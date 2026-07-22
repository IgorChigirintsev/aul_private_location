// Package config loads and validates all runtime configuration from the
// environment into a typed, immutable Config. It fails fast: if a required
// secret is missing or a value is out of range, Load returns an error and the
// server refuses to boot. No secret has a usable default.
package config

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Env distinguishes development conveniences from production strictness.
type Env string

const (
	EnvDevelopment Env = "development"
	EnvProduction  Env = "production"
)

// DBBackend selects which store engine DATABASE_URL points at. The cloud server
// runs on Postgres and that stays the default; the SQLite backend exists for
// the single-binary self-host build (store wiring lands in a later milestone).
type DBBackend string

const (
	BackendPostgres DBBackend = "postgres"
	BackendSQLite   DBBackend = "sqlite"
)

// Config is the fully-resolved server configuration. Treat as immutable.
type Config struct {
	Env          Env
	HTTPAddr     string
	PublicOrigin *url.URL // canonical external origin, e.g. https://aul.example.com
	DatabaseURL  string
	// DBBackend is derived from DATABASE_URL (or AUL_DB_BACKEND), defaulting to
	// Postgres. It only records WHICH backend was requested; the store is still
	// built on Postgres regardless (SQLite store wiring is a later milestone).
	DBBackend DBBackend

	// SessionPepper is a server-side secret HMAC key mixed into session-token
	// hashing so a database-only compromise cannot use stolen token hashes.
	SessionPepper []byte

	SecureCookies            bool
	TrustedServerMode        bool
	MetricsEnabled           bool
	RetentionFeaturesEnabled bool // operator kill-switch for client-side retention features
	RunMigrations            bool
	TrustProxyHeaders        bool   // honor X-Forwarded-For / X-Real-IP (only true behind a trusted proxy)
	DevStaticDir             string // serve web assets from disk instead of embed.FS (dev)
	TilesOrigin              string // optional map-tiles origin, allowed in CSP
	IPLogRetentionDays       int    // 0 disables IP logging entirely

	DefaultRetentionDays int
	MaxRetentionDays     int

	// PingRetentionHours bounds how long a sealed position ping is stored. The
	// only reader left is "latest ping per device" (D-0054 deleted history and
	// the movement/digest stats), so history has no purpose — but its ciphertext
	// still leaks timing/frequency metadata to anyone who steals the DB
	// (THREAT_MODEL §4). The newest ping per (circle, device) is ALWAYS kept
	// regardless of age, or a phone that has been off for days would silently
	// vanish from the map; everything older than this window is dropped.
	PingRetentionHours int

	// Web Push (VAPID, RFC 8292). All optional: with no keypair configured push
	// is simply disabled and /v1/circles/{id}/notify answers 503. The public key
	// is public by design — clients need it as applicationServerKey to subscribe.
	// Payloads stay opaque to the server: it relays a blob the client sealed
	// under K_c (see internal/httpapi/push.go).
	VAPIDPublicKey  string // base64url (raw or padded) P-256 point, 65 bytes
	VAPIDPrivateKey string // base64url (raw or padded) P-256 scalar, 32 bytes
	VAPIDSubject    string // RFC 8292 "sub": mailto: or https: contact URI

	// FCM (Firebase Cloud Messaging, HTTP v1). The second push channel, for
	// Android — a backgrounded app cannot receive Web Push. Optional exactly
	// like VAPID: with no service-account file configured FCM is disabled, the
	// server boots, and /notify still fans out over Web Push alone.
	//
	// Payloads stay opaque here too: FCM messages are data-only, carrying the
	// same blob the client sealed under K_c (see internal/fcm). Google routes
	// the ciphertext; it cannot read it.
	FCMServiceAccountFile string // path to the service-account JSON
	FCMProjectID          string // derived from the JSON — never configured twice
	// FCMCredentialsJSON is the SERVICE-ACCOUNT PRIVATE KEY. Secret, like
	// VAPIDPrivateKey: never log it, never serve it, never echo it in an error.
	FCMCredentialsJSON []byte

	// Token lifetimes.
	AccessTTL  time.Duration
	RefreshTTL time.Duration

	// Request limits.
	BodyLimitBytes  int64
	RequestTimeout  time.Duration
	ShutdownTimeout time.Duration

	// Rate limits (requests per window). Zero means "use default".
	AuthRatePerMin   int
	InvitesRatePerHr int
	PingRatePerMin   int
}

// Load reads configuration from the process environment.
func Load() (*Config, error) {
	return LoadFrom(os.Getenv)
}

// LoadFrom reads configuration using the provided getenv function. This makes
// configuration loading fully testable without mutating the real environment.
func LoadFrom(getenv func(string) string) (*Config, error) {
	var errs []error
	fail := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }

	c := &Config{}

	// Environment.
	switch strings.ToLower(strings.TrimSpace(getenv("AUL_ENV"))) {
	case "", "production", "prod":
		c.Env = EnvProduction
	case "development", "dev":
		c.Env = EnvDevelopment
	default:
		fail("AUL_ENV must be 'production' or 'development'")
	}
	dev := c.Env == EnvDevelopment

	c.HTTPAddr = getenvDefault(getenv, "HTTP_ADDR", ":8080")

	// Public origin: required in production, defaulted in dev.
	rawOrigin := strings.TrimSpace(getenv("PUBLIC_ORIGIN"))
	if rawOrigin == "" {
		if dev {
			rawOrigin = "http://localhost:8080"
		} else {
			fail("PUBLIC_ORIGIN is required in production (e.g. https://aul.example.com)")
		}
	}
	if rawOrigin != "" {
		u, err := url.Parse(rawOrigin)
		if err != nil || u.Scheme == "" || u.Host == "" {
			fail("PUBLIC_ORIGIN must be an absolute URL like https://aul.example.com")
		} else {
			// Normalize to scheme://host[:port] with no path.
			c.PublicOrigin = &url.URL{Scheme: u.Scheme, Host: u.Host}
			if !dev && u.Scheme != "https" {
				fail("PUBLIC_ORIGIN must use https in production")
			}
		}
	}

	// Database.
	c.DatabaseURL = strings.TrimSpace(getenv("DATABASE_URL"))
	if c.DatabaseURL == "" {
		fail("DATABASE_URL is required (postgres://user:pass@host:port/db)")
	}
	backend, err := detectDBBackend(getenv("AUL_DB_BACKEND"), c.DatabaseURL)
	if err != nil {
		fail("%v", err)
	}
	c.DBBackend = backend

	// Session pepper: required non-trivial secret.
	pepper := getenv("SESSION_HASH_PEPPER")
	switch {
	case pepper == "" && dev:
		// Deterministic-but-obviously-insecure dev pepper; loudly not for prod.
		pepper = "dev-insecure-pepper-do-not-use-in-production"
	case pepper == "":
		fail("SESSION_HASH_PEPPER is required (generate: openssl rand -base64 48)")
	case len(pepper) < 16:
		fail("SESSION_HASH_PEPPER must be at least 16 bytes of entropy")
	}
	c.SessionPepper = []byte(pepper)

	c.SecureCookies = getBool(getenv, "SECURE_COOKIES", !dev)
	c.TrustedServerMode = getBool(getenv, "TRUSTED_SERVER_MODE", false)
	c.MetricsEnabled = getBool(getenv, "METRICS_ENABLED", false)
	// Operator kill-switch for the client-side retention features. Defaults ON so
	// operators must opt OUT; every user still defaults opted-out client-side, so
	// nothing activates until both the operator and the user allow it.
	c.RetentionFeaturesEnabled = getBool(getenv, "RETENTION_FEATURES_ENABLED", true)
	c.RunMigrations = getBool(getenv, "RUN_MIGRATIONS", true)
	c.TrustProxyHeaders = getBool(getenv, "TRUST_PROXY_HEADERS", !dev)
	c.DevStaticDir = strings.TrimSpace(getenv("DEV_STATIC_DIR"))
	// The web client points MapLibre at OpenFreeMap by default (D-0018), so the
	// CSP must allow that origin out of the box — otherwise the map renders blank.
	// Self-hosters override with their own tiles origin (which must match the
	// build-time VITE_TILES_STYLE origin).
	c.TilesOrigin = strings.TrimSpace(getenv("TILES_ORIGIN"))
	if c.TilesOrigin == "" {
		c.TilesOrigin = "https://tiles.openfreemap.org"
	}

	c.IPLogRetentionDays = getInt(getenv, fail, "IP_LOG_RETENTION_DAYS", 7, 0, 3650)
	c.DefaultRetentionDays = getInt(getenv, fail, "DEFAULT_RETENTION_DAYS", 7, 1, 3650)
	c.MaxRetentionDays = getInt(getenv, fail, "MAX_RETENTION_DAYS", 90, 1, 3650)
	if c.DefaultRetentionDays > c.MaxRetentionDays {
		fail("DEFAULT_RETENTION_DAYS (%d) cannot exceed MAX_RETENTION_DAYS (%d)",
			c.DefaultRetentionDays, c.MaxRetentionDays)
	}
	// Capped at a week: past that the ciphertext is pure metadata surface, since
	// nothing reads a ping older than the newest one per device.
	c.PingRetentionHours = getInt(getenv, fail, "PING_RETENTION_HOURS", 6, 1, 168)

	loadVAPID(c, getenv, fail)
	loadFCM(c, getenv, fail)

	c.AccessTTL = getDuration(getenv, fail, "ACCESS_TTL", 15*time.Minute)
	c.RefreshTTL = getDuration(getenv, fail, "REFRESH_TTL", 30*24*time.Hour)
	c.RequestTimeout = getDuration(getenv, fail, "REQUEST_TIMEOUT", 30*time.Second)
	c.ShutdownTimeout = getDuration(getenv, fail, "SHUTDOWN_TIMEOUT", 20*time.Second)

	c.BodyLimitBytes = int64(getInt(getenv, fail, "BODY_LIMIT_BYTES", 1<<20, 1024, 1<<26))

	c.AuthRatePerMin = getInt(getenv, fail, "RATE_AUTH_PER_MIN", 10, 1, 100000)
	c.InvitesRatePerHr = getInt(getenv, fail, "RATE_INVITES_PER_HOUR", 20, 1, 100000)
	c.PingRatePerMin = getInt(getenv, fail, "RATE_PINGS_PER_MIN", 120, 1, 100000)

	if cookieSecureButInsecureOrigin(c) {
		fail("SECURE_COOKIES=true requires an https PUBLIC_ORIGIN")
	}

	if len(errs) > 0 {
		return nil, fmt.Errorf("invalid configuration:\n  - %s",
			strings.Join(errStrings(errs), "\n  - "))
	}
	return c, nil
}

// loadVAPID reads the Web Push (VAPID) settings. Push is an optional feature:
// with neither key set it stays disabled and the server boots normally. Setting
// only one key, or setting a malformed one, is an operator mistake that would
// otherwise fail silently on every send — so that does fail fast.
func loadVAPID(c *Config, getenv func(string) string, fail func(string, ...any)) {
	c.VAPIDPublicKey = strings.TrimSpace(getenv("VAPID_PUBLIC_KEY"))
	c.VAPIDPrivateKey = strings.TrimSpace(getenv("VAPID_PRIVATE_KEY"))

	switch {
	case c.VAPIDPublicKey == "" && c.VAPIDPrivateKey == "":
		// Push disabled; nothing else to validate.
		return
	case c.VAPIDPrivateKey == "":
		fail("VAPID_PRIVATE_KEY is required when VAPID_PUBLIC_KEY is set (generate both: aul vapid-keys)")
	case c.VAPIDPublicKey == "":
		fail("VAPID_PUBLIC_KEY is required when VAPID_PRIVATE_KEY is set (generate both: aul vapid-keys)")
	}

	// P-256: an uncompressed public point is 65 bytes, the private scalar 32.
	if n, err := vapidKeyLen(c.VAPIDPublicKey); c.VAPIDPublicKey != "" && (err != nil || n != 65) {
		fail("VAPID_PUBLIC_KEY must be a base64url-encoded 65-byte P-256 public key (generate: aul vapid-keys)")
	}
	if n, err := vapidKeyLen(c.VAPIDPrivateKey); c.VAPIDPrivateKey != "" && (err != nil || n != 32) {
		fail("VAPID_PRIVATE_KEY must be a base64url-encoded 32-byte P-256 private key (generate: aul vapid-keys)")
	}

	// RFC 8292 requires a contact URI in the JWT "sub" claim; push services
	// reject tokens without one. Default to this deployment's own origin when it
	// is https (the production case), so operators need only set the keypair. A
	// non-https origin — a dev server on localhost — is not a valid contact URI,
	// so there the subject must be given explicitly.
	c.VAPIDSubject = strings.TrimSpace(getenv("VAPID_SUBJECT"))
	if c.VAPIDSubject == "" && c.PublicOrigin != nil && c.PublicOrigin.Scheme == "https" {
		c.VAPIDSubject = c.PublicOrigin.String()
	}
	switch s := c.VAPIDSubject; {
	case s == "":
		fail("VAPID_SUBJECT is required when PUBLIC_ORIGIN is not https (e.g. mailto:ops@aul.app)")
	case !strings.HasPrefix(s, "mailto:") && !strings.HasPrefix(s, "https:"):
		fail("VAPID_SUBJECT must be a mailto: or https: contact URI (e.g. mailto:ops@aul.app)")
	}
}

// serviceAccount is the subset of a Google service-account JSON we validate.
// The rest (token_uri, key id, …) is golang.org/x/oauth2/google's business.
type serviceAccount struct {
	Type        string `json:"type"`
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
}

// loadFCM reads the FCM service-account file. FCM is an optional feature: with
// FCM_SERVICE_ACCOUNT_FILE unset it stays disabled and the server boots — same
// contract as VAPID. But a file that is SET and unusable is an operator mistake
// that would otherwise surface as every Android notification silently vanishing,
// so it fails the boot with a message that names the problem.
//
// The project id comes out of the JSON rather than a second env var: it is
// already in there, and two sources of truth for one value is one place for them
// to disagree.
func loadFCM(c *Config, getenv func(string) string, fail func(string, ...any)) {
	path := strings.TrimSpace(getenv("FCM_SERVICE_ACCOUNT_FILE"))
	if path == "" {
		return // FCM disabled; nothing to validate.
	}

	raw, err := os.ReadFile(path) // #nosec G304 -- path IS the operator's own config value; reading it is the feature
	if err != nil {
		fail("FCM_SERVICE_ACCOUNT_FILE is set but cannot be read: %v "+
			"(download it from Firebase console → Project settings → Service accounts)", err)
		return
	}

	// Errors below name the FIELD, never the file's contents: this JSON holds
	// the service account's private key.
	var sa serviceAccount
	if err := json.Unmarshal(raw, &sa); err != nil {
		fail("FCM_SERVICE_ACCOUNT_FILE (%s) is not valid JSON", path)
		return
	}
	switch {
	case sa.Type != "service_account":
		fail("FCM_SERVICE_ACCOUNT_FILE (%s) is not a service-account key "+
			`(expected "type": "service_account"; a google-services.json or web API key will not work)`, path)
		return
	case sa.ProjectID == "":
		fail("FCM_SERVICE_ACCOUNT_FILE (%s) has no project_id", path)
		return
	case sa.ClientEmail == "":
		fail("FCM_SERVICE_ACCOUNT_FILE (%s) has no client_email", path)
		return
	case sa.PrivateKey == "":
		fail("FCM_SERVICE_ACCOUNT_FILE (%s) has no private_key", path)
		return
	}

	c.FCMServiceAccountFile = path
	c.FCMProjectID = sa.ProjectID
	c.FCMCredentialsJSON = raw
}

// vapidKeyLen returns the decoded length of a base64url VAPID key, accepting
// both padded and raw (unpadded) forms — the same leniency webpush-go applies.
func vapidKeyLen(key string) (int, error) {
	if b, err := base64.URLEncoding.DecodeString(key); err == nil {
		return len(b), nil
	}
	b, err := base64.RawURLEncoding.DecodeString(key)
	if err != nil {
		return 0, err
	}
	return len(b), nil
}

func cookieSecureButInsecureOrigin(c *Config) bool {
	return c.SecureCookies && c.PublicOrigin != nil && c.PublicOrigin.Scheme != "https"
}

// IsDev reports whether the server is running in development mode.
func (c *Config) IsDev() bool { return c.Env == EnvDevelopment }

// PushEnabled reports whether Web Push is configured. Load guarantees the keys
// are either both absent (disabled) or both present and well-formed.
func (c *Config) PushEnabled() bool {
	return c.VAPIDPublicKey != "" && c.VAPIDPrivateKey != ""
}

// FCMEnabled reports whether the FCM channel is configured. Load guarantees the
// credentials are either absent (disabled) or present and structurally valid.
//
// This says the OPERATOR configured FCM; it does not say a send can succeed.
// Whether the channel is actually live is the FCM client's business (see
// httpapi.Server.fcmEnabled) — cmd/aul builds one iff this is true, and refuses
// to boot if it cannot. The two channels are independent: either alone is a
// working deployment, and only with neither is push unavailable.
func (c *Config) FCMEnabled() bool { return len(c.FCMCredentialsJSON) > 0 }

// detectDBBackend resolves the store backend without ever hard-rejecting a
// SQLite value. An explicit AUL_DB_BACKEND wins; otherwise the backend is
// inferred from DATABASE_URL's scheme. Anything that is not clearly SQLite
// (a "sqlite:"/"file:" scheme, or a bare filesystem path) is treated as
// Postgres, so the cloud server's "postgres://…"/"postgresql://…" URL — and an
// empty value, already reported by the required-field check — keep the old
// behavior exactly.
func detectDBBackend(explicit, databaseURL string) (DBBackend, error) {
	switch strings.ToLower(strings.TrimSpace(explicit)) {
	case "":
		// fall through to inference
	case "postgres", "postgresql", "pg":
		return BackendPostgres, nil
	case "sqlite", "sqlite3":
		return BackendSQLite, nil
	default:
		return "", fmt.Errorf("AUL_DB_BACKEND must be 'postgres' or 'sqlite'")
	}

	lower := strings.ToLower(strings.TrimSpace(databaseURL))
	switch {
	case strings.HasPrefix(lower, "postgres://"), strings.HasPrefix(lower, "postgresql://"):
		return BackendPostgres, nil
	case strings.HasPrefix(lower, "sqlite:"), strings.HasPrefix(lower, "sqlite3:"), strings.HasPrefix(lower, "file:"):
		return BackendSQLite, nil
	case lower == "":
		return BackendPostgres, nil // empty is a separate required-field failure
	case strings.Contains(lower, "://"):
		// Some other URL scheme: leave it to the (Postgres) store to reject.
		return BackendPostgres, nil
	default:
		// A bare, schemeless value is a SQLite file path (e.g. "aul.db",
		// "/var/lib/aul/aul.db", ":memory:").
		return BackendSQLite, nil
	}
}

// SQLitePath returns the filesystem path (or ":memory:") for a SQLite
// DATABASE_URL, stripping a leading "sqlite:"/"sqlite3:" scheme if present.
// Meaningful only when DBBackend == BackendSQLite; returns DatabaseURL
// unchanged otherwise.
func (c *Config) SQLitePath() string { return SQLitePathOf(c.DatabaseURL) }

// SQLitePathOf strips a leading sqlite:/sqlite3: scheme from a DATABASE_URL,
// yielding the filesystem path (or ":memory:"). Standalone so tools that don't
// Load() the full config (e.g. the publish subcommand) can pick the backend the
// same way the server does. A "file:" DSN is left intact — modernc consumes it.
func SQLitePathOf(databaseURL string) string {
	for _, prefix := range []string{"sqlite://", "sqlite:", "sqlite3://", "sqlite3:"} {
		if len(databaseURL) >= len(prefix) &&
			strings.EqualFold(databaseURL[:len(prefix)], prefix) {
			return databaseURL[len(prefix):]
		}
	}
	return databaseURL
}

// DetectBackend infers the DB backend from AUL_DB_BACKEND + DATABASE_URL using
// the same rules Load() applies. Exposed for tools that open a store without a
// full config.Load() (which would demand runtime secrets they don't need).
func DetectBackend(explicit, databaseURL string) (DBBackend, error) {
	return detectDBBackend(explicit, databaseURL)
}

// --- small typed getters ---

func getenvDefault(getenv func(string) string, key, def string) string {
	if v := strings.TrimSpace(getenv(key)); v != "" {
		return v
	}
	return def
}

func getBool(getenv func(string) string, key string, def bool) bool {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}

func getInt(getenv func(string) string, fail func(string, ...any), key string, def, min, max int) int {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		fail("%s must be an integer", key)
		return def
	}
	if n < min || n > max {
		fail("%s must be between %d and %d", key, min, max)
		return def
	}
	return n
}

func getDuration(getenv func(string) string, fail func(string, ...any), key string, def time.Duration) time.Duration {
	v := strings.TrimSpace(getenv(key))
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		fail("%s must be a duration like 15m or 720h", key)
		return def
	}
	if d <= 0 {
		fail("%s must be positive", key)
		return def
	}
	return d
}

func errStrings(errs []error) []string {
	out := make([]string, len(errs))
	for i, e := range errs {
		out[i] = e.Error()
	}
	return out
}

// ErrNoConfig is returned when configuration is entirely absent (used by tools).
var ErrNoConfig = errors.New("no configuration provided")

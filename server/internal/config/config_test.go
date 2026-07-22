package config

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

// env builds a getenv func from a map.
func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func baseProd() map[string]string {
	return map[string]string{
		"AUL_ENV":             "production",
		"PUBLIC_ORIGIN":       "https://aul.example.com",
		"DATABASE_URL":        "postgres://u:p@db:5432/aul",
		"SESSION_HASH_PEPPER": "a-sufficiently-long-pepper-value",
	}
}

func TestLoad_ProductionOK(t *testing.T) {
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.Env != EnvProduction {
		t.Fatal("expected production env")
	}
	if c.PublicOrigin.String() != "https://aul.example.com" {
		t.Fatalf("origin = %s", c.PublicOrigin)
	}
	if c.AccessTTL != 15*time.Minute || c.RefreshTTL != 30*24*time.Hour {
		t.Fatalf("token TTL defaults wrong: %v %v", c.AccessTTL, c.RefreshTTL)
	}
	if !c.SecureCookies {
		t.Fatal("secure cookies should default true in prod")
	}
	if c.TrustedServerMode {
		t.Fatal("trusted server mode must default OFF")
	}
}

func TestLoad_TilesOriginDefaultsToOpenFreeMap(t *testing.T) {
	// Unset TILES_ORIGIN must default to OpenFreeMap so the CSP allows the map
	// tiles the web client requests by default — otherwise the map renders blank.
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.TilesOrigin != "https://tiles.openfreemap.org" {
		t.Fatalf("TilesOrigin default = %q, want https://tiles.openfreemap.org", c.TilesOrigin)
	}

	// An explicit origin (e.g. a self-hosted tile server) overrides the default.
	m := baseProd()
	m["TILES_ORIGIN"] = "https://tiles.internal.example"
	c2, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c2.TilesOrigin != "https://tiles.internal.example" {
		t.Fatalf("TilesOrigin override = %q", c2.TilesOrigin)
	}
}

func TestLoad_RetentionFeaturesKillSwitch(t *testing.T) {
	// Defaults ON: operators must opt OUT. (Users still default opted-out
	// client-side, so nothing activates until both sides allow it.)
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !c.RetentionFeaturesEnabled {
		t.Fatal("RetentionFeaturesEnabled should default true")
	}

	// RETENTION_FEATURES_ENABLED=false is honored (operator kill-switch).
	m := baseProd()
	m["RETENTION_FEATURES_ENABLED"] = "false"
	c2, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c2.RetentionFeaturesEnabled {
		t.Fatal("RETENTION_FEATURES_ENABLED=false must disable retention features")
	}
}

func TestLoad_MissingRequiredSecrets(t *testing.T) {
	m := baseProd()
	delete(m, "SESSION_HASH_PEPPER")
	delete(m, "DATABASE_URL")
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error for missing required secrets")
	}
}

func TestLoad_ProdRequiresHTTPS(t *testing.T) {
	m := baseProd()
	m["PUBLIC_ORIGIN"] = "http://aul.example.com"
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error: prod origin must be https")
	}
}

func TestLoad_WeakPepperRejected(t *testing.T) {
	m := baseProd()
	m["SESSION_HASH_PEPPER"] = "short"
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error for weak pepper")
	}
}

func TestLoad_DevDefaults(t *testing.T) {
	c, err := LoadFrom(env(map[string]string{
		"AUL_ENV":      "development",
		"DATABASE_URL": "postgres://u:p@localhost/aul",
	}))
	if err != nil {
		t.Fatalf("dev load: %v", err)
	}
	if c.PublicOrigin.String() != "http://localhost:8080" {
		t.Fatalf("dev origin default = %s", c.PublicOrigin)
	}
	if c.SecureCookies {
		t.Fatal("dev should default secure cookies off")
	}
	if len(c.SessionPepper) == 0 {
		t.Fatal("dev pepper should be set")
	}
}

func TestLoad_RetentionBounds(t *testing.T) {
	m := baseProd()
	m["DEFAULT_RETENTION_DAYS"] = "100"
	m["MAX_RETENTION_DAYS"] = "90"
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error: default retention exceeds max")
	}
}

func TestLoad_PingRetentionHours(t *testing.T) {
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if c.PingRetentionHours != 6 {
		t.Fatalf("default PING_RETENTION_HOURS = %d, want 6", c.PingRetentionHours)
	}

	m := baseProd()
	m["PING_RETENTION_HOURS"] = "24"
	if c, err := LoadFrom(env(m)); err != nil || c.PingRetentionHours != 24 {
		t.Fatalf("PING_RETENTION_HOURS=24: got %v err=%v", c, err)
	}

	// Out of range in either direction is an operator mistake, not a clamp: 0
	// would delete everything but the newest pin, and past a week the stored
	// ciphertext is pure metadata surface no reader wants.
	for _, bad := range []string{"0", "169", "-1", "six"} {
		m := baseProd()
		m["PING_RETENTION_HOURS"] = bad
		if _, err := LoadFrom(env(m)); err == nil {
			t.Errorf("PING_RETENTION_HOURS=%q accepted, want rejected", bad)
		}
	}
}

func TestLoad_SecureCookiesRequireHTTPSOrigin(t *testing.T) {
	m := map[string]string{
		"AUL_ENV":             "development",
		"DATABASE_URL":        "postgres://u:p@localhost/aul",
		"PUBLIC_ORIGIN":       "http://localhost:9999",
		"SESSION_HASH_PEPPER": "a-sufficiently-long-pepper-value",
		"SECURE_COOKIES":      "true",
	}
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error: secure cookies with http origin")
	}
}

func TestLoad_InvalidIntRejected(t *testing.T) {
	m := baseProd()
	m["IP_LOG_RETENTION_DAYS"] = "-1"
	if _, err := LoadFrom(env(m)); err == nil {
		t.Fatal("expected error for negative IP retention")
	}
}

// --- Web Push (VAPID) ---

// vapidKeys mints a real keypair so the tests exercise the same encoding the
// server will see in production.
func vapidKeys(t *testing.T) (public, private string) {
	t.Helper()
	private, public, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatalf("generate vapid keys: %v", err)
	}
	return public, private
}

func TestLoad_PushDisabledByDefault(t *testing.T) {
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.PushEnabled() {
		t.Fatal("push must be disabled when no VAPID keys are set")
	}
	if c.VAPIDPublicKey != "" || c.VAPIDPrivateKey != "" {
		t.Fatal("VAPID keys should be empty when unset")
	}
}

func TestLoad_PushEnabledWithBothKeys(t *testing.T) {
	pub, priv := vapidKeys(t)
	m := baseProd()
	m["VAPID_PUBLIC_KEY"] = pub
	m["VAPID_PRIVATE_KEY"] = priv

	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !c.PushEnabled() {
		t.Fatal("push should be enabled when both VAPID keys are set")
	}
	if c.VAPIDPublicKey != pub || c.VAPIDPrivateKey != priv {
		t.Fatal("VAPID keys not loaded verbatim")
	}
	// With no VAPID_SUBJECT the deployment's own origin is a valid RFC 8292
	// https: contact URI, so push works without extra configuration.
	if c.VAPIDSubject != "https://aul.example.com" {
		t.Fatalf("VAPIDSubject = %q, want the public origin", c.VAPIDSubject)
	}
}

func TestLoad_PushSubjectOverride(t *testing.T) {
	pub, priv := vapidKeys(t)
	m := baseProd()
	m["VAPID_PUBLIC_KEY"] = pub
	m["VAPID_PRIVATE_KEY"] = priv
	m["VAPID_SUBJECT"] = "mailto:ops@aul.app"

	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.VAPIDSubject != "mailto:ops@aul.app" {
		t.Fatalf("VAPIDSubject = %q", c.VAPIDSubject)
	}
}

// A dev server's origin is http://localhost, which is not a valid RFC 8292
// contact URI — so it must not be used as the default subject. Enabling push in
// dev requires an explicit VAPID_SUBJECT, and must then boot cleanly.
func TestLoad_PushInDevNeedsExplicitSubject(t *testing.T) {
	pub, priv := vapidKeys(t)
	dev := func() map[string]string {
		return map[string]string{
			"AUL_ENV":           "development",
			"DATABASE_URL":      "postgres://u:p@localhost/aul",
			"VAPID_PUBLIC_KEY":  pub,
			"VAPID_PRIVATE_KEY": priv,
		}
	}
	if _, err := LoadFrom(env(dev())); err == nil {
		t.Fatal("expected an error: http://localhost is not a valid VAPID subject")
	}

	m := dev()
	m["VAPID_SUBJECT"] = "mailto:dev@localhost"
	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("push in dev with an explicit subject must boot: %v", err)
	}
	if !c.PushEnabled() || c.VAPIDSubject != "mailto:dev@localhost" {
		t.Fatalf("push not configured as expected: enabled=%v subject=%q", c.PushEnabled(), c.VAPIDSubject)
	}
}

// A half-configured or malformed keypair would fail silently on every single
// send, so it must fail at boot instead.
func TestLoad_PushMisconfigurationRejected(t *testing.T) {
	pub, priv := vapidKeys(t)
	cases := []struct {
		name string
		envs map[string]string
	}{
		{"public without private", map[string]string{"VAPID_PUBLIC_KEY": pub}},
		{"private without public", map[string]string{"VAPID_PRIVATE_KEY": priv}},
		{"malformed public", map[string]string{"VAPID_PUBLIC_KEY": "not!base64", "VAPID_PRIVATE_KEY": priv}},
		{"malformed private", map[string]string{"VAPID_PUBLIC_KEY": pub, "VAPID_PRIVATE_KEY": "not!base64"}},
		{"wrong-length public", map[string]string{"VAPID_PUBLIC_KEY": "c2hvcnQ", "VAPID_PRIVATE_KEY": priv}},
		{"swapped keys", map[string]string{"VAPID_PUBLIC_KEY": priv, "VAPID_PRIVATE_KEY": pub}},
		{"bad subject", map[string]string{
			"VAPID_PUBLIC_KEY": pub, "VAPID_PRIVATE_KEY": priv, "VAPID_SUBJECT": "ops@aul.app",
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := baseProd()
			for k, v := range tc.envs {
				m[k] = v
			}
			if _, err := LoadFrom(env(m)); err == nil {
				t.Fatal("expected a configuration error")
			}
		})
	}
}

// --- FCM (the Android push channel) ---

// fakeServiceAccount writes a service-account-shaped JSON file and returns its
// path. The private key is obvious junk: config only checks the field is
// present, and a real key must never live in a test fixture.
func fakeServiceAccount(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write service account: %v", err)
	}
	return path
}

const validServiceAccount = `{
  "type": "service_account",
  "project_id": "e2ee-test-project",
  "private_key_id": "0000",
  "private_key": "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n",
  "client_email": "fcm@e2ee-test-project.iam.gserviceaccount.com",
  "client_id": "1",
  "token_uri": "https://oauth2.googleapis.com/token"
}`

// FCM mirrors VAPID: unset means the feature is off and the server still boots.
func TestLoad_FCMDisabledByDefault(t *testing.T) {
	c, err := LoadFrom(env(baseProd()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.FCMEnabled() {
		t.Fatal("FCM must be disabled when FCM_SERVICE_ACCOUNT_FILE is unset")
	}
	if c.FCMProjectID != "" || len(c.FCMCredentialsJSON) != 0 {
		t.Fatal("FCM fields should be empty when unset")
	}
}

func TestLoad_FCMEnabledFromServiceAccount(t *testing.T) {
	m := baseProd()
	m["FCM_SERVICE_ACCOUNT_FILE"] = fakeServiceAccount(t, validServiceAccount)

	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !c.FCMEnabled() {
		t.Fatal("FCM should be enabled when a valid service-account file is set")
	}
	// The project id comes out of the JSON: operators never configure it twice.
	if c.FCMProjectID != "e2ee-test-project" {
		t.Fatalf("FCMProjectID = %q, want it derived from the key file", c.FCMProjectID)
	}
	if len(c.FCMCredentialsJSON) == 0 {
		t.Fatal("credentials JSON not loaded")
	}
	// FCM must not imply Web Push: the channels are independent.
	if c.PushEnabled() {
		t.Fatal("Web Push must stay disabled without VAPID keys")
	}
}

// Each channel works alone, and both together.
func TestLoad_PushChannelsAreIndependent(t *testing.T) {
	pub, priv := vapidKeys(t)
	sa := fakeServiceAccount(t, validServiceAccount)

	cases := []struct {
		name             string
		envs             map[string]string
		wantWeb, wantFCM bool
	}{
		{"neither", map[string]string{}, false, false},
		{"web push only", map[string]string{
			"VAPID_PUBLIC_KEY": pub, "VAPID_PRIVATE_KEY": priv,
		}, true, false},
		{"fcm only", map[string]string{"FCM_SERVICE_ACCOUNT_FILE": sa}, false, true},
		{"both", map[string]string{
			"VAPID_PUBLIC_KEY": pub, "VAPID_PRIVATE_KEY": priv, "FCM_SERVICE_ACCOUNT_FILE": sa,
		}, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := baseProd()
			for k, v := range tc.envs {
				m[k] = v
			}
			c, err := LoadFrom(env(m))
			if err != nil {
				t.Fatalf("every combination must boot, got: %v", err)
			}
			if c.PushEnabled() != tc.wantWeb {
				t.Errorf("PushEnabled = %v, want %v", c.PushEnabled(), tc.wantWeb)
			}
			if c.FCMEnabled() != tc.wantFCM {
				t.Errorf("FCMEnabled = %v, want %v", c.FCMEnabled(), tc.wantFCM)
			}
		})
	}
}

// A key file that is SET but unusable would make every Android notification
// vanish silently. Fail the boot instead — and say what is wrong.
func TestLoad_FCMMisconfigurationRejected(t *testing.T) {
	cases := []struct {
		name    string
		file    string // file contents; "" = point at a path that does not exist
		wantMsg string
	}{
		{"missing file", "", "cannot be read"},
		{"not json", `this is not json`, "not valid JSON"},
		{"empty object", `{}`, "not a service-account key"},
		{"wrong type (google-services.json)", `{"project_info":{"project_id":"x"}}`, "not a service-account key"},
		{"oauth client, not a service account", `{"type":"authorized_user","project_id":"x"}`, "not a service-account key"},
		{"no project_id", `{"type":"service_account","client_email":"a@b.com","private_key":"k"}`, "no project_id"},
		{"no client_email", `{"type":"service_account","project_id":"p","private_key":"k"}`, "no client_email"},
		{"no private_key", `{"type":"service_account","project_id":"p","client_email":"a@b.com"}`, "no private_key"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := baseProd()
			if tc.file == "" {
				m["FCM_SERVICE_ACCOUNT_FILE"] = filepath.Join(t.TempDir(), "does-not-exist.json")
			} else {
				m["FCM_SERVICE_ACCOUNT_FILE"] = fakeServiceAccount(t, tc.file)
			}
			_, err := LoadFrom(env(m))
			if err == nil {
				t.Fatal("expected a configuration error")
			}
			if !strings.Contains(err.Error(), tc.wantMsg) {
				t.Fatalf("error = %q, want it to mention %q", err, tc.wantMsg)
			}
		})
	}
}

// The service-account file holds a private key. A config error names the file
// and the missing field — never the contents.
func TestLoad_FCMErrorsDoNotLeakTheKey(t *testing.T) {
	const secret = "-----BEGIN PRIVATE KEY-----\nSUPER-SECRET-MATERIAL\n-----END PRIVATE KEY-----"
	m := baseProd()
	// Valid private_key, but no project_id: fails validation with the key loaded.
	m["FCM_SERVICE_ACCOUNT_FILE"] = fakeServiceAccount(t,
		`{"type":"service_account","client_email":"a@b.com","private_key":`+strconv.Quote(secret)+`}`)

	_, err := LoadFrom(env(m))
	if err == nil {
		t.Fatal("expected a configuration error")
	}
	if strings.Contains(err.Error(), "SUPER-SECRET-MATERIAL") || strings.Contains(err.Error(), "BEGIN PRIVATE KEY") {
		t.Fatalf("configuration error leaks the service-account private key: %v", err)
	}
}

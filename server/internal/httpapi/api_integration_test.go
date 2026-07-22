//go:build integration

package httpapi_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/crypto"
	"github.com/aul-app/aul/server/internal/httpapi"
	"github.com/aul-app/aul/server/internal/ratelimit"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
	"github.com/aul-app/aul/server/internal/testutil"
)

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
func nonce24() string     { return base64.StdEncoding.EncodeToString(make([]byte, 24)) }

type apiClient struct {
	t     *testing.T
	base  string
	hc    *http.Client
	store *store.Store
}

// pool exposes the DB pool for tests that inspect stored data directly.
func (c *apiClient) pool() *pgxpool.Pool { return c.store.Pool() }

// --- backend-neutral raw-SQL helpers ---
//
// A handful of tests inspect stored rows directly to assert storage-level facts
// (ciphertext opacity, subscription shape, position dedup). These helpers run
// the same assertions against either backend: queries are written pg-style
// ($N); for SQLite the $N are rewritten to ? (every call site lists them in
// ascending order) and string args bind identically to a uuid TEXT column and,
// via pgx, to a Postgres uuid column.

// sqliteTSLayout mirrors internal/store's canonical fixed-width timestamp form
// so a time written by a raw test query sorts lexicographically against the
// timestamps the store writes.
const sqliteTSLayout = "2006-01-02T15:04:05.000Z07:00"

var placeholderRe = regexp.MustCompile(`\$\d+`)

type rawScanner interface{ Scan(dest ...any) error }

func (c *apiClient) qRow(ctx context.Context, pgQuery string, args ...any) rawScanner {
	if testutil.IsSQLite() {
		return c.store.SQLDB().QueryRowContext(ctx, placeholderRe.ReplaceAllString(pgQuery, "?"), args...)
	}
	return c.store.Pool().QueryRow(ctx, pgQuery, args...)
}

// tableColumns returns a table's column names on whichever backend backs the
// store (information_schema on Postgres, pragma_table_info on SQLite).
func (c *apiClient) tableColumns(ctx context.Context, table string) []string {
	c.t.Helper()
	var cols []string
	if testutil.IsSQLite() {
		rows, err := c.store.SQLDB().QueryContext(ctx, `SELECT name FROM pragma_table_info(?)`, table)
		if err != nil {
			c.t.Fatalf("pragma_table_info(%s): %v", table, err)
		}
		defer rows.Close()
		for rows.Next() {
			var col string
			if err := rows.Scan(&col); err != nil {
				c.t.Fatalf("scan col: %v", err)
			}
			cols = append(cols, col)
		}
		return cols
	}
	rows, err := c.store.Pool().Query(ctx,
		`SELECT column_name FROM information_schema.columns WHERE table_name = $1`, table)
	if err != nil {
		c.t.Fatalf("information_schema for %s: %v", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var col string
		if err := rows.Scan(&col); err != nil {
			c.t.Fatalf("scan col: %v", err)
		}
		cols = append(cols, col)
	}
	return cols
}

func (c *apiClient) do(method, path, token string, body any) (int, map[string]any) {
	c.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, rdr)
	if err != nil {
		c.t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		c.t.Fatalf("do %s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &out)
	}
	return resp.StatusCode, out
}

func newTestServer(t *testing.T) *apiClient {
	return newTestServerWith(t, nil)
}

// newTestServerWith builds the test server, letting a test adjust the config
// before the server is wired (e.g. to enable Web Push).
func newTestServerWith(t *testing.T, tweak func(*config.Config)) *apiClient {
	return newTestServerWithDeps(t, tweak, nil)
}

// newTestServerWithDeps additionally lets a test adjust the wired dependencies
// — the FCM channel is a client, not a config value, so a test that wants it
// aimed at a stub must reach the Deps.
func newTestServerWithDeps(t *testing.T, tweak func(*config.Config), tweakDeps func(*httpapi.Deps)) *apiClient {
	t.Helper()
	st := testutil.Store(t)
	origin, _ := url.Parse("http://localhost")
	cfg := &config.Config{
		Env: config.EnvDevelopment, PublicOrigin: origin,
		SessionPepper: []byte("api-test-pepper-abcdefghijklmnop"),
		AccessTTL:     15 * time.Minute, RefreshTTL: 720 * time.Hour,
		DefaultRetentionDays: 7, MaxRetentionDays: 90,
		BodyLimitBytes: 1 << 20, RequestTimeout: 10 * time.Second,
		IPLogRetentionDays: 7,
	}
	if tweak != nil {
		tweak(cfg)
	}
	aud := audit.New(st.Querier, true)
	authSvc, err := auth.NewService(st, aud, cfg, auth.WithArgon2Params(crypto.Argon2Params{Memory: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32}))
	if err != nil {
		t.Fatalf("auth service: %v", err)
	}
	hub := realtime.NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	go hub.Run(ctx)
	t.Cleanup(cancel)

	deps := httpapi.Deps{
		Config: cfg, Store: st, Auth: authSvc, Hub: hub, Audit: aud,
		AuthLimiter: ratelimit.Noop{}, InviteLimiter: ratelimit.Noop{}, PingLimiter: ratelimit.Noop{},
	}
	if tweakDeps != nil {
		tweakDeps(&deps)
	}
	srv := httpapi.NewServer(deps)
	ts := httptest.NewServer(srv.Router())
	t.Cleanup(ts.Close)
	return &apiClient{t: t, base: ts.URL, hc: ts.Client(), store: st}
}

func register(c *apiClient, email, platform string) (token, deviceID string) {
	code, body := c.do(http.MethodPost, "/v1/auth/register", "", map[string]any{
		"email": email, "password": "a-strong-password-123", "platform": platform,
	})
	if code != http.StatusCreated {
		c.t.Fatalf("register %s: status %d: %v", email, code, body)
	}
	dev := body["device"].(map[string]any)
	return body["access_token"].(string), dev["id"].(string)
}

func TestAPI_FullFlow_TwoDevicesSeePings(t *testing.T) {
	c := newTestServer(t)

	aTok, aDev := register(c, "alice@ex.com", "web")
	bTok, bDev := register(c, "bob@ex.com", "android")

	// Alice creates a circle.
	code, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{"retention_days": 7})
	if code != http.StatusCreated {
		t.Fatalf("create circle: %d %v", code, circle)
	}
	circleID := circle["id"].(string)

	// Alice invites; Bob accepts.
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 5})
	inviteID := inv["id"].(string)
	code, acc := c.do(http.MethodPost, "/v1/invites/"+inviteID+"/accept", bTok, nil)
	if code != http.StatusOK || acc["status"] != "joined" {
		t.Fatalf("accept: %d %v", code, acc)
	}

	captured := time.Now().UTC().Format(time.RFC3339)
	postPing := func(tok, cid, ct string) (int, map[string]any) {
		return c.do(http.MethodPost, "/v1/pings/batch", tok, map[string]any{
			"pings": []map[string]any{{
				"circle_id": circleID, "client_id": cid, "nonce": nonce24(),
				"ciphertext": b64(ct), "captured_at": captured,
			}},
		})
	}
	if code, _ := postPing(aTok, "a1", "ALICE"); code != http.StatusOK {
		t.Fatalf("alice ping: %d", code)
	}
	if code, _ := postPing(bTok, "b1", "BOB"); code != http.StatusOK {
		t.Fatalf("bob ping: %d", code)
	}

	// Idempotency: re-posting the same (client_id, captured_at) stores 0.
	code, dup := postPing(aTok, "a1", "ALICE")
	if code != http.StatusOK || int(dup["stored"].(float64)) != 0 {
		t.Fatalf("idempotency failed: %d %v", code, dup)
	}

	// Both see both devices in latest.
	assertSeesBoth := func(tok string) {
		_, view := c.do(http.MethodGet, "/v1/circles/"+circleID+"/pings/latest", tok, nil)
		pings := view["pings"].([]any)
		seen := map[string]bool{}
		for _, p := range pings {
			seen[p.(map[string]any)["device_id"].(string)] = true
		}
		if !seen[aDev] || !seen[bDev] {
			t.Fatalf("expected both devices, saw %v", seen)
		}
	}
	assertSeesBoth(aTok)
	assertSeesBoth(bTok)
}

func TestAPI_MembershipEnforced(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "owner@ex.com", "web")
	cTok, _ := register(c, "stranger@ex.com", "web")

	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)

	// Non-member cannot read the circle (404, existence not leaked).
	if code, _ := c.do(http.MethodGet, "/v1/circles/"+circleID, cTok, nil); code != http.StatusNotFound {
		t.Fatalf("stranger read: expected 404, got %d", code)
	}
	// Non-member cannot post a ping to it (403).
	code, _ := c.do(http.MethodPost, "/v1/pings/batch", cTok, map[string]any{
		"pings": []map[string]any{{
			"circle_id": circleID, "client_id": "x", "nonce": nonce24(),
			"ciphertext": b64("X"), "captured_at": time.Now().UTC().Format(time.RFC3339),
		}},
	})
	if code != http.StatusForbidden {
		t.Fatalf("stranger ping: expected 403, got %d", code)
	}
}

func TestAPI_AuthRequired(t *testing.T) {
	c := newTestServer(t)
	if code, _ := c.do(http.MethodGet, "/v1/circles", "", nil); code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", code)
	}
	if code, _ := c.do(http.MethodGet, "/v1/circles", "garbage-token", nil); code != http.StatusUnauthorized {
		t.Fatalf("expected 401 with bad token, got %d", code)
	}
}

func TestAPI_LeaveAndRetentionValidation(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "o@ex.com", "web")
	bTok, _ := register(c, "m@ex.com", "web")
	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 2})
	c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil)

	// Member can leave immediately (anti-stalking guarantee).
	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/leave", bTok, nil); code != http.StatusOK {
		t.Fatalf("leave: expected 200, got %d", code)
	}
	// After leaving, the ex-member no longer sees the circle.
	if code, _ := c.do(http.MethodGet, "/v1/circles/"+circleID, bTok, nil); code != http.StatusNotFound {
		t.Fatalf("post-leave read: expected 404, got %d", code)
	}
	// Retention over the cap is rejected.
	if code, _ := c.do(http.MethodPatch, "/v1/circles/"+circleID, aTok, map[string]any{"retention_days": 100000}); code != http.StatusBadRequest {
		t.Fatalf("retention cap: expected 400, got %d", code)
	}
}

func TestAPI_MemberProfile(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "profa@ex.com", "web")
	bTok, _ := register(c, "profb@ex.com", "web")

	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 2})
	c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil)

	profilePath := "/v1/circles/" + circleID + "/profile"

	// profileFor returns a member's profile_enc from the members list (nil if unset).
	profileFor := func(tok, email string) (any, bool) {
		_, list := c.do(http.MethodGet, "/v1/circles/"+circleID+"/members", tok, nil)
		for _, mm := range list["members"].([]any) {
			m := mm.(map[string]any)
			if m["email"] == email {
				return m["profile_enc"], true
			}
		}
		return nil, false
	}

	// Alice stores a sealed profile blob (opaque to the server).
	sealed := b64("SEALED-PROFILE-BLOB-alice")
	if code, body := c.do(http.MethodPut, profilePath, aTok, map[string]any{"profile_enc": sealed}); code != http.StatusOK {
		t.Fatalf("set profile: expected 200, got %d: %v", code, body)
	}

	// The list round-trips Alice's blob verbatim; Bob (no profile) stays null.
	if got, ok := profileFor(aTok, "profa@ex.com"); !ok || got != sealed {
		t.Fatalf("alice profile_enc: expected %q, got %v (found=%v)", sealed, got, ok)
	}
	if got, ok := profileFor(aTok, "profb@ex.com"); !ok || got != nil {
		t.Fatalf("bob profile_enc: expected null, got %v (found=%v)", got, ok)
	}

	// Explicit null clears the profile (fallback to email/first-letter).
	if code, _ := c.do(http.MethodPut, profilePath, aTok, map[string]any{"profile_enc": nil}); code != http.StatusOK {
		t.Fatalf("clear profile: expected 200, got %d", code)
	}
	if got, ok := profileFor(aTok, "profa@ex.com"); !ok || got != nil {
		t.Fatalf("cleared profile_enc: expected null, got %v (found=%v)", got, ok)
	}

	// A blob whose decoded size exceeds the 128 KiB ceiling is rejected.
	big := base64.StdEncoding.EncodeToString(make([]byte, 129*1024))
	if code, _ := c.do(http.MethodPut, profilePath, aTok, map[string]any{"profile_enc": big}); code != http.StatusBadRequest {
		t.Fatalf("oversized profile: expected 400, got %d", code)
	}

	// A non-member cannot set a profile; requireCircleMember returns 404 so the
	// circle's existence is not leaked (same as reading a foreign circle).
	sTok, _ := register(c, "profstranger@ex.com", "web")
	if code, _ := c.do(http.MethodPut, profilePath, sTok, map[string]any{"profile_enc": sealed}); code != http.StatusNotFound {
		t.Fatalf("stranger set profile: expected 404, got %d", code)
	}
}

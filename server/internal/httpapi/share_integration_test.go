//go:build integration

package httpapi_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/aul-app/aul/server/internal/testutil"
)

// doShare issues a request to the public viewer endpoint with an explicit cookie
// set (or deliberately none), returning the response cookies so the one-device
// binding can be inspected. The shared apiClient deliberately carries no cookie
// jar, which is exactly what these tests need: every request's credentials are
// stated, never implied.
func (c *apiClient) doShare(method, path string, cookies []*http.Cookie) (int, map[string]any, []*http.Cookie) {
	c.t.Helper()
	req, err := http.NewRequest(method, c.base+path, nil)
	if err != nil {
		c.t.Fatalf("new request: %v", err)
	}
	for _, ck := range cookies {
		req.AddCookie(ck)
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
	return resp.StatusCode, out, resp.Cookies()
}

// createShare mints a live-share session for tok and returns its id.
func createShare(c *apiClient, tok string, body any) string {
	c.t.Helper()
	code, out := c.do(http.MethodPost, "/v1/share", tok, body)
	if code != http.StatusCreated {
		c.t.Fatalf("create share: %d %v", code, out)
	}
	return out["id"].(string)
}

// errCode digs the stable machine-readable code out of the error envelope.
func errCode(body map[string]any) string {
	e, ok := body["error"].(map[string]any)
	if !ok {
		return ""
	}
	code, _ := e["code"].(string)
	return code
}

// expireShare forces a session's clock into the past. TTLs bottom out at 60s, so
// waiting one out is not an option; this is the only way to observe the expiry
// path.
func expireShare(c *apiClient, id string) {
	c.t.Helper()
	ctx := context.Background()
	if testutil.IsSQLite() {
		// SQLite has no now()/interval; write a canonical-format past instant so
		// it sorts lexicographically against the store's timestamps.
		past := time.Now().Add(-time.Minute).UTC().Format(sqliteTSLayout)
		if _, err := c.store.SQLDB().ExecContext(ctx,
			`UPDATE share_sessions SET expires_at = ? WHERE id = ?`, past, id); err != nil {
			c.t.Fatalf("expire share: %v", err)
		}
		return
	}
	if _, err := c.store.Pool().Exec(ctx,
		`UPDATE share_sessions SET expires_at = now() - interval '1 minute' WHERE id = $1`, id); err != nil {
		c.t.Fatalf("expire share: %v", err)
	}
}

// The whole point of the feature: an outsider with no account follows a live
// dot, the sharer's ciphertext reaches them untouched, and the link dies on
// command.
func TestShare_ViewerSeesSealedPositionUntilRevoked(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "sharer@ex.com", "web")

	id := createShare(c, aTok, map[string]any{"ttl_seconds": 600})
	link := "/v1/share/" + id

	// A fresh link is live but blank: the viewer waits for the first fix.
	code, body, cookies := c.doShare(http.MethodGet, link, nil)
	if code != http.StatusOK {
		t.Fatalf("first viewer GET: %d %v", code, body)
	}
	if body["position"] != nil {
		t.Fatalf("a share with no ping yet must report position null, got %v", body["position"])
	}
	if len(cookies) != 1 {
		t.Fatalf("first GET must bind the link with exactly one cookie, got %d", len(cookies))
	}
	viewer := cookies[0]

	// The cookie must be the viewer's bearer token and nothing else: no script
	// may read it, and the browser must send it to this link alone.
	if got, want := viewer.Name, "aul_share_"+id; got != want {
		t.Errorf("cookie name = %q, want %q", got, want)
	}
	if got, want := viewer.Path, "/v1/share/"+id; got != want {
		t.Errorf("cookie path = %q, want %q", got, want)
	}
	if !viewer.HttpOnly {
		t.Error("share cookie must be HttpOnly")
	}
	if viewer.SameSite != http.SameSiteLaxMode {
		t.Errorf("cookie SameSite = %v, want Lax", viewer.SameSite)
	}
	if viewer.MaxAge <= 0 || viewer.MaxAge > 600 {
		t.Errorf("cookie Max-Age = %d, want 0 < age <= 600 (the session's remaining life)", viewer.MaxAge)
	}
	if viewer.Value == "" {
		t.Error("share cookie must carry the opaque token")
	}

	// The sharer posts a fix sealed under K_share — a key the server never sees.
	const sealed = "SEALED-UNDER-K_SHARE-NOT-THE-CIRCLE-KEY"
	captured := time.Now().UTC().Format(time.RFC3339)
	code, out := c.do(http.MethodPut, link+"/ping", aTok, map[string]any{
		"nonce": nonce24(), "ciphertext": b64(sealed), "captured_at": captured,
	})
	if code != http.StatusOK || out["status"] != "ok" {
		t.Fatalf("owner ping: %d %v", code, out)
	}

	// The bound viewer now sees that exact ciphertext, byte for byte.
	code, body, _ = c.doShare(http.MethodGet, link, []*http.Cookie{viewer})
	if code != http.StatusOK {
		t.Fatalf("bound viewer GET: %d %v", code, body)
	}
	pos, ok := body["position"].(map[string]any)
	if !ok {
		t.Fatalf("expected a position, got %v", body["position"])
	}
	if pos["ciphertext"] != b64(sealed) {
		t.Fatalf("ciphertext round-trip: got %v, want %v", pos["ciphertext"], b64(sealed))
	}
	if pos["nonce"] != nonce24() {
		t.Fatalf("nonce round-trip: got %v, want %v", pos["nonce"], nonce24())
	}
	if body["expires_at"] == nil {
		t.Error("viewer must learn when the link dies")
	}

	// Only the latest fix exists: a viewer follows a dot, never a track.
	newer := time.Now().UTC().Add(time.Second).Format(time.RFC3339)
	if code, out := c.do(http.MethodPut, link+"/ping", aTok, map[string]any{
		"nonce": nonce24(), "ciphertext": b64("SECOND-FIX"), "captured_at": newer,
	}); code != http.StatusOK {
		t.Fatalf("second ping: %d %v", code, out)
	}
	var stored int
	if err := c.qRow(context.Background(),
		`SELECT count(*) FROM share_positions WHERE session_id = $1`, id).Scan(&stored); err != nil {
		t.Fatalf("count positions: %v", err)
	}
	if stored != 1 {
		t.Fatalf("share_positions holds %d rows for this session, want exactly 1 (no history)", stored)
	}
	_, body, _ = c.doShare(http.MethodGet, link, []*http.Cookie{viewer})
	if got := body["position"].(map[string]any)["ciphertext"]; got != b64("SECOND-FIX") {
		t.Fatalf("viewer must see the newest fix, got %v", got)
	}

	// Revoke: the link dies at once, for the bound viewer too.
	code, out = c.do(http.MethodDelete, link, aTok, nil)
	if code != http.StatusOK || out["status"] != "revoked" {
		t.Fatalf("revoke: %d %v", code, out)
	}
	code, body, _ = c.doShare(http.MethodGet, link, []*http.Cookie{viewer})
	if code != http.StatusGone {
		t.Fatalf("GET after revoke: %d %v, want 410", code, body)
	}
	if code, out := c.do(http.MethodPut, link+"/ping", aTok, map[string]any{
		"nonce": nonce24(), "ciphertext": b64("TOO-LATE"), "captured_at": time.Now().UTC().Format(time.RFC3339),
	}); code != http.StatusGone {
		t.Fatalf("ping after revoke: %d %v, want 410", code, out)
	}

	// Revoking twice is a no-op, not an error: a retried DELETE must not look
	// like a missing link.
	if code, out := c.do(http.MethodDelete, link, aTok, nil); code != http.StatusOK || out["status"] != "revoked" {
		t.Fatalf("second revoke must be idempotent: %d %v", code, out)
	}
}

// One link, one device. A forwarded link must be dead on arrival for whoever it
// was forwarded to.
func TestShare_OneDeviceBinding(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "binder@ex.com", "web")
	id := createShare(c, aTok, map[string]any{"ttl_seconds": 600})
	link := "/v1/share/" + id

	// First device opens the link and is handed the token.
	code, _, cookies := c.doShare(http.MethodGet, link, nil)
	if code != http.StatusOK {
		t.Fatalf("first GET: %d", code)
	}
	if len(cookies) != 1 {
		t.Fatalf("first GET must set the binding cookie, got %d cookies", len(cookies))
	}
	viewer := cookies[0]

	// A second device with the same link but no cookie is refused.
	code, body, second := c.doShare(http.MethodGet, link, nil)
	if code != http.StatusForbidden {
		t.Fatalf("second device without the cookie: %d %v, want 403", code, body)
	}
	if errCode(body) != "forbidden" {
		t.Errorf("error code = %q, want forbidden", errCode(body))
	}
	if len(second) != 0 {
		t.Fatal("a refused viewer must not be handed a cookie of their own")
	}

	// A wrong/forged token is refused just the same.
	forged := &http.Cookie{Name: viewer.Name, Value: "not-the-real-token"}
	if code, _, _ := c.doShare(http.MethodGet, link, []*http.Cookie{forged}); code != http.StatusForbidden {
		t.Fatalf("forged cookie: %d, want 403", code)
	}
	// A cookie minted for a *different* link must not unlock this one.
	otherID := createShare(c, aTok, map[string]any{"ttl_seconds": 600})
	_, _, otherCookies := c.doShare(http.MethodGet, "/v1/share/"+otherID, nil)
	crossed := &http.Cookie{Name: viewer.Name, Value: otherCookies[0].Value}
	if code, _, _ := c.doShare(http.MethodGet, link, []*http.Cookie{crossed}); code != http.StatusForbidden {
		t.Fatalf("another link's token: %d, want 403", code)
	}

	// The bound device keeps working, repeatedly.
	for i := range 3 {
		if code, _, _ := c.doShare(http.MethodGet, link, []*http.Cookie{viewer}); code != http.StatusOK {
			t.Fatalf("bound viewer GET #%d: %d, want 200", i, code)
		}
	}

	// The sharer sees that the link has been claimed.
	_, list := c.do(http.MethodGet, "/v1/share", aTok, nil)
	for _, ss := range list["sessions"].([]any) {
		s := ss.(map[string]any)
		if s["id"] == id && s["viewer_bound"] != true {
			t.Fatalf("session must report viewer_bound=true once opened: %v", s)
		}
	}
}

// A share is the sharer's alone: nobody else may feed it or kill it, and probing
// for someone else's link must not reveal that it exists.
func TestShare_OwnerOnly(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "owner-share@ex.com", "web")
	bTok, _ := register(c, "stranger-share@ex.com", "web")

	id := createShare(c, aTok, map[string]any{"ttl_seconds": 600})
	link := "/v1/share/" + id
	ping := map[string]any{
		"nonce": nonce24(), "ciphertext": b64("NOT-YOURS"),
		"captured_at": time.Now().UTC().Format(time.RFC3339),
	}

	// A stranger's ping and revoke both 404 — not 403, which would confirm the
	// link is real.
	if code, out := c.do(http.MethodPut, link+"/ping", bTok, ping); code != http.StatusNotFound {
		t.Fatalf("stranger ping: %d %v, want 404", code, out)
	}
	if code, out := c.do(http.MethodDelete, link, bTok, nil); code != http.StatusNotFound {
		t.Fatalf("stranger revoke: %d %v, want 404", code, out)
	}
	// The stranger's attempt changed nothing.
	if code, _ := c.do(http.MethodPut, link+"/ping", aTok, ping); code != http.StatusOK {
		t.Fatalf("owner ping after stranger's attempts: %d, want 200", code)
	}

	// Nor does a stranger's share list leak the owner's link.
	_, list := c.do(http.MethodGet, "/v1/share", bTok, nil)
	if n := len(list["sessions"].([]any)); n != 0 {
		t.Fatalf("stranger sees %d sessions, want 0", n)
	}
	// The owner's does.
	_, list = c.do(http.MethodGet, "/v1/share", aTok, nil)
	sessions := list["sessions"].([]any)
	if len(sessions) != 1 {
		t.Fatalf("owner sees %d sessions, want 1", len(sessions))
	}
	s := sessions[0].(map[string]any)
	if s["id"] != id || s["revoked"] != false || s["created_at"] == nil || s["expires_at"] == nil {
		t.Fatalf("unexpected session DTO: %v", s)
	}

	// Sharing requires an account even though viewing does not.
	if code, _ := c.do(http.MethodPost, "/v1/share", "", map[string]any{"ttl_seconds": 600}); code != http.StatusUnauthorized {
		t.Fatalf("anonymous create: %d, want 401", code)
	}
	if code, _ := c.do(http.MethodGet, "/v1/share", "", nil); code != http.StatusUnauthorized {
		t.Fatalf("anonymous list: %d, want 401", code)
	}
	if code, _ := c.do(http.MethodPut, link+"/ping", "", ping); code != http.StatusUnauthorized {
		t.Fatalf("anonymous ping: %d, want 401", code)
	}
}

// The server decides how long a share lives, whatever the client asks for.
func TestShare_TTLClampedAndDefaulted(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "ttl@ex.com", "web")

	expiryOf := func(body any) time.Duration {
		t.Helper()
		code, out := c.do(http.MethodPost, "/v1/share", aTok, body)
		if code != http.StatusCreated {
			t.Fatalf("create: %d %v", code, out)
		}
		exp, err := time.Parse(time.RFC3339, out["expires_at"].(string))
		if err != nil {
			t.Fatalf("expires_at must be RFC3339: %v", err)
		}
		return time.Until(exp)
	}

	const skew = 30 * time.Second
	// An hour is the ceiling: a day's request must not buy a day.
	if got := expiryOf(map[string]any{"ttl_seconds": 86400}); got > time.Hour+skew {
		t.Fatalf("ttl_seconds=86400 produced a %v share, want it clamped to ~1h", got)
	}
	// Nor may an overflow-sized request slip past the ceiling.
	if got := expiryOf(map[string]any{"ttl_seconds": int64(1) << 40}); got > time.Hour+skew {
		t.Fatalf("ttl_seconds=2^40 produced a %v share, want it clamped to ~1h", got)
	}
	// Under the floor clamps up to a minute.
	if got := expiryOf(map[string]any{"ttl_seconds": 1}); got < time.Minute-skew {
		t.Fatalf("ttl_seconds=1 produced a %v share, want it clamped up to ~60s", got)
	}
	// An omitted TTL means the 15-minute default.
	if got := expiryOf(map[string]any{}); got < 15*time.Minute-skew || got > 15*time.Minute+skew {
		t.Fatalf("omitted ttl produced a %v share, want ~15m", got)
	}
	// So does no body at all.
	if got := expiryOf(nil); got < 15*time.Minute-skew || got > 15*time.Minute+skew {
		t.Fatalf("bodyless create produced a %v share, want ~15m", got)
	}
	// An in-range request is honoured exactly.
	if got := expiryOf(map[string]any{"ttl_seconds": 300}); got < 5*time.Minute-skew || got > 5*time.Minute+skew {
		t.Fatalf("ttl_seconds=300 produced a %v share, want ~5m", got)
	}
}

// An expired link is gone for everyone — including the device it was bound to.
func TestShare_Expired(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "expiry@ex.com", "web")

	id := createShare(c, aTok, map[string]any{"ttl_seconds": 60})
	link := "/v1/share/" + id

	// Bind it while it is still live, then expire it under the viewer's feet.
	code, _, cookies := c.doShare(http.MethodGet, link, nil)
	if code != http.StatusOK {
		t.Fatalf("pre-expiry GET: %d", code)
	}
	viewer := cookies[0]
	expireShare(c, id)

	code, body, _ := c.doShare(http.MethodGet, link, []*http.Cookie{viewer})
	if code != http.StatusGone {
		t.Fatalf("bound viewer after expiry: %d %v, want 410", code, body)
	}
	if errCode(body) != "gone" {
		t.Errorf("error code = %q, want gone", errCode(body))
	}
	// The owner cannot feed a dead link either.
	if code, out := c.do(http.MethodPut, link+"/ping", aTok, map[string]any{
		"nonce": nonce24(), "ciphertext": b64("EXPIRED"), "captured_at": time.Now().UTC().Format(time.RFC3339),
	}); code != http.StatusGone {
		t.Fatalf("owner ping after expiry: %d %v, want 410", code, out)
	}
	// An expired link drops out of the owner's list.
	_, list := c.do(http.MethodGet, "/v1/share", aTok, nil)
	if n := len(list["sessions"].([]any)); n != 0 {
		t.Fatalf("expired session still listed (%d sessions)", n)
	}

	// An expired, never-opened link must not bind on the way out: 410 beats the
	// binding path, so no cookie is minted for a dead session.
	deadID := createShare(c, aTok, map[string]any{"ttl_seconds": 60})
	expireShare(c, deadID)
	code, _, minted := c.doShare(http.MethodGet, "/v1/share/"+deadID, nil)
	if code != http.StatusGone {
		t.Fatalf("expired unbound link: %d, want 410", code)
	}
	if len(minted) != 0 {
		t.Fatal("a dead link must never mint a viewer cookie")
	}
	var bound int
	if err := c.qRow(context.Background(),
		`SELECT count(*) FROM share_sessions WHERE id = $1 AND viewer_token_hash IS NOT NULL`, deadID).Scan(&bound); err != nil {
		t.Fatalf("check binding: %v", err)
	}
	if bound != 0 {
		t.Fatal("a dead link must not be bound by a viewer's GET")
	}
}

// An id nobody ever issued is a 404 — distinct from a link that has died.
func TestShare_Unknown(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "unknown@ex.com", "web")

	for _, id := range []string{
		"00000000-0000-0000-0000-000000000000", // well-formed, never issued
		"not-a-uuid",                           // malformed
	} {
		code, body, cookies := c.doShare(http.MethodGet, "/v1/share/"+id, nil)
		if code != http.StatusNotFound {
			t.Fatalf("GET unknown share %q: %d %v, want 404", id, code, body)
		}
		if errCode(body) != "not_found" {
			t.Errorf("GET %q error code = %q, want not_found", id, errCode(body))
		}
		if len(cookies) != 0 {
			t.Errorf("GET %q must not set a cookie", id)
		}
		if code, _ := c.do(http.MethodDelete, "/v1/share/"+id, aTok, nil); code != http.StatusNotFound {
			t.Errorf("DELETE unknown share %q: %d, want 404", id, code)
		}
		if code, _ := c.do(http.MethodPut, "/v1/share/"+id+"/ping", aTok, map[string]any{
			"nonce": nonce24(), "ciphertext": b64("X"), "captured_at": time.Now().UTC().Format(time.RFC3339),
		}); code != http.StatusNotFound {
			t.Errorf("PUT ping to unknown share %q: %d, want 404", id, code)
		}
	}
}

// The share path must reject the same malformed blobs the ping batch does — it
// is the same opaque-ciphertext contract, and a plaintext-shaped body must never
// find a home here.
func TestShare_PingValidation(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "shareval@ex.com", "web")
	id := createShare(c, aTok, map[string]any{"ttl_seconds": 600})
	path := "/v1/share/" + id + "/ping"
	now := time.Now().UTC().Format(time.RFC3339)

	cases := []struct {
		name string
		body map[string]any
	}{
		{"non-base64 ciphertext", map[string]any{"nonce": nonce24(), "ciphertext": "!!!not base64!!!", "captured_at": now}},
		{"missing ciphertext", map[string]any{"nonce": nonce24(), "captured_at": now}},
		{"missing nonce", map[string]any{"ciphertext": b64("X"), "captured_at": now}},
		{"oversized ciphertext", map[string]any{"nonce": nonce24(), "ciphertext": b64(string(make([]byte, 5000))), "captured_at": now}},
		{"oversized nonce", map[string]any{"nonce": b64(string(make([]byte, 64))), "ciphertext": b64("X"), "captured_at": now}},
		{"captured_at not RFC3339", map[string]any{"nonce": nonce24(), "ciphertext": b64("X"), "captured_at": "yesterday"}},
		{"captured_at far in the future", map[string]any{"nonce": nonce24(), "ciphertext": b64("X"), "captured_at": time.Now().UTC().Add(time.Hour).Format(time.RFC3339)}},
		{"captured_at older than any share could be", map[string]any{"nonce": nonce24(), "ciphertext": b64("X"), "captured_at": time.Now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)}},
		{"plaintext coordinates have no field to land in", map[string]any{"lat": 43.238949, "lng": 76.889709, "captured_at": now}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if code, out := c.do(http.MethodPut, path, aTok, tc.body); code != http.StatusBadRequest {
				t.Fatalf("%s: %d %v, want 400", tc.name, code, out)
			}
		})
	}

	// Nothing above was stored: a rejected ping leaves the share blank.
	_, _, cookies := c.doShare(http.MethodGet, "/v1/share/"+id, nil)
	_, body, _ := c.doShare(http.MethodGet, "/v1/share/"+id, cookies)
	if body["position"] != nil {
		t.Fatalf("a rejected ping must store nothing, got %v", body["position"])
	}
}

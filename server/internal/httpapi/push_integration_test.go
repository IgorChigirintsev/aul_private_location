//go:build integration

package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	webpush "github.com/SherClockHolmes/webpush-go"
	"golang.org/x/oauth2"

	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/fcm"
	"github.com/aul-app/aul/server/internal/httpapi"
)

// stubPushService stands in for a real push service (FCM, Mozilla, …). It
// records the endpoints it was called on and answers per-path: an endpoint
// whose path contains "gone" replies 410, the standard "this subscription is
// dead, stop sending" signal.
type stubPushService struct {
	*httptest.Server
	mu   sync.Mutex
	hits []string
}

func newStubPushService(t *testing.T) *stubPushService {
	t.Helper()
	s := &stubPushService{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.hits = append(s.hits, r.URL.Path)
		s.mu.Unlock()
		if strings.Contains(r.URL.Path, "gone") {
			w.WriteHeader(http.StatusGone)
			return
		}
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *stubPushService) calledPaths() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.hits...)
}

// reset forgets recorded hits so a test can assert on a second fan-out
// independently of the first.
func (s *stubPushService) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hits = nil
}

// subscribeKeys mints a real P-256 subscription keypair; the server encrypts to
// the public half per RFC 8291 and never decrypts.
func subscribeKeys(t *testing.T) (p256dh, auth string) {
	t.Helper()
	priv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate subscription key: %v", err)
	}
	secret := make([]byte, 16)
	if _, err := rand.Read(secret); err != nil {
		t.Fatalf("generate auth secret: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes()),
		base64.RawURLEncoding.EncodeToString(secret)
}

// newPushServer starts an API server with Web Push enabled by a real VAPID key.
func newPushServer(t *testing.T) *apiClient {
	t.Helper()
	priv, pub, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatalf("generate vapid keys: %v", err)
	}
	return newTestServerWith(t, func(c *config.Config) {
		c.VAPIDPublicKey, c.VAPIDPrivateKey = pub, priv
		c.VAPIDSubject = "mailto:ops@aul.app"
	})
}

// subscribe registers a push subscription for the caller pointing at endpoint.
func subscribe(c *apiClient, token, endpoint string) {
	c.t.Helper()
	p256dh, auth := subscribeKeys(c.t)
	code, body := c.do(http.MethodPost, "/v1/push/subscribe", token, map[string]any{
		"endpoint": endpoint, "p256dh": p256dh, "auth": auth,
	})
	if code != http.StatusCreated {
		c.t.Fatalf("subscribe: %d %v", code, body)
	}
}

// circleWithTwoMembers creates a circle owned by alice with bob joined.
func circleWithTwoMembers(c *apiClient, aTok, bTok string) string {
	c.t.Helper()
	code, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	if code != http.StatusCreated {
		c.t.Fatalf("create circle: %d %v", code, circle)
	}
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 5})
	code, acc := c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil)
	if code != http.StatusOK {
		c.t.Fatalf("accept invite: %d %v", code, acc)
	}
	return circleID
}

func (c *apiClient) countSubscriptions(endpoint string) int {
	c.t.Helper()
	var n int
	err := c.qRow(context.Background(),
		`SELECT count(*) FROM push_subscriptions WHERE endpoint = $1`, endpoint).Scan(&n)
	if err != nil {
		c.t.Fatalf("count subscriptions: %v", err)
	}
	return n
}

// The fan-out reaches every other member and never the sender.
func TestPush_NotifyExcludesSender(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	subscribe(c, aTok, push.URL+"/alice")
	subscribe(c, bTok, push.URL+"/bob")

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	if int(body["sent"].(float64)) != 1 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=1 failed=0", body)
	}
	// Alice must not be notified of her own event.
	paths := push.calledPaths()
	if len(paths) != 1 || paths[0] != "/bob" {
		t.Fatalf("push service saw %v, want only /bob", paths)
	}
	// The response carries counts only — no endpoints, no plaintext.
	for _, k := range []string{"endpoint", "endpoints", "payload_enc", "subscriptions"} {
		if _, ok := body[k]; ok {
			t.Errorf("notify response leaked %q", k)
		}
	}
}

// A subscription the push service reports as gone (410) must be deleted.
func TestPush_PrunesGoneSubscriptions(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	dead := push.URL + "/bob-gone"
	subscribe(c, bTok, dead)
	if c.countSubscriptions(dead) != 1 {
		t.Fatal("subscription should exist before notify")
	}

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	// A gone subscription is not a delivery.
	if int(body["sent"].(float64)) != 0 || int(body["failed"].(float64)) != 1 {
		t.Fatalf("counts = %v, want sent=0 failed=1", body)
	}
	if n := c.countSubscriptions(dead); n != 0 {
		t.Fatalf("dead subscription still stored (%d rows); 410 must prune it", n)
	}
}

// Only members may notify a circle; a stranger cannot even learn it exists.
func TestPush_NotifyIsMemberOnly(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	sTok, _ := register(c, "stranger@ex.com", "web")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	subscribe(c, bTok, push.URL+"/bob")

	code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", sTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusNotFound {
		t.Fatalf("stranger notify: expected 404, got %d", code)
	}
	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", "", map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	}); code != http.StatusUnauthorized {
		t.Fatalf("anonymous notify: expected 401, got %d", code)
	}
	if paths := push.calledPaths(); len(paths) != 0 {
		t.Fatalf("no push should have been sent, saw %v", paths)
	}
}

// With no VAPID keys configured the endpoint is unavailable, and server-info
// advertises no key so clients know not to try subscribing.
func TestPush_DisabledWithoutKeys(t *testing.T) {
	c := newTestServer(t) // no VAPID config

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusServiceUnavailable {
		t.Fatalf("notify with push disabled: expected 503, got %d (%v)", code, body)
	}

	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	if v, ok := info["vapid_public_key"]; !ok || v != nil {
		t.Fatalf("vapid_public_key = %v, want null when push is disabled", v)
	}
}

// server-info publishes the VAPID public key clients need as applicationServerKey.
func TestPush_ServerInfoAdvertisesVAPIDKey(t *testing.T) {
	c := newPushServer(t)
	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	key, ok := info["vapid_public_key"].(string)
	if !ok || key == "" {
		t.Fatalf("vapid_public_key = %v, want the public key", info["vapid_public_key"])
	}
	// It must be the PUBLIC key: decodes to a 65-byte P-256 point.
	raw, err := base64.RawURLEncoding.DecodeString(key)
	if err != nil {
		t.Fatalf("vapid_public_key is not base64url: %v", err)
	}
	if len(raw) != 65 {
		t.Fatalf("vapid_public_key decodes to %d bytes, want 65", len(raw))
	}
}

// --- FCM: the second channel (Android) ---

// stubFCMService stands in for the FCM v1 API. It records every message body
// and answers UNREGISTERED for any token containing "dead" — Google's "this
// registration is gone" signal, the FCM spelling of Web Push's 410.
type stubFCMService struct {
	*httptest.Server
	mu     sync.Mutex
	bodies [][]byte
}

func newStubFCMService(t *testing.T) *stubFCMService {
	t.Helper()
	s := &stubFCMService{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.bodies = append(s.bodies, body)
		s.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		if bytes.Contains(body, []byte("dead")) {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"code":404,"status":"NOT_FOUND","details":`+
				`[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}`)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"name":"projects/e2ee-test/messages/1"}`)
	}))
	t.Cleanup(s.Close)
	return s
}

// sentTokens returns the registration token of every message the stub received.
func (s *stubFCMService) sentTokens(t *testing.T) []string {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for _, b := range s.bodies {
		var m struct {
			Message struct {
				Token string `json:"token"`
			} `json:"message"`
		}
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatalf("stub got a body that is not an FCM message: %v", err)
		}
		out = append(out, m.Message.Token)
	}
	return out
}

func (s *stubFCMService) messages() [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([][]byte(nil), s.bodies...)
}

// fcmDeps aims the server's FCM channel at a stub. The token source is static,
// so the real request path runs without a credential and without ever reaching
// Google.
func fcmDeps(stub *stubFCMService) func(*httpapi.Deps) {
	return func(d *httpapi.Deps) {
		d.FCM = fcm.NewWithTokenSource("e2ee-test",
			oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "test-token", TokenType: "Bearer"}),
			fcm.WithBaseURL(stub.URL))
	}
}

// newBothChannelServer starts a server with Web Push AND FCM enabled.
func newBothChannelServer(t *testing.T, stub *stubFCMService) *apiClient {
	t.Helper()
	priv, pub, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatalf("generate vapid keys: %v", err)
	}
	return newTestServerWithDeps(t, func(c *config.Config) {
		c.VAPIDPublicKey, c.VAPIDPrivateKey = pub, priv
		c.VAPIDSubject = "mailto:ops@aul.app"
	}, fcmDeps(stub))
}

// subscribeFCM registers an Android registration token for the caller.
func subscribeFCM(c *apiClient, token, regToken string) {
	c.t.Helper()
	code, body := c.do(http.MethodPost, "/v1/push/subscribe", token, map[string]any{
		"kind": "fcm", "token": regToken,
	})
	if code != http.StatusCreated {
		c.t.Fatalf("subscribe fcm: %d %v", code, body)
	}
}

// An FCM subscription stores the token in endpoint with NO key material: the
// row shape migration 00008 defines (and its CHECK enforces).
func TestPush_FCMSubscribeStoresTokenRow(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)
	aTok, _ := register(c, "alice@ex.com", "android")

	const regToken = "fZx9:APA91bH-alice-device"
	subscribeFCM(c, aTok, regToken)

	var kind string
	var p256dh, auth *string
	err := c.qRow(context.Background(),
		`SELECT kind, p256dh, auth FROM push_subscriptions WHERE endpoint = $1`, regToken).
		Scan(&kind, &p256dh, &auth)
	if err != nil {
		t.Fatalf("read subscription: %v", err)
	}
	if kind != "fcm" {
		t.Errorf("kind = %q, want fcm", kind)
	}
	if p256dh != nil || auth != nil {
		t.Errorf("p256dh=%v auth=%v, want both NULL for an fcm row", p256dh, auth)
	}
}

// The two shapes are kept apart at the API boundary.
func TestPush_SubscribeKindValidation(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)
	aTok, _ := register(c, "alice@ex.com", "android")
	p256dh, auth := subscribeKeys(t)

	cases := []struct {
		name string
		body map[string]any
		want int
	}{
		{"fcm token", map[string]any{"kind": "fcm", "token": "tok-ok"}, http.StatusCreated},
		{"webpush unchanged", map[string]any{
			"endpoint": "https://push.example.com/x", "p256dh": p256dh, "auth": auth,
		}, http.StatusCreated},
		{"webpush with explicit kind", map[string]any{
			"kind": "webpush", "endpoint": "https://push.example.com/y", "p256dh": p256dh, "auth": auth,
		}, http.StatusCreated},
		{"fcm without token", map[string]any{"kind": "fcm"}, http.StatusBadRequest},
		{"fcm with empty token", map[string]any{"kind": "fcm", "token": ""}, http.StatusBadRequest},
		{"fcm carrying web push keys", map[string]any{
			"kind": "fcm", "token": "tok", "p256dh": p256dh, "auth": auth,
		}, http.StatusBadRequest},
		{"fcm token too long", map[string]any{
			"kind": "fcm", "token": strings.Repeat("t", 4097),
		}, http.StatusBadRequest},
		{"unknown kind", map[string]any{"kind": "apns", "token": "tok"}, http.StatusBadRequest},
		{"webpush missing auth", map[string]any{
			"endpoint": "https://push.example.com/z", "p256dh": p256dh,
		}, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			code, body := c.do(http.MethodPost, "/v1/push/subscribe", aTok, tc.body)
			if code != tc.want {
				t.Fatalf("status = %d, want %d (%v)", code, tc.want, body)
			}
		})
	}
}

// An fcm row's endpoint IS its token, so DELETE /v1/push/subscribe unsubscribes
// it by either spelling — {"endpoint":tok} (the pre-existing contract) or
// {"token":tok} (what an Android client would naturally send).
func TestPush_FCMUnsubscribeByTokenOrEndpoint(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)
	aTok, _ := register(c, "alice@ex.com", "android")

	for _, field := range []string{"token", "endpoint"} {
		t.Run("delete by "+field, func(t *testing.T) {
			regToken := "fZx9:APA91bH-" + field
			subscribeFCM(c, aTok, regToken)
			if c.countSubscriptions(regToken) != 1 {
				t.Fatal("subscription should exist before delete")
			}
			code, body := c.do(http.MethodDelete, "/v1/push/subscribe", aTok,
				map[string]any{field: regToken})
			if code != http.StatusOK {
				t.Fatalf("unsubscribe: %d %v", code, body)
			}
			if n := c.countSubscriptions(regToken); n != 0 {
				t.Fatalf("subscription still stored (%d rows) after unsubscribe by %s", n, field)
			}
		})
	}
}

// THE E2EE INVARIANT, end to end: a real /notify request must put a data-only
// message on the wire. Android renders a `notification` message itself, which
// would mean plaintext — the blob is sealed under K_c precisely so neither
// Google nor this server can read it.
func TestPush_FCMNotifyIsDataOnly(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	subscribeFCM(c, bTok, "fZx9:APA91bH-bob-device")

	sealed := b64("sealed-under-K_c")
	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": sealed,
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}

	msgs := stub.messages()
	if len(msgs) != 1 {
		t.Fatalf("FCM saw %d messages, want 1", len(msgs))
	}
	var got struct {
		Message map[string]json.RawMessage `json:"message"`
	}
	if err := json.Unmarshal(msgs[0], &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, ok := got.Message["notification"]; ok {
		t.Fatalf("E2EE VIOLATION: /notify sent a notification message: %s", msgs[0])
	}
	if bytes.Contains(bytes.ToLower(msgs[0]), []byte("notification")) {
		t.Fatalf("E2EE VIOLATION: %q appears in the outgoing FCM body: %s", "notification", msgs[0])
	}

	// The blob crosses to Google exactly as the client sealed it.
	var data struct {
		Message struct {
			Data map[string]string `json:"data"`
		} `json:"message"`
	}
	if err := json.Unmarshal(msgs[0], &data); err != nil {
		t.Fatalf("unmarshal data: %v", err)
	}
	if data.Message.Data["payload_enc"] != sealed {
		t.Fatalf("data.payload_enc = %q, want the sealed blob %q", data.Message.Data["payload_enc"], sealed)
	}
	// And the plaintext it hides is nowhere in the request.
	if bytes.Contains(msgs[0], []byte("sealed-under-K_c")) {
		t.Fatal("the notification plaintext reached FCM")
	}
}

// One fan-out, both channels: every non-muted member is reached wherever they
// registered, and the counts cover both.
func TestPush_NotifyFansOutToBothChannels(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)
	web := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	// Bob has both a browser and a phone; alice is the sender.
	subscribe(c, aTok, web.URL+"/alice")
	subscribe(c, bTok, web.URL+"/bob-browser")
	subscribeFCM(c, bTok, "fZx9:APA91bH-bob-phone")

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	// Both of Bob's devices, neither of Alice's.
	if int(body["sent"].(float64)) != 2 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=2 failed=0 (one per channel)", body)
	}
	if paths := web.calledPaths(); len(paths) != 1 || paths[0] != "/bob-browser" {
		t.Fatalf("web push saw %v, want only /bob-browser", paths)
	}
	if toks := stub.sentTokens(t); len(toks) != 1 || toks[0] != "fZx9:APA91bH-bob-phone" {
		t.Fatalf("fcm saw %v, want only bob's phone", toks)
	}
}

// The mute filter (D-0053) is channel-agnostic: muting silences every device a
// member owns, not just their browser.
func TestPush_MuteSilencesBothChannels(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)
	web := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	subscribe(c, bTok, web.URL+"/bob-browser")
	subscribeFCM(c, bTok, "fZx9:APA91bH-bob-phone")

	// Bob mutes the whole circle.
	setMutes(c, circleID, bTok, true, nil)

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	// A muted member is not a recipient on ANY channel — and the counts do not
	// reveal to the sender that anyone muted them.
	if int(body["sent"].(float64)) != 0 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=0 failed=0", body)
	}
	if paths := web.calledPaths(); len(paths) != 0 {
		t.Fatalf("web push saw %v, want nothing: bob muted the circle", paths)
	}
	if toks := stub.sentTokens(t); len(toks) != 0 {
		t.Fatalf("fcm saw %v, want nothing: bob muted the circle", toks)
	}
}

// FCM's UNREGISTERED is the same contract as Web Push 410: the registration is
// dead, so the row must go — or every future notify wastes a send on it.
func TestPush_FCMPrunesUnregisteredToken(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	const deadToken = "fZx9:APA91bH-bob-dead-phone" // the stub answers UNREGISTERED
	subscribeFCM(c, bTok, deadToken)
	if c.countSubscriptions(deadToken) != 1 {
		t.Fatal("subscription should exist before notify")
	}

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	if int(body["sent"].(float64)) != 0 || int(body["failed"].(float64)) != 1 {
		t.Fatalf("counts = %v, want sent=0 failed=1", body)
	}
	if n := c.countSubscriptions(deadToken); n != 0 {
		t.Fatalf("dead token still stored (%d rows); UNREGISTERED must prune it", n)
	}
}

// Either channel alone is a working deployment. With FCM unconfigured, Web Push
// still delivers — and an Android token that was registered anyway is simply
// not a recipient, not a counted failure.
func TestPush_WebPushStillDeliversWithFCMDisabled(t *testing.T) {
	c := newPushServer(t) // VAPID only: no FCM client wired
	web := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	subscribe(c, bTok, web.URL+"/bob-browser")
	subscribeFCM(c, bTok, "fZx9:APA91bH-bob-phone") // accepted, but undeliverable here

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	if int(body["sent"].(float64)) != 1 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=1 failed=0: web push delivers, the fcm row is not a recipient", body)
	}
	if paths := web.calledPaths(); len(paths) != 1 || paths[0] != "/bob-browser" {
		t.Fatalf("web push saw %v, want /bob-browser", paths)
	}

	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	if info["fcm_enabled"] != false {
		t.Fatalf("fcm_enabled = %v, want false", info["fcm_enabled"])
	}
}

// The mirror image: FCM alone, no VAPID. /notify must work.
func TestPush_FCMDeliversWithWebPushDisabled(t *testing.T) {
	stub := newStubFCMService(t)
	c := newTestServerWithDeps(t, nil, fcmDeps(stub)) // no VAPID keys

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	subscribeFCM(c, bTok, "fZx9:APA91bH-bob-phone")

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify with only FCM configured: %d %v (it must not 503)", code, body)
	}
	if int(body["sent"].(float64)) != 1 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=1 failed=0", body)
	}

	// server-info tells the truth about each channel independently.
	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	if info["fcm_enabled"] != true {
		t.Fatalf("fcm_enabled = %v, want true", info["fcm_enabled"])
	}
	if v, ok := info["vapid_public_key"]; !ok || v != nil {
		t.Fatalf("vapid_public_key = %v, want null when Web Push is disabled", v)
	}
}

// server-info advertises the FCM channel so a client knows whether asking
// Google for a registration token is worth anything.
func TestPush_ServerInfoAdvertisesFCM(t *testing.T) {
	stub := newStubFCMService(t)
	c := newBothChannelServer(t, stub)

	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	if info["fcm_enabled"] != true {
		t.Fatalf("fcm_enabled = %v, want true", info["fcm_enabled"])
	}
	// Nothing about the Firebase project may leak: the app ships its own
	// google-services.json and the server's credential is a secret.
	for _, k := range []string{"fcm_project_id", "fcm_service_account", "project_id", "fcm_credentials"} {
		if _, ok := info[k]; ok {
			t.Errorf("server-info leaked %q", k)
		}
	}
}

// With neither channel configured /notify is unavailable and server-info says
// so on both keys.
func TestPush_BothChannelsDisabled(t *testing.T) {
	c := newTestServer(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)

	code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusServiceUnavailable {
		t.Fatalf("notify with no channel: expected 503, got %d", code)
	}
	_, info := c.do(http.MethodGet, "/v1/server-info", "", nil)
	if info["fcm_enabled"] != false {
		t.Fatalf("fcm_enabled = %v, want false", info["fcm_enabled"])
	}
	if v := info["vapid_public_key"]; v != nil {
		t.Fatalf("vapid_public_key = %v, want null", v)
	}
}

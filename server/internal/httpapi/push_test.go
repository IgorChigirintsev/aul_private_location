package httpapi

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/google/uuid"
	"golang.org/x/oauth2"

	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/fcm"
	"github.com/aul-app/aul/server/internal/store"
)

// pushCfg builds a config with push either enabled (real-looking VAPID keys) or
// disabled. The keys are never used here: every case in this file is rejected
// during validation, before any push is sent or the store is touched — which is
// why a nil store is safe.
func pushCfg(t *testing.T, enabled bool) *config.Config {
	t.Helper()
	origin, err := url.Parse("https://aul.example.com")
	if err != nil {
		t.Fatalf("parse origin: %v", err)
	}
	c := &config.Config{PublicOrigin: origin}
	if enabled {
		c.VAPIDPublicKey = base64.RawURLEncoding.EncodeToString(make([]byte, 65))
		c.VAPIDPrivateKey = base64.RawURLEncoding.EncodeToString(make([]byte, 32))
		c.VAPIDSubject = "mailto:ops@aul.app"
	}
	return c
}

func notifyRequest(t *testing.T, body any) *http.Request {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/circles/"+
		"00000000-0000-0000-0000-000000000001/notify", bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	return r
}

func TestHandleNotify_Validation(t *testing.T) {
	// A blob that decodes to exactly the documented 3 KiB cap.
	atCap := base64.StdEncoding.EncodeToString(make([]byte, maxNotifyBytes))
	// One byte over the cap.
	overCap := base64.StdEncoding.EncodeToString(make([]byte, maxNotifyBytes+1))
	// Comfortably deliverable.
	small := base64.StdEncoding.EncodeToString([]byte("sealed-under-K_c"))

	cases := []struct {
		name       string
		pushOn     bool
		body       any
		wantStatus int
		wantMsg    string
	}{
		{
			name:       "push disabled short-circuits before validation",
			pushOn:     false,
			body:       map[string]any{"payload_enc": small},
			wantStatus: http.StatusServiceUnavailable,
			wantMsg:    "push is not configured",
		},
		{
			name:       "disabled beats a malformed body",
			pushOn:     false,
			body:       map[string]any{"payload_enc": "!!!not base64!!!"},
			wantStatus: http.StatusServiceUnavailable,
			wantMsg:    "push is not configured",
		},
		{
			name:       "non-base64 payload",
			pushOn:     true,
			body:       map[string]any{"payload_enc": "!!!not base64!!!"},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "must be base64",
		},
		{
			name:       "missing payload",
			pushOn:     true,
			body:       map[string]any{},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "required",
		},
		{
			name:       "empty payload",
			pushOn:     true,
			body:       map[string]any{"payload_enc": ""},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "required",
		},
		{
			name:       "oversized payload",
			pushOn:     true,
			body:       map[string]any{"payload_enc": overCap},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "exceeds",
		},
		{
			name:       "unknown field",
			pushOn:     true,
			body:       map[string]any{"payload": small},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "invalid JSON",
		},
		{
			// 3 KiB decoded is within the documented cap but its base64 form is
			// 4096 bytes — past what a 4 KiB Web Push record can carry. The
			// client learns now rather than seeing every send silently fail.
			name:       "at the decoded cap but undeliverable as base64",
			pushOn:     true,
			body:       map[string]any{"payload_enc": atCap},
			wantStatus: http.StatusBadRequest,
			wantMsg:    "web push payload limit",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := NewServer(Deps{Config: pushCfg(t, tc.pushOn)})
			w := httptest.NewRecorder()

			s.handleNotify(w, notifyRequest(t, tc.body))

			if w.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body: %s)", w.Code, tc.wantStatus, w.Body)
			}
			if !strings.Contains(w.Body.String(), tc.wantMsg) {
				t.Fatalf("body = %s, want it to mention %q", w.Body, tc.wantMsg)
			}
			// No handler may ever echo the payload back.
			if strings.Contains(w.Body.String(), small) && tc.wantStatus != http.StatusOK {
				t.Fatal("error response must not echo the sealed payload")
			}
		})
	}
}

// testSubscription mints a real P-256 subscription keypair so webpush actually
// performs RFC 8291 encryption against it. Only the public half is needed: the
// server encrypts, it never decrypts.
func testSubscription(t *testing.T, endpoint string) store.ListCirclePushSubscriptionsRow {
	t.Helper()
	priv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate subscription key: %v", err)
	}
	auth := make([]byte, 16)
	if _, err := rand.Read(auth); err != nil {
		t.Fatalf("generate auth secret: %v", err)
	}
	return store.ListCirclePushSubscriptionsRow{
		ID:       uuid.New(),
		UserID:   uuid.New(),
		Endpoint: endpoint,
		P256dh:   ptr(base64.RawURLEncoding.EncodeToString(priv.PublicKey().Bytes())),
		Auth:     ptr(base64.RawURLEncoding.EncodeToString(auth)),
		Kind:     kindWebPush,
	}
}

func ptr[T any](v T) *T { return &v }

// pushEnabledServer builds a Server with a real VAPID keypair, so JWT signing
// and payload encryption run for real.
func pushEnabledServer(t *testing.T) *Server {
	t.Helper()
	priv, pub, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		t.Fatalf("generate vapid keys: %v", err)
	}
	cfg := pushCfg(t, false)
	cfg.VAPIDPublicKey, cfg.VAPIDPrivateKey = pub, priv
	cfg.VAPIDSubject = "mailto:ops@aul.app"
	return NewServer(Deps{Config: cfg})
}

// maxPushPlaintextBytes is derived from RFC 8291 record math, so it must match
// what webpush-go actually accepts — if the library changes its padding, this
// catches it rather than every large notification silently failing in prod.
func TestMaxPushPlaintextMatchesLibrary(t *testing.T) {
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	defer stub.Close()

	s := pushEnabledServer(t)
	sub := testSubscription(t, stub.URL)

	if err := s.sendPush(t.Context(), sub, make([]byte, maxPushPlaintextBytes)); err != nil {
		t.Fatalf("a %d-byte payload must be sendable, got: %v", maxPushPlaintextBytes, err)
	}
	err := s.sendPush(t.Context(), sub, make([]byte, maxPushPlaintextBytes+1))
	if !errors.Is(err, webpush.ErrMaxPadExceeded) {
		t.Fatalf("a %d-byte payload must exceed the record, got: %v", maxPushPlaintextBytes+1, err)
	}

	// The endpoint's own cap must sit inside that ceiling: the largest base64
	// string we accept is maxPushPlaintextBytes bytes, which is exactly the
	// largest the library will send.
	largestAccepted := base64.StdEncoding.EncodeToString(make([]byte, maxNotifyBytes))
	if len(largestAccepted) <= maxPushPlaintextBytes {
		t.Fatal("maxNotifyBytes now fits the record; the second size check is dead code")
	}
}

// The fan-out must deliver to every subscription, count honestly, and put the
// sealed blob on the wire only under RFC 8291 encryption.
func TestFanOutPush_CountsAndEncrypts(t *testing.T) {
	payload := []byte(base64.StdEncoding.EncodeToString([]byte("sealed-under-K_c-abcdef")))

	var mu sync.Mutex
	var bodies [][]byte
	var headers []http.Header
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, body)
		headers = append(headers, r.Header.Clone())
		mu.Unlock()
		if strings.HasSuffix(r.URL.Path, "/broken") {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer stub.Close()

	s := pushEnabledServer(t)
	subs := []store.ListCirclePushSubscriptionsRow{
		testSubscription(t, stub.URL+"/a"),
		testSubscription(t, stub.URL+"/b"),
		testSubscription(t, stub.URL+"/c"),
		testSubscription(t, stub.URL+"/broken"),
	}

	sent, failed := s.fanOutPush(t.Context(), subs, payload)
	if sent != 3 || failed != 1 {
		t.Fatalf("sent=%d failed=%d, want sent=3 failed=1", sent, failed)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != len(subs) {
		t.Fatalf("push service saw %d requests, want %d", len(bodies), len(subs))
	}
	for i, body := range bodies {
		// The blob must never reach the push service in the clear: Web Push
		// encrypts it again to the subscription's own keys.
		if bytes.Contains(body, payload) {
			t.Fatal("payload reached the push service unencrypted")
		}
		if got := headers[i].Get("Content-Encoding"); got != "aes128gcm" {
			t.Errorf("Content-Encoding = %q, want aes128gcm", got)
		}
		if got := headers[i].Get("TTL"); got != itoa(pushTTLSeconds) {
			t.Errorf("TTL = %q, want %d", got, pushTTLSeconds)
		}
		if got := headers[i].Get("Urgency"); got != "normal" {
			t.Errorf("Urgency = %q, want normal", got)
		}
		if !strings.HasPrefix(headers[i].Get("Authorization"), "vapid t=") {
			t.Errorf("missing VAPID Authorization header: %q", headers[i].Get("Authorization"))
		}
	}
}

// Subscription key material is attacker-supplied, and the fan-out workers run
// outside the Recoverer middleware: a hostile subscription must fail alone, not
// take the server (or the other members' notifications) down with it.
func TestFanOutPush_HostileSubscriptionCannotCrashFanOut(t *testing.T) {
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	defer stub.Close()

	s := pushEnabledServer(t)
	good := testSubscription(t, stub.URL+"/good")

	junk := []store.ListCirclePushSubscriptionsRow{}
	for _, bad := range []struct{ p256dh, auth string }{
		{"", ""},         // empty key material
		{"!!!!", "!!!!"}, // not base64
		{"AAAA", "AAAA"}, // too short to be a P-256 point
		{base64.RawURLEncoding.EncodeToString(make([]byte, 65)), "AAAA"}, // 65 zero bytes: not on the curve
		{base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0xff}, 65)), ""},
	} {
		junk = append(junk, store.ListCirclePushSubscriptionsRow{
			ID: uuid.New(), UserID: uuid.New(), Kind: kindWebPush,
			Endpoint: stub.URL + "/bad", P256dh: ptr(bad.p256dh), Auth: ptr(bad.auth),
		})
	}
	subs := append(junk, good)

	sent, failed := s.fanOutPush(t.Context(), subs, []byte("payload"))
	if sent != 1 {
		t.Fatalf("sent=%d, want 1: the valid subscription must still be delivered", sent)
	}
	if failed != len(junk) {
		t.Fatalf("failed=%d, want %d", failed, len(junk))
	}
}

func TestFanOutPush_NoSubscriptions(t *testing.T) {
	s := pushEnabledServer(t)
	if sent, failed := s.fanOutPush(t.Context(), nil, []byte("x")); sent != 0 || failed != 0 {
		t.Fatalf("sent=%d failed=%d, want 0/0", sent, failed)
	}
}

// --- FCM channel ---

// withFCM points a server's FCM channel at a stub. A static token source keeps
// the real request path (Authorization header and all) while never touching
// Google.
func withFCM(s *Server, baseURL string) *Server {
	s.fcm = fcm.NewWithTokenSource("test-project",
		oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "test-token", TokenType: "Bearer"}),
		fcm.WithBaseURL(baseURL))
	return s
}

// testFCMSubscription is an Android row: the registration token lives in
// endpoint and there is no key material at all (migration 00008).
func testFCMSubscription(token string) store.ListCirclePushSubscriptionsRow {
	return store.ListCirclePushSubscriptionsRow{
		ID: uuid.New(), UserID: uuid.New(), Endpoint: token, Kind: kindFCM,
	}
}

// THE E2EE INVARIANT, at the layer that builds the message. internal/fcm proves
// its own body is data-only; this proves the fan-out asks for a data-only
// message and hands over the sealed blob unmodified. If this fails, Android
// notifications are no longer end-to-end encrypted.
func TestFanOutPush_FCMIsDataOnlyAndOpaque(t *testing.T) {
	payload := []byte(base64.StdEncoding.EncodeToString([]byte("sealed-under-K_c-abcdef")))

	var mu sync.Mutex
	var bodies [][]byte
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, b)
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"name":"projects/p/messages/1"}`)
	}))
	defer stub.Close()

	s := withFCM(pushEnabledServer(t), stub.URL)
	sent, failed := s.fanOutPush(t.Context(), []store.ListCirclePushSubscriptionsRow{
		testFCMSubscription("android-token-1"),
	}, payload)
	if sent != 1 || failed != 0 {
		t.Fatalf("sent=%d failed=%d, want 1/0", sent, failed)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != 1 {
		t.Fatalf("FCM saw %d requests, want 1", len(bodies))
	}
	var msg struct {
		Message map[string]json.RawMessage `json:"message"`
	}
	if err := json.Unmarshal(bodies[0], &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, ok := msg.Message["notification"]; ok {
		t.Fatalf("E2EE VIOLATION: the fan-out sent a notification message: %s", bodies[0])
	}
	if bytes.Contains(bytes.ToLower(bodies[0]), []byte("notification")) {
		t.Fatalf("E2EE VIOLATION: %q appears in the outgoing FCM body: %s", "notification", bodies[0])
	}

	// The blob is relayed verbatim, in data — the server never re-encodes,
	// wraps or inspects it.
	var data struct {
		Message struct {
			Data map[string]string `json:"data"`
		} `json:"message"`
	}
	if err := json.Unmarshal(bodies[0], &data); err != nil {
		t.Fatalf("unmarshal data: %v", err)
	}
	if got := data.Message.Data[fcmDataKey]; got != string(payload) {
		t.Fatalf("data[%q] = %q, want the sealed blob verbatim (%q)", fcmDataKey, got, payload)
	}
}

// One fan-out, two channels: every non-muted member is reached on whichever
// channel their device registered, and the counts cover both.
func TestFanOutPush_MixedKinds(t *testing.T) {
	webStub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/broken") {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer webStub.Close()

	var fcmHits atomic.Int64
	fcmStub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		fcmHits.Add(1)
		// One token is dead; without a store to prune into, the row is simply
		// counted as failed (pruning is covered by the integration test).
		if bytes.Contains(body, []byte("dead-token")) {
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"name":"projects/p/messages/1"}`)
	}))
	defer fcmStub.Close()

	s := withFCM(pushEnabledServer(t), fcmStub.URL)
	subs := []store.ListCirclePushSubscriptionsRow{
		testSubscription(t, webStub.URL+"/alice"),
		testFCMSubscription("android-token-bob"),
		testSubscription(t, webStub.URL+"/broken"),
		testFCMSubscription("android-token-carol"),
		testFCMSubscription("dead-token"),
	}

	sent, failed := s.fanOutPush(t.Context(), subs, []byte("c2VhbGVk"))
	// 1 webpush + 2 fcm delivered; 1 webpush 500 + 1 dead fcm token failed.
	if sent != 3 || failed != 2 {
		t.Fatalf("sent=%d failed=%d, want sent=3 failed=2", sent, failed)
	}
	if n := fcmHits.Load(); n != 3 {
		t.Fatalf("FCM saw %d sends, want 3 (one per fcm row, and none of the webpush rows)", n)
	}
}

// A deployment may run either channel alone. Subscriptions for a channel that
// is not configured are dropped before the fan-out rather than counted as
// failures — see deliverable.
func TestDeliverable_FiltersUnconfiguredChannels(t *testing.T) {
	web := testSubscription(t, "https://push.example.com/x")
	android := testFCMSubscription("android-token")
	all := []store.ListCirclePushSubscriptionsRow{web, android}

	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer stub.Close()

	t.Run("both channels: everything is deliverable", func(t *testing.T) {
		s := withFCM(pushEnabledServer(t), stub.URL)
		if got := s.deliverable(all); len(got) != 2 {
			t.Fatalf("got %d subs, want 2", len(got))
		}
	})
	t.Run("web push only: fcm rows dropped", func(t *testing.T) {
		s := pushEnabledServer(t) // no FCM client
		got := s.deliverable(all)
		if len(got) != 1 || got[0].Kind != kindWebPush {
			t.Fatalf("got %+v, want only the webpush row", got)
		}
	})
	t.Run("fcm only: webpush rows dropped", func(t *testing.T) {
		s := withFCM(NewServer(Deps{Config: pushCfg(t, false)}), stub.URL) // no VAPID
		got := s.deliverable(all)
		if len(got) != 1 || got[0].Kind != kindFCM {
			t.Fatalf("got %+v, want only the fcm row", got)
		}
	})
	t.Run("neither: nothing is deliverable", func(t *testing.T) {
		s := NewServer(Deps{Config: pushCfg(t, false)})
		if got := s.deliverable(all); len(got) != 0 {
			t.Fatalf("got %+v, want nothing", got)
		}
	})
}

// A webpush row cannot legally have NULL keys (the schema forbids it), but the
// fan-out must fail that row rather than nil-deref the whole worker.
func TestSendWebPush_MissingKeyMaterialFailsAlone(t *testing.T) {
	s := pushEnabledServer(t)
	sub := store.ListCirclePushSubscriptionsRow{
		ID: uuid.New(), UserID: uuid.New(), Endpoint: "https://push.example.com/x", Kind: kindWebPush,
	}
	if ok := s.sendPushSafe(t.Context(), sub, []byte("x")); ok {
		t.Fatal("a webpush row with no key material must not report success")
	}
}

func TestVAPIDSubscriber(t *testing.T) {
	// webpush-go prepends "mailto:" to any non-https subscriber, so we must hand
	// it a bare address or it builds "mailto:mailto:...".
	cases := map[string]string{
		"mailto:ops@aul.app":      "ops@aul.app",
		"ops@aul.app":             "ops@aul.app",
		"https://aul.example.com": "https://aul.example.com",
		"":                        "",
	}
	for in, want := range cases {
		if got := vapidSubscriber(in); got != want {
			t.Errorf("vapidSubscriber(%q) = %q, want %q", in, got, want)
		}
	}
}

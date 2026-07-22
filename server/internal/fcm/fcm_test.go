package fcm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"golang.org/x/oauth2"
)

// stubFCM records every request it is sent and answers with a scripted status
// and body. Nothing in this package's tests may reach real FCM.
type stubFCM struct {
	*httptest.Server
	status int
	body   string

	mu       sync.Mutex
	bodies   [][]byte
	paths    []string
	authHdrs []string
}

func newStubFCM(t *testing.T) *stubFCM {
	t.Helper()
	s := &stubFCM{status: http.StatusOK, body: `{"name":"projects/p/messages/1"}`}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.bodies = append(s.bodies, body)
		s.paths = append(s.paths, r.URL.Path)
		s.authHdrs = append(s.authHdrs, r.Header.Get("Authorization"))
		status, respBody := s.status, s.body
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, respBody)
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *stubFCM) reply(status int, body string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.status, s.body = status, body
}

func (s *stubFCM) lastBody(t *testing.T) []byte {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.bodies) == 0 {
		t.Fatal("FCM was never called")
	}
	return s.bodies[len(s.bodies)-1]
}

func testClient(t *testing.T, stub *stubFCM) *Client {
	t.Helper()
	return NewWithTokenSource("test-project",
		oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "test-access-token", TokenType: "Bearer"}),
		WithBaseURL(stub.URL))
}

// THE E2EE INVARIANT. A `notification` message is rendered by Android itself,
// so its contents must be plaintext — which would hand Google, and anyone who
// compels Google, the very thing the client sealed under K_c. Every message
// must be data-only. If this test fails, the E2EE guarantee of Android
// notifications is broken; do not "fix" it by updating the assertion.
func TestSend_IsDataOnly(t *testing.T) {
	stub := newStubFCM(t)
	c := testClient(t, stub)

	if err := c.Send(t.Context(), "device-token", map[string]string{"payload_enc": "c2VhbGVk"}, 600); err != nil {
		t.Fatalf("send: %v", err)
	}

	raw := stub.lastBody(t)

	// 1. Structurally: no notification key anywhere in the message.
	var got struct {
		Message map[string]json.RawMessage `json:"message"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal request body: %v", err)
	}
	if _, ok := got.Message["notification"]; ok {
		t.Fatalf("E2EE VIOLATION: outgoing FCM message carries a notification key: %s", raw)
	}

	// 2. Textually: catches a notification nested anywhere we did not think to
	//    look (android.notification, webpush.notification, …).
	if bytes.Contains(bytes.ToLower(raw), []byte("notification")) {
		t.Fatalf("E2EE VIOLATION: %q appears in the outgoing body: %s", "notification", raw)
	}

	// The sealed blob must be in data, unmodified.
	var msg struct {
		Message struct {
			Token   string            `json:"token"`
			Data    map[string]string `json:"data"`
			Android struct {
				Priority string `json:"priority"`
				TTL      string `json:"ttl"`
			} `json:"android"`
		} `json:"message"`
	}
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatalf("unmarshal message: %v", err)
	}
	if msg.Message.Token != "device-token" {
		t.Errorf("token = %q, want device-token", msg.Message.Token)
	}
	if msg.Message.Data["payload_enc"] != "c2VhbGVk" {
		t.Errorf("data.payload_enc = %q, want the blob verbatim", msg.Message.Data["payload_enc"])
	}
	if msg.Message.Android.Priority != "high" {
		t.Errorf("android.priority = %q, want high", msg.Message.Android.Priority)
	}
	if msg.Message.Android.TTL != "600s" {
		t.Errorf("android.ttl = %q, want 600s", msg.Message.Android.TTL)
	}
}

// The message type must not even have a notification field: the invariant is
// enforced by construction, not only by the test above.
func TestMessageTypeHasNoNotificationField(t *testing.T) {
	b, err := json.Marshal(message{Token: "t", Data: map[string]string{"k": "v"}})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(b), "notification") {
		t.Fatalf("the fcm message type can encode a notification: %s", b)
	}
}

func TestSend_RequestShape(t *testing.T) {
	stub := newStubFCM(t)
	c := testClient(t, stub)

	if err := c.Send(t.Context(), "tok", map[string]string{"payload_enc": "x"}, 600); err != nil {
		t.Fatalf("send: %v", err)
	}

	stub.mu.Lock()
	defer stub.mu.Unlock()
	if want := "/v1/projects/test-project/messages:send"; stub.paths[0] != want {
		t.Errorf("path = %q, want %q", stub.paths[0], want)
	}
	if want := "Bearer test-access-token"; stub.authHdrs[0] != want {
		t.Errorf("Authorization = %q, want %q", stub.authHdrs[0], want)
	}
}

// A dead token must be reported as such, so the caller prunes the row — and
// only for the failures that really mean "dead".
func TestSend_UnregisteredClassification(t *testing.T) {
	const unregistered404 = `{"error":{"code":404,"message":"Requested entity was not found.",
	  "status":"NOT_FOUND","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError",
	  "errorCode":"UNREGISTERED"}]}}`
	const unregistered400 = `{"error":{"code":400,"message":"…","status":"INVALID_ARGUMENT",
	  "details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError",
	  "errorCode":"UNREGISTERED"}]}}`
	const invalidArgument = `{"error":{"code":400,"message":"Invalid JSON payload",
	  "status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest"}]}}`
	const senderMismatch = `{"error":{"code":403,"status":"PERMISSION_DENIED",
	  "details":[{"errorCode":"SENDER_ID_MISMATCH"}]}}`

	cases := []struct {
		name         string
		status       int
		body         string
		wantGone     bool
		wantAnyError bool
	}{
		{"404 with UNREGISTERED prunes", http.StatusNotFound, unregistered404, true, true},
		{"400 with UNREGISTERED prunes", http.StatusBadRequest, unregistered400, true, true},
		{"bare 404 prunes", http.StatusNotFound, `{}`, true, true},
		// Our own malformed request must never delete anyone's subscription.
		{"INVALID_ARGUMENT does not prune", http.StatusBadRequest, invalidArgument, false, true},
		// Wrong project: an operator misconfiguration, not a dead token.
		{"SENDER_ID_MISMATCH does not prune", http.StatusForbidden, senderMismatch, false, true},
		{"401 does not prune", http.StatusUnauthorized, `{"error":{"status":"UNAUTHENTICATED"}}`, false, true},
		{"500 does not prune", http.StatusInternalServerError, `{}`, false, true},
		{"200 succeeds", http.StatusOK, `{"name":"projects/p/messages/1"}`, false, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stub := newStubFCM(t)
			stub.reply(tc.status, tc.body)
			c := testClient(t, stub)

			// Distinctive so the leak check below cannot match by accident.
			const deviceToken = "fZx9-REGISTRATION-TOKEN-9aQ"

			err := c.Send(t.Context(), deviceToken, map[string]string{"payload_enc": "x"}, 600)
			if got := errors.Is(err, ErrUnregistered); got != tc.wantGone {
				t.Errorf("ErrUnregistered = %v, want %v (err: %v)", got, tc.wantGone, err)
			}
			if (err != nil) != tc.wantAnyError {
				t.Errorf("err = %v, want error: %v", err, tc.wantAnyError)
			}
			// A rejection must never surface the token: it identifies a device,
			// exactly as a Web Push endpoint does.
			if err != nil && strings.Contains(err.Error(), deviceToken) {
				t.Errorf("error leaks the registration token: %v", err)
			}
		})
	}
}

// countingSource counts how many times a token is actually MINTED, as opposed
// to served from cache.
type countingSource struct{ calls atomic.Int64 }

func (c *countingSource) Token() (*oauth2.Token, error) {
	c.calls.Add(1)
	// No Expiry: ReuseTokenSource treats a zero expiry as never-expiring.
	return &oauth2.Token{AccessToken: "minted", TokenType: "Bearer"}, nil
}

// Minting an access token is a network round-trip and a signing operation. It
// must happen once and be reused, not run per notification — a circle fan-out
// would otherwise mint one token per member, per notify.
func TestSend_ReusesAccessToken(t *testing.T) {
	stub := newStubFCM(t)
	src := &countingSource{}
	c := NewWithTokenSource("test-project", oauth2.ReuseTokenSource(nil, src), WithBaseURL(stub.URL))

	for range 5 {
		if err := c.Send(t.Context(), "tok", map[string]string{"payload_enc": "x"}, 600); err != nil {
			t.Fatalf("send: %v", err)
		}
	}
	if n := src.calls.Load(); n != 1 {
		t.Fatalf("minted %d access tokens for 5 sends, want 1 (the source must cache)", n)
	}
}

func TestSend_TokenSourceFailurePropagates(t *testing.T) {
	stub := newStubFCM(t)
	c := NewWithTokenSource("p", failingSource{}, WithBaseURL(stub.URL))
	err := c.Send(t.Context(), "tok", map[string]string{"payload_enc": "x"}, 600)
	if err == nil || !strings.Contains(err.Error(), "mint access token") {
		t.Fatalf("err = %v, want a mint failure", err)
	}
	if errors.Is(err, ErrUnregistered) {
		t.Fatal("a credential failure must never be read as a dead token: it would prune every subscription")
	}
}

type failingSource struct{}

func (failingSource) Token() (*oauth2.Token, error) { return nil, errors.New("no credentials") }

// New must reject anything that is not a usable service account, at boot,
// rather than failing on every send later.
func TestNew_RejectsBadCredentials(t *testing.T) {
	cases := map[string]string{
		"not json":      `nope`,
		"empty object":  `{}`,
		"no project_id": `{"type":"service_account","client_email":"a@b.com","private_key":"x"}`,
	}
	for name, creds := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := New(context.Background(), []byte(creds)); err == nil {
				t.Fatal("expected an error, got a usable client")
			}
		})
	}
}

func TestWithBaseURL_TrimsTrailingSlash(t *testing.T) {
	c := NewWithTokenSource("p", oauth2.StaticTokenSource(&oauth2.Token{}), WithBaseURL("https://fcm.example.com/"))
	if c.baseURL != "https://fcm.example.com" {
		t.Fatalf("baseURL = %q, want no trailing slash (it would double the slash in the path)", c.baseURL)
	}
}

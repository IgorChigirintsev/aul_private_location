package httpx

import (
	"net/http"
	"testing"
)

func req(remote string, headers map[string]string) *http.Request {
	r := &http.Request{RemoteAddr: remote, Header: http.Header{}}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	return r
}

func TestClientIP_NoProxyIgnoresHeaders(t *testing.T) {
	// With trustProxy=false, spoofed headers must be ignored.
	r := req("203.0.113.9:5555", map[string]string{
		"X-Forwarded-For": "1.2.3.4",
		"X-Real-IP":       "9.9.9.9",
	})
	if got := ClientIP(r, false); got != "203.0.113.9" {
		t.Fatalf("no-proxy: got %q, want socket peer 203.0.113.9", got)
	}
}

func TestClientIP_PrefersRealIP(t *testing.T) {
	r := req("10.0.0.1:1111", map[string]string{
		"X-Real-IP":       "198.51.100.7",
		"X-Forwarded-For": "1.2.3.4, 198.51.100.7",
	})
	if got := ClientIP(r, true); got != "198.51.100.7" {
		t.Fatalf("got %q, want X-Real-IP 198.51.100.7", got)
	}
}

func TestClientIP_XFFUsesRightmostHop_NotSpoofableLeftmost(t *testing.T) {
	// Attacker sends "X-Forwarded-For: 6.6.6.6"; the trusted proxy APPENDS the
	// real peer, so the header arrives as "6.6.6.6, <realpeer>". We must take the
	// rightmost (real) hop, never the attacker's leftmost value.
	r := req("10.0.0.1:2222", map[string]string{
		"X-Forwarded-For": "6.6.6.6, 203.0.113.50",
	})
	if got := ClientIP(r, true); got != "203.0.113.50" {
		t.Fatalf("got %q, want rightmost hop 203.0.113.50 (leftmost is spoofable)", got)
	}
	if got := ClientIP(r, true); got == "6.6.6.6" {
		t.Fatal("must never return the attacker-controlled leftmost XFF hop")
	}
}

func TestClientIP_FallsBackToPeer(t *testing.T) {
	r := req("203.0.113.99:4444", nil)
	if got := ClientIP(r, true); got != "203.0.113.99" {
		t.Fatalf("got %q, want peer 203.0.113.99", got)
	}
}

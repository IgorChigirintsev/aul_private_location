package launcher

import (
	"encoding/json"
	"testing"
)

// TestFunnelHostPort_ParsesServeConfig feeds hand-built ServeConfig JSON — a
// top-level backgrounded Funnel and a blocking Foreground session with a
// trailing-dot DNSName — and asserts host:port selection plus the https
// origin/port derivation. Pure, no Tailscale, no network.
func TestFunnelHostPort_ParsesServeConfig(t *testing.T) {
	const magic = "box.tail9c2d1.ts.net"

	// Top-level (`tailscale serve --bg`) config on :8443 → origin keeps :8443.
	topLevel := `{
	  "TCP": { "8443": { "HTTPS": true } },
	  "Web": {
	    "box.tail9c2d1.ts.net:8443": {
	      "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } }
	    }
	  },
	  "AllowFunnel": { "box.tail9c2d1.ts.net:8443": true }
	}`

	var sc serveConfig
	if err := json.Unmarshal([]byte(topLevel), &sc); err != nil {
		t.Fatalf("unmarshal top-level: %v", err)
	}
	hp, proxy, ok := sc.funnelHostPort(magic)
	if !ok {
		t.Fatal("funnelHostPort found no live funnel in the top-level config")
	}
	if hp != "box.tail9c2d1.ts.net:8443" {
		t.Fatalf("hostPort = %q", hp)
	}
	if got := proxyPort(proxy); got != "8080" {
		t.Fatalf("proxyPort(%q) = %q, want 8080", proxy, got)
	}
	if origin, err := funnelOrigin(hp); err != nil || origin != "https://box.tail9c2d1.ts.net:8443" {
		t.Fatalf("funnelOrigin = %q, %v; want https://box.tail9c2d1.ts.net:8443", origin, err)
	}

	// Foreground session (blocking `tailscale funnel`) on :443, with a trailing
	// dot in the DNSName key → origin OMITS :443 and tolerates the dot.
	foreground := `{
	  "Foreground": {
	    "sess-1": {
	      "TCP": { "443": { "HTTPS": true } },
	      "Web": {
	        "box.tail9c2d1.ts.net.:443": {
	          "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } }
	        }
	      },
	      "AllowFunnel": { "box.tail9c2d1.ts.net.:443": true }
	    }
	  }
	}`

	var fg serveConfig
	if err := json.Unmarshal([]byte(foreground), &fg); err != nil {
		t.Fatalf("unmarshal foreground: %v", err)
	}
	hp2, _, ok := fg.funnelHostPort(magic)
	if !ok {
		t.Fatal("funnelHostPort found no live funnel in the foreground session")
	}
	if hp2 != "box.tail9c2d1.ts.net.:443" {
		t.Fatalf("foreground hostPort = %q", hp2)
	}
	origin, err := funnelOrigin(hp2)
	if err != nil {
		t.Fatalf("funnelOrigin: %v", err)
	}
	if origin != "https://box.tail9c2d1.ts.net" {
		t.Fatalf("origin = %q, want https://box.tail9c2d1.ts.net (no :443)", origin)
	}

	// A config with no funnel for this node must not match.
	var empty serveConfig
	if err := json.Unmarshal([]byte(`{"AllowFunnel":{"other.ts.net:443":true}}`), &empty); err != nil {
		t.Fatalf("unmarshal empty: %v", err)
	}
	if _, _, ok := empty.funnelHostPort(magic); ok {
		t.Fatal("funnelHostPort matched a funnel for a different node")
	}
}

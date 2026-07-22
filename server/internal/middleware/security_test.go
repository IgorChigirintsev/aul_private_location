package middleware

import (
	"strings"
	"testing"

	"github.com/aul-app/aul/server/internal/config"
)

// directive returns the source-list of a single CSP directive by name.
func directive(csp, name string) (string, bool) {
	for _, d := range strings.Split(csp, ";") {
		d = strings.TrimSpace(d)
		if after, ok := strings.CutPrefix(d, name+" "); ok {
			return after, true
		}
	}
	return "", false
}

// TestCSP_AllowsMapTiles guards the blank-map regression: MapLibre fetches the
// style JSON, vector tiles, glyphs, and sprites from the tiles origin. Those go
// through connect-src (fetch) and img-src (sprite image), so the configured
// tiles origin must appear in both — otherwise the CSP blocks them and the map
// renders blank.
func TestCSP_AllowsMapTiles(t *testing.T) {
	const tiles = "https://tiles.openfreemap.org"
	csp := buildCSP(&config.Config{TilesOrigin: tiles})

	for _, name := range []string{"connect-src", "img-src"} {
		src, ok := directive(csp, name)
		if !ok {
			t.Fatalf("CSP missing %s directive: %q", name, csp)
		}
		if !strings.Contains(src, tiles) {
			t.Fatalf("%s must allow the tiles origin %q, got %q", name, tiles, src)
		}
		if !strings.Contains(src, "'self'") {
			t.Fatalf("%s must still allow 'self', got %q", name, src)
		}
	}

	// MapLibre also needs blob: web workers and libsodium needs wasm-unsafe-eval;
	// assert those critical allowances are present so the map/crypto can run.
	if src, _ := directive(csp, "worker-src"); !strings.Contains(src, "blob:") {
		t.Fatalf("worker-src must allow blob: for MapLibre workers, got %q", src)
	}
	if src, _ := directive(csp, "script-src"); !strings.Contains(src, "'wasm-unsafe-eval'") {
		t.Fatalf("script-src must allow 'wasm-unsafe-eval' for libsodium WASM, got %q", src)
	}
}

// TestCSP_NoTilesOriginStaysStrict: with no tiles origin, connect-src is exactly
// 'self' (no accidental wildcard).
func TestCSP_NoTilesOriginStaysStrict(t *testing.T) {
	csp := buildCSP(&config.Config{TilesOrigin: ""})
	src, ok := directive(csp, "connect-src")
	if !ok || strings.TrimSpace(src) != "'self'" {
		t.Fatalf("connect-src should be exactly 'self' when no tiles origin, got %q", src)
	}
}

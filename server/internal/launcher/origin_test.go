package launcher

import (
	"context"
	"strings"
	"testing"
)

func TestClassifyOrigin(t *testing.T) {
	tests := []struct {
		scheme     string
		wantEnv    string
		wantSecure bool
	}{
		{"https", "production", true},
		{"http", "development", false},
	}
	for _, tt := range tests {
		env, secure := classifyOrigin(tt.scheme)
		if env != tt.wantEnv || secure != tt.wantSecure {
			t.Errorf("classifyOrigin(%q) = (%q, %v), want (%q, %v)",
				tt.scheme, env, secure, tt.wantEnv, tt.wantSecure)
		}
	}
}

// panicDetector fails the test if origin resolution ever consults the funnel on a
// path where an explicit origin should have won.
func panicDetector(context.Context) (funnelResult, bool, string) {
	panic("funnel detector must not be called when --origin is explicit")
}

func TestResolveOrigin_ExplicitHTTPS(t *testing.T) {
	res, err := resolveOrigin(context.Background(),
		Options{Origin: "https://aul.example.com", Port: 8080}, panicDetector)
	if err != nil {
		t.Fatalf("resolveOrigin: %v", err)
	}
	want := resolved{Origin: "https://aul.example.com", Env: "production", SecureCookies: true, BindPort: 8080, Source: sourceFlag}
	if res != want {
		t.Fatalf("resolved = %+v, want %+v", res, want)
	}
}

func TestResolveOrigin_ExplicitHTTPLocalhost(t *testing.T) {
	res, err := resolveOrigin(context.Background(),
		Options{Origin: "http://localhost:8080", Port: 8080}, panicDetector)
	if err != nil {
		t.Fatalf("resolveOrigin: %v", err)
	}
	want := resolved{Origin: "http://localhost:8080", Env: "development", SecureCookies: false, BindPort: 8080, Source: sourceFlag}
	if res != want {
		t.Fatalf("resolved = %+v, want %+v", res, want)
	}
}

func TestResolveOrigin_FunnelDetected(t *testing.T) {
	detect := func(context.Context) (funnelResult, bool, string) {
		return funnelResult{Origin: "https://box.tail9c2d1.ts.net", BindPort: "8080"}, true, ""
	}
	res, err := resolveOrigin(context.Background(), Options{Port: 8080}, detect)
	if err != nil {
		t.Fatalf("resolveOrigin: %v", err)
	}
	want := resolved{Origin: "https://box.tail9c2d1.ts.net", Env: "production", SecureCookies: true, BindPort: 8080, Source: sourceFunnel}
	if res != want {
		t.Fatalf("resolved = %+v, want %+v", res, want)
	}
}

func TestResolveOrigin_Fallback(t *testing.T) {
	detect := func(context.Context) (funnelResult, bool, string) {
		return funnelResult{}, false, "tailscale not installed"
	}
	res, err := resolveOrigin(context.Background(), Options{Port: 8080}, detect)
	if err != nil {
		t.Fatalf("resolveOrigin: %v", err)
	}
	want := resolved{Origin: "http://localhost:8080", Env: "development", SecureCookies: false, BindPort: 8080, Source: sourceLocalhost}
	if res != want {
		t.Fatalf("resolved = %+v, want %+v", res, want)
	}
}

func TestResolveOrigin_InvalidExplicit(t *testing.T) {
	for _, bad := range []string{"ftp://x", "not a url", "https://"} {
		if _, err := resolveOrigin(context.Background(),
			Options{Origin: bad, Port: 8080}, panicDetector); err == nil {
			t.Errorf("resolveOrigin(%q) = nil error, want error", bad)
		}
	}
}

func TestComposeEnv_Matrix(t *testing.T) {
	const (
		pepper = "test-pepper-value-1234"
		dbPath = "/home/op/.config/aul/aul.db"
	)
	// A base env that already carries values we MUST override, to prove dedup.
	base := []string{
		"PATH=/usr/bin",
		"LOG_LEVEL=debug",
		"SECURE_COOKIES=true",               // stale operator value; must be overridden
		"PUBLIC_ORIGIN=http://evil.example", // stale operator value; must be overridden
	}

	modes := []struct {
		name         string
		res          resolved
		wantOrigin   string
		wantEnv      string
		wantSecure   string
		wantHTTPAddr string
	}{
		{
			name:         "https-flag",
			res:          resolved{Origin: "https://aul.example.com", Env: "production", SecureCookies: true, BindPort: 8080, Source: sourceFlag},
			wantOrigin:   "https://aul.example.com",
			wantEnv:      "production",
			wantSecure:   "true",
			wantHTTPAddr: "127.0.0.1:8080",
		},
		{
			name:         "http-localhost",
			res:          resolved{Origin: "http://localhost:8080", Env: "development", SecureCookies: false, BindPort: 8080, Source: sourceLocalhost},
			wantOrigin:   "http://localhost:8080",
			wantEnv:      "development",
			wantSecure:   "false",
			wantHTTPAddr: "127.0.0.1:8080",
		},
		{
			name:         "funnel",
			res:          resolved{Origin: "https://box.ts.net", Env: "production", SecureCookies: true, BindPort: 9090, Source: sourceFunnel},
			wantOrigin:   "https://box.ts.net",
			wantEnv:      "production",
			wantSecure:   "true",
			wantHTTPAddr: "127.0.0.1:9090",
		},
	}

	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			env := composeEnv(base, m.res, pepper, dbPath)
			got := envMap(env)

			checkVal(t, got, "PUBLIC_ORIGIN", m.wantOrigin)
			checkVal(t, got, "AUL_ENV", m.wantEnv)
			checkVal(t, got, "SECURE_COOKIES", m.wantSecure)
			checkVal(t, got, "HTTP_ADDR", m.wantHTTPAddr)
			checkVal(t, got, "DATABASE_URL", "sqlite:"+dbPath)
			checkVal(t, got, "SESSION_HASH_PEPPER", pepper)
			checkVal(t, got, "RUN_MIGRATIONS", "true")

			// Inherited, non-overridden entries pass through unchanged.
			checkVal(t, got, "PATH", "/usr/bin")
			checkVal(t, got, "LOG_LEVEL", "debug")

			// Deliberately-absent keys.
			if _, ok := got["AUL_DB_BACKEND"]; ok {
				t.Error("AUL_DB_BACKEND must not be set (would break the sqlite: URL)")
			}
			if _, ok := got["FCM_PROJECT_ID"]; ok {
				t.Error("FCM_PROJECT_ID must not be set (derived from the service-account JSON)")
			}

			// Dedup: each overridden key must appear exactly once, and it must be
			// OUR value, not the stale one inherited from base.
			for _, key := range []string{"SECURE_COOKIES", "PUBLIC_ORIGIN"} {
				if n := countKey(env, key); n != 1 {
					t.Errorf("%s appears %d times, want exactly 1 (dedup failed)", key, n)
				}
			}
		})
	}
}

// envMap indexes a KEY=VALUE slice; the LAST value wins, matching how exec and
// os.Getenv resolve a duplicated key.
func envMap(env []string) map[string]string {
	m := make(map[string]string, len(env))
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	return m
}

func countKey(env []string, key string) int {
	n := 0
	for _, kv := range env {
		if k, _, ok := strings.Cut(kv, "="); ok && k == key {
			n++
		}
	}
	return n
}

func checkVal(t *testing.T, m map[string]string, key, want string) {
	t.Helper()
	if got, ok := m[key]; !ok {
		t.Errorf("%s missing, want %q", key, want)
	} else if got != want {
		t.Errorf("%s = %q, want %q", key, got, want)
	}
}

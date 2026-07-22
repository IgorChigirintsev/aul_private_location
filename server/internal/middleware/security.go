// Package middleware provides the server's HTTP middleware: security headers,
// CORS restricted to the configured origin, request id / real IP resolution,
// panic recovery, body-size limits, a WebSocket-safe access log, and a
// rate-limit adapter over internal/ratelimit.
package middleware

import (
	"net/http"
	"strings"

	"github.com/aul-app/aul/server/internal/config"
)

// SecurityHeaders sets a strict, static set of security response headers. The
// CSP allows only self plus the configured tiles origin (for MapLibre) and
// same-origin WebSocket; no inline/eval script.
func SecurityHeaders(cfg *config.Config) func(http.Handler) http.Handler {
	csp := buildCSP(cfg)
	hsts := cfg.SecureCookies || (cfg.PublicOrigin != nil && cfg.PublicOrigin.Scheme == "https")
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Set("Content-Security-Policy", csp)
			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("Referrer-Policy", "no-referrer")
			h.Set("X-Frame-Options", "DENY")
			h.Set("Cross-Origin-Opener-Policy", "same-origin")
			h.Set("Permissions-Policy", "geolocation=(self), camera=(), microphone=(), interest-cohort=()")
			if hsts {
				h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
			}
			next.ServeHTTP(w, r)
		})
	}
}

func buildCSP(cfg *config.Config) string {
	tiles := strings.TrimSpace(cfg.TilesOrigin)
	connect := "'self'"
	img := "'self' data: blob:"
	if tiles != "" {
		connect += " " + tiles
		img += " " + tiles
	}
	directives := []string{
		"default-src 'self'",
		"base-uri 'none'",
		"object-src 'none'",
		"frame-ancestors 'none'",
		"form-action 'self'",
		"script-src 'self' 'wasm-unsafe-eval'", // libsodium-wrappers uses WASM
		"style-src 'self' 'unsafe-inline'",     // MapLibre injects inline styles
		"img-src " + img,
		"font-src 'self'",
		"worker-src 'self' blob:",
		"connect-src " + connect,
		"manifest-src 'self'",
	}
	return strings.Join(directives, "; ")
}

// CORS allows only the configured public origin, with credentials. Requests
// from other origins get no CORS headers (browsers block them); same-origin and
// non-browser clients are unaffected.
func CORS(cfg *config.Config) func(http.Handler) http.Handler {
	allowed := ""
	if cfg.PublicOrigin != nil {
		allowed = cfg.PublicOrigin.Scheme + "://" + cfg.PublicOrigin.Host
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")
			if origin != "" && origin == allowed {
				h := w.Header()
				h.Set("Access-Control-Allow-Origin", allowed)
				h.Set("Access-Control-Allow-Credentials", "true")
				h.Set("Vary", "Origin")
				if r.Method == http.MethodOptions {
					h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
					h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
					h.Set("Access-Control-Max-Age", "600")
					w.WriteHeader(http.StatusNoContent)
					return
				}
			} else if r.Method == http.MethodOptions && origin != "" {
				// Disallowed cross-origin preflight: refuse.
				w.WriteHeader(http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

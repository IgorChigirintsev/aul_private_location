package middleware

import (
	"net/http"
	"strconv"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/ratelimit"
)

// KeyFunc derives the rate-limit bucket key for a request. An empty key skips
// limiting for that request.
type KeyFunc func(r *http.Request) string

// RateLimit rejects requests that exceed the limiter for their key with 429 and
// a Retry-After hint.
func RateLimit(l ratelimit.Limiter, key KeyFunc, retryAfterSecs int) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			k := key(r)
			if k != "" && !l.Allow(k) {
				w.Header().Set("Retry-After", strconv.Itoa(retryAfterSecs))
				httpx.WriteError(w, http.StatusTooManyRequests, httpx.CodeRateLimited, "rate limit exceeded, slow down")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// ByIP keys on the resolved client IP.
func ByIP(r *http.Request) string { return "ip:" + httpx.RealIPFrom(r.Context()) }

// ByAuthUser keys on the authenticated user (use after RequireAuth).
func ByAuthUser(r *http.Request) string {
	if a, ok := httpx.AuthFrom(r.Context()); ok {
		return "user:" + a.UserID.String()
	}
	return ""
}

// ByDevice keys on the authenticated device (use after RequireAuth).
func ByDevice(r *http.Request) string {
	if a, ok := httpx.AuthFrom(r.Context()); ok {
		return "dev:" + a.DeviceID.String()
	}
	return ""
}

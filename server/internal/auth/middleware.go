package auth

import (
	"net/http"
	"strings"

	"github.com/aul-app/aul/server/internal/httpx"
)

// RequireAuth authenticates a request by access token (Bearer header preferred,
// then the access cookie) and attaches the identity to the request context. It
// responds 401 on failure.
func (s *Service) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := BearerToken(r)
		if token == "" {
			if c, err := r.Cookie(httpx.CookieAccess); err == nil {
				token = c.Value
			}
		}
		userID, deviceID, sessionID, err := s.Resolve(r.Context(), token)
		if err != nil {
			httpx.Unauthorized(w, "authentication required")
			return
		}
		ctx := httpx.WithAuth(r.Context(), httpx.Auth{
			UserID:    userID,
			DeviceID:  deviceID,
			SessionID: sessionID,
		})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// BearerToken extracts a token from the Authorization header, or "" if absent.
func BearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) > len(prefix) && strings.EqualFold(h[:len(prefix)], prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}

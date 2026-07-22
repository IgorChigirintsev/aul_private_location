package httpapi

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/middleware"
	"github.com/aul-app/aul/server/internal/ratelimit"
	"github.com/aul-app/aul/server/internal/store"
)

type apiCtxKey int

const ctxKeyMembership apiCtxKey = iota

// membershipFrom returns the current circle membership loaded by
// requireCircleMember.
func membershipFrom(ctx context.Context) (store.CircleMember, bool) {
	m, ok := ctx.Value(ctxKeyMembership).(store.CircleMember)
	return m, ok
}

// requireCircleMember loads and verifies that the authenticated user belongs to
// the circle named by the {circleID} URL param, storing the membership in
// context. A non-member gets 404 so circle existence is not leaked.
func (s *Server) requireCircleMember(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := httpx.MustAuth(r.Context())
		circleID, err := uuid.Parse(chi.URLParam(r, "circleID"))
		if err != nil {
			httpx.NotFound(w, "circle not found")
			return
		}
		m, err := s.store.GetMembership(r.Context(), store.GetMembershipParams{
			CircleID: circleID,
			UserID:   auth.UserID,
		})
		if err != nil {
			if store.IsNotFound(err) {
				httpx.NotFound(w, "circle not found")
				return
			}
			httpx.Internal(w, err)
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyMembership, m)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// requireOwner is used inside a requireCircleMember-guarded route to restrict to
// the circle owner.
func requireOwner(w http.ResponseWriter, r *http.Request) (store.CircleMember, bool) {
	m, ok := membershipFrom(r.Context())
	if !ok || m.Role != "owner" {
		httpx.Forbidden(w, "owner role required")
		return store.CircleMember{}, false
	}
	return m, true
}

// decodeBlob decodes a base64 (std or url) ciphertext field with a size ceiling.
func decodeBlob(field, s string, maxBytes int) ([]byte, error) {
	if s == "" {
		return nil, fmt.Errorf("%s is required", field)
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		if b2, err2 := base64.RawStdEncoding.DecodeString(s); err2 == nil {
			b = b2
		} else if b3, err3 := base64.URLEncoding.DecodeString(s); err3 == nil {
			b = b3
		} else {
			return nil, fmt.Errorf("%s must be base64", field)
		}
	}
	if len(b) == 0 {
		return nil, fmt.Errorf("%s must not be empty", field)
	}
	if len(b) > maxBytes {
		return nil, fmt.Errorf("%s exceeds %d bytes", field, maxBytes)
	}
	return b, nil
}

func encodeBlob(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

// parseUUIDParam parses a URL path parameter as a UUID.
func parseUUIDParam(r *http.Request, name string) (uuid.UUID, error) {
	id, err := uuid.Parse(chi.URLParam(r, name))
	if err != nil {
		return uuid.Nil, errors.New(name + " must be a valid id")
	}
	return id, nil
}

// clientIP returns the resolved client IP for the request.
func clientIP(r *http.Request) string { return httpx.RealIPFrom(r.Context()) }

// Rate-limit middleware helpers keyed by IP / user / device.
func (s *Server) rateLimitByIP(l ratelimit.Limiter, retrySecs int) func(http.Handler) http.Handler {
	return middleware.RateLimit(l, middleware.ByIP, retrySecs)
}
func (s *Server) rateLimitByUser(l ratelimit.Limiter, retrySecs int) func(http.Handler) http.Handler {
	return middleware.RateLimit(l, middleware.ByAuthUser, retrySecs)
}
func (s *Server) rateLimitByDevice(l ratelimit.Limiter, retrySecs int) func(http.Handler) http.Handler {
	return middleware.RateLimit(l, middleware.ByDevice, retrySecs)
}

package httpx

import (
	"context"
	"net"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

// Cookie names for web sessions. The refresh cookie is scoped to the auth path
// so it is not sent with every request.
const (
	CookieAccess  = "aul_at"
	CookieRefresh = "aul_rt"
	RefreshPath   = "/v1/auth"
)

type ctxKey int

const (
	ctxKeyAuth ctxKey = iota
	ctxKeyRequestID
	ctxKeyRealIP
)

// Auth is the authenticated identity attached to a request after RequireAuth.
type Auth struct {
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	SessionID uuid.UUID
}

// WithAuth returns a child context carrying the authenticated identity.
func WithAuth(ctx context.Context, a Auth) context.Context {
	return context.WithValue(ctx, ctxKeyAuth, a)
}

// AuthFrom extracts the authenticated identity; ok is false if unauthenticated.
func AuthFrom(ctx context.Context) (Auth, bool) {
	a, ok := ctx.Value(ctxKeyAuth).(Auth)
	return a, ok
}

// MustAuth returns the identity or panics; use only in handlers guarded by
// RequireAuth (a programming error otherwise).
func MustAuth(ctx context.Context) Auth {
	a, ok := AuthFrom(ctx)
	if !ok {
		panic("httpx: MustAuth called on unauthenticated request")
	}
	return a
}

// WithRequestID / RequestIDFrom carry a per-request correlation id.
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxKeyRequestID, id)
}
func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(ctxKeyRequestID).(string)
	return id
}

// WithRealIP / RealIPFrom carry the resolved client IP (proxy-aware).
func WithRealIP(ctx context.Context, ip string) context.Context {
	return context.WithValue(ctx, ctxKeyRealIP, ip)
}
func RealIPFrom(ctx context.Context) string {
	ip, _ := ctx.Value(ctxKeyRealIP).(string)
	return ip
}

// ClientIP resolves the client IP. When trustProxy is true it trusts ONLY hops
// controlled by our own reverse proxy: X-Real-IP (which the proxy overwrites to
// the real peer) is preferred, and for X-Forwarded-For only the RIGHTMOST hop —
// the entry the nearest trusted proxy appended — is used. The leftmost XFF hops
// are attacker-supplied (a proxy appends the real peer to any client-sent XFF),
// so trusting them would let a client spoof its IP and defeat per-IP rate
// limiting, lockout, and audit integrity. When trustProxy is false only the
// direct socket peer is used. Operators must ensure their proxy overwrites
// X-Real-IP and appends to X-Forwarded-For (see deploy/caddy/Caddyfile).
func ClientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xr := strings.TrimSpace(r.Header.Get("X-Real-IP")); xr != "" {
			return xr
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
				return last
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

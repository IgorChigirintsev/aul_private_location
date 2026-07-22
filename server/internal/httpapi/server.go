// Package httpapi assembles the chi router and implements every REST + WebSocket
// handler. Handlers are thin: they validate input, call the store/auth/hub, and
// shape JSON. Encrypted fields cross the wire as base64 and are stored as bytea;
// the server never inspects ciphertext.
package httpapi

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/fcm"
	"github.com/aul-app/aul/server/internal/middleware"
	"github.com/aul-app/aul/server/internal/ratelimit"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

// Validation limits shared across handlers.
const (
	maxBlobBytes    = 4096 // per-ciphertext ceiling (spec: ≤ 4 KiB)
	maxNonceBytes   = 40   // XChaCha20 nonce is 24B; allow small headroom
	maxBatchPings   = 100  // spec: ≤ 100 pings per batch
	maxKeyEnvelopes = 200  // recipients per key-distribution request
	smallJSONLimit  = 64 << 10
	pingJSONLimit   = 1 << 20   // batch of encrypted pings
	maxProfileBytes = 128 << 10 // sealed per-circle member profile (nick + small avatar) ceiling
	// profileJSONLimit bounds the profile PUT body: base64 of a 128 KiB blob is
	// ~171 KiB, leaving room for the JSON envelope before the decoded-size check.
	profileJSONLimit = 256 << 10
	pingFutureSkew   = 5 * time.Minute
)

// Server holds dependencies and builds the router.
type Server struct {
	cfg    *config.Config
	store  *store.Store
	auth   *auth.Service
	hub    *realtime.Hub
	audit  *audit.Logger
	static http.Handler

	authLimiter   ratelimit.Limiter // per IP, auth endpoints
	inviteLimiter ratelimit.Limiter // per user, invite creation
	pingLimiter   ratelimit.Limiter // per device, ping ingestion
	keyEnvLimiter ratelimit.Limiter // per user, key-envelope distribution
	wsLimiter     ratelimit.Limiter // per IP, WebSocket upgrades
	notifyLimiter ratelimit.Limiter // per user, web push fan-out
	shareLimiter  ratelimit.Limiter // per user, live-share link creation

	// pushClient is shared across push sends so connections to the push services
	// are pooled and every request is bounded (webpush-go would otherwise build
	// a fresh, timeout-less http.Client per notification).
	pushClient *http.Client

	// fcm is the second push channel (Android). nil = FCM not configured, which
	// is a supported deployment: /notify then fans out over Web Push alone.
	fcm *fcm.Client
}

// Deps bundles constructor dependencies.
type Deps struct {
	Config *config.Config
	Store  *store.Store
	Auth   *auth.Service
	Hub    *realtime.Hub
	Audit  *audit.Logger
	Static http.Handler

	// FCM enables the Android push channel. nil is valid: FCM stays disabled.
	FCM *fcm.Client

	AuthLimiter   ratelimit.Limiter
	InviteLimiter ratelimit.Limiter
	PingLimiter   ratelimit.Limiter
	KeyEnvLimiter ratelimit.Limiter
	WSLimiter     ratelimit.Limiter
	NotifyLimiter ratelimit.Limiter
	ShareLimiter  ratelimit.Limiter
}

// NewServer wires a Server from its dependencies.
func NewServer(d Deps) *Server {
	return &Server{
		cfg:           d.Config,
		store:         d.Store,
		auth:          d.Auth,
		hub:           d.Hub,
		audit:         d.Audit,
		static:        d.Static,
		fcm:           d.FCM,
		authLimiter:   orNoop(d.AuthLimiter),
		inviteLimiter: orNoop(d.InviteLimiter),
		pingLimiter:   orNoop(d.PingLimiter),
		keyEnvLimiter: orNoop(d.KeyEnvLimiter),
		wsLimiter:     orNoop(d.WSLimiter),
		notifyLimiter: orNoop(d.NotifyLimiter),
		shareLimiter:  orNoop(d.ShareLimiter),
		pushClient:    &http.Client{Timeout: pushSendTimeout},
	}
}

func orNoop(l ratelimit.Limiter) ratelimit.Limiter {
	if l == nil {
		return ratelimit.Noop{}
	}
	return l
}

// Router builds the complete HTTP handler.
func (s *Server) Router() http.Handler {
	r := chi.NewRouter()

	// Global middleware (outermost first).
	r.Use(middleware.Recoverer)
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP(s.cfg.TrustProxyHeaders))
	r.Use(middleware.SecurityHeaders(s.cfg))
	r.Use(middleware.CORS(s.cfg))
	r.Use(middleware.BodyLimit(s.cfg.BodyLimitBytes))
	r.Use(middleware.AccessLog(s.cfg.IPLogRetentionDays > 0))

	// Operational endpoints.
	r.Get("/healthz", s.handleHealthz)
	r.Get("/readyz", s.handleReadyz)
	if s.cfg.MetricsEnabled {
		r.Get("/metrics", s.handleMetrics)
	}

	// REST API under /v1, with a per-request timeout.
	r.Route("/v1", func(r chi.Router) {
		r.Use(timeout(s.cfg.RequestTimeout))
		s.mountAuth(r)
		s.mountCircles(r) // circles + members + invites(create/list) + pings(read) + places + sos + key-envelopes(post)
		s.mountInvites(r) // top-level invite get/accept
		s.mountPings(r)   // top-level ping batch
		s.mountKeyEnvelopes(r)
		s.mountShare(r) // live-share sessions; the viewer GET is public by design
		s.mountMisc(r)
		// Realtime WebSocket lives under /v1 but must NOT get the REST timeout.
	})

	// WebSocket endpoint (long-lived; no request timeout wrapper).
	r.Get("/v1/realtime", s.handleRealtime)

	// Everything else → static web assets / APK downloads (SPA fallback).
	if s.static != nil {
		r.NotFound(s.static.ServeHTTP)
	}
	return r
}

// timeout applies a per-request deadline to REST handlers.
func timeout(d time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.TimeoutHandler(next, d, `{"error":{"code":"timeout","message":"request timed out"}}`)
	}
}

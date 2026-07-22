package httpapi

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/store"
)

func (s *Server) mountMisc(r chi.Router) {
	// Public, unauthenticated.
	r.Get("/server-info", s.handleServerInfo)
	r.Get("/version/latest", s.handleVersionLatest)

	// Authenticated.
	r.Group(func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		r.Post("/push/subscribe", s.handlePushSubscribe)
		r.Delete("/push/subscribe", s.handlePushUnsubscribe)
	})
}

// handleServerInfo advertises the server's E2EE posture so clients can warn the
// user when connected to a trusted-server (plaintext) deployment.
func (s *Server) handleServerInfo(w http.ResponseWriter, r *http.Request) {
	// The VAPID public key is public by design: clients need it as the
	// applicationServerKey to create a push subscription. null = push disabled.
	var vapidKey *string
	if s.cfg.PushEnabled() {
		vapidKey = &s.cfg.VAPIDPublicKey
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"e2ee":                       !s.cfg.TrustedServerMode,
		"trusted_server_mode":        s.cfg.TrustedServerMode,
		"public_origin":              s.cfg.PublicOrigin.String(),
		"retention_features_enabled": s.cfg.RetentionFeaturesEnabled,
		"vapid_public_key":           vapidKey,
		// Whether registering an FCM token here is worth anything. The Android
		// client asks before requesting one from Google — false means this
		// deployment has no FCM credentials and the token would never be used.
		// No project id or sender id is published: the app already carries its
		// own google-services.json.
		"fcm_enabled": s.fcmEnabled(),
	})
}

func (s *Server) handleVersionLatest(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	if platform != "android" && platform != "ios" {
		httpx.BadRequest(w, "platform must be android or ios")
		return
	}
	v, err := s.store.LatestActiveVersion(r.Context(), platform)
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "no published version")
			return
		}
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"version_code":  v.VersionCode,
		"version_name":  v.VersionName,
		"apk_url":       v.ApkUrl,
		"sha256":        v.Sha256,
		"changelog":     v.Changelog,
		"min_supported": v.MinSupported,
	})
}

// Subscription field ceilings. A registration token is ~163 chars today, but
// Google documents no maximum; 4096 is headroom that still stops a client from
// writing an arbitrarily large row.
const (
	maxPushEndpointBytes = 2048
	maxPushKeyBytes      = 512
	maxFCMTokenBytes     = 4096
)

// pushSubscribeReq is either shape of a subscription, discriminated by kind:
//
//	{"endpoint":"https://…","p256dh":"…","auth":"…"}  → Web Push (browser)
//	{"kind":"fcm","token":"…"}                        → FCM (Android)
//
// An absent kind means webpush, so clients written before FCM existed keep
// working untouched.
type pushSubscribeReq struct {
	Kind     string `json:"kind"`
	Endpoint string `json:"endpoint"`
	P256dh   string `json:"p256dh"`
	Auth     string `json:"auth"`
	Token    string `json:"token"`
}

func (s *Server) handlePushSubscribe(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req pushSubscribeReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	params, err := pushSubscriptionParams(req)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	device := a.DeviceID
	params.UserID, params.DeviceID = a.UserID, &device
	if _, err := s.store.UpsertPushSubscription(r.Context(), params); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]string{"status": "subscribed"})
}

// pushSubscriptionParams validates a subscription and maps it onto the row. The
// two shapes are kept strictly apart: mixing them is always a client bug, and
// silently accepting a half-filled row would store a subscription that can never
// be delivered.
//
// Both branches store their opaque per-device address in endpoint — a push
// service URL for webpush, the registration token for fcm — which is what lets
// one unique key, one prune and one unsubscribe serve both channels.
//
// No error message echoes the token or the endpoint: both identify a device.
func pushSubscriptionParams(req pushSubscribeReq) (store.UpsertPushSubscriptionParams, error) {
	var zero store.UpsertPushSubscriptionParams
	switch req.Kind {
	case kindFCM:
		switch {
		case req.Token == "":
			return zero, errors.New(`token is required for kind="fcm"`)
		case len(req.Token) > maxFCMTokenBytes:
			return zero, errors.New("token is too large")
		case req.P256dh != "" || req.Auth != "":
			return zero, errors.New(`kind="fcm" must not carry p256dh or auth: they are Web Push key material and FCM has no use for them`)
		case req.Endpoint != "":
			return zero, errors.New(`kind="fcm" carries the registration token in "token", not "endpoint"`)
		}
		// p256dh/auth stay NULL: an FCM token has no key material of its own.
		return store.UpsertPushSubscriptionParams{Endpoint: req.Token, Kind: kindFCM}, nil

	case "", kindWebPush:
		switch {
		case req.Endpoint == "" || req.P256dh == "" || req.Auth == "":
			return zero, errors.New("endpoint, p256dh, and auth are required")
		case len(req.Endpoint) > maxPushEndpointBytes ||
			len(req.P256dh) > maxPushKeyBytes || len(req.Auth) > maxPushKeyBytes:
			return zero, errors.New("push subscription fields too large")
		case req.Token != "":
			return zero, errors.New(`token is only valid with kind="fcm"`)
		}
		return store.UpsertPushSubscriptionParams{
			Endpoint: req.Endpoint, P256dh: &req.P256dh, Auth: &req.Auth, Kind: kindWebPush,
		}, nil

	default:
		return zero, errors.New(`kind must be "webpush" or "fcm"`)
	}
}

// handlePushUnsubscribe removes a subscription by its opaque address. Both
// channels store that in endpoint, so a browser may send its endpoint and an
// Android client may send its token — the same row lookup serves both.
func (s *Server) handlePushUnsubscribe(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req pushSubscribeReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	target := req.Endpoint
	if target == "" {
		target = req.Token
	}
	if target == "" {
		httpx.BadRequest(w, "endpoint or token is required")
		return
	}
	// Scoped to the caller's user id, so one user cannot unsubscribe another's
	// device by guessing its address.
	if err := s.store.DeletePushSubscription(r.Context(), store.DeletePushSubscriptionParams{
		Endpoint: target, UserID: a.UserID,
	}); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "unsubscribed"})
}

// --- operational endpoints (registered outside /v1) ---

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		httpx.WriteError(w, http.StatusServiceUnavailable, httpx.CodeInternal, "database unavailable")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// handleMetrics exposes a minimal Prometheus text-format snapshot (behind the
// METRICS_ENABLED flag). Expanded instrumentation is future work.
func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	stats := s.hub.Snapshot()
	var b strings.Builder
	fmt.Fprintf(&b, "# HELP aul_realtime_clients Connected WebSocket clients\n")
	fmt.Fprintf(&b, "# TYPE aul_realtime_clients gauge\n")
	fmt.Fprintf(&b, "aul_realtime_clients %d\n", stats.Clients)
	fmt.Fprintf(&b, "# HELP aul_realtime_circles Circles with at least one subscriber\n")
	fmt.Fprintf(&b, "# TYPE aul_realtime_circles gauge\n")
	fmt.Fprintf(&b, "aul_realtime_circles %d\n", stats.Circles)
	fmt.Fprintf(&b, "# HELP aul_db_pool_total Total database pool connections\n")
	fmt.Fprintf(&b, "# TYPE aul_db_pool_total gauge\n")
	fmt.Fprintf(&b, "aul_db_pool_total %d\n", s.store.TotalConns())
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = io.WriteString(w, b.String())
}

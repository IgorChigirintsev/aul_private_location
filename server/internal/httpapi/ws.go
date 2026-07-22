package httpapi

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
)

const (
	wsSendBuffer = 128
	wsWriteWait  = 10 * time.Second
	wsPingEvery  = 30 * time.Second
)

// handleRealtime upgrades to WebSocket after authenticating, subscribes the
// connection to the user's circles, and streams events. Auth is resolved BEFORE
// the upgrade so failures return a normal 401. Browsers authenticate via the
// httpOnly access cookie; native clients may use a Bearer header or the
// access_token query parameter.
func (s *Server) handleRealtime(w http.ResponseWriter, r *http.Request) {
	// Throttle upgrade attempts per IP before doing any work.
	if !s.wsLimiter.Allow("ws:" + clientIP(r)) {
		w.Header().Set("Retry-After", "10")
		httpx.WriteError(w, http.StatusTooManyRequests, httpx.CodeRateLimited, "too many connection attempts")
		return
	}

	token := auth.BearerToken(r)
	if token == "" {
		if c, err := r.Cookie(httpx.CookieAccess); err == nil {
			token = c.Value
		}
	}
	if token == "" {
		token = r.URL.Query().Get("access_token")
	}

	userID, deviceID, _, err := s.auth.Resolve(r.Context(), token)
	if err != nil {
		httpx.Unauthorized(w, "authentication required")
		return
	}

	// Enforce per-user and global connection ceilings before upgrading.
	if !s.hub.Admit(userID) {
		httpx.WriteError(w, http.StatusServiceUnavailable, httpx.CodeRateLimited, "connection limit reached")
		return
	}
	defer s.hub.Release(userID)

	circleRows, err := s.store.ListCirclesForUser(r.Context(), userID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	circleIDs := make([]uuid.UUID, 0, len(circleRows))
	for _, c := range circleRows {
		circleIDs = append(circleIDs, c.ID)
	}

	opts := &websocket.AcceptOptions{}
	if s.cfg.PublicOrigin != nil {
		opts.OriginPatterns = []string{s.cfg.PublicOrigin.Host}
	}
	conn, err := websocket.Accept(w, r, opts)
	if err != nil {
		return // Accept already wrote the response
	}
	defer func() { _ = conn.CloseNow() }()

	client := realtime.NewClient(userID, circleIDs, wsSendBuffer)
	s.hub.Register(client)
	defer s.hub.Unregister(client)

	// Best-effort presence update.
	_ = s.store.TouchDevice(context.WithoutCancel(r.Context()), deviceID)

	// CloseRead handles inbound control frames and cancels readCtx on close.
	readCtx := conn.CloseRead(r.Context())

	// Welcome frame: tell the client which circles it is subscribed to.
	welcome := mustJSON(map[string]any{
		"type":      "welcome",
		"circles":   circleIDs,
		"server_ts": time.Now().UTC(),
		"poll_hint": 30, // seconds; fallback polling cadence
	})
	if err := writeFrame(readCtx, conn, welcome); err != nil {
		return
	}

	ping := time.NewTicker(wsPingEvery)
	defer ping.Stop()

	for {
		select {
		case <-readCtx.Done():
			return
		case frame, ok := <-client.Send():
			if !ok {
				_ = conn.Close(websocket.StatusNormalClosure, "server shutting down")
				return
			}
			if err := writeFrame(readCtx, conn, frame); err != nil {
				return
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(readCtx, wsWriteWait)
			err := conn.Ping(pctx)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func writeFrame(ctx context.Context, conn *websocket.Conn, frame []byte) error {
	wctx, cancel := context.WithTimeout(ctx, wsWriteWait)
	defer cancel()
	return conn.Write(wctx, websocket.MessageText, frame)
}

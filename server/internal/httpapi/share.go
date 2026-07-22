package httpapi

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/crypto"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/store"
)

// Live-share bounds. A share is a short, deliberate "here I am right now" — not
// a standing subscription — so the ceiling is an hour.
const (
	minShareTTL     = 60 * time.Second
	maxShareTTL     = 60 * time.Minute
	defaultShareTTL = 15 * time.Minute
)

// shareGoneMsg is returned for every dead link — expired or revoked, bound or
// never opened. One message for all of them: a viewer who was never meant to
// have the link learns only that it is not live, not what became of it.
const shareGoneMsg = "this share link is no longer live"

// mountShare registers the live-share group. A share session shows ONE outsider
// — unregistered, with no account — the sharer's live position for a bounded
// window. The sharer's client seals each fix under a per-session key K_share
// that travels only in the link's URL fragment: not the circle key, and never to
// the server, which stores and serves opaque ciphertext.
//
// The viewer GET is deliberately outside RequireAuth — the whole point is that
// the recipient has no account. Its access control is the unguessable link plus
// one-device binding (see bindShareViewer), not a session.
func (s *Server) mountShare(r chi.Router) {
	r.Route("/share", func(r chi.Router) {
		// PUBLIC: the viewer holds nothing but the link.
		r.Get("/{shareID}", s.handleGetShare)

		// The sharer's own side.
		r.Group(func(r chi.Router) {
			r.Use(s.auth.RequireAuth)
			r.With(s.rateLimitByUser(s.shareLimiter, 3600)).Post("/", s.handleCreateShare)
			r.Get("/", s.handleListShares)
			r.Delete("/{shareID}", s.handleRevokeShare)
			r.Put("/{shareID}/ping", s.handleSharePing)
		})
	})
}

type createShareReq struct {
	TTLSeconds int64 `json:"ttl_seconds"`
}

type shareSessionDTO struct {
	ID          uuid.UUID `json:"id"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	ViewerBound bool      `json:"viewer_bound"`
	Revoked     bool      `json:"revoked"`
}

type sharePositionDTO struct {
	Nonce      string    `json:"nonce"`       // base64
	Ciphertext string    `json:"ciphertext"`  // base64, sealed under K_share
	CapturedAt time.Time `json:"captured_at"` // RFC3339
}

// clampShareTTL resolves a requested ttl_seconds to an allowed duration. Out-of-
// range requests are clamped rather than rejected: the ceiling is a privacy
// guarantee the server enforces regardless of what the client asks for, and a
// clamp states it in the 201's expires_at instead of failing a share the user
// meant to start.
//
// The comparison stays in the seconds domain: converting first would let a
// large ttl_seconds overflow int64 nanoseconds and wrap to a value that slips
// under the ceiling.
func clampShareTTL(seconds int64) time.Duration {
	switch {
	case seconds <= 0:
		return defaultShareTTL
	case seconds < int64(minShareTTL/time.Second):
		return minShareTTL
	case seconds > int64(maxShareTTL/time.Second):
		return maxShareTTL
	default:
		return time.Duration(seconds) * time.Second
	}
}

func (s *Server) handleCreateShare(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req createShareReq
	// Body is optional: no body means "default TTL".
	if r.ContentLength != 0 {
		if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
			httpx.BadRequest(w, err.Error())
			return
		}
	}
	sess, err := s.store.CreateShareSession(r.Context(), store.CreateShareSessionParams{
		UserID:    a.UserID,
		ExpiresAt: time.Now().Add(clampShareTTL(req.TTLSeconds)),
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{
		"id":         sess.ID,
		"expires_at": sess.ExpiresAt,
	})
}

func (s *Server) handleListShares(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	rows, err := s.store.ListShareSessionsForUser(r.Context(), a.UserID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]shareSessionDTO, 0, len(rows))
	for _, sess := range rows {
		out = append(out, shareSessionDTO{
			ID: sess.ID, CreatedAt: sess.CreatedAt, ExpiresAt: sess.ExpiresAt,
			ViewerBound: sess.ViewerBoundAt != nil, Revoked: sess.RevokedAt != nil,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

// handleRevokeShare kills a link immediately and idempotently: re-revoking keeps
// the original revoked_at and still answers 200, so a client retrying after a
// dropped response never sees a spurious failure.
func (s *Server) handleRevokeShare(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	id, err := parseUUIDParam(r, "shareID")
	if err != nil {
		httpx.NotFound(w, "share link not found")
		return
	}
	if _, err := s.store.RevokeShareSession(r.Context(), store.RevokeShareSessionParams{
		ID: id, UserID: a.UserID,
	}); err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "share link not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "revoked"})
}

type sharePingReq struct {
	Nonce      string `json:"nonce"`       // base64
	Ciphertext string `json:"ciphertext"`  // base64, ≤ 4 KiB, sealed under K_share
	CapturedAt string `json:"captured_at"` // RFC3339
}

// handleSharePing stores the sharer's latest sealed fix for one session. Only
// the owner may post, and only while the session is live; the blob replaces its
// predecessor so no track is ever retained for the viewer to walk back.
func (s *Server) handleSharePing(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	sess, ok := s.loadOwnedShare(w, r, a.UserID)
	if !ok {
		return
	}

	var req sharePingReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	nonce, err := decodeBlob("nonce", req.Nonce, maxNonceBytes)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	ct, err := decodeBlob("ciphertext", req.Ciphertext, maxBlobBytes)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	captured, err := time.Parse(time.RFC3339, req.CapturedAt)
	if err != nil {
		httpx.BadRequest(w, "captured_at must be RFC3339")
		return
	}
	// A session lives at most maxShareTTL, so a fix older than that cannot
	// belong to this share; the future bound is the same clock skew pings allow.
	now := time.Now()
	if captured.Before(now.Add(-maxShareTTL)) || captured.After(now.Add(pingFutureSkew)) {
		httpx.BadRequest(w, "captured_at outside allowed window")
		return
	}

	if err := s.store.UpsertSharePosition(r.Context(), store.UpsertSharePositionParams{
		SessionID: sess.ID, Nonce: nonce, Ciphertext: ct, CapturedAt: captured,
	}); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleGetShare is the viewer's endpoint: PUBLIC, because the recipient is an
// outsider with no account. It returns the sealed position as-is — without
// K_share (which lives in the link fragment the server never receives) the blob
// is meaningless to the server and to anyone who reads its database.
func (s *Server) handleGetShare(w http.ResponseWriter, r *http.Request) {
	id, err := parseUUIDParam(r, "shareID")
	if err != nil {
		httpx.NotFound(w, "share link not found")
		return
	}
	sess, err := s.store.GetShareSession(r.Context(), id)
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "share link not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	// Liveness is checked before binding, so a dead link never mints a cookie.
	if !shareLive(sess, time.Now()) {
		httpx.Gone(w, shareGoneMsg)
		return
	}
	if !s.bindShareViewer(w, r, &sess) {
		return
	}

	var position *sharePositionDTO
	pos, err := s.store.GetSharePosition(r.Context(), sess.ID)
	switch {
	case err == nil:
		position = &sharePositionDTO{
			Nonce: encodeBlob(pos.Nonce), Ciphertext: encodeBlob(pos.Ciphertext), CapturedAt: pos.CapturedAt,
		}
	case !store.IsNotFound(err):
		httpx.Internal(w, err)
		return
	}
	// null until the sharer posts a fix — a fresh link is live but blank.

	// The live position must not linger in a shared cache or a back/forward
	// buffer after the link dies.
	w.Header().Set("Cache-Control", "no-store")
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"expires_at": sess.ExpiresAt,
		"position":   position,
	})
}

// bindShareViewer enforces the one-device rule. The first fetch of a live link
// mints an opaque token, stores only its peppered hash, and returns it in an
// HttpOnly cookie scoped to this link's path; every later fetch must present it.
// That turns a forwarded link into a dead link — the outsider it was sent to
// keeps working, anyone they pass it on to is refused — and it holds even if the
// link leaks through a chat backup, since the cookie never appears in the URL.
//
// It reports whether the request may proceed; on false it has already answered.
func (s *Server) bindShareViewer(w http.ResponseWriter, r *http.Request, sess *store.ShareSession) bool {
	if sess.ViewerTokenHash == nil {
		token, err := crypto.GenerateToken()
		if err != nil {
			httpx.Internal(w, err)
			return false
		}
		bound, err := s.store.BindShareViewer(r.Context(), store.BindShareViewerParams{
			ID:              sess.ID,
			ViewerTokenHash: crypto.HashTokenBytes(s.cfg.SessionPepper, token),
		})
		switch {
		case err == nil:
			*sess = bound
			s.setShareCookie(w, bound, token)
			return true
		case store.IsNotFound(err):
			// Lost the race to another first viewer: the compare-and-swap bound
			// someone else. Re-read and fall through to the cookie check, which
			// this request cannot pass — exactly the intended outcome.
			reloaded, gerr := s.store.GetShareSession(r.Context(), sess.ID)
			if gerr != nil {
				if store.IsNotFound(gerr) {
					httpx.Gone(w, shareGoneMsg)
					return false
				}
				httpx.Internal(w, gerr)
				return false
			}
			*sess = reloaded
		default:
			httpx.Internal(w, err)
			return false
		}
	}

	c, err := r.Cookie(shareCookieName(sess.ID))
	if err != nil || !crypto.ConstantTimeEqualBytes(
		crypto.HashTokenBytes(s.cfg.SessionPepper, c.Value), sess.ViewerTokenHash) {
		httpx.Forbidden(w, "this link is already open on another device")
		return false
	}
	return true
}

// setShareCookie hands the viewer their bearer token for this one link. It is
// scoped to the link's own path (so it is sent nowhere else), HttpOnly (so no
// script can lift it), and expires with the session.
func (s *Server) setShareCookie(w http.ResponseWriter, sess store.ShareSession, token string) {
	maxAge := int(time.Until(sess.ExpiresAt).Seconds())
	if maxAge < 1 {
		maxAge = 1 // a live session always has a positive lifetime left
	}
	http.SetCookie(w, &http.Cookie{ // #nosec G124 -- Secure from config; HttpOnly+SameSite always set
		Name:     shareCookieName(sess.ID),
		Value:    token,
		Path:     shareCookiePath(sess.ID),
		HttpOnly: true,
		Secure:   s.cfg.SecureCookies,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   maxAge,
	})
}

// loadOwnedShare resolves {shareID} to a live session owned by userID. Unknown
// and not-yours are both 404 (a stranger cannot probe for someone else's link);
// dead-but-yours is 410, which the owner's client can act on.
func (s *Server) loadOwnedShare(w http.ResponseWriter, r *http.Request, userID uuid.UUID) (store.ShareSession, bool) {
	id, err := parseUUIDParam(r, "shareID")
	if err != nil {
		httpx.NotFound(w, "share link not found")
		return store.ShareSession{}, false
	}
	sess, err := s.store.GetShareSessionForOwner(r.Context(), store.GetShareSessionForOwnerParams{
		ID: id, UserID: userID,
	})
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "share link not found")
			return store.ShareSession{}, false
		}
		httpx.Internal(w, err)
		return store.ShareSession{}, false
	}
	if !shareLive(sess, time.Now()) {
		httpx.Gone(w, shareGoneMsg)
		return store.ShareSession{}, false
	}
	return sess, true
}

// shareLive reports whether a session may still be written to or read from.
func shareLive(sess store.ShareSession, now time.Time) bool {
	return sess.RevokedAt == nil && sess.ExpiresAt.After(now)
}

// Per-link cookie identity. Naming the cookie after the session and scoping it
// to that session's path keeps concurrent shares independent: one device can
// hold several links, and each is bound on its own.
func shareCookieName(id uuid.UUID) string { return "aul_share_" + id.String() }
func shareCookiePath(id uuid.UUID) string { return "/v1/share/" + id.String() }

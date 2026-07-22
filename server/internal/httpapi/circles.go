package httpapi

import (
	"encoding/base64"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

func (s *Server) mountCircles(r chi.Router) {
	r.Route("/circles", func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		r.Get("/", s.handleListCircles)
		r.Post("/", s.handleCreateCircle)

		r.Route("/{circleID}", func(r chi.Router) {
			r.Use(s.requireCircleMember)
			r.Get("/", s.handleGetCircle)
			r.Patch("/", s.handlePatchCircle)
			r.Delete("/", s.handleDeleteCircle)
			r.Get("/members", s.handleListMembers)
			r.Put("/profile", s.handleSetProfile)
			r.Get("/devices", s.handleCircleDevices)
			r.Delete("/members/{userID}", s.handleRemoveMember)
			r.Post("/leave", s.handleLeaveCircle)
			r.Put("/precision", s.handleSetPrecision)
			r.Post("/rotate-key", s.handleRotateKey)

			// Invites (creation is rate-limited per user).
			r.Get("/invites", s.handleListInvites)
			r.With(s.rateLimitByUser(s.inviteLimiter, 3600)).Post("/invites", s.handleCreateInvite)
			r.Delete("/invites/{inviteID}", s.handleRevokeInvite)

			// Web Push fan-out of a client-sealed blob (rate-limited per user).
			r.With(s.rateLimitByUser(s.notifyLimiter, 60)).Post("/notify", s.handleNotify)

			// Notification mutes: which members' (or the whole circle's) pushes
			// the caller has silenced. Applied by the /notify fan-out above.
			r.Get("/mutes", s.handleGetMutes)
			r.Put("/mutes", s.handleSetMutes)

			// Ping reads (encrypted; server never decrypts).
			r.Get("/pings/latest", s.handleLatestPings)

			// Places, SOS, key envelopes (circle-scoped).
			r.Get("/places", s.handleListPlaces)
			r.Post("/places", s.handleCreatePlace)
			r.Put("/places/{placeID}", s.handleUpdatePlace)
			r.Delete("/places/{placeID}", s.handleDeletePlace)

			r.Get("/sos", s.handleListSOS)
			r.Post("/sos", s.handleCreateSOS)
			r.Post("/sos/{sosID}/resolve", s.handleResolveSOS)
		})
	})
}

type circleDTO struct {
	ID            uuid.UUID `json:"id"`
	NameEnc       *string   `json:"name_enc"` // base64 ciphertext, null if unset
	RetentionDays int32     `json:"retention_days"`
	KeyEpoch      int32     `json:"key_epoch"`
	Role          string    `json:"role"`
	PrecisionMode string    `json:"precision_mode"`
	CreatedAt     time.Time `json:"created_at"`
}

type memberDTO struct {
	UserID        uuid.UUID `json:"user_id"`
	Email         string    `json:"email"` // fallback identity where no profile is set
	Role          string    `json:"role"`
	PrecisionMode string    `json:"precision_mode"`
	JoinedAt      time.Time `json:"joined_at"`
	ProfileEnc    *string   `json:"profile_enc"` // base64 sealed profile (nick+avatar), null if unset
}

func nameEncPtr(b []byte) *string {
	if len(b) == 0 {
		return nil
	}
	s := encodeBlob(b)
	return &s
}

func (s *Server) handleListCircles(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	rows, err := s.store.ListCirclesForUser(r.Context(), a.UserID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]circleDTO, 0, len(rows))
	for _, c := range rows {
		out = append(out, circleDTO{
			ID: c.ID, NameEnc: nameEncPtr(c.NameEnc), RetentionDays: c.RetentionDays,
			KeyEpoch: c.KeyEpoch, Role: c.Role, PrecisionMode: c.PrecisionMode, CreatedAt: c.CreatedAt,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"circles": out})
}

type createCircleReq struct {
	NameEnc       string `json:"name_enc"`       // optional base64
	RetentionDays *int32 `json:"retention_days"` // optional; server default/cap applied
}

func (s *Server) handleCreateCircle(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req createCircleReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	var nameEnc []byte
	if req.NameEnc != "" {
		b, err := decodeBlob("name_enc", req.NameEnc, maxBlobBytes)
		if err != nil {
			httpx.BadRequest(w, err.Error())
			return
		}
		nameEnc = b
	}
	retention := int32(s.cfg.DefaultRetentionDays) // #nosec G115 -- config-validated to 1..3650
	if req.RetentionDays != nil {
		retention = *req.RetentionDays
	}
	if !s.validRetention(retention) {
		httpx.BadRequest(w, "retention_days out of allowed range")
		return
	}

	var circle store.Circle
	err := s.store.WithTx(r.Context(), func(q store.Querier) error {
		c, err := q.CreateCircle(r.Context(), store.CreateCircleParams{
			NameEnc: nameEnc, RetentionDays: retention, CreatedBy: a.UserID,
		})
		if err != nil {
			return err
		}
		if _, err := q.AddMember(r.Context(), store.AddMemberParams{
			CircleID: c.ID, UserID: a.UserID, Role: "owner",
		}); err != nil {
			return err
		}
		circle = c
		return nil
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventCircleCreated, UserID: &a.UserID, CircleID: &circle.ID, IP: clientIP(r)})
	httpx.WriteJSON(w, http.StatusCreated, circleDTO{
		ID: circle.ID, NameEnc: nameEncPtr(circle.NameEnc), RetentionDays: circle.RetentionDays,
		KeyEpoch: circle.KeyEpoch, Role: "owner", PrecisionMode: "precise", CreatedAt: circle.CreatedAt,
	})
}

func (s *Server) handleGetCircle(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	circle, err := s.store.GetCircle(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, circleDTO{
		ID: circle.ID, NameEnc: nameEncPtr(circle.NameEnc), RetentionDays: circle.RetentionDays,
		KeyEpoch: circle.KeyEpoch, Role: m.Role, PrecisionMode: m.PrecisionMode, CreatedAt: circle.CreatedAt,
	})
}

type patchCircleReq struct {
	NameEnc       *string `json:"name_enc"`       // base64; present to change
	RetentionDays *int32  `json:"retention_days"` // present to change
}

func (s *Server) handlePatchCircle(w http.ResponseWriter, r *http.Request) {
	m, ok := requireOwner(w, r)
	if !ok {
		return
	}
	var req patchCircleReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if req.NameEnc != nil {
		b, err := decodeBlob("name_enc", *req.NameEnc, maxBlobBytes)
		if err != nil {
			httpx.BadRequest(w, err.Error())
			return
		}
		if _, err := s.store.UpdateCircleName(r.Context(), store.UpdateCircleNameParams{ID: m.CircleID, NameEnc: b}); err != nil {
			httpx.Internal(w, err)
			return
		}
	}
	if req.RetentionDays != nil {
		if !s.validRetention(*req.RetentionDays) {
			httpx.BadRequest(w, "retention_days out of allowed range")
			return
		}
		if _, err := s.store.UpdateCircleRetention(r.Context(), store.UpdateCircleRetentionParams{ID: m.CircleID, RetentionDays: *req.RetentionDays}); err != nil {
			httpx.Internal(w, err)
			return
		}
	}
	s.handleGetCircle(w, r)
}

func (s *Server) handleDeleteCircle(w http.ResponseWriter, r *http.Request) {
	m, ok := requireOwner(w, r)
	if !ok {
		return
	}
	if err := s.store.DeleteCircle(r.Context(), m.CircleID); err != nil {
		httpx.Internal(w, err)
		return
	}
	s.hub.EvictCircle(m.CircleID)
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (s *Server) handleListMembers(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.ListMembers(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]memberDTO, 0, len(rows))
	for _, mm := range rows {
		out = append(out, memberDTO{
			UserID: mm.UserID, Email: mm.Email, Role: mm.Role,
			PrecisionMode: mm.PrecisionMode, JoinedAt: mm.JoinedAt,
			ProfileEnc: nameEncPtr(mm.ProfileEnc),
		})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"members": out})
}

type profileReq struct {
	// ProfileEnc is a base64 blob sealed under the circle key K_c (nick+avatar,
	// ad "aul-profile:v1"); the server never decrypts it. null clears the profile.
	ProfileEnc *string `json:"profile_enc"`
}

// handleSetProfile stores the caller's own sealed per-circle profile. Membership
// is already enforced by requireCircleMember (a non-member gets 404), so this
// only ever writes the authenticated member's row.
func (s *Server) handleSetProfile(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	var req profileReq
	if err := httpx.DecodeJSON(w, r, &req, profileJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	var blob []byte
	if req.ProfileEnc != nil {
		b, err := base64.StdEncoding.DecodeString(*req.ProfileEnc)
		if err != nil {
			httpx.BadRequest(w, "profile_enc must be base64")
			return
		}
		if len(b) > maxProfileBytes {
			httpx.BadRequest(w, "profile too large")
			return
		}
		blob = b // nil when the string was empty → stores SQL NULL (also clears)
	}
	if err := s.store.SetMemberProfile(r.Context(), store.SetMemberProfileParams{
		CircleID: m.CircleID, UserID: m.UserID, ProfileEnc: blob,
	}); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	m, ok := requireOwner(w, r)
	if !ok {
		return
	}
	target, err := parseUUIDParam(r, "userID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if target == m.UserID {
		httpx.BadRequest(w, "use /leave to remove yourself")
		return
	}
	if err := s.store.RemoveMember(r.Context(), store.RemoveMemberParams{CircleID: m.CircleID, UserID: target}); err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventMemberRemoved, UserID: &m.UserID, CircleID: &m.CircleID, IP: clientIP(r), Detail: map[string]any{"removed": target.String()}})
	// Immediately cut the removed member's live feed of this circle.
	s.hub.EvictUser(m.CircleID, target)
	s.hub.Publish(realtime.Event{Type: realtime.EventMemberChanged, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "removed", "note": "rotate the circle key"})
}

// handleLeaveCircle lets a member leave immediately, no owner approval
// (anti-stalking guarantee). A sole owner must delete or transfer first.
func (s *Server) handleLeaveCircle(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	if m.Role == "owner" {
		owners, err := s.store.CountOwners(r.Context(), m.CircleID)
		if err != nil {
			httpx.Internal(w, err)
			return
		}
		if owners <= 1 {
			httpx.Conflict(w, "transfer ownership or delete the circle before leaving")
			return
		}
	}
	if err := s.store.RemoveMember(r.Context(), store.RemoveMemberParams{CircleID: m.CircleID, UserID: m.UserID}); err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventMemberLeft, UserID: &m.UserID, CircleID: &m.CircleID, IP: clientIP(r)})
	// Instant leave: stop this member's live feed of the circle right away.
	s.hub.EvictUser(m.CircleID, m.UserID)
	s.hub.Publish(realtime.Event{Type: realtime.EventMemberChanged, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "left"})
}

type precisionReq struct {
	Mode string `json:"mode"`
}

func (s *Server) handleSetPrecision(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	var req precisionReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	switch req.Mode {
	case "precise", "city", "paused":
	default:
		httpx.BadRequest(w, "mode must be precise, city, or paused")
		return
	}
	updated, err := s.store.SetPrecisionMode(r.Context(), store.SetPrecisionModeParams{
		CircleID: m.CircleID, UserID: m.UserID, PrecisionMode: req.Mode,
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	// The circle sees precision mode (metadata) — notify watchers.
	s.hub.Publish(realtime.Event{Type: realtime.EventPrecisionMode, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"precision_mode": updated.PrecisionMode})
}

// handleRotateKey bumps the circle key epoch. The owner then distributes the new
// K_c to remaining members via sealed key envelopes.
func (s *Server) handleRotateKey(w http.ResponseWriter, r *http.Request) {
	m, ok := requireOwner(w, r)
	if !ok {
		return
	}
	circle, err := s.store.BumpCircleKeyEpoch(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventKeyRotation, UserID: &m.UserID, CircleID: &m.CircleID, IP: clientIP(r), Detail: map[string]any{"epoch": circle.KeyEpoch}})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"key_epoch": circle.KeyEpoch})
}

func (s *Server) validRetention(days int32) bool {
	return days >= 1 && int(days) <= s.cfg.MaxRetentionDays
}

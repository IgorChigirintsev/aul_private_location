package httpapi

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

// mountInvites registers the top-level (non-circle-scoped) invite routes for
// people who are not yet members.
func (s *Server) mountInvites(r chi.Router) {
	r.Route("/invites", func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		r.Get("/{inviteID}", s.handleGetInvite)
		r.Post("/{inviteID}/accept", s.handleAcceptInvite)
	})
}

type inviteDTO struct {
	ID        uuid.UUID `json:"id"`
	CircleID  uuid.UUID `json:"circle_id"`
	Role      string    `json:"role"`
	MaxUses   int32     `json:"max_uses"`
	Uses      int32     `json:"uses"`
	ExpiresAt time.Time `json:"expires_at"`
	Status    string    `json:"status"`
}

type createInviteReq struct {
	Role       string `json:"role"`        // member|guardian (default member)
	MaxUses    int32  `json:"max_uses"`    // default 1
	TTLSeconds int64  `json:"ttl_seconds"` // default 7 days, max 30 days
}

func (s *Server) handleCreateInvite(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	if m.Role == "guardian" {
		httpx.Forbidden(w, "guardian accounts cannot create invites")
		return
	}
	var req createInviteReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	role := req.Role
	if role == "" {
		role = "member"
	}
	if role != "member" && role != "guardian" {
		httpx.BadRequest(w, "role must be member or guardian")
		return
	}
	maxUses := req.MaxUses
	if maxUses <= 0 {
		maxUses = 1
	}
	if maxUses > 1000 {
		httpx.BadRequest(w, "max_uses too large")
		return
	}
	ttl := time.Duration(req.TTLSeconds) * time.Second
	if ttl <= 0 {
		ttl = 7 * 24 * time.Hour
	}
	if ttl > 30*24*time.Hour {
		httpx.BadRequest(w, "ttl_seconds exceeds 30 days")
		return
	}
	inv, err := s.store.CreateInvite(r.Context(), store.CreateInviteParams{
		CircleID:  m.CircleID,
		CreatedBy: m.UserID,
		Role:      role,
		MaxUses:   maxUses,
		ExpiresAt: time.Now().Add(ttl),
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventInviteCreated, UserID: &m.UserID, CircleID: &m.CircleID, IP: clientIP(r)})
	httpx.WriteJSON(w, http.StatusCreated, inviteToDTO(inv))
}

func (s *Server) handleListInvites(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.ListInvitesForCircle(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]inviteDTO, 0, len(rows))
	for _, inv := range rows {
		out = append(out, inviteToDTO(inv))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"invites": out})
}

func (s *Server) handleRevokeInvite(w http.ResponseWriter, r *http.Request) {
	m, ok := requireOwner(w, r)
	if !ok {
		return
	}
	inviteID, err := parseUUIDParam(r, "inviteID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if err := s.store.RevokeInvite(r.Context(), store.RevokeInviteParams{ID: inviteID, CircleID: m.CircleID}); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "revoked"})
}

// handleGetInvite returns minimal, non-sensitive invite status so a prospective
// member can decide to accept. The circle key is never here — it is in the URL
// fragment the server never sees.
func (s *Server) handleGetInvite(w http.ResponseWriter, r *http.Request) {
	inviteID, err := parseUUIDParam(r, "inviteID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	inv, err := s.store.GetInvite(r.Context(), inviteID)
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "invite not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	valid := inv.Status == "active" && inv.ExpiresAt.After(time.Now()) && inv.Uses < inv.MaxUses
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"circle_id":  inv.CircleID,
		"role":       inv.Role,
		"expires_at": inv.ExpiresAt,
		"valid":      valid,
	})
}

// handleAcceptInvite atomically consumes one invite use and adds the caller as a
// member. Idempotent for an already-joined user.
func (s *Server) handleAcceptInvite(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	inviteID, err := parseUUIDParam(r, "inviteID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}

	inv, err := s.store.GetInvite(r.Context(), inviteID)
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "invite not found")
			return
		}
		httpx.Internal(w, err)
		return
	}

	// Already a member? Treat as success (idempotent), without consuming a use.
	if _, merr := s.store.GetMembership(r.Context(), store.GetMembershipParams{CircleID: inv.CircleID, UserID: a.UserID}); merr == nil {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"circle_id": inv.CircleID, "status": "already_member"})
		return
	} else if !store.IsNotFound(merr) {
		httpx.Internal(w, merr)
		return
	}

	var joinedRole string
	err = s.store.WithTx(r.Context(), func(q store.Querier) error {
		consumed, cerr := q.ConsumeInvite(r.Context(), inviteID)
		if cerr != nil {
			return cerr // includes pgx.ErrNoRows when exhausted/expired/revoked
		}
		joinedRole = consumed.Role
		_, aerr := q.AddMember(r.Context(), store.AddMemberParams{
			CircleID: consumed.CircleID, UserID: a.UserID, Role: consumed.Role,
		})
		return aerr
	})
	if err != nil {
		if store.IsNotFound(err) {
			httpx.WriteError(w, http.StatusGone, httpx.CodeConflict, "invite expired, revoked, or fully used")
			return
		}
		httpx.Internal(w, err)
		return
	}

	s.audit.Log(r.Context(), audit.Event{Name: audit.EventInviteAccepted, UserID: &a.UserID, CircleID: &inv.CircleID, IP: clientIP(r)})
	s.hub.Publish(realtime.Event{Type: realtime.EventMemberChanged, CircleID: inv.CircleID})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"circle_id": inv.CircleID,
		"role":      joinedRole,
		"status":    "joined",
	})
}

func inviteToDTO(inv store.Invite) inviteDTO {
	return inviteDTO{
		ID: inv.ID, CircleID: inv.CircleID, Role: inv.Role,
		MaxUses: inv.MaxUses, Uses: inv.Uses, ExpiresAt: inv.ExpiresAt, Status: inv.Status,
	}
}

package httpapi

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

type sosDTO struct {
	ID         uuid.UUID  `json:"id"`
	CircleID   uuid.UUID  `json:"circle_id"`
	DeviceID   *uuid.UUID `json:"device_id,omitempty"`
	Ciphertext string     `json:"ciphertext"`
	CreatedAt  time.Time  `json:"created_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
}

type sosReq struct {
	Ciphertext string `json:"ciphertext"`
}

func (s *Server) handleCreateSOS(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	a := httpx.MustAuth(r.Context())
	var req sosReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	ct, err := decodeBlob("ciphertext", req.Ciphertext, maxBlobBytes)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	device := a.DeviceID
	ev, err := s.store.CreateSOS(r.Context(), store.CreateSOSParams{
		CircleID: m.CircleID, DeviceID: &device, Ciphertext: ct,
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventSOSCreated, UserID: &m.UserID, DeviceID: &device, CircleID: &m.CircleID, IP: clientIP(r)})
	// Highest-priority fan-out: alert every watcher immediately.
	s.hub.Publish(realtime.Event{Type: realtime.EventSOS, CircleID: m.CircleID, Payload: mustJSON(sosToDTO(ev))})
	httpx.WriteJSON(w, http.StatusCreated, sosToDTO(ev))
}

func (s *Server) handleResolveSOS(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	sosID, err := parseUUIDParam(r, "sosID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	ev, err := s.store.ResolveSOS(r.Context(), store.ResolveSOSParams{
		ID: sosID, CircleID: m.CircleID, ResolvedBy: &m.UserID,
	})
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "active SOS not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventSOSResolved, UserID: &m.UserID, CircleID: &m.CircleID, IP: clientIP(r)})
	s.hub.Publish(realtime.Event{Type: realtime.EventSOSResolved, CircleID: m.CircleID, Payload: mustJSON(map[string]any{"id": ev.ID})})
	httpx.WriteJSON(w, http.StatusOK, sosToDTO(ev))
}

func (s *Server) handleListSOS(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.ListActiveSOS(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]sosDTO, 0, len(rows))
	for _, ev := range rows {
		out = append(out, sosToDTO(ev))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sos": out})
}

func sosToDTO(ev store.SosEvent) sosDTO {
	return sosDTO{
		ID: ev.ID, CircleID: ev.CircleID, DeviceID: ev.DeviceID,
		Ciphertext: encodeBlob(ev.Ciphertext), CreatedAt: ev.CreatedAt, ResolvedAt: ev.ResolvedAt,
	}
}

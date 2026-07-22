package httpapi

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

type placeDTO struct {
	ID         uuid.UUID `json:"id"`
	Ciphertext string    `json:"ciphertext"`
	Version    int32     `json:"version"`
	UpdatedAt  time.Time `json:"updated_at"`
	// CreatedBy is the author, for "«Home» · <owner nick>". It is a user id, not
	// a name: the nick lives in the member's sealed profile and the place's name
	// inside Ciphertext — the client joins them. null once the author's account
	// is gone (ON DELETE SET NULL).
	CreatedBy *uuid.UUID `json:"created_by"`
}

func (s *Server) handleListPlaces(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.ListPlaces(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]placeDTO, 0, len(rows))
	for _, p := range rows {
		out = append(out, placeToDTO(p))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"places": out})
}

type placeReq struct {
	Ciphertext string `json:"ciphertext"`
	Version    int32  `json:"version"` // required for update (optimistic concurrency)
}

func (s *Server) handleCreatePlace(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	var req placeReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	ct, err := decodeBlob("ciphertext", req.Ciphertext, maxBlobBytes)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	p, err := s.store.CreatePlace(r.Context(), store.CreatePlaceParams{
		CircleID: m.CircleID, Ciphertext: ct, AuthorID: &m.UserID,
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	s.hub.Publish(realtime.Event{Type: realtime.EventPlaceUpdated, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusCreated, placeToDTO(p))
}

func (s *Server) handleUpdatePlace(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	placeID, err := parseUUIDParam(r, "placeID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	var req placeReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	ct, err := decodeBlob("ciphertext", req.Ciphertext, maxBlobBytes)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	p, err := s.store.UpdatePlace(r.Context(), store.UpdatePlaceParams{
		ID: placeID, CircleID: m.CircleID, Ciphertext: ct, UpdatedBy: &m.UserID, Version: req.Version,
	})
	if err != nil {
		if store.IsNotFound(err) {
			httpx.Conflict(w, "place not found or version mismatch; re-sync and retry")
			return
		}
		httpx.Internal(w, err)
		return
	}
	s.hub.Publish(realtime.Event{Type: realtime.EventPlaceUpdated, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusOK, placeToDTO(p))
}

func (s *Server) handleDeletePlace(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	placeID, err := parseUUIDParam(r, "placeID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if _, err := s.store.SoftDeletePlace(r.Context(), store.SoftDeletePlaceParams{
		ID: placeID, CircleID: m.CircleID, UpdatedBy: &m.UserID,
	}); err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "place not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	s.hub.Publish(realtime.Event{Type: realtime.EventPlaceUpdated, CircleID: m.CircleID})
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func placeToDTO(p store.PlacesEnc) placeDTO {
	return placeDTO{
		ID: p.ID, Ciphertext: encodeBlob(p.Ciphertext), Version: p.Version,
		UpdatedAt: p.UpdatedAt, CreatedBy: p.CreatedBy,
	}
}

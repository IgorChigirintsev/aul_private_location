package httpapi

import (
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

type circleDeviceDTO struct {
	ID        uuid.UUID `json:"id"`
	UserID    uuid.UUID `json:"user_id"`
	Platform  string    `json:"platform"`
	PubkeyB64 *string   `json:"pubkey"` // base64 X25519 identity public key, null if unset
}

// handleCircleDevices lists the member devices of a circle with their identity
// public keys. Members use this to (a) seal K_c envelopes to each device on
// join/rotation and (b) compute safety codes. Public keys are safe to share
// within a circle.
func (s *Server) handleCircleDevices(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	devices, err := s.store.ListCircleDevices(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]circleDeviceDTO, 0, len(devices))
	for _, d := range devices {
		var pk *string
		if len(d.Pubkey) > 0 {
			v := encodeBlob(d.Pubkey)
			pk = &v
		}
		out = append(out, circleDeviceDTO{ID: d.ID, UserID: d.UserID, Platform: d.Platform, PubkeyB64: pk})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// mountKeyEnvelopes registers sealed-key-envelope relay routes. The server only
// relays crypto_box_seal boxes it cannot open (see THREAT_MODEL).
func (s *Server) mountKeyEnvelopes(r chi.Router) {
	r.Route("/key-envelopes", func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		// Key distribution is infrequent (only on rotation/join); rate-limit the
		// write per user to bound DB write-amplification.
		r.With(s.rateLimitByUser(s.keyEnvLimiter, 60)).Post("/", s.handlePostKeyEnvelopes)
		r.Get("/pending", s.handlePendingKeyEnvelopes)
		r.Post("/{envelopeID}/consume", s.handleConsumeKeyEnvelope)
	})
}

type keyEnvelopeItem struct {
	RecipientDeviceID string `json:"recipient_device_id"`
	Ciphertext        string `json:"ciphertext"` // base64 crypto_box_seal(K_c)
	KeyEpoch          int32  `json:"key_epoch"`
}

type postKeyEnvelopesReq struct {
	CircleID  string            `json:"circle_id"`
	Envelopes []keyEnvelopeItem `json:"envelopes"`
}

// handlePostKeyEnvelopes lets a circle owner distribute the (rotated) circle key
// to member devices as sealed boxes. Recipients must be devices of current
// circle members.
func (s *Server) handlePostKeyEnvelopes(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req postKeyEnvelopesReq
	if err := httpx.DecodeJSON(w, r, &req, pingJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	circleID, err := uuid.Parse(req.CircleID)
	if err != nil {
		httpx.BadRequest(w, "circle_id must be a valid id")
		return
	}
	membership, err := s.store.GetMembership(r.Context(), store.GetMembershipParams{CircleID: circleID, UserID: a.UserID})
	if err != nil {
		if store.IsNotFound(err) {
			httpx.NotFound(w, "circle not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	if membership.Role != "owner" {
		httpx.Forbidden(w, "owner role required to distribute keys")
		return
	}
	if len(req.Envelopes) == 0 || len(req.Envelopes) > maxKeyEnvelopes {
		httpx.BadRequest(w, "envelopes must contain 1..200 items")
		return
	}
	// The circle's current key epoch. Clients send key_epoch=0 meaning "the
	// current epoch"; distributing at a distinct epoch per rotation keeps one
	// pending envelope per rotation so a device offline across N rotations can
	// catch up on every intermediate key (history stays readable).
	circle, err := s.store.GetCircle(r.Context(), circleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}

	// Build the set of valid recipient devices (devices of circle members).
	validDevices := map[uuid.UUID]bool{}
	devices, err := s.store.ListCircleDevices(r.Context(), circleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	for _, d := range devices {
		validDevices[d.ID] = true
	}

	senderDevice := a.DeviceID
	count := 0
	err = s.store.WithTx(r.Context(), func(q store.Querier) error {
		for i, e := range req.Envelopes {
			rid, perr := uuid.Parse(e.RecipientDeviceID)
			if perr != nil {
				return badItem(i, "recipient_device_id must be a valid id")
			}
			if !validDevices[rid] {
				return badItem(i, "recipient_device_id is not a device of a circle member")
			}
			ct, derr := decodeBlob("ciphertext", e.Ciphertext, maxBlobBytes)
			if derr != nil {
				return badItem(i, derr.Error())
			}
			epoch := e.KeyEpoch
			if epoch <= 0 {
				epoch = circle.KeyEpoch
			}
			if _, ierr := q.CreateKeyEnvelope(r.Context(), store.CreateKeyEnvelopeParams{
				CircleID:          circleID,
				RecipientDeviceID: rid,
				SenderDeviceID:    &senderDevice,
				Ciphertext:        ct,
				KeyEpoch:          epoch,
			}); ierr != nil {
				return ierr
			}
			count++
		}
		return nil
	})
	if err != nil {
		var be *itemError
		if errors.As(err, &be) {
			httpx.BadRequest(w, be.Error())
			return
		}
		httpx.Internal(w, err)
		return
	}
	s.audit.Log(r.Context(), audit.Event{Name: audit.EventKeyEnvelopeSent, UserID: &a.UserID, DeviceID: &senderDevice, CircleID: &circleID, IP: clientIP(r), Detail: map[string]any{"count": count}})
	// Nudge recipients to fetch pending envelopes.
	s.hub.Publish(realtime.Event{Type: realtime.EventKeyEnvelope, CircleID: circleID})
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"delivered": count})
}

type keyEnvelopeDTO struct {
	ID             uuid.UUID  `json:"id"`
	CircleID       uuid.UUID  `json:"circle_id"`
	SenderDeviceID *uuid.UUID `json:"sender_device_id,omitempty"`
	Ciphertext     string     `json:"ciphertext"`
	KeyEpoch       int32      `json:"key_epoch"`
	CreatedAt      time.Time  `json:"created_at"`
}

func (s *Server) handlePendingKeyEnvelopes(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	rows, err := s.store.PendingEnvelopesForDevice(r.Context(), a.DeviceID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]keyEnvelopeDTO, 0, len(rows))
	for _, e := range rows {
		out = append(out, keyEnvelopeDTO{
			ID: e.ID, CircleID: e.CircleID, SenderDeviceID: e.SenderDeviceID,
			Ciphertext: encodeBlob(e.Ciphertext), KeyEpoch: e.KeyEpoch, CreatedAt: e.CreatedAt,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"envelopes": out})
}

func (s *Server) handleConsumeKeyEnvelope(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	envelopeID, err := parseUUIDParam(r, "envelopeID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if err := s.store.MarkEnvelopeConsumed(r.Context(), store.MarkEnvelopeConsumedParams{
		ID: envelopeID, RecipientDeviceID: a.DeviceID,
	}); err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "consumed"})
}

// itemError carries a per-item validation message out of a transaction.
type itemError struct{ msg string }

func (e *itemError) Error() string { return e.msg }
func badItem(i int, msg string) error {
	return &itemError{msg: "envelope[" + itoa(i) + "]: " + msg}
}

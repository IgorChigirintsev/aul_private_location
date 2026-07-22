package httpapi

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/store"
)

// mountPings registers the top-level device ping-batch endpoint. Batches may
// address multiple circles (a reporter encrypts the same fix once per circle
// key); membership is verified per referenced circle.
func (s *Server) mountPings(r chi.Router) {
	r.Route("/pings", func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		r.With(s.rateLimitByDevice(s.pingLimiter, 60)).Post("/batch", s.handlePingBatch)
	})
}

type pingItem struct {
	CircleID   string `json:"circle_id"`
	ClientID   string `json:"client_id"`
	Nonce      string `json:"nonce"`       // base64
	Ciphertext string `json:"ciphertext"`  // base64, ≤ 4 KiB
	CapturedAt string `json:"captured_at"` // RFC3339
	TTLSeconds int64  `json:"ttl_seconds"` // optional per-ping expiry hint
}

type pingBatchReq struct {
	Pings []pingItem `json:"pings"`
}

type pingDTO struct {
	ID         uuid.UUID `json:"id"`
	CircleID   uuid.UUID `json:"circle_id"`
	DeviceID   uuid.UUID `json:"device_id"`
	Nonce      string    `json:"nonce"`
	Ciphertext string    `json:"ciphertext"`
	CapturedAt time.Time `json:"captured_at"`
}

func (s *Server) handlePingBatch(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	var req pingBatchReq
	if err := httpx.DecodeJSON(w, r, &req, pingJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if len(req.Pings) == 0 {
		httpx.BadRequest(w, "pings must not be empty")
		return
	}
	if len(req.Pings) > maxBatchPings {
		httpx.BadRequest(w, "batch exceeds 100 pings")
		return
	}

	now := time.Now()
	oldest := now.Add(-time.Duration(s.cfg.MaxRetentionDays) * 24 * time.Hour)
	future := now.Add(pingFutureSkew)

	// Verify membership once per distinct circle in the batch.
	memberOf := map[uuid.UUID]bool{}
	checkMember := func(cid uuid.UUID) (bool, error) {
		if v, ok := memberOf[cid]; ok {
			return v, nil
		}
		_, err := s.store.GetMembership(r.Context(), store.GetMembershipParams{CircleID: cid, UserID: a.UserID})
		if err != nil {
			if store.IsNotFound(err) {
				memberOf[cid] = false
				return false, nil
			}
			return false, err
		}
		memberOf[cid] = true
		return true, nil
	}

	type prepared struct {
		params store.InsertPingParams
	}
	items := make([]prepared, 0, len(req.Pings))

	for i, p := range req.Pings {
		cid, err := uuid.Parse(p.CircleID)
		if err != nil {
			httpx.BadRequest(w, itemErr(i, "circle_id must be a valid id"))
			return
		}
		ok, err := checkMember(cid)
		if err != nil {
			httpx.Internal(w, err)
			return
		}
		if !ok {
			httpx.Forbidden(w, itemErr(i, "not a member of circle_id"))
			return
		}
		if p.ClientID == "" || len(p.ClientID) > 128 {
			httpx.BadRequest(w, itemErr(i, "client_id required, ≤128 chars"))
			return
		}
		nonce, err := decodeBlob("nonce", p.Nonce, maxNonceBytes)
		if err != nil {
			httpx.BadRequest(w, itemErr(i, err.Error()))
			return
		}
		ct, err := decodeBlob("ciphertext", p.Ciphertext, maxBlobBytes)
		if err != nil {
			httpx.BadRequest(w, itemErr(i, err.Error()))
			return
		}
		captured, err := time.Parse(time.RFC3339, p.CapturedAt)
		if err != nil {
			httpx.BadRequest(w, itemErr(i, "captured_at must be RFC3339"))
			return
		}
		if captured.Before(oldest) || captured.After(future) {
			httpx.BadRequest(w, itemErr(i, "captured_at outside allowed window"))
			return
		}
		var expires *time.Time
		if p.TTLSeconds > 0 {
			e := captured.Add(time.Duration(p.TTLSeconds) * time.Second)
			expires = &e
		}
		items = append(items, prepared{params: store.InsertPingParams{
			CircleID:   cid,
			DeviceID:   a.DeviceID,
			ClientID:   p.ClientID,
			Nonce:      nonce,
			Ciphertext: ct,
			CapturedAt: captured,
			ExpiresAt:  expires,
		}})
	}

	// Insert all in one transaction; collect newly-inserted for fan-out.
	var inserted []store.Ping
	err := s.store.WithTx(r.Context(), func(q store.Querier) error {
		for _, it := range items {
			row, err := q.InsertPing(r.Context(), it.params)
			if err != nil {
				if store.IsNotFound(err) {
					continue // duplicate (ON CONFLICT DO NOTHING) — idempotent skip
				}
				return err
			}
			inserted = append(inserted, row)
		}
		return q.TouchDevice(r.Context(), a.DeviceID)
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}

	// Fan out each new ciphertext blob to watchers of its circle.
	for _, row := range inserted {
		s.publishPing(row)
	}

	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"accepted":  len(req.Pings),
		"stored":    len(inserted),
		"duplicate": len(req.Pings) - len(inserted),
	})
}

func (s *Server) publishPing(row store.Ping) {
	dto := pingToDTO(row)
	payload := mustJSON(dto)
	s.hub.Publish(realtime.Event{Type: realtime.EventPing, CircleID: row.CircleID, Payload: payload})
}

func (s *Server) handleLatestPings(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.LatestPingsForCircle(r.Context(), m.CircleID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]pingDTO, 0, len(rows))
	for _, row := range rows {
		out = append(out, pingToDTO(row))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"pings": out})
}

func pingToDTO(row store.Ping) pingDTO {
	return pingDTO{
		ID: row.ID, CircleID: row.CircleID, DeviceID: row.DeviceID,
		Nonce: encodeBlob(row.Nonce), Ciphertext: encodeBlob(row.Ciphertext), CapturedAt: row.CapturedAt,
	}
}

func itemErr(i int, msg string) string {
	return "ping[" + itoa(i) + "]: " + msg
}

package httpapi

import (
	"net/http"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/store"
)

// maxMutedUsers bounds a mute set. A member can only mute fellow members, so the
// natural ceiling is the circle's size; this just keeps an attacker from POSTing
// an unbounded id array for us to validate.
const maxMutedUsers = 500

// mutesDTO is both the GET response and the PUT request/response body: PUT
// replaces the caller's whole mute set for the circle and echoes back what is
// now stored, so a client can round-trip it without a follow-up GET.
type mutesDTO struct {
	// CircleMuted silences the whole circle — stored as the single
	// muted_user_id IS NULL row.
	CircleMuted bool `json:"circle_muted"`
	// MutedUserIDs are the individually muted members. Always non-null in
	// responses (an empty set is [], not null).
	MutedUserIDs []uuid.UUID `json:"muted_user_ids"`
}

// handleGetMutes returns the CALLER's own mutes in this circle. A member may
// never read whose notifications someone else silenced: that would turn a
// private preference into a social signal ("Dad muted you").
func (s *Server) handleGetMutes(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	rows, err := s.store.ListMutes(r.Context(), store.ListMutesParams{
		UserID: m.UserID, CircleID: m.CircleID,
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, mutesFromRows(rows))
}

// handleSetMutes replaces the caller's entire mute set for this circle. It is a
// PUT, not a PATCH: the client sends the state it wants and gets that state
// back, so repeating the same call changes nothing.
func (s *Server) handleSetMutes(w http.ResponseWriter, r *http.Request) {
	m, _ := membershipFrom(r.Context())
	var req mutesDTO
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if len(req.MutedUserIDs) > maxMutedUsers {
		httpx.BadRequest(w, "too many muted_user_ids")
		return
	}

	// Dedupe: the same id twice is the same mute, and the request should not
	// fail over a client's sloppy list.
	ids := make([]uuid.UUID, 0, len(req.MutedUserIDs))
	seen := make(map[uuid.UUID]bool, len(req.MutedUserIDs))
	for _, id := range req.MutedUserIDs {
		// Reject rather than silently drop self-mutes. Dropping would break the
		// PUT contract — the response (and the next GET) would not match what
		// was sent — and it would hide a real client bug, since muting yourself
		// is meaningless: the fan-out already excludes the sender's own devices.
		if id == m.UserID {
			httpx.BadRequest(w, "cannot mute yourself")
			return
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}

	// Every muted id must be a member of THIS circle. Otherwise the endpoint
	// would happily store arbitrary user ids, making it an oracle for "does this
	// account exist" and letting mutes accumulate for strangers.
	if len(ids) > 0 {
		n, err := s.store.CountMembersIn(r.Context(), store.CountMembersInParams{
			CircleID: m.CircleID, UserIds: ids,
		})
		if err != nil {
			httpx.Internal(w, err)
			return
		}
		if int(n) != len(ids) {
			httpx.BadRequest(w, "muted_user_ids must all be members of this circle")
			return
		}
	}

	// Replace atomically: a reader must never observe the empty middle of a
	// delete-then-insert and start pushing to a member who is still muted.
	err := s.store.WithTx(r.Context(), func(q store.Querier) error {
		if err := q.DeleteMutes(r.Context(), store.DeleteMutesParams{
			UserID: m.UserID, CircleID: m.CircleID,
		}); err != nil {
			return err
		}
		if req.CircleMuted {
			// muted_user_id NULL = the whole circle.
			if err := q.InsertMute(r.Context(), store.InsertMuteParams{
				UserID: m.UserID, CircleID: m.CircleID, MutedUserID: nil,
			}); err != nil {
				return err
			}
		}
		for _, id := range ids {
			if err := q.InsertMute(r.Context(), store.InsertMuteParams{
				UserID: m.UserID, CircleID: m.CircleID, MutedUserID: &id,
			}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, mutesDTO{CircleMuted: req.CircleMuted, MutedUserIDs: ids})
}

// mutesFromRows folds the stored rows into the wire shape: the NULL row becomes
// circle_muted, the rest become muted_user_ids.
func mutesFromRows(rows []*uuid.UUID) mutesDTO {
	out := mutesDTO{MutedUserIDs: make([]uuid.UUID, 0, len(rows))}
	for _, id := range rows {
		if id == nil {
			out.CircleMuted = true
			continue
		}
		out.MutedUserIDs = append(out.MutedUserIDs, *id)
	}
	return out
}

//go:build integration

package httpapi_test

import (
	"net/http"
	"testing"
)

// TestAPI_KeyEnvelopes_PerEpochDistribution guards the Phase-4 rotation-correctness
// fix: envelopes posted with key_epoch=0 must be clamped to the circle's *current*
// key epoch (not hardcoded to 1). A device offline across two rotations must find
// one pending envelope per rotation — otherwise the intermediate key is silently
// overwritten (upsert on (circle,device,epoch)) and history sealed under it becomes
// permanently unreadable on that device.
func TestAPI_KeyEnvelopes_PerEpochDistribution(t *testing.T) {
	c := newTestServer(t)

	aTok, _ := register(c, "owner-kev@ex.com", "web")
	bTok, bDev := register(c, "member-kev@ex.com", "android")

	// Owner creates a circle (key_epoch starts at 1); member joins.
	code, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{"retention_days": 7})
	if code != http.StatusCreated {
		t.Fatalf("create circle: %d %v", code, circle)
	}
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 2})
	if code, acc := c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil); code != http.StatusOK {
		t.Fatalf("accept: %d %v", code, acc)
	}

	post := func(ct string) {
		code, body := c.do(http.MethodPost, "/v1/key-envelopes", aTok, map[string]any{
			"circle_id": circleID,
			"envelopes": []map[string]any{{
				"recipient_device_id": bDev, "ciphertext": b64(ct), "key_epoch": 0,
			}},
		})
		if code != http.StatusCreated || int(body["delivered"].(float64)) != 1 {
			t.Fatalf("post envelope %q: %d %v", ct, code, body)
		}
	}
	rotate := func() int32 {
		code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/rotate-key", aTok, nil)
		if code != http.StatusOK {
			t.Fatalf("rotate: %d %v", code, body)
		}
		return int32(body["key_epoch"].(float64))
	}

	// Distribute the initial key (epoch 1), then rotate → epoch 2 and distribute
	// again, then rotate → epoch 3 and distribute again. Client contract: bump
	// the epoch *before* distributing, so each key lands at a distinct epoch.
	post("KEY-EPOCH-1")
	if e := rotate(); e != 2 {
		t.Fatalf("first rotation: expected epoch 2, got %d", e)
	}
	post("KEY-EPOCH-2")
	if e := rotate(); e != 3 {
		t.Fatalf("second rotation: expected epoch 3, got %d", e)
	}
	post("KEY-EPOCH-3")

	// The member has been "offline" the whole time: pending must hold all three
	// envelopes at distinct epochs (1,2,3) — proof the rows were not collapsed.
	_, pend := c.do(http.MethodGet, "/v1/key-envelopes/pending", bTok, nil)
	envs := pend["envelopes"].([]any)
	if len(envs) != 3 {
		t.Fatalf("expected 3 pending envelopes (one per epoch), got %d: %v", len(envs), envs)
	}
	epochs := map[int32]bool{}
	for _, e := range envs {
		epochs[int32(e.(map[string]any)["key_epoch"].(float64))] = true
	}
	for _, want := range []int32{1, 2, 3} {
		if !epochs[want] {
			t.Fatalf("missing pending envelope for epoch %d; saw %v", want, epochs)
		}
	}

	// Re-distributing at the same (unchanged) epoch upserts in place rather than
	// piling up rows — deliver the current key again without a rotation.
	post("KEY-EPOCH-3-REDELIVERED")
	_, pend2 := c.do(http.MethodGet, "/v1/key-envelopes/pending", bTok, nil)
	if n := len(pend2["envelopes"].([]any)); n != 3 {
		t.Fatalf("re-delivery at same epoch should stay at 3 envelopes, got %d", n)
	}
}

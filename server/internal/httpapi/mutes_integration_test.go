//go:build integration

package httpapi_test

import (
	"net/http"
	"sort"
	"testing"
)

// userIDOf returns the caller's own user id.
func userIDOf(c *apiClient, token string) string {
	c.t.Helper()
	code, me := c.do(http.MethodGet, "/v1/account/me", token, nil)
	if code != http.StatusOK {
		c.t.Fatalf("account/me: %d %v", code, me)
	}
	return me["id"].(string)
}

// joinCircle adds a member to an existing circle via a fresh invite.
func joinCircle(c *apiClient, circleID, ownerTok, memberTok string) {
	c.t.Helper()
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", ownerTok, map[string]any{"max_uses": 5})
	code, acc := c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", memberTok, nil)
	if code != http.StatusOK {
		c.t.Fatalf("accept invite: %d %v", code, acc)
	}
}

// setMutes PUTs a mute set and returns the response body.
func setMutes(c *apiClient, circleID, token string, circleMuted bool, ids []string) map[string]any {
	c.t.Helper()
	if ids == nil {
		ids = []string{}
	}
	code, body := c.do(http.MethodPut, "/v1/circles/"+circleID+"/mutes", token, map[string]any{
		"circle_muted": circleMuted, "muted_user_ids": ids,
	})
	if code != http.StatusOK {
		c.t.Fatalf("put mutes: %d %v", code, body)
	}
	return body
}

// mutedIDs pulls muted_user_ids out of a mutes body, sorted for comparison.
func mutedIDs(t *testing.T, body map[string]any) []string {
	t.Helper()
	raw, ok := body["muted_user_ids"].([]any)
	if !ok {
		t.Fatalf("muted_user_ids missing or not a list: %v", body["muted_user_ids"])
	}
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		out = append(out, v.(string))
	}
	sort.Strings(out)
	return out
}

// A member who muted the whole circle receives NO push from it — the fan-out
// must not even hand their endpoint to the push service.
func TestMutes_MutedCircleGetsNoPush(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	subscribe(c, bTok, push.URL+"/bob")

	// Bob mutes the entire circle.
	setMutes(c, circleID, bTok, true, nil)

	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	// A muted member is not a recipient at all: not sent, and not failed either.
	if int(body["sent"].(float64)) != 0 || int(body["failed"].(float64)) != 0 {
		t.Fatalf("counts = %v, want sent=0 failed=0 (muted member is not a recipient)", body)
	}
	if paths := push.calledPaths(); len(paths) != 0 {
		t.Fatalf("push service was called %v; a circle-muted member must receive nothing", paths)
	}
}

// Muting ONE member stops that member's pushes only — everyone else still
// notifies me, and my mute does not affect what others receive.
func TestMutes_MutedSenderGetsNoPushButOthersDo(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	dTok, _ := register(c, "dad@ex.com", "web")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	joinCircle(c, circleID, aTok, dTok)

	subscribe(c, aTok, push.URL+"/alice")
	subscribe(c, bTok, push.URL+"/bob")
	subscribe(c, dTok, push.URL+"/dad")

	// Bob mutes Alice specifically — not the circle.
	setMutes(c, circleID, bTok, false, []string{userIDOf(c, aTok)})

	notify := func(tok string) map[string]any {
		t.Helper()
		code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", tok, map[string]any{
			"payload_enc": b64("sealed-under-K_c"),
		})
		if code != http.StatusOK {
			t.Fatalf("notify: %d %v", code, body)
		}
		return body
	}

	// Alice notifies: Bob muted her, so only Dad is reached.
	body := notify(aTok)
	if int(body["sent"].(float64)) != 1 {
		t.Fatalf("alice notify counts = %v, want sent=1 (dad only)", body)
	}
	paths := push.calledPaths()
	if len(paths) != 1 || paths[0] != "/dad" {
		t.Fatalf("alice's notify reached %v, want only /dad — bob muted alice", paths)
	}

	// Dad notifies: Bob did NOT mute Dad, so Bob is reached (and Alice too).
	// This is the important half — a per-member mute must not become a blanket.
	push.reset()
	body = notify(dTok)
	if int(body["sent"].(float64)) != 2 {
		t.Fatalf("dad notify counts = %v, want sent=2 (alice+bob)", body)
	}
	got := push.calledPaths()
	sort.Strings(got)
	if len(got) != 2 || got[0] != "/alice" || got[1] != "/bob" {
		t.Fatalf("dad's notify reached %v, want /alice and /bob — bob only muted alice", got)
	}
}

// A mute is directional and private: Bob muting Alice does not stop Bob's own
// notifications from reaching Alice.
func TestMutes_AreDirectional(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	subscribe(c, aTok, push.URL+"/alice")
	subscribe(c, bTok, push.URL+"/bob")

	setMutes(c, circleID, bTok, false, []string{userIDOf(c, aTok)})

	// Bob notifies: he muted Alice's pushes TO him, not his TO her.
	code, body := c.do(http.MethodPost, "/v1/circles/"+circleID+"/notify", bTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK {
		t.Fatalf("notify: %d %v", code, body)
	}
	if paths := push.calledPaths(); len(paths) != 1 || paths[0] != "/alice" {
		t.Fatalf("bob's notify reached %v, want /alice — muting is one-directional", paths)
	}
}

// PUT replaces the whole set (it is not a merge), GET returns the caller's own
// mutes, and repeating a PUT is idempotent.
func TestMutes_PutReplacesAndGetReturnsOwn(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	dTok, _ := register(c, "dad@ex.com", "web")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	joinCircle(c, circleID, aTok, dTok)
	aliceID, dadID := userIDOf(c, aTok), userIDOf(c, dTok)

	get := func(tok string) map[string]any {
		t.Helper()
		code, body := c.do(http.MethodGet, "/v1/circles/"+circleID+"/mutes", tok, nil)
		if code != http.StatusOK {
			t.Fatalf("get mutes: %d %v", code, body)
		}
		return body
	}

	// Empty to start, and muted_user_ids is [] rather than null.
	got := get(bTok)
	if got["circle_muted"].(bool) || len(mutedIDs(t, got)) != 0 {
		t.Fatalf("initial mutes = %v, want circle_muted=false and []", got)
	}

	// Mute Alice and Dad.
	want := []string{aliceID, dadID}
	sort.Strings(want)
	put := setMutes(c, circleID, bTok, false, []string{aliceID, dadID})
	if ids := mutedIDs(t, put); len(ids) != 2 || ids[0] != want[0] || ids[1] != want[1] {
		t.Fatalf("put echoed %v, want %v", ids, want)
	}
	if ids := mutedIDs(t, get(bTok)); len(ids) != 2 || ids[0] != want[0] || ids[1] != want[1] {
		t.Fatalf("get after put = %v, want %v", ids, want)
	}

	// Idempotent: the same PUT again yields the same state, not duplicates.
	setMutes(c, circleID, bTok, false, []string{aliceID, dadID})
	if ids := mutedIDs(t, get(bTok)); len(ids) != 2 {
		t.Fatalf("repeated put = %v, want the same 2 mutes", ids)
	}

	// REPLACE, not merge: PUT {alice} alone must drop Dad.
	setMutes(c, circleID, bTok, false, []string{aliceID})
	ids := mutedIDs(t, get(bTok))
	if len(ids) != 1 || ids[0] != aliceID {
		t.Fatalf("after replacing set = %v, want only alice — PUT replaces", ids)
	}

	// circle_muted and per-member mutes coexist, and both round-trip.
	setMutes(c, circleID, bTok, true, []string{aliceID})
	got = get(bTok)
	if !got["circle_muted"].(bool) || len(mutedIDs(t, got)) != 1 {
		t.Fatalf("mixed set = %v, want circle_muted=true and [alice]", got)
	}

	// Clearing everything works.
	setMutes(c, circleID, bTok, false, nil)
	got = get(bTok)
	if got["circle_muted"].(bool) || len(mutedIDs(t, got)) != 0 {
		t.Fatalf("cleared mutes = %v, want circle_muted=false and []", got)
	}

	// GET is the CALLER's own view: Bob's mutes are invisible to Alice, and
	// Alice's own set is untouched by Bob's writes.
	setMutes(c, circleID, bTok, true, []string{aliceID})
	got = get(aTok)
	if got["circle_muted"].(bool) || len(mutedIDs(t, got)) != 0 {
		t.Fatalf("alice's mutes = %v, want her own empty set, not bob's", got)
	}
}

// Validation: only circle members may be muted, self-mute is rejected, and
// non-members cannot touch the endpoint at all.
func TestMutes_Validation(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	sTok, _ := register(c, "stranger@ex.com", "web")
	circleID := circleWithTwoMembers(c, aTok, bTok)
	mutesPath := "/v1/circles/" + circleID + "/mutes"

	// A user outside the circle cannot be muted (no existence oracle).
	code, _ := c.do(http.MethodPut, mutesPath, bTok, map[string]any{
		"circle_muted": false, "muted_user_ids": []string{userIDOf(c, sTok)},
	})
	if code != http.StatusBadRequest {
		t.Fatalf("muting a non-member: expected 400, got %d", code)
	}

	// Self-mute is rejected rather than silently dropped, so the PUT response
	// always equals what was stored.
	code, _ = c.do(http.MethodPut, mutesPath, bTok, map[string]any{
		"circle_muted": false, "muted_user_ids": []string{userIDOf(c, bTok)},
	})
	if code != http.StatusBadRequest {
		t.Fatalf("self-mute: expected 400, got %d", code)
	}

	// A garbage id is a 400, not a 500.
	code, _ = c.do(http.MethodPut, mutesPath, bTok, map[string]any{
		"circle_muted": false, "muted_user_ids": []string{"not-a-uuid"},
	})
	if code != http.StatusBadRequest {
		t.Fatalf("bad uuid: expected 400, got %d", code)
	}

	// Non-members get 404 on both verbs — the circle's existence is not leaked.
	if code, _ := c.do(http.MethodGet, mutesPath, sTok, nil); code != http.StatusNotFound {
		t.Fatalf("stranger get mutes: expected 404, got %d", code)
	}
	if code, _ := c.do(http.MethodPut, mutesPath, sTok, map[string]any{"circle_muted": true}); code != http.StatusNotFound {
		t.Fatalf("stranger put mutes: expected 404, got %d", code)
	}
	// And anonymous callers are unauthorized.
	if code, _ := c.do(http.MethodGet, mutesPath, "", nil); code != http.StatusUnauthorized {
		t.Fatalf("anonymous get mutes: expected 401, got %d", code)
	}
}

// Mutes are scoped to ONE circle: silencing Alice in the family circle must not
// silence her in the work circle. The (user, circle, muted_user) key carries
// that, and the fan-out filter is correlated on circle_id.
func TestMutes_AreScopedPerCircle(t *testing.T) {
	c := newPushServer(t)
	push := newStubPushService(t)

	aTok, _ := register(c, "alice@ex.com", "web")
	bTok, _ := register(c, "bob@ex.com", "android")
	family := circleWithTwoMembers(c, aTok, bTok)
	work := circleWithTwoMembers(c, aTok, bTok)
	subscribe(c, bTok, push.URL+"/bob")

	// Bob mutes the family circle entirely; work is untouched.
	setMutes(c, family, bTok, true, nil)

	// Bob's work mutes stay empty — a mute in one circle is invisible in another.
	_, workMutes := c.do(http.MethodGet, "/v1/circles/"+work+"/mutes", bTok, nil)
	if workMutes["circle_muted"].(bool) || len(mutedIDs(t, workMutes)) != 0 {
		t.Fatalf("work mutes = %v, want empty — muting family must not leak across circles", workMutes)
	}

	// Alice notifying the family circle reaches nobody.
	code, body := c.do(http.MethodPost, "/v1/circles/"+family+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK || int(body["sent"].(float64)) != 0 {
		t.Fatalf("family notify = %d %v, want sent=0", code, body)
	}
	if paths := push.calledPaths(); len(paths) != 0 {
		t.Fatalf("family notify reached %v, want nothing", paths)
	}

	// The same notification in the work circle still reaches Bob.
	code, body = c.do(http.MethodPost, "/v1/circles/"+work+"/notify", aTok, map[string]any{
		"payload_enc": b64("sealed-under-K_c"),
	})
	if code != http.StatusOK || int(body["sent"].(float64)) != 1 {
		t.Fatalf("work notify = %d %v, want sent=1", code, body)
	}
	if paths := push.calledPaths(); len(paths) != 1 || paths[0] != "/bob" {
		t.Fatalf("work notify reached %v, want /bob — only the family circle was muted", paths)
	}
}

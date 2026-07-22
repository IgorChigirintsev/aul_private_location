//go:build integration

// Cross-backend equivalence tests for the three privacy-critical constructs the
// SQLite port had to rewrite from Postgres-only SQL, per the Milestone 2 gate:
//
//  1. live-map latest-fix  — LatestPingsForCircle (DISTINCT ON -> ROW_NUMBER):
//     the newest ping per device. A drift here is a location leak (a stale or
//     wrong fix shown on the map).
//  2. mute-set validation  — CountMembersIn (= ANY(uuid[]) -> IN (?,…)): how
//     many of a set are members. A drift lets a non-member be muted, or a
//     member's mute be silently dropped.
//  3. mute dedup + cascade — InsertMute (NULLS NOT DISTINCT -> two partial
//     unique indexes) and ON DELETE CASCADE: whole-circle vs member mute dedup,
//     and a deleted account's mutes vanishing (also proves PRAGMA
//     foreign_keys=ON holds on a pooled SQLite connection).
//
// Each test runs the identical scenario against EVERY available backend (SQLite
// always; Postgres too when TEST_DATABASE_URL is set) and asserts (a) the
// per-backend result is correct and (b) all backends agree byte-for-byte.
package store_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/store"
)

const equivTruncateSQL = `TRUNCATE
	users, devices, sessions, circles, circle_members, invites,
	pings, places_enc, key_envelopes, sos_events, push_subscriptions,
	app_versions, audit_log, login_attempts,
	share_sessions, share_positions
	RESTART IDENTITY CASCADE`

type namedBackend struct {
	name string
	st   *store.Store
}

// availableBackends returns a fresh, empty store for every backend that can be
// reached: SQLite always (a new temp file), Postgres when TEST_DATABASE_URL is
// set (migrated + truncated).
func availableBackends(t *testing.T) []namedBackend {
	t.Helper()
	ctx := context.Background()
	var out []namedBackend

	// SQLite: fresh temp file.
	path := filepath.Join(t.TempDir(), "equiv.db")
	ss, err := store.OpenSQLite(ctx, path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := ss.MigrateSQLite(ctx); err != nil {
		ss.Close()
		t.Fatalf("migrate sqlite: %v", err)
	}
	t.Cleanup(ss.Close)
	out = append(out, namedBackend{"sqlite", ss})

	// Postgres: only when a throwaway test DB is configured.
	if url := os.Getenv("TEST_DATABASE_URL"); url != "" {
		if err := store.Migrate(ctx, url); err != nil {
			t.Fatalf("migrate postgres: %v", err)
		}
		ps, err := store.Open(ctx, url)
		if err != nil {
			t.Fatalf("open postgres: %v", err)
		}
		if _, err := ps.Pool().Exec(ctx, equivTruncateSQL); err != nil {
			ps.Close()
			t.Fatalf("truncate postgres: %v", err)
		}
		t.Cleanup(ps.Close)
		out = append(out, namedBackend{"postgres", ps})
	}
	return out
}

// assertAllAgree fails if any two backends produced different results.
func assertAllAgree[T comparable](t *testing.T, got map[string][]T) {
	t.Helper()
	var refName string
	var ref []T
	for name, v := range got {
		if refName == "" {
			refName, ref = name, v
			continue
		}
		if !equalSlices(ref, v) {
			t.Fatalf("backends disagree: %s=%v vs %s=%v", refName, ref, name, v)
		}
	}
}

func equalSlices[T comparable](a, b []T) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func mustUser(t *testing.T, st *store.Store, email string) store.User {
	t.Helper()
	u, err := st.CreateUser(context.Background(), store.CreateUserParams{Email: email, PassHash: "x"})
	if err != nil {
		t.Fatalf("create user %s: %v", email, err)
	}
	return u
}

func mustCircle(t *testing.T, st *store.Store, owner uuid.UUID) store.Circle {
	t.Helper()
	c, err := st.CreateCircle(context.Background(), store.CreateCircleParams{RetentionDays: 7, CreatedBy: owner})
	if err != nil {
		t.Fatalf("create circle: %v", err)
	}
	return c
}

// --- 1. live-map latest-fix -------------------------------------------------

// TestEquiv_LatestPingsForCircle: for each of two devices reporting three pings
// at distinct times, the read path must return exactly the newest ping — and
// both backends must return the same set.
func TestEquiv_LatestPingsForCircle(t *testing.T) {
	got := map[string][]string{}
	for _, b := range availableBackends(t) {
		got[b.name] = latestScenario(t, b.st)
	}
	// Newest per device is p2; two devices -> two markers.
	want := []string{"d0-p2", "d1-p2"}
	for name, res := range got {
		if !equalSlices(res, want) {
			t.Fatalf("%s: newest-per-device = %v, want %v", name, res, want)
		}
	}
	assertAllAgree(t, got)
}

func latestScenario(t *testing.T, st *store.Store) []string {
	t.Helper()
	ctx := context.Background()
	owner := mustUser(t, st, "owner@equiv")
	circle := mustCircle(t, st, owner.ID)

	base := time.Now().UTC().Add(-100 * time.Hour)
	for di := 0; di < 2; di++ {
		u := mustUser(t, st, fmt.Sprintf("dev%d@equiv", di))
		dev, err := st.CreateDevice(ctx, store.CreateDeviceParams{UserID: u.ID, Platform: "web"})
		if err != nil {
			t.Fatalf("device: %v", err)
		}
		// Distinct captured_at per ping so "newest" is unambiguous on both engines.
		for pi := 0; pi < 3; pi++ {
			marker := fmt.Sprintf("d%d-p%d", di, pi)
			at := base.Add(time.Duration(di*10+pi) * time.Minute)
			if _, err := st.InsertPing(ctx, store.InsertPingParams{
				CircleID: circle.ID, DeviceID: dev.ID, ClientID: marker,
				Nonce: make([]byte, 24), Ciphertext: []byte(marker), CapturedAt: at,
			}); err != nil {
				t.Fatalf("insert ping %s: %v", marker, err)
			}
		}
	}

	latest, err := st.LatestPingsForCircle(ctx, circle.ID)
	if err != nil {
		t.Fatalf("LatestPingsForCircle: %v", err)
	}
	markers := make([]string, 0, len(latest))
	for _, p := range latest {
		markers = append(markers, string(p.Ciphertext))
	}
	sort.Strings(markers)
	return markers
}

// --- 2. mute-set validation -------------------------------------------------

// TestEquiv_CountMembersIn: the count must reflect exactly how many of the given
// ids are members — members, non-members, mixes, and the empty set — identically
// on both backends.
func TestEquiv_CountMembersIn(t *testing.T) {
	got := map[string][]int64{}
	for _, b := range availableBackends(t) {
		got[b.name] = countMembersScenario(t, b.st)
	}
	want := []int64{2, 1, 0, 0} // {m1,m2,stranger}, {m1}, {stranger}, {}
	for name, res := range got {
		if !equalSlices(res, want) {
			t.Fatalf("%s: counts = %v, want %v", name, res, want)
		}
	}
	assertAllAgree(t, got)
}

func countMembersScenario(t *testing.T, st *store.Store) []int64 {
	t.Helper()
	ctx := context.Background()
	owner := mustUser(t, st, "cm-owner@equiv")
	circle := mustCircle(t, st, owner.ID)
	m1 := mustUser(t, st, "cm-m1@equiv")
	m2 := mustUser(t, st, "cm-m2@equiv")
	stranger := mustUser(t, st, "cm-stranger@equiv")
	for _, m := range []uuid.UUID{m1.ID, m2.ID} {
		if _, err := st.AddMember(ctx, store.AddMemberParams{CircleID: circle.ID, UserID: m, Role: "member"}); err != nil {
			t.Fatalf("add member: %v", err)
		}
	}

	count := func(ids ...uuid.UUID) int64 {
		n, err := st.CountMembersIn(ctx, store.CountMembersInParams{CircleID: circle.ID, UserIds: ids})
		if err != nil {
			t.Fatalf("CountMembersIn: %v", err)
		}
		return n
	}
	return []int64{
		count(m1.ID, m2.ID, stranger.ID),
		count(m1.ID),
		count(stranger.ID),
		count(), // empty set
	}
}

// --- 3. mute dedup + cascade ------------------------------------------------

// TestEquiv_MuteDedupAndCascade: re-muting the whole circle or the same member
// is idempotent (dedup), and deleting the muted account drops its member mute
// while leaving the whole-circle mute — the ON DELETE CASCADE privacy path,
// which on SQLite depends on PRAGMA foreign_keys=ON being live on the pooled
// connection. Both backends must produce the same mute set at each step.
func TestEquiv_MuteDedupAndCascade(t *testing.T) {
	got := map[string][]string{}
	for _, b := range availableBackends(t) {
		got[b.name] = muteScenario(t, b.st)
	}
	// After dedup: {whole-circle, member}. After deleting the member: {whole-circle}.
	want := []string{"after-dedup:circle+member", "after-delete:circle-only"}
	for name, res := range got {
		if !equalSlices(res, want) {
			t.Fatalf("%s: mute lifecycle = %v, want %v", name, res, want)
		}
	}
	assertAllAgree(t, got)
}

func muteScenario(t *testing.T, st *store.Store) []string {
	t.Helper()
	ctx := context.Background()
	owner := mustUser(t, st, "mute-owner@equiv")
	member := mustUser(t, st, "mute-member@equiv")
	circle := mustCircle(t, st, owner.ID)
	if _, err := st.AddMember(ctx, store.AddMemberParams{CircleID: circle.ID, UserID: member.ID, Role: "member"}); err != nil {
		t.Fatalf("add member: %v", err)
	}

	mute := func(target *uuid.UUID) {
		if err := st.InsertMute(ctx, store.InsertMuteParams{
			UserID: owner.ID, CircleID: circle.ID, MutedUserID: target,
		}); err != nil {
			t.Fatalf("insert mute: %v", err)
		}
	}
	// Dedup: each of these is issued twice; the partial unique indexes make the
	// second a no-op (bare ON CONFLICT DO NOTHING).
	mute(nil)        // whole circle
	mute(nil)        // duplicate whole circle -> ignored
	mute(&member.ID) // one member
	mute(&member.ID) // duplicate member -> ignored

	afterDedup := classifyMutes(t, st, owner.ID, circle.ID)

	// Delete the muted account. The muted_user_id FK is ON DELETE CASCADE, so the
	// member mute must vanish; the whole-circle mute (owner-scoped) survives.
	deleteUser(t, st, member.ID)

	afterDelete := classifyMutes(t, st, owner.ID, circle.ID)
	return []string{"after-dedup:" + afterDedup, "after-delete:" + afterDelete}
}

// classifyMutes summarizes a user's mutes in a circle as a stable string:
// "circle+member", "circle-only", "member-only", or "none".
func classifyMutes(t *testing.T, st *store.Store, userID, circleID uuid.UUID) string {
	t.Helper()
	mutes, err := st.ListMutes(context.Background(), store.ListMutesParams{UserID: userID, CircleID: circleID})
	if err != nil {
		t.Fatalf("ListMutes: %v", err)
	}
	var whole, member int
	for _, m := range mutes {
		if m == nil {
			whole++
		} else {
			member++
		}
	}
	switch {
	case whole == 1 && member == 1:
		return "circle+member"
	case whole == 1 && member == 0:
		return "circle-only"
	case whole == 0 && member == 1:
		return "member-only"
	case whole == 0 && member == 0:
		return "none"
	default:
		return fmt.Sprintf("unexpected(whole=%d,member=%d)", whole, member)
	}
}

// deleteUser removes a user row directly, exercising the FK cascade. On SQLite
// this only cascades when PRAGMA foreign_keys=ON is live on the connection.
func deleteUser(t *testing.T, st *store.Store, id uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	if st.IsSQLite() {
		if _, err := st.SQLDB().ExecContext(ctx, `DELETE FROM users WHERE id = ?`, id.String()); err != nil {
			t.Fatalf("delete user (sqlite): %v", err)
		}
		return
	}
	if _, err := st.Pool().Exec(ctx, `DELETE FROM users WHERE id = $1`, id); err != nil {
		t.Fatalf("delete user (postgres): %v", err)
	}
}

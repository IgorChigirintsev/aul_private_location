//go:build integration

package retention

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/store"
	"github.com/aul-app/aul/server/internal/testutil"
)

func seedCircle(t *testing.T, st *store.Store, retentionDays int32) (circleID, deviceID [16]byte) {
	t.Helper()
	ctx := context.Background()
	user, err := st.CreateUser(ctx, store.CreateUserParams{Email: "ret@ex.com", PassHash: "x"})
	if err != nil {
		t.Fatalf("user: %v", err)
	}
	dev, err := st.CreateDevice(ctx, store.CreateDeviceParams{UserID: user.ID, Platform: "web"})
	if err != nil {
		t.Fatalf("device: %v", err)
	}
	circle, err := st.CreateCircle(ctx, store.CreateCircleParams{RetentionDays: retentionDays, CreatedBy: user.ID})
	if err != nil {
		t.Fatalf("circle: %v", err)
	}
	return circle.ID, dev.ID
}

func insertPing(t *testing.T, st *store.Store, circleID, deviceID [16]byte, clientID string, capturedAt time.Time) {
	t.Helper()
	_, err := st.InsertPing(context.Background(), store.InsertPingParams{
		CircleID: circleID, DeviceID: deviceID, ClientID: clientID,
		Nonce: make([]byte, 24), Ciphertext: []byte("ct"), CapturedAt: capturedAt,
	})
	if err != nil && !store.IsNotFound(err) {
		t.Fatalf("insert ping: %v", err)
	}
}

// newDevice adds another device (each needs its own user) to mix into a circle.
func newDevice(t *testing.T, st *store.Store, email string) [16]byte {
	t.Helper()
	ctx := context.Background()
	user, err := st.CreateUser(ctx, store.CreateUserParams{Email: email, PassHash: "x"})
	if err != nil {
		t.Fatalf("user %s: %v", email, err)
	}
	dev, err := st.CreateDevice(ctx, store.CreateDeviceParams{UserID: user.ID, Platform: "web"})
	if err != nil {
		t.Fatalf("device %s: %v", email, err)
	}
	return dev.ID
}

// newCircle adds another circle owned by a fresh user.
func newCircle(t *testing.T, st *store.Store, email string, retentionDays int32) [16]byte {
	t.Helper()
	ctx := context.Background()
	user, err := st.CreateUser(ctx, store.CreateUserParams{Email: email, PassHash: "x"})
	if err != nil {
		t.Fatalf("user %s: %v", email, err)
	}
	circle, err := st.CreateCircle(ctx, store.CreateCircleParams{RetentionDays: retentionDays, CreatedBy: user.ID})
	if err != nil {
		t.Fatalf("circle %s: %v", email, err)
	}
	return circle.ID
}

// widenPartitions makes room for deliberately old test pings.
func widenPartitions(t *testing.T, st *store.Store) {
	t.Helper()
	if err := st.EnsurePingPartitions(context.Background(), store.EnsurePingPartitionsParams{
		FromTs: time.Now().AddDate(0, -6, 0), ToTs: time.Now(),
	}); err != nil {
		t.Fatalf("ensure partitions: %v", err)
	}
}

// sqliteTSLayout mirrors internal/store's canonical fixed-width timestamp form,
// for raw test inserts on the SQLite backend.
const sqliteTSLayout = "2006-01-02T15:04:05.000Z07:00"

func countDevicePings(t *testing.T, st *store.Store, circleID, deviceID [16]byte) int {
	t.Helper()
	ctx := context.Background()
	var n int
	if st.IsSQLite() {
		if err := st.SQLDB().QueryRowContext(ctx,
			`SELECT count(*) FROM pings WHERE circle_id = ? AND device_id = ?`,
			uuid.UUID(circleID).String(), uuid.UUID(deviceID).String()).Scan(&n); err != nil {
			t.Fatalf("count device pings: %v", err)
		}
		return n
	}
	if err := st.Pool().QueryRow(ctx,
		`SELECT count(*) FROM pings WHERE circle_id = $1 AND device_id = $2`,
		uuid.UUID(circleID), uuid.UUID(deviceID)).Scan(&n); err != nil {
		t.Fatalf("count device pings: %v", err)
	}
	return n
}

// newestClientID returns the client_id of the newest surviving ping for a device,
// or "" when the device has none left.
func newestClientID(t *testing.T, st *store.Store, circleID, deviceID [16]byte) string {
	t.Helper()
	ctx := context.Background()
	var id string
	if st.IsSQLite() {
		err := st.SQLDB().QueryRowContext(ctx,
			`SELECT client_id FROM pings WHERE circle_id = ? AND device_id = ?
			 ORDER BY captured_at DESC LIMIT 1`,
			uuid.UUID(circleID).String(), uuid.UUID(deviceID).String()).Scan(&id)
		if err != nil {
			return ""
		}
		return id
	}
	err := st.Pool().QueryRow(ctx,
		`SELECT client_id FROM pings WHERE circle_id = $1 AND device_id = $2
		 ORDER BY captured_at DESC LIMIT 1`,
		uuid.UUID(circleID), uuid.UUID(deviceID)).Scan(&id)
	if err != nil {
		return ""
	}
	return id
}

// scalarCount runs an argument-free count query on whichever backend backs st.
func scalarCount(t *testing.T, st *store.Store, query string) int {
	t.Helper()
	ctx := context.Background()
	var n int
	if st.IsSQLite() {
		if err := st.SQLDB().QueryRowContext(ctx, query).Scan(&n); err != nil {
			t.Fatalf("scalar count: %v", err)
		}
		return n
	}
	if err := st.Pool().QueryRow(ctx, query).Scan(&n); err != nil {
		t.Fatalf("scalar count: %v", err)
	}
	return n
}

// countPingsByClient counts pings for a circle with a given client_id (backend-neutral).
func countPingsByClient(t *testing.T, st *store.Store, circleID [16]byte, clientID string) int {
	t.Helper()
	ctx := context.Background()
	var n int
	if st.IsSQLite() {
		if err := st.SQLDB().QueryRowContext(ctx,
			`SELECT count(*) FROM pings WHERE circle_id = ? AND client_id = ?`,
			uuid.UUID(circleID).String(), clientID).Scan(&n); err != nil {
			t.Fatalf("count pings by client: %v", err)
		}
		return n
	}
	if err := st.Pool().QueryRow(ctx,
		`SELECT count(*) FROM pings WHERE circle_id = $1 AND client_id = $2`,
		uuid.UUID(circleID), clientID).Scan(&n); err != nil {
		t.Fatalf("count pings by client: %v", err)
	}
	return n
}

// The load-bearing rule: a device that has been silent for days still has a pin
// on the map. Its one ancient ping is the newest it has, so it is exempt at any
// age — deleting it would silently blank that person off everyone's map.
func TestRetention_KeepsNewestPingPerDevice_HoweverOld(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	widenPartitions(t, st)

	circleID, deviceID := seedCircle(t, st, 7)
	insertPing(t, st, circleID, deviceID, "only-ping", time.Now().Add(-72*time.Hour))

	w := New(st, &config.Config{MaxRetentionDays: 3650, IPLogRetentionDays: 7, PingRetentionHours: 6})
	if _, err := st.PruneStalePings(ctx, int32(w.pingRetentionHours)); err != nil {
		t.Fatalf("PruneStalePings: %v", err)
	}

	if n := countDevicePings(t, st, circleID, deviceID); n != 1 {
		t.Fatalf("a device whose only ping is 3 days old kept %d pings, want 1 (it was blanked off the map)", n)
	}
}

// A busy device collapses to exactly one stored position: its newest.
func TestRetention_BusyDeviceKeepsExactlyItsNewest(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	widenPartitions(t, st)

	circleID, deviceID := seedCircle(t, st, 7)
	// 50 pings spread over a week, newest ~3.4h old — inside the 6h window, but
	// the rule must hold on the strength of "newest", not "recent".
	const total = 50
	newest := time.Now().Add(-7 * 24 * time.Hour)
	for i := 0; i < total; i++ {
		at := time.Now().Add(-7 * 24 * time.Hour).Add(time.Duration(i) * 200 * time.Minute)
		insertPing(t, st, circleID, deviceID, fmt.Sprintf("p%02d", i), at)
		if at.After(newest) {
			newest = at
		}
	}
	if n := countDevicePings(t, st, circleID, deviceID); n != total {
		t.Fatalf("setup: seeded %d pings, want %d", n, total)
	}

	// Through RunOnce, so the wiring and the per-circle rule are exercised too.
	w := New(st, &config.Config{MaxRetentionDays: 3650, IPLogRetentionDays: 7, PingRetentionHours: 6})
	if err := w.RunOnce(ctx); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if n := countDevicePings(t, st, circleID, deviceID); n != 1 {
		t.Fatalf("busy device kept %d pings, want exactly 1 (its newest)", n)
	}
	if got, want := newestClientID(t, st, circleID, deviceID), fmt.Sprintf("p%02d", total-1); got != want {
		t.Fatalf("survivor is %q, want %q (the newest ping must be the one kept)", got, want)
	}
}

// Pings inside the window are kept even when they are not the newest: that is
// the headroom dedup (uq_pings_dedup) and in-flight reads rely on.
func TestRetention_KeepsPingsInsideWindow(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	widenPartitions(t, st)

	circleID, deviceID := seedCircle(t, st, 7)
	insertPing(t, st, circleID, deviceID, "stale", time.Now().Add(-48*time.Hour))    // old, not newest -> goes
	insertPing(t, st, circleID, deviceID, "in-window", time.Now().Add(-2*time.Hour)) // recent, not newest -> stays
	insertPing(t, st, circleID, deviceID, "newest", time.Now().Add(-1*time.Minute))  // newest -> stays

	if _, err := st.PruneStalePings(ctx, 6); err != nil {
		t.Fatalf("PruneStalePings: %v", err)
	}

	if n := countDevicePings(t, st, circleID, deviceID); n != 2 {
		t.Fatalf("kept %d pings, want 2 (the in-window one and the newest)", n)
	}
	if stale := countPingsByClient(t, st, circleID, "stale"); stale != 0 {
		t.Fatal("a 48h-old, non-newest ping survived the 6h window")
	}
}

// The carve-out is per (circle_id, device_id): one device's newest must not
// shield another's stale pings, and circles must not shield each other.
func TestRetention_DevicesAndCirclesDoNotInterfere(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	widenPartitions(t, st)

	circleA, deviceA := seedCircle(t, st, 7)
	deviceB := newDevice(t, st, "ret-b@ex.com")
	circleB := newCircle(t, st, "ret-c@ex.com", 7)

	// Device A in circle A: chatty and current.
	insertPing(t, st, circleA, deviceA, "a-old", time.Now().Add(-30*time.Hour))
	insertPing(t, st, circleA, deviceA, "a-new", time.Now().Add(-1*time.Minute))
	// Device B in circle A: silent for days, one ancient ping.
	insertPing(t, st, circleA, deviceB, "b-ancient", time.Now().Add(-96*time.Hour))
	// Device A also reports into circle B: its newest there is old and must stay.
	insertPing(t, st, circleB, deviceA, "a-in-b-old", time.Now().Add(-50*time.Hour))
	insertPing(t, st, circleB, deviceA, "a-in-b-new", time.Now().Add(-40*time.Hour))

	if _, err := st.PruneStalePings(ctx, 6); err != nil {
		t.Fatalf("PruneStalePings: %v", err)
	}

	for _, tc := range []struct {
		name             string
		circle, device   [16]byte
		wantCount        int
		wantNewestClient string
	}{
		{"chatty device keeps only its newest", circleA, deviceA, 1, "a-new"},
		{"silent device keeps its ancient pin", circleA, deviceB, 1, "b-ancient"},
		{"same device in another circle keeps that circle's newest", circleB, deviceA, 1, "a-in-b-new"},
	} {
		if n := countDevicePings(t, st, tc.circle, tc.device); n != tc.wantCount {
			t.Errorf("%s: kept %d pings, want %d", tc.name, n, tc.wantCount)
		}
		if got := newestClientID(t, st, tc.circle, tc.device); got != tc.wantNewestClient {
			t.Errorf("%s: survivor is %q, want %q", tc.name, got, tc.wantNewestClient)
		}
	}
}

// A circle whose retention_days is shorter than the ping window still gets the
// tighter rule — but never at the cost of a device's last known pin.
func TestRetention_ShortCircleRetentionStillKeepsNewest(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	widenPartitions(t, st)

	// retention_days=1 with a 168h (7-day) ping window: the circle rule deletes more.
	circleID, deviceID := seedCircle(t, st, 1)
	insertPing(t, st, circleID, deviceID, "day-old", time.Now().Add(-30*time.Hour))
	insertPing(t, st, circleID, deviceID, "ancient-newest", time.Now().Add(-26*time.Hour))

	w := New(st, &config.Config{MaxRetentionDays: 3650, IPLogRetentionDays: 7, PingRetentionHours: 168})
	if err := w.RunOnce(ctx); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if n := countDevicePings(t, st, circleID, deviceID); n != 1 {
		t.Fatalf("kept %d pings, want 1: the circle's 1-day rule must delete the older ping but spare the newest", n)
	}
	if got := newestClientID(t, st, circleID, deviceID); got != "ancient-newest" {
		t.Fatalf("survivor is %q, want %q", got, "ancient-newest")
	}
}

func TestRetention_PerCircleDelete(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()
	cfg := &config.Config{MaxRetentionDays: 90, IPLogRetentionDays: 7}
	w := New(st, cfg)

	// Widen partitions to cover the old ping.
	if err := st.EnsurePingPartitions(ctx, store.EnsurePingPartitionsParams{
		FromTs: time.Now().AddDate(0, -6, 0), ToTs: time.Now(),
	}); err != nil {
		t.Fatalf("ensure partitions: %v", err)
	}

	circleID, deviceID := seedCircle(t, st, 7)
	insertPing(t, st, circleID, deviceID, "old", time.Now().Add(-30*24*time.Hour))
	insertPing(t, st, circleID, deviceID, "new", time.Now().Add(-1*time.Hour))

	if err := w.deleteExpiredPings(ctx); err != nil {
		t.Fatalf("deleteExpiredPings: %v", err)
	}
	n, err := st.CountPingsForCircle(ctx, circleID)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 ping to survive 7-day retention, got %d", n)
	}
}

func TestRetention_DropOldPartitions(t *testing.T) {
	st := testutil.Store(t)
	if st.IsSQLite() {
		t.Skip("partitioning is Postgres-only; the SQLite backstop is covered by TestRetention_SQLitePrunesPastMaxHorizon")
	}
	ctx := context.Background()
	cfg := &config.Config{MaxRetentionDays: 90, IPLogRetentionDays: 7}
	w := New(st, cfg)

	if err := st.EnsurePingPartitions(ctx, store.EnsurePingPartitionsParams{
		FromTs: time.Now().AddDate(0, -6, 0), ToTs: time.Now(),
	}); err != nil {
		t.Fatalf("ensure partitions: %v", err)
	}
	circleID, deviceID := seedCircle(t, st, 90)
	fiveMonthsAgo := time.Now().AddDate(0, -5, 0)
	insertPing(t, st, circleID, deviceID, "ancient", fiveMonthsAgo)

	before, _ := st.CountPingsForCircle(ctx, circleID)
	if before != 1 {
		t.Fatalf("setup: expected 1 ping, got %d", before)
	}

	// Drop partitions fully older than 90 days.
	dropped, err := w.dropOldPartitions(ctx, time.Now().AddDate(0, 0, -90))
	if err != nil {
		t.Fatalf("dropOldPartitions: %v", err)
	}
	if dropped == 0 {
		t.Fatal("expected at least one partition dropped")
	}
	after, _ := st.CountPingsForCircle(ctx, circleID)
	if after != 0 {
		t.Fatalf("expected ancient ping removed by partition drop, got %d", after)
	}
}

// Share sessions are cheap to mint and short-lived, so the table only stays
// bounded if dead ones are actually collected — and a collected session must
// take its sealed position with it, not orphan it.
func TestRetention_PruneShareSessions(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()

	user, err := st.CreateUser(ctx, store.CreateUserParams{Email: "share-ret@ex.com", PassHash: "x"})
	if err != nil {
		t.Fatalf("user: %v", err)
	}

	// seed builds a session with an explicit lifecycle and gives it a position.
	seed := func(expiresIn time.Duration, revokedAgo time.Duration) uuid.UUID {
		t.Helper()
		sess, err := st.CreateShareSession(ctx, store.CreateShareSessionParams{
			UserID: user.ID, ExpiresAt: time.Now().Add(expiresIn),
		})
		if err != nil {
			t.Fatalf("create share session: %v", err)
		}
		if revokedAgo != 0 {
			if st.IsSQLite() {
				revoked := time.Now().Add(-revokedAgo).UTC().Format(sqliteTSLayout)
				if _, err := st.SQLDB().ExecContext(ctx,
					`UPDATE share_sessions SET revoked_at = ? WHERE id = ?`, revoked, sess.ID.String()); err != nil {
					t.Fatalf("revoke: %v", err)
				}
			} else if _, err := st.Pool().Exec(ctx,
				`UPDATE share_sessions SET revoked_at = now() - $2::interval WHERE id = $1`,
				sess.ID, revokedAgo.String()); err != nil {
				t.Fatalf("revoke: %v", err)
			}
		}
		if err := st.UpsertSharePosition(ctx, store.UpsertSharePositionParams{
			SessionID: sess.ID, Nonce: make([]byte, 24), Ciphertext: []byte("sealed"), CapturedAt: time.Now(),
		}); err != nil {
			t.Fatalf("upsert position: %v", err)
		}
		return sess.ID
	}

	live := seed(30*time.Minute, 0)       // still running
	justExpired := seed(-1*time.Hour, 0)  // dead, but inside the grace window
	longExpired := seed(-48*time.Hour, 0) // dead and past grace
	revokedRecently := seed(30*time.Minute, time.Hour)
	revokedLongAgo := seed(30*time.Minute, 48*time.Hour)

	n, err := st.PruneShareSessions(ctx, shareGraceHours)
	if err != nil {
		t.Fatalf("PruneShareSessions: %v", err)
	}
	if n != 2 {
		t.Fatalf("pruned %d sessions, want 2 (the two past the %dh grace)", n, shareGraceHours)
	}

	exists := func(id uuid.UUID) bool {
		t.Helper()
		var count int
		if st.IsSQLite() {
			if err := st.SQLDB().QueryRowContext(ctx, `SELECT count(*) FROM share_sessions WHERE id = ?`, id.String()).Scan(&count); err != nil {
				t.Fatalf("count session: %v", err)
			}
			return count > 0
		}
		if err := st.Pool().QueryRow(ctx, `SELECT count(*) FROM share_sessions WHERE id = $1`, id).Scan(&count); err != nil {
			t.Fatalf("count session: %v", err)
		}
		return count > 0
	}
	for _, tc := range []struct {
		name string
		id   uuid.UUID
		want bool
	}{
		{"live session survives", live, true},
		{"recently expired survives the grace window", justExpired, true},
		{"long-expired is collected", longExpired, false},
		{"recently revoked survives the grace window", revokedRecently, true},
		{"long-revoked is collected", revokedLongAgo, false},
	} {
		if got := exists(tc.id); got != tc.want {
			t.Errorf("%s: exists = %v, want %v", tc.name, got, tc.want)
		}
	}

	// The cascade must leave no sealed position behind its session.
	orphans := scalarCount(t, st, `
		SELECT count(*) FROM share_positions p
		LEFT JOIN share_sessions s ON s.id = p.session_id
		WHERE s.id IS NULL`)
	if orphans != 0 {
		t.Fatalf("%d sealed positions outlived their session", orphans)
	}
	if positions := scalarCount(t, st, `SELECT count(*) FROM share_positions`); positions != 3 {
		t.Fatalf("%d positions remain, want 3 (one per surviving session)", positions)
	}
}

func TestRetention_ScrubAuditIPsAndSessions(t *testing.T) {
	st := testutil.Store(t)
	ctx := context.Background()

	// Insert an old audit row with an IP directly.
	if st.IsSQLite() {
		old := time.Now().AddDate(0, 0, -30).UTC().Format(sqliteTSLayout)
		if _, err := st.SQLDB().ExecContext(ctx,
			`INSERT INTO audit_log (event, ip, ts) VALUES ('login', '5.5.5.5', ?)`, old); err != nil {
			t.Fatalf("insert audit: %v", err)
		}
	} else if _, err := st.Pool().Exec(ctx,
		`INSERT INTO audit_log (event, ip, ts) VALUES ('login', '5.5.5.5', now() - interval '30 days')`); err != nil {
		t.Fatalf("insert audit: %v", err)
	}
	if n, err := st.PruneAuditIPs(ctx, 7); err != nil || n != 1 {
		t.Fatalf("PruneAuditIPs: n=%d err=%v", n, err)
	}
	if remaining := scalarCount(t, st, `SELECT count(*) FROM audit_log WHERE ip IS NOT NULL`); remaining != 0 {
		t.Fatalf("expected old IP scrubbed, %d remain", remaining)
	}
}

// TestRetention_SQLitePrunesPastMaxHorizon covers the SQLite equivalent of the
// Postgres "drop whole months past MAX_RETENTION" partition backstop: on SQLite
// that bound is a DELETE-by-timestamp of everything older than the horizon,
// INCLUDING a device's newest ping (a partition DROP would have taken it too).
func TestRetention_SQLitePrunesPastMaxHorizon(t *testing.T) {
	st := testutil.Store(t)
	if !st.IsSQLite() {
		t.Skip("Postgres uses partition DROP for this bound; see TestRetention_DropOldPartitions")
	}
	ctx := context.Background()

	circleID, deviceID := seedCircle(t, st, 90)
	// One ancient ping (5 months old) and one recent — only the ancient one is
	// past a 90-day max horizon.
	insertPing(t, st, circleID, deviceID, "ancient", time.Now().AddDate(0, -5, 0))
	insertPing(t, st, circleID, deviceID, "recent", time.Now().Add(-time.Hour))

	w := New(st, &config.Config{MaxRetentionDays: 90, IPLogRetentionDays: 7, PingRetentionHours: 6})
	if err := w.RunOnce(ctx); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	// The ancient ping is gone despite being a device's ping; the recent survives.
	if n := countDevicePings(t, st, circleID, deviceID); n != 1 {
		t.Fatalf("kept %d pings, want 1 (ancient past the 90-day horizon must be pruned)", n)
	}
	if got := newestClientID(t, st, circleID, deviceID); got != "recent" {
		t.Fatalf("survivor is %q, want %q", got, "recent")
	}
}

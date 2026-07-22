package sqlitedb

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

// expectedTables enumerates every table the Postgres schema defines
// (server/db/migrations/00001..00008), which the parallel SQLite set must
// reproduce. member profile is a COLUMN on circle_members (00005), not a
// table, so there is no member_profiles table to list.
var expectedTables = []string{
	"users",
	"devices",
	"sessions",
	"circles",
	"circle_members",
	"invites",
	"places_enc",
	"key_envelopes",
	"sos_events",
	"push_subscriptions",
	"app_versions",
	"audit_log",
	"login_attempts",
	"pings",
	"share_sessions",
	"share_positions",
	"notification_mutes",
}

// newMigratedDB opens a fresh temp-file SQLite DB and runs the SQLite
// migrations through the package's own helper.
func newMigratedDB(t *testing.T) *sql.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "aul-test.db")
	db, err := OpenAndMigrate(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenAndMigrate: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func objectExists(t *testing.T, db *sql.DB, objType, name string) bool {
	t.Helper()
	var n int
	err := db.QueryRow(
		`SELECT count(*) FROM sqlite_master WHERE type = ? AND name = ?`,
		objType, name,
	).Scan(&n)
	if err != nil {
		t.Fatalf("query sqlite_master for %s %q: %v", objType, name, err)
	}
	return n == 1
}

// TestMigrations_MaterializeFullSchema is the Milestone 1 gate: it proves the
// complete Postgres schema can exist on a fresh SQLite database.
func TestMigrations_MaterializeFullSchema(t *testing.T) {
	db := newMigratedDB(t)

	// 1. Every table from the Postgres schema exists.
	for _, tbl := range expectedTables {
		if !objectExists(t, db, "table", tbl) {
			t.Errorf("expected table %q to exist after migration, it does not", tbl)
		}
	}

	// 2. The two partial unique indexes that reproduce the whole-circle-mute
	//    dedup (Postgres' NULLS NOT DISTINCT) exist.
	for _, idx := range []string{
		"uq_notification_mutes_member",
		"uq_notification_mutes_circle",
	} {
		if !objectExists(t, db, "index", idx) {
			t.Errorf("expected mute dedup index %q to exist, it does not", idx)
		}
	}
}

// TestForeignKeysPragmaOn asserts the FK-enforcement PRAGMA is ON for a
// connection drawn from the pool — without it the ON DELETE CASCADE mute
// cleanup silently stops working.
func TestForeignKeysPragmaOn(t *testing.T) {
	db := newMigratedDB(t)

	var fk int
	if err := db.QueryRow(`PRAGMA foreign_keys`).Scan(&fk); err != nil {
		t.Fatalf("read PRAGMA foreign_keys: %v", err)
	}
	if fk != 1 {
		t.Fatalf("PRAGMA foreign_keys = %d, want 1 (FK enforcement must be ON)", fk)
	}

	// Prove enforcement is actually live, not just reported on: a device that
	// references a non-existent user must be rejected.
	_, err := db.Exec(
		`INSERT INTO devices (id, user_id, platform) VALUES (?, ?, 'web')`,
		"11111111-1111-1111-1111-111111111111",
		"22222222-2222-2222-2222-222222222222", // no such user
	)
	if err == nil {
		t.Fatal("insert of a device with a dangling user_id succeeded; FK not enforced")
	}
}

// TestEmailCaseInsensitiveUniqueness asserts citext -> TEXT COLLATE NOCASE:
// 'A@x' and 'a@x' collide on the unique index.
func TestEmailCaseInsensitiveUniqueness(t *testing.T) {
	db := newMigratedDB(t)

	if _, err := db.Exec(
		`INSERT INTO users (id, email, pass_hash) VALUES (?, ?, ?)`,
		"aaaaaaaa-0000-0000-0000-000000000001", "A@x", "hash",
	); err != nil {
		t.Fatalf("insert first user: %v", err)
	}

	_, err := db.Exec(
		`INSERT INTO users (id, email, pass_hash) VALUES (?, ?, ?)`,
		"aaaaaaaa-0000-0000-0000-000000000002", "a@x", "hash",
	)
	if err == nil {
		t.Fatal("inserting 'a@x' after 'A@x' succeeded; email uniqueness is case-sensitive")
	}

	// And a case-insensitive lookup finds the row regardless of stored case.
	var got string
	if err := db.QueryRow(
		`SELECT id FROM users WHERE email = ?`, "a@x",
	).Scan(&got); err != nil {
		t.Fatalf("case-insensitive lookup of 'a@x' failed: %v", err)
	}
	if got != "aaaaaaaa-0000-0000-0000-000000000001" {
		t.Fatalf("case-insensitive lookup returned %q, want the 'A@x' row", got)
	}
}

// TestWholeCircleMuteDedup exercises the two partial unique indexes directly:
// a second whole-circle mute (muted_user_id NULL) for the same (user, circle)
// must be rejected, while distinct member mutes coexist. This is the
// privacy-correctness constraint (who is silenced), so it is checked at the
// data level, not just by index existence.
func TestWholeCircleMuteDedup(t *testing.T) {
	db := newMigratedDB(t)

	// Seed FK parents: a user (mute owner) and a circle.
	const uid = "cccccccc-0000-0000-0000-000000000001"
	const cid = "dddddddd-0000-0000-0000-000000000001"
	const other = "cccccccc-0000-0000-0000-000000000002"
	mustExec(t, db, `INSERT INTO users (id, email, pass_hash) VALUES (?, 'owner@x', 'h')`, uid)
	mustExec(t, db, `INSERT INTO users (id, email, pass_hash) VALUES (?, 'other@x', 'h')`, other)
	mustExec(t, db, `INSERT INTO circles (id, created_by) VALUES (?, ?)`, cid, uid)

	// First whole-circle mute: OK.
	mustExec(t, db,
		`INSERT INTO notification_mutes (user_id, circle_id, muted_user_id) VALUES (?, ?, NULL)`,
		uid, cid)
	// Second whole-circle mute for the same (user, circle): must be rejected.
	if _, err := db.Exec(
		`INSERT INTO notification_mutes (user_id, circle_id, muted_user_id) VALUES (?, ?, NULL)`,
		uid, cid,
	); err == nil {
		t.Fatal("a duplicate whole-circle mute was accepted; NULLS-NOT-DISTINCT dedup is broken")
	}

	// A member mute for the same (user, circle) is a DIFFERENT thing and coexists.
	mustExec(t, db,
		`INSERT INTO notification_mutes (user_id, circle_id, muted_user_id) VALUES (?, ?, ?)`,
		uid, cid, other)
	// But a duplicate member mute is rejected.
	if _, err := db.Exec(
		`INSERT INTO notification_mutes (user_id, circle_id, muted_user_id) VALUES (?, ?, ?)`,
		uid, cid, other,
	); err == nil {
		t.Fatal("a duplicate member mute was accepted; member-mute dedup is broken")
	}
}

func mustExec(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatalf("exec %q: %v", query, err)
	}
}

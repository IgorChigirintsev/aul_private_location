//go:build integration

// Package testutil provides shared helpers for integration tests. It is compiled
// only under the `integration` build tag.
//
// The store is backend-parameterised by AUL_TEST_BACKEND:
//
//   - unset / "postgres" (default): connect to TEST_DATABASE_URL, migrate, and
//     TRUNCATE all data — the existing cloud path, unchanged.
//   - "sqlite": create a FRESH temp-file SQLite database per Store(t) call and
//     migrate it. No truncation is needed (each call is a brand-new file), and
//     no external database is required, so the whole integration suite can run
//     against the embedded backend with `AUL_TEST_BACKEND=sqlite`.
package testutil

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aul-app/aul/server/internal/store"
)

// allTables is truncated between tests to isolate them (Postgres backend).
const truncateSQL = `TRUNCATE
	users, devices, sessions, circles, circle_members, invites,
	pings, places_enc, key_envelopes, sos_events, push_subscriptions,
	app_versions, audit_log, login_attempts,
	share_sessions, share_positions
	RESTART IDENTITY CASCADE`

// IsSQLite reports whether the test store runs on the embedded SQLite backend.
// Tests that assert Postgres-storage-specific facts through raw pgx SQL guard
// on this to skip on SQLite (their behavior is covered backend-neutrally
// elsewhere).
func IsSQLite() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("AUL_TEST_BACKEND")), "sqlite")
}

// Store returns a ready Store for the configured backend. The test is skipped
// when the selected backend cannot be reached.
func Store(t testing.TB) *store.Store {
	t.Helper()
	if IsSQLite() {
		return sqliteStore(t)
	}
	return postgresStore(t)
}

// sqliteStore builds a fresh temp-file SQLite store and migrates it. Each call
// gets its own file, so tests are isolated without truncation.
func sqliteStore(t testing.TB) *store.Store {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "aul-test.db")
	st, err := store.OpenSQLite(ctx, path)
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	if err := st.MigrateSQLite(ctx); err != nil {
		st.Close()
		t.Fatalf("migrate sqlite: %v", err)
	}
	t.Cleanup(st.Close)
	return st
}

// postgresStore connects to TEST_DATABASE_URL, applies migrations, TRUNCATES ALL
// DATA, and returns a ready Store. The test is skipped when no test database is
// configured.
//
// It deliberately does NOT fall back to DATABASE_URL: that is the variable a
// real server (your dev box, or worse) runs against, and these tests wipe every
// table. That silent fallback has already destroyed a developer's dev database —
// running the suite in a shell where DATABASE_URL happened to be exported was
// enough. Point TEST_DATABASE_URL at a throwaway instead; if you genuinely mean
// to wipe whatever DATABASE_URL names, say so with AUL_ALLOW_DESTRUCTIVE_TESTS=1.
func postgresStore(t testing.TB) *store.Store {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		if raw := os.Getenv("DATABASE_URL"); raw != "" {
			if os.Getenv("AUL_ALLOW_DESTRUCTIVE_TESTS") != "1" {
				t.Fatalf("integration tests refused to run: TEST_DATABASE_URL is unset, but DATABASE_URL is.\n" +
					"These tests TRUNCATE every table, and DATABASE_URL is what a real server uses.\n" +
					"Use a throwaway database:  TEST_DATABASE_URL=postgres://…/aul_test go test -p 1 -tags=integration ./...\n" +
					"Or, to wipe DATABASE_URL on purpose: AUL_ALLOW_DESTRUCTIVE_TESTS=1")
			}
			url = raw
		}
	}
	if url == "" {
		t.Skip("integration test: set TEST_DATABASE_URL to a throwaway database (or AUL_TEST_BACKEND=sqlite)")
	}
	ctx := context.Background()
	if err := store.Migrate(ctx, url); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	st, err := store.Open(ctx, url)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if _, err := st.Pool().Exec(ctx, truncateSQL); err != nil {
		st.Close()
		t.Fatalf("truncate: %v", err)
	}
	t.Cleanup(st.Close)
	return st
}

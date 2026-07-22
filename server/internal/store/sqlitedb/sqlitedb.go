// Package sqlitedb opens and migrates the embedded-SQLite backend for the
// single-binary self-host build (Milestone 1 of the store port).
//
// It is DELIBERATELY standalone: it is NOT wired into internal/store, which
// remains pgx-only. This package only proves the SQLite schema can be
// materialized (open a database/sql connection on a pure-Go driver, set the
// per-connection PRAGMAs the schema's foreign keys depend on, and run the
// parallel goose migration set). Making the generated queries execute on
// SQLite is Milestone 2.
//
// Driver: modernc.org/sqlite (pure Go, registered under the name "sqlite").
// It requires NO cgo, so the self-host binary still cross-compiles and links
// statically like the rest of the server.
package sqlitedb

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite" // pure-Go database/sql driver "sqlite" (no cgo)

	"github.com/aul-app/aul/server/db"
)

// migrationsDir is the directory inside db.MigrationsSQLiteFS that goose reads.
const migrationsDir = "migrations_sqlite"

// pragmaDSN returns the connection PRAGMAs appended to the SQLite DSN so they
// apply to EVERY connection database/sql opens in the pool. modernc executes
// each `_pragma` value as a `PRAGMA` on connect, so nothing is left to a
// forgotten setup step:
//
//   - foreign_keys=ON  — CRITICAL. SQLite enforces FK actions (the ON DELETE
//     CASCADE / SET NULL / RESTRICT that back mute cleanup, key-envelope
//     cascade, etc.) only when this is on, and it defaults OFF per connection.
//   - journal_mode=WAL — concurrent readers with a single writer; the mode is
//     persisted in the DB header, so re-issuing it per connection is a no-op.
//   - busy_timeout=5000 — wait up to 5s for a writer's lock instead of
//     failing immediately with SQLITE_BUSY.
const pragmaDSN = "_pragma=foreign_keys(1)" +
	"&_pragma=journal_mode(WAL)" +
	"&_pragma=busy_timeout(5000)"

// DSN builds a modernc.org/sqlite DSN for the given database file path with the
// required PRAGMAs attached. path is a filesystem path (modernc strips the
// query string from it when the DSN is not a file: URI).
func DSN(path string) string {
	return path + "?" + pragmaDSN
}

// Open opens (creating if absent) the SQLite database at path and verifies the
// connection. Every pooled connection carries the PRAGMAs from pragmaDSN,
// including foreign_keys=ON. The caller owns the returned *sql.DB and must
// Close it.
//
// This is the standalone helper; it does not build a *store.Store (Milestone 2).
func Open(ctx context.Context, path string) (*sql.DB, error) {
	sqlDB, err := sql.Open("sqlite", DSN(path))
	if err != nil {
		return nil, fmt.Errorf("sqlitedb: open %q: %w", path, err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := sqlDB.PingContext(pingCtx); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("sqlitedb: ping %q: %w", path, err)
	}
	return sqlDB, nil
}

// Migrate applies the embedded SQLite goose migrations up to head against an
// already-open connection. goose speaks database/sql, so the same *sql.DB the
// app uses is reused (unlike the Postgres path, which opens a second pgx
// connection just for goose).
func Migrate(ctx context.Context, sqlDB *sql.DB) error {
	goose.SetBaseFS(db.MigrationsSQLiteFS)
	if err := goose.SetDialect("sqlite3"); err != nil {
		return fmt.Errorf("sqlitedb: goose dialect: %w", err)
	}
	goose.SetLogger(goose.NopLogger())
	if err := goose.UpContext(ctx, sqlDB, migrationsDir); err != nil {
		return fmt.Errorf("sqlitedb: apply migrations: %w", err)
	}
	return nil
}

// OpenAndMigrate is the convenience path: Open then Migrate. On a migration
// failure it closes the connection so the caller is not handed a half-migrated
// handle.
func OpenAndMigrate(ctx context.Context, path string) (*sql.DB, error) {
	sqlDB, err := Open(ctx, path)
	if err != nil {
		return nil, err
	}
	if err := Migrate(ctx, sqlDB); err != nil {
		sqlDB.Close()
		return nil, err
	}
	return sqlDB, nil
}

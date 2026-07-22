// SQLite backend for the embedded single-binary build (Milestone 2).
//
// This file is the hand-written database/sql implementation of the Querier
// interface that the pgx-generated code also satisfies. It is DELIBERATELY
// hand-written rather than a second sqlc codegen: sqlc's SQLite engine infers
// Go types from the column's SQLite storage class (TEXT/INTEGER/BLOB) and cannot
// emit google/uuid.UUID or time.Time fields that round-trip under database/sql,
// so a second codegen would produce a divergent type universe (sqlitestore.User
// with custom scannable types) that could only satisfy the shared Querier
// interface through an equally-large adapter layer. Writing it by hand keeps a
// SINGLE set of param/model types (the store.* types every consumer already
// uses) and gives exact control over the two correctness-critical conversions:
// uuid<->TEXT and time.Time<->RFC3339Nano-with-'Z'.
//
// The Postgres path (store.go + the generated *.sql.go) is untouched; the cloud
// runs on Postgres and stays byte-for-behaviour identical.
package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/store/sqlitedb"
)

// sqliteDBTX is the subset of *sql.DB / *sql.Tx the hand-written queries use, so
// the same query methods run against the pooled DB and against a transaction.
type sqliteDBTX interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// sqliteQueries implements Querier against a database/sql SQLite connection.
type sqliteQueries struct {
	db sqliteDBTX
}

func newSQLiteQueries(db sqliteDBTX) *sqliteQueries { return &sqliteQueries{db: db} }

// Compile-time proof the hand-written SQLite store implements the same interface
// as the generated pgx store. If a query is added to the Postgres set and the
// interface, this line stops compiling until the SQLite mirror is written too.
var _ Querier = (*sqliteQueries)(nil)

// --- time representation -------------------------------------------------
//
// The SQLite schema stores every timestamp as TEXT in a FIXED-WIDTH form:
// RFC3339 with exactly 3 fractional digits and a literal 'Z', e.g.
// 2026-07-20T12:34:56.789Z (see migrations_sqlite/00001_schema.sql, which uses
// strftime('%Y-%m-%dT%H:%M:%fZ','now') for DEFAULTs).
//
// Fixed width is load-bearing: SQLite compares TEXT lexicographically, and the
// time-window predicates (expires_at > now, captured_at < cutoff, ...) rely on
// lexicographic order equalling chronological order. That holds ONLY when every
// stored timestamp has the same fractional precision — a Go time formatted with
// time.RFC3339Nano (which trims trailing zeros) would sort WRONG against a
// strftime '.500Z'. So all Go-written times and all Go-computed cutoffs go
// through fmtTime, matching the schema's 3-digit millisecond form exactly.
const sqliteTimeLayout = "2006-01-02T15:04:05.000Z07:00"

// fmtTime renders t as the canonical fixed-width UTC string bound to SQLite.
func fmtTime(t time.Time) string { return t.UTC().Format(sqliteTimeLayout) }

// parseTime parses a stored timestamp back into UTC time.Time. RFC3339 parsing
// accepts the fractional seconds even though the reference layout omits them.
func parseTime(s string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, err
	}
	return t.UTC(), nil
}

// sqliteEpoch is the min-time sentinel replacing Postgres' 'epoch'::timestamptz
// in CountRecentFailuresByEmail's COALESCE. Any timestamp at or before the first
// real row works; it is only the "no successful login yet" lower bound.
const sqliteEpoch = "0001-01-01T00:00:00.000Z"

// --- bind helpers (Go value -> driver.Value) -----------------------------

// uv binds a non-null uuid as its canonical lowercase-hyphenated TEXT form.
func uv(u uuid.UUID) any { return u.String() }

// uvp binds a nullable uuid: NULL when nil, else the TEXT form.
func uvp(u *uuid.UUID) any {
	if u == nil {
		return nil
	}
	return u.String()
}

// tv binds a non-null time as the canonical fixed-width TEXT form.
func tv(t time.Time) any { return fmtTime(t) }

// tvp binds a nullable time: NULL when nil, else the TEXT form.
func tvp(t *time.Time) any {
	if t == nil {
		return nil
	}
	return fmtTime(*t)
}

// bv binds a bool as 0/1 so it lands in an INTEGER-affinity column unambiguously.
func bv(b bool) any {
	if b {
		return int64(1)
	}
	return int64(0)
}

// --- scan helpers (driver.Value -> Go value) -----------------------------

// asString coerces a scanned TEXT value (string or []byte) to string.
func asString(src any) (string, bool) {
	switch v := src.(type) {
	case string:
		return v, true
	case []byte:
		return string(v), true
	default:
		return "", false
	}
}

type uuidScanner struct{ dst *uuid.UUID }

func (s uuidScanner) Scan(src any) error {
	str, ok := asString(src)
	if !ok {
		return fmt.Errorf("sqlite: cannot scan %T into uuid", src)
	}
	u, err := uuid.Parse(str)
	if err != nil {
		return fmt.Errorf("sqlite: parse uuid %q: %w", str, err)
	}
	*s.dst = u
	return nil
}

type nullUUIDScanner struct{ dst **uuid.UUID }

func (s nullUUIDScanner) Scan(src any) error {
	if src == nil {
		*s.dst = nil
		return nil
	}
	str, ok := asString(src)
	if !ok {
		return fmt.Errorf("sqlite: cannot scan %T into *uuid", src)
	}
	u, err := uuid.Parse(str)
	if err != nil {
		return fmt.Errorf("sqlite: parse uuid %q: %w", str, err)
	}
	*s.dst = &u
	return nil
}

type timeScanner struct{ dst *time.Time }

func (s timeScanner) Scan(src any) error {
	switch v := src.(type) {
	case time.Time:
		*s.dst = v.UTC()
		return nil
	case string:
		t, err := parseTime(v)
		if err != nil {
			return err
		}
		*s.dst = t
		return nil
	case []byte:
		t, err := parseTime(string(v))
		if err != nil {
			return err
		}
		*s.dst = t
		return nil
	default:
		return fmt.Errorf("sqlite: cannot scan %T into time.Time", src)
	}
}

type nullTimeScanner struct{ dst **time.Time }

func (s nullTimeScanner) Scan(src any) error {
	if src == nil {
		*s.dst = nil
		return nil
	}
	var t time.Time
	if err := (timeScanner{&t}).Scan(src); err != nil {
		return err
	}
	*s.dst = &t
	return nil
}

type boolScanner struct{ dst *bool }

func (s boolScanner) Scan(src any) error {
	switch v := src.(type) {
	case int64:
		*s.dst = v != 0
		return nil
	case bool:
		*s.dst = v
		return nil
	case nil:
		*s.dst = false
		return nil
	default:
		return fmt.Errorf("sqlite: cannot scan %T into bool", src)
	}
}

// Convenience constructors so Scan call sites read like the generated ones.
func suuid(dst *uuid.UUID) any   { return uuidScanner{dst} }
func snUUID(dst **uuid.UUID) any { return nullUUIDScanner{dst} }
func stime(dst *time.Time) any   { return timeScanner{dst} }
func snTime(dst **time.Time) any { return nullTimeScanner{dst} }
func sbool(dst *bool) any        { return boolScanner{dst} }

// rowsAffected is the shared tail for :execrows methods.
func rowsAffected(res sql.Result, err error) (int64, error) {
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// --- backend open / migrate ----------------------------------------------

// OpenSQLite opens (creating if absent) the SQLite database at path and returns
// a Store wired to the hand-written SQLite Querier. Every pooled connection
// carries PRAGMA foreign_keys=ON (see internal/store/sqlitedb), which the
// ON DELETE CASCADE mute/key-envelope cleanup depends on. The caller must Close.
func OpenSQLite(ctx context.Context, path string) (*Store, error) {
	sqlDB, err := sqlitedb.Open(ctx, path)
	if err != nil {
		return nil, err
	}
	return &Store{
		Querier: newSQLiteQueries(sqlDB),
		backend: BackendSQLite,
		sqldb:   sqlDB,
	}, nil
}

// MigrateSQLite applies the embedded SQLite goose migrations to head on the
// store's own connection (goose speaks database/sql, so no second handle).
func (s *Store) MigrateSQLite(ctx context.Context) error {
	return sqlitedb.Migrate(ctx, s.sqldb)
}

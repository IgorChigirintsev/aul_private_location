package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib" // database/sql driver "pgx", for goose migrations
	"github.com/pressly/goose/v3"

	"github.com/aul-app/aul/server/db"
)

// Backend selects which engine a Store is wired to. The cloud server runs on
// Postgres (the default); the SQLite backend is the single-binary self-host
// build. The two are kept behind the Querier interface so app code is unaware.
type Backend int

const (
	BackendPostgres Backend = iota
	BackendSQLite
)

// Store owns a database connection and exposes the generated typed queries. It
// embeds Querier — satisfied by the pgx-generated *Queries on Postgres and by
// the hand-written *sqliteQueries on SQLite — so callers use s.CreateUser(...)
// etc. directly regardless of backend. WithTx adds a transaction helper.
//
// Exactly one of pool / sqldb is non-nil, selected by backend.
type Store struct {
	Querier
	backend Backend
	pool    *pgxpool.Pool // BackendPostgres
	sqldb   *sql.DB       // BackendSQLite
}

// Open opens and pings a pgx pool against databaseURL and returns a Postgres
// Store. This is the cloud path and is unchanged from before the SQLite port.
func Open(ctx context.Context, databaseURL string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("store: parse database url: %w", err)
	}
	cfg.MaxConnLifetime = time.Hour
	cfg.MaxConnIdleTime = 30 * time.Minute
	if cfg.MaxConns < 4 {
		cfg.MaxConns = 10
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect pool: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: ping database: %w", err)
	}
	return &Store{Querier: New(pool), backend: BackendPostgres, pool: pool}, nil
}

// Backend reports which engine this Store is wired to.
func (s *Store) Backend() Backend { return s.backend }

// IsSQLite reports whether this Store runs on the embedded SQLite backend. Used
// by retention to pick DELETE-by-timestamp over partition maintenance, and by
// health/metrics to pick the right stats source.
func (s *Store) IsSQLite() bool { return s.backend == BackendSQLite }

// Pool exposes the underlying pgx pool for raw Postgres queries (partition
// maintenance that touches pg_catalog, which sqlc cannot model). It is nil on
// the SQLite backend — callers must guard with IsSQLite.
func (s *Store) Pool() *pgxpool.Pool { return s.pool }

// SQLDB exposes the underlying database/sql handle on the SQLite backend (nil on
// Postgres). Used by retention's SQLite backstop and by tests.
func (s *Store) SQLDB() *sql.DB { return s.sqldb }

// Close releases all pooled connections.
func (s *Store) Close() {
	switch s.backend {
	case BackendSQLite:
		if s.sqldb != nil {
			_ = s.sqldb.Close()
		}
	default:
		if s.pool != nil {
			s.pool.Close()
		}
	}
}

// Ping verifies the database is reachable (health check). Works on both backends.
func (s *Store) Ping(ctx context.Context) error {
	if s.backend == BackendSQLite {
		return s.sqldb.PingContext(ctx)
	}
	return s.pool.Ping(ctx)
}

// TotalConns reports the pool's current connection count for metrics. On SQLite
// it is the database/sql open-connection count.
func (s *Store) TotalConns() int32 {
	if s.backend == BackendSQLite {
		return int32(s.sqldb.Stats().OpenConnections) // #nosec G115 -- bounded by MaxOpenConns (single digits)
	}
	return s.pool.Stat().TotalConns()
}

// WithTx runs fn inside a transaction, committing on success and rolling back on
// error or panic. The Querier passed to fn is bound to the transaction. Both
// backends are supported behind the same interface.
func (s *Store) WithTx(ctx context.Context, fn func(Querier) error) (err error) {
	if s.backend == BackendSQLite {
		return s.withSQLiteTx(ctx, fn)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(ctx)
			panic(p)
		}
		if err != nil {
			_ = tx.Rollback(ctx)
		}
	}()
	if err = fn(New(tx)); err != nil {
		return err
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit tx: %w", err)
	}
	return nil
}

// withSQLiteTx is the SQLite arm of WithTx.
func (s *Store) withSQLiteTx(ctx context.Context, fn func(Querier) error) (err error) {
	tx, err := s.sqldb.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback()
			panic(p)
		}
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	if err = fn(newSQLiteQueries(tx)); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return fmt.Errorf("store: commit tx: %w", err)
	}
	return nil
}

// PruneAllPingsBefore deletes every ping captured strictly before cutoff,
// including the newest-per-device carve-out. It is the SQLite equivalent of the
// Postgres "drop whole months past MAX_RETENTION" partition backstop: a device
// silent past the max horizon leaves the map entirely. Called only on the
// SQLite backend (retention uses dropOldPartitions on Postgres).
func (s *Store) PruneAllPingsBefore(ctx context.Context, cutoff time.Time) (int64, error) {
	res, err := s.sqldb.ExecContext(ctx,
		`DELETE FROM pings WHERE captured_at < ?`, fmtTime(cutoff))
	return rowsAffected(res, err)
}

// IsNotFound reports whether err is a no-rows sentinel from either backend.
func IsNotFound(err error) bool {
	return errors.Is(err, pgx.ErrNoRows) || errors.Is(err, sql.ErrNoRows)
}

// Migrate applies all embedded Postgres goose migrations up to head. It opens a
// separate database/sql connection (goose speaks database/sql) via the pgx
// stdlib driver, then closes it; the app uses the pgx pool.
func Migrate(ctx context.Context, databaseURL string) error {
	sqlDB, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return fmt.Errorf("store: open sql for migrate: %w", err)
	}
	defer sqlDB.Close()

	goose.SetBaseFS(db.MigrationsFS)
	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("store: goose dialect: %w", err)
	}
	goose.SetLogger(goose.NopLogger())
	if err := goose.UpContext(ctx, sqlDB, "migrations"); err != nil {
		return fmt.Errorf("store: apply migrations: %w", err)
	}
	return nil
}

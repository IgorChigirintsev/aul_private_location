// Package db embeds the SQL migrations so the single server binary can apply
// them at startup without shipping the .sql files separately.
package db

import "embed"

// MigrationsFS holds the goose SQL migrations for the Postgres backend (the
// cloud server's store).
//
//go:embed migrations/*.sql
var MigrationsFS embed.FS

// MigrationsSQLiteFS holds the parallel goose SQL migrations for the embedded
// SQLite backend (the single-binary self-host build). It materializes the same
// end-state schema as MigrationsFS translated to SQLite dialect; see
// migrations_sqlite/00001_schema.sql for the type-representation and
// dialect-porting notes. The Postgres set stays the source of truth.
//
//go:embed migrations_sqlite/*.sql
var MigrationsSQLiteFS embed.FS

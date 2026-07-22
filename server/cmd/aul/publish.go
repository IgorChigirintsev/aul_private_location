package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/store"
)

// sha256HexRe matches a lowercase hex-encoded SHA-256 digest (32 bytes).
var sha256HexRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// runPublishVersion registers (or updates) an app release in the app_versions
// table. It deliberately avoids config.Load() — a release job must not need the
// server's runtime secrets (SESSION_HASH_PEPPER, etc.); it only needs a
// database connection. On success it prints the upserted row as indented JSON.
func runPublishVersion(args []string) error {
	params, err := parsePublishFlags(args)
	if err != nil {
		return err
	}

	databaseURL := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if databaseURL == "" {
		return fmt.Errorf("DATABASE_URL is required (postgres://… or sqlite:/path/aul.db)")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Backend-aware, like the server's openStore: a self-hosted SQLite install
	// publishes versions into its own file, not a Postgres it doesn't have.
	backend, err := config.DetectBackend(os.Getenv("AUL_DB_BACKEND"), databaseURL)
	if err != nil {
		return err
	}
	var st *store.Store
	if backend == config.BackendSQLite {
		st, err = store.OpenSQLite(ctx, config.SQLitePathOf(databaseURL))
	} else {
		st, err = store.Open(ctx, databaseURL)
	}
	if err != nil {
		return err
	}
	defer st.Close()

	row, err := st.UpsertAppVersion(ctx, params)
	if err != nil {
		return fmt.Errorf("upsert app version: %w", err)
	}

	out, err := json.MarshalIndent(row, "", "  ")
	if err != nil {
		return fmt.Errorf("encode result: %w", err)
	}
	fmt.Fprintln(os.Stdout, string(out))
	return nil
}

// parsePublishFlags parses and validates the publish-version flags into store
// parameters. It is pure: no environment, no database, no I/O beyond flag
// parsing, so it is fully unit-testable. Empty optional fields become nil
// *string values (SQL NULL) rather than empty strings.
func parsePublishFlags(args []string) (store.UpsertAppVersionParams, error) {
	fs := flag.NewFlagSet("publish-version", flag.ContinueOnError)
	var (
		platform     = fs.String("platform", "", "target platform: android or ios (required)")
		versionCode  = fs.Int("version-code", 0, "monotonic integer build number (required, >0)")
		versionName  = fs.String("version-name", "", "human-readable version, e.g. 1.4.2 (required)")
		apkURL       = fs.String("apk-url", "", "download URL for the APK (optional; requires --sha256)")
		sha256       = fs.String("sha256", "", "hex SHA-256 of the APK (optional; 64 lowercase hex chars)")
		changelog    = fs.String("changelog", "", "release notes (optional)")
		minSupported = fs.Int("min-supported", 0, "lowest still-supported version-code (>=0)")
	)
	if err := fs.Parse(args); err != nil {
		return store.UpsertAppVersionParams{}, err
	}

	switch *platform {
	case "android", "ios":
		// ok
	case "":
		return store.UpsertAppVersionParams{}, fmt.Errorf("--platform is required (android or ios)")
	default:
		return store.UpsertAppVersionParams{}, fmt.Errorf("--platform must be android or ios, got %q", *platform)
	}

	if *versionCode <= 0 {
		return store.UpsertAppVersionParams{}, fmt.Errorf("--version-code is required and must be > 0, got %d", *versionCode)
	}

	name := strings.TrimSpace(*versionName)
	if name == "" {
		return store.UpsertAppVersionParams{}, fmt.Errorf("--version-name is required")
	}

	if *minSupported < 0 {
		return store.UpsertAppVersionParams{}, fmt.Errorf("--min-supported must be >= 0, got %d", *minSupported)
	}

	sha := strings.ToLower(strings.TrimSpace(*sha256))
	if sha != "" && !sha256HexRe.MatchString(sha) {
		return store.UpsertAppVersionParams{}, fmt.Errorf("--sha256 must be 64 hex characters (a SHA-256 digest)")
	}

	url := strings.TrimSpace(*apkURL)
	// Never publish an APK clients cannot verify.
	if url != "" && sha == "" {
		return store.UpsertAppVersionParams{}, fmt.Errorf("--sha256 is required when --apk-url is set")
	}

	params := store.UpsertAppVersionParams{
		Platform:     *platform,
		VersionCode:  int32(*versionCode),
		VersionName:  name,
		ApkUrl:       optStr(url),
		Sha256:       optStr(sha),
		Changelog:    optStr(strings.TrimSpace(*changelog)),
		MinSupported: int32(*minSupported),
	}
	return params, nil
}

// optStr returns nil for an empty string, otherwise a pointer to it, so empty
// optional fields are stored as SQL NULL.
func optStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

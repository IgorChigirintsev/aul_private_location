// Command aul is the single Aul server binary: REST API + WebSocket realtime +
// embedded web app + APK downloads. Configuration is entirely via environment
// variables (see internal/config). It fails fast on invalid config.
package main

import (
	"context"
	"embed"
	"errors"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/fcm"
	"github.com/aul-app/aul/server/internal/httpapi"
	"github.com/aul-app/aul/server/internal/ratelimit"
	"github.com/aul-app/aul/server/internal/realtime"
	"github.com/aul-app/aul/server/internal/retention"
	"github.com/aul-app/aul/server/internal/store"
)

//go:embed all:webdist
var webdist embed.FS

// version is set at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	// Subcommands run instead of the server. `publish-version` lets a release
	// pipeline register a new app release into app_versions (see publish.go);
	// `vapid-keys` mints a Web Push keypair for the operator (see vapid.go).
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "publish-version":
			if err := runPublishVersion(os.Args[2:]); err != nil {
				slog.Error("publish-version failed", "err", err)
				os.Exit(1)
			}
			return
		case "vapid-keys":
			if err := runVAPIDKeys(os.Stdout); err != nil {
				slog.Error("vapid-keys failed", "err", err)
				os.Exit(1)
			}
			return
		}
	}

	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	setupLogging()

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	slog.Info("starting aul", "version", version, "env", cfg.Env, "addr", cfg.HTTPAddr,
		"e2ee", !cfg.TrustedServerMode, "push", cfg.PushEnabled(), "fcm", cfg.FCMEnabled())
	if cfg.TrustedServerMode {
		slog.Warn("TRUSTED_SERVER_MODE is ON — the server can see plaintext coordinates. E2EE is disabled for this deployment.")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Database. The backend is selected from config (Postgres for the cloud,
	// embedded SQLite for the single-binary self-host build).
	st, err := openStore(ctx, cfg)
	if err != nil {
		return err
	}
	defer st.Close()

	// Services.
	auditLog := audit.New(st.Querier, cfg.IPLogRetentionDays > 0)
	authSvc, err := auth.NewService(st, auditLog, cfg)
	if err != nil {
		return err
	}

	// FCM (Android push). Optional: nil client = channel disabled. Config has
	// already checked the file is readable and shaped like a service account;
	// this parses the private key for real, so a boot that gets past here can
	// actually mint an access token.
	//
	// ctx (not a request context) bounds the token source: it caches the access
	// token for the server's lifetime and refreshes it on expiry, so no send
	// ever mints one.
	var fcmClient *fcm.Client
	if cfg.FCMEnabled() {
		fcmClient, err = fcm.New(ctx, cfg.FCMCredentialsJSON)
		if err != nil {
			return err
		}
		slog.Info("fcm enabled", "project_id", fcmClient.ProjectID())
	}

	hub := realtime.NewHub()
	go hub.Run(ctx)

	// Rate limiters (in-process; see D-0008).
	authLimiter := ratelimit.NewPerMinute(cfg.AuthRatePerMin, 10*time.Minute)
	inviteLimiter := ratelimit.NewPerHour(cfg.InvitesRatePerHr, 2*time.Hour)
	pingLimiter := ratelimit.NewPerMinute(cfg.PingRatePerMin, 10*time.Minute)
	keyEnvLimiter := ratelimit.NewPerMinute(30, 10*time.Minute) // per user; key rotation is infrequent
	wsLimiter := ratelimit.NewPerMinute(30, 10*time.Minute)     // per IP; WebSocket upgrades
	notifyLimiter := ratelimit.NewPerMinute(60, 10*time.Minute) // per user; web push fan-out
	shareLimiter := ratelimit.NewPerHour(30, 2*time.Hour)       // per user; live-share link creation
	authLimiter.StartJanitor(ctx, 5*time.Minute)
	inviteLimiter.StartJanitor(ctx, 15*time.Minute)
	pingLimiter.StartJanitor(ctx, 5*time.Minute)
	keyEnvLimiter.StartJanitor(ctx, 5*time.Minute)
	wsLimiter.StartJanitor(ctx, 5*time.Minute)
	notifyLimiter.StartJanitor(ctx, 5*time.Minute)
	shareLimiter.StartJanitor(ctx, 15*time.Minute)

	// Static assets: embedded build, or a dev dir, plus optional APK dir.
	webFS, err := fs.Sub(webdist, "webdist")
	if err != nil {
		return err
	}
	static := httpapi.NewStaticHandler(httpapi.StaticConfig{
		WebFS:  webFS,
		DevDir: cfg.DevStaticDir,
		APKDir: strings.TrimSpace(os.Getenv("APK_DIR")),
	})

	srv := httpapi.NewServer(httpapi.Deps{
		Config: cfg, Store: st, Auth: authSvc, Hub: hub, Audit: auditLog, Static: static,
		FCM:         fcmClient,
		AuthLimiter: authLimiter, InviteLimiter: inviteLimiter, PingLimiter: pingLimiter,
		KeyEnvLimiter: keyEnvLimiter, WSLimiter: wsLimiter, NotifyLimiter: notifyLimiter,
		ShareLimiter: shareLimiter,
	})

	// Background maintenance.
	worker := retention.New(st, cfg)
	go worker.Run(ctx)

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           srv.Router(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      0, // 0: WebSocket streams; REST handlers use their own timeout
		IdleTimeout:       120 * time.Second,
		BaseContext:       func(l net.Listener) context.Context { return ctx },
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", cfg.HTTPAddr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case <-ctx.Done():
		slog.Info("shutdown signal received")
	case err := <-errCh:
		return err
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
		_ = httpServer.Close()
	}
	slog.Info("stopped")
	return nil
}

// openStore migrates (when enabled) and opens the store for the configured
// backend. Postgres runs goose over a throwaway pgx/stdlib connection before
// opening the pgx pool; SQLite opens its single connection first and migrates
// on it (goose speaks database/sql).
func openStore(ctx context.Context, cfg *config.Config) (*store.Store, error) {
	if cfg.DBBackend == config.BackendSQLite {
		st, err := store.OpenSQLite(ctx, cfg.SQLitePath())
		if err != nil {
			return nil, err
		}
		if cfg.RunMigrations {
			migCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
			defer cancel()
			if err := st.MigrateSQLite(migCtx); err != nil {
				st.Close()
				return nil, err
			}
			slog.Info("migrations applied", "backend", "sqlite")
		}
		return st, nil
	}

	if cfg.RunMigrations {
		migCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		if err := store.Migrate(migCtx, cfg.DatabaseURL); err != nil {
			cancel()
			return nil, err
		}
		cancel()
		slog.Info("migrations applied", "backend", "postgres")
	}
	return store.Open(ctx, cfg.DatabaseURL)
}

func setupLogging() {
	level := slog.LevelInfo
	switch strings.ToLower(os.Getenv("LOG_LEVEL")) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	slog.SetDefault(slog.New(h))
}

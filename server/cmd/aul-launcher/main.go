// Command aul-launcher is the headless self-host launcher for Aul. It composes
// the server's environment (data dir, session pepper, public origin, SQLite DSN),
// spawns the sibling `aul` server binary, waits for it to become ready, opens the
// dashboard, and supervises it until Ctrl-C. It is pure Go (CGO_ENABLED=0) and
// cross-OS; the tray/GUI shell is a later phase layered over this core.
//
// This main is deliberately thin: it parses flags, wires signal handling, and
// calls launcher.Run. All behavior lives in internal/launcher.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/aul-app/aul/server/internal/launcher"
)

// version is set at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	// Subcommand dispatch: `aul-launcher doctor` runs the guided reachability
	// preflight (is Tailscale installed / up / Funnel-serving this node) and
	// exits, printing the exact next step for whatever isn't ready. Everything
	// else is the default "compose env and run the server" path below.
	if len(os.Args) > 1 && os.Args[1] == "doctor" {
		runDoctor()
		return
	}

	var (
		dataDir      = flag.String("data-dir", "", "data/config directory (default: OS user config dir + /aul, or AUL_DATA_DIR)")
		origin       = flag.String("origin", "", "public origin, e.g. https://aul.example.com (default: detect Tailscale Funnel, else http://localhost:<port>)")
		port         = flag.Int("port", 8080, "HTTP port the server binds and the localhost fallback uses")
		serverBin    = flag.String("server-bin", "", "path to the aul server binary (default: sibling of this launcher, or AUL_SERVER_BIN)")
		noOpen       = flag.Bool("no-open", false, "do not open the dashboard in a browser (headless)")
		readyTimeout = flag.Duration("ready-timeout", 60*time.Second, "how long to wait for the server to become ready")
		showVersion  = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	setupLogging()

	// SIGINT/SIGTERM cancels ctx; launcher.Run turns that into a graceful child
	// stop and returns context.Canceled, which we treat as a clean exit.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	opts := launcher.Options{
		DataDir:      *dataDir,
		Origin:       *origin,
		ServerBin:    *serverBin,
		Port:         *port,
		NoOpen:       *noOpen,
		ReadyTimeout: *readyTimeout,
	}

	err := launcher.Run(ctx, opts)
	if err == nil || errors.Is(err, context.Canceled) {
		return // clean stop (Ctrl-C / SIGTERM, or a clean server exit)
	}
	slog.Error("fatal", "err", err)
	os.Exit(1)
}

// runDoctor prints the guided reachability preflight and exits non-zero when the
// box is not yet reachable (a public Funnel isn't serving it), so it is usable in
// a script/CI gate as well as by a human.
func runDoctor() {
	setupLogging()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	report := launcher.Diagnose(ctx)
	launcher.WriteReport(os.Stdout, report)
	if !report.Ready() {
		os.Exit(1)
	}
}

// setupLogging configures slog to write JSON to STDERR, honoring LOG_LEVEL. The
// launcher keeps STDERR for structured logs and STDOUT for the human status
// block, so the two never interleave (this mirrors cmd/aul's setupLogging, but
// on STDERR rather than STDOUT).
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
	h := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level})
	slog.SetDefault(slog.New(h))
}

// Package launcher composes the server's environment and supervises it as a
// single headless self-host process. It never touches server config beyond the
// env the server already understands: it resolves the data dir, provisions the
// session pepper, works out the public origin, then spawns the sibling `aul`
// server binary with those variables and keeps it alive until Ctrl-C.
//
// Everything here is pure Go (CGO_ENABLED=0) and cross-OS, so the self-host
// binary needs no native toolchain. A tray/GUI shell is a later phase layered
// over this core; nothing in this package requires a UI.
package launcher

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Options is the fully-explicit launcher input. Zero values are filled by
// withDefaults; the CLI in cmd/aul-launcher maps flags straight onto it.
type Options struct {
	DataDir      string        // data/config dir; "" → AUL_DATA_DIR → os.UserConfigDir()/aul
	Origin       string        // explicit public origin; "" → Funnel detect → localhost
	ServerBin    string        // server binary path; "" → AUL_SERVER_BIN → sibling of the launcher exe
	Port         int           // HTTP bind port (also the localhost fallback port)
	NoOpen       bool          // suppress opening the dashboard (tests / headless)
	ReadyTimeout time.Duration // how long to wait for /readyz before giving up
	Stdout       io.Writer     // status-block sink; nil → os.Stdout (test seam)

	// OnReady, when set, is called once with the reachable public origin the
	// moment the server passes /readyz. It is the hook a GUI/tray shell layers
	// over this headless core uses to show and open the address; nil in the CLI.
	OnReady func(origin string)
}

// Run provisions the data dir, composes the child environment, and supervises
// the server as one headless process until ctx is cancelled (SIGINT/SIGTERM) or
// the server exits cleanly. It is the single entry point; everything else in the
// package is unexported.
//
// The order matters: the single-instance lock is acquired BEFORE any file is
// written, so pepper and database generation are single-writer, and the child is
// spawned with a plain exec.Command (NOT CommandContext) so the supervisor — not
// ctx cancellation — owns the graceful Interrupt→grace→Kill shutdown.
func Run(ctx context.Context, opts Options) error {
	opts = withDefaults(opts)

	dataDir, err := resolveDataDir(opts)
	if err != nil {
		return err
	}

	// Lock first: the pepper/db provisioning below must be single-writer, and a
	// second launcher for the same data dir would otherwise race those writes.
	lock, err := acquireLock(filepath.Join(dataDir, "launcher.lock"))
	if err != nil {
		return err
	}
	defer lock.release()

	serverBin, err := resolveServerBin(opts)
	if err != nil {
		return err
	}

	pepper, err := provisionPepper(dataDir)
	if err != nil {
		return err
	}

	res, err := resolveOrigin(ctx, opts, detectFunnel)
	if err != nil {
		return err
	}

	// Pin the reachable hostname: issued invites bake this origin, so a later
	// Tailscale rename (which can silently append "-1") would strand every one of
	// them. Warn loudly on a change; record it on first use. (Critique #6.)
	warnIfOriginChanged(dataDir, res)

	dbPath := filepath.Join(dataDir, "aul.db")
	env := composeEnv(os.Environ(), res, pepper, dbPath)

	logPath := filepath.Join(dataDir, "server.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600) // #nosec G304 -- server.log inside our own data dir
	if err != nil {
		return fmt.Errorf("open server log %s: %w", logPath, err)
	}
	defer func() { _ = logFile.Close() }()
	// Both child streams write to one locked sink: exec copies stdout and stderr
	// in separate goroutines, so the mutex prevents interleaved lines in the file.
	sink := newLockedWriter(io.MultiWriter(logFile, os.Stderr))

	sup := &supervisor{
		newCmd: func() *exec.Cmd {
			// Plain exec.Command, NOT CommandContext: ctx cancellation must not
			// hard-kill the child. The supervisor drives the graceful stop itself.
			cmd := exec.Command(serverBin) //nolint:noctx // see above: cancellation must not hard-kill the child
			cmd.Env = env
			cmd.Stdout = sink
			cmd.Stderr = sink
			cmd.Dir = dataDir
			return cmd
		},
		minBackoff: 500 * time.Millisecond,
		maxBackoff: 30 * time.Second,
		stableRun:  60 * time.Second,
		stopGrace:  5 * time.Second,
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	supDone := make(chan error, 1)
	go func() { supDone <- sup.run(runCtx) }()

	if err := waitReady(runCtx, res.BindPort, opts.ReadyTimeout); err != nil {
		cancel()
		<-supDone
		return fmt.Errorf("%w — see %s for the failure", err, logPath)
	}

	printStatus(opts.Stdout, statusInfo{res: res, dataDir: dataDir, logPath: logPath})

	// Hand the reachable origin to a GUI/tray shell, if one is driving us.
	if opts.OnReady != nil {
		opts.OnReady(res.Origin)
	}

	if !opts.NoOpen {
		// Non-fatal: a headless box legitimately has no browser opener. Log the URL
		// the operator can click and keep serving.
		if err := openBrowser(res.Origin); err != nil {
			slog.Warn("could not open the dashboard automatically; open it yourself",
				"url", res.Origin, "err", err)
		}
	}

	// Blocks until the parent ctx is cancelled (SIGINT/SIGTERM) or the server
	// exits cleanly. The supervisor performs the graceful child stop; the deferred
	// lock.release and logFile.Close run on the way out.
	return <-supDone
}

// withDefaults fills the zero-valued Options: the default HTTP port, the ready
// timeout, and STDOUT for the status block.
func withDefaults(opts Options) Options {
	if opts.Port == 0 {
		opts.Port = 8080
	}
	if opts.ReadyTimeout == 0 {
		opts.ReadyTimeout = 60 * time.Second
	}
	if opts.Stdout == nil {
		opts.Stdout = os.Stdout
	}
	return opts
}

// detectFunnel adapts the exported FunnelOrigin probe into the funnelDetector
// signature resolveOrigin expects, so origin resolution stays unit-testable with
// a stub and needs no Tailscale.
func detectFunnel(ctx context.Context) (funnelResult, bool, string) {
	return FunnelOrigin(ctx)
}

// warnIfOriginChanged records the reachable Funnel origin in the data dir and
// warns when it differs from the previous run. Only the stable ts.net host is
// pinned — a localhost/flag origin isn't baked into shareable invites the same
// way — so a changed host (a Tailscale rename/collision that appends "-1"/"-2")
// is surfaced before it silently breaks every previously issued invite.
func warnIfOriginChanged(dataDir string, res resolved) {
	if res.Source != sourceFunnel {
		return
	}
	path := filepath.Join(dataDir, "origin.pinned")
	cur := res.Origin
	if prev, err := os.ReadFile(path); err == nil { // #nosec G304 -- origin.pinned inside our own data dir
		switch p := strings.TrimSpace(string(prev)); {
		case p == cur:
			return // unchanged — nothing to record or warn about
		case p != "":
			slog.Warn("reachable origin CHANGED since the last run — invites issued for the old origin will no longer reach this server",
				"was", p, "now", cur,
				"fix", "re-issue invites, and pin this machine's name in Tailscale so it can't change again")
		}
	}
	if err := os.WriteFile(path, []byte(cur+"\n"), 0o600); err != nil {
		slog.Debug("could not record the pinned origin", "path", path, "err", err)
	}
}

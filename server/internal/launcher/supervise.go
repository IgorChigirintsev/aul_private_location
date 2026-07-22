package launcher

import (
	"context"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"time"
)

// supervisor spawns the server child and keeps it alive: it restarts an
// unexpected exit with capped exponential backoff, but stops cleanly when its
// context is cancelled (our own shutdown) or the child exits 0.
type supervisor struct {
	newCmd     func() *exec.Cmd // a FRESH *exec.Cmd each attempt (exec.Cmd is single-use)
	minBackoff time.Duration
	maxBackoff time.Duration
	stableRun  time.Duration // a run at least this long resets backoff to min
	stopGrace  time.Duration // Interrupt→Kill deadline on graceful stop
}

// run supervises the child until ctx is cancelled or the child exits cleanly. It
// returns ctx.Err() on our own shutdown (which main maps to exit 0) or nil on a
// clean child exit; a persistent crash keeps restarting under backoff.
func (s *supervisor) run(ctx context.Context) error {
	backoff := s.minBackoff
	for {
		cmd := s.newCmd()
		start := time.Now()
		if err := cmd.Start(); err != nil {
			// Could not even start (e.g. the binary vanished). Back off and retry,
			// unless we are shutting down.
			slog.Error("could not start server", "err", err)
			if !sleepCtx(ctx, backoff) {
				return ctx.Err()
			}
			backoff = nextBackoff(backoff, s.maxBackoff)
			continue
		}
		slog.Info("server started", "pid", cmd.Process.Pid)

		waitErr := make(chan error, 1) // buffered: the waiter goroutine never blocks
		go func() { waitErr <- cmd.Wait() }()

		select {
		case <-ctx.Done():
			// Our own shutdown: stop the child gracefully and return.
			s.stop(cmd.Process, waitErr)
			return ctx.Err()

		case err := <-waitErr:
			// The child exited on its own. If ctx is already cancelled, a terminal
			// SIGINT reached the child directly — that is expected shutdown, NOT a
			// crash, so do not restart.
			if ctx.Err() != nil {
				return ctx.Err()
			}
			ran := time.Since(start)
			if err == nil {
				slog.Info("server exited cleanly; not restarting")
				return nil
			}
			slog.Warn("server exited unexpectedly; restarting", "err", err, "ran", ran.Round(time.Millisecond))
			if ran >= s.stableRun {
				backoff = s.minBackoff // it ran long enough to count as stable
			}
			if !sleepCtx(ctx, backoff) {
				return ctx.Err()
			}
			backoff = nextBackoff(backoff, s.maxBackoff)
		}
	}
}

// stop drives the graceful child shutdown: SIGINT (which the server's own
// signal.NotifyContext turns into a graceful HTTP shutdown), then a hard Kill if
// it overruns stopGrace. Windows has no Interrupt, so there we Kill outright. A
// single drain of waitErr reaps the process — this is now its only reader.
func (s *supervisor) stop(p *os.Process, waitErr <-chan error) {
	if runtime.GOOS == "windows" {
		_ = p.Kill()
		<-waitErr
		return
	}
	_ = p.Signal(os.Interrupt)
	timer := time.NewTimer(s.stopGrace)
	defer timer.Stop()
	select {
	case <-waitErr:
		// Exited within grace.
	case <-timer.C:
		_ = p.Kill()
		<-waitErr
	}
}

// nextBackoff doubles the backoff, capped at ceil.
func nextBackoff(cur, ceil time.Duration) time.Duration {
	next := cur * 2
	if next > ceil {
		return ceil
	}
	return next
}

// sleepCtx sleeps for d, returning false if ctx is cancelled first, so a caller
// can abort its retry loop during shutdown.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

// lockedWriter serializes writes to an underlying writer. It wraps the
// MultiWriter(server.log, os.Stderr) shared by the child's stdout and stderr:
// exec copies each stream in its own goroutine, so without this mutex their
// writes could interleave mid-line in the shared log file.
type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func newLockedWriter(w io.Writer) *lockedWriter { return &lockedWriter{w: w} }

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

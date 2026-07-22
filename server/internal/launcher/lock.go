package launcher

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// lock is a held single-instance guard. The pidfile stays OPEN for the whole run
// so the OS keeps it referenced, and release() closes and removes it.
type lock struct {
	f    *os.File
	path string
}

// acquireLock takes the single-instance lock for a data dir via a pidfile created
// with O_CREATE|O_EXCL — an atomic create-if-absent on every OS. If the file
// already exists it reads the holder PID and probes liveness: a live holder means
// "already running"; a dead or unparseable holder is a stale lock from a prior
// crash, which we reclaim. The bounded retry loop is race-safe: only one racer
// wins the next O_EXCL create, and the loser re-reads the now-live PID and bails.
//
// It is acquired BEFORE pepper/database provisioning so generation is
// single-writer. Accepted residual risk: PID reuse can make a stale lock look
// live (mostly a Windows concern); a start-time/nonce check would need x/sys.
func acquireLock(path string) (*lock, error) {
	const attempts = 3
	var lastErr error
	for i := 0; i < attempts; i++ {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			if _, werr := f.WriteString(strconv.Itoa(os.Getpid())); werr != nil {
				_ = f.Close()
				_ = os.Remove(path)
				return nil, fmt.Errorf("write lock file %s: %w", path, werr)
			}
			return &lock{f: f, path: path}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("create lock file %s: %w", path, err)
		}

		// Someone holds (or held) it. Alive → refuse; dead/garbage → reclaim.
		pid, perr := readPid(path)
		if perr == nil && processAlive(pid) {
			return nil, fmt.Errorf("another aul launcher is already running for this data dir (pid %d); "+
				"stop it first, or use a different --data-dir", pid)
		}
		// Stale: remove and retry. If a racer recreated it first, the next O_EXCL
		// create fails again and we re-read the now-live PID on the next pass.
		if rerr := os.Remove(path); rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
			return nil, fmt.Errorf("reclaim stale lock file %s: %w", path, rerr)
		}
		lastErr = errors.New("stale lock reclaimed, retrying")
	}
	return nil, fmt.Errorf("could not acquire lock %s after %d attempts: %w", path, attempts, lastErr)
}

// release closes and removes the pidfile, ending the single-instance guard. Safe
// to call once via defer; errors are non-fatal (the process is exiting anyway).
func (l *lock) release() {
	if l == nil || l.f == nil {
		return
	}
	_ = l.f.Close()
	_ = os.Remove(l.path)
}

// readPid parses the PID stored in a pidfile. A missing or garbage value returns
// an error, which the caller treats as a stale (reclaimable) lock.
func readPid(path string) (int, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return 0, fmt.Errorf("unparseable pid in %s: %w", path, err)
	}
	return pid, nil
}

// processAlive reports whether a PID names a live process, cross-OS and without
// cgo. On Windows a successful FindProcess already implies the process exists
// (OpenProcess fails on a gone PID). On Unix, FindProcess always succeeds, so we
// send signal 0: nil or EPERM means alive (EPERM = alive but owned by another
// user), anything else (ESRCH) means gone. syscall.Signal and syscall.EPERM are
// defined on all three OSes, so this is one file with a runtime.GOOS branch — no
// build tag needed.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	if err := p.Signal(syscall.Signal(0)); err != nil {
		return errors.Is(err, syscall.EPERM)
	}
	return true
}

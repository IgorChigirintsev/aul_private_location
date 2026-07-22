package launcher

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestAcquireLock_SecondFailsWhileHeld(t *testing.T) {
	path := filepath.Join(t.TempDir(), "launcher.lock")

	first, err := acquireLock(path)
	if err != nil {
		t.Fatalf("first acquireLock: %v", err)
	}

	_, err = acquireLock(path)
	if err == nil {
		t.Fatal("second acquireLock succeeded while the first is held")
	}
	if !strings.Contains(err.Error(), strconv.Itoa(os.Getpid())) {
		t.Fatalf("error should mention the holder pid %d: %v", os.Getpid(), err)
	}

	first.release()

	// After release, the lock is free again — a clean handoff.
	third, err := acquireLock(path)
	if err != nil {
		t.Fatalf("third acquireLock after release: %v", err)
	}
	third.release()
}

func TestAcquireLock_ReclaimsStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "launcher.lock")

	dead := deadPID(t)
	if err := os.WriteFile(path, []byte(strconv.Itoa(dead)), 0o600); err != nil {
		t.Fatalf("seed stale lock: %v", err)
	}

	l, err := acquireLock(path)
	if err != nil {
		t.Fatalf("acquireLock should reclaim a stale lock: %v", err)
	}
	defer l.release()

	// The reclaimed lock must now hold OUR pid.
	got, err := readPid(path)
	if err != nil {
		t.Fatalf("readPid: %v", err)
	}
	if got != os.Getpid() {
		t.Fatalf("reclaimed lock holds pid %d, want our pid %d", got, os.Getpid())
	}
}

func TestProcessAlive(t *testing.T) {
	if !processAlive(os.Getpid()) {
		t.Errorf("processAlive(self=%d) = false, want true", os.Getpid())
	}
	if processAlive(deadPID(t)) {
		t.Error("processAlive(dead) = true, want false")
	}
	if processAlive(-1) {
		t.Error("processAlive(-1) = true, want false")
	}
}

// deadPID starts a helper subprocess that exits immediately and returns its now-
// dead PID. We Wait for it, so the kernel has fully reaped it and the PID no
// longer names a live process — the standard os/exec helper-process pattern,
// portable across OSes.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=TestLauncherHelperExit")
	cmd.Env = append(os.Environ(), "LAUNCHER_HELPER_EXIT=1")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper: %v", err)
	}
	pid := cmd.Process.Pid
	if err := cmd.Wait(); err != nil {
		t.Fatalf("helper did not exit cleanly: %v", err)
	}
	return pid
}

// TestLauncherHelperExit is not a real test: when LAUNCHER_HELPER_EXIT is set it
// is the entry point of the helper subprocess deadPID spawns, and it exits 0
// immediately so its PID becomes a known-dead one.
func TestLauncherHelperExit(t *testing.T) {
	if os.Getenv("LAUNCHER_HELPER_EXIT") == "1" {
		os.Exit(0)
	}
}

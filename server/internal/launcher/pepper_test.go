package launcher

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestProvisionPepper_GeneratesOnceAndReuses(t *testing.T) {
	dir := t.TempDir()

	first, err := provisionPepper(dir)
	if err != nil {
		t.Fatalf("first provisionPepper: %v", err)
	}
	if len(first) < minPepperBytes {
		t.Fatalf("pepper too short: %d bytes", len(first))
	}
	decoded, err := base64.StdEncoding.DecodeString(first)
	if err != nil {
		t.Fatalf("pepper is not base64: %v", err)
	}
	if len(decoded) != 32 {
		t.Fatalf("pepper decodes to %d bytes, want 32", len(decoded))
	}

	path := filepath.Join(dir, "session_pepper")
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat pepper: %v", err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Fatalf("pepper mode = %o, want 600", perm)
		}
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read pepper: %v", err)
	}

	// A second provision must reuse the SAME value and never rewrite the file:
	// rotating the pepper would log every existing session out.
	second, err := provisionPepper(dir)
	if err != nil {
		t.Fatalf("second provisionPepper: %v", err)
	}
	if second != first {
		t.Fatalf("pepper rotated: first=%q second=%q", first, second)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("re-read pepper: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("pepper file rewritten: before=%q after=%q", before, after)
	}
}

func TestProvisionPepper_ReusesHandEditedValue(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session_pepper")
	const want = "a-sufficiently-long-hand-written-pepper"
	// Seed WITH a trailing newline: TrimSpace on read forgives it, but the file
	// must be left byte-for-byte as the operator wrote it.
	if err := os.WriteFile(path, []byte(want+"\n"), 0o600); err != nil {
		t.Fatalf("seed pepper: %v", err)
	}

	got, err := provisionPepper(dir)
	if err != nil {
		t.Fatalf("provisionPepper: %v", err)
	}
	if got != want {
		t.Fatalf("pepper = %q, want %q (trailing newline should be trimmed)", got, want)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read pepper: %v", err)
	}
	if string(after) != want+"\n" {
		t.Fatalf("pepper file rewritten: %q", after)
	}
}

func TestProvisionPepper_RejectsTooShort(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session_pepper")
	if err := os.WriteFile(path, []byte("short"), 0o600); err != nil {
		t.Fatalf("seed pepper: %v", err)
	}
	if _, err := provisionPepper(dir); err == nil {
		t.Fatal("expected an error for a too-short pepper, got nil")
	}
	// It must NOT overwrite the operator's file, even a bad one — deleting it is
	// an explicit, documented operator choice.
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read pepper: %v", err)
	}
	if string(after) != "short" {
		t.Fatalf("too-short pepper was overwritten: %q", after)
	}
}

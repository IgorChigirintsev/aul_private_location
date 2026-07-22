package launcher

import (
	"fmt"
	"os"
	"path/filepath"
)

// atomicWriteFile writes data to path atomically at the given perm: it writes to
// a temp file in the SAME directory (so os.Rename is an atomic same-filesystem
// replace, never a cross-device EXDEV), fsyncs it, renames over the target, then
// fsyncs the directory so the rename itself survives a crash. Used for the
// session pepper, where a torn write would corrupt an irreplaceable secret.
func atomicWriteFile(path string, data []byte, perm os.FileMode) (err error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".pepper-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp file in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	// Remove the temp on any error path; a no-op once the rename has consumed it.
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmpName)
		}
	}()

	// Pin the mode exactly, independent of umask (CreateTemp already makes it
	// 0600, but be explicit for a secret file).
	if err = tmp.Chmod(perm); err != nil {
		return fmt.Errorf("chmod temp file: %w", err)
	}
	if _, err = tmp.Write(data); err != nil {
		return fmt.Errorf("write temp file: %w", err)
	}
	if err = tmp.Sync(); err != nil { // flush the secret before the rename publishes it
		return fmt.Errorf("sync temp file: %w", err)
	}
	if err = tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err = os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename temp file into place: %w", err)
	}
	if err = syncDir(dir); err != nil {
		return fmt.Errorf("sync dir after rename: %w", err)
	}
	return nil
}

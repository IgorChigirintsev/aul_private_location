package launcher

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// resolveDataDir picks the data/config directory (flag > AUL_DATA_DIR >
// os.UserConfigDir()/aul) and creates it 0700. This is where the pepper, the
// SQLite database, the lock, and server.log live — all owner-only.
func resolveDataDir(opts Options) (string, error) {
	dir := firstNonEmpty(opts.DataDir, os.Getenv("AUL_DATA_DIR"))
	if dir == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", fmt.Errorf("cannot determine a data dir: %w (set --data-dir or AUL_DATA_DIR)", err)
		}
		dir = filepath.Join(base, "aul")
	}
	// #nosec G703 -- the operator names their own data dir (--data-dir/AUL_DATA_DIR); that choice is the feature, not untrusted input
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create data dir %s: %w", dir, err)
	}
	return dir, nil
}

// resolveServerBin locates the server binary (flag > AUL_SERVER_BIN > sibling of
// the launcher executable). The server stays a separate pure-Go no-cgo binary;
// the launcher only composes env and spawns it, so it must exist as a real file.
func resolveServerBin(opts Options) (string, error) {
	bin := firstNonEmpty(opts.ServerBin, os.Getenv("AUL_SERVER_BIN"))
	if bin == "" {
		exe, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("cannot locate this launcher to find its sibling server binary: %w (set --server-bin or AUL_SERVER_BIN)", err)
		}
		bin = filepath.Join(filepath.Dir(exe), serverBinName())
	}
	info, err := os.Stat(bin) // #nosec G703 -- the operator names their own server binary (--server-bin/AUL_SERVER_BIN)
	if err != nil {
		return "", fmt.Errorf("server binary %s not found: %w (build it with 'go build ./cmd/aul', or set --server-bin / AUL_SERVER_BIN)", bin, err)
	}
	if info.IsDir() {
		return "", fmt.Errorf("server binary path %s is a directory, not a file", bin)
	}
	return bin, nil
}

// serverBinName is the server executable's basename for this OS — a single-file
// runtime switch, no build tag needed.
func serverBinName() string {
	if runtime.GOOS == "windows" {
		return "aul.exe"
	}
	return "aul"
}

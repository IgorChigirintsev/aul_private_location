package launcher

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// minPepperBytes is the floor the config package also enforces
// (SESSION_HASH_PEPPER must be >= 16 bytes). We generate far more, but a
// hand-edited file that fell below it is a boot failure we catch here with a
// clearer message than the server would.
const minPepperBytes = 16

// provisionPepper reads <dataDir>/session_pepper, or generates it once. It NEVER
// rotates: the pepper is mixed into every session-token hash, so rewriting it
// would invalidate every existing session and silently log every member out — a
// documented self-host landmine. When the file is present it is reused verbatim.
//
// Idempotency is guaranteed operationally by acquiring the single-instance lock
// before this runs, so two launchers never race the generate-and-write.
func provisionPepper(dataDir string) (string, error) {
	path := filepath.Join(dataDir, "session_pepper")

	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		// Present: reuse exactly. TrimSpace only forgives a hand-added trailing
		// newline; our own writes carry none and round-trip identically.
		pepper := strings.TrimSpace(string(raw))
		if len(pepper) < minPepperBytes {
			return "", fmt.Errorf("session pepper %s is too short (%d bytes, need >= %d); "+
				"delete it to regenerate — but note that regenerating logs every member out",
				path, len(pepper), minPepperBytes)
		}
		return pepper, nil

	case errors.Is(err, os.ErrNotExist):
		// Absent: generate once and publish atomically.
		buf := make([]byte, 32)
		if _, err := rand.Read(buf); err != nil {
			return "", fmt.Errorf("generate session pepper: %w", err)
		}
		pepper := base64.StdEncoding.EncodeToString(buf) // 44 chars, well over the floor
		if err := atomicWriteFile(path, []byte(pepper), 0o600); err != nil {
			return "", fmt.Errorf("write session pepper %s: %w", path, err)
		}
		return pepper, nil

	default:
		return "", fmt.Errorf("read session pepper %s: %w", path, err)
	}
}

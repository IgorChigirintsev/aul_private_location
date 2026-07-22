package launcher

import (
	"fmt"
	"net/url"
	"os/exec"
	"runtime"
)

// openBrowser opens rawURL in the operator's default browser without blocking.
// It rejects any non-http(s) scheme first — the URL is handed to an OS handler,
// so an unexpected scheme (file:, a custom protocol handler) must never get
// through. On every OS the URL is its own argument, never interpolated into a
// shell string.
//
// The exec.Command calls are deliberately context-free: CommandContext would
// kill the operator's browser the moment the launcher's context is cancelled,
// while the opener is fire-and-forget (Start, never Run) precisely so it
// outlives us.
//
//nolint:noctx // see the paragraph above — cancellation must NOT reach the browser
func openBrowser(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("parse url %q: %w", rawURL, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("refusing to open non-http(s) url %q", rawURL)
	}

	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		// rundll32 avoids `cmd /c start` mangling '&' and treating a quoted first
		// arg as the window title, and it spawns no console window.
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", rawURL) // #nosec G204 -- fixed binary, no shell; rawURL validated http(s) above
	case "darwin":
		cmd = exec.Command("open", rawURL) // #nosec G204 -- fixed binary, no shell; rawURL validated http(s) above
	default:
		cmd = exec.Command("xdg-open", rawURL) // #nosec G204 -- fixed binary, no shell; rawURL validated http(s) above
	}
	// Start, never Run: we must not block on the browser process, and a headless
	// box with no opener is a non-fatal condition the caller handles.
	return cmd.Start()
}

package launcher

import (
	"fmt"
	"io"
)

// statusInfo carries the resolved facts printStatus renders.
type statusInfo struct {
	res     resolved
	dataDir string
	logPath string
}

// printStatus writes the concise human status block to w (STDOUT, kept separate
// from slog's STDERR). The Dashboard line is ALWAYS the resolved Origin — the
// anti-localhost invariant that stops a real funnel/LAN origin from being
// replaced by localhost in an invite — and the closing note is the honest
// keep-this-PC-on caveat every self-host operator must understand.
func printStatus(w io.Writer, info statusInfo) {
	fmt.Fprintln(w, "  Aul self-host is running.")
	fmt.Fprintln(w)
	fmt.Fprintf(w, "  Mode:       %s\n", modeLabel(info.res))
	fmt.Fprintf(w, "  Origin:     %s\n", info.res.Origin)
	fmt.Fprintf(w, "  Dashboard:  %s\n", info.res.Origin)
	fmt.Fprintf(w, "  Data dir:   %s\n", info.dataDir)
	fmt.Fprintf(w, "  Server log: %s\n", info.logPath)
	fmt.Fprintln(w)
	fmt.Fprintln(w, "  Keep this computer on and connected. While it is off, circle")
	fmt.Fprintln(w, "  members see only your LAST-SEEN location until it returns.")
	fmt.Fprintln(w, "  Press Ctrl-C to stop.")
}

// modeLabel renders (env, source) as human text for the status block.
func modeLabel(res resolved) string {
	switch res.Source {
	case sourceFlag:
		return res.Env + " (explicit origin)"
	case sourceFunnel:
		return res.Env + " (Tailscale Funnel)"
	case sourceLocalhost:
		return res.Env + " (local)"
	default:
		return res.Env
	}
}

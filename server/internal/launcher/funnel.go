package launcher

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// funnelResult is a detected public front: the https Origin the world uses and
// the local BindPort Funnel proxies to (a string, straight from the parsed proxy
// target — "" means "use the configured port").
type funnelResult struct {
	Origin   string
	BindPort string
}

// tsStatus is the subset of `tailscale status --json` we read.
type tsStatus struct {
	BackendState string
	Self         struct {
		DNSName string
	}
}

// serveConfig is the subset of `tailscale serve status --json` we decode. Only
// the fields that decide "is a public Funnel live for this host" are read, so the
// probe survives Tailscale schema drift.
type serveConfig struct {
	TCP map[string]struct {
		HTTPS bool
	}
	Web map[string]struct {
		Handlers map[string]struct {
			Proxy string
		}
	}
	AllowFunnel map[string]bool
	// Foreground holds the config of a blocking `tailscale funnel` (no --bg),
	// keyed by session id; each entry is a nested serveConfig we must also search.
	Foreground map[string]*serveConfig
}

// FunnelOrigin probes Tailscale for an already-configured public Funnel origin.
// It NEVER hangs: each tailscale call is deadline-bounded, and any failure (no
// tailscale, tailscaled down, no Funnel configured) returns ok=false with a human
// reason so the caller falls back to localhost. It only DETECTS an existing
// Funnel — setting one up (`tailscale serve --funnel`) is the operator's job.
func FunnelOrigin(ctx context.Context) (funnelResult, bool, string) {
	if _, err := exec.LookPath("tailscale"); err != nil {
		return funnelResult{}, false, "tailscale CLI not found on PATH"
	}

	var st tsStatus
	if err := tsJSON(ctx, &st, "status", "--json", "--peers=false"); err != nil {
		return funnelResult{}, false, fmt.Sprintf("tailscale status failed: %v", err)
	}
	if st.BackendState != "Running" {
		return funnelResult{}, false, fmt.Sprintf("tailscale backend is %q, not Running", st.BackendState)
	}
	magic := strings.TrimSuffix(st.Self.DNSName, ".")
	if magic == "" {
		return funnelResult{}, false, "tailscale reports no MagicDNS name for this node"
	}

	var sc serveConfig
	if err := tsJSON(ctx, &sc, "serve", "status", "--json"); err != nil {
		return funnelResult{}, false, fmt.Sprintf("tailscale serve status failed: %v", err)
	}

	hp, proxy, ok := sc.funnelHostPort(magic)
	if !ok {
		return funnelResult{}, false, "no public Funnel is configured for this node"
	}
	origin, err := funnelOrigin(hp)
	if err != nil {
		return funnelResult{}, false, err.Error()
	}
	return funnelResult{Origin: origin, BindPort: proxyPort(proxy)}, true, ""
}

// funnelHostPort finds the HostPort key of a live public Funnel for this node's
// MagicDNS name, plus the proxy target of its first handler. A funnel is live iff
// it is allowed (AllowFunnel[hp]), its port terminates TLS (TCP[port].HTTPS), and
// it actually proxies something (Web[hp].Handlers non-empty). A blocking
// `tailscale funnel` stores its config under Foreground[*] instead of the top
// level, so we recurse there too. The DNSName is dot-stripped before comparison.
func (sc *serveConfig) funnelHostPort(magic string) (hostPort, proxy string, ok bool) {
	for hp := range sc.AllowFunnel {
		if !sc.AllowFunnel[hp] {
			continue
		}
		host, port, err := net.SplitHostPort(hp)
		if err != nil {
			continue
		}
		if !strings.EqualFold(strings.TrimSuffix(host, "."), magic) {
			continue
		}
		if tcp, hasTCP := sc.TCP[port]; !hasTCP || !tcp.HTTPS {
			continue
		}
		web, hasWeb := sc.Web[hp]
		if !hasWeb || len(web.Handlers) == 0 {
			continue
		}
		return hp, firstProxy(web.Handlers), true
	}
	// Recurse into any foreground (blocking `tailscale funnel`) sessions.
	for _, fg := range sc.Foreground {
		if fg == nil {
			continue
		}
		if hp, proxy, ok := fg.funnelHostPort(magic); ok {
			return hp, proxy, ok
		}
	}
	return "", "", false
}

// firstProxy returns a deterministic proxy target from a handler set (the first
// non-empty one by sorted mount path), so the derived bind port is stable.
func firstProxy(handlers map[string]struct{ Proxy string }) string {
	paths := make([]string, 0, len(handlers))
	for p := range handlers {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		if handlers[p].Proxy != "" {
			return handlers[p].Proxy
		}
	}
	return ""
}

// funnelOrigin turns a Funnel HostPort key into the public https origin. Funnel
// allows only 443/8443/10000; 443 is implicit so it is omitted, the others are
// appended verbatim — the port is read from the key, never hardcoded.
func funnelOrigin(hostPort string) (string, error) {
	host, port, err := net.SplitHostPort(hostPort)
	if err != nil {
		return "", fmt.Errorf("funnel host:port %q: %w", hostPort, err)
	}
	origin := "https://" + strings.TrimSuffix(host, ".")
	if port != "443" {
		origin += ":" + port
	}
	return origin, nil
}

// proxyPort extracts the local port from a handler proxy target like
// "http://127.0.0.1:8080" → "8080". An unparseable target yields "", and the
// caller falls back to the configured port.
func proxyPort(proxy string) string {
	u, err := url.Parse(proxy)
	if err != nil {
		return ""
	}
	return u.Port()
}

// tsJSON runs a tailscale subcommand with a hard 4s deadline and decodes its JSON
// stdout into out. A wedged tailscaled must degrade the launcher to localhost,
// never block startup — so a timeout or a non-zero exit is an error.
func tsJSON(ctx context.Context, out any, args ...string) error {
	cctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	var stdout, stderr bytes.Buffer
	// #nosec G204 -- fixed binary name, no shell; args come from our own call sites, never user input
	cmd := exec.CommandContext(cctx, "tailscale", args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if cctx.Err() != nil {
			return fmt.Errorf("timed out after 4s: %w", cctx.Err())
		}
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	if err := json.Unmarshal(stdout.Bytes(), out); err != nil {
		return fmt.Errorf("decode json: %w", err)
	}
	return nil
}

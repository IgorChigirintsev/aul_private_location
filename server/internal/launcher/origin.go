package launcher

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"strconv"
)

// resolved is the outcome of origin resolution: the exact PUBLIC_ORIGIN plus the
// AUL_ENV / SECURE_COOKIES / bind-port values derived from it, and the Source
// (flag|funnel|localhost) for the human status block.
type resolved struct {
	Origin        string
	Env           string
	SecureCookies bool
	BindPort      int
	Source        string
}

// funnelDetector reports a public https origin (and its local proxy-target port)
// when a Tailscale Funnel already serves this machine. It is injected into
// resolveOrigin so origin resolution is unit-testable without Tailscale. ok=false
// means "fall back"; the string is a human reason for logs.
type funnelDetector func(ctx context.Context) (funnelResult, bool, string)

const (
	sourceFlag      = "flag"
	sourceFunnel    = "funnel"
	sourceLocalhost = "localhost"
)

// classifyOrigin maps an origin scheme onto (AUL_ENV, SECURE_COOKIES). This one
// coupling captures the server's config rules: an https origin is a real public
// front (production, secure cookies — config Rule A/C), while anything else can
// only be a same-machine dev origin, where SECURE_COOKIES=true over http is a
// hard boot failure (config Rule C).
func classifyOrigin(scheme string) (env string, secure bool) {
	if scheme == "https" {
		return "production", true
	}
	return "development", false
}

// resolveOrigin decides the public origin in priority order: an explicit
// --origin wins; else a detected Tailscale Funnel; else the localhost fallback.
// The dashboard is always opened at the returned Origin — baking localhost into
// an invite when a real front exists is THE critical launcher bug, so this is the
// single place that decision is made.
func resolveOrigin(ctx context.Context, opts Options, detect funnelDetector) (resolved, error) {
	// (a) Explicit origin: the operator told us exactly what the world sees.
	if opts.Origin != "" {
		u, err := url.Parse(opts.Origin)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
			return resolved{}, fmt.Errorf("invalid --origin %q: want an absolute http(s) URL like https://aul.example.com", opts.Origin)
		}
		env, secure := classifyOrigin(u.Scheme)
		return resolved{
			Origin:        originString(u),
			Env:           env,
			SecureCookies: secure,
			BindPort:      opts.Port,
			Source:        sourceFlag,
		}, nil
	}

	// (b) Tailscale Funnel: a public https origin proxied to a local port. Bind to
	// that proxy-target port so HTTP_ADDR matches what Funnel forwards to.
	if fr, ok, reason := detect(ctx); ok {
		env, secure := classifyOrigin("https")
		port := opts.Port
		if fr.BindPort != "" {
			if n, err := strconv.Atoi(fr.BindPort); err == nil {
				port = n
			}
		}
		return resolved{
			Origin:        fr.Origin,
			Env:           env,
			SecureCookies: secure,
			BindPort:      port,
			Source:        sourceFunnel,
		}, nil
	} else if reason != "" {
		slog.Debug("tailscale funnel not used, falling back to localhost", "reason", reason)
	}

	// (c) Fallback: localhost only. NOT 127.0.0.1 — the browser must hit the exact
	// PUBLIC_ORIGIN string or the server's WS origin check and CORS reject it. The
	// readyz probe uses 127.0.0.1 separately, which is fine server-side.
	env, secure := classifyOrigin("http")
	return resolved{
		Origin:        "http://localhost:" + strconv.Itoa(opts.Port),
		Env:           env,
		SecureCookies: secure,
		BindPort:      opts.Port,
		Source:        sourceLocalhost,
	}, nil
}

// originString normalizes a parsed URL to scheme://host[:port] with no path — the
// canonical PUBLIC_ORIGIN shape the server also stores.
func originString(u *url.URL) string {
	return (&url.URL{Scheme: u.Scheme, Host: u.Host}).String()
}

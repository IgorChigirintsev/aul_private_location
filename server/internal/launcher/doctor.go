package launcher

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"runtime"
	"strings"
)

// DoctorCheck is one preflight step: what it looked at, whether it passed, what
// was found, and — when it failed — the exact next action. Every fix is a step a
// launcher CANNOT perform silently (an SSO login, an admin-console toggle), which
// is precisely why this guided command exists (SELF_HOST_DESIGN.md §a).
type DoctorCheck struct {
	Name   string
	OK     bool
	Detail string
	Fix    string // multi-line allowed; empty when OK
}

// DoctorReport is the staged result: the checks run so far (in order), plus the
// reachable public origin when everything passed (empty otherwise).
type DoctorReport struct {
	Checks []DoctorCheck
	Origin string
}

// Ready reports whether the box is reachable end-to-end (a public Funnel serves
// this node), i.e. whether `aul-launcher` will bake a reachable origin into
// invites rather than an unreachable localhost.
func (r DoctorReport) Ready() bool { return r.Origin != "" }

// Diagnose runs the self-host reachability preflight in dependency order — is
// Tailscale installed, logged in, MagicDNS-named, and serving a public Funnel for
// this node — and stops at the first unmet prerequisite with an actionable fix
// (there is no point probing Funnel while tailscaled is down). It only ever reads
// state; it changes nothing.
func Diagnose(ctx context.Context) DoctorReport {
	var r DoctorReport
	add := func(c DoctorCheck) { r.Checks = append(r.Checks, c) }

	// 1. Tailscale CLI present.
	if _, err := exec.LookPath("tailscale"); err != nil {
		add(DoctorCheck{Name: "Tailscale installed", Detail: "not found on PATH", Fix: installFix()})
		return r
	}
	add(DoctorCheck{Name: "Tailscale installed", OK: true, Detail: "found on PATH"})

	// 2. Backend running (i.e. logged in and up).
	var st tsStatus
	if err := tsJSON(ctx, &st, "status", "--json", "--peers=false"); err != nil {
		add(DoctorCheck{Name: "Tailscale running", Detail: err.Error(), Fix: "Start and sign in:  " + upCmd()})
		return r
	}
	if st.BackendState != "Running" {
		add(DoctorCheck{Name: "Tailscale running", Detail: fmt.Sprintf("backend is %q", st.BackendState), Fix: "Sign in:  " + upCmd()})
		return r
	}
	add(DoctorCheck{Name: "Tailscale running", OK: true, Detail: "backend Running"})

	// 3. MagicDNS name — the stable https://<name>.ts.net host invites are baked on.
	magic := strings.TrimSuffix(st.Self.DNSName, ".")
	if magic == "" {
		add(DoctorCheck{Name: "MagicDNS name", Detail: "this node has none", Fix: "Enable MagicDNS + HTTPS certificates in the admin console:\n  https://login.tailscale.com/admin/dns"})
		return r
	}
	add(DoctorCheck{Name: "MagicDNS name", OK: true, Detail: magic})

	// 4. A public Funnel actually serving this node.
	fr, ok, reason := FunnelOrigin(ctx)
	if !ok {
		add(DoctorCheck{Name: "Public Funnel", Detail: reason, Fix: funnelFix(magic)})
		return r
	}
	add(DoctorCheck{Name: "Public Funnel", OK: true, Detail: fr.Origin})
	r.Origin = fr.Origin
	return r
}

// WriteReport prints a doctor report as a human checklist (a ✓/✗ per step, the
// fix indented under any failure), then a one-line verdict.
func WriteReport(w io.Writer, r DoctorReport) {
	for _, c := range r.Checks {
		mark := "✗"
		if c.OK {
			mark = "✓"
		}
		fmt.Fprintf(w, "%s %s — %s\n", mark, c.Name, c.Detail)
		if !c.OK && c.Fix != "" {
			for _, line := range strings.Split(c.Fix, "\n") {
				fmt.Fprintf(w, "    %s\n", line)
			}
		}
	}
	if r.Ready() {
		fmt.Fprintf(w, "\nReady — your server is reachable at %s\n", r.Origin)
		fmt.Fprintln(w, "Start it any time with:  aul-launcher")
		return
	}
	fmt.Fprintln(w, "\nNot reachable yet. Do the step above, then re-run:  aul-launcher doctor")
	fmt.Fprintln(w, "(You can still run `aul-launcher` now — it will serve on localhost only,")
	fmt.Fprintln(w, " which is fine for trying it on this machine but not for remote members.)")
}

// installFix is the OS-appropriate "install Tailscale" instruction.
func installFix() string {
	switch runtime.GOOS {
	case "darwin":
		return "Install Tailscale (Mac App Store or https://tailscale.com/download/mac), then:  tailscale up"
	case "windows":
		return "Install Tailscale (https://tailscale.com/download/windows), then sign in from the tray"
	default:
		return "Install Tailscale, then sign in:\n  curl -fsSL https://tailscale.com/install.sh | sh\n  sudo tailscale up"
	}
}

// upCmd is the OS-appropriate `tailscale up` invocation (root on Linux).
func upCmd() string {
	if runtime.GOOS == "linux" {
		return "sudo tailscale up"
	}
	return "tailscale up"
}

// funnelFix is the guided Funnel-enablement instruction. Funnel is OFF by default
// and needs both an admin-console grant and a `tailscale funnel` command — the
// one step no launcher can do silently.
func funnelFix(magic string) string {
	return "Enable Funnel for this node, then expose the launcher's port:\n" +
		"  1. Admin console → Access controls: grant the \"funnel\" nodeAttr to this node\n" +
		"     (https://login.tailscale.com/admin/acls) — Funnel is OFF by default.\n" +
		"  2. Run:  tailscale funnel 8080   (8080 is the port aul-launcher serves)\n" +
		"  Then this box is reachable at  https://" + magic
}

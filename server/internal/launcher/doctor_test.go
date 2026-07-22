package launcher

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteReport_Ready(t *testing.T) {
	var b bytes.Buffer
	WriteReport(&b, DoctorReport{
		Checks: []DoctorCheck{
			{Name: "Tailscale installed", OK: true, Detail: "found on PATH"},
			{Name: "Public Funnel", OK: true, Detail: "https://box.tail1.ts.net"},
		},
		Origin: "https://box.tail1.ts.net",
	})
	out := b.String()
	if !strings.Contains(out, "✓ Tailscale installed") {
		t.Errorf("missing a passing check line:\n%s", out)
	}
	if !strings.Contains(out, "Ready — your server is reachable at https://box.tail1.ts.net") {
		t.Errorf("missing the ready verdict:\n%s", out)
	}
}

func TestWriteReport_NotReady_IndentsTheFix(t *testing.T) {
	var b bytes.Buffer
	WriteReport(&b, DoctorReport{
		Checks: []DoctorCheck{
			{Name: "Tailscale installed", OK: true, Detail: "found on PATH"},
			{Name: "Public Funnel", Detail: "no public Funnel is configured", Fix: "step one\nstep two"},
		},
	})
	out := b.String()
	if !strings.Contains(out, "✗ Public Funnel") {
		t.Errorf("missing the failed check:\n%s", out)
	}
	if !strings.Contains(out, "    step one") || !strings.Contains(out, "    step two") {
		t.Errorf("fix must be indented per line:\n%s", out)
	}
	if !strings.Contains(out, "Not reachable yet") {
		t.Errorf("missing the not-ready verdict:\n%s", out)
	}
}

func TestFunnelFix_MentionsHostPortAndConsole(t *testing.T) {
	fix := strings.ToLower(funnelFix("box.tail1.ts.net"))
	for _, want := range []string{"funnel", "tailscale funnel 8080", "https://box.tail1.ts.net", "admin"} {
		if !strings.Contains(fix, strings.ToLower(want)) {
			t.Errorf("funnelFix missing %q:\n%s", want, fix)
		}
	}
}

func TestInstallFix_NonEmpty(t *testing.T) {
	if strings.TrimSpace(installFix()) == "" {
		t.Error("installFix must not be empty")
	}
}

func TestWarnIfOriginChanged_PinsFunnelHostAndDetectsChange(t *testing.T) {
	dir := t.TempDir()
	pin := filepath.Join(dir, "origin.pinned")
	read := func() string {
		b, _ := os.ReadFile(pin)
		return strings.TrimSpace(string(b))
	}

	// First Funnel run records the reachable origin.
	warnIfOriginChanged(dir, resolved{Origin: "https://a.ts.net", Source: sourceFunnel})
	if got := read(); got != "https://a.ts.net" {
		t.Fatalf("pinned = %q, want https://a.ts.net", got)
	}

	// A localhost/flag origin is NOT pinned — it isn't a stable, shareable host —
	// so it must never overwrite the ts.net pin.
	warnIfOriginChanged(dir, resolved{Origin: "http://localhost:8080", Source: sourceLocalhost})
	if got := read(); got != "https://a.ts.net" {
		t.Errorf("localhost run overwrote the pin: %q", got)
	}

	// A changed Funnel host (rename appended "-1") updates the record so the next
	// run is quiet again — the warning fired once, on this transition.
	warnIfOriginChanged(dir, resolved{Origin: "https://a-1.ts.net", Source: sourceFunnel})
	if got := read(); got != "https://a-1.ts.net" {
		t.Errorf("changed host not recorded: %q", got)
	}
}

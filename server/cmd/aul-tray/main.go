//go:build tray

// Command aul-tray is the system-tray shell over the headless launcher core
// (internal/launcher). It runs exactly one server via launcher.Run and surfaces
// the ~5 Phase-1 widgets from SELF_HOST_DESIGN.md: status, the reachable address,
// open-dashboard, and quit. The headless core stays pure-Go and all-OS; this thin
// GUI layer is the only part that needs a native toolkit, so it is a SEPARATE
// build target, gated behind the `tray` build tag and excluded from the default
// `go build ./...` (and CI) — which keeps the core CGO-free.
//
// STATUS: scaffold. It is not compiled by the default build and was NOT built or
// run in the authoring environment (a tray needs CGO + a native GUI toolkit + a
// display, none of which were available). Treat the systray wiring as unverified
// until it is built and run on a real desktop.
//
// BUILD (Linux):
//
//	go get fyne.io/systray            # add the maintained systray fork
//	sudo apt install libayatana-appindicator3-dev   # (or libappindicator3-dev)
//	CGO_ENABLED=1 go build -tags tray -o aul-tray ./cmd/aul-tray
//	# place aul-tray next to the `aul` server binary, then run it.
//
// macOS / Windows use the SAME fyne.io/systray package and this same source, but
// must be built on their own hosts (Cocoa / Win32), and — for distribution —
// notarized / EV-signed. That signing/packaging is the external "last mile"
// (SELF_HOST_DESIGN.md); this file is only the shared cross-OS tray logic.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"sync/atomic"

	"fyne.io/systray"

	"github.com/aul-app/aul/server/internal/launcher"
)

// currentOrigin holds the reachable address once the server is up, so the
// "Open dashboard" click has something to open. atomic because launcher.Run's
// OnReady callback fires on a different goroutine than the menu loop.
var currentOrigin atomic.Pointer[string]

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetTitle("Aul")
	systray.SetTooltip("Aul — your self-hosted server")

	mStatus := systray.AddMenuItem("Starting…", "Server status")
	mStatus.Disable()
	mOpen := systray.AddMenuItem("Open dashboard", "Open your Aul dashboard")
	mOpen.Disable() // enabled once we know the address
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop the server and quit")

	ctx, cancel := context.WithCancel(context.Background())

	// The headless core: resolve env, spawn + supervise the server, detect the
	// Funnel origin. NoOpen — the tray owns "open", not the launcher. OnReady
	// lands the reachable address into the menu the instant /readyz passes.
	go func() {
		err := launcher.Run(ctx, launcher.Options{
			NoOpen: true,
			OnReady: func(origin string) {
				o := origin
				currentOrigin.Store(&o)
				mStatus.SetTitle("Running · " + origin)
				mOpen.Enable()
			},
		})
		if err != nil && ctx.Err() == nil {
			slog.Error("launcher stopped unexpectedly", "err", err)
			mStatus.SetTitle("Stopped — see server.log")
			mOpen.Disable()
		}
	}()

	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				if o := currentOrigin.Load(); o != nil {
					if err := openURL(*o); err != nil {
						slog.Warn("could not open the dashboard", "url", *o, "err", err)
					}
				}
			case <-mQuit.ClickedCh:
				cancel()       // graceful server stop inside launcher.Run
				systray.Quit() // tear the tray down
				return
			}
		}
	}()
}

// openURL opens the default browser at url, per OS.
func openURL(url string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		return exec.Command("xdg-open", url).Start()
	}
}

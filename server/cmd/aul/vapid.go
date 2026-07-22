package main

import (
	"fmt"
	"io"

	webpush "github.com/SherClockHolmes/webpush-go"
)

// runVAPIDKeys generates a fresh Web Push (VAPID) keypair and prints it as env
// lines ready to paste into the server's environment. Like publish-version it
// avoids config.Load() — generating keys needs no database and no runtime
// secrets, which is the point: an operator can enable push before the server
// has ever booted with it.
//
// The private key is a signing secret: whoever holds it can send push messages
// that clients accept as coming from this deployment. It grants no access to
// notification contents — those are sealed under the circle key K_c, which the
// server never has.
func runVAPIDKeys(out io.Writer) error {
	private, public, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		return fmt.Errorf("generate vapid keys: %w", err)
	}
	fmt.Fprintf(out, "# Web Push (VAPID) keypair — add to the server environment.\n")
	fmt.Fprintf(out, "# Keep VAPID_PRIVATE_KEY secret; VAPID_PUBLIC_KEY is served to clients.\n")
	fmt.Fprintf(out, "# Rotating the keypair invalidates every existing subscription.\n")
	fmt.Fprintf(out, "VAPID_PUBLIC_KEY=%s\n", public)
	fmt.Fprintf(out, "VAPID_PRIVATE_KEY=%s\n", private)
	fmt.Fprintf(out, "VAPID_SUBJECT=mailto:ops@example.com\n")
	return nil
}

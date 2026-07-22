package launcher

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

// waitReady polls the server's /readyz until it returns 200 or the timeout
// elapses. It probes 127.0.0.1 (server-side, unaffected by the browser-origin
// rule that keeps a fallback PUBLIC_ORIGIN on "localhost"). /readyz runs
// store.Ping, so a 200 means the SQLite store is open AND migrated — a genuine
// readiness gate, not a bare liveness ping.
func waitReady(ctx context.Context, port int, timeout time.Duration) error {
	target := "http://127.0.0.1:" + strconv.Itoa(port) + "/readyz"
	client := &http.Client{Timeout: 2 * time.Second}

	deadlineCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		if probeOnce(deadlineCtx, client, target) {
			return nil
		}
		select {
		case <-deadlineCtx.Done():
			return fmt.Errorf("server did not answer 200 at %s within %s", target, timeout)
		case <-ticker.C:
		}
	}
}

// probeOnce does a single GET and reports whether the server answered 200.
func probeOnce(ctx context.Context, client *http.Client, target string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	// Drain a little so the connection can be reused across polls.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
	return resp.StatusCode == http.StatusOK
}

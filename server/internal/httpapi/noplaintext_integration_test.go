//go:build integration

package httpapi_test

import (
	"context"
	"encoding/base64"
	"net/http"
	"testing"
	"time"

	"github.com/aul-app/aul/server/internal/crypto"
)

// TestServerStoresNoPlaintext is the Phase-4 criterion "the server contains no
// plaintext": a ping sealed client-side is stored opaquely, the pings table has
// no coordinate columns, and no circle key lives in the database.
func TestServerStoresNoPlaintext(t *testing.T) {
	c := newTestServer(t)
	tok, deviceID := register(c, "e2ee@ex.com", "web")
	_ = deviceID

	_, circle := c.do(http.MethodPost, "/v1/circles", tok, map[string]any{"retention_days": 7})
	circleID := circle["id"].(string)

	// Seal a ping whose plaintext carries a distinctive marker, with a circle
	// key the server never sees.
	key := make([]byte, crypto.XChaChaKeySize)
	for i := range key {
		key[i] = byte(i * 7)
	}
	nonce := make([]byte, crypto.XChaChaNonceSize)
	for i := range nonce {
		nonce[i] = byte(i + 1)
	}
	const marker = "SECRET_LAT_43.238949_LNG_76.889709"
	ct, err := crypto.SealXChaCha20(key, nonce, []byte(`{"m":"`+marker+`"}`), nil)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}

	code, _ := c.do(http.MethodPost, "/v1/pings/batch", tok, map[string]any{
		"pings": []map[string]any{{
			"circle_id":   circleID,
			"client_id":   "np-1",
			"nonce":       base64.StdEncoding.EncodeToString(nonce),
			"ciphertext":  base64.StdEncoding.EncodeToString(ct),
			"captured_at": time.Now().UTC().Format(time.RFC3339),
		}},
	})
	if code != http.StatusOK {
		t.Fatalf("post ping: %d", code)
	}

	ctx := context.Background()

	// 1) The stored ciphertext must NOT contain the plaintext marker.
	var stored []byte
	if err := c.qRow(ctx,
		`SELECT ciphertext FROM pings WHERE circle_id = $1 LIMIT 1`, circleID).Scan(&stored); err != nil {
		t.Fatalf("read ciphertext: %v", err)
	}
	if len(stored) == 0 {
		t.Fatal("no ciphertext stored")
	}
	if containsSub(stored, []byte(marker)) {
		t.Fatal("plaintext marker found in stored ciphertext — server can see coordinates!")
	}

	// 2) The pings table must have NO coordinate columns.
	forbidden := map[string]bool{"lat": true, "lng": true, "latitude": true, "longitude": true, "location": true, "geom": true, "geography": true, "coordinates": true}
	for _, col := range c.tableColumns(ctx, "pings") {
		if forbidden[col] {
			t.Fatalf("pings table has a plaintext coordinate column: %q", col)
		}
	}

	// 3) No circle key is stored anywhere (the circles table has no key column).
	forbiddenKeys := map[string]bool{"key": true, "circle_key": true, "k_c": true, "secret": true}
	for _, col := range c.tableColumns(ctx, "circles") {
		if forbiddenKeys[col] {
			t.Fatal("circles table stores a key — K_c must never touch the server")
		}
	}
}

func containsSub(haystack, needle []byte) bool {
	if len(needle) == 0 {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := range needle {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

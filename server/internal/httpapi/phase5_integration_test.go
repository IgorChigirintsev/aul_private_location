//go:build integration

package httpapi_test

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/aul-app/aul/server/internal/crypto"
)

// TestAPI_Places_CRUD_Concurrency exercises the encrypted-places lifecycle:
// create → list → optimistic-concurrency update → stale-version 409 → soft
// delete → excluded from list. Non-members are refused (404, no existence leak).
func TestAPI_Places_CRUD_Concurrency(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "places-owner@ex.com", "web")
	sTok, _ := register(c, "places-stranger@ex.com", "web")

	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{"retention_days": 7})
	circleID := circle["id"].(string)

	// Create.
	code, p := c.do(http.MethodPost, "/v1/circles/"+circleID+"/places", aTok, map[string]any{"ciphertext": b64("PLACE-BLOB-1")})
	if code != http.StatusCreated {
		t.Fatalf("create place: %d %v", code, p)
	}
	placeID := p["id"].(string)
	if int(p["version"].(float64)) != 1 {
		t.Fatalf("new place version = %v, want 1", p["version"])
	}

	// List shows it.
	_, list := c.do(http.MethodGet, "/v1/circles/"+circleID+"/places", aTok, nil)
	if n := len(list["places"].([]any)); n != 1 {
		t.Fatalf("list places = %d, want 1", n)
	}

	// Update with the correct version bumps to 2.
	code, up := c.do(http.MethodPut, "/v1/circles/"+circleID+"/places/"+placeID, aTok, map[string]any{"ciphertext": b64("PLACE-BLOB-2"), "version": 1})
	if code != http.StatusOK || int(up["version"].(float64)) != 2 {
		t.Fatalf("update place: %d %v", code, up)
	}

	// Update with a stale version conflicts (409) — optimistic concurrency.
	code, _ = c.do(http.MethodPut, "/v1/circles/"+circleID+"/places/"+placeID, aTok, map[string]any{"ciphertext": b64("PLACE-BLOB-3"), "version": 1})
	if code != http.StatusConflict {
		t.Fatalf("stale update: expected 409, got %d", code)
	}

	// Non-member cannot see or create places (404, existence not leaked).
	if code, _ := c.do(http.MethodGet, "/v1/circles/"+circleID+"/places", sTok, nil); code != http.StatusNotFound {
		t.Fatalf("stranger list places: expected 404, got %d", code)
	}

	// Soft delete → excluded from list.
	if code, _ := c.do(http.MethodDelete, "/v1/circles/"+circleID+"/places/"+placeID, aTok, nil); code != http.StatusOK {
		t.Fatalf("delete place: %d", code)
	}
	_, list2 := c.do(http.MethodGet, "/v1/circles/"+circleID+"/places", aTok, nil)
	if n := len(list2["places"].([]any)); n != 0 {
		t.Fatalf("list after delete = %d, want 0", n)
	}
}

// TestAPI_SOS_Lifecycle: create → appears in active list → resolve → gone from
// active → resolving again 404s. Any member can resolve.
func TestAPI_SOS_Lifecycle(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "sos-owner@ex.com", "android")
	bTok, _ := register(c, "sos-member@ex.com", "web")

	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 2})
	c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil)

	// Owner raises an SOS.
	code, ev := c.do(http.MethodPost, "/v1/circles/"+circleID+"/sos", aTok, map[string]any{"ciphertext": b64("SOS-SEALED-PAYLOAD")})
	if code != http.StatusCreated {
		t.Fatalf("create sos: %d %v", code, ev)
	}
	sosID := ev["id"].(string)

	// Active list shows exactly one.
	_, active := c.do(http.MethodGet, "/v1/circles/"+circleID+"/sos", bTok, nil)
	if n := len(active["sos"].([]any)); n != 1 {
		t.Fatalf("active sos = %d, want 1", n)
	}

	// Another member resolves it.
	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/sos/"+sosID+"/resolve", bTok, nil); code != http.StatusOK {
		t.Fatalf("resolve sos: %d", code)
	}
	_, active2 := c.do(http.MethodGet, "/v1/circles/"+circleID+"/sos", bTok, nil)
	if n := len(active2["sos"].([]any)); n != 0 {
		t.Fatalf("active sos after resolve = %d, want 0", n)
	}
	// Resolving an already-resolved SOS is a 404 (no active row).
	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/sos/"+sosID+"/resolve", bTok, nil); code != http.StatusNotFound {
		t.Fatalf("double resolve: expected 404, got %d", code)
	}
}

// TestAPI_PingHistoryEndpointRemoved pins the removal: the product dropped
// location history, so the range read must stay gone. /pings/latest (the live
// map) keeps working — that is the line this test defends.
func TestAPI_PingHistoryEndpointRemoved(t *testing.T) {
	c := newTestServer(t)
	aTok, aDev := register(c, "hist-owner@ex.com", "android")
	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{"retention_days": 30})
	circleID := circle["id"].(string)

	now := time.Now().UTC()
	code, _ := c.do(http.MethodPost, "/v1/pings/batch", aTok, map[string]any{
		"pings": []map[string]any{{
			"circle_id": circleID, "client_id": "h1", "nonce": nonce24(),
			"ciphertext": b64("H-1"), "captured_at": now.Add(-time.Hour).Format(time.RFC3339),
		}},
	})
	if code != http.StatusOK {
		t.Fatalf("post ping: %d", code)
	}

	// The history range read is gone: no route, so the SPA fallback answers —
	// anything but a 200 JSON track. What matters is that it serves no pings.
	from := now.Add(-4 * time.Hour).Format(time.RFC3339)
	to := now.Format(time.RFC3339)
	code, hist := c.do(http.MethodGet, "/v1/circles/"+circleID+"/pings?device="+aDev+"&from="+from+"&to="+to, aTok, nil)
	if code == http.StatusOK && hist["pings"] != nil {
		t.Fatalf("ping history endpoint still serves a track: %d %v", code, hist)
	}

	// Ingest and the live map are untouched: the ping was stored and is served.
	code, latest := c.do(http.MethodGet, "/v1/circles/"+circleID+"/pings/latest", aTok, nil)
	if code != http.StatusOK {
		t.Fatalf("latest: %d %v", code, latest)
	}
	if n := len(latest["pings"].([]any)); n != 1 {
		t.Fatalf("latest pings = %d, want 1 — storage/ingest must still work", n)
	}
}

// TestAPI_Places_CreatedBy: a place records its AUTHOR, and no edit rewrites it.
// Clients render "«Home» · <owner nick>" from this, so it must survive another
// member's update (which moves updated_by, not created_by).
func TestAPI_Places_CreatedBy(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "place-author@ex.com", "web")
	bTok, _ := register(c, "place-editor@ex.com", "web")

	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)
	_, inv := c.do(http.MethodPost, "/v1/circles/"+circleID+"/invites", aTok, map[string]any{"max_uses": 2})
	c.do(http.MethodPost, "/v1/invites/"+inv["id"].(string)+"/accept", bTok, nil)

	authorID := userIDOf(c, aTok)

	// Create → the response names the author.
	code, p := c.do(http.MethodPost, "/v1/circles/"+circleID+"/places", aTok, map[string]any{"ciphertext": b64("PLACE-HOME")})
	if code != http.StatusCreated {
		t.Fatalf("create place: %d %v", code, p)
	}
	if p["created_by"] != authorID {
		t.Fatalf("create created_by = %v, want %v", p["created_by"], authorID)
	}
	placeID := p["id"].(string)

	// List → still the author.
	_, list := c.do(http.MethodGet, "/v1/circles/"+circleID+"/places", aTok, nil)
	got := list["places"].([]any)[0].(map[string]any)
	if got["created_by"] != authorID {
		t.Fatalf("list created_by = %v, want %v", got["created_by"], authorID)
	}

	// Another member edits it: created_by must NOT follow the last editor.
	code, up := c.do(http.MethodPut, "/v1/circles/"+circleID+"/places/"+placeID, bTok, map[string]any{
		"ciphertext": b64("PLACE-HOME-EDITED"), "version": 1,
	})
	if code != http.StatusOK {
		t.Fatalf("update place: %d %v", code, up)
	}
	if up["created_by"] != authorID {
		t.Fatalf("created_by after another member's edit = %v, want the original author %v", up["created_by"], authorID)
	}
}

// TestServerStoresNoPlaintext_PlacesAndSOS extends the Phase-4 no-plaintext
// guarantee to Phase-5 tables: a place and an SOS sealed client-side are stored
// opaquely (the plaintext marker never appears in the stored bytes), and neither
// table has any coordinate/name column.
func TestServerStoresNoPlaintext_PlacesAndSOS(t *testing.T) {
	c := newTestServer(t)
	aTok, _ := register(c, "np-places@ex.com", "web")
	_, circle := c.do(http.MethodPost, "/v1/circles", aTok, map[string]any{})
	circleID := circle["id"].(string)

	key := make([]byte, crypto.XChaChaKeySize)
	for i := range key {
		key[i] = byte(i*11 + 3)
	}
	nonce := make([]byte, crypto.XChaChaNonceSize)
	for i := range nonce {
		nonce[i] = byte(i + 5)
	}
	seal := func(marker string) string {
		ct, err := crypto.SealXChaCha20(key, nonce, []byte(`{"n":"`+marker+`"}`), nil)
		if err != nil {
			t.Fatalf("seal: %v", err)
		}
		return base64.StdEncoding.EncodeToString(ct)
	}

	const placeMarker = "HOME_LAT_51.5074_LNG_-0.1278"
	const sosMarker = "SOS_LAT_40.7128_LNG_-74.0060_HELP"

	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/places", aTok, map[string]any{"ciphertext": seal(placeMarker)}); code != http.StatusCreated {
		t.Fatalf("create place: %d", code)
	}
	if code, _ := c.do(http.MethodPost, "/v1/circles/"+circleID+"/sos", aTok, map[string]any{"ciphertext": seal(sosMarker)}); code != http.StatusCreated {
		t.Fatalf("create sos: %d", code)
	}

	ctx := context.Background()

	// Stored ciphertext must not contain the plaintext markers.
	check := func(table, marker string) {
		var stored []byte
		if err := c.qRow(ctx, fmt.Sprintf(`SELECT ciphertext FROM %s WHERE circle_id = $1 LIMIT 1`, table), circleID).Scan(&stored); err != nil {
			t.Fatalf("read %s ciphertext: %v", table, err)
		}
		if len(stored) == 0 {
			t.Fatalf("no ciphertext stored in %s", table)
		}
		if containsSub(stored, []byte(marker)) {
			t.Fatalf("plaintext marker found in %s ciphertext — server can read the payload!", table)
		}
	}
	check("places_enc", placeMarker)
	check("sos_events", sosMarker)

	// Neither table may have a coordinate/name column.
	forbidden := map[string]bool{
		"lat": true, "lng": true, "latitude": true, "longitude": true, "location": true,
		"geom": true, "geography": true, "coordinates": true, "name": true, "label": true, "address": true,
	}
	for _, table := range []string{"places_enc", "sos_events"} {
		for _, col := range c.tableColumns(ctx, table) {
			if forbidden[col] {
				t.Fatalf("%s has a plaintext column: %q", table, col)
			}
		}
	}
}

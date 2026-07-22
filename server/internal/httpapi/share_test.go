package httpapi

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

// The TTL ceiling is the feature's privacy guarantee — a share must not outlive
// the errand it was created for — so it is enforced on the server regardless of
// what the client asks for.
func TestClampShareTTL(t *testing.T) {
	cases := []struct {
		name    string
		seconds int64
		want    time.Duration
	}{
		{"absent field defaults", 0, 15 * time.Minute},
		{"negative defaults", -1, 15 * time.Minute},
		{"absurdly negative defaults", -999999, 15 * time.Minute},
		{"below floor clamps up", 1, time.Minute},
		{"just below floor clamps up", 59, time.Minute},
		{"floor exact", 60, time.Minute},
		{"in range passes through", 900, 15 * time.Minute},
		{"ceiling exact", 3600, time.Hour},
		{"just over ceiling clamps down", 3601, time.Hour},
		{"a day clamps down", 86400, time.Hour},
		{"overflow-sized request clamps down", 1 << 40, time.Hour},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := clampShareTTL(tc.seconds); got != tc.want {
				t.Fatalf("clampShareTTL(%d) = %v, want %v", tc.seconds, got, tc.want)
			}
		})
	}
}

// Whatever the request, the resolved TTL must land inside the documented window.
func TestClampShareTTL_AlwaysWithinBounds(t *testing.T) {
	for _, s := range []int64{-1 << 62, -1, 0, 1, 59, 60, 61, 900, 3599, 3600, 3601, 1 << 62} {
		got := clampShareTTL(s)
		if got < minShareTTL || got > maxShareTTL {
			t.Fatalf("clampShareTTL(%d) = %v, outside [%v, %v]", s, got, minShareTTL, maxShareTTL)
		}
	}
}

// The cookie is scoped to its own link so that holding one share never grants
// another, and so a viewer's browser sends it nowhere else on the origin.
func TestShareCookieNameAndPath(t *testing.T) {
	id := uuid.MustParse("11111111-2222-3333-4444-555555555555")
	other := uuid.MustParse("66666666-7777-8888-9999-000000000000")

	if got, want := shareCookieName(id), "aul_share_11111111-2222-3333-4444-555555555555"; got != want {
		t.Errorf("shareCookieName = %q, want %q", got, want)
	}
	if got, want := shareCookiePath(id), "/v1/share/11111111-2222-3333-4444-555555555555"; got != want {
		t.Errorf("shareCookiePath = %q, want %q", got, want)
	}
	if shareCookieName(id) == shareCookieName(other) {
		t.Error("two sessions must not share a cookie name")
	}
	if shareCookiePath(id) == shareCookiePath(other) {
		t.Error("two sessions must not share a cookie path")
	}
}

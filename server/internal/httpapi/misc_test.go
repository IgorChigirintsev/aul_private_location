package httpapi

import (
	"strings"
	"testing"
)

// POST /v1/push/subscribe accepts two shapes and must keep them strictly apart:
// a half-filled row is a subscription that can never be delivered, and the
// client never finds out.
func TestPushSubscriptionParams(t *testing.T) {
	const (
		endpoint = "https://push.example.com/sub/abc"
		p256dh   = "BF3xN2lnHU_Q1sMHc6IcVwGmqmYcM5V6R2iZ0vLbG5o"
		auth     = "kS1YQ8pQ5r0mZ3Xj2f4Yhw"
		token    = "fZx9:APA91bH-registration-token"
	)

	cases := []struct {
		name     string
		req      pushSubscribeReq
		wantErr  string // substring; "" = accepted
		wantKind string
		wantEP   string
		wantKeys bool // p256dh/auth must be stored
	}{
		// --- Web Push: unchanged from before FCM existed ---
		{
			name:     "webpush without kind (legacy client)",
			req:      pushSubscribeReq{Endpoint: endpoint, P256dh: p256dh, Auth: auth},
			wantKind: kindWebPush, wantEP: endpoint, wantKeys: true,
		},
		{
			name:     "webpush with explicit kind",
			req:      pushSubscribeReq{Kind: "webpush", Endpoint: endpoint, P256dh: p256dh, Auth: auth},
			wantKind: kindWebPush, wantEP: endpoint, wantKeys: true,
		},
		{
			name:    "webpush without p256dh",
			req:     pushSubscribeReq{Endpoint: endpoint, Auth: auth},
			wantErr: "endpoint, p256dh, and auth are required",
		},
		{
			name:    "webpush without auth",
			req:     pushSubscribeReq{Endpoint: endpoint, P256dh: p256dh},
			wantErr: "endpoint, p256dh, and auth are required",
		},
		{
			name:    "webpush without endpoint",
			req:     pushSubscribeReq{P256dh: p256dh, Auth: auth},
			wantErr: "endpoint, p256dh, and auth are required",
		},
		{
			name: "webpush with an oversized endpoint",
			req: pushSubscribeReq{
				Endpoint: strings.Repeat("a", maxPushEndpointBytes+1), P256dh: p256dh, Auth: auth,
			},
			wantErr: "too large",
		},
		{
			name:    "webpush with an oversized p256dh",
			req:     pushSubscribeReq{Endpoint: endpoint, P256dh: strings.Repeat("a", maxPushKeyBytes+1), Auth: auth},
			wantErr: "too large",
		},
		{
			// A client that sends both shapes has a bug; guessing which it means
			// would store a row it did not ask for.
			name:    "webpush must not carry an fcm token",
			req:     pushSubscribeReq{Endpoint: endpoint, P256dh: p256dh, Auth: auth, Token: token},
			wantErr: `token is only valid with kind="fcm"`,
		},

		// --- FCM ---
		{
			name:     "fcm token",
			req:      pushSubscribeReq{Kind: "fcm", Token: token},
			wantKind: kindFCM, wantEP: token, wantKeys: false,
		},
		{
			name:     "fcm token at the size ceiling",
			req:      pushSubscribeReq{Kind: "fcm", Token: strings.Repeat("t", maxFCMTokenBytes)},
			wantKind: kindFCM, wantEP: strings.Repeat("t", maxFCMTokenBytes), wantKeys: false,
		},
		{
			name:    "fcm without a token",
			req:     pushSubscribeReq{Kind: "fcm"},
			wantErr: `token is required for kind="fcm"`,
		},
		{
			name:    "fcm with an empty token",
			req:     pushSubscribeReq{Kind: "fcm", Token: ""},
			wantErr: `token is required for kind="fcm"`,
		},
		{
			name:    "fcm token one byte over the ceiling",
			req:     pushSubscribeReq{Kind: "fcm", Token: strings.Repeat("t", maxFCMTokenBytes+1)},
			wantErr: "token is too large",
		},
		{
			name:    "fcm must not carry p256dh",
			req:     pushSubscribeReq{Kind: "fcm", Token: token, P256dh: p256dh},
			wantErr: "must not carry p256dh or auth",
		},
		{
			name:    "fcm must not carry auth",
			req:     pushSubscribeReq{Kind: "fcm", Token: token, Auth: auth},
			wantErr: "must not carry p256dh or auth",
		},
		{
			name:    "fcm must not carry an endpoint",
			req:     pushSubscribeReq{Kind: "fcm", Token: token, Endpoint: endpoint},
			wantErr: `carries the registration token in "token"`,
		},

		// --- unknown channels ---
		{
			name:    "unknown kind",
			req:     pushSubscribeReq{Kind: "apns", Token: token},
			wantErr: `kind must be "webpush" or "fcm"`,
		},
		{
			name:    "kind is case-sensitive",
			req:     pushSubscribeReq{Kind: "FCM", Token: token},
			wantErr: `kind must be "webpush" or "fcm"`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := pushSubscriptionParams(tc.req)

			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected an error containing %q, got params %+v", tc.wantErr, got)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error = %q, want it to contain %q", err, tc.wantErr)
				}
				// A rejection must not echo the token or endpoint back: both
				// identify a device and both end up in logs.
				if strings.Contains(err.Error(), token) || strings.Contains(err.Error(), endpoint) {
					t.Errorf("error leaks the device address: %v", err)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Kind != tc.wantKind {
				t.Errorf("kind = %q, want %q", got.Kind, tc.wantKind)
			}
			if got.Endpoint != tc.wantEP {
				t.Errorf("endpoint = %q, want %q", got.Endpoint, tc.wantEP)
			}
			if tc.wantKeys {
				if got.P256dh == nil || *got.P256dh != tc.req.P256dh {
					t.Errorf("p256dh = %v, want %q", got.P256dh, tc.req.P256dh)
				}
				if got.Auth == nil || *got.Auth != tc.req.Auth {
					t.Errorf("auth = %v, want %q", got.Auth, tc.req.Auth)
				}
			} else {
				// An FCM row must store NULLs, not empty strings: the schema's
				// kind-shape CHECK rejects anything else (migration 00008).
				if got.P256dh != nil || got.Auth != nil {
					t.Errorf("p256dh=%v auth=%v, want both NULL for an fcm row", got.P256dh, got.Auth)
				}
			}
		})
	}
}

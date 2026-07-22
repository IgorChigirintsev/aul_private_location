//go:build integration

package auth_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/crypto"
	"github.com/aul-app/aul/server/internal/store"
	"github.com/aul-app/aul/server/internal/testutil"
)

var fastArgon = crypto.Argon2Params{Memory: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32}

func newService(t *testing.T, st *store.Store, opts ...auth.Option) *auth.Service {
	t.Helper()
	cfg := &config.Config{
		SessionPepper: []byte("integration-test-pepper-1234567890"),
		AccessTTL:     15 * time.Minute,
		RefreshTTL:    720 * time.Hour,
	}
	aud := audit.New(st.Querier, true)
	base := []auth.Option{auth.WithArgon2Params(fastArgon)}
	svc, err := auth.NewService(st, aud, cfg, append(base, opts...)...)
	if err != nil {
		t.Fatalf("new service: %v", err)
	}
	return svc
}

func TestAuth_RegisterLoginRefreshReuse(t *testing.T) {
	st := testutil.Store(t)
	svc := newService(t, st)
	ctx := context.Background()

	reg, err := svc.Register(ctx, auth.RegisterInput{
		Email: "alice@example.com", Password: "correct-horse-staple", Platform: "web", IP: "1.1.1.1",
	})
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if reg.AccessToken == "" || reg.RefreshToken == "" {
		t.Fatal("register returned empty tokens")
	}

	// Duplicate email rejected.
	if _, err := svc.Register(ctx, auth.RegisterInput{Email: "ALICE@example.com", Password: "another-pass-here", Platform: "web"}); !errors.Is(err, auth.ErrEmailTaken) {
		t.Fatalf("expected ErrEmailTaken, got %v", err)
	}

	// Wrong password.
	if _, err := svc.Login(ctx, auth.LoginInput{Email: "alice@example.com", Password: "wrong", Platform: "web", IP: "1.1.1.1"}); !errors.Is(err, auth.ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials, got %v", err)
	}

	// Correct login.
	login, err := svc.Login(ctx, auth.LoginInput{Email: "alice@example.com", Password: "correct-horse-staple", Platform: "web", IP: "1.1.1.1"})
	if err != nil {
		t.Fatalf("login: %v", err)
	}

	// Resolve access token.
	uid, did, sid, err := svc.Resolve(ctx, login.AccessToken)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if uid != login.User.ID || did != login.Device.ID || sid != login.Session.ID {
		t.Fatal("resolve returned mismatched identity")
	}

	// Refresh rotates tokens.
	rot, err := svc.Refresh(ctx, login.RefreshToken, "1.1.1.1")
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if rot.RefreshToken == login.RefreshToken {
		t.Fatal("refresh token did not rotate")
	}
	// Old access token still valid until expiry? No — rotation replaces access hash.
	if _, _, _, err := svc.Resolve(ctx, login.AccessToken); !errors.Is(err, auth.ErrUnauthorized) {
		t.Fatalf("old access token should be invalid after rotation, got %v", err)
	}
	// New access token works.
	if _, _, _, err := svc.Resolve(ctx, rot.AccessToken); err != nil {
		t.Fatalf("new access token should work: %v", err)
	}

	// Reuse detection: presenting the OLD refresh token again is theft → revoke.
	if _, err := svc.Refresh(ctx, login.RefreshToken, "9.9.9.9"); !errors.Is(err, auth.ErrRefreshReused) {
		t.Fatalf("expected ErrRefreshReused, got %v", err)
	}
	// The session is now revoked: the rotated refresh no longer works.
	if _, err := svc.Refresh(ctx, rot.RefreshToken, "1.1.1.1"); err == nil {
		t.Fatal("rotated refresh should be invalid after reuse-triggered revocation")
	}
}

func TestAuth_ConcurrentRefreshReuseDetected(t *testing.T) {
	st := testutil.Store(t)
	svc := newService(t, st)
	ctx := context.Background()

	reg, err := svc.Register(ctx, auth.RegisterInput{Email: "dave@example.com", Password: "daves-passphrase", Platform: "web", IP: "4.4.4.4"})
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	// Fire several concurrent refreshes of the SAME token. The compare-and-swap
	// rotation must let at most one win and flag the rest as reuse.
	const n = 6
	var wg sync.WaitGroup
	results := make([]*auth.Result, n)
	errs := make([]error, n)
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func(i int) {
			defer wg.Done()
			results[i], errs[i] = svc.Refresh(ctx, reg.RefreshToken, "4.4.4.4")
		}(i)
	}
	wg.Wait()

	successes, reuses := 0, 0
	for i := 0; i < n; i++ {
		switch {
		case errs[i] == nil:
			successes++
		case errors.Is(errs[i], auth.ErrRefreshReused):
			reuses++
		}
	}
	if successes > 1 {
		t.Fatalf("more than one concurrent refresh succeeded (%d): token double-spent", successes)
	}
	if reuses == 0 {
		t.Fatal("expected reuse detection to fire on a concurrent double-spend")
	}
	// The session is revoked once reuse is detected: no issued token still works.
	for i := 0; i < n; i++ {
		if results[i] != nil {
			if _, err := svc.Refresh(ctx, results[i].RefreshToken, "4.4.4.4"); err == nil {
				t.Fatal("a token from a reuse-flagged session should be revoked")
			}
		}
	}
}

func TestAuth_Lockout(t *testing.T) {
	st := testutil.Store(t)
	svc := newService(t, st, auth.WithLockout(auth.LockoutPolicy{
		Window: 15 * time.Minute, EmailThreshold: 3, IPThreshold: 100,
		BaseBackoff: 30 * time.Second, MaxBackoff: 5 * time.Minute,
	}))
	ctx := context.Background()

	if _, err := svc.Register(ctx, auth.RegisterInput{Email: "bob@example.com", Password: "the-right-password", Platform: "web", IP: "2.2.2.2"}); err != nil {
		t.Fatalf("register: %v", err)
	}
	// Three failures.
	for i := 0; i < 3; i++ {
		if _, err := svc.Login(ctx, auth.LoginInput{Email: "bob@example.com", Password: "nope", Platform: "web", IP: "2.2.2.2"}); !errors.Is(err, auth.ErrInvalidCredentials) {
			t.Fatalf("attempt %d: expected invalid creds, got %v", i, err)
		}
	}
	// Even the CORRECT password is now locked out.
	_, err := svc.Login(ctx, auth.LoginInput{Email: "bob@example.com", Password: "the-right-password", Platform: "web", IP: "2.2.2.2"})
	var locked *auth.LockedError
	if !errors.As(err, &locked) {
		t.Fatalf("expected LockedError, got %v", err)
	}
	if locked.RetryAfter <= 0 {
		t.Fatal("lock should carry a positive Retry-After")
	}
}

func TestAuth_RevokeDevice(t *testing.T) {
	st := testutil.Store(t)
	svc := newService(t, st)
	ctx := context.Background()

	reg, err := svc.Register(ctx, auth.RegisterInput{Email: "carol@example.com", Password: "carols-passphrase", Platform: "android", IP: "3.3.3.3"})
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := svc.RevokeDevice(ctx, reg.User.ID, reg.Device.ID, "3.3.3.3"); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, _, _, err := svc.Resolve(ctx, reg.AccessToken); !errors.Is(err, auth.ErrUnauthorized) {
		t.Fatalf("access token should be invalid after device revoke, got %v", err)
	}
}

package auth

import (
	"context"
	"time"

	"github.com/aul-app/aul/server/internal/store"
)

// LockoutPolicy configures persistent, DB-backed brute-force protection. It
// complements the in-memory per-IP rate limiter and survives restarts.
type LockoutPolicy struct {
	Window         time.Duration // sliding window for counting failures
	EmailThreshold int           // failures per email before lock
	IPThreshold    int           // failures per IP before lock (credential spraying)
	BaseBackoff    time.Duration // first lock duration hint
	MaxBackoff     time.Duration // cap
}

// DefaultLockout: after 5 failed logins for an account within 15 minutes the
// account is temporarily locked with an escalating Retry-After; a single IP
// failing 50 times in the window is also locked.
var DefaultLockout = LockoutPolicy{
	Window:         15 * time.Minute,
	EmailThreshold: 5,
	IPThreshold:    50,
	BaseBackoff:    30 * time.Second,
	MaxBackoff:     15 * time.Minute,
}

// LockStatus reports whether an identity is currently locked out.
type LockStatus struct {
	Locked     bool
	RetryAfter time.Duration
	Reason     string
}

func (p LockoutPolicy) backoff(over int) time.Duration {
	if over < 1 {
		over = 1
	}
	if over > 20 { // guard shift overflow
		return p.MaxBackoff
	}
	d := p.BaseBackoff << (over - 1)
	if d > p.MaxBackoff || d <= 0 {
		return p.MaxBackoff
	}
	return d
}

// checkLockout counts recent failures for the email and IP and returns a lock
// status. It reads only; the actual attempt is recorded separately.
func (s *Service) checkLockout(ctx context.Context, email, ip string) (LockStatus, error) {
	windowSecs := s.lockout.Window.Seconds()

	emailFails, err := s.store.CountRecentFailuresByEmail(ctx, store.CountRecentFailuresByEmailParams{
		Email:      strPtr(email),
		WindowSecs: windowSecs,
	})
	if err != nil {
		return LockStatus{}, err
	}
	if int(emailFails) >= s.lockout.EmailThreshold {
		over := int(emailFails) - s.lockout.EmailThreshold + 1
		return LockStatus{Locked: true, RetryAfter: s.lockout.backoff(over), Reason: "too many failed attempts for this account"}, nil
	}

	if ip != "" {
		ipFails, err := s.store.CountRecentFailuresByIP(ctx, store.CountRecentFailuresByIPParams{
			Ip:         strPtr(ip),
			WindowSecs: windowSecs,
		})
		if err != nil {
			return LockStatus{}, err
		}
		if int(ipFails) >= s.lockout.IPThreshold {
			over := int(ipFails) - s.lockout.IPThreshold + 1
			return LockStatus{Locked: true, RetryAfter: s.lockout.backoff(over), Reason: "too many failed attempts from this network"}, nil
		}
	}
	return LockStatus{}, nil
}

func (s *Service) recordAttempt(ctx context.Context, email, ip string, success bool) {
	// Only persist the source IP when IP logging is enabled, so the email↔IP
	// mapping is not retained when the operator opted out of IP logging.
	if !s.storeIP {
		ip = ""
	}
	// Detach so recording survives a cancelled request.
	bg := context.WithoutCancel(ctx)
	_ = s.store.RecordLoginAttempt(bg, store.RecordLoginAttemptParams{
		Email:   strPtr(email),
		Ip:      strPtrOrNil(ip),
		Success: success,
	})
}

func strPtr(s string) *string { return &s }

func strPtrOrNil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

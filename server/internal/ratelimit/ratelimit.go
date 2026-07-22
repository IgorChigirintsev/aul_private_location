// Package ratelimit provides an in-process, keyed token-bucket limiter used to
// throttle requests per IP, per account, and per device. It is dependency-free
// and sits behind the Limiter interface so a shared (Redis) backend can replace
// it for multi-instance deployments without touching call sites (see D-0008).
package ratelimit

import (
	"context"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Limiter decides whether an event identified by key may proceed now.
type Limiter interface {
	Allow(key string) bool
}

type bucket struct {
	lim      *rate.Limiter
	lastSeen time.Time
}

// KeyedLimiter maintains an independent token bucket per key, evicting buckets
// that have been idle longer than ttl to bound memory.
type KeyedLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    rate.Limit
	burst   int
	ttl     time.Duration
	nowFn   func() time.Time
}

// New constructs a KeyedLimiter with the given steady rate, burst, and idle TTL.
func New(r rate.Limit, burst int, ttl time.Duration) *KeyedLimiter {
	return &KeyedLimiter{
		buckets: make(map[string]*bucket),
		rate:    r,
		burst:   burst,
		ttl:     ttl,
		nowFn:   time.Now,
	}
}

// NewPerMinute allows n events per minute per key (burst n).
func NewPerMinute(n int, ttl time.Duration) *KeyedLimiter {
	return New(rate.Limit(float64(n)/60.0), n, ttl)
}

// NewPerHour allows n events per hour per key (burst n).
func NewPerHour(n int, ttl time.Duration) *KeyedLimiter {
	return New(rate.Limit(float64(n)/3600.0), n, ttl)
}

// Allow reports whether one event for key may proceed, consuming a token.
func (k *KeyedLimiter) Allow(key string) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	now := k.nowFn()
	b, ok := k.buckets[key]
	if !ok {
		b = &bucket{lim: rate.NewLimiter(k.rate, k.burst)}
		k.buckets[key] = b
	}
	b.lastSeen = now
	return b.lim.AllowN(now, 1)
}

// cleanup evicts idle buckets.
func (k *KeyedLimiter) cleanup() {
	k.mu.Lock()
	defer k.mu.Unlock()
	cutoff := k.nowFn().Add(-k.ttl)
	for key, b := range k.buckets {
		if b.lastSeen.Before(cutoff) {
			delete(k.buckets, key)
		}
	}
}

// Len reports the number of live buckets (for tests/metrics).
func (k *KeyedLimiter) Len() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.buckets)
}

// StartJanitor runs periodic eviction until ctx is cancelled.
func (k *KeyedLimiter) StartJanitor(ctx context.Context, every time.Duration) {
	go func() {
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				k.cleanup()
			}
		}
	}()
}

// Noop is a Limiter that always allows (used when limiting is disabled/in tests).
type Noop struct{}

func (Noop) Allow(string) bool { return true }

package ratelimit

import (
	"testing"
	"time"

	"golang.org/x/time/rate"
)

func TestKeyedLimiter_BurstThenDeny(t *testing.T) {
	// 5/min → burst 5, then denials until refill.
	l := NewPerMinute(5, time.Minute)
	allowed := 0
	for i := 0; i < 10; i++ {
		if l.Allow("ip:1.2.3.4") {
			allowed++
		}
	}
	if allowed != 5 {
		t.Fatalf("allowed %d of 10, want 5 (burst)", allowed)
	}
	// A different key has its own bucket.
	if !l.Allow("ip:9.9.9.9") {
		t.Fatal("independent key should be allowed")
	}
}

func TestKeyedLimiter_RefillsOverTime(t *testing.T) {
	l := New(rate.Every(10*time.Millisecond), 1, time.Minute)
	if !l.Allow("k") {
		t.Fatal("first should pass")
	}
	if l.Allow("k") {
		t.Fatal("second immediate should be denied")
	}
	time.Sleep(15 * time.Millisecond)
	if !l.Allow("k") {
		t.Fatal("should refill after interval")
	}
}

func TestKeyedLimiter_Eviction(t *testing.T) {
	now := time.Now()
	l := NewPerMinute(5, 50*time.Millisecond)
	l.nowFn = func() time.Time { return now }
	l.Allow("a")
	l.Allow("b")
	if l.Len() != 2 {
		t.Fatalf("expected 2 buckets, got %d", l.Len())
	}
	now = now.Add(time.Second) // advance past TTL
	l.cleanup()
	if l.Len() != 0 {
		t.Fatalf("expected buckets evicted, got %d", l.Len())
	}
}

func TestNoop(t *testing.T) {
	var l Limiter = Noop{}
	for i := 0; i < 1000; i++ {
		if !l.Allow("x") {
			t.Fatal("noop should always allow")
		}
	}
}

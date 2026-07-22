package realtime

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
)

func drain(t *testing.T, c *Client, timeout time.Duration) *Event {
	t.Helper()
	select {
	case frame, ok := <-c.Send():
		if !ok {
			return nil
		}
		var ev Event
		if err := json.Unmarshal(frame, &ev); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		return &ev
	case <-time.After(timeout):
		return nil
	}
}

func TestHub_FanoutToSubscribersOnly(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := NewHub()
	go h.Run(ctx)

	circleA := uuid.New()
	circleB := uuid.New()

	subA := NewClient(uuid.New(), []uuid.UUID{circleA}, 8)
	subB := NewClient(uuid.New(), []uuid.UUID{circleB}, 8)
	h.Register(subA)
	h.Register(subB)

	h.Publish(Event{Type: EventPing, CircleID: circleA, Payload: json.RawMessage(`{"x":1}`)})

	if ev := drain(t, subA, time.Second); ev == nil || ev.Type != EventPing || ev.CircleID != circleA {
		t.Fatalf("subA should have received the circleA ping, got %+v", ev)
	}
	if ev := drain(t, subB, 200*time.Millisecond); ev != nil {
		t.Fatalf("subB should NOT receive a circleA ping, got %+v", ev)
	}
}

func TestHub_UnregisterStopsDelivery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := NewHub()
	go h.Run(ctx)

	circle := uuid.New()
	c := NewClient(uuid.New(), []uuid.UUID{circle}, 8)
	h.Register(c)
	h.Unregister(c)
	// After unregister the send channel is closed.
	if _, ok := <-c.Send(); ok {
		t.Fatal("expected closed send channel after unregister")
	}

	// Publishing now should not panic and no one receives.
	h.Publish(Event{Type: EventPing, CircleID: circle})
}

func TestHub_EvictUserStopsDelivery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := NewHub()
	go h.Run(ctx)

	circle := uuid.New()
	removed := uuid.New()
	stays := uuid.New()
	cRemoved := NewClient(removed, []uuid.UUID{circle}, 8)
	cStays := NewClient(stays, []uuid.UUID{circle}, 8)
	h.Register(cRemoved)
	h.Register(cStays)

	// Evict the removed user from the circle; expect an "unsubscribed" frame.
	h.EvictUser(circle, removed)
	if ev := drainRaw(t, cRemoved, time.Second); ev == nil || ev["type"] != "unsubscribed" {
		t.Fatalf("removed client should receive unsubscribed frame, got %v", ev)
	}

	// A new circle event must reach the remaining member but NOT the removed one.
	h.Publish(Event{Type: EventPing, CircleID: circle, Payload: json.RawMessage(`{"x":1}`)})
	if ev := drain(t, cStays, time.Second); ev == nil || ev.Type != EventPing {
		t.Fatalf("remaining member should still receive events, got %v", ev)
	}
	if ev := drain(t, cRemoved, 200*time.Millisecond); ev != nil {
		t.Fatalf("evicted member must not receive further events, got %+v", ev)
	}
}

func drainRaw(t *testing.T, c *Client, timeout time.Duration) map[string]any {
	t.Helper()
	select {
	case frame, ok := <-c.Send():
		if !ok {
			return nil
		}
		var m map[string]any
		if err := json.Unmarshal(frame, &m); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		return m
	case <-time.After(timeout):
		return nil
	}
}

func TestHub_AdmissionCaps(t *testing.T) {
	h := NewHub()
	h.SetConnLimits(2, 3) // 2 per user, 3 total
	u1, u2, u3 := uuid.New(), uuid.New(), uuid.New()

	if !h.Admit(u1) {
		t.Fatal("first connection for u1 should be admitted")
	}
	if !h.Admit(u1) {
		t.Fatal("second connection for u1 should be admitted")
	}
	if h.Admit(u1) {
		t.Fatal("third connection for u1 should be rejected (per-user cap)")
	}
	if !h.Admit(u2) {
		t.Fatal("u2 first connection should be admitted (total=3)")
	}
	if h.Admit(u3) {
		t.Fatal("global cap of 3 reached; u3 should be rejected")
	}
	h.Release(u1) // frees one global + one u1 slot
	if !h.Admit(u3) {
		t.Fatal("after a release, u3 should now be admitted")
	}
}

func TestHub_SlowClientDropped(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := NewHub()
	go h.Run(ctx)

	circle := uuid.New()
	// Buffer of 1: the second undrained publish should drop the client.
	c := NewClient(uuid.New(), []uuid.UUID{circle}, 1)
	h.Register(c)

	for i := 0; i < 5; i++ {
		h.Publish(Event{Type: EventPing, CircleID: circle})
	}
	// Give the hub time to process and drop.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if h.Snapshot().Clients == 0 {
			return // dropped as expected
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("expected slow client to be dropped")
}

func TestHub_ShutdownClosesClients(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	h := NewHub()
	go h.Run(ctx)
	c := NewClient(uuid.New(), []uuid.UUID{uuid.New()}, 4)
	h.Register(c)
	// Let registration land.
	time.Sleep(20 * time.Millisecond)
	cancel()
	// The send channel must close on shutdown (drain any buffered frames first).
	deadline := time.After(time.Second)
	for {
		select {
		case _, ok := <-c.Send():
			if !ok {
				return // closed as expected
			}
		case <-deadline:
			t.Fatal("expected send channel to close on shutdown")
		}
	}
}

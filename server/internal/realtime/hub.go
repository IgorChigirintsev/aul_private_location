// Package realtime implements the in-process WebSocket hub. Handlers publish an
// event after committing to the database; the hub fans it out to every client
// subscribed to that circle. Payloads are opaque ciphertext blobs — the hub
// never inspects them. Slow clients are dropped rather than blocking the hub
// (bounded memory). Multi-instance fan-out (Postgres LISTEN/NOTIFY) is future
// work (see DECISIONS D-0009).
package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"

	"github.com/google/uuid"
)

// Default connection ceilings (overridable via SetConnLimits).
const (
	defaultMaxConnsPerUser = 10
	defaultMaxConnsTotal   = 10000
)

// EventType enumerates realtime event kinds.
type EventType string

const (
	EventPing          EventType = "ping"
	EventSOS           EventType = "sos"
	EventSOSResolved   EventType = "sos_resolved"
	EventPlaceUpdated  EventType = "place_updated"
	EventKeyEnvelope   EventType = "key_envelope"
	EventPrecisionMode EventType = "precision_mode"
	EventMemberChanged EventType = "member_changed"
)

// Event is the wire message pushed to subscribed clients.
type Event struct {
	Type     EventType       `json:"type"`
	CircleID uuid.UUID       `json:"circle_id"`
	Payload  json.RawMessage `json:"payload,omitempty"`
}

// Client is one WebSocket connection's hub-side handle. The send channel is
// bounded; the transport goroutine drains it to the socket.
type Client struct {
	ID      uuid.UUID
	UserID  uuid.UUID
	circles map[uuid.UUID]struct{}
	send    chan []byte
}

// NewClient builds a client subscribed to the given circles.
func NewClient(userID uuid.UUID, circles []uuid.UUID, buffer int) *Client {
	set := make(map[uuid.UUID]struct{}, len(circles))
	for _, c := range circles {
		set[c] = struct{}{}
	}
	if buffer <= 0 {
		buffer = 64
	}
	return &Client{
		ID:      uuid.New(),
		UserID:  userID,
		circles: set,
		send:    make(chan []byte, buffer),
	}
}

// Send is the channel the transport writer reads to push frames to the socket.
// It is closed by the hub when the client is unregistered.
func (c *Client) Send() <-chan []byte { return c.send }

// Subscribed reports whether the client listens to circleID.
func (c *Client) Subscribed(circleID uuid.UUID) bool {
	_, ok := c.circles[circleID]
	return ok
}

// evictReq removes circle subscriptions from live clients on membership change.
type evictReq struct {
	circleID uuid.UUID
	userID   uuid.UUID // ignored when allUsers is true
	allUsers bool
}

// Hub owns all subscription state and runs a single goroutine loop.
type Hub struct {
	register   chan *Client
	unregister chan *Client
	broadcast  chan Event
	evict      chan evictReq
	statsReq   chan chan Stats

	clients map[*Client]struct{}
	circles map[uuid.UUID]map[*Client]struct{}

	// Admission control (guards connection counts before the socket upgrade).
	connMu     sync.Mutex
	totalConns int
	perUser    map[uuid.UUID]int
	maxPerUser int
	maxTotal   int
}

// Stats is a snapshot for metrics.
type Stats struct {
	Clients int
	Circles int
}

// NewHub constructs a Hub. Call Run to start it.
func NewHub() *Hub {
	return &Hub{
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan Event, 256),
		evict:      make(chan evictReq, 64),
		statsReq:   make(chan chan Stats),
		clients:    make(map[*Client]struct{}),
		circles:    make(map[uuid.UUID]map[*Client]struct{}),
		perUser:    make(map[uuid.UUID]int),
		maxPerUser: defaultMaxConnsPerUser,
		maxTotal:   defaultMaxConnsTotal,
	}
}

// SetConnLimits overrides the per-user and global connection ceilings. A value
// <= 0 leaves that ceiling unchanged.
func (h *Hub) SetConnLimits(perUser, total int) {
	h.connMu.Lock()
	defer h.connMu.Unlock()
	if perUser > 0 {
		h.maxPerUser = perUser
	}
	if total > 0 {
		h.maxTotal = total
	}
}

// Admit reserves a connection slot for userID before the socket upgrade,
// enforcing per-user and global ceilings. Pair every true return with exactly
// one Release. Returns false when a ceiling is reached.
func (h *Hub) Admit(userID uuid.UUID) bool {
	h.connMu.Lock()
	defer h.connMu.Unlock()
	if h.totalConns >= h.maxTotal || h.perUser[userID] >= h.maxPerUser {
		return false
	}
	h.totalConns++
	h.perUser[userID]++
	return true
}

// Release frees a slot reserved by Admit.
func (h *Hub) Release(userID uuid.UUID) {
	h.connMu.Lock()
	defer h.connMu.Unlock()
	if h.totalConns > 0 {
		h.totalConns--
	}
	if h.perUser[userID] > 0 {
		h.perUser[userID]--
		if h.perUser[userID] == 0 {
			delete(h.perUser, userID)
		}
	}
}

// Run processes hub events until ctx is cancelled. On shutdown it closes all
// client send channels so transport goroutines exit.
func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			for c := range h.clients {
				close(c.send)
			}
			h.clients = map[*Client]struct{}{}
			h.circles = map[uuid.UUID]map[*Client]struct{}{}
			return
		case c := <-h.register:
			h.addClient(c)
		case c := <-h.unregister:
			h.removeClient(c)
		case ev := <-h.broadcast:
			h.dispatch(ev)
		case req := <-h.evict:
			h.doEvict(req)
		case reply := <-h.statsReq:
			reply <- Stats{Clients: len(h.clients), Circles: len(h.circles)}
		}
	}
}

func (h *Hub) addClient(c *Client) {
	h.clients[c] = struct{}{}
	for circleID := range c.circles {
		set := h.circles[circleID]
		if set == nil {
			set = make(map[*Client]struct{})
			h.circles[circleID] = set
		}
		set[c] = struct{}{}
	}
}

func (h *Hub) removeClient(c *Client) {
	if _, ok := h.clients[c]; !ok {
		return
	}
	delete(h.clients, c)
	for circleID := range c.circles {
		if set := h.circles[circleID]; set != nil {
			delete(set, c)
			if len(set) == 0 {
				delete(h.circles, circleID)
			}
		}
	}
	close(c.send)
}

func (h *Hub) dispatch(ev Event) {
	set := h.circles[ev.CircleID]
	if len(set) == 0 {
		return
	}
	frame, err := json.Marshal(ev)
	if err != nil {
		slog.Error("realtime: marshal event", "err", err)
		return
	}
	for c := range set {
		select {
		case c.send <- frame:
		default:
			// Slow consumer: drop it rather than block the hub. The client's
			// polling fallback will reconcile missed events.
			slog.Warn("realtime: dropping slow client", "client", c.ID)
			h.removeClient(c)
		}
	}
}

// doEvict removes circleID from the subscriptions of matching clients (a
// specific user, or all users when req.allUsers). The client stays connected but
// stops receiving that circle's events immediately, and is sent an
// "unsubscribed" control frame. This enforces the instant-leave / removal
// privacy guarantee: a removed member's live socket must stop seeing the family.
func (h *Hub) doEvict(req evictReq) {
	set := h.circles[req.circleID]
	if len(set) == 0 {
		return
	}
	frame, _ := json.Marshal(map[string]any{"type": "unsubscribed", "circle_id": req.circleID})
	for c := range set {
		if !req.allUsers && c.UserID != req.userID {
			continue
		}
		delete(c.circles, req.circleID)
		delete(set, c)
		select {
		case c.send <- frame:
		default:
		}
	}
	if len(set) == 0 {
		delete(h.circles, req.circleID)
	}
}

// EvictUser stops one user's live sockets from receiving a circle's events
// (call after removing them / their leaving the circle).
func (h *Hub) EvictUser(circleID, userID uuid.UUID) {
	defer func() { _ = recover() }()
	select {
	case h.evict <- evictReq{circleID: circleID, userID: userID}:
	default:
	}
}

// EvictCircle stops all live sockets from receiving a circle's events (call
// after the circle is deleted).
func (h *Hub) EvictCircle(circleID uuid.UUID) {
	defer func() { _ = recover() }()
	select {
	case h.evict <- evictReq{circleID: circleID, allUsers: true}:
	default:
	}
}

// Register adds a client (blocks until the hub loop accepts it).
func (h *Hub) Register(c *Client) { h.register <- c }

// Unregister removes a client. Safe to call once per client.
func (h *Hub) Unregister(c *Client) {
	// Non-blocking best-effort; if the hub is shutting down, Run already closed.
	defer func() { _ = recover() }()
	h.unregister <- c
}

// Publish fans an event out to subscribers of its circle. Non-blocking-ish: it
// enqueues to the hub's broadcast buffer.
func (h *Hub) Publish(ev Event) {
	defer func() { _ = recover() }()
	select {
	case h.broadcast <- ev:
	default:
		slog.Warn("realtime: broadcast buffer full, dropping event", "type", ev.Type, "circle", ev.CircleID)
	}
}

// Snapshot returns current hub stats.
func (h *Hub) Snapshot() Stats {
	reply := make(chan Stats, 1)
	defer func() { _ = recover() }()
	h.statsReq <- reply
	return <-reply
}

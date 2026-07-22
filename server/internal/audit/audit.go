// Package audit writes append-only security events (logins, key rotations,
// invite issuance, membership changes). Writes are best-effort: a failure is
// logged but never fails the user's request. Coordinates are never recorded
// here. IP is stored only when IP logging is enabled, and is later nulled by the
// retention job.
package audit

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/store"
)

// Standard event names.
const (
	EventRegister        = "register"
	EventLogin           = "login"
	EventLoginFailed     = "login_failed"
	EventLogout          = "logout"
	EventRefresh         = "token_refresh"
	EventRefreshReuse    = "refresh_reuse_detected"
	EventSessionRevoked  = "session_revoked"
	EventDeviceRemoved   = "device_removed"
	EventCircleCreated   = "circle_created"
	EventInviteCreated   = "invite_created"
	EventInviteAccepted  = "invite_accepted"
	EventMemberRemoved   = "member_removed"
	EventMemberLeft      = "member_left"
	EventKeyRotation     = "key_rotation"
	EventKeyEnvelopeSent = "key_envelope_sent"
	EventSOSCreated      = "sos_created"
	EventSOSResolved     = "sos_resolved"
	EventPasswordChanged = "password_changed"
)

// Logger writes audit events.
type Logger struct {
	q       store.Querier
	storeIP bool
}

// New builds a Logger. storeIP is typically config.IPLogRetentionDays > 0. It
// takes the backend-agnostic store.Querier so it works on both the pgx and the
// SQLite store.
func New(q store.Querier, storeIP bool) *Logger {
	return &Logger{q: q, storeIP: storeIP}
}

// Event describes a single audit record. Nil ids are omitted.
type Event struct {
	Name     string
	UserID   *uuid.UUID
	DeviceID *uuid.UUID
	CircleID *uuid.UUID
	IP       string
	Detail   map[string]any
}

// Log writes e best-effort. It uses a background context so audit persistence
// is not cancelled when the request context is done.
func (l *Logger) Log(ctx context.Context, e Event) {
	if l == nil || l.q == nil {
		return
	}
	var detail []byte
	if len(e.Detail) > 0 {
		if b, err := json.Marshal(e.Detail); err == nil {
			detail = b
		}
	}
	var ip *string
	if l.storeIP && e.IP != "" {
		v := e.IP
		ip = &v
	}
	// Detach from the request lifecycle so a cancelled request still audits.
	bg := context.WithoutCancel(ctx)
	if err := l.q.WriteAudit(bg, store.WriteAuditParams{
		Event:         e.Name,
		ActorUserID:   e.UserID,
		ActorDeviceID: e.DeviceID,
		CircleID:      e.CircleID,
		Ip:            ip,
		Detail:        detail,
	}); err != nil {
		slog.Error("audit: write failed", "event", e.Name, "err", err)
	}
}

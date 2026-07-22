// Package retention runs the server's background maintenance: pre-creating ping
// partitions, dropping partitions past the retention horizon, pruning stale
// pings, pruning login-attempt rows, nulling old audit-log IPs, and clearing
// expired sessions. Deleting whole partitions is O(1) and avoids table bloat
// (see DECISIONS D-0005/D-0012).
//
// Pings are held for PING_RETENTION_HOURS (default 6), not for the circle's
// retention_days: since D-0054 deleted history and the movement/digest stats,
// nothing reads a ping other than the newest one per device, so older sealed
// positions are metadata risk with no product value. The newest ping per
// (circle_id, device_id) is exempt at every age — a phone that has been off for
// days must still show its last known pin. retention_days keeps its meaning for
// place tombstones and resolved SOS, and still bounds pings for circles that set
// it below the ping window: whichever rule deletes more, deletes.
//
// One bound sits above all of this: dropOldPartitions drops whole months past
// MAX_RETENTION_DAYS (default 90), taking even a newest-per-device ping with
// them. That is the intended O(1) backstop — a device silent for three months is
// not on anyone's map in any meaningful sense.
package retention

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"time"

	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/store"
)

// partitionNameRe matches the partitions this server creates: pings_pYYYY_MM.
var partitionNameRe = regexp.MustCompile(`^pings_p(\d{4})_(\d{2})$`)

// shareGraceHours is how long a dead live-share session (expired or revoked)
// lingers before deletion. Its own lifetime is at most an hour, so a day of
// grace is generous cover for clock skew and a client that wants to render a
// "this link ended" state, while still bounding the table.
const shareGraceHours = 24

// Worker performs periodic maintenance.
type Worker struct {
	store              *store.Store
	maxRetentionDays   int
	pingRetentionHours int
	ipLogDays          int
	interval           time.Duration
	now                func() time.Time
}

// defaultPingRetentionHours mirrors config's PING_RETENTION_HOURS default. It
// only applies to a Worker built from a zero-valued Config (tests); config.Load
// always supplies a validated 1..168.
const defaultPingRetentionHours = 6

// New builds a retention Worker from config.
func New(st *store.Store, cfg *config.Config) *Worker {
	pingHours := cfg.PingRetentionHours
	if pingHours <= 0 {
		pingHours = defaultPingRetentionHours
	}
	return &Worker{
		store:              st,
		maxRetentionDays:   cfg.MaxRetentionDays,
		pingRetentionHours: pingHours,
		ipLogDays:          cfg.IPLogRetentionDays,
		interval:           time.Hour,
		now:                time.Now,
	}
}

// SetInterval overrides the run interval (tests).
func (w *Worker) SetInterval(d time.Duration) { w.interval = d }

// SetClock overrides the time source (tests).
func (w *Worker) SetClock(f func() time.Time) { w.now = f }

// Run executes maintenance immediately, then on each interval until ctx ends.
func (w *Worker) Run(ctx context.Context) {
	if err := w.RunOnce(ctx); err != nil {
		slog.Error("retention: initial run failed", "err", err)
	}
	t := time.NewTicker(w.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := w.RunOnce(ctx); err != nil {
				slog.Error("retention: run failed", "err", err)
			}
		}
	}
}

// RunOnce performs a single maintenance pass. Errors from individual steps are
// logged and do not abort the remaining steps.
func (w *Worker) RunOnce(ctx context.Context) error {
	now := w.now()

	// 1 & 2. Month-past-MAX_RETENTION backstop. On Postgres this is the O(1)
	// partition machinery (pre-create upcoming months, DROP whole expired ones).
	// SQLite has no partitioning, so the same bound becomes a DELETE-by-timestamp
	// of everything older than the horizon — including a device's newest ping,
	// exactly as a partition DROP would have taken it.
	horizon := now.AddDate(0, 0, -w.maxRetentionDays)
	if w.store.IsSQLite() {
		if dropped, err := w.store.PruneAllPingsBefore(ctx, horizon); err != nil {
			slog.Error("retention: prune pings past max horizon", "err", err)
		} else if dropped > 0 {
			slog.Info("retention: pruned pings past max horizon", "rows", dropped)
		}
	} else {
		// Ensure upcoming partitions exist.
		if err := w.store.EnsurePingPartitions(ctx, store.EnsurePingPartitionsParams{
			FromTs: now.AddDate(0, -1, 0),
			ToTs:   now.AddDate(0, 2, 0),
		}); err != nil {
			slog.Error("retention: ensure partitions", "err", err)
		}
		// Drop partitions entirely older than the max retention horizon.
		if dropped, err := w.dropOldPartitions(ctx, horizon); err != nil {
			slog.Error("retention: drop partitions", "err", err)
		} else if dropped > 0 {
			slog.Info("retention: dropped ping partitions", "count", dropped)
		}
	}

	// 3. Drop stale pings: everything older than the ping window except each
	// device's newest, which is kept however old it is (see PruneStalePings).
	if n, err := w.store.PruneStalePings(ctx, int32(w.pingRetentionHours)); err != nil { // #nosec G115 -- config-validated to 1..168
		slog.Error("retention: prune stale pings", "err", err)
	} else if n > 0 {
		slog.Info("retention: pruned stale pings", "rows", n, "keep_hours", w.pingRetentionHours)
	}

	// 4. Per-circle delete for circles whose retention_days is shorter than the
	// ping window; whichever rule deletes more, deletes.
	if err := w.deleteExpiredPings(ctx); err != nil {
		slog.Error("retention: per-circle delete", "err", err)
	}

	// 5. Prune login attempts aggressively: only the recent lockout window
	// (minutes) is functionally needed, so a 1-day cap bounds the email↔IP
	// metadata far below the IP-log retention window.
	if n, err := w.store.PruneLoginAttempts(ctx, 1); err != nil {
		slog.Error("retention: prune login attempts", "err", err)
	} else if n > 0 {
		slog.Debug("retention: pruned login attempts", "rows", n)
	}

	// 6. Null audit-log IPs older than the IP retention window (0 = keep none;
	// treat as immediate scrub of any IP older than today).
	ipDays := w.ipLogDays
	if n, err := w.store.PruneAuditIPs(ctx, int32(ipDays)); err != nil { // #nosec G115 -- config-validated to 0..3650
		slog.Error("retention: scrub audit ips", "err", err)
	} else if n > 0 {
		slog.Debug("retention: scrubbed audit ips", "rows", n)
	}

	// 7. Remove expired/revoked sessions.
	if n, err := w.store.DeleteExpiredSessions(ctx); err != nil {
		slog.Error("retention: delete expired sessions", "err", err)
	} else if n > 0 {
		slog.Debug("retention: deleted sessions", "rows", n)
	}

	// 8. Prune consumed / stale key envelopes (privacy + storage bound).
	if n, err := w.store.PruneKeyEnvelopes(ctx); err != nil {
		slog.Error("retention: prune key envelopes", "err", err)
	} else if n > 0 {
		slog.Debug("retention: pruned key envelopes", "rows", n)
	}

	// 9. Prune resolved SOS events and soft-deleted place tombstones past the
	// max retention horizon (both are opaque ciphertext; this bounds their
	// growth and scrubs stale metadata). Active SOS and live places are kept.
	horizon = now.AddDate(0, 0, -w.maxRetentionDays)
	if n, err := w.store.PruneResolvedSOS(ctx, &horizon); err != nil {
		slog.Error("retention: prune resolved sos", "err", err)
	} else if n > 0 {
		slog.Debug("retention: pruned resolved sos", "rows", n)
	}
	if n, err := w.store.PrunePlaceTombstones(ctx, horizon); err != nil {
		slog.Error("retention: prune place tombstones", "err", err)
	} else if n > 0 {
		slog.Debug("retention: pruned place tombstones", "rows", n)
	}

	// 10. Remove dead live-share sessions past the grace period; the cascade takes
	// their single sealed position with them. Shares are short-lived and can be
	// minted freely, so without this the table would grow forever.
	if n, err := w.store.PruneShareSessions(ctx, shareGraceHours); err != nil {
		slog.Error("retention: prune share sessions", "err", err)
	} else if n > 0 {
		slog.Debug("retention: pruned share sessions", "rows", n)
	}

	return nil
}

func (w *Worker) deleteExpiredPings(ctx context.Context) error {
	circles, err := w.store.AllCircleRetention(ctx)
	if err != nil {
		return err
	}
	var total int64
	for _, c := range circles {
		n, err := w.store.DeleteExpiredPingsForCircle(ctx, store.DeleteExpiredPingsForCircleParams{
			CircleID:      c.ID,
			RetentionDays: c.RetentionDays,
		})
		if err != nil {
			slog.Error("retention: delete circle pings", "circle", c.ID, "err", err)
			continue
		}
		total += n
	}
	if total > 0 {
		slog.Info("retention: deleted expired pings", "rows", total)
	}
	return nil
}

// dropOldPartitions drops every pings partition whose entire month is strictly
// before horizon. Partition names come from pg_catalog and are re-validated
// against a strict regex before being used in DDL.
func (w *Worker) dropOldPartitions(ctx context.Context, horizon time.Time) (int, error) {
	rows, err := w.store.Pool().Query(ctx, `
		SELECT c.relname
		FROM pg_inherits i
		JOIN pg_class c ON c.oid = i.inhrelid
		JOIN pg_class p ON p.oid = i.inhparent
		WHERE p.relname = 'pings'`)
	if err != nil {
		return 0, err
	}
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			return 0, err
		}
		names = append(names, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	dropped := 0
	for _, name := range names {
		m := partitionNameRe.FindStringSubmatch(name)
		if m == nil {
			continue // not one of ours; never touch it
		}
		year, month := atoi(m[1]), atoi(m[2])
		if month < 1 || month > 12 {
			continue
		}
		// Upper bound is the first instant of the following month.
		upper := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.UTC).AddDate(0, 1, 0)
		if !upper.After(horizon) { // upper <= horizon → whole partition is expired
			if _, err := w.store.Pool().Exec(ctx, fmt.Sprintf("DROP TABLE IF EXISTS %s", name)); err != nil {
				slog.Error("retention: drop partition", "partition", name, "err", err)
				continue
			}
			dropped++
		}
	}
	return dropped, nil
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}

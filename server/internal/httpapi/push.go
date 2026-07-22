package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/fcm"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/store"
)

// Web Push fan-out tuning.
const (
	// maxNotifyBytes caps the DECODED sealed blob. The Web Push record is 4 KiB
	// total, so the plaintext we may hand the push service is smaller still —
	// see maxPushPlaintextBytes.
	maxNotifyBytes = 3 << 10 // 3 KiB

	// maxPushPlaintextBytes is the real RFC 8291 ceiling for what we transmit.
	// A 4096-byte aes128gcm record carries a 86-byte content-coding header, a
	// 16-byte GCM tag and a 1-byte padding delimiter, leaving 3993 bytes of
	// plaintext. We relay the blob as base64 (4 chars per 3 bytes), so this
	// binds before maxNotifyBytes does: it admits ~2994 decoded bytes. Checking
	// it up front turns an undeliverable payload into an immediate 400 instead
	// of a silent per-subscription failure at send time.
	maxPushPlaintextBytes = 3993

	pushTTLSeconds    = 600              // how long the push service may queue for an offline device
	pushSendTimeout   = 10 * time.Second // per subscription
	pushFanoutTimeout = 20 * time.Second // whole fan-out; below the 30s request timeout
	pushWorkers       = 8                // bounded concurrency per request
	pushPruneTimeout  = 5 * time.Second  // deleting a dead subscription row
)

// Delivery channels, matching push_subscriptions.kind (migration 00008).
const (
	kindWebPush = "webpush"
	kindFCM     = "fcm"
)

// fcmDataKey is the FCM data field carrying the sealed blob. The Android client
// reads message.data["payload_enc"] and decrypts it under K_c — the same base64
// string a Web Push subscriber receives as its payload.
const fcmDataKey = "payload_enc"

type notifyReq struct {
	// PayloadEnc is a base64 blob the client sealed under the circle key K_c.
	// The server never decrypts it and never inspects it: it is relayed verbatim
	// as the Web Push payload, which RFC 8291 then encrypts AGAIN to each
	// subscription's own keys. Two independent layers; the server holds neither.
	PayloadEnc string `json:"payload_enc"`
}

// handleNotify fans a sealed notification blob out to the push subscriptions of
// every other member of the circle who has not muted it, over BOTH channels —
// Web Push for browsers, FCM for Android. It reports counts only — never
// endpoints, never tokens, never plaintext.
//
// Muted recipients are filtered out of the subscription query itself, so they
// are never counted in sent/failed: from the sender's side a muted member simply
// is not a recipient, and the counts do not reveal that anyone muted them.
func (s *Server) handleNotify(w http.ResponseWriter, r *http.Request) {
	// Either channel alone is a working deployment; only with neither is push
	// genuinely unavailable.
	if !s.anyPushEnabled() {
		httpx.WriteError(w, http.StatusServiceUnavailable, httpx.CodeInternal, "push is not configured")
		return
	}
	m, _ := membershipFrom(r.Context())

	var req notifyReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	// Decode only to validate: size and base64-ness. The bytes are discarded —
	// what we send is the caller's base64 string, verbatim.
	if _, err := decodeBlob("payload_enc", req.PayloadEnc, maxNotifyBytes); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if len(req.PayloadEnc) > maxPushPlaintextBytes {
		httpx.BadRequest(w, "payload_enc exceeds the web push payload limit")
		return
	}

	// The query both excludes the sender's own devices and drops recipients who
	// muted this circle or muted the sender — hence one sender id for both.
	subs, err := s.store.ListCirclePushSubscriptions(r.Context(), store.ListCirclePushSubscriptionsParams{
		CircleID: m.CircleID, SenderUserID: m.UserID,
	})
	if err != nil {
		httpx.Internal(w, err)
		return
	}

	sent, failed := s.fanOutPush(r.Context(), s.deliverable(subs), []byte(req.PayloadEnc))
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sent": sent, "failed": failed})
}

// deliverable drops subscriptions whose channel this deployment does not run.
//
// They are not counted as failures: a "failure" should mean a delivery that was
// attempted and did not land, so that failed>0 is worth an operator's attention.
// A token registered against a channel the operator never configured is not a
// failed send — it is a client that ignored /v1/server-info, which already
// advertises vapid_public_key and fcm_enabled precisely so it need not.
func (s *Server) deliverable(subs []store.ListCirclePushSubscriptionsRow) []store.ListCirclePushSubscriptionsRow {
	if s.cfg.PushEnabled() && s.fcmEnabled() {
		return subs // both channels live: everything is deliverable.
	}
	out := make([]store.ListCirclePushSubscriptionsRow, 0, len(subs))
	for _, sub := range subs {
		switch sub.Kind {
		case kindFCM:
			if s.fcmEnabled() {
				out = append(out, sub)
			}
		default:
			if s.cfg.PushEnabled() {
				out = append(out, sub)
			}
		}
	}
	return out
}

// fcmEnabled reports whether the FCM channel can send.
//
// The CLIENT is the source of truth, not config.FCMEnabled(): the client is what
// a send actually requires, so asking the config could answer "enabled" for a
// server that has no client wired and would panic on the first send. main builds
// the client iff the config enables it, which keeps the two in step.
func (s *Server) fcmEnabled() bool { return s.fcm != nil }

// anyPushEnabled reports whether /notify has a channel to fan out over.
func (s *Server) anyPushEnabled() bool { return s.cfg.PushEnabled() || s.fcmEnabled() }

// fanOutPush delivers payload to every subscription with a bounded worker pool
// under a total deadline, so one slow push service cannot stall the request.
// Subscriptions the service reports as gone are pruned.
func (s *Server) fanOutPush(ctx context.Context, subs []store.ListCirclePushSubscriptionsRow, payload []byte) (sent, failed int) {
	if len(subs) == 0 {
		return 0, 0
	}
	ctx, cancel := context.WithTimeout(ctx, pushFanoutTimeout)
	defer cancel()

	// Only successes are counted: everything else — a rejected send, a pruned
	// subscription, or work never queued because the budget ran out — is a
	// failure, so failed is whatever is left over.
	var okCount atomic.Int64
	work := make(chan store.ListCirclePushSubscriptionsRow)

	workers := min(pushWorkers, len(subs))
	var wg sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			defer wg.Done()
			for sub := range work {
				if s.sendPushSafe(ctx, sub, payload) {
					okCount.Add(1)
				}
			}
		}()
	}

feed:
	for _, sub := range subs {
		select {
		case work <- sub:
		case <-ctx.Done():
			// Out of budget: everything still unqueued counts as failed.
			break feed
		}
	}
	close(work)
	wg.Wait()

	sent = int(okCount.Load())
	failed = len(subs) - sent
	return sent, failed
}

// errPushGone marks a subscription the push service says no longer exists.
var errPushGone = errors.New("push subscription gone")

// sendPushSafe reports whether the notification was delivered, containing any
// panic. The subscription's p256dh/auth are attacker-supplied (any user can
// POST /v1/push/subscribe), and these workers run outside the Recoverer
// middleware — so a panic in the crypto path would otherwise crash the whole
// server. One bad subscription may only fail itself.
func (s *Server) sendPushSafe(ctx context.Context, sub store.ListCirclePushSubscriptionsRow, payload []byte) (ok bool) {
	defer func() {
		if p := recover(); p != nil {
			slog.Error("push: send panicked", "err", p)
			ok = false
		}
	}()
	return s.sendPush(ctx, sub, payload) == nil
}

// sendPush delivers one notification over the subscription's own channel. The
// payload is opaque on both: it is the client's sealed blob, relayed verbatim.
func (s *Server) sendPush(ctx context.Context, sub store.ListCirclePushSubscriptionsRow, payload []byte) error {
	if sub.Kind == kindFCM {
		return s.sendFCM(ctx, sub, payload)
	}
	return s.sendWebPush(ctx, sub, payload)
}

// sendFCM delivers one notification to an Android registration token (the row's
// endpoint). The message is DATA-ONLY: the sealed blob rides in message.data,
// never message.notification, so Android hands it to the app — which holds K_c —
// instead of rendering it itself, which would require plaintext. internal/fcm
// makes that structural; this is the caller's half of the same invariant.
func (s *Server) sendFCM(ctx context.Context, sub store.ListCirclePushSubscriptionsRow, payload []byte) error {
	ctx, cancel := context.WithTimeout(ctx, pushSendTimeout)
	defer cancel()

	err := s.fcm.Send(ctx, sub.Endpoint, map[string]string{fcmDataKey: string(payload)}, pushTTLSeconds)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, fcm.ErrUnregistered):
		// Same contract as Web Push 404/410: the registration is dead, so stop
		// storing it.
		s.prunePushSubscription(ctx, sub.ID)
		return errPushGone
	default:
		// The error carries a status, never the token — see internal/fcm.
		slog.Warn("push: fcm send failed", "err", err)
		return err
	}
}

// sendWebPush delivers one notification to a browser subscription. webpush
// encrypts the blob AGAIN to this subscription's keys (RFC 8291) and
// authenticates with our VAPID keypair (RFC 8292).
func (s *Server) sendWebPush(ctx context.Context, sub store.ListCirclePushSubscriptionsRow, payload []byte) error {
	ctx, cancel := context.WithTimeout(ctx, pushSendTimeout)
	defer cancel()

	// The schema permits NULL keys only on fcm rows (migration 00008), so this
	// is unreachable — but the fan-out must not nil-deref its way to a panic if
	// it ever becomes reachable.
	if sub.P256dh == nil || sub.Auth == nil {
		return errors.New("webpush subscription is missing key material")
	}

	resp, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{
		Endpoint: sub.Endpoint,
		Keys:     webpush.Keys{P256dh: *sub.P256dh, Auth: *sub.Auth},
	}, &webpush.Options{
		HTTPClient:      s.pushClient,
		Subscriber:      vapidSubscriber(s.cfg.VAPIDSubject),
		VAPIDPublicKey:  s.cfg.VAPIDPublicKey,
		VAPIDPrivateKey: s.cfg.VAPIDPrivateKey,
		TTL:             pushTTLSeconds,
		Urgency:         webpush.UrgencyNormal,
	})
	if err != nil {
		return err
	}
	defer resp.Body.Close() //nolint:errcheck // response body is drained and ignored

	switch {
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		// Standard contract: the subscription is dead, stop storing it.
		s.prunePushSubscription(ctx, sub.ID)
		return errPushGone
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	default:
		// Log the status only — never the endpoint (it identifies a device).
		slog.Warn("push: send rejected", "status", resp.StatusCode)
		return errors.New("push service returned " + itoa(resp.StatusCode))
	}
}

// prunePushSubscription deletes a subscription whose channel reported it dead —
// Web Push 404/410, FCM NOT_FOUND/UNREGISTERED. Both channels agree on what that
// means, so they share one prune.
//
// The delete runs on a context detached from the fan-out deadline: a
// nearly-expired budget must not leave the dead row behind to be retried on
// every future notify.
func (s *Server) prunePushSubscription(ctx context.Context, id uuid.UUID) {
	pruneCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), pushPruneTimeout)
	defer cancel()
	if err := s.store.DeletePushSubscriptionByID(pruneCtx, id); err != nil {
		slog.Error("push: prune dead subscription", "err", err)
	}
}

// vapidSubscriber adapts VAPID_SUBJECT to webpush-go, which prepends "mailto:"
// to any subscriber that is not an https: URI — so handing it a already-correct
// "mailto:ops@aul.app" would yield "mailto:mailto:ops@aul.app" and a JWT the
// push service rejects. Config keeps the canonical RFC 8292 form; this strips
// the scheme back off so the library re-adds exactly one.
func vapidSubscriber(subject string) string {
	if strings.HasPrefix(subject, "https:") {
		return subject
	}
	return strings.TrimPrefix(subject, "mailto:")
}

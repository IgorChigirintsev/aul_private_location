// Package fcm sends data-only messages through the Firebase Cloud Messaging
// HTTP v1 API. It is the second push channel beside Web Push: Android cannot
// receive Web Push while backgrounded, so a phone registers an FCM
// registration token instead (see internal/httpapi/push.go for the fan-out).
//
// # Data-only, always
//
// Every message this package sends is data-only: it carries `message.data` and
// NEVER `message.notification`. This is an E2EE requirement, not a preference.
// A `notification` message is rendered by the Android system itself, so its
// title and body must be plaintext — the very thing the client sealed under the
// circle key K_c to keep from us and from Google. A data message is handed to
// the app's own code, which holds K_c and can decrypt it there.
//
// The invariant is enforced by construction: the message type below has no
// notification field to set, so no caller can add one by accident. TestSend_*
// asserts it on the wire as well.
//
// # Why not the Firebase Admin SDK
//
// Sending needs exactly two things: an OAuth2 access token minted from the
// service account, and one POST. firebase.google.com/go pulls in the whole
// Firebase surface (auth, firestore, storage, …) and its transitive gRPC/API
// stack for that. This file is the whole client instead — fewer dependencies to
// audit in a codebase whose security posture is the product.
package fcm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const (
	// Scope is the only OAuth2 scope this client needs.
	Scope = "https://www.googleapis.com/auth/firebase.messaging"

	// DefaultBaseURL is the FCM v1 host. Overridable so tests can point at a
	// stub: nothing here may ever talk to real FCM from a test.
	DefaultBaseURL = "https://fcm.googleapis.com"

	// defaultTimeout bounds both a send and an access-token refresh. The caller
	// also passes a per-send context deadline; this is the backstop.
	defaultTimeout = 10 * time.Second

	// maxErrorBodyBytes caps how much of an error response we read before
	// classifying it. FCM's error bodies are small; an unbounded read of a
	// misbehaving endpoint is not something a push worker should risk.
	maxErrorBodyBytes = 64 << 10
)

// ErrUnregistered marks a token FCM says is dead: the app was uninstalled, the
// token was refreshed, or the registration otherwise no longer exists. The
// caller prunes the subscription row, exactly as Web Push 404/410 does.
var ErrUnregistered = errors.New("fcm: token is no longer registered")

// Client sends FCM messages for one Firebase project.
type Client struct {
	projectID string
	baseURL   string
	ts        oauth2.TokenSource
	hc        *http.Client
}

// Option configures a Client.
type Option func(*Client)

// WithBaseURL points the client at a different FCM host (tests use a stub).
func WithBaseURL(u string) Option { return func(c *Client) { c.baseURL = strings.TrimSuffix(u, "/") } }

// WithHTTPClient supplies the transport used for both sends and token refresh.
func WithHTTPClient(hc *http.Client) Option { return func(c *Client) { c.hc = hc } }

// New builds a client from the raw service-account JSON. The project id is
// derived from the credentials, so operators configure the key file and nothing
// else.
//
// ctx bounds the lifetime of the token source, not a single send: the source
// caches the access token and refreshes it in the background as it expires, so
// a send never mints one. ctx must therefore live as long as the server does.
func New(ctx context.Context, credentialsJSON []byte, opts ...Option) (*Client, error) {
	c := &Client{baseURL: DefaultBaseURL, hc: &http.Client{Timeout: defaultTimeout}}
	for _, o := range opts {
		o(c)
	}
	// Token refreshes go through the same bounded client as sends; without this
	// they would use http.DefaultClient and could hang without a deadline.
	creds, err := google.CredentialsFromJSON(
		context.WithValue(ctx, oauth2.HTTPClient, c.hc), credentialsJSON, Scope)
	if err != nil {
		return nil, fmt.Errorf("fcm: service-account credentials are not usable: %w", err)
	}
	if creds.ProjectID == "" {
		return nil, errors.New("fcm: service-account JSON has no project_id")
	}
	c.projectID = creds.ProjectID
	c.ts = creds.TokenSource
	return c, nil
}

// NewWithTokenSource builds a client from an explicit token source, bypassing
// the service-account parse. Tests use it to run the real request path against
// a stub without any credential.
func NewWithTokenSource(projectID string, ts oauth2.TokenSource, opts ...Option) *Client {
	c := &Client{projectID: projectID, ts: ts, baseURL: DefaultBaseURL,
		hc: &http.Client{Timeout: defaultTimeout}}
	for _, o := range opts {
		o(c)
	}
	return c
}

// ProjectID reports the Firebase project this client sends for.
func (c *Client) ProjectID() string { return c.projectID }

// message is the FCM v1 message. It deliberately has NO notification field:
// see the package doc. Adding one would hand Google the plaintext.
type message struct {
	Token   string            `json:"token"`
	Data    map[string]string `json:"data"`
	Android *androidConfig    `json:"android,omitempty"`
}

type androidConfig struct {
	// Priority "high" wakes a dozing device; a normal-priority data message may
	// be held until the next maintenance window, which is useless for "someone
	// just arrived".
	Priority string `json:"priority"`
	// TTL mirrors the Web Push TTL: a location notification is worthless once
	// stale, and FCM would otherwise queue it for its 4-week default.
	TTL string `json:"ttl,omitempty"`
}

type sendReq struct {
	Message message `json:"message"`
}

// Send delivers a data-only message to one registration token.
//
// data is relayed verbatim: for Aul it is the caller's sealed blob, which this
// package never inspects and cannot read. It returns ErrUnregistered when the
// token is dead and should be pruned.
func (c *Client) Send(ctx context.Context, token string, data map[string]string, ttlSeconds int) error {
	body, err := json.Marshal(sendReq{Message: message{
		Token:   token,
		Data:    data,
		Android: &androidConfig{Priority: "high", TTL: strconv.Itoa(ttlSeconds) + "s"},
	}})
	if err != nil {
		return fmt.Errorf("fcm: marshal message: %w", err)
	}

	url := c.baseURL + "/v1/projects/" + c.projectID + "/messages:send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("fcm: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	// Cached: the source only touches the network when the token is near expiry.
	tok, err := c.ts.Token()
	if err != nil {
		return fmt.Errorf("fcm: mint access token: %w", err)
	}
	tok.SetAuthHeader(req)

	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("fcm: send: %w", err)
	}
	defer resp.Body.Close() //nolint:errcheck // body is drained and discarded

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrorBodyBytes))
		return nil
	}

	errBody, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBodyBytes))
	if isUnregistered(resp.StatusCode, errBody) {
		return ErrUnregistered
	}
	// Status only. The token identifies a device and the body can echo it, so
	// neither may reach the log.
	return fmt.Errorf("fcm: send rejected with status %d", resp.StatusCode)
}

// apiError is the google.rpc.Status envelope FCM returns on failure.
type apiError struct {
	Error struct {
		Code    int    `json:"code"`
		Status  string `json:"status"`
		Details []struct {
			Type      string `json:"@type"`
			ErrorCode string `json:"errorCode"`
		} `json:"details"`
	} `json:"error"`
}

// isUnregistered reports whether FCM is saying "this token is dead", which is
// the only class of failure that may delete a subscription.
//
// Two spellings mean that: HTTP 404 / status NOT_FOUND, and the FcmError detail
// errorCode UNREGISTERED (which FCM has returned with both 404 and 400).
//
// INVALID_ARGUMENT is deliberately NOT pruned even though it can mean a
// malformed token: it is also what a malformed REQUEST returns — our own bug —
// and that would delete every subscription in the fan-out on the first bad
// deploy. A dead token costs one wasted send per notify; a wrong prune costs
// the user their notifications with no way to notice.
func isUnregistered(status int, body []byte) bool {
	if status == http.StatusNotFound {
		return true
	}
	var e apiError
	if err := json.Unmarshal(body, &e); err != nil {
		return false
	}
	if e.Error.Status == "NOT_FOUND" {
		return true
	}
	for _, d := range e.Error.Details {
		if d.ErrorCode == "UNREGISTERED" {
			return true
		}
	}
	return false
}

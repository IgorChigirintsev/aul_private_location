// Package httpx holds transport-level HTTP helpers shared across the server:
// JSON encoding/decoding with strict limits, a stable error envelope, and
// request-scoped context values (auth identity, request id, real client IP).
// It depends on nothing else in the tree to avoid import cycles.
package httpx

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
)

// ErrorCode is a stable, machine-readable error identifier returned to clients.
type ErrorCode string

const (
	CodeBadRequest    ErrorCode = "bad_request"
	CodeValidation    ErrorCode = "validation_error"
	CodeUnauthorized  ErrorCode = "unauthorized"
	CodeForbidden     ErrorCode = "forbidden"
	CodeNotFound      ErrorCode = "not_found"
	CodeGone          ErrorCode = "gone"
	CodeConflict      ErrorCode = "conflict"
	CodeRateLimited   ErrorCode = "rate_limited"
	CodePayloadTooBig ErrorCode = "payload_too_large"
	CodeLocked        ErrorCode = "account_locked"
	CodeInternal      ErrorCode = "internal_error"
)

type errorEnvelope struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

// WriteJSON writes v as JSON with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("httpx: encode response", "err", err)
	}
}

// WriteError writes the standard error envelope. Client-facing messages must
// never leak internals; keep them short and safe.
func WriteError(w http.ResponseWriter, status int, code ErrorCode, message string) {
	WriteJSON(w, status, errorEnvelope{Error: errorBody{Code: code, Message: message}})
}

// Common shorthands.
func BadRequest(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusBadRequest, CodeBadRequest, msg)
}
func Unauthorized(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusUnauthorized, CodeUnauthorized, msg)
}
func Forbidden(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusForbidden, CodeForbidden, msg)
}
func NotFound(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusNotFound, CodeNotFound, msg)
}

// Gone reports a resource that existed and is now permanently unavailable —
// expired or revoked — as distinct from NotFound's "no such thing".
func Gone(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusGone, CodeGone, msg)
}
func Conflict(w http.ResponseWriter, msg string) {
	WriteError(w, http.StatusConflict, CodeConflict, msg)
}

// Internal logs the real error server-side and returns a generic message.
func Internal(w http.ResponseWriter, err error) {
	slog.Error("httpx: internal error", "err", err)
	WriteError(w, http.StatusInternalServerError, CodeInternal, "internal server error")
}

// ErrBodyTooLarge is returned by DecodeJSON when the body exceeds the limit.
var ErrBodyTooLarge = errors.New("request body too large")

// DecodeJSON reads and decodes a JSON body into dst, enforcing a byte limit and
// rejecting unknown fields and trailing data. It returns ErrBodyTooLarge or a
// descriptive error suitable for a 400.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any, maxBytes int64) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return ErrBodyTooLarge
		}
		return fmt.Errorf("invalid JSON: %w", err)
	}
	// Reject any trailing content after the first JSON value.
	if dec.More() {
		return errors.New("request body must contain a single JSON object")
	}
	return nil
}

// ReadAllLimited reads up to maxBytes from r, erroring if exceeded.
func ReadAllLimited(r io.Reader, maxBytes int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > maxBytes {
		return nil, ErrBodyTooLarge
	}
	return b, nil
}

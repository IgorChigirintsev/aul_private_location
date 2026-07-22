package middleware

import (
	"bufio"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/httpx"
)

// RequestID assigns each request a correlation id (honoring an inbound
// X-Request-Id if present and short) and echoes it in the response.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-Id")
		if id == "" || len(id) > 64 {
			id = uuid.NewString()
		}
		w.Header().Set("X-Request-Id", id)
		ctx := httpx.WithRequestID(r.Context(), id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RealIP resolves the client IP once and stores it in context. When trustProxy
// is false, proxy headers are ignored so clients cannot spoof their IP.
func RealIP(trustProxy bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := httpx.ClientIP(r, trustProxy)
			ctx := httpx.WithRealIP(r.Context(), ip)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// Recoverer converts panics into a 500 and logs them with the request id.
func Recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				slog.Error("panic recovered",
					"err", fmt.Sprint(rec),
					"request_id", httpx.RequestIDFrom(r.Context()),
					"path", r.URL.Path)
				// Best-effort; header may already be written.
				defer func() { _ = recover() }()
				httpx.WriteError(w, http.StatusInternalServerError, httpx.CodeInternal, "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// BodyLimit caps the request body size globally as defense in depth (handlers
// also apply their own tighter limits via httpx.DecodeJSON).
func BodyLimit(max int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Body != nil {
				r.Body = http.MaxBytesReader(w, r.Body, max)
			}
			next.ServeHTTP(w, r)
		})
	}
}

// AccessLog logs one structured line per request. logIP controls whether the
// client IP is included (respecting IP-logging policy). The wrapped writer
// preserves Hijacker/Flusher so WebSocket upgrades still work.
func AccessLog(logIP bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &recorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			attrs := []any{
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"bytes", rec.written,
				"dur_ms", time.Since(start).Milliseconds(),
				"request_id", httpx.RequestIDFrom(r.Context()),
			}
			if logIP {
				attrs = append(attrs, "ip", httpx.RealIPFrom(r.Context()))
			}
			slog.Info("http", attrs...)
		})
	}
}

// recorder captures status/bytes while delegating optional interfaces.
type recorder struct {
	http.ResponseWriter
	status      int
	written     int64
	wroteHeader bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.wroteHeader {
		r.status = code
		r.wroteHeader = true
		r.ResponseWriter.WriteHeader(code)
	}
}

func (r *recorder) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	n, err := r.ResponseWriter.Write(b)
	r.written += int64(n)
	return n, err
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// Hijack delegates to the underlying writer so WebSocket upgrades work.
func (r *recorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := r.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, fmt.Errorf("middleware: underlying ResponseWriter is not a Hijacker")
}

// Flush delegates to the underlying writer when supported.
func (r *recorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

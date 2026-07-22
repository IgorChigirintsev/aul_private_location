package httpapi

import (
	"encoding/json"
	"log/slog"
	"strconv"
)

// mustJSON marshals v for a realtime payload, returning nil on failure (logged).
func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		slog.Error("httpapi: marshal realtime payload", "err", err)
		return nil
	}
	return b
}

func itoa(i int) string { return strconv.Itoa(i) }

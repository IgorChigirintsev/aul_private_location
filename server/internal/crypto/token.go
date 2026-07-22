package crypto

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
)

// TokenBytes is the entropy of an opaque token: 256 bits.
const TokenBytes = 32

// GenerateToken returns a cryptographically random, URL-safe opaque token with
// 256 bits of entropy. These are used for session access/refresh tokens and
// invite ids — values a client presents and the server looks up by hash.
func GenerateToken() (string, error) {
	b := make([]byte, TokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto: generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashToken computes HMAC-SHA256(pepper, token) and returns it hex-encoded. The
// server stores only this hash; a database-only compromise cannot recover or use
// the token because the pepper is a separate server-side secret. Lookups are by
// exact hash match, so this doubles as the indexable column value.
func HashToken(pepper []byte, token string) string {
	mac := hmac.New(sha256.New, pepper)
	mac.Write([]byte(token))
	return hex.EncodeToString(mac.Sum(nil))
}

// HashTokenBytes is HashToken's raw form: the same HMAC-SHA256(pepper, token),
// returned as its 32 unencoded bytes. Use it where the hash lives in a bytea
// column (share-session viewer tokens) rather than an indexed text one.
func HashTokenBytes(pepper []byte, token string) []byte {
	mac := hmac.New(sha256.New, pepper)
	mac.Write([]byte(token))
	return mac.Sum(nil)
}

// ConstantTimeEqual compares two strings in constant time. Use for any secret
// comparison not already reduced to an indexed hash lookup.
func ConstantTimeEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// ConstantTimeEqualBytes compares two byte slices in constant time.
func ConstantTimeEqualBytes(a, b []byte) bool {
	return subtle.ConstantTimeCompare(a, b) == 1
}

// RandomBytes returns n cryptographically random bytes (e.g. server challenges).
func RandomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("crypto: random bytes: %w", err)
	}
	return b, nil
}

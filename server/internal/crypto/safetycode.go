package crypto

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

// Safety codes let two people verify, out of band, that no server-injected
// man-in-the-middle has substituted keys. Both devices independently derive the
// SAME code from BOTH parties' X25519 public keys and compare it in person.
//
// Canonical scheme "aul-safety-code:v1" — MUST be mirrored byte-for-byte by the
// Dart and JS clients (a cross-language test vector is checked in):
//
//	low, high := sort(pubA, pubB)                       // lexicographic byte order
//	digest    := SHA256("aul-safety-code:v1" || 0x00 || low || high)
//	emoji[i]  := SafetyEmojiAlphabet[ digest[i] % 64 ]  // for i in 0..SafetyCodeLength
//
// Because 256 is an exact multiple of 64, `digest[i] % 64` is unbiased, giving
// 6 bits per emoji. The default 10-emoji code carries 60 bits: forging a
// matching code requires ~2^60 X25519 keygens (documented in THREAT_MODEL.md as
// the v1 bound). The full digest and a hex fallback are also returned for
// accessibility.
const (
	// PublicKeyLength is the X25519 public key size in bytes.
	PublicKeyLength = 32
	// SafetyCodeLength is the number of emoji in a code.
	SafetyCodeLength = 10
	// safetyCodeDomain domain-separates the fingerprint hash.
	safetyCodeDomain = "aul-safety-code:v1"
)

// ErrInvalidPublicKey is returned for a wrong-length X25519 public key.
var ErrInvalidPublicKey = errors.New("crypto: public key must be 32 bytes")

// SafetyEmojiAlphabet is the canonical 64-emoji alphabet (index 0..63). Each is
// a single Unicode scalar with default emoji presentation (no variation
// selectors or ZWJ), chosen to render consistently across platforms. This list
// is frozen for v1; changing it changes every safety code.
var SafetyEmojiAlphabet = [64]string{
	"🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
	"🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
	"🐧", "🐦", "🦆", "🦉", "🐴", "🦄", "🐝", "🐛",
	"🦋", "🐌", "🐞", "🐢", "🐍", "🐙", "🐠", "🐬",
	"🐳", "🐘", "🐫", "🐑", "🍎", "🍊", "🍋", "🍌",
	"🍉", "🍇", "🍓", "🍒", "🍑", "🍅", "🌽", "🥕",
	"🍔", "🍕", "🍩", "🍪", "🎂", "🍫", "🍭", "🌵",
	"🌲", "🌸", "🌻", "🌈", "🌙", "🔥", "🌊", "💧",
}

// SafetyCode is a verifiable device fingerprint derived from two public keys.
type SafetyCode struct {
	Emojis []string // SafetyCodeLength emoji, e.g. ["🐶","🍎",...]
	Digest []byte   // full 32-byte SHA-256 digest
}

// String renders the emoji code space-separated.
func (s SafetyCode) String() string { return strings.Join(s.Emojis, " ") }

// HexFallback returns the first 8 digest bytes as grouped hex (an accessible
// alternative to emoji for users who cannot distinguish them).
func (s SafetyCode) HexFallback() string {
	h := hex.EncodeToString(s.Digest[:8])
	var b strings.Builder
	for i := 0; i < len(h); i += 4 {
		if i > 0 {
			b.WriteByte('-')
		}
		b.WriteString(h[i : i+4])
	}
	return b.String()
}

// ComputeSafetyCode derives the canonical safety code from two X25519 public
// keys. The result is independent of argument order.
func ComputeSafetyCode(pubA, pubB []byte) (SafetyCode, error) {
	if len(pubA) != PublicKeyLength || len(pubB) != PublicKeyLength {
		return SafetyCode{}, ErrInvalidPublicKey
	}
	low, high := pubA, pubB
	if bytes.Compare(pubA, pubB) > 0 {
		low, high = pubB, pubA
	}
	h := sha256.New()
	h.Write([]byte(safetyCodeDomain))
	h.Write([]byte{0x00})
	h.Write(low)
	h.Write(high)
	digest := h.Sum(nil)

	emojis := make([]string, SafetyCodeLength)
	for i := 0; i < SafetyCodeLength; i++ {
		emojis[i] = SafetyEmojiAlphabet[digest[i]%64]
	}
	return SafetyCode{Emojis: emojis, Digest: digest}, nil
}

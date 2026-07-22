package crypto

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func key(fill byte) []byte {
	k := make([]byte, PublicKeyLength)
	for i := range k {
		k[i] = fill
	}
	return k
}

func TestComputeSafetyCode_OrderIndependent(t *testing.T) {
	a := key(0x01)
	b := key(0xF0)
	ab, err := ComputeSafetyCode(a, b)
	if err != nil {
		t.Fatalf("ab: %v", err)
	}
	ba, err := ComputeSafetyCode(b, a)
	if err != nil {
		t.Fatalf("ba: %v", err)
	}
	if ab.String() != ba.String() {
		t.Fatalf("safety code not order-independent: %q vs %q", ab, ba)
	}
	if !bytes.Equal(ab.Digest, ba.Digest) {
		t.Fatal("digests differ across argument order")
	}
}

func TestComputeSafetyCode_Shape(t *testing.T) {
	c, err := ComputeSafetyCode(key(0x00), key(0xFF))
	if err != nil {
		t.Fatalf("compute: %v", err)
	}
	if len(c.Emojis) != SafetyCodeLength {
		t.Fatalf("emoji count = %d, want %d", len(c.Emojis), SafetyCodeLength)
	}
	inAlphabet := make(map[string]bool, 64)
	for _, e := range SafetyEmojiAlphabet {
		inAlphabet[e] = true
	}
	for _, e := range c.Emojis {
		if !inAlphabet[e] {
			t.Fatalf("emoji %q not in canonical alphabet", e)
		}
	}
	if len(c.Digest) != 32 {
		t.Fatalf("digest len = %d, want 32", len(c.Digest))
	}
	hf := c.HexFallback()
	if strings.Count(hf, "-") != 3 || len(strings.ReplaceAll(hf, "-", "")) != 16 {
		t.Fatalf("hex fallback format unexpected: %q", hf)
	}
}

func TestComputeSafetyCode_InvalidKeyLength(t *testing.T) {
	if _, err := ComputeSafetyCode(make([]byte, 31), key(0)); !errors.Is(err, ErrInvalidPublicKey) {
		t.Fatalf("short key: got %v", err)
	}
	if _, err := ComputeSafetyCode(key(0), make([]byte, 33)); !errors.Is(err, ErrInvalidPublicKey) {
		t.Fatalf("long key: got %v", err)
	}
}

func TestComputeSafetyCode_DiffersByKey(t *testing.T) {
	c1, _ := ComputeSafetyCode(key(0x01), key(0x02))
	c2, _ := ComputeSafetyCode(key(0x01), key(0x03))
	if c1.String() == c2.String() {
		t.Fatal("different key pairs produced identical codes")
	}
}

// TestComputeSafetyCode_KnownVector pins the canonical output so the Dart/JS
// implementations can be verified against it. Inputs: pubA = 32×0x01,
// pubB = 32×0x02. If this changes, every client's verification breaks — treat a
// failure here as intentional-only.
func TestComputeSafetyCode_KnownVector(t *testing.T) {
	c, err := ComputeSafetyCode(key(0x01), key(0x02))
	if err != nil {
		t.Fatalf("compute: %v", err)
	}
	const wantHex = "c907-9b08-f079-e6fe" // first 8 digest bytes, grouped
	if c.HexFallback() != wantHex {
		t.Fatalf("known-vector hex fallback = %q, want %q (digest=%x)", c.HexFallback(), wantHex, c.Digest)
	}
}

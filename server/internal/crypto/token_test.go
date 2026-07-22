package crypto

import (
	"encoding/base64"
	"testing"
)

func TestGenerateToken_Entropy(t *testing.T) {
	seen := make(map[string]struct{}, 1000)
	for i := 0; i < 1000; i++ {
		tok, err := GenerateToken()
		if err != nil {
			t.Fatalf("generate: %v", err)
		}
		raw, err := base64.RawURLEncoding.DecodeString(tok)
		if err != nil {
			t.Fatalf("token not valid base64url: %v", err)
		}
		if len(raw) != TokenBytes {
			t.Fatalf("token entropy = %d bytes, want %d", len(raw), TokenBytes)
		}
		if _, dup := seen[tok]; dup {
			t.Fatal("duplicate token generated")
		}
		seen[tok] = struct{}{}
	}
}

func TestHashToken_DeterministicAndPeppered(t *testing.T) {
	pepper1 := []byte("pepper-one-pepper-one")
	pepper2 := []byte("pepper-two-pepper-two")
	tok := "the-token"

	h1a := HashToken(pepper1, tok)
	h1b := HashToken(pepper1, tok)
	if h1a != h1b {
		t.Fatal("HashToken must be deterministic for same pepper+token")
	}
	if len(h1a) != 64 { // hex of 32-byte HMAC-SHA256
		t.Fatalf("hash length = %d, want 64 hex chars", len(h1a))
	}
	if HashToken(pepper2, tok) == h1a {
		t.Fatal("different peppers must yield different hashes")
	}
	if HashToken(pepper1, "other-token") == h1a {
		t.Fatal("different tokens must yield different hashes")
	}
}

func TestConstantTimeEqual(t *testing.T) {
	if !ConstantTimeEqual("abc", "abc") {
		t.Fatal("equal strings reported unequal")
	}
	if ConstantTimeEqual("abc", "abd") {
		t.Fatal("unequal strings reported equal")
	}
	if ConstantTimeEqual("abc", "abcd") {
		t.Fatal("different-length strings reported equal")
	}
}

func TestRandomBytes(t *testing.T) {
	a, err := RandomBytes(24)
	if err != nil {
		t.Fatalf("random: %v", err)
	}
	if len(a) != 24 {
		t.Fatalf("len = %d, want 24", len(a))
	}
	b, _ := RandomBytes(24)
	if string(a) == string(b) {
		t.Fatal("two random draws identical")
	}
}

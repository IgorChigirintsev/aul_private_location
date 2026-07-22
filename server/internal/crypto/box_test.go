package crypto

import (
	"bytes"
	"crypto/rand"
	"errors"
	"testing"
)

func TestSealedBox_RoundTrip(t *testing.T) {
	priv := fill(0x33, 32)
	pub, err := DeriveX25519Public(priv)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	msg := []byte("circle key K_c goes here")
	sealed, err := SealAnonymousBox(msg, pub, rand.Reader)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if len(sealed) != len(msg)+SealedBoxOverhead {
		t.Fatalf("sealed length = %d, want %d", len(sealed), len(msg)+SealedBoxOverhead)
	}
	got, err := OpenAnonymousBox(sealed, pub, priv)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("round-trip mismatch: %q", got)
	}
}

func TestSealedBox_WrongRecipientFails(t *testing.T) {
	pub, _ := DeriveX25519Public(fill(0x33, 32))
	otherPriv := fill(0x44, 32)
	otherPub, _ := DeriveX25519Public(otherPriv)
	sealed, _ := SealAnonymousBox([]byte("secret"), pub, rand.Reader)
	if _, err := OpenAnonymousBox(sealed, otherPub, otherPriv); !errors.Is(err, ErrSealedBoxOpen) {
		t.Fatalf("wrong recipient should fail, got %v", err)
	}
}

func TestSealedBox_Deterministic(t *testing.T) {
	// A fixed ephemeral seed makes the sealed output reproducible (used for the
	// committed cross-language vector).
	pub, _ := DeriveX25519Public(fill(0x33, 32))
	a, _ := SealAnonymousBox([]byte("k"), pub, bytes.NewReader(fill(0x42, 64)))
	b, _ := SealAnonymousBox([]byte("k"), pub, bytes.NewReader(fill(0x42, 64)))
	if !bytes.Equal(a, b) {
		t.Fatal("same seed should produce identical sealed boxes")
	}
}

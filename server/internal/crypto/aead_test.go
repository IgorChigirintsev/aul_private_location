package crypto

import (
	"bytes"
	"errors"
	"testing"
)

func TestXChaCha20_RoundTrip(t *testing.T) {
	key := fill(0x11, XChaChaKeySize)
	nonce := fill(0x22, XChaChaNonceSize)
	plain := []byte(`{"lat":1.23,"lng":4.56}`)
	ad := []byte("aul")

	ct, err := SealXChaCha20(key, nonce, plain, ad)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if bytes.Contains(ct, plain) {
		t.Fatal("ciphertext contains plaintext")
	}
	got, err := OpenXChaCha20(key, nonce, ct, ad)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("round-trip mismatch: %q", got)
	}
}

func TestXChaCha20_TamperDetected(t *testing.T) {
	key := fill(0x11, XChaChaKeySize)
	nonce := fill(0x22, XChaChaNonceSize)
	ct, _ := SealXChaCha20(key, nonce, []byte("secret"), nil)
	ct[0] ^= 0xFF // flip a bit
	if _, err := OpenXChaCha20(key, nonce, ct, nil); err == nil {
		t.Fatal("tampered ciphertext must fail authentication")
	}
	// Wrong associated data must also fail.
	ct2, _ := SealXChaCha20(key, nonce, []byte("secret"), []byte("ad-1"))
	if _, err := OpenXChaCha20(key, nonce, ct2, []byte("ad-2")); err == nil {
		t.Fatal("wrong AD must fail authentication")
	}
}

func TestXChaCha20_BadSizes(t *testing.T) {
	if _, err := SealXChaCha20(make([]byte, 31), make([]byte, 24), nil, nil); !errors.Is(err, ErrBadKeyOrNonce) {
		t.Fatalf("short key: %v", err)
	}
	if _, err := SealXChaCha20(make([]byte, 32), make([]byte, 23), nil, nil); !errors.Is(err, ErrBadKeyOrNonce) {
		t.Fatalf("short nonce: %v", err)
	}
}

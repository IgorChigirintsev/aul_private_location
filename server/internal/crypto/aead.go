package crypto

import (
	"errors"

	"golang.org/x/crypto/chacha20poly1305"
)

// XChaCha20-Poly1305 (IETF) is how clients seal pings and places. The server
// never decrypts these in E2EE mode; these helpers exist for trusted-server mode
// and for generating the cross-language interop vectors that the Dart and JS
// clients verify against. The construction is byte-compatible with libsodium's
// crypto_aead_xchacha20poly1305_ietf used by the clients.

const (
	// XChaChaKeySize is the key length (32 bytes).
	XChaChaKeySize = chacha20poly1305.KeySize
	// XChaChaNonceSize is the XChaCha20 nonce length (24 bytes).
	XChaChaNonceSize = chacha20poly1305.NonceSizeX
)

// ErrBadKeyOrNonce is returned for a wrong-length key or nonce.
var ErrBadKeyOrNonce = errors.New("crypto: XChaCha20 key must be 32 bytes and nonce 24 bytes")

// SealXChaCha20 encrypts plaintext under key with the given 24-byte nonce and
// optional associated data, returning ciphertext||tag.
func SealXChaCha20(key, nonce, plaintext, ad []byte) ([]byte, error) {
	if len(key) != XChaChaKeySize || len(nonce) != XChaChaNonceSize {
		return nil, ErrBadKeyOrNonce
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	return aead.Seal(nil, nonce, plaintext, ad), nil
}

// OpenXChaCha20 reverses SealXChaCha20, verifying the Poly1305 tag.
func OpenXChaCha20(key, nonce, ciphertext, ad []byte) ([]byte, error) {
	if len(key) != XChaChaKeySize || len(nonce) != XChaChaNonceSize {
		return nil, ErrBadKeyOrNonce
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	return aead.Open(nil, nonce, ciphertext, ad)
}

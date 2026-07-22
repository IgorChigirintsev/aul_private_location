package crypto

import (
	"crypto/rand"
	"errors"
	"io"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

// crypto_box_seal (anonymous sealed boxes) is how the circle key K_c is
// distributed to member devices: the sender seals K_c to a recipient's X25519
// identity public key, and only that device's private key can open it. The
// server relays these boxes it cannot open. golang.org/x/crypto/nacl/box's
// anonymous format is byte-compatible with libsodium's crypto_box_seal, which
// the Dart and JS clients use — pinned by cross-language vectors.

// SealedBoxOverhead is the extra length a sealed box adds (ephemeral pk + tag).
const SealedBoxOverhead = box.AnonymousOverhead // 48 bytes

// ErrSealedBoxOpen is returned when a sealed box fails to open/authenticate.
var ErrSealedBoxOpen = errors.New("crypto: sealed box open failed")

// DeriveX25519Public returns the Curve25519 public key for a 32-byte private key.
func DeriveX25519Public(priv []byte) ([]byte, error) {
	if len(priv) != 32 {
		return nil, errors.New("crypto: private key must be 32 bytes")
	}
	return curve25519.X25519(priv, curve25519.Basepoint)
}

// SealAnonymousBox seals message to recipientPub (crypto_box_seal). randSource
// supplies the ephemeral key material; pass crypto/rand.Reader in production, or
// a fixed reader for reproducible test vectors.
func SealAnonymousBox(message, recipientPub []byte, randSource io.Reader) ([]byte, error) {
	if len(recipientPub) != 32 {
		return nil, ErrInvalidPublicKey
	}
	var pub [32]byte
	copy(pub[:], recipientPub)
	if randSource == nil {
		randSource = rand.Reader
	}
	return box.SealAnonymous(nil, message, &pub, randSource)
}

// OpenAnonymousBox opens a sealed box addressed to the (pub, priv) keypair.
func OpenAnonymousBox(sealed, pub, priv []byte) ([]byte, error) {
	if len(pub) != 32 || len(priv) != 32 {
		return nil, ErrInvalidPublicKey
	}
	var p, s [32]byte
	copy(p[:], pub)
	copy(s[:], priv)
	msg, ok := box.OpenAnonymous(nil, sealed, &p, &s)
	if !ok {
		return nil, ErrSealedBoxOpen
	}
	return msg, nil
}

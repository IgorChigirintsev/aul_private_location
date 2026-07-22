// Package crypto holds the server-side security primitives that must be real and
// tested even before the E2EE client work: Argon2id password hashing, opaque
// session-token generation and peppered hashing, and the emoji safety-code
// fingerprint that the Dart and JS clients mirror. No primitive here is
// hand-rolled — password hashing uses golang.org/x/crypto/argon2 (the reference
// implementation) and token/fingerprint code uses the standard library.
package crypto

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Argon2Params configures Argon2id. Defaults follow the product spec and current
// OWASP guidance: m=64 MiB, t=3, p=4, 16-byte salt, 32-byte key.
type Argon2Params struct {
	Memory      uint32 // KiB
	Iterations  uint32
	Parallelism uint8
	SaltLength  uint32
	KeyLength   uint32
}

// DefaultArgon2Params are the production parameters.
var DefaultArgon2Params = Argon2Params{
	Memory:      64 * 1024, // 64 MiB
	Iterations:  3,
	Parallelism: 4,
	SaltLength:  16,
	KeyLength:   32,
}

var (
	// ErrInvalidHash is returned when an encoded hash cannot be parsed.
	ErrInvalidHash = errors.New("crypto: invalid argon2 hash format")
	// ErrIncompatibleVersion is returned for an unknown argon2 version.
	ErrIncompatibleVersion = errors.New("crypto: incompatible argon2 version")
	// ErrEmptyPassword guards against hashing/verifying an empty password.
	ErrEmptyPassword = errors.New("crypto: password must not be empty")
)

// HashPassword derives an Argon2id hash and returns it in the standard PHC
// string format, e.g. $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>. The salt is
// freshly random per call. Parameters are embedded so they can be tuned later
// while old hashes still verify.
func HashPassword(password string) (string, error) {
	return HashPasswordWithParams(password, DefaultArgon2Params)
}

// HashPasswordWithParams is HashPassword with explicit parameters (used by tests
// to run cheaply).
func HashPasswordWithParams(password string, p Argon2Params) (string, error) {
	if password == "" {
		return "", ErrEmptyPassword
	}
	salt := make([]byte, p.SaltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("crypto: read salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, p.Iterations, p.Memory, p.Parallelism, p.KeyLength)

	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.Memory, p.Iterations, p.Parallelism,
		b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

// VerifyPassword checks password against an encoded Argon2id hash in constant
// time. It reports ok, and needsRehash=true when the stored parameters are
// weaker than the current defaults (caller should re-hash on next login).
func VerifyPassword(encoded, password string) (ok bool, needsRehash bool, err error) {
	if password == "" {
		return false, false, ErrEmptyPassword
	}
	p, salt, hash, err := decodeHash(encoded)
	if err != nil {
		return false, false, err
	}
	computed := argon2.IDKey([]byte(password), salt, p.Iterations, p.Memory, p.Parallelism, p.KeyLength)
	if subtle.ConstantTimeCompare(hash, computed) != 1 {
		return false, false, nil
	}
	needsRehash = weakerThan(p, DefaultArgon2Params)
	return true, needsRehash, nil
}

func weakerThan(got, want Argon2Params) bool {
	return got.Memory < want.Memory ||
		got.Iterations < want.Iterations ||
		got.Parallelism < want.Parallelism ||
		got.KeyLength < want.KeyLength
}

func decodeHash(encoded string) (p Argon2Params, salt, hash []byte, err error) {
	parts := strings.Split(encoded, "$")
	// ["", "argon2id", "v=19", "m=65536,t=3,p=4", "<salt>", "<hash>"]
	if len(parts) != 6 || parts[1] != "argon2id" {
		return p, nil, nil, ErrInvalidHash
	}
	var version int
	if _, err = fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return p, nil, nil, ErrInvalidHash
	}
	if version != argon2.Version {
		return p, nil, nil, ErrIncompatibleVersion
	}
	if _, err = fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.Memory, &p.Iterations, &p.Parallelism); err != nil {
		return p, nil, nil, ErrInvalidHash
	}
	b64 := base64.RawStdEncoding
	if salt, err = b64.DecodeString(parts[4]); err != nil {
		return p, nil, nil, ErrInvalidHash
	}
	if hash, err = b64.DecodeString(parts[5]); err != nil {
		return p, nil, nil, ErrInvalidHash
	}
	// Reject absurd sizes so the length→uint32 conversions below cannot overflow
	// (Argon2 salts/keys are tens of bytes; 1 KiB is already far beyond real use).
	if len(salt) == 0 || len(hash) == 0 || len(salt) > 1024 || len(hash) > 1024 {
		return p, nil, nil, ErrInvalidHash
	}
	p.SaltLength = uint32(len(salt)) // #nosec G115 -- bounded to ≤1024 by the check above
	p.KeyLength = uint32(len(hash))  // #nosec G115 -- bounded to ≤1024 by the check above
	return p, salt, hash, nil
}

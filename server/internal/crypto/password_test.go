package crypto

import (
	"errors"
	"strings"
	"testing"
)

// fastParams keep unit tests quick while still exercising Argon2id.
var fastParams = Argon2Params{Memory: 8 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32}

func TestHashPassword_RoundTrip(t *testing.T) {
	hash, err := HashPasswordWithParams("correct horse battery staple", fastParams)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if !strings.HasPrefix(hash, "$argon2id$v=19$m=8192,t=1,p=1$") {
		t.Fatalf("unexpected PHC format: %q", hash)
	}
	ok, rehash, err := VerifyPassword(hash, "correct horse battery staple")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if !ok {
		t.Fatal("correct password rejected")
	}
	// fastParams are weaker than defaults, so a rehash should be advised.
	if !rehash {
		t.Fatal("expected needsRehash=true for weak params")
	}
}

func TestHashPassword_DefaultsDoNotNeedRehash(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping 64MiB argon2 in -short")
	}
	hash, err := HashPassword("a-strong-passphrase-123")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	ok, rehash, err := VerifyPassword(hash, "a-strong-passphrase-123")
	if err != nil || !ok {
		t.Fatalf("verify default: ok=%v err=%v", ok, err)
	}
	if rehash {
		t.Fatal("default params should not need rehash")
	}
}

func TestVerifyPassword_WrongPassword(t *testing.T) {
	hash, _ := HashPasswordWithParams("hunter2", fastParams)
	ok, _, err := VerifyPassword(hash, "hunter3")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if ok {
		t.Fatal("wrong password accepted")
	}
}

func TestHashPassword_SaltIsRandom(t *testing.T) {
	h1, _ := HashPasswordWithParams("same", fastParams)
	h2, _ := HashPasswordWithParams("same", fastParams)
	if h1 == h2 {
		t.Fatal("two hashes of the same password are identical — salt not random")
	}
}

func TestPassword_EmptyRejected(t *testing.T) {
	if _, err := HashPassword(""); !errors.Is(err, ErrEmptyPassword) {
		t.Fatalf("hash empty: got %v", err)
	}
	if _, _, err := VerifyPassword("$argon2id$v=19$m=8192,t=1,p=1$YWJjZGVmZ2hpamtsbW5vcA$x", ""); !errors.Is(err, ErrEmptyPassword) {
		t.Fatalf("verify empty: got %v", err)
	}
}

func TestVerifyPassword_MalformedHashes(t *testing.T) {
	cases := map[string]string{
		"not phc":        "hello",
		"wrong algo":     "$argon2i$v=19$m=8192,t=1,p=1$c2FsdA$aGFzaA",
		"bad version":    "$argon2id$v=99$m=8192,t=1,p=1$c2FsdA$aGFzaA",
		"missing fields": "$argon2id$v=19$m=8192,t=1$c2FsdA$aGFzaA",
		"bad b64 salt":   "$argon2id$v=19$m=8192,t=1,p=1$!!!$aGFzaA",
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			ok, _, err := VerifyPassword(h, "pw")
			if ok {
				t.Fatal("malformed hash verified true")
			}
			if err == nil {
				t.Fatal("expected an error for malformed hash")
			}
		})
	}
}

func TestVerifyPassword_NeedsRehashWhenWeaker(t *testing.T) {
	// A hash produced with weaker-than-default params must advise a rehash.
	weak := Argon2Params{Memory: 4 * 1024, Iterations: 1, Parallelism: 1, SaltLength: 16, KeyLength: 32}
	hash, _ := HashPasswordWithParams("pw", weak)
	ok, rehash, err := VerifyPassword(hash, "pw")
	if err != nil || !ok {
		t.Fatalf("verify: ok=%v err=%v", ok, err)
	}
	if !rehash {
		t.Fatal("expected needsRehash=true")
	}
}

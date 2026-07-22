package auth

import (
	"errors"
	"net/mail"
	"strings"
	"unicode/utf8"
)

const (
	minPasswordLen = 8
	maxPasswordLen = 1024 // bound Argon2 input; still very generous
	maxEmailLen    = 254
)

var (
	ErrInvalidEmail    = errors.New("invalid email address")
	ErrWeakPassword    = errors.New("password must be at least 8 characters")
	ErrPasswordTooLong = errors.New("password is too long")
	ErrInvalidPlatform = errors.New("platform must be android, ios, web, or web-mobile")
)

// normalizeEmail trims and lower-cases; storage uses citext but we normalize the
// input too for consistent audit/logging.
func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func validateEmail(email string) (string, error) {
	e := normalizeEmail(email)
	if e == "" || len(e) > maxEmailLen {
		return "", ErrInvalidEmail
	}
	addr, err := mail.ParseAddress(e)
	if err != nil || addr.Address != e {
		return "", ErrInvalidEmail
	}
	return e, nil
}

func validatePassword(pw string) error {
	if !utf8.ValidString(pw) {
		return ErrWeakPassword
	}
	if len(pw) < minPasswordLen {
		return ErrWeakPassword
	}
	if len(pw) > maxPasswordLen {
		return ErrPasswordTooLong
	}
	return nil
}

func validatePlatform(p string) error {
	switch p {
	// 'web-mobile' is a web client in a phone browser — distinguished from desktop
	// 'web' so the map/members UI can drop the desktop-only "PC" badge for it.
	case "android", "ios", "web", "web-mobile":
		return nil
	default:
		return ErrInvalidPlatform
	}
}

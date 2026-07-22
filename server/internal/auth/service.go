// Package auth implements account registration, password login, opaque session
// tokens with refresh rotation + reuse detection, device revocation, and the
// RequireAuth middleware. Passwords use Argon2id; tokens are random 256-bit
// values stored only as peppered HMAC hashes. Nothing here is a stub.
package auth

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/audit"
	"github.com/aul-app/aul/server/internal/config"
	"github.com/aul-app/aul/server/internal/crypto"
	"github.com/aul-app/aul/server/internal/store"
)

// Sentinel errors mapped to HTTP status by the transport layer.
var (
	ErrEmailTaken         = errors.New("auth: email already registered")
	ErrInvalidCredentials = errors.New("auth: invalid credentials")
	ErrRefreshInvalid     = errors.New("auth: invalid or expired refresh token")
	ErrRefreshReused      = errors.New("auth: refresh token reuse detected; session revoked")
	ErrUnauthorized       = errors.New("auth: unauthorized")
	ErrDeviceNotFound     = errors.New("auth: device not found")
)

// LockedError signals a temporary lockout with a retry hint.
type LockedError struct {
	RetryAfter time.Duration
	Reason     string
}

func (e *LockedError) Error() string { return "auth: locked: " + e.Reason }

// Service provides authentication operations.
type Service struct {
	store       *store.Store
	audit       *audit.Logger
	pepper      []byte
	accessTTL   time.Duration
	refreshTTL  time.Duration
	lockout     LockoutPolicy
	argonParams crypto.Argon2Params
	dummyHash   string // burns Argon time on unknown-account logins
	storeIP     bool   // record source IP on login attempts (IP logging enabled)
	now         func() time.Time
}

// Option customizes a Service (used mainly by tests).
type Option func(*Service)

// WithArgon2Params overrides the Argon2id cost (tests use cheap params).
func WithArgon2Params(p crypto.Argon2Params) Option { return func(s *Service) { s.argonParams = p } }

// WithClock overrides the time source (tests).
func WithClock(now func() time.Time) Option { return func(s *Service) { s.now = now } }

// WithLockout overrides the lockout policy (tests).
func WithLockout(p LockoutPolicy) Option { return func(s *Service) { s.lockout = p } }

// NewService builds an auth Service from config.
func NewService(st *store.Store, aud *audit.Logger, cfg *config.Config, opts ...Option) (*Service, error) {
	s := &Service{
		store:       st,
		audit:       aud,
		pepper:      cfg.SessionPepper,
		accessTTL:   cfg.AccessTTL,
		refreshTTL:  cfg.RefreshTTL,
		lockout:     DefaultLockout,
		argonParams: crypto.DefaultArgon2Params,
		storeIP:     cfg.IPLogRetentionDays > 0,
		now:         time.Now,
	}
	for _, o := range opts {
		o(s)
	}
	// Precompute a dummy hash with the same params for timing equalization.
	dummy, err := crypto.HashPasswordWithParams("aul-timing-equalizer-password", s.argonParams)
	if err != nil {
		return nil, fmt.Errorf("auth: init dummy hash: %w", err)
	}
	s.dummyHash = dummy
	return s, nil
}

// Result is returned by Register/Login/Refresh.
type Result struct {
	User             store.User
	Device           store.Device
	Session          store.Session
	AccessToken      string
	RefreshToken     string
	AccessExpiresAt  time.Time
	RefreshExpiresAt time.Time
}

// RegisterInput describes a new account + its first device.
type RegisterInput struct {
	Email       string
	Password    string
	Platform    string
	DisplayName string
	Pubkey      []byte
	IP          string
}

// Register creates a user, its first device, and an initial session.
func (s *Service) Register(ctx context.Context, in RegisterInput) (*Result, error) {
	email, err := validateEmail(in.Email)
	if err != nil {
		return nil, err
	}
	if err := validatePassword(in.Password); err != nil {
		return nil, err
	}
	if err := validatePlatform(in.Platform); err != nil {
		return nil, err
	}
	if err := validatePubkey(in.Pubkey); err != nil {
		return nil, err
	}

	exists, err := s.store.EmailExists(ctx, email)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, ErrEmailTaken
	}

	hash, err := crypto.HashPasswordWithParams(in.Password, s.argonParams)
	if err != nil {
		return nil, err
	}

	var res *Result
	err = s.store.WithTx(ctx, func(q store.Querier) error {
		user, err := q.CreateUser(ctx, store.CreateUserParams{Email: email, PassHash: hash})
		if err != nil {
			return err
		}
		device, err := q.CreateDevice(ctx, store.CreateDeviceParams{
			UserID:      user.ID,
			Platform:    in.Platform,
			DisplayName: strPtrOrNil(in.DisplayName),
			Pubkey:      in.Pubkey,
		})
		if err != nil {
			return err
		}
		r, err := s.issueSession(ctx, q, user, device)
		if err != nil {
			return err
		}
		res = r
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.audit.Log(ctx, audit.Event{Name: audit.EventRegister, UserID: &res.User.ID, DeviceID: &res.Device.ID, IP: in.IP})
	return res, nil
}

// LoginInput describes a login. DeviceID reuses an existing device when set.
type LoginInput struct {
	Email       string
	Password    string
	Platform    string
	DisplayName string
	DeviceID    *uuid.UUID
	Pubkey      []byte
	IP          string
}

// Login verifies credentials and issues a session. It equalizes timing for
// unknown accounts and enforces persistent lockout.
func (s *Service) Login(ctx context.Context, in LoginInput) (*Result, error) {
	email := normalizeEmail(in.Email)
	if err := validatePlatform(in.Platform); err != nil {
		return nil, err
	}
	if err := validatePubkey(in.Pubkey); err != nil {
		return nil, err
	}

	lock, err := s.checkLockout(ctx, email, in.IP)
	if err != nil {
		return nil, err
	}
	if lock.Locked {
		return nil, &LockedError{RetryAfter: lock.RetryAfter, Reason: lock.Reason}
	}

	user, err := s.store.GetUserByEmail(ctx, email)
	if err != nil {
		if store.IsNotFound(err) {
			// Burn comparable time so response timing doesn't reveal account existence.
			_, _, _ = crypto.VerifyPassword(s.dummyHash, in.Password)
			s.recordAttempt(ctx, email, in.IP, false)
			s.audit.Log(ctx, audit.Event{Name: audit.EventLoginFailed, IP: in.IP, Detail: map[string]any{"email": email}})
			return nil, ErrInvalidCredentials
		}
		return nil, err
	}

	ok, needsRehash, err := crypto.VerifyPassword(user.PassHash, in.Password)
	if err != nil {
		return nil, err
	}
	if !ok {
		s.recordAttempt(ctx, email, in.IP, false)
		s.audit.Log(ctx, audit.Event{Name: audit.EventLoginFailed, UserID: &user.ID, IP: in.IP})
		return nil, ErrInvalidCredentials
	}

	if needsRehash {
		if nh, herr := crypto.HashPasswordWithParams(in.Password, s.argonParams); herr == nil {
			_ = s.store.UpdateUserPassword(ctx, store.UpdateUserPasswordParams{ID: user.ID, PassHash: nh})
		}
	}
	s.recordAttempt(ctx, email, in.IP, true)

	var res *Result
	err = s.store.WithTx(ctx, func(q store.Querier) error {
		device, derr := s.resolveOrCreateDevice(ctx, q, user, in)
		if derr != nil {
			return derr
		}
		r, serr := s.issueSession(ctx, q, user, device)
		if serr != nil {
			return serr
		}
		res = r
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.audit.Log(ctx, audit.Event{Name: audit.EventLogin, UserID: &res.User.ID, DeviceID: &res.Device.ID, IP: in.IP})
	return res, nil
}

func (s *Service) resolveOrCreateDevice(ctx context.Context, q store.Querier, user store.User, in LoginInput) (store.Device, error) {
	if in.DeviceID != nil {
		device, err := q.GetDeviceForUser(ctx, store.GetDeviceForUserParams{ID: *in.DeviceID, UserID: user.ID})
		if err != nil {
			if store.IsNotFound(err) {
				return store.Device{}, ErrDeviceNotFound
			}
			return store.Device{}, err
		}
		// Adopt a newly-provided identity pubkey if the device lacks one.
		if len(in.Pubkey) == crypto.PublicKeyLength && len(device.Pubkey) == 0 {
			if err := q.SetDevicePubkey(ctx, store.SetDevicePubkeyParams{ID: device.ID, Pubkey: in.Pubkey}); err != nil {
				return store.Device{}, err
			}
			device.Pubkey = in.Pubkey
		}
		return device, nil
	}
	// No device id supplied. Before minting a new device, look for one this user
	// already owns with the SAME identity pubkey and adopt it. Defence-in-depth
	// against duplicates: a web client that persists its keypair but not its
	// device id (e.g. after a re-auth) would otherwise get a fresh device row on
	// every sign-in, and the live map draws one marker per device. The pubkey is
	// the device's stable cryptographic identity, so matching on it is safe.
	if len(in.Pubkey) == crypto.PublicKeyLength {
		existing, err := q.ListDevicesForUser(ctx, user.ID)
		if err != nil {
			return store.Device{}, err
		}
		for _, d := range existing {
			if bytes.Equal(d.Pubkey, in.Pubkey) {
				return d, nil
			}
		}
	}
	return q.CreateDevice(ctx, store.CreateDeviceParams{
		UserID:      user.ID,
		Platform:    in.Platform,
		DisplayName: strPtrOrNil(in.DisplayName),
		Pubkey:      in.Pubkey,
	})
}

// issueSession generates fresh tokens and persists a session row (within q).
func (s *Service) issueSession(ctx context.Context, q store.Querier, user store.User, device store.Device) (*Result, error) {
	access, err := crypto.GenerateToken()
	if err != nil {
		return nil, err
	}
	refresh, err := crypto.GenerateToken()
	if err != nil {
		return nil, err
	}
	now := s.now()
	accessExp := now.Add(s.accessTTL)
	refreshExp := now.Add(s.refreshTTL)

	session, err := q.CreateSession(ctx, store.CreateSessionParams{
		UserID:           user.ID,
		DeviceID:         device.ID,
		AccessTokenHash:  crypto.HashToken(s.pepper, access),
		RefreshTokenHash: crypto.HashToken(s.pepper, refresh),
		AccessExpiresAt:  accessExp,
		RefreshExpiresAt: refreshExp,
	})
	if err != nil {
		return nil, err
	}
	return &Result{
		User:             user,
		Device:           device,
		Session:          session,
		AccessToken:      access,
		RefreshToken:     refresh,
		AccessExpiresAt:  accessExp,
		RefreshExpiresAt: refreshExp,
	}, nil
}

// Refresh rotates a refresh token. Presenting an already-rotated (previous)
// token is treated as theft and revokes the session.
func (s *Service) Refresh(ctx context.Context, refreshToken, ip string) (*Result, error) {
	if refreshToken == "" {
		return nil, ErrRefreshInvalid
	}
	hash := crypto.HashToken(s.pepper, refreshToken)

	session, err := s.store.GetSessionByRefreshHash(ctx, hash)
	if err != nil {
		if !store.IsNotFound(err) {
			return nil, err
		}
		// Not a current token — is it a replayed previous one?
		reused, rerr := s.store.GetSessionByPrevRefreshHash(ctx, &hash)
		if rerr == nil {
			_ = s.store.RevokeSession(ctx, reused.ID)
			s.audit.Log(ctx, audit.Event{Name: audit.EventRefreshReuse, UserID: &reused.UserID, DeviceID: &reused.DeviceID, IP: ip})
			return nil, ErrRefreshReused
		}
		return nil, ErrRefreshInvalid
	}

	access, err := crypto.GenerateToken()
	if err != nil {
		return nil, err
	}
	newRefresh, err := crypto.GenerateToken()
	if err != nil {
		return nil, err
	}
	now := s.now()
	accessExp := now.Add(s.accessTTL)
	refreshExp := now.Add(s.refreshTTL)

	rotated, err := s.store.RotateSession(ctx, store.RotateSessionParams{
		ID:               session.ID,
		AccessTokenHash:  crypto.HashToken(s.pepper, access),
		RefreshTokenHash: crypto.HashToken(s.pepper, newRefresh),
		AccessExpiresAt:  accessExp,
		RefreshExpiresAt: refreshExp,
		OldRefreshHash:   &hash,
	})
	if err != nil {
		if store.IsNotFound(err) {
			// The token was already rotated by a concurrent request between our
			// lookup and this compare-and-swap: a double-spend of the same
			// refresh token. Treat it as reuse and revoke the session.
			_ = s.store.RevokeSession(ctx, session.ID)
			s.audit.Log(ctx, audit.Event{Name: audit.EventRefreshReuse, UserID: &session.UserID, DeviceID: &session.DeviceID, IP: ip})
			return nil, ErrRefreshReused
		}
		return nil, err
	}
	s.audit.Log(ctx, audit.Event{Name: audit.EventRefresh, UserID: &rotated.UserID, DeviceID: &rotated.DeviceID, IP: ip})
	return &Result{
		Session:          rotated,
		AccessToken:      access,
		RefreshToken:     newRefresh,
		AccessExpiresAt:  accessExp,
		RefreshExpiresAt: refreshExp,
	}, nil
}

// Resolve maps an access token to an authenticated identity for RequireAuth.
func (s *Service) Resolve(ctx context.Context, accessToken string) (uuid.UUID, uuid.UUID, uuid.UUID, error) {
	if accessToken == "" {
		return uuid.Nil, uuid.Nil, uuid.Nil, ErrUnauthorized
	}
	session, err := s.store.GetSessionByAccessHash(ctx, crypto.HashToken(s.pepper, accessToken))
	if err != nil {
		if store.IsNotFound(err) {
			return uuid.Nil, uuid.Nil, uuid.Nil, ErrUnauthorized
		}
		return uuid.Nil, uuid.Nil, uuid.Nil, err
	}
	return session.UserID, session.DeviceID, session.ID, nil
}

// Logout revokes a single session.
func (s *Service) Logout(ctx context.Context, sessionID, userID uuid.UUID, ip string) error {
	if err := s.store.RevokeSession(ctx, sessionID); err != nil {
		return err
	}
	s.audit.Log(ctx, audit.Event{Name: audit.EventLogout, UserID: &userID, IP: ip})
	return nil
}

// RevokeDevice revokes all sessions for a device the user owns (account
// security page). It verifies ownership first.
func (s *Service) RevokeDevice(ctx context.Context, userID, deviceID uuid.UUID, ip string) error {
	device, err := s.store.GetDeviceForUser(ctx, store.GetDeviceForUserParams{ID: deviceID, UserID: userID})
	if err != nil {
		if store.IsNotFound(err) {
			return ErrDeviceNotFound
		}
		return err
	}
	if err := s.store.RevokeSessionsForDevice(ctx, device.ID); err != nil {
		return err
	}
	s.audit.Log(ctx, audit.Event{Name: audit.EventSessionRevoked, UserID: &userID, DeviceID: &device.ID, IP: ip})
	return nil
}

// Store exposes the underlying store for handlers that need read access
// (kept explicit so the auth surface stays intentional).
func (s *Service) Store() *store.Store { return s.store }

func validatePubkey(pk []byte) error {
	if len(pk) != 0 && len(pk) != crypto.PublicKeyLength {
		return fmt.Errorf("pubkey must be %d bytes", crypto.PublicKeyLength)
	}
	return nil
}

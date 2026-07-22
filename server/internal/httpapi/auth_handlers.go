package httpapi

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/aul-app/aul/server/internal/auth"
	"github.com/aul-app/aul/server/internal/httpx"
	"github.com/aul-app/aul/server/internal/store"
)

func (s *Server) mountAuth(r chi.Router) {
	r.Route("/auth", func(r chi.Router) {
		// Unauthenticated, IP rate-limited.
		r.Group(func(r chi.Router) {
			r.Use(s.rateLimitByIP(s.authLimiter, 60))
			r.Post("/register", s.handleRegister)
			r.Post("/login", s.handleLogin)
			r.Post("/refresh", s.handleRefresh)
		})
		// Authenticated.
		r.Group(func(r chi.Router) {
			r.Use(s.auth.RequireAuth)
			r.Post("/logout", s.handleLogout)
		})
	})

	// Account & device management.
	r.Route("/account", func(r chi.Router) {
		r.Use(s.auth.RequireAuth)
		r.Get("/me", s.handleMe)
		r.Get("/devices", s.handleListDevices)
		r.Delete("/devices/{deviceID}", s.handleRevokeDevice)
		r.Get("/sessions", s.handleListSessions)
		r.Get("/audit", s.handleListAudit)
	})
}

type registerReq struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	Platform    string `json:"platform"`
	DisplayName string `json:"display_name"`
	Pubkey      string `json:"pubkey"` // optional base64 X25519 public key
}

type loginReq struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	Platform    string `json:"platform"`
	DisplayName string `json:"display_name"`
	DeviceID    string `json:"device_id"` // optional; reuse an existing device
	Pubkey      string `json:"pubkey"`    // optional base64
}

type refreshReq struct {
	RefreshToken string `json:"refresh_token"`
}

type authResp struct {
	AccessToken      string     `json:"access_token"`
	RefreshToken     string     `json:"refresh_token"`
	AccessExpiresAt  time.Time  `json:"access_expires_at"`
	RefreshExpiresAt time.Time  `json:"refresh_expires_at"`
	User             *userDTO   `json:"user,omitempty"`
	Device           *deviceDTO `json:"device,omitempty"`
}

type userDTO struct {
	ID    uuid.UUID `json:"id"`
	Email string    `json:"email"`
}

type deviceDTO struct {
	ID          uuid.UUID  `json:"id"`
	Platform    string     `json:"platform"`
	DisplayName *string    `json:"display_name,omitempty"`
	HasPubkey   bool       `json:"has_pubkey"`
	LastSeen    *time.Time `json:"last_seen,omitempty"`
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	pubkey, err := optionalPubkey(req.Pubkey)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	res, err := s.auth.Register(r.Context(), auth.RegisterInput{
		Email:       req.Email,
		Password:    req.Password,
		Platform:    req.Platform,
		DisplayName: req.DisplayName,
		Pubkey:      pubkey,
		IP:          clientIP(r),
	})
	if err != nil {
		s.writeAuthError(w, err)
		return
	}
	s.setAuthCookies(w, res)
	httpx.WriteJSON(w, http.StatusCreated, authResultToResp(res, true))
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginReq
	if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	pubkey, err := optionalPubkey(req.Pubkey)
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	var deviceID *uuid.UUID
	if req.DeviceID != "" {
		id, perr := uuid.Parse(req.DeviceID)
		if perr != nil {
			httpx.BadRequest(w, "device_id must be a valid id")
			return
		}
		deviceID = &id
	}
	res, err := s.auth.Login(r.Context(), auth.LoginInput{
		Email:       req.Email,
		Password:    req.Password,
		Platform:    req.Platform,
		DisplayName: req.DisplayName,
		DeviceID:    deviceID,
		Pubkey:      pubkey,
		IP:          clientIP(r),
	})
	if err != nil {
		s.writeAuthError(w, err)
		return
	}
	s.setAuthCookies(w, res)
	httpx.WriteJSON(w, http.StatusOK, authResultToResp(res, true))
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshReq
	// Body is optional when the refresh cookie is present.
	if r.ContentLength != 0 {
		if err := httpx.DecodeJSON(w, r, &req, smallJSONLimit); err != nil {
			httpx.BadRequest(w, err.Error())
			return
		}
	}
	token := req.RefreshToken
	if token == "" {
		if c, err := r.Cookie(httpx.CookieRefresh); err == nil {
			token = c.Value
		}
	}
	res, err := s.auth.Refresh(r.Context(), token, clientIP(r))
	if err != nil {
		s.writeAuthError(w, err)
		return
	}
	s.setAuthCookies(w, res)
	// No user/device echoed on refresh (session already known to client).
	httpx.WriteJSON(w, http.StatusOK, authResultToResp(res, false))
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	if err := s.auth.Logout(r.Context(), a.SessionID, a.UserID, clientIP(r)); err != nil {
		httpx.Internal(w, err)
		return
	}
	s.clearAuthCookies(w)
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "logged_out"})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	user, err := s.store.GetUserByID(r.Context(), a.UserID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, userDTO{ID: user.ID, Email: user.Email})
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	devices, err := s.store.ListDevicesForUser(r.Context(), a.UserID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	out := make([]deviceDTO, 0, len(devices))
	for _, d := range devices {
		out = append(out, deviceToDTO(d))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"devices": out})
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	deviceID, err := parseUUIDParam(r, "deviceID")
	if err != nil {
		httpx.BadRequest(w, err.Error())
		return
	}
	if err := s.auth.RevokeDevice(r.Context(), a.UserID, deviceID, clientIP(r)); err != nil {
		if errors.Is(err, auth.ErrDeviceNotFound) {
			httpx.NotFound(w, "device not found")
			return
		}
		httpx.Internal(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "revoked"})
}

func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	rows, err := s.store.ListActiveSessionsForUser(r.Context(), a.UserID)
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	type sessionDTO struct {
		ID           uuid.UUID `json:"id"`
		DeviceID     uuid.UUID `json:"device_id"`
		Platform     string    `json:"platform"`
		DisplayName  *string   `json:"display_name,omitempty"`
		Current      bool      `json:"current"`
		RotatedAt    time.Time `json:"rotated_at"`
		RefreshUntil time.Time `json:"refresh_expires_at"`
	}
	out := make([]sessionDTO, 0, len(rows))
	for _, s := range rows {
		out = append(out, sessionDTO{
			ID: s.ID, DeviceID: s.DeviceID, Platform: s.Platform,
			DisplayName: s.DisplayName, Current: s.ID == a.SessionID,
			RotatedAt: s.RotatedAt, RefreshUntil: s.RefreshExpiresAt,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

func (s *Server) handleListAudit(w http.ResponseWriter, r *http.Request) {
	a := httpx.MustAuth(r.Context())
	rows, err := s.store.ListAuditForUser(r.Context(), store.ListAuditForUserParams{ActorUserID: &a.UserID, Limit: 100})
	if err != nil {
		httpx.Internal(w, err)
		return
	}
	type auditDTO struct {
		Event string    `json:"event"`
		At    time.Time `json:"at"`
	}
	out := make([]auditDTO, 0, len(rows))
	for _, e := range rows {
		out = append(out, auditDTO{Event: e.Event, At: e.Ts})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"events": out})
}

// --- helpers ---

func (s *Server) writeAuthError(w http.ResponseWriter, err error) {
	var locked *auth.LockedError
	switch {
	case errors.As(err, &locked):
		w.Header().Set("Retry-After", strconv.Itoa(int(locked.RetryAfter.Seconds())))
		httpx.WriteError(w, http.StatusTooManyRequests, httpx.CodeLocked, locked.Reason)
	case errors.Is(err, auth.ErrEmailTaken):
		httpx.Conflict(w, "email already registered")
	case errors.Is(err, auth.ErrInvalidCredentials):
		httpx.Unauthorized(w, "invalid email or password")
	case errors.Is(err, auth.ErrRefreshReused):
		httpx.WriteError(w, http.StatusUnauthorized, httpx.CodeUnauthorized, "session revoked; please sign in again")
	case errors.Is(err, auth.ErrRefreshInvalid):
		httpx.Unauthorized(w, "invalid or expired refresh token")
	case errors.Is(err, auth.ErrDeviceNotFound):
		httpx.NotFound(w, "device not found")
	case errors.Is(err, auth.ErrInvalidEmail), errors.Is(err, auth.ErrWeakPassword),
		errors.Is(err, auth.ErrPasswordTooLong), errors.Is(err, auth.ErrInvalidPlatform):
		httpx.WriteError(w, http.StatusBadRequest, httpx.CodeValidation, err.Error())
	default:
		httpx.Internal(w, err)
	}
}

// Cookies always set HttpOnly + SameSite=Lax; the Secure flag is config-driven
// (true in production, false only for local http). gosec G124 wants a literal
// true which would break local dev, so the correct-by-config sites are annotated.
func (s *Server) setAuthCookies(w http.ResponseWriter, res *auth.Result) {
	secure := s.cfg.SecureCookies
	http.SetCookie(w, &http.Cookie{ // #nosec G124 -- Secure from config; HttpOnly+SameSite always set
		Name: httpx.CookieAccess, Value: res.AccessToken, Path: "/",
		HttpOnly: true, Secure: secure, SameSite: http.SameSiteLaxMode,
		Expires: res.AccessExpiresAt,
	})
	http.SetCookie(w, &http.Cookie{ // #nosec G124 -- Secure from config; HttpOnly+SameSite always set
		Name: httpx.CookieRefresh, Value: res.RefreshToken, Path: httpx.RefreshPath,
		HttpOnly: true, Secure: secure, SameSite: http.SameSiteLaxMode,
		Expires: res.RefreshExpiresAt,
	})
}

func (s *Server) clearAuthCookies(w http.ResponseWriter) {
	secure := s.cfg.SecureCookies
	http.SetCookie(w, &http.Cookie{Name: httpx.CookieAccess, Value: "", Path: "/", HttpOnly: true, Secure: secure, SameSite: http.SameSiteLaxMode, MaxAge: -1})                // #nosec G124 -- cleared cookie; Secure from config
	http.SetCookie(w, &http.Cookie{Name: httpx.CookieRefresh, Value: "", Path: httpx.RefreshPath, HttpOnly: true, Secure: secure, SameSite: http.SameSiteLaxMode, MaxAge: -1}) // #nosec G124 -- cleared cookie; Secure from config
}

func authResultToResp(res *auth.Result, includeIdentity bool) authResp {
	out := authResp{
		AccessToken:      res.AccessToken,
		RefreshToken:     res.RefreshToken,
		AccessExpiresAt:  res.AccessExpiresAt,
		RefreshExpiresAt: res.RefreshExpiresAt,
	}
	if includeIdentity {
		out.User = &userDTO{ID: res.User.ID, Email: res.User.Email}
		d := deviceToDTO(res.Device)
		out.Device = &d
	}
	return out
}

func deviceToDTO(d store.Device) deviceDTO {
	return deviceDTO{
		ID: d.ID, Platform: d.Platform, DisplayName: d.DisplayName,
		HasPubkey: len(d.Pubkey) > 0, LastSeen: d.LastSeen,
	}
}

func optionalPubkey(b64 string) ([]byte, error) {
	if b64 == "" {
		return nil, nil
	}
	pk, err := decodeBlob("pubkey", b64, 64)
	if err != nil {
		return nil, err
	}
	if len(pk) != 32 {
		return nil, errors.New("pubkey must be 32 bytes")
	}
	return pk, nil
}

package store

import (
	"context"
	"strings"
	"time"

	"github.com/google/uuid"
)

// sqNow is the SQLite expression for "the current UTC instant" in the canonical
// fixed-width form the schema stores. It replaces inline now() in SET clauses
// (Postgres now() has no SQLite equivalent). Predicate cutoffs (WHERE ... < now
// - interval) are Go-computed instead and bound as parameters, so the retention
// clock is testable and the value width matches stored timestamps exactly.
const sqNow = `strftime('%Y-%m-%dT%H:%M:%fZ','now')`

// bb binds a []byte, mapping a nil slice to SQL NULL (not an empty blob) so
// nullable BLOB columns (name_enc, profile_enc, pubkey, viewer_token_hash,
// audit detail) round-trip nil correctly.
func bb(b []byte) any {
	if b == nil {
		return nil
	}
	return b
}

// nowUTC is the wall clock used for Go-computed predicate cutoffs.
func nowUTC() time.Time { return time.Now().UTC() }

// ============================ users.sql ============================

func (q *sqliteQueries) CreateUser(ctx context.Context, arg CreateUserParams) (User, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO users (id, email, pass_hash) VALUES (?, ?, ?)
		 RETURNING id, email, pass_hash, created_at, updated_at`,
		uv(id), arg.Email, arg.PassHash)
	var i User
	err := row.Scan(suuid(&i.ID), &i.Email, &i.PassHash, stime(&i.CreatedAt), stime(&i.UpdatedAt))
	return i, err
}

func (q *sqliteQueries) EmailExists(ctx context.Context, email string) (bool, error) {
	row := q.db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE email = ?)`, email)
	var exists bool
	err := row.Scan(sbool(&exists))
	return exists, err
}

func (q *sqliteQueries) GetUserByEmail(ctx context.Context, email string) (User, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT id, email, pass_hash, created_at, updated_at FROM users WHERE email = ?`, email)
	var i User
	err := row.Scan(suuid(&i.ID), &i.Email, &i.PassHash, stime(&i.CreatedAt), stime(&i.UpdatedAt))
	return i, err
}

func (q *sqliteQueries) GetUserByID(ctx context.Context, id uuid.UUID) (User, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT id, email, pass_hash, created_at, updated_at FROM users WHERE id = ?`, uv(id))
	var i User
	err := row.Scan(suuid(&i.ID), &i.Email, &i.PassHash, stime(&i.CreatedAt), stime(&i.UpdatedAt))
	return i, err
}

func (q *sqliteQueries) UpdateUserPassword(ctx context.Context, arg UpdateUserPasswordParams) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE users SET pass_hash = ?, updated_at = `+sqNow+` WHERE id = ?`,
		arg.PassHash, uv(arg.ID))
	return err
}

// ============================ devices.sql ============================

const deviceCols = `id, user_id, platform, display_name, pubkey, push_token, created_at, last_seen`

func scanDevice(s interface{ Scan(...any) error }, i *Device) error {
	return s.Scan(suuid(&i.ID), suuid(&i.UserID), &i.Platform, &i.DisplayName, &i.Pubkey,
		&i.PushToken, stime(&i.CreatedAt), snTime(&i.LastSeen))
}

func (q *sqliteQueries) CreateDevice(ctx context.Context, arg CreateDeviceParams) (Device, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO devices (id, user_id, platform, display_name, pubkey) VALUES (?, ?, ?, ?, ?)
		 RETURNING `+deviceCols,
		uv(id), uv(arg.UserID), arg.Platform, arg.DisplayName, bb(arg.Pubkey))
	var i Device
	err := scanDevice(row, &i)
	return i, err
}

func (q *sqliteQueries) DeleteDevice(ctx context.Context, arg DeleteDeviceParams) error {
	_, err := q.db.ExecContext(ctx, `DELETE FROM devices WHERE id = ? AND user_id = ?`,
		uv(arg.ID), uv(arg.UserID))
	return err
}

func (q *sqliteQueries) GetDevice(ctx context.Context, id uuid.UUID) (Device, error) {
	row := q.db.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM devices WHERE id = ?`, uv(id))
	var i Device
	err := scanDevice(row, &i)
	return i, err
}

func (q *sqliteQueries) GetDeviceForUser(ctx context.Context, arg GetDeviceForUserParams) (Device, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+deviceCols+` FROM devices WHERE id = ? AND user_id = ?`, uv(arg.ID), uv(arg.UserID))
	var i Device
	err := scanDevice(row, &i)
	return i, err
}

func (q *sqliteQueries) ListCircleDevices(ctx context.Context, circleID uuid.UUID) ([]Device, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT d.id, d.user_id, d.platform, d.display_name, d.pubkey, d.push_token, d.created_at, d.last_seen
		 FROM devices d JOIN circle_members cm ON cm.user_id = d.user_id
		 WHERE cm.circle_id = ? ORDER BY d.created_at`, uv(circleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Device{}
	for rows.Next() {
		var i Device
		if err := scanDevice(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) ListDevicesForUser(ctx context.Context, userID uuid.UUID) ([]Device, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+deviceCols+` FROM devices WHERE user_id = ? ORDER BY created_at`, uv(userID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Device{}
	for rows.Next() {
		var i Device
		if err := scanDevice(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) SetDevicePubkey(ctx context.Context, arg SetDevicePubkeyParams) error {
	_, err := q.db.ExecContext(ctx, `UPDATE devices SET pubkey = ? WHERE id = ?`, bb(arg.Pubkey), uv(arg.ID))
	return err
}

func (q *sqliteQueries) SetDevicePushToken(ctx context.Context, arg SetDevicePushTokenParams) error {
	_, err := q.db.ExecContext(ctx, `UPDATE devices SET push_token = ? WHERE id = ?`, arg.PushToken, uv(arg.ID))
	return err
}

func (q *sqliteQueries) TouchDevice(ctx context.Context, id uuid.UUID) error {
	_, err := q.db.ExecContext(ctx, `UPDATE devices SET last_seen = `+sqNow+` WHERE id = ?`, uv(id))
	return err
}

// ============================ circles.sql ============================

const circleCols = `id, name_enc, retention_days, key_epoch, created_by, created_at`

func scanCircle(s interface{ Scan(...any) error }, i *Circle) error {
	return s.Scan(suuid(&i.ID), &i.NameEnc, &i.RetentionDays, &i.KeyEpoch, suuid(&i.CreatedBy), stime(&i.CreatedAt))
}

const memberCols = `circle_id, user_id, role, precision_mode, joined_at, profile_enc`

func scanMember(s interface{ Scan(...any) error }, i *CircleMember) error {
	return s.Scan(suuid(&i.CircleID), suuid(&i.UserID), &i.Role, &i.PrecisionMode, stime(&i.JoinedAt), &i.ProfileEnc)
}

func (q *sqliteQueries) AddMember(ctx context.Context, arg AddMemberParams) (CircleMember, error) {
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO circle_members (circle_id, user_id, role, precision_mode)
		 VALUES (?, ?, ?, 'precise')
		 ON CONFLICT (circle_id, user_id) DO UPDATE SET role = excluded.role
		 RETURNING `+memberCols,
		uv(arg.CircleID), uv(arg.UserID), arg.Role)
	var i CircleMember
	err := scanMember(row, &i)
	return i, err
}

func (q *sqliteQueries) AllCircleRetention(ctx context.Context) ([]AllCircleRetentionRow, error) {
	rows, err := q.db.QueryContext(ctx, `SELECT id, retention_days FROM circles`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []AllCircleRetentionRow{}
	for rows.Next() {
		var i AllCircleRetentionRow
		if err := rows.Scan(suuid(&i.ID), &i.RetentionDays); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) BumpCircleKeyEpoch(ctx context.Context, id uuid.UUID) (Circle, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE circles SET key_epoch = key_epoch + 1 WHERE id = ? RETURNING `+circleCols, uv(id))
	var i Circle
	err := scanCircle(row, &i)
	return i, err
}

func (q *sqliteQueries) CountOwners(ctx context.Context, circleID uuid.UUID) (int64, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT count(*) FROM circle_members WHERE circle_id = ? AND role = 'owner'`, uv(circleID))
	var count int64
	err := row.Scan(&count)
	return count, err
}

func (q *sqliteQueries) CreateCircle(ctx context.Context, arg CreateCircleParams) (Circle, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO circles (id, name_enc, retention_days, created_by) VALUES (?, ?, ?, ?)
		 RETURNING `+circleCols,
		uv(id), bb(arg.NameEnc), arg.RetentionDays, uv(arg.CreatedBy))
	var i Circle
	err := scanCircle(row, &i)
	return i, err
}

func (q *sqliteQueries) DeleteCircle(ctx context.Context, id uuid.UUID) error {
	_, err := q.db.ExecContext(ctx, `DELETE FROM circles WHERE id = ?`, uv(id))
	return err
}

func (q *sqliteQueries) GetCircle(ctx context.Context, id uuid.UUID) (Circle, error) {
	row := q.db.QueryRowContext(ctx, `SELECT `+circleCols+` FROM circles WHERE id = ?`, uv(id))
	var i Circle
	err := scanCircle(row, &i)
	return i, err
}

func (q *sqliteQueries) GetMembership(ctx context.Context, arg GetMembershipParams) (CircleMember, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+memberCols+` FROM circle_members WHERE circle_id = ? AND user_id = ?`,
		uv(arg.CircleID), uv(arg.UserID))
	var i CircleMember
	err := scanMember(row, &i)
	return i, err
}

func (q *sqliteQueries) ListCirclesForUser(ctx context.Context, userID uuid.UUID) ([]ListCirclesForUserRow, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT c.id, c.name_enc, c.retention_days, c.key_epoch, c.created_by, c.created_at, cm.role, cm.precision_mode
		 FROM circles c JOIN circle_members cm ON cm.circle_id = c.id
		 WHERE cm.user_id = ? ORDER BY c.created_at`, uv(userID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ListCirclesForUserRow{}
	for rows.Next() {
		var i ListCirclesForUserRow
		if err := rows.Scan(suuid(&i.ID), &i.NameEnc, &i.RetentionDays, &i.KeyEpoch,
			suuid(&i.CreatedBy), stime(&i.CreatedAt), &i.Role, &i.PrecisionMode); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) ListMembers(ctx context.Context, circleID uuid.UUID) ([]ListMembersRow, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT cm.circle_id, cm.user_id, cm.role, cm.precision_mode, cm.joined_at, cm.profile_enc, u.email
		 FROM circle_members cm JOIN users u ON u.id = cm.user_id
		 WHERE cm.circle_id = ? ORDER BY cm.joined_at`, uv(circleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ListMembersRow{}
	for rows.Next() {
		var i ListMembersRow
		if err := rows.Scan(suuid(&i.CircleID), suuid(&i.UserID), &i.Role, &i.PrecisionMode,
			stime(&i.JoinedAt), &i.ProfileEnc, &i.Email); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) RemoveMember(ctx context.Context, arg RemoveMemberParams) error {
	_, err := q.db.ExecContext(ctx, `DELETE FROM circle_members WHERE circle_id = ? AND user_id = ?`,
		uv(arg.CircleID), uv(arg.UserID))
	return err
}

func (q *sqliteQueries) SetMemberProfile(ctx context.Context, arg SetMemberProfileParams) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE circle_members SET profile_enc = ? WHERE circle_id = ? AND user_id = ?`,
		bb(arg.ProfileEnc), uv(arg.CircleID), uv(arg.UserID))
	return err
}

func (q *sqliteQueries) SetMemberRole(ctx context.Context, arg SetMemberRoleParams) (CircleMember, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE circle_members SET role = ? WHERE circle_id = ? AND user_id = ? RETURNING `+memberCols,
		arg.Role, uv(arg.CircleID), uv(arg.UserID))
	var i CircleMember
	err := scanMember(row, &i)
	return i, err
}

func (q *sqliteQueries) SetPrecisionMode(ctx context.Context, arg SetPrecisionModeParams) (CircleMember, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE circle_members SET precision_mode = ? WHERE circle_id = ? AND user_id = ? RETURNING `+memberCols,
		arg.PrecisionMode, uv(arg.CircleID), uv(arg.UserID))
	var i CircleMember
	err := scanMember(row, &i)
	return i, err
}

func (q *sqliteQueries) UpdateCircleName(ctx context.Context, arg UpdateCircleNameParams) (Circle, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE circles SET name_enc = ? WHERE id = ? RETURNING `+circleCols, bb(arg.NameEnc), uv(arg.ID))
	var i Circle
	err := scanCircle(row, &i)
	return i, err
}

func (q *sqliteQueries) UpdateCircleRetention(ctx context.Context, arg UpdateCircleRetentionParams) (Circle, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE circles SET retention_days = ? WHERE id = ? RETURNING `+circleCols, arg.RetentionDays, uv(arg.ID))
	var i Circle
	err := scanCircle(row, &i)
	return i, err
}

// ============================ invites.sql ============================

const inviteCols = `id, circle_id, created_by, role, max_uses, uses, expires_at, status, created_at`

func scanInvite(s interface{ Scan(...any) error }, i *Invite) error {
	return s.Scan(suuid(&i.ID), suuid(&i.CircleID), suuid(&i.CreatedBy), &i.Role, &i.MaxUses,
		&i.Uses, stime(&i.ExpiresAt), &i.Status, stime(&i.CreatedAt))
}

func (q *sqliteQueries) ConsumeInvite(ctx context.Context, id uuid.UUID) (Invite, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE invites SET uses = uses + 1
		 WHERE id = ? AND status = 'active' AND expires_at > ? AND uses < max_uses
		 RETURNING `+inviteCols,
		uv(id), tv(nowUTC()))
	var i Invite
	err := scanInvite(row, &i)
	return i, err
}

func (q *sqliteQueries) CountRecentInvitesByUser(ctx context.Context, createdBy uuid.UUID) (int64, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT count(*) FROM invites WHERE created_by = ? AND created_at > ?`,
		uv(createdBy), tv(nowUTC().Add(-time.Hour)))
	var count int64
	err := row.Scan(&count)
	return count, err
}

func (q *sqliteQueries) CreateInvite(ctx context.Context, arg CreateInviteParams) (Invite, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO invites (id, circle_id, created_by, role, max_uses, expires_at) VALUES (?, ?, ?, ?, ?, ?)
		 RETURNING `+inviteCols,
		uv(id), uv(arg.CircleID), uv(arg.CreatedBy), arg.Role, arg.MaxUses, tv(arg.ExpiresAt))
	var i Invite
	err := scanInvite(row, &i)
	return i, err
}

func (q *sqliteQueries) GetInvite(ctx context.Context, id uuid.UUID) (Invite, error) {
	row := q.db.QueryRowContext(ctx, `SELECT `+inviteCols+` FROM invites WHERE id = ?`, uv(id))
	var i Invite
	err := scanInvite(row, &i)
	return i, err
}

func (q *sqliteQueries) ListInvitesForCircle(ctx context.Context, circleID uuid.UUID) ([]Invite, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+inviteCols+` FROM invites WHERE circle_id = ? AND status = 'active' AND expires_at > ?
		 ORDER BY created_at DESC`, uv(circleID), tv(nowUTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Invite{}
	for rows.Next() {
		var i Invite
		if err := scanInvite(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) RevokeInvite(ctx context.Context, arg RevokeInviteParams) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE invites SET status = 'revoked' WHERE id = ? AND circle_id = ?`, uv(arg.ID), uv(arg.CircleID))
	return err
}

// ============================ key_envelopes.sql ============================

const envelopeCols = `id, circle_id, recipient_device_id, sender_device_id, ciphertext, key_epoch, created_at, consumed_at`

func scanEnvelope(s interface{ Scan(...any) error }, i *KeyEnvelope) error {
	return s.Scan(suuid(&i.ID), suuid(&i.CircleID), suuid(&i.RecipientDeviceID), snUUID(&i.SenderDeviceID),
		&i.Ciphertext, &i.KeyEpoch, stime(&i.CreatedAt), snTime(&i.ConsumedAt))
}

func (q *sqliteQueries) CreateKeyEnvelope(ctx context.Context, arg CreateKeyEnvelopeParams) (KeyEnvelope, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO key_envelopes (id, circle_id, recipient_device_id, sender_device_id, ciphertext, key_epoch)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT (circle_id, recipient_device_id, key_epoch) DO UPDATE
		 SET ciphertext = excluded.ciphertext, sender_device_id = excluded.sender_device_id,
		     created_at = `+sqNow+`, consumed_at = NULL
		 RETURNING `+envelopeCols,
		uv(id), uv(arg.CircleID), uv(arg.RecipientDeviceID), uvp(arg.SenderDeviceID), bb(arg.Ciphertext), arg.KeyEpoch)
	var i KeyEnvelope
	err := scanEnvelope(row, &i)
	return i, err
}

func (q *sqliteQueries) MarkEnvelopeConsumed(ctx context.Context, arg MarkEnvelopeConsumedParams) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE key_envelopes SET consumed_at = `+sqNow+`
		 WHERE id = ? AND recipient_device_id = ? AND consumed_at IS NULL`,
		uv(arg.ID), uv(arg.RecipientDeviceID))
	return err
}

func (q *sqliteQueries) PendingEnvelopesForDevice(ctx context.Context, recipientDeviceID uuid.UUID) ([]KeyEnvelope, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+envelopeCols+` FROM key_envelopes WHERE recipient_device_id = ? AND consumed_at IS NULL
		 ORDER BY created_at LIMIT 500`, uv(recipientDeviceID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []KeyEnvelope{}
	for rows.Next() {
		var i KeyEnvelope
		if err := scanEnvelope(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) PruneKeyEnvelopes(ctx context.Context) (int64, error) {
	now := nowUTC()
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM key_envelopes
		 WHERE (consumed_at IS NOT NULL AND consumed_at < ?)
		    OR (consumed_at IS NULL AND created_at < ?)`,
		tv(now.AddDate(0, 0, -7)), tv(now.AddDate(0, 0, -30)))
	return rowsAffected(res, err)
}

// ============================ sessions.sql ============================

const sessionCols = `id, user_id, device_id, access_token_hash, refresh_token_hash, prev_refresh_hash, access_expires_at, refresh_expires_at, revoked_at, created_at, rotated_at`

func scanSession(s interface{ Scan(...any) error }, i *Session) error {
	return s.Scan(suuid(&i.ID), suuid(&i.UserID), suuid(&i.DeviceID), &i.AccessTokenHash, &i.RefreshTokenHash,
		&i.PrevRefreshHash, stime(&i.AccessExpiresAt), stime(&i.RefreshExpiresAt), snTime(&i.RevokedAt),
		stime(&i.CreatedAt), stime(&i.RotatedAt))
}

func (q *sqliteQueries) CreateSession(ctx context.Context, arg CreateSessionParams) (Session, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO sessions (id, user_id, device_id, access_token_hash, refresh_token_hash, access_expires_at, refresh_expires_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING `+sessionCols,
		uv(id), uv(arg.UserID), uv(arg.DeviceID), arg.AccessTokenHash, arg.RefreshTokenHash,
		tv(arg.AccessExpiresAt), tv(arg.RefreshExpiresAt))
	var i Session
	err := scanSession(row, &i)
	return i, err
}

func (q *sqliteQueries) DeleteExpiredSessions(ctx context.Context) (int64, error) {
	cutoff := tv(nowUTC().Add(-24 * time.Hour))
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM sessions
		 WHERE refresh_expires_at < ?
		    OR (revoked_at IS NOT NULL AND revoked_at < ?)`, cutoff, cutoff)
	return rowsAffected(res, err)
}

func (q *sqliteQueries) GetSessionByAccessHash(ctx context.Context, accessTokenHash string) (Session, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+sessionCols+` FROM sessions
		 WHERE access_token_hash = ? AND revoked_at IS NULL AND access_expires_at > ?`,
		accessTokenHash, tv(nowUTC()))
	var i Session
	err := scanSession(row, &i)
	return i, err
}

func (q *sqliteQueries) GetSessionByPrevRefreshHash(ctx context.Context, prevRefreshHash *string) (Session, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+sessionCols+` FROM sessions WHERE prev_refresh_hash = ? AND revoked_at IS NULL`,
		prevRefreshHash)
	var i Session
	err := scanSession(row, &i)
	return i, err
}

func (q *sqliteQueries) GetSessionByRefreshHash(ctx context.Context, refreshTokenHash string) (Session, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+sessionCols+` FROM sessions
		 WHERE refresh_token_hash = ? AND revoked_at IS NULL AND refresh_expires_at > ?`,
		refreshTokenHash, tv(nowUTC()))
	var i Session
	err := scanSession(row, &i)
	return i, err
}

func (q *sqliteQueries) ListActiveSessionsForUser(ctx context.Context, userID uuid.UUID) ([]ListActiveSessionsForUserRow, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT s.id, s.user_id, s.device_id, s.access_token_hash, s.refresh_token_hash, s.prev_refresh_hash,
		        s.access_expires_at, s.refresh_expires_at, s.revoked_at, s.created_at, s.rotated_at, d.platform, d.display_name
		 FROM sessions s JOIN devices d ON d.id = s.device_id
		 WHERE s.user_id = ? AND s.revoked_at IS NULL AND s.refresh_expires_at > ?
		 ORDER BY s.rotated_at DESC`, uv(userID), tv(nowUTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ListActiveSessionsForUserRow{}
	for rows.Next() {
		var i ListActiveSessionsForUserRow
		if err := rows.Scan(suuid(&i.ID), suuid(&i.UserID), suuid(&i.DeviceID), &i.AccessTokenHash,
			&i.RefreshTokenHash, &i.PrevRefreshHash, stime(&i.AccessExpiresAt), stime(&i.RefreshExpiresAt),
			snTime(&i.RevokedAt), stime(&i.CreatedAt), stime(&i.RotatedAt), &i.Platform, &i.DisplayName); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) RevokeSession(ctx context.Context, id uuid.UUID) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE sessions SET revoked_at = `+sqNow+` WHERE id = ? AND revoked_at IS NULL`, uv(id))
	return err
}

func (q *sqliteQueries) RevokeSessionsForDevice(ctx context.Context, deviceID uuid.UUID) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE sessions SET revoked_at = `+sqNow+` WHERE device_id = ? AND revoked_at IS NULL`, uv(deviceID))
	return err
}

func (q *sqliteQueries) RevokeSessionsForUser(ctx context.Context, userID uuid.UUID) error {
	_, err := q.db.ExecContext(ctx,
		`UPDATE sessions SET revoked_at = `+sqNow+` WHERE user_id = ? AND revoked_at IS NULL`, uv(userID))
	return err
}

func (q *sqliteQueries) RotateSession(ctx context.Context, arg RotateSessionParams) (Session, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE sessions SET
		     access_token_hash = ?, refresh_token_hash = ?, prev_refresh_hash = ?,
		     access_expires_at = ?, refresh_expires_at = ?, rotated_at = `+sqNow+`
		 WHERE id = ? AND refresh_token_hash = ? AND revoked_at IS NULL
		 RETURNING `+sessionCols,
		arg.AccessTokenHash, arg.RefreshTokenHash, arg.OldRefreshHash,
		tv(arg.AccessExpiresAt), tv(arg.RefreshExpiresAt), uv(arg.ID), arg.OldRefreshHash)
	var i Session
	err := scanSession(row, &i)
	return i, err
}

// ============================ share.sql ============================

const shareCols = `id, user_id, created_at, expires_at, revoked_at, viewer_token_hash, viewer_bound_at`

func scanShare(s interface{ Scan(...any) error }, i *ShareSession) error {
	return s.Scan(suuid(&i.ID), suuid(&i.UserID), stime(&i.CreatedAt), stime(&i.ExpiresAt),
		snTime(&i.RevokedAt), &i.ViewerTokenHash, snTime(&i.ViewerBoundAt))
}

func (q *sqliteQueries) BindShareViewer(ctx context.Context, arg BindShareViewerParams) (ShareSession, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE share_sessions SET viewer_token_hash = ?, viewer_bound_at = `+sqNow+`
		 WHERE id = ? AND viewer_token_hash IS NULL RETURNING `+shareCols,
		bb(arg.ViewerTokenHash), uv(arg.ID))
	var i ShareSession
	err := scanShare(row, &i)
	return i, err
}

func (q *sqliteQueries) CreateShareSession(ctx context.Context, arg CreateShareSessionParams) (ShareSession, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO share_sessions (id, user_id, expires_at) VALUES (?, ?, ?) RETURNING `+shareCols,
		uv(id), uv(arg.UserID), tv(arg.ExpiresAt))
	var i ShareSession
	err := scanShare(row, &i)
	return i, err
}

func (q *sqliteQueries) GetSharePosition(ctx context.Context, sessionID uuid.UUID) (SharePosition, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT session_id, nonce, ciphertext, captured_at, updated_at FROM share_positions WHERE session_id = ?`,
		uv(sessionID))
	var i SharePosition
	err := row.Scan(suuid(&i.SessionID), &i.Nonce, &i.Ciphertext, stime(&i.CapturedAt), stime(&i.UpdatedAt))
	return i, err
}

func (q *sqliteQueries) GetShareSession(ctx context.Context, id uuid.UUID) (ShareSession, error) {
	row := q.db.QueryRowContext(ctx, `SELECT `+shareCols+` FROM share_sessions WHERE id = ?`, uv(id))
	var i ShareSession
	err := scanShare(row, &i)
	return i, err
}

func (q *sqliteQueries) GetShareSessionForOwner(ctx context.Context, arg GetShareSessionForOwnerParams) (ShareSession, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT `+shareCols+` FROM share_sessions WHERE id = ? AND user_id = ?`, uv(arg.ID), uv(arg.UserID))
	var i ShareSession
	err := scanShare(row, &i)
	return i, err
}

func (q *sqliteQueries) ListShareSessionsForUser(ctx context.Context, userID uuid.UUID) ([]ShareSession, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+shareCols+` FROM share_sessions WHERE user_id = ? AND expires_at > ? ORDER BY created_at DESC`,
		uv(userID), tv(nowUTC()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ShareSession{}
	for rows.Next() {
		var i ShareSession
		if err := scanShare(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) PruneShareSessions(ctx context.Context, graceHours int32) (int64, error) {
	cutoff := tv(nowUTC().Add(-time.Duration(graceHours) * time.Hour))
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM share_sessions
		 WHERE expires_at < ?
		    OR (revoked_at IS NOT NULL AND revoked_at < ?)`, cutoff, cutoff)
	return rowsAffected(res, err)
}

func (q *sqliteQueries) RevokeShareSession(ctx context.Context, arg RevokeShareSessionParams) (ShareSession, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE share_sessions SET revoked_at = COALESCE(revoked_at, `+sqNow+`)
		 WHERE id = ? AND user_id = ? RETURNING `+shareCols,
		uv(arg.ID), uv(arg.UserID))
	var i ShareSession
	err := scanShare(row, &i)
	return i, err
}

func (q *sqliteQueries) UpsertSharePosition(ctx context.Context, arg UpsertSharePositionParams) error {
	_, err := q.db.ExecContext(ctx,
		`INSERT INTO share_positions (session_id, nonce, ciphertext, captured_at) VALUES (?, ?, ?, ?)
		 ON CONFLICT (session_id) DO UPDATE SET
		     nonce = excluded.nonce, ciphertext = excluded.ciphertext,
		     captured_at = excluded.captured_at, updated_at = `+sqNow,
		uv(arg.SessionID), bb(arg.Nonce), bb(arg.Ciphertext), tv(arg.CapturedAt))
	return err
}

// ============================ sos.sql ============================

const sosCols = `id, circle_id, device_id, ciphertext, created_at, resolved_at, resolved_by`

func scanSOS(s interface{ Scan(...any) error }, i *SosEvent) error {
	return s.Scan(suuid(&i.ID), suuid(&i.CircleID), snUUID(&i.DeviceID), &i.Ciphertext,
		stime(&i.CreatedAt), snTime(&i.ResolvedAt), snUUID(&i.ResolvedBy))
}

func (q *sqliteQueries) CreateSOS(ctx context.Context, arg CreateSOSParams) (SosEvent, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO sos_events (id, circle_id, device_id, ciphertext) VALUES (?, ?, ?, ?) RETURNING `+sosCols,
		uv(id), uv(arg.CircleID), uvp(arg.DeviceID), bb(arg.Ciphertext))
	var i SosEvent
	err := scanSOS(row, &i)
	return i, err
}

func (q *sqliteQueries) GetSOS(ctx context.Context, id uuid.UUID) (SosEvent, error) {
	row := q.db.QueryRowContext(ctx, `SELECT `+sosCols+` FROM sos_events WHERE id = ?`, uv(id))
	var i SosEvent
	err := scanSOS(row, &i)
	return i, err
}

func (q *sqliteQueries) ListActiveSOS(ctx context.Context, circleID uuid.UUID) ([]SosEvent, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+sosCols+` FROM sos_events WHERE circle_id = ? AND resolved_at IS NULL ORDER BY created_at DESC`,
		uv(circleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []SosEvent{}
	for rows.Next() {
		var i SosEvent
		if err := scanSOS(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) PruneResolvedSOS(ctx context.Context, resolvedAt *time.Time) (int64, error) {
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM sos_events WHERE resolved_at IS NOT NULL AND resolved_at < ?`, tvp(resolvedAt))
	return rowsAffected(res, err)
}

func (q *sqliteQueries) ResolveSOS(ctx context.Context, arg ResolveSOSParams) (SosEvent, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE sos_events SET resolved_at = `+sqNow+`, resolved_by = ?
		 WHERE id = ? AND circle_id = ? AND resolved_at IS NULL RETURNING `+sosCols,
		uvp(arg.ResolvedBy), uv(arg.ID), uv(arg.CircleID))
	var i SosEvent
	err := scanSOS(row, &i)
	return i, err
}

// ============================ places.sql ============================

const placeCols = `id, circle_id, ciphertext, version, deleted, updated_by, updated_at, created_at, created_by`

func scanPlace(s interface{ Scan(...any) error }, i *PlacesEnc) error {
	return s.Scan(suuid(&i.ID), suuid(&i.CircleID), &i.Ciphertext, &i.Version, sbool(&i.Deleted),
		snUUID(&i.UpdatedBy), stime(&i.UpdatedAt), stime(&i.CreatedAt), snUUID(&i.CreatedBy))
}

func (q *sqliteQueries) CreatePlace(ctx context.Context, arg CreatePlaceParams) (PlacesEnc, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO places_enc (id, circle_id, ciphertext, version, created_by, updated_by)
		 VALUES (?, ?, ?, 1, ?, ?) RETURNING `+placeCols,
		uv(id), uv(arg.CircleID), bb(arg.Ciphertext), uvp(arg.AuthorID), uvp(arg.AuthorID))
	var i PlacesEnc
	err := scanPlace(row, &i)
	return i, err
}

func (q *sqliteQueries) ListPlaces(ctx context.Context, circleID uuid.UUID) ([]PlacesEnc, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+placeCols+` FROM places_enc WHERE circle_id = ? AND deleted = 0 ORDER BY created_at`,
		uv(circleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []PlacesEnc{}
	for rows.Next() {
		var i PlacesEnc
		if err := scanPlace(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) PrunePlaceTombstones(ctx context.Context, updatedAt time.Time) (int64, error) {
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM places_enc WHERE deleted = 1 AND updated_at < ?`, tv(updatedAt))
	return rowsAffected(res, err)
}

func (q *sqliteQueries) SoftDeletePlace(ctx context.Context, arg SoftDeletePlaceParams) (PlacesEnc, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE places_enc SET deleted = 1, version = version + 1, updated_by = ?, updated_at = `+sqNow+`
		 WHERE id = ? AND circle_id = ? AND deleted = 0 RETURNING `+placeCols,
		uvp(arg.UpdatedBy), uv(arg.ID), uv(arg.CircleID))
	var i PlacesEnc
	err := scanPlace(row, &i)
	return i, err
}

func (q *sqliteQueries) UpdatePlace(ctx context.Context, arg UpdatePlaceParams) (PlacesEnc, error) {
	row := q.db.QueryRowContext(ctx,
		`UPDATE places_enc SET ciphertext = ?, version = version + 1, updated_by = ?, updated_at = `+sqNow+`
		 WHERE id = ? AND circle_id = ? AND version = ? AND deleted = 0 RETURNING `+placeCols,
		bb(arg.Ciphertext), uvp(arg.UpdatedBy), uv(arg.ID), uv(arg.CircleID), arg.Version)
	var i PlacesEnc
	err := scanPlace(row, &i)
	return i, err
}

// ============================ mutes.sql ============================

func (q *sqliteQueries) ListMutes(ctx context.Context, arg ListMutesParams) ([]*uuid.UUID, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT muted_user_id FROM notification_mutes WHERE user_id = ? AND circle_id = ? ORDER BY created_at`,
		uv(arg.UserID), uv(arg.CircleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []*uuid.UUID{}
	for rows.Next() {
		var muted *uuid.UUID
		if err := rows.Scan(snUUID(&muted)); err != nil {
			return nil, err
		}
		items = append(items, muted)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) DeleteMutes(ctx context.Context, arg DeleteMutesParams) error {
	_, err := q.db.ExecContext(ctx,
		`DELETE FROM notification_mutes WHERE user_id = ? AND circle_id = ?`, uv(arg.UserID), uv(arg.CircleID))
	return err
}

func (q *sqliteQueries) InsertMute(ctx context.Context, arg InsertMuteParams) error {
	// Bare ON CONFLICT DO NOTHING fires on whichever of the two partial unique
	// indexes (uq_notification_mutes_member / uq_notification_mutes_circle) the
	// row violates — the SQLite reproduction of Postgres' NULLS NOT DISTINCT.
	_, err := q.db.ExecContext(ctx,
		`INSERT INTO notification_mutes (user_id, circle_id, muted_user_id) VALUES (?, ?, ?)
		 ON CONFLICT DO NOTHING`,
		uv(arg.UserID), uv(arg.CircleID), uvp(arg.MutedUserID))
	return err
}

// CountMembersIn expands the Postgres `user_id = ANY($1::uuid[])` array param
// into an `IN (?,?,…)` list, since SQLite has no array type. An empty set can
// never match (count 0), matching `= ANY('{}')`.
func (q *sqliteQueries) CountMembersIn(ctx context.Context, arg CountMembersInParams) (int64, error) {
	if len(arg.UserIds) == 0 {
		return 0, nil
	}
	placeholders := make([]string, len(arg.UserIds))
	args := make([]any, 0, len(arg.UserIds)+1)
	args = append(args, uv(arg.CircleID))
	for i, id := range arg.UserIds {
		placeholders[i] = "?"
		args = append(args, uv(id))
	}
	query := `SELECT count(*) FROM circle_members WHERE circle_id = ? AND user_id IN (` +
		strings.Join(placeholders, ",") + `)`
	row := q.db.QueryRowContext(ctx, query, args...)
	var count int64
	err := row.Scan(&count)
	return count, err
}

// ============================ pings.sql ============================

const pingCols = `id, circle_id, device_id, client_id, nonce, ciphertext, captured_at, received_at, expires_at`

func scanPing(s interface{ Scan(...any) error }, i *Ping) error {
	return s.Scan(suuid(&i.ID), suuid(&i.CircleID), suuid(&i.DeviceID), &i.ClientID, &i.Nonce,
		&i.Ciphertext, stime(&i.CapturedAt), stime(&i.ReceivedAt), snTime(&i.ExpiresAt))
}

func (q *sqliteQueries) CountPingsForCircle(ctx context.Context, circleID uuid.UUID) (int64, error) {
	row := q.db.QueryRowContext(ctx, `SELECT count(*) FROM pings WHERE circle_id = ?`, uv(circleID))
	var count int64
	err := row.Scan(&count)
	return count, err
}

func (q *sqliteQueries) InsertPing(ctx context.Context, arg InsertPingParams) (Ping, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO pings (id, circle_id, device_id, client_id, nonce, ciphertext, captured_at, expires_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT (device_id, client_id, captured_at) DO NOTHING RETURNING `+pingCols,
		uv(id), uv(arg.CircleID), uv(arg.DeviceID), arg.ClientID, bb(arg.Nonce), bb(arg.Ciphertext),
		tv(arg.CapturedAt), tvp(arg.ExpiresAt))
	var i Ping
	err := scanPing(row, &i)
	return i, err
}

// LatestPingsForCircle reproduces Postgres' `DISTINCT ON (device_id) ... ORDER
// BY device_id, captured_at DESC` with a ROW_NUMBER window: rn=1 is the newest
// row per device. The outer `ORDER BY device_id` matches the DISTINCT ON output
// order. Ties at a device's max captured_at resolve arbitrarily on BOTH engines;
// callers (and the equivalence test) seed distinct captured_at per device so the
// picked row is deterministic.
func (q *sqliteQueries) LatestPingsForCircle(ctx context.Context, circleID uuid.UUID) ([]Ping, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT `+pingCols+` FROM (
		     SELECT `+pingCols+`,
		            ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY captured_at DESC) AS rn
		     FROM pings WHERE circle_id = ?
		 ) WHERE rn = 1 ORDER BY device_id`, uv(circleID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Ping{}
	for rows.Next() {
		var i Ping
		if err := scanPing(rows, &i); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

// ============================ misc.sql ============================

func (q *sqliteQueries) CountRecentFailuresByEmail(ctx context.Context, arg CountRecentFailuresByEmailParams) (int64, error) {
	cutoff := tv(nowUTC().Add(-time.Duration(arg.WindowSecs * float64(time.Second))))
	row := q.db.QueryRowContext(ctx,
		`SELECT count(*) FROM login_attempts la
		 WHERE la.email = ? AND la.success = 0 AND la.created_at > ?
		   AND la.created_at > COALESCE(
		         (SELECT max(ok.created_at) FROM login_attempts ok WHERE ok.email = ? AND ok.success = 1), ?)`,
		arg.Email, cutoff, arg.Email, sqliteEpoch)
	var count int64
	err := row.Scan(&count)
	return count, err
}

func (q *sqliteQueries) CountRecentFailuresByIP(ctx context.Context, arg CountRecentFailuresByIPParams) (int64, error) {
	cutoff := tv(nowUTC().Add(-time.Duration(arg.WindowSecs * float64(time.Second))))
	row := q.db.QueryRowContext(ctx,
		`SELECT count(*) FROM login_attempts WHERE ip = ? AND success = 0 AND created_at > ?`,
		arg.Ip, cutoff)
	var count int64
	err := row.Scan(&count)
	return count, err
}

func (q *sqliteQueries) DeleteExpiredPingsForCircle(ctx context.Context, arg DeleteExpiredPingsForCircleParams) (int64, error) {
	cutoff := tv(nowUTC().AddDate(0, 0, -int(arg.RetentionDays)))
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM pings
		 WHERE pings.circle_id = ? AND pings.captured_at < ?
		   AND EXISTS (
		       SELECT 1 FROM pings newer
		       WHERE newer.circle_id = pings.circle_id
		         AND newer.device_id = pings.device_id
		         AND newer.captured_at > pings.captured_at)`,
		uv(arg.CircleID), cutoff)
	return rowsAffected(res, err)
}

func (q *sqliteQueries) DeletePushSubscription(ctx context.Context, arg DeletePushSubscriptionParams) error {
	_, err := q.db.ExecContext(ctx,
		`DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?`, arg.Endpoint, uv(arg.UserID))
	return err
}

func (q *sqliteQueries) DeletePushSubscriptionByID(ctx context.Context, id uuid.UUID) error {
	_, err := q.db.ExecContext(ctx, `DELETE FROM push_subscriptions WHERE id = ?`, uv(id))
	return err
}

// EnsurePingPartitions is a no-op on SQLite: the pings table is not partitioned
// (SQLite has no partitioning), so there is nothing to pre-create. Retention on
// SQLite is DELETE-by-timestamp; see Store.PruneAllPingsBefore and PruneStalePings.
func (q *sqliteQueries) EnsurePingPartitions(ctx context.Context, arg EnsurePingPartitionsParams) error {
	return nil
}

func (q *sqliteQueries) LatestActiveVersion(ctx context.Context, platform string) (AppVersion, error) {
	row := q.db.QueryRowContext(ctx,
		`SELECT id, platform, version_code, version_name, apk_url, sha256, changelog, min_supported, is_active, created_at
		 FROM app_versions WHERE platform = ? AND is_active = 1 ORDER BY version_code DESC LIMIT 1`, platform)
	var i AppVersion
	err := row.Scan(suuid(&i.ID), &i.Platform, &i.VersionCode, &i.VersionName, &i.ApkUrl, &i.Sha256,
		&i.Changelog, &i.MinSupported, sbool(&i.IsActive), stime(&i.CreatedAt))
	return i, err
}

func (q *sqliteQueries) ListAuditForUser(ctx context.Context, arg ListAuditForUserParams) ([]AuditLog, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT id, ts, event, actor_user_id, actor_device_id, circle_id, ip, detail FROM audit_log
		 WHERE actor_user_id = ? ORDER BY ts DESC LIMIT ?`, uvp(arg.ActorUserID), arg.Limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []AuditLog{}
	for rows.Next() {
		var i AuditLog
		if err := rows.Scan(&i.ID, stime(&i.Ts), &i.Event, snUUID(&i.ActorUserID), snUUID(&i.ActorDeviceID),
			snUUID(&i.CircleID), &i.Ip, &i.Detail); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) ListCirclePushSubscriptions(ctx context.Context, arg ListCirclePushSubscriptionsParams) ([]ListCirclePushSubscriptionsRow, error) {
	rows, err := q.db.QueryContext(ctx,
		`SELECT ps.id, ps.user_id, ps.endpoint, ps.p256dh, ps.auth, ps.kind
		 FROM push_subscriptions ps JOIN circle_members cm ON cm.user_id = ps.user_id
		 WHERE cm.circle_id = ? AND ps.user_id <> ?
		   AND NOT EXISTS (
		       SELECT 1 FROM notification_mutes m
		       WHERE m.user_id = ps.user_id AND m.circle_id = ?
		         AND (m.muted_user_id IS NULL OR m.muted_user_id = ?))
		 ORDER BY ps.created_at`,
		uv(arg.CircleID), uv(arg.SenderUserID), uv(arg.CircleID), uv(arg.SenderUserID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ListCirclePushSubscriptionsRow{}
	for rows.Next() {
		var i ListCirclePushSubscriptionsRow
		if err := rows.Scan(suuid(&i.ID), suuid(&i.UserID), &i.Endpoint, &i.P256dh, &i.Auth, &i.Kind); err != nil {
			return nil, err
		}
		items = append(items, i)
	}
	return items, rows.Err()
}

func (q *sqliteQueries) PruneAuditIPs(ctx context.Context, keepDays int32) (int64, error) {
	res, err := q.db.ExecContext(ctx,
		`UPDATE audit_log SET ip = NULL WHERE ip IS NOT NULL AND ts < ?`,
		tv(nowUTC().AddDate(0, 0, -int(keepDays))))
	return rowsAffected(res, err)
}

func (q *sqliteQueries) PruneLoginAttempts(ctx context.Context, keepDays int32) (int64, error) {
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM login_attempts WHERE created_at < ?`, tv(nowUTC().AddDate(0, 0, -int(keepDays))))
	return rowsAffected(res, err)
}

func (q *sqliteQueries) PruneStalePings(ctx context.Context, keepHours int32) (int64, error) {
	cutoff := tv(nowUTC().Add(-time.Duration(keepHours) * time.Hour))
	res, err := q.db.ExecContext(ctx,
		`DELETE FROM pings
		 WHERE pings.captured_at < ?
		   AND EXISTS (
		       SELECT 1 FROM pings newer
		       WHERE newer.circle_id = pings.circle_id
		         AND newer.device_id = pings.device_id
		         AND newer.captured_at > pings.captured_at)`, cutoff)
	return rowsAffected(res, err)
}

func (q *sqliteQueries) RecordLoginAttempt(ctx context.Context, arg RecordLoginAttemptParams) error {
	_, err := q.db.ExecContext(ctx,
		`INSERT INTO login_attempts (email, ip, success) VALUES (?, ?, ?)`,
		arg.Email, arg.Ip, bv(arg.Success))
	return err
}

func (q *sqliteQueries) UpsertAppVersion(ctx context.Context, arg UpsertAppVersionParams) (AppVersion, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO app_versions (id, platform, version_code, version_name, apk_url, sha256, changelog, min_supported, is_active)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
		 ON CONFLICT (platform, version_code) DO UPDATE SET
		     version_name = excluded.version_name, apk_url = excluded.apk_url, sha256 = excluded.sha256,
		     changelog = excluded.changelog, min_supported = excluded.min_supported, is_active = 1
		 RETURNING id, platform, version_code, version_name, apk_url, sha256, changelog, min_supported, is_active, created_at`,
		uv(id), arg.Platform, arg.VersionCode, arg.VersionName, arg.ApkUrl, arg.Sha256, arg.Changelog, arg.MinSupported)
	var i AppVersion
	err := row.Scan(suuid(&i.ID), &i.Platform, &i.VersionCode, &i.VersionName, &i.ApkUrl, &i.Sha256,
		&i.Changelog, &i.MinSupported, sbool(&i.IsActive), stime(&i.CreatedAt))
	return i, err
}

func (q *sqliteQueries) UpsertPushSubscription(ctx context.Context, arg UpsertPushSubscriptionParams) (PushSubscription, error) {
	id := uuid.New()
	row := q.db.QueryRowContext(ctx,
		`INSERT INTO push_subscriptions (id, user_id, device_id, endpoint, p256dh, auth, kind)
		 VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT (endpoint) DO UPDATE
		 SET p256dh = excluded.p256dh, auth = excluded.auth, user_id = excluded.user_id, kind = excluded.kind
		 RETURNING id, user_id, device_id, endpoint, p256dh, auth, created_at, kind`,
		uv(id), uv(arg.UserID), uvp(arg.DeviceID), arg.Endpoint, arg.P256dh, arg.Auth, arg.Kind)
	var i PushSubscription
	err := row.Scan(suuid(&i.ID), suuid(&i.UserID), snUUID(&i.DeviceID), &i.Endpoint, &i.P256dh, &i.Auth,
		stime(&i.CreatedAt), &i.Kind)
	return i, err
}

func (q *sqliteQueries) WriteAudit(ctx context.Context, arg WriteAuditParams) error {
	_, err := q.db.ExecContext(ctx,
		`INSERT INTO audit_log (event, actor_user_id, actor_device_id, circle_id, ip, detail)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		arg.Event, uvp(arg.ActorUserID), uvp(arg.ActorDeviceID), uvp(arg.CircleID), arg.Ip, bb(arg.Detail))
	return err
}

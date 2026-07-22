-- +goose Up

-- A phone opened in a mobile browser now registers as 'web-mobile' rather than
-- desktop 'web'. The distinction lets the map/members UI drop the desktop-only
-- "PC" badge and the "located via Wi-Fi" hint for phones (which have GPS),
-- without any other change to the device. Widen the platform CHECK to admit the
-- new value. The inline CHECK from 00002_core is auto-named devices_platform_check.
ALTER TABLE devices DROP CONSTRAINT devices_platform_check;
ALTER TABLE devices ADD CONSTRAINT devices_platform_check
    CHECK (platform IN ('android', 'ios', 'web', 'web-mobile'));

-- +goose Down
-- 'web-mobile' has no representation in the old CHECK; fold those rows back to
-- 'web' (they are still web devices) so the tighter constraint can re-apply.
UPDATE devices SET platform = 'web' WHERE platform = 'web-mobile';
ALTER TABLE devices DROP CONSTRAINT devices_platform_check;
ALTER TABLE devices ADD CONSTRAINT devices_platform_check
    CHECK (platform IN ('android', 'ios', 'web'));

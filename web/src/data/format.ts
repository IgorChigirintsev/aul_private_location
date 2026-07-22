/// Milliseconds left until an RFC3339 deadline, floored at 0.
///
/// An unparseable deadline returns 0 — i.e. "expired". That is deliberate: this
/// drives whether a live-share link still shows someone's location, so garbage
/// in must fail CLOSED (stop sharing), never open.
export function msUntil(rfc3339: string | null | undefined, now: number = Date.now()): number {
  if (!rfc3339) return 0;
  const deadline = Date.parse(rfc3339);
  if (!Number.isFinite(deadline)) return 0;
  return Math.max(0, deadline - now);
}

/// Formats a remaining duration as a mm:ss countdown ("09:07"), rolling over to
/// h:mm:ss past an hour. Digits only — nothing to translate.
export function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const s = total % 60;
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  const pad2 = (n: number) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${pad2(m)}:${pad2(s)}` : `${pad2(m)}:${pad2(s)}`;
}

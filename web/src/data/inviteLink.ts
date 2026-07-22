/// Parses a pasted invite link into its id + fragment (K_c). Tolerant of a
/// missing protocol/host — the user may paste anything from a bare `/i/<id>#…`
/// to a full `https://host/i/<id>#…`. Returns null for anything without both a
/// `/i/<id>` path segment AND a non-empty `#` fragment.
///
/// The fragment is the secret circle key: it is returned so the caller can carry
/// it in a client-side `/i/:id#frag` navigation ONLY. It must never be logged or
/// sent to a server.
export function parseInviteLink(
  raw: string,
): { inviteId: string; fragment: string } | null {
  const input = raw.trim();
  if (!input) return null;
  const hashIndex = input.indexOf('#');
  if (hashIndex === -1) return null;
  const fragment = input.slice(hashIndex + 1);
  if (!fragment) return null;
  // Drop any query string before matching the path segment.
  const beforeHash = input.slice(0, hashIndex).split('?')[0];
  const m = beforeHash.match(/\/i\/([^/#?]+)/);
  if (!m || !m[1]) return null;
  return { inviteId: m[1], fragment };
}

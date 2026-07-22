# Aul — Threat Model

This document is honest by policy. If Aul cannot protect against something, it is
written here plainly. "Trust, but verify the code" is the whole point.

Status: **living document.** The cryptographic sections are specified now and
implemented in Phase 4; the server‑metadata sections are accurate for the
Phase‑1 server.

## 1. What we are protecting

Family location data: a person's coordinates over time, the names and locations
of their meaningful places ("home", "school"), their geofence rules, SOS events,
and battery/precision status. This data reveals where children sleep, where
people work, daily routines, and who is with whom. It must not be readable by the
server operator, a database thief, a network observer, or Aul the company.

## 2. Roles & actors

- **Reporter** — a device sharing its own location into a circle.
- **Watcher** — a device viewing a circle's map.
- **Circle owner** — can rotate the circle key, set retention, invite/remove.
- **Server operator** — runs the backend (could be a self‑hoster, could be us).
- **Adversaries:** a curious/compromised server operator; a database dump thief;
  a passive network observer; a malicious circle member; a stalker abusing the
  product; a lost/stolen unlocked device.

## 3. Cryptographic design (the guarantee)

- Each **device** generates an **X25519 identity keypair** at registration. The
  **private key never leaves the device** (Android Keystore / iOS Keychain /
  browser IndexedDB — see §7 for the web caveat).
- Each **circle** has a 32‑byte symmetric key **K_c**, generated on the owner's
  device. K_c never touches the server.
- **Invites** carry K_c in the URL *fragment*: `https://host/i/<invite_id>#<base64url(K_c)>`.
  Fragments are never sent to the server by browsers. The server only ever knows
  `invite_id` and status. Membership is confirmed by signing a server challenge
  with the device identity key.
- **Location pings**: the plaintext `{lat,lng,acc,speed,heading,batt,ts,mode}`
  is sealed with **XChaCha20‑Poly1305** under K_c with a fresh random 24‑byte
  nonce. The server stores `(circle_id, device_id, nonce, ciphertext, server_ts,
  ttl)` and can decrypt none of it.
- **Places & geofences** are stored as ciphertext blobs; clients sync them and
  compute enter/exit **locally**. The server performs no computation over
  coordinates (unless trusted‑server mode is explicitly enabled — §8).
- **Key distribution / rotation**: when a member leaves, the owner rotates K_c
  and distributes the new key to remaining members with `crypto_box_seal`
  (anonymous sealed box) to each member's X25519 identity public key, via the
  `key_envelopes` endpoint. The server relays sealed boxes it cannot open.
- **Device verification**: a **safety code** (emoji fingerprint derived from a
  hash of both parties' public keys) is compared out‑of‑band to detect a
  server‑injected man‑in‑the‑middle.

Primitives are libsodium only (X25519, `crypto_box_seal`, XChaCha20‑Poly1305).
**No hand‑rolled cryptography.** The server never receives K_c or any private key.

## 4. What the SERVER can see (metadata — the honest list)

Even with perfect E2EE, a location service is a metadata machine. The server
*does* see, and an operator or DB thief could obtain:

- **Who**: account emails, which devices belong to which account, circle
  membership graph (who is in a circle with whom).
- **When & how often**: the timing, frequency and size of pings — enough to infer
  activity/sleep patterns and "is this person moving right now" without any
  coordinate. Ping *size* is padded to a fixed length to blunt this (see §5).
- **Where‑from (network)**: source IP of each request (retained ≤ 7 days,
  configurable), hence coarse geolocation of the *connection*.
- **Roles & config**: who owns a circle, retention setting, precision *mode*
  (precise/city/paused) because the circle needs to display it — the mode label
  is metadata even though the coordinate is not.
- **Security events**: logins, key rotations, invite issuance (audit log).
- **Notification mutes** (who has muted whom, or a whole circle). This is a
  deliberate trade: the requirement is that muting *stops other members' devices
  sending to you*, and the server performs the push fan-out — so it must know to
  skip you. The alternative (deliver, then drop it on the recipient's device)
  would tell the server nothing but would not actually stop the delivery. The
  notification *content* stays sealed under K_c either way. (D-0053)
- **Place authorship**: which member created each place (`created_by`), so clients
  can show "«Home» · Anna". The place's name, coordinates and radius stay sealed.
- **Live-share sessions**: that an account opened a share link, its deadline, and
  that *some* device claimed it — never the position (sealed under a per-session
  key that only ever exists in the link fragment) nor who the viewer is. (D-0051)
  *Correction (D-0059): §3's claim that key material never leaves the OS keystore
  was not quite true on Android — the sharer's copy of **K_share** was kept in
  plain `SharedPreferences`. App-private, but not encrypted at rest, so a device
  backup or a root-level reader could lift it and open that session's positions.
  It now lives in the keystore beside K_c. K_share never reached the server in
  either case; this was about rest, not transit.*

There is also one class of metadata that leaves our server entirely:

- **Push relays are third parties, and they see traffic patterns.** Waking a
  closed app is not something an app may do by itself: the OS insists on its own
  relay. Web Push goes through the browser vendor's service (Google for Chrome,
  Mozilla for Firefox); Android notifications go through **Google FCM** (D-0057).
  Those relays learn *that* a notification was delivered to a given
  subscription/device, *when*, and its *size* — i.e. a rough activity trace, on
  top of what the server already sees. They cannot read a word of it: the payload
  is sealed under K_c on the sending device before our server ever holds it, and
  Web Push seals it again per RFC 8291. Aul sends **data-only** FCM messages
  precisely so that Android never renders a notification we would have had to
  hand over in plaintext.
  This is a genuine trade, so it is opt-out: push is **off unless the operator
  configures it**, and a deployment that leaves VAPID and FCM unset simply has no
  third-party relay in the picture (at the cost of no background alerts).
  A relay-free path for de-Googled phones (UnifiedPush / self-hosted ntfy) is a
  known, not-yet-built option — see D-0057.

The server **cannot** see: coordinates, speed, heading, exact battery value,
place names, geofence shapes, SOS payload contents, or the circle key.

## 5. Metadata minimization

- Ping ciphertext is **padded to a fixed size** before encryption so blob length
  does not leak precision mode or payload contents.
- **Places & SOS** are padded to a 256‑byte block before sealing, so a place name
  or SOS message does not leak its exact length — only a coarse bucket at 256‑byte
  granularity (a payload > 256 B pads to 512 B). The UI caps place names (80
  chars) and SOS messages (160) so normal payloads stay in the single 256‑byte
  bucket; the residual bucket‑granularity is an accepted, documented limit, not
  claimed away. Places/SOS also carry domain‑separation associated data so a
  ciphertext of one type can't be replayed as another (D‑0034).
- **Circle name** length is *not* hidden: `name_enc` is sealed unpadded, so the
  server learns each circle name's byte length (never its plaintext). Accepted —
  the server already sees the full membership graph, which is far more revealing
  than a name's length; padding the name is a possible future hardening.
- IP addresses in request logs are retained ≤ 7 days (`IP_LOG_RETENTION_DAYS`)
  and can be disabled entirely; they are never joined to ping content.
- Retention job deletes ping history older than the circle's `retention_days`.
- No third‑party analytics, no ad SDKs, no external fonts/CDNs on authenticated
  pages (CSP forbids them).

## 6. What is explicitly OUT of scope for v1 (honest limits)

- **Forward secrecy.** v1 has none: rotating K_c does not make *old* ciphertext
  unreadable to members who had the old key, and a member who kept the old key
  can still read old history. Roadmap: MLS (Messaging Layer Security) group
  keying. Documented, not hidden.
- **Traffic‑analysis resistance** beyond fixed‑size padding. A global passive
  adversary can still learn *when* you move.
- **Anti‑coercion.** If someone forces you to unlock your device, they get your
  keys. No duress mode in v1.
- **Server availability / integrity attacks.** A malicious server can withhold or
  reorder pings, or deny service. It cannot forge ciphertext (Poly1305) or read
  it. It *can* lie about who is in a circle — safety codes exist to detect
  key‑substitution MITM.
- **Account enumeration at registration.** Registration reveals whether an email
  is already registered (a 409). This is a known v1 limitation; it is IP
  rate‑limited (using a non‑spoofable client IP), and full mitigation (uniform
  responses gated on email verification) is planned. Login does **not** leak
  existence — its timing is equalized and its response is uniform.

## 7. The web client is weaker — stated plainly

The web app's JavaScript is **served by the server**. A malicious or compromised
server can ship JS that exfiltrates K_c or the identity key from the browser.
Therefore:

- The browser is only as trustworthy as the server delivering its code, on each
  load. Native apps ship code out‑of‑band (signed APK / App Store) and are not
  subject to this.
- Web identity private keys live in IndexedDB (non‑extractable WebCrypto where
  the primitive allows; libsodium keys stored with care). This resists casual
  XSS token theft but **not** a hostile server.
- We mitigate, not solve: strict CSP (no inline/eval, no third‑party origins),
  Subresource Integrity where applicable, reproducible web builds so the served
  bundle can be audited, and a clear in‑product notice that the web watcher is a
  convenience with a weaker trust model than the app.
- Recommendation surfaced in‑product: **use the app for anything sensitive.**

## 8. Trusted‑server mode (self‑host opt‑in, default OFF)

Self‑hosters who trust their own server may enable `TRUSTED_SERVER_MODE=true`,
which allows plaintext coordinates and server‑side geofencing/PostGIS. This
trades the E2EE guarantee for server‑side features. It is **off by default**,
loudly logged at startup, and surfaced in the client UI ("this server can see
your location"). Our cloud never enables it.

## 9. Anti‑stalking (product‑level, non‑negotiable)

Technical privacy is not the same as personal safety. Aul additionally enforces:

- **No hidden/stealth reporting.** A reporting device always shows a persistent,
  non‑dismissible OS notification.
- **One‑tap "Who can see me"** from any screen.
- **A monthly, non‑disable‑able reminder**: "You are sharing location with …".
- **Instant unilateral leave** — no owner approval required to stop sharing.
- **Guardian mode** (asymmetry for child accounts) always shows a visible badge
  on the child's device; it can never be silent.

## 10. Server hardening (Phase‑1 scope)

Argon2id passwords; opaque hashed session tokens; refresh rotation with
reuse‑detection; IP + account rate limiting with exponential lockout; strict
input validation (blob ≤ 4 KiB, batch ≤ 100); body‑size limits and timeouts;
strict security headers (CSP/HSTS/nosniff/Referrer‑Policy); same‑origin CORS;
audit log; parameterized queries only (sqlc). See [SECURITY.md](SECURITY.md).

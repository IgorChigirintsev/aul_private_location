# Aul self-host on PC — design (2026-07-20)

> Recommendation: pure-Go SQLite + Tailscale Funnel (default) + single signed native binary with tray UI. The owner still decides the reachability privacy posture. Blockers surfaced by the critique (FCM, offline-signal, tailscaled) must be resolved before GA.

# Aul self-host ("run your own server, one button, any OS") — architecture + phased plan

## Recommendation in one line

Ship **pure-Go SQLite (`modernc.org/sqlite`) + Tailscale Funnel (default reachability) + a single signed native binary with a tray UI, per OS.** This is the only internally consistent combination that keeps the "no third parties" promise *meaningful* rather than nominal: it is the one stack where (1) the family's data lives in a file on their own disk, (2) the reachability relay never sees plaintext because TLS terminates on the owner's own machine, and (3) there is no second executable, no Docker, and no runtime download to sign, notarize, or break.

Every other viable option is a *bridge*, not the destination:
- **embedded-postgres** is the honest "fast homelab bridge" — zero schema work, but it trades the SQLite port's bounded one-time cost for permanent per-user runtime liabilities (the PG-major on-disk upgrade trap = silent data-loss on auto-update, a second unsigned native binary to notarize, 130–270 MB, no Windows-arm64). Fine as an *operator tier*; wrong as the flagship consumer path.
- **Cloudflare Tunnel**, **our-own GCP relay**, **Docker**, **Tauri/Electron**, and **direct port-forward** each fail a load-bearing constraint (detailed below). They are rejected, not deferred.

One consequence to state plainly up front: the **cloud** product stays on Postgres (multi-tenant scale needs partitioning/concurrency/HA), so choosing SQLite for self-host means **maintaining two SQL dialects forever.** The schema audit shows this is contained — the app already hides the driver behind `store.IsNotFound()` (~28 sites; only `retention.go` and `misc.go` touch `Pool()` directly) — but every future schema/query change must be authored and tested twice, and the integration suite must run against both backends. That is the real, permanent price of this design, and it is the right price to pay versus embedded-postgres's data-loss-on-update risk.

---

## (a) The owner's decision — the reachability privacy posture

This is a **values decision, not an engineering one**, which is why it belongs to the owner. The manifesto is "no third parties," but the audits establish an unavoidable tension:

> The **only** posture with literally zero third party in the traffic path is **direct** (port-forward + own domain + Let's Encrypt) — and that is precisely the one that **cannot be one-button on any OS** and **silently fails for 20–50% of users** (CGNAT is a categorical, no-software-fix blocker; UPnP frequently off or falsely reports success; failures are non-diagnosable by a non-technical person). "No third parties," taken absolutely, is incompatible with "one button, any OS, reliably reachable." Something must give.

Here is what each posture actually leaks, straight from the audits. The owner should choose with this table in front of them:

| Posture | Who the third party is | What it sees | What stays sealed | Verdict |
|---|---|---|---|---|
| **Direct** (UPnP/DDNS/LE) | None in traffic path (DDNS provider + public CT logs see only hostname↔IP) | Nothing in traffic | Everything | Purest, but **unreachable for a large minority (CGNAT), silent non-diagnosable failures, not one-click** |
| **Tailscale Funnel** *(recommended default)* | Tailscale (user's **own** account) | Connection **metadata only**: ts.net hostname/SNI, member IPs, timing, byte volume | **All plaintext HTTP** (credentials, cookies, social graph, paths, bodies) *and* all E2EE content — because **TLS terminates on the owner's node**; relays forward ciphertext | **Best privacy-preserving reachable option** |
| **Cloudflare Tunnel** | Cloudflare (US co., subpoena/NSL, breach target) | **Everything non-E2EE in cleartext**: signup/login email+password, replayable session cookies, the full membership + activity graph, client IPs, timing | Only K_c-sealed content (coordinates, circle names, nicknames) | **Reject** — it terminates *your* TLS; directly contradicts why a privacy user self-hosts |
| **Our own GCP relay** | **Aul itself** | Cloud-equivalent metadata **+ session tokens** (relay must terminate TLS for same-origin/secure-cookies to work) | Only K_c-sealed content | **Reject** — reinstates us as a mandatory intermediary; self-host collapses to "cloud where only the at-rest DB moved." Very-large build + perpetual opex |

**Recommendation to the owner, stated plainly:**

> **Default to Tailscale Funnel.** It is the smallest possible compromise: the relay is metadata-only (who-connects-to-whom-and-when, not what), it is the *user's own* Tailscale account so **Aul never enters the path**, and because TLS terminates on the home box the relay is cryptographically blind to credentials and the social graph — the exact things Cloudflare would expose and our-own-relay would re-centralize. **Offer "Direct mode" as an advanced toggle** for the minority who can port-forward and want literally zero relay (the code already supports `AUL_DOMAIN`/Caddy for this). **Never** wire the self-host tier to Cloudflare or to our own relay — both break the manifesto in the one way that matters (they can read identities/credentials/graph).

**The honest dent in "one button" you must own:** Tailscale is **not** zero-config, and no launcher can hide this. The audit is explicit — the user must (a) create a Tailscale account via third-party SSO (Google/Microsoft/GitHub/Apple), (b) install `tailscaled` (admin/root, a system networking service), (c) complete an interactive browser auth, and (d) **enable Funnel in the admin console** (an ACL/grant edit + turn on HTTPS certs — Funnel is OFF by default and this is a web-console action a launcher *cannot* perform silently). You also **cannot** ship a pre-provisioned auth key, because that would put every family on *your* single tailnet — the wrong ownership model. So the truthful product claim is: **"one button to run your server; a short, guided, one-time setup to make it reachable."** Phase 2 owns that guided flow. If even that is too much for the target user, the honest answer in the UI is "use the hosted instance" — which is fine, because the cloud product exists.

---

## (b) The availability caveat — the PC must stay on

This cannot be *solved*, only *softened*, and the plan must treat it as a first-class product surface, not a warning dialog.

**Why it's fundamental:** the realtime hub is in-process, single-goroutine, single-instance by design (`realtime/hub.go`, D-0009; rate limiters/ceilings are in-memory too). A home box that sleeps, hibernates, closes its lid, or loses power **silently staleness the live map** — members keep seeing the last dot, looking fresh, with no signal it's stale. For a location-safety app that is the worst failure mode: confidently wrong.

**What can be softened (do it, but don't overclaim):**
- **Sleep inhibition** while the server runs: `SetThreadExecutionState` (Windows), `IOPMAssertion`/`caffeinate` (macOS), `systemd-inhibit` (Linux). Constraints from the audit: **never silently override the user's power policy** (surface it as a toggle), and you **cannot keep a lidded laptop awake.** So this narrows the gap; it does not close it.

**What actually handles "PC is off" — a client + protocol change, not a desktop popup:**
- Add a **member-visible "home server offline" signal.** Members must see *"Home server last seen 14 min ago — location may be stale"* with an explicit staleness timestamp and an offline badge on the map, instead of a stale-but-fresh-looking dot. This is the real mitigation and it is a client + protocol change (Phase 2), because the honesty has to reach the *viewer's* screen, not just the operator's tray.
- **Last-known-location with explicit age** everywhere a live position is shown.
- **Push goes quiet, correctly:** if VAPID/FCM is configured, notifications originate from the server, so an off server simply sends nothing — acceptable, but the offline badge is what keeps it honest.

**Onboarding copy must say the quiet part out loud:** this tier is for an **always-on machine** (a mini-PC, an always-on desktop, a home server), and **for a laptop that sleeps, the hosted instance is the better choice.** The audit is blunt that this caveat "remains the top reason most families should use the cloud." Selling it as "run it on your laptop" would be dishonest and will generate support pain; sell it as "run it on the PC you never turn off."

---

## (c) How the invite link carries the self-hosted origin (so web + app just work)

This is the elegant part of the existing design and it requires **almost no server work** — the launcher's entire job is to make sure clients *talk to the server through the reachable origin*. From the packaging/origin audit:

- **Invite format:** `<origin>/i/<inviteId>#<base64url(K_c)>`. The circle key rides in the **URL fragment the server never sees**; the server's create/accept handlers deal only in the invite **UUID** (`httpapi/invites.go`) and **never touch the origin.**
- **Web** builds the link from `location.origin` (`web/src/features/InviteDialog.tsx:32`). Because the dashboard is served *by* the server and uses same-origin relative fetch/WebSocket (`web/src/data/api.ts`), **a dashboard opened at the ts.net URL automatically mints ts.net-origin invites — zero config.**
- **App (Flutter)** builds it from the `serverUrl` the user typed on the login screen (`controller.dart:415` → `invite_link.dart:57`); it's server-agnostic with no hard-coded default.

So the launcher has exactly **one responsibility** for this to work: **inject the Funnel hostname as `PUBLIC_ORIGIN` (with `AUL_ENV=production`, `SECURE_COOKIES=true`) *before* serving any client, and open the dashboard at that ts.net origin — never at `localhost`.** Get this right and every invite, web or app, bakes in the reachable origin and members on cellular just connect. Get it wrong (dashboard opened at `localhost:8080` or a LAN IP) and every invite encodes an unreachable origin — the single most likely launcher bug, so it gets an explicit Phase-1 exit test.

Two supporting facts make Tailscale the right partner here specifically:
- **`PUBLIC_ORIGIN` also gates the WebSocket allowed-origin** (`httpapi/ws.go:69-70`) and CORS/CSP (`middleware/security.go`); a Funnel-terminated HTTPS origin satisfies the https/secure-cookie coupling **for free** — no Caddy, no cert handling.
- **ts.net hostnames are stable** across reboots/IP/NAT changes, so origin-baked invites **stay valid long-term** — the decisive advantage over Cloudflare quick-tunnels, whose random rotating hostname would break every previously issued invite *and* every member's stored `server_url`. **Caveat to engineer around:** a node rename or re-auth collision can append `-1`/`-2` and change the host, silently breaking issued invites — so the launcher must **pin the machine name** (Phase 2).

---

## Phased implementation plan

### Phase 0 — Reachability spike (days, ~zero new code)

**Purpose:** de-risk the *only* thing the audits flag as unvalidated and design-invalidating, at near-zero cost, **before** committing the 3-week DB port. The DB is high-effort but low-uncertainty ("just work"); reachability is the real unknown.

**Scope:** Run the *existing* `aul` binary against a throwaway local Postgres on a dev machine. Install `tailscaled`, enable Funnel manually, set `PUBLIC_ORIGIN` to the ts.net host, open the dashboard there.

**Exit criteria (all must pass):**
1. A **remote member on cellular** joins via a ts.net invite and sees a **live** location update — i.e., the **WebSocket realtime hub survives Funnel proxying** (audit: "should be validated end-to-end on the target OSes") and the same-origin WS check passes.
2. Invites minted from the ts.net dashboard encode the ts.net origin (not localhost).
3. ts.net host survives a reboot and the invite still works.

**Kill condition:** if Funnel can't carry the WS hub or the origin story breaks, the whole reachability leg is wrong — and we learned it in days, not after the DB port.

> Deliberately: **no embedded-postgres, ever.** Using the dev's existing Postgres here means we never build, sign, or throw away a second-binary integration — sidestepping all of embedded-postgres's liabilities and honoring SQLite as the permanent path.

### Phase 1 — Walking skeleton: prove it end-to-end as the *real* design (the "prove it" milestone)

**Purpose:** one dogfood build a non-developer teammate can run and use — the true single pure-Go binary, on one OS.

**Scope:**
- **The SQLite port** (critical path, ~1.5–3 focused engineer-weeks per the schema audit). Non-negotiable long pole because it's what makes the single pure-Go binary possible. Break it down as the audit does:
  - Parallel SQLite migration set (8 files; migrations **00004/00007/00008 need the 12-step table-rebuild**).
  - Rewrite the ~6 dialect-hostile, **correctness-sensitive** constructs and **re-prove equivalence** (not translate): `DISTINCT ON` → `ROW_NUMBER()` window (live-map latest-fix, `pings.sql:13`); `= ANY($1::uuid[])` → expanded `IN`/`json_each` (mute-set validation, `mutes.sql:23`, which also forces a hand-written signature since sqlc can't regen the slice param); `NULLS NOT DISTINCT` → **two partial unique indexes** (whole-circle-mute dedup, `00007:25`); `make_interval`/`now()` in predicates → **Go-computed cutoff bounds**; `'epoch'::timestamptz` and `::casts`.
  - **Rip out ping partitioning**: no PL/pgSQL partition functions, retention becomes DELETE-by-timestamp (the row-level prunes already are plain DELETEs); rewrite `retention.go` (drop `dropOldPartitions`/`EnsurePingPartitions`) and make `misc.sql` `EnsurePingPartitions` a no-op.
  - Regenerate sqlc under the sqlite engine **last** (it rejects the PG-only SQL until the above is done); fix the type stack — a **uuid wrapper type** (google/uuid has no `sql.Scanner`/`driver.Valuer`), `timestamptz`→`time.Time` tz round-tripping, `citext`→`TEXT COLLATE NOCASE`, generate UUIDs Go-side (no `gen_random_uuid()`).
  - **Connection PRAGMAs on every pooled conn** — `foreign_keys=ON` (or `ON DELETE CASCADE` mute cleanup silently dies — a correctness landmine), `journal_mode=WAL`, `busy_timeout`. `goose.SetDialect("sqlite3")`; `IsNotFound` maps `sql.ErrNoRows`.
  - Select the backend via **config/build-tag** (`config.go` currently hardcodes a required `postgres://` URL) with sane SQLite defaults for true one-download-then-run.
- **Minimal Go tray launcher** (single OS — pick the cheapest to sign; Linux AppImage needs no cert, or macOS whose notarization is most mature): bundles `tailscaled`, **auto-generates + persists** `SESSION_HASH_PEPPER` and any DB secret (**never rotate the pepper silently — it logs everyone out**), injects `PUBLIC_ORIGIN` from the Funnel host, runs **exactly one** server process, opens the dashboard at the ts.net origin, uses `/readyz` for readiness. ~5 widgets: start/stop, status, invite URL, "keep this PC on" note.
- **Package-time web build:** run `make web` (Node) then the Go build in CI so the user needs neither Node nor Go — otherwise a clean build embeds only `index.html` and serves a broken SPA (packaging audit's critical gap).

**Exit criteria:** a teammate double-clicks the build, completes Tailscale setup once, and a remote family member on cellular joins and sees live location — running the **real** stack (pure-Go SQLite single binary), with the full integration suite green **against SQLite** (port `testutil/db.go`, `retention_integration_test.go` off Postgres/partitions).

### Phase 2 — Hardening + cross-OS breadth (the majority of the calendar)

- **All three OSes with signing** (the audit's "3× per-OS work"): macOS Developer ID + hardened runtime + **notarize/staple** ($99/yr, LSUIElement tray); Windows — an **EV code-signing cert (~$300–700/yr)** is effectively required for day-one SmartScreen trust for a non-technical audience, plus the Firewall "allow" prompt on bind; Linux AppImage (closest feel) + `.deb`/`.rpm`, each with autostart/tray.
- **Availability, done honestly:** sleep-inhibition toggle (never silent) **+ the member-visible "home server offline" signal** (client + protocol change) with explicit last-seen staleness — the real fix from part (b).
- **Auto-update as a data-safety operation:** swap a running signed binary (download-rename-relaunch, **re-verify signature/notarization**); and because `RUN_MIGRATIONS` defaults true and this is the family's **only** copy of their ciphertext DB, **mandatory pre-update backup + rollback** before any migration. The signing key becomes the update root-of-trust (same discipline as the APK key).
- **Guided Tailscale onboarding** for the unavoidable account + `tailscale up` + **admin-console Funnel enablement** steps a launcher can't automate; **pin the machine name** so a rename can't append `-1` and break issued invites.
- **"Direct mode" advanced toggle** (UPnP/DDNS/Caddy/`AUL_DOMAIN`) for zero-relay purists, clearly labeled "may not work on your network (CGNAT)."

### Phase 3 — Residual privacy + polish (optional, post-GA)

- **Self-host map tiles** (`TILES_ORIGIN`) to stop the default OpenFreeMap CDN from seeing map viewports — the last casual third party in the picture.
- Launcher observability, crash/orphan-process recovery, backup export UX.

---

## Honest residual-third-party ledger (what "no third parties" really means after this design)

| Party | Sees | Mitigation in this design |
|---|---|---|
| **Tailscale** (user's own account) | Connection metadata: ts.net host, member IPs, timing, byte volume | Unavoidable for reachable-without-port-forward; **TLS terminates on the owner's box** so no plaintext/credentials/graph; Direct mode removes it entirely |
| **SSO identity provider** (Google/etc.) | That the owner created a Tailscale account | Inherent to Tailscale onboarding; disclosed in onboarding |
| **Public CT logs** | The ts.net hostname exists | Inherent to any Let's Encrypt/Funnel cert; hostname only, no traffic |
| **OpenFreeMap CDN** | Map viewport of whoever views the map | Phase 3: self-host tiles via `TILES_ORIGIN` |

Everything the manifesto most cares about — **location coordinates, circle names, member profiles/nicknames, and K_c itself** — stays sealed under K_c end-to-end and never reaches any of these parties. The at-rest database lives as a file on the owner's disk. That is the strongest "no third parties" story achievable while remaining one-button and reachable on any OS — and the table above is exactly the disclosure the owner should stand behind publicly rather than claim an absolute that only Direct mode (which most users can't run) could honor.
---

# Adversarial critique — Aul self-host-on-PC design

Ranked by severity. Classification: **BLOCKER** (design is wrong/dishonest as stated until fixed), **MUST-MITIGATE** (ship-stopping unless a specific mitigation lands before GA), **ACCEPTABLE-WITH-DISCLOSURE** (real cost, honest disclosure is sufficient).

---

## 1. FCM/Android push is a hidden third party the ledger omits — BLOCKER (of the disclosure claim)

The "honest residual-third-party ledger" presents itself as the complete disclosure the owner should "stand behind publicly," but it has no row for **Firebase Cloud Messaging**. Android push cannot be delivered peer-to-peer. In self-host there are only two options, and the design addresses neither:

- **Route Android push through Aul's Firebase project** (project `e2ee-a6a40`, per memory) → Aul sees every self-hoster's **device push tokens plus notification timing/metadata** for every family. That reinstates Aul as a mandatory metadata intermediary — the exact thing the design "rejects" the GCP-relay option for. And it directly contradicts "Aul never enters the path."
- **Require each family to configure their own Firebase project** → not one-button, and demands a Google Cloud console project + service-account JSON, which is far harder than the Tailscale steps already conceded as the honesty dent.
- **Disable FCM** → Android loses push entirely: SOS alerts, geofence/arrival notifications, and re-engagement all go dark, not just "quiet when server is off."

Web push (VAPID) is genuinely self-contained; FCM is not. Until the ledger names FCM and the design picks one of the three postures explicitly, the public disclosure is incomplete in exactly the dimension (metadata to Aul) the whole document claims to have eliminated. **Blocker for the "stand behind it publicly" claim.**

---

## 2. "Single signed native binary" is contradicted by bundled tailscaled — MUST-MITIGATE

The design rejects embedded-postgres partly because it is "a second unsigned native binary to notarize," then makes Tailscale the flagship — which requires **bundling `tailscaled`, a second native executable that installs a system-level networking service / TUN driver requiring admin/root.** On macOS that is a privileged helper / system-extension install with its own Gatekeeper notarization surface and additional System Settings approval dialogs; on Windows it's a service install + driver. So the "one signed binary, no second executable" advantage claimed over embedded-postgres does not actually hold for the recommended stack. The premise isn't false, but the framing is misleading and the extra notarization/privileged-install work is unbudgeted. Must-mitigate: re-scope the packaging work honestly and confirm tailscaled can be bundled + notarized + silently service-installed per OS (it may not be, cleanly).

---

## 3. The offline signal has a bootstrap problem the plan hand-waves — MUST-MITIGATE

The core availability mitigation is "Home server last seen 14 min ago." But **an offline server cannot report its own offline-ness.** The "last seen" and offline badge must be *client-inferred* from WS disconnect + last-ping age — the design describes it as if the server emits it. This mechanism must be specified: viewer detects connection failure, falls back to last-known-position with an age computed client-side, and shows the badge. Also, it lands in Phase 2, so the Phase-1 dogfood build ships with the "confidently wrong fresh-looking stale dot" failure mode for a safety app. For a location-safety product this is the single worst failure; the badge must precede any non-dogfood exposure. Must-mitigate, and the mechanism (client-side inference) is a real design gap, not just sequencing.

---

## 4. Members are conscripted into Tailscale's metadata surface without consent — MUST-MITIGATE

The privacy analysis is owner-centric. But every connecting family member's **phone reveals its source IP, connection timing, and location-update cadence to Tailscale's DERP/Funnel ingress** on every session. Members never created a Tailscale account, never saw Tailscale's ToS, and did not choose this — the owner's values decision is silently imposed on the whole circle, several of whom (kids, less-technical relatives) are exactly the people the threat model protects. "TLS terminates on the owner's box" protects content, not this per-member connection metadata (who-connects-to-whom-and-when is precisely §4 threat-model metadata). The owner-facing disclosure table is necessary but not sufficient; members need to know their connection metadata transits Tailscale. Must-mitigate (member-facing disclosure), not merely owner-facing.

---

## 5. Funnel is a single-vendor dependency for continuous WS at family scale — MUST-MITIGATE

Two under-weighted risks the plan waves past:

- **Traffic model mismatch.** Funnel is documented as low/moderate-traffic, "not a CDN," beta/free-tier. This product holds **persistent WebSockets per member, continuously, 24/7**. That is close to the profile Funnel discourages, and may hit idle-timeout resets or acceptable-use limits over days. Phase 0's kill-criteria test *one* member seeing *one* live update — they never load a family of 5–6 with sustained WS over time, which is the actual risk.
- **Re-centralization the design criticizes elsewhere.** Tailscale can change Funnel terms/limits or disable the beta and break **every self-hoster simultaneously** — the same "central dependency / can deplatform" objection used to reject Cloudflare applies to Funnel, just with better privacy. The design should own this as a standing dependency risk, not present Funnel as escaping re-centralization.

Must-mitigate: extend Phase-0 exit criteria to sustained, multi-member, multi-day WS, and disclose the vendor-dependency.

---

## 6. No hostname/identity portability across machine replacement — MUST-MITIGATE

ts.net stability is correctly praised for reboots/IP/NAT. But the design has **no story for the PC dying or being replaced.** A new machine → new ts.net hostname → every previously issued invite AND every member's stored `server_url` breaks, with the only recovery being re-inviting the entire circle and every member re-entering a URL. For a set-and-forget family locator meant to last years, hardware replacement is a *when*, not an *if*, and it silently kills the whole circle. "Pin the machine name" doesn't help across a fresh install on new hardware. Must-mitigate: define an origin-rebind / hostname-portability path (e.g., reclaim the same tailnet node name on the new box) or disclose that hardware replacement requires full re-invite.

---

## 7. Disk failure = total, unrecoverable loss of the family's data — MUST-MITIGATE / disclose

The at-rest ciphertext DB and `SESSION_HASH_PEPPER` live only on the owner's disk. Auto-update ships a pre-update backup (good), but there is **no off-box / disk-failure backup story** until Phase 3 "backup export UX." A dead SSD loses the entire circle's history and logs everyone out (pepper gone). Inherent to self-host, but it must be disclosed prominently and a backup-export offered at GA, not Phase 3. Must-mitigate on sequencing; acceptable-with-disclosure on substance.

---

## 8. Dual-dialect SQL forever is a live privacy-bug generator on safety paths — MUST-MITIGATE

The design accepts the two-dialect tax, but the adversarial point is sharper than "author twice": the three re-proven constructs are **notification-mute dedup, mute-set validation, and live-map latest-fix** — i.e., who-sees-whose-location and who-is-silenced. A future query change made correctly in Postgres but subtly wrong in the SQLite mirror (FK-cascade off because a PRAGMA wasn't set on one pooled conn; NULLS-NOT-DISTINCT partial-index arbiter not matching) becomes a **location-leak or mute-failure that only manifests on self-host**, where there is no ops person to notice. This isn't a one-time port cost; it's a permanent correctness hazard on exactly the privacy-critical paths. Must-mitigate: enforced dual-backend CI on every schema/query change with explicit equivalence tests for these three constructs, treated as a release gate, not aspirational.

---

## 9. Windows EV code-signing may be legally unavailable, not just expensive — MUST-MITIGATE

The plan budgets $300–700/yr for an EV cert for day-one SmartScreen trust. EV/OV code-signing now requires **hardware-token/cloud-HSM issuance plus organization identity vetting — issued to a legal entity, not an individual/open-source project.** If "Aul" is not an incorporated entity, EV issuance is blocked outright, and OV certs no longer buy quick SmartScreen reputation. Additionally, the auto-updater's "swap a running signed binary / relaunch" pattern is a classic Defender heuristic trigger (process replacing its own image). The design treats signing as a solved checkbook item; the legal-entity prerequisite and the updater/AV interaction are unaddressed. Must-mitigate.

---

## 10. OpenFreeMap leaks approximate location, deferred too late — MUST-MITIGATE (not Phase 3)

For a location-privacy product, the default map-tile CDN sees **the map viewport of every viewer** — i.e., approximately where each member is looking / located. That is leaking a coarse form of the exact thing K_c seals, to an uncontracted third party, by default, until Phase 3 "optional, post-GA." Self-hosting tiles or bounding the leak deserves to be in the GA disclosure and ideally mitigated before GA, not an optional afterthought. Must-mitigate on priority; at minimum it must appear in the owner-facing disclosure table, where it currently sits only in the residual ledger.

---

## 11. Direct-mode CGNAT / UPnP failures — ACCEPTABLE-WITH-DISCLOSURE

Correctly scoped as an advanced toggle with a "may not work (CGNAT)" label. The audits' verdict (20–50% categorically unreachable, silent non-diagnosable failures) is sound and the design doesn't over-sell it. Acceptable *provided* the toggle's failure is diagnosable in-launcher (an external reachability self-check that doesn't false-positive), which the plan should state.

---

## 12. "One button" is honestly downgraded to "one button + guided setup" — ACCEPTABLE-WITH-DISCLOSURE

The Funnel admin-console enablement (ACL grant + HTTPS certs, a web-console action no launcher can perform silently) is correctly conceded, and the reframed claim ("one button to run; a short guided one-time setup to make it reachable") is honest. Acceptable — but note this materially narrows the addressable audience to users who will complete SSO + a privileged daemon install + a console ACL edit, which is a meaningfully smaller set than "non-technical families." The plan's own fallback ("use the hosted instance") is the right escape hatch and should be prominent.

---

## Net assessment

The document is unusually self-aware and most of its stated tradeoffs are correct. The genuinely dangerous gaps are the ones it *doesn't* surface: **(1) FCM/Firebase as an unlisted Aul-metadata third party**, which punctures the completeness of the public disclosure; **(2) bundled tailscaled quietly breaking the "single signed binary" premise**; and **(3) the offline-signal bootstrap + it landing after dogfood**, which leaves the worst safety failure mode live. Those three plus the dual-dialect privacy-correctness hazard (#8) are what I'd block GA on. The reachability and availability honesty is otherwise the strongest part of the plan; the weakest is that Phase 0's kill-criteria validate the easy case (one member, one update) and none of the hard ones (sustained multi-member WS, sleep, Funnel limits, offline inference).
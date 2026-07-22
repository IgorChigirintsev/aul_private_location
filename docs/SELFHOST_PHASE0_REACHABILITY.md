# Self-host Phase 0 — reachability spike (Tailscale Funnel)

> **Why this is first.** The DB port and the launcher are high-effort but low-uncertainty
> ("just work"). The *real* unknown the audits flag is reachability: **does the WebSocket
> realtime hub survive being proxied through Tailscale Funnel, end-to-end, from a phone on
> cellular?** If it doesn't, the whole "Funnel default" leg is wrong — and this ~1-hour
> test tells us before any launcher work is committed to it. See `SELF_HOST_DESIGN.md` §Phase 0.
>
> This is the one step that genuinely **needs you**: a Tailscale account is tied to a person
> (SSO), and enabling Funnel is a web-console action no script can do silently.

## What you need

- **The always-on machine** that will host (a mini-PC / desktop you don't turn off). A laptop
  that sleeps is the wrong host for real use — but it's fine to *spike* on any machine.
- **A phone on mobile data** (turn Wi-Fi OFF on it) — this is what proves a real remote member,
  behind carrier NAT, can reach your box. Testing from the same LAN proves nothing.
- ~1 hour.

## The manual bits (no launcher can hide these)

1. **Install Tailscale** and log in (creates your tailnet via Google/Microsoft/GitHub/Apple SSO):
   - Linux: `curl -fsSL https://tailscale.com/install.sh | sh`
   - macOS/Windows: the Tailscale app.
   - Then: `sudo tailscale up` → complete the browser login.

2. **Find your MagicDNS hostname** (the stable `https://<name>.ts.net` origin):
   ```
   tailscale status --json | grep -i dnsname     # Self.DNSName, e.g. my-pc.tail1234.ts.net.
   ```
   (Drop the trailing dot.) MagicDNS + HTTPS certs must be enabled in the admin console
   (**https://login.tailscale.com/admin/dns** → enable MagicDNS and "HTTPS Certificates").

3. **Enable Funnel** — the console action:
   - Admin console → **Access controls (ACLs)** → add a `nodeAttr` granting `funnel` to your
     node (Tailscale's editor shows the exact snippet; it's `{"nodeAttrs":[{"target":["autogroup:member"],"attr":["funnel"]}]}` or similar).
   - This is OFF by default and is the step the design honestly calls out as "one button
     becomes one button + a short guided setup."

## Bring the server up at the ts.net origin

The launcher (being built) will do this for you (`aul-launcher --origin https://<name>.ts.net`).
Until then, run the single SQLite binary directly — this is exactly what the launcher will spawn:

```bash
# Build the pure-Go server binary (no Docker, no Postgres):
cd server && CGO_ENABLED=0 go build -o /tmp/aul ./cmd/aul

# Pick a stable data dir on the host (your DB + secret live here — back this up):
mkdir -p ~/.aul && HOST="$(tailscale status --json | sed -n 's/.*"DNSName": *"\([^"]*\)\..*/\1/p' | head -1)"

DATABASE_URL="sqlite:$HOME/.aul/aul.db" \
SESSION_HASH_PEPPER="$( [ -f ~/.aul/pepper ] && cat ~/.aul/pepper || (openssl rand -base64 32 | tee ~/.aul/pepper) )" \
PUBLIC_ORIGIN="https://$HOST" \
HTTP_ADDR="127.0.0.1:8080" \
AUL_ENV=production SECURE_COOKIES=true RUN_MIGRATIONS=true \
/tmp/aul
```

In a second terminal, expose it through Funnel:
```bash
tailscale funnel 8080          # or: tailscale funnel --bg 8080
tailscale funnel status        # should show https://<name>.ts.net  ->  127.0.0.1:8080
```

Open `https://<name>.ts.net` in your own browser first — you should get the Aul dashboard over
real HTTPS (Funnel terminates TLS on *your* box; the cert is Let's Encrypt via Tailscale).

## Exit criteria — ALL must pass (this is the go/no-go)

1. **The load-bearing one:** from your **phone on cellular (Wi-Fi off)**, open
   `https://<name>.ts.net`, create an account, and **join/create a circle**. On a second
   device (your laptop as a watcher) confirm the phone's marker **appears and moves live** —
   i.e. the **WebSocket hub survives Funnel proxying**, not just plain HTTP.
2. **Origin baking:** an invite minted from the dashboard on the ts.net URL contains
   `https://<name>.ts.net/i/...` (NOT `localhost` / a LAN IP). Copy an invite link and eyeball it.
3. **Reboot survival:** reboot the host, bring the server + `tailscale funnel` back up, and
   confirm the **same** ts.net URL and a previously-issued invite **still work** (ts.net names
   are stable — this is the decisive advantage over Cloudflare quick-tunnels).
4. **Sustained multi-member** (critique #5 — don't validate only the easy case): keep **2–3
   members connected with the map open for ~30+ minutes** and confirm the live updates don't
   silently stall (Funnel is documented as "not a CDN" / moderate-traffic; persistent 24/7 WS
   is close to what it discourages, so we must see it hold, not assume it).

## Kill condition

If the WS hub can't carry a live update through Funnel (criterion 1), or updates stall under
sustained multi-member load (criterion 4), **Funnel-as-default is wrong** and we rethink the
reachability leg (Direct-only, or a different relay) *before* building the launcher around it.

## What to report back

- Pass/fail on each of the 4 criteria.
- If it works: the ts.net hostname format you got (so the launcher's detection matches reality).
- Any Funnel quirk (idle timeout, a port other than 443, a rename appending `-1`).

Everything sealed under K_c (coordinates, circle names, nicknames) stays sealed throughout —
Funnel only ever sees ciphertext + connection metadata, because TLS terminates on your box.

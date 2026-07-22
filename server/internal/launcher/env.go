package launcher

import (
	"sort"
	"strconv"
	"strings"
)

// composeEnv builds the exact environment for the server child: the operator's
// inherited environment with our resolved values layered on top so ours always
// win. It sets only variables the server already understands (internal/config);
// it deliberately leaves two keys unset (see below).
func composeEnv(base []string, res resolved, pepper, dbPath string) []string {
	overrides := map[string]string{
		"PUBLIC_ORIGIN":       res.Origin,
		"AUL_ENV":             res.Env,
		"SECURE_COOKIES":      strconv.FormatBool(res.SecureCookies),
		"DATABASE_URL":        "sqlite:" + dbPath,
		"SESSION_HASH_PEPPER": pepper,
		"RUN_MIGRATIONS":      "true",
		// Bind LOOPBACK only, never 0.0.0.0. The public front (Tailscale Funnel, or
		// a Direct-mode reverse proxy) runs on this same box and reaches us over
		// 127.0.0.1; it terminates TLS. Binding all interfaces would additionally
		// expose this PLAINTEXT http server — credentials, session cookies, the
		// social graph — to anyone on the LAN, straight past the TLS that the whole
		// reachability design puts in front of it. The readyz probe also uses
		// 127.0.0.1, and localhost origins resolve here, so nothing legitimate loses
		// reach.
		"HTTP_ADDR": "127.0.0.1:" + strconv.Itoa(res.BindPort),
	}
	// Deliberately NOT set:
	//   AUL_DB_BACKEND — an explicit value forces a backend; leaving it unset lets
	//     config infer "sqlite" from the "sqlite:" DATABASE_URL. Forcing postgres
	//     here would break the sqlite path (config.detectDBBackend).
	//   FCM_PROJECT_ID — the server derives the project id from the service-account
	//     JSON, never from an env var (config.loadFCM). Two sources of truth for
	//     one value is one place for them to disagree.
	return mergeEnv(base, overrides)
}

// mergeEnv drops every inherited entry whose KEY appears in overrides, then
// appends the overrides in sorted key order. Dropping-then-appending guarantees
// our values win over whatever the operator's shell already exported, and the
// sort makes the result deterministic so tests can assert on it.
func mergeEnv(base []string, overrides map[string]string) []string {
	out := make([]string, 0, len(base)+len(overrides))
	for _, kv := range base {
		key, _, ok := strings.Cut(kv, "=")
		if !ok {
			// Not a KEY=VALUE entry; leave it untouched.
			out = append(out, kv)
			continue
		}
		if _, overridden := overrides[key]; overridden {
			continue
		}
		out = append(out, kv)
	}
	keys := make([]string, 0, len(overrides))
	for k := range overrides {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out = append(out, k+"="+overrides[k])
	}
	return out
}

// firstNonEmpty returns the first argument that is non-empty after trimming, or
// "" if all are blank. It expresses the launcher's flag > env > default
// precedence in one place.
func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if t := strings.TrimSpace(v); t != "" {
			return t
		}
	}
	return ""
}

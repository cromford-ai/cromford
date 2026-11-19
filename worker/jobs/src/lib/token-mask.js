// Token mask (BH-9800): the second wall behind "no log line carries a field
// value". maskTokens(s) replaces each Sentry token (sntry<letter>_...) and each
// PostHog key (ph<letter>_...) in s with its prefix and ***. Every console line
// of routes/signal-keys.js and lib/signal-probe.js passes through it.
const TOKEN_RE = /\b(sntry[a-z]_|ph[a-z]_)[A-Za-z0-9_=+/.-]+/g;

export function maskTokens(s) {
  return String(s === undefined || s === null ? "" : s).replace(TOKEN_RE, "$1***");
}

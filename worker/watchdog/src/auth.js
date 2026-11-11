/**
 * Watchdog route auth (docs/watchdog-spec.md "Auth").
 *
 * Phase 1 of BH-9264. A caller sends `Authorization: Bearer <secret>`. The
 * legacy `?s=<secret>` query is still accepted, and each use writes ONE log
 * line `watchdog query-auth route=<path> box=<name|->`, so the operator can
 * count the callers that still need to move before phase 2 removes it.
 *
 * Fleet routes take WATCHDOG_SECRET, or HARNESS_SECRET as the phase 1
 * fallback. A header match on HARNESS_SECRET while WATCHDOG_SECRET is set
 * writes ONE `watchdog fallback-auth ...` line. If the two secrets are equal,
 * the separation is fake, so every fleet route answers 500 and compares nothing.
 *
 * The stamp route takes STAMP_SECRET only, on the same two transports.
 *
 * A header that is present decides alone: a wrong header is 403, with no
 * fall-through to `?s=`. Log lines never hold a secret or the query string.
 * Each function returns null (allowed) or the Response to send.
 */

export const MISCONFIG = "watchdog misconfigured: WATCHDOG_SECRET must differ from HARNESS_SECRET";

const enc = new TextEncoder();

// Constant-time compare over the UTF-8 bytes. The length difference is folded
// into the result, so the loop always runs over the longer input.
function safeEqual(a, b) {
  const x = enc.encode(a), y = enc.encode(b);
  const n = Math.max(x.length, y.length);
  let d = x.length ^ y.length;
  for (let i = 0; i < n; i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

// The token of `Bearer <token>` (scheme case-insensitive), else null.
function bearer(h) {
  const m = /^Bearer\s+(\S+)$/i.exec(h);
  return m ? m[1] : null;
}

const deny = () => new Response("no", { status: 403 });

export function fleetAuth(req, url, env, box = null) {
  const wd = env.WATCHDOG_SECRET || "", hs = env.HARNESS_SECRET || "";
  if (wd && hs && wd === hs) {
    console.error(MISCONFIG);
    return new Response(MISCONFIG, { status: 500 });
  }
  const tag = `route=${url.pathname} box=${box || "-"}`;
  const h = req.headers.get("authorization");
  if (h !== null) {
    const tok = bearer(h);
    if (!tok) return deny();
    if (wd && safeEqual(tok, wd)) return null;
    if (hs && safeEqual(tok, hs)) {
      if (wd) console.log(`watchdog fallback-auth ${tag}`);
      return null;
    }
    return deny();
  }
  const s = url.searchParams.get("s");
  if (s && ((wd && safeEqual(s, wd)) || (hs && safeEqual(s, hs)))) {
    console.log(`watchdog query-auth ${tag}`);
    return null;
  }
  return deny();
}

export function stampAuth(req, url, env) {
  const st = env.STAMP_SECRET || "";
  if (!st) return deny();
  const h = req.headers.get("authorization");
  if (h !== null) {
    const tok = bearer(h);
    return tok && safeEqual(tok, st) ? null : deny();
  }
  const s = url.searchParams.get("s");
  if (s && safeEqual(s, st)) {
    console.log(`watchdog query-auth route=${url.pathname} box=-`);
    return null;
  }
  return deny();
}

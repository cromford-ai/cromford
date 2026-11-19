// The signal key vendor seam (BH-9800): the ONLY file that calls Sentry or
// PostHog. The test route (routes/signal-keys.js) builds the probe URL here and
// calls probeSignal; tests replace globalThis.fetch with a stub.
//
// probeUrl(kind, fields) -> {ok:true, url} | {ok:false, why}
//   Fills kind.test_template: each {field} is URL-encoded, except the host
//   field (kind.host_field), which is the normalized origin. The final URL must
//   be https:, on a host in kind.host_allow, with no port and no userinfo.
// probeSignal({url, secret, timeoutMs}) -> {result, status}
//   One GET with Authorization: Bearer <secret>, redirect:'manual' (a redirect
//   is a result, never followed, so the key never goes to a second host) and an
//   AbortController timeout. The answer body is never read into a result.
// classify(status | error) -> ok | http_<n> | timeout | network
// reasonOf(result) -> a fixed short text; never vendor text, never the key.
import { maskTokens } from "./token-mask.js";

export const allowList = (csv) => String(csv || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);

// The origin `https://<host>` of v when it is an https URL with only a host on
// the allow list (a trailing slash is dropped, the case is lowered), else null.
export function normalizeHost(v, allow) {
  let u;
  try { u = new URL(String(v || "").trim()); } catch { return null; }
  if (u.protocol !== "https:" || u.username || u.password || u.port) return null;
  if ((u.pathname !== "/" && u.pathname !== "") || u.search || u.hash) return null;
  const host = u.hostname.toLowerCase();
  return allow.includes(host) ? `https://${host}` : null;
}

export function probeUrl(kind, fields) {
  const allow = allowList(kind && kind.host_allow);
  let bad = null;
  const filled = String((kind && kind.test_template) || "").replace(/\{([a-z0-9_]+)\}/g, (_, name) => {
    const v = fields && fields[name];
    if (typeof v !== "string" || v === "") { bad = bad || `no ${name}`; return ""; }
    if (kind.host_field && name === kind.host_field) {
      const origin = normalizeHost(v, allow);
      if (!origin) bad = bad || "host not allowed";
      return origin || "";
    }
    return encodeURIComponent(v);
  });
  if (bad) return { ok: false, why: bad };
  let u;
  try { u = new URL(filled); } catch { return { ok: false, why: "bad url" }; }
  if (u.protocol !== "https:" || u.username || u.password || u.port || !allow.includes(u.hostname.toLowerCase())) {
    return { ok: false, why: "host not allowed" };
  }
  return { ok: true, url: u.toString() };
}

export function classify(x) {
  if (typeof x === "number") {
    if (x === 200 || x === 204) return "ok";
    return Number.isInteger(x) && x >= 100 && x <= 599 ? `http_${x}` : "network";
  }
  const name = x && x.name;
  return name === "AbortError" || name === "TimeoutError" ? "timeout" : "network";
}

const REASONS = {
  ok: "the key works",
  http_401: "the key was refused",
  http_403: "the key lacks a scope",
  http_404: "check the organization or project",
  http_429: "rate limited, try again later",
  timeout: "the vendor did not answer in time",
  network: "the vendor could not be reached",
  key_missing: "the worker key is missing",
  decrypt_failed: "the stored key does not decrypt",
  bad_url: "the probe URL is not allowed",
};
export function reasonOf(result) {
  if (REASONS[result]) return REASONS[result];
  const m = /^http_(\d{3})$/.exec(String(result));
  if (m && m[1][0] === "5") return "the vendor failed";
  if (m && m[1][0] === "3") return "the vendor answered with a redirect";
  return m ? `the vendor answered HTTP ${m[1]}` : "unknown result";
}

export async function probeSignal({ url, secret, timeoutMs }) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method: "GET",
      headers: { authorization: `Bearer ${secret}`, accept: "application/json" },
      redirect: "manual",
      signal: ac.signal,
    });
    try { await res.body?.cancel(); } catch { /* the body is not read */ }
    const result = classify(res.status);
    return { result, status: result === "network" ? null : res.status };
  } catch (e) {
    const result = ac.signal.aborted ? "timeout" : classify(e);
    if (result === "network") console.warn(maskTokens(`[signal-probe] network error: ${String((e && e.message) || e).slice(0, 200)}`));
    return { result, status: null };
  } finally {
    clearTimeout(timer);
  }
}

// ── A D1 overload give-up is a 503 on EVERY route (BH-9249) ─────────────────
// Sentry CROMFORD-HARNESS-24: withD1Retry (lib/d1-retry.js) rethrows a
// "D1 DB is overloaded" rejection after its last attempt. Only some routes
// catch that themselves (lib/http.js d1OverloadGuarded, routes/verdict.js
// overloadGiveUp, steer, flags, gh-budget). Out of any other route (GET
// /api/jobs is one) the give-up left fetch as an unhandled Error: a 500 with
// no body, and one Sentry event per give-up.
//
// withOverloadAnswer wraps the whole fetch, so a give-up from ANY route, open
// or gated, answers 503 {error:"D1 overloaded", detail, retryable:true,
// d1_attempts, route} with a retry-after header. bin/lib/jobs/req.sh retries
// a 503 whose body says "overloaded". Route-level guards still answer first.
//
// The streak and the Sentry rule are the BH-7541 ones (lib/d1-giveup.js): one
// upsert on the raw binding per give-up, and a Sentry event only on every Nth
// give-up of a streak, tagged d1_route (this route key) and d1_op (the
// statement, set by withD1Retry). Every other error is rethrown as the same
// object, so withHarnessSentry still reports a real bug.
//
// A WRITE is not retryable. req.sh re-sends any 503 whose body says
// "overloaded", whatever the method, and a write route can give up AFTER an
// earlier statement committed (BH-6805: the flags read-back after a committed
// batch). A re-send would write twice. So a method other than GET/HEAD
// answers 503 {error:"D1 unavailable", retryable:false, written:"unknown",
// d1_attempts, route} with no retry-after and without the word "overloaded":
// the client sees what it saw before (a 5xx it does not re-send), and the
// worker still throws nothing.
//
// No D1 read in the overload branch: the retry-after knob comes from the
// settings snapshot already in memory (peekSetting), like the retry knobs.
import { isD1Overloaded, retryingDb } from "./d1-retry.js";
import { recordGiveUp } from "./d1-giveup.js";
import { peekSetting } from "./settings-cache.js";
import { captureException } from "./sentry.js";
import { json, nowIso } from "./http.js";

// index.js takes retryingDb from here with withOverloadAnswer, on one import
// line, so the list file index.js does not grow (BH-6738 list-file lint).
export { retryingDb };

export const D1_OVERLOAD_RETRY_AFTER_S = 2; // fallback for settings row d1_overload.retry_after_s
const RETRY_AFTER_KEY = "d1_overload.retry_after_s";
const RETRY_AFTER_MAX_S = 60;

// The resource-window rejection without the "D1 DB is overloaded" prefix, in
// case D1 sends it bare. Answered only: withD1Retry does NOT retry it, because
// a retry inside the same 10 s window adds load.
const RESOURCE_WINDOW = /Too many resources consumed within/;

export function isD1OverloadAnswer(e) {
  if (!e || typeof e !== "object" || typeof e.message !== "string") return false;
  return isD1Overloaded(e) || RESOURCE_WINDOW.test(e.message);
}

// "<METHOD> /seg1/seg2/seg3": at most 3 path segments, a segment with a digit
// or over 32 chars is ":id", cut to 80 chars (the d1_op tag cap). The key is
// the d1_overload_streaks primary key, so it must stay a bounded set.
const KEY_SEGMENTS = 3;
const SEGMENT_MAX = 32;
const KEY_MAX = 80;

export function overloadRouteKey(method, path) {
  const segs = String(path || "").split("/").filter(Boolean).slice(0, KEY_SEGMENTS)
    .map((s) => (/\d/.test(s) || s.length > SEGMENT_MAX ? ":id" : s));
  return `${String(method || "-")} /${segs.join("/")}`.slice(0, KEY_MAX);
}

// The retry hint in seconds, from memory only; a whole number 1..60, else 2.
export function retryAfterS(db) {
  const v = peekSetting(retryingDb(db), RETRY_AFTER_KEY);
  if (typeof v !== "string" || !/^\d+$/.test(v)) return D1_OVERLOAD_RETRY_AFTER_S;
  const n = Number(v);
  return n >= 1 && n <= RETRY_AFTER_MAX_S ? n : D1_OVERLOAD_RETRY_AFTER_S;
}

const SAFE_METHODS = new Set(["GET", "HEAD"]);

export function withOverloadAnswer(handler) {
  const inner = handler.fetch;
  return {
    ...handler,
    async fetch(req, env, ctx) {
      try {
        return await inner.call(handler, req, env, ctx);
      } catch (e) {
        if (!isD1OverloadAnswer(e)) throw e;
        const route = overloadRouteKey(req.method, new URL(req.url).pathname);
        const g = await recordGiveUp(env, route, nowIso());
        const attempts = typeof e.d1Attempts === "number" ? e.d1Attempts : null;
        console.warn(`d1-overload: ${route} answered 503 after ${attempts ?? "?"} attempt(s), streak ${g.consecutive}`);
        e.d1Route = route;
        e.d1GiveUps = g.consecutive;
        if (g.report) await captureException(e, env);
        if (!SAFE_METHODS.has(req.method)) {
          return json(503, { error: "D1 unavailable", retryable: false, written: "unknown", d1_attempts: attempts, route });
        }
        const res = json(503, {
          error: "D1 overloaded", detail: String(e.message).slice(0, 200), retryable: true,
          d1_attempts: attempts, route,
        });
        res.headers.set("retry-after", String(retryAfterS(env && env.DB)));
        return res;
      }
    },
  };
}

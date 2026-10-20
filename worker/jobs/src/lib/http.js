// harness-jobs — the three things every route needs from the request, in one
// place (BH-1195): the clock, the JSON response, and the bearer.
//
// Split out of src/index.js, where `nowIso` and `json` were the first two
// functions in the file and the bearer check was four lines inside `fetch`.
// Nothing here changed shape: the same header is read, the same comparison is
// made, the same body is serialised with the same content-type.

import { isD1Overloaded } from "./d1-retry.js";

export function nowIso() { return new Date().toISOString().replace(/\.\d{3}Z$/, "Z"); }

export function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ── A missing table is an ANSWER, not a 1101 (BH-1000, 2026-09-19) ──────────
// An uncaught throw inside fetch() is an HTTP 500 with NO BODY, which every
// client in this fleet reads as "the worker is down". That is precisely wrong
// for the one failure that has now happened twice: the code deployed and its
// table did not. `bin/hub-lease.sh` reported a transport outage for 29 minutes
// while 52 gated cron lanes skipped, and `GET /api/settings/<key>` had been
// 500ing for three weeks with every knob reader silently on its code default.
//
// 503 is the honest status — the route exists, its storage does not — and the
// body names the table, so the line in logs/jobs-client.log says what to fix
// instead of sending an operator to look for a network problem.
//
// The classification is NARROW on purpose (D10): only `no such table` is
// "schema not applied". A lock, a syntax error, a bad binding — those answer
// "<table> unavailable", because telling an operator to apply a schema that is
// already there costs them the whole search.
//
// It lives here, beside `json`, because it IS an answer: BH-1195 moved the
// route bodies into ./routes/*.js, and a guard imported from one route family
// by another would make the two lease/settings modules depend on each other.
export async function d1Guarded(table, fn) {
  try {
    return await fn();
  } catch (e) {
    const detail = String((e && e.message) || e).slice(0, 200);
    if (/no such table/i.test(detail)) return json(503, { error: `${table} schema not applied`, detail });
    return json(503, { error: `${table} unavailable`, detail });
  }
}

// ── A D1 overload is a 503, everything else still throws (BH-6805) ───────────
// withD1Retry (BH-6690) rethrows an overload after its last attempt. On a route
// whose "no row" answer means "off" to a box, that give-up must not become a
// default: it is a 503 whose body says "overloaded", the answer
// bin/lib/jobs/req.sh retries once and flag_fetch serves from its last-good
// cache. NARROWER than d1Guarded on purpose (D10): only isD1Overloaded is
// answered here, and every other error is rethrown as the same object, so
// withSentry still reports a real bug.
export async function d1OverloadGuarded(table, fn, label = "") {
  try {
    return await fn();
  } catch (e) {
    if (!isD1Overloaded(e)) throw e;
    console.warn(`d1-overload: ${table}${label ? " " + label : ""} answered 503 after ${e.d1Attempts ?? "?"} attempt(s)`);
    return json(503, { error: `${table} unavailable`, detail: String(e.message).slice(0, 200), retryable: true, d1_attempts: e.d1Attempts ?? null });
  }
}

// A route handler wrapped in d1OverloadGuarded (BH-7580): the history routes
// that call readHistory answered a give-up as a thrown 500 and a Sentry event.
// The wrap is the whole handler, so no body is re-indented.
export function overloadGuardedRoute(table, handler) {
  return (ctx) => d1OverloadGuarded(table, () => handler(ctx));
}

// One credential, the one every box already holds. No CF token on a box.
//
// UNSET IS DENIED, NOT ALLOWED. A worker deployed without HARNESS_SECRET must
// refuse everything rather than open everything: `!env.HARNESS_SECRET` is the
// first half of the test on purpose, and moving it behind the comparison would
// make an empty bearer match an unset secret.
export function bearerOk(req, env) {
  const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  return Boolean(env.HARNESS_SECRET) && auth === env.HARNESS_SECRET;
}

// The JSON body, for the methods that carry one. A malformed body is `{}` and
// not a 400: every route that needs a field validates that field itself, and
// answers with the name of the field rather than "bad JSON".
export async function readBody(req) {
  return req.method === "POST" || req.method === "PUT" || req.method === "PATCH" || req.method === "DELETE"
    ? await req.json().catch(() => ({}))
    : {};
}

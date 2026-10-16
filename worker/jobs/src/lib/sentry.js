// Exception reporting to Sentry for a harness worker (BH-5618).
//
// The Cloud worker's copy of this file moved to example-org/cromford-web
// (BH-5239), so this copy has no twin in this repo.
//
// OFF UNLESS CONFIGURED. Without the HARNESS_SENTRY_DSN binding the handler
// runs exactly as written and the SDK is never imported. The import is lazy on
// purpose: about 100 shell suites run single worker files with node from a
// checkout that never ran `npm ci`, and wrangler's bundler still includes a
// dynamic import. It also matters at runtime: the SDK caches one client per
// isolate with the DSN of its first init, so a no-DSN pass through withSentry
// would leave a DSN-less client behind.
//
// The inner handler gets the ORIGINAL env. withSentry hands it a Proxy that
// routes every D1 call through Sentry's D1 instrumentation; a request-keyed
// WeakMap gives the handler back the env the runtime passed.
//
// beforeSend is the spend gate, and it runs before the transport sends:
//   - kill switch (pauseFlags workers only): pause_flags row
//     lane-off-sentry-report with active=1 drops the event. A failed read sends
//     (fail-open: D1 is often the thing that is failing);
//   - cap: at most HARNESS_SENTRY_MAX_PER_FP_HOUR events (default 6) per
//     worker + exception type + message head per UTC hour, per isolate;
//   - tags lane/box/project/harness_sha (harness_sync's deploy sets
//     HARNESS_SHA to the snapshot sha, BH-6813), and d1_attempts plus d1_op
//     on a D1 overload give-up (lib/d1-retry.js), then scrubEvent.

let sdk;
let sdkFailed = false;
const loadSdk = () => (sdk ||= import("@sentry/cloudflare"));

let currentEnv = {}; // the env of the latest armed invocation in this isolate
const seen = new Map(); // cap key -> { hour, n }
const DEFAULT_MAX_PER_FP_HOUR = 6;
const PAUSE_FLAG = "lane-off-sentry-report";

const SECRET_KEY = /authorization|cookie|token|secret/i;

function dropSecretKeys(obj, depth = 0) {
  if (!obj || typeof obj !== "object" || depth > 5) return;
  for (const k of Object.keys(obj)) {
    if (SECRET_KEY.test(k)) delete obj[k];
    else dropSecretKeys(obj[k], depth + 1);
  }
}

export function scrubEvent(event) {
  const r = event.request;
  if (r) {
    delete r.data;
    delete r.cookies;
    delete r.query_string;
    if (typeof r.url === "string") r.url = r.url.split("?")[0];
    dropSecretKeys(r.headers);
  }
  dropSecretKeys(event.extra);
  dropSecretKeys(event.contexts);
  for (const b of event.breadcrumbs || []) dropSecretKeys(b && b.data);
  return event;
}

function maxPerHour(env) {
  const n = parseInt(env.HARNESS_SENTRY_MAX_PER_FP_HOUR, 10);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_MAX_PER_FP_HOUR;
}

async function paused(env) {
  try {
    const row = await env.DB.prepare("SELECT active FROM pause_flags WHERE name = ?1").bind(PAUSE_FLAG).first();
    return Boolean(row) && Number(row.active) === 1;
  } catch {
    return false;
  }
}

function overCap(event, worker, env) {
  const ex = (event.exception && event.exception.values && event.exception.values[0]) || {};
  const key = `${worker}|${ex.type || "-"}|${String(ex.value || event.message || "").slice(0, 120)}`;
  const hour = Math.floor(Date.now() / 3600000);
  if (seen.size > 500) for (const [k, v] of seen) if (v.hour !== hour) seen.delete(k);
  const slot = seen.get(key);
  const cur = slot && slot.hour === hour ? slot : { hour, n: 0 };
  if (cur.n >= maxPerHour(env)) return true;
  cur.n += 1;
  seen.set(key, cur);
  return false;
}

async function gate(event, worker, pauseFlags, hint) {
  const env = currentEnv;
  if (pauseFlags && (await paused(env))) return null;
  if (overCap(event, worker, env)) return null;
  event.tags = {
    ...event.tags,
    lane: worker,
    box: "cloudflare",
    project: "-",
    harness_sha: env.HARNESS_SHA || "unknown",
  };
  // BH-6690: lib/d1-retry.js marks a D1 overload it gave up on.
  const ex = hint && hint.originalException;
  if (ex && typeof ex.d1Attempts === "number") event.tags.d1_attempts = String(ex.d1Attempts);
  if (ex && typeof ex.d1Op === "string") event.tags.d1_op = ex.d1Op;
  return scrubEvent(event);
}

export function sentryOptions(env, worker, pauseFlags = false) {
  return {
    dsn: env.HARNESS_SENTRY_DSN,
    sendDefaultPii: false,
    maxRequestBodySize: "none",
    sampleRate: 1.0,
    tracesSampleRate: 0,
    beforeSend: (event, hint) => gate(event, worker, pauseFlags, hint),
  };
}

async function sdkOrNull() {
  try {
    return await loadSdk();
  } catch (e) {
    if (!sdkFailed) console.error(`sentry: @sentry/cloudflare failed to load, reporting is off: ${(e && e.message) || e}`);
    sdkFailed = true;
    return null;
  }
}

export function withHarnessSentry(handler, { worker, pauseFlags = false }) {
  for (const m of ["fetch", "scheduled"]) {
    const plain = handler[m];
    if (typeof plain !== "function") continue;
    const envOf = new WeakMap();
    let wrapped;
    handler[m] = function (arg, env, ctx) {
      if (!env || !env.HARNESS_SENTRY_DSN) return plain.call(handler, arg, env, ctx);
      return (async () => {
        const S = await sdkOrNull();
        if (!S) return plain.call(handler, arg, env, ctx);
        currentEnv = env;
        envOf.set(arg, env);
        if (!wrapped) {
          const inner = { [m]: (a, _sentryEnv, c) => plain.call(handler, a, envOf.get(a), c) };
          S.withSentry((e) => sentryOptions(e, worker, pauseFlags), inner);
          wrapped = inner[m];
        }
        return wrapped(arg, env, ctx);
      })();
    };
  }
  return handler;
}

// For a worker that turns a throw into a response itself (harness-cloud's
// catch), so withSentry never sees it. Never throws.
export async function captureException(e, env) {
  if (!env || !env.HARNESS_SENTRY_DSN) return;
  try {
    const S = await sdkOrNull();
    if (S) S.captureException(e);
  } catch {
    // reporting must never change the response
  }
}

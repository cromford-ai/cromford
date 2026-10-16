// D1 overload retry (BH-6690).
//
// D1 rejects a query with "D1_ERROR: D1 DB is overloaded. Requests queued for
// too long." (or "... Too many requests queued.") when its queue is full. The
// worker sent every query once, so one such rejection failed the request:
// Sentry issue CROMFORD-HARNESS-W counted 113 in 24 h.
//
// index.js wraps env.DB with retryingDb() once per request, so every route
// gets the retry with no route edit. Only the overload message is retried:
// D1 rejects it at the queue, before the query runs, so a retried write never
// lands twice, and a batch is one transaction (all or nothing). Every other
// error rethrows after one call.
//
// On give-up the SAME error is rethrown with e.d1Attempts set, and with
// e.d1Op ("<method> <VERB> <table>", see d1OpOf) when the call names its SQL.
// lib/sentry.js turns those into tags d1_attempts and d1_op on the one event
// withSentry already sends, so there is no second capture here.
//
// 5 attempts at a 100 ms base sleep 750..1500 ms in total before a give-up.
// That stays well under the 8 s curl timeout most jobs clients use
// (`-m "${JOBS_TIMEOUT:-8}"`, for example bin/lead-verdict.sh).
//
// The attempts and backoff are code constants on purpose: they bound a retry
// against a D1 that is overloaded, so they cannot be read from D1 in the same
// request (same rule as MODE_RETRY_DELAY_MS in routes/verdicts.js, BH-5773).
export const D1_RETRY_ATTEMPTS = 5;
export const D1_RETRY_BASE_MS = 100;
export const D1_RETRY_MAX_MS = 1000;

const OVERLOADED = "D1 DB is overloaded";

export function isD1Overloaded(e) {
  return Boolean(e) && typeof e.message === "string" && e.message.includes(OVERLOADED);
}

const realSleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Wait before attempt n+1: d = min(max, base * 2^(n-1)), then d/2 + random*d/2.
export async function withD1Retry(fn, opts = {}) {
  const sleep = opts.sleep || realSleep;
  const random = opts.random || Math.random;
  for (let n = 1; ; n++) {
    try {
      return await fn();
    } catch (e) {
      if (!isD1Overloaded(e)) throw e;
      if (n >= D1_RETRY_ATTEMPTS) {
        e.d1Attempts = n;
        if (typeof opts.op === "string") e.d1Op = opts.op;
        if (opts.onGiveUp) opts.onGiveUp(e, n);
        throw e;
      }
      const d = Math.min(D1_RETRY_MAX_MS, D1_RETRY_BASE_MS * 2 ** (n - 1));
      await sleep(d / 2 + random() * (d / 2));
    }
  }
}

// "<method> <VERB> <table>" for a Sentry tag: the first SQL keyword and the
// table after FROM / INTO / UPDATE / TABLE (or a PRAGMA's argument). String
// literals and comments are cut out first and only identifiers are kept, so
// no literal or bound value reaches the tag. A missing part is "-".
const OP_MAX = 80;
const TABLE_AFTER =
  /\b(?:FROM|INTO|UPDATE(?:\s+OR\s+[A-Z]+)?|TABLE(?:\s+IF\s+(?:NOT\s+)?EXISTS)?)\s+[`"[]?([A-Z_][A-Z0-9_]*)|^PRAGMA\s+[A-Z_]+\s*\(\s*[`"[]?([A-Z_][A-Z0-9_]*)/i;

export function d1OpOf(method, sql) {
  let verb = "-";
  let table = "-";
  if (typeof sql === "string") {
    const s = sql
      .replace(/'(?:[^']|'')*'/g, "''")
      .replace(/--[^\n]*/g, " ")
      .replace(/\/\*[\s\S]*?\*\//g, " ")
      .trim();
    const v = /^[A-Za-z]+/.exec(s);
    if (v) verb = v[0].toUpperCase();
    const t = TABLE_AFTER.exec(s);
    if (t) table = t[1] || t[2];
  }
  return `${method} ${verb} ${table}`.slice(0, OP_MAX);
}

const RETRIED = new Set(["first", "all", "run", "raw"]);
const rawOf = new WeakMap(); // statement proxy -> raw statement
const sqlOf = new WeakMap(); // statement proxy -> the SQL given to prepare()

// A real D1 object keeps internal state, so a method must run with `this` as
// the raw target, never the proxy.
function passThrough(target, prop) {
  const v = target[prop];
  return typeof v === "function" ? v.bind(target) : v;
}

function wrapStatement(stmt, sql) {
  if (!stmt || typeof stmt !== "object") return stmt;
  const p = new Proxy(stmt, {
    get(target, prop) {
      if (prop === "bind") return (...a) => wrapStatement(target.bind(...a), sql);
      if (RETRIED.has(prop) && typeof target[prop] === "function") {
        return (...a) => withD1Retry(() => target[prop](...a), { op: d1OpOf(prop, sql) });
      }
      return passThrough(target, prop);
    },
  });
  rawOf.set(p, stmt);
  sqlOf.set(p, sql);
  return p;
}

// The raw binding behind a retryingDb proxy, else db itself. lib/core.js keys
// its ensureTable/ensureColumns caches on it, so a caller that holds the raw
// binding and the wrapped env share one cache entry.
export function rawDb(db) {
  return rawDbOf.get(db) || db;
}
const rawDbOf = new WeakMap(); // db proxy -> raw binding

// Memoised per raw binding: ensureTable/ensureColumns, settings-cache and the
// verdicts modeCache key their caches on env.DB, so a new proxy per request
// would miss every one of them and ADD D1 load.
const dbProxies = new WeakMap();

export function retryingDb(db) {
  if (!db || typeof db !== "object") return db;
  let p = dbProxies.get(db);
  if (p) return p;
  p = new Proxy(db, {
    get(target, prop) {
      if (prop === "prepare") return (sql, ...a) => wrapStatement(target.prepare(sql, ...a), sql);
      if (prop === "batch") {
        return (stmts, ...rest) => {
          const list = Array.isArray(stmts);
          const raw = list ? stmts.map((s) => rawOf.get(s) || s) : stmts;
          const op = d1OpOf(`batch(${list ? stmts.length : "-"})`, list ? sqlOf.get(stmts[0]) : undefined);
          return withD1Retry(() => target.batch(raw, ...rest), { op });
        };
      }
      if (prop === "exec") return (sql, ...a) => withD1Retry(() => target.exec(sql, ...a), { op: d1OpOf("exec", sql) });
      return passThrough(target, prop);
    },
  });
  dbProxies.set(db, p);
  rawDbOf.set(p, db);
  return p;
}

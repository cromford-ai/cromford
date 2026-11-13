// harness-jobs — the D1 statement counter (BH-9076, slice 5 of BH-9067).
//
// WHAT IT COUNTS. On a sampled request, every statement the request runs on
// env.DB is counted under (hour, hash of its normalized SQL): calls += 1, and
// rows_read += meta.rows_read when D1 reports it. all(), run() and each
// statement of a batch() carry meta; first() and raw() do not, so they add a
// call with 0 rows_read. A statement that throws is still a call. A retried
// attempt (lib/d1-retry.js sits inside this wrap) is one more call: it is real
// D1 load.
//
// SAMPLING. A request is sampled when d1.stmt_stats_sample_pct > 0 and
// random() * 100 < pct (100 = every request, 0 = none). An unsampled request
// gets env unchanged: the same env.DB object, so zero added work. The stats DB
// is memoised per binding, like retryingDb, so the ensureTable, archive-read
// and settings-cache caches keep one stable key on a sampled request too.
//
// ONLY WITH ctx.waitUntil. The knob read and the flush run in ctx.waitUntil,
// after the Response, so the counter never adds latency to a request. A call
// with no ctx (the node test suites call worker.fetch(req, env)) is never
// sampled and reads nothing. Until the knobs have been read once in this
// isolate, no request is sampled: a pct of 0 in the settings row is never
// overridden by the code fallback.
//
// THE FLUSH. After a sampled request, the isolate's accumulator is swapped out
// and written in ONE batch of upserts into d1_stmt_stats (PK hour, sql_hash;
// the upsert adds, so two isolates flushing one hour sum). It writes through
// the raw binding, so the flush and the knob read never count themselves. A
// flush that fails logs one line and drops those counts: they are stats only,
// never user data. Over d1.stmt_stats_max_keys distinct keys, new statements
// count under the hash `overflow` so the cap is visible in /top.
//
// Knobs (settings rows, worker/jobs/schema.d/202611070338-bh-9076-d1-stmt-stats.sql):
// read with one statement, again when older than d1.stmt_stats_refresh_s.

import { markWrapper } from "./db-root.js";

const KNOB_KEYS = {
  pct: "d1.stmt_stats_sample_pct",
  refreshS: "d1.stmt_stats_refresh_s",
  sqlMaxChars: "d1.stmt_stats_sql_max_chars",
  maxKeys: "d1.stmt_stats_max_keys",
};
// Code fallbacks, each [default, min, max]; each names its settings row above.
const KNOB_DEFAULTS = {
  pct: [1, 0, 100],             // d1.stmt_stats_sample_pct
  refreshS: [300, 10, 3600],    // d1.stmt_stats_refresh_s
  sqlMaxChars: [500, 50, 4000], // d1.stmt_stats_sql_max_chars
  maxKeys: [500, 10, 10000],    // d1.stmt_stats_max_keys
};
export const OVERFLOW_HASH = "overflow";
const KNOB_SQL = `SELECT key, value FROM settings WHERE key IN (${Object.keys(KNOB_KEYS).map(() => "?").join(",")})`;
const UPSERT_SQL = `INSERT INTO d1_stmt_stats (hour, sql_hash, sql_text, calls, rows_read) VALUES (?1, ?2, ?3, ?4, ?5)
  ON CONFLICT (hour, sql_hash) DO UPDATE SET calls = calls + excluded.calls, rows_read = rows_read + excluded.rows_read`;

const fallbackKnobs = () => Object.fromEntries(Object.entries(KNOB_DEFAULTS).map(([k, [d]]) => [k, d]));

// Per-isolate state. _resetStmtStats() clears it (tests only).
let acc = new Map();          // `${hour}|${hash}` -> {hour, hash, sql, calls, rows_read}
let knobs = fallbackKnobs();
let knobsAt = 0;              // ms of the last successful knob read; 0 = never
let knobsTryAt = 0;           // ms of the last attempt; the next one waits refresh_s
let knobsLoading = null;
const statsDbs = new WeakMap(); // raw binding -> stats proxy
const rawStmtOf = new WeakMap(); // stats statement proxy -> raw statement

export function _resetStmtStats() {
  acc = new Map();
  knobs = fallbackKnobs();
  knobsAt = 0;
  knobsTryAt = 0;
  knobsLoading = null;
}

// normalizeSql(sql) — the statement's shape: string and number literals are
// `?`, numbered binds are `?`, an IN list of binds is `IN (?)`, comments go,
// whitespace collapses. Pure.
export function normalizeSql(sql) {
  return String(sql)
    .replace(/'(?:[^']|'')*'/g, "?")
    .replace(/--[^\n]*/g, " ")
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/\?\d+/g, "?")
    .replace(/(?<![\w$.?])\d+(?:\.\d+)?\b/g, "?")
    .replace(/\s+/g, " ")
    .replace(/\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/gi, "IN (?)")
    .trim();
}

// sqlHash(normalized) — FNV-1a 64 bit of the UTF-8 text, 16 hex chars.
const FNV_OFFSET = 0xcbf29ce484222325n;
const FNV_PRIME = 0x100000001b3n;
const MASK64 = 0xffffffffffffffffn;
export function sqlHash(text) {
  let h = FNV_OFFSET;
  for (const b of new TextEncoder().encode(String(text))) {
    h ^= BigInt(b);
    h = (h * FNV_PRIME) & MASK64;
  }
  return h.toString(16).padStart(16, "0");
}

// The sampling decision. Pure: pct is the knob, r is random() in [0, 1).
export function sampled(pct, r) {
  return pct > 0 && r * 100 < pct;
}

const hourNow = () => new Date().toISOString().slice(0, 13);

function count(sql, rowsRead) {
  const hour = hourNow();
  const norm = normalizeSql(sql);
  let hash = sqlHash(norm);
  let key = `${hour}|${hash}`;
  let e = acc.get(key);
  if (!e && acc.size >= knobs.maxKeys) {
    hash = OVERFLOW_HASH;
    key = `${hour}|${hash}`;
    e = acc.get(key);
    if (!e) { e = { hour, hash, sql: "(overflow)", calls: 0, rows_read: 0 }; acc.set(key, e); }
  }
  if (!e) { e = { hour, hash, sql: norm, calls: 0, rows_read: 0 }; acc.set(key, e); }
  e.calls += 1;
  const n = Number(rowsRead);
  if (Number.isFinite(n) && n > 0) e.rows_read += n;
}

const rowsOf = (res) => (res && res.meta ? res.meta.rows_read : undefined);

function passThrough(target, prop) {
  const v = target[prop];
  return typeof v === "function" ? v.bind(target) : v;
}

// One counted call: count once whether it resolves or throws.
async function counted(sql, fn, meta) {
  let res;
  try {
    res = await fn();
    return res;
  } finally {
    count(sql, meta ? rowsOf(res) : undefined);
  }
}

function statsStatement(stmt, sql) {
  if (!stmt || typeof stmt !== "object") return stmt;
  const p = new Proxy(stmt, {
    get(target, prop) {
      if (prop === "bind") return (...a) => statsStatement(target.bind(...a), sql);
      if (prop === "all" || prop === "run") return (...a) => counted(sql, () => target[prop](...a), true);
      if (prop === "first" || prop === "raw") return (...a) => counted(sql, () => target[prop](...a), false);
      return passThrough(target, prop);
    },
  });
  rawStmtOf.set(p, { stmt, sql });
  return p;
}

// stmtStatsDb(db) — db with every statement counted. Memoised per binding.
export function stmtStatsDb(db) {
  if (!db || typeof db !== "object") return db;
  let p = statsDbs.get(db);
  if (p) return p;
  p = new Proxy(db, {
    get(target, prop) {
      if (prop === "prepare") return (sql, ...a) => statsStatement(target.prepare(sql, ...a), sql);
      if (prop === "batch") {
        return async (stmts, ...rest) => {
          const list = Array.isArray(stmts) ? stmts : [];
          const raw = list.map((s) => (rawStmtOf.get(s) || { stmt: s }).stmt);
          const sqls = list.map((s) => (rawStmtOf.get(s) || { sql: "(batch statement)" }).sql);
          let res;
          try {
            res = await target.batch(Array.isArray(stmts) ? raw : stmts, ...rest);
            return res;
          } finally {
            sqls.forEach((sql, i) => count(sql, rowsOf(Array.isArray(res) ? res[i] : undefined)));
          }
        };
      }
      if (prop === "exec") return (sql, ...a) => counted(sql, () => target.exec(sql, ...a), false);
      return passThrough(target, prop);
    },
  });
  statsDbs.set(db, p);
  markWrapper(p, db); // BH-9657: caches key on the binding under this proxy
  return p;
}

function knobValue(byKey, name) {
  const [def, min, max] = KNOB_DEFAULTS[name];
  const v = byKey.has(KNOB_KEYS[name]) ? String(byKey.get(KNOB_KEYS[name])).trim() : "";
  if (!/^\d+$/.test(v)) return def;
  const n = Number(v);
  return n >= min && n <= max ? n : def;
}

// loadStmtStatsKnobs(rawDb, nowMs) — read the four knob rows once. A failed
// read keeps the last values and is retried after refresh_s.
export async function loadStmtStatsKnobs(db, nowMs = Date.now()) {
  knobsTryAt = nowMs;
  try {
    const res = await db.prepare(KNOB_SQL).bind(...Object.values(KNOB_KEYS)).all();
    const byKey = new Map(((res && res.results) || []).map((r) => [r.key, r.value]));
    knobs = Object.fromEntries(Object.keys(KNOB_DEFAULTS).map((k) => [k, knobValue(byKey, k)]));
    knobsAt = nowMs;
  } catch (e) {
    console.warn(`stmt-stats: knob read failed, keeping the last values: ${String((e && e.message) || e).slice(0, 200)}`);
  }
  return knobs;
}

function refreshKnobs(db, ctx) {
  const now = Date.now();
  if (knobsLoading || (knobsTryAt !== 0 && now - knobsTryAt < knobs.refreshS * 1000)) return;
  knobsLoading = loadStmtStatsKnobs(db, now).finally(() => { knobsLoading = null; });
  ctx.waitUntil(knobsLoading);
}

// flushStmtStats(rawDb) — write the accumulator in one batch. Never throws.
// Returns the number of rows written (0 when empty or on a failure).
export async function flushStmtStats(db) {
  if (acc.size === 0) return 0;
  const entries = [...acc.values()];
  acc = new Map();
  try {
    await db.batch(entries.map((e) => db.prepare(UPSERT_SQL)
      .bind(e.hour, e.hash, e.sql.slice(0, knobs.sqlMaxChars), e.calls, e.rows_read)));
    return entries.length;
  } catch (e) {
    console.warn(`stmt-stats: flush of ${entries.length} key(s) dropped: ${String((e && e.message) || e).slice(0, 200)}`);
    return 0;
  }
}

// withStmtStats(handler, {random}) — a copy of the handler object whose fetch
// counts the statements of a sampled request. Every other property is kept.
export function withStmtStats(handler, { random = Math.random } = {}) {
  const inner = handler.fetch;
  return {
    ...handler,
    async fetch(req, env, ctx) {
      const db = env && env.DB;
      if (!db || !ctx || typeof ctx.waitUntil !== "function") return inner.call(handler, req, env, ctx);
      refreshKnobs(db, ctx);
      if (knobsAt === 0 || !sampled(knobs.pct, random())) return inner.call(handler, req, env, ctx);
      try {
        return await inner.call(handler, req, { ...env, DB: stmtStatsDb(db) }, ctx);
      } finally {
        ctx.waitUntil(flushStmtStats(db));
      }
    },
  };
}

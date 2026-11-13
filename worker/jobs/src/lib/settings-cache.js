// The settings table, read once per isolate per TTL (BH-5781).
//
// GET /api/settings and GET /api/settings/<key> are the two reads every box
// makes on every lane tick, and each one was a D1 query. This keeps one
// snapshot of the whole table per isolate, keyed on the root D1 binding
// (lib/db-root.js: the binding under the retry and stmt-stats proxies, so a
// sampled request uses the same snapshot, BH-9657), and answers both routes
// from it until it is older than the TTL.
//
// ONE READ AT A TIME (BH-9657). Callers that arrive while a read of the same
// binding is in flight wait for that read; they do not start their own. A
// burst on a cold isolate is one D1 read, not one per request. A read that
// rejects rejects every waiter and is not kept, so the next caller reads again.
// A write (invalidateSettings) during a read drops that read's result: the
// waiters get it, but it is not stored.
//
// PER-ISOLATE, NOT FLEET-WIDE. Every route in this worker that writes `settings`
// calls invalidateSettings, so the isolate that took the write reads D1 again on
// its next GET. Another isolate does not hear about it: it can serve the old row
// for at most the TTL after the write. D1 stays the store of record; this is a
// read-through copy, never a write path.
//
// THE TTL, in seconds, strict integer 0..60, first source that parses wins:
//   1. the `settings_cache_ttl_s` row in the snapshot just read;
//   2. env.SETTINGS_CACHE_TTL_S (wrangler.jsonc vars);
//   3. 0.
// A value that is not an integer or is out of range is ignored, never clamped.
// 0 is OFF: the snapshot is not stored, and every read that does not join a
// read already in flight queries D1.

import { rootDb } from "./db-root.js";

const snaps = new WeakMap();    // root binding -> snapshot
const inflight = new WeakMap(); // root binding -> { promise } of the read in flight
const gens = new WeakMap();     // root binding -> count of invalidateSettings calls
const TTL_KEY = "settings_cache_ttl_s";
const TTL_MAX_S = 60;

function ttlSeconds(v) {
  if (typeof v !== "string" || !/^\d+$/.test(v)) return null;
  const n = Number(v);
  return n <= TTL_MAX_S ? n : null;
}

// -> { rows, byKey, at, ttlMs }: rows in key order, byKey a Map of key -> row.
// A D1 throw propagates to the caller's d1Guarded and nothing is stored. The
// read goes through env.DB (the caller's proxy), so it is retried and counted.
export async function settingsRows(env) {
  const root = rootDb(env.DB);
  const snap = snaps.get(root);
  if (snap && Date.now() - snap.at < snap.ttlMs) return snap;
  const running = inflight.get(root);
  if (running) return running.promise;
  const gen = gens.get(root) || 0;
  const entry = { promise: null };
  inflight.set(root, entry); // before the read starts, so its finally always sees it
  entry.promise = (async () => {
    try {
      const res = await env.DB.prepare("SELECT * FROM settings ORDER BY key ASC").all();
      const rows = res.results || [];
      const byKey = new Map(rows.map((r) => [r.key, r]));
      const row = byKey.get(TTL_KEY);
      const ttl = ttlSeconds(row ? String(row.value) : null) ?? ttlSeconds(env.SETTINGS_CACHE_TTL_S) ?? 0;
      const out = { rows, byKey, at: Date.now(), ttlMs: ttl * 1000 };
      if ((gens.get(root) || 0) === gen) {
        if (ttl > 0) snaps.set(root, out);
        else snaps.delete(root);
      }
      return out;
    } finally {
      if (inflight.get(root) === entry) inflight.delete(root);
    }
  })();
  return entry.promise;
}

// Every successful write to `settings` calls this, after the write. It also
// drops a read in flight: its waiters still get its result, but it is not stored.
export function invalidateSettings(env) {
  const root = rootDb(env.DB);
  snaps.delete(root);
  inflight.delete(root);
  gens.set(root, (gens.get(root) || 0) + 1);
}

// The value of `key` (as a string) from the snapshot stored for the root
// binding of `db` (any wrapper of it finds the same snapshot), while
// that snapshot is younger than its TTL; else null. It never queries D1 and
// never stores anything, so a reader that must add no D1 load (the overload
// retry knobs in lib/d1-retry.js, BH-9190) can use it. With TTL 0 there is no
// snapshot, so it is always null.
export function peekSetting(db, key) {
  const snap = snaps.get(rootDb(db));
  if (!snap || Date.now() - snap.at >= snap.ttlMs) return null;
  const row = snap.byKey.get(key);
  return row && row.value !== null && row.value !== undefined ? String(row.value) : null;
}

// The settings table, read once per isolate per TTL (BH-5781).
//
// GET /api/settings and GET /api/settings/<key> are the two reads every box
// makes on every lane tick, and each one was a D1 query. This keeps one
// snapshot of the whole table per isolate, keyed on the env.DB binding, and
// answers both routes from it until it is older than the TTL.
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
// 0 is OFF: the snapshot is not stored and every read queries D1.

const snaps = new WeakMap();
const TTL_KEY = "settings_cache_ttl_s";
const TTL_MAX_S = 60;

function ttlSeconds(v) {
  if (typeof v !== "string" || !/^\d+$/.test(v)) return null;
  const n = Number(v);
  return n <= TTL_MAX_S ? n : null;
}

// -> { rows, byKey }: rows in key order, byKey a Map of key -> row. A D1 throw
// propagates to the caller's d1Guarded and nothing is stored.
export async function settingsRows(env) {
  const snap = snaps.get(env.DB);
  if (snap && Date.now() - snap.at < snap.ttlMs) return snap;
  const res = await env.DB.prepare("SELECT * FROM settings ORDER BY key ASC").all();
  const rows = res.results || [];
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const row = byKey.get(TTL_KEY);
  const ttl = ttlSeconds(row ? String(row.value) : null) ?? ttlSeconds(env.SETTINGS_CACHE_TTL_S) ?? 0;
  const out = { rows, byKey, at: Date.now(), ttlMs: ttl * 1000 };
  if (ttl > 0) snaps.set(env.DB, out);
  else snaps.delete(env.DB);
  return out;
}

// Every successful write to `settings` calls this, after the write.
export function invalidateSettings(env) {
  snaps.delete(env.DB);
}

// The value of `key` (as a string) from the snapshot stored for `db`, while
// that snapshot is younger than its TTL; else null. It never queries D1 and
// never stores anything, so a reader that must add no D1 load (the overload
// retry knobs in lib/d1-retry.js, BH-9190) can use it. With TTL 0 there is no
// snapshot, so it is always null.
export function peekSetting(db, key) {
  const snap = snaps.get(db);
  if (!snap || Date.now() - snap.at >= snap.ttlMs) return null;
  const row = snap.byKey.get(key);
  return row && row.value !== null && row.value !== undefined ? String(row.value) : null;
}

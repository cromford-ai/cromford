// harness-jobs — the BH-9556 seed moves: two lanes act from the first merge.
//
// Two settings rows were seeded in a mode that computes and never acts:
//   console.needs.sweep_dry_run = 1        (BH-9117; reader bin/needs-sweep.sh)
//   scheduler.mode              = shadow   (BH-6978; readers bin/scheduler.sh,
//                                          bin/lib/sched-gate.sh, bin/fly-pool.sh,
//                                          bin/lib/rb/gates.sh)
// BH-9556 item 8/9: the lanes act, with no shadow or dry-run phase. A schema.d
// statement cannot change a row: the schema is additive and harness-sync
// re-applies it on every deploy (tests/schema-additive.bh-1000-test.sh). So,
// as BH-9177 does for the suite-trust knob (lib/suite-trust.js), the first
// settings read on each DB binding runs ONE guarded batch. Each UPDATE changes
// its row only while the row is still the untouched seed: the old value AND
// actor `seed`. An operator's row (any other actor) is never moved, so an
// operator's `1` / `shadow` / `off` stays the kill flag. A moved row carries
// actor `seed:BH-9556`, so a second run (another isolate, the next deploy)
// changes nothing. PUT /api/settings refuses actor `seed` (routes/settings.js),
// so no operator write can be taken for the seed.
//
// NEVER THROWS. Every box reads settings through the two GET routes that call
// this, so a throw here would stop the fleet. A failed batch is one
// console.warn, is NOT memoised, and the read goes on with what D1 holds; the
// next read retries. The memo is per isolate per raw binding and is only an
// optimisation: the guard in the SQL makes a re-run a no-op.
//
// Rollback: set the row back with an operator actor (PUT /api/settings).

import { rawDb } from "./d1-retry.js";

export const SEED_MOVE_ACTOR = "seed";
export const SEED_MOVED_ACTOR = "seed:BH-9556";
export const SEED_MOVE_SQL =
  "UPDATE settings SET value = ?3, note = ?4, actor = 'seed:BH-9556', updated_at = ?5 " +
  "WHERE key = ?1 AND value = ?2 AND actor = 'seed'";

export const SEED_MOVES = Object.freeze([
  Object.freeze({
    key: "console.needs.sweep_dry_run", from: "1", to: "0",
    note: "BH-9117/BH-9556: 0 = the NEEDS sweep applies (the seed since BH-9556); 1 = it decides and logs but changes no row (the kill flag). " +
      "No row = 0; an outage is exit 4 with one alert, never a dry run. Reader: bin/needs-sweep.sh",
  }),
  Object.freeze({
    key: "scheduler.mode", from: "shadow", to: "enforce",
    note: "BH-6978/BH-6979/BH-9556: enforce = the ready set decides dispatch (the seed since BH-9556; a stale set falls back to today's path); " +
      "shadow or off = the kill flags; any other value runs shadow. No row = shadow; an outage is exit 1 with one alert. " +
      "Readers: bin/scheduler.sh, bin/lib/sched-gate.sh, bin/fly-pool.sh, bin/lib/rb/gates.sh",
  }),
]);

const moved = new WeakSet();   // raw bindings whose batch already ran clean

// applySeedMoves(db, onMoved) — run the guarded moves once per raw binding.
// onMoved() runs when any UPDATE changed a row (the caller drops its settings
// snapshot there). Resolves to the per-move change counts, or null when it did
// nothing (no binding, memoised, or failed). Never rejects.
export async function applySeedMoves(db, onMoved) {
  if (!db || typeof db.prepare !== "function") return null;
  let root;
  try { root = rawDb(db); } catch { root = db; }
  if (!root || typeof root !== "object") return null;
  if (moved.has(root)) return null;
  try {
    const at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const res = await db.batch(SEED_MOVES.map((m) =>
      db.prepare(SEED_MOVE_SQL).bind(m.key, m.from, m.to, m.note, at)));
    moved.add(root);
    const changes = (res || []).map((r) => Number(r?.meta?.changes || 0));
    if (changes.some((n) => n > 0) && typeof onMoved === "function") {
      try { onMoved(); } catch { /* the snapshot ages out on its own TTL */ }
    }
    return changes;
  } catch (e) {
    console.warn(`seed-moves: BH-9556 seed move failed, retried on the next settings read: ${e && e.message}`);
    return null;
  }
}

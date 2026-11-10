// harness-jobs — the suite ledger's trust knob (BH-9063, slice C0).
//
// Which rows a lookup may serve. The settings row
// lib.suite-reuse.suite_reuse_trust (catalog/lanes.d/_lib.suite-reuse.json,
// knob SUITE_REUSE_TRUST) holds one of two values:
//   class  the BH-5354 I1 rule: a lookup matches its own ctx only, and a ci
//          (token) caller sees ci rows only. The code default (no row) and
//          the C0 seed; the C1 flip below moves the seed to image.
//   image  a lookup matches (repo, suite, fingerprint) in every class and ctx.
//          The fingerprint carries the runner image id (suite-fingerprint v3),
//          so the same fingerprint means the same image: that is the trust.
//          A fail at the key in ANY row hides every green.
// Any other value, or a settings read that throws, turns reuse OFF with a
// reason. It never falls back to the default (D11), the readReuseKnobs rule.

// The code fallback of the settings row, used only when no row exists.
// test/suite-results-retention.bh-9063.test.js pins it equal to the seed and
// the registry default.
export const TRUST_DEFAULT = "class";
export const TRUST_KEY = "lib.suite-reuse.suite_reuse_trust";
const TRUSTS = new Set(["class", "image"]);

// THE C1 FLIP (BH-9177). C1 moves the row from the C0 seed `class` to `image`.
// A schema.d statement cannot change a row: the schema is additive, because
// harness-sync re-applies it on every deploy (tests/schema-additive.bh-1000-test.sh).
// So the first trust read on each DB binding runs ONE guarded UPDATE. It changes
// the row only while it is still the untouched C0 seed (value class, actor
// seed): an operator's own value (any other actor) is kept, and a second run
// changes nothing. A failed UPDATE is ignored; the read below then answers
// what the row holds. Rollback: set the row to class with an operator actor.
export const TRUST_FLIP_SQL =
  "UPDATE settings SET value = 'image', actor = 'seed:BH-9177', updated_at = ?2, note = ?3 " +
  "WHERE key = ?1 AND value = 'class' AND actor IN ('seed', 'registry-seed')";
const TRUST_FLIP_NOTE = "BH-9063/BH-9177: class|image; class = a lookup matches its own ctx and a ci caller sees ci rows only; " +
  "image = match repo+suite+fingerprint in every class and ctx (the C1 value); any other value turns reuse off";
const flipped = new WeakSet();

async function flipSeed(db) {
  if (!db || flipped.has(db)) return;
  flipped.add(db);
  try {
    await db.prepare(TRUST_FLIP_SQL)
      .bind(TRUST_KEY, new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), TRUST_FLIP_NOTE).run();
  } catch {
    // The read below decides; a flip that did not happen leaves the old rule.
  }
}

export async function readTrustKnob(db) {
  let row;
  await flipSeed(db);
  try {
    row = await db.prepare("SELECT value FROM settings WHERE key = ?1").bind(TRUST_KEY).first();
  } catch {
    return { trust: null, reason: "settings unavailable" };
  }
  if (!row) return { trust: TRUST_DEFAULT };
  const v = row.value;
  return TRUSTS.has(v) ? { trust: v } : { trust: null, reason: "bad suite_reuse_trust" };
}

// harness-jobs — the suite ledger's trust knob (BH-9063, slice C0).
//
// Which rows a lookup may serve. The settings row
// lib.suite-reuse.suite_reuse_trust (catalog/lanes.d/_lib.suite-reuse.json,
// knob SUITE_REUSE_TRUST) holds one of two values:
//   class  the BH-5354 I1 rule: a lookup matches its own ctx only, and a ci
//          (token) caller sees ci rows only. The default and the seed.
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

export async function readTrustKnob(db) {
  let row;
  try {
    row = await db.prepare("SELECT value FROM settings WHERE key = ?1").bind(TRUST_KEY).first();
  } catch {
    return { trust: null, reason: "settings unavailable" };
  }
  if (!row) return { trust: TRUST_DEFAULT };
  const v = row.value;
  return TRUSTS.has(v) ? { trust: v } : { trust: null, reason: "bad suite_reuse_trust" };
}

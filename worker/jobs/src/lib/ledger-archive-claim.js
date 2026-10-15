// owner: BH-6780.1 (claim exactly-once on an archived key)
//
// POST /api/ledger/claim calls this after its input checks and before its
// INSERT. A non-null answer is the Response the route returns instead of
// claiming. Today it always answers null, so the claim is unchanged.
export async function claimArchiveGuard(env, kind, key, t) {
  return null;
}

// owner: BH-6780.1 (claim exactly-once on an archived key)
//
// POST /api/ledger/claim calls this after its input checks and before its
// INSERT. A non-null answer is the Response the route returns instead of
// claiming. The four answers:
//   null  the kind is in neither archive list (no hot read, no env.ARCHIVE call),
//         or the hot row exists (the normal claim decides), or the archive has
//         no row for the key (the claim runs);
//   200   the key sits in the archive: { claimed: false, archived: true }, and
//         nothing is written, so an archived key is never claimed twice;
//   503   the archive is down or unbound for a sticky kind, or settings cannot
//         be read. Nothing is written: an outage is never "absent".

import { json } from "./http.js";
import { settingsRows } from "./settings-cache.js";
import { ledgerArchiveKinds, ledgerArchiveLookup } from "./ledger-archive.js";

export async function claimArchiveGuard(env, kind, key, t) {
  let byKey;
  try {
    ({ byKey } = await settingsRows(env));
  } catch {
    return json(503, { error: "settings unavailable" });
  }
  const { allow, sticky } = ledgerArchiveKinds(byKey);
  if (!allow.has(kind) && !sticky.has(kind)) return null;
  const hot = await env.DB.prepare("SELECT 1 FROM ledgers WHERE kind=?1 AND key=?2")
    .bind(kind, key).first();
  if (hot) return null;
  const a = await ledgerArchiveLookup(env, kind, key);
  if (a.status === 200) return json(200, { claimed: false, ledger: a.row, archived: true, as_of: t });
  if (a.status === 503) return json(503, { error: a.error });
  return null;
}

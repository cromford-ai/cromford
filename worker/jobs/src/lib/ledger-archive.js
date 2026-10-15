// The archive read behind GET /api/ledger (BH-6780).
//
// A ledger kind can move its old rows out of the hot `ledgers` table into the
// archive store (env.ARCHIVE, a second D1 with the same `ledgers` shape). Two
// settings rows say which kinds a hot miss may look for there:
//   retention.ledgers.archive_kinds   kinds an operator allows to move;
//   retention.ledgers.archived_kinds  kinds that HAVE moved rows (sticky: the
//                                     archive rule writes it, and it is never
//                                     taken back while rows sit in the archive).
// A kind in neither list never touches env.ARCHIVE.

import { settingsRows } from "./settings-cache.js";

export const LEDGER_ARCHIVE_KINDS_KEY = "retention.ledgers.archive_kinds";
export const LEDGER_ARCHIVED_KINDS_KEY = "retention.ledgers.archived_kinds";

const MAX_KINDS = 64;
const MAX_KIND_LEN = 32; // PUT /api/ledger cuts a kind to 32, so a longer entry can never match

function parseKinds(v) {
  const out = new Set();
  for (const s of String(v ?? "").split(",")) {
    const k = s.trim();
    if (!k || k.length > MAX_KIND_LEN) continue;
    if (out.size >= MAX_KINDS) break;
    out.add(k);
  }
  return out;
}

// byKey: the Map settingsRows answers. -> { allow, sticky, stickyAt }.
export function ledgerArchiveKinds(byKey) {
  const allowRow = byKey.get(LEDGER_ARCHIVE_KINDS_KEY);
  const stickyRow = byKey.get(LEDGER_ARCHIVED_KINDS_KEY);
  return {
    allow: parseKinds(allowRow && allowRow.value),
    sticky: parseKinds(stickyRow && stickyRow.value),
    stickyAt: (stickyRow && stickyRow.updated_at) || null,
  };
}

// One point read on the archive's PRIMARY KEY (kind, key). An archive with no
// `ledgers` table yet holds no row, so it answers null; any other error throws.
export async function archiveLedgerRow(env, kind, key) {
  try {
    const row = await env.ARCHIVE.prepare("SELECT * FROM ledgers WHERE kind=?1 AND key=?2")
      .bind(kind, key).first();
    return row || null;
  } catch (e) {
    if (/no such table/i.test(String((e && e.message) || ""))) return null;
    throw e;
  }
}

// The answer for a hot miss: { status: 200, row } | { status: 404 } |
// { status: 503, error }. 503 is an outage, never "absent".
export async function ledgerArchiveLookup(env, kind, key) {
  let byKey;
  try {
    ({ byKey } = await settingsRows(env));
  } catch {
    return { status: 503, error: "settings unavailable" };
  }
  const { allow, sticky } = ledgerArchiveKinds(byKey);
  if (!allow.has(kind) && !sticky.has(kind)) return { status: 404 };
  if (!env.ARCHIVE) {
    // A sticky kind has rows in the archive, so an unbound archive cannot say "absent".
    return sticky.has(kind) ? { status: 503, error: "archive not bound" } : { status: 404 };
  }
  let row;
  try {
    row = await archiveLedgerRow(env, kind, key);
  } catch {
    return { status: 503, error: "ledger archive unavailable" };
  }
  return row ? { status: 200, row } : { status: 404 };
}

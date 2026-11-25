import { ledgerArchiveKinds, LEDGER_ARCHIVED_KINDS_KEY } from "../../lib/ledger-archive.js";
import { ledgerArchiveMinDays, ledgerKindClass, ledgerKindMovable } from "../../lib/ledger-kind-class.js";
import { invalidateSettings } from "../../lib/settings-cache.js";

// Seconds between the record of a kind in archived_kinds and its first move:
// at least 2x the 60 s settings cache cap, so every isolate reads the kind as
// sticky (and answers a GET miss from the archive) before a row leaves hot.
const WAIT_KEY = "retention.ledgers.sticky_wait_s";
const WAIT_DEF_S = 120;  // fallback of the WAIT_KEY settings row (schema.d/*-bh-6865-*.sql)
const WAIT_MAX_S = 86400;

function waitSeconds(byKey) {
  const row = byKey.get(WAIT_KEY);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return WAIT_DEF_S;
  const n = Number(v);
  return n >= WAIT_DEF_S && n <= WAIT_MAX_S ? n : WAIT_DEF_S;
}

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// -> { list, error, settle } for runRule. A listed kind the audit does not call
// movable is refused and named in the error. A movable kind that is not yet in
// archived_kinds is recorded there on a real run, and that run moves nothing.
// A recorded kind moves once the record is WAIT_KEY seconds old. A dry run
// writes nothing and counts only recorded kinds. archived_kinds is append-only.
async function kinds(env, o) {
  const { allow, sticky, stickyAt } = ledgerArchiveKinds(o.byKey);
  const ok = [];
  const refused = [];
  for (const k of allow) {
    if (ledgerKindMovable(k)) ok.push(k);
    else refused.push(`${k}(${ledgerKindClass(k)})`);
  }
  const error = refused.length ? `refused kinds: ${refused.join(", ")}` : null;
  if (!ok.length) return { list: [], error };
  const fresh = ok.filter((k) => !sticky.has(k));
  if (fresh.length) {
    if (o.dryRun) return { list: ok.filter((k) => sticky.has(k)), error };
    await env.DB.prepare(
      `INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,?3,'retention',?4)
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, actor=excluded.actor, updated_at=excluded.updated_at`
    ).bind(LEDGER_ARCHIVED_KINDS_KEY, [...sticky, ...fresh].join(","),
      "BH-6780: written by the ledgers.archive rule; never remove a kind by hand while its rows are in the archive",
      iso(o.nowMs)).run();
    invalidateSettings(env);
    return { list: ok, error, settle: true };
  }
  const at = Date.parse(stickyAt || "");
  if (!Number.isFinite(at) || at > o.nowMs - waitSeconds(o.byKey) * 1000) return { list: ok, error, settle: true };
  return { list: ok, error };
}

export default [
  // BH-6865 (BH-6780.2): ledger rows of an audited, allowlisted kind move to
  // the archive store; never deleted without a counted-back copy. Off until
  // retention.ledgers.archive_days >= retention.ledgers.archive_min_days
  // (default and floor 91) and retention.ledgers.archive_kinds
  // lists a kind. The ids read uses idx_ledgers_kind_updated; the delete
  // re-checks the cutoff, so a row written after the copy stays hot.
  {
    rule: "ledgers.archive", table: "ledgers", key: "retention.ledgers.archive_days", def: 0,
    minDays: ledgerArchiveMinDays, archive: "ledgers", delCutoff: true, kinds,
    ids: "SELECT rowid AS id FROM ledgers WHERE kind IN (SELECT value FROM json_each(?3)) AND updated_at < ?1 LIMIT ?2",
    sel: "SELECT * FROM ledgers WHERE rowid IN (SELECT value FROM json_each(?1))",
    del: "DELETE FROM ledgers WHERE rowid IN (SELECT value FROM json_each(?1)) AND updated_at < ?2",
  },
];

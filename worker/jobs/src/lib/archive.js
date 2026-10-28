// The archive store (BH-6774): cold history in a second D1 database,
// harness-archive, bound to this worker as env.ARCHIVE. The hot store (env.DB)
// keeps what the fleet reacts to; the archive holds rows with long-term value
// that nothing polls. Only history views and audits read it.
//
// UNBOUND IS SAFE. Until an operator creates the database and adds its binding
// (worker/jobs/wrangler.jsonc, a commented stanza), env.ARCHIVE is undefined:
// archiveBound() is false, the retention run moves nothing and deletes nothing
// for an archive rule, and its audit row says "archive not bound".
//
// THE SCHEMA FOLLOWS THE HOT TABLE. An archive table has the hot table's
// columns (PRAGMA table_info on env.DB), plus archived_at, with the hot table's
// natural key as its primary key and an index on its time column. A column the
// hot table gains later (ensureColumns) is added here on the next copy.
//
// NO LEDGER TABLE IS HERE. Ledger rows are claim keys (GET /api/ledger?key,
// POST /api/ledger/claim): an archived row would read as "not done". Ledger
// kinds move only after a per-kind reader audit (BH-6774 C2).

export const ARCHIVE_TABLES = {
  cost_rows: { key: ["box", "row_hash"], time: "ts" },
  stage_events: { key: ["id"], time: "created_at" },
  // BH-7243.0: the roadmap retention rules (routes/retention.js).
  roadmap_ideas: { key: ["id"], time: "updated_at" },
  roadmap_idea_events: { key: ["id"], time: "at" },
  roadmap_waves: { key: ["id"], time: "updated_at" },
  // BH-7595: the web_vault audit rule (routes/retention.js).
  web_vault_audit: { key: ["id"], time: "at" },
  // BH-7722: the Tackler decision ledger (routes/retention.js unblock_decisions.age).
  unblock_decisions: { key: ["id"], time: "created_at" },
  // BH-7965: the secret envelope sweep (routes/secret-envelope-apply.js).
  secret_envelope_events: { key: ["id"], time: "at" },
  // BH-7972: old prompt versions (routes/retention.d/bh-7972-prompt-versions.js).
  prompt_versions: { key: ["id"], time: "created_at" },
  // BH-8731: the ticket lifecycle ledger (routes/retention.d/bh-8731-ticket-events.js).
  ticket_events: { key: ["id"], time: "at" },
};

// One text for every archive rule's "unbound" audit row (lib/archive-daily.js).
export { ARCHIVE_NOT_BOUND } from "./archive-daily.js";
const COPY_CHUNK = 100;  // statements per D1 batch
const q = (c) => `"${String(c).replace(/"/g, '""')}"`;

export function archiveBound(env) {
  return !!(env && env.ARCHIVE && typeof env.ARCHIVE.prepare === "function");
}

async function tableInfo(db, table) {
  // sql-ident-ok: table is an ARCHIVE_TABLES key, quoted by q()
  return ((await db.prepare(`PRAGMA table_info(${q(table)})`).all()).results || []);
}

// ensureArchiveTable(env, table) — create the archive table, or add the hot
// table's new columns to it. Returns the hot table's column names.
export async function ensureArchiveTable(env, table) {
  const spec = ARCHIVE_TABLES[table];
  if (!spec) throw new Error(`no archive spec for ${table}`);
  const hot = await tableInfo(env.DB, table);
  if (!hot.length) throw new Error(`hot table ${table} not found`);
  const have = new Set((await tableInfo(env.ARCHIVE, table)).map((c) => c.name));
  if (!have.size) {
    const defs = hot.map((c) => `${q(c.name)} ${c.type || ""}`.trim()).join(", ");
    // One after the other: the index names the table the first statement makes.
    // sql-ident-ok: table, key and column names come from ARCHIVE_TABLES and PRAGMA table_info, quoted by q()
    await env.ARCHIVE.prepare(`CREATE TABLE IF NOT EXISTS ${q(table)} (${defs}, archived_at TEXT NOT NULL, PRIMARY KEY (${spec.key.map(q).join(", ")}))`).run();
    // sql-ident-ok: table and time column come from ARCHIVE_TABLES, quoted by q()
    await env.ARCHIVE.prepare(`CREATE INDEX IF NOT EXISTS ${q(`idx_${table}_${spec.time}`)} ON ${q(table)}(${q(spec.time)})`).run();
  } else {
    for (const c of hot) {
      // sql-ident-ok: table from ARCHIVE_TABLES, column from PRAGMA table_info, quoted by q()
      if (!have.has(c.name)) await env.ARCHIVE.prepare(`ALTER TABLE ${q(table)} ADD COLUMN ${q(c.name)} ${c.type || ""}`.trim()).run();
    }
  }
  return hot.map((c) => c.name);
}

// archiveCopy(env, table, rows, at) — upsert the hot rows into the archive,
// then count them back by their key. An upsert, not INSERT OR IGNORE: a hot
// row can change after a copy whose delete failed (the ingest fills lane_id,
// guard_fp, participant), and the re-copy must carry the newer values before
// the hot row is deleted. Returns true only when every row is in the archive. Throws
// "archive copy failed: ..." on a write error, so the caller deletes nothing.
export async function archiveCopy(env, table, rows, at) {
  if (!rows.length) return true;
  const spec = ARCHIVE_TABLES[table];
  const cols = Object.keys(rows[0]);
  const set = [...cols.filter((c) => !spec.key.includes(c)), "archived_at"]
    .map((c) => `${q(c)} = excluded.${q(c)}`).join(", ");
  const sql = `INSERT INTO ${q(table)} (${cols.map(q).join(", ")}, archived_at)
               VALUES (${cols.map((_, i) => `?${i + 1}`).join(",")}, ?${cols.length + 1})
               ON CONFLICT (${spec.key.map(q).join(", ")}) DO UPDATE SET ${set}`;
  try {
    for (let i = 0; i < rows.length; i += COPY_CHUNK) {
      await env.ARCHIVE.batch(rows.slice(i, i + COPY_CHUNK).map((r) =>
        env.ARCHIVE.prepare(sql).bind(...cols.map((c) => (r[c] === undefined ? null : r[c])), at)));
    }
  } catch (e) {
    throw new Error(`archive copy failed: ${String((e && e.message) || e).slice(0, 200)}`);
  }
  const keys = JSON.stringify(rows.map((r) => spec.key.map((k) => r[k])));
  const on = spec.key.map((k, i) => `a.${q(k)} = json_extract(j.value, '$[${i}]')`).join(" AND ");
  // sql-ident-ok: table and key columns come from ARCHIVE_TABLES, quoted by q(); the keys are a bind
  const row = await env.ARCHIVE.prepare(
    `SELECT COUNT(*) AS n FROM json_each(?1) j JOIN ${q(table)} a ON ${on}`).bind(keys).first();
  return Number(row ? row.n : 0) === rows.length;
}

// archiveMaxTime(env, table) — the newest time value in the archive table, or
// null when the archive is unbound, the table does not exist yet, or it is empty.
export async function archiveMaxTime(env, table) {
  if (!archiveBound(env)) return null;
  const spec = ARCHIVE_TABLES[table];
  try {
    // sql-ident-ok: table and time column come from ARCHIVE_TABLES, quoted by q()
    const row = await env.ARCHIVE.prepare(`SELECT MAX(${q(spec.time)}) AS m FROM ${q(table)}`).first();
    return row && row.m ? String(row.m) : null;
  } catch (e) {
    if (/no such table/i.test(String((e && e.message) || e))) return null;
    throw e;
  }
}

// archivedCostHashes(env, box, rows) — the row_hash values of `rows` (pushed by
// one box) that are already in the archive. Only rows at or before the newest
// archived ts are looked up, in one read; a push of recent rows never reaches
// here (the caller filters on age first). Throws when the archive cannot be read.
export async function archivedCostHashes(env, box, rows) {
  const max = await archiveMaxTime(env, "cost_rows");
  if (!max) return new Set();
  const cand = rows.filter((r) => typeof r.ts === "string" && r.ts <= max).map((r) => r.row_hash);
  if (!cand.length) return new Set();
  const res = await env.ARCHIVE.prepare(
    `SELECT row_hash FROM cost_rows WHERE box = ?1 AND row_hash IN (SELECT value FROM json_each(?2))`
  ).bind(box, JSON.stringify(cand)).all();
  return new Set((res.results || []).map((x) => x.row_hash));
}

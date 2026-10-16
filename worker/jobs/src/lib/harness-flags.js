// harness_flags — the ported flag families' rows (BH-4153, BH-4141.1).
//
// For the names FLAG_PORTED_RE matches, the ROW is the truth: the box reads it
// first, falls back to a last-good cache, and writes no flags/ file. Every other
// flag name stays a pause_flags row with the BH-1370 file reconcile, untouched.
//
// FLAG_PORTED_RE is written on ONE line on purpose: tests/flags-db.bh-4153-test.sh
// sed-extracts the text between the slashes and compares it with the shell copy
// in bin/lib/jobs/flags.sh, so the two lists cannot drift.
//
// NO MIRROR (BH-4154): a ported write writes harness_flags and its audit row
// only. Every worker reader of a fleet flag reads through readFleetFlag,
// fleetFlagRows, activeFleetFlags or flagActiveSql below, which pick the store
// by name: harness_flags for a ported name (its pause_flags row only while no
// harness_flags row exists, the backfill's own fallback), pause_flags for every
// other name. A name added to FLAG_PORTED_RE moves every reader with it.

import { ensureTable } from "./core.js";

export const FLAG_PORTED_RE = /^(paused-.+|automerge-disabled|automerge-disabled-.+|lanedown-.+|dispatch-mode-.+)$/;

// Flag names become file names under flags/ on every box (the non-ported ones
// still do), so the alphabet is the one that cannot escape that directory.
export const FLAG_NAME_RE = /^[A-Za-z0-9._-]+$/;
const SCOPE_RE = /^[A-Za-z0-9._-]{1,64}$/;

export const VALUE_MAX = 512;

export const isPortedFlag = (name) => FLAG_PORTED_RE.test(String(name || ""));

// FLAG_PORTED_RE as SQL, so a statement can apply the same rule. Each
// alternative is a literal name or a literal head followed by `.+`; any other
// shape throws at load, so the two forms cannot drift apart.
const PORTED_ALTS = (() => {
  const m = /^\^\((.*)\)\$$/.exec(FLAG_PORTED_RE.source);
  if (!m) throw new Error("FLAG_PORTED_RE: expected ^(a|b|...)$");
  return m[1].split("|").map((alt) => {
    const a = /^([A-Za-z0-9-]+)(\.\+)?$/.exec(alt);
    if (!a) throw new Error(`FLAG_PORTED_RE: unsupported alternative ${alt}`);
    return { head: a[1], more: Boolean(a[2]) };
  });
})();

// The SQL predicate "<col> is a ported name". `col` is a column or a bind.
export function portedSql(col) {
  return "(" + PORTED_ALTS.map(({ head, more }) => (more
    ? `(substr(${col}, 1, ${head.length})='${head}' AND length(${col}) > ${head.length})`
    : `${col}='${head}'`)).join(" OR ") + ")";
}

// 'fleet' when absent or empty, the scope when it is a box-name-shaped string,
// null (the caller's 400) otherwise.
export function validScope(s) {
  if (s === undefined || s === null || s === "") return "fleet";
  const v = String(s);
  return SCOPE_RE.test(v) ? v : null;
}

// A harness_flags row plus the legacy keys every pause_flags reader expects
// (flag_sync, /config, config-detail.js, lane-switch.sh): ON is active=1.
export function legacyShape(row) {
  if (!row) return null;
  const { scope, name, value, set_by, reason, set_at, cleared_at } = row;
  return {
    scope, name, value: value ?? null, set_by: set_by ?? null, reason: reason ?? null,
    set_at, cleared_at: cleared_at ?? null,
    active: cleared_at == null ? 1 : 0,
    actor: set_by ?? null,
    updated_at: cleared_at ?? set_at,
  };
}

// A pause_flags row in the same shape: fleet scope, no value, its one stamp
// standing for set_at (and for cleared_at when it is off). The original
// columns ride along unchanged.
export function projectPauseRow(row) {
  if (!row) return null;
  const on = Number(row.active) === 1;
  return {
    scope: "fleet", name: row.name, value: null, set_by: row.actor ?? null, reason: row.reason ?? null,
    set_at: row.updated_at, cleared_at: on ? null : row.updated_at,
    ...row,
  };
}

// The current row of a ported name, in the full shape, or null. A fleet name
// with no harness_flags row yet falls back to its pause_flags row: that is the
// row the backfill would copy, so a worker running ahead of the backfill never
// answers "no row" for a pause that exists.
export async function readPortedFlag(env, scope, name) {
  const row = await env.DB.prepare("SELECT * FROM harness_flags WHERE scope=?1 AND name=?2").bind(scope, name).first();
  if (row) return legacyShape(row);
  if (scope !== "fleet") return null;
  const legacy = await env.DB.prepare("SELECT * FROM pause_flags WHERE name=?1").bind(name).first();
  return projectPauseRow(legacy);
}

// The harness_flags upsert. ON writes set_at=t, cleared_at=NULL; OFF keeps the
// stored set_at and writes cleared_at=t (a soft clear: the row is history).
export function upsertStmt(env, { scope, name, value, actor, reason, setAt, clearedAt }) {
  return env.DB.prepare(
    `INSERT INTO harness_flags (scope, name, value, set_by, reason, set_at, cleared_at) VALUES (?1,?2,?3,?4,?5,?6,?7)
     ON CONFLICT(scope, name) DO UPDATE SET value=?3, set_by=COALESCE(?4, set_by), reason=?5,
       set_at=CASE WHEN ?7 IS NULL THEN ?6 ELSE harness_flags.set_at END, cleared_at=?7`
  ).bind(scope, name, value ?? null, actor ?? null, reason ?? null, setAt, clearedAt ?? null);
}

// ── the fleet readers (BH-4154) ────────────────────────────────────────────

// The fleet row of one name, in the full shape, or null: the harness_flags
// row of a ported name (readPortedFlag), the pause_flags row of any other.
export async function readFleetFlag(env, name) {
  if (isPortedFlag(name)) {
    await ensureTable(env, "harness_flags");
    return readPortedFlag(env, "fleet", name);
  }
  return projectPauseRow(await env.DB.prepare("SELECT * FROM pause_flags WHERE name=?1").bind(name).first());
}

// The flag list, both stores merged, in the full shape and ordered by name
// then scope: harness_flags rows of ported names (every scope when `scope` is
// null), plus the pause_flags rows a ported fleet row does not replace.
// `prefix` is compared with substr, not LIKE, because `_` is in the alphabet.
// Each statement reads limit+1 rows, so `truncated` is exact.
export async function fleetFlagRows(env, { scope = "fleet", prefix = "", onlyOn = 0, limit = 500 } = {}) {
  await ensureTable(env, "harness_flags");
  // sql-ident-ok: portedSql builds literal text from the PORTED_ALTS code list; limit is a code constant from each caller
  const ported = await env.DB.prepare(
    `SELECT * FROM harness_flags
      WHERE (?1 IS NULL OR scope=?1) AND substr(name, 1, length(?2))=?2 AND (?3=0 OR cleared_at IS NULL)
        AND ${portedSql("name")}
      ORDER BY name ASC, scope ASC LIMIT ${limit + 1}`
  ).bind(scope, prefix, onlyOn).all();
  // sql-ident-ok: portedSql builds literal text from the PORTED_ALTS code list; limit is a code constant from each caller
  const legacy = scope !== null && scope !== "fleet" ? { results: [] } : await env.DB.prepare(
    `SELECT * FROM pause_flags p
      WHERE substr(name, 1, length(?1))=?1 AND (?2=0 OR active=1)
        AND NOT (${portedSql("p.name")} AND EXISTS (SELECT 1 FROM harness_flags h WHERE h.scope='fleet' AND h.name=p.name))
      ORDER BY name ASC LIMIT ${limit + 1}`
  ).bind(prefix, onlyOn).all();
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const flags = [
    ...(ported.results || []).map(legacyShape),
    ...(legacy.results || []).map(projectPauseRow),
  ].sort((a, b) => cmp(a.name, b.name) || cmp(a.scope, b.scope));
  return { flags: flags.slice(0, limit), truncated: flags.length > limit };
}

// The fleet flags among `names` that are ON, each as
// { name, table, actor, reason, updated_at }: `table` is the store that
// answered. Two statements at most; the harness_flags one only when a name is
// ported.
export async function activeFleetFlags(env, names) {
  if (!names.length) return [];
  const ported = names.filter(isPortedFlag);
  const marks = (xs, from) => xs.map((_, i) => `?${from + i}`).join(",");
  const out = [];
  if (ported.length) {
    await ensureTable(env, "harness_flags");
    // sql-ident-ok: marks() is ?N placeholder text
    const rows = await env.DB.prepare(
      `SELECT name, set_by AS actor, reason, set_at AS updated_at FROM harness_flags
        WHERE scope='fleet' AND cleared_at IS NULL AND name IN (${marks(ported, 1)})`
    ).bind(...ported).all();
    for (const r of rows.results || []) out.push({ ...r, table: "harness_flags" });
  }
  // Every name binds first (?1..?n), the ported ones again after them: a
  // pause_flags row of a ported name counts only while it has no fleet
  // harness_flags row.
  const twin = ported.length
    ? ` AND NOT (name IN (${marks(ported, names.length + 1)})
        AND EXISTS (SELECT 1 FROM harness_flags h WHERE h.scope='fleet' AND h.name=pause_flags.name))`
    : "";
  // sql-ident-ok: marks() is ?N placeholder text; twin is a literal clause with marks()
  const rows = await env.DB.prepare(
    `SELECT name, actor, reason, updated_at FROM pause_flags WHERE active=1 AND name IN (${marks(names, 1)})${twin}`
  ).bind(...names, ...ported).all();
  for (const r of rows.results || []) out.push({ ...r, table: "pause_flags" });
  return out;
}

// The SQL guard "fleet flag <name> is ON", for a D1 batch where a JS read
// cannot act as the guard. The name binds as ?1. The caller has run
// ensureTable(env, "harness_flags") when the name is ported.
export function flagActiveSql(name) {
  if (!isPortedFlag(name)) return "EXISTS (SELECT 1 FROM pause_flags WHERE name=?1 AND active=1)";
  return `(EXISTS (SELECT 1 FROM harness_flags WHERE scope='fleet' AND name=?1 AND cleared_at IS NULL)
    OR (NOT EXISTS (SELECT 1 FROM harness_flags WHERE scope='fleet' AND name=?1)
        AND EXISTS (SELECT 1 FROM pause_flags WHERE name=?1 AND active=1)))`;
}

// The statement that turns fleet flag <name> OFF, in the store its name picks,
// written only while it is ON. A ported name gets a cleared harness_flags row
// (created cleared when only its pause_flags row exists, so the row decides
// from then on). Any other name is the pause_flags upsert the main-red CLEAR
// has always run.
export function clearFleetFlagStmt(env, name, actor, reason, t) {
  if (isPortedFlag(name)) {
    return env.DB.prepare(
      `INSERT INTO harness_flags (scope, name, set_by, reason, set_at, cleared_at)
       VALUES ('fleet', ?1, ?2, 'cleared: ' || ?3, ?4, ?4)
       ON CONFLICT(scope, name) DO UPDATE SET set_by=excluded.set_by, reason=excluded.reason,
         cleared_at=excluded.cleared_at WHERE harness_flags.cleared_at IS NULL`
    ).bind(name, actor, reason, t);
  }
  return env.DB.prepare(
    `INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?1, 0, ?2, 'cleared: ' || ?3, ?4)
     ON CONFLICT(name) DO UPDATE SET active=0, actor=excluded.actor, reason=excluded.reason,
       updated_at=excluded.updated_at WHERE pause_flags.active=1`
  ).bind(name, actor, reason, t);
}

// prompt-store — prompt overrides as immutable versions plus one head per
// (scope, project, kind) (BH-7940.0; docs/PROMPTS.md). routes/prompts.js is the
// HTTP face; the siblings of BH-7940 import these names.
//
// A save never overwrites: it inserts version n+1 and moves the head in ONE
// D1 batch, which D1 runs as one transaction. With base_version the insert
// happens only while the newest version is still base_version, so two people
// who opened the same version cannot both save it: the second gets 409.

import { json, nowIso } from "./http.js";
import { settingsRows } from "./settings-cache.js";
import { missingMarkers } from "./prompt-markers.js";

export const PROMPT_KINDS = Object.freeze(["rules", "watcher", "plan", "execute", "review", "fix-round", "qa"]);
// A leading alphanumeric refuses ".", ".." and "_fleet": a slug is never a
// path trick in prompts/<project>.md or state/prompts/<project>/.
export const PROJECT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
// The documented fallback when the prompts.body_max_bytes row is absent or not
// a whole number.
const BODY_MAX_FALLBACK = 262144;

const VERSION_COLS = "id, scope, project, kind, version, body, author, note, created_at";
const HEAD_SELECT = "SELECT h.scope, h.kind, h.set_at, v.id AS version_id, v.version, v.author "
  + "FROM prompt_heads h JOIN prompt_versions v ON v.id = h.version_id ";

// Every statement this module runs, so the EXPLAIN test plans the same text.
export const PROMPT_SQL = Object.freeze({
  listHeads: `${HEAD_SELECT}WHERE h.scope = 'fleet' AND h.project = '' UNION ALL `
    + `${HEAD_SELECT}WHERE h.scope = 'project' AND h.project = ?1`,
  readVersion: `SELECT ${VERSION_COLS} FROM prompt_versions WHERE scope = ?1 AND project = ?2 AND kind = ?3 AND version = ?4`,
  insertNext: "INSERT INTO prompt_versions (scope, project, kind, version, body, author, note, created_at) "
    + "SELECT ?1, ?2, ?3, COALESCE(MAX(version), 0) + 1, ?4, ?5, ?6, ?7 FROM prompt_versions "
    + "WHERE scope = ?1 AND project = ?2 AND kind = ?3",
  insertOnBase: "INSERT INTO prompt_versions (scope, project, kind, version, body, author, note, created_at) "
    + "SELECT ?1, ?2, ?3, ?8 + 1, ?4, ?5, ?6, ?7 "
    + "WHERE (SELECT COALESCE(MAX(version), 0) FROM prompt_versions WHERE scope = ?1 AND project = ?2 AND kind = ?3) = ?8",
  // changes() is the insert's row count, so the head moves only when THIS
  // batch inserted a version. The WHERE lets SQLite parse the upsert.
  headUpsert: "INSERT INTO prompt_heads (scope, project, kind, version_id, set_by, set_at) "
    + "SELECT scope, project, kind, id, author, created_at FROM prompt_versions "
    + "WHERE scope = ?1 AND project = ?2 AND kind = ?3 AND changes() = 1 ORDER BY version DESC LIMIT 1 "
    + "ON CONFLICT(scope, project, kind) DO UPDATE SET version_id = excluded.version_id, "
    + "set_by = excluded.set_by, set_at = excluded.set_at",
  versionById: "SELECT version FROM prompt_versions WHERE id = ?1",
});

const bad = (error) => json(400, { error });

// -> {scope, project, kind}, or a 400 Response. params holds the path's scope
// and kind; project is the ?project= query value. Fleet stores project ''.
export function parsePromptKey(url, params) {
  const { scope, kind } = params;
  if (scope !== "fleet" && scope !== "project") return bad("scope must be fleet or project");
  if (!PROMPT_KINDS.includes(kind)) return bad(`kind must be one of ${PROMPT_KINDS.join(", ")}`);
  const project = url.searchParams.get("project") ?? "";
  if (scope === "fleet") {
    if (project !== "") return bad("a fleet prompt takes no project");
    return { scope, project: "", kind };
  }
  if (!PROJECT_RE.test(project)) return bad("project must match [A-Za-z0-9][A-Za-z0-9._-]{0,99}");
  return { scope, project, kind };
}

async function bodyMaxBytes(env) {
  const row = (await settingsRows(env)).byKey.get("prompts.body_max_bytes");
  const v = row ? String(row.value) : "";
  return /^[1-9][0-9]*$/.test(v) ? Number(v) : BODY_MAX_FALLBACK;
}

const conflict = () => json(409, { error: "version_conflict" });

// -> {id, version}, or a 400/409/413/422 Response. A refusal writes nothing.
export async function saveVersion(env, { scope, project, kind, body, author, note, base_version }) {
  if (typeof body !== "string") return bad("body must be a string");
  if (typeof author !== "string" || author.trim() === "") return bad("author must be a non-blank string");
  if (note === undefined || note === null) note = "";
  if (typeof note !== "string") return bad("note must be a string");
  const onBase = base_version !== undefined && base_version !== null;
  if (onBase && !(Number.isInteger(base_version) && base_version >= 0)) return bad("base_version must be a whole number >= 0");
  if (body.trim() === "") return json(422, { error: "empty_body" });
  const max = await bodyMaxBytes(env);
  if (new TextEncoder().encode(body).length > max) return json(413, { error: "body_too_large", max_bytes: max });
  const missing = missingMarkers(kind, body);
  if (missing.length > 0) return json(422, { error: "missing_marker", missing });

  const binds = [scope, project, kind, body, author.trim(), note, nowIso()];
  const insert = onBase
    ? env.DB.prepare(PROMPT_SQL.insertOnBase).bind(...binds, base_version)
    : env.DB.prepare(PROMPT_SQL.insertNext).bind(...binds);
  const head = env.DB.prepare(PROMPT_SQL.headUpsert).bind(scope, project, kind);
  let results;
  try {
    results = await env.DB.batch([insert, head]);
  } catch (e) {
    // node:sqlite and D1 ("D1_ERROR: UNIQUE constraint failed: ...") both say
    // this; D1 rolls the batch back. Anything else is not a conflict.
    if (/UNIQUE constraint failed/.test(String((e && e.message) || e))) return conflict();
    throw e;
  }
  const meta = (results[0] && results[0].meta) || {};
  if (Number(meta.changes || 0) === 0) return conflict();
  const id = Number(meta.last_row_id);
  const version = await env.DB.prepare(PROMPT_SQL.versionById).bind(id).first("version");
  return { id, version: Number(version) };
}

// -> the version row with its body, or null.
export async function readVersion(env, { scope, project, kind, version }) {
  return env.DB.prepare(PROMPT_SQL.readVersion).bind(scope, project, kind, version).first();
}

// -> seven rows in PROMPT_KINDS order: the project head, else the fleet head,
// else source "repo". project '' lists fleet and repo only.
export async function listHeads(env, project) {
  const { results } = await env.DB.prepare(PROMPT_SQL.listHeads).bind(project).all();
  const fleet = new Map();
  const own = new Map();
  for (const r of results || []) (r.scope === "project" ? own : fleet).set(r.kind, r);
  return PROMPT_KINDS.map((kind) => {
    const r = own.get(kind) || fleet.get(kind);
    if (!r) return { kind, source: "repo", version: null, version_id: null, author: null, set_at: null };
    return { kind, source: r.scope, version: Number(r.version), version_id: Number(r.version_id), author: r.author, set_at: r.set_at };
  });
}

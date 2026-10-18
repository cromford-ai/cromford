// registry routes — the fleet registry in D1 (BH-5649, slice 1 of BH-5633).
//
// Four tables hold what fleet.conf and its sibling maps hold today: projects,
// boxes, lane membership and account→box maps. registry_meta holds the ONE
// version number, and every import that changes a row bumps it once.
// bin/lib/registry.sh reads GET /api/registry when REGISTRY_SOURCE=db.
//
// Every write needs the registry admin token on top of the bearer, because the
// bearer is on every box and this table decides what every box runs. POST
// /api/registry/import is the bulk write only bin/registry-seed.sh calls. The
// per-row write routes (BH-5650, routes/registry-write.js) are what
// bin/registry.sh calls: projects and
// boxes (POST, PATCH, DELETE, drain), lane membership and box accounts (POST,
// DELETE: every column of those two is the key, so there is nothing to PATCH).
// Each write is one D1 batch: the rows, one registry_audit row per changed row
// (actor, time, old, new) and one version bump. `projects` (BH-4082,
// routes/projects.js) is a separate table with its own form; both stay until
// wave 3 (BH-5633) retires the files.
//
// The import never deletes. A row in D1 that the payload does not carry is
// kept and reported in `stale`, so a truncated seed file cannot erase a box.
//
// Every string is refused, never trimmed, if it holds whitespace or a control
// character: these rows are written back into positional files split on
// whitespace, and a trimmed value hides what the sender actually sent.

import { ensureColumns } from "../lib/core.js";
import { d1Guarded, json } from "../lib/http.js";
import { sqlIdent } from "../lib/sql-ident.js";

export const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
export const HOST_RE = /^[a-z0-9][a-z0-9.-]{0,63}$/;
export const ID_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
export const BOX_GLOB_RE = /^[a-z0-9*][a-z0-9.*_-]{0,63}$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
export const ACTOR_RE = /^[A-Za-z0-9._-]{1,64}$/;
const KINDS = ["login", "cost_rows", "jobs"];
const STATUSES = ["active", "retired"];
// A box's role. Null is no role: the readers (fleet-conf.sh, the seed) apply
// their own defaults, and GET leaves the key out.
export const ROLES = ["build", "review", "gate", "standby", "hub", "gate-only", "retired"];
const MAX_ROWS = 5000;
const MAX_BINDS = 100; // D1 refuses a statement with more bound values.

// One entry per table: the wire columns in their fixed order (also the
// canonical JSON key order), the natural key, the GET order and the audit
// entity name. updated_at is stored but never part of the wire row.
export const TABLES = {
  projects: {
    table: "registry_projects", entity: "project",
    cols: ["project", "repo", "prod", "board_prefix", "cron_offset", "box", "position", "status"],
    pk: ["project"], order: "position, project",
  },
  boxes: {
    table: "registry_boxes", entity: "box",
    cols: ["box", "box_id", "tailnet_ip", "cost_box", "standby_hub_name", "standby_hub_id", "role"],
    pk: ["box"], order: "box",
  },
  lane_boxes: {
    table: "registry_lane_boxes", entity: "lane_box",
    cols: ["lane", "box_id"], pk: ["lane", "box_id"], order: "lane, box_id",
  },
  box_accounts: {
    table: "registry_box_accounts", entity: "box_account",
    cols: ["account", "kind", "box"], pk: ["account", "kind", "box"], order: "account, kind, box",
  },
};

// The row in fixed key order, so equal rows give equal strings.
export const canon = (spec, row) => JSON.stringify(Object.fromEntries(spec.cols.map((c) => [c, row[c] ?? null])));
export const keyOf = (spec, row) => spec.pk.map((c) => row[c]).join("/");

export function registryAdminOk(req, env) {
  return Boolean(env.REGISTRY_ADMIN_TOKEN) && req.headers.get("x-registry-admin-token") === env.REGISTRY_ADMIN_TOKEN;
}

export const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
const badText = (v) => typeof v === "string" && /[\s\x00-\x1f\x7f]/.test(v);

// A required string matching re, or an error naming the field.
function need(row, field, re, at, what) {
  const v = row[field];
  if (typeof v !== "string" || !re.test(v)) return `${at}.${field} must be ${what}`;
  return null;
}

// A nullable string: null/undefined → null; otherwise it must be one token.
function optional(row, field, at) {
  const v = row[field];
  if (v === undefined || v === null) return { value: null };
  if (typeof v !== "string" || v === "") return { error: `${at}.${field} must be a string or null` };
  return { value: v };
}

// Pure: the payload → {value} normalized, or {error} naming the field and
// index. Nothing is clamped, trimmed or coerced: a string "3" is not 3.
export function validateRegistry(body) {
  if (!isObj(body)) return { error: "body must be a JSON object" };
  let actor = "registry-seed";
  if (body.actor !== undefined) {
    if (typeof body.actor !== "string" || !ACTOR_RE.test(body.actor)) return { error: "actor must be 1-64 letters, digits, dots, dashes or underscores" };
    actor = body.actor;
  }
  if (!Array.isArray(body.projects) || body.projects.length === 0) return { error: "projects must be a non-empty array" };
  for (const name of ["boxes", "lane_boxes", "box_accounts"]) {
    if (body[name] !== undefined && !Array.isArray(body[name])) return { error: `${name} must be an array` };
  }
  const input = {
    projects: body.projects,
    boxes: body.boxes || [],
    lane_boxes: body.lane_boxes || [],
    box_accounts: body.box_accounts || [],
  };

  // Whitespace or a control character in any string column, before any other
  // check, so the error says what is really wrong with the value.
  for (const [name, rows] of Object.entries(input)) {
    for (let i = 0; i < rows.length; i += 1) {
      if (!isObj(rows[i])) return { error: `${name}[${i}] must be an object` };
      for (const c of TABLES[name].cols) {
        if (badText(rows[i][c])) return { error: `${name}[${i}].${c} must not contain whitespace or control characters` };
      }
    }
  }

  const out = { projects: [], boxes: [], lane_boxes: [], box_accounts: [] };

  const boxNames = new Set();
  for (let i = 0; i < input.boxes.length; i += 1) {
    const b = input.boxes[i];
    const at = `boxes[${i}]`;
    const err = need(b, "box", HOST_RE, at, "a lowercase hostname") || need(b, "box_id", ID_RE, at, "a lowercase id");
    if (err) return { error: err };
    if (boxNames.has(b.box)) return { error: `${at}.box duplicates ${b.box}` };
    boxNames.add(b.box);
    const row = { box: b.box, box_id: b.box_id };
    for (const c of ["tailnet_ip", "cost_box", "standby_hub_name", "standby_hub_id"]) {
      const o = optional(b, c, at);
      if (o.error) return { error: o.error };
      row[c] = o.value;
    }
    if (row.tailnet_ip !== null) {
      const m = IPV4_RE.exec(row.tailnet_ip);
      if (!m || m.slice(1).some((o) => Number(o) > 255)) return { error: `${at}.tailnet_ip must be a dotted IPv4 address` };
    }
    const role = b.role === undefined ? null : b.role;
    if (role !== null && !ROLES.includes(role)) return { error: `${at}.role must be one of ${ROLES.join(", ")}` };
    row.role = role;
    out.boxes.push(row);
  }

  const seenProject = new Set();
  const seenPosition = new Set();
  for (let i = 0; i < input.projects.length; i += 1) {
    const p = input.projects[i];
    const at = `projects[${i}]`;
    const err = need(p, "project", SLUG_RE, at, "1-64 lowercase letters, digits or dashes");
    if (err) return { error: err };
    if (seenProject.has(p.project)) return { error: `${at}.project duplicates ${p.project}` };
    seenProject.add(p.project);
    const status = p.status === undefined ? "active" : p.status;
    if (!STATUSES.includes(status)) return { error: `${at}.status must be active or retired` };
    // A retired row comes from a `# @retired` directive with no repo: `-`.
    const repoOk = typeof p.repo === "string" && (REPO_RE.test(p.repo) || (status === "retired" && p.repo === "-"));
    if (!repoOk) return { error: `${at}.repo must be an owner/name GitHub slug` };
    // prod and board_prefix are stored VERBATIM, `-` included.
    for (const c of ["prod", "board_prefix"]) {
      if (typeof p[c] !== "string" || p[c] === "") return { error: `${at}.${c} must be a non-empty string (- for none)` };
    }
    if (status === "active") {
      if (p.prod !== "-" && !/^https?:\/\/\S+$/.test(p.prod)) return { error: `${at}.prod must be a URL or -` };
      if (p.board_prefix !== "-" && !/^\/\S*$/.test(p.board_prefix)) return { error: `${at}.board_prefix must start with / or be -` };
    }
    // Refused, never clamped: 10 is not 9 and "3" is not 3.
    if (!Number.isInteger(p.cron_offset) || p.cron_offset < 0 || p.cron_offset > 9) return { error: `${at}.cron_offset must be an integer from 0 to 9` };
    if (!Number.isInteger(p.position) || p.position < 0) return { error: `${at}.position must be an integer of 0 or more` };
    if (seenPosition.has(p.position)) return { error: `${at}.position duplicates ${p.position}` };
    seenPosition.add(p.position);
    const box = p.box === undefined ? null : p.box;
    if (box !== null) {
      if (typeof box !== "string" || !HOST_RE.test(box)) return { error: `${at}.box must be a lowercase hostname or null` };
      if (!boxNames.has(box)) return { error: `${at}.box ${box} has no boxes row` };
    }
    out.projects.push({ project: p.project, repo: p.repo, prod: p.prod, board_prefix: p.board_prefix, cron_offset: p.cron_offset, box, position: p.position, status });
  }

  const seenLane = new Set();
  for (let i = 0; i < input.lane_boxes.length; i += 1) {
    const l = input.lane_boxes[i];
    const at = `lane_boxes[${i}]`;
    const err = need(l, "lane", ID_RE, at, "a lowercase id") || need(l, "box_id", ID_RE, at, "a lowercase id");
    if (err) return { error: err };
    const k = `${l.lane}/${l.box_id}`;
    if (seenLane.has(k)) return { error: `${at} duplicates ${k}` };
    seenLane.add(k);
    out.lane_boxes.push({ lane: l.lane, box_id: l.box_id });
  }

  const seenAccount = new Set();
  for (let i = 0; i < input.box_accounts.length; i += 1) {
    const a = input.box_accounts[i];
    const at = `box_accounts[${i}]`;
    const err = need(a, "account", ID_RE, at, "a lowercase id");
    if (err) return { error: err };
    if (!KINDS.includes(a.kind)) return { error: `${at}.kind must be one of ${KINDS.join(", ")}` };
    const err2 = need(a, "box", BOX_GLOB_RE, at, "a lowercase hostname or glob");
    if (err2) return { error: err2 };
    const k = `${a.account}/${a.kind}/${a.box}`;
    if (seenAccount.has(k)) return { error: `${at} duplicates ${k}` };
    seenAccount.add(k);
    out.box_accounts.push({ account: a.account, kind: a.kind, box: a.box });
  }

  return { value: { actor, ...out } };
}

export async function readMeta(env) {
  return env.DB.prepare("SELECT version, updated_at FROM registry_meta WHERE id=1").first();
}

// Every table, LIMIT MAX_ROWS+1 so an oversize table is seen, never cut.
// registry_boxes.role is an ADDED column (core.js ADDED_COLUMNS): add it before
// the SELECT names it. A missing table makes the ALTER throw, and d1Guarded
// answers 503 as before. Every name is checked first, so a bad one throws
// before ensureColumns prepares its PRAGMA.
export async function readAll(env) {
  for (const spec of Object.values(TABLES)) [spec.table, ...spec.cols].forEach((n) => sqlIdent(n));
  await ensureColumns(env, "registry_boxes");
  const out = {};
  for (const [name, spec] of Object.entries(TABLES)) {
    // sql-ident-ok: TABLES const (table, cols, order); MAX_ROWS + 1 is a number const
    const r = await env.DB.prepare(
      `SELECT ${spec.cols.map(sqlIdent).join(", ")} FROM ${sqlIdent(spec.table)} ORDER BY ${spec.order} LIMIT ${MAX_ROWS + 1}`
    ).all();
    out[name] = r.results || [];
  }
  return out;
}

export const tooLarge = (all) => Object.values(all).some((rows) => rows.length > MAX_ROWS);

// Multi-row INSERT statements of `cols`, chunked so no statement binds more
// than MAX_BINDS values. `tail` is appended to each (the upsert clause).
function chunkedInserts(env, table, cols, rows, tail) {
  const per = Math.floor(MAX_BINDS / cols.length);
  const stmts = [];
  for (let i = 0; i < rows.length; i += per) {
    const part = rows.slice(i, i + per);
    const binds = [];
    const values = part.map((r) => {
      const marks = cols.map((c) => { binds.push(r[c] ?? null); return `?${binds.length}`; });
      return `(${marks.join(",")})`;
    });
    // sql-ident-ok: TABLES const or the literal registry_audit cols; values is ?N marks; tail names a subset of cols
    stmts.push(env.DB.prepare(`INSERT INTO ${sqlIdent(table)} (${cols.map(sqlIdent).join(", ")}) VALUES ${values.join(",")}${tail}`).bind(...binds));
  }
  return stmts;
}

// Diff `want` against `have` on natural keys and write the difference in ONE
// D1 batch: the row upserts and deletes, one audit row per changed row, and one
// version bump. Identical rows are skipped. A key in `have` that `want` does
// not carry is deleted only with `deletes: true` (the write routes); the
// import passes false, so those rows are kept and named in `stale`. No change
// means no batch: no audit row and the version is kept.
export async function applyRegistry(env, t, actor, have, meta, want, { deletes }) {
  const version = meta.version + 1;
  const stmts = [];
  const audit = [];
  const stale = [];
  let changed = 0;
  for (const [name, spec] of Object.entries(TABLES)) {
    const current = new Map(have[name].map((r) => [keyOf(spec, r), { row: r, was: canon(spec, r) }]));
    const upserts = [];
    for (const row of want[name]) {
      const k = keyOf(spec, row);
      const now = canon(spec, row);
      const was = current.get(k)?.was;
      current.delete(k);
      if (was === now) continue;
      upserts.push({ ...row, updated_at: t });
      audit.push({ at: t, actor, entity: spec.entity, key: k, old_value: was ?? null, new_value: now, version });
    }
    for (const [k, { row, was }] of current) {
      if (!deletes) { stale.push(`${spec.entity}:${k}`); continue; }
      changed += 1;
      const where = spec.pk.map(sqlIdent).map((c, i) => `${c}=?${i + 1}`).join(" AND ");
      // sql-ident-ok: TABLES const (table, pk)
      stmts.push(env.DB.prepare(`DELETE FROM ${sqlIdent(spec.table)} WHERE ${where}`).bind(...spec.pk.map((c) => row[c])));
      audit.push({ at: t, actor, entity: spec.entity, key: k, old_value: was, new_value: null, version });
    }
    if (!upserts.length) continue;
    changed += upserts.length;
    const cols = [...spec.cols, "updated_at"];
    const set = cols.filter((c) => !spec.pk.includes(c)).map((c) => `${c}=excluded.${c}`).join(", ");
    stmts.push(...chunkedInserts(env, spec.table, cols, upserts, ` ON CONFLICT(${spec.pk.join(", ")}) DO UPDATE SET ${set}`));
  }
  stale.sort();

  if (changed === 0) return { changed: 0, version: meta.version, stale };

  stmts.push(...chunkedInserts(env, "registry_audit", ["at", "actor", "entity", "key", "old_value", "new_value", "version"], audit, ""));
  stmts.push(env.DB.prepare("UPDATE registry_meta SET version=version+1, updated_at=?1 WHERE id=1").bind(t));
  await env.DB.batch(stmts);
  return { changed, version, stale };
}

// Every lane the registry ever held a membership for. The audit is
// append-only, so a lane drained to zero boxes is still listed: the render
// overlay (bin/render-cron.sh) gives such a lane zero boxes instead of falling
// back to its file .boxes.
async function readKnownLanes(env) {
  // sql-ident-ok: MAX_ROWS + 1 is a number const
  const r = await env.DB.prepare(
    `SELECT DISTINCT substr(key, 1, instr(key, '/') - 1) AS lane FROM registry_audit WHERE entity='lane_box' ORDER BY 1 LIMIT ${MAX_ROWS + 1}`
  ).all();
  return (r.results || []).map((x) => x.lane);
}

export const routes = [
  [
    "GET", "/api/registry",
    async ({ env, t }) => d1Guarded("registry", async () => {
      const meta = await readMeta(env);
      const all = await readAll(env);
      const known = await readKnownLanes(env);
      if (tooLarge(all) || known.length > MAX_ROWS) return json(507, { error: "registry too large" });
      // A null role is no `role` key, so a reader that predates roles sees its old row.
      const boxes = all.boxes.map(({ role, ...b }) => (role === null || role === undefined ? b : { ...b, role }));
      return json(200, { version: meta.version, updated_at: meta.updated_at, ...all, boxes, known_lanes: known, as_of: t });
    }),
  ],

  [
    "GET", "/api/registry/version",
    async ({ env }) => d1Guarded("registry", async () => {
      const meta = await readMeta(env);
      return json(200, { version: meta.version, updated_at: meta.updated_at });
    }),
  ],

  [
    "POST", "/api/registry/import",
    async ({ req, env, t, body }) => d1Guarded("registry", async () => {
      // The admin gate comes before any read: a caller with only the bearer
      // learns nothing from this route.
      if (!registryAdminOk(req, env)) {
        return json(403, { error: "registry writes need the registry admin token (x-registry-admin-token)" });
      }
      const checked = validateRegistry(body);
      if (checked.error) return json(400, { error: checked.error });
      const want = checked.value;

      const meta = await readMeta(env);
      const have = await readAll(env);
      if (tooLarge(have)) return json(507, { error: "registry too large" });

      const r = await applyRegistry(env, t, want.actor, have, meta, want, { deletes: false });
      return json(200, { ok: true, changed: r.changed, version: r.version, stale: r.stale });
    }),
  ],

];

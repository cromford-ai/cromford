// model-routes routes — BH-1510.0: the model ladder becomes a row.
//
// Same split as every other family here (BH-1195): src/index.js holds the
// ordered table, this file holds the bodies. Nothing else in the fleet calls
// these yet — bin/lib/model-route.sh (also #1510.0) is the first reader, and
// no lane is converted to use it until #1510.1/.2.
//
// PRECEDENCE IS PER ROLE, NOT PER RUNG (core.js resolveModelLadder): a project
// either owns its whole ladder for a role or it owns none of it. This is why
// PUT always replaces the WHOLE ladder for (scope, role) in one call — a
// caller that wanted to change one rung still sends every rung, so the ladder
// that results is one decision an operator can see in one audit row per rung,
// not a merge of two edits made at two different times.
import { d1Guarded, json } from "../lib/http.js";
import {
  MODEL_ROUTE_PROJECT_RE, MODEL_ROUTE_ROLE_RE, MODEL_ROUTE_RUNNERS,
  ensureTable, knownModelIds, modelRouteGaps, modelRouteRoles, modelRouteScopeVersion, resolveModelLadder,
} from "../lib/core.js";
import { readHistory, mergeGroups } from "../lib/archive-read.js";

const MAX_LADDER = 8; // a bound, not a measured ceiling — nothing today runs anywhere near it
// A stage.* role (BH-1766) is a runner and its fallback: agent-call reads
// positions 0 and 1 (stage_runner_for prints two runners), so a third rung
// would sit in the table looking like it does something.
const MAX_STAGE_LADDER = 2;

function badRole(role) {
  return typeof role !== "string" || role.length === 0 || role.length > 128 || !MODEL_ROUTE_ROLE_RE.test(role);
}

// null = hub (valid); a non-empty string must match the project token shape;
// anything else (number, object) is refused rather than silently coerced to
// hub — a caller that meant to scope a write and typo'd the field must not have
// it land on the hub default instead. An EMPTY string is the hub only on a
// read (`?project=` from a form); on a write body (`forWrite`) it is refused
// for the same typo reason (BH-1510.3 review).
function normalizeProject(raw, forWrite = false) {
  if (raw === undefined || raw === null) return { ok: true, project: null };
  if (typeof raw !== "string") return { ok: false };
  const p = raw.trim();
  if (p === "") return forWrite ? { ok: false } : { ok: true, project: null };
  if (p.length > 64 || !MODEL_ROUTE_PROJECT_RE.test(p)) return { ok: false };
  return { ok: true, project: p };
}

// (coalesce(project,'') \0 role \0 position) -> {updated_by, updated_at}, for
// the hub rows and (when given) one project's rows — one query for the whole
// list read rather than one per role.
// `scopes` is the set of (coalesce(project,''), role) pairs that hold at least
// one row, from the SAME rows — which is what says whether a role's OWN scope
// on this tab is the project's or the hub's, and so which of them a gap
// belongs to (BH-1563).
async function rungProvenance(env, project) {
  const rows = await env.DB.prepare(
    project
      ? "SELECT coalesce(project,'') AS p, role, position, updated_by, updated_at FROM model_routes WHERE project IS NULL OR project=?1"
      : "SELECT '' AS p, role, position, updated_by, updated_at FROM model_routes WHERE project IS NULL"
  ).bind(...(project ? [project] : [])).all();
  const prov = new Map();
  const scopes = new Set();
  for (const r of rows.results || []) {
    prov.set(`${r.p}\u0000${r.role}\u0000${r.position}`, { updated_by: r.updated_by, updated_at: r.updated_at });
    scopes.add(`${r.p}\u0000${r.role}`);
  }
  return { prov, scopes };
}

const MAX_CHANGES = 500;

// The version guard, INSIDE the batch. D1 runs a batch as one transaction and
// rolls it back when any statement errors, so a first statement that errors
// when the scope's version is not the one the caller edited makes the check
// and the write one atomic step — a read-time check alone would still let a
// write land between the check and the batch. json('stale') is SQLite's
// cheapest way to raise from plain SQL (no triggers): it throws "malformed
// JSON", which isStaleGuard() recognises.
function versionGuard(env, role, project, expected) {
  return env.DB.prepare(
    project
      ? "SELECT json(CASE WHEN (SELECT coalesce(max(id),0) FROM model_routes WHERE role=?1 AND project=?2)=?3 THEN '1' ELSE 'stale' END) AS ok"
      : "SELECT json(CASE WHEN (SELECT coalesce(max(id),0) FROM model_routes WHERE role=?1 AND project IS NULL)=?3 THEN '1' ELSE 'stale' END) AS ok"
  ).bind(role, project || "", expected);
}
const isStaleGuard = (e) => /malformed JSON/i.test(String((e && e.message) || e));

// null = no guard asked for; a number = the version the caller edited; anything
// else is a caller bug, refused.
function expectedVersion(raw) {
  if (raw === undefined || raw === null) return { ok: true, v: null };
  const v = Number(raw);
  return Number.isInteger(v) && v >= 0 ? { ok: true, v } : { ok: false };
}

// The 409. `expected` is what the caller told us it edited — {v} for the scope
// this write names, {hub} for the hub ladder a project edit was BASED on
// (BH-1563) — and `stale` names which of the two actually moved, because
// "reload and edit again" means a different thing for each: the project's own
// ladder moved, or the hub ladder the override was being created from did.
// Both versions are re-read here, so the body hands back the numbers a retry
// would carry rather than making the caller read again to find out.
async function staleNow(env, role, project, expected) {
  const scope_version = await modelRouteScopeVersion(env, role, project);
  const hub_scope_version = project ? await modelRouteScopeVersion(env, role, null) : scope_version;
  const exp = expected || {};
  const hubMoved = exp.hub !== null && exp.hub !== undefined && exp.hub !== hub_scope_version;
  const projectMoved = exp.v !== null && exp.v !== undefined && exp.v !== scope_version;
  const which = hubMoved && projectMoved ? "both" : hubMoved ? "hub" : "project";
  const error = which === "hub"
    ? "the hub ladder this edit was based on changed since you loaded it — reload and edit again"
    : which === "both"
      ? "both this ladder and the hub ladder it was based on changed since you loaded them — reload and edit again"
      : "this ladder changed since you loaded it — reload and edit again";
  return json(409, { error, scope_version, hub_scope_version, stale: which });
}

// Run a batch that may start with one or two versionGuards; a tripped guard is
// a 409, anything else propagates to d1Guarded as before.
// `into`, when given, receives the batch's per-statement results.
async function guardedBatch(env, stmts, role, project, expected, into) {
  try {
    const out = await env.DB.batch(stmts);
    if (into) into.push(...(out || []));
    return null;
  } catch (e) {
    if (isStaleGuard(e)) return staleNow(env, role, project, expected);
    throw e;
  }
}

// What a DELETE in a batch measured. A result with no numeric count is an
// error, never "0 removed": the tombstone flag and the response read it.
function deletedCount(r) {
  const n = r && r.meta ? r.meta.changes : undefined;
  if (!Number.isInteger(n) || n < 0) throw new Error("DELETE result carried no row count");
  return n;
}

const TS_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const MAX_UNROUTED = 500;

// BH-2512: every stage the cost ledger saw since `since` that agent-call would
// run with NO stage.* route: no rung-0 row for `stage.<lowercased stage>` at
// the call's project or at the hub (the resolver ignores a ladder with no rung
// 0, so a gapped one is still unrouted). agent-call then runs it on
// RUNNER_<STAGE> from env, else claude. One row per (stage, project) pair,
// folded here into one entry per stage. A failed ledger read is reported as
// that, never as an empty list: the routes read it rides on still answers.
// BH-7035: a `since` the archive can reach reads it too (lib/archive-read.js).
// model_routes is hot only, so the archive groups without the route check
// and one hot statement applies the same check to its (stage, project) pairs.
const UNROUTED_KEEP_SQL =
  `SELECT json_extract(v.value,'$[0]') AS stage, json_extract(v.value,'$[1]') AS project
     FROM json_each(?1) v
    WHERE NOT EXISTS (SELECT 1 FROM model_routes m
                       WHERE m.role = 'stage.' || json_extract(v.value,'$[0]') AND m.position = 0
                         AND (m.project IS NULL OR m.project = json_extract(v.value,'$[1]')))`;
const pairKey = (r) => JSON.stringify([r.stage, r.project ?? null]);
const nullFirst = (x, y) => (x === y ? 0 : x === null ? -1 : y === null ? 1 : x < y ? -1 : 1);

async function unroutedStages(env, since, project, now) {
  let rows;
  let archTruncated = false;
  let archiveState;
  try {
    // sql-ident-ok: the project clause is a literal picked by project, which binds as ?3
    const hotSql = `SELECT lower(c.stage) AS stage, c.project AS project, count(*) AS calls,
              max(c.ts) AS last_seen, group_concat(DISTINCT c.runner) AS runners
         FROM cost_rows c
        WHERE c.ts >= ?1 AND c.stage IS NOT NULL AND c.stage <> ''${project ? " AND c.project = ?3" : ""}
          AND NOT EXISTS (SELECT 1 FROM model_routes m
                           WHERE m.role = 'stage.' || lower(c.stage) AND m.position = 0
                             AND (m.project IS NULL OR m.project = c.project))
        GROUP BY lower(c.stage), c.project
        ORDER BY lower(c.stage), c.project
        LIMIT ?2`;
    // sql-ident-ok: the project clause is a literal picked by project, which binds as ?3
    const archSql = `SELECT lower(c.stage) AS stage, c.project AS project, count(*) AS calls,
              max(c.ts) AS last_seen, group_concat(DISTINCT c.runner) AS runners
         FROM cost_rows c
        WHERE c.ts >= ?1 AND c.stage IS NOT NULL AND c.stage <> ''${project ? " AND c.project = ?3" : ""}
        GROUP BY lower(c.stage), c.project
        ORDER BY lower(c.stage), c.project
        LIMIT ?2`;
    const binds = project ? [since, MAX_UNROUTED + 1, project] : [since, MAX_UNROUTED + 1];
    const r = await readHistory(env, { table: "cost_rows", since, now, hot: { sql: hotSql, binds }, archive: { sql: archSql, binds } });
    archiveState = r.state;
    rows = r.hot.results || [];
    if (r.archive) {
      let arch = r.archive.results || [];
      // The archive side at its cap may lack a pair (D12), filtered or not.
      archTruncated = arch.length > MAX_UNROUTED;
      if (arch.length) {
        const keep = await env.DB.prepare(UNROUTED_KEEP_SQL).bind(JSON.stringify(arch.map((x) => [x.stage, x.project ?? null]))).all();
        const kept = new Set((keep.results || []).map(pairKey));
        arch = arch.filter((x) => kept.has(pairKey(x)));
      }
      rows = mergeGroups(rows, arch, {
        by: ["stage", "project"], spec: { calls: "sum", last_seen: "max", runners: "union" }, pickBy: "last_seen",
        compare: (a, b) => nullFirst(a.stage, b.stage) || nullFirst(a.project ?? null, b.project ?? null),
        limit: MAX_UNROUTED + 1,
      }).rows;
    }
  } catch (e) {
    return { unrouted_stages: null, unrouted_since: since, unrouted_error: `could not read cost_rows: ${e && e.message ? e.message : e}` };
  }
  const truncated = rows.length > MAX_UNROUTED || archTruncated;
  const byStage = new Map();
  for (const row of rows.slice(0, MAX_UNROUTED)) {
    let e = byStage.get(row.stage);
    if (!e) {
      const role = `stage.${row.stage}`;
      e = { stage: row.stage, role: badRole(role) ? null : role, projects: [], calls: 0, last_seen: null, runners: [] };
      byStage.set(row.stage, e);
    }
    e.projects.push(row.project);
    e.calls += Number(row.calls) || 0;
    if (row.last_seen && (!e.last_seen || row.last_seen > e.last_seen)) e.last_seen = row.last_seen;
    for (const rn of String(row.runners || "").split(",")) if (rn && !e.runners.includes(rn)) e.runners.push(rn);
  }
  for (const e of byStage.values()) e.runners.sort();
  return { unrouted_stages: [...byStage.values()], unrouted_since: since, unrouted_truncated: truncated, unrouted_archive: archiveState };
}

export const routes = [
  // ── GET every role's resolved ladder (the UI slice's data source) ───────
  [
    "GET", "/api/model-routes",
    async ({ env, url, t }) => {
      return d1Guarded("model_routes", async () => {
        await ensureTable(env, "model_routes");
        const rawProject = url.searchParams.get("project");
        const norm = normalizeProject(rawProject === null ? undefined : rawProject);
        if (!norm.ok) return json(400, { error: "project must be a bare token, <= 64 chars" });
        const project = norm.project;
        // BH-2512: opt-in, so every caller that does not ask (bin/lib/model-route.sh,
        // the gap-check lane) gets the response and the cost it always had.
        const since = url.searchParams.get("unrouted_since");
        if (since !== null && !TS_RE.test(since)) {
          return json(400, { error: "unrouted_since must be YYYY-MM-DDTHH:MM:SSZ (cost_rows.ts's own shape)" });
        }
        const roles = await modelRouteRoles(env, project);
        const { prov, scopes } = await rungProvenance(env, project);
        // FLEET-WIDE on every tab (BH-1563), not just this one's scope: a
        // project tab must still show the hub's hidden scopes, and a scope a
        // project owns alone is not a row on the hub tab at all — this list is
        // the only place it surfaces.
        const gaps = await modelRouteGaps(env);
        const gapped = new Set(gaps.map((g) => `${g.project || ""}\u0000${g.role}`));
        const out = [];
        for (const role of roles) {
          const { ladder, source } = await resolveModelLadder(env, role, project);
          // BH-1510.3: who last wrote each rung, merged in HERE and not in
          // resolveModelLadder — the one-role read below is what
          // bin/lib/model-route.sh parses, and its shape stays put. A rung
          // still carrying updated_by='seed' is the screen's cue that nobody
          // has decided it since #1510.0 (the #1507 carry-over rows).
          const scopeKey = source === "project" ? project : "";
          const withProv = ladder.map((r) => ({ ...r, ...(prov.get(`${scopeKey}\u0000${role}\u0000${r.position}`) || {}) }));
          // The row's OWN scope: the project's when it holds rows for this
          // role (even gapped ones — those rows are exactly what is hidden),
          // otherwise the hub's. A project that owns a healthy ladder is not
          // tagged for the hub's gap; it is not that row's problem.
          const own = project && scopes.has(`${project}\u0000${role}`) ? project : "";
          out.push({ role, ladder: withProv, source, gapped: gapped.has(`${own}\u0000${role}`) });
        }
        const res = { project, roles: out, gaps, runners: MODEL_ROUTE_RUNNERS, as_of: t };
        if (since !== null) Object.assign(res, await unroutedStages(env, since, project, t));
        return json(200, res);
      });
    },
  ],

  // ── GET one role's resolved ladder ───────────────────────────────────────
  [
    "GET", { prefix: "/api/model-routes/" },
    async ({ env, path, url, t }) => {
      return d1Guarded("model_routes", async () => {
        await ensureTable(env, "model_routes");
        let role;
        try { role = decodeURIComponent(path.slice("/api/model-routes/".length)); } catch { role = null; }
        if (role === null || badRole(role)) return json(400, { error: "role must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$, <= 128 chars" });
        const rawProject = url.searchParams.get("project");
        const norm = normalizeProject(rawProject === null ? undefined : rawProject);
        if (!norm.ok) return json(400, { error: "project must be a bare token, <= 64 chars" });
        const { ladder, source } = await resolveModelLadder(env, role, norm.project);
        // 200 with an empty ladder, not a 404: "no route for this role yet" is
        // a real answer a caller acts on (falls back to its own documented
        // constant), the same doctrine /api/retry-policies/:lane already uses.
        // scope_version is the version of the scope THIS read names (the
        // project's own override when ?project= is given — 0 if it has none —
        // else the hub), i.e. what a PUT or reset from here would replace.
        const scope_version = await modelRouteScopeVersion(env, role, norm.project);
        // The version of the HUB scope, always (BH-1563). On a project read
        // whose scope_version is 0 it is the only version the edit has: a save
        // that CREATES an override is based on the inherited hub ladder, so
        // `expected_version: 0` cannot catch the hub moving underneath it.
        // Equal to scope_version on a hub read.
        const hub_scope_version = norm.project ? await modelRouteScopeVersion(env, role, null) : scope_version;
        // The rows of the scope this read NAMES, when they exist and do not
        // start at rung 0 — the half-written ladder resolveModelLadder ignores.
        // scope_version above already counts them (max(id) over the scope), so
        // a reset or PUT carrying it repairs them under the same guard.
        const own = await env.DB.prepare(
          norm.project
            ? "SELECT position, model, runner FROM model_routes WHERE role=?1 AND project=?2 ORDER BY position ASC"
            : "SELECT position, model, runner FROM model_routes WHERE role=?1 AND project IS NULL ORDER BY position ASC"
        ).bind(...(norm.project ? [role, norm.project] : [role])).all();
        const ownRows = own.results || [];
        const gapped = ownRows.length > 0 && Number(ownRows[0].position) !== 0 ? { rows: ownRows } : null;
        // Who last wrote each rung of the RESOLVED ladder, beside it rather
        // than inside it: bin/lib/model-route.sh parses `ladder` and its rung
        // shape stays {position, model, runner}.
        const provRows = source === "none" ? { results: [] } : await env.DB.prepare(
          source === "project"
            ? "SELECT position, updated_by, updated_at FROM model_routes WHERE role=?1 AND project=?2 ORDER BY position ASC"
            : "SELECT position, updated_by, updated_at FROM model_routes WHERE role=?1 AND project IS NULL ORDER BY position ASC"
        ).bind(...(source === "project" ? [role, norm.project] : [role])).all();
        return json(200, {
          role, project: norm.project, ladder, source, scope_version, hub_scope_version, gapped,
          provenance: provRows.results || [], runners: MODEL_ROUTE_RUNNERS, as_of: t,
        });
      });
    },
  ],

  // ── PUT a role's whole ladder (hub, or one project's override) ──────────
  [
    "PUT", "/api/model-routes",
    async ({ env, t, body }) => {
      return d1Guarded("model_routes", async () => {
        await ensureTable(env, "model_routes");
        await ensureTable(env, "model_route_changes");
        const role = String(body.role || "").trim();
        if (badRole(role)) return json(400, { error: "role must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$, <= 128 chars" });
        const norm = normalizeProject(body.project, true);
        if (!norm.ok) return json(400, { error: "project must be a bare token, <= 64 chars, or absent/null for the hub default" });
        const project = norm.project;
        const scope = project ? "project" : "hub";
        const ev = expectedVersion(body.expected_version);
        if (!ev.ok) return json(400, { error: "expected_version must be a non-negative integer (the scope_version you read)" });
        // The HUB guard (BH-1563): a project write made on the INHERITED hub
        // ladder carries the hub's version too, so a hub edit in another tab
        // cannot land underneath an override being created from it. Refused on
        // a hub write rather than ignored — a caller that sent it there has
        // confused the two guards, and silently dropping it would leave it
        // believing it was protected.
        const ehv = expectedVersion(body.expected_hub_version);
        if (!ehv.ok) return json(400, { error: "expected_hub_version must be a non-negative integer (the hub_scope_version you read)" });
        if (ehv.v !== null && !project) {
          return json(400, { error: "expected_hub_version only applies to a project write (the hub write's own guard is expected_version)" });
        }

        if (!Array.isArray(body.ladder) || body.ladder.length === 0) {
          return json(400, { error: "ladder must be a non-empty array of {model, runner}" });
        }
        if (body.ladder.length > MAX_LADDER) {
          return json(400, { error: `ladder must carry at most ${MAX_LADDER} rungs` });
        }
        if (role.startsWith("stage.") && body.ladder.length > MAX_STAGE_LADDER) {
          return json(400, { error: `a stage.* ladder carries at most ${MAX_STAGE_LADDER} rungs (primary + fallback): agent-call reads no third` });
        }
        const ladder = [];
        for (let i = 0; i < body.ladder.length; i++) {
          const rung = body.ladder[i] || {};
          const model = typeof rung.model === "string" ? rung.model.trim() : "";
          const runner = typeof rung.runner === "string" ? rung.runner.trim() : "";
          if (!model || model.length > 256) return json(400, { error: `ladder[${i}].model must be a non-empty string, <= 256 chars` });
          if (!MODEL_ROUTE_RUNNERS.includes(runner)) {
            return json(400, { error: `ladder[${i}].runner must be one of ${MODEL_ROUTE_RUNNERS.join(", ")}` });
          }
          ladder.push({ position: i, model, runner });
        }
        // Every model named must already carry a price row — the "control the
        // pathway" premise fails quietly if a role can route to a model the
        // cost pipeline has never priced (it would report as $0 forever).
        const known = await knownModelIds(env);
        const unknown = ladder.filter((r) => !known.has(r.model)).map((r) => r.model);
        if (unknown.length > 0) {
          return json(400, { error: `unknown model(s), not in model_prices: ${[...new Set(unknown)].join(", ")}` });
        }

        const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
        const reason = body.reason ? String(body.reason).slice(0, 512) : null;

        const existingRows = await env.DB.prepare(
          project
            ? "SELECT position, model, runner, updated_by, updated_at FROM model_routes WHERE role=?1 AND project=?2 ORDER BY position ASC"
            : "SELECT position, model, runner, updated_by, updated_at FROM model_routes WHERE role=?1 AND project IS NULL ORDER BY position ASC"
        ).bind(...(project ? [role, project] : [role])).all();
        const before = new Map((existingRows.results || []).map((r) => [Number(r.position), r]));
        const expected = { v: ev.v, hub: ehv.v };
        if (ev.v !== null) {
          const current = await modelRouteScopeVersion(env, role, project);
          if (current !== ev.v) return staleNow(env, role, project, expected);
        }
        if (ehv.v !== null) {
          const currentHub = await modelRouteScopeVersion(env, role, null);
          if (currentHub !== ehv.v) return staleNow(env, role, project, expected);
        }

        // `confirm: true` on an unchanged ladder is "I have looked at this and
        // it is right": it re-stamps every rung with this actor and audits each
        // one with before = after. It is how a seeded rung stops reading SEED
        // without its model being changed (BH-1510.3 review).
        const confirm = body.confirm === true;
        const same = (was, rung) => was && was.model === rung.model && was.runner === rung.runner;
        const changed = ladder.some((rung) => !same(before.get(rung.position), rung))
          || [...before.keys()].some((pos) => pos >= ladder.length);
        if (!changed && !confirm) {
          const { ladder: after } = await resolveModelLadder(env, role, project);
          return json(200, { route: { scope, project, role, ladder: after }, changed: false });
        }

        // THE WHOLE SCOPE IS REPLACED IN ONE BATCH (BH-1510.3 review). The old
        // shape — upsert the rungs that moved, delete the positions it had READ
        // past the new length — let a write that committed between the read
        // and the batch leave rows nobody deleted: PUT/PUT produced [b0, a2],
        // and reset/PUT a project override holding only rung 2. Deleting every
        // row of (project, role) and inserting the new ladder in the SAME
        // transaction means the result is always exactly one request's ladder.
        // An unchanged rung keeps its own updated_by/updated_at (unless this is
        // a confirm): it was not decided by this write.
        const stmts = [];
        if (ev.v !== null) stmts.push(versionGuard(env, role, project, ev.v));
        // The hub guard rides in the SAME batch, for the same reason the
        // project one does: a read-time check alone still loses to a hub write
        // that commits between the check and the batch.
        if (ehv.v !== null) stmts.push(versionGuard(env, role, null, ehv.v));
        stmts.push(env.DB.prepare(
          "DELETE FROM model_routes WHERE coalesce(project,'')=coalesce(?1,'') AND role=?2"
        ).bind(project, role));
        const insert = env.DB.prepare(
          `INSERT INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8)`
        );
        const change = env.DB.prepare(
          `INSERT INTO model_route_changes
             (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)`
        );
        for (const rung of ladder) {
          const was = before.get(rung.position) || null;
          const keep = same(was, rung) && !confirm;
          stmts.push(insert.bind(scope, project, role, rung.position, rung.model, rung.runner,
            keep ? was.updated_by : actor, keep ? was.updated_at : t));
          if (keep) continue; // an unchanged rung is not a decision — no audit row, unless confirmed
          stmts.push(change.bind(
            scope, project, role, rung.position,
            was ? was.model : null, was ? was.runner : null,
            rung.model, rung.runner, actor, reason, t
          ));
        }
        // A shorter ladder than before: each dropped rung gets its own audit
        // row (after_* NULL); the DELETE above already removed it.
        for (const [pos, was] of before) {
          if (pos >= ladder.length) {
            stmts.push(change.bind(scope, project, role, pos, was.model, was.runner, null, null, actor, reason, t));
          }
        }
        const refused = await guardedBatch(env, stmts, role, project, expected);
        if (refused) return refused;

        const { ladder: after } = await resolveModelLadder(env, role, project);
        return json(200, { route: { scope, project, role, ladder: after } });
      });
    },
  ],

  // ── POST reset: drop one project's override, back to the hub (BH-1510.3) ─
  // Its own route because the PUT cannot say it: an empty ladder is refused
  // there on purpose (a hub role with no rungs would fail every caller closed).
  // PROJECT-ONLY — there is nothing above the hub to reset to — and an empty
  // project is refused rather than read as "the hub", the same rule the PUT's
  // normalizeProject applies to a typo'd scope. Every removed rung gets its own
  // audit row (after_* NULL), exactly like a PUT that shortened a ladder, read
  // inside the batch that deletes it (BH-1928). A project with no override is a
  // no-op: no tombstone, because a project scope has no seed to hold off.
  [
    "POST", "/api/model-routes/reset",
    async ({ env, t, body }) => {
      return d1Guarded("model_routes", async () => {
        await ensureTable(env, "model_routes");
        await ensureTable(env, "model_route_changes");
        const role = String(body.role || "").trim();
        if (badRole(role)) return json(400, { error: "role must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$, <= 128 chars" });
        const norm = normalizeProject(body.project);
        if (!norm.ok || !norm.project) {
          return json(400, { error: "project is required: reset drops a PROJECT's override; the hub default has nothing to reset to" });
        }
        const project = norm.project;
        const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
        const reason = body.reason ? String(body.reason).slice(0, 512) : null;
        const ev = expectedVersion(body.expected_version);
        if (!ev.ok) return json(400, { error: "expected_version must be a non-negative integer (the scope_version you read)" });
        // A guard field that quietly does nothing is worse than no guard: the
        // caller believes the write is protected (BH-1563). A reset deletes
        // THIS project's rows, and the hub ladder it falls back to afterwards
        // is not part of that decision, so the field has no meaning here.
        if (body.expected_hub_version !== undefined && body.expected_hub_version !== null) {
          return json(400, { error: "expected_hub_version does not apply to a reset — it deletes this project's own rows; guard it with expected_version" });
        }
        if (ev.v !== null) {
          const current = await modelRouteScopeVersion(env, role, project);
          if (current !== ev.v) return staleNow(env, role, project, { v: ev.v, hub: null });
        }

        // READ AND DELETE IN ONE BATCH (BH-1928): the audit rows are an
        // INSERT … SELECT over the rows the DELETE after it removes, in the same
        // transaction, so a write that lands after this request was sent is
        // audited with the value that was actually deleted, not a stale pre-read.
        // The WHOLE scope goes in one statement, not the positions this request
        // happened to read: a PUT that lands inside the window must not leave a
        // stray rung behind as a primary-less override (BH-1510.3 review).
        const stmts = [];
        if (ev.v !== null) stmts.push(versionGuard(env, role, project, ev.v));
        stmts.push(env.DB.prepare(
          `INSERT INTO model_route_changes
             (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
           SELECT 'project', project, role, position, model, runner, NULL, NULL, ?3, ?4, ?5
             FROM model_routes WHERE project=?1 AND role=?2 ORDER BY position ASC`
        ).bind(project, role, actor, reason, t));
        const del = stmts.length;
        stmts.push(env.DB.prepare("DELETE FROM model_routes WHERE project=?1 AND role=?2").bind(project, role));
        const results = [];
        const refused = await guardedBatch(env, stmts, role, project, { v: ev.v, hub: null }, results);
        if (refused) return refused;
        const removed = deletedCount(results[del]);

        const { ladder, source } = await resolveModelLadder(env, role, project);
        return json(200, { removed, route: { role, project, ladder, source } });
      });
    },
  ],

  // ── POST remove: take a role off the hub, durably (BH-1572) ──────────────
  // The PUT refuses an empty ladder and reset is project-only, so until this
  // route the only way to take a hub role away was a raw DELETE — and the next
  // deploy re-applied schema.sql and put the seeded rungs straight back. This is
  // the audited way: every removed rung gets its own audit row (after_* NULL),
  // and those rows are the TOMBSTONE — every model_routes seed in schema.sql
  // skips a role with any hub audit history, so a removed role stays removed.
  // A role with no route answers "none", and each caller then does what it does
  // for no route: a floor rung is skipped (the way to switch a floor off), a
  // build lane defers. Put a role back with a PUT.
  // HUB-ONLY: a project's override is dropped with /api/model-routes/reset,
  // which falls back to the hub rather than to nothing; a project here is
  // refused rather than read as the hub. A role with no hub rows is NOT a no-op
  // (BH-1928): it writes one tombstone audit row (position 0, before/after all
  // NULL) so the seeds skip it on the next deploy, and answers tombstone:true.
  [
    "POST", "/api/model-routes/remove",
    async ({ env, t, body }) => {
      return d1Guarded("model_routes", async () => {
        await ensureTable(env, "model_routes");
        await ensureTable(env, "model_route_changes");
        const role = String(body.role || "").trim();
        if (badRole(role)) return json(400, { error: "role must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$, <= 128 chars" });
        if (body.project !== undefined && body.project !== null) {
          return json(400, { error: "remove takes a hub role only; drop a project's override with POST /api/model-routes/reset" });
        }
        if (body.expected_hub_version !== undefined && body.expected_hub_version !== null) {
          return json(400, { error: "expected_hub_version does not apply to a remove — this IS the hub scope; guard it with expected_version" });
        }
        const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
        const reason = body.reason ? String(body.reason).slice(0, 512) : null;
        const ev = expectedVersion(body.expected_version);
        if (!ev.ok) return json(400, { error: "expected_version must be a non-negative integer (the scope_version you read)" });
        if (ev.v !== null) {
          const current = await modelRouteScopeVersion(env, role, null);
          if (current !== ev.v) return staleNow(env, role, null, { v: ev.v, hub: null });
        }

        // One batch, in this order, behind the guard: audit every hub rung the
        // DELETE is about to remove (read inside the batch, BH-1928), then the
        // tombstone when there is none, then the DELETE. D1 commits it all or
        // nothing, so a DELETE never lands without its audit, or the reverse.
        // The TOMBSTONE (BH-1928): with no hub rung there is nothing to audit,
        // and the seeds' guard would find no history, so the next deploy would
        // re-seed a role an operator just removed. One row at position 0 with
        // every before/after NULL (the one shape a real rung row never has)
        // is the history that makes the removal stick.
        const stmts = [];
        if (ev.v !== null) stmts.push(versionGuard(env, role, null, ev.v));
        stmts.push(env.DB.prepare(
          `INSERT INTO model_route_changes
             (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
           SELECT 'hub', NULL, role, position, model, runner, NULL, NULL, ?2, ?3, ?4
             FROM model_routes WHERE project IS NULL AND role=?1 ORDER BY position ASC`
        ).bind(role, actor, reason, t));
        stmts.push(env.DB.prepare(
          `INSERT INTO model_route_changes
             (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
           SELECT 'hub', NULL, ?1, 0, NULL, NULL, NULL, NULL, ?2, ?3, ?4
            WHERE NOT EXISTS (SELECT 1 FROM model_routes WHERE project IS NULL AND role=?1)`
        ).bind(role, actor, reason, t));
        const del = stmts.length;
        // The whole scope in one statement, for the reasons the PUT and reset give.
        stmts.push(env.DB.prepare("DELETE FROM model_routes WHERE project IS NULL AND role=?1").bind(role));
        const results = [];
        const refused = await guardedBatch(env, stmts, role, null, { v: ev.v, hub: null }, results);
        if (refused) return refused;
        const removed = deletedCount(results[del]);

        return json(200, { removed, role, tombstone: removed === 0 });
      });
    },
  ],

  // ── GET a role's audit trail (BH-1510.3) ─────────────────────────────────
  // Newest first. With ?project= the hub's changes come back too: a project on
  // the hub default runs whatever the hub was last set to, so the hub's edits
  // are part of that project's story. Without it, every scope for the role.
  // `limit` is a page bound, and `truncated` says when it bit.
  [
    "GET", "/api/model-route-changes",
    async ({ env, url, t }) => {
      return d1Guarded("model_route_changes", async () => {
        await ensureTable(env, "model_route_changes");
        const role = String(url.searchParams.get("role") || "").trim();
        if (badRole(role)) return json(400, { error: "role is required and must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$" });
        const rawProject = url.searchParams.get("project");
        const norm = normalizeProject(rawProject === null ? undefined : rawProject);
        if (!norm.ok) return json(400, { error: "project must be a bare token, <= 64 chars" });
        const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), MAX_CHANGES);
        // sql-ident-ok: the project clause is a literal picked by norm.project, which binds as ?3
        const rows = await env.DB.prepare(
          `SELECT id, scope, project, role, position, before_model, before_runner,
                  after_model, after_runner, actor, reason, at
             FROM model_route_changes
            WHERE role=?1${norm.project ? " AND (project IS NULL OR project=?3)" : ""}
            ORDER BY id DESC LIMIT ?2`
        ).bind(...(norm.project ? [role, limit + 1, norm.project] : [role, limit + 1])).all();
        const list = rows.results || [];
        return json(200, {
          role, project: norm.project,
          changes: list.slice(0, limit), truncated: list.length > limit, as_of: t,
        });
      });
    },
  ],
];

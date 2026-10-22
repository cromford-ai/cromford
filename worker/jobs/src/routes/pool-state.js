// pool-state routes — BH-5001 (BH-4951.2): the Fly pool's money-deciding state
// as rows every hub can read.
//
// bin/fly-pool.sh decided three spends from files that exist only on the hub
// (state/pool/<p>/): the per-key spawn ledger, the push-rejected terminal
// verdict and the lane-failure spawn hold, plus the held marker the fleet page
// counts. A rebuilt hub read "never spawned, never terminal, never held" and
// bought machines it had already been told not to. The readers go through
// bin/lib/pool-state-rows.sh, the backfill is bin/pool-state.sh, and both keep
// the files as the fail-open fallback. Timestamps a box sends (ts, until_at)
// are epoch seconds, like the files.

import { json } from "../lib/http.js";
import { strictInt, str, ensureTable, ensureColumns, laneName } from "../lib/core.js";

const TABLES = ["pool_spawns", "pool_terminals", "pool_holds"];
const LIMITS = { spawns: 2000, terminals: 500, holds: 500, markers: 2000 };
const ROWS_MAX = 500;
const TEXT_MAX = 500;
const KINDS = new Set(["spawn", "ticket"]);
// A hub name as bin/box-name.sh sanitises it, plus the backfill's `#k` suffix
// for the k-th repeat of one ts in one .spawns file.
const BOX_RE = /^[A-Za-z0-9._-]{1,64}(#[0-9]{1,6})?$/;
// The same shape check queue.js applies to a claim's machine.
const MACHINE_RE = /^[A-Za-z0-9._:-]{1,64}$/;

// pool_markers (BH-7431) is written by routes/pool-markers.js and read here, so
// the one GET a tick makes still carries every pool_* list.
const ensureAll = async (env) => { for (const tbl of [...TABLES, "pool_markers"]) await ensureTable(env, tbl); };
const boxOf = (v) => (typeof v === "string" && BOX_RE.test(v) ? v : "");
const epochOf = (v) => { const n = strictInt(v); return n !== null && n >= 0 ? n : null; };
const isTrue = (v) => v === true || v === 1 || v === "1" || v === "true";
const bad = (error) => json(400, { error });

// Reads one list with LIMIT+1, so a cut list says it was cut (D12).
async function bounded(env, sql, binds, limit) {
  // sql-ident-ok: sql is a literal from each bounded() call; limit is a LIMITS constant
  const r = await env.DB.prepare(`${sql} LIMIT ${limit + 1}`).bind(...binds).all();
  const rows = r.results || [];
  return { rows: rows.slice(0, limit), truncated: rows.length > limit };
}

export const routes = [
  // The whole snapshot for one project: one read per pool tick. Spawns are the
  // newest first from `since` on; terminals, holds and markers are every row.
  [
    "GET", "/api/pool-state",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const sinceRaw = url.searchParams.get("since");
      const since = sinceRaw === null || sinceRaw === "" ? 0 : epochOf(sinceRaw);
      if (since === null) return bad("since must be a non-negative epoch integer");
      await ensureAll(env);
      const s = await bounded(env,
        "SELECT ticket_key, ts, box, machine FROM pool_spawns WHERE project = ?1 AND ts >= ?2 ORDER BY ts DESC, box",
        [project, since], LIMITS.spawns);
      const tm = await bounded(env,
        "SELECT ticket_key, branch, head_sha, reason, created_at, cleared_at, cleared_why FROM pool_terminals WHERE project = ?1 ORDER BY updated_at DESC, ticket_key",
        [project], LIMITS.terminals);
      const h = await bounded(env,
        "SELECT kind, ticket_key, ticket_id, until_at, why, first_seen, last_seen FROM pool_holds WHERE project = ?1 ORDER BY updated_at DESC, kind, ticket_key",
        [project], LIMITS.holds);
      // BH-7431: the once-markers and wait clocks, the newest first.
      const mk = await bounded(env,
        "SELECT ticket_key, marker, value FROM pool_markers WHERE project = ?1 ORDER BY updated_at DESC, ticket_key, marker",
        [project], LIMITS.markers);
      return json(200, {
        project,
        spawns: s.rows.map((r) => ({ key: r.ticket_key, ts: Number(r.ts), box: r.box, machine: r.machine ?? null })),
        terminals: tm.rows.map((r) => ({
          key: r.ticket_key, branch: r.branch ?? null, head_sha: r.head_sha ?? null, reason: r.reason ?? null,
          created_at: r.created_at, cleared_at: r.cleared_at ?? null, cleared_why: r.cleared_why ?? null,
        })),
        holds: h.rows.map((r) => ({
          kind: r.kind, key: r.ticket_key, ticket_id: r.ticket_id ?? null,
          until_at: r.until_at === null || r.until_at === undefined ? null : Number(r.until_at),
          why: r.why ?? null, first_seen: r.first_seen ?? null, last_seen: r.last_seen ?? null,
        })),
        markers: mk.rows.map((r) => ({ key: r.ticket_key, marker: r.marker, value: r.value ?? "" })),
        as_of: t,
        truncated: { spawns: s.truncated, terminals: tm.truncated, holds: h.truncated, markers: mk.truncated },
      });
    },
  ],

  // One row per .spawns line. Every row is validated before anything is
  // written, so a bad row refuses the whole call; the rest is one batch.
  [
    "POST", "/api/pool-state/spawns",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const rows = body.rows;
      if (!Array.isArray(rows) || rows.length === 0 || rows.length > ROWS_MAX) {
        return bad(`rows must be a non-empty array of at most ${ROWS_MAX}`);
      }
      const clean = [];
      for (const r of rows) {
        const key = laneName(r && r.key);
        const ts = epochOf(r && r.ts);
        const box = boxOf(r && r.box);
        if (!key || ts === null || !box) return bad("each row needs key, an epoch ts and a box");
        let machine = null;
        if (r.machine !== undefined && r.machine !== null && r.machine !== "") {
          if (typeof r.machine !== "string" || !MACHINE_RE.test(r.machine)) return bad("machine is not a machine id");
          machine = r.machine;
        }
        clean.push([project, key, ts, box, machine, t]);
      }
      await ensureAll(env);
      const res = await env.DB.batch(clean.map((b) => env.DB.prepare(
        "INSERT INTO pool_spawns (project, ticket_key, ts, box, machine, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) "
        + "ON CONFLICT(project, ticket_key, ts, box) DO NOTHING"
      ).bind(...b)));
      const inserted = res.reduce((n, r) => n + Number((r && r.meta && r.meta.changes) || 0), 0);
      return json(200, { inserted, total: clean.length });
    },
  ],

  // The file's "remove ONE entry equal to ts" (BH-1279's un-record), on any box.
  [
    "POST", "/api/pool-state/spawns/remove",
    async ({ env, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      const ts = epochOf(body.ts);
      if (!project || !key || ts === null) return bad("project, key and an epoch ts are required");
      await ensureAll(env);
      const r = await env.DB.prepare(
        "DELETE FROM pool_spawns WHERE rowid = (SELECT rowid FROM pool_spawns WHERE project = ?1 AND ticket_key = ?2 AND ts = ?3 LIMIT 1)"
      ).bind(project, key, ts).run();
      return json(200, { removed: Number((r.meta && r.meta.changes) || 0) > 0 ? 1 : 0 });
    },
  ],

  // A new verdict: the upsert resets any clear. if_absent (backfill, heal from
  // a file) never overwrites a row, so a file cannot undo a newer DB verdict.
  [
    "PUT", "/api/pool-state/terminal",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) return bad("project and key must match [A-Za-z0-9._-]{1,64}");
      const box = body.box === undefined || body.box === null || body.box === "" ? null : boxOf(body.box);
      if (box === "") return bad("box is not a box name");
      await ensureAll(env);
      const tail = isTrue(body.if_absent)
        ? "ON CONFLICT(project, ticket_key) DO NOTHING"
        : "ON CONFLICT(project, ticket_key) DO UPDATE SET branch = excluded.branch, head_sha = excluded.head_sha, "
          + "reason = excluded.reason, created_at = excluded.created_at, box = excluded.box, "
          + "cleared_at = NULL, cleared_why = NULL, updated_at = excluded.updated_at";
      // sql-ident-ok: tail is one of two literal ON CONFLICT clauses
      const r = await env.DB.prepare(
        "INSERT INTO pool_terminals (project, ticket_key, branch, head_sha, reason, created_at, box, cleared_at, cleared_why, updated_at) "
        + `VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, NULL, ?8) ${tail}`
      ).bind(project, key, str(body.branch, TEXT_MAX), str(body.head_sha, TEXT_MAX), str(body.reason, TEXT_MAX),
        str(body.created_at, 64) || t, box, t).run();
      return json(200, { ok: true, inserted: Number((r.meta && r.meta.changes) || 0) > 0 ? 1 : 0 });
    },
  ],

  // The re-read head (an `unknown` head recorded), or the re-arm. A clear keeps
  // the verdict and the first clear's time; 404 when there is no row.
  [
    "PATCH", "/api/pool-state/terminal",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) return bad("project and key must match [A-Za-z0-9._-]{1,64}");
      const box = body.box === undefined || body.box === null || body.box === "" ? null : boxOf(body.box);
      if (box === "") return bad("box is not a box name");
      await ensureAll(env);
      let stmt;
      if (isTrue(body.clear)) {
        stmt = env.DB.prepare(
          "UPDATE pool_terminals SET cleared_why = CASE WHEN cleared_at IS NULL THEN ?4 ELSE cleared_why END, "
          + "cleared_at = COALESCE(cleared_at, ?3), box = COALESCE(?5, box), updated_at = ?3 "
          + "WHERE project = ?1 AND ticket_key = ?2"
        ).bind(project, key, t, str(body.why, TEXT_MAX), box);
      } else if (typeof body.head_sha === "string" && body.head_sha !== "") {
        stmt = env.DB.prepare(
          "UPDATE pool_terminals SET head_sha = ?3, box = COALESCE(?5, box), updated_at = ?4 WHERE project = ?1 AND ticket_key = ?2"
        ).bind(project, key, str(body.head_sha, TEXT_MAX), t, box);
      } else {
        return bad("send head_sha, or clear:true");
      }
      const r = await stmt.run();
      if (Number((r.meta && r.meta.changes) || 0) === 0) return json(404, { error: "no terminal row for this key" });
      return json(200, { ok: true });
    },
  ],

  // A spawn hold (kind spawn, key '', until_at) or a held marker (kind ticket).
  // first_seen survives a refresh; if_absent never overwrites.
  [
    "PUT", "/api/pool-state/holds",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const kind = typeof body.kind === "string" && KINDS.has(body.kind) ? body.kind : "";
      if (!kind) return bad("kind must be spawn or ticket");
      let key = "";
      if (kind === "ticket") {
        key = laneName(body.key);
        if (!key) return bad("a ticket hold names its key");
      } else if (body.key !== undefined && body.key !== null && body.key !== "") {
        return bad("a spawn hold is the project's: key must be empty");
      }
      let until = null;
      if (body.until_at !== undefined && body.until_at !== null && body.until_at !== "") {
        until = epochOf(body.until_at);
        if (until === null) return bad("until_at must be a non-negative epoch integer");
      }
      if (kind === "spawn" && until === null) return bad("a spawn hold needs until_at");
      const box = body.box === undefined || body.box === null || body.box === "" ? null : boxOf(body.box);
      if (box === "") return bad("box is not a box name");
      await ensureAll(env);
      const tail = isTrue(body.if_absent)
        ? "ON CONFLICT(project, kind, ticket_key) DO NOTHING"
        : "ON CONFLICT(project, kind, ticket_key) DO UPDATE SET ticket_id = excluded.ticket_id, "
          + "until_at = excluded.until_at, why = excluded.why, last_seen = excluded.last_seen, "
          + "box = excluded.box, updated_at = excluded.updated_at";
      // sql-ident-ok: tail is one of two literal ON CONFLICT clauses
      const r = await env.DB.prepare(
        "INSERT INTO pool_holds (project, kind, ticket_key, ticket_id, until_at, why, first_seen, last_seen, box, updated_at) "
        + `VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ${tail}`
      ).bind(project, kind, key, str(body.ticket_id, 64), until, str(body.why, TEXT_MAX),
        str(body.first_seen, 64) || t, str(body.last_seen, 64) || t, box, t).run();
      return json(200, { ok: true, inserted: Number((r.meta && r.meta.changes) || 0) > 0 ? 1 : 0 });
    },
  ],

  // Lifting a hold deletes it, as the file is deleted.
  [
    "PATCH", "/api/pool-state/holds",
    async ({ env, body }) => {
      const project = laneName(body.project);
      if (!project) return bad("project must match [A-Za-z0-9._-]{1,64}");
      const kind = typeof body.kind === "string" && KINDS.has(body.kind) ? body.kind : "";
      if (!kind) return bad("kind must be spawn or ticket");
      const key = kind === "ticket" ? laneName(body.key) : "";
      if (kind === "ticket" && !key) return bad("a ticket hold names its key");
      if (!isTrue(body.clear)) return bad("send clear:true");
      await ensureAll(env);
      const r = await env.DB.prepare(
        "DELETE FROM pool_holds WHERE project = ?1 AND kind = ?2 AND ticket_key = ?3"
      ).bind(project, kind, key).run();
      return json(200, { removed: Number((r.meta && r.meta.changes) || 0) > 0 ? 1 : 0 });
    },
  ],

  // The machine onto a claim won before the machine existed (spawn_one claims
  // before `fly machine run`). Never overwrites a claim that names another one.
  [
    "PUT", "/api/pool-state/claim-machine",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key);
      if (!project || !key) return bad("project and key must match [A-Za-z0-9._-]{1,64}");
      const machine = typeof body.machine === "string" && MACHINE_RE.test(body.machine) ? body.machine : "";
      if (!machine) return bad("machine is not a machine id");
      await ensureColumns(env, "build_queue");
      const r = await env.DB.prepare(
        "UPDATE build_queue SET machine = ?3, updated_at = ?4 WHERE project = ?1 AND ticket_key = ?2 "
        + "AND status = 'claimed' AND (machine IS NULL OR machine = ?3)"
      ).bind(project, key, machine, t).run();
      if (Number((r.meta && r.meta.changes) || 0) > 0) return json(200, { stamped: true, machine });
      const row = await env.DB.prepare(
        "SELECT status, machine FROM build_queue WHERE project = ?1 AND ticket_key = ?2"
      ).bind(project, key).first();
      if (row && row.status === "claimed") {
        return json(409, { error: "the claim names another machine", machine: row.machine });
      }
      return json(404, { error: "no claimed row for this key" });
    },
  ],
];

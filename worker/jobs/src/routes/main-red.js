// main-red routes — the detail behind a main-red freeze, and its audited CLEAR
// (BH-2372, BH-2329.1).
//
// Since BH-945 a red main is a pause_flags row named main-red-<owner>-<repo>,
// and that row stays the freeze every box reads. These routes add the two
// tables the contract (#2371) put beside it: main_red, the detector's detail
// (project, sha, workflow, job, run), and main_red_events, one row per raise,
// new sha, green or clear. They join the flags family, so src/index.js keeps
// its table as it was.
//
// A CLEAR is the one write here that touches the freeze row. It is one batch
// of three statements, each guarded on the flag still being active, so a clear
// cannot stamp main_red without dropping the freeze and writing its event, and
// two clears racing each other write one event between them.
//
// BH-4154: the freeze is read and cleared in the store its name picks
// (lib/harness-flags.js). main-red-* is not a ported name, so today that is
// the pause_flags row, exactly as before.

import { json, d1Guarded } from "../lib/http.js";
import { fleetFlagRows, readFleetFlag, flagActiveSql, clearFleetFlagStmt } from "../lib/harness-flags.js";

const NAME_RE = /^main-red-[A-Za-z0-9._-]+$/;
// The detector's own kill switches share the prefix. They are not freezes.
const KILL_SWITCHES = new Set(["main-red-detector-off", "main-red-pr-pair-off"]);
const CAP = 200;

function validName(v) {
  const n = String(v || "").trim();
  return n.length <= 128 && NAME_RE.test(n) && !KILL_SWITCHES.has(n) ? n : null;
}
function str(v, n) {
  if (v === undefined || v === null) return null;
  const s = String(v).trim().slice(0, n);
  return s || null;
}
const readRow = (env, name) => env.DB.prepare("SELECT * FROM main_red WHERE name=?1").bind(name).first();

export const routes = [
  [
    "GET", "/api/main-red",
    ({ env, url, t }) => d1Guarded("main_red", async () => {
      // ?all=1 is what the detector reads: every detail row, cleared_* included.
      // The default is what the console banner reads: live freezes only.
      if (url.searchParams.get("all") === "1") {
        const rows = (await env.DB.prepare("SELECT * FROM main_red ORDER BY name LIMIT ?1").bind(CAP + 1).all()).results || [];
        return json(200, { main_red: rows.slice(0, CAP), truncated: rows.length > CAP, as_of: t });
      }
      // The live freezes from the flag store, then their main_red detail by
      // name: the two can live in different tables, so the join is here.
      const { flags } = await fleetFlagRows(env, { prefix: "main-red-", onlyOn: 1, limit: CAP + 1 + KILL_SWITCHES.size });
      const live = flags.filter((f) => !KILL_SWITCHES.has(f.name)).slice(0, CAP + 1);
      const detail = new Map();
      if (live.length) {
        const got = await env.DB.prepare(
          "SELECT * FROM main_red WHERE name IN (SELECT value FROM json_each(?1))"
        ).bind(JSON.stringify(live.map((f) => f.name))).all();
        for (const r of got.results || []) detail.set(r.name, r);
      }
      const rows = live.map((f) => {
        const mr = detail.get(f.name) || {};
        return {
          name: f.name, active: f.active, actor: f.actor, reason: f.reason, updated_at: f.updated_at,
          slug: mr.slug ?? null, project: mr.project ?? null, sha: mr.sha ?? null, workflow: mr.workflow ?? null,
          job: mr.job ?? null, run_url: mr.run_url ?? null, since: mr.since ?? null, red_reason: mr.reason ?? null,
          cleared_sha: mr.cleared_sha ?? null, cleared_at: mr.cleared_at ?? null, cleared_by: mr.cleared_by ?? null,
          clear_reason: mr.clear_reason ?? null,
        };
      });
      return json(200, { main_red: rows.slice(0, CAP), truncated: rows.length > CAP, as_of: t });
    }),
  ],

  [
    // The detector's upsert. It writes main_red and its events only; the
    // freeze itself is still raised through PUT /api/flags.
    "PUT", "/api/main-red",
    ({ env, t, body }) => d1Guarded("main_red", async () => {
      const name = validName(body.name);
      if (!name) return json(400, { error: "valid main-red name required" });
      if (body.active === undefined || body.active === null) return json(400, { error: "active required" });
      const active = (body.active === true || body.active === 1 || body.active === "1" || body.active === "true") ? 1 : 0;
      const actor = str(body.actor, 128) || "detector";
      const sha = str(body.sha, 128);
      const reason = str(body.reason, 512);
      const stored = await readRow(env, name);

      // Sticky clear: an operator cleared this sha, so the detector seeing the
      // same red sha again is not news. Only a new sha re-raises.
      if (active === 1 && stored && stored.active === 0 && stored.cleared_sha !== null && stored.cleared_sha === sha) {
        return json(200, { main_red: stored, cleared: true });
      }

      const prev = stored ? stored.active : 0;
      const event = prev === 0 && active === 1 ? "raise"
        : prev === 1 && active === 1 && sha !== stored.sha ? "new_sha"
        : prev === 1 && active === 0 ? "green"
        : null;
      const stmts = [
        env.DB.prepare(
          `INSERT INTO main_red (name, slug, project, active, sha, workflow, job, run_url, since, reason, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
           ON CONFLICT(name) DO UPDATE SET slug=?2, project=?3, active=?4, sha=?5, workflow=?6, job=?7,
             run_url=?8, since=?9, reason=?10, updated_at=?11`
        ).bind(name, str(body.slug, 256), str(body.project, 128), active, sha, str(body.workflow, 256),
          str(body.job, 256), str(body.run_url, 512), str(body.since, 64), reason, t),
      ];
      if (event) {
        stmts.push(env.DB.prepare(
          "INSERT INTO main_red_events (name, action, sha, actor, reason, at) VALUES (?1,?2,?3,?4,?5,?6)"
        ).bind(name, event, sha, actor, reason, t));
      }
      await env.DB.batch(stmts);
      return json(200, { main_red: await readRow(env, name), event });
    }),
  ],

  [
    "POST", "/api/main-red/clear",
    ({ env, t, body }) => d1Guarded("main_red", async () => {
      const reason = String(body.reason || "").trim().slice(0, 512);
      if (!reason) return json(400, { error: "reason required" });
      const actor = String(body.actor || "").trim().slice(0, 128);
      if (!actor) return json(400, { error: "actor required" });
      const name = validName(body.name);
      if (!name) return json(400, { error: "valid main-red name required" });

      const flag = await readFleetFlag(env, name);
      if (!flag || Number(flag.active) !== 1) return json(409, { error: "not red" });
      const mr = await readRow(env, name);
      // The operator cleared the sha they were shown. A detector that has
      // since moved the row to another sha makes that a different decision.
      const seen = str(body.sha, 128);
      if (seen && seen !== (mr ? mr.sha : null)) return json(409, { error: "moved to a new sha" });

      const stillRed = flagActiveSql(name);
      const [ev] = await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO main_red_events (name, action, sha, actor, reason, at)
           SELECT ?1, 'clear', ?2, ?3, ?4, ?5 WHERE ${stillRed}`
        ).bind(name, mr ? mr.sha : null, actor, reason, t),
        env.DB.prepare(
          `UPDATE main_red SET active=0, cleared_sha=sha, cleared_at=?2, cleared_by=?3, clear_reason=?4, updated_at=?2
            WHERE name=?1 AND ${stillRed}`
        ).bind(name, t, actor, reason),
        clearFleetFlagStmt(env, name, actor, reason, t),
      ]);
      // Another clear landed between the read above and this batch.
      if (!ev || !ev.meta || ev.meta.changes !== 1) return json(409, { error: "not red" });
      const after = await readFleetFlag(env, name);
      return json(200, { cleared: true, flag: after, main_red: (await readRow(env, name)) || null });
    }),
  ],
];

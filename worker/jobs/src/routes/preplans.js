// preplans routes — the plan a watcher box already paid for.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  PREPLAN_MAX_BYTES, PREPLAN_FILES_MAX_BYTES, PREPLAN_RETENTION_DAYS,
  PREPLAN_INDEX_COLS, str, ensureTable, ensureColumns, laneName,
} from "../lib/core.js";

// GET /api/preplans/adoption. Exported so the test EXPLAINs the statements that
// ship. ?1 = since, ?2 = project or NULL for every project. Both are served by
// idx_events_stage_created (schema.sql). The recent read asks for one row past
// its cap so recent_truncated is measured, not guessed.
const ADOPTION_WHERE = `WHERE e.stage='preplan' AND e.created_at >= ?1
     AND e.verdict IN ('ADOPTED','STALE','MISS','OFF')
     AND (?2 IS NULL OR j.project=?2)`;
const ADOPTION_RECENT_MAX = 50;
// COUNT(DISTINCT e.job_id), not COUNT(*): one build is one outcome. A POST that
// reached D1 but lost its reply is re-sent by bin/lib/jobs/req.sh and lands a
// second row for the same job; counting rows would skew the rate the cadence
// gate reads (BH-2543.1). The build side also posts once per $BUILD dir.
export const ADOPTION_COUNTS_SQL = `SELECT j.project AS project, substr(e.created_at,1,10) AS day,
       e.verdict AS verdict, COUNT(DISTINCT e.job_id) AS n
  FROM stage_events e JOIN jobs j ON j.id=e.job_id
  ${ADOPTION_WHERE}
  GROUP BY j.project, day, e.verdict`;
export const ADOPTION_RECENT_SQL = `SELECT e.job_id AS job_id, j.ticket_id AS ticket_id, j.project AS project,
       e.verdict AS verdict, e.detail AS detail, e.created_at AS created_at
  FROM stage_events e JOIN jobs j ON j.id=e.job_id
  ${ADOPTION_WHERE}
  ORDER BY e.created_at DESC, e.id DESC LIMIT ${ADOPTION_RECENT_MAX + 1}`;

export const routes = [
  // ── Pre-plans (BH-658) ─────────────────────────────────────────────────
  // The plan a watcher box already paid for, published so the HUB can hand it
  // to the Fly machine that will build the ticket. See the `preplans` comment
  // in schema.sql for why this is a row and not the queue row's meta column.
  //
  // WRITE IS BEARER-ONLY AND POST-ONLY, like transcripts: a fabricated plan
  // on a real ticket is the worst kind of evidence, the kind a builder would
  // execute.
  [
    "POST", "/api/preplans",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key || body.ticket_key);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!key) return json(400, { error: "ticket_key is required and must match [A-Za-z0-9._-]{1,64}" });
      const planMd = typeof body.plan_md === "string" ? body.plan_md : "";
      if (!planMd.trim()) return json(400, { error: "plan_md must be a non-empty plan" });
      // NEVER TRUNCATED — see PREPLAN_MAX_BYTES. The publisher logs REFUSED and
      // the build plans fresh, which is the honest outcome; a stored prefix of a
      // plan is a design the builder would execute half of.
      // Measured in BYTES, which is what the column and the constant both say:
      // a plan is prose and a multi-byte character would otherwise be counted as
      // one against a limit named for bytes.
      const planBytes = new TextEncoder().encode(planMd).length;
      if (planBytes > PREPLAN_MAX_BYTES) return json(413, { error: "plan too large" });
      // No base sha means bin/lib/preplan-lib.sh:preplan_check can never judge
      // this plan, and an unjudgeable pre-plan is discarded at adopt. Refusing
      // it here keeps a row that nobody may use out of the table entirely.
      const baseSha = String(body.base_sha || "").trim().toLowerCase();
      if (!/^[0-9a-f]{7,40}$/.test(baseSha)) return json(400, { error: "base_sha must be a git sha" });
      // REFUSED over cap, not sliced — see PREPLAN_FILES_MAX_BYTES. A prefix of
      // the file list would weaken the staleness check and the overlap guard in
      // the fail-OPEN direction, which is the direction that ships a wrong build.
      const plannedFiles = body.planned_files === undefined || body.planned_files === null
        ? "" : String(body.planned_files);
      if (new TextEncoder().encode(plannedFiles).length > PREPLAN_FILES_MAX_BYTES) {
        return json(413, { error: "planned_files too large" });
      }
      const str = (v, n) => (v === undefined || v === null || v === "" ? null : String(v).slice(0, n));
      // BH-5799: when the planner started reading the ticket thread. The plan
      // thread gate (bin/lib/plan-thread.sh) counts a comment newer than this
      // as one the plan must cite. Anything but a whole-second UTC ISO stamp is
      // stored NULL, and a NULL row is judged as having read nothing.
      const threadAt = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(String(body.thread_at || ""))
        ? String(body.thread_at) : null;
      // The table creates itself before the first statement that needs it: the
      // worker deploys on merge, and nothing else applies schema.sql. See
      // ensureTable. thread_at is an ADDED column (ADDED_COLUMNS).
      await ensureTable(env, "preplans");
      await ensureColumns(env, "preplans");
      await env.DB.prepare(
        `INSERT INTO preplans
           (project, ticket_key, base_sha, ticket_fp, planned_files, plan_md, bytes, box, created_at, updated_at, thread_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?9,?10)
         ON CONFLICT(project, ticket_key) DO UPDATE SET
           base_sha=?3, ticket_fp=?4, planned_files=?5, plan_md=?6, bytes=?7,
           box=COALESCE(?8, box), updated_at=?9, thread_at=?10`
      ).bind(project, key, baseSha, str(body.ticket_fp, 512), plannedFiles || null,
        planMd, planBytes, str(body.box, 64), t, threadAt).run();
      // Housekeeping rides the write: one bounded statement, no sweep, no cron.
      const cutoff = new Date(Date.parse(t) - PREPLAN_RETENTION_DAYS * 86400000)
        .toISOString().replace(/\.\d{3}Z$/, "Z");
      await env.DB.prepare("DELETE FROM preplans WHERE updated_at < ?1").bind(cutoff).run();
      // The row WITHOUT its plan: the publisher has the plan on disk already.
      // sql-ident-ok: PREPLAN_INDEX_COLS is an export const column list in lib/core.js
      const row = await env.DB.prepare(
        `SELECT ${PREPLAN_INDEX_COLS} FROM preplans WHERE project=?1 AND ticket_key=?2`
      ).bind(project, key).first();
      return json(200, { preplan: row });
    },
  ],

  // One pre-plan, WITH its plan — the relay's read, once per spawn. A 404
  // means exactly what it says: nothing published for this ticket, and
  // bin/fly-pool.sh says so in its log rather than shipping a partial dir.
  // Without `key`: the INDEX, no bodies — what bin/overlap-guard.sh needs to
  // judge a candidate's file list from the hub.
  [
    "GET", "/api/preplans",
    async ({ env, url, t }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project is required" });
      // The READ creates it too: on a fresh database the hub's relay and the
      // overlap guard both run before any box has published, and an honest 404
      // beats a 500 that reads as an outage.
      await ensureTable(env, "preplans");
      await ensureColumns(env, "preplans");
      const key = laneName(url.searchParams.get("key") || url.searchParams.get("ticket_key"));
      if (key) {
        const row = await env.DB.prepare(
          "SELECT * FROM preplans WHERE project=?1 AND ticket_key=?2"
        ).bind(project, key).first();
        if (!row) return json(404, { error: "no such preplan" });
        return json(200, { preplan: row, as_of: t });
      }
      // sql-ident-ok: PREPLAN_INDEX_COLS is an export const column list in lib/core.js
      const rows = await env.DB.prepare(
        `SELECT ${PREPLAN_INDEX_COLS} FROM preplans WHERE project=?1
          ORDER BY updated_at DESC LIMIT 500`
      ).bind(project).all();
      return json(200, { preplans: rows.results || [], as_of: t });
    },
  ],

  // ── Pre-plan adoption (BH-2543) ────────────────────────────────────────
  // How many pre-plans a build actually used. Each non-resumed build posts one
  // stage_events row (stage='preplan', verdict ADOPTED|STALE|MISS|OFF) from
  // `# >>> preplan outcome event (BH-2543)` in bin/lib/rb/plan.sh; the shape
  // below is the contract in bin/lib/preplan-cadence.sh.
  [
    "GET", "/api/preplans/adoption",
    async ({ env, url, t }) => {
      const rawProject = url.searchParams.get("project");
      let project = null;
      if (rawProject !== null && rawProject !== "") {
        project = laneName(rawProject);
        if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      }
      // Out of range is refused, never clamped: a caller asking for 90 days and
      // silently getting 30 would read a 30-day rate as a 90-day one.
      const rawDays = url.searchParams.get("days");
      let days = 7;
      if (rawDays !== null) {
        days = /^\d+$/.test(rawDays) ? Number(rawDays) : 0;
        if (days < 1 || days > 30) return json(400, { error: "days must be an integer 1-30" });
      }
      const since = new Date(Date.parse(t) - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      const counts = await env.DB.prepare(ADOPTION_COUNTS_SQL).bind(since, project).all();
      const recentRows = await env.DB.prepare(ADOPTION_RECENT_SQL).bind(since, project).all();

      const zero = () => ({ adopted: 0, stale: 0, miss: 0, off: 0 });
      const byProject = new Map();
      const byDay = new Map();
      for (const r of counts.results || []) {
        const k = r.verdict.toLowerCase();
        if (!byProject.has(r.project)) byProject.set(r.project, zero());
        byProject.get(r.project)[k] += r.n;
        const dk = `${r.project}\u0000${r.day}`;
        if (!byDay.has(dk)) byDay.set(dk, { project: r.project, day: r.day, ...zero() });
        byDay.get(dk)[k] += r.n;
      }
      // bought = adopted + stale; nothing bought is an unknown rate, never 0.
      const rate = (c) => (c.adopted + c.stale ? c.adopted / (c.adopted + c.stale) : null);
      // BH-3437: builds = every build that looked for a pre-plan (adopted +
      // stale + miss); OFF is switched off on purpose, not missed. hit_rate =
      // adopted/builds, null with no builds. Additive: rate/bought stay as the
      // cadence gate reads them.
      const hits = (c) => {
        const builds = c.adopted + c.stale + c.miss;
        return { builds, hit_rate: builds ? c.adopted / builds : null };
      };
      const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
      const projects = [...byProject.entries()]
        .sort((a, b) => cmp(a[0], b[0]))
        .map(([p, c]) => ({ project: p, ...c, bought: c.adopted + c.stale, rate: rate(c), ...hits(c) }));
      const dayRows = [...byDay.values()]
        .sort((a, b) => cmp(a.project, b.project) || cmp(a.day, b.day))
        .map((d) => ({ ...d, rate: rate(d), ...hits(d) }));
      const recent = recentRows.results || [];
      return json(200, {
        window_days: days, since, projects, days: dayRows,
        recent: recent.slice(0, ADOPTION_RECENT_MAX),
        recent_truncated: recent.length > ADOPTION_RECENT_MAX,
        as_of: t,
      });
    },
  ],
];

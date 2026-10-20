// roadmap-wave-file routes — BH-7243.4 (BH-7267): approve a drafted roadmap
// wave, file its slices as ai-build GitHub issues, and keep the linked issues'
// state in sync. Tables: worker/jobs/schema.d/*-bh-7243-roadmap-ideas.sql
// (roadmap_waves, roadmap_links); knobs:
// schema.d/202610191957-bh-7243-roadmap-wave-file.sql. Route list:
// test/route-table.d/bh-7243-roadmap-wave-file.txt. Lanes: bin/roadmap-file.sh
// (file-claim, filed, file-done) and bin/roadmap-issue-sync.sh (links/stale,
// links/state). The console writes approve and reject only
// (console-ui/functions/_lib/coord-writes.d/7243-roadmap-wave-file.js).
//
// THE STATUS FLOW. draft -approve-> approved -file-claim-> filing
// -file-done filed-> filed. file-done approved (with an error) sends a filing
// wave back to approved, and the claim retries it after roadmap.file_retry_min.
// A filing wave whose lane died is claimed again after the same window.
// draft -reject-> rejected. Every move is a CAS on the status column.
//
// POST /api/roadmap/waves/approve {id, project, expected_status:'draft', actor}
//   400 on a bad id or project, or expected_status other than draft. 403 when
//   the actor is blank, archie, a staff_agents name, or `console` while
//   roadmap.approve_requires_identity is 1. 404 when no wave has this id in
//   this project. 409 when the wave is not draft or its draft has no slices.
//   200 {wave}.
// POST /api/roadmap/waves/reject {id, project, reason?, actor}
//   The same gate and CAS, draft -> rejected; error = `rejected: <reason>`.
// POST /api/roadmap/waves/file-claim {box, dry_run?}
//   200 {wave:null} when nothing is claimable, else {wave:{id, project,
//   idea_ids, draft, approved_by}, repo, board_api_prefix}. A wave whose
//   project has no projects row (or whose draft has no slices) goes back to
//   approved with an error: 200 {wave:null, skipped:id}. dry_run reads only.
// POST /api/roadmap/waves/filed {id, slice, repo, issue}
//   One roadmap_links row per idea of the wave, idempotent on the primary key.
//   200 {written, linked}.
// POST /api/roadmap/waves/file-done {id, status: filed|approved, error?}
//   filed only when the wave's links name as many distinct issues as it has
//   slices (409 otherwise). approved needs an error.
// GET /api/roadmap/waves/issues?id=&project=
//   200 {wave:{id, status, slice_count, repo, error, approved_by,
//   approved_at}, issues:[{repo, issue, issue_state, url}]}.
// GET /api/roadmap/links/stale?limit=
//   Links never read, then the oldest read, older than
//   roadmap.issue_sync_stale_min; at most roadmap.issue_sync_batch rows.
//   200 {links:[{repo, issue, state_seen_at}], as_of}, one entry per issue.
// PUT /api/roadmap/links/state {repo, issue, issue_state} | {repo, issue, tried:true}
//   Every link row of that issue. 200 {updated}; 404 when none exists.
//   state_seen_at is the time the lane last asked GitHub about the issue.
//   tried:true stamps it and keeps issue_state: a read that failed (404, 403,
//   5xx, an unknown state) goes to the back of the stale queue, so one dead
//   issue never holds the head of the queue on every tick.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { ensureRoadmapTables } from "./roadmap-ideas.js";

export const ISSUE_STATES = ["open", "closed_completed", "closed_other"];
const WAVE_ID_RE = /^[A-Za-z0-9._:-]{1,80}$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const BOX_RE = /^[A-Za-z0-9._-]{1,64}$/;
const ACTOR_MAX = 120;
const TEXT_MAX = 500;
// One INSERT holds this many ideas: 5 shared binds + one per idea, under D1's 100.
const LINK_CHUNK = 90;

// The SQL texts, exported so the EXPLAIN test reads exactly what runs.
// claim read: idx_roadmap_waves_status (status IN (...)).
export const CLAIM_SQL = `SELECT id, status, updated_at, claimed_at FROM roadmap_waves
  WHERE status IN ('approved', 'filing')
    AND ((status = 'approved' AND (error IS NULL OR updated_at < ?1)) OR (status = 'filing' AND claimed_at < ?1))
  ORDER BY updated_at LIMIT 1`;
// waves/issues and the board read: idx_roadmap_links_wave.
export const ISSUES_LINKS_SQL = "SELECT repo, issue, issue_state FROM roadmap_links WHERE wave_id = ?1 AND project = ?2 ORDER BY issue";
// The sync lane's read: idx_roadmap_links_state_seen. NULL sorts first, so a
// link never read goes before every link read once.
export const STALE_SQL = "SELECT repo, issue, state_seen_at FROM roadmap_links WHERE state_seen_at IS NULL OR state_seen_at < ?1 ORDER BY state_seen_at LIMIT ?2";
// The sync lane's write: idx_roadmap_links_repo_issue.
export const STATE_SQL = "UPDATE roadmap_links SET issue_state = ?3, state_seen_at = ?4 WHERE repo = ?1 AND issue = ?2";
// A failed read: idx_roadmap_links_repo_issue. issue_state keeps its last value.
export const TRIED_SQL = "UPDATE roadmap_links SET state_seen_at = ?3 WHERE repo = ?1 AND issue = ?2";
// filed only when every slice has a link. The COUNT is one scalar subquery on
// idx_roadmap_links_wave, run once for the one wave row, never per row.
export const FILE_DONE_SQL = `UPDATE roadmap_waves SET status = 'filed', error = NULL, updated_at = ?3
  WHERE id = ?1 AND status = 'filing' AND (SELECT COUNT(DISTINCT issue) FROM roadmap_links WHERE wave_id = ?1) >= ?2`;

const WAVE_COLS = "id, project, status, idea_ids, draft, error, claimed_by, claimed_at, approved_by, approved_at, updated_at";
// sql-ident-ok: WAVE_COLS is a module constant
const WAVE_SQL = `SELECT ${WAVE_COLS} FROM roadmap_waves WHERE id = ?1 AND project = ?2`;

const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };
export function draftSlices(text) {
  const d = typeof text === "string" ? parse(text) : null;
  return d && typeof d === "object" && Array.isArray(d.slices) ? d.slices : [];
}
const ideaIds = (text) => {
  const v = typeof text === "string" ? parse(text) : null;
  return Array.isArray(v) ? v.filter((x) => typeof x === "string" && x !== "") : [];
};
const waveOut = (w) => ({
  id: w.id, project: w.project, status: w.status, error: w.error ?? null, approved_by: w.approved_by ?? null,
  approved_at: w.approved_at ?? null, updated_at: w.updated_at, slice_count: draftSlices(w.draft).length,
});
const minutesBefore = (t, min) => new Date(Date.parse(t) - min * 60e3).toISOString().replace(/\.\d{3}Z$/, "Z");
const isPosInt = (v) => Number.isInteger(v) && v >= 1;
const issueUrl = (repo, n) => `https://github.com/${repo}/issues/${n}`;

// Settings and the five roadmap tables, read and ensured in parallel.
async function prep(env) {
  const [{ byKey }] = await Promise.all([settingsRows(env), ensureRoadmapTables(env)]);
  return byKey;
}

// The approve and reject gate, the parts that need no read (D14: a blank
// actor fails closed). Returns {actor} or {refuse}.
function actorCheck(byKey, raw) {
  const actor = typeof raw === "string" ? raw.trim() : "";
  if (!actor || actor.length > ACTOR_MAX) return { refuse: "actor is required: a person decides a wave" };
  const low = actor.toLowerCase();
  if (low === "archie") return { refuse: "actor archie is an agent: a person decides a wave" };
  if (low === "console" && intSetting(byKey, "roadmap.approve_requires_identity", 0, 0, 1) === 1) {
    return { refuse: "actor console is refused while roadmap.approve_requires_identity is 1: sign in with a named identity" };
  }
  return { actor, low };
}
// A staff_agents roster name is an agent (the staff.js isAgentActor rule). A
// database without the roster table has no agents.
async function isStaffAgent(env, low) {
  try {
    return !!(await env.DB.prepare("SELECT 1 AS x FROM staff_agents WHERE name = ?1").bind(low).first());
  } catch (e) {
    if (/no such table/i.test(String((e && e.message) || e))) return false;
    throw e;
  }
}

// decide(to): the approve (to = approved) and reject (to = rejected) handler.
const decide = (to) => ({ env, t, body }) => d1Guarded("roadmap_waves", async () => {
  const b = body && typeof body === "object" ? body : {};
  const id = typeof b.id === "string" && WAVE_ID_RE.test(b.id) ? b.id : "";
  if (!id) return json(400, { error: "id must match ^[A-Za-z0-9._:-]{1,80}$", field: "id" });
  const project = typeof b.project === "string" ? laneName(b.project) : "";
  if (!project) return json(400, { error: "project must match ^[A-Za-z0-9._-]{1,64}$", field: "project" });
  let reason = null;
  if (to === "approved" && b.expected_status !== "draft") {
    return json(400, { error: "expected_status must be draft", field: "expected_status" });
  }
  if (to === "rejected" && b.reason !== undefined && b.reason !== null && b.reason !== "") {
    if (typeof b.reason !== "string" || b.reason.length > TEXT_MAX) return json(400, { error: `reason must be a string of at most ${TEXT_MAX} characters`, field: "reason" });
    reason = b.reason.trim() || null;
  }
  const byKey = await prep(env);
  const gate = actorCheck(byKey, b.actor);
  if (gate.refuse) return json(403, { error: gate.refuse });
  const [agent, w] = await Promise.all([isStaffAgent(env, gate.low), env.DB.prepare(WAVE_SQL).bind(id, project).first()]);
  if (agent) return json(403, { error: `actor ${gate.actor} is a staff agent: a person decides a wave` });
  if (!w) return json(404, { error: "no such wave" });
  if (w.status !== "draft") return json(409, { error: `wave is ${w.status}, not draft`, wave: waveOut(w) });
  if (to === "approved" && draftSlices(w.draft).length < 1) return json(409, { error: "draft has no slices", wave: waveOut(w) });

  const res = to === "approved"
    ? await env.DB.prepare(
      `UPDATE roadmap_waves SET status = 'approved', approved_by = ?3, approved_at = ?4, error = NULL, updated_at = ?4
        WHERE id = ?1 AND project = ?2 AND status = 'draft'`).bind(id, project, gate.actor, t).run()
    : await env.DB.prepare(
      `UPDATE roadmap_waves SET status = 'rejected', error = ?3, updated_at = ?4
        WHERE id = ?1 AND project = ?2 AND status = 'draft'`).bind(id, project, reason ? `rejected: ${reason}` : "rejected", t).run();
  const now = await env.DB.prepare(WAVE_SQL).bind(id, project).first();
  if (Number(res.meta.changes) !== 1) return json(409, { error: `wave is ${now ? now.status : "gone"}, not draft`, wave: now ? waveOut(now) : null });
  return json(200, { wave: waveOut(now) });
});

export const routes = [
  ["POST", "/api/roadmap/waves/approve", decide("approved")],
  ["POST", "/api/roadmap/waves/reject", decide("rejected")],

  [
    "POST", "/api/roadmap/waves/file-claim",
    ({ env, t, body }) => d1Guarded("roadmap_waves", async () => {
      const b = body && typeof body === "object" ? body : {};
      const box = typeof b.box === "string" && BOX_RE.test(b.box) ? b.box : "";
      if (!box) return json(400, { error: "box must match ^[A-Za-z0-9._-]{1,64}$", field: "box" });
      const dry = b.dry_run === true;
      const byKey = await prep(env);
      const cutoff = minutesBefore(t, intSetting(byKey, "roadmap.file_retry_min", 30, 1, 1440));
      const cand = await env.DB.prepare(CLAIM_SQL).bind(cutoff).first();
      if (!cand) return json(200, { wave: null });
      if (!dry) {
        const res = await env.DB.prepare(
          `UPDATE roadmap_waves SET status = 'filing', claimed_by = ?2, claimed_at = ?3, updated_at = ?3
            WHERE id = ?1 AND status = ?4 AND updated_at = ?5 AND COALESCE(claimed_at, '') = ?6`
        ).bind(cand.id, box, t, cand.status, cand.updated_at, cand.claimed_at || "").run();
        if (Number(res.meta.changes) !== 1) return json(200, { wave: null });
      }
      const [wr, pr] = await env.DB.batch([
        env.DB.prepare(`SELECT ${WAVE_COLS} FROM roadmap_waves WHERE id = ?1`).bind(cand.id), // sql-ident-ok: WAVE_COLS is a module constant
        env.DB.prepare("SELECT p.repo, p.board_api_prefix FROM projects p JOIN roadmap_waves w ON w.project = p.project WHERE w.id = ?1").bind(cand.id),
      ]);
      const w = (wr.results || [])[0];
      const p = (pr.results || [])[0];
      const slices = w ? draftSlices(w.draft) : [];
      const why = !p ? "project has no projects row" : slices.length < 1 ? "draft has no slices" : "";
      if (why) {
        if (!dry) {
          await env.DB.prepare(
            `UPDATE roadmap_waves SET status = 'approved', error = ?2, claimed_by = NULL, updated_at = ?3
              WHERE id = ?1 AND status = 'filing' AND claimed_by = ?4`).bind(cand.id, why, t, box).run();
        }
        return json(200, { wave: null, skipped: cand.id, error: why });
      }
      return json(200, {
        wave: { id: w.id, project: w.project, idea_ids: ideaIds(w.idea_ids), draft: { ...parse(w.draft), slices }, approved_by: w.approved_by ?? null },
        repo: p.repo, board_api_prefix: p.board_api_prefix || null,
      });
    }),
  ],

  [
    "POST", "/api/roadmap/waves/filed",
    ({ env, t, body }) => d1Guarded("roadmap_links", async () => {
      const b = body && typeof body === "object" ? body : {};
      const id = typeof b.id === "string" && WAVE_ID_RE.test(b.id) ? b.id : "";
      if (!id) return json(400, { error: "id must match ^[A-Za-z0-9._:-]{1,80}$", field: "id" });
      if (!isPosInt(b.slice)) return json(400, { error: "slice must be an integer of 1 or more", field: "slice" });
      if (!isPosInt(b.issue)) return json(400, { error: "issue must be an integer of 1 or more", field: "issue" });
      if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return json(400, { error: "repo must be owner/name", field: "repo" });
      await ensureRoadmapTables(env);
      const w = await env.DB.prepare(
        "SELECT w.status, w.project, w.idea_ids, w.draft, p.repo FROM roadmap_waves w LEFT JOIN projects p ON p.project = w.project WHERE w.id = ?1"
      ).bind(id).first();
      if (!w) return json(404, { error: "no such wave" });
      if (w.status !== "filing") return json(409, { error: `wave is ${w.status}, not filing` });
      if (b.slice > draftSlices(w.draft).length) return json(400, { error: "slice is past the last slice of the draft", field: "slice" });
      if (b.repo !== w.repo) return json(400, { error: "repo is not the project's repo", field: "repo" });
      const ideas = ideaIds(w.idea_ids);
      if (!ideas.length) return json(409, { error: "wave has no idea_ids" });
      const stmts = [];
      for (let i = 0; i < ideas.length; i += LINK_CHUNK) {
        const part = ideas.slice(i, i + LINK_CHUNK);
        const values = part.map((_, k) => `(?${k + 6}, ?1, ?2, ?3, ?4, 'roadmap-file', ?5)`).join(", ");
        // sql-ident-ok: values is built from numbered placeholders only
        stmts.push(env.DB.prepare(
          `INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, created_by, created_at) VALUES ${values}
            ON CONFLICT (idea_id, repo, issue) DO NOTHING`
        ).bind(w.project, b.repo, b.issue, id, t, ...part));
      }
      const res = await env.DB.batch(stmts);
      const written = res.reduce((n, r) => n + Number((r.meta && r.meta.changes) || 0), 0);
      return json(200, { written, linked: ideas.length });
    }),
  ],

  [
    "POST", "/api/roadmap/waves/file-done",
    ({ env, t, body }) => d1Guarded("roadmap_waves", async () => {
      const b = body && typeof body === "object" ? body : {};
      const id = typeof b.id === "string" && WAVE_ID_RE.test(b.id) ? b.id : "";
      if (!id) return json(400, { error: "id must match ^[A-Za-z0-9._:-]{1,80}$", field: "id" });
      if (b.status !== "filed" && b.status !== "approved") return json(400, { error: "status must be filed or approved", field: "status" });
      const err = typeof b.error === "string" ? b.error.trim() : "";
      if (b.status === "approved" && (!err || err.length > TEXT_MAX)) {
        return json(400, { error: `error is required with approved: 1..${TEXT_MAX} characters`, field: "error" });
      }
      await ensureRoadmapTables(env);
      const w = await env.DB.prepare(`SELECT ${WAVE_COLS} FROM roadmap_waves WHERE id = ?1`).bind(id).first(); // sql-ident-ok: WAVE_COLS is a module constant
      if (!w) return json(404, { error: "no such wave" });
      if (w.status !== "filing") return json(409, { error: `wave is ${w.status}, not filing`, wave: waveOut(w) });
      const res = b.status === "filed"
        ? await env.DB.prepare(FILE_DONE_SQL).bind(id, draftSlices(w.draft).length, t).run()
        : await env.DB.prepare(
          `UPDATE roadmap_waves SET status = 'approved', error = ?2, claimed_by = NULL, updated_at = ?3
            WHERE id = ?1 AND status = 'filing'`).bind(id, err, t).run();
      const now = await env.DB.prepare(`SELECT ${WAVE_COLS} FROM roadmap_waves WHERE id = ?1`).bind(id).first(); // sql-ident-ok: WAVE_COLS is a module constant
      if (Number(res.meta.changes) !== 1) {
        const why = now && now.status === "filing" ? "not every slice has a link" : `wave is ${now ? now.status : "gone"}, not filing`;
        return json(409, { error: why, wave: now ? waveOut(now) : null });
      }
      return json(200, { wave: waveOut(now) });
    }),
  ],

  [
    "GET", "/api/roadmap/waves/issues",
    ({ env, url }) => d1Guarded("roadmap_waves", async () => {
      const q = url.searchParams;
      const id = WAVE_ID_RE.test(q.get("id") || "") ? q.get("id") : "";
      if (!id) return json(400, { error: "id must match ^[A-Za-z0-9._:-]{1,80}$", field: "id" });
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: "project must match ^[A-Za-z0-9._-]{1,64}$", field: "project" });
      await ensureRoadmapTables(env);
      const [wr, pr, lr] = await env.DB.batch([
        env.DB.prepare(WAVE_SQL).bind(id, project),
        env.DB.prepare("SELECT repo FROM projects WHERE project = ?1").bind(project),
        env.DB.prepare(ISSUES_LINKS_SQL).bind(id, project),
      ]);
      const w = (wr.results || [])[0];
      if (!w) return json(404, { error: "no such wave" });
      const repo = ((pr.results || [])[0] || {}).repo ?? null;
      const seen = new Set();
      const issues = [];
      for (const l of lr.results || []) {
        const k = `${l.repo}#${l.issue}`;
        if (seen.has(k)) continue;
        seen.add(k);
        issues.push({ repo: l.repo, issue: Number(l.issue), issue_state: l.issue_state ?? null, url: issueUrl(l.repo, l.issue) });
      }
      const o = waveOut(w);
      return json(200, {
        wave: { id: o.id, status: o.status, slice_count: o.slice_count, repo, error: o.error, approved_by: o.approved_by, approved_at: o.approved_at },
        issues,
      });
    }),
  ],

  [
    "GET", "/api/roadmap/links/stale",
    ({ env, url, t }) => d1Guarded("roadmap_links", async () => {
      const raw = url.searchParams.get("limit");
      if (raw !== null && (!/^\d+$/.test(raw) || Number(raw) < 1)) return json(400, { error: "limit must be an integer of 1 or more", field: "limit" });
      const byKey = await prep(env);
      const cap = intSetting(byKey, "roadmap.issue_sync_batch", 50, 1, 200);
      const n = raw === null ? cap : Math.min(Number(raw), cap);
      const cutoff = minutesBefore(t, intSetting(byKey, "roadmap.issue_sync_stale_min", 30, 1, 10080));
      const { results } = await env.DB.prepare(STALE_SQL).bind(cutoff, n).all();
      const seen = new Set();
      const links = [];
      for (const l of results || []) {
        const k = `${l.repo}#${l.issue}`;
        if (seen.has(k)) continue;
        seen.add(k);
        links.push({ repo: l.repo, issue: Number(l.issue), state_seen_at: l.state_seen_at ?? null });
      }
      return json(200, { links, as_of: t });
    }),
  ],

  [
    "PUT", "/api/roadmap/links/state",
    ({ env, t, body }) => d1Guarded("roadmap_links", async () => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return json(400, { error: "repo must be owner/name", field: "repo" });
      if (!isPosInt(b.issue)) return json(400, { error: "issue must be an integer of 1 or more", field: "issue" });
      const tried = b.tried === true && b.issue_state === undefined;
      if (b.tried !== undefined && !tried) return json(400, { error: "tried must be true and comes without issue_state", field: "tried" });
      if (!tried && !ISSUE_STATES.includes(b.issue_state)) return json(400, { error: `issue_state must be one of ${ISSUE_STATES.join("|")}`, field: "issue_state" });
      await ensureRoadmapTables(env);
      const res = tried
        ? await env.DB.prepare(TRIED_SQL).bind(b.repo, b.issue, t).run()
        : await env.DB.prepare(STATE_SQL).bind(b.repo, b.issue, b.issue_state, t).run();
      const updated = Number(res.meta.changes);
      if (updated < 1) return json(404, { error: "no link names this issue" });
      return json(200, { updated });
    }),
  ],
];

// ticket-status routes — BH-8973 (C0): the live status of a ticket, read from
// the hub's own rows at request time. The MCP tools ticket_status and
// stuck_tickets (mcp/tools/ticket-status.mjs) read these through /api/coord.
//
//   GET /api/ticket-status?project=<p>|repo=<owner/name>&key=<K>...&issue=<n>...
//   GET /api/ticket-status/stuck?project=<p>|repo=<owner/name>
//
// ANSWER (format `ticket-status v1`): {format, project, repo, fresh_at,
// tickets, unknown} and, on /stuck, {stuck_min, scanned, truncated} in place of
// `unknown`. fresh_at is this request's clock `t`, taken in the same
// invocation as the reads. Nothing is cached: every call reads D1.
//
// INPUT. `key` and `issue` repeat. A key is trimmed and upper-cased once; an
// issue is a whole number > 0 and resolves through build_queue.ticket_id. A
// repo resolves through `projects` (trimmed, any case): no row is 404
// unknown_repo, two rows are 409 ambiguous_repo (never pick one). More tickets
// than ticket_status.batch_max is 400 too_many, never a silent cut.
//
// THE READS. One loader serves both routes, and its cost does not grow with
// the number of tickets: round 1 is ONE env.DB.batch of the SQL.* statements
// below over json_each of every key; round 2 is ONE batch of at most 3
// statements that need round 1's answer (the newest job's heartbeat and last
// stage event, and the blockers' own queue rows). A D1 error fails the call
// through d1Guarded (503): a failed sub-read is never read as "not_known".
// test/ticket-status.bh-8973.test.js S8 EXPLAINs every SQL text at volume.
//
// THE STATE of a ticket is ticketState() below: the first rule that matches.
//
// D1 has no RLS. Both routes sit behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES), and every statement is bound to one project.

import { json, d1Guarded } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";

const FORMAT = "ticket-status v1";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const REPO_RE = /^[a-z0-9_.-]{1,100}\/[a-z0-9_.-]{1,100}$/;
const KEY_RE = /^[A-Z0-9._-]{1,64}$/;
const ISSUE_RE = /^[0-9]{1,12}$/;
// The code fallbacks of the settings rows of the same names
// (schema.d/202611110521-bh-8973-ticket-status.sql seeds all four).
const STUCK_MIN_DEFAULT = 90; // ticket_status.stuck_min
const BATCH_MAX_DEFAULT = 20; // ticket_status.batch_max
const ATTEMPTS_LIMIT_DEFAULT = 20; // ticket_status.attempts_limit
const STUCK_SCAN_DEFAULT = 200; // ticket_status.stuck_scan_limit
const SIBLING = { since: "after-since", released: "after-released" };
const HOLD_RELEASE = "the hold row is cleared (pool hold release)";

// Every keyed statement starts with this: the named keys plus the keys whose
// queue row carries a named issue (?1 project, ?2 keys JSON, ?3 issues JSON).
// CROSS JOIN fixes the join order: the short JSON list drives each index
// lookup, so no statement reads a whole project's rows.
const K = `WITH k(key) AS (SELECT value FROM json_each(?2)
  UNION SELECT build_queue.ticket_key FROM json_each(?3) AS i
    CROSS JOIN build_queue ON build_queue.project = ?1 AND build_queue.ticket_id = i.value)`;
const IN_K = "IN (SELECT key FROM k)";
const PR_COLS = "k.key AS ticket_key, number, state, head_ref, merged_at, review_decision, queue_state, url";
const PR_REPO = "pr_records.repo = (SELECT repo FROM projects WHERE project = ?1)";

export const SQL = {
  // Round 0 (repo given): the projects registry is one row per fleet project
  // (under 50 rows), so this reads it whole; no index is needed.
  repo: "SELECT project, repo FROM projects WHERE lower(trim(repo)) = ?1 LIMIT 2",
  // /stuck candidates: idx_build_queue_status (status, project, enqueued_at). ?1 project ?2 limit + 1
  candidates: "SELECT ticket_key FROM build_queue WHERE status IN ('queued', 'claimed') AND project = ?1 ORDER BY enqueued_at, ticket_key LIMIT ?2",
  // Round 1. ?1 project ?2 keys ?3 issues ?4 attempts_limit + 1
  // build_queue PK (project, ticket_key); the issue half of k uses idx_build_queue_project_ticket_id.
  queue: `${K} SELECT ticket_key, ticket_id, status, attempt, claimed_by, claimed_at, enqueued_at, finished_at, reason,
    updated_at, machine, phase, phase_at, phase_actor FROM build_queue WHERE project = ?1 AND ticket_key ${IN_K}`,
  // pool_holds PK (project, kind, ticket_key): the ticket holds, and the project's spawn hold.
  holds: `${K} SELECT kind, ticket_key, until_at, why, first_seen FROM pool_holds WHERE project = ?1 AND kind = 'ticket' AND ticket_key ${IN_K}
    UNION ALL SELECT kind, ticket_key, until_at, why, first_seen FROM pool_holds WHERE project = ?1 AND kind = 'spawn' AND ticket_key = ''`,
  // pool_markers PK (project, ticket_key, marker).
  markers: `${K} SELECT ticket_key, marker, value, updated_at FROM pool_markers
    WHERE project = ?1 AND ticket_key ${IN_K} AND marker IN ('after-since', 'after-released')`,
  // pool_spawns PK (project, ticket_key, ts, box): the newest spawn of each key.
  spawns: `${K} SELECT ticket_key, max(ts) AS ts, machine FROM pool_spawns WHERE project = ?1 AND ticket_key ${IN_K} GROUP BY ticket_key`,
  // pool_terminals PK (project, ticket_key).
  terminals: `${K} SELECT ticket_key, branch, reason, created_at, cleared_at FROM pool_terminals WHERE project = ?1 AND ticket_key ${IN_K}`,
  // idx_jobs_project_ticket_created: jobs.ticket_id is the build KEY. meta is
  // read only for result and branch, and only when it is valid JSON.
  jobs: `${K} SELECT id, ticket_key, kind, box, stage, status, created_at, updated_at, result, branch FROM (
      SELECT id, ticket_id AS ticket_key, kind, box, stage, status, created_at, updated_at,
        CASE WHEN json_valid(meta) THEN json_extract(meta, '$.result') END AS result,
        CASE WHEN json_valid(meta) THEN json_extract(meta, '$.branch') END AS branch,
        ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY created_at DESC, id DESC) AS rn
      FROM jobs WHERE project = ?1 AND ticket_id ${IN_K} AND kind IN ('build', 'fix'))
    WHERE rn <= ?4 ORDER BY ticket_key, rn`,
  // idx_ticket_events_project_ticket_id (project, ticket_key, id).
  events: `${K} SELECT ticket_key, from_phase, to_phase, actor, reason, pr, at FROM (
      SELECT ticket_key, from_phase, to_phase, actor, reason, pr, at,
        ROW_NUMBER() OVER (PARTITION BY ticket_key ORDER BY id DESC) AS rn
      FROM ticket_events WHERE project = ?1 AND ticket_key ${IN_K})
    WHERE rn <= ?4 ORDER BY ticket_key, rn`,
  // idx_ticket_edges_child (project, child): parent and child are issue numbers.
  edges: `${K}, c(id) AS (SELECT build_queue.ticket_id FROM k
        CROSS JOIN build_queue ON build_queue.project = ?1 AND build_queue.ticket_key = k.key
        WHERE build_queue.ticket_id IS NOT NULL
      UNION SELECT value FROM json_each(?3))
    SELECT parent, child FROM c CROSS JOIN ticket_edges ON ticket_edges.project = ?1 AND ticket_edges.child = c.id`,
  // idx_pr_records_repo_head (repo, head_ref): the branch ticket/<key>, or a
  // re-plan branch ticket/<key>-<x>. '.' is the code point after '-', so
  // ticket/bh-8973 never reads ticket/bh-89731 or ticket/bh-8973x.
  prs: `${K} SELECT ${PR_COLS} FROM k CROSS JOIN pr_records ON ${PR_REPO} AND pr_records.head_ref = 'ticket/' || lower(k.key)
    UNION ALL SELECT ${PR_COLS} FROM k CROSS JOIN pr_records ON ${PR_REPO}
      AND pr_records.head_ref >= 'ticket/' || lower(k.key) || '-' AND pr_records.head_ref < 'ticket/' || lower(k.key) || '.'`,
  // ledgers PK (kind, key): the newest br_attempt row of each key, in the same
  // key range as routes/br-attempts.js ('$' is the code point after '#').
  // The resolver writes bra_key(<p>, br_cap_key(<p>, rkey, <KEY>)), and
  // br_cap_key is br_rkey("<p>-<KEY>"), so the row key is <p>/<p>-<KEY>#...
  // br_rkey maps [^A-Za-z0-9._-] to '-'; PROJECT_RE and KEY_RE admit only that
  // set, so br_rkey is the identity here and the plain concatenation is exact.
  br: `${K} SELECT ticket_key, status, updated_at FROM (
      SELECT k.key AS ticket_key, ledgers.status, ledgers.updated_at,
        ROW_NUMBER() OVER (PARTITION BY k.key ORDER BY ledgers.key DESC) AS rn
      FROM k CROSS JOIN ledgers ON ledgers.kind = 'br_attempt'
        AND ledgers.key >= ?1 || '/' || ?1 || '-' || k.key || '#'
        AND ledgers.key < ?1 || '/' || ?1 || '-' || k.key || '$')
    WHERE rn = 1`,
  // projects PK (project): the repo of a call that named a project.
  project: "SELECT project, repo FROM projects WHERE project = ?1",
  // Round 2. ?1 job ids JSON: job_heartbeats PK (job_id).
  beats: "SELECT job_id, beat_at FROM job_heartbeats WHERE job_id IN (SELECT value FROM json_each(?1))",
  // idx_events_job (job_id).
  stages: "SELECT job_id, max(created_at) AS at FROM stage_events WHERE job_id IN (SELECT value FROM json_each(?1)) GROUP BY job_id",
  // The blockers' own rows: PK by key, idx_build_queue_project_ticket_id by issue. ?1 project ?2 keys ?3 issues
  blockers: `SELECT ticket_key, ticket_id, status, phase FROM build_queue WHERE project = ?1 AND ticket_key IN (SELECT value FROM json_each(?2))
    UNION ALL SELECT ticket_key, ticket_id, status, phase FROM build_queue WHERE project = ?1 AND ticket_id IN (SELECT value FROM json_each(?3))`,
};
const ROUND1 = ["queue", "holds", "markers", "spawns", "terminals", "jobs", "events", "edges", "prs", "br"];

const bad = (error, extra = {}) => json(400, { error, ...extra });
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const msOf = (s) => (typeof s === "string" && s ? Date.parse(s) : NaN);
const epochIso = (n) => (Number.isFinite(Number(n)) && n !== null && n !== "" ? iso(Number(n) * 1000) : null);
const rowsOf = (res) => (res && res.results) || [];
const groupBy = (rows, col = "ticket_key") => {
  const m = new Map();
  for (const r of rows) { if (!m.has(r[col])) m.set(r[col], []); m.get(r[col]).push(r); }
  return m;
};

// The newest of some ISO strings, as ISO; null when none parses.
function newest(...vals) {
  let best = NaN;
  for (const v of vals) { const n = msOf(v); if (Number.isFinite(n) && !(n <= best)) best = n; }
  return Number.isFinite(best) ? iso(best) : null;
}

// A settings row that is a whole number >= min, else null (never clamped).
function wholeRow(byKey, key, min) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && n >= min ? n : null;
}
function knobs(byKey) {
  return {
    stuckMin: wholeRow(byKey, "ticket_status.stuck_min", 0) ?? STUCK_MIN_DEFAULT,
    batchMax: wholeRow(byKey, "ticket_status.batch_max", 1) ?? BATCH_MAX_DEFAULT,
    limit: wholeRow(byKey, "ticket_status.attempts_limit", 1) ?? ATTEMPTS_LIMIT_DEFAULT,
    scan: wholeRow(byKey, "ticket_status.stuck_scan_limit", 1) ?? STUCK_SCAN_DEFAULT,
  };
}

// A blocker's state from its own queue row: its lifecycle phase, else the
// queue status; no row is not_known.
const rowState = (r) => (r ? r.phase || r.status : "not_known");
const issueOf = (id) => (typeof id === "string" && ISSUE_RE.test(id) ? Number(id) : null);
const isMerged = (p) => Boolean(p.merged_at) || p.state === "merged";

// The PR a ticket reads: a merged one, else the newest open one, else the newest.
function pickPr(prs) {
  const by = (f) => prs.filter(f).sort((a, b) => b.number - a.number)[0];
  return by(isMerged) || by((p) => p.state === "open") || by(() => true) || null;
}

// The sibling hold of a queued row: fly-pool.sh pool_after_gate writes
// after-since "<blocker>\t<epoch>" on the first held tick, and on release
// clears it and writes after-released (a 24 h counter it keeps). So a hold is
// live while after-since exists and no after-released is newer than it.
function siblingHold(markers) {
  const since = markers.find((m) => m.marker === SIBLING.since);
  if (!since) return null;
  const rel = markers.find((m) => m.marker === SIBLING.released);
  if (rel && msOf(rel.updated_at) >= msOf(since.updated_at)) return null;
  const [blocker, epoch] = String(since.value ?? "").split("\t");
  return { blocker: blocker || null, since: (/^\d+$/.test(epoch ?? "") ? epochIso(epoch) : null) ?? since.updated_at };
}

// The pure state of one ticket. `r` holds its round 1 and 2 rows; the first
// rule that matches wins:
//   merged      a PR with merged_at (or state merged), or phase merged
//   abandoned   phase abandoned, or a pool_terminals row not cleared
//   running     the newest build/fix job is running (stage: the job's, or
//               fix-and-recheck for a fix job)
//   in_resolver the newest br_attempt row is newer than the newest job's end
//               (rung: that row's status, the resolver's action)
//   spawning    the queue row is claimed and no job runs yet
//   held        the queue row is queued under a ticket hold, a live sibling
//               hold or a project spawn hold whose until_at is in the future
//   queued      the queue row is queued
//   pr_open     an open PR
//   not_known   no queue row and no job
//   stopped     anything else: the row is done or failed with no open PR
//               (the last outcome is in attempts)
export function ticketState(r, nowMs) {
  const q = r.queue || null;
  const jobs = r.jobs || [];
  const job = jobs[0] || null;
  const limit = r.limit;
  const pr = pickPr(r.prs || []);
  const markers = r.markers || [];
  const spawnedAt = r.spawn ? epochIso(r.spawn.ts) : null;
  const term = r.terminal && !r.terminal.cleared_at ? r.terminal : null;
  const queued = q && q.status === "queued";
  const sib = queued ? siblingHold(markers) : null;
  const tHold = queued && r.hold ? r.hold : null;
  const sHold = queued && r.spawnHold && Number(r.spawnHold.until_at) * 1000 > nowMs ? r.spawnHold : null;
  const blockers = r.blockers || { byKey: new Map(), byIssue: new Map() };

  let state; let stage = null; let rung = null;
  if ((pr && isMerged(pr)) || (q && q.phase === "merged")) state = "merged";
  else if ((q && q.phase === "abandoned") || term) state = "abandoned";
  else if (job && job.status === "running") {
    state = "running";
    stage = job.kind === "fix" ? "fix-and-recheck" : job.stage;
  } else if (r.br && (!job || msOf(r.br.updated_at) > msOf(job.updated_at))) {
    state = "in_resolver";
    rung = r.br.status;
  } else if (q && q.status === "claimed") state = "spawning";
  else if (tHold || sib || sHold) state = "held";
  else if (queued) state = "queued";
  else if (pr && pr.state === "open") state = "pr_open";
  else if (!q && !job) state = "not_known";
  else state = "stopped";

  let hold = null;
  if (state === "held") {
    if (tHold) hold = { reason: "ticket_hold", releases: HOLD_RELEASE };
    else if (sib) hold = { reason: "sibling_hold", releases: `${sib.blocker} is done or merged, or the pool releases the wait` };
    else hold = { reason: "spawn_hold", releases: `the project spawn hold ends at ${epochIso(sHold.until_at)}` };
  }

  const waits = [];
  if (state !== "merged" && state !== "abandoned") {
    for (const e of r.edges || []) {
      const row = blockers.byIssue.get(e.parent);
      waits.push({ kind: "blocker", ticket: e.parent, key: row ? row.ticket_key : null, state: rowState(row) });
    }
    if (sib) waits.push({ kind: "sibling_hold", ticket: sib.blocker, since: sib.since, state: rowState(blockers.byKey.get(sib.blocker)) });
    if (tHold) waits.push({ kind: "ticket_hold", why: tHold.why ?? null, since: tHold.first_seen ?? null, releases: HOLD_RELEASE });
    if (sHold) waits.push({ kind: "spawn_hold", why: sHold.why ?? null, until: epochIso(sHold.until_at) });
    if (pr && pr.state === "open") {
      waits.push({ kind: "lead_verdict", state: pr.review_decision ?? null });
      if (pr.queue_state) waits.push({ kind: "merge_queue", state: pr.queue_state });
    }
    if (state === "running" && job.kind === "fix") waits.push({ kind: "fix_round", state: job.stage });
  }

  const checkpoint = job ? newest(job.updated_at, r.beat, r.stageAt) : null;
  const events = r.events || [];
  return {
    key: r.key,
    issue: q ? issueOf(q.ticket_id) : null,
    state, stage, rung,
    machine: (q && q.machine) || (r.spawn && r.spawn.machine) || null,
    spawned_at: spawnedAt ?? (q ? q.claimed_at ?? null : null),
    claimed_at: q ? q.claimed_at ?? null : null,
    branch: (pr && pr.head_ref) || (job && typeof job.branch === "string" && job.branch) || (r.terminal && r.terminal.branch) || null,
    pr: pr ? { number: pr.number, state: pr.state ?? null, merged_at: pr.merged_at ?? null, url: pr.url ?? null } : null,
    last_checkpoint_at: checkpoint,
    last_activity_at: newest(q && q.updated_at, q && q.phase_at, job && job.updated_at, r.beat, r.stageAt, spawnedAt,
      ...markers.map((m) => m.updated_at)),
    attempts: jobs.slice(0, limit).map((j) => ({
      job_id: j.id, kind: j.kind, started_at: j.created_at, ended_at: j.status === "running" ? null : j.updated_at,
      status: j.status, stage: j.stage, machine: j.box ?? null,
      outcome: typeof j.result === "string" && j.result.trim() ? j.result.trim().split(/\s+/)[0] : null,
    })),
    events: events.slice(0, limit).map((e) => ({ from: e.from_phase, to: e.to_phase, actor: e.actor, reason: e.reason, pr: e.pr, at: e.at })),
    waits_on: waits,
    hold,
    truncated: { attempts: jobs.length > limit, events: events.length > limit },
  };
}

// Every table the loader reads exists, and build_queue / pr_records carry
// their added columns and indexes. All cached per isolate: 0 statements warm.
async function ensureAll(env) {
  await Promise.all(["pool_holds", "pool_markers", "pool_spawns", "pool_terminals", "ticket_events", "ticket_edges", "pr_records"]
    .map((tbl) => ensureTable(env, tbl)));
  await Promise.all([ensureColumns(env, "build_queue"), ensureColumns(env, "pr_records")]);
}

// The tickets of `keys` (normalized) and of `issues` (digit strings), in
// request order. -> {tickets, unknown, repo}
export async function loadTickets(env, project, repo, keys, issues, k, nowMs) {
  const kj = JSON.stringify(keys);
  const ij = JSON.stringify(issues);
  const names = repo === undefined ? [...ROUND1, "project"] : ROUND1;
  const res = await env.DB.batch(names.map((n) => {
    const s = env.DB.prepare(SQL[n]);
    return n === "project" ? s.bind(project) : n === "jobs" || n === "events" ? s.bind(project, kj, ij, k.limit + 1) : s.bind(project, kj, ij);
  }));
  const got = Object.fromEntries(names.map((n, i) => [n, rowsOf(res[i])]));
  const repoName = repo === undefined ? (got.project[0] ? got.project[0].repo : null) : repo;
  const queue = new Map(got.queue.map((r) => [r.ticket_key, r]));
  const jobs = groupBy(got.jobs);

  // The ticket list: the named keys, then the keys an issue resolved to.
  const order = [...keys];
  const unknown = [];
  for (const i of issues) {
    const hits = got.queue.filter((r) => r.ticket_id === i).map((r) => r.ticket_key).sort();
    if (!hits.length) unknown.push({ issue: Number(i) });
    for (const h of hits) if (!order.includes(h)) order.push(h);
  }

  // Round 2: what needs round 1's answer.
  const newestJobs = order.map((key) => (jobs.get(key) || [])[0]).filter(Boolean).map((j) => j.id);
  const blockerKeys = [...new Set(got.markers.filter((m) => m.marker === SIBLING.since)
    .map((m) => String(m.value ?? "").split("\t")[0]).filter(Boolean))];
  const blockerIssues = [...new Set(got.edges.map((e) => e.parent))];
  const r2 = [];
  if (newestJobs.length) {
    r2.push(["beats", env.DB.prepare(SQL.beats).bind(JSON.stringify(newestJobs))]);
    r2.push(["stages", env.DB.prepare(SQL.stages).bind(JSON.stringify(newestJobs))]);
  }
  if (blockerKeys.length || blockerIssues.length) {
    r2.push(["blockers", env.DB.prepare(SQL.blockers).bind(project, JSON.stringify(blockerKeys), JSON.stringify(blockerIssues))]);
  }
  const res2 = r2.length ? await env.DB.batch(r2.map((x) => x[1])) : [];
  const got2 = Object.fromEntries(r2.map((x, i) => [x[0], rowsOf(res2[i])]));
  const beats = new Map((got2.beats || []).map((b) => [b.job_id, b.beat_at]));
  const stages = new Map((got2.stages || []).map((s) => [s.job_id, s.at]));
  const blockers = {
    byKey: new Map((got2.blockers || []).map((b) => [b.ticket_key, b])),
    byIssue: new Map((got2.blockers || []).filter((b) => b.ticket_id !== null).map((b) => [b.ticket_id, b])),
  };

  const holds = new Map(got.holds.filter((h) => h.kind === "ticket").map((h) => [h.ticket_key, h]));
  const spawnHold = got.holds.find((h) => h.kind === "spawn") || null;
  const markers = groupBy(got.markers);
  const spawns = new Map(got.spawns.map((s) => [s.ticket_key, s]));
  const terms = new Map(got.terminals.map((s) => [s.ticket_key, s]));
  const events = groupBy(got.events);
  const prs = groupBy(got.prs);
  const br = new Map(got.br.map((b) => [b.ticket_key, b]));
  const edges = groupBy(got.edges, "child");

  const tickets = order.map((key) => {
    const q = queue.get(key) || null;
    const js = jobs.get(key) || [];
    const top = js[0];
    return ticketState({
      key, queue: q, jobs: js, limit: k.limit, prs: prs.get(key) || [], markers: markers.get(key) || [],
      spawn: spawns.get(key) || null, terminal: terms.get(key) || null, hold: holds.get(key) || null, spawnHold,
      br: br.get(key) || null, events: events.get(key) || [],
      edges: q && q.ticket_id !== null ? edges.get(q.ticket_id) || [] : [],
      beat: top ? beats.get(top.id) ?? null : null, stageAt: top ? stages.get(top.id) ?? null : null, blockers,
    }, nowMs);
  });
  return { tickets, unknown, repo: repoName };
}

// project= or repo= (exactly one) -> {project, repo} | a Response.
async function scope(env, url) {
  const p = url.searchParams.get("project");
  const rawRepo = url.searchParams.get("repo");
  if ((p === null) === (rawRepo === null)) return bad("project");
  if (p !== null) return PROJECT_RE.test(p) ? { project: p, repo: undefined } : bad("project");
  const repo = rawRepo.trim().toLowerCase();
  if (!REPO_RE.test(repo)) return bad("repo");
  const { results } = await env.DB.prepare(SQL.repo).bind(repo).all();
  const rows = results || [];
  if (rows.length === 0) return json(404, { error: "unknown_repo", repo: rawRepo.trim() });
  if (rows.length > 1) return json(409, { error: "ambiguous_repo", repo: rawRepo.trim(), projects: rows.map((r) => r.project).sort() });
  return { project: rows[0].project, repo: rows[0].repo };
}

export const routes = [
  // ── GET /api/ticket-status — the live status of named tickets ─────────────
  [
    "GET", "/api/ticket-status",
    async ({ env, t, url }) => {
      const keys = [];
      for (const raw of url.searchParams.getAll("key")) {
        const key = raw.trim().toUpperCase();
        if (!KEY_RE.test(key)) return bad("key");
        if (!keys.includes(key)) keys.push(key);
      }
      const issues = [];
      for (const raw of url.searchParams.getAll("issue")) {
        const v = raw.trim();
        if (!ISSUE_RE.test(v) || Number(v) < 1) return bad("issue");
        const n = String(Number(v));
        if (!issues.includes(n)) issues.push(n);
      }
      return d1Guarded("build_queue", async () => {
        const sc = await scope(env, url);
        if (sc instanceof Response) return sc;
        if (keys.length + issues.length === 0) return bad("ticket");
        const [{ byKey }] = await Promise.all([settingsRows(env), ensureAll(env)]);
        const k = knobs(byKey);
        if (keys.length + issues.length > k.batchMax) return bad("too_many", { max: k.batchMax });
        const out = await loadTickets(env, sc.project, sc.repo, keys, issues, k, Date.parse(t));
        return json(200, { format: FORMAT, project: sc.project, repo: out.repo, fresh_at: t, tickets: out.tickets, unknown: out.unknown });
      });
    },
  ],

  // ── GET /api/ticket-status/stuck — open rows with no activity past the knob ─
  [
    "GET", "/api/ticket-status/stuck",
    async ({ env, t, url }) => d1Guarded("build_queue", async () => {
      const sc = await scope(env, url);
      if (sc instanceof Response) return sc;
      const [{ byKey }] = await Promise.all([settingsRows(env), ensureAll(env)]);
      const k = knobs(byKey);
      const { results } = await env.DB.prepare(SQL.candidates).bind(sc.project, k.scan + 1).all();
      const cand = (results || []).map((r) => r.ticket_key);
      const keys = cand.slice(0, k.scan);
      const nowMs = Date.parse(t);
      const cutoff = nowMs - k.stuckMin * 60000;
      const out = keys.length ? await loadTickets(env, sc.project, sc.repo, keys, [], k, nowMs) : { tickets: [], repo: sc.repo ?? null };
      const tickets = out.tickets
        .filter((x) => x.last_activity_at !== null && Date.parse(x.last_activity_at) < cutoff)
        .sort((a, b) => Date.parse(a.last_activity_at) - Date.parse(b.last_activity_at) || (a.key < b.key ? -1 : 1));
      return json(200, {
        format: FORMAT, project: sc.project, repo: out.repo ?? null, fresh_at: t, stuck_min: k.stuckMin,
        scanned: keys.length, truncated: cand.length > k.scan, tickets,
      });
    }),
  ],
];

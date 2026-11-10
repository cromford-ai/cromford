// The pure logic behind NOW, HISTORY and NEEDS — the three old-cockpit views.
// It lives here rather than in the screens because these are exactly the rules
// that would regress silently: a non-zero exit that stops reading as a failure,
// a tick summary parsed into confident zeros, a parked build that quietly stops
// counting as something waiting on a person.

import { jobState, ORPHAN_AFTER_S } from './jobs.js';
import { stageLabel, verdictLabel } from './stages.js';
import { tierLabel } from './labels.js';

// ---------------------------------------------------------------- runs

// rc is the harness's own exit code. 0 is a clean tick. 1 is the script
// failing. 126/127/130/137/143 are the shell's and the kernel's codes for
// "never ran" and "killed", which is a different story from "ran and failed" —
// an OOM kill or a timeout is an infrastructure problem, not a triage problem.
const KILLED_CODES = new Set([126, 127, 130, 137, 143]);

export function runOutcome(run) {
  if (!run) return 'unknown';
  const rc = run.rc;
  if (rc === null || rc === undefined || rc === '') return 'unknown';
  const n = Number(rc);
  if (!Number.isFinite(n)) return 'unknown';
  if (n === 0) return 'ok';
  return KILLED_CODES.has(n) ? 'killed' : 'failed';
}

export const OUTCOME_LABEL = { ok: 'OK', failed: 'FAILED', killed: 'KILLED', unknown: 'UNKNOWN' };
// The exit code in words: `rc=1` means nothing to someone who has not read the
// shell's manual.
export function rcLabel(rc) {
  const o = runOutcome({ rc });
  if (o === 'unknown') return 'no exit code';
  return `exit code ${Number(rc)} · ${OUTCOME_LABEL[o].toLowerCase()}`;
}

export const OUTCOME_TONE = { ok: 'green', failed: 'dead', killed: 'warn', unknown: 'muted' };

// Sorting an outcome column: worst first when ascending, so the thing worth
// looking at is one click away rather than at the bottom of 8,000 rows.
const OUTCOME_RANK = { failed: 0, killed: 1, unknown: 2, ok: 3 };
export const outcomeRank = (run) => OUTCOME_RANK[runOutcome(run)] ?? 9;

export function runDurationSeconds(run) {
  if (!run || !run.started_at || !run.finished_at) return null;
  const a = Date.parse(run.started_at);
  const b = Date.parse(run.finished_at);
  if (Number.isNaN(a) || Number.isNaN(b)) return null;
  const s = Math.round((b - a) / 1000);
  // A finish before its start is a clock artifact, not a negative duration.
  return s < 0 ? null : s;
}

// A triage tick beats a structured summary line, e.g.
//   tickets=1 new=0 triaged=0 buildable=0 built=0 commented=0 \
//     [gate=board-changed scope=1 model=<model id> cost=$metered]
// Some lanes beat prose instead ("No open `ai-build` issues this tick…"), and
// the field set drifts per project (project-2 beats `actionable`, the others
// beat `triaged`). So this parses what is THERE and reports the rest as absent:
// a counter nobody beat is null, never 0, or the row claims a project triaged
// nothing when in truth it never said.
export function parseTickSummary(summary) {
  const out = { counters: {}, meta: {}, prose: null };
  if (!summary || typeof summary !== 'string') return out;
  const text = summary.trim();
  if (!text) return out;

  const bracket = text.match(/\[([^\]]*)\]\s*$/);
  const body = bracket ? text.slice(0, bracket.index).trim() : text;
  // Trailing punctuation is real in this data — one lane beats
  // "commented=0`" — so a value keeps only what it is, or `0`` sorts as a
  // string and the counter silently stops being a number.
  const pairs = (s) => {
    const m = {};
    for (const [, k, v] of s.matchAll(/([a-z_]+)=([^\s\]]+)/g)) m[k] = v.replace(/[`,.;:]+$/, '');
    return m;
  };
  const counters = pairs(body);
  for (const [k, v] of Object.entries(counters)) {
    out.counters[k] = /^-?\d+$/.test(v) ? Number(v) : v;
  }
  if (bracket) out.meta = pairs(bracket[1]);
  // Anything that carried no `k=v` at all was prose the lane wrote for a human.
  if (!Object.keys(out.counters).length) out.prose = body;
  return out;
}

// The one number a fleet row leads with: how much the tick actually moved.
// Absent counters stay absent — `null` renders as "—", never as a confident 0.
export function tickWork(summary) {
  const { counters } = parseTickSummary(summary);
  const pick = (...keys) => {
    for (const k of keys) if (typeof counters[k] === 'number') return counters[k];
    return null;
  };
  return {
    tickets: pick('tickets'),
    fresh: pick('new'),
    // project-2's lane calls it `actionable`; everyone else calls it `triaged`.
    triaged: pick('triaged', 'actionable'),
    built: pick('built'),
    commented: pick('commented')
  };
}

// ---------------------------------------------------------------- boards

// "87% used, 28G free" -> 87. The string is beaten by the box, so anything that
// does not look like a percentage is unknown rather than 0.
export function diskPercent(disk) {
  if (!disk || typeof disk !== 'string') return null;
  const m = disk.match(/(\d+(?:\.\d+)?)\s*%/);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) ? n : null;
}

// A box at 90% is minutes from a build that cannot check out a repo, so the
// threshold sits below where it hurts rather than at it.
export const diskTone = (pct) =>
  pct === null || pct === undefined ? 'muted' : pct >= 90 ? 'dead' : pct >= 80 ? 'warn' : 'ok';

// ---------------------------------------------------------------- needs

// Four different questions arrive as four lists; this is the one place that
// decides what each row IS, how loud it is, and where clicking it goes. Every
// row gets a destination — a needs list whose rows dead-end is a to-do list you
// cannot action.
export const NEED_KINDS = ['alert', 'command', 'build', 'stale', 'proposal'];

const SEV_RANK = { high: 0, medium: 1, low: 2 };
export const needSeverityRank = (row) => SEV_RANK[row && row.severity] ?? 9;

const projectPath = (p) => (p ? `/p/${encodeURIComponent(p)}` : null);

// The PR number is parsed from a beat-written URL elsewhere (format.js); here
// only the internal destination is chosen, so an absent pr_url falls back to
// the build drill rather than producing a link that goes nowhere.
export function needRows(payload, stale = []) {
  if (!payload) return [];
  const rows = [];

  for (const a of payload.alerts || []) {
    rows.push({
      kind: 'alert',
      id: `alert:${a.id}`,
      severity: 'high',
      project: a.project || null,
      title: a.line || a.akey || `alert #${a.id}`,
      detail: a.akey || '',
      ts: a.ts || null,
      // Resolving is an action, and the action lives on the ALERTS screen.
      to: '/alerts',
      action: 'RESOLVE'
    });
  }

  for (const c of payload.commands || []) {
    rows.push({
      kind: 'command',
      id: `command:${c.id}`,
      // A dead-letter is out of retries; a `failed` may still be retried.
      severity: c.status === 'dead_letter' ? 'high' : 'medium',
      project: c.project || null,
      title: `${c.type || 'command'} ${c.status === 'dead_letter' ? 'gave up' : 'failed'} — ${c.result || 'no reason beaten'}`,
      detail: c.ckey || '',
      ts: c.updated_at || c.created_at || null,
      to: projectPath(c.project),
      action: c.project ? 'RE-RUN FROM PROJECT' : null
    });
  }

  for (const b of payload.builds || []) {
    const parked = b.stage !== 'pr_created';
    rows.push({
      kind: 'build',
      id: `build:${b.id}`,
      // BH-4991: the key on its own, so the screen links it to /t/<KEY>.
      ticket: b.ticket_key || null,
      // A stopped plan needs a decision; a PR waiting on a merge needs a click.
      severity: parked ? 'high' : 'medium',
      project: b.project || null,
      title: parked
        ? `${b.ticket_key || b.bkey} stopped at ${stageLabel(b.stage)}`
        : `${b.ticket_key || b.bkey} has a PR nobody has merged`,
      detail: `${tierLabel(b.tier)}${b.verdict ? ` · ${verdictLabel(b.verdict)}` : ''}`,
      ts: b.updated_at || null,
      to: `/builds/${b.id}`,
      prUrl: b.pr_url || null,
      action: 'OPEN BUILD'
    });
  }

  // A build row the jobs ledger has no running job for (staleBuilds below). The
  // hub never closes these rows, so this is where they are seen, not BUILDING NOW.
  for (const b of stale || []) {
    rows.push({
      kind: 'stale',
      id: `stale:${b.id}`,
      ticket: b.ticket_key || null,
      severity: 'medium',
      project: b.project || null,
      title: `${b.ticket_key || b.bkey} looks stale: last moved ${stageLabel(b.stage)} and no build job is running`,
      detail: tierLabel(b.tier),
      ts: b.updated_at || null,
      to: `/builds/${b.id}`,
      prUrl: b.pr_url || null,
      action: 'OPEN BUILD'
    });
  }

  for (const p of payload.proposals || []) {
    rows.push({
      kind: 'proposal',
      id: `proposal:${p.pkey}`,
      // The gate is a decision waiting on the operator, but nothing is broken while it
      // waits — it is the quietest thing on this screen.
      severity: 'low',
      project: p.project || null,
      title: p.title || p.slug,
      detail: p.score === null || p.score === undefined ? '' : `score ${p.score}`,
      ts: p.updated_at || null,
      to: `/ideas/${encodeURIComponent(p.project)}/${encodeURIComponent(p.slug)}`,
      action: 'DECIDE'
    });
  }

  // A row with no ticket says so (null), never undefined.
  return rows.map((r) => ('ticket' in r ? r : { ...r, ticket: null }));
}

export function summariseNeeds(payload, stale = []) {
  const rows = needRows(payload, stale);
  const byKind = {};
  const byProject = {};
  let high = 0;
  for (const r of rows) {
    byKind[r.kind] = (byKind[r.kind] || 0) + 1;
    const key = r.project || 'fleet';
    byProject[key] = (byProject[key] || 0) + 1;
    if (r.severity === 'high') high++;
  }
  return { total: rows.length, high, byKind, byProject };
}

// NEEDS A HUMAN on NOW, split by kind, each part a link to the list that shows
// exactly those rows. `needs` is the /now payload's server counts; staleCount
// is the client's stale builds (staleBuilds().length), or null while the jobs
// read is unknown. A part whose read is unknown is null (rendered as a dash),
// never an invented 0. The total keeps the rule NOW always had: server total
// plus the stale builds the client can see, so an unread jobs read adds none.
export function needsSplit(needs, staleCount) {
  const known = !!needs && needs.total !== null && needs.total !== undefined;
  const num = (v) => (known && v !== null && v !== undefined && Number.isFinite(Number(v)) ? Number(v) : null);
  const stale = staleCount === null || staleCount === undefined ? null : Number(staleCount);
  const parts = [
    { key: 'alerts', label: 'open alerts', value: num(needs && needs.alerts), to: '/alerts' },
    { key: 'builds', label: 'parked builds', value: num(needs && needs.builds), to: '/needs?kind=build' },
    { key: 'stale', label: 'stale builds', value: stale, to: '/needs?kind=stale' },
    { key: 'commands', label: 'failed commands', value: num(needs && needs.commands), to: '/needs?kind=command' },
    { key: 'proposals', label: 'ideas at the gate', value: num(needs && needs.proposals), to: '/ideas?status=gate_pending' }
  ];
  const total = known ? Number(needs.total) + (stale || 0) : null;
  return { parts, total };
}

export const NEED_LABEL = {
  alert: 'ALERT',
  command: 'COMMAND',
  build: 'BUILD',
  stale: 'STALE BUILD',
  proposal: 'IDEA GATE'
};

// ---------------------------------------------------------------- building now

// What is building is decided by the jobs ledger (GET /api/coord/jobs), never
// by console `builds` rows: those are not closed when a build is abandoned,
// parked, superseded or restarted, so on 2026-09-29 they said 60 while 11 jobs
// were running. A build is a running build/fix job with a sign of life inside
// the watchdog's ORPHAN_AFTER_S. The worker caps a list read at 500 rows.
const BUILD_KINDS = new Set(['build', 'fix']);
export const JOBS_READ_CAP = 500;
const ticketKey = (project, t) => `${project || ''}|${String(t || '').trim().toUpperCase()}`;
const jobKey = (j) => (String(j.ticket_id || '').trim() ? ticketKey(j.project, j.ticket_id) : `id:${j.id}`);
const newer = (a, b, field) => (Date.parse(a[field]) || 0) > (Date.parse(b[field]) || 0);

// null when the jobs read failed or has not arrived: nothing is counted then.
export function liveBuildJobs(jobsPayload) {
  if (!jobsPayload) return null;
  const jobs = jobsPayload.jobs || [];
  const live = new Map();
  let quiet = 0;
  let otherRunning = 0;
  for (const j of jobs) {
    if (String(j.status || '').toLowerCase() !== 'running') continue;
    if (!BUILD_KINDS.has(j.kind)) { otherRunning++; continue; }
    if (jobState(j) !== 'running') { quiet++; continue; }
    // One row per ticket: a restart leaves two job rows, the newer is the build.
    const k = jobKey(j);
    const seen = live.get(k);
    if (!seen || newer(j, seen, 'created_at')) live.set(k, j);
  }
  return { live: [...live.entries()], quiet, otherRunning, capped: jobs.length >= JOBS_READ_CAP };
}

// Newest builds row per ticket key, for joining tier/verdict/PR onto a job.
function newestBuildByKey(builds) {
  const by = new Map();
  for (const b of builds || []) {
    const k = ticketKey(b.project, b.ticket_key || b.bkey);
    const seen = by.get(k);
    if (!seen || newer(b, seen, 'updated_at')) by.set(k, b);
  }
  return by;
}

export function buildingNow(jobsPayload, builds) {
  const lj = liveBuildJobs(jobsPayload);
  if (!lj) return null;
  const by = newestBuildByKey(builds);
  const rows = lj.live.map(([key, j]) => {
    const b = by.get(key) || null;
    return {
      ...j,
      key,
      ticket: (b && b.ticket_key) || String(j.ticket_id || '').trim().toUpperCase() || null,
      build_id: b ? b.id : null,
      tier: b ? b.tier : null,
      verdict: b ? b.verdict : null,
      pr_url: b ? b.pr_url : null,
      build_stage: b ? b.stage : null
    };
  });
  return { rows, count: rows.length, capped: lj.capped, quiet: lj.quiet, otherRunning: lj.otherRunning };
}

// Unfinished build rows with no running build job (live or quiet: a quiet job
// is the JOBS screen's problem) that have not moved for ORPHAN_AFTER_S. A row
// beaten a minute ago may not have opened its job yet, so it is neither. With
// no jobs read, nothing is stale: blaming 70 rows on a down jobs worker is the
// same wrong number the other way round.
export function staleBuilds(builds, jobsPayload, nowMs = Date.now()) {
  if (!jobsPayload) return [];
  const hasJob = new Set();
  for (const j of jobsPayload.jobs || []) {
    if (String(j.status || '').toLowerCase() === 'running' && BUILD_KINDS.has(j.kind)) hasJob.add(jobKey(j));
  }
  const stale = [];
  for (const [k, b] of newestBuildByKey(builds)) {
    if (hasJob.has(k)) continue;
    const t = Date.parse(b.updated_at);
    if (!Number.isNaN(t) && nowMs - t < ORPHAN_AFTER_S * 1000) continue;
    stale.push(b);
  }
  return stale;
}

// ---------------------------------------------------------------- shared

// The distinct values of a field, for a filter row. Sorted, blanks dropped —
// a filter chip for "" is a chip that filters to nothing.
export function facet(rows, key) {
  const seen = new Set();
  for (const r of rows || []) {
    const v = r && r[key];
    if (v !== null && v !== undefined && v !== '') seen.add(String(v));
  }
  return [...seen].sort();
}

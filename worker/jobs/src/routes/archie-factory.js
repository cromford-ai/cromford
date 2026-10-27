// archie-factory routes — BH-4588 (BH-4574.6): Archie's daily factory report.
//
// GET /api/archie/factory-report?day=YYYY-MM-DD[&project=][&limit=] answers one
// UTC day in one request: the mode, merges per project, queue health, stuck
// items and how they were cleared, tickets filed and shipped, spend vs caps,
// the one thing the operator should know, and that day's archie_actions rows. Two
// readers: bin/archie-fm-report.sh renders it as the daily Telegram text
// (bin/lib/archie-fm-report/render.sh), and the console Factory screen
// (console-ui/src/screens/Factory.js) shows it.
//
// Every section carries ok. A section with nothing in it carries empty_reason.
// A section whose read failed is {ok:false, error} and never a 0 in another
// section, and the answer is still a 200 (D12): only a junk param is a 400.
//
// READS. One settings read first (the mode, the caps and the two list caps
// the other reads bind), then the six data reads in ONE Promise.all: projects,
// the archie_actions aggregate and rows of the day (idx_archie_actions_day),
// the merges (idx_ledgers_kind_status_created, then idx_artifacts_ref and the
// jobs PK; LEFT JOINs keep the ledger as the outer loop, no per-row subquery),
// spend (idx_cost_rows_ts) and the queue batches (idx_mq_batches_finished).
// Seven statements a call; test/archie-factory.bh-4588.test.js W5 and W6 pin
// the plans and the count. cost_rows is read hot only: a day the
// retention.cost_rows.archive_days rule may have moved is ok:false, not a 0.

import { json } from "../lib/http.js";
import { MERGE_MAX } from "../lib/daily-digest/core-sections.js";
import { COST_ARCHIVE_FLOOR_DAYS } from "./retention.js";

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const PROJECT_RE = /^[a-z0-9-]{1,64}$/;
const DAY_MS = 86400000;
// Code fallbacks; the settings rows of the same name win (schema.d BH-4588).
const ACTIONS_LIMIT_DEFAULT = 300; // archie.report.actions_limit
const ACTIONS_LIMIT_MAX = 500;     // the archie.report.actions_limit row's own ceiling (its note: 1-500)
const STUCK_MAX_DEFAULT = 20;      // archie.report.stuck_max
const STUCK_MAX_CEIL = 200;        // the archie.report.stuck_max row's own ceiling (its note: 1-200)
// A day's merges are read whole up to the daily digest's MERGE_MAX; past it
// the section is an error. The hot cost_rows window never goes under
// retention.js COST_ARCHIVE_FLOOR_DAYS, whatever retention.cost_rows.archive_days says.
const MODE_DEFAULT = "on";         // bin/lib/archie-fm.sh AFM_MODE_DEFAULT, no archie.manage row

// The playbook families of each section. queue-solo is the culprit's own CI
// run, counted under the queue; watch-ticket and improve are tickets;
// watch-session is a model session, never an item.
const isQueue = (pb) => pb.startsWith("queue-");
const isTicket = (pb) => pb === "improve" || pb === "watch-ticket";
const isStuck = (pb) => pb === "rebase-repair" || pb === "stacked-parent-merged" || pb === "data-lane"
  || (pb.startsWith("watch-") && pb !== "watch-ticket" && pb !== "watch-session");
const OPEN_OUTCOMES = new Set(["started", "requested", "deferred"]);

const bad = (field) => json(400, { error: field });
const intIn = (v, lo, hi) => (/^\d{1,6}$/.test(String(v ?? "")) && Number(v) >= lo && Number(v) <= hi ? Number(v) : null);
const errOf = (e) => String((e && e.message) || e).slice(0, 200);
const all = async (db, sql, ...binds) => (await db.prepare(sql).bind(...binds).all()).results || [];
const settled = (p) => p.then((v) => ({ ok: true, v }), (e) => ({ ok: false, error: errOf(e) }));
const prUrl = (repo, pr) => `https://github.com/${repo}/pull/${pr}`;
const repoOfPrUrl = (u) => {
  const m = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/pull\/(\d+)/.exec(String(u || ""));
  return m ? { repo: m[1], pr: Number(m[2]) } : null;
};
const parseEvidence = (s) => { try { return JSON.parse(s); } catch { return {}; } };
const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };

// ── the reads ───────────────────────────────────────────────────────────────
const SQL_SETTINGS = `SELECT key, value FROM settings
  WHERE (key >= 'archie.' AND key < 'archie/') OR (key >= 'budget.project.' AND key < 'budget.project/')
     OR key = 'retention.cost_rows.archive_days'`;
const SQL_PROJECTS = `SELECT project, repo FROM projects`;
const SQL_AGG = (pf) => `SELECT playbook, mode, action, outcome, project,
       COALESCE(json_extract(evidence, '$.existing'), 0) AS existing, COUNT(*) AS n
  FROM archie_actions WHERE day = ?1${pf ? " AND project = ?2" : ""}
  GROUP BY playbook, mode, action, outcome, project, existing`;
const SQL_ROWS = (pf) => `SELECT id, created_at, updated_at, project, repo, pr, playbook, mode, action, outcome, why, evidence
  FROM archie_actions WHERE day = ?1${pf ? " AND project = ?3" : ""}
  ORDER BY created_at DESC, id DESC LIMIT ?2`;
const SQL_MERGES = `SELECT l.key AS key, l.created_at AS created_at, j.project AS project
  FROM ledgers l
  LEFT JOIN job_artifacts a ON a.artifact_kind = 'pr_url' AND a.artifact_ref = l.key
  LEFT JOIN jobs j ON j.id = a.job_id
  WHERE l.kind = 'merge' AND l.status = 'merged' AND l.created_at >= ?1 AND l.created_at < ?2
  ORDER BY l.created_at LIMIT ?3`;
const SQL_SPEND = (pf) => `SELECT project, COUNT(*) AS calls, SUM(cost_usd IS NULL) AS unpriced, SUM(cost_usd) AS usd
  FROM cost_rows WHERE ts >= ?1 AND ts < ?2${pf ? " AND project = ?3" : ""} GROUP BY project`;
const SQL_BATCHES = `SELECT repo, outcome, COUNT(*) AS n FROM merge_queue_batches
  WHERE finished_at >= ?1 AND finished_at < ?2 GROUP BY repo, outcome`;
export const FACTORY_SQL = { SQL_SETTINGS, SQL_PROJECTS, SQL_AGG, SQL_ROWS, SQL_MERGES, SQL_SPEND, SQL_BATCHES };

// ── the sections (pure) ─────────────────────────────────────────────────────
function modeSection(st) {
  if (!st.ok) return { ok: false, error: st.error };
  const s = st.v;
  const fleetRaw = s.get("archie.manage");
  const norm = (v) => (["on", "observe", "off"].includes(String(v).trim()) ? String(v).trim() : "observe");
  const fleet = fleetRaw === undefined ? MODE_DEFAULT : norm(fleetRaw);
  const projects = {};
  for (const [k, v] of s) {
    const m = /^archie\.manage\.([a-z0-9-]+)$/.exec(k);
    if (m) projects[m[1]] = norm(v);
  }
  return { ok: true, fleet, off: fleet === "off", projects, source: fleetRaw === undefined ? "default" : "archie.manage" };
}

function mergesSection(r, repoProject, project, day) {
  if (!r.ok) return { ok: false, error: r.error };
  if (r.v.length > MERGE_MAX) return { ok: false, error: `more than ${MERGE_MAX} merges in one day` };
  const seen = new Map();
  for (const row of r.v) {
    const prev = seen.get(row.key);
    if (!prev || (!prev.project && row.project)) seen.set(row.key, row);
  }
  const groups = new Map();
  for (const row of seen.values()) {
    const p = repoOfPrUrl(row.key);
    const repo = p ? p.repo : null;
    // The job's project, else the projects row of the repo, else the repo's name.
    const proj = row.project || (repo && repoProject.get(repo)) || (repo ? repo.split("/")[1].toLowerCase() : "unknown");
    if (project && proj !== project) continue;
    const g = groups.get(proj) || { project: proj, n: 0, prs: [] };
    g.n += 1;
    g.prs.push({ repo, pr: p ? p.pr : null, url: row.key, merged_at: row.created_at });
    groups.set(proj, g);
  }
  const by_project = [...groups.values()].sort((a, b) => b.n - a.n || a.project.localeCompare(b.project));
  const total = by_project.reduce((s, g) => s + g.n, 0);
  return { ok: true, total, by_project, ...(total === 0 ? { empty_reason: `no merge was recorded on ${day}` } : {}) };
}

function queueSection(agg, batches, repoProject, project, day) {
  const out = { ok: true };
  if (!agg.ok && !batches.ok) return { ok: false, error: `${agg.error}; ${batches.error}` };
  if (agg.ok) {
    const a = { total: 0, by_action: {}, by_outcome: {} };
    for (const g of agg.v) {
      if (!isQueue(g.playbook)) continue;
      const n = Number(g.n);
      a.total += n;
      bump(a.by_action, g.action, n);
      bump(a.by_outcome, g.outcome, n);
    }
    out.actions = a;
  } else {
    out.actions = { ok: false, error: agg.error };
  }
  if (batches.ok) {
    const b = { total: 0, by_outcome: {} };
    for (const g of batches.v) {
      const proj = repoProject.get(g.repo) || String(g.repo).split("/")[1]?.toLowerCase();
      if (project && proj !== project) continue;
      const n = Number(g.n);
      b.total += n;
      bump(b.by_outcome, g.outcome || "unknown", n);
    }
    out.batches = b;
  } else {
    out.batches = { ok: false, error: batches.error };
  }
  if (!agg.ok || !batches.ok) {
    out.ok = false;
    out.error = (agg.ok ? batches.error : agg.error);
  }
  if (out.ok && out.actions.total === 0 && out.batches.total === 0) {
    out.empty_reason = `no merge-queue batch finished and Archie took no queue action on ${day}`;
  }
  return out;
}

const isUrl = (v) => typeof v === "string" && v.startsWith("https://");
// The link of a row: its PR, else the issue its evidence names (a url, or an
// issue number on the row's repo, the improve playbook's shape).
const linkOf = (r, ev) => {
  if (Number(r.pr) > 0) return prUrl(r.repo, r.pr);
  for (const v of [ev.issue_url, ev.issue, ev.lever && ev.lever.issue]) if (isUrl(v)) return v;
  if (Number.isInteger(ev.issue) && ev.issue > 0) return `https://github.com/${r.repo}/issues/${ev.issue}`;
  return null;
};
const TICKET_KIND = { comment: "commented", track_merged: "shipped", verified: "verified", reopen: "reopened" };
const itemOf = (r) => {
  const ev = parseEvidence(r.evidence);
  const base = r.action.replace(/^would_/, "");
  return {
    id: r.id, project: r.project, repo: r.repo, pr: Number(r.pr), playbook: r.playbook, mode: r.mode,
    action: r.action, outcome: r.outcome, why: r.why, created_at: r.created_at,
    url: linkOf(r, ev), alert_id: typeof ev.alert_id === "string" ? ev.alert_id : null,
    kind: base === "file_ticket" ? (ev.existing ? "commented" : "filed") : (TICKET_KIND[base] || base),
  };
};

function stuckSection(agg, rows, stuckMax, day) {
  if (!agg.ok) return { ok: false, error: agg.error };
  const c = { cleared: 0, open: 0, failed: 0, would: 0, skipped: 0 };
  for (const g of agg.v) {
    if (!isStuck(g.playbook)) continue;
    const n = Number(g.n);
    if (g.outcome === "done") c.cleared += n;
    else if (OPEN_OUTCOMES.has(g.outcome)) c.open += n;
    else if (g.outcome === "failed") c.failed += n;
    else if (g.outcome === "would") c.would += n;
    else c.skipped += n;
  }
  const total = c.cleared + c.open + c.failed + c.would + c.skipped;
  const out = { ok: true, total, ...c };
  if (rows.ok) {
    const items = rows.v.rows.filter((r) => isStuck(r.playbook)).map(itemOf);
    out.items = items.slice(0, stuckMax);
    out.truncated = items.length > stuckMax || rows.v.truncated;
  } else {
    out.items = [];
    out.items_error = rows.error;
    out.truncated = true;
  }
  if (total === 0) out.empty_reason = `Archie cleared nothing and nothing was stuck on ${day}`;
  return out;
}

function ticketsSection(agg, rows, day) {
  if (!agg.ok) return { ok: false, error: agg.error };
  const t = { filed: 0, commented: 0, shipped: 0, verified: 0, reopened: 0, would: 0 };
  for (const g of agg.v) {
    if (!isTicket(g.playbook)) continue;
    const n = Number(g.n);
    if (g.outcome === "would") { t.would += n; continue; }
    if (g.outcome !== "done") continue;
    if (g.action === "file_ticket") { if (Number(g.existing) ? 1 : 0) t.commented += n; else t.filed += n; }
    else if (g.action === "comment") t.commented += n;
    else if (g.action === "track_merged") t.shipped += n;
    else if (g.action === "verified") t.verified += n;
    else if (g.action === "reopen") t.reopened += n;
  }
  const out = { ok: true, ...t };
  out.items = rows.ok ? rows.v.rows.filter((r) => isTicket(r.playbook) && r.outcome === "done").map(itemOf) : [];
  if (!rows.ok) out.items_error = rows.error;
  if (t.filed + t.commented + t.shipped + t.verified + t.reopened + t.would === 0) {
    out.empty_reason = `Archie filed, commented on and shipped no ticket on ${day}`;
  }
  return out;
}

function spendSection(r, st, project, day, nowMs) {
  if (!r.ok) return { ok: false, error: r.error };
  if (!st.ok) return { ok: false, error: `the caps could not be read: ${st.error}` };
  const archDays = Number(st.v.get("retention.cost_rows.archive_days") || 0);
  if (archDays > 0 && Date.parse(`${day}T00:00:00Z`) < nowMs - Math.max(archDays, COST_ARCHIVE_FLOOR_DAYS) * DAY_MS) {
    return { ok: false, error: `${day} is older than the hot cost window (retention.cost_rows.archive_days=${archDays})` };
  }
  const capOf = (p) => {
    const v = st.v.get(`budget.project.${p}.day_usd`) ?? st.v.get("budget.project._default.day_usd");
    const n = v === undefined ? NaN : Number(v);
    return Number.isFinite(n) && n > 0 ? n : null;
  };
  const by_project = r.v.map((g) => {
    const calls = Number(g.calls);
    const unpriced = Number(g.unpriced || 0);
    // null when every call is unpriced: unknown, never free (D11).
    const usd = unpriced === calls ? null : Number(g.usd);
    const p = g.project || "unknown";
    const cap = capOf(p);
    return { project: p, usd, calls, unpriced_calls: unpriced, cap_usd: cap, over: usd !== null && cap !== null && usd > cap };
  }).filter((g) => !project || g.project === project)
    .sort((a, b) => (b.usd ?? -1) - (a.usd ?? -1) || a.project.localeCompare(b.project));
  const out = { ok: true, by_project };
  if (by_project.length === 0) out.empty_reason = `no model call was recorded on ${day}`;
  return out;
}

function actionsSection(rows, limit, day) {
  if (!rows.ok) return { ok: false, error: rows.error };
  const list = rows.v.rows.map((r) => ({
    id: r.id, created_at: r.created_at, updated_at: r.updated_at, project: r.project, repo: r.repo, pr: Number(r.pr),
    playbook: r.playbook, mode: r.mode, action: r.action, outcome: r.outcome, why: r.why, evidence: parseEvidence(r.evidence),
  }));
  return { ok: true, limit, truncated: rows.v.truncated, rows: list,
    ...(list.length === 0 ? { empty_reason: `Archie wrote no action row on ${day}` } : {}) };
}

function totalsOf(agg) {
  if (!agg.ok) return { ok: false, error: agg.error };
  const by_outcome = {};
  let total = 0;
  for (const g of agg.v) { total += Number(g.n); bump(by_outcome, g.outcome, Number(g.n)); }
  return { ok: true, total, by_outcome };
}

// The one thing the operator should know, highest first: failed actions, a project
// over its spend cap, open stuck items, else nothing. An unread section never
// produces a claim (an unreadable spend is never "over cap"). The open
// stop-the-line incident outranks all four; only the lane knows those
// (catalog/archie-stop-the-line.tsv), so render.sh puts it first.
export function oneThing(r) {
  const failed = r.totals.ok ? Number(r.totals.by_outcome.failed || 0) : 0;
  if (failed > 0) {
    const first = r.actions.ok ? r.actions.rows.find((a) => a.outcome === "failed") : null;
    const where = first ? ` The latest: ${first.playbook} on ${first.repo}${first.pr > 0 ? `#${first.pr}` : ""} (${first.why}).` : "";
    return { kind: "failed", text: `${failed} Archie action${failed === 1 ? "" : "s"} failed on ${r.day}.${where}` };
  }
  const over = r.spend.ok ? r.spend.by_project.filter((p) => p.over) : [];
  if (over.length > 0) {
    const p = over[0];
    return { kind: "over_cap", text: `${p.project} spent $${p.usd.toFixed(2)} on ${r.day}, over its $${p.cap_usd.toFixed(2)} day cap.` };
  }
  if (r.stuck.ok && r.stuck.open > 0) {
    return { kind: "stuck_open", text: `${r.stuck.open} stuck item${r.stuck.open === 1 ? " is" : "s are"} still open from ${r.day}.` };
  }
  return { kind: "none", text: `Nothing needs you from ${r.day}.` };
}

export const routes = [
  [
    "GET", "/api/archie/factory-report",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const day = q.get("day");
      if (day === null || !DAY_RE.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00Z`))
          || new Date(`${day}T00:00:00Z`).toISOString().slice(0, 10) !== day) return bad("day");
      let project = null;
      if (q.has("project")) {
        project = q.get("project");
        if (!PROJECT_RE.test(project)) return bad("project");
      }
      const from = `${day}T00:00:00Z`;
      const to = new Date(Date.parse(from) + DAY_MS).toISOString().replace(/\.\d{3}Z$/, "Z");
      const db = env.DB;

      // 1. settings: the mode, the caps and the knobs the reads below bind.
      const st = await settled(all(db, SQL_SETTINGS).then((rows) => new Map(rows.map((r) => [r.key, r.value]))));
      const knob = (k, dflt, hi) => {
        const v = st.ok ? st.v.get(k) : undefined;
        return v === undefined ? dflt : (intIn(String(v).trim(), 1, hi) ?? dflt);
      };
      const cap = knob("archie.report.actions_limit", ACTIONS_LIMIT_DEFAULT, ACTIONS_LIMIT_MAX);
      const stuckMax = knob("archie.report.stuck_max", STUCK_MAX_DEFAULT, STUCK_MAX_CEIL);
      let limit = cap;
      if (q.has("limit")) {
        limit = intIn(q.get("limit"), 1, cap);
        if (limit === null) return json(400, { error: "limit", max: cap });
      }

      // 2. the six data reads, in parallel.
      const pb = project ? [project] : [];
      const [pr, agg, rowsR, merges, spend, batches] = await Promise.all([
        settled(all(db, SQL_PROJECTS)),
        settled(all(db, SQL_AGG(project), day, ...pb)),
        settled(all(db, SQL_ROWS(project), day, limit + 1, ...pb)
          .then((rows) => ({ rows: rows.slice(0, limit), truncated: rows.length > limit }))),
        settled(all(db, SQL_MERGES, from, to, MERGE_MAX + 1)),
        settled(all(db, SQL_SPEND(project), from, to, ...pb)),
        settled(all(db, SQL_BATCHES, from, to)),
      ]);
      const repoProject = new Map(pr.ok ? pr.v.map((r) => [r.repo, r.project]) : []);

      const r = {
        ok: true, day, project, generated_at: t,
        mode: modeSection(st),
        merges: mergesSection(merges, repoProject, project, day),
        queue: queueSection(agg, batches, repoProject, project, day),
        stuck: stuckSection(agg, rowsR, stuckMax, day),
        tickets: ticketsSection(agg, rowsR, day),
        spend: spendSection(spend, st, project, day, Date.parse(t)),
        totals: totalsOf(agg),
        actions: actionsSection(rowsR, limit, day),
      };
      r.one_thing = oneThing(r);
      return json(200, r);
    },
  ],
];

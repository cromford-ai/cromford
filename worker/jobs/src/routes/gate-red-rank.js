// GATE_RED ranking route — BH-9583 (BH-9559 part D, item 10). The builder gate
// (bin/test-impact-gate.sh, tier `topred`) asks which suites turned the most
// builds of a repo GATE_RED lately, and runs those before it pushes.
//
// GET /api/gate-red/top?repo=<owner/name|project>&n=<int>&days=<int>
//   repo  required, ^[A-Za-z0-9._/-]{1,100}$, matched to projects.repo or
//         projects.project. An unknown repo is 200 with suites [] (a real
//         empty answer: no project matches).
//   n     positive integer, else 400. Absent: settings row builder_gate.topred_n.
//   days  positive integer, else 400. Absent: builder_gate.topred_window_days.
//   200 {repo, days, n, since, rows_read, suites: [{suite, count, last_at}]}
//
// The source is the jobs table: _job_finish (bin/lib/rb/gates.sh) writes a
// GATE_RED build as status='failed' with meta = the first 300 chars of the
// RESULT line `GATE_RED <n> red: <a>,<b>; see <build>/gate.txt`
// (bin/lib/selection-gate.sh). ONE statement, bounded by the window through
// idx_jobs_project_status_created (project, status, created_at). The project
// subquery is not correlated: it runs once. No new table, no new index, no
// cache. Note: docs/gates/builder-topred.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

const REPO_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const POS_INT_RE = /^[1-9][0-9]*$/;
const SUITE_RE = /^tests\/(mc\/)?[A-Za-z0-9._-]+\.sh$/;
const LINE_RE = /^GATE_RED (\d+) red: (.*)$/s;
// Fallback of the settings row builder_gate.topred_n (seeded 5).
const TOPRED_N_DEFAULT = 5;
// Fallback of the settings row builder_gate.topred_window_days (seeded 14).
const TOPRED_WINDOW_DAYS_DEFAULT = 14;
const DAY_MS = 86400e3;

const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

export const GATE_RED_RANK_SQL = `SELECT meta, created_at FROM jobs
 WHERE project IN (SELECT project FROM projects WHERE repo = ?1 OR project = ?1)
   AND status = 'failed' AND created_at >= ?2 AND meta LIKE 'GATE_RED %'`;

// gateRedSuites(meta) — the suites one GATE_RED jobs.meta names, each once.
// The list ends at the first `; see `. With no `; see ` the 300-char fold cut
// the line, so the last item can be half a name: it is dropped. Anything that
// is not a tests/[mc/]<name>.sh path is dropped.
export function gateRedSuites(meta) {
  if (typeof meta !== "string") return [];
  const m = LINE_RE.exec(meta);
  if (!m) return [];
  const list = m[2];
  const cut = list.indexOf("; see ");
  let items;
  if (cut >= 0) items = list.slice(0, cut).split(",");
  else { items = list.split(","); items.pop(); }
  const out = [];
  for (const raw of items) {
    const s = raw.trim();
    if (!SUITE_RE.test(s) || s.includes("..") || out.includes(s)) continue;
    out.push(s);
  }
  return out;
}

// rank(rows, n) — count rows per suite; count desc, last_at desc, suite asc.
export function rankSuites(rows, n) {
  const by = new Map();
  for (const r of rows) {
    for (const s of gateRedSuites(r.meta)) {
      const e = by.get(s) || { suite: s, count: 0, last_at: "" };
      e.count += 1;
      if (String(r.created_at) > e.last_at) e.last_at = String(r.created_at);
      by.set(s, e);
    }
  }
  return [...by.values()]
    .sort((a, b) => b.count - a.count || (a.last_at < b.last_at ? 1 : a.last_at > b.last_at ? -1 : 0)
      || (a.suite < b.suite ? -1 : a.suite > b.suite ? 1 : 0))
    .slice(0, n);
}

const bad = (field) => json(400, { error: field });

export const routes = [
  [
    "GET", "/api/gate-red/top",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const repo = q.get("repo");
      if (typeof repo !== "string" || !REPO_RE.test(repo)) return bad("repo");
      const nRaw = q.get("n");
      const dRaw = q.get("days");
      if (nRaw !== null && !POS_INT_RE.test(nRaw)) return bad("n");
      if (dRaw !== null && !POS_INT_RE.test(dRaw)) return bad("days");
      return d1Guarded("jobs", async () => {
        let n = nRaw === null ? null : Number(nRaw);
        let days = dRaw === null ? null : Number(dRaw);
        if (n === null || days === null) {
          const { byKey } = await settingsRows(env);
          if (n === null) n = intSetting(byKey, "builder_gate.topred_n", TOPRED_N_DEFAULT, 1, Number.MAX_SAFE_INTEGER);
          if (days === null) days = intSetting(byKey, "builder_gate.topred_window_days", TOPRED_WINDOW_DAYS_DEFAULT, 1, Number.MAX_SAFE_INTEGER);
        }
        const since = isoSeconds(Date.parse(t) - days * DAY_MS);
        const res = await env.DB.prepare(GATE_RED_RANK_SQL).bind(repo, since).all();
        const rows = res.results || [];
        return json(200, { repo, days, n, since, rows_read: rows.length, suites: rankSuites(rows, n) });
      });
    },
  ],
];

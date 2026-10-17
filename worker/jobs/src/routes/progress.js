// progress routes — K2, the stamps the OUTSIDE dead-man judges.
//
// The watchdog worker (worker/watchdog) checked only LIVENESS: a box pings, the
// hub pushes status. Nothing outside the fleet checked PROGRESS, so a hub whose
// lease failed (09-19, 29 min), a conductor that merged nothing for hours on an
// empty GraphQL budget and a project that spent $643 in a week with no merge
// all looked alive. This route answers, per project, WHEN each lane last
// produced something, what the project spent, how much work is waiting, and
// when each named detector lane last ticked. bin/progress-push.sh relays it to
// the watchdog, which judges it on its own cron (worker/watchdog/src/progress.js)
// and pages Telegram directly.
//
// Every number is a row the fleet already writes: jobs, verdict_history,
// ledgers/merge_queue/merge_trains, cost_rows, build_queue, lane_ticks. No
// GitHub call. The only writes are the cost section's own cache of cost_rows
// (cost_project_hourly and its watermark, lib/cost-hourly.js).
//
// EACH SECTION IS ITS OWN try/catch. A table a database has not been given yet
// (or a D1 hiccup) makes THAT section unknown — named in `errors`, its fields
// null — never a 500 that blinds the other five, and never a fabricated 0 that
// reads as "nothing wrong". The watchdog holds every rule that reads an
// errored section.

import { json } from "../lib/http.js";
import { doraRepo } from "../lib/core.js";
import { readCost } from "../lib/cost-hourly.js";

const clampInt = (v, lo, hi, dflt) => {
  const n = Number(v);
  if (v === null || v === "" || !Number.isFinite(n)) return dflt;
  return Math.min(Math.max(Math.trunc(n), lo), hi);
};
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const newer = (a, b) => (!a ? b || null : !b ? a : (a > b ? a : b));
const DETECTOR_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const MAX_DETECTORS = 20;
// Build lanes: what finishing a ticket looks like in the jobs table.
const BUILD_KINDS = new Set(["build", "fix"]);

export const routes = [
  [
    "GET", "/api/progress/stamps",
    async ({ env, url, t }) => {
      const nowMs = Date.parse(t);
      // Windows come from the caller (its settings rows), clamped here so a
      // bad knob bounds a query instead of scanning the table.
      const spendMin = clampInt(url.searchParams.get("spend_min"), 1, 1440, 60);
      // One or more long windows (the no-merge rule has a day and a week by
      // default): numbers only, each clamped, at most three.
      const longMins = (url.searchParams.get("long_min") || "1440").split(",")
        .map((v) => v.trim()).filter((v) => /^-?\d+$/.test(v)).slice(0, 3)
        .map((v) => clampInt(v, 1, 20160, 1440));
      const lookbackHReq = clampInt(url.searchParams.get("lookback_h"), 1, 720, 168);
      const rawDet = (url.searchParams.get("detectors") || "").split(",").map((s) => s.trim()).filter(Boolean);
      if (rawDet.length > MAX_DETECTORS || rawDet.some((d) => !DETECTOR_RE.test(d))) {
        return json(400, { error: `detectors must be at most ${MAX_DETECTORS} lane ids ([a-z0-9-])` });
      }
      // The stamp lookback is never shorter than the longest no-merge window
      // (#2289 nit 4): a merge older than the lookback reads as "never", and a
      // window longer than it would then page on a merge it simply cannot see.
      const lookbackH = Math.max(lookbackHReq, Math.ceil(Math.max(0, ...longMins) / 60));
      const lookback = iso(nowMs - lookbackH * 3600000);
      const shortCut = iso(nowMs - spendMin * 60000);
      // The widest cut: the legacy cost read scans from here back.
      const scanMin = Math.max(spendMin, lookbackH * 60, ...longMins);
      const scanCut = iso(nowMs - scanMin * 60000);

      const projects = {};
      const P = (p) => {
        if (!projects[p]) {
          projects[p] = {
            stamps: { triage: null, build_ok: null, build_result: null, review: null, merge: null, qa: null, cost: null },
            spend: {}, spend_long: Object.fromEntries(longMins.map((w) => [w, 0])), queued: { build: 0, merge: 0 },
          };
        }
        return projects[p];
      };
      const errors = [];
      const section = async (name, fn) => {
        try { await fn(); } catch (e) {
          errors.push(name);
          console.log(`progress/stamps: ${name} unreadable — ${e && e.message || e}`);
        }
      };
      const all = async (sql, ...binds) => (await env.DB.prepare(sql).bind(...binds).all()).results || [];

      // Job stamps. `running` never counts: a heartbeat is not a result.
      await section("jobs", async () => {
        const rows = await all(
          `SELECT project, kind, status, MAX(updated_at) AS at FROM jobs
            WHERE updated_at >= ?1 AND status != 'running'
            GROUP BY project, kind, status`, lookback);
        for (const r of rows) {
          if (!r.project) continue;
          const s = P(r.project).stamps;
          if (r.kind === "triage" && r.status === "done") s.triage = newer(s.triage, r.at);
          if (BUILD_KINDS.has(r.kind)) {
            s.build_result = newer(s.build_result, r.at);
            if (r.status === "done") s.build_ok = newer(s.build_ok, r.at);
          }
          if (r.kind === "qa") s.qa = newer(s.qa, r.at);
        }
      });

      // Review verdicts, attributed through the job they were written for.
      await section("verdicts", async () => {
        const rows = await all(
          `SELECT j.project AS project, MAX(v.created_at) AS at
             FROM verdict_history v JOIN jobs j ON j.id = v.job_id
            WHERE v.created_at >= ?1 GROUP BY j.project`, lookback);
        for (const r of rows) if (r.project) P(r.project).stamps.review = newer(P(r.project).stamps.review, r.at);
      });

      // Merges: every path the fleet records one on. The merge ledger (keyed
      // on the PR url) is attributed through its job, else through the repo
      // slug merge_queue writes beside its project — the same map
      // /api/metrics/dora uses.
      await section("merges", async () => {
        const repoMap = new Map((await all(
          `SELECT DISTINCT project, repo FROM merge_queue WHERE repo IS NOT NULL LIMIT 500`))
          .map((r) => [r.repo, r.project]));
        const led = await all(
          `SELECT l.key AS key, j.project AS project, MAX(l.updated_at) AS at
             FROM ledgers l LEFT JOIN jobs j ON j.id = l.job_id
            WHERE l.kind = 'merge' AND l.status = 'merged' AND l.updated_at >= ?1
            GROUP BY l.key, j.project`, lookback);
        for (const r of led) {
          const p = r.project || repoMap.get(doraRepo(r.key));
          if (p) P(p).stamps.merge = newer(P(p).stamps.merge, r.at);
        }
        const mq = await all(
          `SELECT project, MAX(updated_at) AS at FROM merge_queue
            WHERE status = 'landed' AND updated_at >= ?1 GROUP BY project`, lookback);
        const mt = await all(
          `SELECT project, MAX(updated_at) AS at FROM merge_trains
            WHERE outcome = 'landed' AND updated_at >= ?1 GROUP BY project`, lookback);
        for (const r of [...mq, ...mt]) if (r.project) P(r.project).stamps.merge = newer(P(r.project).stamps.merge, r.at);
      });

      // Spend: PRICED rows only (an unpriced row is a run, not spend). The
      // windows are read from hourly buckets plus the raw partial hours at
      // their edges (lib/cost-hourly.js, BH-7164), not from every row.
      await section("cost", async () => {
        const c = await readCost(env, {
          nowMs, scanCut, shortCut, lookback, longCuts: longMins.map((w) => iso(nowMs - w * 60000)),
        });
        const round = (n) => Math.round(Number(n || 0) * 100) / 100;
        for (const r of c.short) {
          const p = P(r.project), st = r.stage || "unknown";
          p.spend[st] = round((p.spend[st] || 0) + r.usd);
        }
        for (const [proj, sums] of c.long) {
          const p = P(proj);
          longMins.forEach((w, i) => { p.spend_long[w] = round(p.spend_long[w] + sums[i]); });
        }
        for (const [proj, ts] of c.last) P(proj).stamps.cost = newer(P(proj).stamps.cost, ts);
      });
      if (errors.includes("cost")) for (const p of Object.values(projects)) { p.spend = null; p.spend_long = null; }

      // Work waiting: queued build rows and approved PRs queued to merge.
      await section("queues", async () => {
        const bq = await all(`SELECT project, COUNT(*) AS n FROM build_queue WHERE status = 'queued' GROUP BY project`);
        const mq = await all(`SELECT project, COUNT(*) AS n FROM merge_queue WHERE status = 'queued' GROUP BY project`);
        for (const r of bq) if (r.project) P(r.project).queued.build = Number(r.n) || 0;
        for (const r of mq) if (r.project) P(r.project).queued.merge = Number(r.n) || 0;
      });
      if (errors.includes("queues")) for (const p of Object.values(projects)) p.queued = null;

      // Watch the watchers: each named detector lane's own tick rows.
      let detectors = [];
      if (rawDet.length) {
        await section("detectors", async () => {
          const ph = rawDet.map((_, i) => `?${i + 1}`).join(",");
          const rows = await all(
            `SELECT lane, project, box, last_tick_at, last_outcome, why FROM lane_ticks
              WHERE lane IN (${ph}) ORDER BY lane, box LIMIT 500`, ...rawDet);
          detectors = rows.map((r) => ({ lane: r.lane, project: r.project, box: r.box, at: r.last_tick_at, outcome: r.last_outcome, why: r.why ?? null }));
        });
        if (errors.includes("detectors")) detectors = null;
      }

      return json(200, {
        as_of: t, spend_min: spendMin, long_min: longMins, lookback_h: lookbackH,
        projects, detectors, errors,
      });
    },
  ],
];

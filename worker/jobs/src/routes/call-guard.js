// call-guard routes — K3, the pre-call guard's counter.
//
// NEW family, not moved (BH-1195 split the chain; this lands as its own module).
// src/index.js holds the ordered table; test/route-table.test.js carries these
// entries in the position the table puts them (the end).
//
// THE CONTRACT bin/lib/call-guard.sh reads:
//   POST /api/call-guard/claim  {project, stage, fp, call_id, max, window_s?, runner?, box?}
//     -> 200 {allowed, count, max, window_s, call_id, duplicate, top?}
//        `count` is the PAID calls of this (project, stage, fp) inside the
//        window, this one included when it was allowed. A refusal is a 200
//        with allowed:false — an answer, never an error status — so the client
//        can tell "refused" from "unreadable" without guessing.
//   POST /api/call-guard/settle {call_id, outcome: ok|empty|failed|unbilled}
//     -> 200 {settled}  (false when the row was already settled, was a
//        refusal, or never existed: the FIRST outcome stands)
//   GET  /api/call-guard?project=&stage=&hours=&fp=
//        (fp=, BH-7792: only that fingerprint's row; read-only, no claim)
//     -> {rows:[{project,stage,fp,paid,refused,refused_since_reset,reset_at,last_at}]}
//        `refused` is every refusal in the window. `reset_at` is the `at` of
//        the key's newest reset audit row in the window (null if none), and
//        `refused_since_reset` counts only the refusals inserted after it
//        (rowid order, since `at` is to the second), or all of them when there
//        is no reset. BH-2397: so a RESET supersedes the refusals before it.
//   DELETE /api/call-guard?project=&stage=&fp=&actor=&reason=  -> {reset}
//        an operator's "this work may be bought again": the key's paid rows
//        become reset:<status> (never counted again) and ONE audit row
//        (status=reset, box=actor, note=reason) records who and why.
//   A claim with force:true (AGENT_CALL_GUARD_FORCE=1, a hand-run path) is
//   recorded as paid even at the ceiling: an override is never a free call.
//
// Deterministic, no model anywhere on this path.

import { json } from "../lib/http.js";
import { ensureTable, str } from "../lib/core.js";

// The statuses that COUNT as a paid call. `claimed` is in the list on purpose:
// a box that died mid-call most likely paid, and a guard that forgot in-flight
// calls would let a crash loop through it. `unbilled` and `refused` are not.
const PAID = "('claimed','ok','empty','failed')";
const OUTCOMES = new Set(["ok", "empty", "failed", "unbilled"]);
const WINDOW_DEFAULT_S = 86400;
const WINDOW_MIN_S = 60;
const WINDOW_MAX_S = 7 * 86400;
// Rows older than this are pruned on the claim path, a bounded batch at a
// time: the table grows one row per guarded call and nothing else deletes.
const RETAIN_S = 8 * 86400;

const isoMinus = (t, secs) =>
  new Date(Date.parse(t) - secs * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

function clampInt(v, dflt, lo, hi) {
  const n = Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, Math.trunc(n)));
}

async function paidCount(env, project, stage, fp, since) {
  // sql-ident-ok: PAID is a module const status tuple
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM call_guard
      WHERE project=?1 AND stage=?2 AND fp=?3 AND at>=?4 AND status IN ${PAID}`
  ).bind(project, stage, fp, since).first();
  return Number((row && row.n) || 0);
}

async function topFingerprints(env, project, stage, since) {
  // sql-ident-ok: PAID is a module const status tuple
  const rows = await env.DB.prepare(
    `SELECT fp,
            SUM(CASE WHEN status='refused' THEN 1 ELSE 0 END) AS refused,
            SUM(CASE WHEN status IN ${PAID} THEN 1 ELSE 0 END) AS paid,
            MAX(at) AS last_at
       FROM call_guard
      WHERE project=?1 AND stage=?2 AND at>=?3
      GROUP BY fp
     HAVING refused > 0
      ORDER BY refused DESC, last_at DESC
      LIMIT 3`
  ).bind(project, stage, since).all();
  return (rows.results || []).map((r) => ({
    fp: r.fp, refused: Number(r.refused) || 0, paid: Number(r.paid) || 0, last_at: r.last_at,
  }));
}

export const routes = [
  [
    "POST", "/api/call-guard/claim",
    async ({ env, t, body }) => {
      await ensureTable(env, "call_guard");
      const project = str(body.project, 64);
      const stage = str(body.stage, 64);
      const fp = str(body.fp, 300);
      const callId = str(body.call_id, 128);
      if (!project || !stage || !fp || !callId) {
        return json(400, { error: "project, stage, fp and call_id are required" });
      }
      const max = clampInt(body.max, 0, 0, 1000);
      // 0 is "the guard is off for this stage". The CLIENT decides that and
      // never asks; a route that read 0 as "refuse everything" or as "allow
      // everything" would be guessing which the operator meant.
      if (max < 1) return json(400, { error: "max must be >= 1 (0 means the guard is off: do not ask)" });
      const windowS = clampInt(body.window_s, WINDOW_DEFAULT_S, WINDOW_MIN_S, WINDOW_MAX_S);
      const since = isoMinus(t, windowS);
      const box = str(body.box, 64) || null;
      const runner = str(body.runner, 32) || null;

      // IDEMPOTENT ON call_id. A transport retry of the same claim returns the
      // first decision and is never counted twice.
      const prior = await env.DB.prepare("SELECT status FROM call_guard WHERE call_id=?1").bind(callId).first();
      if (prior) {
        return json(200, {
          allowed: prior.status !== "refused",
          count: await paidCount(env, project, stage, fp, since),
          max, window_s: windowS, call_id: callId, duplicate: true, as_of: t,
        });
      }

      // FORCED (a hand-run path): recorded and counted, never refused.
      if (body.force === true) {
        await env.DB.prepare(
          `INSERT INTO call_guard (call_id, project, stage, fp, status, box, runner, at, note)
           VALUES (?1, ?2, ?3, ?4, 'claimed', ?5, ?6, ?7, 'forced')
           ON CONFLICT(call_id) DO NOTHING`
        ).bind(callId, project, stage, fp, box, runner, t).run();
        return json(200, {
          allowed: true, forced: true,
          count: await paidCount(env, project, stage, fp, since),
          max, window_s: windowS, call_id: callId, duplicate: false, as_of: t,
        });
      }

      // THE COUNT AND THE INSERT ARE ONE STATEMENT. SQLite (and D1) serialise
      // writes, so the sub-select sees every claim committed before this one:
      // two boxes asking at the same instant cannot both slip under `max`.
      // sql-ident-ok: PAID is a module const status tuple
      const ins = await env.DB.prepare(
        `INSERT INTO call_guard (call_id, project, stage, fp, status, box, runner, at)
         SELECT ?1, ?2, ?3, ?4, 'claimed', ?5, ?6, ?7
          WHERE (SELECT COUNT(*) FROM call_guard
                  WHERE project=?2 AND stage=?3 AND fp=?4 AND at>=?8 AND status IN ${PAID}) < ?9
         ON CONFLICT(call_id) DO NOTHING`
      ).bind(callId, project, stage, fp, box, runner, t, since, max).run();
      const allowed = !!(ins.meta && ins.meta.changes);

      let top;
      if (!allowed) {
        // Kept, so the digest can say WHICH work keeps asking. Never counted.
        await env.DB.prepare(
          `INSERT INTO call_guard (call_id, project, stage, fp, status, box, runner, at, settled_at)
           VALUES (?1, ?2, ?3, ?4, 'refused', ?5, ?6, ?7, ?7)
           ON CONFLICT(call_id) DO NOTHING`
        ).bind(callId, project, stage, fp, box, runner, t).run();
        top = await topFingerprints(env, project, stage, since);
      }

      // Bounded retention sweep. The rowid sub-select is the portable LIMIT
      // for a DELETE (D1 is not built with SQLITE_ENABLE_UPDATE_DELETE_LIMIT).
      await env.DB.prepare(
        `DELETE FROM call_guard WHERE rowid IN
           (SELECT rowid FROM call_guard WHERE at < ?1 LIMIT 200)`
      ).bind(isoMinus(t, RETAIN_S)).run();

      return json(200, {
        allowed,
        count: await paidCount(env, project, stage, fp, since),
        max, window_s: windowS, call_id: callId, duplicate: false,
        ...(top ? { top } : {}), as_of: t,
      });
    },
  ],

  [
    "POST", "/api/call-guard/settle",
    async ({ env, t, body }) => {
      await ensureTable(env, "call_guard");
      const callId = str(body.call_id, 128);
      const outcome = str(body.outcome, 16);
      if (!callId) return json(400, { error: "call_id is required" });
      if (!OUTCOMES.has(outcome)) return json(400, { error: "outcome must be ok, empty, failed or unbilled" });
      // Only a `claimed` row moves, and only once: the first outcome stands,
      // and a refusal can never be settled into a paid (or a freed) call.
      const res = await env.DB.prepare(
        "UPDATE call_guard SET status=?2, settled_at=?3 WHERE call_id=?1 AND status='claimed'"
      ).bind(callId, outcome, t).run();
      return json(200, { settled: !!(res.meta && res.meta.changes), call_id: callId, outcome, as_of: t });
    },
  ],

  [
    "DELETE", "/api/call-guard",
    async ({ env, url, t }) => {
      await ensureTable(env, "call_guard");
      const project = str(url.searchParams.get("project"), 64);
      const stage = str(url.searchParams.get("stage"), 64);
      const fp = str(url.searchParams.get("fp"), 300);
      if (!project || !stage || !fp) return json(400, { error: "project, stage and fp are required" });
      const actor = str(url.searchParams.get("actor"), 64) || null;
      const reason = str(url.searchParams.get("reason"), 500) || "manual reset";
      // sql-ident-ok: PAID is a module const status tuple
      const res = await env.DB.prepare(
        `UPDATE call_guard SET status='reset:'||status, settled_at=?4
          WHERE project=?1 AND stage=?2 AND fp=?3 AND status IN ${PAID}`
      ).bind(project, stage, fp, t).run();
      const n = Number((res.meta && res.meta.changes) || 0);
      await env.DB.prepare(
        `INSERT INTO call_guard (call_id, project, stage, fp, status, box, at, settled_at, note)
         VALUES (?1, ?2, ?3, ?4, 'reset', ?5, ?6, ?6, ?7)`
      ).bind(`reset-${crypto.randomUUID()}`,
             project, stage, fp, actor, t, `${reason} (${n} paid row(s) reset)`).run();
      return json(200, { reset: n, project, stage, fp, as_of: t });
    },
  ],

  [
    "GET", "/api/call-guard",
    async ({ env, url, t }) => {
      await ensureTable(env, "call_guard");
      const hours = clampInt(url.searchParams.get("hours"), 24, 1, 24 * 8);
      const where = ["at>=?1"];
      const binds = [isoMinus(t, hours * 3600)];
      const project = url.searchParams.get("project");
      const stage = url.searchParams.get("stage");
      if (project) { binds.push(project); where.push(`project=?${binds.length}`); }
      if (stage) { binds.push(stage); where.push(`stage=?${binds.length}`); }
      // BH-7792: one fingerprint's roll-up (the lead lane's read before its
      // rules pack), served by idx_call_guard_key(project, stage, fp, at).
      const fp = url.searchParams.get("fp");
      if (fp) { binds.push(fp); where.push(`fp=?${binds.length}`); }
      // `w` is the window; `r` is each key's newest reset in it, by rowid.
      // sql-ident-ok: where holds literal column=?N clauses, every value a bind
      const rows = await env.DB.prepare(
        `WITH w AS (SELECT rowid AS rid, * FROM call_guard WHERE ${where.join(" AND ")}),
              r AS (SELECT project, stage, fp,
                           MAX(CASE WHEN status='reset' THEN rid END) AS reset_rid,
                           MAX(CASE WHEN status='reset' THEN at END) AS reset_at
                      FROM w GROUP BY project, stage, fp)
         SELECT w.project, w.stage, w.fp,
                SUM(CASE WHEN w.status IN ${PAID} THEN 1 ELSE 0 END) AS paid,
                SUM(CASE WHEN w.status='refused' THEN 1 ELSE 0 END) AS refused,
                SUM(CASE WHEN w.status='refused' AND (r.reset_rid IS NULL OR w.rid > r.reset_rid)
                         THEN 1 ELSE 0 END) AS refused_since_reset,
                r.reset_at AS reset_at,
                MAX(w.at) AS last_at
           FROM w LEFT JOIN r ON r.project=w.project AND r.stage=w.stage AND r.fp=w.fp
          GROUP BY w.project, w.stage, w.fp
          ORDER BY refused DESC, paid DESC, last_at DESC
          LIMIT 200`
      ).bind(...binds).all();
      return json(200, { rows: rows.results || [], hours, as_of: t });
    },
  ],
];

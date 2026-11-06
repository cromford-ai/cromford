// agent-call-ledger routes — BH-9064, dedup before spend at bin/agent-call.sh.
//
// NEW family (test/route-table.d/bh-9064-agent-call-ledger.txt). The K3
// counter (routes/call-guard.js) counts paid calls; this table remembers what
// each piece of work came to: its status, its attempts, its stored rc and, for
// an `ok`, its answer. bin/lib/agent-call-ledger.sh asks it before the model
// call and settles it after.
//
// THE CONTRACT bin/lib/jobs/agent-call-ledger.sh reads:
//   POST /api/agent-call-ledger/begin
//        {project, stage, fp, max_attempts, window_s, running_ttl_s, replay, box}
//     -> 200 {decision: run|replay|terminal, status, attempts, rc, runner, model,
//             answer_body?, answer_ref?, checkpoint, age_s}
//        run       the row is now `running` and this call is one more attempt
//                  (attempts restarts at 1 when the row is past the window or
//                  was reset). Cases: no row; `failed` under the cap;
//                  `unbilled`; `ok` that may not be replayed; `running` past
//                  its TTL under the cap (a crashed call counts as paid).
//        replay    an `ok` row, replay:true, with a non-blank body. An `ok`
//                  row with no body (the answer was over the client's byte
//                  cap) or a blank one is a miss: it runs. Nothing is written.
//        terminal  `empty`; `failed` or a stale `running` at the cap; `running`
//                  inside its TTL (another box is buying it now); `parked`.
//                  Nothing is written.
//        The decision is ONE upsert: SQLite (and D1) serialise writes, so two
//        boxes asking at the same instant cannot both get `run` past the cap.
//   POST /api/agent-call-ledger/finish
//        {project, stage, fp, status?, rc?, runner?, model?, answer_body?,
//         answer_ref?, checkpoint?}
//     -> 200 {settled}. status is ok|empty|failed|unbilled|parked; `unbilled`
//        gives the attempt back (nothing was bought). A finish with only a
//        checkpoint updates the checkpoint and nothing else. An answer_body
//        over ANSWER_BYTES_MAX is 413 and changes nothing.
//   GET  /api/agent-call-ledger?project=&stage=&fp=[&body=1]  -> {row|null}
//   DELETE /api/agent-call-ledger?project=&stage=&fp=&actor=&reason=  -> {reset}
//        an operator's "buy it again": the row becomes `reset` (the next begin
//        is a fresh run) and keeps who and why in `note`.
//
// Deterministic, no model anywhere on this path.

import { json } from "../lib/http.js";
import { ensureTable, str } from "../lib/core.js";

const FINISH = new Set(["ok", "empty", "failed", "unbilled", "parked"]);
// Request bounds. The knobs themselves are the client's (catalog/lanes.d/
// _lib.agent-call-ledger.json: AGENT_LEDGER_MAX_ATTEMPTS, AGENT_LEDGER_WINDOW_S,
// AGENT_LEDGER_RUNNING_TTL_S); these only refuse a value no knob can hold.
const ATTEMPTS_MAX = 100;
const SECONDS_MAX = 7 * 86400;
// The largest answer a row takes: the max of the AGENT_LEDGER_ANSWER_MAX_BYTES
// knob. A larger body is a client that ignored its knob, so it is refused.
const ANSWER_BYTES_MAX = 1048576;

const isoMinus = (t, secs) =>
  new Date(Date.parse(t) - secs * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

function wholeInt(v, lo, hi) {
  const n = Number(v);
  if (v === null || v === undefined || v === "" || !Number.isInteger(n)) return null;
  return n >= lo && n <= hi ? n : null;
}

function key(src) {
  return { project: str(src.project, 64), stage: str(src.stage, 64), fp: str(src.fp, 300) };
}

const ROW_COLS = "project, stage, fp, status, attempts, rc, runner, model, box, answer_ref, answer_bytes, checkpoint, note, first_at, last_at";

async function readRow(env, k, withBody) {
  // sql-ident-ok: ROW_COLS is a module const column list
  return env.DB.prepare(
    `SELECT ${ROW_COLS}${withBody ? ", answer_body" : ""} FROM agent_call_ledger
      WHERE project=?1 AND stage=?2 AND fp=?3`
  ).bind(k.project, k.stage, k.fp).first();
}

const ageS = (t, at) => (at ? Math.max(0, Math.round((Date.parse(t) - Date.parse(at)) / 1000)) : null);

export const routes = [
  [
    "POST", "/api/agent-call-ledger/begin",
    async ({ env, t, body }) => {
      await ensureTable(env, "agent_call_ledger");
      const k = key(body);
      if (!k.project || !k.stage || !k.fp) return json(400, { error: "project, stage and fp are required" });
      const max = wholeInt(body.max_attempts, 1, ATTEMPTS_MAX);
      const windowS = wholeInt(body.window_s, 1, SECONDS_MAX);
      const ttlS = wholeInt(body.running_ttl_s, 1, SECONDS_MAX);
      if (max === null || windowS === null || ttlS === null) {
        return json(400, { error: `max_attempts (1..${ATTEMPTS_MAX}), window_s and running_ttl_s (1..${SECONDS_MAX}) are required whole numbers` });
      }
      const replay = body.replay === true ? 1 : 0;
      const box = str(body.box, 64) || "";
      const sinceWin = isoMinus(t, windowS);
      const sinceTtl = isoMinus(t, ttlS);
      // fresh:    past the window (a running row only once past its TTL too), or reset
      // runnable: one more attempt of work the row has not settled for good
      // replayable (excluded from runnable): an ok answer with a non-blank body
      const fresh = `(agent_call_ledger.status='reset'
        OR (agent_call_ledger.last_at < ?6
            AND (agent_call_ledger.status <> 'running' OR agent_call_ledger.last_at < ?7)))`;
      const replayable = `(?9 = 1 AND agent_call_ledger.answer_body IS NOT NULL
          AND trim(agent_call_ledger.answer_body, ' ' || char(9, 10, 13)) <> '')`;
      const runnable = `((agent_call_ledger.status='failed' AND agent_call_ledger.attempts < ?8)
        OR agent_call_ledger.status='unbilled'
        OR (agent_call_ledger.status='ok' AND NOT ${replayable})
        OR (agent_call_ledger.status='running' AND agent_call_ledger.last_at < ?7
            AND agent_call_ledger.attempts < ?8))`;
      // sql-ident-ok: fresh, replayable and runnable are module-literal predicates; every value is a bind
      const res = await env.DB.prepare(
        `INSERT INTO agent_call_ledger (project, stage, fp, status, attempts, box, first_at, last_at)
         VALUES (?1, ?2, ?3, 'running', 1, ?4, ?5, ?5)
         ON CONFLICT(project, stage, fp) DO UPDATE SET
           attempts = CASE WHEN ${fresh} THEN 1 ELSE agent_call_ledger.attempts + 1 END,
           first_at = CASE WHEN ${fresh} THEN excluded.first_at ELSE agent_call_ledger.first_at END,
           status = 'running', rc = NULL, runner = NULL, model = NULL,
           answer_body = NULL, answer_ref = NULL, answer_bytes = NULL,
           box = excluded.box, last_at = excluded.last_at
         WHERE ${fresh} OR ${runnable}`
      ).bind(k.project, k.stage, k.fp, box, t, sinceWin, sinceTtl, max, replay).run();
      const changed = !!(res.meta && res.meta.changes);
      const row = await readRow(env, k, !changed && replay === 1);
      if (!row) return json(500, { error: "the ledger row is missing after the upsert" });
      const out = {
        status: row.status, attempts: Number(row.attempts), rc: row.rc === null ? null : Number(row.rc),
        runner: row.runner, model: row.model, checkpoint: row.checkpoint, age_s: ageS(t, row.last_at), as_of: t,
      };
      if (changed) return json(200, { decision: "run", ...out });
      if (row.status === "ok" && replay === 1) {
        return json(200, {
          decision: "replay", ...out,
          answer_body: row.answer_body === undefined ? null : row.answer_body,
          answer_ref: row.answer_ref, answer_bytes: row.answer_bytes,
        });
      }
      return json(200, { decision: "terminal", ...out });
    },
  ],

  [
    "POST", "/api/agent-call-ledger/finish",
    async ({ env, t, body }) => {
      await ensureTable(env, "agent_call_ledger");
      const k = key(body);
      if (!k.project || !k.stage || !k.fp) return json(400, { error: "project, stage and fp are required" });
      const status = str(body.status, 16);
      const checkpoint = str(body.checkpoint, 500);
      if (status === null) {
        if (checkpoint === null) return json(400, { error: "status or checkpoint is required" });
        const res = await env.DB.prepare(
          "UPDATE agent_call_ledger SET checkpoint=?4, last_at=?5 WHERE project=?1 AND stage=?2 AND fp=?3"
        ).bind(k.project, k.stage, k.fp, checkpoint, t).run();
        return json(200, { settled: !!(res.meta && res.meta.changes), checkpoint, as_of: t });
      }
      if (!FINISH.has(status)) return json(400, { error: "status must be ok, empty, failed, unbilled or parked" });
      const rc = body.rc === null || body.rc === undefined ? null : wholeInt(body.rc, 0, 255);
      if (body.rc !== null && body.rc !== undefined && rc === null) return json(400, { error: "rc must be 0..255" });
      const answerBody = typeof body.answer_body === "string" && body.answer_body !== "" ? body.answer_body : null;
      const answerBytes = answerBody === null ? null : new TextEncoder().encode(answerBody).length;
      if (answerBytes !== null && answerBytes > ANSWER_BYTES_MAX) {
        return json(413, { error: `answer_body is ${answerBytes} bytes, over ${ANSWER_BYTES_MAX}` });
      }
      const sentBytes = wholeInt(body.answer_bytes, 0, Number.MAX_SAFE_INTEGER);
      const answerRef = str(body.answer_ref, 500);
      // An ok row with nothing to hand back is not an answer: the reader treats
      // it as a miss, so it is stored, never refused (D11: blank is a miss).
      const res = await env.DB.prepare(
        `UPDATE agent_call_ledger SET
           status=?4, rc=?5, runner=?6, model=?7, answer_body=?8, answer_ref=?9, answer_bytes=?10,
           checkpoint=COALESCE(?11, checkpoint),
           attempts = CASE WHEN ?4='unbilled' THEN MAX(attempts - 1, 0) ELSE attempts END,
           last_at=?12
         WHERE project=?1 AND stage=?2 AND fp=?3`
      ).bind(k.project, k.stage, k.fp, status, rc, str(body.runner, 32), str(body.model, 128),
        answerBody, answerRef, answerBytes === null ? sentBytes : answerBytes,
        checkpoint, t).run();
      return json(200, { settled: !!(res.meta && res.meta.changes), status, as_of: t });
    },
  ],

  [
    "GET", "/api/agent-call-ledger",
    async ({ env, url, t }) => {
      await ensureTable(env, "agent_call_ledger");
      const k = key(Object.fromEntries(url.searchParams));
      if (!k.project || !k.stage || !k.fp) return json(400, { error: "project, stage and fp are required" });
      const row = await readRow(env, k, url.searchParams.get("body") === "1");
      return json(200, { row: row || null, as_of: t });
    },
  ],

  [
    "DELETE", "/api/agent-call-ledger",
    async ({ env, url, t }) => {
      await ensureTable(env, "agent_call_ledger");
      const k = key(Object.fromEntries(url.searchParams));
      if (!k.project || !k.stage || !k.fp) return json(400, { error: "project, stage and fp are required" });
      const actor = str(url.searchParams.get("actor"), 64) || "unknown";
      const reason = str(url.searchParams.get("reason"), 400) || "manual reset";
      const res = await env.DB.prepare(
        `UPDATE agent_call_ledger SET status='reset', note=?4 || ' (was ' || status || ')', last_at=?5
          WHERE project=?1 AND stage=?2 AND fp=?3`
      ).bind(k.project, k.stage, k.fp, `reset by ${actor} at ${t}: ${reason}`, t).run();
      return json(200, { reset: Number((res.meta && res.meta.changes) || 0), as_of: t });
    },
  ],
];

// transcripts routes — the conversation behind a job row.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  TRANSCRIPT_MAX_BYTES, TRANSCRIPT_INDEX_COLS, str,
} from "../lib/core.js";

export const routes = [
  // ── Transcripts: the conversation behind a row ─────────────────────────
  // Every jobs row is one headless agent session. bin/agent-call.sh pushes
  // the rendered, scrubbed transcript of each ATTEMPT here as the attempt
  // ends, so Mission Control can answer "what was the model actually doing"
  // without ssh into a box that may have been recycled since.
  //
  // WRITE IS BEARER-ONLY AND POST-ONLY. The console's Pages proxy passes GET
  // (plus the one PUT /api/flags), so nothing in a browser can author a
  // transcript — a fabricated session on a real job would be the worst kind
  // of evidence, the kind that looks like a record.
  [
    "POST", /^\/api\/jobs\/([^/]+)\/transcript$/,
    async ({ env, t, body, m: trMatch }) => {
      const id = decodeURIComponent(trMatch[1]);
      const job = await env.DB.prepare("SELECT id FROM jobs WHERE id=?1").bind(id).first();
      // Same reason as artifacts and phases: a transcript whose job does not
      // exist is invisible on every screen that starts from a job. 404 is the
      // honest answer and the pusher is fail-open, so it costs the stage nothing.
      if (!job) return json(404, { error: "no such job" });
      let bodyText = typeof body.body === "string" ? body.body : "";
      if (!bodyText.trim()) return json(400, { error: "body must be a non-empty transcript" });
      // TAIL, not reject — see TRANSCRIPT_MAX_BYTES.
      let truncated = body.truncated === true || body.truncated === 1 || body.truncated === "1" ? 1 : 0;
      if (bodyText.length > TRANSCRIPT_MAX_BYTES) {
        bodyText = bodyText.slice(bodyText.length - TRANSCRIPT_MAX_BYTES);
        truncated = 1;
      }
      // A non-integer phase_id lands as 0 ("no phase row") rather than as a
      // 400: the pusher runs on a lane that may legitimately have no phase, and
      // rejecting the push would lose a real transcript over an absent id.
      const phaseId = Number.isInteger(Number(body.phase_id)) && Number(body.phase_id) > 0
        ? Number(body.phase_id) : 0;
      const attempt = Number.isInteger(Number(body.attempt)) && Number(body.attempt) > 0
        ? Number(body.attempt) : 1;
      const str = (v, n) => (v === undefined || v === null || v === "" ? null : String(v).slice(0, n));
      const redactions = Number.isFinite(Number(body.redactions)) ? Math.max(0, Math.trunc(Number(body.redactions))) : 0;
      await env.DB.prepare(
        `INSERT INTO job_transcripts
           (job_id, phase_id, attempt, stage, runner, model, source, bytes, truncated, redactions, body, actor, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?13)
         ON CONFLICT(job_id, phase_id, attempt) DO UPDATE SET
           stage=COALESCE(?4, stage), runner=COALESCE(?5, runner), model=COALESCE(?6, model),
           source=?7, bytes=?8, truncated=?9, redactions=?10, body=?11,
           actor=COALESCE(?12, actor), updated_at=?13`
      ).bind(id, phaseId, attempt, str(body.stage, 64), str(body.runner, 64), str(body.model, 128),
        str(body.source, 32) || "unknown", bodyText.length, truncated, redactions, bodyText,
        str(body.actor, 128), t).run();
      // The stored row WITHOUT its body: the pusher has the text already, and
      // echoing 150KB back onto a box that is mid-build is pure cost.
      // sql-ident-ok: TRANSCRIPT_INDEX_COLS is an export const column list in lib/core.js
      const row = await env.DB.prepare(
        `SELECT ${TRANSCRIPT_INDEX_COLS} FROM job_transcripts
          WHERE job_id=?1 AND phase_id=?2 AND attempt=?3`
      ).bind(id, phaseId, attempt).first();
      return json(200, { transcript: row });
    },
  ],

  // The index: what this job has on file, no bodies. Same shape the detail
  // page already receives, exposed on its own so a reader can poll it.
  [
    "GET", /^\/api\/jobs\/([^/]+)\/transcripts$/,
    async ({ env, t, m: trListMatch }) => {
      const id = decodeURIComponent(trListMatch[1]);
      // sql-ident-ok: TRANSCRIPT_INDEX_COLS is an export const column list in lib/core.js
      const rows = await env.DB.prepare(
        `SELECT ${TRANSCRIPT_INDEX_COLS} FROM job_transcripts WHERE job_id=?1
          ORDER BY phase_id ASC, attempt ASC LIMIT 100`
      ).bind(id).all();
      return json(200, { job_id: id, transcripts: rows.results || [], as_of: t });
    },
  ],

  // ONE body, by (phase_id, attempt). A 404 here means exactly what it says —
  // this attempt pushed no transcript — and the console renders that as its
  // own honest empty state rather than as a load error.
  [
    "GET", /^\/api\/jobs\/([^/]+)\/transcript$/,
    async ({ env, url, t, m: trMatch }) => {
      const id = decodeURIComponent(trMatch[1]);
      const phaseId = Number.isInteger(Number(url.searchParams.get("phase_id")))
        ? Number(url.searchParams.get("phase_id")) : 0;
      const attempt = Number.isInteger(Number(url.searchParams.get("attempt")))
        && Number(url.searchParams.get("attempt")) > 0
        ? Number(url.searchParams.get("attempt")) : 1;
      const row = await env.DB.prepare(
        "SELECT * FROM job_transcripts WHERE job_id=?1 AND phase_id=?2 AND attempt=?3"
      ).bind(id, phaseId, attempt).first();
      if (!row) return json(404, { error: "no transcript for this attempt" });
      return json(200, { transcript: row, as_of: t });
    },
  ],
];

// web-task human-step routes — a person completes a 2FA step of a web-task
// run (BH-7598, slice C0). Contract, decision tables and operator steps:
// docs/notes/2026-10-23-BH-7598-web-task-human.md. Table:
// schema.d/202610251632-bh-7598-web-task-human.sql. Client: bin/lib/web-human.sh.
//
// Every route is behind the bearer (HARNESS_SECRET).
//
// POST /api/web-task/human/ask {run_id, machine, project, site, kind, prompt}   a lane-run machine
//   Header x-web-vault-run-token, checked by web-vault.js's readRefusal (the
//   same run binding as a vault read). kind is code or approve. Three parallel
//   reads (the lane_runs row, the token row, the settings), then ONE batch:
//   the run's open step is set 'superseded' and the new step is inserted.
//   200 {step_id, nonce, wait_until, expires_at, poll_s, tg_chat, logins}.
//   The nonce is in this answer only; D1 keeps its SHA-256.
// POST /api/web-task/human/poll {run_id, machine, step_id, tg_outcome?, board_outcome?}   the same run
//   The same run check, and the step must be this run's. open: pending;
//   cancelled; superseded: 409 old_nonce; consumed: no code. answered: ONE
//   conditional UPDATE to consumed (a code's ciphertext set to NULL in it), and
//   only when it changed one row the answer carries the action (and the code).
//   tg_outcome / board_outcome are written once, the first time they are given.
// POST /api/web-task/answer   the operator, through any bearer holder
//   Body: {run_id, step_id, nonce, action: done|cancel|code, code?, via?}, or
//   a forwarded Telegram update: {callback_query: {data: "wt:<step>:<nonce>:d|c"}},
//   or {message: {text: <code>, reply_to_message: {text|caption: "...\nref: wt:<step>:<nonce>"}}}.
//   First failing check wins: 400 bad form; 403 bad_nonce; 403 other_run;
//   409 old_nonce; 409 already_answered; 410 expired; 400 kind mismatch; 503
//   key missing. Else ONE conditional UPDATE (status='open', not expired).
//   The answer never echoes the code.
//   The resume enqueue (BH-8360, settings row web_task.resume_enqueue,
//   default 0 = off): with 1 and an 'answered' status, the UPDATE and a guarded
//   INSERT run as ONE batch. The INSERT copies the asking run's args_json into
//   a new queued web-task lane run (enqueued_by 'web-task-resume:<step_id>')
//   only when the UPDATE changed one row and that run is web-task and done or
//   died. The 200 then adds resume: enqueued (with resume_run_id) or skipped
//   (with resume_why). A cancel never enqueues. With 0 the route is unchanged.
//   Note: docs/notes/2026-10-25-BH-8360-web-task-resume-enqueue.md.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { decryptValue, encryptValue } from "../lib/web-vault-crypto.js";
import { RUN_SQL, RUN_TOKEN_SQL, allowedSites, readRefusal, sameText, sha256Hex, siteName } from "./web-vault.js";

const KINDS = new Set(["code", "approve"]);
const VIAS = new Set(["api", "board", "telegram"]);
// Format bounds, not knobs: a prompt is one line of a Telegram caption and of
// a NEEDS-HUMAN comment; a code is what a person types from an SMS or an app.
const PROMPT_MAX_BYTES = 512;
const OUTCOME_MAX = 200;
const CODE_RE = /^[A-Za-z0-9-]{1,32}$/;
// 16 bytes, base64url: 22 characters, so "wt:<step>:<nonce>:d" fits the
// 64-byte Telegram callback_data.
const NONCE_BYTES = 16;
const ID_RE = /^[1-9]\d{0,15}$/;
const CALLBACK_RE = /^wt:([1-9]\d{0,15}):([A-Za-z0-9_-]{22}):([dc])$/;
// Line-anchored: a quoted ("> ref: ...") or mid-line ref is not a ref.
const REF_RE = /(?:^|\n)ref: wt:([1-9]\d{0,15}):([A-Za-z0-9_-]{22})[ \t]*(?:\n|$)/;
const CHAT_RE = /^-?\d{1,20}$/;
const LOGIN_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/;

// ?1 run id. idx_web_task_human_run.
export const SUPERSEDE_SQL = "UPDATE web_task_human_step SET status='superseded' WHERE run_id=?1 AND status='open'";
// ?1 run, ?2 project, ?3 site, ?4 kind, ?5 prompt, ?6 nonce hash, ?7 t, ?8 wait_until, ?9 expires_at.
export const INSERT_SQL = `INSERT INTO web_task_human_step (run_id, project, site, kind, prompt, nonce_hash, status, created_at, wait_until, expires_at)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8, ?9)`;
// uq_web_task_human_nonce.
export const STEP_BY_NONCE_SQL = "SELECT id, run_id, kind, status, expires_at FROM web_task_human_step WHERE nonce_hash=?1";
// The PRIMARY KEY.
export const STEP_SQL = "SELECT id, run_id, kind, status, wait_until, expires_at, code_ct, code_iv, key_id FROM web_task_human_step WHERE id=?1";
// ?1 id, ?2 status, ?3 t, ?4 via, ?5 ciphertext, ?6 iv, ?7 key id. The PRIMARY KEY.
export const ANSWER_SQL = `UPDATE web_task_human_step SET status=?2, answered_at=?3, answer_via=?4, code_ct=?5, code_iv=?6, key_id=?7
 WHERE id=?1 AND status='open' AND expires_at > ?3`;
// ?1 step id, ?2 t. Runs in the answer's batch right after ANSWER_SQL, so
// changes() is that UPDATE's: a lost answer inserts nothing. Both lookups are
// PRIMARY KEY; INSERT OR IGNORE meets lane_runs_live (one live run per lane
// and project).
export const RESUME_ENQUEUE_SQL = `INSERT OR IGNORE INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, status)
 SELECT o.lane, o.project, o.args_json, ?2, 'web-task-resume:' || s.id, 'queued'
 FROM web_task_human_step s JOIN lane_runs o ON o.id = s.run_id
 WHERE s.id = ?1 AND s.status = 'answered' AND o.lane = 'web-task' AND o.status IN ('done','died') AND changes() = 1`;
// ?1 the asking run's id, read only when the enqueue inserted nothing. One row
// by PRIMARY KEY; the inner lookup is one probe of lane_runs_live.
export const RESUME_SKIP_SQL = `SELECT o.lane, o.status,
 (SELECT l.id FROM lane_runs l WHERE l.lane = o.lane AND l.project = o.project AND l.status IN ('queued','claimed')) AS live_id
 FROM lane_runs o WHERE o.id = ?1`;
// ?1 id, ?2 t. Used once: the ciphertext goes in the same UPDATE.
export const CONSUME_SQL = `UPDATE web_task_human_step SET status='consumed', code_ct=NULL, code_iv=NULL, consumed_at=?2
 WHERE id=?1 AND status='answered'`;
// ?1 id, ?2 tg_outcome, ?3 board_outcome. A set outcome is never overwritten.
export const OUTCOME_SQL = "UPDATE web_task_human_step SET tg_outcome=COALESCE(tg_outcome, ?2), board_outcome=COALESCE(board_outcome, ?3) WHERE id=?1";

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const b64url = (u8) => btoa(String.fromCharCode(...u8)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const aadOf = (id) => `web-task-human:${id}`;
const refused = (status, why) => json(status, { error: "refused", refused: why });

function idOf(v) {
  const s = typeof v === "number" || typeof v === "string" ? String(v).trim() : "";
  return ID_RE.test(s) ? Number(s) : null;
}

function promptError(v) {
  if (typeof v !== "string") return "prompt is required: a string";
  if (typeof v.isWellFormed === "function" && !v.isWellFormed()) return "prompt is not well-formed text";
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(v)) return "prompt is one line: no control characters";
  const n = new TextEncoder().encode(v).length;
  if (!v.trim() || n > PROMPT_MAX_BYTES) return `prompt must be 1..${PROMPT_MAX_BYTES} bytes`;
  return null;
}

function outcomeOf(v) {
  if (v === undefined || v === null) return { value: null };
  if (typeof v !== "string" || !v || v.length > OUTCOME_MAX) return { error: `an outcome is a string of 1..${OUTCOME_MAX} characters` };
  return { value: v };
}

// The claimed-run check of ask and poll: the presented run token, the lane_runs
// row and the token row. -> {run, why} where why is a readRefusal value or null.
async function runCheck(req, env, runId, machine, more) {
  const presented = req.headers.get("x-web-vault-run-token") || "";
  const [run, tok, hash, ...rest] = await Promise.all([
    env.DB.prepare(RUN_SQL).bind(runId).first(),
    env.DB.prepare(RUN_TOKEN_SQL).bind(runId).first(),
    sha256Hex(presented),
    ...more,
  ]);
  const tokenOk = !!(presented && tok && tok.machine === machine && sameText(hash, String(tok.token_hash)));
  return { run, tokenOk, rest };
}

// A Telegram chat id from the lane-alert DM row, or null (never a guess).
function chatOf(byKey) {
  const row = byKey.get("lib.lane-alert.lane_alert_dm_chat");
  const s = row && row.value !== null && row.value !== undefined ? String(row.value).trim() : "";
  return CHAT_RE.test(s) ? s : null;
}
// The logins of web_task.human_logins; the code default is [] (no board answers).
function loginsOf(byKey) {
  const row = byKey.get("web_task.human_logins");
  if (!row || row.value === null || row.value === undefined) return [];
  return String(row.value).split(",").map((s) => s.trim()).filter((s) => LOGIN_RE.test(s));
}

// The resume enqueue switch: row web_task.resume_enqueue, 0..1; any
// other value and the code default are 0 (off).
function resumeEnqueueOn(byKey) {
  return intSetting(byKey, "web_task.resume_enqueue", 0, 0, 1) === 1;
}

// Why the resume enqueue inserted nothing, from RESUME_SKIP_SQL's row.
function skipWhy(o) {
  if (!o || o.lane !== "web-task") return "not_web_task";
  if (o.status === "queued" || o.status === "claimed") return "run_live";
  if (o.live_id !== null && o.live_id !== undefined) return "already_live";
  return "not_enqueued";
}

// The answer body -> {stepId, nonce, action, code, runId, via} or {error}.
// runId is null for a Telegram form: the run comes from the step row.
export function parseAnswer(b) {
  if (!b || typeof b !== "object") return { error: "body is required" };
  if (b.callback_query !== undefined) {
    const data = b.callback_query && typeof b.callback_query.data === "string" ? b.callback_query.data : "";
    const m = CALLBACK_RE.exec(data);
    if (!m) return { error: "callback_query.data is not wt:<step>:<nonce>:d|c" };
    return { stepId: Number(m[1]), nonce: m[2], action: m[3] === "d" ? "done" : "cancel", code: null, runId: null, via: "telegram" };
  }
  if (b.message !== undefined) {
    const msg = b.message || {};
    const reply = msg.reply_to_message || {};
    const quoted = typeof reply.text === "string" ? reply.text : typeof reply.caption === "string" ? reply.caption : "";
    const m = REF_RE.exec(quoted);
    if (!m) return { error: "message is not a reply to a web-task ask (no ref: line)" };
    const code = typeof msg.text === "string" ? msg.text.trim() : "";
    if (!CODE_RE.test(code)) return { error: "a code is 1..32 letters, digits or dashes" };
    return { stepId: Number(m[1]), nonce: m[2], action: "code", code, runId: null, via: "telegram" };
  }
  const stepId = idOf(b.step_id), runId = idOf(b.run_id);
  if (stepId === null || runId === null) return { error: "run_id and step_id are required: positive integers" };
  if (typeof b.nonce !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(b.nonce)) return { error: "nonce is required" };
  if (!["done", "cancel", "code"].includes(b.action)) return { error: "action is done, cancel or code" };
  const via = b.via === undefined ? "api" : b.via;
  if (!VIAS.has(via)) return { error: "via is api, board or telegram" };
  let code = null;
  if (b.action === "code") {
    code = typeof b.code === "string" ? b.code.trim() : "";
    if (!CODE_RE.test(code)) return { error: "a code is 1..32 letters, digits or dashes" };
  }
  return { stepId, nonce: b.nonce, action: b.action, code, runId, via };
}

export const routes = [
  [
    "POST", "/api/web-task/human/ask",
    ({ req, env, t, body }) => d1Guarded("web_task_human_step", async () => {
      const b = body || {};
      const project = laneName(b.project), site = siteName(b.site), machine = laneName(b.machine), runId = idOf(b.run_id);
      if (!project || !site || !machine || runId === null) return json(400, { error: "run_id, machine, project and site are required" });
      if (!KINDS.has(b.kind)) return json(400, { error: "kind is code or approve" });
      const perr = promptError(b.prompt);
      if (perr) return json(400, { error: perr });
      const { run, tokenOk, rest: [{ byKey }] } = await runCheck(req, env, runId, machine, [settingsRows(env)]);
      const why = readRefusal(run, { project, site, machine, t, allowed: allowedSites(byKey, project), tokenOk });
      if (why) return refused(403, why);
      const now = Date.parse(t);
      // Fallbacks name their rows: web_task.human_wait_s, _poll_s, _answer_ttl_s.
      const waitS = intSetting(byKey, "web_task.human_wait_s", 300, 10, 3600);
      const pollS = intSetting(byKey, "web_task.human_poll_s", 5, 1, 60);
      const ttlS = intSetting(byKey, "web_task.human_answer_ttl_s", 86400, 60, 604800);
      const waitUntil = iso(now + waitS * 1000), expiresAt = iso(now + Math.max(waitS, ttlS) * 1000);
      const nonce = b64url(crypto.getRandomValues(new Uint8Array(NONCE_BYTES)));
      const res = await env.DB.batch([
        env.DB.prepare(SUPERSEDE_SQL).bind(runId),
        env.DB.prepare(INSERT_SQL).bind(runId, project, site, b.kind, b.prompt, await sha256Hex(nonce), t, waitUntil, expiresAt),
      ]);
      const stepId = Number(res[1] && res[1].meta && res[1].meta.last_row_id);
      if (!stepId) return json(503, { error: "web_task_human_step insert gave no id" });
      return json(200, { step_id: stepId, nonce, wait_until: waitUntil, expires_at: expiresAt, poll_s: pollS, tg_chat: chatOf(byKey), logins: loginsOf(byKey) });
    }),
  ],
  [
    "POST", "/api/web-task/human/poll",
    ({ req, env, t, body }) => d1Guarded("web_task_human_step", async () => {
      const b = body || {};
      const machine = laneName(b.machine), runId = idOf(b.run_id), stepId = idOf(b.step_id);
      if (!machine || runId === null || stepId === null) return json(400, { error: "run_id, machine and step_id are required" });
      const tg = outcomeOf(b.tg_outcome), board = outcomeOf(b.board_outcome);
      if (tg.error || board.error) return json(400, { error: tg.error || board.error });
      const { run, tokenOk, rest: [step] } = await runCheck(req, env, runId, machine, [env.DB.prepare(STEP_SQL).bind(stepId).first()]);
      // The run checks of readRefusal; project and site were checked at the ask.
      const why = readRefusal(run, { project: run ? run.project : "", site: "-", machine, t, allowed: ["-"], tokenOk });
      if (why) return refused(403, why);
      if (!step) return refused(404, "no_step");
      if (Number(step.run_id) !== runId) return refused(403, "other_run");
      if (tg.value !== null || board.value !== null) await env.DB.prepare(OUTCOME_SQL).bind(stepId, tg.value, board.value).run();
      if (step.status === "open") return json(200, { state: "pending", wait_until: step.wait_until, expires_at: step.expires_at });
      if (step.status === "cancelled") return json(200, { state: "cancelled" });
      if (step.status === "consumed") return json(200, { state: "consumed" });
      if (step.status === "superseded") return refused(409, "old_nonce");
      let code = null;
      if (step.kind === "code") {
        const dec = await decryptValue(env, step.key_id, aadOf(stepId), step.code_iv, step.code_ct);
        if (!dec.ok) return json(503, { error: dec.why === "key missing" ? "key_missing" : "decrypt_failed" });
        code = dec.value;
      }
      // The code leaves only after the UPDATE that NULLs its ciphertext changed one row.
      const r = await env.DB.prepare(CONSUME_SQL).bind(stepId, t).run();
      if (!r || !r.meta || r.meta.changes !== 1) return refused(409, "already_consumed");
      return json(200, step.kind === "code" ? { state: "answered", action: "code", code } : { state: "answered", action: "done" });
    }),
  ],
  [
    "POST", "/api/web-task/answer",
    ({ env, t, body }) => d1Guarded("web_task_human_step", async () => {
      const p = parseAnswer(body);
      if (p.error) return json(400, { error: p.error });
      const [row, { byKey }] = await Promise.all([
        env.DB.prepare(STEP_BY_NONCE_SQL).bind(await sha256Hex(p.nonce)).first(),
        settingsRows(env),
      ]);
      if (!row || Number(row.id) !== p.stepId) return refused(403, "bad_nonce");
      if (p.runId !== null && Number(row.run_id) !== p.runId) return refused(403, "other_run");
      if (row.status === "superseded") return refused(409, "old_nonce");
      if (row.status !== "open") return refused(409, "already_answered");
      if (String(row.expires_at) <= t) return refused(410, "expired");
      if (p.action === "code" && row.kind !== "code") return json(400, { error: "a code answers a code step only" });
      if (p.action === "done" && row.kind !== "approve") return json(400, { error: "done answers an approve step; a code step needs the code" });
      let ct = null, iv = null, keyId = null;
      if (p.action === "code") {
        keyId = intSetting(byKey, "web_vault.key_id", 1, 1, 999);
        const enc = await encryptValue(env, keyId, aadOf(row.id), p.code);
        if (!enc.ok) return json(503, { error: enc.why === "key missing" ? "key_missing" : "encrypt_failed" });
        ct = enc.ciphertext; iv = enc.iv;
      }
      const status = p.action === "cancel" ? "cancelled" : "answered";
      const answerStmt = env.DB.prepare(ANSWER_SQL).bind(row.id, status, t, p.via, ct, iv, keyId);
      if (status !== "answered" || !resumeEnqueueOn(byKey)) {
        const r = await answerStmt.run();
        if (!r || !r.meta || r.meta.changes !== 1) return refused(409, "already_answered");
        return json(200, { ok: true, step_id: Number(row.id), status });
      }
      const [r, e] = await env.DB.batch([answerStmt, env.DB.prepare(RESUME_ENQUEUE_SQL).bind(row.id, t)]);
      if (!r || !r.meta || r.meta.changes !== 1) return refused(409, "already_answered");
      const base = { ok: true, step_id: Number(row.id), status };
      const newId = e && e.meta && e.meta.changes === 1 ? Number(e.meta.last_row_id) : 0;
      if (newId) return json(200, { ...base, resume: "enqueued", resume_run_id: newId });
      // The answer is recorded either way; a skipped enqueue never fails it.
      const o = await env.DB.prepare(RESUME_SKIP_SQL).bind(row.run_id).first();
      return json(200, { ...base, resume: "skipped", resume_run_id: null, resume_why: skipWhy(o) });
    }),
  ],
];

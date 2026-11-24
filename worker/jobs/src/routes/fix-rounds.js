// fix-rounds routes — BH-2670 (BH-2530.1): the fix-round job queue over
// `fix_round_jobs` (BH-2668, schema.sql).
//
// Same split as every other family here (BH-1195): src/index.js holds the
// ordered table, this file holds the bodies. The one client is
// bin/lib/fix-round-queue.sh, and the answers below are the shapes it parses:
// `.job` / `.duplicate` on enqueue, `.fix_round_jobs` on the list, 404 (none)
// and 409 (lost race / refused) on claim, finish and adopt. No lane sources
// that client yet; the resolver wiring is a later slice of #2530.
//
// Every write is ONE statement whose success is `meta.changes === 1`, and the
// answer is the row re-read after it:
//   enqueue  INSERT … ON CONFLICT DO NOTHING. The partial unique index
//            fix_round_jobs_open (one queued/claimed/done row per project,
//            cap_key) is the dedup, so two concurrent enqueues cannot both
//            write a paid round and there is no read-then-write window.
//   claim    CAS queued → claimed that names the box, walking at most
//            CLAIM_WALK candidates, oldest id first.
//   finish   CAS claimed → done, only by the box that holds the claim.
//   adopt    CAS done → adopted, so exactly one adopter wins.
// The helpers below are exported for routes/fix-round-requeue.js (BH-9906).
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, isoPlusSeconds, laneName } from "../lib/core.js";

// Protocol bounds the ticket fixes, not business parameters.
const RECORD_MAX = 256 * 1024; // bytes of UTF-8; over it is a 413, never sliced
const LIST_MAX = 500;
const CLAIM_WALK = 5;
// verify-timeout (BH-9906): the round's verify stage hit its time cap.
const RESULT_RE = /^(done|terminal|rebuild-fresh|setup-blocked \S+|box-paused \S+|verify-timeout( \S+)?)$/;
// cap_key is built by the resolver (br_rkey), so it is checked, not normalised.
const CAP_KEY_RE = /^[^\x00-\x1f\x7f]{1,200}$/;
const STATUSES = new Set(["queued", "claimed", "done", "adopted"]);

const bytes = (s) => new TextEncoder().encode(s).length;

// args is stored as JSON text; the answer hands back the array that was sent.
export function rowOut(r) {
  if (!r) return r;
  let args = r.args;
  try { args = JSON.parse(r.args); } catch { /* a row not written here: answer it raw */ }
  return { ...r, args };
}

// A body that is not a JSON object (null, an array, junk) reads as {}: every
// POST then answers 400 before touching the table.
export const obj = (b) => (b && typeof b === "object" && !Array.isArray(b) ? b : {});

export const posId = (v) => (Number.isInteger(v) && v > 0 ? v : 0);

// null/absent → { ok, value: null }; a string within the cap → { ok, value };
// a non-string → 400; over the cap → 413. Never truncated.
export function record(v, name) {
  if (v === undefined || v === null) return { value: null };
  if (typeof v !== "string") return { res: json(400, { error: `${name} must be a string or null` }) };
  const n = bytes(v);
  if (n > RECORD_MAX) return { res: json(413, { error: `${name} over 256 KB`, bytes: n, max: RECORD_MAX }) };
  return { value: v };
}

export const readRow = (env, id) =>
  env.DB.prepare("SELECT * FROM fix_round_jobs WHERE id=?1").bind(id).first();

export const routes = [
  // Enqueue. An open row for (project, cap_key) answers 200 duplicate and
  // writes nothing; an adopted row is history and a new round INSERTs (201).
  [
    "POST", "/api/fix-rounds",
    ({ env, t, body }) => d1Guarded("fix_round_jobs", async () => {
      const b = obj(body);
      const project = laneName(b.project);
      const box = laneName(b.box);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      if (typeof b.cap_key !== "string" || !CAP_KEY_RE.test(b.cap_key)) {
        return json(400, { error: "cap_key is required: 1-200 characters, no control characters" });
      }
      const args = b.args;
      if (!Array.isArray(args) || args.length !== 6 || !args.every((a) => typeof a === "string")) {
        return json(400, { error: "args must be an array of exactly 6 strings" });
      }
      // D11: absent is 0; anything but 0/1/true/false is refused, never coerced.
      let hotfix;
      if (b.hotfix === undefined || b.hotfix === 0 || b.hotfix === false) hotfix = 0;
      else if (b.hotfix === 1 || b.hotfix === true) hotfix = 1;
      else return json(400, { error: "hotfix must be 0, 1, true or false" });
      const rec = record(b.record_in, "record_in");
      if (rec.res) return rec.res;

      await ensureTable(env, "fix_round_jobs");
      const ins = await env.DB.prepare(
        `INSERT INTO fix_round_jobs (project, cap_key, box, args, record_in, hotfix,
                                     status, attempt, enqueued_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,'queued',0,?7,?7)
         ON CONFLICT DO NOTHING`
      ).bind(project, b.cap_key, box, JSON.stringify(args), rec.value, hotfix, t).run();
      const openRow = () => env.DB.prepare(
        `SELECT * FROM fix_round_jobs WHERE project=?1 AND cap_key=?2
           AND status IN ('queued','claimed','done') ORDER BY id DESC LIMIT 1`
      ).bind(project, b.cap_key).first();
      if (ins.meta.changes === 1) {
        const job = (ins.meta.last_row_id && await readRow(env, ins.meta.last_row_id)) || await openRow();
        return json(201, { job: rowOut(job), duplicate: false, as_of: t });
      }
      const job = await openRow();
      // changes 0 with no open row is not a duplicate of anything: say so.
      if (!job) return json(503, { error: "fix_round_jobs insert wrote nothing and no open row exists" });
      return json(200, {
        job: rowOut(job), duplicate: true, as_of: t,
        reason: `${project} ${b.cap_key} is already ${job.status}${job.claimed_by ? ` on ${job.claimed_by}` : ""}`,
      });
    }),
  ],

  // List. Optional equality filters, ORDER BY id, bounded at LIST_MAX with
  // `truncated` when more rows exist (D12). An explicit limit outside 1..500
  // is a 400, never clamped (D11).
  [
    "GET", "/api/fix-rounds",
    ({ env, url, t }) => d1Guarded("fix_round_jobs", async () => {
      const q = url.searchParams;
      const status = q.get("status");
      if (status !== null && !STATUSES.has(status)) {
        return json(400, { error: "status must be one of queued, claimed, done, adopted" });
      }
      let limit = LIST_MAX;
      if (q.has("limit")) {
        const raw = q.get("limit");
        limit = /^[0-9]+$/.test(raw) ? Number(raw) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer from 1 to ${LIST_MAX}` });
      }
      await ensureTable(env, "fix_round_jobs");
      const rows = await env.DB.prepare(
        `SELECT * FROM fix_round_jobs
         WHERE (?1 IS NULL OR project=?1) AND (?2 IS NULL OR cap_key=?2)
           AND (?3 IS NULL OR box=?3) AND (?4 IS NULL OR status=?4)
         ORDER BY id ASC LIMIT ?5`
      ).bind(q.get("project"), q.get("cap_key"), q.get("box"), status, limit + 1).all();
      const all = rows.results || [];
      return json(200, {
        fix_round_jobs: all.slice(0, limit).map(rowOut),
        truncated: all.length > limit, as_of: t,
      });
    }),
  ],

  // Claim. The oldest row addressed to `box`, by a CAS that also names the box,
  // so a box can never take another box's round even on a wrong candidate
  // read. `stale_min` re-offers a claim that went quiet; the cutoff comes from
  // the server clock, and junk or a non-positive value means no re-offer (D11).
  [
    "POST", "/api/fix-rounds/claim",
    ({ env, t, body }) => d1Guarded("fix_round_jobs", async () => {
      const b = obj(body);
      const box = laneName(b.box);
      if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      // Only a number (or a numeric string) is a threshold: Number(true) is 1,
      // and a boolean must not become a one-minute re-offer.
      const staleMin = typeof b.stale_min === "number" || typeof b.stale_min === "string"
        ? Number(b.stale_min) : NaN;
      const cutoff = Number.isFinite(staleMin) && staleMin > 0
        ? isoPlusSeconds(t, -staleMin * 60) : null;
      await ensureTable(env, "fix_round_jobs");
      const cands = await env.DB.prepare(
        `SELECT id FROM fix_round_jobs
         WHERE box=?1 AND (status='queued'
                           OR (status='claimed' AND ?2 IS NOT NULL AND updated_at <= ?2))
         ORDER BY id ASC LIMIT ?3`
      ).bind(box, cutoff, CLAIM_WALK).all();
      const ids = (cands.results || []).map((r) => r.id);
      if (!ids.length) return json(404, { error: "nothing queued", box });
      for (const id of ids) {
        const took = await env.DB.prepare(
          `UPDATE fix_round_jobs SET status='claimed', claimed_by=?2, claimed_at=?3,
             attempt=attempt+1, updated_at=?3
           WHERE id=?1 AND box=?2
             AND (status='queued' OR (status='claimed' AND ?4 IS NOT NULL AND updated_at <= ?4))`
        ).bind(id, box, t, cutoff).run();
        if (took.meta.changes === 1) {
          return json(200, { job: rowOut(await readRow(env, id)), claimed: true, as_of: t });
        }
      }
      return json(409, { error: "another claimant took every candidate", refused: true, scope: "fix-rounds", box });
    }),
  ],

  // Finish. done is stamped only from `claimed` by the box holding the claim.
  // Claim always sets claimed_by to the requesting box, so a stale claim is
  // re-offered to the same box, and a late finish from that box's older
  // session still succeeds: the claim records the box, not an attempt id.
  [
    "POST", "/api/fix-rounds/finish",
    ({ env, t, body }) => d1Guarded("fix_round_jobs", async () => {
      const b = obj(body);
      const id = posId(b.id);
      const box = laneName(b.box);
      if (!id) return json(400, { error: "id must be a positive integer" });
      if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      if (typeof b.result !== "string" || !RESULT_RE.test(b.result)) {
        return json(400, { error: "result must be done, terminal, rebuild-fresh, setup-blocked <token>, box-paused <token>, verify-timeout or verify-timeout <token>" });
      }
      const rec = record(b.record_out, "record_out");
      if (rec.res) return rec.res;
      await ensureTable(env, "fix_round_jobs");
      const moved = await env.DB.prepare(
        `UPDATE fix_round_jobs SET status='done', result=?2, record_out=?3, finished_at=?4, updated_at=?4
         WHERE id=?1 AND status='claimed' AND claimed_by=?5`
      ).bind(id, b.result, rec.value, t, box).run();
      const row = await readRow(env, id);
      if (moved.meta.changes === 1) return json(200, { job: rowOut(row), as_of: t });
      if (!row) return json(404, { error: "no such fix round", id });
      return json(409, {
        error: `finish refused: row is ${row.status}${row.claimed_by ? ` on ${row.claimed_by}` : ""}`,
        refused: true, scope: "fix-rounds", job: rowOut(row),
      });
    }),
  ],

  // Adopt. done → adopted, and nothing else: a second adopter gets 409.
  [
    "POST", "/api/fix-rounds/adopt",
    ({ env, t, body }) => d1Guarded("fix_round_jobs", async () => {
      const id = posId(obj(body).id);
      if (!id) return json(400, { error: "id must be a positive integer" });
      await ensureTable(env, "fix_round_jobs");
      const moved = await env.DB.prepare(
        `UPDATE fix_round_jobs SET status='adopted', adopted_at=?2, updated_at=?2
         WHERE id=?1 AND status='done'`
      ).bind(id, t).run();
      const row = await readRow(env, id);
      if (moved.meta.changes === 1) return json(200, { job: rowOut(row), as_of: t });
      if (!row) return json(404, { error: "no such fix round", id });
      return json(409, {
        error: `adopt refused: row is ${row.status}, not done`,
        refused: true, scope: "fix-rounds", job: rowOut(row),
      });
    }),
  ],
];

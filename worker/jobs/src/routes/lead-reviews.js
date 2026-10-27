// lead-reviews routes — BH-1949 (BH-1525.1): the request queue for the lead
// review job, over the lead_review_requests table BH-1948 shipped (schema.sql,
// and the self-create copy in CREATED_TABLES).
//
// The client is bin/lib/lead-reviews.sh; its header is the contract these
// routes answer. A request is keyed by (repo, pr, head_sha) and moves
// requested -> running (claim) -> done | superseded | failed (result), and a
// done row is stamped once when its verdict is promoted into /api/verdicts.
// Writing that verdict row is NOT this file's job: promotion only stamps.
//
// Two credentials, the verdicts split (BH-1525 r2): creating a request and
// stamping its promotion need the lead token on top of the bearer (one
// exception, a build's own in-build ask, inbuildAsk below); start,
// claim and result are the box's own writes and need the bearer only. A result is bound
// to the job that claimed the row and the head it was asked about, so a box
// can finish only the review it is actually running.
//
// BH-5400: a finished request can be sent back to `requested` for a re-review
// (POST /:id/reset, lead token). The reset is RECORDED (reset_count, reset_at)
// on whatever path made it: the claim that takes a requested row which was
// worked before (a raw-SQL reset) records it too, and clears the promoted stamp
// so ?promoted=0 lists the new result. The land lane keys a landing on the job
// that produced it and stamps with {job_id}, which this file refuses (409) once
// the row holds another job.
//
// BH-8512: a reset body may carry {append_notes} (<= 4000 chars; "" or null =
// absent). The note is appended to scope_notes after a newline in the SAME
// compare-and-set as the reset, pinned to the scope_notes read here, so the
// lead prompt's ## Scope notes carries it. review-tier: and review-mode: in it
// become = (BH-6967: only the enqueue writes those tokens). A note already in
// scope_notes is not appended again (a retry); one that would pass 4000 chars
// is not stored and the old notes are never cut. The answer then names
// notes: stored | present | no-room. A requested row takes the note in its
// own pinned UPDATE, with no reset recorded. A body with no note is today's
// reset, statement for statement.
//
// BH-5351 (BH-5348.2), who may hold a claim and for how long:
// - A claim (and a /start) stamps heartbeat_at, and POST /:id/heartbeat {job_id}
//   re-stamps it for the job that holds the running row (409 for anyone else).
//   A running row whose COALESCE(heartbeat_at, updated_at) is older than
//   staleWindow (settings lead_review_claim_stale_s, fallback 900) is taken by
//   the next claimer; the 200 names the old holder as `reclaimed_from`, and the
//   old job's /result and /heartbeat are 409 through the job_id binding.
// - A claim carrying x-participant-token is an enrolled machine's: it passes
//   participantAuth(req, env, 'lead-review') or is refused with its status and
//   `why`, and binds participant=<name>, box=participant:<name>. Without the
//   header it is the bearer box claim, which still needs a body `box`.
// - Separation of duties compares the claimer to head_authors only (recorded
//   at create; bin/lead-review-enqueue.sh puts the build and fix-round
//   identities there). Named = 409 `self-review refused`. A participant on a
//   row with no readable head_authors is 409 `authorship unknown`. A box claim
//   is checked only when settings lead_review_sod_boxes is 1.
// - Every refused participant or SoD claim tries one stage_events row (stage
//   lead-review, verdict participant_refused | sod_refused); the answer says
//   event_logged true or false, and is never a 200 either way.
//
// BH-5779, a running row nobody claims again:
// - POST /api/lead-reviews/reclaim-stale (lead token) takes back every running
//   row whose COALESCE(heartbeat_at, updated_at) is older than the deadline
//   (BH-8579 below sets it), floored at staleWindow so it never undercuts the
//   claim takeover.
//   Under the cap (BH-8579 below) the row goes back to `requested` and the
//   reset is recorded; at the cap it goes to `failed` with its detail, and the
//   failed rung's bounded retry ladder owns it from there.
// - Each row is ONE compare-and-set pinned to the job, the beat and the
//   stale_reclaims the sweep read, so a claim or a heartbeat that lands first wins and the row is not
//   listed. At most LIST_MAX rows a call; `truncated` says more are left.
// - A reclaimed `requested` row clears job_id, so the old job's /result and
//   /heartbeat answer 409 through the existing `row.job_id !== job_id` binding.
//   A `failed` row keeps job_id: a late /result from that job is still bound
//   to it, and /reset treats the row as finished.
// - jobLive is NOT used: this is a heartbeat deadline, not the /start takeover.
//
// BH-8579, a failed job releases its request (lib/lead-review-release.js):
// - The sweep also takes a running row whose bound job ended failed, abandoned
//   or budget_stopped more than one beat interval (staleWindow / 3) ago, when
//   no request heartbeat arrived after the job ended. Detail `job failed: ...`.
// - abandoned and budget_stopped are terminal: that row (on either path) goes
//   straight to `failed`, reason job-terminal, detail `job terminal: ...`. It
//   is never requeued, so a budget stop never buys a second paid review.
// - The deadline is settings lead_review.stale_running_min (minutes, fallback
//   15), else lead_review_running_deadline_s, floored at staleWindow as above.
// - The cap is settings lead_review.release_max_resets (fallback 3) on
//   stale_reclaims: under it a row goes back to `requested` (a reset is
//   recorded); at it the row goes to `failed`, job_id kept.
// - Before either, a pr_records fact field stamped after the request was
//   created that says closed/merged or another head makes the row
//   `superseded` (no counter moves, job_id kept).
// - Each listed entry adds reason (stale | job-failed | job-terminal |
//   pr-closed | head-moved), detail, releases and cap; the answer adds cap.
//
// BH-7792, a finished paid review is never lost to a rebind:
// - /result from a job the row is not bound to lands when it is a done verdict
//   of this head from a lead_review job of this head's key that is running or
//   done, and the row has no result yet (rebindResult). Anything else is 409.
// - POST /:id/release {job_id, detail?} (bearer): the holder of a running
//   claim puts it back to requested, with no reset counted.
//
// A missing id is `no such lead review request`, never the worker's own
// unknown-endpoint body: lr_get reads THAT one as "not deployed" (rc 75).
import { d1Guarded, json } from "../lib/http.js";
import { JOBS_SELECT, OPEN_STATUS, decorateJob, ensureColumns, ensureTable, isoPlusSeconds } from "../lib/core.js";
import { participantAuth, staleWindow } from "./participants.js";
import { releaseSweep } from "../lib/lead-review-release.js";
import { REPO_RE, VERDICT_WORDS, leadTokenOk, optStr, prOf, shaOf } from "./verdicts.js";

export const LR_STATUSES = ["requested", "running", "done", "superseded", "failed"];
const LR_OUTCOMES = ["done", "superseded", "failed"];
const LIST_MAX = 100;
const PRIORITY_MAX = 1000;
const AUTHORS_MAX = 16;
// BH-7711: one PR's requests. Equality on repo and pr (never `?2 IS NULL OR`)
// is what lets SQLite search the autoindex of the UNIQUE(repo, pr, head_sha)
// key. The other binds are the list's, unchanged.
export const LR_LIST_PR_SQL =
  "SELECT rowid AS lr_rowid, * FROM lead_review_requests" +
  " WHERE repo = ?2 AND pr = ?7" +
  " AND (?1 IS NULL OR status IN (SELECT value FROM json_each(?1)))" +
  " AND (?4 IS NULL OR promoted_verdict_at IS NULL)" +
  " AND (?5 IS NULL OR created_at > ?5 OR (created_at = ?5 AND rowid > ?6))" +
  " ORDER BY created_at, rowid LIMIT ?3";
const NO_LEAD = "needs the lead verdict token (x-lead-verdict-token); HARNESS_SECRET alone may only claim and report";

// BH-4955: a `running` row whose job has shown no sign of life for this long is
// taken over by /start. 15 minutes is the ticket's number. It is a liveness
// protocol threshold, like the watchdog's caller-owned stale_min, not a
// business parameter, so it is not a settings row; a settings read with this as
// the fallback is the place to make it tunable.
const LR_START_STALE_S = 15 * 60;

// jobLive — the jobs watchdog's own judgement (routes/jobs.js stale_min):
// status running and activity_age_s (decorateJob: the newer of the last beat
// and updated_at) under the threshold. A null age is live, as the watchdog never
// counts null as stale: unknown evidence never steals a row. A job id with no
// jobs row is not live.
async function jobLive(env, job_id, t) {
  // sql-ident-ok: JOBS_SELECT is a constant from lib/core.js
  const raw = await env.DB.prepare(`${JOBS_SELECT} WHERE j.id=?1`).bind(job_id).first();
  if (!raw) return false;
  const job = decorateJob(raw, t);
  return job.status === OPEN_STATUS && (job.activity_age_s === null || job.activity_age_s < LR_START_STALE_S);
}

const getRow = (env, id) =>
  env.DB.prepare("SELECT * FROM lead_review_requests WHERE id=?1").bind(id).first();

// Every handler runs inside the guard and after the self-create, so a D1 fault
// is a 503 naming the table and a database the deploy reached first still works.
// ensureColumns adds `priority` (BH-5151) and `reset_count` / `reset_at`
// (BH-5400), all ADDED_COLUMNS, to a live table before any handler reads or
// writes them.
const guarded = (fn) => (ctx) =>
  d1Guarded("lead_review_requests", async () => {
    await ensureTable(ctx.env, "lead_review_requests");
    await ensureColumns(ctx.env, "lead_review_requests");
    return fn(ctx);
  });

// BH-5023: a build box holds the bearer but never the lead token, and it files
// the lead review request for the medium-risk head it just pushed
// (bin/inbuild-lead-review.sh). That one shape is allowed with the bearer alone:
// requested_by `inbuild:<box>:<KEY>`, and no priority (a box never jumps the
// queue). Matched untrimmed: the row stores requested_by as sent, and land keys
// its approve check on that exact prefix. The request is still only an ask; bin/lead-review-land.sh promotes
// it only when a builder APPROVE is bound to that head.
const INBUILD_BY = /^inbuild:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$/;
const inbuildAsk = (b) =>
  typeof b.requested_by === "string" && INBUILD_BY.test(b.requested_by)
  && (b.priority === undefined || b.priority === null || b.priority === 0);

// required string, 1..max after trim; null when it is not one
function reqStr(v, max) {
  const s = typeof v === "string" ? v.trim() : "";
  return s && s.length <= max ? s : null;
}

// head_authors on create: absent or null is none; anything else is an array of
// 1..16 strings, each 1..128 after trim, stored lowercased and de-duplicated (D17).
function headAuthorsOf(v) {
  if (v === undefined || v === null) return { v: null };
  const err = { err: `head_authors must be an array of 1..${AUTHORS_MAX} strings, each 1..128 chars` };
  if (!Array.isArray(v) || v.length < 1 || v.length > AUTHORS_MAX) return err;
  const out = [];
  for (const a of v) {
    const s = reqStr(a, 128);
    if (!s) return err;
    if (!out.includes(s.toLowerCase())) out.push(s.toLowerCase());
  }
  return { v: JSON.stringify(out) };
}

// The stored head_authors as a normalised list, or null when it is absent or
// does not parse as a non-empty array of strings: null is "unknown", never "nobody".
function parseAuthors(s) {
  if (s === null || s === undefined) return null;
  try {
    const v = JSON.parse(s);
    if (!Array.isArray(v) || !v.length || !v.every((a) => typeof a === "string")) return null;
    return v.map((a) => a.trim().toLowerCase());
  } catch { return null; }
}

// Separation of duties against head_authors only. Returns { why, matched } or null.
async function sodRefusal(env, row, participant, box) {
  const ids = participant ? [participant, `participant:${participant}`] : [box.trim().toLowerCase()];
  if (!participant) {
    const on = await env.DB.prepare("SELECT value FROM settings WHERE key='lead_review_sod_boxes'").first();
    if (String(on ? on.value : "").trim() !== "1") return null;
  }
  const authors = parseAuthors(row.head_authors);
  if (authors === null) return participant ? { why: "authorship unknown", matched: null } : null;
  const matched = ids.find((i) => authors.includes(i));
  return matched ? { why: "self-review refused", matched } : null;
}

// One stage_events row per refused claim, in its own try: a failed log never
// turns the refusal into anything else, and the answer says which happened.
async function logRefusal(env, t, job_id, verdict, actor, detail) {
  try {
    await env.DB.prepare(
      "INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?1,'lead-review',?2,?3,?4,?5)"
    ).bind(job_id, verdict, actor, JSON.stringify(detail), t).run();
    return { event_logged: true };
  } catch (e) {
    return { event_logged: false, event_error: String((e && e.message) || e).slice(0, 200) };
  }
}

// Pull the optional fields, refusing by name. Returns { err } or { v: {...} }.
function optFields(body, spec) {
  const v = {};
  for (const [key, max] of spec) {
    const r = optStr(body, key, max);
    if (!r.ok) return { err: r.err };
    v[key] = r.v;
  }
  return { v };
}

// rebindResult — BH-7792. A done result from a job the row is NOT bound to
// lands only when ALL of these hold, else null (the caller's 409 stands):
// - the outcome is done with a verdict (a failed or superseded outcome of a
//   rebound job buys nothing, so it is still refused);
// - the head is the row's head, and the row has no result yet (requested or
//   running): a recorded result is never replaced;
// - the poster is a jobs row of kind lead_review whose ticket is this head's
//   key lr-<pr>-<sha12> (job_open's key), with status running or done: a failed
//   job, a job of another head and an unknown job id stay refused.
// ONE compare-and-set pinned to the job and the status read here, so a result
// of the bound job that lands first wins and this one is the 409. The row is
// bound to the poster's job and box; the 200 names the job it took the row
// from as `rebound_from`.
async function rebindResult(env, t, row, job_id, head_sha, outcome, verdict, v) {
  if (outcome !== "done" || verdict === null) return null;
  if (row.head_sha !== head_sha || (row.status !== "running" && row.status !== "requested")) return null;
  const job = await env.DB.prepare("SELECT id, ticket_id, kind, status, box FROM jobs WHERE id=?1").bind(job_id).first();
  if (!job || job.kind !== "lead_review" || job.ticket_id !== `lr-${row.pr}-${head_sha.slice(0, 12)}`) return null;
  if (job.status !== OPEN_STATUS && job.status !== "done") return null;
  const res = await env.DB.prepare(
    `UPDATE lead_review_requests SET status='done', verdict=?1, report_ref=?2, reviewer_model=?3, detail=?4,
                                     job_id=?5, box=?6, participant=NULL, updated_at=?7
      WHERE id=?8 AND status=?9 AND job_id IS ?10`
  ).bind(verdict, v.report_ref, v.reviewer_model, v.detail, job_id, job.box ?? null, t, row.id, row.status, row.job_id ?? null).run();
  if (res.meta.changes !== 1) return null;
  return json(200, { request: await getRow(env, row.id), rebound_from: { job_id: row.job_id ?? null, box: row.box ?? null } });
}

export const routes = [
  [
    "POST", "/api/lead-reviews",
    guarded(async ({ req, env, t, body }) => {
      // The token first: a caller without it learns nothing about the payload,
      // except a build filing the request for its OWN head (BH-5023).
      const b = body || {};
      if (!leadTokenOk(req, env) && !inbuildAsk(b)) return json(403, { error: `creating a lead review request ${NO_LEAD}` });
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const pr = prOf(b.pr);
      if (pr === null) return json(400, { error: "pr must be a positive integer" });
      const head_sha = shaOf(b.head_sha);
      if (!head_sha) return json(400, { error: "head_sha must be a full 40-hex commit sha" });
      const o = optFields(b, [["scope_notes", 4000], ["prior_verdict_ref", 1000], ["requested_by", 128]]);
      if (o.err) return json(400, { error: o.err });
      // BH-5151: absent or null is no priority; anything else is an integer
      // 1..1000, refused outside it, never clamped or coerced from a string.
      const hasPriority = b.priority !== undefined && b.priority !== null;
      if (hasPriority && !(Number.isInteger(b.priority) && b.priority >= 1 && b.priority <= PRIORITY_MAX)) {
        return json(400, { error: `priority must be an integer 1..${PRIORITY_MAX}` });
      }
      const priority = hasPriority ? b.priority : null;
      const authors = headAuthorsOf(b.head_authors);
      if (authors.err) return json(400, { error: authors.err });

      const res = await env.DB.prepare(
        `INSERT INTO lead_review_requests (id, repo, pr, head_sha, scope_notes, prior_verdict_ref,
                                           requested_by, status, created_at, updated_at, priority, head_authors)
         VALUES (?1,?2,?3,?4,?5,?6,?7,'requested',?8,?8,?9,?10)
         ON CONFLICT(repo, pr, head_sha) DO NOTHING`
      ).bind(crypto.randomUUID(), repo, pr, head_sha, o.v.scope_notes, o.v.prior_verdict_ref,
             o.v.requested_by, t, priority, authors.v).run();
      const row = await env.DB.prepare(
        "SELECT * FROM lead_review_requests WHERE repo=?1 AND pr=?2 AND head_sha=?3"
      ).bind(repo, pr, head_sha).first();
      if (res.meta.changes === 1) return json(201, { request: row });
      // The key is taken. Same scope is the same ask (a retry); a different
      // scope on the same head is a different ask the key cannot hold.
      if ((row.scope_notes ?? null) === o.v.scope_notes) {
        // A retry that knows who wrote the head records it on a row that has
        // none; a recorded head_authors is never overwritten.
        let filled = false;
        if (authors.v !== null && row.head_authors == null) {
          await env.DB.prepare(
            "UPDATE lead_review_requests SET head_authors=?1 WHERE id=?2 AND head_authors IS NULL"
          ).bind(authors.v, row.id).run();
          filled = true;
        }
        // The same ask with a new priority re-orders a request still waiting,
        // instead of anyone backdating created_at by hand. A running or
        // finished row keeps what it had, and the caller sees that in the row.
        if (hasPriority && row.status === "requested" && row.priority !== priority) {
          await env.DB.prepare(
            "UPDATE lead_review_requests SET priority=?1, updated_at=?2 WHERE id=?3 AND status='requested'"
          ).bind(priority, t, row.id).run();
          return json(200, { request: await getRow(env, row.id), existing: true });
        }
        return json(200, { request: filled ? await getRow(env, row.id) : row, existing: true });
      }
      return json(409, { error: "a lead review request for this repo, pr and head_sha already exists with different scope_notes", request: row });
    }),
  ],

  // ?status=a,b&repo=&limit=&promoted=0 — oldest first, a work queue's order.
  // created_at is second-resolution, so the tie breaks on rowid (insertion
  // order), never on the random id. The limit is refused outside 1..100, never
  // clamped, and `truncated` is measured by reading one row past it.
  // promoted=0 (BH-1951) keeps only rows with no promoted_verdict_at, so the
  // hub's promotion lane is never starved by the 100 oldest, already-promoted
  // requests; any other value of promoted is a 400.
  // after=<created_at>,<rowid> (BH-5151) answers the rows past that one in the
  // same order, and a truncated page names its last row as `next_after`, so a
  // reader follows the cursor until truncated is false. (created_at, rowid)
  // never changes for a row, so no row is read twice across pages.
  // pr=<n> (BH-7711) needs repo and lists that one PR's requests through
  // LR_LIST_PR_SQL, which the UNIQUE(repo, pr, head_sha) autoindex serves.
  [
    "GET", "/api/lead-reviews",
    guarded(async ({ env, url, t }) => {
      const rawStatus = url.searchParams.get("status");
      const statuses = rawStatus ? rawStatus.split(",").map((s) => s.trim()) : [];
      const bad = statuses.find((s) => !LR_STATUSES.includes(s));
      if (bad !== undefined) return json(400, { error: `status must be a comma list of ${LR_STATUSES.join(", ")}` });
      const repo = (url.searchParams.get("repo") || "").trim();
      if (repo && !REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const rawPr = url.searchParams.get("pr");
      const pr = rawPr === null ? null : prOf(rawPr);
      if (rawPr !== null && pr === null) return json(400, { error: "pr must be a positive integer" });
      if (pr !== null && !repo) return json(400, { error: "pr needs repo" });
      const rawLimit = url.searchParams.get("limit");
      let limit = LIST_MAX;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
      }
      const rawPromoted = url.searchParams.get("promoted");
      if (rawPromoted !== null && rawPromoted !== "0") return json(400, { error: "promoted must be 0 (unpromoted rows only) or absent" });
      const rawAfter = url.searchParams.get("after");
      let afterAt = null, afterRow = null;
      if (rawAfter !== null) {
        const cut = rawAfter.lastIndexOf(",");
        const at = cut < 0 ? "" : rawAfter.slice(0, cut).trim();
        const rid = cut < 0 ? "" : rawAfter.slice(cut + 1);
        if (!at || at.length > 64 || !/^\d+$/.test(rid)) {
          return json(400, { error: "after must be <created_at>,<rowid> as returned in next_after" });
        }
        afterAt = at; afterRow = Number(rid);
      }
      // ONE CONSTANT STATEMENT per shape (with or without pr): nothing is spliced into the SQL text. An absent
      // filter binds NULL and its clause is true; the status list travels as one
      // JSON array bound to ?1 and is unpacked by json_each.
      const binds = [statuses.length ? JSON.stringify(statuses) : null, repo || null, limit + 1, rawPromoted === "0" ? 1 : null,
                     afterAt, afterRow];
      const rows = (await (pr === null
        ? env.DB.prepare(
          "SELECT rowid AS lr_rowid, * FROM lead_review_requests" +
          " WHERE (?1 IS NULL OR status IN (SELECT value FROM json_each(?1)))" +
          " AND (?2 IS NULL OR repo = ?2)" +
          " AND (?4 IS NULL OR promoted_verdict_at IS NULL)" +
          " AND (?5 IS NULL OR created_at > ?5 OR (created_at = ?5 AND rowid > ?6))" +
          " ORDER BY created_at, rowid LIMIT ?3"
        ).bind(...binds)
        : env.DB.prepare(LR_LIST_PR_SQL).bind(...binds, pr)).all()).results || [];
      const page = rows.slice(0, limit);
      const truncated = rows.length > limit;
      const out = { requests: page.map(({ lr_rowid, ...r }) => r), truncated, as_of: t };
      if (truncated) out.next_after = `${page[limit - 1].created_at},${page[limit - 1].lr_rowid}`;
      return json(200, out);
    }),
  ],

  // BH-4955 (BH-4950.2): the box creates its row if it is missing and moves
  // it to running for its own job with ONE compare-and-set pinned to the
  // status and job_id it read, so a racing starter loses (409) instead of both
  // winning. Eligible: requested, superseded, running held by this job, or
  // running held by a job that is not live (the #4025 wedge /claim cannot
  // clear). done and failed are terminal: a done row is a review already paid
  // for. The lane opens its job before it calls start (#4956), so a loser of
  // the race sees the winner's job live; there is no second CAS and no loop.
  [
    "POST", "/api/lead-reviews/start",
    guarded(async ({ req, env, t, body }) => {
      // One participant path, the one that runs the role and SoD checks (D15).
      if (req.headers.has("x-participant-token")) return json(403, { error: "participant claims go through /claim" });
      const b = body || {};
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const pr = prOf(b.pr);
      if (pr === null) return json(400, { error: "pr must be a positive integer" });
      const head_sha = shaOf(b.head_sha);
      if (!head_sha) return json(400, { error: "head_sha must be a full 40-hex commit sha" });
      const job_id = reqStr(b.job_id, 128);
      if (!job_id) return json(400, { error: "job_id must be a string, 1..128 chars" });
      const box = reqStr(b.box, 64);
      if (!box) return json(400, { error: "box must be a string, 1..64 chars" });
      const o = optFields(b, [["scope_notes", 4000], ["requested_by", 128]]);
      if (o.err) return json(400, { error: o.err });

      const ins = await env.DB.prepare(
        `INSERT INTO lead_review_requests (id, repo, pr, head_sha, scope_notes, requested_by,
                                           status, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,'requested',?7,?7)
         ON CONFLICT(repo, pr, head_sha) DO NOTHING`
      ).bind(crypto.randomUUID(), repo, pr, head_sha, o.v.scope_notes,
             o.v.requested_by ?? `lead-review:${box}`, t).run();
      const created = ins.meta.changes === 1;
      const byKey = () => env.DB.prepare(
        "SELECT * FROM lead_review_requests WHERE repo=?1 AND pr=?2 AND head_sha=?3"
      ).bind(repo, pr, head_sha).first();
      const refuse = (row) => (row.status === "done" || row.status === "failed")
        ? json(409, { error: `lead review request is ${row.status}; a finished review is not started again`, request: row, terminal: true })
        : json(409, { error: `lead review request is ${row.status}${row.job_id ? ` (job ${row.job_id})` : ""}, and that job is live`, request: row });

      const row = await byKey();
      if (row.status === "done" || row.status === "failed") return refuse(row);
      if (row.status === "running" && row.job_id !== job_id && await jobLive(env, row.job_id, t)) return refuse(row);
      // verdict/report_ref/detail are written only by /result, which always
      // leaves running, so they are already NULL in every eligible state but
      // superseded, the one the takeover must clear.
      const res = await env.DB.prepare(
        `UPDATE lead_review_requests
            SET status='running', job_id=?1, box=?2, verdict=NULL, report_ref=NULL, detail=NULL, updated_at=?3, heartbeat_at=?3
          WHERE id=?4 AND status=?5 AND job_id IS ?6`
      ).bind(job_id, box, t, row.id, row.status, row.job_id ?? null).run();
      const now = await byKey();
      if (res.meta.changes === 1) return json(200, { request: now, created });
      return refuse(now);
    }),
  ],

  // BH-5779, BH-8579: the stale-running sweep (header above). One settings
  // statement, one constant SELECT, then one CAS per row; only the rows whose
  // CAS won are listed. The rule is lib/lead-review-release.js.
  [
    "POST", "/api/lead-reviews/reclaim-stale",
    guarded(async ({ req, env, t }) => {
      if (!leadTokenOk(req, env)) return json(403, { error: `reclaiming stale lead reviews ${NO_LEAD}` });
      return json(200, await releaseSweep(env, t, LIST_MAX));
    }),
  ],

  [
    "GET", /^\/api\/lead-reviews\/([^/]+)$/,
    guarded(async ({ env, m }) => {
      const row = await getRow(env, decodeURIComponent(m[1]));
      return row ? json(200, { request: row }) : json(404, { error: "no such lead review request" });
    }),
  ],

  // Auth, then separation of duties, then one compare-and-set: from requested,
  // a re-claim by the job that holds it, or (BH-5351) a running row of another
  // job whose heartbeat went quiet past staleWindow. Two claimers cannot both
  // see changes=1.
  // BH-5400: a requested row that carries a job, a verdict or a promoted stamp
  // was worked before and reset by something other than /reset (raw SQL), so
  // the same UPDATE records the reset and clears the stamp. Every SET reads the
  // row as it was before the UPDATE; an own-job re-claim of a running row is
  // not a reset.
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/claim$/,
    guarded(async ({ req, env, t, body, m }) => {
      const id = decodeURIComponent(m[1]);
      const b = body || {};
      const job_id = reqStr(b.job_id, 128);
      if (!job_id) return json(400, { error: "job_id must be a string, 1..128 chars" });
      let box, participant = null;
      if (req.headers.has("x-participant-token")) {
        const a = await participantAuth(req, env, "lead-review");
        if (!a.ok) {
          const ev = await logRefusal(env, t, job_id, "participant_refused", "participant:?", { request_id: id, why: a.why });
          return json(a.status, { error: a.why, ...ev });
        }
        participant = a.machine.name;
        box = `participant:${participant}`;
      } else {
        box = reqStr(b.box, 64);
        if (!box) return json(400, { error: "box must be a string, 1..64 chars" });
      }
      const before = await getRow(env, id);
      if (!before) return json(404, { error: "no such lead review request" });
      const sod = await sodRefusal(env, before, participant, box);
      if (sod) {
        const ev = await logRefusal(env, t, job_id, "sod_refused", participant ? `participant:${participant}` : box, {
          request_id: id, repo: before.repo, pr: before.pr, head_sha: before.head_sha, why: sod.why, matched: sod.matched,
        });
        return json(409, { error: sod.why, ...ev, request: before });
      }
      const cutoff = isoPlusSeconds(t, -(await staleWindow(env)));
      const res = await env.DB.prepare(
        `UPDATE lead_review_requests SET status='running', job_id=?1, box=?2, updated_at=?3, participant=?5, heartbeat_at=?3,
           reset_count = CASE WHEN status='requested' AND (job_id IS NOT NULL OR verdict IS NOT NULL OR promoted_verdict_at IS NOT NULL)
                              THEN COALESCE(reset_count, 0) + 1 ELSE reset_count END,
           reset_at = CASE WHEN status='requested' AND (job_id IS NOT NULL OR verdict IS NOT NULL OR promoted_verdict_at IS NOT NULL)
                           THEN ?3 ELSE reset_at END,
           promoted_verdict_at = CASE WHEN status='requested' THEN NULL ELSE promoted_verdict_at END
         WHERE id=?4 AND (status='requested' OR (status='running' AND job_id=?1)
                          OR (status='running' AND job_id IS NOT ?1 AND COALESCE(heartbeat_at, updated_at) < ?6))`
      ).bind(job_id, box, t, id, participant, cutoff).run();
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      if (res.meta.changes === 1) {
        if (before.status === "running" && before.job_id !== job_id) {
          return json(200, { request: row, reclaimed_from: { job_id: before.job_id, box: before.box, participant: before.participant ?? null } });
        }
        return json(200, { request: row });
      }
      return json(409, { error: `lead review request is ${row.status}${row.job_id ? ` (job ${row.job_id})` : ""}; only a requested row, a re-claim by its own job, or a claim with no heartbeat past the stale window can be claimed`, request: row });
    }),
  ],

  // Re-stamps heartbeat_at for the job that holds the running row, and only
  // that job. updated_at is left alone, so the list order and cursor are too.
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/heartbeat$/,
    guarded(async ({ env, t, body, m }) => {
      const id = decodeURIComponent(m[1]);
      const job_id = reqStr((body || {}).job_id, 128);
      if (!job_id) return json(400, { error: "job_id must be a string, 1..128 chars" });
      const res = await env.DB.prepare(
        "UPDATE lead_review_requests SET heartbeat_at=?1 WHERE id=?2 AND status='running' AND job_id=?3"
      ).bind(t, id, job_id).run();
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      if (res.meta.changes === 1) return json(200, { request: row });
      return json(409, { error: `lead review request is ${row.status}${row.job_id ? ` (job ${row.job_id})` : ""}; only the job that holds a running claim may heartbeat`, request: row });
    }),
  ],

  // BH-7792: the job that holds a running claim gives it back. ONE
  // compare-and-set pinned to the status and the job: the row goes to
  // requested with job, box, participant and heartbeat cleared, and `detail`
  // says why. It is not a reset (reset_count and reset_at are left alone), so
  // the claim that takes it next counts none either. bin/lead-review.sh calls it
  // when the call-guard refuses the paid call (rc 74..79, nothing billed), so
  // the request is free at once for the box that holds the paid report.
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/release$/,
    guarded(async ({ env, t, body, m }) => {
      const id = decodeURIComponent(m[1]);
      const b = body || {};
      const job_id = reqStr(b.job_id, 128);
      if (!job_id) return json(400, { error: "job_id must be a string, 1..128 chars" });
      const o = optFields(b, [["detail", 4000]]);
      if (o.err) return json(400, { error: o.err });
      const res = await env.DB.prepare(
        `UPDATE lead_review_requests
            SET status='requested', job_id=NULL, box=NULL, participant=NULL, heartbeat_at=NULL, detail=?1, updated_at=?2
          WHERE id=?3 AND status='running' AND job_id=?4`
      ).bind(o.v.detail, t, id, job_id).run();
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      if (res.meta.changes === 1) return json(200, { request: row, released_by: job_id });
      return json(409, { error: `lead review request is ${row.status}${row.job_id ? ` (job ${row.job_id})` : ""}; only the job that holds a running claim may release it`, request: row });
    }),
  ],

  // The outcome and the verdict are refused by name, never mapped: APPROVE is
  // not a verdict word, and a failed review carries no verdict at all.
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/result$/,
    guarded(async ({ env, t, body, m }) => {
      const id = decodeURIComponent(m[1]);
      const b = body || {};
      const job_id = reqStr(b.job_id, 128);
      if (!job_id) return json(400, { error: "job_id must be a string, 1..128 chars" });
      if (!LR_OUTCOMES.includes(b.outcome)) return json(400, { error: `outcome must be one of ${LR_OUTCOMES.join(", ")}` });
      const outcome = b.outcome;
      const hasVerdict = b.verdict !== undefined && b.verdict !== null;
      if (hasVerdict && !VERDICT_WORDS.includes(b.verdict)) return json(400, { error: `verdict must be one of ${VERDICT_WORDS.join(", ")}` });
      if (outcome === "done" && !hasVerdict) return json(400, { error: "outcome done needs a verdict" });
      if (outcome !== "done" && hasVerdict) return json(400, { error: `outcome ${outcome} carries no verdict` });
      const verdict = hasVerdict ? b.verdict : null;
      const head_sha = shaOf(b.head_sha);
      if (!head_sha) return json(400, { error: "head_sha must be a full 40-hex commit sha" });
      const o = optFields(b, [["report_ref", 1000], ["reviewer_model", 128], ["detail", 4000]]);
      if (o.err) return json(400, { error: o.err });

      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      if (row.job_id !== job_id) {
        // BH-7792: the request was rebound while this job was still inside its
        // paid call. A finished review of this head from a live lead-review job
        // of this head lands, so a paid review is never lost (rebindResult).
        const rb = await rebindResult(env, t, row, job_id, head_sha, outcome, verdict, o.v);
        if (rb) return rb;
        return json(409, { error: "job_id is not the job this request is bound to", request: row });
      }
      if (row.head_sha !== head_sha) return json(409, { error: "head_sha is not the head this request was made for", request: row });
      if (row.status === "running") {
        const res = await env.DB.prepare(
          `UPDATE lead_review_requests SET status=?1, verdict=?2, report_ref=?3, reviewer_model=?4,
                                           detail=?5, updated_at=?6
           WHERE id=?7 AND status='running' AND job_id=?8`
        ).bind(outcome, verdict, o.v.report_ref, o.v.reviewer_model, o.v.detail, t, id, job_id).run();
        const now = await getRow(env, id);
        if (res.meta.changes === 1) return json(200, { request: now });
        return json(409, { error: `lead review request is ${now.status}`, request: now });
      }
      // A retried finalize from the same job returns the sealed row unchanged.
      if (row.status === outcome && (row.verdict ?? null) === verdict) return json(200, { request: row });
      return json(409, { error: `lead review request is ${row.status}${row.verdict ? ` (${row.verdict})` : ""}; a result is recorded once`, request: row });
    }),
  ],

  // BH-5400: send a finished request back for a re-review. From done, failed or
  // superseded, in ONE compare-and-set that clears the result and the
  // promoted stamp and records the reset. Already requested = 200 unchanged
  // (a retry). BH-7711: a running row whose COALESCE(heartbeat_at, updated_at)
  // is older than staleWindow is reclaimed to requested in ONE compare-and-set
  // pinned to the job and the beat read here (200 with reclaimed_from and
  // stale_s); stale_reclaims, the BH-5779 sweep's ladder, is left alone. A
  // running row with a fresher beat = 409 (a review is in flight).
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/reset$/,
    guarded(async ({ req, env, t, body, m }) => {
      if (!leadTokenOk(req, env)) return json(403, { error: `resetting a lead review request ${NO_LEAD}` });
      const o = optFields(body && typeof body === "object" ? body : {}, [["append_notes", 4000]]);
      if (o.err) return json(400, { error: o.err });
      const note = o.v.append_notes && o.v.append_notes.replaceAll("review-tier:", "review-tier=").replaceAll("review-mode:", "review-mode=");
      const id = decodeURIComponent(m[1]);
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      // BH-8512: what the note does to scope_notes. Only `stored` writes it.
      const old = row.scope_notes ?? null;
      let next = old, notes = null;
      if (note) {
        const cand = old ? `${old}\n${note}` : note;
        if ((old ?? "").includes(note)) notes = "present";
        else if (cand.length > 4000) notes = "no-room";
        else { next = cand; notes = "stored"; }
      }
      const N = notes === "stored";
      const said = notes ? { notes } : {};
      const moved = (now) => json(409, { error: `lead review request is ${now.status}${now.job_id ? ` (job ${now.job_id})` : ""}; it moved while the reset ran`, request: now });
      if (row.status === "requested") {
        if (!N) return json(200, { request: row, existing: true, ...said });
        const res = await env.DB.prepare(
          "UPDATE lead_review_requests SET scope_notes=?1, updated_at=?2 WHERE id=?3 AND status='requested' AND scope_notes IS ?4"
        ).bind(next, t, id, old).run();
        const now = await getRow(env, id);
        if (res.meta.changes === 1) return json(200, { request: now, existing: true, ...said });
        return moved(now);
      }
      if (row.status === "running") {
        const limit = await staleWindow(env);
        const beat = row.heartbeat_at ?? row.updated_at;
        if (!(beat < isoPlusSeconds(t, -limit))) {
          return json(409, { error: `lead review request is running${row.job_id ? ` (job ${row.job_id})` : ""}, heartbeat ${beat}, stale after ${limit} s; a review in flight is not reset`, request: row });
        }
        const why = `stale reset: running with no heartbeat since ${beat} (job ${row.job_id ?? "none"}, box ${row.box ?? "none"}); stale after ${limit} s`.slice(0, 4000);
        // sql-ident-ok: the two ${N ? ...} parts are constant SQL text chosen by the note flag; values bind
        const res = await env.DB.prepare(
          `UPDATE lead_review_requests
              SET status='requested', job_id=NULL, box=NULL, participant=NULL, heartbeat_at=NULL, verdict=NULL,
                  report_ref=NULL, reviewer_model=NULL, promoted_verdict_at=NULL, detail=?1,
                  reset_count=COALESCE(reset_count, 0) + 1, reset_at=?2, updated_at=?2${N ? ", scope_notes=?6" : ""}
            WHERE id=?3 AND status='running' AND job_id IS ?4 AND COALESCE(heartbeat_at, updated_at) = ?5${N ? " AND scope_notes IS ?7" : ""}`
        ).bind(why, t, id, row.job_id ?? null, beat, ...(N ? [next, old] : [])).run();
        const now = await getRow(env, id);
        if (res.meta.changes === 1) {
          return json(200, {
            request: now,
            reclaimed_from: { job_id: row.job_id ?? null, box: row.box ?? null, participant: row.participant ?? null, last_beat: beat },
            stale_s: limit,
            ...said,
          });
        }
        return moved(now);
      }
      // sql-ident-ok: the two ${N ? ...} parts are constant SQL text chosen by the note flag; values bind
      const res = await env.DB.prepare(
        `UPDATE lead_review_requests SET status='requested', job_id=NULL, box=NULL, verdict=NULL, report_ref=NULL,
                                         reviewer_model=NULL, detail=NULL, promoted_verdict_at=NULL,
                                         reset_count=COALESCE(reset_count, 0) + 1, reset_at=?1, updated_at=?1${N ? ", scope_notes=?3" : ""}
         WHERE id=?2 AND status IN ('done', 'failed', 'superseded')${N ? " AND scope_notes IS ?4" : ""}`
      ).bind(t, id, ...(N ? [next, old] : [])).run();
      const now = await getRow(env, id);
      if (res.meta.changes === 1) return json(200, { request: now, ...said });
      if (N && ["done", "failed", "superseded"].includes(now.status)) return moved(now);
      return json(409, { error: `lead review request is ${now.status}${now.job_id ? ` (job ${now.job_id})` : ""}; only a finished request can be reset`, request: now });
    }),
  ],

  // Stamped once: a second call answers the first stamp. BH-5400: a body
  // {job_id} binds the stamp to the result it was made for; a row that now
  // holds another job (reset and re-claimed meanwhile) is a 409, unstamped.
  [
    "POST", /^\/api\/lead-reviews\/([^/]+)\/promoted$/,
    guarded(async ({ req, env, t, body, m }) => {
      if (!leadTokenOk(req, env)) return json(403, { error: `marking a lead review promoted ${NO_LEAD}` });
      const id = decodeURIComponent(m[1]);
      const row = await getRow(env, id);
      if (!row) return json(404, { error: "no such lead review request" });
      const want = body && body.job_id !== undefined && body.job_id !== null ? body.job_id : null;
      if (want !== null && want !== row.job_id) {
        return json(409, { error: `the request now holds job ${row.job_id ?? "none"}; this stamp is for ${want}`, request: row });
      }
      if (row.status !== "done") return json(409, { error: `lead review request is ${row.status}; only a done review can be promoted`, request: row });
      await env.DB.prepare(
        "UPDATE lead_review_requests SET promoted_verdict_at=?1, updated_at=?1 WHERE id=?2 AND promoted_verdict_at IS NULL"
      ).bind(t, id).run();
      return json(200, { request: await getRow(env, id) });
    }),
  ],
];

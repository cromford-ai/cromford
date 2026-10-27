// PR record WRITER for GitHub deliveries (BH-8067 slice C2). The table and its
// read rule live in src/routes/pr-records.js and bin/lib/pr-record.sh; this
// file turns what a signed delivery to POST /webhooks/github already carries
// into pr_records writes, source `webhook`.
//
// prRecordWritesOf(event, payload, t) is PURE: the writes the delivery proves.
// recordPrRecord(env, t, event, payload) runs them in ONE env.DB.batch and
// NEVER throws: a lost write is one console.warn, the receiver answers as
// before, and the max-age backstop (PR_RECORD_MAX_AGE_S) heals the record.
//
// Case 2 of the read rule: a named change whose payload does not carry a field
// stores that field as NULL ("unknown"), so the next pr_record_get that asks
// for it reads GitHub. GitHub's own mergeable_state "unknown" is stored NULL.
//
// Every write is ordered by the event's own time (`at`), clamped to the
// worker's clock, through the same per-field guard the PUT uses: an older
// delivery never replaces a newer value from any source.

import { ensureColumns, ensureTable } from "./core.js";
import { upsertSql, VALUE_FIELDS, REPO_RE, CHECKS_MAX, REVIEWERS_MAX, REVIEWER_RE } from "../routes/pr-records.js";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const num = (v) => (Number.isSafeInteger(v) && v >= 1 && v <= 1e9 ? v : null);
const str = (v) => (typeof v === "string" ? v : "");
const word = (v) => (typeof v === "string" && /^[a-z_]{1,32}$/.test(v) ? v : null);
const ISO_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$/;
// A check name becomes a JSON path `$."<name>"`: no quote, no backslash, no control character.
const NAME_RE = /^[^"\\\u0000-\u001f\u007f]{1,100}$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const PREQUEUE_RE = /^prequeue pr=([1-9][0-9]{0,8}) head=([0-9a-f]{40}) main=[0-9a-f]{40}$/;
const PR_FIELD_ACTIONS = ["opened", "reopened", "synchronize", "edited"];

// The event time: the payload's ISO time without a fraction; t when it is
// missing, does not parse, or is later than t.
function atOf(v, t) {
  const m = ISO_RE.exec(str(v));
  if (!m) return t;
  const at = `${m[1]}Z`;
  const ms = Date.parse(at);
  return Number.isNaN(ms) || ms > Date.parse(t) ? t : at;
}

// Each raw value through the pr-records check; a value that fails drops that field only.
function checked(raw) {
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (v === undefined) continue;
    const val = VALUE_FIELDS[k](v);
    if (val !== undefined) out[k] = val;
  }
  return out;
}

// A GitHub time without its fraction, or undefined (the field is then not written).
function isoOf(v) {
  const m = ISO_RE.exec(str(v));
  return m ? `${m[1]}Z` : undefined;
}

// The columns a whole pulls object fills (not mergeable_state). BH-8452: the
// list readers' columns too. A body that is null on GitHub (an empty PR body)
// is stored "", so NULL keeps one meaning (unknown); no body key writes none.
function prFields(pr) {
  const head = isObj(pr.head) ? pr.head : {}, base = isObj(pr.base) ? pr.base : {};
  return checked({
    state: pr.merged_at || pr.merged === true ? "merged" : pr.state,
    draft: pr.draft,
    head_ref: head.ref, base_ref: base.ref, head_sha: head.sha, base_sha: base.sha,
    labels: Array.isArray(pr.labels) ? pr.labels.map((l) => (isObj(l) ? l.name : l)) : undefined,
    title: pr.title,
    author: isObj(pr.user) ? pr.user.login : undefined,
    body: Object.hasOwn(pr, "body") ? (pr.body === null ? "" : pr.body) : undefined,
    url: pr.html_url,
    pr_created_at: isoOf(pr.created_at),
    pr_updated_at: isoOf(pr.updated_at),
    merged_at: isoOf(pr.merged_at),
  });
}

// BH-8481: a reviewer's key in the reviews object. GraphQL says app/x or x,
// REST says x[bot]: the key is the bare lowercase login, or "" when it fails
// REVIEWER_RE (the write is then dropped).
export function reviewerKey(login) {
  let v = str(login).trim().toLowerCase();
  if (v.startsWith("app/")) v = v.slice(4);
  if (v.endsWith("[bot]")) v = v.slice(0, -5);
  return REVIEWER_RE.test(v) ? v : "";
}

const fieldsWrite = (repo, number, at, refresh, fields) =>
  (number !== null && Object.keys(fields).length ? [{ kind: "fields", repo, number, at, refresh, fields }] : []);

// One check write per PR number, or none when the name or sha fails.
function checkWrites(repo, numbers, name, status, conclusion, sha, at) {
  const s = str(sha).toLowerCase();
  if (!NAME_RE.test(name) || !SHA_RE.test(s)) return [];
  const value = { status: word(status), conclusion: word(conclusion), sha: s, at };
  return numbers.filter((n) => n !== null).map((number) => ({ kind: "check", repo, number, at, name, value }));
}
const prNumbers = (prs) => (Array.isArray(prs) ? prs.map((p) => (isObj(p) ? num(p.number) : null)) : []);

// prRecordWritesOf(event, payload, t) — PURE. [] or a list of
//   {kind:'fields', repo, number, at, refresh, fields}   fields are checked values
//   {kind:'check', repo, number, at, name, value}        value {status, conclusion, sha, at}
//   {kind:'base-push', repo, base_ref, at}
//   {kind:'review', repo, number, at, login, value}      value {state, commit_id, at} (BH-8481)
export function prRecordWritesOf(event, payload, t) {
  if (!isObj(payload)) return [];
  const repo = str(isObj(payload.repository) ? payload.repository.full_name : "").toLowerCase();
  if (!REPO_RE.test(repo)) return [];
  const action = str(payload.action);

  if (event === "pull_request") {
    const pr = payload.pull_request;
    if (!isObj(pr)) return [];
    const fields = prFields(pr);
    const ms = pr.mergeable_state;
    if (typeof ms === "string" && ms !== "unknown" && VALUE_FIELDS.mergeable_state(ms) !== undefined) fields.mergeable_state = ms;
    else if (PR_FIELD_ACTIONS.includes(action)) fields.mergeable_state = null;
    // BH-8481: a PR that was just opened has no review. That is the one
    // delivery that knows the whole reviews set; any other leaves it alone.
    if (action === "opened") fields.reviews = VALUE_FIELDS.reviews({});
    return fieldsWrite(repo, num(pr.number ?? payload.number), atOf(pr.updated_at, t), true, fields);
  }

  if (event === "pull_request_review") {
    const pr = payload.pull_request, rv = isObj(payload.review) ? payload.review : {};
    if (!isObj(pr) || !["submitted", "edited", "dismissed"].includes(action)) return [];
    const fields = prFields(pr);
    const state = str(rv.state).toLowerCase();
    if (action === "dismissed") fields.review_decision = null;
    else if (state === "approved" || state === "changes_requested") fields.review_decision = state;
    const number = num(pr.number ?? payload.number), at = atOf(rv.submitted_at ?? pr.updated_at, t);
    // BH-8481: this reviewer's latest review, merged into a known reviews
    // object (REVIEW_MERGE_SQL). A bad login or state writes no entry.
    const login = reviewerKey(isObj(rv.user) ? rv.user.login : "");
    const rstate = action === "dismissed" ? "DISMISSED" : state.toUpperCase();
    const commit = str(rv.commit_id).toLowerCase();
    const review = number !== null && login && ["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED"].includes(rstate)
      ? [{ kind: "review", repo, number, at, login, value: { state: rstate, commit_id: SHA_RE.test(commit) ? commit : null, at } }]
      : [];
    return [...fieldsWrite(repo, number, at, true, fields), ...review];
  }

  if (event === "issue_comment") {
    const issue = payload.issue;
    if (!["created", "edited"].includes(action) || !isObj(issue) || !isObj(issue.pull_request)) return [];
    const fields = checked({
      labels: Array.isArray(issue.labels) ? issue.labels.map((l) => (isObj(l) ? l.name : l)) : undefined,
      state: issue.pull_request.merged_at ? "merged" : issue.state,
    });
    return fieldsWrite(repo, num(issue.number), atOf(issue.updated_at, t), false, fields);
  }

  if (event === "check_run") {
    const cr = payload.check_run;
    if (!isObj(cr) || !["created", "completed"].includes(action)) return [];
    const at = atOf(action === "completed" ? cr.completed_at : cr.started_at, t);
    return checkWrites(repo, prNumbers(cr.pull_requests), str(cr.name), cr.status, cr.conclusion, cr.head_sha, at);
  }

  if (event === "check_suite") {
    const cs = payload.check_suite;
    if (!isObj(cs) || action !== "completed" || !isObj(cs.app) || !str(cs.app.slug)) return [];
    return checkWrites(repo, prNumbers(cs.pull_requests), `suite:${cs.app.slug}`, cs.status, cs.conclusion, cs.head_sha, atOf(cs.updated_at, t));
  }

  if (event === "workflow_run") {
    const r = payload.workflow_run;
    if (!isObj(r) || action !== "completed" || !str(r.name)) return [];
    const name = `workflow:${r.name}`, at = atOf(r.updated_at, t);
    // The prequeue dispatch runs on main (head_sha is main's tip); the title
    // names the PR and its head. The same form wakeOf reads (core.js).
    const m = PREQUEUE_RE.exec(str(r.display_title));
    if (m && str(r.event) === "workflow_dispatch" && str(r.path).endsWith("/prequeue-gate.yml")) {
      return checkWrites(repo, [num(Number(m[1]))], name, r.status, r.conclusion, m[2], at);
    }
    return checkWrites(repo, prNumbers(r.pull_requests), name, r.status, r.conclusion, r.head_sha, at);
  }

  if (event === "push") {
    const branch = str(payload.repository.default_branch) || "main";
    if (str(payload.ref) !== `refs/heads/${branch}`) return [];
    return [{ kind: "base-push", repo, base_ref: branch, at: t }];
  }
  return [];
}

// One check merged into the checks object. Binds: ?1 repo, ?2 number, ?3 name,
// ?4 value (JSON), ?5 at, ?6 the path `$."<name>"` (a bind, never SQL text).
// On an existing row the merge runs only when the stored entry of that name is
// not newer, differs from the value (a replay changes 0 rows), and the object
// already holds the name or has fewer than CHECKS_MAX names. refreshed_at
// does not move on an existing row: a check does not carry the whole PR.
export const CHECK_MERGE_SQL = `INSERT INTO pr_records (repo, number, checks, fields_at, last_source, webhook_at, created_at, refreshed_at)
    VALUES (?1, ?2, json_object(?3, json(?4)), json_object('checks', ?5), 'webhook', ?5, ?5, ?5)
    ON CONFLICT(repo, number) DO UPDATE SET
      checks = json_set(coalesce(pr_records.checks, '{}'), ?6, json(?4)),
      fields_at = json_set(pr_records.fields_at, '$.checks', max(coalesce(json_extract(pr_records.fields_at, '$.checks'), ''), ?5)),
      last_source = 'webhook',
      webhook_at = max(coalesce(pr_records.webhook_at, ''), ?5)
    WHERE (json_extract(pr_records.checks, ?6 || '.at') IS NULL OR json_extract(pr_records.checks, ?6 || '.at') <= ?5)
      AND json_extract(pr_records.checks, ?6) IS NOT json(?4)
      AND (json_type(pr_records.checks, ?6) IS NOT NULL
           OR (SELECT count(*) FROM json_each(coalesce(pr_records.checks, '{}'))) < ${CHECKS_MAX})`;

// A push to the base branch: every open record of the repo on that base gets
// mergeable_state NULL (case 2). Binds: ?1 repo, ?2 base_ref, ?3 at. A row
// whose value is already NULL at that time is left alone (a replay changes 0).
// Index: ux_pr_records_repo_number (repo=?), SEARCH on 5,000 rows (test X2).
export const BASE_PUSH_SQL = `UPDATE pr_records SET mergeable_state = NULL,
      fields_at = json_set(fields_at, '$.mergeable_state', ?3),
      last_source = 'webhook',
      webhook_at = max(coalesce(webhook_at, ''), ?3)
    WHERE state = 'open' AND repo = ?1 AND base_ref = ?2
      AND (json_extract(fields_at, '$.mergeable_state') IS NULL OR json_extract(fields_at, '$.mergeable_state') <= ?3)
      AND (mergeable_state IS NOT NULL OR json_extract(fields_at, '$.mergeable_state') IS NOT ?3)`;

// BH-8481: one reviewer's latest review merged into the reviews object.
// Binds: ?1 repo, ?2 number, ?3 the path `$."<login>"` (a bind, never SQL
// text), ?4 value (JSON), ?5 at. An UPDATE, never an insert, and only on a
// row whose reviews is known (not NULL): a NULL object stays NULL, because one
// entry is not the whole set. The merge runs when the stored entry is older,
// or the same time and not a dismissal this value does not repeat (a dismissal
// carries its review's submitted_at, so it wins the tie); when the value
// differs (a replay changes 0 rows); and when the object already holds the
// login or has fewer than REVIEWERS_MAX of them. fields_at.reviews moves
// forward, so an older list sync does not replace a newer review.
// refreshed_at does not move: a review does not carry the whole PR.
export const REVIEW_MERGE_SQL = `UPDATE pr_records SET
      reviews = json_set(reviews, ?3, json(?4)),
      fields_at = json_set(fields_at, '$.reviews', max(coalesce(json_extract(fields_at, '$.reviews'), ''), ?5)),
      last_source = 'webhook',
      webhook_at = max(coalesce(webhook_at, ''), ?5)
    WHERE repo = ?1 AND number = ?2 AND reviews IS NOT NULL
      AND (json_extract(reviews, ?3 || '.at') IS NULL OR json_extract(reviews, ?3 || '.at') < ?5
           OR (json_extract(reviews, ?3 || '.at') = ?5
               AND (json_extract(?4, '$.state') = 'DISMISSED' OR json_extract(reviews, ?3 || '.state') IS NOT 'DISMISSED')))
      AND json_extract(reviews, ?3) IS NOT json(?4)
      AND (json_type(reviews, ?3) IS NOT NULL OR (SELECT count(*) FROM json_each(reviews)) < ${REVIEWERS_MAX})`;

function stmtOf(DB, w) {
  if (w.kind === "review") {
    return DB.prepare(REVIEW_MERGE_SQL).bind(w.repo, w.number, `$."${w.login}"`, JSON.stringify(w.value), w.at);
  }
  if (w.kind === "fields") {
    const names = Object.keys(w.fields);
    return DB.prepare(upsertSql(names, { refresh: w.refresh }))
      .bind(w.repo, w.number, w.at, "webhook", ...names.map((f) => w.fields[f]));
  }
  if (w.kind === "check") {
    return DB.prepare(CHECK_MERGE_SQL).bind(w.repo, w.number, w.name, JSON.stringify(w.value), w.at, `$."${w.name}"`);
  }
  return DB.prepare(BASE_PUSH_SQL).bind(w.repo, w.base_ref, w.at);
}

// recordPrRecord — {written} (rows changed) or {written: 0, error}. Never throws.
export async function recordPrRecord(env, t, event, payload) {
  try {
    const writes = prRecordWritesOf(event, payload, t);
    if (!writes.length) return { written: 0 };
    await ensureTable(env, "pr_records");
    await ensureColumns(env, "pr_records");
    const res = await env.DB.batch(writes.map((w) => stmtOf(env.DB, w)));
    return { written: res.reduce((n, r) => n + ((r && r.meta && r.meta.changes) || 0), 0) };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.warn("[pr-record-intake] webhook record write failed", event, error);
    return { written: 0, error };
  }
}

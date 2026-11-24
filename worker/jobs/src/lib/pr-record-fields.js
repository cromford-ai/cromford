// PR record fields of BH-9935 (BH-9926.3): commit statuses, the newest
// Mergify queue payload, the head commit time and the PR file list. The
// columns live in core.d/bh-9935-pr-records-fields.js (ensureColumns). This
// module holds their PUT checks (fieldValues, spread into VALUE_FIELDS by
// routes/pr-records.js) and their webhook writes (fieldWritesOf + fieldStmtOf,
// called by lib/pr-record-intake.js). It imports nothing from routes/, so the
// route module can import it without a cycle; the CHECKS_MAX bound is passed in.
//
//   statuses       {<context>: {state, description, sha, at}}, one entry per
//                  status context, from `status` deliveries (STATUS_MERGE_SQL)
//   mergify_queue  {state, code, draft_pr, failing_checks, left_sha, comment_id,
//                  at}: the newest mergify[bot] payload comment by (created_at,
//                  id), never by updated_at (Mergify edits old comments). The
//                  comment body is never stored.
//   head_commit    {sha, at}: the commit time of a pushed head (push deliveries,
//                  HEAD_PUSH_SQL; or bin/lib/pr-record.sh after a GitHub read)
//   files          {sha, paths}: the changed paths of head `sha`, sorted and
//                  unique. Only bin/lib/pr-record.sh writes it.

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v) => (typeof v === "string" ? v : "");
const REPO_RE = /^[a-z0-9_.-]{1,100}\/[a-z0-9_.-]{1,100}$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const ISO_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$/;
// A git commit time with an offset (push payloads) or Z (the REST API).
const COMMIT_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
// A status context becomes a JSON path `$."<ctx>"`: no quote, no backslash, no control character.
const NAME_RE = /^[^"\\\u0000-\u001f\u007f]{1,100}$/;
export const STATUS_STATES = ["pending", "success", "failure", "error"];
const MQ_STATE_RE = /^[a-z_]{1,32}$/;
const MQ_CODE_RE = /^[A-Z0-9_]{1,64}$/;
const LEFT_SHA_RE = /^[0-9a-f]{7,40}$/;
const MERGIFY_LOGIN = "mergify[bot]";
// The payload markers bin/lib/mc-failed-batch.sh FBH_PAYLOAD_RE matches.
const PAYLOAD_RE = /-\*- Mergify Payload -\*-([\s\S]*?)-\*- Mergify Payload End -\*-/;
// Input shape bounds, not tunable limits (the LABELS_MAX / REF_MAX kind in
// routes/pr-records.js): GitHub's pulls/<n>/files answers at most 3,000
// files; a git path is at most 4,096 bytes (PATH_MAX); GitHub caps a status
// description at 140 characters, and this bound sits far above it.
export const FILES_MAX = 3000;
const PATH_MAX = 4096;
const DESC_MAX = 1024;

const sha = (v) => (typeof v === "string" && SHA_RE.test(v.toLowerCase()) ? v.toLowerCase() : undefined);
const isoAt = (v) => (typeof v === "string" && AT_RE.test(v) && !Number.isNaN(Date.parse(v)) ? v : undefined);
const nullable = (v, ok) => (v === null ? null : ok(v));
const keysOnly = (v, keys) => isObj(v) && Object.keys(v).every((k) => keys.includes(k)) && keys.every((k) => Object.hasOwn(v, k));

// The event time: the payload's ISO time without a fraction; t when it is
// missing, does not parse, or is later than t (the intake's atOf rule).
function atOf(v, t) {
  const m = ISO_RE.exec(str(v));
  if (!m) return t;
  const at = `${m[1]}Z`;
  const ms = Date.parse(at);
  return Number.isNaN(ms) || ms > Date.parse(t) ? t : at;
}
// A commit timestamp in UTC without a fraction, or undefined.
function utcOf(v) {
  if (!COMMIT_TS_RE.test(str(v))) return undefined;
  const ms = Date.parse(v);
  return Number.isNaN(ms) ? undefined : new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function statusEntry(v) {
  if (!keysOnly(v, ["state", "description", "sha", "at"]) || !STATUS_STATES.includes(v.state)) return undefined;
  const d = nullable(v.description, (x) => (typeof x === "string" && x.length <= DESC_MAX ? x : undefined));
  const s = sha(v.sha), at = isoAt(v.at);
  if (d === undefined || s === undefined || at === undefined) return undefined;
  return { state: v.state, description: d, sha: s, at };
}

function mergifyEntry(v, checksMax) {
  const keys = ["state", "code", "draft_pr", "failing_checks", "left_sha", "comment_id", "at"];
  if (!keysOnly(v, keys)) return undefined;
  const state = nullable(v.state, (x) => (typeof x === "string" && MQ_STATE_RE.test(x) ? x : undefined));
  const code = nullable(v.code, (x) => (typeof x === "string" && MQ_CODE_RE.test(x) ? x : undefined));
  const draft = nullable(v.draft_pr, (x) => (Number.isSafeInteger(x) && x > 0 ? x : undefined));
  const left = nullable(v.left_sha, (x) => (typeof x === "string" && LEFT_SHA_RE.test(x.toLowerCase()) ? x.toLowerCase() : undefined));
  const checks = Array.isArray(v.failing_checks) && v.failing_checks.length <= checksMax
    && v.failing_checks.every((x) => typeof x === "string" && NAME_RE.test(x)) ? v.failing_checks : undefined;
  const id = Number.isSafeInteger(v.comment_id) && v.comment_id > 0 ? v.comment_id : undefined;
  const at = isoAt(v.at);
  if ([state, code, draft, left, checks, id, at].includes(undefined)) return undefined;
  return { state, code, draft_pr: draft, failing_checks: checks, left_sha: left, comment_id: id, at };
}

// fieldValues(checksMax) — column -> check, the VALUE_FIELDS form: the JSON
// text to store, or undefined (a 400 that names the field).
export function fieldValues(checksMax) {
  return {
    statuses: (v) => {
      if (!isObj(v) || Object.keys(v).length > checksMax || !Object.keys(v).every((k) => NAME_RE.test(k))) return undefined;
      const out = {};
      for (const [k, e] of Object.entries(v)) {
        const ok = statusEntry(e);
        if (ok === undefined) return undefined;
        out[k] = ok;
      }
      return JSON.stringify(out);
    },
    mergify_queue: (v) => {
      const e = mergifyEntry(v, checksMax);
      return e === undefined ? undefined : JSON.stringify(e);
    },
    head_commit: (v) => {
      if (!keysOnly(v, ["sha", "at"])) return undefined;
      const s = sha(v.sha), at = isoAt(v.at);
      return s === undefined || at === undefined ? undefined : JSON.stringify({ sha: s, at });
    },
    files: (v) => {
      if (!keysOnly(v, ["sha", "paths"]) || !Array.isArray(v.paths) || v.paths.length > FILES_MAX) return undefined;
      const s = sha(v.sha);
      if (s === undefined || !v.paths.every((p) => typeof p === "string" && p.length >= 1 && p.length <= PATH_MAX)) return undefined;
      // Sorted by UTF-16 code unit: for ASCII paths this is the byte order of `LC_ALL=C sort`.
      return JSON.stringify({ sha: s, paths: [...new Set(v.paths)].sort() });
    },
  };
}

// The Mergify value of one comment body, or null. The port of fbh_parse
// (bin/lib/mc-failed-batch.sh): the payload JSON between the markers; code =
// dequeue_reason.code; failing checks = dequeue_reason.checks (strings or
// {name}), else the backticked "Failing checks:" bullets; draft = the last
// "on draft #N"; left sha = the last "Left the queue … at `<sha>`".
function mergifyValueOf(body, id, at, checksMax) {
  const m = PAYLOAD_RE.exec(body);
  if (!m) return null;
  let p;
  try { p = JSON.parse(m[1]); } catch { return null; }
  if (!isObj(p)) return null;
  const reason = isObj(p.dequeue_reason) ? p.dequeue_reason : {};
  let checks = (Array.isArray(reason.checks) ? reason.checks : [])
    .map((c) => (typeof c === "string" ? c : isObj(c) && typeof c.name === "string" ? c.name : ""))
    .filter((c) => c !== "");
  if (!checks.length) {
    const parts = body.split("Failing checks:");
    const tail = parts.length > 1 ? parts[1].split("\n## ")[0] : "";
    checks = tail.split("\n").filter((l) => /^\s*[-*] /.test(l))
      .map((l) => { const c = /`([^`]+)`/.exec(l); return c ? c[1] : ""; }).filter((c) => c !== "");
  }
  const last = (re) => { let v = null; for (const x of body.matchAll(re)) v = x[1]; return v; };
  const draft = last(/on draft #([0-9]+)/g);
  const left = last(/Left the queue\*\*[^\n]*? at `([0-9a-fA-F]{7,40})`/g);
  const value = {
    state: typeof p.state === "string" && MQ_STATE_RE.test(p.state) ? p.state : null,
    code: typeof reason.code === "string" && MQ_CODE_RE.test(reason.code) ? reason.code : null,
    draft_pr: draft !== null && Number.isSafeInteger(Number(draft)) && Number(draft) > 0 ? Number(draft) : null,
    // A check name a status path could not hold is left out; more than
    // checksMax names keep the first checksMax (a reader needs the code most).
    failing_checks: checks.filter((c) => NAME_RE.test(c)).slice(0, checksMax),
    left_sha: left === null ? null : left.toLowerCase(),
    comment_id: id,
    at,
  };
  return mergifyEntry(value, checksMax) === undefined ? null : value;
}

// fieldWritesOf(event, payload, t, checksMax) — PURE. [] or a list of
//   {kind:'status', repo, sha, at, name, value}      value {state, description, sha, at}
//   {kind:'mergify', repo, number, at, id, value}    value: the mergify_queue object
//   {kind:'head-push', repo, head_ref, at, value}    value {sha, at}; at = the push time
export function fieldWritesOf(event, payload, t, checksMax) {
  if (!isObj(payload) || !isObj(payload.repository)) return [];
  const repo = str(payload.repository.full_name).toLowerCase();
  if (!REPO_RE.test(repo)) return [];

  if (event === "status") {
    const s = str(payload.sha).toLowerCase(), name = str(payload.context), state = str(payload.state);
    if (!SHA_RE.test(s) || !NAME_RE.test(name) || !STATUS_STATES.includes(state)) return [];
    const at = atOf(payload.updated_at, t);
    const description = typeof payload.description === "string" ? payload.description.slice(0, DESC_MAX) : null;
    return [{ kind: "status", repo, sha: s, at, name, value: { state, description, sha: s, at } }];
  }

  if (event === "issue_comment") {
    const issue = payload.issue, c = payload.comment;
    if (!["created", "edited"].includes(str(payload.action)) || !isObj(issue) || !isObj(issue.pull_request) || !isObj(c)) return [];
    if (!isObj(c.user) || c.user.login !== MERGIFY_LOGIN || typeof c.body !== "string") return [];
    const number = Number.isSafeInteger(issue.number) && issue.number >= 1 ? issue.number : null;
    const id = Number.isSafeInteger(c.id) && c.id > 0 ? c.id : null;
    if (number === null || id === null || !ISO_RE.test(str(c.created_at))) return [];
    const at = atOf(c.created_at, t);
    const value = mergifyValueOf(c.body, id, at, checksMax);
    return value ? [{ kind: "mergify", repo, number, at, id, value }] : [];
  }

  if (event === "push") {
    const branch = str(payload.repository.default_branch) || "main", ref = str(payload.ref);
    if (!ref.startsWith("refs/heads/") || ref === `refs/heads/${branch}` || payload.deleted === true) return [];
    const hc = payload.head_commit;
    const s = isObj(hc) ? str(hc.id).toLowerCase() : "";
    const cat = isObj(hc) ? utcOf(hc.timestamp) : undefined;
    const headRef = ref.slice("refs/heads/".length);
    if (!SHA_RE.test(s) || cat === undefined || headRef.length < 1 || headRef.length > 255) return [];
    // The order of pushes is the push time, never the commit time: a rebase
    // can push a commit older than the head it replaces.
    const pa = payload.repository.pushed_at;
    const pushed = Number.isSafeInteger(pa) && pa > 0 ? new Date(pa * 1000).toISOString() : pa;
    const at = atOf(typeof pushed === "string" ? pushed.replace(/\.\d{3}Z$/, "Z") : "", t);
    return [{ kind: "head-push", repo, head_ref: headRef, at, value: { sha: s, at: cat } }];
  }
  return [];
}

// One status merged into the statuses object of every record whose head is
// that sha (a status event names no PR). Binds: ?1 repo, ?2 sha, ?3 the path
// `$."<context>"` (a bind, never SQL text), ?4 value (JSON), ?5 at, ?6
// CHECKS_MAX. The merge runs when the stored entry of that context is not
// newer, the value differs (a replay changes 0 rows), and the object already
// holds the context or has fewer than ?6 of them. An UPDATE only: a status
// before the record knows its head is lost (pr_record_statuses then misses).
// refreshed_at does not move: a status does not carry the whole PR.
// Index: idx_pr_records_repo_head_sha (repo, head_sha), test X1.
export const STATUS_MERGE_SQL = `UPDATE pr_records SET
      statuses = json_set(coalesce(statuses, '{}'), ?3, json(?4)),
      fields_at = json_set(fields_at, '$.statuses', max(coalesce(json_extract(fields_at, '$.statuses'), ''), ?5)),
      last_source = 'webhook',
      webhook_at = max(coalesce(webhook_at, ''), ?5)
    WHERE repo = ?1 AND head_sha = ?2
      AND (json_extract(statuses, ?3 || '.at') IS NULL OR json_extract(statuses, ?3 || '.at') <= ?5)
      AND json_extract(statuses, ?3) IS NOT json(?4)
      AND (json_type(statuses, ?3) IS NOT NULL OR (SELECT count(*) FROM json_each(coalesce(statuses, '{}'))) < ?6)`;

// The newest Mergify payload of a PR. Binds: ?1 repo, ?2 number, ?3 value
// (JSON), ?4 at (the comment's created_at), ?5 comment id. The stored value is
// replaced when it is NULL, older, or the same time with an id that is not
// higher (an edit of the newest comment replaces it; an edit of an older one
// does not), and when the value differs. The CHECK_MERGE_SQL upsert pattern.
// Index: ux_pr_records_repo_number (the conflict target), test X1.
export const MERGIFY_SQL = `INSERT INTO pr_records (repo, number, mergify_queue, fields_at, last_source, webhook_at, created_at, refreshed_at)
    VALUES (?1, ?2, json(?3), json_object('mergify_queue', ?4), 'webhook', ?4, ?4, ?4)
    ON CONFLICT(repo, number) DO UPDATE SET
      mergify_queue = json(?3),
      fields_at = json_set(pr_records.fields_at, '$.mergify_queue', max(coalesce(json_extract(pr_records.fields_at, '$.mergify_queue'), ''), ?4)),
      last_source = 'webhook',
      webhook_at = max(coalesce(pr_records.webhook_at, ''), ?4)
    WHERE (pr_records.mergify_queue IS NULL
           OR json_extract(pr_records.mergify_queue, '$.at') < ?4
           OR (json_extract(pr_records.mergify_queue, '$.at') = ?4
               AND json_extract(pr_records.mergify_queue, '$.comment_id') <= ?5))
      AND pr_records.mergify_queue IS NOT json(?3)`;

// A push to a PR branch: every open record of the repo on that head ref gets
// head_commit {sha, at}. Binds: ?1 repo, ?2 head_ref, ?3 value (JSON), ?4 the
// push time. Ordered by fields_at.head_commit (the push time), so an older
// push never replaces a newer one; a replay changes 0 rows.
// Index: idx_pr_records_repo_head (repo, head_ref), test X1.
export const HEAD_PUSH_SQL = `UPDATE pr_records SET head_commit = json(?3),
      fields_at = json_set(fields_at, '$.head_commit', ?4),
      last_source = 'webhook',
      webhook_at = max(coalesce(webhook_at, ''), ?4)
    WHERE repo = ?1 AND head_ref = ?2 AND state = 'open'
      AND (json_extract(fields_at, '$.head_commit') IS NULL OR json_extract(fields_at, '$.head_commit') <= ?4)
      AND head_commit IS NOT json(?3)`;

// fieldStmtOf(DB, w, checksMax) — the statement of a write of fieldWritesOf,
// or null for any other kind.
export function fieldStmtOf(DB, w, checksMax) {
  if (w.kind === "status") {
    return DB.prepare(STATUS_MERGE_SQL).bind(w.repo, w.sha, `$."${w.name}"`, JSON.stringify(w.value), w.at, checksMax);
  }
  if (w.kind === "mergify") return DB.prepare(MERGIFY_SQL).bind(w.repo, w.number, JSON.stringify(w.value), w.at, w.id);
  if (w.kind === "head-push") return DB.prepare(HEAD_PUSH_SQL).bind(w.repo, w.head_ref, JSON.stringify(w.value), w.at);
  return null;
}

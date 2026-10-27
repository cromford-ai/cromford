// pr-records routes — BH-8067: the fleet's own record of each fleet-owned PR.
// Table: worker/jobs/schema.d/202610221947-bh-8067-pr-records.sql. Client:
// bin/lib/pr-record.sh (pr_record_put, pr_record_get).
// test/route-table.d/bh-8067-pr-records.txt pins this route list.
//
// PUT /api/pr-records  {repo, number, source, at?, fields: {...}}
//   source is fleet | webhook | github. at is YYYY-MM-DDTHH:MM:SSZ, default
//   the worker's clock. fields holds one or more of the VALUE_FIELDS columns.
//   mergeable_state may be null: stored NULL, "unknown" (NULLABLE_FIELDS).
//   The whole body is checked before the DB; the first bad key is a 400 that
//   names it and writes nothing. ONE statement upserts the row on (repo,
//   number). Per field: the value is replaced when no time is stored for it
//   or the stored time is <= at; else it is kept, and the field is in `stale`.
//   refreshed_at only moves forward. 200 {row, applied, stale}.
//
// GET /api/pr-records?repo=&number=
//   200 {row, age_s}. row is null when the PR has no record (200, so "absent"
//   is never a transport error). age_s is the worker's now - refreshed_at, so
//   a reader judges age on one clock. One statement, the unique index.
//
// GET /api/pr-records?repo=&state=open|merged|closed[&since=<at>][&need=<k,...>]
//   BH-8452: the list read (no `number`). 200 {rows, truncated, sync, missing, unknown}.
//   rows: every record of the repo in that state, LIST_KEYS only, newest
//   pr_updated_at first, at most the pr_records.list_limit settings row.
//   truncated: more rows exist. sync: {synced_at, age_s, rows} of the last
//   full GitHub list write (POST /api/pr-record-lists), or null: without it a
//   reader cannot know the record holds every PR. missing: the first `need`
//   key that is NULL on a returned row, or null. unknown: how many records of
//   the repo the LAST sync marked state NULL (not in its list, so closed,
//   merged, or open but absent from a lagging GitHub answer). A list reader
//   must treat unknown > 0 as incomplete: a NULL row is not in `rows`, and
//   "not in rows" reads as "no PR". The next sync either lists the PR (open
//   again) or leaves its mark older than the new stamp (no longer counted).
//   ONE batch, three statements.
//   BH-8481: rows also carry merged_at and reviews (parsed). &order=created
//   [&limit=<n>] is the window read: the newest n rows by pr_created_at (the
//   window `gh pr list --limit n` returns; NULL pr_created_at sorts last), n
//   default and at most the pr_records.list_limit row. `truncated` then means
//   "more than n exist", which is no miss for a window reader. limit also caps
//   the default order. A bad order or limit is a 400 that names it.
import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";

const SHA_RE = /^[0-9a-f]{40}$/;
const WORD_RE = /^[a-z_]{1,32}$/;
const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
export const REPO_RE = /^[a-z0-9_.-]{1,100}\/[a-z0-9_.-]{1,100}$/;
export const SOURCES = ["fleet", "webhook", "github"];
// Input shape bounds, not tunable limits: GitHub allows at most 100 labels on
// an issue or PR, and a git ref name of at most 255 bytes.
const LABELS_MAX = 100;
const NAME_MAX = 100;
const REF_MAX = 255;
export const CHECKS_MAX = 100;
// BH-8452, the same kind of bounds: GitHub's PR body limit (65,536
// characters), a login of at most 39 characters (+ "[bot]"), a title far above
// GitHub's own 256, and a URL length browsers accept.
const BODY_MAX = 65536;
const TITLE_MAX = 1024;
const URL_MAX = 2048;
const LOGIN_RE = /^[A-Za-z0-9-]{1,39}(\[bot\])?$/;
// BH-8481, an input shape bound like CHECKS_MAX: the reviewers a PR can carry
// before the object refuses a new one. The key is the bare lowercase login
// (no app/ prefix, no [bot] suffix), so one reviewer is one key.
export const REVIEWERS_MAX = 100;
export const REVIEWER_RE = /^[a-z0-9-]{1,39}$/;
export const REVIEW_STATES = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"];

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const ref = (v) => (typeof v === "string" && v.length >= 1 && v.length <= REF_MAX ? v : undefined);
const sha = (v) => (typeof v === "string" && SHA_RE.test(v.toLowerCase()) ? v.toLowerCase() : undefined);
const word = (v) => (typeof v === "string" && WORD_RE.test(v) ? v : undefined);
const isoAt = (v) => (typeof v === "string" && AT_RE.test(v) && !Number.isNaN(Date.parse(v)) ? v : undefined);
// One reviews entry -> {state, commit_id, at}, or undefined. commit_id and at
// may be null (unknown); no other key is accepted.
function reviewEntry(v) {
  if (!isObj(v) || !Object.keys(v).every((k) => ["state", "commit_id", "at"].includes(k))) return undefined;
  if (!REVIEW_STATES.includes(v.state)) return undefined;
  const commit = v.commit_id === null || v.commit_id === undefined ? null : sha(v.commit_id);
  const at = v.at === null || v.at === undefined ? null : isoAt(v.at);
  if (commit === undefined || at === undefined) return undefined;
  return { state: v.state, commit_id: commit, at };
}
// The reviews object, checked and normalized, as JSON text; or undefined.
export function reviewsValue(v) {
  if (!isObj(v)) return undefined;
  const keys = Object.keys(v);
  if (keys.length > REVIEWERS_MAX || !keys.every((k) => REVIEWER_RE.test(k))) return undefined;
  const out = {};
  for (const k of keys) {
    const e = reviewEntry(v[k]);
    if (e === undefined) return undefined;
    out[k] = e;
  }
  return JSON.stringify(out);
}

// column -> check. A check returns the value to store, or undefined for a 400.
// The SET list of the upsert is built from THIS list, never from request keys.
export const VALUE_FIELDS = {
  state: (v) => (["open", "closed", "merged"].includes(v) ? v : undefined),
  draft: (v) => (v === true || v === 1 ? 1 : v === false || v === 0 ? 0 : undefined),
  head_ref: ref,
  base_ref: ref,
  head_sha: sha,
  base_sha: sha,
  mergeable_state: word,
  labels: (v) => (Array.isArray(v) && v.length <= LABELS_MAX
    && v.every((x) => typeof x === "string" && x.length >= 1 && x.length <= NAME_MAX) ? JSON.stringify(v) : undefined),
  checks: (v) => (isObj(v) && Object.keys(v).length <= CHECKS_MAX
    && Object.keys(v).every((k) => k.length >= 1 && k.length <= NAME_MAX) ? JSON.stringify(v) : undefined),
  review_decision: word,
  queue_state: word,
  last_comment_id: (v) => (Number.isSafeInteger(v) && v > 0 ? v : undefined),
  // BH-8452: the list readers' columns (core.d/bh-8452-pr-records-list.js).
  title: (v) => (typeof v === "string" && v.length >= 1 && v.length <= TITLE_MAX ? v : undefined),
  author: (v) => (typeof v === "string" && LOGIN_RE.test(v) ? v : undefined),
  body: (v) => (typeof v === "string" && v.length <= BODY_MAX ? v : undefined),
  url: (v) => (typeof v === "string" && v.startsWith("https://github.com/") && v.length <= URL_MAX ? v : undefined),
  pr_created_at: isoAt,
  pr_updated_at: isoAt,
  // BH-8481 (core.d/bh-8481-pr-records-reviews.js).
  merged_at: isoAt,
  reviews: reviewsValue,
};
const JSON_FIELDS = ["labels", "checks", "reviews", "fields_at"];
// The columns where null is a value: "unknown, ask GitHub on the next read"
// (case 2 of the read rule in bin/lib/pr-record.sh).
export const NULLABLE_FIELDS = ["mergeable_state"];

export const GET_SQL = "SELECT * FROM pr_records WHERE repo = ?1 AND number = ?2";

// BH-8452: the list read. The keys a list reader gets (created_at and
// updated_at are GitHub's times, stored as pr_created_at / pr_updated_at).
export const LIST_KEYS = ["number", "title", "head_ref", "head_sha", "base_ref", "author", "labels", "body",
  "mergeable_state", "updated_at", "created_at", "url", "draft", "merged_at", "reviews"];
export const LIST_STATES = ["open", "merged", "closed"];
// Binds: ?1 repo, ?2 state, ?3 since or NULL, ?4 limit + 1 (so truncated is exact).
// Index: idx_pr_records_repo_state_upd (repo, state, pr_updated_at), test X1.
const LIST_COLS = `number, title, head_ref, head_sha, base_ref, author, labels, body, mergeable_state,
    pr_updated_at AS updated_at, pr_created_at AS created_at, url, draft, merged_at, reviews`;
export const LIST_SQL = `SELECT ${LIST_COLS}
  FROM pr_records WHERE repo = ?1 AND state = ?2 AND (?3 IS NULL OR pr_updated_at >= ?3)
  ORDER BY pr_updated_at DESC, number DESC LIMIT ?4`;
// BH-8481: the window read (order=created). Same binds. NULL pr_created_at
// sorts last (DESC). Index: idx_pr_records_repo_state_created, test X1 of
// test/pr-record-reviews.bh-8481.test.js.
export const LIST_CREATED_SQL = `SELECT ${LIST_COLS}
  FROM pr_records WHERE repo = ?1 AND state = ?2 AND (?3 IS NULL OR pr_updated_at >= ?3)
  ORDER BY pr_created_at DESC, number DESC LIMIT ?4`;
// Index: ux_pr_record_lists_repo_state.
export const SYNC_SQL = "SELECT synced_at, rows FROM pr_record_lists WHERE repo = ?1 AND state = ?2";
// Binds: ?1 repo, ?2 state. The records the last sync of (repo, state) marked
// unknown: ABSENT_SQL (routes/pr-record-lists.js) sets state NULL and
// fields_at.state = the sync's at, which is synced_at when it is the newest.
// Index: idx_pr_records_repo_state_upd (repo, state IS NULL), the stamp by
// ux_pr_record_lists_repo_state; test X1.
export const UNKNOWN_SQL = `SELECT COUNT(*) AS n FROM pr_records
  WHERE repo = ?1 AND state IS NULL
    AND json_extract(fields_at, '$.state') >= (SELECT synced_at FROM pr_record_lists WHERE repo = ?1 AND state = ?2)`;
// The settings row pr_records.list_limit (seed schema.d/202610261210-bh-8452-
// pr-record-lists.sql); this is its fallback when the row is absent or not an
// integer 1..LIST_LIMIT_MAX.
const LIST_LIMIT_KEY = "pr_records.list_limit";
const LIST_LIMIT_DEFAULT = 500;
const LIST_LIMIT_MAX = 5000;

// The pr_records.list_limit row, or its fallback.
export async function listLimit(env) {
  const row = (await settingsRows(env)).byKey.get(LIST_LIMIT_KEY);
  const v = row ? String(row.value).trim() : "";
  const n = /^\d{1,4}$/.test(v) ? Number(v) : NaN;
  return n >= 1 && n <= LIST_LIMIT_MAX ? n : LIST_LIMIT_DEFAULT;
}

// A list row as it leaves the worker: labels and reviews parsed, nothing else changed.
function listRow(r) {
  const o = { ...r };
  for (const k of ["labels", "reviews"]) {
    if (typeof o[k] === "string") { try { o[k] = JSON.parse(o[k]); } catch { /* left as stored */ } }
  }
  return o;
}

async function listRead(env, url, t, repo, state) {
  if (!LIST_STATES.includes(state)) return json(400, { error: "invalid_field", field: "state" });
  const since = url.searchParams.get("since");
  if (since !== null && isoAt(since) === undefined) return json(400, { error: "invalid_field", field: "since" });
  const needRaw = url.searchParams.get("need");
  const need = needRaw === null || needRaw === "" ? [] : needRaw.split(",");
  if (need.some((k) => !LIST_KEYS.includes(k))) return json(400, { error: "invalid_field", field: "need" });
  const order = url.searchParams.get("order");
  if (order !== null && order !== "created") return json(400, { error: "invalid_field", field: "order" });
  const limitRaw = url.searchParams.get("limit");
  await ensureTable(env, "pr_record_lists");
  const rowLimit = await listLimit(env);
  let limit = rowLimit;
  if (limitRaw !== null) {
    limit = /^[1-9]\d{0,3}$/.test(limitRaw) ? Number(limitRaw) : NaN;
    if (!(limit <= rowLimit)) return json(400, { error: "invalid_field", field: "limit" });
  }
  const [list, sync, unk] = await env.DB.batch([
    env.DB.prepare(order === "created" ? LIST_CREATED_SQL : LIST_SQL).bind(repo, state, since, limit + 1),
    env.DB.prepare(SYNC_SQL).bind(repo, state),
    env.DB.prepare(UNKNOWN_SQL).bind(repo, state),
  ]);
  const all = (list && list.results) || [];
  const rows = all.slice(0, limit).map(listRow);
  const s = sync && sync.results && sync.results[0];
  const age = s ? Math.floor((Date.parse(t) - Date.parse(s.synced_at)) / 1000) : null;
  const missing = need.find((k) => rows.some((r) => r[k] === null || r[k] === undefined)) ?? null;
  const u = unk && unk.results && unk.results[0];
  return json(200, {
    rows, truncated: all.length > limit, missing, unknown: (u && Number(u.n)) || 0,
    sync: s ? { synced_at: s.synced_at, age_s: Number.isFinite(age) ? age : null, rows: s.rows } : null,
  });
}

// {repo, number, source, at, fields} with checked values, or {error, field}.
export function checkPut(body, now) {
  if (!isObj(body)) return { error: "invalid_body" };
  for (const k of Object.keys(body)) {
    if (!["repo", "number", "source", "at", "fields"].includes(k)) return { error: "unknown_key", field: k };
  }
  const repo = typeof body.repo === "string" ? body.repo.trim().toLowerCase() : "";
  if (!REPO_RE.test(repo)) return { error: "invalid_field", field: "repo" };
  const number = body.number;
  if (!Number.isSafeInteger(number) || number < 1) return { error: "invalid_field", field: "number" };
  if (!SOURCES.includes(body.source)) return { error: "invalid_field", field: "source" };
  const at = body.at === undefined ? now : body.at;
  if (typeof at !== "string" || !AT_RE.test(at) || Number.isNaN(Date.parse(at))) return { error: "invalid_field", field: "at" };
  if (!isObj(body.fields) || Object.keys(body.fields).length === 0) return { error: "invalid_field", field: "fields" };
  const fields = {};
  for (const [k, v] of Object.entries(body.fields)) {
    if (!Object.hasOwn(VALUE_FIELDS, k)) return { error: "unknown_field", field: k };
    if (v === null && NULLABLE_FIELDS.includes(k)) { fields[k] = null; continue; }
    const val = VALUE_FIELDS[k](v);
    if (val === undefined) return { error: "invalid_field", field: k };
    fields[k] = val;
  }
  return { repo, number, source: body.source, at, fields };
}

// The upsert for these field names. Binds: ?1 repo, ?2 number, ?3 at,
// ?4 source, then one value per field in `names` order. In an UPDATE every
// right-hand side reads the row as it was before the update.
// refresh: false keeps refreshed_at on an existing row: a write that does not
// carry the whole PR (a webhook comment) must not reset the max-age backstop.
export function upsertSql(names, { refresh = true } = {}) {
  const newer = (f) => `(json_extract(pr_records.fields_at, '$.${f}') IS NULL OR json_extract(pr_records.fields_at, '$.${f}') <= ?3)`;
  const cols = names.join(", ");
  const vals = names.map((_, i) => `?${i + 5}`).join(", ");
  const firstAt = `json_object(${names.map((f) => `'${f}', ?3`).join(", ")})`;
  const sets = names.map((f) => `${f} = CASE WHEN ${newer(f)} THEN excluded.${f} ELSE pr_records.${f} END`);
  const atSet = names.map((f) => `'$.${f}', CASE WHEN ${newer(f)} THEN ?3 ELSE json_extract(pr_records.fields_at, '$.${f}') END`).join(", ");
  return `INSERT INTO pr_records (repo, number, ${cols}, fields_at, last_source, gh_read_at, webhook_at, created_at, refreshed_at)
    VALUES (?1, ?2, ${vals}, ${firstAt}, ?4,
            CASE WHEN ?4 = 'github' THEN ?3 END, CASE WHEN ?4 = 'webhook' THEN ?3 END, ?3, ?3)
    ON CONFLICT(repo, number) DO UPDATE SET
      ${sets.join(",\n      ")},
      fields_at = json_set(pr_records.fields_at, ${atSet}),
      last_source = ?4,
      gh_read_at = CASE WHEN ?4 = 'github' THEN max(coalesce(pr_records.gh_read_at, ''), ?3) ELSE pr_records.gh_read_at END,
      webhook_at = CASE WHEN ?4 = 'webhook' THEN max(coalesce(pr_records.webhook_at, ''), ?3) ELSE pr_records.webhook_at END,
      refreshed_at = ${refresh ? "max(pr_records.refreshed_at, ?3)" : "pr_records.refreshed_at"}
    RETURNING *`;
}

// A row as it leaves the worker: the JSON columns parsed.
export function outRow(r) {
  if (!r) return null;
  const o = { ...r };
  for (const k of JSON_FIELDS) {
    if (typeof o[k] === "string") { try { o[k] = JSON.parse(o[k]); } catch { /* left as stored */ } }
  }
  return o;
}

const guarded = (fn) => (ctx) =>
  d1Guarded("pr_records", async () => {
    await ensureTable(ctx.env, "pr_records");
    await ensureColumns(ctx.env, "pr_records");
    return fn(ctx);
  });

export { guarded };

export const routes = [
  [
    "PUT", "/api/pr-records",
    guarded(async ({ env, t, body }) => {
      const c = checkPut(body, t);
      if (c.error) return json(400, c.field ? { error: c.error, field: c.field } : { error: c.error });
      const names = Object.keys(c.fields);
      const r = await env.DB.prepare(upsertSql(names))
        .bind(c.repo, c.number, c.at, c.source, ...names.map((f) => c.fields[f])).first();
      if (!r) return json(503, { error: "pr_records: the row did not read back" });
      const row = outRow(r);
      const applied = names.filter((f) => row.fields_at && row.fields_at[f] === c.at);
      const stale = names.filter((f) => !applied.includes(f));
      return json(200, { row, applied, stale });
    }),
  ],
  [
    "GET", "/api/pr-records",
    guarded(async ({ env, url, t }) => {
      const repo = (url.searchParams.get("repo") || "").trim().toLowerCase();
      const n = Number(url.searchParams.get("number"));
      if (!REPO_RE.test(repo)) return json(400, { error: "invalid_field", field: "repo" });
      if (!url.searchParams.has("number") && url.searchParams.has("state")) {
        return listRead(env, url, t, repo, url.searchParams.get("state"));
      }
      if (!Number.isSafeInteger(n) || n < 1) return json(400, { error: "invalid_field", field: "number" });
      const r = await env.DB.prepare(GET_SQL).bind(repo, n).first();
      const row = outRow(r);
      const age = row ? Math.floor((Date.parse(t) - Date.parse(row.refreshed_at)) / 1000) : null;
      return json(200, { row, age_s: Number.isFinite(age) ? age : null });
    }),
  ],
];

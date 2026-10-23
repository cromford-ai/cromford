// pr-records routes — BH-8067: the fleet's own record of each fleet-owned PR.
// Table: worker/jobs/schema.d/202610221947-bh-8067-pr-records.sql. Client:
// bin/lib/pr-record.sh (pr_record_put, pr_record_get).
// test/route-table.d/bh-8067-pr-records.txt pins this route list.
//
// PUT /api/pr-records  {repo, number, source, at?, fields: {...}}
//   source is fleet | webhook | github. at is YYYY-MM-DDTHH:MM:SSZ, default
//   the worker's clock. fields holds one or more of the VALUE_FIELDS columns.
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
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const SHA_RE = /^[0-9a-f]{40}$/;
const WORD_RE = /^[a-z_]{1,32}$/;
const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const REPO_RE = /^[a-z0-9_.-]{1,100}\/[a-z0-9_.-]{1,100}$/;
export const SOURCES = ["fleet", "webhook", "github"];
// Input shape bounds, not tunable limits: GitHub allows at most 100 labels on
// an issue or PR, and a git ref name of at most 255 bytes.
const LABELS_MAX = 100;
const NAME_MAX = 100;
const REF_MAX = 255;
const CHECKS_MAX = 100;

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const ref = (v) => (typeof v === "string" && v.length >= 1 && v.length <= REF_MAX ? v : undefined);
const sha = (v) => (typeof v === "string" && SHA_RE.test(v.toLowerCase()) ? v.toLowerCase() : undefined);
const word = (v) => (typeof v === "string" && WORD_RE.test(v) ? v : undefined);

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
};
const JSON_FIELDS = ["labels", "checks", "fields_at"];

export const GET_SQL = "SELECT * FROM pr_records WHERE repo = ?1 AND number = ?2";

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
    const val = VALUE_FIELDS[k](v);
    if (val === undefined) return { error: "invalid_field", field: k };
    fields[k] = val;
  }
  return { repo, number, source: body.source, at, fields };
}

// The upsert for these field names. Binds: ?1 repo, ?2 number, ?3 at,
// ?4 source, then one value per field in `names` order. In an UPDATE every
// right-hand side reads the row as it was before the update.
export function upsertSql(names) {
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
      refreshed_at = max(pr_records.refreshed_at, ?3)
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
    return fn(ctx);
  });

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
      if (!Number.isSafeInteger(n) || n < 1) return json(400, { error: "invalid_field", field: "number" });
      const r = await env.DB.prepare(GET_SQL).bind(repo, n).first();
      const row = outRow(r);
      const age = row ? Math.floor((Date.parse(t) - Date.parse(row.refreshed_at)) / 1000) : null;
      return json(200, { row, age_s: Number.isFinite(age) ? age : null });
    }),
  ],
];

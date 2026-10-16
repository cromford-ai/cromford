// model-watch routes — BH-3425 (BH-3422.0) contract, BH-3426 (BH-3422.1)
// bodies: the daily model-watch lane over model_watch (worker/jobs/schema.sql).
//
//   POST /api/model-watch          record a seen vendor model (first write wins)
//   GET  /api/model-watch          ?status&vendor — at most 500 rows, newest first_seen first
//   PUT  /api/model-watch/state    move a row's status / suggestion / probe stamps
//   GET  /api/model-watch/usage    ?model&since — one aggregate over cost_rows
//
// vendor and model_id are trimmed and lowercased here, once, by `norm`, on
// every write and every lookup (D17). The fuller rewrite (vendor prefix,
// `:free`, date suffix) is mw_norm_id's job on the shell side, before it POSTs.
//
// The shell side is mw_record / mw_get / mw_set_state / mw_usage in
// bin/lib/model-watch.sh.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

// The table's own CHECK set. Compared exactly: "New" is not "new".
const STATUSES = ["new", "suggested", "adopted", "ignored"];
const LIST_CAP = 500;
const NUMERIC = ["prompt", "completion", "cache_read", "cache_write", "context_window"];
const TEXT = ["slug", "source_url", "released_at"];
// PUT's settable columns: a fixed list, so a column name never comes from the body.
const STATE = ["status", "suggestion", "probe", "probe_attempted_at", "announced_at"];
const AUDIT = ["actor", "reason"];
const JSON_TEXT = ["suggestion", "probe"];

const norm = (v) => (typeof v === "string" ? v.trim().toLowerCase() : "");
const str = (v) => (typeof v === "string" ? v.trim() : "");
const has = (o, k) => o[k] !== undefined && o[k] !== null;

const rowOf = (env, vendor, modelId) =>
  env.DB.prepare("SELECT * FROM model_watch WHERE vendor=?1 AND model_id=?2").bind(vendor, modelId).first();

async function record({ env, body, t }) {
  const vendor = norm(body.vendor), modelId = norm(body.model_id), source = str(body.source);
  if (!vendor) return json(400, { error: "vendor required" });
  if (!modelId) return json(400, { error: "model_id required" });
  if (!source) return json(400, { error: "source required" });
  const nums = [];
  for (const k of NUMERIC) {
    // Absent is NULL; junk is a 400, never a silent 0 or NULL (D11).
    if (!has(body, k)) { nums.push(null); continue; }
    if (typeof body[k] !== "number" || !Number.isFinite(body[k])) return json(400, { error: `${k} must be a number` });
    nums.push(body[k]);
  }
  const texts = TEXT.map((k) => (typeof body[k] === "string" ? body[k] : null));
  return d1Guarded("model_watch", async () => {
    await ensureTable(env, "model_watch");
    const r = await env.DB.prepare(
      `INSERT INTO model_watch (vendor, model_id, slug, source, source_url, released_at,
         prompt, completion, cache_read, cache_write, context_window, first_seen, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
       ON CONFLICT(vendor, model_id) DO NOTHING`,
    ).bind(vendor, modelId, texts[0], source, texts[1], texts[2], ...nums, t, t).run();
    const first = (r && r.meta && r.meta.changes) === 1;
    return json(200, { recorded: true, first, row: await rowOf(env, vendor, modelId) });
  });
}

async function list({ env, url }) {
  const status = url.searchParams.get("status") || "";
  const vendor = norm(url.searchParams.get("vendor"));
  // Empty means no filter: mw_get always sends both params, possibly empty.
  if (status && !STATUSES.includes(status)) return json(400, { error: `status must be one of ${STATUSES.join("|")}` });
  const where = [], binds = [];
  if (status) { binds.push(status); where.push(`status=?${binds.length}`); }
  if (vendor) { binds.push(vendor); where.push(`vendor=?${binds.length}`); }
  return d1Guarded("model_watch", async () => {
    await ensureTable(env, "model_watch");
    const sql = `SELECT * FROM model_watch${where.length ? ` WHERE ${where.join(" AND ")}` : ""}
      ORDER BY first_seen DESC, vendor, model_id LIMIT ${LIST_CAP + 1}`;
    const { results = [] } = await env.DB.prepare(sql).bind(...binds).all();
    // A capped read says so (D12).
    return json(200, { rows: results.slice(0, LIST_CAP), truncated: results.length > LIST_CAP });
  });
}

async function setState({ env, body, t }) {
  const vendor = norm(body.vendor), modelId = norm(body.model_id);
  if (!vendor) return json(400, { error: "vendor required" });
  if (!modelId) return json(400, { error: "model_id required" });
  // Before the row lookup, so an unknown status is a 400 even for an absent row.
  if (body.status !== undefined && !STATUSES.includes(body.status)) {
    return json(400, { error: `status must be one of ${STATUSES.join("|")}` });
  }
  // A reason alone is a write too: bin/model-watch-approve.sh records a partial
  // approval's per-route results without touching status (BH-3428 P3). An
  // actor alone says nothing, so it stays a 400.
  const keys = STATE.filter((k) => body[k] !== undefined);
  if (!keys.length && body.reason === undefined) {
    return json(400, { error: `nothing to set: one of ${STATE.join(", ")} or reason required` });
  }
  keys.push(...AUDIT.filter((k) => body[k] !== undefined));
  // suggestion / probe are TEXT columns: a JSON value is stored as its JSON text,
  // never handed to bind() as an object.
  const binds = keys.map((k) => (JSON_TEXT.includes(k) && body[k] !== null && typeof body[k] === "object"
    ? JSON.stringify(body[k]) : body[k]));
  const sets = keys.map((k, i) => `${k}=?${i + 1}`);
  binds.push(t, vendor, modelId);
  sets.push(`updated_at=?${binds.length - 2}`);
  return d1Guarded("model_watch", async () => {
    await ensureTable(env, "model_watch");
    // sql-ident-ok: sets names columns only from the STATE and AUDIT module const lists, every value a ?N bind
    const r = await env.DB.prepare(
      `UPDATE model_watch SET ${sets.join(", ")} WHERE vendor=?${binds.length - 1} AND model_id=?${binds.length}`,
    ).bind(...binds).run();
    if (!(r && r.meta && r.meta.changes)) return json(404, { error: "no such model_watch row" });
    return json(200, { updated: true, row: await rowOf(env, vendor, modelId) });
  });
}

async function usage({ env, url }) {
  const model = str(url.searchParams.get("model")), since = str(url.searchParams.get("since"));
  if (!model) return json(400, { error: "model required" });
  if (!since) return json(400, { error: "since required" });
  // One aggregate, never paged (D12). `rows` is what tells "no rows" from "no spend".
  return d1Guarded("cost_rows", async () => {
    const r = await env.DB.prepare(
      `SELECT COUNT(*) AS rows, COALESCE(SUM(input_toks),0) AS input_toks, COALESCE(SUM(output_toks),0) AS output_toks,
         COALESCE(SUM(cache_read),0) AS cache_read, COALESCE(SUM(cache_write),0) AS cache_write
       FROM cost_rows WHERE model=?1 AND ts>=?2`,
    ).bind(model, since).first();
    return json(200, {
      model, since,
      rows: Number(r.rows), input_toks: Number(r.input_toks), output_toks: Number(r.output_toks),
      cache_read: Number(r.cache_read), cache_write: Number(r.cache_write),
    });
  });
}

export const routes = [
  ["POST", "/api/model-watch", record],
  ["GET", "/api/model-watch", list],
  ["PUT", "/api/model-watch/state", setState],
  ["GET", "/api/model-watch/usage", usage],
];

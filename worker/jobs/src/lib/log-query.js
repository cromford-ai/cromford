// Shared query helpers of the log routes (BH-9308, BH-9120.4): GET /api/jobs
// and GET /api/lane-runs take a range plus search, server sort, a keyset
// cursor, totals and a series. Each helper validates one param and answers
// {v} or {err}; the routes turn an err into a 400 before any table read.
//
// Nothing here reads a table. Every value that goes into SQL TEXT comes from
// an allowlist the route passes in; user text is always a bind.

// The search text has no length cap of its own: it is one bound value, and
// the request URL already bounds it.
const HOUR_MS = 3600e3;
const DAY_MS = 86400e3;
const SERIES = ["hour", "day", "week"];

// A param that is present and not blank after trim.
export const given = (sp, name) => sp.has(name) && sp.get(name).trim() !== "";

// The first param in `names` that is given, or null. A route uses it to refuse
// the range-only params on a request with no from/to.
export function firstGiven(sp, names) {
  for (const n of names) if (given(sp, n)) return n;
  return null;
}

// likeEscape(s): `\` -> `\\`, `%` -> `\%`, `_` -> `\_`, for LIKE ... ESCAPE '\'.
export const likeEscape = (s) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

// searchParam(sp) -> {v: null} (no search), {v: '%<escaped>%'} or {err}.
export function searchParam(sp) {
  const raw = (sp.get("q") || "").trim();
  if (raw === "") return { v: null };
  return { v: `%${likeEscape(raw)}%` };
}

// likeClause(cols, n) -> `(a LIKE ?n ESCAPE '\' OR b LIKE ?n ESCAPE '\')`.
// `cols` is the route's fixed column list; ?n is one bind used by every column.
export const likeClause = (cols, n) => `(${cols.map((c) => `${c} LIKE ?${n} ESCAPE '\\'`).join(" OR ")})`;

// sortParam(sp, allow, defKey) -> {key, col, type, dir} or {err}.
// allow: {key: {col, type: 'text'|'num'}}. dir in asc|desc, default desc.
export function sortParam(sp, allow, defKey) {
  const key = given(sp, "sort") ? sp.get("sort") : defKey;
  if (!Object.prototype.hasOwnProperty.call(allow, key)) {
    return { err: `sort must be one of ${Object.keys(allow).join("|")}` };
  }
  const d = given(sp, "dir") ? sp.get("dir") : "desc";
  if (d !== "asc" && d !== "desc") return { err: "dir must be asc or desc" };
  return { key, col: allow[key].col, type: allow[key].type, dir: d };
}

// orderBy(sort, idCol) -> `<col> ASC, <id> ASC` (or DESC).
export const orderBy = (s, idCol) => `${s.col} ${s.dir.toUpperCase()}, ${idCol} ${s.dir.toUpperCase()}`;

// keysetClause(sort, idCol, n) -> the WHERE part after the cursor row, binds
// ?n (sort value) and ?n+1 (id). Never OFFSET.
export function keysetClause(s, idCol, n) {
  const op = s.dir === "asc" ? ">" : "<";
  return `(${s.col} ${op} ?${n} OR (${s.col} = ?${n} AND ${idCol} ${op} ?${n + 1}))`;
}

const b64urlEncode = (str) => {
  let bin = "";
  for (const b of new TextEncoder().encode(str)) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
function b64urlDecode(s) {
  if (!/^[A-Za-z0-9_-]+$/.test(s) || s.length % 4 === 1) return null;
  try {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

// encodeCursor(value, id) -> base64url (no padding) of JSON [value, id].
export const encodeCursor = (value, id) => b64urlEncode(JSON.stringify([value, id]));

const typeOk = (v, type) => (type === "num" ? typeof v === "number" && Number.isFinite(v) : typeof v === "string");

// cursorParam(sp, sortType, idType) -> {v: null} (no cursor), {v: [value, id]}
// or {err: "cursor is not valid"}. The value type must match the sort column
// and the id type the table's id.
export function cursorParam(sp, sortType, idType) {
  if (!given(sp, "cursor")) return { v: null };
  const bad = { err: "cursor is not valid" };
  const text = b64urlDecode(sp.get("cursor").trim());
  if (text === null) return bad;
  let arr;
  try { arr = JSON.parse(text); } catch { return bad; }
  if (!Array.isArray(arr) || arr.length !== 2) return bad;
  if (!typeOk(arr[0], sortType) || !typeOk(arr[1], idType)) return bad;
  return { v: arr };
}

// flagParam(sp, name) -> {v: bool} or {err}: absent, "" or "0" is off, "1" on.
export function flagParam(sp, name) {
  const raw = sp.has(name) ? sp.get(name).trim() : "";
  if (raw === "" || raw === "0") return { v: false };
  if (raw === "1") return { v: true };
  return { err: `${name} must be 1` };
}

// formatParam(sp) -> {v: null|'csv'} or {err}.
export function formatParam(sp) {
  if (!given(sp, "format")) return { v: null };
  return sp.get("format").trim() === "csv" ? { v: "csv" } : { err: "format must be csv" };
}

const isoOf = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// The start (epoch ms) of the bucket that holds `ms`, in the bucketExpr shape:
// hour floors to the hour, day to UTC midnight, week to the Monday.
function bucketStart(series, ms) {
  if (series === "hour") return Math.floor(ms / HOUR_MS) * HOUR_MS;
  const d = Math.floor(ms / DAY_MS) * DAY_MS;
  if (series === "day") return d;
  const dow = new Date(d).getUTCDay(); // 0 Sunday .. 6 Saturday
  return d - ((dow + 6) % 7) * DAY_MS;
}
const STEP = { hour: HOUR_MS, day: DAY_MS, week: 7 * DAY_MS };
const label = (series, ms) => (series === "hour" ? `${isoOf(ms).slice(0, 13)}:00:00Z` : isoOf(ms).slice(0, 10));

// seriesParam(sp, range, maxBuckets) -> {v: null} (no series),
// {v: {series, buckets: [label]}} or {err}. The buckets run from the bucket of
// `from` up to, not including, `to`; the labels are the strings bucketExpr
// yields. Over maxBuckets is an error, counted before any label is built.
export function seriesParam(sp, range, maxBuckets) {
  if (!given(sp, "series")) return { v: null };
  const series = sp.get("series").trim();
  if (!SERIES.includes(series)) return { err: "series must be hour, day or week" };
  const start = bucketStart(series, Date.parse(range.from));
  const end = Date.parse(range.to);
  const count = Math.ceil((end - start) / STEP[series]);
  if (count > maxBuckets) return { err: `range has over ${maxBuckets} ${series} buckets (mc.period.max_buckets)` };
  const buckets = [];
  for (let ms = start; ms < end; ms += STEP[series]) buckets.push(label(series, ms));
  return { v: { series, buckets } };
}

// fillSeries(buckets, rows) -> [{bucket, value}] for every bucket; a bucket
// with no row is null (a gap), never 0.
export function fillSeries(buckets, rows) {
  const by = new Map((rows || []).map((r) => [r.bucket, Number(r.n)]));
  return buckets.map((b) => ({ bucket: b, value: by.has(b) ? by.get(b) : null }));
}

// pageOut(rows, limit, sort, idKey) -> {rows, next_cursor}. `rows` were read
// with LIMIT limit+1; a row past the limit means there is a next page.
export function pageOut(rows, limit, sort, idKey) {
  if (rows.length <= limit) return { rows, next_cursor: null };
  const kept = rows.slice(0, limit);
  const last = kept[kept.length - 1];
  const raw = last[sort.key];
  const value = sort.type === "num" ? Number(raw) : raw;
  return { rows: kept, next_cursor: encodeCursor(value, idKey === "num" ? Number(last.id) : last.id) };
}

// The period core of the harness-jobs worker (BH-9304, BH-9120.0): one way to
// read a ?from=&to= range, bucket a time column, read the mc.period.* knobs
// and write a CSV. Every report route of #9120 imports it.
//
// console-ui/functions/_lib/period.js holds a copy of PERIOD_FALLBACKS,
// parseRange, bucketExpr, toCsv and csvResponse for the Pages functions.
// worker/jobs/test/period.bh-9304.test.js (PAR1) runs both and compares.
//
// Times are UTC and use the stored form YYYY-MM-DDTHH:MM:SSZ (lib/http.js
// nowIso), so a bound text compare on created_at is a time compare. `to` is
// exclusive: ts >= from AND ts < to.

// Code fallbacks. Each one is the value of its settings row and is used only
// when that row is absent or not valid.
export const PERIOD_FALLBACKS = Object.freeze({
  max_range_days: 366,          // settings row mc.period.max_range_days
  csv_row_cap: 100000,          // settings row mc.period.csv_row_cap
  default_preset: "last_7_days", // settings row mc.period.default_preset
  max_buckets: 2000,            // settings row mc.period.max_buckets
  report_top_rows: 20,          // settings row mc.period.report_top_rows (BH-9308)
  filter_chip_cap: 30,          // settings row mc.period.filter_chip_cap (BH-9308)
});

const PRESETS = ["today", "yesterday", "last_7_days", "last_30_days", "this_month", "last_month"];
const DAY_MS = 86400000;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?(Z|([+-])(\d{2}):(\d{2}))$/;

const isoSec = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

// One ISO value to epoch ms, or null. A real calendar check: 2026-02-30 and
// 25:00 are refused, not rolled over.
function parseIso(v) {
  let m = DATE_RE.exec(v);
  let y, mo, d, hh = 0, mi = 0, ss = 0, off = 0;
  if (m) {
    [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  } else if ((m = TIME_RE.exec(v))) {
    [y, mo, d, hh, mi] = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])];
    ss = m[6] === undefined ? 0 : Number(m[6]);
    if (m[7] !== "Z") {
      const oh = Number(m[9]), om = Number(m[10]);
      if (oh > 23 || om > 59) return null;
      off = (m[8] === "-" ? -1 : 1) * (oh * 60 + om) * 60000;
    }
  } else {
    return null;
  }
  if (hh > 23 || mi > 59 || ss > 59) return null;
  const ms = Date.UTC(y, mo - 1, d, hh, mi, ss);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  return ms - off;
}

const badIso = (side) => ({ error: `${side} is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)` });

// parseRange(url, knobs, nowMs) -> null (no range param), {from, to}, or {error}.
// `url` is a URL or a URLSearchParams. The first value of a repeated param is
// used. A param that is sent but empty is an error, not "absent".
export function parseRange(url, knobs, nowMs) {
  const sp = url instanceof URLSearchParams ? url : url.searchParams;
  const hasFrom = sp.has("from"), hasTo = sp.has("to");
  if (!hasFrom && !hasTo) return null;
  if (!hasFrom) return { error: "from is required when to is given" };
  const from = parseIso(sp.get("from"));
  if (from === null) return badIso("from");
  let to = Math.floor(nowMs / 1000) * 1000;
  if (hasTo) {
    to = parseIso(sp.get("to"));
    if (to === null) return badIso("to");
  }
  if (from >= to) return { error: "from must be before to" };
  const days = (knobs && Number.isInteger(knobs.max_range_days)) ? knobs.max_range_days : PERIOD_FALLBACKS.max_range_days;
  if (to - from > days * DAY_MS) return { error: `range is over ${days} days (mc.period.max_range_days)` };
  return { from: isoSec(from), to: isoSec(to) };
}

// bucketExpr(bucket, col) -> one of 3 fixed SQL fragments, or null. The column
// name is checked, never quoted: only [a-z_] and one optional table prefix.
// A week starts on Monday.
const COL_RE = /^[a-z_]+(\.[a-z_]+)?$/;
export function bucketExpr(bucket, col) {
  if (typeof col !== "string" || !COL_RE.test(col)) return null;
  if (bucket === "hour") return `strftime('%Y-%m-%dT%H:00:00Z', ${col})`;
  if (bucket === "day") return `date(${col})`;
  if (bucket === "week") return `date(${col}, 'weekday 0', '-6 days')`;
  return null;
}

const intIn = (lo, hi) => (v) => (/^\d+$/.test(v) && Number(v) >= lo && Number(v) <= hi ? Number(v) : undefined);
const KNOB_PARSE = {
  max_range_days: intIn(1, 3660),
  csv_row_cap: intIn(1, 1000000),
  default_preset: (v) => (PRESETS.includes(v) ? v : undefined),
  max_buckets: intIn(1, 100000),
  // The top rows of a log screen's period report, sent as `limit`: at most
  // 200, under the limit cap of each of the four log routes.
  report_top_rows: intIn(1, 200),
  // The most LANE / PROJECT filter chips a log screen draws.
  filter_chip_cap: intIn(1, 500),
};

// readPeriodKnobs(env) -> {max_range_days, csv_row_cap, default_preset,
// max_buckets, report_top_rows, filter_chip_cap,
// source: {<key>: 'row' | 'fallback'}}. ONE primary-key range
// statement. A junk value uses the fallback. A D1 error is thrown to the
// caller (the router answers it), never turned into the fallbacks.
export async function readPeriodKnobs(env) {
  const res = await env.DB.prepare(
    "SELECT key, value FROM settings WHERE key >= 'mc.period.' AND key < 'mc.period/'",
  ).all();
  const rows = new Map((res.results || []).map((r) => [r.key, String(r.value).trim()]));
  const out = { source: {} };
  for (const [k, parse] of Object.entries(KNOB_PARSE)) {
    const raw = rows.get(`mc.period.${k}`);
    const v = raw === undefined ? undefined : parse(raw);
    out[k] = v === undefined ? PERIOD_FALLBACKS[k] : v;
    out.source[k] = v === undefined ? "fallback" : "row";
  }
  return out;
}

// RFC 4180: a field with a comma, a quote, CR or LF is quoted and its quotes
// are doubled. Numbers stay raw (String(n)); null and undefined are empty.
function csvField(v) {
  if (v === null || v === undefined) return "";
  const s = String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// toCsv(columns, rows): a header line of the column names, then one line per
// row. A row is an object keyed by column name or an array in column order.
// Every line ends with CRLF.
export function toCsv(columns, rows) {
  const line = (vals) => vals.map(csvField).join(",") + "\r\n";
  let out = line(columns);
  for (const r of rows) out += line(columns.map((c, i) => (Array.isArray(r) ? r[i] : r[c])));
  return out;
}

// csvResponse(columns, rows, {cap, filename}): over `cap` rows it writes the
// first `cap` and then the line `# truncated at <cap>`.
export function csvResponse(columns, rows, { cap = PERIOD_FALLBACKS.csv_row_cap, filename = "export.csv" } = {}) {
  const capped = rows.length > cap;
  const body = toCsv(columns, capped ? rows.slice(0, cap) : rows) + (capped ? `# truncated at ${cap}\r\n` : "");
  const name = String(filename).replace(/[^A-Za-z0-9._-]/g, "_") || "export.csv";
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="${name}"`,
    },
  });
}

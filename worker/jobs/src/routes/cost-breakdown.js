// cost-breakdown route — BH-3557: the fleet's spend, grouped and labelled.
//
// Before this, the only place an operator saw "the fleet spent $1,259 today"
// was the $ TODAY cell of every lane that declared no cost stage (lanes.js now
// reports null there). This is where that number moves to: one grouped read
// over cost_rows by up to two dimensions, plus a leaf read of the rows
// themselves, so every group on /costs drills down to the calls behind it.
//
// NOTHING THE CALLER SENDS IS INTERPOLATED INTO SQL. A dimension or filter
// name is checked against DIMS, and statements() picks its SQL text from
// literals in this file; every value, the rows limit included, is a bind.

import { json, overloadGuardedRoute } from "../lib/http.js";
import { str, ensureColumns } from "../lib/core.js";
import { readHistory, mergeRows, mergeAggregate, mergeGroups } from "../lib/archive-read.js";
import { settingsRows } from "../lib/settings-cache.js";

// dimension -> max filter length. Lengths match the POST's str() caps.
const DIMS = { project: 128, stage: 64, runner: 64, model: 256, billing_mode: 32, ticket: 128 };
const ISO_RE = /^\d{4}-\d{2}-\d{2}T[0-9:.]+Z$/;
// Read limits, not business parameters (same footing as account-usage's LIMITS).
const GROUP_CAP = 500;
const ROWS_MAX = 500;
const ROWS_DEFAULT = 200;

// The aggregate columns. One line of literals, so the sql-command-injection
// check can vouch for every use (its shape (a), BH-4501).
const AGG_COLS = ["COUNT(*) AS calls", "SUM(cost_usd) AS usd", "SUM(CASE WHEN billing_mode='metered' THEN COALESCE(cost_usd,0) ELSE 0 END) AS cash_usd", "SUM(CASE WHEN billing_mode='subscription' THEN COALESCE(cost_usd,0) ELSE 0 END) AS equiv_usd", "SUM(cost_usd IS NULL) AS unpriced_calls"];
// For the ticket grouping the bare run_id/job_id/project come from the row
// holding MAX(ts): SQLite's documented bare-column rule for a query with
// exactly one min()/max() aggregate (D1 is SQLite). That is what lets a
// ticket link to its newest build or job.
const LAST_COLS = ", run_id AS last_run_id, job_id AS last_job_id, project AS last_project";
// How two stores' AGG_COLS rows combine (lib/archive-read.js mergeAggregate).
const AGG_SPEC = { calls: "sum", usd: "sum", cash_usd: "sum", equiv_usd: "sum", unpriced_calls: "sum" };
const desc = (a, b) => (a < b ? 1 : a > b ? -1 : 0);
// SQLite's ORDER BY for TEXT: NULL first, then by code unit.
const asc = (a, b) => (a === b ? 0 : a === null ? -1 : b === null ? 1 : a < b ? -1 : 1);

// statements(q, since, until, group, limit) — the three reads and their binds.
// The SQL text is literals only: each filter clause and each grouped column is
// a literal picked by a switch on a DIMS key (`group` is checked against DIMS
// before this runs). Every value the caller sends is an anonymous `?` bind, in
// the order its `?` appears. The sql-command-injection check proves it per line.
// A filter present and EMPTY (`project=`) means "has none": NULL, '' and
// whitespace all fold into one null group below, so a `(no project)` group
// drills down through exactly that clause. `total` is a second statement, so
// the total is exact even when the groups are capped. No comment line may sit
// between `where = []` and its last use: the check reads comment lines as
// unseen lines and stops vouching for the array.
function statements(q, since, until, group, limit) {
  const binds = [since, until];
  const where = [];
  where.push("ts >= ?", "ts <= ?");
  const filters = {};
  for (const [k, max] of Object.entries(DIMS)) {
    if (!q.has(k)) continue;
    const v = str(q.get(k), max);
    filters[k] = v === null ? "" : v;
    if (v !== null) binds.push(v);
    switch (k) {
      case "project": where.push(v === null ? "(project IS NULL OR TRIM(project)='')" : "project=?"); break;
      case "stage": where.push(v === null ? "(stage IS NULL OR TRIM(stage)='')" : "stage=?"); break;
      case "runner": where.push(v === null ? "(runner IS NULL OR TRIM(runner)='')" : "runner=?"); break;
      case "model": where.push(v === null ? "(model IS NULL OR TRIM(model)='')" : "model=?"); break;
      case "billing_mode": where.push(v === null ? "(billing_mode IS NULL OR TRIM(billing_mode)='')" : "billing_mode=?"); break;
      case "ticket": where.push(v === null ? "(ticket IS NULL OR TRIM(ticket)='')" : "ticket=?"); break;
    }
  }
  const cols = [];
  for (const d of group) {
    switch (d) {
      case "project": cols.push("NULLIF(TRIM(project),'') AS project"); break;
      case "stage": cols.push("NULLIF(TRIM(stage),'') AS stage"); break;
      case "runner": cols.push("NULLIF(TRIM(runner),'') AS runner"); break;
      case "model": cols.push("NULLIF(TRIM(model),'') AS model"); break;
      case "billing_mode": cols.push("NULLIF(TRIM(billing_mode),'') AS billing_mode"); break;
      case "ticket": cols.push("NULLIF(TRIM(ticket),'') AS ticket"); break;
    }
  }
  return {
    filters,
    rows: {
      sql: `SELECT ts, box, row_hash, project, stage, runner, model, billing_mode, ticket, job_id, run_id, pr, cost_usd, rc, duration_s FROM cost_rows WHERE ${where.join(" AND ")} ORDER BY ts DESC LIMIT ?`,
      binds: [...binds, limit],
    },
    groups: {
      sql: `SELECT ${cols.join(", ")}, ${AGG_COLS.join(", ")}, MAX(ts) AS last_ts${group.includes("ticket") ? LAST_COLS : ""} FROM cost_rows WHERE ${where.join(" AND ")} GROUP BY ${group.length === 2 ? "1, 2" : "1"} ORDER BY SUM(COALESCE(cost_usd,0)) DESC, ${group.length === 2 ? "1, 2" : "1"} LIMIT ?`,
      binds: [...binds, GROUP_CAP],
    },
    total: { sql: `SELECT ${AGG_COLS.join(", ")} FROM cost_rows WHERE ${where.join(" AND ")}`, binds },
  };
}

// ── The day's CASH line (BH-9068) ─────────────────────────────────────────
// cash = subscriptions + overage + metered, for the UTC day of `until`:
//   subscriptions  each account's usd_per_month / the days in that month. The
//                  account list is the D1 fleet registry (registry_box_accounts,
//                  the source catalog/cost-accounts.json is exported from since
//                  BH-5651). The price is the settings row
//                  cost.usd_per_month.<account>, read through the same settings
//                  snapshot GET /api/settings serves. bin/cost-prices-push.sh
//                  writes those rows from catalog/cost-accounts.json
//                  usd_per_month ("null" for a null). A row that is absent or
//                  is not a number >= 0 is unknown.
//   overage        the rise of each account's extra-usage meter over the day's
//                  ok readings (extra_usage_snapshots.box is the account label).
//                  A drop is a monthly reset and is not counted down. It covers
//                  the first to the last reading of the day.
//   metered        the day's vendor_spend usd.
// ABSENT IS NOT ZERO. A part with any missing input is null, cash_usd is null,
// and `unknown` names each missing input: subscription:<account> (no price),
// subscription:no-registry-account, overage:<account> (under two readings
// today), overage:no-readable-account, metered:<vendor> (a row with no usd),
// metered:no-vendor-spend-row.
// TWO INPUTS ARE NOT MISSING, THEY ARE OUT OF SCOPE, and each is named in
// `excluded` ({part, name, why}) and left out of the sum. Neither makes
// cash_usd null:
//   why=no-login            an account with no usd reading today whose polls
//                           were recorded status=no-login (a setup-token cannot
//                           read the usage endpoint, bin/extra-usage-track.sh).
//                           Its overage is not in the line, and the line says so.
//   why=subscription-billed a vendor whose polls today were all recorded
//                           status=no-spend-endpoint (bin/vendor-spend-pull.sh
//                           writes that for a vendor that bills a subscription,
//                           with no usd, every hour). It is not metered cash.
//                           Its subscription is a row under subscriptions, priced
//                           by the settings row cost.usd_per_month.<vendor>; with
//                           no price row it is unknown as subscription:<vendor>.
// A no-spend-endpoint poll of a vendor that also has ok polls today is not
// counted as unmeasured. An auth-failed or error poll with no usd still is.
// The two money reads are single aggregates on the ts indexes (EXPLAIN in
// test/cost-cash.bh-9068.test.js); the account read is the registry PK.
export const CASH_OVERAGE_SQL = "SELECT box, SUM(has_usd) AS readings, SUM(CASE WHEN d > 0 THEN d ELSE 0 END) AS usd, SUM(no_login) AS no_login FROM (SELECT box, extra_used_usd IS NOT NULL AS has_usd, COALESCE(status,'') = 'no-login' AS no_login, extra_used_usd - LAG(extra_used_usd) OVER (PARTITION BY box, extra_used_usd IS NOT NULL ORDER BY ts) AS d FROM extra_usage_snapshots WHERE ts >= ?1 AND ts <= ?2) GROUP BY box";
export const CASH_METERED_SQL = "SELECT vendor, COUNT(*) AS polls, SUM(usd) AS usd, SUM(usd IS NULL AND COALESCE(status,'') <> 'no-spend-endpoint') AS unmeasured, SUM(usd IS NULL AND COALESCE(status,'') = 'no-spend-endpoint') AS no_endpoint, SUM(usd IS NOT NULL) AS measured FROM vendor_spend WHERE ts >= ?1 AND ts <= ?2 GROUP BY vendor";
export const CASH_ACCOUNTS_SQL = "SELECT DISTINCT account FROM registry_box_accounts ORDER BY account";
export const PRICE_KEY_PREFIX = "cost.usd_per_month.";
const PRICE_RE = /^\d+(\.\d+)?$/;
const r6 = (n) => Math.round(n * 1e6) / 1e6;

// cashSummary — the pure half. `accounts` is the list of account labels,
// `prices` maps account -> its settings value (a string, as D1 stores it).
export function cashSummary({ day, accounts, prices, overageRows, vendorRows }) {
  const [y, m] = day.split("-").map(Number);
  const daysInMonth = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const meters = new Map((overageRows || []).map((r) => [String(r.box), r]));
  const unknown = [];
  const excluded = [];
  const price = (name) => {
    const raw = prices.get(name);
    return typeof raw === "string" && PRICE_RE.test(raw.trim()) ? Number(raw.trim()) : null;
  };
  const rows = [...new Set(accounts || [])].sort().map((account) => {
    const usdPerMonth = price(account);
    const meter = meters.get(account);
    const readings = meter ? Number(meter.readings) || 0 : 0;
    // No usd reading at all today and at least one no-login poll: the account
    // is known to have no readable meter. One reading is still a gap.
    const noLogin = readings === 0 && !!meter && Number(meter.no_login) > 0;
    if (usdPerMonth === null) unknown.push(`subscription:${account}`);
    if (noLogin) excluded.push({ part: "overage", name: account, why: "no-login" });
    else if (readings < 2) unknown.push(`overage:${account}`);
    return {
      account, kind: "account", usd_per_month: usdPerMonth,
      day_usd: usdPerMonth === null ? null : r6(usdPerMonth / daysInMonth),
      overage_usd: readings < 2 ? null : r6(Number(meter.usd)),
      readings, overage_excluded: noLogin ? "no-login" : null,
    };
  });
  if (!rows.length) unknown.push("subscription:no-registry-account");
  const vendors = (vendorRows || []).map((v) => {
    const unmeasured = Number(v.unmeasured) || 0;
    // Every poll today said no-spend-endpoint: a subscription, not metered cash.
    const notCash = unmeasured === 0 && Number(v.no_endpoint) > 0 && !(Number(v.measured) > 0);
    return {
      vendor: v.vendor, polls: Number(v.polls), unmeasured,
      usd: unmeasured > 0 || notCash ? null : r6(Number(v.usd)),
      excluded: notCash ? "subscription-billed" : null,
    };
  }).sort((a, b) => (a.vendor < b.vendor ? -1 : a.vendor > b.vendor ? 1 : 0));
  const taken = new Set(rows.map((r) => r.account));
  for (const v of vendors) {
    if (!v.excluded) { if (v.usd === null) unknown.push(`metered:${v.vendor}`); continue; }
    excluded.push({ part: "metered", name: v.vendor, why: v.excluded });
    // Its subscription moves under subscriptions. An account of the same name
    // already carries that price row, so it is not counted twice.
    if (taken.has(v.vendor)) continue;
    const usdPerMonth = price(v.vendor);
    if (usdPerMonth === null) unknown.push(`subscription:${v.vendor}`);
    rows.push({
      account: v.vendor, kind: "vendor", usd_per_month: usdPerMonth,
      day_usd: usdPerMonth === null ? null : r6(usdPerMonth / daysInMonth),
      overage_usd: null, readings: 0, overage_excluded: "subscription-billed",
    });
  }
  const meteredIn = vendors.filter((v) => !v.excluded);
  if (!meteredIn.length) unknown.push("metered:no-vendor-spend-row");
  const overageIn = rows.filter((r) => !r.overage_excluded);
  if (rows.length && !overageIn.length) unknown.push("overage:no-readable-account");
  const sum = (list, k) => (list.length && list.every((x) => x[k] !== null)
    ? r6(list.reduce((s, x) => s + x[k], 0)) : null);
  const subscriptions = sum(rows, "day_usd");
  const overage = sum(overageIn, "overage_usd");
  const metered = sum(meteredIn, "usd");
  const parts = [subscriptions, overage, metered];
  return {
    day, subscriptions_usd: subscriptions, overage_usd: overage, metered_usd: metered,
    cash_usd: parts.every((x) => x !== null) ? r6(parts[0] + parts[1] + parts[2]) : null,
    unknown, excluded, accounts: rows, vendors,
  };
}

// readCash — the three reads and the settings snapshot, run in parallel.
async function readCash(env, until) {
  const day = until.slice(0, 10);
  const since = `${day}T00:00:00Z`;
  const [ov, ve, ac, st] = await Promise.all([
    env.DB.prepare(CASH_OVERAGE_SQL).bind(since, until).all(),
    env.DB.prepare(CASH_METERED_SQL).bind(since, until).all(),
    env.DB.prepare(CASH_ACCOUNTS_SQL).all(),
    settingsRows(env),
  ]);
  const prices = new Map();
  for (const r of st.rows) {
    if (typeof r.key === "string" && r.key.startsWith(PRICE_KEY_PREFIX)) prices.set(r.key.slice(PRICE_KEY_PREFIX.length), String(r.value));
  }
  return { since, until, ...cashSummary({
    day, accounts: (ac.results || []).map((r) => r.account), prices,
    overageRows: ov.results || [], vendorRows: ve.results || [],
  }) };
}

export const routes = [
  [
    "GET", "/api/metrics/cost-breakdown",
    overloadGuardedRoute("cost_rows", async ({ env, url, t }) => {
      const q = url.searchParams;
      const since = str(q.get("since"), 64) || (t.slice(0, 10) + "T00:00:00Z");
      const until = str(q.get("until"), 64) || t;
      if (!ISO_RE.test(since)) return json(400, { error: "since must be an ISO UTC timestamp" });
      if (!ISO_RE.test(until)) return json(400, { error: "until must be an ISO UTC timestamp" });

      const groupRaw = str(q.get("group"), 64) || "project";
      const rowsMode = groupRaw === "rows";
      const group = rowsMode ? [] : groupRaw.split(",");
      if (!rowsMode) {
        if (group.length > 2) return json(400, { error: "group takes at most 2 dimensions" });
        if (group.some((d) => !Object.hasOwn(DIMS, d))) {
          return json(400, { error: `group must be rows or 1-2 of ${Object.keys(DIMS).join("|")}` });
        }
        if (new Set(group).size !== group.length) return json(400, { error: "group repeats a dimension" });
      }

      let limit = ROWS_DEFAULT;
      if (rowsMode && q.has("limit")) {
        limit = Number(q.get("limit"));
        if (!Number.isInteger(limit) || limit < 1 || limit > ROWS_MAX) {
          return json(400, { error: `limit must be an integer 1..${ROWS_MAX}` });
        }
      }

      const st = statements(q, since, until, group, limit);
      const { filters } = st;

      await ensureColumns(env, "cost_rows");

      // A range older than the hot store reads the archive too (BH-6779); a
      // row in both stores (box, row_hash) appears once.
      if (rowsMode) {
        const h = await readHistory(env, { table: "cost_rows", since, now: t, hot: st.rows });
        const rows = mergeRows(h.hot.results || [], h.archive && (h.archive.results || []), {
          key: (r) => `${r.box}\u0000${r.row_hash}`,
          compare: (a, b) => desc(a.ts, b.ts) || asc(a.box, b.box) || asc(a.row_hash, b.row_hash),
          limit,
        });
        return json(200, { since, until, filters, rows, truncated: rows.length === limit, archive: h.state, as_of: t });
      }

      // The CASH line is fleet-wide: only the unfiltered read carries it, so a
      // drill-down costs no extra statement (BH-9068).
      const withCash = Object.keys(filters).length === 0;
      const [g, tot, cash] = await Promise.all([
        readHistory(env, { table: "cost_rows", since, now: t, hot: st.groups }),
        readHistory(env, { table: "cost_rows", since, now: t, hot: st.total, method: "first" }),
        withCash ? readCash(env, until) : null,
      ]);
      // Each store groups and sums its own rows; the two answers merge here.
      // A row in both stores counts twice in a sum: an aggregate cannot dedupe.
      const merged = mergeGroups(g.hot.results || [], g.archive && (g.archive.results || []), {
        by: group, spec: { ...AGG_SPEC, last_ts: "max" }, pickBy: "last_ts", limit: GROUP_CAP,
        compare: (a, b) => ((b.usd ?? 0) - (a.usd ?? 0)) || group.reduce((c, d) => c || asc(a[d], b[d]), 0),
      });
      const groups = merged.rows;
      // An aggregate with no GROUP BY always returns one row; over zero rows its
      // SUMs are NULL. usd stays null (nothing priced); the others are counts
      // and sums of a measured empty window, so 0 is the true answer.
      const total = mergeAggregate(tot.hot, tot.archive, AGG_SPEC);
      // One store unread makes the whole answer partial.
      const states = [g.state, tot.state];
      const archive = states.includes("unreadable") ? "unreadable" : states.includes("read") ? "read" : g.state;
      return json(200, {
        since, until, group, filters,
        total: {
          usd: total.usd ?? null,
          cash_usd: total.cash_usd ?? 0, equiv_usd: total.equiv_usd ?? 0,
          calls: total.calls ?? 0, unpriced_calls: total.unpriced_calls ?? 0,
        },
        groups, truncated: merged.truncated, archive, as_of: t,
        ...(cash ? { cash } : {}),
      });
    }),
  ],
];

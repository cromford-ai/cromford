// usage routes — vendor-reported usage: extra-usage snapshots and the reconcile run.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  numOrNull, intOrNull, boolInt, str, ensureColumns,
  parseAccountMap, ANCHOR_DEFAULT_ACCOUNT_MAP, meterAccounts, anchorSpanCandidates,
} from "../lib/core.js";
import { usageWindow, shapeAccountUsage } from "../lib/account-usage.js";

export const routes = [
  [
    "POST", "/api/metrics/extra-usage",
    async ({ env, body }) => {
      // ts from the row, box from the row: this series is per-ACCOUNT and the
      // box IS the account it bills (see bin/extra-usage-track.sh). Stamping it
      // with the server clock would merge two boxes' polls onto one key.
      const box = str(body.box, 128);
      const ts = str(body.ts, 32);
      if (!box || !ts) return json(400, { error: "box and ts required" });
      await ensureColumns(env, "extra_usage_snapshots");
      // status defaults to "ok" ONLY when the row carries a meter reading. A
      // client too old to send it still posts real polls, and calling those "ok"
      // is true; calling a row with no numbers "ok" would not be.
      const euStatus = str(body.status, 32)
        || (numOrNull(body.extra_used_usd) === null ? null : "ok");
      await env.DB.prepare(
        `INSERT INTO extra_usage_snapshots (box, ts, session_pct, weekly_pct, weekly_resets_at,
                                            extra_enabled, extra_used_usd, spend_limit_reached, in_overage,
                                            extra_limit_usd, extra_pct, status, error_body)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
         ON CONFLICT(box, ts) DO UPDATE SET
           session_pct=?3, weekly_pct=?4, weekly_resets_at=?5, extra_enabled=?6,
           extra_used_usd=?7, spend_limit_reached=?8, in_overage=?9,
           extra_limit_usd=COALESCE(?10, extra_limit_usd), extra_pct=COALESCE(?11, extra_pct),
           status=COALESCE(?12, status), error_body=COALESCE(?13, error_body)`
      ).bind(box, ts, numOrNull(body.session_pct), numOrNull(body.weekly_pct),
             str(body.weekly_resets_at, 64), boolInt(body.extra_enabled),
             numOrNull(body.extra_used_usd), boolInt(body.spend_limit_reached),
             boolInt(body.in_overage), numOrNull(body.extra_limit_usd),
             numOrNull(body.extra_pct), euStatus,
             // BH-3985: what the vendor answered on a failed poll, already
             // scrubbed of credentials by the poller. A replay that sends none
             // keeps the stored one.
             str(body.error_body, 2000)).run();
      const row = await env.DB.prepare(
        "SELECT * FROM extra_usage_snapshots WHERE box=?1 AND ts=?2").bind(box, ts).first();
      return json(200, { snapshot: row });
    },
  ],

  [
    "GET", "/api/metrics/extra-usage",
    async ({ env, url, t }) => {
      const box = url.searchParams.get("box");
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1000);
      // `until` (BH-3985) is the cost-rows convention: inclusive, newest-first.
      // A caller that got a full page asks again with until = the oldest ts it
      // saw and dedupes on (box, ts), the PK; it is done at a short page. box
      // is the second sort key so the order is total and two pages never
      // split same-second rows differently.
      const until = str(url.searchParams.get("until"), 64);
      const where = [], binds = [];
      if (box) { binds.push(box); where.push(`box=?${binds.length}`); }
      if (until) { binds.push(until); where.push(`ts<=?${binds.length}`); }
      // sql-ident-ok: where holds literal column clauses with ?N binds; lim is a Number clamped to 1..1000
      const rows = await env.DB.prepare(
        `SELECT * FROM extra_usage_snapshots${where.length ? " WHERE " + where.join(" AND ") : ""}
         ORDER BY ts DESC, box DESC LIMIT ${lim}`
      ).bind(...binds).all();
      return json(200, { snapshots: rows.results || [], until: until || null, as_of: t });
    },
  ],

  // ── Cost reconciliation (2026-09-14, cost fix 4) ────────────────────────
  // bin/cost-reconcile.sh posts one row per (account, window): the account
  // METER's movement over the window against the sum of our own cost rows for
  // that account. Two independent measurements of the same money; the row is
  // where they are made to agree, or made to disagree loudly.
  //
  // The PK is (account, window_key, window_end), so a re-run of the SAME
  // window overwrites its own row and an hourly cadence leaves one row per
  // hour — re-running the daily job after a fix corrects the day rather than
  // appending a second opinion of it.
  [
    "POST", "/api/metrics/reconcile",
    async ({ env, t, body }) => {
      const rows = Array.isArray(body.rows) ? body.rows : (body.account ? [body] : []);
      if (!rows.length) return json(400, { error: "rows[] or a single reconciliation row required" });
      if (rows.length > 500) return json(400, { error: "at most 500 rows per request" });
      const stmts = [];
      let accepted = 0;
      for (const r of rows) {
        const account = str(r.account, 128);
        const windowKey = str(r.window_key, 64);
        const windowEnd = str(r.window_end, 40);
        const state = str(r.state, 32);
        if (!account || !windowKey || !windowEnd || !state) continue;
        accepted++;
        stmts.push(env.DB.prepare(
          `INSERT INTO cost_reconciliation (account, window_key, window_start, window_end, state,
                                            meter_start_usd, meter_end_usd, meter_delta_usd,
                                            rows_usd, jobs_usd, unattributed_usd,
                                            rows_count, jobs_count, gap_usd, gap_pct,
                                            weekly_pct_start, weekly_pct_end, span_start, span_end,
                                            alerted, note, created_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)
           ON CONFLICT(account, window_key, window_end) DO UPDATE SET
             window_start=?3, state=?5, meter_start_usd=?6, meter_end_usd=?7, meter_delta_usd=?8,
             rows_usd=?9, jobs_usd=?10, unattributed_usd=?11, rows_count=?12, jobs_count=?13,
             gap_usd=?14, gap_pct=?15, weekly_pct_start=?16, weekly_pct_end=?17,
             span_start=?18, span_end=?19, alerted=?20, note=?21`
        ).bind(account, windowKey, str(r.window_start, 40), windowEnd, state,
               numOrNull(r.meter_start_usd), numOrNull(r.meter_end_usd), numOrNull(r.meter_delta_usd),
               numOrNull(r.rows_usd), numOrNull(r.jobs_usd), numOrNull(r.unattributed_usd),
               intOrNull(r.rows_count), intOrNull(r.jobs_count),
               numOrNull(r.gap_usd), numOrNull(r.gap_pct),
               numOrNull(r.weekly_pct_start), numOrNull(r.weekly_pct_end),
               str(r.span_start, 40), str(r.span_end, 40),
               boolInt(r.alerted), str(r.note, 2000), t));
      }
      if (!stmts.length) return json(400, { error: "no row carried account, window_key, window_end and state" });
      const results = await env.DB.batch(stmts);
      const inserted = (Array.isArray(results) ? results : [])
        .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);
      return json(200, { accepted, inserted, as_of: t });
    },
  ],

  // The read side: newest first, filterable by account and state, so "which
  // account stopped adding up, and since when" is one request from anywhere
  // the bearer is.
  [
    "GET", "/api/metrics/reconcile",
    async ({ env, url, t }) => {
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), 1000);
      const where = [], binds = [];
      for (const [k, max] of [["account", 128], ["window_key", 64], ["state", 32]]) {
        const v = str(url.searchParams.get(k), max);
        if (v) { binds.push(v); where.push(`${k}=?${binds.length}`); }
      }
      const since = str(url.searchParams.get("since"), 40);
      if (since) { binds.push(since); where.push(`window_end>=?${binds.length}`); }
      // sql-ident-ok: where uses column names from a literal list, values bound; lim is a Number clamped to 1..1000
      const rows = await env.DB.prepare(
        `SELECT * FROM cost_reconciliation${where.length ? " WHERE " + where.join(" AND ") : ""}
         ORDER BY window_end DESC LIMIT ${lim}`
      ).bind(...binds).all();
      return json(200, { reconciliations: rows.results || [], as_of: t });
    },
  ],
  // BH-167 account usage: per auth_account dollars and tokens from cost_rows
  // over a trailing 5h/12h/7d window, with the vendor meter as a cross-check. Three
  // capped reads, then one span sum per meter account that can be compared
  // (at most ANCHOR_MAX_ACCOUNTS). A read that comes back at its LIMIT sets its
  // truncated flag rather than passing a partial answer off as whole.
  [
    "GET", "/api/metrics/account-usage",
    async ({ env, url, t }) => {
      const win = usageWindow({ window: url.searchParams.get("window"), now: Date.parse(t) });
      await ensureColumns(env, "cost_rows");
      const accountMap = parseAccountMap(env.COST_ANCHOR_ACCOUNT_MAP || ANCHOR_DEFAULT_ACCOUNT_MAP);
      const LIMITS = { groups: 200, projects: 1000, snapshots: 3000 };
      const aggregates = `COUNT(*) AS calls, COUNT(cost_usd) AS priced_calls,
              SUM(cost_usd) AS usd, SUM(cost_usd IS NULL) AS unpriced_calls,
              COALESCE(SUM(input_toks),0) AS input_toks, COALESCE(SUM(output_toks),0) AS output_toks,
              COALESCE(SUM(cache_read),0) AS cache_read, COALESCE(SUM(cache_write),0) AS cache_write,
              SUM(input_toks IS NULL AND output_toks IS NULL AND cache_read IS NULL
                  AND cache_write IS NULL) AS untokened_calls`;
      const [groups, projects, snapshots] = (await Promise.all([
        // sql-ident-ok: aggregates is a local literal; LIMITS is a local const object of numbers
        env.DB.prepare(
          `SELECT NULLIF(TRIM(auth_account),'') AS account, ${aggregates},
                  MIN(ts) AS first_ts, MAX(ts) AS last_ts
             FROM cost_rows WHERE ts>=?1 AND ts<?2
            GROUP BY 1 ORDER BY SUM(COALESCE(cost_usd,0)) DESC LIMIT ${LIMITS.groups}`
        ).bind(win.from, win.to).all(),
        // sql-ident-ok: aggregates is a local literal; LIMITS is a local const object of numbers
        env.DB.prepare(
          `SELECT NULLIF(TRIM(auth_account),'') AS account, project, ${aggregates}
             FROM cost_rows WHERE ts>=?1 AND ts<?2
            GROUP BY 1, project ORDER BY SUM(COALESCE(cost_usd,0)) DESC LIMIT ${LIMITS.projects}`
        ).bind(win.from, win.to).all(),
        // sql-ident-ok: LIMITS is a local const object of numbers
        env.DB.prepare(
          `SELECT box, ts, session_pct, weekly_pct, weekly_resets_at, extra_enabled,
                  extra_used_usd, spend_limit_reached
             FROM extra_usage_snapshots WHERE ts>=?1 AND ts<?2
            ORDER BY ts ASC LIMIT ${LIMITS.snapshots}`
        ).bind(win.from, win.to).all(),
      ])).map((r) => r.results || []);

      // Rows billed to the account between its first and last poll, not over
      // the whole window, so the meter delta and the row sum cover the same
      // instants. An empty SUM is "no priced rows in the span", which
      // anchorAccountState reports as unmeasured, never as a gap.
      const candidates = anchorSpanCandidates(meterAccounts({ snapshots, accountMap, ...win })).slice(0, 8);
      const spanRows = await Promise.all(candidates.map((m) => env.DB.prepare(
        `SELECT SUM(cost_usd) AS usd, SUM(cost_usd IS NULL) AS unpriced FROM cost_rows
          WHERE auth_account=?1 AND ts>=?2 AND ts<=?3`
      ).bind(m.label, m.span_from, m.span_to).first()));
      const spanSums = {};
      candidates.forEach((m, i) => {
        const r = spanRows[i] || {};
        spanSums[m.label] = { usd: r.usd ?? 0, unpriced: r.unpriced ?? 0 };
      });

      const truncated = {
        groups: groups.length === LIMITS.groups,
        projects: projects.length === LIMITS.projects,
        snapshots: snapshots.length === LIMITS.snapshots,
      };
      return json(200, shapeAccountUsage({ groups, projects, snapshots, spanSums, accountMap, truncated, ...win }));
    },
  ],
];

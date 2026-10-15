// cost routes — money: burn, vendor spend, per-PR cost, the meter anchor, cost rows.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import { laneDedupResponse } from "../lib/lane-dedup.js";
import { readFleetFlag } from "../lib/harness-flags.js";
import {
  numOrNull, intOrNull, str, ensureColumns, ensureTable, ANCHOR_DEFAULT_ACCOUNT_MAP,
  ANCHOR_DEFAULT_MAX_FACTOR, ANCHOR_OFF_FLAG, parseAccountMap, anchorWindow,
  meterAccounts, anchorSpanCandidates, computeAnchored,
} from "../lib/core.js";

// ── Price versions (BH-5652) ────────────────────────────────────────────
// Every statement below is a constant string with bound parameters only. Each
// write is TWO statements in one env.DB.batch (one D1 transaction): the audit
// row first, then the versioned upsert. The audit insert reads the row BEFORE
// the upsert changes it, so its version is the one the upsert is about to set,
// and `INSERT OR IGNORE` on UNIQUE(kind, key, version) makes a replay a no-op.
// `IS`, not `=`, so a NULL rate posted over a NULL rate counts as the same.
//
// model_prices binds: ?1 model ?2 slug ?3 prompt ?4 completion ?5 cache_read
// ?6 cache_write ?7 cliff_tokens ?8 source ?9 t.
const MODEL_AUDIT_SELECT = `
  INSERT OR IGNORE INTO price_audit (kind, key, version, old_json, new_json, source, effective_at)
  SELECT 'model', ?1,
         COALESCE((SELECT version FROM model_prices WHERE model=?1), 0) + 1,
         (SELECT json_object('prompt', prompt, 'completion', completion, 'cache_read', cache_read,
                             'cache_write', cache_write, 'cliff_tokens', cliff_tokens)
            FROM model_prices WHERE model=?1),
         json_object('prompt', ?3, 'completion', ?4, 'cache_read', ?5, 'cache_write', ?6,
                     'cliff_tokens', ?7),
         ?8, ?9`;
// A non-catalog write is a change when the row is absent or any rate differs.
const MODEL_AUDIT_LIVE = MODEL_AUDIT_SELECT + `
  WHERE NOT EXISTS (SELECT 1 FROM model_prices WHERE model=?1 AND prompt IS ?3
                      AND completion IS ?4 AND cache_read IS ?5 AND cache_write IS ?6
                      AND cliff_tokens IS ?7)`;
// A catalog write only inserts (BH-1890), so it is a change only on a new row.
const MODEL_AUDIT_CATALOG = MODEL_AUDIT_SELECT + `
  WHERE NOT EXISTS (SELECT 1 FROM model_prices WHERE model=?1)`;
const MODEL_INSERT = `
  INSERT INTO model_prices (model, slug, prompt, completion, cache_read, cache_write,
                            cliff_tokens, source, updated_at, version, effective_at)
  VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,1,?9)
  ON CONFLICT(model) `;
// SET expressions all read the OLD row, so the CASEs compare stored vs posted.
// price_source (BH-1613) and the vendor_* rates (BH-1754) are deliberately not
// in this list: the daily refresh posts the whole table and must never clear an
// operator's mark or the price with it.
const MODEL_SAME_RATES = `model_prices.prompt IS excluded.prompt
             AND model_prices.completion IS excluded.completion
             AND model_prices.cache_read IS excluded.cache_read
             AND model_prices.cache_write IS excluded.cache_write
             AND model_prices.cliff_tokens IS excluded.cliff_tokens`;
const MODEL_UPSERT_LIVE = MODEL_INSERT + `DO UPDATE SET
         version = CASE WHEN ` + MODEL_SAME_RATES + `
                        THEN model_prices.version ELSE model_prices.version + 1 END,
         effective_at = CASE WHEN ` + MODEL_SAME_RATES + `
                             AND model_prices.effective_at IS NOT NULL
                             THEN model_prices.effective_at ELSE excluded.effective_at END,
         slug=excluded.slug, prompt=excluded.prompt, completion=excluded.completion,
         cache_read=excluded.cache_read, cache_write=excluded.cache_write,
         cliff_tokens=excluded.cliff_tokens, source=excluded.source,
         updated_at=excluded.updated_at`;
const MODEL_UPSERT_CATALOG = MODEL_INSERT + "DO NOTHING";

// price_fly binds: ?1 key ?2 value ?3 source ?4 t. The catalog is the only
// writer of these rows, so a catalog POST upserts here (unlike model_prices).
const FLY_AUDIT = `
  INSERT OR IGNORE INTO price_audit (kind, key, version, old_json, new_json, source, effective_at)
  SELECT 'fly', ?1,
         COALESCE((SELECT version FROM price_fly WHERE key=?1), 0) + 1,
         (SELECT json_object('value', value) FROM price_fly WHERE key=?1),
         json_object('value', ?2), ?3, ?4
  WHERE NOT EXISTS (SELECT 1 FROM price_fly WHERE key=?1 AND value IS ?2)`;
const FLY_UPSERT = `
  INSERT INTO price_fly (key, value, version, effective_at, source, updated_at)
  VALUES (?1, ?2, 1, ?4, ?3, ?4)
  ON CONFLICT(key) DO UPDATE SET
    version = CASE WHEN price_fly.value IS excluded.value THEN price_fly.version ELSE price_fly.version + 1 END,
    effective_at = CASE WHEN price_fly.value IS excluded.value THEN price_fly.effective_at ELSE excluded.effective_at END,
    value = excluded.value, source = excluded.source, updated_at = excluded.updated_at`;

// model_slugs binds: ?1 model ?2 slug ?3 source ?4 t.
const SLUG_AUDIT = `
  INSERT OR IGNORE INTO price_audit (kind, key, version, old_json, new_json, source, effective_at)
  SELECT 'slug', ?1,
         COALESCE((SELECT version FROM model_slugs WHERE model=?1), 0) + 1,
         (SELECT json_object('slug', slug) FROM model_slugs WHERE model=?1),
         json_object('slug', ?2), ?3, ?4
  WHERE NOT EXISTS (SELECT 1 FROM model_slugs WHERE model=?1 AND slug IS ?2)`;
const SLUG_UPSERT = `
  INSERT INTO model_slugs (model, slug, version, effective_at, source, updated_at)
  VALUES (?1, ?2, 1, ?4, ?3, ?4)
  ON CONFLICT(model) DO UPDATE SET
    version = CASE WHEN model_slugs.slug IS excluded.slug THEN model_slugs.version ELSE model_slugs.version + 1 END,
    effective_at = CASE WHEN model_slugs.slug IS excluded.slug THEN model_slugs.effective_at ELSE excluded.effective_at END,
    slug = excluded.slug, source = excluded.source, updated_at = excluded.updated_at`;

// GET /api/fly-prices answers these beside the price keys, so a price key may
// never take one of their names.
const FLY_RESERVED = new Set(["updated_at", "source", "versions", "_comment"]);
const PRICE_AUDIT_KINDS = new Set(["model", "fly", "slug"]);

export const routes = [
  // ── Metrics ledger (2026-08-29) ────────────────────────────────────────
  // Four measurement series that lived only as CSVs on the hub's disk, so
  // nothing outside that one box could read them and a rebuilt hub lost the
  // history. Schema + the four-tables-not-one-blob reasoning: schema.sql.
  //
  // NAMESPACED UNDER /api/metrics ON PURPOSE. GET /api/burn already exists and
  // means something else entirely — the coordination DB's own view of CLAIMED
  // job spend, which is a subset of the fleet's bill. burn_days is the
  // orchestrator's whole API-equivalent burn. Two different numbers must never
  // share a route, because the first reader to conflate them will conclude the
  // ledger is wrong rather than that they asked the wrong question.
  //
  // Every write is an upsert on the row's natural key: these producers all
  // re-cover ground they have already covered (the burn day is re-pushed
  // hourly, cost-rollup rewrites every PR row daily), so a re-run has to be a
  // no-op and never a duplicate.
  [
    "POST", "/api/metrics/burn",
    async ({ env, t, body }) => {
      // The DAY comes from the row, never from the server clock. This is the
      // same fix the CSV side needed: a producer whose local date disagreed
      // with the reader's UTC date appended a second row for a day that already
      // had one, five times a night, for as long as the tracker had existed.
      const day = str(body.day, 10);
      if (!day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return json(400, { error: "day (YYYY-MM-DD) required" });
      await env.DB.prepare(
        `INSERT INTO burn_days (day, api_calls, fresh_in, output, cache_read, cache_write,
                                usd_equiv, peak_cache_read, avg_cache_read, actor, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT(day) DO UPDATE SET
           api_calls=?2, fresh_in=?3, output=?4, cache_read=?5, cache_write=?6,
           usd_equiv=?7, peak_cache_read=?8, avg_cache_read=?9,
           actor=COALESCE(?10, actor), updated_at=?11`
      ).bind(day, intOrNull(body.api_calls), intOrNull(body.fresh_in), intOrNull(body.output),
             intOrNull(body.cache_read), intOrNull(body.cache_write), numOrNull(body.usd_equiv),
             intOrNull(body.peak_cache_read), intOrNull(body.avg_cache_read),
             str(body.actor, 128), t).run();
      const row = await env.DB.prepare("SELECT * FROM burn_days WHERE day=?1").bind(day).first();
      return json(200, { burn_day: row });
    },
  ],

  [
    "GET", "/api/metrics/burn",
    async ({ env, url, t }) => {
      const days = Math.min(Math.max(Number(url.searchParams.get("days")) || 30, 1), 400);
      // sql-ident-ok: days is a Number clamped to 1..400
      const rows = await env.DB.prepare(
        `SELECT * FROM burn_days ORDER BY day DESC LIMIT ${days}`
      ).all();
      return json(200, { burn_days: rows.results || [], as_of: t });
    },
  ],

  // ── Non-Anthropic vendor spend (2026-09-14, cost fix 5) ────────────────
  // bin/vendor-spend-pull.sh, hourly. See the vendor_spend comment in
  // schema.sql for why this is not more columns on cost_rows and for what
  // kind/status mean.
  //
  // THE VENDOR AND THE ts COME FROM THE ROW, never from the server clock: the
  // producer knows which instant it polled and a server stamp would merge two
  // polls of two vendors onto one key. Same rule as burn_days' day.
  [
    "POST", "/api/metrics/vendor-spend",
    async ({ env, t, body }) => {
      const vendor = str(body.vendor, 64);
      const ts = str(body.ts, 32);
      if (!vendor || !ts) return json(400, { error: "vendor and ts required" });
      // kind and status are a CLOSED set, validated here rather than trusted.
      // These two columns are the whole honesty of the row — a reader decides
      // from them whether a number is the bill or our arithmetic — so a typo
      // that lands as a fourth spelling of "computed" would silently drop the
      // row out of every filter that asks for the real ones.
      const kind = str(body.kind, 16);
      const status = str(body.status, 32);
      if (kind !== null && !["metered", "computed"].includes(kind)) {
        return json(400, { error: "kind must be metered or computed" });
      }
      if (status !== null && !["ok", "no-spend-endpoint", "auth-failed", "error"].includes(status)) {
        return json(400, { error: "status must be ok, no-spend-endpoint, auth-failed or error" });
      }
      // numOrNull, so an empty cell stays NULL. "not measured" and "cost
      // nothing" must not collapse into the same 0 — see schema.sql.
      await env.DB.prepare(
        `INSERT INTO vendor_spend (vendor, ts, window_start, window_end, usd, kind, status,
                                   balance_usd, cumulative_usd, note, raw, actor, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
         ON CONFLICT(vendor, ts) DO UPDATE SET
           window_start=?3, window_end=?4, usd=?5, kind=?6, status=?7,
           balance_usd=?8, cumulative_usd=?9, note=?10, raw=?11,
           actor=COALESCE(?12, actor), updated_at=?13`
      ).bind(vendor, ts, str(body.window_start, 32), str(body.window_end, 32),
             numOrNull(body.usd), kind, status, numOrNull(body.balance_usd),
             numOrNull(body.cumulative_usd), str(body.note, 500),
             // 8KB is the producer's own cap; enforced again here because a
             // 200KB payload from a vendor that changed its mind would land in
             // a row every reader of this table has to page past.
             str(body.raw, 8192), str(body.actor, 128), t).run();
      const row = await env.DB.prepare(
        "SELECT * FROM vendor_spend WHERE vendor=?1 AND ts=?2").bind(vendor, ts).first();
      return json(200, { vendor_spend: row });
    },
  ],

  [
    "GET", "/api/metrics/vendor-spend",
    async ({ env, url, t }) => {
      const vendor = url.searchParams.get("vendor");
      const since = url.searchParams.get("since");
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1000);
      const where = [];
      const binds = [];
      if (vendor) { binds.push(vendor); where.push(`vendor=?${binds.length}`); }
      if (since) { binds.push(since); where.push(`ts>=?${binds.length}`); }
      const sql = `SELECT * FROM vendor_spend${where.length ? " WHERE " + where.join(" AND ") : ""}
                   ORDER BY ts DESC LIMIT ${lim}`;
      const rows = binds.length
        ? await env.DB.prepare(sql).bind(...binds).all()
        : await env.DB.prepare(sql).all();
      return json(200, { vendor_spend: rows.results || [], as_of: t });
    },
  ],

  // BATCH, because the producer is a full sweep. bin/cost-rollup.sh rebuilds
  // state/cost/cost-per-pr.csv from scratch every run — 219 rows today — and
  // 219 round trips from a cron script is how a side channel becomes the work.
  [
    "POST", "/api/metrics/pr-costs",
    async ({ env, t, body }) => {
      const rows = Array.isArray(body.rows) ? body.rows : (body.pr_url ? [body] : []);
      if (!rows.length) return json(400, { error: "rows[] or a single pr_url row required" });
      if (rows.length > 2000) return json(400, { error: "at most 2000 rows per request" });
      await ensureColumns(env, "pr_costs");
      const stmts = [];
      for (const r of rows) {
        const pr = str(r.pr_url, 512);
        if (!pr) continue;
        // auth_account / account_breakdown (2026-09-02): a row that omits them
        // — a rollup from before the columns existed — binds NULL, and the
        // COALESCE keeps whatever a newer push already wrote rather than
        // blanking it. Old clients keep working; they just cannot un-attribute.
        stmts.push(env.DB.prepare(
          `INSERT INTO pr_costs (pr_url, cost_usd, input_toks, output_toks, cache_read,
                                 cache_write, stage_breakdown, build_dirs, updated_at,
                                 auth_account, account_breakdown)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
           ON CONFLICT(pr_url) DO UPDATE SET
             cost_usd=?2, input_toks=?3, output_toks=?4, cache_read=?5, cache_write=?6,
             stage_breakdown=?7, build_dirs=?8, updated_at=?9,
             auth_account=COALESCE(?10, auth_account),
             account_breakdown=COALESCE(?11, account_breakdown)`
        ).bind(pr, numOrNull(r.cost_usd), intOrNull(r.input_toks), intOrNull(r.output_toks),
               intOrNull(r.cache_read), intOrNull(r.cache_write),
               str(r.stage_breakdown, 2000), str(r.build_dirs, 2000), t,
               str(r.auth_account, 128), str(r.account_breakdown, 2000)));
      }
      if (!stmts.length) return json(400, { error: "no row carried a pr_url" });
      await env.DB.batch(stmts);
      return json(200, { upserted: stmts.length, as_of: t });
    },
  ],

  [
    "GET", "/api/metrics/pr-costs",
    async ({ env, url, t }) => {
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1000);
      // sql-ident-ok: lim is a Number clamped to 1..1000
      const rows = await env.DB.prepare(
        `SELECT * FROM pr_costs ORDER BY cost_usd DESC LIMIT ${lim}`
      ).all();
      return json(200, { pr_costs: rows.results || [], as_of: t });
    },
  ],

  // -- GET /api/metrics/cost-anchored (2026-09-14) -------------------------
  // The same dollars the two reads above hold, divided by the account meter
  // that does not undercount them. The whole derivation, and why an
  // unmeasurable window answers factor=1 instead of a number, is the
  // METER-ANCHORED COST block above computeAnchored; COST.md carries the
  // operator-facing version.
  //
  // COMPUTED HERE, NOT IN THE BROWSER, for the same reason DORA is: the
  // console would otherwise hold a second implementation of the arithmetic,
  // and the two would eventually disagree about what a PR cost.
  //
  // KILL SWITCH FIRST, and it is a ROW, not a redeploy: `pause_flags`
  // cost-anchor-off (settable from the console's own flags PUT, reconciled
  // onto every box as flags/cost-anchor-off) or COST_ANCHOR_OFF=1 in the
  // worker's vars. Off answers 200 with disabled:true and EMPTY lists rather
  // than raw-only ones, so a client that ignores the flag renders nothing
  // instead of quietly renaming raw dollars "anchored".
  [
    "GET", "/api/metrics/cost-anchored",
    async ({ env, url, t }) => {
      const win = anchorWindow({
        window: url.searchParams.get("window"),
        day: url.searchParams.get("day"),
        now: Date.parse(t),
      });
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 500, 1), 1000);
      const offRow = await readFleetFlag(env, ANCHOR_OFF_FLAG);
      const offReason = String(env.COST_ANCHOR_OFF || "") === "1"
        ? "COST_ANCHOR_OFF=1 on the worker"
        : (offRow && Number(offRow.active) === 1 ? `the ${ANCHOR_OFF_FLAG} flag is set` : null);
      if (offReason) {
        return json(200, {
          disabled: true, reason: `meter anchoring is off - ${offReason}`,
          window: win.window, from: win.from, to: win.to, limit: lim,
          accounts: [], per_pr: [], per_ticket: [], per_box: [],
          totals: null, gaps: [`Meter anchoring is off (${offReason}), so this endpoint is reporting nothing at all rather than raw dollars under an anchored name.`],
          as_of: t,
        });
      }

      const maxFactor = Math.min(Math.max(numOrNull(env.COST_ANCHOR_MAX_FACTOR)
        ?? ANCHOR_DEFAULT_MAX_FACTOR, 1), 1000);
      const accountMap = parseAccountMap(env.COST_ANCHOR_ACCOUNT_MAP || ANCHOR_DEFAULT_ACCOUNT_MAP);
      // pr_costs has no usable time column, so the whole table is read newest
      // rollup first and windowed in JS on the build-dir stamp. The cap is the
      // bound, and computeAnchored reports it as a gap when the read comes back
      // full rather than letting a silent truncation read as "no PRs".
      const PR_COSTS_CAP = 3000;

      const [rowSums, snaps, prRows, mergeRows] = await Promise.all([
        env.DB.prepare(
          `SELECT box, auth_account AS account, SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls
             FROM cost_rows WHERE ts>=?1 AND ts<?2
            GROUP BY box, auth_account LIMIT 500`
        ).bind(win.from, win.to).all(),
        env.DB.prepare(
          `SELECT box, ts, extra_used_usd, weekly_pct, weekly_resets_at, extra_enabled,
                  spend_limit_reached
             FROM extra_usage_snapshots WHERE ts>=?1 AND ts<?2
            ORDER BY ts ASC LIMIT 2000`
        ).bind(win.from, win.to).all(),
        // sql-ident-ok: PR_COSTS_CAP is a local number const
        env.DB.prepare(
          `SELECT pr_url, cost_usd, stage_breakdown, build_dirs, auth_account, updated_at
             FROM pr_costs ORDER BY updated_at DESC LIMIT ${PR_COSTS_CAP}`
        ).all(),
        env.DB.prepare(
          `SELECT key, created_at FROM ledgers
            WHERE kind='merge' AND status='merged' AND created_at>=?1
            ORDER BY created_at DESC LIMIT 2000`
        ).bind(win.from).all(),
      ]);

      const meters = meterAccounts({
        snapshots: snaps.results || [], accountMap, from: win.from, to: win.to,
      });
      // The SECOND read, and the one that keeps numerator and denominator on
      // the same instants: rows billed to this account between its first and
      // last poll, not over the whole window. Only the accounts that could
      // produce a factor are asked for (anchorSpanCandidates), and that set is
      // capped, so this is a handful of aggregates and never a fan-out.
      const candidates = anchorSpanCandidates(meters);
      const spanRows = await Promise.all(candidates.map((m) => env.DB.prepare(
        `SELECT SUM(COALESCE(cost_usd,0)) AS usd FROM cost_rows
          WHERE auth_account=?1 AND ts>=?2 AND ts<=?3`
      ).bind(m.label, m.span_from, m.span_to).first()));
      const spanSums = {};
      candidates.forEach((m, i) => { spanSums[m.label] = (spanRows[i] && spanRows[i].usd) || 0; });

      const payload = computeAnchored({
        ...win, meters, spanSums,
        rowSums: rowSums.results || [],
        prCosts: prRows.results || [],
        merges: mergeRows.results || [],
        maxFactor, limit: lim, prCostsCap: PR_COSTS_CAP,
      });
      return json(200, { ...payload, disabled: false, max_factor: maxFactor, as_of: t });
    },
  ],

  // ── Raw cost rows (2026-09-02) ──────────────────────────────────────────
  // The per-call rows behind every other cost number, mirrored from each
  // box's logs/cost.csv by bin/cost-rows-push.sh (see the cost_rows comment
  // in schema.sql). INSERT ... ON CONFLICT keyed on (box, row_hash): the
  // client resends a chunk after any failure and after a cursor reset, and
  // neither may become a second row. On conflict the stored row is kept and
  // ONLY a NULL lane_id / guard_fp / participant (BH-5352) is filled from the
  // incoming row (BH-3220: the immediate emitter's row, cut at `note`, landed
  // first and DO NOTHING threw away the mirror's full copy). A set value is never overwritten, an
  // incoming NULL never blanks one, and no other column moves. One D1 batch per
  // request — 2000 rows is one transaction and one round trip; D1's
  // 100-parameter cap per statement rules out a single multi-row VALUES.
  [
    "POST", "/api/metrics/cost-rows",
    async ({ env, t, body }) => {
      const box = str(body.box, 128);
      if (!box) return json(400, { error: "box required" });
      const rows = Array.isArray(body.rows) ? body.rows : [];
      if (!rows.length) return json(400, { error: "rows[] required" });
      if (rows.length > 2000) return json(400, { error: "at most 2000 rows per request" });
      // Before the first write that needs them, exactly like pr_costs.auth_account.
      await ensureColumns(env, "cost_rows");
      const stmts = [];
      for (const r of rows) {
        const hash = str(r.row_hash, 64);
        const lineNo = intOrNull(r.line_no);
        if (!hash || lineNo === null) continue;
        stmts.push(env.DB.prepare(
          `INSERT INTO cost_rows (box, row_hash, line_no, ts, host, project, stage, runner, model,
                                  rc, duration_s, input_toks, output_toks, cache_read, cache_write,
                                  cost_usd, billing_mode, auth_fp, auth_account,
                                  session_id, row_source, result_usd, ticket, job_id, pr, run_id,
                                  note, raw, inserted_at, lane_id, guard_fp, participant)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,
                   ?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32)
           ON CONFLICT(box, row_hash) DO UPDATE SET
             lane_id  = COALESCE(cost_rows.lane_id,  excluded.lane_id),
             guard_fp = COALESCE(cost_rows.guard_fp, excluded.guard_fp),
             participant = COALESCE(cost_rows.participant, excluded.participant)
           WHERE (cost_rows.lane_id IS NULL AND excluded.lane_id IS NOT NULL)
              OR (cost_rows.guard_fp IS NULL AND excluded.guard_fp IS NOT NULL)
              OR (cost_rows.participant IS NULL AND excluded.participant IS NOT NULL)`
        ).bind(box, hash, lineNo, str(r.ts, 64), str(r.host, 128), str(r.project, 128),
               str(r.stage, 64), str(r.runner, 64), str(r.model, 256),
               intOrNull(r.rc), numOrNull(r.duration_s), intOrNull(r.input_toks),
               intOrNull(r.output_toks), intOrNull(r.cache_read), intOrNull(r.cache_write),
               numOrNull(r.cost_usd), str(r.billing_mode, 32), str(r.auth_fp, 64),
               str(r.auth_account, 128),
               // A client that predates these columns simply omits them; str()/
               // numOrNull() turn undefined into NULL, so an old box keeps
               // pushing and lands the same row it always did.
               str(r.session_id, 64), str(r.row_source, 32), numOrNull(r.result_usd),
               str(r.ticket, 128), str(r.job_id, 128), str(r.pr, 256), str(r.run_id, 128),
               // `raw` is generous on purpose: it is one cost.csv line, and a
               // truncated one would re-emit SHORT, which is worse than not
               // having it at all (a short line still parses). 4096 is ~20x the
               // widest row this fleet has written.
               str(r.note, 256), str(r.raw, 4096),
               t,
               // BH-2303: the lane the call was spent by; NULL from a box that predates it.
               str(r.lane_id, 128),
               // BH-2537: the pre-call guard's input fingerprint; NULL from a box that predates it.
               str(r.guard_fp, 300),
               // BH-5352: the participant machine (bin/lib/cost-row.sh's at-source
               // body only; the mirror never sends it, so the fill above adds it).
               str(r.participant, 64)));
      }
      if (!stmts.length) return json(400, { error: "no row carried row_hash and line_no" });
      const results = await env.DB.batch(stmts);
      // `inserted` is what D1 reports as changed: a new row, or (BH-3220) a
      // stored row whose NULL lane_id / guard_fp this push filled. A re-push of
      // rows already there reports 0 and that is the idempotency, visible in
      // the response — the WHERE above is what keeps it 0, since SQLite counts
      // every DO UPDATE that runs as a change, and bin/cost-rows-push.sh reads
      // accepted minus inserted as the dup count.
      const inserted = (Array.isArray(results) ? results : [])
        .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);
      return json(200, { accepted: stmts.length, inserted, as_of: t });
    },
  ],

  // The read side: rows by account / project / box, newest first, so the
  // account question is answerable from anywhere the bearer is.
  [
    "GET", "/api/metrics/cost-rows",
    async ({ env, url, t }) => {
      await ensureColumns(env, "cost_rows");
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 2000);
      const where = [], binds = [];
      // ticket / pr / job_id / run_id are filterable for the same reason they are
      // written: "what did TK-109 cost" should not need a time window.
      for (const [k, max] of [["box", 128], ["project", 128], ["auth_account", 128], ["stage", 64],
                              ["ticket", 128], ["pr", 256], ["job_id", 128], ["run_id", 128],
                              ["row_source", 32], ["guard_fp", 300], ["lane_id", 128],
                              ["runner", 32]]) {
        const v = str(url.searchParams.get(k), max);
        if (v) { binds.push(v); where.push(`${k}=?${binds.length}`); }
      }
      const since = str(url.searchParams.get("since"), 64);
      if (since) { binds.push(since); where.push(`ts>=?${binds.length}`); }
      // `until` (2026-09-14) is what makes a window WIDER than one page
      // readable: rows come back newest-first, so a caller that got a full page
      // walks backwards by asking again with until = the oldest ts it saw.
      // Inclusive on purpose — the caller dedupes on (box, row_hash), and an
      // exclusive bound would drop every row sharing that second.
      const until = str(url.searchParams.get("until"), 64);
      if (until) { binds.push(until); where.push(`ts<=?${binds.length}`); }
      // sql-ident-ok: where uses column names from a literal list, values bound; lim is a clamped Number
      const rows = await env.DB.prepare(
        `SELECT * FROM cost_rows${where.length ? " WHERE " + where.join(" AND ") : ""}
         ORDER BY ts DESC LIMIT ${lim}`
      ).bind(...binds).all();
      return json(200, { cost_rows: rows.results || [], as_of: t });
    },
  ],

  // ── LLM spend, as ONE aggregate (BH-1141) ───────────────────────────────
  // What bin/lib/llm-gate.sh asks before every model call: "what has this lane
  // spent today?" The rows route above cannot answer it — it pages, and a page
  // caps at 2000 rows, so a busy lane's sum would silently come back short and
  // a cap computed from a truncated sum is a cap that never fires. That is
  // indistinguishable in every log from having no cap at all, which is the
  // failure shape this whole ticket is written out of.
  //
  // `since` DEFAULTS TO THIS UTC DAY, not to all of history: a daily ceiling
  // compared against every dollar the fleet ever spent would refuse every lane
  // the moment an operator set one.
  //
  // COALESCE, because SUM() over no rows is NULL in SQLite, and the gate reads
  // a non-numeric answer as "not known" and then fails OPEN — so a null here
  // would quietly disable the cap on exactly the quiet lanes it is cheapest to
  // guard.
  //
  // `refused` counts gate refusals (row_source=refused); `settled` counts the
  // triage no-signal settles (row_source=settled, BH-2604). Both are $0 rows
  // and both are in `calls`; neither moves `usd`.
  [
    "GET", "/api/metrics/llm-spend",
    async ({ env, url, t }) => {
      await ensureColumns(env, "cost_rows");
      // PER LANE (BH-2303). ?lane=L&stage=S sums the stage's rows stamped
      // lane_id=L, PLUS its rows written before lane_id existed (lane_id IS
      // NULL) — so a day that straddles the deploy still counts its earlier
      // spend. A row stamped with ANOTHER lane is never counted: three lanes on
      // stage=review stop sharing one cap. The gate asks once per stage the
      // lane registered (BH-2304) and sums, so each stamped row is counted once.
      // With no stage there is no signature: only stamped rows, any stage.
      // `project` narrows both. Two constant statements, one per case, so each
      // leads with the column its index starts with (BH-2489: the single
      // statement's `?4 IS NULL OR …` let SQLite use neither index, and every
      // gate read was a full scan of cost_rows).
      const laneRaw = url.searchParams.get("lane");
      if (laneRaw !== null) {
        if (!/^[A-Za-z0-9._-]{1,128}$/.test(laneRaw)) return json(400, { error: "lane must be a lane id" });
        const lStage = str(url.searchParams.get("stage"), 64) || null;
        const lProject = str(url.searchParams.get("project"), 128) || null;
        const lSince = str(url.searchParams.get("since"), 64) || (t.slice(0, 10) + "T00:00:00Z");
        const lUntil = str(url.searchParams.get("until"), 64) || null;
        // sql-ident-ok: the lStage null check picks one of two literal strings
        const lr = await env.DB.prepare(
          "SELECT SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls," +
          " SUM(CASE WHEN row_source='refused' THEN 1 ELSE 0 END) AS refused," +
          " SUM(CASE WHEN row_source='settled' THEN 1 ELSE 0 END) AS settled" +
          (lStage !== null
            ? " FROM cost_rows WHERE stage=?4 AND ts>=?1 AND (?2 IS NULL OR ts<=?2)" +
              " AND (?5 IS NULL OR project=?5) AND (lane_id=?3 OR lane_id IS NULL)"
            : " FROM cost_rows WHERE lane_id=?3 AND ts>=?1 AND (?2 IS NULL OR ts<=?2)" +
              " AND (?5 IS NULL OR project=?5)")
        ).bind(lSince, lUntil, laneRaw, lStage, lProject).first();
        return json(200, {
          usd: Number((lr && lr.usd) || 0),
          calls: Number((lr && lr.calls) || 0),
          refused: Number((lr && lr.refused) || 0),
          settled: Number((lr && lr.settled) || 0),
          lane: laneRaw, since: lSince, until: lUntil, as_of: t,
        });
      }
      const where = [], binds = [];
      for (const [k, max] of [["stage", 64], ["project", 128], ["runner", 32],
                              ["box", 128], ["row_source", 32], ["auth_account", 128]]) {
        const v = str(url.searchParams.get(k), max);
        if (v) { binds.push(v); where.push(`${k}=?${binds.length}`); }
      }
      const since = str(url.searchParams.get("since"), 64) || (t.slice(0, 10) + "T00:00:00Z");
      binds.push(since); where.push(`ts>=?${binds.length}`);
      const until = str(url.searchParams.get("until"), 64);
      if (until) { binds.push(until); where.push(`ts<=?${binds.length}`); }
      // sql-ident-ok: where uses column names from a literal list, values bound
      const row = await env.DB.prepare(
        `SELECT SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls,
                SUM(CASE WHEN row_source='refused' THEN 1 ELSE 0 END) AS refused,
                SUM(CASE WHEN row_source='settled' THEN 1 ELSE 0 END) AS settled
           FROM cost_rows WHERE ${where.join(" AND ")}`
      ).bind(...binds).first();
      return json(200, {
        usd: Number((row && row.usd) || 0),
        calls: Number((row && row.calls) || 0),
        refused: Number((row && row.refused) || 0),
        settled: Number((row && row.settled) || 0),
        since, until: until || null, as_of: t,
      });
    },
  ],

  // ── Lane dedup (BH-2537) ────────────────────────────────────────────────
  // Shape-only stub: validates `days` and answers `lanes: []` until the
  // aggregation sibling (#2669) fills it. See src/lib/lane-dedup.js.
  ["GET", "/api/metrics/lane-dedup", async ({ env, url }) => laneDedupResponse(env, url)],

  // ── Model prices (2026-09-20, BH-1032) ──────────────────────
  // The per-token table every cost figure is multiplied by. It lived on the
  // hub as state/model-prices.json, so a Fly pool machine priced its rows
  // from the committed catalog fallback instead — two prices for one call,
  // decided by which machine ran it. Here it is one table; the file on each
  // box becomes its derived cache (bin/model-prices-sync.sh).
  //
  // POST is a WHOLE-TABLE upsert (source=catalog only inserts, BH-1890), never
  // a delete-and-insert: a refresh that fetched fewer models than last time
  // must not un-price the ones it missed.
  // A model whose rates genuinely went away keeps its last known rate, which
  // is the same fail-soft bin/update-model-prices.sh already has on the file.
  [
    "POST", "/api/model-prices",
    async ({ env, t, body }) => {
      // BH-658: the deploy is `wrangler deploy` and nothing else, so the table
      // creates itself here or it does not exist on the live database at all.
      await ensureTable(env, "model_prices");
      // BH-5652: a live table predates version/effective_at, and the upsert
      // names both; the audit table is new.
      await ensureColumns(env, "model_prices");
      await ensureTable(env, "price_audit");
      const rows = Array.isArray(body.rows) ? body.rows : [];
      if (!rows.length) return json(400, { error: "rows[] required" });
      if (rows.length > 500) return json(400, { error: "at most 500 rows per request" });
      const source = str(body.source, 32) || "openrouter";
      // BH-1890: a catalog POST only INSERTS. bin/model-prices-deploy-sync.sh
      // POSTs the models the table lacked at its GET, and the 04:30Z refresh
      // can insert a live rate between that GET and this POST; a catalog row
      // must never replace it. Every other source keeps the full upsert. Each
      // statement is one of two constants, chosen by equality, never user text.
      const catalog = source === "catalog";
      const auditSql = catalog ? MODEL_AUDIT_CATALOG : MODEL_AUDIT_LIVE;
      const upsertSql = catalog ? MODEL_UPSERT_CATALOG : MODEL_UPSERT_LIVE;
      const stmts = [];
      let accepted = 0;
      for (const r of rows) {
        const model = str(r.model, 256);
        if (!model) continue;
        const binds = [model, str(r.slug, 256), numOrNull(r.prompt), numOrNull(r.completion),
                       numOrNull(r.cache_read), numOrNull(r.cache_write),
                       intOrNull(r.cliff_tokens), source, t];
        // BH-5652: audit first, so it reads the row before the upsert moves it.
        stmts.push(env.DB.prepare(auditSql).bind(...binds));
        stmts.push(env.DB.prepare(upsertSql).bind(...binds));
        accepted++;
      }
      if (!accepted) return json(400, { error: "no row carried a model" });
      await env.DB.batch(stmts);
      return json(200, { accepted, as_of: t });
    },
  ],

  // GET answers in catalog/model-prices.json's OWN SHAPE — {updated_at,
  // source, per_token:{model:{prompt,completion,cache_read,cache_write,slug,
  // cliff_tokens}}} — so bin/model-prices-sync.sh writes the body straight to
  // disk and every existing reader (cost_price_tokens, cost_model_cliff,
  // transcript-cost, cost-rollup's row_cost) is unchanged. A shape the
  // consumers have to translate is a second place for the table to be wrong.
  [
    "GET", "/api/model-prices",
    async ({ env, t }) => {
      await ensureTable(env, "model_prices");
      await ensureColumns(env, "model_prices");
      const rows = await env.DB.prepare(
        `SELECT model, slug, prompt, completion, cache_read, cache_write, cliff_tokens,
                source, updated_at, price_source, vendor_prompt, vendor_completion,
                vendor_cache_read, vendor_cache_write, vendor_cliff_tokens,
                version, effective_at
           FROM model_prices ORDER BY model`
      ).all();
      const list = rows.results || [];
      const per_token = {};
      let newest = "", source = "";
      for (const r of list) {
        const e = { prompt: r.prompt, completion: r.completion,
                    cache_read: r.cache_read, cache_write: r.cache_write };
        if (r.slug) e.slug = r.slug;
        // Omitted, never null: cost_model_cliff reads `.cliff_tokens | numbers`
        // and a model with no cliff must have no key, not a null one.
        if (r.cliff_tokens !== null && r.cliff_tokens !== undefined) e.cliff_tokens = r.cliff_tokens;
        // BH-1613: same rule — only a marked row carries the key.
        if (r.price_source) e.price_source = r.price_source;
        // BH-1754: the D1 vendor price, on a marked row with both rates only.
        // bin/update-model-prices.sh prices the model from it (catalog second).
        if (r.price_source && r.vendor_prompt !== null && r.vendor_prompt !== undefined
            && r.vendor_completion !== null && r.vendor_completion !== undefined) {
          e.vendor_direct = { prompt: r.vendor_prompt, completion: r.vendor_completion,
                              cache_read: r.vendor_cache_read ?? null,
                              cache_write: r.vendor_cache_write ?? null };
          if (r.vendor_cliff_tokens !== null && r.vendor_cliff_tokens !== undefined) {
            e.vendor_direct.cliff_tokens = r.vendor_cliff_tokens;
          }
        }
        // BH-5652: the price version, as a number. Every D1 row has one (NOT
        // NULL DEFAULT 1, so a row written before the column reads 1); the key is
        // omitted rather than invented when a row carries none. effective_at
        // follows the cliff_tokens rule above: omitted, never null, until the
        // row's first versioned write fills it.
        if (Number.isInteger(r.version) && r.version > 0) e.version = r.version;
        if (r.effective_at) e.effective_at = r.effective_at;
        per_token[r.model] = e;
        if ((r.updated_at || "") > newest) { newest = r.updated_at || ""; source = r.source || ""; }
      }
      return json(200, { updated_at: newest || t, source: source || "harness-jobs/model_prices",
                         models: list.length, per_token });
    },
  ],

  // BH-1613: the per-model price source, and the ONLY writer of that column.
  // 'vendor-direct' makes bin/update-model-prices.sh price the model at the
  // vendor's own rate instead of OpenRouter's resale rate; 'openrouter' stores
  // NULL, today's behaviour. Stored lowercase, so the refresh's exact match is
  // the only spelling there is.
  // BH-1754: also the only writer of the vendor_* rates. An optional `vendor`
  // {prompt, completion, cache_read?, cache_write?, cliff_tokens?} goes with
  // vendor-direct only, and prompt/completion must be numbers > 0. vendor-direct
  // with no `vendor` leaves stored rates alone (re-marking never erases a
  // price); openrouter clears them with the mark, so a stale price cannot come
  // back when the model is marked again.
  [
    "PUT", "/api/model-prices/source",
    async ({ env, t, body }) => {
      await ensureTable(env, "model_prices");
      await ensureColumns(env, "model_prices");
      const model = str(body.model, 256);
      if (!model) return json(400, { error: "model required" });
      const ps = String(body.price_source || "").trim().toLowerCase();
      if (ps !== "vendor-direct" && ps !== "openrouter") {
        return json(400, { error: "price_source must be vendor-direct or openrouter" });
      }
      const v = body.vendor;
      const rate = (x) => typeof x === "number" && Number.isFinite(x) && x > 0;
      let stmt;
      if (v !== undefined && v !== null) {
        if (ps !== "vendor-direct") return json(400, { error: "vendor rates go with price_source vendor-direct only" });
        if (typeof v !== "object" || !rate(v.prompt) || !rate(v.completion)) {
          return json(400, { error: "vendor needs prompt and completion as numbers > 0" });
        }
        const absent = (x) => x === undefined || x === null;
        if (!(absent(v.cache_read) || rate(v.cache_read)) || !(absent(v.cache_write) || rate(v.cache_write))
            || !(absent(v.cliff_tokens) || (Number.isInteger(v.cliff_tokens) && v.cliff_tokens > 0))) {
          return json(400, { error: "vendor cache rates must be numbers > 0 and cliff_tokens an integer > 0, or absent" });
        }
        stmt = env.DB.prepare(
          `UPDATE model_prices SET price_source = ?2, vendor_prompt = ?3, vendor_completion = ?4,
             vendor_cache_read = ?5, vendor_cache_write = ?6, vendor_cliff_tokens = ?7 WHERE model = ?1`
        ).bind(model, ps, v.prompt, v.completion, v.cache_read ?? null, v.cache_write ?? null,
               v.cliff_tokens ?? null);
      } else if (ps === "vendor-direct") {
        stmt = env.DB.prepare("UPDATE model_prices SET price_source = ?2 WHERE model = ?1").bind(model, ps);
      } else {
        stmt = env.DB.prepare(
          `UPDATE model_prices SET price_source = NULL, vendor_prompt = NULL, vendor_completion = NULL,
             vendor_cache_read = NULL, vendor_cache_write = NULL, vendor_cliff_tokens = NULL WHERE model = ?1`
        ).bind(model);
      }
      const r = await stmt.run();
      if (!r || !r.meta || !r.meta.changes) return json(404, { error: `not in model_prices: ${model}` });
      return json(200, { model, price_source: ps, as_of: t });
    },
  ],

  // ── Fly prices, model slugs, price audit (BH-5652) ─────────────────────
  // Seeded mirrors of catalog/fly-prices.json and catalog/model-slugs.json
  // (bin/price-seed.sh), versioned like model_prices. The files stay what the
  // readers read in this wave; these rows carry the version and the history.
  //
  // POST body {source, prices:<the fly-prices.json object>}. Each number at the
  // top level or one level down becomes a row keyed by its dotted path; strings,
  // arrays and _comment are skipped. No number at all is a 400, never an empty
  // success.
  [
    "POST", "/api/fly-prices",
    async ({ env, t, body }) => {
      await ensureTable(env, "price_fly");
      await ensureTable(env, "price_audit");
      const p = body.prices;
      if (!p || typeof p !== "object" || Array.isArray(p)) return json(400, { error: "prices{} required" });
      const source = str(body.source, 32) || "manual";
      const num = (v) => typeof v === "number" && Number.isFinite(v);
      // A dot inside a key would make the dotted path ambiguous on the way back.
      const okKey = (k) => k.length > 0 && k.length <= 128 && !k.includes(".") && !FLY_RESERVED.has(k);
      const flat = [];
      for (const [k, v] of Object.entries(p)) {
        if (!okKey(k)) continue;
        if (num(v)) flat.push([k, v]);
        else if (v && typeof v === "object" && !Array.isArray(v)) {
          for (const [k2, v2] of Object.entries(v)) if (okKey(k2) && num(v2)) flat.push([`${k}.${k2}`, v2]);
        }
      }
      if (!flat.length) return json(400, { error: "prices carried no number" });
      if (flat.length > 500) return json(400, { error: "at most 500 prices per request" });
      const stmts = [];
      for (const [key, value] of flat) {
        stmts.push(env.DB.prepare(FLY_AUDIT).bind(key, value, source, t));
        stmts.push(env.DB.prepare(FLY_UPSERT).bind(key, value, source, t));
      }
      await env.DB.batch(stmts);
      return json(200, { accepted: flat.length, as_of: t });
    },
  ],

  // GET answers the file's own nesting ({seconds_per_month, cpu_usd_per_core_month:
  // {shared, performance}, ...}) plus updated_at (newest row, null when empty),
  // source (of that row) and versions:{dotted key: n}.
  [
    "GET", "/api/fly-prices",
    async ({ env }) => {
      await ensureTable(env, "price_fly");
      const rows = await env.DB.prepare(
        "SELECT key, value, version, source, updated_at FROM price_fly ORDER BY key"
      ).all();
      const out = {};
      const versions = {};
      let newest = "", source = null;
      for (const r of rows.results || []) {
        const dot = r.key.indexOf(".");
        if (dot === -1) out[r.key] = r.value;
        else {
          const top = r.key.slice(0, dot);
          if (!out[top] || typeof out[top] !== "object") out[top] = {};
          out[top][r.key.slice(dot + 1)] = r.value;
        }
        versions[r.key] = Number(r.version);
        if ((r.updated_at || "") > newest) { newest = r.updated_at || ""; source = r.source ?? null; }
      }
      return json(200, { updated_at: newest || null, source, ...out, versions });
    },
  ],

  // POST body {source, slugs:{model: slug}}. A slug must be a non-empty string
  // of at most 256 characters; any other value is skipped and counted. At most
  // 500 entries; none valid is a 400.
  [
    "POST", "/api/model-slugs",
    async ({ env, t, body }) => {
      await ensureTable(env, "model_slugs");
      await ensureTable(env, "price_audit");
      const m = body.slugs;
      if (!m || typeof m !== "object" || Array.isArray(m)) return json(400, { error: "slugs{} required" });
      const entries = Object.entries(m);
      if (entries.length > 500) return json(400, { error: "at most 500 slugs per request" });
      const source = str(body.source, 32) || "manual";
      const good = (v) => typeof v === "string" && v.length > 0 && v.length <= 256;
      const stmts = [];
      let accepted = 0;
      for (const [model, slug] of entries) {
        if (!good(model) || !good(slug)) continue;
        stmts.push(env.DB.prepare(SLUG_AUDIT).bind(model, slug, source, t));
        stmts.push(env.DB.prepare(SLUG_UPSERT).bind(model, slug, source, t));
        accepted++;
      }
      if (!accepted) return json(400, { error: "no valid slug" });
      await env.DB.batch(stmts);
      return json(200, { accepted, skipped: entries.length - accepted, as_of: t });
    },
  ],

  [
    "GET", "/api/model-slugs",
    async ({ env }) => {
      await ensureTable(env, "model_slugs");
      const rows = await env.DB.prepare(
        "SELECT model, slug, version, updated_at FROM model_slugs ORDER BY model"
      ).all();
      const slugs = {};
      const versions = {};
      let newest = "";
      for (const r of rows.results || []) {
        slugs[r.model] = r.slug;
        versions[r.model] = Number(r.version);
        if ((r.updated_at || "") > newest) newest = r.updated_at || "";
      }
      return json(200, { updated_at: newest || null, slugs, versions });
    },
  ],

  // GET ?kind=model|fly|slug &key= &limit= (default 50, at most 200): why a
  // price changed, newest row first. An unknown kind is a 400, not an empty list.
  [
    "GET", "/api/price-audit",
    async ({ env, url }) => {
      await ensureTable(env, "price_audit");
      const kind = url.searchParams.get("kind");
      if (kind !== null && !PRICE_AUDIT_KINDS.has(kind)) {
        return json(400, { error: "kind must be model, fly or slug" });
      }
      const key = str(url.searchParams.get("key"), 256);
      const limit = Math.min(Math.max(Math.trunc(Number(url.searchParams.get("limit"))) || 50, 1), 200);
      const rows = await env.DB.prepare(
        `SELECT kind, key, version, old_json, new_json, source, effective_at FROM price_audit
          WHERE (?1 IS NULL OR kind = ?1) AND (?2 IS NULL OR key = ?2)
          ORDER BY id DESC LIMIT ?3`
      ).bind(kind, key, limit).all();
      const parse = (s) => (s === null || s === undefined ? null : JSON.parse(s));
      return json(200, {
        rows: (rows.results || []).map((r) => ({
          kind: r.kind, key: r.key, version: Number(r.version),
          old: parse(r.old_json), new: parse(r.new_json),
          source: r.source ?? null, effective_at: r.effective_at,
        })),
        limit,
      });
    },
  ],
];

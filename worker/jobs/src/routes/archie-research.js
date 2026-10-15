// archie-research routes — BH-4065 (BH-3966.4): Archie's research scout ledger.
//
// bin/archie-research.sh claims a dedupe key BEFORE every billable call (an X
// search, the day's web scan, a scoring batch) and before it scores a find,
// and settles it after: ok, empty or failed. ok and empty are terminal, so a
// post or url that already has a row is never bought again, and an empty
// search is never repeated the same day. Table: archie_research (schema.sql,
// BH-4065 block). The keys are normalised in bin/lib/archie-research.sh and
// only validated here.
//
// Every supplied field is validated and a junk one is a 400 naming the field,
// never clamped (D11). A settle replayed onto its own terminal status is 200;
// a different terminal status is 409 (D16).

import { json, d1Guarded } from "../lib/http.js";

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const isDay = (v) => {
  if (typeof v !== "string" || !DAY_RE.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
};
// The key's prefix decides its kind; a claim that names another kind is junk.
const KEY_KINDS = [
  [/^xq:[a-z0-9-]{1,48}:\d{4}-\d{2}-\d{2}$/, "xquery"],
  [/^wq:\d{4}-\d{2}-\d{2}$/, "webscan"],
  [/^x:\d{1,25}$/, "item"],
  [/^web:[0-9a-f]{40}$/, "item"],
  [/^sb:[0-9a-f]{16}$/, "batch"],
  [/^digest:\d{4}-W\d{2}$/, "digest"],
];
const kindOf = (key) => {
  if (typeof key !== "string") return null;
  const hit = KEY_KINDS.find(([re]) => re.test(key));
  return hit ? hit[1] : null;
};
const SETTLE_STATUSES = new Set(["ok", "empty", "failed"]);
const TERMINAL = new Set(["ok", "empty"]);
// A refund hands back an attempt that billed nothing; any other failure counts.
const REFUND_NOTES = new Set(["not-configured", "no-route", "refused"]);
const SLUG_RE = /^[A-Za-z0-9._-]{1,128}$/;
const URL_RE = /^https:\/\/\S{1,2000}$/;
const LIST_MAX = 500;
// The list leaves the payload snapshot out: 500 rows of 8000 chars is not a list.
const LIST_COLS = `id, dedupe_key, kind, source, status, attempts, day, url, title, applies, score, why,
  proposal_title, proposal_summary, proposal_slug, input_toks, output_toks, tool_calls, cost_usd, priced,
  note, created_at, updated_at`;

const bad = (field) => json(400, { error: field });
const intIn = (v, lo, hi) => typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;
// absent/null is null; otherwise a string of 1..max chars, or undefined (junk).
const optText = (v, max) => {
  if (v === undefined || v === null) return null;
  return typeof v === "string" && v.length >= 1 && v.length <= max ? v : undefined;
};
const optNum = (v, lo, hi) => {
  if (v === undefined || v === null) return null;
  return typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : undefined;
};
const optInt = (v) => {
  if (v === undefined || v === null) return null;
  return intIn(v, 0, 100000000) ? v : undefined;
};
const readRow = (env, key) =>
  env.DB.prepare(`SELECT * FROM archie_research WHERE dedupe_key=?1`).bind(key).first();

export const routes = [
  // ── POST /api/archie-research/claim ─────────────────────────────────────
  // ONE conditional upsert: an absent key is inserted claimed with attempts 1
  // (201); a claimed (crashed) or failed row under max_attempts takes
  // attempts+1 and goes back to claimed (200); anything else writes nothing and
  // is a 409 that says why: terminal (ok/empty) or the attempt cap.
  [
    "POST", "/api/archie-research/claim",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const kind = kindOf(b.key);
      if (kind === null) return bad("key");
      if (b.kind !== kind) return bad("kind");
      let source = null;
      if (b.source !== undefined && b.source !== null) {
        if (b.source !== "x" && b.source !== "web") return bad("source");
        source = b.source;
      }
      if (!isDay(b.day)) return bad("day");
      if (!intIn(b.max_attempts, 1, 10)) return bad("max_attempts");
      const url = optText(b.url, 2000);
      if (url === undefined || (url !== null && !URL_RE.test(url))) return bad("url");
      const title = optText(b.title, 300);
      if (title === undefined) return bad("title");

      return d1Guarded("archie_research", async () => {
        const r = await env.DB.prepare(
          `INSERT INTO archie_research (dedupe_key, kind, source, status, attempts, day, url, title, created_at, updated_at)
           VALUES (?1, ?2, ?3, 'claimed', 1, ?4, ?5, ?6, ?7, ?7)
           ON CONFLICT(dedupe_key) DO UPDATE SET attempts = archie_research.attempts + 1, status = 'claimed',
                  day = excluded.day, updated_at = excluded.updated_at
            WHERE archie_research.status IN ('claimed','failed') AND archie_research.attempts < ?8`
        ).bind(b.key, kind, source, b.day, url, title, t, b.max_attempts).run();
        const row = await readRow(env, b.key);
        if (!row) return json(503, { error: "archie_research unavailable", detail: `claim of ${b.key} left no row` });
        if (Number((r.meta && r.meta.changes) || 0) === 1) {
          const created = row.attempts === 1 && row.created_at === t && row.updated_at === t;
          return json(created ? 201 : 200, { ok: true, created, row });
        }
        if (TERMINAL.has(row.status)) return json(409, { error: "terminal", status: row.status, row });
        return json(409, { error: "attempt cap", row });
      });
    },
  ],

  // ── POST /api/archie-research/settle ────────────────────────────────────
  // From claimed: the outcome, its usage and its cost (cost_usd present = this
  // attempt is priced, and it is ADDED, since an earlier attempt may have paid
  // too). From ok: an ok fill-in (score, slug) that never touches the money.
  // The same status onto a settled row is a replay, 200, and writes nothing
  // else. Any other transition is 409. refund:true (claimed -> failed only,
  // note in REFUND_NOTES) hands the attempt back: that call billed nothing.
  [
    "POST", "/api/archie-research/settle",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (kindOf(b.key) === null) return bad("key");
      if (typeof b.status !== "string" || !SETTLE_STATUSES.has(b.status)) return bad("status");
      const f = {
        input_toks: optInt(b.input_toks), output_toks: optInt(b.output_toks), tool_calls: optInt(b.tool_calls),
        cost_usd: optNum(b.cost_usd, 0, 1000), score: optNum(b.score, 0, 10),
        why: optText(b.why, 1000), proposal_title: optText(b.proposal_title, 300),
        proposal_summary: optText(b.proposal_summary, 2000), proposal_slug: optText(b.proposal_slug, 128),
        raw: optText(b.raw, 8000), note: optText(b.note, 200),
      };
      for (const [k, v] of Object.entries(f)) if (v === undefined) return bad(k);
      if (f.proposal_slug !== null && !SLUG_RE.test(f.proposal_slug)) return bad("proposal_slug");
      let applies = null;
      if (b.applies !== undefined && b.applies !== null) {
        if (typeof b.applies !== "boolean") return bad("applies");
        applies = b.applies ? 1 : 0;
      }
      const refund = b.refund === true;
      if (b.refund !== undefined && typeof b.refund !== "boolean") return bad("refund");
      if (refund && (b.status !== "failed" || !REFUND_NOTES.has(f.note))) return bad("refund");

      return d1Guarded("archie_research", async () => {
        const before = await readRow(env, b.key);
        if (!before) return json(404, { error: "research item not found" });
        if (before.status === "claimed") {
          const priced = f.cost_usd === null ? 0 : 1;
          // ?1 key ?2 status ?3 in ?4 out ?5 tools ?6 cost ?7 priced+ ?8 applies
          // ?9 score ?10 why ?11 ptitle ?12 psummary ?13 slug ?14 raw ?15 note
          // ?16 refund ?17 t
          const r = await env.DB.prepare(
            `UPDATE archie_research SET status = ?2,
                    input_toks = COALESCE(?3, input_toks), output_toks = COALESCE(?4, output_toks),
                    tool_calls = COALESCE(?5, tool_calls),
                    cost_usd = CASE WHEN ?6 IS NULL THEN cost_usd ELSE COALESCE(cost_usd, 0) + ?6 END,
                    priced = priced + ?7,
                    applies = COALESCE(?8, applies), score = COALESCE(?9, score), why = COALESCE(?10, why),
                    proposal_title = COALESCE(?11, proposal_title), proposal_summary = COALESCE(?12, proposal_summary),
                    proposal_slug = COALESCE(?13, proposal_slug), raw = COALESCE(?14, raw), note = ?15,
                    attempts = CASE WHEN ?16 = 1 AND attempts > 0 THEN attempts - 1 ELSE attempts END,
                    updated_at = ?17
              WHERE dedupe_key = ?1 AND status = 'claimed'`
          ).bind(b.key, b.status, f.input_toks, f.output_toks, f.tool_calls, f.cost_usd, priced, applies,
            f.score, f.why, f.proposal_title, f.proposal_summary, f.proposal_slug, f.raw, f.note,
            refund ? 1 : 0, t).run();
          if (Number((r.meta && r.meta.changes) || 0) === 1) {
            return json(200, { ok: true, row: await readRow(env, b.key) });
          }
        }
        const cur = await readRow(env, b.key);
        if (cur.status !== b.status || refund) {
          return json(409, { error: `${b.key} is ${cur.status}, not claimed`, row: cur });
        }
        if (cur.status === "ok") {
          await env.DB.prepare(
            `UPDATE archie_research SET applies = COALESCE(?2, applies), score = COALESCE(?3, score),
                    why = COALESCE(?4, why), proposal_title = COALESCE(?5, proposal_title),
                    proposal_summary = COALESCE(?6, proposal_summary),
                    proposal_slug = COALESCE(?7, proposal_slug), updated_at = ?8
              WHERE dedupe_key = ?1 AND status = 'ok'`
          ).bind(b.key, applies, f.score, f.why, f.proposal_title, f.proposal_summary, f.proposal_slug, t).run();
        }
        return json(200, { ok: true, replay: true, row: await readRow(env, b.key) });
      });
    },
  ],

  // ── GET /api/archie-research/spend?day=&reserve_usd= ────────────────────
  // What the lane has spent on <day>: the priced dollars, plus reserve_usd for
  // every billable attempt with no price (in flight, crashed, or a call that
  // answered no usage). An unpriced attempt is never $0 (D11). Item rows are
  // not billable on their own: their scoring batch is.
  [
    "GET", "/api/archie-research/spend",
    async ({ env, url }) => {
      const q = url.searchParams;
      const day = q.get("day");
      if (!isDay(day)) return bad("day");
      const rs = q.get("reserve_usd");
      if (rs === null || !/^\d{1,4}(\.\d{1,6})?$/.test(rs)) return bad("reserve_usd");
      const reserve = Number(rs);
      return d1Guarded("archie_research", async () => {
        const r = await env.DB.prepare(
          `SELECT COALESCE(SUM(cost_usd), 0) AS priced_usd,
                  COALESCE(SUM(CASE WHEN attempts > priced THEN attempts - priced ELSE 0 END), 0) AS unpriced,
                  COUNT(*) AS n
             FROM archie_research WHERE day = ?1 AND kind IN ('xquery','webscan','batch')`
        ).bind(day).first();
        const priced = Number(r.priced_usd);
        const unpriced = Number(r.unpriced);
        const usd = Math.round((priced + unpriced * reserve) * 1e6) / 1e6;
        return json(200, { day, usd, priced_usd: Math.round(priced * 1e6) / 1e6, unpriced_attempts: unpriced, rows: Number(r.n) });
      });
    },
  ],

  // ── GET /api/archie-research?key= | ?from=&to=[&kind=][&status=] ────────
  // ?key= answers {row} or 404 with EXACTLY {"error":"research item not
  // found"}: any other 404 is a worker without this route. The list is the
  // rows whose day is in [from, to], ordered by day and id, at most 500, with
  // truncated:true when there were more (D12).
  [
    "GET", "/api/archie-research",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      if (q.has("key")) {
        const key = q.get("key");
        if (kindOf(key) === null) return bad("key");
        return d1Guarded("archie_research", async () => {
          const row = await readRow(env, key);
          return row ? json(200, { row }) : json(404, { error: "research item not found" });
        });
      }
      const from = q.get("from");
      const to = q.get("to");
      if (!isDay(from)) return bad("from");
      if (!isDay(to)) return bad("to");
      const where = ["day >= ?1", "day <= ?2"];
      const binds = [from, to];
      if (q.has("kind")) {
        const k = q.get("kind");
        if (!["xquery", "webscan", "item", "batch", "digest"].includes(k)) return bad("kind");
        binds.push(k); where.push(`kind = ?${binds.length}`);
      }
      if (q.has("status")) {
        const s = q.get("status");
        if (!["claimed", "ok", "empty", "failed"].includes(s)) return bad("status");
        binds.push(s); where.push(`status = ?${binds.length}`);
      }
      binds.push(LIST_MAX + 1);
      return d1Guarded("archie_research", async () => {
        // sql-ident-ok: LIST_COLS is a module const column list; where holds literal column = ?N clauses
        const rows = (await env.DB.prepare(
          `SELECT ${LIST_COLS} FROM archie_research WHERE ${where.join(" AND ")}
            ORDER BY day ASC, id ASC LIMIT ?${binds.length}`
        ).bind(...binds).all()).results || [];
        return json(200, { rows: rows.slice(0, LIST_MAX), truncated: rows.length > LIST_MAX, as_of: t });
      });
    },
  ],
];

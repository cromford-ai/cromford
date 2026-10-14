// block-findings routes — BH-5806 (BH-5794.1): classify every BLOCK.
//
// bin/lesson-classify.sh (hub, hourly) asks GET /api/block-classify/pending for
// the BLOCK verdicts in the window that have no finished run, CLAIMS each one
// (POST /api/block-classify/claim) BEFORE its one paid model call, and settles
// the claim with the answer (POST /api/block-classify/settle). The claim is the
// persisted "have we already paid for this?" check (#5794, dedup before spend):
// it is keyed on verdicts.id, ok and empty are terminal, and failed retries
// only while attempts < settings lesson_classify.max_attempts (default 3).
// refund:true on a failed settle gives the attempt back, for a call the lane's
// own gate refused (agent-call rc 74: nothing was billed).
//
// The taxonomy is block_categories (rows, not code). A finding whose category
// is not an active row is stored as `other`, and the model's label is kept in
// raw_category, so wave 2 (#5807) can see what the model wanted to say.
//
// GET /api/block-findings/weekly and GET /api/block-findings are the console's
// BLOCKS BY CATEGORY section on /lead-reviews (console-ui/src/screens/BlockCategories.js).
//
// D1 has no RLS. Every route here sits behind the HARNESS_SECRET bearer (none
// is in OPEN_ROUTES), which is the admin-only gate; the console reaches them
// through its server-side GET proxy only.

import { json, d1Guarded } from "../lib/http.js";

const MAX_ATTEMPTS_DEFAULT = 3;   // fallback when settings lesson_classify.max_attempts is absent or junk
const SINCE_DAYS_DEFAULT = 14;    // fallback when settings lesson_classify.since_days is absent or junk
const SETTLE_STATUSES = new Set(["ok", "empty", "failed"]);
const TERMINAL = new Set(["ok", "empty"]);
const MAX_FINDINGS = 50;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const TICKET_RE = /^[A-Z][A-Z0-9]{1,9}-\d{1,7}$/;

const bad = (field) => json(400, { error: field });
const intIn = (v, lo, hi) => typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;
const clip = (v, max) => (typeof v === "string" && v.length > 0 ? v.slice(0, max) : null);
const isDay = (v) => {
  if (typeof v !== "string" || !DAY_RE.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
};
const qInt = (q, name, def, lo, hi) => {
  if (!q.has(name)) return def;
  const n = Number(q.get(name));
  return Number.isInteger(n) && n >= lo && n <= hi ? n : undefined;
};
const settingInt = async (env, key, def, lo, hi) => {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first("value");
  const n = Number(v);
  return v !== null && Number.isInteger(n) && n >= lo && n <= hi ? n : def;
};
const isoMinusDays = (t, days) => new Date(Date.parse(t) - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
// The Monday on or before a day (UTC), as YYYY-MM-DD. SQL twin: date(x, '-6 days', 'weekday 1').
const mondayOf = (ms) => {
  const d = new Date(ms);
  const back = (d.getUTCDay() + 6) % 7;
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - back)).toISOString().slice(0, 10);
};
const WEEK_SQL = "date(f.verdict_at, '-6 days', 'weekday 1')";
const parseList = (s) => { try { const v = JSON.parse(s); return Array.isArray(v) ? v : []; } catch { return []; } };
const runOut = (r) => r && ({
  verdict_id: r.verdict_id, status: r.status, attempts: Number(r.attempts), model: r.model,
  error: r.error, findings: Number(r.findings), updated_at: r.updated_at,
});

// One finding of a settle body, validated; null = junk (the whole settle is 400).
const findingOf = (f) => {
  if (!f || typeof f !== "object" || !intIn(f.n, 1, MAX_FINDINGS)) return null;
  const text = clip(f.text, 4000);
  if (!text) return null;
  const cat = typeof f.category === "string" ? f.category.trim().toLowerCase().slice(0, 64) : "";
  if (f.confidence !== undefined && f.confidence !== null
      && !(typeof f.confidence === "number" && f.confidence >= 0 && f.confidence <= 1)) return null;
  if (f.files !== undefined && !Array.isArray(f.files)) return null;
  const files = (f.files || []).filter((x) => typeof x === "string" && x.length > 0).slice(0, 20).map((x) => x.slice(0, 200));
  return {
    n: f.n, text, category: cat, confidence: typeof f.confidence === "number" ? f.confidence : null,
    cause: clip(f.cause, 300), files, infra_false: f.infra_false === true ? 1 : 0,
  };
};

export const routes = [
  // ── GET /api/block-categories[?all=1] ───────────────────────────────────
  [
    "GET", "/api/block-categories",
    async ({ env, url, t }) => d1Guarded("block_categories", async () => {
      const all = url.searchParams.get("all") === "1";
      const { results } = await env.DB.prepare(
        `SELECT * FROM block_categories ${all ? "" : "WHERE status = 'active'"} ORDER BY id`
      ).all();
      const categories = (results || []).map((r) => ({
        id: r.id, name: r.name, description: r.description, group: r.grp, suggested_stage: r.suggested_stage,
        example_prs: parseList(r.example_prs), status: r.status, added_by: r.added_by, reason: r.reason,
      }));
      return json(200, { categories, as_of: t });
    }),
  ],

  // ── GET /api/block-classify/pending?limit= ──────────────────────────────
  // The BLOCK verdicts created in the last lesson_classify.since_days days with
  // no ok/empty run and fewer than lesson_classify.max_attempts attempts,
  // newest first. A read only: the claim below is what reserves one.
  [
    "GET", "/api/block-classify/pending",
    async ({ env, url, t }) => d1Guarded("block_classify_runs", async () => {
      const limit = qInt(url.searchParams, "limit", 10, 1, 50);
      if (limit === undefined) return bad("limit");
      const max = await settingInt(env, "lesson_classify.max_attempts", MAX_ATTEMPTS_DEFAULT, 1, 10);
      const days = await settingInt(env, "lesson_classify.since_days", SINCE_DAYS_DEFAULT, 1, 365);
      const since = isoMinusDays(t, days);
      const { results } = await env.DB.prepare(
        `SELECT v.id AS verdict_id, v.repo, v.pr, v.head_sha, v.source, v.reviewer, v.note, v.report_url,
                v.created_at, COALESCE(r.attempts, 0) AS attempts, r.status AS run_status
           FROM verdicts v LEFT JOIN block_classify_runs r ON r.verdict_id = v.id
          WHERE v.verdict = 'BLOCK' AND v.created_at >= ?1
            AND (r.verdict_id IS NULL OR (r.status IN ('claimed','failed') AND r.attempts < ?2))
          ORDER BY v.id DESC LIMIT ?3`
      ).bind(since, max, limit + 1).all();
      const rows = results || [];
      return json(200, {
        verdicts: rows.slice(0, limit).map((r) => ({ ...r, attempts: Number(r.attempts) })),
        truncated: rows.length > limit, max_attempts: max, since, as_of: t,
      });
    }),
  ],

  // ── POST /api/block-classify/claim {verdict_id} ─────────────────────────
  // ONE conditional upsert: an absent run is inserted claimed with attempts 1
  // (201); a claimed (crashed) or failed run under the cap takes attempts+1 and
  // goes back to claimed (200). A terminal run is 409 terminal, a run at the
  // cap is 409 at_cap, and neither writes anything.
  [
    "POST", "/api/block-classify/claim",
    async ({ env, body, t }) => {
      const b = body || {};
      if (!intIn(b.verdict_id, 1, Number.MAX_SAFE_INTEGER)) return bad("verdict_id");
      return d1Guarded("block_classify_runs", async () => {
        const v = await env.DB.prepare("SELECT id, repo, pr, head_sha, verdict FROM verdicts WHERE id=?1").bind(b.verdict_id).first();
        if (!v) return json(404, { error: "verdict not found" });
        if (v.verdict !== "BLOCK") return json(409, { error: "not_block", verdict: v.verdict });
        const max = await settingInt(env, "lesson_classify.max_attempts", MAX_ATTEMPTS_DEFAULT, 1, 10);
        const res = await env.DB.prepare(
          `INSERT INTO block_classify_runs (verdict_id, repo, pr, head_sha, status, attempts, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, 'claimed', 1, ?5, ?5)
           ON CONFLICT(verdict_id) DO UPDATE SET attempts = block_classify_runs.attempts + 1,
             status = 'claimed', error = NULL, updated_at = ?5
            WHERE block_classify_runs.status IN ('claimed','failed') AND block_classify_runs.attempts < ?6`
        ).bind(v.id, v.repo, v.pr, v.head_sha, t, max).run();
        const row = await env.DB.prepare("SELECT * FROM block_classify_runs WHERE verdict_id=?1").bind(v.id).first();
        if (!row) return json(503, { error: "block_classify_runs unavailable", detail: `claim of ${v.id} left no row` });
        if (Number(res.meta && res.meta.changes) === 1 && row.status === "claimed") {
          const created = Number(row.attempts) === 1 && row.created_at === t;
          return json(created ? 201 : 200, { claimed: true, attempts: Number(row.attempts), max_attempts: max, run: runOut(row) });
        }
        if (TERMINAL.has(row.status)) return json(409, { error: "terminal", status: row.status, run: runOut(row) });
        return json(409, { error: "at_cap", max_attempts: max, run: runOut(row) });
      });
    },
  ],

  // ── POST /api/block-classify/settle ─────────────────────────────────────
  // {verdict_id, status: ok|empty|failed, model?, error?, refund?, ticket?,
  //  findings?: [{n, text, category, confidence, cause, files[], infra_false}]}
  // From claimed only. ok needs 1..50 findings and writes them (INSERT OR
  // IGNORE on (verdict_id, n)) with the run in one batch; empty and failed
  // carry none. The same status onto a settled run is a replay: 200, nothing
  // written. Any other transition is 409.
  [
    "POST", "/api/block-classify/settle",
    async ({ env, body, t }) => {
      const b = body || {};
      if (!intIn(b.verdict_id, 1, Number.MAX_SAFE_INTEGER)) return bad("verdict_id");
      if (typeof b.status !== "string" || !SETTLE_STATUSES.has(b.status)) return bad("status");
      const refund = b.refund === true;
      if (refund && b.status !== "failed") return bad("refund");
      const findings = b.findings === undefined ? [] : b.findings;
      if (!Array.isArray(findings) || findings.length > MAX_FINDINGS) return bad("findings");
      if (b.status === "ok" && findings.length === 0) return bad("findings");
      if (b.status !== "ok" && findings.length > 0) return bad("findings");
      const fs = findings.map(findingOf);
      if (fs.some((f) => f === null)) return bad("findings");
      if (new Set(fs.map((f) => f.n)).size !== fs.length) return bad("findings");
      const ticket = typeof b.ticket === "string" && TICKET_RE.test(b.ticket) ? b.ticket : null;
      const model = clip(b.model, 128);
      const error = clip(b.error, 500);
      return d1Guarded("block_classify_runs", async () => {
        const run = await env.DB.prepare("SELECT * FROM block_classify_runs WHERE verdict_id=?1").bind(b.verdict_id).first();
        if (!run) return json(404, { error: "no claim for this verdict" });
        if (run.status !== "claimed") {
          if (run.status === b.status && !refund) return json(200, { replay: true, run: runOut(run) });
          return json(409, { error: `${b.verdict_id} is ${run.status}, not claimed`, run: runOut(run) });
        }
        const stmts = [];
        if (b.status === "ok") {
          const v = await env.DB.prepare("SELECT source, created_at FROM verdicts WHERE id=?1").bind(b.verdict_id).first();
          const { results } = await env.DB.prepare("SELECT id FROM block_categories WHERE status = 'active'").all();
          const known = new Set((results || []).map((r) => r.id));
          for (const f of fs) {
            const cat = SLUG_RE.test(f.category) && known.has(f.category) ? f.category : "other";
            stmts.push(env.DB.prepare(
              `INSERT OR IGNORE INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category,
                 raw_category, confidence, cause, files, infra_false, text, model, verdict_at, created_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)`
            ).bind(b.verdict_id, f.n, run.repo, run.pr, ticket, run.head_sha, v ? v.source : null, cat,
              cat === f.category ? null : (f.category || null), f.confidence, f.cause, JSON.stringify(f.files),
              f.infra_false, f.text, model, v ? v.created_at : t, t));
          }
        }
        stmts.push(env.DB.prepare(
          `UPDATE block_classify_runs SET status = ?2, model = COALESCE(?3, model), error = ?4, findings = ?5,
             attempts = CASE WHEN ?6 = 1 AND attempts > 0 THEN attempts - 1 ELSE attempts END, updated_at = ?7
            WHERE verdict_id = ?1 AND status = 'claimed'`
        ).bind(b.verdict_id, b.status, model, error, fs.length, refund ? 1 : 0, t));
        await env.DB.batch(stmts);
        const after = await env.DB.prepare("SELECT * FROM block_classify_runs WHERE verdict_id=?1").bind(b.verdict_id).first();
        return json(200, { run: runOut(after) });
      });
    },
  ],

  // ── GET /api/block-findings/weekly?weeks= ───────────────────────────────
  // Per ISO week (its Monday, UTC, from the BLOCK's own time) and category:
  // findings, distinct verdicts and distinct PRs. weeks 1..52, default 8.
  [
    "GET", "/api/block-findings/weekly",
    async ({ env, url, t }) => d1Guarded("block_findings", async () => {
      const weeks = qInt(url.searchParams, "weeks", 8, 1, 52);
      if (weeks === undefined) return bad("weeks");
      const from = mondayOf(Date.parse(t) - (weeks - 1) * 7 * 86400000);
      const { results } = await env.DB.prepare(
        `SELECT ${WEEK_SQL} AS week, f.category, c.name, count(*) AS findings,
                count(DISTINCT f.verdict_id) AS verdicts, count(DISTINCT f.repo || '#' || f.pr) AS prs
           FROM block_findings f LEFT JOIN block_categories c ON c.id = f.category
          WHERE f.verdict_at >= ?1
          GROUP BY week, f.category ORDER BY week DESC, findings DESC`
      ).bind(`${from}T00:00:00Z`).all();
      const rows = (results || []).map((r) => ({
        week: r.week, category: r.category, name: r.name || r.category,
        findings: Number(r.findings), verdicts: Number(r.verdicts), prs: Number(r.prs),
      }));
      return json(200, { weeks, from, rows, as_of: t });
    }),
  ],

  // ── GET /api/block-findings?category=&week=&limit= ──────────────────────
  // The rows behind one weekly cell (or any filter of them), newest first, each
  // with the verdict's report_url so a row links to the PR and the verdict.
  [
    "GET", "/api/block-findings",
    async ({ env, url, t }) => d1Guarded("block_findings", async () => {
      const q = url.searchParams;
      const limit = qInt(q, "limit", 200, 1, 500);
      if (limit === undefined) return bad("limit");
      const where = [];
      const binds = [];
      if (q.has("category")) {
        const c = q.get("category");
        if (!SLUG_RE.test(c)) return bad("category");
        binds.push(c); where.push(`f.category = ?${binds.length}`);
      }
      if (q.has("week")) {
        const w = q.get("week");
        if (!isDay(w)) return bad("week");
        binds.push(w); where.push(`${WEEK_SQL} = ?${binds.length}`);
      }
      if (q.has("verdict_id")) {
        const v = Number(q.get("verdict_id"));
        if (!Number.isInteger(v) || v < 1) return bad("verdict_id");
        binds.push(v); where.push(`f.verdict_id = ?${binds.length}`);
      }
      binds.push(limit);
      const { results } = await env.DB.prepare(
        `SELECT f.*, v.report_url FROM block_findings f LEFT JOIN verdicts v ON v.id = f.verdict_id
          ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
          ORDER BY f.verdict_at DESC, f.verdict_id DESC, f.n ASC LIMIT ?${binds.length}`
      ).bind(...binds).all();
      const rows = (results || []).map((r) => ({
        id: r.id, verdict_id: r.verdict_id, n: r.n, repo: r.repo, pr: r.pr, ticket: r.ticket, head_sha: r.head_sha,
        source: r.source, category: r.category, raw_category: r.raw_category, confidence: r.confidence,
        cause: r.cause, files: parseList(r.files), infra_false: r.infra_false === 1, text: r.text,
        model: r.model, verdict_at: r.verdict_at, report_url: r.report_url || null,
      }));
      return json(200, { rows, as_of: t });
    }),
  ],
];

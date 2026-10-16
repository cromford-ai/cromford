// lessons routes — BH-5808 (BH-5794.3): measure and retire lessons.
//
// bin/lesson-propose.sh (#5807) opens a lesson PR or issue per repeat BLOCK
// cause. bin/lesson-measure.sh (hub, daily) records each one that merged here
// (POST /api/lessons), judges every `measuring` row once a week (POST
// /api/lessons/measure), files a stronger stage for a not-working row and a
// removal PR for a superseded plan-text lesson (GET /api/lessons/pending, POST
// /api/lessons/mark), runs the retention audit (POST /api/lessons/retention)
// and sends the weekly digest (GET /api/lessons/digest), which the console
// /lead-reviews LESSONS section reads too.
//
// RETIRE. A plan lesson is `superseded` only when its removal PR MERGES. The
// open PR is recorded as removal_number on the row (its status stays) and
// GET /api/lessons/pending lists it in `removing` until the lane reads the PR
// merged (mark status superseded) or closed unmerged (mark clear_removal, so
// the row is in `retire` again and a new PR is opened).
//
// THE JUDGEMENT. W = lessons.window_days. before = [merged_at - W, merged_at),
// after = [merged_at, merged_at + d) for the first whole day d >= W at which
// the after-window holds lessons.min_reviewed reviewed PRs; it grows day by
// day to lessons.max_window_days, past which the row is `inconclusive`. A
// reviewed PR is a DISTINCT (repo, pr) with a verdicts row in the window (any
// source); a BLOCK is a DISTINCT block_findings.verdict_id of the category.
// rate = blocks x 100 / reviewed. Working iff before_blocks > 0 and
// after_rate <= before_rate x (100 - min_cut_pct) / 100, in integers (exactly
// the cut is working). No baseline (0 BLOCKs or 0 reviewed before) is
// `inconclusive`, never `working`.
//
// Every hot read is an exported SQL constant (or builder) so the EXPLAIN QUERY
// PLAN test checks the exact text the routes run (BH-6730). The independent
// reads of one route run together (Promise.all); the writes go in one batch.
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES), which is the admin-only gate.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

// Fallbacks, used only when the settings row lessons.<key> is absent or junk.
const INTS = {
  window_days: [14, 1, 90],
  min_reviewed: [30, 1, 1000],
  min_cut_pct: [30, 1, 100],
  max_window_days: [42, 1, 365],
  digest_days: [7, 1, 90],
  retention_days: [730, 30, 3650],
  list_limit: [100, 1, 500],
};
export const STAGES = ["plan-lesson", "builder-rule", "check", "harness-bug"];
const STATUSES = ["measuring", "working", "not-working", "inconclusive", "superseded", "removed"];
const MEASURE_ROWS = 200;
const WINDOW_ROWS_MAX = 50000;
const IN_CHUNK = 90; // D1 binds at most 100 values a statement.
const DAY_MS = 86400000;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
// Copy of block-findings.js SLUG_RE (module-local there): a block_categories id.
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

export const RECORD_LOOKUP_SQL =
  `SELECT (SELECT escalation_stage FROM lessons WHERE escalation_number = ?1 AND repo = ?2 AND escalation_stage IS NOT NULL LIMIT 1) AS esc,
          (SELECT id FROM lessons WHERE repo = ?2 AND kind = ?3 AND number = ?1) AS id`;
export const MEASURING_SQL =
  "SELECT * FROM lessons WHERE status = 'measuring' ORDER BY merged_at ASC, id ASC LIMIT ?1";
// The window's BLOCK verdicts of n categories: ?1 the span start, ?2..?n+1 the
// categories, ?n+2 the row cap. idx_block_findings_cat.
export const windowBlocksSql = (n) =>
  // sql-ident-ok: the IN list is ?N placeholders built from a count, every category a bind
  `SELECT DISTINCT verdict_id, category, verdict_at FROM block_findings
    WHERE category IN (${Array.from({ length: n }, (_, k) => `?${k + 2}`).join(",")}) AND verdict_at >= ?1
    LIMIT ?${n + 2}`;
// One row per verdict in the span: (repo, pr, created_at). idx_verdicts_created.
// A GROUP BY here lets the planner walk idx_verdicts_pr_head over the whole
// table instead, so the grouping is done in JS.
export const WINDOW_REVIEWED_SQL =
  "SELECT repo, pr, created_at FROM verdicts WHERE created_at >= ?1 LIMIT ?2";
export const PENDING_ESCALATE_SQL =
  "SELECT * FROM lessons WHERE status = 'not-working' AND escalation_number IS NULL ORDER BY merged_at ASC, id ASC LIMIT 200";
export const PENDING_TYPE_SQL =
  `SELECT id, category, change_type, kind, number, url, title, merged_at, status, superseded_by, removal_number, removal_url FROM lessons
    WHERE change_type IN ('plan-lesson', 'check', 'harness-bug') ORDER BY change_type, category, merged_at LIMIT 2000`;
// An escalation issue with no lessons row of its own yet: the sweep reads it live.
export const PENDING_ESCALATED_SQL =
  `SELECT l.id, l.category, l.repo, l.escalation_stage, l.escalation_number, l.escalation_url FROM lessons l
    LEFT JOIN lessons x ON x.repo = l.repo AND x.kind = 'issue' AND x.number = l.escalation_number
    WHERE l.escalation_number IS NOT NULL AND x.id IS NULL ORDER BY l.escalation_number LIMIT 200`;
export const DIGEST_CATEGORY_SQL =
  "SELECT category, COUNT(DISTINCT verdict_id) AS n FROM block_findings WHERE verdict_at >= ?1 GROUP BY category";
export const DIGEST_OVERALL_SQL =
  `SELECT COUNT(DISTINCT repo || '#' || pr) AS reviewed,
          COUNT(DISTINCT CASE WHEN verdict = 'BLOCK' THEN repo || '#' || pr || '@' || head_sha END) AS blocks
     FROM verdicts WHERE created_at >= ?1`;
// block_categories is the taxonomy (about 35 rows): read whole, no index needed.
export const DIGEST_NAMES_SQL = "SELECT id, name FROM block_categories";
export const DIGEST_STATUS_SQL =
  `SELECT category, status, COUNT(*) AS n, MAX(merged_at) AS last_at,
          SUM(CASE WHEN merged_at >= ?1 THEN 1 ELSE 0 END) AS added,
          SUM(CASE WHEN removal_number IS NOT NULL THEN 1 ELSE 0 END) AS removing
     FROM lessons GROUP BY category, status`;
export const DIGEST_LIST_SQL = "SELECT * FROM lessons ORDER BY merged_at DESC, id DESC LIMIT ?1";
const RETAIN_WHERE =
  `merged_at < ?1 AND (status IN ('working', 'inconclusive', 'superseded', 'removed')
     OR (status = 'not-working' AND escalation_number IS NOT NULL))`;
export const RETENTION_COUNT_SQL = `SELECT COUNT(*) AS n FROM lessons WHERE ${RETAIN_WHERE}`;

const bad = (field) => json(400, { error: field });
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const isIso = (v) => typeof v === "string" && ISO_RE.test(v) && !Number.isNaN(Date.parse(v));
const optStr = (v, max) => v === undefined || v === null || (typeof v === "string" && v.length <= max);
const posInt = (v) => Number.isInteger(v) && v > 0;
// rate per 100 reviewed PRs, one decimal; null with no reviewed PR.
const rate = (blocks, reviewed) => (reviewed > 0 ? Math.round((blocks * 1000) / reviewed) / 10 : null);

// conf(env): the lessons.* settings, from ONE memoized settings read.
async function conf(env) {
  const { byKey } = await settingsRows(env);
  const c = {};
  for (const [k, [def, lo, hi]] of Object.entries(INTS)) {
    const row = byKey.get(`lessons.${k}`);
    const v = row ? String(row.value) : null;
    const n = Number(v);
    c[k] = v !== null && /^\d+$/.test(v) && n >= lo && n <= hi ? n : def;
  }
  if (c.max_window_days < c.window_days) c.max_window_days = c.window_days;
  const so = byKey.get("lessons.stage_order");
  const order = so ? String(so.value).split(",").map((s) => s.trim()).filter(Boolean) : [];
  c.stage_order = order.length >= 2 && new Set(order).size === order.length && order.every((s) => STAGES.includes(s))
    ? order : [...STAGES];
  return c;
}
export const nextStage = (order, type) => {
  const i = order.indexOf(type);
  return i >= 0 && i < order.length - 1 ? order[i + 1] : null;
};

// judge(lesson, blocks, reviewed, c, nowMs): the new fields of one measuring row.
// blocks: [{at}] of its category; reviewed: [{key, at}] (ms), one per verdict.
export function judge(l, blocks, reviewed, c, nowMs) {
  const m = Date.parse(l.merged_at);
  const W = c.window_days * DAY_MS;
  const countBlocks = (a, b) => blocks.filter((x) => x.at >= a && x.at < b).length;
  const countReviewed = (a, b) => {
    const s = new Set();
    for (const r of reviewed) if (r.at >= a && r.at < b) s.add(r.key);
    return s.size;
  };
  const before_blocks = countBlocks(m - W, m);
  const before_reviewed = countReviewed(m - W, m);
  let status = "measuring";
  let end = null;
  const elapsed = Math.floor((nowMs - m) / DAY_MS);
  if (elapsed >= c.window_days) {
    for (let d = c.window_days; d <= Math.min(elapsed, c.max_window_days); d++) {
      if (countReviewed(m, m + d * DAY_MS) >= c.min_reviewed) { end = m + d * DAY_MS; break; }
    }
    if (end !== null) status = "judged";
    else if (elapsed >= c.max_window_days) { end = m + c.max_window_days * DAY_MS; status = "inconclusive"; }
  }
  if (end === null) end = m + Math.max(0, Math.min(elapsed, c.max_window_days)) * DAY_MS;
  const after_blocks = countBlocks(m, end);
  const after_reviewed = countReviewed(m, end);
  const br = rate(before_blocks, before_reviewed);
  const ar = rate(after_blocks, after_reviewed);
  const cut_pct = br && ar !== null ? Math.round((1 - ar / br) * 1000) / 10 : null;
  if (status === "judged") {
    if (before_blocks === 0 || before_reviewed === 0) status = "inconclusive";
    else status = after_blocks * before_reviewed * 100 <= before_blocks * after_reviewed * (100 - c.min_cut_pct)
      ? "working" : "not-working";
  }
  return {
    status, before_blocks, before_reviewed, after_blocks, after_reviewed, after_end: iso(end), cut_pct,
    before_rate: br, after_rate: ar,
  };
}

export const routes = [
  // ── POST /api/lessons ───────────────────────────────────────────────────
  // {category, change_type, kind, repo, number, url?, title?, merged_at, source}.
  // An issue this table filed as an escalation (its escalation_number) takes
  // that row's escalation_stage and source `escalation`: wave 2's marker-hit
  // path keeps its old draft target. 201 {created:true, id}; the same (repo,
  // kind, number) again is 200 {created:false, id}, nothing written.
  [
    "POST", "/api/lessons",
    async ({ env, body, t }) => {
      const b = body || {};
      if (typeof b.category !== "string" || !SLUG_RE.test(b.category)) return bad("category");
      if (!STAGES.includes(b.change_type)) return bad("change_type");
      if (b.kind !== "pr" && b.kind !== "issue") return bad("kind");
      if (typeof b.repo !== "string" || !REPO_RE.test(b.repo)) return bad("repo");
      if (!posInt(b.number)) return bad("number");
      if (!optStr(b.url, 500) || (typeof b.url === "string" && !b.url.startsWith("https://"))) return bad("url");
      if (!optStr(b.title, 300)) return bad("title");
      if (!isIso(b.merged_at)) return bad("merged_at");
      if (b.source !== "proposal" && b.source !== "escalation") return bad("source");
      return d1Guarded("lessons", async () => {
        const hit = await env.DB.prepare(RECORD_LOOKUP_SQL).bind(b.number, b.repo, b.kind).first();
        if (hit && hit.id !== null) return json(200, { created: false, id: hit.id });
        const esc = b.kind === "issue" && hit && STAGES.includes(hit.esc) ? hit.esc : null;
        const row = await env.DB.prepare(
          `INSERT OR IGNORE INTO lessons (category, change_type, kind, repo, number, url, title, source, merged_at,
             status, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'measuring', ?10, ?10) RETURNING id`
        ).bind(b.category, esc || b.change_type, b.kind, b.repo, b.number, b.url || null, b.title || null,
          esc ? "escalation" : b.source, b.merged_at, t).first();
        if (row) return json(201, { created: true, id: row.id, change_type: esc || b.change_type });
        const again = await env.DB.prepare(RECORD_LOOKUP_SQL).bind(b.number, b.repo, b.kind).first();
        return json(200, { created: false, id: again ? again.id : null });
      });
    },
  ],

  // ── POST /api/lessons/measure ───────────────────────────────────────────
  // Judges every `measuring` row (oldest MEASURE_ROWS; `more` says rows were
  // left for the next run). A window read over WINDOW_ROWS_MAX rows answers
  // {truncated:true} and writes NOTHING: a lesson is never judged on a cut read.
  [
    "POST", "/api/lessons/measure",
    async ({ env, t }) => d1Guarded("lessons", async () => {
      const c = await conf(env);
      const nowMs = Date.parse(t);
      const { results } = await env.DB.prepare(MEASURING_SQL).bind(MEASURE_ROWS + 1).all();
      const rows = (results || []).slice(0, MEASURE_ROWS);
      const more = (results || []).length > MEASURE_ROWS;
      if (!rows.length) return json(200, { judged: [], still_measuring: 0, more: false, truncated: false, as_of: t });
      const since = iso(Math.min(...rows.map((r) => Date.parse(r.merged_at))) - c.window_days * DAY_MS);
      const cats = [...new Set(rows.map((r) => r.category))];
      const chunks = [];
      for (let i = 0; i < cats.length; i += IN_CHUNK) chunks.push(cats.slice(i, i + IN_CHUNK));
      const reads = await Promise.all([
        env.DB.prepare(WINDOW_REVIEWED_SQL).bind(since, WINDOW_ROWS_MAX + 1).all(),
        ...chunks.map((ch) => env.DB.prepare(windowBlocksSql(ch.length)).bind(since, ...ch, WINDOW_ROWS_MAX + 1).all()),
      ]);
      const sets = reads.map((r) => r.results || []);
      if (sets.some((s) => s.length > WINDOW_ROWS_MAX)) {
        return json(200, { judged: [], still_measuring: rows.length, more, truncated: true, as_of: t });
      }
      const reviewed = sets[0].map((r) => ({ key: `${r.repo}#${r.pr}`, at: Date.parse(r.created_at) }));
      const byCat = new Map();
      for (const s of sets.slice(1)) for (const f of s) {
        if (!byCat.has(f.category)) byCat.set(f.category, new Map());
        const m = byCat.get(f.category);
        const at = Date.parse(f.verdict_at);
        if (!m.has(f.verdict_id) || at < m.get(f.verdict_id)) m.set(f.verdict_id, at);
      }
      const judged = [];
      const stmts = [];
      let still = 0;
      for (const l of rows) {
        const blocks = [...(byCat.get(l.category) || new Map()).values()].map((at) => ({ at }));
        const j = judge(l, blocks, reviewed, c, nowMs);
        if (j.status === "measuring") still += 1;
        else judged.push({ id: l.id, category: l.category, change_type: l.change_type, status: j.status,
          before_rate: j.before_rate, after_rate: j.after_rate, cut_pct: j.cut_pct });
        const moved = j.status !== "measuring" || l.before_blocks !== j.before_blocks || l.before_reviewed !== j.before_reviewed
          || l.after_blocks !== j.after_blocks || l.after_reviewed !== j.after_reviewed || l.after_end !== j.after_end;
        if (!moved) continue;
        stmts.push(env.DB.prepare(
          `UPDATE lessons SET status = ?2, before_blocks = ?3, before_reviewed = ?4, after_blocks = ?5,
             after_reviewed = ?6, after_end = ?7, cut_pct = ?8, measured_at = ?9, updated_at = ?9
           WHERE id = ?1 AND status = 'measuring'`
        ).bind(l.id, j.status, j.before_blocks, j.before_reviewed, j.after_blocks, j.after_reviewed, j.after_end, j.cut_pct, t));
      }
      if (stmts.length) await env.DB.batch(stmts);
      return json(200, { judged, still_measuring: still, more, truncated: false, settings: c, as_of: t });
    }),
  ],

  // ── GET /api/lessons/pending ────────────────────────────────────────────
  // escalate: not-working rows with no escalation issue yet, each with its
  // next_stage (null for the strongest). retire: plan-lesson rows not yet
  // superseded or removed, with no removal PR, whose category has a LATER
  // check or harness-bug row (superseded_by names the earliest). removing:
  // plan-lesson rows not yet superseded or removed whose removal PR is
  // recorded; the lane reads each PR live. escalated_open: rows whose
  // escalation issue has no lessons row of its own yet.
  [
    "GET", "/api/lessons/pending",
    async ({ env, t }) => d1Guarded("lessons", async () => {
      const c = await conf(env);
      const [esc, typed, open] = await Promise.all([
        env.DB.prepare(PENDING_ESCALATE_SQL).all(),
        env.DB.prepare(PENDING_TYPE_SQL).all(),
        env.DB.prepare(PENDING_ESCALATED_SQL).all(),
      ]);
      const escalate = (esc.results || []).map((l) => ({ ...l, next_stage: nextStage(c.stage_order, l.change_type) }));
      const ty = typed.results || [];
      const strong = ty.filter((l) => l.change_type !== "plan-lesson" && l.status !== "removed");
      const retire = [];
      const removing = [];
      for (const l of ty) {
        if (l.change_type !== "plan-lesson" || l.status === "superseded" || l.status === "removed") continue;
        if (l.removal_number !== null && l.removal_number !== undefined) { removing.push(l); continue; }
        const later = strong.filter((s) => s.category === l.category && s.merged_at > l.merged_at)
          .sort((a, b) => (a.merged_at < b.merged_at ? -1 : 1))[0];
        if (later) retire.push({ ...l, superseded_by: later.id, superseded_by_type: later.change_type, superseded_by_url: later.url });
      }
      return json(200, {
        escalate, retire, removing, escalated_open: open.results || [],
        settings: { window_days: c.window_days, min_cut_pct: c.min_cut_pct, min_reviewed: c.min_reviewed, stage_order: c.stage_order },
        as_of: t,
      });
    }),
  ],

  // ── POST /api/lessons/mark ──────────────────────────────────────────────
  // {id, escalation_stage?, escalation_number?, escalation_url?,
  // removal_number?, removal_url?, removal_note?, superseded_by?, status?,
  // clear_removal?}. Only these columns; status only to superseded | removed.
  // clear_removal: true sets removal_number and removal_url to NULL (the
  // removal PR closed without a merge). One UPDATE.
  [
    "POST", "/api/lessons/mark",
    async ({ env, body, t }) => {
      const b = body || {};
      if (!posInt(b.id)) return bad("id");
      const allowed = ["id", "escalation_stage", "escalation_number", "escalation_url", "removal_number", "removal_url",
        "removal_note", "superseded_by", "status", "clear_removal"];
      const unknown = Object.keys(b).find((k) => !allowed.includes(k));
      if (unknown) return bad(unknown);
      const set = [];
      const binds = [b.id];
      const add = (col, v) => { binds.push(v); set.push(`${col} = ?${binds.length}`); };
      if (b.escalation_stage !== undefined) { if (!STAGES.includes(b.escalation_stage)) return bad("escalation_stage"); add("escalation_stage", b.escalation_stage); }
      for (const k of ["escalation_number", "removal_number", "superseded_by"]) {
        if (b[k] !== undefined) { if (!posInt(b[k])) return bad(k); add(k, b[k]); }
      }
      for (const k of ["escalation_url", "removal_url"]) {
        if (b[k] !== undefined) { if (typeof b[k] !== "string" || !b[k].startsWith("https://") || b[k].length > 500) return bad(k); add(k, b[k]); }
      }
      if (b.removal_note !== undefined) { if (typeof b.removal_note !== "string" || !/^[a-z0-9-]{1,40}$/.test(b.removal_note)) return bad("removal_note"); add("removal_note", b.removal_note); }
      if (b.status !== undefined) { if (b.status !== "superseded" && b.status !== "removed") return bad("status"); add("status", b.status); }
      if (b.clear_removal !== undefined) {
        if (b.clear_removal !== true || b.removal_number !== undefined || b.removal_url !== undefined || b.status !== undefined) return bad("clear_removal");
        set.push("removal_number = NULL", "removal_url = NULL");
      }
      if (!set.length) return bad("nothing to set");
      add("updated_at", t);
      return d1Guarded("lessons", async () => {
        // sql-ident-ok: set holds literal `<column> = ?N` clauses from the allowed list above, every value a bind
        const r = await env.DB.prepare(`UPDATE lessons SET ${set.join(", ")} WHERE id = ?1`).bind(...binds).run();
        const changes = r && r.meta ? r.meta.changes : 0;
        if (!changes) return json(404, { error: "no such lesson" });
        return json(200, { updated: changes, id: b.id, as_of: t });
      });
    },
  ],

  // ── POST /api/lessons/retention ─────────────────────────────────────────
  // Count only: lessons is a history table and its rows are KEPT (BH-6730:
  // history rows are archived, never deleted). It counts the judged rows older
  // than lessons.retention_days, and the lane writes the count in the week's
  // lesson_measure ledger row. A delete here would also let the daily sweep
  // record an old lesson_proposal row again as a new `measuring` row.
  // -> {eligible, cutoff, retention_days}.
  [
    "POST", "/api/lessons/retention",
    async ({ env, t }) => d1Guarded("lessons", async () => {
      const c = await conf(env);
      const cutoff = iso(Date.parse(t) - c.retention_days * DAY_MS);
      const n = await env.DB.prepare(RETENTION_COUNT_SQL).bind(cutoff).first("n");
      return json(200, { eligible: n || 0, cutoff, retention_days: c.retention_days, as_of: t });
    }),
  ],

  // ── GET /api/lessons/digest?days= ───────────────────────────────────────
  // The weekly digest: the BLOCK rate overall and per category in the last
  // `days` (default lessons.digest_days), the lessons by status, and the top 5
  // uncovered causes: the categories (not `other`) with the most BLOCKs and no
  // lesson in `measuring` or `working`.
  [
    "GET", "/api/lessons/digest",
    async ({ env, url, t }) => d1Guarded("lessons", async () => {
      const c = await conf(env);
      let days = c.digest_days;
      if (url.searchParams.has("days")) {
        const v = url.searchParams.get("days");
        if (!/^\d+$/.test(v) || Number(v) < 1 || Number(v) > 90) return bad("days");
        days = Number(v);
      }
      const since = iso(Date.parse(t) - days * DAY_MS);
      const [cat, all, names, st, list] = await Promise.all([
        env.DB.prepare(DIGEST_CATEGORY_SQL).bind(since).all(),
        env.DB.prepare(DIGEST_OVERALL_SQL).bind(since).first(),
        env.DB.prepare(DIGEST_NAMES_SQL).all(),
        env.DB.prepare(DIGEST_STATUS_SQL).bind(since).all(),
        env.DB.prepare(DIGEST_LIST_SQL).bind(c.list_limit + 1).all(),
      ]);
      const reviewed = (all && all.reviewed) || 0;
      const overallBlocks = (all && all.blocks) || 0;
      const nameOf = new Map((names.results || []).map((r) => [r.id, r.name]));
      const totals = Object.fromEntries(STATUSES.map((s) => [s, 0]));
      let added = 0;
      let removing = 0;
      const latest = new Map(); // category -> {status, last_at}
      const covered = new Set();
      for (const r of st.results || []) {
        if (r.status in totals) totals[r.status] += r.n;
        added += r.added || 0;
        if (r.status !== "superseded" && r.status !== "removed") removing += r.removing || 0;
        if (r.status === "measuring" || r.status === "working") covered.add(r.category);
        const cur = latest.get(r.category);
        if (!cur || r.last_at > cur.last_at) latest.set(r.category, { status: r.status, last_at: r.last_at });
      }
      const categories = (cat.results || []).map((r) => ({
        id: r.category, name: nameOf.get(r.category) || r.category, blocks: r.n, rate: rate(r.n, reviewed),
        lesson_status: latest.has(r.category) ? latest.get(r.category).status : null,
      })).sort((a, b) => b.blocks - a.blocks || (a.id < b.id ? -1 : 1));
      const other = categories.find((x) => x.id === "other");
      const uncovered = categories.filter((x) => x.id !== "other" && !covered.has(x.id)).slice(0, 5)
        .map((x) => ({ id: x.id, name: x.name, blocks: x.blocks, rate: x.rate }));
      const lrows = list.results || [];
      return json(200, {
        window: { since, days },
        overall: { blocks: overallBlocks, reviewed, rate: rate(overallBlocks, reviewed) },
        categories,
        lessons: {
          added, measuring: totals.measuring, working: totals.working, not_working: totals["not-working"],
          inconclusive: totals.inconclusive, retired: totals.superseded + totals.removed, removing,
          list: lrows.slice(0, c.list_limit), list_truncated: lrows.length > c.list_limit,
        },
        uncovered, other_blocks: other ? other.blocks : 0,
        settings: { window_days: c.window_days, min_cut_pct: c.min_cut_pct, min_reviewed: c.min_reviewed },
        as_of: t,
      });
    }),
  ],
];

// lesson-propose routes — BH-5807 (BH-5794.2): propose fixes for repeat causes.
//
// bin/lesson-propose.sh (hub, daily) asks GET /api/lesson-propose/triggers for
// the categories with lesson_propose.min_blocks or more DISTINCT BLOCK verdicts
// in the last lesson_propose.since_days days, and for the clusters of `other`
// findings (#5806 keeps the model's own label in raw_category) whose label slug
// reaches the same threshold. For a cluster with no category row, the lane
// calls POST /api/lesson-propose/categories, which adds the row with a reason
// and moves the window's matching `other` findings into it.
//
// The tables are #5806's (block_findings, block_categories, settings); this
// family adds none. Both hot reads are exported so the EXPLAIN QUERY PLAN test
// checks the exact text the routes run (BH-6730): the window read is served by
// idx_block_findings_at, the cluster read by idx_block_findings_cat.
//
// D1 has no RLS. Both routes sit behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES), which is the admin-only gate.

import { json, d1Guarded } from "../lib/http.js";

// Fallbacks, used only when the settings row lesson_propose.<key> is absent or junk.
const MIN_BLOCKS_DEFAULT = 3;
const SINCE_DAYS_DEFAULT = 14;
const COOLDOWN_DAYS_DEFAULT = 14;
const MAX_ATTEMPTS_DEFAULT = 3;
const MAX_WINDOW_ROWS = 5000;
const MAX_EVIDENCE = 20;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
// Copy of block-findings.js SLUG_RE (module-local there): a block_categories id.
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

export const TRIGGERS_WINDOW_SQL =
  `SELECT f.verdict_id, f.n, f.repo, f.pr, f.ticket, f.category, f.raw_category, f.cause, f.files,
          f.infra_false, f.text, v.report_url
     FROM block_findings f LEFT JOIN verdicts v ON v.id = f.verdict_id
    WHERE f.verdict_at >= ?1
    ORDER BY f.verdict_at DESC, f.verdict_id DESC, f.n ASC LIMIT ?2`;
export const CLUSTER_MOVE_SQL =
  "SELECT id, pr, raw_category FROM block_findings WHERE category = 'other' AND verdict_at >= ?1";

const bad = (field) => json(400, { error: field });
const clip = (v, max) => (typeof v === "string" && v.length > 0 ? v.slice(0, max) : null);
// Copy of block-findings.js settingInt (module-local there, as in project-leases.js).
const settingInt = async (env, key, def, lo, hi) => {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first("value");
  const n = Number(v);
  return v !== null && Number.isInteger(n) && n >= lo && n <= hi ? n : def;
};
const isoMinusDays = (t, days) => new Date(Date.parse(t) - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
const parseList = (s) => { try { const v = JSON.parse(s); return Array.isArray(v) ? v : []; } catch { return []; } };
// The slug of a raw model label: lowercase, every run of other characters one
// hyphen, trimmed, cut to 63. Null when the result is no valid id, or `other`.
const slugOf = (s) => {
  if (typeof s !== "string") return null;
  const v = s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63).replace(/-+$/, "");
  return v && v !== "other" && SLUG_RE.test(v) ? v : null;
};
// The trigger fields of one group of findings (newest first).
const triggerOf = (fs) => {
  const vids = [...new Set(fs.map((f) => f.verdict_id))].sort((a, b) => a - b);
  const prs = new Map();
  for (const f of fs) {
    const k = `${f.repo}#${f.pr}`;
    if (!prs.has(k)) prs.set(k, { repo: f.repo, pr: f.pr, report_url: f.report_url || null, ticket: f.ticket || null });
  }
  return {
    blocks: vids.length, findings: fs.length, infra_false: fs.filter((f) => f.infra_false === 1).length,
    verdict_ids: vids, prs: [...prs.values()],
    evidence: fs.slice(0, MAX_EVIDENCE).map((f) => ({
      text: String(f.text || "").slice(0, 600), cause: f.cause || null, files: parseList(f.files), repo: f.repo, pr: f.pr,
    })),
  };
};

export const routes = [
  // ── GET /api/lesson-propose/triggers ────────────────────────────────────
  // `categories`: each ACTIVE category but `other` with at least
  // lesson_propose.min_blocks DISTINCT BLOCK verdicts in the window.
  // `clusters`: the window's `other` findings grouped by the slug of their raw
  // label, with the same threshold; `exists` is the status of a row with that
  // id, or null. `truncated` is true when the window held more than
  // MAX_WINDOW_ROWS findings (the newest were read).
  [
    "GET", "/api/lesson-propose/triggers",
    async ({ env, t }) => d1Guarded("block_findings", async () => {
      const settings = {
        min_blocks: await settingInt(env, "lesson_propose.min_blocks", MIN_BLOCKS_DEFAULT, 2, 50),
        since_days: await settingInt(env, "lesson_propose.since_days", SINCE_DAYS_DEFAULT, 1, 90),
        cooldown_days: await settingInt(env, "lesson_propose.cooldown_days", COOLDOWN_DAYS_DEFAULT, 1, 90),
        max_attempts: await settingInt(env, "lesson_propose.max_attempts", MAX_ATTEMPTS_DEFAULT, 1, 10),
      };
      const since = isoMinusDays(t, settings.since_days);
      const { results } = await env.DB.prepare(TRIGGERS_WINDOW_SQL).bind(since, MAX_WINDOW_ROWS + 1).all();
      const rows = (results || []).slice(0, MAX_WINDOW_ROWS);
      const cats = (await env.DB.prepare("SELECT * FROM block_categories").all()).results || [];
      const byId = new Map(cats.map((c) => [c.id, c]));
      const groups = new Map();
      const clusterGroups = new Map();
      for (const r of rows) {
        if (r.category !== "other") {
          if (!groups.has(r.category)) groups.set(r.category, []);
          groups.get(r.category).push(r);
          continue;
        }
        const s = slugOf(r.raw_category);
        if (!s) continue;
        if (!clusterGroups.has(s)) clusterGroups.set(s, []);
        clusterGroups.get(s).push(r);
      }
      const categories = [];
      for (const [id, fs] of groups) {
        const c = byId.get(id);
        if (!c || c.status !== "active") continue;
        const tr = triggerOf(fs);
        if (tr.blocks < settings.min_blocks) continue;
        categories.push({ id, name: c.name, description: c.description, suggested_stage: c.suggested_stage, grp: c.grp, ...tr });
      }
      const clusters = [];
      for (const [id, fs] of clusterGroups) {
        const tr = triggerOf(fs);
        if (tr.blocks < settings.min_blocks) continue;
        const counts = new Map();
        for (const f of fs) counts.set(f.raw_category, (counts.get(f.raw_category) || 0) + 1);
        const raw_labels = [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([l]) => l).slice(0, 20);
        const c = byId.get(id);
        clusters.push({ id, raw_labels, exists: c ? c.status : null, ...tr });
      }
      const order = (a, b) => b.blocks - a.blocks || (a.id < b.id ? -1 : 1);
      return json(200, {
        categories: categories.sort(order), clusters: clusters.sort(order), settings, since,
        truncated: (results || []).length > MAX_WINDOW_ROWS, as_of: t,
      });
    }),
  ],

  // ── POST /api/lesson-propose/categories ─────────────────────────────────
  // {id, name, description?, reason, raw_labels[], since}. Adds one category
  // row for a cluster (added_by lesson-propose, group Lesson-propose, no
  // suggested_stage) and moves the `other` findings at or after `since` whose
  // raw label slugs to one of raw_labels' slugs into it, in ONE batch.
  // New: 201 {created:true, moved}. Active already: 200 {created:false, moved}
  // (the move still runs, so a replay heals a half-done tick). Retired: 409
  // retired, nothing written.
  [
    "POST", "/api/lesson-propose/categories",
    async ({ env, body, t }) => {
      const b = body || {};
      if (typeof b.id !== "string" || !SLUG_RE.test(b.id) || b.id === "other") return bad("id");
      if (typeof b.name !== "string" || b.name.trim().length < 1 || b.name.length > 120) return bad("name");
      if (b.description !== undefined && b.description !== null && typeof b.description !== "string") return bad("description");
      if (typeof b.reason !== "string" || b.reason.trim().length < 1 || b.reason.length > 500) return bad("reason");
      if (!Array.isArray(b.raw_labels) || b.raw_labels.length < 1 || b.raw_labels.length > 20
          || !b.raw_labels.every((l) => typeof l === "string" && l.length > 0 && l.length <= 200)) return bad("raw_labels");
      if (typeof b.since !== "string" || !ISO_RE.test(b.since) || Number.isNaN(Date.parse(b.since))) return bad("since");
      const labels = new Set(b.raw_labels.map(slugOf).filter(Boolean));
      return d1Guarded("block_categories", async () => {
        const row = await env.DB.prepare("SELECT status FROM block_categories WHERE id=?1").bind(b.id).first();
        if (row && row.status !== "active") return json(409, { error: "retired", status: row.status });
        const { results } = await env.DB.prepare(CLUSTER_MOVE_SQL).bind(b.since).all();
        const move = (results || []).filter((r) => labels.has(slugOf(r.raw_category)));
        const stmts = [];
        if (!row) {
          const prs = [...new Set(move.map((r) => r.pr))].slice(0, 5);
          stmts.push(env.DB.prepare(
            `INSERT OR IGNORE INTO block_categories (id, name, description, grp, suggested_stage, example_prs, status,
               added_by, reason, created_at, updated_at)
             VALUES (?1, ?2, ?3, 'Lesson-propose', NULL, ?4, 'active', 'lesson-propose', ?5, ?6, ?6)`
          ).bind(b.id, b.name.trim(), clip(b.description, 1000), JSON.stringify(prs), b.reason.trim(), t));
        }
        // D1 binds at most 100 values a statement: the ids go in chunks.
        for (let i = 0; i < move.length; i += 90) {
          const ids = move.slice(i, i + 90).map((r) => r.id);
          // sql-ident-ok: the IN list is ?N placeholders built from the ids index, every id a bind
          stmts.push(env.DB.prepare(
            `UPDATE block_findings SET category = ?1 WHERE category = 'other' AND id IN (${ids.map((_, k) => `?${k + 2}`).join(",")})`
          ).bind(b.id, ...ids));
        }
        if (stmts.length) await env.DB.batch(stmts);
        return json(row ? 200 : 201, { created: !row, id: b.id, moved: move.length, as_of: t });
      });
    },
  ],
];

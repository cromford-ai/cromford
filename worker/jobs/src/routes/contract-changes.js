// contract-changes routes — BH-9929: the contract-change step ledger
// (schema.d/202611260538-bh-9929-contract-changes.sql). A non-additive schema
// change runs as 3 ordered PRs per parent ticket (expand, migrate, contract);
// each step PR records one row. Both routes sit behind the main bearer
// (HARNESS_SECRET), like every gated family; index.js answers 401 before a
// handler runs.
//
// POST /api/contract-changes {project, parent_ticket, step, pr_url?, head_sha?,
//   classes?, backup_ref?, restore_ref?, verdict?, approved_by?}
//   400 when project is not a slug, parent_ticket is not a positive integer,
//   step is not expand | migrate | contract, or an optional field is not a
//   string (or is longer than its cap). ONE upsert on UNIQUE (project,
//   parent_ticket, step). An empty or absent optional field never overwrites a
//   stored non-empty value, so a later POST with only verdict + approved_by
//   keeps backup_ref. updated_at = now. 200 {row}.
//   Writer: cc_record in bin/lib/contract-change-record.sh.
//
// GET /api/contract-changes?project=<p>[&parent_ticket=<n>][&step=<s>][&limit=<n>]
//   project is required. Rows ORDER BY updated_at DESC, at most limit, and
//   limit is capped at the settings row lib.contract-change.contract_changes_list_max.
//   200 {rows: [...], limit}. Each row also carries the step PR's live
//   verdict (BH-9929 review: the stored `verdict` is written only at PR open,
//   `pending`, and after an autopilot apply, so a merged step showed `pending`
//   forever): from the verdicts table, the newest non-retracted lead or human
//   row of the PR's newest reviewed head, a human row first on that head (a
//   human verdict is final on its head). Fields: verdict (that row's word, else
//   the stored value), verdict_source (lead | human | recorded),
//   verdict_head, verdict_reviewer. One extra round trip: a D1 batch of one
//   indexed read per distinct PR on the page (idx_verdicts_pr_head), at most
//   the list cap. Readers: the console project page
//   (ContractChangesPanel.js) and bin/migration-autopilot.sh (one row by
//   project + parent_ticket + step). The list reads
//   idx_contract_changes_project_updated; a parent_ticket filter reads the
//   UNIQUE autoindex.

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable, strictInt } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const STEPS = new Set(["expand", "migrate", "contract"]);
// Fallback of the settings row lib.contract-change.contract_changes_list_max
// (registry knob CONTRACT_CHANGES_LIST_MAX in catalog/lanes.d/_lib.contract-change.json,
// seeded 100), read as an integer in 1..500.
const LIST_MAX_ENV = "CONTRACT_CHANGES_LIST_MAX";
const LIST_MAX_KEY = `lib.contract-change.${LIST_MAX_ENV.toLowerCase()}`;
const LIST_MAX_DEFAULT = 100;
const LIST_MAX_CEIL = 500;
// Field caps are input validation of a request body (the size of one text
// cell), not a limit on work, so they are not settings rows.
const FIELD_MAX = { pr_url: 500, head_sha: 64, classes: 500, backup_ref: 500, restore_ref: 500, verdict: 64, approved_by: 128 };
const OPTIONAL = Object.keys(FIELD_MAX);

const bad = (field) => json(400, { error: field });

export const SQL = {
  upsert: `INSERT INTO contract_changes (project, parent_ticket, step, ${OPTIONAL.join(", ")}, created_at, updated_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)
           ON CONFLICT (project, parent_ticket, step) DO UPDATE SET
             ${OPTIONAL.map((c) => `${c} = COALESCE(NULLIF(excluded.${c},''), contract_changes.${c})`).join(",\n             ")},
             updated_at = excluded.updated_at
           RETURNING *`,
  list: `SELECT * FROM contract_changes WHERE project = ?1 ORDER BY updated_at DESC LIMIT ?2`,
  listTicket: `SELECT * FROM contract_changes WHERE project = ?1 AND parent_ticket = ?2 ORDER BY updated_at DESC LIMIT ?3`,
  listTicketStep: `SELECT * FROM contract_changes WHERE project = ?1 AND parent_ticket = ?2 AND step = ?3 LIMIT ?4`,
  listStep: `SELECT * FROM contract_changes WHERE project = ?1 AND step = ?2 ORDER BY updated_at DESC LIMIT ?3`,
  // The live verdict of one PR. Both reads use idx_verdicts_pr_head
  // (repo, pr, head_sha, id); verdict_retractions is read by its primary key.
  prVerdict: `SELECT verdict, source, reviewer, head_sha FROM verdicts
           WHERE repo = ?1 AND pr = ?2 AND source IN ('lead','human')
             AND id NOT IN (SELECT verdict_id FROM verdict_retractions)
             AND head_sha = (SELECT head_sha FROM verdicts
                              WHERE repo = ?1 AND pr = ?2 AND source IN ('lead','human')
                                AND id NOT IN (SELECT verdict_id FROM verdict_retractions)
                              ORDER BY id DESC LIMIT 1)
           ORDER BY (source = 'human') DESC, id DESC LIMIT 1`,
};

const PR_RE = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)$/;
const prKey = (url) => {
  const m = typeof url === "string" ? PR_RE.exec(url) : null;
  return m ? { repo: m[1], pr: Number(m[2]), key: `${m[1]}#${m[2]}` } : null;
};

// withLiveVerdicts <env> <rows> — rowOut rows plus verdict_source,
// verdict_head and verdict_reviewer (see the header). A failed verdict read
// keeps the stored values (verdict_source = recorded): the list never fails
// because of it.
async function withLiveVerdicts(env, rows) {
  const prs = new Map();
  for (const r of rows) { const k = prKey(r.pr_url); if (k && !prs.has(k.key)) prs.set(k.key, k); }
  const live = new Map();
  if (prs.size) {
    try {
      await ensureTable(env, "verdicts");
      await ensureTable(env, "verdict_retractions");
      const keys = [...prs.values()];
      const res = await env.DB.batch(keys.map((k) => env.DB.prepare(SQL.prVerdict).bind(k.repo, k.pr)));
      keys.forEach((k, i) => { const v = res[i]?.results?.[0]; if (v) live.set(k.key, v); });
    } catch (e) {
      console.warn("[contract-changes] live verdict read failed; stored verdicts shown", String(e && e.message || e));
    }
  }
  return rows.map((r) => {
    const k = prKey(r.pr_url);
    const v = k ? live.get(k.key) : undefined;
    return v
      ? { ...r, verdict: v.verdict, verdict_source: v.source, verdict_head: v.head_sha ?? null, verdict_reviewer: v.reviewer ?? null }
      : { ...r, verdict_source: "recorded", verdict_head: null, verdict_reviewer: null };
  });
}

const rowOut = (r) => ({
  id: r.id, project: r.project, parent_ticket: r.parent_ticket, step: r.step,
  pr_url: r.pr_url ?? null, head_sha: r.head_sha ?? null, classes: r.classes ?? null,
  backup_ref: r.backup_ref ?? null, restore_ref: r.restore_ref ?? null, verdict: r.verdict ?? null,
  approved_by: r.approved_by ?? null, created_at: r.created_at ?? null, updated_at: r.updated_at ?? null,
});

// A positive integer from a number or a digit string, else null.
const posInt = (v) => {
  if (typeof v === "string" && !/^\d+$/.test(v.trim())) return null;
  const n = strictInt(v);
  return n !== null && n > 0 ? n : null;
};

export const routes = [
  [
    "POST", "/api/contract-changes",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      const ticket = posInt(b.parent_ticket);
      if (ticket === null) return bad("parent_ticket");
      if (typeof b.step !== "string" || !STEPS.has(b.step)) return bad("step must be expand, migrate or contract");
      const vals = [];
      for (const f of OPTIONAL) {
        const v = b[f];
        if (v === undefined || v === null) { vals.push(""); continue; }
        if (typeof v !== "string" || v.length > FIELD_MAX[f] || /[\r\n]/.test(v)) return bad(f);
        vals.push(v.trim());
      }
      return d1Guarded("contract_changes", async () => {
        await ensureTable(env, "contract_changes");
        // An absent field is stored as NULL on insert, and never overwrites on update.
        const row = await env.DB.prepare(SQL.upsert)
          .bind(b.project, ticket, b.step, ...vals.map((v) => (v === "" ? null : v)), t).first();
        if (!row) return json(503, { error: "contract_changes upsert returned no row" });
        return json(200, { row: rowOut(row) });
      });
    },
  ],
  [
    "GET", "/api/contract-changes",
    async ({ env, url }) => {
      const p = url.searchParams;
      const project = p.get("project") || "";
      if (!PROJECT_RE.test(project)) return bad("project");
      const ticketRaw = p.get("parent_ticket");
      const ticket = ticketRaw === null || ticketRaw === "" ? null : posInt(ticketRaw);
      if (ticketRaw !== null && ticketRaw !== "" && ticket === null) return bad("parent_ticket");
      const step = p.get("step") || null;
      if (step !== null && !STEPS.has(step)) return bad("step must be expand, migrate or contract");
      const limRaw = p.get("limit");
      const lim = limRaw === null || limRaw === "" ? null : posInt(limRaw);
      if (limRaw !== null && limRaw !== "" && lim === null) return bad("limit");
      return d1Guarded("contract_changes", async () => {
        await ensureTable(env, "contract_changes");
        const { byKey } = await settingsRows(env);
        const cap = intSetting(byKey, LIST_MAX_KEY, LIST_MAX_DEFAULT, 1, LIST_MAX_CEIL);
        const limit = Math.min(lim ?? cap, cap);
        let stmt;
        if (ticket !== null && step !== null) stmt = env.DB.prepare(SQL.listTicketStep).bind(project, ticket, step, limit);
        else if (ticket !== null) stmt = env.DB.prepare(SQL.listTicket).bind(project, ticket, limit);
        else if (step !== null) stmt = env.DB.prepare(SQL.listStep).bind(project, step, limit);
        else stmt = env.DB.prepare(SQL.list).bind(project, limit);
        const { results } = await stmt.all();
        return json(200, { rows: await withLiveVerdicts(env, (results || []).map(rowOut)), limit });
      });
    },
  ],
];

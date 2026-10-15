// staff outcomes routes — BH-5563 (BH-5556.6): the staff learning loop over
// the BH-5560 findings ledger (schema.d/202610150612-bh-5563-staff-outcomes.sql).
//
// POST /api/staff/outcomes closes ONE filed finding with the word the hub
// resolver (bin/staff-outcomes.sh) read off its GitHub issue: merged (verdict
// agree), rejected or noise (verdict overrule). Everything it changes is one
// D1 batch, and every statement after the first is conditioned on the
// outcome row still having applied = 0, which the last statement sets: the
// finding's status, its staff decision (approve or change, counted), the
// staff_classes streak, and then by verdict:
//   overrule  the agent drops one level (agent-core nextLevel, floor
//             automation) by a compare-and-set on the level read before the
//             batch; a lost race leaves the level as it is (demoted:false,
//             reason "raced"). A pending promotion is voided.
//   agree     a pending promotion the agent has since reached is marked
//             applied. When nextLevel with a hypothetical `delegate` after
//             the agent's outcomes since its last level change would raise it
//             (Archie's rule: settings staff.delegate_after agreements in a
//             row, never above the cap), ONE pending staff_promotions row is
//             proposed. Only an active agent gets one. A human applies it with
//             POST /api/staff/agents/autonomy; this route never raises a level.
//   noise     when the family (agent + class slug) has K noise outcomes since
//             its last proposal (settings staff.noise_suppress_after, default
//             3) and has no pending row and no unexpired active row, ONE
//             staff_suppressions row is proposed with status 'pending' and no
//             approver. A pending row never blocks a claim.
// A replay with the same outcome is 200 existing:true and writes nothing; a
// different outcome is 409 outcome_conflict. Every refusal writes nothing.
//
// GET /api/staff/outcomes/pending is the resolver's work list: filed findings
// with a ticket_url, by id, paged with after_id.
// GET /api/staff/precision is agent-core precision() over each agent's
// outcome verdicts, overall and by class. No outcome is null, never 0.
// POST /api/staff/suppressions/decide is the human decision on a pending
// suppression: approve (active until now + staff.noise_suppress_days, default
// 30) or decline (revoked). archie or a staff agent as approver is 403.

import { json, d1Guarded } from "../lib/http.js";
import { LEVELS, nextLevel, precision } from "../../../../agent-core/src/index.js";
import { isProtectedSlug } from "./archie-autonomy.js";
import { classSlug, familyFingerprint } from "../lib/staff-family.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const FP_RE = /^[0-9a-f]{64}$/;
const ISSUE_RE = /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[0-9]+$/;
const VERDICT = { merged: "agree", rejected: "overrule", noise: "overrule" };
const CHOICE = { agree: "approve", overrule: "change" };
const DAY_MS = 86400000;
// Each batch statement is a no-op once the outcome row is applied.
const GUARD = `EXISTS (SELECT 1 FROM staff_outcomes WHERE fingerprint=?1 AND applied=0)`;
const RANK_SQL = (x) => `CASE ${x} WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END`;

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// A settings row as an integer in [min, max]; absent or junk is the documented
// default, and the answer names which one was used.
const intSetting = async (env, key, def, min, max) => {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key=?1`).bind(key).first();
  const v = row && typeof row.value === "string" ? row.value.trim() : "";
  if (/^\d{1,4}$/.test(v) && Number(v) >= min && Number(v) <= max) return { value: Number(v), source: "settings" };
  return { value: def, source: "default" };
};
const isAgentName = async (env, who) => {
  const a = who.toLowerCase();
  if (a === "archie") return true;
  return !!(await env.DB.prepare(`SELECT 1 AS x FROM staff_agents WHERE name=?1`).bind(a).first());
};
const suppressionOut = (r) => ({
  id: r.id, fingerprint: r.fingerprint, reason: r.reason, approver: r.approver,
  expires_at: r.expires_at, status: r.status, created_at: r.created_at,
});

export const routes = [
  // ── POST /api/staff/outcomes — close one filed finding with its outcome ────
  [
    "POST", "/api/staff/outcomes",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      const fp = typeof b.fingerprint === "string" ? b.fingerprint.trim().toLowerCase() : "";
      if (!FP_RE.test(fp)) return bad("fingerprint");
      const outcome = typeof b.outcome === "string" ? b.outcome.trim().toLowerCase() : "";
      if (!VERDICT[outcome]) return bad("outcome");
      const ticketUrl = typeof b.ticket_url === "string" ? b.ticket_url.trim() : "";
      if (!ISSUE_RE.test(ticketUrl)) return bad("ticket_url");
      const verdict = VERDICT[outcome];

      return d1Guarded("staff_outcomes", async () => {
        const row = await env.DB.prepare(`SELECT * FROM staff_findings WHERE fingerprint=?1`).bind(fp).first();
        if (!row) return json(404, { error: "finding not found" });
        if (row.agent !== name) return json(409, { error: "wrong_agent", agent: row.agent });
        // An outcome already recorded: the same one is a replay, anything else a conflict.
        const prior = async () => {
          const o = await env.DB.prepare(`SELECT * FROM staff_outcomes WHERE fingerprint=?1`).bind(fp).first();
          if (!o) return null;
          if (o.ticket_url !== ticketUrl) return json(409, { error: "ticket_mismatch", ticket_url: o.ticket_url });
          if (o.outcome !== outcome) return json(409, { error: "outcome_conflict", outcome: o.outcome });
          return json(200, { ok: true, existing: true, outcome, verdict, class: o.class });
        };
        const seen = await prior();
        if (seen) return seen;
        if (row.status !== "filed") return json(409, { error: "not_filed", status: row.status });
        if (row.ticket_url !== ticketUrl) return json(409, { error: "ticket_mismatch", ticket_url: row.ticket_url });

        const agent = await env.DB.prepare(`SELECT * FROM staff_agents WHERE name=?1`).bind(name).first();
        if (!agent) return json(404, { error: "agent not found" });
        const dec = await env.DB.prepare(`SELECT class FROM staff_decisions WHERE escalation_key=?1`).bind(`staff:${fp}`).first();
        const slug = classSlug(dec ? dec.class : row.source_kind);
        const family = familyFingerprint(name, slug);
        const delegateAfter = await intSetting(env, "staff.delegate_after", 5, 1, 1000);
        const noiseAfter = await intSetting(env, "staff.noise_suppress_after", 3, 1, 1000);
        const noiseDays = await intSetting(env, "staff.noise_suppress_days", 30, 1, 3650);

        // Demotion and proposal are decided here, from the level read now; the
        // batch applies them only if that level still holds.
        const from = agent.autonomy;
        let demoteTo = from;
        let proposeTo = null;
        if (verdict === "overrule") {
          demoteTo = nextLevel(from, [{ verdict: "overrule" }], null);
        } else if (agent.status === "active") {
          const { results } = await env.DB.prepare(
            `SELECT verdict FROM staff_outcomes WHERE agent=?1 AND applied=1 AND resolved_at >= ?2 ORDER BY id`
          ).bind(name, agent.updated_at).all();
          const history = [...(results || []).map((r) => ({ verdict: r.verdict })), { verdict: "agree" }, { verdict: "delegate" }];
          const next = nextLevel(from, history, { agreementsToPromote: delegateAfter.value, cap: agent.cap });
          if (LEVELS.indexOf(next) > LEVELS.indexOf(from)) proposeTo = next;
        }

        const q = (sql, ...binds) => env.DB.prepare(sql).bind(fp, ...binds);
        const stmts = [];
        const at = {};
        const push = (key, stmt) => { at[key] = stmts.length; stmts.push(stmt); };
        push("outcome", q(
          `INSERT OR IGNORE INTO staff_outcomes
             (fingerprint, agent, class, family, outcome, verdict, ticket_url, resolved_at, suppression_proposed, applied)
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, 0
            WHERE EXISTS (SELECT 1 FROM staff_findings
                           WHERE fingerprint=?1 AND agent=?2 AND status='filed' AND ticket_url=?7)`,
          name, slug, family, outcome, verdict, ticketUrl, t));
        push("finding", q(
          `UPDATE staff_findings SET status=?2, updated_at=?3 WHERE fingerprint=?1 AND status='filed' AND ${GUARD}`,
          outcome, t));
        push("decision", q(
          `UPDATE staff_decisions SET choice=?2, counted=1, chosen_at=?3
            WHERE escalation_key='staff:' || ?1 AND choice IS NULL AND ${GUARD}`,
          CHOICE[verdict], t));
        push("class", q(
          `INSERT OR IGNORE INTO staff_classes (agent, class, cap, never_delegable, state, streak, updated_at, note)
           SELECT ?2, ?3, 'augmentation', ?4, 'ask_first', 0, ?5, 'BH-5563: first outcome' WHERE ${GUARD}`,
          name, slug, isProtectedSlug(slug) ? 1 : 0, t));
        if (verdict === "agree") {
          push("streak", q(
            `UPDATE staff_classes SET streak = streak + 1, updated_at=?4 WHERE agent=?2 AND class=?3 AND ${GUARD}`,
            name, slug, t));
          push("applied", q(
            `UPDATE staff_promotions SET status='applied', decided_at=?3
              WHERE agent=?2 AND status='pending'
                AND ${RANK_SQL(`(SELECT autonomy FROM staff_agents WHERE name=?2)`)} >= ${RANK_SQL("to_level")}
                AND ${GUARD}`,
            name, t));
          if (proposeTo) {
            push("promotion", q(
              `INSERT OR IGNORE INTO staff_promotions (agent, from_level, to_level, agreements, status, created_at)
               SELECT ?2, ?3, ?4, ?5, 'pending', ?6
                WHERE EXISTS (SELECT 1 FROM staff_agents WHERE name=?2 AND autonomy=?3 AND status='active') AND ${GUARD}`,
              name, from, proposeTo, delegateAfter.value, t));
          }
        } else {
          push("streak", q(
            `UPDATE staff_classes SET streak = 0, state = 'ask_first', updated_at=?4,
                    reverted_at = CASE WHEN state = 'delegated' THEN ?4 ELSE reverted_at END
              WHERE agent=?2 AND class=?3 AND ${GUARD}`,
            name, slug, t));
          if (demoteTo !== from) {
            push("demote", q(
              `UPDATE staff_agents SET autonomy=?3, updated_at=?5, note=?6
                WHERE name=?2 AND autonomy=?4 AND ${GUARD}`,
              name, demoteTo, from, t, `demoted by outcome ${fp.slice(0, 12)} (${outcome})`));
          }
          push("void", q(
            `UPDATE staff_promotions SET status='void', decided_at=?3 WHERE agent=?2 AND status='pending' AND ${GUARD}`,
            name, t));
        }
        if (outcome === "noise") {
          // Noise while the family has a pending or unexpired active row is a
          // window boundary: the next proposal counts only noise after it, so
          // closures from a pending window never count toward a re-proposal.
          push("window", q(
            `UPDATE staff_outcomes SET suppression_window = 1
              WHERE fingerprint=?1 AND applied=0 AND outcome='noise'
                AND EXISTS (SELECT 1 FROM staff_suppressions s
                             WHERE s.fingerprint=?2
                               AND (s.status='pending' OR (s.status='active' AND s.expires_at > ?3)))`,
            family, t));
          push("mark", q(
            `UPDATE staff_outcomes SET suppression_proposed = 1
              WHERE fingerprint=?1 AND applied=0 AND outcome='noise'
                AND (SELECT count(*) FROM staff_outcomes o
                      WHERE o.family=?2 AND o.outcome='noise'
                        AND o.id > COALESCE((SELECT max(p.id) FROM staff_outcomes p
                                              WHERE p.family=?2
                                                AND (p.suppression_proposed=1 OR p.suppression_window=1)), 0)) >= ?3
                AND NOT EXISTS (SELECT 1 FROM staff_suppressions s
                                 WHERE s.fingerprint=?2
                                   AND (s.status='pending' OR (s.status='active' AND s.expires_at > ?4)))`,
            family, noiseAfter.value, t));
          push("suppression", q(
            `INSERT OR IGNORE INTO staff_suppressions (fingerprint, reason, approver, expires_at, status, created_at)
             SELECT ?2, ?3, NULL, ?4, 'pending', ?5
              WHERE EXISTS (SELECT 1 FROM staff_outcomes WHERE fingerprint=?1 AND applied=0 AND suppression_proposed=1)`,
            family,
            `${name}: ${noiseAfter.value} noise closures of class ${slug}; proposed by the outcome loop, a human approves`,
            isoSeconds(Date.parse(t) + noiseDays.value * DAY_MS), t));
        }
        push("done", q(`UPDATE staff_outcomes SET applied=1 WHERE fingerprint=?1 AND applied=0`));
        const res = await env.DB.batch(stmts);

        if (changesOf(res[at.outcome]) !== 1) {
          // Another writer moved the finding between the read and the batch.
          const seen2 = await prior();
          if (seen2) return seen2;
          const now = await env.DB.prepare(`SELECT status FROM staff_findings WHERE fingerprint=?1`).bind(fp).first();
          return json(409, { error: "not_filed", status: now ? now.status : null });
        }
        const demoted = at.demote !== undefined && changesOf(res[at.demote]) === 1;
        const autonomy = { from, to: demoted ? demoteTo : from, demoted };
        if (verdict === "overrule" && demoteTo !== from && !demoted) autonomy.reason = "raced";
        let promotionId = null;
        if (at.promotion !== undefined && changesOf(res[at.promotion]) === 1) {
          const p = await env.DB.prepare(`SELECT id FROM staff_promotions WHERE agent=?1 AND status='pending'`).bind(name).first();
          promotionId = p ? p.id : null;
        }
        let suppressionId = null;
        if (at.suppression !== undefined && changesOf(res[at.suppression]) === 1) {
          const s = await env.DB.prepare(`SELECT id FROM staff_suppressions WHERE fingerprint=?1 AND status='pending'`).bind(family).first();
          suppressionId = s ? s.id : null;
        }
        const out = {
          ok: true, outcome, verdict, class: slug, autonomy,
          proposals: { promotion_id: promotionId, promotion_to: promotionId ? proposeTo : null, suppression_id: suppressionId },
        };
        if (outcome === "noise") out.noise_rule = { after: noiseAfter.value, source: noiseAfter.source };
        return json(200, out);
      });
    },
  ],

  // ── GET /api/staff/outcomes/pending — the resolver's work list ─────────────
  [
    "GET", "/api/staff/outcomes/pending",
    async ({ env, url }) => {
      const a = url.searchParams.get("after_id");
      const l = url.searchParams.get("limit");
      if (a !== null && !/^\d{1,15}$/.test(a)) return bad("after_id");
      if (l !== null && !(/^\d{1,3}$/.test(l) && Number(l) >= 1 && Number(l) <= 200)) return bad("limit");
      const after = a === null ? 0 : Number(a);
      const limit = l === null ? 50 : Number(l);
      return d1Guarded("staff_findings", async () => {
        const { results } = await env.DB.prepare(
          `SELECT id, agent, fingerprint, ticket_url FROM staff_findings
            WHERE status='filed' AND ticket_url IS NOT NULL AND id > ?1 ORDER BY id LIMIT ?2`
        ).bind(after, limit + 1).all();
        const rows = results || [];
        const findings = rows.slice(0, limit);
        return json(200, {
          findings, truncated: rows.length > limit,
          next_after_id: findings.length ? findings[findings.length - 1].id : null,
        });
      });
    },
  ],

  // ── GET /api/staff/precision — agent-core precision() per agent and class ──
  [
    "GET", "/api/staff/precision",
    async ({ env, url }) => {
      const raw = url.searchParams.get("agent");
      const only = raw === null ? null : agentOf(raw);
      if (raw !== null && only === null) return bad("agent");
      return d1Guarded("staff_outcomes", async () => {
        let names;
        if (only) {
          const row = await env.DB.prepare(`SELECT name FROM staff_agents WHERE name=?1`).bind(only).first();
          if (!row) return json(404, { error: "agent not found" });
          names = [only];
        } else {
          const { results } = await env.DB.prepare(`SELECT name FROM staff_agents ORDER BY name`).all();
          names = (results || []).map((r) => r.name);
        }
        // sql-ident-ok: one of two fixed literals ("AND agent=?1" or none); the agent name is a bind
        const { results: rows } = await env.DB.prepare(
          `SELECT agent, class, verdict FROM staff_outcomes WHERE applied=1 ${only ? "AND agent=?1" : ""} ORDER BY id`
        ).bind(...(only ? [only] : [])).all();
        const count = (list, v) => list.filter((o) => o.verdict === v).length;
        const agents = names.map((n) => {
          const mine = (rows || []).filter((r) => r.agent === n);
          const classes = [...new Set(mine.map((r) => r.class))].sort();
          return {
            agent: n, precision: precision(mine), agree: count(mine, "agree"), overrule: count(mine, "overrule"),
            by_class: classes.map((c) => {
              const cl = mine.filter((r) => r.class === c);
              return { class: c, precision: precision(cl), agree: count(cl, "agree"), overrule: count(cl, "overrule") };
            }),
          };
        });
        return json(200, { agents });
      });
    },
  ],

  // ── POST /api/staff/suppressions/decide — a human decides a pending row ────
  [
    "POST", "/api/staff/suppressions/decide",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (!(typeof b.id === "number" && Number.isInteger(b.id) && b.id > 0)) return bad("id");
      if (b.decision !== "approve" && b.decision !== "decline") return bad("decision");
      const approver = typeof b.approver === "string" ? b.approver.trim() : "";
      if (approver.length < 1 || approver.length > 64) return bad("approver");
      const to = b.decision === "approve" ? "active" : "revoked";

      return d1Guarded("staff_suppressions", async () => {
        if (await isAgentName(env, approver)) return json(403, { error: "agent_approver" });
        const read = () => env.DB.prepare(`SELECT * FROM staff_suppressions WHERE id=?1`).bind(b.id).first();
        const row = await read();
        if (!row) return json(404, { error: "suppression not found" });
        const days = await intSetting(env, "staff.noise_suppress_days", 30, 1, 3650);
        if (row.status === "pending") {
          const res = await env.DB.prepare(
            `UPDATE staff_suppressions SET status=?2, approver=?3,
                    expires_at = CASE WHEN ?2 = 'active' THEN ?4 ELSE expires_at END
              WHERE id=?1 AND status='pending'`
          ).bind(b.id, to, approver, isoSeconds(Date.parse(t) + days.value * DAY_MS)).run();
          const after = await read();
          if (changesOf(res) === 1) return json(200, { ok: true, suppression: suppressionOut(after), days });
          if (after && after.status === to) return json(200, { ok: true, existing: true, suppression: suppressionOut(after), days });
          return json(409, { error: "not_pending", status: after ? after.status : null });
        }
        if (row.status === to) return json(200, { ok: true, existing: true, suppression: suppressionOut(row), days });
        return json(409, { error: "not_pending", status: row.status });
      });
    },
  ],
];

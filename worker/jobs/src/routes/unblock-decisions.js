// unblock-decisions routes — BH-7722 (UNB-0): the write side of the Tackler
// decision ledger (unblock_decisions, schema.d/*-bh-7722-unblock-decisions.sql).
//
//   POST /api/unblock/decisions/claim        claim a decision key BEFORE any spend
//   POST /api/unblock/decisions/record       claimed -> one terminal outcome
//   GET  /api/unblock/decisions              rows by subject, project or outcome
//   POST /api/unblock/decisions/:id/answer   an escalated card -> answered
//
// CLAIM BEFORE SPEND (G10, G18). The lane claims the key with ONE
// `INSERT ... ON CONFLICT(decision_key) DO NOTHING` before any model call or
// write. Inserted = 200 {claimed:true, id}. A conflict = 409 {claimed:false,
// id, outcome, decision}: another tick owns the key and this one stops. The
// agent is always `tackler`: the body cannot name another.
//
// RECORD. ONE `UPDATE ... WHERE decision_key=?1 AND outcome='claimed'`. A row
// leaves `claimed` once: a second record is 409 not_claimed, an unknown key
// 404. `claimed`, `answered` and `expired` are never a record outcome.
// acted_at is set for would|done|failed|refused; resolved_at for every
// outcome except `escalated` (a card waits for its answer).
//
// LIST. At least one of project, subject, outcome. Newest first, limit 50
// (max 100), before_id pages. `card=u-xxxxxx` implies outcome=escalated and
// keeps the rows whose card.id is that id (bin/unblock-reply.sh, #7762, reads
// `.decisions[].card.id`). evidence, action_args and card come back parsed.
//
// ANSWER. {answer 1-4 | hold, answered_by (a person's email), command_id?,
// note?}. ONE `UPDATE ... WHERE id=?1 AND outcome='escalated'` that also
// checks the option against the card's option count. An agent (tackler,
// archie, any roster name) is 403 agent_answerer: the agent never answers its
// own card. With 0 changes: no row 404; the row's answer_command_id is this
// command 409 {duplicate:true}; still escalated (the option is out of range)
// 400 answer; otherwise 422 not_escalated. Only the duplicate is a 409,
// because unblock-reply.sh reads every 409 as "already recorded".
//
// THE READS (BH-6730). Every statement uses an index the fragment names;
// test/unblock-decisions.bh-7722.test.js W2 EXPLAINs these exact texts at
// 50 000 rows. `+col` keeps the planner on the index the filter is built for.
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const TABLE = "unblock_decisions";
const KEY_RE = /^[A-Za-z0-9._:-]{1,128}$/;
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const HEAD_RE = /^[0-9a-f]{7,40}$/;
const WORD_RE = /^[A-Za-z0-9._:-]{1,64}$/;
const ACTION_RE = /^[a-z_]{1,40}$/;
const CITE_RE = /^[A-Za-z0-9._:-]{1,40}$/;
const CARD_RE = /^u-[0-9a-f]{6}$/;
const INT_RE = /^[1-9]\d{0,15}$/;
const EMAIL_RE = /^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{1,63}$/;
const ANSWER_RE = /^([1-4]|hold)$/;
const SUBJECT_KINDS = new Set(["pr", "batch", "build", "box", "lane", "setting"]);
const DECISIONS = new Set(["act", "escalate", "refuse", "digest"]);
const MODES = new Set(["shadow", "act"]);
const RECORD_OUTCOMES = new Set(["would", "done", "failed", "refused", "no-route", "escalated"]);
const ACTED = new Set(["would", "done", "failed", "refused"]);
const LIST_OUTCOMES = new Set(["claimed", "would", "done", "failed", "refused", "no-route", "escalated", "answered", "expired"]);
// The agents that may never answer a card, besides every roster name.
const AGENT_NAMES = new Set(["tackler", "archie"]);
const JSON_MAX = 8192;
const TEXT_MAX = 500;
const SUBJECT_MAX = 200;
const LIMIT_DEFAULT = 50;
const LIMIT_MAX = 100;

export const CLAIM_SQL =
  `INSERT INTO unblock_decisions (decision_key, agent, project, repo, subject_kind, subject, head, stall_class,
     rule_id, rule_cites, evidence, decision, action, action_args, mode, outcome, created_at)
   VALUES (?1, 'tackler', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'claimed', ?15)
   ON CONFLICT(decision_key) DO NOTHING`;
export const CLAIM_READ_SQL =
  `SELECT id, outcome, decision FROM unblock_decisions WHERE decision_key = ?1`;
// ?1 key ?2 outcome ?3 detail ?4 model_calls ?5 cost_usd ?6 card ?7 now
// ?8 acted (0|1) ?9 resolved (0|1)
export const RECORD_SQL =
  `UPDATE unblock_decisions
      SET outcome = ?2, outcome_detail = ?3, model_calls = ?4, cost_usd = ?5, card = coalesce(?6, card),
          acted_at = CASE WHEN ?8 = 1 THEN ?7 ELSE acted_at END,
          resolved_at = CASE WHEN ?9 = 1 THEN ?7 ELSE resolved_at END
    WHERE decision_key = ?1 AND outcome = 'claimed'`;
// ?1 id ?2 answer ?3 answered_by ?4 now ?5 command_id ?6 note
export const ANSWER_SQL =
  `UPDATE unblock_decisions
      SET outcome = 'answered', answer = ?2, answered_by = ?3, answered_at = ?4, resolved_at = ?4,
          answer_command_id = ?5, outcome_detail = coalesce(?6, outcome_detail)
    WHERE id = ?1 AND outcome = 'escalated'
      AND (?2 = 'hold' OR CAST(?2 AS INTEGER) <= coalesce(json_array_length(card, '$.options'), 0))`;
const ANSWER_READ_SQL = `SELECT id, outcome, answer_command_id FROM unblock_decisions WHERE id = ?1`;
const COLUMNS =
  `id, decision_key, agent, project, repo, subject_kind, subject, head, stall_class, rule_id, rule_cites, evidence,
   decision, action, action_args, mode, outcome, outcome_detail, card, answer, answered_by, answered_at,
   model_calls, cost_usd, override_by, override_at, override_detail, created_at, acted_at, resolved_at`;

// listSql({subject, project, outcome, card}) — the one statement for a filter
// shape. The binds, in order: the filters present (subject, outcome, project),
// then before_id (or null), then the card id (or null) when the shape has the
// outcome filter, then the limit. Built only from fixed text: no input enters
// the SQL. The leading filter picks the index:
//   subject          -> idx_unblock_decisions_subject_id (project, outcome residual)
//   outcome          -> idx_unblock_decisions_outcome_project (project in the index)
//   project only     -> idx_unblock_decisions_project_id
export function listSql({ subject = false, project = false, outcome = false, card = false } = {}) {
  const where = [];
  let n = 0;
  if (subject) {
    where.push(`subject = ?${++n}`);
    if (project) where.push(`+project = ?${++n}`);
    if (outcome) where.push(`+outcome = ?${++n}`);
  } else if (outcome) {
    where.push(`outcome = ?${++n}`);
    if (project) where.push(`project = ?${++n}`);
  } else {
    where.push(`project = ?${++n}`);
  }
  const before = ++n;
  where.push(`(?${before} IS NULL OR id < ?${before})`);
  if (outcome || card) {
    const c = ++n;
    where.push(`(?${c} IS NULL OR json_extract(card, '$.id') = ?${c})`);
  }
  return `SELECT ${COLUMNS} FROM unblock_decisions WHERE ${where.join(" AND ")} ORDER BY id DESC LIMIT ?${++n}`;
}

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const optStr = (v, re) => v === undefined || v === null || (typeof v === "string" && re.test(v));
const parse = (s) => {
  if (typeof s !== "string") return s ?? null;
  try { return JSON.parse(s); } catch { return null; }
};
const rowOut = (r) => ({ ...r, evidence: parse(r.evidence), action_args: parse(r.action_args), card: parse(r.card) });

export const routes = [
  // ── POST /api/unblock/decisions/claim — claim a key before any spend ────────
  [
    "POST", "/api/unblock/decisions/claim",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      if (typeof b.decision_key !== "string" || !KEY_RE.test(b.decision_key)) return bad("decision_key");
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (!optStr(b.repo, REPO_RE)) return bad("repo");
      if (!SUBJECT_KINDS.has(b.subject_kind)) return bad("subject_kind");
      if (typeof b.subject !== "string" || b.subject.trim() === "" || b.subject.length > SUBJECT_MAX) return bad("subject");
      if (!optStr(b.head, HEAD_RE)) return bad("head");
      if (typeof b.stall_class !== "string" || !WORD_RE.test(b.stall_class)) return bad("stall_class");
      if (!DECISIONS.has(b.decision)) return bad("decision");
      // A rule is required except on an escalation (U12: no rule covers it).
      if (b.decision === "escalate" ? !optStr(b.rule_id, WORD_RE) : !(typeof b.rule_id === "string" && WORD_RE.test(b.rule_id))) {
        return bad("rule_id");
      }
      if (!Array.isArray(b.rule_cites) || b.rule_cites.length === 0 || b.rule_cites.length > 20
        || !b.rule_cites.every((c) => typeof c === "string" && CITE_RE.test(c))) return bad("rule_cites");
      if (!isObj(b.evidence)) return bad("evidence");
      const evidence = JSON.stringify(b.evidence);
      if (evidence.length > JSON_MAX) return bad("evidence_too_large");
      if (!optStr(b.action, ACTION_RE)) return bad("action");
      let args = null;
      if (b.action_args !== undefined && b.action_args !== null) {
        if (!isObj(b.action_args)) return bad("action_args");
        args = JSON.stringify(b.action_args);
        if (args.length > JSON_MAX) return bad("action_args");
      }
      if (!MODES.has(b.mode)) return bad("mode");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const res = await env.DB.prepare(CLAIM_SQL).bind(
          b.decision_key, b.project, b.repo ?? null, b.subject_kind, b.subject, b.head ?? null, b.stall_class,
          b.rule_id ?? null, b.rule_cites.join(","), evidence, b.decision, b.action ?? null, args, b.mode, t,
        ).run();
        const row = await env.DB.prepare(CLAIM_READ_SQL).bind(b.decision_key).first();
        if (!row) return json(500, { error: "claim_unresolved", decision_key: b.decision_key });
        if (changesOf(res) === 1) return json(200, { claimed: true, id: row.id });
        return json(409, { claimed: false, id: row.id, outcome: row.outcome, decision: row.decision });
      });
    },
  ],

  // ── POST /api/unblock/decisions/record — claimed -> one terminal outcome ────
  [
    "POST", "/api/unblock/decisions/record",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      if (typeof b.decision_key !== "string" || !KEY_RE.test(b.decision_key)) return bad("decision_key");
      if (!RECORD_OUTCOMES.has(b.outcome)) return bad("outcome");
      if (b.outcome_detail !== undefined && b.outcome_detail !== null
        && (typeof b.outcome_detail !== "string" || b.outcome_detail.length > TEXT_MAX)) return bad("outcome_detail");
      const calls = b.model_calls ?? 0;
      if (!Number.isInteger(calls) || calls < 0 || calls > 1000) return bad("model_calls");
      const cost = b.cost_usd ?? 0;
      if (typeof cost !== "number" || !Number.isFinite(cost) || cost < 0 || cost > 1000) return bad("cost_usd");
      let card = null;
      if (b.card !== undefined && b.card !== null) {
        if (!isObj(b.card)) return bad("card");
        card = JSON.stringify(b.card);
        if (card.length > JSON_MAX) return bad("card");
      }
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const res = await env.DB.prepare(RECORD_SQL).bind(
          b.decision_key, b.outcome, b.outcome_detail ?? null, calls, cost, card, t,
          ACTED.has(b.outcome) ? 1 : 0, b.outcome === "escalated" ? 0 : 1,
        ).run();
        if (changesOf(res) === 1) return json(200, { ok: true, decision_key: b.decision_key, outcome: b.outcome });
        const row = await env.DB.prepare(CLAIM_READ_SQL).bind(b.decision_key).first();
        if (!row) return json(404, { error: "decision not found" });
        return json(409, { error: "not_claimed", outcome: row.outcome });
      });
    },
  ],

  // ── GET /api/unblock/decisions?project=&subject=&outcome=&card=&before_id=&limit=
  [
    "GET", "/api/unblock/decisions",
    async ({ env, url }) => {
      const q = (k) => url.searchParams.get(k);
      const project = q("project"), subject = q("subject"), card = q("card");
      let outcome = q("outcome");
      if (project !== null && !PROJECT_RE.test(project)) return bad("project");
      if (subject !== null && (subject.trim() === "" || subject.length > SUBJECT_MAX)) return bad("subject");
      if (outcome !== null && !LIST_OUTCOMES.has(outcome)) return bad("outcome");
      if (card !== null) {
        if (!CARD_RE.test(card) || (outcome !== null && outcome !== "escalated")) return bad("card");
        outcome = "escalated";
      }
      if (project === null && subject === null && outcome === null) return bad("filter");
      const beforeQ = q("before_id");
      if (beforeQ !== null && !INT_RE.test(beforeQ)) return bad("before_id");
      const limitQ = q("limit");
      if (limitQ !== null && !(INT_RE.test(limitQ) && Number(limitQ) <= LIMIT_MAX)) return bad("limit");
      const limit = limitQ === null ? LIMIT_DEFAULT : Number(limitQ);
      const shape = { subject: subject !== null, project: project !== null, outcome: outcome !== null };
      const binds = [];
      if (shape.subject) {
        binds.push(subject);
        if (shape.project) binds.push(project);
        if (shape.outcome) binds.push(outcome);
      } else if (shape.outcome) {
        binds.push(outcome);
        if (shape.project) binds.push(project);
      } else {
        binds.push(project);
      }
      binds.push(beforeQ === null ? null : Number(beforeQ));
      if (shape.outcome) binds.push(card);
      binds.push(limit);
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        const { results } = await env.DB.prepare(listSql(shape)).bind(...binds).all();
        const decisions = (results || []).map(rowOut);
        return json(200, {
          limit, decisions,
          next_before_id: decisions.length === limit ? decisions[decisions.length - 1].id : null,
        });
      });
    },
  ],

  // ── POST /api/unblock/decisions/:id/answer — a person answers a card ────────
  [
    "POST", /^\/api\/unblock\/decisions\/(\d{1,15})\/answer$/,
    async ({ env, t, body, m }) => {
      const id = Number(m[1]);
      const b = isObj(body) ? body : {};
      if (typeof b.answer !== "string" || !ANSWER_RE.test(b.answer)) return bad("answer");
      const who = typeof b.answered_by === "string" ? b.answered_by.trim() : "";
      if (who === "") return bad("answered_by");
      if (!optStr(b.command_id, KEY_RE)) return bad("command_id");
      if (b.note !== undefined && b.note !== null && (typeof b.note !== "string" || b.note.length > TEXT_MAX)) return bad("note");
      return d1Guarded(TABLE, async () => {
        await ensureTable(env, TABLE);
        if (!EMAIL_RE.test(who)) {
          const name = who.toLowerCase();
          const roster = AGENT_NAMES.has(name)
            || !!(await env.DB.prepare("SELECT 1 AS x FROM staff_agents WHERE name = ?1").bind(name).first());
          return roster ? json(403, { error: "agent_answerer" }) : bad("answered_by");
        }
        const cmd = b.command_id ?? null;
        const res = await env.DB.prepare(ANSWER_SQL).bind(id, b.answer, who, t, cmd, b.note ?? null).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, outcome: "answered", answer: b.answer });
        const row = await env.DB.prepare(ANSWER_READ_SQL).bind(id).first();
        if (!row) return json(404, { error: "decision not found" });
        if (cmd !== null && row.answer_command_id === cmd) return json(409, { duplicate: true, id, outcome: row.outcome });
        if (row.outcome === "escalated") return bad("answer");
        return json(422, { error: "not_escalated", outcome: row.outcome });
      });
    },
  ],
];

// staff record route — BH-5561 (BH-5556.4): the staff heartbeat's record step
// (the last step of bin/staff.sh tick) over the BH-5560 findings ledger.
//
// POST /api/staff/findings/record writes what a tick did with one claimed
// finding: staff_findings.status moves from 'claimed' to one of digested,
// filed, refused, unsupported or failed, and a filing also sets ticket_url.
// The UPDATE only matches a row that is still 'claimed', so a record is never
// applied twice and never moves a row back. A filing also writes ONE
// staff_decisions row keyed 'staff:<fingerprint>' (UNIQUE escalation_key) in the
// same batch, and that insert only fires when the row now reads filed with this
// ticket_url, so a lost race writes no decision. When the UPDATE changes
// nothing, the row is read again: the same status and ticket_url is a replay
// and answers 200 existing:true; anything else is 409 not_claimed with the
// current status. A row of another agent is 409 wrong_agent. Every refusal
// writes nothing.

import { json, d1Guarded } from "../lib/http.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const FP_RE = /^[0-9a-f]{64}$/;
const OUTCOMES = ["digested", "filed", "refused", "unsupported", "failed"];
const MODES = ["ask", "auto"];
const ISSUE_RE = /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[0-9]+$/;
const CLASS_MAX = 200;
const RECOMMENDATION_MAX = 500;

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
// An optional trimmed text: undefined/null/blank is "not given" (""), a
// non-string or an over-long one is invalid (null).
const optText = (v, max) => {
  if (v === undefined || v === null) return "";
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length > max ? null : s;
};

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const findingOut = (r) => ({ id: r.id, agent: r.agent, status: r.status, ticket_url: r.ticket_url, updated_at: r.updated_at });
const readFinding = (env, fp) => env.DB.prepare(`SELECT * FROM staff_findings WHERE fingerprint=?1`).bind(fp).first();

export const routes = [
  // ── POST /api/staff/findings/record — record a tick's outcome on a claimed finding ─
  [
    "POST", "/api/staff/findings/record",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      const fp = typeof b.fingerprint === "string" ? b.fingerprint.trim().toLowerCase() : "";
      if (!FP_RE.test(fp)) return bad("fingerprint");
      const outcome = typeof b.outcome === "string" ? b.outcome.trim().toLowerCase() : "";
      if (!OUTCOMES.includes(outcome)) return bad("outcome");
      let ticketUrl = null;
      let mode = null;
      if (outcome === "filed") {
        ticketUrl = typeof b.ticket_url === "string" ? b.ticket_url.trim() : "";
        if (!ISSUE_RE.test(ticketUrl)) return bad("ticket_url");
        mode = typeof b.mode === "string" ? b.mode.trim().toLowerCase() : "";
        if (!MODES.includes(mode)) return bad("mode");
      }
      const cls = optText(b.class, CLASS_MAX);
      if (cls === null) return bad("class");
      const rec = optText(b.recommendation, RECOMMENDATION_MAX);
      if (rec === null) return bad("recommendation");

      return d1Guarded("staff_findings", async () => {
        const row = await readFinding(env, fp);
        if (!row) return json(404, { error: "finding not found" });
        if (row.agent !== name) return json(409, { error: "wrong_agent", agent: row.agent });

        const stmts = [
          env.DB.prepare(
            `UPDATE staff_findings SET status=?1, ticket_url=COALESCE(?2, ticket_url), updated_at=?3
              WHERE fingerprint=?4 AND agent=?5 AND status='claimed'`
          ).bind(outcome, ticketUrl, t, fp, name),
        ];
        if (outcome === "filed") {
          stmts.push(env.DB.prepare(
            `INSERT OR IGNORE INTO staff_decisions
               (agent, escalation_key, class, sensitive, recommendation, mode, counted, created_at)
             SELECT ?1, 'staff:' || ?2, ?3, 0, ?4, ?5, 0, ?6
              WHERE EXISTS (SELECT 1 FROM staff_findings
                             WHERE fingerprint=?2 AND agent=?1 AND status='filed' AND ticket_url=?7)`
          ).bind(name, fp, cls || row.source_kind, rec || row.title, mode, t, ticketUrl));
        }
        const res = await env.DB.batch(stmts);

        const now = await readFinding(env, fp);
        if (!now) return json(500, { error: "record_unresolved", fingerprint: fp });
        if (changesOf(res[0]) === 1) return json(200, { ok: true, finding: findingOut(now) });
        if (now.status === outcome && (now.ticket_url ?? null) === ticketUrl) {
          return json(200, { ok: true, existing: true, finding: findingOut(now) });
        }
        return json(409, { error: "not_claimed", status: now.status });
      });
    },
  ],
];

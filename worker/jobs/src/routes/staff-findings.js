// staff findings routes — BH-5560 (BH-5556.3): the findings ledger and
// suppressions (schema.sql, BH-5560 block).
//
// POST /api/staff/findings/claim is the dedup-before-spend gate. A staff agent
// claims a finding here BEFORE any filing or model call. The key is agent-core
// fingerprint(item), computed here and nowhere else, and staff_findings holds
// it UNIQUE across all agents: the same item twice gives one claim, and the
// second answers 409 already_claimed with the first row. A finding whose source
// is a staff-filed ticket (a `staff:<name>` label, or filedBy a staff agent on
// the roster) is 409 staff_filed before the ledger is touched: a lane's output
// is never its own input. The claim is ONE statement that also checks
// staff_suppressions, so a suppression and a claim cannot race: an active
// suppression whose expires_at is after now answers 409 suppressed. A
// suppression matches the item's own fingerprint OR its family, the
// familyFingerprint of (agent, classSlug(class, else source.kind)) from
// lib/staff-family.js, which is the key a noise proposal is made on. Every
// refusal writes nothing. A claim that wrote nothing and has no row to explain
// it is a 500 claim_unresolved, never a success.
//
// POST /api/staff/suppressions records a human-approved, expiring mute for one
// fingerprint, status 'active'. A 'pending' row (a noise proposal) never
// matches a claim until a human approves it. The approver is a human: archie or a staff
// agent name is 403 agent_approver. expiresAt is stored as YYYY-MM-DDTHH:MM:SSZ,
// the nowIso() shape, so the TEXT comparison in the claim is a time comparison.
// An expired suppression (expires_at at or before now) no longer matches.

import { json, d1Guarded } from "../lib/http.js";
import { fingerprint, canonicalUrl, isOwnOutput, validate } from "../../../../agent-core/src/index.js";
import { classSlug, familyFingerprint } from "../lib/staff-family.js";
import FINDING from "../../../../agent-core/schema/finding.schema.json" with { type: "json" };
import SUPPRESSION from "../../../../agent-core/schema/suppression.schema.json" with { type: "json" };

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const FP_RE = /^[0-9a-f]{64}$/;
const REASON_MAX = 500;

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
// THE staff label rule: `staff:<anything>`, trimmed and lowercased.
const isStaffLabel = (l) => typeof l === "string" && l.trim().toLowerCase().startsWith("staff:");
const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const findingOut = (r) => ({ id: r.id, agent: r.agent, status: r.status, claimed_at: r.claimed_at });
const suppressionOut = (r) => ({
  id: r.id, fingerprint: r.fingerprint, reason: r.reason, approver: r.approver,
  expires_at: r.expires_at, status: r.status, created_at: r.created_at,
});

const readFinding = (env, fp) => env.DB.prepare(`SELECT * FROM staff_findings WHERE fingerprint=?1`).bind(fp).first();
const activeSuppression = (env, fp, t, familyFp) => env.DB.prepare(
  `SELECT * FROM staff_suppressions WHERE fingerprint IN (?1, ?3) AND status='active' AND expires_at > ?2 ORDER BY expires_at DESC LIMIT 1`
).bind(fp, t, familyFp).first();
const rosterNames = async (env) => {
  const { results } = await env.DB.prepare(`SELECT name FROM staff_agents`).all();
  return (results || []).map((r) => r.name);
};

export const routes = [
  // ── POST /api/staff/findings/claim — claim a finding by fingerprint ────────
  [
    "POST", "/api/staff/findings/claim",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const name = agentOf(b.agent);
      if (name === null) return bad("agent");
      if (b.item === undefined || b.item === null) return bad("item");
      let fp;
      try { fp = fingerprint(b.item); } catch { return bad("item"); }

      const src = b.source;
      const source = src && typeof src === "object" && !Array.isArray(src)
        ? { ...src, ...(typeof src.url === "string" ? { url: canonicalUrl(src.url) } : {}) }
        : src;
      const finding = { agent: name, fingerprint: fp, title: b.title, source, observedAt: b.observedAt };
      const v = validate(FINDING, finding);
      if (!v.ok) return json(400, { error: "finding", errors: v.errors });
      const cls = typeof b.class === "string" && b.class.trim() !== "" ? b.class : source.kind;
      const familyFp = familyFingerprint(name, classSlug(cls));

      return d1Guarded("staff_findings", async () => {
        const agent = await env.DB.prepare(`SELECT name, status FROM staff_agents WHERE name=?1`).bind(name).first();
        if (!agent) return json(404, { error: "agent not found" });
        if (agent.status !== "active") return json(409, { error: "agent_not_active", status: agent.status });

        const roster = await rosterNames(env);
        if (source.labels.some(isStaffLabel) || roster.some((n) => isOwnOutput(finding, n))) {
          return json(409, { claimed: false, error: "staff_filed", fingerprint: fp });
        }

        // The claim and the suppression check are one statement.
        const res = await env.DB.prepare(
          `INSERT OR IGNORE INTO staff_findings
             (fingerprint, agent, title, source_kind, source_url, source_labels, source_filed_by,
              observed_at, status, claimed_at, updated_at)
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'claimed', ?9, ?9
            WHERE NOT EXISTS (SELECT 1 FROM staff_suppressions
                               WHERE fingerprint IN (?1, ?10) AND status = 'active' AND expires_at > ?9)`
        ).bind(
          fp, name, finding.title, source.kind, source.url, JSON.stringify(source.labels),
          typeof source.filedBy === "string" ? source.filedBy : null, finding.observedAt, t, familyFp,
        ).run();

        if (changesOf(res) === 1) {
          const row = await readFinding(env, fp);
          if (!row) return json(500, { error: "claim_unresolved", fingerprint: fp });
          return json(200, { claimed: true, fingerprint: fp, finding: findingOut(row) });
        }
        const s = await activeSuppression(env, fp, t, familyFp);
        if (s) {
          return json(409, {
            claimed: false, error: "suppressed", fingerprint: fp,
            suppression: { id: s.id, reason: s.reason, approver: s.approver, expires_at: s.expires_at },
          });
        }
        const existing = await readFinding(env, fp);
        if (existing) {
          return json(409, { claimed: false, error: "already_claimed", fingerprint: fp, finding: findingOut(existing) });
        }
        return json(500, { error: "claim_unresolved", fingerprint: fp });
      });
    },
  ],

  // ── POST /api/staff/suppressions — a human mutes one fingerprint until expiry ─
  [
    "POST", "/api/staff/suppressions",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const fp = typeof b.fingerprint === "string" ? b.fingerprint.trim().toLowerCase() : "";
      if (!FP_RE.test(fp)) return bad("fingerprint");
      const reason = typeof b.reason === "string" ? b.reason.trim() : "";
      if (reason.length < 1 || reason.length > REASON_MAX) return bad("reason");
      const approver = typeof b.approver === "string" ? b.approver.trim() : "";
      if (approver.length < 1 || approver.length > 64) return bad("approver");
      const ms = typeof b.expiresAt === "string" ? Date.parse(b.expiresAt) : NaN;
      if (!Number.isFinite(ms)) return bad("expiresAt");
      const expiresAt = isoSeconds(ms);
      if (!(expiresAt > t)) return bad("expiresAt_past");
      const v = validate(SUPPRESSION, { fingerprint: fp, reason, approver, expiresAt });
      if (!v.ok) return json(400, { error: "suppression", errors: v.errors });

      return d1Guarded("staff_suppressions", async () => {
        const a = approver.toLowerCase();
        const isAgent = a === "archie" || (await rosterNames(env)).includes(a);
        if (isAgent) return json(403, { error: "agent_approver" });

        const res = await env.DB.prepare(
          `INSERT OR IGNORE INTO staff_suppressions (fingerprint, reason, approver, expires_at, status, created_at)
           VALUES (?1, ?2, ?3, ?4, 'active', ?5)`
        ).bind(fp, reason, approver, expiresAt, t).run();
        const row = await env.DB.prepare(
          `SELECT * FROM staff_suppressions WHERE fingerprint=?1 AND approver=?2 AND expires_at=?3`
        ).bind(fp, approver, expiresAt).first();
        if (!row) return json(500, { error: "suppression_unresolved", fingerprint: fp });
        if (changesOf(res) === 1) return json(200, { ok: true, suppression: suppressionOut(row) });
        return json(200, { ok: true, existing: true, suppression: suppressionOut(row) });
      });
    },
  ],
];

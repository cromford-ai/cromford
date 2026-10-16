// route-rules routes — P4: plan-driven model routing, SHADOW MODE.
//
// Three families on three tables (worker/jobs/schema.sql, the P4 block):
//   /api/route-rules, /api/route-rule-changes   the rules and their audit
//   /api/route-shadow, /api/route-shadow/bounce the per-build shadow record, and
//                                               the measured first-review BLOCK
//                                               share the escalation rule reads
//
// SHADOW ONLY, BY CONSTRUCTION. `mode` accepts 'shadow' and 'off' and nothing
// else — a PUT asking for 'live' is a 400 — so no row this route can write is a
// live routing decision. bin/lib/route-rules.sh reads the rules only to write a
// route_shadow row; run-build never reads its answer.
//
// THE WRITE IS THE model_routes WRITE (docs/MODEL-ROUTES.md): a WHOLE-ROW PUT,
// an optional `expected_version` checked at read time AND as the first
// statement of the batch (so a write that lands between the two is still a
// 409), one append-only audit row per decision, and an identical re-PUT that
// writes nothing. A rule names a model_routes ROLE, which must resolve on the
// hub at write time, never a model id.
import { d1Guarded, json } from "../lib/http.js";
import { MODEL_ROUTE_PROJECT_RE, MODEL_ROUTE_ROLE_RE, ensureTable, resolveModelLadder } from "../lib/core.js";

// The plan features bin/lib/route-rules.sh derives (route_features). A match
// may name only these; an unknown name is refused rather than silently false.
export const ROUTE_FEATURES = [
  "plan_present", "u0", "invariant_bearing", "risk_surface", "docs_only", "fully_specified", "size_declared",
];
export const ROUTE_EFFECTS = ["route", "bump"];
export const ROUTE_MODES = ["shadow", "off"];
export const ROUTE_TIERS = ["T0", "T1", "T2"];
export const ROUTE_TEST_SCOPES = ["minimal", "impact", "full"];
const KINDS = ["bug", "feature", "copy", "migration", "infra", "unknown"];
const MAX_CHANGES = 500;

// A match object is validated key by key; its canonical form (keys sorted) is
// what is stored, so two PUTs that differ only in key order are one decision.
function normalizeMatch(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "match must be a JSON object" };
  const out = {};
  for (const k of Object.keys(raw).sort()) {
    const v = raw[k];
    switch (k) {
      case "any": case "all": case "none":
        if (!Array.isArray(v) || v.length === 0 || v.some((f) => !ROUTE_FEATURES.includes(f))) {
          return { error: `match.${k} must be a non-empty list of: ${ROUTE_FEATURES.join(", ")}` };
        }
        out[k] = [...new Set(v)];
        break;
      case "kind":
        if (!Array.isArray(v) || v.length === 0 || v.some((x) => !KINDS.includes(x))) {
          return { error: `match.kind must be a non-empty list of: ${KINDS.join(", ")}` };
        }
        out[k] = [...new Set(v)];
        break;
      case "planned_tier":
        if (!Array.isArray(v) || v.length === 0 || v.some((x) => !ROUTE_TIERS.includes(x))) {
          return { error: `match.planned_tier must be a non-empty list of: ${ROUTE_TIERS.join(", ")}` };
        }
        out[k] = [...new Set(v)];
        break;
      case "max_lines": case "min_reviews":
        if (!Number.isInteger(v) || v < 0 || v > 1000000) return { error: `match.${k} must be a non-negative integer` };
        out[k] = v;
        break;
      case "days":
        if (!Number.isInteger(v) || v < 1 || v > 365) return { error: "match.days must be an integer 1..365" };
        out[k] = v;
        break;
      case "bounce_rate_gt":
        if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 1) return { error: "match.bounce_rate_gt must be a number 0..1" };
        out[k] = v;
        break;
      default:
        return { error: `match: unknown key '${k}'` };
    }
  }
  return { match: out };
}

const intIn = (v, lo, hi) => (Number.isInteger(v) && v >= lo && v <= hi ? v : null);
const optEnum = (v, set) => (v === undefined || v === null || v === "" ? { ok: true, v: null } : set.includes(v) ? { ok: true, v } : { ok: false });

// Keys sorted, so a seeded match written in another key order compares equal to
// the same conditions sent back by a PUT.
const canon = (o) => (o && typeof o === "object" && !Array.isArray(o)
  ? Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]])) : o);
// The row a PUT writes, and the shape an audit row carries (before/after).
const auditShape = (r) => r && ({
  name: r.name, priority: r.priority, effect: r.effect, mode: r.mode,
  match: canon(typeof r.match_json === "string" ? parseJson(r.match_json) : r.match),
  execute_role: r.execute_role ?? null, review_tier: r.review_tier ?? null,
  test_scope: r.test_scope ?? null, tier_bump: r.tier_bump ?? 0, note: r.note ?? null,
});
const same = (a, b) => JSON.stringify(auditShape(a)) === JSON.stringify(auditShape(b));
const present = (r) => {
  let match = null;
  try { match = JSON.parse(r.match_json); } catch { match = null; }
  return { ...r, match };
};
const parseJson = (s) => { try { return s == null ? null : JSON.parse(s); } catch { return null; } };
const isStaleGuard = (e) => /malformed JSON/i.test(String((e && e.message) || e));

export const routes = [
  // ── the rules, every one, in priority order ─────────────────────────────
  [
    "GET", "/api/route-rules",
    async ({ env, t }) => d1Guarded("route_rules", async () => {
      await ensureTable(env, "route_rules");
      const rows = await env.DB.prepare("SELECT * FROM route_rules ORDER BY priority ASC, name ASC").all();
      return json(200, {
        rules: (rows.results || []).map(present),
        features: ROUTE_FEATURES, effects: ROUTE_EFFECTS, modes: ROUTE_MODES,
        tiers: ROUTE_TIERS, test_scopes: ROUTE_TEST_SCOPES, as_of: t,
      });
    }),
  ],

  // ── PUT one rule, whole row ──────────────────────────────────────────────
  [
    "PUT", "/api/route-rules",
    async ({ env, t, body }) => d1Guarded("route_rules", async () => {
      await ensureTable(env, "route_rules");
      await ensureTable(env, "route_rule_changes");
      const name = typeof body.name === "string" ? body.name.trim() : "";
      if (!name || name.length > 64 || !MODEL_ROUTE_ROLE_RE.test(name)) {
        return json(400, { error: "name must match ^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$, <= 64 chars" });
      }
      const priority = intIn(body.priority, 0, 100000);
      if (priority === null) return json(400, { error: "priority must be an integer 0..100000" });
      if (!ROUTE_EFFECTS.includes(body.effect)) return json(400, { error: `effect must be one of ${ROUTE_EFFECTS.join(", ")}` });
      if (body.mode === "live") {
        return json(400, { error: "P4 is shadow-only: mode must be shadow or off (a live mode is a later ticket, decided on route_shadow evidence)" });
      }
      if (!ROUTE_MODES.includes(body.mode)) return json(400, { error: `mode must be one of ${ROUTE_MODES.join(", ")} (P4 is shadow-only)` });
      const m = normalizeMatch(body.match);
      if (m.error) return json(400, { error: m.error });
      const tier = optEnum(body.review_tier, ROUTE_TIERS);
      if (!tier.ok) return json(400, { error: `review_tier must be one of ${ROUTE_TIERS.join(", ")} or null` });
      const scope = optEnum(body.test_scope, ROUTE_TEST_SCOPES);
      if (!scope.ok) return json(400, { error: `test_scope must be one of ${ROUTE_TEST_SCOPES.join(", ")} or null` });
      const bump = body.tier_bump === undefined || body.tier_bump === null ? 0 : intIn(body.tier_bump, 0, 2);
      if (bump === null) return json(400, { error: "tier_bump must be an integer 0..2" });

      // The execute role must be a model_routes role the HUB resolves today: a
      // rule that names a model id, or a role nobody routed, would record a
      // would-be model nobody could ever run.
      let role = body.execute_role === undefined || body.execute_role === "" ? null : body.execute_role;
      if (role === null && body.effect === "route") return json(400, { error: "execute_role is required on a route rule (a model_routes role)" });
      if (role !== null) {
        if (typeof role !== "string" || role.length > 128 || !MODEL_ROUTE_ROLE_RE.test(role)) {
          return json(400, { error: "execute_role must be a model_routes role name" });
        }
        await ensureTable(env, "model_routes");
        const { ladder } = await resolveModelLadder(env, role, null);
        if (!ladder || ladder.length === 0) {
          return json(400, { error: `execute_role '${role}' has no hub ladder in model_routes — name a routed role, never a model id` });
        }
      }
      const note = body.note === undefined || body.note === null ? null : String(body.note).slice(0, 512);
      const actor = body.actor ? String(body.actor).slice(0, 128) : "api";
      const reason = body.reason ? String(body.reason).slice(0, 512) : null;
      let expected = null;
      if (body.expected_version !== undefined && body.expected_version !== null) {
        expected = Number(body.expected_version);
        if (!Number.isInteger(expected) || expected < 0) {
          return json(400, { error: "expected_version must be a non-negative integer (the version you read; 0 = the rule does not exist yet)" });
        }
      }

      const before = await env.DB.prepare("SELECT * FROM route_rules WHERE name=?1").bind(name).first();
      const curVersion = before ? Number(before.version) : 0;
      if (expected !== null && expected !== curVersion) {
        return json(409, { error: "this rule changed since you loaded it — reload and edit again", version: curVersion });
      }
      const next = {
        name, priority, effect: body.effect, mode: body.mode, match_json: JSON.stringify(m.match),
        execute_role: role, review_tier: tier.v, test_scope: scope.v, tier_bump: bump, note,
      };
      if (before && same(before, next) && body.confirm !== true) {
        return json(200, { rule: present(before), changed: false });
      }
      const newVersion = curVersion + 1;
      const stmts = [];
      if (expected !== null) {
        // json('stale') raises "malformed JSON", which rolls the batch back.
        stmts.push(env.DB.prepare(
          "SELECT json(CASE WHEN coalesce((SELECT version FROM route_rules WHERE name=?1),0)=?2 THEN '1' ELSE 'stale' END) AS ok"
        ).bind(name, expected));
      }
      stmts.push(env.DB.prepare(
        `INSERT INTO route_rules (name, priority, effect, mode, match_json, execute_role, review_tier, test_scope, tier_bump, note, version, updated_by, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
         ON CONFLICT(name) DO UPDATE SET priority=?2, effect=?3, mode=?4, match_json=?5, execute_role=?6,
           review_tier=?7, test_scope=?8, tier_bump=?9, note=?10, version=?11, updated_by=?12, updated_at=?13`
      ).bind(name, priority, next.effect, next.mode, next.match_json, role, tier.v, scope.v, bump, note, newVersion, actor, t));
      stmts.push(env.DB.prepare(
        "INSERT INTO route_rule_changes (name, before_json, after_json, actor, reason, at) VALUES (?1,?2,?3,?4,?5,?6)"
      ).bind(name, before ? JSON.stringify(auditShape(before)) : null, JSON.stringify(auditShape(next)), actor, reason, t));
      try {
        await env.DB.batch(stmts);
      } catch (e) {
        if (!isStaleGuard(e)) throw e;
        const now = await env.DB.prepare("SELECT version FROM route_rules WHERE name=?1").bind(name).first();
        return json(409, { error: "this rule changed since you loaded it — reload and edit again", version: now ? Number(now.version) : 0 });
      }
      const row = await env.DB.prepare("SELECT * FROM route_rules WHERE name=?1").bind(name).first();
      return json(200, { rule: present(row), changed: true });
    }),
  ],

  // ── the audit trail, newest first ────────────────────────────────────────
  [
    "GET", "/api/route-rule-changes",
    async ({ env, url, t }) => d1Guarded("route_rule_changes", async () => {
      await ensureTable(env, "route_rule_changes");
      const name = url.searchParams.get("name");
      const limRaw = Number(url.searchParams.get("limit") || 100);
      const limit = Number.isInteger(limRaw) && limRaw > 0 ? Math.min(limRaw, MAX_CHANGES) : 100;
      const rows = name
        ? await env.DB.prepare("SELECT * FROM route_rule_changes WHERE name=?1 ORDER BY id DESC LIMIT ?2").bind(name, limit + 1).all()
        : await env.DB.prepare("SELECT * FROM route_rule_changes ORDER BY id DESC LIMIT ?1").bind(limit + 1).all();
      const all = rows.results || [];
      const changes = all.slice(0, limit).map((r) => ({
        id: r.id, name: r.name, before: parseJson(r.before_json), after: parseJson(r.after_json),
        actor: r.actor, reason: r.reason, at: r.at,
      }));
      return json(200, { changes, truncated: all.length > limit, as_of: t });
    }),
  ],

  // ── the measured first-review BLOCK share (the escalation rule's input) ──
  // First verdict per build job (verdict_history, joined to jobs for the
  // project) inside the window. With ?rule=, only the jobs whose shadow row
  // named that rule: the unit CLASS's bounce rate. No reviews is rate null,
  // never 0 — "not measured" and "never bounced" are different facts.
  [
    "GET", "/api/route-shadow/bounce",
    async ({ env, url, t }) => d1Guarded("route_shadow", async () => {
      await ensureTable(env, "route_shadow");
      const project = url.searchParams.get("project") || "";
      if (!MODEL_ROUTE_PROJECT_RE.test(project)) return json(400, { error: "project required (a fleet.conf project name)" });
      const rule = url.searchParams.get("rule");
      if (rule !== null && (rule.length > 64 || !MODEL_ROUTE_ROLE_RE.test(rule))) return json(400, { error: "rule must be a rule name" });
      const dRaw = Number(url.searchParams.get("days") || 30);
      const days = Number.isInteger(dRaw) && dRaw >= 1 && dRaw <= 365 ? dRaw : 30;
      const since = new Date(Date.parse(t) - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      const byRule = rule !== null ? "AND vh.job_id IN (SELECT s.job_id FROM route_shadow s WHERE s.project=?1 AND s.rule=?3)" : "";
      // sql-ident-ok: byRule is a literal subquery or empty; rule binds as ?3
      const row = await env.DB.prepare(
        `SELECT count(*) AS reviewed, coalesce(sum(CASE WHEN vh.verdict='BLOCK' THEN 1 ELSE 0 END),0) AS blocked
           FROM verdict_history vh JOIN jobs j ON j.id = vh.job_id
          WHERE j.project=?1 AND vh.created_at >= ?2
            AND vh.id = (SELECT min(v2.id) FROM verdict_history v2 WHERE v2.job_id = vh.job_id)
            ${byRule}`
      ).bind(...(rule !== null ? [project, since, rule] : [project, since])).first();
      const reviewed = Number(row && row.reviewed) || 0;
      const blocked = Number(row && row.blocked) || 0;
      return json(200, { project, rule, days, since, reviewed, blocked, rate: reviewed > 0 ? blocked / reviewed : null, as_of: t });
    }),
  ],

  // ── record one build's shadow decision (idempotent on the build dir) ────
  [
    "POST", "/api/route-shadow",
    async ({ env, t, body }) => d1Guarded("route_shadow", async () => {
      await ensureTable(env, "route_shadow");
      const s = (v, n) => (v === undefined || v === null ? null : String(v).slice(0, n));
      const build = typeof body.build === "string" ? body.build.trim() : "";
      if (!build || build.length > 200 || !/^[A-Za-z0-9._-]+$/.test(build)) return json(400, { error: "build must be the build dir's basename" });
      const project = typeof body.project === "string" ? body.project.trim() : "";
      if (!MODEL_ROUTE_PROJECT_RE.test(project)) return json(400, { error: "project required (a fleet.conf project name)" });
      const would = s(body.would_execute_model, 256);
      const actual = s(body.actual_execute_model, 256);
      const differs = would && actual && would !== actual ? 1 : 0;
      let features = null;
      if (body.features && typeof body.features === "object") features = JSON.stringify(body.features).slice(0, 4000);
      const r = await env.DB.prepare(
        `INSERT OR IGNORE INTO route_shadow (build, job_id, project, ticket_key, rule, bumped, would_execute_role,
           would_execute_model, actual_execute_model, would_review_tier, planned_review_tier, review_model,
           would_test_scope, differs, features_json, box, at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)`
      ).bind(build, s(body.job_id, 200), project, s(body.ticket_key, 64), s(body.rule, 64) ?? "", s(body.bumped, 256) ?? "",
        s(body.would_execute_role, 128), would, actual, s(body.would_review_tier, 4), s(body.planned_review_tier, 4),
        s(body.review_model, 256), s(body.would_test_scope, 16), differs, features, s(body.box, 128), t).run();
      return json(200, { recorded: Number(r && r.meta && r.meta.changes) === 1, differs, as_of: t });
    }),
  ],

  // ── read the shadow rows (the nightly report's source) ──────────────────
  [
    "GET", "/api/route-shadow",
    async ({ env, url, t }) => d1Guarded("route_shadow", async () => {
      await ensureTable(env, "route_shadow");
      const since = url.searchParams.get("since")
        || new Date(Date.parse(t) - 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(since)) return json(400, { error: "since must be an ISO-8601 UTC second (YYYY-MM-DDTHH:MM:SSZ)" });
      const project = url.searchParams.get("project");
      if (project !== null && !MODEL_ROUTE_PROJECT_RE.test(project)) return json(400, { error: "project must be a fleet.conf project name" });
      const lRaw = Number(url.searchParams.get("limit") || 500);
      const limit = Number.isInteger(lRaw) && lRaw > 0 ? Math.min(lRaw, 2000) : 500;
      const rows = project !== null
        ? await env.DB.prepare("SELECT * FROM route_shadow WHERE at >= ?1 AND project=?2 ORDER BY id ASC LIMIT ?3").bind(since, project, limit + 1).all()
        : await env.DB.prepare("SELECT * FROM route_shadow WHERE at >= ?1 ORDER BY id ASC LIMIT ?2").bind(since, limit + 1).all();
      const all = rows.results || [];
      const out = all.slice(0, limit).map((r) => {
        const { features_json: fj, ...rest } = r;
        return { ...rest, features: parseJson(fj) };
      });
      return json(200, { since, project, rows: out, truncated: all.length > limit, as_of: t });
    }),
  ],
];

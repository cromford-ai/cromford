// AI accounts — the rows an operator adds from the console, and the status of
// the envelope that carries each token (BH-7966, BH-7937.2). The token is never
// here: the console seals it to the hub key and stores only that ciphertext as
// a BH-7964 envelope (secret-envelopes.js). A row names the envelope; its state
// is the newest secret_envelope_events row for that envelope, never a column.
// Note: docs/notes/2026-10-23-BH-7966-ai-accounts.md.
//
// GET  /api/ai-accounts                     ONE batch of 5 reads, joined here:
//   {accounts:[{id,vendor,label,plan,use_kind,created_by,created_at,revoked_at,
//   projects,today,boxes,state}], limit, truncated}. Cap: settings
//   ai_accounts_list_limit (1..5000, else 500).
// POST /api/ai-accounts {vendor,label,plan,use_kind,envelope_id,created_by}
//   400 on a bad field or an envelope whose `stored` scope is not exactly
//   ai-account:<vendor>:<label>:<use_kind>[:<project> for project]; 409 when the
//   (vendor,label) exists, revoked or not. 200 {id, state:'pending'}.
// POST /api/ai-accounts/:id/revoke          stamps revoked_at once; a repeat is
//   200 {already:true}; no row is 404. The row is never deleted.
// GET  /api/secrets/envelope/:id/status     {state} from the newest event:
//   pending | consumed | applied | apply_failed | expired. 404 with no event.
//
// No error text here repeats a label, a scope or a token.
import { d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const VENDORS = ["claude", "codex", "openrouter", "fireworks", "xai"];
const USE_KINDS = ["project", "pool", "fallback"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// The hub consumer's label rule (PR #8149 bin/lib/envelope.sh _pacct_label_ok).
const LABEL_RE = /^[a-z0-9._@-]{1,48}$/;
const TOKEN_PREFIX_RE = /^(sk-|sk_|xai-|fw_|or-)/i;
const CREATED_BY_RE = /^console:[A-Za-z0-9._@+-]{1,120}$/;
// Fallback of the settings row ai_accounts_list_limit (schema.d …-bh-7966-ai-accounts.sql).
const LIST_LIMIT_DEFAULT = 500;
const LIST_LIMIT_MAX = 5000;
const PLAN_MAX = 64;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

// The five reads of GET, exported for the EXPLAIN test.
// settings PK range, plus the one knob row.
export const ACCOUNT_SETTINGS_SQL =
  "SELECT key, value FROM settings WHERE (key >= 'account.' AND key < 'account/') OR key = 'ai_accounts_list_limit'";
// ux_ai_accounts_vendor_label serves the ORDER BY. The literal 500 is the
// documented fallback of the ai_accounts_list_limit row.
export const LIST_SQL =
  "SELECT id, vendor, label, plan, use_kind, envelope_id, created_by, created_at, revoked_at FROM ai_accounts ORDER BY vendor, label "
  + `LIMIT COALESCE((SELECT CAST(value AS INTEGER) FROM settings WHERE key='ai_accounts_list_limit' AND CAST(value AS INTEGER) BETWEEN 1 AND ${LIST_LIMIT_MAX}), ${LIST_LIMIT_DEFAULT})`;
// ix_secret_envelope_events_env per account. The newest event is folded in JS.
export const LIST_EVENTS_SQL =
  "SELECT a.envelope_id, e.id, e.event FROM ai_accounts a JOIN secret_envelope_events e ON e.envelope_id = a.envelope_id "
  + "WHERE a.revoked_at IS NULL AND a.envelope_id IS NOT NULL";
// ?1 today 00:00Z. idx_cost_rows_ts / idx_cost_rows_account. The only cost read here.
export const TODAY_COST_SQL =
  "SELECT auth_account, SUM(cost_usd) AS usd FROM cost_rows WHERE ts >= ?1 AND auth_account IN (SELECT label FROM ai_accounts) GROUP BY auth_account";
// registry_box_accounts PK (account, kind, box).
export const BOXES_SQL =
  "SELECT account, COUNT(DISTINCT box) AS n FROM registry_box_accounts WHERE kind = 'login' AND account IN (SELECT label FROM ai_accounts) GROUP BY account";
// ?1 envelope id. ix_secret_envelope_events_env.
export const NEWEST_EVENT_SQL =
  "SELECT event FROM secret_envelope_events WHERE envelope_id = ?1 ORDER BY id DESC LIMIT 1";
// ?1 envelope id. The `stored` event outlives the envelope row a hub read deletes.
export const STORED_SCOPE_SQL =
  "SELECT scope FROM secret_envelope_events WHERE envelope_id = ?1 AND event = 'stored' LIMIT 1";

// checkAiAccountLabel(raw) -> {ok:true, value} | {ok:false, message}. The
// message never contains the value.
export function checkAiAccountLabel(raw) {
  const value = typeof raw === "string" ? raw : "";
  if (!value.trim()) return { ok: false, message: "type an account label" };
  if (TOKEN_PREFIX_RE.test(value.trim())) {
    return { ok: false, message: "that looks like a token: an account is named by a label, and the token goes in the token field" };
  }
  if (value === "shared") return { ok: false, message: "that label is reserved for the fleet pool: pick another label" };
  if (!LABEL_RE.test(value) || value.includes("..") || value.startsWith(".")) {
    return { ok: false, message: "a label is lower-case letters, digits and . _ @ - (at most 48), with no .. and no leading ." };
  }
  return { ok: true, value };
}

// The list state of one account (decision rule 3): a revoke wins, then the
// newest event. No event at all is `unknown`, never a guess.
export function accountStateFrom(event, revokedAt) {
  if (revokedAt) return "revoked";
  if (event === "stored" || event === "consumed") return "pending";
  if (event === "applied") return "active";
  if (event === "apply_failed") return "failed";
  if (event === "expired") return "expired";
  return "unknown";
}

// The status route's word for the newest event.
const STATUS_OF = { stored: "pending", consumed: "consumed", applied: "applied", apply_failed: "apply_failed", expired: "expired" };

export const todayStartZ = (t) => `${String(t).slice(0, 10)}T00:00:00Z`;

// The same rule LIST_SQL applies in SQL, so `limit` in the answer is the cap
// that cut the rows.
function listLimitFrom(value) {
  const s = String(value ?? "").trim();
  if (!/^\d+$/.test(s)) return LIST_LIMIT_DEFAULT;
  const n = Number(s);
  return n >= 1 && n <= LIST_LIMIT_MAX ? n : LIST_LIMIT_DEFAULT;
}

async function ensureTables(env) {
  await ensureTable(env, "ai_accounts");
  await ensureTable(env, "secret_envelopes");
  await ensureTable(env, "secret_envelope_events");
}

// The scope must be exactly what accountScope() in the console writes for this
// row: a project segment for use kind `project`, none for the others.
function scopeMatches(scope, { vendor, label, use_kind }) {
  if (typeof scope !== "string") return false;
  const head = `ai-account:${vendor}:${label}:${use_kind}`;
  if (use_kind === "project") return scope.startsWith(head + ":") && scope.length > head.length + 1;
  return scope === head;
}

export const routes = [
  [
    "GET", "/api/ai-accounts",
    ({ env, t }) => d1Guarded("ai_accounts", async () => {
      await ensureTables(env);
      const db = env.DB;
      const [settingsRes, listRes, eventsRes, costRes, boxRes] = await db.batch([
        db.prepare(ACCOUNT_SETTINGS_SQL),
        db.prepare(LIST_SQL),
        db.prepare(LIST_EVENTS_SQL),
        db.prepare(TODAY_COST_SQL).bind(todayStartZ(t)),
        db.prepare(BOXES_SQL),
      ]);
      const settings = settingsRes.results || [];
      const limit = listLimitFrom(settings.find((r) => r.key === "ai_accounts_list_limit")?.value);
      const projectsOf = new Map();
      for (const r of settings) {
        if (!r.key.startsWith("account.")) continue;
        const list = projectsOf.get(r.value) || [];
        list.push(r.key.slice("account.".length));
        projectsOf.set(r.value, list);
      }
      const newest = new Map();
      for (const e of eventsRes.results || []) {
        const cur = newest.get(e.envelope_id);
        if (!cur || e.id > cur.id) newest.set(e.envelope_id, e);
      }
      const usd = new Map((costRes.results || []).map((r) => [r.auth_account, Number(r.usd) || 0]));
      const boxes = new Map((boxRes.results || []).map((r) => [r.account, Number(r.n)]));
      const accounts = (listRes.results || []).map((a) => ({
        id: a.id,
        vendor: a.vendor,
        label: a.label,
        plan: a.plan,
        use_kind: a.use_kind,
        created_by: a.created_by,
        created_at: a.created_at,
        revoked_at: a.revoked_at,
        projects: [...(projectsOf.get(a.label) || [])].sort(),
        // The cost table was read, so a label with no row today spent 0.
        today: usd.get(a.label) ?? 0,
        // No registry row: unknown, not zero.
        boxes: boxes.has(a.label) ? boxes.get(a.label) : null,
        state: accountStateFrom(newest.get(a.envelope_id)?.event ?? null, a.revoked_at),
      }));
      return noStore(200, { accounts, limit, truncated: accounts.length === limit });
    }),
  ],
  [
    "POST", "/api/ai-accounts",
    ({ env, t, body }) => d1Guarded("ai_accounts", async () => {
      const { vendor, label, plan, use_kind, envelope_id, created_by } = body || {};
      if (!VENDORS.includes(vendor)) return noStore(400, { error: `vendor must be one of ${VENDORS.join(", ")}` });
      if (!USE_KINDS.includes(use_kind)) return noStore(400, { error: `use_kind must be one of ${USE_KINDS.join(", ")}` });
      const lc = checkAiAccountLabel(label);
      if (!lc.ok) return noStore(400, { error: lc.message });
      if (plan !== undefined && plan !== null && (typeof plan !== "string" || plan.length > PLAN_MAX)) {
        return noStore(400, { error: `plan must be text of at most ${PLAN_MAX} chars` });
      }
      if (typeof envelope_id !== "string" || !UUID_RE.test(envelope_id)) return noStore(400, { error: "no such envelope" });
      await ensureTables(env);
      const scope = await env.DB.prepare(STORED_SCOPE_SQL).bind(envelope_id).first("scope");
      if (scope === null || scope === undefined) return noStore(400, { error: "no such envelope" });
      if (!scopeMatches(scope, { vendor, label, use_kind })) {
        return noStore(400, { error: "the envelope was sealed for another vendor, label or use kind" });
      }
      const id = crypto.randomUUID();
      const by = typeof created_by === "string" && CREATED_BY_RE.test(created_by) ? created_by : "api";
      const res = await env.DB.prepare(
        "INSERT INTO ai_accounts (id, vendor, label, plan, use_kind, envelope_id, created_by, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) "
        + "ON CONFLICT(vendor, label) DO NOTHING",
      ).bind(id, vendor, label, plan ? plan : null, use_kind, envelope_id, by, t).run();
      if (!res.meta || res.meta.changes !== 1) {
        return noStore(409, { error: "that label is taken on this vendor (revoked labels too): pick a new label" });
      }
      return noStore(200, { id, state: "pending" });
    }),
  ],
  [
    "POST", /^\/api\/ai-accounts\/([0-9a-f-]{36})\/revoke$/,
    ({ env, t, m }) => d1Guarded("ai_accounts", async () => {
      await ensureTables(env);
      const id = m[1];
      const res = await env.DB.prepare("UPDATE ai_accounts SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL").bind(id, t).run();
      if (res.meta && res.meta.changes === 1) return noStore(200, { revoked_at: t });
      const row = await env.DB.prepare("SELECT revoked_at FROM ai_accounts WHERE id = ?1").bind(id).first();
      if (!row) return noStore(404, { error: "no such account" });
      return noStore(200, { already: true, revoked_at: row.revoked_at });
    }),
  ],
  [
    "GET", /^\/api\/secrets\/envelope\/([0-9a-f-]{36})\/status$/,
    ({ env, t, m }) => d1Guarded("secret_envelopes", async () => {
      await ensureTables(env);
      const id = m[1];
      const [ev, row] = await env.DB.batch([
        env.DB.prepare(NEWEST_EVENT_SQL).bind(id),
        env.DB.prepare("SELECT expires_at FROM secret_envelopes WHERE id = ?1").bind(id),
      ]);
      const event = ev.results?.[0]?.event;
      if (!event) return noStore(404, { error: "no envelope" });
      const expiresAt = row.results?.[0]?.expires_at;
      // A stored envelope nobody read before its expiry is expired, even
      // before a read or the sweep writes the `expired` event.
      if (event === "stored" && expiresAt && expiresAt <= t) return noStore(200, { state: "expired" });
      return noStore(200, { state: STATUS_OF[event] || "unknown" });
    }),
  ],
];

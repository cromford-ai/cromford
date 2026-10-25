// web-vault routes — the encrypted credential store of the web-task lane
// (BH-7595, slice C0 of the web-task S2 plan). Contract and operator steps:
// docs/notes/2026-10-19-BH-7595-web-vault.md. Tables:
// schema.d/202610200735-bh-7595-web-vault.sql. Crypto: lib/web-vault-crypto.js.
//
// Every route is behind the bearer (HARNESS_SECRET). Every lane-run machine
// holds that bearer, so it cannot mean "operator": set, entries and audit also
// need x-web-vault-admin-token equal to the Worker secret WEB_VAULT_ADMIN_TOKEN,
// which lives in the hub env only. Unset on the worker is 403 on all three.
//
// POST /api/web-vault/set {project, site, field, value}   operator
//   400 on a bad field, nothing written. Key missing: 503, one audit row
//   refused:key_missing, no vault row. Else ONE batch: the upsert on
//   uq_web_vault_entry and one audit row. 200 {stored, project, site, field,
//   key_id, updated_at}. The answer never holds the value.
// POST /api/web-vault/read {project, site, field, run_id, machine}   a lane-run machine
//   Header x-web-vault-run-token: the run token the claim answer gave for that
//   run (vault_token). run_id and machine are public (GET /api/lane-runs lists
//   them), so the token is what binds a read to the machine that claimed the
//   run. Four parallel reads (the lane_runs row by PK, the token row by PK, the
//   settings, the vault row on uq_web_vault_entry), then the first failing
//   check wins: no_run, wrong_lane, not_claimed, not_claimer, bad_token,
//   lease_expired, wrong_project, site_not_allowed, no_entry, key_missing,
//   decrypt_failed. Every outcome
//   writes ONE audit row. An ok read writes the audit row and last_used_at in
//   ONE batch and only then answers {value}; a failed batch is a 503 with no value.
// GET /api/web-vault/entries?project=&site=&stale=1&limit=   operator, metadata only
//
// THE RUN TOKEN. POST /api/lane-runs/claim calls mintRunToken for a claimed
// web-task row: 32 random bytes, base64url, in the claim answer only; D1 keeps
// its SHA-256 in web_vault_run_token, keyed by run id. Enqueueing a web-task
// run (POST /api/lane-runs and /api/lane-runs/batch) needs the operator token
// (webTaskEnqueueRefused), so a bearer holder cannot make a run of any project
// and claim it to get a token.
// GET /api/web-vault/audit?project=&site=&limit=             operator, newest first
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { decryptValue, encryptValue, vaultAad } from "../lib/web-vault-crypto.js";

export const WEB_TASK_LANE = "web-task";
const SITE_RE = /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/;
const FIELD_RE = /^[a-z0-9_.-]{1,64}$/;
const VALUE_MAX_BYTES = 4096;
const DAY_MS = 86400e3;
const ENTRY_COLS = "project, site, field, key_id, created_at, updated_at, last_used_at";
const AUDIT_COLS = "id, at, action, outcome, project, site, field, actor, run_id, key_id";

// ?1 project, ?2 site, ?3 field, ?4 ciphertext, ?5 iv, ?6 key_id, ?7 t. uq_web_vault_entry.
export const UPSERT_SQL = `INSERT INTO web_vault (project, site, field, ciphertext, iv, key_id, created_at, updated_at, last_used_at)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7)
 ON CONFLICT(project, site, field) DO UPDATE SET
   ciphertext=excluded.ciphertext, iv=excluded.iv, key_id=excluded.key_id,
   updated_at=excluded.updated_at, last_used_at=excluded.last_used_at`;
export const AUDIT_SQL = `INSERT INTO web_vault_audit (at, action, outcome, project, site, field, actor, run_id, key_id)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`;
export const RUN_SQL = "SELECT id, lane, project, status, claimed_by, lease_until FROM lane_runs WHERE id=?1";
export const ENTRY_SQL = "SELECT id, ciphertext, iv, key_id FROM web_vault WHERE project=?1 AND site=?2 AND field=?3";
export const RUN_TOKEN_SQL = "SELECT machine, token_hash FROM web_vault_run_token WHERE run_id=?1";
// ?1 run id, ?2 machine, ?3 token hash, ?4 t. The run_id PRIMARY KEY.
export const RUN_TOKEN_UPSERT_SQL = `INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES (?1, ?2, ?3, ?4)
 ON CONFLICT(run_id) DO UPDATE SET machine=excluded.machine, token_hash=excluded.token_hash, created_at=excluded.created_at`;
export const TOUCH_SQL = "UPDATE web_vault SET last_used_at=?2 WHERE id=?1";
// The list and stale reads. One fixed text per filter shape, so each keeps its index.
export const LIST_SQL = {
  all: `SELECT ${ENTRY_COLS} FROM web_vault ORDER BY project, site, field LIMIT ?1`,
  project: `SELECT ${ENTRY_COLS} FROM web_vault WHERE project=?1 ORDER BY site, field LIMIT ?2`,
  site: `SELECT ${ENTRY_COLS} FROM web_vault WHERE project=?1 AND site=?2 ORDER BY field LIMIT ?3`,
  stale: `SELECT ${ENTRY_COLS} FROM web_vault WHERE last_used_at < ?1 ORDER BY last_used_at, id LIMIT ?2`,
  staleProject: `SELECT ${ENTRY_COLS} FROM web_vault WHERE last_used_at < ?1 AND project=?2 ORDER BY last_used_at, id LIMIT ?3`,
};
export const AUDIT_LIST_SQL = {
  project: `SELECT ${AUDIT_COLS} FROM web_vault_audit WHERE project=?1 ORDER BY at DESC, id DESC LIMIT ?2`,
  site: `SELECT ${AUDIT_COLS} FROM web_vault_audit WHERE project=?1 AND site=?2 ORDER BY at DESC, id DESC LIMIT ?3`,
};

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// Equal length and equal bytes, with no early exit on the first difference.
export function sameText(a, b) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

// The operator credential. Unset or blank on the worker is DENIED.
export function adminOk(req, env) {
  const want = String((env && env.WEB_VAULT_ADMIN_TOKEN) || "").trim();
  if (!want) return false;
  return sameText(req.headers.get("x-web-vault-admin-token") || "", want);
}
const forbidden = () => json(403, { error: "web-vault needs the operator token (x-web-vault-admin-token)" });

// A web-task enqueue needs the operator token: a 403 Response, or null.
export function webTaskEnqueueRefused(req, env, lane) {
  if (lane !== WEB_TASK_LANE || adminOk(req, env)) return null;
  return json(403, { error: `lane ${WEB_TASK_LANE} is enqueued with the operator token only (x-web-vault-admin-token)` });
}

const b64url = (u8) => btoa(String.fromCharCode(...u8)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export async function sha256Hex(s) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}

// mintRunToken(env, runId, machine, t) -> the token, or null when the row did
// not land (then the run's vault reads are refused bad_token; the claim stands).
export async function mintRunToken(env, runId, machine, t) {
  const token = b64url(crypto.getRandomValues(new Uint8Array(32)));
  try {
    await env.DB.prepare(RUN_TOKEN_UPSERT_SQL).bind(runId, machine, await sha256Hex(token), t).run();
    return token;
  } catch {
    return null;
  }
}

// A host, lower-cased: no scheme, no port, no path. "" when not one.
export function siteName(v) {
  const s = String(v === undefined || v === null ? "" : v).trim().toLowerCase();
  return SITE_RE.test(s) ? s : "";
}
function fieldName(v) {
  const s = String(v === undefined || v === null ? "" : v).trim();
  return FIELD_RE.test(s) ? s : "";
}

// The (project, site, field) of a body or query, or {error}.
function entryOf(src) {
  const project = laneName(src.project), site = siteName(src.site), field = fieldName(src.field);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  if (!site) return { error: "site is required: a host name, no scheme, port or path" };
  if (!field) return { error: "field is required and must match [a-z0-9_.-]{1,64}" };
  return { project, site, field };
}

function valueError(v) {
  if (typeof v !== "string") return "value is required: a string";
  if (typeof v.isWellFormed === "function" && !v.isWellFormed()) return "value is not well-formed text";
  if (v.includes("\u0000")) return "value must not hold a NUL";
  const n = new TextEncoder().encode(v).length;
  if (n < 1 || n > VALUE_MAX_BYTES) return `value must be 1..${VALUE_MAX_BYTES} bytes`;
  return null;
}

// The allow-list of a project: settings row lane.web-task.<project>.allowed_domains,
// a comma list, each entry trimmed and lower-cased. Absent or empty is [].
export function allowedSites(byKey, project) {
  const row = byKey.get(`lane.${WEB_TASK_LANE}.${project}.allowed_domains`);
  if (!row || row.value === null || row.value === undefined) return [];
  return String(row.value).split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
}

// The read decision: the first failing check, or null when the read may go on
// to the vault row. run is the lane_runs row (or null).
// tokenOk: the presented run token hashes to the run's token row, and that row
// is the claim of this machine.
export function readRefusal(run, { project, site, machine, t, allowed, tokenOk }) {
  if (!run) return "no_run";
  if (run.lane !== WEB_TASK_LANE) return "wrong_lane";
  if (run.status !== "claimed") return "not_claimed";
  if (run.claimed_by !== machine) return "not_claimer";
  if (!tokenOk) return "bad_token";
  if (!run.lease_until || String(run.lease_until) <= t) return "lease_expired";
  if (run.project !== project) return "wrong_project";
  if (!allowed.includes(site)) return "site_not_allowed";
  return null;
}
const REFUSAL_STATUS = { no_entry: 404, key_missing: 503, decrypt_failed: 503 };

function limitOf(url, def) {
  const raw = url.searchParams.get("limit");
  if (raw === null || raw === "") return def;
  if (!/^\d+$/.test(raw)) return null;
  const n = Number(raw);
  return n >= 1 && n <= 500 ? n : null;
}

const audit = (env, t, action, outcome, e, actor, runId, keyId) =>
  env.DB.prepare(AUDIT_SQL).bind(t, action, outcome, e.project, e.site, e.field, actor, runId, keyId);

export const routes = [
  [
    "POST", "/api/web-vault/set",
    ({ req, env, t, body }) => d1Guarded("web_vault", async () => {
      if (!adminOk(req, env)) return forbidden();
      const e = entryOf(body || {});
      if (e.error) return json(400, { error: e.error });
      const verr = valueError(body.value);
      if (verr) return json(400, { error: verr });
      const { byKey } = await settingsRows(env);
      const keyId = intSetting(byKey, "web_vault.key_id", 1, 1, 999);
      const enc = await encryptValue(env, keyId, vaultAad(e.project, e.site, e.field), body.value);
      if (!enc.ok) {
        const outcome = enc.why === "key missing" ? "refused:key_missing" : "refused:encrypt_failed";
        await audit(env, t, "set", outcome, e, "operator", null, keyId).run();
        return json(503, { error: enc.why === "key missing" ? "vault key missing" : "vault encrypt failed", key_id: keyId });
      }
      await env.DB.batch([
        env.DB.prepare(UPSERT_SQL).bind(e.project, e.site, e.field, enc.ciphertext, enc.iv, keyId, t),
        audit(env, t, "set", "ok", e, "operator", null, keyId),
      ]);
      return json(200, { stored: true, project: e.project, site: e.site, field: e.field, key_id: keyId, updated_at: t });
    }),
  ],
  [
    "POST", "/api/web-vault/read",
    ({ req, env, t, body }) => d1Guarded("web_vault", async () => {
      const b = body || {};
      const e = entryOf(b);
      if (e.error) return json(400, { error: e.error });
      const machine = laneName(b.machine);
      if (!machine) return json(400, { error: "machine is required and must match [A-Za-z0-9._-]{1,64}" });
      const runId = typeof b.run_id === "number" || typeof b.run_id === "string" ? String(b.run_id).trim() : "";
      if (!/^[1-9]\d{0,15}$/.test(runId)) return json(400, { error: "run_id is required: a positive integer" });
      const id = Number(runId);
      const presented = req.headers.get("x-web-vault-run-token") || "";
      const [run, tok, { byKey }, row, hash] = await Promise.all([
        env.DB.prepare(RUN_SQL).bind(id).first(),
        env.DB.prepare(RUN_TOKEN_SQL).bind(id).first(),
        settingsRows(env),
        env.DB.prepare(ENTRY_SQL).bind(e.project, e.site, e.field).first(),
        sha256Hex(presented),
      ]);
      const tokenOk = !!(presented && tok && tok.machine === machine && sameText(hash, String(tok.token_hash)));
      let why = readRefusal(run, { project: e.project, site: e.site, machine, t, allowed: allowedSites(byKey, e.project), tokenOk });
      let value = null;
      if (!why && !row) why = "no_entry";
      if (!why) {
        const dec = await decryptValue(env, row.key_id, vaultAad(e.project, e.site, e.field), row.iv, row.ciphertext);
        if (dec.ok) value = dec.value;
        else why = dec.why === "key missing" ? "key_missing" : "decrypt_failed";
      }
      const keyId = row && (!why || why === "key_missing" || why === "decrypt_failed") ? row.key_id : null;
      if (why) {
        await audit(env, t, "read", `refused:${why}`, e, machine, id, keyId).run();
        return json(REFUSAL_STATUS[why] || 403, { error: "refused", why });
      }
      // The audit row and last_used_at land before the value leaves; a throw
      // here is d1Guarded's 503 and no value is sent.
      await env.DB.batch([audit(env, t, "read", "ok", e, machine, id, keyId), env.DB.prepare(TOUCH_SQL).bind(row.id, t)]);
      return json(200, { value });
    }),
  ],
  [
    "GET", "/api/web-vault/entries",
    ({ req, env, t, url }) => d1Guarded("web_vault", async () => {
      if (!adminOk(req, env)) return forbidden();
      const q = url.searchParams;
      const limit = limitOf(url, 200);
      if (limit === null) return json(400, { error: "limit must be an integer 1..500" });
      const rawP = q.get("project"), rawS = q.get("site"), stale = q.get("stale") === "1";
      const project = rawP ? laneName(rawP) : "", site = rawS ? siteName(rawS) : "";
      if (rawP && !project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      if (rawS && !site) return json(400, { error: "site must be a host name" });
      if (site && (!project || stale)) return json(400, { error: "site needs project, and stale takes project only" });
      let stmt, retainDays = null;
      if (stale) {
        const { byKey } = await settingsRows(env);
        retainDays = intSetting(byKey, "web_vault.retain_days", 180, 1, 3650);
        const cutoff = iso(Date.parse(t) - retainDays * DAY_MS);
        stmt = project ? env.DB.prepare(LIST_SQL.staleProject).bind(cutoff, project, limit + 1)
          : env.DB.prepare(LIST_SQL.stale).bind(cutoff, limit + 1);
      } else if (site) stmt = env.DB.prepare(LIST_SQL.site).bind(project, site, limit + 1);
      else if (project) stmt = env.DB.prepare(LIST_SQL.project).bind(project, limit + 1);
      else stmt = env.DB.prepare(LIST_SQL.all).bind(limit + 1);
      const rows = (await stmt.all()).results || [];
      const out = { rows: rows.slice(0, limit), more: rows.length > limit, as_of: t };
      if (stale) out.retain_days = retainDays;
      return json(200, out);
    }),
  ],
  [
    "GET", "/api/web-vault/audit",
    ({ req, env, t, url }) => d1Guarded("web_vault_audit", async () => {
      if (!adminOk(req, env)) return forbidden();
      const q = url.searchParams;
      const limit = limitOf(url, 100);
      if (limit === null) return json(400, { error: "limit must be an integer 1..500" });
      const project = laneName(q.get("project"));
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      const rawS = q.get("site"), site = rawS ? siteName(rawS) : "";
      if (rawS && !site) return json(400, { error: "site must be a host name" });
      const stmt = site ? env.DB.prepare(AUDIT_LIST_SQL.site).bind(project, site, limit + 1)
        : env.DB.prepare(AUDIT_LIST_SQL.project).bind(project, limit + 1);
      const rows = (await stmt.all()).results || [];
      return json(200, { rows: rows.slice(0, limit), more: rows.length > limit, as_of: t });
    }),
  ],
];

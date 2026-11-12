// web-session routes — the saved browser session of a web-task run. Contract:
// docs/notes/2026-11-01-BH-7597-web-session.md. The session is the Playwright
// storageState JSON, opaque text here, stored in the web_vault table
// (routes/web-vault.js) as field `session_state` of (project, site): one row
// per (project, site) on uq_web_vault_entry, encrypted like every vault value.
//
// Both routes are behind the bearer and are bound to the caller's claimed lane
// run exactly like POST /api/web-vault/read: body run_id and machine, header
// x-web-vault-run-token, and the same readRefusal decision (no_run,
// wrong_lane, not_claimed, not_claimer, bad_token, lease_expired,
// wrong_project, site_not_allowed). The field is never taken from the body.
//
// POST /api/web-session/save {project, site, run_id, machine, value}
//   400 on a bad body, nothing written. A refusal: 403 {why}, one audit row
//   `set refused:<why>`, no vault change. Then the size: a value over
//   lane.web-task.session_max_bytes (settings row, default 262144,
//   1024..1048576) is 400, nothing written. Key missing: 503, one audit row.
//   Else ONE batch: the upsert and the audit row `set ok`. 200 {stored,
//   project, site, saved_at}. The answer never holds the value.
// POST /api/web-session/load {project, site, run_id, machine}
//   A refusal: 403 {why}. No row: 404 no_entry. A row whose updated_at is at
//   or before now - lane.web-task.session_max_days (settings row, default 14,
//   1..365): 404 expired, and the row stays (the next save replaces it). Key
//   missing or decrypt failed: 503. Every outcome writes ONE audit row. An ok
//   load writes the audit row `read ok` and last_used_at in ONE batch and only
//   then answers {value, saved_at}.
//
// POST /api/web-vault/read refuses field session_state (use_session_load), so
// this load, with its age check, is the one path to a saved session.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { decryptValue, encryptValue, vaultAad } from "../lib/web-vault-crypto.js";
import {
  AUDIT_SQL, RUN_SQL, RUN_TOKEN_SQL, TOUCH_SQL, UPSERT_SQL, WEB_TASK_LANE,
  allowedSites, readRefusal, sameText, sha256Hex, siteName,
} from "./web-vault.js";

export const SESSION_FIELD = "session_state";
// The size cap of a saved session. A storageState is often tens of KB; 1048576
// bytes encrypts and base64-encodes to ~1.4 MB, under D1's 2 MB row.
export const SESSION_MAX_BYTES_KEY = `lane.${WEB_TASK_LANE}.session_max_bytes`;
// Fallback of settings row lane.web-task.session_max_bytes (missing or bad row).
export const SESSION_MAX_BYTES_DEFAULT = 262144;
export const SESSION_MAX_DAYS_KEY = `lane.${WEB_TASK_LANE}.session_max_days`;
export const SESSION_MAX_DAYS_DEFAULT = 14;
const DAY_MS = 86400e3;
// ?1 project, ?2 site. uq_web_vault_entry.
export const SESSION_SQL = `SELECT id, ciphertext, iv, key_id, updated_at FROM web_vault WHERE project=?1 AND site=?2 AND field='${SESSION_FIELD}'`;
const REFUSAL_STATUS = { no_entry: 404, expired: 404, key_missing: 503, decrypt_failed: 503 };

// The (project, site, run id, machine) of a body, or {error}.
function callerOf(b) {
  const project = laneName(b.project), site = siteName(b.site), machine = laneName(b.machine);
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  if (!site) return { error: "site is required: a host name, no scheme, port or path" };
  if (!machine) return { error: "machine is required and must match [A-Za-z0-9._-]{1,64}" };
  const runId = typeof b.run_id === "number" || typeof b.run_id === "string" ? String(b.run_id).trim() : "";
  if (!/^[1-9]\d{0,15}$/.test(runId)) return { error: "run_id is required: a positive integer" };
  return { project, site, field: SESSION_FIELD, machine, id: Number(runId) };
}

// The shape of a value; its size against the row cap is checked after the run
// checks (sizeError), so an unverified caller gets its own refusal.
function valueError(v) {
  if (typeof v !== "string") return "value is required: a string";
  if (typeof v.isWellFormed === "function" && !v.isWellFormed()) return "value is not well-formed text";
  if (v.includes("\u0000")) return "value must not hold a NUL";
  if (v.length === 0) return "value must be 1 byte or more";
  return null;
}

function sizeError(v, byKey) {
  const max = intSetting(byKey, SESSION_MAX_BYTES_KEY, SESSION_MAX_BYTES_DEFAULT, 1024, 1048576);
  const n = new TextEncoder().encode(v).length;
  return n > max ? `value must be 1..${max} bytes` : null;
}

// The run checks of routes/web-vault.js, plus the entry row when withRow.
// Returns { why, byKey, row }.
async function decide(req, env, t, c, withRow) {
  const presented = req.headers.get("x-web-vault-run-token") || "";
  const [run, tok, { byKey }, row, hash] = await Promise.all([
    env.DB.prepare(RUN_SQL).bind(c.id).first(),
    env.DB.prepare(RUN_TOKEN_SQL).bind(c.id).first(),
    settingsRows(env),
    withRow ? env.DB.prepare(SESSION_SQL).bind(c.project, c.site).first() : null,
    sha256Hex(presented),
  ]);
  const tokenOk = !!(presented && tok && tok.machine === c.machine && sameText(hash, String(tok.token_hash)));
  const why = readRefusal(run, { project: c.project, site: c.site, machine: c.machine, t, allowed: allowedSites(byKey, c.project), tokenOk });
  return { why, byKey, row };
}

// True when a session saved at updatedAt is too old to use at t.
export function sessionExpired(updatedAt, t, maxDays) {
  const saved = Date.parse(String(updatedAt || ""));
  if (!Number.isFinite(saved)) return true;
  return saved <= Date.parse(t) - maxDays * DAY_MS;
}

const audit = (env, t, action, outcome, c, keyId) =>
  env.DB.prepare(AUDIT_SQL).bind(t, action, outcome, c.project, c.site, SESSION_FIELD, c.machine, c.id, keyId);
const refused = (why) => json(REFUSAL_STATUS[why] || 403, { error: "refused", why });

export const routes = [
  [
    "POST", "/api/web-session/save",
    ({ req, env, t, body }) => d1Guarded("web_vault", async () => {
      const b = body || {};
      const c = callerOf(b);
      if (c.error) return json(400, { error: c.error });
      const verr = valueError(b.value);
      if (verr) return json(400, { error: verr });
      const { why, byKey } = await decide(req, env, t, c, false);
      if (why) {
        await audit(env, t, "set", `refused:${why}`, c, null).run();
        return refused(why);
      }
      const serr = sizeError(b.value, byKey);
      if (serr) return json(400, { error: serr });
      const keyId = intSetting(byKey, "web_vault.key_id", 1, 1, 999);
      const enc = await encryptValue(env, keyId, vaultAad(c.project, c.site, SESSION_FIELD), b.value);
      if (!enc.ok) {
        const w = enc.why === "key missing" ? "key_missing" : "encrypt_failed";
        await audit(env, t, "set", `refused:${w}`, c, keyId).run();
        return json(503, { error: "refused", why: w, key_id: keyId });
      }
      await env.DB.batch([
        env.DB.prepare(UPSERT_SQL).bind(c.project, c.site, SESSION_FIELD, enc.ciphertext, enc.iv, keyId, t),
        audit(env, t, "set", "ok", c, keyId),
      ]);
      return json(200, { stored: true, project: c.project, site: c.site, saved_at: t });
    }),
  ],
  [
    "POST", "/api/web-session/load",
    ({ req, env, t, body }) => d1Guarded("web_vault", async () => {
      const c = callerOf(body || {});
      if (c.error) return json(400, { error: c.error });
      const d = await decide(req, env, t, c, true);
      const row = d.row;
      let why = d.why, value = null;
      if (!why && !row) why = "no_entry";
      if (!why) {
        const maxDays = intSetting(d.byKey, SESSION_MAX_DAYS_KEY, SESSION_MAX_DAYS_DEFAULT, 1, 365);
        if (sessionExpired(row.updated_at, t, maxDays)) why = "expired";
      }
      if (!why) {
        const dec = await decryptValue(env, row.key_id, vaultAad(c.project, c.site, SESSION_FIELD), row.iv, row.ciphertext);
        if (dec.ok) value = dec.value;
        else why = dec.why === "key missing" ? "key_missing" : "decrypt_failed";
      }
      const keyId = row && (!why || why === "expired" || why === "key_missing" || why === "decrypt_failed") ? row.key_id : null;
      if (why) {
        await audit(env, t, "read", `refused:${why}`, c, keyId).run();
        return refused(why);
      }
      // The audit row and last_used_at land before the value leaves; a throw
      // here is d1Guarded's 503 and no value is sent.
      await env.DB.batch([audit(env, t, "read", "ok", c, keyId), env.DB.prepare(TOUCH_SQL).bind(row.id, t)]);
      return json(200, { value, saved_at: row.updated_at });
    }),
  ],
];

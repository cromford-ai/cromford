// signal-keys routes — per-project Sentry and PostHog keys in an encrypted
// store (BH-9800, slice C0). Contract and operator steps:
// docs/notes/2026-11-17-BH-9800-signal-keys.md. Tables:
// schema.d/202611172248-bh-9800-signal-keys.sql. Crypto: lib/web-vault-crypto.js
// (the web vault's keys and key id). Vendor calls: lib/signal-probe.js only.
//
// Every route is behind the bearer (HARNESS_SECRET). OPERATOR is the web-vault
// admin token (x-web-vault-admin-token, actor `operator`) OR the BH-9262 owner
// proof (the console's Pages proof for an owner email, actor = that email; or
// the Mac human token, actor `human-token`). No shadow mode: no proof is 403
// and nothing is written.
//
// POST /api/signal-keys/set {project, kind, fields}   operator
//   Trims each field. Checks it against the kind row (re, prefixes, host
//   allow, signal_keys.value_max_bytes). 400 names the field, writes nothing.
//   Key missing: 503 + one refused:key_missing audit row. Else ONE batch: the
//   upsert (last_test_* reset to NULL) + one audit row. Never the value.
// POST /api/signal-keys/clear {project, kind}   operator
//   No row: 404 + one refused:no_entry row. Else ONE batch: delete + audit.
// GET /api/signal-keys[?project=P]   bearer, metadata only
//   {kinds, rows (no ciphertext, no iv), more, rotate_days, as_of}.
// POST /api/signal-keys/test {project, kind}   operator
//   Decrypts, calls the vendor through the seam, and stores the result and one
//   audit row in ONE batch. {ok, result, status, reason, tested_at}.
// POST /api/signal-keys/read {project, kind, run_id, machine}   a lane-run machine
//   x-web-vault-run-token of a claimed run of a lane in signal_keys.read_lanes.
//   First failing check wins: no_run, wrong_lane, not_claimed, not_claimer,
//   bad_token, lease_expired, wrong_project, no_entry, key_missing,
//   decrypt_failed. One audit row per outcome; an ok read writes its audit row
//   and last_used_at in ONE batch before it answers {kind, fields, value}.
// POST /api/signal-keys/hub-read {project, kind}   the hub
//   x-envelope-hub-token = ENVELOPE_HUB_TOKEN. Unset: 503 hub_token_unset;
//   wrong: 403 bad_hub_token. Then the read's entry checks and write-then-send.
//
// No log line here carries a field value: each passes through maskTokens.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";
import { decryptValue, encryptValue } from "../lib/web-vault-crypto.js";
import { adminOk, RUN_SQL, RUN_TOKEN_SQL, sameText, sha256Hex } from "./web-vault.js";
import { ownerProof } from "../lib/owner-proof.js";
import { hubTokenOk } from "./secret-envelopes.js";
import { allowList, normalizeHost, probeSignal, probeUrl, reasonOf } from "../lib/signal-probe.js";
import { maskTokens } from "../lib/token-mask.js";
import { READ_LANES_KEY, signalReadLanes } from "../lib/signal-lanes.js";

const KIND_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const DAY_MS = 86400e3;
// Code fallbacks, each the seed of the settings row it names.
const TIMEOUT = { key: "signal_keys.test_timeout_ms", def: 10000, min: 1000, max: 30000 };
const ROTATE = { key: "signal_keys.rotate_days", def: 90, min: 1, max: 3650 };
const LIST = { key: "signal_keys.list_limit", def: 500, min: 1, max: 5000 };
const VALUE_MAX = { key: "signal_keys.value_max_bytes", def: 4096, min: 64, max: 16384 };
const knob = (byKey, k) => intSetting(byKey, k.key, k.def, k.min, k.max);

const ROW_COLS = "project, kind, fields_json, updated_at, updated_by, last_used_at, last_test_at, last_test_status, last_test_result";
// ?1 project ?2 kind ?3 fields_json ?4 ciphertext ?5 iv ?6 key_id ?7 t ?8 actor. uq_signal_keys_entry.
export const UPSERT_SQL = `INSERT INTO signal_keys (project, kind, fields_json, ciphertext, iv, key_id, created_at, updated_at, updated_by)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8)
 ON CONFLICT(project, kind) DO UPDATE SET
   fields_json=excluded.fields_json, ciphertext=excluded.ciphertext, iv=excluded.iv, key_id=excluded.key_id,
   updated_at=excluded.updated_at, updated_by=excluded.updated_by,
   last_test_at=NULL, last_test_status=NULL, last_test_result=NULL`;
export const AUDIT_SQL = `INSERT INTO signal_key_audit (at, action, outcome, project, kind, actor, run_id, key_id)
 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`;
export const ENTRY_SQL = "SELECT id, fields_json, ciphertext, iv, key_id FROM signal_keys WHERE project=?1 AND kind=?2";
export const KIND_SQL = "SELECT kind, fields_json, test_template, host_field, host_allow FROM signal_key_kinds WHERE kind=?1";
export const KINDS_SQL = "SELECT kind, label, fields_json, scope_note, sort FROM signal_key_kinds ORDER BY sort, kind";
// One fixed text per filter shape, so each keeps uq_signal_keys_entry.
export const LIST_SQL = {
  all: `SELECT ${ROW_COLS} FROM signal_keys ORDER BY project, kind LIMIT ?1`,
  project: `SELECT ${ROW_COLS} FROM signal_keys WHERE project=?1 ORDER BY kind LIMIT ?2`,
};
export const DELETE_SQL = "DELETE FROM signal_keys WHERE id=?1";
export const TOUCH_SQL = "UPDATE signal_keys SET last_used_at=?2 WHERE id=?1";
export const TEST_RESULT_SQL = "UPDATE signal_keys SET last_test_at=?2, last_test_status=?3, last_test_result=?4 WHERE id=?1";

// The AAD of one entry: a ciphertext copied into another row fails to decrypt.
export function signalAad(project, kind) {
  return `signal_keys\n${project}\n${kind}`;
}

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const noStore = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store" },
});
const forbidden = () => json(403, { error: "signal-keys needs the operator token or the owner proof" });
const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

// The operator actor, or null.
async function operatorOf(req, env) {
  if (adminOk(req, env)) return "operator";
  const p = await ownerProof(req, env);
  if (!p.ok) return null;
  return p.via === "box-ops" ? p.identity : "human-token";
}

function entryOf(src) {
  const project = laneName(src && src.project);
  const kind = String((src && src.kind) ?? "").trim();
  if (!project) return { error: "project is required and must match [A-Za-z0-9._-]{1,64}" };
  if (!KIND_RE.test(kind)) return { error: "kind is required and must match [a-z0-9][a-z0-9_-]{0,31}" };
  return { project, kind };
}

// Trim spaces, tabs and line breaks at both ends (a pasted key).
const trimPaste = (v) => v.trim();

// The kind row's field list checked against `fields`:
// {clear, secret} | {error, field}.
export function checkFields(kindRow, fields, maxBytes) {
  const defs = parse(kindRow.fields_json);
  if (!Array.isArray(defs)) return { error: `kind ${kindRow.kind} has no field list`, field: null };
  if (!fields || typeof fields !== "object" || Array.isArray(fields)) return { error: "fields is required: an object", field: null };
  const known = new Set(defs.map((d) => d.name));
  for (const k of Object.keys(fields)) if (!known.has(k)) return { error: `unknown field ${k}`, field: k };
  const clear = {};
  let secret = null;
  for (const d of defs) {
    const raw = fields[d.name];
    if (typeof raw !== "string") return { error: `${d.label} is required`, field: d.name };
    const v = trimPaste(raw);
    if (!v) return { error: `${d.label} is required`, field: d.name };
    if (d.secret) {
      const n = new TextEncoder().encode(v).length;
      if (n > maxBytes) return { error: `${d.label} must be at most ${maxBytes} bytes`, field: d.name };
      const prefixes = Array.isArray(d.prefixes) ? d.prefixes : [];
      if (prefixes.length && !prefixes.some((p) => v.startsWith(p))) {
        return { error: `${d.label} must start with ${prefixes.join(" or ")}`, field: d.name };
      }
    }
    let re = null;
    try { re = new RegExp(d.re); } catch { re = null; }
    if (!re || !re.test(v)) return { error: `${d.label} does not match the format (${d.placeholder})`, field: d.name };
    if (kindRow.host_field && d.name === kindRow.host_field) {
      const allow = allowList(kindRow.host_allow);
      const origin = normalizeHost(v, allow);
      if (!origin) return { error: `${d.label} must be one of ${allow.map((h) => `https://${h}`).join(", ")}`, field: d.name };
      clear[d.name] = origin;
    } else if (d.secret) secret = v;
    else clear[d.name] = v;
  }
  if (secret === null) return { error: `kind ${kindRow.kind} has no secret field`, field: null };
  return { clear, secret };
}

const audit = (env, t, action, outcome, e, actor, runId, keyId) =>
  env.DB.prepare(AUDIT_SQL).bind(t, action, outcome, e.project, e.kind, actor, runId ?? null, keyId ?? null);

// A batch that answers false (after one masked log line) instead of throwing.
async function batchOk(env, stmts, what) {
  try {
    await env.DB.batch(stmts);
    return true;
  } catch (e) {
    console.error(maskTokens(`[signal-keys] ${what} batch failed: ${String((e && e.message) || e).slice(0, 200)}`));
    return false;
  }
}

// The entry's secret: {value} | {why: key_missing | decrypt_failed}.
async function secretOf(env, e, row) {
  const dec = await decryptValue(env, row.key_id, signalAad(e.project, e.kind), row.iv, row.ciphertext);
  if (dec.ok) return { value: dec.value };
  return { why: dec.why === "key missing" ? "key_missing" : "decrypt_failed" };
}

// The lane read decision: the first failing check, or null.
export function signalReadRefusal(run, { project, machine, t, lanes, tokenOk }) {
  if (!run) return "no_run";
  if (!lanes.includes(run.lane)) return "wrong_lane";
  if (run.status !== "claimed") return "not_claimed";
  if (run.claimed_by !== machine) return "not_claimer";
  if (!tokenOk) return "bad_token";
  if (!run.lease_until || String(run.lease_until) <= t) return "lease_expired";
  if (run.project !== project) return "wrong_project";
  return null;
}
const REFUSAL_STATUS = { no_entry: 404, key_missing: 503, decrypt_failed: 503, hub_token_unset: 503 };

// The entry checks and the write-then-send of read and hub-read.
async function serveValue(env, t, e, row, action, actor, runId) {
  let why = row ? null : "no_entry";
  let value = null;
  if (!why) {
    const s = await secretOf(env, e, row);
    if (s.why) why = s.why;
    else value = s.value;
  }
  const keyId = row ? row.key_id : null;
  if (why) {
    await audit(env, t, action, `refused:${why}`, e, actor, runId, keyId).run();
    return noStore(REFUSAL_STATUS[why] || 403, { error: "refused", why });
  }
  const landed = await batchOk(env, [audit(env, t, action, "ok", e, actor, runId, keyId), env.DB.prepare(TOUCH_SQL).bind(row.id, t)], action);
  if (!landed) return noStore(503, { error: "the read was not audited, so no value is sent" });
  return noStore(200, { kind: e.kind, fields: parse(row.fields_json) || {}, value });
}

export const routes = [
  [
    "POST", "/api/signal-keys/set",
    ({ req, env, t, body }) => d1Guarded("signal_keys", async () => {
      const actor = await operatorOf(req, env);
      if (!actor) return forbidden();
      const e = entryOf(body);
      if (e.error) return json(400, { error: e.error });
      const [kindRow, { byKey }] = await Promise.all([env.DB.prepare(KIND_SQL).bind(e.kind).first(), settingsRows(env)]);
      if (!kindRow) return json(400, { error: `unknown kind ${e.kind}`, field: "kind" });
      const f = checkFields(kindRow, body.fields, knob(byKey, VALUE_MAX));
      if (f.error) return json(400, { error: f.error, field: f.field });
      const keyId = intSetting(byKey, "web_vault.key_id", 1, 1, 999);
      const enc = await encryptValue(env, keyId, signalAad(e.project, e.kind), f.secret);
      if (!enc.ok) {
        const missing = enc.why === "key missing";
        await audit(env, t, "set", missing ? "refused:key_missing" : "refused:encrypt_failed", e, actor, null, keyId).run();
        return json(503, { error: missing ? "signal key encryption key missing" : "signal key encrypt failed", key_id: keyId });
      }
      const fieldsJson = JSON.stringify(f.clear);
      const landed = await batchOk(env, [
        env.DB.prepare(UPSERT_SQL).bind(e.project, e.kind, fieldsJson, enc.ciphertext, enc.iv, keyId, t, actor),
        audit(env, t, "set", "ok", e, actor, null, keyId),
      ], "set");
      if (!landed) return json(503, { error: "the key was not stored" });
      return json(200, { stored: true, project: e.project, kind: e.kind, fields: f.clear, updated_at: t, updated_by: actor, key_id: keyId });
    }),
  ],
  [
    "POST", "/api/signal-keys/clear",
    ({ req, env, t, body }) => d1Guarded("signal_keys", async () => {
      const actor = await operatorOf(req, env);
      if (!actor) return forbidden();
      const e = entryOf(body);
      if (e.error) return json(400, { error: e.error });
      const row = await env.DB.prepare(ENTRY_SQL).bind(e.project, e.kind).first();
      if (!row) {
        await audit(env, t, "clear", "refused:no_entry", e, actor).run();
        return json(404, { error: "no signal key for this project and kind", project: e.project, kind: e.kind });
      }
      const landed = await batchOk(env, [env.DB.prepare(DELETE_SQL).bind(row.id), audit(env, t, "clear", "ok", e, actor, null, row.key_id)], "clear");
      if (!landed) return json(503, { error: "the key was not cleared" });
      return json(200, { cleared: true, project: e.project, kind: e.kind });
    }),
  ],
  [
    "GET", "/api/signal-keys",
    ({ env, t, url }) => d1Guarded("signal_keys", async () => {
      const rawP = url.searchParams.get("project");
      const project = rawP ? laneName(rawP) : "";
      if (rawP && !project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      // The rows read is bounded by the knob's max, so it runs beside the settings read.
      const rowsStmt = project ? env.DB.prepare(LIST_SQL.project).bind(project, LIST.max + 1)
        : env.DB.prepare(LIST_SQL.all).bind(LIST.max + 1);
      const [kinds, rowsRes, { byKey }] = await Promise.all([env.DB.prepare(KINDS_SQL).all(), rowsStmt.all(), settingsRows(env)]);
      const limit = knob(byKey, LIST);
      const days = knob(byKey, ROTATE);
      const all = rowsRes.results || [];
      const now = Date.parse(t);
      const rows = all.slice(0, limit).map((r) => {
        const by = Date.parse(r.updated_at) + days * DAY_MS;
        return {
          project: r.project, kind: r.kind, fields: parse(r.fields_json) || {}, secret_set: true,
          updated_at: r.updated_at, updated_by: r.updated_by, last_used_at: r.last_used_at ?? null,
          last_test_at: r.last_test_at ?? null, last_test_status: r.last_test_status ?? null, last_test_result: r.last_test_result ?? null,
          rotate_by: Number.isFinite(by) ? iso(by) : null, rotate_overdue: Number.isFinite(by) ? now > by : false,
        };
      });
      return json(200, {
        kinds: (kinds.results || []).map((k) => ({ kind: k.kind, label: k.label, fields: parse(k.fields_json) || [], scope_note: k.scope_note })),
        rows, more: all.length > limit, rotate_days: days, as_of: t,
      });
    }),
  ],
  [
    "POST", "/api/signal-keys/test",
    ({ req, env, t, body }) => d1Guarded("signal_keys", async () => {
      const actor = await operatorOf(req, env);
      if (!actor) return forbidden();
      const e = entryOf(body);
      if (e.error) return json(400, { error: e.error });
      const [row, kindRow, { byKey }] = await Promise.all([
        env.DB.prepare(ENTRY_SQL).bind(e.project, e.kind).first(),
        env.DB.prepare(KIND_SQL).bind(e.kind).first(),
        settingsRows(env),
      ]);
      if (!row || !kindRow) {
        const why = row ? "no_kind" : "no_entry";
        await audit(env, t, "test", `refused:${why}`, e, actor, null, row ? row.key_id : null).run();
        return json(404, { error: "refused", why });
      }
      let result, status = null;
      const s = await secretOf(env, e, row);
      if (s.why) result = s.why;
      else {
        const u = probeUrl(kindRow, parse(row.fields_json) || {});
        if (!u.ok) result = "bad_url";
        else ({ result, status } = await probeSignal({ url: u.url, secret: s.value, timeoutMs: knob(byKey, TIMEOUT) }));
      }
      const landed = await batchOk(env, [
        env.DB.prepare(TEST_RESULT_SQL).bind(row.id, t, status, result),
        audit(env, t, "test", result, e, actor, null, row.key_id),
      ], "test");
      if (!landed) return json(503, { error: "the test result was not stored" });
      return json(200, { ok: result === "ok", result, status, reason: reasonOf(result), tested_at: t });
    }),
  ],
  [
    "POST", "/api/signal-keys/read",
    ({ req, env, t, body }) => d1Guarded("signal_keys", async () => {
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
        env.DB.prepare(ENTRY_SQL).bind(e.project, e.kind).first(),
        sha256Hex(presented),
      ]);
      const tokenOk = !!(presented && tok && tok.machine === machine && sameText(hash, String(tok.token_hash)));
      const lanesRow = byKey.get(READ_LANES_KEY);
      const why = signalReadRefusal(run, { project: e.project, machine, t, lanes: signalReadLanes(lanesRow && lanesRow.value), tokenOk });
      if (why) {
        await audit(env, t, "read", `refused:${why}`, e, machine, id, null).run();
        return noStore(403, { error: "refused", why });
      }
      return serveValue(env, t, e, row, "read", machine, id);
    }),
  ],
  [
    "POST", "/api/signal-keys/hub-read",
    ({ req, env, t, body }) => d1Guarded("signal_keys", async () => {
      const e = entryOf(body);
      if (e.error) return json(400, { error: e.error });
      let why = null;
      if (!String(env.ENVELOPE_HUB_TOKEN ?? "").trim()) why = "hub_token_unset";
      else if (!hubTokenOk(req, env)) why = "bad_hub_token";
      if (why) {
        await audit(env, t, "hub_read", `refused:${why}`, e, "hub").run();
        return noStore(REFUSAL_STATUS[why] || 403, { error: "refused", why });
      }
      const row = await env.DB.prepare(ENTRY_SQL).bind(e.project, e.kind).first();
      return serveValue(env, t, e, row, "hub_read", "hub", null);
    }),
  ],
];

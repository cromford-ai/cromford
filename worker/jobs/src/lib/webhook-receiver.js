// webhook-receiver — the GitHub receiver's guards (BH-9934, BH-9926.2).
// routes/webhooks.js calls these; everything here but receiverKnobs is pure or
// reads only memory.
//
//   bodyCapOf / readCappedBody  the body cap, checked BEFORE the HMAC
//   receiverKnobs / selfAppOf   the fleet's own Apps (HARNESS_SELF_APPS): an
//                               echo of the harness's own write wakes nothing
//   CLAIM_GUARD_SQL             the record statements' delivery-claim guard
//   deadLetterStmt              the row a throw after the signature leaves

import { peekSetting, settingsRows } from "./settings-cache.js";

// Fallback of the settings row webhook.github.max_body_bytes (schema.d/
// 202611240325-bh-9934-webhook-receiver-knobs.sql). 5 MiB: no normal PR or push
// delivery is near it, and GitHub caps a payload at 25 MB.
export const WEBHOOK_MAX_BODY_BYTES = 5242880;
export const MAX_BODY_KEY = "webhook.github.max_body_bytes";
// The range a row value must be in to count; outside it the fallback applies.
const CAP_MIN = 1024, CAP_MAX = 26214400;

// Fallback of the settings row webhook.github.self_echo_actions: the
// harness's own label and comment writes. Every handoff action (opened,
// synchronize, closed, a CI result) stays a wake.
export const SELF_ECHO_KEY = "webhook.github.self_echo_actions";
export const SELF_ECHO_ACTIONS = ["pull_request.labeled", "pull_request.unlabeled",
  "issue_comment.created", "issue_comment.edited"];

// The cap in bytes. peekSetting reads only the snapshot already in memory
// (lib/settings-cache.js): an unsigned caller causes no D1 read. A cold
// isolate, TTL 0 or a bad row value use the fallback.
export function bodyCapOf(env) {
  const v = peekSetting(env.DB, MAX_BODY_KEY);
  if (v !== null && /^\d{1,9}$/.test(v)) {
    const n = Number(v);
    if (n >= CAP_MIN && n <= CAP_MAX) return n;
  }
  return WEBHOOK_MAX_BODY_BYTES;
}

// -> {tooLarge: true} or {raw}. A Content-Length over the cap is refused with
// no read. Otherwise the stream is counted as it is read (a Content-Length
// can be smaller than the body), and the read stops at cap+1 bytes. A read
// that fails is an empty body, as req.text().catch(() => "") was.
export async function readCappedBody(req, cap) {
  const cl = String(req.headers.get("content-length") || "").trim();
  if (/^\d+$/.test(cl) && Number(cl) > cap) return { tooLarge: true };
  if (!req.body) return { raw: "" };
  const reader = req.body.getReader();
  const chunks = [];
  let n = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.byteLength;
      if (n > cap) {
        await reader.cancel().catch(() => {});
        return { tooLarge: true };
      }
      chunks.push(value);
    }
  } catch {
    return { raw: "" };
  }
  const buf = new Uint8Array(n);
  let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.byteLength; }
  return { raw: new TextDecoder().decode(buf) };
}

// The bare lowercase App slug: `app/x`, `x[bot]` and `x` are all "x" (the
// same rule as harness_self_apps_json in bin/lib/harness-self.sh).
const slugOf = (v) => {
  let s = String(v || "").trim().toLowerCase();
  if (s.startsWith("app/")) s = s.slice(4);
  if (s.endsWith("[bot]")) s = s.slice(0, -5);
  return s;
};

// The App slug of a delivery's sender when it is one of the fleet's own Apps,
// else "". HARNESS_SELF_APPS is a deploy var (bin/harness-sync.sh, from
// env/global.env), never a settings row: a trust list is not writable from
// the control plane. A match needs sender.type "Bot": a person or the PAT
// login is never "ours".
export function selfSenderOf(env, payload) {
  const apps = String((env && env.HARNESS_SELF_APPS) || "").split(/\s+/).map(slugOf).filter(Boolean);
  if (!apps.length) return "";
  const s = payload && typeof payload === "object" && payload.sender && typeof payload.sender === "object" ? payload.sender : null;
  if (!s || s.type !== "Bot") return "";
  const slug = slugOf(s.login);
  return apps.includes(slug) ? slug : "";
}

// The App slug when this delivery is an echo of a fleet App's own write
// (sender in the list AND <event>.<action> in knobs.selfEchoActions), else "".
export function selfAppOf(env, event, payload, knobs) {
  const slug = selfSenderOf(env, payload);
  if (!slug) return "";
  const action = String((payload && payload.action) || "");
  return knobs.selfEchoActions.includes(`${event}.${action}`) ? slug : "";
}

// The knobs read after the signature: one settingsRows (the per-isolate
// snapshot, TTL settings_cache_ttl_s). A failed read uses the fallbacks.
export async function receiverKnobs(env) {
  let row;
  try { row = (await settingsRows(env)).byKey.get(SELF_ECHO_KEY); } catch { row = undefined; }
  const v = row && row.value !== null && row.value !== undefined ? String(row.value) : null;
  return { selfEchoActions: v === null ? SELF_ECHO_ACTIONS : v.split(/\s+/).filter(Boolean) };
}

// The guard on every PR record statement of a wake batch. Binds ?a delivery
// id, ?a+1 the claim. The delivery row of the batch holds the claim only when
// it was new, so a duplicate delivery's record statements change 0 rows. Not
// correlated: SQLite runs it once per statement. Index: the primary key
// (vendor, delivery_id) (test X1).
export const CLAIM_GUARD_SQL = (a) =>
  `EXISTS (SELECT 1 FROM webhook_deliveries WHERE vendor = 'github' AND delivery_id = ?${a} AND claim = ?${a + 1})`;

// A dead letter: a delivery whose handling threw after the signature check.
// Its own vendor, so it never holds the `github` id and a redelivery runs
// again. A second throw for the same id moves the row forward.
export const DEAD_VENDOR = "github:dead";
// One plain literal: the vendor is bound as ?1, never interpolated
// (bin/sql-ident-lint.sh refused the r4 form, BH-9934).
export const DEAD_LETTER_SQL = "INSERT INTO webhook_deliveries (vendor, delivery_id, at, error, event) VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(vendor, delivery_id) DO UPDATE SET at = excluded.at, error = excluded.error, event = excluded.event";
export function deadLetterStmt(env, deliveryId, t, error, event) {
  return env.DB.prepare(DEAD_LETTER_SQL).bind(DEAD_VENDOR, deliveryId, t, error, event);
}

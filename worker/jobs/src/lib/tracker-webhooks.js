// tracker-webhooks — the Jira and Linear halves of the webhook doorbell (BH-4079).
//
// POST /webhooks/github has rung the `wakes` doorbell since BH-1034. This module
// is what lets a Jira site or a Linear workspace ring the SAME doorbell: a
// signature check per vendor, an edge-detecting event→wake mapper per vendor,
// the delivery id each vendor stamps on a send, and the one settings read that
// routes a delivery to a harness repo. Nothing downstream of `wakes` changes: a
// Jira or Linear row is an ordinary `kind=issue` row whose `repo` is a fleet
// slug, so bin/wake-loop.sh claims it exactly as it claims a GitHub one.
//
// Everything here except readWebhookConfig is pure. The same rule as wakeOf in
// core.js: a field VALUE (a label, a status, a title) is read to decide and is
// never stored. The only thing a wake keeps is the ticket key.

import { hmacSha256Hex, hexEqual, WAKE_REPO_RE } from "./core.js";

// The documented fallbacks. Each one is a settings row first (see
// readWebhookConfig); these are what answers while nobody has written it.
export const WEBHOOK_DEFAULTS = {
  edgeFields: {
    jira: ["status", "labels", "summary", "description", "resolution"],
    linear: ["stateId", "labelIds", "title", "description"],
  },
  maxAgeS: 300,      // webhook_max_age_s — Linear's replay window
  keepS: 604800,     // webhook_delivery_keep_s — how long a delivery id is remembered
};

// The header each vendor stamps a send with. A redelivery carries the same id.
const DELIVERY_HEADER = {
  github: "x-github-delivery",
  jira: "x-atlassian-webhook-identifier",
  linear: "linear-delivery",
};
const DELIVERY_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;

// deliveryIdOf(vendor, headers) -> the vendor's delivery id, or null when it is
// absent or does not look like one. null is NOT a duplicate: the caller records
// the wake with minute dedupe only.
export function deliveryIdOf(vendor, headers) {
  const h = DELIVERY_HEADER[vendor];
  if (!h || !headers || typeof headers.get !== "function") return null;
  const v = String(headers.get(h) || "").trim();
  return DELIVERY_ID_RE.test(v) ? v : null;
}

// Checked BEFORE the body is read (BH-10532): the vendor secret is set and the
// signature header has the only shape the HMAC below can match (hexEqual is
// case-sensitive and hmacSha256Hex is lowercase). No HMAC here, so an unsigned
// caller costs no body read. -> null (go on) or {status, error}. A bad shape
// gets the same text as a bad HMAC, so a caller cannot tell the checks apart.
const SIG_SHAPE = {
  jira: { secret: "JIRA_WEBHOOK_SECRET", header: "x-hub-signature", re: /^sha256=[0-9a-f]{64}$/ },
  linear: { secret: "LINEAR_WEBHOOK_SECRET", header: "linear-signature", re: /^[0-9a-f]{64}$/ },
};
export function trackerPreCheck(env, vendor, headers) {
  const s = SIG_SHAPE[vendor];
  if (!s) return { status: 500, error: "unknown vendor" };
  if (!env[s.secret]) return { status: 503, error: `webhook receiver not configured (${s.secret} unset)` };
  const sig = String(headers.get(s.header) || "");
  return s.re.test(sig) ? null : { status: 401, error: "bad signature" };
}

// Jira Cloud: `X-Hub-Signature: sha256=<hex>` over the raw body, keyed on the
// secret given when the webhook was registered. null = verified.
export async function verifyJira(env, headers, raw) {
  if (!env.JIRA_WEBHOOK_SECRET) {
    return { status: 503, error: "webhook receiver not configured (JIRA_WEBHOOK_SECRET unset)" };
  }
  const sig = String(headers.get("x-hub-signature") || "");
  const want = "sha256=" + await hmacSha256Hex(env.JIRA_WEBHOOK_SECRET, raw);
  return hexEqual(sig, want) ? null : { status: 401, error: "bad signature" };
}

// Linear: `Linear-Signature: <hex>` over the raw body. null = verified. The
// replay check is linearFresh below, because its window is a settings row and
// no settings read happens before a signature is proven.
export async function verifyLinear(env, headers, raw) {
  if (!env.LINEAR_WEBHOOK_SECRET) {
    return { status: 503, error: "webhook receiver not configured (LINEAR_WEBHOOK_SECRET unset)" };
  }
  const sig = String(headers.get("linear-signature") || "");
  const want = await hmacSha256Hex(env.LINEAR_WEBHOOK_SECRET, raw);
  return hexEqual(sig, want) ? null : { status: 401, error: "bad signature" };
}

// The payload's own `webhookTimestamp` (ms) must sit inside maxAgeS of the
// server clock `t`, so a captured delivery cannot be replayed later. A missing
// timestamp fails, never passes. null = fresh.
export function linearFresh(payload, t, maxAgeS) {
  const ts = payload && typeof payload === "object" ? Number(payload.webhookTimestamp) : NaN;
  const now = Date.parse(t);
  if (!Number.isFinite(ts) || !Number.isFinite(now) || Math.abs(now - ts) > maxAgeS * 1000) {
    return { status: 401, error: "stale or missing webhookTimestamp" };
  }
  return null;
}

const JIRA_KEY_RE = /^[A-Z][A-Z0-9_]{0,19}-[1-9][0-9]{0,8}$/;
const LINEAR_KEY_RE = /^[A-Z][A-Z0-9]{0,9}-[1-9][0-9]{0,8}$/;
const obj = (v) => (v && typeof v === "object" ? v : {});

// The ticket key a delivery is about, validated, or "" — pure, so a route can
// find the project/team to route on before it reads a single settings row.
export function jiraKeyOf(payload) {
  const key = String(obj(obj(payload).issue).key || "");
  return JIRA_KEY_RE.test(key) ? key : "";
}
export function linearKeyOf(payload) {
  const p = obj(payload), d = obj(p.data);
  const m = /\/issue\/([A-Z][A-Z0-9]{0,9}-\d{1,9})(?:\/|$|[?#])/.exec(String(p.url || ""));
  return [d.identifier, obj(d.issue).identifier, m && m[1]]
    .map((v) => String(v || "")).find((v) => LINEAR_KEY_RE.test(v)) || "";
}
export const keyPrefix = (key) => key.slice(0, key.lastIndexOf("-"));

const evName = (s) => String(s).toLowerCase().replace(/[^a-z_.]/g, "").slice(0, 64);

// jiraWakeOf(payload, {edgeFields, selfIds}) -> {project, key, event} or {ignored}.
// An update wakes only when its changelog touches an edge field; one with no
// changelog at all still wakes (fail-open: a missed client costs more than one
// gated triage tick). A delivery our own actor caused never wakes.
export function jiraWakeOf(payload, cfg) {
  const p = obj(payload);
  const we = String(p.webhookEvent || "");
  const isComment = we === "comment_created" || we === "comment_updated";
  if (!isComment && !["jira:issue_created", "jira:issue_updated", "jira:issue_deleted"].includes(we)) {
    return { ignored: we || "unknown" };
  }
  const actor = isComment ? obj(obj(p.comment).author).accountId : obj(p.user).accountId;
  if (actor && (cfg.selfIds || []).includes(String(actor))) return { ignored: "self-authored" };
  if (we === "jira:issue_updated") {
    const items = Array.isArray(obj(p.changelog).items) ? p.changelog.items : [];
    if (items.length) {
      const edge = new Set(cfg.edgeFields || []);
      const hit = items.some((it) => edge.has(String(obj(it).field || "")) || edge.has(String(obj(it).fieldId || "")));
      if (!hit) return { ignored: "no edge field changed" };
    }
  }
  const key = jiraKeyOf(p);
  if (!key) return { ignored: "no issue key" };
  return { project: keyPrefix(key), key, event: evName("jira." + we.replace(/^jira:/, "")) };
}

// linearWakeOf(payload, {edgeFields, selfIds}) -> {team, key, event} or {ignored}.
// Same edge rule as Jira, read off `updatedFrom` (the previous values of what
// changed). The key comes from data.identifier, then data.issue.identifier,
// then the issue URL — a Comment payload carries its issue only in some shapes.
export function linearWakeOf(payload, cfg) {
  const p = obj(payload);
  const type = String(p.type || ""), action = String(p.action || "");
  const ok = (type === "Issue" && ["create", "update", "remove"].includes(action))
    || (type === "Comment" && ["create", "update"].includes(action));
  if (!ok) return { ignored: `${type || "unknown"}.${action || "unknown"}` };
  const actor = obj(p.actor).id;
  if (actor && (cfg.selfIds || []).includes(String(actor))) return { ignored: "self-authored" };
  if (type === "Issue" && action === "update" && p.updatedFrom && typeof p.updatedFrom === "object") {
    const edge = new Set(cfg.edgeFields || []);
    if (!Object.keys(p.updatedFrom).some((k) => edge.has(k))) return { ignored: "no edge field changed" };
  }
  const key = linearKeyOf(p);
  if (!key) return { ignored: "no issue identifier" };
  return { team: keyPrefix(key), key, event: evName(`linear.${type}.${action}`) };
}

const list = (v) => String(v).split(",").map((s) => s.trim()).filter(Boolean);
const posInt = (v, dflt) => (/^[1-9][0-9]{0,9}$/.test(String(v ?? "")) ? Number(v) : dflt);

// readWebhookConfig(env, vendor, routeKey) -> {repo, routeMalformed, edgeFields,
// selfIds, maxAgeS, keepS}. ONE SELECT for every row a delivery needs. routeKey
// is lowercased here, once (settings keys are ^[a-z0-9_.-]{1,64}$). repo is null
// when there is no route row; routeMalformed says a row exists but is no slug.
export async function readWebhookConfig(env, vendor, routeKey) {
  const routeRow = `webhook_route.${vendor}.${String(routeKey || "").toLowerCase()}`;
  const keys = [routeRow, `webhook_edge_fields.${vendor}`, `webhook_self.${vendor}`,
    "webhook_max_age_s", "webhook_delivery_keep_s"];
  const res = await env.DB.prepare(
    `SELECT key, value FROM settings WHERE key IN (?1,?2,?3,?4,?5)`
  ).bind(...keys).all();
  const m = new Map(((res && res.results) || []).map((r) => [r.key, r.value]));
  const route = m.has(routeRow) ? String(m.get(routeRow)).trim() : null;
  const edge = m.has(keys[1]) ? list(m.get(keys[1])) : [];
  return {
    repo: route && WAKE_REPO_RE.test(route) ? route : null,
    routeMalformed: route !== null && !WAKE_REPO_RE.test(route),
    edgeFields: edge.length ? edge : WEBHOOK_DEFAULTS.edgeFields[vendor] || [],
    selfIds: m.has(keys[2]) ? list(m.get(keys[2])) : [],
    maxAgeS: posInt(m.get(keys[3]), WEBHOOK_DEFAULTS.maxAgeS),
    keepS: posInt(m.get(keys[4]), WEBHOOK_DEFAULTS.keepS),
  };
}

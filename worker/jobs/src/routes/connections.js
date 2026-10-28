// connections routes — the tracker connection of each project (BH-7924).
//
// GET  /api/connections                 one row per project: the adapter, its
//                                       settings rows, the last probe status and
//                                       the webhook route. Secrets as booleans.
// PUT  /api/connections                 the console's edit form (coord write
//                                       7924-connections.js). Writes the tracker
//                                       settings rows and ONE config_changes row
//                                       (kind `connection`) in one batch.
// POST /api/connections/<p>/status      box side: bin/connection-probe.sh stores
//                                       its observation in `connection.<p>.status`.
//                                       No coord write row names it, so a browser
//                                       gets the proxy's 405. No audit row.
//
// THE ROWS ARE THE ONES THE ADAPTERS READ. bin/lib/tracker.sh reads
// `tracker_adapter.<p>`; bin/lib/tracker/linear.sh reads
// `tracker_linear.<p>.team|label|states`; bin/lib/tracker/jira.sh reads
// `tracker_jira.<p>.write_projects|read_projects|comment_projects|label|status_map`;
// routes/webhooks.js reads `webhook_route.<vendor>.<team or key, lowercased>`.
// The validation below is the readers' own, so a row this route writes is a
// row the reader accepts.
//
// NO CREDENTIAL IS STORED HERE. A body key that names a secret, or a string
// value with a token shape, is refused with the env var to set instead. The
// value is never echoed back and never written to any row.

import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName, REGISTRY_SEED_ACTOR, WAKE_REPO_RE } from "../lib/core.js";
import { CONFIG_KINDS, configChangeStmts } from "../lib/config-changes.js";
import { invalidateSettings } from "../lib/settings-cache.js";

export const ADAPTERS = ["linear", "jira", "board", "github-issues"];
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;          // routes/projects.js
const SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/;         // routes/settings.js
const LINEAR_TEAM_RE = /^[A-Z][A-Z0-9_]{0,9}$/;      // bin/lib/tracker/linear.sh
const JIRA_KEY_RE = /^[A-Z][A-Z0-9_]{1,9}$/;          // bin/lib/tracker/jira.sh
const LABEL_RE = /^[A-Za-z0-9_.:-]{1,100}$/;          // both adapters
const SMAP_ENTRY_RE = /^[a-z0-9_-]+=[^=]+$/;          // _trk_jira_smap_ok
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
const VAR_NAME_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
// The settings PUT's own value cap (routes/settings.js), so every row written
// here is also a row PUT /api/settings could write. Not a new limit.
const SETTING_VALUE_MAX = 256;
// The bound on the stored status JSON, in bytes: the settings row
// `connection.status_max_bytes` (seeded by schema.d/202610271900-bh-7924-
// connection-status-knob.sql). It stops a broken probe from writing an
// unbounded row. The row is in the `connection.` range loadState already
// reads, so the knob costs no statement. A value that is not an integer in
// 2048..16384 is ignored, never clamped, and 2048 is the fallback. The floor
// is what bin/connection-probe.sh relies on: its error is at most 1500 JSON
// bytes (CONNECTION_PROBE_ERROR_MAX, 40..1500), and the other fields are
// under 550, so a well-formed probe always fits.
export const CONNECTION_STATUS_MAX_KEY = "connection.status_max_bytes";
export const CONNECTION_STATUS_MAX_BYTES = 2048; // fallback of connection.status_max_bytes
const CONNECTION_STATUS_MAX_LIMIT = 16384;
export function statusMaxBytes(rows) {
  const v = rows.get(CONNECTION_STATUS_MAX_KEY);
  if (typeof v !== "string" || !/^\d+$/.test(v.trim())) return CONNECTION_STATUS_MAX_BYTES;
  const n = Number(v.trim());
  return n >= CONNECTION_STATUS_MAX_BYTES && n <= CONNECTION_STATUS_MAX_LIMIT ? n : CONNECTION_STATUS_MAX_BYTES;
}

// The PUT fields, in audit order. `adapter` is the tracker_adapter row and
// `webhook_route` the repo of the route row; the rest are the adapter rows.
const FIELDS = ["adapter", "team", "label", "states", "write_projects", "read_projects",
  "comment_projects", "status_map", "webhook_route"];
const LINEAR_ONLY = new Set(["team", "states"]);
const JIRA_ONLY = new Set(["write_projects", "read_projects", "comment_projects", "status_map"]);

// ── Token refusal ──────────────────────────────────────────────────────────
// Body keys that name a credential (compared lowercased).
const SECRET_KEYS = new Set(["api_key", "apikey", "token", "api_token", "access_token", "refresh_token",
  "secret", "client_secret", "password", "private_key", "webhook_secret", "linear_api_key",
  "jira_api_token", "linear_webhook_secret", "jira_webhook_secret", "github_token", "gh_token"]);
// The token shapes: `sk-` from the ProjectAccounts rule (case-insensitive, so
// `SK-1` is refused as that rule does), then the Linear, Atlassian and GitHub
// formats. Tested per word, so `review=ATATT…` and `owner/ghp_…` are caught
// while `SK`, `SKY`, `ai-build` and `hotfix` pass.
const TOKEN_RES = [/^sk-/i, /^lin_api_/, /^lin_oauth_/, /^ATATT/, /^ghp_/, /^gho_/, /^ghs_/, /^github_pat_/];
export function tokenShaped(value) {
  if (typeof value !== "string") return false;
  return value.split(/[^A-Za-z0-9_-]+/).some((w) => w && TOKEN_RES.some((re) => re.test(w)));
}
const ENV_VAR = { linear: "LINEAR_API_KEY", jira: "JIRA_API_TOKEN", board: "INTERNAL_API_TOKEN", "github-issues": "GH_TOKEN" };

// The env var a refusal names: the key itself when the sender used an env
// var name, else the adapter's credential variable.
function refusal(project, adapter, key) {
  const named = key && /^[A-Z][A-Z0-9_]*$/.test(key) ? key : null;
  const envVar = named || ENV_VAR[adapter] || "the tracker API key";
  const p = SLUG_RE.test(project || "") ? project : "<project>";
  return json(400, {
    error: `API keys are not stored here. Set ${envVar} in env/${p}.env on the box that runs ${p}.`,
    env_var: named || ENV_VAR[adapter] || null,
  });
}

// The first secret key or token-shaped string value in the body, or null.
// Top-level keys, and string values at any depth (credentialVars' KEYS are
// variable names by design, so nested keys are not tested).
function findSecret(body) {
  for (const k of Object.keys(body)) if (SECRET_KEYS.has(k.toLowerCase())) return { key: k };
  const walk = (v) => {
    if (typeof v === "string") return tokenShaped(v);
    if (v && typeof v === "object") return Object.values(v).some(walk);
    return false;
  };
  for (const k of Object.keys(body)) if (walk(body[k])) return { key: null };
  return null;
}

// ── The read: ONE batch, two statements ────────────────────────────────────
// The settings read is three PK range scans on settings.key (W8 proves the
// plan): `connection.*`, `tracker_*` and `webhook_route.*`.
export const CONNECTION_SETTINGS_SQL =
  "SELECT key, value, updated_at FROM settings WHERE (key >= 'connection.' AND key < 'connection/') " +
  "OR (key >= 'tracker_' AND key < 'tracker`') OR (key >= 'webhook_route.' AND key < 'webhook_route/')";
const PROJECTS_SQL = "SELECT project, repo, board_api_prefix FROM projects";

async function loadState(env) {
  await ensureTable(env, "projects");
  const [p, s] = await env.DB.batch([env.DB.prepare(PROJECTS_SQL), env.DB.prepare(CONNECTION_SETTINGS_SQL)]);
  const projects = new Map(((p && p.results) || []).map((r) => [r.project, r]));
  const rows = new Map(((s && s.results) || []).map((r) => [r.key, r.value == null ? null : String(r.value)]));
  const names = new Set(projects.keys());
  for (const k of rows.keys()) {
    const m = /^tracker_adapter\.(.+)$/.exec(k);
    if (m && SLUG_RE.test(m[1])) names.add(m[1]);
  }
  return { projects, rows, names };
}

// The tracker_adapter decision (bin/lib/tracker.sh): the row wins; no row is
// fleet.conf column 4, read here from the registry's board_api_prefix (null is
// `-`, github-issues; anything else is board). A row with another value is
// refused, as the shell refuses it: adapter null plus the reason.
function adapterOf(state, project) {
  const v = state.rows.get(`tracker_adapter.${project}`);
  if (v != null) {
    if (ADAPTERS.includes(v)) return { adapter: v, adapterSource: "row" };
    return { adapter: null, adapterSource: "row",
      adapterError: `settings row tracker_adapter.${project} is ${v.slice(0, 40)}, not one of: ${ADAPTERS.join(" ")}` };
  }
  const reg = state.projects.get(project);
  if (!reg) return { adapter: null, adapterSource: null, adapterError: `no tracker_adapter row and no registry row for ${project}` };
  return { adapter: reg.board_api_prefix == null ? "github-issues" : "board", adapterSource: "registry" };
}

// The current connection fields of a project, raw row values (null = no row).
function fieldsOf(state, project, adapter) {
  const r = (k) => state.rows.get(k) ?? null;
  const f = {
    adapter: r(`tracker_adapter.${project}`),
    team: r(`tracker_linear.${project}.team`),
    label: adapter === "jira" ? r(`tracker_jira.${project}.label`) : r(`tracker_linear.${project}.label`),
    states: r(`tracker_linear.${project}.states`),
    write_projects: r(`tracker_jira.${project}.write_projects`),
    read_projects: r(`tracker_jira.${project}.read_projects`),
    comment_projects: r(`tracker_jira.${project}.comment_projects`),
    status_map: r(`tracker_jira.${project}.status_map`),
  };
  const route = routeOf(state, adapter, f);
  f.webhook_route = route ? route.repo : null;
  return f;
}

// The route-row candidates for a project: the Linear team, or every Jira
// write key, lowercased (routes/webhooks.js keys on the prefix). Never the
// read keys: read_projects is a read allowlist (bin/lib/tracker/jira.sh), so
// a read key can be another project's write key, and its route row is that
// project's row. Route rows are global per vendor key.
function routeKeys(adapter, f) {
  if (adapter === "linear") return f.team ? [`webhook_route.linear.${f.team.toLowerCase()}`] : [];
  if (adapter === "jira") {
    const keys = `${f.write_projects || ""}`.split(/\s+/).filter(Boolean);
    return [...new Set(keys)].map((k) => `webhook_route.jira.${k.toLowerCase()}`);
  }
  return [];
}
function routeOf(state, adapter, f) {
  for (const key of routeKeys(adapter, f)) {
    const repo = state.rows.get(key);
    if (repo != null) return { key, repo };
  }
  return null;
}

function connectionRow(state, project) {
  const a = adapterOf(state, project);
  const f = fieldsOf(state, project, a.adapter);
  const row = {
    project,
    adapter: a.adapter,
    adapterSource: a.adapterSource,
    ...(a.adapterError ? { adapterError: a.adapterError } : {}),
    status: null,
    team: f.team,
    label: f.label,
    states: f.states,
    jira: { write_projects: f.write_projects, read_projects: f.read_projects,
      comment_projects: f.comment_projects, status_map: f.status_map },
    webhookRoute: routeOf(state, a.adapter, f),
  };
  const raw = state.rows.get(`connection.${project}.status`);
  if (raw != null) {
    try {
      const v = JSON.parse(raw);
      if (v && typeof v === "object" && !Array.isArray(v)) row.status = v;
      else row.statusError = "status row is not a JSON object";
    } catch {
      row.statusError = "status row is not JSON";
    }
  }
  return row;
}

// ── PUT validation ─────────────────────────────────────────────────────────
// -> {fields: {name: value}} with only the fields sent (trimmed, "" = delete),
// or {error}. Control characters are refused before any trim (projects.js).
function checkFields(b, adapter) {
  const out = {};
  for (const k of FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) continue;
    const v = b[k];
    if (typeof v !== "string") return { error: `${k} must be a string` };
    if (/[\x00-\x1f\x7f]/.test(v)) return { error: `${k} must be one line` };
    out[k] = v.trim();
  }
  if ("adapter" in out && out.adapter !== "" && !ADAPTERS.includes(out.adapter)) {
    return { error: `adapter must be one of: ${ADAPTERS.join(", ")}` };
  }
  for (const [k, v] of Object.entries(out)) {
    if (v === "" || k === "adapter") continue;
    if (v.length > SETTING_VALUE_MAX) return { error: `${k} must be at most ${SETTING_VALUE_MAX} characters` };
    if (LINEAR_ONLY.has(k) && adapter !== "linear") return { error: `${k} applies only to a linear adapter` };
    if (JIRA_ONLY.has(k) && adapter !== "jira") return { error: `${k} applies only to a jira adapter` };
    if ((k === "label" || k === "webhook_route") && adapter !== "linear" && adapter !== "jira") {
      return { error: `${k} applies only to a linear or jira adapter` };
    }
    if (k === "team" && !LINEAR_TEAM_RE.test(v)) return { error: "team must be a Linear team key (A-Z then up to 9 A-Z, 0-9 or _)" };
    if (k === "label" && !LABEL_RE.test(v)) return { error: "label must be 1-100 letters, digits or _ . : -" };
    if (k === "states") {
      let o = null;
      try { o = JSON.parse(v); } catch { o = null; }
      if (!o || typeof o !== "object" || Array.isArray(o)) return { error: "states must be a JSON object" };
    }
    if (JIRA_ONLY.has(k) && k !== "status_map") {
      const keys = v.split(/\s+/).filter(Boolean);
      if (!keys.every((x) => JIRA_KEY_RE.test(x))) return { error: `${k} must be space-separated Jira project keys` };
      out[k] = keys.join(" ");
    }
    if (k === "status_map" && !v.split(";").every((e) => SMAP_ENTRY_RE.test(e))) {
      return { error: "status_map must be alias=Status;alias=Status (lowercase aliases)" };
    }
    if (k === "webhook_route" && !WAKE_REPO_RE.test(v)) return { error: "webhook_route must be an owner/repo slug" };
  }
  return { fields: out };
}

const upsertStmt = (env, key, value, actor, t) => env.DB.prepare(
  `INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?1,?2,NULL,?3,?4)
   ON CONFLICT(key) DO UPDATE SET value=?2, actor=?3, updated_at=?4`,
).bind(key, value, actor, t);
const deleteStmt = (env, key) => env.DB.prepare("DELETE FROM settings WHERE key=?1").bind(key);

export const routes = [
  [
    "GET", "/api/connections",
    async ({ env, t }) => d1Guarded("settings", async () => {
      const state = await loadState(env);
      const connections = [...state.names].sort().map((p) => connectionRow(state, p));
      return json(200, {
        connections,
        webhookSecrets: { linear: Boolean(env.LINEAR_WEBHOOK_SECRET), jira: Boolean(env.JIRA_WEBHOOK_SECRET) },
        as_of: t,
      });
    }),
  ],

  [
    "PUT", "/api/connections",
    async ({ env, t, body }) => d1Guarded("settings", async () => {
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      const project = typeof b.project === "string" ? b.project.trim().toLowerCase() : "";
      const state = await loadState(env);
      const sentAdapter = typeof b.adapter === "string" && ADAPTERS.includes(b.adapter.trim()) ? b.adapter.trim() : null;
      // The token refusal runs first, before any other answer can quote the body.
      const secret = findSecret(b);
      if (secret) return refusal(project, sentAdapter || adapterOf(state, project).adapter, secret.key);
      if (typeof b.project === "string" && /[\x00-\x1f\x7f]/.test(b.project)) return json(400, { error: "project must be one line" });
      if (!SLUG_RE.test(project)) return json(400, { error: "project must be 1-64 lowercase letters, digits or dashes" });
      if (typeof b.reason !== "string" || !b.reason.trim()) return json(400, { error: "reason required" });
      if (b.reason.trim().length > 512) return json(400, { error: "reason must be <= 512 chars" });
      const actor = typeof b.actor === "string" && b.actor.trim() ? b.actor.trim().slice(0, 128) : "api";
      if (actor === REGISTRY_SEED_ACTOR) return json(400, { error: `actor '${REGISTRY_SEED_ACTOR}' is reserved` });
      if (!state.names.has(project)) return json(404, { error: "unknown project" });

      const cur = adapterOf(state, project);
      // The adapter after this PUT: the one sent, else "" falls back to the
      // registry answer, else the current one.
      let adapter = cur.adapter;
      if (typeof b.adapter === "string" && b.adapter.trim() === "") {
        adapter = adapterOf({ ...state, rows: new Map([...state.rows].filter(([k]) => k !== `tracker_adapter.${project}`)) }, project).adapter;
      } else if (sentAdapter) adapter = sentAdapter;
      const checked = checkFields(b, adapter);
      if (checked.error) return json(400, { error: checked.error });
      const sent = checked.fields;

      const was = fieldsOf(state, project, cur.adapter);
      const labelRow = (a) => (a === "jira" ? `tracker_jira.${project}.label` : `tracker_linear.${project}.label`);
      const keyOf = {
        adapter: `tracker_adapter.${project}`,
        team: `tracker_linear.${project}.team`,
        label: labelRow(adapter),
        states: `tracker_linear.${project}.states`,
        write_projects: `tracker_jira.${project}.write_projects`,
        read_projects: `tracker_jira.${project}.read_projects`,
        comment_projects: `tracker_jira.${project}.comment_projects`,
        status_map: `tracker_jira.${project}.status_map`,
      };
      // The rows after the write, then the route key from those rows.
      const next = new Map(state.rows);
      for (const [k, v] of Object.entries(sent)) {
        if (k === "webhook_route") continue;
        if (v === "") next.delete(keyOf[k]); else next.set(keyOf[k], v);
      }
      if ("webhook_route" in sent) {
        const nextF = fieldsOf({ ...state, rows: next }, project, adapter);
        const keys = routeKeys(adapter, nextF);
        // A route row is global per vendor key, so two projects can name one
        // team or key. A row that points at a repo other than this project's
        // registry repo (and other than the value sent) is refused unless the
        // body sets route_override: true. The audit row names only this
        // project, so a silent change to that row would hide it from the other.
        const ownRepo = state.projects.get(project)?.repo ?? null;
        const guard = (key, value) => {
          const curRepo = next.get(key);
          if (curRepo == null || curRepo === ownRepo || curRepo === value || b.route_override === true) return null;
          return json(409, { error: `${key} routes to ${curRepo}, not ${ownRepo || project}'s repo; send route_override: true to change it`,
            key, repo: curRepo });
        };
        if (sent.webhook_route === "") {
          const hit = keys.find((k) => next.has(k));
          if (hit) {
            const refused = guard(hit, null);
            if (refused) return refused;
            next.delete(hit);
          }
        } else {
          if (!keys.length) {
            return json(400, { error: "webhook_route needs a Linear team or a Jira write project key first" });
          }
          const refused = guard(keys[0], sent.webhook_route);
          if (refused) return refused;
          next.set(keys[0], sent.webhook_route);
        }
      }
      // Only the rows that change are written.
      const stmts = [];
      const changed = [];
      for (const k of new Set([...state.rows.keys(), ...next.keys()])) {
        const a = state.rows.has(k) ? state.rows.get(k) : null;
        const z = next.has(k) ? next.get(k) : null;
        if (a === z) continue;
        if (!SETTING_KEY_RE.test(k)) return json(400, { error: `settings key ${k.slice(0, 80)} is longer than 64 characters` });
        stmts.push(z === null ? deleteStmt(env, k) : upsertStmt(env, k, z, actor, t));
        changed.push(k);
      }
      const after = fieldsOf({ ...state, rows: next }, project, adapter);
      if (stmts.length) {
        await ensureTable(env, "config_changes");
        await env.DB.batch([
          ...stmts,
          ...configChangeStmts(env, CONFIG_KINDS.CONNECTION, project, was, after, FIELDS, actor, b.reason, t),
        ]);
        invalidateSettings(env);
      }
      const fresh = await loadState(env);
      return json(200, { connection: connectionRow(fresh, project), changed: changed.sort(), as_of: t });
    }),
  ],

  [
    "POST", /^\/api\/connections\/([a-z0-9][a-z0-9-]{0,63})\/status$/,
    async ({ env, t, body, m }) => d1Guarded("settings", async () => {
      const project = m[1];
      const b = body && typeof body === "object" && !Array.isArray(body) ? body : {};
      const state = await loadState(env);
      const secret = findSecret(b);
      if (secret) {
        return refusal(project, ADAPTERS.includes(b.adapter) ? b.adapter : adapterOf(state, project).adapter, secret.key);
      }
      if (!state.names.has(project)) return json(404, { error: "unknown project" });
      if (!SETTING_KEY_RE.test(`connection.${project}.status`)) {
        return json(400, { error: `settings key connection.${project}.status is longer than 64 characters` });
      }
      if (b.adapter !== null && !ADAPTERS.includes(b.adapter)) return json(400, { error: `adapter must be null or one of: ${ADAPTERS.join(", ")}` });
      if (typeof b.ok !== "boolean") return json(400, { error: "ok must be a boolean" });
      if (typeof b.checkedAt !== "string" || !ISO_RE.test(b.checkedAt)) return json(400, { error: "checkedAt must be an ISO UTC time" });
      if (b.error !== null && typeof b.error !== "string") return json(400, { error: "error must be a string or null" });
      const cv = b.credentialVars;
      if (!cv || typeof cv !== "object" || Array.isArray(cv)) return json(400, { error: "credentialVars must be an object" });
      for (const [k, v] of Object.entries(cv)) {
        if (!VAR_NAME_RE.test(k)) return json(400, { error: "credentialVars keys must be env var names" });
        if (v !== "present" && v !== "missing") return json(400, { error: "credentialVars values must be present or missing" });
      }
      let box = "";
      if (b.box !== undefined && b.box !== null) {
        box = laneName(b.box);
        if (!box) return json(400, { error: "box must match [A-Za-z0-9._-]{1,64}" });
      }
      const a = adapterOf(state, project);
      const route = routeOf(state, a.adapter, fieldsOf(state, project, a.adapter));
      const secretEnv = a.adapter === "linear" ? env.LINEAR_WEBHOOK_SECRET : a.adapter === "jira" ? env.JIRA_WEBHOOK_SECRET : undefined;
      const status = {
        adapter: b.adapter, ok: b.ok, checkedAt: b.checkedAt, error: b.error, credentialVars: cv,
        webhookRoute: route ? route.key : null,
        webhookSecret: a.adapter === "linear" || a.adapter === "jira" ? (secretEnv ? "present" : "missing") : null,
      };
      const value = JSON.stringify(status);
      const bytes = new TextEncoder().encode(value).length;
      const max = statusMaxBytes(state.rows);
      if (bytes > max) return json(413, { error: `status over ${max} bytes`, bytes, max });
      // An observation, not a decision: no config_changes row.
      await env.DB.prepare(
        `INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?1,?2,NULL,?3,?4)
         ON CONFLICT(key) DO UPDATE SET value=?2, actor=?3, updated_at=?4`,
      ).bind(`connection.${project}.status`, value, box ? `box:${box}` : "box", t).run();
      invalidateSettings(env);
      return json(200, { project, status, as_of: t });
    }),
  ],
];

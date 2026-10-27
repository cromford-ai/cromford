// onboarding-tracker routes — BH-7936 (onboarding UI wave 3): the "Test and
// connect" step of the tracker sheets (console-ui/src/ui/TrackerSheets.js).
//
//   POST /api/onboarding/tracker-test   {project, kind, fields}  -> 202 {test_id}
//        kind is linear | jira | board. The fields are checked (below), then
//        put in ONE KV row `onb-tracker:<test_id>` with a 900 s TTL, and only
//        then is a hub-probe row filed: probe `tracker-test`, ticket_key
//        `onb-<test_id>`, args [kind, test_id]. The hub-probe lane
//        (bin/hub-probe.sh) runs the test on the hub
//        (bin/lib/hub-probes/tracker-test.sh). No field value is ever written
//        to D1: the hub-probe row carries the kind and the random id only.
//        A 400 writes nothing. No ONBOARD_KV binding, or a put that throws, is
//        503 with no D1 statement. A hub-probe insert that fails deletes the
//        KV row and answers 503.
//   GET  /api/onboarding/tracker-test/<test_id>?project=  -> {state, error?, detail?, note?}
//        state is pending (pending or claimed), ok (pass) or error (fail or
//        rejected, `error` is the hub's output, which the probe scrubbed). 404
//        for no row. It reads hub_probe_requests only, so it never holds a
//        field value.
//   POST /api/onboarding/tracker-secret/take  {nonce}  -> 200 {kind, project, fields} | 404
//        The hub's one-time read: get, then delete. The console's coord proxy
//        has no row for it, so a browser cannot call it (405 there).
//
// TEMPORARY (decision 3 of BH-7936): the KV row is the stand-in for the secret
// envelope of onboarding wave 4, which replaces it.
//
// THE KV NAMESPACE. ONBOARD_KV is not bound in worker/jobs/wrangler.jsonc yet:
// a binding needs a real namespace id, and that is an operator step. Until it
// is bound every route here answers 503 "onboarding KV not bound".
import { json } from "../lib/http.js";
import { laneName, str } from "../lib/core.js";
import { routes as hubProbeRoutes } from "./hub-probe.js";

export const KV_TTL_S = 900;
export const KV_PREFIX = "onb-tracker:";
export const PROBE = "tracker-test";
const ID_RE = /^[0-9a-f]{32}$/;
const FIELD_MAX = 512;
const SECRET_MIN = 8;

// The fields of each sheet (decision 1). `secret` fields are the credential:
// at least SECRET_MIN characters, never echoed. The sheet's table is
// console-ui/src/lib/tracker-sheets.js TRACKER_FIELDS; the two must agree.
export const KIND_FIELDS = {
  linear: { api_key: "secret", team: "team", label: "label" },
  jira: { site: "site", email: "email", api_token: "secret", project_key: "jira_key", status_map: "status_map" },
  board: { api_base: "api_base", token: "secret" },
};

// The read the GET makes: the (project, ticket_key, probe) prefix of the
// table's UNIQUE(project, ticket_key, probe, args_hash) index.
export const TEST_LOOKUP_SQL =
  "SELECT status, output, note FROM hub_probe_requests WHERE project=?1 AND ticket_key=?2 AND probe=?3 ORDER BY id DESC LIMIT 1";

// A literal IPv4 host in a private, loopback, link-local, CGNAT or "this
// network" range. A board base must be a public https host.
function privateV4(host) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

function apiBaseError(v) {
  let u;
  try { u = new URL(v); } catch { return "api_base must be an https:// URL"; }
  if (u.protocol !== "https:") return "api_base must be an https:// URL";
  if (u.username || u.password || u.search || u.hash) return "api_base must not carry a user, a query or a fragment";
  const host = u.hostname.toLowerCase();
  if (host.startsWith("[") || host === "localhost" || host.endsWith(".localhost") || privateV4(host) || !host.includes(".")) {
    return "api_base must be a public host";
  }
  return null;
}

// The check for one field of one type: null when it is fine, else the error.
function fieldError(name, type, v) {
  switch (type) {
    case "secret": return v.length >= SECRET_MIN ? null : `${name} must be at least ${SECRET_MIN} characters`;
    case "team": return /^[A-Za-z0-9_]{1,16}$/.test(v) ? null : "team must be a Linear team key (letters, digits, _)";
    case "label": return /^[^\s"\\][^"\\]{0,99}$/.test(v) ? null : "label must be 1-100 characters with no quote or backslash";
    case "site": return /^[a-z0-9-]+\.atlassian\.net$/.test(v) ? null : "site must be <name>.atlassian.net";
    case "email": return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? null : "email must be an email address";
    case "jira_key": return /^[A-Z][A-Z0-9_]{1,9}$/.test(v) ? null : "project_key must be a Jira project key (CROM)";
    case "status_map":
      return v.split(";").every((e) => /^[a-z0-9_-]+=[^=;]+$/.test(e)) ? null : "status_map must be alias=Status;alias=Status";
    case "api_base": return apiBaseError(v);
    default: return `${name} is not a field`;
  }
}

// {fields} trimmed and checked, or {error}. The site is lower-cased first.
export function checkFields(kind, raw) {
  const spec = KIND_FIELDS[kind];
  if (!spec) return { error: "kind must be linear, jira or board" };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "fields must be an object" };
  for (const k of Object.keys(raw)) if (!(k in spec)) return { error: `${k} is not a ${kind} field` };
  const fields = {};
  for (const [name, type] of Object.entries(spec)) {
    const v0 = raw[name];
    if (v0 === undefined || v0 === null) return { error: `${name} is required` };
    if (typeof v0 !== "string") return { error: `${name} must be a string` };
    let v = v0.trim();
    if (!v) return { error: `${name} is required` };
    if (v.length > FIELD_MAX) return { error: `${name} must be at most ${FIELD_MAX} characters` };
    if (type === "site") v = v.toLowerCase();
    const e = fieldError(name, type, v);
    if (e) return { error: e };
    fields[name] = v;
  }
  return { fields };
}

function newId() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

// The ledger's own insert (POST /api/hub-probe), so its checks, its args_hash
// and its SQL stay in one place.
const fileHubProbe = hubProbeRoutes.find(([m, p]) => m === "POST" && p === "/api/hub-probe")[2];

const NO_KV = { error: "onboarding KV not bound (ONBOARD_KV); the operator step in docs/notes/2026-10-22-bh-7936-tracker-test.md" };

export const routes = [
  [
    "POST", "/api/onboarding/tracker-test",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const project = laneName(b.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const kind = typeof b.kind === "string" ? b.kind : "";
      const c = checkFields(kind, b.fields);
      if (c.error) return json(400, { error: c.error });
      const kv = env && env.ONBOARD_KV;
      if (!kv) return json(503, NO_KV);
      const id = newId();
      const key = KV_PREFIX + id;
      try {
        await kv.put(key, JSON.stringify({ kind, project, fields: c.fields }), { expirationTtl: KV_TTL_S });
      } catch {
        return json(503, { error: "onboarding KV put failed" });
      }
      let res = null;
      try {
        res = await fileHubProbe({
          env, t,
          body: { project, ticket_key: `onb-${id}`, probe: PROBE, args: [kind, id], requested_by: str(b.actor, 64) || "console" },
        });
      } catch {
        res = null;
      }
      if (!res || res.status !== 200) {
        try { await kv.delete(key); } catch { /* the TTL removes it in 15 minutes */ }
        return json(503, { error: "the hub-probe request could not be filed" });
      }
      return json(202, { test_id: id });
    },
  ],

  [
    "GET", /^\/api\/onboarding\/tracker-test\/([0-9a-f]{32})$/,
    async ({ env, url, m }) => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      let row;
      try {
        row = await env.DB.prepare(TEST_LOOKUP_SQL).bind(project, `onb-${m[1]}`, PROBE).first();
      } catch {
        return json(503, { error: "hub_probe_requests not readable" });
      }
      if (!row) return json(404, { error: "no tracker test with that id for that project" });
      if (row.status === "pass") return json(200, { state: "ok", detail: row.output || "" });
      if (row.status === "fail" || row.status === "rejected") {
        return json(200, { state: "error", error: row.output || `the test ${row.status === "rejected" ? "was rejected" : "failed"}` });
      }
      return json(200, { state: "pending", note: row.note || null });
    },
  ],

  [
    "POST", "/api/onboarding/tracker-secret/take",
    async ({ env, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const nonce = typeof b.nonce === "string" && ID_RE.test(b.nonce) ? b.nonce : "";
      if (!nonce) return json(400, { error: "nonce must be 32 lower-case hex" });
      const kv = env && env.ONBOARD_KV;
      if (!kv) return json(503, NO_KV);
      const key = KV_PREFIX + nonce;
      let v;
      try { v = await kv.get(key); } catch { return json(503, { error: "onboarding KV read failed" }); }
      if (v === null || v === undefined) return json(404, { error: "no onboarding credential for that nonce (expired or already taken)" });
      try { await kv.delete(key); } catch { return json(503, { error: "onboarding KV delete failed" }); }
      let row;
      try { row = JSON.parse(v); } catch { row = null; }
      if (!row || typeof row !== "object") return json(503, { error: "onboarding KV row is not JSON" });
      return json(200, { kind: row.kind, project: row.project, fields: row.fields });
    },
  ],
];

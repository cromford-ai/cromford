// onboarding repo-create routes — BH-8001 (BH-7935.4): the console's "New repo
// from a template" panel (console-ui/src/screens/onboard/NewRepoPanel.js). The
// worker has no GitHub credential, so it files a repo-create hub-probe row; the
// hub makes the repo through bin/lib/hub-probes/repo-create.sh when it claims
// the row.
//
//   POST /api/onboarding/repo-create  header Idempotency-Key, body {owner, name, template}
//        400 before any D1 statement: a key that is not [A-Za-z0-9._:-]{8,128}
//        (idempotency_key_required, the rule of POST /api/onboarding/runs), an
//        owner/name parseRepoSlug refuses or would change (no trim, no .git
//        strip, no URL), a template not in nextjs | worker | empty.
//        The key names the create: probe_id = the first 16 hex of
//        sha256(key), ticket_key = onb-create-<probe_id>. One lookup on that
//        ticket_key: a row with the same args -> 202 {probe_id} and nothing
//        filed; a row with other args -> 409 {error:"idempotency_key_reused",
//        probe_id}. No row -> fileScreenProbe (the ledger's own insert) ->
//        202 {probe_id}. A row that could not be filed -> 503.
//   GET  /api/onboarding/repo-create/templates
//        {templates:{nextjs, worker, empty}}: true when the settings row
//        onboarding.template.<key> holds a bare owner/repo. Booleans only: the
//        template repo name never leaves the worker. A failed read is all false.
//   GET  /api/onboarding/repo-create/<probe_id>
//        {state:"pending", slug:null, error:null[, note]} | {state:"ok",
//        slug:"<owner>/<name>", error:null} | {state:"error", slug:null, error}.
//        The slug is the row's filed args, never the probe output. 404 no row.
import { d1Guarded, json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { canonical } from "./hub-probe.js";
import { fileScreenProbe, parseRepoSlug } from "./onboarding-repo.js";

const PROJECT = "onboarding";
const PROBE = "repo-create";
export const TEMPLATE_KEYS = ["nextjs", "worker", "empty"];
const KEY_RE = /^[A-Za-z0-9._:-]{8,128}$/;
// The cut of onboarding-repo.js ERROR_MAX, so both screens show the same length.
const ERROR_MAX = 200;
const BARE_RE = /^[^/]+\/[^/]+$/;

// The one read the POST and the GET make: the (project, ticket_key, probe)
// prefix of the table's UNIQUE(project, ticket_key, probe, args_hash) index.
export const LOOKUP_SQL =
  "SELECT status, output, note, args_json FROM hub_probe_requests WHERE project=?1 AND ticket_key=?2 AND probe=?3 ORDER BY id DESC LIMIT 1";

async function probeIdFor(key) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
}

// [owner, name, template] when the body is exactly a creatable repo, else null.
export function createArgs(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const { owner, name, template } = body;
  if (typeof owner !== "string" || typeof name !== "string" || typeof template !== "string") return null;
  if (!TEMPLATE_KEYS.includes(template)) return null;
  const p = parseRepoSlug(`${owner}/${name}`);
  if (!p || p.owner !== owner || p.repo !== name) return null;
  return [owner, name, template];
}

// A template row value the hub will accept: a bare owner/repo, nothing else.
export function templateSet(value) {
  const v = typeof value === "string" ? value : "";
  const p = BARE_RE.test(v) ? parseRepoSlug(v) : null;
  return !!p && p.slug === v;
}

const lookup = (env, h) => env.DB.prepare(LOOKUP_SQL).bind(PROJECT, `onb-create-${h}`, PROBE).first();

function stateOf(row) {
  if (row.status === "pending" || row.status === "claimed") {
    return { state: "pending", slug: null, error: null, ...(row.note ? { note: row.note } : {}) };
  }
  if (row.status === "pass") {
    const [owner, name] = JSON.parse(row.args_json);
    return { state: "ok", slug: `${owner}/${name}`, error: null };
  }
  const text = String(row.output ?? "").trim().slice(0, ERROR_MAX);
  return { state: "error", slug: null, error: text || `the create ${row.status === "rejected" ? "was rejected" : "failed"}` };
}

export const routes = [
  [
    "POST", "/api/onboarding/repo-create",
    async ({ env, req, t, body }) => {
      const key = (req.headers.get("idempotency-key") || "").trim();
      if (!KEY_RE.test(key)) return json(400, { error: "idempotency_key_required" });
      const args = createArgs(body);
      if (!args) return json(400, { error: "owner and name must be a GitHub owner and repo name; template must be nextjs, worker or empty" });
      const h = await probeIdFor(key);
      return d1Guarded("hub_probe_requests", async () => {
        const prior = await lookup(env, h);
        if (prior) {
          if (prior.args_json !== canonical(args)) return json(409, { error: "idempotency_key_reused", probe_id: h });
          return json(202, { probe_id: h });
        }
        const row = await fileScreenProbe(env, { t, ticket_key: `onb-create-${h}`, probe: PROBE, args });
        if (!row) return json(503, { error: "the hub-probe request could not be filed" });
        return json(202, { probe_id: h });
      });
    },
  ],

  [
    "GET", "/api/onboarding/repo-create/templates",
    async ({ env }) => {
      let byKey = new Map();
      try {
        byKey = (await settingsRows(env)).byKey;
      } catch {
        byKey = new Map();
      }
      const templates = {};
      for (const k of TEMPLATE_KEYS) {
        const row = byKey.get(`onboarding.template.${k}`);
        templates[k] = templateSet(row ? row.value : "");
      }
      return json(200, { templates });
    },
  ],

  [
    "GET", /^\/api\/onboarding\/repo-create\/([0-9a-f]{16})$/,
    async ({ env, m }) => d1Guarded("hub_probe_requests", async () => {
      const row = await lookup(env, m[1]);
      if (!row) return json(404, { error: "no repo create with that id" });
      return json(200, stateOf(row));
    }),
  ],
];

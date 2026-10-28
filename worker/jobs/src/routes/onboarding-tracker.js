// onboarding-tracker routes — BH-7936 (onboarding UI wave 3): the "Test and
// connect" step of the tracker sheets (console-ui/src/ui/TrackerSheets.js).
//
//   POST /api/onboarding/tracker-test   {project, kind, envelope_id}  -> 202 {test_id}
//        kind is linear | jira | board. The sheet first sealed its fields to
//        the hub key and stored them as a secret envelope (POST
//        /api/secrets/envelope, scope `tracker:<kind>:<project>`, BH-7968).
//        This route reads that envelope row once by its primary key and
//        accepts it only when it exists, has not expired and has exactly the
//        scope `tracker:<kind>:<project>`; an AI-account envelope is refused,
//        so a tracker test can never burn it. Then it files a hub-probe row:
//        probe `tracker-test`, ticket_key `onb-<test_id>`, args
//        [kind, envelope_id]. The hub-probe lane (bin/hub-probe.sh) runs the
//        test on the hub (bin/lib/hub-probes/tracker-test.sh), which reads the
//        envelope (the read deletes it) and checks the fields. This worker
//        never sees a field value. A 400 writes nothing. A D1 read that throws
//        or a hub-probe insert that fails is 503; the envelope then expires.
//   GET  /api/onboarding/tracker-test/<test_id>?project=  -> {state, error?, detail?, note?}
//        state is pending (pending or claimed), ok (pass) or error (fail or
//        rejected, `error` is the hub's output, which the probe scrubbed). 404
//        for no row. It reads hub_probe_requests only, so it never holds a
//        field value.
import { json } from "../lib/http.js";
import { laneName, str } from "../lib/core.js";
import { routes as hubProbeRoutes } from "./hub-probe.js";

export const PROBE = "tracker-test";
export const TRACKER_KINDS = ["linear", "jira", "board"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// The envelope scope of one tracker test. The console writes the same string
// (console-ui/src/lib/tracker-sheets.js trackerScope).
export const trackerScope = (kind, project) => `tracker:${kind}:${project}`;

// The one read the POST makes: the envelope row by its primary key.
export const ENVELOPE_CHECK_SQL = "SELECT scope, expires_at FROM secret_envelopes WHERE id = ?1";

// The read the GET makes: the (project, ticket_key, probe) prefix of the
// table's UNIQUE(project, ticket_key, probe, args_hash) index.
export const TEST_LOOKUP_SQL =
  "SELECT status, output, note FROM hub_probe_requests WHERE project=?1 AND ticket_key=?2 AND probe=?3 ORDER BY id DESC LIMIT 1";

function newId() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

// The ledger's own insert (POST /api/hub-probe), so its checks, its args_hash
// and its SQL stay in one place.
const fileHubProbe = hubProbeRoutes.find(([m, p]) => m === "POST" && p === "/api/hub-probe")[2];

export const routes = [
  [
    "POST", "/api/onboarding/tracker-test",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      const project = laneName(b.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const kind = typeof b.kind === "string" ? b.kind : "";
      if (!TRACKER_KINDS.includes(kind)) return json(400, { error: "kind must be linear, jira or board" });
      const envelopeId = typeof b.envelope_id === "string" ? b.envelope_id : "";
      if (!UUID_RE.test(envelopeId)) return json(400, { error: "envelope_id must be a lower-case UUID" });
      let row;
      try {
        row = await env.DB.prepare(ENVELOPE_CHECK_SQL).bind(envelopeId).first();
      } catch {
        return json(503, { error: "secret_envelopes not readable" });
      }
      if (!row) return json(400, { error: "no envelope with that id (expired or already read): test again" });
      if (!(String(row.expires_at) > t)) return json(400, { error: "the envelope expired: test again" });
      if (row.scope !== trackerScope(kind, project)) return json(400, { error: `the envelope is not for ${trackerScope(kind, project)}` });
      const id = newId();
      let res = null;
      try {
        res = await fileHubProbe({
          env, t,
          body: { project, ticket_key: `onb-${id}`, probe: PROBE, args: [kind, envelopeId], requested_by: str(b.actor, 64) || "console" },
        });
      } catch {
        res = null;
      }
      if (!res || res.status !== 200) return json(503, { error: "the hub-probe request could not be filed" });
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
];

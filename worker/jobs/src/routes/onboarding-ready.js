// onboarding ready route — BH-8744 (BH-7935.3): the Ready screen's one read.
//
//   GET /api/onboarding/ready/<project>   (project ^[a-z0-9][a-z0-9-]{0,18}$,
//       the name hp_validate takes; any other path is the router's 404)
//     200 {project, repo, prod, box, tailnet, account, fly,
//          facts:{state, vercel?, qa_account?, migration_token?, checked_at?}}
//     404 {error:"unknown_project"} when the registry has no row. Nothing is
//         filed then, so a junk name never makes hub work.
//
// Round trip 1 is ONE env.DB.batch of 3 primary-key reads: the registry row
// (with its box's tailnet), the settings rows (account.<project> and the two
// knobs) and the project's routing row. Round trip 2 runs two reads in
// parallel: fileScreenProbe files this bucket's ready-facts row (the hub runs
// bin/lib/hub-probes/ready-facts.sh on it) and the history read finds the
// newest finished row. 6 statements; 3 for an unknown project.
//
// facts.state: the newest finished (pass or fail) ready-facts row of this
// project, read back twice the stale window:
//   none -> pending; fail -> fail; pass older than stale_s -> stale;
//   pass with three boolean keys -> pass and the booleans; any other pass
//   output -> fail (unparseable never reads as connected).
// The history reaches back 2 x stale_s so a pass between 1x and 2x the window
// shows as stale. A row's finish is never before its bucket start, so a reach
// of 1 x stale_s could never hold a stale row.
//
// `fly` comes from the routing row (builder fly1 or pool), the store
// PUT /api/routing writes and bin/lib/jobs/routing.sh syncs to the boxes. A
// pause_flags row named builder-fly-<p> is NOT read: bin/flag.sh refuses to
// write that name, so it is not where Fly routing lives.
//
// The tailnet IP never leaves the worker: `tailnet` is a boolean.
import { json, d1Guarded } from "../lib/http.js";
import { fileScreenProbe } from "./onboarding-repo.js";

const PROBE = "ready-facts";
const KEY_PREFIX = "onb-ready-";
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const FACT_KEYS = ["vercel", "qa_account", "migration_token"];
// The routing.builder values that build on Fly (schema.d/0000-base.sql).
const FLY_BUILDERS = new Set(["fly1", "pool"]);
// The settings row onboarding.ready_bucket_s (seed schema.d/202611020040-
// bh-8744-onboarding-ready-knobs.sql); this is its fallback when the row is
// absent or not an integer 60..3600.
const BUCKET_KEY = "onboarding.ready_bucket_s";
const BUCKET_DEFAULT = 300;
// The settings row onboarding.ready_stale_s (same seed file); this is its
// fallback when the row is absent or not an integer 300..86400.
const STALE_KEY = "onboarding.ready_stale_s";
const STALE_DEFAULT = 3600;

// An integer knob in [min, max], else the fallback.
function knob(value, min, max, fallback) {
  const v = value == null ? "" : String(value).trim();
  const n = /^\d{1,6}$/.test(v) ? Number(v) : NaN;
  return n >= min && n <= max ? n : fallback;
}

const pad10 = (n) => String(n).padStart(10, "0");
const keyAt = (s) => KEY_PREFIX + pad10(s);

// The three booleans of a pass row's output, or null.
function factsOf(output) {
  try {
    const o = JSON.parse(String(output ?? ""));
    if (!o || typeof o !== "object" || Array.isArray(o)) return null;
    return FACT_KEYS.every((k) => typeof o[k] === "boolean") ? o : null;
  } catch {
    return null;
  }
}

const finished = (row) => row && (row.status === "pass" || row.status === "fail") && row.finished_at;

// The facts answer from the current row and the newest finished history row.
export function readyFacts(current, history, nowS, staleS) {
  const rows = [current, history].filter(finished);
  rows.sort((a, b) => (a.finished_at < b.finished_at ? 1 : a.finished_at > b.finished_at ? -1 : 0));
  const f = rows[0];
  if (!f) return { state: "pending" };
  const checked_at = f.finished_at;
  if (f.status === "fail") return { state: "fail", checked_at };
  const facts = factsOf(f.output);
  if (!facts) return { state: "fail", checked_at };
  if (Date.parse(checked_at) / 1000 < nowS - staleS) return { state: "stale", checked_at };
  return { state: "pass", vercel: facts.vercel, qa_account: facts.qa_account, migration_token: facts.migration_token, checked_at };
}

export const routes = [
  [
    "GET", /^\/api\/onboarding\/ready\/([a-z0-9][a-z0-9-]{0,18})$/,
    async ({ env, t, m }) => d1Guarded("registry_projects", async () => {
      const project = m[1];
      const [reg, sets, route] = await env.DB.batch([
        env.DB.prepare(
          "SELECT p.repo, p.prod, p.box, COALESCE(b.tailnet_ip, '') <> '' AS tailnet "
          + "FROM registry_projects p LEFT JOIN registry_boxes b ON b.box = p.box WHERE p.project = ?1"
        ).bind(project),
        env.DB.prepare("SELECT key, value FROM settings WHERE key IN (?1, ?2, ?3)")
          .bind(`account.${project}`, BUCKET_KEY, STALE_KEY),
        env.DB.prepare("SELECT builder FROM routing WHERE project = ?1").bind(project),
      ]);
      const p = (reg.results || [])[0];
      if (!p) return json(404, { error: "unknown_project" });
      const byKey = new Map((sets.results || []).map((r) => [r.key, r.value]));
      const bucketS = knob(byKey.get(BUCKET_KEY), 60, 3600, BUCKET_DEFAULT);
      const staleS = knob(byKey.get(STALE_KEY), 300, 86400, STALE_DEFAULT);
      const nowS = Math.floor(Date.parse(t) / 1000);
      const args = [project];
      const [current, hist] = await Promise.all([
        fileScreenProbe(env, { t, ticket_key: keyAt(Math.floor(nowS / bucketS) * bucketS), probe: PROBE, args }),
        env.DB.prepare(
          "SELECT status, output, finished_at FROM hub_probe_requests "
          + "WHERE project = 'onboarding' AND ticket_key >= ?1 AND ticket_key <= ?2 AND probe = ?3 AND args_json = ?4 "
          + "AND status IN ('pass', 'fail') ORDER BY finished_at DESC LIMIT 1"
        ).bind(keyAt(Math.max(0, nowS - 2 * staleS)), keyAt(nowS), PROBE, JSON.stringify(args)).first(),
      ]);
      const account = byKey.has(`account.${project}`) ? String(byKey.get(`account.${project}`)) : null;
      const rt = (route.results || [])[0];
      return json(200, {
        project,
        repo: REPO_RE.test(String(p.repo ?? "")) ? p.repo : null,
        prod: p.prod ?? null,
        box: p.box ?? null,
        tailnet: Number(p.tailnet) === 1,
        account,
        fly: !!(rt && FLY_BUILDERS.has(String(rt.builder))),
        facts: readyFacts(current, hist, nowS, staleS),
      });
    }),
  ],
];

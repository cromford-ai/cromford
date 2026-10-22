// onboarding routes — BH-7934.0 (#7947): create and read an onboarding run.
// Tables: worker/jobs/schema.d/202610220114-bh-7934-onboarding-runs.sql.
// Writer: the console's onboarding form. Readers: GET below, the runner lane
// (BH-7934.2), the retry and cancel actions (BH-7934.3) and the tracker check
// (BH-7936). test/route-table.d/bh-7934-onboarding.txt pins this route list.
//
// POST /api/onboarding/runs  header Idempotency-Key, body
//   {repo, project, tracker, box, prefix?, base?, prod?}
//   The key names the run: id = ob_ + the first 20 hex of sha256(key). Each
//   field is trimmed and checked; the first bad one is a 400 that names it and
//   writes nothing. Every other body key is dropped, so a field such as token
//   is never stored. inputs_json is the kept fields in sorted key order, so a
//   replay with reordered keys gives the same bytes. ONE batch inserts the run
//   (state queued) and its 7 queued steps and reads the run back; the steps
//   insert runs only when the stored inputs are this request's, so a reused
//   key with another tracker adds no step.
//   201 {id, state, created:true}; 200 {id, state, created:false} on a replay;
//   409 {error:"idempotency_key_reused", id} when the key holds other inputs.
//
// GET /api/onboarding/runs/:id
//   200 {run, steps}, the steps by ord. 404 {error:"not_found"}. One batch of
//   two primary-key / index reads.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

export const ONBOARDING_STATIONS = ["register", "prompt", "label", "box", "clone", "smoke", "ready"];
const KEY_RE = /^[A-Za-z0-9._:-]{8,128}$/;
const ACTOR_RE = /^[A-Za-z0-9@._-]{1,64}$/;

// The station list for a tracker: label is tracker when the tracker is not
// github-issues.
export function stationsFor(tracker) {
  return ONBOARDING_STATIONS.map((s) => (s === "label" && tracker !== "github-issues" ? "tracker" : s));
}

const prodOk = (v) => {
  if (v === "-") return true;
  if (v.length > 300 || !v.startsWith("https://")) return false;
  try { new URL(v); return true; } catch { return false; }
};
// [field, required, check]. Wave 1 onboards on the shared box only.
const FIELDS = [
  ["repo", true, (v) => /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(v)],
  ["project", true, (v) => /^[a-z0-9][a-z0-9-]{0,39}$/.test(v)],
  ["tracker", true, (v) => v === "github-issues" || v === "board"],
  ["box", true, (v) => v === "shared"],
  ["prefix", false, (v) => /^[A-Z][A-Z0-9]{1,9}$/.test(v)],
  ["base", false, (v) => /^[A-Za-z0-9._/-]{1,100}$/.test(v) && !v.includes("..")],
  ["prod", false, prodOk],
];

// {inputs} with the kept fields in sorted key order, or {error, field}.
export function canonicalInputs(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "invalid_body" };
  const kept = {};
  for (const [field, required, ok] of FIELDS) {
    const raw = body[field];
    const v = typeof raw === "string" ? raw.trim() : raw;
    if (v === undefined || v === null || v === "") {
      if (required) return { error: "invalid_field", field };
      continue;
    }
    if (typeof v !== "string" || !ok(v)) return { error: "invalid_field", field };
    kept[field] = v;
  }
  const inputs = {};
  for (const k of Object.keys(kept).sort()) inputs[k] = kept[k];
  return { inputs };
}

export async function runIdFor(key) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return "ob_" + [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 20);
}

export const RUN_READ_SQL =
  "SELECT id, project, repo, inputs_json, state, station, created_by, created_at, updated_at, finished_at FROM onboarding_runs WHERE id = ?1";
export const STEPS_READ_SQL =
  "SELECT station, ord, state, started_at, finished_at, retries, error_code, log_excerpt FROM onboarding_steps WHERE run_id = ?1 ORDER BY ord";

const guarded = (fn) => (ctx) =>
  d1Guarded("onboarding_runs", async () => {
    await ensureTable(ctx.env, "onboarding_runs");
    await ensureTable(ctx.env, "onboarding_steps");
    return fn(ctx);
  });

export const routes = [
  [
    "POST", "/api/onboarding/runs",
    guarded(async ({ env, req, t, body }) => {
      const key = (req.headers.get("idempotency-key") || "").trim();
      if (!KEY_RE.test(key)) return json(400, { error: "idempotency_key_required" });
      const c = canonicalInputs(body);
      if (c.error) return json(400, c.field ? { error: c.error, field: c.field } : { error: c.error });
      const { inputs } = c;
      const inputsJson = JSON.stringify(inputs);
      const id = await runIdFor(key);
      const actor = (req.headers.get("x-harness-actor") || "").trim();
      const createdBy = ACTOR_RE.test(actor) ? actor : null;
      const steps = stationsFor(inputs.tracker);
      const [ins, , back] = await env.DB.batch([
        env.DB.prepare(
          `INSERT OR IGNORE INTO onboarding_runs (id, project, repo, inputs_json, state, station, created_by, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, 'queued', NULL, ?5, ?6, ?6)`
        ).bind(id, inputs.project, inputs.repo, inputsJson, createdBy, t),
        env.DB.prepare(
          `INSERT OR IGNORE INTO onboarding_steps (run_id, station, ord, state)
           SELECT ?1, s.column1, s.column2, 'queued'
           FROM (VALUES (?3, 1), (?4, 2), (?5, 3), (?6, 4), (?7, 5), (?8, 6), (?9, 7)) AS s
           WHERE EXISTS (SELECT 1 FROM onboarding_runs WHERE id = ?1 AND inputs_json = ?2)`
        ).bind(id, inputsJson, ...steps),
        env.DB.prepare("SELECT inputs_json, state FROM onboarding_runs WHERE id = ?1").bind(id),
      ]);
      const row = back && back.results && back.results[0];
      if (!row) return json(503, { error: "onboarding_runs: the run did not read back" });
      if (row.inputs_json !== inputsJson) return json(409, { error: "idempotency_key_reused", id });
      const created = Number((ins && ins.meta && ins.meta.changes) || 0) === 1;
      return json(created ? 201 : 200, { id, state: row.state, created });
    }),
  ],
  [
    "GET", /^\/api\/onboarding\/runs\/(ob_[0-9a-f]{20})$/,
    guarded(async ({ env, m }) => {
      const id = m[1];
      const [runs, steps] = await env.DB.batch([
        env.DB.prepare(RUN_READ_SQL).bind(id),
        env.DB.prepare(STEPS_READ_SQL).bind(id),
      ]);
      const r = runs && runs.results && runs.results[0];
      if (!r) return json(404, { error: "not_found" });
      const { inputs_json, ...run } = r;
      return json(200, { run: { ...run, inputs: JSON.parse(inputs_json) }, steps: (steps && steps.results) || [] });
    }),
  ],
];

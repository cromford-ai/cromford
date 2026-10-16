// harness-jobs — the shared half of the worker: constants, the transition
// graphs, the SQL the routes bind, and the pure functions the console and the
// tests import (computeDora, computeAnchored, decorateLane, …).
//
// Split out of src/index.js by BH-1195, verbatim. Everything here was already
// module-level in that file; the only edits are the `export` keyword in front
// of each declaration and the one extra `../` on the lanes.json import. The
// routes under src/routes/ import from here, src/index.js re-exports the names
// its callers have always imported from it, and nothing in this file knows a
// route exists.
import { json } from "./http.js";
import SCHEMA_SQL from "#schema-sql";
import { createdTablesFrom } from "./created-tables.js";
import { activeFleetFlags } from "./harness-flags.js";
import { rawDb } from "./d1-retry.js";
import { sqlIdent } from "./sql-ident.js";

export const OPEN_STATUS = "running";


// catalog/lanes.json — the registry of every automatic lane in the fleet
// (BH-1132). Imported so the deploy BAKES it in: a page that asked a box for
// the registry would show nothing whenever that box was the thing that was
// down, and the registry has to be readable exactly when the fleet is not.
// It ships with the bundle, so /api/lanes/registry is always the version that
// was deployed, never a file a half-finished rsync left behind.
import LANES_REGISTRY from "../../../../catalog/lanes.json" with { type: "json" };
// Re-exported so a route module can bind the registry the deploy baked in.
export { LANES_REGISTRY };


// A legal knob key, defined ONCE: the read route and the write route ask the
// same question, so a key that can be written can always be read back.
export const SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/;

// unsettableKnob(key[, registry]) — the ENV name when `lane.<id>[.<project>].<env
// lowercased>` (with or without a trailing `.unlimited`) resolves to a registry
// knob carrying `settable: false`, else null. BH-1511.1 added the `libs` scope:
// `lib.<id>.<env lowercased>` is checked against `registry.libs` the same way,
// because a shared library's command/host/path is exactly as dangerous to write
// from a page as a lane's. The key is lowercased by construction, so the match
// is on the lowercased env name; a key that matches no registered knob is not
// this function's business and comes back null. `registry` is for tests.
export function unsettableKnob(key, registry = LANES_REGISTRY) {
  if (typeof key !== "string") return null;
  const scope = key.startsWith("lane.") ? "lanes" : key.startsWith("lib.") ? "libs" : null;
  if (!scope) return null;
  const pfx = scope === "lanes" ? "lane" : "lib";
  const bare = key.endsWith(".unlimited") ? key.slice(0, -".unlimited".length) : key;
  for (const l of (registry[scope] || [])) {
    const id = String(l.id || "");
    if (!id || !bare.startsWith(`${pfx}.${id}.`)) continue;
    const rest = bare.slice(`${pfx}.${id}.`.length);
    for (const k of (l.knobs || [])) {
      if (k.settable !== false || !k.env) continue;
      const low = String(k.env).toLowerCase();
      // lane-wide (`lane.<id>.<env>`) or project-scoped (`lane.<id>.<proj>.<env>`)
      if (rest === low || (rest.endsWith(`.${low}`) && !rest.slice(0, rest.length - low.length - 1).includes("."))) {
        return k.env;
      }
    }
  }
  return null;
}

// THE REGISTRY SEED (BH-1511.1). Every registered knob with a static default is
// mirrored into `settings` so the table is the complete record an operator
// reads and edits in the console. The rows carry REGISTRY_SEED_ACTOR, and
// bin/lib/lane-gate.sh ranks a row with that actor BELOW the env and the
// registry — so seeding changes no running lane. An operator's edit (any other
// actor) makes the row theirs, and from then on the seed never touches it.
export const REGISTRY_SEED_ACTOR = "registry-seed";

// ?1 key ?2 value ?3 note ?4 actor (REGISTRY_SEED_ACTOR) ?5 updated_at.
// A missing row is inserted; a row the SEED owns follows the registry when its
// default moved; a row anyone else wrote is left exactly as it is; an unchanged
// seed row is not rewritten, so a second seed reports 0 changes.
export const SEED_REGISTRY_SQL =
  `INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?1,?2,?3,?4,?5)
   ON CONFLICT(key) DO UPDATE SET value=excluded.value, note=excluded.note, updated_at=excluded.updated_at
   WHERE settings.actor = ?4 AND settings.value <> excluded.value`;

// ?1 key ?2 actor (REGISTRY_SEED_ACTOR). An orphan is a seed-owned row whose
// knob is no longer in the registry (renamed, removed, default set to null):
// left in place it would go on showing last month's default on the console.
// The actor guard is IN the statement, so a key an operator owns can never be
// deleted by the seed whatever list the caller computed.
export const PRUNE_SEED_SQL = `DELETE FROM settings WHERE key=?1 AND actor=?2`;

// seedRegistryPlan(rows, existing) -> what the seed WOULD do, for
// `harness-ctl seed-registry --dry-run` (review round 2 of #1565). The same
// three guards as SEED_REGISTRY_SQL + PRUNE_SEED_SQL, evaluated over rows read
// once: an absent key is an insert; a seed-owned key whose value moved is an
// update; a key any other actor holds is never in the plan; a seed-owned key
// no longer registered is a prune.
export function seedRegistryPlan(rows, existing) {
  const have = new Map((existing || []).map((r) => [r.key, r]));
  const plan = { rows: rows.length, insert: [], update: [], prune: [], operator_owned: 0, unchanged: 0 };
  for (const r of rows) {
    const cur = have.get(r.key);
    if (!cur) plan.insert.push(r.key);
    else if (cur.actor !== REGISTRY_SEED_ACTOR) plan.operator_owned += 1;
    else if (String(cur.value) !== r.value) plan.update.push({ key: r.key, from: String(cur.value), to: r.value });
    else plan.unchanged += 1;
  }
  const keep = new Set(rows.map((r) => r.key));
  for (const e of (existing || [])) {
    // BH-2564: `conf.*` rows belong to the caps seed, never to this one.
    if (e.actor === REGISTRY_SEED_ACTOR && !keep.has(e.key) && !e.key.startsWith("conf.")) plan.prune.push(e.key);
  }
  return plan;
}

// registrySeedRows(registry) -> [{key, value, note}] — the settable knobs, lanes
// then libs, whose default is a real value. A null/empty default is "unset is
// meaningful" and the PUT route refuses an empty value anyway; a settable:false
// knob is a command/host/path the PUT route refuses; a resolver knob has no env
// name to key on. Hub-level keys only: a project row is always an operator's.
export function registrySeedRows(registry) {
  const out = [];
  for (const [scope, pfx] of [["lanes", "lane"], ["libs", "lib"]]) {
    for (const l of (registry?.[scope] || [])) {
      for (const k of (l.knobs || [])) {
        if (!k.env || k.settable === false || k.default === null || k.default === undefined) continue;
        const value = String(k.default).trim();
        if (!value || value.length > 256) continue;
        const key = `${pfx}.${l.id}.${String(k.env).toLowerCase()}`;
        if (!SETTING_KEY_RE.test(key)) continue;
        const note = `registry default (catalog/lanes.d${scope === "libs" ? "/_lib.json" : `/${l.id}.json`}) — ${k.note || k.env}`.slice(0, 512);
        out.push({ key, value, note });
      }
    }
  }
  return out;
}


// THE FLOOR AND THE TIER ARE ONE NUMBER PER STAGE FAMILY, defined once here.
//
// MAX COST, NOT TARGET COST (the operator 2026-08-27; restated 2026-08-30, "lets change
// our max cost per PR it's too low"). A job's budget_usd is a RUNAWAY TRIPWIRE,
// not an allowance. It exists so a looping session is stoppable — never so a
// legitimate build is judged for costing what the work costs. Nothing in this
// system treats under-spend as good.
//
// The old build tier was $10.50, derived back when a build was smaller. Honest
// build jobs now run ~$15-25: project-2 TK-206 spent $16.46 doing everything right
// and still read as "over budget" in the watchdog line and on the console,
// which is a measurement bug, not a cost problem. So the build family floors at
// $50 — roughly 2x the top of the honest range, far enough above it that
// MEETING this number is evidence of a runaway rather than of a big ticket.
//
// This is the LEDGER's fuse — the number a job row carries and every "spent $X
// of $Y" readout is judged against. bin/agent-call.sh keeps its own, higher
// per-STAGE fuse (150 / 50 / 25) for the runner CLI's --max-budget-usd and
// floors whatever it reads from here, so these numbers can never lower that
// bound.
//
// Two things bind VERBATIM, skipping this floor, because both are a human
// saying "this exact number, on purpose": an operator env override
// (AGENT_CALL_BUDGET_USD*) on the file side, and a budget_cap_flags row marked
// explicit=1 here. Real spend control stays the daily burn ceiling and the
// token ceilings — never this.
export function stageFloor(stage) {
  switch (stage) {
    // Build family: the stages of a PR. `takeover` adopts someone's branch and
    // finishes it, which is build-shaped money, so it is named here for the
    // same reason bin/agent-call.sh names it — a hand-launched session must not
    // be funded by an accident of the catch-all.
    case "plan": case "execute": case "review": case "fix": case "revise":
    case "takeover":
      return 50;
    // Product family: one artifact or one round of thinking, not a whole PR.
    case "ideate": case "prd": case "mockup": case "signals":
    case "synth": case "preplan": case "map":
      return 20;
    // Misc, incl. `probe` — one question.
    default:
      return 10;
  }
}

// The tier IS the floor, exactly as `fl` is in bin/agent-call.sh's _budget_for:
// what a lane gets when no catalog row matches must be the same number a
// matched row can never fall below, or "budgeted" and "unbudgeted" would fund
// the same work differently. A missing catalog degrades to the lane's TIER,
// never to the smallest number — flooring a build lane at the misc figure
// silently reinstates exactly the truncation the manifest exists to prevent.
export const tierDefault = stageFloor;

// The ONE derivation of dollars-from-ceiling, mirroring bin/agent-call.sh:
// input priced at $15/M plus an output allowance of 15% of the ceiling at
// $75/M, floored at the STAGE FAMILY's fuse. Generous on purpose — a bound that
// bites normal work is a correctness regression, not a saving. The floor used
// to be a flat $3 for every stage, which priced a whole build lane off a
// ceiling that only describes one call.
export function usdForCeiling(tokens, stage) {
  const b = (tokens / 1e6) * 15 + ((tokens * 0.15) / 1e6) * 75;
  return Math.round(Math.max(b, stageFloor(stage)) * 100) / 100;
}

// Lane keys are <stage>/<project|*>/<runner|*>. The ladder below is
// agent-call.sh's specificity rule spelled out: project (the workload)
// outweighs runner (the executor), most specific wins. A lane must never be
// budgeted against one ceiling and measured against another.
export function laneCandidates(lane) {
  const parts = String(lane).split("/");
  const stage = parts[0] || "";
  // An empty segment means "unset" as surely as a missing one — a caller that
  // builds the lane from an env var that happens to be blank must not land on a
  // key that can never match.
  const project = parts[1] || "*";
  const runner = parts[2] || "*";
  const out = [];
  const add = (p, r) => { const k = `${stage}/${p}/${r}`; if (!out.includes(k)) out.push(k); };
  add(project, runner);
  add(project, "*");
  add("*", runner);
  add("*", "*");
  return { stage, candidates: out };
}

// Phase 7 rides the EXPLICIT flag along on the same query. bin/agent-call.sh
// floors every resolved cap at its stage family's max ("MAX COST, NOT TARGET
// COST"), and until now only an env override could bind verbatim. An explicit
// row is a human saying "this exact number, on purpose" and gets the same
// standing — resolved for the EXACT key that answered, never inherited down the
// ladder, because "on purpose" is a statement about one row and not about every
// lane that happens to fall back to it.
export async function resolveLane(env, lane) {
  const { stage, candidates } = laneCandidates(lane);
  for (const key of candidates) {
    const row = await env.DB.prepare(
      `SELECT b.lane, b.budget_usd, b.updated_at,
              COALESCE(f.explicit, 0) AS explicit, f.reason AS explicit_reason
         FROM budget_catalog b LEFT JOIN budget_cap_flags f ON f.lane = b.lane
        WHERE b.lane=?1`
    ).bind(key).first();
    if (row) {
      // A DERIVED row is floored at the stage family's fuse; an EXPLICIT row
      // binds verbatim (see stageFloor). Flooring here and not only at sync
      // time is what makes a row written by an older sync — or pushed as a raw
      // {entries:[...]} pair — obey today's policy instead of yesterday's.
      // The stored number rides along as derived_usd, so a floored row stays
      // explainable from the DB rather than from a guess about which branch
      // produced it.
      const explicit = Number(row.explicit) === 1 ? 1 : 0;
      const derived = Number(row.budget_usd);
      const floor = stageFloor(stage);
      const budget = explicit
        ? derived
        : (Number.isFinite(derived) ? Math.max(derived, floor) : floor);
      return {
        matched: row.lane, budget_usd: budget, derived_usd: derived,
        updated_at: row.updated_at,
        source: "catalog",
        explicit,
        explicit_reason: explicit ? (row.explicit_reason || null) : null,
      };
    }
  }
  return { matched: null, budget_usd: tierDefault(stage), derived_usd: null, source: "tier", explicit: 0, explicit_reason: null };
}

// Accepts EITHER the raw catalog/context-budgets.json ({lanes:[...]}, the shape
// a bin script can PUT with no transform) or explicit {entries:[{lane,
// budget_usd}]} pairs. Deriving from the raw manifest here rather than in the
// syncing script means every box reads numbers computed ONE way.
export function catalogEntries(body) {
  const map = new Map();
  // Strictest governs a genuine tie, exactly as the file-side resolver does.
  const put = (lane, usd) => {
    if (!lane || !Number.isFinite(usd)) return;
    const prev = map.get(lane);
    map.set(lane, prev === undefined ? usd : Math.min(prev, usd));
  };
  if (Array.isArray(body.entries)) {
    for (const e of body.entries) put(String(e.lane || ""), Number(e.budget_usd));
  }
  if (Array.isArray(body.lanes)) {
    for (const l of body.lanes) {
      const stage = String(l.stage || "").trim();
      if (!stage) continue;
      const project = l.project ? String(l.project) : "*";
      if (typeof l.ceiling_tokens === "number") {
        put(`${stage}/${project}/${l.runner ? String(l.runner) : "*"}`, usdForCeiling(l.ceiling_tokens, stage));
      }
      // A per-runner ceiling is a fact about the EXECUTOR (the xAI 200K cliff),
      // not about the job, so it cannot live in the job ceiling — it becomes
      // its own key so a grok lane resolves to grok's number and not the
      // lane's. Same outcome as the file resolver's runner_ceilings branch.
      for (const [runner, cap] of Object.entries(l.runner_ceilings || {})) {
        if (typeof cap === "number") put(`${stage}/${project}/${runner}`, usdForCeiling(cap, stage));
      }
    }
  }
  return map;
}

// Age in whole seconds between two ISO stamps, server clock on both sides.
// Box clocks drift (and a fly builder's is whatever the image booted with), so
// staleness is never computed from a time a box reported about itself.
export function ageSeconds(iso, now) {
  const a = Date.parse(iso || ""), b = Date.parse(now);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return Math.max(0, Math.round((b - a) / 1000));
}

// One row shape for every jobs read. `beat_age_s` is null when a claimant has
// never beaten (an older bin/ that predates phase 3, or a run killed before its
// first beat); `activity_age_s` is the honest "how long since ANY evidence of
// life", which falls back to the row's own updated_at so a pre-phase-3 client
// is still watched, just more coarsely.
export function decorateJob(row, now) {
  const beat = row.last_beat_at || null;
  const beatAge = beat ? ageSeconds(beat, now) : null;
  const updAge = ageSeconds(row.updated_at, now);
  return {
    ...row,
    last_beat_at: beat,
    beat_age_s: beatAge,
    activity_age_s: beatAge === null ? updAge : Math.min(beatAge, updAge === null ? beatAge : updAge),
    heartbeating: beat !== null,
    age_s: ageSeconds(row.created_at, now),
  };
}

// Phase 5 rides along as three correlated subselects rather than a second
// round trip: the console's row needs "which phase is it in" and, when the job
// failed, "which phase died", and asking per row would be an N+1 across an
// ocean. The failed-phase column is the LAST failed attempt, because a fix
// round can fail review twice and the second one is the one still standing.
export const JOBS_SELECT =
  `SELECT j.*, h.beat_at AS last_beat_at, h.box AS beat_box, h.note AS beat_note,
          (SELECT p.phase  FROM job_phases p WHERE p.job_id = j.id ORDER BY p.id DESC LIMIT 1) AS phase,
          (SELECT p.status FROM job_phases p WHERE p.job_id = j.id ORDER BY p.id DESC LIMIT 1) AS phase_status,
          (SELECT p.rc     FROM job_phases p WHERE p.job_id = j.id ORDER BY p.id DESC LIMIT 1) AS phase_rc,
          (SELECT p.phase  FROM job_phases p WHERE p.job_id = j.id AND p.status IN ('failed','orphaned')
            ORDER BY p.id DESC LIMIT 1) AS failed_phase,
          c.lane AS lane, c.attempts AS attempts, c.max_attempts AS max_attempts,
          c.next_attempt_at AS next_attempt_at, c.escalate_allowed AS escalate_allowed,
          c.reason AS retry_reason
     FROM jobs j LEFT JOIN job_heartbeats h ON h.job_id = j.id
                 LEFT JOIN job_claims c ON c.job_id = j.id`;

// The statuses a phase may be closed into. An allowlist because these strings
// drive the console's tone map, and a typo'd status that renders as "unknown"
// forever is worse than a 400 the fail-open caller quietly drops.
// `contract_unmet` (phase 7) is what a done-close becomes when the phase did not
// record the artifact its contract declares — see contractBreach below.
export const PHASE_STATUS = ["running", "done", "failed", "orphaned", "budget_stopped", "contract_unmet"];

// ── Transcripts (2026-08-29) ─────────────────────────────────────────────────
// The server's own tail cap, in bytes of the rendered body. bin/transcript-push.sh
// caps at the same number before it pushes, so this is normally a no-op — it is
// here because "the client already capped it" is an assumption about every
// version of bin/ any box in the fleet happens to be running, and a 3MB body
// landing in D1 is not a failure anyone would notice until the console got slow.
// A body over the cap is TAILED, never refused: the end of a session is where
// the failure is, and refusing the push would lose the whole thing to protect a
// number. The row then says truncated=1 and the console says so on screen.
export const TRANSCRIPT_MAX_BYTES = 150000;
// Metadata-only projection. The job detail page polls every 20s and can carry
// several attempts; shipping the bodies on that poll would make the drill-down
// pay megabytes to render a heading. Bodies are fetched one at a time, when a
// reader actually opens one.
export const TRANSCRIPT_INDEX_COLS =
  "job_id, phase_id, attempt, stage, runner, model, source, bytes, truncated, redactions, actor, created_at, updated_at";

// ── Pre-plans (BH-658) ───────────────────────────────────────────────────────
// A plan is 10-40KB; the cap is an order of magnitude above that so it only
// ever fires on something pathological. An over-cap plan is REFUSED (413), not
// tailed the way a transcript is: a transcript is a record of what happened and
// its tail is the useful half, while a plan is an INSTRUCTION — half of one is
// worse than none, because a builder would execute it.
export const PREPLAN_MAX_BYTES = 200000;
// The file list gets the same treatment, and for a sharper reason: a PREFIX of
// it is worse than an absent one. `preplan_check` marks a plan stale when main
// moved in a file the plan lists, and `bin/overlap-guard.sh` defers a build when
// a sibling claims a file — both only judge what they can see, so a list cut
// short fails OPEN on everything past the cut. Refused, never sliced.
export const PREPLAN_FILES_MAX_BYTES = 100000;
// How long a published pre-plan stays readable. Older than this is older than
// any queued build it could serve; the POST handler prunes past it.
export const PREPLAN_RETENTION_DAYS = 14;
// Metadata-only projection: the hub reads the index once per candidate per
// tick, and the plan bodies on that read would be megabytes an hour for a list
// of file paths. `planned_files` is IN it — that list is what the overlap guard
// came for.
export const PREPLAN_INDEX_COLS =
  "project, ticket_key, base_sha, ticket_fp, planned_files, bytes, box, created_at, updated_at";

// ── Child context packs (BH-3493) ────────────────────────────────────────────
// The wire cap for POST /api/context-packs, in UTF-8 bytes, mirrored by
// bin/lib/context-pack.sh. Over it the pack is REFUSED, never sliced, for the
// preplan reason: half a map misleads the planner that trusts it.
export const CONTEXT_PACK_MAX_BYTES = 64000;
// The POST answer is the row without its body; the GET is the row with it.
export const CONTEXT_PACK_INDEX_COLS =
  "project, ticket_key, parent_key, base_sha, bytes, box, created_at, updated_at";
export const CONTEXT_PACK_COLS = `${CONTEXT_PACK_INDEX_COLS}, pack_md`;

// ── Phase 7: ENFORCED STATE TRANSITIONS ──────────────────────────────────────
// Through phase 6 a status was whatever the last writer said it was. PATCH took
// any string, so a stale client, a replayed close or a hand-fired curl could
// walk a finished job back to `running` — reopening a claim the double-build
// guard had already released, and giving the console a row whose history cannot
// be true. The graph below is the whole rule, and it is DATA, so the spec doc
// and the worker cannot drift apart.
//
// TWO PROPERTIES ARE NOT NEGOTIABLE and both fall out of the table:
//   * `budget_stopped` and `done` are TERMINAL. KILL_STOP/BUDGET_STOP stays
//     terminal is a standing iron rule, and a job that already finished has
//     nothing left to become.
//   * `parked` cannot go straight to `done`. A parked job is one a human owns
//     now; it re-enters work through `running` (a retry pickup, a resume) and
//     finishes from there. Marking it done without that path is how a row comes
//     to claim an outcome no attempt produced.
//
// `orphaned` and `queued_for_retry` CAN go straight to done or failed, and that
// is not an inconsistency with the rule above. Both are inferences the watchdog
// drew from SILENCE — no heartbeat for N minutes — and a process that then
// reports its own completion is strictly better evidence than the absence that
// convicted it. Refusing that write would leave a finished build sitting under
// an orphan verdict forever, with its PR invisible to every screen. `parked` is
// the opposite case: a deliberate decision taken after the attempts ran out.
//
// `abandoned` (BH-2406) is an OPERATOR'S decision that this attempt is over
// for good, and it is terminal like `done`: nothing walks it back, so a build
// process still alive after the click cannot close it as done or failed. Any
// status a job can still leave may become it; `done` and `budget_stopped`
// cannot, because they already ended. The only way IN is the audited
// POST /api/jobs/:id/abandon (routes/job-abandon.js), which records who and
// why; PATCH /api/jobs/:id refuses it.
export const JOB_TRANSITIONS = {
  running:          ["running", "done", "failed", "parked", "budget_stopped", "orphaned", "queued_for_retry", "abandoned"],
  queued_for_retry: ["queued_for_retry", "running", "parked", "orphaned", "failed", "done", "abandoned"],
  parked:           ["parked", "running", "queued_for_retry", "orphaned", "abandoned"],
  orphaned:         ["orphaned", "running", "queued_for_retry", "parked", "done", "failed", "abandoned"],
  failed:           ["failed", "running", "queued_for_retry", "parked", "abandoned"],
  done:             ["done"],
  budget_stopped:   ["budget_stopped"],
  abandoned:        ["abandoned"],
};

export const PHASE_TRANSITIONS = {
  running:        ["running", "done", "failed", "orphaned", "budget_stopped", "contract_unmet"],
  failed:         ["failed", "running", "orphaned", "contract_unmet"],
  orphaned:       ["orphaned", "running", "failed"],
  // The repair path: record the artifact, close again, and the contract check
  // re-runs. That is why contract_unmet is not terminal — it is a phase waiting
  // for its evidence, not a phase that failed.
  contract_unmet: ["contract_unmet", "running", "done", "failed"],
  done:           ["done"],
  budget_stopped: ["budget_stopped"],
};

// The pre-claim build queue (2026-09-10). Shallower than the two above because
// a queue entry has one life: it waits, someone takes it, it ends. Every
// terminal state can go back to `queued` — a released push, a requeued fly
// attempt, a ticket genuinely built again next week — so nothing here is a trap;
// the value is entirely in refusing an UNKNOWN target status, because these
// strings drive the dispatcher and a typo that lands would park a build forever.
// `ready` and `dropped` are BH-1033's two additions, and they sit AHEAD of
// `queued` rather than beside it: a ready row is a ticket a triage session has
// not launched yet, so no dispatcher may claim it (every claim path selects
// `status='queued'` and none of them changed). `dropped` is the line a session
// consumed — it did not build and nothing is blocking it, and calling that
// `done` would put a lie in the one ledger the launch reads.
//
// ONLY A `ready` ROW MAY BE DROPPED. bin/queue-line-drop.sh runs while parallel
// triagers are launching builds, so the key it is dropping from the file may
// already be `claimed` on some box — dropping THAT would abandon a live build.
// The refusal is the guard, and the caller treats the 409 as "not mine".
//
// AND NO TERMINAL ROW WALKS BACK TO `ready`. `done` and `failed` still go to
// `queued` — that is how a died ticket is retried — but a `ready` hop would
// clear the reason bin/blocked-resolver.sh intakes parked builds by and the
// RESULT line it reads a rebuild's outcome from, leaving a finished build
// looking like work nobody has launched. `dropped → ready` stays: a consumed
// line ran nothing, so there is no ledger to lose.
export const QUEUE_TRANSITIONS = {
  ready:   ["ready", "queued", "claimed", "dropped", "done", "failed"],
  queued:  ["queued", "claimed", "done", "failed"],
  claimed: ["claimed", "queued", "done", "failed"],
  done:    ["done", "queued"],
  failed:  ["failed", "queued"],
  dropped: ["dropped", "ready", "queued"],
};

// The merge queue (2026-09-10). `dropped` is a fourth status beyond the three
// the brief named, and it earns its place: a PR dequeued because it is no longer
// OPEN has not landed and nothing is blocking it, so recording it as `landed`
// would put a lie in the one ledger a merge decision reads. Everything can go
// back to `queued` — a blocked PR is re-enqueued by the tier-2 sweep today, and
// a dropped one can be reopened — so nothing here is a trap either.
export const MERGE_TRANSITIONS = {
  queued:  ["queued", "blocked", "landed", "dropped"],
  blocked: ["blocked", "queued", "landed", "dropped"],
  landed:  ["landed", "queued"],
  dropped: ["dropped", "queued", "blocked", "landed"],
};

// Returns null when the move is legal, or the refusal to send back as a 409.
//
// THE ASYMMETRY IS DELIBERATE. An unknown TARGET is refused: these strings drive
// every screen and every gate, and a typo that lands as a permanent "unknown"
// state is worse than a 409 a fail-open caller drops. An unknown SOURCE is
// ALLOWED: it means a row was written by something this worker does not model
// yet, and refusing to let it move would strand it forever — the graph must
// never become the thing that makes a row unfixable.
export function checkTransition(graph, from, to, what) {
  if (!Object.prototype.hasOwnProperty.call(graph, to)) {
    return { error: `unknown ${what} status`, from, to, legal: Object.keys(graph) };
  }
  const legal = graph[from];
  if (!legal) return null;                     // source we do not model: allow
  if (legal.includes(to)) return null;
  return {
    error: `illegal ${what} transition`,
    from, to, legal,
    reason: `a ${what} in ${from} may only become ${legal.join(", ")} — ${from} -> ${to} is not a move this ledger records`,
  };
}

// ── Phase 7: OUTCOME CONTRACTS ───────────────────────────────────────────────
// Phases 5 and 6 recorded that a stage RAN and how it ended. Neither recorded
// what it left BEHIND, so a plan stage that exited 0 having written no plan
// file closed `done` exactly like one that did the work. A contract is a row
// saying "this phase must produce an artifact of this kind before it may close
// done", and phase_contracts SHIPS EMPTY — no row is no contract is today's
// behaviour, the same way retry_policies landed dark in phase 6.
//
// `pattern` is a SUBSTRING, not a regex, on purpose: a regex in an operator-
// edited config row is a way to put a catastrophic backtrack inside a worker
// that then times out every close in the fleet. Substring answers the thing
// this is actually for — "the ref must contain APPROVE", "must contain
// https://github.com/" — and cannot be weaponised by a typo.
export async function contractBreach(env, jobId, phaseName) {
  const c = await env.DB.prepare("SELECT * FROM phase_contracts WHERE phase=?1")
    .bind(phaseName).first();
  if (!c) return null;                         // no row, no contract
  const a = await env.DB.prepare(
    "SELECT * FROM job_artifacts WHERE job_id=?1 AND artifact_kind=?2"
  ).bind(jobId, c.artifact_kind).first();
  const ref = a ? String(a.artifact_ref || "").trim() : "";
  if (!ref) {
    return {
      contract: c, artifact_ref: null,
      reason: `phase ${phaseName} must record a ${c.artifact_kind} artifact before it can close done, and none was recorded`
        + (c.note ? ` (${c.note})` : ""),
    };
  }
  if (c.pattern && !ref.includes(String(c.pattern))) {
    return {
      contract: c, artifact_ref: ref.slice(0, 200),
      reason: `phase ${phaseName}'s ${c.artifact_kind} artifact does not contain ${JSON.stringify(String(c.pattern))}`,
    };
  }
  return null;
}

// ── Phase 7: PAUSE FLAGS BIND AT CLAIM TIME ──────────────────────────────────
// Phase 3 made pause flags rows and had the box RECONCILE a file from them, so
// a pause only landed where a box had run flag_sync recently and only on the
// readers that test that particular file. A fly builder that boots, claims and
// builds never reconciles anything. Phase 7 checks the rows inside the claim,
// where every box in the fleet passes through the same answer.
//
// THE FILE REMAINS THE FALLBACK, unchanged: bin/jobs-client.sh `flag_active`
// still reconciles and still answers from the file, so a worker outage leaves a
// box deciding exactly as it does today. This is an ADDITIONAL gate, never a
// replacement — and with no active pause row in either store (pause_flags, or
// harness_flags for the ported paused-* names, BH-4154) it refuses nothing.
//
// Broadest first, because when the whole fleet is paused that is the headline a
// human needs, not the lane rule underneath it.
export function pauseNames(job) {
  const slug = (s) => String(s || "").replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 96);
  const out = ["paused-all"];
  if (job.project) out.push(`paused-${slug(job.project)}`);
  if (job.box) out.push(`paused-box-${slug(job.box)}`);
  if (job.lane) out.push(`paused-lane-${slug(job.lane)}`);
  return out;
}

export async function checkPause(env, job) {
  const names = pauseNames(job);
  // BH-4154: each name from the store its name picks (activeFleetFlags):
  // paused-* from its fleet harness_flags row, or from pause_flags while no
  // such row exists. A D1 error throws to the claim route, which claims nothing.
  const active = await activeFleetFlags(env, names);
  if (active.length === 0) return null;
  // Report in the order the names were built, not the order SQLite returned.
  const hit = names.map((n) => active.find((r) => r.name === n)).find(Boolean);
  if (!hit) return null;
  return {
    scope: "pause",
    flag: hit.name,
    // Named as the ROW, with its table and time (BH-2643): "flags/<name>"
    // sent an investigation after box files.
    reason: `paused: ${hit.table} row ${hit.name} is active (updated ${hit.updated_at})`
      + (hit.reason ? ` — ${hit.reason}` : "")
      + (hit.actor ? ` (set by ${hit.actor})` : ""),
    // The keys this object has always carried, from either store.
    pause: { name: hit.name, active: 1, actor: hit.actor, reason: hit.reason, updated_at: hit.updated_at },
  };
}

// ── Phase 6: the DB decides ──────────────────────────────────────────────────
// Through phase 5 exactly one thing could refuse a claim, and it was written in
// this file: same project + ticket + kind, open, on another box. Everything else
// keeping two boxes off one piece of work was lockfiles and discipline, which is
// where the TK-66/67 double build slipped through. Phase 6 moves the rules into
// ROWS and checks them INSIDE the claim — one request, on one database every box
// shares, instead of each box consulting its own files and hoping.
//
// HOW ATOMIC, EXACTLY. The check and the write are one request, not one D1
// transaction: two first-claims landing in the same millisecond can still both
// pass. That window is milliseconds against the minutes-to-hours the file guards
// left open, and the one place a race would actually cost money — two boxes
// taking over the SAME queued retry row — is closed properly, with a
// compare-and-swap on the row's status. Saying which is which beats implying
// a guarantee this layer does not have.
//
// The one property that must survive: a scope with no matching row is
// UNLIMITED. Rules bind when the DB answers and never otherwise — the client is
// already fail-open (bin/jobs-client.sh), so an unreachable worker means work
// runs exactly as it does today. Availability must never gate work.
export const RULE_SCOPES = ["ticket", "repo", "box", "lane"];

// What `selector` means per scope, and what the peers of a claim are:
//   ticket  selector matches the PROJECT; peers are the same project + ticket_id
//           (any box, any kind unless the rule names one). This is the double
//           build class, and "the same ticket" is only meaningful inside a board.
//   repo    selector matches the project;  peers are every open row on it
//   box     selector matches the box name; peers are every open row on that box
//   lane    selector matches the lane;     peers are every open row in that lane
//
// Most specific wins, selector outranking kind — the same ladder budget_catalog
// lanes resolve on. Two ladders that disagree is how a rule binds somewhere
// nobody meant it to.
export function ruleFor(rules, scope, selector, kind) {
  const candidates = [
    [selector, kind], [selector, "*"], ["*", kind], ["*", "*"],
  ];
  for (const [s, k] of candidates) {
    const hit = rules.find((r) => r.scope === scope && r.selector === s && r.kind === k);
    if (hit) return hit;
  }
  return null;
}

// Count the open peers a rule governs and return the blocking rows. `id` is the
// claim being made and is always excluded: a re-claim of a row this caller
// already owns is idempotent, never a conflict with itself.
export async function scopePeers(env, scope, job) {
  const build = (sql, binds) => ({ sql, binds });
  const base = "SELECT j.id, j.box, j.kind, j.ticket_id FROM jobs j";
  switch (scope) {
    case "ticket":
      if (!job.ticket) return null;   // a ticketless row has no ticket peers
      return build(`${base} WHERE j.status=? AND j.project=? AND j.ticket_id=? AND j.id<>?`,
        [OPEN_STATUS, job.project, job.ticket, job.id]);
    case "repo":
      return build(`${base} WHERE j.status=? AND j.project=? AND j.id<>?`,
        [OPEN_STATUS, job.project, job.id]);
    case "box":
      return build(`${base} WHERE j.status=? AND j.box=? AND j.id<>?`,
        [OPEN_STATUS, job.box, job.id]);
    case "lane":
      if (!job.lane) return null;
      return build(
        `SELECT j.id, j.box, j.kind, j.ticket_id FROM jobs j JOIN job_claims c ON c.job_id=j.id
          WHERE j.status=? AND c.lane=? AND j.id<>?`,
        [OPEN_STATUS, job.lane, job.id]);
    default:
      return null;
  }
}

export const scopeSelector = (scope, job) =>
  scope === "box" ? job.box : scope === "lane" ? (job.lane || "") : job.project;

// The whole rule check, in one place, run inside POST /api/jobs before anything
// is written. Returns null when the claim may proceed, or the refusal to send
// back as a 409 — scope, the rule that bound, and the row that is holding it,
// because a refusal a human cannot explain is a refusal they will work around.
export async function checkRules(env, job) {
  const all = await env.DB.prepare("SELECT * FROM concurrency_rules").all();
  const rules = all.results || [];
  if (rules.length === 0) return null;      // no rows, no rules: unlimited
  for (const scope of RULE_SCOPES) {
    const rule = ruleFor(rules, scope, scopeSelector(scope, job), job.kind);
    if (!rule) continue;                    // no row for this scope: unlimited
    const q = await scopePeers(env, scope, job);
    if (!q) continue;                       // the scope does not apply to this claim
    let sql = q.sql, binds = q.binds.slice();
    if (rule.kind !== "*") { sql += " AND j.kind=?"; binds.push(rule.kind); }
    // D1 binds positionally with ?1..?n; the strings above use bare ? which the
    // driver numbers in order, so appending is safe.
    // sql-ident-ok: scopePeers returns literal SQL text; the scope values are ? binds
    const rows = await env.DB.prepare(`${sql} ORDER BY j.created_at ASC`).bind(...binds).all();
    const peers = rows.results || [];
    const max = Number(rule.max_concurrent);
    if (!Number.isFinite(max) || peers.length < max) continue;
    const holder = peers[0] || null;
    return {
      scope,
      rule: { scope: rule.scope, selector: rule.selector, kind: rule.kind, max_concurrent: max, note: rule.note || null },
      running: peers.length,
      reason: `${scope} max ${max} already running`
        + (holder ? `: ${holder.id} on ${holder.box}` : "")
        + (rule.note ? ` (${rule.note})` : ""),
      job: holder,
    };
  }
  return null;
}

// Retry policy resolution walks the SAME lane ladder as the budget catalog, for
// the same reason: "this lane has a declared ceiling" and "this lane may be
// retried" must be one spelling, not two that can disagree about which lane a
// job is in.
export async function resolveRetryPolicy(env, lane) {
  const { candidates } = laneCandidates(lane || "");
  for (const key of candidates) {
    const row = await env.DB.prepare("SELECT * FROM retry_policies WHERE lane=?1").bind(key).first();
    if (row) return row;
  }
  return null;                              // no policy = today's behaviour
}

// ── BH-1510.0: model routes ─────────────────────────────────────────────────
// The runners bin/agent-call.sh can dispatch to. A closed set on purpose — the
// whole point of this table is that an operator picks a MODEL for a role, and
// an unrecognised runner would write a ladder rung nothing on the fleet knows
// how to call, silently, until the first build that reaches it.
export const MODEL_ROUTE_RUNNERS = ["claude", "codex", "openrouter", "grok", "fireworks"];

// A role names a JOB (build.execute, triage, codex.default, ...), never a
// model or a runner. Lowercase, dot/underscore/hyphen separated, the same
// shape as a budget_catalog lane's stage segment — bounded at 128 so a role
// can never grow into carrying a whole prompt.
export const MODEL_ROUTE_ROLE_RE = /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/;

// A project name, when one is given: the same bare token fleet.conf and every
// other project-scoped table already uses (no path separators, no whitespace).
export const MODEL_ROUTE_PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;

// resolveModelLadder(env, role, project) -> { ladder, source }
//   ladder is [{position, model, runner}], ordered by position ascending.
//   source is 'project' when the PROJECT has its own rows for this role,
//   'hub' when it falls back to the hub default, 'none' when neither has one.
// Precedence is PER ROLE, not per rung: a project either owns its whole ladder
// for this role or it owns none of it. A partial override (project sets rung 0
// but not rung 1) would leave a caller silently mixing one operator's rung 0
// with a different operator's rung 1 for a role neither of them edited as a
// pair — the two edits are unrelated in time and the ladder that results is
// nobody's actual decision. bin/lib/model-route.sh documents the same rule.
//
// NO RUNG 0 = NO SCOPE (BH-1510.3). A scope whose rows do not start at
// position 0 is a half-written ladder (the pre-#1560 PUT/reset could leave one
// under two concurrent writes); handing it back would let every first-row
// reader silently promote a failover rung. A project scope like that is
// ignored (the hub answers); a hub scope like that is "none". The whole-scope
// replace in routes/model-routes.js is what stops new ones being written.
export async function resolveModelLadder(env, role, project) {
  if (project) {
    const rows = await env.DB.prepare(
      "SELECT position, model, runner FROM model_routes WHERE role=?1 AND project=?2 ORDER BY position ASC"
    ).bind(role, project).all();
    const ladder = rows.results || [];
    if (ladder.length > 0 && Number(ladder[0].position) === 0) return { ladder, source: "project" };
  }
  const hub = await env.DB.prepare(
    "SELECT position, model, runner FROM model_routes WHERE role=?1 AND project IS NULL ORDER BY position ASC"
  ).bind(role).all();
  const ladder = hub.results || [];
  if (ladder.length > 0 && Number(ladder[0].position) === 0) return { ladder, source: "hub" };
  return { ladder: [], source: "none" };
}

// The version of ONE write scope (a project's override, or the hub default):
// the highest row id in it, 0 when it has no rows. Every write replaces the
// whole scope with fresh rows (AUTOINCREMENT never reuses an id), so any write
// moves it — the optimistic-concurrency token the console's PUT and reset
// carry as `expected_version`.
export async function modelRouteScopeVersion(env, role, project) {
  const row = await env.DB.prepare(
    project
      ? "SELECT coalesce(max(id),0) AS v FROM model_routes WHERE role=?1 AND project=?2"
      : "SELECT coalesce(max(id),0) AS v FROM model_routes WHERE role=?1 AND project IS NULL"
  ).bind(...(project ? [role, project] : [role])).first();
  return Number((row && row.v) || 0);
}

// Every scope the NO RUNG 0 = NO SCOPE rule above hides, fleet-wide, in one
// GROUP BY (BH-1563). resolveModelLadder is right to ignore these rows, but it
// means nothing on any screen says they exist: the project tab shows HUB
// DEFAULT, the hub tab shows NO ROUTE, and the bash resolver's own norung0
// alert cannot fire, because this worker already resolved past the gap before
// the shell ever saw it. So the gap is a READ of its own, and the console and
// the daily hub lane are what turn it into something an operator can repair.
//
// The test is the resolver's own: min(position) > 0. A ladder like 0,2 has a
// hole PAST the primary and is NOT gapped — position is a failover order, not
// an array index, and the resolver serves it correctly.
export async function modelRouteGaps(env) {
  const rows = await env.DB.prepare(
    `SELECT coalesce(project,'') AS p, role, group_concat(position) AS positions
       FROM model_routes
      GROUP BY coalesce(project,''), role
     HAVING min(position) > 0
      ORDER BY coalesce(project,''), role`
  ).all();
  return (rows.results || []).map((r) => ({
    project: r.p || null,
    role: r.role,
    // group_concat has no defined order — the screen and the alert both print
    // these, so sort them here rather than in two readers.
    positions: String(r.positions || "").split(",").map(Number).filter(Number.isInteger).sort((a, b) => a - b),
  }));
}

// Every role that has EITHER a hub row or a row for this project, so the "list
// every role" route (the UI slice's data source) does not have to be handed a
// role list from outside the table.
export async function modelRouteRoles(env, project) {
  const rows = project
    ? await env.DB.prepare(
        "SELECT DISTINCT role FROM model_routes WHERE project IS NULL OR project=?1 ORDER BY role ASC"
      ).bind(project).all()
    : await env.DB.prepare(
        "SELECT DISTINCT role FROM model_routes WHERE project IS NULL ORDER BY role ASC"
      ).all();
  return (rows.results || []).map((r) => r.role);
}

// A model is "known" once it has a price row — the same table
// bin/update-model-prices.sh keeps current and the only place this worker
// already tracks every model id the fleet has ever priced. Rejecting an
// unpriced model at write time is what keeps a role's ladder from naming a
// model the cost pipeline has never heard of and will report as $0.
export async function knownModelIds(env) {
  const rows = await env.DB.prepare("SELECT model FROM model_prices").all();
  return new Set((rows.results || []).map((r) => r.model));
}

export async function claimRow(env, id) {
  return env.DB.prepare("SELECT * FROM job_claims WHERE job_id=?1").bind(id).first();
}

export async function putClaim(env, id, fields, t) {
  const c = (await claimRow(env, id)) || {};
  const next = {
    lane: fields.lane !== undefined ? fields.lane : (c.lane || null),
    attempts: fields.attempts !== undefined ? fields.attempts : (c.attempts || 1),
    max_attempts: fields.max_attempts !== undefined ? fields.max_attempts : (c.max_attempts ?? null),
    next_attempt_at: fields.next_attempt_at !== undefined ? fields.next_attempt_at : (c.next_attempt_at || null),
    escalate_allowed: fields.escalate_allowed !== undefined ? fields.escalate_allowed : (c.escalate_allowed ?? null),
    reason: fields.reason !== undefined ? fields.reason : (c.reason || null),
  };
  await env.DB.prepare(
    `INSERT INTO job_claims (job_id, lane, attempts, max_attempts, next_attempt_at, escalate_allowed, reason, updated_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
     ON CONFLICT(job_id) DO UPDATE SET lane=?2, attempts=?3, max_attempts=?4,
       next_attempt_at=?5, escalate_allowed=?6, reason=?7, updated_at=?8`
  ).bind(id, next.lane, next.attempts, next.max_attempts, next.next_attempt_at,
    next.escalate_allowed, next.reason, t).run();
  return next;
}

// A death that agent-call.sh already answered for itself is TERMINAL here,
// whatever the policy says. KILL_STOP and BUDGET_STOP each get one same-lane
// retry inside that script; retrying the job on top of that is the second
// attempt paying for the third, and the fleet has spent that money before.
export async function terminalMarker(env, id, job) {
  if (String(job.status || "") === "budget_stopped") return "BUDGET_STOP on the job row";
  const ph = await env.DB.prepare(
    `SELECT phase, note, status FROM job_phases WHERE job_id=?1
      AND (status='budget_stopped' OR note LIKE '%KILL_STOP%' OR note LIKE '%BUDGET_STOP%')
      ORDER BY id DESC LIMIT 1`
  ).bind(id).first();
  if (ph) return `${String(ph.note || ph.status).slice(0, 120)} in phase ${ph.phase}`;
  const ev = await env.DB.prepare(
    `SELECT stage, verdict FROM stage_events WHERE job_id=?1
      AND verdict IN ('KILL_STOP','BUDGET_STOP') ORDER BY id DESC LIMIT 1`
  ).bind(id).first();
  if (ev) return `${ev.verdict} on stage ${ev.stage}`;
  return null;
}

// ── Metrics ledger helpers (2026-08-29) ───────────────────────────────────────
// The metrics rows arrive from shell: every field crosses the wire as whatever
// jq made of a CSV cell, so "" and "n/a" both have to become NULL rather than
// NaN or the string "". A NaN written into a REAL column is a number nobody can
// aggregate over, and it is indistinguishable afterwards from a real zero.
export function numOrNull(v) {
  if (v === undefined || v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
export function intOrNull(v) {
  const n = numOrNull(v);
  return n === null ? null : Math.trunc(n);
}
// Identifiers (a PR number, a Telegram thread id) are parsed strictly: a
// fractional or non-numeric value is rejected, never truncated. intOrNull's
// Math.trunc would file PR 1.5 as PR 1 and thread "6.9" as topic 6, which is a
// wrong record written silently rather than a 400 the caller can see.
export function strictInt(v) {
  if (v === undefined || v === null || v === "" || typeof v === "boolean") return null;
  const n = Number(v);
  return Number.isInteger(n) ? n : null;
}
export function boolInt(v) {
  if (v === undefined || v === null || v === "") return null;
  return (v === true || v === 1 || v === "1" || v === "true") ? 1 : 0;
}
export function str(v, max) {
  if (v === undefined || v === null) return null;
  const s = String(v);
  return s === "" ? null : s.slice(0, max);
}

// Shared bulk append for deduplicated per-project tables (decisions / findings).
// Returns a {status, body} object so the two routes stay one helper.
export async function appendLines(env, table, body, t, columns, bindFn) {
  const project = str(body.project, 128);
  const rows = Array.isArray(body.rows) ? body.rows : null;
  sqlIdent(table);
  columns.forEach((c) => sqlIdent(c));
  if (!project || rows === null) return { status: 400, body: { error: "project and rows[] are required" } };
  if (rows.length > 200) return { status: 413, body: { error: "at most 200 rows per request" } };
  const stmts = [];
  for (const r of rows) {
    if (!r || typeof r !== "object") return { status: 400, body: { error: "each row must be an object" } };
    const stamp = r.stamp === undefined || r.stamp === null ? "" : String(r.stamp);
    const line = r.line === undefined || r.line === null ? "" : String(r.line);
    if (!stamp || !line) return { status: 400, body: { error: "each row needs stamp and line" } };
    // stamp and line are two thirds of the UNIQUE dedupe key. Silently cutting
    // them to length would make two different lines collide as one INSERT OR
    // IGNORE and drop a record with nothing in the answer to say so, so an
    // over-long row is a 400 the caller can see instead.
    if (stamp.length > 32 || line.length > 4000) {
      return { status: 400, body: { error: "stamp is at most 32 chars and line at most 4000" } };
    }
    const binds = bindFn(project, r, stamp, line, t);
    const placeholders = binds.map((_, i) => `?${i + 1}`).join(",");
    // sql-ident-ok: table and columns passed sqlIdent above; placeholders are ?N text
    stmts.push(env.DB.prepare(
      `INSERT OR IGNORE INTO ${table} (${columns.join(",")}) VALUES (${placeholders})`
    ).bind(...binds));
  }
  // An empty rows[] is "nothing new this tick", which is the common case for a
  // hub that appends on every tick — the idempotent answer, not an error line
  // in the caller's log.
  if (!stmts.length) return { status: 200, body: { inserted: 0, ignored: 0, as_of: t } };
  const results = await env.DB.batch(stmts);
  const inserted = (Array.isArray(results) ? results : [])
    .reduce((a, x) => a + ((x && x.meta && Number(x.meta.changes)) || 0), 0);
  return { status: 200, body: { inserted, ignored: stmts.length - inserted, as_of: t } };
}

// Shared cursor read for those same two append-log tables. `since` is the
// cursor and `id ASC` is the tiebreak that makes it stable: several lines share
// one stamp routinely (a whole review pass stamps the same second), and without
// the tiebreak two pages of the same restore can interleave or drop a row.
// lim+1 rows are fetched so `truncated` is measured, not guessed.
export async function listLines(env, table, url, t) {
  sqlIdent(table);
  const since = str(url.searchParams.get("since"), 32);
  if (!since) return json(400, { error: "since required" });
  const project = str(url.searchParams.get("project"), 128);
  const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 5000);
  const where = project ? ["project=?1", "stamp>=?2"] : ["stamp>=?1"];
  const binds = project ? [project, since] : [since];
  // sql-ident-ok: table passed sqlIdent; where is two literals; lim is a clamped number
  const rows = await env.DB.prepare(
    `SELECT * FROM ${table} WHERE ${where.join(" AND ")} ORDER BY stamp ASC, id ASC LIMIT ${lim + 1}`
  ).bind(...binds).all();
  const results = rows.results || [];
  return json(200, { rows: results.slice(0, lim), truncated: results.length > lim, as_of: t });
}

// ── Additive column migration (2026-09-02) ───────────────────────────────────
// auth_account / account_breakdown on pr_costs are the first columns ever ADDED
// to an existing table here. schema.sql is re-applied on every deploy and that
// re-apply is this worker's migration mechanism — but D1 has no
// `ADD COLUMN IF NOT EXISTS`, so a bare ALTER cannot live in a re-runnable file
// (README: "a column could not live in a re-runnable file"). Two halves keep
// "deploy = migration" true anyway: the CREATE in schema.sql carries the
// columns for a fresh database, and this reads PRAGMA table_info once per DB
// handle and ALTERs whatever an existing database is missing, before the first
// write that needs them. Idempotent (a lost race against another isolate is
// "duplicate column", which is the outcome we wanted), additive, and it lands
// with the deploy exactly as a new table would.
//
// Memoised per env.DB handle rather than per module: a stubbed DB in tests is
// a fresh object per call, and a real binding that turns out to be re-created
// per request costs one PRAGMA on a route that is written hourly.
//
// Keyed by TABLE (2026-09-06, SDLC item 3 added outcome_metrics.repairs): the
// mechanism is the same for every table, and a second copy of it would be a
// second place for "deploy = migration" to stop being true. Table and column
// names are interpolated, so they may only ever come from this literal map —
// never from a request.
export const ADDED_COLUMNS = {
  // BH-5635: the flag file's content (a WIP limit, say). Nullable, never
  // backfilled: a row with no value is today's empty flag file.
  pause_flags: [["value", "TEXT"]],
  pr_costs: [["auth_account", "TEXT"], ["account_breakdown", "TEXT"]],
  outcome_metrics: [["repairs", "INTEGER"]],
  // BH-3831: which credential wrote the verdict row (secret | lead-token | human-token).
  // BH-3846: the worker's HMAC over a human-token row.
  // BH-6967: the head's risk tier (low|medium|high) and the review that wrote the
  // row (full|intent|risk-tier), on a table created before them (a fresh one has
  // them in its CREATE). NULL = not said (a row before BH-6967, or a writer
  // outside the lead review path).
  verdicts: [["auth", "TEXT"], ["human_sig", "TEXT"], ["review_tier", "TEXT"], ["review_mode", "TEXT"]],
  // 2026-09-14, cost fixes 1/2/7: row provenance (which transcript priced this
  // row, and whether it was priced from one at all) plus the attribution tags.
  // 2026-09-20, BH-1032: `note` was the one CSV column the mirror never carried
  // (the client's COLS list stopped at run_id, so the cliff-route decision was
  // dropped on the way in), and `raw` is the verbatim line — without it a reader
  // re-renders 4.00 as 4 and every file built from this table differs from the
  // file it mirrors.
  cost_rows: [["session_id", "TEXT"], ["row_source", "TEXT"], ["result_usd", "REAL"],
              ["ticket", "TEXT"], ["job_id", "TEXT"], ["pr", "TEXT"], ["run_id", "TEXT"],
              ["note", "TEXT"], ["raw", "TEXT"], ["lane_id", "TEXT"],
              // BH-2537: the 26th CSV column, the pre-call guard's input fingerprint.
              ["guard_fp", "TEXT"],
              // BH-5349: the participant machine that spent the call; no writer yet.
              ["participant", "TEXT"]],
  // BH-3985: error_body, the vendor's answer on a failed poll.
  extra_usage_snapshots: [["extra_limit_usd", "REAL"], ["extra_pct", "REAL"], ["status", "TEXT"],
                          ["error_body", "TEXT"]],
  // 2026-09-17, BH-482.0: launch lead time — the issue's createdAt and this
  // job's first agent spawn. Nothing writes or reads them yet; the worker
  // sibling stamps them and the DORA route reads them.
  jobs: [["issue_created_at", "TEXT"], ["first_spawn_at", "TEXT"]],
  // BH-1031 (state→DB slice 6): the PROCESS half of lane liveness. The live
  // database already carries a `lanes` table, so the CREATE in schema.sql can
  // never reach it — these ALTERs are what keep "deploy = migration" true for
  // the one fact the fleet used to answer in three different places.
  lanes: [["proc_pid", "INTEGER"], ["proc_note", "TEXT"], ["proc_started_at", "TEXT"],
          ["proc_interval_s", "INTEGER"], ["proc_deadline_at", "TEXT"],
          ["proc_beat_at", "TEXT"], ["proc_ended_at", "TEXT"]],
  // BH-1031: the backup-freshness facts, re-homed off the deleted ssh hop onto
  // the box that owns them. Same reason as the row above — box_status exists in
  // the live database, so only an ALTER can reach it — and same discipline:
  // nullable, never backfilled, and a row with no backup half reads exactly as
  // it does today.
  box_status: [["backup_ts", "TEXT"], ["backup_off", "TEXT"],
               ["backup_unconfigured", "TEXT"], ["backup_reported_at", "TEXT"],
               // BH-1511.1: WHEN a box last said which harness commit it runs
               // (harness_commit itself predates this and had no writer). The
               // seed refuses unless every box said so recently.
               ["harness_reported_at", "TEXT"],
               // BH-2532.0: the hash of the rules the box renders, and WHEN it
               // said so. Written by the self-report sibling; nullable, no backfill.
               ["rules_hash", "TEXT"], ["rules_reported_at", "TEXT"]],
  // BH-1270, parallel trains: which of the tick's disjoint groups this train
  // was. The CREATE above carries it for a fresh database and this ALTER is
  // what reaches the live one — merge_trains shipped with BH-1269 and
  // ensureTable's `IF NOT EXISTS` can never widen a table that already exists.
  // With N trains in flight, "what else was running beside this one" is the
  // first question a reader of a red union asks, and a row that cannot answer
  // it makes every parallel train look like a serial one that happened to be
  // quick.
  merge_trains: [["train_group", "TEXT"]],
  // BH-1026.0: WHICH Fly machine holds a claimed build. Same reason as the two
  // rows above — build_queue exists in the live database, so the CREATE in
  // schema.sql can never widen it and only this ALTER reaches it. Nullable and
  // never backfilled: every row claimed before this column stays legal and
  // reads exactly as it does today.
  build_queue: [["machine", "TEXT"]],
  // BH-1613: the per-model price source. 'vendor-direct' means the daily
  // refresh keeps the committed catalog row (the vendor's own rate and cliff)
  // instead of OpenRouter's resale list; NULL means OpenRouter, today's
  // behaviour. model_prices exists in the live database, so only this ALTER
  // reaches it. Written only by PUT /api/model-prices/source.
  // BH-1754: the vendor-direct PRICE sits next to that mark, so an operator edits
  // the rate in D1 instead of in catalog/model-prices.json (now the fallback).
  // Nullable, never backfilled, and written by the same PUT only: the refresh's
  // whole-table POST never names them, so its daily upsert cannot erase them.
  model_prices: [["price_source", "TEXT"], ["vendor_prompt", "REAL"], ["vendor_completion", "REAL"],
                 ["vendor_cache_read", "REAL"], ["vendor_cache_write", "REAL"],
                 ["vendor_cliff_tokens", "INTEGER"],
                 // BH-5652: the price version and when it took effect. Every
                 // existing row reads version 1 (the default); effective_at stays
                 // NULL until the first versioned write fills it. POST/GET
                 // /api/model-prices call ensureColumns before naming them.
                 ["version", "INTEGER NOT NULL DEFAULT 1"], ["effective_at", "TEXT"]],
  // BH-2627 (BH-2524.0): the fleet file claim on a job's claim row. job_claims
  // exists in the live database, so only this ALTER reaches it. Nullable, never
  // backfilled, and putClaim never names them, so a retry cannot erase them.
  // routes/file-claims.js (BH-2628) calls ensureColumns for job_claims on every PUT and GET.
  job_claims: [["planned_files", "TEXT"], ["files_claimed_at", "TEXT"],
               ["files_expires_at", "TEXT"], ["overlap_not_before", "TEXT"]],
  // BH-2743: baked / smoke_failed / active / demoted. Nullable, never backfilled.
  fly_images: [["state", "TEXT"]],
  // BH-4953 (BH-4950.0): PR gate facts, carried on `state='gate'` rows and
  // folded per field by lib/pr-gate.js. pr_state_events exists in the live
  // database, so only this ALTER reaches it. Nullable, never backfilled: NULL
  // is "no news", and every conductor row reads exactly as it does today.
  pr_state_events: [["draft", "INTEGER"], ["closed", "INTEGER"], ["held", "INTEGER"],
                    ["hotfix", "INTEGER"], ["ci_green_sha", "TEXT"],
                    ["builder_approved_sha", "TEXT"], ["lead_verdict_sha", "TEXT"],
                    ["lead_verdict_word", "TEXT"], ["reviewing_sha", "TEXT"],
                    ["review_failed_sha", "TEXT"], ["nudged_sha", "TEXT"]],
  // BH-5151: the order a lead review request is worked in. Nullable, never
  // backfilled; a higher number is reviewed first and NULL is no priority.
  // Set by POST /api/lead-reviews (routes/lead-reviews.js), whose guard calls
  // ensureColumns for this table before every handler.
  // BH-5400: reset_count / reset_at record that a finished request was sent
  // back to `requested` (the /reset route, or the claim that takes a row a raw
  // reset left behind), so the land lane knows a newer result is coming.
  // BH-5349 (BH-5348.0): the participant claim heartbeat, the participant
  // that holds the claim and the PR head's authors (JSON). Nullable; nothing
  // reads or writes them yet, the BH-5348 siblings do.
  // BH-5799: when the pre-planner started reading the ticket thread, so a
  // builder that adopts the row from the DB can judge which comments are newer
  // than the plan. Nullable, never backfilled: a NULL row predates the column.
  // routes/preplans.js calls ensureColumns before the POST and the GET.
  preplans: [["thread_at", "TEXT"]],
  // BH-5779: stale_reclaims counts how often POST /api/lead-reviews/reclaim-stale took this row back.
  lead_review_requests: [["priority", "INTEGER"], ["reset_count", "INTEGER"], ["reset_at", "TEXT"],
                         ["heartbeat_at", "TEXT"], ["participant", "TEXT"], ["head_authors", "TEXT"],
                         ["stale_reclaims", "INTEGER"]],
};
// BH-2489: indexes that name an ADDED column, created by ensureColumns right
// after the ALTER loop, so they exist exactly when their column does. They can
// never live in schema.sql: harness-sync applies that file to the live D1 BEFORE
// the worker deploys, when lane_id does not exist yet, and a CREATE INDEX on it
// there fails "no such column" and wedges every later deploy (#2473; see the
// note under cost_rows' indexes in schema.sql). These two serve the pre-call
// spend gate's GET /api/metrics/llm-spend?lane= read, which runs once per
// registered stage on every capped model call. Same rule as the map above:
// literal statements only, never built from a request.
export const ADDED_INDEXES = {
  cost_rows: ["CREATE INDEX IF NOT EXISTS idx_cost_rows_lane_ts ON cost_rows(lane_id, ts)",
              "CREATE INDEX IF NOT EXISTS idx_cost_rows_stage_ts ON cost_rows(stage, ts)"],
};
export const addedColumnsReady = new WeakMap();
export async function ensureColumns(env, table) {
  sqlIdent(table);
  const db = env.DB;
  // Keyed on the raw binding, not the BH-6690 retry proxy index.js puts on env.DB.
  let per = addedColumnsReady.get(rawDb(db));
  if (!per) { per = new Map(); addedColumnsReady.set(rawDb(db), per); }
  if (per.has(table)) return per.get(table);
  const p = (async () => {
    // sql-ident-ok: table passed sqlIdent at the top of ensureColumns
    const info = await db.prepare(`PRAGMA table_info(${table})`).all();
    const have = new Set((info.results || []).map((r) => r.name));
    for (const [col, type] of ADDED_COLUMNS[table] || []) {
      if (have.has(col)) continue;
      try {
        // sql-ident-ok: table and col pass sqlIdent; type is a literal type phrase from ADDED_COLUMNS
        await db.prepare(`ALTER TABLE ${table} ADD COLUMN ${sqlIdent(col)} ${type}`).run();
      } catch (e) {
        if (!/duplicate column/i.test(String(e && e.message || e))) throw e;
      }
    }
    // An index is an optimisation: a failed create is logged and swallowed, so
    // it never fails the column migration or the ingest behind it.
    for (const sql of ADDED_INDEXES[table] || []) {
      try {
        await db.prepare(sql).run();
      } catch (e) {
        console.warn(`ensureColumns(${table}): ${sql} failed: ${String(e && e.message || e)}`);
      }
    }
  })();
  per.set(table, p);
  // A failed migration must not be cached as "done": the next request tries again.
  p.catch(() => per.delete(table));
  return p;
}

// ── Additive table creation (BH-658, 2026-09-17) ─────────────────────────────
// The other half of "deploy = migration", for a whole TABLE. A new table that
// relies on a HAND step to reach the live database ships DEAD: the code deploys
// in minutes, every statement against the missing table throws, and the routes
// answer 500 while the client reports an outage and burns the box's daily ALERT
// on a false cause. That is the TK-64 shape (~/.claude/CLAUDE.md: "a schema
// change that exists only as a run-me-manually script is not a migration"), and
// hub_lease shipped with exactly it — the 2026-09-19 outage.
//
// SINCE BH-1000 that hand step is gone: `bin/harness-sync.sh` applies each
// worker's schema.sql statement by statement (`wrangler d1 execute --command`,
// `--file` 10000s under OAuth) BEFORE `wrangler deploy`, and skips the deploy
// when a statement fails, so code cannot run ahead of its schema. This map is
// still the belt to that deploy-time braces: it makes a table true on the live
// database on the FIRST request after a deploy, without waiting for the next
// update-runners run. The map has an entry for every schema table, but a
// table only self-creates where a route calls ensureTable for it. No route does
// for hub_lease or settings: the deploy-time apply plus d1Guarded (lib/http.js)
// cover them, which answers 503 naming the table rather than throwing, and
// putting a CREATE in front of the lease routes would send statements the test
// fixture does not model into every W-test. Two mechanisms, one rule: a route never runs ahead
// of its table in silence.
//
// So a table whose routes must work the minute the worker deploys creates itself
// here, the way ensureColumns ALTERs a missing column: memoised per env.DB
// handle, idempotent (IF NOT EXISTS), additive, never a DROP, and run BEFORE the
// first statement that needs it.
//
// SINCE BH-4987 the statements derive from worker/jobs/schema.d/, not from a
// hand copy. `#schema-sql` (package.json "imports") is the composed schema text:
// the bundled schema.sql in the deployed worker, jobsSchemaSql() under Node.
// createdTablesFrom (lib/created-tables.js) maps it to every CREATE TABLE and
// the CREATE INDEXes ON that table. So a new table is one schema.d fragment and
// nothing else. Do NOT add a key to CREATED_TABLE_OVERRIDES for a new table:
// test/created-tables.bh-4987.test.js refuses it.
//
// The overrides replace the derived entry for their key. Most are hand copies
// that equal the derived form (the same test proves it) and that a later slice
// deletes. Five differ on purpose: merge_trains creates train_group up front,
// verdicts and setting_sigs add CREATE TRIGGERs (schema.d may not hold one,
// BH-1000), pr_state_events adds the pr_state VIEW and harness_flags adds its
// pause_flags backfill INSERT.
//
// Table and statement text may only ever come from the schema text and this
// literal map, never from a request.
// The nine dequeue-watch class words (BH-3727), as SQL, for the two CHECKs on
// dequeue_events and the one on dequeue_actions below.
const DQW_CLASS_SQL = "'rule-break','scanner-fp','semantic-test','textual-conflict','bystander','stale-status','flake','main-red','unclassified'";
export const CREATED_TABLE_OVERRIDES = {
  // BH-1269 — the merge-train registry. Same reason as every self-created table:
  // the deploy is `wrangler deploy`, so a table that waits for a hand-run
  // `d1 execute` ships dead and bin/batch-resolve.sh's row write fails open
  // silently, which is indistinguishable from a lane that ran no trains.
  merge_trains: [
    `CREATE TABLE IF NOT EXISTS merge_trains (
       project TEXT NOT NULL,
       branch TEXT NOT NULL,
       repo TEXT,
       train_pr INTEGER,
       members TEXT,
       member_count INTEGER,
       union_sha TEXT,
       run_id TEXT,
       train_group TEXT,
       outcome TEXT NOT NULL,
       merge_sha TEXT,
       detail TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, branch)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_merge_trains_outcome ON merge_trains(outcome, project, created_at)",
  ],
  // BH-1024 — the append-only verdict record. Same reason as every entry above,
  // and this one is on the HOT path: `job_artifact_put verdict` is how run-build
  // settles, how the BH-1064 block records a review and how
  // `job_verdict_rebind` re-binds an approval after a rebase. A missing table
  // there throws AFTER the standing upsert has landed, so the PUT 500s, the
  // rebind returns rc 1, `mc_rebase` returns rc 5, and a rebased approved PR
  // parks in NEEDS_REBASE "rebind-failed" until somebody hand-runs a d1 execute.
  // Column for column with schema.sql (worker/jobs/test/verdict-history.bh-1024.test.js
  // asserts the agreement, and the pre-deploy database case asserts this map is
  // what creates the table on the live D1).
  verdict_history: [
    `CREATE TABLE IF NOT EXISTS verdict_history (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       job_id TEXT NOT NULL,
       verdict TEXT NOT NULL,
       reviewed_sha TEXT,
       tier TEXT,
       provenance TEXT,
       served_by TEXT,
       source TEXT,
       detail TEXT,
       actor TEXT,
       created_at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_verdict_history_job ON verdict_history(job_id, id)",
  ],
  // BH-1267 — the doorbell table, entered here for its THIRD index rather than
  // for the table itself: `idx_wakes_at` is what makes the daily
  // POST /api/wakes/prune (`at < ?1 ORDER BY at ASC LIMIT ?2`) a covering index
  // search instead of a scan of a table that, until this ticket, nothing ever
  // deleted from. `bin/harness-sync.sh` applies
  // schema.sql statement by statement before the deploy and is what reaches the
  // live database first; this map is the BH-658 belt to that, and the only
  // thing that makes the index true on the first prune if a deploy ever runs
  // ahead of an apply. Column for column with schema.sql (the wakes-prune test
  // asserts the agreement), IF NOT EXISTS throughout, additive, never a DROP.
  wakes: [
    `CREATE TABLE IF NOT EXISTS wakes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       kind TEXT NOT NULL,
       key TEXT NOT NULL,
       event TEXT,
       minute TEXT NOT NULL,
       at TEXT NOT NULL,
       acked_at TEXT
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_wakes_dedupe ON wakes(repo, kind, key, minute)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_unacked ON wakes(acked_at, id)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_at ON wakes(at)",
    // BH-6727 (schema.d/202610141900): the cursor read WHERE id > ? AND repo = ?.
    "CREATE INDEX IF NOT EXISTS idx_wakes_repo_id ON wakes(repo, id)",
    // BH-6799 (schema.d/202610150809): the claim's lower(repo) and kind ranges.
    "CREATE INDEX IF NOT EXISTS idx_wakes_repo_lc_id ON wakes(lower(repo), id)",
    "CREATE INDEX IF NOT EXISTS idx_wakes_kind_id ON wakes(kind, id)",
  ],
  // BH-2636 — POST /api/wakes/prune now sweeps orphan claims, and the prune is
  // a daily lane that already self-creates `wakes`; without this belt it would
  // 500 on a database the deploy-time schema.sql apply has not reached. Same
  // text as schema.sql's BH-2525 block, column for column.
  wake_claims: [
    `CREATE TABLE IF NOT EXISTS wake_claims (
       wake_id INTEGER NOT NULL,
       box TEXT NOT NULL,
       claimed_at TEXT NOT NULL,
       PRIMARY KEY (wake_id, box)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_wake_claims_box_wake ON wake_claims(box, wake_id)",
  ],
  // BH-1025.0 — the belt for the routes child (#1386): `ensureTable(env,
  // 'pr_state_events')` at the top of every handler; the view rides under
  // pr_state_events, because a view over a table the same call just created is
  // the only ordering that works on a database the deploy reached first.
  // Statement text is identical to worker/jobs/schema.sql's block, column for
  // column — worker/jobs/test/pr-state-schema.bh-1385.test.js compares the two
  // databases with PRAGMA table_info rather than trusting that sentence.
  pr_state_events: [
    `CREATE TABLE IF NOT EXISTS pr_state_events (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL, number INTEGER NOT NULL, state TEXT NOT NULL, since TEXT NOT NULL,
       head TEXT, reviewed TEXT, reason TEXT, url TEXT,
       alerted TEXT NOT NULL DEFAULT '-',
       at TEXT NOT NULL, actor TEXT
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_pr_state_events_dedupe ON pr_state_events(repo, number, state, since, alerted)",
    "CREATE INDEX IF NOT EXISTS idx_pr_state_events_pr ON pr_state_events(repo, number, id)",
    "CREATE INDEX IF NOT EXISTS idx_pr_state_events_state_at ON pr_state_events(state, at)",
    "CREATE VIEW IF NOT EXISTS pr_state AS SELECT e.* FROM pr_state_events e WHERE e.id = (SELECT MAX(id) FROM pr_state_events WHERE repo=e.repo AND number=e.number)",
  ],
  pr_attempts: [
    `CREATE TABLE IF NOT EXISTS pr_attempts (
       repo TEXT NOT NULL, number INTEGER NOT NULL, kind TEXT NOT NULL, sha TEXT NOT NULL,
       at TEXT NOT NULL, actor TEXT,
       PRIMARY KEY (repo, number, kind, sha)
     )`,
  ],
  // BH-1510.0 — the same belt as pr_state_events above: `wrangler deploy` is
  // the whole deploy, so a route reached before harness-sync.sh's own schema
  // apply must still create its table rather than 503 for however long that
  // gap lasts. Column for column with worker/jobs/schema.sql's block — that
  // file is the comment, this is the copy the routes actually run against.
  model_routes: [
    `CREATE TABLE IF NOT EXISTS model_routes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       scope TEXT NOT NULL,
       project TEXT,
       role TEXT NOT NULL,
       position INTEGER NOT NULL,
       model TEXT NOT NULL,
       runner TEXT NOT NULL,
       updated_by TEXT,
       updated_at TEXT NOT NULL
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_model_routes_key ON model_routes(coalesce(project,''), role, position)",
    "CREATE INDEX IF NOT EXISTS idx_model_routes_role ON model_routes(role, project)",
  ],
  // BH-2010: the routing audit trail (schema.sql carries the same statements).
  routing_changes: [
    `CREATE TABLE IF NOT EXISTS routing_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       project TEXT NOT NULL,
       before_builder TEXT,
       before_pool_app TEXT,
       before_halted INTEGER,
       after_builder TEXT NOT NULL,
       after_pool_app TEXT,
       after_halted INTEGER NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_routing_changes_project ON routing_changes(project, at)",
  ],
  // BH-2563: the cost-cap audit trail (schema.sql carries the same statements).
  cost_cap_changes: [
    `CREATE TABLE IF NOT EXISTS cost_cap_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       key TEXT NOT NULL,
       before_value TEXT,
       after_value TEXT NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_cost_cap_changes_key ON cost_cap_changes(key, at)",
  ],
  // BH-2513: the console-controls audit trail (schema.sql carries the same statements).
  config_changes: [
    `CREATE TABLE IF NOT EXISTS config_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       kind TEXT NOT NULL,
       name TEXT NOT NULL,
       before_json TEXT,
       after_json TEXT NOT NULL,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_config_changes_kind_name ON config_changes(kind, name, id)",
  ],
  // BH-4153: the ported flag families' rows (schema.sql carries the same
  // statements, and test/flags-db.bh-4153.test.js compares them). The third
  // statement is the one-time backfill from pause_flags: INSERT OR IGNORE (the
  // schema-additive lint's form) makes every later run a no-op, so it is safe
  // on each cold isolate.
  harness_flags: [
    `CREATE TABLE IF NOT EXISTS harness_flags (
  scope TEXT NOT NULL DEFAULT 'fleet', name TEXT NOT NULL, value TEXT,
  set_by TEXT, reason TEXT, set_at TEXT NOT NULL, cleared_at TEXT,
  PRIMARY KEY (scope, name))`,
    "CREATE INDEX IF NOT EXISTS harness_flags_name ON harness_flags(name)",
    `INSERT OR IGNORE INTO harness_flags (scope, name, value, set_by, reason, set_at, cleared_at)
  SELECT 'fleet', name, NULL, actor, reason, updated_at, CASE WHEN active=1 THEN NULL ELSE updated_at END
    FROM pause_flags WHERE name LIKE 'paused-%' OR name = 'automerge-disabled' OR name LIKE 'automerge-disabled-%' OR name LIKE 'lanedown-%'`,
  ],
  model_route_changes: [
    `CREATE TABLE IF NOT EXISTS model_route_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       scope TEXT NOT NULL,
       project TEXT,
       role TEXT NOT NULL,
       position INTEGER NOT NULL,
       before_model TEXT,
       before_runner TEXT,
       after_model TEXT,
       after_runner TEXT,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_model_route_changes_role ON model_route_changes(role, project, at)",
  ],
  // BH-1525 — same belt as model_routes above; worker/jobs/schema.sql's block
  // is the comment, this is the copy the routes run against. The two triggers
  // live ONLY here (schema.sql admits only table/index/view/insert-or-ignore,
  // tests/schema-additive.bh-1000-test.sh), and every verdicts route runs this
  // list before it reads or writes, so the table is append-only from its first
  // touch whether harness-sync or the route created it.
  verdicts: [
    `CREATE TABLE IF NOT EXISTS verdicts (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       verdict TEXT NOT NULL,
       source TEXT NOT NULL,
       reviewer_model TEXT,
       reviewer TEXT,
       report_url TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       auth TEXT,
       human_sig TEXT,
       review_tier TEXT,
       review_mode TEXT
     )`,
    "CREATE INDEX IF NOT EXISTS idx_verdicts_pr_head ON verdicts(repo, pr, head_sha, id)",
    "CREATE TRIGGER IF NOT EXISTS verdicts_no_update BEFORE UPDATE ON verdicts BEGIN SELECT RAISE(ABORT, 'verdicts is append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS verdicts_no_delete BEFORE DELETE ON verdicts BEGIN SELECT RAISE(ABORT, 'verdicts is append-only'); END",
  ],
  // BH-4146 — the self-create copy of schema.sql's lead_protected_paths block
  // (BH-4140.1), statement for statement. No triggers: a remove is an UPDATE
  // of removed_at; routes/lead-protected-paths.js has no DELETE.
  lead_protected_paths: [
    "CREATE TABLE IF NOT EXISTS lead_protected_paths (id INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT NOT NULL, glob TEXT NOT NULL, added_by TEXT NOT NULL, added_at TEXT NOT NULL, removed_at TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS lpp_live ON lead_protected_paths(repo, glob) WHERE removed_at IS NULL",
  ],
  // BH-3905 — schema.sql's setting_sigs block is the comment; the triggers live
  // only here, the same way as verdicts above.
  setting_sigs: [
    `CREATE TABLE IF NOT EXISTS setting_sigs (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       key TEXT NOT NULL,
       seq INTEGER NOT NULL,
       sig TEXT NOT NULL,
       actor TEXT,
       at TEXT NOT NULL,
       UNIQUE(key, seq)
     )`,
    "CREATE TRIGGER IF NOT EXISTS setting_sigs_no_update BEFORE UPDATE ON setting_sigs BEGIN SELECT RAISE(ABORT, 'setting_sigs is append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS setting_sigs_no_delete BEFORE DELETE ON setting_sigs BEGIN SELECT RAISE(ABORT, 'setting_sigs is append-only'); END",
  ],
  // BH-1949 — the self-create copy of schema.sql's lead_review_requests block
  // (BH-1948), column for column; test/lead-reviews.bh-1949.test.js pins the
  // parity. No triggers: unlike verdicts, a request row moves through claim,
  // result and promotion.
  lead_review_requests: [
    `CREATE TABLE IF NOT EXISTS lead_review_requests (
       id TEXT PRIMARY KEY,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       scope_notes TEXT,
       prior_verdict_ref TEXT,
       requested_by TEXT,
       status TEXT NOT NULL DEFAULT 'requested',
       job_id TEXT,
       box TEXT,
       verdict TEXT,
       report_ref TEXT,
       reviewer_model TEXT,
       detail TEXT,
       promoted_verdict_at TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_lead_review_requests_status ON lead_review_requests(status, repo)",
  ],
  // BH-5022 — the self-create copy of schema.sql's risk_tiers block, column for
  // column (test/risk-tiers.bh-5022.test.js pins the parity). One row per
  // classified head; the first classification of a head is kept (the route's
  // ON CONFLICT DO NOTHING), because a head's diff never changes.
  risk_tiers: [
    `CREATE TABLE IF NOT EXISTS risk_tiers (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       project TEXT,
       tier TEXT NOT NULL,
       mode TEXT NOT NULL,
       action TEXT,
       reasons TEXT,
       lines INTEGER,
       files INTEGER,
       created_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_risk_tiers_repo_pr ON risk_tiers(repo, pr)",
    "CREATE INDEX IF NOT EXISTS idx_risk_tiers_tier ON risk_tiers(tier, id)",
  ],
  // BH-5024 — the self-create copy of schema.sql's jev_risk_calls block, column
  // for column (test/jev-risk.bh-5024.test.js pins the parity). The spend
  // ledger in front of every Jev call: claimed before, settled after.
  jev_risk_calls: [
    `CREATE TABLE IF NOT EXISTS jev_risk_calls (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       question_version TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('claimed','ok','empty','failed')),
       attempts INTEGER NOT NULL DEFAULT 0,
       rule_tier TEXT,
       jev_tier TEXT,
       jev_prob REAL,
       model TEXT,
       caller TEXT,
       error TEXT,
       raw TEXT,
       claimed_at TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha, question_version)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_jev_risk_repo_pr ON jev_risk_calls(repo, pr)",
  ],
  // BH-5430 — the self-create copy of schema.sql's queue_risk_scores block,
  // column for column (test/queue-risk.bh-5430.test.js pins the parity). One
  // row per scored head; a re-score of the same head UPDATES it (the route's
  // insert-then-update), so the badge shows the newest routing.
  queue_risk_scores: [
    `CREATE TABLE IF NOT EXISTS queue_risk_scores (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head_sha TEXT NOT NULL,
       project TEXT,
       score INTEGER,
       threshold INTEGER NOT NULL,
       route TEXT NOT NULL,
       mode TEXT NOT NULL,
       reasons TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       UNIQUE(repo, pr, head_sha)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_repo_pr ON queue_risk_scores(repo, pr)",
    "CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_route ON queue_risk_scores(route, id)",
  ],
  // P4 — the self-create copies of schema.sql's route_rules / route_rule_changes
  // / route_shadow blocks, column for column (test/route-rules.p4.test.js pins
  // the parity). The seed rows live only in schema.sql: a table this belt
  // created before harness-sync's apply is an empty rule set, which the shadow
  // resolver reads as "no rule matched" — the same as the live build.
  route_rules: [
    `CREATE TABLE IF NOT EXISTS route_rules (
       name TEXT PRIMARY KEY,
       priority INTEGER NOT NULL,
       effect TEXT NOT NULL,
       mode TEXT NOT NULL,
       match_json TEXT NOT NULL,
       execute_role TEXT,
       review_tier TEXT,
       test_scope TEXT,
       tier_bump INTEGER NOT NULL DEFAULT 0,
       note TEXT,
       version INTEGER NOT NULL DEFAULT 1,
       updated_by TEXT,
       updated_at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_route_rules_priority ON route_rules(priority)",
  ],
  route_rule_changes: [
    `CREATE TABLE IF NOT EXISTS route_rule_changes (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       name TEXT NOT NULL,
       before_json TEXT,
       after_json TEXT,
       actor TEXT NOT NULL,
       reason TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE INDEX IF NOT EXISTS idx_route_rule_changes_name ON route_rule_changes(name, at)",
  ],
  route_shadow: [
    `CREATE TABLE IF NOT EXISTS route_shadow (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       build TEXT NOT NULL,
       job_id TEXT,
       project TEXT NOT NULL,
       ticket_key TEXT,
       rule TEXT,
       bumped TEXT,
       would_execute_role TEXT,
       would_execute_model TEXT,
       actual_execute_model TEXT,
       would_review_tier TEXT,
       planned_review_tier TEXT,
       review_model TEXT,
       would_test_scope TEXT,
       differs INTEGER NOT NULL DEFAULT 0,
       features_json TEXT,
       box TEXT,
       at TEXT NOT NULL
     )`,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_route_shadow_build ON route_shadow(build)",
    "CREATE INDEX IF NOT EXISTS idx_route_shadow_at ON route_shadow(at, project)",
    "CREATE INDEX IF NOT EXISTS idx_route_shadow_job ON route_shadow(job_id)",
  ],
  // TRIAGE-STATE — the self-create copy of schema.sql's triage_state block,
  // column for column (test/triage-state.test.js pins the parity). A deploy that
  // ran before harness-sync applied the schema still answers the pre-check.
  triage_state: [
    `CREATE TABLE IF NOT EXISTS triage_state (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ticket_label TEXT,
       input_hash TEXT,
       verdict TEXT,
       waiting_on TEXT,
       verdict_hash TEXT,
       triaged_at TEXT,
       next_recheck_at TEXT,
       reason TEXT,
       last_decision TEXT,
       last_decision_at TEXT,
       last_mode TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_triage_state_recheck ON triage_state(project, next_recheck_at)",
  ],
  // BH-2575 (BH-2544.3): the family→script registry the /api/alert-family-scripts
  // route reads and writes. Self-creates for the same reason as the rest of this
  // map (the deploy is `wrangler deploy`), and
  // test/alert-family-scripts.bh-2544.test.js compares the result with schema.sql.
  alert_family_scripts: [
    `CREATE TABLE IF NOT EXISTS alert_family_scripts (
       id TEXT PRIMARY KEY,
       match_kind TEXT NOT NULL CHECK (match_kind IN ('akey_prefix','line_regex')),
       match TEXT NOT NULL,
       verify TEXT,
       on_clear TEXT NOT NULL DEFAULT 'settle' CHECK (on_clear IN ('settle','model')),
       on_repro TEXT NOT NULL DEFAULT 'model' CHECK (on_repro IN ('model','park')),
       enabled INTEGER NOT NULL DEFAULT 1,
       priority INTEGER NOT NULL DEFAULT 100,
       note TEXT, actor TEXT, updated_at TEXT NOT NULL)`,
    "CREATE INDEX IF NOT EXISTS idx_alert_family_scripts_enabled_priority ON alert_family_scripts(enabled, priority)",
  ],
  // BH-3727 (BH-3719.1) — the dequeue-watch ledger, the same DDL as the
  // BH-3719.1 block of schema.sql; worker/jobs/test/dequeue-watch.bh-3719.test.js
  // (SCH-PARITY) compares the two table shapes.
  dequeue_events: [
    `CREATE TABLE IF NOT EXISTS dequeue_events (
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head TEXT NOT NULL,
       run_id TEXT NOT NULL,
       project TEXT NOT NULL,
       dequeued_at TEXT,
       run_url TEXT,
       comment_id TEXT,
       batch_size INTEGER,
       members TEXT,
       draft INTEGER,
       attribution TEXT,
       attribution_how TEXT,
       class TEXT CHECK (class IS NULL OR class IN (${DQW_CLASS_SQL})),
       class_how TEXT,
       rule_id TEXT,
       suites TEXT,
       fail_lines TEXT,
       llm_fp TEXT,
       llm_attempted_at TEXT,
       llm_class TEXT CHECK (llm_class IS NULL OR llm_class IN (${DQW_CLASS_SQL})),
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, pr, head, run_id))`,
    "CREATE INDEX IF NOT EXISTS idx_dequeue_events_llm_fp ON dequeue_events(llm_fp)",
    "CREATE INDEX IF NOT EXISTS idx_dequeue_events_created ON dequeue_events(created_at)",
  ],
  dequeue_actions: [
    `CREATE TABLE IF NOT EXISTS dequeue_actions (
       repo TEXT NOT NULL,
       pr INTEGER NOT NULL,
       head TEXT NOT NULL,
       class TEXT NOT NULL CHECK (class IN (${DQW_CLASS_SQL})),
       action TEXT NOT NULL CHECK (action IN ('requeue','lead-request','fix-round','main-red-wait','hold','observe')),
       status TEXT NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed','done','failed','waiting')),
       project TEXT NOT NULL,
       ref TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, pr, head, class))`,
    "CREATE INDEX IF NOT EXISTS idx_dequeue_actions_repo_pr_class ON dequeue_actions(repo, pr, class)",
    "CREATE INDEX IF NOT EXISTS idx_dequeue_actions_status_created ON dequeue_actions(status, created_at)",
  ],
  // BH-4082: the console's project registry (routes/projects.js), schema.sql's
  // DDL verbatim, self-created for the BH-1043 reason above.
  projects: [
    `CREATE TABLE IF NOT EXISTS projects (
       project TEXT PRIMARY KEY,
       repo TEXT NOT NULL,
       prod_url TEXT,
       board_api_prefix TEXT,
       cron_offset INTEGER NOT NULL,
       box TEXT,
       tailnet_ip TEXT,
       note TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL)`,
  ],
  // BH-5001 — the Fly pool's spawn ledger, terminal verdicts and holds
  // (routes/pool-state.js). schema.sql's DDL verbatim, self-created for the
  // BH-1043 reason above; test/pool-state.bh-5001.test.js compares the columns.
  pool_spawns: [
    `CREATE TABLE IF NOT EXISTS pool_spawns (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ts INTEGER NOT NULL,
       box TEXT NOT NULL,
       machine TEXT,
       created_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key, ts, box)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_pool_spawns_ts ON pool_spawns(project, ts)",
  ],
  pool_terminals: [
    `CREATE TABLE IF NOT EXISTS pool_terminals (
       project TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       branch TEXT,
       head_sha TEXT,
       reason TEXT,
       created_at TEXT NOT NULL,
       box TEXT,
       cleared_at TEXT,
       cleared_why TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, ticket_key)
     )`,
  ],
  pool_holds: [
    `CREATE TABLE IF NOT EXISTS pool_holds (
       project TEXT NOT NULL,
       kind TEXT NOT NULL,
       ticket_key TEXT NOT NULL,
       ticket_id TEXT,
       until_at INTEGER,
       why TEXT,
       first_seen TEXT,
       last_seen TEXT,
       box TEXT,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (project, kind, ticket_key)
     )`,
  ],
  // BH-5267 — each project's conflict hotspots and its latest measuring run
  // (routes/conflict-hotspots.js). schema.sql's DDL verbatim, self-created for
  // the BH-1043 reason above; test/conflict-hotspots-route.test.js compares them.
  conflict_hotspots: [
    `CREATE TABLE IF NOT EXISTS conflict_hotspots (
       project TEXT NOT NULL,
       file TEXT NOT NULL,
       conflicts INTEGER NOT NULL,
       rebases INTEGER NOT NULL,
       prs TEXT,
       window_days INTEGER NOT NULL,
       since TEXT NOT NULL,
       until TEXT NOT NULL,
       ref_sha TEXT,
       run_at TEXT NOT NULL,
       PRIMARY KEY (project, file)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_conflict_hotspots_rank ON conflict_hotspots(project, conflicts DESC, rebases DESC, file)",
  ],
  conflict_hotspot_runs: [
    `CREATE TABLE IF NOT EXISTS conflict_hotspot_runs (
       project TEXT PRIMARY KEY,
       repo TEXT,
       box TEXT,
       status TEXT NOT NULL,
       detail TEXT,
       window_days INTEGER,
       since TEXT,
       until TEXT,
       ref_sha TEXT,
       pr_merges INTEGER,
       sync_merges INTEGER,
       merge_tree_errors INTEGER,
       files_total INTEGER,
       rows_stored INTEGER,
       run_at TEXT NOT NULL,
       last_ok_at TEXT
     )`,
  ],
  // BH-5349 — the self-create copy of schema.sql's participant_machines block,
  // column for column (test/participants-schema.bh-5349.test.js pins the parity).
  participant_machines: [
    `CREATE TABLE IF NOT EXISTS participant_machines (
       id TEXT PRIMARY KEY,
       name TEXT NOT NULL UNIQUE,
       owner TEXT,
       requested_roles TEXT NOT NULL,
       granted_roles TEXT,
       token_sha256 TEXT NOT NULL UNIQUE,
       billing_account TEXT,
       status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','revoked')),
       requested_at TEXT NOT NULL,
       decided_by TEXT,
       decided_at TEXT,
       revoked_by TEXT,
       revoked_at TEXT,
       last_seen_at TEXT,
       knobs TEXT
     )`,
    "CREATE INDEX IF NOT EXISTS idx_participant_machines_status ON participant_machines(status)",
  ],
  // BH-5354.0 (BH-5366) — the suite ledger (routes/suite-results.js).
  // schema.sql's DDL verbatim, self-created for the BH-1043 reason above;
  // test/suite-results-schema.bh-5366.test.js compares the two.
  suite_results: [
    `CREATE TABLE IF NOT EXISTS suite_results (
       repo TEXT NOT NULL,
       ctx TEXT NOT NULL,
       class TEXT NOT NULL,
       suite TEXT NOT NULL,
       fingerprint TEXT NOT NULL,
       status TEXT NOT NULL,
       duration_s INTEGER,
       run_id TEXT NOT NULL,
       head_sha TEXT,
       ok_at TEXT,
       last_run_id TEXT NOT NULL,
       runs INTEGER NOT NULL DEFAULT 1,
       fails INTEGER NOT NULL DEFAULT 0,
       first_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, ctx, class, suite, fingerprint)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_suite_results_updated ON suite_results(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_suite_results_key ON suite_results(repo, ctx, suite, fingerprint)",
  ],
  suite_reuse_runs: [
    `CREATE TABLE IF NOT EXISTS suite_reuse_runs (
       repo TEXT NOT NULL,
       run_key TEXT NOT NULL,
       ctx TEXT NOT NULL,
       class TEXT NOT NULL,
       head_sha TEXT,
       ran INTEGER NOT NULL,
       reused INTEGER NOT NULL,
       total INTEGER NOT NULL,
       saved_s INTEGER NOT NULL DEFAULT 0,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL,
       PRIMARY KEY (repo, run_key)
     )`,
    "CREATE INDEX IF NOT EXISTS idx_suite_reuse_runs_created ON suite_reuse_runs(created_at)",
  ],
};
// Every table in the composed schema, with each override in place of its
// derived entry.
export const CREATED_TABLES = { ...createdTablesFrom(SCHEMA_SQL), ...CREATED_TABLE_OVERRIDES };
// Vocabulary for the Fly machine registry (BH-1054). Every writer fails open,
// so a state missing from this set is not a loud error anywhere: the write is
// refused with a 400, the caller prints nothing, and the row keeps saying
// whatever the last listing said. That is why the set carries BOTH the states
// the fleet writes and the ones `fly machine list --json` can report
// mid-transition (`replacing`, `suspending`) — an unknown state in a listing
// costs the whole observe sweep, not just that machine.
//
// TERMINAL IS A SHORTER LIST THAN "BAD". `destroyed`/`gone` are the end of a
// machine; `destroy_failed` is NOT — the machine is still there and the pool
// sweep retries the destroy (bin/fly-pool.sh), so it must stay out of
// MACHINE_TERMINAL or a live machine gets an ended_at and drops out of
// `live=1`.
export const MACHINE_STATES = new Set([
  "created", "starting", "started", "stopping", "stopped",
  "replacing", "destroying", "destroyed", "suspended", "suspending", "gone",
  "spawned", "failed", "destroy_failed"
]);
export const MACHINE_TERMINAL = new Set(["destroyed", "gone"]);

export const createdTablesReady = new WeakMap();
export async function ensureTable(env, table) {
  const db = env.DB;
  // Keyed on the raw binding, as in ensureColumns.
  let per = createdTablesReady.get(rawDb(db));
  if (!per) { per = new Map(); createdTablesReady.set(rawDb(db), per); }
  if (per.has(table)) return per.get(table);
  const p = (async () => {
    for (const sql of CREATED_TABLES[table] || []) await db.prepare(sql).run();
  })();
  per.set(table, p);
  // Same rule as ensureColumns: a failed create is not cached as "done".
  p.catch(() => per.delete(table));
  return p;
}

// ── Lane liveness (2026-08-30) ───────────────────────────────────────────────
// A lane is one (project, box) pair — the unit fleet.conf declares and the unit
// a crontab loses. See the `lanes` table comment in schema.sql for the incident
// this exists for and for why the hub and the boxes write disjoint columns.
//
// THE THRESHOLD IS DERIVED FROM THE CADENCE, not hand-set per lane: three
// missed ticks, floored at half an hour. The floor is what stops a fast lane
// from being called dead for missing one tick, and deriving the rest means a
// lane that ticks hourly is not judged on a ten-minute lane's clock. The number
// rides on every row the API hands back, so a reader never has to guess which
// threshold produced a verdict.
export const LANE_STALE_TICKS = 3;
export const LANE_STALE_FLOOR_S = 1800;
export const LANE_DEFAULT_CADENCE_MIN = 10;

// THE PROCESS HALF'S OWN THRESHOLD (BH-1031). Same shape as the cron half and
// deliberately not the same numbers: a long-lived lane beats every ~300 s, so
// three missed beats is fifteen minutes, floored at ten so a lane that declares
// a one-second rhythm (WAKE_LOOP_INTERVAL_S=0 reads as 1) is not called dead
// for one slow pass. The number rides on the row, so the reaper's page and the
// console's red are one threshold rather than two that can drift.
export const LANE_PROC_STALE_TICKS = 3;
export const LANE_PROC_STALE_FLOOR_S = 600;
export const LANE_PROC_DEFAULT_INTERVAL_S = 300;

// THE HUB LEASE'S CLOCK BUDGET (BH-429). The client renews once a minute, so a
// 180 s lease survives two missed renews before anyone else may take it — long
// enough that a slow tick is not a failover, short enough that a dead box stops
// being the hub within three minutes. A caller may ask for its own ttl, but
// only inside [60, 900]: under a minute and one missed renew is a failover,
// over fifteen and a dead hub stays the hub for a quarter of an hour.
export const HUB_LEASE_TTL_S = 180;
export const HUB_LEASE_TTL_MIN_S = 60;
export const HUB_LEASE_TTL_MAX_S = 900;

// FLEET FILE CLAIMS' BOUNDS (BH-2627, BH-2524.0). A claim's ttl must sit in
// [FILE_CLAIM_TTL_MIN_S, FILE_CLAIM_TTL_MAX_S], the same range as the
// FILE_CLAIM_TTL_S registry knob; an overlap not-before window may be at most
// OVERLAP_NB_MAX_S ahead; one project's claim list returns at most
// FILE_CLAIM_LIST_MAX live claims. Read by routes/file-claims.js (BH-2628).
export const FILE_CLAIM_TTL_MIN_S = 60;
export const FILE_CLAIM_TTL_MAX_S = 86400;
export const OVERLAP_NB_MAX_S = 86400;
export const FILE_CLAIM_LIST_MAX = 200;

// A lane name becomes half a primary key and travels through a shell client, so
// it is held to the same character class bin/box-name.sh sanitises with.
export function laneName(v) {
  const s = String(v === undefined || v === null ? "" : v).trim();
  return /^[A-Za-z0-9._-]{1,64}$/.test(s) ? s : "";
}

// SILENCE IS MEASURED FROM THE LATER OF THE TWO CLOCKS — the last tick and the
// declaration — and never from the tick alone. Two shapes need that:
//
//   never ticked at all: a NULL has no age, so aging only `last_tick_at` would
//     leave the incident's twin (a box whose bootstrap never ran) reading
//     healthy forever. The declaration is what gets aged instead.
//   re-declared after retirement: retire/revive keeps `last_tick_at`, so a lane
//     dropped from fleet.conf months ago and added back today carries an
//     ancient tick. Taking the tick would make it instantly `stale` — pages
//     within five minutes, blaming a lost crontab — on the exact event an
//     operator is standing there watching. The declaration is newer, so it
//     wins, and the lane gets a full threshold to prove itself.
//
// Taking the later of the two is a strict improvement on every other path as
// well: on a normally ticking lane the tick IS the later one.
export function decorateLane(row, now) {
  const declared = Number(row.cadence_min) > 0 ? Number(row.cadence_min) : LANE_DEFAULT_CADENCE_MIN;
  const staleAfter = Math.max(LANE_STALE_FLOOR_S, declared * 60 * LANE_STALE_TICKS);
  const tickAge = row.last_tick_at ? ageSeconds(row.last_tick_at, now) : null;
  const tickMs = Date.parse(row.last_tick_at || "");
  const declaredMs = Date.parse(row.expected_since || "");
  // "Has this lane ticked since the expectation currently in force was made?"
  // A revived lane answers NO while still carrying a real last_tick_at, which
  // is why this is its own fact and not `Boolean(last_tick_at)`.
  const tickedSinceDeclared = Number.isFinite(tickMs)
    && (!Number.isFinite(declaredMs) || tickMs >= declaredMs);
  const reference = tickedSinceDeclared ? row.last_tick_at : (row.expected_since || row.last_tick_at || null);
  const silence = reference ? ageSeconds(reference, now) : null;
  let state;
  if (row.retired_at) state = "retired";
  // Ticking but never declared. Worth SEEING — a box beating a lane fleet.conf
  // has never heard of is a real fact — but never alertable: it would be judged
  // against an expectation nobody made.
  else if (!row.expected_since) state = "unexpected";
  else if (silence !== null && silence > staleAfter) state = "stale";
  // PENDING covers both "never ticked yet" and "has not ticked since it was
  // re-declared". Calling a revived lane `live` would claim it is ticking on
  // schedule before it has ticked once under the expectation now in force.
  else if (!tickedSinceDeclared) state = "pending";
  else state = "live";
  // ── THE PROCESS HALF (BH-1031) ───────────────────────────────────
  // Judged on its OWN clock, never on the cron one, because the whole point of
  // the slice is the case where they disagree: the crontab keeps firing on a
  // box whose merge-conductor died, so `state` reads `live` and the lane is not
  // doing any work. Two facts, one row, and the reader is told both.
  //
  // SILENCE IS THE ONLY TEST AVAILABLE HERE. A pid means nothing on this side
  // of the network — the process is on another machine — so `dead` is not a
  // word this function is entitled to. It says the beats stopped (`silent`) or
  // the lane is past the expected-by it declared (`overdue`), and the box-local
  // reaper, which CAN probe the pid, says the rest.
  const procInterval = Number(row.proc_interval_s) > 0
    ? Number(row.proc_interval_s) : LANE_PROC_DEFAULT_INTERVAL_S;
  const procStaleAfter = Math.max(LANE_PROC_STALE_FLOOR_S, procInterval * LANE_PROC_STALE_TICKS);
  const procAge = row.proc_beat_at ? ageSeconds(row.proc_beat_at, now) : null;
  const endedMs = Date.parse(row.proc_ended_at || "");
  const beatMs = Date.parse(row.proc_beat_at || "");
  const nowMs = Date.parse(now);
  const deadlineMs = Date.parse(row.proc_deadline_at || "");
  let procState;
  if (!row.proc_beat_at) procState = "none";
  // A CLEAN EXIT IS NOT A DEATH. hb_done stamps proc_ended_at, and a lane that
  // finished on purpose must never page — otherwise every completed run would.
  // The comparison is against the last beat so a relaunch (which beats after
  // the previous instance ended) is live again without anyone clearing a flag.
  else if (Number.isFinite(endedMs) && Number.isFinite(beatMs) && endedMs >= beatMs) procState = "ended";
  else if (procAge !== null && procAge > procStaleAfter) procState = "silent";
  else if (Number.isFinite(deadlineMs) && Number.isFinite(nowMs) && nowMs > deadlineMs) procState = "overdue";
  else procState = "fresh";
  return {
    ...row,
    cadence_min: declared,
    stale_after_s: staleAfter,
    tick_age_s: tickAge,
    silence_s: silence,
    expected: Boolean(row.expected_since) && !row.retired_at,
    never_ticked: !row.last_tick_at,
    ticked_since_declared: tickedSinceDeclared,
    state,
    stale: state === "stale",
    proc_state: procState,
    proc_age_s: procAge,
    proc_stale_after_s: procStaleAfter,
    proc_stale: procState === "silent" || procState === "overdue",
  };
}

// ── Fly machine registry, reader side (BH-1055) ──────────────────────────────
// The two ages every reader of the `machines` table wants, computed here so no
// caller has to subtract ISO stamps by hand — and computed on the SERVER clock
// for the same reason every other age in this worker is (a fly builder's clock
// is whatever its image booted with).
//
// NULL, NEVER ZERO, when the stamp is missing: "never listed by Fly" and
// "listed this second" are different facts, and a 0 would read as the second.
export function decorateMachine(row, now) {
  return {
    ...row,
    age_s: row.spawned_at ? ageSeconds(row.spawned_at, now) : null,
    seen_age_s: row.last_seen ? ageSeconds(row.last_seen, now) : null,
  };
}
// A registered machine is either a per-ticket builder or a member of a pool.
// Nothing else has a lifecycle this table can describe.
export const MACHINE_ROLES = new Set(["builder", "pool"]);
// ONE Fly listing per observe call, bounded: D1 binds at most 100 parameters
// per statement and a batch is a transaction, so an unbounded listing would be
// an unbounded transaction. Over the cap the call says `capped:true` and the
// sweep is skipped — see the observe route for why.
export const OBSERVE_CAP = 200;
// The grace a machine gets between being created and appearing in a listing.
// Without it, a machine spawned right after the tick read its listing would be
// called `gone` by the very next observe.
export const OBSERVE_GRACE_S = 1800;
// `detail` is a human-readable note on a row, not a log. Over the cap is a 400,
// never a truncation: half an error message reads like a whole one.
export const MACHINE_DETAIL_MAX = 300;
// Optional strings on a machine row: empty becomes NULL, so COALESCE in the
// upserts means "keep whatever is already stored" rather than "blank it".
export function machineStr(v, n) {
  return v === undefined || v === null || v === "" ? null : String(v).slice(0, n);
}

// EXPIRY IS THE SERVER'S CALL, ALWAYS. `expired` uses the same lexicographic
// comparison SQLite makes in the lease's compare-and-swaps — both sides are
// only ever written by nowIso()/isoPlusSeconds() (ISO seconds, Z), so string
// order is time order — which means a GET can never disagree with the renew
// that runs a millisecond later. `remaining_s` floors at 0: an expired lease
// has no time left, and a negative number reads like a countdown.
export function decorateLease(row, now) {
  if (!row) return null;
  const expired = String(row.expires_at) <= now;
  return {
    holder: row.holder,
    epoch: Number(row.epoch),
    expires_at: row.expires_at,
    updated_at: row.updated_at,
    expired,
    remaining_s: expired ? 0 : Math.round((Date.parse(row.expires_at) - Date.parse(now)) / 1000),
  };
}
export function leaseTtl(v) {
  const n = intOrNull(v);
  if (n === null) return HUB_LEASE_TTL_S;
  return Math.min(HUB_LEASE_TTL_MAX_S, Math.max(HUB_LEASE_TTL_MIN_S, n));
}
export function isoPlusSeconds(iso, s) {
  return new Date(Date.parse(iso) + s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}
// A missing `meta` is "did not win", never "won": the ladder falls through to
// the next statement and at worst ends on the fail-closed 409.
export function leaseWon(r) { return ((r && r.meta && Number(r.meta.changes)) || 0) > 0; }
// The row is RE-READ after every write, so the answer is what the table holds
// rather than what the caller was hoping to write.
export async function readLease(env, now) {
  return decorateLease(await env.DB.prepare("SELECT * FROM hub_lease WHERE id=1").first(), now);
}

// ── SHARED FACTS (BH-1043, audit §2.4) ───────────────────────────────────────
// An account's lease cap and a token's GitHub budget were both kept as per-BOX
// files, and both are only true fleet-wide. See the schema.sql comments for the
// two incidents; what lives here is the arithmetic and the compare-and-swap.
//
// THE CAP IS CHECKED INSIDE THE INSERT. A read-then-write would let two boxes
// both see the last slot free in the same millisecond and both be told they
// won, which is the exact bug — the file version's failure mode, reproduced in
// the fix. The count subquery excludes the claimant's own row so a machine
// renewing its lease can never be refused by itself, and counts only rows that
// have not expired on the SERVER's clock (fleet boxes ran 66-464 s slow on
// 2026-09-14; expiry is never judged on a box's clock).
//
// A LEASE IS NOT A REFUSAL TO LAUNCH. The client maps 409 to "try the next
// account" and an outage to "take this one" — bin/lib/pool-account.sh is
// fail-open by construction, because a build that does not happen is worse than
// a build on a busy account.
export const ACCOUNT_LEASE_TTL_S = 10800;      // matches ACCOUNT_LEASE_TTL_SECS on the box
export const ACCOUNT_LEASE_TTL_MIN_S = 60;
export const ACCOUNT_LEASE_TTL_MAX_S = 86400;
export const ACCOUNT_LEASE_CAP = 4;            // fly/account-capacity.conf's claude row
export const ACCOUNT_LEASE_CAP_MAX = 64;
// cap 0 means "no cap", and the statement still needs a number to compare
// against: a bound that no real fleet can reach is how "unlimited" is expressed
// without a second branch of SQL that could disagree with the first.
export const ACCOUNT_LEASE_UNCAPPED = 1000000;
// ONE statement. Every predicate that decides the outcome is in it.
export const ACCOUNT_LEASE_CLAIM_SQL =
  "INSERT INTO account_leases (account, machine_id, box, project, ticket_key, expires_at, created_at, updated_at) "
  + "SELECT ?1,?2,?3,?4,?5,?6,?7,?7 WHERE "
  + "(SELECT COUNT(*) FROM account_leases WHERE account=?1 AND machine_id<>?2 AND expires_at>?7) < ?8 "
  + "ON CONFLICT(account, machine_id) DO UPDATE SET box=excluded.box, project=excluded.project, "
  + "ticket_key=excluded.ticket_key, expires_at=excluded.expires_at, updated_at=excluded.updated_at";

// ── Fleet cooldowns (BH-2353 / BH-2319.1) ────────────────────────────────────
// One row per (kind, vendor, subject), seen by every box. Keys and the upsert
// rule are the contract in bin/lib/fleet-cooldown.sh. An until more than
// COOLDOWN_MAX_S (8 days) out is refused, never clamped.
export const COOLDOWN_KINDS = ["account", "model", "lane"];
export const COOLDOWN_MAX_S = 691200;
// laneName, or for kind model exactly one "/" between two laneName parts
// (<model>/<account>). "" when the subject is not valid for the kind.
export function cooldownSubject(kind, v) {
  const s = laneName(v);
  if (s) return s;
  if (kind !== "model") return "";
  const parts = String(v === undefined || v === null ? "" : v).trim().split("/");
  return parts.length === 2 && parts.every((p) => p !== "" && laneName(p) === p) ? parts.join("/") : "";
}
// ONE statement, so two boxes writing the same key cannot race a read. until_at
// is a TEXT column (the contract's DDL), so every numeric compare CASTs: as text
// '99999' > '100000'. account/model keep the later until, lane takes the new one.
export const COOLDOWN_PUT_SQL =
  "INSERT INTO fleet_cooldowns (kind, vendor, subject, until_at, since_at, reason, box, set_at) "
  + "VALUES (?1,?2,?3,?4,?5,?6,?7,?8) "
  + "ON CONFLICT(kind, vendor, subject) DO UPDATE SET until_at = CASE WHEN excluded.kind = 'lane' "
  + "THEN excluded.until_at ELSE MAX(CAST(fleet_cooldowns.until_at AS INTEGER), CAST(excluded.until_at AS INTEGER)) END, "
  + "since_at = COALESCE(fleet_cooldowns.since_at, excluded.since_at), "
  + "reason = excluded.reason, box = excluded.box, set_at = excluded.set_at";

export function accountLeaseTtl(v) {
  const n = intOrNull(v);
  if (n === null) return ACCOUNT_LEASE_TTL_S;
  return Math.min(ACCOUNT_LEASE_TTL_MAX_S, Math.max(ACCOUNT_LEASE_TTL_MIN_S, n));
}
export async function accountLeaseLive(env, account, t) {
  const r = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM account_leases WHERE account=?1 AND expires_at>?2"
  ).bind(account, t).first();
  return Number((r && r.n) || 0);
}

// The row the shell client reads, nested the way the file cache it replaces is
// shaped, so bin/lib/gh-budget.sh can write it straight into that cache.
export async function ghBudgetRow(env, fp) {
  const r = await env.DB.prepare("SELECT * FROM gh_budget WHERE fingerprint=?1").bind(fp).first();
  if (!r) return null;
  return {
    fingerprint: r.fingerprint,
    fetched_at: Number(r.fetched_at),
    box: r.box || null,
    core: { remaining: numOrNull(r.core_remaining), limit: numOrNull(r.core_limit), reset: numOrNull(r.core_reset) },
    graphql: { remaining: numOrNull(r.graphql_remaining), limit: numOrNull(r.graphql_limit), reset: numOrNull(r.graphql_reset) },
    updated_at: r.updated_at,
  };
}

export function jobId(kind, project, ticket, ts) {
  const slug = (s) => String(s || "").replace(/[^A-Za-z0-9._-]/g, "-").slice(0, 48);
  return [slug(kind), slug(project), slug(ticket || "noticket"), ts].filter(Boolean).join("-");
}

// ── DORA derivation (2026-09-12) ─────────────────────────────────────────────
// Exported so a test can drive the maths without a Request, and kept as one
// pure function so the route below is nothing but five reads and a call.
//
// EVERY RULE HERE EXISTS BECAUSE THE OBVIOUS VERSION LIES:
//   * a PR whose timestamps do not parse is DROPPED, never counted at zero — a
//     zero lead time is the most flattering wrong answer this could give.
//   * `bad` counts DISTINCT PRs, never finding rows, so a PR that was reverted
//     AND reopened cannot push a rate past 1 (the same rule the OUTCOMES screen
//     and bin/review-tighten.sh already count by).
//   * a metric with no measurable sample is null with n=0, never 0.

// https://github.com/<owner>/<name>/pull/<n> -> "<owner>/<name>". Untrusted:
// these urls reach D1 from shell, so a near-miss yields null, not a guess.
export function doraRepo(url) {
  if (!url || typeof url !== "string") return null;
  const m = url.match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+(?:[/?#].*)?$/);
  return m ? m[1] : null;
}

export function doraPrNumber(url) {
  if (!url || typeof url !== "string") return null;
  const m = url.match(/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/(\d+)(?:[/?#].*)?$/);
  return m ? Number(m[1]) : null;
}

// `owner/repo#N` (the pr_state key) -> the PR url the merge ledger is keyed on.
export function prUrlFromStateKey(key) {
  if (!key || typeof key !== "string") return null;
  const m = key.match(/^([^/\s]+\/[^#\s]+)#(\d+)$/);
  return m ? `https://github.com/${m[1]}/pull/${m[2]}` : null;
}

export const doraMs = (iso) => {
  if (!iso || typeof iso !== "string") return null;
  const v = Date.parse(iso);
  return Number.isNaN(v) ? null : v;
};

// Nearest-rank percentile over an ASCENDING array. Nearest-rank and not a
// linear interpolation on purpose: every value here is a real observed
// duration, and a p90 naming an interval nothing actually took is harder to act
// on than one naming a PR you can go and open.
export function percentile(sortedAsc, p) {
  if (!sortedAsc || !sortedAsc.length) return null;
  const rank = Math.ceil((p / 100) * sortedAsc.length);
  return sortedAsc[Math.min(Math.max(rank, 1), sortedAsc.length) - 1];
}

export function doraStats(values) {
  const xs = values.filter((v) => Number.isFinite(v) && v >= 0).sort((a, b) => a - b);
  return { p50_s: percentile(xs, 50), p90_s: percentile(xs, 90), n: xs.length };
}

// The failures that mean "this merge did not hold". `merged_then_red` is
// tracked and reported beside the rate but is NOT in it — the same split
// bin/outcome-metrics.sh and the OUTCOMES screen already make.
export const DORA_BAD = new Set(["reverted", "reopened"]);

// A `deploy` ledger key, as bin/deploy-train.sh writes it:
// "<owner>/<repo>@<sha production was verified to be serving>". Untrusted, same
// as every other key here — a near-miss yields null rather than a repo slug
// this code invented.
export function doraDeployRepo(key) {
  if (!key || typeof key !== "string") return null;
  const m = key.match(/^([^/\s@]+\/[^\s@]+)@([0-9a-fA-F]{7,40})$/);
  return m ? m[1] : null;
}

// The one sentence that says which two instants the launch figure spans. It
// rides on every row rather than living in the console, so a reader never has
// to guess whether a number measures the board's wait or the fleet's.
export const LAUNCH_BASIS = "issue created → first build job registered (jobs.issue_created_at → jobs.first_spawn_at)";

export function computeDora({
  days, since, now, project: wantProject,
  merges = [], artifacts = [], outcomes = [], prStates = [], repoMap = [], deploys = [],
  // `launches` is NULL, not empty, when the read behind it failed: an empty
  // window is a measured zero, a failed read is no measurement at all, and the
  // payload must not render them the same way.
  launches = [], launchesError = null, launchesCapped = false,
}) {
  const sinceMs = doraMs(since) ?? (now - days * 86400000);

  // ── attribution: PR url -> the job that opened it, and repo -> project ────
  const byPr = new Map();         // pr url -> { project, job_id, job_created_at, ticket_id }
  const verdictByJob = new Map(); // job id -> approval instant (ms)
  const repoProject = new Map();

  for (const a of artifacts) {
    if (!a) continue;
    // BH-1024: bin/review-prs.sh writes a PR's url onto TWO jobs of its own —
    // the `review` lane claim `review_claim` opens per (PR, sha) (the BH-1064
    // block puts `verdict` + `pr_url` on it) and the short-lived
    // `review-verdict` job. Both are minutes old and built nothing, so
    // attributing an external PR's merge to either would report a one-minute
    // lead time for a week of somebody else's work, and their APPROVE would
    // become the approval a merge lane waited on. Neither is a fact about the
    // change, so both job kinds are skipped here.
    if (a.job_kind === "review-verdict" || a.job_kind === "review") continue;
    if (a.artifact_kind === "pr_url") {
      const url = String(a.artifact_ref || "");
      const repo = doraRepo(url);
      if (!repo) continue;
      const rec = {
        project: a.project || null,
        job_id: a.job_id || null,
        // The job's own creation is when the fleet started on the ticket: the
        // earliest instant in D1 that belongs to this change.
        job_created_at: doraMs(a.job_created_at),
        ticket_id: a.ticket_id || null,
      };
      // The EARLIEST job wins. A rebuild or a takeover opens a second job
      // against the same PR, and taking the newer one would report the lead
      // time of the last attempt as the lead time of the change.
      const prev = byPr.get(url);
      if (!prev) byPr.set(url, rec);
      else if (rec.job_created_at !== null
        && (prev.job_created_at === null || rec.job_created_at < prev.job_created_at)) {
        byPr.set(url, rec);
      }
      if (a.project && !repoProject.has(repo)) repoProject.set(repo, a.project);
    } else if (a.artifact_kind === "verdict") {
      // Only an APPROVE starts the merge-lane clock; a BLOCK is the lane not
      // being entered. `updated_at`, not created_at: the row is keyed
      // (job_id, artifact_kind), so a re-review overwrites it and the LATEST
      // approval is the one the landing was actually bound to.
      if (String(a.artifact_ref || "").toUpperCase() !== "APPROVE") continue;
      const at = doraMs(a.updated_at) ?? doraMs(a.created_at);
      if (at === null || !a.job_id) continue;
      verdictByJob.set(a.job_id, at);
    }
  }
  for (const q of repoMap) {
    if (q && q.repo && q.project && !repoProject.has(q.repo)) repoProject.set(q.repo, q.project);
  }

  // ── verified production departures ────────────────────────────────────────
  // bin/deploy-train.sh writes one `deploy` row per departure: keyed on the sha
  // production was verified to be SERVING, status verified|failed, with the
  // batch's shas and PR urls in the detail. It is the only record in D1 that a
  // merge reached anybody, and without it the two metrics below stop at main.
  //
  // TWO WAYS TO ATTACH A MERGE TO A DEPARTURE, in this order:
  //   1. the departure NAMES the PR (its build dir carried a PR_CREATED line) —
  //      exact, and the only one that survives two repos deploying in lockstep;
  //   2. otherwise the earliest verified arrival for that repo AT OR AFTER the
  //      merge. A merge-queue or self-sourced departure has no build dir to
  //      read a PR url out of, and without this those measure nothing at all.
  // A departure that arrived BEFORE the merge is never either: taking it would
  // report a negative deploy time as the fastest lead time on the screen.
  const deployByPr = new Map();          // pr url -> earliest verified instant (ms)
  const deployTimesByRepo = new Map();   // repo -> verified instants, ascending
  const departuresByProject = new Map(); // project -> Set of deploy keys
  const failedByProject = new Map();     // project -> count of departures that never arrived
  for (const d of deploys) {
    if (!d) continue;
    const key = String(d.key || "");
    const repo = doraDeployRepo(key);
    if (!repo) continue;
    let detail = {};
    try { detail = JSON.parse(d.detail || "{}") || {}; } catch { detail = {}; }
    const project = detail.project || repoProject.get(repo) || null;
    if (wantProject && project !== wantProject) continue;
    // The train's own clock where it wrote one; the row's creation otherwise.
    // Never updated_at: a failed row later upserted to verified moves it, and a
    // departure that is re-verified is not a second deployment.
    const at = doraMs(detail.verified_at) ?? doraMs(detail.failed_at) ?? doraMs(d.created_at);
    if (at === null || at < sinceMs) continue;
    if (d.status !== "verified") {
      failedByProject.set(project, (failedByProject.get(project) || 0) + 1);
      continue;
    }
    if (!departuresByProject.has(project)) departuresByProject.set(project, new Set());
    departuresByProject.get(project).add(key);
    if (!deployTimesByRepo.has(repo)) deployTimesByRepo.set(repo, []);
    deployTimesByRepo.get(repo).push(at);
    for (const raw of Array.isArray(detail.prs) ? detail.prs : []) {
      const url = String(raw || "");
      if (!doraRepo(url)) continue;
      // The EARLIEST arrival wins: a PR that rode a second train after a failed
      // departure reached production the first time it was actually served.
      const prev = deployByPr.get(url);
      if (prev === undefined || at < prev) deployByPr.set(url, at);
    }
  }
  for (const list of deployTimesByRepo.values()) list.sort((a, b) => a - b);

  const deployedAt = (url, repo, mergedMs) => {
    const exact = deployByPr.get(url);
    if (exact !== undefined && exact >= mergedMs) return exact;
    for (const at of deployTimesByRepo.get(repo) || []) if (at >= mergedMs) return at;
    return null;
  };

  // The conductor's current row is the only record of when a PR was first SEEN.
  // It is the lead-time fallback for a PR no job claims (a hand-opened PR, or
  // one whose job predates the attribution window).
  const firstSeen = new Map();
  for (const s of prStates) {
    const url = prUrlFromStateKey(s && s.key);
    const at = doraMs(s && s.created_at);
    if (url && at !== null) firstSeen.set(url, at);
  }

  // ── the merged set ────────────────────────────────────────────────────────
  const landed = [];
  const mergedByRepo = new Map();
  for (const m of merges) {
    if (!m || m.status !== "merged") continue;
    const url = String(m.key || "");
    const repo = doraRepo(url);
    const at = doraMs(m.created_at);
    // A merge nobody can place in time is dropped from BOTH sides of every
    // rate — inflating a denominator is how a change-failure rate improves for
    // free.
    if (!repo || at === null || at < sinceMs) continue;
    const attr = byPr.get(url) || {};
    const project = attr.project || repoProject.get(repo) || null;
    if (wantProject && project !== wantProject) continue;
    const start = attr.job_created_at ?? firstSeen.get(url) ?? null;
    const approvedAt = attr.job_id ? (verdictByJob.get(attr.job_id) ?? null) : null;
    // Where the clock STOPS. `merged` is the honest answer for a project whose
    // train never departed (no VERSION_URL, or nothing recorded yet) and the
    // reason lead_end rides on every row rather than being inferred from a
    // per-project flag: one project can have both.
    const liveAt = deployedAt(url, repo, at);
    const end = liveAt ?? at;
    const row = {
      pr: url, repo, number: doraPrNumber(url), project,
      merged_at: m.created_at,
      deployed_at: liveAt === null ? null : new Date(liveAt).toISOString().replace(/\.\d{3}Z$/, "Z"),
      job_id: attr.job_id || null,
      ticket_id: attr.ticket_id || null,
      lead_s: start === null ? null : Math.max(0, Math.round((end - start) / 1000)),
      lead_basis: attr.job_created_at != null ? "job_created"
        : firstSeen.has(url) ? "pr_first_seen" : null,
      lead_end: liveAt === null ? "merged" : "deploy_verified",
      approval_to_merge_s: approvedAt === null
        ? null : Math.max(0, Math.round((at - approvedAt) / 1000)),
      merged_ms: at,
    };
    landed.push(row);
    if (!mergedByRepo.has(repo)) mergedByRepo.set(repo, []);
    mergedByRepo.get(repo).push(row);
  }

  // ── failures ──────────────────────────────────────────────────────────────
  // Keyed on the PR, so one PR carrying two findings is one bad merge.
  const failures = [];
  const badByProject = new Map();
  const redByProject = new Map();
  for (const o of outcomes) {
    if (!o || !o.outcome) continue;
    const url = String(o.pr || "");
    const repo = doraRepo(url) || o.repo || null;
    if (!repo) continue;
    const project = (byPr.get(url) || {}).project || repoProject.get(repo) || null;
    if (wantProject && project !== wantProject) continue;
    const key = url || `${repo}:${o.pr}`;
    if (o.outcome === "merged_then_red") {
      if (!redByProject.has(project)) redByProject.set(project, new Set());
      redByProject.get(project).add(key);
      continue;
    }
    if (!DORA_BAD.has(o.outcome)) continue;
    if (!badByProject.has(project)) badByProject.set(project, new Set());
    badByProject.get(project).add(key);
    const at = doraMs(o.created_at);
    if (at !== null) failures.push({ project, repo, pr: url, outcome: o.outcome, at });
  }

  // ── time to restore ───────────────────────────────────────────────────────
  // The restore is the NEXT merge into the same repo after the failure was
  // recorded. An upper bound, and the payload says so: a repo that merges
  // nothing for a week reads as a week to restore even if the fix was a config
  // change, and outcome_metrics.created_at is the detector's clock, not the
  // incident's. It is still the only restore signal this fleet writes down.
  const ttrByProject = new Map();
  const unrestored = new Map();
  for (const f of failures) {
    const after = (mergedByRepo.get(f.repo) || [])
      .filter((r) => r.merged_ms > f.at)
      .sort((a, b) => a.merged_ms - b.merged_ms)[0];
    if (!after) {
      unrestored.set(f.project, (unrestored.get(f.project) || 0) + 1);
      continue;
    }
    if (!ttrByProject.has(f.project)) ttrByProject.set(f.project, []);
    ttrByProject.get(f.project).push(Math.round((after.merged_ms - f.at) / 1000));
  }

  // ── launch lead time ──────────────────────────────────────────────────────
  // How long a ticket waited between being written on the board and this fleet
  // putting an agent on it: one grouped row per (project, ticket), both stamps
  // already non-null by the time the read hands them over. A row whose stamps
  // do not parse, or whose spawn reads EARLIER than its issue (clock skew, a
  // hand-filed stamp), is DROPPED and counted as such — averaging it in would
  // print a negative wait as the fastest launch on the screen.
  const launchByProject = new Map(); // project -> { secs: [], dropped: n }
  for (const l of launches || []) {
    if (!l) continue;
    const project = l.project || null;
    if (wantProject && project !== wantProject) continue;
    if (!launchByProject.has(project)) launchByProject.set(project, { secs: [], dropped: 0 });
    const bucket = launchByProject.get(project);
    const issuedMs = doraMs(l.issue_created_at);
    const spawnMs = doraMs(l.first_spawn_at);
    if (issuedMs === null || spawnMs === null || spawnMs < issuedMs) {
      bucket.dropped += 1;
      continue;
    }
    bucket.secs.push(Math.round((spawnMs - issuedMs) / 1000));
  }
  let allLaunchSecs = [];
  let allLaunchDropped = 0;
  for (const b of launchByProject.values()) {
    allLaunchSecs = allLaunchSecs.concat(b.secs);
    allLaunchDropped += b.dropped;
  }

  // ── per project ───────────────────────────────────────────────────────────
  const names = new Set();
  for (const r of landed) names.add(r.project);
  for (const p of badByProject.keys()) names.add(p);
  for (const p of redByProject.keys()) names.add(p);
  // A project that departed but merged nothing IN this window is still a
  // project that deployed. Leaving it out would drop its departures from the
  // table while totals.departures still counted them.
  for (const p of departuresByProject.keys()) names.add(p);
  for (const p of failedByProject.keys()) names.add(p);
  // Same precedent as the departures line above: a project whose tickets were
  // picked up in this window but whose work has not merged yet is still a
  // project with a launch lead time, and leaving it out would drop its rows
  // from the table while totals.launch_lead_time still counted them.
  for (const p of launchByProject.keys()) names.add(p);

  const projects = [...names].map((name) => {
    const rows = landed.filter((r) => r.project === name);
    const lead = doraStats(rows.map((r) => r.lead_s).filter((v) => v !== null));
    const lane = doraStats(rows.map((r) => r.approval_to_merge_s).filter((v) => v !== null));
    const ttr = doraStats(ttrByProject.get(name) || []);
    const merged = rows.length;
    const bad = (badByProject.get(name) || new Set()).size;
    const measurable = rows.filter((r) => r.lead_s !== null);
    const toDeploy = measurable.filter((r) => r.lead_end === "deploy_verified").length;
    const toMerge = measurable.length - toDeploy;
    const departures = (departuresByProject.get(name) || new Set()).size;
    const failedDepartures = failedByProject.get(name) || 0;
    return {
      project: name,
      repos: [...new Set(rows.map((r) => r.repo))].sort(),
      merged,
      lead_time: {
        ...lead,
        // Two bases averaged into one column would be two different
        // measurements pretending to be one, so both counts ride along and the
        // console names them.
        from_job_n: rows.filter((r) => r.lead_basis === "job_created").length,
        from_pr_seen_n: rows.filter((r) => r.lead_basis === "pr_first_seen").length,
        unattributed_n: rows.filter((r) => r.lead_basis === null).length,
        // Where each row's clock STOPPED, counted rather than averaged — the
        // same rule as the two start bases above. A column mixing "to main"
        // with "to production" under one label is two measurements wearing one
        // name, and the slower one is the one that matters.
        to_deploy_n: toDeploy,
        to_merge_n: toMerge,
        basis: toDeploy === 0
          ? "build job created → PR merged"
          : toMerge === 0
            ? "build job created → production verified serving it"
            : "build job created → production verified serving it where a departure was recorded, else PR merged",
        deploy_verified: toDeploy > 0,
        evidence: "jobs.created_at (via job_artifacts.artifact_kind='pr_url') → ledgers(kind='merge').created_at"
          + (toDeploy > 0
            ? " → ledgers(kind='deploy', status='verified').detail.verified_at, written by bin/deploy-train.sh"
            : ""),
      },
      // Departures when the train recorded any, merges otherwise — and the row
      // says which. A train carries a BATCH, so merges/day OVERCOUNTS: the
      // moment there is a real departure count, reporting merges instead would
      // be choosing the flattering number over the measured one.
      deployment_frequency: departures > 0 || failedDepartures > 0
        ? {
          per_day: departures === 0 ? 0 : Number((departures / days).toFixed(3)),
          count: departures,
          days,
          merges: merged,
          failed_departures: failedDepartures,
          basis: "verified production departures per day (a train carries a batch, so this sits below merges/day by design)",
          deploy_verified: true,
          evidence: "ledgers(kind='deploy', status='verified'), written by bin/deploy-train.sh on its VERIFIED branch",
        }
        : {
          per_day: merged === 0 ? 0 : Number((merged / days).toFixed(3)),
          count: merged,
          days,
          merges: merged,
          failed_departures: 0,
          basis: "merges per day — NOT verified production departures",
          deploy_verified: false,
          evidence: "ledgers(kind='merge', status='merged')",
        },
      change_failure: {
        rate: merged === 0 ? null : Number((bad / merged).toFixed(4)),
        bad,
        merges: merged,
        main_red: (redByProject.get(name) || new Set()).size,
        evidence: "outcome_metrics(reverted|reopened, DISTINCT pr) ÷ ledgers(kind='merge')",
      },
      time_to_restore: {
        ...ttr,
        unrestored: unrestored.get(name) || 0,
        caveat: "upper bound: the failure clock is outcome_metrics.created_at (a weekly detector's record, not the incident) and the restore is the next merge into the same repo",
        evidence: "outcome_metrics.created_at → the next ledgers(kind='merge') row for that repo",
      },
      // Absent rather than zeroed when the read failed: a client that cannot
      // tell "we could not measure this" from "the wait was nothing" will
      // print the second.
      ...(launches === null ? {} : {
        launch_lead_time: {
          ...doraStats((launchByProject.get(name) || { secs: [] }).secs),
          basis: LAUNCH_BASIS,
          dropped_n: (launchByProject.get(name) || { dropped: 0 }).dropped,
        },
      }),
      merge_lane: {
        ...lane,
        basis: "APPROVE verdict → PR merged",
        evidence: "job_artifacts(artifact_kind='verdict', ref='APPROVE').updated_at → ledgers(kind='merge').created_at",
      },
      slowest: rows
        .filter((r) => r.lead_s !== null)
        .sort((a, b) => b.lead_s - a.lead_s)
        .slice(0, 10)
        .map(({ merged_ms, ...keep }) => keep),
    };
  }).sort((a, b) => (b.merged - a.merged) || String(a.project).localeCompare(String(b.project)));

  const allLead = doraStats(landed.map((r) => r.lead_s).filter((v) => v !== null));
  const allLane = doraStats(landed.map((r) => r.approval_to_merge_s).filter((v) => v !== null));
  const allBad = new Set();
  for (const set of badByProject.values()) for (const k of set) allBad.add(k);
  let allDepartures = 0;
  for (const set of departuresByProject.values()) allDepartures += set.size;
  let allFailedDepartures = 0;
  for (const n of failedByProject.values()) allFailedDepartures += n;
  // Named for the reader of the gap below: which projects now measure to
  // production, and therefore which ones still do not.
  const deployCovered = [...new Set(landed
    .filter((r) => r.lead_end === "deploy_verified")
    .map((r) => r.project))].filter(Boolean).sort();

  return {
    window: { days, since, project: wantProject || null },
    projects,
    totals: {
      merged: landed.length,
      projects: projects.length,
      lead_time: allLead,
      merge_lane: allLane,
      // MERGES per day, as the label on the console says. The verified count
      // rides beside it rather than replacing it, because a fleet where one
      // project reports departures and three report merges has no single
      // honest number for "how often we deploy".
      deploys_per_day: landed.length === 0 ? 0 : Number((landed.length / days).toFixed(3)),
      departures: allDepartures,
      departures_per_day: allDepartures === 0 ? 0 : Number((allDepartures / days).toFixed(3)),
      failed_departures: allFailedDepartures,
      change_failure_rate: landed.length === 0 ? null : Number((allBad.size / landed.length).toFixed(4)),
      bad: allBad.size,
      ...(launches === null ? {} : {
        launch_lead_time: {
          ...doraStats(allLaunchSecs),
          basis: LAUNCH_BASIS,
          dropped_n: allLaunchDropped,
        },
      }),
    },
    // NAMED, not implied. A reader must be able to tell a metric this fleet
    // measures from one it currently cannot, without reading the source.
    gaps: [
      deployCovered.length
        ? {
          metric: "lead time (to deploy) + deployment frequency — PARTIAL",
          missing: `a verified production departure for every project (measuring to production in this window: ${deployCovered.join(", ")})`,
          why: "bin/deploy-train.sh writes a `deploy` ledger row on both its VERIFIED and its failed-verify branch, so the projects named above measure lead time to the instant production served the change and count departures rather than merges. A project with no VERSION_URL never runs a train at all, so its lead time still stops at main — and every project's rows carry `lead_end` saying which clock stopped them.",
          would_need: "a VERSION_URL (a {\"sha\":…} endpoint) in the remaining projects' env, which is the whole gate bin/deploy-train.sh opens on",
        }
        : {
          metric: "lead time (to deploy) + deployment frequency",
          missing: "a durable record of a VERIFIED production deploy",
          why: "bin/deploy-train.sh already proves production serves the merged sha — it polls the project's version endpoint until the live sha is the target or a descendant — and now writes a `deploy` ledger row for it, but no departure has been recorded in this window, so both metrics below still end at the merge.",
          would_need: "a train to actually depart: a project with a VERSION_URL in its env and a merge to carry, after which the rows appear as ledgers(kind='deploy')",
        },
      {
        metric: "merge-lane split (READY → MERGED dwell)",
        missing: "pr_state transition history",
        why: "pr_state lives in `ledgers`, whose primary key is (kind, key) — every transition OVERWRITES the row, so only the current state and its `since` survive. The approval→merged figure above is measured from the job's verdict artifact instead: the same question asked of a ledger that does keep its rows.",
        would_need: "an additive append from the conductor's mc_transition — job_ledger_put of a `pr_state_hist` kind keyed <owner/repo>#<n>@<iso>. NOT made here: bin/merge-conductor*.sh and bin/lib/merge-conductor-lib.sh are owned by another change in flight.",
      },
      {
        metric: "time to restore",
        missing: "an incident clock and a named fix",
        why: "outcome_metrics records when the DETECTOR noticed (a weekly cron), not when production broke, and nothing links a revert or fix PR back to the merge it repaired.",
        would_need: "additive restored_at / fix_pr columns on outcome_metrics, written when bin/outcome-metrics.sh identifies the reverting commit it already reads to build its evidence string",
      },
      // APPENDED, never prepended: the console reads gaps[0] as the deploy gap.
      ...(launches === null
        ? [{
          metric: "launch lead time — READ FAILED",
          missing: "the jobs.issue_created_at / first_spawn_at read on this request",
          why: launchesError || "the launch read failed and reported no reason",
          would_need: "a healthy D1 read; the six other reads succeeded and are reported above",
        }]
        : allLaunchSecs.length === 0
          ? [{
            metric: "launch lead time",
            missing: "jobs.issue_created_at, which only GitHub-Issues builds record",
            why: "launch lead time needs jobs.issue_created_at, which only GitHub-Issues builds record"
              + (allLaunchDropped > 0
                ? "; every row in this window was dropped (unparseable, or spawned before it was filed)"
                : "; no build job in this window carries both stamps"),
            would_need: "a build claim from a GitHub-Issues project passing issue_created_at as job_open's 7th argument (bin/jobs-client.sh)",
          }]
          : []),
      ...(launchesCapped
        ? [{
          metric: "launch lead time — PARTIAL",
          missing: "the rows beyond the 3000-row cap on the launch read",
          why: "the launch read came back full, so the p50/p90 above describe the capped set rather than the whole window",
          would_need: "a narrower ?days= or a ?project=",
        }]
        : []),
    ],
  };
}

// ── THE DOORBELL: webhook identifiers, and nothing else (2026-09-12) ─────────
// docs/EVENTS.md. A GitHub delivery reaches POST /webhooks/github, which is the
// ONLY route on this worker that HARNESS_SECRET does not open — it cannot, since
// GitHub has no way to send our bearer. It authenticates with an HMAC over the
// RAW body instead, keyed on a second secret that exists nowhere else.
//
// WHAT A VERIFIED SIGNATURE PROVES AND WHAT IT DOES NOT. It proves the sender
// holds the shared secret. It proves NOTHING about whether the body describes
// something that really happened — a payload is a claim, and the only thing this
// receiver may keep from a claim is an IDENTIFIER it can hand a lane that will
// go and look for itself: the repo slug, a PR number, an issue number, a sha.
// No title, no branch name, no body text, no actor, no state, no "merged: true".
// The worst a signed lie can achieve is one early tick of a lane that then reads
// GitHub and finds nothing to do.
export const WAKE_REPO_RE = /^[A-Za-z0-9._-]{1,100}\/[A-Za-z0-9._-]{1,100}$/;

export function hexOf(buf) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacSha256Hex(secret, body) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hexOf(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
}

// Length-independent, branch-free comparison. A `===` on the digests leaks the
// length of the matching prefix through timing, which is the one thing an
// attacker holding no secret can actually measure.
export function hexEqual(a, b) {
  const x = String(a || ""), y = String(b || "");
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

// wakeOf(event, payload) -> { kind, key } for the events a lane owns, else null.
// EVERY extracted value is re-validated here rather than trusted: a number must
// look like a number and a sha must look like a sha, because both become part of
// a primary key and travel through a shell loop.
//
// Kinds: pr | checks | push | deploy | issue, plus two that BH-4058 records for
// the wake classes before any lane consumes them: deploy_failed (a deployment
// that failed or errored, never `deploy`, which would QA it) and merge_group (a
// merge-queue entry, keyed on its temporary head sha, which is in no PR's
// pr-state row, so as `checks` it would buy an unkeyed conductor run).
// The labels an `issues.labeled` delivery wakes triage for. A label name is read
// to DECIDE and never stored, like `ref` and `deployment_status.state` below.
export const WAKE_ISSUE_LABELS = ["ai-build", "hotfix"];
export function wakeOf(event, p) {
  const pay = p && typeof p === "object" ? p : {};
  const action = String(pay.action || "");
  const num = (v) => {
    const n = Number(v);
    return Number.isInteger(n) && n > 0 && n < 1e9 ? String(n) : "";
  };
  const sha = (v) => (/^[0-9a-f]{7,64}$/.test(String(v || "").toLowerCase())
    ? String(v).toLowerCase() : "");
  const obj = (v) => (v && typeof v === "object" ? v : {});
  switch (event) {
    // The conductor's own events. `closed` is included on purpose: a PR that
    // merged or was closed is a PR the conductor must SETTLE, and settling is
    // exactly the step that used to wait five minutes for nothing.
    case "pull_request":
      // BH-3997: Mergify's `queued` label is the moment a "not in the merge
      // queue" alert becomes false, so that one label wakes the fleet
      // (bin/lib/wake-class-pr-closed.sh hands it to bin/alerts-merge-resolve.sh).
      // Every other label change moves nothing the fleet watches.
      // BH-4055: GitHub's native merge queue `enqueued` / `dequeued` are the
      // same kind of moment, so they wake the fleet as well; the wake class
      // re-judges pipeline-health's PR checks on them. `unlabeled` stays
      // dropped: the stored row carries no label name to tell `queued` apart.
      if (action === "labeled") {
        if (String(obj(pay.label).name || "") !== "queued") return null;
      } else if (!["opened", "synchronize", "reopened", "closed", "ready_for_review",
        "enqueued", "dequeued"].includes(action)) return null;
      return { kind: "pr", key: num(pay.number || obj(pay.pull_request).number) };
    case "pull_request_review":
      if (!["submitted", "dismissed", "edited"].includes(action)) return null;
      return { kind: "pr", key: num(obj(pay.pull_request).number) };
    // A comment thread on a PR is a PR event; on an issue it is board activity.
    // Only the PRESENCE of the pull_request object is read, never its contents.
    case "issue_comment": {
      if (!["created", "edited"].includes(action)) return null;
      const issue = obj(pay.issue);
      return { kind: issue.pull_request ? "pr" : "issue", key: num(issue.number) };
    }
    case "issues":
      if (action === "labeled") {
        if (!WAKE_ISSUE_LABELS.includes(String(obj(pay.label).name || "").toLowerCase())) return null;
      } else if (!["opened", "edited", "closed", "reopened"].includes(action)) return null;
      return { kind: "issue", key: num(obj(pay.issue).number) };
    // Checks are keyed on the HEAD SHA, not a PR number: one sha can belong to
    // several PRs and the conductor re-reads them all anyway, while the sha is
    // the only identifier a check_run delivery reliably carries.
    case "check_suite":
      if (action !== "completed") return null;
      return { kind: "checks", key: sha(obj(pay.check_suite).head_sha) };
    case "check_run":
      if (action !== "completed") return null;
      return { kind: "checks", key: sha(obj(pay.check_run).head_sha) };
    // A commit status (the second-review / lead verdict statuses among them)
    // carries no action; `pending` is the start of a check, not its answer.
    case "status":
      if (!["success", "failure", "error"].includes(String(pay.state || ""))) return null;
      return { kind: "checks", key: sha(pay.sha) };
    case "workflow_run": {
      if (action !== "completed") return null;
      const r = obj(pay.workflow_run);
      // A pre-queue run wakes the PR it gated. bin/lib/mc-prequeue.d/dispatch.sh
      // dispatches prequeue-gate.yml with `--ref main`, so head_sha is MAIN's
      // tip and names no PR; the run title carries the number. Only the number
      // reaches the row, never the title.
      const m = /^prequeue pr=([1-9][0-9]{0,8}) head=[0-9a-f]{40} main=[0-9a-f]{40}$/
        .exec(String(r.display_title || ""));
      if (m && String(r.event || "") === "workflow_dispatch"
        && String(r.path || "").endsWith("/prequeue-gate.yml")) {
        return { kind: "pr", key: num(m[1]) };
      }
      return { kind: "checks", key: sha(r.head_sha) };
    }
    // Its own kind, see above. head_ref is never read: it is content.
    case "merge_group":
      if (!["checks_requested", "destroyed"].includes(action)) return null;
      return { kind: "merge_group", key: sha(obj(pay.merge_group).head_sha) };
    // DEFAULT BRANCH ONLY (repository.default_branch, else main). A push to a
    // feature branch is the build's own business and would wake the deploy
    // train for something it must never depart on. `event` carries the compare
    // range push.<before>..<after> for bin/repair-on-push.sh, only when both
    // are full shas and before is not the all-zero sha of a new branch.
    case "push": {
      const db = String(obj(pay.repository).default_branch || "");
      const def = /^[A-Za-z0-9._\/-]{1,200}$/.test(db) && !db.includes("..") ? db : "main";
      if (String(pay.ref || "") !== "refs/heads/" + def) return null;
      const b = sha(pay.before), a = sha(pay.after);
      const full = (v) => /^[0-9a-f]{40}$/.test(v);
      const range = full(b) && full(a) && !/^0+$/.test(b);
      return { kind: "push", key: a, ...(range ? { event: `push.${b}..${a}` } : {}) };
    }
    case "deployment_status": {
      const state = String(obj(pay.deployment_status).state || "");
      if (state === "success") return { kind: "deploy", key: sha(obj(pay.deployment).sha) };
      if (state === "failure" || state === "error") return { kind: "deploy_failed", key: sha(obj(pay.deployment).sha) };
      return null;
    }
    default:
      return null;
  }
}

// -- METER-ANCHORED COST (2026-09-14) ----------------------------------------
//
// THE PROBLEM THIS EXISTS FOR. cost_rows is the fleet's only per-call ledger
// and it UNDERCOUNTS the bill 3-4x: a row is written per agent-call, and the
// calls that never reach that wrapper never reach the ledger. The account's own
// cash meter (extra_usage_snapshots.extra_used_usd, polled hourly) does not
// undercount -- it is the number the card is charged. Neither one alone answers
// "what did this PR cost": the meter knows the total and nothing about who
// spent it, the rows know who spent it and are wrong about how much.
//
// SO THE ROWS CARRY THE SHAPE AND THE METER CARRIES THE SCALE:
//
//   factor(account, window) = meter delta over the window
//                             / rows billed to that account over the SAME span
//   anchored(x)             = raw rows of x * factor(the account x bills)
//
// and the raw sum ships beside the anchored one, always, because a single
// number nobody can check against the ledger is how a bad factor becomes a
// budget decision.
//
// WHEN THE FACTOR IS NOT COMPUTED, IT IS 1 AND SAYS SO. The meter only moves
// when an account is PAST its weekly credits: inside them a call costs the
// subscription and the cash meter sits still, so a delta of zero would divide
// the fleet's real spend down to nothing. Every account therefore carries a
// state -- `metered` (a real delta over a span that was fully in overage),
// `unmeasured` (a meter exists but this window cannot be measured against it),
// or `no-login` (no poll for this account at all: 8 of 9 boxes cannot read the
// endpoint, and API-key vendors have no such meter to read). Only `metered`
// ever multiplies anything.
//
// THE SPAN, NOT THE WINDOW, IS THE DENOMINATOR. The project-6 poller started on
// 2026-09-14, so a 7d window holds a few hours of meter, and dividing a week of
// rows by four hours of meter would report a factor of 0.02. Numerator and
// denominator cover the same instants or the account is `unmeasured`.

// The box-label -> account map's documented fallback (COST_ANCHOR_ACCOUNT_MAP on
// the worker overrides it) lives with the other deployment defaults (BH-4080).
export { ANCHOR_DEFAULT_ACCOUNT_MAP } from './deployment-defaults.js';
// A ceiling on the multiplier. rows_usd is a DENOMINATOR: a window where one
// $0.02 row happened to carry a label would otherwise mint a factor of 900,000
// and put a six-figure number on a PR. Clamped both ways, and the clamp is
// reported rather than hidden.
export const ANCHOR_DEFAULT_MAX_FACTOR = 20;
// The pause_flags row (and the flags/ filename it reconciles to) that turns
// this endpoint off without a deploy.
export const ANCHOR_OFF_FLAG = "cost-anchor-off";
// Meter spans we will pay a second D1 query for. The fleet has two metered
// accounts; the cap is what stops a future registry of fifty from turning one
// request into fifty round trips.
export const ANCHOR_MAX_ACCOUNTS = 8;

export const anchorRound = (n) => (Number.isFinite(n) ? Math.round(n * 1e4) / 1e4 : null);

// "box=label,box=label" -> Map. Untrusted input (an env var an operator typed):
// a malformed pair is dropped rather than guessed at.
export function parseAccountMap(spec) {
  const out = new Map();
  for (const part of String(spec || "").split(/[,\s]+/)) {
    if (!part) continue;
    const i = part.indexOf("=");
    if (i <= 0) continue;
    const box = part.slice(0, i).trim();
    const label = part.slice(i + 1).trim();
    if (box && label) out.set(box, label);
  }
  return out;
}

// A build dir is "<project>-<KEY>-<YYYYMMDDHHMM>" (bin/run-build.sh), and it is
// the ONLY place a per-PR cost row records which ticket it was and when the
// money was spent -- pr_costs.updated_at is the rollup's own clock, rewritten
// nightly for every row, so it cannot window anything.
//
// The greedy first group is deliberate: both halves contain hyphens
// ("project-3-TK-109-202607241459") and a key must start with a letter, so the
// only split that satisfies the whole pattern is the right one. A hand-made hub
// dir ("cost-rows-db-20260902") carries no key and matches nothing -- null, not
// a ticket this code invented.
export const ANCHOR_BUILD_DIR_RE = /^(.+)-([A-Za-z][A-Za-z0-9]*-\d+)-(\d{12})$/;
// The hand-run builds on the hub ("cost-rows-db-20260902") end in a bare stamp
// and belong to no ticket. Their dollars are REAL, so the stamp alone is read
// as the time - they land in $/PR and $/box - but neither a project nor a key
// is claimed for them, because the prefix is a slug somebody typed and not a
// project name this fleet knows.
export const ANCHOR_STAMP_RE = /^.+-(\d{12})$/;
export const ANCHOR_DAY_RE = /^.+-(\d{8})$/;

export function anchorStampMs(stamp) {
  const at = stamp.length === 12
    ? Date.parse(`${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}`
      + `T${stamp.slice(8, 10)}:${stamp.slice(10, 12)}:00Z`)
    : Date.parse(`${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T00:00:00Z`);
  return Number.isNaN(at) ? null : at;
}

export function parseBuildDir(name) {
  const dir = String(name || "").trim();
  const m = ANCHOR_BUILD_DIR_RE.exec(dir);
  if (m) {
    const at = anchorStampMs(m[3]);
    if (at !== null) return { dir, project: m[1], key: m[2], at };
  }
  const s = ANCHOR_STAMP_RE.exec(dir) || ANCHOR_DAY_RE.exec(dir);
  if (!s) return null;
  const at = anchorStampMs(s[1]);
  return at === null ? null : { dir, project: null, key: null, at };
}

// "execute:110.77;review:10.72" -> { execute: 110.77, review: 10.72 }
export function parseStageBreakdown(s) {
  const out = {};
  for (const part of String(s || "").split(";")) {
    if (!part) continue;
    const i = part.lastIndexOf(":");
    if (i <= 0) continue;
    const name = part.slice(0, i).trim();
    const usd = Number(part.slice(i + 1));
    if (!name || !Number.isFinite(usd)) continue;
    out[name] = (out[name] || 0) + usd;
  }
  return out;
}

export const anchorIso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// ?window=24h|7d or ?day=YYYY-MM-DD. An unreadable day falls back to the
// rolling window rather than 400ing: this is a read a dashboard polls.
export function anchorWindow({ window: wanted, day, now }) {
  if (day && /^\d{4}-\d{2}-\d{2}$/.test(day)) {
    const start = Date.parse(`${day}T00:00:00Z`);
    if (!Number.isNaN(start)) {
      return {
        window: `day=${day}`, from: anchorIso(start), to: anchorIso(start + 86400000),
        from_ms: start, to_ms: start + 86400000,
      };
    }
  }
  const hours = String(wanted || "") === "7d" ? 168 : 24;
  const fromMs = now - hours * 3600000;
  return {
    window: hours === 168 ? "7d" : "24h", from: anchorIso(fromMs), to: anchorIso(now),
    from_ms: fromMs, to_ms: now,
  };
}

// Phase 1 of the endpoint: what each metered account's meter DID over the
// window, before any rows are divided by it. Split out from computeAnchored
// because the row sum it is divided by is a second D1 query whose bounds are
// this function's output.
//
// A FAILED POLL IS NOT A READING (BH-3985). Since 2026-09-14 a poll that could
// not read the meter (status error / no-login) still writes a row, with
// extra_used_usd NULL. Kept in the span, one such row at either end nulled the
// delta and failed fully_overage, so a meter that moved read "unmeasured" and
// the endpoint said no account was metered. Those rows are counted into
// `failed_polls` and left out of the span; `snapshots` counts readings.
export function meterAccounts({ snapshots = [], accountMap, from, to }) {
  const byLabel = new Map();
  const failed = new Map();
  for (const s of snapshots) {
    if (!s) continue;
    const label = accountMap.get(String(s.box ?? ""));
    if (!label) continue;
    const ts = String(s.ts ?? "");
    if (!ts || ts < from || ts >= to) continue;
    if (!byLabel.has(label)) { byLabel.set(label, []); failed.set(label, { n: 0, box: s.box ?? null }); }
    if (numOrNull(s.extra_used_usd) === null) { failed.get(label).n += 1; continue; }
    byLabel.get(label).push(s);
  }
  const out = [];
  for (const [label, snaps] of byLabel) {
    const failedPolls = failed.get(label).n;
    if (!snaps.length) {
      // Polled, and every poll failed: a meter entry with nothing measured,
      // so the account reads "unmeasured, every poll failed" and not no-login.
      out.push({
        label, meter_box: failed.get(label).box, span_from: null, span_to: null,
        snapshots: 0, failed_polls: failedPolls, meter_delta_usd: null, fully_overage: false,
        weekly_pct: null, weekly_resets_at: null, extra_used_usd: null, spend_limit_reached: false,
      });
      continue;
    }
    snaps.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
    const first = snaps[0];
    const last = snaps[snaps.length - 1];
    const usedFirst = numOrNull(first.extra_used_usd);
    const usedLast = numOrNull(last.extra_used_usd);
    out.push({
      label,
      meter_box: first.box ?? null,
      span_from: first.ts,
      span_to: last.ts,
      snapshots: snaps.length,
      failed_polls: failedPolls,
      meter_delta_usd: (usedFirst === null || usedLast === null || snaps.length < 2)
        ? null : anchorRound(usedLast - usedFirst),
      // "past its weekly credits for the WHOLE span" -- EVERY poll, not the
      // last one. A span that started at 87% spent part of itself on credits
      // the cash meter never saw, and dividing by it would inflate every dollar
      // on the screen.
      fully_overage: snaps.every((s) => {
        const pct = numOrNull(s.weekly_pct);
        return pct !== null && pct >= 100 && Number(s.extra_enabled) === 1;
      }),
      weekly_pct: numOrNull(last.weekly_pct),
      weekly_resets_at: last.weekly_resets_at ?? null,
      extra_used_usd: usedLast,
      spend_limit_reached: Number(last.spend_limit_reached) === 1,
    });
  }
  return out.sort((a, b) => a.label.localeCompare(b.label)).slice(0, ANCHOR_MAX_ACCOUNTS);
}

// The accounts whose factor is worth a second query. Anything else is already
// `unmeasured` and multiplies by 1.
export function anchorSpanCandidates(meters) {
  return (meters || []).filter((m) => m && m.fully_overage
    && m.snapshots >= 2 && m.meter_delta_usd !== null && m.meter_delta_usd > 0);
}

export function anchorAccountState(meter, spanUsd, maxFactor) {
  if (!meter) {
    return {
      state: "no-login", factor: 1, reason:
        "no usage-meter poll for this account in this window - the box that bills it cannot read the meter, or the vendor has none",
    };
  }
  if (meter.snapshots === 0) {
    return {
      state: "unmeasured", factor: 1, reason:
        `every meter poll in this window failed (${meter.failed_polls ?? 0}), so there is no reading to measure`,
    };
  }
  if (meter.snapshots < 2) {
    return { state: "unmeasured", factor: 1, reason: "one meter poll in this window - a delta needs two" };
  }
  if (meter.meter_delta_usd === null) {
    return { state: "unmeasured", factor: 1, reason: "a poll in this span carried no meter value" };
  }
  if (!meter.fully_overage) {
    return {
      state: "unmeasured", factor: 1, reason:
        "the account was still inside its weekly credits for part of this window, so the cash meter measures only part of the spend",
    };
  }
  if (meter.meter_delta_usd < 0) {
    return {
      state: "unmeasured", factor: 1, reason:
        "the meter went backwards in this window (a reset), so the delta is not a spend",
    };
  }
  if (meter.meter_delta_usd === 0) {
    return { state: "unmeasured", factor: 1, reason: "the meter did not move in this window" };
  }
  if (!(spanUsd > 0)) {
    return {
      state: "unmeasured", factor: 1, reason:
        "no priced rows bill this account inside the meter span, so there is nothing to divide",
    };
  }
  const raw = meter.meter_delta_usd / spanUsd;
  const floor = 1 / maxFactor;
  const factor = Math.min(Math.max(raw, floor), maxFactor);
  return {
    state: "metered",
    factor: anchorRound(factor),
    factor_raw: anchorRound(raw),
    factor_capped: factor !== raw,
    reason: factor !== raw
      ? `the measured factor ${anchorRound(raw)} is outside the ${anchorRound(floor)}-${maxFactor} clamp and was capped`
      : null,
  };
}

// Phase 2: everything the screen renders. Pure -- every row it needs is an
// argument, so the arithmetic is testable without a D1.
export function computeAnchored({
  window, from, to, from_ms: fromMs, to_ms: toMs,
  meters = [], rowSums = [], spanSums = {}, prCosts = [], merges = [],
  maxFactor = ANCHOR_DEFAULT_MAX_FACTOR, limit = 500, prCostsCap = null,
}) {
  const gaps = [];

  // -- who spent, per account and per box ----------------------------------
  const rowsByAccount = new Map();
  const boxes = new Map();
  for (const r of rowSums) {
    if (!r) continue;
    const label = String(r.account ?? "").trim() || "unknown";
    const box = String(r.box ?? "").trim() || "unknown";
    const usd = numOrNull(r.usd) ?? 0;
    const calls = numOrNull(r.calls) ?? 0;
    const a = rowsByAccount.get(label) || { usd: 0, calls: 0 };
    a.usd += usd; a.calls += calls;
    rowsByAccount.set(label, a);
    if (!boxes.has(box)) boxes.set(box, new Map());
    const per = boxes.get(box);
    const b = per.get(label) || { usd: 0, calls: 0 };
    b.usd += usd; b.calls += calls;
    per.set(label, b);
  }

  // -- the account strip, and the factors everything else multiplies by -----
  const meterByLabel = new Map((meters || []).map((m) => [m.label, m]));
  const labels = new Set([...rowsByAccount.keys(), ...meterByLabel.keys()]);
  const factorFor = new Map();
  const accounts = [];
  for (const label of [...labels].sort()) {
    const meter = meterByLabel.get(label) || null;
    const rows = rowsByAccount.get(label) || { usd: 0, calls: 0 };
    const spanUsd = Object.prototype.hasOwnProperty.call(spanSums, label)
      ? numOrNull(spanSums[label]) : null;
    const verdict = anchorAccountState(meter, spanUsd, maxFactor);
    factorFor.set(label, verdict.state === "metered" ? verdict.factor : 1);
    accounts.push({
      label,
      meter_box: meter ? meter.meter_box : null,
      meter_delta_usd: meter ? meter.meter_delta_usd : null,
      rows_usd: anchorRound(rows.usd),
      rows_calls: rows.calls,
      rows_usd_span: spanUsd === null ? null : anchorRound(spanUsd),
      span_from: meter ? meter.span_from : null,
      span_to: meter ? meter.span_to : null,
      snapshots: meter ? meter.snapshots : 0,
      failed_polls: meter ? meter.failed_polls ?? 0 : 0,
      weekly_pct: meter ? meter.weekly_pct : null,
      weekly_resets_at: meter ? meter.weekly_resets_at : null,
      extra_used_usd: meter ? meter.extra_used_usd : null,
      spend_limit_reached: meter ? meter.spend_limit_reached : null,
      factor: verdict.factor,
      factor_raw: verdict.factor_raw ?? null,
      factor_capped: Boolean(verdict.factor_capped),
      state: verdict.state,
      reason: verdict.reason,
    });
  }
  const metered = accounts.filter((a) => a.state === "metered");
  if (!metered.length) {
    gaps.push("No account is metered in this window, so every anchored figure equals its raw figure. "
      + "The account strip says why, per account.");
  }
  const factorOf = (label) => factorFor.get(String(label ?? "").trim() || "unknown") ?? 1;

  // -- per box -------------------------------------------------------------
  // A box's rows can bill more than one account, so the anchoring is per
  // (box, account) and summed: one box-wide factor would attribute project-6's
  // multiplier to a row an api key paid for.
  const per_box = [...boxes.entries()].map(([box, per]) => {
    let raw = 0, anchored = 0, calls = 0;
    const split = [];
    for (const [label, v] of per) {
      raw += v.usd; calls += v.calls;
      anchored += v.usd * factorOf(label);
      split.push({ account: label, raw_usd: anchorRound(v.usd), factor: factorOf(label) });
    }
    split.sort((a, b) => b.raw_usd - a.raw_usd);
    return { box, raw_usd: anchorRound(raw), anchored_usd: anchorRound(anchored), calls, accounts: split };
  });

  // -- per PR, and the ticket rollup over it --------------------------------
  const mergedAt = new Map();
  for (const m of merges || []) {
    const key = String((m && m.key) ?? "");
    if (key && m.created_at && !mergedAt.has(key)) mergedAt.set(key, m.created_at);
  }

  let untimed = 0;
  const per_pr = [];
  for (const p of prCosts) {
    if (!p) continue;
    const prUrl = String(p.pr_url ?? "");
    if (!prUrl) continue;
    const dirs = String(p.build_dirs ?? "").split(";")
      .map((d) => parseBuildDir(d)).filter(Boolean)
      .sort((a, b) => a.at - b.at);
    const last = dirs.length ? dirs[dirs.length - 1] : null;
    const merged = mergedAt.get(prUrl) || null;
    // WHEN THE MONEY WAS SPENT, in this order: the last build dir's own stamp
    // (the build that produced the PR), else the merge instant. A row with
    // neither cannot be placed in any window and is counted, not guessed at.
    const atMs = last ? last.at : (merged ? Date.parse(merged) : NaN);
    if (!Number.isFinite(atMs)) { untimed++; continue; }
    if (atMs < fromMs || atMs >= toMs) continue;
    const account = String(p.auth_account ?? "").trim() || "unknown";
    const factor = factorOf(account);
    const raw = numOrNull(p.cost_usd) ?? 0;
    per_pr.push({
      pr_url: prUrl,
      repo: doraRepo(prUrl),
      number: doraPrNumber(prUrl),
      // pr_costs holds no PR title and this endpoint will not fetch GitHub to
      // invent one -- the console links the number through to the PR screen.
      title: null,
      project: last ? last.project : null,
      key: last ? last.key : null,
      build_dir: last ? last.dir : null,
      raw_usd: anchorRound(raw),
      anchored_usd: anchorRound(raw * factor),
      account,
      factor,
      at: anchorIso(atMs),
      merged_at: merged,
      stage_breakdown: parseStageBreakdown(p.stage_breakdown),
    });
  }
  if (untimed) {
    gaps.push(`${untimed} per-PR cost row${untimed === 1 ? "" : "s"} carry neither a parseable build dir `
      + "nor a merge instant, so they cannot be placed in any window and are in no figure here.");
  }
  if (prCostsCap && prCosts.length >= prCostsCap) {
    gaps.push(`The per-PR read is capped at ${prCostsCap} rows (newest rollup first) and came back full, `
      + "so a PR whose rollup row is older than that cap is missing from the PR and ticket tables.");
  }

  const ticketMap = new Map();
  for (const r of per_pr) {
    if (!r.key) continue;
    const id = `${r.project}|${r.key}`;
    const e = ticketMap.get(id) || {
      project: r.project, key: r.key, raw_usd: 0, anchored_usd: 0, prs: 0,
      accounts: new Set(), stage_breakdown: {}, build_dir: r.build_dir, at: r.at, merged_at: null,
    };
    e.raw_usd += r.raw_usd; e.anchored_usd += r.anchored_usd; e.prs += 1;
    e.accounts.add(r.account);
    for (const [stage, usd] of Object.entries(r.stage_breakdown)) {
      e.stage_breakdown[stage] = (e.stage_breakdown[stage] || 0) + usd;
    }
    if (r.at > e.at) { e.at = r.at; e.build_dir = r.build_dir; }
    if (r.merged_at && (!e.merged_at || r.merged_at > e.merged_at)) e.merged_at = r.merged_at;
    ticketMap.set(id, e);
  }
  const per_ticket = [...ticketMap.values()].map((e) => ({
    project: e.project, key: e.key, prs: e.prs,
    raw_usd: anchorRound(e.raw_usd), anchored_usd: anchorRound(e.anchored_usd),
    accounts: [...e.accounts].sort(),
    build_dir: e.build_dir, at: e.at, merged_at: e.merged_at,
    stage_breakdown: Object.fromEntries(Object.entries(e.stage_breakdown)
      .sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, anchorRound(v)])),
  }));
  const unticketed = per_pr.filter((r) => !r.key);
  if (unticketed.length) {
    gaps.push(`${unticketed.length} PR${unticketed.length === 1 ? "" : "s"} in this window carry no ticket `
      + "key in their build dirs (a hand-run build), so they are in $/PR and $/box but not in $/ticket.");
  }

  // -- totals over the WHOLE window, never over the page --------------------
  const sum = (rows, f) => anchorRound(rows.reduce((n, r) => n + (f(r) || 0), 0));
  const totals = {
    rows_usd: sum(accounts, (a) => a.rows_usd),
    rows_anchored_usd: sum(accounts, (a) => a.rows_usd * a.factor),
    meter_delta_usd: accounts.some((a) => a.meter_delta_usd !== null)
      ? sum(accounts, (a) => a.meter_delta_usd) : null,
    pr_raw_usd: sum(per_pr, (r) => r.raw_usd),
    pr_anchored_usd: sum(per_pr, (r) => r.anchored_usd),
    ticket_raw_usd: sum(per_ticket, (r) => r.raw_usd),
    ticket_anchored_usd: sum(per_ticket, (r) => r.anchored_usd),
    box_raw_usd: sum(per_box, (r) => r.raw_usd),
    box_anchored_usd: sum(per_box, (r) => r.anchored_usd),
    prs: per_pr.length, tickets: per_ticket.length, boxes: per_box.length,
    accounts: accounts.length, metered_accounts: metered.length,
  };

  // The rows a PR ledger holds and the rows a per-call ledger holds are two
  // different populations (a PR's cost includes calls from before this window;
  // a box's includes triage that never became a PR). Saying so beats letting a
  // reader discover it by subtracting.
  if (totals.pr_raw_usd && totals.rows_usd
    && Math.abs(totals.pr_raw_usd - totals.rows_usd) / totals.rows_usd > 0.25) {
    gaps.push("$/PR and $/box do not add up to the same total on purpose: a PR row carries the whole "
      + "build's spend (including calls made before this window) and a box row carries only calls "
      + "stamped inside it, triage and failed builds included.");
  }

  const page = (rows) => {
    const sorted = rows.slice().sort((a, b) => (b.anchored_usd - a.anchored_usd)
      || (b.raw_usd - a.raw_usd));
    return { rows: sorted.slice(0, limit), truncated: sorted.length > limit };
  };
  const prPage = page(per_pr);
  const ticketPage = page(per_ticket);
  const boxPage = page(per_box);

  return {
    window, from, to, limit,
    accounts,
    per_pr: prPage.rows, per_pr_truncated: prPage.truncated,
    per_ticket: ticketPage.rows, per_ticket_truncated: ticketPage.truncated,
    per_box: boxPage.rows, per_box_truncated: boxPage.truncated,
    totals, gaps,
  };
}

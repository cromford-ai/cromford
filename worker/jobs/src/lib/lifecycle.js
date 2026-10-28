// harness-jobs — the ticket lifecycle: phases, legal transitions and their
// owners (BH-8731, lifecycle slice 1 of 6).
//
// A build_queue row's `status` says where the QUEUE ROW is (queued, claimed,
// done). Its `phase` says where the TICKET is in its life. The phase lives in
// four nullable build_queue columns (core.d/bh-8731-lifecycle.js) and every
// accepted move appends one ticket_events row (routes/ticket-lifecycle.js).
// core.js re-exports LIFECYCLE_TRANSITIONS and LIFECYCLE_OWNERS next to
// QUEUE_TRANSITIONS. Pure data plus two functions: no imports.
//
// THE KEY "" IS "NO PHASE YET": a build_queue row whose phase IS NULL (every
// row before this slice). A self-transition is never legal; a retrying caller
// reads the 409's `current == to` as "already done". merged and closed are
// terminal: no way out.

export const LIFECYCLE_PHASES = [
  "triaged", "planned", "plan_blocked", "building", "pr_open",
  "in_queue", "ejected", "abandoned", "merged", "closed",
];
export const LIFECYCLE_TERMINAL = new Set(["merged", "closed"]);

// from -> the phases it may move to.
export const LIFECYCLE_TRANSITIONS = {
  "":           ["triaged", "planned", "building", "closed"],
  triaged:      ["planned", "plan_blocked", "building", "closed"],
  planned:      ["building", "plan_blocked", "closed"],
  plan_blocked: ["triaged", "planned", "closed"],
  building:     ["pr_open", "plan_blocked", "abandoned", "closed"],
  pr_open:      ["in_queue", "merged", "abandoned", "closed"],
  in_queue:     ["merged", "ejected", "closed"],
  ejected:      ["in_queue", "pr_open", "abandoned", "closed"],
  abandoned:    ["triaged", "planned", "closed"],
  merged:       [],
  closed:       [],
};

// to -> the actors that own a move INTO that phase.
export const LIFECYCLE_OWNERS = {
  triaged:      ["triage"],
  planned:      ["pool"],
  plan_blocked: ["pool"],
  building:     ["pool"],
  pr_open:      ["pool"],
  in_queue:     ["conductor"],
  ejected:      ["conductor"],
  merged:       ["conductor"],
  abandoned:    ["pr-records", "resolver"],
  closed:       ["board"],
};
export const LIFECYCLE_ACTORS = new Set(["triage", "pool", "conductor", "pr-records", "resolver", "board", "lifecycle"]);

// RE-ENTRY. A move out of plan_blocked, abandoned or ejected is the lifecycle
// agent's (Tackler, the operator's answer on the ticket), unless it goes to abandoned
// or closed: those keep their own owners.
const REENTRY_FROM = new Set(["plan_blocked", "abandoned", "ejected"]);
const REENTRY_KEEP = new Set(["abandoned", "closed"]);

export function lifecycleOwners(from, to) {
  if (REENTRY_FROM.has(from) && !REENTRY_KEEP.has(to)) return ["lifecycle"];
  return LIFECYCLE_OWNERS[to] || [];
}

// -> { ok: true } | { ok: false, error: "illegal_transition", allowed }
//                 | { ok: false, error: "wrong_owner", owners }
export function lifecycleCheck(from, to, actor) {
  const allowed = Object.hasOwn(LIFECYCLE_TRANSITIONS, from) ? LIFECYCLE_TRANSITIONS[from] : [];
  if (!allowed.includes(to)) return { ok: false, error: "illegal_transition", allowed };
  const owners = lifecycleOwners(from, to);
  if (!owners.includes(actor)) return { ok: false, error: "wrong_owner", owners };
  return { ok: true };
}

// The code fallback of each settings row `lifecycle.stuck.<phase>_min`
// (schema.d/*-bh-8731-ticket-events.sql seeds the same values). A row that is
// a whole number >= 0 wins; any other value falls back to this. 0 = stuck at
// once. A phase with no row and no entry here is never reported.
export const STUCK_DEFAULT_MIN = {
  plan_blocked: 1440, // lifecycle.stuck.plan_blocked_min
  ejected: 30,        // lifecycle.stuck.ejected_min
  abandoned: 0,       // lifecycle.stuck.abandoned_min
  building: 180,      // lifecycle.stuck.building_min
  in_queue: 120,      // lifecycle.stuck.in_queue_min
  pr_open: 1440,      // lifecycle.stuck.pr_open_min
};

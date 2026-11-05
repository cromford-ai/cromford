import { minutesSince } from './format.js';
import { FLEET_LOGIN } from './deployment.js';

// Third-party harnesses never ping our watchdog, so they cannot be boxes — but
// their work is real and it lands in the same repos. Before this, a ticket
// another harness had claimed showed nothing on the pipeline at all, which read
// as "nobody is working on it" when in fact someone was.

// FLEET_LOGIN (./deployment.js, BH-4080): every one of OUR lanes authenticates
// with the same shared PAT, so they are indistinguishable from each other by
// design — naming a box would be inventing an attribution the data cannot support.
// Object.create(null), NOT a literal: a plain object inherits from
// Object.prototype, so ACTOR_LABELS['constructor'] would be the Object
// constructor — truthy — and render "function Object() { [native code] }" as
// somebody's name. `constructor`, `toString` and `valueOf` are all valid GitHub
// usernames. A null prototype fixes the label lookup and the pseudo-box group
// key in one move, since both index this map.
const ACTOR_LABELS = Object.assign(Object.create(null), {
  'collaborator-1': 'partner (collaborator-1)',
  'partner-dev': 'partner (collaborator-1)'
});

// Values are normalised the same way triage verdicts are: GitHub logins are
// case-insensitive, and one person must never split into two pseudo-boxes.
const normActor = (a) => (typeof a === 'string' ? a.trim().toLowerCase() : '');

export function actorLabel(actor, fleet) {
  const key = normActor(actor);
  if (!key) return 'unknown actor';
  if (key === FLEET_LOGIN || fleet === true) return 'harness';
  return ACTOR_LABELS[key] || String(actor).trim();
}

// `fleet` decides whether a claim is ours or someone else's. An unparseable
// flag defaults to EXTERNAL on purpose: this feature exists because external
// work was invisible, so defaulting to "ours" would hide the lane again — the
// original bug. Defaulting to external is noisy at worst, and noise is
// recoverable in a way that silence is not.
// Order matters: an EXPLICIT flag outranks the actor fallback in both
// directions. Letting the operator-actor check override an explicit `false` is
// the one case this code could hide a lane — precisely the bug the whole
// feature exists to prevent. Only a missing or unparseable flag falls back to
// the actor, and then only our own login counts as ours.
const isFleetClaim = (claim) => {
  const f = claim.fleet;
  const asText = typeof f === 'string' ? f.trim().toLowerCase() : null;
  if (f === true || asText === 'true') return true;
  if (f === false || asText === 'false') return false;
  return normActor(claim.actor) === FLEET_LOGIN;
};

// A PR claim's state. The hub's ticket snapshot sends `merged` or `open`;
// an OLDER snapshot sends no state at all, and a claim we cannot date as merged
// is treated as OPEN. That fallback is the safe half to get wrong: an open PR
// shown as open is correct today, whereas guessing "merged" would mark work
// finished that is still in flight.
function claimState(kind, raw) {
  if (kind !== 'pr') return null;
  const s = typeof raw === 'string' ? raw.trim().toLowerCase() : '';
  return s === 'merged' ? 'merged' : 'open';
}

export function ticketClaim(ticket) {
  const claim = ticket && ticket.claim;
  if (!claim || typeof claim !== 'object') return null;
  if (!normActor(claim.actor)) return null;
  const fleet = isFleetClaim(claim);
  const kind = typeof claim.kind === 'string' ? claim.kind.trim().toLowerCase() : null;
  const state = claimState(kind, claim.state);
  return {
    actor: String(claim.actor).trim(),
    label: actorLabel(claim.actor, fleet),
    fleet,
    external: !fleet,
    kind,
    state,
    // The one question the card needs answered: is this lane's PR already in?
    // A merged PR on a ticket nobody closed is a BOARD-hygiene item, not work
    // in flight and certainly not an abandoned branch.
    merged: kind === 'pr' && state === 'merged',
    ref: claim.ref || null,
    pr: Number.isFinite(Number(claim.pr)) && claim.pr !== null && claim.pr !== '' ? Number(claim.pr) : null,
    prUrl: typeof claim.pr_url === 'string' ? claim.pr_url : null,
    at: claim.at || null
  };
}

export const claimAge = (claim) => (claim && claim.at ? minutesSince(claim.at) : null);

// `kind:"branch"` means no PR was opened. An old branch tip is then a lane
// somebody walked away from, and saying so is more useful than showing it as
// live work.
//
// It is ONLY ever kind:"branch". Eight project-4 tickets read "stale branch — no PR,
// tip is 8d old" while every one of those PRs had merged days earlier: the
// snapshot could not see the PR, so a finished lane was reported as an
// abandoned one. The snapshot now carries kind:"pr" with a state, and this
// guard must never widen past `branch` again — a merged or open PR is not a
// stale branch no matter how old its timestamp is.
const STALE_BRANCH_MIN = 3 * 24 * 60;

export function claimIsStaleBranch(claim, nowMs = Date.now()) {
  if (!claim || claim.kind !== 'branch' || !claim.at) return false;
  const t = Date.parse(claim.at);
  if (Number.isNaN(t)) return false;
  return nowMs - t > STALE_BRANCH_MIN * 60000;
}

// A merged PR on a ticket that is still open. Not in flight, not abandoned —
// the code landed and the board was never updated, which is a one-click fix
// rather than an investigation.
export const claimIsMerged = (claim) => Boolean(claim && claim.merged);

// Every external claim across every project, each carrying its project so the
// pipeline can show where the work is happening.
export function externalClaims(snapshot) {
  const projects = (snapshot && snapshot.projects) || {};
  const out = [];
  for (const [project, entry] of Object.entries(projects)) {
    for (const ticket of (entry && entry.tickets) || []) {
      const claim = ticketClaim(ticket);
      if (!claim || !claim.external) continue;
      out.push({
        project,
        ticket: ticket.key,
        title: ticket.title || null,
        status: ticket.status || null,
        ...claim
      });
    }
  }
  return out;
}

// One pseudo-box per distinct PERSON — the union across projects, because a
// person working two repos is one person, not two boxes. Grouped on the mapped
// IDENTITY rather than the raw login: collaborator-1 and partner-dev are the same
// human, and the actor map exists to say so — grouping on the login would
// render two identical-looking boxes, which reads as a duplicate-render bug.
// Unknown logins stay separate, because we cannot know that they are not.
export function externalActors(snapshot) {
  const projects = (snapshot && snapshot.projects) || {};
  const byActor = new Map();
  for (const [project, entry] of Object.entries(projects)) {
    for (const lane of (entry && entry.external_lanes) || []) {
      const login = normActor(lane && lane.actor);
      if (!login) continue;
      // The server should never put our own login in external_lanes, but the
      // rendering must not depend on that: a "harness" pseudo-box sitting
      // beside the real boxes would invent a machine that does not exist.
      if (login === FLEET_LOGIN) continue;
      const label = actorLabel(lane.actor, false);
      // Known people group on their identity; unknown logins group on themselves.
      const key = ACTOR_LABELS[login] ? `id:${label}` : `login:${login}`;
      if (!byActor.has(key)) {
        byActor.set(key, { actor: login, label, projects: [], lanes: [], logins: [], latestAt: null });
      }
      const row = byActor.get(key);
      if (!row.logins.includes(login)) row.logins.push(login);
      if (!row.projects.includes(project)) row.projects.push(project);
      row.lanes.push({ ...lane, project });
      if (lane.at && (!row.latestAt || Date.parse(lane.at) > Date.parse(row.latestAt))) {
        row.latestAt = lane.at;
      }
    }
  }
  return [...byActor.values()];
}

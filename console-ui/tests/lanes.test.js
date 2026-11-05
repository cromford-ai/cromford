import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  actorLabel, ticketClaim, externalClaims, externalActors, claimAge, claimIsStaleBranch,
  claimIsMerged
} from '../src/lib/lanes.js';

// determinism: ok-file clock-now-js the snapshot age and the staleness helpers are measured AS offsets
// from one captured read; no case asserts a calendar date.
const snap = {
  generated_at_epoch: Math.floor(Date.now() / 1000) - 240,
  projects: {
    'project-1': {
      tickets: [
        { key: 'TK-249', status: 'in_progress', title: 'a', updatedAt: '2026-08-24T14:00:00Z',
          claim: { actor: 'collaborator-1', fleet: false, kind: 'pr', ref: 'agent/TK-249-r2', pr: 597, pr_url: 'https://github.com/example-org/project-1/pull/597', at: '2026-08-24T14:01:00Z' } },
        { key: 'TK-250', status: 'review', title: 'b', updatedAt: '2026-08-24T13:00:00Z',
          claim: { actor: 'operator', fleet: true, kind: 'pr', pr: 598, pr_url: 'https://github.com/example-org/project-1/pull/598', at: '2026-08-24T13:01:00Z' } },
        { key: 'TK-251', status: 'todo', title: 'c', updatedAt: '2026-08-24T12:00:00Z' }
      ],
      external_lanes: [{ ticket: 'TK-249', actor: 'collaborator-1', kind: 'pr', pr: 597, pr_url: 'https://github.com/example-org/project-1/pull/597', at: '2026-08-24T14:01:00Z' }]
    },
    'project-4': {
      tickets: [
        { key: 'TK-9', status: 'in_progress', title: 'd', updatedAt: '2026-08-24T11:00:00Z',
          claim: { actor: 'someRandomDev', fleet: false, kind: 'branch', ref: 'wip/TK-9', at: '2026-06-01T09:00:00Z' } }
      ],
      external_lanes: [{ ticket: 'TK-9', actor: 'someRandomDev', kind: 'branch', at: '2026-06-01T09:00:00Z' }]
    }
  }
};

// -------------------------------------------------------------- actor labels

test('our shared PAT renders as "harness" and never names a box', () => {
  // Every one of our lanes uses the same operator PAT, so naming a box would be
  // inventing an attribution the data cannot support.
  assert.equal(actorLabel('operator', true), 'harness');
  assert.equal(actorLabel('operator', false), 'harness', 'the login alone identifies our fleet');
});

test('known third parties get their human name', () => {
  assert.equal(actorLabel('collaborator-1', false), 'partner (collaborator-1)');
  assert.equal(actorLabel('partner-dev', false), 'partner (collaborator-1)');
});

test('an unknown actor renders its login RAW, never guessed at', () => {
  assert.equal(actorLabel('someRandomDev', false), 'someRandomDev');
  assert.equal(actorLabel('', false), 'unknown actor');
  assert.equal(actorLabel(null, false), 'unknown actor');
});

test('actor matching survives casing, like every other value we compare', () => {
  assert.equal(actorLabel('operator', true), 'harness');
  assert.equal(actorLabel('collaborator-1', false), 'partner (collaborator-1)');
  assert.equal(actorLabel('  operator  ', true), 'harness');
});

// ------------------------------------------------------------------- claims

test('a ticket with no claim has no claim', () => {
  assert.equal(ticketClaim({ key: 'X' }), null);
  assert.equal(ticketClaim(null), null);
  assert.equal(ticketClaim({ key: 'X', claim: {} }), null, 'a claim with no actor claims nothing');
});

test('fleet:true is ours; fleet:false is external', () => {
  assert.equal(ticketClaim({ claim: { actor: 'operator', fleet: true } }).external, false);
  assert.equal(ticketClaim({ claim: { actor: 'x', fleet: false } }).external, true);
});

test('a MISSING fleet flag defaults to EXTERNAL, the visible direction', () => {
  // This feature exists because external work was invisible. Defaulting an
  // unparseable flag to "ours" would hide the lane again — the original bug.
  // Defaulting to external is noisy at worst, and noise is recoverable.
  assert.equal(ticketClaim({ claim: { actor: 'x' } }).external, true);
  assert.equal(ticketClaim({ claim: { actor: 'x', fleet: 'yes' } }).external, true);
  assert.equal(ticketClaim({ claim: { actor: 'x', fleet: null } }).external, true);
});

test('the string "true" still counts as ours — JSON round-trips are not all typed', () => {
  assert.equal(ticketClaim({ claim: { actor: 'operator', fleet: 'true' } }).external, false);
});

// --------------------------------------------------------- external rollups

test('external claims are collected across every project, with their project', () => {
  const rows = externalClaims(snap);
  assert.equal(rows.length, 2, 'the fleet claim is not external');
  assert.deepEqual(rows.map((r) => r.project).sort(), ['project-1', 'project-4']);
  const pb = rows.find((r) => r.ticket === 'TK-249');
  assert.equal(pb.actor, 'collaborator-1');
  assert.equal(pb.label, 'partner (collaborator-1)');
  assert.equal(pb.pr, 597);
});

test('one pseudo-box row per distinct ACTOR, not per lane', () => {
  const actors = externalActors(snap);
  assert.equal(actors.length, 2);
  const cyg = actors.find((a) => a.actor === 'collaborator-1');
  assert.equal(cyg.label, 'partner (collaborator-1)');
  assert.deepEqual(cyg.projects, ['project-1']);
  assert.equal(cyg.lanes.length, 1);
});

test('an actor working two projects is still ONE row', () => {
  const two = { projects: {
    a: { external_lanes: [{ ticket: 'T1', actor: 'dev', kind: 'pr', pr: 1, at: '2026-08-24T10:00:00Z' }] },
    b: { external_lanes: [{ ticket: 'T2', actor: 'DEV', kind: 'pr', pr: 2, at: '2026-08-24T12:00:00Z' }] }
  }};
  const actors = externalActors(two);
  assert.equal(actors.length, 1, 'casing must not split one person into two boxes');
  assert.deepEqual(actors[0].projects.sort(), ['a', 'b']);
  assert.equal(actors[0].lanes.length, 2);
});

test('the pseudo-box reports its LATEST activity', () => {
  const two = { projects: {
    a: { external_lanes: [
      { ticket: 'T1', actor: 'dev', at: '2026-08-24T10:00:00Z' },
      { ticket: 'T2', actor: 'dev', at: '2026-08-24T12:00:00Z' }
    ] }
  }};
  assert.equal(externalActors(two)[0].latestAt, '2026-08-24T12:00:00Z');
});

test('an empty or absent snapshot yields no pseudo-boxes rather than throwing', () => {
  assert.deepEqual(externalActors(null), []);
  assert.deepEqual(externalActors({}), []);
  assert.deepEqual(externalActors({ projects: { a: {} } }), []);
  assert.deepEqual(externalClaims(null), []);
});

// ------------------------------------------------------------ stale branches

test('a branch claim with an old tip is called stale, honestly', () => {
  // kind:"branch" means no PR yet; an old `at` is a branch someone abandoned.
  const old = { kind: 'branch', at: '2026-06-01T09:00:00Z' };
  assert.equal(claimIsStaleBranch(old, Date.parse('2026-08-24T12:00:00Z')), true);
});

test('a fresh branch is not stale, and a PR is never called a stale branch', () => {
  const fresh = { kind: 'branch', at: '2026-08-24T09:00:00Z' };
  assert.equal(claimIsStaleBranch(fresh, Date.parse('2026-08-24T12:00:00Z')), false);
  const pr = { kind: 'pr', at: '2026-06-01T09:00:00Z' };
  assert.equal(claimIsStaleBranch(pr, Date.parse('2026-08-24T12:00:00Z')), false);
});

// ------------------------------------------------------------ merged PR claims

test('a merged PR claim is merged, not stale, however old its timestamp is', () => {
  // The bug this fixes: eight project-4 tickets rendered "stale branch — no PR, tip
  // is 8d old" while every one of those PRs had landed days earlier. The
  // snapshot could not see the PR, so a finished lane was reported as an
  // abandoned one. It now carries kind:"pr" with state:"merged".
  const claim = ticketClaim({
    key: 'TK-9',
    claim: {
      actor: 'someRandomDev', fleet: false, kind: 'pr', state: 'merged',
      pr: 1421, pr_url: 'https://github.com/example-org/project-4/pull/1421',
      at: '2026-08-16T09:00:00Z'
    }
  });
  assert.equal(claim.state, 'merged');
  assert.equal(claim.merged, true);
  assert.equal(claimIsMerged(claim), true);
  // Eight days old and still NOT a stale branch — the guard is kind:"branch"
  // only, and widening it is what produced the wrong label in the first place.
  assert.equal(claimIsStaleBranch(claim, Date.parse('2026-08-24T12:00:00Z')), false);
  assert.equal(claim.pr, 1421, 'the PR number survives for the card to link');
});

test('an open PR claim is open, and is not reported as merged', () => {
  const claim = ticketClaim({
    key: 'TK-1',
    claim: { actor: 'dev', fleet: false, kind: 'pr', state: 'open', pr: 12, at: '2026-08-24T09:00:00Z' }
  });
  assert.equal(claim.state, 'open');
  assert.equal(claim.merged, false);
  assert.equal(claimIsMerged(claim), false);
});

test('an older snapshot with no state reads a PR claim as OPEN, never as merged', () => {
  // Backward compatibility, and the safe half to get wrong: an open PR shown as
  // open is correct today, whereas guessing "merged" would mark work finished
  // that is still in flight.
  const claim = ticketClaim({
    key: 'TK-249',
    claim: { actor: 'collaborator-1', fleet: false, kind: 'pr', pr: 597, at: '2026-08-24T14:01:00Z' }
  });
  assert.equal(claim.state, 'open');
  assert.equal(claim.merged, false);
  // An unrecognised state is treated the same way, for the same reason.
  const odd = ticketClaim({ key: 'X', claim: { actor: 'dev', kind: 'pr', state: 'DRAFT', pr: 1 } });
  assert.equal(odd.state, 'open');
  assert.equal(odd.merged, false);
});

test('a branch claim carries no PR state and can still go stale', () => {
  const claim = ticketClaim({
    key: 'TK-9',
    claim: { actor: 'dev', fleet: false, kind: 'branch', ref: 'wip/TK-9', at: '2026-06-01T09:00:00Z' }
  });
  assert.equal(claim.state, null, 'state is a PR concept; a branch has none');
  assert.equal(claim.merged, false);
  assert.equal(claimIsStaleBranch(claim, Date.parse('2026-08-24T12:00:00Z')), true);
});

test('claimIsMerged never throws on a missing or malformed claim', () => {
  assert.equal(claimIsMerged(null), false);
  assert.equal(claimIsMerged(undefined), false);
  assert.equal(claimIsMerged({}), false);
});

test('an unparseable date is not asserted to be stale', () => {
  assert.equal(claimIsStaleBranch({ kind: 'branch', at: 'nonsense' }, Date.now()), false);
  assert.equal(claimIsStaleBranch({ kind: 'branch' }, Date.now()), false);
  assert.equal(claimAge({ at: 'nonsense' }), null);
});

test('two logins for the SAME person are one pseudo-box, not two', () => {
  // The actor map exists precisely to collapse collaborator-1 and partner-dev
  // into one human. Grouping by raw login renders two identical-looking boxes
  // for one person, which reads as a duplicate-render bug.
  const two = { projects: {
    'project-1': { external_lanes: [{ ticket: 'TK-1', actor: 'collaborator-1', kind: 'pr', pr: 597, at: '2026-08-24T14:00:00Z' }] },
    'project-3': { external_lanes: [{ ticket: 'TK-1', actor: 'partner-dev', kind: 'pr', pr: 12, at: '2026-08-24T12:00:00Z' }] }
  }};
  const actors = externalActors(two);
  assert.equal(actors.length, 1);
  assert.equal(actors[0].label, 'partner (collaborator-1)');
  assert.deepEqual(actors[0].projects.sort(), ['project-1', 'project-3']);
  assert.equal(actors[0].lanes.length, 2);
  assert.deepEqual(actors[0].logins.sort(), ['collaborator-1', 'partner-dev'],
    'the underlying logins stay visible — the person is one, the accounts are two');
  assert.equal(actors[0].latestAt, '2026-08-24T14:00:00Z');
});

test('two UNKNOWN logins stay two people — we cannot know they are one', () => {
  const two = { projects: { a: { external_lanes: [
    { ticket: 'T1', actor: 'devA', at: '2026-08-24T10:00:00Z' },
    { ticket: 'T2', actor: 'devB', at: '2026-08-24T11:00:00Z' }
  ] } } };
  assert.equal(externalActors(two).length, 2);
});

// ------------------------------------ inherited Object keys are not actor labels

test('a login named "constructor" renders raw, not a function body', () => {
  // A plain object literal inherits from Object.prototype, so ACTOR_LABELS
  // ['constructor'] is the Object constructor — truthy, and it would render
  // "function Object() { [native code] }" as somebody's name. `constructor`,
  // `toString` and `valueOf` are all valid GitHub usernames.
  for (const login of ['constructor', 'toString', 'valueOf', 'hasOwnProperty']) {
    assert.equal(actorLabel(login, false), login, login);
  }
});

test('an inherited-key login groups as its own person, not as a poisoned key', () => {
  const snap = { projects: {
    'project-1': { external_lanes: [{ ticket: 'TK-1', actor: 'constructor', kind: 'pr', pr: 5, at: '2026-08-24T10:00:00Z' }] }
  }};
  const actors = externalActors(snap);
  assert.equal(actors.length, 1);
  assert.equal(actors[0].label, 'constructor');
  assert.deepEqual(actors[0].logins, ['constructor']);
});

// -------------------------------- an explicit fleet:false is always honoured

test('an explicit fleet:false is EXTERNAL even for our own login', () => {
  // The one case the code could hide a lane — the original bug this whole
  // feature exists to prevent. An explicit flag outranks the actor fallback.
  assert.equal(ticketClaim({ claim: { actor: 'operator', fleet: false } }).external, true);
  assert.equal(ticketClaim({ claim: { actor: 'operator', fleet: 'false' } }).external, true);
  assert.equal(ticketClaim({ claim: { actor: 'operator', fleet: false } }).external, true);
});

test('the classification order is explicit-true, explicit-false, then the actor fallback', () => {
  assert.equal(ticketClaim({ claim: { actor: 'someone', fleet: true } }).external, false);
  assert.equal(ticketClaim({ claim: { actor: 'someone', fleet: false } }).external, true);
  assert.equal(ticketClaim({ claim: { actor: 'operator' } }).external, false, 'no flag: our login is ours');
  assert.equal(ticketClaim({ claim: { actor: 'someone' } }).external, true, 'no flag: anyone else is external');
});

// ---------------------------------- our own login never becomes a pseudo-box

test('a fleet login in external_lanes never renders a pseudo-box', () => {
  // The server should not emit it there, but the rendering must not depend on
  // that — a "harness" pseudo-box beside the real boxes invents a machine.
  const snap = { projects: {
    'project-1': { external_lanes: [
      { ticket: 'TK-1', actor: 'operator', kind: 'pr', pr: 1, at: '2026-08-24T10:00:00Z' },
      { ticket: 'TK-2', actor: 'collaborator-1', kind: 'pr', pr: 2, at: '2026-08-24T11:00:00Z' }
    ] }
  }};
  const actors = externalActors(snap);
  assert.equal(actors.length, 1);
  assert.equal(actors[0].label, 'partner (collaborator-1)');
  assert.equal(actors.some((a) => a.label === 'harness'), false);
});

test('a fleet-only external_lanes list yields no pseudo-boxes at all', () => {
  const snap = { projects: { a: { external_lanes: [{ ticket: 'T', actor: 'operator', at: '2026-08-24T10:00:00Z' }] } } };
  assert.deepEqual(externalActors(snap), []);
});

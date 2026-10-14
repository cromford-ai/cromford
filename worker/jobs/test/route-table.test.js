import test from 'node:test';
import assert from 'node:assert/strict';
import { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute, matcherSignature } from '../src/lib/router.js';
import { existsSync, readdirSync, readFileSync } from 'node:fs';

// THE TABLE ANSWERS EXACTLY WHAT THE CHAIN ANSWERED, IN THE SAME ORDER.
//
// Until BH-1195 every route in this worker lived in one flat
// `if (path === … && req.method === …)` chain inside `fetch`, 3,497 lines of
// it. The split moved each handler into src/routes/<family>.js and replaced the
// chain with an ordered `[method, matcher, handler]` table — which is only a
// safe move if the table answers the same (method, path) pairs, in the same
// order, and answers nothing new. Order is not cosmetic: the chain was
// first-match-wins, so `GET /api/jobs/:id` sitting above `GET /api/jobs` is the
// reason each one reaches its own handler.
//
// CHAIN is that chain, extracted from the pre-split file and frozen — as
// FRAGMENTS since Lane E (2026-09-24): test/route-table.d/<NNN>-<family>.txt,
// one per src/routes/<family>.js, each holding that family's signatures in
// table order (`#` lines are comments). CHAIN is their concatenation in file
// name order, so the three-digit prefix IS the cross-family order the table
// must keep. It is still the fixture, not a restatement of the table:
// regenerate it only from the old source, never from the new one —
//
//   git show d5f53aa8:worker/jobs/src/index.js
//
// and read the `path === …` / `path.match(…)` conditions out of the `fetch`
// body in order. A route added later is added to BOTH lists, deliberately, in
// the position the table puts it: a route in an existing family goes into that
// family's fragment; a NEW family is a new fragment whose number sits between
// its neighbours' (they are spaced by ten). Before Lane E this was one array
// every route PR edited — 20 commits in four days, several of them splicing
// "directly under the hub lease" at the same line — so two unrelated route PRs
// conflicted here on a hunk neither was about.
// TEST-CHANGE (Lane E): CHAIN's data moved into test/route-table.d/; every
// assertion below compares against the same list, entry for entry.
const FRAG_DIR = new URL('./route-table.d/', import.meta.url);
// TEST-CHANGE (BH-5788): a fragment may also be <ticket-key>-<family>.txt.
// The regexp is route-families.js's FRAG_RE: group 2 or group 4 is the family,
// and only a numbered fragment (group 1) has an order number.
const FRAG_RE = /^(?:(\d{3})-([a-z0-9-]+)|([a-z]+-\d+(?:[.-]\d+)?)-([a-z][a-z0-9-]*))\.txt$/;
const familyOf = (f) => { const m = f.match(FRAG_RE); return m[2] ?? m[4]; };
const fragFiles = () => (existsSync(FRAG_DIR) ? readdirSync(FRAG_DIR) : []).sort();
const fragLines = (f) => readFileSync(new URL(f, FRAG_DIR), 'utf8')
  .split('\n').filter((l) => l.trim() !== '' && !l.startsWith('#'));
const CHAIN = fragFiles().filter((f) => FRAG_RE.test(f)).flatMap(fragLines);

const table = () => [...OPEN_ROUTES, ...ROUTES];
const sigOf = ([method, matcher]) => `${method} ${matcherSignature(matcher)}`;

test('the router table carries every route the old chain answered, exactly once, in chain order', () => {
  assert.deepEqual(table().map(sigOf), CHAIN,
    'the table and the pre-split chain disagree — a route was dropped, added, or reordered');
});

test('no route is registered twice', () => {
  const seen = new Map();
  for (const sig of table().map(sigOf)) seen.set(sig, (seen.get(sig) || 0) + 1);
  const dupes = [...seen].filter(([, n]) => n > 1);
  assert.deepEqual(dupes, [], 'a duplicate entry means the second copy is dead code the first shadows');
});

test('every entry is [method, matcher, handler] and every handler is a function', () => {
  for (const entry of table()) {
    assert.equal(entry.length, 3, `not a 3-tuple: ${JSON.stringify(entry[1])}`);
    assert.equal(typeof entry[0], 'string', 'method must be a string');
    assert.equal(typeof entry[2], 'function', `handler for ${sigOf(entry)} is not a function`);
  }
});

// THE FRAGMENTS ARE WELL FORMED. Every file in the directory is read — a
// stray `.orig` or a misnamed fragment would otherwise be skipped in silence —
// no two share an order number, and each one is exactly the routes its family
// module exports, in order, so a signature filed under the wrong family is
// named here rather than only as a shifted index in the comparison above.
test('route-table.d: every file is an <NNN>-<family>.txt or <ticket-key>-<family>.txt fragment with a unique number', () => {
  const files = fragFiles();
  assert.ok(files.length > 0, 'test/route-table.d holds no fragments');
  const bad = files.filter((f) => !FRAG_RE.test(f));
  assert.deepEqual(bad, [], 'not a <NNN>-<family>.txt or <ticket-key>-<family>.txt fragment, so never read');
  const nums = files.map((f) => f.match(FRAG_RE)[1]).filter(Boolean);
  assert.deepEqual(nums.filter((n, i) => nums.indexOf(n) !== i), [], 'two fragments share an order number');
});

test('route-table.d: each fragment is exactly its family module\'s routes, in order', async () => {
  const files = fragFiles().filter((f) => FRAG_RE.test(f));
  assert.ok(files.length > 0, 'test/route-table.d holds no fragments');
  for (const f of files) {
    const family = familyOf(f);
    const mod = await import(new URL(`../src/routes/${family}.js`, import.meta.url)).catch(() => null);
    assert.ok(mod && Array.isArray(mod.routes), `${f}: src/routes/${family}.js does not export routes`);
    assert.deepEqual(mod.routes.map(sigOf), fragLines(f), `${f} disagrees with src/routes/${family}.js`);
  }
});

// A matcher nobody can read is a table nobody can check: the test above only
// works because every matcher is DATA (a string, a list, a prefix, a regexp, a
// regexp with a guard) rather than a closure.
test('every matcher is introspectable data', () => {
  for (const [, matcher] of table()) {
    const ok = typeof matcher === 'string' || Array.isArray(matcher)
      || matcher instanceof RegExp
      || (matcher && typeof matcher === 'object' && (typeof matcher.prefix === 'string' || matcher.re instanceof RegExp));
    assert.ok(ok, `matcher is not data: ${String(matcher)}`);
  }
});

// The chain's resolution, driven. Each pair below reached exactly one body
// before the split; `matchRoute` must land on the same one.
const RESOLVES = [
  ['GET',   '/api/jobs',                    'GET /api/jobs'],
  ['GET',   '/api/jobs/J-1',                'GET re:/^\\/api\\/jobs\\/([^/]+)$/'],
  ['PATCH', '/api/jobs/J-1',                'PATCH re:/^\\/api\\/jobs\\/([^/]+)$/'],
  ['GET',   '/api/jobs/J-1/live',           'GET re:/^\\/api\\/jobs\\/([^/]+)\\/live$/'],
  ['POST',  '/api/jobs/J-1/heartbeat',      'POST re:/^\\/api\\/jobs\\/([^/]+)\\/heartbeat$/'],
  ['GET',   '/api/jobs/J-1/transcript',     'GET re:/^\\/api\\/jobs\\/([^/]+)\\/transcript$/'],
  ['GET',   '/api/jobs/J-1/transcripts',    'GET re:/^\\/api\\/jobs\\/([^/]+)\\/transcripts$/'],
  ['GET',   '/api/settings',                'GET /api/settings'],
  ['GET',   '/api/settings/model.plan',     'GET prefix:/api/settings/'],
  ['POST',  '/api/settings/seed-registry',  'POST /api/settings/seed-registry'],
  ['GET',   '/api/settings/seed-registry/plan', 'GET /api/settings/seed-registry/plan'],
  ['GET',   '/api/lanes/tick-boxes',        'GET /api/lanes/tick-boxes'],
  ['GET',   '/api/catalog/build',           'GET prefix:/api/catalog/'],
  ['GET',   '/api/hub-lease',               'GET any:/api/hub/lease|/api/hub-lease'],
  ['POST',  '/api/hub-lease',               'POST any:/api/hub/lease/renew|/api/hub-lease'],
  ['POST',  '/api/hub/lease/promote',       'POST any:/api/hub/lease/promote|/api/hub-lease/promote'],
  // BH-1942: /api/hub/promote is its own route, not the lease promote above,
  // and `claim` is the literal, not an id the result regexp swallowed.
  ['POST',  '/api/hub/promote',             'POST /api/hub/promote'],
  ['POST',  '/api/hub/restore-lab/claim',   'POST /api/hub/restore-lab/claim'],
  ['POST',  '/api/hub/restore-lab/7/result', 'POST re:/^\\/api\\/hub\\/restore-lab\\/(\\d+)\\/result$/'],
  ['POST',  '/api/lanes/all-off',           'POST any:/api/lanes/all-off|/api/lanes/all-on'],
  ['POST',  '/api/lanes/liveness',          'POST /api/lanes/liveness'],
  ['POST',  '/api/lanes/flag-seen',         'POST /api/lanes/flag-seen'],
  ['PATCH', '/api/machines/m-1',            'PATCH re:/^\\/api\\/machines\\/([A-Za-z0-9._-]{1,64})$/ !observe'],
  ['PUT',   '/api/machines/observe',        'PUT /api/machines/observe'],
  ['POST',  '/api/queue/claim',             'POST /api/queue/claim'],
  ['POST',  '/api/deploy-queue/claim',      'POST /api/deploy-queue/claim'],
  ['GET',   '/api/metrics/cost-anchored',   'GET /api/metrics/cost-anchored'],
  ['GET',   '/api/alerts',                  'GET any:/api/alerts|/api/alerts/families'],
  ['GET',   '/api/alerts/families',         'GET any:/api/alerts|/api/alerts/families'],
  ['POST',  '/api/alerts/claim',            'POST /api/alerts/claim'],
  // BH-1386: the DELETE is the only route in the new family whose method is not
  // shared with another route on the same path, so it is the one that proves
  // the method half of the match — a table that dropped it would resolve the
  // path to the GET and answer a forget with a lookup.
  ['DELETE', '/api/pr-attempts',            'DELETE /api/pr-attempts'],
  ['GET',   '/api/pr-attempts',             'GET /api/pr-attempts'],
  // BH-4953: exact paths, so GET /api/pr-state can never answer for them.
  ['GET',   '/api/pr-state/gate',           'GET /api/pr-state/gate'],
  ['GET',   '/api/pr-state/needs-review',   'GET /api/pr-state/needs-review'],
];

test('matchRoute lands on the same handler the chain did', () => {
  for (const [method, path, want] of RESOLVES) {
    const hit = matchRoute(ROUTES, method, path);
    assert.ok(hit, `${method} ${path} matched nothing`);
    assert.equal(sigOf(hit.entry), want, `${method} ${path} landed on the wrong entry`);
  }
});

// The chain guarded the machine-detail regexp with `machineMatch[1] !== "observe"`
// so that a PATCH to /api/machines/observe FELL THROUGH to the routes under it
// and ended at the 404. A matcher that dropped the guard would answer here
// instead, turning a 404 into a machine patch on a machine named "observe".
test('PATCH /api/machines/observe still falls through to nothing', () => {
  assert.equal(matchRoute(ROUTES, 'PATCH', '/api/machines/observe'), null);
});

test('an unknown path matches nothing, so the entry point can 404 it', () => {
  assert.equal(matchRoute(ROUTES, 'GET', '/api/nope'), null);
  assert.equal(matchRoute(ROUTES, 'DELETE', '/api/jobs'), null);
});

// The bearer is checked between the open table and the gated one, so a route in
// the wrong table is a route with the wrong credential.
test('only the three tracker webhooks, the two ci-durations routes, the two ci-test-tiers routes and the three suite-ledger routes are open; each webhook is open to every method', () => {
  // BH-4079 added Jira and Linear beside GitHub; each carries its own HMAC.
  // Sentry/PagerDuty intake is out of scope, so no other /webhooks/* opens.
  // BH-5653: the ci-durations pair carries its own scoped bearer
  // (CI_DURATIONS_TOKEN or HARNESS_SECRET), so CI never holds the main one.
  // TEST-CHANGE (BH-5653): OPEN_ROUTES gains the two ci-durations routes; the webhook assertions and the /api/jobs refusal stay.
  // TEST-CHANGE (BH-5653 C1): and the ci-test-tiers pair, whose handlers check
  // their own bearer (GET: CI_DURATIONS_TOKEN or HARNESS_SECRET; PUT: HARNESS_SECRET only).
  // BH-5366 added the suite ledger (CI has no bearer); each route checks its
  // own credential with credentialClass(), and only on its exact method.
  // TEST-CHANGE (merge of main into BH-5366): OPEN_ROUTES carries all three sets; every assertion of each side stays.
  assert.deepEqual(OPEN_ROUTES.map(sigOf), ['* /webhooks/github', '* /webhooks/jira', '* /webhooks/linear',
    'POST /api/ci/suite-durations', 'GET /api/ci/suite-durations',
    'GET /api/ci/test-tiers', 'PUT /api/ci/test-tiers',
    'POST /api/suite-results/lookup', 'PUT /api/suite-results', 'PUT /api/suite-results/runs']);
  assert.equal(matchRoute(OPEN_ROUTES, 'GET', '/api/suite-results'), null);
  assert.equal(matchRoute(OPEN_ROUTES, 'GET', '/api/suite-results/runs'), null);
  for (const v of ['github', 'jira', 'linear']) {
    assert.ok(matchRoute(OPEN_ROUTES, 'GET', `/webhooks/${v}`), `a GET must still reach /webhooks/${v}, to be 405ed`);
    assert.ok(matchRoute(OPEN_ROUTES, 'POST', `/webhooks/${v}`));
  }
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', '/webhooks/sentry'), null);
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', '/webhooks/pagerduty'), null);
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', '/api/jobs'), null);
  for (const method of ['GET', 'POST']) {
    const hit = matchRoute(OPEN_ROUTES, method, '/api/ci/suite-durations');
    assert.ok(hit, `${method} /api/ci/suite-durations must match in OPEN_ROUTES`);
    assert.equal(sigOf(hit.entry), `${method} /api/ci/suite-durations`);
  }
  for (const method of ['GET', 'PUT']) {
    const hit = matchRoute(OPEN_ROUTES, method, '/api/ci/test-tiers');
    assert.ok(hit, `${method} /api/ci/test-tiers must match in OPEN_ROUTES`);
    assert.equal(sigOf(hit.entry), `${method} /api/ci/test-tiers`);
  }
  assert.equal(matchRoute(OPEN_ROUTES, 'POST', '/api/ci/test-tiers'), null);
});

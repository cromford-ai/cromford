// BH-9258 (#9061 Fix 4): the pool_status tool (mcp/tools/pool-status.mjs)
// passes the route's gates_today through, so the in-app AI reads the same
// daily selection-gate count as the project page. Through the REAL registry
// and the REAL consoleFetch against the stub console; any fetch off the stub
// is refused and counted.
// The counts are the ones the real lane posted
// (tests/fixtures/pool-tick-gate-counts.bh-9258/post.json, pinned by
// tests/pool-tick-gate-counts.bh-9258-test.sh P1 and round-tripped through the
// worker by worker/jobs/test/pool-tick-gates.bh-9258.test.js W1).
//   M1 gates_today is passed through, field for field
//   M2 an absent, null, array or string gates_today is null
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const fetched = [];
const realFetch = globalThis.fetch;
let stubOrigin = null;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  if (!stubOrigin || !url.startsWith(stubOrigin + '/')) return Promise.reject(new Error(`blocked off-stub fetch: ${url}`));
  return realFetch(input, init);
};

const { loadTools, callTool } = await import('../lib/tools.mjs');
const { startStub } = await import('./lib/stub-console.mjs');

const HERE = dirname(fileURLToPath(import.meta.url));
const BASE = JSON.parse(readFileSync(join(HERE, 'fixtures/pool-status.bh-7709.json'), 'utf8'));
const POSTED = JSON.parse(readFileSync(join(HERE, '../../tests/fixtures/pool-tick-gate-counts.bh-9258/post.json'), 'utf8'));
const GATES = POSTED.rows.find((r) => r.project === 'p').gates_today;
const PATH = '/api/coord/pool/status?project=fixture-os';
const registry = await loadTools(new URL('../tools/', import.meta.url));

async function call(t, answer) {
  const stub = await startStub({ routes: { [PATH]: { json: answer } } });
  stubOrigin = stub.url;
  t.after(() => stub.close());
  const r = await callTool(registry, 'pool_status', { project: 'fixture-os' },
    { cfg: { url: stub.url, token: 'tok-fixture-9258', secret: null } });
  assert.notEqual(r.isError, true, r.content?.[0]?.text);
  assert.deepEqual(JSON.parse(r.content[0].text), r.structuredContent);
  return r.structuredContent;
}

test('M1 gates_today is passed through, field for field', async (t) => {
  assert.equal(GATES.gates, 4);
  const before = fetched.length;
  const o = await call(t, { ...BASE, gates_today: { ...GATES, stray: 'tok-fixture-planted' } });
  assert.deepEqual(o.gates_today, GATES);
  assert.equal(JSON.stringify(o).includes('tok-fixture-planted'), false);
  assert.equal(o.skips.waits_for.count, 13); // the BH-7709 fields are unchanged
  assert.equal(fetched.slice(before).every((u) => u.startsWith(stubOrigin + '/')), true);
});

test('M2 an absent, null, array or string gates_today is null', async (t) => {
  const { gates_today: _drop, ...without } = { ...BASE };
  for (const answer of [without, { ...BASE, gates_today: null }, { ...BASE, gates_today: [GATES] }, { ...BASE, gates_today: 'x' }]) {
    const o = await call(t, answer);
    assert.ok(Object.hasOwn(o, 'gates_today'));
    assert.equal(o.gates_today, null, JSON.stringify(answer.gates_today));
  }
});

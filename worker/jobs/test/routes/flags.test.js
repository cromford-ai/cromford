import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso } from '../lib/harness.js';

test('a flag name is a file name: nothing that could escape flags/ is accepted', async () => {
  for (const name of ['../../etc/passwd', 'paused project-3', 'paused/project-3', '']) {
    const r = await call('/api/flags', { method: 'PUT', body: { name, active: 1 } });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(name)}`);
  }
});

test('a flag write needs an explicit active, and coerces the shapes a client sends', async () => {
  const missing = await call('/api/flags', { method: 'PUT', body: { name: 'paused-project-3' } });
  assert.equal(missing.status, 400);
  for (const [sent, want] of [[true, 1], ['true', 1], [1, 1], [0, 0], ['0', 0], [false, 0]]) {
    const r = await call('/api/flags', { method: 'PUT', body: { name: 'paused-project-3', active: sent } });
    assert.equal(r.status, 200);
    // TEST-CHANGE BH-4154: paused-* is a ported name and its write no longer
    // mirrors into pause_flags, so the coerced value is read from the
    // harness_flags upsert: ON binds cleared_at (?7) NULL, OFF binds a stamp.
    assert.ok(!r.db._calls.some((c) => /INSERT INTO pause_flags/.test(c.sql)), 'no pause_flags mirror');
    const ins = r.db._calls.find((c) => /INSERT INTO harness_flags/.test(c.sql));
    const got = ins.binds[6] === null ? 1 : 0;
    assert.equal(got, want, `active ${JSON.stringify(sent)} became ${got}`);
  }
});

test('an unknown flag is a 404 - a real answer the client maps to "nothing to reconcile"', async () => {
  const r = await call('/api/flags/paused-project-3');
  assert.equal(r.status, 404);
  const found = await call('/api/flags/paused-project-3', {
    state: { flags: [{ name: 'paused-project-3', active: 1, updated_at: iso(0) }] }
  });
  assert.equal(found.status, 200);
  assert.equal(found.body.flag.active, 1);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from '../lib/harness.js';

test('telegram-topics PUT validates project and thread_id, GET returns map', async () => {
  const badProject = await call('/api/telegram-topics', { method: 'PUT', body: { project: '../x', thread_id: 1 } });
  assert.equal(badProject.status, 400);
  const badThread1 = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'cromford', thread_id: 'abc' } });
  assert.equal(badThread1.status, 400);
  const badThread2 = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'cromford', thread_id: 0 } });
  assert.equal(badThread2.status, 400);
  const badThread3 = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'cromford', thread_id: '0' } });
  assert.equal(badThread3.status, 400);

  const fractional = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'cromford', thread_id: '6.9' } });
  assert.equal(fractional.status, 400, 'thread 6.9 must not be stored as topic 6');
  assert.equal(fractional.db._calls.filter((c) => /telegram_topics/.test(c.sql)).length, 0);
  // project-5 next to project-5 would be two topic rows for one project.
  const upper = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'Cromford', thread_id: 6 } });
  assert.equal(upper.status, 400);
  assert.equal(upper.db._calls.filter((c) => /telegram_topics/.test(c.sql)).length, 0);

  const r = await call('/api/telegram-topics', { method: 'PUT', body: { project: 'cromford', thread_id: '6', actor: 'hub' } });
  assert.equal(r.status, 200);
  const ins = r.db._calls.find((c) => /INSERT INTO telegram_topics/.test(c.sql));
  assert.equal(ins.binds[1], 6);
  assert.deepEqual(r.body, { topic: { project: 'cromford', thread_id: 6 } });

  const empty = await call('/api/telegram-topics');
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.topics, {});

  const full = await call('/api/telegram-topics', {
    state: { topics: [
      { project: 'cromford', thread_id: 6, actor: 'hub', updated_at: 't' },
      { project: 'project-5', thread_id: 42, actor: 'hub', updated_at: 't' }
    ] }
  });
  // project -> thread id: a caller doing .topics[project] wants the integer it
  // posts to, not the row it came from.
  assert.deepEqual(full.body.topics, { 'cromford': 6, 'project-5': 42 });
});

// BH-6350: the per-project dispatch mode row `dispatch-mode-<p>` is a PORTED
// harness_flags name, so PUT /api/flags stores its value (up to 512 chars) in
// harness_flags, scope fleet, and writes one config_changes audit row in the
// same batch. The value is the shell's dm_parse grammar (bin/lib/dispatch-mode.sh):
// `hotfix-only` or `hotfix-only:<n>,<n>`.
//
//   W1 PUT stores the row (scope fleet, the value, cleared_at null)
//   W2 the PUT writes exactly one config_changes row that holds the value
//   W3 DELETE clears the row and writes one more audit row
//   W4 GET /api/flags/dispatch-mode-<p> returns the value
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const NAME = 'dispatch-mode-bh';
const VALUE = 'hotfix-only:6291,6292';

const call = (DB, method, path, body) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  await fn(opened);
}

const hrow = (db, name) => db.prepare("SELECT * FROM harness_flags WHERE scope='fleet' AND name=?").get(name);
const audits = (db, name) =>
  db.prepare("SELECT * FROM config_changes WHERE kind='flag' AND name=? ORDER BY id").all(name);
const put = (DB) => call(DB, 'PUT', '/api/flags', { name: NAME, active: 1, value: VALUE, reason: 'r', actor: 'console' });

test('W1 PUT dispatch-mode-<p> stores the value in harness_flags, scope fleet', (t) => withDb(t, async ({ db, DB }) => {
  const r = await put(DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const h = hrow(db, NAME);
  assert.ok(h, 'harness_flags row written');
  assert.equal(h.value, VALUE);
  assert.equal(h.cleared_at, null);
  assert.equal(h.reason, 'r');
}));

test('W2 the PUT writes exactly one audit row that holds the value', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB);
  const a = audits(db, NAME);
  assert.equal(a.length, 1);
  assert.equal(a[0].kind, 'flag');
  assert.equal(JSON.parse(a[0].after_json).value, VALUE);
}));

test('W3 DELETE clears the row and adds one audit row', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB);
  const r = await call(DB, 'DELETE', `/api/flags?name=${NAME}&reason=x`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.notEqual(hrow(db, NAME).cleared_at, null);
  assert.equal(audits(db, NAME).length, 2);
}));

test('W4 GET returns the value (not refused as a non-ported name)', (t) => withDb(t, async ({ DB }) => {
  await put(DB);
  const r = await call(DB, 'GET', `/api/flags/${NAME}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.flag.value, VALUE);
  assert.equal(r.body.flag.cleared_at, null);
}));

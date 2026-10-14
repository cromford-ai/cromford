// BH-4153 (BH-4141.1): flags in the DB. The ported families (paused-*,
// automerge-disabled, automerge-disabled-*, lanedown-*) live in harness_flags,
// keyed (scope, name). TEST-CHANGE BH-4154: the fleet-scope pause_flags mirror
// is retired; the worker readers read harness_flags for these names, so W1, W1b,
// W2 and W8 now pin that NO pause_flags row is written.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim,
// through the real worker.fetch:
//   W1  PUT ported fleet -> harness_flags row (cleared_at NULL), NO pause_flags
//       row (BH-4154), one config_changes kind=flag row; a same-value re-PUT
//       adds no audit row; a value change does; value is capped at 512 chars;
//       an inactive PUT on no row creates it cleared; a re-set reopens it;
//   W2  DELETE -> cleared_at set, no pause_flags row, one audit row; an unknown
//       name is a 404; an already-cleared row is a 200 with no write;
//   W3  a box-scoped PUT (lanedown-*, scope boxa) writes no pause_flags row;
//       a bad scope is a 400;
//   W4  a non-ported PUT/DELETE (alerts-db) is the legacy body: pause_flags
//       only, harness_flags untouched, legacy response keys;
//   W5  GET list merges both stores, every row in the full shape, a ported name
//       once; ?prefix, ?scope and ?active=1 filter; bad scope/prefix -> 400;
//       the 500 cap reports truncated;
//   W6  GET /api/flags/<name>?scope= -> ported from harness_flags, 404 absent;
//   W7  checkPause refuses a claim after PUT paused-<p> and allows it after
//       DELETE (through harness_flags since BH-4154);
//   W8  expected_set_at mismatch -> 409 {error:'flag moved'} and no write;
//   W9  the backfill statement run twice changes nothing the second time and
//       never overwrites an existing harness_flags row; schema.sql and
//       CREATED_TABLES carry the same statements;
//   W10 FLAG_PORTED_RE is one line, the text the shell copy is compared to.
//   W11 (BH-4883) the readers on main before #4332 (bin/lib/jobs/flags.sh
//       _flag_row, bin/lib/lane-switch.sh) read only .flag.active (0|1) and
//       .flag.updated_at from GET /api/flags/<name>: through set, clear and
//       re-set of a ported name, both stay readable and track each write.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const FULL_KEYS = ['scope', 'name', 'value', 'set_by', 'reason', 'set_at', 'cleared_at', 'active', 'actor', 'updated_at'];

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

const hrow = (db, name, scope = 'fleet') =>
  db.prepare('SELECT * FROM harness_flags WHERE scope=? AND name=?').get(scope, name);
const prow = (db, name) => db.prepare('SELECT * FROM pause_flags WHERE name=?').get(name);
const audits = (db, name) =>
  db.prepare("SELECT * FROM config_changes WHERE kind='flag' AND name=? ORDER BY id").all(name);
const hcount = (db) => db.prepare('SELECT COUNT(*) AS n FROM harness_flags').get().n;
const sortedKeys = (o) => Object.keys(o).sort();

test('W1 PUT ported fleet writes the row, no mirror and one audit row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console', reason: 'freeze' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const h = hrow(db, 'paused-p');
  assert.ok(h, 'harness_flags row written');
  assert.equal(h.cleared_at, null);
  assert.equal(h.set_by, 'console');
  assert.equal(h.reason, 'freeze');
  assert.equal(h.value, null);
  // TEST-CHANGE BH-4154: the mirror is retired, so no pause_flags row.
  assert.equal(prow(db, 'paused-p'), undefined, 'no pause_flags mirror');
  assert.equal(audits(db, 'paused-p').length, 1);
  // The response row is the full shape, legacy keys included.
  assert.deepEqual(sortedKeys(r.body.flag), [...FULL_KEYS].sort());
  assert.equal(r.body.flag.active, 1);
  assert.equal(r.body.flag.actor, 'console');
  assert.equal(r.body.flag.updated_at, h.set_at);

  const again = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'poll', reason: 'r2' });
  assert.equal(again.status, 200);
  assert.equal(audits(db, 'paused-p').length, 1, 'a same-value re-PUT is not a decision');
  assert.equal(hrow(db, 'paused-p').reason, 'r2', 'the re-PUT still upserts');

  const val = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, value: 'x'.repeat(600), actor: 'console' });
  assert.equal(val.status, 200);
  assert.equal(hrow(db, 'paused-p').value.length, 512, 'value capped at 512');
  assert.equal(audits(db, 'paused-p').length, 2, 'a value change is audited');
  const after = JSON.parse(audits(db, 'paused-p')[1].after_json);
  assert.equal(after.active, 1);
  assert.equal(after.value.length, 512);
}));

test('W1b an inactive PUT on no row creates it cleared; a re-set reopens it', (t) => withDb(t, async ({ db, DB }) => {
  const off = await call(DB, 'PUT', '/api/flags', { name: 'automerge-disabled', active: 0, actor: 'console' });
  assert.equal(off.status, 200);
  const h = hrow(db, 'automerge-disabled');
  assert.ok(h);
  assert.equal(typeof h.cleared_at, 'string');
  assert.equal(h.cleared_at, h.set_at);
  // TEST-CHANGE BH-4154: the mirror is retired, so no pause_flags row.
  assert.equal(prow(db, 'automerge-disabled'), undefined);
  assert.equal(off.body.flag.active, 0);

  const on = await call(DB, 'PUT', '/api/flags', { name: 'automerge-disabled', active: 1, actor: 'console' });
  assert.equal(on.status, 200);
  assert.equal(hrow(db, 'automerge-disabled').cleared_at, null);
  // TEST-CHANGE BH-4154: the re-set writes no pause_flags row either.
  assert.equal(prow(db, 'automerge-disabled'), undefined);
  assert.equal(audits(db, 'automerge-disabled').length, 2);
}));

test('W2 DELETE clears, writes no mirror and audits once; unknown 404; cleared is a no-op 200', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console', reason: 'freeze' });
  const del = await call(DB, 'DELETE', '/api/flags?name=paused-p&scope=fleet&reason=back&actor=operator');
  assert.equal(del.status, 200, JSON.stringify(del.body));
  const h = hrow(db, 'paused-p');
  assert.equal(typeof h.cleared_at, 'string');
  assert.equal(h.reason, 'back');
  assert.equal(h.set_by, 'operator');
  // TEST-CHANGE BH-4154: the clear writes no pause_flags row.
  assert.equal(prow(db, 'paused-p'), undefined);
  const a = audits(db, 'paused-p');
  assert.equal(a.length, 2);
  assert.equal(JSON.parse(a[1].after_json).active, 0);
  assert.equal(a[1].actor, 'operator');
  assert.equal(del.body.flag.active, 0);
  assert.deepEqual(sortedKeys(del.body.flag), [...FULL_KEYS].sort());

  const unknown = await call(DB, 'DELETE', '/api/flags?name=paused-nope');
  assert.equal(unknown.status, 404);
  assert.equal(hrow(db, 'paused-nope'), undefined);

  const before = { ...hrow(db, 'paused-p') };
  const twice = await call(DB, 'DELETE', '/api/flags?name=paused-p&reason=again&actor=x');
  assert.equal(twice.status, 200);
  assert.equal(audits(db, 'paused-p').length, 2, 'an already-cleared DELETE writes no audit row');
  assert.deepEqual({ ...hrow(db, 'paused-p') }, before, 'an already-cleared DELETE writes nothing');

  for (const q of ['name=../x', 'name=', 'name=paused-p&scope=bad%20scope']) {
    const bad = await call(DB, 'DELETE', `/api/flags?${q}`);
    assert.equal(bad.status, 400, q);
  }
}));

test('W3 a box-scoped PUT writes no pause_flags row; a bad scope is a 400', (t) => withDb(t, async ({ db, DB }) => {
  const name = 'lanedown-boxa-codex-20261003';
  const r = await call(DB, 'PUT', '/api/flags', { name, scope: 'boxa', active: 1, actor: 'boxa' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.flag.scope, 'boxa');
  assert.ok(hrow(db, name, 'boxa'));
  assert.equal(hrow(db, name, 'fleet'), undefined);
  assert.equal(prow(db, name), undefined, 'box scope is not mirrored');
  const del = await call(DB, 'DELETE', `/api/flags?name=${name}&scope=boxa`);
  assert.equal(del.status, 200);
  assert.equal(prow(db, name), undefined, 'box-scope clear is not mirrored either');

  for (const scope of ['a b', 'x'.repeat(65), '../etc']) {
    const bad = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', scope, active: 1 });
    assert.equal(bad.status, 400, JSON.stringify(scope));
  }
  assert.equal(hrow(db, 'paused-p'), undefined);
}));

test('W4 a non-ported name is the legacy body, harness_flags untouched', (t) => withDb(t, async ({ db, DB }) => {
  const n0 = hcount(db);
  const r = await call(DB, 'PUT', '/api/flags', { name: 'alerts-db', active: 1, actor: 'console', reason: 'r', scope: 'boxa', value: 'v' });
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body), ['flag']);
  // TEST-CHANGE (BH-5639 merge): BH-5635 gives a NON-ported pause_flags row an
  // optional `value` (the flag file's content), so the legacy body now carries
  // it. The other keys and the untouched harness_flags table are unchanged.
  assert.deepEqual(sortedKeys(r.body.flag), ['active', 'actor', 'name', 'reason', 'updated_at', 'value']);
  assert.equal(r.body.flag.value, 'v');
  assert.equal(prow(db, 'alerts-db').active, 1);
  assert.equal(hcount(db), n0);

  const del = await call(DB, 'DELETE', '/api/flags?name=alerts-db&actor=operator&reason=done');
  assert.equal(del.status, 200);
  assert.equal(prow(db, 'alerts-db').active, 0);
  assert.equal(prow(db, 'alerts-db').actor, 'operator');
  assert.equal(audits(db, 'alerts-db').length, 2);
  assert.equal(hcount(db), n0);

  const missing = await call(DB, 'DELETE', '/api/flags?name=never-set');
  assert.equal(missing.status, 404);
  assert.equal(prow(db, 'never-set'), undefined);
}));

test('W5 GET list merges both stores in the full shape and filters', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'console' });
  await call(DB, 'PUT', '/api/flags', { name: 'alerts-db', active: 1, actor: 'console' });
  await call(DB, 'PUT', '/api/flags', { name: 'lanedown-boxa-codex-20261003', scope: 'boxa', active: 1 });
  await call(DB, 'PUT', '/api/flags', { name: 'automerge-disabled', active: 0 });

  const all = await call(DB, 'GET', '/api/flags');
  assert.equal(all.status, 200);
  assert.equal(typeof all.body.as_of, 'string');
  assert.equal(all.body.truncated, undefined);
  const names = all.body.flags.map((f) => `${f.name}@${f.scope}`);
  assert.deepEqual(names, [
    'alerts-db@fleet', 'automerge-disabled@fleet', 'lanedown-boxa-codex-20261003@boxa', 'paused-p@fleet',
  ], 'ordered by name, ported names once');
  for (const f of all.body.flags) assert.deepEqual(sortedKeys(f), [...FULL_KEYS].sort(), f.name);
  const legacy = all.body.flags.find((f) => f.name === 'alerts-db');
  assert.equal(legacy.set_by, 'console');
  assert.equal(legacy.value, null);
  assert.equal(legacy.cleared_at, null);
  assert.equal(legacy.set_at, legacy.updated_at);
  const am = all.body.flags.find((f) => f.name === 'automerge-disabled');
  assert.equal(am.active, 0);
  assert.equal(am.updated_at, am.cleared_at);

  const pre = await call(DB, 'GET', '/api/flags?prefix=paused-');
  assert.deepEqual(pre.body.flags.map((f) => f.name), ['paused-p']);
  const wild = await call(DB, 'GET', '/api/flags?prefix=paused_');
  assert.deepEqual(wild.body.flags, [], '_ is a literal, not a LIKE wildcard');
  const box = await call(DB, 'GET', '/api/flags?scope=boxa');
  assert.deepEqual(box.body.flags.map((f) => f.name), ['lanedown-boxa-codex-20261003']);
  const fleet = await call(DB, 'GET', '/api/flags?scope=fleet');
  assert.deepEqual(fleet.body.flags.map((f) => f.name), ['alerts-db', 'automerge-disabled', 'paused-p']);
  const on = await call(DB, 'GET', '/api/flags?active=1');
  assert.deepEqual(on.body.flags.map((f) => f.name), ['alerts-db', 'lanedown-boxa-codex-20261003', 'paused-p']);

  for (const q of ['scope=a%20b', 'prefix=a%25', 'prefix=a%20b']) {
    const bad = await call(DB, 'GET', `/api/flags?${q}`);
    assert.equal(bad.status, 400, q);
  }
}));

test('W5b the 500 cap reports truncated', (t) => withDb(t, async ({ db, DB }) => {
  const ins = db.prepare("INSERT INTO harness_flags (scope, name, set_at) VALUES ('fleet', ?, '2026-10-03T00:00:00Z')");
  for (let i = 0; i < 300; i++) ins.run(`paused-x${String(i).padStart(3, '0')}`);
  const insp = db.prepare("INSERT INTO pause_flags (name, active, updated_at) VALUES (?, 1, '2026-10-03T00:00:00Z')");
  for (let i = 0; i < 300; i++) insp.run(`legacy-${String(i).padStart(3, '0')}`);
  const r = await call(DB, 'GET', '/api/flags');
  assert.equal(r.body.flags.length, 500);
  assert.equal(r.body.truncated, true);
  assert.equal(r.body.flags[0].name, 'legacy-000');
}));

test('W6 GET one flag: ported from harness_flags by scope, 404 when absent', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, 'GET', '/api/flags/paused-p')).status, 404);
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, value: 'v1' });
  const r = await call(DB, 'GET', '/api/flags/paused-p');
  assert.equal(r.status, 200);
  assert.equal(r.body.flag.value, 'v1');
  assert.equal(r.body.flag.scope, 'fleet');
  assert.deepEqual(sortedKeys(r.body.flag), [...FULL_KEYS].sort());
  assert.equal((await call(DB, 'GET', '/api/flags/paused-p?scope=boxa')).status, 404);

  await call(DB, 'PUT', '/api/flags', { name: 'lanedown-boxa-x-20261003', scope: 'boxa', active: 1 });
  assert.equal((await call(DB, 'GET', '/api/flags/lanedown-boxa-x-20261003')).status, 404);
  const box = await call(DB, 'GET', '/api/flags/lanedown-boxa-x-20261003?scope=boxa');
  assert.equal(box.status, 200);
  assert.equal(box.body.flag.scope, 'boxa');

  await call(DB, 'PUT', '/api/flags', { name: 'alerts-db', active: 1, actor: 'c' });
  const legacy = await call(DB, 'GET', '/api/flags/alerts-db');
  assert.equal(legacy.status, 200);
  assert.deepEqual(sortedKeys(legacy.body.flag), [...FULL_KEYS].sort());
  assert.equal(legacy.body.flag.set_by, 'c');
  assert.equal((await call(DB, 'GET', '/api/flags/paused-p?scope=a%20b')).status, 400);
}));

test('W7 checkPause refuses a claim after PUT paused-<p> and allows it after DELETE', (t) => withDb(t, async ({ DB }) => {
  const claim = (id) => call(DB, 'POST', '/api/jobs', {
    id, project: 'project-3', kind: 'build', box: 'box-project-3-2', stage: 'plan',
    ticket_id: id, lane: 'plan/project-3/claude',
  });
  await call(DB, 'PUT', '/api/flags', { name: 'paused-project-3', active: 1, actor: 'console', reason: 'hold' });
  const refused = await claim('TK-1');
  assert.equal(refused.status, 409, JSON.stringify(refused.body));
  assert.equal(refused.body.scope, 'pause');
  assert.equal(refused.body.flag, 'paused-project-3');
  await call(DB, 'DELETE', '/api/flags?name=paused-project-3&reason=go');
  const ok = await claim('TK-2');
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
}));

test('W8 expected_set_at guards the write: a mismatch is a 409 and writes nothing', (t) => withDb(t, async ({ db, DB }) => {
  const noRowBad = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, expected_set_at: '2020-01-01T00:00:00Z' });
  assert.equal(noRowBad.status, 409);
  assert.equal(noRowBad.body.error, 'flag moved');
  assert.equal(noRowBad.body.flag, null);
  assert.equal(hrow(db, 'paused-p'), undefined);
  assert.equal(prow(db, 'paused-p'), undefined);

  const noRowOk = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, expected_set_at: '' });
  assert.equal(noRowOk.status, 200);
  await call(DB, 'DELETE', '/api/flags?name=paused-p&reason=cleared');
  const h = { ...hrow(db, 'paused-p') };
  const nAudit = audits(db, 'paused-p').length;

  const stale = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, expected_set_at: '' });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.flag.name, 'paused-p');
  assert.equal(stale.body.flag.active, 0);
  const wrong = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, expected_set_at: h.set_at + 'x' });
  assert.equal(wrong.status, 409);
  assert.deepEqual({ ...hrow(db, 'paused-p') }, h, 'no write on 409');
  // TEST-CHANGE BH-4154: no pause_flags row exists at all now.
  assert.equal(prow(db, 'paused-p'), undefined, 'no mirror write on 409');
  assert.equal(audits(db, 'paused-p').length, nAudit, 'no audit on 409');

  const right = await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, expected_set_at: h.cleared_at });
  assert.equal(right.status, 200);
  assert.equal(hrow(db, 'paused-p').cleared_at, null);
}));

test('W9 the backfill is idempotent and never overwrites; schema.sql and CREATED_TABLES agree', (t) => withDb(t, async ({ db }) => {
  const stmts = CREATED_TABLES.harness_flags;
  assert.ok(Array.isArray(stmts), 'CREATED_TABLES.harness_flags exists');
  const backfill = stmts.find((s) => /^\s*INSERT OR IGNORE INTO harness_flags/.test(s));
  assert.ok(backfill, 'the backfill statement is in CREATED_TABLES');
  const flat = (s) => s.replace(/\s+/g, ' ').trim();
  const schema = flat(jobsSchemaSql()
    .split('\n').filter((l) => !/^\s*--/.test(l)).join('\n'));
  for (const s of stmts) assert.ok(schema.includes(flat(s)), `schema.sql carries: ${flat(s).slice(0, 60)}`);

  const ins = db.prepare('INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES (?,?,?,?,?)');
  ins.run('paused-a', 1, 'console', 'r', '2026-10-01T00:00:00Z');
  ins.run('automerge-disabled', 0, 'operator', null, '2026-10-02T00:00:00Z');
  ins.run('lanedown-b-x-20261001', 1, 'b', null, '2026-10-01T00:00:00Z');
  ins.run('alerts-db', 1, 'console', null, '2026-10-01T00:00:00Z');
  db.prepare("INSERT INTO harness_flags (scope, name, set_by, set_at) VALUES ('fleet','paused-a','kept','2026-10-03T00:00:00Z')").run();

  db.prepare(backfill).run();
  const n1 = hcount(db);
  assert.equal(n1, 3, 'three ported names, alerts-db not backfilled');
  assert.equal(hrow(db, 'paused-a').set_by, 'kept', 'an existing row is never overwritten');
  const am = hrow(db, 'automerge-disabled');
  assert.equal(am.cleared_at, '2026-10-02T00:00:00Z');
  assert.equal(am.set_by, 'operator');
  assert.equal(hrow(db, 'lanedown-b-x-20261001').cleared_at, null);
  assert.equal(hrow(db, 'alerts-db'), undefined);

  db.prepare(backfill).run();
  assert.equal(hcount(db), n1, 'a second run adds nothing');
}));

test('W10 FLAG_PORTED_RE is one exact line the shell copy is compared to', async () => {
  const src = readFileSync(new URL('../src/lib/harness-flags.js', import.meta.url), 'utf8');
  // TEST-CHANGE BH-6350: the pinned literal gains |dispatch-mode-.+ (the
  // per-project dispatch mode row is a ported family), and the positive list
  // gains dispatch-mode-x. A spec change to this case, not a weakening.
  assert.ok(src.split('\n').includes(
    'export const FLAG_PORTED_RE = /^(paused-.+|automerge-disabled|automerge-disabled-.+|lanedown-.+|dispatch-mode-.+)$/;',
  ));
  const { FLAG_PORTED_RE } = await import('../src/lib/harness-flags.js');
  for (const n of ['paused-x', 'automerge-disabled', 'automerge-disabled-p', 'lanedown-b-x-1', 'dispatch-mode-x']) assert.ok(FLAG_PORTED_RE.test(n), n);
  for (const n of ['paused-', 'automerge-disabledx', 'alerts-db', 'lanedown-', 'dispatch-mode-']) assert.ok(!FLAG_PORTED_RE.test(n), n);
});

test('W11 the pre-#4332 shell readers keep .flag.active and .flag.updated_at', (t) => withDb(t, async ({ DB }) => {
  const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;
  const read = async () => (await call(DB, 'GET', '/api/flags/paused-p')).body.flag;
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'box', reason: 'file' });
  const on = await read();
  assert.equal(on.active, 1);
  assert.match(on.updated_at, ISO);
  const off = (await call(DB, 'DELETE', '/api/flags?name=paused-p&actor=console')).body.flag;
  assert.equal(off.active, 0);
  assert.match(off.updated_at, ISO);
  assert.equal((await read()).active, 0);
  assert.equal((await read()).updated_at, off.cleared_at, 'a clear stamps updated_at with cleared_at');
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 0, actor: 'box' });
  assert.equal((await read()).active, 0, 'an inactive PUT on a cleared row stays off');
  await call(DB, 'PUT', '/api/flags', { name: 'paused-p', active: 1, actor: 'box' });
  const re = await read();
  assert.equal(re.active, 1);
  assert.equal(re.updated_at, re.set_at, 'a re-set stamps updated_at with set_at');
  const listed = (await call(DB, 'GET', '/api/flags')).body.flags.filter((f) => f.name === 'paused-p');
  assert.equal(listed.length, 1, 'the list carries the ported name once');
  assert.equal(listed[0].active, 1);
}));

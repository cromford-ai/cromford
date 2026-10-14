import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaFile } from './lib/jobs-schema.js';

// BH-2659 (BH-2518.1): the four box-commands routes, driven through the real
// worker.fetch against real SQLite and the real schema.sql (the #2658 contract
// block). Dedup is the box_commands_open partial index and every claim is a
// compare-and-swap judged by meta.changes, so the SQL is the behaviour. Red on
// the contract branch: every route answers 404.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T12:00:00Z');
const iso = (sAgo) => new Date(NOW_MS - sAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SCHEMA = jobsSchemaFile();
const MACHINE = 'e7843d1c4a2b98';

async function open(t, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb(hooks);
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  // project-3-1 and project-4-1 are boxes the fleet has heard from; hub deliberately is not.
  for (const b of ['project-3-1', 'project-4-1']) {
    env.db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?, ?)').run(b, iso(60));
  }
  return env;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const cmds = (db) => db.prepare('SELECT * FROM box_commands_v2 ORDER BY id').all();
const row = (db, id) => db.prepare('SELECT * FROM box_commands_v2 WHERE id=?').get(id);
const audits = (db, action) => db.prepare('SELECT * FROM hub_lease_changes WHERE action=? ORDER BY id').all(action);
function seed(db, over = {}) {
  const r = {
    box: 'project-3-1', type: 'backup_now', target: '', args: null, reason: 'seeded', status: 'requested',
    requested_by: 'console', requested_at: iso(600), claimed_by: null, claimed_at: null, ...over,
  };
  const res = db.prepare(
    'INSERT INTO box_commands_v2 (box,type,target,args,reason,status,requested_by,requested_at,claimed_by,claimed_at) VALUES (?,?,?,?,?,?,?,?,?,?)',
  ).run(r.box, r.type, r.target, r.args, r.reason, r.status, r.requested_by, r.requested_at, r.claimed_by, r.claimed_at);
  return Number(res.lastInsertRowid);
}
const req = (over = {}) => ({ box: 'project-3-1', type: 'backup_now', reason: 'nightly missed', actor: 'console', confirm: true, ...over });
const fly = (over = {}) => req({ box: 'hub', type: 'fly_machine_stop', target: MACHINE, project: 'project-3', app: 'bh-pool-project-3', ...over });

// ── POST /api/box-commands ────────────────────────────────────────────────

test('W1: an unconfirmed request is 400 confirm_required, audited once each, and writes no command', async (t) => {
  const env = await open(t); if (!env) return;
  for (const confirm of [undefined, 'true', 1, 'yes']) {
    const r = await call(env.DB, 'POST', '/api/box-commands', req({ confirm }));
    assert.equal(r.status, 400, JSON.stringify(confirm));
    assert.deepEqual(r.body, { error: 'confirm_required' });
  }
  let a = audits(env.db, 'box_command_refused');
  assert.equal(a.length, 4, 'one refused row per attempt');
  for (const x of a) {
    assert.equal(x.outcome, 'refused:confirm');
    assert.equal(x.target, 'project-3-1');
    assert.equal(x.actor, 'console');
    assert.equal(x.reason, 'nightly missed');
    assert.equal(x.at, iso(0));
  }
  // No actor is still on the record; a blank reason is still confirm_required
  // (confirm is checked first).
  const r = await call(env.DB, 'POST', '/api/box-commands', { box: 'project-3-1', type: 'backup_now', reason: '  ' });
  assert.deepEqual(r.body, { error: 'confirm_required' });
  a = audits(env.db, 'box_command_refused');
  assert.equal(a.length, 5);
  assert.equal(a.at(-1).actor, 'unknown');
  assert.equal(cmds(env.db).length, 0);
});

test('W2: reason, type, box and unknown_box are refused in order and write nothing; hub needs no box_status row', async (t) => {
  const env = await open(t); if (!env) return;
  for (const reason of ['', '   ', undefined, 7]) {
    const r = await call(env.DB, 'POST', '/api/box-commands', req({ reason, type: 'reboot' }));
    assert.equal(r.status, 400, `reason ${JSON.stringify(reason)}`);
    assert.deepEqual(r.body, { error: 'reason_required' }, 'reason is checked before type');
  }
  for (const type of ['reboot', undefined, '']) {
    const r = await call(env.DB, 'POST', '/api/box-commands', req({ type, box: 'a/b' }));
    assert.equal(r.status, 400);
    assert.match(r.body.error, /^type must be one of/, 'type is checked before box');
  }
  for (const box of ['a/b', 'x'.repeat(65), '', undefined, 5]) {
    const r = await call(env.DB, 'POST', '/api/box-commands', req({ box }));
    assert.equal(r.status, 400, `box ${JSON.stringify(box)}`);
    assert.match(r.body.error, /^box is required/);
  }
  const ghost = await call(env.DB, 'POST', '/api/box-commands', req({ box: 'ghost-9' }));
  assert.equal(ghost.status, 409);
  assert.deepEqual(ghost.body, { error: 'unknown_box' });
  assert.equal(cmds(env.db).length, 0);
  assert.equal(audits(env.db, 'box_command_refused').length, 0, 'only the confirm refusal is audited');
  const hub = await call(env.DB, 'POST', '/api/box-commands', req({ box: 'hub' }));
  assert.equal(hub.status, 201);
  assert.equal(hub.body.command.box, 'hub');
});

test('W3: Fly types need box hub, a machine id and project/app; non-Fly types take no target', async (t) => {
  const env = await open(t); if (!env) return;
  const bad = [
    fly({ box: 'project-3-1' }),
    fly({ target: 'ABC12345' }), fly({ target: 'abc1234' }), fly({ target: 'a'.repeat(33) }), fly({ target: undefined }),
    fly({ project: 'a/b' }), fly({ project: undefined }), fly({ app: '' }), fly({ app: 3 }),
    req({ target: 'x' }),
  ];
  for (const b of bad) {
    const r = await call(env.DB, 'POST', '/api/box-commands', b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(cmds(env.db).length, 0);

  const f = await call(env.DB, 'POST', '/api/box-commands', fly({ type: 'fly_machine_destroy' }));
  assert.equal(f.status, 201);
  assert.deepEqual(f.body.command.args, { project: 'project-3', app: 'bh-pool-project-3' }, 'args come back parsed');
  const stored = row(env.db, f.body.id);
  assert.equal(stored.target, MACHINE);
  assert.deepEqual(JSON.parse(stored.args), { project: 'project-3', app: 'bh-pool-project-3' });

  const b = await call(env.DB, 'POST', '/api/box-commands', req({ project: 'ignored' }));
  assert.equal(b.status, 201);
  assert.equal(b.body.command.args, null);
  const s = row(env.db, b.body.id);
  assert.equal(s.target, '');
  assert.equal(s.args, null);
});

test('W4: a first request is 201 with its audit row; the same open request is 200 deduped with the same id', async (t) => {
  const env = await open(t); if (!env) return;
  const first = await call(env.DB, 'POST', '/api/box-commands', req({ reason: '  nightly missed  ' }));
  assert.equal(first.status, 201);
  assert.equal(first.body.deduped, false);
  assert.equal(first.body.status, 'requested');
  assert.equal(first.body.id, first.body.command.id);
  const r = row(env.db, first.body.id);
  assert.equal(r.requested_by, 'console');
  assert.equal(r.requested_at, iso(0));
  assert.equal(r.reason, 'nightly missed', 'stored trimmed');

  const again = await call(env.DB, 'POST', '/api/box-commands', req({ actor: 'mcp' }));
  assert.equal(again.status, 200);
  assert.equal(again.body.deduped, true);
  assert.equal(again.body.id, first.body.id);
  assert.equal(cmds(env.db).length, 1);

  const a = audits(env.db, 'box_command_request');
  assert.equal(a.length, 2);
  for (const x of a) { assert.equal(x.reason, 'nightly missed'); assert.equal(x.outcome, 'ok'); assert.equal(x.target, 'project-3-1'); }
  assert.deepEqual(a.map((x) => x.actor), ['console', 'mcp']);

  const other = await call(env.DB, 'POST', '/api/box-commands', fly());
  const other2 = await call(env.DB, 'POST', '/api/box-commands', fly({ target: 'ffff0000' }));
  assert.equal(other.status, 201);
  assert.equal(other2.status, 201, 'a different target is a different open command');
  assert.notEqual(other.body.id, other2.body.id);
});

// ── GET /api/box-commands ─────────────────────────────────────────────────

test('W5: GET lists the last 50 newest first, says when it cut, and filters by box', async (t) => {
  const env = await open(t); if (!env) return;
  const empty = await call(env.DB, 'GET', '/api/box-commands');
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body, { commands: [], truncated: false, as_of: iso(0) });

  for (let i = 0; i < 49; i++) seed(env.db, { status: 'ok' });
  seed(env.db, { box: 'hub', status: 'ok', args: '{"project":"p","app":"a"}' });
  seed(env.db, { box: 'hub', status: 'fail', args: 'not json' });
  const all = await call(env.DB, 'GET', '/api/box-commands');
  assert.equal(all.status, 200);
  assert.equal(all.body.commands.length, 50);
  assert.equal(all.body.truncated, true);
  assert.equal(all.body.as_of, iso(0));
  const ids = all.body.commands.map((c) => c.id);
  assert.deepEqual(ids, [...ids].sort((x, y) => y - x), 'newest first');
  assert.equal(ids[0], 51);
  assert.equal(all.body.commands[0].args, 'not json', 'an unparseable args is returned raw, not a 503');
  assert.deepEqual(all.body.commands[1].args, { project: 'p', app: 'a' });

  const hub = await call(env.DB, 'GET', '/api/box-commands?box=hub');
  assert.equal(hub.status, 200);
  assert.deepEqual(hub.body.commands.map((c) => c.box), ['hub', 'hub']);
  assert.equal(hub.body.truncated, false);

  const bad = await call(env.DB, 'GET', '/api/box-commands?box=a/b');
  assert.equal(bad.status, 400);
});

// ── POST /api/box-commands/claim ──────────────────────────────────────────

test('W6: a claim only ever hands out a row for a box the claimer listed', async (t) => {
  const env = await open(t); if (!env) return;
  const project-4 = seed(env.db, { box: 'project-4-1' });
  const hub = seed(env.db, { box: 'hub', type: 'fly_machine_stop', target: MACHINE, args: '{"project":"project-3","app":"x"}' });

  let r = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'project-3-1', boxes: ['project-3-1'] });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { command: null });
  r = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'project-3-1', boxes: [' project-3-1 ', 'project-3-1', 'Hub'] });
  assert.deepEqual(r.body, { command: null }, 'box matching is exact and case-sensitive');
  assert.equal(row(env.db, project-4).status, 'requested');
  assert.equal(row(env.db, hub).status, 'requested');

  r = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'project-4-1', boxes: ['project-4-1'] });
  assert.equal(r.body.command.id, project-4);
  assert.equal(r.body.command.status, 'claimed');
  assert.equal(r.body.command.claimed_by, 'project-4-1');
  assert.equal(r.body.command.claimed_at, iso(0));
  assert.equal(row(env.db, hub).status, 'requested');

  r = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'hub', boxes: ['project-3-1', 'hub'] });
  assert.equal(r.body.command.id, hub);
  assert.deepEqual(r.body.command.args, { project: 'project-3', app: 'x' }, 'claim returns args parsed');

  for (const b of [{ claimer: 'hub', boxes: [] }, { claimer: 'hub', boxes: 'project-3-1' }, { claimer: 'hub', boxes: ['ok', 'bad/x'] },
    { claimer: 'hub', boxes: Array.from({ length: 51 }, (_, i) => `b${i}`) }, { claimer: 'hub' }, { boxes: ['hub'] },
    { claimer: 'a/b', boxes: ['hub'] }]) {
    const x = await call(env.DB, 'POST', '/api/box-commands/claim', b);
    assert.equal(x.status, 400, JSON.stringify(b).slice(0, 80));
  }
});

test('W7: TTL from settings (fallback 1800), strict cutoff, oldest first, and a lost CAS race is null', async (t) => {
  const env = await open(t); if (!env) return;
  const claim = (claimer = 'project-3-1') => call(env.DB, 'POST', '/api/box-commands/claim', { claimer, boxes: ['project-3-1'] });
  const fresh = seed(env.db, { status: 'claimed', claimed_by: 'a', claimed_at: iso(10) });
  assert.deepEqual((await claim('b')).body, { command: null }, 'a fresh claim is not re-offered');
  env.db.prepare('UPDATE box_commands_v2 SET claimed_at=? WHERE id=?').run(iso(1800), fresh);
  assert.deepEqual((await claim('b')).body, { command: null }, 'exactly at the TTL is not stale');
  env.db.prepare('UPDATE box_commands_v2 SET claimed_at=? WHERE id=?').run(iso(1801), fresh);
  let r = await claim('b');
  assert.equal(r.body.command.id, fresh);
  assert.equal(row(env.db, fresh).claimed_by, 'b');

  env.db.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('box_commands_claim_ttl_s', '60', ?)").run(iso(0));
  const s = seed(env.db, { type: 'harness_sync', status: 'claimed', claimed_by: 'a', claimed_at: iso(61) });
  r = await claim('c');
  assert.equal(r.body.command.id, s, 'the settings row wins');
  env.db.prepare("UPDATE settings SET value='abc' WHERE key='box_commands_claim_ttl_s'").run();
  const s2 = seed(env.db, { type: 'cli_update', status: 'claimed', claimed_by: 'a', claimed_at: iso(61) });
  assert.deepEqual((await claim('c')).body, { command: null }, 'an unparseable setting falls back to 1800');
  env.db.prepare('UPDATE box_commands_v2 SET claimed_at=? WHERE id=?').run(iso(1801), s2);
  assert.equal((await claim('c')).body.command.id, s2);

  // Oldest first.
  env.db.prepare('DELETE FROM box_commands_v2').run();
  const older = seed(env.db, { type: 'harness_sync' });
  seed(env.db, { type: 'cli_update' });
  assert.equal((await claim()).body.command.id, older);
});

test('W7b: a claim that loses the CAS race answers null and leaves the winner', async (t) => {
  const hooks = {};
  const env = await open(t, hooks); if (!env) return;
  const id = seed(env.db);
  hooks.beforeRun = (sql) => {
    if (/UPDATE box_commands_v2 SET status='claimed'/.test(sql)) {
      hooks.beforeRun = null;
      env.db.prepare(`UPDATE box_commands_v2 SET status='claimed', claimed_by='other', claimed_at=? WHERE id=?`).run(iso(0), id);
    }
  };
  const r = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'project-3-1', boxes: ['project-3-1'] });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { command: null });
  assert.equal(row(env.db, id).claimed_by, 'other');
});

// ── POST /api/box-commands/:id/result ─────────────────────────────────────

test('W8: result records ok/fail only for the claimer holding the row', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seed(env.db, { status: 'claimed', claimed_by: 'A', claimed_at: iso(5) });
  const res = (b, i = id) => call(env.DB, 'POST', `/api/box-commands/${i}/result`, b);
  assert.equal((await res({ claimer: 'A', ok: 'true' })).status, 400);
  assert.equal((await res({ claimer: 'A', ok: true, detail: 'x'.repeat(501) })).status, 400);
  assert.equal((await res({ claimer: 'A', ok: true, detail: 5 })).status, 400);
  assert.equal((await res({ ok: true })).status, 400);
  const b = await res({ claimer: 'B', ok: true });
  assert.equal(b.status, 409);
  assert.deepEqual(b.body, { error: 'not_claimed_by_you' });
  assert.equal(row(env.db, id).status, 'claimed');
  assert.equal(row(env.db, id).finished_at, null);

  const a = await res({ claimer: 'A', ok: true, detail: 'stopped' });
  assert.equal(a.status, 200);
  assert.equal(a.body.ok, true);
  assert.equal(a.body.command.status, 'ok');
  assert.equal(a.body.command.finished_at, iso(0));
  assert.equal(a.body.command.detail, 'stopped');
  assert.equal((await res({ claimer: 'A', ok: true })).status, 409, 'a finished row is not re-stamped');
  assert.equal((await res({ claimer: 'A', ok: true }, 9999)).status, 409);

  const f = seed(env.db, { type: 'harness_sync', status: 'claimed', claimed_by: 'A', claimed_at: iso(5) });
  const fr = await res({ claimer: 'A', ok: false }, f);
  assert.equal(fr.status, 200);
  assert.equal(row(env.db, f).status, 'fail');
  assert.equal(row(env.db, f).detail, null);

  const again = await call(env.DB, 'POST', '/api/box-commands', req());
  assert.equal(again.status, 201, 'a finished command does not block a new one');
  assert.notEqual(again.body.id, id);
});

test('W9: schema.sql applied a second time is a no-op and the open index still dedups', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec(readFileSync(SCHEMA, 'utf8'));
  const first = await call(env.DB, 'POST', '/api/box-commands', req());
  assert.equal(first.status, 201);
  const dup = await call(env.DB, 'POST', '/api/box-commands', req());
  assert.equal(dup.status, 200);
  assert.equal(dup.body.deduped, true);
  assert.equal(cmds(env.db).length, 1);
});

test('W10: with the table missing, the routes answer 503 schema not applied, never a 500', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE box_commands_v2');
  const g = await call(env.DB, 'GET', '/api/box-commands');
  assert.equal(g.status, 503);
  assert.equal(g.body.error, 'box_commands schema not applied');
  const c = await call(env.DB, 'POST', '/api/box-commands/claim', { claimer: 'hub', boxes: ['hub'] });
  assert.equal(c.status, 503);
});

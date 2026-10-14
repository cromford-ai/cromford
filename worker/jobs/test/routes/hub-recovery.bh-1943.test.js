import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';
import { SECRET, iso } from '../lib/harness.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

// BH-1943 (BH-1909.1): GET /api/hub/recovery and POST /api/hub/promote, the two
// routes #1942 left as 501 stubs.
//
// Every case goes through worker.fetch and the real route table (D2), against a
// node:sqlite D1 built from the real schema.sql, so the compare-and-swap and the
// conditional audit insert are SQL that actually runs, not a stub answering
// `changes:1` to anything. Fixture clocks are iso(msAgo) off harness.js's single
// anchor; the route reads its own server clock, a few ms later.

const MIN = 60 * 1000;

async function open(t, hooks = {}) {
  const h = await openDb(hooks);
  if (!h) t.skip('node:sqlite unavailable on this runtime');
  return h;
}

async function fetchJson(h, path, { method = 'GET', body } = {}) {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB: h.DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const getRecovery = (h) => fetchJson(h, '/api/hub/recovery');
const promote = (h, body) => fetchJson(h, '/api/hub/promote', { method: 'POST', body });

function setLease(h, holder, epoch, expiresMsAgo) {
  h.db.prepare('INSERT INTO hub_lease (id, holder, epoch, expires_at, updated_at) VALUES (1, ?, ?, ?, ?)')
    .run(holder, epoch, iso(expiresMsAgo), iso(10 * MIN));
}
function addBox(h, box, { ts = null, off = null, unc = null } = {}) {
  h.db.prepare('INSERT INTO box_status (box, backup_ts, backup_off, backup_unconfigured, backup_reported_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(box, ts, off, unc, iso(0), iso(0));
}
const leaseRow = (h) => h.db.prepare('SELECT * FROM hub_lease WHERE id=1').get() ?? null;
const auditRows = (h) => h.db.prepare('SELECT * FROM hub_lease_changes ORDER BY id').all();

// BH-2198: promote is off until hub.promote_enabled is flipped on. Every
// pre-2198 case below exercises a gate AFTER that one, so the fixtures turn it on.
function setPromote(h, value) {
  h.db.prepare("INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('hub.promote_enabled', ?, 'test', 'test', ?) "
    + 'ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(value, iso(0));
}

// bw-1 holds a lease at epoch 4 (live for 2 more minutes, or expired 2 minutes
// ago with live:false); bw-1 and bw-2 are boxes the fleet knows; promote is on.
function standard(h, { live = true } = {}) {
  setLease(h, 'bw-1', 4, live ? -2 * MIN : 2 * MIN);
  addBox(h, 'bw-1');
  addBox(h, 'bw-2');
  setPromote(h, '1');
}
const GOOD = { target: 'bw-2', expected_epoch: 4, confirm: true, actor: 'console', reason: 'drill' };

// ── GET /api/hub/recovery ─────────────────────────────────────────────────

test('R1: an empty DB answers 200 with a null lease and no rows, never a 404', async (t) => {
  const h = await open(t); if (!h) return;
  const r = await getRecovery(h);
  assert.equal(r.status, 200);
  assert.equal(r.body.lease, null);
  assert.equal(r.body.role.active, null);
  assert.equal(r.body.role.active_expired_holder, null);
  assert.deepEqual(r.body.role.standby, []);
  assert.equal(typeof r.body.role.standby_note, 'string');
  assert.ok(r.body.role.standby_note.length > 0);
  assert.deepEqual(r.body.backups, []);
  assert.deepEqual(r.body.recent_changes, []);
  assert.equal(r.body.truncated, false);
  assert.equal(typeof r.body.as_of, 'string');
});

test('R2: a live lease is readLease verbatim plus live:true, and its holder is the active role', async (t) => {
  const h = await open(t); if (!h) return;
  setLease(h, 'bw-1', 4, -2 * MIN);
  for (const b of ['bw-1', 'bw-2', 'bw-3', 'bw-4', 'bw-5']) addBox(h, b);
  const r = await getRecovery(h);
  assert.equal(r.status, 200);
  const l = r.body.lease;
  assert.equal(l.holder, 'bw-1');
  assert.equal(l.epoch, 4);
  assert.equal(l.expired, false);
  assert.equal(l.live, true);
  assert.equal(typeof l.remaining_s, 'number');
  assert.ok(l.remaining_s > 0);
  assert.equal(l.expires_at, iso(-2 * MIN));
  assert.equal(r.body.role.active, 'bw-1');
  assert.equal(r.body.role.active_expired_holder, null);
  assert.deepEqual(r.body.role.standby, [], 'standby is never inferred from box_status');
});

test('R3: an expired lease is not active; its holder is named as the expired holder', async (t) => {
  const h = await open(t); if (!h) return;
  setLease(h, 'bw-1', 4, 5 * MIN);
  const r = await getRecovery(h);
  assert.equal(r.status, 200);
  assert.equal(r.body.lease.expired, true);
  assert.equal(r.body.lease.live, false);
  assert.equal(r.body.role.active, null);
  assert.equal(r.body.role.active_expired_holder, 'bw-1');
});

test('R4: backup state per box mirrors bf_state_age, and absent age is null, never 0', async (t) => {
  const h = await open(t); if (!h) return;
  addBox(h, 'a-off', { ts: iso(10 * MIN), off: 'off' });
  addBox(h, 'b-ok', { ts: iso(10 * MIN) });
  addBox(h, 'c-stale', { ts: iso(45 * MIN) });
  addBox(h, 'd-garbage', { ts: 'garbage' });
  addBox(h, 'e-unconf', { ts: '', unc: 'unconfigured' });
  addBox(h, 'f-missing');
  addBox(h, 'g-future', { ts: iso(-5 * MIN) });
  const r = await getRecovery(h);
  assert.equal(r.status, 200);
  assert.equal(r.body.stale_min, 30);
  assert.equal(r.body.stale_min_source, 'fallback');
  const by = Object.fromEntries(r.body.backups.map((b) => [b.box, b]));
  assert.deepEqual(r.body.backups.map((b) => b.box),
    ['a-off', 'b-ok', 'c-stale', 'd-garbage', 'e-unconf', 'f-missing', 'g-future']);
  const want = {
    'a-off': ['off', null], 'b-ok': ['ok', 10], 'c-stale': ['stale', 45],
    'd-garbage': ['unknown', null], 'e-unconf': ['unconfigured', null],
    'f-missing': ['missing', null], 'g-future': ['ok', 0],
  };
  for (const [box, [state, age]] of Object.entries(want)) {
    assert.equal(by[box].state, state, `${box} state`);
    assert.strictEqual(by[box].age_min, age, `${box} age_min`);
  }
  assert.equal(by['a-off'].backup_off, 'off');
  assert.equal(by['d-garbage'].backup_ts, 'garbage');
  assert.equal(by['e-unconf'].backup_unconfigured, 'unconfigured');
  assert.equal(typeof by['b-ok'].backup_reported_at, 'string');
});

test('R5: backup_stale_min comes from settings when it is all digits, else the fallback', async (t) => {
  const h = await open(t); if (!h) return;
  addBox(h, 'c-stale', { ts: iso(45 * MIN) });
  const setKnob = (v) => h.db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES ('backup_stale_min', ?, ?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(v, iso(0));

  setKnob('60');
  let r = await getRecovery(h);
  assert.equal(r.body.stale_min, 60);
  assert.equal(r.body.stale_min_source, 'setting');
  assert.equal(r.body.backups[0].state, 'ok');
  assert.equal(r.body.backups[0].age_min, 45);

  for (const bad of ['abc', '-5', '4.0', '']) {
    setKnob(bad);
    r = await getRecovery(h);
    assert.equal(r.body.stale_min, 30, `knob ${JSON.stringify(bad)}`);
    assert.equal(r.body.stale_min_source, 'fallback', `knob ${JSON.stringify(bad)}`);
    assert.equal(r.body.backups[0].state, 'stale', `knob ${JSON.stringify(bad)}`);
  }
});

test('R6: an unapplied hub_lease_changes answers 503 schema not applied, not 404 or 200', async (t) => {
  const h = await open(t); if (!h) return;
  h.db.exec('DROP TABLE hub_lease_changes');
  const r = await getRecovery(h);
  assert.equal(r.status, 503);
  assert.equal(r.body.error, 'hub_lease schema not applied');
});

test('R7: recent_changes is the last 20, newest first, with truncated only past 20', async (t) => {
  const h = await open(t); if (!h) return;
  const add = () => h.db.prepare(`INSERT INTO hub_lease_changes (action, actor, outcome, at) VALUES ('promote','console','ok',?)`).run(iso(0));
  for (let i = 0; i < 20; i++) add();
  let r = await getRecovery(h);
  assert.equal(r.body.recent_changes.length, 20);
  assert.equal(r.body.truncated, false);
  for (let i = 0; i < 5; i++) add();
  r = await getRecovery(h);
  assert.equal(r.body.recent_changes.length, 20);
  assert.equal(r.body.truncated, true);
  assert.deepEqual(r.body.recent_changes.map((c) => c.id), Array.from({ length: 20 }, (_, i) => 25 - i));
  assert.equal(r.body.recent_changes[0].action, 'promote');
});

test('R8: a box_status without the backup_* columns is migrated first and reads missing', async (t) => {
  const h = await open(t); if (!h) return;
  h.db.exec('DROP TABLE box_status');
  h.db.exec('CREATE TABLE box_status (box TEXT PRIMARY KEY, updated_at TEXT)');
  h.db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?, ?)').run('bw-1', iso(0));
  const r = await getRecovery(h);
  assert.equal(r.status, 200);
  assert.equal(r.body.backups.length, 1);
  assert.equal(r.body.backups[0].state, 'missing');
  assert.strictEqual(r.body.backups[0].age_min, null);
});

// ── POST /api/hub/promote ─────────────────────────────────────────────────

test('actor is required, and that one refusal writes nothing (actor is NOT NULL)', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const before = leaseRow(h);
  for (const actor of [undefined, '', '   ']) {
    const r = await promote(h, { ...GOOD, actor });
    assert.equal(r.status, 400);
    assert.equal(r.body.error, 'actor_required');
  }
  assert.deepEqual(leaseRow(h), before);
  assert.equal(auditRows(h).length, 0);
});

test('P1: confirm is checked before the target', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const r = await promote(h, { ...GOOD, confirm: false, target: 'box-99' });
  assert.equal(r.status, 400);
  assert.equal(r.body.error, 'confirm_required');
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].outcome, 'refused:confirm');
});

test('P2: the target is checked before the epoch', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const r = await promote(h, { ...GOOD, target: 'box-99', expected_epoch: '4.0' });
  assert.equal(r.status, 400);
  assert.equal(r.body.error, 'unknown_box');
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].outcome, 'refused:unknown_box');
  assert.equal(rows[0].target, 'box-99');
});

test('P3: every adversarial input is refused with one audit row and no lease write', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const cases = [
    [{ confirm: undefined }, 400, 'confirm_required', 'refused:confirm'],
    [{ confirm: 'true' }, 400, 'confirm_required', 'refused:confirm'],
    [{ confirm: 1 }, 400, 'confirm_required', 'refused:confirm'],
    [{ confirm: 'yes' }, 400, 'confirm_required', 'refused:confirm'],
    [{ target: '' }, 400, 'unknown_box', 'refused:unknown_box'],
    [{ target: 'box-hub; rm' }, 400, 'unknown_box', 'refused:unknown_box'],
    [{ target: 'box-99' }, 400, 'unknown_box', 'refused:unknown_box'],
    // BH-2272: the name bin/hub-lease.sh used to send for `promote --holder X`.
    [{ target: '--holder' }, 400, 'unknown_box', 'refused:unknown_box'],
    [{ expected_epoch: '4.0' }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: '4' }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: 4.5 }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: -1 }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: null }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: true }, 400, 'expected_epoch_invalid', 'refused:expected_epoch'],
    [{ expected_epoch: 3 }, 409, 'stale_epoch', 'refused:stale_epoch'],
  ];
  const before = leaseRow(h);
  for (const [over, status, error, outcome] of cases) {
    const n = auditRows(h).length;
    const r = await promote(h, { ...GOOD, ...over });
    const label = JSON.stringify(over);
    assert.equal(r.status, status, label);
    assert.equal(r.body.error, error, label);
    const rows = auditRows(h);
    assert.equal(rows.length, n + 1, `${label}: exactly one audit row`);
    const row = rows[rows.length - 1];
    assert.equal(row.action, 'promote_refused', label);
    assert.equal(row.outcome, outcome, label);
    assert.equal(row.actor, 'console', label);
    assert.equal(row.reason, 'drill', label);
    assert.deepEqual(leaseRow(h), before, `${label}: lease untouched`);
  }
});

test('P4: an empty lease table is 409 no_lease with one refusal row', async (t) => {
  const h = await open(t); if (!h) return;
  addBox(h, 'bw-2');
  setPromote(h, '1');
  const r = await promote(h, GOOD);
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'no_lease');
  assert.equal(r.body.lease, null);
  assert.equal(leaseRow(h), null);
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].outcome, 'refused:no_lease');
});

test('P5: a stale expected_epoch is 409 with the live lease and one refusal row', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const r = await promote(h, { ...GOOD, expected_epoch: 3 });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'stale_epoch');
  assert.equal(r.body.lease.epoch, 4);
  assert.equal(r.body.lease.holder, 'bw-1');
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].before_holder, 'bw-1');
  assert.equal(rows[0].before_epoch, 4);
});

function spyBatch(h) {
  const seen = [];
  const orig = h.DB.batch.bind(h.DB);
  h.DB.batch = (stmts) => { seen.push(stmts.length); return orig(stmts); };
  return seen;
}

// BH-2198: a promote over a LIVE lease is refused unless overridden, so the
// success path runs the case the route exists for: the old holder's lease lapsed.
async function assertPromoted(t, body) {
  const h = await open(t); if (!h) return null;
  standard(h, { live: false });
  const seen = spyBatch(h);
  const r = await promote(h, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.promoted, true);
  assert.deepEqual(r.body.before, { holder: 'bw-1', epoch: 4 });
  assert.deepEqual(r.body.after, { holder: 'bw-2', epoch: 5 });
  assert.equal(r.body.lease.holder, 'bw-2');
  assert.equal(r.body.lease.epoch, 5);
  assert.equal(r.body.lease.live, true);
  assert.equal(typeof r.body.as_of, 'string');
  assert.deepEqual(seen, [2], 'one batch of two statements');
  const row = leaseRow(h);
  assert.equal(row.holder, 'bw-2');
  assert.equal(row.epoch, 5);
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, r.body.audit_id);
  assert.equal(rows[0].action, 'promote');
  assert.equal(rows[0].outcome, 'ok');
  assert.equal(rows[0].before_holder, 'bw-1');
  assert.equal(rows[0].before_epoch, 4);
  assert.equal(rows[0].after_holder, 'bw-2');
  assert.equal(rows[0].after_epoch, 5);
  assert.equal(rows[0].target, 'bw-2');
  assert.equal(rows[0].actor, 'console');
  assert.equal(rows[0].reason, 'drill');
  assert.equal(rows[0].at, r.body.as_of);
  return h;
}

test('P6: a confirmed promote bumps the epoch and writes its audit row in one batch', async (t) => {
  await assertPromoted(t, GOOD);
});

test('P7: a lost race (epoch moved between read and batch) is 409, never 200, never an ok row', async (t) => {
  const hooks = {};
  const h = await open(t, hooks); if (!h) return;
  standard(h, { live: false });
  let bumped = false;
  hooks.beforeRun = (sql) => {
    if (!bumped && /^UPDATE hub_lease SET holder/.test(sql)) {
      bumped = true;
      h.db.prepare('UPDATE hub_lease SET epoch=epoch+1 WHERE id=1').run();
    }
  };
  const r = await promote(h, GOOD);
  assert.ok(bumped, 'the race hook fired');
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'stale_epoch');
  assert.equal(r.body.lease.epoch, 5);
  assert.equal(r.body.lease.holder, 'bw-1');
  const rows = auditRows(h);
  assert.equal(rows.filter((x) => x.outcome === 'ok').length, 0);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].action, 'promote_refused');
  assert.equal(rows[0].outcome, 'refused:stale_epoch');
  assert.equal(leaseRow(h).holder, 'bw-1');
});

test('P8: the issue spelling {holder, expect_epoch} promotes the same as the contract spelling', async (t) => {
  const { target, expected_epoch, ...rest } = GOOD;
  await assertPromoted(t, { ...rest, holder: target, expect_epoch: expected_epoch });
});

// BH-2272 changed this pin: the legacy route used to promote with no confirm;
// it is retired, so the only way to move the hub is the guarded route above.
test('P9: the legacy /api/hub/lease/promote is 410 gone and moves nothing', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const before = leaseRow(h);
  for (const path of ['/api/hub/lease/promote', '/api/hub-lease/promote']) {
    const r = await fetchJson(h, path, { method: 'POST', body: { holder: 'bw-2' } });
    assert.equal(r.status, 410, path);
    assert.equal(r.body.error, 'gone', path);
    assert.equal(r.body.use, '/api/hub/promote', path);
  }
  assert.deepEqual(leaseRow(h), before);
  assert.equal(auditRows(h).length, 0);
});

test('T8: after a promote the old holder is fenced and the new one renews on the new epoch', async (t) => {
  const h = await assertPromoted(t, GOOD);
  if (!h) return;
  const renew = (body) => fetchJson(h, '/api/hub/lease/renew', { method: 'POST', body });
  let r = await renew({ holder: 'bw-1', epoch: 4 });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'lease held');
  r = await renew({ holder: 'bw-2', epoch: 5 });
  assert.equal(r.status, 200);
  assert.equal(r.body.renewed, true);
});

// ── BH-2198: the split-brain guard ────────────────────────────────────────
// #2158 shipped the promote without it. Three rules: a default-OFF setting
// gates the route first; a live lease is refused with NO write unless the body
// says override_live_lease:true, which is audited as its own outcome; a stale
// epoch is still the audited 409 it always was.

const settingRows = (h) => h.db.prepare("SELECT * FROM settings WHERE key='hub.promote_enabled'").all();

test('G1: hub.promote_enabled is seeded OFF, and off (or missing) is 403 with one audit row', async (t) => {
  const h = await open(t); if (!h) return;
  const seeded = settingRows(h);
  assert.equal(seeded.length, 1, 'schema.sql seeds the row');
  assert.equal(seeded[0].value, '0', 'default OFF');
  setLease(h, 'bw-1', 4, 2 * MIN);
  addBox(h, 'bw-2');
  const before = leaseRow(h);
  const cases = ['seed', 'missing', 'false', '', 'yes'];
  for (const c of cases) {
    if (c === 'missing') h.db.prepare("DELETE FROM settings WHERE key='hub.promote_enabled'").run();
    else if (c !== 'seed') setPromote(h, c);
    const n = auditRows(h).length;
    const r = await promote(h, GOOD);
    assert.equal(r.status, 403, c);
    assert.equal(r.body.error, 'promote-disabled', c);
    const rows = auditRows(h);
    assert.equal(rows.length, n + 1, `${c}: exactly one audit row`);
    assert.equal(rows[rows.length - 1].action, 'promote_refused', c);
    assert.equal(rows[rows.length - 1].outcome, 'refused:promote-disabled', c);
    assert.equal(rows[rows.length - 1].actor, 'console', c);
    assert.deepEqual(leaseRow(h), before, `${c}: lease untouched`);
  }
  for (const on of ['1', 'true']) {
    setPromote(h, on);
    const r = await promote(h, GOOD);
    assert.equal(r.status, 200, `${on} is on: ${JSON.stringify(r.body)}`);
    h.db.prepare("UPDATE hub_lease SET holder='bw-1', epoch=4, expires_at=? WHERE id=1").run(iso(2 * MIN));
  }
});

test('G2: the setting is checked before confirm and before the target', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  setPromote(h, '0');
  const r = await promote(h, { ...GOOD, confirm: false, target: 'box-99', expected_epoch: 'x' });
  assert.equal(r.status, 403);
  assert.equal(r.body.error, 'promote-disabled');
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].outcome, 'refused:promote-disabled');
});

test('G3: the actor is still required with the setting off, and that refusal writes nothing', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  setPromote(h, '0');
  for (const actor of [undefined, '', '   ']) {
    const r = await promote(h, { ...GOOD, actor });
    assert.equal(r.status, 400);
    assert.equal(r.body.error, 'actor_required');
  }
  assert.equal(auditRows(h).length, 0);
});

test('G4: a live lease is 409 lease_live and writes nothing; only the literal true overrides', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const seen = spyBatch(h);
  const before = leaseRow(h);
  for (const override_live_lease of [undefined, false, 'true', 1, 'yes']) {
    const r = await promote(h, { ...GOOD, override_live_lease });
    const label = JSON.stringify({ override_live_lease });
    assert.equal(r.status, 409, label);
    assert.equal(r.body.error, 'lease_live', label);
    assert.equal(r.body.lease.holder, 'bw-1', label);
    assert.equal(r.body.lease.live, true, label);
    assert.equal(typeof r.body.hint, 'string', label);
  }
  assert.deepEqual(leaseRow(h), before, 'lease untouched');
  assert.equal(auditRows(h).length, 0, 'no audit row');
  assert.deepEqual(seen, [], 'no batch issued');
});

test('G5: override_live_lease:true promotes over a live lease, audited as its own outcome, and says stop the old hub', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h);
  const r = await promote(h, { ...GOOD, override_live_lease: true });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.override_live_lease, true);
  assert.deepEqual(r.body.before, { holder: 'bw-1', epoch: 4 });
  assert.deepEqual(r.body.after, { holder: 'bw-2', epoch: 5 });
  assert.match(r.body.stop_old_hub, /stop the old hub now/i);
  assert.match(r.body.stop_old_hub, /bw-1/);
  const row = leaseRow(h);
  assert.equal(row.holder, 'bw-2');
  assert.equal(row.epoch, 5);
  const rows = auditRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, r.body.audit_id);
  assert.equal(rows[0].action, 'promote');
  assert.equal(rows[0].outcome, 'ok:override_live_lease');
  assert.equal(rows[0].before_holder, 'bw-1');
  assert.equal(rows[0].after_holder, 'bw-2');
  assert.equal(rows[0].actor, 'console');
});

test('G6: a stale epoch is still the audited 409, with the override and on an expired lease', async (t) => {
  for (const [live, extra] of [[true, { override_live_lease: true }], [false, {}]]) {
    const h = await open(t); if (!h) return;
    standard(h, { live });
    const before = leaseRow(h);
    const r = await promote(h, { ...GOOD, ...extra, expected_epoch: 3 });
    const label = `live=${live}`;
    assert.equal(r.status, 409, label);
    assert.equal(r.body.error, 'stale_epoch', label);
    const rows = auditRows(h);
    assert.equal(rows.length, 1, label);
    assert.equal(rows[0].outcome, 'refused:stale_epoch', label);
    assert.deepEqual(leaseRow(h), before, label);
  }
});

test('G7: an expired lease promotes without the override; outcome ok, and the body still says stop the old hub', async (t) => {
  const h = await assertPromoted(t, GOOD);
  if (!h) return;
  const rows = auditRows(h);
  assert.equal(rows[0].outcome, 'ok');
  const r = await getRecovery(h);
  assert.equal(r.body.recent_changes[0].outcome, 'ok');
});

test('G7b: the success body names the old holder in stop_old_hub', async (t) => {
  const h = await open(t); if (!h) return;
  standard(h, { live: false });
  const r = await promote(h, GOOD);
  assert.equal(r.status, 200);
  assert.equal(r.body.override_live_lease, false);
  assert.match(r.body.stop_old_hub, /bw-1/);
});

test('G8: the old holder renewing between the read and the batch is 409 lease_live, never a promote', async (t) => {
  const hooks = {};
  const h = await open(t, hooks); if (!h) return;
  standard(h, { live: false });
  let renewed = false;
  hooks.beforeRun = (sql) => {
    if (!renewed && /^UPDATE hub_lease SET holder/.test(sql)) {
      renewed = true;
      h.db.prepare('UPDATE hub_lease SET expires_at=? WHERE id=1').run(iso(-5 * MIN));
    }
  };
  const r = await promote(h, GOOD);
  assert.ok(renewed, 'the race hook fired');
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'lease_live');
  const row = leaseRow(h);
  assert.equal(row.holder, 'bw-1');
  assert.equal(row.epoch, 4);
  assert.equal(auditRows(h).length, 0, 'no ok row, no refusal row');
});

test('G9: re-applying schema.sql keeps one hub.promote_enabled row and an operator flip', async (t) => {
  const h = await open(t); if (!h) return;
  setPromote(h, '1');
  const { readFileSync } = await import('node:fs');
  h.db.exec(jobsSchemaSql());
  const rows = settingRows(h);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].value, '1');
});

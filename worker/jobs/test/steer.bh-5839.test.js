// BH-5839 (Mission Control step-in): the steer notes behind the ticket page's
// "Step in" composer. One row per message, driven through the REAL router
// against a real schema.sql database (the node:sqlite shim):
//   - "now" reaches a RUNNING build job only, and is read once at a step boundary
//   - "ticket" and "hold" wait in the hub's outbox until it reports delivery
//   - every send and every read is a stage event on the job (the event log)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').trim();
const T0 = '2026-10-09T20:00:00Z';

const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const job = (db, id, over = {}) => {
  const r = { project: 'cromford', ticket_id: 'BH-4991', kind: 'build', box: 'pool-1', stage: 'execute', status: 'running', ...over };
  db.prepare('INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)')
    .run(id, r.project, r.ticket_id, r.kind, r.box, r.stage, r.status, T0, T0);
};
const send = (DB, body) => call(DB, '/api/steer', { method: 'POST', body: { project: 'cromford', ticket: 'BH-4991', actor: 'operator@example.com', ...body } });
const claim = (DB, id) => call(DB, `/api/steer/${id}/claim`, { method: 'POST', body: {} });
const events = (db, id) => db.prepare('SELECT stage, verdict, actor, detail FROM stage_events WHERE job_id=? ORDER BY id').all(id);

test('BH-5839 steer notes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 belt DDL == schema.sql, and a POST self-creates the table', async () => {
    const stmts = CREATED_TABLES.steer_notes;
    assert.ok(Array.isArray(stmts) && stmts.length >= 2, 'table + indexes');
    const m = SCHEMA.match(/CREATE TABLE IF NOT EXISTS steer_notes \([\s\S]*?\n\);/);
    assert.ok(m, 'schema.sql carries the steer_notes CREATE');
    assert.equal(norm(stmts[0]), norm(m[0].replace(/;$/, '')));
    for (const s of stmts.slice(1)) assert.ok(SCHEMA.includes(`${s};`), `schema.sql carries: ${s}`);
    const { db, DB } = await openDb();
    db.exec('DROP TABLE IF EXISTS steer_notes');
    const res = await send(DB, { mode: 'ticket', text: 'Use the setup helper.' });
    assert.equal(res.status, 201, JSON.stringify(res.body));
    assert.equal(db.prepare('SELECT count(*) AS n FROM steer_notes').get().n, 1);
  });

  await t.test('S2 "now" needs a running build job of the same ticket', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run'); job(db, 'b-done', { status: 'done' }); job(db, 't-run', { kind: 'triage' });
    job(db, 'b-other', { ticket_id: 'BH-1' });
    assert.equal((await send(DB, { mode: 'now', text: 'x' })).status, 400, 'no job_id');
    assert.equal((await send(DB, { mode: 'now', text: 'x', job_id: 'nope' })).status, 404);
    for (const id of ['b-done', 't-run', 'b-other']) {
      const r = await send(DB, { mode: 'now', text: 'x', job_id: id });
      assert.equal(r.status, 409, `${id}: ${JSON.stringify(r.body)}`);
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM steer_notes').get().n, 0, 'a refused note writes nothing');
    const ok = await send(DB, { mode: 'now', text: '  Check the 375px layout first.  ', job_id: 'b-run' });
    assert.equal(ok.status, 201, JSON.stringify(ok.body));
    assert.equal(ok.body.note.text, 'Check the 375px layout first.');
    assert.equal(ok.body.note.status, 'pending');
    assert.deepEqual(events(db, 'b-run').map((e) => [e.stage, e.verdict, e.actor]), [['steer', 'SENT', 'operator@example.com']]);
  });

  await t.test('S3 input is refused, never coerced', async () => {
    const { DB } = await openDb();
    for (const [body, why] of [
      [{ mode: 'shout', text: 'x' }, 'mode'], [{ mode: 'ticket', text: '   ' }, 'blank text'],
      [{ mode: 'ticket', text: 'x'.repeat(4001) }, 'long text'], [{ mode: 'hold', text: 'x'.repeat(501) }, 'a hold note is the hold reason, cut at 500 by thc_run'], [{ mode: 'ticket', text: 'x', ticket: 'BH-0' }, 'ticket'],
      [{ mode: 'ticket', text: 'x', project: 'bad project' }, 'project'], [{ mode: 'ticket', text: 'x', actor: '' }, 'actor'],
    ]) assert.equal((await send(DB, body)).status, 400, why);
  });

  // TEST-CHANGE (BH-5839 review): take now claims (status taken) and the
  // call's exit settles; the old S4 asserted read straight from take.
  await t.test('S4 take claims each "now" note once; settle read:true makes it read, and the read is an event', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run');
    await send(DB, { mode: 'now', text: 'first', job_id: 'b-run' });
    await send(DB, { mode: 'now', text: 'second', job_id: 'b-run' });
    await send(DB, { mode: 'ticket', text: 'for the thread', job_id: 'b-run' });
    const a = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.deepEqual(a.body.notes.map((n) => n.text), ['first', 'second']);
    assert.deepEqual(a.body.notes.map((n) => n.status), ['taken', 'taken']);
    assert.equal(a.body.hold, null);
    const b = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.deepEqual(b.body.notes, [], 'a note is taken once');
    assert.equal(events(db, 'b-run').filter((e) => e.verdict === 'READ').length, 0, 'a take is not a read');
    const ids = a.body.notes.map((n) => n.id);
    const st = await call(DB, '/api/steer/settle', { method: 'POST', body: { job_id: 'b-run', ids, read: true } });
    assert.equal(st.status, 200, JSON.stringify(st.body));
    const rows = db.prepare("SELECT status, build_read_at FROM steer_notes WHERE mode='now'").all();
    assert.ok(rows.every((r) => r.status === 'read' && r.build_read_at), JSON.stringify(rows));
    assert.deepEqual(events(db, 'b-run').filter((e) => e.verdict === 'READ').length, 2);
    const again = await call(DB, '/api/steer/settle', { method: 'POST', body: { job_id: 'b-run', ids, read: false } });
    assert.deepEqual(again.body.notes, [], 'a read note is not given back');
    const list = await call(DB, '/api/steer?project=cromford&ticket=BH-4991');
    assert.deepEqual(list.body.notes.map((n) => [n.mode, n.status]), [['ticket', 'pending'], ['now', 'read'], ['now', 'read']]);
  });

  await t.test('S4b settle read:false gives taken notes back as pending; only this job\'s taken notes move; bad input is 400', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run'); job(db, 'b-two');
    const n1 = (await send(DB, { mode: 'now', text: 'one', job_id: 'b-run' })).body.note;
    const n2 = (await send(DB, { mode: 'now', text: 'two', job_id: 'b-two' })).body.note;
    await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-two' } });
    const r = await call(DB, '/api/steer/settle', { method: 'POST', body: { job_id: 'b-run', ids: [n1.id, n2.id], read: false } });
    assert.deepEqual(r.body.notes.map((n) => [n.id, n.status]), [[n1.id, 'pending']], 'the other job\'s note does not move');
    assert.equal(db.prepare('SELECT status FROM steer_notes WHERE id=?').get(n2.id).status, 'taken');
    assert.equal(db.prepare('SELECT build_read_at FROM steer_notes WHERE id=?').get(n1.id).build_read_at, null);
    assert.equal(events(db, 'b-run').filter((e) => e.verdict === 'READ').length, 0, 'a give-back is not a read');
    const t2 = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.deepEqual(t2.body.notes.map((n) => n.id), [n1.id], 'the next step boundary takes it again');
    for (const body of [{ ids: [n1.id], read: true }, { job_id: 'b-run', ids: [], read: true },
      { job_id: 'b-run', ids: ['1'], read: true }, { job_id: 'b-run', ids: [n1.id] }, { job_id: 'b-run', ids: [n1.id], read: 'yes' }]) {
      assert.equal((await call(DB, '/api/steer/settle', { method: 'POST', body })).status, 400, JSON.stringify(body));
    }
  });

  await t.test('S4c a taken note whose box never settled is taken again after steer.take_lease_s', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run');
    const n = (await send(DB, { mode: 'now', text: 'lost box', job_id: 'b-run' })).body.note;
    await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    const fresh = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.deepEqual(fresh.body.notes, [], 'inside the lease it stays with the taker');
    db.prepare("UPDATE steer_notes SET updated_at='2026-01-01T00:00:00Z' WHERE id=?").run(n.id);
    const stale = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.deepEqual(stale.body.notes.map((x) => x.id), [n.id], 'past the lease it is taken again');
  });

  await t.test('S4d a hold and a "now" note in one take: the hold only, and the "now" note stays pending', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run');
    const now = (await send(DB, { mode: 'now', text: 'use the helper', job_id: 'b-run' })).body.note;
    await send(DB, { mode: 'hold', text: 'wait', job_id: 'b-run' });
    const a = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.equal(a.body.hold && a.body.hold.text, 'wait');
    assert.deepEqual(a.body.notes, [], 'a call that refuses on a hold takes no note');
    const row = db.prepare('SELECT status, build_read_at FROM steer_notes WHERE id=?').get(now.id);
    assert.deepEqual({ ...row }, { status: 'pending', build_read_at: null });
    assert.equal(events(db, 'b-run').filter((e) => e.verdict === 'READ').length, 0);
  });

  await t.test('S5 a hold note stops the job it was sent to, once', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run'); job(db, 'b-next');
    const h = await send(DB, { mode: 'hold', text: 'Wait for the schema answer.', job_id: 'b-run' });
    assert.equal(h.status, 201);
    // b-next asks FIRST, while the hold is still untaken: a hold sent to b-run
    // must not stop another job of the same ticket.
    const c = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-next' } });
    assert.equal(c.body.hold, null, 'another build of the ticket is not stopped by this note; the hold label does that');
    const a = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.equal(a.body.hold && a.body.hold.text, 'Wait for the schema answer.');
    const b = await call(DB, '/api/steer/take', { method: 'POST', body: { job_id: 'b-run' } });
    assert.equal(b.body.hold, null, 'the stop is taken once');
    assert.ok(events(db, 'b-run').some((e) => e.stage === 'steer' && e.verdict === 'HOLD'));
    const n = db.prepare("SELECT status FROM steer_notes WHERE mode='hold'").get();
    assert.equal(n.status, 'pending', 'the build reading it does not deliver the comment and label');
  });

  await t.test('S6 the outbox: ticket and hold notes until delivered; 3 failures is terminal', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run');
    await send(DB, { mode: 'now', text: 'not for the hub', job_id: 'b-run' });
    const tk = (await send(DB, { mode: 'ticket', text: 'comment me' })).body.note;
    const hd = (await send(DB, { mode: 'hold', text: 'hold me' })).body.note;
    let box = await call(DB, '/api/steer/outbox');
    assert.deepEqual(box.body.notes.map((n) => n.id), [tk.id, hd.id]);
    // TEST-CHANGE (BH-5839 review): a report needs the hub's claim first.
    const unclaimed = await call(DB, `/api/steer/${tk.id}/delivered`, { method: 'POST', body: { ok: true } });
    assert.equal(unclaimed.status, 409, 'an unclaimed note cannot be reported');
    assert.equal((await claim(DB, tk.id)).status, 200);
    const ok = await call(DB, `/api/steer/${tk.id}/delivered`, { method: 'POST', body: { ok: true, detail: 'comment 123' } });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ok.body.note.status, 'delivered');
    for (let i = 1; i <= 3; i++) {
      assert.equal((await claim(DB, hd.id)).status, 200, `claim ${i}`);
      const f = await call(DB, `/api/steer/${hd.id}/delivered`, { method: 'POST', body: { ok: false, detail: `gh 502 #${i}` } });
      assert.equal(f.body.note.status, i < 3 ? 'pending' : 'failed', `attempt ${i}`);
    }
    box = await call(DB, '/api/steer/outbox');
    assert.deepEqual(box.body.notes, [], 'delivered and failed notes leave the outbox');
    const again = await call(DB, `/api/steer/${tk.id}/delivered`, { method: 'POST', body: { ok: false } });
    assert.equal(again.status, 409, 'a finished note is not reopened');
    assert.equal(db.prepare('SELECT detail FROM steer_notes WHERE id=?').get(hd.id).detail, 'gh 502 #3');
  });

  await t.test('S7 the attempt cap is the settings row steer.attempts_max; a bad value falls back to 3', async () => {
    for (const [value, failsAt] of [['2', 2], ['x', 3], ['0', 3], ['11', 3]]) {
      const { db, DB } = await openDb();
      db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('steer.attempts_max', ?, 't', 't', ?)").run(value, T0);
      const n = (await send(DB, { mode: 'ticket', text: 'comment me' })).body.note;
      const seen = [];
      for (let i = 1; i <= 3; i++) {
        await claim(DB, n.id);
        const f = await call(DB, `/api/steer/${n.id}/delivered`, { method: 'POST', body: { ok: false, detail: `gh 502 #${i}` } });
        seen.push(f.body.note.status);
        if (f.body.note.status === 'failed') break;
      }
      assert.equal(seen.length, failsAt, `steer.attempts_max='${value}': ${JSON.stringify(seen)}`);
      assert.equal(seen[seen.length - 1], 'failed', `steer.attempts_max='${value}'`);
    }
  });

  await t.test('S8 the outbox page size is the settings row steer.outbox_limit; ?limit= wins', async () => {
    const { db, DB } = await openDb();
    db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('steer.outbox_limit', '1', 't', 't', ?)").run(T0);
    const a = (await send(DB, { mode: 'ticket', text: 'one' })).body.note;
    await send(DB, { mode: 'ticket', text: 'two' });
    const box = await call(DB, '/api/steer/outbox');
    assert.deepEqual(box.body.notes.map((n) => n.id), [a.id], 'the row bounds the page');
    const two = await call(DB, '/api/steer/outbox?limit=2');
    assert.equal(two.body.notes.length, 2, 'an explicit ?limit= wins');
    db.prepare("UPDATE settings SET value='x' WHERE key='steer.outbox_limit'").run();
    const fb = await call(DB, '/api/steer/outbox');
    assert.equal(fb.body.notes.length, 2, 'a bad row falls back to 10');
  });

  await t.test('S9 claim: one box of two gets a note; a claimed note leaves the outbox until steer.deliver_lease_s', async () => {
    const { db, DB } = await openDb();
    job(db, 'b-run');
    const now = (await send(DB, { mode: 'now', text: 'not for the hub', job_id: 'b-run' })).body.note;
    const tk = (await send(DB, { mode: 'ticket', text: 'comment me' })).body.note;
    const [a, b] = [await claim(DB, tk.id), await claim(DB, tk.id)];
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.note.status, 'delivering');
    assert.equal(b.status, 409, 'the second box is refused, so it posts nothing');
    assert.equal((await claim(DB, now.id)).status, 409, 'a "now" note is never the hub\'s');
    assert.equal((await claim(DB, 999999)).status, 404);
    assert.deepEqual((await call(DB, '/api/steer/outbox')).body.notes, [], 'a fresh claim is not offered again');
    db.prepare("UPDATE steer_notes SET updated_at='2026-01-01T00:00:00Z' WHERE id=?").run(tk.id);
    const box = await call(DB, '/api/steer/outbox');
    assert.deepEqual(box.body.notes.map((n) => n.id), [tk.id], 'a claim whose report was lost comes back after the lease');
    const again = await claim(DB, tk.id);
    assert.equal(again.status, 200, 'and can be claimed again');
    db.prepare("INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('steer.deliver_lease_s', '3600', 't', 't', ?)").run(T0);
    // 600 s before the worker's own claim time (the anchor), so no test clock is read.
    const old = new Date(Date.parse(again.body.note.updated_at) - 600 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    db.prepare("UPDATE steer_notes SET updated_at=? WHERE id=?").run(old, tk.id);
    assert.deepEqual((await call(DB, '/api/steer/outbox')).body.notes, [], 'the settings row sets the lease (3600 s > 600 s old)');
  });
});

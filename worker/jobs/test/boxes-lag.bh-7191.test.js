// BH-7306 (BH-7191.4): POST /api/boxes/lag {rows:[{box, lag_min}]}, the write
// fvc_sink (bin/lib/fleet-version-sink.sh) sends once per fleet-version-check
// tick. Driven through the REAL worker.fetch over the REAL jobs schema (the
// node:sqlite D1 shim). Pinned here: the bearer gate (W1), the write and its
// read-back through GET /api/boxes (W2), update only (W3), the body checks
// that write nothing (W4) and the per-row checks (W5).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'fixture-secret';
const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const lag = (DB, body, secret) => call(DB, '/api/boxes/lag', { method: 'POST', body, secret });

async function seeded() {
  const o = await openDb();
  for (const box of ['a', 'b']) {
    o.db.prepare("INSERT INTO box_status (box, harness_commit, updated_at) VALUES (?, 'abcd1234abcd', '2026-10-17T00:00:00Z')").run(box);
  }
  return o;
}
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM box_status').get().n;
const lagCols = (db) => {
  try { return db.prepare('SELECT box, harness_lag_min, lag_checked_at FROM box_status ORDER BY box').all(); } catch { return null; }
};

test('BH-7191.4 POST /api/boxes/lag', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 no bearer or a wrong bearer is 401', async () => {
    const { db, DB } = await seeded();
    for (const secret of [null, 'wrong-fixture']) {
      const r = await lag(DB, { rows: [{ box: 'a', lag_min: 0 }] }, secret);
      assert.equal(r.status, 401, `bearer ${secret}`);
    }
    const cols = lagCols(db);
    assert.ok(cols === null || cols.every((r) => r.harness_lag_min === null), 'a 401 writes nothing');
  });

  await t.test('W2 the rows are written and GET /api/boxes reads them back', async () => {
    const { DB } = await seeded();
    const r = await lag(DB, { rows: [{ box: 'a', lag_min: 0 }, { box: 'b', lag_min: 40 }] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.updated, 2);
    assert.deepEqual(r.body.unknown, []);
    assert.equal(r.body.rejected, 0);
    const g = await call(DB, '/api/boxes');
    assert.equal(g.status, 200);
    const by = Object.fromEntries(g.body.boxes.map((x) => [x.box, x]));
    assert.equal(by.a.harness_lag_min, 0);
    assert.equal(by.b.harness_lag_min, 40);
    assert.equal(by.a.lag_checked_at, r.body.as_of, 'lag_checked_at is the request time');
    assert.match(by.b.lag_checked_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/);
    assert.equal(by.a.harness_commit, 'abcd1234abcd', 'other columns are untouched');
  });

  await t.test('W2b a box twice in one body: the last row wins', async () => {
    const { db, DB } = await seeded();
    const r = await lag(DB, { rows: [{ box: 'a', lag_min: 5 }, { box: 'a', lag_min: 0 }] });
    assert.equal(r.status, 200);
    assert.equal(r.body.updated, 1);
    assert.equal(lagCols(db).find((x) => x.box === 'a').harness_lag_min, 0);
  });

  await t.test('W3 an unknown box makes no row and is named in unknown', async () => {
    const { db, DB } = await seeded();
    const before = count(db);
    const r = await lag(DB, { rows: [{ box: 'zz', lag_min: 3 }, { box: 'b', lag_min: 1 }] });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.unknown, ['zz']);
    assert.equal(r.body.updated, 1);
    assert.equal(count(db), before, 'no row was created');
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM box_status WHERE box='zz'").get().n, 0);
  });

  await t.test('W4 a bad body is 400 and writes nothing', async () => {
    const { db, DB } = await seeded();
    const big = Array.from({ length: 201 }, (_, i) => ({ box: i % 2 ? 'a' : 'b', lag_min: 7 }));
    for (const body of [{}, { rows: 'a' }, { rows: {} }, { rows: [] }, { rows: big }]) {
      const r = await lag(DB, body);
      assert.equal(r.status, 400, JSON.stringify(body).slice(0, 60));
    }
    const cols = lagCols(db);
    assert.ok(cols === null || cols.every((x) => x.harness_lag_min === null && x.lag_checked_at === null), JSON.stringify(cols));
    const ok = await lag(DB, { rows: big.slice(0, 200) });
    assert.equal(ok.status, 200, '200 rows is the cap, not over it');
  });

  await t.test('W5 a bad name or a bad lag_min is rejected and not written', async () => {
    const { db, DB } = await seeded();
    const rows = [
      { box: 'a', lag_min: -1 }, { box: 'a', lag_min: 1.5 }, { box: 'a', lag_min: '7' },
      { box: 'a', lag_min: 525601 }, { box: 'a' }, { box: 'bad name', lag_min: 1 }, { box: '', lag_min: 1 }, 'x',
      { box: 'b', lag_min: 525600 },
    ];
    const r = await lag(DB, { rows });
    assert.equal(r.status, 200);
    assert.equal(r.body.rejected, 8);
    assert.equal(r.body.updated, 1);
    const by = Object.fromEntries(lagCols(db).map((x) => [x.box, x]));
    assert.equal(by.a.harness_lag_min, null, 'no rejected row reached a');
    assert.equal(by.a.lag_checked_at, null);
    assert.equal(by.b.harness_lag_min, 525600);
  });
});

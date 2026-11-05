// BH-2645 (BH-2516.1): the real token-health write and read routes that
// replace the BH-2644 stubs. Every case goes through the REAL router
// (worker.fetch) against a node:sqlite D1 built from schema.sql, so the
// upsert and the union read are the statements production runs.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const WARN_KEY = 'lib.token-health.token_health_warn_h';
const ROW_KEYS = [
  'box', 'expires_at', 'expires_in_s', 'expiring', 'fail_count', 'kind', 'last_attempt_at',
  'last_error', 'last_ok', 'last_ok_at', 'leases', 'live_leases', 'reported', 'subject',
];

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const post = (DB, body) => call(DB, '/api/account-leases/token-health', { method: 'POST', body });
const health = (DB) => call(DB, '/api/account-leases/health');
const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is fromNow(s) or iso(ANCHOR) off it
// Second precision, like the worker's own clock.
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const fromNow = (s) => iso(ANCHOR + s * 1000);

function putToken(db, kind, subject, expiresAt) {
  db.prepare(
    `INSERT INTO token_health (kind,subject,box,expires_at,last_ok_at,last_attempt_at,last_ok,fail_count,last_error,updated_at)
     VALUES (?,?,?,?,?,?,1,0,NULL,?)`
  ).run(kind, subject, 'hub', expiresAt, iso(ANCHOR), iso(ANCHOR), iso(ANCHOR));
}

function putLease(db, account, machine, expiresAt) {
  db.prepare(
    `INSERT INTO account_leases (account,machine_id,box,project,ticket_key,expires_at,created_at,updated_at)
     VALUES (?,?,?,?,?,?,?,?)`
  ).run(account, machine, 'box1', 'proj', 'BH-1', expiresAt, iso(ANCHOR), iso(ANCHOR));
}

const setWarn = (db, v) => db.prepare('UPDATE settings SET value=? WHERE key=?').run(v, WARN_KEY);
const byKey = (accounts) => Object.fromEntries(accounts.map((a) => [`${a.kind}/${a.subject}`, a]));

test('BH-2645 token health routes', async (t) => {
  // Keep the worker clock at the same second as the expiry fixtures. Database
  // preparation and earlier subtests must not consume G4's one-second margin.
  t.mock.timers.enable({ apis: ['Date'], now: Math.floor(ANCHOR / 1000) * 1000 });
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('P1 every invalid body 400s and writes nothing', async () => {
    const { db, DB } = await openDb();
    const good = { kind: 'oauth', subject: 'acct-x', box: 'hub', ok: true };
    const bad = [
      { ...good, kind: 'foo' },
      { ...good, kind: 'OAUTH' },
      { ...good, ok: 'yes' },
      { ...good, ok: 1 },
      { ...good, ok: 'true' },
      { ...good, expires_at: 'soon' },
      { ...good, expires_at: '' },
      { ...good, expires_at: 12345 },
      { ...good, subject: 'a b' },
      { kind: 'oauth', box: 'hub', ok: true },
    ];
    for (const b of bad) {
      const res = await post(DB, b);
      assert.equal(res.status, 400, `${JSON.stringify(b)} -> ${JSON.stringify(res.body)}`);
      assert.equal(typeof res.body.error, 'string');
    }
    assert.equal(db.prepare('SELECT count(*) AS n FROM token_health').get().n, 0);
    // The same body with every field valid is written: the 400s above are the
    // validation, not a route that never writes.
    const ok = await post(DB, { ...good, expires_at: '2100-01-01T00:00:00Z' });
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(db.prepare('SELECT count(*) AS n FROM token_health').get().n, 1);
  });

  await t.test('P2 fail, fail, ok: counters, last_ok_at and expires_at follow the ticket', async () => {
    const { db, DB } = await openDb();
    const row = () => db.prepare("SELECT * FROM token_health WHERE kind='oauth' AND subject='acct-x'").get();
    const exp1 = '2100-01-01T00:00:00Z';
    const r1 = await post(DB, { kind: 'oauth', subject: 'acct-x', box: 'b1', ok: false, expires_at: exp1, error: 'refresh 401' });
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.ok, true);
    assert.deepEqual(r1.body.row, { ...row() });
    assert.equal(row().fail_count, 1);
    assert.equal(row().last_ok, 0);
    assert.equal(row().last_ok_at, null);
    assert.equal(row().expires_at, exp1);
    assert.equal(row().last_error, 'refresh 401');
    assert.equal(row().box, 'b1');
    assert.match(row().last_attempt_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.equal(row().updated_at, row().last_attempt_at);

    const r2 = await post(DB, { kind: 'oauth', subject: 'acct-x', box: 'b2', ok: false });
    assert.equal(r2.status, 200);
    assert.equal(row().fail_count, 2);
    assert.equal(row().last_ok, 0);
    assert.equal(row().last_ok_at, null);
    assert.equal(row().expires_at, exp1, 'a fail with no expires_at keeps the previous one');
    assert.equal(row().last_error, null, 'a fail with no error records none');
    assert.equal(row().box, 'b2');

    const exp2 = '2101-06-01T12:00:00.000Z';
    const r3 = await post(DB, { kind: 'oauth', subject: 'acct-x', box: 'b3', ok: true, expires_at: exp2 });
    assert.equal(r3.status, 200);
    assert.equal(row().fail_count, 0);
    assert.equal(row().last_ok, 1);
    assert.equal(row().last_ok_at, row().last_attempt_at, 'last_ok_at is the server clock of this ok');
    assert.equal(row().expires_at, '2101-06-01T12:00:00Z', 'stored at second precision');
    assert.deepEqual(r3.body.row, { ...row() });

    // A fail WITH a new expires_at replaces it; a later ok with none clears it.
    await post(DB, { kind: 'oauth', subject: 'acct-x', box: 'b3', ok: false, expires_at: exp1 });
    assert.equal(row().expires_at, exp1);
    await post(DB, { kind: 'oauth', subject: 'acct-x', box: 'b3', ok: true });
    assert.equal(row().expires_at, null);
    assert.equal(db.prepare('SELECT count(*) AS n FROM token_health').get().n, 1, 'one row per (kind, subject)');

    // The same subject under the other kind is its own row.
    await post(DB, { kind: 'gh_app', subject: 'acct-x', box: 'b3', ok: false });
    assert.equal(db.prepare('SELECT count(*) AS n FROM token_health').get().n, 2);
    assert.equal(row().fail_count, 0);
  });

  await t.test('P3 last_error is truncated to 200 chars', async () => {
    const { db, DB } = await openDb();
    const res = await post(DB, { kind: 'gh_app', subject: 'app-1', box: 'hub', ok: false, error: 'e'.repeat(300) });
    assert.equal(res.status, 200);
    const r = db.prepare("SELECT last_error FROM token_health WHERE subject='app-1'").get();
    assert.equal(r.last_error.length, 200);
  });

  await t.test('G1 the union of live leases and token rows, with the expiring rule', async () => {
    const { db, DB } = await openDb();
    const c = await call(DB, '/api/account-leases/claim', {
      method: 'POST', body: { account: 'acct-a', machine_id: 'm1', box: 'box1', project: 'p', ticket_key: 'BH-9' },
    });
    assert.equal(c.status, 200, JSON.stringify(c.body));
    putToken(db, 'oauth', 'acct-b', fromNow(2 * 3600));
    putToken(db, 'oauth', 'acct-c', fromNow(48 * 3600));
    putToken(db, 'gh_app', 'app-123', fromNow(-3600));
    putToken(db, 'oauth', 'acct-n', null);
    putLease(db, 'acct-z', 'm9', fromNow(-60));

    const res = await health(DB);
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.deepEqual(Object.keys(res.body).sort(), ['accounts', 'as_of', 'truncated', 'warn_h', 'warn_h_source']);
    assert.equal(res.body.warn_h, 24);
    assert.equal(res.body.warn_h_source, 'settings');
    assert.deepEqual(res.body.truncated, { leases: false, tokens: false });
    for (const a of res.body.accounts) assert.deepEqual(Object.keys(a).sort(), ROW_KEYS, `${a.kind}/${a.subject}`);
    assert.deepEqual(res.body.accounts.map((a) => `${a.kind}/${a.subject}`), [
      'gh_app/app-123', 'oauth/acct-a', 'oauth/acct-b', 'oauth/acct-c', 'oauth/acct-n',
    ], 'sorted by kind then subject; the expired-lease-only acct-z is absent');

    const m = byKey(res.body.accounts);
    const a = m['oauth/acct-a'];
    assert.equal(a.reported, false);
    assert.equal(a.expiring, false);
    assert.equal(a.live_leases, 1);
    assert.equal(a.fail_count, 0);
    assert.equal(a.expires_at, null);
    assert.equal(a.expires_in_s, null);
    assert.deepEqual(Object.keys(a.leases[0]).sort(), ['box', 'expires_at', 'machine_id', 'project', 'ticket_key']);
    assert.equal(a.leases[0].machine_id, 'm1');
    assert.equal(a.leases[0].ticket_key, 'BH-9');

    assert.equal(m['oauth/acct-b'].expiring, true);
    assert.equal(m['oauth/acct-b'].reported, true);
    assert.equal(m['oauth/acct-b'].live_leases, 0);
    assert.deepEqual(m['oauth/acct-b'].leases, []);
    assert.ok(m['oauth/acct-b'].expires_in_s > 7000 && m['oauth/acct-b'].expires_in_s <= 7200);
    assert.equal(m['oauth/acct-c'].expiring, false);
    assert.equal(m['gh_app/app-123'].expiring, true);
    assert.ok(m['gh_app/app-123'].expires_in_s < 0, 'an expired token keeps its negative expires_in_s');
    assert.equal(m['oauth/acct-n'].expiring, false);
    assert.equal(m['oauth/acct-n'].expires_in_s, null);
    // Read-only: the expired lease is still in the table afterwards.
    assert.equal(db.prepare("SELECT count(*) AS n FROM account_leases WHERE account='acct-z'").get().n, 1);
  });

  await t.test('G2 a lease on a reported account merges into its token row', async () => {
    const { db, DB } = await openDb();
    putToken(db, 'oauth', 'acct-b', fromNow(2 * 3600));
    putToken(db, 'gh_app', 'acct-b', fromNow(2 * 3600));
    putLease(db, 'acct-b', 'm1', fromNow(600));
    const res = await health(DB);
    const rows = res.body.accounts.filter((x) => x.subject === 'acct-b');
    assert.equal(rows.length, 2, 'one oauth row, one gh_app row: never a third lease-only row');
    const m = byKey(rows);
    assert.equal(m['oauth/acct-b'].reported, true);
    assert.equal(m['oauth/acct-b'].live_leases, 1);
    assert.equal(m['oauth/acct-b'].leases.length, 1);
    assert.equal(m['gh_app/acct-b'].live_leases, 0);
    assert.deepEqual(m['gh_app/acct-b'].leases, []);
  });

  await t.test('G3 warn_h comes from the settings row; unusable values fall back to 24', async () => {
    const { db, DB } = await openDb();
    putToken(db, 'oauth', 'acct-b', fromNow(2 * 3600));
    putToken(db, 'oauth', 'acct-30', fromNow(30 * 3600));

    setWarn(db, '1');
    let res = await health(DB);
    assert.equal(res.body.warn_h, 1);
    assert.equal(res.body.warn_h_source, 'settings');
    assert.equal(byKey(res.body.accounts)['oauth/acct-b'].expiring, false);

    setWarn(db, '48');
    res = await health(DB);
    assert.equal(res.body.warn_h, 48);
    assert.equal(byKey(res.body.accounts)['oauth/acct-30'].expiring, true);

    for (const v of ['abc', '0', '-3', '', ' ']) {
      setWarn(db, v);
      res = await health(DB);
      assert.equal(res.body.warn_h, 24, `value ${JSON.stringify(v)}`);
      assert.equal(res.body.warn_h_source, 'default', `value ${JSON.stringify(v)}`);
      assert.equal(byKey(res.body.accounts)['oauth/acct-30'].expiring, false);
      assert.equal(byKey(res.body.accounts)['oauth/acct-b'].expiring, true);
    }

    db.prepare('DELETE FROM settings WHERE key=?').run(WARN_KEY);
    res = await health(DB);
    assert.equal(res.body.warn_h, 24);
    assert.equal(res.body.warn_h_source, 'default');
  });

  await t.test('G4 a token exactly warn_h hours + 1 s away is not red', async () => {
    const { db, DB } = await openDb();
    putToken(db, 'oauth', 'edge', fromNow(24 * 3600 + 1));
    putToken(db, 'oauth', 'inside', fromNow(24 * 3600 - 5));
    const m = byKey((await health(DB)).body.accounts);
    assert.equal(m['oauth/edge'].expires_in_s, 24 * 3600 + 1);
    assert.equal(m['oauth/edge'].expiring, false, `expires_in_s=${m['oauth/edge'].expires_in_s}`);
    assert.equal(m['oauth/inside'].expiring, true);
  });

  await t.test('G5 the leases and tokens caps set truncated; counts stay exact', async () => {
    const { db, DB } = await openDb();
    const exp = fromNow(3600);
    for (let i = 0; i < 200; i++) putLease(db, `acct-${String(i % 7).padStart(2, '0')}`, `m${i}`, exp);
    let res = await health(DB);
    assert.deepEqual(res.body.truncated, { leases: false, tokens: false });
    assert.equal(res.body.accounts.reduce((s, a) => s + a.leases.length, 0), 200);

    putLease(db, 'acct-99', 'm-last', exp);
    res = await health(DB);
    assert.equal(res.body.truncated.leases, true);
    assert.equal(res.body.truncated.tokens, false);
    assert.equal(res.body.accounts.reduce((s, a) => s + a.leases.length, 0), 200);
    assert.equal(res.body.accounts.reduce((s, a) => s + a.live_leases, 0), 201);

    const ins = db.prepare(
      "INSERT INTO token_health (kind,subject,box,expires_at,last_ok,fail_count,updated_at) VALUES ('gh_app',?,NULL,NULL,1,0,?)"
    );
    for (let i = 0; i < 500; i++) ins.run(`app-${String(i).padStart(4, '0')}`, iso(ANCHOR));
    res = await health(DB);
    assert.equal(res.body.truncated.tokens, false);
    assert.equal(res.body.accounts.filter((a) => a.reported).length, 500);

    ins.run('app-9999', iso(ANCHOR));
    res = await health(DB);
    assert.equal(res.body.truncated.tokens, true);
    assert.equal(res.body.accounts.filter((a) => a.reported).length, 500);
  });

  await t.test('G6 the old GET /api/account-leases answer keeps its keys', async () => {
    const { DB } = await openDb();
    await call(DB, '/api/account-leases/claim', { method: 'POST', body: { account: 'max1', machine_id: 'm1' } });
    await post(DB, { kind: 'oauth', subject: 'max1', box: 'hub', ok: true });
    const res = await call(DB, '/api/account-leases');
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['as_of', 'counts', 'live']);
    assert.deepEqual(res.body.counts, { max1: 1 });
  });
});

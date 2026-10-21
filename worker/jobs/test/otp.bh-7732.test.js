// BH-7732: GET /api/otp, the otp_messages table, its indexes and its
// retention rule. Driven through the REAL worker.fetch on node:sqlite with the
// composed jobs schema. Rows are written straight into the table, in the shape
// worker/otp-inbox/src/index.js writes them.
//   O1 bearer        O2 newest code        O3 since (ISO and epoch)
//   O4 404           O5 recipient case and wrong recipient
//   O6 no log line holds a code            O7 EXPLAIN at 5,000 rows
//   O8 retention removes a 30 h row        O9 dry run and the default window
//   O10 400 on a bad to or since           K1 seeds and indexes
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh7732';
const SQL = await import('../src/routes/otp.js').catch(() => ({}));
const CODES = ['111111', '222222', '333333', '444444', 'K7Q2ZP', '555555'];

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, method, path, { auth = `Bearer ${SECRET}`, body } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, headers: res.headers, body: await res.json().catch(() => null) }));
}
const get = (DB, to, since, opts) => call(DB, 'GET', `/api/otp?${new URLSearchParams({ to, since })}`, opts);
function seed(db, { to = 'bot@otp.example.test', mid, code, status = code ? 'code' : 'no_code', at, subject = 'Your code' }) {
  db.prepare(`INSERT INTO otp_messages (recipient, message_id, sender, subject, code, parse_status, received_at)
              VALUES (?,?,'noreply@vendor.example.test',?,?,?,?)`).run(to, mid, subject, code ?? null, status, at);
}
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-20T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
async function capture(fn) {
  const lines = []; const keep = {};
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) { keep[k] = console[k]; console[k] = (...a) => lines.push(a.map(String).join(' ')); }
  try { await fn(); } finally { Object.assign(console, keep); }
  return lines;
}
const ALL_LINES = [];

test('K1 the schema has otp_messages, its three indexes and the retention window row (1 day)', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ix = Object.fromEntries(o.db.prepare("SELECT name, \"unique\" AS u FROM pragma_index_list('otp_messages')").all().map((r) => [r.name, r.u]));
  assert.equal(ix.uq_otp_messages_msg, 1);
  assert.equal(ix.idx_otp_messages_recipient, 0);
  assert.equal(ix.idx_otp_messages_received, 0);
  const cols = (n) => o.db.prepare(`SELECT name FROM pragma_index_info('${n}') ORDER BY seqno`).all().map((r) => r.name);
  assert.deepEqual(cols('uq_otp_messages_msg'), ['recipient', 'message_id']);
  assert.deepEqual(cols('idx_otp_messages_recipient'), ['recipient', 'received_at']);
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key='retention.otp_messages.days'").get()?.value, '1');
  assert.throws(() => seed(o.db, { mid: 'x', code: '1', status: 'bogus', at: '2026-10-20T00:00:00Z' }), /CHECK/);
});

test('O1 no bearer or a wrong bearer: 401, and nothing is read', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'm1', code: '111111', at: '2026-10-20T10:00:00Z' });
  const a = await get(o.DB, 'bot@otp.example.test', '2026-10-20T00:00:00Z', { auth: null });
  assert.equal(a.status, 401); assert.equal(JSON.stringify(a.body).includes('111111'), false);
  const b = await get(o.DB, 'bot@otp.example.test', '2026-10-20T00:00:00Z', { auth: 'Bearer tok-fixture-wrong' });
  assert.equal(b.status, 401); assert.equal(JSON.stringify(b.body).includes('111111'), false);
});

test('O2 two code rows after since: 200 with the newer one, no-store', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'm1', code: '111111', at: '2026-10-20T10:00:00Z' });
  seed(o.db, { mid: 'm2', code: '222222', at: '2026-10-20T10:05:00Z', subject: 'Newer' });
  seed(o.db, { mid: 'm3', at: '2026-10-20T10:06:00Z' }); // a newer no_code row is never the answer
  let r;
  ALL_LINES.push(...await capture(async () => { r = await get(o.DB, 'bot@otp.example.test', '2026-10-20T09:00:00Z'); }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.code, '222222');
  assert.equal(r.body.subject, 'Newer');
  assert.equal(r.body.sender, 'noreply@vendor.example.test');
  assert.equal(r.body.received_at, '2026-10-20T10:05:00Z');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  // two rows in the same second: the later insert wins
  seed(o.db, { mid: 'm4', code: '333333', at: '2026-10-20T10:05:00Z' });
  seed(o.db, { mid: 'm5', code: '444444', at: '2026-10-20T10:05:00Z' });
  ALL_LINES.push(...await capture(async () => { r = await get(o.DB, 'bot@otp.example.test', '2026-10-20T09:00:00Z'); }));
  assert.equal(r.body.code, '444444');
});

test('O3 a row before since is not returned; since in epoch seconds reads the same as ISO; since itself counts', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'm1', code: '111111', at: '2026-10-20T10:00:00Z' });
  seed(o.db, { mid: 'm2', code: 'K7Q2ZP', at: '2026-10-20T10:10:00Z' });
  let a, b, c, d;
  ALL_LINES.push(...await capture(async () => {
    a = await get(o.DB, 'bot@otp.example.test', '2026-10-20T10:10:00Z');
    b = await get(o.DB, 'bot@otp.example.test', String(Date.parse('2026-10-20T10:10:00Z') / 1000));
    c = await get(o.DB, 'bot@otp.example.test', '2026-10-20T10:10:01Z');
    d = await get(o.DB, 'bot@otp.example.test', String(Date.parse('2026-10-20T09:00:00Z') / 1000));
  }));
  assert.equal(a.status, 200); assert.equal(a.body.code, 'K7Q2ZP');
  assert.equal(b.status, 200); assert.equal(b.body.code, 'K7Q2ZP');
  assert.equal(c.status, 404);
  assert.equal(d.body.code, 'K7Q2ZP');
});

test('O4 no row, or only no_code and too_large rows: 404 no code', async (t) => {
  const o = await fresh(t); if (!o) return;
  let r;
  ALL_LINES.push(...await capture(async () => { r = await get(o.DB, 'bot@otp.example.test', '2026-10-20T00:00:00Z'); }));
  assert.equal(r.status, 404); assert.equal(r.body.error, 'no code');
  seed(o.db, { mid: 'm1', at: '2026-10-20T10:00:00Z' });
  seed(o.db, { mid: 'm2', status: 'too_large', at: '2026-10-20T10:01:00Z' });
  ALL_LINES.push(...await capture(async () => { r = await get(o.DB, 'bot@otp.example.test', '2026-10-20T00:00:00Z'); }));
  assert.equal(r.status, 404); assert.equal(r.body.error, 'no code');
  assert.equal(r.headers.get('cache-control'), 'no-store');
});

test('O5 to= is trimmed and lowercased; another recipient\'s row is never returned', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'm1', code: '555555', at: '2026-10-20T10:00:00Z' });
  seed(o.db, { to: 'other@otp.example.test', mid: 'm2', code: '444444', at: '2026-10-20T10:30:00Z' });
  let a, b;
  ALL_LINES.push(...await capture(async () => {
    a = await get(o.DB, ' Bot@OTP.Example.Test ', '2026-10-20T00:00:00Z');
    b = await get(o.DB, 'nobody@otp.example.test', '2026-10-20T00:00:00Z');
  }));
  assert.equal(a.status, 200); assert.equal(a.body.code, '555555');
  assert.equal(b.status, 404);
});

test('O10 a bad or missing to or since: 400, before any read', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const to of ['', 'not-an-address', 'a b@otp.example.test', 'x@otp.example.test/../y']) {
    assert.equal((await get(o.DB, to, '2026-10-20T00:00:00Z')).status, 400, `to=${to}`);
  }
  for (const since of ['', 'yesterday', '2026-10-20 10:00:00Z', '2026-10-20T10:00:00+00:00', '-5', '1.5']) {
    assert.equal((await get(o.DB, 'bot@otp.example.test', since)).status, 400, `since=${since}`);
  }
  assert.equal((await call(o.DB, 'GET', '/api/otp?to=bot%40otp.example.test')).status, 400, 'since is required');
});

// O6 drives its own reads, so it never depends on the order or the outcome of
// O2-O5, and it never skips: the CI skip guard fails any skipped test. The
// route writes no console line today, so an empty capture is the normal case;
// the sentinel line proves the capture itself works.
test('O6 no console line written by a 200, 404, 400 or 401 read holds a code', async () => {
  const o = await openDb();
  assert.ok(o, 'node:sqlite unavailable: O6 cannot drive the route');
  seed(o.db, { mid: 'm1', code: '111111', at: '2026-10-20T10:00:00Z' });
  seed(o.db, { mid: 'm2', code: 'K7Q2ZP', at: '2026-10-20T10:05:00Z' });
  seed(o.db, { to: 'other@otp.example.test', mid: 'm3', code: '555555', at: '2026-10-20T10:06:00Z' });
  const SENTINEL = 'o6-capture-sentinel';
  const st = [];
  const lines = await capture(async () => {
    console.log(SENTINEL);
    st.push((await get(o.DB, 'bot@otp.example.test', '2026-10-20T09:00:00Z')).status);
    st.push((await get(o.DB, 'nobody@otp.example.test', '2026-10-20T09:00:00Z')).status);
    st.push((await get(o.DB, 'not-an-address', '2026-10-20T09:00:00Z')).status);
    st.push((await get(o.DB, 'bot@otp.example.test', '2026-10-20T09:00:00Z', { auth: 'Bearer tok-fixture-wrong' })).status);
  });
  assert.deepEqual(st, [200, 404, 400, 401]);
  assert.ok(lines.includes(SENTINEL), 'the console capture caught nothing');
  for (const line of [...lines, ...ALL_LINES]) for (const c of CODES) assert.ok(!line.includes(c), `a log line holds ${c}: ${line}`);
});

test('O7 at 5,000 rows over 50 recipients the route read, the dedup lookup and the retention reads use their indexes, no SCAN', async (t) => {
  const o = await fresh(t); if (!o) return;
  const { db } = o;
  assert.ok(SQL.OTP_READ_SQL, 'routes/otp.js exports OTP_READ_SQL');
  db.exec('BEGIN');
  const ins = db.prepare(`INSERT INTO otp_messages (recipient, message_id, sender, subject, code, parse_status, received_at)
                          VALUES (?,?,'s@vendor.example.test','x',?,?,?)`);
  for (let i = 0; i < 5000; i++) {
    const at = new Date(Date.parse('2026-10-19T00:00:00Z') + i * 17e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
    ins.run(`r${i % 50}@otp.example.test`, `<m${i}@vendor.example.test>`, i % 4 ? String(100000 + i) : null, i % 4 ? 'code' : 'no_code', at);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const { RULES } = await import('../src/routes/retention.js');
  const rule = RULES.find((x) => x.rule === 'otp_messages.age');
  assert.ok(rule, 'the otp_messages.age retention rule exists');
  const T = '2026-10-19T12:00:00Z';
  const plans = {
    route: plan(db, SQL.OTP_READ_SQL, 'r1@otp.example.test', T),
    dedup: plan(db, 'SELECT 1 FROM otp_messages WHERE recipient=?1 AND message_id=?2', 'r1@otp.example.test', '<m1@vendor.example.test>'),
    ret_ids: plan(db, rule.ids, T, 500),
    ret_del: plan(db, rule.del, '[1,2]'),
  };
  for (const [name, lines] of Object.entries(plans)) {
    assert.deepEqual(fullScans(lines, ['otp_messages']), [], `${name}: ${lines.join(' | ')}`);
  }
  const uses = (name, ix) => assert.ok(plans[name].some((x) => x.includes(ix)), `${name}: ${plans[name].join(' | ')}`);
  uses('route', 'idx_otp_messages_recipient');
  uses('dedup', 'uq_otp_messages_msg');
  uses('ret_ids', 'idx_otp_messages_received');
  assert.ok(!plans.route.some((x) => /TEMP B-TREE/.test(x)), `route sorts on the index: ${plans.route.join(' | ')}`);
});

// The retention route cuts off at its own server clock, so the seeded ages are
// offsets from one anchor taken here.
const NOW_MS = Date.now(); // determinism: ok the single anchor; the route under test reads the real clock
const hoursAgo = (h) => new Date(NOW_MS - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
const runRetention = (DB, body) => call(DB, 'POST', '/api/retention/run', { body: body ?? {} });
const audit = (db) => db.prepare("SELECT dry_run, counted, removed FROM retention_runs WHERE rule='otp_messages.age' ORDER BY id").all();

test('O8 retention with dry_run 0 deletes the 30 h row, keeps the 2 h row, and writes one audit row', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'old', code: '111111', at: hoursAgo(30) });
  seed(o.db, { mid: 'new', code: '222222', at: hoursAgo(2) });
  setting(o.db, 'retention.dry_run', 0);
  const r = await runRetention(o.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const rule = r.body.rules.find((x) => x.rule === 'otp_messages.age');
  assert.ok(rule, 'the otp rule ran'); assert.equal(rule.removed, 1); assert.equal(rule.error, null);
  assert.deepEqual(o.db.prepare('SELECT message_id FROM otp_messages').all().map((x) => x.message_id), ['new']);
  const a = audit(o.db);
  assert.equal(a.length, 1); assert.equal(Number(a[0].removed), 1); assert.equal(Number(a[0].dry_run), 0);
});

test('O9 a dry run counts and deletes nothing, with one audit row; with the settings row gone the window is 24 h', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db, { mid: 'old', code: '111111', at: hoursAgo(30) });
  seed(o.db, { mid: 'new', code: '222222', at: hoursAgo(2) });
  setting(o.db, 'retention.dry_run', 1);
  const r = await runRetention(o.DB);
  assert.equal(r.body.dry_run, true);
  const rule = r.body.rules.find((x) => x.rule === 'otp_messages.age');
  assert.equal(rule.counted, 1); assert.equal(rule.removed, 0);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM otp_messages').get().n, 2);
  const a = audit(o.db);
  assert.equal(a.length, 1); assert.equal(Number(a[0].dry_run), 1); assert.equal(Number(a[0].counted), 1); assert.equal(Number(a[0].removed), 0);
  // the default window when the row is absent
  o.db.prepare("DELETE FROM settings WHERE key='retention.otp_messages.days'").run();
  seed(o.db, { mid: 'edge-out', code: '333333', at: hoursAgo(25) });
  seed(o.db, { mid: 'edge-in', code: '444444', at: hoursAgo(23) });
  const r2 = await runRetention(o.DB);
  const rule2 = r2.body.rules.find((x) => x.rule === 'otp_messages.age');
  assert.equal(rule2.counted, 2, 'the 30 h and 25 h rows are past the default 24 h window; the 23 h and 2 h rows are not');
  assert.equal(Date.parse(rule2.cutoff) <= NOW_MS - 24 * 3600e3 + 120e3 && Date.parse(rule2.cutoff) >= NOW_MS - 24 * 3600e3 - 120e3, true, `cutoff ${rule2.cutoff}`);
});

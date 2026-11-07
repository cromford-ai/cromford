// BH-5560 (BH-5556.3): the staff findings ledger and suppressions, driven
// through the REAL worker.fetch against the REAL schema.sql (the node:sqlite
// D1 shim), the way staff-charter.test.js does it. Pinned here: one claim per
// agent-core fingerprint (the second is refused), a staff-filed source refused
// before the ledger is touched, a suppression with reason, approver and expiry
// that a human records, and an expired suppression that no longer matches.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { fingerprint } from '../../../agent-core/src/index.js';

const SECRET = 'test-secret';
const HUMAN = 'fixture-independent-human-token';
const call = (DB, path, { method = 'POST', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json', 'x-human-verdict-token': HUMAN },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, HUMAN_VERDICT_TOKEN: HUMAN }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const claim = (DB, body) => call(DB, '/api/staff/findings/claim', { body });
const suppress = (DB, body) => call(DB, '/api/staff/suppressions', { body });

const FUTURE = '2099-01-01T00:00:00Z';
// One captured anchor. The route reads its own clock, which is never earlier
// than ANCHOR, so an expiry at ANCHOR or before it is past for every request.
const ANCHOR = Date.now();  // determinism: ok the single anchor; every expiry below is ANCHOR or an offset before it, and the route's clock only moves forward from it
const isoAgo = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const nowIso = () => isoAgo(0);

// One claim body. `item` is what the fingerprint keys; `source` overrides merge in.
const finding = (item, { agent = 'watchman', source = {}, title = 'Secret in a public repo' } = {}) => ({
  agent, item, title,
  source: { kind: 'alert', url: 'https://example.com/alerts/fixture-1', labels: ['ops'], ...source },
  observedAt: '2026-10-09T02:00:00Z',
});
const findings = (db) => db.prepare('SELECT * FROM staff_findings ORDER BY id').all();
const nFindings = (db) => db.prepare('SELECT count(*) AS n FROM staff_findings').get().n;
const nSupp = (db) => db.prepare('SELECT count(*) AS n FROM staff_suppressions').get().n;
const addSupp = (db, fp, { status = 'active', approver = 'operator', expires = FUTURE } = {}) => db.prepare(
  "INSERT INTO staff_suppressions (fingerprint, reason, approver, expires_at, status, created_at) VALUES (?,?,?,?,?,'2026-10-09T00:00:00Z')"
).run(fp, 'known noise, fixture', approver, expires, status);

test('BH-5560 staff findings ledger and suppressions', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('F0 every route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const p of ['/api/staff/findings/claim', '/api/staff/suppressions']) {
      assert.equal((await call(DB, p, { body: {}, secret: null })).status, 401, p);
    }
  });

  await t.test('F1 schema: both tables exist empty; UNIQUE fingerprint and the suppression CHECKs hold', async () => {
    const { db } = await openDb();
    assert.equal(nFindings(db), 0);
    assert.equal(nSupp(db), 0);
    const fp = 'a'.repeat(64);
    const ins = () => db.prepare(
      "INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, claimed_at, updated_at) VALUES (?,'watchman','x','alert','https://x/a','[]','t','t','t')"
    ).run(fp);
    ins();
    assert.throws(ins, /UNIQUE/);
    assert.throws(() => addSupp(db, fp, { approver: null }), /CHECK/);
    assert.throws(() => addSupp(db, fp, { status: 'bogus' }), /CHECK/);
    assert.throws(() => addSupp(db, 'short'), /CHECK/);
    addSupp(db, fp, { status: 'pending', approver: null });
    assert.equal(nSupp(db), 1);
  });

  await t.test('F2 claim: a padded, cased agent claims; unknown 404, paused 409, missing item 400 — refusals write nothing', async () => {
    const { DB, db } = await openDb();
    const r = await claim(DB, finding({ repo: 'a/b', rule: 'aws-key' }, { agent: ' Watchman ' }));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.claimed, true);
    const rows = findings(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].agent, 'watchman');
    assert.equal(rows[0].status, 'claimed');
    assert.equal(r.body.finding.id, rows[0].id);
    assert.equal(r.body.finding.agent, 'watchman');
    assert.deepEqual(JSON.parse(rows[0].source_labels), ['ops']);

    const g = await claim(DB, finding({ n: 2 }, { agent: 'ghost' }));
    assert.equal(g.status, 404);
    assert.deepEqual(g.body, { error: 'agent not found' });
    db.prepare("UPDATE staff_agents SET status='paused' WHERE name='clerk'").run();
    const p = await claim(DB, finding({ n: 3 }, { agent: 'clerk' }));
    assert.equal(p.status, 409, JSON.stringify(p.body));
    assert.equal(p.body.error, 'agent_not_active');
    const noItem = finding(null);
    delete noItem.item;
    assert.equal((await claim(DB, noItem)).status, 400);
    assert.equal((await claim(DB, { ...finding(null), item: null })).body.error, 'item');
    assert.equal((await claim(DB, finding({ n: 4 }, { agent: 'bad agent' }))).body.error, 'agent');
    const noTitle = await claim(DB, finding({ n: 5 }, { title: '' }));
    assert.equal(noTitle.status, 400);
    assert.equal(noTitle.body.error, 'finding');
    assert.ok(noTitle.body.errors.some((e) => /title/.test(e)), JSON.stringify(noTitle.body));
    assert.equal((await claim(DB, { ...finding({ n: 6 }), source: { kind: 'alert', url: 'https://x/a' } })).body.error, 'finding');
    assert.equal(nFindings(db), 1);
  });

  await t.test('F3 the key is agent-core fingerprint(item); a token query never splits it or reaches the table', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', path: 'src/x.js', rule: 'aws-key' };
    const r = await claim(DB, finding(item, { source: { url: 'https://Example.com/alerts/7/?token=abc#frag' } }));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.fingerprint, fingerprint(item));
    // Key order does not change the key.
    assert.equal(r.body.fingerprint, fingerprint({ rule: 'aws-key', path: 'src/x.js', repo: 'a/b' }));
    const row = findings(db)[0];
    assert.equal(row.fingerprint, fingerprint(item));
    assert.equal(row.source_url, 'https://example.com/alerts/7');
    assert.ok(!row.source_url.includes('?'));

    const a = await claim(DB, finding({ url: 'https://x.test/a?token=1' }));
    assert.equal(a.status, 200, JSON.stringify(a.body));
    const b = await claim(DB, finding({ url: 'https://x.test/a?token=2' }));
    assert.equal(b.status, 409, JSON.stringify(b.body));
    assert.equal(b.body.error, 'already_claimed');
    assert.equal(a.body.fingerprint, b.body.fingerprint);
    assert.equal(nFindings(db), 2);
  });

  await t.test('F4 the same fingerprint twice gives one claim; the second is refused and names the first row', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'dep-cve', id: 'CVE-2026-0001' };
    const first = await claim(DB, finding(item));
    assert.equal(first.status, 200);
    const second = await claim(DB, finding(item, { title: 'A different title, same item' }));
    assert.equal(second.status, 409, JSON.stringify(second.body));
    assert.equal(second.body.claimed, false);
    assert.equal(second.body.error, 'already_claimed');
    assert.equal(second.body.fingerprint, first.body.fingerprint);
    assert.equal(second.body.finding.id, first.body.finding.id);
    assert.equal(nFindings(db), 1);
    assert.equal(findings(db)[0].title, 'Secret in a public repo');
    // A different item is a different key, and claims.
    const other = await claim(DB, finding({ ...item, id: 'CVE-2026-0002' }));
    assert.equal(other.status, 200);
    assert.notEqual(other.body.fingerprint, first.body.fingerprint);
    assert.equal(nFindings(db), 2);
  });

  await t.test('F5 a second agent cannot claim an item another agent holds', async () => {
    const { DB, db } = await openDb();
    const item = { box: 'hub', check: 'disk' };
    assert.equal((await claim(DB, finding(item, { agent: 'watchman' }))).status, 200);
    const c = await claim(DB, finding(item, { agent: 'clerk' }));
    assert.equal(c.status, 409);
    assert.equal(c.body.error, 'already_claimed');
    assert.equal(c.body.finding.agent, 'watchman');
    assert.equal(findings(db)[0].agent, 'watchman');
    assert.equal(nFindings(db), 1);
  });

  await t.test('F6 a source that is a staff-filed ticket is refused and writes nothing', async () => {
    const { DB, db } = await openDb();
    const cases = [
      { labels: ['bug', 'staff:watchman'] },
      { labels: [' Staff:Clerk '] },
      { labels: ['staff:someone-not-on-roster'] },
      { labels: ['ops'], filedBy: 'Quartermaster' },
      { labels: [], filedBy: ' archivist ' },
    ];
    for (const [i, source] of cases.entries()) {
      const r = await claim(DB, finding({ n: i }, { agent: 'watchman', source }));
      assert.equal(r.status, 409, JSON.stringify({ source, body: r.body }));
      assert.equal(r.body.error, 'staff_filed', JSON.stringify(source));
      assert.equal(r.body.claimed, false);
    }
    assert.equal(nFindings(db), 0);
  });

  await t.test('F7 negatives: sources that are not staff-filed still claim', async () => {
    const { DB, db } = await openDb();
    const cases = [
      { labels: ['bug', 'staffing'] },
      { labels: ['staff'] },
      { labels: ['ops:staff:x'] },
      { labels: [], filedBy: 'operator' },
      { labels: [], filedBy: 'archie' },
    ];
    for (const [i, source] of cases.entries()) {
      const r = await claim(DB, finding({ neg: i }, { source }));
      assert.equal(r.status, 200, JSON.stringify({ source, body: r.body }));
      assert.equal(r.body.claimed, true);
    }
    assert.equal(nFindings(db), cases.length);
  });

  await t.test('F8 a suppression records reason, approver and expiry; a replay is the same row; bad input is 400', async () => {
    const { DB, db } = await openDb();
    const fp = fingerprint({ repo: 'a/b', rule: 'noisy' });
    const body = { fingerprint: fp.toUpperCase(), reason: ' known noise ', approver: ' operator@example.com ', expiresAt: '2099-01-01T00:00:00.500+00:00' };
    const r = await suppress(DB, body);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.ok, true);
    const row = db.prepare('SELECT * FROM staff_suppressions').get();
    assert.equal(row.fingerprint, fp);
    assert.equal(row.reason, 'known noise');
    assert.equal(row.approver, 'operator@example.com');
    assert.equal(row.expires_at, '2099-01-01T00:00:00Z');
    assert.equal(row.status, 'active');
    assert.equal(r.body.suppression.id, row.id);
    assert.equal(r.body.suppression.expires_at, '2099-01-01T00:00:00Z');
    const again = await suppress(DB, body);
    assert.equal(again.status, 200);
    assert.equal(again.body.existing, true);
    assert.equal(again.body.suppression.id, row.id);
    assert.equal(nSupp(db), 1);

    const ok = { fingerprint: fp, reason: 'r', approver: 'operator', expiresAt: FUTURE };
    const want = [
      [{ ...ok, reason: undefined }, 'reason'],
      [{ ...ok, reason: '   ' }, 'reason'],
      [{ ...ok, reason: 'x'.repeat(501) }, 'reason'],
      [{ ...ok, approver: undefined }, 'approver'],
      [{ ...ok, approver: '' }, 'approver'],
      [{ ...ok, expiresAt: undefined }, 'expiresAt'],
      [{ ...ok, expiresAt: 'soon' }, 'expiresAt'],
      [{ ...ok, expiresAt: isoAgo(60) }, 'expiresAt_past'],
      [{ ...ok, fingerprint: 'abc' }, 'fingerprint'],
      [{ ...ok, fingerprint: 'g'.repeat(64) }, 'fingerprint'],
      [{ ...ok, fingerprint: undefined }, 'fingerprint'],
    ];
    for (const [b, field] of want) {
      const res = await suppress(DB, b);
      assert.equal(res.status, 400, JSON.stringify(b));
      assert.equal(res.body.error, field, JSON.stringify(b));
    }
    assert.equal(nSupp(db), 1);
  });

  await t.test('F9 an agent is never the approver of a suppression', async () => {
    const { DB, db } = await openDb();
    const fp = fingerprint({ n: 'f9' });
    for (const approver of ['archie', 'Archie', 'watchman', ' Clerk ']) {
      const r = await suppress(DB, { fingerprint: fp, reason: 'r', approver, expiresAt: FUTURE });
      assert.equal(r.status, 403, approver);
      assert.deepEqual(r.body, { error: 'agent_approver' });
    }
    assert.equal(nSupp(db), 0);
  });

  await t.test('F10 an active suppression refuses the claim; an expired one no longer matches', async () => {
    const { DB, db } = await openDb();
    const item = { repo: 'a/b', rule: 'muted' };
    const fp = fingerprint(item);
    const s = await suppress(DB, { fingerprint: fp, reason: 'accepted risk', approver: 'operator', expiresAt: FUTURE });
    assert.equal(s.status, 200, JSON.stringify(s.body));
    const r = await claim(DB, finding(item));
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.claimed, false);
    assert.equal(r.body.error, 'suppressed');
    assert.deepEqual(r.body.suppression, {
      id: s.body.suppression.id, reason: 'accepted risk', approver: 'operator', expires_at: FUTURE,
    });
    assert.equal(nFindings(db), 0);

    db.prepare('UPDATE staff_suppressions SET expires_at=? WHERE fingerprint=?').run(isoAgo(1), fp);
    const after = await claim(DB, finding(item));
    assert.equal(after.status, 200, JSON.stringify(after.body));
    assert.equal(after.body.claimed, true);
    assert.equal(nFindings(db), 1);

    // An expiry at or before now, a pending row and a revoked row never match.
    const atNow = { k: 'at-now' };
    addSupp(db, fingerprint(atNow), { expires: nowIso() });
    const pending = { k: 'pending' };
    addSupp(db, fingerprint(pending), { status: 'pending', approver: null });
    const revoked = { k: 'revoked' };
    addSupp(db, fingerprint(revoked), { status: 'revoked' });
    for (const it of [atNow, pending, revoked]) {
      const c = await claim(DB, finding(it));
      assert.equal(c.status, 200, JSON.stringify({ it, body: c.body }));
    }
    assert.equal(nFindings(db), 4);
  });

  await t.test('F11 a suppression for another fingerprint does not block an unrelated claim', async () => {
    const { DB, db } = await openDb();
    addSupp(db, fingerprint({ k: 'muted' }));
    const r = await claim(DB, finding({ k: 'unrelated' }));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(nFindings(db), 1);
  });

  await t.test('F12 an unapplied table answers 503 naming it, never a claim', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE staff_findings');
    const r = await claim(DB, finding({ k: 'no-table' }));
    assert.equal(r.status, 503);
    assert.match(r.body.error, /staff_findings/);
  });
});

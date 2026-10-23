// BH-5567 (BH-5556.10): the staff screen's three read routes, driven through
// the REAL worker.fetch against the REAL schema.sql (the node:sqlite D1 shim),
// the staff-findings.test.js shape. Findings are seeded through the real
// POST /api/staff/findings/claim; status and ticket_url are set by SQL because
// no route writes them yet.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
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
const claim = (DB, item, { agent = 'watchman', title = 'Secret in a public repo' } = {}) => call(DB, '/api/staff/findings/claim', {
  method: 'POST',
  body: {
    agent, item, title,
    source: { kind: 'alert', url: `https://example.com/alerts/fixture-${item.n}`, labels: ['ops', 'fixture'] },
    observedAt: '2026-10-09T02:00:00Z',
  },
});
const STAFF = ['archivist', 'clerk', 'dispatcher', 'inspector', 'millwright', 'quartermaster', 'watchman'];
const TICKET = 'https://github.com/example-org/cromford/issues/5567';

// Two open watchman findings and one merged one. Returns their ids.
async function seed(DB, db) {
  const ids = [];
  for (const n of [1, 2, 3]) {
    const r = await claim(DB, { n, rule: 'fixture-rule' }, { title: `Finding ${n}` });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    ids.push(r.body.finding.id);
  }
  db.prepare('UPDATE staff_findings SET status=? WHERE id=?').run('merged', ids[2]);
  db.prepare('UPDATE staff_findings SET ticket_url=? WHERE id=?').run(TICKET, ids[0]);
  return ids;
}

test('BH-5567 staff screen read routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W0 every new route is bearer-gated', async () => {
    const { DB } = await openDb();
    for (const p of ['/api/staff/roster', '/api/staff/findings?agent=watchman', '/api/staff/finding?id=1']) {
      assert.equal((await call(DB, p, { secret: null })).status, 401, p);
    }
  });

  await t.test('W1 roster: 8 rows, archie first from settings, open counts, null precision and spend', async () => {
    const { DB, db } = await openDb();
    await seed(DB, db);
    const r = await call(DB, '/api/staff/roster');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const rows = r.body.agents;
    // BH-7722 seeds tackler: archie + 7 + tackler.
    assert.equal(rows.length, 9);
    assert.equal(rows[0].name, 'archie');
    assert.equal(rows[0].role, 'overlooker');
    assert.equal(rows[0].accountable, 'operator@example.com');
    assert.equal(rows[0].kind, 'overlooker');
    assert.deepEqual(rows.slice(1).map((a) => a.name).filter((n) => n !== 'tackler'), STAFF);
    assert.ok(rows.some((a) => a.name === 'tackler' && a.kind === 'staff'), 'BH-7722 seeds tackler');
    assert.ok(rows.slice(1).every((a) => a.kind === 'staff'));
    const open = Object.fromEntries(rows.map((a) => [a.name, a.open_findings]));
    assert.equal(open.watchman, 2, 'the merged row is not open');
    for (const n of ['archie', ...STAFF.filter((s) => s !== 'watchman')]) assert.equal(open[n], 0, n);
    for (const a of rows) {
      assert.equal(a.precision, null, `${a.name} precision is null, never 0`);
      assert.equal(a.spend_usd, null, `${a.name} spend is null, never 0`);
    }
    const qm = rows.find((a) => a.name === 'quartermaster');
    assert.equal(qm.role, 'cost');
    assert.equal(qm.autonomy, 'automation');
    assert.equal(qm.cap, 'augmentation');
    assert.equal(qm.status, 'active');
    assert.match(r.body.sources.precision, /BH-5563/);
    assert.match(r.body.sources.spend, /BH-5561/);
  });

  await t.test('W1b roster: an absent archie settings row is null, never a code fallback', async () => {
    const { DB, db } = await openDb();
    db.prepare("DELETE FROM settings WHERE key='staff.archie.accountable'").run();
    const r = await call(DB, '/api/staff/roster');
    assert.equal(r.status, 200);
    assert.equal(r.body.agents[0].accountable, null);
    assert.equal(r.body.agents[0].role, 'overlooker');
  });

  await t.test('W2 findings: only the open rows, id DESC; the agent is case blind; archie is an empty list', async () => {
    const { DB, db } = await openDb();
    const ids = await seed(DB, db);
    const r = await call(DB, '/api/staff/findings?agent=watchman');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.agent, 'watchman');
    assert.deepEqual(r.body.findings.map((f) => f.id), [ids[1], ids[0]]);
    assert.equal(r.body.truncated, false);
    assert.equal(r.body.findings[1].ticket_url, TICKET);
    assert.equal(r.body.findings[0].title, 'Finding 2');
    const upper = await call(DB, '/api/staff/findings?agent=%20WATCHMAN%20');
    assert.equal(upper.status, 200);
    assert.deepEqual(upper.body.findings.map((f) => f.id), [ids[1], ids[0]]);
    const archie = await call(DB, '/api/staff/findings?agent=archie');
    assert.equal(archie.status, 200);
    assert.deepEqual(archie.body.findings, []);
  });

  await t.test('W2b findings: more than 500 open rows is truncated, capped at 500', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare(
      "INSERT INTO staff_findings (fingerprint, agent, title, source_kind, source_url, source_labels, observed_at, claimed_at, updated_at) VALUES (?,'clerk','x','alert','https://example.com/a','[]','t','t','t')"
    );
    for (let i = 0; i < 501; i++) ins.run(i.toString(16).padStart(64, '0'));
    const r = await call(DB, '/api/staff/findings?agent=clerk');
    assert.equal(r.status, 200);
    assert.equal(r.body.findings.length, 500);
    assert.equal(r.body.truncated, true);
  });

  await t.test('W3 findings: missing or bad agent 400, unknown agent 404', async () => {
    const { DB, db } = await openDb();
    await seed(DB, db);
    for (const q of ['', '?agent=', '?agent=..%2Fx', '?agent=a']) {
      const r = await call(DB, `/api/staff/findings${q}`);
      assert.equal(r.status, 400, q);
      assert.equal(r.body.error, 'agent');
    }
    const r = await call(DB, '/api/staff/findings?agent=nobody');
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'agent not found');
  });

  await t.test('W4 finding: one row with its ticket_url and parsed labels; bad id 400, missing 404', async () => {
    const { DB, db } = await openDb();
    const ids = await seed(DB, db);
    const r = await call(DB, `/api/staff/finding?id=${ids[0]}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.finding.id, ids[0]);
    assert.equal(r.body.finding.ticket_url, TICKET);
    assert.deepEqual(r.body.finding.source_labels, ['ops', 'fixture']);
    assert.equal(r.body.finding.labels_invalid, undefined);
    assert.equal(r.body.finding.agent, 'watchman');
    const none = await call(DB, `/api/staff/finding?id=${ids[1]}`);
    assert.equal(none.body.finding.ticket_url, null);
    db.prepare('UPDATE staff_findings SET source_labels=? WHERE id=?').run('not json', ids[1]);
    const junk = await call(DB, `/api/staff/finding?id=${ids[1]}`);
    assert.equal(junk.status, 200);
    assert.equal(junk.body.finding.source_labels, 'not json');
    assert.equal(junk.body.finding.labels_invalid, true);
    for (const q of ['', '?id=abc', '?id=0', '?id=-1', '?id=1.5', '?id=12345678901234567']) {
      const b = await call(DB, `/api/staff/finding${q}`);
      assert.equal(b.status, 400, q);
      assert.equal(b.body.error, 'id');
    }
    const miss = await call(DB, '/api/staff/finding?id=999999');
    assert.equal(miss.status, 404);
    assert.equal(miss.body.error, 'finding not found');
  });

  await t.test('W5 a missing table answers 503 and names it', async () => {
    const { DB, db } = await openDb();
    db.exec('DROP TABLE staff_findings');
    for (const p of ['/api/staff/findings?agent=watchman', '/api/staff/finding?id=1', '/api/staff/roster']) {
      const r = await call(DB, p);
      assert.equal(r.status, 503, p);
      assert.match(r.body.error, /staff_findings/, p);
    }
    const fresh = await openDb();
    fresh.db.exec('DROP VIEW IF EXISTS agent_classes; DROP TABLE staff_agents');
    const roster = await call(fresh.DB, '/api/staff/roster');
    assert.equal(roster.status, 503);
    assert.match(roster.body.error, /staff_agents/);
    const f = await call(fresh.DB, '/api/staff/findings?agent=watchman');
    assert.equal(f.status, 503);
    assert.match(f.body.error, /staff_agents/);
  });

  await t.test('W6 every staff-screen route is a GET', async () => {
    const { routes: staffScreen } = await import('../src/routes/staff-screen.js');
    assert.equal(staffScreen.length, 3);
    for (const [method] of staffScreen) assert.equal(method, 'GET');
  });
});

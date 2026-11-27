// BH-10197: POST /api/unblock/change-marks/check and /commit, driven through
// the REAL worker.fetch on the composed jobs schema in node:sqlite.
//
//   W1  first seen -> due, reason first
//   W2  a newer pr wake -> wake; a wake for PR 12 does not mark PR 123 or 1; a
//       wake of another repo with the same number does not mark; a checks wake
//       does not mark
//   W3  an issue wake for the item's issue -> wake; no issue given -> issue
//       wakes are ignored
//   W4  a head change -> head
//   W5  commit is newer only: mark 5 then mark 4 -> 0 changes and the row keeps
//       5; mark 5 again -> stored (the backstop refresh); the fields round-trip
//   W6  settled: a wake in the worker's current minute -> settled 0, then
//       unsettled
//   W7  backstop on the worker clock: decide() at 3599 s quiet, 3600 s
//       backstop; through the route a row 3500 s old is quiet and 3700 s old is
//       backstop; backstop_s 0 -> off
//   W8  400 cases (bad repo, site, pr, head, backstop_s, issue, too many items
//       from the settings row); fields over the byte cap -> refused, not stored
//   W9  EXPLAIN QUERY PLAN on 5,000 marks rows and 20,000 wakes: the check's
//       three statements and the commit search their indexes, no SCAN; the
//       retention read uses idx_unblock_change_marks_checked
//   W10 wrong repo (the tenant analog): a check for repo B sees no row of repo
//       A (0 rows); the retention rule deletes a 15-day row and keeps a 13-day
//       row through POST /api/retention/run
//   W11 a pruned wake never lowers the mark: a row with mark 5 and no wakes,
//       3700 s old -> backstop, mark 5 -> commit stores it -> next check quiet;
//       a head change with the wakes pruned commits and the next check is quiet
//   W12 a nudge wake (kind issue, minute 'nudge:<dedupe>') on the ticket issue
//       marks the PR once (settled 1); after the commit the PR is quiet, not
//       unsettled on every tick; a webhook wake in the current minute beside
//       it is still unsettled
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { decide, PR_MARKS_SQL, ISSUE_MARKS_SQL, ROWS_SQL, COMMIT_SQL } from '../src/routes/unblock-change-marks.js';
import { RULES } from '#retention-rules';

const SECRET = 'test-secret-fixture';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const minuteAgo = (s) => isoAgo(s).slice(0, 16) + ':00Z';
const REPO = 'example-org/cromford';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function call(DB, path, body) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const check = (DB, items, over = {}) => call(DB, '/api/unblock/change-marks/check', { repo: REPO, site: 'queue', backstop_s: 3600, items, ...over });
const commit = (DB, items, over = {}) => call(DB, '/api/unblock/change-marks/commit', { repo: REPO, site: 'queue', items, ...over });
function wake(db, { repo = REPO, kind = 'pr', key, ago = 600 }) {
  return Number(db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)')
    .run(repo, kind, String(key), 'x', minuteAgo(ago), isoAgo(ago)).lastInsertRowid);
}
function seedRow(db, { repo = REPO.toLowerCase(), site = 'queue', pr, head = H1, mark = 0, settled = 1, fields = '{}', ago = 60 }) {
  db.prepare('INSERT INTO unblock_change_marks (repo, site, pr, head, mark, settled, fields, checked_at) VALUES (?,?,?,?,?,?,?,?)')
    .run(repo, site, pr, head, mark, settled, fields, isoAgo(ago));
}
const byPr = (body) => Object.fromEntries(body.items.map((i) => [i.pr, i]));

test('W1 first seen is due, reason first; a commit makes it quiet', async (t) => {
  const o = await fresh(t); if (!o) return;
  const r = await check(o.DB, [{ pr: 7, head: H1 }]);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.items[0].due, r.body.items[0].reason, r.body.items[0].mark, r.body.items[0].settled], [true, 'first', 0, 1]);
  const c = await commit(o.DB, [{ pr: 7, head: H1, mark: 0, settled: 1, fields: { cr: false } }]);
  assert.equal(c.status, 200);
  assert.equal(c.body.stored, 1);
  const r2 = await check(o.DB, [{ pr: 7, head: H1 }]);
  assert.deepEqual([r2.body.items[0].due, r2.body.items[0].reason], [false, 'quiet']);
  assert.deepEqual(r2.body.items[0].fields, { cr: false });
});

test('W2 a newer pr wake marks only its own PR in its own repo', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = wake(o.db, { key: 12 });
  wake(o.db, { repo: 'Other/repo', key: 123 });
  wake(o.db, { kind: 'checks', key: '123' + 'c'.repeat(37) });
  for (const pr of [12, 123, 1]) seedRow(o.db, { pr, mark: 0 });
  const r = byPr((await check(o.DB, [{ pr: 12, head: H1 }, { pr: 123, head: H1 }, { pr: 1, head: H1 }])).body);
  assert.deepEqual([r[12].due, r[12].reason, r[12].mark], [true, 'wake', id]);
  assert.deepEqual([r[123].due, r[123].reason, r[123].mark], [false, 'quiet', 0]);
  assert.deepEqual([r[1].due, r[1].reason, r[1].mark], [false, 'quiet', 0]);
  // the repo is matched as given and lowercased
  const id2 = wake(o.db, { repo: REPO.toLowerCase(), key: 1 });
  const r2 = byPr((await check(o.DB, [{ pr: 1, head: H1 }])).body);
  assert.deepEqual([r2[1].reason, r2[1].mark], ['wake', id2]);
});

test('W3 an issue wake marks the item that names the issue, and only it', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { pr: 30 }); seedRow(o.db, { pr: 31 });
  const id = wake(o.db, { kind: 'issue', key: 900 });
  const r = byPr((await check(o.DB, [{ pr: 30, head: H1, issue: 900 }, { pr: 31, head: H1 }])).body);
  assert.deepEqual([r[30].due, r[30].reason, r[30].mark], [true, 'wake', id]);
  assert.deepEqual([r[31].due, r[31].reason, r[31].mark], [false, 'quiet', 0]);
  // the same item, now naming the issue, is marked by it
  const r2 = byPr((await check(o.DB, [{ pr: 31, head: H1, issue: 900 }])).body);
  assert.equal(r2[31].reason, 'wake');
});

test('W4 a head change is due, reason head', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { pr: 4, head: H1 });
  const r = (await check(o.DB, [{ pr: 4, head: H2 }])).body.items[0];
  assert.deepEqual([r.due, r.reason], [true, 'head']);
});

test('W5 commit is newer only; the same mark refreshes; fields round-trip', async (t) => {
  const o = await fresh(t); if (!o) return;
  const rv = [{ id: 9, state: 'CHANGES_REQUESTED', commit_id: '0'.repeat(40), submitted_at: '2026-11-24T00:00:00Z', user: { login: 'lead' }, body: '<!-- review-verdict:block ' }];
  let c = await commit(o.DB, [{ pr: 5, head: H1, mark: 5, settled: 1, fields: { rv, fc: false } }], { site: 'review' });
  assert.equal(c.body.stored, 1);
  c = await commit(o.DB, [{ pr: 5, head: H2, mark: 4, settled: 1, fields: { rv: [], fc: true } }], { site: 'review' });
  assert.equal(c.body.stored, 0, 'an older mark changes 0 rows');
  const row = o.db.prepare("SELECT head, mark, fields FROM unblock_change_marks WHERE pr = 5 AND site = 'review'").get();
  assert.deepEqual([row.head, row.mark], [H1, 5]);
  o.db.prepare("UPDATE unblock_change_marks SET checked_at = ? WHERE pr = 5").run(isoAgo(5000));
  c = await commit(o.DB, [{ pr: 5, head: H1, mark: 5, settled: 1, fields: { rv, fc: false } }], { site: 'review' });
  assert.equal(c.body.stored, 1, 'the same mark refreshes the row');
  const r = (await check(o.DB, [{ pr: 5, head: H1 }], { site: 'review' })).body.items[0];
  assert.deepEqual([r.due, r.reason], [false, 'quiet']);
  assert.deepEqual(r.fields, { rv, fc: false });
});

test('W6 a wake in the current minute is not settled; the next check is unsettled', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = wake(o.db, { key: 6, ago: 0 });
  // the worker clock may have moved to the next minute since the seed: then the
  // wake is settled, which is right; pin the answer by moving it into the future minute
  o.db.prepare('UPDATE wakes SET minute = ? WHERE id = ?').run('2999-01-01T00:00:00Z', id);
  const r = (await check(o.DB, [{ pr: 6, head: H1 }])).body.items[0];
  assert.deepEqual([r.reason, r.mark, r.settled], ['first', id, 0]);
  await commit(o.DB, [{ pr: 6, head: H1, mark: r.mark, settled: r.settled, fields: {} }]);
  const r2 = (await check(o.DB, [{ pr: 6, head: H1 }])).body.items[0];
  assert.deepEqual([r2.due, r2.reason], [true, 'unsettled']);
  o.db.prepare('UPDATE wakes SET minute = ? WHERE id = ?').run(minuteAgo(600), id);
  const r3 = (await check(o.DB, [{ pr: 6, head: H1 }])).body.items[0];
  assert.equal(r3.settled, 1, 'a wake whose minute is over is settled');
});

test('W7 the backstop runs on the worker clock', async (t) => {
  const t0 = '2026-11-26T12:00:00Z';
  const at = (s) => new Date(Date.parse(t0) - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const row = (s) => ({ head: H1, mark: 3, settled: 1, checked_at: at(s) });
  assert.deepEqual(decide(row(3599), { head: H1 }, { mark: 3 }, t0, 3600), { due: false, reason: 'quiet' });
  assert.deepEqual(decide(row(3600), { head: H1 }, { mark: 3 }, t0, 3600), { due: true, reason: 'backstop' });
  assert.deepEqual(decide(row(10), { head: H1 }, { mark: 3 }, t0, 0), { due: true, reason: 'off' });
  assert.deepEqual(decide(row(10), { head: H1 }, { mark: 2 }, t0, 3600), { due: false, reason: 'quiet' }, 'a lower mark is not newer');
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { pr: 70, ago: 3500 }); seedRow(o.db, { pr: 71, ago: 3700 });
  const r = byPr((await check(o.DB, [{ pr: 70, head: H1 }, { pr: 71, head: H1 }])).body);
  assert.deepEqual([r[70].due, r[70].reason], [false, 'quiet']);
  assert.deepEqual([r[71].due, r[71].reason], [true, 'backstop']);
  const r0 = (await check(o.DB, [{ pr: 70, head: H1 }], { backstop_s: 0 })).body.items[0];
  assert.deepEqual([r0.due, r0.reason], [true, 'off']);
});

test('W8 bad bodies are 400 and write nothing; fields over the cap are refused', async (t) => {
  const o = await fresh(t); if (!o) return;
  const cases = [
    [{ repo: 'no-slash' }, 'repo'], [{ site: 'infra' }, 'site'], [{ items: 'x' }, 'items'],
    [{ items: [{ pr: 0, head: H1 }] }, 'pr'], [{ items: [{ pr: 1, head: 'XYZ' }] }, 'head'],
    [{ items: [{ pr: 1, head: H1 }, { pr: 1, head: H1 }] }, 'pr_repeated'],
  ];
  for (const [over, field] of cases) {
    const r = await check(o.DB, [{ pr: 1, head: H1 }], over);
    assert.deepEqual([r.status, r.body.error], [400, field], JSON.stringify(over));
    const c = await commit(o.DB, [{ pr: 1, head: H1, mark: 0, settled: 1, fields: {} }], over);
    assert.deepEqual([c.status, c.body.error], [400, field], `commit ${JSON.stringify(over)}`);
  }
  for (const b of [-1, 86401, 1.5, '60']) assert.equal((await check(o.DB, [{ pr: 1, head: H1 }], { backstop_s: b })).body.error, 'backstop_s');
  assert.equal((await check(o.DB, [{ pr: 1, head: H1, issue: -3 }])).body.error, 'issue');
  for (const [k, v] of [['mark', -1], ['settled', 2], ['fields', []]]) {
    const c = await commit(o.DB, [{ pr: 1, head: H1, mark: 0, settled: 1, fields: {}, [k]: v }]);
    assert.deepEqual([c.status, c.body.error], [400, k]);
  }
  // items_max comes from the settings row
  o.db.prepare("UPDATE settings SET value = '2' WHERE key = 'unblock.change_marks.items_max'").run();
  const three = [1, 2, 3].map((pr) => ({ pr, head: H1 }));
  assert.equal((await check(o.DB, three)).body.error, 'items_max');
  assert.equal((await check(o.DB, three.slice(0, 2))).status, 200);
  // fields_max_bytes comes from the settings row
  o.db.prepare("UPDATE settings SET value = '20' WHERE key = 'unblock.change_marks.fields_max_bytes'").run();
  const c = await commit(o.DB, [{ pr: 1, head: H1, mark: 0, settled: 1, fields: { rv: 'x'.repeat(30) } }, { pr: 2, head: H1, mark: 0, settled: 1, fields: { fc: true } }]);
  assert.deepEqual([c.status, c.body.stored, c.body.refused], [200, 1, [1]]);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM unblock_change_marks').get().n, 1, 'only the item under the cap is stored');
});

test('W9 the check, the commit and the retention read use their indexes at volume', async (t) => {
  const o = await fresh(t); if (!o) return;
  const db = o.db;
  db.exec('BEGIN');
  const iw = db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 20000; i++) {
    const kind = ['pr', 'issue', 'checks', 'push'][i % 4];
    const m = new Date(Date.parse('2026-11-01T00:00:00Z') + i * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    iw.run(`org/repo-${i % 10}`, kind, String(i % 2000), 'x', m, m);
  }
  const im = db.prepare('INSERT INTO unblock_change_marks (repo, site, pr, head, mark, settled, fields, checked_at) VALUES (?,?,?,?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) im.run(`org/repo-${i % 10}`, i % 2 ? 'queue' : 'review', i, H1, i, 1, '{}', `2026-11-${String(1 + (i % 25)).padStart(2, '0')}T00:00:00Z`);
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
  const keys = JSON.stringify(['1', '2', '3']);
  const checks = [
    ['pr marks', plan(PR_MARKS_SQL, 'org/repo-1', 'org/repo-1', keys), /idx_wakes_dedupe/],
    ['issue marks', plan(ISSUE_MARKS_SQL, 'org/repo-1', 'org/repo-1', keys), /idx_wakes_dedupe/],
    ['stored rows', plan(ROWS_SQL, 'org/repo-1', 'queue', '[1,2,3]'), /ux_unblock_change_marks_key/],
    ['commit', plan(COMMIT_SQL, 'org/repo-1', 'queue', '[]', '2026-11-26T00:00:00Z'), null],
  ];
  const rule = RULES.find((r) => r.rule === 'unblock_change_marks.age');
  assert.ok(rule, 'no unblock_change_marks.age rule in #retention-rules');
  checks.push(['retention ids', plan(rule.ids, '2026-11-10T00:00:00Z', 500), /idx_unblock_change_marks_checked/]);
  for (const [name, details, want] of checks) {
    for (const d of details) assert.doesNotMatch(d, /^SCAN (wakes|unblock_change_marks)\b(?!.*USING (COVERING )?INDEX)/, `${name}: ${d}`);
    if (want) assert.ok(details.some((d) => want.test(d)), `${name} does not use ${want}: ${details.join(' | ')}`);
  }
  for (const d of plan(rule.del, '[1,2]')) assert.doesNotMatch(d, /^SCAN unblock_change_marks\b/, `retention del: ${d}`);
});

test('W10 a check for repo B sees no row of repo A; retention keeps 13 days and deletes 15', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { repo: 'org-a/app', pr: 8, mark: 0 });
  const r = (await check(o.DB, [{ pr: 8, head: H1 }], { repo: 'org-b/app' })).body.items[0];
  assert.deepEqual([r.due, r.reason, r.fields], [true, 'first', {}], 'repo B must read 0 rows of repo A');
  seedRow(o.db, { pr: 50, ago: 15 * 86400 });
  seedRow(o.db, { pr: 51, ago: 13 * 86400 });
  o.db.prepare("UPDATE settings SET value = '0' WHERE key = 'retention.dry_run'").run();
  const run = await worker.fetch(new Request('https://jobs.test/api/retention/run', {
    method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
  }), { DB: o.DB, HARNESS_SECRET: SECRET });
  assert.equal(run.status, 200, await run.clone().text());
  const left = o.db.prepare("SELECT pr FROM unblock_change_marks WHERE repo = 'example-org/cromford' ORDER BY pr").all().map((x) => x.pr);
  assert.deepEqual(left, [51]);
});

test('W11 a pruned wake never lowers the mark; the backstop commit refreshes the row', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { pr: 7, mark: 5, ago: 3700 });
  const r = (await check(o.DB, [{ pr: 7, head: H1 }])).body.items[0];
  assert.deepEqual([r.due, r.reason, r.mark, r.settled], [true, 'backstop', 5, 1]);
  const c = await commit(o.DB, [{ pr: 7, head: H1, mark: r.mark, settled: r.settled, fields: {} }]);
  assert.equal(c.body.stored, 1, 'the backstop commit must refresh the row');
  const r2 = (await check(o.DB, [{ pr: 7, head: H1 }])).body.items[0];
  assert.deepEqual([r2.due, r2.reason], [false, 'quiet']);
  // a head change while the wakes are pruned
  const r3 = (await check(o.DB, [{ pr: 7, head: H2 }])).body.items[0];
  assert.deepEqual([r3.due, r3.reason, r3.mark], [true, 'head', 5]);
  const c3 = await commit(o.DB, [{ pr: 7, head: H2, mark: r3.mark, settled: r3.settled, fields: {} }]);
  assert.equal(c3.body.stored, 1);
  const r4 = (await check(o.DB, [{ pr: 7, head: H2 }])).body.items[0];
  assert.deepEqual([r4.due, r4.reason], [false, 'quiet']);
});

test('W12 a nudge wake on the ticket issue marks the PR once, then it is settled and quiet', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedRow(o.db, { pr: 7, mark: 0, ago: 60 });
  // the shape POST /api/wakes/nudge writes: kind issue, minute 'nudge:<dedupe>'
  const id = Number(o.db.prepare('INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?)')
    .run(REPO, 'issue', '900', 'nudge:untriaged', 'nudge:untriaged-900', isoAgo(30)).lastInsertRowid);
  const r = (await check(o.DB, [{ pr: 7, head: H1, issue: 900 }])).body.items[0];
  assert.deepEqual([r.due, r.reason, r.mark, r.settled], [true, 'wake', id, 1], 'a nudge minute is not the current minute');
  const c = await commit(o.DB, [{ pr: 7, head: H1, mark: r.mark, settled: r.settled, fields: {} }]);
  assert.equal(c.body.stored, 1);
  const r2 = (await check(o.DB, [{ pr: 7, head: H1, issue: 900 }])).body.items[0];
  assert.deepEqual([r2.due, r2.reason], [false, 'quiet'], 'a nudge row must not keep the PR unsettled on every tick');
  // a webhook wake in the current minute beside the nudge is still unsettled
  wake(o.db, { kind: 'issue', key: 900, ago: 0 });
  const r3 = (await check(o.DB, [{ pr: 7, head: H1, issue: 900 }])).body.items[0];
  assert.deepEqual([r3.due, r3.reason, r3.settled], [true, 'wake', 0]);
});

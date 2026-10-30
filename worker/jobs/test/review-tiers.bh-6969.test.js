// BH-6969 (BH-6544.3): GET /api/metrics/review-tiers, the four window reads
// behind the DORA digest's `review` block (bin/dora_review.py reads the body).
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema (worker/jobs/schema.d/), the landing-outcome.bh-6745 idiom.
//   R1 no bearer -> 401
//   R2 seeded rows -> merges, verdicts (lead + risk-tier only), reverts
//      (reverted only), culprits (main_red_attrib only, pr extracted); the
//      window filters; the verdict read reaches 14 days further back; the
//      field names bin/dora_review.py reads are pinned
//   R3 EXPLAIN QUERY PLAN of the four statements at seeded volume: each uses
//      its index, no full scan
//   R4 days clamps (0 -> 1, 500 -> 90, junk -> 7); capped.culprits at the LIMIT
//   R5 the composed schema seeds review.tier_revert_margin = 0.02 and
//      review.tier_revert_min_n = 5
//   R6 a PR parked before the window and merged inside it: the ledger PUT
//      upsert keeps created_at from the first (parked) write, so merged_at is
//      the row's updated_at (bin/merge-sweep.sh parks, bin/lib/mc/settle.sh
//      merges on the same key)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { openVolumeDb, capturingD1, plan, fullScans, isoAgo } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh6969';
const A = 'Org/alpha';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function get(DB, path, { bearer = true } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    headers: bearer ? { authorization: `Bearer ${SECRET}` } : {},
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}
const PATH = '/api/metrics/review-tiers';

// The writers' shapes: a ledgers merge row (key = PR url), a verdicts row
// (bin/lead-verdict.sh), an outcome_metrics row (routes/outcomes.js) and a
// main_red_attrib ledger row (bin/lib/mrb-act.sh _mrb_mapgap, detail.pr int).
function seed(db) {
  const led = db.prepare('INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES (?,?,?,?,?,?)');
  led.run('merge', `https://github.com/${A}/pull/1`, 'merged', null, isoAgo(2), isoAgo(2));
  led.run('merge', `https://github.com/${A}/pull/2`, 'merged', null, isoAgo(24 * 10), isoAgo(24 * 10));   // out of a 7d window
  led.run('merge', `https://github.com/${A}/pull/3`, 'parked', null, isoAgo(2), isoAgo(2));               // not merged
  led.run('pr_state', `https://github.com/${A}/pull/4`, 'merged', null, isoAgo(2), isoAgo(2));            // not a merge row
  led.run('main_red_attrib', `${A}@${H1}`, 'gap', JSON.stringify({ pr: 1, risk_tier: 'low' }), isoAgo(3), isoAgo(3));
  led.run('main_red_attrib', `${A}@${H2}`, 'no-gap', JSON.stringify({ pr: 9 }), isoAgo(24 * 10), isoAgo(24 * 10));  // out
  const v = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, review_tier, review_mode, created_at)
                        VALUES (?,?,?,?,?,?,?,?)`);
  v.run(A, 1, H1, 'MERGE', 'lead', 'medium', 'intent', isoAgo(4));
  v.run(A, 1, H1, 'MERGE', 'risk-tier', 'low', 'risk-tier', isoAgo(3));
  v.run(A, 1, H1, 'BLOCK', 'human', 'medium', 'full', isoAgo(3));          // a human row: not read
  v.run(A, 5, H2, 'MERGE', 'lead', null, null, isoAgo(24 * 18));           // inside days+14 (21d)
  v.run(A, 6, H2, 'MERGE', 'lead', null, null, isoAgo(24 * 25));           // outside it
  const o = db.prepare('INSERT INTO outcome_metrics (repo, pr, outcome, day, evidence, created_at) VALUES (?,?,?,?,?,?)');
  o.run(A, `https://github.com/${A}/pull/1`, 'reverted', isoAgo(24).slice(0, 10), 'revert sha', isoAgo(1));
  o.run(A, `https://github.com/${A}/pull/1`, 'reopened', isoAgo(24).slice(0, 10), 'reopened', isoAgo(1));
  o.run(A, `https://github.com/${A}/pull/7`, 'merged_then_red', isoAgo(24).slice(0, 10), 'red', isoAgo(1));
  o.run(A, `https://github.com/${A}/pull/8`, 'reverted', isoAgo(24).slice(0, 10), 'old', isoAgo(24 * 10));   // out
}

test('R1 no bearer -> 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await get(o.DB, PATH, { bearer: false })).status, 401);
});

test('R2 the four reads: rows in the window, the field names, the 14-day verdict reach', async (t) => {
  const o = await fresh(t); if (!o) return;
  seed(o.db);
  const res = await get(o.DB, `${PATH}?days=7`);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const b = res.body;
  assert.equal(b.days, 7);
  assert.match(b.since, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(Date.parse(b.since) - Date.parse(b.verdict_since), 14 * 86400e3);
  assert.deepEqual(b.merges.map((r) => r.pr_url), [`https://github.com/${A}/pull/1`]);
  assert.deepEqual(Object.keys(b.merges[0]).sort(), ['merged_at', 'pr_url']);
  // lead + risk-tier only, newest first; pr 5 (18 days) is inside the reach, pr 6 (25 days) is not.
  assert.deepEqual(b.verdicts.map((r) => [r.pr, r.source]), [[1, 'risk-tier'], [1, 'lead'], [5, 'lead']]);
  assert.deepEqual(Object.keys(b.verdicts[0]).sort(),
    ['created_at', 'head_sha', 'id', 'pr', 'repo', 'review_mode', 'review_tier', 'source', 'verdict']);
  assert.equal(b.verdicts[0].review_mode, 'risk-tier');
  assert.equal(b.verdicts[2].review_mode, null);
  assert.deepEqual(b.reverts.map((r) => r.pr), [`https://github.com/${A}/pull/1`]);
  assert.deepEqual(Object.keys(b.reverts[0]).sort(), ['created_at', 'outcome', 'pr', 'repo']);
  assert.deepEqual(b.culprits.map((r) => [r.key, r.pr, r.status]), [[`${A}@${H1}`, 1, 'gap']]);
  assert.deepEqual(Object.keys(b.culprits[0]).sort(), ['key', 'pr', 'status', 'updated_at']);
  assert.deepEqual(b.capped, { merges: false, verdicts: false, reverts: false, culprits: false });
});

test('R3 at seeded volume the four statements use their indexes, no full scan', async (t) => {
  const o = await openVolumeDb();
  if (!o) { t.skip('node:sqlite unavailable'); return; }
  const { db } = o;
  db.exec('BEGIN');
  const v = db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, review_tier, review_mode, created_at)
                        VALUES (?,?,?,?,?,?,?,?)`);
  for (let i = 0; i < 20000; i++) {
    v.run(`o/r${i % 13}`, 1 + (i % 4000), i.toString(16).padStart(40, '0'), i % 5 ? 'MERGE' : 'BLOCK',
      ['lead', 'risk-tier', 'human', 'box'][i % 4], ['low', 'medium', 'high'][i % 3], ['full', 'intent', 'risk-tier'][i % 3],
      isoAgo((i % 1440) / 2));
  }
  const om = db.prepare('INSERT INTO outcome_metrics (repo, pr, outcome, day, created_at) VALUES (?,?,?,?,?)');
  for (let i = 0; i < 5000; i++) {
    om.run(`o/r${i % 13}`, String(i), ['reverted', 'reopened', 'merged_then_red'][i % 3], isoAgo(24).slice(0, 10), isoAgo(i % 1440));
  }
  const mr = db.prepare('INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES (?,?,?,?,?,?)');
  for (let i = 0; i < 3000; i++) {
    mr.run('merge', `https://github.com/o/r${i % 13}/pull/${i}`, ['merged', 'parked', 'merged'][i % 3], null,
      isoAgo(i % 1440 + 48), isoAgo(i % 1440));
  }
  for (let i = 0; i < 500; i++) {
    mr.run('main_red_attrib', `o/r${i % 13}@${i.toString(16).padStart(40, '0')}`, 'gap', JSON.stringify({ pr: i + 1 }), isoAgo(i), isoAgo(i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const log = [];
  const res = await worker.fetch(new Request(`https://jobs.test${PATH}?days=7`, { headers: { authorization: `Bearer ${SECRET}` } }),
    { DB: capturingD1(db, log), HARNESS_SECRET: SECRET });
  assert.equal(res.status, 200);
  const want = [
    // TEST-CHANGE (BH-8735): idx_ledgers_kind_status_updated (kind, status,
    // updated_at, key) also serves this kind + status + window read, as a
    // covering index; either index is the index this case asks for.
    [/FROM ledgers\s+WHERE kind='merge'/, 'ledgers', /USING (COVERING )?INDEX idx_ledgers_kind_(status_)?updated /],
    [/FROM verdicts/, 'verdicts', /USING INDEX idx_verdicts_created/],
    [/FROM outcome_metrics/, 'outcome_metrics', /USING INDEX idx_outcome_created/],
    [/FROM ledgers\s+WHERE kind='main_red_attrib'/, 'ledgers', /USING INDEX idx_ledgers_kind_updated/],
  ];
  for (const [re, table, idx] of want) {
    const hits = log.filter((r) => re.test(r.sql));
    assert.equal(hits.length, 1, `${re}: ${log.map((r) => r.sql).join(' | ')}`);
    const lines = plan(db, hits[0].sql, ...hits[0].binds);
    assert.deepEqual(fullScans(lines, [table]), [], lines.join(' | '));
    assert.ok(lines.some((l) => idx.test(l)), `${idx}: ${lines.join(' | ')}`);
  }
});

test('R4 days clamps; capped.culprits is true at the LIMIT and false under it', async (t) => {
  const o = await fresh(t); if (!o) return;
  for (const [q, d] of [['0', 1], ['500', 90], ['junk', 7], ['', 7], ['3', 3]]) {
    const res = await get(o.DB, `${PATH}?days=${q}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.days, d, `days=${q}`);
  }
  assert.equal((await get(o.DB, PATH)).body.days, 7);
  const mr = o.db.prepare('INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES (?,?,?,?,?,?)');
  o.db.exec('BEGIN');
  for (let i = 0; i < 1999; i++) mr.run('main_red_attrib', `o/r@${i.toString(16).padStart(40, '0')}`, 'gap', JSON.stringify({ pr: i + 1 }), isoAgo(1), isoAgo(1));
  o.db.exec('COMMIT');
  const under = await get(o.DB, `${PATH}?days=7`);
  assert.equal(under.body.culprits.length, 1999);
  assert.equal(under.body.capped.culprits, false);
  mr.run('main_red_attrib', `o/r@${'f'.repeat(40)}`, 'gap', JSON.stringify({ pr: 1 }), isoAgo(1), isoAgo(1));
  mr.run('main_red_attrib', `o/r@${'e'.repeat(40)}`, 'gap', JSON.stringify({ pr: 2 }), isoAgo(1), isoAgo(1));
  const over = await get(o.DB, `${PATH}?days=7`);
  assert.equal(over.body.culprits.length, 2000);
  assert.equal(over.body.capped.culprits, true);
  assert.equal(over.body.capped.verdicts, false);
});

test('R5 the composed schema seeds review.tier_revert_margin = 0.02', async (t) => {
  const o = await fresh(t); if (!o) return;
  const row = o.db.prepare("SELECT value, actor FROM settings WHERE key='review.tier_revert_margin'").get();
  assert.ok(row, 'the seed row is missing');
  assert.equal(row.value, '0.02');
  assert.equal(row.actor, 'seed');
  const minN = o.db.prepare("SELECT value, actor FROM settings WHERE key='review.tier_revert_min_n'").get();
  assert.ok(minN, 'the review.tier_revert_min_n seed row is missing');
  assert.equal(minN.value, '5');
  assert.equal(minN.actor, 'seed');
});

test('R6 parked before the window, merged inside it: listed, merged_at is the merge write', async (t) => {
  const o = await fresh(t); if (!o) return;
  const url = `https://github.com/${A}/pull/10`;
  const parkedAt = isoAgo(24 * 10);
  o.db.prepare('INSERT INTO ledgers (kind, key, status, detail, created_at, updated_at) VALUES (?,?,?,?,?,?)')
    .run('merge', url, 'parked', null, parkedAt, parkedAt);
  // The real upsert (routes/ledger.js), as bin/lib/mc/settle.sh writes it.
  const put = await worker.fetch(new Request('https://jobs.test/api/ledger', {
    method: 'PUT',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ kind: 'merge', key: url, status: 'merged' }),
  }), { DB: o.DB, HARNESS_SECRET: SECRET });
  assert.equal(put.status, 200);
  const row = o.db.prepare("SELECT created_at, updated_at FROM ledgers WHERE kind='merge' AND key=?").get(url);
  assert.equal(row.created_at, parkedAt, 'the upsert keeps the first write\'s created_at');
  const res = await get(o.DB, `${PATH}?days=7`);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.merges.map((r) => r.pr_url), [url]);
  assert.equal(res.body.merges[0].merged_at, row.updated_at);
  assert.ok(Date.parse(res.body.merges[0].merged_at) >= Date.parse(res.body.since));
});

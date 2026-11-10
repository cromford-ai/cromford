// BH-9177 (C1 of #9063): the suite ledger's trust row moves from the C0 seed
// `class` to `image` on the first trust read of a DB, and only while the row
// is still that untouched seed (src/lib/suite-trust.js, TRUST_FLIP_SQL).
//
//   F1 a fresh DB from the composed schema: the seed row is class; the first
//      lookup through worker.fetch answers trust image, and the row is image
//      with an actor that names BH-9177
//   F2 an operator's row (class, actor operator): still class, still operator, after
//      the read, and the lookup answers trust class
//   F3 a second read changes nothing (updated_at too); a row put back to the
//      C0 seed flips once more on a new DB binding only
//   F4 (R2-1) a class row the registry seed wrote (actor registry-seed) flips
//      too, and a later POST /api/settings/seed-registry does not revert it
//   F5 the schema stays additive: no schema.d fragment carries the flip
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { readTrustKnob, TRUST_KEY } from '../src/lib/suite-trust.js';

const row = (db) => db.prepare('SELECT value, actor, updated_at FROM settings WHERE key = ?').all(TRUST_KEY);
const lookup = async (DB) => {
  const res = await worker.fetch(new Request('https://jobs.test/api/suite-results/lookup', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer SECRET-fixture' },
    body: JSON.stringify({ repo: 'acme/widget', ctx: 'c', items: [{ suite: 'tests/a.sh', fingerprint: 'a'.repeat(64) }] }),
  }), { DB, HARNESS_SECRET: 'SECRET-fixture' });
  return { status: res.status, body: await res.json() };
};

test('F1 the first lookup flips the C0 seed to image', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable on this runtime');
  assert.deepEqual(row(o.db).map((r) => [r.value, r.actor]), [['class', 'seed']]);
  const r = await lookup(o.DB);
  assert.equal(r.status, 200);
  assert.equal(r.body.trust, 'image');
  const rows = row(o.db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].value, 'image');
  assert.match(rows[0].actor, /BH-9177/);
});

test("F2 an operator's class row is kept", async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable on this runtime');
  o.db.prepare("UPDATE settings SET value = 'class', actor = 'operator', updated_at = '2026-11-07T00:00:00Z' WHERE key = ?").run(TRUST_KEY);
  assert.deepEqual(await readTrustKnob(o.DB), { trust: 'class' });
  assert.deepEqual(row(o.db).map((r) => [r.value, r.actor, r.updated_at]), [['class', 'operator', '2026-11-07T00:00:00Z']]);
  assert.equal((await lookup(o.DB)).body.trust, 'class');
});

test('F3 a second read changes nothing', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable on this runtime');
  assert.deepEqual(await readTrustKnob(o.DB), { trust: 'image' });
  const first = row(o.db);
  o.db.prepare("UPDATE settings SET value = 'class', actor = 'seed' WHERE key = ?").run(TRUST_KEY);
  // The same binding has run its flip: the read answers the row as it is.
  assert.deepEqual(await readTrustKnob(o.DB), { trust: 'class' });
  assert.equal(row(o.db)[0].updated_at, first[0].updated_at);
  // A new binding (a new isolate) over the same rows flips the seed once more.
  assert.deepEqual(await readTrustKnob(d1(o.db)), { trust: 'image' });
});

test('F4 a registry-seed class row flips and the next registry seed keeps image', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable on this runtime');
  o.db.prepare("UPDATE settings SET value = 'class', actor = 'registry-seed', updated_at = '2026-11-07T00:00:00Z' WHERE key = ?").run(TRUST_KEY);
  assert.equal((await lookup(o.DB)).body.trust, 'image');
  const after = row(o.db);
  assert.equal(after.length, 1);
  assert.equal(after[0].value, 'image');
  assert.match(after[0].actor, /BH-9177/);
  const res = await worker.fetch(new Request('https://jobs.test/api/settings/seed-registry', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer SECRET-fixture' },
    body: '{}',
  }), { DB: o.DB, HARNESS_SECRET: 'SECRET-fixture' });
  assert.equal(res.status, 200);
  assert.deepEqual(row(o.db).map((r) => [r.value, r.actor]), [['image', after[0].actor]]);
  assert.deepEqual(await readTrustKnob(d1(o.db)), { trust: 'image' });
});

test('F5 no schema.d fragment carries the flip', () => {
  const dir = new URL('../schema.d/', import.meta.url);
  for (const f of readdirSync(dir)) {
    assert.doesNotMatch(readFileSync(new URL(f, dir), 'utf8'), /suite_reuse_trust'\s*,\s*'image'|SET value\s*=\s*'image'/i, f);
  }
});

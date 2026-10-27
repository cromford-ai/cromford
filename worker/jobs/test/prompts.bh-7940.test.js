// BH-7969 (BH-7940.0): prompt versions and heads. A save is an immutable
// prompt_versions row plus a prompt_heads upsert in one D1 batch; the list
// resolves each kind to the project head, else the fleet head, else the repo
// file. Driven through the REAL router (worker.fetch) on the node:sqlite D1
// shim with the composed schema. Each case opens its own database and uses its
// own project slug.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { missingMarkers } from '../src/lib/prompt-markers.js';
import { PROMPT_KINDS, saveVersion } from '../src/lib/prompt-store.js';
import CATALOG from '../../../catalog/prompt-markers.json' with { type: 'json' };

const SECRET = 'sec-fixture-7969';
// BH-7972 filled the review, plan and rules marker lists: a save of those kinds
// carries its markers (the other four kinds take any body).
const MARK = Object.fromEntries(Object.entries(CATALOG).map(([k, v]) => [k, v.length ? `${v.join('\n')}\n` : '']));

const call = (DB, path, { method = 'GET', body, auth = SECRET } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(auth === null ? {} : { authorization: `Bearer ${auth}` }), 'content-type': 'application/json' },
  body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const q = (p) => (p === undefined ? '' : `?project=${encodeURIComponent(p)}`);
const save = (DB, scope, kind, project, body) => call(DB, `/api/prompts/${scope}/${kind}${q(project)}`, { method: 'POST', body });
const list = (DB, project) => call(DB, `/api/prompts${q(project)}`);
const read = (DB, scope, kind, version, project) => call(DB, `/api/prompts/${scope}/${kind}/${version}${q(project)}`);
const byKind = (r) => Object.fromEntries(r.body.prompts.map((p) => [p.kind, p]));
const count = (db, table) => db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n;

test('BH-7940 prompt store', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('markers-seam: a known kind lists its missing markers; an unknown kind throws', () => {
    for (const k of PROMPT_KINDS) {
      assert.deepEqual(missingMarkers(k, 'any body'), CATALOG[k]);
      assert.deepEqual(missingMarkers(k, `${MARK[k]}any body`), []);
    }
    for (const k of ['watcher', 'execute', 'fix-round', 'qa']) assert.deepEqual(CATALOG[k], []);
    for (const k of ['review', 'plan', 'rules']) assert.ok(CATALOG[k].length > 0, k);
    assert.throws(() => missingMarkers('deploy', 'x'), /unknown prompt kind: deploy/);
    assert.throws(() => missingMarkers('toString', 'x'), /unknown prompt kind/);
  });

  await t.test('missing-marker-422: a body that lacks a catalog marker is refused; nothing written', async () => {
    // The real catalog (BH-7972): review needs TIER: and VERDICT:.
    const { db, DB } = await openDb();
    const r = await save(DB, 'project', 'review', 'demo-marker', { body: 'TIER: 1\nno verdict line', author: 'operator' });
    assert.equal(r.status, 422, JSON.stringify(r.body));
    assert.equal(r.body.error, 'missing_marker');
    assert.deepEqual(r.body.missing, ['VERDICT:']);
    assert.equal(count(db, 'prompt_versions'), 0);
    const ok = await save(DB, 'project', 'review', 'demo-marker', { body: 'TIER: 1\nVERDICT: x', author: 'operator' });
    assert.equal(ok.status, 201, JSON.stringify(ok.body));
  });

  await t.test('save-moves-head: v1 then v2; the head moves; v1 is still readable', async () => {
    const { DB } = await openDb();
    const p = 'demo-save-moves-head';
    const a = await save(DB, 'project', 'watcher', p, { body: 'one', author: 'operator', note: 'first' });
    assert.equal(a.status, 201, JSON.stringify(a.body));
    assert.equal(a.body.version, 1);
    assert.ok(Number.isInteger(a.body.id));
    const b = await save(DB, 'project', 'watcher', p, { body: 'two', author: 'dana' });
    assert.equal(b.status, 201, JSON.stringify(b.body));
    assert.equal(b.body.version, 2);
    const l = await list(DB, p);
    assert.equal(l.status, 200, JSON.stringify(l.body));
    assert.equal(l.body.project, p);
    const w = byKind(l).watcher;
    assert.equal(w.source, 'project');
    assert.equal(w.version, 2);
    assert.equal(w.version_id, b.body.id);
    assert.equal(w.author, 'dana');
    assert.ok(w.set_at);
    const r1 = await read(DB, 'project', 'watcher', 1, p);
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.equal(r1.body.prompt.body, 'one');
    assert.equal(r1.body.prompt.note, 'first');
    assert.equal(r1.body.prompt.author, 'operator');
    const r2 = await read(DB, 'project', 'watcher', 2, p);
    assert.equal(r2.body.prompt.body, 'two');
    assert.equal(r2.body.prompt.note, '');
    // Near misses that must be accepted: a body of only "0" (execute has no
    // markers), a CRLF body (plan, after its markers).
    const z = await save(DB, 'project', 'execute', p, { body: '0', author: 'operator' });
    assert.equal(z.status, 201, JSON.stringify(z.body));
    const z2 = await save(DB, 'project', 'plan', p, { body: `${MARK.plan}0`, author: 'operator' });
    assert.equal(z2.status, 201, JSON.stringify(z2.body));
    const c = await save(DB, 'project', 'plan', p, { body: `${MARK.plan}a\r\nb\r\n`, author: 'operator' });
    assert.equal(c.status, 201, JSON.stringify(c.body));
    assert.equal((await read(DB, 'project', 'plan', 2, p)).body.prompt.body, `${MARK.plan}a\r\nb\r\n`);
    const dotted = await save(DB, 'project', 'qa', 'a.b-c_1', { body: 'x', author: 'operator' });
    assert.equal(dotted.status, 201, JSON.stringify(dotted.body));
  });

  await t.test('empty-body-422: an empty or blank body is refused for every kind; nothing written', async () => {
    const { db, DB } = await openDb();
    for (const kind of ['watcher', 'rules']) {
      for (const body of ['', '  \n']) {
        const r = await save(DB, 'project', kind, 'demo-empty-body', { body, author: 'operator' });
        assert.equal(r.status, 422, `${kind} ${JSON.stringify(body)}: ${JSON.stringify(r.body)}`);
        assert.equal(r.body.error, 'empty_body');
      }
    }
    const f = await save(DB, 'fleet', 'qa', undefined, { body: '\t', author: 'operator' });
    assert.equal(f.status, 422);
    assert.equal(count(db, 'prompt_versions'), 0);
    assert.equal(count(db, 'prompt_heads'), 0);
  });

  await t.test('too-large-413: max+1 bytes refused, exactly max accepted, the settings row sets the max', async () => {
    const { db, DB } = await openDb();
    const p = 'demo-too-large';
    const max = Number(db.prepare("SELECT value FROM settings WHERE key='prompts.body_max_bytes'").get().value);
    assert.equal(max, 262144);
    // "é" is two UTF-8 bytes: the rules markers plus enough "é" (and one "x"
    // when the markers have an odd byte count) is exactly max bytes; one more
    // ASCII byte is over.
    const mb = new TextEncoder().encode(MARK.rules).length;
    const exact = MARK.rules + (mb % 2 ? 'x' : '') + 'é'.repeat(Math.floor((max - mb) / 2));
    assert.equal(new TextEncoder().encode(exact).length, max);
    const over = await save(DB, 'project', 'rules', p, { body: exact + 'x', author: 'operator' });
    assert.equal(over.status, 413, JSON.stringify(over.body).slice(0, 200));
    assert.equal(over.body.error, 'body_too_large');
    assert.equal(over.body.max_bytes, max);
    assert.equal(count(db, 'prompt_versions'), 0);
    const ok = await save(DB, 'project', 'rules', p, { body: exact, author: 'operator' });
    assert.equal(ok.status, 201, JSON.stringify(ok.body).slice(0, 200));
    // The row sets the max: the markers plus 10 bytes.
    db.prepare("UPDATE settings SET value=? WHERE key='prompts.body_max_bytes'").run(String(mb + 10));
    const small = await save(DB, 'project', 'rules', p, { body: `${MARK.rules}ééééé!`, author: 'operator' });
    assert.equal(small.status, 413);
    assert.equal(small.body.max_bytes, mb + 10);
    const fits = await save(DB, 'project', 'rules', p, { body: `${MARK.rules}ééééé`, author: 'operator' });
    assert.equal(fits.status, 201);
  });

  await t.test('bad-scope-400: bad scope, kind, project, version or field; nothing written', async () => {
    const { db, DB } = await openDb();
    const good = { body: 'x', author: 'operator' };
    const cases = [
      ['POST', '/api/prompts/team/watcher?project=demo-bad', good],
      ['POST', '/api/prompts/project/deploy?project=demo-bad', good],
      ['POST', '/api/prompts/project/watcher?project=..%2Fx', good],
      ['POST', '/api/prompts/project/watcher?project=.x', good],
      ['POST', '/api/prompts/project/watcher?project=_fleet', good],
      ['POST', '/api/prompts/project/watcher?project=', good],
      ['POST', '/api/prompts/project/watcher', good],
      ['POST', '/api/prompts/fleet/watcher?project=a', good],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x', author: 'operator', base_version: -1 }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x', author: 'operator', base_version: 1.5 }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x', author: 'operator', base_version: '1' }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 7, author: 'operator' }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x', author: '  ' }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x' }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', { body: 'x', author: 'operator', note: 5 }],
      ['POST', '/api/prompts/project/watcher?project=demo-bad', ['x']],
      ['GET', '/api/prompts/project/watcher/0?project=demo-bad'],
      ['GET', '/api/prompts/project/watcher/abc?project=demo-bad'],
      ['GET', '/api/prompts/team/watcher/1?project=demo-bad'],
      ['GET', '/api/prompts?project=..%2Fx'],
      ['GET', '/api/prompts?project=_fleet'],
    ];
    for (const [method, path, body] of cases) {
      const r = await call(DB, path, { method, body });
      assert.equal(r.status, 400, `${method} ${path} ${JSON.stringify(body)}: ${JSON.stringify(r.body)}`);
      assert.ok(r.body && typeof r.body.error === 'string');
    }
    assert.equal(count(db, 'prompt_versions'), 0);
    assert.equal(count(db, 'prompt_heads'), 0);
  });

  await t.test('no-bearer-401: no bearer and a wrong bearer are refused on all three routes', async () => {
    const { db, DB } = await openDb();
    for (const auth of [null, 'wrong-fixture']) {
      const a = await call(DB, '/api/prompts?project=demo-401', { auth });
      const b = await call(DB, '/api/prompts/project/watcher/1?project=demo-401', { auth });
      const c = await call(DB, '/api/prompts/project/watcher?project=demo-401', { method: 'POST', auth, body: { body: 'x', author: 'operator' } });
      assert.deepEqual([a.status, b.status, c.status], [401, 401, 401]);
    }
    assert.equal(count(db, 'prompt_versions'), 0);
  });

  await t.test('concurrent-save-409: two saves on one base; one wins, one is 409; a stale base is 409', async () => {
    const { db, DB } = await openDb();
    const p = 'demo-concurrent';
    const [a, b] = await Promise.all([
      save(DB, 'project', 'review', p, { body: `${MARK.review}from-a`, author: 'a', base_version: 0 }),
      save(DB, 'project', 'review', p, { body: `${MARK.review}from-b`, author: 'b', base_version: 0 }),
    ]);
    const statuses = [a.status, b.status].sort();
    assert.deepEqual(statuses, [201, 409], `${JSON.stringify(a.body)} ${JSON.stringify(b.body)}`);
    const win = a.status === 201 ? a : b;
    const lose = a.status === 201 ? b : a;
    assert.equal(lose.body.error, 'version_conflict');
    assert.equal(count(db, 'prompt_versions'), 1);
    const head = db.prepare("SELECT version_id FROM prompt_heads WHERE scope='project' AND project=? AND kind='review'").get(p);
    assert.equal(head.version_id, win.body.id);
    // A stale base after v1 is 409 and the head stays.
    const stale = await save(DB, 'project', 'review', p, { body: `${MARK.review}late`, author: 'c', base_version: 0 });
    assert.equal(stale.status, 409);
    assert.equal(count(db, 'prompt_versions'), 1);
    // base_version equal to the current max is accepted.
    const next = await save(DB, 'project', 'review', p, { body: `${MARK.review}v2`, author: 'c', base_version: 1 });
    assert.equal(next.status, 201, JSON.stringify(next.body));
    assert.equal(next.body.version, 2);
    // The head moved back to v1 by hand while v2 exists; a failed stale save must not move it.
    db.prepare("UPDATE prompt_heads SET version_id=? WHERE scope='project' AND project=? AND kind='review'").run(win.body.id, p);
    const stale2 = await save(DB, 'project', 'review', p, { body: `${MARK.review}late2`, author: 'c', base_version: 1 });
    assert.equal(stale2.status, 409);
    const after = db.prepare("SELECT version_id FROM prompt_heads WHERE scope='project' AND project=? AND kind='review'").get(p);
    assert.equal(after.version_id, win.body.id);
    assert.equal(count(db, 'prompt_versions'), 2);
  });

  await t.test('unique-throw-409: a D1 UNIQUE error is 409; any other error rethrows', async () => {
    const { db } = await openDb();
    const real = d1(db);
    const stub = (err) => ({ prepare: (s) => real.prepare(s), batch: async () => { throw err; } });
    const args = { scope: 'project', project: 'demo-unique', kind: 'rules', body: `${MARK.rules}x`, author: 'operator' };
    const r = await saveVersion({ DB: stub(new Error('D1_ERROR: UNIQUE constraint failed: prompt_versions.scope, prompt_versions.project, prompt_versions.kind, prompt_versions.version: SQLITE_CONSTRAINT')) }, args);
    assert.ok(r instanceof Response);
    assert.equal(r.status, 409);
    assert.equal((await r.json()).error, 'version_conflict');
    await assert.rejects(saveVersion({ DB: stub(new Error('boom')) }, args), /boom/);
  });

  await t.test('wrong-project-isolated: an override on A does not reach B', async () => {
    const { DB } = await openDb();
    const A = 'demo-iso-a', B = 'demo-iso-b';
    const a = await save(DB, 'project', 'watcher', A, { body: 'A only', author: 'operator' });
    assert.equal(a.status, 201);
    assert.equal(byKind(await list(DB, B)).watcher.source, 'repo');
    assert.equal(byKind(await list(DB, A)).watcher.source, 'project');
    const f = await save(DB, 'fleet', 'watcher', undefined, { body: 'fleet', author: 'operator' });
    assert.equal(f.status, 201, JSON.stringify(f.body));
    const lb = byKind(await list(DB, B)).watcher;
    assert.equal(lb.source, 'fleet');
    assert.equal(lb.version_id, f.body.id);
    const la = byKind(await list(DB, A)).watcher;
    assert.equal(la.source, 'project');
    assert.equal(la.version_id, a.body.id);
    const rb = await read(DB, 'project', 'watcher', 1, B);
    assert.equal(rb.status, 404);
    assert.equal(rb.body.error, 'not_found');
  });

  await t.test('fleet-and-repo: no heads is seven repo rows; fleet then project wins; partial match stays repo', async () => {
    const { DB } = await openDb();
    const p = 'demo-fleet-repo';
    const empty = await list(DB, p);
    assert.equal(empty.status, 200);
    assert.deepEqual(empty.body.prompts.map((r) => r.kind), [...PROMPT_KINDS]);
    assert.deepEqual(PROMPT_KINDS, ['rules', 'watcher', 'plan', 'execute', 'review', 'fix-round', 'qa']);
    for (const r of empty.body.prompts) {
      assert.deepEqual([r.source, r.version, r.version_id, r.author, r.set_at], ['repo', null, null, null, null]);
    }
    const f = await save(DB, 'fleet', 'rules', undefined, { body: `${MARK.rules}fleet rules`, author: 'operator' });
    assert.equal(byKind(await list(DB, p)).rules.source, 'fleet');
    // The fleet list (no project) shows fleet and repo only.
    const fl = await list(DB, undefined);
    assert.equal(fl.status, 200);
    assert.equal(byKind(fl).rules.source, 'fleet');
    assert.equal(byKind(fl).rules.version_id, f.body.id);
    const pr = await save(DB, 'project', 'rules', p, { body: `${MARK.rules}project rules`, author: 'operator' });
    const l = byKind(await list(DB, p));
    assert.equal(l.rules.source, 'project');
    assert.equal(l.rules.version_id, pr.body.id);
    await save(DB, 'project', 'plan', p, { body: `${MARK.plan}plan`, author: 'operator' });
    const l2 = byKind(await list(DB, p));
    assert.equal(l2.plan.source, 'project');
    assert.equal(l2.watcher.source, 'repo');
    // A fleet-scope read uses no project.
    const fr = await read(DB, 'fleet', 'rules', 1, undefined);
    assert.equal(fr.status, 200);
    assert.equal(fr.body.prompt.body, `${MARK.rules}fleet rules`);
    assert.equal(fr.body.prompt.project, '');
  });

  await t.test('schema-not-applied-503: a missing table is 503, never an empty list', async () => {
    const { db, DB } = await openDb();
    db.exec('DROP TABLE prompt_heads');
    const r = await list(DB, 'demo-503');
    assert.equal(r.status, 503, JSON.stringify(r.body));
    assert.match(r.body.error, /schema not applied/);
  });

  await t.test('statement-count: list 1, version read 1, save = batch of 2 + 1 read + at most 1 settings read', async () => {
    const { db } = await openDb();
    const inner = d1(db);
    let n = 0;
    const DB = { prepare: (s) => { n++; return inner.prepare(s); }, batch: (s) => inner.batch(s) };
    const p = 'demo-count';
    n = 0; const s = await save(DB, 'project', 'watcher', p, { body: 'x', author: 'operator' });
    assert.equal(s.status, 201);
    assert.ok(n >= 3 && n <= 4, `save prepared ${n}`);
    n = 0; await list(DB, p);
    assert.equal(n, 1);
    n = 0; await read(DB, 'project', 'watcher', 1, p);
    assert.equal(n, 1);
  });
});

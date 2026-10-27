// BH-7936: the onboarding tracker test routes (src/routes/onboarding-tracker.js).
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema, an in-memory KV fake for ONBOARD_KV and a recorder over every D1
// prepare/bind, so the order "KV first, then D1" and "no field value in D1" are
// measured, not assumed.
//   F1-F3 each kind files one tracker-test hub-probe row and answers 202
//   F4 the KV row has a 900 s TTL       F5 0 D1 statements before the put; no value in D1
//   F6 a blank required field is 400     F7 no KV binding is 503   F8 a KV put that throws is 503
//   F9 bad site / api_base / kind / short secret / unknown field is 400
//   F10 GET maps pending/claimed/pass/fail and never returns a field value
//   F11 a failed D1 insert deletes the KV row and answers 503
//   W1 take answers the fields once, then 404   W2 claim + result + GET round trip
//   E1 the GET lookup uses the unique index
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7936';
const S = 'SENTINEL-7936-fixture';
const FIELDS = {
  linear: { api_key: `lin_api_${S}`, team: 'CRO', label: 'ai-build' },
  jira: {
    site: 'sandbox-example.atlassian.net', email: `bot-${S}@example.com`, api_token: `jira-${S}`,
    project_key: 'CROM', status_map: 'todo=To Do;in_progress=In Progress;review=In Review;closed=Done'
  },
  board: { api_base: 'https://board.example.com/api/board', token: `board-${S}` }
};
const REQUIRED = {
  linear: ['api_key', 'team', 'label'],
  jira: ['site', 'email', 'api_token', 'project_key', 'status_map'],
  board: ['api_base', 'token']
};

function kvFake(events, { throwOnPut = false } = {}) {
  const store = new Map();
  return {
    store,
    puts: [],
    async put(k, v, opts) {
      events.push({ kind: 'kv.put', k });
      if (throwOnPut) throw new Error('kv down');
      this.puts.push({ k, v, opts });
      store.set(k, v);
    },
    async get(k) { events.push({ kind: 'kv.get', k }); return store.has(k) ? store.get(k) : null; },
    async delete(k) { events.push({ kind: 'kv.delete', k }); store.delete(k); }
  };
}

// Every prepare and bind lands in `events`, in order with the KV calls.
function recorded(DB, events) {
  return {
    prepare(sql) {
      events.push({ kind: 'd1.prepare', sql });
      const st = DB.prepare(sql);
      const wrap = {
        bind(...v) { events.push({ kind: 'd1.bind', v }); st.bind(...v); return wrap; },
        first: (...a) => st.first(...a),
        all: (...a) => st.all(...a),
        run: (...a) => st.run(...a)
      };
      return wrap;
    },
    batch: (s) => DB.batch(s)
  };
}

async function world(t, kvOpts) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const events = [];
  const KV = kvOpts === null ? undefined : kvFake(events, kvOpts);
  const env = { DB: recorded(o.DB, events), HARNESS_SECRET: SECRET };
  if (KV) env.ONBOARD_KV = KV;
  return { ...o, events, KV, env };
}

async function call(w, method, path, body, { auth = `Bearer ${SECRET}` } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = auth;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), w.env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const d1Events = (w) => w.events.filter((e) => e.kind.startsWith('d1.'));
const start = (w, kind, fields = FIELDS[kind], project = 'newproj') =>
  call(w, 'POST', '/api/onboarding/tracker-test', { project, kind, fields });

for (const kind of ['linear', 'jira', 'board']) {
  test(`F1-F3 ${kind}: 202 with a 32-hex test_id and one tracker-test hub-probe row`, async (t) => {
    const w = await world(t); if (!w) return;
    const r = await start(w, kind);
    assert.equal(r.status, 202, JSON.stringify(r.body));
    assert.match(r.body.test_id, /^[0-9a-f]{32}$/);
    const rows = w.db.prepare('SELECT * FROM hub_probe_requests').all();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].probe, 'tracker-test');
    assert.equal(rows[0].project, 'newproj');
    assert.equal(rows[0].ticket_key, `onb-${r.body.test_id}`);
    assert.equal(rows[0].status, 'pending');
    assert.deepEqual(JSON.parse(rows[0].args_json), [kind, r.body.test_id]);
  });
}

test('F4 the fields go to ONE KV row onb-tracker:<id> with expirationTtl 900, trimmed', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await start(w, 'linear', { ...FIELDS.linear, team: '  CRO ' });
  assert.equal(r.status, 202);
  assert.equal(w.KV.puts.length, 1);
  const p = w.KV.puts[0];
  assert.equal(p.k, `onb-tracker:${r.body.test_id}`);
  assert.equal(p.opts.expirationTtl, 900);
  const v = JSON.parse(p.v);
  assert.equal(v.kind, 'linear');
  assert.equal(v.project, 'newproj');
  assert.equal(v.fields.api_key, FIELDS.linear.api_key);
  assert.equal(v.fields.team, 'CRO');
});

test('F5 0 D1 statements before the KV put, and no SQL text or bound value holds a field value', async (t) => {
  for (const kind of ['linear', 'jira', 'board']) {
    const w = await world(t); if (!w) return;
    const r = await start(w, kind);
    assert.equal(r.status, 202);
    const putAt = w.events.findIndex((e) => e.kind === 'kv.put');
    const firstD1 = w.events.findIndex((e) => e.kind.startsWith('d1.'));
    assert.ok(putAt >= 0, 'a KV put happened');
    assert.ok(firstD1 > putAt, `${kind}: the first D1 statement (${firstD1}) comes after the put (${putAt})`);
    const d1 = JSON.stringify(d1Events(w));
    for (const v of Object.values(FIELDS[kind])) {
      if (v.length >= 4) assert.equal(d1.includes(v), false, `${kind}: D1 saw ${v}`);
    }
    assert.equal(d1.includes(S), false);
    const row = JSON.stringify(w.db.prepare('SELECT * FROM hub_probe_requests').all());
    assert.equal(row.includes(S), false);
  }
});

test('F6 a missing, blank or whitespace-only required field is 400 naming it; no KV put, no D1', async (t) => {
  for (const kind of Object.keys(REQUIRED)) {
    for (const f of REQUIRED[kind]) {
      for (const bad of [undefined, '', '   ']) {
        const w = await world(t); if (!w) return;
        const fields = { ...FIELDS[kind] };
        if (bad === undefined) delete fields[f]; else fields[f] = bad;
        const r = await start(w, kind, fields);
        assert.equal(r.status, 400, `${kind}.${f}=${JSON.stringify(bad)}`);
        assert.equal(r.body.error, `${f} is required`, `${kind}.${f}=${JSON.stringify(bad)}`);
        assert.equal(w.KV.puts.length, 0);
        assert.equal(d1Events(w).length, 0);
      }
    }
  }
});

test('F7 no ONBOARD_KV binding: 503, 0 D1 statements', async (t) => {
  const w = await world(t, null); if (!w) return;
  const r = await start(w, 'linear');
  assert.equal(r.status, 503);
  assert.match(r.body.error, /KV not bound/);
  assert.equal(d1Events(w).length, 0);
  const take = await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce: 'a'.repeat(32) });
  assert.equal(take.status, 503);
});

test('F8 a KV put that throws: 503, 0 D1 statements', async (t) => {
  const w = await world(t, { throwOnPut: true }); if (!w) return;
  const r = await start(w, 'jira');
  assert.equal(r.status, 503);
  assert.equal(d1Events(w).length, 0);
  assert.equal(JSON.stringify(r.body).includes(S), false);
});

test('F9 refused inputs: 400, no KV put', async (t) => {
  const cases = [
    ['github-issues', {}],
    ['Linear', FIELDS.linear],
    ['jira', { ...FIELDS.jira, site: 'acme.atlassian.net.evil.example' }],
    ['jira', { ...FIELDS.jira, site: 'https://acme.atlassian.net' }],
    ['jira', { ...FIELDS.jira, site: 'acme.atlassian.net/../x' }],
    ['jira', { ...FIELDS.jira, site: 'localhost' }],
    ['jira', { ...FIELDS.jira, project_key: 'crom' }],
    ['jira', { ...FIELDS.jira, status_map: 'todo=To Do;oops' }],
    ['jira', { ...FIELDS.jira, email: 'not-an-email' }],
    ['board', { ...FIELDS.board, api_base: 'http://board.example.com/api/board' }],
    ['board', { ...FIELDS.board, api_base: 'https://169.254.169.254/latest' }],
    ['board', { ...FIELDS.board, api_base: 'https://10.0.0.5/api' }],
    ['board', { ...FIELDS.board, api_base: 'https://127.0.0.1/api' }],
    ['board', { ...FIELDS.board, api_base: 'https://localhost/api' }],
    ['board', { ...FIELDS.board, api_base: 'https://[::1]/api' }],
    ['board', { ...FIELDS.board, api_base: 'https://u:p@board.example.com/api' }],
    ['board', { ...FIELDS.board, token: 'short' }],
    ['linear', { ...FIELDS.linear, team: 'C R O' }],
    ['linear', { ...FIELDS.linear, extra: 'x' }],
    ['linear', { ...FIELDS.linear, team: 7 }]
  ];
  for (const [kind, fields] of cases) {
    const w = await world(t); if (!w) return;
    const r = await start(w, kind, fields);
    assert.equal(r.status, 400, `${kind} ${JSON.stringify(fields)}`);
    assert.equal(w.KV.puts.length, 0);
  }
  const w = await world(t); if (!w) return;
  assert.equal((await start(w, 'linear', FIELDS.linear, 'bad project')).status, 400);
  assert.equal((await call(w, 'POST', '/api/onboarding/tracker-test', { project: 'p', kind: 'linear', fields: 'x' })).status, 400);
  // An upper-case site is lower-cased first, then accepted.
  const up = await start(w, 'jira', { ...FIELDS.jira, site: 'Sandbox-Example.Atlassian.NET' });
  assert.equal(up.status, 202);
  assert.equal(JSON.parse(w.KV.puts[0].v).fields.site, 'sandbox-example.atlassian.net');
});

test('F0 the routes sit behind the bearer', async (t) => {
  const w = await world(t); if (!w) return;
  assert.equal((await call(w, 'POST', '/api/onboarding/tracker-test', { project: 'p', kind: 'linear', fields: FIELDS.linear }, { auth: null })).status, 401);
  assert.equal((await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce: 'a'.repeat(32) }, { auth: 'Bearer tok-fixture-wrong' })).status, 401);
  assert.equal(w.KV.puts.length, 0);
});

test('W1 take answers the fields once, then 404; a bad nonce is 400', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await start(w, 'board');
  const a = await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce: r.body.test_id });
  assert.equal(a.status, 200);
  assert.equal(a.body.kind, 'board');
  assert.equal(a.body.project, 'newproj');
  assert.deepEqual(a.body.fields, FIELDS.board);
  const b = await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce: r.body.test_id });
  assert.equal(b.status, 404);
  for (const nonce of ['A'.repeat(32), 'a'.repeat(31), '../x', 7]) {
    assert.equal((await call(w, 'POST', '/api/onboarding/tracker-secret/take', { nonce })).status, 400);
  }
});

test('F10/W2 the GET answers pending, then ok or the error text, and never a field value', async (t) => {
  const w = await world(t); if (!w) return;
  const r = await start(w, 'jira');
  const id = r.body.test_id;
  const get = (p = 'newproj', i = id) => call(w, 'GET', `/api/onboarding/tracker-test/${i}?project=${p}`);
  let g = await get();
  assert.equal(g.status, 200);
  assert.equal(g.body.state, 'pending');
  const claim = await call(w, 'POST', '/api/hub-probe/claim', { claimed_by: 'hub', n: 5 });
  assert.equal(claim.body.rows.length, 1);
  g = await get();
  assert.equal(g.body.state, 'pending', 'claimed is still pending to the sheet');
  await call(w, 'POST', '/api/hub-probe/result', { id: claim.body.rows[0].id, result: 'fail', http_status: 401, output: 'FAIL list\njira: GET /rest/api/3/search/jql answered 401' });
  g = await get();
  assert.equal(g.body.state, 'error');
  assert.match(g.body.error, /answered 401/);
  assert.equal(JSON.stringify(g.body).includes(S), false);

  const r2 = await start(w, 'linear');
  const c2 = await call(w, 'POST', '/api/hub-probe/claim', { claimed_by: 'hub', n: 5 });
  await call(w, 'POST', '/api/hub-probe/result', { id: c2.body.rows[0].id, result: 'pass', http_status: 200, output: 'ok list=2 dry-write=ok' });
  const g2 = await get('newproj', r2.body.test_id);
  assert.equal(g2.body.state, 'ok');
  assert.equal(g2.body.detail, 'ok list=2 dry-write=ok');

  assert.equal((await get('otherproj')).status, 404, 'the wrong project finds nothing');
  assert.equal((await get('newproj', 'b'.repeat(32))).status, 404);
  assert.equal((await get('newproj', 'nothex')).status, 404, 'a non-hex id does not match the route');
  assert.equal((await call(w, 'GET', `/api/onboarding/tracker-test/${id}`)).status, 400, 'project is required');
});

test('F11 a hub-probe insert that fails deletes the KV row and answers 503', async (t) => {
  const w = await world(t); if (!w) return;
  w.db.exec('DROP TABLE hub_probe_requests');
  const r = await start(w, 'linear');
  assert.equal(r.status, 503);
  assert.equal(w.KV.puts.length, 1);
  assert.equal(w.KV.store.size, 0, 'the orphan credential is gone');
});

test('E1 the GET lookup is served by the unique (project, ticket_key, probe, args_hash) index', async (t) => {
  const w = await world(t); if (!w) return;
  const ins = w.db.prepare("INSERT INTO hub_probe_requests (project, ticket_key, probe, args_json, args_hash, requested_at) VALUES (?,?,?,?,?,?)");
  for (let i = 0; i < 3000; i++) ins.run(`p${i % 20}`, `BH-${i}`, 'd1-count', '[]', `h${i}`, '2026-10-20T00:00:00Z');
  const { TEST_LOOKUP_SQL } = await import('../src/routes/onboarding-tracker.js');
  const plan = w.db.prepare(`EXPLAIN QUERY PLAN ${TEST_LOOKUP_SQL}`).all('p1', 'onb-x', 'tracker-test').map((r) => r.detail).join(' | ');
  assert.match(plan, /USING INDEX sqlite_autoindex_hub_probe_requests/);
  assert.doesNotMatch(plan, /SCAN hub_probe_requests/);
});

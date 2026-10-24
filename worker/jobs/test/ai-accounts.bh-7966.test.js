// BH-7966 (BH-7937.2): the AI account rows and the envelope status route.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own database and seeds its own envelopes (fresh
// uuids), so no case depends on another or on order.
//   L1 label rule (refuse / accept, no echo)    E1-E10 envelope binding
//   D1 D2 duplicate = 409                        W1-W4 write counts per exit
//   G1-G5 the list: projects, order, boxes, limit knob
//   C1-C4 today's spend window                   S1-S9 state from the newest event
//   O1 envelope + account, then the list says pending
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import * as MOD from '../src/routes/ai-accounts.js';

const SECRET = 'tok-fixture-bh7966-main';
const HUB = 'tok-fixture-bh7966-hub';
const bytes = (n, k) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 37 + k) & 255));
const CT = bytes(256, 13).toString('base64');
const NOW_MS = Date.parse('2026-10-23T12:00:00Z');
const NOW = '2026-10-23T12:00:00Z';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  return o;
}
function call(DB, method, path, { body, hubHeader } = {}) {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  if (hubHeader) headers['x-envelope-hub-token'] = hubHeader;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET, ENVELOPE_HUB_TOKEN: HUB })
    .then(async (res) => {
      const text = await res.text();
      let json = null; try { json = JSON.parse(text); } catch { json = null; }
      return { status: res.status, headers: res.headers, text, body: json };
    });
}
async function envelope(DB, scope) {
  const r = await call(DB, 'POST', '/api/secrets/envelope', { body: { scope, ciphertext: CT } });
  assert.equal(r.status, 200, `envelope ${scope}: ${r.text}`);
  return r.body.id;
}
const addAccount = (DB, body) => call(DB, 'POST', '/api/ai-accounts', { body });
async function account(DB, { vendor = 'openrouter', label = 'team-a', use_kind = 'pool', project, plan } = {}) {
  const scope = `ai-account:${vendor}:${label}:${use_kind}${project ? ':' + project : ''}`;
  const envelope_id = await envelope(DB, scope);
  const r = await addAccount(DB, { vendor, label, use_kind, envelope_id, plan });
  assert.equal(r.status, 200, `account ${scope}: ${r.text}`);
  return { id: r.body.id, envelope_id };
}
const list = (DB) => call(DB, 'GET', '/api/ai-accounts');
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM ai_accounts').get().n;
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-23T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const event = (db, envelopeId, ev) => db.prepare(
  "INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?, 'ai-account:x', ?, NULL, ?)"
).run(envelopeId, ev, NOW);
let costSeq = 0;
const cost = (db, label, ts, usd) => db.prepare(
  "INSERT INTO cost_rows (box, row_hash, line_no, ts, auth_account, cost_usd, inserted_at) VALUES ('box-fixture', ?, 1, ?, ?, ?, ?)"
).run(`h-${++costSeq}`, ts, label, usd, NOW);
const byLabel = (body, vendor, label) => body.accounts.find((a) => a.vendor === vendor && a.label === label);

const REFUSE = ['sk-x', 'SK-proj-1', 'sk_live1', 'xai-abc123', 'fw_abc', 'or-abc', 'team..a', 'Team-A', 'team:a',
  'a'.repeat(49), 'shared', '', '   ', '.hidden'];
const ACCEPT = ['team-a', 'skate', 'ops.1', 'a@b', 'b'.repeat(48), 'x'];

test('L1 the label rule: each refusal is a 400 that does not echo the label, each accept is a 200', async (t) => {
  const o = await fresh(t); if (!o) return;
  const anyId = await envelope(o.DB, 'ai-account:openrouter:team-z:pool');
  for (const label of REFUSE) {
    const r = await addAccount(o.DB, { vendor: 'openrouter', label, use_kind: 'pool', envelope_id: anyId });
    assert.equal(r.status, 400, `accepted ${JSON.stringify(label)}`);
    if (label.trim()) assert.ok(!r.text.includes(label), `the 400 echoes ${JSON.stringify(label)}`);
    // A pasted token is named as one, in any case (SK-proj-1 too).
    if (/^(sk|xai|fw|or)[-_]/i.test(label)) assert.match(r.body.error, /looks like a token/, label);
    assert.equal(MOD.checkAiAccountLabel(label).ok, false, `checkAiAccountLabel accepted ${JSON.stringify(label)}`);
  }
  assert.equal(count(o.db), 0, 'no refusal writes a row');
  for (const label of ACCEPT) {
    await account(o.DB, { vendor: 'claude', label });
    assert.equal(MOD.checkAiAccountLabel(label).ok, true, label);
  }
  assert.equal(count(o.db), ACCEPT.length);
});

test('E1-E10 the envelope must exist and its scope must name this vendor, label and use kind', async (t) => {
  const o = await fresh(t); if (!o) return;
  const base = { vendor: 'openrouter', label: 'team-a', use_kind: 'pool' };
  const refuse = [
    ['E1 unknown uuid', { ...base, envelope_id: crypto.randomUUID() }],
    ['E2 tracker envelope', { ...base, envelope_id: await envelope(o.DB, 'tracker:x') }],
    ['E3 another vendor', { ...base, envelope_id: await envelope(o.DB, 'ai-account:claude:team-a:pool') }],
    ['E4 prefix near miss', { ...base, envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-ab:pool') }],
    ['E5 project scope sent as pool', { ...base, envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:project:demo') }],
    ['E6 not a uuid', { ...base, envelope_id: 'not-a-uuid' }],
    ['E7 pool with a project segment', { ...base, envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:pool:demo') }],
    ['E8 project with no project', { ...base, use_kind: 'project', envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:project') }],
    ['E8b bad vendor', { ...base, vendor: 'openai', envelope_id: await envelope(o.DB, 'ai-account:openai:team-a:pool') }],
    ['E8c bad use kind', { ...base, use_kind: 'spare', envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:spare') }],
    ['E8d plan too long', { ...base, plan: 'p'.repeat(65), envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:pool') }],
  ];
  for (const [name, body] of refuse) {
    const r = await addAccount(o.DB, body);
    assert.equal(r.status, 400, `${name}: ${r.text}`);
    assert.ok(!r.text.includes('ai-account:'), `${name}: the 400 echoes a scope`);
  }
  assert.equal(count(o.db), 0, 'no refusal writes a row');
  // E9 pool and project accept.
  const pool = await addAccount(o.DB, { ...base, envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:pool') });
  assert.equal(pool.status, 200, pool.text);
  assert.equal(pool.body.state, 'pending');
  assert.match(pool.body.id, /^[0-9a-f-]{36}$/);
  const proj = await addAccount(o.DB, { vendor: 'claude', label: 'team-a', use_kind: 'project', envelope_id: await envelope(o.DB, 'ai-account:claude:team-a:project:demo') });
  assert.equal(proj.status, 200, proj.text);
  // E10 an envelope the hub already read (the row is gone, its stored event stays).
  const id = await envelope(o.DB, 'ai-account:xai:ops.1:fallback');
  const read = await call(o.DB, 'GET', `/api/secrets/envelope/${id}`, { hubHeader: HUB });
  assert.equal(read.status, 200);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelopes WHERE id=?').get(id).n, 0);
  const late = await addAccount(o.DB, { vendor: 'xai', label: 'ops.1', use_kind: 'fallback', envelope_id: id });
  assert.equal(late.status, 200, late.text);
  // created_by: a console stamp is kept, anything else is `api`.
  const cb = (i) => o.db.prepare('SELECT created_by FROM ai_accounts WHERE id=?').get(i).created_by;
  assert.equal(cb(pool.body.id), 'api');
  const stamped = await addAccount(o.DB, { vendor: 'fireworks', label: 'fw-team', use_kind: 'pool', created_by: 'console:operator@example.com', envelope_id: await envelope(o.DB, 'ai-account:fireworks:fw-team:pool') });
  assert.equal(cb(stamped.body.id), 'console:operator@example.com');
  const forged = await addAccount(o.DB, { vendor: 'codex', label: 'cx', use_kind: 'pool', created_by: 'root; drop', envelope_id: await envelope(o.DB, 'ai-account:codex:cx:pool') });
  assert.equal(cb(forged.body.id), 'api');
});

test('D1 D2 a second (vendor,label) is 409, a revoked label too, and the row count stays 1', async (t) => {
  const o = await fresh(t); if (!o) return;
  const first = await account(o.DB);
  const again = await addAccount(o.DB, { vendor: 'openrouter', label: 'team-a', use_kind: 'pool', envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:pool') });
  assert.equal(again.status, 409);
  assert.match(again.body.error, /label is taken/);
  assert.equal(count(o.db), 1);
  const rv = await call(o.DB, 'POST', `/api/ai-accounts/${first.id}/revoke`);
  assert.equal(rv.status, 200);
  const third = await addAccount(o.DB, { vendor: 'openrouter', label: 'team-a', use_kind: 'pool', envelope_id: await envelope(o.DB, 'ai-account:openrouter:team-a:pool') });
  assert.equal(third.status, 409, 'a revoked label stays taken');
  assert.equal(count(o.db), 1);
  // The same label on another vendor is a different account.
  await account(o.DB, { vendor: 'claude' });
  assert.equal(count(o.db), 2);
});

test('W1-W4 revoke stamps once and keeps the row; a repeat writes nothing; an unknown id is 404', async (t) => {
  const o = await fresh(t); if (!o) return;
  const a = await account(o.DB);
  const evBefore = o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelope_events').get().n;
  const r1 = await call(o.DB, 'POST', `/api/ai-accounts/${a.id}/revoke`);
  assert.equal(r1.status, 200);
  assert.equal(r1.body.revoked_at, NOW);
  const row = () => o.db.prepare('SELECT revoked_at FROM ai_accounts WHERE id=?').get(a.id);
  assert.equal(row().revoked_at, NOW);
  t.mock.timers.tick(60e3);
  const r2 = await call(o.DB, 'POST', `/api/ai-accounts/${a.id}/revoke`);
  assert.equal(r2.status, 200);
  assert.equal(r2.body.already, true);
  assert.equal(row().revoked_at, NOW, 'the second revoke does not move the stamp');
  assert.equal(count(o.db), 1, 'revoke never deletes');
  const r3 = await call(o.DB, 'POST', `/api/ai-accounts/${crypto.randomUUID()}/revoke`);
  assert.equal(r3.status, 404);
  assert.equal(o.db.prepare('SELECT COUNT(*) AS n FROM secret_envelope_events').get().n, evBefore, 'the account routes write no event');
  const g = await list(o.DB);
  assert.equal(byLabel(g.body, 'openrouter', 'team-a').state, 'revoked');
});

test('G1-G4 the list: projects per label, vendor,label order, boxes from the registry or null', async (t) => {
  const o = await fresh(t); if (!o) return;
  await account(o.DB, { vendor: 'openrouter', label: 'team-a' });
  await account(o.DB, { vendor: 'claude', label: 'zeta' });
  await account(o.DB, { vendor: 'claude', label: 'alpha', plan: 'max' });
  setting(o.db, 'account.demo', 'team-a');
  setting(o.db, 'account.beta-os', 'team-a');
  setting(o.db, 'account.other', 'zeta');
  setting(o.db, 'account.pooled', 'shared');
  const reg = o.db.prepare("INSERT INTO registry_box_accounts (account, kind, box, updated_at) VALUES (?,?,?,?)");
  reg.run('team-a', 'login', 'box-a', NOW);
  reg.run('team-a', 'login', 'box-b', NOW);
  reg.run('team-a', 'jobs', 'box-c', NOW);
  const g = await list(o.DB);
  assert.equal(g.status, 200, g.text);
  assert.equal(g.headers.get('cache-control'), 'no-store');
  assert.deepEqual(g.body.accounts.map((a) => `${a.vendor}/${a.label}`), ['claude/alpha', 'claude/zeta', 'openrouter/team-a']);
  const ta = byLabel(g.body, 'openrouter', 'team-a');
  assert.deepEqual(ta.projects, ['beta-os', 'demo']);
  assert.equal(ta.boxes, 2, 'login rows only, distinct boxes');
  assert.equal(ta.state, 'pending');
  assert.equal(ta.use_kind, 'pool');
  assert.deepEqual(byLabel(g.body, 'claude', 'zeta').projects, ['other']);
  assert.equal(byLabel(g.body, 'claude', 'alpha').boxes, null, 'no registry row = unknown, not 0');
  assert.equal(byLabel(g.body, 'claude', 'alpha').plan, 'max');
  assert.deepEqual(byLabel(g.body, 'claude', 'alpha').projects, []);
  assert.equal(g.body.limit, 500);
  assert.equal(g.body.truncated, false);
  for (const a of g.body.accounts) {
    for (const k of Object.keys(a)) assert.ok(!/cipher|token|scope/.test(k), `the list carries ${k}`);
  }
});

test('G5 the list cap is the ai_accounts_list_limit row; 0 or abc fall back to 500', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal(o.db.prepare("SELECT value FROM settings WHERE key='ai_accounts_list_limit'").get().value, '500');
  for (const l of ['a1', 'a2', 'a3']) await account(o.DB, { label: l });
  setting(o.db, 'ai_accounts_list_limit', 2);
  let g = await list(o.DB);
  assert.equal(g.body.accounts.length, 2);
  assert.equal(g.body.limit, 2);
  assert.equal(g.body.truncated, true);
  for (const bad of ['0', 'abc', '5001', '-3']) {
    setting(o.db, 'ai_accounts_list_limit', bad);
    g = await list(o.DB);
    assert.equal(g.status, 200);
    assert.equal(g.body.limit, 500, bad);
    assert.equal(g.body.accounts.length, 3, bad);
    assert.equal(g.body.truncated, false);
  }
});

test('C1-C4 today = cost_rows of this label since 00:00Z of the request day', async (t) => {
  const o = await fresh(t); if (!o) return;
  await account(o.DB, { label: 'team-a' });
  await account(o.DB, { label: 'idle' });
  cost(o.db, 'team-a', '2026-10-22T23:59:59Z', 100);   // C1 yesterday: out
  cost(o.db, 'team-a', '2026-10-23T00:00:00Z', 1.25);  // C2 midnight: in
  cost(o.db, 'team-a', '2026-10-23T11:00:00Z', 0.5);
  cost(o.db, 'other', '2026-10-23T11:00:00Z', 9);      // C3 another label: out
  const g = await list(o.DB);
  assert.equal(byLabel(g.body, 'openrouter', 'team-a').today, 1.75);
  assert.equal(byLabel(g.body, 'openrouter', 'idle').today, 0, 'C4 no row today is a measured 0');
  assert.equal(MOD.todayStartZ('2026-10-23T12:00:00Z'), '2026-10-23T00:00:00Z');
});

test('S1-S9 state follows the newest event of the account envelope; revoked wins', async (t) => {
  const o = await fresh(t); if (!o) return;
  const st = (label) => list(o.DB).then((g) => byLabel(g.body, 'openrouter', label).state);
  const status = (id) => call(o.DB, 'GET', `/api/secrets/envelope/${id}/status`);
  // S1 stored -> pending
  const a = await account(o.DB, { label: 's1' });
  assert.equal(await st('s1'), 'pending');
  let s = await status(a.envelope_id);
  assert.equal(s.status, 200);
  assert.deepEqual(Object.keys(s.body), ['state']);
  assert.equal(s.body.state, 'pending');
  assert.equal(s.headers.get('cache-control'), 'no-store');
  // S2 consumed -> pending on the list, consumed on status
  await call(o.DB, 'GET', `/api/secrets/envelope/${a.envelope_id}`, { hubHeader: HUB });
  assert.equal(await st('s1'), 'pending');
  assert.equal((await status(a.envelope_id)).body.state, 'consumed');
  // S3 applied -> active
  event(o.db, a.envelope_id, 'applied');
  assert.equal(await st('s1'), 'active');
  assert.equal((await status(a.envelope_id)).body.state, 'applied');
  // S4 a later apply_failed -> failed
  event(o.db, a.envelope_id, 'apply_failed');
  assert.equal(await st('s1'), 'failed');
  assert.equal((await status(a.envelope_id)).body.state, 'apply_failed');
  // S5 expired -> expired
  const b = await account(o.DB, { label: 's5' });
  event(o.db, b.envelope_id, 'expired');
  assert.equal(await st('s5'), 'expired');
  assert.equal((await status(b.envelope_id)).body.state, 'expired');
  // S6 another envelope's events never count
  const c = await account(o.DB, { label: 's6' });
  const stranger = await envelope(o.DB, 'ai-account:openrouter:nobody:pool');
  event(o.db, stranger, 'applied');
  assert.equal(await st('s6'), 'pending');
  // S7 revoked wins over applied
  event(o.db, c.envelope_id, 'applied');
  await call(o.DB, 'POST', `/api/ai-accounts/${c.id}/revoke`);
  assert.equal(await st('s6'), 'revoked');
  // S8 stored, and the envelope is past expires_at -> expired on status
  const d = await account(o.DB, { label: 's8' });
  t.mock.timers.tick(901e3);
  assert.equal((await status(d.envelope_id)).body.state, 'expired');
  // S9 no event -> 404 on status (a uuid nobody stored), and the ciphertext never shows
  const none = await status(crypto.randomUUID());
  assert.equal(none.status, 404);
  assert.ok(!(await status(d.envelope_id)).text.includes(CT.slice(0, 40)));
  // accountStateFrom, the pure rule
  assert.equal(MOD.accountStateFrom(null, null), 'unknown');
  assert.equal(MOD.accountStateFrom('stored', null), 'pending');
  assert.equal(MOD.accountStateFrom('applied', '2026-10-23T00:00:00Z'), 'revoked');
});

test('O1 an envelope POST, then the account POST, then GET lists openrouter / team-a as pending', async (t) => {
  const o = await fresh(t); if (!o) return;
  const id = await envelope(o.DB, 'ai-account:openrouter:team-a:pool');
  const r = await addAccount(o.DB, { vendor: 'openrouter', label: 'team-a', use_kind: 'pool', envelope_id: id });
  assert.equal(r.status, 200);
  const g = await list(o.DB);
  const row = byLabel(g.body, 'openrouter', 'team-a');
  assert.ok(row, 'the new account is listed');
  assert.equal(row.state, 'pending');
  assert.equal(row.id, r.body.id);
});

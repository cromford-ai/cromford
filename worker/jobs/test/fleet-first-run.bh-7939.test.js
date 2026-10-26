// BH-7977 (BH-7939.3): GET /api/fleet/first-run, the one-statement read that
// tells the console whether a new fleet still misses a required account.
// Driven through the REAL worker.fetch on node:sqlite with the composed jobs
// schema. Each case opens its own database and seeds its own rows, so no case
// depends on another or on order.
//   R1 all three required, no more_ai: complete true, the field set
//   R2 anthropic = a non-revoked claude row; more_ai = any other vendor
//   R3 github_app.installed trimmed '1'      R4 telegram bot_present + chat_id
//   R5 one statement per GET                 R6 the first_run.gate seed
//   R7 PUT /api/settings first_run.gate=0 reads back gate:false
//   R8 no ai_accounts table = 503 naming the schema; R-AUTH no bearer = 401
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7977-main';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const GATE_FRAGMENT = readdirSync(SCHEMA_D).find((f) => /^\d{12}-bh-7977-first-run-gate\.sql$/.test(f));
const FIELDS = ['anthropic', 'github_app', 'telegram', 'more_ai', 'complete', 'gate'];

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
async function call(DB, method, path, { body, bearer = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (bearer) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (method !== 'GET') init.body = JSON.stringify(body ?? {});
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch { json = null; }
  return { status: res.status, headers: res.headers, text, body: json };
}
const firstRun = (DB) => call(DB, 'GET', '/api/fleet/first-run');
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-25T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));
const unset = (db, key) => db.prepare('DELETE FROM settings WHERE key=?').run(key);
let accSeq = 0;
const account = (db, vendor, { revoked = false } = {}) => db.prepare(
  "INSERT INTO ai_accounts (id, vendor, label, plan, use_kind, envelope_id, created_by, created_at, revoked_at) VALUES (?, ?, ?, NULL, 'pool', NULL, 'api', '2026-10-25T00:00:00Z', ?)"
).run(`acc-fixture-${++accSeq}`, vendor, `label-fixture-${accSeq}`, revoked ? '2026-10-25T01:00:00Z' : null);
// The three required accounts, present.
function allRequired(db) {
  account(db, 'claude');
  setting(db, 'github_app.installed', '1');
  setting(db, 'telegram.bot_present', '1');
  setting(db, 'telegram.chat_id', '12345');
}

test('R1 all three required and no more_ai: 200, complete true, more_ai false, each field a boolean', async (t) => {
  const o = await fresh(t); if (!o) return;
  allRequired(o.db);
  setting(o.db, 'first_run.gate', '1');
  const r = await firstRun(o.DB);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  for (const k of FIELDS) assert.equal(typeof r.body[k], 'boolean', `${k} is not a boolean: ${r.text}`);
  assert.equal(r.body.anthropic, true);
  assert.equal(r.body.github_app, true);
  assert.equal(r.body.telegram, true);
  assert.equal(r.body.more_ai, false);
  assert.equal(r.body.complete, true, 'more_ai false must never make complete false');
  assert.equal(r.body.gate, true);
});

test('R1b one required account missing: complete false', async (t) => {
  const o = await fresh(t); if (!o) return;
  allRequired(o.db);
  unset(o.db, 'github_app.installed');
  const r = await firstRun(o.DB);
  assert.equal(r.body.github_app, false);
  assert.equal(r.body.complete, false);
});

test('R2 anthropic is a non-revoked claude row; another vendor is more_ai and never anthropic', async (t) => {
  {
    const o = await fresh(t); if (!o) return;
    account(o.db, 'claude');
    const r = await firstRun(o.DB);
    assert.equal(r.body.anthropic, true);
    assert.equal(r.body.more_ai, false);
  }
  {
    const o = await fresh(t); if (!o) return;
    account(o.db, 'claude', { revoked: true });
    const r = await firstRun(o.DB);
    assert.equal(r.body.anthropic, false, 'a revoked claude row is not an account');
  }
  {
    const o = await fresh(t); if (!o) return;
    account(o.db, 'codex');
    const r = await firstRun(o.DB);
    assert.equal(r.body.anthropic, false);
    assert.equal(r.body.more_ai, true);
    assert.equal(r.body.complete, false);
  }
  for (const v of ['openrouter', 'fireworks', 'xai']) {
    const o = await fresh(t); if (!o) return;
    account(o.db, v);
    account(o.db, 'codex', { revoked: true });
    assert.equal((await firstRun(o.DB)).body.more_ai, true, v);
  }
  {
    const o = await fresh(t); if (!o) return;
    account(o.db, 'codex', { revoked: true });
    assert.equal((await firstRun(o.DB)).body.more_ai, false, 'a revoked codex row is not an account');
  }
});

test('R3 github_app is the row github_app.installed, trimmed, exactly 1', async (t) => {
  const cases = [['1', true], [' 1', true], ['1 ', true], ['0', false], ['yes', false], ['11', false], [null, false]];
  for (const [value, want] of cases) {
    const o = await fresh(t); if (!o) return;
    if (value !== null) setting(o.db, 'github_app.installed', value);
    assert.equal((await firstRun(o.DB)).body.github_app, want, `github_app.installed=${JSON.stringify(value)}`);
  }
});

test('R4 telegram needs bot_present trimmed 1 AND a non-blank chat_id', async (t) => {
  const cases = [
    ['1', '12345', true], [' 1 ', '-100123', true], ['1', '', false], ['1', '   ', false],
    ['0', '12345', false], ['true', '12345', false], ['11', '12345', false],
    [null, '12345', false], ['1', null, false],
  ];
  for (const [bot, chat, want] of cases) {
    const o = await fresh(t); if (!o) return;
    account(o.db, 'claude');
    setting(o.db, 'github_app.installed', '1');
    // The settings PUT refuses an empty value, but a raw D1 write can leave
    // one, so '' is seeded straight into the table.
    if (bot !== null) setting(o.db, 'telegram.bot_present', bot);
    if (chat !== null) setting(o.db, 'telegram.chat_id', chat);
    const r = await firstRun(o.DB);
    assert.equal(r.body.telegram, want, `bot_present=${JSON.stringify(bot)} chat_id=${JSON.stringify(chat)}`);
    assert.equal(r.body.complete, want, 'telegram is required');
  }
});

test('R5 one GET runs exactly one statement', async (t) => {
  const o = await fresh(t); if (!o) return;
  allRequired(o.db);
  const inner = d1(o.db);
  let prepares = 0;
  let batches = 0;
  const DB = {
    prepare(sql) { prepares += 1; return inner.prepare(sql); },
    async batch(s) { batches += 1; return inner.batch(s); },
  };
  const r = await firstRun(DB);
  assert.equal(r.status, 200, r.text);
  assert.equal(prepares, 1, 'one prepare() per GET');
  assert.equal(batches, 0, 'no batch');
});

test('R6 the first_run.gate fragment seeds 1 on a new fleet and 0 on a fleet with jobs or projects', async (t) => {
  assert.ok(GATE_FRAGMENT, 'no <stamp>-bh-7977-first-run-gate.sql fragment');
  const names = readdirSync(SCHEMA_D).sort();
  assert.ok(names.indexOf(GATE_FRAGMENT) > names.indexOf('0000-base.sql'), 'the fragment must sort after 0000-base.sql (jobs, settings)');
  assert.ok(names.indexOf(GATE_FRAGMENT) > names.indexOf('0002-base-rest.sql'), 'the fragment must sort after 0002-base-rest.sql (projects)');
  const sql = readFileSync(new URL(GATE_FRAGMENT, SCHEMA_D), 'utf8');
  const gate = (db) => db.prepare("SELECT value FROM settings WHERE key='first_run.gate'").get()?.value ?? null;
  {
    const o = await fresh(t); if (!o) return;
    assert.equal(gate(o.db), '1', 'a fresh DB is a new fleet');
    assert.equal((await firstRun(o.DB)).body.gate, true);
    // A re-apply is a no-op: INSERT OR IGNORE keeps what is there.
    o.db.prepare("INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES ('job-fixture-1','p-fixture','build','box-fixture','plan','running','2026-10-25T00:00:00Z','2026-10-25T00:00:00Z')").run();
    o.db.exec(sql);
    assert.equal(gate(o.db), '1', 're-applying the fragment must not change the row');
    unset(o.db, 'first_run.gate');
    o.db.exec(sql);
    assert.equal(gate(o.db), '0', 'a fleet with a jobs row is an existing fleet');
    assert.equal((await firstRun(o.DB)).body.gate, false);
  }
  {
    const o = await fresh(t); if (!o) return;
    o.db.prepare("INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('p-fixture','o/r-fixture',0,'2026-10-25T00:00:00Z','2026-10-25T00:00:00Z')").run();
    unset(o.db, 'first_run.gate');
    o.db.exec(sql);
    assert.equal(gate(o.db), '0', 'a fleet with a projects row is an existing fleet');
  }
  {
    // No row (the fragment not applied) is the code fallback: gate false.
    const o = await fresh(t); if (!o) return;
    unset(o.db, 'first_run.gate');
    assert.equal((await firstRun(o.DB)).body.gate, false);
    for (const v of ['yes', 'true', '2', '0']) {
      setting(o.db, 'first_run.gate', v);
      assert.equal((await firstRun(o.DB)).body.gate, false, `gate=${v}`);
    }
    setting(o.db, 'first_run.gate', ' 1 ');
    assert.equal((await firstRun(o.DB)).body.gate, true);
  }
});

test('R7 PUT /api/settings first_run.gate=0 reads back as gate:false through the route', async (t) => {
  const o = await fresh(t); if (!o) return;
  assert.equal((await firstRun(o.DB)).body.gate, true);
  const put = await call(o.DB, 'PUT', '/api/settings', { body: { key: 'first_run.gate', value: '0', reason: 'fixture: keep the list' } });
  assert.equal(put.status, 200, put.text);
  assert.equal((await firstRun(o.DB)).body.gate, false);
});

test('R8 with no ai_accounts table the route is a 503 that names the schema; R-AUTH no bearer is 401', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.exec('DROP TABLE ai_accounts');
  const r = await firstRun(o.DB);
  assert.equal(r.status, 503, r.text);
  assert.equal(r.body.error, 'ai_accounts schema not applied');
  const o2 = await fresh(t); if (!o2) return;
  const anon = await call(o2.DB, 'GET', '/api/fleet/first-run', { bearer: false });
  assert.equal(anon.status, 401);
});

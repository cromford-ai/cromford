// BH-10532: the Jira and Linear receivers check the secret and the signature
// header SHAPE before they read the body, then read the body under a cap
// (settings rows webhook.jira.max_body_bytes / webhook.linear.max_body_bytes,
// read from memory by bodyCapOf(env, vendor)), then run the unchanged HMAC.
// Every case goes through the REAL worker.fetch onto the real composed schema
// in node:sqlite. Zero network: no outbound call exists on these routes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { settingsRows } from '../src/lib/settings-cache.js';
import { WEBHOOK_MAX_BODY_BYTES, bodyCapOf } from '../src/lib/webhook-receiver.js';
import { trackerPreCheck } from '../src/lib/tracker-webhooks.js';

const S = { github: 'gh-10532', jira: 'jira-10532', linear: 'linear-10532' };
const REPO = 'Example-Org/bh10532-repo';
const hmac = (secret, raw) => createHmac('sha256', secret).update(raw).digest('hex');
const SIG_HEADER = { github: 'x-hub-signature-256', jira: 'x-hub-signature', linear: 'linear-signature' };
const sigOf = (vendor, secret, raw) => (vendor === 'linear' ? '' : 'sha256=') + hmac(secret, raw);
const HEX64 = 'a'.repeat(64);

async function setup(t, { settings = {}, env: extra = {}, secrets = S } = {}) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const rows = { 'webhook_route.jira.crom': REPO, 'webhook_route.linear.eng': REPO, ...settings };
  for (const [k, v] of Object.entries(rows)) {
    o.db.prepare('INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)')
      .run(k, v, 'test', 'test', '2026-11-28T00:00:00Z');
  }
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer-10532', ...extra };
  if (secrets.github !== undefined) env.GITHUB_WEBHOOK_SECRET = secrets.github;
  if (secrets.jira !== undefined) env.JIRA_WEBHOOK_SECRET = secrets.jira;
  if (secrets.linear !== undefined) env.LINEAR_WEBHOOK_SECRET = secrets.linear;
  const count = (table) => o.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
  const wakes = () => o.db.prepare('SELECT repo, kind, key, event FROM wakes ORDER BY id').all().map((r) => ({ ...r }));
  return { ...o, env, count, wakes };
}

// A body stream that records whether anyone pulled from it. start() enqueues
// nothing, so the only way to get bytes is pull().
function tracked(raw) {
  const st = { pulled: false };
  const enc = new TextEncoder().encode(raw);
  const stream = new ReadableStream({
    pull(ctl) { st.pulled = true; ctl.enqueue(enc); ctl.close(); },
  }, { highWaterMark: 0 });
  return { st, stream };
}

// opts: { sig (exact header value, null = no header), headers, stream }
async function send(ctx, vendor, raw, opts = {}) {
  const headers = { 'content-type': 'application/json', ...(vendor === 'github' ? { 'x-github-event': 'issues' } : {}), ...(opts.headers || {}) };
  const sig = 'sig' in opts ? opts.sig : sigOf(vendor, S[vendor], raw);
  if (sig !== null) headers[SIG_HEADER[vendor]] = sig;
  const { st, stream } = tracked(raw);
  const res = await worker.fetch(new Request(`https://jobs.test/webhooks/${vendor}`, {
    method: 'POST', headers, body: stream, duplex: 'half',
  }), ctx.env);
  return { status: res.status, body: await res.json().catch(() => null), pulled: st.pulled };
}

const jiraComment = (key = 'CROM-12') => ({
  webhookEvent: 'comment_created', issue: { key }, comment: { id: '1', author: { accountId: 'client-acct' } },
});
const linIssueUpdate = (ident = 'ENG-5') => ({
  type: 'Issue', action: 'update', actor: { id: 'client-user' },
  data: { id: 'lin-1', identifier: ident }, updatedFrom: { stateId: 's-old' },
  url: `https://linear.app/example/issue/${ident}/a-title`,
  webhookTimestamp: Date.now(), // determinism: ok the route compares it with its own clock
});
const validPayload = { jira: jiraComment, linear: linIssueUpdate };
// A valid JSON object of exactly n bytes (pad field grows to fit).
function padded(vendor, n) {
  const base = { ...validPayload[vendor](), pad: '' };
  const len = Buffer.byteLength(JSON.stringify(base));
  assert.ok(n >= len, `padded: ${n} < ${len}`);
  const raw = JSON.stringify({ ...base, pad: 'p'.repeat(n - len) });
  assert.equal(Buffer.byteLength(raw), n);
  return raw;
}

// ── P1 / P2: the pre-read guard ─────────────────────────────────────────────
const JIRA_ROWS = [
  ['secret unset', { secret: undefined, sig: 'sha256=' + HEX64 }, 503],
  ['secret empty', { secret: '', sig: 'sha256=' + HEX64 }, 503],
  ['header absent', { sig: null }, 401],
  ['header empty', { sig: '' }, 401],
  ['64 hex, no sha256= prefix', { sig: HEX64 }, 401],
  ['sha256= + 63 hex', { sig: 'sha256=' + 'a'.repeat(63) }, 401],
  ['sha256= + 64 UPPERCASE hex', { sig: 'sha256=' + 'A'.repeat(64) }, 401],
  ['sha1= + 40 hex', { sig: 'sha1=' + 'a'.repeat(40) }, 401],
  ['two values', { sig: `sha256=${HEX64},sha256=${HEX64}` }, 401],
];
const LINEAR_ROWS = [
  ['secret unset', { secret: undefined, sig: HEX64 }, 503],
  ['header absent', { sig: null }, 401],
  ['sha256= + 64 hex (Jira format)', { sig: 'sha256=' + HEX64 }, 401],
  ['65 hex', { sig: 'a'.repeat(65) }, 401],
];

for (const [vendor, rows, tag] of [['jira', JIRA_ROWS, 'P1'], ['linear', LINEAR_ROWS, 'P2']]) {
  test(`${tag} ${vendor} pre-read table: 503/401 with the body never read and no row written`, async (t) => {
    for (const [name, row, want] of rows) {
      const secrets = { ...S, [vendor]: 'secret' in row ? row.secret : S[vendor] };
      const ctx = await setup(t, { secrets }); if (!ctx) return;
      const raw = JSON.stringify(validPayload[vendor]());
      const r = await send(ctx, vendor, raw, { sig: row.sig });
      assert.equal(r.status, want, `${vendor} ${name}: ${JSON.stringify(r.body)}`);
      assert.equal(r.pulled, false, `${vendor} ${name}: body was read`);
      if (want === 503) assert.match(r.body.error, new RegExp(`${vendor.toUpperCase()}_WEBHOOK_SECRET unset`));
      if (want === 401) assert.equal(r.body.error, 'bad signature');
      assert.equal(ctx.count('wakes'), 0, name);
      assert.equal(ctx.count('webhook_deliveries'), 0, name);
    }
  });
}

test('P1/P2 the right shape passes to the read; a wrong secret is still the HMAC 401', async (t) => {
  for (const vendor of ['jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const raw = JSON.stringify(validPayload[vendor]());
    const r = await send(ctx, vendor, raw, { sig: sigOf(vendor, 'wrong-secret', raw) });
    assert.equal(r.status, 401, vendor);
    assert.equal(r.body.error, 'bad signature');
    assert.equal(r.pulled, true, `${vendor}: shape ok so the body is read`);
    assert.equal(ctx.count('wakes'), 0);
    assert.equal(ctx.count('webhook_deliveries'), 0);
  }
});

test('P3 trackerPreCheck decision table (pure)', () => {
  const h = (o) => new Headers(o);
  const env = { JIRA_WEBHOOK_SECRET: 'j', LINEAR_WEBHOOK_SECRET: 'l' };
  assert.equal(trackerPreCheck(env, 'jira', h({ 'x-hub-signature': 'sha256=' + HEX64 })), null);
  assert.equal(trackerPreCheck(env, 'linear', h({ 'linear-signature': HEX64 })), null);
  assert.deepEqual(trackerPreCheck({}, 'jira', h({ 'x-hub-signature': 'sha256=' + HEX64 })),
    { status: 503, error: 'webhook receiver not configured (JIRA_WEBHOOK_SECRET unset)' });
  assert.deepEqual(trackerPreCheck({}, 'linear', h({ 'linear-signature': HEX64 })),
    { status: 503, error: 'webhook receiver not configured (LINEAR_WEBHOOK_SECRET unset)' });
  assert.deepEqual(trackerPreCheck(env, 'jira', h({})), { status: 401, error: 'bad signature' });
  assert.deepEqual(trackerPreCheck(env, 'linear', h({ 'linear-signature': 'sha256=' + HEX64 })), { status: 401, error: 'bad signature' });
  assert.equal(trackerPreCheck(env, 'github', h({})).status, 500);
});

// ── B1-B3: the capped read ──────────────────────────────────────────────────
for (const vendor of ['jira', 'linear']) {
  test(`B1 ${vendor}: a validly signed body of fallback cap + 1 bytes is 413, no row`, async (t) => {
    const ctx = await setup(t); if (!ctx) return;
    const raw = 'z'.repeat(WEBHOOK_MAX_BODY_BYTES + 1);
    const r = await send(ctx, vendor, raw);
    assert.equal(r.status, 413, JSON.stringify(r.body));
    assert.equal(r.body.error, 'payload too large');
    assert.equal(r.body.cap, WEBHOOK_MAX_BODY_BYTES);
    assert.equal(ctx.count('wakes'), 0);
    assert.equal(ctx.count('webhook_deliveries'), 0);
  });

  test(`B2 ${vendor}: a Content-Length over the cap is 413 with no read`, async (t) => {
    const ctx = await setup(t); if (!ctx) return;
    const raw = JSON.stringify(validPayload[vendor]());
    const r = await send(ctx, vendor, raw, { headers: { 'content-length': String(WEBHOOK_MAX_BODY_BYTES + 1) } });
    assert.equal(r.status, 413, JSON.stringify(r.body));
    assert.equal(r.pulled, false);
    assert.equal(ctx.count('wakes'), 0);
  });

  test(`B3 ${vendor}: row webhook.${vendor}.max_body_bytes=1024 in the snapshot: 1025 bytes is 413, 1024 bytes is a wake`, async (t) => {
    const ctx = await setup(t, { settings: { [`webhook.${vendor}.max_body_bytes`]: '1024' }, env: { SETTINGS_CACHE_TTL_S: '30' } });
    if (!ctx) return;
    await settingsRows(ctx.env);
    const over = await send(ctx, vendor, padded(vendor, 1025));
    assert.equal(over.status, 413, JSON.stringify(over.body));
    assert.equal(over.body.cap, 1024);
    assert.equal(ctx.count('wakes'), 0);
    const ok = await send(ctx, vendor, padded(vendor, 1024));
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(ctx.count('wakes'), 1);
  });
}

// ── C1-C4: bodyCapOf(env, vendor) ───────────────────────────────────────────
test('C1 no snapshot: every vendor (and an unknown one) gets the fallback', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  assert.equal(bodyCapOf(ctx.env, 'jira'), WEBHOOK_MAX_BODY_BYTES);
  assert.equal(bodyCapOf(ctx.env, 'linear'), WEBHOOK_MAX_BODY_BYTES);
  assert.equal(bodyCapOf(ctx.env, 'nope'), WEBHOOK_MAX_BODY_BYTES);
  assert.equal(bodyCapOf(ctx.env), WEBHOOK_MAX_BODY_BYTES);
});

test('C2 a row is read per vendor: jira 2048 and github 1024 do not leak into each other', async (t) => {
  const ctx = await setup(t, {
    settings: { 'webhook.jira.max_body_bytes': '2048', 'webhook.github.max_body_bytes': '1024' },
    env: { SETTINGS_CACHE_TTL_S: '30' },
  });
  if (!ctx) return;
  await settingsRows(ctx.env);
  assert.equal(bodyCapOf(ctx.env, 'jira'), 2048);
  assert.equal(bodyCapOf(ctx.env, 'linear'), 5242880); // the seeded row
  assert.equal(bodyCapOf(ctx.env), 1024);
  assert.equal(bodyCapOf(ctx.env, 'github'), 1024);
});

test('C3 a jira row out of 1024..26214400 or not a whole number uses the fallback', async (t) => {
  for (const v of ['1023', '26214401', 'abc', '2e6', '0']) {
    const ctx = await setup(t, { settings: { 'webhook.jira.max_body_bytes': v }, env: { SETTINGS_CACHE_TTL_S: '30' } });
    if (!ctx) return;
    await settingsRows(ctx.env);
    assert.equal(bodyCapOf(ctx.env, 'jira'), WEBHOOK_MAX_BODY_BYTES, `row ${v}`);
  }
});

test('C4 the composed schema seeds both rows with 5242880', async (t) => {
  const { DatabaseSync } = await import('node:sqlite').catch(() => ({}));
  if (!DatabaseSync) { t.skip('node:sqlite unavailable'); return; }
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  for (const v of ['jira', 'linear']) {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(`webhook.${v}.max_body_bytes`);
    assert.equal(row && row.value, '5242880', v);
  }
});

// ── V1: a valid delivery under the cap is today's behavior ──────────────────
test('V1 a valid signed delivery under the cap: one wake, one delivery row, per vendor', async (t) => {
  const want = {
    jira: { repo: REPO, kind: 'issue', key: 'CROM-12', event: 'jira.comment_created' },
    linear: { repo: REPO, kind: 'issue', key: 'ENG-5', event: 'linear.issue.update' },
  };
  const did = { jira: 'x-atlassian-webhook-identifier', linear: 'linear-delivery' };
  for (const vendor of ['jira', 'linear']) {
    const ctx = await setup(t); if (!ctx) return;
    const r = await send(ctx, vendor, JSON.stringify(validPayload[vendor]()), { headers: { [did[vendor]]: `bh10532-${vendor}-1` } });
    assert.equal(r.status, 200, `${vendor}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.vendor, vendor);
    assert.deepEqual(ctx.wakes(), [want[vendor]], vendor);
    assert.equal(ctx.count('webhook_deliveries'), 1, vendor);
  }
});

// ── G1: GitHub unchanged ────────────────────────────────────────────────────
test('G1 github keeps its order: unsigned 401, over the cap 413', async (t) => {
  const ctx = await setup(t); if (!ctx) return;
  const a = await send(ctx, 'github', '{}', { sig: null });
  assert.equal(a.status, 401);
  const b = await send(ctx, 'github', 'z'.repeat(WEBHOOK_MAX_BODY_BYTES + 1));
  assert.equal(b.status, 413);
  assert.equal(b.body.cap, WEBHOOK_MAX_BODY_BYTES);
});

// ── N1: no unbounded read left on the routes ────────────────────────────────
test('N1 routes/webhooks.js holds no req.text( call', () => {
  const src = readFileSync(fileURLToPath(new URL('../src/routes/webhooks.js', import.meta.url)), 'utf8');
  assert.equal(src.includes('req.text('), false);
});

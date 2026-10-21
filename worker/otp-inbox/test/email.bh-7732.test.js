// BH-7732: the otp inbox Email Worker. The REAL default export's email()
// handler, driven with a local message object shaped like Cloudflare's
// ForwardableEmailMessage ({from, to, headers, raw, rawSize}), writing to the
// harness-jobs D1 on node:sqlite with the composed jobs schema. No network.
//   E1 one row with the parsed fields       E2 a second delivery writes no row
//   E3 same Message-ID, second recipient    E4 too large: body never read
//   E5 no log line holds a code (own run)   E6 a failed insert rejects, 0 rows
//   E7 round trip: email() then the jobs worker's GET /api/otp
//   E8 every fixture stores the status and code the matcher gives it
//   E9 no Message-ID: the fp: id is stable across two deliveries
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { openDb, d1 } from '../../jobs/test/lib/d1-sqlite.bh-1030.js';

const mod = await import('../src/index.js').catch((e) => ({ loadError: e }));
const inbox = mod.default;
const FIX = new URL('./fixtures/', import.meta.url);
const SECRET = 'tok-fixture-bh7732';
// The fixtures are stored with LF lines; real mail arrives with CRLF.
const eml = (name) => new Uint8Array(Buffer.from(readFileSync(new URL(name, FIX), 'utf8').replace(/\r?\n/g, '\r\n'), 'utf8'));
const FIXTURE_CODES = ['482913', '730415', '551820', '391027', 'K7Q2ZP'];

// A message as Email Routing hands it to the worker. `to` and `from` are the
// SMTP envelope; headers come from the raw message.
function message(name, { to = 'bot@otp.example.test', from = 'noreply@vendor.example.test', rawSize, onRead } = {}) {
  const bytes = eml(name);
  const head = Buffer.from(bytes).toString('utf8').split('\r\n\r\n')[0];
  const headers = new Headers();
  for (const line of head.replace(/\r\n[ \t]+/g, ' ').split('\r\n')) {
    const i = line.indexOf(':');
    if (i > 0) headers.append(line.slice(0, i).trim(), line.slice(i + 1).trim());
  }
  return {
    from, to, headers, rawSize: rawSize ?? bytes.length,
    get raw() { if (onRead) onRead(); return new Response(bytes).body; },
    setReject() { throw new Error('setReject is not called by this worker'); },
  };
}

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  assert.equal(mod.loadError, undefined, `worker/otp-inbox/src/index.js loads: ${mod.loadError}`);
  assert.equal(typeof inbox?.email, 'function', 'the default export has email()');
  return o;
}
const rows = (db) => db.prepare('SELECT * FROM otp_messages ORDER BY id').all();

// capture(fn) — every console line written while fn runs.
async function capture(fn) {
  const lines = [];
  const keep = {};
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) {
    keep[k] = console[k];
    console[k] = (...a) => lines.push(a.map(String).join(' '));
  }
  try { await fn(); } catch (e) { lines.push(`THROWN ${e && e.message}`); throw e; } finally { Object.assign(console, keep); }
  return lines;
}
const ALL_LINES = [];

test('E1 code-plain.eml writes exactly one row with recipient, sender, subject, the code and received_at', async (t) => {
  const o = await fresh(t); if (!o) return;
  const lines = await capture(() => inbox.email(message('code-plain.eml', { to: ' Bot@OTP.Example.Test ', from: 'NoReply@Vendor.Example.Test' }), { DB: o.DB }));
  ALL_LINES.push(...lines);
  const x = rows(o.db);
  assert.equal(x.length, 1);
  assert.equal(x[0].recipient, 'bot@otp.example.test');
  assert.equal(x[0].sender, 'noreply@vendor.example.test');
  assert.equal(x[0].subject, 'Your Acme sign-in');
  assert.equal(x[0].message_id, '<fixture-plain-1@vendor.example.test>');
  assert.equal(x[0].code, '482913');
  assert.equal(x[0].parse_status, 'code');
  assert.match(x[0].received_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.deepEqual(lines, ['otp-inbox: stored to=bot@otp.example.test from=noreply@vendor.example.test status=code dup=0']);
});

test('E2 the same message delivered twice writes no second row; the second log line says dup=1', async (t) => {
  const o = await fresh(t); if (!o) return;
  const lines = await capture(async () => {
    await inbox.email(message('code-plain.eml'), { DB: o.DB });
    await inbox.email(message('code-plain.eml'), { DB: o.DB });
  });
  ALL_LINES.push(...lines);
  assert.equal(rows(o.db).length, 1);
  assert.match(lines[0], / dup=0$/);
  assert.match(lines[1], / dup=1$/);
});

test('E3 the same Message-ID to a second recipient writes one row per recipient', async (t) => {
  const o = await fresh(t); if (!o) return;
  ALL_LINES.push(...await capture(async () => {
    await inbox.email(message('code-plain.eml', { to: 'a@otp.example.test' }), { DB: o.DB });
    await inbox.email(message('code-plain.eml', { to: 'b@otp.example.test' }), { DB: o.DB });
  }));
  assert.deepEqual(rows(o.db).map((r) => [r.recipient, r.code]), [['a@otp.example.test', '482913'], ['b@otp.example.test', '482913']]);
});

test('E4 a message over 1 MB writes one too_large row with no code and never reads the raw stream', async (t) => {
  const o = await fresh(t); if (!o) return;
  let read = false;
  const lines = await capture(() => inbox.email(message('code-plain.eml', { rawSize: 1048577, onRead: () => { read = true; } }), { DB: o.DB }));
  ALL_LINES.push(...lines);
  assert.equal(read, false, 'message.raw was not touched');
  const x = rows(o.db);
  assert.equal(x.length, 1);
  assert.equal(x[0].parse_status, 'too_large');
  assert.equal(x[0].code, null);
  assert.equal(x[0].subject, 'Your Acme sign-in');
  assert.equal(x[0].message_id, '<fixture-plain-1@vendor.example.test>');
  assert.match(lines[0], / status=too_large dup=0$/);
  // exactly 1 MB is still read
  ALL_LINES.push(...await capture(() => inbox.email(message('code-subject.eml', { rawSize: 1048576 }), { DB: o.DB })));
  assert.equal(rows(o.db)[1].parse_status, 'code');
});

test('E6 an insert that throws: the handler rejects, no row, the log line has the error name and no code', async (t) => {
  const o = await fresh(t); if (!o) return;
  const real = d1(o.db);
  const DB = {
    prepare(sql) {
      const s = real.prepare(sql);
      let b = [];
      const api = { bind(...v) { b = v; s.bind(...v); return api; }, first: (c) => s.first(c), all: () => s.all(),
        run: async () => { if (/^\s*INSERT/i.test(sql)) { const e = new Error('D1_ERROR: fixture write failed'); e.name = 'D1Error'; throw e; } return s.run(); } };
      return api;
    },
  };
  let err = null;
  const lines = await capture(async () => {
    try { await inbox.email(message('code-plain.eml'), { DB }); } catch (e) { err = e; }
  });
  ALL_LINES.push(...lines);
  assert.ok(err, 'the handler rejected');
  assert.equal(err.name, 'D1Error');
  assert.equal(rows(o.db).length, 0);
  assert.deepEqual(lines, ['otp-inbox: store failed to=bot@otp.example.test err=D1Error']);
});

test('E7 round trip: email() then the jobs worker GET /api/otp on the same D1 returns the code', async (t) => {
  const o = await fresh(t); if (!o) return;
  ALL_LINES.push(...await capture(() => inbox.email(message('code-subject.eml', { to: 'Bot@OTP.example.test' }), { DB: o.DB })));
  const jobs = (await import('../../jobs/src/index.js')).default;
  let res;
  ALL_LINES.push(...await capture(async () => {
    res = await jobs.fetch(new Request('https://jobs.test/api/otp?to=bot%40otp.example.test&since=2000-01-01T00:00:00Z',
      { headers: { authorization: `Bearer ${SECRET}` } }), { DB: o.DB, HARNESS_SECRET: SECRET });
  }));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.code, '391027');
  assert.equal(body.subject, '391027 is your Acme code');
});

test('E8 every fixture stores the status and the code the matcher gives it', async (t) => {
  const o = await fresh(t); if (!o) return;
  const want = {
    'code-plain.eml': ['code', '482913'], 'code-html-base64.eml': ['code', '730415'], 'code-qp.eml': ['code', '551820'],
    'code-subject.eml': ['code', '391027'], 'newsletter-no-code.eml': ['no_code', null], 'no-message-id.eml': ['code', 'K7Q2ZP'],
  };
  for (const [name, [status, code]] of Object.entries(want)) {
    const to = `${name.replace(/\.eml$/, '')}@otp.example.test`;
    ALL_LINES.push(...await capture(() => inbox.email(message(name, { to }), { DB: o.DB })));
    const r = o.db.prepare('SELECT parse_status, code FROM otp_messages WHERE recipient=?').get(to);
    assert.deepEqual([r?.parse_status, r?.code], [status, code], name);
  }
});

test('E9 no Message-ID: the fp: id is stable, so a second delivery writes no row; another subject is another row', async (t) => {
  const o = await fresh(t); if (!o) return;
  ALL_LINES.push(...await capture(async () => {
    await inbox.email(message('no-message-id.eml'), { DB: o.DB });
    await inbox.email(message('no-message-id.eml'), { DB: o.DB });
  }));
  const x = rows(o.db);
  assert.equal(x.length, 1);
  assert.match(x[0].message_id, /^fp:[0-9a-f]{64}$/);
  ALL_LINES.push(...await capture(() => inbox.email(message('no-message-id.eml', { from: 'other@vendor.example.test' }), { DB: o.DB })));
  assert.equal(rows(o.db).length, 2, 'a different envelope sender gives a different fp: id');
});

// E5 drives its own email() calls, so it never depends on the order or the
// outcome of E1-E9, and it never skips: the CI skip guard fails any skipped
// test. Every fixture is delivered twice inside ONE capture (the stored line
// and the dup line); the sentinel line proves the capture itself works. The
// lines E1-E9 captured, when they ran, are checked too.
test('E5 no console line written while email() stores or dedups every fixture holds any fixture code', async () => {
  const o = await openDb();
  assert.ok(o, 'node:sqlite unavailable: E5 cannot drive email()');
  assert.equal(mod.loadError, undefined, `worker/otp-inbox/src/index.js loads: ${mod.loadError}`);
  const names = readdirSync(FIX).filter((n) => n.endsWith('.eml')).sort();
  assert.ok(names.length >= 6, `the fixture set is present: ${names}`);
  const SENTINEL = 'e5-capture-sentinel';
  const lines = await capture(async () => {
    console.log(SENTINEL);
    for (const name of names) {
      const to = `e5-${name.replace(/\.eml$/, '')}@otp.example.test`;
      await inbox.email(message(name, { to }), { DB: o.DB });
      await inbox.email(message(name, { to }), { DB: o.DB });
    }
  });
  assert.ok(lines.includes(SENTINEL), 'the console capture caught nothing');
  // Count only the worker's own lines: node 22 prints its SQLite
  // ExperimentalWarning through the console, inside the capture.
  const own = lines.filter((l) => l.startsWith('otp-inbox: '));
  assert.equal(own.length, 2 * names.length, `one worker line per delivery: ${own.join(' | ')}`);
  assert.equal(rows(o.db).filter((r) => r.parse_status === 'code').length, FIXTURE_CODES.length, 'every code fixture stored its code');
  for (const line of [...lines, ...ALL_LINES]) {
    for (const c of FIXTURE_CODES) assert.ok(!line.includes(c), `a log line holds code ${c}: ${line}`);
  }
});

test('E10 fetch() answers 404: the worker has no HTTP surface', async () => {
  assert.equal(mod.loadError, undefined, `worker/otp-inbox/src/index.js loads: ${mod.loadError}`);
  const res = await inbox.fetch(new Request('https://otp-inbox.test/api/otp'), {});
  assert.equal(res.status, 404);
});

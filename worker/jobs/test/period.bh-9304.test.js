// BH-9304 (BH-9120.0): the shared period core on the worker side.
//
// PR*  parseRange: the accept/refuse table of the plan's Failure modes.
// BE*  bucketExpr: 3 fixed SQL fragments only, run in SQLite.
// K*   the mc.period.* knobs: the seed fragment, readPeriodKnobs, the route.
// E3   the knob read is one primary-key range statement.
// CSV* toCsv / csvResponse.
// PAR1 the Pages copy (console-ui/functions/_lib/period.js) answers the same.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import * as W from '../src/lib/period.js';
import * as P from '../../../console-ui/functions/_lib/period.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan } from './lib/d1-volume.bh-6727.js';

const SECRET = 'test-secret';
const NOW = Date.parse('2026-11-14T12:00:00.750Z');
const KNOBS = { max_range_days: 366 };
const BAD = (side) => `${side} is not an ISO date (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z)`;
const u = (qs) => new URL(`https://jobs.test/api/x?${qs}`);
const q = (from, to) => {
  const sp = new URLSearchParams();
  if (from !== undefined) sp.set('from', from);
  if (to !== undefined) sp.set('to', to);
  return sp.toString();
};

// [name, query string, expected]
const PR = [
  ['PR1 date-only means 00:00Z', q('2026-10-01', '2026-10-08'), { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' }],
  ['PR2 minutes with Z', q('2026-10-01T00:00Z', '2026-10-02T00:00:00Z'), { from: '2026-10-01T00:00:00Z', to: '2026-10-02T00:00:00Z' }],
  ['PR3 an offset converts to Z', q('2026-10-01T02:00:00+02:00', '2026-10-01T03:30:00-01:30'), { from: '2026-10-01T00:00:00Z', to: '2026-10-01T05:00:00Z' }],
  ['PR4 missing to = now, to the second', q('2026-11-01T00:00:00Z'), { from: '2026-11-01T00:00:00Z', to: '2026-11-14T12:00:00Z' }],
  ['PR5 exactly max_range_days', q('2025-11-13T12:00:00Z', '2026-11-14T12:00:00Z'), { from: '2025-11-13T12:00:00Z', to: '2026-11-14T12:00:00Z' }],
  ['PR6 max_range_days + 1 s', q('2025-11-13T11:59:59Z', '2026-11-14T12:00:00Z'), { error: 'range is over 366 days (mc.period.max_range_days)' }],
  ['PR7 refuses 1', q('1', '2026-10-08'), { error: BAD('from') }],
  ['PR8 refuses an epoch number', q('1730419200', '2026-10-08'), { error: BAD('from') }],
  ['PR9 refuses text with ;', q('2026-10-01;DROP', '2026-10-08'), { error: BAD('from') }],
  ['PR10 refuses a time with no zone', q('2026-10-01T00:00:00', '2026-10-08'), { error: BAD('from') }],
  ['PR11 refuses fractional seconds', q('2026-10-01T00:00:00.500Z', '2026-10-08'), { error: BAD('from') }],
  ['PR12 refuses 2026-02-30', q('2026-02-30', '2026-03-08'), { error: BAD('from') }],
  ['PR13 refuses an empty from', q('', '2026-10-08'), { error: BAD('from') }],
  ['PR14 to without from', q(undefined, '2026-10-08'), { error: 'from is required when to is given' }],
  ['PR15 from == to', q('2026-10-01', '2026-10-01T00:00:00Z'), { error: 'from must be before to' }],
  ['PR16 from > to', q('2026-10-08', '2026-10-01'), { error: 'from must be before to' }],
  ['PR17 a bad to', q('2026-10-01', '2026-10-08T25:00:00Z'), { error: BAD('to') }],
  ['PR18 first from wins', 'from=2026-10-01&from=2027-01-01&to=2026-10-08', { from: '2026-10-01T00:00:00Z', to: '2026-10-08T00:00:00Z' }],
];

for (const [name, qs, want] of PR) {
  test(`${name}`, () => {
    assert.deepEqual(W.parseRange(u(qs), KNOBS, NOW), want);
  });
}

test('PR19 no range param -> null; the knob default applies when knobs are absent', () => {
  assert.equal(W.parseRange(u('project=x'), KNOBS, NOW), null);
  assert.deepEqual(W.parseRange(u(q('2025-11-13T11:59:59Z', '2026-11-14T12:00:00Z')), {}, NOW),
    { error: 'range is over 366 days (mc.period.max_range_days)' });
  assert.deepEqual(W.parseRange(u(q('2026-10-01', '2026-11-01')), { max_range_days: 30 }, NOW),
    { error: 'range is over 30 days (mc.period.max_range_days)' });
});

const FRAG = {
  hour: "strftime('%Y-%m-%dT%H:00:00Z', created_at)",
  day: 'date(created_at)',
  week: "date(created_at, 'weekday 0', '-6 days')",
};

test('BE1 the 3 bucket fragments, verbatim, and what SQLite makes of them', async (t) => {
  for (const [b, f] of Object.entries(FRAG)) assert.equal(W.bucketExpr(b, 'created_at'), f);
  assert.equal(W.bucketExpr('day', 'j.created_at'), 'date(j.created_at)');
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  const at = (ts) => o.db.prepare(`SELECT ${W.bucketExpr('hour', 'x')} AS h, ${W.bucketExpr('day', 'x')} AS d, ${W.bucketExpr('week', 'x')} AS w FROM (SELECT ? AS x)`).get(ts);
  // 2026-11-15 is a Sunday: its week starts Monday 2026-11-09.
  assert.deepEqual({ ...at('2026-11-15T13:45:00Z') }, { h: '2026-11-15T13:00:00Z', d: '2026-11-15', w: '2026-11-09' });
  assert.equal(at('2026-11-09T00:00:00Z').w, '2026-11-09', 'a Monday is its own week start');
  assert.equal(at('2026-11-16T00:00:00Z').w, '2026-11-16');
});

test('BE2 any other bucket is null', () => {
  for (const b of ["strftime('%s', created_at)", 'hour;--', 'HOUR', '', undefined, null, 'month']) {
    assert.equal(W.bucketExpr(b, 'created_at'), null, String(b));
  }
});

test('BE3 a bad column is null', () => {
  for (const c of ['created_at;DROP', 'a.b.c', 'Created_At', '', '1x', 'x y']) {
    assert.equal(W.bucketExpr('day', c), null, c);
  }
});

const knobRows = (db) => db.prepare("SELECT key, value, actor FROM settings WHERE key LIKE 'mc.period.%' ORDER BY key").all()
  .map((r) => ({ ...r }));

test('K1 the composed schema seeds the 6 mc.period.* rows with the ticket values (BH-9308 added 2)', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  assert.deepEqual(knobRows(o.db).map((r) => [r.key, r.value, r.actor]), [
    ['mc.period.csv_row_cap', '100000', 'seed'],
    ['mc.period.default_preset', 'last_7_days', 'seed'],
    ['mc.period.filter_chip_cap', '30', 'seed'],
    ['mc.period.max_buckets', '2000', 'seed'],
    ['mc.period.max_range_days', '366', 'seed'],
    ['mc.period.report_top_rows', '20', 'seed'],
  ]);
  const k = await W.readPeriodKnobs({ DB: o.DB });
  assert.deepEqual({ ...k, source: undefined }, {
    max_range_days: 366, csv_row_cap: 100000, default_preset: 'last_7_days', max_buckets: 2000,
    report_top_rows: 20, filter_chip_cap: 30, source: undefined,
  });
  assert.deepEqual(k.source, {
    max_range_days: 'row', csv_row_cap: 'row', default_preset: 'row', max_buckets: 'row', report_top_rows: 'row', filter_chip_cap: 'row',
  });
});

test('K2 each row overrides its fallback', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  const set = o.db.prepare('UPDATE settings SET value=? WHERE key=?');
  set.run('30', 'mc.period.max_range_days');
  set.run('500', 'mc.period.csv_row_cap');
  set.run('last_30_days', 'mc.period.default_preset');
  set.run('100', 'mc.period.max_buckets');
  const k = await W.readPeriodKnobs({ DB: o.DB });
  assert.equal(k.max_range_days, 30);
  assert.equal(k.csv_row_cap, 500);
  assert.equal(k.default_preset, 'last_30_days');
  assert.equal(k.max_buckets, 100);
  assert.equal(k.source.max_range_days, 'row');
});

test('K3 absent rows and junk values give the fallbacks, and source says so', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  o.db.exec("DELETE FROM settings WHERE key LIKE 'mc.period.%'");
  let k = await W.readPeriodKnobs({ DB: o.DB });
  assert.deepEqual([k.max_range_days, k.csv_row_cap, k.default_preset, k.max_buckets, k.report_top_rows, k.filter_chip_cap],
    [366, 100000, 'last_7_days', 2000, 20, 30]);
  assert.deepEqual(Object.values(k.source), ['fallback', 'fallback', 'fallback', 'fallback', 'fallback', 'fallback']);
  const ins = o.db.prepare("INSERT INTO settings (key,value,actor,updated_at) VALUES (?,?,'t','2026-11-14T00:00:00Z')");
  ins.run('mc.period.max_range_days', 'abc');
  ins.run('mc.period.csv_row_cap', '-1');
  ins.run('mc.period.default_preset', 'custom');
  ins.run('mc.period.max_buckets', '1.5');
  ins.run('mc.period.report_top_rows', '0');
  ins.run('mc.period.filter_chip_cap', 'x');
  k = await W.readPeriodKnobs({ DB: o.DB });
  assert.deepEqual([k.max_range_days, k.csv_row_cap, k.default_preset, k.max_buckets, k.report_top_rows, k.filter_chip_cap],
    [366, 100000, 'last_7_days', 2000, 20, 30]);
  assert.deepEqual(Object.values(k.source), ['fallback', 'fallback', 'fallback', 'fallback', 'fallback', 'fallback']);
  assert.deepEqual(W.PERIOD_FALLBACKS, {
    max_range_days: 366, csv_row_cap: 100000, default_preset: 'last_7_days', max_buckets: 2000, report_top_rows: 20, filter_chip_cap: 30,
  });
});

test('K3b a D1 throw is not mapped to the fallbacks', async () => {
  const DB = { prepare() { return { bind() { return this; }, all: async () => { throw new Error('D1_ERROR: overloaded'); } }; } };
  await assert.rejects(W.readPeriodKnobs({ DB }), /overloaded/);
});

test('E3 the knob read is ONE statement and a primary-key search, no SCAN settings', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  const log = [];
  await W.readPeriodKnobs({ DB: capturingD1(o.db, log) });
  assert.equal(log.length, 1);
  assert.match(log[0].sql, /FROM settings WHERE key >= 'mc\.period\.' AND key < 'mc\.period\/'/);
  const lines = plan(o.db, log[0].sql, ...log[0].binds);
  assert.ok(!lines.some((l) => /^SCAN settings/.test(l)), lines.join(' | '));
  assert.ok(lines.some((l) => /SEARCH settings USING (INDEX sqlite_autoindex_settings_1|PRIMARY KEY)/.test(l)), lines.join(' | '));
});

test('K4 GET /api/period/knobs answers the 6 values with the bearer, 401 without', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite is absent');
  o.db.prepare('UPDATE settings SET value=? WHERE key=?').run('90', 'mc.period.max_range_days');
  const env = { DB: o.DB, HARNESS_SECRET: SECRET };
  const ok = await worker.fetch(new Request('https://jobs.test/api/period/knobs', {
    headers: { authorization: `Bearer ${SECRET}` },
  }), env);
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.deepEqual(body.knobs, {
    max_range_days: 90, csv_row_cap: 100000, default_preset: 'last_7_days', max_buckets: 2000, report_top_rows: 20, filter_chip_cap: 30,
  });
  assert.equal(body.source.max_range_days, 'row');
  assert.match(body.as_of, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const no = await worker.fetch(new Request('https://jobs.test/api/period/knobs'), env);
  assert.equal(no.status, 401);
});

// A small RFC 4180 reader, so CSV1 proves the text parses back to the values.
function parseCsv(text) {
  const rows = []; let row = []; let f = ''; let inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"' && text[i + 1] === '"') { f += '"'; i++; } else if (c === '"') inQ = false; else f += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\r' && text[i + 1] === '\n') { row.push(f); rows.push(row); row = []; f = ''; i++; }
    else f += c;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}

const CSV_CASES = [
  [['a', 'b'], [{ a: 'a,b', b: 'say "hi"' }, { a: 'x\ny', b: 'plain' }]],
  [['n', 'm'], [{ n: 1234.5, m: 0 }, [7, -2]]],
  [['k', 'v'], [{ k: null, v: undefined }, { k: 'z' }]],
];

test('CSV1 RFC 4180 quoting: comma, quote, newline; quotes doubled; CRLF ends', () => {
  const text = W.toCsv(...CSV_CASES[0]);
  assert.equal(text, 'a,b\r\n"a,b","say ""hi"""\r\n"x\ny",plain\r\n');
  assert.deepEqual(parseCsv(text), [['a', 'b'], ['a,b', 'say "hi"'], ['x\ny', 'plain']]);
});

test('CSV2 numbers stay raw', () => {
  assert.equal(W.toCsv(...CSV_CASES[1]), 'n,m\r\n1234.5,0\r\n7,-2\r\n');
});

test('CSV3 null and undefined are empty fields', () => {
  assert.equal(W.toCsv(...CSV_CASES[2]), 'k,v\r\n,\r\nz,\r\n');
});

test('CSV4 csvResponse caps the rows, says so on the last line, and sends the headers', async () => {
  const rows = [{ a: 1 }, { a: 2 }, { a: 3 }];
  const res = W.csvResponse(['a'], rows, { cap: 2, filename: 'jobs 2026/10.csv' });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'text/csv; charset=utf-8');
  assert.equal(res.headers.get('content-disposition'), 'attachment; filename="jobs_2026_10.csv"');
  assert.equal(await res.text(), 'a\r\n1\r\n2\r\n# truncated at 2\r\n');
  const full = W.csvResponse(['a'], rows, { cap: 3, filename: 'x.csv' });
  assert.equal(await full.text(), 'a\r\n1\r\n2\r\n3\r\n', 'no truncation line under the cap');
});

test('PAR1 the Pages copy gives the same output on every PR, BE and CSV case', async () => {
  for (const [name, qs] of PR) assert.deepEqual(P.parseRange(u(qs), KNOBS, NOW), W.parseRange(u(qs), KNOBS, NOW), name);
  assert.deepEqual(P.parseRange(u('x=1'), KNOBS, NOW), W.parseRange(u('x=1'), KNOBS, NOW));
  for (const b of ['hour', 'day', 'week', 'HOUR', 'hour;--', '']) {
    for (const c of ['created_at', 'j.created_at', 'created_at;DROP']) assert.equal(P.bucketExpr(b, c), W.bucketExpr(b, c), `${b}/${c}`);
  }
  for (const c of CSV_CASES) assert.equal(P.toCsv(...c), W.toCsv(...c));
  const a = W.csvResponse(['a'], [{ a: 1 }, { a: '"' }], { cap: 1, filename: 'a b.csv' });
  const b = P.csvResponse(['a'], [{ a: 1 }, { a: '"' }], { cap: 1, filename: 'a b.csv' });
  assert.equal(await b.text(), await a.text());
  assert.deepEqual([...b.headers], [...a.headers]);
  assert.deepEqual(P.PERIOD_FALLBACKS, W.PERIOD_FALLBACKS);
});

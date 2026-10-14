import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { sortRows, nextDirection, ariaSort } from '../src/lib/sort.js';
import {
  savedRows, savedTiles, runRows, reusedSuiteRows, isNotDeployed, SUITE_REUSE_DAYS
} from '../src/lib/suite-reuse.js';
import { CiHealthScreen, CiHealthView, SuiteReuseView } from '../src/screens/CiHealth.js';

// BH-5369 (BH-5354.3): the SUITE REUSE section of /ci. The response fixtures
// are shaped exactly like worker/jobs/src/routes/suite-reuse-saved.js answers:
// /saved {days, since, rows:[{day, repo, class, runs, ran, reused, saved_s}]}
// and /runs {day, capped, rows:[suite_reuse_runs row + url + reused_suites]}.

const BH = 'example-org/cromford';
const NOW = Date.parse('2026-10-08T12:00:00Z');
const TODAY = '2026-10-08';
const day = (d, cls, saved_s, extra = {}) => ({ day: d, repo: BH, class: cls, runs: 2, ran: 3, reused: 4, saved_s, ...extra });
const run = (run_key, created_at, extra = {}) => ({
  repo: BH, run_key, ctx: 'isolated', class: 'ci', head_sha: null, ran: 1, reused: 2, total: 3, saved_s: 90,
  created_at, updated_at: created_at, url: null, reused_suites: null, ...extra,
});

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });
const failed = (msg, status) => {
  const e = new Error(msg);
  if (status) e.status = status;
  return { data: null, error: e, loading: false, reload: () => {} };
};

const SAVED = loaded({ days: 14, rows: [
  day('2026-10-02', 'ci', 600),
  day(TODAY, 'ci', 120),
  day(TODAY, 'builder', 600),
  day('2026-10-07', 'ci', 300),
  day('2026-09-30', 'ci', 6000),
] });
const view = (props) => render(h(SuiteReuseView, { reuse: SAVED, nowMs: NOW, onOpenDay: () => {}, onOpenRun: () => {}, ...props }));
function tables(v, out = []) {
  if (!v || typeof v !== 'object') return out;
  if (Array.isArray(v)) { v.forEach((x) => tables(x, out)); return out; }
  if (v.type && v.type.name === 'SortableTable') out.push(v);
  if (v.props) tables(v.props.children, out);
  return out;
}
const dayButtons = (out) => [...out.matchAll(/<button[^>]*aria-expanded="(?:true|false)"[^>]*>(\d{4}-\d{2}-\d{2})<\/button>/g)].map((m) => m[1]);

test('1 the getters go through the coord proxy with the right query', async () => {
  const seen = [];
  const orig = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{"rows":[]}', { status: 200 }); };
  try {
    await api.suiteReuseSaved(SUITE_REUSE_DAYS);
    await api.suiteReuseSaved(14, BH);
    await api.suiteReuseRuns(TODAY, BH, 'ci');
    await api.suiteReuseRuns(TODAY);
  } finally {
    globalThis.fetch = orig;
  }
  assert.deepEqual(seen, [
    '/api/coord/suite-results/saved?days=14', // determinism: ok the getter's query text, compared as a string; nothing here reads a clock or a window
    '/api/coord/suite-results/saved?days=14&repo=example-org%2Fcromford', // determinism: ok the getter's query text, compared as a string; nothing here reads a clock or a window
    '/api/coord/suite-results/runs?day=2026-10-08&repo=example-org%2Fcromford&class=ci',
    '/api/coord/suite-results/runs?day=2026-10-08',
  ]);
});

test('2 tiles: CI minutes only, today and the last 7 UTC days; builder minutes apart', () => {
  const rows = savedRows(SAVED.data);
  const t = savedTiles(rows, NOW);
  assert.equal(t.todayMin, 2, 'today: the ci 120 s, not the builder 600 s');
  assert.equal(t.weekMin, (120 + 300 + 600) / 60, '7 days: 10-02..10-08 ci only, 09-30 is outside');
  assert.equal(t.builderWeekMin, 10);
  assert.equal(savedRows({}), null, 'no rows array is absent, not zero');
  assert.equal(savedRows(null), null);
  assert.deepEqual(rows.map((r) => r.key)[1], `${TODAY}|${BH}|ci`);
  const out = view({});
  assert.match(out, /CI MIN SAVED TODAY[\s\S]*?2\.0/);
  assert.match(out, /CI MIN SAVED 7D[\s\S]*?17\.0/);
  assert.match(out, /builder runs saved 10\.0 min in the last 7 days/);
});

test('3 the day table: seven sortable headers, DAY descending by default; a DAY click flips to ascending', () => {
  const out = view({});
  const ths = out.match(/<th\b[^>]*>/g) || [];
  assert.equal(ths.length, 7);
  for (const th of ths) assert.match(th, /aria-sort="/);
  for (const label of ['DAY', 'REPO', 'RUNNER', 'RUNS', 'RAN', 'REUSED', 'SAVED']) assert.ok(out.includes(label), label);
  assert.match(ths[0], /aria-sort="descending"/);
  assert.deepEqual(dayButtons(out), [TODAY, TODAY, '2026-10-07', '2026-10-02', '2026-09-30']);
  assert.ok(out.includes('class="tablewrap tablewrap--wide"'), 'the table scrolls in its own container');
  assert.ok(out.includes('>builder<') && out.includes('>ci<'));
  // preact-render-to-string runs no click handlers. SortableTable's header
  // click is nextDirection + sortRows over the column's own accessor; drive
  // that with this view's DAY column.
  const dir = nextDirection('day', 'day', 'desc');
  assert.equal(dir, 'asc');
  assert.equal(ariaSort('day', 'day', dir), 'ascending');
  const asc = sortRows(savedRows(SAVED.data), (r) => r.day, dir).map((r) => r.day);
  assert.deepEqual(asc, ['2026-09-30', '2026-10-02', '2026-10-07', TODAY, TODAY]);
});

test('4 an open day: its DAY button is expanded and the runs table renders, a ci run links to GitHub', () => {
  const openDay = { day: TODAY, repo: BH, class: 'ci' };
  const url = `https://github.com/${BH}/actions/runs/123/attempts/1`;
  const runs = loaded({ day: TODAY, capped: false, rows: [
    run('123-1-0', `${TODAY}T10:00:00Z`, { url }),
    run('example-BH-1-gate-1', `${TODAY}T11:00:00Z`, { class: 'builder' }),
    run('124-1-0', `${TODAY}T09:00:00Z`, { url: 'https://evil.example/x' }),
  ] });
  const out = view({ openDay, runs });
  assert.equal((out.match(/aria-expanded="true"/g) || []).length, 1, 'only the open day');
  assert.match(out, new RegExp(`<button[^>]*aria-expanded="true"[^>]*>${TODAY}</button>`));
  assert.ok(out.includes(`RUNS · ${TODAY} · ${BH} · ci`));
  assert.ok(out.includes(`<a href="${url}" target="_blank" rel="noopener noreferrer"`));
  assert.ok(!out.includes('evil.example'), 'a non-GitHub url is dropped, never linked');
  assert.ok(/<span[^>]*>example-BH-1-gate-1<\/span>/.test(out), 'a builder run is plain text');
  const order = ['example-BH-1-gate-1', '123-1-0', '124-1-0'].map((k) => out.indexOf(`>${k}<`));
  assert.deepEqual([...order].sort((a, b) => a - b), order, 'runs newest first');
  // The DAY button and the run's SUITES button call the handlers the screen
  // passes. preact-render-to-string runs no handlers, so find the real tables
  // in the vnode tree and press the buttons their cells render.
  const opened = [];
  const ranOpen = [];
  const tree = SuiteReuseView({ reuse: SAVED, nowMs: NOW, openDay, runs, onOpenDay: (r) => opened.push(r), onOpenRun: (k) => ranOpen.push(k) });
  const [dayTable, runTable] = tables(tree);
  dayTable.props.columns[0].cell(dayTable.props.rows[1]).props.onClick();
  assert.deepEqual(opened.map((r) => [r.day, r.repo, r.class]), [[TODAY, BH, 'ci']]);
  const runCell = runTable.props.columns[0].cell(runTable.props.rows[0]);
  [].concat(runCell).flat(Infinity).find((k) => k && k.type === 'button').props.onClick();
  assert.deepEqual(ranOpen, ['123-1-0']);
  const capped = view({ openDay, runs: loaded({ day: TODAY, capped: true, rows: [run('1-1-0', `${TODAY}T01:00:00Z`)] }) });
  assert.ok(capped.includes('first 200 runs only'));
  const none = view({ openDay, runs: loaded({ day: TODAY, capped: false, rows: [] }) });
  assert.ok(none.includes(`no runs on ${TODAY}`));
  const broke = view({ openDay, runs: failed('http_503 suite_reuse_runs unavailable', 503) });
  assert.ok(broke.includes('http_503 suite_reuse_runs unavailable') && broke.includes('RETRY'));
});

test('5 an open run: its reused suites, or a note when the ledger did not record them', () => {
  const openDay = { day: TODAY, repo: BH, class: 'ci' };
  const suites = [{ suite: 'tests/a.sh', run_id: '99-1-0', duration_s: 40 }, { suite: 'tests/b.sh', from_run: '98-1-0', saved_s: 12 }];
  const runs = loaded({ day: TODAY, capped: false, rows: [run('123-1-0', `${TODAY}T10:00:00Z`, { reused_suites: suites }), run('124-1-0', `${TODAY}T09:00:00Z`)] });
  const out = view({ openDay, runs, openRun: '123-1-0' });
  assert.ok(out.includes('REUSED · 123-1-0'));
  for (const label of ['SUITE', 'FROM RUN']) assert.ok(out.includes(label), label);
  assert.ok(out.includes('tests/a.sh') && out.includes('99-1-0') && out.includes('>40<'));
  assert.ok(out.includes('tests/b.sh') && out.includes('98-1-0') && out.includes('>12<'));
  assert.deepEqual(reusedSuiteRows({ reused_suites: suites }).map((s) => [s.suite, s.from_run, s.saved_s]),
    [['tests/a.sh', '99-1-0', 40], ['tests/b.sh', '98-1-0', 12]]);
  const notRecorded = view({ openDay, runs, openRun: '124-1-0' });
  assert.ok(notRecorded.includes('REUSED · 124-1-0'));
  assert.ok(notRecorded.includes('the ledger did not record which suites this run reused (2 reused)'));
  assert.equal(reusedSuiteRows({ reused_suites: null }), null);
  assert.equal(runRows({ rows: [{ url: 'http://github.com/x', reused_suites: 'x' }] }).rows[0].url, null);
});

test('6 empty, not deployed and failing render distinctly', () => {
  const empty = view({ reuse: loaded({ days: 14, rows: [] }) });
  assert.ok(empty.includes('no reuse recorded yet'));
  assert.ok(!empty.includes('not deployed'));
  const notDeployed = view({ reuse: failed('unknown endpoint', 404) });
  assert.ok(notDeployed.includes('no reuse recorded yet'));
  assert.ok(notDeployed.includes('the suite-reuse routes are not deployed on the jobs worker yet'));
  assert.ok(isNotDeployed({ status: 404 }) && !isNotDeployed({ status: 500 }) && !isNotDeployed(null));
  const broke = view({ reuse: failed('http_500', 500) });
  assert.ok(broke.includes('could not load') && broke.includes('http_500') && broke.includes('RETRY'));
  assert.ok(!broke.includes('no reuse recorded yet'));
  const loading = view({ reuse: { data: null, error: null, loading: true } });
  assert.ok(loading.includes('class="skel"'));
});

test('7 CiHealthView renders SUITE REUSE after CI HEALTH only when the reuse prop is set', () => {
  const base = {
    health: loaded({ rows: [] }), flakes: loaded({ flakes: [] }), quarantine: loaded({ rows: [] }),
    onToggle: () => {}, onOpen: () => {}, pending: null, msg: null,
  };
  const without = render(h(CiHealthView, base));
  assert.ok(without.includes('CI HEALTH'));
  assert.ok(!without.includes('SUITE REUSE'));
  const withIt = render(h(CiHealthView, { ...base, reuse: SAVED, onOpenDay: () => {}, onOpenRun: () => {} }));
  assert.ok(withIt.indexOf('SUITE REUSE') > withIt.indexOf('CI HEALTH'));
  assert.ok(withIt.includes('CI MIN SAVED TODAY'));
});

test('8 the screen reads saved minutes on the 60 s poll and opens no native dialog', () => {
  const src = CiHealthScreen.toString() + SuiteReuseView.toString();
  assert.match(CiHealthScreen.toString(), /api\.suiteReuseSaved\(SUITE_REUSE_DAYS\), \[\], poll\)/);
  assert.match(CiHealthScreen.toString(), /intervalMs: 60000/);
  assert.equal(/(^|[^A-Za-z_.])(window\.)?(confirm|alert|prompt)\s*\(/.test(src), false);
});

// BH-7728 (UNB-6): the console TACKLER screen on /unblock.
//
// The real route is mounted from app.js ROUTES into the shared fake DOM, and
// every read goes through the real lib/unblock-api.js against a stubbed fetch
// (no network). Fixtures are the wire shapes of the two jobs-worker reads:
//   GET /api/coord/unblock/metrics?project=&days=7
//   GET /api/coord/unblock/metrics/decisions?project=[&before_id=]
// Both answer 503 {"error":"unblock_decisions schema not applied"} before the
// UNB-0 table exists. Each test seeds its own fixture.
// determinism: ok every timestamp in this file is a literal, never the wall clock.

import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/unblock', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { installDom, routedFetch, all, fire, byTestId } = await import('./helpers/fake-dom.bh-5750.js');
const { ROUTES, NAV, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const P = 'cromford';
const SCHEMA_503 = { error: 'unblock_decisions schema not applied', detail: 'fixture: no table' };

const dayRow = (day, over = {}) => ({
  day, decisions: 3, would: 1, escalations: 1, overrides: 0, stall_median_min: 20, stall_p95_min: 40, ...over
});
const metrics = (over = {}) => ({
  project: P, days: 7, from: '2026-10-13T00:00:00Z', to: '2026-10-20T00:00:00Z',
  daily: [
    dayRow('2026-10-13', { decisions: 2, would: 0, escalations: 0, overrides: 1, stall_median_min: 15, stall_p95_min: 70 }),
    dayRow('2026-10-14', { decisions: 5, would: 2, escalations: 1, overrides: 0, stall_median_min: null, stall_p95_min: null }),
    dayRow('2026-10-15', { decisions: 4, would: 3, escalations: 2, overrides: 2, stall_median_min: 25, stall_p95_min: 50 }),
  ],
  totals: { decisions_per_day: 3, escalations_per_day: 0.57, override_rate: 0.0952, stall_median_min: 30, stall_p95_min: 60, stall_unknown: 2 },
  rules: [{ rule_id: 'U1', acts: 10, overrides: 1 }], expired_cards: 2, uncovered: 1, truncated: false,
  ...over,
});
const decision = (id, over = {}) => ({
  id, created_at: '2026-10-19T10:00:00Z', acted_at: null, project: P, repo: 'example-org/cromford',
  subject_kind: 'pr', subject: 'example-org/cromford#7617', head: 'abc1234fixture', rule_id: 'U6', rule_cites: 'G15,G13',
  decision: 'act', action: 'post_block', mode: 'shadow', outcome: 'would', outcome_detail: null,
  override_by: null, override_at: null, override_detail: null, evidence: '{"verdict":"BLOCK","n":1}', evidence_truncated: false,
  ...over,
});
const ROWS = () => [
  decision(4460),
  decision(4450, { subject_kind: 'box', subject: 'box:box-fixture-1', rule_id: 'U2', decision: 'escalate', action: null, outcome: 'done',
    outcome_detail: 'fixture outcome detail', override_by: 'operator', override_detail: 'fixture override detail' }),
  decision(4440, { subject_kind: 'lane', subject: 'lane:merge-conductor', rule_id: null, decision: 'digest', action: null, mode: 'act', outcome: 'done' }),
];
const decisions = (over = {}) => ({ project: P, limit: 50, next_before_id: 4440, decisions: ROWS(), ...over });

const route = ({ m = [200, metrics()], d = [200, decisions()] } = {}) => (u) =>
  (u.startsWith('/api/coord/unblock/metrics/decisions') ? d : u.startsWith('/api/coord/unblock/metrics') ? m : [404, { error: 'no fixture' }]);

let mounted = null;
afterEach(() => {
  if (mounted) { mount(null, mounted); mounted = null; }
  window.location.search = '';
});

function mountRoute(doc, search = '') {
  window.location.pathname = '/unblock';
  window.location.search = search;
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/unblock'), C]).find(([params]) => params);
  assert.ok(hit, 'a route for /unblock');
  const root = doc.createElement('div');
  const fleet = { data: { projects: [P, 'project-3'] }, error: null, loading: false, reload() {} };
  mount(h(FleetContext.Provider, { value: fleet }, h(hit[1], hit[0])), root);
  mounted = root;
  return root;
}

const section = (root, id) => {
  const s = byTestId(root, id)[0];
  assert.ok(s, `section ${id} renders`);
  return s;
};
const headers = (el) => all(el).filter((n) => n.localName === 'th');
const bodyRows = (el) => all(el).filter((n) => n.localName === 'tr' && n.parentNode && n.parentNode.localName === 'tbody' && !(n.attrs.class || '').includes('tbl-expand'));
const button = (el, label) => all(el).find((n) => n.localName === 'button' && n.textContent.trim() === label);

test('C0 /unblock is a route, its headline is TACKLER, and the STAFF tab lights on it', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const h1 = all(root).find((n) => n.localName === 'h1');
  assert.ok(h1 && h1.textContent.includes('TACKLER'), `h1 says TACKLER: ${h1 && h1.textContent}`);
  const staff = NAV.find((n) => n.label === 'STAFF');
  assert.equal(staff.match('/unblock'), true);
  const others = NAV.filter((n) => n.label !== 'STAFF' && n.match('/unblock'));
  assert.deepEqual(others.map((n) => n.label), [], 'only STAFF lights on /unblock');
});

test('C0b the two reads start together, before either answers', async () => {
  const doc = installDom();
  const started = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  globalThis.fetch = async (url) => {
    const u = String(url);
    started.push(u);
    await gate;
    const [status, body] = route()(u);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  const root = mountRoute(doc);
  await flush();
  assert.deepEqual(started.slice().sort(), [
    '/api/coord/unblock/metrics/decisions?project=cromford',
    '/api/coord/unblock/metrics?project=cromford&days=7',   // determinism: ok clock-rolling-window an assert on the URL the screen asked the fetch stub for; the stub answers fixed rows whatever the date
  ]);
  assert.ok(byTestId(root, 'unblock-loading').length >= 2, 'a skeleton per section while the reads are open');
  release();
  await flush();
  assert.equal(started.length, 2, 'no third read');
  assert.equal(byTestId(root, 'unblock-loading').length, 0, 'the skeletons go when the reads answer');
});

test('C0c ?project=project-3 moves both reads to project-3', async () => {
  const doc = installDom();
  const calls = routedFetch(route());
  mountRoute(doc, '?project=project-3');
  await flush();
  assert.equal(calls.length, 2);
  for (const c of calls) assert.equal(new URL(c.url, 'https://x.test').searchParams.get('project'), 'project-3', c.url);
});

test('C1 every header of both tables is a sort button with aria-sort; a click sorts asc, the next desc', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const expect = {
    'unblock-trend': ['DAY', 'DECISIONS', 'WOULD', 'ESCALATIONS', 'OVERRIDES', 'STALL MEDIAN', 'STALL P95'],
    'unblock-ledger': ['ID', 'CREATED', 'SUBJECT', 'RULE', 'CITES', 'DECISION', 'ACTION', 'MODE', 'OUTCOME', 'OVERRIDE'],
  };
  for (const [id, labels] of Object.entries(expect)) {
    const ths = headers(section(root, id));
    assert.equal(ths.length, labels.length, `${id}: ${labels.length} headers`);
    for (let i = 0; i < labels.length; i++) {
      assert.ok(ths[i].textContent.includes(labels[i]), `${id} header ${i} is ${labels[i]}`);
      assert.ok(['none', 'ascending', 'descending'].includes(ths[i].attrs['aria-sort']), `${id} ${labels[i]} has aria-sort`);
      const btn = () => all(headers(section(root, id))[i]).find((n) => n.localName === 'button');
      assert.ok(btn(), `${id} ${labels[i]} is a button`);
      fire(btn(), 'click');
      await flush();
      assert.equal(headers(section(root, id))[i].attrs['aria-sort'], 'ascending', `${id} ${labels[i]} first click`);
      fire(btn(), 'click');
      await flush();
      assert.equal(headers(section(root, id))[i].attrs['aria-sort'], 'descending', `${id} ${labels[i]} second click`);
    }
  }
  // The sort moves the rows: the ledger by ID ascending, then descending.
  const ledger = () => section(root, 'unblock-ledger');
  const ids = () => bodyRows(ledger()).map((tr) => Number(tr.childNodes[0].textContent.trim()));
  const idBtn = () => all(headers(ledger())[0]).find((n) => n.localName === 'button');
  fire(idBtn(), 'click');
  await flush();
  assert.deepEqual(ids(), [4440, 4450, 4460]);
  fire(idBtn(), 'click');
  await flush();
  assert.deepEqual(ids(), [4460, 4450, 4440]);
  // The trend table by DECISIONS ascending.
  const trend = () => section(root, 'unblock-trend');
  fire(all(headers(trend())[1]).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.deepEqual(bodyRows(trend()).map((tr) => tr.childNodes[0].textContent.trim()), ['2026-10-13', '2026-10-15', '2026-10-14']);
  // A null stall shows n/a, never 0.
  const nullDay = bodyRows(trend()).find((tr) => tr.childNodes[0].textContent.trim() === '2026-10-14');
  assert.equal(nullDay.childNodes[5].textContent.trim(), 'n/a');
});

test('C2 a pr subject links to /pr/<project>/<n>, a box to /machines?box=<name>, a lane is plain text', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const rows = bodyRows(section(root, 'unblock-ledger'));
  const subjectCell = (id) => rows.find((tr) => tr.childNodes[0].textContent.trim() === String(id)).childNodes[2];
  const linkOf = (cell) => all(cell).find((n) => n.localName === 'a');
  assert.equal(linkOf(subjectCell(4460)).attrs.href, '/pr/cromford/7617');
  assert.equal(linkOf(subjectCell(4450)).attrs.href, '/machines?box=box-fixture-1');
  assert.equal(linkOf(subjectCell(4440)), undefined, 'a lane subject has no link');
  assert.match(subjectCell(4440).textContent, /lane/);
  assert.match(subjectCell(4440).textContent, /lane:merge-conductor/);
});

test('C2b the ID button opens the evidence, outcome detail and override detail under the row', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  assert.ok(!root.textContent.includes('fixture override detail'), 'closed by default');
  fire(button(section(root, 'unblock-ledger'), '4450'), 'click');
  await flush();
  const open = all(root).find((n) => n.localName === 'tr' && (n.attrs.class || '').includes('tbl-expand'));
  assert.ok(open, 'an expand row');
  assert.match(open.textContent, /"verdict": "BLOCK"/);
  assert.match(open.textContent, /fixture outcome detail/);
  assert.match(open.textContent, /fixture override detail/);
});

test('C3 the tiles show the four metric values from the read', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const tiles = byTestId(root, 'unblock-tile').map((n) => n.textContent.replace(/\s+/g, ' ').trim());
  assert.equal(tiles.length, 4, tiles.join(' | '));
  assert.match(tiles[0], /STALL MEDIAN \/ P95.*30 \/ 60\s*min/);
  assert.match(tiles[1], /DECISIONS \/ DAY\s*3$/);
  assert.match(tiles[2], /ESCALATIONS \/ DAY.*0\.57/);
  assert.match(tiles[3], /OVERRIDE RATE.*9\.5\s*%/);
});

test('C3b a null metric shows n/a', async () => {
  const doc = installDom();
  routedFetch(route({ m: [200, metrics({ totals: { decisions_per_day: 0, escalations_per_day: 0, override_rate: null, stall_median_min: null, stall_p95_min: null, stall_unknown: 0 } })] }));
  const root = mountRoute(doc);
  await flush();
  const tiles = byTestId(root, 'unblock-tile').map((n) => n.textContent.replace(/\s+/g, ' ').trim());
  assert.match(tiles[0], /n\/a \/ n\/a/);
  assert.match(tiles[3], /OVERRIDE RATE.*n\/a/);
  assert.ok(!/OVERRIDE RATE.*0\s*%/.test(tiles[3]), 'a null rate is never 0%');
});

test('C4 a 503 "schema not applied" renders "Tackler ledger is not live yet", not the error box', async () => {
  const doc = installDom();
  routedFetch(route({ m: [503, SCHEMA_503], d: [503, SCHEMA_503] }));
  const root = mountRoute(doc);
  await flush();
  assert.match(root.textContent, /Tackler ledger is not live yet/);
  assert.equal(button(root, 'RETRY'), undefined, 'no ErrorBox RETRY');
  assert.ok(!root.textContent.includes('could not load'), 'no ErrorBox');
});

test('C5 a generic 500 renders the ErrorBox with RETRY, and RETRY reads again', async () => {
  const doc = installDom();
  const calls = routedFetch(route({ m: [500, { error: 'fixture boom' }], d: [500, { error: 'fixture boom' }] }));
  const root = mountRoute(doc);
  await flush();
  assert.ok(root.textContent.includes('could not load'));
  assert.ok(root.textContent.includes('fixture boom'));
  assert.ok(!root.textContent.includes('not live yet'));
  const retry = button(root, 'RETRY');
  assert.ok(retry, 'a RETRY button');
  const before = calls.length;
  fire(retry, 'click');
  await flush();
  assert.ok(calls.length > before, 'RETRY reads again');
});

test('C5b zero decision rows renders "no decisions in this window"', async () => {
  const doc = installDom();
  routedFetch(route({ d: [200, decisions({ decisions: [], next_before_id: null })] }));
  const root = mountRoute(doc);
  await flush();
  assert.match(section(root, 'unblock-ledger').textContent, /no decisions in this window/);
  assert.equal(button(root, 'OLDER'), undefined, 'no OLDER with nothing older');
});

test('C6 OLDER requests before_id=<last id>', async () => {
  const doc = installDom();
  const calls = routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const older = button(root, 'OLDER');
  assert.ok(older, 'an OLDER button');
  fire(older, 'click');
  await flush();
  const last = calls[calls.length - 1];
  assert.equal(new URL(last.url, 'https://x.test').searchParams.get('before_id'), '4440');
  assert.equal(new URL(last.url, 'https://x.test').searchParams.get('project'), P);
});

test('C6b a page with no next_before_id field pages from the last row id', async () => {
  const doc = installDom();
  const rows = Array.from({ length: 50 }, (_, i) => decision(5000 - i));
  const body = { project: P, limit: 50, decisions: rows };
  const calls = routedFetch(route({ d: [200, body] }));
  const root = mountRoute(doc);
  await flush();
  fire(button(root, 'OLDER'), 'click');
  await flush();
  const last = calls[calls.length - 1];
  assert.equal(new URL(last.url, 'https://x.test').searchParams.get('before_id'), '4951');
});

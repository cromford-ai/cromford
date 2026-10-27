// BH-4588: the console FACTORY screen on /factory.
//
// The real route is mounted from app.js ROUTES into the shared fake DOM. The
// one read goes through the real lib/factory-api.js against a stubbed fetch
// (no network). The fetch answers the committed route output
// tests/fixtures/archie-fm-report.bh-4588/report.json (and empty.json for an
// empty day), read from disk, so a field rename in the worker route breaks
// this suite too. Each test reads its own copy before it changes it.
// determinism: ok every day in this file is a literal or the fixture's day, never the wall clock.

import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/factory', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { installDom, routedFetch, all, fire, byTestId } = await import('./helpers/fake-dom.bh-5750.js');
const { ROUTES, NAV, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const FIXTURE_PATH = fileURLToPath(new URL('../../tests/fixtures/archie-fm-report.bh-4588/report.json', import.meta.url));
const CSS_PATH = fileURLToPath(new URL('../src/styles.css', import.meta.url));
const fixture = () => JSON.parse(readFileSync(FIXTURE_PATH, 'utf8'));
const EMPTY_PATH = fileURLToPath(new URL('../../tests/fixtures/archie-fm-report.bh-4588/empty.json', import.meta.url));
const emptyFixture = () => JSON.parse(readFileSync(EMPTY_PATH, 'utf8'));
const DAY = fixture().day;
const SEARCH = `?day=${DAY}`;

const route = (answer = () => [200, fixture()]) => (u) =>
  (u.startsWith('/api/coord/archie/factory-report') ? answer(u) : [404, { error: 'no fixture' }]);

let mounted = null;
afterEach(() => {
  if (mounted) { mount(null, mounted); mounted = null; }
  window.location.search = '';
});

function mountRoute(doc, search = SEARCH) {
  window.location.pathname = '/factory';
  window.location.search = search;
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/factory'), C]).find(([params]) => params);
  assert.ok(hit, 'a route for /factory');
  const root = doc.createElement('div');
  const fleet = { data: { projects: ['cromford', 'project-4'] }, error: null, loading: false, reload() {} };
  mount(h(FleetContext.Provider, { value: fleet }, h(hit[1], hit[0])), root);
  mounted = root;
  return root;
}

const one = (root, id) => {
  const n = byTestId(root, id)[0];
  assert.ok(n, `${id} renders`);
  return n;
};
const text = (n) => n.textContent.replace(/\s+/g, ' ').trim();
const sectionRow = (root, key) => {
  const n = byTestId(root, 'factory-section').find((s) => s.attrs['data-section'] === key);
  assert.ok(n, `section row ${key} renders`);
  return text(n);
};
const headers = (el) => all(el).filter((n) => n.localName === 'th');
const bodyRows = (el) => all(el).filter((n) => n.localName === 'tr' && n.parentNode && n.parentNode.localName === 'tbody' && !(n.attrs.class || '').includes('tbl-expand'));
const expandRows = (el) => all(el).filter((n) => n.localName === 'tr' && (n.attrs.class || '').includes('tbl-expand'));
const button = (el, label) => all(el).find((n) => n.localName === 'button' && text(n) === label);
const idButton = (root, id) => {
  const b = all(one(root, 'factory-actions')).find((n) => n.localName === 'button' && n.attrs['data-id'] === String(id));
  assert.ok(b, `an expand button for action ${id}`);
  return b;
};
const links = (el) => all(el).filter((n) => n.localName === 'a').map((a) => a.attrs.href);
const qday = (url) => new URL(url, 'https://x.test').searchParams.get('day');

test('C1 the one thing shows first, the sections carry the fixture counts, one table row per action', async () => {
  const doc = installDom();
  const calls = routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const fx = fixture();
  assert.equal(calls.length, 1, 'exactly one request for the day view');
  assert.equal(qday(calls[0].url), DAY);
  assert.ok(calls[0].url.startsWith('/api/coord/archie/factory-report?'), calls[0].url);

  // The one thing comes before the mode line and before every section row.
  const order = all(root).filter((n) => n.attrs && ['factory-one-thing', 'factory-mode', 'factory-section', 'factory-actions'].includes(n.attrs['data-testid']))
    .map((n) => n.attrs['data-testid']);
  assert.equal(order[0], 'factory-one-thing', order.join(','));
  assert.equal(order[1], 'factory-mode', order.join(','));
  assert.equal(text(one(root, 'factory-one-thing')), fx.one_thing.text);
  assert.match(text(one(root, 'factory-mode')), /observe/);

  // The sections are a compact dl, not a card wall.
  const dl = all(root).find((n) => n.localName === 'dl' && n.attrs['data-testid'] === 'factory-sections');
  assert.ok(dl, 'the sections render as a dl');
  assert.equal(byTestId(root, 'factory-section').length, 6);
  assert.match(sectionRow(root, 'merges'), /\b3 merged\b/);
  assert.match(sectionRow(root, 'merges'), /cromford 2/);
  assert.match(sectionRow(root, 'merges'), /project-4 1/);
  assert.match(sectionRow(root, 'stuck'), /cleared 2\b/);
  assert.match(sectionRow(root, 'stuck'), /open 1\b/);
  assert.match(sectionRow(root, 'tickets'), /filed 1\b/);
  assert.match(sectionRow(root, 'tickets'), /shipped 1\b/);
  assert.match(sectionRow(root, 'queue'), /batches 3\b/);
  assert.match(sectionRow(root, 'totals'), /\b8 actions\b/);
  assert.match(sectionRow(root, 'spend'), /cromford \$3\.75/);
  // A merged PR in the section drills to its console PR screen.
  assert.ok(links(byTestId(root, 'factory-section').find((s) => s.attrs['data-section'] === 'merges')).includes('/pr/cromford/101'));

  const rows = bodyRows(one(root, 'factory-actions'));
  assert.equal(rows.length, fx.actions.rows.length);
  // Default order: newest first, the same order the route sends.
  assert.deepEqual(rows.map((tr) => text(tr.childNodes[0])), fx.actions.rows.map((r) => `#${r.id}`));
  assert.ok(!root.textContent.includes('truncated'), 'no truncated tag when the route did not cut');
});

test('C2 every column but the expand toggle sorts with aria-sort; a click is ascending, the next descending; the rows move', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const table = () => one(root, 'factory-actions');
  const labels = ['ID', 'TIME', 'PROJECT', 'REPO/PR', 'PLAYBOOK', 'ACTION', 'OUTCOME', 'WHY'];
  const ths = headers(table());
  assert.equal(ths.length, labels.length);
  assert.equal(ths[0].attrs['aria-sort'], undefined, 'the expand toggle does not sort');
  assert.equal(all(ths[0]).find((n) => n.localName === 'button'), undefined, 'the expand toggle header is no sort button');
  for (let i = 1; i < labels.length; i++) {
    assert.ok(text(ths[i]).startsWith(labels[i]), `header ${i} is ${labels[i]}: ${text(ths[i])}`);
    const btn = () => all(headers(table())[i]).find((n) => n.localName === 'button');
    assert.ok(btn(), `${labels[i]} is a sort button`);
    fire(btn(), 'click');
    await flush();
    assert.equal(headers(table())[i].attrs['aria-sort'], 'ascending', `${labels[i]} first click`);
    fire(btn(), 'click');
    await flush();
    assert.equal(headers(table())[i].attrs['aria-sort'], 'descending', `${labels[i]} second click`);
  }
  const ids = () => bodyRows(table()).map((tr) => text(tr.childNodes[0]));
  const sortBy = async (i) => { fire(all(headers(table())[i]).find((n) => n.localName === 'button'), 'click'); await flush(); };
  // TIME ascending: oldest first.
  await sortBy(1);
  assert.equal(headers(table())[1].attrs['aria-sort'], 'ascending');
  assert.deepEqual(ids(), ['#1', '#2', '#3', '#4', '#5', '#6', '#7', '#8']);
  await sortBy(1);
  assert.deepEqual(ids(), ['#8', '#7', '#6', '#5', '#4', '#3', '#2', '#1']);
  // PLAYBOOK ascending: the playbook names in order.
  await sortBy(4);
  const books = bodyRows(table()).map((tr) => text(tr.childNodes[4]));
  assert.deepEqual(books, [...books].sort());
  assert.equal(books[0], 'improve');
  assert.equal(books[books.length - 1], 'watch-ticket');
  // OUTCOME descending puts requested first.
  await sortBy(6);
  await sortBy(6);
  assert.equal(text(bodyRows(table())[0].childNodes[6]), 'requested');
});

test('C3 the row id opens tr.tbl-expand with the evidence and a /pr/<project>/<n> link; a pr-0 row shows its issue link', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const table = () => one(root, 'factory-actions');
  assert.equal(expandRows(table()).length, 0, 'closed by default');

  // pr > 0: action 5, queue-culprit on cromford #102.
  fire(idButton(root, 5), 'click');
  await flush();
  let open = expandRows(table());
  assert.equal(open.length, 1);
  assert.equal(idButton(root, 5).attrs['aria-expanded'], 'true');
  assert.ok(links(open[0]).includes('/pr/cromford/102'), links(open[0]).join(','));
  assert.match(text(open[0]), /no evidence recorded/);

  // pr 0 with evidence.issue_url: action 6.
  fire(idButton(root, 6), 'click');
  await flush();
  open = expandRows(table());
  assert.equal(open.length, 1, 'one expand row at a time');
  assert.match(text(open[0]), /fp/);
  assert.match(text(open[0]), /0123456789ab/);
  assert.match(text(open[0]), /issue_url/);
  assert.match(text(open[0]), /existing/);
  assert.ok(links(open[0]).includes('https://github.com/example-org/cromford/issues/9001'), links(open[0]).join(','));
  assert.ok(!links(open[0]).some((l) => l.startsWith('/pr/')), 'a pr-0 row has no PR link');

  // pr 0 with evidence.issue as a URL: action 7.
  fire(idButton(root, 7), 'click');
  await flush();
  assert.ok(links(expandRows(table())[0]).includes('https://github.com/example-org/cromford/issues/8999'));

  // pr 0 with an alert id only: action 3.
  fire(idButton(root, 3), 'click');
  await flush();
  open = expandRows(table());
  assert.match(text(open[0]), /main-red-cromford/);
  assert.ok(links(open[0]).includes('/alerts'), links(open[0]).join(','));

  // A second click on the open row closes it.
  fire(idButton(root, 3), 'click');
  await flush();
  assert.equal(expandRows(table()).length, 0);

  // The REPO/PR cell of a pr > 0 row links to the console PR screen too.
  const row1 = bodyRows(table()).find((tr) => text(tr.childNodes[0]) === '#1');
  assert.deepEqual(links(row1.childNodes[3]), ['/pr/cromford/101']);
});

test('C4 mobile: the table scrolls in its tablewrap, no inline width over 375px, every button is a 44px .btn or a header button', async () => {
  const doc = installDom();
  routedFetch(route());
  const root = mountRoute(doc);
  await flush();
  const wrap = all(one(root, 'factory-actions')).find((n) => (n.attrs.class || '').split(/\s+/).includes('tablewrap'));
  assert.ok(wrap, 'the table sits in a .tablewrap');
  assert.ok(all(wrap).some((n) => n.localName === 'table'), 'the table is inside the tablewrap');
  const css = readFileSync(CSS_PATH, 'utf8');
  assert.match(css, /\.tablewrap\s*\{[^}]*overflow-x:\s*auto/, 'styles.css gives .tablewrap overflow-x:auto');
  assert.match(css, /\.btn--sm\s*\{[^}]*min-height:\s*44px/, 'styles.css gives .btn--sm a 44px floor');
  assert.match(css, /table\.tbl th button\s*\{[^}]*min-height:\s*44px/, 'styles.css gives header buttons a 44px floor');

  // Open one drill-down so its contents are checked as well.
  fire(idButton(root, 6), 'click');
  await flush();
  for (const n of all(root)) {
    const st = String((n.attrs && n.attrs.style) || '');
    for (const m of st.matchAll(/(?:^|;)\s*(?:min-|max-)?width\s*:\s*(\d+)px/g)) {
      assert.ok(Number(m[1]) <= 375, `inline width ${m[0]} on <${n.localName}>`);
    }
    if (n.attrs && n.attrs.width) assert.ok(Number(n.attrs.width) <= 375, `width attr on <${n.localName}>`);
  }
  for (const b of all(root).filter((n) => n.localName === 'button')) {
    const cls = (b.attrs.class || '').split(/\s+/);
    const inHeader = b.parentNode && b.parentNode.localName === 'th';
    assert.ok(inHeader || (cls.includes('btn') && cls.includes('btn--sm')), `button "${text(b)}" has the 44px .btn--sm class`);
  }
  // Prev and next are buttons with that class too.
  assert.ok(one(root, 'factory-prev').attrs.class.includes('btn--sm'));
  assert.ok(one(root, 'factory-next').attrs.class.includes('btn--sm'));
});

test('C5 /factory is a route, the STAFF tab lights on it and no other tab does, and the STAFF screen links to it', async () => {
  assert.ok(ROUTES.some(([p]) => p === '/factory'), 'ROUTES has /factory');
  const staff = NAV.find((n) => n.label === 'STAFF');
  assert.equal(staff.match('/factory'), true);
  assert.deepEqual(NAV.filter((n) => n.label !== 'STAFF' && n.match('/factory')).map((n) => n.label), []);
  assert.ok(!NAV.some((n) => n.to === '/factory'), 'no new tab: the bottom nav stays one row');
  const staffSrc = readFileSync(fileURLToPath(new URL('../src/screens/Staff.js', import.meta.url)), 'utf8');
  assert.match(staffSrc, /to="\/factory"/, 'Staff.js links to /factory');
});

test('C6a the Skeleton shows while the read is open, and goes when it answers', async () => {
  const doc = installDom();
  let release;
  const gate = new Promise((r) => { release = r; });
  const started = [];
  globalThis.fetch = async (url) => {
    started.push(String(url));
    await gate;
    return { ok: true, status: 200, text: async () => JSON.stringify(fixture()) };
  };
  const root = mountRoute(doc);
  await flush();
  const loading = one(root, 'factory-loading');
  assert.ok(all(loading).some((n) => (n.attrs.class || '').includes('skel')), 'a Skeleton bar');
  assert.equal(byTestId(root, 'factory-actions').length, 0);
  release();
  await flush();
  assert.equal(byTestId(root, 'factory-loading').length, 0);
  assert.equal(started.length, 1);
});

test('C6b a 500 shows the ErrorBox; RETRY reads the same day again', async () => {
  const doc = installDom();
  const calls = routedFetch(route(() => [500, { error: 'fixture boom' }]));
  const root = mountRoute(doc);
  await flush();
  assert.match(root.textContent, /could not load/);
  assert.match(root.textContent, /fixture boom/);
  const retry = button(root, 'RETRY');
  assert.ok(retry, 'a RETRY button');
  const before = calls.length;
  fire(retry, 'click');
  await flush();
  assert.equal(calls.length, before + 1, 'RETRY reads again');
  assert.equal(qday(calls[calls.length - 1].url), DAY);
});

test('C6c a 503 "schema not applied" shows the not-live state, not the ErrorBox', async () => {
  const doc = installDom();
  routedFetch(route(() => [503, { error: 'archie_actions schema not applied', detail: 'fixture: no table' }]));
  const root = mountRoute(doc);
  await flush();
  assert.match(root.textContent, /Factory report is not live yet/);
  assert.equal(button(root, 'RETRY'), undefined);
  assert.ok(!root.textContent.includes('could not load'));
});

test('C6d the empty route output: 0 action rows shows Empty with the reason, each empty section says "none: <reason>"', async () => {
  const doc = installDom();
  const fx = emptyFixture();
  const calls = routedFetch(route(() => [200, emptyFixture()]));
  const root = mountRoute(doc, `?day=${fx.day}`);
  await flush();
  assert.equal(qday(calls[0].url), fx.day);
  assert.equal(text(one(root, 'factory-one-thing')), fx.one_thing.text);
  const empty = all(root).find((n) => (n.attrs.class || '') === 'empty');
  assert.ok(empty, 'the Empty state');
  assert.equal(text(empty), `none: ${fx.actions.empty_reason}`);
  assert.equal(byTestId(root, 'factory-actions').length, 0, 'no table for 0 rows');
  for (const key of ['merges', 'queue', 'stuck', 'tickets', 'spend']) {
    assert.ok(fx[key].empty_reason, `the empty fixture gives ${key} an empty_reason`);
    assert.match(sectionRow(root, key), new RegExp(`none: ${fx[key].empty_reason}$`), key);
  }
  assert.ok(!root.textContent.includes('not measured'), 'an empty section is measured');
});

test('C6f an ok:false section says "not measured: <error>", never 0; usd null is "unknown", never $0', async () => {
  const doc = installDom();
  const fx = fixture();
  fx.merges = { ok: false, error: 'ledgers read failed' };
  fx.queue = { ...fx.queue, actions: { ok: false, error: 'aggregate read failed' } };
  fx.actions = { ok: false, error: 'rows read failed' };
  routedFetch(route(() => [200, fx]));
  const root = mountRoute(doc);
  await flush();
  assert.match(sectionRow(root, 'merges'), /^MERGES\s*not measured: ledgers read failed$/);
  assert.ok(!/\b0 merged\b/.test(sectionRow(root, 'merges')), 'never 0 for an unmeasured section');
  assert.match(sectionRow(root, 'queue'), /actions not measured: aggregate read failed/);
  assert.match(sectionRow(root, 'queue'), /batches 3\b/, 'the other half still shows');
  assert.match(root.textContent, /not measured: rows read failed/);
  assert.equal(byTestId(root, 'factory-actions').length, 0);
  // The committed fixture carries project-4 with usd null.
  assert.match(sectionRow(root, 'spend'), /project-4 unknown/);
  assert.ok(!/project-4 \$0/.test(sectionRow(root, 'spend')), 'a null usd is never $0');
});

test('C6e truncated actions show the truncated tag', async () => {
  const doc = installDom();
  const fx = fixture();
  fx.actions.truncated = true;
  routedFetch(route(() => [200, fx]));
  const root = mountRoute(doc);
  await flush();
  assert.match(root.textContent, /truncated/);
});

test('C7 PREV requests the day before, NEXT the day after; each move is one request', async () => {
  const doc = installDom();
  const calls = routedFetch(route());
  const root = mountRoute(doc, '?day=2026-10-01');
  await flush();
  assert.equal(calls.length, 1);
  assert.equal(qday(calls[0].url), '2026-10-01');
  fire(one(root, 'factory-prev'), 'click');
  await flush();
  assert.equal(calls.length, 2);
  assert.equal(qday(calls[1].url), '2026-09-30');
  fire(one(root, 'factory-next'), 'click');
  await flush();
  fire(one(root, 'factory-next'), 'click');
  await flush();
  assert.equal(calls.length, 4);
  assert.equal(qday(calls[3].url), '2026-10-02');
});

test('C8 a bad ?day= falls back to the given UTC day; shiftDay crosses a month and a year', async () => {
  const { todayUtc, shiftDay, validDay } = await import('../src/screens/Factory.js');
  assert.equal(todayUtc(new Date('2026-10-22T23:59:59Z')), '2026-10-22');
  assert.equal(shiftDay('2026-03-01', -1), '2026-02-28');
  assert.equal(shiftDay('2026-12-31', 1), '2027-01-01');
  assert.equal(validDay('2026-10-22'), '2026-10-22');
  assert.equal(validDay('2026-13-01'), null);
  assert.equal(validDay('yesterday'), null);
  assert.equal(validDay(null), null);
});

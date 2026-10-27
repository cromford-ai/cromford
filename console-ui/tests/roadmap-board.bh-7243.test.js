import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, routedFetch, all, fire, dialogOf, confirmOf, buttonIn, byName, byTestId, rowsOf, rowFor, type, isDisabled } from './helpers/fake-dom.bh-5750.js';

// BH-7265 (BH-7243.2): the roadmap board view.
//
// The REAL App (ROUTES, Roadmap.js, board-view.js, api.js) is mounted into the
// fake DOM at /roadmap/cromford?view=board, against a stubbed fetch that
// plays the jobs worker through the coord paths. The first board answer is the
// fixture the worker test captured from the REAL GET /api/roadmap/board
// (worker/jobs/test/fixtures/roadmap-board.bh-7243.json, B15). Clicks, drags,
// keys and submits are fired on the real nodes. window.confirm/alert/prompt
// throw.
//
// R1  the 5 api calls (URL and method) and the coord write fragment rows
// R2  the 4 columns render from the fixture, cards in the right columns; the
//     wave-pick checkboxes feed WaveSelectBar's selection
// R3  dragstart on an Ideas card + drop on Next -> one move POST with expected_version
// R4  a Now card: no draggable, no drag handle, "Computed from linked tickets",
//     its issue links and /t/<ticket>
// R5  MOVE opens a visible role=menu; Escape closes it and focus goes back to MOVE
// R5b Discard from the menu opens the in-app dialog, CONFIRM posts the move
// R6  the DECISIONS DATE header flips aria-sort ascending, then descending
// R7  ADD an open decision, DECIDE it in the modal: expected_status open, no native dialog
// R8  LINK ISSUE posts the issue number as an integer; REMOVE confirms in a modal
// R9  a load failure shows RETRY, not the empty copy
// R10 truncated shows the note
// R11 a drop answered 409 shows the reload line

installDom();
const { render: mount } = await import('preact');
const { App } = await import('../src/app.js');
const { api } = await import('../src/api.js');
const { FRAGMENT_WRITES } = await import('#coord-writes');
const FRAG = await import('../functions/_lib/coord-writes.d/7243-roadmap-board.js').catch(() => ({ default: [] }));

window.history.pushState = window.history.replaceState = (_s, _t, to) => {
  const u = new URL(to, 'https://mc.fixture.invalid');
  window.location.pathname = u.pathname;
  window.location.search = u.search;
};

const FIXTURE = JSON.parse(readFileSync(new URL('../../worker/jobs/test/fixtures/roadmap-board.bh-7243.json', import.meta.url), 'utf8'));
const clone = (v) => JSON.parse(JSON.stringify(v));

// The in-memory worker: GET board from the fixture, plus the writes.
function backend({ board = FIXTURE, overrides = {} } = {}) {
  const store = { board: clone(board), n: 0 };
  const route = (url, method, body) => {
    const u = new URL(url, 'https://mc.fixture.invalid');
    const key = `${method} ${u.pathname}`;
    if (overrides[key]) return overrides[key](u, body, store);
    if (key === 'GET /api/coord/roadmap/board') return [200, store.board];
    if (key === 'POST /api/coord/roadmap/ideas/move') {
      for (const col of Object.keys(store.board.columns)) {
        const i = store.board.columns[col].findIndex((c) => c.id === body.id);
        if (i < 0) continue;
        const [card] = store.board.columns[col].splice(i, 1);
        Object.assign(card, { lane: body.to_lane, version: card.version + 1 });
        if (body.to_lane !== 'discarded') store.board.columns[col === 'now' || col === 'shipped' ? col : body.to_lane].unshift(card);
        return [200, { idea: card }];
      }
      return [404, { error: 'idea not found' }];
    }
    if (key === 'POST /api/coord/roadmap/decisions') {
      const d = { id: `nd-${++store.n}`, kind: body.kind, title: body.title, body: body.body || null, status: body.kind === 'log' ? 'decided' : 'open',
        created_by: 'console', decided_by: null, created_at: '2026-10-17T12:30:00Z', updated_at: '2026-10-17T12:30:00Z', decided_at: null };
      (d.kind === 'open' ? store.board.open_decisions : store.board.decisions).unshift(d);
      return [201, { decision: d }];
    }
    if (key === 'POST /api/coord/roadmap/decisions/decide') {
      const i = store.board.open_decisions.findIndex((d) => d.id === body.id);
      if (i < 0) return [404, { error: 'decision not found' }];
      const [d] = store.board.open_decisions.splice(i, 1);
      Object.assign(d, { status: body.status, decided_by: 'console', decided_at: '2026-10-17T12:31:00Z' });
      if (body.status === 'decided') store.board.decisions.unshift(d);
      return [200, { decision: d }];
    }
    if (key === 'POST /api/coord/roadmap/links') return [201, { link: { repo: 'example-org/cromford', issue: body.issue } }];
    if (key === 'POST /api/coord/roadmap/links/remove') return [200, { removed: 1 }];
    return [404, { error: 'unknown endpoint' }];
  };
  return { store, route };
}

let root = null;
afterEach(() => { if (root) { mount(null, root); root = null; } });
async function mountAt(path, b) {
  const u = new URL(path, 'https://mc.fixture.invalid');
  window.location.pathname = u.pathname;
  window.location.search = u.search;
  const calls = routedFetch(b.route);
  root = document.createElement('div');
  mount(h(App), root);
  await flush();
  return calls;
}
const BOARD = '/roadmap/cromford?view=board';
const text = (n) => n.textContent.replace(/\s+/g, ' ');
const describe = () => (root ? text(root).slice(0, 600) : '');
const hidden = (n) => {
  for (let p = n; p; p = p.parentNode) {
    if (p.attrs && 'hidden' in p.attrs) return true;
    const css = (p.style && (p.style.cssText || '')) + (p.attrs && p.attrs.style ? p.attrs.style : '');
    if (/display:\s*none/.test(css) || (p.style && p.style.display === 'none')) return true;
  }
  return false;
};
const col = (name) => byTestId(root, `roadmap-col-${name}`)[0];
const cards = (name) => byTestId(col(name), 'roadmap-card');
const card = (id) => byTestId(root, 'roadmap-card').find((c) => c.attrs['data-id'] === id);
const cardTitles = (name) => cards(name).map((c) => all(c).find((n) => n.localName === 'a').textContent.trim());
const ready = () => waitFor(() => byTestId(root, 'roadmap-board').length && col('ideas') && cards('ideas').length, 'the board', describe);
const posts = (calls, path) => calls.filter((c) => c.method === 'POST' && c.url === `/api/coord/roadmap/${path}`);

test('R1 the 5 api calls hit the coord paths; the fragment holds exactly the 4 write rows', async () => {
  const calls = routedFetch(() => [200, {}]);
  await api.roadmapBoard('board harness');
  await api.roadmapLink({ idea_id: 'i1', project: 'p', issue: 4 });
  await api.roadmapUnlink({ idea_id: 'i1', project: 'p', issue: 4 });
  await api.roadmapAddDecision({ project: 'p', kind: 'log', title: 't' });
  await api.roadmapDecide({ id: 'd1', project: 'p', status: 'decided', expected_status: 'open' });
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), [
    'GET /api/coord/roadmap/board?project=board+harness',
    'POST /api/coord/roadmap/links',
    'POST /api/coord/roadmap/links/remove',
    'POST /api/coord/roadmap/decisions',
    'POST /api/coord/roadmap/decisions/decide',
  ]);
  assert.equal(calls[1].body.issue, 4);
  const rows = FRAG.default.map((r) => `${r.method} ${r.path} ${r.body.join(',')}`);
  assert.deepEqual(rows, [
    'POST roadmap/links idea_id,project,issue',
    'POST roadmap/links/remove idea_id,project,issue',
    'POST roadmap/decisions project,kind,title,body',
    'POST roadmap/decisions/decide id,project,status,expected_status',
  ]);
  for (const r of FRAG.default) {
    assert.ok(!r.body.includes('actor'), `${r.path}: the proxy stamps the actor`);
    assert.ok(FRAGMENT_WRITES.some((w) => w.path === r.path && w.method === r.method), `${r.path} is in the composed table`);
    assert.equal(r.ok('issue', 4), true, 'a number passes');
    assert.equal(r.ok('title', {}), false, 'an object is refused');
  }
});

test('R2 the 4 columns render from the fixture; the wave checkboxes feed WaveSelectBar', async () => {
  const calls = await mountAt(BOARD, backend());
  await ready();
  assert.ok(calls.some((c) => c.url === '/api/coord/roadmap/board?project=cromford'));
  assert.equal(calls.filter((c) => c.url.startsWith('/api/coord/roadmap/')).length, 1, 'one roadmap request for the screen (the App shell makes its own)');
  assert.deepEqual(cardTitles('ideas'), ['Alpha idea', 'Bravo idea']);
  assert.deepEqual(cardTitles('next'), ['Charlie idea']);
  assert.deepEqual(cardTitles('now'), ['Delta idea']);
  assert.deepEqual(cardTitles('shipped'), ['Echo idea']);
  for (const [n, label] of [['ideas', 'IDEAS 2'], ['next', 'NEXT 1'], ['now', 'NOW 1'], ['shipped', 'SHIPPED 1']]) {
    assert.match(text(col(n)), new RegExp(`^\\s*${label}`), n);
    assert.ok(!hidden(col(n)), `${n} is visible`);
  }
  const a = all(card('f5')).find((n) => n.localName === 'a');
  assert.equal(a.attrs.href, '/roadmap/cromford/idea/f5', 'the title drills into the idea page');
  // Ideas/Next cards carry a wave-pick checkbox; Now/Shipped do not.
  const boxes = all(root).filter((n) => n.attrs && n.attrs.name === 'wave-pick');
  assert.equal(boxes.length, 3);
  assert.equal(all(card('f3')).filter((n) => n.attrs && n.attrs.name === 'wave-pick').length, 0);
  const sel = () => byTestId(root, 'roadmap-wave-select')[0].attrs['data-selected'];
  assert.equal(sel(), '');
  fire(all(card('f1')).find((n) => n.attrs && n.attrs.name === 'wave-pick'), 'change', { target: { checked: true } });
  fire(all(card('f2')).find((n) => n.attrs && n.attrs.name === 'wave-pick'), 'change', { target: { checked: true } });
  await flush();
  assert.equal(sel(), 'f1,f2');
  fire(all(card('f1')).find((n) => n.attrs && n.attrs.name === 'wave-pick'), 'change', { target: { checked: false } });
  await flush();
  assert.equal(sel(), 'f2');
  // The list view is one click away, and the list links back to the board.
  assert.ok(all(root).some((n) => n.localName === 'a' && n.attrs.href === '/roadmap/cromford?view=list'));
});

test('R2b the list view links to the board, and the click opens it', async () => {
  const b = backend();
  b.route = ((inner) => (url, method, body) => (url.startsWith('/api/coord/roadmap/ideas?')
    ? [200, { project: 'cromford', ideas: [], counts: { ideas: 0, next: 0, discarded: 0 }, truncated: false, as_of: FIXTURE.as_of }]
    : inner(url, method, body)))(b.route);
  await mountAt('/roadmap/cromford', b);
  await waitFor(() => all(root).some((n) => n.localName === 'a' && n.attrs.href === BOARD), 'the BOARD link', describe);
  const a = all(root).find((n) => n.localName === 'a' && n.attrs.href === BOARD);
  assert.equal(a.textContent.trim(), 'BOARD');
  fire(a, 'click');
  await ready();
  assert.equal(window.location.search, '?view=board');
});

test('R3 a drag from Ideas dropped on Next posts one move with the card version', async () => {
  const b = backend();
  const calls = await mountAt(BOARD, b);
  await ready();
  const c = card('f1');
  assert.equal(c.attrs.draggable, 'true');
  assert.ok(byTestId(c, 'roadmap-drag').length, 'a visible drag handle');
  fire(c, 'dragstart', { dataTransfer: { setData() {}, effectAllowed: '' } });
  const ev = { defaultPrevented: false };
  fire(col('next'), 'dragover', { preventDefault() { ev.defaultPrevented = true; } });
  assert.equal(ev.defaultPrevented, true, 'Next accepts the drop');
  fire(col('next'), 'drop');
  fire(col('next'), 'drop');
  await waitFor(() => cardTitles('next').includes('Bravo idea'), 'the card in Next', describe);
  const moves = posts(calls, 'ideas/move');
  assert.equal(moves.length, 1, 'single-flight: two drops post once');
  assert.deepEqual(moves[0].body, { id: 'f1', project: 'cromford', to_lane: 'next', expected_version: 1 });
  // A drop on the column the card is already in posts nothing.
  fire(card('f1'), 'dragstart', { dataTransfer: { setData() {} } });
  fire(col('next'), 'drop');
  await flush();
  assert.equal(posts(calls, 'ideas/move').length, 1);
  // Now does not take a drop.
  const ev2 = { defaultPrevented: false };
  fire(card('f2'), 'dragstart', { dataTransfer: { setData() {} } });
  if (col('now').listeners.dragover) fire(col('now'), 'dragover', { preventDefault() { ev2.defaultPrevented = true; } });
  assert.equal(ev2.defaultPrevented, false, 'Now refuses the drop');
});

test('R4 a Now card is not draggable and links its issues and its running ticket', async () => {
  await mountAt(BOARD, backend());
  await ready();
  const c = card('f3');
  assert.ok(c, describe());
  assert.ok(!('draggable' in c.attrs) || c.attrs.draggable === 'false', 'no draggable');
  assert.equal(byTestId(c, 'roadmap-drag').length, 0, 'no drag handle');
  assert.match(text(c), /Computed from linked tickets/);
  const anchors = all(c).filter((n) => n.localName === 'a');
  const issue = anchors.find((n) => n.attrs.href === 'https://github.com/example-org/cromford/issues/101');
  assert.ok(issue, 'the issue link');
  assert.equal(issue.textContent.trim(), '#101');
  assert.equal(issue.attrs.target, '_blank');
  assert.match(issue.attrs.rel, /noopener/);
  assert.ok(anchors.some((n) => n.attrs.href === '/t/BH-101'), 'the running ticket link');
  assert.match(text(c), /#103.*not read yet/);
  const shipped = card('f4');
  assert.equal(byTestId(shipped, 'roadmap-drag').length, 0);
  assert.match(text(shipped), /Computed from linked tickets/);
  // A wave link has no REMOVE; a hand link does.
  assert.equal(buttonIn(shipped, 'REMOVE'), undefined);
  assert.ok(buttonIn(c, 'REMOVE'));
});

test('R5 MOVE opens a visible menu; Escape closes it and returns focus to MOVE', async () => {
  await mountAt(BOARD, backend());
  await ready();
  const move = () => buttonIn(card('f1'), 'MOVE');
  assert.equal(move().attrs['aria-haspopup'], 'menu');
  fire(move(), 'click');
  await flush();
  const menu = all(card('f1')).find((n) => n.attrs && n.attrs.role === 'menu');
  assert.ok(menu, 'a role=menu node is mounted');
  assert.ok(!hidden(menu), 'the menu is visible');
  assert.equal(move().attrs['aria-expanded'], 'true');
  const items = all(menu).filter((n) => n.attrs && n.attrs.role === 'menuitem').map((n) => n.textContent.trim());
  assert.deepEqual(items, ['Next', 'Discard'], 'the current lane is left out');
  fire(menu, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(all(card('f1')).find((n) => n.attrs && n.attrs.role === 'menu'), undefined);
  assert.equal(document.activeElement, move(), 'focus is back on MOVE');
  // A Now card's menu says the card stays where its links put it.
  fire(buttonIn(card('f3'), 'MOVE'), 'click');
  await flush();
  const m3 = all(card('f3')).find((n) => n.attrs && n.attrs.role === 'menu');
  assert.match(text(m3), /Sets the hand lane\. The card stays here while its links say so\./);
  assert.deepEqual(all(m3).filter((n) => n.attrs && n.attrs.role === 'menuitem').map((n) => n.textContent.trim()), ['Next', 'Discard']);
});

test('R5b Discard from the menu confirms in the in-app dialog, then posts the move', async () => {
  const calls = await mountAt(BOARD, backend());
  await ready();
  fire(buttonIn(card('f5'), 'MOVE'), 'click');
  await flush();
  fire(buttonIn(card('f5'), 'Discard'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d, 'a role=dialog node');
  assert.equal(d.attrs['aria-label'], 'Discard this idea?');
  fire(buttonIn(d, 'CANCEL'), 'click');
  await flush();
  assert.equal(posts(calls, 'ideas/move').length, 0);
  fire(buttonIn(card('f5'), 'MOVE'), 'click');
  await flush();
  fire(buttonIn(card('f5'), 'Next'), 'click');
  await waitFor(() => cardTitles('next').includes('Alpha idea'), 'Alpha in Next', describe);
  assert.deepEqual(posts(calls, 'ideas/move')[0].body, { id: 'f5', project: 'cromford', to_lane: 'next', expected_version: 1 });
});

test('R6 the DECISIONS DATE header flips aria-sort ascending, then descending', async () => {
  const board = clone(FIXTURE);
  board.decisions.push({ ...board.decisions[0], id: 'd0', title: 'Older call', decided_at: '2026-10-10T09:00:00Z', created_at: '2026-10-10T09:00:00Z' });
  await mountAt(BOARD, backend({ board }));
  await ready();
  const table = () => byTestId(root, 'roadmap-decisions')[0];
  const th = () => all(table()).find((n) => n.localName === 'th' && n.textContent.trim().startsWith('DATE'));
  const order = () => rowsOf(table()).slice(1).map((tr) => tr.childNodes[1].textContent.trim().split(/\s{2,}|\n/)[0]);
  assert.ok(!hidden(table()));
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'ascending');
  assert.match(order()[0], /^Older call/);
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'descending');
  assert.match(order()[0], /^Ship the board first/);
  assert.ok(rowFor(byTestId(root, 'roadmap-open-decisions')[0], 'Render cadence'), 'the open question row');
});

test('R7 ADD an open decision, then DECIDE it in the modal with expected_status open', async () => {
  const calls = await mountAt(BOARD, backend());
  await ready();
  const form = () => byTestId(root, 'roadmap-decision-add')[0];
  const kind = byName(form(), 'kind');
  kind.value = 'open';
  fire(kind, 'change');
  await flush();
  type(byName(form(), 'title'), 'Who approves waves?');
  await flush();
  fire(form(), 'submit');
  fire(form(), 'submit');
  await waitFor(() => rowFor(byTestId(root, 'roadmap-open-decisions')[0], 'Who approves waves?'), 'the new open row', describe);
  assert.equal(posts(calls, 'decisions').length, 1, 'single-flight add');
  assert.deepEqual(posts(calls, 'decisions')[0].body, { project: 'cromford', kind: 'open', title: 'Who approves waves?', body: '' });
  const row = rowFor(byTestId(root, 'roadmap-open-decisions')[0], 'Who approves waves?');
  fire(buttonIn(row, 'DECIDE'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d, 'the in-app dialog');
  assert.ok(!hidden(d));
  assert.ok(byName(d, 'decide-status'), 'the status choice');
  fire(confirmOf(d), 'click');
  await waitFor(() => posts(calls, 'decisions/decide').length === 1, 'the decide post', describe);
  assert.deepEqual(posts(calls, 'decisions/decide')[0].body, { id: 'nd-1', project: 'cromford', status: 'decided', expected_status: 'open' });
  await waitFor(() => rowFor(byTestId(root, 'roadmap-decisions')[0], 'Who approves waves?'), 'the row in DECISIONS', describe);
});

test('R7b a stale decide (409) shows the stored status and reloads', async () => {
  const b = backend({ overrides: { 'POST /api/coord/roadmap/decisions/decide': (u, body, store) => [409, { error: 'stale status', decision: { ...store.board.open_decisions[0], status: 'dropped' } }] } });
  const calls = await mountAt(BOARD, b);
  await ready();
  const reads = () => calls.filter((c) => c.method === 'GET').length;
  const before = reads();
  fire(buttonIn(rowFor(byTestId(root, 'roadmap-open-decisions')[0], 'Render cadence'), 'DECIDE'), 'click');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => /Someone decided this first\. It is now dropped\./.test(text(root)), 'the stale line', describe);
  assert.ok(reads() > before, 'the board reloads');
});

test('R8 LINK ISSUE posts the number as an integer; REMOVE confirms in a modal', async () => {
  const calls = await mountAt(BOARD, backend());
  await ready();
  const f = byTestId(card('f1'), 'roadmap-link-form')[0];
  type(byName(f, 'issue'), '42');
  await flush();
  fire(f, 'submit');
  fire(f, 'submit');
  await waitFor(() => posts(calls, 'links').length === 1, 'the link post', describe);
  await flush();
  assert.equal(posts(calls, 'links').length, 1, 'single-flight link');
  assert.deepEqual(posts(calls, 'links')[0].body, { idea_id: 'f1', project: 'cromford', issue: 42 });
  // A non-number never posts.
  const f2 = byTestId(card('f2'), 'roadmap-link-form')[0];
  type(byName(f2, 'issue'), '4x');
  await flush();
  fire(f2, 'submit');
  await flush();
  assert.equal(posts(calls, 'links').length, 1);
  assert.match(text(f2), /issue number/i);
  // REMOVE on a hand link.
  fire(buttonIn(card('f3'), 'REMOVE'), 'click');
  await flush();
  assert.equal(dialogOf(root).attrs['aria-label'], 'Remove the link to #101?');
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => posts(calls, 'links/remove').length === 1, 'the remove post', describe);
  assert.deepEqual(posts(calls, 'links/remove')[0].body, { idea_id: 'f3', project: 'cromford', issue: 101 });
});

test('R9 a failed load shows RETRY, not the empty copy', async () => {
  const b = backend({ overrides: { 'GET /api/coord/roadmap/board': () => [500, { error: 'roadmap_ideas unavailable' }] } });
  await mountAt(BOARD, b);
  // The App shell has RETRY buttons of its own: the one that counts is in the board's error box.
  const box = () => byTestId(root, 'roadmap-board-error')[0];
  await waitFor(() => box() && buttonIn(box(), 'RETRY'), 'the board RETRY button', describe);
  assert.match(text(box()), /roadmap_ideas unavailable|500/);
  assert.doesNotMatch(text(root), /No ideas/);
  assert.equal(byTestId(root, 'roadmap-board').length, 0);
});

test('R9b while loading: 4 lane headers in the skeleton; zero cards: the empty copy', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const b = backend({ board: { ...clone(FIXTURE), columns: { ideas: [], next: [], now: [], shipped: [] }, decisions: [], open_decisions: [] } });
  const calls = routedFetch(b.route);
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (...a) => { await gate; return realFetch(...a); };
  window.location.pathname = '/roadmap/cromford'; window.location.search = '?view=board';
  root = document.createElement('div');
  mount(h(App), root);
  await flush();
  const sk = byTestId(root, 'roadmap-board-skeleton')[0];
  assert.ok(sk, describe());
  assert.match(text(sk), /IDEAS.*NEXT.*NOW.*SHIPPED/);
  release();
  await waitFor(() => /No ideas on this board yet/.test(text(root)), 'the empty copy', describe);
  assert.ok(calls.length >= 1);
});

test('R10 truncated shows the note', async () => {
  const board = { ...clone(FIXTURE), truncated: { ideas: true, links: false, running: false, decisions: false } };
  await mountAt(BOARD, backend({ board }));
  await ready();
  assert.match(text(root), /Showing the newest 5\. Older items are not on this board\./);
});

test('R11 a drop answered 409 says so and reloads', async () => {
  const b = backend({ overrides: { 'POST /api/coord/roadmap/ideas/move': (u, body, store) => [409, { error: 'stale version', idea: { ...store.board.columns.ideas[1], version: 4 } }] } });
  const calls = await mountAt(BOARD, b);
  await ready();
  const reads = () => calls.filter((c) => c.method === 'GET').length;
  const before = reads();
  fire(card('f1'), 'dragstart', { dataTransfer: { setData() {} } });
  fire(col('next'), 'drop');
  await waitFor(() => /Someone changed this idea\. Reloaded\./.test(text(root)), 'the 409 line', describe);
  assert.ok(reads() > before);
  assert.ok(!isDisabled(buttonIn(card('f1'), 'MOVE')), 'the card is usable again');
});

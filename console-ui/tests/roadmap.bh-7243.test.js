import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, routedFetch, all, fire, dialogOf, confirmOf, buttonIn, byName, byTestId, rowsOf, rowFor, type } from './helpers/fake-dom.bh-5750.js';

// BH-7264 (BH-7243.1): the roadmap index, list and idea screens.
//
// The REAL App (ROUTES, Roadmap.js, list-view.js, api.js) is mounted into the
// fake DOM at a /roadmap path, against a stubbed fetch that plays the jobs
// worker through the coord paths with an in-memory store. Clicks, typing and
// submits are fired on the real nodes. window.confirm/alert/prompt throw.
//
// C1  the 4 new api calls: URL and method
// C2  /roadmap: one row per project with counts and a /roadmap/<p> link
// C3  /roadmap/<p>: the idea rows are mounted and not hidden
// C4  ADD IDEA: two submits before the answer post once, with an idem_key
// C4b a failed add keeps its idem_key for the retry
// C5  click TITLE: aria-sort ascending, again: descending
// C6  zero ideas: the empty copy
// C7  a move answered 409 shows the stored row's lane and version
// C8  DISCARD opens the in-app dialog; no native dialog is called
// C9  the idea page: fields, the EDIT form, HISTORY with an edited event
// C10 ?lane=next reads lane=next; a lane chip navigates; truncated shows a note
// C11 the ideas table sits in a .tablewrap; the form has class roadmap-form
// C12 the observable outcome: add (source operator, Enter) -> top row; MOVE TO
//     NEXT + CONFIRM -> LANE Next; the idea page shows 2 events

installDom();
const { render: mount } = await import('preact');
const { App } = await import('../src/app.js');
const { api } = await import('../src/api.js');

// navigate() pushes a URL; the fake window has no real history, so the
// push moves location here.
window.history.pushState = window.history.replaceState = (_s, _t, to) => {
  const u = new URL(to, 'https://mc.fixture.invalid');
  window.location.pathname = u.pathname;
  window.location.search = u.search;
};

const NOW = '2026-10-17T12:00:00Z';
const at = (min) => new Date(Date.parse(NOW) + min * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

// The in-memory worker. Each answer has the shape the jobs route returns
// (worker/jobs/src/routes/roadmap-ideas.js).
function backend({ ideas = [], truncated = false, overrides = {} } = {}) {
  const store = { ideas: ideas.map((i) => ({ ...i })), events: {}, clock: 10 };
  for (const i of store.ideas) store.events[i.id] = [{ id: 1, kind: 'created', from_lane: null, to_lane: 'ideas', actor: 'operator', reason: null, detail: null, at: i.created_at }];
  const tick = () => at(store.clock++);
  const route = (url, method, body) => {
    const u = new URL(url, 'https://mc.fixture.invalid');
    const p = u.pathname;
    const key = `${method} ${p}`;
    if (overrides[key]) return overrides[key](u, body, store);
    if (key === 'GET /api/coord/roadmap/summary') {
      return [200, { projects: [
        { project: 'cromford', counts: { ideas: 2, next: 1, discarded: 0 }, total: 3 },
        { project: 'proj-empty', counts: { ideas: 0, next: 0, discarded: 0 }, total: 0 }], as_of: NOW }];
    }
    if (key === 'GET /api/coord/roadmap/ideas') {
      const lane = u.searchParams.get('lane');
      const rows = store.ideas.filter((i) => !lane || i.lane === lane);
      const counts = { ideas: 0, next: 0, discarded: 0 };
      for (const i of store.ideas) counts[i.lane] += 1;
      return [200, { project: u.searchParams.get('project'), ideas: rows, counts, truncated, as_of: NOW }];
    }
    if (key === 'POST /api/coord/roadmap/ideas') {
      const t = tick();
      const idea = { id: `new-${store.ideas.length + 1}`, project: body.project, title: body.title, note: body.note || null, source: body.source,
        link: body.link || null, lane: 'ideas', version: 1, idem_key: body.idem_key, created_by: 'console', created_at: t, updated_at: t, discarded_at: null };
      store.ideas.push(idea);
      store.events[idea.id] = [{ id: 1, kind: 'created', from_lane: null, to_lane: 'ideas', actor: 'console', reason: null, detail: null, at: t }];
      return [201, { idea }];
    }
    if (key === 'POST /api/coord/roadmap/ideas/move') {
      const idea = store.ideas.find((i) => i.id === body.id);
      if (!idea) return [404, { error: 'idea not found' }];
      if (idea.version !== body.expected_version) return [409, { error: 'stale version', idea }];
      const t = tick();
      store.events[idea.id].push({ id: store.events[idea.id].length + 1, kind: 'moved', from_lane: idea.lane, to_lane: body.to_lane, actor: 'console', reason: null, detail: null, at: t });
      Object.assign(idea, { lane: body.to_lane, version: idea.version + 1, updated_at: t });
      return [200, { idea }];
    }
    if (key === 'POST /api/coord/roadmap/ideas/edit') {
      const idea = store.ideas.find((i) => i.id === body.id);
      if (idea.version !== body.expected_version) return [409, { error: 'stale version', idea }];
      const before = {};
      for (const k of ['title', 'note', 'link', 'source']) if (k in body) { before[k] = idea[k]; idea[k] = body[k]; }
      const t = tick();
      store.events[idea.id].push({ id: store.events[idea.id].length + 1, kind: 'edited', from_lane: null, to_lane: null, actor: 'console', reason: null, detail: JSON.stringify({ before }), at: t });
      Object.assign(idea, { version: idea.version + 1, updated_at: t });
      return [200, { idea }];
    }
    const m = /^\/api\/coord\/roadmap\/ideas\/([^/]+)$/.exec(p);
    if (m && method === 'GET') {
      const idea = store.ideas.find((i) => i.id === decodeURIComponent(m[1]) && i.project === u.searchParams.get('project'));
      if (!idea) return [404, { error: 'idea not found' }];
      return [200, { idea, events: [...store.events[idea.id]].reverse(), as_of: NOW }];
    }
    return [200, {}];
  };
  return { store, route };
}

const IDEA = (id, title, lane, min, extra = {}) => ({
  id, project: 'cromford', title, note: null, source: 'qa', link: null, lane, version: 1, idem_key: null,
  created_by: 'operator', created_at: at(min), updated_at: at(min), discarded_at: null, ...extra
});
const SEED = [IDEA('i1', 'Bravo idea', 'ideas', 1), IDEA('i2', 'Alpha idea', 'ideas', 2), IDEA('i3', 'Charlie idea', 'next', 3)];

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
const text = (n) => n.textContent.replace(/\s+/g, ' ');
const hidden = (n) => {
  for (let p = n; p; p = p.parentNode) {
    if (p.attrs && 'hidden' in p.attrs) return true;
    const css = (p.style && (p.style.cssText || '')) + (p.attrs && p.attrs.style ? p.attrs.style : '');
    if (/display:\s*none/.test(css) || (p.style && p.style.display === 'none')) return true;
  }
  return false;
};
const ideaRows = () => rowsOf(byTestId(root, 'roadmap-ideas')[0]).slice(1);
const titles = () => ideaRows().map((tr) => tr.childNodes[0].textContent.trim());
const cellOf = (tr, i) => tr.childNodes[i].textContent.trim();
const form = () => byTestId(root, 'roadmap-add')[0];
const describe = () => (root ? text(root).slice(0, 600) : '');
// preact writes `value` as an attribute until the fake node has the property.
const valueOf = (n) => (n.value !== undefined ? n.value : n.attrs.value);
// A user's typing renders before the Enter, so each type() is followed by a flush.
const typeIn = async (el, v) => { type(el, v); await flush(); };

test('C1 the 4 new api calls hit the coord paths with the right method', async () => {
  const calls = routedFetch(() => [200, {}]);
  await api.roadmapIdea('cromford', 'a b/c');
  await api.roadmapSummary();
  await api.roadmapMoveIdea({ id: 'i1', project: 'cromford', to_lane: 'next', expected_version: 1 });
  await api.roadmapEditIdea({ id: 'i1', project: 'cromford', note: 'n', expected_version: 2 });
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), [
    'GET /api/coord/roadmap/ideas/a%20b%2Fc?project=cromford',
    'GET /api/coord/roadmap/summary',
    'POST /api/coord/roadmap/ideas/move',
    'POST /api/coord/roadmap/ideas/edit',
  ]);
  assert.equal(calls[2].body.expected_version, 1);
  assert.equal(calls[3].body.note, 'n');
});

test('C2 /roadmap: one row per project with lane counts, and the project links to its list', async () => {
  const b = backend();
  await mountAt('/roadmap', b);
  await waitFor(() => byTestId(root, 'roadmap-summary').length, 'the summary table', describe);
  const t = byTestId(root, 'roadmap-summary')[0];
  const row = rowFor(t, 'cromford');
  assert.ok(row, describe());
  assert.deepEqual([1, 2, 3, 4].map((i) => cellOf(row, i)), ['2', '1', '0', '3']);
  const a = all(row).find((n) => n.localName === 'a');
  assert.equal(a.attrs.href, '/roadmap/cromford');
  assert.ok(rowFor(t, 'proj-empty'), 'a project with 0 ideas is listed');
  assert.ok(!hidden(row));
  fire(a, 'click');
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the list after the project click', describe);
  assert.equal(window.location.pathname, '/roadmap/cromford');
});

test('C3 the idea rows render visible, newest UPDATED first, each title linked to its idea page', async () => {
  const b = backend({ ideas: SEED });
  const calls = await mountAt('/roadmap/cromford?view=list', b);
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  assert.ok(calls.some((c) => c.url === '/api/coord/roadmap/ideas?project=cromford'));
  assert.deepEqual(titles(), ['Charlie idea', 'Alpha idea', 'Bravo idea']);
  for (const tr of ideaRows()) assert.ok(!hidden(tr), 'row is not hidden');
  const r = rowFor(root, 'Charlie idea');
  assert.equal(cellOf(r, 1), 'qa');
  assert.equal(cellOf(r, 2), 'Next');
  const a = all(r).find((n) => n.localName === 'a');
  assert.equal(a.attrs.href, '/roadmap/cromford/idea/i3');
});

test('C4 two submits before the answer post once, with an idem_key; the next add gets a new key', async () => {
  const b = backend({ ideas: SEED });
  const calls = await mountAt('/roadmap/cromford', b);
  await waitFor(() => form(), 'the add form', describe);
  await typeIn(byName(form(), 'title'), 'Double click idea');
  fire(form(), 'submit');
  fire(form(), 'submit');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/roadmap/ideas');
  assert.equal(posts.length, 1, 'one POST for two submits');
  assert.match(posts[0].body.idem_key, /^[A-Za-z0-9._:-]{1,80}$/);
  assert.equal(posts[0].body.title, 'Double click idea');
  assert.equal(valueOf(byName(form(), 'title')), '', 'the form clears after the add');
  await typeIn(byName(form(), 'title'), 'Second idea');
  fire(form(), 'submit');
  await flush();
  const after = calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/roadmap/ideas');
  assert.equal(after.length, 2);
  assert.notEqual(after[1].body.idem_key, after[0].body.idem_key, 'a new key per form open');
  // A blank title never posts.
  fire(form(), 'submit');
  await flush();
  assert.equal(calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/roadmap/ideas').length, 2);
  assert.match(text(form()), /title is required/i);
});

test('C4b a failed add keeps the idem_key, so the retry is a replay, not a second idea', async () => {
  let n = 0;
  const b = backend({ ideas: SEED, overrides: { 'POST /api/coord/roadmap/ideas': (u, body, store) => {
    n += 1;
    if (n === 1) return [503, { error: 'roadmap_ideas unavailable' }];
    return backend().route(u.href, 'POST', body);
  } } });
  const calls = await mountAt('/roadmap/cromford', b);
  await waitFor(() => form(), 'the add form', describe);
  await typeIn(byName(form(), 'title'), 'Retry idea');
  fire(form(), 'submit');
  await waitFor(() => /The add failed/.test(text(form())), 'the failure line', describe);
  assert.equal(valueOf(byName(form(), 'title')), 'Retry idea', 'the typed title is kept');
  fire(form(), 'submit');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/roadmap/ideas');
  assert.equal(posts.length, 2);
  assert.equal(posts[1].body.idem_key, posts[0].body.idem_key, 'the same key on the retry');
});

test('C5 clicking the TITLE header flips aria-sort ascending, then descending', async () => {
  const b = backend({ ideas: SEED });
  await mountAt('/roadmap/cromford', b);
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  const th = () => all(byTestId(root, 'roadmap-ideas')[0]).find((n) => n.localName === 'th' && n.textContent.trim().startsWith('TITLE'));
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'ascending');
  assert.deepEqual(titles(), ['Alpha idea', 'Bravo idea', 'Charlie idea']);
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'descending');
  assert.deepEqual(titles(), ['Charlie idea', 'Bravo idea', 'Alpha idea']);
});

test('C6 zero ideas shows the empty copy, and a lane filter names its lane', async () => {
  const b = backend({ ideas: [] });
  await mountAt('/roadmap/cromford', b);
  await waitFor(() => /No ideas yet/.test(text(root)), 'the empty copy', describe);
  assert.match(text(root), /No ideas yet\. Add the first one above\./);
  assert.ok(form(), 'the add form is there on an empty roadmap');
  mount(null, root); root = null;
  await mountAt('/roadmap/cromford?lane=discarded', backend({ ideas: SEED }));
  await waitFor(() => /No ideas in Discarded/.test(text(root)), 'the lane empty copy', describe);
});

test('C7 a move answered 409 shows the stored row lane and version, and reloads', async () => {
  const stored = IDEA('i2', 'Alpha idea', 'discarded', 2, { version: 3 });
  const b = backend({ ideas: SEED, overrides: { 'POST /api/coord/roadmap/ideas/move': () => [409, { error: 'stale version', idea: stored }] } });
  const calls = await mountAt('/roadmap/cromford', b);
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  const reads = () => calls.filter((c) => c.method === 'GET' && c.url.startsWith('/api/coord/roadmap/ideas?')).length;
  const before = reads();
  fire(buttonIn(rowFor(root, 'Alpha idea'), 'MOVE TO NEXT'), 'click');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => /It is now in Discarded, version 3/.test(text(root)), 'the stale message', describe);
  const status = byTestId(root, 'roadmap-status')[0];
  assert.match(text(status), /Someone changed this idea first\. It is now in Discarded, version 3\./);
  assert.ok(reads() > before, 'the list reloads');
  const move = calls.find((c) => c.url === '/api/coord/roadmap/ideas/move');
  assert.deepEqual(move.body, { id: 'i2', project: 'cromford', to_lane: 'next', expected_version: 1 });
});

test('C8 DISCARD opens the in-app dialog; CANCEL posts nothing; no native dialog is called', async () => {
  const b = backend({ ideas: SEED });
  const calls = await mountAt('/roadmap/cromford', b);
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  fire(buttonIn(rowFor(root, 'Bravo idea'), 'DISCARD'), 'click');
  await flush();
  const d = dialogOf(root);
  assert.ok(d, 'a role=dialog node is mounted');
  assert.equal(d.attrs['aria-label'], 'Discard this idea?');
  assert.match(text(d), /Bravo idea/);
  fire(buttonIn(d, 'CANCEL'), 'click');
  await flush();
  assert.equal(dialogOf(root), undefined);
  assert.equal(calls.filter((c) => c.url === '/api/coord/roadmap/ideas/move').length, 0);
  // CONFIRM moves it; a discarded row then offers RESTORE.
  fire(buttonIn(rowFor(root, 'Bravo idea'), 'DISCARD'), 'click');
  await flush();
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => cellOf(rowFor(root, 'Bravo idea'), 2) === 'Discarded', 'the discarded lane', describe);
  assert.ok(buttonIn(rowFor(root, 'Bravo idea'), 'RESTORE'));
  assert.equal(buttonIn(rowFor(root, 'Bravo idea'), 'DISCARD'), undefined);
  assert.ok(buttonIn(rowFor(root, 'Charlie idea'), 'BACK TO IDEAS'), 'a Next row can go back');
});

test('C9 the idea page: fields, the EDIT form saves only the changed field, HISTORY shows the edit', async () => {
  const b = backend({ ideas: [IDEA('i1', 'Bravo idea', 'ideas', 1, { link: 'https://example.com/spec', note: 'old note' })] });
  const calls = await mountAt('/roadmap/cromford/idea/i1', b);
  await waitFor(() => byTestId(root, 'roadmap-history').length, 'the history table', describe);
  assert.match(text(root), /Bravo idea/);
  const link = all(root).find((n) => n.localName === 'a' && n.attrs.href === 'https://example.com/spec');
  assert.ok(link, 'the link is an anchor');
  const ef = byTestId(root, 'roadmap-edit')[0];
  assert.equal(valueOf(byName(ef, 'title')), 'Bravo idea');
  assert.equal(valueOf(byName(ef, 'note')), 'old note');
  await typeIn(byName(ef, 'note'), 'new note');
  fire(ef, 'submit');
  await waitFor(() => /Edited note/.test(text(byTestId(root, 'roadmap-history')[0])), 'the edited event', describe);
  const e = calls.find((c) => c.url === '/api/coord/roadmap/ideas/edit');
  assert.deepEqual(e.body, { id: 'i1', project: 'cromford', note: 'new note', expected_version: 1 });
  assert.equal(rowsOf(byTestId(root, 'roadmap-history')[0]).length - 1, 2);
  const back = all(root).find((n) => n.localName === 'a' && n.attrs.href === '/roadmap/cromford');
  assert.ok(back, 'a link back to the list');
});

test('C9b an unknown idea is an empty state, not a crash', async () => {
  await mountAt('/roadmap/cromford/idea/nope', backend({ ideas: SEED }));
  await waitFor(() => /This idea does not exist in cromford/.test(text(root)), 'the not-found copy', describe);
});

test('C10 ?lane=next reads lane=next; a lane chip navigates; truncated shows a note', async () => {
  const b = backend({ ideas: SEED, truncated: true });
  const calls = await mountAt('/roadmap/cromford?lane=next', b);
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  assert.ok(calls.some((c) => c.url === '/api/coord/roadmap/ideas?project=cromford&lane=next'), JSON.stringify(calls.map((c) => c.url)));
  assert.deepEqual(titles(), ['Charlie idea']);
  assert.match(text(root), /Showing the newest 1\. Filter by lane to see the rest\./);
  fire(buttonIn(root, 'IDEAS 2'), 'click');
  await waitFor(() => calls.some((c) => c.url === '/api/coord/roadmap/ideas?project=cromford&lane=ideas'), 'the lane=ideas read', describe);
  assert.equal(window.location.search, '?lane=ideas');
  await waitFor(() => titles().length === 2, 'the ideas lane rows', describe);
  // A bad lane value reads every lane.
  mount(null, root); root = null;
  const c2 = await mountAt('/roadmap/cromford?lane=now', backend({ ideas: SEED }));
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  assert.ok(c2.some((c) => c.url === '/api/coord/roadmap/ideas?project=cromford'));
});

test('C11 the ideas table sits in a .tablewrap and the form has class roadmap-form', async () => {
  await mountAt('/roadmap/cromford', backend({ ideas: SEED }));
  await waitFor(() => byTestId(root, 'roadmap-ideas').length, 'the ideas table', describe);
  const table = all(byTestId(root, 'roadmap-ideas')[0]).find((n) => n.localName === 'table');
  assert.ok(table.parentNode.attrs.class.split(/\s+/).includes('tablewrap'));
  assert.ok(form().attrs.class.split(/\s+/).includes('roadmap-form'));
});

test('C12 add with source operator + Enter -> top row; MOVE TO NEXT -> LANE Next; the idea page shows 2 events', async () => {
  const b = backend({ ideas: SEED });
  const calls = await mountAt('/roadmap/cromford?view=list', b);
  await waitFor(() => form(), 'the add form', describe);
  await typeIn(byName(form(), 'title'), 'Observable idea');
  const src = byName(form(), 'source');
  src.value = 'operator';
  fire(src, 'change');
  await flush();
  // Enter in the title input submits the form.
  fire(form(), 'submit');
  await waitFor(() => titles()[0] === 'Observable idea', 'the new idea on top', describe);
  assert.equal(calls.find((c) => c.method === 'POST' && c.url === '/api/coord/roadmap/ideas').body.source, 'operator');
  fire(buttonIn(rowFor(root, 'Observable idea'), 'MOVE TO NEXT'), 'click');
  await flush();
  assert.equal(dialogOf(root).attrs['aria-label'], 'Move to Next?');
  fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => cellOf(rowFor(root, 'Observable idea'), 2) === 'Next', 'LANE Next', describe);
  fire(all(rowFor(root, 'Observable idea')).find((n) => n.localName === 'a'), 'click');
  await waitFor(() => byTestId(root, 'roadmap-history').length, 'the idea page', describe);
  assert.match(window.location.pathname, /^\/roadmap\/cromford\/idea\/new-4$/);
  const hist = rowsOf(byTestId(root, 'roadmap-history')[0]).slice(1);
  assert.equal(hist.length, 2);
  assert.match(text(byTestId(root, 'roadmap-history')[0]), /Moved from Ideas to Next/);
  assert.match(text(byTestId(root, 'roadmap-history')[0]), /Created in Ideas/);
});

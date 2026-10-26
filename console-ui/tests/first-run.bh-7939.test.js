import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, buttonIn, dialogOf } from './helpers/fake-dom.bh-5750.js';

// BH-7977 (BH-7939.3): a new fleet with a missing required account opens `/`
// on the first-run screen, not on the Fleet list. The real FleetScreen is
// mounted in the fake DOM against a routed fetch, so every read goes through
// the real loaders. Any native dialog throws (fake-dom).
//   S1 complete false + gate: FirstRun with 4 cards, no projects rows; both
//      reads start before either answers
//   S2 complete true, or gate false: the projects table, no FirstRun
//   S3 a 503 first-run read: the projects table plus "could not check fleet accounts"
//   S4 the cards sit in one .tiles element, one column at <= 768px
//   S5 the seam paths and the loader errors; every URL is same-origin /api/
//   S6 ADD ACCOUNT opens the add sheet, Escape closes it; the GitHub App and
//      Telegram cards link to their settings rows

installDom();
const { FleetScreen } = await import('../src/screens/Fleet.js');
const { FleetContext } = await import('../src/app.js');
const { AuthError } = await import('../src/api.js');
const { firstRunApi, loadFirstRun, FIRST_RUN_PATH } = await import('../src/lib/first-run.js');

// The worker's answer shape (worker/jobs/test/fleet-first-run.bh-7939.test.js R1).
const ANSWER = (over = {}) => ({
  anthropic: true, github_app: true, telegram: false, more_ai: false, complete: false, gate: true, ...over
});
const PROJECTS = ['alpha-fixture', 'beta-fixture'].map((project) => ({
  project, last_run_age_min: 3, last_summary: 'ok', last_rc: 0, paused: false, automerge: true, fleet: {}
}));

function routes(firstRun) {
  return (u) => {
    if (u === '/api/dash/projects') return [200, { projects: PROJECTS, projects_source: 'fleet_status', snapshot_age_min: 1 }];
    if (u === FIRST_RUN_PATH) return firstRun;
    if (u === '/api/coord/settings') return [200, { settings: [] }];
    return [200, {}];
  };
}

const mounted = new Set();
test.afterEach(() => { for (const root of mounted) mount(null, root); mounted.clear(); });

async function mountFleet() {
  const doc = installDom();
  // The sheet hands focus back to its opener only while it is in the page.
  doc.contains = (n) => all(doc).includes(n);
  const root = doc.createElement('div');
  doc.appendChild(root);
  mount(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)), root);
  mounted.add(root);
  await flush();
  return root;
}
const firstRunOf = (root) => all(root).find((n) => n.attrs && /\bfirst-run\b/.test(n.attrs.class || ''));
const cardsOf = (root) => all(root).filter((n) => n.attrs && n.attrs['data-card']);
const projectRows = (root) => all(root).filter((n) => n.localName === 'tr'
  && n.childNodes[0] && n.childNodes[0].localName === 'td' && /-fixture$/.test(n.childNodes[0].textContent.trim()));

test('S1 complete false with the gate on: FirstRun with 4 cards in order and no project rows; both reads start before either answers', async () => {
  // Every answer waits until the test releases it.
  const calls = [];
  const held = [];
  const route = routes([200, ANSWER()]);
  globalThis.fetch = (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET' });
    return new Promise((resolve) => held.push(() => {
      const [status, payload] = route(u);
      resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(payload) });
    }));
  };
  const root = await mountFleet();
  const urls = calls.map((c) => c.url);
  assert.ok(urls.includes(FIRST_RUN_PATH), `first-run requested: ${urls}`);
  assert.ok(urls.includes('/api/dash/projects'), `projects requested: ${urls}`);
  assert.equal(Boolean(firstRunOf(root)), false, 'nothing answered yet, so no FirstRun');
  while (held.length) held.shift()();
  await flush();
  const fr = firstRunOf(root);
  assert.ok(fr, 'the first-run screen renders');
  assert.deepEqual(cardsOf(root).map((n) => n.attrs['data-card']), ['anthropic', 'github_app', 'telegram', 'more_ai']);
  assert.deepEqual(projectRows(root), [], 'no project list in place of FirstRun');
  assert.match(root.textContent, /Set up the fleet accounts/);
  // Each card's tag says only what the route's flag for that card says.
  const tag = (id) => {
    const t = all(cardsOf(root).find((n) => n.attrs['data-card'] === id)).find((n) => /\btag\b/.test(n.attrs?.class || ''));
    return [t.attrs.class, t.textContent.trim()];
  };
  assert.deepEqual(tag('anthropic'), ['tag tag--green', 'added']);
  assert.deepEqual(tag('github_app'), ['tag tag--green', 'added']);
  assert.deepEqual(tag('telegram'), ['tag tag--warn', 'not added']);
  assert.deepEqual(tag('more_ai'), ['tag tag--idle', 'optional']);
  for (const c of calls) assert.match(c.url, /^\/api\//, 'same-origin only: 0 vendor calls');
});

test('S2 complete true, or the gate off: the projects table and no FirstRun', async () => {
  for (const answer of [ANSWER({ telegram: true, complete: true }), ANSWER({ gate: false })]) {
    const calls = routedFetch(routes([200, answer]));
    const root = await mountFleet();
    assert.ok(calls.some((c) => c.url === FIRST_RUN_PATH), 'first-run is read');
    assert.equal(Boolean(firstRunOf(root)), false, `no FirstRun for ${JSON.stringify(answer)}`);
    assert.equal(projectRows(root).length, 2, 'the project list renders');
    assert.doesNotMatch(root.textContent, /could not check fleet accounts/);
    for (const c of calls) assert.match(c.url, /^\/api\//);
  }
});

test('S3 a failed first-run read: the projects table plus the inline "could not check fleet accounts" line', async () => {
  const calls = routedFetch(routes([503, { error: 'ai_accounts schema not applied' }]));
  const root = await mountFleet();
  assert.equal(Boolean(firstRunOf(root)), false);
  assert.equal(projectRows(root).length, 2);
  assert.match(root.textContent, /could not check fleet accounts — ai_accounts schema not applied/);
  const line = all(root).find((n) => n.attrs && n.attrs.role === 'status' && /could not check fleet accounts/.test(n.textContent));
  assert.ok(line, 'the line is a role=status element');
  for (const c of calls) assert.match(c.url, /^\/api\//);
});

test('S4 the 4 cards are children of one .tiles element, which is one column at <= 768px', async () => {
  routedFetch(routes([200, ANSWER()]));
  const root = await mountFleet();
  const parents = new Set(cardsOf(root).map((n) => n.parentNode));
  assert.equal(parents.size, 1);
  const [grid] = [...parents];
  assert.ok((grid.attrs.class || '').split(/\s+/).includes('tiles'), grid.attrs.class);
  for (const c of cardsOf(root)) assert.ok((c.attrs.class || '').split(/\s+/).includes('tile'), c.attrs.class);
  const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  const at = css.indexOf('@media (max-width: 768px) {');
  assert.ok(at >= 0, 'no 768px media block');
  const block = css.slice(at, css.indexOf('\n}\n', at));
  assert.match(block, /\.tiles \{ grid-template-columns: minmax\(0, 1fr\); \}/);
});

test('S5 the seam calls /api/coord/fleet/first-run; the loader throws AuthError on 403 and a status error on 500', async () => {
  const seen = [];
  const seam = firstRunApi({ get: (p) => { seen.push(p); return Promise.resolve(ANSWER()); }, coordPath: (p) => '/api/coord' + p.replace(/^\/api(?=\/)/, '') });
  await seam.firstRun();
  assert.deepEqual(seen, ['/api/coord/fleet/first-run']);
  assert.equal(FIRST_RUN_PATH, '/api/coord/fleet/first-run');
  const reply = (status, body) => async () => ({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) });
  await assert.rejects(loadFirstRun(reply(403, { error: 'forbidden' })), (e) => e instanceof AuthError);
  await assert.rejects(loadFirstRun(reply(404, { error: 'unauthorized' })), (e) => e instanceof AuthError);
  await assert.rejects(loadFirstRun(reply(500, { error: 'boom' })), (e) => e.status === 500 && e.message === 'boom' && !(e instanceof AuthError));
  await assert.rejects(loadFirstRun(reply(502, null)), (e) => e.status === 502 && e.message === 'http_502');
  await assert.rejects(loadFirstRun(async () => ({ ok: true, status: 200, text: async () => 'not json' })), /bad response/);
  await assert.rejects(loadFirstRun(async () => { throw new Error('x'); }), /network unreachable/);
  const got = await loadFirstRun(reply(200, ANSWER({ complete: true })));
  assert.equal(got.complete, false, 'complete is recomputed from the three required flags');
  const seenInit = [];
  await loadFirstRun(async (u, init) => { seenInit.push([u, init]); return { ok: true, status: 200, text: async () => '{}' }; });
  assert.equal(seenInit[0][0], '/api/coord/fleet/first-run');
  assert.equal(seenInit[0][1].credentials, 'same-origin');
});

test('S6 ADD ACCOUNT on Anthropic and More AI opens the add sheet and Escape closes it; GitHub App and Telegram link to their rows', async () => {
  const calls = routedFetch(routes([200, ANSWER({ anthropic: false })]));
  const root = await mountFleet();
  const card = (id) => cardsOf(root).find((n) => n.attrs['data-card'] === id);
  for (const id of ['anthropic', 'more_ai']) {
    assert.equal(Boolean(dialogOf(root)), false, 'no sheet before the click');
    const btn = buttonIn(card(id), 'ADD ACCOUNT');
    assert.ok(btn, `${id} has ADD ACCOUNT`);
    fire(btn, 'click');
    await flush();
    const d = dialogOf(root);
    assert.ok(d, `${id}: the add sheet opens`);
    assert.equal(d.attrs['aria-label'], 'ADD AI ACCOUNT');
    fire(globalThis.document, 'keydown', { key: 'Escape' });
    await flush();
    assert.equal(Boolean(dialogOf(root)), false, `${id}: Escape closes the sheet`);
  }
  const link = (id) => all(card(id)).find((n) => n.localName === 'a');
  assert.equal(link('github_app').attrs.href, '/config/setting/github_app.installed');
  assert.equal(link('telegram').attrs.href, '/config/setting/telegram.chat_id');
  for (const id of ['github_app', 'telegram']) {
    assert.equal(Boolean(buttonIn(card(id), 'ADD ACCOUNT')), false, `${id} has no button that does nothing`);
    assert.match(card(id).textContent, /The setup sheet is not built yet\./);
  }
  for (const c of calls) assert.match(c.url, /^\/api\//);
});

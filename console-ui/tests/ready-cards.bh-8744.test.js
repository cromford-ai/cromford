// BH-8744 (BH-7935.3): the Ready screen. The pure half
// (src/lib/ready-cards.js) and the mounted screen
// (src/screens/ProjectReady.js) in the fake DOM, plus the Project page's
// READY link through the real router.
//   C1 nine cards in order, each with a title and a sentence
//   C2 the tag rule, every row and its near misses
//   C3 "connected" comes only from a pass (every facts state x facts card)
//   C4 eight cards link to /config; AI account opens the sheet
//   C5 the two actions; no repo means no ticket action
//   M1 the mounted screen: nine cards with the fixture's tags; the AI account
//      Choose button opens the sheet; a written pin reads again, a close does not
//   M2 loading is the skeleton; an error is distinct with Retry; 404 is the
//      not-in-registry line
//   M3 the Project page READY link opens the Ready screen (the entry point)
// Every mount uses the fake DOM of tests/helpers/fake-dom.bh-5750.js, whose
// native dialogs throw. No network: the api is a fake, or fetch is routed.

import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, buttonIn, dialogOf } from './helpers/fake-dom.bh-5750.js';

const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { readyCards, readyActions, READY_CARD_IDS } = await import('../src/lib/ready-cards.js');
const { ProjectReadyScreen } = await import('../src/screens/ProjectReady.js');
const { App } = await import('../src/app.js');

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

// The worker's answer for a seeded project (worker test A1's shape).
const ANSWER = {
  project: 'project-11', repo: 'example-org/project-11', prod: 'https://x.example', box: 'ra-box', tailnet: true,
  account: 'ra-label', fly: true,
  facts: { state: 'pass', vercel: true, qa_account: false, migration_token: true, checked_at: '2026-10-30T08:50:15.000Z' }
};
const TITLES = ['Production URL', 'Preview QA', 'QA test account', 'Fly builder pool', 'Dedicated box and Tailscale',
  'Alerts', 'Migrations', 'Tracker', 'AI account'];
const ANSWER_TAGS = ['connected', 'connected', 'not set', 'connected', 'connected', 'fleet default', 'connected', 'not checked', 'ra-label'];
const tagOf = (state, id) => readyCards(state).find((c) => c.id === id).tag;

// ------------------------------------------------------------------ C1

test('C1 nine cards in the spec order, each with a title and a sentence', () => {
  const cards = readyCards(ANSWER);
  assert.equal(cards.length, 9);
  assert.deepEqual(cards.map((c) => c.title), TITLES);
  assert.deepEqual(cards.map((c) => c.id), READY_CARD_IDS);
  for (const c of cards) assert.match(c.sentence, /^Without it, .+\.$/, c.title);
  assert.equal(new Set(cards.map((c) => c.sentence)).size, 9, 'nine different sentences');
  assert.deepEqual(cards.map((c) => c.tag), ANSWER_TAGS);
});

// ------------------------------------------------------------------ C2

test('C2 the tag rule, every row with both sides and the near misses', () => {
  const base = { ...ANSWER };
  for (const [prod, tag] of [[null, 'not set'], [undefined, 'not set'], ['', 'not set'], ['-', 'not set'],
    ['https://x', 'connected'], ['http://x', 'unknown'], [' https://x', 'unknown'], ['https:/x', 'unknown']]) {
    assert.equal(tagOf({ ...base, prod }, 'prod'), tag, `prod ${JSON.stringify(prod)}`);
  }
  for (const [account, tag] of [[undefined, 'fleet pool'], [null, 'fleet pool'], ['shared', 'fleet pool'],
    [' shared ', 'fleet pool'], ['ra-label', 'ra-label'], ['shared-2', 'shared-2'], ['', 'fleet pool']]) {
    assert.equal(tagOf({ ...base, account }, 'account'), tag, `account ${JSON.stringify(account)}`);
  }
  for (const [fly, tag] of [[true, 'connected'], [false, 'not set'], [undefined, 'not set'], ['true', 'not set']]) {
    assert.equal(tagOf({ ...base, fly }, 'fly'), tag, `fly ${JSON.stringify(fly)}`);
  }
  for (const [box, tailnet, tag] of [[null, false, 'shared box'], ['', true, 'shared box'], [undefined, true, 'shared box'],
    ['ra-box', true, 'connected'], ['ra-box', false, 'not set'], ['ra-box', undefined, 'not set']]) {
    assert.equal(tagOf({ ...base, box, tailnet }, 'box'), tag, `box ${JSON.stringify(box)} tailnet ${tailnet}`);
  }
  const facts = (f) => ({ ...base, facts: f });
  const FACT_CARDS = { vercel: 'vercel', qa: 'qa_account', migrations: 'migration_token' };
  for (const [id, key] of Object.entries(FACT_CARDS)) {
    assert.equal(tagOf(facts({ state: 'pending' }), id), 'checking', `${id} pending`);
    assert.equal(tagOf(facts({ state: 'fail' }), id), 'unknown', `${id} fail`);
    assert.equal(tagOf(facts({ state: 'stale' }), id), 'stale', `${id} stale`);
    assert.equal(tagOf(facts({ state: 'pass', [key]: true }), id), 'connected', `${id} pass true`);
    assert.equal(tagOf(facts({ state: 'pass', [key]: false }), id), 'not set', `${id} pass false`);
    assert.equal(tagOf(facts({ state: 'pass' }), id), 'unknown', `${id} pass with no boolean`);
    assert.equal(tagOf(facts(null), id), 'checking', `${id} no facts`);
  }
  assert.equal(tagOf(base, 'alerts'), 'fleet default');
  assert.equal(tagOf(base, 'tracker'), 'not checked');
  assert.equal(readyCards(null).length, 9, 'no answer still gives nine cards');
});

// ------------------------------------------------------------------ C3

test('C3 "connected" on a facts card comes only from a pass with true', () => {
  for (const state of ['pending', 'fail', 'stale', 'pass', 'nonsense', undefined]) {
    for (const v of [true, false, undefined, 'true', 1]) {
      const s = { ...ANSWER, facts: { state, vercel: v, qa_account: v, migration_token: v } };
      for (const id of ['vercel', 'qa', 'migrations']) {
        const want = state === 'pass' && v === true;
        assert.equal(tagOf(s, id) === 'connected', want, `${id} state ${state} value ${JSON.stringify(v)}`);
      }
    }
  }
  for (const id of ['alerts', 'tracker']) {
    assert.notEqual(tagOf(ANSWER, id), 'connected', `${id} has no stored source`);
  }
});

// ------------------------------------------------------------------ C4

test('C4 eight cards link to /config; AI account opens the sheet', () => {
  for (const c of readyCards(ANSWER)) {
    if (c.id === 'account') assert.deepEqual(c.action, { kind: 'sheet' });
    else assert.deepEqual(c.action, { kind: 'link', href: '/config' }, c.title);
  }
});

// ------------------------------------------------------------------ C5

test('C5 the two actions; a null repo gives no ticket action', () => {
  const a = readyActions('project-11', 'example-org/project-11');
  assert.equal(a.ticket, 'https://github.com/example-org/project-11/issues/new');
  assert.equal(a.project, '/p/project-11');
  assert.equal(readyActions('project-11', null).ticket, null);
  assert.equal(readyActions('project-11', 'not a repo').ticket, null);
  assert.equal(readyActions('project-11', 'o/r?x=1').ticket, null);
});

// ------------------------------------------------------------------ M1-M2

function fakeApi({ answer = ANSWER, fail = null } = {}) {
  const calls = { ready: 0, settings: [] };
  const api = {
    onboardReady: async (p) => {
      calls.ready += 1;
      calls.project = p;
      if (fail) throw fail;
      return answer;
    },
    aiAccounts: async () => ({ accounts: [] }),
    setCoordSetting: async (body) => { calls.settings.push(body); return { ok: true }; }
  };
  return { api, calls };
}

// AiAccountSheet's focus restore asks document.contains (the first-run and
// onboard-envelope suites add it the same way).
const domWithContains = () => {
  const doc = installDom();
  doc.contains = (n) => all(doc).includes(n);
  return doc;
};

async function mountScreen(fake) {
  const doc = domWithContains();
  setUrl('/projects/project-11/ready');
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(ProjectReadyScreen, { project: 'project-11', api: fake.api }), el);
  await flush();
  return el;
}

const cardsIn = (el) => all(el).filter((n) => n.localName === 'article');
const hasClass = (n, c) => String(n.attrs.class || '').split(/\s+/).includes(c);
const tagIn = (card) => all(card).find((n) => n.localName === 'span' && hasClass(n, 'tag'));
const text = (root) => root.textContent.replace(/\s+/g, ' ');

test('M1 nine cards with the fixture tags; Choose opens the sheet; a written pin reads again', async () => {
  const fake = fakeApi();
  const el = await mountScreen(fake);
  assert.equal(fake.calls.ready, 1, 'ONE read');
  assert.equal(fake.calls.project, 'project-11');
  assert.match(text(el), /Ready: project-11/);
  const band = all(el).find((n) => n.localName === 'section' && n.attrs['aria-label'] === 'Connect when you need it');
  assert.ok(band, 'the band');
  const cards = cardsIn(band);
  assert.equal(cards.length, 9);
  assert.deepEqual(cards.map((c) => tagIn(c).textContent.trim()), ANSWER_TAGS);
  // Eight card links to /config, and the two actions.
  const links = all(band).filter((n) => n.localName === 'a');
  assert.equal(links.length, 8);
  for (const a of links) assert.equal(a.attrs.href, '/config');
  const ticket = all(el).find((n) => n.localName === 'a' && n.attrs.href === 'https://github.com/example-org/project-11/issues/new');
  assert.ok(ticket, 'File the first ticket');
  assert.equal(ticket.attrs.target, '_blank');
  assert.equal(ticket.attrs.rel, 'noopener noreferrer');
  assert.ok(all(el).find((n) => n.localName === 'a' && n.attrs.href === '/p/project-11'), 'Open the project');

  // AI account: Choose opens the sheet.
  assert.equal(dialogOf(el), undefined, 'no sheet before the click');
  const account = cards[8];
  fire(buttonIn(account, 'Choose'), 'click');
  await flush();
  const sheet = dialogOf(el);
  assert.ok(sheet, 'the sheet mounted');
  assert.equal(sheet.attrs['aria-label'], 'AI account for project-11');
  // CLOSE writes nothing and does not read again.
  fire(buttonIn(sheet, 'CLOSE'), 'click');
  await flush();
  assert.equal(dialogOf(el), undefined, 'closed');
  assert.equal(fake.calls.ready, 1, 'a close does not read again');
  assert.equal(fake.calls.settings.length, 0);

  // The pool choice, confirmed: written, the sheet closes, the screen reads again.
  fire(buttonIn(cardsIn(el)[8], 'Choose'), 'click');
  await flush();
  fire(buttonIn(dialogOf(el), 'USE THE FLEET POOL'), 'click');
  await flush();
  fire(buttonIn(el, 'UNPIN'), 'click');
  await flush();
  assert.deepEqual(fake.calls.settings.map((s) => [s.key, s.value]), [['account.project-11', 'shared']]);
  assert.equal(fake.calls.ready, 2, 'a written pin reads again');
  assert.equal(dialogOf(el), undefined, 'the sheet closed');
});

test('M2 loading is the skeleton; an error has Retry; a 404 is the not-in-registry line', async () => {
  let release;
  const held = { api: { ...fakeApi().api, onboardReady: () => new Promise((r) => { release = r; }) } };
  const el = await mountScreen(held);
  assert.ok(all(el).some((n) => hasClass(n, 'skel')), 'the skeleton');
  assert.equal(cardsIn(el).length, 0);
  release(ANSWER);
  await flush();
  assert.equal(cardsIn(el).length, 9);

  const err = Object.assign(new Error('http_503'), { status: 503 });
  const failing = fakeApi({ fail: err });
  const el2 = await mountScreen(failing);
  assert.match(text(el2), /The ready read failed\./);
  assert.equal(cardsIn(el2).length, 0);
  fire(buttonIn(el2, 'Retry'), 'click');
  await flush();
  assert.equal(failing.calls.ready, 2, 'Retry reads again');

  const missing = fakeApi({ fail: Object.assign(new Error('unknown_project'), { status: 404 }) });
  const el3 = await mountScreen(missing);
  assert.match(text(el3), /This project is not in the registry yet\./);
  assert.doesNotMatch(text(el3), /The ready read failed/);
  assert.ok(all(el3).find((n) => n.localName === 'a' && n.attrs.href === '/p/project-11'), 'Open the project');
});

test('M2b no repo on record: no ticket action, and the line says so', async () => {
  const el = await mountScreen(fakeApi({ answer: { ...ANSWER, repo: null } }));
  assert.equal(all(el).find((n) => n.localName === 'a' && String(n.attrs.href || '').startsWith('https://github.com/')), undefined);
  assert.match(text(el), /No repo on record\./);
});

// ------------------------------------------------------------------ M3

test('M3 the Project page READY link opens the Ready screen through the real router', async () => {
  const doc = domWithContains();
  setUrl('/p/project-11');
  const calls = routedFetch((u) => {
    if (u.startsWith('/api/coord/onboarding/ready/')) return [200, ANSWER];
    if (u.startsWith('/api/dash/projects')) return [200, { projects: [{ project: 'project-11' }] }];
    if (u.startsWith('/api/dash/p/')) return [200, { runs: [], builds: [], alerts: [], board: {} }];
    if (u.startsWith('/api/coord/settings')) return [200, { settings: [] }];
    return [200, {}];
  });
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(App), el);
  await flush();
  const link = all(el).find((n) => n.localName === 'a' && n.attrs.href === '/projects/project-11/ready');
  assert.ok(link, 'the Project page has the READY link');
  assert.equal(link.textContent.trim(), 'READY');
  fire(link, 'click');
  await flush();
  assert.equal(window.location.pathname, '/projects/project-11/ready');
  assert.ok(calls.some((c) => c.url === '/api/coord/onboarding/ready/project-11'), 'the screen read its route');
  assert.equal(cardsIn(el).length, 9);
});

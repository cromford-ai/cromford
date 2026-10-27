// BH-7972 (BH-7940.4): the prompt history actions in the editor, the three
// history calls and the proxy shapes they go through.
//
// PromptVersionsSheet and UseLevelAboveButton are mounted for real in the fake
// DOM, alone and inside the real PromptEditor. lib/prompt-history.js is the
// only caller of fetch here; the stub throws on a URL outside /api/prompts, so
// a pass makes 0 vendor calls. window.confirm / alert / prompt throw (the fake
// DOM installs them), so a native dialog fails the case. The proxy cases call
// onRequest with a local fetch stub.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, buttonIn, buttonsIn, confirmOf } from './helpers/fake-dom.bh-5750.js';

const doc = installDom();
const { PromptVersionsSheet, UseLevelAboveButton } = await import('../src/ui/PromptHistoryActions.js');
const { PromptEditor } = await import('../src/ui/PromptEditor.js');
const H = await import('../src/lib/prompt-history.js');
const { onRequest } = await import('../functions/api/prompts/[[path]].js');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const KINDS = ['rules', 'watcher', 'plan', 'execute', 'review', 'fix-round', 'qa'];

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });
const mountIn = (node) => {
  const el = doc.createElement('div');
  mounted.add(el);
  mount(node, el);
  return el;
};

// ------------------------------------------------------------- fixtures

// The keys GET /api/prompts/:scope/:kind/versions answers with
// (worker/jobs/src/routes/prompt-history.js, asserted by versions-no-body in
// worker/jobs/test/prompt-history.bh-7972.test.js).
const vrow = (version, author, note, created_at) => ({ id: 100 + version, version, author, note, created_at });
const V3 = [
  vrow(3, 'zz-c@example.test', 'restored from v1', '2026-10-25T10:00:00Z'),
  vrow(2, 'zz-b@example.test', 'second', '2026-10-24T10:00:00Z'),
  vrow(1, 'zz-a@example.test', 'first', '2026-10-23T10:00:00Z')
];

const outside = (u) => { throw new Error(`a call outside /api/prompts: ${u}`); };

// The history routes as a local stub; `on` overrides an answer by method.
function historyApi({ rows = V3, post = () => [201, { id: 204, version: 4, restored_from: 1 }], del = () => [200, { dropped: 1 }] } = {}) {
  return routedFetch((u, method, body) => {
    if (!u.startsWith('/api/prompts')) outside(u);
    const url = new URL(u, 'http://console.test');
    if (method === 'POST') return post(url, body);
    if (method === 'DELETE') return del(url);
    if (url.pathname.endsWith('/versions')) {
      return [200, { scope: 'project', project: url.searchParams.get('project') || '', kind: 'plan', versions: rows, limit: 200 }];
    }
    if (url.pathname === '/api/prompts') {
      return [200, { project: url.searchParams.get('project') || '', prompts: KINDS.map((k) => ({ kind: k, source: 'repo', version: null, version_id: null, author: null, set_at: null })) }];
    }
    return [404, { error: 'not_found' }];
  });
}

const dialogNamed = (el, re) => all(el).find((n) => n.attrs && n.attrs.role === 'dialog' && re.test(n.attrs['aria-label'] || ''));
const sheetOf = (el) => dialogNamed(el, /^Versions of /);
const confirmDialog = (el) => all(el).find((n) => n.attrs && n.attrs.role === 'dialog' && (n.attrs.class || '').split(/\s+/).includes('modal'));
const bodyRows = (el) => all(el).filter((n) => n.localName === 'tbody').flatMap((tb) => tb.childNodes.filter((c) => c.localName === 'tr'));
const cellsOf = (tr) => tr.childNodes.filter((c) => c.localName === 'td').map((td) => td.textContent.trim());
const lines = (el, role) => all(el).filter((n) => n.attrs && n.attrs.role === role).map((n) => n.textContent.trim());
const hasClass = (n, c) => (n.attrs.class || '').split(/\s+/).includes(c);

async function openSheet(el) {
  const btn = buttonIn(el, 'VERSIONS');
  assert.ok(btn, 'a VERSIONS button');
  fire(btn, 'click');
  await flush();
  const sheet = sheetOf(el);
  assert.ok(sheet, 'VERSIONS opens the sheet');
  return sheet;
}

// ------------------------------------------------------------- the sheet

test('restore-per-row: VERSIONS opens the sheet; 3 rows, 3 RESTORE buttons; 0 fetches before the click', async () => {
  const calls = historyApi();
  const el = mountIn(h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan', onRestored() {} }));
  await flush();
  assert.equal(calls.length, 0, 'nothing is read on mount');
  assert.equal(sheetOf(el), undefined);
  const sheet = await openSheet(el);
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['GET /api/prompts/project/plan/versions?project=zz-p']);
  assert.equal(sheet.attrs['aria-modal'], 'true');
  const rows = bodyRows(sheet);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows.map((r) => cellsOf(r)[0]), ['v3', 'v2', 'v1'], 'newest first');
  assert.deepEqual(cellsOf(rows[2]).slice(0, 4), ['v1', 'zz-a@example.test', '2026-10-23 10:00Z', 'first']);
  assert.equal(buttonsIn(sheet).filter((b) => b.textContent.trim() === 'RESTORE').length, 3);
  // CLOSE and Escape close it; a second open reads again.
  fire(buttonIn(sheet, 'CLOSE'), 'click');
  await flush();
  assert.equal(sheetOf(el), undefined);
  const again = await openSheet(el);
  fire(again, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(sheetOf(el), undefined, 'Escape closes the sheet');
  assert.equal(calls.length, 2);
});

test('sheet-states: skeleton while the read runs, an empty list, and a failed read', async () => {
  let release;
  globalThis.fetch = (u) => {
    if (!String(u).startsWith('/api/prompts')) outside(u);
    return new Promise((r) => { release = r; });
  };
  const el = mountIn(h(PromptVersionsSheet, { scope: 'fleet', kind: 'qa' }));
  await flush();
  let sheet = await openSheet(el);
  assert.ok(all(sheet).some((n) => n.attrs && hasClass(n, 'skel')), 'skeleton rows while loading');
  release({ ok: true, status: 200, text: async () => JSON.stringify({ versions: [] }) });
  await flush();
  sheet = sheetOf(el);
  assert.match(sheet.textContent, /No saved versions\./);
  assert.equal(bodyRows(sheet).length, 0);

  const calls = routedFetch(() => [502, { error: 'harness-jobs unreachable' }]);
  const el2 = mountIn(h(PromptVersionsSheet, { scope: 'fleet', kind: 'qa' }));
  await flush();
  await openSheet(el2);
  assert.equal(calls[0].url, '/api/prompts/fleet/qa/versions', 'a fleet read sends no project');
  assert.ok(lines(el2, 'alert').some((l) => l === 'could not load — harness-jobs unreachable'), JSON.stringify(lines(el2, 'alert')));
});

test('aria-sort-headers: each sortable header has aria-sort; a click flips it; the action column does not sort', async () => {
  historyApi();
  const el = mountIn(h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  const sheet = await openSheet(el);
  const ths = all(sheet).filter((n) => n.localName === 'th');
  assert.equal(ths.length, 5);
  const sortable = ths.filter((th) => th.attrs['aria-sort'] !== undefined);
  assert.deepEqual(sortable.map((th) => th.textContent.replace(/[↑↓]/g, '').trim()), ['VERSION', 'WHO', 'WHEN', 'NOTE']);
  assert.equal(sortable[0].attrs['aria-sort'], 'descending');
  fire(buttonsIn(sortable[0])[0], 'click');
  await flush();
  const s2 = sheetOf(el);
  const th0 = all(s2).filter((n) => n.localName === 'th')[0];
  assert.equal(th0.attrs['aria-sort'], 'ascending');
  assert.deepEqual(bodyRows(s2).map((r) => cellsOf(r)[0]), ['v1', 'v2', 'v3']);
  // WHO sorts by the author text.
  const who = all(s2).filter((n) => n.localName === 'th')[1];
  fire(buttonsIn(who)[0], 'click');
  await flush();
  assert.deepEqual(bodyRows(sheetOf(el)).map((r) => cellsOf(r)[1]), ['zz-a@example.test', 'zz-b@example.test', 'zz-c@example.test']);
});

test('sheet-under-640: the sheet sits in .tablewrap; the css makes it a bottom sheet under 640 px, tokens only', async () => {
  historyApi();
  const el = mountIn(h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  const sheet = await openSheet(el);
  assert.ok(hasClass(sheet, 'prompt-versions'));
  const wrap = all(sheet).find((n) => n.attrs && hasClass(n, 'tablewrap'));
  assert.ok(wrap, 'the table is inside .tablewrap');
  assert.ok(all(wrap).some((n) => n.localName === 'table'));

  const css = fs.readFileSync(path.join(root, 'src/styles.css'), 'utf8');
  const media = css.match(/@media \(max-width: 639px\) \{([\s\S]*?)\n\}/g) || [];
  const block = media.find((m) => /\.prompt-versions\s*\{/.test(m));
  assert.ok(block, 'a @media (max-width: 639px) block styles .prompt-versions');
  const rule = block.match(/\.prompt-versions\s*\{([^}]*)\}/)[1];
  assert.match(rule, /position:\s*fixed/);
  assert.match(rule, /bottom:\s*0/);
  assert.match(rule, /left:\s*0/);
  assert.match(rule, /right:\s*0/);
  assert.match(rule, /width:\s*100%/);
  assert.match(css, /\n\.tablewrap\s*\{[^}]*overflow-x:\s*auto/);
  // Touch targets: the sheet buttons are at least 44 px tall.
  assert.match(css, /\n\.prompt-versions \.btn\s*\{[^}]*min-height:\s*44px/);
  const own = [...css.matchAll(/(^|\n)\s*(\.prompt-versions[^{]*)\{([^}]*)\}/g)];
  assert.ok(own.length >= 3);
  for (const m of own) assert.doesNotMatch(m[3], /#[0-9a-f]{3,8}\b|rgba?\(/i, m[2]);
});

test('confirm-before-restore: RESTORE opens the confirm modal; 0 POSTs until confirm; then 1 POST and onRestored once', async () => {
  const calls = historyApi();
  let restored = 0;
  const el = mountIn(h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan', onRestored: () => { restored++; } }));
  await flush();
  const sheet = await openSheet(el);
  const row = bodyRows(sheet).find((r) => cellsOf(r)[0] === 'v1');
  fire(buttonIn(row, 'RESTORE'), 'click');
  await flush();
  const modal = confirmDialog(el);
  assert.ok(modal, 'the confirm modal opens');
  assert.equal(modal.attrs['aria-label'], 'RESTORE v1');
  assert.match(modal.textContent, /v4|new version/);
  assert.equal(calls.filter((c) => c.method !== 'GET').length, 0, 'no POST before CONFIRM');
  fire(confirmOf(modal), 'click');
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, '/api/prompts/project/plan/restore?project=zz-p&version=1');
  assert.deepEqual(posts[0].body, {}, 'the client sends no author');
  assert.equal(restored, 1);
  assert.equal(sheetOf(el), undefined, 'the sheet closes');
  assert.ok(lines(el, 'status').includes('Restored v1 as v4.'), JSON.stringify(lines(el, 'status')));
});

test('confirm-before-drop: USE LEVEL ABOVE opens the confirm modal; then 1 DELETE and onDropped once', async () => {
  const calls = historyApi();
  let dropped = 0;
  const el = mountIn(h(UseLevelAboveButton, { scope: 'project', project: 'zz-p', kind: 'plan', onDropped: () => { dropped++; } }));
  await flush();
  assert.equal(calls.length, 0);
  fire(buttonIn(el, 'USE LEVEL ABOVE'), 'click');
  await flush();
  const modal = confirmDialog(el);
  assert.ok(modal);
  assert.match(modal.textContent, /the fleet override if one exists, else the repo file/);
  assert.equal(calls.length, 0, 'no DELETE before CONFIRM');
  fire(confirmOf(modal), 'click');
  await flush();
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['DELETE /api/prompts/project/plan/head?project=zz-p']);
  assert.equal(calls[0].body, undefined, 'a DELETE sends no body');
  assert.equal(dropped, 1);
  assert.ok(lines(el, 'status').includes('Override dropped. The level above is in use.'), JSON.stringify(lines(el, 'status')));

  // Fleet scope: the repo file takes over; {dropped: 0} says so plainly.
  const c2 = historyApi({ del: () => [200, { dropped: 0 }] });
  const el2 = mountIn(h(UseLevelAboveButton, { scope: 'fleet', kind: 'rules', onDropped() {} }));
  await flush();
  fire(buttonIn(el2, 'USE LEVEL ABOVE'), 'click');
  await flush();
  const m2 = confirmDialog(el2);
  assert.match(m2.textContent, /the repo file/);
  assert.doesNotMatch(m2.textContent, /fleet override/);
  fire(confirmOf(m2), 'click');
  await flush();
  assert.equal(c2[0].url, '/api/prompts/fleet/rules/head');
  assert.ok(lines(el2, 'status').includes('No override at this level.'));
});

test('cancel-sends-nothing: Escape or CANCEL on either modal makes 0 writes', async () => {
  const calls = historyApi();
  let restored = 0;
  let dropped = 0;
  const el = mountIn(h('div', null,
    h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan', onRestored: () => { restored++; } }),
    h(UseLevelAboveButton, { scope: 'project', project: 'zz-p', kind: 'plan', onDropped: () => { dropped++; } })));
  await flush();
  const sheet = await openSheet(el);
  fire(buttonIn(bodyRows(sheet)[0], 'RESTORE'), 'click');
  await flush();
  fire(buttonIn(confirmDialog(el), 'CANCEL'), 'click');
  await flush();
  assert.equal(confirmDialog(el), undefined);
  assert.ok(sheetOf(el), 'CANCEL on the modal keeps the sheet open');
  fire(buttonIn(bodyRows(sheetOf(el))[1], 'RESTORE'), 'click');
  await flush();
  fire(doc, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(confirmDialog(el), undefined);
  fire(buttonIn(el, 'USE LEVEL ABOVE'), 'click');
  await flush();
  fire(buttonIn(confirmDialog(el), 'CANCEL'), 'click');
  await flush();
  assert.equal(calls.filter((c) => c.method !== 'GET').length, 0);
  assert.deepEqual([restored, dropped], [0, 0]);
});

test('refusal-shown: a 422 names the marker, a 404 archived says so, the sheet stays open', async () => {
  const answers = [
    [[422, { error: 'missing_marker', missing: ['VERDICT:'] }], 'Restore refused. Missing marker: VERDICT:'],
    [[404, { error: 'archived' }], 'v2 is archived. It cannot be restored.'],
    [[404, { error: 'not_found' }], 'v2 was not found.'],
    [[409, { error: 'version_conflict' }], 'Someone saved a newer version first. Open VERSIONS again.'],
    [[502, { error: 'harness-jobs unreachable' }], 'The restore failed: harness-jobs unreachable']
  ];
  for (const [answer, want] of answers) {
    historyApi({ post: () => answer });
    let restored = 0;
    const el = mountIn(h(PromptVersionsSheet, { scope: 'project', project: 'zz-p', kind: 'plan', onRestored: () => { restored++; } }));
    await flush();
    const sheet = await openSheet(el);
    fire(buttonIn(bodyRows(sheet)[1], 'RESTORE'), 'click');
    await flush();
    fire(confirmOf(confirmDialog(el)), 'click');
    await flush();
    assert.ok(sheetOf(el), 'the sheet stays open on a refusal');
    assert.ok(lines(sheetOf(el), 'alert').includes(want), `${JSON.stringify(answer)}: ${JSON.stringify(lines(el, 'alert'))}`);
    assert.equal(restored, 0);
  }
});

test('drop-refusal-shown: a failed drop says so and does not reload', async () => {
  historyApi({ del: () => [502, { error: 'harness-jobs unreachable' }] });
  let dropped = 0;
  const el = mountIn(h(UseLevelAboveButton, { scope: 'project', project: 'zz-p', kind: 'plan', onDropped: () => { dropped++; } }));
  await flush();
  fire(buttonIn(el, 'USE LEVEL ABOVE'), 'click');
  await flush();
  fire(confirmOf(confirmDialog(el)), 'click');
  await flush();
  assert.ok(lines(el, 'alert').includes('The drop failed: harness-jobs unreachable'), JSON.stringify(lines(el, 'alert')));
  assert.equal(dropped, 0);
});

test('no-native-dialogs: the new sources call no window.confirm, alert or prompt', () => {
  for (const f of ['src/ui/PromptHistoryActions.js', 'src/lib/prompt-history.js']) {
    const code = fs.readFileSync(path.join(root, f), 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.ok(code.length > 0, f);
    assert.doesNotMatch(code, /window\.(confirm|alert|prompt)\b|(^|[^\w.])(confirm|alert|prompt)\s*\(/m, f);
  }
  // The fake DOM's natives throw, so the flows above could not have used them.
  assert.throws(() => window.confirm('x'), /native dialog/);
});

test('editor-renders-real-actions: the real PromptEditor mounts both buttons; VERSIONS opens the sheet', async () => {
  const calls = historyApi();
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  assert.ok(buttonIn(el, 'VERSIONS'), 'VERSIONS in the editor');
  assert.ok(buttonIn(el, 'USE LEVEL ABOVE'), 'USE LEVEL ABOVE in the editor');
  const before = calls.length;
  const sheet = await openSheet(el);
  assert.equal(calls.length, before + 1);
  assert.equal(bodyRows(sheet).length, 3);
  // A restore reloads the editor's reads.
  fire(buttonIn(bodyRows(sheet)[2], 'RESTORE'), 'click');
  await flush();
  const n = calls.length;
  fire(confirmOf(confirmDialog(el)), 'click');
  await flush();
  assert.ok(calls.slice(n + 1).some((c) => c.url.startsWith('/api/prompts?')), 'onRestored re-ran the editor reads');
  for (const c of calls) assert.ok(c.url.startsWith('/api/prompts'), c.url);
});

// ------------------------------------------------------------- lib

test('lib: the three calls build the proxy paths; a bad list body throws', async () => {
  const calls = routedFetch((u, method) => (method === 'GET' ? [200, { versions: 'nope' }] : [200, { dropped: 1 }]));
  await assert.rejects(H.listVersions({ scope: 'project', project: 'a.b', kind: 'qa' }), /bad response/);
  await H.dropHead({ scope: 'fleet', project: 'ignored', kind: 'qa' });
  await H.restoreVersion({ scope: 'fleet', kind: 'review', version: 7 });
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), [
    'GET /api/prompts/project/qa/versions?project=a.b',
    'DELETE /api/prompts/fleet/qa/head',
    'POST /api/prompts/fleet/review/restore?version=7'
  ]);
});

// ------------------------------------------------------------- the proxy

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
function proxyFetch() {
  const seen = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url.startsWith(CONSOLE)) return new Response('', { status: 200 });
    if (!url.startsWith(JOBS)) throw new Error(`a call outside the jobs worker: ${url}`);
    seen.push({ url, method: init.method, headers: new Headers(init.headers || {}), body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return seen;
}
let seq = 0;
const proxy = ({ method = 'GET', segs, search = '', body }) => onRequest({
  request: new Request(`https://console.example.pages.dev/api/prompts/${segs.join('/')}${search}`, {
    method, headers: { 'content-type': 'application/json', cookie: `dash=bh7972-fixture-${++seq}` }, body
  }),
  env: { HARNESS_SECRET: 'sec-fixture-7972' },
  params: { path: segs }
});

test('proxy-new-shapes: versions, restore and head are forwarded with the bearer; restore carries version and the resolved author', async () => {
  const seen = proxyFetch();
  let res = await proxy({ segs: ['project', 'plan', 'versions'], search: '?project=alpha&version=9' });
  assert.equal(res.status, 200);
  res = await proxy({ method: 'POST', segs: ['project', 'plan', 'restore'], search: '?project=alpha&version=3&author=mallory', body: '{"author":"mallory","body":"smuggled"}' });
  assert.equal(res.status, 200);
  res = await proxy({ method: 'DELETE', segs: ['fleet', 'rules', 'head'] });
  assert.equal(res.status, 200);
  assert.deepEqual(seen.map((s) => `${s.method} ${s.url}`), [
    `GET ${JOBS}/api/prompts/project/plan/versions?project=alpha`,
    `POST ${JOBS}/api/prompts/project/plan/restore?project=alpha&version=3`,
    `DELETE ${JOBS}/api/prompts/fleet/rules/head`
  ]);
  for (const s of seen) {
    assert.equal(s.headers.get('authorization'), 'Bearer sec-fixture-7972');
    assert.equal(s.headers.get('cookie'), null);
  }
  // A restore forwards the resolved author and nothing the browser sent.
  const fwd = JSON.parse(seen[1].body);
  assert.equal(fwd.author, 'console');
  assert.deepEqual(Object.keys(fwd), ['author']);
  assert.equal(seen[2].body, undefined);
});

test('proxy-wrong-method-405: wrong method or segment pairs are 405 or 400 with 0 jobs fetches', async () => {
  const seen = proxyFetch();
  const cases = [
    ['DELETE', ['project', 'plan', '1'], 405],
    ['POST', ['project', 'plan', '1'], 405],
    ['GET', ['project', 'plan', 'restore'], 405],
    ['POST', ['project', 'plan', 'versions'], 405],
    ['DELETE', ['project', 'plan', 'versions'], 405],
    ['GET', ['project', 'plan', 'head'], 405],
    ['POST', ['project', 'plan', 'head'], 405],
    ['DELETE', ['project', 'plan', 'restore'], 405],
    ['DELETE', ['project', 'plan'], 405],
    ['GET', ['project', 'plan', 'versions', 'x'], 405],
    ['GET', ['project', 'plan', 'Versions'], 400],
    ['GET', ['project', 'plan', 'toString'], 400],
    ['DELETE', ['team', 'plan', 'head'], 400]
  ];
  for (const [method, segs, want] of cases) {
    const res = await proxy({ method, segs, search: '?project=alpha', body: method === 'POST' ? '{}' : undefined });
    assert.equal(res.status, want, `${method} ${segs.join('/')}`);
  }
  for (const v of ['0', '01', 'abc', '', '1234567890']) {
    const res = await proxy({ method: 'POST', segs: ['project', 'plan', 'restore'], search: `?project=alpha&version=${v}`, body: '{}' });
    assert.equal(res.status, 400, `version=${v}`);
  }
  const none = await proxy({ method: 'POST', segs: ['project', 'plan', 'restore'], search: '?project=alpha', body: '{}' });
  assert.equal(none.status, 400, 'no version');
  assert.equal(seen.length, 0);
});

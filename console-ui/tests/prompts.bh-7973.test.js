// BH-7973 (BH-7940.5): the prompts list and editor in the settings shell.
//
// The list (src/screens/Prompts.js) and the editor (src/ui/PromptEditor.js)
// are mounted for real in the fake DOM, through PromptsScreen and through the
// settings shell. lib/prompts.js is driven directly for the diff, the marker
// lint and the two read rounds. Every fetch is a local stub that throws on a
// URL outside /api/prompts: 0 vendor calls. Each case builds its own rows.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import {
  installDom, routedFetch, all, fire, dialogOf, buttonIn, confirmOf, isDisabled, type
} from './helpers/fake-dom.bh-5750.js';

// A window whose history really moves location, so navigate() after a save
// is seen by useSearchParam and the screen swaps the editor for the list.
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/settings/p/zz-p/prompts', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: {
    pushState(_s, _t, to) { setUrl(to); },
    replaceState(_s, _t, to) { setUrl(to); }
  },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};
const doc = installDom();

const P = await import('../src/lib/prompts.js');
const { AuthError } = await import('../src/api.js');
const { PromptsScreen } = await import('../src/screens/Prompts.js');
const { PromptEditor } = await import('../src/ui/PromptEditor.js');
const { SETTINGS_MENU, findItem, menuFor } = await import('../src/lib/settings-menu.js');
const { SETTINGS_SCREENS, SettingsShellView } = await import('../src/screens/settings/Shell.js');

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

const repoRow = (kind) => ({ kind, source: 'repo', version: null, version_id: null, author: null, set_at: null });
const headRow = (kind, source, version, author = 'zz-author@example.test') =>
  ({ kind, source, version, version_id: 100 + version, author, set_at: '2026-10-20T10:00:00Z' });
// Seven rows in kind order with the given heads swapped in.
const rowsWith = (...heads) => KINDS.map((k) => heads.find((r) => r.kind === k) || repoRow(k));

const outside = (u) => { throw new Error(`a call outside /api/prompts: ${u}`); };

// The contract routes as a local stub. `own` is the project list (the project
// head, else the fleet head, else repo, as listHeads answers); `fleet` the
// fleet list; `bodies` maps "<scope>/<kind>/<version>" to a body.
function promptApi({ own = rowsWith(), fleet = rowsWith(), bodies = {}, onPost = () => [500, { error: 'no post expected' }] } = {}) {
  const state = { own, fleet };
  const calls = routedFetch((u, method, body) => {
    if (!u.startsWith('/api/prompts')) outside(u);
    const url = new URL(u, 'http://console.test');
    if (method === 'POST') return onPost(url, body, state);
    if (url.pathname === '/api/prompts') {
      const p = url.searchParams.get('project');
      return [200, { project: p || '', prompts: p ? state.own : state.fleet, as_of: '2026-10-23T00:00:00Z' }];
    }
    const key = url.pathname.slice('/api/prompts/'.length);
    if (!(key in bodies)) return [404, { error: 'not_found' }];
    const [scope, kind, version] = key.split('/');
    return [200, { prompt: { scope, kind, version: Number(version), body: bodies[key], author: 'zz-author@example.test', note: '' } }];
  });
  return { calls, state };
}

// A fetch that holds every answer until the test releases it, so a test can
// see which requests started before any of them came back.
function heldFetch(route) {
  const calls = [];
  globalThis.fetch = (url, init = {}) => {
    const u = String(url);
    if (!u.startsWith('/api/prompts')) return Promise.reject(new Error(`a call outside /api/prompts: ${u}`));
    return new Promise((resolve) => {
      calls.push({
        url: u,
        released: false,
        release() {
          this.released = true;
          const [status, payload] = route(u);
          resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(payload) });
        }
      });
    });
  };
  return calls;
}

const valueOf = (n) => (n.value !== undefined ? n.value : n.attrs.value);
const textareas = (el) => all(el).filter((n) => n.localName === 'textarea');
const editorText = (el) => textareas(el).find((n) => (n.attrs.class || '').split(' ').includes('prompt-editor__text'));
const byClass = (el, cls) => all(el).filter((n) => n.nodeType === 1 && (n.attrs.class || '').split(/\s+/).includes(cls));
const byTestId = (el, id) => all(el).find((n) => n.attrs && n.attrs['data-testid'] === id);
const bodyRows = (el) => all(el).filter((n) => n.localName === 'tbody').flatMap((tb) => tb.childNodes.filter((c) => c.localName === 'tr'));
const cellsOf = (tr) => tr.childNodes.filter((c) => c.localName === 'td').map((td) => td.textContent.trim());
const statusLines = (el) => all(el).filter((n) => n.attrs && n.attrs.role === 'status').map((n) => n.textContent.trim());
const alertLines = (el) => all(el).filter((n) => n.attrs && n.attrs.role === 'alert').map((n) => n.textContent.trim());
const diffLines = (panel, cls) => byClass(panel, cls).map((n) => n.textContent);

// ------------------------------------------------------------- lib

test('diff-against-previous: lineDiff marks the added line only', () => {
  assert.deepEqual(P.lineDiff('a\nc', 'a\nb\nc'), [
    { op: ' ', text: 'a' }, { op: '+', text: 'b' }, { op: ' ', text: 'c' }
  ]);
  assert.deepEqual(P.lineDiff('a\nb\nc', 'a\nX\nc'), [
    { op: ' ', text: 'a' }, { op: '-', text: 'b' }, { op: '+', text: 'X' }, { op: ' ', text: 'c' }
  ]);
  assert.deepEqual(P.lineDiff('x\ny\nz', 'y\nz\nw'), [
    { op: '-', text: 'x' }, { op: ' ', text: 'y' }, { op: ' ', text: 'z' }, { op: '+', text: 'w' }
  ]);
  // An empty body has no lines, not one blank line.
  assert.deepEqual(P.lineDiff('', 'one'), [{ op: '+', text: 'one' }]);
  assert.deepEqual(P.lineDiff('same', 'same'), [{ op: ' ', text: 'same' }]);
});

test('diff-crlf: CRLF and LF bodies with the same lines have no change', () => {
  const d = P.lineDiff('a\r\nb', 'a\nb');
  assert.deepEqual(d, [{ op: ' ', text: 'a' }, { op: ' ', text: 'b' }]);
  assert.equal(d.filter((x) => x.op !== ' ').length, 0);
});

test('lint-negatives: missingMarkers is a case-sensitive substring check', () => {
  const cat = { review: ['VERDICT:', 'TIER:', '## Requirements coverage'] };
  const miss = (body) => P.missingMarkers('review', body, cat);
  // Must report missing.
  assert.deepEqual(miss('verdict: ok\nTIER: 1\n## Requirements coverage'), ['VERDICT:']);
  assert.deepEqual(miss('VERDICT ok\nTIER: 1\n## Requirements coverage'), ['VERDICT:']);
  assert.deepEqual(miss('VERDICT: ok\nTIER : 1\n## Requirements coverage'), ['TIER:']);
  assert.deepEqual(miss('VERDICT: ok\nTIER: 1\n## Requirements'), ['## Requirements coverage']);
  assert.deepEqual(miss(''), ['VERDICT:', 'TIER:', '## Requirements coverage']);
  // Must NOT report missing.
  assert.deepEqual(miss('TIER: 1\n## Requirements coverage\nVERDICT:'), []);
  assert.deepEqual(miss('```\nVERDICT:\nTIER:\n## Requirements coverage\n```'), []);
  assert.deepEqual(miss('VERDICT: x\r\nTIER: 1\r\n## Requirements coverage\r\n'), []);
  // A kind with no list, or an unknown kind, has nothing to report.
  assert.deepEqual(P.missingMarkers('plan', '', cat), []);
  assert.deepEqual(P.missingMarkers('nope', '', cat), []);
});

test('repo-path: the level-above file follows docs/PROMPTS.md', () => {
  assert.equal(P.repoPath('rules', 'zz-p'), 'rules/CLAUDE.md');
  assert.equal(P.repoPath('watcher', 'zz-p'), 'prompts/zz-p.md');
  assert.equal(P.repoPath('watcher', ''), 'prompts/<project>.md');
  assert.equal(P.repoPath('plan', 'zz-p'), 'prompts/stages/plan.md');
  assert.equal(P.repoPath('fix-round'), 'prompts/stages/fix-round.md');
  assert.equal(P.listHref('fleet'), '/settings/fleet/prompts');
  assert.equal(P.listHref('project', 'a b'), '/settings/p/a%20b/prompts');
  assert.deepEqual([...P.PROMPT_KINDS], KINDS);
});

test('auth-error: a 403 from the proxy is the console AuthError; other errors carry status and body', async () => {
  routedFetch((u) => (u.startsWith('/api/prompts') ? [403, { error: 'unauthorized' }] : outside(u)));
  await assert.rejects(P.listPrompts('zz-p'), (e) => e instanceof AuthError);
  routedFetch((u) => (u.startsWith('/api/prompts') ? [409, { error: 'version_conflict' }] : outside(u)));
  await assert.rejects(P.savePrompt({ scope: 'fleet', kind: 'plan', body: 'x', note: 'n', baseVersion: 0 }),
    (e) => e.status === 409 && e.body.error === 'version_conflict');
});

test('load-editor-parallel: each round starts all its reads before any answer', async () => {
  const own = rowsWith(headRow('plan', 'project', 3));
  const fleet = rowsWith(headRow('plan', 'fleet', 7));
  const bodies = { 'project/plan/3': 'p3', 'project/plan/2': 'p2', 'fleet/plan/7': 'f7' };
  const calls = heldFetch((u) => {
    const url = new URL(u, 'http://console.test');
    if (url.pathname === '/api/prompts') return [200, { prompts: url.searchParams.get('project') ? own : fleet }];
    const key = url.pathname.slice('/api/prompts/'.length);
    return [200, { prompt: { version: Number(key.split('/')[2]), body: bodies[key] } }];
  });
  const done = P.loadEditor({ scope: 'project', project: 'zz-p', kind: 'plan' });
  await flush();
  assert.deepEqual(calls.map((c) => c.url).sort(), ['/api/prompts', '/api/prompts?project=zz-p']);
  calls.forEach((c) => c.release());
  await flush();
  assert.deepEqual(calls.slice(2).map((c) => c.url).sort(), [
    '/api/prompts/fleet/plan/7', '/api/prompts/project/plan/2?project=zz-p', '/api/prompts/project/plan/3?project=zz-p'
  ]);
  assert.equal(calls.slice(2).filter((c) => c.released).length, 0);
  calls.slice(2).forEach((c) => c.release());
  const ed = await done;
  assert.equal(calls.length, 5);
  assert.equal(ed.baseVersion, 3);
  assert.equal(ed.startText, 'p3');
  assert.equal(ed.previous.body, 'p2');
  assert.equal(ed.previous.version, 2);
  assert.deepEqual({ level: ed.above.level, version: ed.above.version, body: ed.above.body }, { level: 'fleet', version: 7, body: 'f7' });
});

// ------------------------------------------------------------- list

test('list: seven sortable rows, sources named, the kind cell links to the editor, in a scroll box', async () => {
  setUrl('/settings/p/zz-p/prompts');
  const { calls } = promptApi({ own: rowsWith(headRow('watcher', 'project', 1), headRow('plan', 'fleet', 4)) });
  const el = mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  await flush();
  assert.deepEqual(calls.map((c) => c.url), ['/api/prompts?project=zz-p']);
  const rows = bodyRows(el);
  assert.equal(rows.length, 7);
  const ths = all(el).filter((n) => n.localName === 'th');
  assert.equal(ths.length, 5);
  for (const th of ths) assert.ok('aria-sort' in th.attrs || th.childNodes.some((c) => c.localName === 'button'), 'every header sorts');
  const kindTh = ths.find((th) => th.textContent.includes('KIND'));
  assert.equal(kindTh.attrs['aria-sort'], 'ascending');
  assert.deepEqual(rows.map((r) => cellsOf(r)[0]), KINDS);
  const byKind = (k) => cellsOf(rows.find((r) => cellsOf(r)[0] === k));
  assert.deepEqual(byKind('watcher').slice(0, 4), ['watcher', 'project override', '1', 'zz-author@example.test']);
  assert.deepEqual(byKind('plan').slice(0, 3), ['plan', 'fleet override', '4']);
  assert.deepEqual(byKind('rules').slice(0, 2), ['rules', 'repo default']);
  const link = all(rows[1]).find((n) => n.localName === 'a');
  assert.equal(link.attrs.href, '/settings/p/zz-p/prompts?kind=watcher');
  const table = all(el).find((n) => n.localName === 'table');
  assert.ok((table.parentNode.attrs.class || '').split(' ').includes('tablewrap'));

  // KIND sorts both ways.
  fire(all(kindTh).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.deepEqual(bodyRows(el).map((r) => cellsOf(r)[0]), [...KINDS].reverse());
});

test('list-skeleton: seven placeholder rows while the one read runs', async () => {
  setUrl('/settings/p/zz-p/prompts');
  const calls = heldFetch(() => [200, { prompts: rowsWith() }]);
  const el = mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  await flush();
  assert.equal(byClass(el, 'skel').length, 7);
  assert.equal(bodyRows(el).length, 0);
  assert.deepEqual(calls.map((c) => c.url), ['/api/prompts?project=zz-p']);
  calls[0].release();
  await flush();
  assert.equal(byClass(el, 'skel').length, 0);
  assert.equal(bodyRows(el).length, 7);
});

test('list-fleet-scope: no project on the read, editor links under /settings/fleet', async () => {
  setUrl('/settings/fleet/prompts');
  const { calls } = promptApi({ fleet: rowsWith(headRow('rules', 'fleet', 2)) });
  const el = mountIn(h(PromptsScreen, { scope: 'fleet' }));
  await flush();
  assert.deepEqual(calls.map((c) => c.url), ['/api/prompts']);
  const plan = bodyRows(el).find((r) => cellsOf(r)[0] === 'plan');
  assert.equal(all(plan).find((n) => n.localName === 'a').attrs.href, '/settings/fleet/prompts?kind=plan');
  assert.deepEqual(cellsOf(bodyRows(el)[0]).slice(0, 3), ['rules', 'fleet override', '2']);
});

test('list-error and unknown-kind: a failed read says so; ?kind=nope shows the list', async () => {
  setUrl('/settings/p/zz-p/prompts?kind=nope');
  routedFetch((u) => (u.startsWith('/api/prompts') ? [503, { error: 'prompt_versions missing' }] : outside(u)));
  const el = mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  await flush();
  assert.match(el.textContent, /could not load/);
  assert.match(el.textContent, /prompt_versions missing/);
  assert.equal(editorText(el), undefined);

  // With a good read, ?kind=nope is the list: one list read, seven rows, no editor.
  const { calls } = promptApi({ own: rowsWith(headRow('plan', 'project', 1)) });
  const el2 = mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  await flush();
  assert.deepEqual(calls.map((c) => c.url), ['/api/prompts?project=zz-p']);
  assert.equal(bodyRows(el2).length, 7);
  assert.equal(editorText(el2), undefined);
});

// ------------------------------------------------------------- editor

test('editor-textarea: one full-width editor textarea holds the head body', async () => {
  setUrl('/settings/fleet/prompts?kind=plan');
  promptApi({ fleet: rowsWith(headRow('plan', 'fleet', 1)), bodies: { 'fleet/plan/1': 'plan body v1' } });
  const el = mountIn(h(PromptsScreen, { scope: 'fleet' }));
  await flush();
  const tas = textareas(el).filter((n) => (n.attrs.class || '').includes('prompt-editor__text'));
  assert.equal(tas.length, 1);
  assert.equal(valueOf(tas[0]), 'plan body v1');
  const back = all(el).find((n) => n.localName === 'a' && n.textContent.includes('ALL PROMPTS'));
  assert.equal(back.attrs.href, '/settings/fleet/prompts');
});

test('lint-shows-missing-verdict: the lint names the missing marker in place', async () => {
  promptApi({ fleet: rowsWith(headRow('review', 'fleet', 1)), bodies: { 'fleet/review/1': 'TIER: 1\nbody' } });
  const el = mountIn(h(PromptEditor, { scope: 'fleet', kind: 'review', markers: { review: ['TIER:', 'VERDICT:'] } }));
  await flush();
  const lines = statusLines(el);
  assert.ok(lines.some((l) => l.includes('Missing marker: VERDICT:')), JSON.stringify(lines));
  assert.ok(!lines.some((l) => l.includes('TIER:')), JSON.stringify(lines));
  // Typing the marker clears it.
  type(editorText(el), 'TIER: 1\nVERDICT: ok');
  await flush();
  assert.ok(!statusLines(el).some((l) => l.includes('Missing marker')));
  assert.ok(statusLines(el).some((l) => l.includes('Markers: all present')));
  // An empty catalog list (the shipped catalog until BH-7940.4) shows no lint line.
  const el2 = mountIn(h(PromptEditor, { scope: 'fleet', kind: 'review', markers: { review: [] } }));
  await flush();
  assert.equal(statusLines(el2).filter((l) => /marker/i.test(l)).length, 0);
});

async function openSaveDialog(el, text) {
  type(editorText(el), text);
  await flush();
  const save = buttonIn(el, 'SAVE');
  assert.ok(save && !isDisabled(save), 'SAVE is enabled after an edit');
  fire(save, 'click');
  await flush();
  const dialog = dialogOf(el);
  assert.ok(dialog, 'SAVE opens the confirm modal');
  return dialog;
}

test('save-opens-confirm-modal: note required, one POST without author, then the list shows the new head', async () => {
  setUrl('/settings/p/zz-p/prompts?kind=watcher');
  const posts = [];
  const { calls } = promptApi({
    onPost: (url, body, state) => {
      posts.push({ url: url.pathname + url.search, body });
      state.own = rowsWith(headRow('watcher', 'project', 1, 'zz-owner@example.test'));
      return [201, { id: 9, version: 1 }];
    }
  });
  const el = mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  await flush();
  assert.equal(valueOf(editorText(el)), '');
  assert.ok(isDisabled(buttonIn(el, 'SAVE')), 'SAVE is off while nothing changed');
  const dialog = await openSaveDialog(el, 'watch zz-p closely');
  assert.equal(posts.length, 0, 'no POST before CONFIRM');
  assert.match(dialog.textContent, /watcher/);
  assert.match(dialog.textContent, /zz-p/);
  const confirm = confirmOf(dialog);
  assert.ok(isDisabled(confirm), 'CONFIRM waits for a note');
  const note = textareas(dialog)[0];
  type(note, '   ');
  await flush();
  assert.ok(isDisabled(confirmOf(dialogOf(el))), 'a blank note keeps CONFIRM off');
  type(note, 'first override');
  await flush();
  assert.ok(!isDisabled(confirmOf(dialogOf(el))));
  fire(confirmOf(dialogOf(el)), 'click');
  await flush();
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, '/api/prompts/project/watcher?project=zz-p');
  assert.deepEqual(posts[0].body, { body: 'watch zz-p closely', note: 'first override', base_version: 0 });
  assert.ok(!('author' in posts[0].body));
  assert.equal(window.location.pathname + window.location.search, '/settings/p/zz-p/prompts');
  const row = bodyRows(el).find((r) => cellsOf(r)[0] === 'watcher');
  assert.ok(row, 'the list is back');
  assert.deepEqual(cellsOf(row).slice(0, 4), ['watcher', 'project override', '1', 'zz-owner@example.test']);
  assert.equal(calls.filter((c) => c.method === 'GET' && c.url === '/api/prompts?project=zz-p').length, 2, 'the editor read once, the list read fresh');
});

test('save-cancel-writes-nothing: CANCEL closes the modal, sends nothing and keeps the text', async () => {
  const posts = [];
  promptApi({
    fleet: rowsWith(headRow('plan', 'fleet', 2)),
    bodies: { 'fleet/plan/2': 'v2', 'fleet/plan/1': 'v1' },
    onPost: (url, body) => { posts.push(body); return [201, { id: 1, version: 3 }]; }
  });
  const el = mountIn(h(PromptEditor, { scope: 'fleet', kind: 'plan' }));
  await flush();
  const dialog = await openSaveDialog(el, 'v2 changed');
  fire(buttonIn(dialog, 'CANCEL'), 'click');
  await flush();
  assert.equal(dialogOf(el), undefined);
  assert.equal(posts.length, 0);
  assert.equal(valueOf(editorText(el)), 'v2 changed');
});

test('save-422-names-marker: a server refusal names the marker and keeps the text', async () => {
  const posts = [];
  promptApi({
    own: rowsWith(headRow('review', 'project', 2)),
    bodies: { 'project/review/2': 'VERDICT: x', 'project/review/1': 'old' },
    onPost: (url, body) => { posts.push(body); return [422, { error: 'missing_marker', missing: ['VERDICT:'] }]; }
  });
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'review', markers: { review: [] } }));
  await flush();
  const dialog = await openSaveDialog(el, 'no marker here');
  type(textareas(dialog)[0], 'drop it');
  await flush();
  fire(confirmOf(dialogOf(el)), 'click');
  await flush();
  assert.equal(posts.length, 1);
  assert.equal(posts[0].base_version, 2);
  const lines = alertLines(el);
  assert.ok(lines.some((l) => l.includes('The server refused the save. Missing marker: VERDICT:')), JSON.stringify(lines));
  assert.equal(valueOf(editorText(el)), 'no marker here');
});

test('save-refusals: 409, 413, empty body and a network failure each get one plain line', async () => {
  const answers = [
    [[409, { error: 'version_conflict' }], /saved a newer version first/],
    [[413, { error: 'body_too_large', max_bytes: 262144 }], /262144 bytes/],
    [[422, { error: 'empty_body' }], /refused an empty body/],
    [[502, { error: 'harness-jobs unreachable' }], /The save failed: harness-jobs unreachable/]
  ];
  for (const [answer, want] of answers) {
    promptApi({ fleet: rowsWith(headRow('qa', 'fleet', 1)), bodies: { 'fleet/qa/1': 'q' }, onPost: () => answer });
    const el = mountIn(h(PromptEditor, { scope: 'fleet', kind: 'qa' }));
    await flush();
    const dialog = await openSaveDialog(el, 'q2');
    type(textareas(dialog)[0], 'n');
    await flush();
    fire(confirmOf(dialogOf(el)), 'click');
    await flush();
    assert.ok(alertLines(el).some((l) => want.test(l)), `${answer[0]}: ${JSON.stringify(alertLines(el))}`);
    assert.equal(valueOf(editorText(el)), 'q2');
  }
});

test('diff-against-previous: the editor diffs the head against the version before it', async () => {
  promptApi({
    own: rowsWith(headRow('plan', 'project', 3)),
    bodies: { 'project/plan/3': 'a\nb\nc', 'project/plan/2': 'a\nc' }
  });
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  const panel = byTestId(el, 'diff-previous');
  assert.ok(panel, 'the previous-version panel renders');
  assert.match(panel.textContent, /version 2/i);
  assert.deepEqual(diffLines(panel, 'prompt-diff__add'), ['+ b']);
  assert.deepEqual(diffLines(panel, 'prompt-diff__del'), []);
  // The diff follows the text.
  type(editorText(el), 'a\nc\nd');
  await flush();
  assert.deepEqual(diffLines(byTestId(el, 'diff-previous'), 'prompt-diff__add'), ['+ d']);
});

test('diff-previous-states: no head, version 1 and an archived version each say so', async () => {
  const cases = [
    [rowsWith(), {}, /No saved version yet\./],
    [rowsWith(headRow('plan', 'project', 1)), { 'project/plan/1': 'one' }, /No previous version\./],
    [rowsWith(headRow('plan', 'project', 5)), { 'project/plan/5': 'five' }, /Version 4 is archived\./]
  ];
  for (const [own, bodies, want] of cases) {
    promptApi({ own, bodies });
    const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan' }));
    await flush();
    assert.match(byTestId(el, 'diff-previous').textContent, want);
    assert.ok(editorText(el), 'the editor still works');
  }
});

test('diff-level-above: project diffs against the fleet head, fleet names the repo file', async () => {
  const { calls } = promptApi({
    own: rowsWith(headRow('plan', 'project', 1)),
    fleet: rowsWith(headRow('plan', 'fleet', 4)),
    bodies: { 'project/plan/1': 'x\ny', 'fleet/plan/4': 'x' }
  });
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  assert.ok(calls.some((c) => c.url === '/api/prompts/fleet/plan/4'));
  const above = byTestId(el, 'diff-above');
  assert.match(above.textContent, /fleet version 4/i);
  assert.deepEqual(diffLines(above, 'prompt-diff__add'), ['+ y']);

  // No project head: the editor starts from the fleet body, base_version 0.
  const posts = [];
  promptApi({
    own: rowsWith(headRow('plan', 'fleet', 4)),
    fleet: rowsWith(headRow('plan', 'fleet', 4)),
    bodies: { 'fleet/plan/4': 'fleet text' },
    onPost: (url, body) => { posts.push(body); return [201, { id: 2, version: 1 }]; }
  });
  const el3 = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan', onSaved() {} }));
  await flush();
  assert.equal(valueOf(editorText(el3)), 'fleet text');
  const d = await openSaveDialog(el3, 'fleet text\nmore');
  type(textareas(d)[0], 'n');
  await flush();
  fire(confirmOf(dialogOf(el3)), 'click');
  await flush();
  assert.equal(posts[0].base_version, 0);

  promptApi({ fleet: rowsWith(headRow('plan', 'fleet', 1)), bodies: { 'fleet/plan/1': 'p' } });
  const el2 = mountIn(h(PromptEditor, { scope: 'fleet', kind: 'plan' }));
  await flush();
  const repo = byTestId(el2, 'diff-above');
  assert.match(repo.textContent, /prompts\/stages\/plan\.md/);
  assert.match(repo.textContent, /The console cannot read it\./);
});

test('editor-parallel-reads: round 1 and round 2 each start every read before any answer', async () => {
  const own = rowsWith(headRow('review', 'project', 2));
  const fleet = rowsWith(headRow('review', 'fleet', 9));
  const bodies = { 'project/review/2': 'r2', 'project/review/1': 'r1', 'fleet/review/9': 'f9' };
  const calls = heldFetch((u) => {
    const url = new URL(u, 'http://console.test');
    if (url.pathname === '/api/prompts') return [200, { prompts: url.searchParams.get('project') ? own : fleet }];
    const key = url.pathname.slice('/api/prompts/'.length);
    return [200, { prompt: { version: Number(key.split('/')[2]), body: bodies[key] } }];
  });
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'review' }));
  await flush();
  assert.equal(calls.length, 2, 'round 1: both lists started');
  calls.forEach((c) => c.release());
  await flush();
  assert.equal(calls.length, 5, 'round 2: head, previous and fleet bodies started together');
  assert.equal(calls.slice(2).filter((c) => c.released).length, 0);
  calls.slice(2).forEach((c) => c.release());
  await flush();
  assert.equal(calls.length, 5);
  assert.equal(valueOf(editorText(el)), 'r2');
});

test('history-seam-rendered: both seam components get scope, project, kind and a reload callback', async () => {
  const { calls } = promptApi({ own: rowsWith(headRow('qa', 'project', 1)), bodies: { 'project/qa/1': 'q' } });
  const seen = {};
  const Versions = (props) => { seen.versions = props; return h('i', { class: 'zz-versions' }, 'VERSIONS STUB'); };
  const LevelAbove = (props) => { seen.above = props; return h('i', { class: 'zz-above' }, 'ABOVE STUB'); };
  const el = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'qa', Versions, LevelAbove }));
  await flush();
  assert.match(el.textContent, /VERSIONS STUB/);
  assert.match(el.textContent, /ABOVE STUB/);
  for (const p of [seen.versions, seen.above]) {
    assert.equal(p.scope, 'project');
    assert.equal(p.project, 'zz-p');
    assert.equal(p.kind, 'qa');
  }
  assert.equal(typeof seen.versions.onRestored, 'function');
  assert.equal(typeof seen.above.onDropped, 'function');
  const before = calls.length;
  seen.versions.onRestored();
  await flush();
  assert.ok(calls.length > before, 'onRestored re-runs the reads');

  // The real seam renders nothing and the editor still works.
  promptApi({ own: rowsWith(headRow('qa', 'project', 1)), bodies: { 'project/qa/1': 'q' } });
  const el2 = mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'qa' }));
  await flush();
  assert.equal(valueOf(editorText(el2)), 'q');
});

// ------------------------------------------------------------- menu and entry point

test('menu: the Prompts rows are built and have hrefs', () => {
  const src = fs.readFileSync(path.join(root, 'src/lib/settings-menu.js'), 'utf8');
  assert.ok(src.includes("id: 'prompts'"), 'the menu still has prompts rows');
  assert.ok(!src.includes('wave 6b'));
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'prompts').tag, undefined);
  assert.equal(findItem(SETTINGS_MENU, 'project', 'prompts').tag, undefined);
  const href = (scope, project) => menuFor(SETTINGS_MENU, { scope, project, page: 'lanes' })
    .flatMap((g) => g.items).find((i) => i.id === 'prompts').href;
  assert.equal(href('fleet'), '/settings/fleet/prompts');
  assert.equal(href('project', 'zz-p'), '/settings/p/zz-p/prompts');
  assert.equal(SETTINGS_SCREENS.prompts, PromptsScreen);
});

test('entry-point: the settings shell menu links to Prompts and mounts the list', async () => {
  setUrl('/settings/p/zz-p/lanes');
  const projects = { data: { projects: [{ project: 'zz-p' }] }, error: null, loading: false };
  const stub = { ...SETTINGS_SCREENS, lanes: () => h('p', null, 'LANES STUB') };
  const el = mountIn(h(SettingsShellView, { screens: stub, scope: 'project', project: 'zz-p', page: 'lanes', projects }));
  await flush();
  const link = all(el).find((n) => n.localName === 'a' && n.textContent.trim() === 'Prompts');
  assert.ok(link, 'the Prompts row is a link');
  assert.equal(link.attrs.href, '/settings/p/zz-p/prompts');

  setUrl('/settings/p/zz-p/prompts');
  const { calls } = promptApi({ own: rowsWith(headRow('watcher', 'project', 1)) });
  const el2 = mountIn(h(SettingsShellView, { scope: 'project', project: 'zz-p', page: 'prompts', projects }));
  await flush();
  assert.deepEqual(calls.map((c) => c.url), ['/api/prompts?project=zz-p']);
  assert.equal(bodyRows(el2).length, 7);
  assert.doesNotMatch(el2.textContent, /Not built yet/);
});

// ------------------------------------------------------------- static

test('css: the table and the diff scroll in their own box, the textarea is full width, tokens only', () => {
  const css = fs.readFileSync(path.join(root, 'src/styles.css'), 'utf8');
  const rule = (sel) => {
    const m = css.match(new RegExp(`(^|\\n)${sel.replace(/[.]/g, '\\.')}\\s*\\{([^}]*)\\}`));
    assert.ok(m, `a ${sel} rule exists`);
    return m[2];
  };
  assert.match(rule('.tablewrap'), /overflow-x:\s*auto/);
  assert.match(rule('.prompt-editor__text'), /width:\s*100%/);
  assert.match(rule('.prompt-editor__text'), /font-family:\s*var\(--font-mono\)/);
  assert.match(rule('.prompt-diff'), /overflow-x:\s*auto/);
  const promptRules = [...css.matchAll(/(^|\n)(\.prompt-[^{]*)\{([^}]*)\}/g)];
  assert.ok(promptRules.length >= 4);
  for (const m of promptRules) assert.doesNotMatch(m[3], /#[0-9a-f]{3,8}\b|rgba?\(/i, m[2]);
});

test('no-native-dialogs: the three new sources call no window.confirm, alert or prompt', () => {
  for (const f of ['src/screens/Prompts.js', 'src/ui/PromptEditor.js', 'src/lib/prompts.js']) {
    const code = fs.readFileSync(path.join(root, f), 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.ok(code.length > 0, f);
    assert.doesNotMatch(code, /window\.(confirm|alert|prompt)\b|(^|[^\w.])(confirm|alert|prompt)\s*\(/m, f);
  }
});

test('zero-network: a full list-and-editor pass asks only /api/prompts', async () => {
  setUrl('/settings/p/zz-p/prompts');
  const { calls } = promptApi({
    own: rowsWith(headRow('plan', 'project', 2)),
    fleet: rowsWith(headRow('plan', 'fleet', 1)),
    bodies: { 'project/plan/2': 'b', 'project/plan/1': 'a', 'fleet/plan/1': 'f' }
  });
  mountIn(h(PromptsScreen, { scope: 'project', project: 'zz-p' }));
  mountIn(h(PromptEditor, { scope: 'project', project: 'zz-p', kind: 'plan' }));
  await flush();
  assert.ok(calls.length >= 5);
  for (const c of calls) assert.ok(c.url.startsWith('/api/prompts'), c.url);
  assert.equal(calls.filter((c) => /^[a-z]+:\/\//i.test(c.url)).length, 0);
});

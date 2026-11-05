import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { accountRows, checkAccountLabel, makeAccountSetter } from '../src/lib/project-accounts.js';
import { ProjectAccountsView } from '../src/screens/ProjectAccounts.js';
import { SettingsView } from '../src/screens/Settings.js';
import { tabsFrom } from '../src/lib/settings.js';

// BH-1657: which Claude account each fleet project bills. The assignment is a
// settings row `account.<project>` holding a LABEL; this is where an operator
// reads and sets it. The worker PUT refuses a token-shaped value; the console
// refuses it first so the operator sees why before anything is sent.

const settings = [
  { key: 'account.project-3', value: 'own:project-3', actor: 'console', updated_at: '2026-09-23T19:00:00Z' },
  { key: 'account.project-4', value: 'shared', actor: 'console', updated_at: '2026-09-23T18:00:00Z' },
  { key: 'account.retired-os', value: 'own:retired', actor: 'console', updated_at: '2026-09-20T10:00:00Z' },
  { key: 'lane.merge-conductor.mc_max_prs', value: '8', actor: 'console', updated_at: '2026-09-22T10:00:00Z' },
];

test('accountRows: one row per project, the union of the fleet and the account rows', () => {
  const rows = accountRows(settings, ['project-4', 'project-3', 'project-5-os']);
  assert.deepEqual(rows.map((r) => r.project), ['project-3', 'project-4', 'project-5-os', 'retired-os']);
  const by = Object.fromEntries(rows.map((r) => [r.project, r]));
  assert.equal(by['project-3'].label, 'own:project-3');
  assert.equal(by['project-3'].actor, 'console');
  assert.equal(by['project-4'].label, null, '`shared` is the explicit unpin, not a label');
  assert.equal(by['project-4'].actor, 'console', 'who unpinned it still shows');
  assert.equal(by['project-5-os'].label, null, 'no row = shared pool');
  assert.equal(by['project-5-os'].actor, null);
  assert.equal(by['retired-os'].label, 'own:retired', 'a pin on a project that left the fleet is still shown');
  assert.equal(rows.find((r) => r.project === 'merge-conductor.mc_max_prs'), undefined, 'lane knobs are not accounts');
});

test('accountRows: absent inputs are an empty list, never a throw', () => {
  assert.deepEqual(accountRows(null, null), []);
  assert.deepEqual(accountRows({ settings: [] }, []), []);
});

test('checkAccountLabel mirrors the worker rule', () => {
  for (const v of ['own:project-3', 'shared', 'max1', 'a@b.c']) assert.equal(checkAccountLabel(v).ok, true, v);
  for (const v of ['sk-ant-x', 'sk-ant-oat01-abc', 'a/b', '../x', 'own..project-3', '.x', '', '   ', 'x'.repeat(65)]) {
    const r = checkAccountLabel(v);
    assert.equal(r.ok, false, `accepted ${JSON.stringify(v)}`);
    assert.ok(r.message && !r.message.includes('sk-ant'), 'the refusal never repeats a token back');
  }
});

test('makeAccountSetter: the in-app confirm comes first, and a cancel writes nothing', async () => {
  const writes = []; const asked = [];
  let answer = false;
  const setter = makeAccountSetter({
    confirm: async (o) => { asked.push(o); return answer; },
    writeSetting: async (b) => { writes.push(b); return { setting: b }; },
    onNote: () => {},
  });
  const row = { project: 'project-3', label: null };
  assert.equal((await setter.set(row, 'own:project-3')).status, 'cancelled');
  assert.equal(writes.length, 0);
  assert.match(String(asked[0].body), /project-3 will bill account own:project-3/);
  answer = true;
  assert.equal((await setter.set(row, ' own:project-3 ')).status, 'written');
  assert.deepEqual(writes, [{ key: 'account.project-3', value: 'own:project-3', actor: 'console' }]);
  assert.equal((await setter.set(row, 'sk-ant-x')).status, 'invalid');
  assert.equal(writes.length, 1, 'a token-shaped value never reaches the worker');
  await setter.set(row, 'shared');
  assert.match(String(asked.at(-1).body), /back to the shared pool/);
});

const view = (over = {}) => render(h(ProjectAccountsView, {
  rows: accountRows(settings, ['project-3', 'project-5-os']),
  error: null, loading: false, busy: null, guard: (_k, fn) => fn(), onSet: () => {},
  ...over,
}));

test('the table renders: sortable headers, linked project cells, shared pool, a scroll box', () => {
  const html = view();
  assert.match(html, /<table/);
  assert.match(html, /class="tablewrap/, 'the table scrolls in its own box, never the page');
  assert.equal((html.match(/aria-sort=/g) || []).length, 4, 'four sortable headers');
  assert.ok(html.includes('href="/settings?project=project-3"'), 'no dead rows: the project links');
  assert.ok(html.includes('own:project-3'));
  assert.ok(html.includes('shared pool'), 'an unpinned project says so');
  assert.match(html, /<input[^>]*aria-label="account label for project-3"/);
});

test('the empty state and a failed read say different things', () => {
  assert.ok(view({ rows: [] }).includes('NO PROJECTS'));
  const err = view({ rows: [], error: new Error('http_500') });
  assert.ok(err.includes('could not read the settings table'));
  assert.ok(!err.includes('NO PROJECTS'));
});

test('SettingsView mounts PROJECT ACCOUNTS on the hub tab only', () => {
  const status = { scope: 'hub', projects: ['project-3'], lanes: [] };
  const base = {
    tabs: tabsFrom(status), rows: [], status, error: null, loading: false, busy: null,
    note: null, actions: {}, dialog: null, onTab: () => {}, onReload: () => {},
    accountActions: { set: async () => ({ status: 'written' }) },
  };
  assert.ok(render(h(SettingsView, { ...base, activeTab: 'hub' })).includes('PROJECT ACCOUNTS'));
  assert.ok(!render(h(SettingsView, { ...base, activeTab: 'project-3' })).includes('PROJECT ACCOUNTS'));
});

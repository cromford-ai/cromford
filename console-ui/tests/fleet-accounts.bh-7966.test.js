import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { sortRows } from '../src/lib/sort.js';
import { FleetAccountsView, fleetColumns } from '../src/screens/FleetAccounts.js';
import { ProjectAccountsView } from '../src/screens/ProjectAccounts.js';

// BH-7966 (BH-7937.2): "ACCOUNTS ON THE FLEET" on the Settings hub tab.
//   T1 every column sorts asc then desc by its shown value; headers carry aria-sort
//   T2 the table sits in .aiacct__wrap, which scrolls sideways inside itself
//   T3 the label cell links to /settings?account=<label>; projects link to their lanes
//   T4 boxes null = —; loading = Skeleton; error = ErrorBox, never the Empty state
//   T5 a truncated answer says it shows the first N
//   M1 PROJECT ACCOUNTS shows CHOOSE only when the screen passes onChoose
const ROWS = [
  { id: 'id-1', vendor: 'openrouter', label: 'team-a', plan: 'pro', use_kind: 'pool', projects: ['demo', 'beta-os'], today: 1.75, boxes: 2, state: 'pending', revoked_at: null },
  { id: 'id-2', vendor: 'claude', label: 'zeta', plan: null, use_kind: 'project', projects: [], today: 0, boxes: null, state: 'active', revoked_at: null },
  { id: 'id-3', vendor: 'xai', label: 'alpha', plan: 'api', use_kind: 'fallback', projects: ['omega'], today: 12, boxes: 5, state: 'revoked', revoked_at: '2026-10-23T01:00:00Z' },
];
const data = (over = {}) => ({ accounts: ROWS, limit: 500, truncated: false, ...over });

test('T1 every column has a sort accessor that orders asc then desc; each header is a button with aria-sort', () => {
  const cols = fleetColumns({ onRotate: () => {} });
  assert.deepEqual(cols.map((c) => c.key), ['vendor', 'label', 'plan', 'projects', 'today', 'boxes', 'state', 'action']);
  for (const c of cols) {
    assert.equal(typeof c.sort, 'function', `${c.key} has no sort accessor`);
    const asc = sortRows(ROWS, c.sort, 'asc').map((r) => r.id);
    const desc = sortRows(ROWS, c.sort, 'desc').map((r) => r.id);
    assert.notDeepEqual(asc, desc, `${c.key}: asc and desc give the same order`);
  }
  assert.deepEqual(sortRows(ROWS, cols.find((c) => c.key === 'today').sort, 'asc').map((r) => r.today), [0, 1.75, 12]);
  assert.deepEqual(sortRows(ROWS, cols.find((c) => c.key === 'label').sort, 'desc').map((r) => r.label), ['zeta', 'team-a', 'alpha']);
  const out = render(h(FleetAccountsView, { data: data(), loading: false, error: null }));
  const heads = out.match(/<th(\s[^>]*)?>/g) || [];
  assert.equal(heads.length, 8);
  assert.equal((out.match(/<th[^>]*aria-sort="(ascending|descending|none)"/g) || []).length, 8);
  assert.equal((out.match(/<th[^>]*>\s*<button type="button"/g) || []).length, 8);
});

test('T2 the table is inside .aiacct__wrap and the stylesheet gives it overflow-x: auto', () => {
  const out = render(h(FleetAccountsView, { data: data(), loading: false, error: null }));
  assert.match(out, /<div class="aiacct__wrap">[\s\S]*<table/);
  const css = readFileSync(new URL('../src/ai-accounts.css', import.meta.url), 'utf8');
  const rule = /\.aiacct__wrap\s*\{([^}]*)\}/.exec(css);
  assert.ok(rule, 'no .aiacct__wrap rule in src/ai-accounts.css');
  assert.match(rule[1], /overflow-x:\s*auto/);
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'tokens only: no hex colour');
  const main = readFileSync(new URL('../src/main.js', import.meta.url), 'utf8');
  assert.match(main, /import '\.\/ai-accounts\.css';/);
});

test('T3 label cells link to /settings?account=<label>; each project links to its lanes page', () => {
  const out = render(h(FleetAccountsView, { data: data(), loading: false, error: null }));
  assert.match(out, /href="\/settings\?account=team-a"/);
  assert.match(out, /href="\/settings\?account=zeta"/);
  assert.match(out, /href="\/settings\/p\/demo\/lanes"/);
  assert.match(out, /href="\/settings\/p\/beta-os\/lanes"/);
});

test('T4 boxes null shows —; loading shows the Skeleton; an error is the ErrorBox and not the Empty state', () => {
  const out = render(h(FleetAccountsView, { data: data(), loading: false, error: null }));
  const zeta = out.slice(out.indexOf('account=zeta'));
  assert.match(zeta.slice(0, zeta.indexOf('</tr>')), /—/);
  const loading = render(h(FleetAccountsView, { data: null, loading: true, error: null }));
  assert.match(loading, /class="skel"/);
  assert.doesNotMatch(loading, /<table/);
  const err = render(h(FleetAccountsView, { data: null, loading: false, error: new Error('ai_accounts schema not applied') }));
  assert.match(err, /could not load/);
  assert.match(err, /ai_accounts schema not applied/);
  assert.doesNotMatch(err, /NO AI ACCOUNTS/);
  const empty = render(h(FleetAccountsView, { data: data({ accounts: [] }), loading: false, error: null }));
  assert.match(empty, /NO AI ACCOUNTS/);
  assert.match(empty, /ADD ACCOUNT/);
  // A revoked row has no ROTATE; the others do.
  assert.equal((out.match(/>ROTATE</g) || []).length, 2);
});

test('T5 a truncated answer says only the first N accounts are shown', () => {
  const out = render(h(FleetAccountsView, { data: data({ limit: 3, truncated: true }), loading: false, error: null }));
  assert.match(out, /first 3 accounts/);
  const full = render(h(FleetAccountsView, { data: data(), loading: false, error: null }));
  assert.doesNotMatch(full, /first \d+ accounts/);
});

test('M1 PROJECT ACCOUNTS renders a CHOOSE button per row with onChoose, and none without it', () => {
  const rows = [
    { project: 'demo', label: null, actor: null, updated_at: null, href: '/settings?project=demo' },
    { project: 'beta-os', label: 'team-a', actor: 'console', updated_at: '2026-10-23T00:00:00Z', href: '/settings?project=beta-os' },
  ];
  const base = { rows, error: null, loading: false, busy: null, guard: () => {}, onSet: async () => ({}) };
  const withChoose = render(h(ProjectAccountsView, { ...base, onChoose: () => {} }));
  assert.equal((withChoose.match(/>CHOOSE…</g) || []).length, 2);
  const without = render(h(ProjectAccountsView, base));
  assert.doesNotMatch(without, /CHOOSE/);
});

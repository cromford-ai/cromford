import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
// Namespace imports, so a missing export fails its own test rather than the file.
import * as Lib from '../src/lib/cost-breakdown.js';
import { CostBreakdownView } from '../src/screens/CostBreakdown.js';

// BH-9068 C3: the CASH line on /costs. It sits at the top of the SPEND
// BREAKDOWN section and reads the `cash` object that the section's own
// GET /api/metrics/cost-breakdown already returns (no new request). The
// fixtures are the shape worker/jobs/src/routes/cost-breakdown.js cashSummary
// returns; worker/jobs/test/cost-cash.bh-9068.test.js proves the server side.

const base = {
  since: '2099-09-25T00:00:00Z', until: '2099-09-25T12:00:00Z', group: ['project'], filters: {},
  total: { usd: 21.5, cash_usd: 8.25, equiv_usd: 12, calls: 7, unpriced_calls: 1 },
  groups: [{ project: 'project-4', usd: 21.5, cash_usd: 8.25, equiv_usd: 12, calls: 7, unpriced_calls: 1, last_ts: '2099-09-25T11:00:00Z' }],
  truncated: false, as_of: '2099-09-25T12:00:00Z'
};
const known = {
  day: '2099-09-25', since: '2099-09-25T00:00:00Z', until: '2099-09-25T12:00:00Z',
  subscriptions_usd: 21, overage_usd: 3.5, metered_usd: 4, cash_usd: 28.5, unknown: [],
  accounts: [
    { account: 'acct-fixture-a', usd_per_month: 600, day_usd: 20, overage_usd: 3.5, readings: 4 },
    { account: 'acct-fixture-b', usd_per_month: 30, day_usd: 1, overage_usd: 0, readings: 2 }
  ],
  vendors: [{ vendor: 'openrouter', usd: 2, polls: 2, unmeasured: 0 }, { vendor: 'fly', usd: 2, polls: 1, unmeasured: 0 }]
};
const unknownCash = {
  ...known, subscriptions_usd: null, overage_usd: null, metered_usd: null, cash_usd: null,
  unknown: ['subscription:acct-fixture-b', 'subscription:acct-fixture-d', 'overage:acct-fixture-c', 'metered:xai'],
  accounts: [
    { account: 'acct-fixture-b', usd_per_month: null, day_usd: null, overage_usd: 1.5, readings: 3 },
    { account: 'acct-fixture-c', usd_per_month: 30, day_usd: 1, overage_usd: null, readings: 1 },
    { account: 'acct-fixture-d', usd_per_month: null, day_usd: null, overage_usd: 2, readings: 2 }
  ],
  vendors: [{ vendor: 'xai', usd: null, polls: 3, unmeasured: 3 }]
};

// The fleet shape: one account with a login, one setup-token account whose
// overage the worker leaves out by name, and codex billed by subscription.
const excludedCash = {
  ...known, subscriptions_usd: 23, overage_usd: 3.5, metered_usd: 2, cash_usd: 28.5, unknown: [],
  excluded: [
    { part: 'overage', name: 'acct-fixture-t', why: 'no-login' },
    { part: 'overage', name: 'acct-fixture-u', why: 'no-login' },
    { part: 'metered', name: 'codex', why: 'subscription-billed' }
  ],
  accounts: [
    { account: 'acct-fixture-a', kind: 'account', usd_per_month: 600, day_usd: 20, overage_usd: 3.5, readings: 4, overage_excluded: null },
    { account: 'acct-fixture-t', kind: 'account', usd_per_month: 30, day_usd: 1, overage_usd: null, readings: 0, overage_excluded: 'no-login' },
    { account: 'codex', kind: 'vendor', usd_per_month: 60, day_usd: 2, overage_usd: null, readings: 0, overage_excluded: 'subscription-billed' }
  ],
  vendors: [
    { vendor: 'codex', usd: null, polls: 3, unmeasured: 0, excluded: 'subscription-billed' },
    { vendor: 'fly', usd: 2, polls: 1, unmeasured: 0, excluded: null }
  ]
};

const view = (data) => render(h(CostBreakdownView, {
  data, error: null, loading: false, reload: () => {}, win: 'today', onWin: () => {}, view: 'project', onView: () => {}
}));
// Visible in server markup: present, and no ancestor opened before it is hidden.
function assertVisible(markup, text) {
  const i = markup.indexOf(text);
  assert.ok(i >= 0, `"${text}" is not rendered:\n${markup.slice(0, 600)}`);
  const before = markup.slice(0, i);
  assert.doesNotMatch(before.slice(before.lastIndexOf('<section')), /\shidden(=|\s|>)|display:\s*none|visibility:\s*hidden/,
    `"${text}" sits under a hidden element`);
}
const strip = (markup) => markup.replace(/<!--.*?-->/g, '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ');

test('K1: the CASH line shows the total and its three parts, above the breakdown table', () => {
  const out = view({ ...base, cash: known });
  const text = strip(out);
  assertVisible(out, 'data-cash-line');
  assert.ok(text.includes('cash $28.50 = subscriptions $21.00 + overage $3.50 + metered $4.00'), text);
  assert.ok(text.includes('2099-09-25'), 'the line names the UTC day it covers');
  assert.ok(out.indexOf('data-cash-line') < out.indexOf('<table'), 'the CASH line is above the breakdown table');
  // It wraps rather than scroll the page at 390px.
  const tag = out.match(/<[^>]*data-cash-line[^>]*>/)[0];
  assert.match(tag, /flex-wrap:\s*wrap/);
  assert.doesNotMatch(tag, /white-space:\s*nowrap/);
});

test('K2: a null part shows "cash unknown" and names the accounts with no price, never $0.00', () => {
  const out = view({ ...base, cash: unknownCash });
  const text = strip(out);
  assertVisible(out, 'data-cash-line');
  assert.ok(text.includes('cash unknown (no price: acct-fixture-b, acct-fixture-d'), text);
  assert.ok(text.includes('no reading: overage acct-fixture-c, metered xai'), text);
  const line = strip(out.slice(out.indexOf('data-cash-line'), out.indexOf('<table')));
  assert.doesNotMatch(line, /\$0\.00/, 'an unknown part is never shown as $0.00');
  // The parts list names each missing input too.
  assert.ok(line.includes('acct-fixture-b: subscription unknown (no price)'), line);
  assert.ok(line.includes('acct-fixture-c: subscription $1.00 ($30.00/month) · overage unknown'), line);
  assert.ok(line.includes('xai: metered unknown (3 polls)'), line);
});

test('K3: cashLine is the pure text of both states, and a payload without cash has no line', () => {
  assert.equal(Lib.cashLine(known), 'cash $28.50 = subscriptions $21.00 + overage $3.50 + metered $4.00');
  assert.equal(Lib.cashLine(unknownCash), 'cash unknown (no price: acct-fixture-b, acct-fixture-d; no reading: overage acct-fixture-c, metered xai)');
  assert.equal(Lib.cashLine({ ...unknownCash, unknown: ['metered:no-vendor-spend-row'] }),
    'cash unknown (no reading: metered no-vendor-spend-row)');
  assert.equal(Lib.cashLine(null), null);
  const out = view(base);
  assert.equal(out.includes('data-cash-line'), false, 'a filtered or old payload renders no CASH line');
});

test('K4: a named exclusion keeps the dollar number and says what it does not cover', () => {
  const out = view({ ...base, cash: excludedCash });
  const text = strip(out);
  assertVisible(out, 'data-cash-line');
  const want = 'cash $28.50 = subscriptions $23.00 + overage $3.50 + metered $2.00'
    + ' · not counted: overage acct-fixture-t, acct-fixture-u (no login); metered codex (subscription-billed)';
  assert.ok(text.includes(want), text);
  assert.equal(Lib.cashLine(excludedCash), want);
  const line = strip(out.slice(out.indexOf('data-cash-line'), out.indexOf('<table')));
  assert.doesNotMatch(line, /unknown/, 'an excluded input is not shown as unknown');
  assert.doesNotMatch(line, /\$0\.00/, 'an excluded input is never shown as $0.00');
  assert.ok(line.includes('acct-fixture-t: subscription $1.00 ($30.00/month) · overage not counted (no login)'), line);
  assert.ok(line.includes('codex: subscription $2.00 ($60.00/month) · vendor subscription, no overage meter'), line);
  assert.ok(line.includes('codex: not metered cash (subscription-billed) (3 polls)'), line);
  assert.ok(line.includes('fly: metered $2.00 (1 polls)'), line);
  // An unknown line still names the exclusions beside the missing inputs.
  assert.equal(Lib.cashLine({ ...excludedCash, cash_usd: null, subscriptions_usd: null, unknown: ['subscription:codex'] }),
    'cash unknown (no price: codex; not counted: overage acct-fixture-t, acct-fixture-u (no login); metered codex (subscription-billed))');
  // A payload from a worker without `excluded` reads as before.
  assert.equal(Lib.cashExcluded(known), '');
});

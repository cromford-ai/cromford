import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  fmtUsdExact, fmtShare, spendRows, stageBreakdown, stagesReconcile,
  spendHeadline, projectSpendUnavailable, billingHealth
} from '../src/lib/spend.js';

// ------------------------------------------------------- money never lies

test('a cost we do not have is a dash, never $0.00', () => {
  // "$0.00" claims we know the spend and it was nothing. A missing figure
  // claims nothing. On a money screen those must not look identical.
  assert.equal(fmtUsdExact(null), '—');
  assert.equal(fmtUsdExact(undefined), '—');
  assert.equal(fmtUsdExact('nonsense'), '—');
  assert.equal(fmtUsdExact(0), '$0.00', 'a real zero IS zero and says so');
});

test('a tiny non-zero cost never rounds down to free', () => {
  // $0.004 shown as "$0.00" reads as "this lane costs nothing", which is how a
  // lane quietly burning money stays invisible.
  assert.equal(fmtUsdExact(0.004), '<$0.01');
  assert.equal(fmtUsdExact(0.0001), '<$0.01');
  assert.equal(fmtUsdExact(0.005), '$0.01');
});

test('dollars render at cent precision, unrounded beyond it', () => {
  assert.equal(fmtUsdExact(41.2), '$41.20');
  assert.equal(fmtUsdExact(1678), '$1,678.00');
  assert.equal(fmtUsdExact(2.87), '$2.87');
});

test('a negative cost is shown, not swallowed', () => {
  // A credit or a parser bug is information; hiding it hides the bug.
  assert.equal(fmtUsdExact(-3.5), '-$3.50');
});

// ------------------------------------------------- fleet totals are not ours

test('the fleet headline uses the totals the API sent, never a client-side sum', () => {
  // Summing the per-project rows would silently exclude any project the
  // rollup marks unavailable, producing a confident total that is too low.
  const h = spendHeadline({
    fleet_cost_7d: 100, fleet_cost_30d: 400,
    spend: [{ project: 'a', cost_7d: 10 }, { project: 'b', unavailable: true }]
  });
  assert.equal(h.cost7d, '$100.00');
  assert.equal(h.cost30d, '$400.00');
});

test('an absent fleet total is unknown, not the sum of what we happen to have', () => {
  const h = spendHeadline({ spend: [{ project: 'a', cost_7d: 10 }] });
  assert.equal(h.cost7d, '—');
  assert.equal(h.cost30d, '—');
});

test('spend_unavailable is a reason, never a zero', () => {
  const h = spendHeadline({ spend_unavailable: 'cost rollup has not run yet', fleet_cost_7d: null });
  assert.equal(h.unavailable, 'cost rollup has not run yet');
  assert.equal(h.cost7d, '—');
});

test('a stale rollup is flagged — it is a daily cron, so >26h means it did not run', () => {
  assert.equal(spendHeadline({ spend_stale: true, spend_age_min: 1800 }).stale, true);
  assert.equal(spendHeadline({ spend_stale: false, spend_age_min: 90 }).stale, false);
  assert.equal(spendHeadline({ spend_age_min: 90 }).ageMin, 90);
  assert.equal(spendHeadline({}).ageMin, null);
});

test('unpriced calls surface as an undercount, and zero is not a warning', () => {
  assert.equal(spendHeadline({ unpriced_calls_7d: 412 }).unpriced, 412);
  assert.equal(spendHeadline({ unpriced_calls_7d: 0 }).unpriced, 0);
});

// ---------------------------------------------------------- per-project rows

test('a project the rollup does not carry says so instead of showing $0', () => {
  const rows = spendRows({ spend: [
    { project: 'project-1', cost_7d: 12.4 },
    { project: 'project-6', unavailable: true }
  ]});
  assert.equal(projectSpendUnavailable(rows[1]), true);
  assert.equal(rows[1].cost_7d, null, 'not zero — unknown');
  assert.equal(projectSpendUnavailable(rows[0]), false);
});

test('rows survive an absent spend array', () => {
  assert.deepEqual(spendRows({}), []);
  assert.deepEqual(spendRows(null), []);
});

// -------------------------------------------------------- stage breakdown

test('stages sort by cost, largest first', () => {
  const b = stageBreakdown({ plan: 0.51, execute: 1.64, review: 0.43, qa: 0.29 });
  assert.deepEqual(b.map((s) => s.stage), ['execute', 'plan', 'review', 'qa']);
  assert.equal(b[0].usd, 1.64);
});

test('an empty or missing stage map is empty, not a fake row', () => {
  assert.deepEqual(stageBreakdown(null), []);
  assert.deepEqual(stageBreakdown({}), []);
});

test('a breakdown that does not add up to the total SAYS so', () => {
  // Unpriced calls make the stage sum fall short of the project total. Showing
  // the parts without flagging the gap implies the parts are the whole.
  const r = stagesReconcile({ plan: 1, execute: 2 }, 5);
  assert.equal(r.sum, 3);
  assert.equal(r.matches, false);
  assert.equal(Math.round(r.delta * 100) / 100, 2);
});

test('a breakdown that does add up is not nagged about', () => {
  const r = stagesReconcile({ plan: 1, execute: 2 }, 3);
  assert.equal(r.matches, true);
  assert.equal(r.delta, 0);
});

test('float dust does not count as a mismatch', () => {
  // 0.1 + 0.2 !== 0.3 in binary floating point; warning about a third of a
  // cent would train the operator to ignore the warning that matters.
  const r = stagesReconcile({ a: 0.1, b: 0.2 }, 0.3);
  assert.equal(r.matches, true);
});

test('reconciliation is skipped when there is no total to reconcile against', () => {
  assert.equal(stagesReconcile({ plan: 1 }, null).matches, null);
});

// --------------------------------------------------------------- the share

test('a share in 0..1 renders as a percentage', () => {
  assert.equal(fmtShare(0.42), '42%');
  assert.equal(fmtShare(0), '0%');
  assert.equal(fmtShare(1), '100%');
});

test('a share outside 0..1 is shown raw rather than guessed at', () => {
  // If the encoding is already a percent, multiplying again would report 4200%.
  assert.equal(fmtShare(42), '42');
  assert.equal(fmtShare(null), '—');
  assert.equal(fmtShare('x'), '—');
});

// ------------------------------------------------ an incomplete fleet total

test('an incomplete fleet total is rendered as a FLOOR, not as the answer', () => {
  // Some projects are unpriced (JIRA-driven), so the total is a lower bound.
  // Printing it bare states a fleet spend that is knowably too low.
  const h = spendHeadline({
    fleet_cost_7d: 53.77, fleet_cost_30d: 228.62,
    fleet_cost_incomplete: true, fleet_cost_missing: ['project-10-a', 'project-10-b']
  });
  assert.equal(h.incomplete, true);
  assert.equal(h.cost7d, '≥ $53.77');
  assert.equal(h.cost30d, '≥ $228.62');
  assert.deepEqual(h.missing, ['project-10-a', 'project-10-b']);
});

test('a complete total is printed plainly, with no floor marker', () => {
  const h = spendHeadline({ fleet_cost_7d: 53.77, fleet_cost_incomplete: false });
  assert.equal(h.incomplete, false);
  assert.equal(h.cost7d, '$53.77');
  assert.deepEqual(h.missing, []);
});

test('an unknown total is never dressed up as a floor', () => {
  // "≥ —" is nonsense; absence stays absence.
  const h = spendHeadline({ fleet_cost_7d: null, fleet_cost_incomplete: true });
  assert.equal(h.cost7d, '—');
});

test('incomplete is inferred from a missing list even without the flag', () => {
  const h = spendHeadline({ fleet_cost_7d: 10, fleet_cost_missing: ['x'] });
  assert.equal(h.incomplete, true);
  assert.equal(h.cost7d, '≥ $10.00');
});

// --------------------------------------- unpriced calls: null is not zero

test('a null unpriced count is UNKNOWN, not zero', () => {
  // The rollup now sends null for projects it cannot price. Rendering that as
  // 0 claims we checked and there were none.
  const rows = spendRows({ spend: [
    { project: 'a', cost_7d: 1, unpriced_calls_7d: null },
    { project: 'b', cost_7d: 1, unpriced_calls_7d: 0 },
    { project: 'c', unavailable: true }
  ]});
  assert.equal(rows[0].unpriced_calls_7d, null);
  assert.equal(rows[1].unpriced_calls_7d, 0);
  assert.equal(rows[2].unpriced_calls_7d, null, 'an unavailable project cannot have a known count');
});

test('a null fleet unpriced count is unknown too', () => {
  assert.equal(spendHeadline({ unpriced_calls_7d: null }).unpriced, null);
  assert.equal(spendHeadline({ unpriced_calls_7d: 0 }).unpriced, 0);
  assert.equal(spendHeadline({ unpriced_calls_7d: 412 }).unpriced, 412);
});

// ------------------------------------------------------- the 24h window

test('a 24h figure the worker does not send yet is unknown, not $0.00', () => {
  // The snapshot carries cost_24h since 2026-08-24; an older worker payload
  // simply lacks it, and that absence must render as a dash.
  const h = spendHeadline({ fleet_cost_7d: 100 });
  assert.equal(h.cost24h, '—');
  const rows = spendRows({ spend: [{ project: 'a', cost_7d: 10 }] });
  assert.equal(rows[0].cost_24h, null);
});

test('a present 24h figure renders, and inherits the incomplete floor', () => {
  const h = spendHeadline({ fleet_cost_24h: 41.2, fleet_cost_7d: 100, fleet_cost_missing: ['x'] });
  assert.equal(h.cost24h, '≥ $41.20');
  const rows = spendRows({ spend: [
    { project: 'a', cost_24h: 0, cost_7d: 10 },
    { project: 'b', unavailable: true }
  ]});
  assert.equal(rows[0].cost_24h, 0, 'a measured-empty window is a real zero');
  assert.equal(rows[1].cost_24h, null, 'an unavailable project stays unknown');
});

test('an unknown unpriced count does not raise the undercount alarm', () => {
  // The alarm means "we know calls went unpriced". Unknown is not that.
  assert.equal(spendHeadline({ unpriced_calls_7d: null }).unpricedKnownPositive, false);
  assert.equal(spendHeadline({ unpriced_calls_7d: 412 }).unpricedKnownPositive, true);
  assert.equal(spendHeadline({ unpriced_calls_7d: 0 }).unpricedKnownPositive, false);
});

// ============================ cash vs attributed compute ============================

test('cash and attributed are TWO numbers, and cash is the one that hit a card', () => {
  const h = spendHeadline({
    overage_meter_usd: 4.33, // gate: the meter is absolute, so cash is reportable
    fleet_notional_7d: 6338.87, fleet_cash_7d: 0.78,
    cash_overage_7d: 4.33, fleet_cash_7d_total: 5.11
  });
  assert.equal(h.attributed7d, '$6,338.87');
  assert.equal(h.cash7d, '$5.11');
});

test('the cash total is the SERVER\'s, never cash+overage computed here', () => {
  // Same rule as every other fleet total: if the server's definition of
  // "total" ever stops being a simple sum, a client-side add would quietly
  // disagree with the books.
  const h = spendHeadline({ overage_meter_usd: 2, fleet_cash_7d: 1, cash_overage_7d: 2, fleet_cash_7d_total: 99 });
  assert.equal(h.cash7d, '$99.00', 'the sent total wins over the parts');
});

test('an absent cash total does not fall back to adding the parts', () => {
  const h = spendHeadline({ overage_meter_usd: 4.33, fleet_cash_7d: 0.78, cash_overage_7d: 4.33 });
  assert.equal(h.cash7d, '—');
});

test('attributed falls back to fleet_cost_7d when notional is not sent', () => {
  assert.equal(spendHeadline({ fleet_cost_7d: 5669.23 }).attributed7d, '$5,669.23');
  assert.equal(spendHeadline({ fleet_notional_7d: 6338.87, fleet_cost_7d: 5669.23 }).attributed7d,
    '$6,338.87', 'the explicit notional field wins when present');
});

test('BOTH lines carry the SAME floor marker when the total is incomplete', () => {
  // Two money lines under different floor rules invite comparing numbers that
  // are not comparable — the whole reason this was locked as one rule.
  const h = spendHeadline({
    overage_meter_usd: 4.33,
    fleet_notional_7d: 6338.87, fleet_cash_7d_total: 5.11,
    fleet_cost_incomplete: true, fleet_cost_missing: ['a', 'b']
  });
  assert.equal(h.attributed7d, '≥ $6,338.87');
  assert.equal(h.cash7d, '≥ $5.11');
});

test('a zero cash figure is still zero, not missing — and still floored', () => {
  // "$0.00" here means measured-and-nothing-yet, which is the honest reading
  // while the rollout fills in. It must not become a dash.
  const h = spendHeadline({ overage_meter_usd: 0, fleet_cash_7d_total: 0, fleet_cost_incomplete: true });
  assert.equal(h.cash7d, '≥ $0.00');
});

// ------------------------------------------- unknown-billing health signal

test('no unclassified calls means no note at all', () => {
  assert.equal(billingHealth({ fleet_unknown_billing_calls_7d: 0 }).state, 'clean');
  assert.equal(billingHealth({}).state, 'clean');
});

test('a 24h of ZERO means the backlog is clearing — not an alarm', () => {
  // 7d high + 24h zero = legacy rows only; new rows ARE tagging. Framing this
  // as a problem would train the operator to ignore the real one.
  const h = billingHealth({ fleet_unknown_billing_calls_7d: 1889, fleet_unknown_billing_calls_24h: 0 });
  assert.equal(h.state, 'clearing');
  assert.equal(h.alarming, false);
  assert.match(h.text, /1889/);
});

test('a NON-ZERO 24h means new rows are still not tagging — that IS the signal', () => {
  const h = billingHealth({ fleet_unknown_billing_calls_7d: 1889, fleet_unknown_billing_calls_24h: 40 });
  assert.equal(h.state, 'not_tagging');
  assert.equal(h.alarming, true);
  assert.match(h.text, /40/);
});

test('an ABSENT 24h says we cannot tell which state it is in', () => {
  // The console does not report the 24h window yet. Guessing "clearing" would
  // be inventing the reassurance; guessing "not tagging" would be inventing
  // the alarm. Neither is ours to claim.
  const h = billingHealth({ fleet_unknown_billing_calls_7d: 1889 });
  assert.equal(h.state, 'unknown_window');
  assert.equal(h.alarming, false);
  assert.match(h.text, /cannot tell|not reported|unknown/i);
});

test('a server-sent cash_note is preferred over our own wording', () => {
  const h = billingHealth({ fleet_unknown_billing_calls_7d: 5, cash_note: 'only 2 of 8 boxes tagging yet' });
  assert.match(h.text, /only 2 of 8 boxes tagging yet/);
});

// ---------------------------------------------- per-project cash columns

test('per-project cash and unknown counts come through, null-safe', () => {
  const rows = spendRows({ spend: [
    { project: 'project-4', cost_7d: 2415.57, cash_cost_7d: 0.78, cash_cost_24h: 0.1, unknown_billing_calls_7d: 721, unknown_billing_calls_24h: null },
    { project: 'x', unavailable: true }
  ]});
  assert.equal(rows[0].cash_cost_7d, 0.78);
  assert.equal(rows[0].unknown_billing_calls_7d, 721);
  assert.equal(rows[0].unknown_billing_calls_24h, null);
  assert.equal(rows[1].cash_cost_7d, null, 'an unpriced project has unknown cash, not zero');
});

test('a real zero cash on a priced project stays zero', () => {
  const rows = spendRows({ spend: [{ project: 'project-1', cost_7d: 1105.6, cash_cost_7d: 0 }] });
  assert.equal(rows[0].cash_cost_7d, 0, 'measured as zero, not missing');
});

// ================== the cash line is GATED on the absolute overage meter ==================

test('with no overage meter, cash is NOT a number — it is "measuring"', () => {
  // Pre-fix, cash_overage_7d is a since-tracker-start DELTA, so the total is
  // understated by orders of magnitude. "$5.11" is plausible, tidy and wrong —
  // the dead-feed shape. A floor marker cannot honestly cover a 1000x gap, so
  // the number is withheld entirely rather than decorated.
  const h = spendHeadline({ fleet_cash_7d_total: 5.11, overage_meter_usd: null });
  assert.equal(h.cashReady, false);
  assert.equal(h.cash7d, null, 'no figure at all, not a floored wrong one');
  assert.match(h.cashPending, /measuring|not yet absolute/i);
});

test('the gate is the METER field, not the cash total — a present total does not unlock it', () => {
  assert.equal(spendHeadline({ fleet_cash_7d_total: 5.11 }).cashReady, false);
  assert.equal(spendHeadline({ fleet_cash_7d_total: 5.11, overage_meter_usd: 0 }).cashReady, true,
    'a real zero meter IS a reading');
});

test('once the meter is absolute, cash renders from the SERVER total', () => {
  const h = spendHeadline({
    overage_meter_usd: 18863.42, fleet_cash_7d_total: 18868.53,
    fleet_cash_7d: 0.78, cash_overage_7d: 18867.75
  });
  assert.equal(h.cashReady, true);
  assert.equal(h.cash7d, '$18,868.53', 'the server total, never summed here');
  assert.equal(h.cashPending, null);
});

test('a ready cash line still takes the shared incomplete floor', () => {
  const h = spendHeadline({
    overage_meter_usd: 18863.42, fleet_cash_7d_total: 18868.53,
    fleet_notional_7d: 6338.87, fleet_cost_incomplete: true
  });
  assert.equal(h.cash7d, '≥ $18,868.53');
  assert.equal(h.attributed7d, '≥ $6,338.87', 'both lines, one rule');
});

test('a ready meter with a MISSING total is still not a number', () => {
  // The gate says the meter is trustworthy; it does not conjure a total.
  const h = spendHeadline({ overage_meter_usd: 100 });
  assert.equal(h.cashReady, true);
  assert.equal(h.cash7d, '—');
});

// ------------------------------------------- being IN overage is the headline

test('in_overage is a state, and it outranks the number', () => {
  const h = spendHeadline({
    overage_meter_usd: 18863.42, fleet_cash_7d_total: 18868.53,
    overage_state: { enabled: true, in_overage: true, resets_at: '2026-09-01T00:00:00Z', spend_limit_reached: false }
  });
  assert.equal(h.overage.inOverage, true);
  assert.equal(h.overage.resetsAt, '2026-09-01T00:00:00Z');
});

test('spend_limit_reached FALSE says NOTHING about whether a cap exists', () => {
  // "not hit" is not "does not exist". An account with a $50K limit that has
  // not reached it reports false too. The field the dashboard would need
  // (the endpoint's `limit`) is not plumbed, so no cap claim is derivable —
  // and a false "no cap" on an $18.8K tile is the kind of thing someone acts on.
  const h = spendHeadline({
    overage_meter_usd: 1, overage_state: { enabled: true, in_overage: true, spend_limit_reached: false }
  });
  assert.equal(h.overage.limitReached, false);
  assert.equal('uncapped' in h.overage, false, 'the concept must not exist on the model at all');
});

test('spend_limit_reached TRUE is the one cap statement the data supports', () => {
  const h = spendHeadline({
    overage_meter_usd: 1, overage_state: { enabled: true, in_overage: true, spend_limit_reached: true }
  });
  assert.equal(h.overage.limitReached, true);
});

test('an absent spend_limit_reached claims nothing either way', () => {
  const h = spendHeadline({ overage_meter_usd: 1, overage_state: { in_overage: true } });
  assert.equal(h.overage.limitReached, false, 'false here means "no such claim", not "a cap was not hit"');
  assert.equal(h.overage.known, true);
});

test('not in overage, or no state at all, claims nothing', () => {
  assert.equal(spendHeadline({ overage_state: { enabled: true, in_overage: false } }).overage.inOverage, false);
  assert.equal(spendHeadline({}).overage.inOverage, false);
  assert.equal(spendHeadline({}).overage.known, false);
  assert.equal(spendHeadline({ overage_state: { in_overage: true } }).overage.known, true);
});

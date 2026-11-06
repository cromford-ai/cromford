import { fmtNum } from './format.js';

// Real dollars. Every rule in here exists because the alternative is a money
// screen that states something false — and a cost readout is believed.

// Deliberately strict. `Number(null)`, `Number('')`, `Number(false)` and
// `Number([])` are all 0 and all finite, so the obvious
// `Number.isFinite(Number(n))` reports a MISSING cost as a real zero — which on
// this screen renders "$0.00" where the truth is "we do not know". Only an
// actual number, or a non-blank numeric string, counts.
const isNum = (n) => {
  if (typeof n === 'number') return Number.isFinite(n);
  if (typeof n === 'string' && n.trim() !== '') return Number.isFinite(Number(n));
  return false;
};

// "$0.00" claims we know the spend and it was nothing. A missing figure claims
// nothing at all. On a money screen those must never look the same. And a tiny
// non-zero cost must never round down to free: $0.004 shown as "$0.00" is how a
// lane quietly burning money stays invisible.
export function fmtUsdExact(n) {
  if (!isNum(n)) return '—';
  const v = Number(n);
  if (v === 0) return '$0.00';
  const abs = Math.abs(v);
  if (abs < 0.005) return v < 0 ? '>-$0.01' : '<$0.01';
  return `${v < 0 ? '-' : ''}$${fmtNum(abs, { decimals: 2 })}`;
}

// A "share" is almost certainly a 0..1 fraction, but guessing wrong turns 42%
// into 4200%. Anything outside that range is shown raw rather than interpreted.
export function fmtShare(n) {
  if (!isNum(n)) return '—';
  const v = Number(n);
  if (v >= 0 && v <= 1) return `${Math.round(v * 100)}%`;
  return String(v);
}

// The fleet headline uses the totals the API sent. Summing the per-project rows
// would silently exclude every project the rollup marks unavailable and produce
// a confident total that is too low — the most expensive kind of wrong here.
export function spendHeadline(costs) {
  const c = costs || {};
  const missing = Array.isArray(c.fleet_cost_missing) ? c.fleet_cost_missing : [];
  const cashReady = isNum(c.overage_meter_usd);
  const over = c.overage_state && typeof c.overage_state === 'object' ? c.overage_state : null;
  // Some projects are unpriced (JIRA-driven), so the fleet total is then a
  // LOWER BOUND. Printing it bare states a fleet spend that is knowably too
  // low; "≥" is the difference between a total and a floor. An absent total
  // stays absent — "≥ —" is nonsense.
  const incomplete = Boolean(c.fleet_cost_incomplete) || missing.length > 0;
  const floor = (v) => {
    const t = fmtUsdExact(v);
    return incomplete && t !== '—' ? `≥ ${t}` : t;
  };
  // null means the rollup could not count them. Rendering that as 0 claims we
  // checked and found none, which is the same lie as $0.00 for a missing cost.
  const unpriced = isNum(c.unpriced_calls_7d) ? Number(c.unpriced_calls_7d) : null;
  return {
    // TWO distinct numbers, and they must never be rendered comparably-but-
    // differently. "Attributed" is what the compute would cost at retail;
    // "cash" is what actually hit a card. Both carry the SAME floor marker,
    // because two money lines under different floor rules invite comparing
    // figures that are not comparable.
    //
    // The cash TOTAL is the server's `fleet_cash_7d_total`, never cash+overage
    // added here: if the server's definition of "total" ever stops being a
    // simple sum, a client-side add would quietly disagree with the books.
    //
    // ATTRIBUTED PREFERS `fleet_notional_7d` OVER `fleet_cost_7d` DELIBERATELY —
    // do not "simplify" this back. They are different numbers (6338.87 vs
    // 5669.23 when this was written) and the gap is real spend, not rounding:
    // `fleet_cost_7d` is summed client-side by the console worker over
    // knownProjects only, which EXCLUDES the "other" bucket (alert-triage,
    // bench, probes). `fleet_notional_7d` comes from the hub rollup, which
    // folds "other" in. So cost_7d has exactly the blindness cromford #61
    // fixed hub-side: it silently drops spend that is not attributed to a named
    // project. Preferring notional is a correction UP toward the truth. The
    // cost_7d fallback exists only for a payload that predates the field.
    attributed7d: floor(isNum(c.fleet_notional_7d) ? c.fleet_notional_7d : c.fleet_cost_7d),

    // THE CASH LINE IS GATED ON `overage_meter_usd`, NOT on the cash total.
    // Before the rollup reports an ABSOLUTE meter, `cash_overage_7d` is only
    // the delta since the tracker started — so the total is understated by
    // orders of magnitude (5.11 against a real weekly overage near 18,863).
    // "$5.11" is plausible, tidy and wrong, which is the dead-feed shape: the
    // failure is invisible precisely because the number looks reasonable. A
    // floor marker cannot honestly cover a 1000x gap, so the figure is
    // WITHHELD rather than decorated, and the tile says it is still measuring.
    // A real zero meter IS a reading; only null means "not yet absolute".
    cashReady,
    cash7d: cashReady ? floor(c.fleet_cash_7d_total) : null,
    cashPending: cashReady
      ? null
      : 'measuring — the overage meter is not yet absolute, so a cash total would understate what has actually been billed. Per-project metered-lane cash below is unaffected and is shown.',
    cashMetered7d: fmtUsdExact(c.fleet_cash_7d),
    cashOverage7d: fmtUsdExact(c.cash_overage_7d),
    hasCash: cashReady && isNum(c.fleet_cash_7d_total),
    // Being IN overage outranks the number: it means every further call bills
    // cash at API rates.
    //
    // THERE IS DELIBERATELY NO "uncapped" HERE. `spend_limit_reached === false`
    // means the cap was not HIT — not that no cap EXISTS. An account with a
    // $50K limit that has not reached it reports false too, so reading that as
    // "no spend cap" is an invented claim, and a false "no cap" next to an
    // $18.8K figure is the kind of thing somebody acts on. The field that
    // would actually support it (the endpoint's `limit`) is not plumbed
    // through the tracker or the rollup; if we ever want that warning, it gets
    // added upstream rather than inferred here.
    //
    // `limitReached` is therefore the ONLY cap statement the data supports,
    // and only on an explicit true.
    overage: {
      known: Boolean(over),
      enabled: over ? over.enabled === true : false,
      inOverage: over ? over.in_overage === true : false,
      resetsAt: over && over.resets_at ? over.resets_at : null,
      limitReached: over ? over.spend_limit_reached === true : false
    },
    cost24h: floor(c.fleet_cost_24h),
    cost7d: floor(c.fleet_cost_7d),
    cost30d: floor(c.fleet_cost_30d),
    hasTotals: isNum(c.fleet_cost_24h) || isNum(c.fleet_cost_7d) || isNum(c.fleet_cost_30d),
    incomplete,
    missing,
    unavailable: c.spend_unavailable || null,
    stale: Boolean(c.spend_stale),
    ageMin: isNum(c.spend_age_min) ? Number(c.spend_age_min) : null,
    generatedAt: c.spend_generated_at || null,
    unpriced,
    // The undercount alarm means "we KNOW calls went unpriced". Unknown is not that.
    unpricedKnownPositive: unpriced !== null && unpriced > 0
  };
}

// A project the rollup does not carry reports unknown, never zero.
export function spendRows(costs) {
  const rows = (costs && costs.spend) || [];
  return rows.map((r) => ({
    project: r.project,
    unavailable: Boolean(r.unavailable),
    cost_24h: r.unavailable || !isNum(r.cost_24h) ? null : Number(r.cost_24h),
    cost_7d: r.unavailable || !isNum(r.cost_7d) ? null : Number(r.cost_7d),
    cost_30d: r.unavailable || !isNum(r.cost_30d) ? null : Number(r.cost_30d),
    cost_per_merged_pr_7d: r.unavailable || !isNum(r.cost_per_merged_pr_7d) ? null : Number(r.cost_per_merged_pr_7d),
    merged_prs_7d: r.unavailable || !isNum(r.merged_prs_7d) ? null : Number(r.merged_prs_7d),
    triage_share_7d: r.unavailable || !isNum(r.triage_share_7d) ? null : Number(r.triage_share_7d),
    unpriced_calls_7d: r.unavailable || !isNum(r.unpriced_calls_7d) ? null : Number(r.unpriced_calls_7d),
    cash_cost_7d: r.unavailable || !isNum(r.cash_cost_7d) ? null : Number(r.cash_cost_7d),
    cash_cost_24h: r.unavailable || !isNum(r.cash_cost_24h) ? null : Number(r.cash_cost_24h),
    unknown_billing_calls_7d: r.unavailable || !isNum(r.unknown_billing_calls_7d) ? null : Number(r.unknown_billing_calls_7d),
    unknown_billing_calls_24h: r.unavailable || !isNum(r.unknown_billing_calls_24h) ? null : Number(r.unknown_billing_calls_24h),
    stages_7d: r.stages_7d || null
  }));
}

export const projectSpendUnavailable = (row) => Boolean(row && row.unavailable);

export function stageBreakdown(stages) {
  if (!stages || typeof stages !== 'object') return [];
  const rows = Object.entries(stages)
    .filter(([, usd]) => isNum(usd))
    .map(([stage, usd]) => ({ stage, usd: Number(usd) }))
    .sort((a, b) => b.usd - a.usd);
  const max = rows.length ? Math.max(...rows.map((r) => Math.abs(r.usd))) : 0;
  return rows.map((r) => ({ ...r, barPct: max > 0 ? Math.round((Math.abs(r.usd) / max) * 100) : 0 }));
}

// Unpriced calls make the stage sum fall short of the project total. Showing
// the parts without flagging the gap implies the parts are the whole — so the
// gap is computed and named. The tolerance exists because 0.1 + 0.2 !== 0.3 in
// binary floating point, and warning about a third of a cent would train the
// operator to ignore the warning that matters.
const CENT_TOLERANCE = 0.005;

export function stagesReconcile(stages, total) {
  const rows = stageBreakdown(stages);
  const sum = rows.reduce((n, r) => n + r.usd, 0);
  if (!isNum(total)) return { sum, matches: null, delta: null };
  const delta = Number(total) - sum;
  return { sum, matches: Math.abs(delta) <= CENT_TOLERANCE, delta };
}

// How healthy is the billing-mode tagging? A high 7d count is EXPECTED during
// the rollout (legacy rows predating billing mode), so it must not read as an
// alarm. The signal that actually matters is the 24h window:
//
//   24h == 0    new rows ARE tagging; the 7d number is backlog clearing — fine
//   24h  > 0    new rows are still arriving unclassified — that is the bug
//   24h absent  we cannot tell, and neither guess is ours to make
//
// Claiming "clearing" without the 24h number would invent reassurance;
// claiming "not tagging" would invent an alarm.
export function billingHealth(costs) {
  const c = costs || {};
  const week = isNum(c.fleet_unknown_billing_calls_7d) ? Number(c.fleet_unknown_billing_calls_7d) : 0;
  const day = isNum(c.fleet_unknown_billing_calls_24h) ? Number(c.fleet_unknown_billing_calls_24h) : null;
  const note = typeof c.cash_note === 'string' && c.cash_note.trim() ? c.cash_note.trim() : null;

  if (week <= 0) return { state: 'clean', alarming: false, week, day, text: note || '' };

  const lead = `${week} calls not yet classified in the last 7 days (billing rollout in progress)`;
  if (day === null) {
    return {
      state: 'unknown_window', alarming: false, week, day,
      text: note || `${lead}. The 24h window that would say whether NEW rows are tagging is not reported yet, so this cannot tell you which it is — a clearing backlog or a tagging bug.`
    };
  }
  if (day > 0) {
    return {
      state: 'not_tagging', alarming: true, week, day,
      text: note || `${lead}, and ${day} of them landed in the last 24h — new rows are still arriving unclassified, so this is not just legacy backlog.`
    };
  }
  return {
    state: 'clearing', alarming: false, week, day,
    text: note || `${lead}, but none in the last 24h — new rows are tagging and the 7d figure is legacy backlog clearing.`
  };
}

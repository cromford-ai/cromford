import { fmtUsd } from './format.js';

// BH-6174 (BH-5526 slice C4): the pure half of the LANE SPEND section on /costs.
// The numbers are the worker's (GET /api/metrics/lane-spend); this file only
// names them. A null stays null all the way to the cell, which shows `—`: a
// lane with no p99 row has no alert line, and that is unknown, not $0.00.

const num = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));

// The ceiling cell, from the settings row grammar the gate reads
// (`_llm_ceiling` in bin/lib/llm-gate.sh). Only `armed` is a dollar figure.
export function ceilingText(row) {
  if (!row) return '—';
  switch (row.ceiling_state) {
    case 'armed': return fmtUsd(num(row.ceiling_usd));
    case 'off': return 'off';
    case 'zero': return '0 (none)';
    case 'junk': return `junk: ${row.ceiling_raw ?? ''}`;
    default: return '—';
  }
}

// Order matters: a lane over its ceiling is also over its alert line, and the
// ceiling is the one the gate refuses on. `tone` is the console's pill tone.
export function stateOf(row) {
  if (row && row.over_ceiling) return { label: 'OVER CEILING', tone: 'dead', rank: 3 };
  if (row && row.over_alert) return { label: 'OVER ALERT', tone: 'warn', rank: 2 };
  if (!row || (num(row.alert_usd) === null && num(row.ceiling_usd) === null)) return { label: 'no line', tone: 'muted', rank: 0 };
  return { label: 'ok', tone: 'ok', rank: 1 };
}

export function laneSpendRows(data) {
  const lanes = (data && Array.isArray(data.lanes)) ? data.lanes : [];
  return lanes.map((l, i) => {
    const row = {
      key: l.lane ?? `\u0000row-${i}`,
      lane: l.lane ?? null,
      registered: l.registered === true,
      today_usd: num(l.today_usd),
      calls: num(l.calls),
      p99_usd: num(l.p99_usd),
      p99_days: num(l.p99_days),
      alert_mult: num(l.alert_mult),
      alert_usd: num(l.alert_usd),
      ceiling_usd: num(l.ceiling_usd),
      ceiling_state: l.ceiling_state || 'none',
      ceiling_raw: l.ceiling_raw ?? null,
      over_alert: l.over_alert === true,
      over_ceiling: l.over_ceiling === true,
      pct_of_ceiling: num(l.pct_of_ceiling),
    };
    row.state = stateOf(row);
    return row;
  });
}

// The fleet kill switch only. A box row or a flags/ file on one box never
// reaches the worker, so the banner says it cannot see those.
export function switchBanner(data) {
  if (!data || data.ceiling_switch_fleet !== true) return null;
  return 'The fleet switch switch.spend-ceiling-off is on, so no ceiling is enforced on any lane. A per-box switch is not visible here.';
}

// The multiplier the hub stored on the p99 rows; null when no lane has one.
export function alertMult(data) {
  const l = (data && Array.isArray(data.lanes)) ? data.lanes.find((x) => num(x.alert_mult) !== null) : null;
  return l ? num(l.alert_mult) : null;
}

export function laneSpendNote(data) {
  const d = data || {};
  const m = alertMult(d);
  const table = d.p99_day ?? 'no day';
  const alert = m === null ? `alert line = p99 table of ${table}` : `alert line = ${m}x p99 from the table of ${table}`;
  return `cost_rows per lane_id since ${d.since ?? '—'} · ${alert} · ceiling = settings spend.ceiling.<lane>.day_usd`;
}

// Said under the table when the alert lines are not today's table.
export function p99Footnote(data) {
  if (!data) return null;
  if (data.p99_day === null || data.p99_day === undefined) return 'no p99 table is pushed yet, so no lane has an alert line';
  if (data.p99_day !== data.day) return `the alert lines come from the p99 table of ${data.p99_day}, not ${data.day}`;
  return null;
}

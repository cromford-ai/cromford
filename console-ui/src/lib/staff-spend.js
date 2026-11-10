// BH-9127: spend per staff agent on /staff (the roster SPEND cell) and on
// /staff/:agent (SPEND TODAY and SPEND 7D). The roster (worker/jobs
// staff-screen.js) answers spend_usd for today (UTC) and spend_usd_7d, read
// from the cost rows of the agent's lanes plus its own heartbeat calls. A
// null is an unread figure: it renders n/a with the source as the tooltip,
// never $0.00. A real 0 is $0.00. Every figure links to COSTS filtered to the
// agent (/costs?agent=<name>, screens/AgentSpend.js).

import { html, Link } from '../router.js';
import { fmtUsdExact } from './spend.js';

export const costsHref = (agent) => `/costs?agent=${encodeURIComponent(agent)}`;

const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

// The tooltip of an unread figure. Archie's map row has its own source.
const sourceOf = (row, sources) => {
  const s = sources || {};
  return (row && row.name === 'archie' && s.spend_archie) || s.spend || '';
};

const naSpan = (title) => html`<span class="na" title=${title}>n/a</span>`;
const unpricedTail = (n) => (isNum(n) && n > 0 ? html` <span class="na">+${n} unpriced</span>` : null);

function figure(row, value, unpriced, title, sources) {
  if (!isNum(value)) return naSpan(sourceOf(row, sources));
  return html`<${Link} to=${costsHref(row.name)} title=${title}>${fmtUsdExact(value)}<//>${unpricedTail(unpriced)}`;
}

const weekTitle = (row) => {
  const d = isNum(row.spend_window_days) ? row.spend_window_days : 7;
  const week = isNum(row.spend_usd_7d) ? fmtUsdExact(row.spend_usd_7d) : 'n/a';
  return `today (UTC); ${d}D ${week}; click for COSTS filtered to ${row.name}`;
};

export function spendCell(row, sources) {
  return figure(row, row && row.spend_usd, row && row.spend_unpriced, row ? weekTitle(row) : '', sources);
}

export function spendFacts(row, sources) {
  const d = isNum(row.spend_window_days) ? row.spend_window_days : 7;
  return [
    ['SPEND TODAY', figure(row, row.spend_usd, row.spend_unpriced, 'today (UTC)', sources)],
    [`SPEND ${d}D`, figure(row, row.spend_usd_7d, row.spend_unpriced_7d, `the last ${d} days`, sources)]
  ];
}

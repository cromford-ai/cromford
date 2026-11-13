// BH-2556 (BH-2540.3): the LLM sites list, one sortable row per LLM call site
// with its spend, pathway, refusals and gates. Reached from COSTS (the
// "LLM SITES →" link), and each SITE cell drills to /llm-sites/<id>. Split like
// AccountUsage: the screen owns the fetch, the view is a pure function of the
// useApi state so it renders server-side in the tests.
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import { agoFromMinutes, minutesSince, fmtNum } from '../lib/format.js';
import {
  runnerColumns, siteViewRows, money, BADGE_TITLES, drillHref, incompleteText
} from '../lib/llm-sites.js';

export function LlmSitesScreen() {
  const state = useApi(() => api.llmSites(), [], { intervalMs: 60000 });
  return html`<${LlmSitesView} state=${state}/>`;
}

const dash = html`<span class="na">—</span>`;
const val = (v) => (v === null || v === undefined ? dash : v);
// Exact money (`<$0.01`, never a rounded $0.00), tagged with its basis. The
// basis tag lives in the attribute, the header and the Legend: a per-cell
// API-eq link would double the width of a 20-column table at 375px.
const usdExact = (n, basis = 'api') => (n === null || n === undefined
  ? dash : html`<span class="num" data-usd-basis=${basis}>${money(n)}</span>`);
const usdCol = (key, label, get, extra = {}, basis = 'api') => ({
  key, label, sort: get, cell: (r) => usdExact(get(r), basis), align: 'right', ...extra,
});
const refusedSum = (r) => {
  const parts = [r.refused.gate, r.refused.guard, r.refused.kill].filter((v) => v !== null);
  return parts.length ? parts.reduce((a, b) => a + b, 0) : null;
};

export function columns(runners) {
  return [
    {
      key: 'site', label: 'SITE', sort: (r) => r.id,
      cell: (r) => html`<${Link} to=${drillHref(r.id)} class="cell-name">${r.id}<//>
        ${r.badges.map((b) => html` <span key=${b} class="tag tag--bad badge badge--red" title=${BADGE_TITLES[b]}>${b}</span>`)}
        ${r.shared || r.attribution === 'signature'
          ? html` <span class="tag tag--warn" title="spend attributed by signature or shared with another site">shared</span>`
          : null}`,
    },
    {
      key: 'lane', label: 'LANE', sort: (r) => r.lane,
      cell: (r) => (r.lane ? html`<${Link} to=${`/settings/${encodeURIComponent(r.lane)}`}>${r.lane}<//>` : dash),
    },
    { key: 'stage', label: 'STAGE', sort: (r) => r.stage, cell: (r) => val(r.stage) },
    { key: 'kind', label: 'KIND', sort: (r) => r.kind, cell: (r) => val(r.kind) },
    ...runners.map((n) => usdCol(`u24-${n}`, `24H ${n.toUpperCase()}`, (r) => r.usd24[n], { unit: 'API-eq' })),
    ...runners.map((n) => usdCol(`u7-${n}`, `7D ${n.toUpperCase()}`, (r) => r.usd7[n], { unit: 'API-eq' })),
    usdCol('total7', '7D TOTAL', (r) => r.total7),
    {
      key: 'cash', label: 'CASH 7D', sort: (r) => r.cash_7d, align: 'right',
      cell: (r) => html`${usdExact(r.cash_7d, 'cash')}${r.unknown_billing_7d > 0
        ? html`<br/><span class="na" style="font-size:var(--fs-2xs)">${usdExact(r.unknown_billing_7d, 'api')} unknown billing</span>`
        : null}`,
    },
    usdCol('notional', 'API-EQUIVALENT 7D', (r) => r.notional_7d, { raw: 'NOTIONAL' }),
    { key: 'calls', label: 'CALLS', sort: (r) => r.calls_7d, cell: (r) => val(r.calls_7d), align: 'right' },
    {
      key: 'refused', label: 'REFUSED', unit: 'gate/guard/kill', raw: 'REFUSED G/G/K',
      sort: refusedSum, cell: (r) => r.refusedText, align: 'right',
    },
    {
      key: 'k', label: 'CALL GUARD MAX', raw: 'K3 K', sort: (r) => r.guard_k,
      cell: (r) => (r.guard_k === null ? dash : `${r.guard_k}${r.guard_enforced ? ' enforced' : ''}`), align: 'right',
    },
    {
      key: 'kill', label: 'CONTEXT KILL', unit: 'tokens', raw: 'KILL',
      sort: (r) => r.kill_tokens, cell: (r) => val(r.kill_tokens), align: 'right',
    },
    usdCol('cap', 'DAILY CAP', (r) => r.cap_usd_day, { unit: '$, UTC day', raw: 'CAP/DAY' }),
    usdCol('today', 'SPENT TODAY', (r) => r.today_usd, { unit: '$, UTC', raw: 'TODAY $' }),
    {
      key: 'knobs', label: 'KNOBS BOUND', unit: 'count', raw: 'KNOBS', sort: (r) => r.knobsBound,
      cell: (r) => html`<span title=${r.knobsList}>${r.knobsBound}</span>`, align: 'right',
    },
    {
      key: 'badges', label: 'WARNINGS', raw: 'BADGES',
      sort: (r) => r.badges.length, cell: (r) => r.badges.length, align: 'right',
    },
  ];
}

// Wording from catalog/lanes.d/_lib.call-guard.json (CALL_GUARD_MAX_MAP), the
// LLM_USD_CAP_DAY note and worker/jobs/src/lib/llm-sites.js (cash vs notional).
const LEGEND = [
  { term: 'NOTIONAL / API-EQUIVALENT', text: 'Subscription calls priced at list rates: what they would have cost on the API, not cash.' },
  { term: 'CASH', text: 'Metered calls: money actually billed. Calls with no billing mode tagged are not in it: their API-equivalent cost shows under it as unknown billing.' },
  { term: 'REFUSED', text: 'Calls stopped in the last 7 days, shown as gate/guard/kill: by a gate, by the call guard, or by the context kill.' },
  { term: 'CALL GUARD MAX', text: 'Paid calls one piece of work may make inside the guard window before the next is refused. 0 means the guard is off. "enforced" means it refuses; otherwise it only counts.' },
  { term: 'CONTEXT KILL', text: 'The token count at which a call is killed.' },
  { term: 'DAILY CAP', text: 'Dollars the lane may spend in the current UTC day.' },
  { term: 'KNOBS BOUND', text: 'How many settings knobs are bound to this site. Hover the number for their names.' },
  { term: 'WARNINGS', text: Object.entries(BADGE_TITLES).map(([k, v]) => `${k}: ${v}.`).join(' ') },
];

export function LlmSitesView({ state }) {
  const { data, error, loading, reload } = state || {};
  const header = html`
    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <${Link} to="/costs" class="crumb">← COSTS<//>
      ${data ? html`<span style="font-size:var(--fs-sm);color:var(--faint)">as of ${agoFromMinutes(minutesSince(data.as_of))}</span>` : null}
    </div>
    <${PageHeadline} chip="LLM SITES"
      line1=${data ? `${fmtNum(siteViewRows(data).length)} places in the code call a model.` : error ? 'The LLM sites read failed.' : 'Reading the LLM call sites.'}
      line2="Each with its runner, its model and what it spent."/>`;

  if (!data) {
    return html`<div class="page">
      ${header}
      ${error ? html`<${ErrorBox} error=${error} onRetry=${reload}/>` : html`<${Skeleton} rows=${6} height=${22}/>`}
    </div>`;
  }

  const runners = runnerColumns(data);
  const rows = siteViewRows(data);
  const incomplete = incompleteText(data);
  return html`
    <div class="page">
      ${header}
      ${error ? html`<${ErrorBox} error=${error} onRetry=${reload}/>` : null}
      ${incomplete ? html`<div class="banner banner--warn">incomplete: <b>${incomplete}</b></div>` : null}
      <${SortableTable} wide columns=${columns(runners)} rows=${rows} rowKey=${(r) => r.id}
        defaultSort="total7" defaultDir="desc"
        empty=${html`<${Empty} title="no LLM sites in the catalog"/>`}/>
      ${rows.length ? html`<${Legend} items=${LEGEND}/>` : null}
    </div>`;
}

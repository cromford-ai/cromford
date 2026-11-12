import { useState, useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { fmtUsd } from '../lib/format.js';
import {
  BREAKDOWN_WINDOWS, BREAKDOWN_VIEWS, viewOf, windowParams, billingLabel, breakdownRows,
  childRequest, ticketHref, leafRows, cashLine
} from '../lib/cost-breakdown.js';

// BH-3557: where the fleet's spend is, by project → stage, runner · model,
// billing mode and ticket, each group drillable down to the cost rows behind
// it. This is where the fleet number went when the Settings lane table stopped
// showing it on every lane that declares no cost stage. Split like
// AccountUsage: the section owns the fetches, the view is a pure function of
// props so it renders server-side in the tests.
export function CostBreakdownSection() {
  const [win, setWin] = useState('today');
  const [view, setView] = useState('project');
  // open[d] is the key of the one open row at depth d; kids holds each child
  // fetch by its request key.
  const [open, setOpen] = useState([]);
  const [kids, setKids] = useState({});
  // Bumped on a window/view change, so a child answer from the old one is dropped.
  const gen = useRef(0);
  const a = useApi(() => api.costBreakdown({
    ...windowParams(win, Date.now()), group: viewOf(view).levels[0].join(',')
  }), [win, view], { intervalMs: 60000 });

  const reset = () => { gen.current += 1; setOpen([]); setKids({}); };
  const onWin = (w) => { if (w !== win) { reset(); setWin(w); } };
  const onView = (v) => { if (v !== view) { reset(); setView(v); } };

  const load = (req) => {
    const g = gen.current;
    setKids((k) => ({ ...k, [req.key]: { loading: true } }));
    // The child reads the SAME window its parent's numbers came from.
    const w = a.data ? { since: a.data.since, until: a.data.until } : windowParams(win, Date.now());
    api.costBreakdown({ ...w, ...req.params }).then(
      (data) => { if (g === gen.current) setKids((k) => ({ ...k, [req.key]: { data } })); },
      (error) => { if (g === gen.current) setKids((k) => ({ ...k, [req.key]: { error } })); });
  };
  const onOpen = (depth, row, req) => {
    const closing = open[depth] === row.key;
    setOpen(closing ? open.slice(0, depth) : [...open.slice(0, depth), row.key]);
    if (!closing && !(kids[req.key] && kids[req.key].data)) load(req);
  };

  return html`<${CostBreakdownView} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}
    win=${win} onWin=${onWin} view=${view} onView=${onView}
    open=${open} onOpen=${onOpen} kids=${kids} onRetryChild=${load}/>`;
}

const money = (key, label, get) => ({
  key, label, align: 'right', sort: (r) => get(r),
  cell: (r) => html`<span class="num">${fmtUsd(get(r))}</span>`
});

const countColumns = [
  { key: 'usd', label: '$', align: 'right', sort: (r) => r.usd, cell: (r) => html`<span class="num">${r.usdText}</span>` },
  money('cash', 'CASH $', (r) => r.cash_usd ?? null),
  money('equiv', 'API-EQUIV $', (r) => r.equiv_usd ?? null),
  { key: 'calls', label: 'CALLS', align: 'right', sort: (r) => r.calls, cell: (r) => r.calls ?? '—' },
  { key: 'unpriced', label: 'UNPRICED', align: 'right', sort: (r) => r.unpriced, cell: (r) => r.unpriced ?? '—' }
];

const DIM_HEAD = { project: 'PROJECT', stage: 'STAGE', runner: 'RUNNER', model: 'MODEL', billing_mode: 'BILLING', ticket: 'TICKET' };

const when = (ts) => (ts ? String(ts).slice(5, 16).replace('T', ' ') : '—');

export function LeafRows({ data }) {
  const rows = leafRows(data);
  const cell = (k) => (r) => (r[k] === null || r[k] === undefined ? html`<span class="na">—</span>` : r[k]);
  const columns = [
    {
      key: 'ts', label: 'WHEN', sort: (r) => r.ts,
      cell: (r) => (r.href
        ? html`<${Link} to=${r.href} class="cell-name" title=${r.ts}>${when(r.ts)}<//>`
        : html`<span title=${r.ts || ''}>${when(r.ts)}</span>`)
    },
    { key: 'project', label: 'PROJECT', sort: (r) => r.project, cell: cell('project') },
    { key: 'stage', label: 'STAGE', sort: (r) => r.stage, cell: cell('stage') },
    { key: 'runner', label: 'RUNNER', sort: (r) => r.runner, cell: cell('runner') },
    { key: 'model', label: 'MODEL', sort: (r) => r.model, cell: cell('model') },
    { key: 'billing', label: 'BILLING', sort: (r) => billingLabel(r.billing_mode), cell: (r) => billingLabel(r.billing_mode) },
    {
      key: 'ticket', label: 'TICKET', sort: (r) => r.ticket,
      cell: (r) => (!r.ticket ? html`<span class="na">—</span>`
        : (r.href ? html`<${Link} to=${r.href}>${r.ticket}<//>` : r.ticket))
    },
    { key: 'usd', label: '$', align: 'right', sort: (r) => r.cost_usd ?? null, cell: (r) => html`<span class="num">${r.usdText}</span>` }
  ];
  return html`
    ${data && data.truncated ? html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">
      capped: newest ${rows.length} rows</span></div>` : null}
    <${SortableTable} wide columns=${columns} rows=${rows} rowKey=${(r) => r.key} defaultSort="ts" defaultDir="desc"
      empty=${html`<${Empty} title="no cost rows" note="No cost row matches this group in the window."/>`}/>`;
}

function Level({ viewKey, depth, data, filters, open, onOpen, kids, onRetryChild }) {
  const dims = viewOf(viewKey).levels[depth];
  const rows = breakdownRows(data, dims);
  const openRow = rows.find((r) => r.key === open[depth]) || null;
  const req = openRow ? childRequest(viewKey, depth, openRow, filters) : null;

  const identity = {
    key: 'label', label: dims.map((d) => DIM_HEAD[d]).join(' · '), sort: (r) => r.label,
    cell: (r) => {
      const href = dims.includes('ticket') ? ticketHref(r)
        : (dims.includes('project') && r.project ? `/p/${encodeURIComponent(r.project)}` : null);
      return html`<span style="display:inline-flex;gap:6px;flex-wrap:wrap;align-items:center">
        <button type="button" class="btn btn--sm" aria-expanded=${open[depth] === r.key ? 'true' : 'false'}
          onClick=${() => onOpen(depth, r, childRequest(viewKey, depth, r, filters))}>${r.label}</button>
        ${href ? html`<${Link} to=${href} class="crumb">${dims.includes('ticket') ? 'OPEN →' : 'PROJECT →'}<//>` : null}
      </span>`;
    }
  };

  const kid = req ? kids[req.key] : null;
  const child = () => {
    if (!kid || kid.loading) return html`<${Skeleton} rows=${3} height=${18}/>`;
    if (kid.error) return html`<${ErrorBox} error=${kid.error} onRetry=${onRetryChild ? () => onRetryChild(req) : null}/>`;
    if (req.group === 'rows') return html`<${LeafRows} data=${kid.data}/>`;
    return html`<${Level} viewKey=${viewKey} depth=${depth + 1} data=${kid.data} filters=${req.filters}
      open=${open} onOpen=${onOpen} kids=${kids} onRetryChild=${onRetryChild}/>`;
  };

  return html`
    ${data && data.truncated ? html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">
      capped: the top ${rows.length} groups by spend; the total above is still exact</span></div>` : null}
    <${SortableTable} wide columns=${[identity, ...countColumns]} rows=${rows} rowKey=${(r) => r.key}
      defaultSort="usd" defaultDir="desc"
      empty=${html`<${Empty} title="no spend in this window" note="No cost row falls in this window."/>`}/>
    ${openRow ? html`
      <div style="margin-top:10px;padding-left:10px;border-left:2px solid var(--line)">
        <div class="section__note" style="margin-bottom:6px">${openRow.label} · ${req.group === 'rows'
          ? 'cost rows' : req.group.split(',').map((d) => DIM_HEAD[d]).join(' · ').toLowerCase()}</div>
        ${child()}
      </div>` : null}`;
}

// BH-9068: one line, the day's cash and its three parts. It wraps on a narrow
// screen. The per-account and per-vendor parts open below it.
function CashLine({ cash }) {
  const line = cashLine(cash);
  if (!line) return null;
  const part = (usd) => (usd === null || usd === undefined ? 'unknown' : fmtUsd(usd));
  return html`<div data-cash-line style="display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline;margin-bottom:10px;overflow-wrap:anywhere">
    <b>CASH · ${cash.day} UTC</b>
    <span class="num" style="min-width:0">${line}</span>
    <details style="flex-basis:100%;min-width:0">
      <summary class="section__note">parts</summary>
      <ul style="margin:4px 0;padding-left:18px">
        ${(cash.accounts || []).map((a) => html`<li key=${'a' + a.account}>${a.account}: subscription ${part(a.day_usd)}${
          a.usd_per_month === null ? ' (no price)' : ` (${fmtUsd(a.usd_per_month)}/month)`}${
          a.kind === 'vendor' ? ' · vendor subscription, no overage meter'
            : a.overage_excluded ? ` · overage not counted (${a.overage_excluded === 'no-login' ? 'no login' : a.overage_excluded})`
              : ` · overage ${part(a.overage_usd)}`}</li>`)}
        ${(cash.vendors || []).map((v) => html`<li key=${'v' + v.vendor}>${v.vendor}: ${
          v.excluded ? `not metered cash (${v.excluded})` : `metered ${part(v.usd)}`} (${v.polls} polls)</li>`)}
      </ul>
    </details>
  </div>`;
}

export function CostBreakdownView({ data, error, loading, reload, win, onWin, view, onView, open = [], onOpen, kids = {}, onRetryChild }) {
  const buttons = (list, cur, on) => html`<span style="display:inline-flex;gap:6px;flex-wrap:wrap">
    ${list.map((x) => html`
      <button key=${x.key} type="button" class=${x.key === cur ? 'tab tab--on' : 'tab'}
        aria-pressed=${x.key === cur ? 'true' : 'false'}
        onClick=${() => on(x.key)}>${x.label}</button>`)}
  </span>`;
  const right = html`<span style="display:inline-flex;gap:12px;flex-wrap:wrap">
    ${buttons(BREAKDOWN_WINDOWS, win, onWin)}${buttons(BREAKDOWN_VIEWS, view, onView)}
  </span>`;

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    return html`<${Level} viewKey=${view} depth=${0} data=${data} filters=${{}}
      open=${open} onOpen=${onOpen} kids=${kids} onRetryChild=${onRetryChild}/>`;
  };

  const tot = (data && data.total) || null;
  const span = (ts) => String(ts || '').slice(0, 16).replace('T', ' ');
  const note = data && tot
    ? `cost_rows · ${span(data.since)} → ${span(data.until)} · total ${fmtUsd(tot.usd)} (cash ${fmtUsd(tot.cash_usd)}, API-equivalent, not cash ${fmtUsd(tot.equiv_usd)})`
    : null;
  return html`<${Section} title="SPEND BREAKDOWN" note=${note} right=${right}><${CashLine} cash=${data && data.cash}/>${body()}<//>`;
}

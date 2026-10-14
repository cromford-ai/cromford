import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { laneHref } from '../lib/settings.js';
import { SortableTable } from '../ui/SortableTable.js';
import { UsdCell } from '../ui/UsdCell.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { laneSpendRows, ceilingText, switchBanner, laneSpendNote, p99Footnote } from '../lib/lane-spend.js';

// BH-6174 (BH-5526 slice C4): each lane's spend today against its alert line
// and its ceiling, from GET /api/metrics/lane-spend. Mounted on /costs below
// CAPS. Split like AccountUsage: the section owns the fetch, the view is a pure
// function of props so the tests render it server-side. Read only: the ceiling
// is edited through the settings path, never from here.

export function LaneSpendSection() {
  const a = useApi(() => api.laneSpend(), [], { intervalMs: 60000 });
  return html`<${LaneSpendView} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}/>`;
}

// A null is `—`, never a $0.00 that the lane did not report.
const usd = (v) => (v === null ? html`<span class="na">—</span>` : html`<${UsdCell} value=${v} basis="api"/>`);

// A stage-<s> id is not in the registry, so the console has no screen for it.
const laneCell = (r) => (r.registered
  ? html`<${Link} to=${laneHref(r.lane)} class="cell-name">${r.lane}<//>`
  : html`<span class="na" title="not a registered lane: no detail screen">${r.lane ?? '(unnamed)'}</span>`);

const PILL = { dead: 'pill pill--dead', warn: 'pill pill--warn', ok: 'pill', muted: 'pill pill--muted' };

export const laneSpendColumns = [
  { key: 'lane', label: 'LANE', sort: (r) => r.lane, cell: laneCell },
  { key: 'today', label: 'TODAY', sort: (r) => r.today_usd, cell: (r) => usd(r.today_usd), align: 'right' },
  { key: 'alert', label: 'ALERT LINE', sort: (r) => r.alert_usd, cell: (r) => usd(r.alert_usd), align: 'right' },
  {
    key: 'ceiling', label: 'CEILING', sort: (r) => r.ceiling_usd,
    cell: (r) => (r.ceiling_state === 'armed' && r.ceiling_usd !== null ? usd(r.ceiling_usd) : ceilingText(r)),
    align: 'right'
  },
  {
    key: 'pct', label: '% OF CEILING', sort: (r) => r.pct_of_ceiling,
    cell: (r) => (r.pct_of_ceiling === null ? '—' : `${r.pct_of_ceiling}%`), align: 'right'
  },
  {
    key: 'p99', label: 'P99 · DAYS', sort: (r) => r.p99_usd,
    cell: (r) => (r.p99_usd === null ? '—' : `$${r.p99_usd.toFixed(2)} · ${r.p99_days ?? '—'}d`), align: 'right'
  },
  {
    key: 'state', label: 'STATE', sort: (r) => r.state.rank,
    cell: (r) => html`<span class=${PILL[r.state.tone] || PILL.muted}>${r.state.label}</span>`
  },
];

export function LaneSpendView({ data, error, loading, reload }) {
  const rows = laneSpendRows(data);
  const banner = switchBanner(data);
  const foot = p99Footnote(data);

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    return html`<${SortableTable} wide columns=${laneSpendColumns} rows=${rows} rowKey=${(r) => r.key}
      defaultSort="today" defaultDir="desc"
      empty=${html`<${Empty} title="no lane has spend, an alert line or a ceiling today"/>`}/>`;
  };

  return html`
    <${Section} title="LANE SPEND · TODAY (UTC)" note=${data ? laneSpendNote(data) : null}>
      ${banner ? html`<div class="banner banner--warn" style="margin-bottom:10px"><span style="overflow-wrap:anywhere">${banner}</span></div>` : null}
      ${body()}
      ${data && foot ? html`<div class="footnote" style="margin-top:8px"><span style="color:var(--faint)">${foot}</span></div>` : null}
    <//>`;
}

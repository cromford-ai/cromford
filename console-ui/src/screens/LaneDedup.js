import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { fmtUsd, fmtNum } from '../lib/format.js';
import { prLink, boxLink } from '../lib/anchored.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';

// BH-2537.4: how many calls each lane spends per distinct input (guard_fp),
// from GET /api/metrics/lane-dedup. Drills lane -> fp -> the individual cost
// rows. The numbers are the worker's; this file only lays them out. Until the
// aggregation (#2669) lands the route answers `lanes: []` and the section shows
// its empty state. Split like AccountUsage: the section owns the fetch, the
// view is a pure function of props so it renders server-side in the tests.

export const DEDUP_WINDOWS = [
  { days: 7, label: '7D' },
  { days: 1, label: '1D' },
  { days: 30, label: '30D' },
];
const FP_CALLS_LIMIT = 50;

// Nulls stay null: a lane whose calls carry no fp has no ratio, and that is
// unknown, not zero.
export function laneRows(data) {
  const lanes = (data && Array.isArray(data.lanes)) ? data.lanes : [];
  return lanes.map((l) => ({
    key: l.lane ?? '\u0000unnamed',
    lane: l.lane ?? null,
    label: l.lane ?? '(unnamed)',
    calls: l.calls ?? null,
    distinct_fp: l.distinct_fp ?? null,
    calls_per_fp: l.calls_per_fp ?? null,
    distinct_tickets: l.distinct_tickets ?? null,
    distinct_prs: l.distinct_prs ?? null,
    no_fp_calls: l.no_fp_calls ?? null,
    usd: l.usd ?? null,
    fps: Array.isArray(l.fps) ? l.fps : [],
  }));
}

export function fmtRatio(v) {
  if (v === null || v === undefined || !Number.isFinite(Number(v))) return '—';
  return fmtNum(Number(v), { decimals: 2 });
}

// Only a real GitHub URL becomes a link; anything else is shown as text.
export const fpPrLink = (fp) => prLink({ pr_url: fp && fp.pr });

const isoSecond = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

// The same window the lane table shows. An unnamed lane has no lane_id the
// route can filter on, so it is dropped and the panel says so.
export function fpCallsParams({ lane, fp, days, now }) {
  return { guard_fp: fp, lane_id: lane ?? null, since: isoSecond(now - days * 86400000), limit: FP_CALLS_LIMIT };
}

export const showNoFpNote = (rows) => rows.some((r) => Number(r.no_fp_calls) > 0);

// The fetcher FpCallsPanel hands to useApi.
export const loadFpCalls = (lane, fp, days, now) => api.costRows(fpCallsParams({ lane, fp, days, now }));

export function LaneDedupSection() {
  const [days, setDays] = useState(7);
  const a = useApi(() => api.laneDedup(days), [days], { intervalMs: 60000 });
  return html`<${LaneDedupView} data=${a.data} error=${a.error} loading=${a.loading}
    reload=${a.reload} days=${days} onDays=${setDays}/>`;
}

const na = (v) => v ?? '—';

const callColumns = [
  { key: 'ts', label: 'TS', sort: (r) => r.ts, cell: (r) => na(r.ts) },
  {
    key: 'box', label: 'BOX', sort: (r) => r.box,
    cell: (r) => (r.box ? html`<${Link} to=${boxLink().to} class="cell-name">${r.box}<//>` : '—'),
  },
  { key: 'runner', label: 'RUNNER', sort: (r) => r.runner, cell: (r) => na(r.runner) },
  { key: 'model', label: 'MODEL', sort: (r) => r.model, cell: (r) => na(r.model) },
  { key: 'rc', label: 'RC', sort: (r) => r.rc, cell: (r) => na(r.rc), align: 'right' },
  { key: 'usd', label: '$', sort: (r) => r.cost_usd, cell: (r) => fmtUsd(r.cost_usd), align: 'right' },
  { key: 'session', label: 'SESSION', sort: (r) => r.session_id, cell: (r) => na(r.session_id) },
];

export function FpCallsView({ data, error, loading, reload, fp, lane }) {
  const rows = (data && Array.isArray(data.cost_rows)) ? data.cost_rows : [];
  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${3} height=${18}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    if (!rows.length) return html`<${Empty} title="no calls for this input in this window"/>`;
    return html`
      ${lane === null ? html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">
        this lane has no id, so these are this input's calls in every lane</span></div>` : null}
      <${SortableTable} wide columns=${callColumns} rows=${rows} rowKey=${(r) => `${r.box}|${r.row_hash}`}
        defaultSort="ts" defaultDir="desc"/>
      ${rows.length === FP_CALLS_LIMIT ? html`<div class="footnote" style="margin-top:6px"><span style="color:var(--faint)">
        showing the newest ${FP_CALLS_LIMIT} calls</span></div>` : null}`;
  };
  return html`<div style="margin-top:12px">
    <div class="section__note" style="margin-bottom:6px">${fp} · calls</div>
    ${body()}
  </div>`;
}

function FpCallsPanel({ lane, fp, days }) {
  const [now] = useState(() => Date.now());
  const a = useApi(() => loadFpCalls(lane, fp, days, now), [lane, fp, days]);
  return html`<${FpCallsView} data=${a.data} error=${a.error} loading=${a.loading}
    reload=${a.reload} fp=${fp} lane=${lane}/>`;
}

export function LaneDedupView({ data, error, loading, reload, days, onDays, initialOpen = null, initialFp = null }) {
  const [open, setOpen] = useState(initialOpen);
  const [openFp, setOpenFp] = useState(initialFp);
  const rows = laneRows(data);

  const switcher = html`<span style="display:inline-flex;gap:6px;flex-wrap:wrap">
    ${DEDUP_WINDOWS.map((w) => html`
      <button key=${w.days} type="button" class=${w.days === days ? 'tab tab--on' : 'tab'}
        aria-pressed=${w.days === days ? 'true' : 'false'}
        onClick=${() => onDays(w.days)}>${w.label}</button>`)}
  </span>`;

  const laneColumns = [
    {
      key: 'lane', label: 'LANE', sort: (r) => r.label,
      cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${open === r.key ? 'true' : 'false'}
        onClick=${() => { setOpen(open === r.key ? null : r.key); setOpenFp(null); }}>${r.label}</button>`,
    },
    { key: 'calls', label: 'CALLS', sort: (r) => r.calls, cell: (r) => na(r.calls), align: 'right' },
    { key: 'distinct_fp', label: 'DISTINCT FPS', sort: (r) => r.distinct_fp, cell: (r) => na(r.distinct_fp), align: 'right' },
    { key: 'calls_per_fp', label: 'CALLS/FP', sort: (r) => r.calls_per_fp, cell: (r) => fmtRatio(r.calls_per_fp), align: 'right' },
    { key: 'distinct_tickets', label: 'DISTINCT TICKETS', sort: (r) => r.distinct_tickets, cell: (r) => na(r.distinct_tickets), align: 'right' },
    { key: 'distinct_prs', label: 'DISTINCT PRS', sort: (r) => r.distinct_prs, cell: (r) => na(r.distinct_prs), align: 'right' },
    { key: 'no_fp_calls', label: 'NO-FP CALLS', sort: (r) => r.no_fp_calls, cell: (r) => na(r.no_fp_calls), align: 'right' },
    { key: 'usd', label: '$', sort: (r) => r.usd, cell: (r) => fmtUsd(r.usd), align: 'right' },
  ];

  const fpColumns = [
    {
      key: 'fp', label: 'FP', sort: (f) => f.fp,
      cell: (f) => html`<button type="button" class="btn btn--sm" aria-expanded=${openFp === f.fp ? 'true' : 'false'}
        onClick=${() => setOpenFp(openFp === f.fp ? null : f.fp)}>${f.fp}</button>`,
    },
    { key: 'calls', label: 'CALLS', sort: (f) => f.calls, cell: (f) => na(f.calls), align: 'right' },
    { key: 'ticket', label: 'TICKET', sort: (f) => f.ticket, cell: (f) => na(f.ticket) },
    {
      key: 'pr', label: 'PR', sort: (f) => f.pr,
      cell: (f) => {
        const l = fpPrLink(f);
        return l ? html`<a href=${l.to} target="_blank" rel="noopener">${f.pr}</a>` : na(f.pr || null);
      },
    },
    {
      key: 'project', label: 'PROJECT', sort: (f) => f.project,
      cell: (f) => (f.project === null || f.project === undefined
        ? html`<span class="na">(no project)</span>`
        : html`<${Link} to=${`/p/${encodeURIComponent(f.project)}`} class="cell-name">${f.project}<//>`),
    },
    { key: 'usd', label: '$', sort: (f) => f.usd, cell: (f) => fmtUsd(f.usd), align: 'right' },
  ];

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    if (!rows.length) {
      return html`<${Empty} title="no calls in this window" note="No cost row carries a lane in this window."/>`;
    }
    const openRow = rows.find((r) => r.key === open);
    const fpOpen = openRow && openRow.fps.some((f) => f.fp === openFp);
    return html`
      ${data.truncated && data.truncated.fps ? html`<div class="banner banner--warn" style="margin-bottom:10px"><span>
        Each lane lists only its top inputs. The worker capped this list, so it does not cover every input in the window.
      </span></div>` : null}
      ${showNoFpNote(rows) ? html`<div class="footnote" style="margin-bottom:10px"><span style="color:var(--faint)">
        rows written before BH-2537 carry no fingerprint</span></div>` : null}
      <${SortableTable} wide columns=${laneColumns} rows=${rows} rowKey=${(r) => r.key}
        defaultSort="calls_per_fp" defaultDir="desc"/>
      ${openRow ? html`
        <div style="margin-top:12px">
          <div class="section__note" style="margin-bottom:6px">${openRow.label} · inputs</div>
          <${SortableTable} wide columns=${fpColumns} rows=${openRow.fps} rowKey=${(f) => f.fp}
            defaultSort="calls" defaultDir="desc"
            empty=${html`<${Empty} title="no inputs recorded for this lane"/>`}/>
          ${fpOpen ? html`<${FpCallsPanel} key=${`${openRow.key}|${openFp}|${days}`}
            lane=${openRow.lane} fp=${openFp} days=${days}/>` : null}
        </div>` : null}`;
  };

  const note = data ? `cost_rows per lane_id · last ${days}d` : null;
  return html`<${Section} title="CALLS PER DISTINCT INPUT · BY LANE" note=${note} right=${switcher}>${body()}<//>`;
}

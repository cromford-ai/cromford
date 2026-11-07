import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { fmtNum } from '../lib/format.js';

// BH-9154 (Fix 5 of BH-9066): the daily review counter on the Lead reviews
// screen. One row per day, newest first: the review model calls by kind,
// reviews per merged PR, and the semantic rebinds (review-saving REUSED). The
// worker rolls the counts up from cost_rows, the merge ledger and stage_events
// (worker/jobs/src/routes/review-counts.js); this panel only reads them.
// A kind the worker's kind map has no rule for comes back null and shows as
// "—" with a title, never as 0. No ?days: the worker answers its
// review_counts.max_days (a settings row), so the panel holds no day count.

export const REVIEW_KINDS = [
  { key: 'lens', label: 'LENS' },
  { key: 'fix-rereview', label: 'FIX RE-REVIEW' },
  { key: 'lead', label: 'LEAD' },
  { key: 'conductor', label: 'CONDUCTOR' },
  { key: 'autopilot', label: 'AUTOPILOT' },
  { key: 'rescue', label: 'RESCUE' },
  { key: 'resolver', label: 'RESOLVER' }
];

const POLL = { intervalMs: 300000 };
const na = (why) => html`<span class="na" title=${why}>—</span>`;
const num = (n) => html`<span class="num">${fmtNum(n)}</span>`;

// Reviews per merged PR: n/a when no PR merged that day, never 0 or infinity.
export function perMergedText(d) {
  return d && Number.isFinite(d.per_merged) && d.merged_prs > 0 ? fmtNum(d.per_merged, { decimals: 1 }) : 'n/a';
}

function columns() {
  return [
    { key: 'day', label: 'DAY', sort: (d) => d.day, cell: (d) => html`<span class="num">${d.day}</span>` },
    ...REVIEW_KINDS.map((k) => ({
      key: k.key, label: k.label, sort: (d) => (d.kinds[k.key] === null ? -1 : d.kinds[k.key]),
      cell: (d) => (d.kinds[k.key] === null ? na('no kind-map rule counts this kind (settings row review_counts.kind_map)') : num(d.kinds[k.key]))
    })),
    { key: 'reviews', label: 'REVIEWS', sort: (d) => d.reviews, cell: (d) => num(d.reviews) },
    { key: 'merged_prs', label: 'MERGED PRS', sort: (d) => d.merged_prs, cell: (d) => num(d.merged_prs) },
    { key: 'per_merged', label: 'REVIEWS / MERGED PR', sort: (d) => (d.merged_prs > 0 ? d.per_merged : -1),
      cell: (d) => (d.merged_prs > 0 ? html`<span class="num">${perMergedText(d)}</span>` : na('no PR merged this day')) },
    { key: 'rebinds', label: 'REBINDS', sort: (d) => d.rebinds, cell: (d) => num(d.rebinds) }
  ];
}

export function ReviewCountsView({ counts }) {
  const data = counts.data;
  const days = data && Array.isArray(data.days) ? data.days : null;
  let body;
  if (counts.loading && !data) body = html`<${Skeleton} rows=${3}/>`;
  else if (counts.error && !data) body = html`<${ErrorBox} error=${counts.error} onRetry=${counts.reload}/>`;
  else if (!days) body = html`<${ErrorBox} error="bad response" onRetry=${counts.reload}/>`;
  else if (!days.length) body = html`<${Empty} title="none" note=${`No review was counted in the last ${data.max_days} days.`}/>`;
  else {
    body = html`
      <div style="overflow-x:auto;max-width:100%">
        <${SortableTable} columns=${columns()} rows=${days} rowKey=${(d) => d.day} defaultSort="day" defaultDir="desc"/>
      </div>
      ${Array.isArray(data.unmapped) && data.unmapped.length ? html`<div class="footnote"><span>not counted (no kind-map rule): ${data.unmapped.join(', ')}</span></div>` : null}
      ${data.rolled_at ? html`<div class="footnote"><span>rolled up ${data.rolled_at}</span></div>` : null}`;
  }
  return html`
    <div data-panel="review-counts">
      <${Section} title="REVIEW COUNTS" note="review model calls per day, by kind, with the rebinds that saved one">
        ${body}
      <//>
    </div>`;
}

export function ReviewCountsPanel() {
  const counts = useApi(() => api.reviewCounts(), [], POLL);
  return html`<${ReviewCountsView} counts=${counts}/>`;
}

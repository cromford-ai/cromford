import { useState, useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { fmtUsd, fmtNum } from '../lib/format.js';
import { LeafRows } from './CostBreakdown.js';

// BH-3926 (BH-3921.3): how many triage tickets the model was paid to re-read
// although their inputs had not changed, per day and project. The numbers are
// GET /api/metrics/triage-paid-unchanged's (worker/jobs/src/routes/triage-waste.js),
// read off the cost-row notes bin/lib/triage-state-waste.sh writes. Each count
// drills down to that day's triage cost rows for the project, through the same
// leaf table SPEND BREAKDOWN uses. Split like CostBreakdown: the section owns
// the fetches, the view is a pure function of props.

const DAYS = 14;

export const rowKeyOf = (r) => `${r.day}|${r.project ?? ''}`;

// The leaf read for one row: that UTC day's triage rows for the project. A
// null project is sent as `project=` (the worker reads IS NULL).
export const drillParams = (r) => ({
  since: `${r.day}T00:00:00Z`, until: `${r.day}T23:59:59.999Z`,
  group: 'rows', limit: 500, stage: 'triage', project: r.project ?? ''
});

export function TriageWasteSection() {
  const a = useApi(() => api.triagePaidUnchanged(DAYS), [], { intervalMs: 60000 });
  const [open, setOpen] = useState(null);
  const [kids, setKids] = useState({});
  // Bumped on every open/close, so an answer for a row no longer open is dropped.
  const gen = useRef(0);

  const load = (r) => {
    const key = rowKeyOf(r);
    const g = ++gen.current;
    setKids((k) => ({ ...k, [key]: { loading: true } }));
    api.costBreakdown(drillParams(r)).then(
      (data) => { if (g === gen.current) setKids((k) => ({ ...k, [key]: { data } })); },
      (error) => { if (g === gen.current) setKids((k) => ({ ...k, [key]: { error } })); });
  };
  const onOpen = (r) => {
    const key = rowKeyOf(r);
    if (open === key) { gen.current += 1; setOpen(null); return; }
    setOpen(key);
    if (kids[key] && kids[key].data) { gen.current += 1; return; }
    load(r);
  };

  return html`<${TriageWasteView} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}
    open=${open} onOpen=${onOpen} kid=${open ? kids[open] : null} onRetryChild=${load}/>`;
}

export function TriageWasteView({ data, error, loading, reload, open = null, onOpen, kid = null, onRetryChild }) {
  const rows = (data && data.rows) || [];
  const openRow = rows.find((r) => rowKeyOf(r) === open) || null;

  const columns = [
    // Day desc, then paid-unchanged desc inside a day, from one sort key.
    { key: 'day', label: 'DAY', sort: (r) => `${r.day}|${String(r.paid_unchanged ?? 0).padStart(9, '0')}`, cell: (r) => r.day },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => (r.project
        ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}>${r.project}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'paid_unchanged', label: 'PAID UNCHANGED', align: 'right', sort: (r) => r.paid_unchanged,
      cell: (r) => html`<button type="button" class="btn btn--sm"
        aria-expanded=${open === rowKeyOf(r) ? 'true' : 'false'}
        title="the triage cost rows of this day and project"
        onClick=${() => onOpen && onOpen(r)}>${r.paid_unchanged}</button>`
    },
    { key: 'waste_calls', label: 'WASTE CALLS', align: 'right', sort: (r) => r.waste_calls, cell: (r) => r.waste_calls },
    { key: 'triage_calls', label: 'TRIAGE CALLS', align: 'right', sort: (r) => r.triage_calls, cell: (r) => r.triage_calls },
    {
      key: 'usd', label: '$', align: 'right', sort: (r) => r.usd ?? null,
      cell: (r) => html`<span class="num">${r.usd === null || r.usd === undefined ? '—' : fmtUsd(r.usd)}</span>`
    }
  ];

  const child = () => {
    if (!kid || kid.loading) return html`<${Skeleton} rows=${3} height=${18}/>`;
    if (kid.error) return html`<${ErrorBox} error=${kid.error} onRetry=${onRetryChild ? () => onRetryChild(openRow) : null}/>`;
    return html`<${LeafRows} data=${kid.data}/>`;
  };

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    return html`
      ${data && data.truncated ? html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">
        capped: the newest ${fmtNum(rows.length)} day · project rows</span></div>` : null}
      <${SortableTable} wide columns=${columns} rows=${rows} rowKey=${rowKeyOf} defaultSort="day" defaultDir="desc"
        empty=${html`<${Empty} title="no triage calls in this window" note="No successful triage cost row falls in this window."/>`}/>
      ${openRow ? html`
        <div style="margin-top:10px;padding-left:10px;border-left:2px solid var(--line)">
          <div class="section__note" style="margin-bottom:6px">${openRow.day} · ${openRow.project || '(no project)'} · triage cost rows</div>
          ${child()}
        </div>` : null}`;
  };

  const note = data ? `cost_rows · stage triage · rc 0 · since ${String(data.from || '').slice(0, 10)} · ${data.days} days` : null;
  return html`<${Section} title="TRIAGE PAID UNCHANGED" note=${note}>${body()}<//>`;
}

import { useState, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';

// BH-5806 (BH-5794.1): BLOCKs by category per week, on /lead-reviews. The
// numbers are GET /api/block-findings/weekly's (worker/jobs/src/routes/block-findings.js),
// written by bin/lesson-classify.sh: one row per finding of each lead, human or
// builder BLOCK, with the category the classify call named. Each week x
// category row opens its findings (GET /api/block-findings?category=&week=),
// each linking the PR and the verdict. Split like TriageWaste: the section owns
// the fetches, the view is a pure function of props.

const WEEKS = 8;

export const rowKeyOf = (r) => `${r.week}|${r.category}`;

const prUrl = (f) => `https://github.com/${f.repo}/pull/${f.pr}`;

export function BlockCategoriesSection() {
  const a = useApi(() => api.blockFindingsWeekly(WEEKS), [], { intervalMs: 300000 });
  const [open, setOpen] = useState(null);
  const [kids, setKids] = useState({});
  // Bumped on every open/close, so an answer for a row no longer open is dropped.
  const gen = useRef(0);

  const load = (r) => {
    const key = rowKeyOf(r);
    const g = ++gen.current;
    setKids((k) => ({ ...k, [key]: { loading: true } }));
    api.blockFindings({ category: r.category, week: r.week }).then(
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

  return html`<${BlockCategoriesView} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}
    open=${open} onOpen=${onOpen} kid=${open ? kids[open] : null} onRetryChild=${load}/>`;
}

export function FindingRows({ data }) {
  const rows = (data && data.rows) || [];
  const columns = [
    { key: 'pr', label: 'PR', sort: (f) => f.pr, cell: (f) => html`<a href=${prUrl(f)} target="_blank" rel="noopener">#${f.pr}</a>` },
    {
      key: 'verdict_id', label: 'VERDICT', sort: (f) => f.verdict_id,
      cell: (f) => html`<a href=${f.report_url || prUrl(f)} target="_blank" rel="noopener"
        title="the review that recorded this BLOCK">verdict #${f.verdict_id}</a>`
    },
    { key: 'ticket', label: 'TICKET', sort: (f) => f.ticket, cell: (f) => f.ticket || html`<span class="na">—</span>` },
    {
      key: 'cause', label: 'CAUSE', sort: (f) => f.cause,
      cell: (f) => html`<span>${f.cause || f.text}</span>${f.infra_false
        ? html` <span class="pill" title="the classifier says this BLOCK is not the PR's fault">infra / false</span>` : null}`
    },
    { key: 'files', label: 'FILES', sort: (f) => (f.files || []).join(' '), cell: (f) => (f.files || []).join(', ') },
    { key: 'verdict_at', label: 'WHEN', sort: (f) => f.verdict_at, cell: (f) => String(f.verdict_at || '').slice(0, 10) }
  ];
  return html`<${SortableTable} wide columns=${columns} rows=${rows} rowKey=${(f) => f.id} defaultSort="verdict_at" defaultDir="desc"
    empty=${html`<${Empty} title="no findings" note="Nothing is stored for this week and category."/>`}/>`;
}

export function BlockCategoriesView({ data, error, loading, reload, open = null, onOpen, kid = null, onRetryChild }) {
  const rows = (data && data.rows) || [];
  const openRow = rows.find((r) => rowKeyOf(r) === open) || null;

  const columns = [
    // Week desc, then findings desc inside a week, from one sort key.
    { key: 'week', label: 'WEEK', sort: (r) => `${r.week}|${String(r.findings ?? 0).padStart(9, '0')}`, cell: (r) => r.week },
    {
      key: 'category', label: 'CATEGORY', sort: (r) => r.category,
      cell: (r) => html`<span title=${r.category}>${r.name}</span> <span class="na">${r.category}</span>`
    },
    {
      key: 'findings', label: 'FINDINGS', align: 'right', sort: (r) => r.findings,
      cell: (r) => html`<button type="button" class="btn btn--sm"
        aria-expanded=${open === rowKeyOf(r) ? 'true' : 'false'}
        title="the findings of this week and category"
        onClick=${() => onOpen && onOpen(r)}>${r.findings}</button>`
    },
    { key: 'verdicts', label: 'VERDICTS', align: 'right', sort: (r) => r.verdicts, cell: (r) => r.verdicts },
    { key: 'prs', label: 'PRS', align: 'right', sort: (r) => r.prs, cell: (r) => r.prs }
  ];

  const child = () => {
    if (!kid || kid.loading) return html`<${Skeleton} rows=${3} height=${18}/>`;
    if (kid.error) return html`<${ErrorBox} error=${kid.error} onRetry=${onRetryChild ? () => onRetryChild(openRow) : null}/>`;
    return html`<${FindingRows} data=${kid.data}/>`;
  };

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    return html`
      <${SortableTable} wide columns=${columns} rows=${rows} rowKey=${rowKeyOf} defaultSort="week" defaultDir="desc"
        empty=${html`<${Empty} title="no BLOCK classified in this window" note="bin/lesson-classify.sh writes a row per finding of each BLOCK verdict."/>`}/>
      ${openRow ? html`
        <div style="margin-top:10px;padding-left:10px;border-left:2px solid var(--line);overflow-x:auto">
          <div class="section__note" style="margin-bottom:6px">${openRow.week} · ${openRow.name} · findings</div>
          ${child()}
        </div>` : null}`;
  };

  const note = data ? `block_findings · per week (Monday, UTC) · since ${data.from || ''} · ${data.weeks} weeks` : null;
  return html`<${Section} title="BLOCKS BY CATEGORY" note=${note}>${body()}<//>`;
}

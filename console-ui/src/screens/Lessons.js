import { useState, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { FindingRows } from './BlockCategories.js';

// BH-5808 (BH-5794.3): the weekly lesson digest, on /lead-reviews. The numbers
// are GET /api/lessons/digest's (worker/jobs/src/routes/lessons.js), the same
// JSON bin/lesson-measure.sh renders into the operator's weekly message: the
// BLOCK rate overall and per category, each recorded lesson with its before
// and after rate and its status, and the top uncovered causes. A category row
// opens its newest findings (GET /api/block-findings?category=), each linking
// the PR and the verdict. Split like BlockCategories: the section owns the
// fetches, the view is a pure function of props.

const DAYS = 7;

// rate per 100 reviewed PRs, one decimal; null with no reviewed PR.
export const rateOf = (blocks, reviewed) =>
  Number.isInteger(reviewed) && reviewed > 0 && Number.isInteger(blocks) ? Math.round((blocks * 1000) / reviewed) / 10 : null;
const fmtRate = (r) => (r === null || r === undefined ? html`<span class="na">—</span>` : String(r));
const linkOf = (l) => l.url || `https://github.com/${l.repo}/${l.kind === 'pr' ? 'pull' : 'issues'}/${l.number}`;

export function LessonsSection() {
  const a = useApi(() => api.lessonsDigest(DAYS), [], { intervalMs: 300000 });
  const [open, setOpen] = useState(null);
  const [kids, setKids] = useState({});
  // Bumped on every open/close, so an answer for a row no longer open is dropped.
  const gen = useRef(0);

  const load = (category) => {
    const g = ++gen.current;
    setKids((k) => ({ ...k, [category]: { loading: true } }));
    api.blockFindings({ category }).then(
      (data) => { if (g === gen.current) setKids((k) => ({ ...k, [category]: { data } })); },
      (error) => { if (g === gen.current) setKids((k) => ({ ...k, [category]: { error } })); });
  };
  const onOpen = (c) => {
    if (open === c.id) { gen.current += 1; setOpen(null); return; }
    setOpen(c.id);
    if (kids[c.id] && kids[c.id].data) { gen.current += 1; return; }
    load(c.id);
  };

  return html`<${LessonsView} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}
    open=${open} onOpen=${onOpen} kid=${open ? kids[open] : null} onRetryChild=${load}/>`;
}

export function LessonsView({ data, error, loading, reload, open = null, onOpen, kid = null, onRetryChild }) {
  const cats = (data && data.categories) || [];
  const lessons = (data && data.lessons && data.lessons.list) || [];
  const openCat = cats.find((c) => c.id === open) || null;

  const catColumns = [
    {
      key: 'id', label: 'CATEGORY', sort: (c) => c.id,
      cell: (c) => html`<span title=${c.id}>${c.name}</span> <span class="na">${c.id}</span>`
    },
    {
      key: 'blocks', label: 'BLOCKS', align: 'right', sort: (c) => c.blocks,
      cell: (c) => html`<button type="button" class="btn btn--sm"
        aria-expanded=${open === c.id ? 'true' : 'false'}
        title="the newest findings of this category"
        onClick=${() => onOpen && onOpen(c)}>${c.blocks}</button>`
    },
    { key: 'rate', label: 'RATE', unit: '/100 PRs', align: 'right', sort: (c) => c.rate, cell: (c) => fmtRate(c.rate) },
    { key: 'lesson_status', label: 'LESSON', sort: (c) => c.lesson_status || '', cell: (c) => c.lesson_status || html`<span class="na">none</span>` }
  ];

  const lessonColumns = [
    {
      key: 'number', label: 'LESSON', sort: (l) => l.number,
      cell: (l) => html`<a href=${linkOf(l)} target="_blank" rel="noopener" title=${l.title || ''}>${l.kind === 'pr' ? 'PR' : 'issue'} #${l.number}</a>`
    },
    { key: 'category', label: 'CATEGORY', sort: (l) => l.category, cell: (l) => l.category },
    { key: 'change_type', label: 'STAGE', sort: (l) => l.change_type, cell: (l) => l.change_type },
    { key: 'merged_at', label: 'MERGED', sort: (l) => l.merged_at, cell: (l) => String(l.merged_at || '').slice(0, 10) },
    {
      key: 'before', label: 'BEFORE', unit: '/100', align: 'right', sort: (l) => rateOf(l.before_blocks, l.before_reviewed),
      cell: (l) => html`<span title=${`${l.before_blocks ?? '?'} BLOCKs in ${l.before_reviewed ?? '?'} reviewed PRs`}>${fmtRate(rateOf(l.before_blocks, l.before_reviewed))}</span>`
    },
    {
      key: 'after', label: 'AFTER', unit: '/100', align: 'right', sort: (l) => rateOf(l.after_blocks, l.after_reviewed),
      cell: (l) => html`<span title=${`${l.after_blocks ?? '?'} BLOCKs in ${l.after_reviewed ?? '?'} reviewed PRs`}>${fmtRate(rateOf(l.after_blocks, l.after_reviewed))}</span>`
    },
    { key: 'cut_pct', label: 'CUT', unit: '%', align: 'right', sort: (l) => l.cut_pct, cell: (l) => fmtRate(l.cut_pct) },
    { key: 'status', label: 'STATUS', sort: (l) => l.status, cell: (l) => l.status },
    {
      key: 'escalation', label: 'ESCALATION', sort: (l) => l.escalation_number || 0,
      cell: (l) => l.escalation_number
        ? html`<a href=${l.escalation_url || `https://github.com/${l.repo}/issues/${l.escalation_number}`} target="_blank" rel="noopener">#${l.escalation_number} ${l.escalation_stage || ''}</a>`
        : html`<span class="na">—</span>`
    },
    {
      key: 'removal', label: 'REMOVAL', sort: (l) => l.removal_number || 0,
      cell: (l) => l.removal_number
        ? html`<a href=${l.removal_url || `https://github.com/${l.repo}/pull/${l.removal_number}`} target="_blank" rel="noopener">PR #${l.removal_number}</a>`
        : (l.removal_note ? l.removal_note : html`<span class="na">—</span>`)
    }
  ];

  const child = () => {
    if (!kid || kid.loading) return html`<${Skeleton} rows=${3} height=${18}/>`;
    if (kid.error) return html`<${ErrorBox} error=${kid.error} onRetry=${onRetryChild ? () => onRetryChild(openCat.id) : null}/>`;
    return html`<${FindingRows} data=${kid.data}/>`;
  };

  const body = () => {
    if (loading && !data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (error && !data) return html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    const o = data.overall || {};
    const l = data.lessons || {};
    const unc = data.uncovered || [];
    return html`
      <div class="section__note" data-testid="lessons-summary" style="margin-bottom:8px">
        BLOCK rate ${fmtRate(o.rate)} per 100 reviewed PRs (${o.blocks ?? 0} BLOCKs in ${o.reviewed ?? 0} PRs) ·
        lessons added ${l.added ?? 0} · measuring ${l.measuring ?? 0} · working ${l.working ?? 0} ·
        not working ${l.not_working ?? 0} · retired ${l.retired ?? 0} · removal PR open ${l.removing ?? 0}
      </div>
      <${SortableTable} wide columns=${catColumns} rows=${cats} rowKey=${(c) => c.id} defaultSort="blocks" defaultDir="desc"
        empty=${html`<${Empty} title="no BLOCK in this window" note="bin/lesson-classify.sh writes a row per finding of each BLOCK verdict."/>`}/>
      ${openCat ? html`
        <div style="margin-top:10px;padding-left:10px;border-left:2px solid var(--line);overflow-x:auto">
          <div class="section__note" style="margin-bottom:6px">${openCat.name} · newest findings</div>
          ${child()}
        </div>` : null}
      <div class="section__note" style="margin:12px 0 6px">uncovered causes (no lesson measuring or working)</div>
      ${unc.length
        ? html`<ul data-testid="lessons-uncovered" style="margin:0;padding-left:18px">${unc.map((u) => html`<li>${u.name} <span class="na">${u.id}</span> · ${u.blocks} BLOCKs</li>`)}</ul>`
        : html`<div class="na">none</div>`}
      ${(data.other_blocks || 0) > 0 ? html`<div class="section__note">other: ${data.other_blocks} BLOCKs with no category</div>` : null}
      <div class="section__note" style="margin:12px 0 6px">lessons${l.list_truncated ? ` · the newest ${lessons.length} shown` : ''}</div>
      <${SortableTable} wide columns=${lessonColumns} rows=${lessons} rowKey=${(x) => x.id} defaultSort="merged_at" defaultDir="desc"
        empty=${html`<${Empty} title="no lesson recorded" note="bin/lesson-measure.sh records each merged lesson PR or issue of bin/lesson-propose.sh."/>`}/>`;
  };

  const note = data && data.window ? `lessons · BLOCK rate per 100 reviewed PRs · since ${String(data.window.since || '').slice(0, 10)} · ${data.window.days} days` : null;
  return html`<${Section} title="LESSONS" note=${note}>${body()}<//>`;
}

// BH-7261 owns this file: the weekly PM brief (/roadmap/:project?view=brief).
// ONE request (pmBrief) and a Skeleton until it answers. A decide reloads the
// read; there is no poll. BriefBody is the pure half: it renders a payload.
import { useState, useRef, useEffect } from 'preact/hooks';
import { html, Link, useSearchParam } from '../../router.js';
import { useApi } from '../../lib/hooks.js';
import { pmBrief, pmDecideMove } from '../../lib/roadmap-api/pm-brief.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { useConfirm } from '../../ui/Modal.js';
import { laneLabel } from '../../lib/roadmap.js';

const listPath = (project) => `/roadmap/${encodeURIComponent(project)}`;
const ideaPath = (project, id) => `${listPath(project)}/idea/${encodeURIComponent(id)}`;
const briefPath = (project, week) => `${listPath(project)}?${new URLSearchParams({ view: 'brief', ...(week ? { week } : {}) })}`;
const moveAnchor = (id) => `brief-move-${id}`;
const ROW = 'display:flex;gap:6px;flex-wrap:wrap';
const ids = (list) => (Array.isArray(list) ? list.join(', ') : '');

const StatusLine = ({ text }) => (text ? html`
  <div class="banner banner--warn" role="status" data-testid="brief-status"><span>${text}</span></div>` : null);

function summaryText(brief) {
  if (brief.status === 'failed') return `The brief failed: ${brief.error || 'no reason recorded'}.`;
  if (brief.status === 'claimed') return 'The brief is being written. Reload in a few minutes.';
  return (brief.body && brief.body.summary) || 'No summary.';
}

export function BriefBody({ project, data, moveParam, busy, onDecide }) {
  const brief = data.brief;
  const b = brief.body || {};
  const stale = b.stale || [];
  const now = b.now || [];
  const moves = data.moves || [];
  const weeks = data.weeks || [];
  // A next-wave id shows its title when any other part of the brief knows it.
  const titles = new Map();
  for (const r of stale) titles.set(r.idea_id, r.title);
  for (const r of now) titles.set(r.idea_id, r.title);
  for (const m of moves) if (m.title) titles.set(m.idea_id, m.title);
  const ideaLink = (id, title) => html`<${Link} to=${ideaPath(project, id)} class="cell-name">${title || id}<//>`;

  const staleCols = [
    { key: 'title', label: 'TITLE', flex: true, cell: (r) => ideaLink(r.idea_id, r.title) },
    { key: 'lane', label: 'LANE', cell: (r) => laneLabel(r.lane) },
    { key: 'age_days', label: 'AGE', unit: 'days', align: 'right', sort: (r) => Number(r.age_days) || 0, cell: (r) => String(r.age_days) }
  ];
  const moveCols = [
    { key: 'title', label: 'IDEA', flex: true, sort: (r) => r.title || r.idea_id, cell: (r) => (r.id === moveParam
      ? html`<span id=${moveAnchor(r.id)} data-testid="brief-move-target">▶ ${ideaLink(r.idea_id, r.title)}</span>`
      : ideaLink(r.idea_id, r.title)) },
    { key: 'move', label: 'MOVE', sort: (r) => `${r.from_col} ${r.to_col}`, cell: (r) => `${laneLabel(r.from_col)} → ${laneLabel(r.to_col)}` },
    { key: 'reason', label: 'REASON', cell: (r) => r.reason || '' },
    { key: 'evidence', label: 'EVIDENCE', sort: (r) => ids(r.evidence), cell: (r) => ids(r.evidence) },
    { key: 'status', label: 'STATUS', cell: (r) => r.status },
    { key: 'actions', label: 'ACTIONS', sort: null, cell: (r) => (r.status === 'proposed' ? html`
      <span style=${ROW}>
        <button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onDecide(r, 'approve')}>APPROVE</button>
        <button type="button" class="btn btn--sm btn--danger" disabled=${busy} onClick=${() => onDecide(r, 'reject')}>REJECT</button>
      </span>` : null) }
  ];

  return html`
    <${Section} title="SUMMARY">
      <p style="white-space:pre-wrap;margin:0">${summaryText(brief)}</p>
    <//>
    <${Section} title="STALE" note=${b.stale_partial
      ? 'The backlog read was cut, so this list may miss the oldest ideas.'
      : 'ideas with no change for a long time, oldest first.'}>
      <div data-testid="brief-stale">
        <${SortableTable} wide columns=${staleCols} rows=${stale} rowKey=${(r) => r.idea_id} defaultSort="age_days" defaultDir="desc"
          empty=${html`<${Empty} title="No stale ideas."/>`}/>
      </div>
    <//>
    <${Section} title="MOVES" note="each move asks for one decision. APPROVE moves the idea; REJECT leaves it.">
      <div data-testid="brief-moves">
        <${SortableTable} wide columns=${moveCols} rows=${moves} rowKey=${(r) => r.id} defaultSort="status"
          rowClass=${(r) => (r.id === moveParam ? 'row--target' : '')}
          empty=${html`<${Empty} title="No moves proposed."/>`}/>
      </div>
    <//>
    <${Section} title="NOW" note="what the brief says to work on now. Read only.">
      ${now.length ? html`
        <ul data-testid="brief-now">
          ${now.map((r) => html`
            <li key=${r.idea_id}>${ideaLink(r.idea_id, r.title)}: ${r.reason || ''}
              ${r.evidence && r.evidence.length ? html` <span class="section__note">(${ids(r.evidence)})</span>` : null}</li>`)}
        </ul>` : html`<div data-testid="brief-now"><${Empty} title="Nothing for now."/></div>`}
    <//>
    <${Section} title="NEXT WAVE">
      ${(b.next_wave || []).length ? html`
        <ul data-testid="brief-next-wave">
          ${b.next_wave.map((id) => html`<li key=${id}>${ideaLink(id, titles.get(id))}</li>`)}
        </ul>` : html`<div data-testid="brief-next-wave"><${Empty} title="No next wave."/></div>`}
    <//>
    <${Section} title="WEEKS" note="the newest 12 briefs.">
      <ul data-testid="brief-weeks" style=${ROW + ';list-style:none;padding:0'}>
        ${weeks.map((w) => html`
          <li key=${w.id}><${Link} to=${briefPath(project, w.week)} class="btn btn--sm">${w.week} · ${w.status}<//></li>`)}
      </ul>
    <//>`;
}

function decideError(e) {
  if (e && e.status === 409) return 'Someone already decided this move.';
  return `The decision failed: ${e && e.message ? e.message : String(e)}.`;
}

export function RoadmapBriefView({ project }) {
  const week = useSearchParam('week');
  const moveParam = useSearchParam('move');
  const d = useApi(() => pmBrief(project, week), [project, week]);
  const [dialog, confirm] = useConfirm();
  const [status, setStatus] = useState(null);
  const [busy, setBusy] = useState(false);
  // The ref stops a second decision before the first re-render lands.
  const inFlight = useRef(false);
  const data = d.data;
  const brief = data && data.brief;

  useEffect(() => {
    if (!moveParam || !brief || typeof document === 'undefined') return;
    const el = document.getElementById(moveAnchor(moveParam));
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'center' });
  }, [moveParam, brief]);

  const onDecide = async (m, decision) => {
    if (inFlight.current) return;
    const approve = decision === 'approve';
    const ok = await confirm({
      title: approve ? 'Approve this move?' : 'Reject this move?',
      body: `${m.title || m.idea_id}: ${laneLabel(m.from_col)} → ${laneLabel(m.to_col)}`,
      confirmLabel: approve ? 'APPROVE' : 'REJECT',
      tone: approve ? undefined : 'danger'
    });
    if (!ok || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try {
      const res = await pmDecideMove({ project, move_id: m.id, decision });
      setStatus(res && res.applied === false ? 'The idea moved since the brief. Nothing changed.' : null);
    } catch (e) {
      setStatus(decideError(e));
    } finally {
      inFlight.current = false;
      setBusy(false);
      d.reload();
    }
  };

  const shownWeek = (data && data.week) || week || 'latest';
  const line2 = brief
    ? `${brief.status} · ${brief.sent_tg ? 'Telegram sent' : 'Telegram not sent'}`
    : data ? 'No brief yet.' : d.error ? 'The read failed.' : 'Reading the brief.';

  return html`
    <div class="page">
      <${PageHeadline} chip="Brief" line1=${`${project} · ${shownWeek}`} line2=${line2}/>
      <div><${Link} to=${listPath(project)} class="btn btn--sm">BACK TO ${project}<//></div>
      ${d.loading && !data
        ? html`<${Skeleton} rows=${4} height=${20}/>`
        : d.error && !data
          ? html`<${ErrorBox} error=${d.error} onRetry=${d.reload}/>`
          : !brief
            ? html`<${Empty} title="No brief yet" note="The weekly pm-groom lane writes one each Monday."/>`
            : html`
              <${StatusLine} text=${status}/>
              <${BriefBody} project=${project} data=${data} moveParam=${moveParam} busy=${busy} onDecide=${onDecide}/>`}
      ${dialog}
    </div>`;
}

// BH-7243.2 owns this file: the roadmap board (/roadmap/:project?view=board).
// ONE request (GET board: one D1 batch of 4 statements on the worker) and a
// four-column skeleton until it answers. Ideas and Next are the hand lanes:
// their cards drag between the two and carry a wave-pick checkbox. Now and
// Shipped are computed from the linked issues, so their cards do not drag.
// Every write reloads the board; there is no poll.
import { useState, useRef, useEffect } from 'preact/hooks';
import { html, Link } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { Section, Empty, ErrorBox } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { useConfirm } from '../../ui/Modal.js';
import { laneLabel, writeError, when } from '../../lib/roadmap.js';
import { WaveSelectBar } from './wave-select.js';

const COLUMNS = [
  { key: 'ideas', label: 'IDEAS', hand: true },
  { key: 'next', label: 'NEXT', hand: true },
  { key: 'now', label: 'NOW', hand: false },
  { key: 'shipped', label: 'SHIPPED', hand: false }
];
const MENU_LANES = ['ideas', 'next', 'discarded'];
const ISSUE_MAX = 2 ** 31 - 1;
const STATE_LABEL = { open: 'open', closed_completed: 'closed: done', closed_other: 'closed' };
const stateLabel = (s) => (s === null || s === undefined ? 'not read yet' : STATE_LABEL[s] || String(s));
const listPath = (project) => `/roadmap/${encodeURIComponent(project)}`;
const ideaPath = (project, id) => `${listPath(project)}/idea/${encodeURIComponent(id)}`;
const LABEL = 'font-size:var(--fs-xs);color:var(--soft)';

const StatusLine = ({ text }) => (text ? html`
  <div class="banner banner--warn" role="status" data-testid="roadmap-status"><span>${text}</span></div>` : null);

const ColumnHead = ({ label, count }) => html`
  <div class="kb__head"><span class="kb__title">${label}</span>${' '}<span class="kb__count">${count}</span></div>`;

function BoardSkeleton() {
  return html`
    <div class="kb roadmap-board" data-testid="roadmap-board-skeleton" aria-busy="true">
      ${COLUMNS.map((c) => html`
        <div class="kb__col roadmap-col" key=${c.key}>
          <${ColumnHead} label=${c.label} count="…"/>
          <span class="roadmap-col__empty">Loading…</span>
        </div>`)}
    </div>`;
}

// The keyboard MOVE menu of one card. Escape closes it and focus goes back to
// the MOVE button.
function MoveMenu({ card, computed, open, busy, onToggle, onClose, onPick }) {
  const btn = useRef(null);
  const menu = useRef(null);
  useEffect(() => {
    if (open && menu.current) {
      const first = menu.current.querySelector('button');
      if (first) first.focus();
    }
  }, [open]);
  const close = () => { onClose(); if (btn.current) btn.current.focus(); };
  const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } };
  return html`
    <span class="roadmap-move">
      <button ref=${btn} type="button" class="btn btn--sm" aria-haspopup="menu" aria-expanded=${open ? 'true' : 'false'}
        disabled=${busy} onClick=${onToggle}>MOVE</button>
      ${open ? html`
        <div ref=${menu} class="roadmap-menu" role="menu" aria-label=${`Move ${card.title}`} onKeyDown=${onKey}>
          ${computed ? html`<span class="roadmap-menu__note">Sets the hand lane. The card stays here while its links say so.</span>` : null}
          ${MENU_LANES.filter((l) => l !== card.lane).map((l) => html`
            <button key=${l} type="button" role="menuitem" class="btn btn--sm" onClick=${() => { close(); onPick(l); }}>
              ${l === 'discarded' ? 'Discard' : laneLabel(l)}</button>`)}
        </div>` : null}
    </span>`;
}

// LINK ISSUE: one number, posted once.
function LinkForm({ project, card, onDone }) {
  const [v, setV] = useState('');
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);
  const submit = async (e) => {
    e.preventDefault();
    if (inFlight.current) return;
    const s = v.trim();
    const n = /^\d{1,10}$/.test(s) ? Number(s) : NaN;
    if (!Number.isInteger(n) || n < 1 || n > ISSUE_MAX) { setErr('Type an issue number, like 42.'); return; }
    inFlight.current = true;
    setBusy(true);
    setErr(null);
    try {
      await api.roadmapLink({ idea_id: card.id, project, issue: n });
      setV('');
      onDone(null);
    } catch (x) {
      setErr(x && x.status === 409 && x.body && x.body.error ? `The link was refused: ${x.body.error}.` : `The link failed: ${x && x.message ? x.message : String(x)}.`);
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };
  return html`
    <form class="roadmap-link" data-testid="roadmap-link-form" onSubmit=${submit}>
      <input class="knob__input" name="issue" type="text" inputmode="numeric" aria-label=${`Issue number for ${card.title}`}
        placeholder="#" value=${v} onInput=${(e) => setV(e.target.value)}/>
      <button class="btn btn--sm" type="submit" disabled=${busy}>${busy ? 'LINKING…' : 'LINK ISSUE'}</button>
      ${err ? html`<span class="section__note" role="alert">${err}</span>` : null}
    </form>`;
}

function BoardCard({ project, card, column, computed, picked, busy, menuOpen, setMenu, onDragStart, onPick, onMove, onUnlink, onDone }) {
  const hand = !computed;
  return html`
    <div class="card roadmap-card" data-testid="roadmap-card" data-id=${card.id}
      draggable=${hand ? 'true' : undefined} onDragStart=${hand ? (e) => onDragStart(e, card, column) : undefined}>
      <div class="roadmap-card__head">
        ${hand ? html`<span class="roadmap-card__drag" data-testid="roadmap-drag" title="Drag to Ideas or Next" aria-hidden="true">⠿</span>` : null}
        ${hand ? html`<input type="checkbox" name="wave-pick" aria-label=${`Pick ${card.title} for a wave`} checked=${picked}
          onChange=${(e) => onPick(card.id, e.target.checked)}/>` : null}
        <${Link} to=${ideaPath(project, card.id)} class="cell-name">${card.title}<//>
      </div>
      ${computed ? html`<span class="roadmap-card__note">Computed from linked tickets</span>` : null}
      ${card.links.length ? html`
        <ul class="roadmap-links">
          ${card.links.map((l) => html`
            <li key=${`${l.repo}#${l.issue}`}>
              <a href=${l.url} target="_blank" rel="noopener noreferrer">#${l.issue}</a>${' '}
              <span class="tag tag--sm">${stateLabel(l.issue_state)}</span>
              ${l.ticket ? html`${' '}<${Link} to=${`/t/${encodeURIComponent(l.ticket)}`}>${l.ticket}<//>` : null}
              ${l.wave_id === null ? html`${' '}<button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onUnlink(card, l)}>REMOVE</button>` : null}
            </li>`)}
        </ul>` : null}
      <div class="roadmap-card__actions">
        <${MoveMenu} card=${card} computed=${computed} open=${menuOpen} busy=${busy}
          onToggle=${() => setMenu(menuOpen ? null : card.id)} onClose=${() => setMenu(null)} onPick=${(to) => onMove(card, to)}/>
        <${LinkForm} project=${project} card=${card} onDone=${onDone}/>
      </div>
    </div>`;
}

function AddDecisionForm({ project, onAdded }) {
  const blank = { kind: 'log', title: '', body: '' };
  const [f, setF] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const inFlight = useRef(false);
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async (e) => {
    e.preventDefault();
    if (inFlight.current) return;
    if (!f.title.trim()) { setErr('A title is required.'); return; }
    inFlight.current = true;
    setBusy(true);
    setErr(null);
    try {
      await api.roadmapAddDecision({ project, kind: f.kind, title: f.title, body: f.body });
      setF(blank);
      onAdded();
    } catch (x) {
      setErr(x && x.status === 400 && x.body && x.body.error ? `The add was refused: ${x.body.error}.` : `The add failed: ${x && x.message ? x.message : String(x)}.`);
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };
  return html`
    <form class="roadmap-form roadmap-decision-form" data-testid="roadmap-decision-add" onSubmit=${submit}>
      <label><span style=${LABEL}>KIND</span>
        <select class="knob__input" name="kind" value=${f.kind} onChange=${set('kind')}>
          <option value="log">decision (log)</option>
          <option value="open">open question</option>
        </select></label>
      <label class="roadmap-decision-form__title"><span style=${LABEL}>TITLE</span>
        <input class="knob__input" name="title" type="text" maxlength="200" value=${f.title} onInput=${set('title')}/></label>
      <label class="roadmap-decision-form__body"><span style=${LABEL}>DETAIL</span>
        <textarea class="knob__input" name="body" rows="2" value=${f.body} onInput=${set('body')}></textarea></label>
      <button class="btn btn--primary" type="submit" disabled=${busy}>${busy ? 'ADDING…' : 'ADD'}</button>
      ${err ? html`<span class="section__note" role="alert">${err}</span>` : null}
    </form>`;
}

export function RoadmapBoardView({ project }) {
  const b = useApi(() => api.roadmapBoard(project), [project]);
  const [dialog, confirm] = useConfirm();
  const [status, setStatus] = useState(null);
  const [busy, setBusy] = useState(false);
  const [menu, setMenu] = useState(null);
  const [picked, setPicked] = useState([]);
  const inFlight = useRef(false);
  const drag = useRef(null);
  const decideTo = useRef('decided');

  // One write at a time; every write reloads the board.
  const write = async (fn, onError) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try {
      await fn();
      setStatus(null);
    } catch (e) {
      setStatus(onError(e));
    } finally {
      inFlight.current = false;
      setBusy(false);
      b.reload();
    }
  };
  const moveError = (e) => (e && e.status === 409 ? 'Someone changed this idea. Reloaded.' : writeError(e, 'move'));
  const move = (card, to) => write(() => api.roadmapMoveIdea({ id: card.id, project, to_lane: to, expected_version: card.version }), moveError);
  const onMove = async (card, to) => {
    if (to === 'discarded') {
      const ok = await confirm({ title: 'Discard this idea?', body: card.title, confirmLabel: 'DISCARD', tone: 'danger' });
      if (!ok) return;
    }
    move(card, to);
  };
  const onUnlink = async (card, l) => {
    const ok = await confirm({ title: `Remove the link to #${l.issue}?`, body: card.title, confirmLabel: 'REMOVE', tone: 'danger' });
    if (ok) write(() => api.roadmapUnlink({ idea_id: card.id, project, issue: l.issue }), (e) => writeError(e, 'remove'));
  };
  const onDecide = async (d) => {
    decideTo.current = 'decided';
    const ok = await confirm({
      title: 'Decide this question?', confirmLabel: 'CONFIRM',
      body: () => html`
        <p style="margin:0 0 8px">${d.title}</p>
        <label><span style=${LABEL}>OUTCOME</span>
          <select class="knob__input" name="decide-status" onChange=${(e) => { decideTo.current = e.target.value; }}>
            <option value="decided">Decided</option>
            <option value="dropped">Dropped</option>
          </select></label>`
    });
    if (!ok) return;
    write(() => api.roadmapDecide({ id: d.id, project, status: decideTo.current, expected_status: 'open' }),
      (e) => (e && e.status === 409 && e.body && e.body.decision
        ? `Someone decided this first. It is now ${e.body.decision.status}.`
        : `The decide failed: ${e && e.message ? e.message : String(e)}.`));
  };

  const onDragStart = (e, card, column) => {
    drag.current = { card, column };
    if (e && e.dataTransfer) {
      try { e.dataTransfer.setData('text/plain', card.id); e.dataTransfer.effectAllowed = 'move'; } catch { /* a browser without dataTransfer data */ }
    }
  };
  const onDragOver = (key) => (e) => { if (drag.current && drag.current.column !== key) e.preventDefault(); };
  const onDrop = (key) => (e) => {
    if (e && e.preventDefault) e.preventDefault();
    const d = drag.current;
    drag.current = null;
    if (!d || d.column === key) return;
    move(d.card, key);
  };
  const onPick = (id, on) => setPicked((s) => (on ? (s.includes(id) ? s : [...s, id]) : s.filter((x) => x !== id)));

  const data = b.data;
  const cols = (data && data.columns) || { ideas: [], next: [], now: [], shipped: [] };
  const shown = COLUMNS.reduce((n, c) => n + (cols[c.key] || []).length, 0);
  const handIds = new Set([...(cols.ideas || []), ...(cols.next || [])].map((c) => c.id));
  const selected = picked.filter((id) => handIds.has(id));
  const tr = (data && data.truncated) || {};
  const truncated = tr.ideas || tr.links || tr.running || tr.decisions;
  const decisions = (data && data.decisions) || [];
  const open = (data && data.open_decisions) || [];

  const decisionColumns = [
    { key: 'date', label: 'DATE', sort: (r) => r.decided_at || r.created_at, cell: (r) => when(r.decided_at || r.created_at) },
    { key: 'title', label: 'DECISION', flex: true, cell: (r) => html`
      <span class="cell-name">${r.title}</span>${r.body ? html`<span class="roadmap-decision__body">${r.body}</span>` : null}` },
    { key: 'by', label: 'BY', sort: (r) => r.decided_by || r.created_by, cell: (r) => r.decided_by || r.created_by || '' }
  ];
  const openColumns = [
    { key: 'title', label: 'TOPIC', cell: (r) => html`<span class="cell-name">${r.title}</span>` },
    { key: 'body', label: 'QUESTION', flex: true, cell: (r) => r.body || '' },
    { key: 'created_at', label: 'OPENED', cell: (r) => when(r.created_at) },
    { key: 'created_by', label: 'BY', cell: (r) => r.created_by || '' },
    { key: 'action', label: 'ACTION', sort: null, cell: (r) => html`
      <button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onDecide(r)}>DECIDE</button>` }
  ];

  return html`
    <div class="page">
      <${PageHeadline} chip="Roadmap" line1=${project}
        line2=${data ? `${shown} ${shown === 1 ? 'card' : 'cards'} on the board.` : b.error ? 'The read failed.' : 'Reading the board.'}/>
      <div style="display:flex;gap:6px;flex-wrap:wrap">
        <${Link} to="/roadmap" class="btn btn--sm">ALL ROADMAPS<//>
        <${Link} to=${`${listPath(project)}?view=list`} class="btn btn--sm">LIST VIEW<//>
      </div>
      <${StatusLine} text=${status}/>
      <${Section} title="BOARD" note=${truncated
        ? `Showing the newest ${shown}. Older items are not on this board.`
        : 'Drag a card between Ideas and Next. Now and Shipped follow the linked issues.'}>
        ${b.loading && !data
          ? html`<${BoardSkeleton}/>`
          : b.error && !data
            ? html`<div data-testid="roadmap-board-error"><${ErrorBox} error=${b.error} onRetry=${b.reload}/></div>`
            : html`
              ${shown === 0 ? html`<${Empty} title="No ideas on this board yet." note="Add the first one in the list view."/>` : null}
              <div data-testid="roadmap-wave-select" data-selected=${selected.join(',')}>
                <${WaveSelectBar} project=${project} selected=${selected}/>
              </div>
              <div class="kb roadmap-board" data-testid="roadmap-board">
                ${COLUMNS.map((c) => html`
                  <div class="kb__col roadmap-col" key=${c.key} data-testid=${`roadmap-col-${c.key}`}
                    onDragOver=${c.hand ? onDragOver(c.key) : undefined} onDrop=${c.hand ? onDrop(c.key) : undefined}>
                    <${ColumnHead} label=${c.label} count=${(cols[c.key] || []).length}/>
                    ${(cols[c.key] || []).map((card) => html`
                      <${BoardCard} key=${card.id} project=${project} card=${card} column=${c.key} computed=${!c.hand}
                        picked=${selected.includes(card.id)} busy=${busy} menuOpen=${menu === card.id} setMenu=${setMenu}
                        onDragStart=${onDragStart} onPick=${onPick} onMove=${onMove} onUnlink=${onUnlink}
                        onDone=${() => b.reload()}/>`)}
                    ${(cols[c.key] || []).length === 0 ? html`<span class="roadmap-col__empty">—</span>` : null}
                  </div>`)}
              </div>`}
      <//>
      <${Section} title="DECISIONS" note="the decisions log, newest first. Click a header to sort.">
        <${AddDecisionForm} project=${project} onAdded=${b.reload}/>
        ${data ? html`<div data-testid="roadmap-decisions">
          <${SortableTable} wide columns=${decisionColumns} rows=${decisions} rowKey=${(r) => r.id} defaultSort="date" defaultDir="desc"
            empty=${html`<${Empty} title="No decisions yet."/>`}/>
        </div>` : null}
      <//>
      <${Section} title="OPEN DECISIONS" note="questions still to decide. DECIDE records the outcome.">
        ${data ? html`<div data-testid="roadmap-open-decisions">
          <${SortableTable} wide columns=${openColumns} rows=${open} rowKey=${(r) => r.id} defaultSort="created_at" defaultDir="desc"
            empty=${html`<${Empty} title="No open questions."/>`}/>
        </div>` : null}
      <//>
      ${dialog}
    </div>`;
}

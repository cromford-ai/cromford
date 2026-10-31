// BH-7243.1 owns this file: the roadmap index (/roadmap), a project's idea
// list (/roadmap/:project, the default view) and the idea page
// (/roadmap/:project/idea/:id). Each screen makes ONE request (one D1 batch of
// 2 statements on the worker) and shows a Skeleton until it answers. Writes
// reload the read; there is no poll. The pure half is lib/roadmap.js.
import { useState, useRef } from 'preact/hooks';
import { html, Link, navigate, useSearchParam, currentSearch } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { PageHeadline } from '../../ui/line.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { useConfirm } from '../../ui/Modal.js';
import {
  IDEA_LANES, IDEA_SOURCES, laneLabel, laneParam, newIdemKey, rowActions, summaryRows,
  writeError, editChanges, eventLine, when
} from '../../lib/roadmap.js';
import { pmRuns } from '../../lib/roadmap-api/pm-flesh.js';
import { FleshSection } from './flesh-section.js';

const listPath = (project) => `/roadmap/${encodeURIComponent(project)}`;
const ideaPath = (project, id) => `${listPath(project)}/idea/${encodeURIComponent(id)}`;

// The form row: fields wrap, and under ~600 px each one takes the full width.
const FORM = 'display:flex;flex-wrap:wrap;gap:8px;align-items:flex-end';
const field = (basis) => `display:flex;flex-direction:column;gap:4px;flex:1 1 ${basis};min-width:0`;
const LABEL = 'font-size:var(--fs-xs);color:var(--soft)';

const StatusLine = ({ text }) => (text ? html`
  <div class="banner banner--warn" role="status" data-testid="roadmap-status"><span>${text}</span></div>` : null);

// ── /roadmap ────────────────────────────────────────────────────────────────
export function RoadmapIndexView() {
  const s = useApi(() => api.roadmapSummary(), []);
  const rows = s.data ? summaryRows(s.data.projects) : [];
  const num = (key, label) => ({ key, label, align: 'right', cell: (r) => String(r[key]) });
  const columns = [
    { key: 'project', label: 'PROJECT', cell: (r) => html`<${Link} to=${listPath(r.project)} class="cell-name">${r.project}<//>` },
    num('ideas', 'IDEAS'), num('next', 'NEXT'), num('discarded', 'DISCARDED'), num('total', 'TOTAL')
  ];
  return html`
    <div class="page">
      <${PageHeadline} chip="Roadmap" line1="Roadmaps"
        line2=${s.data ? `${rows.length} ${rows.length === 1 ? 'project' : 'projects'}.` : s.error ? 'The read failed.' : 'Reading the projects.'}/>
      <${Section} title="PROJECTS" note="one row per project. Open a project to add and move its ideas.">
        ${s.loading && !s.data
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : s.error && !s.data
            ? html`<${ErrorBox} error=${s.error} onRetry=${s.reload}/>`
            : html`<div data-testid="roadmap-summary">
                <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.project} defaultSort="project"
                  empty=${html`<${Empty} title="No projects yet" note="A project appears here once it is a row of the projects table."/>`}/>
              </div>`}
      <//>
    </div>`;
}

// ── /roadmap/:project ───────────────────────────────────────────────────────
function AddIdeaForm({ project, onAdded }) {
  const blank = { title: '', note: '', source: 'operator', link: '' };
  const [f, setF] = useState(blank);
  // One idem_key per form open: a retried or double-clicked add is a replay
  // on the worker, never a second idea. A new key only after an add lands.
  const [idemKey, setIdemKey] = useState(newIdemKey);
  // The ref stops a second submit before the first re-render lands.
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.value }));

  const submit = async (e) => {
    e.preventDefault();
    if (inFlight.current) return;
    if (!f.title.trim()) { setError('A title is required.'); return; }
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      await api.roadmapAddIdea({ project, title: f.title, note: f.note, source: f.source, link: f.link, idem_key: idemKey });
      setF(blank);
      setIdemKey(newIdemKey());
      onAdded();
    } catch (err) {
      setError(err && err.status === 400 && err.body && err.body.error
        ? `The add was refused: ${err.body.error}.`
        : `The add failed: ${err && err.message ? err.message : String(err)}.`);
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return html`
    <form class="roadmap-form" data-testid="roadmap-add" style=${FORM} onSubmit=${submit}>
      <label style=${field('280px')}><span style=${LABEL}>TITLE</span>
        <input class="knob__input" name="title" type="text" maxlength="200" required value=${f.title} onInput=${set('title')}
          placeholder="One line. Press Enter to add."/></label>
      <label style=${field('160px')}><span style=${LABEL}>SOURCE</span>
        <select class="knob__input" name="source" value=${f.source} onChange=${set('source')}>
          ${IDEA_SOURCES.map((s) => html`<option key=${s} value=${s}>${s}</option>`)}
        </select></label>
      <label style=${field('220px')}><span style=${LABEL}>LINK</span>
        <input class="knob__input" name="link" type="url" value=${f.link} onInput=${set('link')} placeholder="https://"/></label>
      <label style=${field('100%')}><span style=${LABEL}>NOTE</span>
        <textarea class="knob__input" name="note" rows="2" value=${f.note} onInput=${set('note')}></textarea></label>
      <button class="btn btn--primary" type="submit" disabled=${busy}>${busy ? 'ADDING…' : 'ADD IDEA'}</button>
      ${error ? html`<span class="section__note" role="alert" style="flex:1 1 100%">${error}</span>` : null}
    </form>`;
}

export function RoadmapListView({ project }) {
  const lane = laneParam(useSearchParam('lane'));
  const list = useApi(() => api.roadmapIdeas(project, lane), [project, lane]);
  const [dialog, confirm] = useConfirm();
  const [status, setStatus] = useState(null);
  const [moving, setMoving] = useState(null);

  const setLane = (l) => {
    const q = new URLSearchParams(currentSearch());
    if (l) q.set('lane', l); else q.delete('lane');
    const qs = q.toString();
    navigate(`${listPath(project)}${qs ? `?${qs}` : ''}`);
  };

  const onAction = async (idea, action) => {
    if (moving) return;
    const ok = await confirm({ title: action.title, body: idea.title, confirmLabel: action.label, tone: action.tone });
    if (!ok) return;
    setMoving(idea.id);
    try {
      await api.roadmapMoveIdea({ id: idea.id, project, to_lane: action.to, expected_version: idea.version });
      setStatus(null);
    } catch (e) {
      setStatus(writeError(e, 'move'));
    } finally {
      setMoving(null);
      list.reload();
    }
  };

  const d = list.data;
  const ideas = (d && d.ideas) || [];
  const counts = (d && d.counts) || null;
  const total = counts ? IDEA_LANES.reduce((n, l) => n + (counts[l] || 0), 0) : null;
  const chip = (label, l) => html`
    <button type="button" class=${lane === l ? 'tab tab--on' : 'tab'} aria-pressed=${lane === l ? 'true' : 'false'}
      onClick=${() => setLane(l)}>${counts ? `${label} ${l ? counts[l] || 0 : total}` : label}</button>`;
  const columns = [
    { key: 'title', label: 'TITLE', flex: true, cell: (r) => html`<${Link} to=${ideaPath(project, r.id)} class="cell-name">${r.title}<//>` },
    { key: 'source', label: 'SOURCE', cell: (r) => r.source },
    { key: 'lane', label: 'LANE', cell: (r) => laneLabel(r.lane) },
    { key: 'created_at', label: 'ADDED', cell: (r) => when(r.created_at) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => when(r.updated_at) },
    { key: 'actions', label: 'ACTIONS', sort: null, cell: (r) => html`
      <span style="display:flex;gap:6px;flex-wrap:wrap">
        ${rowActions(r).map((a) => html`
          <button key=${a.label} type="button" class=${a.tone === 'danger' ? 'btn btn--sm btn--danger' : 'btn btn--sm'}
            disabled=${moving !== null} onClick=${() => onAction(r, a)}>${a.label}</button>`)}
      </span>` }
  ];

  return html`
    <div class="page">
      <${PageHeadline} chip="Roadmap" line1=${project}
        line2=${d ? `${total} ${total === 1 ? 'idea' : 'ideas'}.` : list.error ? 'The read failed.' : 'Reading the ideas.'}/>
      <div style="display:flex;gap:6px;flex-wrap:wrap">
        <${Link} to="/roadmap" class="btn btn--sm">ALL ROADMAPS<//>
        <${Link} to=${`${listPath(project)}?view=board`} class="btn btn--sm">BOARD<//>
      </div>
      <${Section} title="ADD IDEA" note="Enter in the title adds the idea. It lands in Ideas.">
        <${AddIdeaForm} project=${project} onAdded=${list.reload}/>
      <//>
      <${StatusLine} text=${status}/>
      <${Section} title="IDEAS" note=${d && d.truncated ? `Showing the newest ${ideas.length}. Filter by lane to see the rest.` : 'newest change first. Click a title for its page and history.'}>
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ALL', null)}
          ${IDEA_LANES.map((l) => chip(laneLabel(l).toUpperCase(), l))}
        </div>
        ${list.loading && !d
          ? html`<${Skeleton} rows=${6} height=${20}/>`
          : list.error && !d
            ? html`<${ErrorBox} error=${list.error} onRetry=${list.reload}/>`
            : html`<div data-testid="roadmap-ideas">
                <${SortableTable} wide columns=${columns} rows=${ideas} rowKey=${(r) => r.id} defaultSort="updated_at" defaultDir="desc"
                  empty=${html`<${Empty} title=${lane ? `No ideas in ${laneLabel(lane)}.` : 'No ideas yet. Add the first one above.'}/>`}/>
              </div>`}
      <//>
      ${dialog}
    </div>`;
}

// ── /roadmap/:project/idea/:id ──────────────────────────────────────────────
function EditIdeaForm({ project, idea, onSaved }) {
  const [f, setF] = useState({ title: idea.title || '', note: idea.note || '', link: idea.link || '', source: idea.source });
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.value }));
  // An imported idea keeps `import` as a choice, so an edit never has to change it.
  const sources = IDEA_SOURCES.includes(idea.source) ? IDEA_SOURCES : [...IDEA_SOURCES, idea.source];

  const submit = async (e) => {
    e.preventDefault();
    if (inFlight.current) return;
    const changes = editChanges(idea, f);
    if (!Object.keys(changes).length) { setMsg('Nothing changed.'); return; }
    inFlight.current = true;
    setBusy(true);
    try {
      await api.roadmapEditIdea({ id: idea.id, project, ...changes, expected_version: idea.version });
      onSaved(null);
    } catch (err) {
      setMsg(null);
      onSaved(writeError(err, 'edit'));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return html`
    <form class="roadmap-form" data-testid="roadmap-edit" style=${FORM} onSubmit=${submit}>
      <label style=${field('280px')}><span style=${LABEL}>TITLE</span>
        <input class="knob__input" name="title" type="text" maxlength="200" value=${f.title} onInput=${set('title')}/></label>
      <label style=${field('160px')}><span style=${LABEL}>SOURCE</span>
        <select class="knob__input" name="source" value=${f.source} onChange=${set('source')}>
          ${sources.map((s) => html`<option key=${s} value=${s}>${s}</option>`)}
        </select></label>
      <label style=${field('220px')}><span style=${LABEL}>LINK</span>
        <input class="knob__input" name="link" type="url" value=${f.link} onInput=${set('link')}/></label>
      <label style=${field('100%')}><span style=${LABEL}>NOTE</span>
        <textarea class="knob__input" name="note" rows="4" value=${f.note} onInput=${set('note')}></textarea></label>
      <button class="btn btn--primary" type="submit" disabled=${busy}>${busy ? 'SAVING…' : 'SAVE'}</button>
      ${msg ? html`<span class="section__note" role="alert" style="flex:1 1 100%">${msg}</span>` : null}
    </form>`;
}

export function RoadmapIdeaView({ project, id }) {
  const d = useApi(() => api.roadmapIdea(project, id), [project, id]);
  // BH-7260: the PM flesh-out runs, read at mount in parallel with the idea.
  const f = useApi(() => pmRuns(project, id), [project, id]);
  const [status, setStatus] = useState(null);
  const idea = d.data && d.data.idea;
  const events = (d.data && d.data.events) || [];
  const missing = d.error && d.error.status === 404;
  const onSaved = (err) => { setStatus(err); d.reload(); };

  const fact = (label, value) => html`
    <div class="kv" style="grid-template-columns:minmax(90px,140px) minmax(0,1fr)">
      <span class="kv__label">${label}</span><span style="overflow-wrap:anywhere">${value === null || value === undefined || value === '' ? '—' : value}</span>
    </div>`;
  const columns = [
    { key: 'at', label: 'WHEN', cell: (r) => when(r.at) },
    { key: 'what', label: 'WHAT', flex: true, sort: (r) => eventLine(r), cell: (r) => eventLine(r) },
    { key: 'actor', label: 'BY', cell: (r) => r.actor },
    { key: 'reason', label: 'REASON', cell: (r) => r.reason || '' }
  ];

  return html`
    <div class="page">
      <${PageHeadline} chip="Idea" line1=${idea ? idea.title : id}
        line2=${idea ? `${laneLabel(idea.lane)} · version ${idea.version}` : missing ? 'Not found.' : d.error ? 'The read failed.' : 'Reading the idea.'}/>
      <div><${Link} to=${listPath(project)} class="btn btn--sm">BACK TO ${project}<//></div>
      ${d.loading && !d.data
        ? html`<${Skeleton} rows=${5} height=${20}/>`
        : missing
          ? html`<${Empty} title=${`This idea does not exist in ${project}.`} note="It may belong to another project, or the retention job archived it."/>`
          : d.error && !d.data
            ? html`<${ErrorBox} error=${d.error} onRetry=${d.reload}/>`
            : html`
              <${StatusLine} text=${status}/>
              <${Section} title="IDEA">
                ${fact('TITLE', idea.title)}
                ${fact('LANE', laneLabel(idea.lane))}
                ${fact('SOURCE', idea.source)}
                ${fact('LINK', idea.link ? html`<a href=${idea.link} target="_blank" rel="noopener noreferrer">${idea.link}</a>` : null)}
                ${fact('NOTE', idea.note ? html`<span style="white-space:pre-wrap">${idea.note}</span>` : null)}
                ${fact('VERSION', String(idea.version))}
                ${fact('CREATED', `${when(idea.created_at)} by ${idea.created_by}`)}
                ${fact('UPDATED', when(idea.updated_at))}
                ${fact('DISCARDED', when(idea.discarded_at))}
              <//>
              <${Section} title="EDIT" note="SAVE sends only the fields you changed.">
                <${EditIdeaForm} key=${idea.version} project=${project} idea=${idea} onSaved=${onSaved}/>
              <//>
              <${Section} title="HISTORY" note="the newest 50 changes, newest first.">
                <div data-testid="roadmap-history">
                  <${SortableTable} wide columns=${columns} rows=${events} rowKey=${(r) => r.id} defaultSort="at" defaultDir="desc"
                    empty=${html`<${Empty} title="No history yet."/>`}/>
                </div>
              <//>`}
      ${missing ? null : html`<${FleshSection} project=${project} id=${id} f=${f}/>`}
    </div>`;
}

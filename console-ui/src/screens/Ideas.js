import { useState } from 'preact/hooks';
import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { minutesSince, fmtNum } from '../lib/format.js';
import { PRODUCT_COCKPIT_URL } from '../lib/deployment.js';
import {
  statusLabel, statusTone, statusRank, awaitingDecision,
  dusLabel, dusRank, summarise, facet, ideaPath,
  mockupLink, mockupShots, mockupRank, mockupAnchor, withMockups, mockupCountText, scoreExplain
} from '../lib/ideas.js';

// IDEAS is the port of the old console's /product view: the weekly generative
// stage's proposals, from the ones nobody has looked at yet to the ones that
// shipped. The rows come from the console worker's own D1 through
// functions/api/ideas/, so this is the same data the cockpit renders — read
// only. The approve / kill / revise gate still lives in the old console.

const REFRESH_MS = 60000;

const TONE_CLASS = { warn: 'pill pill--warn', dead: 'pill pill--dead', ok: 'pill', muted: 'pill pill--muted' };

// What SCORE and BUCKET mean, on the page rather than in a tooltip. The formula
// is bin/run-product.sh's, the ranges the ideate prompt's, the bucket order
// the synth prompt's. The idea page renders the same legend.
export const IDEA_LEGEND = [
  { term: 'SCORE', text: 'impact (1 to 10) times confidence (1 to 10) divided by effort in AI build sessions, rounded to one decimal. Higher is better and there is no fixed top' },
  { term: 'BUCKET', text: 'DERISK: something that can hurt the business if left. UNCLOG: removes a bottleneck. SCALE: grows what already works. Picked in that order' }
];

// "Show me only the ones with a mockup" is a habit, not a view somebody sends,
// so it is remembered per viewer rather than put in the URL (project and status
// still ride the URL). Every access is guarded: a private window, blocked site
// data or a thumbnail capture must render the screen correctly with nothing
// stored, and "show everything" is what it falls back to. Same convention as
// the kanban view toggle and the chat screen's read state.
const MOCKUPS_KEY = 'mc.ideas.mockups-only.v1';
function loadMockupsOnly() {
  try { return window.localStorage.getItem(MOCKUPS_KEY) === '1'; } catch { return false; }
}
function saveMockupsOnly(on) {
  try { window.localStorage.setItem(MOCKUPS_KEY, on ? '1' : '0'); } catch { /* not worth surfacing */ }
}

// The mockup cell. A posted proposal opens the interactive mockup on the
// client's board; anything the drafting stage shot opens the idea page at its
// screenshots. A row with neither says which kind of empty it is instead of
// leaving a cell nobody can act on.
export function MockupCell({ row }) {
  const link = mockupLink(row);
  const shots = mockupShots(row);
  if (!link && !shots) {
    return html`<span class="na"
      title="No mockup on file. The drafting stage is what renders one, so a candidate that never got past scoring has none, and that is the expected shape rather than a failed upload.">—</span>`;
  }
  return html`
    <span style="display:inline-flex;gap:4px;white-space:nowrap">
      ${link ? html`
        <a class="tag tag--green" href=${link} target="_blank" rel="noopener noreferrer"
          title="the interactive mockup on the client's board (their sign-in required)">OPEN</a>` : null}
      ${shots ? html`
        <${Link} to=${mockupAnchor(row)} class="tag tag--green"
          title="the mockup as the drafting stage shot it, served from the console's own asset store">
          ${fmtNum(shots)} SHOT${shots === 1 ? '' : 'S'}<//>` : null}
    </span>`;
}

// The PROPOSALS table and what its SCORE and BUCKET mean. Nothing here reads
// the screen's state, so a render test can drive it with rows alone.
export function ProposalsTable({ rows, empty }) {
  const columns = [
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    {
      // The one column carrying a sentence: it takes the width the others leave
      // over (`flex` + `wide` on the table below), so a proposal title reads as
      // far as the row allows instead of stopping at a fixed character cap.
      key: 'title', label: 'IDEA', sort: (r) => r.title, flex: true,
      cell: (r) => html`
        <${Link} to=${ideaPath(r)} class="cell-name" title=${r.summary || r.title}>
          <span class="cell-wrap" style="color:inherit">${r.title}</span>
        <//>`
    },
    {
      key: 'department', label: 'DEPT', sort: (r) => r.department,
      cell: (r) => (r.department ? html`<span class="tag">${r.department}</span>` : html`<span class="na">—</span>`)
    },
    {
      key: 'dus', label: 'BUCKET', sort: (r) => dusRank(r.dus),
      cell: (r) => (dusLabel(r.dus)
        ? html`<span class="tag" title=${r.dus_why || ''}>${dusLabel(r.dus)}</span>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'score', label: 'SCORE', sort: (r) => r.score, align: 'right',
      cell: (r) => (r.score === null || r.score === undefined
        ? html`<span class="na">—</span>`
        : html`<span class="num">${r.score}${scoreExplain(r)
          ? html`<span style="display:block;font-size:var(--fs-2xs);color:var(--faint)">${scoreExplain(r)}</span>`
          : null}</span>`)
    },
    {
      key: 'status', label: 'STATUS', sort: (r) => statusRank(r.status),
      cell: (r) => html`<span class=${TONE_CLASS[statusTone(r.status)]}>${statusLabel(r.status)}</span>`
    },
    {
      // Sorting brings the ones you can look at to the top: a live board link
      // first, then the shots on file, and no mockup sinks in both directions.
      key: 'mockup', label: 'MOCKUP', sort: mockupRank,
      cell: (r) => html`<${MockupCell} row=${r}/>`
    },
    {
      // The mockup has its own column now, so this one is the rest of what the
      // drafting stage left behind rather than a second, unclickable shot count.
      key: 'drafted', label: 'DRAFTED', sort: (r) => (r.has_prd ? 2 : 0) + (Number(r.chat_turns) > 0 ? 1 : 0),
      cell: (r) => html`
        <span style="display:inline-flex;gap:4px;white-space:nowrap">
          ${r.has_prd ? html`<span class="tag">PRD</span>` : null}
          ${Number(r.chat_turns) > 0 ? html`<span class="tag">${r.chat_turns} CHAT</span>` : null}
          ${!r.has_prd && !Number(r.chat_turns) ? html`<span class="na">—</span>` : null}
        </span>`
    },
    {
      key: 'ticket_key', label: 'TICKET', sort: (r) => r.ticket_key,
      cell: (r) => (r.ticket_key
        ? html`<${Link} to=${ideaPath(r)} class="cell-name">${r.ticket_key}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'updated_at', label: 'UPDATED', sort: (r) => minutesSince(r.updated_at), align: 'right',
      // The product stage runs weekly, so a day-old row is normal. A week of
      // silence on a proposal is the point where it is worth a colour.
      cell: (r) => html`<span title=${r.updated_at}><${Age} min=${minutesSince(r.updated_at)} warnAt=${10080}/></span>`
    }
  ];

  return html`
    <${SortableTable} columns=${columns} rows=${rows} wide
      rowKey=${(r) => r.pkey}
      rowClass=${(r) => (awaitingDecision(r) ? 'row--warn' : '')}
      defaultSort="updated_at" defaultDir="desc"
      empty=${empty} />
    <${Legend} items=${IDEA_LEGEND}/>`;
}

// The old console's product cockpit, in a new tab. Its address is a deployment
// default (../lib/deployment.js, BH-4080).
export function CockpitLink() {
  return html`<a href=${PRODUCT_COCKPIT_URL} target="_blank" rel="noopener noreferrer">product cockpit</a>`;
}

export function IdeasScreen() {
  // Filters ride the URL, so a link to "everything awaiting a decision on
  // project-3" is a link somebody can send.
  const project = useSearchParam('project');
  const status = useSearchParam('status');
  const [mockupsOnly, setMockupsOnlyState] = useState(loadMockupsOnly);
  const setMockupsOnly = (on) => { setMockupsOnlyState(on); saveMockupsOnly(on); };
  const ideas = useApi(() => api.ideas(), [], { intervalMs: REFRESH_MS });

  const all = (ideas.data && ideas.data.proposals) || [];
  // scoped = what the URL filters left. The mockup toggle narrows that further,
  // and the count below reports over `scoped` so turning it on never collapses
  // to "12 of 12".
  const scoped = all
    .filter((r) => !project || r.project === project)
    .filter((r) => !status || r.status === status);
  const rows = withMockups(scoped, mockupsOnly);
  const s = summarise(rows);
  const mockupCount = mockupCountText(scoped);

  const setFilter = (key, value) => {
    const q = new URLSearchParams();
    const next = { project, status, [key]: value };
    if (next.project) q.set('project', next.project);
    if (next.status) q.set('status', next.status);
    const qs = q.toString();
    navigate(`/ideas${qs ? `?${qs}` : ''}`);
  };


  const chip = (label, active, onClick) => html`
    <button type="button" class=${active ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;

  return html`
    <div class="page">
      <${PageHeadline} chip="Ideas"
        line1=${ideas.data ? `${fmtNum(s.total)} ${s.total === 1 ? 'proposal' : 'proposals'}.` : ideas.error ? 'The ideas read failed.' : 'Reading the proposals.'}
        line2=${ideas.data ? mockupCount : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span style="font-size:var(--fs-sm);color:var(--faint)">
          the product stage's proposals — PRD, mockup and where each one got to.
          Read-only here; the approve / kill / revise gate is still the${' '}
          <${CockpitLink}/>.
        </span>
      </div>

      <div class="stats stats--6">
        <${Stat} label="AWAITING DECISION" value=${ideas.data ? s.awaiting : '…'} tone=${s.awaiting ? 'warn' : null}/>
        <${Stat} label="CANDIDATES" value=${ideas.data ? (s.byStatus.candidate || 0) : '…'}/>
        <${Stat} label="POSTED TO CLIENTS" value=${ideas.data ? s.posted : '…'}/>
        <${Stat} label="SHIPPED" value=${ideas.data ? s.shipped : '…'}/>
        <${Stat} label="WITH A MOCKUP" value=${ideas.data ? s.withMockup : '…'}/>
        <${Stat} label="IN VIEW" value=${ideas.data ? s.total : '…'} tone="sm"/>
      </div>

      ${ideas.data && ideas.data.truncated ? html`
        <div class="banner banner--warn">
          <span>The read hit its row cap, so this is the most recently updated slice — not every proposal on file.</span>
        </div>` : null}

      <${Section} title="FILTERS"
        note="project and status live in the URL, so a filtered view is a link you can send. The mockup toggle is remembered in this browser only.">
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ALL PROJECTS', !project, () => setFilter('project', null))}
          ${facet(all, 'project').map((p) => chip(p, project === p, () => setFilter('project', p)))}
        </div>
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ANY STATUS', !status, () => setFilter('status', null))}
          ${facet(all, 'status').map((st) => chip(statusLabel(st), status === st, () => setFilter('status', st)))}
        </div>
        <div class="tabs" title="the same rows either way, minus the ones there is nothing to look at yet">
          ${chip('EVERY IDEA', !mockupsOnly, () => setMockupsOnly(false))}
          ${chip('WITH MOCKUPS', mockupsOnly, () => setMockupsOnly(true))}
          ${ideas.data ? html`<span class="section__note" style="align-self:center">${mockupCount}</span>` : null}
        </div>
      <//>

      <${Section} title="PROPOSALS"
        note=${ideas.data
          ? `${fmtNum(rows.length)} of ${fmtNum(all.length)} · every row opens its PRD, mockup and chat`
          : 'loading'}>
        ${ideas.loading && !ideas.data
          ? html`<${Skeleton} rows=${6} height=${20}/>`
          : ideas.error && !ideas.data
            ? html`<${ErrorBox} error=${ideas.error} onRetry=${ideas.reload}/>`
            : html`<${ProposalsTable} rows=${rows}
                empty=${html`<${Empty} title=${mockupsOnly ? 'NO PROPOSALS WITH A MOCKUP IN VIEW' : 'NO PROPOSALS IN VIEW'}
                  note=${mockupsOnly
                    ? 'Nothing in this view has reached the drafting stage yet, which is where a mockup gets rendered. Switch to EVERY IDEA to see the candidates behind it.'
                    : project || status
                      ? 'Nothing matches this filter. The product stage runs weekly, so a narrow filter can be legitimately empty.'
                      : 'No proposal has reached the console yet. bin/run-product.sh beats them here as it drafts them.'} />`} />`}
      <//>
    </div>`;
}

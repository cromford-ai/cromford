import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { TicketKey } from '../ui/TicketKey.js';
import { PageHeadline, StationTrack, STATIONS } from '../ui/line.js';
import { kanbanHeadline, KANBAN_STATION, cardStation } from '../lib/line-screens.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import {
  PIPELINE_COLUMNS, filterPipeline, cardKind, cardKey, cardRoute, fleetProjects,
  pipelineRows, shippedCaveat
} from '../lib/kanban.js';
import { SortableTable } from '../ui/SortableTable.js';
import { HeldTag } from '../ui/HeldTag.js';
import {
  ticketColumns, ticketProjects, projectInSnapshot, ticketTotal,
  snapshotAgeMinFromEpochSeconds, snapshotUsable, ticketTriage
} from '../lib/tickets.js';
import { externalClaims, ticketClaim, claimAge, claimIsStaleBranch, claimIsMerged } from '../lib/lanes.js';
import { Section, Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import { agoFromMinutes, minutesSince, snapshotLabel, safeHttpsUrl, prNumberFromUrl } from '../lib/format.js';
import { tierLabel } from '../lib/labels.js';
import { stageLabel, verdictLabel } from '../lib/stages.js';

// CARDS or LIST, remembered per viewer. It is a convenience, so every access is
// guarded: a private window, blocked site data or a thumbnail capture must
// render the screen correctly with nothing stored, and CARDS is the default it
// falls back to. Same convention as the chat screen's read state.
const VIEW_KEY = 'mc.kanban.view.v1';
const VIEWS = ['cards', 'list'];
function loadView() {
  try {
    const raw = window.localStorage.getItem(VIEW_KEY);
    return VIEWS.includes(raw) ? raw : 'cards';
  } catch { return 'cards'; }
}
function saveView(view) {
  try { window.localStorage.setItem(VIEW_KEY, view); } catch { /* not worth surfacing */ }
}

export function KanbanScreen() {
  const fleet = useFleet();
  const [tab, setTab] = useState('pipeline');
  const [project, setProject] = useState(null);
  const [view, setViewState] = useState(loadView);
  const setView = (v) => { setViewState(v); saveView(v); };
  // hub/fleet are literals, not projects — they get no filter pill and no board pane.
  const projects = fleetProjects(fleet.data && fleet.data.projects);

  return html`
    <div class="page">
      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
        <${Link} to="/" class="crumb">← FLEET<//>
        <${Link} to="/merge-queue" class="btn btn--sm">MERGE QUEUE<//>
        <${Link} to="/lead-reviews" class="btn btn--sm">LEAD REVIEWS<//>
        <${Link} to="/build-order" class="btn btn--sm">BUILD ORDER<//>
        <div class="tabs">
          <button class=${tab === 'pipeline' ? 'tab tab--on' : 'tab'} onClick=${() => setTab('pipeline')}>PIPELINE</button>
          <button class=${tab === 'boards' ? 'tab tab--on' : 'tab'} onClick=${() => setTab('boards')}>BOARDS</button>
        </div>
        ${tab === 'pipeline' ? html`
          <div class="tabs" title="the same rows either way — cards to see the shape of the pipeline, a list to scan and sort it">
            <button class=${view === 'cards' ? 'tab tab--on' : 'tab'} onClick=${() => setView('cards')}>CARDS</button>
            <button class=${view === 'list' ? 'tab tab--on' : 'tab'} onClick=${() => setView('list')}>LIST</button>
          </div>` : null}
        <div style="display:flex;gap:6px;margin-left:auto;flex-wrap:wrap">
          <button class=${project === null ? 'tab tab--on' : 'tab'} onClick=${() => setProject(null)}>ALL</button>
          ${projects.map((p) => html`
            <button key=${p} class=${project === p ? 'tab tab--on' : 'tab'} onClick=${() => setProject(p)}>${p}</button>`)}
        </div>
      </div>

      ${tab === 'pipeline'
        ? html`<${Pipeline} project=${project} view=${view}/>`
        : html`<${PageHeadline} chip="Boards" line1=${`${projects.length} ${projects.length === 1 ? 'board' : 'boards'}.`} line2="Each project's own product board, from the hub's ticket snapshot."/>
          <${Boards} project=${project} projects=${projects}/>`}
    </div>`;
}

// BH-4992 (wave 3 of BH-4947): the pipeline's condition in words, from the
// board counts the screen already reads. The columns below are the stations.
export function KanbanHeadline({ board }) {
  const k = kanbanHeadline(board && board.counts);
  return html`<${PageHeadline} chip="Pipeline" asOf=${board && board.snapshot_age_min !== undefined ? snapshotLabel(board.snapshot_age_min) : null}
    line1=${k.line1} line2=${k.line2} lede=${k.lede}/>`;
}

function Pipeline({ project, view }) {
  // The archive is a SERVER-side filter (functions/api/dash/kanban/pipeline.js),
  // so asking for the audit view is a different request, not a client toggle
  // over rows already in hand — the stale rows are genuinely not sent by
  // default. Nothing is deleted; this asks for them back.
  const [audit, setAudit] = useState(false);
  // The server can filter too, but filtering client-side keeps one payload
  // shared across pill clicks and keeps the counts recomputation honest.
  const p = useApi(() => api.pipeline(null, { includeArchived: audit }), [audit], { intervalMs: 30000 });
  // Work claimed by a third-party harness never reaches our build ledger, so
  // without this the pipeline shows nothing for a ticket somebody else is
  // actively building — which reads as "nobody picked this up".
  const snap = useApi(() => api.ticketsSnapshot(), [], { intervalMs: 60000 });

  if (p.loading && !p.data) return html`<${KanbanHeadline} board=${null}/><${Skeleton} rows=${4} height=${70}/>`;
  if (p.error && !p.data) return html`<${KanbanHeadline} board=${null}/><${ErrorBox} error=${p.error} onRetry=${p.reload}/>`;

  const external = externalClaims(snap.data)
    .filter((c) => !project || c.project === project);
  const board = filterPipeline(p.data, project);
  const total = PIPELINE_COLUMNS.reduce((n, c) => n + board.columns[c.key].length, 0);
  const shipped = shippedCaveat(board);

  return html`
    <${KanbanHeadline} board=${board}/>
    <${Section}
      title=${project ? `PIPELINE · ${project}` : 'PIPELINE'}
      note=${`derived from D1 state · ${snapshotLabel(p.data.snapshot_age_min)}`}>
      ${view === 'list'
        ? html`<${PipelineList} board=${board} external=${external} shipped=${shipped}
            emptyNote=${emptyNote(project)} onToggleAudit=${() => setAudit(!audit)}/>`
        : html`<${PipelineBoard} board=${board} external=${external} shipped=${shipped}
            showEmpty=${total === 0 && !board.counts.queued} emptyNote=${emptyNote(project)}
            onToggleAudit=${() => setAudit(!audit)}/>`}
    <//>`;
}

// BH-3569: display words only. lib/kanban.js keeps its keys and labels (its
// tests pin them); this is what the screen draws.
const COLUMN_WORDS = { merge_queue: 'MERGE QUEUE' };
const columnWords = (key, label) => COLUMN_WORDS[key] || label;

// What each column means, visible under both views (a title= is invisible on a
// phone). Kept free of the words the footnotes use, so a board with nothing
// held back still says nothing about held-back rows.
const COLUMN_LEGEND = [
  { term: 'QUEUED', text: 'tickets waiting for a build to start, one line per project' },
  { term: 'BUILDING', text: 'a build is running on it now' },
  { term: 'MERGE QUEUE', text: 'approved auto-merge PRs waiting their turn to merge' },
  { term: 'REVIEW', text: 'a PR waiting on the reviewed-merge sweep or a person' },
  { term: 'SHIPPED', text: 'merged recently' },
  { term: 'DEAD', text: 'failed or given up; open one to see where it stopped' }
];

// Our own PR with no verdict yet is waiting on a review; a dash there read as
// "reviewed, no opinion". No PR and no verdict is still a dash.
const ownUnreviewed = (hasPr, verdict) => hasPr && !verdict;

const emptyNote = (project) => (project
  ? `No build, command or queued ticket for ${project} right now.`
  : 'Nothing is queued, building, waiting on review or recently merged across the fleet.');

// The board: six columns of cards. Unchanged behaviour — it only moved out of
// Pipeline so the list view could sit beside it rather than inside an if.
export function PipelineBoard({ board, external, shipped, showEmpty, emptyNote, onToggleAudit }) {
  // Aliased rather than renamed through the body: `view` now means CARDS-or-LIST
  // one level up, so the prop is `board`, and keeping the local name makes this
  // a move rather than a rewrite of a column layout that is already correct.
  const view = board;
  return html`
      ${showEmpty ? html`<${Empty} title="the pipeline is empty" note=${emptyNote}/>` : null}
      <div class="kb">
        ${PIPELINE_COLUMNS.map((col) => html`
          <div class="kb__col" key=${col.key}>
            <div class=${col.accent === 'green' ? 'kb__head kb__head--green' : 'kb__head'}>
              ${KANBAN_STATION[col.key] === null || KANBAN_STATION[col.key] === undefined
                ? html`<span class="kb__station kb__station--off">off the line</span>`
                : html`<span class="kb__station">${String(KANBAN_STATION[col.key] + 1).padStart(2, '0')} ${STATIONS[KANBAN_STATION[col.key]]}</span>`}
              <span class=${`kb__title${col.accent === 'green' ? ' kb__title--green' : col.accent === 'red' ? ' kb__title--red' : col.accent === 'cyan' ? ' kb__title--cyan' : ''}`}>
                ${columnWords(col.key, col.label)}
              </span>
              <span class="kb__count">${view.counts[col.key] ?? 0}</span>
              ${col.key === 'queued'
                ? html`<span class="kb__count" title="the queued column holds one rollup per project; its count is a queue-depth sum">·depth</span>`
                : null}
              ${col.key === 'building' && external.length
                ? html`<span class="kb__external"
                    title="claimed by a harness that is not ours — real work in flight, but it never reaches our build ledger, so it is counted separately from the number above">
                    · ${external.length} external
                  </span>`
                : null}
              ${col.key === 'building' && view.building_stale > 0
                ? html`<span class="kb__stale"
                    title=${`${view.building_stale} unmerged build${view.building_stale === 1 ? '' : 's'} stuck in a build stage past the freshness window — abandoned attempts the hub still has to sweep from the ledger. NOT in flight, and deliberately not counted above.${view.building_stale_is_fleet_wide ? ' This is a fleet-wide number and cannot be attributed to one project.' : ''}`}>
                    · ${view.building_stale} stale${view.building_stale_is_fleet_wide ? ' (fleet)' : ''}
                  </span>`
                : null}
              ${col.key === 'merged_deployed' && shipped
                ? html`<span class="kb__note" title=${shipped.title}>· ${shipped.label}</span>`
                : null}
              ${col.key === 'dead_failed' ? html`<${DeadArchiveNote} view=${view} onToggle=${onToggleAudit}/>` : null}
            </div>
            ${view.columns[col.key].map((card) => html`
              <${Card} key=${cardKey(card)} card=${card} column=${col.key}/>`)}
            ${col.key === 'building'
              ? external.map((c) => html`<${ExternalCard} key=${`${c.project}:${c.ticket}`} claim=${c}/>`)
              : null}
            ${view.columns[col.key].length === 0 && !(col.key === 'building' && external.length)
              ? html`<span style="font-size:var(--fs-xs);color:var(--fainter);padding:4px 2px">—</span>`
              : null}
          </div>`)}
      </div>
      <${Legend} items=${COLUMN_LEGEND}/>`;
}

// The list: the same rows the board draws, in one dense table. Headers sort
// (the shared SortableTable, so the ordering rule is the console's one rule),
// every identity cell links where its card linked, and the table scrolls inside
// its own container at narrow widths rather than pushing the page sideways.
export function PipelineList({ board, external, shipped, emptyNote, onToggleAudit }) {
  // BH-6536: a ticket_stage card's reason, and a synthetic card's project link,
  // joined back onto its row by the row key pipelineRows builds.
  const staged = new Map();
  for (const [col, cards] of Object.entries((board && board.columns) || {})) {
    for (const c of Array.isArray(cards) ? cards : []) {
      if (c && (c.stage_why || c.synthetic === 'ticket_stage')) staged.set(`${col}:${cardKey(c)}`, c);
    }
  }
  const rows = pipelineRows(board, external).map((r) => {
    const c = staged.get(r.key);
    if (!c) return r;
    return {
      ...r,
      stageWhy: c.stage_why || null,
      route: c.synthetic === 'ticket_stage' ? `/p/${encodeURIComponent(c.project)}` : r.route
    };
  });

  const columns = [
    {
      key: 'columnOrder', label: 'COLUMN', sort: (r) => r.columnOrder,
      cell: (r) => html`<span class=${columnTagClass(r.column)}>${columnWords(r.column, r.columnLabel)}</span>`
    },
    {
      key: 'label', label: 'TICKET', sort: (r) => r.label,
      // An archived row is one the DEAD column hides by default. In the board it
      // is only ever visible in the audit view and carries an ARCHIVED chip;
      // dropping that chip here would render a held-back row identically to a
      // live one, which is the exact confusion the archive note exists to stop.
      cell: (r) => html`
        <${TicketKey} k=${r.ticket} cls="cell-name" fallback=${r.label}
          alt=${{ to: r.route, label: r.prNumber ? 'PR' : r.kind === 'build' ? 'build' : 'open' }}/>
        ${r.archived
          ? html` <span class="tag tag--idle"
              title="older than the archive window — hidden from the default DEAD view, never deleted">ARCHIVED</span>`
          : null}
        ${r.closedIssue
          ? html` <span class="tag tag--idle"
              title="the GitHub issue is closed — hidden from the default DEAD view, never deleted">ISSUE CLOSED</span>`
          : null}
        ${r.held ? html` <${HeldTag} held=${true} ...${r.held}/>` : null}
        ${r.stageWhy ? html` <span class="card__body card__why" title=${r.stageWhy}>${r.stageWhy}</span>` : null}`
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => (r.project
        ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}>${r.project}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      // The one column carrying a sentence — a build's stage is short, but a
      // command's ckey and an external lane's line are not. It takes the width
      // the fixed columns leave over (`flex` + `wide`) and truncates only when
      // the row has genuinely run out of room, with the full text on hover.
      key: 'detail', label: 'STAGE', sort: (r) => r.detail, flex: true,
      cell: (r) => html`<span class="cell-wrap" title=${r.detail}>${stageLabel(r.detail)}</span>`
    },
    {
      key: 'tier', label: 'TIER', sort: (r) => r.tier, align: 'right',
      cell: (r) => (r.tier === null ? html`<span class="na">—</span>` : html`<span class="tag">${tierLabel(r.tier)}</span>`)
    },
    {
      key: 'verdict', label: 'VERDICT', sort: (r) => (r.external ? r.externalLabel : r.verdict),
      cell: (r) => {
        // A third-party lane has no verdict of ours to show. Naming who owns it
        // is the honest cell; an empty one reads as "reviewed, no opinion".
        if (r.external) return html`<span class="tag tag--external">${r.externalLabel}</span>`;
        if (ownUnreviewed(r.prNumber !== null, r.verdict)) return html`<span class="tag tag--idle">not reviewed yet</span>`;
        if (!r.verdict) return html`<span class="na">—</span>`;
        return html`<span class=${r.verdict === 'APPROVE' ? 'tag tag--green' : 'tag tag--warn'} title=${r.verdict}>${verdictLabel(r.verdict)}</span>`;
      }
    },
    {
      key: 'prNumber', label: 'PR', sort: (r) => r.prNumber, align: 'right',
      cell: (r) => {
        if (r.prNumber === null) return html`<span class="na">—</span>`;
        // Our own PRs open the console's PR drill-down; a third-party PR is not
        // in our ledger, so its only honest destination is GitHub.
        if (!r.external && r.project) {
          return html`<${Link} to=${`/pr/${r.project}/${r.prNumber}`}>#${r.prNumber}<//>`;
        }
        const href = safeHttpsUrl(r.prUrl);
        return href
          ? html`<a href=${href} target="_blank" rel="noopener noreferrer">#${r.prNumber} ↗</a>`
          : html`<span>#${r.prNumber}</span>`;
      }
    },
    {
      key: 'ageMin', label: 'AGE', sort: (r) => r.ageMin, align: 'right',
      cell: (r) => html`<span title=${r.ageMin === null ? 'no timestamp on this row' : `${Math.round(r.ageMin)} minutes`}>
        ${agoFromMinutes(r.ageMin)}</span>`
    }
  ];

  // Every disclosure the board makes in a column head. A list that shows the
  // rows but drops the counts BESIDE them is a quieter version of the same lie
  // the SHIPPED cap was: 5 abandoned builds and 12 archived dead rows exist
  // either way, and the audit toggle has to be reachable from both views or the
  // held-back rows are only findable in one of them.
  const stale = Number(board.building_stale) || 0;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <${SortableTable} columns=${columns} rows=${rows} wide
        rowKey=${(r) => r.key}
        rowClass=${(r) => (r.column === 'dead_failed' || r.stale ? 'row--warn' : '')}
        defaultSort="columnOrder" defaultDir="asc"
        empty=${html`<${Empty} title="the pipeline is empty" note=${emptyNote}/>`}/>
      <div class="footnote" style="display:flex;gap:14px;flex-wrap:wrap;align-items:center">
        ${shipped
          ? html`<span title=${shipped.title}>SHIPPED · ${shipped.label}</span>`
          : null}
        ${stale > 0
          ? html`<span class="kb__stale"
              title=${`${stale} unmerged build${stale === 1 ? '' : 's'} stuck in a build stage past the freshness window — abandoned attempts the hub still has to sweep from the ledger. NOT in flight, and deliberately not in the BUILDING rows above.${board.building_stale_is_fleet_wide ? ' This is a fleet-wide number and cannot be attributed to one project.' : ''}`}>
              BUILDING · ${stale} stale${board.building_stale_is_fleet_wide ? ' (fleet)' : ''} not shown
            </span>`
          : null}
        ${external.length
          ? html`<span class="kb__external"
              title="claimed by a harness that is not ours — real work, but it never reaches our build ledger, so it is counted apart from our own rows">
              BUILDING · ${external.length} external
            </span>`
          : null}
        ${board.showing_archived || Number(board.dead_archived) > 0 || (board.dead_closed_known && Number(board.dead_closed) > 0)
          ? html`<span style="display:inline-flex;gap:4px;align-items:center;flex-wrap:wrap">
              DEAD <${DeadArchiveNote} view=${board} onToggle=${onToggleAudit}/>
            </span>`
          : null}
      </div>
      <${Legend} items=${COLUMN_LEGEND}/>
    </div>`;
}

// The column tag's colour follows the board's own accents, so a row reads the
// same way in either view.
function columnTagClass(key) {
  if (key === 'building') return 'tag tag--green';
  if (key === 'dead_failed') return 'tag tag--dead';
  if (key === 'review') return 'tag tag--cyan';
  // MERGE Q is a healthy lane — it is the auto-merge queue doing its job. The
  // board draws it bright, not amber; an amber chip on every row of a working
  // queue reads as a warning nobody needs to act on.
  return 'tag';
}

// The DEAD column's archive line. It states the number held back, the window,
// and the way to see them — because a column that quietly shows 4 of 104 rows
// has lied, and the whole point of archiving the rot was to make the rows that
// matter legible, not to make the rest unfindable.
//
// The branch is chosen by what the PAYLOAD says it is (`showing_archived`), not
// by the button's own state: a toggle re-fetches, and for that moment the old
// rows are still on screen. Following the intent would label a filtered column
// "archived shown" for a beat, which is the small lie this column can least
// afford.
function DeadArchiveNote({ view, onToggle }) {
  const n = view.dead_archived;
  const days = view.dead_archive_days;
  const windowLabel = days ? `${days}d` : 'the archive window';
  // BH-938: dead build rows whose GitHub issue is closed, held back the same
  // way. Only counted when the join actually read its ledger; when it could
  // not, nothing was held back and the column is the worker's own count.
  const closed = view.dead_closed_known && Number(view.dead_closed) > 0 ? Number(view.dead_closed) : 0;
  const fleet = (view.dead_closed_is_fleet_wide ? ' This is a fleet-wide number and cannot be attributed to one project.' : '')
    + (view.dead_closed_complete === false ? ' The closed-issue list was read up to its 1000-row cap, so some closed-issue rows may still be showing.' : '');
  const closedNote = closed
    ? html`<span title=${`${closed} dead build row${closed === 1 ? '' : 's'} whose GitHub issue is closed are hidden. Hidden, not deleted: SHOW ALL returns them flagged.${fleet}`}>
        · ${closed} closed-issue${view.dead_closed_is_fleet_wide ? ' (fleet)' : ''}${view.showing_archived ? ' shown' : ''}
      </span>`
    : null;
  if (view.showing_archived) {
    return html`
      <span class="kb__stale" title="showing every dead row, archived ones included and flagged">
        · ${n} archived shown
        ${closedNote}
        <button class="tab" style="margin-left:4px" onClick=${onToggle}>HIDE OLD</button>
      </span>`;
  }
  if (!n && !closed) return null;
  return html`
    <span class="kb__stale">
      ${n
        ? html`<span title=${`${n} dead row${n === 1 ? '' : 's'} older than ${windowLabel} are archived out of this view. Archived means HIDDEN, never deleted — every row is still in the database and this button asks for them.${view.dead_archive_is_fleet_wide ? ' This is a fleet-wide number and cannot be attributed to one project.' : ''}`}>
            · ${n} archived${view.dead_archive_is_fleet_wide ? ' (fleet)' : ''}
          </span>`
        : null}
      ${closedNote}
      <button class="tab" style="margin-left:4px" onClick=${onToggle}>SHOW ALL</button>
    </span>`;
}

function Card({ card, column }) {
  const kind = cardKind(card);
  // BH-6536: a ticket_stage card has no build row behind it; it links to its
  // project, never to a /builds/ page that does not exist.
  const to = card && card.synthetic === 'ticket_stage' ? `/p/${encodeURIComponent(card.project)}` : cardRoute(card);

  if (kind === 'queue') {
    return html`
      <${Link} to=${to} class="card">
        <div class="card__top">
          <span class="card__key">${card.project}</span>
          <span class=${Number(card.oldest_queued_min) >= 45 ? 'card__age card__age--warn' : 'card__age'}>
            ${agoFromMinutes(card.oldest_queued_min)}
          </span>
        </div>
        <span class="card__body">${card.queue_depth} ticket${card.queue_depth === 1 ? '' : 's'} waiting · oldest ${agoFromMinutes(card.oldest_queued_min)}</span>
        ${card.pending_commands
          ? html`<span class="card__foot">${card.pending_commands} pending command${card.pending_commands > 1 ? 's' : ''}</span>`
          : null}
      <//>`;
  }

  if (kind === 'command') {
    return html`
      <${Link} to=${to} class=${column === 'dead_failed' ? 'card card--dead' : 'card'}
        title=${card.archived ? 'archived — older than the archive window, hidden from the default DEAD view' : undefined}>
        <div class="card__top">
          <span class="card__key">command #${card.command_id}</span>
          <span class="card__age">${agoFromMinutes(card.age_min)}</span>
        </div>
        <span class="card__body" title=${card.ckey}>${card.ckey}</span>
        <span class="card__foot">
          ${(() => {
            // A dead-letter command arrives with stage:'dead_letter' and no
            // `status`, so reading status alone renders an empty chip — the
            // one card whose state matters most showing nothing at all.
            const state = card.status || card.stage || 'unknown';
            return html`<span class=${state === 'dead_letter' ? 'tag tag--dead' : 'tag'}>${state}</span>`;
          })()}
          ${card.archived ? html`<span class="tag tag--idle">ARCHIVED</span>` : null}
          <span>${card.project}</span>
        </span>
      <//>`;
  }

  const dead = column === 'dead_failed';
  const done = column === 'merged_deployed';
  const live = column === 'building';
  // BH-4992: the card's station, never behind its column. A failed card sits
  // off the line, so it has none; a shipped card is drawn done.
  const station = cardStation(card, column);
  const cls = dead ? 'card card--dead'
    : done ? 'card card--done'
    : live ? 'card card--green'
    : column === 'merge_queue' ? 'card card--bright'
    : column === 'review' ? 'card card--cyan'
    : 'card';

  return html`
    <${Link} to=${to} class=${cls}>
      <div class="card__top">
        ${/* ticket-link: inside-a-link. The whole card links to its PR or build (tests/kanban-list-render.test.js pins it); a key link cannot nest in it. The LIST view links the key. */ ''}
        <span class="card__key">${card.ticket || card.bkey || `build #${card.id}`}</span>
        <span class=${live ? 'card__age card__age--live' : done ? 'card__age card__age--ok' : 'card__age'}>
          ${done ? '✓ ' : ''}${agoFromMinutes(card.age_min ?? minutesSince(card.updated_at))}
        </span>
      </div>
      <span class="card__body" title=${card.stage || undefined}>${card.stage ? stageLabel(card.stage) || card.stage : '—'}</span>
      ${card.stage_why ? html`<span class="card__body card__why" title=${card.stage_why}>${card.stage_why}</span>` : null}
      ${station !== null ? html`<div class="card__track" title=${STATIONS.map((s, i) => `${String(i + 1).padStart(2, '0')} ${s}`).join(' · ')}><${StationTrack} at=${station} state=${done ? 'done' : 'now'}
        label=${card.ticket || card.bkey || `build #${card.id}`} compact=${true}/></div>` : null}
      <span class="card__foot">
        <span>${card.project}</span>
        ${card.tier ? html`<span class="tag">${tierLabel(card.tier)}</span>` : null}
        ${card.verdict
          ? html`<span class=${card.verdict === 'APPROVE' ? 'tag tag--green' : 'tag tag--warn'} title=${card.verdict}>${verdictLabel(card.verdict)}</span>`
          : ownUnreviewed(prNumberFromUrl(card.pr_url) !== null, card.verdict)
            ? html`<span class="tag tag--idle">not reviewed yet</span>`
            : null}
        ${card.closed_issue
          ? html`<span class="tag tag--idle"
              title="the GitHub issue is closed — hidden from the default DEAD view, never deleted">ISSUE CLOSED</span>`
          : null}
        ${card.held ? html`<${HeldTag} held=${true} ...${card.held}/>` : null}
      </span>
    <//>`;
}

function Boards({ project, projects }) {
  // ONE call for every OS board, from the hub's own snapshot — not four live
  // calls out to the client board APIs. It is a snapshot, so its age is stated
  // rather than implied.
  const snap = useApi(() => api.ticketsSnapshot(), [], { intervalMs: 60000 });

  if (snap.loading && !snap.data) return html`<${Skeleton} rows=${4} height=${70}/>`;
  if (snap.error && !snap.data) return html`<${ErrorBox} error=${snap.error} onRetry=${snap.reload}/>`;

  // A 200 is not proof of a snapshot. The route answers 200 with
  // {ok:false, unavailable:"..."} when the watchdog read fails, and 200 with
  // {ok:true, projects:{}} before the hub's 10-minute push has ever run. Both
  // leave `carried` empty, and falling through to the per-project map would
  // then tell the operator "no OS board for this project — a normal state, not
  // a fault" for four projects that certainly have one.
  const usable = snapshotUsable(snap.data);
  if (!usable.usable) {
    return html`
      <${Section} title="CLIENT BOARDS" note="from the hub's ticket snapshot">
        <div class="banner banner--warn">
          <span>
            No ticket snapshot to show — <b>${usable.reason}</b>.
            ${' This says nothing about whether these projects have boards; they are simply not in this snapshot. Nothing below is claimed either way.'}
          </span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${snap.reload}>RETRY</button>
        </div>
      <//>`;
  }

  const ageMin = snapshotAgeMinFromEpochSeconds(snap.data.generated_at_epoch);
  const carried = ticketProjects(snap.data);
  // Show what the fleet runs, not just what the snapshot carries: a project
  // with no OS board has to render its own honest empty state rather than
  // silently disappearing from the tab.
  const list = project ? [project] : (projects.length ? projects : carried);
  const grandTotal = carried.reduce(
    (n, p) => n + ticketTotal(snap.data.projects[p] && snap.data.projects[p].tickets), 0);

  return html`
    <div style="display:flex;flex-direction:column;gap:20px">
      <div class="footnote">
        <span>
          ${ageMin === null
            ? 'snapshot age unknown — the hub sent no usable timestamp'
            : `snapshot ${ageMin === 0 ? 'now' : `${agoFromMinutes(ageMin)} ago`}`}
          · ${grandTotal} tickets across ${carried.length} board${carried.length === 1 ? '' : 's'}
          · pushed by the hub, not read live from the client boards
        </span>
      </div>
      ${list.map((p) => html`
        <${BoardPane} key=${p} project=${p} snapshot=${snap.data}/>`)}
    </div>`;
}

function BoardPane({ project, snapshot }) {
  if (!projectInSnapshot(snapshot, project)) {
    return html`
      <${Section} title=${`BOARD · ${project}`}>
        <${Empty} title="no OS board for this project"
          note="The hub's ticket snapshot does not carry this project — it is driven by GitHub issues or JIRA rather than an OS board. A normal state, not a fault.">
          <${Link} to=${`/p/${encodeURIComponent(project)}`} class="btn btn--sm">OPEN ${project}<//>
        <//>
      <//>`;
  }

  const entry = snapshot.projects[project] || {};
  const tickets = entry.tickets || [];
  const cols = ticketColumns(tickets);
  const unknownCols = cols.filter((c) => !c.known && c.count > 0);

  return html`
    <${Section}
      title=${html`BOARD · <${Link} to=${`/p/${encodeURIComponent(project)}`}>${project}<//>`}
      note=${`${tickets.length} tickets${entry.board_id ? ` · board ${entry.board_id}` : ''}`}>
      ${unknownCols.length ? html`
        <div class="footnote">
          <span style="color:var(--amber-dk)">
            ${unknownCols.map((c) => `${c.count} ${c.key}`).join(', ')} — status the console does not
            know, shown in its own column rather than dropped
          </span>
        </div>` : null}
      <div class=${`kb kb--cols-${Math.min(cols.length, 6)}`}>
        ${cols.map((col) => html`
          <div class="kb__col" key=${col.key}>
            <div class="kb__head">
              <span class=${col.key === 'done' ? 'kb__title' : col.key === 'in_progress' ? 'kb__title kb__title--green' : 'kb__title'}>
                ${col.label}
              </span>
              <span class="kb__count">${col.count}</span>
            </div>
            ${col.tickets.slice(0, 40).map((t) => html`
              <${TicketCard} key=${t.key} ticket=${t} project=${project}/>`)}
            ${col.tickets.length > 40 ? html`
              <span style="font-size:var(--fs-xs);color:var(--faint);padding:4px 2px">
                +${col.tickets.length - 40} more not rendered
              </span>` : null}
            ${col.count === 0
              ? html`<span style="font-size:var(--fs-xs);color:var(--fainter);padding:4px 2px">—</span>`
              : null}
          </div>`)}
      </div>
    <//>`;
}


// A ticket a third-party harness is building. It is real work in flight, so it
// belongs in BUILDING — but it never reaches our build ledger, so it is styled
// distinctly and counted apart from our own in-flight number.
function ExternalCard({ claim }) {
  // A MERGED PR is not an abandoned branch and not work in flight. Eight project-4
  // tickets read "stale branch — no PR, tip is 8d old" while every one of those
  // PRs had landed days earlier: the snapshot could not see the PR, so a
  // finished lane was reported as a dead one. The snapshot now says so, and the
  // card says what is actually true — the code is in, the ticket is not closed.
  const merged = claimIsMerged(claim);
  const stale = !merged && claimIsStaleBranch(claim);
  const age = claimAge(claim);
  const href = safeHttpsUrl(claim.prUrl);
  return html`
    <div class=${merged ? 'card card--external card--done' : stale ? 'card card--external card--stale' : 'card card--external'}
      title=${`${claim.ticket} on ${claim.project} — claimed by ${claim.label}, not by our harness`}>
      <div class="card__top">
        <span class="card__key"><${TicketKey} k=${claim.ticket}/></span>
        <span class=${merged ? 'card__age card__age--ok' : stale ? 'card__age card__age--warn' : 'card__age'}>
          ${merged ? '✓ ' : ''}${age === null ? 'no activity date' : agoFromMinutes(age)}
        </span>
      </div>
      <span class="card__body">${claim.title || claim.status || 'claimed externally'}</span>
      <span class="card__foot">
        <span class="tag tag--external">EXTERNAL · ${claim.label}</span>
        <${Link} to=${`/p/${encodeURIComponent(claim.project)}`}>${claim.project}<//>
        ${claim.pr && href
          ? html`<a href=${href} target="_blank" rel="noopener noreferrer">PR #${claim.pr} ↗</a>`
          : claim.pr
            ? html`<span>PR #${claim.pr}</span>`
            : claim.ref
              ? html`<span title="no PR opened yet — this is a branch">branch ${claim.ref}</span>`
              : null}
        ${merged
          ? html`<span class="tag tag--green"
              title="the PR is in. What is left is board hygiene: nobody moved the ticket.">
              PR #${claim.pr} merged ${age === null ? '' : `${agoFromMinutes(age)} ago`} · ticket not closed
            </span>`
          : stale
            ? html`<span style="color:var(--amber-txt)">stale branch — no PR, tip is ${agoFromMinutes(age)} old</span>`
            : null}
      </span>
    </div>`;
}

// The snapshot carries no ticket URL, so a card is not yet a link. Said plainly
// on the card's title attribute rather than faked with a dead href.
//
// Triage fields are rendered ONLY when both are present. The hub's push does
// not carry them yet, and inferring "ready to build" from an absent verdict
// would invent the exact distinction this surface exists to show — so this
// works unchanged before and after that hub change ships.
function TicketCard({ ticket, project }) {
  const triage = ticketTriage(ticket);
  // Who is building it. A fleet claim renders as "harness" without naming a
  // box — every one of our lanes shares the same PAT.
  const claim = ticketClaim(ticket);
  return html`
    <div class=${triage.blockedOnClient ? 'card card--dead' : 'card'}
      title=${`${ticket.key} — the snapshot carries no ticket URL yet`}>
      <div class="card__top">
        <span class="card__key"><${TicketKey} k=${ticket.key}/></span>
        <span class="card__age">${agoFromMinutes(minutesSince(ticket.updatedAt))}</span>
      </div>
      <span class="card__body">${ticket.title || 'untitled'}</span>
      ${claim ? html`
        <span class="card__foot">
          <span class=${claim.external ? 'tag tag--external' : 'tag'}>${claim.label}</span>
          ${claim.pr && safeHttpsUrl(claim.prUrl)
            ? html`<a href=${safeHttpsUrl(claim.prUrl)} target="_blank" rel="noopener noreferrer">PR #${claim.pr} ↗</a>`
            : claim.pr ? html`<span>PR #${claim.pr}</span>` : null}
          ${claimIsMerged(claim)
            ? html`<span class="tag tag--green"
                title="the PR is in. What is left is board hygiene: nobody moved the ticket.">
                MERGED · ticket not closed
              </span>`
            : null}
        </span>` : null}
      ${triage.state === 'blocked_on_client'
        ? html`<span class="card__foot">
            <span class="tag tag--dead">WAITING ON CLIENT</span>
            <span style="color:var(--red-txt)">triage asked a question — not ready to build</span>
          </span>`
        : triage.state === 'assessed'
          ? html`<span class="card__foot">
              <span class="tag">${triage.verdict}</span>
              ${triage.waitingOn ? html`<span>waiting on ${triage.waitingOn}</span>` : null}
            </span>`
          : html`<span class="card__foot">
              <span class="tag tag--idle" title="nobody has assessed this ticket yet — unassessed is not the same as ready to build">
                NOT YET ASSESSED
              </span>
            </span>`}
    </div>`;
}

import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { fleetProjects as fleetProjectNames } from '../lib/kanban.js';
import { WAITING_REASONS, REASON_LABEL } from '../lib/waiting.js';
import { SortableTable } from '../ui/SortableTable.js';
import { TicketKey } from '../ui/TicketKey.js';
import { Skeleton, Empty, ErrorBox, Age, ProjectLink, Legend } from '../ui/primitives.js';

// The "To do (waiting)" view (BH-9116): every open board ticket that is not in
// flight, one reason each, from GET /api/dash/kanban/waiting. On the KANBAN
// screen's TO DO (WAITING) tab and in the QUEUES section of /p/<project>.
// The rule is src/lib/waiting.js; this only draws its answer.

const REASON_ORDER = Object.fromEntries(WAITING_REASONS.map((r, i) => [r, i]));
const dash = html`<span class="na">—</span>`;

function WaitsOn({ r }) {
  if (r.reason === 'blocked-by' && r.blocker) {
    return html`<span>blocked by <${Link} to=${r.blocker.route} class="tk">${r.blocker.key}<//>${r.blocker.url
      ? html` <a href=${r.blocker.url} target="_blank" rel="noopener noreferrer" title="the blocker on its board">↗</a>` : null}</span>`;
  }
  if (r.reason === 'queued') {
    const pos = r.position === null || r.position === undefined ? 'position unknown' : `position ${r.position}`;
    return html`<span>${pos}${r.reason_text ? ` · ${r.reason_text}` : ''}</span>`;
  }
  if (r.reason === 'needs-clarification') return r.waiting_on ? html`<span>${`waiting on ${r.waiting_on}`}</span>` : dash;
  return r.reason_text ? html`<span>${r.reason_text}</span>` : dash;
}

const columns = [
  { key: 'project', label: 'PROJECT', sort: (r) => r.project, cell: (r) => html`<${ProjectLink} project=${r.project}/>` },
  {
    key: 'key', label: 'KEY', sort: (r) => r.key,
    cell: (r) => html`<span class="tk-pair"><${TicketKey} k=${r.key}/>${r.board_url
      ? html` <a href=${r.board_url} target="_blank" rel="noopener noreferrer" title="open on its board">↗</a>` : null}</span>`
  },
  { key: 'title', label: 'TITLE', flex: true, sort: (r) => r.title, cell: (r) => r.title || dash },
  { key: 'reason', label: 'REASON', sort: (r) => REASON_ORDER[r.reason] ?? 99, cell: (r) => html`<span class="tag" title=${REASON_LABEL[r.reason] || ''}>${r.reason}</span>` },
  { key: 'waits', label: 'WAITS ON', sort: null, cell: (r) => html`<${WaitsOn} r=${r}/>` },
  { key: 'age', label: 'AGE', sort: (r) => r.age_min, cell: (r) => html`<${Age} min=${r.age_min} warnAt=${Infinity}/>` },
  {
    key: 'link', label: 'JOB/PR', sort: null,
    cell: (r) => (r.pr_route || r.job_route
      ? html`<span style="display:flex;gap:6px;flex-wrap:wrap">
          ${r.pr_route ? html`<${Link} to=${r.pr_route}>PR<//>` : null}
          ${r.job_route ? html`<${Link} to=${r.job_route}>JOB<//>` : null}
        </span>`
      : dash)
  }
];

const LEGEND = WAITING_REASONS.map((r) => ({ term: r, text: REASON_LABEL[r] }));

export function WaitingView({ state, project = null, fleetProjects = [], onRetry }) {
  if (state.loading && !state.data) return html`<${Skeleton} rows=${4} height=${18}/>`;
  if (state.error && !state.data) return html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`;
  const d = state.data || {};
  if (d.ok !== true) {
    return html`<div class="banner banner--warn"><span>The waiting view is unavailable: <b>${d.unavailable || 'no answer'}</b>. This is not a count of zero.</span></div>`;
  }
  if (project && d.project_in_snapshot === false) {
    return html`<${Empty} title=${`no OS board snapshot for ${project}`}
      note="This project's tickets are not in the hub's ticket snapshot (a GitHub-issue board), so this view cannot list them."/>`;
  }
  const counts = d.counts || {};
  const covered = new Set(d.snapshot_projects || []);
  const uncovered = project ? [] : (fleetProjects || []).filter((p) => !covered.has(p));
  const rows = d.rows || [];
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center">
        ${WAITING_REASONS.filter((r) => counts[r] > 0).map((r) => html`<span key=${r} class="tag" title=${REASON_LABEL[r]}>${`${r} ${counts[r]}`}</span>`)}
        <span class="tag tag--idle" title="open tickets with a running build, a fresh claim or a PR in review">${`in flight ${d.in_flight || 0}`}</span>
        ${(d.stale_claims || []).length
          ? html`<span class="tag tag--warn" title="claimed queue rows with no running build; KANBAN does not count them as building">${`stale claims ${d.stale_claims.length}`}</span>`
          : null}
      </div>
      ${d.truncated ? html`<span class="section__note">${`Only the first ${d.knobs ? d.knobs.max_tickets : ''} open tickets were read; ${d.unread || 0} more are not shown (knob waiting.max_tickets).`}</span>` : null}
      ${uncovered.length ? html`<span class="section__note">${`not covered: ${uncovered.join(', ')} — no OS board snapshot`}</span>` : null}
      ${rows.length === 0
        ? html`<${Empty} title="nothing waiting" note=${project ? `Every open ${project} ticket is in flight.` : 'Every open ticket on the OS boards is in flight.'}/>`
        : html`<${SortableTable} columns=${columns} rows=${rows} wide defaultSort="age" defaultDir="desc"
            rowKey=${(r) => `${r.project}:${r.key}`}/>`}
      <${Legend} items=${LEGEND}/>
    </div>`;
}

export default function WaitingPanel({ project = null }) {
  const fleet = useFleet();
  const state = useApi(() => api.waiting(project), [project], { intervalMs: 60000 });
  const names = fleetProjectNames(fleet && fleet.data && fleet.data.projects);
  return html`<${WaitingView} state=${state} project=${project} fleetProjects=${names} onRetry=${state.reload}/>`;
}

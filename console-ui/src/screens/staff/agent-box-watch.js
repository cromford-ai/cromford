// BH-10231 (C1 of BH-9889): the BOX WATCH section of /staff/quartermaster.
// The hub lane bin/box-watch.sh restarts a fleet box that failed
// box_watch.fail_probes ssh probes in a row, at most once per box per
// box_watch.restart_window_min, and writes one row per restart attempt. This
// section lists the newest 50 rows (GET /api/box-watch/actions?limit=50),
// newest first, polled every 60 s. It owns its read, so it never waits on the
// page's other reads. AgentBoxWatchView is a pure function of props, so the
// tests render it server-side.
import { html, Link } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Legend } from '../../ui/primitives.js';

// The roster and the agent page poll at the same 60 s.
const POLL_MS = 60000;
// The list read's page size (the worker caps it at 200).
export const BOX_WATCH_LIMIT = 50;
export const BOX_WATCH_AGENT = 'quartermaster';

const na = (v) => (v === null || v === undefined || v === '' ? html`<span class="na">—</span>` : v);
const OUTCOME_TEXT = {
  claimed: 'in progress', back: 'back', still_dark: 'still dark', refused: 'refused', restart_failed: 'restart failed'
};
const outcomeCell = (o) => {
  const t = OUTCOME_TEXT[o] || String(o || '');
  const bad = o === 'still_dark' || o === 'refused' || o === 'restart_failed';
  return html`<span style=${bad ? 'color:var(--red)' : ''}>${t}</span>`;
};

export const BOX_WATCH_COLUMNS = [
  { key: 'acted_at', label: 'ACTED', cell: (r) => na(r.acted_at) },
  {
    key: 'box', label: 'BOX',
    cell: (r) => html`<${Link} to=${`/machines?box=${encodeURIComponent(r.box)}`} class="cell-name">${r.box}<//>`
  },
  { key: 'probes', label: 'PROBES', align: 'right', cell: (r) => na(r.probes) },
  { key: 'outcome', label: 'OUTCOME', sort: (r) => r.outcome, cell: (r) => outcomeCell(r.outcome) },
  { key: 'restart_rc', label: 'RESTART RC', align: 'right', cell: (r) => na(r.restart_rc) },
  { key: 'recovery_rc', label: 'RECOVERY RC', align: 'right', cell: (r) => na(r.recovery_rc) },
  { key: 'back_at', label: 'BACK AT', cell: (r) => na(r.back_at) },
  { key: 'detail', label: 'DETAIL', flex: true, sort: null, cell: (r) => na(r.detail) }
];

const LEGEND = [
  { term: 'PROBES', text: 'failed ssh probes in a row when the restart started (settings row box_watch.fail_probes)' },
  { term: 'OUTCOME', text: 'back = the box answers ssh after the restart; still dark, refused and restart failed page the operator' },
  { term: 'RESTART RC', text: 'the exit code of bin/box-ops.sh restart; 2 = refused (for example no Orgo key)' }
];

export function boxWatchRows(data) {
  if (!data || typeof data !== 'object' || !Array.isArray(data.actions)) return null;
  return data.actions.filter((r) => r && typeof r === 'object' && typeof r.box === 'string');
}

export function AgentBoxWatchView({ actions }) {
  const rows = boxWatchRows(actions && actions.data);
  let body;
  if (actions && actions.loading && !rows) body = html`<${Skeleton} rows=${3} height=${20}/>`;
  else if (rows === null) {
    body = html`<${ErrorBox} error=${(actions && actions.error) || new Error('the box-watch read returned no list')} onRetry=${actions && actions.reload}/>`;
  } else {
    body = html`
      ${actions && actions.error ? html`<${ErrorBox} error=${actions.error} onRetry=${actions.reload}/>` : null}
      <${SortableTable} wide columns=${BOX_WATCH_COLUMNS} rows=${rows} rowKey=${(r) => r.id} defaultSort="acted_at" defaultDir="desc"
        empty=${html`<${Empty} title="no box restarts recorded" note="the hub restarts a box only after it fails its ssh probes in a row"/>`}/>
      <${Legend} items=${LEGEND}/>`;
  }
  return html`<div data-testid="agent-box-watch">
    <${Section} title="BOX WATCH" note="box restarts by the hub box-watch duty, newest first">${body}<//>
  </div>`;
}

export function AgentBoxWatch() {
  const actions = useApi(() => api.boxWatchActions({ limit: BOX_WATCH_LIMIT }), [], { intervalMs: POLL_MS });
  return html`<${AgentBoxWatchView} actions=${actions}/>`;
}

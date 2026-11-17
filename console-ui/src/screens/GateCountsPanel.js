import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, ErrorBox, Age } from '../ui/primitives.js';
import { minutesSince, fmtNum } from '../lib/format.js';

// The SELECTION GATES TODAY section on /p/<project> (BH-9258, #9061 Fix 4):
// today's (UTC) pre-PR selection-gate outcomes of this project's pool builds.
// The hub lane bin/pool-tick-summary.sh counts builds/pool-<P>-*/gate.txt
// (bin/lib/sg-day-counts.sh) every 2 minutes and stores the counts as the
// pool row's gates_today; this panel reads that row with ONE GET of its own,
// in parallel with the page's other reads. A project with no pool row (no
// gates_today) renders nothing.

export const GATE_COLUMNS = [
  ['day', 'DAY'], ['gates', 'GATES'], ['rc0', 'RC 0'], ['rc1_attributed', 'RED (ATTRIBUTED)'],
  ['rc1_unattributed', 'RED (UNATTRIBUTED)'], ['could_not_run', 'COULD NOT RUN'],
];

const isCount = (v) => Number.isInteger(v) && v >= 0;

// "unattributed: 27 of 45 (60%)", or "unattributed: n/a" when no gate ran.
export function shareLine(g) {
  if (!g || !isCount(g.gates) || g.gates === 0 || !isCount(g.rc1_unattributed)) return 'unattributed: n/a';
  return `unattributed: ${fmtNum(g.rc1_unattributed)} of ${fmtNum(g.gates)} (${fmtNum(Math.round((100 * g.rc1_unattributed) / g.gates))}%)`;
}

// The gates_today object of a /api/pool/status answer, or null.
export function gatesOf(data) {
  const g = data && data.gates_today;
  return g && typeof g === 'object' && !Array.isArray(g) ? g : null;
}

export function GateCountsView({ loading, error, data, onRetry }) {
  const title = 'SELECTION GATES TODAY';
  const note = 'pre-PR selection gates of this project’s pool builds, UTC day';
  if (loading) return html`<${Section} title=${title} note=${note}><${Skeleton} rows=${2} height=${18}/><//>`;
  if (error) return html`<${Section} title=${title} note=${note}><${ErrorBox} error=${error} onRetry=${onRetry}/><//>`;
  const g = gatesOf(data);
  if (!g) return null;
  const columns = GATE_COLUMNS.map(([key, label]) => (key === 'day'
    ? { key, label, cell: (r) => html`<span class="mono">${r.day}</span>` }
    : { key, label, align: 'right', cell: (r) => (isCount(r[key]) ? fmtNum(r[key]) : '—') }));
  const age = data.reported_at ? minutesSince(data.reported_at) : null;
  return html`
    <${Section} title=${title} note=${note}>
      <${SortableTable} columns=${columns} rows=${[g]} rowKey=${(r) => r.day} wide/>
      <p class="section__note" style="margin:6px 0 0">
        ${shareLine(g)} · reported <${Age} min=${age}/>
      </p>
    <//>`;
}

export default function GateCountsPanel({ project }) {
  const read = useApi(() => api.poolStatus(project), [project]);
  return html`<${GateCountsView} loading=${!read.data && !read.error} error=${read.error}
    data=${read.data} onRetry=${read.reload}/>`;
}

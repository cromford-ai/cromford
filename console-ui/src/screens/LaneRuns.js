import { html, Link, useSearchParam } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { whenLabel, fmtDuration } from '../lib/format.js';
import { laneRunMetrics, laneRunList, laneRun } from '../lib/lane-runs-api.js';

// LANES (BH-6127): where each lane's runs ran once a lane can run on Fly. The
// jobs worker owns the queue (BH-6124); this page only reads it. /lane-runs is
// 24 h of counts and queue wait per lane and per machine, plus the hub's load;
// /lane-runs/lane/:lane and /lane-runs/machine/:machine are the runs behind a
// row; /lane-runs/run/:id is one run. Each screen owns its read and hands the
// load state to a view that is a pure function of props, so the tests render
// the views server-side with fixed data (the CiHealth split).

const HOURS = 24;
const POLL = { intervalMs: 60000 };

export const EMPTY_COPY = 'No lane runs in the last 24 h. Every lane runs on the hub until a lane_placement row says fly.';
const LIST_EMPTY = 'No lane runs match this filter.';

const na = (why) => html`<span class="na" title=${why || ''}>—</span>`;
const note = (text) => html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">${text}</span></div>`;
const when = (iso) => (iso ? html`<span title=${iso}>${whenLabel(iso)}</span>` : na('not yet'));
const laneHref = (lane) => `/lane-runs/lane/${encodeURIComponent(lane)}`;
const machineHref = (m) => `/lane-runs/machine/${encodeURIComponent(m)}`;
const runHref = (id) => `/lane-runs/run/${encodeURIComponent(id)}`;

// Seconds as minutes: one decimal under ten minutes, whole minutes above.
// Null stays null, so a lane with no wait sample shows a dash and never 0.
export function minutes(s) {
  if (s === null || s === undefined || !Number.isFinite(Number(s))) return null;
  const m = Number(s) / 60;
  return m < 10 ? Math.round(m * 10) / 10 : Math.round(m);
}
const minCell = (s, why) => (minutes(s) === null ? na(why) : minutes(s));
const usd = (n) => {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return na('no cost recorded');
  const v = Number(n);
  return v > 0 && v < 0.01 ? '<0.01' : v.toFixed(2);
};

// The minutes and cost columns draw a rounded number and sort on the raw
// one. `alertMin` turns a wait max at or over the alert limit amber.
export function laneColumns(alertMin) {
  const hot = (s) => alertMin !== null && alertMin !== undefined && Number(s) >= Number(alertMin) * 60;
  return [
    { key: 'lane', label: 'LANE', sort: (r) => r.lane, cell: (r) => html`<${Link} to=${laneHref(r.lane)} class="cell-name">${r.lane}<//>` },
    { key: 'queued', label: 'QUEUED', align: 'right', sort: (r) => r.queued, cell: (r) => r.queued ?? na() },
    { key: 'claimed', label: 'CLAIMED', align: 'right', sort: (r) => r.claimed, cell: (r) => r.claimed ?? na() },
    { key: 'done', label: 'DONE', align: 'right', sort: (r) => r.done, cell: (r) => r.done ?? na() },
    { key: 'died', label: 'DIED', align: 'right', sort: (r) => r.died, cell: (r) => r.died ?? na() },
    { key: 'wait_p50', label: 'WAIT P50', unit: 'min', align: 'right', sort: (r) => r.wait_p50_s, cell: (r) => minCell(r.wait_p50_s, 'no wait sample') },
    {
      key: 'wait_max', label: 'WAIT MAX', unit: 'min', align: 'right', sort: (r) => r.wait_max_s,
      cell: (r) => (minutes(r.wait_max_s) === null ? na('no wait sample')
        : hot(r.wait_max_s) ? html`<span style="color:var(--amber)" title="at or over the alert limit">${minutes(r.wait_max_s)}</span>`
          : minutes(r.wait_max_s))
    },
    { key: 'cost', label: 'COST', unit: '$', align: 'right', sort: (r) => r.cost_usd, cell: (r) => usd(r.cost_usd) },
  ];
}
export const LANE_COLUMNS = laneColumns(null);

export const MACHINE_COLUMNS = [
  { key: 'machine', label: 'MACHINE', sort: (r) => r.machine, cell: (r) => html`<${Link} to=${machineHref(r.machine)} class="cell-name">${r.machine}<//>` },
  { key: 'claimed', label: 'CLAIMED', align: 'right', sort: (r) => r.claimed, cell: (r) => r.claimed ?? na() },
  { key: 'done', label: 'DONE', align: 'right', sort: (r) => r.done, cell: (r) => r.done ?? na() },
  { key: 'died', label: 'DIED', align: 'right', sort: (r) => r.died, cell: (r) => r.died ?? na() },
  { key: 'last', label: 'LAST CLAIM', sort: (r) => r.last_claimed_at, cell: (r) => when(r.last_claimed_at) },
];

export const RUN_COLUMNS = [
  { key: 'id', label: 'RUN #', align: 'right', sort: (r) => r.id, cell: (r) => html`<${Link} to=${runHref(r.id)} class="cell-name">${r.id}<//>` },
  { key: 'lane', label: 'LANE', sort: (r) => r.lane, cell: (r) => html`<${Link} to=${laneHref(r.lane)}>${r.lane}<//>` },
  { key: 'project', label: 'PROJECT', sort: (r) => r.project, cell: (r) => r.project || na() },
  { key: 'status', label: 'STATUS', sort: (r) => r.status, cell: (r) => r.status || na() },
  { key: 'enqueued', label: 'ENQUEUED', sort: (r) => r.enqueued_at, cell: (r) => when(r.enqueued_at) },
  { key: 'wait', label: 'WAIT', unit: 'min', align: 'right', sort: (r) => r.wait_s, cell: (r) => minCell(r.wait_s, 'not claimed yet') },
  { key: 'machine', label: 'MACHINE', sort: (r) => r.claimed_by, cell: (r) => (r.claimed_by ? html`<${Link} to=${machineHref(r.claimed_by)}>${r.claimed_by}<//>` : na('not claimed yet')) },
  { key: 'rc', label: 'RC', align: 'right', sort: (r) => r.rc, cell: (r) => r.rc ?? na('not finished') },
];

const asOf = (data) => (data && data.as_of ? `as of ${String(data.as_of).slice(11, 19)}Z` : '');
const errText = (e) => (e && e.message ? e.message : String(e));
// The load states every view shares. Data on screen stays when a refresh
// fails, with the failure named above it; no data and an error is the
// ErrorBox; neither yet is the skeleton.
function loadGate(state) {
  if (state.data) return state.error ? note(`refresh failed: ${errText(state.error)}`) : null;
  if (state.error) return html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>`;
  return html`<${Skeleton} rows=${4} height=${20}/>`;
}

// ---------------------------------------------------------------- /lane-runs

export function LaneRunsScreen() {
  const state = useApi(() => laneRunMetrics(HOURS), [], POLL);
  return html`<${LaneRunsView} state=${state}/>`;
}

// `laneSort` ([key, dir]) is the lanes table's first sort; the tests use it to
// render the order a header click produces.
export function LaneRunsView({ state, laneSort }) {
  const d = state.data;
  const lanes = d && Array.isArray(d.lanes) ? d.lanes : [];
  const machines = d && Array.isArray(d.machines) ? d.machines : [];
  const hours = d && d.hours ? d.hours : HOURS;
  const head = html`<${PageHeadline} chip="LANES" asOf=${asOf(d)}
    line1=${d ? `${lanes.length} ${lanes.length === 1 ? 'lane' : 'lanes'} ran in the last ${hours} h.` : 'Reading lane runs.'}
    line2="Queue wait, claims and deaths per lane and per machine."/>`;
  const gate = loadGate(state);
  if (!d) return html`${head}${gate}`;
  if (!lanes.length) return html`${head}${gate}<${Empty} title="no lane runs" note=${EMPTY_COPY}/>`;

  const hub = d.hub;
  const [sortKey, sortDir] = laneSort || ['lane', 'asc'];
  return html`
    ${head}
    ${gate}
    <div class="footnote" style="margin-bottom:14px">
      <span class="tag">${hub ? `hub load ${hub.load1} · ${fmtDuration(hub.age_s)} old` : 'hub load: no report yet'}</span>
      <span class="tag">alert limit ${d.wait_alert_min} min</span>
      <span class="tag">window ${hours} h</span>
      ${d.cost_available === false ? html`<span class="tag tag--warn">cost not available</span>` : null}
    </div>
    <${Section} title=${`LANES · ${lanes.length}`} note="wait is enqueue to claim; a lane's name opens its runs">
      ${d.truncated ? note('wait sample capped: p50 and max cover the newest runs only') : null}
      <${SortableTable} columns=${laneColumns(d.wait_alert_min)} rows=${lanes} rowKey=${(r) => r.lane}
        defaultSort=${sortKey} defaultDir=${sortDir}/>
    <//>
    <${Section} title=${`MACHINES · ${machines.length}`} note="each machine that claimed a run in the window">
      <${SortableTable} columns=${MACHINE_COLUMNS} rows=${machines} rowKey=${(r) => r.machine}
        empty=${html`<${Empty} title="no machine claimed a run in the window"/>`}/>
    <//>`;
}

// ------------------------------------------- /lane-runs/lane|machine/:x

export function LaneRunListScreen({ lane, machine }) {
  const status = useSearchParam('status');
  const state = useApi(() => laneRunList({ lane, machine, status }), [lane, machine, status], POLL);
  return html`<${LaneRunListView} state=${state} lane=${lane} machine=${machine} status=${status}/>`;
}

export function LaneRunListView({ state, lane, machine, status }) {
  const d = state.data;
  const runs = d && Array.isArray(d.runs) ? d.runs : [];
  const what = lane ? `lane ${lane}` : `machine ${machine}`;
  const head = html`<${PageHeadline} chip=${lane ? `LANE · ${lane}` : `MACHINE · ${machine}`} asOf=${asOf(d)}
    line1=${d ? `${runs.length} ${runs.length === 1 ? 'run' : 'runs'} on ${what}${status ? ` with status ${status}` : ''}.` : `Reading the runs on ${what}.`}
    line2="Newest first. A run number opens that run."/>`;
  const back = html`<div class="footnote" style="margin-bottom:10px"><${Link} to="/lane-runs">← all lanes<//></div>`;
  const gate = loadGate(state);
  if (!d) return html`${head}${back}${gate}`;
  return html`
    ${head}
    ${back}
    ${gate}
    ${d.truncated ? note(`showing the newest ${d.limit} runs`) : null}
    <${SortableTable} columns=${RUN_COLUMNS} rows=${runs} rowKey=${(r) => r.id} defaultSort="id" defaultDir="desc"
      empty=${html`<${Empty} title="no runs" note=${LIST_EMPTY}/>`}/>`;
}

// ---------------------------------------------------- /lane-runs/run/:id

export function LaneRunScreen({ id }) {
  const state = useApi(() => laneRun(id), [id]);
  return html`<${LaneRunView} state=${state} id=${id}/>`;
}

// The prof line and the args are worker text: they render as text nodes, so
// markup in them stays literal.
const stamp = (iso) => (iso ? html`${iso} <span class="na">· ${whenLabel(iso)}</span>` : na('not yet'));

export function LaneRunView({ state, id }) {
  const r = state.data && state.data.run;
  const head = html`<${PageHeadline} chip=${`RUN · ${id}`} asOf=${asOf(state.data)}
    line1=${r ? `Run #${r.id} on lane ${r.lane} is ${r.status}.` : `Reading run #${id}.`}
    line2=${r ? `Project ${r.project || 'none'}, ${r.attempts ?? 0} ${r.attempts === 1 ? 'attempt' : 'attempts'}.` : 'One lane run.'}/>`;
  if (!r && state.error && state.error.status === 404) {
    return html`${head}<${Empty} title=${`No lane run #${id}.`} note="The jobs worker has no run with this id."/>`;
  }
  const gate = loadGate(state);
  if (!r) return html`${head}${gate}`;
  const rows = [
    ['RC', r.rc ?? na('not finished')],
    ['PROF LINE', r.prof_line ? html`<code style="overflow-wrap:anywhere">${r.prof_line}</code>` : na('no PROF line')],
    ['CLAIMER', r.claimed_by ? html`<${Link} to=${machineHref(r.claimed_by)}>${r.claimed_by}<//>` : na('not claimed yet')],
    ['WAIT', minutes(r.wait_s) === null ? na('not claimed yet') : `${minutes(r.wait_s)} min`],
    ['RUN TIME', r.run_s === null || r.run_s === undefined ? na('not finished') : fmtDuration(r.run_s)],
    ['ATTEMPTS', r.attempts ?? na()],
    ['STATUS', r.status || na()],
    ['LANE', html`<${Link} to=${laneHref(r.lane)}>${r.lane}<//>`],
    ['PROJECT', r.project || na()],
    ['ENQUEUED', stamp(r.enqueued_at)],
    ['ENQUEUED BY', r.enqueued_by || na()],
    ['CLAIMED', stamp(r.claimed_at)],
    ['HEARTBEAT', stamp(r.heartbeat_at)],
    ['LEASE UNTIL', stamp(r.lease_until)],
    ['FINISHED', stamp(r.finished_at)],
    ['ARGS', Array.isArray(r.args) && r.args.length ? html`<code style="overflow-wrap:anywhere">${r.args.join(' ')}</code>` : na('no args')],
  ];
  return html`
    ${head}
    <div class="footnote" style="margin-bottom:10px"><${Link} to=${laneHref(r.lane)}>← lane ${r.lane}<//></div>
    ${gate}
    <${Section} title="RUN">
      ${rows.map(([k, v]) => html`
        <div key=${k} class="kv" style="grid-template-columns:110px minmax(0,1fr)">
          <span class="kv__label">${k}</span>
          <span class="kv__val" style="text-align:left;overflow-wrap:anywhere">${v}</span>
        </div>`)}
    <//>`;
}

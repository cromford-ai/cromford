// BH-9422 (BH-9187.4, C4): the staff lever scorecards.
// StaffMetrics: the /staff METRICS section, one row per staff agent from
// GET /api/staff/levers/scoreboard. AgentMetric({agent}): the /staff/<agent>
// METRIC section from GET /api/staff/levers/scorecard. Each owns its read;
// StaffMetricsView and AgentMetricView are pure functions of props, so the
// tests render them server-side. Archie is not a staff agent: the scoreboard
// leaves it out and Staff.js passes no METRIC section for it.
//
// PRECISION here is the lever precision (moved / settled lever actions in
// the window), not the roster's ticket-verdict PRECISION (BH-5563).
import { html, Link } from '../../router.js';
import { useApi } from '../../lib/hooks.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Legend } from '../../ui/primitives.js';
import { na } from '../../lib/staff.js';
import { fetchScoreboard, fetchScorecard, scoreRows, fmtValue, precisionText } from '../../lib/staff-scores.js';

// The roster and the agent page poll at the same 60 s.
const POLL_MS = 60000;

const naSpan = (s) => html`<span class=${s === 'n/a' || s === 'no sample' || s === 'no metric row' ? 'na' : ''}>${s}</span>`;
const metricText = (m) => (m ? m : 'no metric row');
const sampleTitle = (s) => (s && s.sampled_at ? `sampled ${s.sampled_at}` : '');

function metricColumns(days) {
  return [
    {
      key: 'agent', label: 'AGENT',
      cell: (r) => html`<${Link} to=${`/staff/${encodeURIComponent(r.agent)}`} class="cell-name">${r.agent}<//>`
    },
    { key: 'metric', label: 'METRIC', cell: (r) => naSpan(metricText(r.metric)) },
    { key: 'target', label: 'TARGET', align: 'right', cell: (r) => naSpan(na(r.target)) },
    { key: 'level', label: 'LEVEL', cell: (r) => naSpan(na(r.level)) },
    { key: 'now', label: 'NOW', align: 'right', cell: (r) => html`<span title=${sampleTitle(r.metric_now)}>${naSpan(fmtValue(r.now))}</span>` },
    { key: 'then', label: `${days === null ? '?' : days}D AGO`, align: 'right', cell: (r) => html`<span title=${sampleTitle(r.metric_then)}>${naSpan(fmtValue(r.then))}</span>` },
    { key: 'actions', label: 'ACTIONS', align: 'right', cell: (r) => naSpan(na(r.actions)) },
    { key: 'settled', label: 'SETTLED', align: 'right', cell: (r) => naSpan(na(r.settled)) },
    { key: 'moved', label: 'MOVED', align: 'right', cell: (r) => naSpan(na(r.moved)) },
    { key: 'precision', label: 'PRECISION', align: 'right', cell: (r) => naSpan(precisionText(r.precision)) }
  ];
}

const legend = (days) => [
  { term: 'METRIC', text: 'the one number the agent owns (settings row staff.<agent>.metric); lower is better' },
  { term: 'NOW', text: 'the newest metric sample; no sample means the agent has not posted one yet' },
  { term: `${days === null ? '?' : days}D AGO`, text: 'the newest sample at or before the start of the window (settings row staff.scorecard_days)' },
  { term: 'ACTIONS', text: 'lever actions in the window, dry runs not counted' },
  { term: 'PRECISION', text: 'moved / settled lever actions in the window; n/a until one settles. Not the roster\'s PRECISION, which is ticket verdicts' }
];

export function StaffMetricsView({ board }) {
  const res = scoreRows(board && board.data);
  let body;
  if (board && board.loading && !res) body = html`<${Skeleton} rows=${7} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(board && board.error) || new Error('the scoreboard read returned no agent list')} onRetry=${board && board.reload}/>`;
  } else {
    body = html`
      ${board && board.error ? html`<${ErrorBox} error=${board.error} onRetry=${board.reload}/>` : null}
      <${SortableTable} wide columns=${metricColumns(res.days)} rows=${res.rows} rowKey=${(r) => r.agent} defaultSort="agent" defaultDir="asc"
        empty=${html`<${Empty} title="no staff agents"/>`}/>
      <${Legend} items=${legend(res.days)}/>`;
  }
  return html`<${Section} title="METRICS" note="each staff agent's metric, target and level, with its lever actions in the window">${body}<//>`;
}

export function StaffMetrics() {
  const board = useApi(fetchScoreboard, [], { intervalMs: POLL_MS });
  return html`<${StaffMetricsView} board=${board}/>`;
}

export function AgentMetricView({ card }) {
  const c = card && card.data && typeof card.data === 'object' && typeof card.data.agent === 'string' ? card.data : null;
  if (card && card.loading && !c) return html`<${Skeleton} rows=${5} height=${18}/>`;
  if (!c) return html`<${ErrorBox} error=${(card && card.error) || new Error('the scorecard read returned no agent')} onRetry=${card && card.reload}/>`;
  const items = [
    ['METRIC', metricText(c.metric)],
    ['TARGET', na(c.target)],
    ['LEVEL', na(c.level)],
    ['NOW', fmtValue(c.metric_now)],
    [`${na(c.days)} DAYS AGO`, fmtValue(c.metric_then)],
    ['ACTIONS', na(c.actions)],
    ['DRY RUNS', na(c.dry_runs)],
    ['SETTLED', na(c.settled)],
    ['MOVED', na(c.moved)],
    ['PRECISION', precisionText(c.precision)]
  ];
  return html`
    ${card && card.error ? html`<${ErrorBox} error=${card.error} onRetry=${card.reload}/>` : null}
    <dl class="lanekv">
      ${items.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${naSpan(v)}</dd>`)}
    </dl>
    <p style="color:var(--faint);margin:6px 0 0;overflow-wrap:anywhere">PRECISION is moved / settled lever actions in the window, not the ticket-verdict precision.</p>`;
}

export function AgentMetric({ agent }) {
  const card = useApi(() => fetchScorecard(agent), [agent], { intervalMs: POLL_MS });
  return html`<${AgentMetricView} card=${card}/>`;
}

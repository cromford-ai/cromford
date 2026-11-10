import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { laneSpendRows } from '../lib/lane-spend.js';
import { rosterRows, displayName } from '../lib/staff.js';
import { fmtUsdExact } from '../lib/spend.js';
import { laneSpendColumns } from './LaneSpend.js';

// BH-9127: COSTS filtered to one staff agent (/costs?agent=<name>), the target
// of the SPEND links on /staff and /staff/:agent. It reads the roster (the
// agent's spend_lanes and its today / 7D figures) and the lane spend in
// parallel, and shows the LANE SPEND rows of that agent's lanes only, in the
// same table as the unfiltered section below it. The agent's own heartbeat
// calls ride the shared `staff` lane: they are in its total, not a lane row.

// The worker's agent identity (lib/staff.js): checked before any request.
const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const agentName = (a) => {
  const s = typeof a === 'string' ? a.trim().toLowerCase() : '';
  return AGENT_RE.test(s) ? s : null;
};

const load = () => Promise.all([api.staffRoster(), api.laneSpend()]);

export function AgentLaneSpendSection({ agent }) {
  const name = agentName(agent);
  if (!name) return html`<${AgentLaneSpendView} agent=${agent} invalid=${true}/>`;
  return html`<${AgentLaneSpendLoader} agent=${name}/>`;
}

function AgentLaneSpendLoader({ agent }) {
  const a = useApi(load, [agent], { intervalMs: 60000 });
  return html`<${AgentLaneSpendView} agent=${agent} data=${a.data} error=${a.error} loading=${a.loading} reload=${a.reload}/>`;
}

const money = (v) => (typeof v === 'number' && Number.isFinite(v) ? fmtUsdExact(v) : 'n/a');

// data is [roster body, lane-spend body]. Pure: the tests render it.
export function AgentLaneSpendView({ agent, invalid = false, data = null, error = null, loading = false, reload = null }) {
  const label = String(agent || '').trim().toLowerCase();
  const title = invalid ? 'AGENT · LANE SPEND · TODAY (UTC)' : `${label.toUpperCase()} · LANE SPEND · TODAY (UTC)`;
  const all = html`<${Link} to="/costs">show all lanes<//>`;
  let body;
  if (invalid) body = html`<${Empty} title="not an agent name" note="the agent filter takes a staff agent name"/>`;
  else if (loading && !data) body = html`<${Skeleton} rows=${3} height=${20}/>`;
  else if (!data) body = html`<${ErrorBox} error=${error || new Error('the agent spend read returned nothing')} onRetry=${reload}/>`;
  else {
    const rr = rosterRows(data[0]);
    const row = rr && rr.rows.find((r) => r.name === label);
    if (!rr) body = html`<${ErrorBox} error=${new Error('the roster read returned no list')} onRetry=${reload}/>`;
    else if (!row) body = html`<${Empty} title=${`no agent ${label} on the roster`}/>`;
    else {
      const mine = new Set(Array.isArray(row.spend_lanes) ? row.spend_lanes : []);
      const lanes = data[1] && Array.isArray(data[1].lanes) ? data[1].lanes.filter((l) => mine.has(l.lane)) : [];
      const days = typeof row.spend_window_days === 'number' ? row.spend_window_days : 7;
      body = html`
        ${error ? html`<${ErrorBox} error=${error} onRetry=${reload}/>` : null}
        <div style="display:flex;flex-wrap:wrap;gap:4px 16px;margin-bottom:8px">
          <span>today ${money(row.spend_usd)}</span>
          <span>${days}D ${money(row.spend_usd_7d)}</span>
          <${Link} to=${`/staff/${encodeURIComponent(label)}`}>${displayName(label)}<//>
        </div>
        <p style="color:var(--faint);margin:0 0 6px;overflow-wrap:anywhere">
          ${mine.size ? `lanes: ${[...mine].join(', ')}. ` : 'no lanes of its own. '}The agent's own heartbeat calls ride the shared staff lane: they are in its total, not a row here.
        </p>
        <${SortableTable} wide columns=${laneSpendColumns} rows=${laneSpendRows({ lanes })} rowKey=${(r) => r.key}
          defaultSort="today" defaultDir="desc"
          empty=${html`<${Empty} title=${`no lane spend for ${label} today`}/>`}/>`;
    }
  }
  return html`<${Section} title=${title} right=${all}>${body}<//>`;
}

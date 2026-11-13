import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { agoFromMinutes, fmtNum } from '../lib/format.js';
import { fleetProjects } from '../lib/kanban.js';
import { utilizationRows, cellText, pauseAge, verdictRank } from '../lib/utilization.js';

// BH-4011 (BH-3988.3): is each project idle because nothing is ready, or
// paused, or blocked? One row per fleet.conf project from the newest hourly
// snapshot. The screen owns the reads; the view is a pure function of props so
// the tests render it server-side (the CiHealth split).
export function UtilizationScreen() {
  const util = useApi(() => api.utilization(), [], { intervalMs: 60000 });
  const fleet = useFleet();
  const projects = fleet && fleet.data ? fleetProjects(fleet.data.projects) : null;
  const [open, setOpen] = useState(null);
  return html`<${UtilizationView} util=${util} projects=${projects} open=${open}
    onOpen=${(p) => setOpen(open === p ? null : p)}/>`;
}

const WARN = new Set(['starved', 'blocked', 'paused']);
const tagClass = (v) => (WARN.has(v) ? 'tag tag--warn' : v === 'busy' || v === 'saturated' ? 'tag tag--plain' : 'tag tag--idle');
const note = (text) => html`<div class="footnote" style="margin-bottom:6px"><span style="color:var(--faint)">${text}</span></div>`;
const num = (key, label, title) => ({
  key, label, align: 'right', sort: (r) => r[key],
  cell: (r) => html`<span title=${title ? title(r) : undefined}>${cellText(r[key])}</span>`,
});

export function UtilizationView({ util, projects, open, onOpen, now = Date.now() }) {
  const columns = [
    { key: 'project', label: 'PROJECT', sort: (r) => r.project, cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>` },
    {
      key: 'verdict', label: 'VERDICT', sort: (r) => verdictRank(r.verdict),
      cell: (r) => html`<button type="button" class="btn btn--sm" title=${r.why} aria-expanded=${open === r.project ? 'true' : 'false'}
          onClick=${() => onOpen(r.project)}><span class=${tagClass(r.verdict)}>${r.verdict}</span></button>
        ${r.stale && r.snapshot ? html` <span class="tag tag--warn" title="snapshot older than 2h">stale</span>` : null}`
    },
    num('ready', 'READY'), num('blocked', 'BLOCKED'),
    num('held', 'HELD', (r) => (r.heldComplete === false ? 'capped at 30 reads, may be low' : undefined)),
    num('parked', 'PARKED'), num('running', 'RUNNING'), num('cap', 'CAP'), num('free', 'FREE'),
    {
      key: 'pauses', label: 'PAUSES', sort: (r) => (r.pauses ? r.pauses.length : null),
      cell: (r) => (r.pauses && r.pauses.length
        ? r.pauses.map((p) => html`<div style="white-space:nowrap">${p.name || p.kind || '?'} · ${pauseAge(p.since, now)}</div>`)
        : cellText(r.pauses ? 0 : null))
    },
    num('prReview', 'PRS REVIEW'), num('prCi', 'PRS CI'), num('prMq', 'PRS MQ'),
    {
      key: 'asOf', label: 'AS OF', sort: (r) => r.asOf,
      cell: (r) => (r.asOf ? html`<span title=${r.asOf}>${agoFromMinutes((now - Date.parse(r.asOf)) / 60000)}</span>` : '—')
    },
  ];

  const body = () => {
    if (!util || !(util.data || util.error)) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (util.error) return html`<${ErrorBox} error=${util.error} onRetry=${util.reload}/>`;
    const out = utilizationRows(util.data, projects, now);
    if (!out) return html`<${ErrorBox} error="unexpected answer from /api/utilization (no rows list)" onRetry=${util.reload}/>`;
    if (out.snapshots === 0) {
      return html`<${Empty} title="no utilization snapshot yet" note="the hourly lane writes the first one at :07"/>`;
    }
    const stale = out.rows.filter((r) => r.stale && r.snapshot).length;
    const row = open ? out.rows.find((r) => r.project === open) : null;
    return html`
      ${out.fleetUnread ? note('fleet list unread, showing the projects that have a snapshot') : null}
      ${out.extra.length ? note(`not in fleet.conf, not shown: ${out.extra.join(', ')}`) : null}
      ${stale ? note(`${fmtNum(stale)} row${stale === 1 ? '' : 's'} older than 2h: the hourly lane may have stopped`) : null}
      <${SortableTable} wide columns=${columns} rows=${out.rows} rowKey=${(r) => r.project}
        defaultSort="verdict" defaultDir="asc"/>
      ${row ? html`<${PayloadPanel} row=${row} now=${now}/>` : null}`;
  };

  const uo = util && util.data ? utilizationRows(util.data, projects, now) : null;
  return html`
    <${PageHeadline} chip="Utilization"
      line1=${uo ? `${fmtNum(uo.rows.length)} ${uo.rows.length === 1 ? 'project' : 'projects'}, ${fmtNum(uo.snapshots)} with a snapshot.` : util && util.error ? 'The utilization read failed.' : 'Reading the utilization snapshots.'}
      line2="How much of each project's capacity the last hour used."/>
    <${Section} title="UTILIZATION" note="newest hourly snapshot per fleet project; click a verdict for its payload">
      ${body()}
    <//>`;
}

const pauseColumns = (now) => [
  { key: 'kind', label: 'KIND', sort: (p) => p.kind, cell: (p) => cellText(p.kind) },
  { key: 'name', label: 'NAME', sort: (p) => p.name, cell: (p) => html`<span style="overflow-wrap:anywhere">${cellText(p.name)}</span>` },
  { key: 'since', label: 'SINCE', sort: (p) => p.since, cell: (p) => html`<span title=${p.since || undefined}>${pauseAge(p.since, now)}</span>` },
  { key: 'stopsBuilds', label: 'STOPS BUILDS', sort: (p) => p.stopsBuilds, cell: (p) => (p.stopsBuilds === null ? '—' : p.stopsBuilds ? 'yes' : 'no') },
];

function PayloadPanel({ row, now }) {
  return html`
    <${Section} title=${`PAYLOAD · ${row.project}`} note=${row.why}>
      ${!row.snapshot ? html`<${Empty} title=${`no snapshot for ${row.project} yet`}/>`
        : html`
          ${row.payloadError ? note(`payload ${row.payloadError}`) : null}
          ${row.pauses
            ? html`<${SortableTable} columns=${pauseColumns(now)} rows=${row.pauses} rowKey=${(p) => `${p.kind}|${p.name}`}
                empty=${html`<${Empty} title="no pauses"/>`}/>`
            : note('pauses unmeasured')}
          ${row.basis ? Object.entries(row.basis).map(([k, v]) => html`<div>${k}: ${String(v)}</div>`) : note('no basis recorded')}
          <div style="overflow-x:auto;margin-top:8px"><pre style="margin:0">${JSON.stringify(row.payload, null, 2)}</pre></div>`}
    <//>`;
}

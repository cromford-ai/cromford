import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { flyIdleDestroys, flyIdleHeadline, flyIdleRows, flyIdleStops } from '../lib/fly-idle.js';

const STATE_TAG = {
  over: 'tag tag--warn', stopping: 'tag tag--cyan', unknown: 'tag tag--dead', nosignal: 'tag tag--warn',
  idle: 'tag', busy: 'tag tag--green', exempt: 'tag tag--idle'
};

const ext = (href, text, cls = 'mono') => (href
  ? html`<a class=${cls} href=${href} target="_blank" rel="noopener noreferrer">${text}</a>`
  : html`<span class=${cls}>${text}</span>`);

const appCol = { key: 'app', label: 'APP', sort: (r) => r.app, cell: (r) => ext(r.appHref, r.app, 'cell-name') };
const machineCol = { key: 'machine', label: 'MACHINE', sort: (r) => r.machine_id, cell: (r) => ext(r.href, r.machine_id) };

// The FLY IDLE section of /machines (BH-6061): the last bin/fly-idle-reaper.sh
// pass's started machines and the stops it requested in the last 24 h.
// BH-6877: a LAST WORK column (sorted on the raw time) and the destroys of the
// last 24 h. Read-only. Each machine links to its Fly machine page, the only
// deeper record; a destroyed machine has none, so only its app links.
export function FlyIdlePanel() {
  const read = useApi(() => api.flyIdle(), [], { intervalMs: 60000 });
  const body = read.data;
  let content;
  if (!body && !read.error) {
    content = html`<${Skeleton} rows=${3} height=${18}/>`;
  } else if (read.error || !Array.isArray(body.machines) || !Array.isArray(body.stops)) {
    // A failed read, or a body without its arrays, is an error, never "nothing idle".
    content = html`<${ErrorBox} error=${read.error || new Error('no machines in the answer')} onRetry=${read.reload}/>`;
  } else {
    const rows = flyIdleRows(body);
    const stops = flyIdleStops(body);
    const destroys = flyIdleDestroys(body);
    content = html`
      <p class="section__note" style=${`margin:6px 0${body.pass && Number(body.pass.partial) > 0 ? ';color:var(--amber)' : ''}`}>
        ${flyIdleHeadline(body)}</p>
      <h3 class="section__note" style="margin:10px 0 4px">STARTED MACHINES</h3>
      <${SortableTable} wide
        columns=${[
          appCol,
          machineCol,
          { key: 'source', label: 'SOURCE', sort: (r) => r.source, cell: (r) => html`<span>${r.source}</span>` },
          {
            key: 'state', label: 'STATE', sort: (r) => r.state,
            cell: (r) => html`<span class=${STATE_TAG[r.state] || 'tag'}>${String(r.state || 'unknown').toUpperCase()}</span>`
          },
          { key: 'idle', label: 'IDLE', align: 'right', sort: (r) => r.idle_s, cell: (r) => html`<span>${r.idle}</span>` },
          { key: 'last_work', label: 'LAST WORK', sort: (r) => r.last_work_at, cell: (r) => html`<span>${r.last_work}</span>` },
          { key: 'limit', label: 'LIMIT', align: 'right', sort: (r) => r.threshold_s, cell: (r) => html`<span>${r.limit}</span>` },
          { key: 'usd', label: '$/H', align: 'right', sort: (r) => r.usd_per_hour, cell: (r) => html`<span>${r.usd}</span>` }
        ]}
        rows=${rows}
        rowKey=${(r) => r.key}
        defaultSort="idle" defaultDir="desc"
        empty=${html`<${Empty} title=${body.pass ? 'no started machines' : 'no reaper pass yet'}
          note=${body.pass ? 'The last pass found no started Fly machine.' : 'bin/fly-idle-reaper.sh has not reported a pass.'}/>`}/>
      <h3 class="section__note" style="margin:14px 0 4px">STOPS IN THE LAST 24 H · ${stops.total} stop${stops.total === 1 ? '' : 's'}
        · $${stops.saved_usd_per_hour_24h.toFixed(3)}/h saved${stops.unpriced ? ` · ${stops.unpriced} unpriced` : ''}</h3>
      <${SortableTable} wide
        columns=${[
          { key: 'time', label: 'TIME', sort: (r) => r.stopped_at, cell: (r) => html`<span>${r.time}</span>` },
          appCol,
          machineCol,
          { key: 'size', label: 'SIZE', sort: (r) => r.size, cell: (r) => html`<span>${r.size}</span>` },
          { key: 'idle', label: 'IDLE AT STOP', align: 'right', sort: (r) => r.idle_s, cell: (r) => html`<span>${r.idle}</span>` },
          { key: 'usd', label: '$/H SAVED', align: 'right', sort: (r) => r.usd_per_hour, cell: (r) => html`<span>${r.usd}</span>` }
        ]}
        rows=${stops.rows}
        rowKey=${(r) => r.key}
        defaultSort="time" defaultDir="desc"
        empty=${html`<${Empty} title="no stops in the last 24 h" note="The reaper requested no stop in this window."/>`}/>
      ${stops.truncated
        ? html`<p class="section__note" style="margin:6px 0 0">showing the newest ${stops.rows.length} of ${stops.total}; the $/h sum covers the shown rows</p>`
        : null}
      ${destroys.available
        ? html`
      <h3 class="section__note" style="margin:14px 0 4px">DESTROYED (24 H) · ${destroys.count} destroy${destroys.count === 1 ? '' : 's'}
        · restart $${destroys.usd_per_hour.toFixed(3)}/h${destroys.unpriced ? ` · ${destroys.unpriced} unpriced` : ''}</h3>
      <${SortableTable} wide
        columns=${[
          { key: 'time', label: 'TIME', sort: (r) => r.destroyed_at, cell: (r) => html`<span>${r.time}</span>` },
          appCol,
          { key: 'machine', label: 'MACHINE', sort: (r) => r.machine_id, cell: (r) => html`<span class="mono">${r.machine_id}</span>` },
          { key: 'size', label: 'SIZE', sort: (r) => r.size, cell: (r) => html`<span>${r.size}</span>` },
          { key: 'stopped', label: 'STOPPED FOR', align: 'right', sort: (r) => r.stopped_s, cell: (r) => html`<span>${r.stopped}</span>` },
          { key: 'usd', label: 'RESTART $/H', align: 'right', sort: (r) => r.usd_per_hour, cell: (r) => html`<span>${r.usd}</span>` }
        ]}
        rows=${destroys.rows}
        rowKey=${(r) => r.key}
        defaultSort="time" defaultDir="desc"
        empty=${html`<${Empty} title="no destroys in the last 24 h" note="The reaper requested no destroy in this window."/>`}/>
      ${destroys.truncated
        ? html`<p class="section__note" style="margin:6px 0 0">showing the newest ${destroys.rows.length} of ${destroys.count}; the restart $/h sum covers the shown rows</p>`
        : null}`
        : html`<p class="section__note" style="margin:14px 0 0">destroy list not available: ${destroys.error || 'the worker did not send it'}</p>`}`;
  }
  return html`<${Section} title="FLY IDLE" note="started Fly machines and idle stops, from the fly-idle-reaper lane">${content}<//>`;
}

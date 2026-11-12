import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { hotspotCells, panelNote, HOTSPOTS_SHOWN } from '../lib/conflict-hotspots-panel.js';
import { fmtNum } from '../lib/format.js';

const num = (v) => (v === null || v === undefined || v === '' ? '—' : v);

// The CONFLICT HOTSPOTS section on /p/<project> (BH-5267): the files that
// conflicted or were rebased most in the window bin/conflict-hotspots-fleet.sh
// last measured on this project's box. Read-only: each #N links to its PR page,
// the file to its GitHub history at the measured sha when the run named both.
export default function ConflictHotspotsPanel({ project }) {
  const read = useApi(() => api.conflictHotspots(project, HOTSPOTS_SHOWN), [project]);
  if (!read.data && !read.error) return html`<${Skeleton} rows=${3} height=${18}/>`;
  // A failed read, or a body without its hotspots array, is an error, never an
  // empty table and never "not measured yet".
  const hotspots = read.data && read.data.hotspots;
  if (read.error || !Array.isArray(hotspots)) {
    return html`<${ErrorBox} error=${read.error || new Error('no hotspots in the answer')} onRetry=${read.reload}/>`;
  }

  const run = read.data.run || null;
  const note = panelNote(run);
  const failed = run && run.status !== 'ok';
  const noteLine = html`<p class="section__note" style=${`margin:6px 0${failed ? ';color:var(--amber)' : ''}`}>${note}</p>`;

  if (!hotspots.length) {
    // No good window at all is "not measured", whatever the latest run did; a
    // good window with nothing in it is "no hotspots".
    const measured = run && (run.status === 'ok' || run.last_ok_at);
    return measured
      ? html`<${Empty} title="NO HOTSPOTS" note=${note}/>`
      : html`<${Empty} title="NOT MEASURED YET" note=${note}/>`;
  }

  const rows = hotspots.map((r) => ({ ...r, cells: hotspotCells(r, project, run) }));
  const columns = [
    { key: 'file', label: 'FILE', flex: true, cell: (r) => (r.cells.fileHref
      ? html`<a class="mono cell-wrap" href=${r.cells.fileHref} target="_blank" rel="noopener noreferrer">${r.file}</a>`
      : html`<span class="mono cell-wrap">${r.file}</span>`) },
    { key: 'conflicts', label: 'CONFLICTS', align: 'right', cell: (r) => num(r.conflicts) },
    { key: 'rebases', label: 'REBASES', align: 'right', cell: (r) => num(r.rebases) },
    { key: 'prs', label: 'PRS', sort: (r) => r.cells.prs.map((p) => p.label).join(', '), cell: (r) => {
      const prs = r.cells.prs;
      if (!prs.length) return '—';
      return html`<span class="cell-wrap">${prs.map((p, i) => html`
        ${i ? ', ' : ''}${p.href ? html`<${Link} key=${p.label} to=${p.href}>${p.label}<//>` : html`<span class="mono">${p.label}</span>`}`)}</span>`;
    } }
  ];
  const total = Number(read.data.total);
  return html`
    <div>
      ${noteLine}
      <${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.file} wide
        defaultSort="conflicts" defaultDir="desc"/>
      ${read.data.truncated
        ? html`<p class="section__note" style="margin:6px 0 0">${Number.isFinite(total) && total > 0
          ? `showing ${fmtNum(rows.length)} of ${fmtNum(total)}` : `showing the top ${fmtNum(rows.length)}; more files exist`}</p>`
        : null}
    </div>`;
}

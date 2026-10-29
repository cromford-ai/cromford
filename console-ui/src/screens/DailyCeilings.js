import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { dailyCeilingRows, dailyWarnPct, withSpend } from '../lib/daily-ceilings.js';

// BH-7876: the DAILY CEILINGS table on /costs, under CAPS. It takes the CAPS
// section's settings read (no second settings fetch) and reads every ceiling
// project's spend for the UTC day in one Promise.all. Display only: a ceiling
// is set with `bin/jobs-client.sh setting-set conf.cost-caps.<p>.daily_usd`.

// loadDaySpend(projects, fetchSpend) -> { [project]: answer | { error } }.
// One read per distinct project, all at once; a failure stays with its project.
export async function loadDaySpend(projects, fetchSpend = (p) => api.llmSpend(p)) {
  const uniq = [...new Set(projects)];
  const answers = await Promise.all(uniq.map((p) => fetchSpend(p).then(
    (a) => a,
    (e) => ({ error: (e && e.message) || 'read failed' }))));
  return Object.fromEntries(uniq.map((p, i) => [p, answers[i]]));
}

export function DailyCeilingsSection({ settings }) {
  const list = settings && settings.data && settings.data.settings;
  const projects = dailyCeilingRows(list).rows.filter((r) => r.ceiling !== null).map((r) => r.project).sort();
  const spend = useApi(() => loadDaySpend(projects), [projects.join(',')], { intervalMs: 60000 });
  return html`<${DailyCeilingsView} settings=${settings} spend=${spend}/>`;
}

const money = (v) => (v === null || v === undefined ? '—' : `$${Number(v).toFixed(2)}`);
const STATE_COLOR = { over: 'var(--red)', warn: 'var(--amber)', unknown: 'var(--faint)', unreadable: 'var(--faint)' };

export const ceilingColumns = [
  {
    key: 'project', label: 'PROJECT', sort: (r) => r.project,
    cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>${r.box
      ? html` <span style="color:var(--faint)">· box ${r.box}</span>` : null}`,
  },
  {
    key: 'ceiling', label: 'CEILING', unit: '$', sort: (r) => r.ceiling,
    cell: (r) => (r.ceiling === null ? html`<span title="the harness refuses this value">${r.raw} (refused)</span>` : `$${r.ceiling}`),
  },
  { key: 'spent', label: 'TODAY (UTC)', unit: '$', sort: (r) => r.spent, cell: (r) => money(r.spent) },
  { key: 'pct', label: 'USED', unit: '%', sort: (r) => r.pct, cell: (r) => (r.pct === null ? '—' : `${r.pct}%`) },
  {
    key: 'state', label: 'STATE', sort: (r) => r.state,
    cell: (r) => html`<span style=${STATE_COLOR[r.state] ? `color:${STATE_COLOR[r.state]}` : ''}
      title=${r.error || r.asOf || ''}>${r.state}</span>`,
  },
];

export function DailyCeilingsView({ settings, spend }) {
  const list = settings && settings.data && settings.data.settings;
  const { rows, unreadable } = dailyCeilingRows(list);

  const body = () => {
    if (settings && settings.loading && !(settings.data)) return html`<${Skeleton} rows=${2} height=${20}/>`;
    if (unreadable) {
      return html`<${ErrorBox} error=${(settings && settings.error) || new Error('the settings read returned no list')}
        onRetry=${settings && settings.reload}/>`;
    }
    if (rows.length && spend && spend.loading && !spend.data) return html`<${Skeleton} rows=${rows.length} height=${20}/>`;
    const out = withSpend(rows, (spend && spend.data) || {}, dailyWarnPct(list));
    return html`<${SortableTable} columns=${ceilingColumns} rows=${out} rowKey=${(r) => r.key} defaultSort="project"
      empty=${html`<${Empty} title="no daily ceilings set"/>`}/>`;
  };

  return html`
    <${Section} title="DAILY CEILINGS" note="conf.cost-caps.<project>.daily_usd: no new build at 100% until 00:00Z; hotfixes still run">
      ${body()}
    <//>`;
}

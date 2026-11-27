import { useEffect } from 'preact/hooks';
import { html, Link, useSearchParam, navigate, currentSearch } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { Clock } from '../ui/icons.js';
import { whenLabel, fmtNum } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { commandRows, commandTarget, filterCommands, facetValues, FILTER_KEYS } from '../lib/commands.js';
import { withPeriod } from '../lib/period.js';
import { PeriodPicker } from '../ui/PeriodPicker.js';
import { useLogPeriod, logHref, logCsvHref, logPollMs, LogToolbar, LogReportPanel } from '../lib/log-period.js';
import { report as commandsReport } from './period-report.d/commands.js';

// HISTORY → COMMANDS (BH-2514): every console and chat command the worker
// still returns from GET /api/dash/commands, newest first, with who sent it,
// what became of it and a link to what it acted on. It reads the latest LIMIT
// rows and no more, so the sort headers and the filters work on those rows and
// the footnote says so.
//
// BH-9308 (BH-9120.4): the screen reads one period (the URL's, else the knob
// default) through GET /api/cockpit/commands: created_at in [from, to), a
// search (?q= over the key, type, project, payload and result), type /
// project / status filters on the server, the CSV of the whole filter and the
// period report. It reads the newest LIMIT rows of that period; the header
// sorts and the actor filter work on those rows. loadCommands (the dash list)
// stays for its other callers.

export const LIMIT = 200;
export const loadCommands = () => api.commands(LIMIT);
const POLL_MS = 30000;

const DEAD = new Set(['dead_letter', 'failed', 'refused']);
// The statuses whose key alone does not say what happened; the rest read fine
// once the underscores go (plainLabel).
const STATUS_WORDS = { pending: 'waiting to run', claimed: 'picked up', dead_letter: 'gave up after retries' };
const statusWords = (s) => STATUS_WORDS[s] || plainLabel(s);
const statusClass = (s) => (DEAD.has(s) ? 'tag tag--dead' : s === 'done' ? 'tag tag--green' : 'tag tag--idle');
const na = html`<span class="na">—</span>`;

export function CommandHistoryScreen() {
  const filters = {
    type: useSearchParam('type'),
    status: useSearchParam('status'),
    project: useSearchParam('project'),
    actor: useSearchParam('actor'),
    id: useSearchParam('id')
  };
  const q = useSearchParam('q');
  const reportOpen = useSearchParam('report') === '1';
  const { period, knobs } = useLogPeriod();
  const from = period ? period.from : null;
  const to = period ? period.to : null;
  const state = useApi(() => (from
    ? api.periodGet('/api/cockpit/commands', {
      from, to, keep: { type: filters.type, project: filters.project, status: filters.status, q, limit: LIMIT }
    })
    : new Promise(() => {})), [from, to, filters.type, filters.project, filters.status, q],
  { intervalMs: logPollMs(period, Date.now(), POLL_MS) });

  // Every other param (the period, the search) stays; BH-9308.
  const setFilter = (key, value) => navigate(logHref('/history/commands', currentSearch(), { [key]: value }));

  // A ?id= link (a retry_command's target) lands on its row once it is loaded.
  useEffect(() => {
    if (!filters.id || !state.data) return;
    const el = document.getElementById(`cmd-${filters.id}`);
    if (el) el.scrollIntoView({ block: 'center' });
  }, [filters.id, state.data]);

  return html`
    <div class="page">
      <${PageHeadline} chip="Commands"
        line1=${state.data && Array.isArray(state.data.commands) ? `${fmtNum(state.data.commands.length)} ${state.data.commands.length === 1 ? 'command' : 'commands'} on record.` : state.error ? 'The commands read failed.' : 'Reading the commands.'}
        line2="Who sent each one, and what became of it."/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/now" class="crumb">← NOW<//>
        <span class="crumb-sep">/</span>
        <span style="font-size:var(--fs-sm);color:var(--faint)">
          every command sent from the console or chat, who sent it and what became of it.
        </span>
      </div>

      <div class="tabs">
        <${Link} to=${withPeriod('/history', currentSearch())} class="tab">RUNS<//>
        <${Link} to="/history?tab=builds" class="tab">BUILDS<//>
        <span class="tab tab--on" aria-current="page">COMMANDS</span>
      </div>

      <${PeriodPicker} period=${period} knobs=${knobs}/>
      <${LogToolbar} path="/history/commands" search=${currentSearch()} placeholder="search key, type, project, payload or result"
        csv=${period ? logCsvHref('/api/cockpit/commands', period, { type: filters.type, project: filters.project, status: filters.status, q }) : null}/>
      ${reportOpen && period ? html`<${LogReportPanel} report=${commandsReport} period=${period} knobs=${knobs}/>` : null}

      <${CommandHistoryView} state=${state} filters=${filters} setFilter=${setFilter} source="/api/cockpit/commands"/>
    </div>`;
}

// The body, split from the hooks so every load state renders under test.
// `source` names the read in the malformed-body error (the screen's is the
// cockpit period route).
export function CommandHistoryView({ state, filters, setFilter, source = '/api/dash/commands' }) {
  if (state.error && !state.data) return html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>`;
  if (!state.data) return html`<${Skeleton} rows=${8} height=${20}/>`;

  const { rows, malformed } = commandRows(state.data);
  if (malformed) {
    return html`<${ErrorBox} error=${`unexpected response from ${source}`} onRetry=${state.reload}/>`;
  }

  const shown = filterCommands(rows, filters);
  const active = FILTER_KEYS.filter((k) => filters[k]);
  const chip = (label, on, onClick) => html`
    <button type="button" class=${on ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;
  const idN = filters.id ? Number(filters.id) : null;
  const idLoaded = idN !== null && rows.some((r) => Number(r.id) === idN);

  return html`
    <div style="display:flex;flex-direction:column;gap:14px">
      ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}

      <${Section} title="FILTERS" note="filters live in the URL, so a filtered view is a link you can send">
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ANY TYPE', !filters.type, () => setFilter('type', null))}
          ${facetValues(rows, 'type').map((t) => chip(t, filters.type === t, () => setFilter('type', t)))}
        </div>
        <div class="tabs">
          ${chip('ANY STATUS', !filters.status, () => setFilter('status', null))}
          ${facetValues(rows, 'status').map((s) => chip(s, filters.status === s, () => setFilter('status', s)))}
        </div>
        ${active.length ? html`
          <div class="tabs" style="margin-top:8px">
            ${active.map((k) => html`
              <button type="button" class="tab tab--on" title="remove this filter"
                onClick=${() => setFilter(k, null)}>${k}: ${filters[k]} ×</button>`)}
          </div>` : null}
      <//>

      ${idN !== null && !idLoaded ? html`
        <div class="banner"><span>command #${filters.id} is older than the loaded window</span></div>` : null}

      <${Section} title="COMMANDS" note=${`${fmtNum(shown.length)} of ${fmtNum(rows.length)} loaded${
        state.data.totals ? ` · ${fmtNum(Number(state.data.totals.total) || 0)} in this period` : ''} · newest first`}>
        ${rows.length
          ? html`<${CommandsTable} rows=${shown} highlight=${idN} setFilter=${setFilter}
              empty=${html`<${Empty} title="NO COMMAND MATCHES THESE FILTERS"
                note="no command matches these filters in the loaded rows."/>`}/>`
          : html`<${Empty} title="NO COMMANDS" note="no console or chat command on record."/>`}
        <div class="footnote">
          <${Clock}/>
          <span>latest ${fmtNum(rows.length)} commands the console returned · sorting and filters apply to these rows only${rows.length >= LIMIT ? ' · older commands are not shown' : ''}</span>
        </div>
      <//>
    </div>`;
}

export function CommandsTable({ rows, highlight = null, setFilter = null, empty = null, nowMs = Date.now() }) {
  const filterBtn = (key, value) => (setFilter
    ? html`<button type="button" class="btn btn--sm" title=${`show only ${key} ${value}`}
        onClick=${() => setFilter(key, value)}>=</button>` : null);

  const columns = [
    { key: 'id', label: '#', sort: (r) => Number(r.id), align: 'right',
      cell: (r) => html`<span class="num" id=${`cmd-${r.id}`}>${r.id}</span>` },
    { key: 'when', label: 'WHEN', sort: (r) => r.createdAt || '',
      cell: (r) => (r.createdAt
        ? html`<span title=${r.createdAt}>${whenLabel(r.createdAt, nowMs)}</span>` : na) },
    { key: 'type', label: 'TYPE', sort: (r) => r.type || '',
      cell: (r) => html`<span class="tag tag--idle">${r.type || '—'}</span>` },
    { key: 'project', label: 'PROJECT', sort: (r) => r.project || '',
      cell: (r) => (r.project
        ? html`<span style="white-space:nowrap"><${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>
            ${' '}${filterBtn('project', r.project)}</span>` : na) },
    { key: 'actor', label: 'ACTOR', sort: (r) => r.actor || '',
      cell: (r) => (r.actor
        ? html`<span style="white-space:nowrap">${r.actor} ${filterBtn('actor', r.actor)}</span>` : na) },
    { key: 'status', label: 'STATUS', sort: (r) => r.status || '',
      cell: (r) => (r.status ? html`<span class=${statusClass(r.status)} title=${r.status}>${statusWords(r.status)}</span>` : na) },
    { key: 'outcome', label: 'OUTCOME', sort: (r) => r.outcome || '',
      cell: (r) => (r.outcome
        ? html`<span class="cell-wrap" title=${r.outcome}>${r.outcome.length > 120 ? `${r.outcome.slice(0, 120)}…` : r.outcome}</span>`
        : na) },
    { key: 'target', label: 'TARGET', sort: (r) => commandTarget(r)?.label || '',
      cell: (r) => {
        const t = commandTarget(r);
        return t ? html`<${Link} to=${t.to}>${t.label}<//>` : na;
      } }
  ];

  return html`<${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id} wide=${true}
    rowClass=${(r) => [DEAD.has(r.status) ? 'row--dead' : '', highlight !== null && Number(r.id) === highlight ? 'row--hl' : '']
      .filter(Boolean).join(' ')}
    defaultSort="when" defaultDir="desc" empty=${empty}/>`;
}

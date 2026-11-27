// The log screens' period helpers (BH-9308, BH-9120.4): JOBS, LANES, HISTORY
// and COMMAND LOG. Only these four screens use this file. The period itself
// (from, to, bucket, compare) is the contract's (src/lib/period.js); this file
// adds what a log screen needs on top of it: a search and column filters in
// the URL, a CSV link of the whole filter, a poll that stops when the range
// ended, and the in-place "Period report" panel that reads a
// period-report.d seam.
//
// Every filter lives in the URL, so a filtered view is a link someone can
// send, and a reload keeps it. The server escapes the search (`%` and `_` are
// literal); nothing here builds SQL.

import { useState, useEffect, useRef } from 'preact/hooks';
import { html, Link, navigate, useSearchParam, currentSearch } from '../router.js';
import { api } from '../api.js';
import { useApi } from './hooks.js';
import { csvHref, pickBucket, parsePeriodQuery, defaultPeriod } from './period.js';
import { SortableTable } from '../ui/SortableTable.js';
import { PeriodChart } from '../ui/PeriodChart.js';
import { Section, Stat, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';

// The URL keys each screen reads besides the period.
export const LOG_KEYS = Object.freeze({
  jobs: ['q', 'project', 'lane', 'status', 'sort', 'dir'],
  lanes: ['q', 'project', 'lane', 'machine', 'status', 'sort', 'dir'],
  history: ['q', 'project', 'kind', 'outcome'],
  commands: ['q', 'type', 'project', 'status', 'actor', 'id']
});

// readLogParams(search, keys) -> {key: value or null} for exactly `keys`. An
// empty value is null.
export function readLogParams(search, keys) {
  const sp = new URLSearchParams(search || '');
  const out = {};
  for (const k of keys) {
    const v = sp.get(k);
    out[k] = v === null || v === '' ? null : v;
  }
  return out;
}

// logHref(path, search, changes) -> `path?...`: every param of `search` (the
// period and the other filters) with `changes` applied. A change to null or ''
// removes that key. A cursor never survives a filter change: it points into
// the old result.
export function logHref(path, search, changes = {}) {
  const sp = new URLSearchParams(search || '');
  sp.delete('cursor');
  for (const [k, v] of Object.entries(changes)) {
    if (v === null || v === undefined || v === '') sp.delete(k);
    else sp.set(k, String(v));
  }
  const qs = sp.toString();
  return `${path}${qs ? `?${qs}` : ''}`;
}

// The filters that have a value, as a plain object.
const present = (filters) => Object.fromEntries(Object.entries(filters || {})
  .filter(([, v]) => v !== null && v !== undefined && v !== ''));

// The CSV of the whole filter: the contract's csvHref (period + format=csv)
// with the filters kept. The worker writes every row up to mc.period.csv_row_cap.
export function logCsvHref(apiPath, period, filters) {
  return csvHref(apiPath, { ...(period || {}), keep: present(filters) });
}

// The bucket a report series asks for: the period's own, or one picked from
// the range length when it is 'auto'.
export function seriesBucket(period, nowMs) {
  if (period && ['hour', 'day', 'week'].includes(period.bucket)) return period.bucket;
  const to = period && period.to ? Date.parse(period.to) : nowMs;
  return pickBucket(to - Date.parse(period.from));
}

// 0 (no poll) when the range ended; else the screen's own interval. A past
// range does not change, so reading it again is a cost with no news.
export function logPollMs(period, nowMs, ms) {
  return period && period.to && Date.parse(period.to) <= nowMs ? 0 : ms;
}

// The code fallbacks of the log screens' row caps. Each is the value of its
// settings row and is used only when the knob read failed or the row is not
// valid: mc.period.report_top_rows (the period report's top rows, sent as
// limit) and mc.period.filter_chip_cap (the LANE / PROJECT filter chips).
export const LOG_KNOB_FALLBACKS = Object.freeze({ report_top_rows: 20, filter_chip_cap: 30 });

// logKnob(knobs, name) -> the knob's positive integer from api.periodKnobs,
// else its LOG_KNOB_FALLBACKS value.
export function logKnob(knobs, name) {
  const v = knobs ? knobs[name] : undefined;
  return Number.isInteger(v) && v > 0 ? v : LOG_KNOB_FALLBACKS[name];
}

// chipValues(rows, key, knobs) -> the distinct non-empty `key` values of the
// loaded rows, sorted, at most mc.period.filter_chip_cap of them.
export function chipValues(rows, key, knobs) {
  return [...new Set((rows || []).map((r) => r[key]).filter(Boolean))].sort()
    .slice(0, logKnob(knobs, 'filter_chip_cap'));
}

// The period of a log screen: the URL's, else the mc.period.default_preset
// knob's (a failed knob read uses the code fallback and never holds the
// screen). Null only while the knob read is in flight and the URL has none.
export function useLogPeriod() {
  useSearchParam('from');
  useSearchParam('to');
  useSearchParam('bucket');
  const urlPeriod = parsePeriodQuery(currentSearch());
  const knobs = useApi(() => api.periodKnobs(), []);
  const values = knobs.data && knobs.data.knobs;
  const period = urlPeriod || (knobs.loading ? null : defaultPeriod(values, Date.now()));
  return { period, knobs: values };
}

// Page 1 of a cursor-paged read (polled at `intervalMs`) plus the pages a
// "Load more" click appended. `fetchPage(cursor)` returns the route's body;
// `rowsKey` names its rows array. A deps change starts over at page 1. Rows
// are de-duplicated by id when a refreshed page 1 overlaps a loaded page.
export function useCursorPages(fetchPage, deps, rowsKey, intervalMs = 0) {
  const first = useApi(() => fetchPage(null), deps, { intervalMs });
  const key = JSON.stringify(deps);
  const [more, setMore] = useState({ key, rows: [], cursor: undefined, loading: false, error: null });
  const cur = more.key === key ? more : { key, rows: [], cursor: undefined, loading: false, error: null };
  const firstRows = first.data && Array.isArray(first.data[rowsKey]) ? first.data[rowsKey] : [];
  const cursor = cur.cursor !== undefined ? cur.cursor : (first.data ? first.data.next_cursor || null : null);
  const seen = new Set(firstRows.map((r) => r.id));
  const rows = [...firstRows, ...cur.rows.filter((r) => !seen.has(r.id))];
  const loadMore = async () => {
    if (!cursor || cur.loading) return;
    setMore({ ...cur, loading: true, error: null });
    try {
      const d = await fetchPage(cursor);
      setMore({ key, rows: [...cur.rows, ...(d[rowsKey] || [])], cursor: d.next_cursor || null, loading: false, error: null });
    } catch (e) {
      setMore({ ...cur, loading: false, error: e });
    }
  };
  return { first, rows, cursor, loadMore, moreLoading: cur.loading, moreError: cur.error };
}

// The search box, the filter chips, the CSV link and the report toggle.
//   filters: [{key, any, values: [value | {value, label}]}] — one chip row each
//   csv:     the href of the CSV, or null
export function LogToolbar({ path, search, filters = [], csv = null, placeholder = 'search' }) {
  const sp = new URLSearchParams(search || '');
  const q = sp.get('q') || '';
  const [text, setText] = useState(q);
  useEffect(() => setText(q), [q]);
  // The box's own value, not the state: a submit right after a keystroke
  // must not send the text from before it.
  const box = useRef(null);
  const submit = (e) => {
    e.preventDefault();
    const v = box.current && typeof box.current.value === 'string' ? box.current.value : text;
    navigate(logHref(path, search, { q: v.trim() || null }));
  };
  const reportOpen = sp.get('report') === '1';
  const chip = (label, on, to) => html`
    <${Link} to=${to} class=${on ? 'tab tab--on' : 'tab'} aria-current=${on ? 'true' : undefined}>${label}<//>`;
  return html`
    <div class="log-toolbar" style="display:flex;flex-direction:column;gap:8px;margin:10px 0">
      <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center">
        <form role="search" onSubmit=${submit} style="display:flex;gap:6px;flex:1 1 220px;min-width:0">
          <input ref=${box} class="knob__input" type="search" name="q" aria-label="search this period"
            placeholder=${placeholder} value=${text} style="flex:1;min-width:0"
            onInput=${(e) => setText(e.target.value)}/>
          <button type="submit" class="btn btn--sm">SEARCH</button>
        </form>
        ${csv ? html`<a class="btn btn--sm" href=${csv} download>Download CSV</a>` : null}
        ${chip('Period report', reportOpen, logHref(path, search, { report: reportOpen ? null : '1' }))}
      </div>
      ${filters.map((f) => {
        const cur = sp.get(f.key);
        return html`<div class="tabs" key=${f.key} style="flex-wrap:wrap">
          ${chip(f.any, !cur, logHref(path, search, { [f.key]: null }))}
          ${f.values.map((v) => {
            const value = typeof v === 'object' ? v.value : v;
            const label = typeof v === 'object' ? v.label : v;
            return chip(label, cur === value, logHref(path, search, { [f.key]: value }));
          })}
        </div>`;
      })}
    </div>`;
}

const label = (k) => k.toUpperCase().replace(/_/g, ' ');

// The in-place period report: the seam's totals, its series as a PeriodChart,
// its top rows and a Print button. "no data for this period" only when the
// read succeeded and the total is 0; a failed read is the ErrorBox.
// `knobs` (api.periodKnobs) reaches the seam's load as its third argument, for
// mc.period.report_top_rows.
export function LogReportPanel({ report, period, knobs = null }) {
  const state = useApi(() => report.load(api, period, knobs),
    [report.title, period.from, period.to, period.bucket, logKnob(knobs, 'report_top_rows')]);
  let body;
  if (state.error && !state.data) body = html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>`;
  else if (!state.data) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else {
    const { totals = {}, series = [], topRows = [], columns = [], rowHref = null } = state.data;
    if (!Number(totals.total)) {
      body = html`<${Empty} title="no data for this period" note="nothing was recorded in this range."/>`;
    } else {
      const cols = columns.map((c, i) => ({
        key: c, label: label(c), plain: c === 'id',
        cell: (r) => (i === 0 && rowHref ? html`<${Link} to=${rowHref(r)} class="cell-name">${r[c]}<//>`
          : (r[c] === null || r[c] === undefined ? '—' : r[c]))
      }));
      body = html`
        <div class="stats">
          ${Object.entries(totals).map(([k, v]) => html`<${Stat} key=${k} label=${label(k)} value=${Number(v) || 0}/>`)}
        </div>
        <${PeriodChart} series=${series} bucket=${seriesBucket(period, Date.now())}/>
        <${SortableTable} columns=${cols} rows=${topRows} rowKey=${(r) => r.id} wide=${true}/>`;
    }
  }
  return html`
    <${Section} title=${`PERIOD REPORT · ${report.title}`} note=${`${period.from} to ${period.to || 'now'} (UTC)`}
      right=${html`<button type="button" class="btn btn--sm" onClick=${() => window.print()}>Print</button>`}>
      ${body}
    <//>`;
}

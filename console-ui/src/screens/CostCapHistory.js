import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { usePolledApi } from '../lib/poll.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { clockTime, fmtNum } from '../lib/format.js';
import { changeRows } from '../lib/cost-cap-changes.js';

// BH-2567 (BH-2511.4): the Costs page's CAP HISTORY section, mounted on /costs
// directly below CAPS. It reads the cap change log from
// GET /api/coord/cost-cap-changes on mount and on a light poll, so an edit made
// in CAPS shows up here without the two sections knowing about each other.
// Clicking a KEY re-reads the log for that key only.

export const LIMIT = 200;
export const POLL_MS = 30000;

// The answer carries the key it was asked for, so a late answer for the
// previous filter is never shown under the new one.
export const loadChanges = (key) =>
  api.costCapChanges({ key: key || undefined, limit: LIMIT }).then((res) => ({ key: key || null, res }));

const na = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? na : String(v));

export function CostCapHistorySection() {
  const [key, setKey] = useState(null);
  const state = usePolledApi(() => loadChanges(key), [key], { intervalMs: POLL_MS });
  return html`<${CostCapHistoryView} state=${state} filterKey=${key}
    onFilter=${setKey} onClear=${() => setKey(null)} onRetry=${state.reload}/>`;
}

// The body, split from the hooks so every load state renders under test.
export function CostCapHistoryView({ state, filterKey = null, onFilter, onClear, onRetry }) {
  const forThisKey = state.data && state.data.key === (filterKey || null);

  let body;
  if (!forThisKey) {
    body = state.error
      ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`
      : html`<${Skeleton} rows=${4} height=${18}/>`;
  } else {
    const { rows, truncated, malformed } = changeRows(state.data.res);
    if (malformed) {
      body = html`<${ErrorBox} error=${'unexpected response from /api/coord/cost-cap-changes'} onRetry=${onRetry}/>`;
    } else {
      body = html`
        ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>` : null}
        ${rows.length
          ? html`<${ChangesTable} rows=${rows} onFilter=${onFilter}/>`
          : html`<${Empty} title=${filterKey ? `no cap changes for ${filterKey} yet` : 'no cap changes yet'}/>`}
        ${truncated ? html`
          <div class="footnote"><span style="color:var(--faint)">showing the newest ${fmtNum(rows.length)}</span></div>` : null}`;
    }
  }

  return html`
    <${Section} title="CAP HISTORY" note="every cap edit, newest first">
      ${filterKey ? html`
        <div style="display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px">
          <span class="tag tag--idle">key: ${filterKey}</span>
          <button type="button" class="btn btn--sm" onClick=${onClear}>clear filter</button>
        </div>` : null}
      ${body}
    <//>`;
}

function ChangesTable({ rows, onFilter }) {
  const columns = [
    { key: 'at', label: 'WHEN', sort: (r) => r.at || '',
      cell: (r) => (r.at
        ? html`<span title=${r.at} style="white-space:nowrap">${String(r.at).slice(0, 10)} ${clockTime(r.at)}</span>` : na) },
    { key: 'key', label: 'KEY', sort: (r) => r.key || '',
      cell: (r) => html`<button type="button" class="cell-name" title=${`show only ${r.key}`}
        style="background:none;border:0;padding:0;font:inherit;cursor:pointer;text-align:left"
        onClick=${() => onFilter(r.key)}>${r.key}</button>` },
    { key: 'before_value', label: 'BEFORE', sort: (r) => r.before_value ?? '', cell: (r) => orNa(r.before_value) },
    { key: 'after_value', label: 'AFTER', sort: (r) => r.after_value ?? '', cell: (r) => orNa(r.after_value) },
    { key: 'actor', label: 'ACTOR', sort: (r) => r.actor || '', cell: (r) => orNa(r.actor) },
    { key: 'reason', label: 'REASON', sort: (r) => r.reason || '',
      cell: (r) => (r.reason ? html`<span class="cell-wrap">${r.reason}</span>` : na) }
  ];
  return html`<${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id} wide=${true}
    defaultSort="at" defaultDir="desc"/>`;
}

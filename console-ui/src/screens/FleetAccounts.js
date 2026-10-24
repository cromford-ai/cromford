// ACCOUNTS ON THE FLEET (BH-7966, BH-7937.2): every AI account an operator
// added, on the Settings hub tab under PROJECT ACCOUNTS. One read
// (GET /api/coord/ai-accounts); the worker joins the projects, today's spend,
// the boxes and the state. + ADD ACCOUNT and ROTATE open the add sheet.

import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { UsdCell } from '../ui/UsdCell.js';
import { AiAccountSheet } from './AiAccountSheet.js';

const STATE_TAG = { active: 'tag tag--green', pending: 'tag', failed: 'tag tag--bad', expired: 'tag tag--warn', revoked: 'tag tag--idle', unknown: 'tag tag--idle' };

export function FleetAccounts({ reloadKey }) {
  const res = useApi(() => api.aiAccounts(), [reloadKey]);
  const [sheet, setSheet] = useState(null);
  const close = () => setSheet(null);
  return html`
    <${FleetAccountsView} data=${res.data} loading=${res.loading && !res.data} error=${res.error}
      onRetry=${res.reload} onAdd=${() => setSheet({ mode: 'add' })} onRotate=${(row) => setSheet({ mode: 'rotate', old: row })}/>
    <${AiAccountSheet} open=${Boolean(sheet)} mode=${sheet ? sheet.mode : 'add'} old=${sheet ? sheet.old || null : null}
      onClose=${close} onSaved=${() => res.reload()}/>`;
}

// The columns, exported so a test can sort by each accessor the way the
// table does.
export function fleetColumns({ onRotate }) {
  return [
    { key: 'vendor', label: 'VENDOR', sort: (r) => r.vendor, cell: (r) => html`<span class="mono">${r.vendor}</span>` },
    {
      key: 'label', label: 'LABEL', sort: (r) => r.label,
      cell: (r) => html`<${Link} to=${`/settings?account=${encodeURIComponent(r.label)}`} class="cell-name">${r.label}<//>`
    },
    { key: 'plan', label: 'PLAN', sort: (r) => r.plan || '', cell: (r) => (r.plan ? html`<span>${r.plan}</span>` : html`<span class="na">—</span>`) },
    {
      key: 'projects', label: 'PROJECTS', sort: (r) => (r.projects || []).join(', '),
      cell: (r) => ((r.projects || []).length
        ? html`<span class="aiacct__projects">${r.projects.map((p) => html`<${Link} key=${p} to=${`/settings/p/${encodeURIComponent(p)}/lanes`}>${p}<//>`)}</span>`
        : html`<span class="na">none</span>`)
    },
    { key: 'today', label: 'TODAY', sort: (r) => r.today, align: 'right', cell: (r) => html`<${UsdCell} value=${r.today}/>` },
    { key: 'boxes', label: 'BOXES', sort: (r) => r.boxes, align: 'right', cell: (r) => (r.boxes === null || r.boxes === undefined ? html`<span class="na" title="no box reported a login for this label">—</span>` : html`<span class="num">${r.boxes}</span>`) },
    { key: 'state', label: 'STATE', sort: (r) => r.state, cell: (r) => html`<span class=${STATE_TAG[r.state] || 'tag'}>${r.state}</span>` },
    {
      key: 'action', label: 'ACTION', sort: (r) => (r.revoked_at ? 'revoked' : 'rotate'),
      cell: (r) => (r.revoked_at ? html`<span class="na">revoked</span>`
        : html`<button type="button" class="btn btn--sm" onClick=${() => onRotate && onRotate(r)}>ROTATE</button>`)
    }
  ];
}

export function FleetAccountsView({ data, loading, error, onRetry, onAdd, onRotate }) {
  const rows = data && Array.isArray(data.accounts) ? data.accounts : [];
  const add = html`<button type="button" class="btn btn--sm" onClick=${() => onAdd && onAdd()}>+ ADD ACCOUNT</button>`;
  return html`
    <${Section} title="ACCOUNTS ON THE FLEET" note="every AI account the hub holds a token for: a label, never the token" right=${add}>
      ${loading ? html`<${Skeleton} rows=${1} height=${22}/>`
        : error ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`
        : html`
          <div class="aiacct__wrap">
            <${SortableTable} rows=${rows} rowKey=${(r) => r.id} defaultSort="vendor" columns=${fleetColumns({ onRotate })}
              empty=${html`<${Empty} title="NO AI ACCOUNTS" note="Add one: its token is sealed in this page and only the hub can open it.">${add}<//>`}/>
          </div>
          ${data && data.truncated ? html`<p class="section__note">Showing the first ${data.limit} accounts (settings row ai_accounts_list_limit).</p>` : null}`}
    <//>`;
}

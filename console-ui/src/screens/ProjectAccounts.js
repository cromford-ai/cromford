// PROJECT ACCOUNTS (BH-1657): which Claude account each fleet project bills,
// on the hub tab of /settings. A row is a settings row `account.<project>`
// holding a LABEL; setting it goes through the in-app confirm and the worker
// PUT, which refuses anything token-shaped. The token itself never leaves the
// boxes, so nothing here can show one.

import { useState, useEffect } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Empty, Age } from '../ui/primitives.js';
import { minutesSince } from '../lib/format.js';
import { accountRows, checkAccountLabel } from '../lib/project-accounts.js';

export function ProjectAccounts({ projects, accountActions, busy, guard, onChoose, reloadKey }) {
  // reloadKey (BH-7966): a choice sheet write re-reads the pins.
  const settings = useApi(() => api.settings(), [reloadKey]);
  const rows = accountRows(settings.data, projects);
  const onSet = async (row, draft) => {
    const res = await accountActions.set(row, draft);
    if (res && res.status === 'written') settings.reload();
    return res;
  };
  return html`<${ProjectAccountsView} rows=${rows} error=${settings.error}
    loading=${settings.loading && !settings.data} busy=${busy} guard=${guard} onSet=${onSet} onChoose=${onChoose}/>`;
}

export function ProjectAccountsView({ rows, error, loading, busy, guard, onSet, onChoose }) {
  return html`
    <${Section} title="PROJECT ACCOUNTS"
      note="which Claude account each project bills — a label, never a token; shared = the shared pool">
      ${error ? html`
        <div class="banner">
          <span><b>could not read the settings table — ${String(error.message || error)}.</b>
            ${rows.length ? ' The rows below are the fleet list only, not the stored pins.' : ''}</span>
        </div>` : null}
      ${loading ? html`<span class="na">loading…</span>` : error && !rows.length ? null : html`
        <${SortableTable} rows=${rows} rowKey=${(r) => r.project} defaultSort="project"
          empty=${html`<${Empty} title="NO PROJECTS" note="The lane status named no fleet project and no account row exists."/>`}
          columns=${[
            {
              key: 'project', label: 'PROJECT', sort: (r) => r.project,
              cell: (r) => html`<${Link} to=${r.href} class="cell-name">${r.project}<//>`
            },
            {
              key: 'label', label: 'ACCOUNT', sort: (r) => r.label || '',
              cell: (r) => html`<${AccountCell} row=${r} busy=${busy} guard=${guard} onSet=${onSet} onChoose=${onChoose}/>`
            },
            {
              key: 'actor', label: 'SET BY', sort: (r) => r.actor,
              cell: (r) => (r.actor ? html`<span class="mono">${r.actor}</span>` : html`<span class="na">—</span>`)
            },
            {
              key: 'updated_at', label: 'UPDATED', sort: (r) => r.updated_at,
              cell: (r) => (r.updated_at
                ? html`<span title=${r.updated_at}><${Age} min=${minutesSince(r.updated_at)} warnAt=${Infinity}/></span>`
                : html`<span class="na">never</span>`)
            }
          ]}/>`}
    <//>`;
}

function AccountCell({ row, busy, guard, onSet, onChoose }) {
  const [draft, setDraft] = useState(row.label || '');
  // A refetch that changed the stored label must win over a stale draft.
  useEffect(() => { setDraft(row.label || ''); }, [row.label]);
  const key = `account:${row.project}`;
  const dirty = draft.trim() !== (row.label || '');
  const check = dirty ? checkAccountLabel(draft) : { ok: true };
  const submit = () => { if (dirty && check.ok) guard(key, () => onSet(row, draft)); };
  return html`
    <span class="knob">
      <input id=${key} class=${check.ok ? 'knob__input' : 'knob__input knob__input--bad'} type="text"
        value=${draft} placeholder="shared pool" autocomplete="off" spellcheck="false"
        aria-label=${`account label for ${row.project}`}
        aria-invalid=${check.ok ? 'false' : 'true'} aria-describedby=${`${key}-note`}
        disabled=${busy !== null}
        onInput=${(e) => setDraft(e.target.value)}
        onKeyDown=${(e) => { if (e.key === 'Enter') submit(); }} />
      ${dirty ? html`
        <button type="button" class="btn btn--sm" disabled=${busy !== null || !check.ok} onClick=${submit}>
          ${busy === key ? '…' : 'SET'}
        </button>` : null}
      ${onChoose ? html`
        <button type="button" class="btn btn--sm" disabled=${busy !== null}
          aria-label=${`choose the AI account for ${row.project}`} onClick=${() => onChoose(row)}>CHOOSE…</button>` : null}
      <span id=${`${key}-note`} class=${check.ok ? 'knob__note' : 'knob__note knob__note--bad'}>
        ${!check.ok ? check.message : row.label ? '' : 'shared pool'}
      </span>
    </span>`;
}

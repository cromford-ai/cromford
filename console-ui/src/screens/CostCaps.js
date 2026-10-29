import { useState, useMemo } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { laneHref } from '../lib/settings.js';
import { agoFromMinutes, minutesSince } from '../lib/format.js';
import { capRows, editFormState, makeEditAction, CAP_GRAMMAR } from '../lib/cost-caps.js';
import { DailyCeilingsSection } from './DailyCeilings.js';

// BH-2566 (BH-2511.3): the Costs page's CAPS section, mounted on /costs
// directly below COST BREAKER. Every conf.cost-caps.* / conf.lane-caps.*
// settings row, and an audited EDIT for the fleet ones. The section owns the
// read and the write; the view is a pure function of props so the tests render
// it server-side (same split as CostBreaker.js).
export const loadSettings = () => api.settings();

export function CostCapsSection() {
  const settings = useApi(loadSettings, [], { intervalMs: 60000 });
  const [dialog, confirm] = useConfirm();
  const [pending, setPending] = useState(null);
  const [msg, setMsg] = useState(null);

  const onEdit = useMemo(() => makeEditAction({
    confirm,
    put: (args) => api.putCostCap(args),
    reload: settings.reload,
    onMsg: setMsg,
    onPending: setPending,
    renderForm: (row, form, setBlocked) => html`<${EditForm} row=${row} value=${form} onBlocked=${setBlocked}/>`
  }), [confirm, settings.reload]);

  return html`
    <${CostCapsView} settings=${settings} onEdit=${onEdit} pending=${pending} msg=${msg}/>
    <${DailyCeilingsSection} settings=${settings}/>
    ${dialog}`;
}

// The modal body. VALUE is the first field, so the Modal's once-per-open
// effect puts focus there and keeps it there (D39); this adds no effect.
export function EditForm({ row, value, onBlocked }) {
  const [v, setV] = useState(value.value);
  const [reason, setReason] = useState(value.reason);
  const { hint } = editFormState(v, reason, row.kind);
  const input = (label, cur, placeholder, write) => html`
    <label class="knob" style="width:100%">
      <span class="knob__label">${label}</span>
      <input class="knob__input" style="width:100%" type="text" value=${cur} placeholder=${placeholder}
        onInput=${(e) => write(e.target.value)}/>
    </label>`;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="overflow-wrap:anywhere"><b>${row.key}</b></span>
      ${input('VALUE', v, CAP_GRAMMAR[row.kind], (x) => {
        value.value = x;
        setV(x);
        if (onBlocked) onBlocked(editFormState(x, value.reason, row.kind).blocked);
      })}
      ${input('REASON', reason, 'why this cap changes', (x) => {
        value.reason = x;
        setReason(x);
        if (onBlocked) onBlocked(editFormState(value.value, x, row.kind).blocked);
      })}
      <span style="color:var(--faint)">${row.kind} takes ${CAP_GRAMMAR[row.kind]}. The worker records the change with your reason.</span>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
    </div>`;
}

const dash = (v) => (v === null || v === undefined || v === '' ? '—' : v);
// The leading number, so "100 5" sorts after "20"; `off` sorts as text.
const leading = (v) => {
  if (v === null || v === undefined) return null;
  const first = String(v).trim().split(/\s+/)[0];
  return /^\d+(\.\d+)?$/.test(first) ? Number(first) : String(v);
};
// Relative, with the timestamp itself on hover.
const when = (iso) => (iso ? html`<span title=${iso}>${agoFromMinutes(minutesSince(iso))}</span>` : '—');

function subjectCell(r) {
  if (r.scope === 'project') return html`<${Link} to=${`/p/${encodeURIComponent(r.subject)}`} class="cell-name">${r.subject}<//>`;
  if (r.scope === 'lane') return html`<${Link} to=${laneHref(r.subject)} class="cell-name">${r.subject}<//>`;
  return r.subject;
}

const scopeText = (r) => (r.box ? `${r.scope} · box ${r.box}` : r.scope);

export function capColumns({ onEdit, pending }) {
  return [
    { key: 'scope', label: 'SCOPE', sort: scopeText, cell: scopeText },
    { key: 'subject', label: 'SUBJECT', cell: subjectCell },
    { key: 'kind', label: 'KIND', cell: (r) => r.kind },
    { key: 'catalog', label: 'CATALOG', sort: (r) => leading(r.catalog), cell: (r) => dash(r.catalog) },
    { key: 'override', label: 'OVERRIDE', sort: (r) => leading(r.override), cell: (r) => dash(r.override) },
    { key: 'applies', label: 'APPLIES', sort: (r) => leading(r.applies), cell: (r) => dash(r.applies) },
    { key: 'actor', label: 'BY', cell: (r) => dash(r.actor) },
    { key: 'updatedAt', label: 'UPDATED', cell: (r) => when(r.updatedAt) },
    {
      key: 'edit', label: 'EDIT', sort: null,
      cell: (r) => (r.editable
        ? html`<button type="button" class="btn btn--sm" disabled=${pending === r.key} onClick=${() => onEdit(r)}>EDIT</button>`
        : html`<span style="color:var(--faint)">display only</span>`)
    },
  ];
}

export function CostCapsView({ settings, onEdit, pending, msg }) {
  const data = settings && settings.data;
  const caps = capRows(data && data.settings);

  const body = () => {
    if (settings && settings.loading && !data) return html`<${Skeleton} rows=${3} height=${20}/>`;
    if (caps.unreadable) {
      return html`<${ErrorBox} error=${(settings && settings.error) || new Error('the settings read returned no list')}
        onRetry=${settings && settings.reload}/>`;
    }
    return html`<${SortableTable} wide columns=${capColumns({ onEdit, pending })} rows=${caps.rows} rowKey=${(r) => r.key}
      defaultSort="scope"
      empty=${html`<${Empty} title="no cap rows yet — run bin/cost-caps-seed.sh on the hub"/>`}/>`;
  };

  return html`
    <${Section} title="CAPS" note="conf.cost-caps.* and conf.lane-caps.* settings rows">
      ${msg ? html`<div class=${msg.ok ? 'banner banner--warn' : 'banner'} role="status"
        style=${msg.ok ? 'margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : 'margin-bottom:10px'}>
        <span style="overflow-wrap:anywhere">${msg.text}</span></div>` : null}
      ${body()}
      <div class="footnote" style="margin-top:8px"><span style="color:var(--faint)">
        a box-local flags/cost-caps.conf or flags/lane-caps.conf is not visible here; an override row beats it
      </span></div>
    <//>`;
}

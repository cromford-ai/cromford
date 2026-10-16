// BH-6824 (Staff in Mission Control 3/4): the AUTONOMY panel of one staff
// agent. AgentAutonomy({agent}) owns the read (GET /api/staff/autonomy) and
// the two writes (the agent's level, one class's delegation), each in the
// project Modal with a required reason. The modal closes only on a 2xx, and
// the panel then re-reads the GET: it shows the read-back, never the intent.
// AgentAutonomyView is a pure function of props, so the tests render it
// server-side. The pure half is lib/staff-autonomy.js.
import { useRef, useState } from 'preact/hooks';
import { html } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { Modal } from '../../ui/Modal.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Skeleton, Empty, ErrorBox, Age } from '../../ui/primitives.js';
import { minutesSince } from '../../lib/format.js';
import { na } from '../../lib/staff.js';
import {
  autonomyState, levelOptions, canEditClass, classTarget, delegateBlock, autonomyBody, delegationBody,
  reasonHint, reasonOf, errorText
} from '../../lib/staff-autonomy.js';

const errText = (e) => (e && e.body && e.body.error ? errorText(e.body) : `refused: ${e && e.message ? e.message : String(e)}`);

export function AgentAutonomy({ agent }) {
  const read = useApi(() => api.staffAutonomy(agent), [agent]);
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const [note, setNote] = useState(null);
  const nonce = useRef(0);
  // A second click can land before the render that shows SAVING….
  const inFlight = useRef(false);
  const st = autonomyState(read.data);

  // kind 'level': the agent's level; kind 'class': one class's delegation.
  const open = (kind, cls = null) => {
    if (!st) return;
    nonce.current += 1;
    setServerError(null);
    const options = kind === 'level' ? levelOptions(st.agent.autonomy, st.agent.cap, st.levels) : [];
    setEdit({
      kind, cls, nonce: nonce.current, options, cap: st.agent.cap, levels: st.levels,
      draft: { reason: '', to: options[0] || null }
    });
  };

  const onConfirm = async () => {
    if (inFlight.current || !edit) return;
    const name = st ? st.agent.name : agent;
    const body = edit.kind === 'level'
      ? autonomyBody(name, edit.draft.to, edit.cap, edit.draft.reason, edit.levels)
      : delegationBody(name, edit.cls, edit.draft.reason);
    if (body === null) { setServerError('refused here: a reason is required, and the change must be allowed'); return; }
    inFlight.current = true;
    setPending(true);
    setServerError(null);
    try {
      if (edit.kind === 'level') await api.staffSetAutonomy(body);
      else await api.staffSetDelegation(body);
      setNote(edit.kind === 'level'
        ? `level change sent (${body.autonomy}); the panel shows what the server read back`
        : `${body.class}: ${body.decision} sent; the panel shows what the server read back`);
      setEdit(null);
      read.reload();
    } catch (e) {
      setServerError(errText(e));
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  };

  const title = edit && (edit.kind === 'level' ? 'CHANGE LEVEL' : `${classTarget(edit.cls) === 'delegate' ? 'DELEGATE' : 'ASK FIRST'} ${edit.cls.class}`);
  const dialog = edit ? html`
    <${Modal} key=${edit.nonce} title=${title}
      confirmLabel=${pending ? 'SAVING…' : 'SAVE'}
      tone="warn"
      confirmBlocked=${true}
      body=${({ setBlocked }) => html`<${AutonomyForm} edit=${edit} serverError=${serverError} onBlocked=${setBlocked}/>`}
      onConfirm=${onConfirm}
      onCancel=${() => { if (!inFlight.current) setEdit(null); }}/>` : null;

  return html`<${AgentAutonomyView} agent=${agent} state=${read} onEdit=${open} busy=${pending} note=${note} dialog=${dialog}/>`;
}

// The draft lives in the form's own state and is written through to `edit`,
// so a re-render of the page never resets what is typed (D39).
export function AutonomyForm({ edit, serverError, onBlocked }) {
  const [reason, setReason] = useState(edit.draft.reason);
  const [to, setTo] = useState(edit.draft.to);
  const blockedFor = (r, t) => reasonOf(r) === null || (edit.kind === 'level' && !t);
  const onReason = (v) => { edit.draft.reason = v; setReason(v); onBlocked(blockedFor(v, to)); };
  const onTo = (v) => { edit.draft.to = v; setTo(v); onBlocked(blockedFor(reason, v)); };
  const hint = reasonHint(reason);
  const c = edit.cls;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      ${edit.kind === 'level' ? html`
        <span style="color:var(--faint);overflow-wrap:anywhere">The cap is ${edit.cap}. Only levels at or below it are offered.</span>
        <label class="knob" style="width:100%">
          <span class="knob__label">LEVEL</span>
          <select class="knob__input" style="width:100%" aria-label="level" value=${to} onChange=${(e) => onTo(e.target.value)}>
            ${edit.options.map((l) => html`<option key=${l} value=${l}>${l}</option>`)}
          </select>
        </label>` : html`
        <span style="overflow-wrap:anywhere">
          <b>${c.class}</b>: ${c.state} → ${classTarget(c) === 'delegate' ? 'delegated' : 'ask_first'}
          ${classTarget(c) === 'ask_first' ? ' (the streak goes back to 0)' : ''}
        </span>`}
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" aria-label="reason" value=${reason}
          placeholder="why (required)" onInput=${(e) => onReason(e.target.value)}/>
      </label>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
      ${serverError ? html`<span role="alert" style="color:var(--red);overflow-wrap:anywhere">${serverError}</span>` : null}
    </div>`;
}

const btn = (label, disabled, onClick, titleText = '') => html`
  <button type="button" class="btn btn--sm" style="min-height:44px" title=${titleText} disabled=${disabled} onClick=${onClick}>${label}</button>`;
const age = (iso) => (iso
  ? html`<span title=${iso}><${Age} min=${minutesSince(iso)} warnAt=${Infinity}/></span>`
  : html`<span class="na">${na(null)}</span>`);
const text = (v) => html`<span class=${v === null || v === undefined ? 'na' : ''} style="overflow-wrap:anywhere">${na(v)}</span>`;

export function classColumns({ onEdit, busy }) {
  return [
    { key: 'class', label: 'CLASS', cell: (c) => html`<span class="cell-name">${c.class}</span>` },
    { key: 'display_state', label: 'STATE', cell: (c) => html`<span>${c.display_state}</span>` },
    {
      key: 'cap', label: 'CAP',
      cell: (c) => html`<span title=${`effective cap (the lower of agent and class): ${c.effective_cap}`}>${na(c.cap)}</span>`
    },
    { key: 'streak', label: 'STREAK', align: 'right', cell: (c) => html`<span>${na(c.streak)}</span>` },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (c) => {
        if (!canEditClass(c)) return html`<span class="na">never delegable</span>`;
        if (classTarget(c) === 'ask_first') return btn('ASK FIRST…', busy, () => onEdit && onEdit('class', c));
        const why = delegateBlock(c);
        return html`${btn('DELEGATE…', busy || Boolean(why), () => onEdit && onEdit('class', c), why || '')}
          ${why ? html`<span class="na" style="display:block;font-size:var(--fs-xs)">${why}</span>` : null}`;
      }
    }
  ];
}

const CHANGE_COLUMNS = [
  { key: 'created_at', label: 'WHEN', sort: (r) => r.id, cell: (r) => age(r.created_at) },
  { key: 'kind', label: 'KIND', cell: (r) => text(r.kind) },
  { key: 'class', label: 'CLASS', cell: (r) => (r.class ? text(r.class) : html`<span class="na">agent level</span>`) },
  { key: 'from_value', label: 'FROM', cell: (r) => text(r.from_value) },
  { key: 'to_value', label: 'TO', cell: (r) => text(r.to_value) },
  { key: 'actor', label: 'BY', cell: (r) => text(r.actor) },
  { key: 'reason', label: 'REASON', flex: true, cell: (r) => text(r.reason) }
];

export function AgentAutonomyView({ agent, state, onEdit, busy = false, note = null, dialog = null }) {
  const st = autonomyState(state && state.data);
  if (state && state.loading && !st) return html`<${Skeleton} rows=${5} height=${20}/>`;
  if (st === null) {
    return html`<${ErrorBox} error=${(state && state.error) || new Error(`the autonomy read for ${agent} returned no agent`)}
      onRetry=${state && state.reload}/>`;
  }
  const options = levelOptions(st.agent.autonomy, st.agent.cap, st.levels);
  const facts = [['AUTONOMY', st.agent.autonomy], ['CAP', st.agent.cap], ['STATUS', st.agent.status]];
  return html`
    <div>
      ${dialog}
      ${state && state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
      ${note ? html`<div class="banner banner--warn" role="status"
        style="margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)">
        <span style="overflow-wrap:anywhere">${note}</span></div>` : null}
      <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-bottom:8px">
        <dl class="lanekv" style="flex:1 1 30ch">
          ${facts.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${na(v)}</dd>`)}
        </dl>
        ${btn('CHANGE LEVEL…', busy || options.length === 0, () => onEdit && onEdit('level'),
          options.length === 0 ? 'no other level at or below the cap' : '')}
      </div>
      <p style="color:var(--faint);overflow-wrap:anywhere">
        A class is delegated only after ${st.delegateAfter ? st.delegateAfter.min : 'n/a'} agreements in a row, and only when both caps are autonomy.
      </p>
      <${SortableTable} wide columns=${classColumns({ onEdit, busy })} rows=${st.classes} rowKey=${(c) => c.class}
        defaultSort="class" empty=${html`<${Empty} title="no action classes recorded yet"/>`}/>
      <h3 class="section__title" style="display:block;margin-top:14px">LAST CHANGES</h3>
      ${st.truncated ? html`<p style="color:var(--faint)">capped at ${st.limit}: the newest ${st.limit} changes show</p>` : null}
      <${SortableTable} wide columns=${CHANGE_COLUMNS} rows=${st.changes} rowKey=${(r) => r.id}
        defaultSort="created_at" defaultDir="desc" empty=${html`<${Empty} title="no changes yet"/>`}/>
    </div>`;
}

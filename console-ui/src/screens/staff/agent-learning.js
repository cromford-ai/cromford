// BH-6825 (Staff in Mission Control 4/4): the LEARNING panel of /staff/:agent,
// the agent-learning seam (AgentLearning({agent, row})). Precision and noise
// of the agent over the two windows of GET /api/staff/learning, each count a
// button that opens the outcome rows behind it (GET
// /api/staff/learning/outcomes, cursor paged, each row linking its finding),
// the pending promotion with its evidence, and the newest human decisions.
// APPROVE… and VOID… open the in-app Modal with a required reason and post
// POST /api/staff/promotions/decide. The modal closes only on a 2xx; the note
// is the route's read-back and the panel reads the GET again. AgentLearning
// owns the reads and the write; AgentLearningView is a pure function of props
// so the tests render it server-side.
import { useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../../router.js';
import { api } from '../../api.js';
import { useApi } from '../../lib/hooks.js';
import { Modal } from '../../ui/Modal.js';
import { SortableTable } from '../../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../../ui/primitives.js';
import { safeHttpsUrl } from '../../lib/format.js';
import { displayName, na } from '../../lib/staff.js';
import {
  learningState, pct, COUNT_KEYS, countLabel, outcomeHref, decideBody, errorText, readBackText, REASON_MAX
} from '../../lib/staff-learning.js';

// `row` is the roster row of the agent (the seam contract); the panel reads
// its own numbers and does not need it. `onChanged` runs after a 2xx decide so
// the page re-reads what feeds its own facts (the roster's AUTONOMY).
export function AgentLearning({ agent, onChanged = null }) {
  const state = useApi(() => api.staffLearning(agent), [agent]);
  const [drill, setDrill] = useState(null);
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const [note, setNote] = useState(null);
  // Each drill-down read takes a version; an answer for an older one is dropped,
  // so a slow page never lands on a newer selection.
  const ver = useRef(0);
  const nonce = useRef(0);
  // A second click can land before the render that shows SAVING….
  const inFlight = useRef(false);

  useEffect(() => { ver.current += 1; setDrill(null); setNote(null); }, [agent]);

  const load = async (base, before) => {
    ver.current += 1;
    const v = ver.current;
    setDrill({ ...base, loading: true, error: null });
    try {
      const ans = await api.staffLearningOutcomes(agent, { days: base.days, outcome: base.outcome, before });
      if (v !== ver.current) return;
      if (!ans || !Array.isArray(ans.rows)) throw new Error('the outcomes read returned no list');
      setDrill({
        ...base, rows: [...(before ? base.rows : []), ...ans.rows],
        truncated: ans.truncated === true, next_before: ans.next_before || null, loading: false, error: null
      });
    } catch (e) {
      if (v === ver.current) setDrill({ ...base, loading: false, error: e });
    }
  };
  const onCount = (days, outcome, total) => load({ days, outcome, total, rows: [], truncated: false, next_before: null });
  const onOlder = () => { if (drill && drill.next_before && !drill.loading) load(drill, drill.next_before); };

  const onDecide = (decision, promotion) => {
    nonce.current += 1;
    setServerError(null);
    setNote(null);
    setEdit({ decision, promotion, nonce: nonce.current, draft: { reason: '' } });
  };
  const onConfirm = async () => {
    if (inFlight.current || !edit) return;
    const body = decideBody({ id: edit.promotion.id, decision: edit.decision, reason: edit.draft.reason });
    if (!body) { setServerError(errorText({ body: { error: 'reason' } })); return; }
    inFlight.current = true;
    setPending(true);
    setServerError(null);
    try {
      const ans = await api.staffDecidePromotion(body);
      const text = readBackText(ans);
      if (!text) { setServerError(errorText({ body: { error: 'decide_unresolved' } })); return; }
      setNote(text);
      setEdit(null);
      state.reload();
      if (typeof onChanged === 'function') onChanged();
    } catch (e) {
      setServerError(errorText(e));
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  };

  const verb = edit && edit.decision === 'approve' ? 'APPROVE' : 'VOID';
  const dialog = edit ? html`
    <${Modal} key=${edit.nonce}
      title=${`${verb} PROMOTION #${edit.promotion.id}`}
      confirmLabel=${pending ? 'SAVING…' : verb}
      tone=${edit.decision === 'approve' ? 'warn' : 'danger'}
      confirmBlocked=${true}
      body=${({ setBlocked }) => html`<${DecideForm} agent=${agent} edit=${edit} serverError=${serverError} onBlocked=${setBlocked}/>`}
      onConfirm=${onConfirm}
      onCancel=${() => { if (!inFlight.current) setEdit(null); }}/>` : null;

  return html`<${AgentLearningView} agent=${agent} state=${state} drill=${drill} onCount=${onCount} onOlder=${onOlder}
    onDecide=${onDecide} busy=${pending} note=${note} dialog=${dialog}/>`;
}

// The reason lives in the form's own state and is written through to the
// draft, so a re-render never resets what is typed (D39).
export function DecideForm({ agent, edit, serverError, onBlocked }) {
  const [reason, setReason] = useState(edit.draft.reason);
  const p = edit.promotion;
  const onInput = (v) => {
    edit.draft.reason = v;
    setReason(v);
    onBlocked(decideBody({ id: p.id, decision: edit.decision, reason: v }) === null);
  };
  const who = displayName(agent);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="color:var(--faint);overflow-wrap:anywhere">
        ${edit.decision === 'approve'
          ? `Raises ${who} from ${p.from_level} to ${p.to_level} and marks the proposal applied.`
          : `Voids the proposal. ${who} stays at ${p.from_level}.`}
      </span>
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <textarea class="knob__input" style="width:100%;min-height:72px" aria-label="reason" maxlength=${REASON_MAX}
          placeholder="why (required)" value=${reason} onInput=${(e) => onInput(e.target.value)}></textarea>
      </label>
      ${serverError ? html`<span role="alert" style="color:var(--red);overflow-wrap:anywhere">${serverError}</span>` : null}
    </div>`;
}

const naCell = (v) => html`<span class=${v === null || v === undefined || v === '' ? 'na' : ''}>${na(v)}</span>`;
const pctCell = (x) => html`<span class=${x === null || x === undefined ? 'na' : ''}>${pct(x)}</span>`;
const btn = (label, disabled, onClick, extra = {}) => html`
  <button type="button" class="btn btn--sm" style="min-height:44px" disabled=${disabled} onClick=${onClick} ...${extra}>${label}</button>`;
const ticketLink = (url) => {
  const href = safeHttpsUrl(url);
  if (!href) return naCell(url);
  const tail = String(url).split('/').filter(Boolean).pop();
  return html`<a href=${href} target="_blank" rel="noopener">${/^\d+$/.test(tail || '') ? `#${tail}` : 'ticket'}</a>`;
};

function windowColumns(onCount) {
  const countCell = (w, key, outcome) => {
    const n = Number(w[key]);
    if (!(n > 0)) return html`<span>${Number.isFinite(n) ? n : 'n/a'}</span>`;
    return btn(String(n), false, () => onCount && onCount(w.days, outcome, n), { 'aria-label': countLabel(n, outcome, w.days) });
  };
  return [
    { key: 'days', label: 'WINDOW', cell: (w) => `last ${w.days} days` },
    { key: 'precision', label: 'PRECISION', sort: (w) => (w.precision === null ? -1 : w.precision), cell: (w) => pctCell(w.precision) },
    { key: 'noise_rate', label: 'NOISE RATE', sort: (w) => (w.noise_rate === null ? -1 : w.noise_rate), cell: (w) => pctCell(w.noise_rate) },
    ...COUNT_KEYS.map(([key, outcome]) => ({ key, label: key.toUpperCase(), align: 'right', cell: (w) => countCell(w, key, outcome) }))
  ];
}

const OUTCOME_COLUMNS = [
  {
    key: 'finding_id', label: 'FINDING', align: 'right',
    cell: (o) => {
      const href = outcomeHref(o.finding_id);
      return href ? html`<${Link} to=${href}>#${o.finding_id}<//>` : html`<span class="na">finding removed</span>`;
    }
  },
  { key: 'class', label: 'CLASS', cell: (o) => naCell(o.class) },
  { key: 'outcome', label: 'OUTCOME', cell: (o) => naCell(o.outcome) },
  { key: 'verdict', label: 'VERDICT', cell: (o) => naCell(o.verdict) },
  { key: 'ticket_url', label: 'TICKET', cell: (o) => ticketLink(o.ticket_url) },
  { key: 'resolved_at', label: 'RESOLVED', cell: (o) => naCell(o.resolved_at) }
];
const outcomeKey = (o) => o.id;

const DECISION_COLUMNS = [
  { key: 'decided_at', label: 'WHEN', cell: (d) => naCell(d.decided_at) },
  { key: 'decision', label: 'DECISION', cell: (d) => naCell(d.decision) },
  { key: 'from_level', label: 'FROM', cell: (d) => naCell(d.from_level) },
  { key: 'to_level', label: 'TO', cell: (d) => naCell(d.to_level) },
  { key: 'actor', label: 'BY', cell: (d) => naCell(d.actor) },
  { key: 'reason', label: 'REASON', flex: true, cell: (d) => html`<span style="overflow-wrap:anywhere">${na(d.reason)}</span>` }
];

function OutcomesSection({ drill, onCount, onOlder }) {
  const what = drill.outcome === 'all' ? 'all' : drill.outcome;
  const n = drill.rows.length;
  let body;
  if (drill.loading && !n) body = html`<${Skeleton} rows=${3} height=${18}/>`;
  else if (drill.error && !n) {
    body = html`<${ErrorBox} error=${drill.error} onRetry=${() => onCount(drill.days, drill.outcome, drill.total)}/>`;
  } else {
    body = html`
      ${drill.error ? html`<${ErrorBox} error=${drill.error} onRetry=${onOlder}/>` : null}
      ${n < drill.total ? html`<p style="color:var(--faint)">${n} of ${drill.total} loaded; sort covers the loaded rows</p>` : null}
      <${SortableTable} wide columns=${OUTCOME_COLUMNS} rows=${drill.rows} rowKey=${outcomeKey} defaultSort="resolved_at" defaultDir="desc"
        empty=${html`<${Empty} title=${`no ${what} outcomes in the last ${drill.days} days now`}/>`}/>
      ${drill.truncated ? html`<p>${btn(drill.loading ? 'LOADING…' : 'OLDER', drill.loading, onOlder)}</p>` : null}`;
  }
  return html`<${Section} title="OUTCOMES" note=${`${what} outcomes in the last ${drill.days} days, newest first`}>${body}<//>`;
}

function ProposalSection({ s, onDecide, busy }) {
  const p = s.promotion;
  if (!p) {
    return html`<${Section} title="PROMOTION PROPOSAL">
      <${Empty} title="no pending proposal" note="the learning loop proposes one after enough agreements in a row"/>
    <//>`;
  }
  const ev = p.evidence;
  const facts = [
    ['PROPOSAL', `#${p.id}: ${p.from_level} → ${p.to_level}`],
    ['AGREEMENTS', na(p.agreements)],
    ['MADE', na(p.created_at)],
    ['SINCE', na(ev.since)]
  ];
  return html`
    <${Section} title="PROMOTION PROPOSAL" note="the outcomes since the agent's last level change are the evidence">
      <dl class="lanekv">
        ${facts.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${v}</dd>`)}
      </dl>
      ${p.stale ? html`<div class="banner banner--warn" role="status" style="margin:8px 0">
        <span style="overflow-wrap:anywhere">The agent's level moved since the proposal (now ${s.agent.autonomy}). An approve is refused.</span></div>` : null}
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin:8px 0">
        ${btn('APPROVE…', busy, () => onDecide && onDecide('approve', p))}
        ${btn('VOID…', busy, () => onDecide && onDecide('void', p))}
      </div>
      ${ev.truncated ? html`<p style="color:var(--faint)">showing ${ev.rows.length} of ${ev.total}, the newest first</p>` : null}
      <${SortableTable} wide columns=${OUTCOME_COLUMNS} rows=${ev.rows} rowKey=${outcomeKey} defaultSort="resolved_at" defaultDir="desc"
        empty=${html`<${Empty} title="no outcomes since the last level change"/>`}/>
    <//>`;
}

export function AgentLearningView({ agent, state, drill, onCount, onOlder, onDecide, busy = false, note = null, dialog = null }) {
  const s = learningState(state && state.data);
  let body;
  if (state && state.loading && !s) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else if (!s) {
    body = html`<${ErrorBox} error=${(state && state.error) || new Error('the learning read returned no windows')} onRetry=${state && state.reload}/>`;
  } else {
    const rows = s.windows.map((w, i) => ({ ...w, _k: i }));
    const longer = s.retentionDays ? s.windows.filter((w) => w.days > s.retentionDays) : [];
    body = html`
      ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
      <${SortableTable} wide columns=${windowColumns(onCount)} rows=${rows} rowKey=${(w) => w._k}/>
      ${s.windows.filter((w) => Number(w.total) === 0).map((w) => html`<p key=${`e-${w.days}`} class="na">no outcomes in the last ${w.days} days</p>`)}
      ${longer.map((w) => html`<p key=${`r-${w.days}`} style="color:var(--faint)">outcomes are kept ${s.retentionDays} days, so the ${w.days}-day window counts only those</p>`)}`;
  }
  return html`
    <div data-testid="agent-learning">
      ${dialog}
      ${note ? html`<div class="banner banner--warn" role="status"
        style="margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)">
        <span style="overflow-wrap:anywhere">${note}</span></div>` : null}
      <${Section} title="LEARNING" note=${`precision and noise of ${displayName(agent)}'s filed findings; click a count for its rows`}>${body}<//>
      ${s && drill ? html`<${OutcomesSection} drill=${drill} onCount=${onCount} onOlder=${onOlder}/>` : null}
      ${s ? html`<${ProposalSection} s=${s} onDecide=${onDecide} busy=${busy}/>` : null}
      ${s ? html`
        <${Section} title="DECISIONS" note=${s.decisionsMore ? 'the newest 5 show' : 'promotion decisions made by a person'}>
          <${SortableTable} wide columns=${DECISION_COLUMNS} rows=${s.decisions} rowKey=${(d) => d.id} defaultSort="decided_at" defaultDir="desc"
            empty=${html`<${Empty} title="no decisions yet"/>`}/>
        <//>` : null}
    </div>`;
}

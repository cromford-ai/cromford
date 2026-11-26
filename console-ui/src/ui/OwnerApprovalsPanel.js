import { useState } from 'preact/hooks';
import { html } from '../router.js';
import { api, AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { agoFromMinutes, minutesSince } from '../lib/format.js';
import { Section, Skeleton, Empty, ErrorBox } from './primitives.js';
import { SortableTable } from './SortableTable.js';
import { COMMAND_LABELS } from '../lib/box-commands.js';
import { flyCapText, flyOnboardText } from './BoxOpForms.js';

// BH-9262 (C1): the owner-approval inbox, on /machines at #owner-approvals.
// A chat caller (bin/archie.sh delegate, bin/box-request.sh) that the jobs
// worker refused for want of an owner proof files a pending row
// (worker/jobs/src/routes/owner-approvals.js). A row grants nothing: the owner
// runs the action here, through the screen's own proved route, and only then
// is the row marked decided.
//   REVIEW (a box command)   the screen's boxOp: the priced launch dialog, or
//                            the confirm+reason dialog. After the worker took
//                            the command, decide `approved` with its id.
//   APPROVE (a delegation)   an in-app confirm, then the archie delegation,
//                            then decide `approved` with the class.
//   DECLINE                  decide `declined`; no action runs.
// A refusal (403 human_proof_required, 409 not_earned, ...) is a banner and no
// decide: the row stays pending. Props: boxOp, confirm and setBanner of
// MachinesScreen.

const errText = (e) => (e && e.message ? e.message : String(e));
const lostSession = (e) => { if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized')); };

const KIND_LABEL = { box_command: 'BOX COMMAND', archie_delegation: 'DELEGATION' };
const STATUS_TAG = { pending: 'tag tag--warn', approved: 'tag tag--green', declined: 'tag', expired: 'tag tag--dead' };

const p = (r) => (r && r.payload && typeof r.payload === 'object' ? r.payload : {});
const specText = (x) => [x.vcpus != null ? `${x.vcpus} vCPU` : null, x.mem_gb != null ? `${x.mem_gb} GB RAM` : null,
  x.disk_gb != null ? `${x.disk_gb} GB disk` : null].filter(Boolean).join(', ');

// The action in words, from the stored payload.
export function actionText(r) {
  const x = p(r);
  if (r.kind === 'archie_delegation') return `delegate ${x.class || '?'}${x.min_streak != null ? ` (after ${x.min_streak} in a row)` : ''}`;
  const parts = [`${COMMAND_LABELS[x.type] || x.type || '?'} ${x.target || ''}`.trim()];
  if (x.project && x.project !== x.target) parts.push(x.project);
  const spec = specText(x);
  if (spec) parts.push(spec);
  if (x.account) parts.push(x.account);
  if (x.cap != null) parts.push(`cap ${x.cap}`);
  return parts.join(' · ');
}

// The boxOp call that REVIEW makes for a box_command payload, or null when
// this screen has no dialog for that type. A priced type opens its quote flow
// again, so the owner sees a fresh price before anything is bought.
export function reviewPlan(r) {
  const x = p(r);
  const reason = typeof x.reason === 'string' && x.reason.trim() ? x.reason : `owner approval #${r.id}`;
  const num = (v) => (v == null ? '' : String(v));
  switch (x.type) {
    case 'orgo_launch_quote':
    case 'orgo_launch':
      return {
        type: 'orgo_launch_quote',
        ctx: { id: x.target, project: x.project, account: x.account, vcpus: num(x.vcpus), mem_gb: num(x.mem_gb), disk_gb: num(x.disk_gb), reason }
      };
    case 'orgo_resize_quote':
    case 'orgo_resize':
      return { type: 'orgo_resize_quote', ctx: { box: x.target, account: x.account, accounts: x.account ? [x.account] : [] } };
    case 'fly_pool_cap':
      return { type: 'fly_pool_cap', ctx: { project: x.target, cap: x.cap }, text: flyCapText(x.target, x.cap) };
    case 'fly_onboard':
      return { type: 'fly_onboard', ctx: { project: x.target, cap: x.cap ?? undefined }, text: flyOnboardText(x.target) };
    case 'orgo_restart':
    case 'orgo_stop':
      return {
        type: x.type, ctx: { box: x.target, account: x.account || undefined },
        text: `${COMMAND_LABELS[x.type]} Orgo box ${x.target}? It is queued for the hub's box-ops lane.`
      };
    default:
      return null;
  }
}

export function OwnerApprovalsPanel({ boxOp, confirm, setBanner }) {
  const list = useApi(() => api.ownerApprovals(), [], { intervalMs: 30000 });
  const [busy, setBusy] = useState(null);
  const data = list.data;
  const rows = data && Array.isArray(data.approvals) ? data.approvals : [];

  // Mark the row decided. Called only after the owner's action succeeded (or
  // on DECLINE); a failure here leaves the row pending and says so.
  const decide = async (r, decision, resultRef, done) => {
    const body = resultRef == null ? { decision } : { decision, result_ref: resultRef };
    try {
      await api.decideOwnerApproval(r.id, body);
      setBanner({ ok: true, text: `${done ? `${done}; ` : ''}approval #${r.id} ${decision}` });
    } catch (e) {
      lostSession(e);
      setBanner({ ok: false, text: `${done ? `${done}, but ` : ''}approval #${r.id} was not marked ${decision}: ${errText(e)}` });
    }
    list.reload();
  };

  const run = (r, fn) => async () => {
    if (busy !== null) return;
    setBusy(r.id);
    try { await fn(); } finally { setBusy(null); }
  };

  const review = (r) => run(r, async () => {
    const plan = reviewPlan(r);
    if (!plan) { setBanner({ ok: false, text: `approval #${r.id}: this screen has no dialog for ${p(r).type || 'that type'}` }); return; }
    const res = await boxOp(plan.type, plan.ctx, plan.text, 'warn');
    // Cancelled, or refused: boxOp already showed why. The row stays pending.
    if (!res || !res.ok) return;
    if (res.id == null) {
      setBanner({ ok: false, text: `${res.text}, but the worker gave no command id, so approval #${r.id} stays pending` });
      return;
    }
    await decide(r, 'approved', String(res.id), res.text);
  });

  const approve = (r) => run(r, async () => {
    const x = p(r);
    const ok = await confirm({
      title: `DELEGATE ${x.class}`, confirmLabel: 'DELEGATE', tone: 'warn',
      body: html`<p>Archie will handle ${x.class} calls and report after each one. One overrule puts the class back.
        Asked by ${r.actor || 'unknown'}${r.via ? ` via ${r.via}` : ''}.</p>`
    });
    if (!ok) return;
    try {
      await api.archieDelegation({ class: x.class, decision: 'delegate', min_streak: x.min_streak, reason: `owner approval #${r.id}` });
    } catch (e) {
      lostSession(e);
      const streak = e && e.body && e.body.streak != null ? ` (streak ${e.body.streak} of ${x.min_streak})` : '';
      setBanner({ ok: false, text: `DELEGATE ${x.class} refused: ${errText(e)}${streak}. Approval #${r.id} stays pending.` });
      return;
    }
    await decide(r, 'approved', String(x.class), `${x.class} is delegated`);
  });

  const decline = (r) => run(r, () => decide(r, 'declined', null, null));

  const actions = (r) => {
    if (r.status !== 'pending') return html`<span class="na">—</span>`;
    const off = busy !== null;
    return html`
      <span style="display:flex;flex-wrap:wrap;gap:6px;white-space:nowrap">
        ${r.kind === 'box_command'
          ? html`<button class="btn btn--sm btn--warn" type="button" disabled=${off} onClick=${review(r)}>REVIEW</button>`
          : html`<button class="btn btn--sm btn--warn" type="button" disabled=${off} onClick=${approve(r)}>APPROVE</button>`}
        <button class="btn btn--sm" type="button" disabled=${off} onClick=${decline(r)}>DECLINE</button>
      </span>`;
  };

  return html`
    <div id="owner-approvals" data-state=${list.loading && !data ? 'loading' : 'ready'}>
      <${Section} title="OWNER APPROVALS"
        note="requests from chat that need your proof; nothing runs until you act here">
        ${list.loading && !data ? html`<${Skeleton} rows=${2} height=${18}/>` : null}
        ${list.error && !data ? html`<${ErrorBox} error=${list.error} onRetry=${list.reload}/>` : null}
        ${data ? html`
          <${SortableTable} wide
            columns=${[
              {
                key: 'created', label: 'REQUESTED', sort: (r) => r.created_at,
                cell: (r) => html`<span title=${r.created_at}>${agoFromMinutes(minutesSince(r.created_at))}</span>`
              },
              { key: 'kind', label: 'KIND', sort: (r) => r.kind, cell: (r) => html`<span class="tag">${KIND_LABEL[r.kind] || r.kind}</span>` },
              { key: 'action', label: 'ACTION', sort: (r) => actionText(r), flex: true, cell: (r) => html`<span>${actionText(r)}</span>` },
              {
                key: 'by', label: 'REQUESTED BY', sort: (r) => `${r.actor || ''} ${r.via || ''}`,
                cell: (r) => html`<span>${r.actor || 'unknown'}${r.via ? html` <span class="na">via ${r.via}</span>` : null}</span>`
              },
              {
                key: 'status', label: 'STATUS', sort: (r) => r.status,
                cell: (r) => html`<span class=${STATUS_TAG[r.status] || 'tag'}>${String(r.status || 'unknown').toUpperCase()}</span>`
              },
              { key: 'actions', label: 'ACTIONS', sort: null, cell: actions }
            ]}
            rows=${rows}
            rowKey=${(r) => r.id}
            defaultSort="created" defaultDir="desc"
            empty=${html`<${Empty} title="Nothing waits for your approval"
              note="A chat request that needs your proof shows here." />`} />
          ${data.truncated ? html`
            <div class="banner banner--warn">
              <span>showing the newest ${rows.length}; older pending requests are not listed</span>
            </div>` : null}` : null}
      <//>
    </div>`;
}

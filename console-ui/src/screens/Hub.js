import { useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { Section, Skeleton, Empty, Legend } from '../ui/primitives.js';
import { SortableTable } from '../ui/SortableTable.js';
import { useConfirm } from '../ui/Modal.js';
import { agoFromMinutes, fmtNum } from '../lib/format.js';
import {
  leaseView, roleView, backupRows, promoteTargets, promoteFormState, promoteBody,
  promoteOutcome, promoteResult, loadError, createLoader
} from '../lib/hub.js';
import { RestoreLabPanel } from './hub/RestoreLab.js';
import { StandbyPanel } from './hub/Standby.js';
import { SeedRegistryPanel } from './hub/SeedRegistry.js';
import { ChatBindingsPanel } from './hub/ChatBindings.js';

// HUB — hub recovery (BH-1909): who holds the hub lease, each box's backup
// stamps, promote, and the restore lab. BH-1945 builds the lease, role,
// backups and promote parts on the BH-1942 contract. Until #1943 lands,
// GET /api/hub/recovery answers 501 and this page shows that as a load error,
// never as "no data". There is no polling: a refresh under an open promote
// dialog buys nothing, so RELOAD is the refresh.

const remainingLabel = (s) => (s === null ? '—' : s < 60 ? `${s}s left` : `${fmtNum(Math.floor(s / 60))}m left`);
const asOf = (ms) => (typeof ms === 'number' ? `as of ${new Date(ms).toISOString().slice(11, 19)}Z` : '');
const PILL = { ok: 'pill', warn: 'pill pill--warn', dead: 'pill pill--dead', unknown: 'pill pill--muted' };
const pillLabel = (b) => b.badge || b.text;
// STATE sorts worst first: a box with no backup outranks a stale one, and a
// tone this page does not know sinks.
const TONE_RANK = { dead: 0, warn: 1, unknown: 2, ok: 3 };

const BACKUP_LEGEND = [
  { term: 'STATE', text: "whether this box's last backup is recent enough" },
  { term: 'AGE', text: 'how old the newest backup is' },
  { term: 'LAST REPORTED', text: 'when the box last told the hub about its backups' },
];

export const BACKUP_COLUMNS = [
  { key: 'box', label: 'BOX', sort: (r) => r.box, cell: (r) => html`<${Link} to="/machines" class="cell-name">${r.box}<//>` },
  { key: 'state', label: 'STATE', sort: (r) => TONE_RANK[r.badge.tone] ?? 4,
    cell: (r) => html`<span class=${PILL[r.badge.tone] || PILL.unknown} title=${r.badge.title}>${pillLabel(r.badge)}</span>` },
  { key: 'age', label: 'AGE', sort: (r) => r.ageMin,
    cell: (r) => (r.ageMin === null ? html`<span class="na">—</span>` : agoFromMinutes(r.ageMin)) },
  { key: 'reported', label: 'LAST REPORTED', sort: (r) => r.reportedMin,
    cell: (r) => (r.reportedMin === null ? html`<span class="na">never</span>` : html`<span title=${r.reportedAt}>${agoFromMinutes(r.reportedMin)} ago</span>`) },
];

// The promote dialog's fields. Like PauseForm (Project.js), it owns its state
// and writes every change through to `value`, the object the confirm reads,
// so typing never re-renders the page behind the dialog and the Modal's
// once-per-open focus effect keeps focus on the field being typed in (D39).
export function PromoteForm({ holder, epoch, targets, value, onBlocked }) {
  const [f, setF] = useState(value);
  const set = (k) => (e) => {
    value[k] = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(promoteFormState(value, targets).blocked);
  };
  const { hint } = promoteFormState(f, targets);
  const field = 'knob__input';
  const full = 'width:100%';
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>Move the hub lease off <b>${holder}</b> (epoch <b>${epoch}</b>). The promote is refused if the lease has moved since this page loaded.</span>
      <label class="knob" style=${full}>
        <span class="knob__label">TARGET</span>
        <select class=${field} style=${full} value=${f.target} onChange=${set('target')}>
          <option value="">choose a box</option>
          ${targets.map((t) => html`<option key=${t} value=${t}>${t}</option>`)}
        </select>
      </label>
      <label class="knob" style=${full}>
        <span class="knob__label">REASON</span>
        <input class=${field} style=${full} type="text" value=${f.reason} onInput=${set('reason')}
          placeholder="recorded on the lease change" required aria-required="true" />
      </label>
      <label class="knob" style=${full}>
        <span class="knob__label">Type the box name to confirm</span>
        <input class=${field} style=${full} type="text" value=${f.typed} onInput=${set('typed')}
          autocomplete="off" autocapitalize="off" spellcheck="false" />
      </label>
      ${hint ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${hint}</span>` : null}
    </div>`;
}

// What the dialog's confirm does: re-check the gate, send ONE promote with the
// epoch the dialog opened on, and turn the answer into the line the page
// shows. Never retried; a failure is a message, not a second request.
export async function runPromote(form, targets, epoch) {
  const gate = promoteFormState(form, targets);
  if (gate.blocked) return { ok: false, text: gate.hint };
  try {
    return promoteResult(await api.promoteHub(promoteBody(form.target, epoch, form.reason)));
  } catch (err) {
    return { ok: false, text: promoteOutcome(err) };
  }
}

// The page for one load state. HubScreen owns the state; this only draws it,
// so every state is renderable on its own.
export function HubView({ state, now, onReload, onPromote, promoteMsg }) {
  const { data, error, loading, fetchedAt } = state;
  const lease = data ? leaseView(data.lease, now) : null;
  const role = data ? roleView(data, now) : null;
  const rows = data ? backupRows(data, now) : [];
  const targets = data ? promoteTargets(data) : [];
  const promoteWhy = !lease ? 'No hub lease recorded.' : !targets.length ? 'No other box has reported to promote.' : null;

  return html`
    <div class="page">
      <${PageHeadline} chip="HUB"
        line1=${lease ? `${lease.holder || 'A box'} holds the hub lease.` : data ? 'No hub lease recorded.' : error ? 'The hub read failed.' : 'Reading the hub.'}
        line2=${data ? `${fmtNum(rows.length)} ${rows.length === 1 ? 'backup' : 'backups'} on record.` : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <button class="btn btn--sm" type="button" onClick=${onReload} disabled=${loading}>RELOAD</button>
        ${data ? html`<button class="btn btn--sm btn--danger" type="button" onClick=${onPromote}
          disabled=${Boolean(promoteWhy)} title=${promoteWhy || 'promote another box to hub'}>PROMOTE</button>` : null}
      </div>

      ${error ? html`
        <div class="banner" role="alert">
          <span>could not load — <b>${loadError(error)}</b></span>
          <button class="btn btn--sm" style="margin-left:auto" type="button" onClick=${onReload}>RELOAD</button>
        </div>` : null}

      ${!error && !data ? html`<${Skeleton} rows=${4} />` : null}

      ${promoteMsg ? html`<span class=${promoteMsg.ok ? 'knob__note' : 'knob__note knob__note--bad'}
        style="max-width:none" role="status">${promoteMsg.text}</span>` : null}

      ${data ? html`
        <${Section} title="LEASE" note=${asOf(fetchedAt)}>
          ${lease ? html`
            <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center">
              <span>holder <b>${lease.holder}</b></span>
              <span>epoch <b>${lease.epoch}</b></span>
              <span title=${lease.expiresAt || ''}>${remainingLabel(lease.remainingS)}</span>
              ${lease.expired ? html`<span class="pill pill--dead">EXPIRED</span>` : null}
            </div>` : html`<span>No hub lease recorded.</span>`}
        <//>
        <${Section} title="ROLE">
          <div style="display:flex;flex-wrap:wrap;gap:8px 16px">
            <span>active <b>${role.active || '—'}</b></span>
            ${role.expiredHolder ? html`<span>expired holder: <b>${role.expiredHolder}</b></span>` : null}
            ${role.standbyNote
              ? html`<span>${role.standbyNote}</span>`
              : html`<span>standby: <b>${role.standby.join(', ')}</b></span>`}
          </div>
        <//>
        <${StandbyPanel} data=${data} reloadKey=${fetchedAt} />
        <${Section} title="BACKUPS">
          <${SortableTable} columns=${BACKUP_COLUMNS} rows=${rows} rowKey=${(r) => r.box} defaultSort="box"
            empty=${html`<${Empty} title="No box has reported a backup stamp yet." />`} />
          ${rows.length ? html`<${Legend} items=${BACKUP_LEGEND} />` : null}
        <//>` : null}

      <${RestoreLabPanel} boxes=${rows.map((r) => r.box)} />
      <${SeedRegistryPanel} />
      <${ChatBindingsPanel} />
    </div>`;
}

export function HubScreen() {
  const [state, setState] = useState({ data: null, error: null, loading: true, fetchedAt: null });
  const [promoteMsg, setPromoteMsg] = useState(null);
  const [dialog, ask] = useConfirm();
  const loader = useRef(null);
  if (!loader.current) {
    loader.current = createLoader(() => api.hubRecovery(), (patch) => setState((s) => ({ ...s, ...patch })));
  }
  const load = loader.current;
  useEffect(() => { load(); }, []);

  const onPromote = async () => {
    const lease = leaseView(state.data && state.data.lease, Date.now());
    const targets = promoteTargets(state.data);
    if (!lease || !targets.length) return;
    // The epoch the operator is looking at is the one sent: if the lease moved
    // while the dialog was open, the worker answers stale_epoch.
    const epoch = lease.epoch;
    const form = { target: '', typed: '', reason: '' };
    const ok = await ask({
      title: 'PROMOTE A HUB', confirmLabel: 'PROMOTE', tone: 'danger', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${PromoteForm} holder=${lease.holder} epoch=${epoch} targets=${targets}
        value=${form} onBlocked=${setBlocked} />`
    });
    if (!ok) return;
    setPromoteMsg(null);
    const msg = await runPromote(form, targets, epoch);
    setPromoteMsg(msg);
    if (msg.ok) load();
  };

  return html`
    <${HubView} state=${state} now=${Date.now()} onReload=${load} onPromote=${onPromote} promoteMsg=${promoteMsg} />
    ${dialog}`;
}

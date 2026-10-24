// Which AI account one project bills (BH-7966, BH-7937.2): the fleet pool
// (`shared`), an existing active account, or a new account of the project's
// own. The pin is the settings row account.<project>, written through
// makeAccountSetter, so its in-app confirm and its PUT are the ones PROJECT
// ACCOUNTS already uses; a cancel writes nothing. "Its own account" opens the
// add sheet with use kind `project`, and the new label is pinned after it saves.
// BH-7937.4 opens this from the onboarding screens.

import { useState, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { api as realApi } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from './Modal.js';
import { makeAccountSetter } from '../lib/project-accounts.js';
import { activeAccounts, chooseAccount } from '../lib/ai-accounts.js';
import { AiAccountSheet, useSheetFocus } from '../screens/AiAccountSheet.js';

// AiAccountChoiceSheet({project, onDone}). onDone(result) runs on every
// outcome: {status:'written'|'cancelled'|'failed'|'closed', ...}.
export function AiAccountChoiceSheet({ project, onDone, api = realApi }) {
  const [dialog, confirm] = useConfirm();
  const [note, setNote] = useState(null);
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState(false);
  const accounts = useApi(() => api.aiAccounts(), []);
  const setter = makeAccountSetter({
    confirm: (opts) => confirm({ ...opts, body: html`<span>${opts.body}</span>` }),
    writeSetting: (body) => api.setCoordSetting(body),
    onNote: setNote
  });
  const finish = (res) => { if (onDone) onDone(res); };

  const onChoose = async (choice) => {
    if (busy) return;
    setBusy(true);
    try {
      const res = await chooseAccount({ choice, project, setter });
      if (res.status === 'open-add') { setAdding(true); return; }
      if (res.status !== 'cancelled') finish(res);
    } finally { setBusy(false); }
  };
  // The new project account saved: pin it, through the same confirm.
  const onSaved = async (saved) => {
    setAdding(false);
    const res = await chooseAccount({ choice: { kind: 'account', label: saved.label }, project, setter });
    finish(res);
  };

  if (adding) {
    return html`${dialog}<${AiAccountSheet} open=${true} mode="add" project=${project} api=${api}
      onClose=${() => setAdding(false)} onSaved=${onSaved}/>`;
  }
  return html`${dialog}<${AiAccountChoiceView} project=${project} accounts=${activeAccounts(accounts.data)}
    loading=${accounts.loading && !accounts.data} error=${accounts.error} note=${note} busy=${busy}
    onChoose=${onChoose} onClose=${() => finish({ status: 'closed' })}/>`;
}

export function AiAccountChoiceView({ project, accounts, loading, error, note, busy, onChoose, onClose }) {
  const [pick, setPick] = useState('');
  const ref = useRef(null);
  useSheetFocus(true, ref, onClose);
  return html`
    <div class="aisheet__scrim" onClick=${(e) => { if (e.target === e.currentTarget && onClose) onClose(); }}>
      <div class="aisheet aisheet--open" role="dialog" aria-modal="true" aria-label=${`AI account for ${project}`} ref=${ref}>
        <span class="aisheet__title">AI ACCOUNT FOR ${project}</span>
        <div class="aisheet__choice">
          <button type="button" class="btn" disabled=${busy} onClick=${() => onChoose({ kind: 'pool' })}>USE THE FLEET POOL</button>
          <span class="aisheet__hint">Bill the shared accounts (account.${project} = shared).</span>
        </div>
        <div class="aisheet__choice">
          <label class="aisheet__field"><span>AN EXISTING ACCOUNT</span>
            ${loading ? html`<span class="na">loading…</span>`
              : error ? html`<span class="knob__note knob__note--bad">could not read the accounts: ${String(error.message || error)}</span>`
              : accounts.length ? html`
                <select value=${pick} disabled=${busy} onChange=${(e) => setPick(e.target.value)}>
                  <option value="">choose an active account</option>
                  ${accounts.map((a) => html`<option key=${a.id} value=${a.label}>${a.vendor} / ${a.label}</option>`)}
                </select>`
              : html`<span class="na">no active account yet</span>`}
          </label>
          <button type="button" class="btn" disabled=${busy || !pick} onClick=${() => onChoose({ kind: 'account', label: pick })}>USE THIS ACCOUNT</button>
        </div>
        <div class="aisheet__choice">
          <button type="button" class="btn" disabled=${busy} onClick=${() => onChoose({ kind: 'own' })}>ADD THIS PROJECT'S OWN ACCOUNT</button>
          <span class="aisheet__hint">Opens the add sheet with use kind project.</span>
        </div>
        ${note ? html`<p class=${note.ok ? 'aisheet__status' : 'aisheet__status aisheet__status--error'} role="status">${note.text}</p>` : null}
        <div class="aisheet__actions">
          <button type="button" class="btn" onClick=${onClose}>CLOSE</button>
        </div>
      </div>
    </div>`;
}

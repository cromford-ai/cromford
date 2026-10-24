// The AI account add sheet (BH-7966, BH-7937.2). The operator picks a vendor,
// names the account with a label, pastes the token and presses TEST AND SAVE.
// The token is sealed in this page to the hub key and leaves only as an
// envelope ciphertext; the token is cleared from state on every exit. Then the
// sheet polls the envelope status and says what it found: proved, failed, or
// still waiting for the hub. A bottom sheet at 640px and below, a side sheet
// above (src/ai-accounts.css).

import { useState, useEffect, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { api as realApi } from '../api.js';
import { sealSecret } from '../lib/envelope.js';
import { VENDORS, USE_KINDS, loadSheetConfig, saveAccount, pollStatus } from '../lib/ai-accounts.js';

const blankForm = ({ project, old }) => ({
  vendor: old ? old.vendor : 'claude',
  label: '',
  token: '',
  plan: old && old.plan ? old.plan : '',
  use_kind: project ? 'project' : old ? old.use_kind : 'pool',
  project: project || (old && old.use_kind === 'project' && old.projects && old.projects[0]) || null
});
const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));

// Focus moves into the sheet when it opens and back to the opener when it
// closes; Escape closes; Tab stays inside (the Modal.js pattern). A confirm
// modal above the sheet owns Escape and Tab while it is open.
export function useSheetFocus(open, sheetRef, onClose) {
  const openerRef = useRef(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    if (!open) return undefined;
    openerRef.current = document.activeElement;
    const el = sheetRef.current;
    const first = el && el.querySelector('select, input, textarea, button');
    if (first) first.focus();
    const onKey = (e) => {
      if (document.querySelector('.modal__scrim')) return;
      if (e.key === 'Escape') { e.preventDefault(); if (closeRef.current) closeRef.current(); }
      if (e.key === 'Tab' && el) {
        const f = el.querySelectorAll('button, input, select, textarea');
        if (!f.length) return;
        const a = f[0]; const z = f[f.length - 1];
        if (e.shiftKey && document.activeElement === a) { e.preventDefault(); z.focus(); }
        else if (!e.shiftKey && document.activeElement === z) { e.preventDefault(); a.focus(); }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      const o = openerRef.current;
      if (o && typeof o.focus === 'function' && document.contains(o)) o.focus();
    };
  }, [open]);
}

// AiAccountSheet({open, mode:'add'|'rotate', project?, old?, onClose, onSaved, api?})
// `project` (from the choice sheet) fixes use kind `project` for that project.
// `old` (rotate) prefills vendor, plan and use kind; the label starts empty.
export function AiAccountSheet({ open, mode = 'add', project = null, old = null, onClose, onSaved, api = realApi }) {
  const [form, setForm] = useState(() => blankForm({ project, old }));
  const [config, setConfig] = useState(null);
  const [configError, setConfigError] = useState(null);
  const [phase, setPhase] = useState('idle');
  const [message, setMessage] = useState(null);
  const sheetRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    setForm(blankForm({ project, old }));
    setPhase('idle');
    setMessage(null);
    let alive = true;
    loadSheetConfig(api).then((c) => { if (alive) { setConfig(c); setConfigError(null); } },
      (e) => { if (alive) setConfigError(e); });
    return () => { alive = false; };
  }, [open, project, old && old.id]);

  useSheetFocus(open, sheetRef, onClose);

  const onField = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  const onSubmit = async () => {
    if (phase === 'saving' || phase === 'polling') return;
    setPhase('saving');
    setMessage(null);
    let res;
    try {
      res = await saveAccount({ api, seal: sealSecret, form, config, rotateFrom: mode === 'rotate' ? old : null });
    } finally {
      // The token never outlives the attempt, whatever it answered.
      setForm((f) => ({ ...f, token: '' }));
    }
    if (res.status !== 'saved') { setPhase(res.status === 'no-key' ? 'idle' : 'error'); setMessage(res.message); return; }
    if (onSaved) onSaved(res);
    setMessage(res.message || null);
    setPhase('polling');
    const end = await pollStatus({ api, envelopeId: res.envelope_id, pollS: config.pollS, waitS: config.waitS, sleep: sleepMs, now: () => Date.now() });
    setPhase(end);
  };

  return html`<${AiAccountSheetView} open=${open} mode=${mode} project=${project} old=${old} form=${form}
    config=${config} configError=${configError} phase=${phase} message=${message}
    sheetRef=${sheetRef} onField=${onField} onSubmit=${onSubmit} onClose=${onClose}/>`;
}

const PHASE_COPY = {
  saving: 'Sealing the token and saving…',
  polling: 'Saved. Waiting for the hub to apply it…',
  proved: 'PROVED: the hub applied the token.',
  failed: 'FAILED: the hub did not apply the token (the apply failed or the envelope expired). Add it again with a new label.',
  waiting: 'STILL WAITING: the hub has not applied it yet; it shows pending in the table.'
};

export function AiAccountSheetView({ open, mode, project, old, form, config, configError, phase = 'idle', message, sheetRef, onField, onSubmit, onClose }) {
  if (!open) return null;
  const set = (k) => (e) => onField && onField(k, e.target.value);
  const vendor = VENDORS.find((v) => v.id === form.vendor) || VENDORS[0];
  const noKey = Boolean(config) && !config.publicKey;
  const busy = phase === 'saving' || phase === 'polling';
  const done = phase === 'proved' || phase === 'failed' || phase === 'waiting' || phase === 'polling';
  const title = mode === 'rotate' ? 'ROTATE AI ACCOUNT' : 'ADD AI ACCOUNT';
  return html`
    <div class="aisheet__scrim" onClick=${(e) => { if (e.target === e.currentTarget && onClose) onClose(); }}>
      <div class="aisheet aisheet--open" role="dialog" aria-modal="true" aria-label=${title} ref=${sheetRef}>
        <span class="aisheet__title">${title}</span>
        ${mode === 'rotate' && old ? html`<p class="aisheet__note">Rotating ${old.label}: this adds a new label; the old one is revoked after this one saves.</p>` : null}
        ${configError ? html`<div class="banner"><span>could not read the hub key: <b>${String(configError.message || configError)}</b></span></div>` : null}
        ${noKey ? html`<div class="banner"><span><b>The hub key is not set yet (run bin/envelope-keygen.sh on the hub).</b> Nothing is sent until it is.</span></div>` : null}
        <form class="aisheet__form" onSubmit=${(e) => { e.preventDefault(); if (onSubmit) onSubmit(); }}>
          <label class="aisheet__field"><span>VENDOR</span>
            <select value=${form.vendor} disabled=${busy || done} onChange=${set('vendor')}>
              ${VENDORS.map((v) => html`<option value=${v.id} selected=${v.id === form.vendor}>${v.label}</option>`)}
            </select>
          </label>
          <span class="aisheet__hint">${vendor.label}: ${vendor.hint}.</span>
          <label class="aisheet__field"><span>LABEL</span>
            <input type="text" value=${form.label} placeholder="team-a" autocomplete="off" spellcheck="false" maxlength="48"
              disabled=${busy || done} onInput=${set('label')}/>
          </label>
          <label class="aisheet__field"><span>TOKEN</span>
            <input type="password" value=${form.token} autocomplete="off" spellcheck="false"
              disabled=${busy || done} onInput=${set('token')}/>
          </label>
          <label class="aisheet__field"><span>USE</span>
            <select value=${form.use_kind} disabled=${busy || done || Boolean(project)} onChange=${set('use_kind')}>
              ${USE_KINDS.map((u) => html`<option value=${u.id} selected=${u.id === form.use_kind}>${u.label}: ${u.note}</option>`)}
            </select>
          </label>
          ${form.use_kind === 'project' ? html`
            <label class="aisheet__field"><span>PROJECT</span>
              <input type="text" value=${form.project || ''} readonly=${Boolean(project)} autocomplete="off" spellcheck="false"
                disabled=${busy || done} onInput=${set('project')}/>
            </label>` : null}
          <label class="aisheet__field"><span>PLAN</span>
            <input type="text" value=${form.plan} placeholder="max, pro, api…" autocomplete="off" maxlength="64"
              disabled=${busy || done} onInput=${set('plan')}/>
          </label>
          ${phase !== 'idle' && PHASE_COPY[phase] ? html`<p class=${`aisheet__status aisheet__status--${phase}`} role="status">${PHASE_COPY[phase]}</p>` : null}
          ${message ? html`<p class="aisheet__status aisheet__status--error" role="alert">${message}</p>` : null}
          <div class="aisheet__actions">
            <button type="button" class="btn" onClick=${onClose}>${done ? 'CLOSE' : 'CANCEL'}</button>
            ${done ? null : html`<button type="submit" class="btn btn--primary" disabled=${busy || noKey || !config}>
              ${busy ? '…' : 'TEST AND SAVE'}</button>`}
          </div>
        </form>
      </div>
    </div>`;
}

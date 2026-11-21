import { useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../router.js';
import { AuthError } from '../api.js';
import { fieldError, maskTokens, sendBody, trimPaste, OWNER_LINE } from '../lib/signal-keys.js';
import { signalKeySet, signalKeyTest } from '../lib/signal-keys-api.js';
import { sheetKeyHandler } from '../lib/tracker-sheets.js';

// The Set/Replace sheet of the project Signals page (BH-9839). One input per
// field of the kind, in the catalog's order, each with a visible label above
// it and the field's format as the placeholder. The secret field is a
// password input that the server never fills: Replace fills only the
// non-secret fields from the row. A paste is trimmed (never refused); a blur
// runs the prefix and format check and shows the error under that field with
// the value kept. Save checks every field, sends the set, empties the secret
// from state, then runs the test and shows its result here. A bottom sheet
// below 720 px, a panel above (src/signals.css). Nothing goes to storage.

const SECRET_KEPT = 'The key is stored encrypted. It is never shown again.';

// The sheet as a function of its state, so a test can render any state.
export function SignalKeySheetView({
  project, kind, mode, values, errors, phase, note, formError, boxRef,
  onInput, onPaste, onBlur, onSave, onClose
}) {
  const id = (n) => `ksheet-${kind.kind}-${n}`;
  const busy = phase === 'saving';
  const done = phase === 'saved';
  const title = `${mode === 'replace' ? 'Replace' : 'Set'} the ${kind.label} key of ${project}`;
  return html`
    <div class="ksheet__scrim" onClick=${(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div class="ksheet" ref=${boxRef} role="dialog" aria-modal="true" aria-labelledby=${id('title')}>
        <h2 class="ksheet__title" id=${id('title')}>${title}</h2>
        <div class="ksheet__body">
          ${kind.fields.map((f) => {
            const err = errors[f.name];
            return html`
              <div class="ksheet__field" key=${f.name}>
                <label class="ksheet__label" for=${id(f.name)}>${f.label}</label>
                <input id=${id(f.name)} name=${f.name} type=${f.secret ? 'password' : 'text'}
                  autocomplete=${f.secret ? 'off' : undefined} spellcheck=${false}
                  placeholder=${f.placeholder || ''} value=${values[f.name] ?? ''} disabled=${busy || done}
                  aria-invalid=${err ? 'true' : undefined} aria-describedby=${err ? id(`${f.name}-err`) : undefined}
                  onInput=${(e) => onInput(f.name, e.currentTarget.value)}
                  onPaste=${(e) => onPaste(f.name, e)}
                  onBlur=${(e) => onBlur(f.name, e.currentTarget.value)} />
                ${err ? html`<span class="ksheet__error" id=${id(`${f.name}-err`)} role="alert">${err}</span>` : null}
              </div>`;
          })}
        </div>
        ${formError ? html`<p class="ksheet__error" role="alert">${formError}</p>` : null}
        ${busy ? html`<p class="ksheet__note" role="status">Saving…</p>` : null}
        ${done ? html`<p class="ksheet__note" role="status">${note}</p><p class="ksheet__note">${SECRET_KEPT}</p>` : null}
        <div class="ksheet__actions">
          ${done
            ? html`<button class="btn btn--primary" type="button" onClick=${onClose}>Done</button>`
            : html`
              <button class="btn" type="button" disabled=${busy} onClick=${onClose}>Cancel</button>
              <button class="btn btn--primary" type="button" disabled=${busy} onClick=${onSave}>Save</button>`}
        </div>
      </div>
    </div>`;
}

const initialValues = (kind, row) => Object.fromEntries(kind.fields.map((f) => [
  f.name, !f.secret && row && row.fields && typeof row.fields[f.name] === 'string' ? row.fields[f.name] : ''
]));

// Props: project, kind (a catalog entry of the list), row (null for Set),
// onClose(saved) — saved is true once a set has landed.
export function SignalKeySheet({ project, kind, row, onClose }) {
  const [values, setValues] = useState(() => initialValues(kind, row));
  const [errors, setErrors] = useState({});
  const [phase, setPhase] = useState('idle');
  const [note, setNote] = useState('');
  const [formError, setFormError] = useState('');
  const boxRef = useRef(null);
  const savedRef = useRef(false);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  const close = () => closeRef.current(savedRef.current);

  // Focus the first field once per open; Escape and Tab through refs, so a
  // parent re-render never re-runs this and moves focus (D39).
  useEffect(() => {
    const first = boxRef.current && boxRef.current.querySelector('input');
    if (first) first.focus();
    const onKey = sheetKeyHandler(() => close(), () => boxRef.current, document);
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, []);

  const setField = (name, v) => setValues((s) => ({ ...s, [name]: v }));
  const setFieldError = (name, msg) => setErrors((s) => {
    const next = { ...s };
    if (msg) next[name] = msg; else delete next[name];
    return next;
  });
  const defOf = (name) => kind.fields.find((f) => f.name === name);

  const onInput = (name, v) => setField(name, v);
  const onPaste = (name, e) => {
    const text = e && e.clipboardData && typeof e.clipboardData.getData === 'function' ? e.clipboardData.getData('text') : null;
    if (typeof text !== 'string') return;
    e.preventDefault();
    setField(name, trimPaste(text));
    setFieldError(name, null);
  };
  // The check on leaving a field. A blank field is not an error until Save.
  const onBlur = (name, v) => {
    if (!trimPaste(v)) { setFieldError(name, null); return; }
    setFieldError(name, fieldError(defOf(name), v));
  };

  const onSave = async () => {
    const errs = {};
    for (const f of kind.fields) {
      const e = fieldError(f, values[f.name]);
      if (e) errs[f.name] = e;
    }
    setErrors(errs);
    setFormError('');
    if (Object.keys(errs).length) return;
    setPhase('saving');
    const body = sendBody(project, kind.kind, kind.fields, values);
    try {
      const r = await signalKeySet(body);
      if (!r || r.stored !== true) throw new Error('the key was not stored');
    } catch (e) {
      setPhase('idle');
      if (e instanceof AuthError) { window.dispatchEvent(new CustomEvent('dash:unauthorized')); return; }
      if (e.refused) { setFormError(OWNER_LINE); return; }
      const field = e.body && typeof e.body.field === 'string' && defOf(e.body.field) ? e.body.field : null;
      if (field) setFieldError(field, maskTokens(e.message));
      else setFormError(`Not saved: ${maskTokens(e.message)}`);
      return;
    }
    // Stored: the secret leaves this component's state now.
    savedRef.current = true;
    setValues((s) => Object.fromEntries(Object.entries(s).map(([k, v]) => [k, defOf(k) && defOf(k).secret ? '' : v])));
    let line;
    try {
      const t = await signalKeyTest({ project, kind: kind.kind });
      line = t && t.ok === true ? 'Saved. Test: ok' : `Saved. Test: ${t && t.result}${t && t.reason ? ` — ${t.reason}` : ''}`;
    } catch (e) {
      if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
      line = `Saved. The test did not run: ${e.refused ? OWNER_LINE : maskTokens(e.message)}`;
    }
    setNote(maskTokens(line));
    setPhase('saved');
  };

  return html`<${SignalKeySheetView} project=${project} kind=${kind} mode=${row ? 'replace' : 'set'}
    values=${values} errors=${errors} phase=${phase} note=${note} formError=${formError} boxRef=${boxRef}
    onInput=${onInput} onPaste=${onPaste} onBlur=${onBlur} onSave=${onSave} onClose=${close}/>`;
}

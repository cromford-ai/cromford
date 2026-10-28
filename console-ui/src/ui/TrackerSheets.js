import { useEffect, useRef, useState } from 'preact/hooks';
import { html } from '../router.js';
import {
  TRACKER_FIELDS, TRACKER_TITLES, JIRA_STATUS_DEFAULTS, defaultStatuses, initialValues,
  missingField, sendFields, publicFields, trackerClient, runTrackerTest, sheetKeyHandler
} from '../lib/tracker-sheets.js';
import { sealSecret } from '../lib/envelope.js';

// The tracker connect sheets (BH-7936, onboarding UI wave 3): Linear, Jira and
// the app's own board. One sheet per tracker, with the fields of decision 1, a
// Later button and a Test and connect button. Test and connect seals the
// fields to the hub key, stores them as a secret envelope (POST
// /api/coord/secrets/envelope, scope tracker:<kind>:<project>), files a hub
// test with the envelope id (POST /api/coord/onboarding/tracker-test) and
// polls its answer every 5 s. `ok` calls onConnected with the fields minus
// the credential; an error shows in place and keeps every field. A bottom
// sheet below 720 px, a centred panel above (src/ui/TrackerSheets.css).
// Nothing is stored in the browser: the credential lives in this component's
// state, and only its ciphertext leaves the page.
//
// Props: kind (linear|jira|board), project, onConnected({kind, fields,
// test_id}), onLater(), `client` (the coord calls) and `seal` (default
// sealSecret); tests may pass either.

export { JIRA_STATUS_DEFAULTS };

const PENDING_COPY = 'Testing. The hub runs the test within 10 minutes.';

// The sheet as a function of its state. Exported so a test can render any
// state (an error, a blank field) without a DOM.
export function TrackerSheetView({ kind, values, statuses, phase, error, note, boxRef, onChange, onStatus, onTest, onLater }) {
  const fields = TRACKER_FIELDS[kind] || [];
  const missing = missingField(kind, values, statuses);
  const busy = phase === 'testing';
  const id = (n) => `tsheet-${kind}-${n}`;
  return html`
    <div class="tsheet__scrim" onClick=${(e) => { if (e.target === e.currentTarget && !busy) onLater(); }}>
      <div class="tsheet" ref=${boxRef} role="dialog" aria-modal="true" aria-labelledby=${id('title')}>
        <h2 class="tsheet__title" id=${id('title')}>${TRACKER_TITLES[kind] || kind}</h2>
        <div class="tsheet__body">
          ${fields.map((f) => html`
            <label class="tsheet__field" for=${id(f.name)}>
              <span class="tsheet__label">${f.label}</span>
              <input id=${id(f.name)} name=${f.name} type=${f.secret ? 'password' : 'text'}
                autocomplete=${f.secret ? 'off' : undefined} spellcheck=${false}
                placeholder=${f.placeholder || ''} value=${values[f.name] ?? ''} disabled=${busy}
                onInput=${(e) => onChange(f.name, e.currentTarget.value)} />
              ${f.hint ? html`<span class="tsheet__hint">${f.hint}</span>` : null}
            </label>`)}
          ${kind === 'jira' ? html`
            <fieldset class="tsheet__statuses">
              <legend class="tsheet__label">Status map</legend>
              ${JIRA_STATUS_DEFAULTS.map((r) => html`
                <label class="tsheet__status" for=${id(`status_${r.key}`)}>
                  <span class="tsheet__state">${r.label}</span>
                  <input id=${id(`status_${r.key}`)} name=${`status_${r.key}`} type="text" spellcheck=${false}
                    value=${(statuses || {})[r.key] ?? ''} disabled=${busy}
                    onInput=${(e) => onStatus(r.key, e.currentTarget.value)} />
                </label>`)}
            </fieldset>` : null}
        </div>
        ${phase === 'error' && error ? html`<div class="tsheet__error" role="alert">${error}</div>` : null}
        ${busy ? html`<p class="tsheet__note" role="status">${PENDING_COPY}${note ? ` (${note})` : ''}</p>` : null}
        ${!busy && missing ? html`<p class="tsheet__note" aria-live="polite">Fill in ${missing.label}.</p>` : null}
        <div class="tsheet__actions">
          <button class="btn" type="button" onClick=${onLater}>Later</button>
          <button class="btn btn--primary" type="button" disabled=${Boolean(missing) || busy}
            onClick=${() => { if (!missing && !busy) onTest(); }}>${busy ? 'Testing' : 'Test and connect'}</button>
        </div>
      </div>
    </div>`;
}

export function TrackerSheet({ kind, project, onConnected, onLater, client, seal }) {
  const [values, setValues] = useState(() => initialValues(kind));
  const [statuses, setStatuses] = useState(() => defaultStatuses());
  const [phase, setPhase] = useState('idle');
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const boxRef = useRef(null);
  const abortRef = useRef(null);
  const laterRef = useRef(onLater);
  laterRef.current = onLater;

  // Focus the first field once per open; Escape and Tab through a ref, so a
  // parent re-render never re-runs this and moves focus (D39).
  useEffect(() => {
    const box = boxRef.current;
    const first = box && box.querySelector('input');
    if (first) first.focus();
    const onKey = sheetKeyHandler(() => laterRef.current(), () => boxRef.current, document);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      if (abortRef.current) abortRef.current.abort();
    };
  }, []);

  const test = async () => {
    if (abortRef.current) abortRef.current.abort();
    const ac = new AbortController();
    abortRef.current = ac;
    const fields = sendFields(kind, values, statuses);
    setPhase('testing'); setError(''); setNote('');
    const r = await runTrackerTest({
      client: client || trackerClient(), seal: seal || sealSecret, project, kind, fields, signal: ac.signal,
      onPending: (p) => setNote(p && p.note ? String(p.note) : '')
    });
    if (r.state === 'aborted') return;
    abortRef.current = null;
    if (r.state === 'ok') {
      setPhase('ok');
      onConnected({ kind, fields: publicFields(kind, fields), test_id: r.test_id });
      return;
    }
    setPhase('error');
    setError(r.error);
  };

  return html`<${TrackerSheetView} kind=${kind} values=${values} statuses=${statuses} phase=${phase}
    error=${error} note=${note} boxRef=${boxRef}
    onChange=${(name, v) => setValues((s) => ({ ...s, [name]: v }))}
    onStatus=${(key, v) => setStatuses((s) => ({ ...s, [key]: v }))}
    onTest=${test} onLater=${() => { if (abortRef.current) abortRef.current.abort(); onLater(); }} />`;
}

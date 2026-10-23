import { useState, useEffect, useMemo } from 'preact/hooks';
import { html } from '../router.js';
import { AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Skeleton, ErrorBox } from './primitives.js';
import { useConfirm } from './Modal.js';
import { PromptVersionsSheet, UseLevelAboveButton } from './PromptHistoryActions.js';
import { loadEditor, savePrompt, lineDiff, missingMarkers } from '../lib/prompts.js';
import MARKERS from '../../../catalog/prompt-markers.json' with { type: 'json' };

// The prompt editor (BH-7940.5): one kind in one scope. A full-width textarea,
// a line diff against the previous version and against the level above, the
// marker lint in place, and SAVE through the confirm modal with a note.
// `markers` defaults to catalog/prompt-markers.json; `Versions` and
// `LevelAbove` default to the history seam BH-7940.4 fills.

export function PromptEditor({
  scope, project, kind, onSaved, markers = MARKERS,
  Versions = PromptVersionsSheet, LevelAbove = UseLevelAboveButton
}) {
  const ed = useApi(() => loadEditor({ scope, project, kind }), [scope, project, kind]);
  const [text, setText] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const [dialog, ask] = useConfirm();

  // Fresh reads (first load, a restore, a drop) reset the text to what they say.
  useEffect(() => { if (ed.data) setText(ed.data.startText); }, [ed.data]);

  const where = scope === 'project' ? `project ${project}` : 'the fleet';
  const head = html`<h2 class="prompt-editor__title">${kind} · ${where}</h2>`;

  if (ed.error && !ed.data) {
    return html`<div class="prompt-editor">${head}<${ErrorBox} error=${ed.error} onRetry=${ed.reload}/></div>`;
  }
  if (!ed.data) {
    return html`<div class="prompt-editor">${head}<${Skeleton} rows=${8} height=${16}/></div>`;
  }

  const d = ed.data;
  const current = text === null ? d.startText : text;
  const missing = missingMarkers(kind, current, markers);
  const listed = markers && Array.isArray(markers[kind]) && markers[kind].length > 0;
  const canSave = !saving && current !== d.startText && current.trim() !== '';

  const onSave = async () => {
    let note = '';
    const ok = await ask({
      title: `SAVE ${kind}`,
      confirmLabel: 'SAVE VERSION',
      confirmBlocked: true,
      body: ({ setBlocked }) => html`
        <p>Save a new version of <b>${kind}</b> for ${where}.</p>
        ${listed ? html`<p>${missing.length ? `Missing marker: ${missing.join(', ')}` : 'Markers: all present'}</p>` : null}
        <textarea class="prompt-note" rows="3" aria-label="note" placeholder="why this change"
          onInput=${(e) => { note = e.target.value; setBlocked(!note.trim()); }}></textarea>`
    });
    if (!ok) return;
    setSaving(true);
    setSaveError(null);
    try {
      await savePrompt({ scope, kind, project, body: current, note: note.trim(), baseVersion: d.baseVersion });
      if (onSaved) onSaved();
    } catch (e) {
      if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
      setSaveError(e);
    } finally {
      setSaving(false);
    }
  };

  return html`
    <div class="prompt-editor">
      ${head}
      <div class="prompt-editor__actions">
        <${Versions} scope=${scope} project=${project} kind=${kind} onRestored=${ed.reload}/>
        <${LevelAbove} scope=${scope} project=${project} kind=${kind} onDropped=${ed.reload}/>
      </div>
      ${listed ? html`<div class="prompt-lint">
        ${missing.length
          ? missing.map((m) => html`<p role="status" class="prompt-lint__bad" key=${m}>Missing marker: ${m}</p>`)
          : html`<p role="status" class="prompt-lint__ok">Markers: all present</p>`}
      </div>` : null}
      <textarea class="prompt-editor__text" aria-label=${`${kind} prompt`} rows="24" spellcheck="false"
        value=${current} onInput=${(e) => setText(e.target.value)}></textarea>
      ${saveError ? html`<div class="prompt-lint">${saveErrorLines(saveError).map((l) => html`
        <p role="alert" class="prompt-lint__bad" key=${l}>${l}</p>`)}</div>` : null}
      <div class="prompt-editor__actions">
        <button type="button" class="btn btn--primary" disabled=${!canSave} onClick=${onSave}>SAVE</button>
        ${d.baseVersion ? html`<span class="prompt-editor__meta">editing on version ${d.baseVersion}</span>` : null}
      </div>
      <${PreviousPanel} previous=${d.previous} text=${current}/>
      <${AbovePanel} above=${d.above} text=${current}/>
      ${dialog}
    </div>`;
}

// One plain line per refusal. The textarea keeps the text in every case.
function saveErrorLines(e) {
  const body = (e && e.body) || {};
  if (e.status === 422 && body.error === 'missing_marker' && Array.isArray(body.missing)) {
    return body.missing.map((m) => `The server refused the save. Missing marker: ${m}`);
  }
  if (e.status === 422 && body.error === 'empty_body') return ['The server refused an empty body.'];
  if (e.status === 409) return ['Someone saved a newer version first. Open the list again to load it. Your text is still here.'];
  if (e.status === 413) return [`The body is larger than the server limit of ${body.max_bytes} bytes.`];
  return [`The save failed: ${e.message || String(e)}`];
}

function Diff({ from, text }) {
  const rows = useMemo(() => lineDiff(from, text), [from, text]);
  if (!rows.some((r) => r.op !== ' ')) return html`<p class="prompt-editor__meta">No change.</p>`;
  const cls = { '+': 'prompt-diff__add', '-': 'prompt-diff__del', ' ': 'prompt-diff__ctx' };
  return html`<pre class="prompt-diff">${rows.map((r, i) => html`<span key=${i} class=${cls[r.op]}>${r.op} ${r.text}</span>`)}</pre>`;
}

function PreviousPanel({ previous, text }) {
  let body;
  let title = 'AGAINST THE PREVIOUS VERSION';
  if (!previous) body = html`<p class="prompt-editor__meta">No saved version yet.</p>`;
  else if (previous.version === 0) body = html`<p class="prompt-editor__meta">No previous version.</p>`;
  else if (previous.archived) body = html`<p class="prompt-editor__meta">Version ${previous.version} is archived.</p>`;
  else {
    title = `AGAINST VERSION ${previous.version}`;
    body = html`<${Diff} from=${previous.body} text=${text}/>`;
  }
  return html`<section class="prompt-editor__panel" data-testid="diff-previous">
    <span class="section__title">${title}</span>${body}</section>`;
}

function AbovePanel({ above, text }) {
  if (above.level === 'repo') {
    return html`<section class="prompt-editor__panel" data-testid="diff-above">
      <span class="section__title">AGAINST THE LEVEL ABOVE</span>
      <p class="prompt-editor__meta">The level above is the repo file ${above.path}. The console cannot read it.</p>
    </section>`;
  }
  return html`<section class="prompt-editor__panel" data-testid="diff-above">
    <span class="section__title">AGAINST FLEET VERSION ${above.version}</span>
    <${Diff} from=${above.body} text=${text}/>
  </section>`;
}

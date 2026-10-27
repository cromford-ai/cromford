import { useState, useEffect, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { AuthError } from '../api.js';
import { useConfirm } from './Modal.js';
import { SortableTable } from './SortableTable.js';
import { Skeleton } from './primitives.js';
import { listVersions, restoreVersion, dropHead } from '../lib/prompt-history.js';

// The prompt editor's history actions (BH-7940.4; docs/PROMPTS.md, "Markers,
// versions and restore"). PromptEditor (BH-7940.5) renders both with scope,
// project, kind and a reload callback. Restore and drop go through the
// console confirm modal; nothing here reads before a click.

const unauthorized = (e) => { if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized')); };
const when = (at) => String(at || '').replace('T', ' ').replace(/:\d\d(\.\d+)?Z$/, 'Z');

// One plain line per restore refusal.
function restoreError(e, version) {
  const body = (e && e.body) || {};
  if (e.status === 422 && body.error === 'missing_marker' && Array.isArray(body.missing)) {
    return `Restore refused. Missing marker: ${body.missing.join(', ')}`;
  }
  if (e.status === 404 && body.error === 'archived') return `v${version} is archived. It cannot be restored.`;
  if (e.status === 404) return `v${version} was not found.`;
  if (e.status === 409) return 'Someone saved a newer version first. Open VERSIONS again.';
  return `The restore failed: ${e.message || String(e)}`;
}

// A VERSIONS button. A click opens the sheet and reads the list once; each
// row has a RESTORE that saves that version again as the next one.
export function PromptVersionsSheet({ scope, project, kind, onRestored }) {
  const [open, setOpen] = useState(false);
  const [list, setList] = useState({ rows: null, error: null });
  const [refusal, setRefusal] = useState(null);
  const [done, setDone] = useState(null);
  const [busy, setBusy] = useState(false);
  const [dialog, ask] = useConfirm();
  const closeRef = useRef(null);
  const reads = useRef(0);

  useEffect(() => { if (open && closeRef.current) closeRef.current.focus(); }, [open]);

  const show = async () => {
    const n = ++reads.current;
    setOpen(true);
    setRefusal(null);
    setList({ rows: null, error: null });
    try {
      const rows = await listVersions({ scope, project, kind });
      if (n === reads.current) setList({ rows, error: null });
    } catch (e) {
      unauthorized(e);
      if (n === reads.current) setList({ rows: null, error: e });
    }
  };
  const close = () => { reads.current++; setOpen(false); };

  const onRestore = async (v) => {
    const ok = await ask({
      title: `RESTORE v${v.version}`,
      confirmLabel: 'RESTORE',
      body: html`<p>Save the text of v${v.version} again as a new version of <b>${kind}</b>.
        It becomes the version in use. v${v.version} and every other version stay.</p>`
    });
    if (!ok) return;
    setBusy(true);
    setRefusal(null);
    try {
      const res = await restoreVersion({ scope, project, kind, version: v.version });
      close();
      setDone(`Restored v${res.restored_from} as v${res.version}.`);
      if (onRestored) onRestored();
    } catch (e) {
      unauthorized(e);
      setRefusal(restoreError(e, v.version));
    } finally {
      setBusy(false);
    }
  };

  const columns = [
    { key: 'version', label: 'VERSION', cell: (r) => html`<span class="cell-name">v${r.version}</span>` },
    { key: 'author', label: 'WHO', cell: (r) => r.author },
    { key: 'created_at', label: 'WHEN', cell: (r) => when(r.created_at) },
    { key: 'note', label: 'NOTE', flex: true, cell: (r) => r.note },
    {
      key: 'action', label: '', sort: null,
      cell: (r) => html`<button type="button" class="btn" disabled=${busy} onClick=${() => onRestore(r)}>RESTORE</button>`
    }
  ];

  let content;
  if (list.error) content = html`<p role="alert" class="prompt-lint__bad">could not load — ${list.error.message || String(list.error)}</p>`;
  else if (!list.rows) content = html`<${Skeleton} rows=${4} height=${16}/>`;
  else {
    content = html`<${SortableTable} columns=${columns} rows=${list.rows} rowKey=${(r) => r.id}
      defaultSort="version" defaultDir="desc"
      empty=${html`<p class="prompt-editor__meta">No saved versions.</p>`}/>`;
  }

  return html`
    <button type="button" class="btn" onClick=${show}>VERSIONS</button>
    ${done ? html`<span role="status" class="prompt-editor__meta">${done}</span>` : null}
    ${open ? html`
      <div class="prompt-versions__scrim" onClick=${(e) => { if (e.target === e.currentTarget) close(); }}>
        <div class="prompt-versions" role="dialog" aria-modal="true" aria-label=${`Versions of ${kind}`}
          onKeyDown=${(e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } }}>
          <div class="prompt-versions__head">
            <span class="section__title">VERSIONS · ${kind}</span>
            <button type="button" class="btn" ref=${closeRef} onClick=${close}>CLOSE</button>
          </div>
          ${refusal ? html`<p role="alert" class="prompt-lint__bad">${refusal}</p>` : null}
          ${content}
        </div>
      </div>` : null}
    ${dialog}`;
}

// USE LEVEL ABOVE: drop this level's head after a confirm. The versions stay.
export function UseLevelAboveButton({ scope, project, kind, onDropped }) {
  const [note, setNote] = useState(null);
  const [busy, setBusy] = useState(false);
  const [dialog, ask] = useConfirm();
  const next = scope === 'project' ? 'the fleet override if one exists, else the repo file' : 'the repo file';
  const where = scope === 'project' ? `project ${project}` : 'the fleet';

  const onClick = async () => {
    const ok = await ask({
      title: 'USE LEVEL ABOVE',
      confirmLabel: 'DROP OVERRIDE',
      tone: 'warn',
      body: html`<p>Stop using the <b>${kind}</b> override of ${where}. In its place: ${next}.
        The saved versions stay, and VERSIONS can restore one.</p>`
    });
    if (!ok) return;
    setBusy(true);
    setNote(null);
    try {
      const res = await dropHead({ scope, project, kind });
      setNote({ ok: true, text: res.dropped ? 'Override dropped. The level above is in use.' : 'No override at this level.' });
      if (onDropped) onDropped();
    } catch (e) {
      unauthorized(e);
      setNote({ ok: false, text: `The drop failed: ${e.message || String(e)}` });
    } finally {
      setBusy(false);
    }
  };

  return html`
    <button type="button" class="btn" disabled=${busy} onClick=${onClick}>USE LEVEL ABOVE</button>
    ${note ? html`<span role=${note.ok ? 'status' : 'alert'}
      class=${note.ok ? 'prompt-editor__meta' : 'prompt-lint__bad'}>${note.text}</span>` : null}
    ${dialog}`;
}

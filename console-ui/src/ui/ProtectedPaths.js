import { useState, useRef } from 'preact/hooks';
import { html } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from './Modal.js';
import { SortableTable } from './SortableTable.js';
import { Skeleton, Empty, ErrorBox, ProjectLink } from './primitives.js';

// BH-4147 (BH-4140.2) — the PROTECTED PATHS panel on /settings: the lead's
// protected-path globs per repo (GET/PUT /api/lead-protected-paths through the
// coord proxy, which stamps added_by), and the lead_authority_mode hint. The
// pure pieces are exported so tests/protected-paths.bh-4140.test.js drives
// them without a browser; PRVerdicts.js is the pattern.

// The repo field's starting value, a convenience only: the one repo in
// catalog/lead-protected-paths.seed.tsv, the seed of the rows. The field is editable.
export const DEFAULT_REPO = 'example-org/cromford';

const MODE_KEY = 'lead_authority_mode';
const repoName = (repo) => String(repo || '').split('/').pop();

export function protectedPathColumns({ busy, onRemove }) {
  return [
    { key: 'repo', label: 'REPO', sort: (r) => r.repo,
      cell: (r) => html`<${ProjectLink} project=${repoName(r.repo)}/>` },
    { key: 'glob', label: 'GLOB', sort: (r) => r.glob,
      cell: (r) => html`<span class="mono">${r.glob}</span>` },
    { key: 'added_by', label: 'ADDED BY', sort: (r) => r.added_by,
      cell: (r) => (r.added_by ? html`<span>${r.added_by}</span>` : html`<span class="na">—</span>`) },
    { key: 'added_at', label: 'ADDED AT', sort: (r) => r.added_at,
      cell: (r) => html`<span class="num">${r.added_at}</span>` },
    { key: 'remove', label: 'REMOVE', sort: null,
      cell: (r) => html`<button type="button" class="btn btn--sm btn--danger" disabled=${busy}
        onClick=${() => onRemove(r)}>REMOVE</button>` }
  ];
}

// state: useApi's { loading, error, data, reload }.
export function ProtectedPathsView({ repo, state, busy, onRemove }) {
  if (state.loading && !state.data) return html`<${Skeleton} rows=${3}/>`;
  const rows = state.data && Array.isArray(state.data.rows) ? state.data.rows : null;
  if (!rows) {
    const error = state.error || new Error('the answer carried no rows');
    return html`<${ErrorBox} error=${new Error(`protected paths for ${repo}: ${error.message || error}`)} onRetry=${state.reload}/>`;
  }
  if (!rows.length) {
    return html`<${Empty} title="NO PROTECTED PATHS"
      note=${`${repo} has no live protected-path rows. Add a glob above.`} />`;
  }
  return html`
    <div style="overflow-x:auto;max-width:100%">
      <${SortableTable}
        columns=${protectedPathColumns({ busy, onRemove })}
        rows=${rows}
        rowKey=${(r) => `${r.repo} ${r.glob}`}
        defaultSort="glob" />
    </div>`;
}

const failText = (e) => (e && e.message) || String(e);

// One add. Returns {ok, text}; a blank field is refused before any call, and
// only created:true is "added" (D9).
export async function addProtectedPath({ write, repo, glob }) {
  const r = typeof repo === 'string' ? repo.trim() : '';
  if (!r || typeof glob !== 'string' || !glob.trim()) return { ok: false, text: 'repo and glob are both required' };
  try {
    const res = await write({ repo: r, glob, op: 'add' });
    if (res && res.created === true) return { ok: true, text: `added ${glob} to ${r}` };
    if (res && res.created === false) return { ok: true, text: `${glob} is already protected on ${r}` };
    return { ok: false, text: `unexpected answer adding ${glob}` };
  } catch (e) {
    return { ok: false, text: failText(e) };
  }
}

// One remove, through the in-app modal. {sent:false} on cancel, otherwise
// {sent:true, ok, text}. A 404 means the row is no longer live.
export async function removeProtectedPath({ confirm, write, row }) {
  const ok = await confirm({
    title: 'REMOVE PROTECTED PATH',
    body: html`Stop protecting <b>${row.glob}</b> on <b>${row.repo}</b>? The row is kept with removed_at set.`,
    tone: 'danger',
    confirmLabel: 'REMOVE'
  });
  if (!ok) return { sent: false };
  try {
    const res = await write({ repo: row.repo, glob: row.glob, op: 'remove' });
    if (res && res.removed === true) return { sent: true, ok: true, text: `removed ${row.glob} from ${row.repo}` };
    return { sent: true, ok: false, text: `unexpected answer removing ${row.glob}` };
  } catch (e) {
    if (e && e.status === 404) return { sent: true, ok: true, text: `${row.glob} was already removed` };
    return { sent: true, ok: false, text: failText(e) };
  }
}

// The lead_authority_mode row as the hint shows it. bin/lib/lead-authority.sh
// trims and lowercases once and reads no row as lane; anything else is a value
// the lead lane treats as unreadable, so it is never shown as lane (D11).
export function modeOf(state) {
  if (state.error || !state.data || !('setting' in state.data)) {
    return state.loading && !state.error ? { kind: 'loading' } : { kind: 'error' };
  }
  const s = state.data.setting;
  if (s === null) return { kind: 'ok', value: null, label: 'no row, so lane', next: 'human' };
  const value = String(s.value == null ? '' : s.value).trim().toLowerCase();
  if (value === 'lane') return { kind: 'ok', value, label: 'lane', next: 'human' };
  if (value === 'human') return { kind: 'ok', value, label: 'human', next: 'lane' };
  return { kind: 'unknown', value: s.value, label: `${s.value} (not lane or human: the lead lane cannot read it)`, next: 'lane' };
}

export function LeadAuthorityHint({ state, busy, onSet }) {
  const m = modeOf(state);
  const head = m.kind === 'loading'
    ? html`${MODE_KEY}: reading…`
    : m.kind === 'error'
      ? html`could not read ${MODE_KEY}${state.error ? ` (${failText(state.error)})` : ''}`
      : html`${MODE_KEY}: <b>${m.label}</b>.`;
  return html`
    <div class="section__note" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px">
      <span style="min-width:0">${head} lane = the lead review signs protected paths; human = a person must.
        A per-repo ${MODE_KEY}.&lt;owner&gt;.&lt;name&gt; row overrides it.</span>
      ${m.next ? html`<button type="button" class="btn btn--sm" disabled=${busy}
        onClick=${() => onSet(m.next)}>SET ${m.next}</button>` : null}
    </div>`;
}

// Set the global lead_authority_mode row. Only a row that comes back with the
// value sent is a success.
export async function flipLeadAuthority({ confirm, write, to }) {
  const ok = await confirm({
    title: 'SET LEAD AUTHORITY MODE',
    body: html`Set <b>${MODE_KEY}</b> to <b>${to}</b>? ${to === 'human'
      ? 'A person must sign PRs that touch protected paths.'
      : 'The lead review signs PRs that touch protected paths.'}`,
    tone: 'warn',
    confirmLabel: `SET ${to}`
  });
  if (!ok) return { sent: false };
  try {
    const res = await write({ key: MODE_KEY, value: to, note: 'BH-4147 console' });
    if (res && res.setting && res.setting.value === to) return { sent: true, ok: true, text: `${MODE_KEY} set to ${to}` };
    return { sent: true, ok: false, text: `unexpected answer setting ${MODE_KEY}` };
  } catch (e) {
    return { sent: true, ok: false, text: failText(e) };
  }
}

export function ProtectedPathsPanel() {
  const [repoDraft, setRepoDraft] = useState(DEFAULT_REPO);
  const [repo, setRepo] = useState(DEFAULT_REPO);
  const [glob, setGlob] = useState('');
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState(null);
  const inFlight = useRef(false);
  const [dialog, confirm] = useConfirm();
  const paths = useApi(() => api.protectedPaths(repo), [repo]);
  const mode = useApi(() => api.coordSetting(MODE_KEY), []);

  // One write at a time: a second click while one is in flight is ignored.
  const guard = async (fn) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    try { await fn(); } finally { inFlight.current = false; setBusy(false); }
  };
  const show = (r, reload) => {
    if (r.sent === false) return;
    setNote({ ok: r.ok, text: r.text });
    if (r.ok) reload();
  };
  const load = () => setRepo(repoDraft.trim());
  // An add to a repo other than the one on screen switches the table to it.
  const onAdd = () => guard(async () => {
    const target = repoDraft.trim();
    const r = await addProtectedPath({ write: api.setProtectedPath, repo: target, glob });
    if (r.ok) setGlob('');
    show(r, target !== repo ? () => setRepo(target) : paths.reload);
  });
  const onRemove = (row) => guard(async () => show(await removeProtectedPath({ confirm, write: api.setProtectedPath, row }), paths.reload));
  const onSet = (to) => guard(async () => show(await flipLeadAuthority({ confirm, write: api.setCoordSetting, to }), mode.reload));
  const enter = (fn) => (e) => { if (e.key === 'Enter') { e.preventDefault(); fn(); } };

  return html`
    <div>
      ${dialog}
      <${LeadAuthorityHint} state=${mode} busy=${busy} onSet=${onSet}/>
      <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px">
        <input class="knob__input" type="text" aria-label="repo" placeholder="owner/name" value=${repoDraft} style="min-width:0;flex:1 1 180px"
          onInput=${(e) => setRepoDraft(e.target.value)} onBlur=${load} onKeyDown=${enter(load)}/>
        <input class="knob__input" type="text" aria-label="glob" placeholder="glob, e.g. tmp/**" value=${glob} style="min-width:0;flex:1 1 180px"
          onInput=${(e) => setGlob(e.target.value)} onKeyDown=${enter(onAdd)}/>
        <button type="button" class="btn btn--sm btn--primary" disabled=${busy} onClick=${onAdd}>ADD</button>
      </div>
      ${note ? html`<div class=${note.ok ? 'section__note' : 'banner'} style="margin-bottom:8px">
        <span>${note.text}</span></div>` : null}
      <${ProtectedPathsView} repo=${repo} state=${paths} busy=${busy} onRemove=${onRemove}/>
    </div>`;
}

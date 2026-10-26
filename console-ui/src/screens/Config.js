// BH-2375 (BH-2330.0) + BH-2378 (BH-2330.3): /config, every settings row and
// every flag, with an audited EDIT and TURN ON/OFF, and the newest changes of
// any kind from config_changes, the one audit store. The screen owns the reads
// and the writes; ConfigView is a pure function of props so the tests render
// it server-side.
import { useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { agoFromMinutes, minutesSince } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import {
  changesStatus, configHref, CONFIG_CHANGES_LIMIT, RECENT_CHANGES_LIMIT,
  settingRows, flagRows, recentChangeRows, validateValue, validateReason, settingPutBody
} from '../lib/config.js';

// What each config_changes kind is, in words. One entry per kind in
// worker/jobs/src/lib/config-changes.js CONFIG_KINDS; an unknown kind has no
// entry and so no line.
export const CONFIG_KIND_MEANING = Object.freeze({
  setting: 'a fleet setting row the worker and boxes read',
  flag: 'an on/off switch; boxes turn it into a file on their next tick',
  cost_cap: 'a spending limit',
  concurrency_rule: 'how many builds may run at once',
  retry_policy: 'how often a dead job is retried',
  phase_contract: 'what a build phase must hand over',
  review_gate_threshold: 'the bar a review verdict must clear',
  telegram_topic: 'where a chat notice is posted',
  registry_seed: 'the starting list of projects and lanes',
  merge_queue: 'merge queue order and holds',
  held_page: 'a page that is held back from sending',
  project: 'a watched project and where its board lives',
  project_secret: 'a project build secret name in the Fly secret store (never a value)'
});

// One read per (kind, name, limit). An answer that lands after the filter
// changed is dropped, so a route change never paints the previous record's
// answer (D23). `reload` re-reads the same filter and keeps what is shown
// until the answer lands.
export function useConfigChanges(kind, name, limit = CONFIG_CHANGES_LIMIT) {
  const [state, setState] = useState({ loading: true, error: null, data: null });
  const [nonce, setNonce] = useState(0);
  const lastKey = useRef(null);
  useEffect(() => {
    let live = true;
    const key = JSON.stringify([kind, name, limit]);
    const same = lastKey.current === key;
    lastKey.current = key;
    setState(same ? (s) => ({ ...s, loading: true }) : { loading: true, error: null, data: null });
    api.configChanges({ kind, name, limit }).then(
      (data) => { if (live) setState({ loading: false, error: null, data }); },
      (error) => {
        if (!live) return;
        if (error instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
        setState({ loading: false, error, data: null });
      }
    );
    return () => { live = false; };
  }, [kind, name, limit, nonce]);
  return { ...state, reload: () => setNonce((n) => n + 1) };
}

const loadSettings = () => api.settings();
const loadFlags = () => api.coordFlags();
const errText = (e) => (e && e.message ? e.message : String(e));

export function ConfigScreen() {
  const settings = useApi(loadSettings, [], { intervalMs: 60000 });
  const flags = useApi(loadFlags, [], { intervalMs: 60000 });
  const changes = useConfigChanges(null, null, RECENT_CHANGES_LIMIT);
  const [filter, setFilter] = useState('');
  const [showLane, setShowLane] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [note, setNote] = useState(null);
  const [dialog, ask] = useConfirm();

  // One latch for every write on the page; it clears in finally.
  const write = async (put, success) => {
    busyRef.current = true;
    setBusy(true);
    try {
      await put();
      setNote({ ok: true, text: success });
      settings.reload();
      flags.reload();
      changes.reload();
    } catch (e) {
      setNote({ ok: false, text: `refused: ${errText(e)}` });
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };

  const onEdit = async (row) => {
    if (busyRef.current || !row.editableHere) return;
    const form = { value: row.value == null ? '' : String(row.value), reason: '' };
    const ok = await ask({
      title: `EDIT ${row.key}`, confirmLabel: 'SAVE', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${ChangeForm} row=${row} form=${form} withValue onBlocked=${setBlocked}/>`
    });
    if (!ok || busyRef.current) return;
    const v = validateValue(form.value);
    const r = validateReason(form.reason);
    if (!v.ok || !r.ok) { setNote({ ok: false, text: `refused: ${(v.ok ? r : v).message}` }); return; }
    await write(() => api.setCoordSetting(settingPutBody(row.key, v.value, r.value)), `${row.key} set to ${v.value}`);
  };

  const onToggle = async (row) => {
    if (busyRef.current) return;
    const form = { reason: '' };
    const ok = await ask({
      title: `TURN ${row.on ? 'OFF' : 'ON'} ${row.name}`, confirmLabel: row.on ? 'TURN OFF' : 'TURN ON',
      tone: 'warn', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${ChangeForm} row=${row} form=${form} onBlocked=${setBlocked}/>`
    });
    if (!ok || busyRef.current) return;
    const r = validateReason(form.reason);
    if (!r.ok) { setNote({ ok: false, text: `refused: ${r.message}` }); return; }
    await write(() => api.setCoordFlag(row.name, !row.on, r.value), `${row.name} turned ${row.on ? 'off' : 'on'}`);
  };

  return html`
    <${ConfigView} settings=${settings} flags=${flags} changes=${changes}
      filter=${filter} showLane=${showLane} onFilter=${setFilter} onShowLane=${setShowLane}
      onEdit=${onEdit} onToggle=${onToggle} busy=${busy} note=${note}/>
    ${dialog}`;
}

// The modal body. Its values live in `form` (the caller's object, read on
// confirm) and in this component's own state, never in the page's, so a 60s
// poll re-rendering the page never resets what is being typed. The first
// field takes focus once per open (Modal.js, D39).
export function ChangeForm({ row, form, withValue = false, onBlocked }) {
  const [value, setValue] = useState(form.value);
  const [reason, setReason] = useState(form.reason);
  const [touched, setTouched] = useState({});
  const v = withValue ? validateValue(value) : { ok: true };
  const r = validateReason(reason);
  const set = (field, x) => {
    form[field] = x;
    if (field === 'value') setValue(x); else setReason(x);
    setTouched((t) => ({ ...t, [field]: true }));
    const okV = withValue ? validateValue(form.value).ok : true;
    onBlocked(!(okV && validateReason(form.reason).ok));
  };
  const input = (field, cur, check, placeholder) => html`
    <label class="knob" style="width:100%">
      <span class="knob__label">${field.toUpperCase()}</span>
      <input class=${touched[field] && !check.ok ? 'knob__input knob__input--bad' : 'knob__input'} style="width:100%"
        type="text" aria-label=${field} value=${cur} placeholder=${placeholder}
        onInput=${(e) => set(field, e.target.value)}/>
      ${touched[field] && !check.ok ? html`<span style="color:var(--red)">${check.message}</span>` : null}
    </label>`;
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="color:var(--faint);overflow-wrap:anywhere">
        last written by ${row.actor || 'unknown'} ${agoFromMinutes(minutesSince(row.updated_at))}
      </span>
      ${withValue ? input('value', value, v, 'one line, 256 characters or fewer') : null}
      ${input('reason', reason, r, 'why this changes (required)')}
    </div>`;
}

const dash = (v) => (v === null || v === undefined || v === '' ? '—' : v);
const wrap = (v) => html`<span style="overflow-wrap:anywhere">${dash(v)}</span>`;
const age = (iso) => html`<span title=${iso || ''}><${Age} min=${minutesSince(iso)} warnAt=${Infinity}/></span>`;

function settingColumns({ onEdit, busy }) {
  return [
    { key: 'key', label: 'KEY', cell: (r) => html`<${Link} to=${configHref('setting', r.key)} class="cell-name">${r.key}<//>` },
    { key: 'value', label: 'VALUE', cell: (r) => wrap(r.value) },
    { key: 'actor', label: 'LAST WRITER', cell: (r) => dash(r.actor) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => age(r.updated_at) },
    { key: 'note', label: 'NOTE', cell: (r) => wrap(r.note) },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => (r.editableHere
        ? html`<button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onEdit(r)}>EDIT</button>`
        : html`<${Link} to=${r.href}>edit on lane page<//>`)
    }
  ];
}

function flagColumns({ onToggle, busy }) {
  return [
    { key: 'name', label: 'NAME', cell: (r) => html`<${Link} to=${configHref('flag', r.name)} class="cell-name">${r.name}<//>` },
    { key: 'on', label: 'STATE', sort: (r) => (r.on ? 1 : 0), cell: (r) => (r.on ? 'ON' : 'OFF') },
    // BH-5643: the flag file's content, e.g. a wip-limit-<p> number.
    { key: 'value', label: 'VALUE', cell: (r) => dash(r.value) },
    { key: 'actor', label: 'ACTOR', cell: (r) => dash(r.actor) },
    { key: 'reason', label: 'REASON', cell: (r) => wrap(r.reason) },
    { key: 'updated_at', label: 'UPDATED', cell: (r) => age(r.updated_at) },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => html`<button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onToggle(r)}>${r.on ? 'TURN OFF' : 'TURN ON'}</button>`
    }
  ];
}

const CHANGE_COLUMNS = [
  { key: 'at', label: 'AT', cell: (r) => age(r.at) },
  { key: 'kind', label: 'KIND', cell: (r) => html`<span title=${r.kind}>${plainLabel(r.kind)}</span>` },
  { key: 'name', label: 'NAME', cell: (r) => html`<${Link} to=${r.href} class="cell-name">${r.name}<//>` },
  { key: 'actor', label: 'WHO', cell: (r) => dash(r.actor) },
  { key: 'reason', label: 'WHY', cell: (r) => wrap(r.reason) }
];

const FIELD_LEGEND = [
  { term: 'VALUE', text: "the setting's current value; on a flag, the flag file's content (a wip-limit number)" },
  { term: 'LAST WRITER', text: 'who changed it last (ACTOR on a flag)' },
  { term: 'UPDATED', text: 'how long ago it last changed' },
  { term: 'NOTE', text: 'what the setting is for, as written when it was created' },
  { term: 'STATE', text: 'ON means the switch is set; OFF means it is clear' }
];

// The kinds present in the rows, each once, in the order they first appear.
const kindLegend = (rows) => [...new Set(rows.map((r) => r.kind))]
  .filter((k) => CONFIG_KIND_MEANING[k])
  .map((k) => ({ term: plainLabel(k), text: CONFIG_KIND_MEANING[k] }));

// A read's table: skeleton on the first load, ErrorBox for a failed read with
// nothing to show, ErrorBox above the kept rows for a failed poll, Empty for a
// read that answered zero rows.
function readTable(read, rows, what, table) {
  const data = read && read.data;
  if (read && read.loading && !data) return html`<${Skeleton} rows=${3} height=${20}/>`;
  if (rows === null) {
    return html`<${ErrorBox} error=${(read && read.error) || new Error(`the ${what} read returned no list`)} onRetry=${read && read.reload}/>`;
  }
  return html`
    ${read && read.error ? html`<${ErrorBox} error=${read.error} onRetry=${read.reload}/>` : null}
    ${table}`;
}

export function ConfigView({ settings, flags, changes, filter = '', showLane = false, onFilter, onShowLane, onEdit, onToggle, busy = false, note = null }) {
  const sRows = settingRows(settings && settings.data && settings.data.settings, filter, showLane);
  const fRows = flagRows(flags && flags.data && flags.data.flags, filter);
  const recent = recentChangeRows(changes && changes.data);
  const f = String(filter || '').trim();
  const noMatch = (none) => html`<${Empty} title=${f ? `no key matches '${f}'` : none}/>`;

  return html`
    <div class="page">
      <${PageHeadline} chip="ALL SETTINGS & FLAGS" line1="Every setting and every flag."
        line2=${Array.isArray(recent) ? `${recent.length} recent ${recent.length === 1 ? 'change' : 'changes'}, each with its reason.` : 'Each change is recorded with its reason.'}/>
      ${note ? html`<div class=${note.ok ? 'banner banner--warn' : 'banner'} role="status"
        style=${note.ok ? 'margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : 'margin-bottom:10px'}>
        <span style="overflow-wrap:anywhere">${note.text}</span></div>` : null}

      <${Section} title="SETTINGS" note="every settings row; lane knobs are edited on their lane page">
        <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-bottom:8px">
          <input class="knob__input" style="width:min(100%,28ch)" type="text" aria-label="filter by key"
            placeholder="filter by key" value=${filter} onInput=${(e) => onFilter && onFilter(e.target.value)}/>
          <label style="display:inline-flex;align-items:center;gap:6px;min-height:44px">
            <input type="checkbox" checked=${showLane} onChange=${(e) => onShowLane && onShowLane(e.target.checked)}/>
            show lane knobs
          </label>
        </div>
        ${readTable(settings, sRows, 'settings', html`<${SortableTable} wide columns=${settingColumns({ onEdit, busy })}
          rows=${sRows || []} rowKey=${(r) => r.key} defaultSort="key"
          empty=${noMatch(showLane ? 'no settings rows' : 'no settings rows outside the lane knobs')}/>`)}
      <//>

      <${Section} title="FLAGS" note=${html`pause_flags; the filter applies here too · <${Link} to="/flags">ALL FLAGS →<//>`}>
        ${readTable(flags, fRows, 'flags', html`<${SortableTable} wide columns=${flagColumns({ onToggle, busy })}
          rows=${fRows || []} rowKey=${(r) => r.name} defaultSort="name" empty=${noMatch('no flags')}/>`)}
        <${Legend} items=${FIELD_LEGEND}/>
      <//>

      <${Section} title=${`RECENT CHANGES — newest ${RECENT_CHANGES_LIMIT}`} note="config_changes, every kind">
        <p>${changesStatus(changes || { loading: true })}</p>
        ${recent && recent.truncated ? html`<p style="color:var(--faint)">showing the newest ${RECENT_CHANGES_LIMIT}; open a row for its full history</p>` : null}
        ${recent && recent.rows.length ? html`<${SortableTable} wide columns=${CHANGE_COLUMNS} rows=${recent.rows}
          rowKey=${(r) => r.id} defaultSort="at" defaultDir="desc"/>
          <${Legend} items=${kindLegend(recent.rows)}/>` : null}
      <//>
    </div>`;
}

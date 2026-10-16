// BH-4153 (BH-4141.1): /flags, every flag row from both stores with its scope,
// a SET FLAG… and a CLEAR on each ON row, each through an in-app modal with a
// required reason. The modal closes only on a 2xx; a refusal shows inside it
// and keeps what was typed. FlagsScreen owns the reads and writes; FlagsView
// is a pure function of props so the tests render it server-side.
import { useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useFleet } from '../app.js';
import { useApi } from '../lib/hooks.js';
import { Modal } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { minutesSince } from '../lib/format.js';
import { fleetProjects } from '../lib/kanban.js';
import { configHref } from '../lib/config.js';
import {
  flagRowsAll, flagProject, isBoxScope, setBody, clearQuery, setFormState, clearFormState, FLEET_SCOPE
} from '../lib/flags.js';
import { boxSwitchRows } from '../lib/box-switches.js';

const loadFlags = () => api.coordFlagsAll();
const loadSettings = () => api.settings();
const errText = (e) => (e && e.message ? e.message : String(e));

export function FlagsScreen() {
  const flags = useApi(loadFlags, [], { intervalMs: 60000 });
  // Started in the same mount as the flags read, so the two run in parallel.
  const switches = useApi(loadSettings, [], { intervalMs: 60000 });
  const fleet = useFleet();
  const projects = fleetProjects(fleet && fleet.data && fleet.data.projects);
  const [filter, setFilter] = useState('');
  const [showCleared, setShowCleared] = useState(false);
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const [note, setNote] = useState(null);
  const nonce = useRef(0);
  // The confirm is guarded here as well as by `pending`: a second click can
  // land before the render that shows SAVING….
  const inFlight = useRef(false);

  const open = (kind, row = null) => {
    nonce.current += 1;
    setServerError(null);
    setEdit({ kind, row, nonce: nonce.current, draft: kind === 'set' ? { name: '', scope: FLEET_SCOPE, value: '', reason: '' } : { reason: '' } });
  };

  const onConfirm = async () => {
    if (inFlight.current || !edit) return;
    const { kind, row, draft } = edit;
    const st = kind === 'set' ? setFormState(draft) : clearFormState(draft);
    if (st.blocked) { setServerError(st.hint); return; }
    inFlight.current = true;
    setPending(true);
    setServerError(null);
    try {
      if (kind === 'set') {
        const body = setBody(draft);
        await api.setCoordFlagRow(body);
        setNote(`${body.name} set on ${body.scope}`);
      } else {
        await api.clearCoordFlag(clearQuery({ name: row.name, scope: row.scope, reason: draft.reason }));
        setNote(`${row.name} cleared on ${row.scope}`);
      }
      setEdit(null);
      flags.reload();
    } catch (e) {
      setServerError(`refused: ${errText(e)}`);
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  };

  const dialog = edit ? html`
    <${Modal} key=${edit.nonce}
      title=${edit.kind === 'set' ? 'SET FLAG' : `CLEAR ${edit.row.name}`}
      confirmLabel=${pending ? 'SAVING…' : edit.kind === 'set' ? 'SET' : 'CLEAR'}
      tone=${edit.kind === 'set' ? undefined : 'warn'}
      confirmBlocked=${true}
      body=${({ setBlocked }) => (edit.kind === 'set'
        ? html`<${SetForm} draft=${edit.draft} serverError=${serverError} onBlocked=${setBlocked}/>`
        : html`<${ClearForm} row=${edit.row} draft=${edit.draft} serverError=${serverError} onBlocked=${setBlocked}/>`)}
      onConfirm=${onConfirm}
      onCancel=${() => { if (!inFlight.current) setEdit(null); }}/>` : null;

  return html`<${FlagsView} flags=${flags} switches=${switches} projects=${projects} filter=${filter} showCleared=${showCleared}
    onFilter=${setFilter} onShowCleared=${setShowCleared} onSet=${() => open('set')} onClear=${(r) => open('clear', r)}
    busy=${pending} note=${note} dialog=${dialog}/>`;
}

// One labelled text input. Its value lives in the form's own state and is
// written through to `draft`, so a poll re-rendering the page never resets
// what is being typed (D39).
const field = (name, cur, onInput, placeholder) => html`
  <label class="knob" style="width:100%">
    <span class="knob__label">${name.toUpperCase()}</span>
    <input class="knob__input" style="width:100%" type="text" aria-label=${name} value=${cur}
      placeholder=${placeholder} onInput=${(e) => onInput(e.target.value)}/>
  </label>`;

const hintLine = (hint, serverError) => html`
  ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
  ${serverError ? html`<span role="alert" style="color:var(--red);overflow-wrap:anywhere">${serverError}</span>` : null}`;

export function SetForm({ draft, serverError, onBlocked }) {
  const [f, setF] = useState({ ...draft });
  const set = (k) => (v) => {
    draft[k] = v;
    setF({ ...draft });
    onBlocked(setFormState(draft).blocked);
  };
  const { hint } = setFormState(f);
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      ${field('name', f.name, set('name'), 'for example paused-project-3')}
      ${field('scope', f.scope, set('scope'), 'fleet, or a box name')}
      ${field('value', f.value, set('value'), 'optional')}
      ${field('reason', f.reason, set('reason'), 'why this is set (required)')}
      ${hintLine(hint, serverError)}
    </div>`;
}

export function ClearForm({ row, draft, serverError, onBlocked }) {
  const [reason, setReason] = useState(draft.reason);
  const onInput = (v) => {
    draft.reason = v;
    setReason(v);
    onBlocked(clearFormState(draft).blocked);
  };
  const { hint } = clearFormState({ reason });
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="color:var(--faint);overflow-wrap:anywhere">
        scope ${row.scope}, set by ${row.set_by || 'unknown'}. The row stays, marked cleared.
      </span>
      ${field('reason', reason, onInput, 'why this is cleared (required)')}
      ${hintLine(hint, serverError)}
    </div>`;
}

const none = html`<span class="na">—</span>`;
const dash = (v) => (v === null || v === undefined || v === '' ? none : v);
const wrap = (v) => html`<span style="overflow-wrap:anywhere">${dash(v)}</span>`;
const age = (iso) => (iso
  ? html`<span title=${iso}><${Age} min=${minutesSince(iso)} warnAt=${Infinity}/></span>`
  : none);

export function flagColumns({ projects, onClear, busy }) {
  return [
    {
      key: 'scope', label: 'SCOPE',
      cell: (r) => (isBoxScope(r.scope) ? html`<${Link} to="/machines">${r.scope}<//>` : r.scope)
    },
    { key: 'name', label: 'NAME', cell: (r) => html`<${Link} to=${configHref('flag', r.name)} class="cell-name">${r.name}<//>` },
    {
      key: 'project', label: 'PROJECT', sort: (r) => flagProject(r.name, projects),
      cell: (r) => {
        const p = flagProject(r.name, projects);
        return p ? html`<${Link} to=${`/p/${encodeURIComponent(p)}`}>${p}<//>` : none;
      }
    },
    { key: 'value', label: 'VALUE', cell: (r) => wrap(r.value) },
    { key: 'state', label: 'STATE', sort: (r) => (r.on ? 1 : 0), cell: (r) => (r.on ? 'ON' : 'cleared') },
    { key: 'set_by', label: 'SET BY', cell: (r) => dash(r.set_by) },
    { key: 'set_at', label: 'SET AT', cell: (r) => age(r.set_at) },
    { key: 'cleared_at', label: 'CLEARED AT', cell: (r) => age(r.cleared_at) },
    { key: 'reason', label: 'REASON', flex: true, cell: (r) => wrap(r.reason) },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => (r.on
        ? html`<button type="button" class="btn btn--sm" disabled=${busy} onClick=${() => onClear(r)}>CLEAR</button>`
        : null)
    }
  ];
}

export function boxSwitchColumns() {
  return [
    { key: 'box', label: 'BOX', cell: (r) => html`<${Link} to="/machines">${r.box}<//>` },
    { key: 'name', label: 'SWITCH', cell: (r) => html`<${Link} to=${configHref('setting', r.key)} class="cell-name">${r.name}<//>` },
    { key: 'value', label: 'VALUE', cell: (r) => wrap(r.value) },
    { key: 'set_by', label: 'SET BY', cell: (r) => dash(r.set_by) },
    { key: 'set_at', label: 'SET AT', cell: (r) => age(r.set_at) }
  ];
}

// The BOX SWITCHES body. `switches` is the settings read; null means the page
// was rendered without it, so there is no section.
function boxSwitchBody(switches, filter) {
  const data = switches.data;
  const rows = boxSwitchRows(data);
  const f = String(filter || '').trim().toLowerCase();
  if (switches.loading && !data) return html`<${Skeleton} rows=${2} height=${20}/>`;
  if (rows === null) {
    return html`<${ErrorBox} error=${switches.error || new Error('the settings read returned no list')} onRetry=${switches.reload}/>`;
  }
  const shown = f ? rows.filter((r) => [r.name, r.box, r.set_by].some((v) => String(v ?? '').toLowerCase().includes(f))) : rows;
  return html`
    ${switches.error ? html`<${ErrorBox} error=${switches.error} onRetry=${switches.reload}/>` : null}
    <${SortableTable} wide columns=${boxSwitchColumns()} rows=${shown} rowKey=${(r) => r.key} defaultSort="box"
      empty=${html`<${Empty} title=${f ? `no box switch matches '${String(filter).trim()}'` : 'no box switch is on'}/>`}/>`;
}

const LEGEND = [
  { term: 'SCOPE', text: 'fleet applies everywhere; a box name applies on that box only' },
  { term: 'STATE', text: 'ON means the flag is set; cleared means it was turned off and kept for history' },
  { term: 'VALUE', text: 'an optional value stored with the flag' },
  { term: 'PROJECT', text: 'the project a paused or automerge flag is about' }
];

export function FlagsView({ flags, switches = null, projects = [], filter = '', showCleared = false, onFilter, onShowCleared, onSet, onClear, busy = false, note = null, dialog = null }) {
  const data = flags && flags.data;
  const res = flagRowsAll(data, { filter, showCleared });
  const f = String(filter || '').trim();

  let body;
  if (flags && flags.loading && !data) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(flags && flags.error) || new Error('the flags read returned no list')} onRetry=${flags && flags.reload}/>`;
  } else {
    body = html`
      ${flags && flags.error ? html`<${ErrorBox} error=${flags.error} onRetry=${flags.reload}/>` : null}
      ${res.truncated ? html`<p style="color:var(--faint)">the list is truncated: the worker capped it, so filter to see the rest</p>` : null}
      <${SortableTable} wide columns=${flagColumns({ projects, onClear, busy })} rows=${res.rows}
        rowKey=${(r) => `${r.scope}|${r.name}`} defaultSort="name"
        empty=${html`<${Empty} title=${f ? `no flag matches '${f}'` : 'no flags'}
          note=${res.hidden ? `${res.hidden} cleared, turn on show cleared to see them` : null}/>`}/>
      ${!showCleared && res.hidden && res.rows.length ? html`<p style="color:var(--faint)">${res.hidden} cleared not shown</p>` : null}`;
  }

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Flags"
        line1=${res ? `${res.rows.length} ${res.rows.length === 1 ? 'flag' : 'flags'} set.` : flags && flags.loading ? 'Reading the flags.' : 'The flags read failed.'}
        line2=${res && res.hidden ? `${res.hidden} cleared, not shown.` : 'Each flag is a switch the fleet reads.'}/>
      ${note ? html`<div class="banner banner--warn" role="status"
        style="margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)">
        <span style="overflow-wrap:anywhere">${note}</span></div>` : null}
      <${Section} title="ALL FLAGS" note=${html`every flag, fleet and per box; the switches page is <${Link} to="/config">/config<//>`}>
        <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-bottom:8px">
          <input class="knob__input" style="width:min(100%,28ch)" type="text" aria-label="filter flags"
            placeholder="filter by name, scope or reason" value=${filter} onInput=${(e) => onFilter && onFilter(e.target.value)}/>
          <label style="display:inline-flex;align-items:center;gap:6px;min-height:44px">
            <input type="checkbox" checked=${showCleared} onChange=${(e) => onShowCleared && onShowCleared(e.target.checked)}/>
            SHOW CLEARED
          </label>
          <button type="button" class="btn btn--sm btn--primary" style="margin-left:auto" disabled=${busy}
            onClick=${() => onSet && onSet()}>SET FLAG…</button>
        </div>
        ${body}
        <${Legend} items=${LEGEND}/>
      <//>
      ${switches ? html`
        <${Section} title="BOX SWITCHES" note="the switch.<name>.<box> settings rows that are on; a box reads its own row first">
          ${boxSwitchBody(switches, filter)}
        <//>` : null}
    </div>`;
}

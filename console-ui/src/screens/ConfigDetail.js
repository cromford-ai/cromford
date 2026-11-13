// BH-2379 (BH-2330.4): /config/:kind/:name, one config row's page. `kind` and
// `name` arrive already decoded by router.js matchRoute. CURRENT is the live
// row where the page has a reader for the kind (a settings row, a pause flag);
// HISTORY is every config_changes row for (kind, name), newest first.
import { useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { usePolledApi } from '../lib/poll.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { clockTime, minutesSince, fmtNum } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { CONFIG_KIND_MEANING } from './Config.js';
import { isKnownKind, historyRows, sideText, currentFor, DETAIL_LIMIT, FLAG_LIST_CAP } from '../lib/config-detail.js';

export const POLL_MS = 30000;
const hasReader = (kind) => kind === 'setting' || kind === 'flag';

// Each answer carries the (kind, name) it was asked for, so the view never
// shows one record's answer under another.
export const loadHistory = (kind, name) =>
  api.configChanges({ kind, name, limit: DETAIL_LIMIT }).then((res) => ({ kind, name, res }));
export const loadCurrent = (kind, name) =>
  (kind === 'setting' ? api.coordSetting(name) : api.coordFlags()).then((res) => ({ kind, name, res }));

const na = html`<span class="na">—</span>`;
const orNa = (v) => (v === null || v === undefined || v === '' ? na : String(v));

export function ConfigDetailScreen({ kind, name }) {
  const known = isKnownKind(kind);
  // usePolledApi keeps one alive flag across (kind, name) changes, so a read
  // started for the previous record would still land. It never settles
  // instead: no state write, and no poll re-armed for the old record (D23).
  const at = useRef(null);
  at.current = `${kind}\u0000${name}`;
  const onlyIfCurrent = (p) => {
    const asked = at.current;
    const hold = () => new Promise(() => {});
    return p.then((v) => (at.current === asked ? v : hold()), (e) => (at.current === asked ? Promise.reject(e) : hold()));
  };
  const history = usePolledApi(() => onlyIfCurrent(loadHistory(kind, name)), [kind, name],
    { intervalMs: POLL_MS, enabled: known });
  const current = usePolledApi(() => onlyIfCurrent(loadCurrent(kind, name)), [kind, name],
    { intervalMs: POLL_MS, enabled: known && hasReader(kind) });
  return html`<${ConfigDetailView} kind=${kind} name=${name} known=${known}
    history=${history} current=${current} onRetryHistory=${history.reload} onRetryCurrent=${current.reload}/>`;
}

// The body, split from the hooks so every load state renders under test.
export function ConfigDetailView({ kind, name, known, history, current, onRetryHistory, onRetryCurrent }) {
  const head = html`
    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <${Link} to="/config" class="crumb">← ALL SETTINGS & FLAGS<//>
      <span class="page-title" style="overflow-wrap:anywhere">${plainLabel(kind)} · ${name}</span>
    </div>
    <${PageHeadline} chip=${plainLabel(kind)} line1=${name} line2="Its current value and every change, with who and why."/>`;
  const meaning = known && CONFIG_KIND_MEANING[kind];
  if (!known) {
    return html`<div class="page">${head}
      <${Empty} title=${`unknown kind: ${kind}`} note="config_changes holds no rows of this kind"/>
    </div>`;
  }
  return html`<div class="page">${head}
    ${meaning ? html`<p class="section__note">${meaning}</p>` : null}
    <${Section} title="CURRENT">
      <${Current} kind=${kind} name=${name} state=${current} onRetry=${onRetryCurrent}/>
    <//>
    <${Section} title="HISTORY" note="every change to this row, newest first">
      <${History} kind=${kind} name=${name} state=${history} onRetry=${onRetryHistory}/>
    <//>
  </div>`;
}

const forThis = (state, kind, name) => state.data && state.data.kind === kind && state.data.name === name;

const SETTING_LEGEND = [
  { term: 'VALUE', text: "the setting's current value" },
  { term: 'LAST WRITER', text: 'who changed it last' },
  { term: 'UPDATED', text: 'how long ago it last changed' },
  { term: 'NOTE', text: 'what the setting is for, as written when it was created' }
];
const FLAG_LEGEND = [
  { term: 'STATE', text: 'active means the switch is set; inactive means it is clear' },
  { term: 'LAST WRITER', text: 'who changed it last' },
  { term: 'UPDATED', text: 'how long ago it last changed' },
  { term: 'REASON', text: 'why it was last turned on or off' }
];

function Current({ kind, name, state, onRetry }) {
  if (!hasReader(kind)) {
    return html`<span style="color:var(--faint)">history only; this page has no current-row reader for ${kind}</span>`;
  }
  if (!forThis(state, kind, name)) {
    return state.error
      ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`
      : html`<${Skeleton} rows=${3} height=${14}/>`;
  }
  const cur = currentFor(kind, name, state.data.res);
  const box = state.error ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>` : null;
  if (cur.malformed) {
    return html`<${ErrorBox} error=${`unexpected response from the ${kind} read`} onRetry=${onRetry}/>`;
  }
  if (cur.missing) {
    return html`${box}<span style="color:var(--faint)">${cur.capped
      ? `not in the first ${FLAG_LIST_CAP} flags; the flag list is full, so this is not proof the flag is gone`
      : `no row: there is no ${kind} named ${name} now`}</span>`;
  }
  const r = cur.row;
  const items = [
    [kind === 'flag' ? 'STATE' : 'VALUE', orNa(r.value)],
    ['LAST WRITER', orNa(r.actor)],
    ['UPDATED', html`<span title=${r.at || ''}><${Age} min=${minutesSince(r.at)} warnAt=${Infinity}/></span>`],
    [kind === 'flag' ? 'REASON' : 'NOTE', orNa(r.note)]
  ];
  return html`${box}
    <dl style="display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 12px;margin:0">
      ${items.map(([k, v]) => html`
        <dt key=${`t-${k}`} style="color:var(--muted)">${k}</dt>
        <dd key=${`d-${k}`} style="margin:0;min-width:0;overflow-wrap:anywhere">${v}</dd>`)}
    </dl>
    <${Legend} items=${kind === 'flag' ? FLAG_LEGEND : SETTING_LEGEND}/>`;
}

function History({ kind, name, state, onRetry }) {
  if (!forThis(state, kind, name)) {
    return state.error
      ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>`
      : html`<${Skeleton} rows=${4} height=${18}/>`;
  }
  const { rows, truncated, malformed } = historyRows(state.data.res);
  if (malformed) {
    return html`<${ErrorBox} error=${'unexpected response from /api/coord/config-changes'} onRetry=${onRetry}/>`;
  }
  return html`
    ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${onRetry}/>` : null}
    ${truncated ? html`
      <div class="footnote"><span style="color:var(--faint)">showing the newest ${fmtNum(rows.length)} changes; sorting covers only these</span></div>` : null}
    ${rows.length
      ? html`<${ChangesTable} rows=${rows}/>`
      : html`<${Empty} title="no changes recorded yet" note=${`config_changes has nothing for ${kind} · ${name}`}/>`}`;
}

function ChangesTable({ rows }) {
  const columns = [
    { key: 'at', label: 'AT', sort: (r) => r.at || '',
      cell: (r) => (r.at
        ? html`<span title=${r.at} style="white-space:nowrap">${String(r.at).slice(0, 10)} ${clockTime(r.at)}</span>` : na) },
    { key: 'change', label: 'BEFORE → AFTER', sort: (r) => sideText(r.after_json, 'after'),
      cell: (r) => html`<span style="overflow-wrap:anywhere">${sideText(r.before_json, 'before')} → ${sideText(r.after_json, 'after')}</span>` },
    { key: 'actor', label: 'WHO', sort: (r) => r.actor || '', cell: (r) => orNa(r.actor) },
    { key: 'reason', label: 'WHY', sort: (r) => r.reason || '',
      cell: (r) => (r.reason ? html`<span class="cell-wrap">${r.reason}</span>` : na) }
  ];
  return html`<${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id} wide=${true}
    defaultSort="at" defaultDir="desc"/>`;
}

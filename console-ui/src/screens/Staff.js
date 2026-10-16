// BH-5567 (BH-5556.10): /staff, the staff roster (Archie plus the seven mill
// agents) with open findings and a kill switch per agent, and its drill-down:
// /staff/:agent (the agent detail page: facts, last heartbeat, the activity
// timeline and the open findings, BH-6822), /staff/finding/:id (one finding,
// out to its source and its ticket) and /staff/tick/:id (one heartbeat tick
// and its cost rows). The kill switch writes the
// staff-kill-<agent> or staff-kill-all flag through the Flags screen's own
// PUT and DELETE, in an in-app modal with a required reason. The modal closes
// only on a 2xx; the KILL column shows the flags read-back, never the intent.
// Each *Screen owns its reads and writes; each *View is a pure function of
// props so the tests render it server-side.
import { useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Modal } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { minutesSince, safeHttpsUrl } from '../lib/format.js';
import { configHref } from '../lib/config.js';
import { clearFormState } from '../lib/flags.js';
import {
  rosterRows, findingRows, killFlagName, killSetBody, killClearQuery, killState, displayName, na,
  KILL_ALL, ARCHIE, ARCHIE_KILL_FLAG
} from '../lib/staff.js';
import { activityRows, mergePages, heartbeatText, tickHref } from '../lib/staff-activity.js';
import { AgentChat } from './staff/agent-chat.js';
import { AgentLearning } from './staff/agent-learning.js';

const loadRoster = () => api.staffRoster();
const loadKillFlags = () => api.coordFlagsAll({ prefix: 'staff-kill-' });
const errText = (e) => (e && e.message ? e.message : String(e));
const FLAGS_NOTE = 'The staff heartbeat (BH-5561) reads these flags at the start of every tick.';

export function StaffScreen() {
  const roster = useApi(loadRoster, [], { intervalMs: 60000 });
  const flags = useApi(loadKillFlags, [], { intervalMs: 60000 });
  const [edit, setEdit] = useState(null);
  const [pending, setPending] = useState(false);
  const [serverError, setServerError] = useState(null);
  const [note, setNote] = useState(null);
  const nonce = useRef(0);
  // A second click can land before the render that shows SAVING….
  const inFlight = useRef(false);

  // kind is 'kill' (set the flag) or 'resume' (clear it). beat is { at } (the
  // agent's last tick) for one agent, null for all staff.
  const open = (kind, name, who, beat = null) => {
    nonce.current += 1;
    setServerError(null);
    setEdit({ kind, name, who, beat, nonce: nonce.current, draft: { reason: '' } });
  };

  const onConfirm = async () => {
    if (inFlight.current || !edit) return;
    const { kind, name, draft } = edit;
    const st = clearFormState(draft);
    if (st.blocked) { setServerError(st.hint); return; }
    const write = kind === 'kill' ? killSetBody(name, draft.reason) : killClearQuery(name, draft.reason);
    if (write === null) { setServerError(`refused: ${name} is not a staff kill flag`); return; }
    inFlight.current = true;
    setPending(true);
    setServerError(null);
    try {
      if (kind === 'kill') await api.setCoordFlagRow(write);
      else await api.clearCoordFlag(write);
      setNote(`${name} ${kind === 'kill' ? 'set' : 'cleared'} on fleet`);
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
      title=${`${edit.kind === 'kill' ? 'KILL' : 'RESUME'} ${edit.who}`}
      confirmLabel=${pending ? 'SAVING…' : edit.kind === 'kill' ? 'KILL' : 'RESUME'}
      tone=${edit.kind === 'kill' ? 'danger' : 'warn'}
      confirmBlocked=${true}
      body=${({ setBlocked }) => html`<${KillForm} edit=${edit} serverError=${serverError} onBlocked=${setBlocked}/>`}
      onConfirm=${onConfirm}
      onCancel=${() => { if (!inFlight.current) setEdit(null); }}/>` : null;

  return html`<${StaffView} roster=${roster} flags=${flags} onKill=${open} busy=${pending} note=${note} dialog=${dialog}/>`;
}

// The reason lives in the form's own state and is written through to the
// draft, so a poll re-rendering the page never resets what is typed (D39).
export function KillForm({ edit, serverError, onBlocked }) {
  const [reason, setReason] = useState(edit.draft.reason);
  const onInput = (v) => {
    edit.draft.reason = v;
    setReason(v);
    onBlocked(clearFormState(edit.draft).blocked);
  };
  const { hint } = clearFormState({ reason });
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span style="color:var(--faint);overflow-wrap:anywhere">
        ${edit.kind === 'kill' ? 'Sets' : 'Clears'} the fleet flag <b>${edit.name}</b>. The staff heartbeat reads it at the start of every tick.
      </span>
      ${edit.beat ? html`<span style="overflow-wrap:anywhere">${edit.who}: ${heartbeatText(edit.beat.at)}</span>` : null}
      <label class="knob" style="width:100%">
        <span class="knob__label">REASON</span>
        <input class="knob__input" style="width:100%" type="text" aria-label="reason" value=${reason}
          placeholder="why (required)" onInput=${(e) => onInput(e.target.value)}/>
      </label>
      ${hint ? html`<span style="color:var(--faint)">${hint}</span>` : null}
      ${serverError ? html`<span role="alert" style="color:var(--red);overflow-wrap:anywhere">${serverError}</span>` : null}
    </div>`;
}

const naCell = (v, title) => html`<span class=${v === null || v === undefined ? 'na' : ''} title=${title || ''}>${na(v)}</span>`;
const KILL_LABEL = { on: 'ON', off: 'off', unknown: 'unknown' };
const btn = (label, disabled, onClick) => html`
  <button type="button" class="btn btn--sm" style="min-height:44px" disabled=${disabled} onClick=${onClick}>${label}</button>`;

export function rosterColumns({ flagsData, sources, onKill, busy }) {
  const stateOf = (r) => {
    const name = r.name === ARCHIE ? null : killFlagName(r.name);
    return name ? killState(flagsData, name) : null;
  };
  return [
    {
      key: 'name', label: 'AGENT',
      cell: (r) => html`<${Link} to=${`/staff/${encodeURIComponent(r.name)}`} class="cell-name">${r.display}<//>
        <span class="na" style="display:block;font-size:var(--fs-xs)">${r.name}</span>`
    },
    { key: 'role', label: 'ROLE', cell: (r) => naCell(r.role) },
    { key: 'accountable', label: 'ACCOUNTABLE', cell: (r) => naCell(r.accountable) },
    { key: 'autonomy', label: 'AUTONOMY', cell: (r) => naCell(r.autonomy) },
    { key: 'cap', label: 'CAP', cell: (r) => naCell(r.cap) },
    { key: 'status', label: 'STATUS', cell: (r) => naCell(r.status) },
    {
      key: 'open_findings', label: 'OPEN FINDINGS', align: 'right',
      cell: (r) => html`<${Link} to=${`/staff/${encodeURIComponent(r.name)}`}>${na(r.open_findings)}<//>`
    },
    { key: 'precision', label: 'PRECISION', cell: (r) => naCell(r.precision, sources.precision) },
    { key: 'spend_usd', label: 'SPEND', unit: '$', cell: (r) => naCell(r.spend_usd, sources.spend) },
    {
      key: 'kill', label: 'KILL', sort: (r) => (r.name === ARCHIE ? ARCHIE_KILL_FLAG : stateOf(r)),
      cell: (r) => {
        if (r.name === ARCHIE) return html`<${Link} to=${configHref('flag', ARCHIE_KILL_FLAG)}>${ARCHIE_KILL_FLAG}<//>`;
        const s = stateOf(r);
        return s ? html`<span class=${s === 'unknown' ? 'na' : ''}>${KILL_LABEL[s]}</span>` : naCell(null);
      }
    },
    {
      key: 'action', label: 'ACTION', sort: null,
      cell: (r) => {
        const name = r.name === ARCHIE ? null : killFlagName(r.name);
        if (!name) return null;
        const s = stateOf(r);
        // An unread last tick is unknown (undefined), never "no tick yet".
        const beat = { at: sources.last_tick === 'unread' ? undefined : r.last_tick_at };
        return s === 'on'
          ? btn('RESUME…', busy, () => onKill('resume', name, r.display, beat))
          : btn('KILL…', busy || s === 'unknown', () => onKill('kill', name, r.display, beat));
      }
    }
  ];
}

const LEGEND = [
  { term: 'KILL', text: 'ON means the staff-kill flag for that agent is set; unknown means the flags read failed' },
  { term: 'OPEN FINDINGS', text: 'findings the agent claimed that are not merged, rejected, noise or closed' },
  { term: 'PRECISION', text: 'n/a until BH-5563 records outcomes' },
  { term: 'SPEND', text: 'n/a until BH-5561 records spend per agent' },
  { term: 'ARCHIE', text: 'the Overlooker; lane-off-archie stops it, and STOP ALL STAFF does not' }
];

export function StaffView({ roster, flags, onKill, busy = false, note = null, dialog = null }) {
  const res = rosterRows(roster && roster.data);
  const flagsData = flags && flags.data;
  const allState = killState(flagsData, KILL_ALL);

  let body;
  if (roster && roster.loading && !res) body = html`<${Skeleton} rows=${8} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(roster && roster.error) || new Error('the roster read returned no list')} onRetry=${roster && roster.reload}/>`;
  } else {
    body = html`
      ${roster && roster.error ? html`<${ErrorBox} error=${roster.error} onRetry=${roster.reload}/>` : null}
      <${SortableTable} columns=${rosterColumns({ flagsData, sources: res.sources, onKill, busy })} rows=${res.rows}
        rowKey=${(r) => r.name} defaultSort="open_findings" defaultDir="desc"
        empty=${html`<${Empty} title="no staff agents"/>`}/>`;
  }

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Staff"
        line1=${res ? `${res.rows.length} ${res.rows.length === 1 ? 'agent' : 'agents'} on the roster.` : roster && roster.loading ? 'Reading the roster.' : 'The roster read failed.'}
        line2="Archie and the mill staff, with their open findings."/>
      ${note ? html`<div class="banner banner--warn" role="status"
        style="margin-bottom:10px;border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)">
        <span style="overflow-wrap:anywhere">${note}</span></div>` : null}
      <${Section} title="ROSTER" note=${html`every staff agent; the flags page is <${Link} to="/flags">/flags<//>`}>
        <div style="display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;margin-bottom:8px">
          <span style="color:var(--faint);overflow-wrap:anywhere;flex:1 1 30ch">${FLAGS_NOTE}</span>
          <span>${`${KILL_ALL}: ${KILL_LABEL[allState]}`}</span>
          ${allState === 'on'
            ? btn('RESUME ALL STAFF…', busy, () => onKill && onKill('resume', KILL_ALL, 'ALL STAFF'))
            : btn('STOP ALL STAFF…', busy || allState === 'unknown', () => onKill && onKill('kill', KILL_ALL, 'ALL STAFF'))}
        </div>
        ${flags && flags.error ? html`<${ErrorBox} error=${flags.error} onRetry=${flags.reload}/>` : null}
        ${body}
        <${Legend} items=${LEGEND}/>
      <//>
    </div>`;
}

// ---------------------------------------------------------------- /staff/:agent

export function StaffAgentScreen({ agent }) {
  const roster = useApi(loadRoster, []);
  const findings = useApi(() => api.staffFindings(agent), [agent], { intervalMs: 60000 });
  const activity = useApi(() => api.staffActivity(agent, {}), [agent], { intervalMs: 60000 });
  // The OLDER pages: { rows, next } once one loaded. A request started for
  // another agent never lands here (version guard).
  const [older, setOlder] = useState(null);
  const [olderBusy, setOlderBusy] = useState(false);
  const [olderError, setOlderError] = useState(null);
  const version = useRef(0);
  const inFlight = useRef(false);
  useEffect(() => {
    version.current += 1;
    inFlight.current = false;
    setOlder(null); setOlderBusy(false); setOlderError(null);
  }, [agent]);

  const first = activityRows(activity.data);
  const next = older ? older.next : first && first.next;
  const onOlder = async () => {
    if (!next || inFlight.current) return;
    const v = version.current;
    inFlight.current = true;
    setOlderBusy(true);
    setOlderError(null);
    try {
      const page = activityRows(await api.staffActivity(agent, { before: next }));
      if (v !== version.current) return;
      if (!page) throw new Error('the older page returned no event list');
      // The first OLDER keeps the page-one rows on screen now. Page one
      // refreshes every 60 s, and a new event at its head pushes its last row
      // out; without this seed that row falls between the pages unseen.
      const seed = first ? first.rows : [];
      setOlder((o) => ({ rows: mergePages(o ? o.rows : seed, page.rows), next: page.next }));
    } catch (e) {
      if (v === version.current) setOlderError(errText(e));
    } finally {
      if (v === version.current) { inFlight.current = false; setOlderBusy(false); }
    }
  };
  return html`<${AgentDetailView} agent=${agent} roster=${roster} findings=${findings} activity=${activity}
    older=${older} onOlder=${onOlder} olderBusy=${olderBusy} olderError=${olderError}/>`;
}

const age = (iso) => (iso
  ? html`<span title=${iso}><${Age} min=${minutesSince(iso)} warnAt=${Infinity}/></span>`
  : naCell(null));
const extLink = (url, label) => {
  const href = safeHttpsUrl(url);
  return href
    ? html`<a href=${href} target="_blank" rel="noopener" style="overflow-wrap:anywhere">${label || href}</a>`
    : html`<span style="overflow-wrap:anywhere">${na(url)}</span>`;
};
const ticketLabel = (url) => {
  const tail = String(url || '').split('/').filter(Boolean).pop();
  return /^\d+$/.test(tail || '') ? `#${tail}` : 'ticket';
};
const findingHref = (id) => `/staff/finding/${encodeURIComponent(id)}`;

const FINDING_COLUMNS = [
  { key: 'id', label: 'ID', align: 'right', cell: (f) => html`<${Link} to=${findingHref(f.id)}>${f.id}<//>` },
  { key: 'title', label: 'TITLE', flex: true, cell: (f) => html`<${Link} to=${findingHref(f.id)} class="cell-name">${f.title}<//>` },
  { key: 'status', label: 'STATUS', cell: (f) => naCell(f.status) },
  { key: 'source_url', label: 'SOURCE', cell: (f) => extLink(f.source_url, f.source_kind) },
  { key: 'observed_at', label: 'OBSERVED', cell: (f) => age(f.observed_at) },
  { key: 'claimed_at', label: 'CLAIMED', cell: (f) => age(f.claimed_at) },
  {
    key: 'ticket_url', label: 'TICKET',
    cell: (f) => (f.ticket_url ? extLink(f.ticket_url, ticketLabel(f.ticket_url)) : html`<span class="na">none yet</span>`)
  }
];

const fmtDuration = (s) => (s === null || s === undefined ? 'n/a' : s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`);
const fmtUsd = (v) => (v === null || v === undefined ? null : `$${Number(v).toFixed(4)}`);
const costCell = (r) => {
  if (r.kind !== 'tick') return html`<span class="na">—</span>`;
  if (r.cost === null) return html`<span class="na" title="no cost row for this tick">${r.unpriced ? `${r.unpriced} unpriced` : 'n/a'}</span>`;
  return html`<span>${fmtUsd(r.cost)}${r.unpriced ? html` <span class="na">+${r.unpriced} unpriced</span>` : null}</span>`;
};

const ACTIVITY_COLUMNS = [
  { key: 'when', label: 'WHEN', sort: (r) => r.ts, cell: (r) => age(r.ts) },
  { key: 'kindLabel', label: 'KIND', cell: (r) => r.kindLabel },
  {
    key: 'summary', label: 'WHAT', flex: true,
    cell: (r) => html`
      ${r.href ? html`<${Link} to=${r.href} class="cell-name" style="overflow-wrap:anywhere">${r.summary}<//>`
        : html`<span style="overflow-wrap:anywhere">${r.summary}</span>`}
      ${r.ext ? html` <a href=${r.ext} target="_blank" rel="noopener">${ticketLabel(r.ext)}</a>` : null}`
  },
  { key: 'result', label: 'RESULT', cell: (r) => naCell(r.result) },
  { key: 'duration_s', label: 'DURATION', align: 'right', cell: (r) => (r.kind === 'tick' ? fmtDuration(r.duration_s) : html`<span class="na">—</span>`) },
  { key: 'cost', label: 'COST', unit: '$', align: 'right', cell: costCell }
];

function ActivityBody({ activity, older, onOlder, olderBusy, olderError }) {
  const first = activityRows(activity && activity.data);
  if (!activity || (activity.loading && !first)) return html`<${Skeleton} rows=${6} height=${20}/>`;
  if (first === null) {
    return html`<${ErrorBox} error=${activity.error || new Error('the activity read returned no event list')} onRetry=${activity.reload}/>`;
  }
  const rows = older ? mergePages(first.rows, older.rows) : first.rows;
  const next = older ? older.next : first.next;
  const note = `sorts the ${rows.length} loaded rows; OLDER loads more${first.costStatus === 'unread' ? '; cost unread' : ''}`;
  return html`
    ${activity.error ? html`<${ErrorBox} error=${activity.error} onRetry=${activity.reload}/>` : null}
    <p style="color:var(--faint);margin:0 0 6px">${note}</p>
    <${SortableTable} wide columns=${ACTIVITY_COLUMNS} rows=${rows} rowKey=${(r) => r.key} defaultSort="when" defaultDir="desc"
      empty=${html`<${Empty} title="no activity recorded yet"/>`}/>
    ${olderError ? html`<p role="alert" style="color:var(--red);overflow-wrap:anywhere">older page: ${olderError}</p>` : null}
    ${next ? html`<p>${btn(olderBusy ? 'LOADING…' : 'OLDER', olderBusy || !onOlder, () => onOlder && onOlder())}</p>` : null}`;
}

// The last heartbeat fact: the newest tick, linked to its page. Unknown until
// the activity read answers.
function lastBeat(activity) {
  const res = activityRows(activity && activity.data);
  if (!res) return naCell(null);
  const lt = res.lastTick;
  if (!lt) return html`<span class="na">no tick recorded yet</span>`;
  return html`<${Link} to=${tickHref(lt.id)}>${age(lt.started_at)}<//>${lt.phase !== 'done' ? html` <span class="na">stopped at ${lt.phase}</span>` : null}`;
}

// The agent detail page. autonomySlot is the AUTONOMY section the screen
// passes in (BH-6824); without it the spot is empty.
export function AgentDetailView({ agent, roster, findings, activity, older = null, onOlder = null, olderBusy = false, olderError = null, autonomySlot = null }) {
  const rr = rosterRows(roster && roster.data);
  const row = rr && rr.rows.find((a) => a.name === String(agent || '').trim().toLowerCase());
  const res = findingRows(findings && findings.data);

  let body;
  if (findings && findings.loading && !res) body = html`<${Skeleton} rows=${4} height=${20}/>`;
  else if (res === null) {
    body = html`<${ErrorBox} error=${(findings && findings.error) || new Error('the findings read returned no list')} onRetry=${findings && findings.reload}/>`;
  } else {
    body = html`
      ${findings && findings.error ? html`<${ErrorBox} error=${findings.error} onRetry=${findings.reload}/>` : null}
      ${res.truncated ? html`<p style="color:var(--faint)">the list is capped at 500: the newest 500 open findings show</p>` : null}
      <${SortableTable} wide columns=${FINDING_COLUMNS} rows=${res.rows} rowKey=${(f) => f.id} defaultSort="id" defaultDir="desc"
        empty=${html`<${Empty} title="no open findings"/>`}/>`;
  }

  const facts = row ? [['ROLE', row.role], ['ACCOUNTABLE', row.accountable], ['AUTONOMY', row.autonomy], ['CAP', row.cap], ['STATUS', row.status]] : [];
  const name = String(agent || '').trim().toLowerCase();
  return html`
    <div class="page">
      <${PageHeadline} chip="Staff"
        line1=${displayName(agent)}
        line2=${res ? `${res.rows.length} open ${res.rows.length === 1 ? 'finding' : 'findings'}${res.truncated ? ' (capped)' : ''}.` : 'Open findings.'}/>
      <p><${Link} to="/staff">← the roster<//></p>
      <dl class="lanekv">
        ${facts.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${na(v)}</dd>`)}
        <dt key="t-beat">LAST HEARTBEAT</dt><dd key="d-beat">${lastBeat(activity)}</dd>
      </dl>
      <${AgentChat} agent=${name} row=${row || null}/>
      ${autonomySlot}
      <${Section} title="ACTIVITY" note="ticks, findings, outcomes and decisions, newest first">
        <${ActivityBody} activity=${activity} older=${older} onOlder=${onOlder} olderBusy=${olderBusy} olderError=${olderError}/>
      <//>
      <${Section} title="OPEN FINDINGS">${body}<//>
      <${AgentLearning} agent=${name} row=${row || null}/>
    </div>`;
}
// BH-5567's name for the same view; its tests and imports stay valid.
export const StaffAgentView = AgentDetailView;

// ---------------------------------------------------------- /staff/finding/:id

export function StaffFindingScreen({ id }) {
  const finding = useApi(() => api.staffFinding(id), [id]);
  return html`<${StaffFindingView} id=${id} finding=${finding}/>`;
}

const labelsText = (f) => (f.labels_invalid
  ? `${na(f.source_labels)} (not a valid label list)`
  : Array.isArray(f.source_labels) && f.source_labels.length ? f.source_labels.join(', ') : 'none');

export function StaffFindingView({ id, finding }) {
  const f = finding && finding.data && finding.data.finding;
  let body;
  if (finding && finding.loading && !f) body = html`<${Skeleton} rows=${8} height=${18}/>`;
  else if (!f) {
    body = html`<${ErrorBox} error=${(finding && finding.error) || new Error('the finding read returned no row')} onRetry=${finding && finding.reload}/>`;
  } else {
    const items = [
      ['ID', String(f.id)],
      ['AGENT', html`<${Link} to=${`/staff/${encodeURIComponent(f.agent)}`}>${displayName(f.agent)}<//>`],
      ['TITLE', f.title],
      ['STATUS', na(f.status)],
      ['TICKET', f.ticket_url ? extLink(f.ticket_url) : html`<span class="na">no ticket filed yet</span>`],
      ['SOURCE', extLink(f.source_url)],
      ['SOURCE KIND', na(f.source_kind)],
      ['LABELS', labelsText(f)],
      ['FILED BY', na(f.source_filed_by)],
      ['OBSERVED', na(f.observed_at)],
      ['CLAIMED', na(f.claimed_at)],
      ['UPDATED', na(f.updated_at)],
      ['FINGERPRINT', html`<code style="overflow-wrap:anywhere">${f.fingerprint}</code>`]
    ];
    body = html`
      <dl class="lanekv">
        ${items.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${v}</dd>`)}
      </dl>`;
  }
  return html`
    <div class="page">
      <${PageHeadline} chip="Staff" line1=${f ? f.title : `Finding ${id || ''}`}
        line2=${f ? `${displayName(f.agent)}, ${na(f.status)}.` : 'One staff finding.'}/>
      <p>${f ? html`<${Link} to=${`/staff/${encodeURIComponent(f.agent)}`}>← ${displayName(f.agent)}'s findings<//>` : html`<${Link} to="/staff">← the roster<//>`}</p>
      <${Section} title="FINDING">${body}<//>
    </div>`;
}

// ------------------------------------------------------------- /staff/tick/:id

export function StaffTickScreen({ id }) {
  const tick = useApi(() => api.staffTick(id), [id]);
  return html`<${StaffTickView} id=${id} tick=${tick}/>`;
}

const COST_COLUMNS = [
  { key: 'ts', label: 'TS', cell: (c) => na(c.ts) },
  { key: 'stage', label: 'STAGE', cell: (c) => naCell(c.stage) },
  { key: 'model', label: 'MODEL', cell: (c) => naCell(c.model) },
  { key: 'rc', label: 'RC', align: 'right', cell: (c) => naCell(c.rc) },
  { key: 'duration_s', label: 'DURATION', unit: 's', align: 'right', cell: (c) => naCell(c.duration_s) },
  {
    key: 'cost_usd', label: 'COST', unit: '$', align: 'right',
    cell: (c) => (c.cost_usd === null || c.cost_usd === undefined ? html`<span class="na">unpriced</span>` : fmtUsd(c.cost_usd))
  },
  { key: 'session_id', label: 'SESSION', cell: (c) => html`<code style="overflow-wrap:anywhere">${na(c.session_id)}</code>` }
];

export function StaffTickView({ id, tick }) {
  const d = tick && tick.data;
  const t = d && d.tick;
  let body;
  if (tick && tick.loading && !t) body = html`<${Skeleton} rows=${8} height=${18}/>`;
  else if (!t) {
    body = html`<${ErrorBox} error=${(tick && tick.error) || new Error('the tick read returned no row')} onRetry=${tick && tick.reload}/>`;
  } else {
    const items = [
      ['ID', String(t.id)],
      ['AGENT', html`<${Link} to=${`/staff/${encodeURIComponent(t.agent)}`}>${displayName(t.agent)}<//>`],
      ['PHASE', t.phase === 'done' ? 'done' : `stopped at ${t.phase}`],
      ['STARTED', na(t.started_at)],
      ['ENDED', na(t.ended_at)],
      ['DURATION', fmtDuration(t.duration_s)],
      ['COLLECTOR RC', na(t.collector_rc)],
      ['COLLECTOR SECONDS', na(t.collector_s)],
      ['MODEL RC', na(t.model_rc)],
      ['COLLECTED', na(t.collected)], ['NEW', na(t.new_items)], ['DEFERRED', na(t.deferred)],
      ['MODEL CALLS', na(t.model_calls)], ['DIGESTED', na(t.digested)], ['FILED', na(t.filed)],
      ['REFUSED', na(t.refused)], ['UNSUPPORTED', na(t.unsupported)], ['FAILED', na(t.failed)], ['HELD', na(t.held)],
      ['COST RUN ID', html`<code style="overflow-wrap:anywhere">${na(t.cost_run_id)}</code>`],
      ['TICK KEY', html`<code style="overflow-wrap:anywhere">${t.tick_key}</code>`]
    ];
    const rows = Array.isArray(d.cost_rows) ? d.cost_rows : [];
    body = html`
      <dl class="lanekv">
        ${items.map(([k, v]) => html`<dt key=${`t-${k}`}>${k}</dt><dd key=${`d-${k}`}>${v}</dd>`)}
      </dl>
      <${Section} title="COST ROWS" note=${d.cost_status === 'unread' ? 'the cost read failed' : d.cost_rows_truncated ? 'the first 20 rows' : 'the model calls of this tick; SESSION is the transcript id'}>
        ${d.cost_status === 'unread' ? html`<span class="na">cost unread</span>` : html`
          <${SortableTable} wide columns=${COST_COLUMNS} rows=${rows} rowKey=${(c) => `${c.ts}|${c.session_id}`} defaultSort="ts"
            empty=${html`<${Empty} title="no cost rows" note=${t.cost_run_id ? 'none pushed for this tick yet' : 'this tick made no model call'}/>`}/>`}
      <//>`;
  }
  return html`
    <div class="page">
      <${PageHeadline} chip="Staff" line1=${t ? `${displayName(t.agent)} tick ${t.id}` : `Tick ${id || ''}`}
        line2=${t ? `${t.started_at}, ${t.phase === 'done' ? 'done' : `stopped at ${t.phase}`}.` : 'One staff heartbeat tick.'}/>
      <p>${t ? html`<${Link} to=${`/staff/${encodeURIComponent(t.agent)}`}>← ${displayName(t.agent)}<//>` : html`<${Link} to="/staff">← the roster<//>`}</p>
      <${Section} title="TICK">${body}<//>
    </div>`;
}

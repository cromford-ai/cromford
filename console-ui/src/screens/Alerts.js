import { useState, useCallback, useRef } from 'preact/hooks';
import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Modal, useConfirm } from '../ui/Modal.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, ProjectLink, Legend } from '../ui/primitives.js';
import { minutesSince, clockTime, agoFromMinutes, whenLabel } from '../lib/format.js';
import {
  shapeAlertRows, alertSortValue, filterHref, familyHref, boxHref, stateHref,
  FLEET_ROWS_LIMIT, FLEET_ROWS_DEFAULT_STATE,
  alertRowActions, shapeAlertActions, actionOutcomeText
} from '../lib/alertrows.js';
import { decisionsHref } from '../lib/components.js';

const FILTER_KEYS = ['family', 'box', 'state', 'component'];
const withoutFilter = (filters, drop) =>
  Object.fromEntries(FILTER_KEYS.filter((k) => k !== drop).map((k) => [k, filters[k]]));

// Small faint text under a cell's primary text: the id under the line, the
// key under the alert text.
const SECONDARY = 'display:block;font-size:var(--fs-2xs);color:var(--faint)';

// The line reads first; the id sits small under it. With no line the id is
// the only thing to show, so it stays primary.
const idCell = (r, idNode) => (r.line
  ? html`<span class="cell-wrap" title=${r.line}>${r.line}</span><span style=${SECONDARY}>${idNode}</span>`
  : idNode);

const fleetColumns = (nowMs) => [
  // No per-alert route exists yet, so the id carries the atomic thing the row
  // is about — its latest line — rather than a link to a page we do not have.
  {
    key: 'id', label: 'ID', sort: (r) => alertSortValue(r, 'id'),
    cell: (r) => idCell(r, html`<span class="cell-name" title=${r.line}>${r.id}</span>`)
  },
  {
    key: 'family', label: 'FAMILY', sort: (r) => alertSortValue(r, 'family'),
    cell: (r) => (r.family
      ? html`<${Link} to=${familyHref(r.family)} class="cell-name">${r.family}<//>`
      : html`<span class="na">—</span>`)
  },
  {
    key: 'box', label: 'BOX', sort: (r) => alertSortValue(r, 'box'),
    cell: (r) => (r.box
      ? html`<${Link} to=${boxHref(r.box)} class="cell-name">${r.box}<//>`
      : html`<span class="na">—</span>`)
  },
  {
    // '' is fleet-wide per the contract, not a missing project: it says so
    // rather than linking to /p/ with nothing after it.
    key: 'project', label: 'PROJECT', sort: (r) => alertSortValue(r, 'project'),
    cell: (r) => (r.project
      ? html`<${ProjectLink} project=${r.project}/>`
      : html`<span class="na">fleet</span>`)
  },
  {
    key: 'state', label: 'STATE', sort: (r) => alertSortValue(r, 'state'),
    cell: (r) => html`<${Link} to=${stateHref(r.state)} class="tag">${r.state}<//>`
  },
  { key: 'count', label: 'COUNT', sort: (r) => alertSortValue(r, 'count'), align: 'right', cell: (r) => r.count },
  {
    key: 'first_seen', label: 'FIRST SEEN', sort: (r) => alertSortValue(r, 'first_seen'), align: 'right',
    cell: (r) => html`<span title=${r.first_seen}><${Age} min=${r.ageMin} warnAt=${120}/></span>`
  },
  {
    key: 'last_seen', label: 'LAST SEEN', sort: (r) => alertSortValue(r, 'last_seen'), align: 'right',
    cell: (r) => html`<span title=${r.last_seen}><${Age} min=${r.lastSeenMin} warnAt=${120}/></span>`
  },
  {
    key: 'claimed_by', label: 'CLAIMED BY', sort: (r) => alertSortValue(r, 'claimed_by'),
    cell: (r) => (r.lane
      ? html`<span class="tag">${r.lane}</span>${r.laneBox
        ? html`<span style="color:var(--faint)">@${r.laneBox}</span>` : null}`
      : html`<span class="na">—</span>`)
  },
  {
    key: 'notified_at', label: 'NOTIFIED', sort: (r) => alertSortValue(r, 'notified_at'), align: 'right',
    cell: (r) => html`<span title=${r.notified_at || ''}>${whenLabel(r.notified_at, nowMs)}</span>`
  }
];

export const ALERTS_LEGEND = [
  { term: 'FAMILY', text: 'alerts whose lines match the same pattern, grouped under one short id; click it to see only that group' },
  { term: 'COUNT', text: 'how many times this alert fired since it was first seen' },
  { term: 'CLAIMED BY', text: 'the lane and box working on it; blank means nobody has picked it up' },
  {
    term: 'STATE',
    text: 'new: not handled yet. quarantined: held back from notifications for now. triaged: someone looked and it is known. parked: set aside on purpose. resolved: closed'
  },
  { term: 'NOTIFIED', text: 'the last time it was sent anywhere' }
];

const ACTION_LABEL = { ack: 'ACK', snooze: 'SNOOZE', resolve: 'RESOLVE', note: 'NOTE' };

const historyColumns = (nowMs) => [
  { key: 'at', label: 'AT', sort: (a) => a.at, cell: (a) => html`<span title=${a.at}>${whenLabel(a.at, nowMs)}</span>` },
  { key: 'action', label: 'ACTION', sort: (a) => a.action, cell: (a) => html`<span class="tag">${a.action}</span>` },
  { key: 'actor', label: 'ACTOR', sort: (a) => a.actor, cell: (a) => a.actor || html`<span class="na">—</span>` },
  { key: 'outcome', label: 'OUTCOME', sort: (a) => a.outcome, cell: (a) => a.outcome || html`<span class="na">—</span>` },
  {
    key: 'note', label: 'NOTE', sort: (a) => a.note,
    cell: (a) => (a.noteShort
      ? html`<span class="cell-wrap" title=${a.note}>${a.noteShort}</span>`
      : html`<span class="na">—</span>`)
  }
];

// One alert's action log, the atomic record behind a FLEET ROWS id.
function AlertHistory({ id, history, onClose, nowMs }) {
  const shaped = history.shaped;
  return html`
    <div id="alert-history" style="margin-top:12px">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;flex-wrap:wrap">
        <span class="section__title">HISTORY · ${id}</span>
        ${shaped && shaped.truncated
          ? html`<span style="font-size:var(--fs-sm);color:var(--faint)">showing ${shaped.rows.length} of more</span>`
          : null}
        <button type="button" class="btn btn--sm" style="margin-left:auto" onClick=${onClose}>CLOSE</button>
      </div>
      ${history.error && !shaped
        ? html`<${ErrorBox} error=${history.error} onRetry=${history.reload}/>`
        : !shaped
          // No data and no error is still finding out, even in the one render
          // before useApi notices the id changed: never the empty state.
          ? html`<${Skeleton} rows=${3} height=${18}/>`
          : html`<${SortableTable} columns=${historyColumns(nowMs)} rows=${shaped ? shaped.rows : []}
              rowKey=${(a) => a.id} defaultSort="at" defaultDir="desc"
              empty=${html`<${Empty} title="no actions recorded"
                note="The worker holds no action rows for this alert." />`}/>`}
    </div>`;
}

// The NOTE modal's body. Confirm stays blocked until the text is not blank.
export function NoteDialogBody({ setBlocked, onText }) {
  return html`<textarea maxlength="1000" rows="4" aria-label="note" style="width:100%"
    onInput=${(e) => { setBlocked(!e.target.value.trim()); onText(e.target.value); }}></textarea>`;
}

// The fleet's own alerts table, read through the coord proxy. It writes only
// through the per-row ACK / SNOOZE / RESOLVE / NOTE buttons, and only when
// `AlertsScreen` passes `actions`; without it the table is read-only. The OPEN
// table above keeps its own `resolve_alert`, and this section owns its own read
// so a worker that has not shipped the route yet shows its failure HERE and
// leaves that table alone.
// `nowMs` is the one clock read the screen handed the shaper, so NOTIFIED and
// the ages beside it are measured from the same instant.
export function FleetRowsSection({ loading, error, onRetry, shaped, filters, actions, nowMs = Date.now() }) {
  // Under a component filter (the Components screen's drill-down, BH-6973)
  // each row also links to what component-watch decided on it. Without that
  // filter the columns are the ones this table always had.
  const fleetCols = filters && filters.component
    ? [...fleetColumns(nowMs), {
      key: 'decisions', label: 'DECISIONS', sort: null,
      cell: (r) => html`<${Link} to=${decisionsHref(r.id)} class="btn btn--sm">DECISIONS<//>`
    }]
    : fleetColumns(nowMs);
  const columns = actions
    ? [
      {
        ...fleetCols[0],
        cell: (r) => idCell(r, html`<button type="button" class="cell-name"
          style="background:none;border:0;padding:0;font:inherit;color:inherit;cursor:pointer;text-align:left;text-decoration:underline dotted"
          aria-expanded=${actions.openId === r.id ? 'true' : 'false'} aria-controls="alert-history"
          title=${r.line} onClick=${() => actions.onToggleHistory(r.id)}>${r.id}</button>`)
      },
      ...fleetCols.slice(1),
      {
        key: 'actions', label: 'ACTIONS', sort: null,
        cell: (r) => html`<div style="display:flex;flex-wrap:wrap;gap:4px">
          ${alertRowActions(r).map((act) => html`
            <button type="button" class="btn btn--sm" key=${act} disabled=${Boolean(actions.pending[r.id])}
              onClick=${() => actions.onAction(r, act)}>${ACTION_LABEL[act]}</button>`)}
        </div>`
      }
    ]
    : fleetCols;
  const active = FILTER_KEYS.filter((k) => filters && filters[k]);
  const rows = shaped ? shaped.rows : [];
  const note = shaped
    ? (shaped.truncated
      ? `showing ${rows.length} of more`
      : `${rows.length} row${rows.length === 1 ? '' : 's'}`)
    : null;

  return html`
    <${Section} title="FLEET ROWS" note=${note}>
      ${active.length || (shaped && shaped.asOf) ? html`
        <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px">
          ${active.map((k) => html`
            <span class="pill" key=${k}>
              ${k}=${filters[k]}
              <${Link} to=${filterHref(withoutFilter(filters, k))} class="btn btn--sm"
                style="margin-left:4px;min-height:auto;padding:1px 6px"
                title=${`clear the ${k} filter`}>CLEAR<//>
            </span>`)}
          ${shaped && shaped.asOf
            ? html`<span style="font-size:var(--fs-sm);color:var(--faint)">as of ${clockTime(shaped.asOf)}</span>`
            : null}
        </div>` : null}

      ${loading && !shaped
        ? html`<${Skeleton} rows=${4} height=${20}/>`
        : error && !shaped
          ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`
          : html`<${SortableTable} columns=${columns} rows=${rows}
              rowKey=${(r) => r.id}
              rowClass=${(r) => (r.state === 'new' ? 'row--warn' : '')}
              defaultSort="first_seen" defaultDir="asc"
              empty=${active.length
                ? html`<${Empty} title="no fleet rows match"
                    note=${`${active.map((k) => `${k}=${filters[k]}`).join(' · ')} narrows this list — clear a chip to widen it.`}/>`
                : html`<${Empty} title="no fleet rows yet"
                    note="Either the alerts-db flag is off or nothing has fired." />`}/>
              ${rows.length ? html`<${Legend} items=${ALERTS_LEGEND}/>` : null}`}
      ${actions && actions.openId ? html`
        <${AlertHistory} id=${actions.openId} history=${actions.history} nowMs=${nowMs}
          onClose=${() => actions.onToggleHistory(actions.openId)}/>` : null}
    <//>`;
}

// OPEN ALERTS. The key is the alert's machine name, so it sits small under
// the line rather than taking a column of its own.
export function openAlertColumns(resolving, resolve) {
  return [
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    {
      key: 'ts', label: 'AGE', sort: (r) => minutesSince(r.ts), align: 'right',
      cell: (r) => html`<span title=${r.ts}><${Age} min=${minutesSince(r.ts)} warnAt=${120}/></span>`
    },
    {
      key: 'line', label: 'LINE', sort: null,
      cell: (r) => html`<span class="cell-wrap" title=${r.line}>${r.line}</span>${r.akey
        ? html`<span style=${SECONDARY}>${r.akey}</span>` : null}`
    },
    {
      key: 'action', label: '', sort: null, align: 'right',
      cell: (r) => html`<button class="btn btn--sm" disabled=${resolving[r.id]}
        onClick=${() => resolve(r)}>${resolving[r.id] ? '…' : 'RESOLVE'}</button>`
    }
  ];
}

export const resolvedColumns = (nowMs) => [
  { key: 'project', label: 'PROJECT', sort: (a) => a.project,
    cell: (a) => html`<${Link} to=${`/p/${encodeURIComponent(a.project)}`} class="cell-name">${a.project}<//>` },
  { key: 'ts', label: 'RAISED', sort: (a) => minutesSince(a.ts), align: 'right',
    cell: (a) => html`<span title=${a.ts}>${whenLabel(a.ts, nowMs)}</span>` },
  { key: 'line', label: 'LINE', sort: null,
    cell: (a) => html`<span class="cell-wrap" title=${a.line}>${a.line}</span>` },
  { key: 'resolved_reason', label: 'RESOLVED BY', sort: (a) => a.resolved_reason,
    cell: (a) => a.resolved_reason
      ? html`<span class="tag">${a.resolved_reason}</span>`
      : html`<span class="na">—</span>` }
];

// Alerts live per project in D1, so the open set is assembled from each
// project's own /p/:project payload rather than from one alerts endpoint.
export function AlertsScreen() {
  const fleet = useFleet();
  // A per-project alert count on the fleet screen links here with ?project=,
  // so the number you clicked and the rows you land on are the same set.
  const filterProject = useSearchParam('project');
  const projects = (fleet.data && fleet.data.projects) || [];
  const all = useApi(
    async () => {
      const results = await Promise.all(projects.map(async (p) => {
        try {
          const d = await api.project(p);
          return (d.alerts || []).map((a) => ({ ...a, project: p }));
        } catch {
          // One unreachable project must not blank the whole alerts screen.
          return [{ project: p, _unreadable: true }];
        }
      }));
      return results.flat();
    },
    [projects.join(',')],
    { intervalMs: 30000 }
  );

  // The fleet table's own read: its own filters, its own failure. `state`
  // defaults to everything unresolved, so the section opens as a worklist.
  const filterFamily = useSearchParam('family');
  const filterBox = useSearchParam('box');
  const filterState = useSearchParam('state');
  const filterComponent = useSearchParam('component');
  const fleetRows = useApi(
    () => api.alerts({
      state: filterState || FLEET_ROWS_DEFAULT_STATE,
      family: filterFamily,
      box: filterBox,
      component: filterComponent,
      limit: FLEET_ROWS_LIMIT
    }),
    [filterFamily, filterBox, filterState, filterComponent],
    { intervalMs: 30000 }
  );

  const [resolving, setResolving] = useState({});
  const [msg, setMsg] = useState(null);

  const resolve = useCallback(async (alert) => {
    setResolving((s) => ({ ...s, [alert.id]: true }));
    setMsg(null);
    try {
      await api.action({ type: 'resolve_alert', alert_id: alert.id });
      setMsg({ ok: true, text: `resolved alert #${alert.id} on ${alert.project}` });
      all.reload();
    } catch (e) {
      setMsg({ ok: false, text: `could not resolve #${alert.id} — ${e.message}` });
    } finally {
      setResolving((s) => ({ ...s, [alert.id]: false }));
    }
  }, [all]);

  // FLEET ROWS row actions (BH-2324). The history read is keyed on the open id,
  // so switching rows clears the old log instead of showing it under the new one.
  const [pendingRow, setPendingRow] = useState({});
  const [openId, setOpenId] = useState(null);
  const [noteFor, setNoteFor] = useState(null);
  const noteText = useRef('');
  const [confirmNode, confirm] = useConfirm();
  const history = useApi(
    () => (openId ? api.alertActions(openId) : Promise.resolve(null)),
    [openId]
  );

  const runAction = async (row, act, note) => {
    setPendingRow((s) => ({ ...s, [row.id]: true }));
    setMsg(null);
    let response = null;
    let error = null;
    try {
      response = await api.alertAction(row.id, act, note);
    } catch (e) {
      error = e;
    } finally {
      setPendingRow((s) => ({ ...s, [row.id]: false }));
    }
    setMsg(actionOutcomeText(act, row.id, { response, error }));
    // A refusal means the row moved under us, so both paths re-read it.
    fleetRows.reload();
    if (openId === row.id) history.reload();
  };

  const onAction = async (row, act) => {
    if (act === 'note') {
      noteText.current = '';
      setNoteFor(row);
      return;
    }
    if (act === 'ack' || act === 'resolve') {
      const ok = await confirm({
        title: act === 'ack' ? 'ACK ALERT' : 'RESOLVE ALERT',
        body: `${act === 'ack' ? 'Ack' : 'Resolve'} ${row.id} (${row.state}). The console cannot undo this.`,
        confirmLabel: act === 'ack' ? 'ACK' : 'RESOLVE',
        tone: 'warn'
      });
      if (!ok) return;
    }
    runAction(row, act);
  };

  // Until the fleet answers we do not know WHICH projects to ask, so there is
  // no honest empty state to show yet — only "still finding out".
  if (!fleet.data) {
    return html`<div class="page"><${PageHeadline} chip="Alerts" line1="Reading the alerts." line2="The fleet list comes first."/><${Skeleton} rows=${5} height=${22}/></div>`;
  }

  const rows = all.data || [];
  // One clock read per render, handed to the shaper, so every age on the table
  // is measured from the same instant.
  const nowMs = Date.now();
  const shapedFleet = fleetRows.data ? shapeAlertRows(fleetRows.data, nowMs) : null;
  const unreadable = rows.filter((a) => a._unreadable);
  const alerts = rows
    .filter((a) => !a._unreadable)
    .filter((a) => !filterProject || a.project === filterProject);
  const open = alerts.filter((a) => !a.resolved);
  const resolved24h = alerts.filter((a) => a.resolved && minutesSince(a.ts) <= 1440);
  const last24h = alerts.filter((a) => minutesSince(a.ts) !== null && minutesSince(a.ts) <= 1440);

  const columns = openAlertColumns(resolving, resolve);

  return html`
    <div class="page">
      <${PageHeadline} chip=${filterProject ? `Alerts · ${filterProject}` : 'Alerts'}
        line1=${all.data ? `${open.length} open ${open.length === 1 ? 'alert' : 'alerts'}.` : all.error ? 'The alerts read failed.' : 'Reading the alerts.'}
        line2=${all.data ? `${resolved24h.length} resolved in the last 24 hours.${unreadable.length ? ` ${unreadable.length} projects not read.` : ''}` : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/" class="crumb">← FLEET<//>
        <${Link} to="/components" class="crumb">COMPONENTS →<//>
        ${filterProject ? html`
          <span class="pill">
            ${filterProject}
            <button class="btn btn--sm" style="margin-left:4px;min-height:auto;padding:1px 6px"
              title="show every project" onClick=${() => navigate('/alerts')}>CLEAR</button>
          </span>` : null}
        <span style="font-size:var(--fs-sm);color:var(--faint)">
          ${filterProject
            ? `filtered to ${filterProject} · counts below are for this project only`
            : `assembled per project · ${projects.length} project${projects.length === 1 ? '' : 's'} polled`}
        </span>
      </div>

      <div class="stats">
        <${Stat} label="OPEN NOW" value=${all.data ? open.length : '…'} tone=${open.length ? 'warn' : null}/>
        <${Stat} label="RAISED 24H" value=${all.data ? last24h.length : '…'}/>
        <${Stat} label="RESOLVED 24H" value=${all.data ? resolved24h.length : '…'}/>
        <${Stat} label="PROJECTS AFFECTED"
          value=${all.data ? new Set(open.map((a) => a.project)).size : '…'}/>
        <${Stat} label="OLDEST OPEN"
          value=${all.data && open.length
            ? agoFromMinutes(Math.max(...open.map((a) => minutesSince(a.ts) || 0)))
            : '—'} tone="sm"/>
      </div>

      ${msg ? html`
        <div class=${msg.ok ? 'banner banner--warn' : 'banner'}
          style=${msg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${msg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => setMsg(null)}>DISMISS</button>
        </div>` : null}

      ${unreadable.length ? html`
        <div class="banner banner--warn">
          <span>could not read alerts for <b>${unreadable.map((u) => u.project).join(', ')}</b> —
            the counts above exclude ${unreadable.length === 1 ? 'it' : 'them'}.</span>
        </div>` : null}

      <${Section} title="OPEN ALERTS">
        ${all.loading && !all.data
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : all.error && !all.data
            ? html`<${ErrorBox} error=${all.error} onRetry=${all.reload}/>`
            : html`<${SortableTable} columns=${columns} rows=${open}
                rowKey=${(r) => `${r.project}:${r.id}`}
                rowClass=${() => 'row--warn'}
                defaultSort="ts" defaultDir="asc"
                empty=${html`<${Empty} title="nothing open"
                  note="No project is holding an unresolved alert right now." />`} />`}
      <//>

      <${FleetRowsSection} loading=${fleetRows.loading} error=${fleetRows.error}
        onRetry=${fleetRows.reload} shaped=${shapedFleet} nowMs=${nowMs}
        filters=${{ family: filterFamily, box: filterBox, state: filterState, component: filterComponent }}
        actions=${{
          onAction, pending: pendingRow, openId,
          onToggleHistory: (id) => setOpenId((o) => (o === id ? null : id)),
          history: { ...history, shaped: history.data ? shapeAlertActions(history.data) : null }
        }}/>

      ${confirmNode}
      ${noteFor ? html`
        <${Modal} title=${`NOTE ON ${noteFor.id}`} confirmLabel="ADD NOTE" confirmBlocked=${true}
          body=${({ setBlocked }) => html`
            <${NoteDialogBody} setBlocked=${setBlocked} onText=${(t) => { noteText.current = t; }}/>`}
          onConfirm=${() => { const row = noteFor; setNoteFor(null); runAction(row, 'note', noteText.current.trim()); }}
          onCancel=${() => setNoteFor(null)}/>` : null}

      ${resolved24h.length ? html`
        <${Section} title="RESOLVED · 24H" note=${`${resolved24h.length} closed`}>
          <${SortableTable} columns=${resolvedColumns(nowMs)}
            rows=${resolved24h}
            rowKey=${(a) => `${a.project}:${a.id}`}
            defaultSort="ts" defaultDir="desc" />
        <//>` : null}
    </div>`;
}

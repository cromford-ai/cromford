import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import { whenLabel } from '../lib/format.js';
import { FLEET_ROWS_LIMIT, FLEET_ROWS_DEFAULT_STATE } from '../lib/alertrows.js';
import {
  componentNames, shapeComponentRow, countLabel, countSortValue, componentAlertsHref
} from '../lib/components.js';

// The worker's own caps: GET /api/alerts clamps at 500, the decisions read at 200.
const OPEN_LIMIT = 500;
const DECISIONS_LIMIT = 200;

const na = (title) => html`<span class="na" title=${title || undefined}>—</span>`;
const msgOf = (e) => (e && e.message ? e.message : String(e));
const ms = (iso) => {
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
};

export const COMPONENTS_LEGEND = [
  { term: 'OPEN', text: 'alerts of this component that are not resolved; click to see them' },
  { term: 'LAST RUN', text: 'the newest decision the component watcher recorded for this component' },
  { term: 'DECISIONS 24H', text: 'decisions the watcher recorded in the last 24 hours; "200+" means the read was cut' },
  { term: 'TICKETS', text: 'decisions that filed a ticket; a "+" means the read was cut and there can be more' }
];

export const componentColumns = (nowMs) => [
  {
    key: 'name', label: 'COMPONENT', sort: (r) => r.name,
    cell: (r) => html`<${Link} to=${componentAlertsHref(r.name)} class="cell-name">${r.name}<//>`
  },
  {
    key: 'open', label: 'OPEN', align: 'right', sort: (r) => countSortValue(r.open, r.openTruncated),
    cell: (r) => (r.open === null
      ? na(r.alertsError)
      : html`<${Link} to=${componentAlertsHref(r.name)}>${countLabel(r.open, r.openTruncated)}<//>`)
  },
  {
    key: 'last_run', label: 'LAST RUN', align: 'right', sort: (r) => ms(r.lastRunAt),
    cell: (r) => (r.decisionsError
      ? na(r.decisionsError)
      : r.lastRunAt
        ? html`<span title=${r.lastRunAt}>${whenLabel(r.lastRunAt, nowMs)}</span>`
        : na('no decision recorded'))
  },
  {
    key: 'decisions24h', label: 'DECISIONS 24H', align: 'right',
    sort: (r) => countSortValue(r.decisions24h, r.decisions24hMore),
    cell: (r) => (r.decisions24h === null ? na(r.decisionsError) : countLabel(r.decisions24h, r.decisions24hMore))
  },
  {
    key: 'tickets', label: 'TICKETS', align: 'right', sort: (r) => countSortValue(r.tickets, r.ticketsMore),
    cell: (r) => (r.tickets === null ? na(r.decisionsError) : countLabel(r.tickets, r.ticketsMore))
  }
];

// `data` is { names: componentNames(...), components: [{ name, alerts?, decisions?,
// alertsError?, decisionsError? }] }, what ComponentsScreen's reads return.
export function ComponentsView({ data, loading, error, onRetry, nowMs }) {
  const names = data ? data.names : null;
  const rows = data
    ? data.components.map((c) => shapeComponentRow(c.name, c.alerts, c.decisions, nowMs,
      { alertsError: c.alertsError, decisionsError: c.decisionsError }))
    : [];
  const line1 = data
    ? `${rows.length} ${rows.length === 1 ? 'component holds' : 'components hold'} open alerts.`
    : error ? 'The components read failed.' : 'Reading the components.';
  const notes = names ? [
    names.unstamped ? `${names.unstamped} ${names.unstamped === 1 ? 'alert has' : 'alerts have'} no component yet.` : null,
    names.truncated ? `Built from the newest ${OPEN_LIMIT} open alerts; a component past them has no row.` : null
  ].filter(Boolean) : [];

  return html`
    <div class="page">
      <${PageHeadline} chip="Components" line1=${line1}
        line2=${data ? 'Open alerts and watcher decisions per component.' : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/alerts" class="crumb">← ALERTS<//>
        ${onRetry ? html`<button type="button" class="btn btn--sm" onClick=${onRetry}
          disabled=${Boolean(loading)}>REFRESH</button>` : null}
      </div>
      <${Section} title="COMPONENTS" note=${data ? `${rows.length} row${rows.length === 1 ? '' : 's'}` : null}>
        ${!data && loading
          ? html`<${Skeleton} rows=${6} height=${20}/>`
          : !data && error
            ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`
            : !data
              ? html`<${Skeleton} rows=${6} height=${20}/>`
              : html`<${SortableTable} columns=${componentColumns(nowMs)} rows=${rows}
                  rowKey=${(r) => r.name} defaultSort="open" defaultDir="desc"
                  empty=${html`<${Empty} title="no component holds an open alert"
                    note="Every unresolved alert is either unstamped or there are none." />`}/>
                ${notes.map((n) => html`<p class="section__note" key=${n}>${n}</p>`)}
                ${rows.length ? html`<${Legend} items=${COMPONENTS_LEGEND}/>` : null}`}
      <//>
    </div>`;
}

// Wave 1 finds the names; wave 2 reads every component's alerts and decisions
// in ONE Promise.all. A failed per-component read marks that row, never the
// whole screen (the AlertsScreen per-project pattern).
export function ComponentsScreen() {
  const res = useApi(async () => {
    const names = componentNames(await api.alerts({ state: FLEET_ROWS_DEFAULT_STATE, limit: FLEET_ROWS_LIMIT }));
    const components = await Promise.all(names.names.map(async (name) => {
      const [alerts, decisions] = await Promise.all([
        api.alerts({ component: name, state: FLEET_ROWS_DEFAULT_STATE, limit: OPEN_LIMIT })
          .then((d) => ({ d }), (e) => ({ e: msgOf(e) })),
        api.alertDecisions({ component: name, limit: DECISIONS_LIMIT })
          .then((d) => ({ d }), (e) => ({ e: msgOf(e) }))
      ]);
      return { name, alerts: alerts.d, alertsError: alerts.e, decisions: decisions.d, decisionsError: decisions.e };
    }));
    return { names, components };
  }, []);
  // One clock read per render, so every age on the table is measured from it.
  return html`<${ComponentsView} data=${res.data} loading=${res.loading} error=${res.error}
    onRetry=${res.reload} nowMs=${Date.now()}/>`;
}

const decisionColumns = (nowMs) => [
  { key: 'at', label: 'AT', align: 'right', sort: (d) => ms(d.at),
    cell: (d) => html`<span title=${d.at}>${whenLabel(d.at, nowMs)}</span>` },
  { key: 'verdict', label: 'VERDICT', sort: (d) => d.verdict, cell: (d) => html`<span class="tag">${d.verdict}</span>` },
  { key: 'outcome', label: 'OUTCOME', sort: (d) => d.outcome, cell: (d) => d.outcome || na() },
  { key: 'issue', label: 'ISSUE', align: 'right', sort: (d) => d.issue,
    cell: (d) => (d.issue === null || d.issue === undefined
      ? na()
      : html`<${Link} to=${`/t/BH-${d.issue}`} class="cell-name">BH-${d.issue}<//>`) },
  { key: 'run_id', label: 'RUN', sort: (d) => d.run_id, cell: (d) => d.run_id || na() },
  { key: 'reason', label: 'REASON', sort: null,
    cell: (d) => html`<span class="cell-wrap" title=${d.reason}>${d.reason}</span>` }
];

export function AlertDecisionsView({ id, data, loading, error, onRetry, nowMs }) {
  const rows = data && Array.isArray(data.decisions) ? data.decisions : [];
  const component = rows.length && rows[0].component ? rows[0].component : null;
  const line1 = data
    ? `${rows.length} ${rows.length === 1 ? 'decision' : 'decisions'} on this alert.`
    : error ? 'The decisions read failed.' : 'Reading the decisions.';
  return html`
    <div class="page">
      <${PageHeadline} chip=${`Decisions · ${id}`} line1=${line1}
        line2=${data ? 'What the component watcher decided, newest first.' : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/alerts" class="crumb">← ALERTS<//>
        ${component ? html`<${Link} to=${componentAlertsHref(component)} class="crumb">← ${component}<//>` : null}
      </div>
      <${Section} title="DECISIONS" note=${data && data.truncated ? `showing the newest ${DECISIONS_LIMIT}` : null}>
        ${!data && loading
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : !data && error
            ? html`<${ErrorBox} error=${error} onRetry=${onRetry}/>`
            : !data
              ? html`<${Skeleton} rows=${4} height=${20}/>`
              : html`<${SortableTable} columns=${decisionColumns(nowMs)} rows=${rows}
                  rowKey=${(d) => d.id} defaultSort="at" defaultDir="desc"
                  empty=${html`<${Empty} title="no decisions recorded"
                    note="The component watcher has not decided on this alert yet." />`}/>`}
      <//>
    </div>`;
}

export function AlertDecisionsScreen({ id }) {
  const res = useApi(() => api.alertDecisions({ alert_id: id, limit: DECISIONS_LIMIT }), [id]);
  return html`<${AlertDecisionsView} id=${id} data=${res.data} loading=${res.loading} error=${res.error}
    onRetry=${res.reload} nowMs=${Date.now()}/>`;
}

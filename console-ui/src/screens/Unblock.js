import { useState } from 'preact/hooks';
import { html, Link, useSearchParam } from '../router.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { fleetProjects } from '../lib/kanban.js';
import { PageHeadline } from '../ui/line.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { unblockMetrics, unblockDecisions, isNotLive, UNBLOCK_DAYS } from '../lib/unblock-api.js';

// TACKLER (BH-7728, UNB-6): what the Tackler decided over the last 7 days, per
// project. Two reads through the coord proxy, started together: the metrics
// (tiles + one row per day) and one page of the decision ledger (50 rows,
// newest first; OLDER pages by before_id). Before the UNB-0 table is applied
// the worker answers 503 "unblock_decisions schema not applied", and the
// screen says the ledger is not live yet instead of showing an error.

export const DEFAULT_PROJECT = 'cromford';
export const NOT_LIVE_COPY = 'Tackler ledger is not live yet';
const NO_ROWS_COPY = 'no decisions in this window';

const na = (why) => html`<span class="na" title=${why || ''}>n/a</span>`;
const isNum = (v) => v !== null && v !== undefined && Number.isFinite(Number(v));
const numText = (v) => (isNum(v) ? String(Number(v)) : 'n/a');
const numCell = (v, why) => (isNum(v) ? Number(v) : na(why));
const textCell = (v, why) => (v === null || v === undefined || v === '' ? na(why) : v);

// 0.0952 -> "9.5"; null stays null.
export function percent(rate) {
  if (!isNum(rate)) return null;
  return String(Math.round(Number(rate) * 1000) / 10);
}

// "2026-10-19T10:00:00Z" -> "2026-10-19 10:00Z": a fixed format, no clock read.
const stamp = (iso) => (iso ? html`<span title=${iso}>${String(iso).slice(0, 16).replace('T', ' ')}Z</span>` : na('not recorded'));

// The subject drills to its own screen: a PR to /pr/<project>/<n> (parsed from
// "owner/repo#n"), a box to /machines?box=<name> ("box:<name>"). Every other
// kind has no screen of its own and renders as text with its kind.
export function subjectHref(row) {
  const s = String(row.subject || '');
  if (row.subject_kind === 'pr') {
    const m = /#(\d+)$/.exec(s);
    return m ? `/pr/${encodeURIComponent(row.project)}/${m[1]}` : null;
  }
  if (row.subject_kind === 'box' && s.startsWith('box:') && s.length > 4) {
    return `/machines?box=${encodeURIComponent(s.slice(4))}`;
  }
  return null;
}
function subjectCell(row) {
  const to = subjectHref(row);
  if (to) return html`<${Link} to=${to} class="cell-name">${row.subject}<//>`;
  return html`<span><span class="tag">${row.subject_kind || 'unknown'}</span> ${textCell(row.subject, 'no subject')}</span>`;
}

export const TREND_COLUMNS = [
  { key: 'day', label: 'DAY', sort: (r) => r.day, cell: (r) => r.day },
  { key: 'decisions', label: 'DECISIONS', align: 'right', sort: (r) => r.decisions, cell: (r) => numCell(r.decisions) },
  { key: 'would', label: 'WOULD', align: 'right', sort: (r) => r.would, cell: (r) => numCell(r.would) },
  { key: 'escalations', label: 'ESCALATIONS', align: 'right', sort: (r) => r.escalations, cell: (r) => numCell(r.escalations) },
  { key: 'overrides', label: 'OVERRIDES', align: 'right', sort: (r) => r.overrides, cell: (r) => numCell(r.overrides) },
  { key: 'stall_median', label: 'STALL MEDIAN', unit: 'min', align: 'right', sort: (r) => r.stall_median_min, cell: (r) => numCell(r.stall_median_min, 'no stall sample') },
  { key: 'stall_p95', label: 'STALL P95', unit: 'min', align: 'right', sort: (r) => r.stall_p95_min, cell: (r) => numCell(r.stall_p95_min, 'no stall sample') },
];

export function ledgerColumns(openId, onToggle) {
  return [
    {
      key: 'id', label: 'ID', align: 'right', sort: (r) => r.id,
      cell: (r) => html`<button type="button" class="btn btn--sm" aria-expanded=${openId === r.id ? 'true' : 'false'}
        aria-controls=${`unblock-${r.id}`} title="show the evidence" onClick=${() => onToggle(r.id)}>${r.id}</button>`
    },
    { key: 'created', label: 'CREATED', sort: (r) => r.created_at, cell: (r) => stamp(r.created_at) },
    { key: 'subject', label: 'SUBJECT', sort: (r) => r.subject, cell: subjectCell },
    { key: 'rule', label: 'RULE', sort: (r) => r.rule_id, cell: (r) => textCell(r.rule_id, 'no rule') },
    { key: 'cites', label: 'CITES', sort: (r) => r.rule_cites, cell: (r) => textCell(r.rule_cites, 'no cites') },
    { key: 'decision', label: 'DECISION', sort: (r) => r.decision, cell: (r) => textCell(r.decision) },
    { key: 'action', label: 'ACTION', sort: (r) => r.action, cell: (r) => textCell(r.action, 'no action') },
    { key: 'mode', label: 'MODE', sort: (r) => r.mode, cell: (r) => textCell(r.mode) },
    { key: 'outcome', label: 'OUTCOME', sort: (r) => r.outcome, cell: (r) => textCell(r.outcome, 'no outcome yet') },
    {
      key: 'override', label: 'OVERRIDE', sort: (r) => r.override_by,
      cell: (r) => (r.override_by ? html`<span title=${r.override_at || ''}>${r.override_by}</span>` : na('no override'))
    },
  ];
}

// The evidence is a JSON string (cut at 2 KB by the worker). Pretty-print it
// when it parses; show it as it is when it does not.
function evidenceText(raw) {
  if (raw === null || raw === undefined || raw === '') return null;
  try { return JSON.stringify(JSON.parse(raw), null, 2); } catch { return String(raw); }
}
const pre = (text) => html`<pre style="white-space:pre-wrap;overflow-wrap:anywhere;margin:4px 0 8px">${text}</pre>`;
function expandBody(r) {
  const ev = evidenceText(r.evidence);
  return html`
    <div style="min-width:0">
      <div class="section__note">EVIDENCE${r.evidence_truncated ? ' (cut at 2 KB)' : ''}</div>
      ${ev ? pre(ev) : html`<div>${na('no evidence')}</div>`}
      <div class="section__note">OUTCOME DETAIL</div>
      ${r.outcome_detail ? pre(r.outcome_detail) : html`<div>${na('no outcome detail')}</div>`}
      <div class="section__note">OVERRIDE DETAIL</div>
      ${r.override_detail ? pre(r.override_detail) : html`<div>${na('no override')}</div>`}
    </div>`;
}

const loading = () => html`<div data-testid="unblock-loading"><${Skeleton} rows=${4} height=${20}/></div>`;

function Tiles({ totals }) {
  const t = totals || {};
  const pct = percent(t.override_rate);
  const tiles = [
    { label: 'STALL MEDIAN / P95', value: `${numText(t.stall_median_min)} / ${numText(t.stall_p95_min)}`, unit: 'min' },
    { label: 'DECISIONS / DAY', value: numText(t.decisions_per_day) },
    { label: 'ESCALATIONS / DAY', value: numText(t.escalations_per_day) },
    { label: 'OVERRIDE RATE', value: pct === null ? 'n/a' : pct, unit: pct === null ? null : '%' },
  ];
  return html`
    <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px">
      ${tiles.map((it) => html`
        <div key=${it.label} data-testid="unblock-tile" style="flex:1 1 160px;min-width:0;display:flex;flex-direction:column">
          <${Stat} label=${it.label} value=${it.value} unit=${it.unit}/>
        </div>`)}
    </div>`;
}

function MetricsBody({ state }) {
  const d = state.data;
  if (!d) return state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : loading();
  const daily = Array.isArray(d.daily) ? d.daily : [];
  const t = d.totals || {};
  return html`
    ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
    <${Tiles} totals=${t}/>
    <div class="footnote" style="margin-bottom:10px">
      <span class="tag">stall unknown ${numText(t.stall_unknown)}</span>
      <span class="tag">cards expired ${numText(d.expired_cards)}</span>
      <span class="tag">uncovered ${numText(d.uncovered)}</span>
      ${d.truncated ? html`<span class="tag tag--warn">window capped: totals cover the newest rows only</span>` : null}
    </div>
    <div data-testid="unblock-trend">
      <${SortableTable} columns=${TREND_COLUMNS} rows=${daily} rowKey=${(r) => r.day}
        defaultSort="day" defaultDir="desc" empty=${html`<${Empty} title="no days in this window"/>`}/>
    </div>`;
}

// OLDER shows when the worker says there is an older page (next_before_id not
// null), or, when the field is absent, when the page is full. It pages from
// next_before_id, else from the id of the last row the worker sent.
export function olderCursor(d) {
  const rows = d && Array.isArray(d.decisions) ? d.decisions : [];
  if (d && Object.prototype.hasOwnProperty.call(d, 'next_before_id')) {
    return d.next_before_id === null || d.next_before_id === undefined ? null : d.next_before_id;
  }
  const limit = d && isNum(d.limit) ? Number(d.limit) : 50;
  return rows.length && rows.length >= limit ? rows[rows.length - 1].id : null;
}

function LedgerBody({ state, before, onOlder, onNewest, openId, onToggle }) {
  const d = state.data;
  if (!d) return state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : loading();
  const rows = Array.isArray(d.decisions) ? d.decisions : [];
  const cursor = olderCursor(d);
  return html`
    ${state.error ? html`<${ErrorBox} error=${state.error} onRetry=${state.reload}/>` : null}
    <${SortableTable} wide columns=${ledgerColumns(openId, onToggle)} rows=${rows} rowKey=${(r) => r.id}
      defaultSort="id" defaultDir="desc"
      expand=${(r) => (r.id === openId ? { id: `unblock-${r.id}`, body: expandBody(r) } : null)}
      empty=${html`<${Empty} title=${NO_ROWS_COPY}/>`}/>
    ${before || cursor !== null ? html`
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:8px">
        ${before ? html`<button type="button" class="btn btn--sm" onClick=${onNewest}>NEWEST</button>` : null}
        ${cursor !== null ? html`<button type="button" class="btn btn--sm" onClick=${() => onOlder(cursor)}>OLDER</button>` : null}
      </div>` : null}`;
}

export function UnblockView({ project, projects, metrics, decisions, before, onOlder, onNewest, openId, onToggle }) {
  const picker = html`
    <div class="tabs" style="margin-bottom:12px">
      ${projects.map((p) => html`<${Link} key=${p} to=${`/unblock?project=${encodeURIComponent(p)}`}
        class=${p === project ? 'tab tab--on' : 'tab'}>${p}<//>`)}
    </div>`;
  const head = html`<${PageHeadline} chip="STAFF"
    line1=${`TACKLER · ${project}`}
    line2=${`What the Tackler decided in the last ${UNBLOCK_DAYS} days, and what a person overrode.`}/>`;
  if (isNotLive(metrics.error) || isNotLive(decisions.error)) {
    return html`${head}${picker}<${Empty} title=${NOT_LIVE_COPY}
      note="The jobs worker has no unblock_decisions table yet. It is applied by UNB-0."/>`;
  }
  return html`
    ${head}
    ${picker}
    <${Section} title=${`LAST ${UNBLOCK_DAYS} DAYS`} note="stall is minutes from the stall to the Tackler's decision">
      <${MetricsBody} state=${metrics}/>
    <//>
    <${Section} title="LEDGER" note="newest first, 50 per page; an ID opens its evidence">
      <div data-testid="unblock-ledger">
        <${LedgerBody} state=${decisions} before=${before} onOlder=${onOlder} onNewest=${onNewest}
          openId=${openId} onToggle=${onToggle}/>
      </div>
    <//>`;
}

export function UnblockScreen() {
  const fleet = useFleet();
  const asked = useSearchParam('project');
  const project = asked || DEFAULT_PROJECT;
  // The page cursor belongs to one project: a switch starts at the newest page.
  const [page, setPage] = useState({ project, before: null });
  const before = page.project === project ? page.before : null;
  const [openId, setOpenId] = useState(null);
  // Two hooks in one render: both effects run in the same commit, so the two
  // reads start together and neither waits on the other.
  const metrics = useApi(() => unblockMetrics(project, UNBLOCK_DAYS), [project]);
  const decisions = useApi(() => unblockDecisions(project, before === null ? undefined : before), [project, before]);
  const listed = fleetProjects(fleet && fleet.data && fleet.data.projects);
  const projects = [...new Set([DEFAULT_PROJECT, ...listed, project])];
  return html`<${UnblockView} project=${project} projects=${projects} metrics=${metrics} decisions=${decisions}
    before=${before}
    onOlder=${(id) => { setOpenId(null); setPage({ project, before: id }); }}
    onNewest=${() => { setOpenId(null); setPage({ project, before: null }); }}
    openId=${openId} onToggle=${(id) => setOpenId((cur) => (cur === id ? null : id))}/>`;
}

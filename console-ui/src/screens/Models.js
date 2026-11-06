import { useState, useCallback, useEffect, useMemo } from 'preact/hooks';
import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useFleet } from '../app.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, Legend } from '../ui/primitives.js';
import { UsdCell } from '../ui/UsdCell.js';
import { fmtUsd, clockTime, whenLabel } from '../lib/format.js';
import { fleetProjects } from '../lib/kanban.js';
import { isHub } from '../lib/settings.js';
import {
  spendPlan, spendSince, modelRows, pricedModels, perMillion, changeRows,
  gapRows, makeModelActions, isDirect, isStageRole, screenCoverage, unroutedRows, priceRows,
  SPEND_DAYS, KEEP_SEED_LABEL
} from '../lib/models.js';

// MODELS (BH-1510.3) — every role the harness runs a model for, as the
// model_routes table has it: the primary, the failover ladder, the runner, the
// price, and what that role spent in the last week. The "control the pathway"
// surface from #1510: a role's model is a row here, changed here, audited here.
//
// Hub tab = the defaults; a project tab = what that project actually resolves
// (its own override, or the hub default it falls back to). Precedence is per
// ROLE: a project owns its whole ladder for a role or none of it.

const ROUTES_REFRESH_MS = 60000;

function useTabs(activeTab) {
  const fleet = useFleet();
  const projects = fleetProjects(fleet && fleet.data && fleet.data.projects);
  const ids = ['hub'].concat(projects);
  if (activeTab && !ids.includes(activeTab)) ids.push(activeTab);
  return ids.map((id) => ({ id, label: id === 'hub' ? 'HUB' : id }));
}

// One llm-spend SUM per distinct (stage|runner, project) the roles map onto.
// A failed read is recorded per key, so one bad stage blanks one cell, not the
// table.
async function fetchSpend(roles, project) {
  const plan = spendPlan(roles, project);
  const since = spendSince(Date.now());
  const pairs = await Promise.all(plan.queries.map(async (q) => {
    try {
      return [q.key, await api.llmSpend({ ...q.params, since })];
    } catch (e) {
      return [q.key, { error: String((e && e.message) || e) }];
    }
  }));
  return { plan, spend: Object.fromEntries(pairs) };
}

export function ModelsScreen() {
  const tabParam = useSearchParam('project');
  const tab = tabParam || 'hub';
  const project = isHub(tab) ? null : tab;
  const tabs = useTabs(tab);

  // The same 7-day window the spend columns use (BH-2512's UNROUTED STAGES).
  const routes = useApi(() => api.modelRoutes(project, spendSince(Date.now())), [project], { intervalMs: ROUTES_REFRESH_MS });
  const prices = useApi(() => api.modelPrices(), []);
  const roles = ((routes.data && routes.data.roles) || []).map((r) => r.role);
  const spend = useApi(() => fetchSpend(roles, project), [project, roles.join(',')]);

  const onTab = useCallback((next) => {
    navigate(next === 'hub' ? '/models' : `/models?project=${encodeURIComponent(next)}`);
  }, []);

  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [note, setNote] = useState(null);
  const actions = useMemo(() => makeModelActions({
    confirm: (opts) => confirm({ title: opts.title, body: html`<p style="margin:0">${opts.note}</p>`, confirmLabel: opts.confirmLabel, tone: opts.tone }),
    writePriceSource: (body) => api.setModelPriceSource(body),
    refresh: prices.reload,
    onNote: setNote
  }), [confirm, prices.reload]);
  const onPriceSource = useCallback(async (p) => {
    setBusy(p.model);
    try { await actions.setPriceSource({ model: p.model, direct: p.direct }); } finally { setBusy(null); }
  }, [actions]);

  if (routes.loading && !routes.data) return html`<div class="page"><${PageHeadline} chip="Models" line1="Reading the model routes." line2=""/><${Skeleton} rows=${10} height=${22}/></div>`;

  const plan = (spend.data && spend.data.plan) || spendPlan(roles, project);
  // A role's own `live` field, when the route sends one, rides onto its row (stageLiveNote).
  const live = new Map(((routes.data && routes.data.roles) || []).map((r) => [r.role, r.live]));
  const rows = modelRows({
    routes: routes.data, prices: prices.data, spend: spend.data && spend.data.spend, plan, project
  }).map((r) => (live.get(r.role) === undefined ? r : { ...r, live: live.get(r.role) }));
  return html`<${ModelsView} tabs=${tabs} activeTab=${tab} rows=${rows} coverage=${screenCoverage(rows)}
    gaps=${gapRows(routes.data)}
    unrouted=${unroutedRows(routes.data, project)} unroutedError=${routes.data && routes.data.unrouted_error}
    unroutedTruncated=${Boolean(routes.data && routes.data.unrouted_truncated)}
    prices=${prices.data ? priceRows(prices.data) : undefined} onPriceSource=${onPriceSource}
    dialog=${dialog} busy=${busy} note=${note} onDismissNote=${() => setNote(null)}
    error=${routes.error || prices.error} loading=${routes.loading || spend.loading}
    asOf=${routes.data && routes.data.as_of} onTab=${onTab}
    onReload=${() => { routes.reload(); prices.reload(); spend.reload(); }} />`;
}

// ───────────────────────────────────────────────────────── render half

const dash = html`<span class="na">—</span>`;
const rate = (v) => (v === null || v === undefined ? '—' : v < 1 ? fmtUsd(v, { decimals: 3 }) : fmtUsd(v));
const fmtRate = (v) => (v === null || v === undefined ? dash : html`<span class="num" data-usd-basis="api">${rate(v)}</span>`);

// BH-3570: what the column names mean, said under the table instead of in a title=.
const MODEL_LEGEND = [
  { term: 'PRIMARY', text: 'the model a role calls first.' },
  { term: 'FAILOVER', text: 'the models tried next, in order, when the one before is rate limited or down.' },
  { term: 'RUNNER', text: 'the CLI that makes the call: claude, codex, grok, ...' },
  { term: 'SCOPE', text: 'HUB DEFAULT: every project uses it. PROJECT OVERRIDE: this project has its own ladder for the role.' },
  { term: 'RUNG', text: 'a step on the ladder; RUNG 0 is the primary, higher rungs are failovers.' },
  { term: 'RC 75', text: 'rate limited, the failover took the call; with no ladder at all the caller stops with 75 and alerts.' },
  { term: '$/1M IN / OUT', text: 'list price per million input / output tokens.' }
];

// BH-3570 (D5): say only what the route read backs up. No live field on the
// rows means the console cannot tell whether agent-call uses them.
export function stageLiveNote(rows) {
  if (rows.length && rows.every((r) => r.live === true)) return "Live: agent-call picks each build stage's runner from these rows.";
  if (rows.some((r) => r.live === false)) return 'Not live: agent-call does not read these rows yet.';
  return 'Not confirmed live: the route read does not say whether agent-call uses these rows.';
}

// BH-1613: shown only when the row's price_source is 'vendor-direct'.
const DirectTag = () => html`<span class="tag" style="white-space:nowrap"
  title="marked vendor-direct: the daily refresh prices it from its catalog/model-prices.json row, not OpenRouter (a model with no catalog row stays on OpenRouter and the refresh logs that)">DIRECT</span>`;
const GapTag = () => html`<span class="tag tag--warn" style="white-space:nowrap"
  title="rows exist for this scope but none at rung 0, so the resolver ignores them">GAPPED</span> `;

const ScopeTag = ({ source, gapped }) => html`${gapped ? html`<${GapTag}/>` : null}${source === 'project'
  ? html`<span class="tag tag--warn" style="white-space:nowrap" title="this project carries its own ladder for this role">PROJECT OVERRIDE</span>`
  : source === 'hub'
    ? html`<span class="tag tag--idle" style="white-space:nowrap" title="the hub default">HUB DEFAULT</span>`
    : html`<span class="tag">NO ROUTE</span>`}`;

// On BOTH spend columns since BH-1563, so `tag--sm`: two of these in one row at
// the full chip size push the roles table past 1280px.
const AttributionTag = ({ attribution }) => (attribution.kind === 'shared' || attribution.kind === 'partial'
  ? html` <span class="tag tag--sm" style="white-space:nowrap" title=${attribution.note}>${attribution.kind.toUpperCase()}</span>`
  : null);

function SpendCell({ row, field }) {
  if (row.spend_error) return html`<span class="na" title=${`spend read failed: ${row.spend_error}`}>?</span>`;
  const v = row[field];
  if (v === null || v === undefined) return html`<span class="na" title=${row.attribution.note}>—</span>`;
  if (field === 'usd_7d') return html`<span title=${row.attribution.note}><${UsdCell} value=${v} basis="api"/></span>`;
  return html`<span class="num" title=${row.attribution.note}>${v}</span>`;
}

export function ModelsView({
  tabs, activeTab, rows, coverage: cov, gaps, error, loading, asOf, onTab, onReload,
  unrouted, unroutedError, unroutedTruncated, prices, onPriceSource, dialog, busy, note, onDismissNote
}) {
  const seeded = rows.filter((r) => r.seed).length;
  const gapped = gaps || [];
  const stageRows = rows.filter((r) => isStageRole(r.role));
  const roleRows = rows.filter((r) => !isStageRole(r.role));
  return html`
    <div class="page">
      ${dialog || null}
      <${PageHeadline} chip="MODELS" line1=${`${rows.length} ${rows.length === 1 ? 'role' : 'roles'} on a model ladder.`}
        line2=${`${stageRows.length} pipeline ${stageRows.length === 1 ? 'stage' : 'stages'}, ${roleRows.length} other ${roleRows.length === 1 ? 'role' : 'roles'}.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span class="section__note">every role, its model ladder, its price and its last ${SPEND_DAYS} days</span>
        <button class="btn btn--sm" style="margin-left:auto" onClick=${onReload}>${loading ? 'REFRESHING…' : 'REFRESH'}</button>
      </div>

      ${error ? html`
        <div class="banner">
          <span><b>could not reach the model-routes API — ${String(error.message || error)}.</b>
            ${rows.length ? ' Everything below is the last state that loaded, not live.' : ' Nothing has loaded yet in this session.'}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onReload}>RETRY</button>
        </div>` : null}

      ${note ? html`<${NoteBanner} note=${note} onDismiss=${onDismissNote}/>` : null}

      ${seeded ? html`
        <div class="banner banner--warn">
          <span><b>${seeded} ${seeded === 1 ? 'role carries' : 'roles carry'} a rung still on its #1510.0 seed value</b>${' '}
            (tagged SEED): nobody has decided that rung since the seed copied the code default of 2026-09-22,
            and some of those defaults have since moved in code (#1507). Open the role and either change the
            model and save, or press ${KEEP_SEED_LABEL} to record the seed as reviewed. Nothing here changes on
            its own.</span>
        </div>` : null}

      ${gapped.length ? html`
        <div class="banner banner--warn">
          <span><b>${gapped.length} ${gapped.length === 1 ? 'scope carries' : 'scopes carry'} a ladder with no rung 0</b>${' '}
            (a half-written ladder from before #1560). They are ignored by every resolver: a project one falls back
            to the hub, a hub one is no route at all. Open each and press RESET TO HUB (a project scope) or
            SAVE LADDER (either) to repair it.
            <ul style="margin:6px 0 0;padding-left:18px">
              ${gapped.map((g) => html`<li key=${`${g.project || 'hub'}/${g.role}`}>
                <${Link} to=${g.href} class="cell-name">${g.label}<//></li>`)}
            </ul>
          </span>
        </div>` : null}

      <div class="tabs" style="margin:4px 0 12px" role="tablist">
        ${tabs.map((t) => html`
          <button key=${t.id} type="button" role="tab"
            aria-selected=${t.id === activeTab ? 'true' : 'false'}
            class=${t.id === activeTab ? 'tab tab--on' : 'tab'}
            onClick=${() => onTab(t.id)}>${t.label}</button>`)}
      </div>

      <${Section} title=${activeTab === 'hub' ? 'HUB DEFAULTS' : `${activeTab.toUpperCase()} — RESOLVED`}
        note=${asOf ? `as of ${clockTime(asOf)}` : 'no live read yet'}>
        ${error && !rows.length ? null : html`<${ModelTable} rows=${roleRows}/>`}
        <${Legend} items=${MODEL_LEGEND}/>
      <//>

      ${stageRows.length ? html`
        <${Section} title="STAGE RUNNERS"
          note=${`which runner each build stage uses, and its fallback. ${stageLiveNote(stageRows)}`}>
          <${SortableTable} rows=${stageRows} rowKey=${(r) => r.role} defaultSort="role" columns=${stageRunnerColumns}/>
        <//>` : null}

      ${unrouted !== undefined ? html`<${UnroutedSection} rows=${unrouted} error=${unroutedError} truncated=${unroutedTruncated}/>` : null}

      ${prices && activeTab === 'hub' ? html`
        <${Section} title="MODEL PRICES"
          note="per model, fleet-wide. VENDOR-DIRECT prices a model at the vendor's own rate from the hub's daily 04:30 refresh">
          <${PriceTable} rows=${prices} busy=${busy} onPriceSource=${onPriceSource}/>
        <//>` : null}

      ${rows.length ? html`<${CoverageNote} coverage=${cov}/>` : null}
    </div>`;
}

function NoteBanner({ note, onDismiss }) {
  return html`
    <div class=${note.ok ? 'banner banner--warn' : 'banner'}
      style=${note.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
      <span>${note.text}</span>
      <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismiss}>DISMISS</button>
    </div>`;
}

// BH-2512: stages that ran in the window on no stage.* route. The tag is what
// agent-call does with no route and no RUNNER_<STAGE> env; RAN ON is what the
// ledger actually recorded, because an env override beats the tag.
const DefaultsTag = () => html`<span class="tag tag--warn" style="white-space:nowrap"
  title="no stage.* route: agent-call uses RUNNER_<STAGE> from env if the box sets it, else claude">DEFAULTS TO CLAUDE</span>`;

function UnroutedSection({ rows, error, truncated }) {
  return html`
    <${Section} title="UNROUTED STAGES"
      note=${`stages in the cost ledger in the last ${SPEND_DAYS} days with no stage.* route. agent-call runs them on RUNNER_<STAGE> from env if set, else claude. Open one and save a ladder to route it.`}>
      ${rows === null ? html`
        <div class="banner"><span><b>could not read the cost ledger — ${String(error || 'unknown error')}.</b>
          Whether any stage is unrouted is not known.</span></div>` : html`
        <${SortableTable} rows=${rows} rowKey=${(r) => r.stage} defaultSort="stage"
          empty=${html`<${Empty} title="EVERY STAGE IS ROUTED" note=${`every stage in the last ${SPEND_DAYS} days of the cost ledger has a stage.* route`}/>`}
          columns=${unroutedColumns}/>
        ${truncated ? html`<p class="section__note" style="margin:8px 0 0">showing the first 500 stage/project pairs; there are more.</p>` : null}`}
    <//>`;
}

export const unroutedColumns = [
  {
    key: 'stage', label: 'STAGE', sort: (r) => r.stage,
    cell: (r) => html`${r.href ? html`<${Link} to=${r.href} class="cell-name">${r.stage}<//>`
      : html`<span class="mono" title="not a valid role name, so no stage.* route can hold it">${r.stage}</span>`} <${DefaultsTag}/>`
  },
  { key: 'projects', label: 'PROJECTS', sort: (r) => r.projects.join(', '), cell: (r) => html`<span>${r.projects.map((p) => p || 'none').join(', ')}</span>` },
  { key: 'runners', label: 'RAN ON', sort: (r) => r.runners.join(', '), cell: (r) => (r.runners.length ? html`<span>${r.runners.join(', ')}</span>` : dash) },
  { key: 'calls', label: `CALLS ${SPEND_DAYS}D`, sort: (r) => r.calls, align: 'right', cell: (r) => html`<span class="num">${r.calls}</span>` },
  { key: 'last_seen', label: 'LAST SEEN', sort: (r) => r.last_seen, cell: (r, nowMs = Date.now()) => (r.last_seen ? html`<span title=${r.last_seen}>${whenLabel(r.last_seen, nowMs)}</span>` : dash) }
];

// BH-2512: the price-source override, one button per model.
function PriceTable({ rows, busy, onPriceSource }) {
  return html`
    <${SortableTable} rows=${rows} rowKey=${(p) => p.model} defaultSort="model"
      empty=${html`<${Empty} title="NO PRICES" note="model_prices has no row yet; the hub's daily refresh fills it."/>`}
      columns=${[
        { key: 'model', label: 'MODEL', sort: (p) => p.model, cell: (p) => html`<span class="mono">${p.model}</span>` },
        {
          key: 'price_in', label: '$/1M IN / OUT', sort: (p) => p.price_in, align: 'right',
          cell: (p) => (p.price_in === null ? dash : html`<span class="num" data-usd-basis="api" style="white-space:nowrap">${rate(p.price_in)} / ${rate(p.price_out)}</span>`)
        },
        {
          key: 'direct', label: 'SOURCE', sort: (p) => (p.direct ? 1 : 0),
          cell: (p) => (p.direct ? html`<${DirectTag}/>${p.vendorRates ? html` <span class="tag tag--sm" title="vendor rates stored in the table">RATES SET</span>` : null}` : html`<span>openrouter</span>`)
        },
        {
          key: 'action', label: '', sort: null,
          cell: (p) => html`<button type="button" class=${p.direct ? 'btn btn--sm btn--warn' : 'btn btn--sm'}
            disabled=${busy !== null && busy !== undefined} onClick=${() => onPriceSource && onPriceSource(p)}>
            ${busy === p.model ? '…' : p.direct ? 'USE OPENROUTER' : 'MARK VENDOR-DIRECT'}</button>`
        }
      ]}/>`;
}

function ModelTable({ rows }) {
  return html`
    <${SortableTable} rows=${rows} rowKey=${(r) => r.role} defaultSort="role"
      empty=${html`<${Empty} title="NO ROLES" note="model_routes has no row for any role yet. The #1510.0 seed lands with the schema apply."/>`}
      columns=${[
        {
          key: 'role', label: 'ROLE', sort: (r) => r.role,
          cell: (r) => html`<${Link} to=${r.href} class="cell-name">${r.role}<//>
            ${r.seed ? html` <span class="tag tag--warn" style="white-space:nowrap" title="still the #1510.0 seed value — nobody has decided it">SEED</span>` : null}`
        },
        { key: 'primary', label: 'PRIMARY', sort: (r) => r.primary, cell: (r) => (r.primary ? html`<span class="mono">${r.primary}</span>` : dash) },
        {
          key: 'fallbacks', label: 'FAILOVER', sort: (r) => r.fallbacks.length,
          cell: (r) => (r.fallbacks.length
            ? html`<span class="mono" style="white-space:nowrap">${r.fallbacks.map((f, i) => html`${i ? ', ' : ''}${f.model}${f.runner !== r.runner ? ` (${f.runner})` : ''}`)}</span>`
            : html`<span class="na">none</span>`)
        },
        { key: 'runner', label: 'RUNNER', sort: (r) => r.runner, cell: (r) => (r.runner ? html`<span>${r.runner}</span>` : dash) },
        // In and out share one column, sorted by the input rate: two price
        // columns were what pushed the table past a 1280px desktop.
        {
          key: 'price_in', label: '$/1M IN / OUT', sort: (r) => r.price_in, align: 'right',
          cell: (r) => (r.price_in === null ? dash
            : html`<span class="num" data-usd-basis="api" style="white-space:nowrap">${rate(r.price_in)} / ${rate(r.price_out)}</span>${r.direct ? html` <${DirectTag}/>` : null}`)
        },
        // The SHARED/PARTIAL tag rides on CALLS as well as on $ (BH-1563): a
        // summed calls figure is exactly as double-counted as the dollars.
        {
          key: 'calls_7d', label: 'CALLS 7D', sort: (r) => r.calls_7d, align: 'right',
          cell: (r) => html`<${SpendCell} row=${r} field="calls_7d"/><${AttributionTag} attribution=${r.attribution}/>`
        },
        {
          key: 'usd_7d', label: '$ 7D', sort: (r) => r.usd_7d, align: 'right',
          cell: (r) => html`<${SpendCell} row=${r} field="usd_7d"/><${AttributionTag} attribution=${r.attribution}/>`
        },
        { key: 'source', label: 'SCOPE', sort: (r) => r.source, cell: (r) => html`<${ScopeTag} source=${r.source} gapped=${r.gapped}/>` },
        {
          key: 'history', label: 'HISTORY', sort: null,
          cell: (r) => html`<${Link} to=${`${r.href}#history`} class="cell-name">history<//>`
        }
      ]}/>`;
}

// BH-1766: the stage.* roles. A stage ladder is at most two rungs (the worker
// refuses a third), so the fallback is rung 1's runner.
export const stageRunnerColumns = [
  {
    key: 'role', label: 'STAGE', sort: (r) => r.role,
    cell: (r) => html`<${Link} to=${r.href} class="cell-name">${r.role}<//>
      ${r.seed ? html` <span class="tag tag--warn" style="white-space:nowrap" title="still the seed value — nobody has decided it">SEED</span>` : null}`
  },
  { key: 'runner', label: 'RUNNER', sort: (r) => r.runner, cell: (r) => (r.runner ? html`<span>${r.runner}</span>` : dash) },
  {
    key: 'fallback', label: 'FALLBACK RUNNER', sort: (r) => (r.fallbacks[0] ? r.fallbacks[0].runner : null),
    cell: (r) => (r.fallbacks[0] ? html`<span>${r.fallbacks[0].runner}</span>` : html`<span class="na">none</span>`)
  },
  { key: 'primary', label: 'MODEL', sort: (r) => r.primary, cell: (r) => (r.primary ? html`<span class="mono">${r.primary}</span>` : dash) },
  { key: 'source', label: 'SCOPE', sort: (r) => r.source, cell: (r) => html`<${ScopeTag} source=${r.source} gapped=${r.gapped}/>` },
  {
    key: 'history', label: 'HISTORY', sort: null,
    cell: (r) => html`<${Link} to=${`${r.href}#history`} class="cell-name">history<//>`
  }
];

function CoverageNote({ coverage: cov }) {
  const line = (label, list) => (list.length ? html`<li>${label}: ${list.join(', ')}</li>` : null);
  return html`
    <${Section} title="SPEND ATTRIBUTION" note=${`cost ledger, last ${SPEND_DAYS} days, by stage / runner label`}>
      <ul class="section__note" style="margin:0;padding-left:18px;line-height:1.7">
        ${line('exact', cov.exact)}
        ${line('shared stage (figure is the whole stage)', cov.shared)}
        ${line('partial (some of the role\'s calls)', cov.partial)}
        ${line('no spend attribution yet', cov.none)}
      </ul>
    <//>`;
}

// ─────────────────────────────────────────────────────────── role page

export function ModelRoleScreen({ role }) {
  const projectParam = useSearchParam('project');
  const project = isHub(projectParam) ? null : projectParam;

  const route = useApi(() => api.modelRoute(role, project), [role, project]);
  const hub = useApi(() => (project ? api.modelRoute(role, null) : Promise.resolve(null)), [role, project]);
  const prices = useApi(() => api.modelPrices(), []);
  const history = useApi(() => api.modelRouteChanges({ role, project, limit: 200 }), [role, project]);
  const spend = useApi(() => fetchSpend([role], project), [role, project]);

  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [note, setNote] = useState(null);

  const refresh = useCallback(() => { route.reload(); hub.reload(); history.reload(); }, [route.reload, hub.reload, history.reload]);
  const actions = useMemo(() => makeModelActions({
    confirm: (opts) => confirm({
      title: opts.title,
      body: html`<${ChangeList} changes=${opts.changes} note=${opts.note}/>`,
      confirmLabel: opts.confirmLabel,
      tone: opts.tone
    }),
    writeLadder: (body) => api.putModelRoute(body),
    resetLadder: (body) => api.resetModelRoute(body),
    removeLadder: (body) => api.removeModelRoute(body),
    refresh,
    onNote: setNote
  }), [confirm, refresh]);

  // A #history / #change-N link lands on that section once the rows exist.
  const loaded = Boolean(history.data);
  useEffect(() => {
    const id = typeof window !== 'undefined' ? window.location.hash.slice(1) : '';
    if (!loaded || !id) return;
    const el = document.getElementById(id);
    if (el) el.scrollIntoView({ block: 'start' });
  }, [loaded]);

  if (route.loading && !route.data) return html`<div class="page"><${PageHeadline} chip="Model route" line1=${role} line2="Reading the route."/><${Skeleton} rows=${8} height=${20}/></div>`;

  const r = route.data || { ladder: [], source: 'none' };
  const row = modelRows({
    routes: { roles: [{ role, ladder: r.ladder, source: r.source }] }, prices: prices.data,
    spend: spend.data && spend.data.spend, plan: spend.data ? spend.data.plan : spendPlan([role], project), project
  })[0];

  return html`<${ModelRoleView} role=${role} project=${project} route=${r}
    hub=${hub.data ? hub.data.ladder : null} row=${row} prices=${prices.data}
    runners=${(route.data && route.data.runners) || []}
    changes=${changeRows(history.data && history.data.changes)} truncated=${Boolean(history.data && history.data.truncated)}
    error=${route.error || prices.error || history.error} dialog=${dialog}
    busy=${busy} setBusy=${setBusy} note=${note} onDismissNote=${() => setNote(null)} actions=${actions} />`;
}

function ChangeList({ changes, note }) {
  const fmt = (x) => (x ? `${x.model} (${x.runner})` : 'no rung');
  return html`
    <div>
      <p style="margin:0 0 8px">${note}</p>
      <ul style="margin:0;padding-left:18px">
        ${changes.map((c) => html`<li key=${c.position} class="mono" style="word-break:break-word">
          rung ${c.position}: ${fmt(c.before)} → ${fmt(c.after)}</li>`)}
      </ul>
    </div>`;
}

export function ModelRoleView({
  role, project, route, hub, row, prices, runners, changes, truncated, error, dialog,
  busy, setBusy, note, onDismissNote, actions, nowMs = Date.now()
}) {
  const back = project ? `/models?project=${encodeURIComponent(project)}` : '/models';
  const perToken = (prices && prices.per_token) || {};
  const ladderRows = (route.ladder || []).map((x) => ({
    ...x,
    price_in: perToken[x.model] ? perMillion(perToken[x.model].prompt) : null,
    price_out: perToken[x.model] ? perMillion(perToken[x.model].completion) : null,
    direct: isDirect(perToken[x.model])
  }));
  const guard = async (key, fn) => {
    if (!setBusy) return fn();
    setBusy(key);
    try { return await fn(); } finally { setBusy(null); }
  };

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Model route" line1=${role} line2=${project ? `Scoped to ${project}.` : 'The hub default.'}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to=${back} class="crumb">← MODELS<//>
        <span class="crumb-sep">/</span>
        ${project ? html`<${Link} to=${`/p/${encodeURIComponent(project)}`} class="tag">${project}<//>` : html`<span class="tag">hub</span>`}
        <${ScopeTag} source=${route.source} gapped=${Boolean(route.gapped)}/>
      </div>

      ${error ? html`<div class="banner"><span><b>could not refresh — ${String(error.message || error)}.</b> This is the last state that loaded.</span></div>` : null}
      ${note ? html`
        <div class=${note.ok ? 'banner banner--warn' : 'banner'}
          style=${note.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${note.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${onDismissNote}>DISMISS</button>
        </div>` : null}

      <${Section} title="LADDER" note=${route.source === 'project' ? `${project}'s own ladder` : route.source === 'hub' ? 'the hub default' : 'no route in the table'}>
        <${SortableTable} rows=${ladderRows} rowKey=${(x) => x.position} defaultSort="position"
          empty=${html`<${Empty} title="NO RUNGS" note="Neither this project nor the hub has a ladder for this role. A caller resolving it fails closed (rc 75) and alerts."/>`}
          columns=${[
            { key: 'position', label: 'RUNG', sort: (x) => x.position, cell: (x) => html`<span class="num">${x.position === 0 ? '0 (primary)' : x.position}</span>` },
            { key: 'model', label: 'MODEL', sort: (x) => x.model, cell: (x) => html`<span class="mono">${x.model}</span>${x.direct ? html` <${DirectTag}/>` : null}` },
            { key: 'runner', label: 'RUNNER', sort: (x) => x.runner, cell: (x) => html`<span>${x.runner}</span>` },
            { key: 'price_in', label: '$/1M IN', sort: (x) => x.price_in, align: 'right', cell: (x) => fmtRate(x.price_in) },
            { key: 'price_out', label: '$/1M OUT', sort: (x) => x.price_out, align: 'right', cell: (x) => fmtRate(x.price_out) }
          ]}/>
        <${Legend} items=${MODEL_LEGEND}/>
        ${route.gapped ? html`
          <p class="section__note" style="margin:8px 0 0">
            ${project ? `${project} has` : 'The hub has'} rows for this role that start past rung 0, so no rung 0 exists and
            every resolver ignores them${project ? `; ${project} runs the hub ladder above` : ' and the role has no route at all'}.
            ${project ? 'RESET TO HUB drops them. ' : ''}Saving a ladder below replaces the whole scope and repairs it.
            <ul class="mono" style="margin:6px 0 0;padding-left:18px">
              ${route.gapped.rows.map((x) => html`<li key=${x.position}>rung ${x.position}: ${x.model} (${x.runner})</li>`)}
            </ul>
          </p>` : null}
        ${row ? html`
          <p class="section__note" style="margin:8px 0 0">
            Last ${SPEND_DAYS} days: ${row.spend_error ? `spend read failed (${row.spend_error})`
              : row.usd_7d === null ? 'no spend figure' : html`<${UsdCell} value=${row.usd_7d} basis="api"/> over ${row.calls_7d} calls`}${' — '}${row.attribution.note || 'exact attribution'}.
          </p>` : null}
      <//>

      <${Section} title="EDIT" note=${project ? `writes ${project}'s ladder` : 'writes the hub default'}>
        ${project && route.source !== 'project'
          ? html`<p class="section__note" style="margin:0 0 8px">${project} follows the hub default for this role; saving creates an override for ${project} only.</p>`
          : null}
        <${LadderEditor} key=${JSON.stringify(route.ladder)} role=${role} project=${project} route=${route} hub=${hub}
          prices=${prices} runners=${runners} busy=${busy} guard=${guard} actions=${actions}/>
      <//>

      <div id="history">
        <${Section} title="HISTORY" note=${project ? `${project}'s changes and the hub's, newest first` : 'every scope, newest first'}>
          <${HistoryTable} changes=${changes} nowMs=${nowMs}/>
          ${truncated ? html`<p class="section__note">Showing the newest ${changes.length}; older changes exist.</p>` : null}
        <//>
      </div>
    </div>`;
}

function LadderEditor({ role, project, route, hub, prices, runners, busy, guard, actions }) {
  const [draft, setDraft] = useState(() => (route.ladder || []).map((x) => ({ model: x.model, runner: x.runner })));
  const [reason, setReason] = useState('');
  const priced = pricedModels(prices);
  const pricedSet = new Set(priced);
  const set = (i, patch) => setDraft((d) => d.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  const version = route.scope_version;
  // The hub version rides along so a save that CREATES an override from the
  // inherited hub ladder is guarded against that ladder moving (BH-1563); the
  // lib decides when to send it.
  const hubVersion = route.hub_scope_version;
  const save = () => guard('save', () => actions.saveLadder({
    role, project, before: route.ladder || [], draft, priced: pricedSet, runners, reason, source: route.source, version, hubVersion
  }));
  // A gapped project scope resets like an override, because that is what it is
  // — rows this project owns that nothing reads. `current` is those rows, so
  // the confirm modal shows exactly what goes.
  const gapRowsHere = route.gapped ? route.gapped.rows : null;
  const resettable = Boolean(project) && (route.source === 'project' || Boolean(gapRowsHere));
  const reset = () => guard('reset', () => actions.resetOverride({
    role, project, current: gapRowsHere || route.ladder, hub, reason, version
  }));
  // KEEP confirms the scope this page WRITES. A project tab resolving to the
  // hub would otherwise turn "keep the hub's seed" into a new project override,
  // so there it points at the hub tab instead.
  const ownScope = !project || route.source === 'project';
  const seeded = (route.provenance || []).some((p) => p.updated_by === 'seed');
  const keep = () => guard('keep', () => actions.keepSeed({ role, project, current: route.ladder, reason, version }));
  // BH-2512: REMOVE takes the hub's rows away, gapped ones included, so it is
  // offered only on the hub scope and only when the hub has rows.
  const hubRows = !project ? (route.source === 'hub' ? route.ladder : gapRowsHere) : null;
  const remove = () => guard('remove', () => actions.removeRoute({ role, project, current: hubRows, reason, version }));

  return html`
    <div style="display:flex;flex-direction:column;gap:8px;max-width:100%">
      ${draft.map((x, i) => {
        // The current model stays selectable even if it lost its price row,
        // labelled so; saving it then fails validation with the reason shown.
        const models = pricedSet.has(x.model) || !x.model ? priced : [x.model].concat(priced);
        return html`
          <div key=${i} style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
            <span class="na" style="min-width:64px">${i === 0 ? 'primary' : `rung ${i}`}</span>
            <select class="knob__input" style="width:auto;max-width:100%" aria-label=${`rung ${i} model`}
              disabled=${busy !== null} onChange=${(e) => set(i, { model: e.target.value })}>
              ${models.map((m) => html`<option value=${m} selected=${m === x.model}>${pricedSet.has(m) ? m : `${m} (not priced)`}</option>`)}
            </select>
            <select class="knob__input" style="width:auto" aria-label=${`rung ${i} runner`}
              disabled=${busy !== null} onChange=${(e) => set(i, { runner: e.target.value })}>
              ${runners.map((rn) => html`<option value=${rn} selected=${rn === x.runner}>${rn}</option>`)}
            </select>
            ${draft.length > 1 ? html`
              <button type="button" class="btn btn--sm" disabled=${busy !== null}
                onClick=${() => setDraft((d) => d.filter((_, j) => j !== i))}>REMOVE</button>` : null}
          </div>`;
      })}
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
        <button type="button" class="btn btn--sm" disabled=${busy !== null || !priced.length}
          onClick=${() => setDraft((d) => d.concat([{ model: priced[0], runner: (d[d.length - 1] || {}).runner || runners[0] }]))}>ADD RUNG</button>
        <input class="knob__input" style="flex:1 1 220px;max-width:100%" type="text" placeholder="reason (recorded in the audit trail)"
          aria-label="reason" value=${reason} onInput=${(e) => setReason(e.target.value)}/>
        <button type="button" class="btn btn--sm btn--primary" disabled=${busy !== null} onClick=${save}>
          ${busy === 'save' ? '…' : 'SAVE LADDER'}</button>
        ${seeded && ownScope ? html`
          <button type="button" class="btn btn--sm" disabled=${busy !== null} onClick=${keep}
            title="record the seeded ladder as reviewed, without changing it">
            ${busy === 'keep' ? '…' : KEEP_SEED_LABEL}</button>` : null}
        ${resettable ? html`
          <button type="button" class="btn btn--sm btn--warn" disabled=${busy !== null} onClick=${reset}>
            ${busy === 'reset' ? '…' : 'RESET TO HUB'}</button>` : null}
        ${hubRows && hubRows.length ? html`
          <button type="button" class="btn btn--sm btn--warn" disabled=${busy !== null} onClick=${remove}
            title="delete every hub rung of this role, audited; stays removed across deploys">
            ${busy === 'remove' ? '…' : 'REMOVE ROUTE'}</button>` : null}
      </div>
      ${seeded && !ownScope ? html`<p class="section__note" style="margin:0">
        The seeded rung is the hub's: confirm it on the <${Link} to=${`/models/${encodeURIComponent(role)}`}>hub tab<//>.</p>` : null}
    </div>`;
}

function HistoryTable({ changes, nowMs }) {
  const fmt = (m, r) => (m ? html`<span class="mono">${m}</span> <span class="na">(${r})</span>` : dash);
  return html`
    <${SortableTable} rows=${changes} rowKey=${(c) => c.id} defaultSort="at" defaultDir="desc"
      empty=${html`<${Empty} title="NO CHANGES" note="Nothing has written this role since the audit table existed. The #1510.0 seed is an INSERT, not a change, so a seeded role starts here empty."/>`}
      columns=${[
        {
          key: 'at', label: 'WHEN', sort: (c) => c.id,
          // Each change is its own anchor: the atomic record, linkable.
          cell: (c) => html`<a id=${c.anchor} href=${`#${c.anchor}`} class="cell-name" title=${c.at}>${c.at ? whenLabel(c.at, nowMs) : '—'}</a>`
        },
        { key: 'scope', label: 'SCOPE', sort: (c) => c.project || '', cell: (c) => html`<span>${c.project || 'hub'}</span>` },
        { key: 'position', label: 'RUNG', sort: (c) => c.position, cell: (c) => html`<span class="num">${c.position}</span>` },
        { key: 'kind', label: 'KIND', sort: (c) => c.kind, cell: (c) => html`<span class=${c.kind === 'removed' ? 'tag tag--warn' : 'tag'}>${c.kind}</span>` },
        { key: 'before', label: 'BEFORE', sort: (c) => c.before_model, cell: (c) => fmt(c.before_model, c.before_runner) },
        { key: 'after', label: 'AFTER', sort: (c) => c.after_model, cell: (c) => fmt(c.after_model, c.after_runner) },
        { key: 'actor', label: 'WHO', sort: (c) => c.actor, cell: (c) => html`<span>${c.actor || '—'}</span>` },
        { key: 'reason', label: 'REASON', sort: (c) => c.reason, cell: (c) => (c.reason ? html`<span>${c.reason}</span>` : dash) }
      ]}/>`;
}


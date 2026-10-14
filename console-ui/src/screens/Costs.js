import { useState, useCallback } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { TicketKey } from '../ui/TicketKey.js';
import { api, fetchLog, HUB_LOG_KINDS } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { LogPane } from '../ui/LogPane.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Legend } from '../ui/primitives.js';
import {
  fmtUsdExact, fmtShare, spendRows, spendHeadline, stageBreakdown, stagesReconcile, billingHealth
} from '../lib/spend.js';
import { clockTime, minutesSince, agoFromMinutes } from '../lib/format.js';
import {
  ANCHOR_WINDOWS, fmtFactor, isAnchored, anchorState, anchorHeadline,
  prLink, ticketLink, boxLink, stageLine
} from '../lib/anchored.js';
import { AccountUsageSection } from './AccountUsage.js';
import { CostBreakdownSection } from './CostBreakdown.js';
import { TriageWasteSection } from './TriageWaste.js';
import { LaneDedupSection } from './LaneDedup.js';
import { CostBreakerSection } from './CostBreaker.js';
import { CostCapsSection } from './CostCaps.js';
import { LaneSpendSection } from './LaneSpend.js';
import { CostCapHistorySection } from './CostCapHistory.js';

// The title row, with the LLM SITES link beside it (BH-2556). Its own
// component so the link renders in the node tests.
export function CostsHeader({ windowDays }) {
  return html`
    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <${Link} to="/" class="crumb">← FLEET<//>
      <span class="crumb-sep">/</span>
      <span class="crumb">COSTS</span>
      <span style="font-size:var(--fs-sm);color:var(--faint)">window ${windowDays} days</span>
      <${Link} to="/llm-sites" class="crumb">LLM SITES →<//>
    </div>`;
}

// This screen renders exactly what the endpoint holds and says plainly what it
// does not. No priced per-call rows reach D1 today, so anything here that looks
// like a dollar figure would be invented — the `gaps` array is the headline,
// not a footnote.
export function CostsScreen() {
  const c = useApi(() => api.costs(), [], { intervalMs: 60000 });
  const [which, setWhich] = useState('cost');

  // Fleet-level logs are addressed to the literal `hub`, never to a project and
  // never to "fleet" (which the fetch validator rejects).
  const hubAction = useCallback((kind) => fetchLog('hub', kind), []);

  if (c.loading && !c.data) return html`<div class="page"><${PageHeadline} chip="Costs" line1="Reading the costs." line2=""/><${Skeleton} rows=${6} height=${22}/></div>`;
  if (c.error && !c.data) {
    return html`<div class="page">
      <${Link} to="/" class="crumb">← FLEET<//>
      <${PageHeadline} chip="Costs" line1="The costs read failed." line2=""/>
      <${ErrorBox} error=${c.error} onRetry=${c.reload}/>
    </div>`;
  }

  const data = c.data;
  const volume = data.volume || [];
  const readouts = data.readouts || [];
  const gaps = data.gaps || [];
  const totalRuns = volume.reduce((n, v) => n + (v.runs || 0), 0);
  const totalTickets = volume.reduce((n, v) => n + (v.tickets_built || 0), 0);
  const totalFailed = volume.reduce((n, v) => n + (v.failed_runs || 0), 0);

  return html`
    <div class="page">
      <${PageHeadline} chip="Costs"
        line1=${`${totalRuns} ${totalRuns === 1 ? 'run' : 'runs'} in ${data.window_days} days. ${totalTickets} ${totalTickets === 1 ? 'ticket' : 'tickets'} built.`}
        line2=${`${totalFailed} failed ${totalFailed === 1 ? 'run' : 'runs'}.${gaps.length ? ` ${gaps.length} ${gaps.length === 1 ? 'caveat' : 'caveats'} from the API.` : ''}`}/>
      <${CostsHeader} windowDays=${data.window_days}/>

      <${SpendSection} costs=${data}/>
      <${CostBreakdownSection}/>
      <${TriageWasteSection}/>
      <${CostBreakerSection}/>
      <${CostCapsSection}/>
      <${CostCapHistorySection}/>
      <${LaneSpendSection}/>

      ${gaps.length ? html`
        <div class="footnote" style="flex-direction:column;align-items:flex-start;gap:4px">
          <span style="color:var(--faint)"><b>Caveats the API itself reports:</b></span>
          ${gaps.map((g, i) => html`<span key=${i} style="color:var(--faint)">· ${g}</span>`)}
        </div>` : null}

      <${LaneDedupSection}/>
      <${AccountUsageSection}/>
      <${AnchoredSection}/>

      <${Section} title=${`THROUGHPUT · ${data.window_days}D`}
        note="run and ticket VOLUME — the efficiency proxy, windowed by ?days; spend above is fixed 7d/30d">
      <div class="stats" style="margin-bottom:10px">
        <${Stat} label=${`RUNS · ${data.window_days}D`} value=${totalRuns}/>
        <${Stat} label=${`TICKETS BUILT · ${data.window_days}D`} value=${totalTickets} tone="green"/>
        <${Stat} label="FAILED RUNS" value=${totalFailed} tone=${totalFailed ? 'warn' : null}/>
        <${Stat} label="PROJECTS WITH VOLUME" value=${volume.length}/>
        <${Stat} label="READ-OUTS ON FILE" value=${readouts.length}/>
      </div>
      <//>

      <${Section} title="VOLUME BY PROJECT" note="run and ticket counts from D1 — not spend">
        <${SortableTable}
          columns=${[
            {
              key: 'project', label: 'PROJECT', sort: (r) => r.project,
              cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
            },
            { key: 'runs', label: 'RUNS', sort: (r) => r.runs, align: 'right', cell: (r) => html`<span class="num">${r.runs ?? 0}</span>` },
            {
              key: 'failed_runs', label: 'FAILED', sort: (r) => r.failed_runs, align: 'right',
              cell: (r) => r.failed_runs
                ? html`<span class="num--warn">${r.failed_runs}</span>`
                : html`<span class="na">0</span>`
            },
            {
              key: 'tickets_built', label: 'TICKETS BUILT', sort: (r) => r.tickets_built, align: 'right',
              cell: (r) => html`<span class="num--ok">${r.tickets_built ?? 0}</span>`
            },
            {
              key: 'ratio', label: 'RUNS / TICKET', sort: (r) => (r.tickets_built ? r.runs / r.tickets_built : null), align: 'right',
              cell: (r) => r.tickets_built
                ? html`<span>${(r.runs / r.tickets_built).toFixed(1)}</span>`
                : html`<span class="na">—</span>`
            }
          ]}
          rows=${volume}
          rowKey=${(r) => r.project}
          defaultSort="tickets_built" defaultDir="desc"
          empty=${html`<${Empty} title="no volume in the window"
            note=${`Nothing ran anywhere in the last ${data.window_days} days.`} />`} />
      <//>

      <${Section} title="COST READ-OUT HEADLINES"
        note="the hub's cost-readout beat lands as an event, headline only — the ~7KB body is discarded on ingest">
        ${readouts.length
          ? html`<${SortableTable}
              columns=${[
                { key: 'ts', label: 'WHEN', sort: (r) => minutesSince(r.ts),
                  cell: (r) => html`<span title=${r.ts}>${clockTime(r.ts)}</span>` },
                { key: 'age', label: 'AGE', sort: (r) => minutesSince(r.ts), align: 'right',
                  cell: (r) => html`<span>${agoFromMinutes(minutesSince(r.ts))}</span>` },
                { key: 'project', label: 'SCOPE', sort: (r) => r.project,
                  cell: (r) => html`<span style="color:var(--soft)">${r.project || 'fleet'}</span>` },
                { key: 'line', label: 'HEADLINE', sort: null,
                  cell: (r) => html`<span class="cell-wrap" title=${r.line}>${r.line}</span>` }
              ]}
              rows=${readouts}
              rowKey=${(r) => r.id}
              defaultSort="ts" defaultDir="asc" />`
          : html`<${Empty} title="no read-outs on file"
              note="The hub has not beaten a cost read-out into the console yet." />`}
      <//>

      <${Section} title="HUB LOGS"
        note="fleet-level logs are addressed to the literal hub — the box that holds the cost roll-up, the decisions log and pipeline health">
        <${LogPane}
          kinds=${HUB_LOG_KINDS.map((k) => ({ key: k, label: k.toUpperCase() }))}
          activeKind=${which}
          onKind=${setWhich}
          action=${hubAction}
          autoFetch=${false}
          emptyHint="Pick a hub log and press FETCH FRESH — cost is the priced roll-up this screen cannot show from D1." />
      <//>
    </div>`;
}

// Exact money stays exact (BH-3570 D1): fmtUsdExact keeps `<$0.01` where
// UsdCell would round to $0.00. The basis rides on the attribute; the header
// and the legend say what it means.
const dash = html`<span class="na">—</span>`;
const usdExact = (n, basis = 'api') => (n === null || n === undefined
  ? dash
  : html`<span class="num" data-usd-basis=${basis}>${fmtUsdExact(n)}</span>`);

const SPEND_LEGEND = [
  { term: 'API-EQUIV', text: 'API-equivalent: list price times tokens. What the compute would cost on the API, not cash.' },
  { term: 'CASH 7D', text: 'Metered cash only. It leaves out subscription overage, so it is narrower than CASH OUT.' },
  { term: 'UNCLASSIFIED', text: 'Calls with no billing mode tagged yet, so we cannot say whether they were cash or subscription.' },
  { term: 'UNPRICED', text: 'Calls with no priced usage row. They cost something and are counted here as nothing, so the spend is an undercount.' },
  { term: 'TRIAGE SHARE', text: "The part of this project's 7-day spend that went to triage." },
];

const ANCHORED_LEGEND = [
  { term: 'RAW', text: 'The cost-row ledger sum. It undercounts the real bill.' },
  { term: 'ANCHORED', text: "The raw figure scaled onto the account's own cash meter. Muted when nothing was metered, because then it equals RAW." },
  { term: '×', text: "Anchored divided by raw for that row's account." },
  { term: '× vs LEDGER', text: "The fleet's anchored total divided by its raw total for this window." },
];

export const AnchoredLegend = () => html`<${Legend} items=${ANCHORED_LEGEND}/>`;

// Real dollars. The rules here are not stylistic: a cost readout is believed,
// so a figure we do not have must never render as $0.00, a fleet total is
// whatever the API sent rather than a client-side sum that silently drops the
// projects the rollup could not price, and an undercount says it is one.
export function SpendSection({ costs }) {
  const [openProject, setOpenProject] = useState(null);
  const head = spendHeadline(costs);
  const health = billingHealth(costs);
  const rows = spendRows(costs);
  const priced = rows.filter((r) => !r.unavailable);
  const unpricedProjects = rows.filter((r) => r.unavailable);

  const columns = [
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    {
      // null here means the worker does not send cost_24h yet (or the project
      // is unpriced) — a dash, never $0.00.
      key: 'cost_24h', label: 'API-EQUIV 24H', sort: (r) => r.cost_24h, align: 'right',
      cell: (r) => r.unavailable
        ? html`<span class="na" title="the rollup does not carry this project">n/a</span>`
        : usdExact(r.cost_24h)
    },
    {
      key: 'cost_7d', label: 'API-EQUIV 7D', sort: (r) => r.cost_7d, align: 'right',
      cell: (r) => r.unavailable
        ? html`<span class="na" title="the rollup does not carry this project">n/a</span>`
        : html`<span style="color:var(--bright);font-weight:700">${usdExact(r.cost_7d)}</span>`
    },
    {
      key: 'cash_cost_7d', label: 'CASH 7D (METERED)', sort: (r) => r.cash_cost_7d, align: 'right',
      cell: (r) => r.unavailable
        ? html`<span class="na" title="the rollup does not carry this project">n/a</span>`
        : r.cash_cost_7d === null
          ? html`<span class="na" title="no cash figure reported for this project — unknown, not zero">unknown</span>`
          : html`<span title="metered-lane cash only — it excludes subscription overage, so it is narrower than the fleet Cash out line"
              style=${r.cash_cost_7d > 0 ? 'color:var(--amber-lt)' : ''}>${usdExact(r.cash_cost_7d, 'cash')}</span>`
    },
    {
      key: 'unknown_billing_calls_7d', label: 'UNCLASSIFIED', sort: (r) => r.unknown_billing_calls_7d, align: 'right',
      cell: (r) => r.unknown_billing_calls_7d === null
        ? html`<span class="na">—</span>`
        : r.unknown_billing_calls_7d > 0
          ? html`<span style="color:var(--faint)" title="calls with no billing mode tagged yet — expected while the rollout completes">${r.unknown_billing_calls_7d}</span>`
          : html`<span class="na">0</span>`
    },
    {
      key: 'cost_30d', label: 'API-EQUIV 30D', sort: (r) => r.cost_30d, align: 'right',
      cell: (r) => r.unavailable ? html`<span class="na">n/a</span>` : usdExact(r.cost_30d)
    },
    {
      key: 'cost_per_merged_pr_7d', label: '$ PER MERGED PR · 7D', sort: (r) => r.cost_per_merged_pr_7d, align: 'right',
      cell: (r) => r.unavailable ? html`<span class="na">n/a</span>` : usdExact(r.cost_per_merged_pr_7d)
    },
    {
      key: 'merged_prs_7d', label: 'MERGED 7D', sort: (r) => r.merged_prs_7d, align: 'right',
      cell: (r) => r.merged_prs_7d === null
        ? html`<span class="na">—</span>`
        : html`<span class="num">${r.merged_prs_7d}</span>`
    },
    {
      key: 'triage_share_7d', label: 'TRIAGE SHARE · 7D', unit: '% of spend', sort: (r) => r.triage_share_7d, align: 'right',
      cell: (r) => html`<span style="color:var(--soft)">${fmtShare(r.triage_share_7d)}</span>`
    },
    {
      key: 'unpriced_calls_7d', label: 'UNPRICED', sort: (r) => r.unpriced_calls_7d, align: 'right',
      cell: (r) => r.unpriced_calls_7d === null
        ? html`<span class="na" title="the rollup could not count unpriced calls for this project — unknown, not zero">unknown</span>`
        : r.unpriced_calls_7d > 0
          ? html`<span class="num--warn" title="calls with no priced usage row — this project's spend is an undercount">${r.unpriced_calls_7d}</span>`
          : html`<span class="na">0</span>`
    },
    {
      key: 'stages', label: '', sort: null, align: 'right',
      cell: (r) => r.stages_7d && Object.keys(r.stages_7d).length
        ? html`<button class="btn btn--sm" onClick=${() => setOpenProject(openProject === r.project ? null : r.project)}>
            ${openProject === r.project ? 'HIDE STAGES' : 'STAGES'}
          </button>`
        : html`<span class="na">—</span>`
    }
  ];

  const open = openProject ? rows.find((r) => r.project === openProject) : null;

  return html`
    <${Section} title="SPEND"
      note=${head.unavailable
        ? 'the cost rollup is unavailable'
        : `fixed 24h / 7d / 30d windows · ${head.ageMin === null ? 'age unknown' : `rolled up ${agoFromMinutes(head.ageMin)} ago`}`}
      right=${html`<span style="display:inline-flex;gap:6px">
        ${head.incomplete
          ? html`<span class="tag tag--warn"
              title=${`The fleet total excludes ${head.missing.length ? head.missing.join(', ') : 'one or more projects'} — the rollup cannot price them, so the figure shown is a floor, not the answer.`}>
              INCOMPLETE</span>`
          : null}
        ${head.stale
          ? html`<span class="tag tag--warn" title="the rollup is a daily cron — more than 26h old means it has not run">STALE</span>`
          : null}
      </span>`}>

      ${head.unavailable ? html`
        <div class="banner banner--warn">
          <span>
            No spend to show — <b>${head.unavailable}</b>.
            ${' This is why the figures below read n/a rather than zero dollars: nothing was measured, which is not the same as nothing was spent.'}
          </span>
        </div>` : null}

      ${head.incomplete ? html`
        <div class="banner banner--warn">
          <span>
            The fleet total is <b>incomplete</b> — it is a floor, not the answer.
            ${head.missing.length
              ? html` The rollup does not price ${head.missing.join(', ')}, so ${head.missing.length === 1 ? 'its' : 'their'} spend is missing from the totals above.`
              : ' One or more projects are not priced by the rollup.'}
            ${' Real fleet spend is higher by an unknown amount, which is why the headline reads "≥".'}
          </span>
        </div>` : null}

      ${head.stale ? html`
        <div class="banner banner--warn">
          <span>
            The cost rollup is <b>stale</b>${head.ageMin !== null ? ` — ${agoFromMinutes(head.ageMin)} old` : ''}.
            ${" It runs as a daily cron, so anything past 26h means it did not run. Spend below is real but it is not today's."}
          </span>
        </div>` : null}

      ${head.unpricedKnownPositive ? html`
        <div class="banner">
          <span>
            <b>${`${head.unpriced} calls unpriced in the last 7 days — the spend below is an UNDERCOUNT.`}</b>
            ${' A runner lane is producing usage rows the cost parser cannot read, so those calls were billed by the vendor and counted as zero here. The real figure is higher by an unknown amount — this is the same shape as a lane reading zero dollars while the bill arrives.'}
          </span>
        </div>` : null}

      ${head.overage.inOverage ? html`
        <div class=${head.overage.limitReached ? 'banner banner--warn' : 'banner'}>
          <span>
            <b>${'IN OVERAGE'}</b>${' — billing cash at API rates'}
            ${head.overage.resetsAt ? ` until it resets at ${head.overage.resetsAt}` : ''}.
            ${head.overage.limitReached ? ' Spend limit reached — billing stopped.' : ''}
          </span>
        </div>` : null}

      ${!head.cashReady ? html`
        <div class="banner banner--warn">
          <span><b>${'Cash out is not being reported yet.'}</b> ${head.cashPending}</span>
        </div>` : null}

      <div class="stats">
        <${Stat} label="API-equivalent (not cash) · 7D"
          value=${html`<span data-usd-basis="api">${head.attributed7d}</span>`}
          tone=${head.hasTotals ? 'green' : 'sm'}/>
        <${Stat} label="CASH OUT · 7D"
          value=${head.cashReady ? html`<span data-usd-basis="cash">${head.cash7d}</span>` : 'measuring…'}
          tone=${head.cashReady ? 'amber' : 'sm'}/>
        <${Stat} label="API-equivalent · 24H" value=${html`<span data-usd-basis="api">${head.cost24h}</span>`} tone="sm"/>
        <${Stat} label="API-equivalent · 30D" value=${html`<span data-usd-basis="api">${head.cost30d}</span>`} tone="sm"/>
        <${Stat} label="UNPRICED CALLS · 7D"
          value=${head.unpriced === null ? 'unknown' : head.unpriced}
          tone=${head.unpricedKnownPositive ? 'warn' : head.unpriced === null ? 'sm' : null}/>
        <${Stat} label="PROJECTS PRICED" value=${`${priced.length}/${rows.length}`} tone="sm"
          unit=${unpricedProjects.length ? ` · not priced: ${unpricedProjects.map((r) => r.project).join(', ')}` : null}/>
        <${Stat} label="ROLLED UP" value=${head.ageMin === null ? 'unknown' : agoFromMinutes(head.ageMin) + ' ago'} tone="sm"/>
      </div>

      <div class="footnote" style="flex-direction:column;align-items:flex-start;gap:4px">
        <span style="color:var(--faint)">
          ${'API-equivalent (not cash) = what the compute would cost at list price. Cash = what actually hit a card (metered vendors + subscription overage).'}
          ${head.cashReady && head.hasCash && head.cashMetered7d !== '—'
            ? html` Cash breaks down as <span data-usd-basis="cash">${head.cashMetered7d}</span> metered + <span data-usd-basis="cash">${head.cashOverage7d}</span> overage.`
            : ''}
        </span>
        ${health.state !== 'clean' && health.text ? html`
          <span style=${health.alarming ? 'color:var(--amber-txt)' : 'color:var(--faint)'}>
            ${health.alarming ? '⚠ ' : ''}${health.text}
          </span>` : null}
      </div>

      ${rows.length
        ? html`<${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.project}
            rowClass=${(r) => (r.unavailable ? 'row--warn' : '')}
            defaultSort="cost_7d" defaultDir="desc" />`
        : html`<${Empty} title="no per-project spend"
            note="The rollup returned no project rows." />`}
      <${Legend} items=${SPEND_LEGEND}/>

      ${unpricedProjects.length ? html`
        <div class="footnote">
          <span style="color:var(--amber-dk)">
            ${unpricedProjects.map((r) => r.project).join(', ')} — not carried by the cost rollup, so
            ${unpricedProjects.length === 1 ? 'its' : 'their'} spend is unknown rather than zero,
            and ${unpricedProjects.length === 1 ? 'it is' : 'they are'} not in the fleet total above.
          </span>
        </div>` : null}

      ${open ? html`<${StageBreakdown} row=${open}/>` : null}
    <//>`;
}

// The stage parts are shown against the project total, and when they do not add
// up the gap is named rather than left for the reader to notice. That gap is
// usually exactly the unpriced calls.
function StageBreakdown({ row }) {
  const stages = stageBreakdown(row.stages_7d);
  const rec = stagesReconcile(row.stages_7d, row.cost_7d);
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:10px;margin-top:10px">
      <div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap">
        <span class="section__title">${row.project} · BY STAGE · 7D</span>
        <span class="section__note">${usdExact(row.cost_7d)} total</span>
      </div>
      ${stages.map((s) => html`
        <div key=${s.stage} class="kv" style="grid-template-columns:110px minmax(0,1fr) 80px">
          <span class="kv__label">${s.stage}</span>
          <span class="meter"><span class=${`meter__fill${s.barPct > 60 ? ' meter__fill--hi' : ''}`}
            style=${`width:${s.barPct}%`}></span></span>
          <span class="kv__val">${usdExact(s.usd)}</span>
        </div>`)}
      <div class="kv kv--total" style="grid-template-columns:110px minmax(0,1fr) 80px">
        <span class="kv__label">stage sum</span>
        <span></span>
        <span class="kv__val">${usdExact(rec.sum)}</span>
      </div>
      ${rec.matches === false ? html`
        <span style="font-size:var(--fs-xs);color:var(--amber-txt);line-height:1.6">
          ${'The stages do not add up to the project total — '}${usdExact(Math.abs(rec.delta))}${' '}
          ${rec.delta > 0 ? 'is unaccounted for by any stage.' : 'more is attributed to stages than the total.'}
          ${row.unpriced_calls_7d > 0 ? ` Most likely the ${row.unpriced_calls_7d} unpriced calls on this project.` : ''}
        </span>` : null}
      ${rec.matches === null ? html`
        <span style="font-size:var(--fs-xs);color:var(--faint)">
          No project total to reconcile these stages against.
        </span>` : null}
    </div>`;
}

// ── METER-ANCHORED SPEND ────────────────────────────────────────────────────
// Everything above this line is cost_rows, and cost_rows UNDERCOUNTS the real
// bill 3-4x: a row exists per wrapped agent call, and the calls that miss the
// wrapper miss the ledger. The account's own cash meter does not undercount.
// So these tables carry BOTH figures in every row — the raw ledger sum and that
// same sum scaled onto the meter — because an anchored dollar with no raw
// dollar beside it is a number nobody can check, and a money screen that cannot
// be checked is how a bad multiplier becomes a budget decision.
//
// The arithmetic is entirely the worker's (GET /api/metrics/cost-anchored).
// Nothing in this file multiplies anything; see lib/anchored.js for why.
function AnchoredSection() {
  const [win, setWin] = useState('24h');
  const a = useApi(() => api.costAnchored({ window: win }), [win], { intervalMs: 60000 });
  const head = anchorHeadline(a.data);

  const switcher = html`<span style="display:inline-flex;gap:6px;flex-wrap:wrap">
    ${ANCHOR_WINDOWS.map((w) => html`
      <button key=${w.key} type="button" class=${w.key === win ? 'tab tab--on' : 'tab'}
        aria-pressed=${w.key === win ? 'true' : 'false'}
        onClick=${() => setWin(w.key)}>${w.label}</button>`)}
  </span>`;

  const body = () => {
    if (a.loading && !a.data) return html`<${Skeleton} rows=${4} height=${20}/>`;
    if (a.error && !a.data) return html`<${ErrorBox} error=${a.error} onRetry=${a.reload}/>`;
    if (head.disabled) {
      return html`<div class="banner banner--warn">
        <span>
          <b>Anchoring is off</b> — ${head.reason}. Nothing is shown rather than raw dollars
          under an anchored heading, which would be the same lie in a nicer font.
        </span>
      </div>`;
    }
    if (!head.ready) return html`<${Empty} title="no anchored figures" note="The endpoint returned nothing for this window."/>`;

    const d = a.data;
    const anchoredBasis = head.anyAnchored ? 'cash' : 'api';
    return html`
      <${AnchoredLegend}/>
      <${AccountStrip} accounts=${d.accounts} head=${head}/>

      ${!head.anyAnchored ? html`
        <div class="banner banner--warn" style="margin:10px 0">
          <span>
            <b>Nothing is metered in this window</b>, so every ANCHORED figure below is identical to its
            RAW figure — it is the ledger, not a correction of it. The account strip says why per account.
            This is the normal case: the meter only moves once an account is past its weekly credits.
          </span>
        </div>` : null}

      ${(d.gaps || []).length ? html`
        <div class="footnote" style="flex-direction:column;align-items:flex-start;gap:4px;margin-bottom:10px">
          <span style="color:var(--faint)"><b>What these tables do not cover:</b></span>
          ${d.gaps.map((g, i) => html`<span key=${i} style="color:var(--faint)">· ${g}</span>`)}
        </div>` : null}

      <${AnchoredTable}
        title="$ / PR"
        note="one row per pull request the rollup priced, placed in the window by the build that produced it"
        columns=${prColumns}
        rows=${d.per_pr}
        rowKey=${(r) => r.pr_url}
        defaultSort="anchored_usd"
        truncated=${d.per_pr_truncated} limit=${d.limit}
        totalRaw=${head.ready ? d.totals.pr_raw_usd : null}
        totalAnchored=${head.ready ? d.totals.pr_anchored_usd : null}
        totalN=${d.totals.prs} anchoredBasis=${anchoredBasis}
        empty="No priced PR landed in this window."/>

      <${AnchoredTable}
        title="$ / TICKET"
        note="the PRs above rolled up by the ticket key their build dir carries"
        columns=${ticketColumns}
        rows=${d.per_ticket}
        rowKey=${(r) => `${r.project}|${r.key}`}
        defaultSort="anchored_usd"
        truncated=${d.per_ticket_truncated} limit=${d.limit}
        totalRaw=${d.totals.ticket_raw_usd}
        totalAnchored=${d.totals.ticket_anchored_usd}
        totalN=${d.totals.tickets} anchoredBasis=${anchoredBasis}
        empty="No ticket-keyed spend in this window."/>

      <${AnchoredTable}
        title="$ / BOX"
        note="every priced call stamped inside the window, triage and failed builds included — a wider population than $/PR"
        columns=${boxColumns}
        rows=${d.per_box}
        rowKey=${(r) => r.box}
        defaultSort="anchored_usd"
        truncated=${d.per_box_truncated} limit=${d.limit}
        totalRaw=${d.totals.box_raw_usd}
        totalAnchored=${d.totals.box_anchored_usd}
        totalN=${d.totals.boxes} anchoredBasis=${anchoredBasis}
        empty="No priced call from any box in this window."/>`;
  };

  return html`
    <${Section} title="ANCHORED SPEND"
      note=${head.ready && head.from
        ? `${head.window} · ${head.metered} of ${head.accounts} account${head.accounts === 1 ? '' : 's'} metered`
        : 'cost_rows scaled onto the account cash meter'}
      right=${html`<span style="display:inline-flex;gap:8px;align-items:center;flex-wrap:wrap">
        ${head.ready && head.uplift
          ? html`<span class="tag" title="the anchored fleet total divided by the raw one, for this window">
              ×${head.uplift.toFixed(2)} vs LEDGER</span>`
          : null}
        ${switcher}
      </span>`}>
      ${body()}
    <//>`;
}

// One card per billing account: what its meter did, what its rows claim, and
// the multiplier between them. A state is always spelled out in a sentence —
// "factor 1.00" and "we could not measure this" are opposite claims that would
// otherwise render identically.
export function AccountStrip({ accounts, head }) {
  if (!accounts.length) {
    return html`<${Empty} title="no accounts in this window" note="No priced row and no meter poll landed in the window."/>`;
  }
  return html`
    <div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:12px">
      ${accounts.map((acc) => {
        const s = anchorState(acc);
        const color = s.tone === 'ok' ? 'var(--green)' : s.tone === 'warn' ? 'var(--amber)' : 'var(--fainter)';
        return html`
          <div key=${acc.label} class="card" style="flex:1 1 260px;min-width:0;padding:10px 12px">
            <div style="display:flex;gap:8px;align-items:baseline;flex-wrap:wrap">
              <span class="cell-name" style="word-break:break-all">${acc.label}</span>
              <span class="tag" style=${`margin-left:auto;color:${color};border-color:${color}`}
                title=${s.note}>${s.label}</span>
            </div>
            <div style="display:flex;gap:14px;flex-wrap:wrap;margin-top:8px;font-size:var(--fs-sm)">
              <span title="how much the account's own cash meter moved across this window">
                <span style="color:var(--faint)">METER </span>
                ${acc.meter_delta_usd === null
                  ? html`<span class="na">—</span>`
                  : html`<span style="color:var(--bright);font-weight:700">${usdExact(acc.meter_delta_usd, 'cash')}</span>`}
              </span>
              <span title="what cost_rows billed to this account over the window">
                <span style="color:var(--faint)">ROWS </span>${usdExact(acc.rows_usd)}
              </span>
              <span title=${s.note}>
                <span style="color:var(--faint)">FACTOR </span>
                <span style=${`color:${color};font-weight:700`}>${fmtFactor(acc.factor, acc.state)}</span>
              </span>
            </div>
            ${acc.weekly_pct !== null && acc.weekly_pct !== undefined ? html`
              <div style="margin-top:6px;font-size:var(--fs-2xs);color:var(--faint)">
                weekly credits ${Number(acc.weekly_pct).toFixed(0)}% used${acc.weekly_resets_at ? `, resets ${acc.weekly_resets_at}` : ''}
                ${acc.spend_limit_reached ? html` · <span class="tag tag--warn">SPEND LIMIT REACHED</span>` : null}
              </div>` : null}
            ${acc.factor_capped ? html`
              <div style="margin-top:6px;font-size:var(--fs-2xs);color:var(--amber)"
                title=${s.note}>measured ${fmtFactor(acc.factor_raw, 'metered')} — clamped</div>` : null}
            <div style="margin-top:6px;font-size:var(--fs-2xs);color:var(--fainter)">${s.note}</div>
          </div>`;
      })}
    </div>`;
}

// A table plus the one thing SortableTable has no opinion about: a totals line
// that is explicitly the WINDOW's total, not the page's. When the page is
// truncated those two differ, and a footer that quietly means something other
// than the column above it is the dishonest kind.
export function AnchoredTable({ title, note, columns, rows, rowKey, defaultSort, truncated, limit, totalRaw, totalAnchored, totalN, empty, anchoredBasis = 'api' }) {
  return html`
    <${Section} title=${title} note=${note}>
      <${SortableTable}
        columns=${columns} rows=${rows} rowKey=${rowKey}
        defaultSort=${defaultSort} defaultDir="desc"
        empty=${html`<${Empty} title="nothing here" note=${empty}/>`} />
      ${rows.length ? html`
        <div class="footnote" style="justify-content:flex-start;gap:16px;flex-wrap:wrap">
          <span><b>TOTAL</b></span>
          <span>${totalN} row${totalN === 1 ? '' : 's'}</span>
          <span>raw ${usdExact(totalRaw)}</span>
          <span>anchored <span style="color:var(--bright);font-weight:700">${usdExact(totalAnchored, anchoredBasis)}</span></span>
          ${truncated
            ? html`<span class="tag tag--warn"
                title=${`The table shows the ${limit} costliest rows. The total counts every row in the window.`}>
                SHOWING TOP ${limit}<//>`
            : null}
        </div>` : null}
    <//>`;
}

// Every identity cell links somewhere real, and a cell with nowhere honest to
// go is a dash rather than a route that would 404.
const IdCell = ({ link, label, title }) => {
  if (!link) return html`<span class="na" title=${title}>${label}</span>`;
  if (link.kind === 'external') {
    return html`<a href=${link.to} target="_blank" rel="noopener noreferrer" class="cell-name" title=${title}>${label}</a>`;
  }
  return html`<${Link} to=${link.to} class="cell-name" title=${title}>${label}<//>`;
};

// The two money columns, in every table, always together. RAW is the ledger;
// ANCHORED is the ledger scaled onto the meter — and where nothing was metered
// the second is shown muted, because it is a copy of the first and not a
// second, confirming measurement.
const rawCol = {
  key: 'raw_usd', label: 'RAW', sort: (r) => r.raw_usd, align: 'right',
  cell: (r) => html`<span title="the cost_rows sum — known to undercount">${usdExact(r.raw_usd)}</span>`
};
const anchoredCol = {
  key: 'anchored_usd', label: 'ANCHORED', sort: (r) => r.anchored_usd, align: 'right',
  cell: (r) => isAnchored(r)
    ? html`<span style="color:var(--bright);font-weight:700"
        title="raw rows scaled onto the account's cash meter">${usdExact(r.anchored_usd, 'cash')}</span>`
    : html`<span class="na" title="nothing metered this account in this window, so this equals the raw figure">${usdExact(r.anchored_usd)}</span>`
};

const accountCol = {
  key: 'account', label: 'ACCOUNT', sort: (r) => r.account,
  cell: (r) => html`<span style="color:var(--soft);word-break:break-all">${r.account}</span>`
};

const prColumns = [
  {
    key: 'pr', label: 'PR', sort: (r) => `${r.repo || ''}#${r.number || ''}`,
    cell: (r) => html`<${IdCell} link=${prLink(r)}
      label=${`${r.repo || '?'}#${r.number ?? '?'}`} title=${r.pr_url}/>`
  },
  {
    key: 'key', label: 'TICKET', sort: (r) => r.key,
    cell: (r) => r.key
      ? html`<${TicketKey} k=${r.key} cls="cell-name" title=${`${r.project || 'unknown project'} · ${r.build_dir || ''}`}
          alt=${ticketLink(r) ? { to: ticketLink(r).to, label: 'build' } : null}/>`
      : html`<span class="na" title="a hand-run build — no ticket key in its build dir">—</span>`
  },
  accountCol,
  {
    key: 'factor', label: '×', sort: (r) => r.factor, align: 'right',
    cell: (r) => html`<span style=${isAnchored(r) ? 'color:var(--amber-lt)' : 'color:var(--fainter)'}>
      ${isAnchored(r) ? `${Number(r.factor).toFixed(2)}x` : '—'}</span>`
  },
  rawCol,
  anchoredCol,
  {
    key: 'at', label: 'WHEN', sort: (r) => r.at,
    cell: (r) => html`<span title=${r.merged_at ? `merged ${r.merged_at}` : r.at}>${clockTime(r.at)}</span>`
  }
];

const ticketColumns = [
  {
    key: 'key', label: 'TICKET', sort: (r) => r.key,
    cell: (r) => html`<${TicketKey} k=${r.key} cls="cell-name" title=${r.build_dir}
      alt=${ticketLink(r) ? { to: ticketLink(r).to, label: 'build' } : null}/>`
  },
  {
    key: 'project', label: 'PROJECT', sort: (r) => r.project,
    cell: (r) => r.project
      ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
      : html`<span class="na">—</span>`
  },
  { key: 'prs', label: 'PRS', sort: (r) => r.prs, align: 'right', cell: (r) => html`<span class="num">${r.prs}</span>` },
  rawCol,
  anchoredCol,
  {
    key: 'stages', label: 'STAGES', sort: null,
    cell: (r) => {
      const line = stageLine(r.stage_breakdown, fmtUsdExact);
      return line
        ? html`<span class="cell-wrap" data-usd-basis="api" style="color:var(--soft)" title=${line}>${line}</span>`
        : html`<span class="na">—</span>`;
    }
  }
];

const boxColumns = [
  {
    key: 'box', label: 'BOX', sort: (r) => r.box,
    cell: (r) => html`<${IdCell} link=${boxLink()} label=${r.box} title="open the machines screen"/>`
  },
  { key: 'calls', label: 'CALLS', sort: (r) => r.calls, align: 'right', cell: (r) => html`<span class="num">${r.calls ?? 0}</span>` },
  {
    key: 'accounts', label: 'ACCOUNTS', sort: (r) => (r.accounts || []).length,
    cell: (r) => html`<span style="color:var(--soft);word-break:break-all"
      title="a box can bill more than one account, and each is anchored on its own factor">
      ${(r.accounts || []).map((s) => s.account).join(', ') || '—'}</span>`
  },
  rawCol,
  anchoredCol
];

export { prColumns, ticketColumns, boxColumns };

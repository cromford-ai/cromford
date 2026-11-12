import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, Legend } from '../ui/primitives.js';
import { UsdCell } from '../ui/UsdCell.js';
import { fmtUsd, fmtNum, minutesSince, safeHttpsUrl } from '../lib/format.js';
import {
  perRepo, weeklyBurn, findingRows, costRows, summarise,
  outcomeLabel, outcomeTone, pct
} from '../lib/outcomes.js';

// OUTCOMES is the screen for the only question the rest of Mission Control does
// not ask: did the work HOLD? Everything else here counts activity — builds
// run, PRs opened, dollars spent. This counts what came BACK: the merges that
// were reverted, the tickets that reopened, the mains that went red, and what
// each of those landings cost.
//
// It is also where the steering rule shows its work. bin/review-tighten.sh
// parks a repo whose trailing-window revert/reopen rate crosses its threshold,
// and the GATE column is that flag, read straight off the row the detector
// wrote. This screen NEVER recomputes the decision — the rule lives in one
// script and the payload here is read-only (the Pages Function is GET-only, so
// a dashboard cannot flip its own gate).

const REFRESH_MS = 60000;
const WINDOWS = [7, 14, 30];
const DEFAULT_DAYS = 14;

const TONE_CLASS = { warn: 'tag tag--warn', dead: 'tag tag--dead', muted: 'tag' };

// Anything at or above this is worth a colour on a rate cell. It is a READING
// aid and deliberately not the gate's threshold: the gate's number is per repo
// and lives on its row, and hard-coding it here would be a second copy of a
// DB-driven parameter.
const RATE_WARN = 0.1;

// What each header means, said once under the stats instead of in hover text.
const OUTCOMES_LEGEND = [
  { term: 'DID NOT HOLD (RATE)', text: 'Merges that were reverted or reopened, counted once per PR, out of all merges. Main going red is counted beside it, not in it.' },
  { term: 'MAIN RED', text: 'Merges in the window whose own checks on main went red.' },
  { term: 'COST PER PR', text: 'Spend over the priced PRs only. A repo with none priced shows no figure.' },
  { term: 'GATE', text: 'PARKED: the review gate holds this repo\'s merges for review. AUTO-MERGE: it merges on its own. NOT MEASURED: bin/review-tighten.sh has not measured it yet.' },
  { term: 'THRESHOLD', text: 'The not-held rate at which the gate parks a repo. It clears at the lower rate in the row.' },
  { term: 'TREND', text: 'This week\'s spend as a bar against the biggest week shown.' },
  { term: 'API CALLS', text: 'API calls the orchestrator made that week.' },
  { term: 'PEAK CACHE READ', text: 'The biggest cache read of any single API call that week, in tokens. It is the runaway-session signal, not volume.' }
];

const rateCell = (r) => {
  if (r === null || r === undefined) return html`<span class="na">—</span>`;
  const hot = Number(r) >= RATE_WARN;
  return html`<span class="num" style=${hot ? 'color:var(--amber)' : ''}>${pct(r)}</span>`;
};

const numCell = (n, tone) =>
  !n ? html`<span class="na">0</span>` : html`<span class="num" style=${tone ? `color:${tone}` : ''}>${n}</span>`;

// Every identity cell goes somewhere. A PR's home is GitHub (this console has
// no screen for a PR it only knows by url), the job's is the JOBS screen, and a
// repo's is this screen filtered to it.
const prCell = (row) => {
  const href = safeHttpsUrl(row.pr);
  const label = row.repo && row.number ? `${row.repo.split('/')[1]} #${row.number}` : row.pr;
  return href
    ? html`<a href=${href} target="_blank" rel="noopener noreferrer" class="cell-name">${label}</a>`
    : html`<span class="na">${label}</span>`;
};

export function OutcomesScreen() {
  const repo = useSearchParam('repo');
  const daysParam = Number(useSearchParam('days'));
  const days = WINDOWS.includes(daysParam) ? daysParam : DEFAULT_DAYS;
  const out = useApi(() => api.outcomes(), [], { intervalMs: REFRESH_MS });

  const setFilter = (key, value) => {
    const next = { repo, days: days === DEFAULT_DAYS ? null : String(days), [key]: value };
    const q = new URLSearchParams();
    if (next.repo) q.set('repo', next.repo);
    if (next.days) q.set('days', next.days);
    const qs = q.toString();
    navigate(`/outcomes${qs ? `?${qs}` : ''}`);
  };
  return html`<${OutcomesView} out=${out} repo=${repo} days=${days} setFilter=${setFilter}/>`;
}

// Prop-driven so a test can render it with a fixed clock (BH-3570).
export function OutcomesView({ out, repo, days, setFilter, nowMs = Date.now() }) {
  const data = out.data || {};
  const gates = data.gates || [];
  const allRepoRows = perRepo(
    { merges: data.merges, outcomes: data.outcomes, prCosts: data.pr_costs, gates },
    days, nowMs
  );
  const repoRows = allRepoRows.filter((r) => !repo || r.repo === repo);
  const s = summarise(repoRows, repo ? gates.filter((g) => g.repo === repo) : gates);
  const weeks = weeklyBurn(data.burn_days);
  const findings = findingRows({ outcomes: data.outcomes, prCosts: data.pr_costs, merges: data.merges })
    .filter((f) => !repo || f.repo === repo);
  const costs = costRows({ prCosts: data.pr_costs, merges: data.merges, outcomes: data.outcomes }, days, nowMs)
    .filter((c) => !repo || c.repo === repo);
  const gateRows = (repo ? gates.filter((g) => g.repo === repo) : gates);
  const chip = (label, active, onClick) => html`
    <button type="button" class=${active ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;

  const repoColumns = [
    {
      key: 'repo', label: 'REPO', sort: (r) => r.repo,
      cell: (r) => html`<${Link} to=${`/outcomes?repo=${encodeURIComponent(r.repo)}${days === DEFAULT_DAYS ? '' : `&days=${days}`}`} class="cell-name">${r.repo}<//>`
    },
    { key: 'merged', label: 'MERGED', sort: (r) => r.merged, align: 'right', cell: (r) => numCell(r.merged) },
    { key: 'reverted', label: 'REVERTED', sort: (r) => r.reverted, align: 'right', cell: (r) => numCell(r.reverted, 'var(--red-lt)') },
    { key: 'reopened', label: 'REOPENED', sort: (r) => r.reopened, align: 'right', cell: (r) => numCell(r.reopened, 'var(--red-lt)') },
    { key: 'mainRed', label: 'MAIN RED', unit: `${days}d`, sort: (r) => r.mainRed, align: 'right', cell: (r) => numCell(r.mainRed, 'var(--amber)') },
    {
      key: 'rate', label: 'DID NOT HOLD', unit: '%', raw: 'RATE', sort: (r) => r.rate, align: 'right',
      cell: (r) => rateCell(r.rate)
    },
    {
      key: 'costPerPr', label: 'COST PER PR', sort: (r) => r.costPerPr, align: 'right',
      cell: (r) => (r.costPerPr === null
        ? html`<span class="na" title="none of this repo's merges in the window have a priced row yet">—</span>`
        : html`<span class="num" title=${`${fmtUsd(r.costUsd)} over ${fmtNum(r.pricedPrs)} priced PR${r.pricedPrs === 1 ? '' : 's'} of ${fmtNum(r.merged)} merged`}><${UsdCell} value=${r.costPerPr} basis="api"/></span>`)
    },
    {
      key: 'costUsd', label: 'SPEND', sort: (r) => r.costUsd, align: 'right',
      cell: (r) => (r.costUsd === null ? html`<span class="na">—</span>` : html`<${UsdCell} value=${r.costUsd} basis="api"/>`)
    },
    {
      key: 'tightened', label: 'GATE', sort: (r) => (r.tightened ? 0 : r.gate ? 1 : 2),
      cell: (r) => (r.tightened
        ? html`<span class="pill pill--warn" title=${(r.gate && r.gate.evidence) || 'parked by bin/review-tighten.sh'}>PARKED</span>`
        : r.gate
          ? html`<span class="pill" title=${r.gate.evidence || ''}>AUTO-MERGE</span>`
          : html`<span class="pill pill--muted" title="bin/review-tighten.sh has not measured this repo yet — no gate row">NOT MEASURED</span>`)
    }
  ];

  const gateColumns = [
    {
      key: 'repo', label: 'REPO', sort: (r) => r.repo,
      cell: (r) => html`<${Link} to=${`/outcomes?repo=${encodeURIComponent(r.repo)}`} class="cell-name">${r.repo}<//>`
    },
    {
      key: 'tightened', label: 'GATE', sort: (r) => Number(r.tightened) === 1 ? 0 : 1,
      cell: (r) => (Number(r.tightened) === 1
        ? html`<span class="pill pill--warn">PARKED</span>`
        : html`<span class="pill">AUTO-MERGE</span>`)
    },
    {
      key: 'rate', label: 'DID NOT HOLD', unit: '%', raw: 'RATE', sort: (r) => r.rate, align: 'right',
      cell: (r) => rateCell(r.rate)
    },
    {
      key: 'bad', label: 'BAD / MERGED', sort: (r) => r.bad, align: 'right',
      cell: (r) => html`<span class="num">${r.bad ?? '—'} / ${r.merges ?? '—'}</span>`
    },
    {
      key: 'tighten_rate', label: 'THRESHOLD', unit: 'parks at', sort: (r) => r.tighten_rate, align: 'right',
      cell: (r) => html`<span class="num" title=${`clears at or under ${pct(r.clear_rate)} · needs ${r.min_merges} merges to mean anything · from the ${r.threshold_scope} threshold row`}>
        ≥ ${pct(r.tighten_rate)}</span>`
    },
    {
      key: 'window_days', label: 'WINDOW', sort: (r) => r.window_days, align: 'right',
      cell: (r) => html`<span class="num">${r.window_days ?? '—'}d</span>`
    },
    {
      key: 'decision', label: 'LAST CALL', sort: (r) => r.decision,
      cell: (r) => html`<span class=${TONE_CLASS[r.decision === 'tighten' ? 'warn' : 'muted']}>${String(r.decision || '—').toUpperCase()}</span>`
    },
    {
      key: 'evidence', label: 'EVIDENCE', sort: null,
      cell: (r) => html`<span class="cell-wrap" style="max-width:52ch;color:var(--faint)">${r.evidence || '—'}</span>`
    },
    {
      key: 'updated_at', label: 'MEASURED', sort: (r) => minutesSince(r.updated_at), align: 'right',
      // The detector is a daily cron, so a row older than ~two days means it
      // stopped running — which is worth a colour, because a stale gate is a
      // gate nobody is maintaining.
      cell: (r) => html`<span title=${r.updated_at}><${Age} min=${minutesSince(r.updated_at)} warnAt=${2880}/></span>`
    }
  ];

  const weekColumns = [
    {
      key: 'week', label: 'WEEK OF', sort: (r) => r.week,
      // The one identity cell in this console that is deliberately not a link:
      // there is no per-week screen to open, and a WEEK OF cell pointing at the
      // whole-fleet COSTS page would be a link that goes to the wrong place,
      // which is worse than none. Marked in the DOM so the no-dead-rows drive
      // can tell an intentional flat cell from an oversight.
      cell: (r) => html`<span class="cell-name" data-flat="no per-week detail view exists in this console">${r.week}</span>`
    },
    {
      key: 'usd', label: 'API-EQUIV', sort: (r) => r.usd, align: 'right',
      cell: (r) => html`<${UsdCell} value=${r.usd} basis="api"/>`
    },
    {
      key: 'trend', label: 'TREND', sort: null,
      cell: (r) => html`<div class="meter" style="min-width:80px" title=${`${fmtUsd(r.usd)} over ${fmtNum(r.days)} measured day${r.days === 1 ? '' : 's'}`}>
        <div class=${r.share > 0.8 ? 'meter__fill meter__fill--hi' : 'meter__fill'} style=${`width:${Math.round(r.share * 100)}%`}></div>
      </div>`
    },
    {
      key: 'deltaPct', label: 'VS PRIOR', sort: (r) => r.deltaPct, align: 'right',
      cell: (r) => (r.deltaPct === null
        ? html`<span class="na" title="only compared when both weeks have all seven days measured — a missing day would read as a cheap week">—</span>`
        : html`<span class="num" style=${r.deltaPct > 0 ? 'color:var(--amber)' : ''}>
            ${r.deltaPct > 0 ? '+' : ''}${fmtNum(r.deltaPct * 100, { decimals: 0 })}%</span>`)
    },
    {
      key: 'days', label: 'DAYS', sort: (r) => r.days, align: 'right',
      cell: (r) => (r.complete
        ? html`<span class="num">7</span>`
        : html`<span class="num" style="color:var(--amber)" title="this week is partial — either it is still running or the burn tracker missed days">${r.days}</span>`)
    },
    {
      key: 'apiCalls', label: 'API CALLS', sort: (r) => r.apiCalls, align: 'right',
      cell: (r) => html`<span class="num">${r.apiCalls.toLocaleString()}</span>`
    },
    {
      key: 'peakCacheRead', label: 'PEAK CACHE READ', sort: (r) => r.peakCacheRead, align: 'right',
      cell: (r) => html`<span class="num" title="the runaway-session signal, not the volume one">${r.peakCacheRead.toLocaleString()}</span>`
    }
  ];

  const findingColumns = [
    // The PR leads, because it is what this row IS and it is the thing you
    // click. A DAY column in front of it would be a dead identity cell.
    { key: 'pr', label: 'PR', sort: (r) => r.number, cell: prCell },
    { key: 'day', label: 'DAY', sort: (r) => r.day, cell: (r) => html`<span class="num">${r.day || '—'}</span>` },
    {
      key: 'repo', label: 'REPO', sort: (r) => r.repo,
      cell: (r) => (r.repo
        ? html`<${Link} to=${`/outcomes?repo=${encodeURIComponent(r.repo)}`} class="cell-name">${r.repo}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'outcome', label: 'OUTCOME', sort: (r) => r.outcome,
      cell: (r) => html`<span class=${TONE_CLASS[outcomeTone(r.outcome)]}>${outcomeLabel(r.outcome)}</span>`
    },
    {
      key: 'costUsd', label: 'COST', sort: (r) => r.costUsd, align: 'right',
      cell: (r) => (r.costUsd === null ? html`<span class="na">—</span>` : html`<${UsdCell} value=${r.costUsd} basis="api"/>`)
    },
    {
      key: 'jobId', label: 'JOB', sort: (r) => r.jobId,
      cell: (r) => (r.jobId
        ? html`<${Link} to=${`/jobs/${encodeURIComponent(r.jobId)}`} class="cell-name">${r.jobId}<//>`
        : html`<span class="na" title="the merge ledger has no job for this PR — merged before the coordination DB, or by hand">—</span>`)
    },
    {
      key: 'evidence', label: 'EVIDENCE', sort: null,
      cell: (r) => html`<span class="cell-wrap" style="max-width:56ch;color:var(--faint)">${r.evidence || '—'}</span>`
    }
  ];

  const costColumns = [
    {
      key: 'pr', label: 'PR', sort: (r) => r.number, cell: prCell
    },
    {
      key: 'repo', label: 'REPO', sort: (r) => r.repo,
      cell: (r) => (r.repo
        ? html`<${Link} to=${`/outcomes?repo=${encodeURIComponent(r.repo)}`} class="cell-name">${r.repo}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'costUsd', label: 'COST', sort: (r) => r.costUsd, align: 'right',
      cell: (r) => (r.costUsd === null ? html`<span class="na">—</span>` : html`<${UsdCell} value=${r.costUsd} basis="api"/>`)
    },
    {
      key: 'outcomes', label: 'HELD?', sort: (r) => r.outcomes.length,
      cell: (r) => (r.outcomes.length
        ? html`<span style="display:inline-flex;gap:4px;flex-wrap:wrap">
            ${r.outcomes.map((o) => html`<span key=${o} class=${TONE_CLASS[outcomeTone(o)]}>${outcomeLabel(o)}</span>`)}
          </span>`
        : html`<span class="tag tag--green">HELD</span>`)
    },
    {
      key: 'stageBreakdown', label: 'STAGES', sort: null,
      cell: (r) => html`<span class="cell-wrap" style="max-width:44ch;color:var(--faint)">${r.stageBreakdown || '—'}</span>`
    },
    {
      key: 'jobId', label: 'JOB', sort: (r) => r.jobId,
      cell: (r) => (r.jobId
        ? html`<${Link} to=${`/jobs/${encodeURIComponent(r.jobId)}`} class="cell-name">${r.jobId}<//>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'mergedAt', label: 'MERGED', sort: (r) => minutesSince(r.mergedAt), align: 'right',
      cell: (r) => html`<span title=${r.mergedAt || ''}><${Age} min=${minutesSince(r.mergedAt)} warnAt=${100000}/></span>`
    }
  ];

  const loading = out.loading && !out.data;
  const failed = out.error && !out.data;

  return html`
    <div class="page">
      <${PageHeadline} chip="Outcomes"
        line1=${out.data ? `${s.merged} merged in ${days} days. ${s.bad} did not hold.` : failed ? 'The outcomes read failed.' : 'Reading the outcomes.'}
        line2=${out.data ? `Main went red ${fmtNum(s.mainRed)} ${s.mainRed === 1 ? 'time' : 'times'}.` : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span style="font-size:11px;color:var(--faint)">
          did the work hold? Merges that were reverted or reopened, what they cost,
          and which repos the review gate has parked. Read-only — the gate is
          decided by <code>bin/review-tighten.sh</code>, never from this page.
        </span>
      </div>

      <div class="stats stats--6">
        <${Stat} label=${`MERGED · ${days}D`} value=${out.data ? s.merged : '…'}/>
        <${Stat} label="DID NOT HOLD" value=${out.data ? s.bad : '…'} tone=${s.bad ? 'warn' : null}/>
        <${Stat} label="REVERT/REOPEN RATE" value=${out.data ? pct(s.rate) : '…'} tone=${s.rate !== null && s.rate >= RATE_WARN ? 'warn' : null}/>
        <${Stat} label="MAIN WENT RED" value=${out.data ? s.mainRed : '…'}/>
        <${Stat} label="COST PER PR" value=${out.data ? html`<${UsdCell} value=${s.costPerPr} basis="api"/>` : '…'}/>
        <${Stat} label="REPOS PARKED" value=${out.data ? s.tightened : '…'} tone=${s.tightened ? 'warn' : null}/>
      </div>
      <${Legend} items=${OUTCOMES_LEGEND}/>

      ${out.data && out.data.degraded && out.data.degraded.length ? html`
        <div class="banner banner--warn">
          <span>Part of this view could not be read: <b>${out.data.degraded.join(' · ')}</b>.
            The tables below are missing whatever that read carries — they are not empty because nothing happened.</span>
        </div>` : null}

      <${Section} title="WINDOW" note="the view window, in the URL, so a filtered view is a link you can send">
        <div class="tabs" style="margin-bottom:8px">
          ${WINDOWS.map((d) => chip(`LAST ${d}D`, days === d, () => setFilter('days', d === DEFAULT_DAYS ? null : String(d))))}
        </div>
        <div class="tabs">
          ${chip('ALL REPOS', !repo, () => setFilter('repo', null))}
          ${allRepoRows.map((r) => chip(r.repo, repo === r.repo, () => setFilter('repo', r.repo)))}
        </div>
      <//>

      <${Section} title="REVIEW GATE"
        note=${gateRows.length
          ? `${fmtNum(gateRows.filter((g) => Number(g.tightened) === 1).length)} parked of ${fmtNum(gateRows.length)} measured · thresholds are DB rows, not code`
          : 'the steering rule has not written a measurement yet'}>
        ${loading
          ? html`<${Skeleton} rows=${2} height=${20}/>`
          : html`<${SortableTable} columns=${gateColumns} rows=${gateRows}
              rowKey=${(r) => r.repo}
              rowClass=${(r) => (Number(r.tightened) === 1 ? 'row--warn' : '')}
              defaultSort="tightened" defaultDir="asc"
              empty=${html`<${Empty} title="NO GATE MEASUREMENT YET"
                note="bin/review-tighten.sh writes a row per repo every run (hub, daily 05:45Z). Nothing here means it has not run since this shipped, or it found no merged-PR ledger to measure against — it never guesses a rate."/>`}/>`}
      <//>

      <${Section} title="PER REPO"
        note=${out.data ? `${fmtNum(repoRows.length)} repo${repoRows.length === 1 ? '' : 's'} landed something in the last ${days} days` : 'loading'}>
        ${loading
          ? html`<${Skeleton} rows=${5} height=${20}/>`
          : failed
            ? html`<${ErrorBox} error=${out.error} onRetry=${out.reload}/>`
            : html`<${SortableTable} columns=${repoColumns} rows=${repoRows}
                rowKey=${(r) => r.repo}
                rowClass=${(r) => (r.tightened ? 'row--warn' : '')}
                defaultSort="rate" defaultDir="desc"
                empty=${html`<${Empty} title="NOTHING MERGED IN THIS WINDOW"
                  note=${`No PR in the harness-jobs merge ledger landed in the last ${days} days${repo ? ` for ${repo}` : ''}. A wider window may show more.`}/>`}/>`}
      <//>

      <${Section} title="WEEKLY BURN"
        note="the orchestrator's API-equivalent burn, bucketed by UTC week — a partial week says so rather than reading as a cheap one">
        ${loading
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : html`<${SortableTable} columns=${weekColumns} rows=${weeks}
              rowKey=${(r) => r.week}
              defaultSort="week" defaultDir="desc"
              empty=${html`<${Empty} title="NO BURN ROWS"
                note="bin/orchestrator-burn.sh pushes one row per UTC day to the metrics ledger. An empty table means none have landed."/>`}/>`}
      <//>

      <${Section} title="WHAT CAME BACK"
        note=${out.data ? `${fmtNum(findings.length)} finding${findings.length === 1 ? '' : 's'} on record · every row opens its PR` : 'loading'}>
        ${loading
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : html`<${SortableTable} columns=${findingColumns} rows=${findings}
              rowKey=${(r) => `${r.repo}:${r.pr}:${r.outcome}`}
              rowClass=${(r) => (outcomeTone(r.outcome) === 'dead' ? 'row--warn' : '')}
              defaultSort="day" defaultDir="desc"
              empty=${html`<${Empty} title="NOTHING CAME BACK"
                note="bin/outcome-metrics.sh has recorded no revert, reopen or red main for these merges. It runs Mondays 05:20Z and rechecks recent merges for a week, so the newest landings may simply not have been asked about yet."/>`}/>`}
      <//>

      <${Section} title="WHAT THE LANDINGS COST"
        note=${out.data ? `priced merges in the last ${days} days, dearest first` : 'loading'}>
        ${loading
          ? html`<${Skeleton} rows=${5} height=${20}/>`
          : html`<${SortableTable} columns=${costColumns} rows=${costs}
              rowKey=${(r) => r.pr}
              rowClass=${(r) => (r.outcomes.length ? 'row--warn' : '')}
              defaultSort="costUsd" defaultDir="desc"
              empty=${html`<${Empty} title="NO PRICED MERGES IN THIS WINDOW"
                note="bin/cost-rollup.sh prices a PR from its build directories. A merge with no priced row is one it could not attribute, not a free one."/>`}/>`}
      <//>
    </div>`;
}

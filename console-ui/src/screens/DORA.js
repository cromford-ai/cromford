import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, ProjectLink } from '../ui/primitives.js';
import { safeHttpsUrl, minutesSince, fmtNum } from '../lib/format.js';
import {
  projectRows, slowRows, basisNote, fmtSeconds, fmtRate, fmtFrequency, isThin, THIN_SAMPLE
} from '../lib/dora.js';

// DORA is the screen for the question no other tab asks: where is the TIME
// going? FLEET says what the machines are, NOW says what they are doing,
// OUTCOMES says whether the work held — and none of them can tell you that a
// change takes four days from ticket to main and three of those are spent
// approved, waiting to merge.
//
// EVERY NUMBER NAMES ITS SOURCE. The worker computes each metric and ships an
// `evidence` string with it (which table, which column, which join); this
// screen renders that string in the cell's title and never recomputes a metric
// of its own. A panel deriving its own figures beside an endpoint deriving
// different ones is two answers to one question.
//
// AND IT SAYS WHERE EACH CLOCK STOPS. bin/deploy-train.sh now records every
// verified production departure as a `deploy` ledger row, so lead time ends at
// production and LANDINGS counts departures FOR THE PROJECTS THAT RUN A TRAIN.
// A project without one still ends at the merge, and both facts are a banner on
// this page rather than a footnote — the alternative is one column meaning two
// different things, which is a number people act on that means something other
// than what it says.

const REFRESH_MS = 60000;
const WINDOWS = [7, 14, 30];
const DEFAULT_DAYS = 14;

// A reading aid, not a gate. Deliberately NOT the review gate's threshold: that
// number is a DB row that parks repos, and a second copy of it here would drift
// from the one that binds.
const CFR_WARN = 0.15;

// A duration with no samples behind it renders as `—`, never "0s". Zero is the
// most flattering wrong answer a lead-time cell can give.
const dur = (s, n, evidence) => (!n
  ? html`<span class="na" title=${evidence || 'not measurable in this window'}>—</span>`
  : html`<span class="num" title=${evidence || ''}>${fmtSeconds(s)}</span>`);

// `noun` is [singular, plural]: a count reads "8 merges", but 0 stays a bare 0.
const sampleCell = (n, what, noun) => {
  if (!n) return html`<span class="na" title=${`nothing ${what} could be measured in this window`}>0</span>`;
  const text = noun ? `${fmtNum(n)} ${n === 1 ? noun[0] : noun[1]}` : n;
  return isThin(n)
    ? html`<span class="num" style="color:var(--amber)"
        title=${`only ${fmtNum(n)} sample${n === 1 ? '' : 's'} — under ${THIN_SAMPLE} a p90 is just the slowest one of them`}>${text}</span>`
    : html`<span class="num">${text}</span>`;
};

// Every sort accessor below is the RAW number, never the formatted string:
// sorting on "2h" vs "3d" is alphabetical and produces a table whose header
// arrow points one way while the rows say another.
export function projectColumns(ev, days) {
  return [
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => (r.project
        ? html`<${ProjectLink} project=${r.project}/>`
        : html`<span class="na" title="no job artifact and no merge-queue row names a project for this repo">unattributed</span>`)
    },
    {
      key: 'leadP50', label: 'TIME FROM START TO MERGE, MEDIAN', raw: 'LEAD p50', sort: (r) => r.leadP50, align: 'right',
      cell: (r) => dur(r.leadP50, r.leadN, ev('lead_time'))
    },
    {
      key: 'leadP90', label: 'TIME FROM START TO MERGE, SLOWEST 1 IN 10', raw: 'LEAD p90', sort: (r) => r.leadP90, align: 'right',
      cell: (r) => dur(r.leadP90, r.leadN, ev('lead_time'))
    },
    {
      key: 'leadN', label: 'BASED ON', unit: 'merges', raw: 'LEAD n', sort: (r) => r.leadN, align: 'right',
      cell: (r) => html`<span title=${basisNote(r)}>${sampleCell(r.leadN, 'a lead time', ['merge', 'merges'])}</span>`
    },
    {
      key: 'perDay', label: 'MERGES PER DAY', raw: 'LANDINGS', sort: (r) => r.perDay, align: 'right',
      // The title is the worker's own basis string, not a sentence of this
      // screen's: the figure means verified production departures for a project
      // whose deploy train records them and merges for one that has none, and a
      // hardcoded label can only ever be right about one of those.
      cell: (r) => html`<span class="num"
        title=${`${r.freqDeployVerified
          ? `${fmtNum(r.freqCount)} verified departure${r.freqCount === 1 ? '' : 's'} carrying ${fmtNum(r.merged)} merge${r.merged === 1 ? '' : 's'}${r.freqFailed ? `, ${fmtNum(r.freqFailed)} that never arrived` : ''}`
          : `${fmtNum(r.merged)} merge${r.merged === 1 ? '' : 's'}`} over ${days}d — ${r.freqBasis || ''}. ${ev('deployment_frequency')}`}>
        ${fmtFrequency(r.perDay)}</span>`
    },
    {
      key: 'cfr', label: 'FAILED CHANGES', unit: '%', raw: 'CHANGE FAIL', sort: (r) => r.cfr, align: 'right',
      cell: (r) => (r.cfr === null
        ? html`<span class="na" title="nothing merged in this window, so there is no rate to have">—</span>`
        : html`<span class="num" style=${r.cfr >= CFR_WARN ? 'color:var(--amber)' : ''}
            title=${`${r.bad} of ${r.merged} merges did not hold — reverted or reopened, counted once per PR. ${r.mainRed} main-red reported separately and NOT in this rate. ${ev('change_failure')}`}>
            ${fmtRate(r.cfr)}</span>`)
    },
    {
      key: 'ttrP50', label: 'TIME TO RESTORE, MEDIAN', raw: 'RESTORE p50', sort: (r) => r.ttrP50, align: 'right',
      cell: (r) => dur(r.ttrP50, r.ttrN, ev('time_to_restore'))
    },
    {
      key: 'ttrP90', label: 'TIME TO RESTORE, SLOWEST 1 IN 10', raw: 'RESTORE p90', sort: (r) => r.ttrP90, align: 'right',
      cell: (r) => dur(r.ttrP90, r.ttrN, ev('time_to_restore'))
    },
    {
      key: 'unrestored', label: 'OPEN FAILURES', raw: 'OPEN FAIL', sort: (r) => r.unrestored, align: 'right',
      cell: (r) => (r.unrestored
        ? html`<span class="num" style="color:var(--red-lt)"
            title="failures with nothing merged into that repo since — NOT restored, rather than restored instantly">${r.unrestored}</span>`
        : html`<span class="na">0</span>`)
    },
    {
      key: 'laneP50', label: 'APPROVAL TO MERGE, MEDIAN', raw: 'APPROVE→MERGE p50', sort: (r) => r.laneP50, align: 'right',
      cell: (r) => dur(r.laneP50, r.laneN, ev('merge_lane'))
    },
    {
      key: 'laneP90', label: 'APPROVAL TO MERGE, SLOWEST 1 IN 10', raw: 'APPROVE→MERGE p90', sort: (r) => r.laneP90, align: 'right',
      cell: (r) => dur(r.laneP90, r.laneN, ev('merge_lane'))
    },
    {
      key: 'laneN', label: 'BASED ON', unit: 'approvals', raw: 'LANE n', sort: (r) => r.laneN, align: 'right',
      cell: (r) => sampleCell(r.laneN, 'a merge lane', ['approval', 'approvals'])
    }
  ];
}

export function slowColumns() {
  return [
    {
      key: 'pr', label: 'PR', sort: (r) => r.leadS,
      cell: (r) => {
        const href = safeHttpsUrl(r.pr);
        const label = r.repo && r.number ? `${r.repo.split('/')[1]} #${r.number}` : (r.pr || '—');
        return href
          ? html`<a href=${href} target="_blank" rel="noopener noreferrer" class="cell-name">${label}</a>`
          : html`<span class="na">${label}</span>`;
      }
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => (r.project ? html`<${ProjectLink} project=${r.project}/>` : html`<span class="na">—</span>`)
    },
    {
      key: 'leadS', label: 'TIME FROM START TO MERGE', raw: 'LEAD', sort: (r) => r.leadS, align: 'right',
      // Both ends of the clock in one title. Two rows in this list can stop on
      // different ones, so neither half may be assumed from the table's header.
      cell: (r) => html`<span class="num"
        title=${`${r.basis === 'pr_first_seen'
          ? 'from when the merge conductor first saw this PR — no build job claims it'
          : 'from when the build job was created'} → ${r.end === 'deploy_verified'
            ? `production verified serving it at ${r.deployedAt || 'the recorded departure'}`
            : 'the merge (no verified production departure recorded for it)'}`}>${fmtSeconds(r.leadS)}</span>`
    },
    {
      key: 'laneS', label: 'APPROVAL TO MERGE', raw: 'APPROVE→MERGE', sort: (r) => r.laneS, align: 'right',
      cell: (r) => (r.laneS === null
        ? html`<span class="na" title="no APPROVE verdict artifact is bound to this PR's job — merged by hand, or approved before that artifact existed">—</span>`
        : html`<span class="num">${fmtSeconds(r.laneS)}</span>`)
    },
    {
      key: 'ticketId', label: 'TICKET', sort: (r) => r.ticketId,
      cell: (r) => (r.ticketId && r.project
        ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.ticketId}<//>`
        : html`<span class="na">${r.ticketId || '—'}</span>`)
    },
    {
      key: 'jobId', label: 'JOB', sort: (r) => r.jobId,
      cell: (r) => (r.jobId
        ? html`<${Link} to=${`/jobs/${encodeURIComponent(r.jobId)}`} class="cell-name">${r.jobId}<//>`
        : html`<span class="na" title="no coordination job recorded this PR — opened by hand, or before the jobs DB">—</span>`)
    },
    {
      key: 'mergedAt', label: 'MERGED', sort: (r) => minutesSince(r.mergedAt), align: 'right',
      cell: (r) => html`<span class="num" title=${r.mergedAt || ''}>${(r.mergedAt || '—').slice(0, 10)}</span>`
    }
  ];
}

// The two tables are EXPORTED components rather than inline markup so a test
// can render the real thing and read the HTML back — "the headers sort and
// every identity cell links" becomes a thing observed, not assumed. Same
// pattern as KANBAN's PipelineList.
export function DoraProjectTable({ rows, days = DEFAULT_DAYS, evidence = {}, empty }) {
  const ev = (k) => (evidence[k] && evidence[k].evidence) || '';
  return html`<${SortableTable} columns=${projectColumns(ev, days)} rows=${rows}
    rowKey=${(r) => r.project || 'unattributed'}
    rowClass=${(r) => (r.cfr !== null && r.cfr >= CFR_WARN ? 'row--warn' : '')}
    defaultSort="leadP90" defaultDir="desc"
    empty=${empty}/>`;
}

export function DoraSlowestTable({ rows, empty }) {
  return html`<${SortableTable} columns=${slowColumns()} rows=${rows}
    rowKey=${(r) => r.pr}
    defaultSort="leadS" defaultDir="desc"
    empty=${empty}/>`;
}

export function DORAScreen() {
  const project = useSearchParam('project');
  const daysParam = Number(useSearchParam('days'));
  const days = WINDOWS.includes(daysParam) ? daysParam : DEFAULT_DAYS;

  // The window is a SERVER parameter, not a client filter: the worker's
  // percentiles are computed over it, so changing it has to refetch. It rides
  // in the deps so useApi clears the old answer rather than showing 30-day
  // numbers under a 7-day heading while the refetch runs.
  const out = useApi(() => api.dora({ days }), [days], { intervalMs: REFRESH_MS });

  const data = out.data || {};
  const allRows = projectRows(data);
  const rows = allRows.filter((r) => !project || r.project === project);
  const slow = slowRows(rows, { limit: project ? 25 : 10 });
  const totals = data.totals || {};
  const gaps = data.gaps || [];
  // Which projects on screen actually reach production. Named, not implied:
  // "some of these are deploy-verified" is not something a reader can act on.
  const deployed = rows.filter((r) => r.deployVerified && r.project).map((r) => r.project);
  // The evidence strings are identical on every project row (they name tables,
  // not values), so the first row is the whole vocabulary.
  const evidence = (data.projects && data.projects[0]) || {};

  const setFilter = (key, value) => {
    const next = { project, days: days === DEFAULT_DAYS ? null : String(days), [key]: value };
    const q = new URLSearchParams();
    if (next.project) q.set('project', next.project);
    if (next.days) q.set('days', next.days);
    const qs = q.toString();
    navigate(`/dora${qs ? `?${qs}` : ''}`);
  };
  const chip = (label, active, onClick) => html`
    <button type="button" class=${active ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;

  const loading = out.loading && !out.data;
  const failed = out.error && !out.data;
  const cfrTotal = totals.change_failure_rate;

  return html`
    <div class="page">
      <${PageHeadline} chip="DORA"
        line1=${out.data ? `${totals.merged ?? 0} merged in ${days} days. ${fmtFrequency(totals.deploys_per_day)} a day.` : failed ? 'The DORA read failed.' : 'Reading the delivery numbers.'}
        line2=${out.data ? `Median start to merge: ${fmtSeconds(totals.lead_time && totals.lead_time.p50_s)}.` : ''}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span style="font-size:11px;color:var(--faint)">
          where the time goes. Lead time, how often we land, how often a landing
          comes back, how long until the next one — per project, over a window,
          each number naming the table it came from.
        </span>
      </div>

      <div class="stats stats--6">
        <${Stat} label=${`MERGED · ${days}D`} value=${out.data ? (totals.merged ?? 0) : '…'}/>
        <${Stat} label="START TO MERGE, MEDIAN" value=${out.data ? fmtSeconds(totals.lead_time && totals.lead_time.p50_s) : '…'} tone="sm"/>
        <${Stat} label="START TO MERGE, SLOWEST 1 IN 10" value=${out.data ? fmtSeconds(totals.lead_time && totals.lead_time.p90_s) : '…'} tone="sm"/>
        <${Stat} label="MERGES PER DAY" value=${out.data ? fmtFrequency(totals.deploys_per_day) : '…'} tone="sm"/>
        <${Stat} label="FAILED CHANGES" value=${out.data ? fmtRate(cfrTotal) : '…'}
          tone=${cfrTotal !== null && cfrTotal !== undefined && cfrTotal >= CFR_WARN ? 'warn' : null}/>
        <${Stat} label="APPROVAL TO MERGE, MEDIAN"
          value=${out.data ? fmtSeconds(totals.merge_lane && totals.merge_lane.p50_s) : '…'} tone="sm"/>
      </div>

      ${out.data ? (deployed.length
        ? html`
          <div class="banner">
            <span>
              <b>${deployed.join(', ')} measure${deployed.length === 1 ? 's' : ''} to PRODUCTION.</b>
              <code>bin/deploy-train.sh</code> records each verified departure, so for those
              projects LEAD ends when production actually served the change and LANDINGS counts
              departures rather than merges. Every other project still ends at the merge —
              the BASED ON column says how many merges each figure uses. ${fmtNum(gaps.length)} gap${gaps.length === 1 ? '' : 's'} named at the bottom of this page.
            </span>
          </div>`
        : html`
          <div class="banner banner--warn">
            <span>
              <b>These end at the MERGE, not at the deploy.</b>
              <code>bin/deploy-train.sh</code> verifies that production serves the merged sha and
              writes a <code>deploy</code> ledger row for it, but no departure was recorded in this
              window. So LEAD stops at main, and LANDINGS counts merges, which OVERCOUNTS departures
              because a train carries a batch. ${fmtNum(gaps.length)} gap${gaps.length === 1 ? '' : 's'} named at the bottom of this page.
            </span>
          </div>`) : null}

      <${Section} title="WINDOW" note="in the URL, so a filtered view is a link you can send">
        <div class="tabs" style="margin-bottom:8px">
          ${WINDOWS.map((d) => chip(`LAST ${d}D`, days === d, () => setFilter('days', d === DEFAULT_DAYS ? null : String(d))))}
        </div>
        <div class="tabs">
          ${chip('ALL PROJECTS', !project, () => setFilter('project', null))}
          ${allRows.filter((r) => r.project).map((r) => chip(r.project, project === r.project, () => setFilter('project', r.project)))}
        </div>
      <//>

      <${Section} title="PER PROJECT"
        note=${out.data
          ? `${fmtNum(rows.length)} project${rows.length === 1 ? '' : 's'} landed something in the last ${days} days · hover any figure for the table it came from`
          : 'loading'}>
        ${loading
          ? html`<${Skeleton} rows=${5} height=${20}/>`
          : failed
            ? html`<${ErrorBox} error=${out.error} onRetry=${out.reload}/>`
            : html`<${DoraProjectTable} rows=${rows} days=${days} evidence=${evidence}
                empty=${html`<${Empty} title="NOTHING LANDED IN THIS WINDOW"
                  note=${`No PR in the harness-jobs merge ledger merged in the last ${days} days${project ? ` for ${project}` : ''}. A wider window may show more — an empty table here is not a fast fleet.`}/>`}/>`}
      <//>

      <${Section} title="SLOWEST CHANGES"
        note=${out.data
          ? `the ${fmtNum(slow.length)} longest lead time${slow.length === 1 ? '' : 's'} on screen · every row opens its PR, its project and the job that built it`
          : 'loading'}>
        ${loading
          ? html`<${Skeleton} rows=${4} height=${20}/>`
          : html`<${DoraSlowestTable} rows=${slow}
              empty=${html`<${Empty} title="NO LEAD TIME MEASURABLE"
                note="A lead time needs a start: the build job that opened the PR, or the conductor's first sighting of it. Merges with neither are excluded rather than counted at zero."/>`}/>`}
      <//>

      <${Section} title="WHAT THIS CANNOT MEASURE YET"
        note="named on purpose — a metric the fleet cannot compute is reported as missing, never estimated">
        ${gaps.length
          ? html`<div style="display:flex;flex-direction:column;gap:10px">
              ${gaps.map((g) => html`
                <div class="banner" key=${g.metric} style="align-items:flex-start">
                  <span>
                    <b>${g.metric}</b> — missing: <b>${g.missing}</b><br/>
                    <span style="color:var(--faint)">${g.why}</span><br/>
                    <span style="color:var(--faint)">would need: ${g.would_need}</span>
                  </span>
                </div>`)}
            </div>`
          : loading
            ? html`<${Skeleton} rows=${2} height=${20}/>`
            : html`<${Empty} title="NO GAPS REPORTED"
                note="The endpoint ships its own gap list. An empty one means every metric above is computed from a real ledger."/>`}
      <//>
    </div>`;
}

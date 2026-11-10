import { html, Link } from '../router.js';
import { TicketKey } from '../ui/TicketKey.js';
import { PageHeadline, SectionHead } from '../ui/line.js';
import { LineBoard } from '../ui/LineBoard.js';
import { jobRows } from '../lib/jobs.js';
import { lineTickets } from '../lib/line.js';
import { nowHeadline } from '../lib/line-screens.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, healthColor, Cursor, Legend } from '../ui/primitives.js';
import { Dot, Clock } from '../ui/icons.js';
import { agoFromMinutes, minutesSince, clockTime, healthFromAge, prNumberFromUrl, whenLabel, countOrNull } from '../lib/format.js';
import { stageProgress, stageLabel, STEPS } from '../lib/stages.js';
import { plainLabel, tierLabel } from '../lib/labels.js';
import {
  runOutcome, outcomeRank, OUTCOME_LABEL, OUTCOME_TONE, rcLabel,
  tickWork, parseTickSummary, diskPercent, diskTone, buildingNow, staleBuilds, needsSplit, JOBS_READ_CAP
} from '../lib/cockpit.js';

// NOW is the port of the old console's home, "Now · Harness". FLEET next door
// answers "are the machines alive"; this answers "what is the harness DOING" —
// the last tick on every board, what is building this minute, and the activity
// feed underneath it. Both are needed and neither is the other, which is why
// this is its own screen rather than more rows on the fleet page.

const REFRESH_MS = 30000;
const TONE_CLASS = { green: 'tag tag--green', dead: 'tag tag--dead', warn: 'tag tag--warn', muted: 'tag tag--idle' };

const BUILDING_LEGEND = [
  { term: 'building', text: 'a build job that beat in the last 10 minutes. One row per ticket, the latest attempt.' },
  { term: 'stale', text: 'a build row with no running job for 10 minutes. Listed on NEEDS. A row that moved in the last 10 minutes is in neither place yet.' },
  { term: 'tier', text: 'auto-merge merges itself once approved; reviewed merge waits for the reviewed-merge sweep.' }
];

// The screen is the two reads; NowView is everything drawn from them, so the
// rules can be rendered against fixtures.
export function NowScreen() {
  const nowData = useApi(() => api.cockpitNow(), [], { intervalMs: REFRESH_MS });
  // BUILDING NOW is the jobs ledger's answer, the same read JOBS makes.
  const jobs = useApi(() => api.jobs({ status: 'running', limit: JOBS_READ_CAP }), [], { intervalMs: REFRESH_MS });
  return html`<${NowView} data=${nowData} jobs=${jobs} nowMs=${Date.now()}/>`;
}

export function NowView({ data: nowData, jobs, nowMs = Date.now() }) {
  const d = nowData.data || {};
  const boards = d.boards || [];
  const builds = d.active_builds || [];
  const runs = d.recent_runs || [];
  const needs = d.needs || {};
  // null until the jobs read answers; a failed read counts nothing and calls
  // nothing stale.
  const bn = jobs.data ? buildingNow(jobs.data, builds) : null;
  const stale = staleBuilds(builds, jobs.data, nowMs);
  const buildingValue = bn ? (bn.capped ? `${bn.count}+` : bn.count)
    : jobs.loading && !jobs.data ? '…' : countOrNull(null);
  // BH-9117: the NEEDS count split by kind; its total is the NEEDS A HUMAN value.
  const split = needsSplit(nowData.data ? needs : null, jobs.data ? stale.length : null);
  const needsTotal = split.total;
  const oldest = runs.length ? runs[runs.length - 1] : null;

  // Every stat gates on the DATA, never on the loading flag: an errored useApi
  // returns {data:null, loading:false}, and falling through to a computed 0
  // would render "0 building" — indistinguishable from an idle fleet when the
  // truth is that the read failed.
  const newestTick = runs.length ? minutesSince(runs[0].finished_at || runs[0].started_at) : null;
  const ticks1h = runs.filter((r) => {
    const m = minutesSince(r.started_at);
    return m !== null && m <= 60;
  }).length;
  const failing = runs.filter((r) => runOutcome(r) !== 'ok' && runOutcome(r) !== 'unknown').length;
  // BH-4992: the headline and the line, from the same two reads.
  const jobRowsNow = jobs.data ? jobRows(jobs.data) : null;
  const hl = nowHeadline({
    inFlight: jobRowsNow ? lineTickets(jobRowsNow).length : null,
    needs: nowData.data ? needsTotal : null,
    boards: nowData.data ? boards.length : null,
    ticks: nowData.data ? runs.length : null,
    failing: nowData.data ? failing : null
  });

  return html`
    <div class="page">
      <${PageHeadline} chip="Now · live"
        asOf=${d.generated_at ? `Console D1 · read at ${clockTime(d.generated_at)}` : 'Console D1'}
        line1=${hl.line1} line2=${hl.line2} lede=${hl.lede}/>

      <div class="stats stats--6">
        <${Stat} label="LAST TICK" value=${nowData.data ? agoFromMinutes(newestTick) : '…'} tone="sm"
          to="/history"/>
        <${Stat} label="TICKS · 1H" value=${nowData.data ? ticks1h : '…'} to="/history"/>
        <${Stat} label="BUILDING NOW" value=${buildingValue} tone="green" to="/jobs"/>
        <${Stat} label="NEEDS A HUMAN" value=${nowData.data ? countOrNull(needsTotal) : '…'}
          tone=${needsTotal ? 'warn' : null} to="/needs"/>
        <${Stat} label="BOARDS" value=${nowData.data ? boards.length : '…'}/>
        <${Stat} label=${`FAILED OF LAST ${runs.length} TICKS`} value=${nowData.data ? failing : '…'}
          tone=${failing ? 'warn' : null} to="/history?outcome=failed"/>
      </div>

      <${NeedsSplitLine} split=${split} loaded=${!!nowData.data}/>

      ${nowData.error && !nowData.data
        ? html`<${ErrorBox} error=${nowData.error} onRetry=${nowData.reload}/>` : null}

      <${SectionHead} num=${1} title="The line"
        note="every ticket in flight, furthest along first, from the running jobs read below"/>
      ${jobRowsNow
        ? html`<${LineBoard} rows=${jobRowsNow}/>`
        : html`<div class="board__empty">${jobs.error ? 'The jobs read failed, so the line cannot be drawn.' : 'Reading the running jobs.'}</div>`}

      <${Section} title="BOARDS" note="the last tick each board beat — every row drills into the project"
        right=${html`<${Link} to="/history" style="font-size:var(--fs-xs);letter-spacing:1px">ALL RUNS ›<//>`}>
        ${nowData.loading && !nowData.data
          ? html`<${Skeleton} rows=${6} height=${20}/>`
          : html`<${BoardsTable} boards=${boards} nowMs=${nowMs}/>`}
      <//>

      <div class="split">
        <div class="split__col">
          <${Section} title="BUILDING NOW"
            note="one row per ticket, from build jobs with a heartbeat in the last 10 minutes"
            right=${html`<${Link} to="/needs" style="font-size:var(--fs-xs);letter-spacing:1px">WHAT IS PARKED ›<//>`}>
            ${bn && (bn.quiet || bn.otherRunning) ? html`
              <div class="section__note" style="margin-bottom:6px">
                ${bn.otherRunning} other jobs running (triage, reviews). ${bn.quiet} build jobs have gone quiet.
                ${' '}<${Link} to="/jobs">see JOBS<//>
              </div>` : null}
            ${bn && bn.capped ? html`
              <div class="section__note" style="margin-bottom:6px">
                the jobs read hit its ${JOBS_READ_CAP}-row cap, so there may be more than this
              </div>` : null}
            ${d.active_builds_truncated ? html`
              <div class="section__note" style="margin-bottom:6px">
                stale check covers the newest 200 unfinished build rows
              </div>` : null}
            ${jobs.error && !jobs.data
              ? html`<${ErrorBox} error=${jobs.error} onRetry=${jobs.reload}/>`
              : !bn
                ? html`<${Skeleton} rows=${3} height=${20}/>`
                : html`<${BuildingTable} rows=${bn.rows} nowMs=${nowMs}/>`}
            <${Legend} items=${BUILDING_LEGEND}/>
          <//>

          <${Section} title="LATEST TICKS"
            note=${oldest
              ? `${runs.length} newest ticks, fleet-wide, ${whenLabel(oldest.started_at, nowMs)} to now`
              : 'no ticks in view'}
            right=${html`<${Link} to="/history" style="font-size:var(--fs-xs);letter-spacing:1px">FULL HISTORY ›<//>`}>
            ${nowData.loading && !nowData.data
              ? html`<${Skeleton} rows=${5} height=${20}/>`
              : html`<${LatestTicksTable} runs=${runs} nowMs=${nowMs}/>`}
          <//>
        </div>

        <div class="split__col">
          <${Section} title="ACTIVITY"
            note=${d.events_excluding
              ? `newest first · ${d.events_excluding.join(', ')} beats excluded`
              : 'newest first'}>
            ${nowData.loading && !nowData.data
              ? html`<${Skeleton} rows=${8} height=${16}/>`
              : html`<${Feed} events=${d.events || []} nowMs=${nowMs}/>`}
          <//>
        </div>
      </div>

      <div class="footnote">
        <${Clock}/>
        <span>read straight from the console worker's D1 · refreshes every ${REFRESH_MS / 1000}s${
          d.generated_at ? ` · read at ${clockTime(d.generated_at)}` : ''}</span>
        <span class="footnote__spacer"></span>
        <${Cursor}/>
      </div>
    </div>`;
}

// One wrapping line under the stats: what NEEDS A HUMAN is made of, each part a
// link to its list. `…` until /now answers, `—` for a part whose read failed.
function NeedsSplitLine({ split, loaded }) {
  return html`
    <div class="section__note" data-testid="needs-split"
      style="display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline;margin:6px 0 10px">
      <span style="letter-spacing:1px">NEEDS</span>
      ${split.parts.map((p) => html`
        <span key=${p.key}>${'· '}<${Link} to=${p.to} data-kind=${p.key}>${
          !loaded ? '…' : p.value === null ? '—' : p.value} ${p.label}<//></span>`)}
    </div>`;
}

function BoardsTable({ boards, nowMs }) {
  const columns = [
    {
      key: 'project', label: 'BOARD', sort: (b) => b.project,
      cell: (b) => html`
        <span style="display:inline-flex;align-items:center;gap:7px">
          <${Dot} color=${healthColor(healthFromAge(minutesSince(b.last_run_at)))} size=${7}/>
          <${Link} to=${`/p/${encodeURIComponent(b.project)}`} class="cell-name">${b.project}<//>
        </span>`
    },
    {
      key: 'last_run_at', label: 'LAST TICK', sort: (b) => minutesSince(b.last_run_at), align: 'right',
      cell: (b) => html`<span title=${b.last_run_at || 'never'}>
        <${Age} min=${minutesSince(b.last_run_at)} warnAt=${60}/></span>`
    },
    {
      key: 'last_rc', label: 'RC', sort: (b) => b.last_rc, align: 'right',
      cell: (b) => {
        const o = runOutcome({ rc: b.last_rc });
        return o === 'unknown'
          ? html`<span class="na">—</span>`
          : html`<span class=${TONE_CLASS[OUTCOME_TONE[o]]} title=${`rc=${b.last_rc}`}>${rcLabel(b.last_rc)}</span>`;
      }
    },
    {
      key: 'work', label: 'WORK', sort: (b) => {
        const w = tickWork(b.last_summary);
        return w.built === null ? null : w.built;
      },
      cell: (b) => html`<${TickWork} summary=${b.last_summary}/>`
    },
    {
      key: 'gate', label: 'GATE', sort: (b) => parseTickSummary(b.last_summary).meta.gate,
      cell: (b) => {
        const gate = parseTickSummary(b.last_summary).meta.gate;
        return gate ? html`<span class="tag" title=${`why the tick did or did not do full work (${gate})`}>${plainLabel(gate)}</span>`
          : html`<span class="na">—</span>`;
      }
    },
    {
      key: 'disk', label: 'DISK', sort: (b) => diskPercent(b.disk), align: 'right',
      cell: (b) => {
        const pct = diskPercent(b.disk);
        if (pct === null) return html`<span class="na">—</span>`;
        const tone = diskTone(pct);
        return html`<span class=${tone === 'ok' ? 'num' : tone === 'warn' ? 'num--warn' : 'num--bad'}
          title=${b.disk}>${pct}%</span>`;
      }
    },
    {
      key: 'state', label: 'STATE', sort: (b) => `${b.paused ? 0 : 1}${b.automerge ? 1 : 0}`,
      cell: (b) => html`
        <span style="display:inline-flex;gap:5px;flex-wrap:wrap">
          ${b.paused ? html`<span class="tag tag--warn">paused</span>` : null}
          ${b.automerge ? null : html`<span class="tag tag--warn">auto-merge off</span>`}
          ${!b.paused && b.automerge ? html`<span class="tag tag--idle">running</span>` : null}
        </span>`
    }
  ];
  return html`<${SortableTable} columns=${columns} rows=${boards} rowKey=${(b) => b.project}
    rowClass=${(b) => (runOutcome({ rc: b.last_rc }) === 'failed' ? 'row--dead' : '')}
    defaultSort="last_run_at" defaultDir="asc"
    empty=${html`<${Empty} title="no board has beaten a tick"
      note="Nothing has posted a run to the console yet. bin/beat.sh writes these rows as each tick finishes." />`} />`;
}

// A counter nobody beat renders as nothing, never as 0 — the difference between
// "this tick triaged nothing" and "this lane does not report triage".
function TickWork({ summary }) {
  const w = tickWork(summary);
  const parsed = parseTickSummary(summary);
  const parts = [
    ['tickets', w.tickets], ['new', w.fresh], ['triaged', w.triaged],
    ['built', w.built], ['commented', w.commented]
  ].filter(([, v]) => v !== null && v !== 0);
  if (!parts.length) {
    if (parsed.prose) {
      return html`<span class="cell-wrap" style="max-width:38ch;color:var(--faint)" title=${parsed.prose}>${parsed.prose}</span>`;
    }
    return html`<span style="color:var(--faint)">quiet tick</span>`;
  }
  return html`
    <span style="display:inline-flex;gap:5px;flex-wrap:wrap" title=${summary || ''}>
      ${parts.map(([label, v]) => html`<span key=${label} class="tag">${v} ${label}</span>`)}
    </span>`;
}

// Every row links somewhere: its PR, else its build, else the job itself.
const targetLabel = (r) => (prNumberFromUrl(r.pr_url) && r.project ? 'PR'
  : r.build_id !== null && r.build_id !== undefined ? 'build' : 'job');
function rowTarget(r) {
  const n = prNumberFromUrl(r.pr_url);
  if (n && r.project) return `/pr/${encodeURIComponent(r.project)}/${n}`;
  if (r.build_id !== null && r.build_id !== undefined) return `/builds/${r.build_id}`;
  return `/jobs/${encodeURIComponent(r.id)}`;
}

export function buildingColumns(nowMs = Date.now()) {
  return [
    {
      key: 'ticket', label: 'TICKET', sort: (r) => r.ticket || '',
      // BH-4991: the key opens the ticket page; the row's PR, build or job stays one click away.
      cell: (r) => html`<${TicketKey} k=${r.ticket} cls="cell-name" fallback=${`job ${r.id}`} alt=${{ to: rowTarget(r), label: targetLabel(r) }}/>`
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}>${r.project}<//>`
    },
    {
      key: 'stage', label: 'STAGE', sort: (r) => r.stage || r.build_stage,
      cell: (r) => {
        const st = r.stage || r.build_stage;
        const prog = stageProgress(st);
        return html`
          <span style="display:flex;align-items:center;gap:8px;min-width:140px">
            <span class="build__bar" style="flex:1;min-width:60px">
              ${STEPS.map((step, i) => html`
                <span key=${step} style=${`width:${100 / STEPS.length}%;background:${
                  i < prog.step ? 'var(--green)' : i === prog.step ? 'var(--live)' : 'transparent'}`}></span>`)}
            </span>
            <span style="color:var(--soft);white-space:nowrap" title=${st || ''}>${stageLabel(st) || 'no stage'}</span>
          </span>`;
      }
    },
    {
      key: 'tier', label: 'TIER', align: 'right',
      sort: (r) => (r.tier === null || r.tier === undefined || r.tier === '' ? null : Number(r.tier)),
      cell: (r) => html`<span title=${r.tier === null || r.tier === undefined ? '' : `tier ${r.tier}`}>${tierLabel(r.tier)}</span>`
    },
    {
      key: 'beat', label: 'HEARTBEAT', align: 'right',
      sort: (r) => (r.beat_age_s === null || r.beat_age_s === undefined ? null : Number(r.beat_age_s)),
      cell: (r) => html`<span title=${r.last_beat_at || ''}>${whenLabel(r.last_beat_at, nowMs)}</span>`
    },
    {
      key: 'created_at', label: 'STARTED', sort: (r) => r.created_at, align: 'right',
      cell: (r) => html`<span title=${r.created_at || ''}>${whenLabel(r.created_at, nowMs)}</span>`
    }
  ];
}

function BuildingTable({ rows, nowMs }) {
  return html`<${SortableTable} columns=${buildingColumns(nowMs)} rows=${rows} rowKey=${(r) => r.key}
    defaultSort="created_at" defaultDir="asc"
    empty=${html`<${Empty} title="nothing is building"
      note="No build job has a heartbeat right now. That is the normal state between ticks. What is stuck sits on NEEDS instead.">
      <${Link} to="/needs" class="btn btn--sm">SEE WHAT IS PARKED<//>
    <//>`} />`;
}

function LatestTicksTable({ runs, nowMs }) {
  const columns = [
    {
      key: 'started_at', label: 'TIME', sort: (r) => r.started_at,
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`} title=${r.started_at || ''}>${whenLabel(r.started_at, nowMs)}<//>`
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    {
      key: 'outcome', label: 'OUTCOME', sort: (r) => outcomeRank(r),
      cell: (r) => {
        const o = runOutcome(r);
        return html`<span class=${TONE_CLASS[OUTCOME_TONE[o]]} title=${`rc=${r.rc ?? '—'}`}>${OUTCOME_LABEL[o]}</span>`;
      }
    },
    {
      key: 'summary', label: 'WHAT IT DID', sort: null,
      cell: (r) => html`<${TickWork} summary=${r.summary}/>`
    },
    {
      key: 'open', label: '', sort: null, align: 'right',
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`}>run #${r.id}<//>`
    }
  ];
  return html`<${SortableTable} columns=${columns} rows=${runs} rowKey=${(r) => r.id}
    defaultSort="started_at" defaultDir="desc"
    empty=${html`<${Empty} title="no runs on record" note="Nothing has beaten a run row to the console yet." />`} />`;
}

// The feed is deliberately not a table: it is one chronological column of
// unrelated event types, and sorting it by anything but time is meaningless.
function Feed({ events, nowMs }) {
  if (!events.length) {
    return html`<${Empty} title="no activity"
      note="Nothing but flag scrapes and raw webhooks has beaten an event row lately." />`;
  }
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;max-height:520px;overflow-y:auto">
      ${events.map((e) => html`
        <div key=${e.id} class="timeline__row">
          <span class="timeline__text">
            <span class="timeline__ts" title=${e.ts || ''}>${whenLabel(e.ts, nowMs)}</span>
            ${' · '}
            ${e.project
              ? html`<${Link} to=${`/p/${encodeURIComponent(e.project)}`}>${e.project}<//>`
              : html`<span style="color:var(--faint)">fleet</span>`}
            ${' · '}<span style="color:var(--soft-2)" title=${e.type || ''}>${plainLabel(e.type)}</span>
            ${' · '}${e.detail}
          </span>
        </div>`)}
    </div>`;
}

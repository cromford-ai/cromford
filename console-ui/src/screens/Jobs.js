import { useState, useCallback } from 'preact/hooks';
import { html, Link, useSearchParam } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, ProjectLink, Legend } from '../ui/primitives.js';
import { PageHeadline, StatGrid, SectionHead } from '../ui/line.js';
import { UsdCell } from '../ui/UsdCell.js';
import { useConfirm } from '../ui/Modal.js';
import { clockTime, whenLabel, countOrNull, fmtNum } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { MergeQueueStrip } from '../ui/merge-queue-live.js';
import { PrStageTrack } from '../ui/pr-stage-track.js';
import { LineBoard } from '../ui/LineBoard.js';
import {
  jobRows, jobCounts, jobSpend, ageLabel, burnByDay, burnByProject, burnTotal, flagRows,
  laneRows, laneCounts, laneSortKey
} from '../lib/jobs.js';
import { lineTickets, jobsHeadline, ticketPath } from '../lib/line.js';

// JOBS - the coordination DB's own view of the fleet: who claimed what, whether
// it is still breathing, what it has spent against the cap it was handed.
//
// BH-4990 (wave 1 of BH-4947, "The Line"): a headline from the live counts, a
// hairline stat grid, then 01 The line (one row per ticket in flight, its
// eight-station track, and a log of the newest beats), 02 Lanes, and the
// jobs, burn and pause-flag tables as they were (03-05): they carry the
// pause/resume controls and the way into /jobs/:id. Every ticket key links to
// /t/<KEY> (src/screens/Ticket.js).
//
// What this screen is NOT: the build record. A PR, a board comment and
// ALERTS.log remain the client-facing truth. A job that never claimed a row is
// invisible here, and the burn figures below say so on the tile rather than
// implying they are the whole bill.
const REFRESH_MS = 20000;

// A lanes row is one (project, box) triage liveness row (bin/run-triage.sh ->
// lane_tick), so its own page is the run-triage lane scoped to that project.
const TRIAGE_LANE = 'run-triage';

// How a lane's last tick ended, in words. These are the kinds the triage lane
// posts through LANE_TICK (bin/run-triage.sh, bin/lib/rt/*.sh,
// bin/lib/triage-state.sh); anything else falls back to plainLabel.
const TICK_KIND = {
  tick: 'ran', start: 'started', skip: 'skipped, nothing new', paused: 'paused',
  locked: 'skipped, already running', refused: 'refused by a gate', dispatch: 'handed to a builder',
  run: 'ran', failed: 'ran and failed'
};

export function JobsScreen() {
  // ?project= is what a LANE row links into, so "this lane is silent" leads
  // straight to "here is everything it last claimed" instead of a dead end.
  const project = useSearchParam('project');
  const jobs = useApi(() => api.jobs({ limit: 200, project: project || undefined }),
    [project], { intervalMs: REFRESH_MS });
  const lanes = useApi(() => api.lanes(), [], { intervalMs: REFRESH_MS });
  const burn = useApi(() => api.burn(14), [], { intervalMs: 120000 });
  const flags = useApi(() => api.coordFlags(), [], { intervalMs: 60000 });

  if (jobs.loading && !jobs.data) return html`<div class="page"><${PageHeadline} chip="Jobs · live" line1="Reading the line." line2="The jobs read has not answered."/><${Skeleton} rows=${8} height=${20}/></div>`;
  if (jobs.error && !jobs.data) {
    return html`<div class="page">
      <${Link} to="/" class="crumb">← FLEET<//>
      <${PageHeadline} chip="Jobs · live" line1="The jobs read failed." line2="Nothing on the line can be drawn."/>
      <${ErrorBox} error=${jobs.error} onRetry=${jobs.reload}/>
      <div class="footnote">This view reads the harness-jobs worker through the console's own proxy. If it
        says HARNESS_SECRET is not set, the Pages project is missing that variable - the fleet is unaffected.</div>
    </div>`;
  }

  const rows = jobRows(jobs.data);
  const open = rows.filter((r) => r.status === 'running');

  return html`
    <div class="page">
      <${JobsLine} jobs=${jobs.data} lanes=${lanes.data}/>

      <${MergeQueueStrip}/>

      <${SectionHead} num=${2} title="Lanes" note="What fleet.conf says should be ticking, and whether it is."/>
      <${LanesSection} lanes=${lanes}/>

      <${SectionHead} num=${3} title="Jobs" note="Every claim the coordination DB holds, newest first."/>
      <${Section} title=${project ? `JOBS · ${project}` : 'JOBS'}
        note=${`${fmtNum(rows.length)} most recent rows · ${fmtNum(open.length)} still claimed · every column sorts`}
        right=${project
          ? html`<${Link} to="/jobs" class="crumb">SHOW ALL PROJECTS<//>`
          : null}>
        <${JobsTable} rows=${rows}/>
      <//>

      <${SectionHead} num=${4} title="Burn" note="What the job rows spent, by day and by project."/>
      <${BurnSection} burn=${burn}/>
      <${SectionHead} num=${5} title="Pause flags" note="Pause or resume a board's pickup across the fleet."/>
      <${FlagsSection} flags=${flags}/>

      <div class="footnote" style="flex-direction:column;align-items:flex-start;gap:4px">
        <span style="color:var(--faint)">LANES are what fleet.conf says SHOULD be ticking. A lane is one
          (project, box) pair, and it heartbeats on every triage tick - including the gate skips that claim
          no job and spend nothing, which is most ticks on a quiet board. SILENT means the lane has not
          ticked within three of its own cadences: on 2026-08-30 project-7 lost its crons on
          the project-6 box and went ten hours unnoticed, because the box was still pinging and a lane
          that never ticks never claims a job to go stale. NEVER means it has not ticked since it was
          declared - usually a box whose crons never landed at all.</span>
        <span style="color:var(--faint)">A row appears here when a claimant registered it. A stage that ran
          without a claim - an unclaimed lane, or a box whose worker call failed open - spends real money and
          never shows up, so treat these dollars as the coordinated share, not the bill.</span>
        <span style="color:var(--faint)">STOPPED BEATING means the last heartbeat is over 10 minutes old.
          ORPHANED means bin/jobs-watchdog.sh has since judged it dead and released the claim.</span>
        <span style="color:var(--faint)">QUEUED FOR RETRY means the watchdog judged a dead claim retryable under
          its lane's policy and the lane's own next cron tick will pick the row up - nothing is launched from
          the watchdog. PARKED means the policy ran out of attempts, so the row is waiting on a person. Hover
          either pill for the reason the DB recorded. ATTEMPTS reads "2/3" when the lane has a policy; a bare
          number means it has none, which is the default and means detection only.</span>
        <span style="color:var(--faint)">PHASE is the stage the claim is in, or - on a job that ended badly -
          the stage it died in. Coordination is still per JOB: one claim covers plan, execute and review, and
          phases are the record of what happened inside it, never a second permission to continue. Open the
          job for every phase it ran, with the runner, the exit code and the dollars.</span>
      </div>
    </div>`;
}

const plural = (n, one, many) => `${fmtNum(n)} ${n === 1 ? one : many}`;

// The hero and 01 The line, from the jobs payload and the lanes payload (null
// while it loads). Exported so it renders in a test with no fetch.
export function JobsLine({ jobs, lanes }) {
  const rows = jobRows(jobs);
  const counts = jobCounts(rows);
  const hl = jobsHeadline(counts, laneCounts(laneRows(lanes)));
  const line = lineTickets(rows);
  return html`
    <${PageHeadline} chip="Jobs · live"
      asOf=${`Coordination DB${jobs && jobs.as_of ? ` · as of ${clockTime(jobs.as_of)}` : ''}`}
      line1=${hl.line1} line2=${hl.line2} lede=${hl.lede}>
      <${StatGrid} items=${[
        { label: 'Claimed now', value: counts.running, tone: 'live' },
        { label: 'Stopped beating', value: counts.stalled, tone: counts.stalled ? 'warn' : undefined },
        { label: 'Orphaned', value: counts.orphaned, tone: counts.orphaned ? 'warn' : undefined },
        { label: 'Parked', value: counts.parked, tone: counts.parked ? 'warn' : undefined },
        { label: 'Queued for retry', value: counts.queued_for_retry, tone: counts.queued_for_retry ? 'warn' : undefined },
        { label: 'Quiet (never beat)', value: counts.quiet },
        { label: 'Spend on these rows', value: html`<${UsdCell} value=${jobSpend(rows)}/>` }
      ]}/>
    <//>
    <${SectionHead} num=${1} title="The line"
      note=${`${plural(line.length, 'ticket', 'tickets')} in flight, one row each, furthest along first.`}/>
    <${LineBoard} rows=${rows}/>`;
}

function stateCell(r) {
  const cls = r.tone === 'dead' ? 'pill pill--dead' : r.tone === 'warn' ? 'pill pill--warn' : r.tone === 'ok' ? 'pill' : 'pill pill--muted';
  // A queued or parked row carries the DB's OWN reason on the pill, because
  // "why is this parked" is the only question that state raises and answering
  // it costs one attribute.
  const title = r.retry && r.retry.reason
    ? r.retry.reason + (r.retry.next_attempt_at ? ` (next attempt after ${r.retry.next_attempt_at})` : '')
    : undefined;
  return html`<span class=${cls} title=${title}>${r.state.toUpperCase().replace(/_/g, ' ')}</span>`;
}

// ATTEMPTS (phase 6). "2/3" means the lane's retry policy allows three and this
// is the second. A bare number means the lane has no policy, so there is no
// denominator to show - and a dash means the row predates the counter. None of
// the three is guessed into either of the others.
function attemptsCell(r) {
  if (!r.attempt_label) return html`<span class="na" title="no attempt counter on this row">-</span>`;
  const retried = r.attempts > 1;
  return html`<span class=${retried ? 'num num--warn' : 'num'}
    title=${retried ? 'this claim has been retried under its lane policy' : 'first attempt'}>${r.attempt_label}</span>`;
}

// The phase column (phase 5). A failed job names the phase that FAILED; a live
// one names the phase it is in. No phase at all is "-", not a guess: that box
// may simply be running bin/ from before per-phase tracking, and a made-up
// stage name on a row that never reported one is worse than an honest dash.
function phaseCell(r) {
  const p = r.phase;
  if (!p) {
    return html`<span class="na" title="no phase row - this claim has not opened a stage, or its box predates per-phase tracking">-</span>`;
  }
  if (p.failed) {
    return html`<span class="pill pill--dead" title=${`this job died in ${p.failed}${p.rc === null ? '' : ` (rc=${p.rc})`}`}>
      ${p.failed.toUpperCase()} FAILED</span>`;
  }
  // A running phase is the active stage of a running build: in progress, so
  // it reads --live (brick in Mill), never the done green of a plain .pill.
  return html`<span class=${p.running ? 'pill pill--live' : 'pill pill--muted'}
    title=${`${p.name} - ${p.status}${p.rc === null ? '' : ` (rc=${p.rc})`}`}>${p.name.toUpperCase()}</span>`;
}

export function JobsTable({ rows }) {
  return html`
    <${SortableTable}
      rows=${rows}
      rowKey=${(r) => r.id}
      defaultSort="created_at"
      defaultDir="desc"
      empty=${html`<${Empty} title="NO JOBS ON FILE"
        note="Nothing has claimed a coordination row yet. That is normal on a quiet fleet and expected right after the worker's first deploy."/>`}
      columns=${[
        {
          key: 'id', label: 'JOB', sort: (r) => r.id,
          // No dead rows: the identity cell is the way into the job's own page.
          cell: (r) => html`<${Link} to=${`/jobs/${encodeURIComponent(r.id)}`} class="cell-name">${r.id}<//>`
        },
        { key: 'state', label: 'STATE', sort: (r) => r.state, cell: stateCell },
        {
          key: 'project', label: 'PROJECT', sort: (r) => r.project,
          cell: (r) => (r.project && r.project !== 'orchestrator'
            ? html`<${ProjectLink} project=${r.project}/>`
            : html`<span>${r.project || '-'}</span>`)
        },
        { key: 'lane', label: 'LANE', sort: (r) => r.lane, cell: (r) => html`<span>${r.lane}</span>` },
        {
          key: 'phase', label: 'PHASE', sort: (r) => (r.phase ? r.phase.name : ''),
          cell: (r) => phaseCell(r)
        },
        {
          key: 'attempts', label: 'ATTEMPTS', sort: (r) => Number(r.attempts) || 0, align: 'right',
          cell: attemptsCell
        },
        {
          key: 'key', label: 'TICKET', sort: (r) => r.key,
          // BH-5667: the stage-track seam rides in the cell, so the column set is unchanged.
          cell: (r) => html`${r.key ? html`<${Link} to=${ticketPath(r.key)}>${r.key}<//>` : html`<span class="na">-</span>`}<${PrStageTrack}
            repo=${r.repo} pr=${r.pr} project=${r.project} ticket=${r.key}/>`
        },
        { key: 'box', label: 'BOX', sort: (r) => r.box, cell: (r) => html`<span>${r.box || '-'}</span>` },
        {
          key: 'spent_usd', label: 'SPENT / CAP', sort: (r) => Number(r.spent_usd) || 0, align: 'right',
          // A zero cap is a cap ($0.00); only an absent one is "no cap".
          cell: (r) => html`<span class="num"><${UsdCell} value=${r.spent_usd}/><span class="na"> / </span>${r.budget_usd === null || r.budget_usd === undefined || r.budget_usd === ''
            ? html`<span class="na">${countOrNull(null, { uncapped: true })}</span>`
            : html`<${UsdCell} value=${r.budget_usd}/>`}</span>`
        },
        {
          key: 'age_s', label: 'STARTED', sort: (r) => Number(r.age_s), align: 'right',
          cell: (r) => html`<span title=${r.created_at || ''}>${ageLabel(r.age_s)} ago</span>`
        },
        {
          key: 'activity_age_s', label: 'LAST BEAT', sort: (r) => Number(r.activity_age_s), align: 'right',
          cell: (r) => (r.heartbeating
            ? html`<span class=${r.state === 'stalled' || r.state === 'orphaned' ? 'num--warn' : ''}
                title=${r.last_beat_at || ''}>${ageLabel(r.beat_age_s)}</span>`
            : html`<span class="na" title="this box's bin/ predates heartbeats">never</span>`)
        }
      ]}/>`;
}

export function BurnSection({ burn }) {
  const [view, setView] = useState('day');
  if (burn.loading && !burn.data) return html`<${Section} title="BURN"><${Skeleton} rows=${3}/><//>`;
  if (burn.error && !burn.data) {
    return html`<${Section} title="BURN"><${ErrorBox} error=${burn.error} onRetry=${burn.reload}/><//>`;
  }
  const days = burnByDay(burn.data);
  const projects = burnByProject(burn.data);
  const total = burnTotal(burn.data);
  const today = days[0];

  return html`
    <${Section} title=${`BURN · ${(burn.data && burn.data.days) || 14}D`}
      note="summed from the job rows themselves - the coordinated share of spend, not the fleet's whole bill"
      right=${html`
        <span class="tabs">
          <button class=${`tab${view === 'day' ? ' tab--on' : ''}`} onClick=${() => setView('day')}>BY DAY</button>
          <button class=${`tab${view === 'project' ? ' tab--on' : ''}`} onClick=${() => setView('project')}>BY PROJECT</button>
        </span>`}>
      <div class="stats" style="margin-bottom:10px">
        <${Stat} label="TOTAL" value=${html`<${UsdCell} value=${total}/>`} tone="sm"/>
        <${Stat} label="LATEST DAY" value=${today ? html`<${UsdCell} value=${today.spent_usd}/>` : 'no data'} tone="sm"/>
        <${Stat} label="DAYS WITH ROWS" value=${days.length}/>
      </div>
      ${view === 'day'
        ? html`<${SortableTable} rows=${days} rowKey=${(r) => r.day} defaultSort="day" defaultDir="desc"
            empty=${html`<${Empty} title="NO SPEND ROWS YET"
              note="Job rows carry spend once agent-call.sh posts a stage delta against a claim."/>`}
            columns=${[
              { key: 'day', label: 'DAY', sort: (r) => r.day, cell: (r) => html`<span>${r.day}</span>` },
              { key: 'spent_usd', label: 'SPENT', sort: (r) => r.spent_usd, align: 'right', cell: (r) => html`<${UsdCell} value=${r.spent_usd}/>` },
              { key: 'jobs', label: 'JOBS', sort: (r) => r.jobs, align: 'right', cell: (r) => html`<span class="num">${r.jobs}</span>` },
              { key: 'projects', label: 'PROJECTS', sort: (r) => r.projects, align: 'right', cell: (r) => html`<span class="num">${r.projects}</span>` },
              {
                key: 'orphaned', label: 'ORPHANED', sort: (r) => r.orphaned, align: 'right',
                cell: (r) => (r.orphaned ? html`<span class="num--warn">${r.orphaned}</span>` : html`<span class="na">0</span>`)
              }
            ]}/>`
        : html`<${SortableTable} rows=${projects} rowKey=${(r) => `${r.project}/${r.kind}`} defaultSort="spent_usd" defaultDir="desc"
            empty=${html`<${Empty} title="NO SPEND ROWS YET" note="Nothing has posted a spend delta in this window."/>`}
            columns=${[
              {
                key: 'project', label: 'PROJECT', sort: (r) => r.project,
                cell: (r) => (r.project && r.project !== 'orchestrator'
                  ? html`<${ProjectLink} project=${r.project}/>`
                  : html`<span>${r.project || '-'}</span>`)
              },
              { key: 'kind', label: 'LANE', sort: (r) => r.kind, cell: (r) => html`<span title=${r.kind}>${plainLabel(r.kind)}</span>` },
              { key: 'spent_usd', label: 'SPENT', sort: (r) => r.spent_usd, align: 'right', cell: (r) => html`<${UsdCell} value=${r.spent_usd}/>` },
              { key: 'jobs', label: 'JOBS', sort: (r) => r.jobs, align: 'right', cell: (r) => html`<span class="num">${r.jobs}</span>` },
              {
                key: 'per_job', label: 'PER JOB', sort: (r) => r.per_job, align: 'right',
                cell: (r) => html`<${UsdCell} value=${r.per_job}/>`
              },
              { key: 'days', label: 'DAYS', sort: (r) => r.days, align: 'right', cell: (r) => html`<span class="num">${r.days}</span>` }
            ]}/>`}
      <${Legend} items=${[
        { term: 'ORPHANED', text: 'jobs that day whose claim the watchdog judged dead and released' },
        { term: 'API-eq', text: 'list price times tokens, not cash paid; open /costs for the difference' }
      ]}/>
    <//>`;
}

function FlagsSection({ flags }) {
  // The board list comes from the fleet's own project snapshot, never a
  // constant in this file: a hardcoded fleet is a fifth place to forget a new
  // project, and enrolling one (project-9 was the last) already touches
  // enough files.
  const projects = useApi(() => api.projects(), [], { intervalMs: 300000 });
  const boards = ((projects.data && projects.data.projects) || []).map((p) => p.project).filter(Boolean);
  const [dialog, confirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [note, setNote] = useState(null);

  const toggle = useCallback(async (name, active) => {
    const ok = await confirm({
      title: active ? `PAUSE ${name}?` : `RESUME ${name}?`,
      body: active
        ? html`<span>This writes the pause row. Every box reads it on its next tick - within about a
            minute - and stops picking up new work for it. Work already running is not touched.</span>`
        : html`<span>This clears the pause row. Boxes read it on their next tick and resume normally.</span>`,
      confirmLabel: active ? 'PAUSE' : 'RESUME',
      tone: active ? 'warn' : undefined
    });
    if (!ok) return;
    setBusy(name);
    try {
      await api.setCoordFlag(name, active, 'set from Mission Control');
      setNote(`${name} set to ${active ? 'paused' : 'running'} - boxes apply it on their next tick.`);
      flags.reload();
    } catch (e) {
      setNote(`could not write ${name}: ${e.message}`);
    } finally {
      setBusy(null);
    }
  }, [confirm, flags]);

  const rows = flagRows(flags.data);
  // Every board gets a row whether or not the DB has ever heard of it, so the
  // absence of a row reads as "not paused" instead of as a missing control.
  const merged = boards.map((p) => {
    const name = `paused-${p}`;
    const found = rows.find((r) => r.name === name);
    return found || { name, active: false, scope: p, updated_at: null, actor: null, reason: null, _unset: true };
  }).concat(rows.filter((r) => !boards.some((p) => `paused-${p}` === r.name)));

  return html`
    <${Section} title="PAUSE FLAGS"
      note=${`rows here drive the flags/ file on every box - the file is still what the pipeline tests${
        boards.length ? '' : ' (waiting on the fleet snapshot for the board list)'}`}>
      ${flags.error && !flags.data ? html`<${ErrorBox} error=${flags.error} onRetry=${flags.reload}/>` : null}
      ${note ? html`<div class="footnote"><span>${note}</span></div>` : null}
      <${SortableTable} rows=${merged} rowKey=${(r) => r.name} defaultSort="name"
        empty=${html`<${Empty} title="NO FLAG ROWS" note="Nothing has been paused from the console yet."/>`}
        columns=${[
          { key: 'name', label: 'FLAG', sort: (r) => r.name, cell: (r) => html`<span>${r.name}</span>` },
          {
            key: 'active', label: 'STATE', sort: (r) => (r.active ? 1 : 0),
            cell: (r) => (r.active
              ? html`<span class="pill pill--warn">PAUSED</span>`
              : html`<span class="pill">RUNNING</span>`)
          },
          {
            key: 'updated_at', label: 'CHANGED', sort: (r) => r.updated_at,
            cell: (r) => (r.updated_at
              ? html`<span title=${r.updated_at}>${whenLabel(r.updated_at)}</span>`
              : html`<span class="na">never set</span>`)
          },
          { key: 'actor', label: 'BY', sort: (r) => r.actor, cell: (r) => html`<span>${r.actor || '-'}</span>` },
          {
            key: 'reason', label: 'REASON', sort: null,
            cell: (r) => html`<span class="na">${r.reason || '-'}</span>`
          },
          {
            key: 'act', label: 'ACTION', sort: null, align: 'right',
            cell: (r) => html`<button class=${`btn btn--sm${r.active ? '' : ' btn--warn'}`}
              disabled=${busy === r.name}
              onClick=${() => toggle(r.name, !r.active)}>
              ${busy === r.name ? '...' : r.active ? 'RESUME' : 'PAUSE'}</button>`
          }
        ]}/>
      ${dialog}
    <//>`;
}

// LANES - the expected set, and whether it is alive. The rows arrive with their
// verdict already computed by the worker, off the same fields
// bin/jobs-watchdog.sh pages on, so this table and the alert that woke someone
// up cannot drift apart.
export function LanesSection({ lanes }) {
  if (lanes.loading && !lanes.data) return html`<${Section} title="LANES"><${Skeleton} rows=${4}/><//>`;
  if (lanes.error && !lanes.data) {
    return html`<${Section} title="LANES"><${ErrorBox} error=${lanes.error} onRetry=${lanes.reload}/><//>`;
  }
  const rows = laneRows(lanes.data);
  const c = laneCounts(rows);
  return html`
    <${Section} title="LANES"
      note="what fleet.conf says should be ticking - silent lanes first, every column sorts">
      <div class="stats" style="margin-bottom:10px">
        <${Stat} label="EXPECTED" value=${c.expected}/>
        <${Stat} label="SILENT" value=${c.stale} tone=${c.stale ? 'warn' : null}/>
        <${Stat} label="AWAITING FIRST TICK" value=${c.pending} tone=${c.pending ? 'warn' : null}/>
        <${Stat} label="UNDECLARED" value=${c.unexpected} tone=${c.unexpected ? 'warn' : null}/>
        <${Stat} label="RETIRED" value=${c.retired}/>
      </div>
      <${SortableTable}
        rows=${rows}
        rowKey=${(r) => r.lane}
        defaultSort="state"
        empty=${html`<${Empty} title="NO LANES DECLARED YET"
          note="The hub declares the expected set from fleet.conf on its next fleet-status push (every 10 minutes). Until then nothing here is watched."/>`}
        columns=${[
          {
            // No dead rows: the identity cell opens this lane's own page, and
            // the second link is everything it last claimed.
            key: 'lane', label: 'LANE', sort: (r) => r.lane,
            cell: (r) => html`<${Link} to=${`/settings/${TRIAGE_LANE}?project=${encodeURIComponent(r.project)}`} class="cell-name">${r.lane}<//>
              <${Link} to=${`/jobs?project=${encodeURIComponent(r.project)}`} style="margin-left:6px">jobs<//>`
          },
          {
            key: 'project', label: 'PROJECT', sort: (r) => r.project,
            cell: (r) => html`<${ProjectLink} project=${r.project}/>`
          },
          { key: 'box', label: 'BOX', sort: (r) => r.box, cell: (r) => html`<span>${r.box || '-'}</span>` },
          // Sorted by SEVERITY, not by the word: alphabetical order puts
          // `stale` fourth, behind live and pending and retired.
          { key: 'state', label: 'STATE', sort: laneSortKey, cell: laneStateCell },
          {
            key: 'age', label: 'LAST TICK', sort: (r) => (r.tick_age_s === null ? Infinity : Number(r.tick_age_s)),
            align: 'right',
            cell: (r) => (r.tick_age_s === null
              ? html`<span class="na" title="this lane has not ticked since it was declared">never</span>`
              : html`<span class=${r.stale ? 'num--warn' : ''} title=${r.last_tick_at || ''}>
                  ${r.age_label} ago</span>`)
          },
          {
            key: 'last_tick_kind', label: 'KIND', sort: (r) => r.last_tick_kind,
            // A skip IS a heartbeat: the gate finding nothing changed is a
            // healthy lane, not an idle one, and the column says which it was.
            cell: (r) => (r.last_tick_kind
              ? html`<span class="na" title=${r.last_tick_kind}>${TICK_KIND[r.last_tick_kind] || plainLabel(r.last_tick_kind)}</span>`
              : html`<span class="na">-</span>`)
          },
          {
            key: 'stale_after_s', label: 'THRESHOLD', sort: (r) => Number(r.stale_after_s) || 0, align: 'right',
            cell: (r) => html`<span class="na"
              title=${`three missed ticks at this lane's ${fmtNum(Math.round((Number(r.cadence_min) || 10)))}m cadence`}
              >${ageLabel(r.stale_after_s)}</span>`
          }
        ]}/>
      <${Legend} items=${[
        { term: 'THRESHOLD', text: "silent after three missed ticks at this lane's own cadence, never less than 30 minutes; the worker computes it" },
        { term: 'KIND', text: 'how the last tick ended' },
        { term: 'STATE', text: 'live, silent, never ticked, awaiting first tick, undeclared or retired' }
      ]}/>
    <//>`;
}

function laneStateCell(r) {
  const cls = r.tone === 'dead' ? 'pill pill--dead' : r.tone === 'warn' ? 'pill pill--warn'
    : r.tone === 'ok' ? 'pill' : 'pill pill--muted';
  const title = {
    stale: `no tick for ${ageLabel(r.silence_s)} - this lane should tick every ${fmtNum(Math.round(Number(r.cadence_min) || 10))}m`,
    pending: 'declared, but its first tick is not due yet',
    unexpected: 'this box is ticking a lane fleet.conf never declared - visible, but nothing alerts on it',
    retired: 'dropped from fleet.conf; the row is kept, nothing is expected of it',
    live: 'ticking on schedule'
  }[r.state];
  const label = r.state === 'stale' ? (r.never_ticked ? 'NEVER TICKED' : 'SILENT') : r.state.toUpperCase();
  return html`<span class=${cls} title=${title}>${label}</span>`;
}

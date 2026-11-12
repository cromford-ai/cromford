import { useState, useCallback, useEffect, useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, fetchArtifact, ARTIFACT_KINDS, AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { LogPane } from '../ui/LogPane.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, UnavailableChip } from '../ui/primitives.js';
import { agoFromMinutes, fmtDuration, prNumberFromUrl, whenLabel, fmtNum } from '../lib/format.js';
import { stageProgress, buildLane, STEPS, VERDICT_TONE, stageLabel, verdictLabel } from '../lib/stages.js';
import { tierLabel, plainLabel } from '../lib/labels.js';
import { UsdCell } from '../ui/UsdCell.js';
import { phaseRows } from '../lib/jobs.js';
import {
  matchBuildJob, mergeLive, shouldPollLive, liveSpend, gatesPassed,
  liveStep, subStage, logRows, pillClass
} from '../lib/live.js';
import { nextDelay } from '../lib/backoff.js';
import { TimelineDot } from '../ui/icons.js';
import { JobActions } from '../ui/JobActions.js';
import { HeldTag } from '../ui/HeldTag.js';
import { useTicketHold, TicketHoldControl } from '../ui/TicketHold.js';

// How often a RUNNING build is asked what it is doing. Five seconds is the
// cadence a person watching a build reads as live; a finished one is never
// asked again (shouldPollLive), and a failing route backs off from here.
export const LIVE_MS = 5000;

// How far back the job list is searched for this build's job row. The console
// build row carries no job id, so the join is made in the browser against the
// project's recent jobs — see matchBuildJob.
const JOB_LOOKUP_LIMIT = 200;

export function BuildScreen({ id }) {
  const b = useApi(() => api.build(id), [id]);

  const build = b.data ? b.data.build : null;
  const project = build ? build.project : null;
  const ticket = build ? build.ticket_key : null;

  // One call per mount, not per tick: which coordination job IS this build.
  const j = useApi(
    () => (project && ticket ? api.jobs({ project, limit: JOB_LOOKUP_LIMIT }) : Promise.resolve(null)),
    [project, ticket]
  );
  const jobRow = build && j.data ? matchBuildJob(build, j.data.jobs) : null;
  const jobId = jobRow ? jobRow.id : null;

  const [live, setLive] = useState(null);
  const [liveError, setLiveError] = useState(null);
  const liveRef = useRef(null);
  const buildRef = useRef(null);
  buildRef.current = build;

  // The cursored live feed. usePolledApi cannot drive this one: it REPLACES its
  // data every tick, and this stream has to accumulate across ticks — the
  // events already on screen are not re-sent once `since` has passed them.
  useEffect(() => {
    liveRef.current = null;
    setLive(null);
    setLiveError(null);
    if (!jobId) return undefined;

    let alive = true;
    let timer = null;
    let failures = 0;

    const tick = async () => {
      try {
        const payload = await api.live(jobId, liveRef.current ? liveRef.current.cursor : 0);
        if (!alive) return;
        failures = 0;
        const next = mergeLive(liveRef.current, payload);
        liveRef.current = next;
        setLive(next);
        setLiveError(null);
      } catch (e) {
        if (!alive) return;
        if (e instanceof AuthError) {
          window.dispatchEvent(new CustomEvent('dash:unauthorized'));
          return;
        }
        // The last good payload stays on screen and the failure is rendered as
        // itself — a dead feed must never read as "this build did nothing".
        failures += 1;
        setLiveError(e);
      }
      if (!alive) return;
      if (shouldPollLive(liveRef.current, buildRef.current)) {
        timer = setTimeout(tick, nextDelay(LIVE_MS, failures));
      }
    };

    tick();
    return () => { alive = false; if (timer) clearTimeout(timer); };
    // eslint-disable-next-line
  }, [jobId]);

  // One hold read (BH-2326.3) feeds both the HELD tag and the HOLD control.
  const th = useTicketHold(project, ticket);

  const artifactAction = useCallback(
    (kind) => fetchArtifact(project, ticket, kind),
    [project, ticket]
  );

  if (b.loading && !b.data) return html`<div class="page"><${PageHeadline} chip="Build" line1=${`build #${id}`} line2="Reading the build."/><${Skeleton} rows=${6} height=${22}/></div>`;
  if (b.error && !b.data) {
    return html`<div class="page">
      <${Link} to="/" class="crumb">← FLEET<//>
      <${PageHeadline} chip="Build" line1=${`build #${id}`} line2="The build read failed."/>
      <${ErrorBox} error=${b.error} onRetry=${b.reload}/>
    </div>`;
  }

  const lane = buildLane(build);
  const prNumber = prNumberFromUrl(build.pr_url);

  // Why there is no live record, in the words of whatever actually went wrong:
  // the job list failed, or it answered and this build is not in it.
  const jobNote = jobId ? null
    : !(project && ticket) ? 'this build row carries no project or ticket key, so it joins to no job'
      : j.error ? `could not resolve the job · ${errText(j.error)}`
        : j.loading ? 'finding this build\'s job record'
          : `no job record found in the last ${JOB_LOOKUP_LIMIT} jobs of ${project}`;

  return html`
    <div class="page">
      <${PageHeadline} chip="Build" line1=${build.ticket_key || build.bkey || `build #${build.id}`}
        line2=${`${build.stage ? stageLabel(build.stage) : 'no stage on file'}.${build.verdict ? ` ${verdictLabel(build.verdict)}.` : ''}`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        ${project
          ? html`<${Link} to=${`/p/${encodeURIComponent(project)}`} class="crumb">← ${project}<//>`
          : html`<${Link} to="/" class="crumb">← FLEET<//>`}
        <span class="crumb-sep">/</span>
        <span class="tag tag--plain">build #${build.id}</span>
        ${build.verdict
          ? html`<span class=${build.verdict === 'APPROVE' ? 'tag tag--green' : 'tag tag--warn'} title=${build.verdict}>${verdictLabel(build.verdict)}</span>`
          : null}
        <${HeldTag} ...${th.hold || {}}/>
        ${prNumber && project
          ? html`<${Link} to=${`/pr/${encodeURIComponent(project)}/${prNumber}`} class="btn btn--sm"
              style="margin-left:auto">PR #${prNumber} ›<//>`
          : null}
      </div>

      <${BuildStats} build=${build} lane=${lane}/>

      <${TicketHoldControl} project=${project} ticket=${ticket} hold=${th.hold} reload=${th.reload}/>

      ${jobRow ? html`<${JobActions} key=${jobRow.id} job=${jobRow} onDone=${j.reload}/>` : null}

      <${BuildMission} build=${build} live=${live} liveError=${liveError} jobNote=${jobNote}
        timeline=${b.data.timeline || []} artifactAction=${artifactAction}/>
    </div>`;
}

const errText = (e) => String((e && e.message) || e || 'unknown');

// The build's headline facts in words (BH-3569): stage and tier as an operator
// says them, not the pipeline's keys. Exported so a test renders it.
export function BuildStats({ build, lane }) {
  return html`
      <div class="stats">
        <${Stat} label="STAGE" value=${build.stage ? stageLabel(build.stage) : '—'} tone="sm"/>
        <${Stat} label="LANE" value=${String(lane || '').replace('_', ' ') || '—'} tone="sm"/>
        <${Stat} label="TIER" value=${tierLabel(build.tier)} tone="sm"/>
        <${Stat} label="MERGED" value=${build.merged ? 'yes' : 'no'} tone=${build.merged ? 'green' : null}/>
        <${Stat} label="AGE" value=${agoFromMinutes(build.age_min)} tone="sm"/>
      </div>`;
}

// A dollar figure carries its basis (cost rows are API-equivalent); unknown
// spend stays a dash, never $0.00.
const usd = (n) => (n === null || n === undefined ? '—' : html`<${UsdCell} value=${n} basis="api"/>`);

// The mission view: where this build is, what it is spending, and what it has
// said for itself. Exported so it can be rendered and read back in a test —
// this is the component the /builds/:id route mounts, not a copy of it.
export function BuildMission({ build, live, liveError, jobNote, timeline = [], artifactAction, nowMs = Date.now() }) {
  const [which, setWhich] = useState('plan');
  const logRef = useRef(null);

  const project = build.project;
  const ticket = build.ticket_key;
  const events = (live && live.events) || [];
  const rows = logRows(events);
  const phases = phaseRows(live);
  const spend = liveSpend(live);

  const prog = stageProgress(build.stage, build.merged);
  const step = liveStep(build, events);
  const sub = subStage(events, step);
  const polling = shouldPollLive(live, build);
  const status = (live && live.job && live.job.status) || (build.merged ? 'merged' : 'building');

  // The newest line is at the bottom, which is where the pane stays parked.
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [rows.length]);

  // Never blank: if no event has landed, the line still says what the hub last
  // beat and how old that is, so a silent feed is legible as silence.
  const subLine = sub && (sub.detail || sub.verdict)
    ? html`
      ${sub.verdict
        ? html`<span class=${pillClass(VERDICT_TONE[String(sub.verdict).toUpperCase()] || null)}>${sub.verdict}</span> `
        : null}${sub.detail || ''}`
    : html`last beat: ${build.stage || 'unknown'} · ${agoFromMinutes(build.age_min)} ago`;

  const railNote = spend === null
    ? 'spend not on file yet — no phase has billed, or this build has no live record'
    : `${fmtNum(phases.length)} phase${phases.length === 1 ? '' : 's'} on file, as of the last answer`;

  const logNote = rows.length
    ? `${fmtNum(rows.length)} event${rows.length === 1 ? '' : 's'}, newest at the bottom${live && live.capped ? ' · more still loading' : ''}`
    : 'nothing has been emitted for this build yet';

  return html`
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <span class="section__title">PROGRESS</span>
      ${jobNote
        // No job row means no timer is armed, whatever the build row says. A
        // LIVE badge over a feed nobody is reading is the lie this avoids.
        ? html`<span class="tag tag--idle">NOT WATCHING</span>`
        : polling
          ? html`<span class="tag tag--green">LIVE · every ${LIVE_MS / 1000}s</span>`
          : html`<span class="tag tag--plain">FINAL · ${status}</span>`}
      ${liveError ? html`<${UnavailableChip} what="live feed" reason=${errText(liveError)}/>` : null}
      ${jobNote ? html`<span class="section__note">${jobNote}</span>` : null}
    </div>

    ${prog.dead ? html`
      <div class="banner">
        <span>This build stopped at <b>${prog.label}</b>. It is not progressing and will not resume on its own.</span>
      </div>` : html`
      <div class="panel panel__pad">
        <div class="build__bar">
          ${STEPS.map((s, i) => html`
            <span key=${s} style=${`width:${100 / STEPS.length}%;background:${
              prog.done || i < step ? 'var(--green)' : i === step ? 'var(--live)' : 'transparent'}`}></span>`)}
        </div>
        <div class="build__stages" style="margin-top:10px">
          ${STEPS.map((s, i) => html`
            <span key=${s} class=${prog.done || i < step ? 'done' : i === step ? 'on' : ''}>
              ${s}${prog.done || i < step ? ' ✓' : ''}
            </span>`)}
        </div>
        <div class="build__sub">${subLine}</div>
      </div>`}

    <div class="split">
      <div class="split__col">
        <${Section} title="PROGRESS LOG" note=${logNote}>
          ${rows.length
            ? html`<div class="build__log" ref=${logRef}>
                ${rows.map((r) => html`
                  <div key=${r.id} class="log__row">
                    <span class="timeline__ts">${r.when}</span> · ${r.stage} ${' '}
                    ${r.verdict ? html`<span class=${pillClass(r.tone)}>${r.verdict}</span> ` : null}
                    ${r.detail}
                  </div>`)}
              </div>`
            : html`<${Empty} title="no progress events yet"
                note=${`Last beat: ${build.stage || 'unknown'} · ${agoFromMinutes(build.age_min)} ago. Events land here as the build passes each gate.`} />`}
        <//>

        <${Section} title="ARTIFACTS"
          note=${project && ticket
            ? `pulled from the ${project} box on request`
            : 'this build row carries no project or ticket key, so no artifact can be addressed'}>
          ${project && ticket
            ? html`<${LogPane}
                kinds=${ARTIFACT_KINDS.map((k) => ({ key: k, label: k.toUpperCase() }))}
                activeKind=${which}
                onKind=${setWhich}
                action=${artifactAction}
                terminalClass="term term--artifact"
                autoFetch=${false}
                emptyHint="Artifacts live in a per-ticket build dir on the owning box. Pick a kind and press FETCH FRESH." />`
            : html`<${Empty} title="not addressable"
                note="fetch_artifact is always project-scoped and needs a ticket key; this row has neither." />`}
        <//>

        ${build.detail ? html`
          <${Section} title="STORED DETAIL" note="plan and review as they beat into D1">
            <pre class="term term--artifact">${build.detail}
<span class="term__end">─ ─ ─ end of stored detail ─ ─ ─</span></pre>
          <//>` : null}
      </div>

      <div class="split__col">
        <${Section} title="LIVE" note=${railNote}>
          <div class="stats">
            <${Stat} label="SPEND SO FAR" value=${usd(spend)} tone=${spend === null ? null : 'green'}/>
            <${Stat} label="GATES PASSED" value=${gatesPassed(events)}/>
            <${Stat} label="STAGE" value=${stageLabel((live && live.job && live.job.stage) || build.stage) || '—'} tone="sm"/>
            <${Stat} label="STATUS" value=${status} tone="sm"/>
          </div>
        <//>

        <${Section} title="PHASES" note="one row per stage the build opened, with the model that ran it">
          <${SortableTable} rows=${phases} rowKey=${(p) => p.id} defaultSort="id" defaultDir="asc"
            empty=${html`<${Empty} title="no phase rows yet"
              note="This build has not opened a phase, or its live record is not reachable from here." />`}
            columns=${[
              { key: 'phase', label: 'PHASE', sort: (p) => p.phase, cell: (p) => html`<span class="cell-name">${p.phase || '—'}</span>` },
              { key: 'runner', label: 'RUNNER', sort: (p) => p.runner, cell: (p) => html`<span>${p.runner || '—'}</span>` },
              { key: 'model', label: 'MODEL', sort: (p) => p.model, cell: (p) => html`<span class="na">${p.model || '—'}</span>` },
              {
                key: 'status', label: 'STATUS', sort: (p) => p.status,
                cell: (p) => html`<span class=${p.tone === 'dead' ? 'pill pill--dead' : p.tone === 'warn' ? 'pill pill--warn' : 'pill'}>
                  ${plainLabel(p.status || 'unknown')}</span>`
              },
              {
                key: 'duration_s', label: 'TOOK', sort: (p) => p.duration_s, align: 'right',
                // A phase that is still running has no duration yet, and a dash
                // says that where "0s" would claim it finished instantly.
                cell: (p) => html`<span class=${p.duration_s === null ? 'na' : ''}>${fmtDuration(p.duration_s)}</span>`
              },
              {
                key: 'spend_usd', label: 'SPEND', sort: (p) => p.spend_usd, align: 'right',
                cell: (p) => (p.spend_usd === null || p.spend_usd === undefined
                  ? html`<span class="num na">—</span>`
                  : html`<${UsdCell} value=${p.spend_usd} basis="api"/>`)
              }
            ]}/>
        <//>

        <${Section} title="TIMELINE" note=${`${fmtNum(timeline.length)} events`}>
          ${timeline.length
            ? html`<div class="panel panel__pad">
                ${timeline.map((e, i) => html`
                  <div key=${e.id} class="timeline__row">
                    <div class="timeline__rail">
                      <${TimelineDot} open=${i === timeline.length - 1} color=${i === timeline.length - 1 ? 'var(--amber)' : 'var(--green)'}/>
                      ${i < timeline.length - 1 ? html`<span class="timeline__line"></span>` : null}
                    </div>
                    <span class="timeline__text">
                      <span class="timeline__ts" title=${e.ts}>${whenLabel(e.ts, nowMs)}</span> · ${plainLabel(e.type)} · ${e.detail}
                    </span>
                  </div>`)}
              </div>`
            : html`<${Empty} title="no timeline events"
                note="No event rows point at this build." />`}
        <//>
      </div>
    </div>`;
}

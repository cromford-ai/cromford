import { useState, useCallback } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { TicketKey } from '../ui/TicketKey.js';
import { api, fetchLog, LOG_KINDS } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { MainRedBanner } from '../ui/MainRedBanner.js';
import { LogPane } from '../ui/LogPane.js';
import { SortableTable } from '../ui/SortableTable.js';
import {
  Section, Skeleton, Empty, ErrorBox, HealthPill, Age, Cursor
} from '../ui/primitives.js';
import { agoFromMinutes, minutesSince, snapshotLabel, prNumberFromUrl, fmtBytes, whenLabel } from '../lib/format.js';
import { plainLabel, tierLabel } from '../lib/labels.js';
import { stageProgress, buildLane, STEPS } from '../lib/stages.js';
import {
  PAUSE_WHATS, pauseCommandFor, resumeCommandFor, shapePauses, boardPauseLines
} from '../lib/pauses.js';
import { PauseReasonForm } from '../ui/PauseForms.js';
import { RoutingPanel } from './RoutingPanel.js';
import { PreplanAdoption } from './PreplanAdoption.js';
import BuildQueuePanel from './BuildQueuePanel.js';
import DeployQueuePanel from './DeployQueuePanel.js';
import MergeTrainsPanel from './MergeTrainsPanel.js';
import ConflictHotspotsPanel from './ConflictHotspotsPanel.js';
import { SetupRunLink } from './SetupLine.js';

export function ProjectScreen({ project }) {
  const p = useApi(() => api.project(project), [project], { intervalMs: 30000 });
  const costs = useApi(() => api.costs(), []);
  // The old cockpit's per-project page also showed the whole-ledger totals
  // behind these twenty rows, and the company map. Neither is in
  // /api/dash/p/<project>, so they come from the D1 read next door — a separate
  // call on purpose, so a D1 hiccup degrades one pane instead of the screen.
  const deep = useApi(() => api.cockpitProject(project), [project]);
  // The live pause rows, for the why/who/when under the header (BH-2509). The
  // same read as the Fleet page: a failed one is zero rows, never a crash.
  const pausesApi = useApi(() => api.pauses(), [project], { intervalMs: 30000 });
  const [which, setWhich] = useState('triage');
  const [busy, setBusy] = useState(null);
  const [actionMsg, setActionMsg] = useState(null);
  const [dialog, confirm] = useConfirm();

  const data = p.data || {};
  const board = data.board || {};
  const paused = Boolean(board.paused);
  const automerge = Boolean(board.automerge);

  // `cmd` is a command type, or a whole command when it carries more than
  // {type, project} (the PAUSE form's what/reason/ttl_s).
  const act = useCallback(async (cmd, label) => {
    const payload = typeof cmd === 'string' ? { type: cmd, project } : cmd;
    setBusy(payload.type);
    setActionMsg(null);
    try {
      const res = await api.action(payload);
      setActionMsg({ ok: true, text: `${label} queued as command #${res.command_id}` });
      p.reload();
    } catch (e) {
      setActionMsg({ ok: false, text: `${label} refused — ${e.message}` });
    } finally {
      setBusy(null);
    }
  }, [project, p]);

  const confirmAct = useCallback(async (type, label, body, tone) => {
    const ok = await confirm({ title: label, body, confirmLabel: label, tone });
    if (ok) act(type, label);
  }, [confirm, act]);

  // PAUSE takes what, reason and ttl. `form` is a fresh object per click that
  // PauseForm writes through, so typing never re-renders this page.
  const pauseAct = useCallback(async () => {
    const form = { what: 'triage', reason: '', ttlS: '' };
    const ok = await confirm({
      title: 'PAUSE', confirmLabel: 'PAUSE', tone: 'warn',
      confirmBlocked: pauseFormState(project, form).blocked,
      body: ({ setBlocked }) => html`<${PauseForm} project=${project} value=${form} onBlocked=${setBlocked}/>`
    });
    if (!ok) return;
    const cmd = pauseCommandFor(project, form);
    if (cmd.error) { setActionMsg({ ok: false, text: `PAUSE refused — ${cmd.error}` }); return; }
    act(cmd, 'PAUSE');
  }, [confirm, act, project]);

  // RESUME asks why (BH-2509), in a dialog blocked until a reason is typed.
  const resumeAct = useCallback(async () => {
    const form = { reason: '' };
    const ok = await confirm({
      title: 'RESUME', confirmLabel: 'RESUME', confirmBlocked: true,
      body: ({ setBlocked }) => html`<${PauseReasonForm} value=${form} onBlocked=${setBlocked}
        text=${html`Resume the harness on <b>${project}</b>? Triage ticks and builds start again on the next cadence.`}/>`
    });
    if (!ok) return;
    const cmd = resumeCommandFor(project, form.reason);
    if (cmd.error) { setActionMsg({ ok: false, text: `RESUME refused — ${cmd.error}` }); return; }
    act(cmd, 'RESUME');
  }, [confirm, act, project]);

  const logAction = useCallback((kind) => fetchLog(project, kind), [project]);

  if (p.loading && !p.data) {
    return html`<div class="page"><${PageHeadline} chip="Project" line1=${project} line2="Reading the project."/><${Skeleton} rows=${8} height=${22}/></div>`;
  }
  if (p.error && !p.data) {
    return html`<div class="page">
      <${Link} to="/" class="crumb">← FLEET<//>
      <${PageHeadline} chip="Project" line1=${project} line2="The project read failed."/>
      <${ErrorBox} error=${p.error} onRetry=${p.reload}/>
    </div>`;
  }

  const runs = data.runs || [];
  const builds = data.builds || [];
  const alerts = (data.alerts || []).filter((a) => !a.resolved);
  const lastRunAge = runs.length ? minutesSince(runs[0].finished_at || runs[0].started_at) : null;

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Project" line1=${project}
        line2=${`${builds.length} ${builds.length === 1 ? 'build' : 'builds'} on file. ${alerts.length} open ${alerts.length === 1 ? 'alert' : 'alerts'}.`}
        lede=${lastRunAge === null ? 'No tick on record.' : `Last tick ${agoFromMinutes(lastRunAge)}.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/" class="crumb">← FLEET<//>
        <span class="crumb-sep">/</span>
        <${HealthPill} ageMin=${lastRunAge}/>
        ${paused ? html`<span class="tag tag--warn">PAUSED</span>` : null}
        ${data.known === false ? html`
          <span class="tag" title="this name is not in the hub's last pushed registry">NOT IN REGISTRY</span>` : null}
        <span style="font-size:var(--fs-sm);color:var(--faint)">${snapshotLabel(minutesSince(data.snapshot_pushed_at))}</span>

        <div style="display:flex;gap:8px;margin-left:auto;flex-wrap:wrap">
          <${Link} to=${`/history?project=${encodeURIComponent(project)}`} class="btn">FULL HISTORY<//>
          <${Link} to=${`/needs?project=${encodeURIComponent(project)}`} class="btn">NEEDS<//>
          <${Link} to=${`/connections?project=${encodeURIComponent(project)}`} class="btn">CONNECTION<//>
          <${SetupRunLink} project=${project}/>
          <button class="btn" disabled=${busy !== null}
            onClick=${() => act('run_triage', 'FORCE TRIAGE')}>
            ${busy === 'run_triage' ? 'QUEUEING…' : 'FORCE TRIAGE'}
          </button>
          ${paused
            ? html`<button class="btn" disabled=${busy !== null}
                onClick=${resumeAct}>
                RESUME
              </button>`
            : html`<button class="btn btn--warn" disabled=${busy !== null}
                onClick=${pauseAct}>
                PAUSE
              </button>`}
          <button class=${automerge ? 'toggle' : 'toggle toggle--off'} disabled=${busy !== null}
            aria-pressed=${automerge ? 'true' : 'false'}
            onClick=${() => confirmAct(
              automerge ? 'automerge_off' : 'automerge_on',
              automerge ? 'TURN AUTOMERGE OFF' : 'TURN AUTOMERGE ON',
              automerge
                ? html`Turn auto-merge <b>off</b> for ${project}? Tier-1 APPROVE PRs will then sit in the review lane waiting for a human instead of merging themselves.`
                : html`Turn auto-merge <b>on</b> for ${project}? Tier-1 PRs carrying an APPROVE verdict will merge without anyone looking at them first.`,
              automerge ? 'warn' : null
            )}>
            AUTOMERGE
            <span class="toggle__track"><span class="toggle__knob"></span></span>
          </button>
        </div>
      </div>
      <${PauseDetail} rows=${shapePauses(pausesApi.data, Date.now()).rows} project=${project} paused=${paused} />
      <${MainRedBanner} project=${project} confirm=${confirm} />

      ${actionMsg ? html`
        <div class=${actionMsg.ok ? 'banner banner--warn' : 'banner'}
          style=${actionMsg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${actionMsg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => setActionMsg(null)}>DISMISS</button>
        </div>` : null}

      ${alerts.length ? html`
        <div class="banner banner--warn">
          <span><b>${alerts.length} open alert${alerts.length > 1 ? 's' : ''}</b> — ${alerts[0].line}</span>
          <${Link} to="/alerts" class="btn btn--sm" style="margin-left:auto">TRIAGE ALERTS<//>
        </div>` : null}

      <div class="split">
        <div class="split__col">
          <${Section} title="RECENT RUNS" note=${`${runs.length} most recent`}
            right=${html`<${Link} to=${`/history?project=${encodeURIComponent(project)}`}
              style="font-size:var(--fs-xs);letter-spacing:1px">ALL RUNS ›<//>`}>
            <${RunsTable} runs=${runs}/>
          <//>

          <${Section} title="BUILDS" note=${`${builds.length} most recent`}
            right=${html`<${Link} to=${`/history?tab=builds&project=${encodeURIComponent(project)}`}
              style="font-size:var(--fs-xs);letter-spacing:1px">ALL BUILDS ›<//>`}>
            <${BuildsTable} builds=${builds} project=${project}/>
          <//>

          <${Section} title="THE WHOLE LEDGER"
            note="every run and build on record for this project, not the most recent twenty">
            <${LedgerPanel} deep=${deep} project=${project}/>
          <//>
        </div>

        <div class="split__col">
          <${Section} title="QUEUES" note="build queue, deploy queue and merge trains for this project">
            <${BuildQueuePanel} project=${project}/>
            <${DeployQueuePanel} project=${project}/>
            <${MergeTrainsPanel} project=${project}/>
          <//>
          <${Section} title="ROUTING" note="builder, pool and halt for this project, from the routing row">
            <${RoutingPanel} project=${project}/>
          <//>
          <${Section} title="PREPLAN ADOPTION" note="how many bought pre-plans a build used, from stage_events"><${PreplanAdoption} project=${project}/><//>
          <${Section} title="CONFLICT HOTSPOTS" note="files that conflicted or were rebased most, measured weekly on this project's box"><${ConflictHotspotsPanel} project=${project}/><//>

          <${Section} title="LOG TAIL" note=${`fetched live from the ${project} box on request`}>
            <${LogPane}
              kinds=${LOG_KINDS.map((k) => ({ key: k, label: k.toUpperCase() }))}
              activeKind=${which}
              onKind=${setWhich}
              action=${logAction} />
          <//>

          <${Section} title="VOLUME · 7D"
            note="run and ticket counts — the denominator for cost-per-ticket, not a price">
            <${VolumePanel} costs=${costs} project=${project}/>
          <//>

          <${Section} title="EVENTS" note="most recent first">
            <${EventList} events=${data.events || []}/>
          <//>

          <${Section} title="COMPANY MAP"
            note="the brief the triage lane reads before it judges a ticket">
            <${CompanyMap} deep=${deep} project=${project}/>
          <//>
        </div>
      </div>

      <div class="footnote">
        <span>every run, build and PR here drills further · controls queue a command for the box, they do not act locally</span>
        <span class="footnote__spacer"></span>
        <${Cursor}/>
      </div>
    </div>`;
}

export function RunsTable({ runs, nowMs }) {
  const columns = [
    {
      key: 'started_at', label: 'TIME', sort: (r) => r.started_at,
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`}>${whenLabel(r.started_at, nowMs)}<//>`
    },
    { key: 'kind', label: 'KIND', sort: (r) => r.kind, cell: (r) => html`<span style="color:var(--soft)">${r.kind || '—'}</span>` },
    {
      key: 'rc', label: 'RC', sort: (r) => r.rc, align: 'right',
      cell: (r) => r.rc === null || r.rc === undefined
        ? html`<span class="na">—</span>`
        : html`<span class=${Number(r.rc) === 0 ? 'num--ok' : 'num--bad'}>${r.rc}</span>`
    },
    {
      key: 'summary', label: 'SUMMARY', sort: null,
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`} class="cell-wrap" title=${r.summary || ''}>
        ${r.summary || 'no summary'}<//>`
    },
    {
      key: 'age', label: 'AGE', sort: (r) => minutesSince(r.finished_at || r.started_at), align: 'right',
      cell: (r) => html`<${Age} min=${minutesSince(r.finished_at || r.started_at)} warnAt=${60}/>`
    }
  ];
  return html`<${SortableTable} columns=${columns} rows=${runs} rowKey=${(r) => r.id}
    defaultSort="started_at" defaultDir="desc"
    empty=${html`<${Empty} title="no runs on record"
      note="This project has not beaten a run row to the console yet." />`} />`;
}

export function BuildsTable({ builds, project }) {
  // A browse list, so it is a dense sortable table rather than a card wall:
  // the stage bar survives as a cell because it is the actual signal, and
  // every identity cell links on to the PR or the build.
  const columns = [
    {
      key: 'ticket_key', label: 'TICKET', sort: (b) => b.ticket_key || b.bkey,
      cell: (b) => {
        const n = prNumberFromUrl(b.pr_url);
        // BH-4991: the key opens the ticket page; the PR or build stays one click away.
        return html`<${TicketKey} k=${b.ticket_key} cls="cell-name" fallback=${b.bkey}
          alt=${{ to: n ? `/pr/${encodeURIComponent(project)}/${n}` : `/builds/${b.id}`, label: n ? 'PR' : 'build' }}/>`;
      }
    },
    {
      key: 'stage', label: 'STAGE', sort: (b) => b.stage,
      cell: (b) => {
        const prog = stageProgress(b.stage, b.merged);
        if (prog.dead) {
          return html`<span style="color:var(--red-txt)" title=${b.stage}>stopped at ${prog.label}</span>`;
        }
        return html`
          <span style="display:flex;align-items:center;gap:8px;min-width:150px">
            <span class="build__bar" style="flex:1;min-width:70px">
              ${STEPS.map((st, i) => html`
                <span key=${st} style=${`width:${100 / STEPS.length}%;background:${
                  prog.done || i < prog.step ? 'var(--green)' : i === prog.step ? 'var(--live)' : 'transparent'}`}></span>`)}
            </span>
            <span style="color:var(--soft);white-space:nowrap">${b.stage}</span>
          </span>`;
      }
    },
    {
      key: 'lane', label: 'LANE', sort: (b) => buildLane(b),
      cell: (b) => {
        const lane = buildLane(b);
        return html`<span class=${laneTagClass(lane)}>${laneLabel(lane)}</span>`;
      }
    },
    {
      key: 'tier', label: 'TIER', sort: (b) => b.tier, align: 'right',
      cell: (b) => b.tier ? html`<span class="num">${tierLabel(b.tier)}</span>` : html`<span class="na">no tier</span>`
    },
    {
      key: 'verdict', label: 'VERDICT', sort: (b) => b.verdict,
      cell: (b) => b.verdict
        ? html`<span class=${b.verdict === 'APPROVE' ? 'tag tag--green' : b.verdict === 'BLOCK' ? 'tag tag--dead' : 'tag tag--warn'}>${b.verdict}</span>`
        : html`<span class="na">—</span>`
    },
    {
      key: 'age_min', label: 'AGE', sort: (b) => b.age_min, align: 'right',
      cell: (b) => html`<${Age} min=${b.age_min} warnAt=${120}/>`
    },
    {
      key: 'links', label: '', sort: null, align: 'right',
      cell: (b) => {
        const n = prNumberFromUrl(b.pr_url);
        return html`<span style="display:inline-flex;gap:8px;white-space:nowrap">
          ${n ? html`<${Link} to=${`/pr/${encodeURIComponent(project)}/${n}`}>PR #${n}<//>` : null}
          <${Link} to=${`/builds/${b.id}`}>build #${b.id}<//>
        </span>`;
      }
    }
  ];

  return html`<${SortableTable}
    columns=${columns}
    rows=${builds}
    rowKey=${(b) => b.id}
    rowClass=${(b) => (buildLane(b) === 'dead' ? 'row--dead' : '')}
    defaultSort="age_min" defaultDir="asc"
    empty=${html`<${Empty} title="no builds on record"
      note="Nothing this project produced has beaten a build row into D1 yet." />`} />`;
}

// Exported for the legibility test: a lane the map does not know reads in words.
export const laneLabel = (lane) => ({
  merged: 'MERGED', merge_queue: 'MERGE QUEUE', review: 'NEEDS REVIEW',
  building: 'BUILDING', dead: 'DEAD'
}[lane] || (lane ? plainLabel(lane).toUpperCase() : 'UNKNOWN'));

const laneTagClass = (lane) => ({
  merged: 'tag tag--solid', merge_queue: 'tag tag--green', review: 'tag tag--warn',
  building: 'tag tag--cyan', dead: 'tag tag--dead'
}[lane] || 'tag');

// The whole-ledger totals. It is a separate read from /api/dash/p/<project>, so
// it reports its own failure rather than borrowing the screen's — a pane that
// silently renders zeros would say a project has never run.
function LedgerPanel({ deep, project }) {
  if (deep.loading && !deep.data) return html`<${Skeleton} rows=${3} height=${18}/>`;
  if (deep.error && !deep.data) return html`<${ErrorBox} error=${deep.error} onRetry=${deep.reload}/>`;
  const d = deep.data || {};
  const rs = d.run_stats || {};
  const stages = (d.build_stats && d.build_stats.by_stage) || [];
  const builds = stages.reduce((n, s) => n + Number(s.n || 0), 0);
  const kv = (label, value, to) => html`
    <div class="kv" key=${label}>
      <span class="kv__label">${label}</span>
      <span class="kv__val">${to ? html`<${Link} to=${to}>${value}<//>` : value}</span>
    </div>`;
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:2px">
      ${kv('runs on record', rs.runs ?? 0, `/history?project=${encodeURIComponent(project)}`)}
      ${kv('of those, non-zero exit', rs.failed ?? 0,
        `/history?project=${encodeURIComponent(project)}&outcome=failed`)}
      ${kv('first run', rs.first_run_at ? String(rs.first_run_at).slice(0, 10) : '—')}
      ${kv('builds on record', builds, `/history?tab=builds&project=${encodeURIComponent(project)}`)}
      ${(rs.by_kind || []).map((k) => kv(`${k.kind} runs`, k.n,
        `/history?project=${encodeURIComponent(project)}&kind=${encodeURIComponent(k.kind)}`))}
      ${stages.slice(0, 6).map((s) => kv(`builds at ${s.stage}`, s.n))}
    </div>`;
}

// The company map is 16-18KB of per-project brief that lives ONLY in this D1 —
// no screen has ever rendered it, and the old cockpit is where it was read. It
// is long, so it opens collapsed with its size and age on the summary line.
function CompanyMap({ deep, project }) {
  if (deep.loading && !deep.data) return html`<${Skeleton} rows=${2} height=${18}/>`;
  if (deep.error && !deep.data) return html`<${ErrorBox} error=${deep.error} onRetry=${deep.reload}/>`;
  const map = deep.data && deep.data.company_map;
  if (!map || !map.content) {
    return html`<${Empty} title="no company map"
      note=${`Nothing has beaten a company map for ${project}. bin/load-project.sh writes it when the project is onboarded.`} />`;
  }
  return html`
    <details class="panel panel__pad">
      <summary style="cursor:pointer;font-size:var(--fs-sm);color:var(--soft)">
        ${fmtBytes(map.bytes)} · updated ${map.updated_at ? String(map.updated_at).slice(0, 10) : '—'}
        <span style="color:var(--faint)"> — click to read</span>
      </summary>
      <pre class="term" style="margin-top:10px">${map.content}</pre>
    </details>`;
}

function VolumePanel({ costs, project }) {
  if (costs.loading && !costs.data) return html`<${Skeleton} rows=${2} height=${30}/>`;
  if (costs.error && !costs.data) return html`<${ErrorBox} error=${costs.error} onRetry=${costs.reload}/>`;
  const row = ((costs.data && costs.data.volume) || []).find((v) => v.project === project);
  if (!row) {
    return html`<${Empty} title="no volume in the window"
      note=${`Nothing ran for ${project} in the last ${(costs.data && costs.data.window_days) || 7} days.`} />`;
  }
  const max = Math.max(row.runs || 0, row.tickets_built || 0, 1);
  const bar = (n) => Math.max(6, Math.round((n / max) * 100));
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:12px">
      ${[['runs', row.runs], ['tickets built', row.tickets_built], ['failed runs', row.failed_runs]].map(([label, n]) => html`
        <div key=${label} style="display:flex;flex-direction:column;gap:5px">
          <div style="display:flex;font-size:var(--fs-xs);color:var(--faint)">
            <span>${label}</span><span style="margin-left:auto;color:var(--bright);font-weight:700">${n ?? 0}</span>
          </div>
          <div class="meter"><div class=${label === 'failed runs' && n ? 'meter__fill' : 'meter__fill meter__fill--hi'}
            style=${`width:${n ? bar(n) : 0}%;${label === 'failed runs' && n ? 'background:var(--red-lt)' : ''}`}></div></div>
        </div>`)}
      <${Link} to="/costs" style="font-size:var(--fs-xs);letter-spacing:1px">WHY THERE IS NO PRICE HERE ›<//>
    </div>`;
}

function EventList({ events, nowMs }) {
  if (!events.length) {
    return html`<${Empty} title="no events" note="Nothing has beaten an event row for this project." />`;
  }
  return html`
    <div class="panel panel__pad" style="display:flex;flex-direction:column;gap:0;max-height:260px;overflow-y:auto">
      ${events.slice(0, 40).map((e) => html`
        <div key=${e.id} class="timeline__row">
          <span class="timeline__text">
            <span class="timeline__ts">${whenLabel(e.ts, nowMs)}</span> · ${e.type} · ${e.detail}
          </span>
        </div>`)}
    </div>`;
}

// Whether the PAUSE form may be sent, and the inline line that says why not.
// One rule, pauseCommandFor's: PAUSE is disabled exactly when the command it
// would send is refused, so the button and the backstop can never disagree.
// The worker 400s a blank reason, so the form opens blocked.
export function pauseFormState(project, form) {
  const cmd = pauseCommandFor(project, form);
  if (!cmd.error) return { blocked: false, hint: null };
  return {
    blocked: true,
    hint: cmd.error === 'reason required'
      ? 'A reason is required: it is recorded on the pause and shown on its PAUSED tag.'
      : cmd.error
  };
}

// The PAUSE dialog's fields. Its own state drives the inputs and every change
// is written through to `value`, the object pauseAct reads on confirm, and
// reports to the dialog whether PAUSE may be pressed (onBlocked). pauseAct
// still runs pauseCommandFor on confirm, so a bad ttl is refused with a
// message rather than silently fixed here.
export function PauseForm({ project, value, onBlocked }) {
  const [f, setF] = useState(value);
  const set = (k) => (e) => {
    value[k] = e.target.value;
    setF({ ...value });
    if (onBlocked) onBlocked(pauseFormState(project, value).blocked);
  };
  const { hint } = pauseFormState(project, f);
  const field = 'knob__input';
  const full = 'width:100%';
  return html`
    <div style="display:flex;flex-direction:column;gap:10px">
      <span>
        ${f.what === 'triage'
          ? html`Pause the harness on <b>${project}</b>? Triage stops running and no new build is launched until it is resumed. Builds already in flight are not killed.`
          : html`Pause <b>${f.what}</b> on <b>${project}</b>. Lanes that honour this pause stop until it ends or expires.`}
      </span>
      <label class="knob" style=${full}>
        <span class="knob__label">WHAT</span>
        <select class=${field} style=${full} value=${f.what} onChange=${set('what')}>
          ${PAUSE_WHATS.map((w) => html`<option key=${w} value=${w}>${w}</option>`)}
        </select>
      </label>
      <label class="knob" style=${full}>
        <span class="knob__label">REASON</span>
        <input class=${field} style=${full} type="text" value=${f.reason} onInput=${set('reason')}
          placeholder="why, for whoever sees the tag" required aria-required="true" />
      </label>
      <label class="knob" style=${full}>
        <span class="knob__label">TTL (SECONDS)</span>
        <input class=${field} style=${full} type="text" inputmode="numeric" value=${f.ttlS} onInput=${set('ttlS')}
          placeholder="default" />
      </label>
      ${hint ? html`<span class="knob__note knob__note--bad" style="max-width:none" role="status">${hint}</span>` : null}
    </div>`;
}

// Why, who and when for every pause on this board (BH-2509): one line per live
// row covering it, fleet rows included, and the flag-file line when the box
// is paused with no triage row on record. Nothing when neither applies.
export function PauseDetail({ rows, project, paused }) {
  const lines = boardPauseLines(rows, project, paused);
  if (!lines.length) return null;
  return html`
    <ul class="pause-detail" aria-label="pauses on this board"
      style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px;font-size:var(--fs-sm)">
      ${lines.map((l) => html`
        <li key=${l.key} style="display:flex;gap:8px;flex-wrap:wrap;align-items:baseline;overflow-wrap:anywhere;min-width:0">
          ${l.what
            ? html`<span class="tag tag--bad">PAUSED(${l.what})</span>`
            : html`<span class="tag tag--warn">PAUSED</span>`}
          <span style="min-width:0">${l.text}</span>
        </li>`)}
    </ul>`;
}

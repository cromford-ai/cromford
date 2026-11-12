import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, ProjectLink } from '../ui/primitives.js';
import { whenLabel, countOrNull, safeHttpsUrl, fmtNum } from '../lib/format.js';
import { plainLabel } from '../lib/labels.js';
import { runOutcome, OUTCOME_LABEL } from '../lib/cockpit.js';
import { UsdCell } from '../ui/UsdCell.js';
import { jobState, jobTone, budgetUse, ageLabel, phaseRows } from '../lib/jobs.js';
import { TranscriptList } from '../ui/Transcript.js';
import { JobActions } from '../ui/JobActions.js';
import { transcriptRows, emptyStateNote } from '../lib/transcripts.js';

// One job, all the way down: the claim, every phase it opened, the CONVERSATION
// each attempt had, every stage event it emitted, and any ledger row that names
// it. The transcript is the new bottom of the drill-down - below a stage event
// used to be a build dir on a box behind ssh, and now the session that produced
// it is one click away. What is still below THAT lives in the build dir and the
// PR, which this page links to when the row carries them.
export function JobScreen({ id }) {
  const j = useApi(() => api.job(id), [id], { intervalMs: 20000 });

  if (j.loading && !j.data) return html`<div class="page"><${PageHeadline} chip="Job" line1=${id} line2="Reading the job."/><${Skeleton} rows=${6} height=${20}/></div>`;
  if (j.error && !j.data) {
    return html`<div class="page">
      <${Link} to="/jobs" class="crumb">← JOBS<//>
      <${PageHeadline} chip="Job" line1=${id} line2="The job read failed."/>
      <${ErrorBox} error=${j.error} onRetry=${j.reload}/>
    </div>`;
  }

  return html`<${JobView} data=${j.data} onReload=${j.reload}/>`;
}

// The page itself, apart from the read, so a render test can hand it a payload.
export function JobView({ data, onReload, nowMs = Date.now() }) {
  const job = data.job || {};
  const phases = phaseRows(data);
  const events = data.events || [];
  const transcripts = transcriptRows(data);
  const ledgers = data.ledgers || [];
  const state = jobState(job);
  const tone = jobTone(state);
  const use = budgetUse(job);
  const meta = parseMeta(job.meta);
  const pr = meta && typeof meta.pr === 'string' ? safeHttpsUrl(meta.pr) : null;

  return html`
    <div class="page">
      <${PageHeadline} chip="Job" line1=${job.id}
        line2=${`${plainLabel(state)}. ${fmtNum(phases.length)} ${phases.length === 1 ? 'phase' : 'phases'}, ${fmtNum(events.length)} ${events.length === 1 ? 'event' : 'events'}.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/jobs" class="crumb">← JOBS<//>
        <span class=${tone === 'dead' ? 'pill pill--dead' : tone === 'warn' ? 'pill pill--warn' : 'pill'}>
          ${state.toUpperCase().replace('_', ' ')}</span>
      </div>

      <div class="stats" style="margin:10px 0">
        <${Stat} label="PROJECT" value=${job.project || '-'} tone="sm"
          to=${job.project && job.project !== 'orchestrator' ? `/p/${encodeURIComponent(job.project)}` : null}/>
        <${Stat} label="LANE" value=${`${job.kind || '?'}/${job.stage || '?'}`} tone="sm"/>
        <${Stat} label="BOX" value=${job.box || '-'} tone="sm"/>
        <${Stat} label="SPENT" value=${html`<${UsdCell} value=${job.spent_usd}/>`} tone="sm"/>
        <${Stat} label="CAP (MAX-COST FUSE)" tone="sm"
          value=${job.budget_usd === null || job.budget_usd === undefined || job.budget_usd === ''
            ? countOrNull(null, { uncapped: true })
            : html`<${UsdCell} value=${job.budget_usd}/>`}/>
        <${Stat} label="OF CAP" value=${use === null ? '-' : `${fmtNum(Math.round(use * 100))}%`}
          tone=${use !== null && use >= 1 ? 'warn' : 'sm'}/>
        <${Stat} label="LAST BEAT"
          value=${job.heartbeating ? `${ageLabel(job.beat_age_s)} ago` : 'never'}
          tone=${state === 'stalled' || state === 'orphaned' ? 'warn' : 'sm'}/>
      </div>

      <${JobActions} key=${job.id} job=${job} onDone=${onReload}/>

      ${state === 'orphaned' || state === 'stalled' ? html`
        <div class="banner">
          <span>
            <b>This claim stopped heartbeating.</b> ${state === 'orphaned'
              ? 'bin/jobs-watchdog.sh has marked it orphaned, so the ticket is claimable again.'
              : 'The watchdog has not judged it yet; its next scan will.'}
            ${job.failed_phase ? `It was in the ${job.failed_phase} phase when the beats stopped.` : ''}
            Nothing was retried - a kill is the OS ending the process, and re-running it blind races the
            double-build guard. The forensics line, if this box wrote one, is in logs/kills.log.
          </span>
        </div>` : null}

      ${job.ticket_id || pr ? html`
        <div class="footnote" style="gap:12px">
          ${job.ticket_id ? html`<span>ticket <span>${job.ticket_id}</span></span>` : null}
          ${pr ? html`<a href=${pr} target="_blank" rel="noopener noreferrer">open the PR</a>` : null}
        </div>` : null}

      <${Section} title="PHASES"
        note=${`${fmtNum(phases.length)} on file - one row per stage attempt, with the exit code and the dollars it actually cost`}>
        <${SortableTable} rows=${phases} rowKey=${(p) => p.id} defaultSort="id" defaultDir="asc"
          empty=${html`<${Empty} title="NO PHASE ROWS"
            note="This claim opened no stage - it may predate per-phase tracking, or it ended before its first stage started."/>`}
          columns=${[
            { key: 'started_at', label: 'STARTED', sort: (p) => p.started_at, cell: (p) => html`<span title=${p.started_at}>${whenLabel(p.started_at, nowMs)}</span>` },
            { key: 'phase', label: 'PHASE', sort: (p) => p.phase, cell: (p) => html`<span class="cell-name" title=${p.phase}>${plainLabel(p.phase)}</span>` },
            {
              key: 'status', label: 'STATUS', sort: (p) => p.status,
              cell: (p) => html`<span class=${p.tone === 'dead' ? 'pill pill--dead' : p.tone === 'warn' ? 'pill pill--warn' : 'pill'}>
                ${plainLabel(p.status)}</span>`
            },
            { key: 'runner', label: 'RUNNER', sort: (p) => p.runner, cell: (p) => html`<span>${p.runner || '-'}</span>` },
            { key: 'model', label: 'MODEL', sort: (p) => p.model, cell: (p) => html`<span class="na">${p.model || '-'}</span>` },
            {
              // The REAL exit code, unlaundered: 137 is a kill, and a phase that
              // says so is the difference between "the vendor broke" and "the OS
              // ended us", which are two different responses.
              // The words come from runOutcome; the raw code stays in the title.
              key: 'rc', label: 'RESULT', raw: 'RC', sort: (p) => p.rc, align: 'right',
              cell: (p) => (runOutcome({ rc: p.rc }) === 'unknown'
                ? html`<span class="na" title=${p.rc === null || p.rc === undefined ? undefined : `exit code ${p.rc}`}>-</span>`
                : html`<span class=${Number(p.rc) === 0 ? 'num' : 'num--warn'} title=${`exit code ${p.rc}`}>${OUTCOME_LABEL[runOutcome({ rc: p.rc })]}</span>`)
            },
            {
              key: 'spend_usd', label: 'SPENT', sort: (p) => Number(p.spend_usd) || 0, align: 'right',
              cell: (p) => html`<${UsdCell} value=${p.spend_usd}/>`
            },
            {
              key: 'duration_s', label: 'TOOK', sort: (p) => p.duration_s, align: 'right',
              cell: (p) => (p.duration_s === null
                ? html`<span class="na" title="this phase never closed, so it has no honest duration">-</span>`
                : html`<span>${ageLabel(p.duration_s)}</span>`)
            },
            { key: 'note', label: 'NOTE', sort: null, cell: (p) => html`<span class="na">${p.note || '-'}</span>` }
          ]}/>
      <//>

      <${Section} title="TRANSCRIPT"
        note=${transcripts.length
          ? `${fmtNum(transcripts.length)} attempt${transcripts.length === 1 ? '' : 's'} on file - click one to read the conversation`
          : 'what the model was actually doing, when a model ran'}>
        <${TranscriptList} jobId=${job.id} rows=${transcripts} emptyNote=${emptyStateNote(data)}/>
      <//>

      <${Section} title="STAGE EVENTS" note=${`${fmtNum(events.length)} on file - the atomic record this job left behind`}>
        <${SortableTable} rows=${events} rowKey=${(e) => e.id} defaultSort="id" defaultDir="asc"
          empty=${html`<${Empty} title="NO STAGE EVENTS"
            note="This job closed without emitting one, or it is still on its first stage."/>`}
          columns=${[
            { key: 'created_at', label: 'WHEN', sort: (e) => e.created_at, cell: (e) => html`<span title=${e.created_at}>${whenLabel(e.created_at, nowMs)}</span>` },
            { key: 'stage', label: 'STAGE', sort: (e) => e.stage, cell: (e) => html`<span>${e.stage}</span>` },
            {
              key: 'verdict', label: 'VERDICT', sort: (e) => e.verdict,
              cell: (e) => (e.verdict
                ? html`<span class=${/FAIL|REJECT|ORPHANED|BUDGET_STOP/.test(e.verdict) ? 'pill pill--warn' : 'pill'}>${e.verdict}</span>`
                : html`<span class="na">-</span>`)
            },
            { key: 'actor', label: 'ACTOR', sort: (e) => e.actor, cell: (e) => html`<span>${e.actor}</span>` },
            { key: 'detail', label: 'DETAIL', sort: null, cell: (e) => html`<span class="na">${e.detail || '-'}</span>` }
          ]}/>
      <//>

      <${Section} title="LEDGER ROWS" note="merge / migration decisions recorded against this job">
        <${SortableTable} rows=${ledgers} rowKey=${(l) => `${l.kind}:${l.key}`} defaultSort="updated_at" defaultDir="desc"
          empty=${html`<${Empty} title="NO LEDGER ROWS"
            note="Only merge-sweep and migration-autopilot write these, so most jobs have none."/>`}
          columns=${[
            { key: 'kind', label: 'KIND', sort: (l) => l.kind, cell: (l) => html`<span>${l.kind}</span>` },
            {
              key: 'key', label: 'KEY', sort: (l) => l.key,
              cell: (l) => {
                const url = safeHttpsUrl(l.key);
                return url
                  ? html`<a href=${url} target="_blank" rel="noopener noreferrer" class="cell-name">${l.key}</a>`
                  : html`<span>${l.key}</span>`;
              }
            },
            { key: 'status', label: 'STATUS', sort: (l) => l.status, cell: (l) => html`<span class="pill">${l.status}</span>` },
            { key: 'updated_at', label: 'UPDATED', sort: (l) => l.updated_at, cell: (l) => html`<span title=${l.updated_at}>${whenLabel(l.updated_at, nowMs)}</span>` }
          ]}/>
      <//>

      ${job.meta ? html`
        <${Section} title="META" note="what the claimant recorded about itself - never a secret, by contract">
          <pre class="term">${typeof job.meta === 'string' ? job.meta : JSON.stringify(job.meta, null, 2)}</pre>
        <//>` : null}
    </div>`;
}

// meta is free-form JSON written by a box, so it is untrusted input: a string
// that does not parse is shown as itself rather than throwing the page away.
function parseMeta(meta) {
  if (!meta) return null;
  if (typeof meta === 'object') return meta;
  try { return JSON.parse(meta); } catch { return null; }
}

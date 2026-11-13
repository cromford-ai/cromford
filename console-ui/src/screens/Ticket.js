// /t/<KEY> (BH-4991, BH-4947 wave 2): the ticket page. Every ticket key across
// the console links here (ui/TicketKey.js). It replaces the wave 1 stub.
//
// Layout per the reference's #t/ view (cromford-web
// docs/design/mission-control-line.html): a state chip, the headline, a meta
// line where every fact is a link, the station track (a station with events
// scrolls to its first one), the actions, the agent session with its "Step in"
// composer and note echo (BH-5839), "What happened", the details card, cost by stage and files changed,
// then every job row of the ticket.
//
// The reads: the job rows (api.jobs({ticket_id})), the newest build job's
// detail (api.job), the project row (api.projects), the PR (api.pr), the hold
// (useTicketHold) and the newest transcript (api.jobTranscript) are what Jobs,
// Job, Build and PR already fetch. The ticket's steer notes (api.steerNotes)
// feed the "Step in" echo, and a send reloads them.

import { useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi, useDocumentVisible } from '../lib/hooks.js';
import { Skeleton, ErrorBox } from '../ui/primitives.js';
import { PageHeadline, SectionHead, StationTrack } from '../ui/line.js';
import { SortableTable } from '../ui/SortableTable.js';
import { UsdCell } from '../ui/UsdCell.js';
import { useTicketHold, TicketHoldControl } from '../ui/TicketHold.js';
import { AgentSession } from '../ui/AgentSession.js';
import { jobRows, ageLabel } from '../lib/jobs.js';
import { lineTickets, STATIONS } from '../lib/line.js';
import { clockTime, fmtNum } from '../lib/format.js';
import { transcriptRows } from '../lib/transcripts.js';
import {
  ticketJob, ticketFacts, stageCosts, eventTimeline, firstEventOf,
  parseTranscript, sessionLive, stationName
} from '../lib/ticket-detail.js';
import { JobsTable } from './Jobs.js';

const REFRESH_MS = 20000;

export function TicketScreen({ ticket }) {
  const jobs = useApi(() => api.jobs({ ticket_id: ticket, limit: 100 }), [ticket], { intervalMs: REFRESH_MS });
  const rows = jobs.data ? jobRows(jobs.data) : [];
  const job = ticketJob(rows);
  const jobId = job ? job.id : null;
  const project = job ? job.project : null;
  const visible = useDocumentVisible();

  const detail = useApi(() => (jobId ? api.job(jobId) : Promise.resolve(null)), [jobId], { intervalMs: REFRESH_MS });
  const projects = useApi(() => (project ? api.projects() : Promise.resolve(null)), [project], { intervalMs: 300000 });
  const projectRow = projects.data && Array.isArray(projects.data.projects)
    ? projects.data.projects.find((p) => p.project === project) || null : null;
  const prNo = ticketFacts({ ticket, rows, detail: okDetail(detail.data), pr: null, project: projectRow }).prNumber;
  const pr = useApi(() => (project && prNo ? api.pr(project, prNo) : Promise.resolve(null)), [project, prNo], { intervalMs: 60000 });
  // The transcript polls only while the tab is in front, as Chat does.
  const trs = transcriptRows(okDetail(detail.data) || {});
  const last = trs.length ? trs[trs.length - 1] : null;
  const transcript = useApi(() => (jobId && last ? api.jobTranscript(jobId, last.phase_id, last.attempt) : Promise.resolve(null)),
    [jobId, last ? last.key : null], { intervalMs: visible ? REFRESH_MS : 0 });
  const th = useTicketHold(project, ticket);
  const notes = useApi(() => (project ? api.steerNotes(project, ticket) : Promise.resolve(null)), [project, ticket], { intervalMs: REFRESH_MS });

  if (jobs.error && !jobs.data) {
    return html`<div class="page">
      <${Link} to="/jobs" class="crumb">← JOBS<//>
      <h1 class="line-headline">${ticket}</h1>
      <${ErrorBox} error=${jobs.error} onRetry=${jobs.reload}/>
    </div>`;
  }
  if (!jobs.data) {
    return html`<div class="page">
      <${Link} to="/jobs" class="crumb">← JOBS<//>
      <h1 class="line-headline">${ticket}</h1>
      <${Skeleton} rows=${4} height=${20}/>
    </div>`;
  }
  return html`
    <${TicketView} ticket=${ticket} rows=${rows} asOf=${jobs.data.as_of || null}
      detail=${okDetail(detail.data)} pr=${okPr(pr.data)} project=${projectRow}
      transcriptBody=${transcript.data && transcript.data.transcript ? transcript.data.transcript.body : null}
      hold=${th.hold} holdReload=${th.reload}
      steerNotes=${notes.data && Array.isArray(notes.data.notes) ? notes.data.notes : null}
      steerError=${notes.error ? notes.error.message || 'load failed' : null} steerReload=${notes.reload}/>`;
}

// A payload that is not the shape the page reads is treated as absent.
const okDetail = (d) => (d && typeof d === 'object' && d.job && typeof d.job === 'object' ? d : null);
const okPr = (p) => (p && typeof p === 'object' && (p.gh || Array.isArray(p.files)) ? p : null);

const STATE_CHIP = { now: 'On the line', held: 'Parked', fail: 'Stopped' };

export function TicketView({
  ticket, rows = [], asOf = null, detail = null, pr = null, project = null, transcriptBody = null,
  hold = null, holdReload, steerNotes = null, steerError = null, steerReload
}) {
  const composeRef = useRef(null);
  const line = lineTickets(rows);
  const projects = [...new Set(rows.map((r) => r.project).filter(Boolean))];
  const where = line.length
    ? `On the line in ${line.map((t) => t.project).join(' and ')}.`
    : rows.length ? 'Not on the line: no row for it is open.' : '';

  if (!rows.length) {
    return html`
      <div class="page">
        <${Link} to="/jobs" class="crumb">← JOBS<//>
        <${PageHeadline} chip="Ticket" asOf=${asOf ? `Coordination DB · as of ${clockTime(asOf)}` : null}
          line1=${ticket} line2="No jobs on file."/>
        <div class="empty">
          <span class="empty__title">NOTHING ON FILE</span>
          <span class="empty__note">No job has claimed ${ticket}. A ticket shows up here once a lane claims a row for it.</span>
          <${Link} to="/jobs" class="btn">BACK TO JOBS<//>
        </div>
      </div>`;
  }

  const f = ticketFacts({ ticket, rows, detail, pr, project });
  const tl = eventTimeline(detail && detail.events);
  const costs = stageCosts(detail && detail.phases);
  const targets = STATIONS.map((_, i) => { const id = firstEventOf(tl, i); return id === null ? null : `ev-${id}`; });
  const live = sessionLive(f.job, detail && detail.phases);
  const feed = parseTranscript(transcriptBody);
  const files = pr && Array.isArray(pr.files) ? pr.files : [];
  const lineAt = f.line ? f.line.at : null;
  const projLink = f.project ? `/p/${encodeURIComponent(f.project)}` : null;
  const prPage = f.project && f.prNumber ? `/pr/${encodeURIComponent(f.project)}/${f.prNumber}` : null;
  const toCompose = () => {
    const el = composeRef.current;
    if (el && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  };

  return html`
    <div class="page">
      <${Link} to="/jobs" class="crumb">← JOBS<//>
      <${PageHeadline} chip=${f.line ? STATE_CHIP[f.line.state] || 'Ticket' : 'Ticket'}
        asOf=${`Coordination DB${asOf ? ` · as of ${clockTime(asOf)}` : ''}`}
        line1=${ticket}
        line2=${f.title || `${fmtNum(rows.length)} ${rows.length === 1 ? 'job' : 'jobs'} in ${fmtNum(projects.length)} ${projects.length === 1 ? 'project' : 'projects'}.`}
        lede=${where}/>

      <div class="d-meta">
        ${f.project ? html`<span>Project <${Link} to=${projLink}>${f.project}<//></span>` : null}
        ${f.issueUrl ? html`<span>Issue <a href=${f.issueUrl} target="_blank" rel="noopener noreferrer">#${f.issue}</a></span>` : null}
        ${prPage ? html`<span>PR <${Link} to=${prPage}>#${f.prNumber}<//></span>` : null}
        ${f.box ? html`<span>Box <${Link} to="/machines">${f.box}<//></span>` : null}
        ${f.age_s !== null ? html`<span>${ageLabel(f.age_s)} since the first job</span>` : null}
        ${f.cost !== null ? html`<span><${UsdCell} value=${f.cost}/> so far</span>` : null}
        ${f.job ? html`<span>Job <${Link} to=${`/jobs/${encodeURIComponent(f.job.id)}`}>${f.job.id}<//></span>` : null}
      </div>

      ${line.map((t) => html`
        <div class="track-scroll" key=${t.project}>
          <${StationTrack} at=${t.at} state=${t.state} times=${t.times} label=${t.key} targets=${f.line && t.project === f.line.project ? targets : []}/>
        </div>`)}

      <div class="d-actions">
        ${f.issueUrl ? html`<a class="btn" href=${f.issueUrl} target="_blank" rel="noopener noreferrer">OPEN ON GITHUB ↗</a>` : null}
        ${f.prUrl ? html`<a class="btn" href=${`${f.prUrl}/files`} target="_blank" rel="noopener noreferrer">SEE THE DIFF ↗</a>` : null}
        <button type="button" class="btn" onClick=${toCompose}>STEP IN</button>
        ${f.job ? html`<${Link} to=${`/jobs/${encodeURIComponent(f.job.id)}`} class="btn">LOGS<//>` : null}
        ${hold && hold.held ? html`<${TicketHoldControl} project=${f.project} ticket=${ticket} hold=${hold} reload=${holdReload}/>` : null}
      </div>

      <${AgentSession} live=${live} stage=${stationName(lineAt)} feed=${feed} composeRef=${composeRef}
        project=${f.project} ticket=${ticket} job=${f.job} notes=${steerNotes} notesError=${steerError} onSent=${steerReload}/>

      <section class="grid2">
        <div class="tp-card">
          <h3 class="tp-card__head"><span>What happened</span><span class="na">click a station to jump</span></h3>
          ${tl.length ? html`
            <ul class="tl">
              ${tl.map((e) => html`
                <li key=${e.id} id=${`ev-${e.id}`}>
                  <span class="tl__ts" title=${e.at}>${clockTime(e.at)}</span>
                  <div class="tl__what">
                    <span class="tl__stage">${e.stage}${e.verdict ? ` · ${e.verdict}` : ''}</span>
                    ${e.text ? html`<span>${e.text}</span>` : null}
                    ${e.output ? html`<details class="tl__out"><summary>Output</summary><pre class="term">${e.output}</pre></details>` : null}
                  </div>
                </li>`)}
            </ul>`
            : html`<p class="na">No stage events on file for ${f.job ? f.job.id : 'this ticket'} yet.</p>`}
        </div>
        <div class="d-side">
          <div class="tp-card">
            <h3 class="tp-card__head"><span>Details</span></h3>
            <dl class="tp-kv">
              <dt>Review</dt><dd>${f.verdict || html`<span class="na">not yet</span>`}</dd>
              <dt>Branch</dt><dd class="mono">${f.branch || html`<span class="na">—</span>`}</dd>
              <dt>Model</dt><dd>${f.model ? html`<${Link} to="/models">${f.model}<//>` : html`<span class="na">—</span>`}</dd>
              <dt>Box</dt><dd>${f.box ? html`<${Link} to="/machines">${f.box}<//>` : html`<span class="na">—</span>`}</dd>
              <dt>Repo</dt><dd>${f.repo ? html`<a href=${`https://github.com/${f.repo}`} target="_blank" rel="noopener noreferrer">${f.repo}</a>` : html`<span class="na">—</span>`}</dd>
            </dl>
          </div>
          <div class="tp-card">
            <h3 class="tp-card__head"><span>Cost by stage</span><span><${UsdCell} value=${costs.total}/></span></h3>
            <${SortableTable} rows=${costs.rows} rowKey=${(r) => r.stage} defaultSort="station" defaultDir="asc"
              empty=${html`<p class="na">No phase has reported yet.</p>`}
              columns=${[
                { key: 'stage', label: 'STAGE', sort: (r) => r.stage,
                  cell: (r) => (targets[r.station] ? html`<a href=${`#${targets[r.station]}`} class="tk">${r.stage}</a>` : html`<span>${r.stage}</span>`) },
                { key: 'station', label: 'STATION', sort: (r) => r.station ?? 99, cell: (r) => html`<span>${stationName(r.station) || '—'}</span>` },
                { key: 'model', label: 'MODEL', sort: (r) => r.model, cell: (r) => html`<span class="mono">${r.model || '—'}</span>` },
                { key: 'cost', label: 'COST', sort: (r) => r.cost ?? -1, align: 'right', cell: (r) => html`<${UsdCell} value=${r.cost}/>` }
              ]}/>
          </div>
          ${files.length ? html`
            <div class="tp-card">
              <h3 class="tp-card__head"><span>Files changed</span><span>${fmtNum(files.length)}</span></h3>
              <ul class="files">
                ${files.map((x) => html`
                  <li key=${x.filename}>
                    <a class="tk" href=${`${f.prUrl}/files`} target="_blank" rel="noopener noreferrer">${x.filename}</a>
                    <span><span class="add">+${x.additions}</span> <span class="del">−${x.deletions}</span></span>
                  </li>`)}
              </ul>
            </div>` : null}
        </div>
      </section>

      <${SectionHead} num=${1} title="Jobs" note="Every job row for this ticket. Open one for its phases, spend and transcript."/>
      <${JobsTable} rows=${rows}/>
    </div>`;
}

import { useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { useConfirm } from '../ui/Modal.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { fmtUsd, fmtDuration, whenLabel } from '../lib/format.js';
import { BlockCategoriesSection } from './BlockCategories.js';
import {
  SPEND_KEY, CONCURRENCY_KEY, AUTO_REPOS_ENV, DRIFT_LIMIT, WORKLIST_LIMIT, RUNNING_LIMIT, FAILED_LIMIT,
  autoReposFrom, projectByRepo, prHref, driftCount, failedRows, parseLimit, limitState, sinceIso,
  prOfJob, worklistRows
} from '../lib/lead-reviews.js';

// BH-4957 (BH-4950.4): what the lead review lane is doing. A stat strip
// (today's spend against its cap, running against the concurrency limit, and
// how much PR state the reconcile had to repair in 24h), then three tables:
// the worklist the lane takes PRs from, the reviews running now, and the PRs
// whose review failed on the head they have now. Every number is read live;
// the only write is the two limits, through the audited settings PUT.

const POLL = { intervalMs: 60000 };

// One gate + one needs-review read per auto repo. A repo that fails is named,
// and the readable repos still render (D12).
async function loadRepos(repos) {
  return Promise.all(repos.map(async (repo) => {
    const [needs, gate] = await Promise.allSettled([api.prNeedsReview(repo, WORKLIST_LIMIT), api.prGate(repo)]);
    return {
      repo,
      needs: needs.status === 'fulfilled' && needs.value && Array.isArray(needs.value.rows) ? needs.value.rows : null,
      gate: gate.status === 'fulfilled' && gate.value && Array.isArray(gate.value.rows) ? gate.value.rows : null,
      error: [needs, gate].filter((r) => r.status === 'rejected').map((r) => String(r.reason && r.reason.message || r.reason))[0]
        || ((needs.status === 'fulfilled' && !Array.isArray(needs.value && needs.value.rows))
          || (gate.status === 'fulfilled' && !Array.isArray(gate.value && gate.value.rows)) ? 'bad response' : null)
    };
  }));
}

// The EDIT flow for one limit. confirm is useConfirm's; put is
// api.setCoordSetting. Cancel or Escape sends nothing; a refused or odd answer
// is a failure with the worker's text, never "set".
export function makeLimitEdit({ confirm, put, reload, onMsg }) {
  return async ({ kind, key, title, current }) => {
    const form = { value: current === null || current === undefined ? '' : String(current) };
    const ok = await confirm({
      title,
      confirmLabel: 'SAVE',
      confirmBlocked: !parseLimit(kind, form.value).ok,
      body: ({ setBlocked }) => {
        const p = parseLimit(kind, form.value);
        return html`
          <label style="display:flex;flex-direction:column;gap:6px">
            <span>${key}</span>
            <input class="knob__input" style="width:100%" type="text" aria-label=${key} inputmode="decimal" value=${form.value}
              onInput=${(e) => { form.value = e.target.value; setBlocked(!parseLimit(kind, form.value).ok); }}/>
            <span class="footnote" style="color:var(--faint)">${p.ok ? 'saved as a settings row; the lead review lane reads it on its next tick' : p.error}</span>
          </label>`;
      }
    });
    if (!ok) return { sent: false };
    const parsed = parseLimit(kind, form.value);
    if (!parsed.ok) { onMsg({ ok: false, text: parsed.error }); return { sent: false }; }
    const value = String(parsed.value);
    try {
      const res = await put({ key, value, reason: 'console edit' });
      if (!res || !res.setting || String(res.setting.value) !== value) {
        onMsg({ ok: false, text: `${key}: the worker did not echo the saved row` });
        return { sent: true, ok: false };
      }
      onMsg({ ok: true, text: `${key} set to ${value}` });
      reload();
      return { sent: true, ok: true };
    } catch (e) {
      onMsg({ ok: false, text: `${key}: ${e.message}` });
      return { sent: true, ok: false };
    }
  };
}

export function LeadReviewsScreen() {
  const registry = useApi(() => api.lanesRegistry(), []);
  const projects = useApi(() => api.coordProjects(), [], POLL);
  const cap = useApi(() => api.coordSetting(SPEND_KEY), [], POLL);
  const conc = useApi(() => api.coordSetting(CONCURRENCY_KEY), [], POLL);
  const spend = useApi(() => api.llmSpend({ stage: 'lead-review', lane: 'lead-review' }), [], POLL);
  const running = useApi(() => api.jobs({ kind: 'lead_review', status: 'running', limit: RUNNING_LIMIT }), [], POLL);
  const drift = useApi(() => api.prStateEvents({ since: sinceIso(Date.now()), limit: DRIFT_LIMIT }), [], POLL);
  const failedReqs = useApi(() => api.leadReviews({ status: 'failed', limit: FAILED_LIMIT }), [], POLL);
  const repos = autoReposFrom(registry.data);
  const repoKey = repos ? repos.join(' ') : '';
  const repoReads = useApi(() => (repos ? loadRepos(repos) : Promise.resolve(null)), [repoKey], POLL);
  const [dialog, confirm] = useConfirm();
  const [msg, setMsg] = useState(null);
  const edit = makeLimitEdit({
    confirm, put: api.setCoordSetting, onMsg: setMsg,
    reload: () => { cap.reload(); conc.reload(); }
  });

  return html`
    ${dialog}
    <${LeadReviewsView} registry=${registry} repos=${repos} projects=${projects} cap=${cap} conc=${conc}
      spend=${spend} running=${running} drift=${drift} failedReqs=${failedReqs} repoReads=${repoReads}
      msg=${msg} onEdit=${edit}/>`;
}

const errText = (s) => String(s && s.error ? s.error.message || s.error : 'no answer');
const wrapTable = (t) => html`<div style="overflow-x:auto;max-width:100%">${t}</div>`;
const na = html`<span class="na">—</span>`;
const stamp = (iso, nowMs) => (iso ? html`<span class="num" title=${iso}>${whenLabel(iso, nowMs)}</span>` : na);

// A PR cell: the console's PR page for a mapped repo, otherwise GitHub, so no
// row is ever dead.
function prCell(map, repo, n, url) {
  const href = prHref(map, repo, n);
  if (href) return html`<${Link} to=${href} class="cell-name">${repo}#${n}<//>`;
  const gh = url || `https://github.com/${repo}/pull/${n}`;
  return html`<a href=${gh} target="_blank" rel="noopener noreferrer" class="cell-name"
    title="this repo has no console project, so this opens GitHub">${repo}#${n} ↗</a>`;
}
const jobCell = (id) => (id ? html`<${Link} to=${`/jobs/${encodeURIComponent(id)}`} class="num">${id}<//>` : na);
const head12 = (sha) => (sha ? html`<span class="num" title=${sha}>${String(sha).slice(0, 12)}</span>` : na);

function worklistColumns(map, nowMs) {
  return [
    { key: 'position', label: 'POSITION', sort: (r) => r.position, cell: (r) => html`<span class="num">${r.position}</span>` },
    { key: 'pr', label: 'PR', sort: (r) => `${r.repo}#${String(r.number).padStart(8, '0')}`, cell: (r) => prCell(map, r.repo, r.number, r.url) },
    { key: 'head', label: 'HEAD', sort: (r) => r.head || '', cell: (r) => head12(r.head) },
    { key: 'hotfix', label: 'HOTFIX', sort: (r) => (r.hotfix ? 1 : 0), cell: (r) => (r.hotfix ? html`<span class="tag tag--warn">hotfix</span>` : na) },
    { key: 'nudged', label: 'NUDGED', sort: (r) => (r.nudged ? 1 : 0), cell: (r) => (r.nudged ? html`<span class="tag">nudged</span>` : na) },
    { key: 'approved_at', label: 'APPROVED AT', sort: (r) => r.approved_at || '', cell: (r) => stamp(r.approved_at, nowMs) }
  ];
}

function runningColumns(nowMs) {
  return [
    { key: 'id', label: 'JOB', sort: (j) => j.id, cell: (j) => jobCell(j.id) },
    { key: 'project', label: 'PROJECT', sort: (j) => j.project || '',
      cell: (j) => (j.project ? html`<${Link} to=${`/p/${encodeURIComponent(j.project)}`}>${j.project}<//>` : na) },
    { key: 'pr', label: 'PR', sort: (j) => prOfJob(j) ?? -1,
      cell: (j) => {
        const n = prOfJob(j);
        if (n === null) return na;
        return j.project ? html`<${Link} to=${`/pr/${encodeURIComponent(j.project)}/${n}`}>#${n}<//>` : html`<span>#${n}</span>`;
      } },
    { key: 'box', label: 'BOX', sort: (j) => j.box || '', cell: (j) => (j.box ? html`<span>${j.box}</span>` : na) },
    { key: 'age_s', label: 'AGE', sort: (j) => (Number.isFinite(j.age_s) ? j.age_s : -1),
      cell: (j) => html`<span class="num" title=${j.created_at || ''}>${fmtDuration(j.age_s)}</span>` }
  ];
}

function failedColumns(map, nowMs) {
  return [
    { key: 'pr', label: 'PR', sort: (r) => `${r.repo}#${String(r.number).padStart(8, '0')}`, cell: (r) => prCell(map, r.repo, r.number, r.url) },
    { key: 'head', label: 'HEAD', sort: (r) => r.head || '', cell: (r) => head12(r.head) },
    { key: 'detail', label: 'DETAIL', flex: true, sort: (r) => r.detail || '',
      cell: (r) => (r.detail ? html`<span style="overflow-wrap:anywhere">${r.detail}</span>`
        : html`<span class="na">${r.joined ? 'no detail recorded' : 'no failed request row read for this head'}</span>`) },
    { key: 'job_id', label: 'JOB', sort: (r) => r.job_id || '', cell: (r) => jobCell(r.job_id) },
    { key: 'failed_at', label: 'FAILED AT', sort: (r) => r.failed_at || '', cell: (r) => stamp(r.failed_at, nowMs) }
  ];
}

// One tile of the strip. `to` links the value; `onEdit` adds the EDIT button.
function Tile({ label, value, to, onEdit, testid }) {
  return html`
    <div class="stat" data-tile=${testid} style="flex:1 1 180px">
      <span class="stat__label">${label}</span>
      <span class="stat__value stat__value--sm">${to ? html`<${Link} to=${to}>${value}<//>` : value}</span>
      ${onEdit ? html`<button type="button" class="btn btn--sm" style="align-self:flex-start;margin-top:4px" onClick=${onEdit}>EDIT</button>` : null}
    </div>`;
}

function spendText(spend, cap) {
  const spent = spend.error && !spend.data ? 'spend unreadable'
    : spend.data && Number.isFinite(spend.data.usd) ? fmtUsd(spend.data.usd) : spend.loading ? '…' : 'spend unreadable';
  const c = limitState('spend', cap);
  const capText = c.kind === 'ok' ? `cap ${fmtUsd(c.value)}` : c.kind === 'none' ? 'no cap set'
    : c.kind === 'bad' ? `cap ${c.raw} (unreadable)` : c.kind === 'error' ? `cap unreadable (${c.text})` : 'cap …';
  return `${spent} / ${capText}`;
}

function runningText(running, conc) {
  const jobs = running.data && Array.isArray(running.data.jobs) ? running.data.jobs : null;
  const n = jobs ? `${jobs.length >= RUNNING_LIMIT ? '≥' : ''}${jobs.length}` : running.error ? 'running unreadable' : '…';
  const c = limitState('concurrency', conc);
  const cText = c.kind === 'ok' ? `concurrency ${c.value}` : c.kind === 'none' ? 'default (free slots)'
    : c.kind === 'bad' ? `concurrency ${c.raw} (unreadable)` : c.kind === 'error' ? `concurrency unreadable (${c.text})` : 'concurrency …';
  return `${n} / ${cText}`;
}

function driftText(drift) {
  if (drift.error && !drift.data) return `unreadable (${errText(drift)})`;
  if (!drift.data) return '…';
  if (!Array.isArray(drift.data.rows)) return 'unreadable (bad response)';
  const d = driftCount(drift.data.rows, DRIFT_LIMIT);
  return `${d.capped ? '≥' : ''}${d.n}`;
}

export function LeadReviewsView({ registry, repos, projects, cap, conc, spend, running, drift, failedReqs, repoReads, msg, onEdit, nowMs = Date.now() }) {
  const map = projectByRepo(projects && projects.data);
  const capNow = limitState('spend', cap);
  const concNow = limitState('concurrency', conc);
  const projectsNote = projects && projects.error && !projects.data
    ? html`<div class="footnote"><span>project list unreadable (${errText(projects)}), so PR links open GitHub</span></div>` : null;

  // Repos: unknown until the registry answers, an error if it has no knob.
  let reposBlock = null;
  if (registry.loading && !registry.data) reposBlock = html`<${Skeleton} rows=${3}/>`;
  else if (registry.error && !registry.data) reposBlock = html`<${ErrorBox} error=${registry.error} onRetry=${registry.reload}/>`;
  else if (!repos) reposBlock = html`<${ErrorBox} error=${`the lane registry has no ${AUTO_REPOS_ENV} on lead-review-land, so there is no repo to read`}/>`;
  else if (repoReads.loading && !repoReads.data) reposBlock = html`<${Skeleton} rows=${3}/>`;
  else if (repoReads.error && !repoReads.data) reposBlock = html`<${ErrorBox} error=${repoReads.error} onRetry=${repoReads.reload}/>`;

  const per = Array.isArray(repoReads && repoReads.data) ? repoReads.data : [];
  const needsBad = per.filter((r) => r.needs === null);
  const gateBad = per.filter((r) => r.gate === null);
  const partial = (bad, what) => (bad.length ? html`
    <div class="banner"><span>incomplete: could not read ${what} for <b>${bad.map((r) => `${r.repo} (${r.error || 'bad response'})`).join(', ')}</b>; the rows below are the other repos only</span></div>` : null);

  const work = worklistRows(per);
  const workCapped = per.some((r) => Array.isArray(r.needs) && r.needs.length >= WORKLIST_LIMIT);
  const reqs = failedReqs.data && Array.isArray(failedReqs.data.requests) ? failedReqs.data.requests : null;
  const failed = failedRows(per.flatMap((r) => r.gate || []), reqs || []);
  const jobs = running.data && Array.isArray(running.data.jobs) ? running.data.jobs : null;

  const worklistBody = reposBlock || (needsBad.length === per.length
    ? html`<${ErrorBox} error=${needsBad.map((r) => `${r.repo}: ${r.error || 'bad response'}`).join('; ')} onRetry=${repoReads.reload}/>`
    : html`
      ${partial(needsBad, 'the worklist')}
      ${work.length ? wrapTable(html`<${SortableTable} columns=${worklistColumns(map, nowMs)} rows=${work}
          rowKey=${(r) => `${r.repo}#${r.number}`} defaultSort="position"/>`)
        : html`<${Empty} title="none" note="No PR on an auto repo is approved, CI green and waiting for a lead review on its head."/>`}
      ${workCapped ? html`<div class="footnote"><span>a repo returned ${WORKLIST_LIMIT} rows, the page size; more may be waiting</span></div>` : null}`);

  let runningBody;
  if (running.loading && !running.data) runningBody = html`<${Skeleton} rows=${2}/>`;
  else if (!jobs) runningBody = html`<${ErrorBox} error=${running.error || 'bad response'} onRetry=${running.reload}/>`;
  else if (!jobs.length) runningBody = html`<${Empty} title="none" note="No lead_review job is running."/>`;
  else runningBody = html`
    ${wrapTable(html`<${SortableTable} columns=${runningColumns(nowMs)} rows=${jobs} rowKey=${(j) => j.id} defaultSort="age_s" defaultDir="desc"/>`)}
    ${jobs.length >= RUNNING_LIMIT ? html`<div class="footnote"><span>showing ${RUNNING_LIMIT} running jobs, the page size; there may be more</span></div>` : null}`;

  const failedBody = reposBlock || (gateBad.length === per.length
    ? html`<${ErrorBox} error=${gateBad.map((r) => `${r.repo}: ${r.error || 'bad response'}`).join('; ')} onRetry=${repoReads.reload}/>`
    : html`
      ${partial(gateBad, 'gate facts')}
      ${failed.length ? wrapTable(html`<${SortableTable} columns=${failedColumns(map, nowMs)} rows=${failed}
          rowKey=${(r) => `${r.repo}#${r.number}`} defaultSort="pr"/>`)
        : html`<${Empty} title="none" note="No PR on an auto repo has a failed lead review on its current head."/>`}
      ${failed.length && !reqs ? html`<div class="footnote"><span>failed request rows unreadable (${errText(failedReqs)}), so detail and job are missing</span></div>` : null}
      ${failed.length && reqs && failedReqs.data.truncated ? html`<div class="footnote"><span>incomplete: only the oldest ${FAILED_LIMIT} failed request rows were read, so a newer failure may show no detail</span></div>` : null}`);

  return html`
    <div class="page">
      <${PageHeadline} chip="Lead reviews"
        line1=${jobs ? `${jobs.length} ${jobs.length === 1 ? 'lead review' : 'lead reviews'} running.` : 'Reading the lead reviews.'}
        line2=${repoReads.data ? `${failed.length} ${failed.length === 1 ? 'PR has' : 'PRs have'} a failed review on its head.` : ''}/>
      <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
        <${Link} to="/kanban" class="crumb">← KANBAN<//>
      </div>
      ${msg ? html`<div class="banner" role="status"
        style=${msg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}><span>${msg.text}</span></div>` : null}

      <div style="display:flex;flex-wrap:wrap;gap:8px;margin:12px 0">
        <${Tile} testid="spend" label="SPEND TODAY (UTC)" value=${spendText(spend, cap)} to="/costs"
          onEdit=${() => onEdit({ kind: 'spend', key: SPEND_KEY, title: 'EDIT DAILY SPEND CAP', current: capNow.kind === 'ok' ? capNow.value : null })}/>
        <${Tile} testid="running" label="RUNNING" value=${runningText(running, conc)} to="/jobs"
          onEdit=${() => onEdit({ kind: 'concurrency', key: CONCURRENCY_KEY, title: 'EDIT CONCURRENCY', current: concNow.kind === 'ok' ? concNow.value : null })}/>
        <${Tile} testid="drift" label="DRIFT 24H (reconcile repairs)" value=${driftText(drift)}/>
      </div>
      ${projectsNote}

      <${Section} title="WORKLIST" note=${repos ? `needs a lead review, in the lane's order · ${repos.join(', ')} (catalog default)` : ''}>
        ${worklistBody}
      <//>
      <${Section} title="RUNNING" note="lead_review jobs with status running">
        ${runningBody}
      <//>
      <${Section} title="FAILED" note="the review failed on the head the PR has now">
        ${failedBody}
      <//>
      <${BlockCategoriesSection}/>
    </div>`;
}

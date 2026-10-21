import { useState, useCallback } from 'preact/hooks';
import { html, Link } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, fetchArtifact } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { LogPane } from '../ui/LogPane.js';
import { useConfirm } from '../ui/Modal.js';
import { Section, Stat, Skeleton, Empty, ErrorBox } from '../ui/primitives.js';
import { SortableTable } from '../ui/SortableTable.js';
import { agoFromMinutes, safeHttpsUrl, whenLabel } from '../lib/format.js';
import { stageLabel, verdictLabel } from '../lib/stages.js';
import { tierLabel } from '../lib/labels.js';
import { UsdCell } from '../ui/UsdCell.js';
import { TimelineDot, Dot } from '../ui/icons.js';
import { repoFromPrUrl, liveHeadOf, standingShaOf, VerdictsView, requestLeadReview, LeadReviewFailedLine } from '../ui/PRVerdicts.js';
import { liveHeadTier } from '../lib/risk-tiers.js';
import { IronLawHold } from '../ui/IronLawHold.js';

// The artifact tabs a PR carries. `context` and `cost` exist in the action
// vocabulary too but are not part of the review story, so they sit behind MORE.
const PRIMARY_TABS = ['plan', 'review', 'security', 'qa', 'pipeline'];
const EXTRA_TABS = ['context', 'cost'];

// The Merge button's command body (BH-4439). The sha of the standing verdict
// for the live head rides as `verdict_sha`, so the Pages proxy can tell a click
// after a re-review of a moved head from a repeat on the refused one (both
// carry the same live head; only the verdict differs). It's never `sha`:
// bin/poll-commands.sh reads `.sha` as the REVIEWED sha it binds the merge to.
export function mergeCommandFor({ project, build, verdictSha }) {
  const body = { type: 'merge_pr', project, ticket: build.ticket_key, pr_url: build.pr_url };
  if (verdictSha) body.verdict_sha = verdictSha;
  return body;
}

export function PRScreen({ project, number }) {
  const pr = useApi(() => api.pr(project, number), [project, number], { intervalMs: 60000 });
  const [which, setWhich] = useState('review');
  const [showExtra, setShowExtra] = useState(false);
  const [merging, setMerging] = useState(false);
  const [mergeMsg, setMergeMsg] = useState(null);
  const [requesting, setRequesting] = useState(false);
  const [reviewMsg, setReviewMsg] = useState(null);
  const [dialog, confirm] = useConfirm();

  const data = pr.data || {};
  const builds = data.builds || [];
  const ticket = builds.length ? builds[0].ticket_key : null;
  // BH-1952: the verdict history is keyed on the GitHub repo, and the STANDING
  // marker and the request button on the PR's full live head. Neither is
  // guessed: no repo, no table; no 40-hex head, no button and no marker.
  const repo = repoFromPrUrl(data.html_url) || repoFromPrUrl(builds.length ? builds[0].pr_url : null);
  const liveHead = liveHeadOf(data);
  const verdicts = useApi(
    () => (repo ? api.verdicts(repo, number, liveHead) : Promise.resolve(null)),
    [repo, number, liveHead], { intervalMs: 60000 }
  );
  const verdictSha = standingShaOf(verdicts.data, liveHead);
  // BH-4957: did a lead review fail on this head? Only asked with a repo and a
  // full live head; LeadReviewFailedLine says when the answer is unreadable.
  const leadFailed = useApi(
    () => (repo && liveHead
      ? Promise.all([api.prGate(repo), api.leadReviews({ status: 'failed', repo, limit: 100 })])
        .then(([gate, failed]) => ({ gate, failed }))
      : Promise.resolve(null)),
    [repo, liveHead], { intervalMs: 60000 }
  );
  // BH-5022: the risk tier rows of this PR; PRStats picks the live head's.
  const risk = useApi(
    () => (repo ? api.riskTiers({ repo, pr: number }) : Promise.resolve(null)),
    [repo, number], { intervalMs: 60000 }
  );

  const artifactAction = useCallback(
    (kind) => fetchArtifact(project, ticket, kind),
    [project, ticket]
  );

  const doMerge = useCallback(async () => {
    const build = builds[0];
    const ok = await confirm({
      title: 'MERGE THIS PR',
      body: html`Queue a merge of <b>#${number}</b> on <b>${project}</b>?
        The command goes to the box that owns the repo — nothing merges from this browser.
        ${data.checks && data.checks.failure
          ? html`<br/><br/><span style="color:var(--red-lt)">${data.checks.failure} check${data.checks.failure > 1 ? 's are' : ' is'} failing right now.</span>`
          : ''}`,
      confirmLabel: 'QUEUE MERGE'
    });
    if (!ok) return;
    setMerging(true);
    setMergeMsg(null);
    try {
      const res = await api.action(mergeCommandFor({ project, build, verdictSha }));
      setMergeMsg({ ok: true, text: `merge queued as command #${res.command_id}` });
    } catch (e) {
      // The repo whitelist refuses anything outside the four example-org repos —
      // that is the intended answer for e.g. a project-10 PR, not a bug.
      setMergeMsg({ ok: false, text: `merge refused — ${e.message}` });
    } finally {
      setMerging(false);
    }
  }, [builds, confirm, number, project, data.checks, verdictSha]);

  const doRequestReview = useCallback(async () => {
    setRequesting(true);
    setReviewMsg(null);
    try {
      const res = await requestLeadReview({
        confirm, action: api.action, project, repo, pr: Number(number), headSha: liveHead
      });
      if (res && res.text) setReviewMsg(res);
    } finally {
      setRequesting(false);
    }
  }, [confirm, project, repo, number, liveHead]);

  if (pr.loading && !pr.data) return html`<div class="page"><${PageHeadline} chip="Pull request" line1=${`PR #${number}`} line2="Reading the PR."/><${Skeleton} rows=${7} height=${22}/></div>`;
  if (pr.error && !pr.data) {
    return html`<div class="page">
      <${Link} to=${`/p/${encodeURIComponent(project)}`} class="crumb">← ${project}<//>
      <${PageHeadline} chip="Pull request" line1=${`PR #${number}`} line2="The PR read failed."/>
      <${ErrorBox} error=${pr.error} onRetry=${pr.reload}/>
    </div>`;
  }

  const gh = data.gh;
  const checks = data.checks;
  const state = gh ? gh.state : null;
  const mergeable = builds.length && builds[0].pr_url;
  const tabs = showExtra ? [...PRIMARY_TABS, ...EXTRA_TABS] : PRIMARY_TABS;

  return html`
    <div class="page">
      ${dialog}
      <${PageHeadline} chip="Pull request" line1=${`PR #${number}${state ? ` is ${state}.` : '.'}`}
        line2=${gh ? gh.title : (ticket ? `${ticket} · title unavailable` : 'title unavailable')}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to=${`/p/${encodeURIComponent(project)}`} class="crumb">← ${project}<//>
        <span class="crumb-sep">/</span>
        <span style="font-size:var(--fs-lg);color:var(--soft);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:44ch">
          ${gh ? gh.title : (ticket ? `${ticket} · title unavailable` : 'title unavailable')}
        </span>
        ${state ? html`
          <span class=${state === 'merged' ? 'pill' : state === 'open' ? 'pill' : 'pill pill--muted'}>
            <${Dot} color=${state === 'merged' ? 'var(--green-lt)' : state === 'open' ? 'var(--green)' : 'var(--muted)'} size=${7}/>
            ${state.toUpperCase()}${gh.draft ? ' · DRAFT' : ''}
          </span>` : null}
        ${!data.enriched ? html`
          <span class="tag tag--warn" title=${data.gh_error || 'GH_READ_TOKEN not provisioned'}>
            live GitHub data unavailable
          </span>` : null}

        <div style="display:flex;gap:8px;margin-left:auto;flex-wrap:wrap">
          ${safeHttpsUrl(data.html_url)
            ? html`<a class="btn" href=${safeHttpsUrl(data.html_url)} target="_blank" rel="noopener noreferrer">GITHUB ↗</a>`
            : null}
          ${ticket ? html`<${Link} to=${`/p/${encodeURIComponent(project)}`} class="btn">TICKET ${ticket}<//>` : null}
          ${repo && liveHead
            ? html`<button class="btn" disabled=${requesting} onClick=${doRequestReview}>
                ${requesting ? 'REQUESTING…' : 'REQUEST LEAD REVIEW'}</button>`
            : null}
          ${mergeable && state !== 'merged'
            ? html`<button class="btn btn--primary" disabled=${merging} onClick=${doMerge}>
                ${merging ? 'QUEUEING…' : 'MERGE'}</button>`
            : null}
        </div>
      </div>

      ${mergeMsg ? html`
        <div class=${mergeMsg.ok ? 'banner banner--warn' : 'banner'}
          style=${mergeMsg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${mergeMsg.text}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => setMergeMsg(null)}>DISMISS</button>
        </div>` : null}

      ${reviewMsg ? html`
        <div class=${reviewMsg.ok ? 'banner banner--warn' : 'banner'}
          style=${reviewMsg.ok ? 'border-color:var(--line-active);background:var(--panel-active);color:var(--green-lt)' : ''}>
          <span>${reviewMsg.ok ? reviewMsg.text : `lead review request refused — ${reviewMsg.text}`}</span>
          <button class="btn btn--sm" style="margin-left:auto" onClick=${() => setReviewMsg(null)}>DISMISS</button>
        </div>` : null}

      ${!data.enriched ? html`
        <div class="banner banner--warn">
          <span>
            ${data.has_repo === false
              ? html`This project has <b>no GitHub repo configured</b>, so there is no GitHub side to fetch.`
              : data.gh_error
                ? html`Live GitHub data unavailable — <b>${data.gh_error}</b>.`
                : html`Live GitHub data unavailable (<b>GH_READ_TOKEN not set</b>).`}
            Title, checks, diff size and the file list come from GitHub and are blank above;
            everything sourced from D1 (builds, verdict, tier, stage, artifacts) is below and is complete.
          </span>
        </div>` : null}

      <${PRStats} builds=${builds} data=${data} gh=${gh} checks=${checks} risk=${repo ? risk : null} liveHead=${liveHead}/>

      ${data.cost && !data.cost.available ? html`
        <div class="footnote"><span>build cost — ${data.cost.reason}</span>
          <${Link} to="/costs" style="margin-left:auto">what IS priced ›<//></div>` : null}

      ${checks && checks.failing && checks.failing.length ? html`
        <div class="banner">
          <span><b>${checks.failure} failing check${checks.failure > 1 ? 's' : ''}:</b>
            ${checks.failing.map((f) => {
              const href = safeHttpsUrl(f.url);
              return href
                ? html`<a href=${href} target="_blank" rel="noopener noreferrer" style="margin-right:10px">${f.name}<//>`
                : html`<span style="margin-right:10px;color:var(--red-lt)" title="check URL was not https — not linked">${f.name}</span>`;
            })}</span>
        </div>` : null}

      <div class="split split--wide">
        <div class="split__col">
          <${Section} title="ARTIFACTS"
            note=${ticket ? `fetched from the ${project} box for ${ticket}` : 'no ticket key on any build row — artifacts are not addressable'}
            right=${html`<button class="btn btn--sm" onClick=${() => setShowExtra(!showExtra)}>
              ${showExtra ? 'FEWER' : 'MORE'}</button>`}>
            ${ticket
              ? html`<${LogPane}
                  kinds=${tabs.map((k) => ({ key: k, label: k.toUpperCase() }))}
                  activeKind=${which}
                  onKind=${setWhich}
                  action=${artifactAction}
                  terminalClass="term term--artifact"
                  autoFetch=${false}
                  emptyHint="Each tab pulls that file from the owning box's build dir. Pick one and press FETCH FRESH." />`
              : html`<${Empty} title="not addressable"
                  note="fetch_artifact needs the ticket key, and no build row pointing at this PR carries one." />`}
          <//>

          ${data.body ? html`
            <${Section} title="PR BODY">
              <pre class="term term--artifact">${data.body}</pre>
            <//>` : null}

          <${Section} title="FILES"
            note=${data.files_error
              ? `file list unavailable — ${data.files_error}`
              : data.files_capped ? 'capped at 50 — the PR touched at least that many' : ''}>
            ${data.files && data.files.length
              ? html`<${SortableTable}
                  columns=${[
                    { key: 'filename', label: 'FILE', sort: (f) => f.filename,
                      cell: (f) => html`<span class="cell-wrap" title=${f.filename}>${f.filename}</span>` },
                    { key: 'status', label: 'STATUS', sort: (f) => f.status,
                      cell: (f) => html`<span class="tag">${f.status}</span>` },
                    { key: 'additions', label: '+', sort: (f) => f.additions, align: 'right',
                      cell: (f) => html`<span style="color:var(--green)">+${f.additions}</span>` },
                    { key: 'deletions', label: '−', sort: (f) => f.deletions, align: 'right',
                      cell: (f) => html`<span style="color:var(--red-lt)">−${f.deletions}</span>` },
                    { key: 'changes', label: 'CHANGES', sort: (f) => f.changes, align: 'right',
                      cell: (f) => html`<span class="num">${f.changes ?? (f.additions + f.deletions)}</span>` }
                  ]}
                  rows=${data.files}
                  rowKey=${(f) => f.filename}
                  defaultSort="changes" defaultDir="desc" />`
              : html`<${Empty} title="no file list"
                  note=${data.files_error
                    ? `GitHub did not return the file list (${data.files_error}).`
                    : 'The file list comes from GitHub and is unavailable without GH_READ_TOKEN.'} />`}
          <//>
        </div>

        <div class="split__col">
          <${Section} title="VERDICTS"
            note=${repo
              ? (liveHead ? `head-bound review verdicts for ${repo}#${number}` : `${repo}#${number} · no full live head sha, so no STANDING marker`)
              : ''}>
            ${repo && liveHead ? html`<${LeadReviewFailedLine} number=${number} liveHead=${liveHead} state=${leadFailed}/>` : null}
            ${repo
              ? html`<${VerdictsView} repo=${repo} liveHead=${liveHead} state=${verdicts}/>`
              : html`<${Empty} title="no GitHub repo for this PR"
                  note="Neither the PR payload nor a build row carries a github.com PR url, so there is no repo to read verdicts for." />`}
          <//>

          ${repo ? html`<${IronLawHold} repo=${repo} number=${number} liveHead=${liveHead}/>` : null}

          <${Section} title="BUILD ROWS"
            note=${`${builds.length} build row${builds.length === 1 ? '' : 's'} point${builds.length === 1 ? 's' : ''} at this PR`}>
            ${builds.length
              ? html`<${SortableTable}
                  columns=${[
                    { key: 'bkey', label: 'BUILD', sort: (b) => b.bkey,
                      cell: (b) => html`<${Link} to=${`/builds/${b.id}`} class="cell-name">${b.bkey}<//>` },
                    { key: 'stage', label: 'STAGE', sort: (b) => b.stage,
                      cell: (b) => html`<span class="tag" title=${b.stage}>${stageLabel(b.stage) || '—'}</span>` },
                    { key: 'tier', label: 'TIER', sort: (b) => (b.tier === null || b.tier === undefined ? null : Number(b.tier)), align: 'right',
                      cell: (b) => b.tier ? html`<span>${tierLabel(b.tier)}</span>` : html`<span class="na">—</span>` },
                    { key: 'verdict', label: 'VERDICT', sort: (b) => b.verdict,
                      cell: (b) => b.verdict
                        ? html`<span class=${b.verdict === 'APPROVE' ? 'tag tag--green' : 'tag tag--warn'} title=${b.verdict}>${verdictLabel(b.verdict)}</span>`
                        : html`<span class="na">—</span>` },
                    { key: 'age_min', label: 'AGE', sort: (b) => b.age_min, align: 'right',
                      cell: (b) => html`<span>${agoFromMinutes(b.age_min)}</span>` }
                  ]}
                  rows=${builds}
                  rowKey=${(b) => b.id}
                  defaultSort="age_min" defaultDir="asc" />`
              : html`<${Empty} title="no build row"
                  note="No row in D1 points at this PR number for this project." />`}
          <//>

          <${Section} title="TIMELINE">
            <${PRTimeline} gh=${gh} builds=${builds}/>
          <//>
        </div>
      </div>
    </div>`;
}

// The PR's headline facts (BH-3569): verdict and tier in words, and BUILD COST
// with its basis. Exported so a test renders it. BH-5022: RISK TIER is the
// live head's tier and reasons; a failed read says so, never "not classified".
export function PRStats({ builds, data, gh, checks, risk, liveHead }) {
  const top = builds.length ? builds[0] : null;
  return html`
      <div class="stats stats--6">
        <${Stat} label="VERDICT"
          value=${top && top.verdict ? verdictLabel(top.verdict) : '—'}
          tone=${top && top.verdict === 'APPROVE' ? 'green' : 'sm'}/>
        <${Stat} label="TIER" value=${top && top.tier ? tierLabel(top.tier) : '—'} tone="sm"/>
        <${Stat} label="CHECKS"
          value=${checks ? `${checks.success}/${checks.total}` : '—'}
          tone=${checks && checks.failure ? 'amber' : checks ? 'green' : 'sm'}/>
        <${Stat} label="DIFF"
          value=${gh ? html`<span style="color:var(--green)">+${gh.additions}</span> <span style="color:var(--red-lt)">−${gh.deletions}</span>` : '—'}
          tone="sm"/>
        <${Stat} label="FILES"
          value=${gh ? gh.changed_files : (data.files ? data.files.length : '—')}
          unit=${data.files_capped ? '+' : null}/>
        <${Stat} label="BUILD COST"
          value=${data.cost && data.cost.available ? buildCost(data.cost.total) : 'n/a'} tone="sm"/>
        <div class="stat" style="grid-column:1 / -1">
          <span class="stat__label">RISK TIER</span>
          <span class="stat__value stat__value--sm" style="overflow-wrap:anywhere">${riskFact(risk, liveHead)}</span>
        </div>
      </div>`;
}

function riskFact(risk, liveHead) {
  if (!risk || (!risk.data && !risk.error)) return '—';
  if (risk.error) {
    return html`<span class="tag tag--warn" title=${String(risk.error.message || risk.error)}>unreadable</span>
      <span style="color:var(--faint)"> ${String(risk.error.message || risk.error)}</span>`;
  }
  const row = liveHeadTier(risk.data.rows, liveHead);
  if (!row) return html`<span class="na">not classified</span>`;
  return html`<span class=${row.tier === 'high' ? 'tag tag--warn' : row.tier === 'low' ? 'tag tag--green' : 'tag'} title=${row.tier}>${String(row.tier).toUpperCase()}</span>
    <span> ${row.reasons || ''}</span>`;
}

// The PR payload is not produced in this repo, so its cost total is taken as
// whatever arrives: a number gets UsdCell; a preformatted "$" string is labelled
// as it stands rather than re-parsed. Build cost rows are API-equivalent.
function buildCost(total) {
  if (total === null || total === undefined || total === '') return '—';
  if (Number.isFinite(Number(total))) return html`<${UsdCell} value=${Number(total)} basis="api"/>`;
  if (String(total).includes('$')) {
    return html`<span class="num" data-usd-basis="api">${total} <${Link} to="/costs" class="usd-basis">API-eq<//></span>`;
  }
  return total;
}

function PRTimeline({ gh, builds, nowMs = Date.now() }) {
  const events = [];
  if (gh) {
    if (gh.created_at) events.push({ ts: gh.created_at, text: `PR opened by ${gh.author || 'unknown'} on ${gh.head_ref} → ${gh.base_ref}` });
    if (gh.updated_at) events.push({ ts: gh.updated_at, text: 'last updated on GitHub' });
    if (gh.merged_at) events.push({ ts: gh.merged_at, text: 'merged' });
    else if (gh.closed_at) events.push({ ts: gh.closed_at, text: 'closed without merging' });
  }
  for (const b of builds) {
    if (b.updated_at) events.push({ ts: b.updated_at, text: `${b.bkey} → ${stageLabel(b.stage)}${b.verdict ? ` (${verdictLabel(b.verdict)})` : ''}` });
  }
  events.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts));

  if (!events.length) {
    return html`<${Empty} title="no timeline"
      note="Timestamps come from GitHub and from the build rows; neither is available here." />`;
  }

  return html`
    <div class="panel panel__pad">
      ${events.map((e, i) => html`
        <div key=${i} class="timeline__row">
          <div class="timeline__rail">
            <${TimelineDot} open=${i === events.length - 1} color=${i === events.length - 1 ? 'var(--amber)' : 'var(--green)'}/>
            ${i < events.length - 1 ? html`<span class="timeline__line"></span>` : null}
          </div>
          <span class="timeline__text">
            <span class="timeline__ts" title=${e.ts}>${whenLabel(e.ts, nowMs)}</span> · ${e.text}
          </span>
        </div>`)}
    </div>`;
}

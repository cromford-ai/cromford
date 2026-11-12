import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { TicketKey } from '../ui/TicketKey.js';

import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Cursor, Legend } from '../ui/primitives.js';
import { Clock } from '../ui/icons.js';
import { minutesSince, clockTime, safeHttpsUrl, prNumberFromUrl, whenLabel, countOrNull, fmtNum } from '../lib/format.js';
import {
  needRows, summariseNeeds, needSeverityRank, NEED_LABEL, NEED_KINDS, facet, staleBuilds, JOBS_READ_CAP
} from '../lib/cockpit.js';

// A build row's title starts with its key; the key renders as its own link.
const titleAfterKey = (r) => r.title.slice(String(r.ticket).length).trimStart();

// NEEDS is the port of the old console's /needs: the one list of everything
// waiting on a person. Four sources, deliberately in one table rather than four
// panes — the question an operator arrives with is "what do I have to do", not
// "how many alerts are there", and four panes make the smallest pile look like
// the whole job.
//
// It is read-only, like everything on this proxy: each row's action is a LINK to
// the screen that already owns that decision (resolve on ALERTS, merge on the
// PR, approve on the idea). Nothing here mints a command.

const REFRESH_MS = 60000;

const SEV_CLASS = { high: 'tag tag--dead', medium: 'tag tag--warn', low: 'tag tag--idle' };
const SEV_LABEL = { high: 'BLOCKING', medium: 'WAITING', low: 'DECIDE' };
const QUEUE_LEGEND = [
  { term: 'blocking', text: 'stopped. Nothing moves until someone decides.' },
  { term: 'waiting', text: 'a PR or a retry waiting on a click.' },
  { term: 'decide', text: 'an idea at the gate. Nothing is broken while it waits.' },
  { term: 'stale build', text: 'a build row with no running job for 10 minutes. Open it to see where it stopped.' }
];

export function NeedsScreen() {
  const project = useSearchParam('project');
  const kindFilter = useSearchParam('kind');
  // The project filter is applied at the API so the counts strip describes the
  // same slice the table does; the kind filter is client-side because every
  // kind is already in hand.
  const needs = useApi(() => api.cockpitNeeds(project), [project], { intervalMs: REFRESH_MS });
  // The jobs ledger decides which unfinished build rows are stale.
  const jobs = useApi(() => api.jobs({ status: 'running', limit: JOBS_READ_CAP }), [], { intervalMs: REFRESH_MS });

  const setParam = (key, value) => {
    const next = { project, kind: kindFilter, [key]: value };
    const q = new URLSearchParams();
    for (const k of ['project', 'kind']) if (next[k]) q.set(k, next[k]);
    const qs = q.toString();
    navigate(`/needs${qs ? `?${qs}` : ''}`);
  };

  return html`<${NeedsView} needs=${needs} jobs=${jobs} project=${project} kindFilter=${kindFilter}
    nowMs=${Date.now()} setParam=${setParam}/>`;
}

export function NeedsView({ needs, jobs, project, kindFilter, nowMs = Date.now(), setParam }) {
  const payload = needs.data || null;
  // Nothing is stale without a jobs answer (lib/cockpit.js staleBuilds).
  const stale = payload ? staleBuilds(payload.unfinished_builds || [], jobs.data, nowMs) : [];
  const all = needRows(payload, stale);
  const rows = all.filter((r) => !kindFilter || r.kind === kindFilter);
  const s = summariseNeeds(payload, stale);
  // Two numbers exist and they are not the same thing: `counts` is the whole
  // filtered set straight out of D1, `s` is what actually arrived (each list is
  // capped at 200). The strip reports the authoritative one; the table says how
  // much of it is on screen.
  const counts = (payload && payload.counts) || {};
  const capped = Object.entries((payload && payload.truncated) || {})
    .filter(([, v]) => v).map(([k]) => k.replace(/_/g, ' '));
  // The server counts cannot know which rows are stale, so the screen adds them.
  const total = payload ? (counts.total ?? s.total - stale.length) + stale.length : null;

  const chip = (label, active, onClick) => html`
    <button type="button" class=${active ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;

  const columns = [
    {
      key: 'severity', label: 'WHY', sort: (r) => needSeverityRank(r),
      cell: (r) => html`<span class=${SEV_CLASS[r.severity] || 'tag'}>${SEV_LABEL[r.severity] || r.severity}</span>`
    },
    {
      key: 'kind', label: 'KIND', sort: (r) => r.kind,
      // NEED_LABEL is already words; the kind key never shows.
      cell: (r) => html`<${Link} to=${`/needs${paramsFor(project, r.kind)}`} class="cell-name">${NEED_LABEL[r.kind] || r.kind}<//>`
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => (r.project
        ? html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`}>${r.project}<//>`
        : html`<span style="color:var(--faint)" title="beaten without a project — a fleet-level item">fleet</span>`)
    },
    {
      key: 'title', label: 'WHAT', sort: null,
      // BH-4991: a build row's key opens the ticket page; the rest of the line
      // still opens the build.
      cell: (r) => (r.ticket && r.title.startsWith(r.ticket)
        ? html`<span class="cell-wrap" style="max-width:60ch"><${TicketKey} k=${r.ticket}/>${' '}<${Link} to=${r.to} title=${r.title}>${titleAfterKey(r)}<//></span>`
        : html`<${Link} to=${r.to} class="cell-wrap" style="max-width:60ch" title=${r.title}>${r.title}<//>`)
    },
    {
      key: 'detail', label: 'DETAIL', sort: (r) => r.detail,
      cell: (r) => (r.detail
        ? html`<span class="cell-wrap" style="max-width:26ch" title=${r.detail}>${r.detail}</span>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'ts', label: 'WAITING', sort: (r) => minutesSince(r.ts), align: 'right',
      // A day of waiting is the point where something that should have been
      // swept clearly was not.
      cell: (r) => html`<span title=${r.ts || ''}
        class=${minutesSince(r.ts) !== null && minutesSince(r.ts) >= 1440 ? 'num--warn' : ''}>${whenLabel(r.ts, nowMs)}</span>`
    },
    {
      key: 'action', label: '', sort: null, align: 'right',
      cell: (r) => {
        const pr = r.prUrl ? safeHttpsUrl(r.prUrl) : null;
        const prNum = prNumberFromUrl(r.prUrl);
        return html`
          <span style="display:inline-flex;gap:8px;white-space:nowrap;justify-content:flex-end">
            ${pr && prNum && r.project
              ? html`<${Link} to=${`/pr/${encodeURIComponent(r.project)}/${prNum}`}>PR #${prNum}<//>` : null}
            <${Link} to=${r.to}>${r.action || 'OPEN'}<//>
          </span>`;
      }
    }
  ];

  return html`
    <div class="page">
      <${PageHeadline} chip="Needs a human"
        line1=${total === null ? (needs.error ? 'The needs read failed.' : 'Reading what waits on a person.') : `${fmtNum(total)} ${total === 1 ? 'thing needs' : 'things need'} a person.`}
        line2=${total === null ? '' : `${fmtNum(stale.length)} stale ${stale.length === 1 ? 'build' : 'builds'} among them.`}/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <span style="font-size:var(--fs-sm);color:var(--faint)">
          everything the harness stopped on and cannot finish by itself. Read-only here —
          each row links to the screen that owns the decision.
        </span>
      </div>

      <div class="stats stats--6">
        <${Stat} label="TOTAL" value=${payload ? total : '…'}
          tone=${total ? 'warn' : null}/>
        <${Stat} label="BLOCKING" value=${payload ? s.high : '…'} tone=${s.high ? 'warn' : null}/>
        <${Stat} label="OPEN ALERTS" value=${payload ? (counts.alerts ?? 0) : '…'} to="/alerts"/>
        <${Stat} label="DEAD COMMANDS" value=${payload ? (counts.commands ?? 0) : '…'}/>
        <${Stat} label="PARKED BUILDS" value=${payload ? (counts.builds ?? 0) : '…'}/>
        <${Stat} label="STALE BUILDS" value=${!payload ? '…' : jobs.data ? stale.length : countOrNull(null)}
          tone=${stale.length ? 'warn' : null} to="/needs?kind=stale"/>
        <${Stat} label="IDEAS AT THE GATE" value=${payload ? (counts.proposals ?? 0) : '…'} to="/ideas?status=gate_pending"/>
      </div>

      ${needs.error && !payload ? html`<${ErrorBox} error=${needs.error} onRetry=${needs.reload}/>` : null}

      ${capped.length ? html`
        <div class="banner banner--warn">
          <span>The ${capped.join(' and ')} read${capped.length > 1 ? 's' : ''} hit the 200-row cap, so the table
            below is the newest slice, not everything. The strip above is the real count.</span>
        </div>` : null}

      <${Section} title="FILTERS" note="filters live in the URL, so a filtered view is a link you can send">
        <div class="tabs" style="margin-bottom:8px">
          ${chip('WHOLE FLEET', !project, () => setParam('project', null))}
          ${facet(all, 'project').map((p) => chip(p, project === p, () => setParam('project', p)))}
        </div>
        <div class="tabs">
          ${chip('EVERYTHING', !kindFilter, () => setParam('kind', null))}
          ${NEED_KINDS.filter((k) => s.byKind[k]).map((k) =>
            chip(`${NEED_LABEL[k]} (${s.byKind[k]})`, kindFilter === k, () => setParam('kind', k)))}
        </div>
      <//>

      <${Section} title="THE QUEUE"
        note=${payload ? `${fmtNum(rows.length)} of ${fmtNum(total)} in view` : 'loading'}>
        ${needs.loading && !payload
          ? html`<${Skeleton} rows=${8} height=${20}/>`
          : html`<${SortableTable} columns=${columns} rows=${rows} rowKey=${(r) => r.id}
              rowClass=${(r) => (r.severity === 'high' ? 'row--dead' : r.severity === 'medium' ? 'row--warn' : '')}
              defaultSort="severity" defaultDir="asc"
              empty=${html`<${Empty} title="NOTHING NEEDS YOU"
                note=${project || kindFilter
                  ? 'Nothing matches this filter. Widen it before believing the whole fleet is clear.'
                  : 'No open alert, no dead-lettered command, no parked or stale build and no idea at the gate. The harness is unblocked.'} />`} />`}
        <${Legend} items=${QUEUE_LEGEND}/>
      <//>

      <div class="footnote">
        <${Clock}/>
        <span>open alerts · dead-lettered and failed commands · builds stopped at a plan or sitting on an unmerged PR · proposals at the gate${
          payload && payload.generated_at ? ` · read at ${clockTime(payload.generated_at)}` : ''}</span>
        <span class="footnote__spacer"></span>
        <${Cursor}/>
      </div>
    </div>`;
}

const paramsFor = (project, kind) => {
  const q = new URLSearchParams();
  if (project) q.set('project', project);
  if (kind) q.set('kind', kind);
  const qs = q.toString();
  return qs ? `?${qs}` : '';
};

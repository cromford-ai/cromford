import { useState, useEffect, useCallback } from 'preact/hooks';
import { html, Link, useSearchParam, navigate } from '../router.js';
import { PageHeadline } from '../ui/line.js';
import { api, AuthError } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { SortableTable } from '../ui/SortableTable.js';
import { Section, Stat, Skeleton, Empty, ErrorBox, Age, Cursor } from '../ui/primitives.js';
import { Clock } from '../ui/icons.js';
import { minutesSince, fmtDuration, prNumberFromUrl, whenLabel, fmtNum } from '../lib/format.js';
import { stageProgress, stageLabel, verdictLabel } from '../lib/stages.js';
import { plainLabel, tierLabel } from '../lib/labels.js';
import {
  runOutcome, outcomeRank, OUTCOME_LABEL, OUTCOME_TONE, runDurationSeconds, tickWork, facet
} from '../lib/cockpit.js';

// HISTORY is the port of the old console's /history: every run the fleet has
// ever beaten, not the twenty the project page shows. 8,700 rows and growing by
// ~250 a day, so it pages on a CURSOR (the run id), never an offset — and the
// sort headers sort the rows that are loaded, which the footnote says out loud
// rather than implying the whole ledger reordered.

const PAGE = 100;
const TONE_CLASS = { green: 'tag tag--green', dead: 'tag tag--dead', warn: 'tag tag--warn', muted: 'tag tag--idle' };

export function HistoryScreen() {
  // Filters ride the URL, so "every failed project-4 tick" is a link somebody can send.
  const project = useSearchParam('project');
  const kind = useSearchParam('kind');
  const outcome = useSearchParam('outcome');
  const tab = useSearchParam('tab') === 'builds' ? 'builds' : 'runs';

  const setParam = (key, value) => {
    const next = { project, kind, outcome, tab: tab === 'builds' ? 'builds' : null, [key]: value };
    const q = new URLSearchParams();
    for (const k of ['tab', 'project', 'kind', 'outcome']) if (next[k]) q.set(k, next[k]);
    const qs = q.toString();
    navigate(`/history${qs ? `?${qs}` : ''}`);
  };

  const chip = (label, active, onClick) => html`
    <button type="button" class=${active ? 'tab tab--on' : 'tab'} onClick=${onClick}>${label}</button>`;

  return html`
    <div class="page">
      <${PageHeadline} chip="History" line1="Every run and every build."
        line2="What the fleet beat to the console, oldest kept."/>
      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
        <${Link} to="/now" class="crumb">← NOW<//>
        <span class="crumb-sep">/</span>
        <span style="font-size:var(--fs-sm);color:var(--faint)">
          every run and every build the fleet has beaten to the console, oldest kept.
        </span>
      </div>

      <div class="tabs">
        ${chip('RUNS', tab === 'runs', () => setParam('tab', null))}
        ${chip('BUILDS', tab === 'builds', () => setParam('tab', 'builds'))}
        ${chip('COMMANDS', false, () => navigate('/history/commands'))}
      </div>

      ${tab === 'runs'
        ? html`<${RunHistory} project=${project} kind=${kind} outcome=${outcome} setParam=${setParam} chip=${chip}/>`
        : html`<${BuildHistory} project=${project} setParam=${setParam} chip=${chip}/>`}
    </div>`;
}

// One pager for both tabs: it holds the accumulated rows and the cursor, and it
// resets BOTH whenever the filter changes — keeping page 1 of the old filter
// under page 2 of the new one is how a list starts lying about what it is.
function usePager(fetchPage, key) {
  const [state, setState] = useState({ rows: [], cursor: null, total: null, extra: {}, done: false });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = useCallback(async (before, replace) => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetchPage(before);
      setState((s) => ({
        rows: replace ? res.rows : [...s.rows, ...res.rows],
        cursor: res.next_cursor,
        total: res.total,
        extra: res.extra || {},
        done: !res.next_cursor
      }));
    } catch (e) {
      if (e instanceof AuthError) window.dispatchEvent(new CustomEvent('dash:unauthorized'));
      setError(e);
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line
  }, [key]);

  useEffect(() => {
    setState({ rows: [], cursor: null, total: null, extra: {}, done: false });
    load(null, true);
    // eslint-disable-next-line
  }, [key]);

  return { ...state, loading, error, more: () => load(state.cursor, false), reload: () => load(null, true) };
}

// The columns take the clock so a render against a fixture reads the same stamps
// every time; the screens pass nothing and get Date.now().
export function runColumns(nowMs = Date.now()) {
  return [
    {
      key: 'started_at', label: 'STARTED', sort: (r) => r.started_at,
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`} title=${r.started_at || ''}>${whenLabel(r.started_at, nowMs)}<//>`
    },
    {
      key: 'project', label: 'PROJECT', sort: (r) => r.project,
      cell: (r) => html`<${Link} to=${`/p/${encodeURIComponent(r.project)}`} class="cell-name">${r.project}<//>`
    },
    { key: 'kind', label: 'KIND', sort: (r) => r.kind, cell: (r) => html`<span class="tag tag--idle" title=${r.kind || ''}>${plainLabel(r.kind) || '—'}</span>` },
    {
      key: 'outcome', label: 'OUTCOME', sort: (r) => outcomeRank(r),
      cell: (r) => {
        const o = runOutcome(r);
        return html`<span class=${TONE_CLASS[OUTCOME_TONE[o]]} title=${`rc=${r.rc ?? '—'}`}>${OUTCOME_LABEL[o]}</span>`;
      }
    },
    {
      key: 'duration', label: 'TOOK', sort: (r) => runDurationSeconds(r), align: 'right',
      cell: (r) => html`<span class="num">${fmtDuration(runDurationSeconds(r))}</span>`
    },
    {
      key: 'built', label: 'BUILT', sort: (r) => tickWork(r.summary).built, align: 'right',
      cell: (r) => {
        const n = tickWork(r.summary).built;
        return n === null ? html`<span class="na">—</span>` : html`<span class=${n ? 'num--ok' : 'num'}>${n}</span>`;
      }
    },
    {
      key: 'summary', label: 'SUMMARY', sort: null,
      cell: (r) => html`<${Link} to=${`/runs/${r.id}`} class="cell-wrap" title=${r.summary || ''}>
        ${r.summary || 'no summary'}<//>`
    },
    {
      key: 'age', label: 'AGE', sort: (r) => minutesSince(r.finished_at || r.started_at), align: 'right',
      cell: (r) => html`<${Age} min=${minutesSince(r.finished_at || r.started_at)} warnAt=${1440}/>`
    }
  ];
}

function RunHistory({ project, kind, outcome, setParam, chip }) {
  const key = `runs|${project || ''}|${kind || ''}|${outcome || ''}`;
  const pager = usePager(async (before) => {
    const res = await api.cockpitHistory({ project, kind, outcome, before, limit: PAGE });
    return { rows: res.runs || [], next_cursor: res.next_cursor, total: res.total, extra: { failed: res.failed } };
  }, key);

  // The facets come from the rows in hand, so a project that has not appeared in
  // the loaded pages has no chip. The fleet registry is on the FLEET screen.
  const projects = facet(pager.rows, 'project');
  const kinds = facet(pager.rows, 'kind');

  const columns = runColumns();

  return html`
    <div style="display:flex;flex-direction:column;gap:14px">
      <div class="stats">
        <${Stat} label="RUNS IN FILTER" value=${pager.total === null ? '…' : pager.total}/>
        <${Stat} label="OF THOSE, BAD" value=${pager.extra.failed === undefined ? '…' : pager.extra.failed}
          tone=${pager.extra.failed ? 'warn' : null}/>
        <${Stat} label="LOADED HERE" value=${pager.rows.length} tone="sm"/>
      </div>

      <${Section} title="FILTERS" note="filters live in the URL, so a filtered view is a link you can send">
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ALL PROJECTS', !project, () => setParam('project', null))}
          ${projects.map((p) => chip(p, project === p, () => setParam('project', p)))}
        </div>
        <div class="tabs" style="margin-bottom:8px">
          ${chip('ANY KIND', !kind, () => setParam('kind', null))}
          ${kinds.map((k) => chip(k.toUpperCase(), kind === k, () => setParam('kind', k)))}
        </div>
        <div class="tabs">
          ${chip('ANY OUTCOME', !outcome, () => setParam('outcome', null))}
          ${chip('CLEAN', outcome === 'ok', () => setParam('outcome', 'ok'))}
          ${chip('NON-ZERO EXIT', outcome === 'failed', () => setParam('outcome', 'failed'))}
        </div>
      <//>

      <${Section} title="RUNS"
        note=${pager.total === null ? 'loading' : `${fmtNum(pager.rows.length)} of ${fmtNum(pager.total)} loaded · newest first`}>
        ${pager.error && !pager.rows.length
          ? html`<${ErrorBox} error=${pager.error} onRetry=${pager.reload}/>`
          : pager.loading && !pager.rows.length
            ? html`<${Skeleton} rows=${8} height=${20}/>`
            : html`<${SortableTable} columns=${columns} rows=${pager.rows} rowKey=${(r) => r.id}
                rowClass=${(r) => (runOutcome(r) === 'failed' ? 'row--dead' : runOutcome(r) === 'killed' ? 'row--warn' : '')}
                defaultSort="started_at" defaultDir="desc"
                empty=${html`<${Empty} title="NO RUNS IN FILTER"
                  note="Nothing matches. A narrow filter can be legitimately empty — the ledger keeps every run since 2026-07-22." />`} />`}
        <${More} pager=${pager} noun="runs"/>
      <//>
    </div>`;
}

export function buildColumns(nowMs = Date.now()) {
  return [
    {
      key: 'ticket_key', label: 'TICKET', sort: (b) => b.ticket_key || b.bkey,
      cell: (b) => {
        const n = prNumberFromUrl(b.pr_url);
        return html`<${Link} to=${n ? `/pr/${encodeURIComponent(b.project)}/${n}` : `/builds/${b.id}`}
          class="cell-name">${b.ticket_key || b.bkey}<//>`;
      }
    },
    {
      key: 'project', label: 'PROJECT', sort: (b) => b.project,
      cell: (b) => html`<${Link} to=${`/p/${encodeURIComponent(b.project)}`}>${b.project}<//>`
    },
    {
      key: 'stage', label: 'STAGE', sort: (b) => b.stage,
      cell: (b) => {
        const prog = stageProgress(b.stage, b.merged);
        return html`<span style=${prog.dead ? 'color:var(--red-txt)' : 'color:var(--soft)'} title=${b.stage || ''}>
          ${prog.dead ? `stopped at ${stageLabel(b.stage)}` : stageLabel(b.stage) || '—'}</span>`;
      }
    },
    {
      key: 'tier', label: 'TIER', align: 'right',
      sort: (b) => (b.tier === null || b.tier === undefined || b.tier === '' ? null : Number(b.tier)),
      cell: (b) => html`<span title=${b.tier ? `tier ${b.tier}` : ''}>${tierLabel(b.tier)}</span>`
    },
    {
      key: 'verdict', label: 'VERDICT', sort: (b) => b.verdict,
      cell: (b) => (b.verdict
        ? html`<span class=${b.verdict === 'APPROVE' ? 'tag tag--green' : b.verdict === 'BLOCK' ? 'tag tag--dead' : 'tag tag--warn'}
            title=${b.verdict}>${verdictLabel(b.verdict)}</span>`
        : html`<span class="na">—</span>`)
    },
    {
      key: 'merged', label: 'MERGED', sort: (b) => Number(b.merged || 0),
      cell: (b) => (Number(b.merged)
        ? html`<span class="tag tag--solid">MERGED</span>`
        : html`<span class="tag tag--idle">NO</span>`)
    },
    {
      key: 'updated_at', label: 'AGE', sort: (b) => minutesSince(b.updated_at), align: 'right',
      cell: (b) => html`<span title=${b.updated_at || ''}><${Age} min=${minutesSince(b.updated_at)} warnAt=${1440}/></span>`
    },
    {
      key: 'open', label: '', sort: null, align: 'right',
      cell: (b) => html`<${Link} to=${`/builds/${b.id}`}>build #${b.id}<//>`
    }
  ];
}

function BuildHistory({ project, setParam, chip }) {
  const key = `builds|${project || ''}`;
  const pager = usePager(async (before) => {
    const res = await api.cockpitBuildHistory({ project, before, limit: PAGE });
    return { rows: res.builds || [], next_cursor: res.next_cursor, total: res.total, extra: { merged: res.merged } };
  }, key);

  const projects = facet(pager.rows, 'project');

  const columns = buildColumns();

  return html`
    <div style="display:flex;flex-direction:column;gap:14px">
      <div class="stats">
        <${Stat} label="BUILDS IN FILTER" value=${pager.total === null ? '…' : pager.total}/>
        <${Stat} label="OF THOSE, MERGED" value=${pager.extra.merged === undefined ? '…' : pager.extra.merged} tone="green"/>
        <${Stat} label="LOADED HERE" value=${pager.rows.length} tone="sm"/>
      </div>

      <${Section} title="FILTERS" note="filters live in the URL, so a filtered view is a link you can send">
        <div class="tabs">
          ${chip('ALL PROJECTS', !project, () => setParam('project', null))}
          ${projects.map((p) => chip(p, project === p, () => setParam('project', p)))}
        </div>
      <//>

      <${Section} title="BUILDS"
        note=${pager.total === null ? 'loading' : `${fmtNum(pager.rows.length)} of ${fmtNum(pager.total)} loaded · newest first`}>
        ${pager.error && !pager.rows.length
          ? html`<${ErrorBox} error=${pager.error} onRetry=${pager.reload}/>`
          : pager.loading && !pager.rows.length
            ? html`<${Skeleton} rows=${8} height=${20}/>`
            : html`<${SortableTable} columns=${columns} rows=${pager.rows} rowKey=${(b) => b.id}
                defaultSort="updated_at" defaultDir="desc"
                empty=${html`<${Empty} title="NO BUILDS IN FILTER"
                  note="Nothing matches this filter." />`} />`}
        <${More} pager=${pager} noun="builds"/>
      <//>
    </div>`;
}

// The pager's own honesty: it says how much is loaded against the filter's real
// total, and it never claims the end until the API stopped handing out cursors.
function More({ pager, noun }) {
  return html`
    <div class="footnote">
      <${Clock}/>
      ${pager.done
        ? html`<span>every ${noun} in this filter is loaded · the sort headers reorder all ${fmtNum(pager.rows.length)}</span>`
        : html`<span>${fmtNum(pager.rows.length)} of ${pager.total === null || pager.total === undefined ? '?' : fmtNum(pager.total)} loaded · the sort headers reorder what is loaded, not the rest</span>`}
      <span class="footnote__spacer"></span>
      ${pager.error && pager.rows.length
        ? html`<span style="color:var(--amber)">last page failed — ${pager.error.message}</span>` : null}
      ${pager.done
        ? html`<${Cursor} small=${true}/>`
        : html`<button class="btn btn--sm" disabled=${pager.loading} onClick=${pager.more}>
            ${pager.loading ? 'LOADING…' : `LOAD ${PAGE} MORE`}</button>`}
    </div>`;
}

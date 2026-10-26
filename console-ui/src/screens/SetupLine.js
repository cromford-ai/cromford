// The setup line (BH-7934.3): one onboarding run at
// /projects/:project/setup/:runId, read from GET /api/coord/onboarding/runs/:id
// ({run, steps}, worker/jobs/src/routes/onboarding.js). It polls every 5 s while
// the run is queued or running and stops on done, failed or cancelled. The two
// writes are RETRY on the failed station and CANCEL RUN (an in-app confirm).
// The screen has no nav tab: a tab cannot know a run id. The project page
// (/p/:project) links here through SetupRunLink, from the project's newest run.

import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { PageHeadline, StationTrack } from '../ui/line.js';
import { Skeleton, ErrorBox, Empty } from '../ui/primitives.js';
import { useConfirm } from '../ui/Modal.js';
import { useApi } from '../lib/hooks.js';

// The contract's seven stations, in ord order. Station 3 is `label` for a
// github-issues tracker and `tracker` for the board.
export const SETUP_STATIONS = ['register', 'prompt', 'label|tracker', 'box', 'clone', 'smoke', 'ready'];

// error_code -> the page where a person fixes it. Only an own key counts, so
// `toString` or `__proto__` from a step is not a link.
export const FIX_LINKS = { app_no_issues_write: 'https://github.com/settings/installations' };

const PURPOSE = {
  register: 'add the project to the fleet registry',
  prompt: 'write the project prompt',
  label: 'create the ai-build label',
  tracker: 'check the board tracker',
  box: 'place the project on its box',
  clone: 'clone the repo on the box',
  smoke: 'run a smoke build',
  ready: 'mark the project ready'
};

const PILLS = {
  queued: { label: 'QUEUED', tone: 'muted' },
  running: { label: 'RUNNING', tone: 'live' },
  done: { label: 'DONE', tone: 'ok' },
  failed: { label: 'FAILED', tone: 'fail' },
  skipped: { label: 'SKIPPED', tone: 'muted' }
};
const PILL_CLASS = { live: 'pill pill--live', fail: 'pill pill--dead', ok: 'pill', muted: 'pill pill--muted' };

export const POLL_MS = 5000;
const LIVE = ['queued', 'running'];
const CANCELLABLE = ['queued', 'running', 'failed'];

// The next poll in ms after an answer: 5000 while the run can still move (or
// before the first answer), 0 (no poll) once it is done, failed or cancelled.
export function nextPollMs(runState) {
  return runState === undefined || runState === null || LIVE.includes(runState) ? POLL_MS : 0;
}

// 42s, 3m 05s, 1h 02m. A step with no end yet runs to nowMs; no start is null.
export function formatDuration(startIso, endIso, nowMs) {
  const start = startIso ? Date.parse(startIso) : NaN;
  if (Number.isNaN(start)) return null;
  const end = endIso ? Date.parse(endIso) : nowMs;
  const s = Math.max(0, Math.floor((end - start) / 1000));
  const pad = (n) => String(n).padStart(2, '0');
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${pad(s % 60)}s`;
  return `${Math.floor(s / 3600)}h ${pad(Math.floor((s % 3600) / 60))}m`;
}

// A poll answer paints only when it is the newest request's.
export const acceptAnswer = (seq, latest) => seq === latest;

const fixLink = (code) => (typeof code === 'string' && Object.prototype.hasOwnProperty.call(FIX_LINKS, code) ? FIX_LINKS[code] : null);

// {run, steps} -> what the screen shows.
export function setupView(data, nowMs) {
  const run = (data && data.run) || {};
  const steps = (data && Array.isArray(data.steps) ? data.steps : []).slice().sort((a, b) => a.ord - b.ord);
  const total = steps.length || SETUP_STATIONS.length;
  const open = steps.find((s) => s.state !== 'done');
  const at = open ? open.ord : total;
  const stations = steps.map((s) => {
    const pill = PILLS[s.state] || { label: String(s.state || '?').toUpperCase(), tone: 'muted' };
    const detail = s.state === 'failed'
      ? (s.error_code || 'failed')
      : s.retries > 0 ? `retry ${s.retries}` : (PURPOSE[s.station] || '');
    const fix = s.state === 'failed'
      ? { excerpt: s.log_excerpt || '', href: fixLink(s.error_code), retry: run.state === 'failed' }
      : null;
    const end = s.finished_at || (s.state === 'running' ? null : s.started_at);
    return { station: s.station, ord: s.ord, pill, detail, duration: formatDuration(s.started_at, end, nowMs), fix };
  });
  const done = run.state === 'done';
  return {
    eyebrow: `STATION ${at} OF ${total}`,
    at,
    stations,
    log: steps.filter((s) => s.log_excerpt).map((s) => ({ station: s.station, excerpt: s.log_excerpt })),
    canCancel: CANCELLABLE.includes(run.state),
    openEnabled: done,
    openHref: done && run.project ? `/p/${encodeURIComponent(run.project)}` : null,
    live: LIVE.includes(run.state)
  };
}

export function StationList({ view, busy, onRetry }) {
  return html`
    <ol class="setup-stations">
      ${view.stations.map((s) => html`
        <li key=${s.station} class=${`setup-station setup-station--${s.pill.tone}`}>
          <div class="setup-station__row">
            <span class=${PILL_CLASS[s.pill.tone]}>${s.pill.label}</span>
            <span class="setup-station__name">${String(s.ord).padStart(2, '0')} ${s.station}</span>
            <span class="setup-station__detail">${s.detail}</span>
            <span class="setup-station__dur">${s.duration || '—'}</span>
          </div>
          ${s.fix ? html`
            <div class="setup-fixbox">
              <pre>${s.fix.excerpt || '(no log)'}</pre>
              <div class="setup-fixbox__actions">
                ${s.fix.retry ? html`<button type="button" class="btn setup-retry" disabled=${Boolean(busy)}
                  onClick=${onRetry}>${busy === 'retry' ? 'RETRYING…' : 'RETRY'}</button>` : null}
                ${s.fix.href ? html`<a class="btn setup-fix" href=${s.fix.href} target="_blank" rel="noopener">FIX ON GITHUB</a>` : null}
              </div>
            </div>` : null}
        </li>`)}
    </ol>`;
}

const hhmm = () => `${new Date().toISOString().slice(11, 16)}Z`;

// One GET per poll, never two at once: the next timer starts after an answer.
// Each request takes a seq; an answer paints only if its seq is still the
// latest, so a poll in flight before a RETRY cannot paint `failed` back over
// `queued`. useApi is not used: its one `alive` ref is shared by every
// request of a mounted screen, so it cannot drop a superseded answer.
function useSetupRun(runId) {
  const [st, setSt] = useState({ data: null, error: null, stale: null });
  const seq = useRef(0);
  const timer = useRef(null);
  const last = useRef(null);
  const load = useCallback(() => {
    clearTimeout(timer.current);
    const mine = ++seq.current;
    api.setupRun(runId).then((data) => {
      if (!acceptAnswer(mine, seq.current)) return;
      last.current = data;
      setSt({ data, error: null, stale: null });
      const ms = nextPollMs(data && data.run ? data.run.state : null);
      if (ms > 0) timer.current = setTimeout(load, ms);
    }, (error) => {
      if (!acceptAnswer(mine, seq.current)) return;
      // A failed poll after an answer keeps the last answer, says so, and
      // polls again while that answer is live. A first-load failure or a 404
      // replaces it: there is no run to show.
      const prev = last.current;
      if (prev && error.status !== 404) {
        setSt({ data: prev, error: null, stale: hhmm() });
        if (nextPollMs(prev.run ? prev.run.state : null) > 0) timer.current = setTimeout(load, POLL_MS);
        return;
      }
      last.current = null;
      setSt({ data: null, error, stale: null });
    });
  }, [runId]);
  useEffect(() => {
    last.current = null;
    setSt({ data: null, error: null, stale: null });
    load();
    return () => { seq.current++; clearTimeout(timer.current); };
  }, [load]);
  return { ...st, reload: load };
}

// The project page's link to the newest run's setup line, or null when the
// project has no run (or the read failed: the link is an extra, never an error).
export function setupLinkFor(project, data) {
  const run = data && data.run;
  if (!run || !run.id) return null;
  return {
    to: `/projects/${encodeURIComponent(project)}/setup/${encodeURIComponent(run.id)}`,
    label: `SETUP ${String(run.state || '').toUpperCase()}`.trim()
  };
}

export function SetupRunLinkView({ project, data }) {
  const link = setupLinkFor(project, data);
  return link ? html`<${Link} to=${link.to} class="btn setup-entry">${link.label}<//>` : null;
}

export function SetupRunLink({ project }) {
  const latest = useApi(() => api.setupLatest(project), [project]);
  return html`<${SetupRunLinkView} project=${project} data=${latest.data}/>`;
}

export function SetupLineScreen({ project, runId }) {
  const { data, error, stale, reload } = useSetupRun(runId);
  const [dialog, askConfirm] = useConfirm();
  const [busy, setBusy] = useState(null);
  const [actErr, setActErr] = useState(null);
  const pending = useRef(false);

  // One write at a time: the ref stops a second click before the disabled
  // attribute has rendered. Success or refusal, the run is read again.
  const act = async (kind, fn) => {
    if (pending.current) return;
    pending.current = true;
    setBusy(kind);
    setActErr(null);
    try {
      await fn();
    } catch (e) {
      setActErr(`${kind === 'retry' ? 'RETRY' : 'CANCEL'} refused: ${e && e.message ? e.message : e}`);
    } finally {
      pending.current = false;
      setBusy(null);
      reload();
    }
  };
  const onRetry = () => act('retry', () => api.setupRetry(runId));
  const onCancel = async () => {
    const ok = await askConfirm({
      title: 'CANCEL THIS SETUP RUN?',
      body: 'Every station that is not done is skipped. A station already running on the box can still finish.',
      confirmLabel: 'CANCEL RUN',
      cancelLabel: 'KEEP IT',
      tone: 'danger'
    });
    if (ok) act('cancel', () => api.setupCancel(runId));
  };

  if (!data) {
    // The headline is there in every state, saying which run is being read.
    let body = html`<div class="setup-skeleton" aria-busy="true"><${Skeleton} rows=${7} height=${18}/></div>`;
    if (error && error.status === 404) {
      body = html`<${Empty} title=${`No setup run ${runId}`}
        note="The run id is not known. It may be mistyped, or the run aged out of the retention window."/>`;
    } else if (error) {
      body = html`<${ErrorBox} error=${error} onRetry=${reload}/>`;
    }
    return html`
      <div class="page setup-line">
        <${PageHeadline} chip="SETUP RUN" line1=${`Setting up ${project}`} line2=${runId}/>
        ${body}
      </div>`;
  }

  const view = setupView(data, Date.now());
  const run = data.run || {};
  const trackState = run.state === 'failed' ? 'fail' : run.state === 'cancelled' ? 'held' : 'now';
  const names = view.stations.length ? view.stations.map((s) => s.station) : SETUP_STATIONS;
  return html`
    <div class="page setup-line">
      <${PageHeadline} chip=${view.eyebrow} line1=${`Setting up ${run.project || project}`}
        line2=${`${run.repo || ''} · ${String(run.state || '').toUpperCase()}`}
        lede=${view.live ? 'This page reads the run every 5 seconds.' : null}/>
      <div class="setup-strip">
        <${StationTrack} stations=${names} at=${view.at - 1} state=${trackState} label="setup"/>
      </div>
      ${stale ? html`<p class="setup-stale" role="status">last update failed ${stale}</p>` : null}
      ${actErr ? html`<p class="setup-error" role="alert">${actErr}</p>` : null}
      <${StationList} view=${view} busy=${busy} onRetry=${onRetry}/>
      <details class="setup-log">
        <summary>LOG</summary>
        ${view.log.length
          ? view.log.map((l) => html`<div class="setup-log__entry" key=${l.station}><span class="setup-log__station">${l.station}</span><pre>${l.excerpt}</pre></div>`)
          : html`<p class="setup-log__none">no station has written a log yet</p>`}
      </details>
      <div class="setup-bar">
        <button type="button" class="btn btn--danger setup-cancel" disabled=${!view.canCancel || Boolean(busy)}
          onClick=${onCancel}>${busy === 'cancel' ? 'CANCELLING…' : 'CANCEL RUN'}</button>
        ${view.openHref
          ? html`<${Link} class="btn btn--primary setup-open" to=${view.openHref}>OPEN PROJECT<//>`
          : html`<a class="btn btn--primary setup-open" aria-disabled="true">OPEN PROJECT</a>`}
      </div>
      ${dialog}
    </div>`;
}

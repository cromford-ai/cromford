import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { html, Link, navigate } from '../router.js';
import { api, AuthError } from '../api.js';
import { PageHeadline } from '../ui/line.js';
import { Skeleton } from '../ui/primitives.js';
import { useApi } from '../lib/hooks.js';
import {
  KNOBS, knobInt, parseSlug, deriveProject, derivePrefix, projectOk, prefixOk, defaultTracker,
  TRACKERS, canContinue, canStart, reviewLines, makeStarter
} from '../lib/onboard.js';
import { NewRepoPanel } from './onboard/NewRepoPanel.js';

// /projects/new (BH-7999, BH-7935.2): step 1 picks the repo, step 2 the
// tracker, and Start setup files one onboarding run (POST
// /api/coord/onboarding/runs) and opens its setup line. The pure rules are in
// lib/onboard.js; the styles are onboard.css, imported by main.js because the
// node suites import this file and node cannot load CSS.
// owner BH-7935.2

const TEMPLATES = ['nextjs', 'worker', 'empty'];
const BOXES = [
  { id: 'shared', label: 'Shared' },
  { id: 'dedicated', label: 'Dedicated', tag: 'wave 6' },
  { id: 'fly', label: 'Fly pool', tag: 'wave 6' }
];
const unauthorized = () => window.dispatchEvent(new CustomEvent('dash:unauthorized'));
const settingRow = (q) => (q.data && q.data.setting) || null;

// The repo-detect poll for one slug: one idle wait, then a GET every pollMs
// until the answer is ok or error, or maxS has passed. An answer that lands
// after the slug changed (or the screen left) is dropped.
function useDetect(slug, pollMs, maxS) {
  const [detect, setDetect] = useState({ status: 'idle' });
  const [attempt, setAttempt] = useState(0);
  const timing = useRef({ pollMs, maxS });
  timing.current = { pollMs, maxS };
  useEffect(() => {
    if (!slug) { setDetect({ status: 'idle' }); return undefined; }
    let alive = true;
    let timer = null;
    const started = Date.now();
    setDetect({ status: 'pending' });
    const poll = async () => {
      let answer;
      try {
        answer = await api.onboardRepo(slug);
      } catch (e) {
        if (!alive) return;
        if (e instanceof AuthError) unauthorized();
        setDetect({ status: 'error', error: e.message });
        return;
      }
      if (!alive) return;
      if (answer && answer.state === 'ok') { setDetect({ status: 'ok', answer }); return; }
      if (answer && answer.state === 'error') { setDetect({ status: 'error', error: answer.error || 'the repo check failed' }); return; }
      const waited = (Date.now() - started) / 1000;
      if (waited >= timing.current.maxS) { setDetect({ status: 'timeout', waited: Math.round(waited) }); return; }
      timer = setTimeout(poll, timing.current.pollMs);
    };
    timer = setTimeout(poll, timing.current.pollMs);
    return () => { alive = false; clearTimeout(timer); };
  }, [slug, attempt]);
  return [detect, () => setAttempt((n) => n + 1)];
}

function DetectCard({ slug, detect, onRetry }) {
  if (detect.status === 'idle') return null;
  const retry = html`<button type="button" class="btn btn--sm" onClick=${onRetry}>Retry</button>`;
  let body;
  if (detect.status === 'pending') {
    body = html`<span class="onboard-detect__note">Checking the repo…</span><${Skeleton} rows=${3} />`;
  } else if (detect.status === 'error') {
    body = html`<p class="onboard-detect__note">${detect.error}</p>${retry}`;
  } else if (detect.status === 'timeout') {
    body = html`<p class="onboard-detect__note">Still checking after ${detect.waited} s.</p>${retry}`;
  } else if (detect.answer.visible === true) {
    const f = detect.answer.facts || {};
    const issues = f.has_issues === true ? 'on' : f.has_issues === false ? 'off' : 'unknown';
    body = html`<dl class="onboard-facts">
      <dt>Default branch</dt><dd>${f.default_branch || 'unknown'}</dd>
      <dt>Issues</dt><dd>${issues}</dd>
      <dt>Open issues</dt><dd>${Number.isFinite(f.open_issues) ? f.open_issues : 'unknown'}</dd>
      <dt>Repo</dt><dd><a href=${`https://github.com/${slug}`} target="_blank" rel="noopener">github.com/${slug}</a></dd>
    </dl>`;
  } else {
    const url = typeof detect.answer.install_url === 'string' && detect.answer.install_url.startsWith('https://') ? detect.answer.install_url : null;
    body = html`<p class="onboard-detect__note">The GitHub App cannot see this repo yet.</p>
      ${url ? html`<a class="btn btn--sm" href=${url} target="_blank" rel="noopener">Install the GitHub App</a>` : null}
      ${retry}`;
  }
  return html`<section class="onboard-detect" aria-live="polite">${body}</section>`;
}

function Radios({ label, options, value, onPick }) {
  return html`<div class="onboard-radios" role="radiogroup" aria-label=${label}>
    ${options.map((o) => html`<button type="button" role="radio" data-value=${o.id}
      class=${`onboard-radio${value === o.id ? ' onboard-radio--on' : ''}`}
      aria-checked=${value === o.id ? 'true' : 'false'} disabled=${o.disabled}
      onClick=${() => { if (!o.disabled) onPick(o.id); }}>
      <span class="onboard-radio__label">${o.label}</span>
      ${o.tag ? html`<span class="tag tag--idle">${o.tag}</span>` : null}
      ${o.note ? html`<span class="onboard-radio__note">${o.note}</span>` : null}
    </button>`)}
  </div>`;
}

function Field({ id, label, value, onInput, error, placeholder }) {
  return html`<label class="onboard-field" for=${id}>
    <span>${label}</span>
    <input id=${id} value=${value} placeholder=${placeholder} autocomplete="off"
      aria-invalid=${error ? 'true' : 'false'} onInput=${(e) => onInput(e.currentTarget.value)} />
    ${error ? html`<span class="onboard-field__err" id=${`${id}-err`} role="alert">${error}</span>` : null}
  </label>`;
}

export function OnboardScreen() {
  // Four independent reads, all started on mount; none blocks the input.
  const repos = useApi(() => api.onboardRepos(), []);
  const readyQ = useApi(() => api.coordSetting(KNOBS.boardReady.key), []);
  const pollQ = useApi(() => api.coordSetting(KNOBS.pollMs.key), []);
  const maxQ = useApi(() => api.coordSetting(KNOBS.pollMaxS.key), []);
  const boardReady = knobInt(settingRow(readyQ), KNOBS.boardReady.fallback, 0) === 1;
  const pollMs = knobInt(settingRow(pollQ), KNOBS.pollMs.fallback);
  const maxS = knobInt(settingRow(maxQ), KNOBS.pollMaxS.fallback);

  const [step, setStep] = useState(1);
  const [segment, setSegment] = useState('existing');
  const [slug, setSlug] = useState('');
  const [fresh, setFresh] = useState({ owner: '', name: '', template: 'nextjs' });
  const [edits, setEdits] = useState({});
  const [advOpen, setAdvOpen] = useState(false);
  const [tracker, setTracker] = useState(null);
  const [picked, setPicked] = useState(false);
  const [starting, setStarting] = useState(false);
  const [startErr, setStartErr] = useState(null);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);

  const parsed = parseSlug(slug);
  const [detect, retryDetect] = useDetect(parsed ? parsed.slug : null, pollMs, maxS);
  const facts = detect.status === 'ok' && detect.answer.visible === true ? (detect.answer.facts || {}) : null;

  // A field the user edited keeps its value; the others follow the slug.
  const project = edits.project ?? deriveProject(slug);
  const prefix = edits.prefix ?? derivePrefix(project);
  const base = edits.base ?? ((facts && facts.default_branch) || '');
  const prod = edits.prod ?? '';
  const edit = (k) => (v) => setEdits((e) => ({ ...e, [k]: v }));
  const projectErr = parsed && !projectOk(project) ? 'Use 1-19 chars of a-z, 0-9 and -, starting with a letter or digit.' : null;
  const prefixErr = parsed && !prefixOk(prefix) ? 'Use 2-10 chars of A-Z and 0-9, starting with a letter.' : null;

  const state = { segment, slug, project, prefix, base, prod, tracker, inFlight: starting };
  const starter = useMemo(() => makeStarter({ run: api.onboardRun, navigate, uuid: () => crypto.randomUUID() }), []);

  const onContinue = () => {
    if (!canContinue(state)) return;
    if (!picked) setTracker(defaultTracker(facts, boardReady));
    setStep(2);
  };
  const onStart = async () => {
    if (!canStart(state)) return;
    setStarting(true);
    setStartErr(null);
    try {
      const res = await starter(state);
      if (res.error && alive.current) setStartErr(res.error);
    } catch (e) {
      if (e instanceof AuthError) unauthorized();
      else if (alive.current) setStartErr(`Could not start setup: ${e.message}`);
    } finally {
      if (alive.current) setStarting(false);
    }
  };

  const repoNames = repos.data && repos.data.state === 'ok' && Array.isArray(repos.data.repos) ? repos.data.repos : [];
  const issuesOff = facts && facts.has_issues === false;
  const trackerCards = TRACKERS.map((t) => ({
    ...t,
    disabled: t.never || (t.id === 'board' && !boardReady),
    tag: t.id === 'board' && boardReady ? null : t.tag,
    note: t.id !== 'github-issues' ? null
      : issuesOff ? 'Issues are off in this repo. Turn them on in the repo settings, then pick this card.'
        : facts ? null : 'We could not check Issues yet.'
  }));

  const stepOne = html`
    <${Radios} label="Repo" value=${segment} onPick=${setSegment}
      options=${[{ id: 'existing', label: 'Existing repo' }, { id: 'new', label: 'New repo' }]} />
    ${segment === 'existing' ? html`
      <label class="onboard-field" for="onboard-slug">
        <span>GitHub repo</span>
        <input id="onboard-slug" list="onboard-repos" value=${slug} autocomplete="off"
          placeholder="owner/repo or https://github.com/owner/repo"
          onInput=${(e) => setSlug(e.currentTarget.value)} />
      </label>
      <datalist id="onboard-repos">${repoNames.map((r) => html`<option value=${r} />`)}</datalist>
      <${DetectCard} slug=${parsed ? parsed.slug : ''} detect=${detect} onRetry=${retryDetect} />
    ` : html`
      <div class="onboard-new">
        <${Field} id="onboard-new-owner" label="Owner" value=${fresh.owner} onInput=${(v) => setFresh((f) => ({ ...f, owner: v }))} />
        <${Field} id="onboard-new-name" label="Name" value=${fresh.name} onInput=${(v) => setFresh((f) => ({ ...f, name: v }))} />
        <${Radios} label="Template" value=${fresh.template} onPick=${(v) => setFresh((f) => ({ ...f, template: v }))}
          options=${TEMPLATES.map((t) => ({ id: t, label: t }))} />
        <${NewRepoPanel} owner=${fresh.owner} name=${fresh.name} template=${fresh.template}
          onCreated=${(s) => { setSlug(s); setSegment('existing'); }} />
        <p class="onboard-hint">Create the repo first.</p>
      </div>`}
    <details class="onboard-adv" open=${advOpen || Boolean(projectErr || prefixErr)}
      onToggle=${(e) => setAdvOpen(e.currentTarget.open)}>
      <summary>Advanced</summary>
      <${Field} id="onboard-project" label="Project name" value=${project} onInput=${edit('project')} error=${projectErr} />
      <${Field} id="onboard-prefix" label="Ticket prefix" value=${prefix} onInput=${edit('prefix')} error=${prefixErr} />
      <${Field} id="onboard-base" label="Base branch" value=${base} onInput=${edit('base')} />
      <${Field} id="onboard-prod" label="Production URL" value=${prod} onInput=${edit('prod')} placeholder="https://" />
      <fieldset class="onboard-box">
        <legend>Box</legend>
        ${BOXES.map((b) => html`<label class="onboard-box__opt">
          <input type="radio" name="onboard-box" value=${b.id} checked=${b.id === 'shared'} disabled=${b.id !== 'shared'} />
          <span>${b.label}</span>${b.tag ? html`<span class="tag tag--idle">${b.tag}</span>` : null}
        </label>`)}
      </fieldset>
    </details>`;

  const stepTwo = html`
    <${Radios} label="Tracker" value=${tracker} options=${trackerCards}
      onPick=${(v) => { setTracker(v); setPicked(true); }} />
    <section class="onboard-review">
      <h2 class="onboard-review__title">Review</h2>
      <dl>
        ${reviewLines(state).map((l) => (l.label
          ? html`<dt>${l.label}</dt><dd>${l.value}</dd>`
          : html`<dd class="onboard-review__last">${l.value}</dd>`))}
      </dl>
      ${startErr ? html`<p class="onboard-review__err" role="alert">${startErr}</p>` : null}
    </section>`;

  return html`<div class="onboard">
    <${PageHeadline} line1="New project" line2=${step === 1 ? 'Step 1 of 2: the repo' : 'Step 2 of 2: the tracker'} />
    <div class="onboard-body">${step === 1 ? stepOne : stepTwo}</div>
    <div class="onboard-bar">
      ${step === 1
        ? html`<${Link} to="/" class="btn">Back<//>
          <button type="button" class="btn btn--primary" disabled=${!canContinue(state)} onClick=${onContinue}>Continue</button>`
        : html`<button type="button" class="btn" onClick=${() => setStep(1)}>Back</button>
          <button type="button" class="btn btn--primary" disabled=${!canStart(state)} onClick=${onStart}>${starting ? 'Starting…' : 'Start setup'}</button>`}
    </div>
  </div>`;
}

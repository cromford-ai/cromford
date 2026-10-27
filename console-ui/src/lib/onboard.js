// The pure half of /projects/new (BH-7999, BH-7935.2): the slug rule, the
// derived project name and prefix, the tracker default, the run body, the
// Review lines and the Start setup flight. src/screens/Onboard.js renders it.

// The three settings rows the screen reads (schema fragment
// worker/jobs/schema.d/202610270351-bh-7935-onboarding-board-ready.sql). The
// fallback is what the screen uses when a row is absent or unreadable.
export const KNOBS = {
  boardReady: { key: 'onboarding.product_board_ready', fallback: 0 },
  pollMs: { key: 'onboarding.detect_poll_ms', fallback: 3000 },
  pollMaxS: { key: 'onboarding.detect_poll_max_s', fallback: 120 }
};

// A settings row's value as an integer >= min, else the fallback. An absent
// row is not 0 (D11).
export function knobInt(row, fallback, min = 1) {
  const raw = row && typeof row === 'object' ? String(row.value ?? '').trim() : '';
  if (!/^[0-9]+$/.test(raw)) return fallback;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= min ? n : fallback;
}

// A copy of parseRepoSlug in worker/jobs/src/routes/onboarding-repo.js, so the
// screen refuses exactly what the repo-detect route refuses.
const SLUG_RAW_MAX = 2048;
const OWNER_RE = /^[A-Za-z0-9-]{1,39}$/;
const NAME_RE = /^[A-Za-z0-9_.-]{1,100}$/;
const URL_RE = /^https:\/\/github\.com\/([^/]+)\/([^/]+)(\/[^\s?#]*)?$/;
const BARE_RE = /^([^/]+)\/([^/]+)$/;

export function parseSlug(raw) {
  if (typeof raw !== 'string' || raw.length > SLUG_RAW_MAX) return null;
  const s = raw.trim();
  const m = s.startsWith('https://github.com/') ? URL_RE.exec(s) : BARE_RE.exec(s);
  if (!m) return null;
  const owner = m[1];
  const repo = m[2].endsWith('.git') ? m[2].slice(0, -4) : m[2];
  if (!OWNER_RE.test(owner) || !NAME_RE.test(repo) || repo === '.' || repo === '..') return null;
  return { owner, repo, slug: `${owner}/${repo}` };
}

// MAX_PROJECT_LEN in bin/load-project.sh: a project-scoped settings key must
// fit the worker's 64 chars. A structural limit, not a business knob.
const PROJECT_MAX = 19;

export const projectOk = (p) => typeof p === 'string' && /^[a-z0-9][a-z0-9-]{0,18}$/.test(p);
export const prefixOk = (p) => typeof p === 'string' && /^[A-Z][A-Z0-9]{1,9}$/.test(p);

// The repo part as a project name: lower case, other chars to -, no leading or
// trailing -, at most 19 chars. '' for a slug parseSlug refuses.
export function deriveProject(slug) {
  const p = parseSlug(slug);
  if (!p) return '';
  return p.repo.toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^-+/, '')
    .slice(0, PROJECT_MAX).replace(/-+$/, '');
}

// bin/load-project.sh: the upper-case first letter of each - segment; under
// 2 chars, the first two chars of the name.
export function derivePrefix(name) {
  const s = String(name || '');
  const initials = s.split('-').map((seg) => seg.slice(0, 1).toUpperCase()).join('');
  return initials.length >= 2 ? initials : s.slice(0, 2).toUpperCase();
}

// The tracker step 2 preselects. Only has_issues === false is "off"; facts
// that are absent or not a boolean are unknown, and unknown is GitHub Issues.
export function defaultTracker(facts, productBoardReady) {
  if (facts && facts.has_issues === false) return productBoardReady ? 'board' : null;
  return 'github-issues';
}

export const TRACKERS = [
  { id: 'github-issues', label: 'GitHub Issues' },
  { id: 'board', label: 'Product board', tag: 'soon' },
  { id: 'linear', label: 'Linear', tag: 'wave 3', never: true },
  { id: 'jira', label: 'Jira', tag: 'wave 3', never: true },
  { id: 'app-board', label: 'App board', tag: 'wave 3', never: true }
];
const trackerLabel = (id) => (TRACKERS.find((t) => t.id === id) || {}).label;

// The body of POST /api/onboarding/runs. Empty optional fields are dropped.
export function runInputs(state) {
  const p = parseSlug(state.slug);
  const out = { repo: p ? p.slug : '', project: state.project, tracker: state.tracker, box: 'shared' };
  for (const k of ['prefix', 'base', 'prod']) {
    const v = typeof state[k] === 'string' ? state[k].trim() : '';
    if (v) out[k] = v;
  }
  return out;
}

export const canContinue = (state) => state.segment === 'existing' && parseSlug(state.slug) !== null;

export const canStart = (state) => Boolean(state.tracker) && projectOk(state.project)
  && prefixOk(state.prefix) && parseSlug(state.slug) !== null && !state.inFlight;

export const LAST_REVIEW_LINE = 'Nothing is built until a ticket is labeled.';

export function reviewLines(state) {
  const p = parseSlug(state.slug);
  return [
    { label: 'Repo', value: p ? p.slug : 'not set' },
    { label: 'Project', value: `${state.project || 'not set'} · prefix ${state.prefix || 'not set'}` },
    { label: 'Tracker', value: trackerLabel(state.tracker) || 'not picked' },
    { label: 'Box', value: 'Shared' },
    { label: 'AI account', value: 'fleet pool' },
    { label: null, value: LAST_REVIEW_LINE }
  ];
}

export const NOT_LIVE = 'Setup runs are not live yet (wave 1, #7934).';

// The sentence a failed create shows.
export function startError(err) {
  const status = err && err.status;
  if (status === 404 || status === 405) return NOT_LIVE;
  if (status === 400 && err.body && typeof err.body.field === 'string') return `The setup service refused the ${err.body.field} field.`;
  if (status === 409) return 'This form was already used for another run. Change a field or reload.';
  return `Could not start setup: ${err && err.message ? err.message : String(err)}`;
}

// start(state) -> a promise of {id} or {error}. One Idempotency-Key per form
// state: a retry of the same inputs sends the same key, so the worker answers
// the first run. While a call is in flight, start returns that call's promise
// and sends nothing. navigate runs only on an answer that carries an id. An
// AuthError is rethrown for the app shell.
export function makeStarter({ run, navigate, uuid }) {
  const keys = new Map();
  let flight = null;
  return function start(state) {
    if (flight) return flight;
    const inputs = runInputs(state);
    const form = JSON.stringify(inputs);
    if (!keys.has(form)) keys.set(form, uuid());
    const key = keys.get(form);
    // The callbacks run on a later turn, so flight is set before it is cleared.
    flight = Promise.resolve()
      .then(() => run(inputs, key))
      .then((res) => {
        if (!res || typeof res.id !== 'string' || !res.id) return { error: startError(new Error('no run id in the answer')) };
        navigate(`/projects/${encodeURIComponent(inputs.project)}/setup/${encodeURIComponent(res.id)}`);
        return { id: res.id };
      }, (err) => {
        if (err && err.name === 'AuthError') throw err;
        return { error: startError(err) };
      })
      .finally(() => { flight = null; });
    return flight;
  };
}

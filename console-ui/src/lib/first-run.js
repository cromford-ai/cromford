// First run of a new fleet (BH-7977, BH-7939.3): the console half of
// GET /api/fleet/first-run. The `/` screen (src/screens/Fleet.js) reads it once
// per load, beside the projects read, and shows src/screens/FirstRun.js in
// place of the Fleet list while a required account is missing and the gate row
// first_run.gate is on. Note: docs/notes/2026-10-25-BH-7977-first-run.md.

import { AuthError } from '../api.js';

// The worker route through the coord proxy (/api/coord/<rest> → /api/<rest>).
export const FIRST_RUN_PATH = '/api/coord/fleet/first-run';

// The call in the shape of aiAccountsApi (lib/ai-accounts.js), for a later
// spread into `api` (src/api.js).
export const firstRunApi = ({ get, coordPath }) => ({
  firstRun: () => get(coordPath('/api/fleet/first-run'))
});

const REQUIRED = ['anthropic', 'github_app', 'telegram'];

// firstRunFrom(body) -> {anthropic, github_app, telegram, more_ai, gate, complete}.
// Only `true` is true. `complete` is recomputed from the three required flags,
// so a body with a missing or wrong `complete` never hides the screen.
export function firstRunFrom(body) {
  const b = body && typeof body === 'object' ? body : {};
  const out = {};
  for (const k of [...REQUIRED, 'more_ai', 'gate']) out[k] = b[k] === true;
  out.complete = REQUIRED.every((k) => out[k]);
  return out;
}

// showFirstRun(state) -> true only when the gate is on and a required account
// is missing.
export const showFirstRun = (s) => Boolean(s) && s.gate === true && s.complete === false;

// loadFirstRun(fetchImpl) -> firstRunFrom(body). The same error shapes as
// api.js request(): an AuthError on a lost session, else an Error with .status.
export async function loadFirstRun(fetchImpl = (...a) => fetch(...a)) {
  let res;
  try {
    res = await fetchImpl(FIRST_RUN_PATH, { credentials: 'same-origin' });
  } catch {
    throw new Error('network unreachable');
  }
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  if ((res.status === 403 && !(body && body.error === 'owner_only'))
    || (res.status === 404 && body && body.error === 'unauthorized')) {
    throw new AuthError();
  }
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return firstRunFrom(body);
}

// The four cards, in order. A `sheet` card opens the AI account add sheet; an
// `href` card links to its settings row (no setup sheet exists for it yet).
export const FIRST_RUN_CARDS = [
  { id: 'anthropic', title: 'Anthropic (Claude)', required: true, action: 'sheet' },
  { id: 'github_app', title: 'GitHub App', required: true, href: '/config/setting/github_app.installed' },
  { id: 'telegram', title: 'Telegram', required: true, href: '/config/setting/telegram.chat_id' },
  { id: 'more_ai', title: 'More AI accounts', required: false, action: 'sheet' }
];

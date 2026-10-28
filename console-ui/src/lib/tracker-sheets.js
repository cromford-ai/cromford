// The pure half of the tracker connect sheets (BH-7936, src/ui/TrackerSheets.js):
// the fields of each sheet, the Jira status map defaults, the field checks,
// the coord client and the test run (seal, store the envelope, start, poll).
//
// BH-7968: the fields leave the browser only as a secret envelope. They are
// sealed as one JSON plaintext {"fields":{...}} to the hub key (settings row
// hub_envelope_public_key) and stored with scope tracker:<kind>:<project>;
// the test start carries the envelope id and no field value. The hub probe
// (bin/lib/hub-probes/tracker-test.sh) opens the envelope and checks the
// fields again, because only the hub sees them.

import { api } from '../api.js';
import { loadSheetConfig } from './ai-accounts.js';
import { sealSecret } from './envelope.js';

export const TRACKER_KINDS = ['linear', 'jira', 'board'];

export const TRACKER_TITLES = { linear: 'Connect Linear', jira: 'Connect Jira', board: "Connect the app's board" };

// Decision 1. `secret` fields are the credential: a password input, never
// handed to onConnected and never stored in the browser.
export const TRACKER_FIELDS = {
  linear: [
    { name: 'api_key', label: 'API key', secret: true, hint: 'A Linear personal API key.' },
    { name: 'team', label: 'Team key', placeholder: 'CRO' },
    { name: 'label', label: 'Build label', placeholder: 'ai-build', initial: 'ai-build' }
  ],
  jira: [
    { name: 'site', label: 'Site', placeholder: 'acme.atlassian.net' },
    { name: 'email', label: 'Email', placeholder: 'you@example.com' },
    { name: 'api_token', label: 'API token', secret: true },
    { name: 'project_key', label: 'Project key', placeholder: 'CROM' }
  ],
  board: [
    { name: 'api_base', label: 'Board API base', placeholder: 'https://app.example.com/api/board' },
    { name: 'token', label: 'Internal token', secret: true }
  ]
};

// Decision 4: the harness state, the Jira adapter's status_map alias, and the
// Jira status it maps to. Each status is editable on the sheet.
export const JIRA_STATUS_DEFAULTS = [
  { key: 'todo', label: 'ready', status: 'To Do' },
  { key: 'in_progress', label: 'building', status: 'In Progress' },
  { key: 'review', label: 'review', status: 'In Review' },
  { key: 'closed', label: 'closed', status: 'Done' }
];

export const POLL_MS = 5000;
// The hub-probe lane runs every 10 minutes; a test with no answer after 20 is
// reported as an error, never left spinning.
export const MAX_WAIT_MS = 20 * 60 * 1000;

export const defaultStatuses = () => Object.fromEntries(JIRA_STATUS_DEFAULTS.map((r) => [r.key, r.status]));

export function initialValues(kind) {
  return Object.fromEntries((TRACKER_FIELDS[kind] || []).map((f) => [f.name, f.initial || '']));
}

export function statusMapString(statuses) {
  return JIRA_STATUS_DEFAULTS.map((r) => `${r.key}=${String((statuses || {})[r.key] ?? '').trim()}`).join(';');
}

// The first required field that is blank after a trim, as {name, label}, or null.
export function missingField(kind, values, statuses) {
  for (const f of TRACKER_FIELDS[kind] || []) {
    if (!String((values || {})[f.name] ?? '').trim()) return { name: f.name, label: f.label };
  }
  if (kind === 'jira') {
    for (const r of JIRA_STATUS_DEFAULTS) {
      if (!String((statuses || {})[r.key] ?? '').trim()) return { name: `status_${r.key}`, label: `status for ${r.label}` };
    }
  }
  return null;
}

// The fields the sheet seals: trimmed, and for Jira the status map string.
export function sendFields(kind, values, statuses) {
  const out = {};
  for (const f of TRACKER_FIELDS[kind] || []) out[f.name] = String((values || {})[f.name] ?? '').trim();
  if (kind === 'jira') out.status_map = statusMapString(statuses || defaultStatuses());
  return out;
}

// The fields without the credential: what onConnected hands the screen.
export function publicFields(kind, fields) {
  const secret = new Set((TRACKER_FIELDS[kind] || []).filter((f) => f.secret).map((f) => f.name));
  return Object.fromEntries(Object.entries(fields || {}).filter(([k]) => !secret.has(k)));
}

// The checks of each field (BH-7936 decision 1). `secret` is the credential.
// The hub probe applies the same table (bin/lib/hub-probes/tracker-test.sh
// _onb_fields_check); this copy only answers the user before anything is sent.
const FIELD_MAX = 512;
const SECRET_MIN = 8;
const KIND_FIELDS = {
  linear: { api_key: 'secret', team: 'team', label: 'label' },
  jira: { site: 'site', email: 'email', api_token: 'secret', project_key: 'jira_key', status_map: 'status_map' },
  board: { api_base: 'api_base', token: 'secret' }
};

// A literal IPv4 host in a private, loopback, link-local, CGNAT or "this
// network" range. A board base must be a public https host.
function privateV4(host) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

function apiBaseError(v) {
  let u;
  try { u = new URL(v); } catch { return 'api_base must be an https:// URL'; }
  if (u.protocol !== 'https:') return 'api_base must be an https:// URL';
  if (u.username || u.password || u.search || u.hash) return 'api_base must not carry a user, a query or a fragment';
  const host = u.hostname.toLowerCase();
  if (host.startsWith('[') || host === 'localhost' || host.endsWith('.localhost') || privateV4(host) || !host.includes('.')) {
    return 'api_base must be a public host';
  }
  return null;
}

function fieldError(name, type, v) {
  switch (type) {
    case 'secret': return v.length >= SECRET_MIN ? null : `${name} must be at least ${SECRET_MIN} characters`;
    case 'team': return /^[A-Za-z0-9_]{1,16}$/.test(v) ? null : 'team must be a Linear team key (letters, digits, _)';
    case 'label': return /^[^\s"\\][^"\\]{0,99}$/.test(v) ? null : 'label must be 1-100 characters with no quote or backslash';
    case 'site': return /^[a-z0-9-]+\.atlassian\.net$/.test(v) ? null : 'site must be <name>.atlassian.net';
    case 'email': return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? null : 'email must be an email address';
    case 'jira_key': return /^[A-Z][A-Z0-9_]{1,9}$/.test(v) ? null : 'project_key must be a Jira project key (CROM)';
    case 'status_map':
      return v.split(';').every((e) => /^[a-z0-9_-]+=[^=;]+$/.test(e)) ? null : 'status_map must be alias=Status;alias=Status';
    case 'api_base': return apiBaseError(v);
    default: return `${name} is not a field`;
  }
}

// checkTrackerFields(kind, raw) -> {fields} trimmed (the Jira site lower-cased)
// | {error}. The error never repeats a value.
export function checkTrackerFields(kind, raw) {
  const spec = KIND_FIELDS[kind];
  if (!spec) return { error: 'kind must be linear, jira or board' };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'fields must be an object' };
  for (const k of Object.keys(raw)) if (!(k in spec)) return { error: `${k} is not a ${kind} field` };
  const fields = {};
  for (const [name, type] of Object.entries(spec)) {
    const v0 = raw[name];
    if (v0 === undefined || v0 === null) return { error: `${name} is required` };
    if (typeof v0 !== 'string') return { error: `${name} must be a string` };
    let v = v0.trim();
    if (!v) return { error: `${name} is required` };
    if (v.length > FIELD_MAX) return { error: `${name} must be at most ${FIELD_MAX} characters` };
    if (type === 'site') v = v.toLowerCase();
    const e = fieldError(name, type, v);
    if (e) return { error: e };
    fields[name] = v;
  }
  return { fields };
}

// The envelope scope of one tracker test. The worker route
// (worker/jobs/src/routes/onboarding-tracker.js trackerScope) and the hub
// probe compare against the same string.
export const trackerScope = (kind, project) => `tracker:${kind}:${project}`;
const TRACKER_SCOPE_RE = /^tracker:(linear|jira|board):[a-z0-9._@-]{1,64}$/;

async function readJson(res) {
  let body = null;
  try { body = JSON.parse(await res.text()); } catch { body = null; }
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    throw err;
  }
  if (!body || typeof body !== 'object') throw new Error('bad response');
  return body;
}

// The coord proxy calls. fetchImpl is injectable for the tests; publicKey()
// reads the hub key through the shared settings memo (lib/ai-accounts.js).
export function trackerClient(fetchImpl = (...a) => fetch(...a), settingsApi = api) {
  const post = (path, body, signal) => fetchImpl(path, {
    method: 'POST', credentials: 'same-origin', signal,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  }).then(readJson);
  return {
    publicKey: () => loadSheetConfig(settingsApi).then((c) => c.publicKey),
    postEnvelope: (body, signal) => post('/api/coord/secrets/envelope', body, signal),
    start: (project, kind, envelopeId, signal) => post('/api/coord/onboarding/tracker-test', { project, kind, envelope_id: envelopeId }, signal),
    result: (project, id, signal) => fetchImpl(
      `/api/coord/onboarding/tracker-test/${encodeURIComponent(id)}?${new URLSearchParams({ project })}`,
      { credentials: 'same-origin', signal }
    ).then(readJson)
  };
}

const why = (e) => (e && e.message ? e.message : String(e));

// sealTrackerFields: check the fields, read the hub key, seal {"fields":...},
// store the envelope. -> {envelope_id} | {error}. Each step that fails stops
// the later ones, so nothing is sent after a refusal.
export async function sealTrackerFields({ client, seal = sealSecret, project, kind, fields, signal }) {
  const c = checkTrackerFields(kind, fields);
  if (c.error) return { error: c.error };
  const scope = trackerScope(kind, project);
  if (!TRACKER_SCOPE_RE.test(scope) || scope.includes('..')) return { error: 'the project name must be lower-case letters, digits and . _ @ -' };
  let key;
  try { key = await client.publicKey(); } catch (e) { return { error: `not sent: the hub key could not be read (${why(e)})` }; }
  if (!key) return { error: 'The hub key is not set yet, so nothing was sent.' };
  let ciphertext;
  try { ciphertext = await seal(key, JSON.stringify({ fields: c.fields })); } catch (e) { return { error: `not sent: the credential could not be sealed (${why(e)})` }; }
  let stored;
  try { stored = await client.postEnvelope({ scope, ciphertext }, signal); } catch (e) { return { error: `not sent: the envelope store refused it (${why(e)})` }; }
  if (!stored || typeof stored.id !== 'string') return { error: 'not sent: the envelope store gave no id' };
  return { envelope_id: stored.id };
}

const wait = (ms, signal) => new Promise((resolve) => {
  const id = setTimeout(resolve, ms);
  if (signal) signal.addEventListener('abort', () => { clearTimeout(id); resolve(); }, { once: true });
});

// One test: seal and store the envelope, POST the start once, then poll
// while the hub has not answered. Resolves {state: 'ok', test_id, detail} |
// {state: 'error', test_id?, error} | {state: 'aborted'}. Never throws: a
// refused seal or start is an error with its text.
export async function runTrackerTest({
  client, seal = sealSecret, project, kind, fields, signal, onPending,
  pollMs = POLL_MS, maxWaitMs = MAX_WAIT_MS, sleep = wait, now = () => Date.now()
}) {
  const sealed = await sealTrackerFields({ client, seal, project, kind, fields, signal });
  if (signal && signal.aborted) return { state: 'aborted' };
  if (sealed.error) return { state: 'error', error: sealed.error };
  let started;
  try {
    started = await client.start(project, kind, sealed.envelope_id, signal);
  } catch (e) {
    if (signal && signal.aborted) return { state: 'aborted' };
    return { state: 'error', error: e && e.message ? e.message : 'the test could not start' };
  }
  const id = started && started.test_id;
  if (!id) return { state: 'error', error: 'the worker answered no test id' };
  const t0 = now();
  for (;;) {
    if (signal && signal.aborted) return { state: 'aborted' };
    let r;
    try {
      r = await client.result(project, id, signal);
    } catch (e) {
      if (signal && signal.aborted) return { state: 'aborted' };
      r = { state: 'pending', note: e && e.message ? e.message : null };
    }
    if (r.state === 'ok') return { state: 'ok', test_id: id, detail: r.detail || '' };
    if (r.state === 'error') return { state: 'error', test_id: id, error: r.error || 'the test failed' };
    if (onPending) onPending(r);
    if (now() - t0 >= maxWaitMs) {
      return { state: 'error', test_id: id, error: `no answer from the hub after ${Math.round(maxWaitMs / 60000)} minutes; test again` };
    }
    await sleep(pollMs, signal);
    if (signal && signal.aborted) return { state: 'aborted' };
  }
}

// The sheet's keydown handler: Escape is Later, Tab stays inside the sheet.
// box() answers the sheet element; doc is the document (injectable for tests).
export function sheetKeyHandler(onLater, box, doc = globalThis.document) {
  return (e) => {
    if (e.key === 'Escape') { e.preventDefault(); onLater(); return; }
    if (e.key !== 'Tab') return;
    const el = box();
    if (!el) return;
    const focusable = el.querySelectorAll('button:not([disabled]), input, select, textarea');
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (e.shiftKey && doc.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && doc.activeElement === last) { e.preventDefault(); first.focus(); }
  };
}

// The pure half of the tracker connect sheets (BH-7936, src/ui/TrackerSheets.js):
// the fields of each sheet, the Jira status map defaults, the blank-field
// check, the coord client and the test run (one POST, then a poll).
//
// The worker checks the same fields again (worker/jobs/src/routes/
// onboarding-tracker.js KIND_FIELDS): this table only decides what the sheet
// shows and when Test and connect is enabled.

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

// The fields the route takes: trimmed, and for Jira the status map string.
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

// The coord proxy calls. fetchImpl is injectable for the tests.
export function trackerClient(fetchImpl = (...a) => fetch(...a)) {
  return {
    start: (project, kind, fields, signal) => fetchImpl('/api/coord/onboarding/tracker-test', {
      method: 'POST', credentials: 'same-origin', signal,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ project, kind, fields })
    }).then(readJson),
    result: (project, id, signal) => fetchImpl(
      `/api/coord/onboarding/tracker-test/${encodeURIComponent(id)}?${new URLSearchParams({ project })}`,
      { credentials: 'same-origin', signal }
    ).then(readJson)
  };
}

const wait = (ms, signal) => new Promise((resolve) => {
  const id = setTimeout(resolve, ms);
  if (signal) signal.addEventListener('abort', () => { clearTimeout(id); resolve(); }, { once: true });
});

// One test: POST once, then poll while the hub has not answered. Resolves
// {state: 'ok', test_id, detail} | {state: 'error', test_id?, error} |
// {state: 'aborted'}. Never throws: a refused start is an error with its text.
export async function runTrackerTest({
  client, project, kind, fields, signal, onPending,
  pollMs = POLL_MS, maxWaitMs = MAX_WAIT_MS, sleep = wait, now = () => Date.now()
}) {
  let started;
  try {
    started = await client.start(project, kind, fields, signal);
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

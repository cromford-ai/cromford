// The signal-keys calls of the project Signals page and the Fleet SIGNALS
// column (BH-9839). The jobs worker serves /api/signal-keys* (BH-9800 C0);
// the console reaches it through the coord proxy: the GET passthrough for the
// list, and the coord-writes.d/9839-signal-keys.js rows for set, clear, test.
// api.js stays untouched, so this file carries its own fetch (the
// lane-runs-api.js shape).
//
// Errors:
//   403 {error: <the signal-keys owner text>}  Error with .refused = true. A
//       signed-in user with no owner proof; the page shows it in place.
//   any other 403, or a 404 {error:"unauthorized"}  AuthError (sign in again).
//   any other non-2xx  Error with .status, .body and the worker's `error`.

import { AuthError } from '../api.js';

const OWNER_REFUSAL = 'signal-keys needs the operator token or the owner proof';

async function call(method, path, body) {
  let res;
  try {
    res = await fetch(path, {
      method,
      credentials: 'same-origin',
      ...(body === undefined ? {} : { headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
    });
  } catch {
    throw new Error('network unreachable');
  }
  let parsed = null;
  const text = await res.text();
  if (text) {
    try { parsed = JSON.parse(text); } catch { parsed = null; }
  }
  if (res.status === 403 && parsed && parsed.error === OWNER_REFUSAL) {
    const err = new Error(OWNER_REFUSAL);
    err.refused = true;
    err.status = 403;
    err.body = parsed;
    throw err;
  }
  if (res.status === 403 || (res.status === 404 && parsed && parsed.error === 'unauthorized')) throw new AuthError();
  if (!res.ok) {
    const err = new Error(parsed && parsed.error ? String(parsed.error) : `http_${res.status}`);
    err.status = res.status;
    err.body = parsed;
    throw err;
  }
  if (parsed === null) throw new Error('bad response');
  return parsed;
}

// {kinds, rows, more, rotate_days, as_of}; one project, or every project.
export const signalKeysList = (project) =>
  call('GET', `/api/coord/signal-keys${project ? `?project=${encodeURIComponent(project)}` : ''}`);
// {project, kind, fields} -> {stored: true, …}
export const signalKeySet = (body) => call('POST', '/api/coord/signal-keys/set', body);
// {project, kind} -> {cleared: true, …}
export const signalKeyClear = (body) => call('POST', '/api/coord/signal-keys/clear', body);
// {project, kind} -> {ok, result, status, reason, tested_at}
export const signalKeyTest = (body) => call('POST', '/api/coord/signal-keys/test', body);

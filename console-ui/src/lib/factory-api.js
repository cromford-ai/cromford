// BH-4588: the one read of the FACTORY screen. The jobs worker serves
// /api/archie/factory-report, reached through the coord GET passthrough
// (/api/coord/<rest> -> /api/<rest>). The auth rule is the one in
// unblock-api.js: a 403, or a 404 whose body says unauthorized, is an
// AuthError (useApi turns that into the sign-in screen); any other non-2xx is
// an Error carrying the worker's `error` and the status. A 503 whose error
// says "schema not applied" (d1Guarded, before the archie tables exist) is the
// "report not live yet" state, marked `notLive`.

import { AuthError } from '../api.js';

const NOT_APPLIED_RE = /schema not applied$/;

async function get(path) {
  let res;
  try {
    res = await fetch(path, { credentials: 'same-origin' });
  } catch (e) {
    throw new Error('network unreachable');
  }
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  if (res.status === 403 || (res.status === 404 && body && body.error === 'unauthorized')) {
    throw new AuthError();
  }
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    err.body = body;
    err.notLive = res.status === 503 && !!body && NOT_APPLIED_RE.test(String(body.error || ''));
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

// True for the 503 the worker answers before the archie tables exist.
export const isNotLive = (e) => !!(e && e.notLive === true);

// day is YYYY-MM-DD (UTC).
export const factoryReport = (day) =>
  get(`/api/coord/archie/factory-report?day=${encodeURIComponent(day)}`);

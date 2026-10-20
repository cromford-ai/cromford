// BH-7728 (UNB-6): the two Tackler ledger reads. The jobs worker serves
// /api/unblock/metrics*, reached through the coord GET passthrough
// (/api/coord/<rest> -> /api/<rest>). api.js stays untouched, so this file
// carries its own GET with the same auth rule as lane-runs-api.js: a 403, or a
// 404 whose body says unauthorized, is an AuthError (useApi turns that into the
// sign-in screen); any other non-2xx is an Error carrying the worker's `error`
// and the status. A 503 whose error is SCHEMA_NOT_APPLIED is the "ledger not
// live yet" state (the UNB-0 table is not applied), marked `notLive`.

import { AuthError } from '../api.js';

export const SCHEMA_NOT_APPLIED = 'unblock_decisions schema not applied';
export const UNBLOCK_DAYS = 7;

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
    err.notLive = res.status === 503 && !!body && body.error === SCHEMA_NOT_APPLIED;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

// True for the 503 the worker answers before the unblock_decisions table exists.
export const isNotLive = (e) => !!(e && e.notLive === true);

function query(params) {
  const parts = Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${k}=${encodeURIComponent(v)}`);
  return parts.length ? `?${parts.join('&')}` : '';
}

export const unblockMetrics = (project, days = UNBLOCK_DAYS) =>
  get(`/api/coord/unblock/metrics${query({ project, days })}`);

export const unblockDecisions = (project, beforeId) =>
  get(`/api/coord/unblock/metrics/decisions${query({ project, before_id: beforeId })}`);

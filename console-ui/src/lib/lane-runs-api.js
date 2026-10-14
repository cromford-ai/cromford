// BH-6127: the three lane-runs reads. The jobs worker serves /api/lane-runs*,
// reached through the coord GET passthrough (/api/coord/<rest> -> /api/<rest>).
// api.js stays untouched, so this file carries its own GET with the same auth
// rule: a 403, or a 404 whose body says unauthorized, is an AuthError (useApi
// turns that into the sign-in screen); any other non-2xx is an Error carrying
// the worker's `error` and the status, so a 404 run reads as "not found".

import { AuthError } from '../api.js';

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
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

// `?a=1&b=2` from the params that have a value; '' when none do.
function query(params) {
  const parts = Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${k}=${encodeURIComponent(v)}`);
  return parts.length ? `?${parts.join('&')}` : '';
}

export const laneRunMetrics = (hours) => get(`/api/coord/lane-runs/metrics${query({ hours })}`);

export const laneRunList = ({ lane, machine, status } = {}) =>
  get(`/api/coord/lane-runs${query({ lane, machine, status })}`);

export const laneRun = (id) => get(`/api/coord/lane-runs/${encodeURIComponent(id)}`);

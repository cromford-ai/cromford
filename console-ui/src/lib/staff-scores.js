// BH-9422 (BH-9187.4, C4): the staff lever scorecards on Mission Control.
// The jobs worker serves GET /api/staff/levers/scoreboard (every staff agent,
// worker/jobs/src/routes/staff-scoreboard.js) and /api/staff/levers/scorecard
// (one agent, staff-levers.js), reached through the coord GET passthrough
// (/api/coord/<rest> -> /api/<rest>). api.js stays untouched (a hotspot), so
// this file carries its own GET with the lane-runs-api.js auth rule: a 403, or
// a 404 whose body says unauthorized, is an AuthError; any other non-2xx is an
// Error carrying the worker's `error` and the status.
//
// The pure half: scoreRows (null on a body with no agents array: a failed
// read, never an empty list), fmtValue (`no sample` for a missing sample,
// never 0), precisionText (`n/a` when 0 actions settled, never 0%) and
// metricAgentOf (Archie is not a staff agent: the scorecard answers 404).

import { AuthError } from '../api.js';
import { ARCHIE } from './staff.js';

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

export const fetchScoreboard = () => get('/api/coord/staff/levers/scoreboard');
export const fetchScorecard = (agent) => get(`/api/coord/staff/levers/scorecard?agent=${encodeURIComponent(agent)}`);

const valueOf = (s) => (s && typeof s === 'object' ? s.value : s);
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

// { days, rows } from a scoreboard body; null when the body has no agents list.
// Each row is the agent's scorecard plus `now` and `then` (the sample values,
// null when no sample) so the table sorts on numbers.
export function scoreRows(res) {
  if (!res || typeof res !== 'object' || !Array.isArray(res.agents)) return null;
  const rows = res.agents
    .filter((a) => a && typeof a.agent === 'string')
    .map((a) => ({ ...a, now: num(valueOf(a.metric_now)), then: num(valueOf(a.metric_then)) }));
  return { days: num(res.days), rows };
}

// A sample ({value, sampled_at}) or a bare number: at most 2 decimals; a
// missing sample is `no sample`, never 0.
export function fmtValue(sample) {
  const v = num(valueOf(sample));
  if (v === null) return 'no sample';
  return String(Math.round(v * 100) / 100);
}

// moved / settled as a whole percent; null (0 settled) is `n/a`, never 0%.
export function precisionText(p) {
  const v = num(p);
  return v === null ? 'n/a' : `${Math.round(v * 100)}%`;
}

// The agent whose METRIC section the detail page shows: trimmed and
// lowercased; null for Archie (not a staff agent) and for no name.
export function metricAgentOf(agent) {
  const a = String(agent === undefined || agent === null ? '' : agent).trim().toLowerCase();
  return a === '' || a === ARCHIE ? null : a;
}

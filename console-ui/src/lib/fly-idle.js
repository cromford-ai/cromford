// The FLY IDLE panel of /machines, the pure half. Body shape from
// GET /api/fly-idle (worker/jobs/src/routes/fly-idle.js):
// { pass: null | { pass_at, apps_total, apps_failed, partial, box },
//   machines: [{ app, machine_id, size, source, idle_s, idle_state, threshold_s, usd_per_hour }],
//   over_count, stops: [{ stop_id, app, machine_id, size, idle_s, usd_per_hour, status, stopped_at, ... }],
//   stops_24h, saved_usd_per_hour_24h }.
// machines is the last reaper pass's snapshot of STARTED machines. A stop row
// is a stop the reaper requested (flyctl rc 0), not a stop it observed.
import { clockTime, fmtDuration } from './format.js';

const APP_RE = /^[a-z0-9-]{1,63}$/;
const MACHINE_RE = /^[0-9a-f]{6,32}$/;
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

// Links only for names the worker would have accepted; anything else is text.
export const flyAppHref = (app) => (APP_RE.test(String(app || '')) ? `https://fly.io/apps/${app}` : null);
export const flyMachineHref = (app, id) => (flyAppHref(app) && MACHINE_RE.test(String(id || ''))
  ? `https://fly.io/apps/${app}/machines/${id}` : null);

// An unknown idle time is `—`, never 0: a read failure is never idle.
export function fmtIdle(idleS, state) {
  if (state === 'unknown' || !isNum(idleS)) return '—';
  return fmtDuration(idleS);
}

const usdLabel = (v) => (isNum(v) ? `$${v.toFixed(3)}` : 'unpriced');

export function flyIdleRows(body) {
  const machines = body && Array.isArray(body.machines) ? body.machines : [];
  return machines.map((m) => {
    const unknown = m.idle_state === 'unknown' || !isNum(m.idle_s);
    return {
      key: `${m.app}/${m.machine_id}`,
      app: m.app,
      machine_id: m.machine_id,
      source: m.source || '—',
      state: m.idle_state,
      idle_s: unknown ? null : m.idle_s,
      idle: fmtIdle(m.idle_s, m.idle_state),
      threshold_s: isNum(m.threshold_s) ? m.threshold_s : null,
      limit: isNum(m.threshold_s) ? fmtDuration(m.threshold_s) : '—',
      usd_per_hour: isNum(m.usd_per_hour) ? m.usd_per_hour : null,
      usd: usdLabel(m.usd_per_hour),
      href: flyMachineHref(m.app, m.machine_id),
      appHref: flyAppHref(m.app),
    };
  });
}

// Only the rows the GET returned. saved is their sum; an unpriced row adds
// nothing and is counted apart, so the sum never claims a price it lacks.
export function flyIdleStops(body) {
  const stops = body && Array.isArray(body.stops) ? body.stops : [];
  const rows = stops.map((s) => ({
    key: s.stop_id || `${s.app}/${s.machine_id}/${s.stopped_at}`,
    stopped_at: s.stopped_at,
    time: clockTime(s.stopped_at),
    app: s.app,
    machine_id: s.machine_id,
    size: s.size || '—',
    idle_s: isNum(s.idle_s) ? s.idle_s : null,
    idle: fmtIdle(s.idle_s, null),
    usd_per_hour: isNum(s.usd_per_hour) ? s.usd_per_hour : null,
    usd: usdLabel(s.usd_per_hour),
    href: flyMachineHref(s.app, s.machine_id),
    appHref: flyAppHref(s.app),
  }));
  const priced = rows.filter((r) => r.usd_per_hour !== null);
  const total = isNum(body && body.stops_24h) ? body.stops_24h : rows.length;
  return {
    rows,
    saved_usd_per_hour_24h: priced.reduce((n, r) => n + r.usd_per_hour, 0),
    unpriced: rows.length - priced.length,
    total,
    truncated: total > rows.length,
  };
}

export function flyIdleHeadline(body) {
  const pass = body && body.pass;
  if (!pass) return 'no reaper pass yet';
  const started = body && Array.isArray(body.machines) ? body.machines.length : 0;
  const over = isNum(body.over_count) ? body.over_count : 0;
  const failed = isNum(pass.apps_failed) ? pass.apps_failed : 0;
  const partial = Number(pass.partial) > 0 || failed > 0;
  return `${started} started · ${over} over the idle limit · as of ${clockTime(pass.pass_at)}`
    + (partial ? ` (partial: ${failed} app${failed === 1 ? '' : 's'} not read)` : '');
}

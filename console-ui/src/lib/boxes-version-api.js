// BH-7191.4: the harness version facts behind the /machines SHA, LAG, LAST
// SYNC and LAST BEAT columns. Four reads through the coord GET passthrough
// (/api/coord/<rest> -> /api/<rest>), started together, joined by box name
// here on the client. api.js stays untouched, so this file carries its own GET
// (the lane-runs-api.js shape). Each read has its own catch: one failed feed
// marks only that feed not ok, so its cells say `unavailable` and the rest of
// the screen keeps its data. A side read never sends the screen to sign-in.

import { api } from '../api.js';
import { agoFromMinutes, minutesSince } from './format.js';

// A stored lag is fresh for two ticks of the */10 fleet-version-check cron.
// An older number is not `current`, it is `unchecked`.
export const LAG_FRESH_MIN = 20;
// The code fallback for the settings row harness_version.max_lag_min, the
// same 30 the lane uses, so the console and the alert agree.
export const LAG_MAX_FALLBACK = 30;
const MAX_LAG_KEY = 'harness_version.max_lag_min';

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
  if (!res.ok) {
    const err = new Error(body && body.error ? body.error : `http_${res.status}`);
    err.status = res.status;
    throw err;
  }
  if (body === null) throw new Error('bad response');
  return body;
}

const listOf = (v) => (Array.isArray(v) ? v : []);

function maxLagFrom(payload) {
  const row = listOf(payload && payload.settings).find((r) => r && r.key === MAX_LAG_KEY);
  const v = row ? String(row.value ?? '').trim() : '';
  return /^\d+$/.test(v) ? Number(v) : LAG_MAX_FALLBACK;
}

// -> { status: {byName, ok}, registry: {boxes, ok}, fly: {byMachine, ok}, maxLagMin }.
// Never rejects.
export async function readBoxesVersion() {
  const [status, registry, fly, maxLagMin] = await Promise.all([
    get('/api/coord/boxes').then((p) => {
      const byName = {};
      for (const r of listOf(p.boxes)) if (r && r.box) byName[r.box] = r;
      return { byName, ok: true };
    }).catch(() => ({ byName: {}, ok: false })),
    get('/api/coord/registry').then((p) => ({ boxes: listOf(p.boxes), ok: true }))
      .catch(() => ({ boxes: [], ok: false })),
    get('/api/coord/lane-fleet/machines').then((p) => {
      const byMachine = {};
      for (const m of listOf(p.machines)) if (m && m.machine_id) byMachine[m.machine_id] = m;
      return { byMachine, ok: true };
    }).catch(() => ({ byMachine: {}, ok: false })),
    api.settings().then(maxLagFrom).catch(() => LAG_MAX_FALLBACK)
  ]);
  return { status, registry, fly, maxLagMin };
}

// The first 8 characters, or '-'.
export const shortSha = (s) => (s ? String(s).slice(0, 8) : '-');

// The LAG cell: { text, tone, sort }. `current` only for a stored 0 checked
// under LAG_FRESH_MIN ago; tone 'warn' (amber) over maxLagMin.
export function lagView(row, { ok, now, maxLagMin }) {
  if (!ok) return { text: 'unavailable', tone: null, sort: null };
  const unchecked = { text: 'unchecked', tone: null, sort: null };
  if (!row || !row.lag_checked_at) return unchecked;
  const at = Date.parse(row.lag_checked_at);
  if (Number.isNaN(at) || now - at >= LAG_FRESH_MIN * 60000) return unchecked;
  const n = row.harness_lag_min;
  if (n === null || n === undefined || n === '' || !Number.isInteger(Number(n)) || Number(n) < 0) return unchecked;
  const lag = Number(n);
  if (lag === 0) return { text: 'current', tone: null, sort: 0 };
  const max = Number.isFinite(maxLagMin) ? maxLagMin : LAG_MAX_FALLBACK;
  return { text: `${lag} min`, tone: lag > max ? 'warn' : null, sort: lag };
}

// A time cell: '2m', '3h', … or '-' for a field that is not there.
export const timeView = (iso) => (iso ? agoFromMinutes(minutesSince(iso)) : '-');

// The watchdog rows plus one row per registry box the watchdog has no record
// of. Each row gets its box_status row by exact name (null when none).
export function versionBoxRows(watchdogRows, data) {
  const byName = (data && data.status && data.status.byName) || {};
  const rows = watchdogRows.map((r) => ({ ...r, registryOnly: false, status: byName[r.name] || null }));
  if (!data || !data.registry) return rows;
  const seen = new Set(rows.map((r) => r.name));
  for (const b of data.registry.boxes) {
    const name = b && b.box;
    if (!name || seen.has(name)) continue;
    seen.add(name);
    rows.push({ name, ping: null, min: null, registryOnly: true, status: byName[name] || null });
  }
  return rows;
}

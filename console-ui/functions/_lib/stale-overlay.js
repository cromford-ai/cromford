// BH-10119 (item 5 of #10060) — `building_stale` on the kanban is the count of
// its detector, not the console worker's raw count.
//
// The console worker counts rows in a build stage past its freshness window.
// It does not subtract the live set, so a build that is still queued, claimed,
// on a machine or beating its job row reads as stale. The detector,
// bin/stale-build-reaper.sh, applies the full rule (stage planning|executing,
// quiet for STALE_REAPER_MINUTES, no queued/claimed queue row, no live machine,
// no fresh job row, no fresh build dir) and, after each complete tick, writes
// its dead count to harness-jobs ledgers(kind=building_stale, key=fleet):
//   status  the dead count, a decimal string
//   detail  JSON {stale, held, candidates, window_min, mode, at, valid_until}
//
// overlayStale puts that number on the payload while the row is valid. The
// validity window travels in the row (valid_until, from the reaper's knob
// STALE_REAPER_COUNT_TTL_MIN), so this file holds no window of its own. Any
// doubt keeps the console's number and says why (`building_stale_reason`):
// FAIL OPEN, the same rule as the other ledger joins in pipeline.js.

const JOBS = 'https://harness-jobs.operator.workers.dev';
export const STALE_LEDGER_KIND = 'building_stale';
export const STALE_LEDGER_KEY = 'fleet';

// One ledger read per isolate per minute, the CLOSED_TTL_MS style of
// pipeline.js. Only a 200 or a 404 is cached; a failure is retried next request.
let staleCache = null;
const STALE_TTL_MS = 60000;
export function _resetStaleCache() { staleCache = null; }

// {row} on a 200 with {ledger}, {row: null} on a 404 (no row yet: a real
// answer), null on no secret, any other status, a bad body or a throw.
export async function fetchStaleCount(env) {
  if (!env || !env.HARNESS_SECRET) return null;
  const now = Date.now();
  if (staleCache && now - staleCache.at < STALE_TTL_MS) return staleCache.value;
  let value;
  try {
    const res = await fetch(`${JOBS}/api/ledger?kind=${STALE_LEDGER_KIND}&key=${STALE_LEDGER_KEY}`,
      { headers: { authorization: `Bearer ${env.HARNESS_SECRET}` } });
    if (res.status === 404) {
      value = { row: null };
    } else if (res.status === 200) {
      const body = await res.json();
      if (!body || typeof body.ledger !== 'object' || body.ledger === null) return null;
      value = { row: body.ledger };
    } else {
      return null;
    }
  } catch {
    return null;
  }
  staleCache = { at: now, value };
  return value;
}

// Why a row cannot be used, or null when it can. Pure.
function rowProblem(row) {
  if (typeof row.status !== 'string' || !/^\d+$/.test(row.status)) return 'bad-row';
  let d;
  try { d = JSON.parse(row.detail); } catch { return 'bad-row'; }
  if (!d || typeof d !== 'object' || typeof d.valid_until !== 'string') return 'bad-row';
  if (!Number.isFinite(Date.parse(d.valid_until))) return 'bad-row';
  return null;
}

// Pure. The answer of fetchStaleCount -> the payload with building_stale set
// from the reaper's row while it is valid (valid_until >= now, inclusive).
// Otherwise the console's number stays, with building_stale_source 'console'
// and a reason: unreadable | no-row | bad-row | expired. Columns and counts do
// not change. A payload that is not an object comes back as it is.
export function overlayStale(payload, answer, { now = Date.now() } = {}) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return payload;
  const keep = (reason) => ({ ...payload, building_stale_source: 'console', building_stale_reason: reason });
  if (!answer || typeof answer !== 'object') return keep('unreadable');
  const row = answer.row;
  if (!row || typeof row !== 'object') return keep('no-row');
  const problem = rowProblem(row);
  if (problem) return keep(problem);
  if (now > Date.parse(JSON.parse(row.detail).valid_until)) return keep('expired');
  return {
    ...payload,
    building_stale: Number(row.status),
    building_stale_source: 'reaper',
    building_stale_at: row.updated_at ?? null,
    building_stale_console: payload.building_stale ?? null
  };
}

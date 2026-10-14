// BH-5750: the Orgo side of the ORGO BOXES rows — which Orgo box id a row
// is, what GET /api/coord/orgo-computers says about it, and whether a Fly
// project is on the builder pool. Absent stays absent: a row with no record
// is `unknown`, a route that is not deployed is `not available`, and a read
// older than STALE_MIN is shown as stale, never as current.

// A read older than this many minutes is stale (T4.4).
export const STALE_MIN = 15;

const BOX_ID_RE = /^[a-z][a-z0-9]{0,31}$/;

// The Orgo box id per watchdog row name, or null when it cannot be named.
// The rule is bin/lib/cron-lines.sh cron_box_id_for's: drop the fleet's name
// prefix, then a trailing -N. The console has no copy of that prefix, so it
// is the dash segments every non-hub row shares (none with fewer than two
// rows). `hub` is the hub. What is left must be a box id; an all-number rest
// (the hub's own fleet name, e.g. <prefix>-1) is not one, so it gets null.
export function orgoBoxIds(names) {
  const others = names.filter((n) => n !== 'hub').map((n) => String(n).split('-'));
  let prefix = 0;
  if (others.length >= 2) {
    const min = Math.min(...others.map((s) => s.length));
    while (prefix < min - 1 && others.every((s) => s[prefix] === others[0][prefix])) prefix += 1;
  }
  const out = {};
  for (const name of names) {
    if (name === 'hub') { out[name] = 'hub'; continue; }
    const segs = String(name).split('-').slice(prefix);
    if (segs.length > 1 && /^\d{1,2}$/.test(segs[segs.length - 1])) segs.pop();
    const id = segs.join('-');
    out[name] = BOX_ID_RE.test(id) ? id : null;
  }
  return out;
}

// GET /api/coord/orgo-computers -> { byName, accounts, asOf }. Throws on an
// unreadable payload so the screen shows a read failure, not "unknown".
export function shapeOrgoComputers(payload) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.computers)) {
    throw new Error('orgo computers: unreadable payload');
  }
  const byName = {};
  for (const c of payload.computers) {
    if (!c || typeof c.name !== 'string') continue;
    (byName[c.name] = byName[c.name] || []).push(c);
  }
  const accounts = payload.accounts && typeof payload.accounts === 'object' ? payload.accounts : {};
  return { byName, accounts, asOf: payload.as_of || null, truncated: payload.truncated === true };
}

const minutesSince = (iso, now) => {
  const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? Math.max(0, Math.floor((now - t) / 60000)) : null;
};

// One row's Orgo state. `orgo` is shapeOrgoComputers' output, or
// { unavailable, reason } (route not deployed), { error } (read failed), or
// null (still loading). -> { state, text, tone, stale, ageMin, computer }
export function orgoStateFor(name, orgo, now = Date.now()) {
  const none = (state, tone = '') => ({ state, text: state, tone, stale: false, ageMin: null, computer: null });
  if (orgo === null || orgo === undefined) return none('loading');
  if (orgo.unavailable) return none('not available', 'warn');
  if (orgo.error) return none('read failed', 'dead');
  const list = (orgo.byName && orgo.byName[name]) || [];
  const live = list.filter((c) => !c.gone_at);
  // A capped list cannot prove a box has no record (D12).
  if (!list.length) return none(orgo.truncated ? 'unknown (list truncated)' : 'unknown');
  if (!live.length) {
    const g = list[0];
    return { state: 'gone', text: `gone ${agoText(minutesSince(g.gone_at, now))}`.trim(), tone: 'dead', stale: false, ageMin: null, computer: null };
  }
  if (live.length > 1) return { ...none(`ambiguous (${live.length})`, 'warn') };
  const c = live[0];
  // seen_at is the last read that listed this computer. An account's read_at
  // moves on a FAILED read too, so it cannot say the record is current.
  const ageMin = minutesSince(c.seen_at, now);
  const stale = ageMin === null || ageMin > STALE_MIN;
  const state = typeof c.status === 'string' && c.status ? c.status : 'unknown';
  const text = stale ? `${state} · stale ${ageMin === null ? 'age unknown' : agoText(ageMin)}` : state;
  return { state, text, tone: stale ? 'warn' : state === 'running' ? 'green' : '', stale, ageMin, computer: c };
}

function agoText(min) {
  if (min === null) return '';
  if (min < 60) return `${min}m`;
  if (min < 48 * 60) return `${Math.floor(min / 60)}h`;
  return `${Math.floor(min / 1440)}d`;
}

// "4c/16gb/100gb", or null when the record carries no specs.
export function specsText(c) {
  if (!c || ![c.cpu, c.ram_gb, c.disk_gb].every((v) => Number.isFinite(v))) return null;
  return `${c.cpu}c/${c.ram_gb}gb/${c.disk_gb}gb`;
}

// The sort key for a SPECS cell: cpu, then ram, then disk, as numbers.
export function specsSortKey(c) {
  return specsText(c) === null ? null : c.cpu * 1e8 + c.ram_gb * 1e4 + c.disk_gb;
}

// The account names the Orgo read knows, for the account select.
export function orgoAccounts(orgo) {
  return orgo && orgo.accounts ? Object.keys(orgo.accounts).sort() : [];
}

// Whether a Fly project is on the builder pool. The machines payload carries
// no pool flag, so this reads the block: a pool app (fly-onboard.sh makes
// pool-<p>; <p>-pool is the older name) or a machine with role pool.
export function flyOnPool(project, block) {
  if (!block) return false;
  const apps = Array.isArray(block.apps) ? block.apps : [];
  if (apps.includes(`pool-${project}`) || apps.includes(`${project}-pool`)) return true;
  return Array.isArray(block.machines) && block.machines.some((m) => m && m.role === 'pool');
}

// A whole number above 0 from a typed string: the number, null when typed
// but invalid, undefined when blank. Never clamped (D11).
export function parsePositiveInt(s) {
  const t = typeof s === 'string' ? s.trim() : s === undefined || s === null ? '' : String(s);
  if (t === '') return undefined;
  return /^[1-9]\d*$/.test(t) ? Number(t) : null;
}

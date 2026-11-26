// The period of a report screen (BH-9304, BH-9120.0), pure. A period lives in
// the URL as ?from=&to=&bucket=&compare=, so it is shareable and survives a
// reload. Times are UTC, in the worker's stored form YYYY-MM-DDTHH:MM:SSZ,
// and `to` is exclusive. `to: null` means "open, until now": the worker reads
// a missing `to` as its own clock (worker/jobs/src/lib/period.js parseRange,
// which is the validator of record).

export const PRESETS = Object.freeze(['today', 'yesterday', 'last_7_days', 'last_30_days', 'this_month', 'last_month', 'custom']);
export const BUCKETS = Object.freeze(['auto', 'hour', 'day', 'week']);

// The code fallback of the settings row mc.period.default_preset.
export const PERIOD_UI_FALLBACKS = Object.freeze({ default_preset: 'last_7_days' });

const H = 3600000;
const DAY = 24 * H;
const VALUE_RE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?Z)?$/;
const PERIOD_KEYS = ['from', 'to', 'bucket', 'compare'];

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const valid = (v) => typeof v === 'string' && VALUE_RE.test(v);

// resolvePreset(name, nowMs) -> {from, to} or null (custom, unknown). Rolling
// presets start at 00:00Z and leave `to` open, so the URL is the same all day.
export function resolvePreset(name, nowMs) {
  const n = new Date(nowMs);
  const y = n.getUTCFullYear(), m = n.getUTCMonth();
  const d0 = Date.UTC(y, m, n.getUTCDate());
  switch (name) {
    case 'today': return { from: iso(d0), to: null };
    case 'yesterday': return { from: iso(d0 - DAY), to: iso(d0) };
    case 'last_7_days': return { from: iso(d0 - 6 * DAY), to: null };
    case 'last_30_days': return { from: iso(d0 - 29 * DAY), to: null };
    case 'this_month': return { from: iso(Date.UTC(y, m, 1)), to: null };
    case 'last_month': return { from: iso(Date.UTC(y, m - 1, 1)), to: iso(Date.UTC(y, m, 1)) };
    default: return null;
  }
}

// parsePeriodQuery(search) -> {from, to, bucket, compare}, or null when there
// is no valid `from`. A `to` that does not parse is dropped (open).
export function parsePeriodQuery(search) {
  const sp = new URLSearchParams(search || '');
  const from = sp.get('from');
  if (!valid(from)) return null;
  const to = sp.get('to');
  const bucket = sp.get('bucket');
  return {
    from,
    to: valid(to) ? to : null,
    bucket: BUCKETS.includes(bucket) ? bucket : 'auto',
    compare: sp.get('compare') === '1'
  };
}

// The preset whose range is exactly this period, else 'custom'.
export function activePreset(period, nowMs) {
  if (!period) return 'custom';
  for (const name of PRESETS) {
    const r = resolvePreset(name, nowMs);
    if (r && r.from === period.from && r.to === (period.to || null)) return name;
  }
  return 'custom';
}

// periodQuery(period, keepParams) -> a query string (no '?'): every param of
// keepParams except the period's own four, then from, to, bucket, compare.
export function periodQuery(period, keepParams) {
  const out = new URLSearchParams();
  const keep = keepParams instanceof URLSearchParams ? [...keepParams.entries()]
    : Object.entries(keepParams || {}).filter(([, v]) => v !== undefined && v !== null);
  for (const [k, v] of keep) if (!PERIOD_KEYS.includes(k)) out.append(k, String(v));
  const p = period || {};
  if (p.from) out.set('from', p.from);
  if (p.to) out.set('to', p.to);
  if (p.bucket && p.bucket !== 'auto' && BUCKETS.includes(p.bucket)) out.set('bucket', p.bucket);
  if (p.compare === true) out.set('compare', '1');
  return out.toString();
}

// Hour up to and including 48 h, day up to and including 90 days, week after.
export function pickBucket(rangeMs) {
  if (rangeMs <= 48 * H) return 'hour';
  if (rangeMs <= 90 * DAY) return 'day';
  return 'week';
}

// The period of the same length that ends where this one starts.
export function previousPeriod({ from, to }, nowMs = Date.now()) {
  const f = Date.parse(from);
  const t = to ? Date.parse(to) : nowMs;
  return { from: iso(f - (t - f)), to: iso(f) };
}

// The same query plus format=csv. `query.keep` holds the other params.
export function csvHref(path, query) {
  const qs = periodQuery(query, query && query.keep);
  return `${path}?${qs ? `${qs}&` : ''}format=csv`;
}

// A side-menu link that keeps the current period: `to` plus ?from=&to= from
// `search`, only those two and only when `from` is valid.
export function withPeriod(to, search) {
  const p = parsePeriodQuery(search);
  if (!p) return to;
  const qs = new URLSearchParams({ from: p.from, ...(p.to ? { to: p.to } : {}) }).toString();
  return `${to}${to.includes('?') ? '&' : '?'}${qs}`;
}

// The period of a screen with no from/to in its URL: the knob preset when it
// is a real preset, else PERIOD_UI_FALLBACKS.
export function defaultPeriod(knobs, nowMs) {
  const k = knobs && knobs.default_preset;
  const name = PRESETS.includes(k) && k !== 'custom' ? k : PERIOD_UI_FALLBACKS.default_preset;
  return { ...resolvePreset(name, nowMs), bucket: 'auto', compare: false };
}

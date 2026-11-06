// Rendering helpers whose whole job is to stay honest about what we do and do
// not know. Everything derived from the hub's beat is a snapshot, never live,
// and an age we never received says "never" rather than rendering as zero.

export function agoFromMinutes(min) {
  if (min === null || min === undefined || !Number.isFinite(Number(min))) return 'never';
  const m = Math.max(0, Math.floor(Number(min)));
  if (m === 0) return 'now';
  if (m < 60) return `${m}m`;
  if (m < 1440) return `${Math.floor(m / 60)}h`;
  return `${Math.floor(m / 1440)}d`;
}

export function snapshotLabel(ageMin) {
  if (ageMin === null || ageMin === undefined) return 'no snapshot yet';
  const a = agoFromMinutes(ageMin);
  return a === 'now' ? 'snapshot now' : `snapshot ${a} ago`;
}

// Age thresholds for the hub's own snapshot and for a box ping. Fleet ticks run
// on a few-minute cadence, so ten minutes of silence is already worth a colour.
export function healthFromAge(min) {
  if (min === null || min === undefined || !Number.isFinite(Number(min))) return 'unknown';
  const m = Number(min);
  if (m < 10) return 'ok';
  if (m < 30) return 'warn';
  return 'dead';
}

export function fmtBytes(n) {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return '—';
  const b = Number(n);
  if (b < 1024) return `${b}B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)}KB`;
  return `${(b / 1024 / 1024).toFixed(1)}MB`;
}

export function shortSha(sha) {
  if (!sha || typeof sha !== 'string') return '—';
  return sha.slice(0, 7);
}

export function minutesSince(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.round((Date.now() - t) / 60000));
}

export function clockTime(iso) {
  if (!iso) return '—';
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '—';
  return `${String(t.getUTCHours()).padStart(2, '0')}:${String(t.getUTCMinutes()).padStart(2, '0')}Z`;
}

// BH-9119: the one number formatter. A fixed en-US locale with grouping, so
// 12224.73 reads 12,224.73 whatever the browser's locale. Strict like isNum in
// lib/spend.js: only a finite number or a non-blank numeric string formats;
// null, '', a boolean or NaN reads '—', never 0. With no `decimals` the Intl
// default applies (up to 3 fraction digits, no padding). A rounded zero never
// shows a minus sign.
const isNum = (n) => {
  if (typeof n === 'number') return Number.isFinite(n);
  if (typeof n === 'string' && n.trim() !== '') return Number.isFinite(Number(n));
  return false;
};
const NUM_FORMATS = new Map();
const numFormat = (decimals) => {
  let f = NUM_FORMATS.get(decimals);
  if (!f) {
    const digits = decimals === undefined ? {} : { minimumFractionDigits: decimals, maximumFractionDigits: decimals };
    f = new Intl.NumberFormat('en-US', { useGrouping: true, signDisplay: 'negative', ...digits });
    NUM_FORMATS.set(decimals, f);
  }
  return f;
};
export function fmtNum(n, { decimals } = {}) {
  if (!isNum(n)) return '—';
  return numFormat(decimals).format(Number(n));
}

export function fmtUsd(n, { decimals = 2 } = {}) {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return '—';
  const v = Number(n);
  const text = fmtNum(Math.abs(v), { decimals });
  return `${v < 0 && /[1-9]/.test(text) ? '-' : ''}$${text}`;
}

export function fmtDuration(seconds) {
  if (seconds === null || seconds === undefined || !Number.isFinite(Number(seconds))) return '—';
  const s = Math.max(0, Math.round(Number(seconds)));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

// The PR number is parsed out of a `pr_url` that arrived in D1 from a beat, so
// it is untrusted input: only a github.com pull URL yields a number.
export function prNumberFromUrl(url) {
  if (!url || typeof url !== 'string') return null;
  const m = url.match(/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/(\d+)(?:[/?#].*)?$/);
  return m ? Number(m[1]) : null;
}

// The watchdog reports box liveness as prose ("2m ago", "never"), so the tile
// colour has to come back out of that string rather than from a number.
export function minutesFromPingText(text) {
  if (!text || typeof text !== 'string') return null;
  const t = text.trim().toLowerCase();
  if (t === 'never' || t === '') return null;
  const m = t.match(/^(\d+(?:\.\d+)?)\s*([smhd])/);
  if (!m) return null;
  const n = Number(m[1]);
  const unit = m[2];
  if (unit === 's') return 0;
  if (unit === 'm') return Math.round(n);
  if (unit === 'h') return Math.round(n * 60);
  return Math.round(n * 1440);
}

// A URL that reaches an href must be https. Check-run and PR URLs come from a
// GitHub response, but the same field is echoed through D1 rows written by a
// beat, so it is treated as untrusted: anything that is not https (javascript:,
// data:, //host) yields null and the link is rendered as inert text instead.
export function safeHttpsUrl(url) {
  if (!url || typeof url !== 'string') return null;
  try {
    // No base URL on purpose: with one, a protocol-relative "//evil.com/x"
    // would resolve to an arbitrary https host and pass the check. These are
    // always absolute URLs, so anything that is not parses as invalid.
    const u = new URL(url);
    return u.protocol === 'https:' ? u.href : null;
  } catch {
    return null;
  }
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// A clock time alone makes a row from four days ago look like one from an hour
// ago. Under a day we say how long ago; from a day on we print the date (UTC).
export function whenLabel(iso, nowMs = Date.now()) {
  if (iso === null || iso === undefined || iso === '') return 'never';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return 'unreadable';
  const diff = nowMs - t;
  if (diff < 60000) return 'just now'; // future stamps (clock skew) land here too
  const min = Math.floor(diff / 60000);
  if (min < 60) return `${min}m ago`;
  if (min < 1440) return `${Math.floor(min / 60)}h ago`;
  const d = new Date(t);
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()} ${hh}:${mm}Z`;
}

// "—" used to mean both "nothing measured" and 0. These are three different facts.
export function countOrNull(v, { uncapped = false } = {}) {
  if (v === null || v === undefined || v === '') return uncapped ? 'no cap' : 'no data';
  const n = Number(v);
  return Number.isFinite(n) ? fmtNum(n) : 'no data';
}

// Every $ in the console is either API-equivalent (list price x tokens, what the
// cost rows carry) or cash actually paid. Say which. Anything not asked for as
// cash is API-equivalent, because that is what every attributed figure is.
// `basis` is the machine key UsdCell writes to data-usd-basis; `label` is the words.
export const USD_BASIS_LABEL = Object.freeze({ api: 'API-eq', cash: 'cash' });
export function usdBasis(n, basis = 'api') {
  const b = basis === 'cash' ? 'cash' : 'api';
  const ok = n !== null && n !== undefined && n !== '' && Number.isFinite(Number(n));
  return { text: ok ? fmtUsd(n) : 'no data', basis: b, label: USD_BASIS_LABEL[b] };
}

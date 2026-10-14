// BH-6350: a project's dispatch mode, shaped from the GET /api/coord/flags
// rows. Two rows decide it, and paused wins:
//   paused-<p>         ON → paused (the BH-4153 row, read as pausedOf reads it)
//   dispatch-mode-<p>  ON → hotfix-only, unless its value is `normal`
//   neither            → normal
// The value grammar is the shell's (bin/lib/dispatch-mode.sh dm_parse): trim,
// compare case-insensitively; `normal`; `hotfix-only`; `hotfix-only:<n>,<n>`
// with whole numbers above 0. Anything else reads as hotfix-only with no
// allow-list and bad=true: an operator turned the row ON to restrict.

export const ALLOW_MAX = 40;
export const VALUE_MAX = 512;
export const ALLOW_ERROR = 'whole issue numbers, comma separated';

const LIST = /^hotfix-only:\s*([0-9]+(?:\s*,\s*[0-9]+)*)$/;

function on(row) {
  return Boolean(row) && Number(row.active) === 1 && row.active !== null && row.active !== '';
}

// Numbers in first-seen order, duplicates dropped; null when one is 0.
function numbers(parts) {
  const out = [];
  for (const s of parts) {
    const n = Number(s);
    if (!Number.isSafeInteger(n) || n < 1) return null;
    if (!out.includes(n)) out.push(n);
  }
  return out;
}

export function parseModeValue(v) {
  const t = typeof v === 'string' ? v.trim().toLowerCase() : '';
  if (t === '' || t === 'hotfix-only') return { mode: 'hotfix-only', allow: [], bad: false };
  if (t === 'normal') return { mode: 'normal', allow: [], bad: false };
  const m = LIST.exec(t);
  const allow = m ? numbers(m[1].split(',').map((s) => s.trim())) : null;
  return allow ? { mode: 'hotfix-only', allow, bad: false } : { mode: 'hotfix-only', allow: [], bad: true };
}

export function formatModeValue(allow) {
  return allow && allow.length ? `hotfix-only:${allow.join(',')}` : 'hotfix-only';
}

// { mode, allow, set_at, dispatch_on } for one project. set_at is the row
// that decided it. dispatch_on says the dispatch-mode-<p> row stands, which a
// paused project still may have: the SET dialog needs it to clear that row.
export function modeOf(byName, p) {
  const paused = byName.get(`paused-${p}`);
  const row = byName.get(`dispatch-mode-${p}`);
  const dispatchOn = on(row);
  if (on(paused)) return { mode: 'paused', allow: [], set_at: paused.set_at || null, dispatch_on: dispatchOn };
  if (!dispatchOn) return { mode: 'normal', allow: [], set_at: null, dispatch_on: false };
  const v = parseModeValue(row.value);
  return { mode: v.mode, allow: v.allow, set_at: row.set_at || null, dispatch_on: true };
}

const tokens = (text) => (typeof text === 'string' ? text.trim() : '').split(/[\s,]+/).filter(Boolean);

// The SET dialog's allow-list check. Empty is fine: hotfix-only with no list.
export function allowInputError(text) {
  const parts = tokens(text);
  if (!parts.length) return null;
  if (!parts.every((s) => /^[0-9]{1,15}$/.test(s)) || !numbers(parts)) return ALLOW_ERROR;
  const allow = numbers(parts);
  if (allow.length > ALLOW_MAX) return `at most ${ALLOW_MAX} issue numbers`;
  if (formatModeValue(allow).length > VALUE_MAX) return `the list is longer than ${VALUE_MAX} characters`;
  return null;
}

export function parseAllowInput(text) {
  return allowInputError(text) ? [] : (numbers(tokens(text)) || []);
}

export function modeText(cell) {
  if (!cell) return '—';
  if (cell.mode === 'hotfix-only' && cell.allow && cell.allow.length) return `hotfix-only (+${cell.allow.length} allowed)`;
  return cell.mode;
}

const RANK = { paused: 0, 'hotfix-only': 1, normal: 2 };

// Sort rank: the most restricted first; unknown and null last.
export function modeRank(mode) {
  return mode in RANK ? RANK[mode] : 3;
}

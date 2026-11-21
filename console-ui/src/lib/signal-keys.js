// The pure half of the project Signals page (BH-9839, slice C1 of BH-9800):
// the per-field checks the sheet runs on blur and on Save, the state of a card
// and of a Fleet pill, the set body, and the token mask. No DOM, no fetch.
//
// Every field definition comes from the server: GET /api/signal-keys answers
// `kinds[].fields[]` from the signal_key_kinds catalog ({name, label,
// placeholder, re, secret, prefixes}). The checks below are the same rules,
// with the same texts, as checkFields in worker/jobs/src/routes/signal-keys.js,
// so an error on blur reads exactly like the server's 400. The server stays
// the gate: it also checks the host allow list and the size cap.

// The line a refused write shows in place (a signed-in user with no owner proof).
export const OWNER_LINE = 'Only a fleet owner can change these keys.';

// Spaces, tabs and line breaks off both ends of a pasted key (the server's trim).
export const trimPaste = (v) => String(v ?? '').trim();

const prefixesOf = (def) => (def && def.secret && Array.isArray(def.prefixes) ? def.prefixes : []);

// `<Label> must start with <p1> or <p2>` for a secret field whose trimmed
// value has none of its prefixes, else null. A blank value is fieldError's case.
export function prefixError(def, value) {
  const v = trimPaste(value);
  const prefixes = prefixesOf(def);
  if (!v || !prefixes.length || prefixes.some((p) => v.startsWith(p))) return null;
  return `${def.label} must start with ${prefixes.join(' or ')}`;
}

// The first failing check of one field after the trim: required, prefix, then
// the field's format. null when the value passes.
export function fieldError(def, value) {
  const v = trimPaste(value);
  if (!v) return `${def.label} is required`;
  const p = prefixError(def, v);
  if (p) return p;
  let re = null;
  try { re = new RegExp(def.re); } catch { re = null; }
  if (!re || !re.test(v)) return `${def.label} does not match the format (${def.placeholder})`;
  return null;
}

// One card's state from its row: missing (no row), failing (a test result that
// is not ok), set (never tested, or tested ok).
export function cardState(kind, row) {
  if (!row) return { kind: kind.kind, state: 'missing', rotate: false };
  const r = row.last_test_result;
  const state = r !== null && r !== undefined && r !== 'ok' ? 'failing' : 'set';
  return { kind: kind.kind, state, rotate: row.rotate_overdue === true };
}

// One pill per catalog kind, in catalog order, for one project. A row of a
// kind the catalog does not hold is ignored; a missing catalog is no pills.
export function pillState(kinds, rows, project) {
  if (!Array.isArray(kinds)) return [];
  const mine = (Array.isArray(rows) ? rows : []).filter((r) => r && r.project === project);
  return kinds.map((k) => ({ ...cardState(k, mine.find((r) => r.kind === k.kind) || null), label: k.label }));
}

// The Fleet sort value: how many kinds are not set (missing or failing).
export const notSetCount = (pills) => pills.filter((p) => p.state !== 'set').length;

// The POST signal-keys/set body: every field of the kind, trimmed, in the
// catalog's order. The server requires every field, the secret included.
export function sendBody(project, kind, defs, values) {
  const fields = {};
  for (const d of defs || []) fields[d.name] = trimPaste((values || {})[d.name]);
  return { project, kind, fields };
}

// The worker's mask (worker/jobs/src/lib/token-mask.js): a Sentry token
// (sntry<letter>_…) or a PostHog key (ph<letter>_…) becomes its prefix and ***.
const TOKEN_RE = /\b(sntry[a-z]_|ph[a-z]_)[A-Za-z0-9_=+/.-]+/g;
export const maskTokens = (s) => String(s ?? '').replace(TOKEN_RE, '$1***');
export const isTokenShaped = (s) => typeof s === 'string' && maskTokens(s) !== s;

// An ISO time as `YYYY-MM-DD HH:MMZ`, or '—'.
export function shortTime(iso) {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(String(iso || ''));
  return m ? `${m[1]} ${m[2]}Z` : '—';
}

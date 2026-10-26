// BH-2379 (BH-2330.4): the /config/:kind/:name page's pure half.

// The console's copy of CONFIG_KINDS in worker/jobs/src/lib/config-changes.js,
// in the same order. config-detail-render.bh-2330.test.js pins the two equal.
export const CONFIG_KIND_VALUES = Object.freeze([
  'review_gate_threshold', 'concurrency_rule', 'retry_policy', 'phase_contract',
  'cost_cap', 'telegram_topic', 'registry_seed', 'setting', 'flag', 'merge_queue',
  'held_page', 'project', 'project_secret'
]);
export const isKnownKind = (kind) => CONFIG_KIND_VALUES.includes(kind);

// The history read size; the worker clamps it to its own MAX_CHANGES (500).
export const DETAIL_LIMIT = 500;
// GET /api/flags answers at most this many rows (worker/jobs/src/routes/flags.js).
export const FLAG_LIST_CAP = 500;

// A body without a changes array is a failed read, never "no changes".
export function historyRows(res) {
  if (!res || !Array.isArray(res.changes)) return { malformed: true };
  return { rows: res.changes, truncated: res.truncated === true };
}

const fieldText = (v) => (v === null || v === undefined ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));

// One side of a change. before_json NULL is a create and after_json 'null' a
// delete (configChangeStmts). One audited field shows its value; several show
// `field: value` joined by ' · '. Text that does not parse is shown as it is.
export function sideText(json, side) {
  if (side === 'before' && json == null) return '(created)';
  if (side === 'after' && json === 'null') return '(deleted)';
  if (json == null) return '—';
  let v;
  try { v = JSON.parse(json); } catch { return String(json); }
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return fieldText(v);
  const keys = Object.keys(v);
  if (keys.length === 0) return '—';
  if (keys.length === 1) return fieldText(v[keys[0]]);
  return keys.map((k) => `${k}: ${fieldText(v[k])}`).join(' · ');
}

// The current row for the kinds that have a reader: {row}, {missing} (with
// `capped` when the flag list was full, so absent does not mean gone),
// {malformed} for a body of the wrong shape, {none} for every other kind.
export function currentFor(kind, name, res) {
  if (kind === 'setting') {
    if (!res || typeof res !== 'object' || !('setting' in res)) return { malformed: true };
    const s = res.setting;
    if (!s) return { missing: true };
    return { row: { value: s.value, actor: s.actor, at: s.updated_at, note: s.note } };
  }
  if (kind === 'flag') {
    if (!res || !Array.isArray(res.flags)) return { malformed: true };
    const f = res.flags.find((x) => x && x.name === name);
    if (!f) return { missing: true, capped: res.flags.length >= FLAG_LIST_CAP };
    return { row: { value: Number(f.active) === 1 ? 'active' : 'inactive', actor: f.actor, at: f.updated_at, note: f.reason } };
  }
  return { none: true };
}

// BH-2513: the config_changes audit trail (schema.sql), the same idea as
// routing_changes. configChangeStmts BUILDS the audit INSERT and runs nothing:
// the caller calls ensureTable(env, 'config_changes') first and batches the
// returned statements next to its own write, so the audit row and the change
// land together (routes/routing.js does the same for routing_changes).

// The only kinds a row may carry. `kind` comes from code, never from a request.
export const CONFIG_KINDS = Object.freeze({
  REVIEW_GATE_THRESHOLD: 'review_gate_threshold',
  RULE: 'concurrency_rule',
  RETRY_POLICY: 'retry_policy',
  CONTRACT: 'phase_contract',
  COST_CAP: 'cost_cap',
  TELEGRAM_TOPIC: 'telegram_topic',
  REGISTRY_SEED: 'registry_seed',
  SETTING: 'setting',
  FLAG: 'flag',
  MERGE_QUEUE: 'merge_queue',
  HELD_PAGE: 'held_page',
  PROJECT: 'project',
  PROJECT_SECRET: 'project_secret',
  CONNECTION: 'connection', // BH-7924: PUT /api/connections, one row per changed project
});

// Equality is on String() form, so a threshold read back from D1 as 5 and
// written from a form as '5' is not a change. null and undefined are equal.
const norm = (v) => (v == null ? null : String(v));

// {f: o[f] ?? null} in `fields` order: the stored JSON carries the raw values.
function pick(o, fields) {
  const out = {};
  for (const f of fields) out[f] = o[f] ?? null;
  return out;
}

// `was` is the row before the write (null/undefined when the write creates it),
// `after` the row written (null/undefined when the write deletes it), `fields`
// the fields audited. Returns one prepared INSERT for a create (before_json
// NULL), a changed update, or a delete (after_json the JSON text 'null', since
// the column is NOT NULL). Returns [] when both `was` and `after` are present
// and every audited field is unchanged (an unchanged write is not a decision),
// or when neither is present (nothing existed, nothing was written).
export function configChangeStmts(env, kind, name, was, after = null, fields, actor, reason, t) {
  if (was == null && after == null) return [];
  if (was && after && fields.every((f) => norm(was[f]) === norm(after[f]))) return [];
  const actorNorm = actor ? String(actor).slice(0, 128) : 'api';
  const reasonNorm = (reason == null ? '' : String(reason).trim()).slice(0, 512) || null;
  return [
    env.DB.prepare(
      'INSERT INTO config_changes (kind, name, before_json, after_json, actor, reason, at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    ).bind(
      kind,
      name,
      was ? JSON.stringify(pick(was, fields)) : null,
      after == null ? 'null' : JSON.stringify(pick(after, fields)),
      actorNorm,
      reasonNorm,
      t,
    ),
  ];
}

const KIND_VALUES = new Set(Object.values(CONFIG_KINDS));
const MAX_CHANGES = 500;

// BH-2375: the one read over config_changes, newest first. Like
// configChangeStmts it imports nothing: the caller calls
// ensureTable(env, 'config_changes') first. `kind` and `name`
// are optional equality filters bound as parameters; a kind not in
// CONFIG_KINDS or a name outside 1..256 chars is {error}, never an unfiltered
// read. `limit` behaves like the routing and cost-cap audit GETs (a
// non-number falls to 100, then clamped 1..500); one extra row is read so
// `truncated` is measured, not guessed.
export async function listConfigChanges(env, { kind = null, name = null, limit } = {}, t) {
  if (kind !== null && !KIND_VALUES.has(kind)) {
    return { error: `kind must be one of ${[...KIND_VALUES].join(', ')}` };
  }
  if (name !== null && (typeof name !== 'string' || name.length < 1 || name.length > 256)) {
    return { error: 'name must be 1 to 256 characters' };
  }
  const n = Math.min(Math.max(Number(limit) || 100, 1), MAX_CHANGES);
  const rows = await env.DB.prepare(
    'SELECT * FROM config_changes WHERE (?2 IS NULL OR kind=?2) AND (?3 IS NULL OR name=?3) ORDER BY id DESC LIMIT ?1',
  ).bind(n + 1, kind, name).all();
  const list = rows.results || [];
  return { changes: list.slice(0, n), truncated: list.length > n, as_of: t };
}

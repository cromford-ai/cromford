// Settings tools (BH-7712): read and write one settings row through the
// console's coord proxy, with the knob registry the console has DEPLOYED (GET
// /api/coord/lanes/registry) as the reference for type, min and max. The
// worker stays the last check on every write; these checks are a stricter
// front, never a bypass. A secret-looking row is never returned.
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const ROWS = '/api/coord/settings';
const REG = '/api/coord/lanes/registry';
// A prefix read answers at most this many rows; `total` and `truncated` say
// when there were more.
const ROW_LIMIT = 100;

const KEY_RE = /^[a-z0-9_.-]{1,64}$/;
// The note must say why and how to go back.
const NOTE_MIN = 20;
const ROLLBACK_RE = /roll\s*back|revert|undo|restore|set (it )?back/i;
// A secret-named LAST key segment, and a secret-shaped value.
const SECRET_KEY_RE = /(secret|token|password|passwd|apikey|api_key|private_key|credentials?|cookie|bearer|sig)$/;
const SECRET_VALUE_RE = /^\s*(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|xox[bpa]-|AKIA|Bearer\s)/;

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (t) => ({ content: [{ type: 'text', text: t }], isError: true });
const nullable = (v) => (v === undefined ? null : v);
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });

async function getJson(ctx, path) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', path);
  if (r.ok) return { ok: true, data: r.data };
  if (r.status === 404) return { ok: false, error: `console route not available: ${path}` };
  return { ok: false, error: r.error };
}

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}

const lastSegment = (key) => String(key).split('.').at(-1);
const isSecretValue = (v) => typeof v === 'string' && SECRET_VALUE_RE.test(v);
const isSecretRow = (r) => r.redacted === true || SECRET_KEY_RE.test(lastSegment(r.key)) || isSecretValue(r.value);

// The registry from GET /api/coord/lanes/registry, or null for a bad payload.
const registryOf = (data) => {
  const reg = isPlain(data) && isPlain(data.registry) ? data.registry : null;
  return reg && Array.isArray(reg.lanes) && Array.isArray(reg.libs) ? reg : null;
};

// `<lane|lib>.<id>.<env>` or `<lane|lib>.<id>.<project>.<env>` → the knob,
// else null. Lane and lib ids hold no dots, so the split is exact.
function resolveKnob(reg, key) {
  if (!reg) return null;
  const parts = key.split('.');
  if (parts.length !== 3 && parts.length !== 4) return null;
  const [pf, id] = parts;
  const kind = pf === 'lane' ? 'lane' : pf === 'lib' ? 'lib' : null;
  if (!kind) return null;
  const owner = (kind === 'lane' ? reg.lanes : reg.libs).find((o) => o?.id === id);
  const env = parts.at(-1);
  const k = (Array.isArray(owner?.knobs) ? owner.knobs : [])
    .find((x) => typeof x?.env === 'string' && x.env.toLowerCase() === env);
  if (!k) return null;
  return {
    owner: id, kind, env: k.env, type: nullable(k.type), default: nullable(k.default),
    min: nullable(k.min), max: nullable(k.max), unit: nullable(k.unit), zero_means: nullable(k.zero_means),
    note: nullable(k.note), settable: k.settable !== false, project_scoped: parts.length === 4,
  };
}

// One row as the tools answer it. A secret row keeps its key, never its value.
function shapeRow(r) {
  const out = {
    value: nullable(r.value), note: nullable(r.note), actor: nullable(r.actor), updated_at: nullable(r.updated_at),
  };
  if (isSecretRow(r)) {
    out.value = null;
    out.redacted = true;
  }
  return out;
}

// A known knob's check of the value: null, or the refusal.
function badValue(knob, raw) {
  const v = String(raw).trim();
  let n;
  if (knob.type === 'int') {
    if (!/^-?\d+$/.test(v)) return `value_type: ${knob.env} wants int`;
    n = Number(v);
  } else if (knob.type === 'float' || knob.type === 'number') {
    n = Number(v);
    if (v === '' || !Number.isFinite(n)) return `value_type: ${knob.env} wants ${knob.type}`;
  } else {
    return v === '' ? `value_type: ${knob.env} wants ${knob.type}` : null;
  }
  const range = `value_out_of_range: ${v} (min ${knob.min ?? 'none'}, max ${knob.max ?? 'none'})`;
  if (typeof knob.min === 'number' && n < knob.min) return range;
  if (typeof knob.max === 'number' && n > knob.max) return range;
  return null;
}

// ---- setting_get ----

const getSchema = {
  type: 'object', properties: { key: str(64), prefix: str(64) }, additionalProperties: false,
};
const getArgs = checkArgs(getSchema);

function getPrecheck(args) {
  const bad = getArgs(args);
  if (bad) return bad;
  if (args.key !== undefined && args.prefix !== undefined) return 'key_or_prefix_not_both';
  for (const k of ['key', 'prefix']) if (args[k] !== undefined && !KEY_RE.test(args[k])) return `invalid_arguments: ${k}`;
  return null;
}

async function settingGet(a, ctx) {
  if (a.key !== undefined) {
    const [one, rg] = await Promise.all([getJson(ctx, `${ROWS}/${encodeURIComponent(a.key)}`), getJson(ctx, REG)]);
    if (!one.ok) return fail(one.error);
    if (!isPlain(one.data) || !('setting' in one.data)) return fail(`bad_payload: ${ROWS}/${a.key}`);
    const reg = rg.ok ? registryOf(rg.data) : null;
    const r = isPlain(one.data.setting) ? one.data.setting : null;
    const out = {
      key: a.key, ...(r ? shapeRow({ ...r, key: a.key }) : { value: null, note: null, actor: null, updated_at: null }),
      source: nullable(one.data.source), knob: resolveKnob(reg, a.key), as_of: nullable(one.data.as_of),
    };
    if (!reg) out.partial = [REG];
    return reply(ctx, out);
  }
  const [all, rg] = await Promise.all([getJson(ctx, ROWS), getJson(ctx, REG)]);
  if (!all.ok) return fail(all.error);
  if (!isPlain(all.data) || !Array.isArray(all.data.settings)) return fail(`bad_payload: ${ROWS}`);
  const reg = rg.ok ? registryOf(rg.data) : null;
  const prefix = a.prefix ?? null;
  const match = all.data.settings
    .filter((r) => isPlain(r) && typeof r.key === 'string' && r.key.startsWith(prefix ?? ''))
    .sort((x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0));
  const rows = match.slice(0, ROW_LIMIT).map((r) => ({ key: r.key, ...shapeRow(r), knob: resolveKnob(reg, r.key) }));
  const out = { prefix, rows, total: match.length, truncated: match.length > rows.length, as_of: nullable(all.data.as_of) };
  if (!reg) out.partial = [REG];
  return reply(ctx, out);
}

// ---- setting_set ----

const setSchema = {
  type: 'object',
  properties: {
    key: str(64),
    // String or number; the precheck checks it (checkArgs takes one type).
    value: {},
    note: str(512),
    confirm: { type: 'boolean' },
    force: { type: 'boolean' },
  },
  required: ['key', 'value', 'note', 'confirm'],
  additionalProperties: false,
};
const setArgs = checkArgs(setSchema);

function setPrecheck(args) {
  if (args.confirm !== true) return 'confirm_required';
  if (typeof args.note !== 'string' || args.note.trim() === '') return 'note_required';
  if (args.note.trim().length < NOTE_MIN || !ROLLBACK_RE.test(args.note)) return 'note_must_say_why_and_rollback';
  const bad = setArgs(args);
  if (bad) return bad;
  if (!KEY_RE.test(args.key)) return 'invalid_arguments: key';
  const v = args.value;
  const okValue = (typeof v === 'string' && v.trim() !== '' && v.length <= 4096) || (typeof v === 'number' && Number.isFinite(v));
  if (!okValue) return 'invalid_arguments: value';
  if (SECRET_KEY_RE.test(lastSegment(args.key)) || isSecretValue(String(v))) return 'secret_value_refused';
  return null;
}

async function settingSet(a, ctx) {
  const [one, rg] = await Promise.all([getJson(ctx, `${ROWS}/${encodeURIComponent(a.key)}`), getJson(ctx, REG)]);
  if (!one.ok) return fail(one.error);
  if (!isPlain(one.data) || !('setting' in one.data)) return fail(`bad_payload: ${ROWS}/${a.key}`);
  if (!rg.ok) return fail(`registry_unavailable: ${rg.error}`);
  const reg = registryOf(rg.data);
  if (!reg) return fail(`registry_unavailable: bad_payload: ${REG}`);

  const knob = resolveKnob(reg, a.key);
  const forced = a.force === true;
  if (!knob && !forced) {
    return fail(`unknown_knob: ${a.key} (pass force: true to write a key the knob registry does not list)`);
  }
  if (knob && !knob.settable) return fail(`not_settable: ${knob.env}`);
  if (knob) {
    const bad = badValue(knob, a.value);
    if (bad) return fail(bad);
  }

  const old = isPlain(one.data.setting) ? shapeRow({ ...one.data.setting, key: a.key }) : null;
  // No actor: the coord proxy stamps the caller's session identity.
  const body = { key: a.key, value: String(a.value).trim(), note: a.note, reason: a.note };
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'PUT', ROWS, body);
  if (!r.ok) return fail(r.status === 404 ? `console route not available: ${ROWS}` : r.error);
  if (!isPlain(r.data) || !isPlain(r.data.setting)) {
    return fail(`bad_payload: ${ROWS} (write sent, answer unreadable; read it back with setting_get)`);
  }
  const fresh = shapeRow({ key: a.key, ...r.data.setting });
  return reply(ctx, { key: a.key, old, new: fresh, knob, forced: !knob && forced, as_of: nullable(r.data.as_of) });
}

export const tools = [
  {
    name: 'setting_get',
    description: 'Read one settings row (key) or the rows under a prefix: value, note, actor, update time, and the knob registry entry (type, default, min, max, zero_means, note). Secret rows come back with value null.',
    kind: 'read',
    inputSchema: getSchema,
    precheck: getPrecheck,
    handler: settingGet,
  },
  {
    name: 'setting_set',
    description: 'Write one settings row through PUT /api/settings; the console stamps you as the actor. The note must say why and how to roll back. The value is checked against the knob registry (type, min, max); a key the registry does not list needs force: true. Returns the old and new row. Needs confirm: true.',
    kind: 'write',
    inputSchema: setSchema,
    precheck: setPrecheck,
    handler: settingSet,
  },
];

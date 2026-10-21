// Pool status tool (BH-7709): why a project's queued builds do not spawn. It
// reads ONE console route, GET /api/coord/pool/status?project=<p> (format
// pool-status v1): the row the hub lane bin/pool-tick-summary.sh builds from
// the last pool tick in logs/fly-pool.log (the header counts, one decision per
// row key, what stopped the tick or the last start, the last hour's env bundle
// failures and max-ticks waits, today's respawns), plus the per-key spawn cap
// from the settings rows. This file groups the decisions and parses no log. A
// field the answer lacks stays null here, never 0.
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const ROUTE = '/api/coord/pool/status';
// The lane reports every 2 minutes, so 10 minutes is 5 missed reports.
const STALE_S = 600;
const EXAMPLES = 5;
const GROUPS = ['waits_for', 'hold', 'spawn_cap', 'env_bundle', 'quota', 'not_queued', 'other'];
const LAST_TICK = ['at', 'started_at', 'ended_at', 'complete', 'rows_decided', 'rows_spawned', 'stop', 'window_stop',
  'cap', 'knob', 'in_progress_since', 'max_ticks_waits_1h', 'last_max_ticks_at'];
const PROJECT_RE = /^[A-Za-z0-9._-]{1,64}$/;

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const nullable = (v) => (v === undefined ? null : v);

// The redacted text is the one source: structuredContent is parsed back from
// it, so neither half can carry what the other scrubbed.
function reply(ctx, value) {
  const text = redact(JSON.stringify(value), ctx.cfg);
  return { content: [{ type: 'text', text }], structuredContent: JSON.parse(text) };
}
const fail = (ctx, t) => ({ content: [{ type: 'text', text: redact(t, ctx.cfg) }], isError: true });

// Seconds from `iso` to `now`, or null.
function ageS(iso, now) {
  const t = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isFinite(t) && Number.isFinite(now) ? Math.max(0, Math.round((now - t) / 1000)) : null;
}

// The stored decisions as the 7 skip groups plus spawned, each {count,
// examples}: the first 5 keys in log order. A class this file does not know is
// counted as other.
function group(decisions) {
  const g = Object.fromEntries([...GROUPS, 'spawned'].map((k) => [k, { count: 0, examples: [] }]));
  for (const d of decisions) {
    if (!Array.isArray(d) || typeof d[0] !== 'string') continue;
    const slot = g[d[1]] ?? g.other;
    slot.count += 1;
    if (slot.examples.length < EXAMPLES) slot.examples.push(d[0]);
  }
  const { spawned, ...skips } = g;
  return { skips, spawned };
}

async function poolStatus(a, ctx) {
  if (!PROJECT_RE.test(a.project)) return fail(ctx, 'invalid_arguments: project');
  const path = `${ROUTE}?project=${encodeURIComponent(a.project)}`;
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, 'GET', path);
  if (!r.ok) return fail(ctx, r.status === 404 ? `console route not available: ${ROUTE}` : r.error);
  const d = r.data;
  if (!isPlain(d) || d.project !== a.project) return fail(ctx, `bad_payload: ${ROUTE}`);
  const ok = d.tick === 'ok';
  const lt = isPlain(d.last_tick) ? d.last_tick : {};
  const grouped = ok && Array.isArray(d.decisions) ? group(d.decisions) : null;
  const age = ageS(d.reported_at, Date.parse(d.as_of));
  return reply(ctx, {
    project: d.project,
    status: ok ? 'ok' : 'no_summary',
    reason: nullable(d.reason),
    reported_at: nullable(d.reported_at),
    as_of: nullable(d.as_of),
    report_age_s: age,
    stale: age === null ? null : age > STALE_S,
    truncated: ok ? nullable(d.decisions_truncated) : null,
    pool: {
      queued: nullable(d.queued), running: nullable(d.running), spawning: nullable(d.spawning),
      cap: nullable(d.cap), hotfix: nullable(d.hotfix),
      spawn_cap_per_key: isPlain(d.spawn_cap_per_key)
        ? { value: nullable(d.spawn_cap_per_key.value), window_s: nullable(d.spawn_cap_per_key.window_s), source: nullable(d.spawn_cap_per_key.source) }
        : null,
    },
    last_tick: Object.fromEntries(LAST_TICK.map((k) => [k, nullable(lt[k])])),
    skips: grouped ? grouped.skips : null,
    spawned: grouped ? grouped.spawned : null,
    env_bundle_failures_1h: nullable(d.env_bundle_failures_1h),
    respawns: Array.isArray(d.respawns) ? d.respawns : null,
    respawns_since: nullable(d.respawns_since),
    respawns_truncated: nullable(d.respawns_truncated),
  });
}

const schema = {
  type: 'object',
  properties: { project: { type: 'string', minLength: 1, maxLength: 64 } },
  required: ['project'],
  additionalProperties: false,
};

export const tools = [
  {
    name: 'pool_status',
    description: "Why a project's queued builds do not spawn: the pool's queued, running and spawning counts, its cap and the per-key spawn cap, the last pool tick (start, end, rows decided and spawned, and what stopped it or the last start: budget, age, code change, max-ticks, load shed or spawn hold), its skip reasons grouped with up to 5 example keys each, the env bundle failures of the last hour, and today's respawned keys.",
    kind: 'read',
    inputSchema: schema,
    precheck: checkArgs(schema),
    handler: poolStatus,
  },
];

// Read tools: each forwards one GET (chat: one POST) to the console API.
// Names and argument shapes follow the Cloud worker's `mcp-tools.js` (moved out
// of this repo, BH-5239).
import { forward } from '../lib/tools.mjs';
import { consoleFetch, redact } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

// Every object level is closed, and no schema declares a tenant property.
const obj = (properties, required) => ({
  type: 'object', properties, ...(required ? { required } : {}), additionalProperties: false,
});
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const int = (minimum, maximum) => ({ type: 'integer', minimum, ...(maximum === undefined ? {} : { maximum }) });
const LIMIT = int(1, 200);
const PROJECT = str(100);

const seg = encodeURIComponent;
// `?a=1&b=2` from the defined entries, in the order given; '' when none are.
const query = (pairs) => {
  const q = new URLSearchParams();
  for (const [k, v] of pairs) if (v !== undefined) q.append(k, String(v));
  const s = q.toString();
  return s ? '?' + s : '';
};
const get = (path) => (args, ctx) => forward(ctx, 'GET', path(args));

// project_status's spend_ceiling block (BH-7876): the project's daily ceiling
// row conf.cost-caps.<project>.daily_usd, the warn row
// conf.cost-caps.daily_warn_pct and the spend for the UTC day, read in
// parallel with the dash read. The fleet rows only: a box row is not shown.
// A failed dash read fails the tool as forward does; a failed ceiling read is
// state 'unknown', never a spend of 0.
const DAILY_WARN_PCT = 80; // the harness's code fallback (cost-budget.sh)
const NUM = /^\d+(\.\d+)?$/;
const rowNumber = (res) => {
  const raw = res && res.ok ? res.data?.setting?.value : undefined;
  const s = raw === undefined || raw === null ? '' : String(raw).trim();
  return NUM.test(s) ? Number(s) : null;
};
const warnPct = (res) => {
  const n = rowNumber(res);
  return n !== null && n > 0 && n <= 100 ? n : DAILY_WARN_PCT;
};
export function spendCeiling(project, settingRes, spendRes, warnRes) {
  const out = { project, ceiling_usd: null, spent_usd_today: null, pct: null, state: 'none', as_of: null };
  if (!settingRes.ok) return { ...out, state: 'unknown', error: settingRes.status === 404 ? 'setting_route_missing' : String(settingRes.error) };
  const raw = settingRes.data?.setting?.value;
  if (raw === undefined || raw === null) return out;
  const ceiling = NUM.test(String(raw).trim()) ? Number(String(raw).trim()) : 0;
  if (!(ceiling > 0)) return { ...out, state: 'unreadable', error: 'ceiling_refused' };
  out.ceiling_usd = ceiling;
  const usd = spendRes.ok ? spendRes.data?.usd : undefined;
  if (typeof usd !== 'number' || !Number.isFinite(usd)) {
    return { ...out, state: 'unknown', error: spendRes.ok ? 'spend_not_a_number' : String(spendRes.error) };
  }
  const state = usd >= ceiling ? 'over' : usd * 100 >= ceiling * warnPct(warnRes) ? 'warn' : 'under';
  return { ...out, spent_usd_today: usd, pct: Math.floor((usd * 100) / ceiling), state, as_of: spendRes.data?.as_of ?? null };
}

async function projectStatus(a, ctx) {
  const fetcher = ctx.consoleFetch ?? consoleFetch;
  const dashPath = `/api/dash/p/${seg(a.project)}`;
  const [dash, setting, spend, warn] = await Promise.all([
    fetcher(ctx.cfg, 'GET', dashPath),
    fetcher(ctx.cfg, 'GET', `/api/coord/settings/${seg(`conf.cost-caps.${a.project}.daily_usd`)}`),
    fetcher(ctx.cfg, 'GET', '/api/coord/metrics/llm-spend' + query([['project', a.project]])),
    fetcher(ctx.cfg, 'GET', '/api/coord/settings/conf.cost-caps.daily_warn_pct'),
  ]);
  if (!dash.ok || dash.data === null || typeof dash.data !== 'object' || Array.isArray(dash.data)) {
    // The answer forward gives, from the same response: no second dash read.
    return forward({ ...ctx, consoleFetch: async () => dash }, 'GET', dashPath);
  }
  const data = { ...dash.data, spend_ceiling: spendCeiling(a.project, setting, spend, warn) };
  return { content: [{ type: 'text', text: redact(JSON.stringify(data), ctx.cfg) }], structuredContent: data };
}

const defs = [
  {
    name: 'project_status', description: "One project's board and build state.", kind: 'read',
    inputSchema: obj({ project: PROJECT }, ['project']),
    handler: projectStatus,
  },
  {
    name: 'builds', description: 'List recent builds.', kind: 'read',
    inputSchema: obj({ limit: LIMIT }),
    handler: get((a) => '/api/dash/builds' + query([['limit', a.limit]])),
  },
  {
    name: 'pipeline', description: 'Tickets in the build pipeline.', kind: 'read',
    inputSchema: obj({ limit: LIMIT, filter: obj({ project: PROJECT }) }),
    handler: get((a) => '/api/dash/kanban/pipeline' +
      query([['project', a.filter?.project], ['shipped_limit', a.limit]])),
  },
  {
    name: 'prs', description: 'Pull requests the harness opened. Needs filter.project.', kind: 'read',
    inputSchema: obj({
      limit: LIMIT, state: { type: 'string', enum: ['open', 'closed', 'merged', 'all'] },
      filter: obj({ project: PROJECT }),
    }),
    // The console route is per project: refuse before any request rather
    // than send /api/dash/prs/ or /api/dash/prs/undefined.
    precheck: (a) => (a && a.filter && typeof a.filter.project === 'string' && a.filter.project
      ? null : 'project_required'),
    handler: get((a) => `/api/dash/prs/${seg(a.filter.project)}` +
      query([['limit', a.limit], ['state', a.state]])),
  },
  {
    name: 'alerts', description: 'Recent alerts.', kind: 'read',
    inputSchema: obj({
      limit: LIMIT,
      filter: obj({ project: PROJECT, severity: { type: 'string', enum: ['page', 'warn', 'info'] } }),
    }),
    handler: get((a) => '/api/dash/alerts' +
      query([['limit', a.limit], ['project', a.filter?.project], ['severity', a.filter?.severity]])),
  },
  {
    name: 'costs', description: 'Spend records.', kind: 'read',
    inputSchema: obj({ limit: LIMIT, filter: obj({ project: PROJECT, since: str(40) }) }),
    handler: get((a) => '/api/dash/costs' +
      query([['limit', a.limit], ['project', a.filter?.project], ['since', a.filter?.since]])),
  },
  {
    name: 'machines', description: 'The machines in the fleet.', kind: 'read',
    inputSchema: obj({}),
    handler: get(() => '/api/dash/machines'),
  },
  {
    name: 'logs', description: "The tail of a project's harness log.", kind: 'read',
    inputSchema: obj({ project: PROJECT, lines: int(1, 500) }, ['project']),
    handler: get((a) => `/api/dash/logs/${seg(a.project)}` + query([['lines', a.lines]])),
  },
  {
    // Model-backed on the console side: one POST per call, never retried here.
    name: 'chat', description: 'Ask the harness a question.', kind: 'read',
    inputSchema: obj({ message: str(4000), project: PROJECT }, ['message']),
    handler: (a, ctx) => forward(ctx, 'POST', '/api/dash/chat',
      a.project === undefined ? { text: a.message } : { text: a.message, target: a.project }),
  },
];

// The whole schema is checked before any request. A tool's own precheck
// (prs: project_required) answers first, as the more specific refusal.
export const tools = defs.map((t) => {
  const schemaCheck = checkArgs(t.inputSchema);
  const own = t.precheck;
  return { ...t, precheck: own ? (a, ctx) => own(a, ctx) ?? schemaCheck(a) : schemaCheck };
});

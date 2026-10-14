// Read tools: each forwards one GET (chat: one POST) to the console API.
// Names and argument shapes follow the Cloud worker's `mcp-tools.js` (moved out
// of this repo, BH-5239).
import { forward } from '../lib/tools.mjs';
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

const defs = [
  {
    name: 'project_status', description: "One project's board and build state.", kind: 'read',
    inputSchema: obj({ project: PROJECT }, ['project']),
    handler: get((a) => `/api/dash/p/${seg(a.project)}`),
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

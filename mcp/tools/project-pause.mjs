// Project pause tools: pause_project and resume_project. Each one sends three
// console commands in one call, POST /api/dash/action each, and reports one
// result per part, then reads the project page once for the state after.
//   pause_project   pause_board, automerge_off, pool_hold {hold: true}
//   resume_project  resume_board, pool_hold {hold: false}, automerge_on|off
// They run only when confirm is the boolean true; a refusal sends nothing.
// The three commands are independent, so they go in parallel, and a failed
// part does not stop the other two (no rollback). Each part is a queued
// console command: the hub runs it on its next poll.
// pool_hold reaches the hub through the Pages proxy fallback
// (console-ui/functions/_lib/pool-hold-command.js), so HARNESS_CONSOLE_URL
// must be the Pages origin; through the worker host it reports
// http_400: unknown action.
import { consoleFetch } from '../lib/console.mjs';
import { checkArgs } from './lib/schema.mjs';

const ACTION = '/api/dash/action';
const NOTE = 'Each part is a queued console command. The hub runs it on its next poll. ' +
  'Call project_status to see it applied.';
const obj = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
const PROJECT = { type: 'string', minLength: 1, maxLength: 100 };
const REASON = { type: 'string', minLength: 1, maxLength: 500 };
const BOOL = { type: 'boolean' };
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const flag = (v) => (typeof v === 'boolean' ? v : null);

// The console's answer for one POST: ok only on a 2xx.
function part(name, body, r) {
  const id = r.ok && isPlain(r.data) && Number.isSafeInteger(r.data.command_id) ? r.data.command_id : null;
  const error = r.ok ? null : (r.status === 404 ? `console route not available: ${ACTION}` : r.error);
  return { part: name, type: body.type, ok: r.ok === true, command_id: id, error };
}

async function run(ctx, project, bodies) {
  const f = ctx.consoleFetch ?? consoleFetch;
  const answers = await Promise.all(bodies.map(([, body]) => f(ctx.cfg, 'POST', ACTION, body)));
  const parts = bodies.map(([name, body], i) => part(name, body, answers[i]));
  // After the POSTs, so it is the console's own read, never the intent. It can
  // still show the old state until the hub polls (the note says so).
  const path = `/api/dash/p/${encodeURIComponent(project)}`;
  const s = await f(ctx.cfg, 'GET', path);
  const board = s.ok && isPlain(s.data) ? (isPlain(s.data.board) ? s.data.board : {}) : null;
  const ok = parts.every((p) => p.ok);
  const out = {
    project, ok, parts,
    state_after: board ? { paused: flag(board.paused), automerge: flag(board.automerge) } : null,
    partial: board ? [] : [path],
    note: NOTE,
  };
  return { content: [{ type: 'text', text: JSON.stringify(out) }], structuredContent: out, ...(ok ? {} : { isError: true }) };
}

const guarded = (name, description, inputSchema, bodies) => {
  const check = checkArgs(inputSchema);
  return {
    name, description, kind: 'guarded', inputSchema,
    precheck: (args) => {
      if (args.confirm !== true) return 'confirm_required';
      return check(args);
    },
    handler: (args, ctx) => run(ctx, args.project, bodies(args)),
  };
};

export const tools = [
  guarded('pause_project',
    "Pause a project: pause its board, set its automerge off and hold its Fly pool (no new spawns; running builds finish). Needs confirm: true.",
    obj({ project: PROJECT, confirm: BOOL, reason: REASON }, ['project', 'confirm']),
    ({ project, reason = 'paused with MCP pause_project' }) => [
      ['board', { type: 'pause_board', project, reason }],
      ['automerge', { type: 'automerge_off', project }],
      ['pool', { type: 'pool_hold', project, hold: true, reason }],
    ]),
  guarded('resume_project',
    "Resume a project: resume its board, release its Fly pool hold and set its automerge to the given value. Needs confirm: true.",
    obj({ project: PROJECT, confirm: BOOL, automerge: BOOL, reason: REASON }, ['project', 'confirm', 'automerge']),
    ({ project, automerge, reason = 'resumed with MCP resume_project' }) => [
      ['board', { type: 'resume_board', project, reason }],
      ['automerge', { type: automerge ? 'automerge_on' : 'automerge_off', project }],
      ['pool', { type: 'pool_hold', project, hold: false, reason }],
    ]),
];

// Action tools: each sends exactly one POST /api/dash/action {type, ...args}.
// Names and argument shapes follow the Cloud worker's `mcp-tools.js` (moved out
// of this repo, BH-5239). The schemas are closed, so an argument
// named `type` is refused before the
// spread below could override it.
import { forward } from '../lib/tools.mjs';
import { checkArgs } from './lib/schema.mjs';

const obj = (properties, required) => ({
  type: 'object', properties, ...(required ? { required } : {}), additionalProperties: false,
});
const str = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const PROJECT = str(100);
const ISSUE = { type: 'integer', minimum: 1 };

// `type` is the command type the hub runs, when it is not the tool name.
const action = (name, description, inputSchema, type = name) => ({
  name, description, kind: 'write', inputSchema,
  // Required fields, types, lengths and ranges are refused before the POST.
  precheck: checkArgs(inputSchema),
  handler: (args, ctx) => forward(ctx, 'POST', '/api/dash/action', { type, ...args }),
});

export const tools = [
  action('file_issue', 'File an issue on a project board.',
    obj({ project: PROJECT, title: str(200), body: str(20000) }, ['project', 'title'])),
  action('comment_issue', 'Comment on an issue.',
    obj({ project: PROJECT, issue: ISSUE, body: str(20000) }, ['project', 'issue', 'body'])),
  // The hub knows a hold as hold_ticket (bin/lib/ticket-hold-cmd.sh), BH-5820.
  action('hold_issue', 'Put an issue on hold.',
    obj({ project: PROJECT, issue: ISSUE, reason: str(500) }, ['project', 'issue']), 'hold_ticket'),
  action('run_triage', 'Run triage on a project, or one issue.',
    obj({ project: PROJECT, issue: ISSUE }, ['project'])),
  action('pause_board', 'Pause a project board.', obj({ project: PROJECT }, ['project'])),
  action('resume_board', 'Resume a project board.', obj({ project: PROJECT }, ['project'])),
  action('fetch_artifact', 'Fetch one artifact of a build.',
    obj({ project: PROJECT, build_id: str(100), name: str(200) }, ['project', 'build_id', 'name'])),
];

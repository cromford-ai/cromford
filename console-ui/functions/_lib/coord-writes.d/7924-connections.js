import { isStr } from '../coord-writes.js';

export default [
  // BH-7924: the /connections EDIT form (src/screens/Connections.js). One PUT
  // writes a project's tracker rows; the worker validates every field,
  // refuses a token-shaped value with the env var to set instead, and audits
  // the change in config_changes kind `connection`. Only these string fields
  // travel (an empty string deletes that row); a key like api_key is never
  // forwarded. The box's POST connections/<p>/status has no row here, so a
  // browser gets 405 for it.
  {
    method: 'PUT',
    path: 'connections',
    body: ['project', 'adapter', 'team', 'label', 'states', 'write_projects', 'read_projects',
      'comment_projects', 'status_map', 'webhook_route', 'reason'],
    ok: isStr
  }
];

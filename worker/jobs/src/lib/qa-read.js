// QA capabilities are explicit at both the route and response-field boundary.
// Opaque metadata, notes, reasons and future columns cannot enter a preview.
const PATHS = new Set(['/api/jobs', '/api/flags']);

export function qaReadOk(req, env) {
  const auth = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  return Boolean(env.QA_READ_TOKEN) && env.QA_READ_TOKEN !== env.HARNESS_SECRET
    && auth === env.QA_READ_TOKEN && req.method === 'GET' && PATHS.has(new URL(req.url).pathname);
}

const JOB_FIELDS = [
  'id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status', 'budget_usd', 'spent_usd',
  'created_at', 'updated_at', 'issue_created_at', 'first_spawn_at', 'last_beat_at', 'beat_box',
  'beat_age_s', 'activity_age_s', 'heartbeating', 'age_s', 'phase', 'phase_status', 'phase_rc',
  'failed_phase', 'lane', 'attempts', 'max_attempts', 'next_attempt_at', 'escalate_allowed',
];
const FLAG_FIELDS = ['name', 'scope', 'active', 'set_at', 'cleared_at', 'updated_at'];
const projectRows = (rows, fields) => rows.map((row) => Object.fromEntries(
  fields.filter((key) => Object.hasOwn(row, key)).map((key) => [key, row[key]]),
));

export const qaJobs = (rows) => projectRows(rows, JOB_FIELDS);
export const qaFlags = (rows) => projectRows(rows, FLAG_FIELDS);

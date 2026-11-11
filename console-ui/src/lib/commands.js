import { prNumberFromUrl } from './format.js';

// The rows of GET /api/dash/commands (BH-2514), normalised once for the
// /history/commands table. The worker hands back `{commands:[…]}` whose
// `payload` is the command body as a JSON string (bin/poll-commands.sh reads it
// the same way); the Pages proxy stamps `actor` into that body, so the actor is
// on the row when the worker lifts it and in the payload otherwise. Nothing
// here fills a gap with a guess: no actor is null, no target is null.

const enc = encodeURIComponent;

const PROPOSAL = new Set(['chat_proposal', 'post_proposal', 'kill_proposal', 'revise_proposal']);
const BOARD = new Set(['pause_board', 'resume_board', 'pause_set', 'pause_end', 'run_triage', 'fetch_log',
  'fetch_artifact', 'automerge_on', 'automerge_off', 'update_company_map', 'hold_ticket', 'unhold_ticket',
  'comment_issue', 'file_issue']);
// A fleet pause has no board; its row lives in the pause flags table on /jobs.
const FLEET_PAUSE = new Set(['pause_set', 'pause_end']);

const str = (v) => (typeof v === 'string' && v.trim() ? v : null);

function parsePayload(raw) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return { payload: raw, unreadable: false };
  if (raw == null || raw === '') return { payload: {}, unreadable: false };
  if (typeof raw === 'string') {
    try {
      const p = JSON.parse(raw);
      if (p && typeof p === 'object' && !Array.isArray(p)) return { payload: p, unreadable: false };
    } catch { /* falls through */ }
  }
  return { payload: {}, unreadable: true };
}

function normalise(row) {
  const { payload, unreadable } = parsePayload(row.payload);
  return {
    id: row.id,
    type: str(row.type),
    project: str(row.project) ?? str(payload.project),
    actor: str(row.actor) ?? str(payload.actor),
    status: str(row.status) ?? str(row.stage),
    outcome: str(row.refusal) ?? str(row.result),
    createdAt: row.created_at ?? null,
    payload,
    payloadUnreadable: unreadable
  };
}

// A body in neither documented shape is `malformed`, never an empty list: the
// screen says "unexpected response" rather than "nothing on record".
export function commandRows(body) {
  const list = Array.isArray(body) ? body : body && Array.isArray(body.commands) ? body.commands : null;
  if (!list) return { rows: [], malformed: true };
  return { rows: list.filter((r) => r && typeof r === 'object').map(normalise), malformed: false };
}

const posInt = (v) => {
  const n = typeof v === 'string' && /^[1-9][0-9]*$/.test(v) ? Number(v) : v;
  return Number.isInteger(n) && n > 0 ? n : null;
};

// Where a command points: its job, PR, idea, board or the command it retried.
export function commandTarget(row) {
  if (!row) return null;
  const p = row.payload || {};
  const project = row.project;
  const job = typeof p.job_id === 'number' ? String(p.job_id) : str(p.job_id);
  if (job) return { to: `/jobs/${enc(job)}`, label: `job ${job}` };
  const type = row.type;
  if (type === 'merge_pr' || type === 'lead_review') {
    const n = type === 'merge_pr' ? prNumberFromUrl(p.pr_url) : posInt(p.pr);
    return project && n ? { to: `/pr/${enc(project)}/${n}`, label: `PR #${n}` } : null;
  }
  if (PROPOSAL.has(type)) {
    const slug = str(p.slug);
    return project && slug ? { to: `/ideas/${enc(project)}/${enc(slug)}`, label: `idea ${slug}` } : null;
  }
  if (BOARD.has(type)) {
    if (project) return { to: `/p/${enc(project)}`, label: `${project} board` };
    if (FLEET_PAUSE.has(type) && p.scope === 'fleet') return { to: '/jobs', label: 'fleet pauses' };
    return null;
  }
  if (type === 'retry_command') {
    const n = posInt(p.cmd_id);
    return n ? { to: `/history/commands?id=${n}`, label: `command #${n}` } : null;
  }
  if (type === 'chat') return { to: '/chat', label: 'chat' };
  return null;
}

export const FILTER_KEYS = ['type', 'status', 'project', 'actor'];

export function filterCommands(rows, filters = {}) {
  const on = FILTER_KEYS.filter((k) => filters[k] != null && filters[k] !== '');
  return rows.filter((r) => on.every((k) => r[k] === filters[k]));
}

export function facetValues(rows, key) {
  return [...new Set(rows.map((r) => r[key]).filter((v) => v != null))].sort();
}

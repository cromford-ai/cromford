// BH-6823: the staff chat thread's pure half. One thread per staff agent; the
// agent reads a note on its next bin/staff.sh tick and answers it in the same
// model turn. The rows are the ones worker/jobs/src/routes/staff-chat.js
// answers on GET /api/staff/chat: an operator note (role operator, state
// pending | held | taken | read | unanswered | failed) and an agent reply
// (role agent, state sent, reply_to = the note, tick_key = the tick, tick_id =
// the staff_ticks row once it landed).

// The worker's cap (routes/steer.js STEER_TEXT_MAX, reused by staff-chat.js).
export const STAFF_CHAT_TEXT_MAX = 4000;

// The worker's agent identity (staff.js): trimmed, lowercased, this alphabet.
// Archie is not a staff_agents row and has no thread.
const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
export const chatAgent = (agent) => {
  const a = typeof agent === 'string' ? agent.trim().toLowerCase() : '';
  return AGENT_RE.test(a) && a !== 'archie' && a !== 'all' ? a : null;
};

// The POST body, or null when there is nothing valid to send. Over the cap is
// refused, never cut.
export function chatBody(agent, text) {
  const a = chatAgent(agent);
  const t = typeof text === 'string' ? text.trim() : '';
  if (!a || !t || t.length > STAFF_CHAT_TEXT_MAX) return null;
  return { agent: a, text: t };
}

const isId = (v) => (typeof v === 'number' || typeof v === 'string') && /^[1-9][0-9]*$/.test(String(v));

// Messages (any order, pages and local rows mixed) as the thread, oldest
// first: each operator note with its reply. A reply whose note is not on a
// loaded page shows on its own. A row without a server id (a send in flight)
// sits at the bottom. null for anything that is not a list: a failed read is
// not an empty thread.
export function threadRows(messages) {
  if (!Array.isArray(messages)) return null;
  const rows = messages.filter((m) => m && typeof m === 'object');
  const replies = new Map();
  for (const m of rows) if (m.role === 'agent' && isId(m.reply_to)) replies.set(Number(m.reply_to), m);
  const noteIds = new Set(rows.filter((m) => m.role !== 'agent' && isId(m.id)).map((m) => Number(m.id)));
  const out = [];
  for (const m of rows) {
    if (m.role === 'agent') {
      if (!noteIds.has(Number(m.reply_to))) out.push({ note: null, reply: m });
    } else {
      out.push({ note: m, reply: isId(m.id) ? replies.get(Number(m.id)) || null : null });
    }
  }
  const sortId = (r) => {
    const m = r.note || r.reply;
    return isId(m.id) ? Number(m.id) : Infinity;
  };
  return out.sort((a, b) => sortId(a) - sortId(b));
}

// What a note's row proves, as { text, tick }: tick is a tick key the view may
// link (rendered after text), or null. "answered" only off a reply row;
// "agent stopped" only off a held note or the GET's live `stopped`.
export function noteState(note, { stopped = false, reply = null } = {}) {
  const n = note || {};
  const key = typeof n.tick_key === 'string' && n.tick_key ? n.tick_key : null;
  if (reply) return { text: 'answered in tick', tick: (reply.tick_key || key) || null };
  switch (n.state) {
    case 'sending': return { text: 'sending', tick: null };
    case 'held': return { text: 'agent stopped: kept, read when it resumes', tick: null };
    case 'pending':
      return stopped
        ? { text: 'agent stopped: kept, read when it resumes', tick: null }
        : { text: 'waiting for the next tick', tick: null };
    case 'taken': return key ? { text: `in tick ${key} now`, tick: null } : { text: 'in a tick now', tick: null };
    case 'read': return key ? { text: 'read in tick', tick: key } : { text: 'read', tick: null };
    case 'unanswered': return key ? { text: 'no answer in tick', tick: key } : { text: 'no answer', tick: null };
    case 'failed': {
      const n2 = Number(n.attempts);
      return { text: Number.isInteger(n2) && n2 > 0 ? `not answered after ${n2} ${n2 === 1 ? 'try' : 'tries'}` : 'not answered', tick: null };
    }
    default: return { text: `state ${n.state === undefined || n.state === null ? 'unknown' : String(n.state)}`, tick: null };
  }
}

// The /staff/tick/:id link (BH-6822) of a reply, or null until the tick row
// landed (the tick posts its row at exit).
export function tickHref(row) {
  const id = row ? row.tick_id : null;
  return typeof id === 'number' && Number.isInteger(id) && id > 0 ? `/staff/tick/${id}` : null;
}

// Several message lists as one, by id; a later list wins (the head page is
// passed last, so its copy of a note is the newest). Rows without an id (a send
// in flight) are kept as they are.
export function mergeMessages(...lists) {
  const byId = new Map();
  const loose = [];
  for (const list of lists) {
    for (const m of list || []) {
      if (!m || typeof m !== 'object') continue;
      if (isId(m.id)) byId.set(Number(m.id), m); else loose.push(m);
    }
  }
  return [...byId.values(), ...loose];
}

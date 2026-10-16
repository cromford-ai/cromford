import { NON_PROJECTS } from './kanban.js';
import { commandRows } from './commands.js';
// The chat thread is assembled from overlapping polls plus optimistic local
// turns, so the merge has to be idempotent. The dedup key is
// (command_id, direction): command_id alone would collapse every reply into its
// own question, and the row `id` alone would leave an optimistic turn on screen
// beside the server's copy of the same turn.

// (command_id, direction, target). command_id alone collapses a reply into its
// own question; the row `id` alone leaves an optimistic turn beside the
// server's copy of it. Target is in the key because a command_id shared across
// two targets would otherwise make one thread's turn silently vanish — and the
// optimistic turn and its server row always agree on target, so including it
// does not break the replacement this dedup exists for.
const keyOf = (m) => `${String(m.command_id)}:${m.direction}:${normaliseTarget(m.target)}`;

// A turn is addressed either to the hub orchestrator or to one box's Claude
// session. The deployed worker does not send `target` yet, and a message
// without one is an orchestrator turn — treating it as "unknown" would empty
// the default thread the moment this ships.
export const ORCHESTRATOR = 'orchestrator';

export const normaliseTarget = (t) => (t === null || t === undefined || t === '' ? ORCHESTRATOR : String(t));

export const messageTarget = (m) => normaliseTarget(m && m.target);

export const filterByTarget = (messages, target) => {
  const want = normaliseTarget(target);
  return (messages || []).filter((m) => messageTarget(m) === want);
};

// `hub` is the fetch_log-only literal — the box that holds the fleet-level
// logs. It is NOT a chat target: offering it would queue a chat command that
// nothing answers, and the tab would sit there forever looking merely slow.
// Same set the fleet views use, kept in one place.
export const NON_TARGETS = NON_PROJECTS;

// The untargeted read returns EVERY thread with one global `last_id`, so its
// cursor lives in the same map under a reserved key. Keying it (rather than
// holding a loose scalar) is what makes the shared-cursor bug structurally
// impossible: a targeted read added later gets its own key by construction and
// can never inherit this one. The key is not a legal project name, so no
// project can ever collide with it.
export const ALL_THREADS = '__all__';

// BH-6823: a staff agent's thread is a target too, keyed `staff:<agent>`. It
// is not a command turn: the tab renders the agent's own chat pane
// (screens/staff/agent-chat.js), which the agent reads on its next tick.
// Archie is not a staff agent and has no thread.
export const STAFF_PREFIX = 'staff:';
const STAFF_AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const isStaffAgent = (a) => typeof a === 'string' && STAFF_AGENT_RE.test(a) && a !== 'archie' && a !== 'all';

// The agent of a `staff:<agent>` target key, or null for any other key.
export function staffAgentOf(key) {
  if (typeof key !== 'string' || !key.startsWith(STAFF_PREFIX)) return null;
  const a = key.slice(STAFF_PREFIX.length);
  return isStaffAgent(a) ? a : null;
}

export function buildTargets(projects, staff = []) {
  const agents = [...new Set((staff || []).filter(isStaffAgent))];
  return [
    { key: ORCHESTRATOR, label: 'HUB ORCHESTRATOR' },
    ...(projects || []).filter((p) => !NON_TARGETS.has(String(p))).map((p) => ({ key: p, label: p })),
    ...agents.map((a) => ({ key: `${STAFF_PREFIX}${a}`, label: `STAFF ${a.toUpperCase()}`, kind: 'staff', agent: a }))
  ];
}

// One cursor PER TARGET. `last_id` from a targeted GET describes that target
// only, so feeding it back as a shared cursor makes the next tab's poll start
// too high and skip every message below it — they simply never appear.
export const cursorFor = (cursors, target) => Number((cursors || {})[normaliseTarget(target)]) || 0;

export function advanceCursor(cursors, target, payload) {
  const t = normaliseTarget(target);
  const last = payload && payload.last_id !== undefined && payload.last_id !== null
    ? Number(payload.last_id)
    : null;
  if (last === null || !Number.isFinite(last)) return cursors || {};
  return { ...(cursors || {}), [t]: Math.max(cursorFor(cursors, t), last) };
}

// A reply can come back as a routing failure rather than an answer. Rows
// written before the `error` column existed carry it only as self-describing
// text, so both shapes have to be recognised — but conservatively: painting a
// real answer as an error hides the answer the operator actually asked for.
const FAILURE_TEXT = /^\s*(routing[ _]failed\b|could not route\b|failed to route\b|no route to\b)/i;

export function isFailedReply(m) {
  if (!m || m.direction !== 'reply') return false;
  if (m.error) return true;
  return FAILURE_TEXT.test(String(m.text || ''));
}

export function replyFailure(m) {
  if (!isFailedReply(m)) return null;
  const reason = m.error ? String(m.error) : 'routing_failed';
  return {
    reason,
    label: reason === 'routing_failed' ? 'ROUTING FAILED' : reason.replace(/_/g, ' ').toUpperCase(),
    note: reason === 'routing_failed'
      ? 'The turn never reached a session. It was not answered and will not be — send it again.'
      : 'The turn came back as a failure rather than an answer.'
  };
}

export function optimisticTurn(commandId, text, target) {
  return {
    id: null,
    command_id: String(commandId),
    direction: 'out',
    origin: 'dash',
    target: normaliseTarget(target),
    text,
    created_at: new Date().toISOString(),
    pending: true
  };
}

// Unread = a REPLY newer than the last one you saw on that target. Counting a
// target you have never opened as "all unread" would light up every box on
// first load, which trains you to ignore the dot.
export function markSeen(seen, target, messages) {
  const t = normaliseTarget(target);
  const highest = filterByTarget(messages, t)
    .reduce((max, m) => (m.id !== null && m.id !== undefined && Number(m.id) > max ? Number(m.id) : max), 0);
  return { ...seen, [t]: Math.max(Number(seen[t]) || 0, highest) };
}

export function unreadByTarget(messages, seen) {
  const out = {};
  for (const m of messages || []) {
    const t = messageTarget(m);
    if (out[t] === undefined) out[t] = 0;
    // Your own turns are never unread, and neither is anything already seen.
    if (m.direction !== 'reply') continue;
    if (m.id === null || m.id === undefined) continue;
    if (Number(m.id) > (Number(seen && seen[t]) || 0)) out[t] += 1;
  }
  return out;
}

// A box's Claude session can be cold, and the first turn to it is slow. Saying
// "no response" or timing out would read as broken when it is merely starting.
export function pendingWaitLabel({ messages, target, waitingMs = 0 }) {
  const t = normaliseTarget(target);
  if (t === ORCHESTRATOR) {
    return { text: 'waiting for the orchestrator', patient: false };
  }
  // A routing failure is not the box answering — it never reached a session,
  // so the next turn is still a first turn against a cold one.
  const hasAnswered = filterByTarget(messages, t).some((m) => m.direction === 'reply' && !isFailedReply(m));
  if (hasAnswered) return { text: `waiting for the ${t} box`, patient: false };
  const long = waitingMs >= 20000;
  return {
    text: long
      ? `still waking the ${t} box — a cold session takes a while on the first turn`
      : `waking the ${t} box…`,
    patient: true
  };
}

export function mergeMessages(existing, incoming) {
  const byKey = new Map();
  let seq = 0;
  const put = (m, serverWins) => {
    const k = keyOf(m);
    const prev = byKey.get(k);
    if (prev && !serverWins) return;
    byKey.set(k, { ...m, command_id: String(m.command_id), _seq: prev ? prev._seq : seq++ });
  };
  for (const m of existing || []) put(m, false);
  // Incoming rows come from the server, so they replace an optimistic turn.
  for (const m of incoming || []) put(m, true);

  return [...byKey.values()]
    .sort((a, b) => {
      const ia = a.id === null || a.id === undefined;
      const ib = b.id === null || b.id === undefined;
      // Turns still awaiting their server row sit at the bottom, under the
      // spinner — they are the newest thing that happened by construction.
      if (ia !== ib) return ia ? 1 : -1;
      if (!ia && a.id !== b.id) return Number(a.id) - Number(b.id);
      return a._seq - b._seq;
    })
    .map(({ _seq, ...m }) => m);
}

export function pendingCommandIds(messages) {
  const replied = new Set(
    (messages || []).filter((m) => m.direction === 'reply').map((m) => String(m.command_id))
  );
  const out = [];
  for (const m of messages || []) {
    if (m.direction !== 'out') continue;
    const id = String(m.command_id);
    if (!replied.has(id) && !out.includes(id)) out.push(id);
  }
  return out;
}

// The poll cursor only ever moves forward. A `since` that regresses replays the
// whole thread on every tick, and optimistic turns have no server id to offer.
export function nextSince(current, payload) {
  const last = payload && payload.last_id !== undefined && payload.last_id !== null
    ? Number(payload.last_id)
    : null;
  if (last === null || !Number.isFinite(last)) return current;
  return Math.max(Number(current) || 0, last);
}

// Command-status vocabulary the hub writes on orchestrator chat commands
// (BH-4995): queued_behind:<id> | running:<iso> | answered:<iso> |
// no_reply:<iso> | duplicate:<iso>. Anything else ("handed to orchestrator",
// a refusal, null) is not a queue state.
const CMD_STATUS = /^(queued_behind|running|answered|no_reply|duplicate):(.+)$/;

export function parseCmdStatus(result) {
  const m = typeof result === 'string' ? CMD_STATUS.exec(result) : null;
  if (!m) return { state: null };
  const [, state, tail] = m;
  if (state === 'queued_behind') {
    return /^[1-9][0-9]*$/.test(tail) ? { state, behind: tail } : { state: null };
  }
  return Number.isNaN(Date.parse(tail)) ? { state: null } : { state, at: tail };
}

// A running turn with no update for this long is flagged, not hidden: the hub
// may have died mid-turn and the operator should see that. A display threshold
// over data the hub already writes, so a UI constant rather than a knob.
export const ORC_RUNNING_STALE_MIN = 60;

// The orchestrator's turn queue out of a GET /api/dash/commands body: the turn
// running now (newest `running:` wins) and the turns queued behind it, oldest
// first. An orchestrator chat sent from the console carries no project, so the
// target is normalised the same way the thread's is.
export function orcQueue(commands, nowMs) {
  const { rows } = commandRows(commands);
  const live = rows
    .filter((r) => r.type === 'chat' && normaliseTarget(r.project) === ORCHESTRATOR && r.status === 'done')
    .map((r) => ({ id: String(r.id), createdAt: r.createdAt, ...parseCmdStatus(r.outcome) }));

  let running = null;
  for (const r of live) {
    if (r.state !== 'running') continue;
    const startedMs = Date.parse(r.at);
    if (!running || startedMs > running.startedMs
      || (startedMs === running.startedMs && Number(r.id) > Number(running.id))) {
      running = { id: r.id, startedMs };
    }
  }
  if (running) {
    const ageMs = Math.max(0, nowMs - running.startedMs);
    running = { ...running, ageMs, stale: ageMs >= ORC_RUNNING_STALE_MIN * 60000 };
  }

  const waiting = live
    .filter((r) => r.state === 'queued_behind' && (!running || r.id !== running.id))
    .map((r) => ({ r, created: Date.parse(r.createdAt) }))
    .sort((a, b) => {
      const na = Number.isNaN(a.created);
      const nb = Number.isNaN(b.created);
      if (na !== nb) return na ? 1 : -1;
      if (!na && a.created !== b.created) return a.created - b.created;
      return Number(a.r.id) - Number(b.r.id);
    })
    .map(({ r, created }) => ({
      id: r.id, behind: r.behind, ageMs: Number.isNaN(created) ? null : Math.max(0, nowMs - created)
    }));

  return { running, waiting };
}

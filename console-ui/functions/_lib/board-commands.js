// The Pages-side queue for the console's board commands (BH-5820):
// comment_issue, hold_ticket and unhold_ticket, and file_issue (BH-9014, the
// MCP `file_issue` tool).
//
// The console worker (the harness-console repo) refuses these four with
// 400 'unknown action' before it inserts anything, because its ACTION_TYPES
// does not list them. The hub runs all four (bin/poll-commands.sh; file_issue
// through bin/lib/tracker/issue-file-cmd.sh).
// So when the worker answers exactly that refusal for one of these types, the
// Pages proxy validates the body here and inserts the command row into the
// worker's own D1 (`CONSOLE_DB`). The hub claims every pending row whatever
// wrote it. Once the worker accepts the types it answers 200, and this path
// never runs again.
//
// AUTHORISATION IS DELEGATED, ON PURPOSE — the same rule as functions/api/
// cockpit/, coord/, ideas/ and outcomes/. The worker's 400 is NOT proof that
// it checked the `dash` cookie first, so the 400 never buys a write. Before a
// row is queued, the incoming cookie and Authorization header go to the console
// worker's own authed endpoint, and only a 200 permits the write. Unlike those read-only
// functions, there is no cache: every write is probed. An unreachable worker
// is not a grant; it fails closed.

import { holdTarget, HOLD_REASON_MAX } from '../../src/lib/ticket-hold.js';

export const BOARD_FALLBACK_TYPES = new Set(['comment_issue', 'hold_ticket', 'unhold_ticket', 'file_issue']);

export const CONSOLE = 'https://harness-console.operator.workers.dev';
export const AUTH_PROBE = '/api/dash/fleet';

// True only when the console worker answers 200 to its authed probe with these
// credentials: the `dash` cookie (the browser) and/or the Authorization header
// (an MCP client with HARNESS_CONSOLE_TOKEN sends a Bearer token and no cookie;
// mcp/lib/console.mjs: "a token wins"). Whatever the request carried goes to
// the probe, so the worker decides. Neither, any other status, or a fetch
// error is false.
export async function signedIn({ cookie = '', authorization = '' } = {}) {
  if (!cookie && !authorization) return false;
  const headers = {};
  if (cookie) headers.cookie = cookie;
  if (authorization) headers.authorization = authorization;
  try {
    const res = await fetch(CONSOLE + AUTH_PROBE, { headers, redirect: 'manual' });
    return res.status === 200;
  } catch {
    return false;
  }
}

export const COMMENT_BODY_MAX = 20000;
export const ISSUE_TITLE_MAX = 256; // GitHub's own limit on an issue title (a vendor API limit, not a tunable)
const PROJECT = /^[A-Za-z0-9._-]{1,100}$/;
const posInt = (v) => Number.isSafeInteger(v) && v > 0;

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// The command row for a sent body, or {error} for a 400. `sent.actor` is the
// proxy's resolved identity, never the browser's.
export async function boardCommand(sent) {
  const type = sent.type;
  if (!BOARD_FALLBACK_TYPES.has(type)) return { error: 'unknown action' };
  const project = typeof sent.project === 'string' ? sent.project.trim() : '';
  if (!PROJECT.test(project)) return { error: 'project required' };
  const actor = sent.actor;
  // The same click within one minute is the same command (the worker's
  // toggle convention); the minute is UTC.
  const minute = new Date().toISOString().slice(0, 16);

  if (type === 'comment_issue') {
    if (!posInt(sent.issue)) return { error: 'issue must be a positive integer' };
    const body = sent.body;
    if (typeof body !== 'string' || !body.trim() || body.length > COMMENT_BODY_MAX) {
      return { error: `body required (1-${COMMENT_BODY_MAX} characters)` };
    }
    const hash = (await sha256Hex(body)).slice(0, 16);
    return {
      type, project,
      ckey: `${project}:${type}:${sent.issue}:${minute}:${hash}`,
      payload: { issue: sent.issue, body, actor }
    };
  }

  if (type === 'file_issue') {
    const title = typeof sent.title === 'string' ? sent.title.trim() : '';
    if (!title || title.length > ISSUE_TITLE_MAX) {
      return { error: `title required (1-${ISSUE_TITLE_MAX} characters)` };
    }
    const body = sent.body ?? '';
    if (typeof body !== 'string' || body.length > COMMENT_BODY_MAX) {
      return { error: `body must be a string of at most ${COMMENT_BODY_MAX} characters` };
    }
    const hash = (await sha256Hex(title + '\n' + body)).slice(0, 16);
    return { type, project, ckey: `${project}:${type}:${minute}:${hash}`, payload: { title, body, actor } };
  }

  const target = holdTarget(project, sent.ticket);
  let n, ref;
  if (target) { n = target.issue; ref = { ticket: target.ticket }; }
  else if (sent.ticket == null && posInt(sent.issue)) { n = sent.issue; ref = { issue: sent.issue }; }
  else return { error: 'ticket (PREFIX-<n>) or issue required' };
  const reason = String(sent.reason ?? '').trim().slice(0, HOLD_REASON_MAX);
  return { type, project, ckey: `${project}:${type}:${n}:${minute}`, payload: { ...ref, reason, actor } };
}

// Insert the row once per ckey. {command_id} on success; {error:'no-db'}
// when the binding is absent; {error:'d1-error'} on any database failure.
export async function enqueueBoardCommand(db, cmd) {
  if (!db || typeof db.prepare !== 'function') return { error: 'no-db' };
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  try {
    await db.prepare(
      `INSERT INTO commands (ckey, type, project, payload, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'pending', ?, ?) ON CONFLICT(ckey) DO NOTHING`
    ).bind(cmd.ckey, cmd.type, cmd.project, JSON.stringify(cmd.payload), now, now).run();
    const row = await db.prepare('SELECT id FROM commands WHERE ckey = ?').bind(cmd.ckey).first();
    const id = row ? Number(row.id) : NaN;
    if (!Number.isSafeInteger(id) || id <= 0) throw new Error('no id after insert');
    return { command_id: id };
  } catch (e) {
    // The body text never reaches the log.
    console.error(`board-commands: ${cmd.type} ${cmd.project} not queued: ${e && e.message ? e.message : e}`);
    return { error: 'd1-error' };
  }
}

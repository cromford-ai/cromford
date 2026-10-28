// Cloudflare Pages Function: forward /api/* to the console worker.
//
// The point is same-origin. The `dash` cookie is HttpOnly + SameSite=Lax and is
// set on THIS host by /login/<secret>; proxying here means the browser attaches
// it to every /api/dash/* call with no CORS preflight, no bearer token in JS,
// and no secret ever reaching the page.
//
// Every request passes through verbatim except one: a command, POST
// /api/dash/action, has its body's `actor` set HERE to the resolved identity
// (BH-2515, functions/_lib/access-identity.js): the Cloudflare Access email
// when its signed assertion verifies, 'console' otherwise. bin/poll-commands.sh
// names a payload actor on the pause row it writes, but today's console worker
// (harness-console pauseCommand) rebuilds the payload without it, so pause rows
// still record 'console' and the top-bar pill says so. It is not carried there
// on purpose: the worker is also reachable directly with the shared dash
// cookie, so it cannot tell this stamp from a browser-sent actor.
//
// A pause command is also checked here before it is forwarded (BH-2509):
// pause_board, resume_board and pause_set are a 400 'reason required' unless
// `reason` is a string that is not blank once trimmed, and a pause_set whose
// scope is exactly 'fleet' is a 400 'ttl_s required for a fleet pause' unless
// `ttl_s` is a whole number above 0 (a number, or a string of digits). Nothing
// is forwarded on a 400. Every other command, pause_end included, passes as
// before. Telegram and the MCP tool do not come through here.
//
// A merge_pr carrying the standing verdict's sha as `verdict_sha` first frees
// its command key from a terminal "head moved" refusal bound to a different
// reviewed sha (BH-4439, functions/_lib/merge-pr-rekey.js), so a click after a
// re-review mints a new command instead of getting the old refusal back. It's
// a no-op without the CONSOLE_DB binding or a valid `verdict_sha`.
//
// comment_issue, hold_ticket and unhold_ticket are forwarded first like every
// command (BH-5820, functions/_lib/board-commands.js). Only when the worker
// answers 400 'unknown action' for one of them (its ACTION_TYPES lacks them,
// and that refusal inserts nothing) does this proxy consider a write. It
// first presents the incoming `dash` cookie to the worker's authed probe
// (/api/dash/fleet); anything but a 200 is a 403 'unauthorized' and no row.
// Then it validates the body and queues the row in CONSOLE_DB itself,
// answering {ok, type, ckey, command_id}. A bad body is a 400 naming the field. No CONSOLE_DB returns the worker's
// refusal as it was, and a failed write is a 503. Once the worker accepts the
// types it answers 200, and this path never runs.

import { resolveIdentity } from '../_lib/access-identity.js';
import { rekeyHeadMovedRefusal } from '../_lib/merge-pr-rekey.js';
import { BOARD_FALLBACK_TYPES, boardCommand, enqueueBoardCommand, signedIn } from '../_lib/board-commands.js';
import { POOL_HOLD_TYPES, poolHoldCommand } from '../_lib/pool-hold-command.js';
import { CONNECTION_PROBE_TYPES, connectionProbeCommand } from '../_lib/connection-probe-command.js';
import { readOnlyRefusal } from '../_lib/qa-session.js';

const WORKER = 'https://harness-console.operator.workers.dev';
const COMMAND = '/api/dash/action';

const jsonError = (status, error) =>
  new Response(JSON.stringify({ error }), { status, headers: { 'content-type': 'application/json' } });

// The worker's response, with `body` in place of its body. Set-Cookie rides
// along, so a cookie the worker refreshes still lands on this origin.
const passThrough = (upstream, body) => {
  const out = new Headers(upstream.headers);
  out.delete('content-encoding');
  out.delete('content-length');
  return new Response(body, { status: upstream.status, statusText: upstream.statusText, headers: out });
};

const NEEDS_REASON = new Set(['pause_board', 'resume_board', 'pause_set']);

// The 400 message for a pause command the console must not queue, or null.
function pauseRefusal(cmd) {
  if (!NEEDS_REASON.has(cmd.type)) return null;
  if (typeof cmd.reason !== 'string' || !cmd.reason.trim()) return 'reason required';
  if (cmd.type === 'pause_set' && cmd.scope === 'fleet') {
    const t = cmd.ttl_s;
    const whole = (typeof t === 'number' && Number.isInteger(t) && t > 0)
      || (typeof t === 'string' && /^[1-9][0-9]*$/.test(t));
    if (!whole) return 'ttl_s required for a fleet pause';
  }
  return null;
}

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  // A QA session (cromford #5909) never writes. The worker refuses it too;
  // this answers first, so not even the CONSOLE_DB fallback can be reached.
  const qaRefused = readOnlyRefusal(request);
  if (qaRefused) return qaRefused;
  const target = new URL(url.pathname + url.search, WORKER);

  const headers = new Headers(request.headers);
  // Host must be the worker's, or workerd routes the request as this origin.
  headers.delete('host');
  // Let Cloudflare re-negotiate the response encoding with the worker.
  headers.delete('accept-encoding');

  const init = {
    method: request.method,
    headers,
    redirect: 'manual'
  };
  // The parsed command and its stamped actor, for the BH-5820 fallback below.
  let sent = null;
  let actor = null;
  if (request.method === 'POST' && url.pathname === COMMAND) {
    // A body that is not a JSON object is refused rather than forwarded as-is:
    // passing it through unparsed would pass its actor through too.
    try { sent = JSON.parse(await request.text()); } catch { sent = null; }
    if (!sent || typeof sent !== 'object' || Array.isArray(sent)) {
      return jsonError(400, `a POST to ${COMMAND} must carry a JSON object body`);
    }
    const refusal = pauseRefusal(sent);
    if (refusal) return jsonError(400, refusal);
    if (sent.type === 'merge_pr') await rekeyHeadMovedRefusal(env && env.CONSOLE_DB, sent);
    ({ actor } = await resolveIdentity(request, env || {}));
    init.body = JSON.stringify({ ...sent, actor });
    headers.set('content-type', 'application/json');
    headers.delete('content-length');
  } else if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = await request.arrayBuffer();
  }

  let upstream;
  try {
    upstream = await fetch(target.toString(), init);
  } catch (e) {
    return new Response(JSON.stringify({ error: 'console worker unreachable' }), {
      status: 502,
      headers: { 'content-type': 'application/json' }
    });
  }

  if (sent && BOARD_FALLBACK_TYPES.has(sent.type) && upstream.status === 400) {
    return boardFallback(upstream, { ...sent, actor }, env, {
      cookie: request.headers.get('cookie') || '',
      authorization: request.headers.get('authorization') || ''
    });
  }
  // pool_hold (BH-7708) takes the same fallback with its own validation.
  if (sent && POOL_HOLD_TYPES.has(sent.type) && upstream.status === 400) {
    return boardFallback(upstream, { ...sent, actor }, env, {
      cookie: request.headers.get('cookie') || '',
      authorization: request.headers.get('authorization') || ''
    }, poolHoldCommand);
  }
  // PROBE NOW (BH-7924): run_script, connection-probe.sh <project> only.
  if (sent && CONNECTION_PROBE_TYPES.has(sent.type) && upstream.status === 400) {
    return boardFallback(upstream, { ...sent, actor }, env, {
      cookie: request.headers.get('cookie') || '',
      authorization: request.headers.get('authorization') || ''
    }, connectionProbeCommand);
  }

  // Pass everything back verbatim.
  return passThrough(upstream, upstream.body);
}

// The worker refused a board command with a 400. Queue it here only when the
// refusal is 'unknown action'; any other 400 goes back as the worker sent it.
// The worker's 400 does not prove it authenticated the request, so the
// credentials (cookie and/or Authorization) must pass the worker's authed probe
// before anything is validated or written.
async function boardFallback(upstream, sent, env, creds, build = boardCommand) {
  const text = await upstream.text();
  let refusal = null;
  try { refusal = JSON.parse(text); } catch { refusal = null; }
  if (!refusal || refusal.error !== 'unknown action') return passThrough(upstream, text);
  if (!(await signedIn(creds))) return jsonError(403, 'unauthorized');
  const cmd = await build(sent);
  if (cmd.error) return jsonError(400, cmd.error);
  const q = await enqueueBoardCommand(env && env.CONSOLE_DB, cmd);
  if (q.error === 'no-db') return passThrough(upstream, text);
  if (q.error) return jsonError(503, `${cmd.type} not queued: console database write failed`);
  return new Response(JSON.stringify({ ok: true, type: cmd.type, ckey: cmd.ckey, command_id: q.command_id }), {
    status: 200, headers: { 'content-type': 'application/json' }
  });
}

// Cloudflare Pages Function: /api/prompts/* -> the harness-jobs worker
// (BH-7940.0). The prompt editor (BH-7940.4) and the prompts screen
// (BH-7940.5) call this same-origin path; it is their only way to the store.
//
// The bearer (HARNESS_SECRET) is attached HERE and never reaches the browser.
// Sign-in is delegated to the console worker's probe (signedIn), as in
// functions/api/coord/. The browser cookie goes to that probe only, never to
// harness-jobs. Every path segment and the `project` param are checked by value
// before anything is forwarded, and a save's or a restore's `author` is the
// identity resolved here, never the browser's.
//
// Shapes (BH-7940.0, BH-7940.4): GET '' (the list), GET <scope>/<kind>/<n>,
// POST <scope>/<kind> (a save), GET <scope>/<kind>/versions,
// POST <scope>/<kind>/restore?version=<n> and DELETE <scope>/<kind>/head.
// Any other method and shape is 405.

import { signedIn } from '../../_lib/board-commands.js';
import { resolveIdentity } from '../../_lib/access-identity.js';
import { readOnlyRefusal } from '../../_lib/qa-session.js';

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SCOPES = new Set(['fleet', 'project']);
const KINDS = new Set(['rules', 'watcher', 'plan', 'execute', 'review', 'fix-round', 'qa']);
const VERSION_RE = /^[1-9][0-9]{0,8}$/;
const PROJECT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
// The third segment is a version number, or the one method a history action takes.
const ACTIONS = Object.freeze({ versions: 'GET', restore: 'POST', head: 'DELETE' });
const isAction = (s) => Object.prototype.hasOwnProperty.call(ACTIONS, s);
const SEGMENT_OK = [(s) => SCOPES.has(s), (s) => KINDS.has(s), (s) => VERSION_RE.test(s) || isAction(s)];
const FORWARDED = ['body', 'note', 'base_version'];

// True when `method` may go to these segments.
function shapeAllowed(method, segs) {
  if (segs.length === 0) return method === 'GET';
  if (segs.length === 2) return method === 'POST';
  if (segs.length !== 3) return false;
  return isAction(segs[2]) ? ACTIONS[segs[2]] === method : method === 'GET';
}

const json = (status, obj) =>
  new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });

export async function onRequest(context) {
  const { request, env, params } = context;

  const qaRefused = readOnlyRefusal(request);
  if (qaRefused) return qaRefused;

  if (!env.HARNESS_SECRET) {
    return json(503, { error: 'HARNESS_SECRET is not set on this Pages project, so the prompts view cannot authenticate to harness-jobs' });
  }

  let ok = false;
  try { ok = await signedIn({ cookie: request.headers.get('cookie') || '' }); } catch { ok = false; }
  if (!ok) return json(403, { error: 'unauthorized' });

  const raw = params && params.path;
  const segs = Array.isArray(raw) ? raw : (raw ? String(raw).split('/') : []);
  for (let i = 0; i < segs.length; i++) {
    if (i < SEGMENT_OK.length && !SEGMENT_OK[i](segs[i])) return json(400, { error: 'bad path segment' });
  }
  const method = request.method;
  if (!shapeAllowed(method, segs)) {
    return json(405, { error: `method ${method} not allowed on /api/prompts/${segs.join('/')}` });
  }

  const url = new URL(request.url);
  const project = url.searchParams.get('project');
  const target = new URL(segs.length ? `/api/prompts/${segs.join('/')}` : '/api/prompts', JOBS);
  if (project !== null) {
    if (!PROJECT_RE.test(project)) return json(400, { error: 'bad project' });
    target.searchParams.set('project', project);
  }
  const restoring = segs[2] === 'restore';
  if (restoring) {
    const version = url.searchParams.get('version');
    if (!VERSION_RE.test(version || '')) return json(400, { error: 'version must be a whole number >= 1' });
    target.searchParams.set('version', version);
  }

  const init = {
    method,
    headers: { authorization: `Bearer ${env.HARNESS_SECRET}`, 'content-type': 'application/json' }
  };
  if (method === 'POST') {
    let sent = null;
    try { sent = JSON.parse(await request.text()); } catch { sent = null; }
    if (!sent || typeof sent !== 'object' || Array.isArray(sent)) {
      return json(400, { error: 'a POST to /api/prompts must carry a JSON object body' });
    }
    const author = (await resolveIdentity(request, env)).actor;
    if (typeof author !== 'string' || !author.trim()) return json(403, { error: 'unauthorized' });
    // A restore takes only the author; a save takes the FORWARDED keys too.
    const out = {};
    if (!restoring) for (const k of FORWARDED) if (k in sent) out[k] = sent[k];
    out.author = author;
    init.body = JSON.stringify(out);
  }

  let upstream;
  try {
    upstream = await fetch(target.toString(), init);
  } catch {
    return json(502, { error: 'harness-jobs unreachable' });
  }
  const headers = new Headers(upstream.headers);
  headers.delete('content-encoding');
  headers.delete('content-length');
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}

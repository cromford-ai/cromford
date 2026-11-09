// Cloudflare Pages Function: GET /api/dash/kanban/waiting[?project=] — the
// "To do (waiting)" view (BH-9116): every open board ticket that is not in
// flight, with one reason each. src/lib/waiting.js holds the rule.
//
// TWO READS, IN SEQUENCE (the second needs the first's keys), and nothing else:
//   1. the hub's ticket snapshot on the console worker, with the CALLER'S OWN
//      headers. That read is the sign-in check: anything but a 200 goes back to
//      the caller as sent, and the jobs worker is never called.
//   2. POST harness-jobs /api/waiting/state with the open tickets, under
//      HARNESS_SECRET. One D1 batch answers it.
// No file read and no box call.
//
// A FAILED READ IS NEVER AN EMPTY VIEW. An unusable snapshot or a failed jobs
// read is 200 {ok:false, unavailable}, with no rows and no counts: classifying
// with no jobs state would call every open ticket not-triaged.
import { classifyWaiting, openTickets, PROJECT_RE } from '../../../../src/lib/waiting.js';
import { snapshotUsable } from '../../../../src/lib/tickets.js';

const WORKER = 'https://harness-console.operator.workers.dev';
const JOBS = 'https://harness-jobs.operator.workers.dev';

const out = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
});

export async function onRequest(context) {
  const { request, env } = context;
  if (request.method !== 'GET') return out(405, { error: 'method not allowed' });
  const url = new URL(request.url);
  const project = url.searchParams.get('project');
  if (project !== null && !PROJECT_RE.test(project)) return out(400, { error: 'bad project' });

  const headers = new Headers(request.headers);
  headers.delete('host');
  headers.delete('accept-encoding');
  let snapRes;
  try {
    snapRes = await fetch(`${WORKER}/api/dash/tickets-snapshot`, { method: 'GET', headers, redirect: 'manual' });
  } catch {
    return out(502, { error: 'console worker unreachable' });
  }
  if (snapRes.status !== 200) {
    const pass = new Headers(snapRes.headers);
    pass.delete('content-encoding');
    pass.delete('content-length');
    return new Response(snapRes.body, { status: snapRes.status, statusText: snapRes.statusText, headers: pass });
  }
  let snapshot;
  try {
    snapshot = JSON.parse(await snapRes.text());
  } catch {
    return out(200, { ok: false, unavailable: 'the ticket snapshot is not JSON' });
  }
  const usable = snapshotUsable(snapshot);
  if (!usable.usable) return out(200, { ok: false, unavailable: `no ticket snapshot: ${usable.reason}` });

  // A project with no OS board is not in the snapshot: a normal state, said
  // out loud, with no jobs read.
  if (project !== null && !Object.prototype.hasOwnProperty.call(snapshot.projects, project)) {
    return out(200, classifyWaiting(snapshot, {}, { project }));
  }

  if (!env || !env.HARNESS_SECRET) {
    return out(503, { ok: false, unavailable: 'HARNESS_SECRET not set on the Pages project' });
  }
  const tickets = openTickets(snapshot, project).map(({ project: p, key, id }) => (id ? { project: p, key, id } : { project: p, key }));
  let state;
  try {
    const res = await fetch(`${JOBS}/api/waiting/state`, {
      method: 'POST',
      headers: { authorization: `Bearer ${env.HARNESS_SECRET}`, 'content-type': 'application/json' },
      body: JSON.stringify({ tickets })
    });
    if (res.status !== 200) return out(200, { ok: false, unavailable: `jobs state read failed (${res.status})` });
    state = await res.json();
  } catch {
    return out(200, { ok: false, unavailable: 'jobs state read failed (unreachable or not JSON)' });
  }
  if (!state || !Array.isArray(state.triage) || !Array.isArray(state.queue)) {
    return out(200, { ok: false, unavailable: 'jobs state read failed (bad body)' });
  }
  return out(200, classifyWaiting(snapshot, state, { project }));
}

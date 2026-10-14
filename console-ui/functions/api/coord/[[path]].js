// Cloudflare Pages Function: /api/coord/* -> the harness-jobs worker.
//
// The coordination DB (jobs, heartbeats, ledgers, burn, pause flags) lives in
// its own worker, authed with HARNESS_SECRET — the bearer every box holds. That
// secret must never reach the browser, so the page calls this same-origin path
// and the bearer is attached HERE, in the Pages runtime.
//
// AUTHORISATION IS DELEGATED, ON PURPOSE. The `dash` cookie is minted and
// validated by the console worker; this function does not know its shape and
// deliberately does not learn it — a second copy of a session rule is a second
// place for it to drift. Instead the incoming cookie is presented to the
// console worker's own authed endpoint, and only a 200 buys the proxy. So there
// is exactly one definition of "signed in", and rotating DASH_SECRET on the
// console revokes access here in the same moment.
//
// Env this needs (Pages project -> Settings -> Environment variables):
//   HARNESS_SECRET  — same value as the boxes' env/global.env
// Without it every call answers 503 with that in the body, rather than 401ing
// as though the operator were signed out.
//   CF_ACCESS_TEAM_DOMAIN, CF_ACCESS_AUD — optional (BH-2515): with both set
// and Access in front of the host, writes carry the operator's email as actor;
// without them they carry 'console' (see functions/_lib/access-identity.js).

import { resolveIdentity, FALLBACK_ACTOR } from '../../_lib/access-identity.js';
import { readOnlyRefusal } from '../../_lib/qa-session.js';
import { importTheme, CUSTOM_KEY_RE, CUSTOM_PREFIX } from '../../../src/theme/custom.js';
import { isStr, isScalar, jsonError } from '../../_lib/coord-writes.js';
import { checkWrites } from '../../_lib/coord-writes-compose.js';
import { FRAGMENT_WRITES } from '#coord-writes';

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
// The authed read used as the session check. It is the app's own 30s poll, so
// it is the endpoint most likely to be warm and least likely to be removed.
const AUTH_PROBE = '/api/dash/fleet';

// WHO DID A WRITE is the proxy's to say, never the browser's (BH-1946 review,
// widened to every write by BH-2405). Every write the proxy admits has its
// `actor` stamped HERE, overwriting any client value: in the body, or in the
// query string for the call-guard reset DELETE (BH-2331). The `dash` session is
// one shared operator login (DASH_SECRET) with no per-user identity in it, so
// the identity it authenticates is the console itself: 'console', the same
// actor every console write already names (lib/settings.js, lib/models.js).
// BH-2515: the one lookup is writeActor below. When Cloudflare Access sits in
// front of this host and its signed assertion verifies, the actor is the
// operator's Access email; otherwise it is SESSION_ACTOR. Never a header the
// browser can set on its own. The alert row actions (BH-2324: POST
// alerts/actions, audited per actor in alert_actions) are stamped the same way.
const SESSION_ACTOR = FALLBACK_ACTOR;
const writeActor = async (request, env) => (await resolveIdentity(request, env)).actor;
// BH-2323: an operator RETRY / REQUEUE on one job. The id segment is one path
// segment and never `.` or `..`.
const JOB_ACTION = /^jobs\/([^/]+)\/(retry|requeue)$/;
const isJobAction = (rest) => {
  const m = JOB_ACTION.exec(rest);
  return Boolean(m) && m[1] !== '.' && m[1] !== '..';
};
// BH-2406: ABANDON on one job, the worker's audited move to the terminal
// `abandoned`. Same one-segment id rule.
const JOB_ABANDON = /^jobs\/([^/]+)\/abandon$/;
const isJobAbandon = (rest) => {
  const m = JOB_ABANDON.exec(rest);
  return Boolean(m) && m[1] !== '.' && m[1] !== '..';
};

// THE WRITE SURFACE (BH-2405): the row contract is in functions/_lib/coord-writes.js.
// BH-6487: WRITES is closed. A new write route is a new file,
// functions/_lib/coord-writes.d/<NNNN>-<slug>.js, never a row appended here.
// BH-5353: one participant decision on a worker-minted (crypto.randomUUID) id.
const PARTICIPANT_ID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const participantDecision = (verb) => {
  const re = new RegExp(`^participants\\/${PARTICIPANT_ID}\\/${verb}$`);
  return (rest) => re.test(rest);
};
const WRITES = [
  // BH-4153: the /flags screen. PUT `flags` also carries `scope` and `value`.
  // BH-5643: `value` is the flag file's content, e.g. a wip limit.
  { method: 'PUT', path: 'flags', body: ['name', 'active', 'reason', 'scope', 'value'] },
  // #1132: a knob is a PUT `settings`.
  // BH-2378: PUT `settings` carries the /config EDIT's reason. Optional here,
  // because the SETTINGS page's knob writes send none.
  { method: 'PUT', path: 'settings', body: ['key', 'value', 'note', 'reason'] },
  // BH-1510.3 (and the next row): a role's ladder is a PUT `model-routes`; dropping an override is
  // POST `model-routes/reset`. Both audited in model_route_changes.
  { method: 'PUT', path: 'model-routes', body: ['role', 'project', 'ladder', 'expected_version', 'expected_hub_version', 'reason', 'confirm'] },
  { method: 'POST', path: 'model-routes/reset', body: ['role', 'project', 'expected_version', 'expected_hub_version', 'reason'] },
  // BH-2512 (and the next row): the Models page's REMOVE ROUTE (POST `model-routes/remove`) and
  // price-source toggle (PUT `model-prices/source`). `project` IS forwarded on
  // the remove so the worker's hub-only 400 stays the gate; dropping it here
  // would turn a project remove into a hub one. The price source takes strings
  // only and never `vendor`: vendor rates stay a jobs-client.sh action.
  { method: 'POST', path: 'model-routes/remove', body: ['role', 'project', 'expected_version', 'reason'] },
  { method: 'PUT', path: 'model-prices/source', body: ['model', 'price_source'], ok: isStr },
  // #1132 (and the next row): the master switch is POST `lanes/all-off|all-on`.
  { method: 'POST', path: 'lanes/all-off', body: ['reason'] },
  { method: 'POST', path: 'lanes/all-on', body: ['reason'] },
  // BH-2105: the /hub PROMOTE modal; the worker re-checks confirm and
  // expected_epoch. `ttl_s`, `override_live_lease` and the holder/expect_epoch
  // aliases are the worker's box-side contract and never come from a browser.
  { method: 'POST', path: 'hub/promote', body: ['target', 'expected_epoch', 'reason', 'confirm'] },
  // BH-1946: the /hub RESTORE LAB request; the worker re-checks confirm.
  { method: 'POST', path: 'hub/restore-lab', body: ['box', 'snapshot', 'confirm'] },
  // BH-2519: the /hub standby VERIFY request (box, confirm); the worker re-checks
  // confirm and the standby row. claim, <id>/result and heartbeat are box-side
  // and stay 405.
  { method: 'POST', path: 'hub/standby/verify', body: ['box', 'confirm'] },
  // BH-2518: POST `box-commands` exactly, a box/machine op request (no page
  // calls it yet). Flat scalars (project and app, never a nested args), no `ok`, so
  // a boolean confirm passes like restore-lab. claim and :id/result are the
  // box lane's routes and stay 405 from a browser.
  // BH-5750: the Orgo and Fly pool controls add their args and the price
  // token (quote_id, confirm_monthly_usd), forwarded as sent; the worker
  // validates them and gates every one of those types on the stamped actor.
  { method: 'POST', path: 'box-commands', body: ['box', 'type', 'target', 'project', 'app', 'reason', 'confirm',
    'account', 'vcpus', 'mem_gb', 'disk_gb', 'to', 'ip', 'delete', 'cap', 'quote_id', 'confirm_monthly_usd'] },
  // BH-2323: RETRY / REQUEUE on one job; `detail` only, as a string, because the
  // worker's requeue reads max_attempts and a click must not lift that cap.
  { method: 'POST', path: isJobAction, body: ['detail'], ok: isStr, rowOrder: true },
  // BH-2406: ABANDON on one job; `reason` only, as a string. The worker
  // re-checks the transition.
  { method: 'POST', path: isJobAbandon, body: ['reason'], ok: isStr, rowOrder: true },
  // BH-2329.3: the Project page's main-red CLEAR (exact path); name, reason and
  // sha as strings. The worker requires a reason and re-checks the sha.
  { method: 'POST', path: 'main-red/clear', body: ['name', 'reason', 'sha'], ok: isStr, rowOrder: true },
  // BH-2405: POST `alerts/actions`; strings or finite numbers only, and
  // `action` a string, so an array never reaches the worker's String().
  { method: 'POST', path: 'alerts/actions', body: ['id', 'akey', 'action', 'reason', 'snooze_s', 'note'], ok: isScalar },
  // BH-2328: the Project page's HALT toggle, a PUT to `routing` exactly (not
  // routing/<p>, not routing-changes); haltOnlyBody rebuilds its body.
  { method: 'PUT', path: 'routing', body: ['project', 'halted', 'reason'], build: (sent, env) => haltOnlyBody(sent, env) },
  // BH-2521 (and the next row): the /hub SEED REGISTRY apply (POST settings/seed-registry/apply,
  // plan_fp as a string; the plain CLI POST settings/seed-registry stays 405
  // from a browser) and the CHAT BINDINGS edit (PUT telegram-topics; project a
  // string, thread_id an integer). BH-2995: both carry a required reason; a
  // `reasonRequired` row with a blank or non-string one is refused 400 here.
  { method: 'POST', path: 'settings/seed-registry/apply', body: ['plan_fp', 'reason'], ok: isStr, reasonRequired: true },
  { method: 'PUT', path: 'telegram-topics', body: ['project', 'thread_id', 'reason'], ok: (k, v) => (k === 'thread_id' ? Number.isInteger(v) : typeof v === 'string'), reasonRequired: true },
  // BH-2331: the COST BREAKER RESET is a DELETE to `call-guard` exactly (never
  // call-guard/claim or /settle); its fields are query parameters, no body.
  { method: 'DELETE', path: 'call-guard', body: null, query: ['project', 'stage', 'fp', 'reason'] },
  // BH-4153: the /flags CLEAR is a DELETE to `flags` exactly (never
  // flags/<name>), its fields name, scope and reason as query parameters, no
  // body, reason required (400 here), the call-guard RESET's shape.
  { method: 'DELETE', path: 'flags', body: null, query: ['name', 'scope', 'reason'] },
  // BH-4846: deleting a custom theme, a DELETE to `settings/ui.theme.custom.<slug>`
  // exactly (no other settings row is deletable from anywhere); no body,
  // `reason` in the query, the actor stamped there. A PUT `settings` to that
  // prefix is checked by the theme validator before it is forwarded (themeWriteError).
  { method: 'DELETE', path: (rest) => /^settings\/ui\.theme\.custom\.[a-z0-9-]{1,40}$/.test(rest), body: null, query: ['reason'] },
  // BH-2563 (BH-2511.0): the Costs page's cap edit, a PUT to `cost-caps` exactly
  // (never cost-caps/seed, which is hub-bearer only); strings only.
  { method: 'PUT', path: 'cost-caps', body: ['key', 'value', 'reason'], ok: isStr },
  // BH-2634: the /ci QUARANTINE toggle, a PUT to `metrics/flakes/quarantine`
  // exactly (never the `metrics/flakes` ledger). The worker audits every change.
  { method: 'PUT', path: 'metrics/flakes/quarantine', body: ['repo', 'test', 'active', 'reason'] },
  // BH-2513 (and the next three rows): the Controls editors' PUTs (review-gate/thresholds, rules,
  // retry-policies, contracts). needsReason: a blank or non-string reason is a
  // 400 here. DELETE rules and PUT review-gate stay off the table.
  { method: 'PUT', path: 'review-gate/thresholds', body: ['scope', 'window_days', 'min_merges', 'tighten_rate', 'clear_rate', 'note', 'reason'], needsReason: true },
  { method: 'PUT', path: 'rules', body: ['scope', 'selector', 'kind', 'max_concurrent', 'note', 'reason'], needsReason: true },
  { method: 'PUT', path: 'retry-policies', body: ['lane', 'max_attempts', 'backoff_seconds', 'escalate_allowed', 'note', 'reason'], needsReason: true },
  { method: 'PUT', path: 'contracts', body: ['phase', 'artifact_kind', 'pattern', 'note', 'reason'], needsReason: true },
  // BH-4082: the Controls Projects editor, a PUT to `projects` exactly, with a
  // required reason like the four rows above. There is no DELETE projects.
  { method: 'PUT', path: 'projects', body: ['project', 'repo', 'prod_url', 'board_api_prefix', 'cron_offset', 'box', 'tailnet_ip', 'note', 'reason'], needsReason: true },
  // BH-3157 (BH-2325.2) (and the next row): the merge queue's row edit, a PATCH to `merge-queue`
  // exactly, and the conductor's held-page release, a POST to
  // `conductor/held/release` exactly. Both bodies are rebuilt by a validator
  // below (mergeQueueBody, heldReleaseBody). POST merge-queue (enqueue) and
  // every write to `conductor/held` stay 405.
  { method: 'PATCH', path: 'merge-queue', body: ['project', 'pr', 'status', 'reason'], build: (sent) => mergeQueueBody(sent) },
  { method: 'POST', path: 'conductor/held/release', body: ['repo', 'number', 'state', 'head', 'kind', 'why'], build: (sent) => heldReleaseBody(sent) },
  // BH-2510 (and the next row): the Project page's QUEUES actions, POST `queue/action` and POST
  // `deploy-queue/action` exactly; strings only, reason required (400 here).
  // The raw PATCH queue and the claim/depart routes stay 405 from a browser.
  { method: 'POST', path: 'queue/action', body: ['project', 'key', 'action', 'reason'], ok: isStr, needsReason: true },
  { method: 'POST', path: 'deploy-queue/action', body: ['project', 'sha', 'action', 'reason'], ok: isStr, needsReason: true },
  // BH-4147: the /settings PROTECTED PATHS add/remove, a PUT to
  // `lead-protected-paths` exactly; protectedPathBody rebuilds it, and the
  // stamped actor is its `added_by`. POST, DELETE and PATCH stay 405.
  { method: 'PUT', path: 'lead-protected-paths', body: ['repo', 'glob', 'op'], build: (sent, _env, actor) => protectedPathBody(sent, actor) },
  // BH-5353: the participants screen's APPROVE, DENY and REVOKE, a POST to
  // `participants/<uuid>/approve|deny|revoke` exactly (request and any other
  // shape stay 405). approve forwards granted_roles (participantApproveBody);
  // deny and revoke forward the actor only. `leadToken` rows, and only they,
  // carry this Pages project's LEAD_VERDICT_TOKEN as x-lead-verdict-token;
  // without it they answer 503 and forward nothing.
  { method: 'POST', path: participantDecision('approve'), body: ['granted_roles'], build: (sent) => participantApproveBody(sent), leadToken: true },
  { method: 'POST', path: participantDecision('deny'), body: [], leadToken: true },
  { method: 'POST', path: participantDecision('revoke'), body: [], leadToken: true }
];
// Every write row: WRITES, then the coord-writes.d/ fragments in name order.
// A duplicate (method, string path) refuses to load rather than shadow a row.
export const ROUTES = checkWrites([...WRITES, ...FRAGMENT_WRITES]);
// BH-5839: GETs that only a box makes. Every other GET passes as-is; these are
// 405 from a browser, the same as a write that is not a ROUTES row.
const BOX_ONLY_GETS = ['steer/outbox'];
const writeRoute = (method, rest) => ROUTES.find((w) =>
  w.method === method && (typeof w.path === 'function' ? w.path(rest) : w.path === rest)) || null;

// The forwarded body: the row's fields the browser sent, then the stamped
// actor (writeActor's answer for this request). Own keys only, so a
// `__proto__` key in the JSON is just an unlisted field and is dropped. A
// plain row keeps the browser's key order with the actor where the browser put
// it (the `{...sent, actor}` spread these routes always forwarded); a
// `rowOrder` row forwards in the row's order with the actor last, the exact
// shape of its pre-table allowlist (job actions, CLEAR).
function pickBody(sent, row, actor) {
  const keep = (k) => Object.prototype.hasOwnProperty.call(sent, k) && (!row.ok || row.ok(k, sent[k]));
  const out = {};
  const keys = row.rowOrder ? row.body : Object.keys(sent);
  for (const k of keys) {
    if (k === 'actor') out.actor = actor;
    else if (row.body.includes(k) && keep(k)) out[k] = sent[k];
  }
  out.actor = actor;
  return out;
}

// BH-4846: a custom theme row is fleet-visible (every viewer's picker paints
// it), so its value is validated HERE, by the same validator the editor and
// import use (src/theme/custom.js): known keys only, real colours, the
// self-hosted fonts, radii in range, every text pair at 4.5:1. A 400 with
// the validator's errors, or null for any other key.
function themeWriteError(sent) {
  if (typeof sent.key !== 'string' || !sent.key.trim().startsWith(CUSTOM_PREFIX)) return null;
  const key = sent.key.trim();
  if (!CUSTOM_KEY_RE.test(key)) return jsonError(400, `a custom theme key is ${CUSTOM_PREFIX}<slug>, the slug 1-40 of a-z 0-9 -`);
  const res = typeof sent.value === 'string' ? importTheme(sent.value) : { ok: false, errors: ['value must be the theme JSON as a string'] };
  if (res.ok) return null;
  return new Response(JSON.stringify({ error: `${key} is not a valid theme: ${res.errors.join('; ')}`, errors: res.errors }), {
    status: 400, headers: { 'content-type': 'application/json' }
  });
}

// halted as the worker accepts it, or null when it is anything else.
function haltedFlag(v) {
  if (v === true || v === 1 || v === '1' || v === 'true') return 1;
  if (v === false || v === 0 || v === '0' || v === 'false') return 0;
  return null;
}

// THE CONSOLE'S ROUTING WRITE IS HALT-ONLY, and that is enforced HERE, not in
// the page (BH-2328 review). The worker's PUT /api/routing is a full upsert of
// builder, pool_app and halted, so forwarding the browser's body would let a
// forged request re-route a project or create a row. Only {project, halted,
// reason} is read from the browser; builder and pool_app are copied from the
// row as the worker holds it now, so the write can change nothing but halted.
// No row is a refusal: a HALT never creates one. An UNHALT lifts a halt someone
// set on purpose, so it must say why. The row's updated_at rides along as
// expected_updated_at (BH-2488), so the worker answers 409 instead of writing
// when the row moved between this read and the PUT; a browser-sent guard is
// dropped like every other browser field. Returns {body} or {error: Response}.
async function haltOnlyBody(sent, env) {
  const project = typeof sent.project === 'string' ? sent.project : '';
  if (!project) return { error: jsonError(400, 'project required') };
  const halted = haltedFlag(sent.halted);
  if (halted === null) return { error: jsonError(400, 'halted must be 0 or 1') };
  const reason = typeof sent.reason === 'string' ? sent.reason.trim() : '';
  if (halted === 0 && !reason) return { error: jsonError(400, 'an UNHALT needs a reason') };
  let res;
  try {
    res = await fetch(new URL(`/api/routing/${encodeURIComponent(project)}`, JOBS).toString(), {
      method: 'GET', headers: { authorization: `Bearer ${env.HARNESS_SECRET}` }
    });
  } catch {
    return { error: jsonError(502, 'could not read the routing row: harness-jobs unreachable') };
  }
  if (res.status === 404) return { error: jsonError(404, `no routing row for ${project}; the console only halts an existing row`) };
  const row = res.ok ? ((await res.json().catch(() => null)) || {}).routing : null;
  if (!row || typeof row.builder !== 'string') {
    return { error: jsonError(502, `could not read the routing row (http ${res.status})`) };
  }
  const body = { project: row.project ?? project, builder: row.builder, pool_app: row.pool_app ?? null, halted };
  if (reason) body.reason = reason;
  if (typeof row.updated_at === 'string' && row.updated_at !== '') body.expected_updated_at = row.updated_at;
  return { body };
}

const positiveInt = (v) => typeof v === 'number' && Number.isInteger(v) && v > 0;
const nonBlank = (v) => typeof v === 'string' && v.trim() !== '';

// BH-3157: the merge-queue PATCH. The console moves a row between queued,
// blocked and dropped; it never records a landing (the conductor does). Types
// are checked, never coerced: pr '41' is a 400, not 41. Values that pass go
// through as sent; the worker still checks the project and the transition.
// Returns {body} or {error: Response}.
const MQ_STATUSES = Object.freeze(['queued', 'blocked', 'dropped']);
function mergeQueueBody(sent) {
  const { project, pr, status, reason } = sent;
  if (!nonBlank(project)) return { error: jsonError(400, 'project required') };
  if (!positiveInt(pr)) return { error: jsonError(400, 'pr must be a positive integer') };
  if (status === 'landed') return { error: jsonError(400, 'status landed is refused: the console never records a landing') };
  if (!MQ_STATUSES.includes(status)) return { error: jsonError(400, `status must be one of ${MQ_STATUSES.join(', ')}`) };
  if (!nonBlank(reason)) return { error: jsonError(400, 'a reason is required') };
  return { body: { project, pr, status, reason } };
}

// BH-3157: releasing one held conductor page. The four key fields are strings
// (the worker's holdKey checks their values), number a positive integer, and
// why non-blank. Returns {body} or {error: Response}.
function heldReleaseBody(sent) {
  for (const k of ['repo', 'state', 'head', 'kind']) {
    if (typeof sent[k] !== 'string') return { error: jsonError(400, `${k} must be a string`) };
  }
  if (!positiveInt(sent.number)) return { error: jsonError(400, 'number must be a positive integer') };
  if (!nonBlank(sent.why)) return { error: jsonError(400, 'a why is required') };
  const { repo, number, state, head, kind, why } = sent;
  return { body: { repo, number, state, head, kind, why } };
}

// BH-4147: one protected-path add or remove. repo and glob are strings and op
// is exactly add or remove; nothing is coerced. The worker still checks repo
// and glob themselves (normRepo, validGlob). added_by is the proxy's actor,
// never the browser's. Returns {body} or {error: Response}.
function protectedPathBody(sent, actor) {
  const { repo, glob, op } = sent;
  if (typeof repo !== 'string' || typeof glob !== 'string') return { error: jsonError(400, 'repo and glob must be strings') };
  if (op !== 'add' && op !== 'remove') return { error: jsonError(400, 'op must be add or remove') };
  return { body: { repo, glob, op, added_by: actor } };
}

// BH-5353: an APPROVE's grant. A non-empty list of at most 8 role names, each
// a 1..32 char string; nothing is coerced. The worker still checks it is a
// subset of the row's requested_roles. Returns {body} or {error: Response}.
function participantApproveBody(sent) {
  const g = sent.granted_roles;
  const ok = Array.isArray(g) && g.length > 0 && g.length <= 8 &&
    g.every((r) => typeof r === 'string' && r.length >= 1 && r.length <= 32);
  if (!ok) return { error: jsonError(400, 'granted_roles must be a non-empty array of role names') };
  return { body: { granted_roles: g } };
}

// Verdicts are cached per cookie for a minute so a 15s-refreshing jobs view
// does not double every poll into two worker calls. Module scope on a Pages
// isolate is best-effort by nature: a cold isolate simply re-checks.
const seen = new Map();
const TTL_MS = 60000;

async function signedIn(cookie) {
  if (!cookie) return false;
  const now = Date.now();
  const hit = seen.get(cookie);
  if (hit && now - hit.at < TTL_MS) return hit.ok;
  let ok = false;
  try {
    const res = await fetch(CONSOLE + AUTH_PROBE, { headers: { cookie }, redirect: 'manual' });
    ok = res.status === 200;
  } catch {
    // The console being unreachable is NOT a grant. It fails closed: an
    // operator sees "could not verify the session", never someone else's data.
    ok = false;
  }
  seen.set(cookie, { ok, at: now });
  return ok;
}

export async function onRequest(context) {
  const { request, env, params } = context;
  const url = new URL(request.url);

  // A QA session (cromford #5909) reads and never writes: its GET probe
  // passes signedIn below, so a write is refused here, first.
  const qaRefused = readOnlyRefusal(request);
  if (qaRefused) return qaRefused;

  if (!env.HARNESS_SECRET) {
    return new Response(JSON.stringify({
      error: 'HARNESS_SECRET is not set on this Pages project — the coordination view cannot authenticate to harness-jobs'
    }), { status: 503, headers: { 'content-type': 'application/json' } });
  }

  const cookie = request.headers.get('cookie') || '';
  if (!(await signedIn(cookie))) {
    // The same shape src/api.js already treats as "not signed in".
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 403, headers: { 'content-type': 'application/json' }
    });
  }

  // /api/coord/<rest> -> <jobs worker>/api/<rest>. A GET passes as-is, query
  // and all; a write passes only if it is a row of ROUTES, and a job cannot be
  // PATCHed from a browser (stage/status transitions belong to the box doing
  // the work).
  const rest = Array.isArray(params.path) ? params.path.join('/') : (params.path || '');
  // BH-2515: who this session writes as, answered here (the jobs worker has no
  // such route). Plain GETs skip the resolution so the polls pay no crypto.
  if (request.method === 'GET' && rest === 'whoami') {
    const who = await resolveIdentity(request, env);
    return new Response(JSON.stringify(who), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  const row = request.method === 'GET' ? null : writeRoute(request.method, rest);
  if ((request.method !== 'GET' && !row) || (request.method === 'GET' && BOX_ONLY_GETS.includes(rest))) {
    return new Response(JSON.stringify({ error: `method ${request.method} not allowed on /api/coord/${rest}` }), {
      status: 405, headers: { 'content-type': 'application/json' }
    });
  }

  // BH-2397: the RESET reason is enforced here, not only in the browser's modal.
  // A blank one is refused before anything is forwarded; the worker's own
  // "manual reset" default is left for the box CLI path (bin/jobs-client.sh).
  if (request.method === 'DELETE' && rest === 'call-guard' && (url.searchParams.get('reason') || '').trim() === '') {
    return new Response(JSON.stringify({ error: 'a reason is required to reset the call guard' }), {
      status: 400, headers: { 'content-type': 'application/json' }
    });
  }
  // BH-4153: a flag CLEAR needs a reason the same way.
  if (request.method === 'DELETE' && rest === 'flags' && (url.searchParams.get('reason') || '').trim() === '') {
    return jsonError(400, 'a reason is required to clear a flag');
  }

  // BH-5353: a participant decision authenticates to the worker with the lead
  // token as well as the bearer. Refused before anything is forwarded when the
  // Pages project does not have it.
  const lead = row && row.leadToken ? (env.LEAD_VERDICT_TOKEN || '').trim() : '';
  if (row && row.leadToken && !lead) {
    return jsonError(503, 'LEAD_VERDICT_TOKEN is not set on this Pages project — participant decisions cannot authenticate to harness-jobs');
  }

  const target = new URL(`/api/${rest}`, JOBS);
  // The one actor every stamp below writes, resolved once per admitted write.
  const actor = row ? await writeActor(request, env) : SESSION_ACTOR;
  if (!row) {
    target.search = url.search;
  } else {
    for (const k of row.query || []) {
      for (const v of url.searchParams.getAll(k)) target.searchParams.append(k, v);
    }
    // A body-less write's actor rides in the query string, stamped over
    // whatever the browser sent.
    if (!row.body) target.searchParams.set('actor', actor);
  }
  const init = {
    method: request.method,
    headers: {
      authorization: `Bearer ${env.HARNESS_SECRET}`,
      'content-type': 'application/json'
    }
  };
  if (lead) init.headers['x-lead-verdict-token'] = lead;
  if (row && row.body) {
    // A body that is not a JSON object is refused rather than forwarded:
    // passing it through unparsed would pass its actor through too.
    let sent = null;
    try { sent = JSON.parse(await request.text()); } catch { sent = null; }
    if (!sent || typeof sent !== 'object' || Array.isArray(sent)) {
      return new Response(JSON.stringify({ error: `a ${request.method} to /api/coord/${rest} must carry a JSON object body` }), {
        status: 400, headers: { 'content-type': 'application/json' }
      });
    }
    if (row.reasonRequired && (typeof sent.reason !== 'string' || !sent.reason.trim())) return jsonError(400, 'reason required');
    if (row.needsReason && (typeof sent.reason !== 'string' || sent.reason.trim() === '')) {
      return jsonError(400, 'a reason is required');
    }
    if (request.method === 'PUT' && rest === 'settings') {
      const bad = themeWriteError(sent);
      if (bad) return bad;
    }
    // A row with `build` rebuilds its body from the worker's own state (the
    // routing PUT: haltOnlyBody); every other row forwards its allowlist.
    if (row.build) {
      const built = await row.build(sent, env, actor);
      if (built.error) return built.error;
      init.body = JSON.stringify({ ...built.body, actor });
    } else init.body = JSON.stringify(pickBody(sent, row, actor));
  }

  let upstream;
  try {
    upstream = await fetch(target.toString(), init);
  } catch (e) {
    return new Response(JSON.stringify({ error: 'harness-jobs unreachable' }), {
      status: 502, headers: { 'content-type': 'application/json' }
    });
  }
  const out = new Headers(upstream.headers);
  out.delete('content-encoding');
  out.delete('content-length');
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
}

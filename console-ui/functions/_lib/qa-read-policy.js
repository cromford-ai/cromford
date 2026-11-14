// The QA read policy (BH-9263): what a QA preview session may read from
// harness-jobs, and which fields of each answer it gets back.
//
// A QA session (a `dashqa` cookie, functions/_lib/qa-session.js) runs
// unreviewed preview JS. So it reads only the routes below, only with the
// listed query parameters, and every answer is cut down to the listed keys.
// An unknown route, query parameter, top-level key or column is dropped. A new
// column on a jobs row stays hidden from a QA session until a row here lists it.
//
// TWO READERS, ONE POLICY, TWO BYTE-IDENTICAL COPIES. The coord proxy
// (console-ui/functions/api/coord/[[path]].js) reads
// console-ui/functions/_lib/qa-read-policy.js, before it forwards and again on
// the answer. The jobs worker (worker/jobs/src/lib/qa-read.js) reads
// worker/jobs/src/lib/qa-read-policy.js for a QA_READ_TOKEN bearer. Each deploy
// bundles only its own tree: a console preview copies only console-ui/functions
// and console-ui/src, and the worker deploy snapshot (bin/harness-sync.sh
// snapshot_tree) holds worker/, catalog/ and agent-core/. So edit both files
// together: worker test J9 and tests/qa-read-token.bh-9263-test.sh fail when
// they differ.
//
// The allowlist is code, not a settings row, on purpose: a HARNESS_SECRET
// holder must not be able to widen what the separate token opens. `whoami` is
// on the QA list too, but Pages answers it itself (no jobs call), so it is not
// a row here. To widen the list, read the `qa-read: refused GET <route>` lines
// in the Pages log (docs/notes/2026-11-13-BH-9263-qa-read-token.md).
//
// Pure: no imports, no I/O.

const freeze = (row) => Object.freeze({
  query: Object.freeze(row.query), top: Object.freeze(row.top), list: row.list, fields: Object.freeze(row.fields),
});

export const QA_READ_ROUTES = Object.freeze({
  jobs: freeze({
    query: ['project', 'status', 'box', 'ticket_id', 'kind', 'limit', 'stale_min'],
    top: ['jobs', 'as_of'],
    list: 'jobs',
    fields: ['id', 'project', 'ticket_id', 'kind', 'box', 'stage', 'status', 'created_at', 'updated_at',
      'issue_created_at', 'first_spawn_at', 'last_beat_at', 'beat_age_s', 'activity_age_s', 'heartbeating',
      'age_s', 'phase', 'phase_status', 'phase_rc', 'failed_phase', 'lane', 'attempts', 'max_attempts',
      'next_attempt_at', 'retry_reason', 'budget_usd', 'spent_usd'],
  }),
  flags: freeze({
    query: ['scope', 'prefix', 'active'],
    top: ['flags', 'as_of', 'truncated'],
    list: 'flags',
    fields: ['scope', 'name', 'active', 'set_by', 'reason', 'set_at', 'cleared_at', 'updated_at'],
  }),
});

const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

// qaReadPolicy <rest> — the route's row, or null. <rest> is the path after
// /api/ (coord: after /api/coord/). Exact match only: no prefix, no case fold.
export function qaReadPolicy(rest) {
  if (typeof rest !== 'string' || !own(QA_READ_ROUTES, rest)) return null;
  return QA_READ_ROUTES[rest];
}

// qaReadQuery <row> <URLSearchParams> — a new URLSearchParams with only the
// row's query parameters, in their sent order.
export function qaReadQuery(row, params) {
  const out = new URLSearchParams();
  for (const [k, v] of params) if (row.query.includes(k)) out.append(k, v);
  return out;
}

// projectQaBody <rest> <body> — the body cut to the row's keys, or null when
// the route is not on the list or the body is not a JSON object. Inside the
// list key, each row keeps only the listed fields; a list entry that is not an
// object is dropped.
export function projectQaBody(rest, body) {
  const row = qaReadPolicy(rest);
  if (!row || !isObj(body)) return null;
  const out = {};
  for (const k of row.top) {
    if (!own(body, k)) continue;
    if (k !== row.list) { out[k] = body[k]; continue; }
    const list = Array.isArray(body[k]) ? body[k] : [];
    out[k] = list.filter(isObj).map((item) => {
      const kept = {};
      for (const f of row.fields) if (own(item, f)) kept[f] = item[f];
      return kept;
    });
  }
  return out;
}

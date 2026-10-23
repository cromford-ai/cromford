#!/bin/bash
# tests/routing-cas-proxy.bh-2488-test.sh — the console's HALT write is a
# compare-and-swap end to end (BH-2488, the proxy + UI half of BH-2459).
#
# The coord proxy's haltOnlyBody reads the routing row, copies builder and
# pool_app from it, and now forwards that row's updated_at as
# expected_updated_at. The worker (worker/jobs/src/routes/routing.js, #2482)
# answers 409 when the row moved between that read and the PUT, so a stale
# HALT can no longer revert a builder change made in the window.
#
# Driven for real: the REAL proxy onRequest, whose upstream fetch is routed
# into the REAL worker fetch handler over node:sqlite built from
# worker/jobs/schema.sql (the D1 shim of worker/jobs/test/routing-cas.bh-2459).
#
#   C1. a concurrent unguarded builder change inside the proxy's read -> PUT
#       window: the HALT answers 409, the row keeps builder=local halted=0,
#       and routing_changes holds only the builder's row (nothing reverted).
#   C2. no concurrent change: the HALT answers 200, halted=1, builder=pool
#       kept, one audit row with actor console.
#   C3. the forwarded expected_updated_at is the row's own stamp, whatever
#       the browser sent as expected_updated_at or updated_at.
#   N.  the node suite console-ui/tests/routing-cas.bh-2488.test.js (the 409
#       copy, the no-retry rule and the mounted panel's reload), run when the
#       console-ui dependencies are installed.
# Run from anywhere: tests/routing-cas-proxy.bh-2488-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
LIB="$DIR/console-ui/src/lib/routing.js"
WORKER="$DIR/worker/jobs/src/index.js"
SCHEMA="$DIR/worker/jobs/schema.sql"

for f in "$PROXY" "$LIB" "$WORKER" "$SCHEMA"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "routing-cas-proxy: SKIPPED — node is not installed on this box"; exit 0; }

# The worker imports catalog/lanes.json four levels above src/lib/core.js, and
# that file is GENERATED and git-ignored (BH-1247). So the worker's sources run
# from a scratch copy whose catalog/ holds this repo's own render.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
W="$T/w"
mkdir -p "$W/worker/jobs" "$W/catalog"
cp -R "$(dirname "$WORKER")" "$W/worker/jobs/src" || bad "cannot copy the worker sources"
# TEST-CHANGE (BH-4987): core.js resolves `#schema-sql` through the worker's
# package.json, and under Node that composes schema.d/ through test/lib/, so
# the scratch tree carries all three beside src/.
cp "$DIR/worker/jobs/package.json" "$W/worker/jobs/" || bad "cannot copy the worker package.json (BH-4987)"
cp -R "$DIR/worker/jobs/schema.d" "$W/worker/jobs/schema.d" || bad "cannot copy worker/jobs/schema.d (BH-4987)"
mkdir -p "$W/worker/jobs/test/lib" || bad "cannot create the worker test/lib (BH-4987)"
cp "$DIR/worker/jobs/test/lib/jobs-schema.js" "$DIR/worker/jobs/test/lib/schema-sql.node.js" "$W/worker/jobs/test/lib/" \
  || bad "cannot copy the Node schema composer (BH-4987)"
# TEST-CHANGE (BH-4607): index.js imports ROUTES from `#routes`, which under
# Node is test/lib/routes.node.js reading test/route-table.d/, so the scratch
# tree carries both.
cp "$DIR/worker/jobs/test/lib/routes.node.js" "$W/worker/jobs/test/lib/" \
  && cp -R "$DIR/worker/jobs/test/route-table.d" "$W/worker/jobs/test/route-table.d" \
  || bad "cannot copy the Node route loader and test/route-table.d (BH-4607)"
# The staff routes import agent-core/ by a relative path (BH-5559), so the
# scratch tree carries it beside worker/, as the deployed bundle does.
cp -R "$DIR/agent-core" "$W/agent-core" || bad "cannot copy agent-core (the worker imports it, BH-5559)"
cp "$(rendered_registry)" "$W/catalog/lanes.json" || bad "cannot place the rendered lane registry"
cp "$DIR/catalog/llm-sites.json" "$W/catalog/" || bad "cannot place the LLM sites catalog (the worker imports it, BH-2553)"
cp "$DIR/catalog/context-budgets.json" "$W/catalog/" || bad "cannot place the context budgets (the worker imports them, BH-2554)"
cp "$DIR/catalog/prompt-markers.json" "$W/catalog/" || bad "cannot place the prompt markers (the worker imports them, BH-7940)"

# --- C1..C3: the real proxy over the real worker ------------------------------
OUT=$(node --no-warnings --input-type=module -e "
import { readFileSync } from 'node:fs';
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }
if (!DatabaseSync) { console.log('skip node:sqlite is not available'); process.exit(0); }
const { onRequest } = await import('$PROXY');
const worker = (await import('$W/worker/jobs/src/index.js')).default;
const SCHEMA = readFileSync('$SCHEMA', 'utf8');
const SECRET = 'test-harness-secret';
const JOBS = 'https://harness-jobs.operator.workers.dev';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}

const SEEDED = '2026-01-01T00:00:00Z';
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(\"INSERT INTO routing (project, builder, pool_app, halted, updated_at) VALUES ('p','pool','bh-pool-p',0,'\" + SEEDED + \"')\");
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

// Every upstream call the proxy makes goes into worker.fetch; the console's
// auth probe answers 200. onPut runs just before the proxy's PUT is served.
function wire(env, onPut) {
  const puts = [];
  globalThis.fetch = async (input, init = {}) => {
    const u = typeof input === 'string' ? input : input.url;
    if (u.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    if (!u.startsWith(JOBS)) return new Response('{}', { status: 599 });
    if ((init.method || 'GET') === 'PUT') { puts.push(JSON.parse(init.body)); if (onPut) await onPut(); }
    return worker.fetch(new Request(u, init), env);
  };
  return puts;
}

let seq = 0;
const halt = (body) => onRequest({
  request: new Request('https://console.example.pages.dev/api/coord/routing', {
    method: 'PUT', headers: { cookie: 'dash=cas' + (++seq), 'content-type': 'application/json' },
    body: JSON.stringify(body)
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: ['routing'] }
});

const rowOf = (db) => ({ ...db.prepare(\"SELECT builder, halted FROM routing WHERE project='p'\").get() });
const audit = (db) => db.prepare('SELECT actor FROM routing_changes ORDER BY id').all().map((r) => r.actor);

// C1: a builder change lands between the proxy's read and its PUT.
{
  const { db, env } = fresh();
  wire(env, async () => {
    const r = await worker.fetch(new Request(JOBS + '/api/routing', {
      method: 'PUT', headers: { authorization: 'Bearer ' + SECRET, 'content-type': 'application/json' },
      body: JSON.stringify({ project: 'p', builder: 'local', halted: 0, actor: 'builder' })
    }), env);
    eq('C1-concurrent-write', r.status, 200);
  });
  const res = await halt({ project: 'p', halted: 1, reason: 'drill' });
  eq('C1-status', res.status, 409);
  const out = await res.json().catch(() => null);
  eq('C1-body', [out && out.error, out && out.routing && out.routing.builder], ['routing changed underneath you', 'local']);
  eq('C1-row-kept', rowOf(db), { builder: 'local', halted: 0 });
  eq('C1-audit', audit(db), ['builder']);
}

// C2: nothing moved, the HALT lands.
{
  const { db, env } = fresh();
  wire(env);
  const res = await halt({ project: 'p', halted: 1, reason: 'drill' });
  eq('C2-status', res.status, 200);
  eq('C2-row', rowOf(db), { builder: 'pool', halted: 1 });
  eq('C2-audit', audit(db), ['console']);
}

// C3: the guard is the row's stamp, never the browser's.
{
  const { env } = fresh();
  const puts = wire(env);
  await halt({ project: 'p', halted: 1, reason: 'drill', expected_updated_at: '1999', updated_at: 'x' });
  eq('C3-forwarded', puts.map((b) => b.expected_updated_at), [SEEDED]);
}
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "proxy: ${line#no }" ;;
    skip\ *) echo "routing-cas-proxy: C1-C3 SKIPPED — ${line#skip }" ;;
    *) [ -n "$line" ] && bad "proxy: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- N: the node suite, driven -------------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "routing-cas-proxy: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/routing-cas.bh-2488.test.js 2>&1); then ok
  else bad "console-ui/tests/routing-cas.bh-2488.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "routing-cas-proxy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

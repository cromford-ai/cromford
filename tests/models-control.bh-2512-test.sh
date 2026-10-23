#!/bin/bash
# tests/models-control.bh-2512-test.sh — the Models page can remove a route,
# override a price source, and see every stage that has no stage.* route
# (BH-2512).
#
# The worker already had both writes (POST /api/model-routes/remove, BH-1572;
# PUT /api/model-prices/source, BH-1613). What blocked the console was the
# coord proxy's WRITES allowlist, which 405'd both. The unrouted list is an
# opt-in `unrouted_since` on GET /api/model-routes.
#
# Driven for real: the REAL proxy onRequest, whose upstream fetch is routed
# into the REAL worker fetch handler over node:sqlite built from
# worker/jobs/schema.sql (the pattern of tests/routing-cas-proxy.bh-2488-test.sh).
#
#   D1. remove through the proxy: 200, no hub rows left for the role, and the
#       audit rows carry actor console.
#   D2. price source through the proxy: vendor-direct lands, openrouter
#       clears it back to NULL.
#   D3. the ticket's own test end to end: a cost row for an unrouted stage is
#       listed by the proxy's GET; a route PUT through the proxy removes it.
#   N.  the node suites worker/jobs/test/model-routes-unrouted.bh-2512.test.js
#       and console-ui/tests/models-control.bh-2512.test.js (the second only
#       when the console-ui dependencies are installed).
# Run from anywhere: tests/models-control.bh-2512-test.sh   (exit 0 = all pass)
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
ROUTES="$DIR/worker/jobs/src/routes/model-routes.js"
WORKER="$DIR/worker/jobs/src/index.js"
SCHEMA="$DIR/worker/jobs/schema.sql"
WTEST="$DIR/worker/jobs/test/model-routes-unrouted.bh-2512.test.js"
CTEST="$DIR/console-ui/tests/models-control.bh-2512.test.js"
LIB="$DIR/console-ui/src/lib/models.js"
SCREEN="$DIR/console-ui/src/screens/Models.js"
API="$DIR/console-ui/src/api.js"

for f in "$PROXY" "$ROUTES" "$WORKER" "$SCHEMA" "$WTEST" "$CTEST" "$LIB" "$SCREEN" "$API"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "models-control: SKIPPED — node is not installed on this box"; exit 0; }

# The worker imports catalog/lanes.json, which is GENERATED and git-ignored
# (BH-1247), so its sources run from a scratch copy holding this repo's render.
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

# --- D1..D3: the real proxy over the real worker ------------------------------
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
    if (/^\s*(SELECT|PRAGMA|WITH)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
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

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(\"INSERT INTO model_prices (model, slug, prompt, completion, source, updated_at) VALUES ('test-model-a','test/a',1,1,'catalog','2026-09-26T00:00:00Z')\");
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

function wire(env) {
  globalThis.fetch = async (input, init = {}) => {
    const u = typeof input === 'string' ? input : input.url;
    if (u.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    if (!u.startsWith(JOBS)) return new Response('{}', { status: 599 });
    return worker.fetch(new Request(u, init), env);
  };
}

let seq = 0;
const via = (method, rest, body) => onRequest({
  request: new Request('https://console.example.pages.dev/api/coord/' + rest, {
    method, headers: { cookie: 'dash=mc' + (++seq), 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('?')[0].split('/') }
});

// D1: remove a seeded hub role through the proxy.
{
  const { db, env } = fresh();
  wire(env);
  const rungs = db.prepare(\"SELECT count(*) AS n FROM model_routes WHERE role='stage.triage' AND project IS NULL\").get().n;
  eq('D1-seeded', rungs > 0, true);
  const res = await via('POST', 'model-routes/remove', { role: 'stage.triage', reason: 'drill', actor: 'mallory' });
  eq('D1-status', res.status, 200);
  eq('D1-gone', db.prepare(\"SELECT count(*) AS n FROM model_routes WHERE role='stage.triage' AND project IS NULL\").get().n, 0);
  eq('D1-audit', db.prepare(\"SELECT DISTINCT actor, reason FROM model_route_changes WHERE role='stage.triage'\").all().map((r) => ({ ...r })), [{ actor: 'console', reason: 'drill' }]);
  const proj = await via('POST', 'model-routes/remove', { role: 'stage.plan', project: 'p1' });
  eq('D1-project-refused', proj.status, 400);
}

// D2: price source through the proxy, both ways.
{
  const { db, env } = fresh();
  wire(env);
  const src = () => db.prepare(\"SELECT price_source FROM model_prices WHERE model='test-model-a'\").get().price_source;
  const a = await via('PUT', 'model-prices/source', { model: 'test-model-a', price_source: 'vendor-direct' });
  eq('D2-direct-status', a.status, 200);
  eq('D2-direct', src(), 'vendor-direct');
  const b = await via('PUT', 'model-prices/source', { model: 'test-model-a', price_source: 'openrouter' });
  eq('D2-openrouter-status', b.status, 200);
  eq('D2-openrouter', src(), null);
  const c = await via('PUT', 'model-prices/source', { model: 'no-such-model', price_source: 'openrouter' });
  eq('D2-missing-404', c.status, 404);
}

// D3: an unrouted stage appears, and adding a route removes it.
{
  const { db, env } = fresh();
  wire(env);
  const now = Date.now();
  const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  db.prepare(\"INSERT INTO cost_rows (box, row_hash, line_no, ts, project, stage, runner, inserted_at) VALUES ('b','h1',1,?,'p1','qux','claude','2026-09-26T00:00:00Z')\").run(iso(now - 3600000));
  const since = iso(now - 7 * 86400000);
  const list = async () => {
    const r = await via('GET', 'model-routes?unrouted_since=' + encodeURIComponent(since));
    const j = await r.json();
    return (j.unrouted_stages || []).map((s) => s.stage);
  };
  eq('D3-listed', (await list()).includes('qux'), true);
  const put = await via('PUT', 'model-routes', { role: 'stage.qux', ladder: [{ model: 'test-model-a', runner: 'claude' }], reason: 'route it' });
  eq('D3-put', put.status, 200);
  eq('D3-gone', (await list()).includes('qux'), false);
}
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "proxy: ${line#no }" ;;
    skip\ *) echo "models-control: D1-D3 SKIPPED — ${line#skip }" ;;
    *) [ -n "$line" ] && bad "proxy: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- N: the node suites, driven -----------------------------------------------
# The worker suite runs from the same scratch copy (it needs catalog/lanes.json).
# It reads the schema through test/lib/jobs-schema.js, which composes schema.d/.
mkdir -p "$W/worker/jobs/test/lib"
cp "$WTEST" "$SCHEMA" "$W/worker/jobs/" 2>/dev/null && mv "$W/worker/jobs/$(basename "$WTEST")" "$W/worker/jobs/test/" \
  && cp "$DIR/worker/jobs/test/lib/jobs-schema.js" "$W/worker/jobs/test/lib/" \
  && cp -R "$DIR/worker/jobs/schema.d" "$W/worker/jobs/" \
  || bad "cannot stage the worker suite"
if NOUT=$(cd "$W/worker/jobs" && node --test "test/$(basename "$WTEST")" 2>&1); then ok
else bad "worker/jobs/test/model-routes-unrouted.bh-2512.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|error:' | head -20
fi

if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "models-control: console-ui node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/models-control.bh-2512.test.js 2>&1); then ok
  else bad "console-ui/tests/models-control.bh-2512.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|error:' | head -20
  fi
fi

echo "models-control: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

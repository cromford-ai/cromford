#!/bin/bash
# tests/standby-contract.bh-2519-test.sh — the BH-2519 standby contract
# (BH-2519.0 / BH-2638): the shared schema, the two route modules wired into
# the worker dispatcher (empty in the contract, filled by BH-2639), the two console api helpers and the console stubs
# every later BH-2519 slice imports.
#
# The worker modules and the schema are driven through node (routes imported,
# schema.sql exec'd into a node:sqlite db). The console module imports preact
# from the browser import map, so it cannot load in node: its exports are
# pinned by guarded greps that fail when the symbol is absent.
set -uo pipefail
DIR=$(readlink -f "$(dirname "$0")/..")
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SCHEMA="$DIR/worker/jobs/schema.sql"
STANDBY_ROUTES="$DIR/worker/jobs/src/routes/hub-standby.js"
VERIFY_ROUTES="$DIR/worker/jobs/src/routes/hub-standby-verify.js"
STUBS="$DIR/console-ui/src/screens/hub/StandbyVerify.js"
API="$DIR/console-ui/src/api.js"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# ── a. console stubs: the three contract exports and the hook's default shape ──
if [ -f "$STUBS" ]; then
  check "a: StandbyVerify.js exports useStandbyVerifyRuns(reloadKey)" \
    "grep -Eq '^export function useStandbyVerifyRuns\(reloadKey\)' '$STUBS'"
  check "a: StandbyVerify.js exports StandbyVerifyCell({ row, last, onQueued })" \
    "grep -Eq '^export function StandbyVerifyCell\(\{ row, last, onQueued \}\)' '$STUBS'"
  check "a: StandbyVerify.js exports StandbyVerifyDetail({ box, runs, error, onRetry })" \
    "grep -Eq '^export function StandbyVerifyDetail\(\{ box, runs, error, onRetry \}\)' '$STUBS'"
  # BH-2642 filled the hook, so this pins the five-key return, not the stub's empties.
  check "a: useStandbyVerifyRuns returns { runs, lastByBox, truncated, error, reload }" \
    "grep -Eq 'return \\{ runs[,:].*lastByBox.*truncated.*error.*reload' '$STUBS'"
  check "a: StandbyVerify.js parses" "node --check '$STUBS' 2>/dev/null"
else
  fail "a: $STUBS is missing"
fi
check "a: api.js has standbyVerify(body) POST" \
  "grep -Eq \"standbyVerify: \\(body\\) => post\\('/api/coord/hub/standby/verify', body\\)\" '$API'"
check "a: api.js has standbyVerifyRuns() GET" \
  "grep -Eq \"standbyVerifyRuns: \\(\\) => get\\('/api/coord/hub/standby/verify'\\)\" '$API'"

# ── b. worker wiring, through the real modules ──
# worker/jobs/src/lib/core.js imports catalog/lanes.json, which is generated and
# git-ignored, so the dispatcher and both route modules (they import core.js
# since BH-2639) are loaded from a scratch copy of the worker source beside a
# lanes.json composed by bin/lanes-build.sh. The worker imports other catalog
# JSON too (lib/llm-sites-catalog.js reads catalog/llm-sites.json), so every
# checked-in catalog/*.json rides along before lanes.json is composed.
mkdir -p "$T/worker/jobs" "$T/catalog"
cp -r "$DIR/worker/jobs/src" "$T/worker/jobs/src"
# TEST-CHANGE (BH-4987): core.js resolves `#schema-sql` through the worker's
# package.json, and under Node that composes schema.d/ through test/lib/, so
# the scratch tree carries all three beside src/.
cp "$DIR/worker/jobs/package.json" "$T/worker/jobs/" || fail "cannot copy the worker package.json (BH-4987)"
cp -R "$DIR/worker/jobs/schema.d" "$T/worker/jobs/schema.d" || fail "cannot copy worker/jobs/schema.d (BH-4987)"
mkdir -p "$T/worker/jobs/test/lib" || fail "cannot create the worker test/lib (BH-4987)"
cp "$DIR/worker/jobs/test/lib/jobs-schema.js" "$DIR/worker/jobs/test/lib/schema-sql.node.js" "$T/worker/jobs/test/lib/" \
  || fail "cannot copy the Node schema composer (BH-4987)"
# TEST-CHANGE (BH-4607): index.js imports ROUTES from `#routes`, which under
# Node is test/lib/routes.node.js reading test/route-table.d/, so the scratch
# tree carries both.
cp "$DIR/worker/jobs/test/lib/routes.node.js" "$T/worker/jobs/test/lib/" \
  && cp -R "$DIR/worker/jobs/test/route-table.d" "$T/worker/jobs/test/route-table.d" \
  || fail "cannot copy the Node route loader and test/route-table.d (BH-4607)"
# The staff routes import agent-core/ by a relative path (BH-5559), so the
# scratch tree carries it beside worker/, as the deployed bundle does.
cp -R "$DIR/agent-core" "$T/agent-core" || fail "cannot copy agent-core (the worker imports it, BH-5559)"
cp "$DIR"/catalog/*.json "$T/catalog/"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/catalog/lanes.json" >/dev/null 2>&1 \
  || fail "b: bin/lanes-build.sh could not compose catalog/lanes.json"
out=$(node --input-type=module -e "
  const a = await import('$T/worker/jobs/src/routes/hub-standby.js');
  const b = await import('$T/worker/jobs/src/routes/hub-standby-verify.js');
  for (const [n, m] of [['hub-standby', a], ['hub-standby-verify', b]])
    if (!Array.isArray(m.routes)) { console.log(n + ' routes not an array'); process.exit(1); }
  const idx = await import('$T/worker/jobs/src/index.js');
  if (typeof idx.default?.fetch !== 'function') { console.log('index.js has no default fetch'); process.exit(1); }
  console.log('ok');
" 2>&1)
if [ "$out" = ok ]; then pass "b: both route modules export a routes array; index.js loads"
else fail "b: worker modules: $(printf '%s' "$out" | tail -n 3)"; fi

# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment
# and ROUTES follows the sorted fragment names, so the order is read there.
FRAGD="$DIR/worker/jobs/test/route-table.d"
rl=$(ls "$FRAGD" | grep -nE '^[0-9]{3}-restore-lab\.txt$' | cut -d: -f1)
hs=$(ls "$FRAGD" | grep -nE '^[0-9]{3}-hub-standby\.txt$' | cut -d: -f1)
hv=$(ls "$FRAGD" | grep -nE '^[0-9]{3}-hub-standby-verify\.txt$' | cut -d: -f1)
if [ -n "$rl" ] && [ -n "$hs" ] && [ -n "$hv" ] && [ "$hs" -eq $((rl+1)) ] && [ "$hv" -eq $((rl+2)) ]; then
  pass "b: the hub-standby and hub-standby-verify fragments come right after restore-lab"
else fail "b: route-table.d fragment order (restoreLab=$rl hubStandby=$hs hubStandbyVerify=$hv)"; fi
check "b: hub-standby is registered by one route-table.d fragment" \
  "[ \"\$(ls '$FRAGD'/[0-9][0-9][0-9]-hub-standby.txt 2>/dev/null | wc -l)\" = 1 ]"
check "b: hub-standby-verify is registered by one route-table.d fragment" \
  "[ \"\$(ls '$FRAGD'/[0-9][0-9][0-9]-hub-standby-verify.txt 2>/dev/null | wc -l)\" = 1 ]"

# ── c. the new schema block is additive ──
block=$(awk '/BH-2519: hub standby heartbeat/{on=1} on&&/^$/{exit} on' "$SCHEMA")
if [ -z "$block" ]; then fail "c: BH-2519 schema block not found"
elif printf '%s\n' "$block" | grep -v '^\s*--' | grep -Eiq '\b(DROP|ALTER)\b'; then fail "c: BH-2519 schema block has DROP/ALTER"
else pass "c: BH-2519 schema block has no DROP/ALTER"; fi
# it sits directly after the restore_lab_runs block, not at EOF
ri=$(grep -n 'CREATE UNIQUE INDEX IF NOT EXISTS restore_lab_runs_open' "$SCHEMA" | cut -d: -f1)
bi=$(grep -n 'BH-2519: hub standby heartbeat' "$SCHEMA" | cut -d: -f1)
if [ -n "$ri" ] && [ -n "$bi" ] && [ "$bi" -eq $((ri+2)) ]; then pass "c: block sits directly after restore_lab_runs"
else fail "c: block position (restore_lab_runs_open=$ri block=$bi)"; fi

# ── d/e/f. apply schema.sql to node:sqlite, twice; the index and the ttl seed ──
out=$(node --input-type=module -e "
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { console.log('SKIP node:sqlite unavailable'); process.exit(1); }
  const { readFileSync } = await import('node:fs');
  const sql = readFileSync('$SCHEMA', 'utf8');
  const db = new DatabaseSync(':memory:');
  const r = [];
  const t = (name, ok) => r.push((ok ? 'PASS: ' : 'FAIL: ') + name);
  db.exec(sql); db.exec(sql);
  t('d: schema.sql applies twice', true);
  const names = db.prepare(\"SELECT name FROM sqlite_master WHERE name IN ('standby_status','standby_verify_runs','standby_verify_runs_open') ORDER BY name\").all().map(x => x.name);
  t('d: standby_status, standby_verify_runs, standby_verify_runs_open exist (' + names.join(',') + ')', names.length === 3);
  const ttl = () => db.prepare(\"SELECT value FROM settings WHERE key='standby_verify_claim_ttl_s'\").get()?.value;
  t('d: settings standby_verify_claim_ttl_s = 1800 (got ' + ttl() + ')', ttl() === '1800');
  const cols = (tb) => db.prepare('PRAGMA table_info(' + tb + ')').all().map(c => c.name).join(',');
  t('d: standby_status columns', cols('standby_status') === 'box,of_hub,snapshot,ok,reported_at');
  t('d: standby_verify_runs columns', cols('standby_verify_runs') === 'id,box,of_hub,status,requested_by,requested_at,claimed_at,finished_at,verdict_detail,sha256,snapshot_ts');
  const ins = (box, status) => { try { db.prepare(\"INSERT INTO standby_verify_runs (box,of_hub,status,requested_at) VALUES (?,'hub1',?,'2026-09-26T00:00:00Z')\").run(box, status); return 'ok'; } catch (e) { return String(e.message); } };
  t('e: first open run for b1 is accepted', ins('b1', 'requested') === 'ok');
  const dup = ins('b1', 'requested');
  t('e: second open run for b1 is refused UNIQUE (' + dup + ')', /UNIQUE/.test(dup));
  const dupc = ins('b1', 'claimed');
  t('e: a claimed run beside an open one for b1 is refused UNIQUE (' + dupc + ')', /UNIQUE/.test(dupc));
  t('e: a finished (ok) run beside the open one for b1 is accepted', ins('b1', 'ok') === 'ok');
  t('e: an open run for another box (b2) is accepted', ins('b2', 'requested') === 'ok');
  db.prepare(\"UPDATE settings SET value='600' WHERE key='standby_verify_claim_ttl_s'\").run();
  db.exec(sql);
  t('f: an operator-edited ttl survives a re-apply (got ' + ttl() + ')', ttl() === '600');
  console.log(r.join('\n'));
" 2>&1)
rc=$?
if [ $rc -ne 0 ] && ! grep -q '^FAIL: ' <<<"$out"; then
  fail "d: schema apply: $(printf '%s' "$out" | tail -n 3)"
else
  while IFS= read -r line; do
    case "$line" in
      PASS:*) pass "${line#PASS: }" ;;
      FAIL:*) fail "${line#FAIL: }" ;;
    esac
  done <<<"$out"
fi

echo "standby-contract.bh-2519: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

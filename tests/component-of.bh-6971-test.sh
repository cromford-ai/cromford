#!/bin/bash
# tests/component-of.bh-6971-test.sh — bin/component-of.sh maps an alert line to
# the component that owns it, from catalog/components.tsv (BH-6971, BH-6546.1).
#
#   C1 ten lines in the real producer formats, one per seed component, map to
#      that component against the REAL catalog, and --check passes; a line two
#      rows match goes to the earlier row (scratch catalog).
#   C2 an unknown line and a 12-hex family hash are `unowned`, rc 0.
#   C3 a malformed catalog row (4 fields, a bad name, a regex that does not
#      compile, a lane that does not exist under --check) is rc 2 with the
#      line number and the raw line on stderr, and nothing on stdout.
#   C4 the negative list: a log path or ticket title that only CONTAINS a lane
#      name, an empty line and a bare timestamp are `unowned`; a leading
#      timestamp is removed before the match; --batch keeps ids and order.
#   C5 the worker half (the column, the GET filter and the stamp route in
#      worker/jobs/src/routes/alert-components.js), when node can run it.
#
# Run from anywhere: tests/component-of.bh-6971-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
CO="$DIR/bin/component-of.sh"
CAT="$DIR/catalog/components.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
is() { # is <want> <line> — the resolver's answer for <line> is <want>, rc 0
  local got rc
  got=$(bash "$CO" "$2" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$got" = "$1" ] && ok || bad "'$2' -> want $1 rc 0, got '$got' rc $rc"
}

# ---- C1 ten producer lines, one per seed component -----------------------------------
is merge-conductor  '[merge-conductor] HEAD_MOVED example-org/cromford#1 head moved after review'
is blocked-resolver '[orchestrator/blocked-resolver] [blocked-resolver] STARVED project-4: 3 parked candidate(s) were offered'
is pool-builders    '[pool/project-4] builder machine 1234 is still in builder-project-4 and nothing uses it'
is triage           '[project-4] TRIAGE STAGE MISSING: bin/lib/rt/plan.sh is not on this box'
is deploy-train     '[project-4] DEPLOY TRAIN: production is NOT serving 3e9df610 40m after the merge (live=none)'
is main-red-bisect  '[orchestrator/main-red-bisect] main is red at 3e9df610; first bad merge #6961'
is jobs-worker      '[jobs-watchdog] LEDGER RECONCILED: 2 claim(s) closed done because their PR merged'
is console          '[orchestrator/console-preview-deploy] [console-preview] The lane removed D1 from the preview environment'
is cost             '[cost-rollup] NEW UNPRICED PAIR(S): openrouter/x; the cost ledger stores these as NULL'
is hub-health       'hub-probe: store-failed=1 bad-key=0 spool-failed=0 (logs/hub-probe.log)'
# The second row of a component is reached too.
is triage           '[alert-triage] DEFERRAL BACKLOG: 40 lines spooled'
is hub-health       '[project-4] HEALTHCHECK: https://os.project-4.example/api/health returned HTTP 500'
OUT=$(bash "$CO" --check 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "C1 --check on the real catalog: rc $rc: $OUT"
[[ "$OUT" =~ ^components:\ 10\ component\(s\),\ [0-9]+\ row\(s\)$ ]] && ok || bad "C1 --check count line: $OUT"
# Every seed component has a row.
for c in merge-conductor blocked-resolver pool-builders triage deploy-train main-red-bisect jobs-worker console cost hub-health; do
  grep -q "^$c"$'\t' "$CAT" && ok || bad "C1 seed component $c has no row in catalog/components.tsv"
done
# First match wins, in file order.
printf '# two rows match\nfirst\t^\\[x\\]\t-\t-\t-\nsecond\t^\\[x\\] y\t-\t-\t-\n' > "$T/two.tsv"
got=$(COMPONENTS_TSV="$T/two.tsv" bash "$CO" '[x] y z')
[ "$got" = first ] && ok || bad "C1 two matching rows must answer the earlier one, got $got"

# ---- C2 unowned -------------------------------------------------------------------
is unowned '[no-such-lane] something broke'
is unowned 'abcdef012345'

# ---- C3 a malformed row is red with the line -----------------------------------------
bad_row() { # bad_row <label> <catalog text> <stderr pattern> [--check]
  printf '%b' "$2" > "$T/bad.tsv"
  local out err rc
  out=$(COMPONENTS_TSV="$T/bad.tsv" bash "$CO" ${4:-'[merge-conductor] x'} 2>"$T/err"); rc=$?
  err=$(cat "$T/err")
  [ "$rc" = 2 ] && ok || bad "C3 $1: want rc 2, got $rc"
  [ -z "$out" ] && ok || bad "C3 $1: stdout must be empty, got '$out'"
  grep -qE "$3" <<<"$err" && ok || bad "C3 $1: stderr '$err' does not match $3"
}
# GOOD comes FIRST and matches the probe line, so an empty stdout proves there
# is no partial answer from the rows read before the bad one.
GOOD='merge-conductor\t^\\[merge-conductor\\]\t-\t-\t-\n'
bad_row 'four fields'   "# c\n${GOOD}cost\t^x\t-\t-\n"         '^component-of: bad.tsv:3: want 5 tab-separated fields, got 4: cost	\^x	-	-$'
bad_row 'bad name'      "${GOOD}Bad_Name\t^x\t-\t-\t-\n"       '^component-of: bad.tsv:2: component must match .*: Bad_Name	\^x'
bad_row 'bad regex'     "${GOOD}cost\t([\t-\t-\t-\n"            '^component-of: bad.tsv:2: regex does not compile: cost	\(\['
bad_row 'missing lane'  "cost\t^x\tno-such-lane-6971\t-\t-\n"  '^component-of: bad.tsv:1: lane no-such-lane-6971 has no catalog/lanes.d/no-such-lane-6971.json' --check
OUT=$(COMPONENTS_TSV="$T/nope.tsv" bash "$CO" x 2>&1); rc=$?
[ "$rc" = 2 ] && ok || bad "C3 a missing catalog is rc 2, got $rc ($OUT)"
bash "$CO" >/dev/null 2>&1; rc=$?
[ "$rc" = 64 ] && ok || bad "C3 no argument is rc 64, got $rc"

# ---- C4 the negative list, the stamp and --batch -------------------------------------
is unowned 'tail https://hub.example/logs/merge-conductor.log for the HEAD_MOVED lines'
is unowned 'BH-1: fix blocked-resolver docs'
is unowned ''
is unowned '2026-10-15T21:00Z'
is unowned 'cost-rollup ran 3 times'
is cost    '2026-10-15 21:00:00Z [cost-rollup] NEW UNPRICED PAIR(S): openrouter/x'
is merge-conductor '2026-10-15T21:00:00Z [merge-conductor] x'
got=$(printf 'i3\t[cost-rollup] x\ni1\tnothing here\ni2\t2026-10-15 21:00:00Z [merge-conductor] y\n' | bash "$CO" --batch)
want=$(printf 'i3\tcost\ni1\tunowned\ni2\tmerge-conductor')
[ "$got" = "$want" ] && ok || bad "C4 --batch: got $(printf '%q' "$got")"

# ---- C5 the worker half ------------------------------------------------------------
ROUTE="$DIR/worker/jobs/src/routes/alert-components.js"
[ -f "$ROUTE" ] && grep -q '"POST", "/api/alerts/component"' "$ROUTE" && ok || bad "C5 $ROUTE must carry POST /api/alerts/component"
if ! command -v node >/dev/null 2>&1; then
  echo "component-of.bh-6971: C5 node suite SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ] || [ ! -f "$DIR/catalog/context-budgets.json" ]; then
  echo "component-of.bh-6971: C5 node suite SKIPPED — catalog/lanes.json or context-budgets.json is not composed (the jobs-worker CI job runs it)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/alerts-component.bh-6971.test.js 2>&1); then ok
else bad "C5 worker/jobs/test/alerts-component.bh-6971.test.js failed: $(grep -E '^not ok|error:' <<<"$NOUT" | head -5)"; fi

echo "component-of.bh-6971: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/daily-digest-contract.bh-3703-test.sh — the daily-digest contract
# (BH-3703, slice 1 of BH-3688).
#
# The route and the shape helpers are proved by node --test in
# worker/jobs/test/daily-digest.bh-3703.test.js. This file pins the two shell
# stubs the siblings fill in (#3707) and the two committed fixtures, names every
# new source by path so the orphan ratchet can see it, and runs the node suite
# when its runtime is there (the cost-breakdown.bh-3557 pattern).
#
#   SH1. bash -n and shellcheck -S error on both stubs.
#   SH2. dd_render: 5 args -> rc 2; 6 args with a missing JSON -> rc != 0 and
#        empty stdout. The render itself is pinned by
#        tests/daily-digest-render.bh-3688-test.sh (BH-3707).
#   SH3. dd_summary with the knob unset: rc 1, writes no out file, calls
#        nothing; 1 arg -> rc 2. The knob-on paths are pinned by
#        tests/daily-digest-summary.bh-3688-test.sh (BH-3707).
#   SH4. dd_render reads no ${X:-default}; dd_summary reads exactly its two
#        knobs; neither lib carries a /root/harness literal.
#   SH5. jq shape checks on both fixtures.
#   SH6. the node suite, run for real.
# Run from anywhere: tests/daily-digest-contract.bh-3703-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RENDER="$DIR/bin/lib/daily-digest-render.sh"
SUMMARY="$DIR/bin/lib/daily-digest-summary.sh"
SHAPE="$DIR/worker/jobs/src/lib/daily-digest/shape.js"
CORE="$DIR/worker/jobs/src/lib/daily-digest/core-sections.js"
STATE="$DIR/worker/jobs/src/lib/daily-digest/state-sections.js"
ROUTE="$DIR/worker/jobs/src/routes/daily-digest.js"
INDEX="$DIR/worker/jobs/src/index.js"
FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
EMPTY="$DIR/tests/fixtures/daily-digest/empty-day.json"

for f in "$RENDER" "$SUMMARY" "$SHAPE" "$CORE" "$STATE" "$ROUTE" "$INDEX" "$FIX" "$EMPTY"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- SH1: syntax and shellcheck ----------------------------------------------
bash -n "$RENDER" "$SUMMARY" 2>/dev/null && ok || bad "bash -n on the stubs"
for f in "$RENDER" "$SUMMARY"; do bash -n "$f" && ok || bad "bash -n $f"; done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$RENDER" "$SUMMARY" && ok || bad "shellcheck -S error on the stubs"
else
  echo "daily-digest-contract: shellcheck SKIPPED — not installed on this box"
fi

# --- SH2: dd_render's frozen signature ---------------------------------------
OUT=$(bash -c '. "$1" && dd_render "$2" b c d 5 f' _ "$RENDER" "$T/no-such.json" 2>"$T/render.err"); RC=$?
[ "$RC" != 0 ] && ok || bad "dd_render with a missing JSON: rc $RC, want non-zero"
[ -z "$OUT" ] && ok || bad "dd_render printed on stdout: $OUT"
bash -c '. "$1" && dd_render a b c d e' _ "$RENDER" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "dd_render with 5 args: rc $RC, want 2"

# --- SH3: dd_summary is off by default: writes nothing, calls nothing ---------
mkdir -p "$T/bin"
for c in claude agent-call.sh codex curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
rm -f "$T/sum.out"
env -u DAILY_DIGEST_LLM_SUMMARY PATH="$T/bin:$PATH" bash -c '. "$1" && dd_summary "$2" "$3"' _ "$SUMMARY" "$FIX" "$T/sum.out" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "dd_summary (knob unset): rc $RC, want 1"
[ ! -e "$T/sum.out" ] && ok || bad "dd_summary (knob unset) created its out file"
[ ! -s "$T/calls.log" ] && ok || bad "dd_summary made a call: $(cat "$T/calls.log")"
bash -c '. "$1" && dd_summary only-one' _ "$SUMMARY" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "dd_summary with 1 arg: rc $RC, want 2"

# --- SH4: which env each lib reads -------------------------------------------
code() { grep -vE '^[[:space:]]*#' "$1"; }
if code "$RENDER" | grep -qE '\$\{[A-Z_]+:-'; then bad "dd_render reads an env default"; else ok; fi
KNOBS=$(code "$SUMMARY" | grep -oE '\$\{[A-Z_]+:-' | sed -E 's/^\$\{//; s/:-$//' | sort -u | tr '\n' ' ')
[ "$KNOBS" = "DAILY_DIGEST_LLM_MAX_USD DAILY_DIGEST_LLM_SUMMARY " ] && ok || bad "dd_summary reads [$KNOBS]"
code "$SUMMARY" | grep -qF '${DAILY_DIGEST_LLM_SUMMARY:-0}' && ok || bad "dd_summary must read \${DAILY_DIGEST_LLM_SUMMARY:-0} literally"
code "$SUMMARY" | grep -qF '${DAILY_DIGEST_LLM_MAX_USD:-0.10}' && ok || bad "dd_summary must read \${DAILY_DIGEST_LLM_MAX_USD:-0.10} literally"
if grep -qF '/root/harness' "$RENDER" "$SUMMARY"; then bad "a /root/harness literal in a daily-digest lib"; else ok; fi

# --- SH5: the fixtures -------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  jq -e '.empty == false and (.tripwires.rows | length) == 8 and .tripwires.n == 8' "$FIX" >/dev/null && ok || bad "fixture-day shape"
  jq -e '.empty == true and .spend.usd_per_merged_pr == null and .throughput.filing_to_merge.p50_s == null
         and .tripwires.n == 0 and (.tripwires.rows | length) == 0' "$EMPTY" >/dev/null && ok || bad "empty-day shape"
  [ "$(jq -c 'keys' "$FIX")" = "$(jq -c 'keys' "$EMPTY")" ] && ok || bad "the fixtures' top-level keys differ"
else
  echo "daily-digest-contract: fixture jq checks SKIPPED — jq is not installed on this box"
fi

# --- wiring ------------------------------------------------------------------
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-daily-digest.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "daily-digest has no route-table.d fragment (BH-4607: the fragment IS the registration)"
grep -q 'from "./routes/daily-digest.js"' "$INDEX" && bad "index.js hand-registers daily-digest: the fragment registers it (BH-4607)" || ok
grep -qx 'GET /api/metrics/daily-digest' "$DIR"/worker/jobs/test/route-table.d/*-daily-digest.txt 2>/dev/null \
  && ok || bad "no route-table fragment for GET /api/metrics/daily-digest"

# --- SH6: the node suite -----------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "daily-digest-contract: node suite SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "daily-digest-contract: node suite SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/daily-digest.bh-3703.test.js 2>&1); then ok
else bad "node suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30
fi

echo "daily-digest-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

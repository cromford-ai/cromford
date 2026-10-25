#!/bin/bash
# tests/plan-fragment-rule.bh-5788-test.sh — the planner is told that shared
# lists are fragments (BH-5788 C): a new table is a new stamp-key schema.d
# fragment, a new jobs-worker route family is a key-named route-table.d
# fragment, never an append to a shared list.
#
#   C1  th_fragment_rule (bin/lib/test-home-lib.sh) prints the sentence, with
#       the ticket key lower-cased, in a repo with a worker/*/schema.d/
#   C2  a repo with no worker/*/schema.d/ gets nothing
#   C3  the REAL plan prompt block of bin/lib/rb/plan.sh (read through
#       tests/lib/rb-all.sh) carries it, run from such a checkout, and the REAL
#       bin/run-preplan.sh sends it in the pre-plan prompt for the checkout it
#       plans in; with the lib absent the lane still runs
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-fragment-rule.bh-5788-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/test-home-lib.sh"
# shellcheck source=../bin/lib/test-home-lib.sh
. "$LIB" || { echo "FAIL: could not source $LIB"; exit 1; }
command -v th_fragment_rule >/dev/null 2>&1 || bad "C1 th_fragment_rule is not defined in bin/lib/test-home-lib.sh"

# The fixture checkouts: one composed like cromford, one like an app repo.
mkdir -p "$T/withfrag/worker/jobs/schema.d" "$T/nofrag/src" "$T/nofrag/worker/other"

# ── C1 the helper ─────────────────────────────────────────────────────────────
S=$(th_fragment_rule BH-5788 "$T/withfrag"); RC=$?
[ "$RC" = 0 ] && ok || bad "C1 rc $RC"
for want in 'schema.d/<yyyymmddhhmm>-bh-5788-<name>.sql' 'never a picked NNNN' 'bin/schema-build.sh --write' \
            'worker/jobs/src/routes/<family>.js' 'worker/jobs/test/route-table.d/bh-5788-<family>.txt' \
            'never an `index.js` edit' 'Never append to a shared list'; do
  grep -qF -- "$want" <<<"$S" && ok || bad "C1 the sentence must carry [$want]: $S"
done
[ "$(printf '%s' "$S" | wc -l)" = 0 ] && ok || bad "C1 the sentence must be one line"
[ "${S: -1}" = ' ' ] && ok || bad "C1 the sentence must end in a space so the next prompt text does not run into it"
# A child key's dot becomes a dash in the schema name (the composer allows no
# dot there); the route-table fragment keeps the key as it is (FRAG_RE allows it).
S=$(th_fragment_rule BH-6005.4 "$T/withfrag")
grep -qF 'schema.d/<yyyymmddhhmm>-bh-6005-4-<name>.sql' <<<"$S" && grep -qF 'route-table.d/bh-6005.4-<family>.txt' <<<"$S" && ok \
  || bad "C1 a child key: the schema name carries bh-6005-4, the route fragment bh-6005.4: $S"

# ── C2 no schema.d, no sentence ───────────────────────────────────────────────
S=$(th_fragment_rule BH-5788 "$T/nofrag"); RC=$?
[ "$RC" = 0 ] && [ -z "$S" ] && ok || bad "C2 a repo with no worker/*/schema.d must get nothing, rc $RC out [$S]"

# ── C3 the real plan prompt ───────────────────────────────────────────────────
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk 'index($0, "# >>> plan prompt")==1 {f=1;next} index($0, "# <<< plan prompt")==1 {exit} f' "$RB" > "$T/plan-prompt.sh"
[ -s "$T/plan-prompt.sh" ] && ok || bad "C1 could not extract the 'plan prompt' block"
mkdir -p "$T/h/bin/lib" "$T/b"
planprompt() { # planprompt <checkout> <capture> — the block, run from <checkout>
  # TEST-CHANGE (BH-7970): the block renders prompts/stages/plan.md through sp_render, so the driver loads the repo's bin/lib/stage-prompt.sh.
  rm -f "$2"
  ( cd "$1" && env HARNESS="$T/h" BUILD="$T/b" KEY=BH-5788 TICKET=1 PROJECT=widget-os PLAN_MODEL=m \
        PLAN_AMBIGUITY_RULE= KIND_HINT_LINE= CARRIED_NOTE_LINE= LIBP="$LIB" CAP="$2" SPLIB="$DIR/bin/lib/stage-prompt.sh" \
    bash -c 'set -uo pipefail
             CC() { printf "%s" "$5" > "$CAP"; }
             CC_ARTIFACT_KIND=; CC_ARTIFACT_FILE=
             . "$LIBP"
             . "$SPLIB"
             . "$0"' "$T/plan-prompt.sh" ) >"$T/plan-prompt.out" 2>&1
}
planprompt "$T/withfrag" "$T/p1.txt"
grep -qF 'worker/jobs/test/route-table.d/bh-5788-<family>.txt' "$T/p1.txt" && ok \
  || bad "C3 the plan prompt must carry the fragment sentence: $(head -c 300 "$T/p1.txt" 2>/dev/null) $(tail -3 "$T/plan-prompt.out")"
grep -qF 'PLAN ONLY - do not modify' "$T/p1.txt" && ok || bad "C3 the plan instructions must survive the sentence"
planprompt "$T/nofrag" "$T/p2.txt"
grep -qF 'SHARED LISTS ARE FRAGMENTS' "$T/p2.txt" && bad "C3 an app repo's plan prompt must not carry the sentence" || ok
grep -qF 'PLAN ONLY - do not modify' "$T/p2.txt" && ok || bad "C3 the app repo's plan prompt must still be sent"

# ── C3 the real pre-plan lane ─────────────────────────────────────────────────
P="$T/pp"
mkdir -p "$P/bin/lib" "$P/env" "$P/flags" "$P/logs" "$P/plans" "$P/locks" "$P/repos/proj"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$P" proj || exit 1
scratch_install_closure bin/run-preplan.sh "$P" >/dev/null || { echo "FAIL: closure install"; exit 1; }
: > "$P/env/global.env"
cat > "$P/bin/agent-call.sh" <<'STUB'
#!/bin/bash
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt>
printf '%s' "$6" > "${PROMPT_DIR:?}/prompt.txt"
exit 0
STUB
chmod +x "$P/bin/agent-call.sh"
mkdir -p "$P/stubbin"; printf '#!/bin/bash\nexit 0\n' > "$P/stubbin/git"; chmod +x "$P/stubbin/git"
# The checkout the lane plans in (legacy and per-key paths), shaped like this repo.
# Each run is a fresh key: a key the lane already tried is not re-planned.
mkdir -p "$P/repos/.preplan-proj/worker/jobs/schema.d" "$P/repos/.preplan-proj-AB-7/worker/jobs/schema.d" \
         "$P/repos/.preplan-proj-AB-8/worker/jobs/schema.d"
lane() { # lane <KEY>
  rm -f "$P/prompt.txt"
  PATH="$P/stubbin:$PATH" PROMPT_DIR="$P" HARNESS="$P" REPOS_ROOT="$P/repos" \
    bash "$P/bin/run-preplan.sh" proj 1 "$1" >"$T/lane.out" 2>&1; RC=$?
}
lane AB-7
[ "$RC" = 0 ] && ok || bad "C3 the pre-plan lane must exit 0, rc $RC: $(tail -3 "$T/lane.out")"
grep -qF 'worker/jobs/test/route-table.d/ab-7-<family>.txt' "$P/prompt.txt" 2>/dev/null && ok \
  || bad "C3 the pre-plan prompt must carry the fragment sentence for ab-7: $(head -c 300 "$P/prompt.txt" 2>/dev/null)"
grep -qF 'TEST FILES ARE PER-TICKET' "$P/prompt.txt" 2>/dev/null && ok || bad "C3 the test-file rule must still be there"
mv "$P/bin/lib/test-home-lib.sh" "$T/parked.sh"
lane AB-8
[ "$RC" = 0 ] && ok || bad "C3 with the lib absent the lane must still exit 0, rc $RC: $(tail -3 "$T/lane.out")"
grep -qF 'Write a precise implementation plan' "$P/prompt.txt" 2>/dev/null && ok || bad "C3 with the lib absent the prompt must still be sent"
grep -qF 'SHARED LISTS ARE FRAGMENTS' "$P/prompt.txt" 2>/dev/null && bad "C3 with the lib absent there is no sentence" || ok

echo "plan-fragment-rule.bh-5788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

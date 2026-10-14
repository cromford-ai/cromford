#!/bin/bash
# tests/ci-plan-member-reach.bh-6688-test.sh — the merge-queue plan job says
# how many of the batch's members reach the whole corpus on their own files
# (BH-6688).
#
# WHY. The BH-5373 replay found 17 of 20 draft members with a `full` reach, and
# nothing in CI said so: the number came from an offline replay. With
# CI_PLAN_MEMBER_REACH=1 bin/ci-plan.sh reads each #<n> member's files and
# selects them as a batch select against one map. It is REPORT ONLY: the
# mode, list, shard count and rc are the same with it on or off. The real
# planner and the real bin/test-impact.sh run against this tree (on one map
# built once); only GitHub is a stub.
#
#   R1  two lane-file members -> `member reach: full 0 of 2 members`
#   R2  #2 touches the docker runner -> `full 1 of 2 members (#2 bin/run-tests-in-docker.sh)`
#   R3  #2's files cannot be read -> `member reach: unreadable (#2 files could not be read)`
#   R4  off: CI_PLAN_MEMBER_REACH unset, or a shard (CI_PLAN_ESCALATION set),
#       prints no line and reads no files
#   R5  R2 and R3 plan the same mode, count and list as R4
#   R6  GITHUB_STEP_SUMMARY holds the line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-plan-member-reach.bh-6688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The fake gh: `api repos/o/r/pulls/<n>` answers no `full` label;
# `api --paginate repos/o/r/pulls/<n>/files --jq …` prints $FAKE_GH_DIR/<n>.files,
# and fails when <n>.fail exists. Every call is logged to $GH_SINK.
cat > "$T/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
p=""; for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
case "$p" in
  */pulls/*/files) n="${p%/files}"; n="${n##*/}"
                   [ ! -e "$FAKE_GH_DIR/$n.fail" ] || exit 1
                   cat "$FAKE_GH_DIR/$n.files" ;;
  */pulls/*)       echo '{"number":'"${p##*/}"',"labels":[{"name":"ai-build"}]}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/gh"
mkdir -p "$T/prs"; : > "$T/notiers.tsv"
# The real bin/test-impact.sh, handed one map built once from this tree, so
# each plan does not build two (`map` copies it; `select` reads it).
bash "$DIR/bin/test-impact.sh" map --root "$DIR" --out "$T/map" 2>"$T/map.err" && [ -s "$T/map" ] \
  || { echo "FAIL: the map could not be built: $(cat "$T/map.err")"; exit 1; }
cat > "$T/impact" <<'EOF'
#!/bin/bash
cmd="$1"; shift
if [ "$cmd" = map ]; then
  while [ $# -gt 0 ]; do [ "$1" = --out ] && { cp "$IMPACT_MAP" "$2"; exit; }; shift; done
  cat "$IMPACT_MAP"; exit
fi
case " $* " in *" --map "*) exec bash "$IMPACT_REAL" "$cmd" "$@" ;; esac
exec bash "$IMPACT_REAL" "$cmd" "$@" --map "$IMPACT_MAP"
EOF
chmod +x "$T/impact"
printf 'catalog/lanes.d/merge-conductor.json\n' > "$T/changed"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)

# bplan <tag> <VAR=val…> — one batch plan of this tree; RC, OUT, GO, list in $T/list.<tag>
bplan() {
  local tag="$1"; shift
  rm -f "$T/go"; : > "$T/sink"
  OUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_ESCALATION -u CI_PLAN_MEMBER_REACH \
          CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" TI_PR_LABELS= CI_QUARANTINE= \
          TI_PR_TITLE='merge queue: checking #1 + #2 together on main (abc1234)' CI_PR_BODY= \
          CI_REPO=o/r CI_PLAN_GH="$T/gh" GH_SINK="$T/sink" FAKE_GH_DIR="$T/prs" \
          CI_PLAN_CHANGED_FILE="$T/changed" CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" \
          CI_PLAN_IMPACT="$T/impact" IMPACT_REAL="$DIR/bin/test-impact.sh" IMPACT_MAP="$T/map" \
          "$@" bash "$PLAN" --out "$T/list.$tag" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
reach_line() { grep '^ci-plan: member reach:' <<<"$OUT"; }
files_calls() { grep -c '/files' "$T/sink"; }

printf 'catalog/lanes.d/merge-conductor.json\n' > "$T/prs/1.files"
printf 'catalog/lanes.d/merge-conductor.json\ncatalog/pr-self-check.tsv\n' > "$T/prs/2.files"

# R1 — both members bounded.
bplan r1 CI_PLAN_MEMBER_REACH=1
[ "$RC" = 0 ] && [ "$(reach_line)" = "ci-plan: member reach: full 0 of 2 members" ] && ok \
  || bad "R1 two lane-file members: full 0 of 2 (rc $RC): $(reach_line) $(tail -2 <<<"$OUT")"
[ "$(files_calls)" = 2 ] && grep -q -- '--paginate' "$T/sink" && ok || bad "R1 each member's files are read once, paginated: $(cat "$T/sink")"

# R4 — off: no line, no files read. This is the plan R2 and R3 must match.
bplan r4
[ "$RC" = 0 ] && [ -z "$(reach_line)" ] && [ "$(files_calls)" = 0 ] && ok \
  || bad "R4 unset prints no member reach and reads no files (rc $RC): $(reach_line) / $(cat "$T/sink")"
MODE4=$(out mode); COUNT4=$(out count); N4=$(out n)
[ "$MODE4" = batch-selected ] && ok || bad "R4 fixture: the lane-file batch is batch-selected: $MODE4 $(out escalation)"
bplan r4s CI_PLAN_MEMBER_REACH=1 CI_PLAN_ESCALATION=-
[ "$RC" = 0 ] && [ -z "$(reach_line)" ] && [ "$(files_calls)" = 0 ] && ok \
  || bad "R4 a shard (CI_PLAN_ESCALATION set) prints no member reach and reads no files (rc $RC): $(reach_line) / $(cat "$T/sink")"

# R2 + R6 — #2 also touches the docker runner; the step summary gets the line.
printf 'catalog/pr-self-check.tsv\nbin/run-tests-in-docker.sh\n' > "$T/prs/2.files"
: > "$T/summary"
bplan r2 CI_PLAN_MEMBER_REACH=1 GITHUB_STEP_SUMMARY="$T/summary"
[ "$RC" = 0 ] && [ "$(reach_line)" = "ci-plan: member reach: full 1 of 2 members (#2 bin/run-tests-in-docker.sh)" ] && ok \
  || bad "R2 #2 with the docker runner: full 1 of 2 (rc $RC): $(reach_line)"
grep -qxF "member reach: full 1 of 2 members (#2 bin/run-tests-in-docker.sh)" "$T/summary" && ok \
  || bad "R6 the step summary holds the member reach line: $(cat "$T/summary")"
[ "$(out mode)" = "$MODE4" ] && [ "$(out count)" = "$COUNT4" ] && [ "$(out n)" = "$N4" ] && cmp -s "$T/list.r2" "$T/list.r4" && ok \
  || bad "R5 R2 plans what R4 plans: mode $(out mode)/$MODE4 count $(out count)/$COUNT4 n $(out n)/$N4"

# R3 — #2's files read fails.
touch "$T/prs/2.fail"
bplan r3 CI_PLAN_MEMBER_REACH=1
[ "$RC" = 0 ] && [ "$(reach_line)" = "ci-plan: member reach: unreadable (#2 files could not be read)" ] && ok \
  || bad "R3 a failed files read is unreadable, never full 0 (rc $RC): $(reach_line)"
[ "$(out mode)" = "$MODE4" ] && [ "$(out count)" = "$COUNT4" ] && [ "$(out n)" = "$N4" ] && cmp -s "$T/list.r3" "$T/list.r4" && ok \
  || bad "R5 R3 plans what R4 plans: mode $(out mode)/$MODE4 count $(out count)/$COUNT4 n $(out n)/$N4"
rm -f "$T/prs/2.fail"

# The workflow's plan step turns it on.
grep -qE "^          CI_PLAN_MEMBER_REACH: '1'$" "$DIR/.github/workflows/harness-ci.yml" && ok \
  || bad "the plan step of .github/workflows/harness-ci.yml sets CI_PLAN_MEMBER_REACH: '1'"

echo "ci-plan-member-reach.bh-6688: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

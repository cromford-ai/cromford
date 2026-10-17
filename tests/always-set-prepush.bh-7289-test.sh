#!/bin/bash
# tests/always-set-prepush.bh-7289-test.sh — a merge-queue batch drops the
# always-suites the pre-push gate already ran green on every member's head
# (BH-7289, wave 3 of #7033).
#
# The real bin/ci-plan.sh runs with a stub test-impact (CI_PLAN_IMPACT) and a
# stub gh (CI_PLAN_GH) that serves `pulls/<n>` with .head.sha, .body and
# .labels. The prepush list is a 4-line fixture (CI_PLAN_PREPUSH_LIST). The
# records in the member bodies are written by the real ppr_write
# (bin/lib/prepush-record.sh) from a stub gate out dir.
#
#   P0  the real catalog/test-impact-always-prepush.txt: every line is an
#       always-suite, sorted and unique; prints the shrink line
#   P1  2 members, both with a record on their head: A1..A4 dropped, prepush=4
#   P2  member #22 has no record: nothing dropped, the reason names #22
#   P3  #22's record head is not its head: nothing dropped
#   P4  #22's record lists A1..A3 only: the intersection (3) is dropped
#   P5  two record markers in one body: nothing dropped
#   P6  a v2 record: nothing dropped
#   P7  CI_ALWAYS_PREPUSH_SKIP=0 / =yes: off, the value named
#   P8  the draft's own `full` label: members not read, off
#   P9  a member that cannot be read: off
#   P10 a quarantined suite is never dropped
#   P11 a regression row re-adds a dropped suite
#   P12 an ordinary PR: no prepush key, no line, the list unchanged
#   P13 a record line that is not a plain tests/ path is ignored
#   P14 a quoted record marker is not a marker
#   P15 a shard subtracts exactly the plan job's file; --expect-n agrees
#   P16 a shard whose file is unreadable is rc 1
#   P17 a plan job that cannot write the file is rc 2
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/always-set-prepush.bh-7289-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
. "$DIR/bin/lib/prepush-record.sh" || { echo "FAIL: cannot source bin/lib/prepush-record.sh"; exit 1; }

# ── P0. the real list.
REAL="$DIR/catalog/test-impact-always-prepush.txt"
check "P0 the list exists" '[ -r "$REAL" ]'
grep -Ev '^[[:space:]]*(#|$)' "$REAL" > "$T/real.list" 2>/dev/null
( cd "$DIR" && bin/test-impact.sh always 2>/dev/null ) | LC_ALL=C sort -u > "$T/always"
K=$(grep -c . "$T/real.list"); A=$(grep -c . "$T/always")
check "P0 the list is not empty ($K)" '[ "$K" -gt 0 ]'
check "P0 the list is LC_ALL=C sorted and unique" 'LC_ALL=C sort -u "$T/real.list" | cmp -s - "$T/real.list"'
NOTIN=$(LC_ALL=C awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$T/always" "$T/real.list" | paste -sd' ' -)
check "P0 every line is an always-suite (not: ${NOTIN:-none})" '[ -z "$NOTIN" ]'
check "P0 fewer lines than the always set ($K of $A)" '[ "$K" -lt "$A" ]'
echo "always set in a batch: $A -> $((A - K)) when every member has a green record ($K moved to catalog/test-impact-always-prepush.txt)"

# ── the fixture.
A1=tests/gh-rest-no-subshell-lint.sh; A2=tests/gh-app-ratchet-test.sh
A3=tests/pr-scoped-test-lint.bh-5684-test.sh; A4=tests/route-keyed-merge.bh-5788-test.sh
A5=tests/config-literal-lint.sh; A6=tests/ci-shard-split-test.sh
X1=tests/ci-plan-test.sh; X2=tests/env-path-test.sh
for s in $A1 $A2 $A3 $A4 $A5 $A6 $X1 $X2; do [ -f "$DIR/$s" ] || { echo "FAIL: setup: $s is not in the tree"; exit 1; }; done
printf '# fixture list\n%s\n' "$A1" "$A2" "$A3" "$A4" > "$T/pplist"
printf '%s\n' "$A1" "$A2" "$A3" "$A4" "$A5" "$A6" "$X1" "$X2" > "$T/sel.txt"
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    cat "$FAKE_SELECT" > "$OUT"; echo "impact: 8 of 300 suites (selected)" >&2 ;;
  ci-select) cat "$FAKE_SELECT" > "$OUT"; echo "impact: 8 of 300 suites (selected)" >&2 ;;
esac
FAKE
cat > "$T/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
n="${2##*/}"
[ -n "${FAKE_GH_FAIL:-}" ] && [ "$n" = "$FAKE_GH_FAIL" ] && exit 1
cat "$FAKE_GH_DIR/$n.json"
FAKE
chmod +x "$T/fake.sh" "$T/gh"
: > "$T/notiers.tsv"
printf 'console-ui/src/screens/Jobs.js\n' > "$T/changed"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)
SHA21=2121212121212121212121212121212121212121
SHA22=2222222222222222222222222222222222222222
TITLE='merge queue: checking #21 on main (abc1234)'
DRAFT='This batch carries [#21](https://github.com/o/r/pull/21) and [#22](https://github.com/o/r/pull/22).'

# gate <dir> <suite...> — a stub gate out dir, green, whose fast-lints ran these suites with rc 0.
gate() {
  local d="$1" s; shift
  mkdir -p "$d/fast-lints.d"
  printf 'rules-pack\tgreen\t0\t3\trules-pack\nfast-lints\tgreen\t0\t9\tfast-lints\n' > "$d/summary.tsv"
  : > "$d/fast-lints.d/timings.tsv"
  for s in "$@"; do printf '%s\t1\t0\n' "$s" >> "$d/fast-lints.d/timings.tsv"; done
}
# member <n> <head> <body-file> — the gh reply for #n.
member() { jq -n --argjson n "$1" --arg h "$2" --rawfile b "$3" '{number: $n, head: {sha: $h}, body: $b, labels: [{name: "ai-build"}]}' > "$T/prs/$1.json"; }
# record <file> <head> <suite...> — a member body: prose, then the real writer's block.
record() {
  local f="$1" h="$2"; shift 2
  scratch_rm "$T/g" || exit 1; gate "$T/g" "$@"
  { printf '## What\n\nA fixture PR body.\n'; ppr_write "$T/g" "$h" "$DIR"; printf '\n---\nfooter\n'; } > "$f"
}
mkdir -p "$T/prs" "$T/bodies"
setup_green() {
  record "$T/bodies/21" "$SHA21" "$A1" "$A2" "$A3" "$A4" "$A5"; member 21 "$SHA21" "$T/bodies/21"
  record "$T/bodies/22" "$SHA22" "$A1" "$A2" "$A3" "$A4"; member 22 "$SHA22" "$T/bodies/22"
}

# bplan <VAR=val ...> [-- args] — one batch plan; sets RC OUT GO; the list is $T/list.
bplan() {
  local vars=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && { shift; args=("$@"); }
  rm -f "$T/go" "$T/list"; : > "$T/sink"
  OUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_PLAN_ESCALATION -u CI_ALWAYS_PREPUSH_SKIP -u CI_PLAN_PREPUSH_FILE \
          -u CI_PLAN_DURATIONS_FILE -u CI_PLAN_REUSE -u CI_PLAN_REUSED_FILE -u CI_PLAN_MEMBER_REACH \
          CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/x TI_BASE="$HEADSHA" TI_PR_LABELS= CI_QUARANTINE= \
          TI_PR_TITLE="$TITLE" CI_PR_BODY="$DRAFT" CI_REPO=o/r CI_PLAN_GH="$T/gh" GH_SINK="$T/sink" FAKE_GH_DIR="$T/prs" \
          CI_PLAN_IMPACT="$T/fake.sh" FAKE_SELECT="$T/sel.txt" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_PLAN_PREPUSH_LIST="$T/pplist" GITHUB_OUTPUT="$T/go" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" ${args[@]+"${args[@]}"} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
inlist() { grep -qxF -- "$1" "$T/list"; }
none_dropped() { # none_dropped <tag> — A1..A4 all run and prepush=off
  local s miss=""
  for s in $A1 $A2 $A3 $A4; do inlist "$s" || miss="$miss $s"; done
  { [ "$RC" = 0 ] && [ -z "$miss" ] && [ "$(out prepush)" = off ] && [ "$(out count)" = 8 ]; } && ok \
    || bad "$1: nothing may be dropped (rc=$RC missing:${miss:- none} prepush=$(out prepush) count=$(out count)) [$OUT]"
}

# ── P1 (A1). every member green on its head.
setup_green
bplan
for s in $A1 $A2 $A3 $A4; do check "P1 $s is dropped" '! inlist "$s"'; done
for s in $A5 $A6 $X1 $X2; do check "P1 $s still runs" 'inlist "$s"'; done
check "P1 rc 0, prepush=4, count 4 (rc=$RC prepush=$(out prepush) count=$(out count))" '[ "$RC" = 0 ] && [ "$(out prepush)" = 4 ] && [ "$(out count)" = 4 ]'
check "P1 the line says dropped 4 of 4 for 2 members: $(grep 'prepush:' <<<"$OUT")" 'grep -qxF "ci-plan: prepush: dropped 4 of 4 listed suites (2 members, all with a green record on their head)" <<<"$OUT"'
check "P1 the reason ends in '; prepush -4': $(out summary)" 'case "$(out summary)" in *"; prepush -4) — "*) true ;; *) false ;; esac'
check "P1 mode stays batch-selected" '[ "$(out mode)" = batch-selected ]'
check "P1 no gh call beyond the two member reads" '[ "$(sort "$T/sink" | tr "\n" " ")" = "api repos/o/r/pulls/21 api repos/o/r/pulls/22 " ]'
P1_COUNT=$(out count)

# ── P2 (A2). member #22 has no record.
setup_green; printf '## What\n\nNo gate ran.\n' > "$T/bodies/22"; member 22 "$SHA22" "$T/bodies/22"
bplan
none_dropped P2
check "P2 the line names #22 and its sha: $(grep 'prepush:' <<<"$OUT")" 'grep -qxF "ci-plan: prepush: off (#22 has no green record on ${SHA22:0:8})" <<<"$OUT"'
check "P2 count is 4 higher than P1 ($(out count) vs $P1_COUNT)" '[ "$(out count)" = $((P1_COUNT + 4)) ]'

# ── P3. #22's head moved after the gate.
setup_green; member 22 3333333333333333333333333333333333333333 "$T/bodies/22"
bplan
none_dropped P3

# ── P4. the intersection.
setup_green; record "$T/bodies/22" "$SHA22" "$A1" "$A2" "$A3"; member 22 "$SHA22" "$T/bodies/22"
bplan
check "P4 prepush=3, A4 runs, A1..A3 do not (prepush=$(out prepush))" '[ "$(out prepush)" = 3 ] && inlist "$A4" && ! inlist "$A1" && ! inlist "$A2" && ! inlist "$A3"'

# ── P5. two markers.
setup_green; cat "$T/bodies/22" "$T/bodies/22" > "$T/bodies/22b"; member 22 "$SHA22" "$T/bodies/22b"
bplan
none_dropped P5

# ── P6. a v2 record.
setup_green; sed 's/prepush-gate-record v1 /prepush-gate-record v2 /' "$T/bodies/22" > "$T/bodies/22v"; member 22 "$SHA22" "$T/bodies/22v"
bplan
none_dropped P6

# ── P7. the knob.
setup_green
bplan CI_ALWAYS_PREPUSH_SKIP=0
none_dropped "P7 =0"
check "P7 =0 is named" 'grep -qxF "ci-plan: prepush: off (CI_ALWAYS_PREPUSH_SKIP=0)" <<<"$OUT"'
bplan CI_ALWAYS_PREPUSH_SKIP=yes
none_dropped "P7 =yes"
check "P7 =yes is named" 'grep -qxF "ci-plan: prepush: off (CI_ALWAYS_PREPUSH_SKIP=yes)" <<<"$OUT"'
bplan CI_ALWAYS_PREPUSH_SKIP=1
check "P7 =1 drops (prepush=$(out prepush))" '[ "$(out prepush)" = 4 ]'

# ── P8. the draft's own full label: the members are never read.
setup_green
bplan TI_PR_LABELS=full
check "P8 rc 0, prepush=off, members not read: $(grep 'prepush:' <<<"$OUT")" '[ "$RC" = 0 ] && [ "$(out prepush)" = off ] && grep -qxF "ci-plan: prepush: off (members not read)" <<<"$OUT"'
for s in $A1 $A2 $A3 $A4; do check "P8 $s runs" 'inlist "$s"'; done

# ── P9. a member that cannot be read.
setup_green
bplan FAKE_GH_FAIL=22
check "P9 rc 0, prepush=off, A1..A4 run (prepush=$(out prepush))" '[ "$RC" = 0 ] && [ "$(out prepush)" = off ] && inlist "$A1" && inlist "$A4"'

# ── P10. quarantine.
setup_green
# The tier step drops a quarantined suite from a batch unless it is protected,
# so $A2 is protected here: it stays in the list, and the drop must keep it.
printf '%s  fixture\n' "$A2" > "$T/protected"
bplan CI_QUARANTINE="$A2" CI_PLAN_PROTECTED="$T/protected"
check "P10 the quarantined $A2 runs, the other 3 are dropped (prepush=$(out prepush))" 'inlist "$A2" && [ "$(out prepush)" = 3 ] && ! inlist "$A1"'

# ── P11. a regression row (catalog/ci-batch-regression.d/bh-6838.txt names A4) re-adds it.
setup_green; printf 'worker/jobs/test/route-table.d/x.json\n' > "$T/changed.reg"
bplan CI_PLAN_CHANGED_FILE="$T/changed.reg"
check "P11 $A4 runs again through the regression union: $(grep 'regression' <<<"$OUT" | head -2)" 'inlist "$A4" && ! inlist "$A1"'

# ── P12. an ordinary PR.
setup_green
bplan TI_PR_HEAD_REF=ticket/bh-1
check "P12 rc 0, no prepush key, no line, the list whole (count=$(out count))" '[ "$RC" = 0 ] && ! grep -q "^prepush=" "$T/go" && ! grep -q "prepush:" <<<"$OUT" && [ "$(out count)" = 8 ]'
check "P12 no gh call" '[ ! -s "$T/sink" ]'

# ── P13. lines that are not a plain tests/ path.
setup_green
{ printf '<!-- prepush-gate-record v1 head=%s -->\n' "$SHA22"
  printf 'prepush-ran: ../%s\nprepush-ran: %s; rm -rf x\nprepush-ran: %s\n' "$A2" "$A3" "$A1"
  printf '<!-- /prepush-gate-record -->\n'; } > "$T/bodies/22x"
member 22 "$SHA22" "$T/bodies/22x"
bplan
check "P13 only A1 is dropped (prepush=$(out prepush))" '[ "$(out prepush)" = 1 ] && ! inlist "$A1" && inlist "$A2" && inlist "$A3"'

# ── P14. a quoted marker.
setup_green; sed 's/^/> /' "$T/bodies/22" > "$T/bodies/22q"; member 22 "$SHA22" "$T/bodies/22q"
bplan
none_dropped P14

# ── P15. plan job, then a shard.
setup_green
bplan CI_PLAN_PREPUSH_FILE="$T/pp-drop.txt"
PN=$(out n); PE=$(out escalation); cp "$T/list" "$T/plan.list"
check "P15 the plan job wrote prepush=on and the 4 suites" '[ "$(head -1 "$T/pp-drop.txt")" = prepush=on ] && [ "$(tail -n +2 "$T/pp-drop.txt" | LC_ALL=C sort | tr "\n" " ")" = "$(printf "%s\n" $A1 $A2 $A3 $A4 | LC_ALL=C sort | tr "\n" " ")" ]'
bplan CI_PLAN_PREPUSH_FILE="$T/pp-drop.txt" CI_PLAN_ESCALATION="$PE" FAKE_GH_FAIL=21 -- --expect-n "$PN"
check "P15 the shard agrees on n, makes no gh call and plans the same list (rc=$RC) [$OUT]" '[ "$RC" = 0 ] && [ ! -s "$T/sink" ] && cmp -s "$T/list" "$T/plan.list" && [ "$(out prepush)" = 4 ]'
bplan CI_PLAN_ESCALATION="$PE" -- --expect-n "$PN"
check "P15 a shard with no file drops nothing" '[ "$(grep -c . "$T/list")" = 8 ]'
setup_green; printf '## What\n' > "$T/bodies/22"; member 22 "$SHA22" "$T/bodies/22"
bplan CI_PLAN_PREPUSH_FILE="$T/pp-off.txt"
check "P15 an off plan writes prepush=off and nothing else" '[ "$(cat "$T/pp-off.txt")" = prepush=off ]'
bplan CI_PLAN_PREPUSH_FILE="$T/pp-off.txt" CI_PLAN_ESCALATION=- -- --expect-n "$(out n)"
check "P15 a shard of an off plan drops nothing (rc=$RC)" '[ "$RC" = 0 ] && [ "$(grep -c . "$T/list")" = 8 ]'

# ── P16. a shard whose file is unreadable or malformed.
bplan CI_PLAN_PREPUSH_FILE="$T/no-such-file" CI_PLAN_ESCALATION=- -- --expect-n 1
check "P16 unreadable: rc 1 (rc=$RC)" '[ "$RC" = 1 ] && grep -q "prepush drop" <<<"$OUT"'
printf 'garbage\n%s\n' "$A1" > "$T/pp-bad.txt"
bplan CI_PLAN_PREPUSH_FILE="$T/pp-bad.txt" CI_PLAN_ESCALATION=- -- --expect-n 1
check "P16 malformed: rc 1 (rc=$RC)" '[ "$RC" = 1 ]'

# ── P17. a plan job that cannot write its file.
setup_green
bplan CI_PLAN_PREPUSH_FILE="$T/no-such-dir/pp.txt"
check "P17 rc 2 (rc=$RC)" '[ "$RC" = 2 ] && grep -q "cannot write the prepush drop" <<<"$OUT"'

echo "always-set-prepush.bh-7289: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

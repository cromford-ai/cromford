#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stack-wait-parent-merge.bh-5234-test.sh — BH-5234. A child whose parent
# PR is still open is no longer always stacked on the parent's branch. The knob
# STACK_WAIT_PARENT_MERGE = off|rollouts|all (default rollouts), resolved by
# sp_wait_mode in bin/lib/stale-parent.sh, decides which children wait for the
# parent to MERGE instead:
#   off      — today's behaviour: every eligible child stacks.
#   rollouts — a rollout-wave child (a body line `Rollout wave N of M: ...`,
#              written by bin/lib/file-children.sh fc_child_footer) waits; every
#              other child stacks as today.
#   all      — no child stacks; every one waits for the merge.
# An invalid value is `plan` (BH-6389), with ONE line in logs/stale-parent.log;
# the launch side reads `plan` as `rollouts`.
#
# Two places obey it, and both are DRIVEN here rather than grepped:
#   1. bin/unblocked-children.sh (the launch side) emits no STACKABLE line for a
#      waiting child. Driven against a gh stub shaped like the one
#      tests/stacked-child-builds-test.sh uses.
#   2. the `stacked child builds` block of bin/lib/rb/gates.sh (the builder
#      side) answers BUILD_DEFERRED stack-wait and exits 3 instead of cutting the
#      branch from the parent, when the parent branch is still fetchable. Driven
#      against a REAL repo, because the fetch is the block's existence probe.
# Run from anywhere: tests/stack-wait-parent-merge.bh-5234-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset STACK_WAIT_PARENT_MERGE

UC="$DIR/bin/unblocked-children.sh"
SP_LIB="$DIR/bin/lib/stale-parent.sh"
GATES="$DIR/bin/lib/rb/gates.sh"
# The lib does not exist before BH-5234 lands: that is a red, never a skip.
[ -f "$SP_LIB" ] && ok || bad "bin/lib/stale-parent.sh is missing — sp_wait_mode has nowhere to live"
grep -q '^# >>> stacked child builds' "$GATES" && ok || bad "the stacked child builds block is not in bin/lib/rb/gates.sh any more"

# ============================================================================
# 1. bin/unblocked-children.sh — the launch side
# ============================================================================
mkdir -p "$T/h/flags" "$T/h/bin/lib" "$T/h/logs" "$T/fakebin"
export HARNESS="$T/h" GH_ISSUES_REPO="org/repo"
# The soft class judges Blocked-by lines on its own evidence; it is not this
# ticket's subject, so it is off in both spellings and cannot release a child.
export DEP_VERIFY=0; touch "$T/h/flags/dep-verify-off"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
case "$*" in
  *"issue list"*) cat "$HARNESS/issues.json" ;;
  *"pr list"*)    cat "$HARNESS/prs.json" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"; export PATH="$T/fakebin:$PATH"
scratch_install_closure bin/lib/gh-rest-list.sh "$T/h" >/dev/null || bad "could not install the gh-rest closure into the scratch harness"
scratch_install_closure bin/lib/stale-parent.sh "$T/h" >/dev/null 2>&1 \
  || bad "could not install bin/lib/stale-parent.sh into the scratch harness"
uc() { "$UC" p 2>/dev/null; }

write_issues() { # write_issues <OPEN|CLOSED> — the state of blocker #1
  jq -n --arg s "$1" '[
   {number:1, state:$s, title:"XX-1 the parent", body:"parent work\nPart of #9"},
   {number:2, state:"OPEN", title:"XX-2 rollout wave", labels:[{name:"ai-build"}],
    body:"## Scope\nPart of #9\nBlocked-by: #1 (hard)\nRollout wave 2 of 3: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again."},
   {number:3, state:"OPEN", title:"XX-3 ordinary child", labels:[{name:"ai-build"}],
    body:"## Scope\nPart of #9\nBlocked-by: #1 (hard)"}
  ]' > "$T/h/issues.json"
}
write_issues OPEN
cat > "$T/h/prs.json" <<'JSON'
[
 {"number":900,"url":"https://github.com/org/repo/pull/900","title":"XX-1: the parent","headRefName":"ticket/xx-1","isDraft":false}
]
JSON
DIFF_OPEN='board issues: CHANGED 3 "XX-3 ordinary child" (comments: 1 -> 2; activity)'
DIFF_CLOSED='board issues: CHANGED 1 "XX-1 the parent" (state: open -> closed; comments: 3 -> 4)'

# W1 + W2: default knob (unset) = rollouts. The rollout wave waits for the
# merge; the ordinary child stacks exactly as it does today, chain tag included.
OUT=$(uc <<<"$DIFF_OPEN")
grep -q 'STACKABLE 2 ' <<<"$OUT" \
  && bad "W1: a rollout-wave child must not be STACKABLE under the default knob (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 3 "XX-3 ordinary child" base=ticket/xx-1 parent-pr=https://github.com/org/repo/pull/900 chain=#9 ' <<<"$OUT" \
  && ok || bad "W2: an ordinary child keeps today's STACKABLE line with chain=#9 under the default knob (got: $OUT)"

# W3: off = today's behaviour, the rollout wave stacks too.
OUT=$(STACK_WAIT_PARENT_MERGE=off uc <<<"$DIFF_OPEN")
grep -q '^board issues: STACKABLE 2 .*base=ticket/xx-1' <<<"$OUT" \
  && ok || bad "W3: STACK_WAIT_PARENT_MERGE=off must stack the rollout wave as today (got: $OUT)"
grep -q '^board issues: STACKABLE 3 ' <<<"$OUT" && ok || bad "W3: off must still stack the ordinary child (got: $OUT)"

# W4: all = nothing stacks.
OUT=$(STACK_WAIT_PARENT_MERGE=all uc <<<"$DIFF_OPEN")
grep -q 'STACKABLE 2 ' <<<"$OUT" && bad "W4: =all must not stack the rollout wave (got: $OUT)" || ok
grep -q 'STACKABLE 3 ' <<<"$OUT" && bad "W4: =all must not stack the ordinary child either (got: $OUT)" || ok

# W5: an invalid value reads as plan (BH-6389; it was rollouts), which the
# launch side treats as rollouts, and says so once in the lib's log.
: > "$T/h/logs/stale-parent.log"
OUT=$(STACK_WAIT_PARENT_MERGE=bogus uc <<<"$DIFF_OPEN")
grep -q 'STACKABLE 2 ' <<<"$OUT" && bad "W5: =bogus must behave as rollouts — no STACKABLE 2 (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 3 ' <<<"$OUT" && ok || bad "W5: =bogus must behave as rollouts — STACKABLE 3 present (got: $OUT)"
SPLOG=$(cat "$T/h/logs/stale-parent.log" 2>/dev/null)
[ "$(grep -c . <<<"$SPLOG")" = 1 ] && grep -q 'bogus' <<<"$SPLOG" && grep -q 'using plan$' <<<"$SPLOG" \
  && ok || bad "W5: exactly one stale-parent.log line naming 'bogus' and 'plan' (got: $SPLOG)"

# W6: the parent CLOSED — the knob only governs stacking, so the release is
# untouched under every mode.
write_issues CLOSED
for m in off rollouts all; do
  OUT=$(STACK_WAIT_PARENT_MERGE=$m uc <<<"$DIFF_CLOSED")
  grep -q '^board issues: UNBLOCKED 2 ' <<<"$OUT" \
    && ok || bad "W6: with #1 closed, #2 must be UNBLOCKED under STACK_WAIT_PARENT_MERGE=$m (got: $OUT)"
done
write_issues OPEN

# ============================================================================
# 2. bin/lib/rb/gates.sh — the builder side, `stacked child builds` block
# ============================================================================
# A separate scratch harness: the block must reach the issue through the
# pipeline's own gh_rest (stubbed below), so no gh-rest.sh sits beside the lib
# here to redefine it.
mkdir -p "$T/b/bin/lib" "$T/b/flags" "$T/b/logs"
cp "$DIR/bin/fleet-conf.sh" "$T/b/bin/"
# scratch-closure-allow: the builder block is driven with a stubbed gh_rest, so the lib's own closure (gh-rest.sh) must not ride along and redefine it
cp "$DIR/bin/lib/stale-parent.sh" "$T/b/bin/lib/" 2>/dev/null || bad "could not copy bin/lib/stale-parent.sh into the builder harness"
cat > "$T/b/fleet.conf" <<'CONF'
# project repo prod board_prefix offset box tailnet_ip
demo-os example-org/demo-os https://demo.example.com - 0 box1 192.0.2.1
demo-board example-org/demo-board https://board.example.com /api/boards/b1 0 box1 192.0.2.1
CONF
export FLEET_CONF="$T/b/fleet.conf"
[ "$("$T/b/bin/fleet-conf.sh" demo-os board_prefix)" = "-" ] && ok || bad "fixture: demo-os must read as an issues project (board_prefix -)"
[ "$("$T/b/bin/fleet-conf.sh" demo-board board_prefix)" = "/api/boards/b1" ] && ok || bad "fixture: demo-board must read as a board project"

git init -q --bare "$T/origin.git"
git init -q "$T/seed" && ( cd "$T/seed"
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add f.txt; git commit -qm base
  git branch -M main; git remote add origin "$T/origin.git"; git push -q origin main
  git checkout -qb ticket/TK-41; echo parent >> f.txt; git commit -qam parent; git push -q origin ticket/TK-41 ) >/dev/null 2>&1
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
git -C "$T/repo" ls-remote --exit-code origin ticket/TK-41 >/dev/null 2>&1 && ok || bad "fixture: origin must carry the parent branch"

awk '/^# >>> stacked child builds/{f=1;next} /^# <<< stacked child builds/{exit} f' \
  "$RB_ALL" > "$T/stack.sh"
[ -s "$T/stack.sh" ] && ok || bad "could not extract the stacked-base block — markers missing?"

# The driver: exactly the names run-build.sh has at that point, plus the
# pipeline's RESULT/STAMP and a gh_rest stub that logs and answers per body-mode.
cat > "$T/driver.sh" <<'SH'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { printf '%s\n' "$*" > "$T/result"; }
gh_rest() {
  printf '%s\n' "$*" >> "$T/rest-calls.txt"
  case "$*" in *issues/42*) ;; *) return 1 ;; esac
  case "$(cat "$T/body-mode")" in
    rollout) jq -nc '{number:42, body:"Part of #9\nBlocked-by: #41 (hard)\nRollout wave 2 of 3: planned by its author"}' ;;
    plain)   jq -nc '{number:42, body:"Part of #9\nBlocked-by: #41 (hard)"}' ;;
    *)       return 75 ;;
  esac
}
BASE=main
. "$1"
printf '%s|%s\n' "$BASE" "$STACK_ON"
SH
run_wait() { # run_wait <body-mode> [env assignments...] ; prints "rc|BASE|STACK_ON"
  local bm="$1" out rc; shift
  printf '%s\n' "$bm" > "$T/body-mode"
  rm -f "$T/result"; : > "$T/rest-calls.txt"
  mkdir -p "$T/b/builds/b"; : > "$T/b/builds/b/pipeline.log"
  out=$( export T HARNESS="$T/b" PROJECT=demo-os KEY=TK-42 TICKET=42 GH_AUTH_SLUG=example-org/demo-os \
           BUILD="$T/b/builds/b" REPO="$T/repo" STACK_BASE=ticket/TK-41 \
           STACK_PARENT_PR=https://github.com/example-org/demo-os/pull/900
         export "$@" 2>/dev/null || true
         bash "$T/driver.sh" "$T/stack.sh" 2>/dev/null ); rc=$?
  printf '%s|%s\n' "$rc" "$out"
}
DEFER='BUILD_DEFERRED stack-wait: parent branch ticket/TK-41 is still open and STACK_WAIT_PARENT_MERGE='

# W7: default knob, rollout body, parent fetchable -> deferred, never stacked.
R=$(run_wait rollout X=1)
[ "${R%%|*}" = 3 ] && ok || bad "W7: a rollout child with a live parent must exit 3 under the default knob (got '$R')"
grep -q "^${DEFER}rollouts" "$T/result" 2>/dev/null \
  && ok || bad "W7: RESULT must be BUILD_DEFERRED stack-wait naming =rollouts (got: $(cat "$T/result" 2>/dev/null))"
[ "$R" = "3|" ] && ok || bad "W7: the deferred path must not reach the end of the block with STACK_ON set (got '$R')"
grep -q 'STACKED on' "$T/b/builds/b/pipeline.log" && bad "W7: a deferred child must not log STACKED on" || ok
grep -q 'GET repos/example-org/demo-os/issues/42' "$T/rest-calls.txt" \
  && ok || bad "W7: rollouts mode must read the issue through gh_rest GET repos/\$GH_AUTH_SLUG/issues/\$TICKET (got: $(cat "$T/rest-calls.txt"))"

# W8: default knob, ordinary body -> today's stack.
R=$(run_wait plain X=1)
[ "$R" = "0|ticket/TK-41|ticket/TK-41" ] && ok || bad "W8: a non-rollout child must stack on the parent exactly as today (got '$R')"
[ -e "$T/result" ] && bad "W8: a stacked build must not write a RESULT (got: $(cat "$T/result"))" || ok
grep -q 'STACKED on ticket/TK-41' "$T/b/builds/b/pipeline.log" && ok || bad "W8: the stack must still be logged"

# W9: the issue read failed -> rollouts cannot tell, so it waits.
R=$(run_wait fail STACK_WAIT_PARENT_MERGE=rollouts)
[ "${R%%|*}" = 3 ] && ok || bad "W9: a failed issue read under rollouts must defer (got '$R')"
grep -q "^${DEFER}rollouts" "$T/result" 2>/dev/null \
  && ok || bad "W9: RESULT must be BUILD_DEFERRED stack-wait (got: $(cat "$T/result" 2>/dev/null))"

# W10: off -> never defers and never reads the issue.
R=$(run_wait rollout STACK_WAIT_PARENT_MERGE=off)
[ "$R" = "0|ticket/TK-41|ticket/TK-41" ] && ok || bad "W10: =off must stack a rollout child as today (got '$R')"
grep -q 'issues/42' "$T/rest-calls.txt" && bad "W10: =off must not read the issue (got: $(cat "$T/rest-calls.txt"))" || ok

# all on a BOARD project: deferred with no issue read at all.
R=$(run_wait plain STACK_WAIT_PARENT_MERGE=all PROJECT=demo-board GH_AUTH_SLUG=example-org/demo-board)
[ "${R%%|*}" = 3 ] && ok || bad "=all on a board project must defer (got '$R')"
grep -q "^${DEFER}all" "$T/result" 2>/dev/null \
  && ok || bad "=all: RESULT must name STACK_WAIT_PARENT_MERGE=all (got: $(cat "$T/result" 2>/dev/null))"
grep -q 'issues/' "$T/rest-calls.txt" && bad "=all must defer without reading any issue (got: $(cat "$T/rest-calls.txt"))" || ok

echo "stack-wait-parent-merge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/mc-stack-follow.bh-1670-test.sh — BH-1670: when the conductor settles a
# parent PR as MERGED, each open child based on the parent's branch is
# retargeted to the project base, THEN rebased `--onto <base> <parent's
# pre-merge head sha>` and pushed once.
#
# THE DEFECT THIS PINS (project-5 #3180 on #3117). The parent was squash-merged.
# The child was retargeted to main, but its branch still carried the parent's
# pre-squash commits, and nothing pushed it, so it sat with no CI and a diff
# that was two tickets wide until somebody rebased it by hand.
#
# Sections A-C, E and F source the real lib and drive `conductor_settle` (the
# function every conductor merge settles through) against a REAL bare origin, so
# every git assertion is about the origin's own refs. D drives a whole
# bin/merge-conductor.sh tick with an argv-recording git, because what it pins
# is the pr_worker wiring. gh is a stub that records every argv.
#
# D1 MUTATIONS, run once before the PR and confirmed red: delete the follow
# call in conductor_settle (A red), swap the PATCH and the push (A red), pass
# `origin/$oldbase` for the sha (A red), drop `parent=#N` from the park reason
# (B red).
#
# Run from anywhere: tests/mc-stack-follow.bh-1670-test.sh   (exit 0 = all pass)
set -uo pipefail
# TEST-CHANGE (BH-1585 shape): section D's tick reads the open list over REST;
# the bridge answers those reads from the GraphQL list its stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/settle.sh" ] && [ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: bin/lib/mc/settle.sh bin/lib/mc/rebase.sh
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/merge-conductor.sh
REALGIT=$(command -v git)
SLUG=example-org/demo-os

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# ── the scratch harness ──────────────────────────────────────────────────────
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
# The children list is _gpm_open_children, which the lib sources from here.
cp "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/gh-pr-create.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/repos"

# git: the real one, with every push also written to the shared event log, so
# the order of the base PATCH and the push is observable.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/events.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"

# gh: every argv to gh-argv.txt; the base PATCH also to events.txt. The child
# PR (#2) is read back from files so each case can shape it.
# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0   # BH-2504: an unheld ticket
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pulls?state=open&base=ticket%2Fbh-1&per_page=100"*)
    case "\$(cat "$T/mode-children")" in
      500)  restpr --raw 500 '{"message":"boom"}' ;;
      full) restpr --raw 200 "\$(jq -nc '[range(100)|{number:(.+100)}]')" ;;
      *)    restpr --raw 200 '[{"number":2,"base":{"ref":"ticket/bh-1"}}]' ;;
    esac ;;
  # A PR on a DIFFERENT feature branch: listed only when asked for that base.
  *"pulls?state=open&base=ticket%2Fbh-9&per_page=100"*) restpr --raw 200 '[{"number":3}]' ;;
  # TEST-CHANGE (BH-5234): mc_restack reads the restacked child's own open
  # children before it pushes; ticket/bh-2 has none.
  *"pulls?state=open&base=ticket%2Fbh-2&per_page=100"*) restpr --raw 200 '[]' ;;
  *"api -X PATCH repos/$SLUG/pulls/"*" -f base="*)
    printf 'PATCH %s\n' "\$*" >> "$T/events.txt"
    [ -f "$T/patch-fails" ] && exit 1
    printf '%s' "\${*##*base=}" > "$T/child-base"; exit 0 ;;
  *"api -X PATCH repos/$SLUG/pulls/"*" -f state="*) printf 'KICK %s\n' "\$*" >> "$T/events.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/2"*)
    [ -f "$T/child-read-fails" ] && { restpr --raw 502 '{"message":"bad gateway"}'; exit 0; }
    case "\$(cat "$T/child-state")" in CLOSED) st=closed ;; *) st=open ;; esac
    restpr --raw 200 "\$(jq -nc --arg st "\$st" --arg sha "\$(cat "$T/child-head")" \
      --arg base "\$(cat "$T/child-base")" --arg repo "\$(cat "$T/child-repo")" \
      '{number:2,state:\$st,merged_at:null,head:{sha:\$sha,ref:"ticket/bh-2",repo:{full_name:\$repo}},base:{ref:\$base},labels:[],html_url:"https://github.com/$SLUG/pull/2"}')" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# fixture <case> — a fresh origin: main, the parent ticket/bh-1 (two commits),
# the child ticket/bh-2 (one commit on the parent), the parent SQUASH-merged
# into main and its branch deleted from origin, which is the stuck shape.
#   conflict  main also edits the child's line, so the replay conflicts
#   revert   the replay conflicts but a merge of main is clean (BH-5967)
#   forced   the parent is force-pushed AFTER the child was cut, and the
#            rewritten head is the one that merged (not an ancestor of the child)
fixture() {
  local mode="${1:-}" S="$T/seed"
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor"
  : > "$T/events.txt"; : > "$T/gh-argv.txt"; : > "$T/h/logs/merge-conductor.log"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv" "$T/patch-fails" "$T/child-read-fails"
  rm -rf "$T/h/state/stack-follow"
  echo ok > "$T/mode-children"; echo OPEN > "$T/child-state"
  echo ticket/bh-1 > "$T/child-base"; echo "$SLUG" > "$T/child-repo"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  printf 'base\n' > "$S/a.txt"; printf 'c0\n' > "$S/child.txt"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb ticket/bh-1
  printf 'p1\n' > "$S/p1.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p1
  printf 'p2\n' > "$S/p2.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p2
  "$REALGIT" -C "$S" checkout -qb ticket/bh-2
  printf 'child\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam child
  CHILD0=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q ticket/bh-1
  if [ "$mode" = forced ]; then
    printf 'p2-rewritten\n' > "$S/p2.txt"; "$REALGIT" -C "$S" commit -q --amend -am p2b
  fi
  PHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main
  "$REALGIT" -C "$S" merge -q --squash ticket/bh-1 >/dev/null && "$REALGIT" -C "$S" commit -qm 'parent (#1)'
  if [ "$mode" = conflict ]; then
    printf 'main-edit\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam 'main edits the child line'
  fi
  # BH-5967 `revert`: the child's FIRST commit edits child.txt and its second
  # puts it back, beside its own file. main edits child.txt too, so replaying
  # the first commit conflicts, while a merge of main (the child's net change to
  # child.txt is none) is clean.
  if [ "$mode" = revert ]; then
    "$REALGIT" -C "$S" checkout -q ticket/bh-2
    printf 'c0\n' > "$S/child.txt"; printf 'own\n' > "$S/own.txt"
    "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm 'child puts child.txt back, adds own.txt'
    CHILD0=$("$REALGIT" -C "$S" rev-parse HEAD)
    "$REALGIT" -C "$S" checkout -q main
    printf 'main-edit\n' > "$S/child.txt"; "$REALGIT" -C "$S" commit -qam 'main edits the child line'
  fi
  "$REALGIT" -C "$S" push -q origin main ticket/bh-2 2>/dev/null
  CHEAD=$CHILD0; printf '%s' "$CHEAD" > "$T/child-head"
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
PEND="$T/h/state/stack-follow/example-org_demo-os#2"
LOG="$T/h/logs/merge-conductor.log"
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export PATH="$T/fakebin:$PATH"
# BH-1715: the give-up limits are REQUIRED registry knobs with no literal in
# the lib. bin/merge-conductor.sh's `lane_env_apply merge-conductor` exports a
# required knob's registry default when no settings row exists; this fixture
# sources the lib without the tick, so it exports the same two defaults.
export MC_STACK_FOLLOW_TRIES=3 MC_STACK_FOLLOW_GIVEUP_S=21600
MERGES=0
settle() { conductor_settle "$SLUG#1" "https://github.com/$SLUG/pull/1" demo-os "$SLUG" ticket/bh-1 "" "" \
             "$PHEAD" "$PHEAD" APPROVE CLEAN "merged" "" >/dev/null 2>&1; }

# ============================================================================
# A. The parent settles MERGED: retarget, then rebase --onto main <sha>, then
#    ONE push, and no close/reopen kick.
# ============================================================================
fixture; ACTIONS=1; settle
grep -q 'pulls?state=open&base=ticket%2Fbh-1&per_page=100' "$T/gh-argv.txt" \
  && ok || bad "A: the children must be read from base.ref == the parent's branch (got: $(grep pulls "$T/gh-argv.txt" | head -3))"
grep -q 'PATCH .*pulls/2 -f base=main' "$T/events.txt" \
  && ok || bad "A: the child must be retargeted to main (events: $(cat "$T/events.txt"))"
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] \
  && ok || bad "A: exactly one push (events: $(cat "$T/events.txt"))"
PL=$(grep -n '^PATCH' "$T/events.txt" | head -1 | cut -d: -f1); UL=$(grep -n '^PUSH' "$T/events.txt" | head -1 | cut -d: -f1)
[ -n "$PL" ] && [ -n "$UL" ] && [ "$PL" -lt "$UL" ] \
  && ok || bad "A: the base PATCH must come BEFORE the push (events: $(cat "$T/events.txt"))"
[ "$(origin_rev ticket/bh-2^)" = "$(origin_rev main)" ] \
  && ok || bad "A: the child's new parent must be main's tip (child^=$(origin_rev ticket/bh-2^) main=$(origin_rev main))"
[ "$("$REALGIT" -C "$T/origin.git" rev-list --count main..ticket/bh-2)" = 1 ] \
  && ok || bad "A: the child must carry exactly its own one commit over main (got $("$REALGIT" -C "$T/origin.git" rev-list --count main..ticket/bh-2))"
pid() { "$REALGIT" -C "$T/origin.git" show "$1" | "$REALGIT" patch-id --stable | cut -d' ' -f1; }
[ -n "$(pid "$CHEAD")" ] && [ "$(pid ticket/bh-2)" = "$(pid "$CHEAD")" ] \
  && ok || bad "A: the replayed commit must be the child's own change (patch-id differs)"
grep -q 'state=closed' "$T/gh-argv.txt" \
  && bad "A: no close/reopen kick on this path — the push is the CI trigger" || ok
[ -e "$PEND" ] && bad "A: the pending follow must be cleared after the push" || ok
grep -q 'demo-os#2 restacked onto main after parent=#1' "$LOG" \
  && ok || bad "A: the log must say the child was restacked (got: $(grep 'demo-os#2' "$LOG" | tail -2))"
grep -q "stackfollow $SLUG#2 $(origin_rev ticket/bh-2)" "$MC_ATTEMPTS" \
  && ok || bad "A: the attempt line must carry the pushed head"
grep -q 'pulls/3' "$T/gh-argv.txt" && bad "A: a PR on another feature branch must not be touched" || ok
[ "$(state_of "$SLUG#1")" = MERGED ] && ok || bad "A: the parent row must still settle MERGED"

# ============================================================================
# B. The replay conflicts: parked conflict-unresolvable with parent=#1, the
#    resolver owns it, the retarget happened, nothing was pushed.
# ============================================================================
fixture conflict; ACTIONS=1; settle
[ "$(state_of "$SLUG#2")" = BLOCKED_HUMAN ] && ok || bad "B: the child must park BLOCKED_HUMAN (got $(state_of "$SLUG#2"))"
R=$(reason_of "$SLUG#2")
case "$R" in conflict-unresolvable:*parent=#1*child.txt*) ok ;; *) bad "B: the reason must be conflict-unresolvable naming parent=#1 and the file (got: $R)" ;; esac
grep -q "$SLUG#2 BLOCKED_AGENT conflict-unresolvable: .*parent=#1" "$LOG" \
  && ok || bad "B: the log must say BLOCKED_AGENT with parent=#1 (got: $(grep 'demo-os#2' "$LOG" | tail -2))"
grep -q 'PATCH .*pulls/2 -f base=main' "$T/events.txt" && ok || bad "B: the retarget must still happen"
grep -q '^PUSH' "$T/events.txt" && bad "B: a conflicted replay must never be pushed" || ok
[ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "B: origin's child head must be untouched"
[ -e "$PEND" ] && bad "B: the pending follow must be cleared once the resolver owns the child" || ok
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
BRFN=$(sed -n '/^br_reason_of() {/,/^}/p' "$T/br-corpus.sh")
[ -n "$BRFN" ] && eval "$BRFN" && [ "$(br_reason_of "$R")" = conflict-unresolvable ] \
  && ok || bad "B: bin/blocked-resolver.sh must read this reason as conflict-unresolvable"

# ============================================================================
# G. BH-5967: the replay conflicts but a merge of main is clean. The conductor
#    merges main into the child and pushes; nothing parks, and no person rebases.
# ============================================================================
fixture revert; ACTIONS=1; settle
[ "$(state_of "$SLUG#2")" = BLOCKED_HUMAN ] && bad "G: THE BUG: a child main merges into cleanly was parked ($(reason_of "$SLUG#2"))" || ok
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] && ok || bad "G: one push of the merged child (events: $(cat "$T/events.txt"))"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor main ticket/bh-2 2>/dev/null && ok \
  || bad "G: main is merged into the child on origin"
[ "$(origin_rev ticket/bh-2)" != "$CHEAD" ] && ok || bad "G: the child head moved"
grep -q "$SLUG#2 STACK_MAIN_MERGED .*parent=#1 merged and the replay onto main conflicted in child.txt, so main was merged into the child instead and pushed" "$LOG" && ok \
  || bad "G: the log says main was merged in: $(grep 'demo-os#2' "$LOG" | tail -2)"
grep -qi 'rebase by hand\|human rebase' "$LOG" && bad "G: no line asks a person to rebase: $(grep -i 'by hand' "$LOG")" || ok
[ -e "$PEND" ] && bad "G: the pending follow is cleared after the push" || ok

# ============================================================================
# H. BH-5967 (review of 99682a0c6): the merge of main is clean but its gate is
#    red (mc_rebase rc 2). The park says rebase-gate-red, not "both conflict".
# ============================================================================
fixture revert; ACTIONS=1
eval "_h_real_$(declare -f mc_rebase)"
mc_rebase() { return 2; }
settle
eval "$(declare -f _h_real_mc_rebase | sed '1s/^_h_real_mc_rebase /mc_rebase /')"
R=$(reason_of "$SLUG#2")
case "$R" in rebase-gate-red:*parent=#1*"the merge of main was clean but its typecheck/unit gate is red"*) ok ;;
  *) bad "H: a red gate parks rebase-gate-red and says the merge was clean (got: $R)" ;; esac
case "$R" in *"both conflict"*) bad "H: the reason must not say both conflict: $R" ;; *) ok ;; esac

# ============================================================================
# C. The children list is unreadable or a full page: nothing is followed, the
#    settle still lands, the log says why.
# ============================================================================
for m in 500 full; do
  fixture; echo "$m" > "$T/mode-children"; ACTIONS=1; settle
  grep -q '^PATCH\|^PUSH' "$T/events.txt" && bad "C($m): no PATCH and no push on an unproven list" || ok
  [ "$(state_of "$SLUG#1")" = MERGED ] && ok || bad "C($m): the settle must still write MERGED"
  grep -q 'children of ticket/bh-1 unreadable' "$LOG" && ok || bad "C($m): the log must say the children were unreadable"
  [ -e "$PEND" ] && bad "C($m): nothing may be recorded from an unproven list" || ok
done

# ============================================================================
# D. The child's own worker holds its lock at settle time: the follow is left
#    to that worker (no wait), and a whole tick then consumes it.
# ============================================================================
fixture; ACTIONS=1
exec 7>"$(mc_pr_lock demo-os 2)"; flock -n 7 || bad "D: the test could not take the child's lock"
settle
exec 7>&-
[ -s "$PEND" ] && ok || bad "D: a held child lock must leave the pending follow for its worker"
grep -q "$PHEAD" "$PEND" 2>/dev/null && ok || bad "D: the pending follow must carry the parent's pre-merge sha"
grep -q '^PUSH\|^PATCH' "$T/events.txt" && bad "D: a held child must not be touched by the settle" || ok
grep -q 'demo-os#2: its own conductor worker holds the PR lock' "$LOG" && ok || bad "D: the log must say the child's lock was held"

# ============================================================================
# E. Observe mode: the owed follow is recorded, nothing is written to GitHub.
# ============================================================================
fixture; ACTIONS=0; settle
[ -s "$PEND" ] && ok || bad "E: observe mode must still record the owed follow"
grep -q '^PATCH\|^PUSH' "$T/events.txt" && bad "E: observe mode must not PATCH or push" || ok
grep -q "would restack $SLUG#2 onto main (parent=#1, upstream ${PHEAD:0:8})" "$LOG" \
  && ok || bad "E: observe mode must log what it would do (got: $(grep 'demo-os#2' "$LOG" | tail -1))"

# ============================================================================
# F. Negatives that must never push.
# ============================================================================
# F1: the parent was force-pushed after the child was cut — not an ancestor.
fixture forced; ACTIONS=1
mc_restack "$SLUG" demo-os ticket/bh-2 "$CHEAD" "$PHEAD" main "https://github.com/$SLUG/pull/2" >/dev/null 2>&1; RC=$?
[ "$RC" = 6 ] && ok || bad "F1: a non-ancestor upstream sha must answer rc 6 (got $RC)"
[ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "F1: origin must be unchanged"
: > "$T/events.txt"; settle
grep -q '^PUSH' "$T/events.txt" && bad "F1: a non-ancestor parent sha must not push" || ok
[ -e "$PEND" ] && bad "F1: the pending follow must be cleared on the fallback" || ok
grep -q 'demo-os#2 .*not an ancestor.*retarget' "$LOG" && ok || bad "F1: the log must name the fallback (got: $(grep 'demo-os#2' "$LOG" | tail -1))"
# F2: the child is from a fork.
fixture; echo someone/demo-os > "$T/child-repo"; ACTIONS=1; settle
grep -q '^PUSH\|^PATCH' "$T/events.txt" && bad "F2: a fork child must not be pushed or retargeted here" || ok
[ -e "$PEND" ] && bad "F2: a fork child's pending follow must be cleared" || ok
# F3: the child is CLOSED.
fixture; echo CLOSED > "$T/child-state"; ACTIONS=1; settle
grep -q '^PUSH\|^PATCH' "$T/events.txt" && bad "F3: a closed child must not be touched" || ok
[ -e "$PEND" ] && bad "F3: a closed child's pending follow must be cleared" || ok
# F4: the child's ticket is on HOLD — skipped, still owed.
fixture; ACTIONS=1
eval "_orig_hold() $(declare -f mc_hold_keeps_pr | tail -n +2)"
mc_hold_keeps_pr() { return 0; }
settle
eval "mc_hold_keeps_pr() $(declare -f _orig_hold | tail -n +2)"
grep -q '^PUSH' "$T/events.txt" && bad "F4: a held child must not be pushed" || ok
[ -s "$PEND" ] && ok || bad "F4: a held child's follow stays owed"
# F5: the retarget is refused — no push while the PR still points at the parent.
fixture; touch "$T/patch-fails"; ACTIONS=1; settle
grep -q '^PATCH' "$T/events.txt" && ok || bad "F5: the retarget must have been tried"
grep -q '^PUSH' "$T/events.txt" && bad "F5: a refused retarget must never be followed by a push" || ok
[ -s "$PEND" ] && ok || bad "F5: a refused retarget keeps the follow owed"
# F6: three unreadable child reads — cleared, and ONE alert says what to do.
fixture; touch "$T/child-read-fails"; ACTIONS=1
mc_stack_pending_put "$SLUG" 2 1 "https://github.com/$SLUG/pull/1" ticket/bh-1 "$PHEAD" main
: > "$T/h/logs/ALERTS.log"
for _ in 1 2 3; do mc_stack_follow demo-os "$SLUG" 2 1 "https://github.com/$SLUG/pull/1" ticket/bh-1 "$PHEAD" main >/dev/null 2>&1; done
[ -e "$PEND" ] && bad "F6: the follow must be given up after three failed tries" || ok
[ "$(grep -c "demo-os#2.*could not be restacked" "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "F6: the give-up must write exactly one alert (got: $(cat "$T/h/logs/ALERTS.log"))"

# ============================================================================
# D (part 2). A whole bin/merge-conductor.sh tick consumes the pending follow
#    through pr_worker. Argv-recording git (the mc-stranded-child fixture).
# ============================================================================
TD="$T/d"; mkdir -p "$TD"
export HARNESS="$TD/h"
mkdir -p "$TD/h/bin/lib/mc" "$TD/h/bin/lib/jobs" "$TD/h/logs" "$TD/h/state" "$TD/h/flags" "$TD/h/locks" \
         "$TD/h/builds" "$TD/h/env" "$TD/fakebin" "$TD/repos" "$TD/heads"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-pr-merge.sh" \
   "$DIR/bin/lib/gh-pr-create.sh" "$TD/h/bin/lib/"
# BH-2504: the restack pushes only through bin/lib/hold-push.sh (+ hold.sh).
hold_fixture_libs "$DIR" "$TD/h" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$TD/h/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$TD/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$TD/h/bin/"
cp "$DIR/tests/lib/rest-emit.sh" "$TD/fakebin/restpr"; chmod +x "$TD/fakebin/restpr"
H72=bbbb0072bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; NEW72=eeee0072eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
PSHA=ffff0071ffffffffffffffffffffffffffffffff
printf '%s' "$H72" > "$TD/heads/ticket_pb-72"; printf '%s' "$NEW72" > "$TD/heads/new-ticket_pb-72"
cat > "$TD/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TD/git-argv.txt"
WT=""; SUB=""
while [ \$# -gt 0 ]; do
  case "\$1" in -C) WT="\$2"; shift 2 ;; -c) shift 2 ;; *) SUB="\$1"; shift; break ;; esac
done
KEY=\$(printf '%s' "\$WT" | tr '/' '_')
case "\$SUB" in
  ls-remote|remote|fetch) exit 0 ;;
  worktree) exit 0 ;;
  clone) for a in "\$@"; do case "\$a" in /*) mkdir -p "\$a/.git" ;; esac; done; exit 0 ;;
  checkout) for a in "\$@"; do case "\$a" in origin/*) printf '%s' "\${a#origin/}" > "$TD/wt-\$KEY" ;; esac; done; exit 0 ;;
  rev-parse)
    BR=\$(cat "$TD/wt-\$KEY" 2>/dev/null)
    if [ -f "$TD/done-\$KEY" ]; then cat "$TD/heads/new-\$(printf '%s' "\$BR" | tr '/' '_')" 2>/dev/null
    else cat "$TD/heads/\$(printf '%s' "\$BR" | tr '/' '_')" 2>/dev/null; fi
    exit 0 ;;
  rebase)
    case " \$* " in *" --abort "*) exit 0 ;; esac
    printf '%s rebase %s\n' "\$(cat "$TD/wt-\$KEY" 2>/dev/null)" "\$*" >> "$TD/rebases.txt"
    touch "$TD/done-\$KEY"; exit 0 ;;
  push) printf '%s\n' "\$*" >> "$TD/pushes.txt"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TD/fakebin/git"
cat > "$TD/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TD/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/$SLUG/pulls/"*) printf '%s\n' "\$*" >> "$TD/patches.txt"; exit 0 ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*) printf '%s\n' "\$*" >> "$TD/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/$SLUG/pulls/72/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/72"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$SLUG/pulls/72"*)
    restpr --raw 200 '{"number":72,"state":"open","merged_at":null,"head":{"sha":"$H72","ref":"ticket/TK-72","repo":{"full_name":"$SLUG"}},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"app/cromford","type":"Bot"},"body":"harness PR body","draft":false}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  *"pr list -R $SLUG --state open"*)
    echo '[{"number":72,"url":"https://github.com/$SLUG/pull/72","headRefOid":"$H72","headRefName":"ticket/TK-72","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]' ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$TD/fakebin/gh"
cat > "$TD/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$TD/fakebin/curl"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$TD/h/fleet.conf"
: > "$TD/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$TD/h/bin/agent-call.sh"; chmod +x "$TD/h/bin/agent-call.sh"
D72="$TD/h/builds/demo-os-TK-72-202609230001"; mkdir -p "$D72"
echo "PR_CREATED https://github.com/$SLUG/pull/72" > "$D72/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D72/review.md"; echo "$H72" > "$D72/reviewed-sha"
touch "$TD/h/flags/merge-conductor-actions"
: > "$TD/rebases.txt"; : > "$TD/pushes.txt"; : > "$TD/patches.txt"
# The owed follow, written by the lib's own writer (as a held-lock settle does).
( PATH="$TD/fakebin:$PATH" HARNESS="$TD/h"; . "$TD/h/bin/lib/merge-conductor-lib.sh"; mc_init
  mc_stack_pending_put "$SLUG" 72 71 "https://github.com/$SLUG/pull/71" ticket/TK-71 "$PSHA" main ) \
  || bad "D2: mc_stack_pending_put failed"
PEND72="$TD/h/state/stack-follow/example-org_demo-os#72"
[ -s "$PEND72" ] && ok || bad "D2: the pending follow for #72 must exist before the tick"
( cd "$TD" && PATH="$TD/fakebin:$PATH" HARNESS="$TD/h" HARNESS_SECRET=x GH_LIST_BRIDGE_ROOT="$TD" \
  MC_REPOS="$TD/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_PR_PARALLEL=1 \
  bash "$TD/h/bin/merge-conductor.sh" >/dev/null 2>"$TD/tick.err" ) || { echo "tick rc=$?"; tail -5 "$TD/tick.err"; }
grep -q "ticket/TK-72 rebase .*--onto origin/main $PSHA" "$TD/rebases.txt" \
  && ok || bad "D2: the tick must rebase #72 --onto origin/main from the parent sha (got: $(cat "$TD/rebases.txt"))"
# BH-2504: bin/lib/hold-push.sh names the destination as a full refname.
[ "$(grep -cE -- "HEAD:(refs/heads/)?ticket/TK-72( |$)" "$TD/pushes.txt")" = 1 ] \
  && ok || bad "D2: exactly one push of #72 (got: $(cat "$TD/pushes.txt"))"
grep -q -- "--force-with-lease=ticket/TK-72:$H72" "$TD/pushes.txt" && ok || bad "D2: the push must be leased on the head read"
[ -e "$PEND72" ] && bad "D2: the tick must consume the pending follow" || ok
grep -q 'pulls/72 -f state=closed' "$TD/patches.txt" && bad "D2: no close/reopen kick after the push" || ok
[ -s "$TD/gh-writes.txt" ] && bad "D2: no gh merge/edit/close verb: $(cat "$TD/gh-writes.txt")" || ok

# D3. A `.pushed` marker from an EARLIER tick never holds a row back: it is
#     dropped and the PR classifies as usual (only a same-tick marker defers).
printf 'an-earlier-tick\t%s\n' "$NEW72" > "$PEND72.pushed"
( cd "$TD" && PATH="$TD/fakebin:$PATH" HARNESS="$TD/h" HARNESS_SECRET=x GH_LIST_BRIDGE_ROOT="$TD" \
  MC_REPOS="$TD/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_PR_PARALLEL=1 \
  bash "$TD/h/bin/merge-conductor.sh" >/dev/null 2>"$TD/tick.err" ) || { echo "tick rc=$?"; tail -5 "$TD/tick.err"; }
[ -e "$PEND72.pushed" ] && bad "D3: a marker from an earlier tick must be dropped" || ok
grep -q 'demo-os#72 was restacked .* earlier this tick' "$TD/h/logs/merge-conductor.log" \
  && bad "D3: an earlier tick's marker must not defer the row" || ok
[ -n "$(awk -F'\t' -v k="$SLUG#72" '$1==k {print $2}' "$TD/h/state/merge-conductor/pr-state.tsv" 2>/dev/null)" ] \
  && ok || bad "D3: #72 must classify on this tick"

echo "mc-stack-follow.bh-1670-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]

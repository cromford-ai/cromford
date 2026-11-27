#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/hold-push-queued.bh-10201-test.sh — BH-10201: a lane never pushes to a
# branch whose open PR is in the merge queue.
#
# THE INCIDENT (#10134, 2026-11-25). A person queued the PR at 21:28Z. Build
# 50666 rebased the branch and pushed it at 23:10Z. Mergify dequeued the PR
# (the head moved) and nothing put it back for 9.5 hours.
#
# THE RULE. bin/lib/hold-push.sh hold_push_queue_guard: after the hold verdict
# and the rewrite guard, before the push, ONE read of the branch's open PR
# (`pulls?head=<owner>:<branch>&state=open`). A PR that carries Mergify's
# `queued` or `checking` label refuses the push: rc 6, one line that names the
# PR, nothing reaches the remote. A `new` lease reads nothing (the branch has
# no PR yet). HOLD_PUSH_QUEUE_GUARD=0 reads nothing and pushes. A read that
# fails does NOT refuse the push: one line says the guard did not run (the
# queue-return pass of the merge conductor is the second line of defence).
#
# MUTATIONS this suite must catch (each makes at least one case red):
#   M1 drop the guard call from hold_push             -> Q1, Q2
#   M2 match `queued` only, not `checking`            -> Q2
#   M3 match `dequeued` as a substring of the labels  -> Q3
#   M4 ignore the knob                                -> Q5
#   M5 read the PR for a `new` lease                  -> Q6
#   M6 refuse the push when the read fails            -> Q4
# Real git; only gh_rest (a shell function) is faked.
# Run from anywhere: tests/hold-push-queued.bh-10201-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email fixture@example.invalid
git config --global user.name FIXTURE
git config --global commit.gpgsign false
git config --global init.defaultBranch main

mkdir -p "$T/h/bin/lib"
scratch_install_closure bin/lib/hold-push.sh "$T/h" >/dev/null || bad "could not install bin/lib/hold-push.sh's closure"
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || bad "could not install bin/fleet-conf.sh"
scratch_install_closure bin/lib/stale-parent.sh "$T/h" >/dev/null || bad "could not install bin/lib/stale-parent.sh's closure"
# A BOARD project: no GitHub-issue hold read, so the queue read is the only read.
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
HP="$T/h/bin/lib/hold-push.sh"
grep -q '^hold_push_queue_guard()' "$DIR/bin/lib/hold-push.sh" && ok || bad "bin/lib/hold-push.sh has no hold_push_queue_guard"

# --- the fake GitHub: the open PR of the branch, answered per $T/pr-mode ---------
gh_rest() {
  printf '%s\n' "$*" >> "$T/rest-calls.txt"
  case "$*" in
    *'pulls?head=example-org:ticket%2Fbh-1&state=open'*)
      case "$(cat "$T/pr-mode" 2>/dev/null)" in
        queued)   printf '%s\n' '[{"number":134,"labels":[{"name":"hotfix"},{"name":"queued"}]}]'; return 0 ;;
        checking) printf '%s\n' '[{"number":134,"labels":[{"name":"checking"}]}]'; return 0 ;;
        dequeued) printf '%s\n' '[{"number":134,"labels":[{"name":"dequeued"},{"name":"merge-queue-later"}]}]'; return 0 ;;
        nopr)     printf '%s\n' '[]'; return 0 ;;
        500)      printf '%s\n' '{"message":"boom"}'; return 75 ;;
      esac ;;
  esac
  return 75
}
mode() { printf '%s\n' "$1" > "$T/pr-mode"; }
head_reads() { grep -c 'pulls?head=' "$T/rest-calls.txt" 2>/dev/null || true; }

O="$T/origin.git"; WT="$T/wt"; BR=ticket/bh-1
git init -q --bare "$O"
git clone -q "$O" "$WT" 2>/dev/null
echo base > "$WT/f.txt"; git -C "$WT" add f.txt; git -C "$WT" commit -qm base
git -C "$WT" push -q origin HEAD:refs/heads/main
git -C "$WT" checkout -qb "$BR"
echo pr > "$WT/pr.txt"; git -C "$WT" add pr.txt; git -C "$WT" commit -qm "BH-1: the PR"
git -C "$WT" push -q origin "HEAD:refs/heads/$BR"
B1=$(git -C "$O" rev-parse "refs/heads/$BR")
remote_tip() { git -C "$O" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
[ -n "$B1" ] && ok || bad "fixture: origin has no $BR"

# next — origin's branch back to B1, one new commit in the worktree, no calls.
next() {
  git -C "$O" update-ref "refs/heads/$BR" "$B1"
  git -C "$O" update-ref -d refs/heads/ticket/bh-77 2>/dev/null
  git -C "$WT" checkout -q -B "$BR" "$B1"
  echo "$1" >> "$WT/pr.txt"; git -C "$WT" commit -qam "BH-1: $1"; NEW=$(git -C "$WT" rev-parse HEAD)
  : > "$T/rest-calls.txt"
}
PUSH() { # PUSH <branch> <lease> [env...] -> rc; stderr in $T/push.err
  local b="$1" l="$2"; shift 2
  ( for a in "$@"; do export "${a?}"; done
    . "$HP" 2>/dev/null || exit 99
    hold_push demo-os - "$WT" "$O" HEAD "$b" "$l" ) 2>"$T/push.err"
}

# Q1 — the PR carries `queued`: rc 6, nothing pushed, one line that names the PR
next q1; mode queued
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 6 ] && ok || bad "Q1 a push to a queued PR must be refused with rc 6 (got $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$B1" ] && ok || bad "Q1 nothing may reach origin while the PR is queued"
[ "$(grep -c "NOT pushing $BR.*#134" "$T/push.err")" = 1 ] && ok \
  || bad "Q1 exactly one line 'NOT pushing $BR ... #134' on stderr: $(cat "$T/push.err")"
[ "$(head_reads)" = 1 ] && ok || bad "Q1 exactly one PR read (got $(head_reads))"

# Q2 — the PR carries `checking`: rc 6
next q2; mode checking
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 6 ] && ok || bad "Q2 a push to a PR Mergify is checking must be refused with rc 6 (got $RC)"
[ "$(remote_tip "$BR")" = "$B1" ] && ok || bad "Q2 nothing may reach origin while the PR is checking"

# Q3 — `dequeued` only, and a branch with no open PR: the push runs
next q3a; mode dequeued
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 0 ] && ok || bad "Q3 a dequeued PR is not in the queue; the push must run (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "Q3 origin must hold the new head of the dequeued PR"
next q3b; mode nopr
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 0 ] && ok || bad "Q3 a branch with no open PR must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "Q3 origin must hold the new head of the branch with no PR"

# Q4 — the read fails: the push runs, and one line says the guard did not run
next q4; mode 500
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 0 ] && ok || bad "Q4 an unread PR list must not refuse the push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "Q4 origin must hold the new head"
[ "$(grep -c 'queue guard did not run' "$T/push.err")" = 1 ] && ok \
  || bad "Q4 exactly one line 'queue guard did not run' on stderr: $(cat "$T/push.err")"

# Q5 — HOLD_PUSH_QUEUE_GUARD=0: nothing read, the push runs on a queued PR
next q5; mode queued
PUSH "$BR" "$B1" HOLD_PUSH_QUEUE_GUARD=0; RC=$?
[ "$RC" = 0 ] && ok || bad "Q5 HOLD_PUSH_QUEUE_GUARD=0 must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "Q5 origin must hold the new head"
[ "$(head_reads)" = 0 ] && ok || bad "Q5 the guard switched off must read nothing (got $(head_reads))"

# Q6 — lease `new`: a branch that does not exist yet has no PR; nothing read
next q6; mode queued
PUSH ticket/bh-77 new; RC=$?
[ "$RC" = 0 ] && ok || bad "Q6 a new branch must push (rc $RC: $(cat "$T/push.err"))"
[ "$(remote_tip ticket/bh-77)" = "$NEW" ] && ok || bad "Q6 origin must hold the new branch"
[ "$(head_reads)" = 0 ] && ok || bad "Q6 a new lease must read nothing (got $(head_reads))"

# Q7 — the knob is in the registry, default 1
K="$DIR/catalog/lanes.d/_lib.stale-parent.knobs.d/HOLD_PUSH_QUEUE_GUARD.json"
[ "$(jq -r '"\(.env) \(.default)"' "$K" 2>/dev/null)" = "HOLD_PUSH_QUEUE_GUARD 1" ] && ok \
  || bad "Q7 $K must declare HOLD_PUSH_QUEUE_GUARD with default 1"

# R1 — #10134 REPLAYED: a person queued the PR at 21:28Z; the builder's rebase
# round pushes at 23:10Z. Guard ON: rc 6, the queued head stays, ONE read and
# nothing else. tests/mc/queue-return-pass R replays the same events with the
# guard off (HOLD_PUSH_QUEUE_GUARD=0, the push below).
next r1; mode queued
PUSH "$BR" "$B1"; RC=$?
[ "$RC" = 6 ] && [ "$(remote_tip "$BR")" = "$B1" ] && ok || bad "R1 guard on: the 23:10Z push must be refused, the queued head kept (rc $RC)"
[ "$(grep -c . "$T/rest-calls.txt")" = 1 ] && ok || bad "R1 guard on: one read and nothing else ($(cat "$T/rest-calls.txt"))"
PUSH "$BR" "$B1" HOLD_PUSH_QUEUE_GUARD=0; RC=$?
[ "$RC" = 0 ] && [ "$(remote_tip "$BR")" = "$NEW" ] && ok || bad "R1 guard off: the push re-heads the queued PR, as on 2026-11-25 (rc $RC)"

echo "hold-push-queued: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# bin/lib/push-once.sh — BH-8049: a build attempt on a branch that already has a
# PR pushes ONCE, at the end of the attempt. Sourced by bin/lib/rb/gates.sh.
# Functions only: no side effect at source time.
#
# WHY. Every push to a PR branch starts the repo's PR CI (project-6: ci + e2e,
# about 130 runner-minutes) and cancels the run before it, after that run
# already spent minutes. PUSH_BRANCH pushed after execute and after each fix
# round, so one attempt on an existing PR made up to 18 runs in a day. Now the
# backup pushes of such an attempt are deferred: the commits collect in the
# worktree, and the pre-PR push (pr-push) sends them in one push. An attempt
# that ends before pr-push (a REVIEW_BLOCKED, a gate exit, a yield, a signal)
# sends them from run-build.sh's EXIT trap (PO_FLUSH_ON_EXIT), so
# bin/blocked-resolver.sh still finds the work on origin. A retry attempt
# pushes once more. HARNESS_EXIT and the PR body do not change.
#
# BUILD_PUSH_ONCE (settings row lane.fly-pool.build_push_once, else the env):
#   pr      (default) defer when the branch already has a PR: SQUASH_OK=0 (a
#           dispatcher-supplied TARGET_BRANCH is an existing PR's head) or
#           RB_PR_OPEN is set. A first build with no PR keeps its backup
#           pushes: no PR CI runs on them, and they keep the TK-269 "the tree
#           survives the machine" guarantee.
#   always  defer every backup push.
#   off     the old behavior: push after every commit-producing stage.
#   Any other value reads as pr.
# While push-once is active CKPT_START (bin/lib/rb/plan.sh) starts no
# checkpoint watcher, because each of its wip checkpoints is a push too.
#
# Functional pushes are not deferred: the E2E preview push and the preview-QA
# fix push need the pushed tree to build a preview. Each push goes through
# hold_push (bin/lib/hold-push.sh), so a held ticket is never pushed.

# po_mode — pr | always | off.
po_mode() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fly-pool BUILD_PUSH_ONCE "${PROJECT:-}" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || v="${BUILD_PUSH_ONCE:-}"
  case "$v" in pr|always|off) ;; *) v=pr ;; esac
  printf '%s\n' "$v"
}

# po_active — rc 0 when this attempt defers its backup pushes.
po_active() {
  case "$(po_mode)" in
    always) return 0 ;;
    off)    return 1 ;;
  esac
  [ "${SQUASH_OK:-1}" = 0 ] || [ -n "${RB_PR_OPEN:-}" ]
}

# po_defer <stage> — rc 0: the push after <stage> is deferred (one log line,
# PO_DEFERRED=1). rc 1: push-once is not active, push as before.
po_defer() {
  po_active || return 1
  PO_DEFERRED=1
  local n
  n=$(git rev-list --count "refs/remotes/origin/$BRANCH..HEAD" 2>/dev/null) || n="?"
  echo "$(STAMP) [$PROJECT/$KEY] push-once: deferred push after $1 — $n commit(s) wait for the end-of-attempt push (BH-8049)" >> "$BUILD/pipeline.log"
  return 0
}

# po_flush <why> — the end-of-attempt push for an attempt that deferred one and
# ended before pr-push. Only when HEAD differs from refs/remotes/origin/$BRANCH
# (track_pushed keeps that equal to the last push). One hold_push, the call
# RB_PUSH makes, without the yield: a held ticket is "not pushed", never an
# exit. Always rc 0; never writes RESULT.
po_flush() {
  local why="${1:-end}" h l rc=0
  [ "${PO_DEFERRED:-0}" = 1 ] || return 0
  h=$(git rev-parse -q --verify HEAD 2>/dev/null) || return 0
  l=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null) || l=""
  [ "$h" != "$l" ] || return 0
  if declare -F RB_TICKET_LOCK_GATE >/dev/null; then
    # RB_PR_OPEN=1 here so a lost lock returns 3 instead of exiting the trap.
    RB_PR_OPEN=1 RB_TICKET_LOCK_GATE "push-once-$why" || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    if command -v hold_push >/dev/null 2>&1; then
      HOLD_PUSH_LOG="$BUILD/pipeline.log" hold_push -u "$PROJECT" - "$PWD" origin "$BRANCH" "$BRANCH" "${l:-new}" 2>>"$BUILD/pipeline.log" || rc=$?
    else
      rc=1
    fi
  fi
  if [ "$rc" = 0 ]; then
    declare -F track_pushed >/dev/null && track_pushed
    PO_DEFERRED=0
    echo "$(STAMP) [$PROJECT/$KEY] push-once: end-of-attempt push ${h:0:12} ($why)" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] push-once: end-of-attempt push not pushed ($rc) — ${h:0:12} stays in $PWD" >> "$BUILD/pipeline.log"
  fi
  return 0
}

PO_FLUSH_ON_EXIT() { po_flush exit; }

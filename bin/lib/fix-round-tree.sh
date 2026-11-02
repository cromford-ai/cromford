#!/bin/bash
# bin/lib/fix-round-tree.sh — is the fix round's worktree the PR's? (BH-8896)
#
# bin/blocked-resolver.sh br_fix_round calls frt_check after the worktree add
# and before the merge, the brief and the agent call. project-6-os FXR-1465
# (2026-11-01) was a fix round for PR #3511 on a pool machine reused from
# TK-3496 (PR #3512), and its record carried #3512's build. A round that is
# not on its own PR's tree must stop before it spends an agent call.
#
# frt_check <wt> <want-branch> <lease> <reuse 0|1>
#   rc 0  the tree is the PR's: HEAD is on <want-branch>, and HEAD == <lease>
#         (reuse 0) or HEAD descends <lease> (reuse 1, a checkpoint).
#   rc 1  a wrong tree. stdout: one line `FIX_ROUND_WRONG_TREE: <why>`.
#   rc 0  HEAD or its branch cannot be read: one stderr line, not checked.
#         A read failure is not proof of a wrong tree (fail-open).
# Full 40-hex compare: a sha that shares the first 8 hex is another sha.
# Tests: tests/fix-round-wrong-tree.bh-8896-test.sh.

frt_check() {
  local wt="${1:-}" want="${2:-}" lease="${3:-}" reuse="${4:-0}" head br
  head=$(git -C "$wt" rev-parse --verify -q HEAD 2>/dev/null)
  if [ -z "$head" ] || [ -z "$lease" ]; then
    echo "frt: HEAD unreadable in $wt, not checked" >&2
    return 0
  fi
  br=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
  if [ -z "$br" ]; then
    # A readable HEAD with no branch is a detached HEAD: never the round's tree.
    if git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "FIX_ROUND_WRONG_TREE: $wt has a detached HEAD ${head:0:8}, not $want"
      return 1
    fi
    echo "frt: the branch in $wt is unreadable, not checked" >&2
    return 0
  fi
  if [ "$br" != "$want" ]; then
    echo "FIX_ROUND_WRONG_TREE: $wt is on $br, not $want"
    return 1
  fi
  if [ "$reuse" = 1 ]; then
    git -C "$wt" merge-base --is-ancestor "$lease" "$head" >/dev/null 2>&1 && return 0
    echo "FIX_ROUND_WRONG_TREE: $wt HEAD ${head:0:8} on $want does not descend PR head ${lease:0:8}"
    return 1
  fi
  [ "$head" = "$lease" ] && return 0
  echo "FIX_ROUND_WRONG_TREE: $wt HEAD ${head:0:8} is not PR head ${lease:0:8}"
  return 1
}

#!/bin/bash
# tests/lib/git-history-full.bh-9733.sh — is a checkout's git history full?
# Sourced, never executed (BH-9733).
#
# ghf_full <dir> — rc 0 only when <dir> is a git repo, it is not shallow, and
# HEAD has more than 2 commits. rc 1 otherwise. No output.
#
# A suite that looks for an old commit in the real history (for example the
# commit that deleted a file) can only demand to find it on full history. Two
# shapes can never hold such a commit, and this rejects both:
#   - the gate's snapshot tree: snapshot_tree in bin/test-impact-gate.sh makes
#     a fresh `git init` from `git archive`, with 1 commit (`snapshot`) or
#     2 commits (`base`, `head`);
#   - a shallow clone (every box worktree, a CI checkout without fetch-depth 0).
# The 2 is the snapshot shape, a test-structure constant, not a product knob.
ghf_full() {
  local d="$1" n
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || return 1
  [ "$(git -C "$d" rev-parse --is-shallow-repository 2>/dev/null)" = false ] || return 1
  n=$(git -C "$d" rev-list --count HEAD 2>/dev/null) || return 1
  [ "${n:-0}" -gt 2 ]
}

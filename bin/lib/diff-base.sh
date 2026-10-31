# bin/lib/diff-base.sh — this build's own diff, from the merge base with origin/<base> (BH-7114).
# Sourced, never executed. No output at source time. Safe under `set -uo pipefail`.
#
# Every worktree of a hub checkout shares the LOCAL <base> ref, and it moves
# once at build start. The pre-PR block rebases onto origin/<base>, so after a
# sibling PR merges, `<base>...HEAD` takes the merge base with the old local
# ref and lists the sibling's files as this build's (project-6 #908: 28 listed,
# 17 real). The ref rule is the one SCOPE_BASE (rb/execute.sh) and WHAT_BASE
# (rb/pr.sh) already use.
# shellcheck shell=bash

diff_base_ref() { # diff_base_ref <base> — origin/<base> when it resolves, else <base>
  local base="${1:-}"
  if [ -n "$base" ] && git rev-parse -q --verify "origin/$base" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$base"
  else
    printf '%s\n' "$base"
  fi
}

diff_changed_files() { # diff_changed_files <base> — one path per line; git's rc
  local ref mb
  ref=$(diff_base_ref "${1:-}")
  mb=$(git merge-base "$ref" HEAD 2>/dev/null)
  if [ -n "$mb" ]; then
    git diff --name-only "$mb" HEAD
  else
    # No merge base (unknown ref, shallow clone, unrelated history): today's
    # three-dot line, so git answers with its own rc and output.
    git diff --name-only "$ref"...HEAD
  fi
}

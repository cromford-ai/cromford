# shellcheck shell=bash
# bin/lib/automerge-paths.sh — BH-9426: the paths a merge resolves by itself,
# so a build overlap on them is no reason to defer. Sourced, never run;
# sourcing defines functions only.
#
# A path is AUTO-MERGE in a target repo when
#   (a) the repo's `## Generated files` table declares it (gen_table_paths at
#       HEAD, bin/lib/generated-table.sh; gen_path_matches: the whole path or a
#       whole-path glob, never a prefix) — the conductor regenerates it; or
#   (b) `git check-attr merge` answers `union` for it — git merges it without
#       a conflict.
# Everything else is not: a fragment file edited on both sides, a prefix of a
# generated path, a `merge=binary` path, `.gitattributes` itself.
#
# FAIL-OPEN = THE OLD RULE. No repo dir, no git, no generated-table lib: the set
# is empty, so every checker judges every path as it did before this file.
#
# Readers: bin/conflict-check.sh, bin/overlap-guard.sh (amp_filter),
# bin/plan-overlap.sh and bin/plan-sibling.sh (amp_is_automerge in
# fragment_safe).

_AMP_DIR=""
_AMP_GEN=""

# amp_init <repo-dir> — read the Generated-files table once per repo per process.
amp_init() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ "$dir" = "$_AMP_DIR" ] && return 0
  _AMP_DIR="$dir"; _AMP_GEN=""
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  if ! command -v gen_table_paths >/dev/null 2>&1; then
    # shellcheck source=bin/lib/generated-table.sh
    . "$(dirname "${BASH_SOURCE[0]}")/generated-table.sh" 2>/dev/null || return 0
  fi
  _AMP_GEN=$(gen_table_paths "$dir" HEAD 2>/dev/null) || _AMP_GEN=""
  return 0
}

# _amp_gen_hit <path> — rc 0 when a declared row of the current repo covers it.
_amp_gen_hit() {
  local g
  [ -n "$_AMP_GEN" ] || return 1
  while IFS= read -r g; do
    [ -n "$g" ] && gen_path_matches "$1" "$g" && return 0
  done <<< "$_AMP_GEN"
  return 1
}

# amp_is_automerge <repo-dir> <path> — rc 0 when <path> is auto-merge in <repo-dir>.
amp_is_automerge() {
  local dir="${1:-}" p="${2:-}" a
  [ -n "$dir" ] && [ -n "$p" ] && [ -d "$dir" ] || return 1
  amp_init "$dir"
  _amp_gen_hit "$p" && return 0
  a=$(git -C "$dir" check-attr merge -- "$p" 2>/dev/null) || return 1
  [ "${a##*: }" = union ]
}

# amp_filter <repo-dir> — stdin paths -> stdout the paths that are NOT
#   auto-merge, in order. One `git check-attr --stdin` for the whole list.
#   No repo dir: every path passes through.
amp_filter() {
  local dir="${1:-}" p a
  local -A uni=()
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then cat; return 0; fi
  amp_init "$dir"
  local list; list=$(cat)
  [ -n "$list" ] || return 0
  while IFS= read -r a; do
    case "$a" in *": merge: union") uni["${a%: merge: union}"]=1 ;; esac
  done < <(printf '%s\n' "$list" | git -C "$dir" check-attr --stdin merge 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -n "${uni[$p]:-}" ] && continue
    _amp_gen_hit "$p" && continue
    printf '%s\n' "$p"
  done <<< "$list"
  return 0
}

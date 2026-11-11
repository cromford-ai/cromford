#!/bin/bash
# bin/lib/changelog-fragment.sh — a build never edits the shared changelog in
# its PR (BH-9096). Sourced, never executed; defines functions only.
#
# WHY. Every build that adds an entry at the top of docs/RECENT-CHANGES.md
# edits the same hunk, so the second of two merges conflicts on a file no
# ticket is about. This moves the entry the build ADDED to its own fragment
# file, docs/recent-changes.d/<key>.md, so two builds never share a hunk and no
# merge driver is needed (GitHub does not run .gitattributes drivers).
#
# clf_strip <base-ref> <key> [build-dir] — run in the build's worktree, after
# the last execute-stage commit and before the gates, review and first push
# (bin/lib/rb/execute.sh, `# >>> changelog fragment`), so the head-bound
# approval sees the moved head. For each changelog path:
#   1. no merge-base with <base-ref> -> one line, nothing done
#   2. the path is not in the diff -> nothing
#   3. the build created the path -> left (its own new file)
#   4. the diff touches only changelog paths -> left (the ticket is about it)
#   5. the diff deletes or edits a line of it -> left (`not a pure addition`):
#      a rewrite keeps its edit, nothing is truncated
#   6. a pure addition -> the added lines (hunks joined by one blank line) go
#      to <dir>/<base lowercased>.d/<key lowercased>.md, written to a temp file
#      and moved; ONLY then is the path reset to the merge-base, and both land
#      in one commit
#   7. `moved ...` is printed only when HEAD's changelog equals the merge-base
#      AND the fragment is in HEAD; anything else says `not claimed`
# Prints one line per path it acted on (or nothing), always returns 0.
#
# KNOBS. The path list: env CHANGELOG_FRAGMENT_PATHS (tests), else the settings
# row conf.changelog-fragment.paths (space separated), else the fallback
# docs/RECENT-CHANGES.md below. Switch: lane_switch changelog-fragment-off
# (settings row switch.changelog-fragment-off[.<box>], else the flag file).

# The fallback when conf.changelog-fragment.paths has no row.
CLF_DEFAULT_PATHS="docs/RECENT-CHANGES.md"

_clf_paths() {
  local v="${CHANGELOG_FRAGMENT_PATHS:-}"
  if [ -z "$v" ]; then
    if ! command -v conf_row >/dev/null 2>&1; then
      # shellcheck source=bin/lib/conf-row.sh
      . "$(dirname "${BASH_SOURCE[0]}")/conf-row.sh" 2>/dev/null || :
    fi
    command -v conf_row >/dev/null 2>&1 && v=$(conf_row changelog-fragment paths 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || v="$CLF_DEFAULT_PATHS"
  printf '%s\n' "$v" | tr ' \t' '\n\n' | awk 'NF && !s[$0]++'
}

_clf_off() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
      || lane_switch() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] && [ -f "$r/flags/$1" ]; }
  fi
  lane_switch changelog-fragment-off file
}

# _clf_frag <path> <key> -> docs/RECENT-CHANGES.md + TK-639 -> docs/recent-changes.d/TK-639.md
_clf_frag() {
  local d b
  d=$(dirname "$1"); b=$(basename "$1" .md)
  b=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
  printf '%s%s.d/%s.md\n' "$([ "$d" = . ] || printf '%s/' "$d")" "$b" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
}

clf_strip() {
  local base="${1:-}" key="${2:-}" mb changed paths p frag del rest tmp
  [ -n "$base" ] || return 0
  [[ "$key" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ "$key" != . ] && [ "$key" != .. ] || { echo "key '$key' is not a safe file name — left"; return 0; }
  _clf_off && return 0
  if ! mb=$(git merge-base "$base" HEAD 2>/dev/null) || [ -z "$mb" ]; then
    echo "no merge-base with $base — left"
    return 0
  fi
  paths=$(_clf_paths)
  changed=$(git diff --name-only --no-renames "$mb" HEAD 2>/dev/null)
  rest=$(printf '%s\n' "$changed" | grep -vxF -f <(printf '%s\n' "$paths") | grep -v '^\.harness/specs/' | awk 'NF' | wc -l | tr -d ' ')
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF -- "$p" <<<"$changed" || continue
    if ! git cat-file -e "$mb:$p" 2>/dev/null; then
      echo "$p was created by this build — left"; continue
    fi
    if [ "$rest" = 0 ]; then
      echo "the diff touches only the changelog ($p) — the ticket is about it, left"; continue
    fi
    del=$(git diff --numstat --no-renames "$mb" HEAD -- "$p" 2>/dev/null | awk '{print $2; exit}')
    if [ "$del" != 0 ]; then
      echo "$p: not a pure addition — left"; continue
    fi
    frag=$(_clf_frag "$p" "$key")
    mkdir -p "$(dirname "$frag")" 2>/dev/null || { echo "$p: cannot create $(dirname "$frag") — not claimed"; continue; }
    tmp="$frag.tmp.$$"
    git diff -U0 --no-renames "$mb" HEAD -- "$p" 2>/dev/null | awk '
      /^@@/ { if (n) blank = 1; next }
      /^\+\+\+ / { next }
      /^\+/ { if (blank) { print ""; blank = 0 } print substr($0, 2); n++ }' > "$tmp"
    if [ ! -s "$tmp" ]; then
      rm -f "$tmp"; echo "$p: no added line found — left"; continue
    fi
    mv -f "$tmp" "$frag"
    if git checkout -q "$mb" -- "$p" 2>/dev/null && git add -- "$frag" 2>/dev/null \
       && git -c commit.gpgsign=false commit -q --no-verify \
            -m "chore($key): move the ${p##*/} entry to $frag (BH-9096)" -- "$p" "$frag" >/dev/null 2>&1; then
      if git diff --quiet "$mb" HEAD -- "$p" 2>/dev/null && git cat-file -e "HEAD:$frag" 2>/dev/null; then
        echo "moved $p entry to $frag"
      else
        echo "strip commit landed but $p still differs from ${mb:0:8} — not claimed"
      fi
      continue
    fi
    # The reset or the commit failed: put the changelog back as HEAD has it,
    # index and tree, and drop the fragment HEAD does not hold.
    git reset -q HEAD -- "$p" "$frag" >/dev/null 2>&1
    git checkout -q HEAD -- "$p" >/dev/null 2>&1
    git cat-file -e "HEAD:$frag" 2>/dev/null || rm -f "$frag"
    rmdir "$(dirname "$frag")" 2>/dev/null
    echo "move FAILED for $p — restored to HEAD, the entry stays; not claimed"
  done <<<"$paths"
  return 0
}

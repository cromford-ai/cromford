#!/bin/bash
# bin/list-file-lint.sh — refuse a PR that appends to a list file without adding
# its entry as a fragment file (BH-6738).
#
# Usage: bin/list-file-lint.sh [--base <ref>] [--catalog <file>]
#   --base     the ref the PR diffs against (default origin/main). The diff is
#              <base>...HEAD, so only this PR's own commits count.
#   --catalog  read only <file> (a test override). Without it the lint reads
#              catalog/list-files.tsv at HEAD AND at <base> and applies the
#              union, so a PR that deletes a row is still checked against it.
#
# The catalog has three tab-separated columns: <path glob> <input> <note>.
# <input> is `<dir>/` (the PR must ADD a file under it), `rendered <dir>/` (the
# PR must add or edit a file under it) or `ignored <dir>/` (a git-ignored render:
# any added line is red). A `*` in a glob never crosses a `/`.
#
# An append is net growth of the file in the diff (numstat added > deleted); a
# binary change counts as one. A value edit or a shrink is not an append.
#
# rc 0  no list file grew, or every one grew through its input dir
# rc 1  a list file grew without its fragment
# rc 2  a malformed catalog row, an unknown flag, or a diff that cannot be read
set -uo pipefail
set -f

usage() { echo "usage: bin/list-file-lint.sh [--base <ref>] [--catalog <file>]" >&2; }

BASE=origin/main
CATALOG=
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || { usage; exit 2; }; BASE=$2; shift 2 ;;
    --catalog) [ $# -ge 2 ] || { usage; exit 2; }; CATALOG=$2; shift 2 ;;
    *) echo "list-file-lint: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$CATALOG" ] && [ ! -r "$CATALOG" ]; then
  echo "list-file-lint: cannot read catalog $CATALOG" >&2; exit 2
fi
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "list-file-lint: not inside a git work tree" >&2; exit 2; }
cd "$TOP" || exit 2
REL=catalog/list-files.tsv

ROW_GLOB=(); ROW_IN=(); ROW_NOTE=(); ROW_SRC=()
BADROWS=()

# row_error <glob> <input> — print why a row is malformed, or nothing.
row_error() {
  local glob=$1 input=$2 dir
  [ -n "$glob" ] || { echo "empty path glob"; return; }
  case "$input" in
    "rendered "*) dir=${input#rendered } ;;
    "ignored "*)  dir=${input#ignored } ;;
    *" "*|"")     echo "column 2 must be <dir>/, rendered <dir>/ or ignored <dir>/"; return ;;
    *)            dir=$input ;;
  esac
  case "$dir" in
    */) ;;
    *) echo "column 2 must be <dir>/, rendered <dir>/ or ignored <dir>/"; return ;;
  esac
  case "$dir" in *" "*|/) echo "column 2 must be <dir>/, rendered <dir>/ or ignored <dir>/"; return ;; esac
  local p
  for p in "$glob" "$dir"; do
    case "$p" in /*) echo "path $p must be relative to the repo root"; return ;; esac
    case "/$p/" in */../*) echo "path $p must not hold a .. segment"; return ;; esac
  done
}

# load <label> <strict> < catalog — append its rows; malformed rows go to
# BADROWS when strict=1 and are skipped with one note when strict=0.
load() {
  local label=$1 strict=$2 n=0 line rest glob input note err skipped=0 i dup
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '#'*|'') continue ;; esac
    [ -z "${line//[[:space:]]/}" ] && continue
    rest=${line//[^$'\t']/}
    if [ "${#rest}" -ne 2 ]; then
      err="want 3 tab-separated fields, got $(( ${#rest} + 1 ))"
    else
      IFS=$'\t' read -r glob input note <<< "$line"
      err=$(row_error "$glob" "$input")
    fi
    if [ -n "$err" ]; then
      if [ "$strict" = 1 ]; then BADROWS+=("$label:$n: $err")
      else skipped=$((skipped + 1)); fi
      continue
    fi
    dup=0
    for i in "${!ROW_GLOB[@]}"; do
      [ "${ROW_GLOB[$i]}" = "$glob" ] && [ "${ROW_IN[$i]}" = "$input" ] && { dup=1; break; }
    done
    [ "$dup" = 1 ] && continue
    ROW_GLOB+=("$glob"); ROW_IN+=("$input"); ROW_NOTE+=("$note"); ROW_SRC+=("$label:$n")
  done
  [ "$skipped" -gt 0 ] && echo "list-file-lint: note: skipped $skipped malformed row(s) in $label"
  return 0
}

if ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  echo "list-file-lint: cannot diff against $BASE (no such commit)"; exit 2
fi

if [ -n "$CATALOG" ]; then
  load "$CATALOG" 1 < "$CATALOG"
else
  [ -f "$REL" ] && load "$REL" 1 < "$REL"
  if [ "${#BADROWS[@]}" -eq 0 ] && git cat-file -e "$BASE:$REL" 2>/dev/null; then
    load "$BASE:$REL" 0 < <(git show "$BASE:$REL")
  fi
fi
if [ "${#BADROWS[@]}" -gt 0 ]; then
  for b in "${BADROWS[@]}"; do echo "list-file-lint: malformed row $b"; done
  exit 2
fi
[ "${#ROW_GLOB[@]}" -eq 0 ] && exit 0

# The PR's changed paths, NUL-separated so no path is quoted or split.
ST=(); FILES=()
NS=$(mktemp) || exit 2
trap 'rm -f "$NS"' EXIT
if ! git diff --name-status --no-renames -z "$BASE"...HEAD > "$NS" 2>/dev/null; then
  echo "list-file-lint: cannot diff against $BASE"; exit 2
fi
while IFS= read -r -d '' s && IFS= read -r -d '' f; do
  ST+=("$s"); FILES+=("$f")
done < "$NS"

slashes() { local x=${1//[^\/]/}; echo "${#x}"; }

# has_input <dir> <statuses> — the PR has a path under <dir> with one of the
# statuses (A, or A and M).
has_input() {
  local dir=$1 want=$2 j
  for j in "${!FILES[@]}"; do
    case "${FILES[$j]}" in "$dir"*) ;; *) continue ;; esac
    case "$want" in *"${ST[$j]}"*) return 0 ;; esac
  done
  return 1
}

RED=0; OKFILES=()
for i in "${!FILES[@]}"; do
  F=${FILES[$i]}
  case "${ST[$i]}" in A|M) ;; *) continue ;; esac
  fs=$(slashes "$F")
  grown=; desc=
  for r in "${!ROW_GLOB[@]}"; do
    G=${ROW_GLOB[$r]}
    [ "$(slashes "$G")" = "$fs" ] || continue
    # shellcheck disable=SC2254 # the glob is the pattern on purpose
    case "$F" in $G) ;; *) continue ;; esac
    if [ -z "$grown" ]; then
      IFS=$'\t' read -r -d '' a d _ < <(git diff --numstat --no-renames -z "$BASE"...HEAD -- "$F")
      if [ "${a:-}" = - ]; then grown=1; desc="changed as a binary file"
      elif [ "${a:-0}" -gt "${d:-0}" ] 2>/dev/null; then grown=1; desc="grew by $((a - d)) line(s)"
      else grown=0; fi
    fi
    [ "$grown" = 1 ] || continue
    IN=${ROW_IN[$r]}
    row="${ROW_SRC[$r]}: $G -> $IN; ${ROW_NOTE[$r]}"
    case "$IN" in
      "ignored "*)
        dir=${IN#ignored }
        echo "list-file-lint: $F is a git-ignored render and this PR commits it ($desc) ($row)"
        echo "  Fix: $F is a git-ignored render; drop it from the PR (git rm --cached $F) and edit $dir."
        RED=1 ;;
      "rendered "*)
        dir=${IN#rendered }
        if has_input "$dir" AM; then OKFILES+=("$F"); else
          echo "list-file-lint: $F $desc and this PR adds or edits no file under $dir ($row)"
          echo "  Fix: edit the inputs under $dir and re-render $F."
          RED=1
        fi ;;
      *)
        dir=$IN
        if has_input "$dir" A; then OKFILES+=("$F"); else
          echo "list-file-lint: $F $desc and this PR adds no file under $dir ($row)"
          echo "  Fix: put the new entry in its own file under $dir and keep $F unchanged."
          RED=1
        fi ;;
    esac
  done
done

[ "$RED" = 1 ] && exit 1
if [ "${#OKFILES[@]}" -gt 0 ]; then
  k=$(printf '%s\n' "${OKFILES[@]}" | sort -u | wc -l)
  echo "list-file-lint: $k list file(s) changed, all through their fragments."
fi
exit 0

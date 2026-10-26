#!/bin/bash
# bin/lib/security-lens-classes.sh — the attack-class notes the security lens
# gets for one diff (BH-7911). Sourced by bin/lib/rb/review.sh; no side effects
# at source time.
#
# The table is catalog/security-classes.tsv:
#   class<TAB>path-ERE<TAB>diff-ERE<TAB>note      ("-" = no match on that axis)
# The class text is prompts/security-classes/<class>.md, vendored verbatim
# (prompts/security-classes/PROVENANCE.md). A row matches a diff when its
# path-ERE matches a changed path or a planned file, or its diff-ERE matches an
# added or removed line. Both are case-insensitive. The first two matching rows
# in file order win.
#
# Knobs (env, read at call time):
#   SLC_ROOT  repo root (default: two directories above this file)
#   SLC_TSV   the table (default $SLC_ROOT/catalog/security-classes.tsv)
#   SLC_DIR   the class files (default $SLC_ROOT/prompts/security-classes)
#   SECURITY_LENS_CLASS_MAX_BYTES  cap on the class text (default 24000; a
#             non-numeric value or 0 uses the default)
# shellcheck shell=bash

__slc_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

_slc_root() { printf '%s\n' "${SLC_ROOT:-${__slc_lib_dir:+$__slc_lib_dir/../..}}"; }
_slc_tsv()  { printf '%s\n' "${SLC_TSV:-$(_slc_root)/catalog/security-classes.tsv}"; }
_slc_dir()  { printf '%s\n' "${SLC_DIR:-$(_slc_root)/prompts/security-classes}"; }

# slc_check [<tsv>] — validate the table and its class files. rc 0, or rc 2
# with one stderr line per bad line: `security-lens-classes: <tsv>:<n>: <why>`.
slc_check() {
  local tsv="${1:-$(_slc_tsv)}" dir n=0 bad=0 line class pere dere note rest seen=" " ere rc
  dir=$(_slc_dir)
  if [ ! -f "$tsv" ] || [ ! -r "$tsv" ]; then
    echo "security-lens-classes: $tsv: missing or unreadable" >&2; return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    case "$line" in '#'*) continue ;; esac
    [ -z "${line//[[:space:]]/}" ] && continue
    rest=${line//[!$'\t']/}
    if [ "${#rest}" != 3 ]; then
      echo "security-lens-classes: $tsv:$n: expected 4 tab-separated fields, got $(( ${#rest} + 1 ))" >&2; bad=1; continue
    fi
    IFS=$'\t' read -r class pere dere note <<< "$line"
    if ! [[ $class =~ ^[a-z][a-z0-9-]*$ ]]; then
      echo "security-lens-classes: $tsv:$n: bad class name '$class'" >&2; bad=1; continue
    fi
    if [ "$pere" = - ] && [ "$dere" = - ]; then
      echo "security-lens-classes: $tsv:$n: $class: both EREs are '-', the row can never match" >&2; bad=1; continue
    fi
    for ere in "$pere" "$dere"; do
      [ "$ere" = - ] && continue
      if [ -z "$ere" ]; then
        echo "security-lens-classes: $tsv:$n: $class: empty ERE (use '-')" >&2; bad=1; continue
      fi
      grep -qiE -- "$ere" < /dev/null 2>/dev/null; rc=$?
      if [ "$rc" = 2 ]; then
        echo "security-lens-classes: $tsv:$n: $class: ERE does not compile: $ere" >&2; bad=1
      fi
    done
    if [ ! -s "$dir/$class.md" ]; then
      echo "security-lens-classes: $tsv:$n: $class: no class file $dir/$class.md" >&2; bad=1
    fi
    case "$seen" in *" $class "*)
      echo "security-lens-classes: $tsv:$n: $class: class repeated" >&2; bad=1 ;;
    esac
    seen="$seen$class "
    : "$note"
  done < "$tsv"
  [ "$bad" = 0 ] || return 2
  return 0
}

# _slc_paths <diff-file> — every path the diff names, one per line: the
# `--- a/` and `+++ b/` headers (quoted or not, /dev/null skipped), `rename
# from/to`, and `Binary files a/<p> and b/<q> differ`.
_slc_paths() {
  awk '
    function unq(p) {
      if (substr(p, 1, 1) == "\"" && substr(p, length(p), 1) == "\"") {
        p = substr(p, 2, length(p) - 2); gsub(/\\"/, "\"", p); gsub(/\\\\/, "\\", p)
      }
      return p
    }
    function emit(p) {
      p = unq(p)
      if (p == "/dev/null" || p == "") return
      sub(/^[ab]\//, "", p); print p
    }
    /^diff --git / { hdr = 1; next }
    /^@@/          { hdr = 0; next }
    NR == 1        { hdr = 1 }
    hdr && /^(\+\+\+|---) / { p = substr($0, 5); sub(/\t.*$/, "", p); emit(p); next }
    hdr && /^rename (from|to) / { p = $0; sub(/^rename (from|to) /, "", p); emit(p); next }
    hdr && /^Binary files .* differ$/ {
      p = $0; sub(/^Binary files /, "", p); sub(/ differ$/, "", p)
      i = index(p, " and ")
      if (i) { emit(substr(p, 1, i - 1)); emit(substr(p, i + 5)) }
      next
    }
  ' "$1"
}

# _slc_lines <diff-file> — every added or removed line inside a hunk.
_slc_lines() {
  awk '
    /^diff --git / { hdr = 1; next }
    /^@@/          { hdr = 0; next }
    NR == 1 && !/^diff --git / { hdr = 1 }
    !hdr && /^[-+]/ { print }
  ' "$1"
}

# slc_for_diff <diff-file> <planned-files-file> — print `SLC_CLASSES: <c1>[ <c2>]`
# and then the class text, or nothing when no row matches. rc 0, or rc 2 on a
# bad table or an unreadable diff (stderr names it).
slc_for_diff() {
  local diff="${1:-}" planned="${2:-}" tsv dir paths lines line class pere dere note picked="" k=0 cap c body n
  tsv=$(_slc_tsv); dir=$(_slc_dir)
  slc_check "$tsv" || return 2
  if [ -z "$diff" ] || [ ! -f "$diff" ] || [ ! -r "$diff" ]; then
    echo "security-lens-classes: diff file '$diff' missing or unreadable" >&2; return 2
  fi
  paths=$( { _slc_paths "$diff"; [ -n "$planned" ] && [ -r "$planned" ] && grep -v '^[[:space:]]*$' "$planned"; } | sort -u)
  lines=$(_slc_lines "$diff")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '#'*) continue ;; esac
    [ -z "${line//[[:space:]]/}" ] && continue
    IFS=$'\t' read -r class pere dere note <<< "$line"
    : "$note"
    if { [ "$pere" != - ] && [ -n "$paths" ] && grep -qiE -- "$pere" <<< "$paths"; } \
       || { [ "$dere" != - ] && [ -n "$lines" ] && grep -qiE -- "$dere" <<< "$lines"; }; then
      picked="${picked:+$picked }$class"; k=$((k+1))
      [ "$k" -ge 2 ] && break
    fi
  done < "$tsv"
  [ -n "$picked" ] || return 0
  cap=${SECURITY_LENS_CLASS_MAX_BYTES:-}
  [[ $cap =~ ^[0-9]+$ ]] && [ "$((10#$cap))" -gt 0 ] && cap=$((10#$cap)) || cap=24000
  body=$(k=0; for c in $picked; do
           [ "$k" = 1 ] && printf '\n'
           printf '=== attack class: %s (prompts/security-classes/%s.md) ===\n' "$c" "$c"
           cat "$dir/$c.md"; k=1
         done; printf x)
  body=${body%x}
  printf 'SLC_CLASSES: %s\n' "$picked"
  n=$(printf '%s' "$body" | wc -c | tr -d ' ')
  if [ "$n" -gt "$cap" ]; then
    head -c "$cap" <<< "$body"
    printf '\n[security-lens-classes: truncated at %s bytes, SECURITY_LENS_CLASS_MAX_BYTES]\n' "$cap"
  else
    printf '%s' "$body"
  fi
  return 0
}

#!/bin/bash
# bin/component-of.sh — BH-6971 (BH-6546.1): which component owns an alert.
#
#   component-of.sh <alert line|family>   print the component, or `unowned`
#   component-of.sh --batch               stdin `<id>\t<line>`, stdout `<id>\t<component>`
#   component-of.sh --check               validate the catalog, print a count
#
# The catalog is catalog/components.tsv (COMPONENTS_TSV overrides it): five
# tab-separated fields per row, `component regex lanes logs doc`. A leading
# `YYYY-MM-DD[T ]HH:MM[:SS][Z]` stamp and one space are removed from the line,
# then the rows are matched in FILE ORDER and the first match wins. No match
# is `unowned`, rc 0. A family hash is matched as text, so it is `unowned`.
#
# It labels and never acts. Every row is loaded and validated BEFORE any match:
# a bad row prints `component-of: components.tsv:<n>: <reason>: <line>` on
# stderr and exits 2 with no answer on stdout, because a partial catalog would
# stamp an alert with the wrong owner. Missing catalog: rc 2. Usage: rc 64.
# `--check` also checks that each lane id is catalog/lanes.d/<id>.json, each
# log is logs/<x>.log and the owner doc exists (they need the repo tree).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
CAT="${COMPONENTS_TSV:-$ROOT/catalog/components.tsv}"
NAME_RE='^[a-z][a-z0-9-]{0,63}$'
STAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z? ?'

usage() { echo "usage: component-of.sh <alert line|family> | --batch | --check" >&2; exit 64; }
die_row() { # die_row <lineno> <reason> <raw line>
  echo "component-of: $(basename "$CAT"):$1: $2: $3" >&2
  exit 2
}

[ $# -ge 1 ] || usage
MODE=one
case "$1" in
  --batch) MODE=batch ;;
  --check) MODE=check ;;
  --) shift; [ $# -ge 1 ] || usage ;;
  -h|--help) usage ;;
esac

[ -r "$CAT" ] || { echo "component-of: catalog not readable: $CAT" >&2; exit 2; }

COMP=(); RE=(); LANES=(); LOGS=(); DOCS=(); LNO=()
n=0
while IFS= read -r raw || [ -n "$raw" ]; do
  n=$((n+1))
  [[ -z "$raw" || "$raw" == \#* ]] && continue
  tabs="${raw//[^$'\t']/}"
  [ "${#tabs}" -eq 4 ] || die_row "$n" "want 5 tab-separated fields, got $(( ${#tabs} + 1 ))" "$raw"
  IFS=$'\t' read -r c re l g d <<<"$raw"
  [[ "$c" =~ $NAME_RE ]] || die_row "$n" "component must match $NAME_RE" "$raw"
  [ -n "$re" ] || die_row "$n" "empty regex" "$raw"
  [[ "" =~ $re ]]; [ $? -eq 2 ] && die_row "$n" "regex does not compile" "$raw"
  for f in "$l" "$g" "$d"; do [ -n "$f" ] || die_row "$n" "empty field (write - for none)" "$raw"; done
  COMP+=("$c"); RE+=("$re"); LANES+=("$l"); LOGS+=("$g"); DOCS+=("$d"); LNO+=("$n")
done < "$CAT"

if [ "$MODE" = check ]; then
  i=0
  while [ "$i" -lt "${#COMP[@]}" ]; do
    raw="${COMP[$i]}"$'\t'"${RE[$i]}"$'\t'"${LANES[$i]}"$'\t'"${LOGS[$i]}"$'\t'"${DOCS[$i]}"
    if [ "${LANES[$i]}" != - ]; then
      IFS=, read -r -a ids <<<"${LANES[$i]}"
      for id in "${ids[@]}"; do
        [ -f "$ROOT/catalog/lanes.d/$id.json" ] || die_row "${LNO[$i]}" "lane $id has no catalog/lanes.d/$id.json" "$raw"
      done
    fi
    if [ "${LOGS[$i]}" != - ]; then
      IFS=, read -r -a ps <<<"${LOGS[$i]}"
      for p in "${ps[@]}"; do
        [[ "$p" =~ ^logs/[A-Za-z0-9._-]+\.log$ ]] || die_row "${LNO[$i]}" "log path $p is not logs/<x>.log" "$raw"
      done
    fi
    if [ "${DOCS[$i]}" != - ] && [ ! -e "$ROOT/${DOCS[$i]}" ]; then
      die_row "${LNO[$i]}" "owner doc ${DOCS[$i]} does not exist" "$raw"
    fi
    i=$((i+1))
  done
  echo "components: $(printf '%s\n' "${COMP[@]}" | sort -u | grep -c .) component(s), ${#COMP[@]} row(s)"
  exit 0
fi

resolve() { # resolve <line> -> the component or unowned
  local s="$1" i=0
  [[ "$s" =~ $STAMP_RE ]] && s="${s:${#BASH_REMATCH[0]}}"
  while [ "$i" -lt "${#COMP[@]}" ]; do
    if [[ "$s" =~ ${RE[$i]} ]]; then printf '%s\n' "${COMP[$i]}"; return 0; fi
    i=$((i+1))
  done
  printf 'unowned\n'
}

if [ "$MODE" = batch ]; then
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    id="${rec%%$'\t'*}"
    if [ "$id" = "$rec" ]; then line=""; else line="${rec#*$'\t'}"; fi
    printf '%s\t%s\n' "$id" "$(resolve "$line")"
  done
  exit 0
fi

resolve "$*"

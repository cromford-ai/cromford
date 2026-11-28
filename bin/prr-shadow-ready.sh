#!/bin/bash
# bin/prr-shadow-ready.sh — is a lane ready to move its gh_source row from
# shadow to record? (BH-10211 C0). No model call, no network, no write.
#
# Usage:
#   bin/prr-shadow-ready.sh <lane-id>          one line for one lane
#   bin/prr-shadow-ready.sh --all [--md]       one line (or Markdown table row)
#                                              per gh_source lane: each lane
#                                              with catalog/lanes.d/<lane>.knobs.d/GH_SOURCE.json
#
# It reads the shadow-read counter of prr_read, written by prr_count_add
# (bin/lib/prr-count.sh): every kept day file of
# <root>/logs/prr-count/<lane>/<YYYY-MM-DD>.tsv, root ${HARNESS:-${H:-/root/harness}}.
#   hours    = floor((now - the oldest `first`) / 3600)
#   agreed   = the sum of `agree`
#   mismatch = max(the sum of `mismatch`, the count of `PRR_SHADOW lane=<lane> `
#              lines in logs/prr-shadow.log at or after the oldest `first`).
#              The log count covers a counter write a lock timeout dropped.
# READY needs hours >= PRR_READY_HOURS AND agreed >= PRR_READY_MIN_AGREED AND
# mismatch = 0 AND a readable counter. miss and skip do not block.
#
# Output: <lane> READY|NOT READY hours=<h> agreed=<n> mismatch=<n> miss=<n> skip=<n>[ why=<r,...>]
# Reasons: hours<H, agreed<N, mismatch>0, no-counter, unreadable.
# rc 0 READY; 1 NOT READY; 2 no counter, an unreadable or malformed file, or a
# bad lane id. --all exits 0 when every lane is READY, else the highest rc.
# Knobs (catalog/lanes.d/_lib.prr-count.json): PRR_READY_HOURS, PRR_READY_MIN_AGREED.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd) || exit 2
# shellcheck source=bin/lib/prr-count.sh
. "$R/bin/lib/prr-count.sh" || { echo "prr-shadow-ready: cannot source bin/lib/prr-count.sh" >&2; exit 2; }
ROOT="${HARNESS:-${H:-/root/harness}}"
# fallback only: the knob is PRR_READY_HOURS in catalog/lanes.d/_lib.prr-count.json
NEED_H=$(_prr_count_int "${PRR_READY_HOURS:-}" 48)
# fallback only: the knob is PRR_READY_MIN_AGREED in catalog/lanes.d/_lib.prr-count.json
NEED_A=$(_prr_count_int "${PRR_READY_MIN_AGREED:-}" 100)
NOW=$(prr_count_now)
MD=0

# judge <lane> — sets LINE_* and returns the lane's rc.
judge() {
  local lane="$1" d="$ROOT/logs/prr-count/$1" files=() f sums start h log logm rc=0 why=""
  L_H=0 L_A=0 L_M=0 L_MISS=0 L_SKIP=0 L_WHY="" L_ST="NOT READY"
  if ! [[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then L_WHY="bad-lane"; return 2; fi
  for f in "$d"/*.tsv; do [ -e "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" = 0 ]; then L_WHY="no-counter"; return 2; fi
  # One awk over every kept file: a row that is not <known key>\t<digits> is
  # malformed, and an unreadable counter is never clean.
  sums=$(awk -F'\t' '
    !($1 ~ /^(first|last|agree|mismatch|miss|skip|miss\.[a-z0-9_:.-]+)$/ && $2 ~ /^[0-9]+$/ && NF == 2) { bad = 1; exit }
    $1 == "first" { if (s == "" || $2 + 0 < s + 0) s = $2 }
    $1 == "agree" { a += $2 } $1 == "mismatch" { m += $2 }
    $1 == "miss" { x += $2 } $1 == "skip" { k += $2 }
    END { if (bad || s == "") print "bad"; else printf "%d %d %d %d %d\n", s, a, m, x, k }' "${files[@]}" 2>/dev/null) || sums=bad
  if [ -z "$sums" ] || [ "$sums" = bad ]; then L_WHY="unreadable"; return 2; fi
  read -r start L_A L_M L_MISS L_SKIP <<<"$sums"
  h=$(( (NOW - start) / 3600 )); [ "$h" -ge 0 ] || h=0; L_H=$h
  log="$ROOT/logs/prr-shadow.log"
  if [ -r "$log" ]; then
    logm=$(awk -v l="lane=$lane" -v t="$(date -u -d "@$start" '+%Y-%m-%dT%H:%M:%SZ')" \
      '$2 == "PRR_SHADOW" && $3 == l && $1 >= t { n++ } END { print n + 0 }' "$log" 2>/dev/null)
    [[ "$logm" =~ ^[0-9]+$ ]] && [ "$logm" -gt "$L_M" ] && L_M=$logm
  fi
  [ "$L_H" -ge "$NEED_H" ] || why="${why:+$why,}hours<$NEED_H"
  [ "$L_A" -ge "$NEED_A" ] || why="${why:+$why,}agreed<$NEED_A"
  [ "$L_M" = 0 ] || why="${why:+$why,}mismatch>0"
  if [ -z "$why" ]; then L_ST=READY; else L_WHY=$why; rc=1; fi
  return "$rc"
}

emit() { # emit <lane>
  if [ "$MD" = 1 ]; then
    printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$1" "$L_ST" "$L_H" "$L_A" "$L_M" "$L_MISS" "$L_SKIP" "${L_WHY:--}"
  else
    printf '%s %s hours=%s agreed=%s mismatch=%s miss=%s skip=%s%s\n' "$1" "$L_ST" "$L_H" "$L_A" "$L_M" "$L_MISS" "$L_SKIP" "${L_WHY:+ why=$L_WHY}"
  fi
}

ALL=0; LANE=""
for a in "$@"; do
  case "$a" in
    --all) ALL=1 ;;
    --md) MD=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    -*) echo "prr-shadow-ready: unknown option $a" >&2; exit 2 ;;
    *) LANE="$a" ;;
  esac
done
lanes=()
if [ "$ALL" = 1 ]; then
  for f in "$R"/catalog/lanes.d/*.knobs.d/GH_SOURCE.json; do
    [ -e "$f" ] || continue
    f="${f%.knobs.d/GH_SOURCE.json}"; lanes+=("${f##*/}")
  done
elif [ -n "$LANE" ]; then
  lanes=("$LANE")
else
  echo "usage: bin/prr-shadow-ready.sh <lane-id> | --all [--md]" >&2; exit 2
fi
[ "${#lanes[@]}" -gt 0 ] || { echo "prr-shadow-ready: no gh_source lane found" >&2; exit 2; }

if [ "$MD" = 1 ]; then
  echo '| lane | status | hours | agreed | mismatch | miss | skip | why |'
  echo '| --- | --- | --- | --- | --- | --- | --- | --- |'
fi
worst=0
for l in "${lanes[@]}"; do
  judge "$l"; rc=$?
  emit "$l"
  [ "$rc" -gt "$worst" ] && worst=$rc
done
exit "$worst"

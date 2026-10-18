#!/bin/bash
# bin/lib/fleet-version-decide.sh — the fleet version check's pure half (BH-7191).
# Sourced, never executed; defines functions only, safe under set -u.
# Reader: bin/fleet-version-check.sh (the hub lane).
#
# fvc_main_log <checkout> [n]
#   Prints "<sha> <commit epoch> <F>" for the first-parent origin/main history,
#   newest first, at most n lines (default 3000). F is 1 when that commit
#   touches a path in FLEET_PATHS (bin/lib/fleet-paths.sh, sourced by the
#   caller), else 0. With FLEET_PATHS empty every line is F=1, so a missing lib
#   can only make the check stricter. rc 1 when the log is empty or unreadable.
#
# fvc_lag_min <sha> <main log file> [as_of epoch]
#   Prints the minutes the sha lags main as of as_of (default FVC_NOW, else now):
#     <n>     the sha is on the log. Its missing commits are the lines above it;
#             of those, the ones with epoch <= as_of and F=1 count. None left
#             prints 0 (a sha at the tip is 0 whatever its age). Else
#             floor((as_of - epoch of the oldest kept) / 60), at least 0.
#     >=<n>   not on the log, but an ancestor of origin/main in the checkout
#             (older than the fetched window): n is measured from the oldest
#             fetched line. Needs FVC_CHECKOUT; without it this is notmain.
#     notmain an unknown sha, or a branch never merged.
#   The only git call is the not-found branch.
#
# fvc_decide
#   Reads TSV on stdin, one row per box, columns in order:
#     box role sha reported_epoch lag last_beat_at sync_timer harness_synced_at
#   (empty = unknown). Sources fleet-version-rules.d/*.sh (FVC_RULES_DIR
#   overrides the directory) in LC_ALL=C name order, once. For each row it sets
#   FVC_BOX FVC_ROLE FVC_SHA FVC_REPORTED FVC_LAG FVC_BEAT FVC_SYNC_TIMER
#   FVC_SYNCED and calls each function in FVC_RULES in order. A rule prints
#   zero or more lines "ALERT <box> <kind> <detail>", "SKIP <box> <why>" or
#   "OK <box> <detail>", and returns 2 to stop the rules for this box.
#   Thresholds: FVC_MAX_LAG_MIN and FVC_MAX_BEAT_GAP_MIN (default 30 each). A
#   value that is not a whole number prints one WARN line and uses 30.
#   No network call, no git call.

fvc_main_log() {
  local co="${1:-}" n="${2:-3000}" all fleet
  [ -n "$co" ] || return 1
  case "$n" in ''|*[!0-9]*) n=3000 ;; esac
  all=$(git -C "$co" log --first-parent --format='%H %ct' -n "$n" origin/main 2>/dev/null) || return 1
  [ -n "$all" ] || return 1
  if [ -z "${FLEET_PATHS:-}" ]; then
    printf '%s\n' "$all" | awk '{ print $1, $2, 1 }'
    return 0
  fi
  # shellcheck disable=SC2086  # FLEET_PATHS is a word list of pathspecs
  fleet=$(git -C "$co" log --first-parent --format=%H -n "$n" origin/main -- $FLEET_PATHS 2>/dev/null) \
    || { printf '%s\n' "$all" | awk '{ print $1, $2, 1 }'; return 0; }
  awk 'NR == FNR { if ($1 != "") f[$1] = 1; next } { print $1, $2, ($1 in f) ? 1 : 0 }' \
    <(printf '%s\n' "$fleet") <(printf '%s\n' "$all")
}

fvc_lag_min() {
  local sha="${1:-}" f="${2:-}" asof="${3:-}" out oldest
  [ -n "$asof" ] || asof="${FVC_NOW:-$(date +%s)}"
  sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  case "$sha" in ''|*[!0-9a-f]*) echo notmain; return 0 ;; esac
  [ "${#sha}" -ge 7 ] && [ "${#sha}" -le 40 ] || { echo notmain; return 0; }
  [ -r "$f" ] || { echo notmain; return 0; }
  out=$(awk -v s="$sha" -v now="$asof" '
    NF < 3 { next }
    { last = $2 }
    substr($1, 1, length(s)) == s {
      if (keep == "") { print 0 } else { m = int((now - keep) / 60); print (m < 0 ? 0 : m) }
      found = 1; exit
    }
    $2 <= now && $3 == 1 { keep = $2 }
    END { if (!found) print "NOTFOUND " last }' "$f")
  case "$out" in
    NOTFOUND*) oldest=${out#NOTFOUND } ;;
    *) echo "$out"; return 0 ;;
  esac
  if [ -n "${FVC_CHECKOUT:-}" ] && [ -n "$oldest" ] \
    && git -C "$FVC_CHECKOUT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
    local m=$(( (asof - oldest) / 60 ))
    [ "$m" -ge 0 ] || m=0
    echo ">=$m"
    return 0
  fi
  echo notmain
}

fvc_decide() {
  local d f r rc
  local FVC_BOX FVC_ROLE FVC_SHA FVC_REPORTED FVC_LAG FVC_BEAT FVC_SYNC_TIMER FVC_SYNCED
  case "${FVC_MAX_LAG_MIN:-30}" in
    ''|*[!0-9]*) echo "WARN FVC_MAX_LAG_MIN=${FVC_MAX_LAG_MIN} is not a whole number; using 30"; FVC_MAX_LAG_MIN=30 ;;
  esac
  case "${FVC_MAX_BEAT_GAP_MIN:-30}" in
    ''|*[!0-9]*) echo "WARN FVC_MAX_BEAT_GAP_MIN=${FVC_MAX_BEAT_GAP_MIN} is not a whole number; using 30"; FVC_MAX_BEAT_GAP_MIN=30 ;;
  esac
  FVC_MAX_LAG_MIN=$(( 10#${FVC_MAX_LAG_MIN:-30} )); FVC_MAX_BEAT_GAP_MIN=$(( 10#${FVC_MAX_BEAT_GAP_MIN:-30} ))
  FVC_RULES=()
  d="$(dirname "${BASH_SOURCE[0]}")/fleet-version-rules.d"
  [ -z "${FVC_RULES_DIR:-}" ] || d=$FVC_RULES_DIR
  # LC_ALL=C name order: the glob sorts by the locale's collation.
  # shellcheck disable=SC2034  # LC_ALL is read by the glob below
  local LC_ALL=C
  # Unquoted on purpose: tests/lib/scratch.sh's closure scan follows $d/*.sh
  # into fleet-version-rules.d/ only in this form. The path has no spaces.
  # shellcheck disable=SC2231
  for f in $d/*.sh; do
    [ -f "$f" ] || continue
    # shellcheck source=/dev/null
    . "$f" || { echo "WARN rule file $f did not load"; continue; }
  done
  # Tab is IFS whitespace, and read folds a run of it into one break, so an
  # empty column would shift the rest left. \037 is not whitespace.
  # shellcheck disable=SC2034  # the FVC_* row fields are read by the sourced rules
  while IFS=$'\037' read -r FVC_BOX FVC_ROLE FVC_SHA FVC_REPORTED FVC_LAG FVC_BEAT FVC_SYNC_TIMER FVC_SYNCED; do
    [ -n "$FVC_BOX" ] || continue
    for r in "${FVC_RULES[@]}"; do
      "$r"; rc=$?
      [ "$rc" -eq 2 ] && break
    done
  done < <(tr '\t' '\037')
  return 0
}

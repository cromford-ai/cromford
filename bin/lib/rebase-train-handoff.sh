#!/bin/bash
# bin/lib/rebase-train-handoff.sh — the rebase train's park becomes a conductor
# hand-off to bin/blocked-resolver.sh (BH-9167).
#
# THE BUG. After two STRIKE lines bin/rebase-train.sh appended the PR to
# state/rebase-train-skip.txt and wrote an ALERTS line that said "the merge
# conductor classifies it conflict-unresolvable and bin/blocked-resolver.sh
# rebuilds the ticket fresh". Nothing read the skip list, and the conductor
# parks conflict-unresolvable only when ITS OWN rebase fails, so the row stayed
# NEEDS_REBASE and the resolver never saw the PR (project-4 #2325/#2326, 23h).
#
# THE FIX. The train writes the same park archie-fm writes
# (afm_request_fix_round, bin/lib/archie-fm.sh): a BLOCKED_HUMAN row with a
# reason mc_handoff_owns knows, through mc_transition (which records the
# hand-off file, so mc_handoff_sticky holds the row), plus the
# `handed to bin/blocked-resolver.sh` log line br_handoff_lines parses. The
# resolver then finds it through br_from_conductor and walks its existing
# rebase-conflict ladder: mechanical, fix round, rebuild-fresh.
#
# Functions only, never an exit. Needs bin/lib/merge-conductor-lib.sh loaded
# and mc_init run by the caller; without it every function answers
# `no-conductor-lib` rc 1.

# _rth_ready — rc 0 when every conductor function this lib calls is defined.
_rth_ready() {
  local f
  for f in mc_row_get mc_transition mc_log mc_handoff_owns mc_handoff_rel_file \
           mc_attempt_has mc_attempt_put mc_record_for; do
    command -v "$f" >/dev/null 2>&1 || return 1
  done
  return 0
}

# rth_park_why <train-log> <pr-url> — the conductor reason for this PR's park,
#   read from the detail line after its LAST `STRIKE <url>` line. The URL match
#   is a whole field, so pull/23 never matches pull/232. A line for the URL that
#   is not a strike detail (`rebasing`, `conflicts auto-unioned`) is skipped.
#   Always prints a reason that starts with a word mc_handoff_owns knows.
rth_park_why() {
  local log="$1" url="$2" out kind arg tail="rebase-train parked it after 2 failed rounds" parts=()
  out=$(awk -v u="$url" '
    $4 == "STRIKE" && $5 == u && NF == 5 { seen = 1; got = ""; next }
    !seen || got != "" || $4 != u { next }
    {
      t = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", t)
      p = "conflict outside the auto classes ("
      if (index(t, p) == 1 && index(t, ") — left for judgment") > 0) {
        f = substr(t, length(p) + 1); f = substr(f, 1, index(f, ") — left for judgment") - 1)
        got = "conflict\t" f
      } else if (index(t, "rebase stopped >6 times") == 1) {
        got = "stopped\t"
      } else if (t ~ /^typecheck: [0-9]+ NEW error\(s\)/) {
        n = t; sub(/^typecheck: /, "", n); sub(/ .*/, "", n); got = "tsc\t" n
      } else if (index(t, "unit tests RED post-rebase") == 1) {
        got = "unit\t"
      }
    }
    END { print got }' "$log" 2>/dev/null) || out=""
  kind=${out%%$'\t'*}; arg=${out#*$'\t'}
  # One space between paths, none at the ends ("(a.ts src/b.ts )" in the log).
  read -r -a parts <<<"$arg"; arg="${parts[*]}"
  case "$kind" in
    conflict)
      case "$arg" in
        ''|'resolver failed') printf 'conflict-unresolvable: %s\n' "$tail" ;;
        *) printf 'conflict-unresolvable: %s — %s\n' "$arg" "$tail" ;;
      esac ;;
    stopped) printf 'conflict-unresolvable: %s (rebase stopped more than 6 times)\n' "$tail" ;;
    tsc)     printf 'rebase-gate-red: %s (typecheck: %s new errors)\n' "$tail" "$arg" ;;
    unit)    printf 'rebase-gate-red: %s (unit tests red)\n' "$tail" ;;
    *)       printf 'conflict-unresolvable: %s\n' "$tail" ;;
  esac
}

# rth_handed <key> <head> — rc 0 when the train already handed this (PR, head)
#   off and that hand-off still stands (the row is parked on a hand-off reason
#   on this head) or the resolver has released it. A train marker whose park a
#   conductor tick overwrote, with no release, is rc 1: the park is written
#   again once. A new head is a new fact: no marker, rc 1.
rth_handed() {
  local key="${1:-}" head="${2:-}" row
  _rth_ready || return 1
  [ -n "$key" ] && [ -n "$head" ] && [ "$head" != - ] || return 1
  mc_attempt_has "trainhandoff $key $head" || return 1
  row=$(mc_row_get "$key")
  if [ "$(cut -f2 <<<"$row")" = BLOCKED_HUMAN ] && mc_handoff_owns "$(cut -f7 <<<"$row")" \
     && [ "$(cut -f4 <<<"$row")" = "$head" ]; then
    return 0
  fi
  [ -e "$(mc_handoff_rel_file "$key")" ] && return 0
  mc_attempt_has "handoff-rel $key $head" && return 0
  return 1
}

# rth_handoff <pr-url> <head> <record-dir> <reason> — write the park. Prints
#   one word:
#   handed rc 0          the row, the trainhandoff marker and the log line
#   conductor-park rc 3  the conductor already parked it on a hand-off reason
#                        on this head; nothing rewritten
#   already rc 3         rth_handed says yes; nothing written
#   no-row rc 1          the conductor has no row for the PR on this box
#   bad-head rc 1        no usable head sha
#   no-conductor-lib rc 1
#   Order: row, then marker, then log line. A crash between the row and the
#   marker is repaired by the next run as a same-state no-op.
rth_handoff() {
  local url="${1:-}" head="${2:-}" rec="${3:-}" why="${4:-}" slug n key row
  _rth_ready || { echo no-conductor-lib; return 1; }
  case "$url" in https://github.com/*/*/pull/[0-9]*) ;; *) echo no-row; return 1 ;; esac
  slug=${url#https://github.com/}; slug=${slug%/pull/*}; n=${url##*/}; key="$slug#$n"
  case "$head" in ''|-) echo bad-head; return 1 ;; esac
  [ "${#head}" -ge 7 ] || { echo bad-head; return 1; }
  row=$(mc_row_get "$key")
  [ -n "$row" ] || { echo no-row; return 1; }
  if rth_handed "$key" "$head"; then echo already; return 3; fi
  if [ "$(cut -f2 <<<"$row")" = BLOCKED_HUMAN ] && mc_handoff_owns "$(cut -f7 <<<"$row")" \
     && [ "$(cut -f4 <<<"$row")" = "$head" ]; then
    echo conductor-park; return 3
  fi
  [ -n "$why" ] || why="conflict-unresolvable: rebase-train parked it after 2 failed rounds"
  [ -n "$rec" ] || rec=$(mc_record_for "$url" || true)
  mc_transition "$key" BLOCKED_HUMAN "$why" "$head" "$(cut -f5 <<<"$row")" "$url" - DIRTY "${rec:--}" >/dev/null
  mc_attempt_put "trainhandoff $key $head"
  mc_log "$key BLOCKED_AGENT $why — handed to bin/blocked-resolver.sh (rebase-train: 2 failed rounds; its ladder: merge main again, then an agent fix round on this branch, then a fresh rebuild): $url"
  echo handed
  return 0
}

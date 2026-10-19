#!/bin/bash
# bin/lib/fanin-window-stall.sh — the merge conductor's window-stall alert.
# Sourced by bin/lib/fanin.sh, never executed. No set -e, no exit: every
# function returns 0 and never fails its caller (the fanin.sh rule).
#
# THE STALL. A fan-in run of the merge-conductor lane for one repo (a full tick
# or a keyed run) where every enumerated PR is accounted `deferred:window` did
# no work on that repo: the window had no room for any worker. One such run is
# normal under load. MC_WINDOW_STALL_TICKS (default 2, 0 = off, not a number =
# 2) such runs in a row is a silent stall, and it opens one warn alert:
#   lane-alert.sh --severity warn --id mc-window-stall-<repo> merge-conductor
#     "MERGE CONDUCTOR STALL <repo>: every PR deferred (deferred:window) on <n>
#      runs in a row; ..."
# plus one line in the conductor log ($FANIN_LOG). The first later run that
# accounts any other outcome resolves that id, if the streak had reached the
# threshold. Not counted, so the streak is unchanged: a run that enumerated 0
# PRs, and an orphan report (fanin.sh does not call this on that path).
# deferred:solo is a hand-off to a keyed run, not a stall, so it resets.
#
# THE STATE. $root/state/fanin/merge-conductor/.window-stall, TSV
# `repo<TAB>count<TAB>epoch`, one row per repo, rewritten under `flock -w 5`
# on .window-stall.lock. A row older than 7 days is dropped on each write. If
# the lock is not free in 5 s, nothing is written and nothing is sent: the
# next run counts again. The count is written before the alert is sent, so a
# failed send is sent again by the next all-deferred run with the same id.

_fws_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# fws_note <ledger> <lane> <scope> <enumerated> <tally> — called by
# _fanin_report after its FANIN line. <tally> is the text it built:
# "<outcome> <n>, <outcome> <n>"; the count is the last word of each part.
fws_note() {
  local lane="$2" scope="${3:-run}" en="$4" tally="${5:-}" h th sf now all out prev cnt id text
  [ "$lane" = merge-conductor ] || return 0
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  th="${MC_WINDOW_STALL_TICKS:-2}"
  case "$th" in ''|*[!0-9]*) th=2 ;; esac
  [ "$th" -gt 0 ] 2>/dev/null || return 0
  case "$en" in ''|*[!0-9]*) return 0 ;; esac
  [ "$en" -gt 0 ] || return 0
  all=$(awk -v t="$tally" -v en="$en" 'BEGIN {
    n = split(t, p, ", "); ok = (n == 1)
    for (i = 1; i <= n; i++) { c = p[i]; sub(/.* /, "", c); o = p[i]; sub(/ [^ ]*$/, "", o)
      if (o != "deferred:window" || c != en) ok = 0 }
    print ok + 0 }')
  sf="$h/state/fanin/merge-conductor/.window-stall"
  mkdir -p "${sf%/*}" 2>/dev/null || return 0
  [ "$all" = 1 ] || [ -s "$sf" ] || return 0
  now=$(date +%s)
  out=$( ( flock -w 5 7 2>/dev/null || exit 0
      tmp="$sf.tmp.$BASHPID"
      : > "$tmp" 2>/dev/null || exit 0
      [ -f "$sf" ] || : > "$sf" 2>/dev/null || exit 0
      awk -F'\t' -v OFS='\t' -v s="$scope" -v now="$now" -v all="$all" -v tmp="$tmp" '
        $3 !~ /^[0-9]+$/ || $3 + 604800 < now { next }
        $1 == s { prev = $2 + 0; next }
        { print > tmp }
        END { cnt = (all == 1) ? prev + 1 : 0
              if (cnt > 0) print s, cnt, now > tmp
              print prev + 0, cnt }' "$sf" 2>/dev/null > "$tmp.out" \
        && mv -f "$tmp" "$sf" 2>/dev/null && cat "$tmp.out"
      rm -f "$tmp" "$tmp.out" 2>/dev/null
      exit 0
    ) 7>>"$sf.lock" 2>/dev/null )
  read -r prev cnt <<<"$out"
  case "$cnt" in ''|*[!0-9]*) return 0 ;; esac
  id="mc-window-stall-$(printf '%s' "$scope" | tr -c 'A-Za-z0-9_-' '_')"
  if [ "$cnt" -ge "$th" ]; then
    text="MERGE CONDUCTOR STALL $scope: every PR deferred (deferred:window) on $cnt runs in a row; last run enumerated $en. No PR of this repo is being worked. Window: MC_FULL_TICK_BUDGET_S=${MC_FULL_TICK_BUDGET_S:-1500}."
    _fws_send "$h" "$id" "$text" --severity warn
  elif [ "$cnt" = 0 ] && [ "${prev:-0}" -ge "$th" ]; then
    text="MERGE CONDUCTOR STALL $scope recovered: $tally"
    _fws_send "$h" "$id" "$text" --resolve
  fi
  return 0
}

# _fws_send <root> <id> <text> <mode...> — the log line, then lane-alert.sh,
# or bin/alert-line.sh on a root without it (same id; --resolve is its
# --severity resolved). With neither, the log line is the record.
_fws_send() {
  local h="$1" id="$2" text="$3"
  shift 3
  [ -n "${FANIN_LOG:-}" ] && printf '%s %s\n' "$(_fws_stamp)" "$text" >> "$FANIN_LOG" 2>/dev/null
  if [ -x "$h/bin/lane-alert.sh" ]; then
    "$h/bin/lane-alert.sh" "$@" --id "$id" merge-conductor "$text" >/dev/null 2>&1 || true
  elif [ -x "$h/bin/alert-line.sh" ]; then
    [ "$1" = --resolve ] && set -- --severity resolved
    "$h/bin/alert-line.sh" "$@" --id "$id" "$text" >/dev/null 2>&1 || true
  fi
  return 0
}

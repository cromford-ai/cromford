#!/bin/bash
# shellcheck shell=bash
# bin/lib/observe-report.sh — BH-3859: the one operator message a lane that
# ships dark posts after it has watched for a while. Sourced, never run; nothing
# here runs on source. bin/dequeue-watch.sh is the first caller; any lane with
# an observe mode that logs WOULD_<ACTION> lines can call it with its own knob.
#
#   observe_report_tick <lane> <ticks-N> <log-file> <flip-cmd> [since]
#     Call it once at the end of every full observe tick. It counts the tick in
#     $root/state/observe-report/<lane>.json ({since, ticks, sent_at}), and on
#     the N-th tick sends ONE warn through bin/lane-alert.sh
#     (--id observe-report:<lane>): how many ticks, the WOULD_ lines of
#     <log-file> stamped at or after `since` counted per action and per PR, up
#     to 5 example lines, and <flip-cmd>. After that it does nothing, ever: it
#     never sends twice and never flips anything itself. [since] is the stamp
#     (YYYY-MM-DD HH:MM:SSZ) a fresh counter starts from, so the caller can pass
#     the start of the tick whose WOULD_ lines it is counting; default now.
#     rc 0 counted (and sent, at N). rc 1 = no root, bad input, or the send
#     could not be made; then nothing is stamped and the next tick retries.
#
# The state file is written tmp + mv. A missing or unparseable one is a fresh
# counter (logged once). sent_at is stamped only after lane-alert.sh answered
# rc 0; a failed or missing lane-alert.sh leaves it unstamped for the next tick.
# Reads at most the last 20000 lines of <log-file> (D21).
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither the verb
# returns 1 and builds no path.

_or_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_or_log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') observe-report: $2" >> "$1" 2>/dev/null || true; }

# _or_message <lane> <ticks> <since> <log-file> <flip-cmd> — the operator text.
# The stamp regex is spelled without {n}: older mawk (1.3.4-20200120, Debian 12)
# reads intervals literally and would match nothing, falsely reporting "nothing".
_or_message() {
  local lane="$1" n="$2" since="$3" logf="$4" flip="$5" lines total prs counts ex
  lines=$(tail -n 20000 "$logf" 2>/dev/null | grep -F ' WOULD_' \
    | awk -v s="$since" '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z / && ($1 " " $2) >= s')
  if [ -z "$lines" ]; then
    printf '%s has watched for %s ticks since %s without acting. It would have done nothing in %s ticks. To let it act: %s' \
      "$lane" "$n" "$since" "$n" "$flip"
    return 0
  fi
  total=$(printf '%s\n' "$lines" | wc -l)
  prs=$(printf '%s\n' "$lines" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | sort -u | wc -l)
  counts=$(printf '%s\n' "$lines" | grep -oE 'WOULD_[A-Z_]+' | sort | uniq -c | sort -k1,1nr -k2 \
    | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }')
  ex=$(head -5 <<<"$lines" | cut -c1-200 | paste -sd';' - | sed 's/;/; /g')
  printf '%s has watched for %s ticks since %s without acting. It would have done %s %s on %s %s: %s. Examples: %s. To let it act: %s' \
    "$lane" "$n" "$since" "$total" "$([ "$total" = 1 ] && echo thing || echo things)" \
    "$prs" "$([ "$prs" = 1 ] && echo PR || echo PRs)" "$counts" "$ex" "$flip"
}

observe_report_tick() {
  local root lane="${1:-}" n="${2:-}" logf="${3:-}" flip="${4:-}" start="${5:-}" dir f st since ticks sent msg now rc
  root=$(_or_root)
  [ -n "$root" ] || return 1
  [[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ -n "$logf" ] && [ -n "$flip" ] || return 1
  now=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  [[ "$start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || start="$now"
  dir="$root/state/observe-report"; f="$dir/$lane.json"
  mkdir -p "$dir" 2>/dev/null || return 1
  if ! st=$(jq -ce 'select((.since | type) == "string" and (.ticks | type) == "number")' "$f" 2>/dev/null); then
    [ -e "$f" ] && _or_log "$logf" "$lane state unreadable, counting from fresh"
    st=$(jq -nc --arg s "$start" '{since: $s, ticks: 0, sent_at: null}')
  fi
  sent=$(printf '%s' "$st" | jq -r '.sent_at // ""')
  [ -z "$sent" ] || return 0
  since=$(printf '%s' "$st" | jq -r '.since')
  ticks=$(( $(printf '%s' "$st" | jq -r '.ticks | floor') + 1 ))
  st=$(printf '%s' "$st" | jq -c --argjson t "$ticks" '.ticks = $t')
  _or_write "$f" "$st" || return 1
  [ "$ticks" -ge "$n" ] || return 0

  if [ ! -x "$root/bin/lane-alert.sh" ]; then
    _or_log "$logf" "lane-alert missing, not sent"
    return 1
  fi
  msg=$(_or_message "$lane" "$ticks" "$since" "$logf" "$flip")
  "$root/bin/lane-alert.sh" --severity warn --id "observe-report:$lane" "$lane" "$msg" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ]; then
    _or_log "$logf" "lane-alert rc $rc, not sent"
    return 1
  fi
  _or_write "$f" "$(printf '%s' "$st" | jq -c --arg t "$(date -u +%FT%TZ)" '.sent_at = $t')" || return 1
  _or_log "$logf" "sent after $ticks ticks"
  return 0
}

# _or_write <file> <json> — atomic: the state is the old one or the new one.
_or_write() {
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null && return 0
  rm -f "$1.tmp.$$" 2>/dev/null
  return 1
}

#!/bin/bash
# bin/lib/wake-class-ticket-holds.sh — BH-1034 wake class `ticket-holds`
# (BH-6977, BH-6547.1).
#
# ARMED BY the class flag `wake-lanes-ticket-holds` (`bin/jobs-client.sh
# flag-set wake-lanes-ticket-holds on`), and by nothing else. Without it
# bin/wake-loop.sh's CLASS_ON is 0 for this class and neither hook below is
# ever called. flags/wake-lanes-off beats the class flag.
#
# WHAT IT DOES. Any wake on a GitHub issue (kind issue, numeric key) makes this
# class read the issue's thread. Not only issue_comment.*: wake rows dedupe on
# (repo, kind, key, minute) and the FIRST event in a minute wins, so a HOLD
# posted in the same minute as a label or an edit arrives as an issues.* row.
# The row carries no comment text, so this class reads the thread itself (at
# most 1000 comments, oldest first) and mirrors every person
# HOLD or RESUME comment into ticket_holds through bin/lib/ticket-edges.sh
# (te_put_holds; hold.sh's `decide` says what a HOLD and a lift are). It
# changes no hold decision: hold_classify stays the reader.
#
# BOUNDED. At most ticket_holds.wake_reads_max threads per drain (settings row,
# default 20, 0 = the class does nothing). Threads over the cap are dropped
# from this drain with one say line; the next wake on that issue reads
# it again. A failed thread read writes one line to logs/ticket-holds.log and
# writes no row.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines say(), so
# nothing here calls it at source time — only the dispatch function does.
# shellcheck shell=bash

# Accumulator of "<project>|<repo>|<issue>" entries, initialised at source time
# (the loop runs under `set -u`).
WC_TICKET_HOLDS_Q=""

# wc_ticket_holds_row <project> <kind> <key> <event> <repo> <id>
# Any issue wake with an issue number and a repo slug counts, whatever its
# event (see WHAT IT DOES). The upsert is keyed on comment_id, so an extra read
# writes no extra row.
wc_ticket_holds_row() {
  local p="${1:-}" kind="${2:-}" key="${3:-}" repo="${5:-}" e
  [ "$kind" = issue ] && [ -n "$p" ] || return 0
  [[ $key =~ ^[1-9][0-9]{0,8}$ ]] && [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
  e="$p|$repo|$key"
  case " $WC_TICKET_HOLDS_Q " in
    *" $e "*) ;;
    *) WC_TICKET_HOLDS_Q="${WC_TICKET_HOLDS_Q:+$WC_TICKET_HOLDS_Q }$e" ;;
  esac
  return 0
}

# wc_ticket_holds_dispatch — once per non-empty drain.
wc_ticket_holds_dispatch() {
  local q="$WC_TICKET_HOLDS_Q" max e p repo n tmp rc left=0 read=0 root
  WC_TICKET_HOLDS_Q=""
  [ -n "$q" ] || return 0
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  if ! declare -F te_put_holds >/dev/null 2>&1; then
    # shellcheck source=bin/lib/ticket-edges.sh
    . "$(dirname "${BASH_SOURCE[0]}")/ticket-edges.sh" >/dev/null 2>&1 || return 0
  fi
  max=""
  command -v setting_get >/dev/null 2>&1 && max=$(setting_get ticket_holds.wake_reads_max 2>/dev/null)
  [[ $max =~ ^[0-9]+$ ]] || max=20
  [ "$max" -gt 0 ] || return 0
  command -v gh_rest_issue_comments >/dev/null 2>&1 || {
    printf '%s ticket-holds: gh_rest_issue_comments is not defined — no thread read\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" >> "$root/logs/ticket-holds.log" 2>/dev/null
    return 0
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ticket-holds.XXXXXX" 2>/dev/null) || return 0
  for e in $q; do
    if [ "$read" -ge "$max" ]; then left=$((left + 1)); continue; fi
    p="${e%%|*}"; n="${e##*|}"; repo="${e#*|}"; repo="${repo%|*}"
    read=$((read + 1))
    gh_rest_issue_comments "$repo" "$n" 1000 > "$tmp" 2>/dev/null; rc=$?
    if [ "$rc" != 0 ]; then
      { mkdir -p "$root/logs" && printf '%s ticket-holds[%s]: %s#%s thread read failed rc=%s — no row written\n' \
          "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$p" "$repo" "$n" "$rc" >> "$root/logs/ticket-holds.log"; } 2>/dev/null
      continue
    fi
    te_put_holds "$p" "$n" "$tmp" >/dev/null 2>&1 || true
  done
  rm -f "$tmp"
  if [ "$left" -gt 0 ] && command -v say >/dev/null 2>&1; then
    say "ticket-holds: $left thread(s) left for the next wake (cap ticket_holds.wake_reads_max=$max)"
  fi
  return 0
}

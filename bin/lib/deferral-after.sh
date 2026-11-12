# shellcheck shell=bash
# bin/lib/deferral-after.sh — BH-5967: a deferral on an open build is never
# terminal, and it is released by the blocker, not by a count.
#
# WHY. On 2026-10-10, 39 of 95 open cromford tickets sat with no open PR,
# no blocker and no hold, and nothing built them. A pool build that overlapped
# an open PR on a non-splittable file stood down with `BUILD_DEFERRED ...
# After: <KEY> ...`. After JOBS_QUEUE_DEFER_MAX stand-downs the row turned
# FAILED "parked for the blocked-resolver", and the resolver reached about one
# project per 100 minutes (#5913). So the ticket waited after its blocker had
# merged: #5521 and #5888 waited on #5890 (merged 15:19Z), #5788 on #5937
# (merged 17:32Z).
#
# THE RULE. A stand-down that names the build it waits for (`After: <KEY>`) is a
# WAIT, not a failure. bin/fly-pool.sh and bin/jobs-watchdog.sh keep its row
# queued with `after` in the meta, whatever the count. The pool's spawn gate
# then holds the row with no machine until <KEY> has no open PR and nothing in
# flight, and on that tick it re-offers the row with its count reset. A wait on
# the same blocker past DEFER_AFTER_LOOP_ALERT stand-downs pages once.
#
# Defines functions only. Nothing runs on source.

# defer_after_key <text> — print the ticket key a deferral waits for. rc 1 when
# the text names none. Reads `After: <KEY>` anywhere in the text: run-build's
# two shapes are `BUILD_DEFERRED After: <KEY> <why> — ...` and
# `BUILD_DEFERRED <overlap line>; After: <KEY> — ...` (bin/lib/rb/gates.sh).
defer_after_key() {
  local t="${1:-}" k
  k=$(printf '%s' "$t" | grep -oE 'After: [A-Z][A-Z0-9]*-[0-9]+(\.[0-9]+)*' | head -n 1)
  k="${k#After: }"
  [ -n "$k" ] || return 1
  printf '%s' "$k"
}

# defer_wait_key <text> [own-key] — BH-9283: print "<KEY>\t<kind>" for the key
# any WAIT deferral names, rc 1 when it names none. First match wins:
#   1. `After: <KEY>` (the defer_after_key rule)               kind after
#   2. a `stack-wait:` line with a `ticket/<prefix>-<n>[-rN]` token that is not
#      the own key (bin/lib/rb/gates.sh's four stack-wait RESULT shapes; -rN
#      dropped, upper-cased)                                     kind stack
#   3. `Blocked-by #<n>` with an own key: <own prefix>-<n>       kind blocked
#      (GitHub-Issues projects, where the key is the prefix plus the issue).
# defer_after_key is NOT changed: the reap callers keep the After-only rule.
defer_wait_key() {
  local t="${1:-}" own="${2:-}" k tok
  if k=$(defer_after_key "$t"); then printf '%s\tafter\n' "$k"; return 0; fi
  if [[ "$t" == *"stack-wait:"* ]]; then
    while IFS= read -r tok; do
      tok="${tok#ticket/}"
      [[ "$tok" =~ ^(.*)-[rR][0-9]+$ ]] && tok="${BASH_REMATCH[1]}"
      tok=$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')
      [ -n "$tok" ] && [ "$tok" != "$own" ] && { printf '%s\tstack\n' "$tok"; return 0; }
    done < <(printf '%s' "$t" | grep -oE 'ticket/[A-Za-z][A-Za-z0-9]*-[0-9]+(\.[0-9]+)*(-[rR][0-9]+)?')
  fi
  if [[ "$own" =~ ^([A-Z][A-Z0-9]*)-[0-9]+$ ]] && [[ "$t" =~ Blocked-by\ \#([0-9]+)([^0-9A-Za-z]|$) ]]; then
    printf '%s-%s\tblocked\n' "${own%-*}" "${BASH_REMATCH[1]}"; return 0
  fi
  return 1
}

# defer_after_loop_n — DEFER_AFTER_LOOP_ALERT, validated (default 12, 0 = off).
defer_after_loop_n() {
  local v="${DEFER_AFTER_LOOP_ALERT:-12}"
  case "$v" in ''|*[!0-9]*) v=12 ;; esac
  printf '%s' "$v"
}

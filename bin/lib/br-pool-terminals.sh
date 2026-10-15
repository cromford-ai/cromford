#!/bin/bash
# shellcheck shell=bash
# bin/lib/br-pool-terminals.sh — the blocked-resolver's list of push-rejected
# pool terminals. Sourced by bin/blocked-resolver.sh, never run: no `set`, no
# `exit`, nothing runs at source time.
#
# A pool terminal (state/pool/<p>/<KEY>.terminal, bin/fly-pool.sh) is a build
# whose push was rejected and whose branch has not moved since. The pool does
# not start it again on its own. Until BH-6821 only fly-pool.log said so.
#
#   br_pool_terminal_pass [project]
#     Lists every terminal not yet told (one `say` line each; the told ones
#     are one count line) and posts ONE comment on the
#     ticket's GitHub issue naming the branch and the head. The comment needs a
#     numeric `ticket_id` in the file and an issues-lane project (fleet.conf
#     board_prefix "-"): an in-app board has no GitHub issue to comment on.
#     <KEY>.terminal-noted is touched only after the POST answered 2xx. It is
#     the sentinel fly-pool's pool_terminal_noted uses, so the ticket gets one
#     comment whichever lane posts first. At most BR_POOL_TERMINAL_MAX posts per
#     call (default 20); the rest wait for the next tick. OBSERVE=1 posts
#     nothing. Never fails its caller.
#
# Needs the caller's `say` and bin/lib/gh-rest.sh's gh_rest_comment. The root
# is ${HARNESS:-${H:-}} only; with none, nothing is listed.

br_pool_terminal_body() { # <branch> <sha> <since> -> the comment text
  printf 'The build pool stopped on this ticket.\n\n'
  printf 'The last build could not push to `%s`. The push was rejected at `%s` (%s), and the branch has not moved since. The pool does not start another build on its own.\n\n' "$1" "$2" "$3"
  # "If needed, comment RETRY" ON PURPOSE: fly-pool's POOL_REARM_NEG_RE reads
  # `if` near the word as a negation, so this comment never re-arms the terminal
  # it describes (the same wording pool_terminal_noted uses).
  printf 'If needed, comment `RETRY` on this ticket, or push to `%s`, and the next pool tick picks it up.\n' "$1"
}

br_pool_terminal_pass() {
  local only="${1:-}" root="${HARNESS:-${H:-}}" max="${BR_POOL_TERMINAL_MAX:-20}"
  local tf p key br sha since tid slug prefix f posts=0 left=0 told=0
  [ -n "$root" ] && [ -d "$root/state/pool" ] || return 0
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  for tf in "$root"/state/pool/*/*.terminal; do
    [ -f "$tf" ] || continue
    p=$(basename "$(dirname "$tf")"); key=$(basename "$tf" .terminal)
    [ -z "$only" ] || [ "$p" = "$only" ] || continue
    br=$(jq -r '.branch // empty' "$tf" 2>/dev/null)
    sha=$(jq -r '.head_sha // empty' "$tf" 2>/dev/null)
    since=$(jq -r '.created_at // empty' "$tf" 2>/dev/null)
    tid=$(jq -r '.ticket_id // empty' "$tf" 2>/dev/null)
    local line="$p/$key: push-rejected terminal on ${br:-?} at ${sha:-?} since ${since:-?}"
    # A told terminal is counted, not listed: nothing removes old .terminal
    # files, so one line each per tick would grow the log for ever.
    if [ -f "${tf%.terminal}.terminal-noted" ]; then told=$((told + 1)); continue; fi
    case "$tid" in ''|*[!0-9]*) say "$line — no ticket id on the terminal file — not commented"; continue ;; esac
    prefix=$("$root/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
    slug=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    if [ "$prefix" != "-" ]; then say "$line — board project, no GitHub issue — not commented"; continue; fi
    case "$slug" in */*) ;; *) say "$line — no repo for $p in fleet.conf — not commented"; continue ;; esac
    if [ "${OBSERVE:-0}" = 1 ]; then say "$line — observe mode, would comment on $slug#$tid"; continue; fi
    if [ "$posts" -ge "$max" ]; then left=$((left + 1)); say "$line"; continue; fi
    say "$line"
    posts=$((posts + 1))
    command -v br_use_token >/dev/null 2>&1 && br_use_token "$slug"
    f=$(mktemp "${TMPDIR:-/tmp}/br-pool-terminal.XXXXXX") || continue
    chmod 600 "$f" 2>/dev/null
    br_pool_terminal_body "${br:-?}" "${sha:-?}" "${since:-?}" > "$f"
    if command -v gh_rest_comment >/dev/null 2>&1 && gh_rest_comment "$slug" "$tid" "$f"; then
      : > "${tf%.terminal}.terminal-noted"
      say "$p/$key: told $slug#$tid about the push-rejected terminal on ${br:-?}"
    else
      say "$p/$key: the terminal comment on $slug#$tid was not posted (HTTP ${GH_REST_STATUS:-000}) — retried next tick"
    fi
    rm -f "$f"
  done
  [ "$left" -gt 0 ] && say "$left push-rejected terminal comment(s) left for the next tick (BR_POOL_TERMINAL_MAX=$max)"
  [ "$told" -gt 0 ] && say "$told push-rejected terminal(s) already told on their ticket"
  return 0
}

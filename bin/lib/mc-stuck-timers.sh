#!/bin/bash
# bin/lib/mc-stuck-timers.sh — timers on three stuck states of an open PR.
# Sourced by bin/merge-conductor.sh (every entry point) and by
# bin/blocked-resolver.sh (the red-checks reader only). Functions only: no
# side effect at source time.
#
#   A  CI NEVER STARTED. A head with no workflow run at all (`ci=none`, not a
#      cancelled-only head) for MC_CI_NOSTART_MIN minutes gets ONE
#      workflow_dispatch of a workflow that declares BOTH `pull_request` and
#      `workflow_dispatch` (never a deploy workflow), and ONE alert. Never an
#      empty commit, never a close/reopen from here.
#   B  A FAILED REBASE OR MAIN MERGE. mc_transition calls mst_fix_now_on_park
#      on a state change; a BLOCKED_HUMAN conflict-unresolvable* or
#      rebase-gate-red* park starts bin/blocked-resolver.sh for that PR at once
#      (BR_ONLY_PR), the launch shape of mc_eject_fix_now.
#   C  RED ON TWO CONSECUTIVE SETTLED HEADS. The tick records each head's
#      settled CI (`cihead`). A red head at rung 0 whose previous settled head
#      is red too skips the one-rerun rung: mc_classify answers RED_TWICE with
#      the failing check names, and B's hook starts the resolver.
#
# Every action is once per (PR, head) through an attempts mark written BEFORE
# the action. MC_STUCK_TIMERS (default 1) is the kill switch: at 0 every entry
# point returns at once and the conductor runs its old paths. Observe mode
# (ACTIONS!=1) logs one WOULD line and writes no action mark.
#
# Marks (state/merge-conductor/attempts.txt and its pr-rows twin):
#   cinone <key> <head> <epoch>   first tick the head read `ci=none` (the clock)
#   cinostart <key> <head>        the CI-never-started timer acted on this head
#   cihead <key> <head> <green|red>  a settled CI answer, one line per outcome
#   fixnow <key> <head> <rebase|red> the resolver was launched for this park
# File: state/merge-conductor/red-checks/<id>: line 1 the head, then one
# failing check name per line. Pruned after MC_RED_CHECKS_KEEP_D days.

# BH-8049: the dispatch skips a head a green or running PR run of the same
# workflow already covers (cds_check). Without the file the dispatch is as before.
if ! command -v cds_check >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/ci-dispatch-skip.sh" ]; then
  # shellcheck source=bin/lib/ci-dispatch-skip.sh
  . "${BASH_SOURCE[0]%/*}/ci-dispatch-skip.sh"
fi

# mst_on — rc 0 when the timers are on (MC_STUCK_TIMERS=1, the default).
mst_on() { [ "${MC_STUCK_TIMERS:-1}" = 1 ]; }

# mst_nostart_min <project> — MC_CI_NOSTART_MIN for the project (lane_knob:
# the project row, the global row, the env, the registry default). Not a
# whole number, or under 1: 15.
mst_nostart_min() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob merge-conductor MC_CI_NOSTART_MIN "${1:-}" 2>/dev/null | tr -d '[:space:]')
  else
    v="${MC_CI_NOSTART_MIN:-}"
  fi
  case "$v" in ''|*[!0-9]*) v=15 ;; esac
  [ "$((10#$v))" -ge 1 ] 2>/dev/null || v=15
  printf '%s\n' "$((10#$v))"
}

# mst_max_per_tick — MC_STUCK_TIMERS_MAX_PER_TICK, else 5.
mst_max_per_tick() {
  local v="${MC_STUCK_TIMERS_MAX_PER_TICK:-5}"
  case "$v" in ''|*[!0-9]*) v=5 ;; esac
  [ "$((10#$v))" -ge 1 ] 2>/dev/null || v=5
  printf '%s\n' "$((10#$v))"
}

# _mst_has <line> — rc 0 when the mark exists. The local file first: every
# mc_attempt_put writes it, and a hit there costs no pr-rows read. A miss asks
# mc_attempt_has (rows first), once, before the caller writes the mark.
_mst_has() {
  grep -qxF "$1" "${MC_ATTEMPTS:-/nonexistent}" 2>/dev/null && return 0
  mc_attempt_has "$1" 2>/dev/null
}

# _mst_wf_get <var> <path> — one REST read into <var>; rc as gh_rest.
#   Through a FILE, never `$(gh_rest …)` (the lib/mc/block-ci.sh idiom), so
#   GH_REST_STATUS / GH_REST_REASON stay in this shell for the caller's log.
_mst_wf_get() {
  local _mw_t _mw_r="" rc=0
  _mw_t=$(mktemp "${TMPDIR:-/tmp}/mc-mst.XXXXXX") || { printf -v "$1" '%s' ""; return 75; }
  gh_rest GET "$2" > "$_mw_t" || rc=$?
  _mw_r=$(cat "$_mw_t" 2>/dev/null)
  rm -f "$_mw_t"
  printf -v "$1" '%s' "$_mw_r"
  return "$rc"
}

# mst_pick_dispatch_wf <owner/repo> <branch> — the workflow to dispatch for a
#   run-less head. rc 0 prints its basename; rc 1 none qualifies; rc 75 the
#   workflow list could not be read.
#   A workflow qualifies when its file AT THE HEAD BRANCH declares both
#   `pull_request` (so it is the PR's CI) and `workflow_dispatch` (so it can be
#   dispatched). `ci.yml`/`ci.yaml` are read first. At most 5 file reads.
mst_pick_dispatch_wf() {
  local slug="$1" br="$2" j="" paths p c brq reads=0 rc=0
  _mst_wf_get j "repos/$slug/actions/workflows?per_page=100" || return 75
  paths=$(jq -r '(.workflows // [])[] | select((.state // "active") == "active") | .path // empty' <<<"$j" 2>/dev/null) || return 75
  [ -n "$paths" ] || return 1
  paths=$( { grep -E '/ci\.ya?ml$' <<<"$paths"; grep -vE '/ci\.ya?ml$' <<<"$paths"; } )
  brq=$(jq -rn --arg b "$br" '$b|@uri')
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$reads" -lt 5 ] || break
    reads=$((reads+1)); rc=0
    _mst_wf_get j "repos/$slug/contents/$p?ref=$brq" || rc=$?
    [ "$rc" = 0 ] || continue
    c=$(jq -r '.content // empty' <<<"$j" 2>/dev/null | base64 -d 2>/dev/null | sed 's/#.*//')
    grep -Eq '(^|[^A-Za-z0-9_])pull_request([^A-Za-z0-9_]|$)' <<<"$c" || continue
    grep -Eq '(^|[^A-Za-z0-9_])workflow_dispatch([^A-Za-z0-9_]|$)' <<<"$c" || continue
    printf '%s' "${p##*/}"; return 0
  done <<<"$paths"
  return 1
}

# mst_ci_nostart <project> <key> <owner/repo> <num> <url> <head> <ci> <flake>
#                <mergeState> <mergeable> <baseRef> <projectBase> <reason> <branch>
#   The CI-never-started timer. Called by pr_worker on every open PR it ticks,
#   in every state, just before the WAIT_CI catch-all. Always rc 0.
mst_ci_nostart() {
  local p="$1" key="$2" slug="$3" num="$4" url="$5" head="$6" ci="$7" flake="$8"
  local ms="$9" mg="${10}" bref="${11}" pbase="${12}" why="${13}" br="${14:-}"
  local first age min wf rc did
  mst_on || return 0
  [ -n "$key" ] && [ -n "$head" ] && [ -n "$br" ] || return 0
  # A head with a run (pending, green, red), or whose runs were all cancelled
  # (the flake ladder's), is not run-less.
  [ "$ci" = none ] && [ -z "$flake" ] || return 0
  # GitHub runs nothing on a tree it cannot merge: the rebase owns it.
  [ "$ms" != DIRTY ] && [ "$mg" != CONFLICTING ] || return 0
  # A push permission is not something a CI run can add (BH-800).
  [ "${MC_IDENTITY_BLOCKED:-0}" != 1 ] || return 0
  mc_identity_blocked "$why" && return 0
  # A stacked child is not on the project base; its block owns it.
  [ -n "$pbase" ] && [ "$bref" = "$pbase" ] || return 0
  # The clock is read from the local file only, so a run-less head costs no
  # read per tick.
  first=$(awk -v k="$key" -v h="$head" '$1=="cinone" && $2==k && $3==h {print $4; exit}' "${MC_ATTEMPTS:-/nonexistent}" 2>/dev/null)
  case "$first" in
    ''|*[!0-9]*)
      # THE CLOCK STARTS AT FIRST SIGHT, so the first tick after a deploy
      # alerts on nothing. Bookkeeping, not an action: written in every mode.
      mc_attempt_put "cinone $key $head $(mc_now)"
      return 0 ;;
  esac
  # bin/merge-conductor.sh reads the window once per project (MST_NOSTART_MIN).
  min="${MST_NOSTART_MIN:-}"
  case "$min" in ''|*[!0-9]*) min=$(mst_nostart_min "$p") ;; esac
  age=$(( $(mc_now) - first ))
  [ "$age" -ge $((min * 60)) ] || return 0
  _mst_has "cinostart $key $head" && return 0
  mc_hold_keeps_pr "$slug" "$num" && return 0
  if ! mc_tick_budget_take "$p" stucktimer "$(mst_max_per_tick)"; then
    mc_log "$key CI never started on ${head:0:8} ($((age/60))m) — this tick's stuck-timer budget ($(mst_max_per_tick)) is spent; the next tick acts"
    return 0
  fi
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_tick_budget_give "$p" stucktimer
    mc_log "$key would dispatch CI once on ${head:0:8} and alert CI_NEVER_STARTED — no workflow run for $((age/60))m (observe mode: nothing written)"
    return 0
  fi
  mc_attempt_put "cinostart $key $head"
  if _mst_has "cikick $key $head"; then
    did="already kicked by close/reopen on this head, so nothing more was re-triggered"
  else
    rc=0; wf=$(mst_pick_dispatch_wf "$slug" "$br") || rc=$?
    case "$rc" in
      0)
        rc=0; mc_head_still "$slug" "$key" "$head" "CI dispatch" || rc=$?
        case "$rc" in
          0)
            # BH-8049: the `ci=none` read can be a memo. A green or running
            # pull_request/merge_group run of $wf on this head means CI did
            # start: no dispatch, no cikick and no CI_NEVER_STARTED alert. The
            # cinostart mark above stops a second look at this head.
            local cds="" crc=1
            if declare -F cds_check >/dev/null; then
              crc=0; cds=$(cds_check "$slug" "$head" "$wf") || crc=$?
              [ -n "$cds" ] && mc_log "$key $cds"
              [ "$crc" = 0 ] && return 0
            fi
            if gh_rest POST "repos/$slug/actions/workflows/$wf/dispatches" -f "ref=$br" >/dev/null; then
              mc_attempt_put "cikick $key $head"
              did="dispatched $wf on $br"
            else
              did="the dispatch of $wf on $br FAILED (HTTP ${GH_REST_STATUS:-000}), so nothing was re-triggered"
            fi ;;
          1) mc_log "$key CI never started on ${head:0:8}, but the PR has moved on — no dispatch, no alert"; return 0 ;;
          *) did="the PR head could not be read before the dispatch, so nothing was re-triggered" ;;
        esac ;;
      1) did="no workflow declares pull_request + workflow_dispatch, so nothing was re-triggered" ;;
      *) did="the workflow list could not be read (HTTP ${GH_REST_STATUS:-000}), so nothing was re-triggered" ;;
    esac
  fi
  # cikickalert keeps ci_absent_escalate quiet on this head: this is its alert.
  _mst_has "cikickalert $key $head" || mc_attempt_put "cikickalert $key $head"
  mc_alert "$key" CI_NEVER_STARTED "no workflow run on ${head:0:8} after $((age/60))m; $did: $url"
  mc_log "$key CI_NEVER_STARTED $key $head after $((age/60))m — $did; alerted once"
  return 0
}

# mst_cihead_put <key> <head> <green|red> — one line per (head, outcome). A
#   red head whose rerun went green gets a second, green, line; the newest
#   line of a head is its answer. Always rc 0.
mst_cihead_put() {
  local key="$1" head="$2" ci="$3"
  mst_on || return 0
  case "$ci" in green|red) ;; *) return 0 ;; esac
  [ -n "$key" ] && [ -n "$head" ] || return 0
  _mst_has "cihead $key $head $ci" && return 0
  mc_attempt_put "cihead $key $head $ci"
  return 0
}

# mst_red_consecutive <key> <head> — rc 0 and prints the previous settled
#   head when that head's newest answer is red. rc 1 otherwise (no previous
#   head, green, or the attempts file could not be read).
mst_red_consecutive() {
  local key="$1" head="$2" line
  mst_on || return 1
  [ -r "${MC_ATTEMPTS:-}" ] || return 1
  line=$(awk -v k="$key" -v h="$head" '$1=="cihead" && $2==k && $3!=h {last=$3" "$4} END {if (last!="") print last}' "$MC_ATTEMPTS" 2>/dev/null) || return 1
  [ "${line#* }" = red ] || return 1
  printf '%s\n' "${line%% *}"
}

mst_red_checks_file() { printf '%s/red-checks/%s' "$MC_STATE_DIR" "$(mc_handoff_id "$1")"; }

# mst_red_checks_put <owner/repo> <key> <head> — ONE check-runs read; writes
#   the red-checks file and prints the names comma-joined (`unread` when the
#   read failed, `none named` when it named no failed check). At most 10.
mst_red_checks_put() {
  local slug="$1" key="$2" head="$3" j="" rc=0 names f
  _mst_wf_get j "repos/$slug/commits/$head/check-runs?filter=latest&per_page=100" || rc=$?
  if [ "$rc" = 0 ]; then
    names=$(jq -r '[(.check_runs // [])[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure") | .name] | unique | .[:10][]' <<<"$j" 2>/dev/null) || names=unread
    [ -n "$names" ] || names="none named"
  else
    names=unread
  fi
  f=$(mst_red_checks_file "$key")
  mkdir -p "${f%/*}" 2>/dev/null
  { printf '%s\n' "$head"; printf '%s\n' "$names"; } > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  paste -sd, <<<"$names" | sed 's/,/, /g'
}

# mst_red_checks_read <key> <head> — the names, one a line, when the file is
#   for this head. rc 1 when there is none for it.
mst_red_checks_read() {
  local f fh out
  [ -n "${1:-}" ] && [ "${#2}" -ge 7 ] || return 1
  command -v mc_handoff_id >/dev/null 2>&1 && [ -n "${MC_STATE_DIR:-}" ] || return 1
  f=$(mst_red_checks_file "$1")
  [ -s "$f" ] || return 1
  { IFS= read -r fh < "$f"; } 2>/dev/null
  [ "${#fh}" -ge 7 ] || return 1
  case "$fh" in "$2"*) ;; *) case "$2" in "$fh"*) ;; *) return 1 ;; esac ;; esac
  out=$(tail -n +2 "$f" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# mst_red_brief <key> <head> — the fix-round brief paragraph (blank lines
#   first) naming the checks that failed on <head>, when the conductor found it
#   red after red (mst_red_consec) and handed the PR over. Prints nothing, rc 0,
#   when there is no red-checks file for this head. Moved out of
#   bin/blocked-resolver.sh's br_fix_round to keep the driver under its
#   split-layout ceiling (tests/br/driver-ceiling.tsv).
mst_red_brief() {
  local names
  names=$(mst_red_checks_read "$1" "$2") || return 0
  printf '\n\n%s\n%s' "RED ON THIS HEAD AND ON THE HEAD BEFORE IT. THE CHECKS THAT FAILED ON THIS HEAD:" "$names"
}

_mst_consec_word() { # <prev> <head> <names-csv> — the MC_RED_CONSEC value
  printf '%s %s|%s' "${1:0:8}" "${2:0:8}" "$3"
}

# mst_red_known <key> <head> — the MC_RED_CONSEC value of a head an earlier
#   tick already found red after red (its red-checks file is for this head),
#   so a later tick reads no check-runs and buys no flake rerun. Empty when not.
mst_red_known() {
  local key="$1" head="$2" prev names
  mst_on || return 0
  names=$(mst_red_checks_read "$key" "$head") || return 0
  prev=$(mst_red_consecutive "$key" "$head") || return 0
  _mst_consec_word "$prev" "$head" "$(paste -sd, <<<"$names" | sed 's/,/, /g')"
}

# mst_red_consec <owner/repo> <key> <head> — when the previous settled head is
#   red too: reads the failing checks once, writes the red-checks file, and
#   prints the MC_RED_CONSEC value mc_classify reads. Empty when not.
mst_red_consec() {
  local slug="$1" key="$2" head="$3" prev names
  mst_on || return 0
  prev=$(mst_red_consecutive "$key" "$head") || return 0
  names=$(mst_red_checks_put "$slug" "$key" "$head")
  mc_log "$key red on ${head:0:8} after red on ${prev:0:8} — no rerun rung: RED_TWICE now, failing checks: $names"
  _mst_consec_word "$prev" "$head" "$names"
}

# mst_fix_now <project> <key> <head> <url> <rebase|red> — start
#   bin/blocked-resolver.sh for this one PR now. Once per (PR, head, kind): the
#   mark is written BEFORE the launch. The launch is detached and reports
#   nothing back, so the line says "launch requested"; the resolver's own
#   `one-PR run for <key>` line is the proof that it ran. Always rc 0.
mst_fix_now() {
  local p="$1" key="$2" head="$3" url="$4" kind="$5"
  mst_on || return 0
  [ -n "$key" ] && [ -n "$head" ] || return 0
  _mst_has "fixnow $key $head $kind" && return 0
  if [ -z "$p" ]; then
    mc_log "$key $kind park on ${head:0:8}: no project in this process, so no same-tick resolver launch; the resolver's next tick takes it"
    return 0
  fi
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_log "$key would start bin/blocked-resolver.sh $p for this PR now ($kind park on ${head:0:8}; observe mode: nothing written)"
    return 0
  fi
  mc_attempt_put "fixnow $key $head $kind"
  ( BR_ONLY_PR="$key" setsid "$MC_H/bin/blocked-resolver.sh" "$p" </dev/null >>"$MC_H/logs/blocked-resolver-cron.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) 2>/dev/null
  mc_log "$key $kind — bin/blocked-resolver.sh launch requested for this PR now (BR_ONLY_PR): $url"
  return 0
}

# mst_fix_now_on_park <key> <new-state> <reason> <head> <url> — mc_transition
#   calls this after a state CHANGE. Only the conductor sets MC_FIX_NOW_ON
#   (not exported), and a one-PR resolver run has BR_ONLY_PR set, so a resolver
#   that calls mc_transition never launches another resolver.
mst_fix_now_on_park() {
  local kind
  [ "${MC_FIX_NOW_ON:-0}" = 1 ] && [ -z "${BR_ONLY_PR:-}" ] || return 0
  mst_on || return 0
  case "${2:-}:${3:-}" in
    BLOCKED_HUMAN:conflict-unresolvable*|BLOCKED_HUMAN:rebase-gate-red*) kind=rebase ;;
    RED_TWICE:red-twice*) kind=red ;;
    *) return 0 ;;
  esac
  mst_fix_now "${P:-}" "$1" "$4" "$5" "$kind"
}

# mst_prune — delete red-checks files older than MC_RED_CHECKS_KEEP_D days
#   (default 14), at most once an hour per box (a stamp file). Always rc 0.
mst_prune() {
  local d keep stamp
  mst_on || return 0
  [ -n "${MC_STATE_DIR:-}" ] || return 0
  d="$MC_STATE_DIR/red-checks"; [ -d "$d" ] || return 0
  stamp="$d/.pruned"
  [ -n "$(find "$stamp" -mmin -60 2>/dev/null)" ] && return 0
  : > "$stamp" 2>/dev/null
  keep="${MC_RED_CHECKS_KEEP_D:-14}"
  case "$keep" in ''|*[!0-9]*) keep=14 ;; esac
  [ "$((10#$keep))" -ge 1 ] 2>/dev/null || keep=14
  find "$d" -maxdepth 1 -type f ! -name .pruned -mtime +"$((10#$keep))" -delete 2>/dev/null
  return 0
}

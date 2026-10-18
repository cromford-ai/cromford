#!/bin/bash
# shellcheck shell=bash
# bin/lib/sched-gate.sh — the one reader of the scheduler's ready set and the
# one place the enforce rule lives (BH-6979, wave 3 of #6547). Sourced, never
# executed: no `set -e`, no `exit`, nothing runs at source time but function
# definitions. Contract: docs/notes/2026-10-17-BH-6979-scheduler-enforce.md.
#
# Callers: bin/lib/rb/gates.sh (`# >>> scheduler enforce gate (BH-6979)` and
# the `# >>> stacked child builds` arm), bin/fly-pool.sh (pool_spawn_decision
# gate 0c), bin/lib/rt/scope.sh (`# >>> overlap schedule feed`; it also hands
# the section to triage shards through SHARD_SOP) and bin/overlap-schedule.sh
# (`--key` answers nothing in enforce with a usable set). bin/lib/rt/shards.sh
# is not edited (BH-3418 B1).
#
# sched_enforced <project>
#   rc 0 when the settings row scheduler.mode is exactly `enforce` (white space
#   trimmed) AND <project> is a word of scheduler.projects (default
#   cromford). No row, an outage or any other value is rc 1: today's path.
#
# sched_gate <project> <KEY>
#   Prints one line, sets SCHED_LINE (that line), SCHED_AT (the tick or empty)
#   and SCHED_REASON, and returns:
#     rc 0  SCHED_READY <KEY> (tick <at>)                 verdict yes
#     rc 3  SCHED_WAIT <KEY> reason=<reason> (tick <at>)  verdict no or unknown,
#                                                         or absent from the set
#                                                         (reason `not in ready set`)
#     rc 2  SCHED_PASS <KEY> <why>                        today's path: not
#           enforced, a key that is not <PFX>-<n>, verdict in-flight, or the
#           set is not usable (`ready set <state>`). A set that is not usable
#           also writes ONE warn ALERTS line per project per UTC day.
#   The set is usable when GET /api/scheduler/ready answers ok:true for a tick
#   posted in mode enforce, no older than scheduler.ready_max_age_s (900), with
#   complete:true. Else the state is one of unreadable | no-tick | shadow-tick
#   | stale | incomplete.
#
# sched_scope_section <project>
#   Sets SCHED_TEXT (and prints it) to the triage prompt section SCHEDULER
#   READY SET when the set is usable under enforce; rc 1 and empty otherwise,
#   and the caller keeps today's OVERLAP SCHEDULE section.
#
# Call these in the caller's own shell, never inside $( ): the read is memoized
# in shell variables (one GET per project per 60 s, so a long pool tick still
# reads a fresh set), and a $( ) subshell would drop the memo and the SCHED_*
# results.
#
# Test seam: SCHED_NOW (epoch seconds used instead of the clock; only all-digit
# values are used), the same seam bin/scheduler.sh reads.

# The harness root (BH-2613: no literal fallback). Every caller sets HARNESS;
# with no root the lib reads nothing and writes nothing, and every gate answers
# its "not enforced" or "unreadable" path.
_sched_h() { printf '%s' "${HARNESS:-${H:-}}"; }

_sched_now() {
  if [[ "${SCHED_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$SCHED_NOW"; else date -u +%s; fi
}

# _sched_var <prefix> <project> — a shell variable name for a per-project memo.
_sched_var() { printf '%s_%s' "$1" "${2//[^A-Za-z0-9_]/_}"; }

# _sched_fresh <prefix> <project> — rc 0 when that memo was set less than
# 60 s ago.
_sched_fresh() {
  local t; t=$(_sched_var "$1_T" "$2")
  [ -n "${!t:-}" ] || return 1
  [ $((SECONDS - ${!t})) -lt 60 ]
}

_sched_client() {
  command -v setting_get >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 && return 0
  local root; root=$(_sched_h)
  [ -n "$root" ] || return 1
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" 2>/dev/null
  command -v setting_get >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1
}

sched_enforced() {
  local p="${1:-}" v rc mv projects
  [ -n "$p" ] || return 1
  mv=$(_sched_var _SCHED_MODE "$p")
  if ! _sched_fresh _SCHED_MODE "$p"; then
    v=0
    if _sched_client; then
      local mode; mode=$(setting_get scheduler.mode 2>/dev/null | tr -d '[:space:]')
      if [ "$mode" = enforce ]; then
        projects=$(setting_get scheduler.projects 2>/dev/null); rc=$?
        [ "$rc" = 0 ] && [ -n "${projects// /}" ] || projects=cromford
        [[ " $(tr -s '[:space:],' ' ' <<<"$projects") " == *" $p "* ]] && v=1
      fi
    fi
    printf -v "$mv" '%s' "$v"
    printf -v "$(_sched_var _SCHED_MODE_T "$p")" '%s' "$SECONDS"
  fi
  [ "${!mv}" = 1 ]
}

# sched_ready_load <project> — the newest set into the memo; sets _SCHED_STATE.
sched_ready_load() {
  local p="${1:-}" jv body st at at_s max now complete
  jv=$(_sched_var _SCHED_JSON "$p")
  if ! _sched_fresh _SCHED_JSON "$p"; then
    body=""
    _sched_client && body=$(_jobs_req GET "/api/scheduler/ready?project=$p" 2>/dev/null) || body=""
    jq -e '.ok == true' <<<"$body" >/dev/null 2>&1 || body=""
    printf -v "$jv" '%s' "$body"
    printf -v "$(_sched_var _SCHED_JSON_T "$p")" '%s' "$SECONDS"
  fi
  body=${!jv}
  SCHED_AT=""
  if [ -z "$body" ]; then _SCHED_STATE=unreadable; return 1; fi
  # `|`, not a tab: read collapses a leading empty field of a white-space IFS.
  IFS='|' read -r at st complete < <(jq -r '"\(.at // "")|\(.mode // "")|\(.complete == true)"' <<<"$body")
  SCHED_AT=$at
  if [ -z "$at" ]; then _SCHED_STATE=no-tick; return 1; fi
  if [ "$st" != enforce ]; then _SCHED_STATE=shadow-tick; return 1; fi
  max=$(setting_get scheduler.ready_max_age_s 2>/dev/null | tr -d '[:space:]')
  [[ $max =~ ^[0-9]+$ ]] || max=900
  now=$(_sched_now)
  [ -n "$at" ] && at_s=$(date -u -d "$at" +%s 2>/dev/null) || { _SCHED_STATE=unreadable; return 1; }
  if [ $((now - at_s)) -gt "$max" ]; then _SCHED_STATE=stale; return 1; fi
  if [ "$complete" != true ]; then _SCHED_STATE=incomplete; return 1; fi
  _SCHED_STATE=ok
}

# _sched_alert_once <project> — one warn ALERTS line per project per UTC day.
# The day flag goes through bin/lib/flags.sh (flag_has --cached / flag_set; the
# file alerted-sched-fallback-<project>-<YYYYMMDD> under the box's flags), set
# before the line. If the flag library cannot load or the flag cannot be set,
# the line still goes out.
_sched_alert_once() {
  local p="$1" h name text
  h=$(_sched_h)
  [ -n "$h" ] || return 0
  name="alerted-sched-fallback-$p-$(date -u -d "@$(_sched_now)" +%Y%m%d)"
  # shellcheck source=bin/lib/flags.sh
  command -v flag_set >/dev/null 2>&1 || . "$h/bin/lib/flags.sh" 2>/dev/null
  if command -v flag_has >/dev/null 2>&1; then
    flag_has --cached "$name" 2>/dev/null && return 0
    flag_set "$name" on "sched-gate: fallback alert sent" >/dev/null 2>&1
  fi
  text="[$p] scheduler.mode=enforce but the ready set is $_SCHED_STATE — dispatch fell back to sibling-serial/overlap-schedule/stack-wait; check bin/scheduler.sh (logs/scheduler.log)"
  if [ -x "$h/bin/alert-line.sh" ]; then
    "$h/bin/alert-line.sh" --severity warn --id "sched-fallback-$p" --project "$p" "$text" >/dev/null 2>&1
  else
    printf '%s\n' "sched-gate: no bin/alert-line.sh; not sent: $text" >&2
  fi
  return 0
}

# _sched_pfx <project> <KEY> — the board key prefix of <project>.
_sched_pfx() {
  local pfx="" root
  root=$(_sched_h)
  [ -n "$root" ] || { printf '%s' "${2%%-*}"; return 0; }
  command -v preplan_key_prefix >/dev/null 2>&1 && pfx=$(preplan_key_prefix "$root" "$1" 2>/dev/null)
  [ -n "$pfx" ] || pfx=$(grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$root/prompts/$1.md" 2>/dev/null | head -1 | cut -d- -f1)
  [ -n "$pfx" ] || pfx=${2%%-*}
  printf '%s' "$pfx"
}

sched_gate() {
  local p="${1:-}" k="${2:-}" pfx n v ready reason rc
  SCHED_LINE=""; SCHED_AT=""; SCHED_REASON=""
  if ! sched_enforced "$p"; then
    SCHED_LINE="SCHED_PASS $k not enforced"; printf '%s\n' "$SCHED_LINE"; return 2
  fi
  pfx=$(_sched_pfx "$p" "$k")
  if ! [[ $k =~ ^${pfx}-([1-9][0-9]{0,8})$ ]]; then
    SCHED_LINE="SCHED_PASS $k key not $pfx-<n>"; printf '%s\n' "$SCHED_LINE"; return 2
  fi
  n=${BASH_REMATCH[1]}
  if ! sched_ready_load "$p"; then
    _sched_alert_once "$p"
    SCHED_LINE="SCHED_PASS $k ready set $_SCHED_STATE"; printf '%s\n' "$SCHED_LINE"; return 2
  fi
  local jv; jv=$(_sched_var _SCHED_JSON "$p")
  v=$(jq -r --arg n "$n" 'first(.verdicts[]? | select(.ticket == $n) | "\(.ready)\t\(.reason)") // ""' <<<"${!jv}")
  IFS=$'\t' read -r ready reason <<<"$v"
  case "$ready" in
    yes) SCHED_LINE="SCHED_READY $k (tick $SCHED_AT)"; rc=0 ;;
    no|unknown) SCHED_REASON=$reason; SCHED_LINE="SCHED_WAIT $k reason=$reason (tick $SCHED_AT)"; rc=3 ;;
    in-flight) SCHED_LINE="SCHED_PASS $k verdict in-flight (tick $SCHED_AT)"; rc=2 ;;
    "") SCHED_REASON="not in ready set"; SCHED_LINE="SCHED_WAIT $k reason=not in ready set (tick $SCHED_AT)"; rc=3 ;;
    *) SCHED_LINE="SCHED_PASS $k verdict $ready not known (tick $SCHED_AT)"; rc=2 ;;
  esac
  printf '%s\n' "$SCHED_LINE"
  return "$rc"
}

sched_scope_section() {
  local p="${1:-}" pfx jv ready waiting
  SCHED_TEXT=""
  sched_enforced "$p" || return 1
  if ! sched_ready_load "$p"; then _sched_alert_once "$p"; return 1; fi
  pfx=$(_sched_pfx "$p" "")
  jv=$(_sched_var _SCHED_JSON "$p")
  ready=$(jq -r --arg x "$pfx-" '[.verdicts[]? | select(.ready == "yes") | $x + .ticket] | join(" ")' <<<"${!jv}")
  waiting=$(jq -r --arg x "$pfx-" '.verdicts[]? | select(.ready == "no" or .ready == "unknown") | "\($x + .ticket) — \(.reason)"' <<<"${!jv}")
  SCHED_TEXT="SCHEDULER READY SET (enforce, tick $SCHED_AT)
Computed by bin/scheduler.sh; the settings row scheduler.mode is enforce.
READY: ${ready:-(none)}
WAITING:
${waiting:-(none)}

Launch rule: the scheduler owns the launch order this tick. Launch only READY keys, each per its own gating conditions in the SOP. Do NOT launch a WAITING key: leave its queue line where it is and say \`skip :: scheduler: <its reason>\` in your output. bin/run-build.sh refuses it anyway (BUILD_DEFERRED), and the next tick re-offers it. A key in neither list is in flight, is not a $pfx-<n> key, or arrived after this tick: bin/run-build.sh decides it at launch. Do not pass STACK_BASE: in enforce every build is cut from the default branch. There is no overlap wave order this tick."
  printf '%s\n' "$SCHED_TEXT"
}

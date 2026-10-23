#!/bin/bash
# shellcheck shell=bash
# bin/lib/dispatch-mode.sh — the per-project dispatch mode: normal, hotfix-only
# or paused. Sourced, never run, never exits.
#
# THE ROW. `dispatch-mode-<project>`, scope fleet, is a harness_flags row
# (FLAG_PORTED_RE in bin/lib/jobs/flags.sh), so it is read DB-first by flag_has,
# from the last-good cache state/flags-cache/fleet/dispatch-mode-<p> when the
# worker does not answer, and from the file flags/dispatch-mode-<p> (its content
# is the value) on a box with no worker. Its value:
#
#   hotfix-only                   only hotfix-labelled tickets launch
#   hotfix-only:<n>[,<n>...]      the same, plus these issue numbers
#   normal                        normal
#
# Row cleared or absent: normal. Row ON with no value: hotfix-only with no
# allow-list. Row ON with a value that does not parse: hotfix-only with an EMPTY
# allow-list and DM_BAD=1, the stricter of the two build modes, because the
# operator turned the row on to restrict.
#
# PAUSED IS NOT A SECOND STORE. It is the existing paused-<p> row (BH-4153),
# read the way the fastpath and triage read it (flag_active, which fails closed;
# the file with no client). Every current pause reader keeps deciding the pause;
# this lib only reports it. Precedence: paused > hotfix-only > normal.
#
# THE CODE FALLBACK IS normal: a row that cannot be read with no cache is
# normal (DM_SRC=default). The age alert line is the knob DISPATCH_MODE_ALERT_H
# (catalog/lanes.d/_lib.dispatch-mode.json, settings row
# lib.dispatch-mode.dispatch_mode_alert_h), code fallback 24 h.
#
#   dm_read <project>          sets DM_MODE DM_ALLOW DM_SET_AT DM_SRC DM_BAD DM_VALUE
#                              DM_UNREADABLE (1: row unreadable, no cache -> normal); rc 0
#   dm_parse <value>           sets DM_MODE DM_ALLOW DM_BAD from one value; rc 0
#   dm_allow_has <n>           rc 0 when n is on DM_ALLOW (whole-number match)
#   dm_admit_ticket <n> <hf>   hf 1 hotfix, 0 not, 2 unknown; rc 0 admit, 1 hold
#   dm_meta_admit <n> <meta>   a build_queue row's meta JSON; rc 0 admit, 1 hold
#   dm_job_admit <job.json>    a pool queue file; rc 0 admit, 1 hold
#   dm_since_s <project>       epoch hotfix-only began (state/dispatch-mode/<p>.since)
#   dm_age_alert <project>     one lane-alert page past the knob; resolve on leave
#   dm_allow_text              DM_ALLOW as "n,n", or "none"
#
# In normal and paused every dm_*_admit admits: the pause is decided by the
# existing gates, never here.

_dm_h() { printf '%s' "${HARNESS:-${H:-}}"; }

dm_parse() {
  local v="${1:-}" lv rest n out=""
  DM_MODE=hotfix-only; DM_ALLOW=""; DM_BAD=0
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  lv=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$lv" in
    "") return 0 ;;
    normal) DM_MODE=normal; return 0 ;;
    hotfix-only) return 0 ;;
    hotfix-only:*)
      rest="${lv#hotfix-only:}"
      if [[ "$rest" =~ ^[[:space:]]*[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*[[:space:]]*$ ]]; then
        for n in ${rest//,/ }; do
          n=$(printf '%s' "$n" | sed 's/^0*//')
          [ -n "$n" ] || { DM_BAD=1; DM_ALLOW=""; return 0; }
          case " $out " in *" $n "*) ;; *) out="${out:+$out }$n" ;; esac
        done
        DM_ALLOW="$out"
        return 0
      fi
      DM_BAD=1; return 0 ;;
    *) DM_BAD=1; return 0 ;;
  esac
}

dm_read() {
  local p="${1:-}" h rc cur v=""
  h=$(_dm_h)
  DM_MODE=normal; DM_ALLOW=""; DM_SET_AT=""; DM_SRC=default; DM_BAD=0; DM_VALUE=""; DM_UNREADABLE=0
  [ -n "$p" ] && [ -n "$h" ] || return 0
  if command -v flag_active >/dev/null 2>&1; then
    if flag_active "paused-$p" >/dev/null 2>&1; then DM_MODE=paused; DM_SRC=paused; return 0; fi
  elif [ -f "$h/flags/paused-$p" ]; then
    DM_MODE=paused; DM_SRC=paused; return 0
  fi
  if command -v flag_has >/dev/null 2>&1; then
    rc=0; flag_has "dispatch-mode-$p" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) DM_SRC="${FLAG_SRC:-db}"
         if [ "$DM_SRC" = file ]; then
           v=$(head -c 512 "$h/flags/dispatch-mode-$p" 2>/dev/null | head -1)
         elif command -v _flag_cache_read >/dev/null 2>&1; then
           cur=$(_flag_cache_read fleet "dispatch-mode-$p" 2>/dev/null)
           v=$(jq -r '.value // ""' <<<"$cur" 2>/dev/null)
           DM_SET_AT=$(jq -r '.set_at // ""' <<<"$cur" 2>/dev/null)
         fi ;;
      1) DM_SRC="${FLAG_SRC:-db}"; return 0 ;;
      *) DM_SRC=default; DM_UNREADABLE=1; return 0 ;;
    esac
  elif [ -f "$h/flags/dispatch-mode-$p" ]; then
    DM_SRC=file
    v=$(head -c 512 "$h/flags/dispatch-mode-$p" 2>/dev/null | head -1)
  else
    DM_SRC=default; return 0
  fi
  DM_VALUE="$v"
  dm_parse "$v"
  return 0
}

dm_allow_has() {
  local n="${1:-}"
  n=$(printf '%s' "$n" | sed 's/^0*//')
  [ -n "$n" ] || return 1
  case " ${DM_ALLOW:-} " in *" $n "*) return 0 ;; esac
  return 1
}

dm_allow_text() { if [ -n "${DM_ALLOW:-}" ]; then printf '%s' "${DM_ALLOW// /,}"; else printf none; fi; }

dm_admit_ticket() {
  [ "${DM_MODE:-normal}" = hotfix-only ] || return 0
  case "${2:-0}" in 1|2) return 0 ;; esac
  dm_allow_has "${1:-}"
}

# dm_meta_admit — the build_queue row form of dm_job_admit (fly-dispatch's
# rows pick reads rows, not files). The meta carries hotfix, the rebase object
# (kind rebase), blocked_resolver and deaths the same way the file does.
dm_meta_admit() {
  local t="${1:-}" meta="${2:-}" hf_on=1 a
  [ "${DM_MODE:-normal}" = hotfix-only ] || return 0
  command -v hotfix_lane_on >/dev/null 2>&1 && hf_on=$(hotfix_lane_on "$(_dm_h)")
  a=$(printf '%s' "${meta:-}" | jq -r --arg hf "$hf_on" 'if type != "object" then "no"
      elif ($hf == "1" and .hotfix == true) then "yes"
      elif (.kind // "") == "rebase" or ((.rebase // null) | type) == "object" then "yes"
      elif ((.blocked_resolver // "") | tostring) as $b | ($b != "" and $b != "false") then "yes"
      elif ((.deaths // 0) | tonumber? // 0) > 0 then "yes"
      else "no" end' 2>/dev/null)
  [ "$a" = yes ] && return 0
  dm_allow_has "$t"
}

# dm_job_admit — a queued pool job. Admitted: a hotfix, a conductor rebase job,
# a lead-review job (BH-8027: it unblocks a merge, it is no ticket build),
# a blocked-resolver rebuild (rebuild:true), a death requeue (deaths > 0), or an
# allow-listed ticket_id. These were admitted once already, or are not a new
# ticket build at all.
dm_job_admit() {
  local f="${1:-}" a t
  [ "${DM_MODE:-normal}" = hotfix-only ] || return 0
  [ -s "$f" ] || return 0
  if command -v hotfix_job_is >/dev/null 2>&1; then
    hotfix_job_is "$f" "$(_dm_h)" && return 0
  else
    jq -e '.hotfix == true' "$f" >/dev/null 2>&1 && return 0
  fi
  a=$(jq -r 'if ((.rebase // null) | type) == "object" then "yes"
      elif ((.leadreview // null) | type) == "object" then "yes"
      elif ((.console_preview // null) | type) == "object" then "yes"
      elif .rebuild == true then "yes"
      elif ((.deaths // 0) | tonumber? // 0) > 0 then "yes"
      else "no" end' "$f" 2>/dev/null)
  [ "$a" = yes ] && return 0
  t=$(jq -r '.ticket_id // ""' "$f" 2>/dev/null)
  dm_allow_has "$t"
}

_dm_now() { if [ -n "${DM_NOW:-}" ]; then printf '%s' "$DM_NOW"; else date -u +%s; fi; }

# dm_since_s <project> — the epoch hotfix-only began. Each ON write sets the
# row's set_at again, so an allow-list edit would restart a set_at clock; the
# state file keeps the first tick that read hotfix-only instead. Seeded from the
# row's set_at when absent, else now. Call it only while DM_MODE is hotfix-only.
dm_since_s() {
  local p="${1:-}" h f s=""
  h=$(_dm_h); [ -n "$h" ] && [ -n "$p" ] || { _dm_now; return 0; }
  f="$h/state/dispatch-mode/$p.since"
  s=$(head -1 "$f" 2>/dev/null)
  case "$s" in ''|*[!0-9]*) s="" ;; esac
  if [ -z "$s" ]; then
    [ -n "${DM_SET_AT:-}" ] && s=$(date -u -d "$DM_SET_AT" +%s 2>/dev/null) # determinism: ok — DM_SET_AT is the row's own set_at, checked non-empty first
    case "$s" in ''|*[!0-9]*) s=$(_dm_now) ;; esac
    mkdir -p "${f%/*}" 2>/dev/null && printf '%s\n' "$s" > "$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f" 2>/dev/null
  fi
  printf '%s' "$s"
}

# _dm_alert_h <project> — DISPATCH_MODE_ALERT_H through the settings contract
# (row > env > registry default), in a subshell so lane-gate's fail-closed exit
# can never stop the caller; anything but an integer of 1 or more is 24.
_dm_alert_h() {
  local p="${1:-}" h v lib
  h=$(_dm_h)
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  v=$(
    command -v lib_env_apply >/dev/null 2>&1 || . "$lib/lane-gate.sh" >/dev/null 2>&1 || { printf '%s' "${DISPATCH_MODE_ALERT_H:-}"; exit 0; }
    lib_env_apply dispatch-mode "$p" >/dev/null 2>&1
    printf '%s' "${DISPATCH_MODE_ALERT_H:-}") || v="${DISPATCH_MODE_ALERT_H:-}"
  case "$v" in ''|*[!0-9]*) v=24 ;; esac
  [ "$v" -ge 1 ] 2>/dev/null || v=24
  printf '%s' "$v"
}

# dm_age_alert <project> — run after dm_read. Not hotfix-only: the since file
# goes and an open alert is resolved. hotfix-only past the line: one warn
# alert (the digest, not a page), id dispatch-mode-hotfix-only:<p>; the open
# alert-state id suppresses repeats.
dm_age_alert() {
  local p="${1:-}" h f lim since now age hrs iso
  h=$(_dm_h); [ -n "$h" ] && [ -n "$p" ] || return 0
  f="$h/state/dispatch-mode/$p.since"
  if [ "${DM_MODE:-normal}" != hotfix-only ]; then
    if [ -f "$f" ]; then
      rm -f "$f" 2>/dev/null
      [ -x "$h/bin/lane-alert.sh" ] && HARNESS="$h" "$h/bin/lane-alert.sh" --resolve --id "dispatch-mode-hotfix-only:$p" triage \
        "$p: dispatch mode is ${DM_MODE:-normal} again; hotfix-only ended." >/dev/null 2>&1 </dev/null
    fi
    return 0
  fi
  since=$(dm_since_s "$p"); now=$(_dm_now)
  lim=$(_dm_alert_h "$p")
  age=$((now - since))
  [ "$age" -ge $((lim * 3600)) ] || return 0
  hrs=$((age / 3600))
  iso=$(date -u -d "@$since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  [ -x "$h/bin/lane-alert.sh" ] || return 0
  HARNESS="$h" "$h/bin/lane-alert.sh" --severity warn --id "dispatch-mode-hotfix-only:$p" triage \
    "$p: dispatch mode hotfix-only has been on for $hrs h (since $iso, over the $lim h line). Non-hotfix tickets are waiting. Set it back to normal in Mission Control, or edit lib.dispatch-mode.dispatch_mode_alert_h to raise the line." \
    >/dev/null 2>&1 </dev/null
  return 0
}

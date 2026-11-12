# shellcheck shell=bash
# bin/lib/stuck-work/classify.sh — BH-3789 (BH-3781.0): the stuck-work
# classifier CONTRACT, and since BH-3790 (BH-3781.1) its bodies. Sourced, never
# executed, pure: no gh, curl, ledger or file read. The signatures, output
# shapes and the two formats below are fixed by the contract.
#
# ── FACTS line ─────────────────────────────────────────────────────────────
# One TSV line per item, 22 fields in this order (tests/fixtures/stuck-work/README):
# FACTS: kind item url draft labels lead_status lead_status_at verdict verdict_sha verdict_at head mergify cond_state cond_since resolver_at dqw_action_at job_stage job_stage_seen issue_blocked issue_hold open_pr first_seen
# `-` = absent, `?` = unreadable (never read as absent), kind is pr|ticket,
# every *_at / *_since / *_seen field is epoch seconds.
#
# ── snapshot row ───────────────────────────────────────────────────────────
# What the lane will write and the digest will read (no writer ships yet):
# jobs ledger kind `stuck_work_snapshot`, key `latest`, detail
# {"at":<epoch>,"complete":true|false,"by_state":{"<state>":n},"total":n}.
#
# ── signatures ─────────────────────────────────────────────────────────────
#   sw_state <facts-line>          -> state\towner\tentered_at\towner_action_at
#   sw_sla_s <state> [stage]       -> seconds
#   sw_decide <sla_s> <age_s> <ledger_status|-|?> <repage_factor>
#                                  -> page|repage|quiet
#   sw_key <item> <state> <entered_at>
#                                  -> <item>|<state>|<entered_at_epoch>
#   sw_page_text <item> <state> <owner> <age_s> <sla_s> <url>
#                                  -> the page text
#
# ── FACTS vocabulary (BH-3790; the fact readers emit exactly these) ─────────
#   draft          1 | 0 (a ticket line carries -)
#   labels         comma-joined names; dequeued, merge-queue, human-required
#                  and ai-build mean something here
#   lead_status    success | ready = the lead passed it; anything else = not
#   verdict        MERGE | APPROVE = merge verdict, BLOCK, or -; anything
#                  else does not parse
#   mergify        queued | checking | failed | -
#   cond_state     - or a CONDUCTOR_STATES name
#                  (worker/jobs/src/routes/conductor-held.js); anything else
#                  does not parse
#   issue_blocked, issue_hold  1 | 0
#   open_pr        - or an item
# A line that is not 22 non-empty fields, an unknown kind, a value outside this
# vocabulary, or a `?` in a field the precedence walk actually reads is
# `unclassified` (owner stuck-work, SLA 0): it pages once instead of going
# silent. A `?` in a field the walk never reaches changes nothing.
#
# ── additive helpers (BH-3790) ─────────────────────────────────────────────
#   sw_decide takes an optional 5th arg, the state: waiting-on-human and
#   excluded are always quiet (the digest carries them).
#   sw_age_s <now> <entered_at> [owner_action_at] -> seconds since the newest
#     numeric anchor; 0 when none is numeric or it is in the future.
#   sw_repage_factor, sw_max_items, sw_repo -> the knob values.
# Every SLA is a settings row (lane.stuck-work.stuck_work_sla_*); the
# ${X:-default} below is the documented fallback and equals the registry
# default in catalog/lanes.d/stuck-work.json.

# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
_SW_DEPLOYMENT="${HARNESS_DEPLOYMENT_FILE-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deployment.sh}"
# shellcheck source=bin/lib/deployment.sh
. "$_SW_DEPLOYMENT" || return 1
SW_CONDUCTOR_STATES=" WAIT_CI WAIT_REVIEW HEAD_MOVED NEEDS_REBASE REBASING BLOCKED_HUMAN NEEDS_HUMAN_VERDICT WAIT_LEAD WAIT_MIGRATION RED_TWICE READY QUEUED STACKED_WAIT MERGED CLOSED ABANDONED "

_sw_num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# sw_state's helpers; they read its locals (fs, first_seen) by dynamic scope.
# _sw_q: a `?` among the fields a step reads ends the walk.
_sw_q() { local v; for v in "$@"; do [ "$v" = '?' ] && return 0; done; return 1; }
_sw_un() { printf 'unclassified\tstuck-work\t%s\t-\n' "$fs"; }
# an entered anchor: digits as they are, `?` unreadable (rc 1), absent -> first_seen
_sw_at() { if _sw_num "$1"; then echo "$1"; elif [ "$1" = '?' ] || [ "$first_seen" = '?' ]; then return 1; else echo "$fs"; fi; }
_sw_out() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

sw_state() {
  [ $# -ge 1 ] || return 1
  local line=$1 tabs fs=0 e a
  local kind item url draft labels lead_status lead_status_at verdict verdict_sha verdict_at head mergify cond_state cond_since resolver_at dqw_action_at job_stage job_stage_seen issue_blocked issue_hold open_pr first_seen
  tabs=${line//[!$'\t']/}
  if [ "${#tabs}" != 21 ] || [[ $line == *$'\n'* || $line == $'\t'* || $line == *$'\t' || $line == *$'\t\t'* ]]; then
    printf 'unclassified\tstuck-work\t0\t-\n'; return 0
  fi
  IFS=$'\t' read -r kind item url draft labels lead_status lead_status_at verdict verdict_sha verdict_at head mergify cond_state cond_since resolver_at dqw_action_at job_stage job_stage_seen issue_blocked issue_hold open_pr first_seen <<< "$line"
  _sw_num "$first_seen" && fs=$first_seen
  case "$kind" in
    pr)
      _sw_q "$draft" && { _sw_un; return 0; }
      case "$draft" in 1) _sw_out excluded - "$fs" -; return 0 ;; 0|-) ;; *) _sw_un; return 0 ;; esac
      _sw_q "$labels" "$mergify" && { _sw_un; return 0; }
      case "$mergify" in queued|checking|failed|-) ;; *) _sw_un; return 0 ;; esac
      if [[ ,$labels, == *,dequeued,* ]] || [ "$mergify" = failed ]; then
        _sw_q "$dqw_action_at" && { _sw_un; return 0; }
        e=$(_sw_at -) || { _sw_un; return 0; }
        a=-; _sw_num "$dqw_action_at" && a=$dqw_action_at
        _sw_out dequeued dequeue-watch "$e" "$a"; return 0
      fi
      _sw_q "$cond_state" && { _sw_un; return 0; }
      [ "$cond_state" = - ] || [[ $SW_CONDUCTOR_STATES == *" $cond_state "* ]] || { _sw_un; return 0; }
      if [ "$mergify" = queued ] || [ "$mergify" = checking ] || [[ ,$labels, == *,merge-queue,* ]] || [ "$cond_state" = QUEUED ]; then
        if [ "$cond_state" = QUEUED ]; then e=$(_sw_at "$cond_since"); else e=$(_sw_at -); fi || { _sw_un; return 0; }
        _sw_out queued Mergify "$e" -; return 0
      fi
      _sw_q "$verdict" && { _sw_un; return 0; }
      case "$verdict" in MERGE|APPROVE|BLOCK|-) ;; *) _sw_un; return 0 ;; esac
      if [ "$verdict" != - ]; then
        _sw_q "$verdict_sha" "$head" && { _sw_un; return 0; }
        if [ "$verdict_sha" != - ] && [ "$verdict_sha" = "$head" ]; then
          if [ "$verdict" = BLOCK ]; then
            _sw_q "$resolver_at" && { _sw_un; return 0; }
            e=$(_sw_at "$verdict_at") || { _sw_un; return 0; }
            a=-; _sw_num "$resolver_at" && a=$resolver_at
            _sw_out blocked 'fix round' "$e" "$a"; return 0
          fi
          if [ "$cond_state" = BLOCKED_HUMAN ] || [ "$cond_state" = NEEDS_HUMAN_VERDICT ] || [[ ,$labels, == *,human-required,* ]]; then
            if _sw_num "$cond_since"; then e=$cond_since; else e=$(_sw_at "$verdict_at") || { _sw_un; return 0; }; fi
            _sw_out waiting-on-human the operator "$e" -; return 0
          fi
          _sw_q "$lead_status" && { _sw_un; return 0; }
          if [ "$lead_status" = success ] || [ "$lead_status" = ready ]; then
            e=$(_sw_at "$verdict_at") && a=$(_sw_at "$lead_status_at") || { _sw_un; return 0; }
            [ "$a" -gt "$e" ] && e=$a
            _sw_out ready conductor "$e" -; return 0
          fi
        fi
      fi
      e=$(_sw_at -) || { _sw_un; return 0; }
      _sw_out awaiting-lead-review 'lead lane' "$e" - ;;
    ticket)
      _sw_q "$labels" && { _sw_un; return 0; }
      [[ ,$labels, == *,ai-build,* ]] || { _sw_out excluded - "$fs" -; return 0; }
      _sw_q "$open_pr" && { _sw_un; return 0; }
      [ "$open_pr" = - ] || { _sw_out excluded - "$fs" -; return 0; }
      _sw_q "$issue_hold" "$issue_blocked" && { _sw_un; return 0; }
      if [ "$issue_hold" = 1 ] || [ "$issue_blocked" = 1 ]; then _sw_out excluded - "$fs" -; return 0; fi
      _sw_q "$job_stage" && { _sw_un; return 0; }
      if [ "$job_stage" != - ]; then
        e=$(_sw_at "$job_stage_seen") || { _sw_un; return 0; }
        _sw_out "building:$job_stage" builder "$e" -; return 0
      fi
      e=$(_sw_at -) || { _sw_un; return 0; }
      _sw_out unlaunched 'triage / dispatch' "$e" - ;;
    *) _sw_un ;;
  esac
  return 0
}

# minutes from a knob value: all digits and > 0, else the default
_sw_min() { if _sw_num "$1" && [ $((10#$1)) -gt 0 ]; then echo $((10#$1)); else echo "$2"; fi; }

sw_sla_s() {
  local st=${1:-} stage=${2:-} m d=60 stages ent
  case "$st" in
    awaiting-lead-review) m=${STUCK_WORK_SLA_LEAD_REVIEW_MIN:-60} ;;
    ready)            m=${STUCK_WORK_SLA_READY_MIN:-15}; d=15 ;;
    queued)           m=${STUCK_WORK_SLA_QUEUED_MIN:-90}; d=90 ;;
    dequeued)         m=${STUCK_WORK_SLA_DEQUEUED_MIN:-30}; d=30 ;;
    blocked)          m=${STUCK_WORK_SLA_BLOCKED_MIN:-60} ;;
    waiting-on-human) m=${STUCK_WORK_SLA_HUMAN_MIN:-1440}; d=1440 ;;
    unlaunched)       m=${STUCK_WORK_SLA_UNLAUNCHED_MIN:-60} ;;
    unclassified)     echo 0; return 0 ;;
    building|building:*)
      [ "$st" = building ] || stage=${st#building:}
      [ -n "$stage" ] || return 1
      stages=${STUCK_WORK_SLA_BUILD_STAGES:-plan=45,execute=120,review=45,fix=60,default=90}
      [[ $stages =~ ^[a-z0-9_-]+=[0-9]+(,[a-z0-9_-]+=[0-9]+)*$ ]] || stages=plan=45,execute=120,review=45,fix=60,default=90
      m=; d=90
      for ent in ${stages//,/ }; do
        [ "${ent%%=*}" = "$stage" ] && m=${ent#*=}
        [ "${ent%%=*}" = default ] && d=$(_sw_min "${ent#*=}" 90)
      done ;;
    *) return 1 ;;
  esac
  echo $(( $(_sw_min "$m" "$d") * 60 ))
}

sw_age_s() {
  local now=${1:-} a=-1 v
  _sw_num "$now" || { echo 0; return 0; }
  shift
  for v in "$@"; do _sw_num "$v" && [ $((10#$v)) -gt "$a" ] && a=$((10#$v)); done
  if [ "$a" -lt 0 ] || [ "$a" -gt "$now" ]; then echo 0; else echo $((10#$now - a)); fi
}

sw_repage_factor() {
  local f=${STUCK_WORK_REPAGE_FACTOR:-4}
  _sw_num "$f" || f=4
  [ $((10#$f)) -lt 2 ] && f=2
  echo $((10#$f))
}

sw_max_items() { _sw_min "${STUCK_WORK_MAX_ITEMS:-300}" 300; }

sw_repo() {
  local r=${STUCK_WORK_REPO:-$HARNESS_REPO}
  [[ $r =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || r=$(unset HARNESS_REPO; . "$_SW_DEPLOYMENT" && printf %s "$HARNESS_REPO")
  echo "$r"
}

# A row with any status but repaged (paged, or one a later writer adds) has
# paged once, so it may repage at factor x SLA; repaged is quiet for good.
sw_decide() {
  [ $# -ge 4 ] || return 1
  local sla=$1 age=$2 led=$3 f=$4
  case "${5:-}" in waiting-on-human|excluded) echo quiet; return 0 ;; esac
  if ! _sw_num "$sla" || ! _sw_num "$age" || [ "$led" = '?' ] || [ "${#sla}" -gt 15 ] || [ "${#age}" -gt 15 ]; then echo quiet; return 0; fi
  sla=$((10#$sla)) age=$((10#$age))
  if [ "$age" -lt "$sla" ]; then echo quiet; return 0; fi
  if _sw_num "$f" && [ "${#f}" -le 3 ]; then f=$((10#$f)); else f=4; fi
  [ "$f" -lt 2 ] && f=2
  case "$led" in
    -) echo page ;;
    repaged) echo quiet ;;
    # SLA 0 (unclassified) pages once: any ledger row means it already did
    *) [ "$sla" = 0 ] && { echo quiet; return 0; }
       if [ "$age" -ge $((f * sla)) ]; then echo repage; else echo quiet; fi ;;
  esac
}

sw_key() {
  local item=${1:-} st=${2:-} e=${3:-}
  [ -n "$item" ] && [ -n "$st" ] || return 1
  _sw_num "$e" || e=0
  printf '%s|%s|%s\n' "$item" "$st" "$e"
}

sw_page_text() {
  [ $# -ge 6 ] || return 1
  local age=- sla=-
  _sw_num "$4" && age=$((10#$4 / 60))
  _sw_num "$5" && sla=$((10#$5 / 60))
  printf 'STUCK-WORK %s %s owner=%s age=%sm sla=%sm — %s\n' "$1" "$2" "$3" "$age" "$sla" "$6"
}

# shellcheck shell=bash
# bin/lib/pool-lifecycle.sh — BH-8733 (lifecycle 3/6): the pool writes a
# ticket's phase through the BH-8731 lifecycle verb, and reads it back.
# Sourced, never run. Defining functions is its only effect at source time.
#
# WHY. A PLAN_BLOCKED stop lived only in hub files, and the question stayed in
# the hub's plan.md where nothing could ask it again. The phase and the
# question now live in the build_queue row (phase, phase_at, phase_actor,
# question; BH-8731), written by the actor that owns them: the pool owns
# planned, plan_blocked, building and pr_open (worker/jobs/src/lib/lifecycle.js).
#
# THE WRITES (config/fly-pool.d, rendered into bin/fly-pool.sh)
#   planned       push_preplan relayed a pre-plan to a machine.
#   building      spawn_one spawned a machine, or the reuse handoff reused one.
#   pr_open <n>   the reap closed the row for a PR_CREATED RESULT.
#   plan_blocked  the reap closed the row for a PLAN_BLOCKED RESULT; the
#                 question is the plan's blocked excerpt (pb_excerpt).
#
# pool_phase_set <project> <key> <to> <reason> [pr] [question]  always rc 0.
#   One POST /api/lifecycle/transition, actor pool. 200: one `phase -> <to>`
#   line. The 409 table (the body's `current`):
#     current == to   silent: the move is already done (a respawn, a re-reap).
#     to plan_blocked, current NULL or pr_open; to pr_open, current NULL,
#     triaged or planned:
#                     REPAIR. The spawn's building write did not land, or this
#                     is a rebuild over pr_open. Send building ("repair: ..."),
#                     then <to> once more. At most 2 extra calls, no loop.
#                     (plan_blocked from triaged or planned is legal at once,
#                     so it never answers 409 and needs no repair.)
#     any other 409   one `refused` line, no retry. pool_phase_reap acts on a
#                     refused plan_blocked (below).
#   rc 2 (no row), rc 1 (outage), rc 3 (bad arguments): one line, no retry.
#   A lane job key (RB-, RR-, LR-, FXR-, CP-) is not a ticket and is never
#   written. No verb on this host: one line per process, no write.
# pool_phase_get <project> <key>  prints `phase<TAB>phase_at<TAB>question` (a
#   missing field is `-`; tabs and newlines in the question become spaces).
#   rc 0 a row, rc 2 no row, rc 1 outage or no client.
# pool_phase_reap <project> <key> <local-dir> [ticket]  always rc 0; writes
#   from line 1 of <local-dir>/RESULT: PLAN_BLOCKED -> plan_blocked + question,
#   PR_CREATED <url .../pull/N> -> pr_open N, any other word -> nothing (the
#   phase stays building, and the BH-8731 stuck read reports it). It reads only
#   that one record, the one the reap just pulled.
#   A REFUSED plan_blocked (verdict 5198). merged and closed are terminal
#   (lifecycle.js), so the phase cannot hold the stop, and the spawn gate
#   passes those phases: the key would relaunch up to the spawn cap every day.
#   For a key in merged or closed on an issues ticket (all-digit ticket), the
#   stop is stored as ONE needs-human hold on the issue (bin/needs-human-hold.sh,
#   fp per key, the question in the action). The pool's HOLD gate
#   (pool_hold_check) reads it and stops the next spawn until a person
#   answers. `<local-dir>/lifecycle-refused.held` is written only after the
#   hold script exits 0. Any other refusal gives ONE ALERTS line per record
#   (`<local-dir>/lifecycle-refused.alerted`): a failed hold names its rc; a
#   board ticket (no issue to hold) says the spawn cap is the bound; abandoned,
#   ejected and in_queue add nothing, because the spawn gate refuses them.
#
# A failed write never stops the pool: the queue row is closed before the phase
# is written. Knob: POOL_LIFECYCLE_QUESTION_MAX (catalog/lanes.d/fly-pool.knobs.d).

_plc_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }
_plc_ticket_key() { # rc 0 only for a ticket's build key
  case "${1:-}" in ''|RB-*|RR-*|LR-*|FXR-*|CP-*) return 1 ;; esac
  return 0
}
_plc_load() { # rc 0 when lifecycle_transition is defined
  if ! declare -F lifecycle_transition >/dev/null 2>&1; then
    local f="${BASH_SOURCE[0]%/*}/jobs/lifecycle.sh"
    # shellcheck disable=SC1090
    [ -r "$f" ] && . "$f" 2>/dev/null
  fi
  declare -F lifecycle_transition >/dev/null 2>&1 && return 0
  [ -n "${_PLC_SAID:-}" ] || _plc_say "lifecycle: no verb on this host — phase writes skipped"
  _PLC_SAID=1
  return 1
}

# _plc_send <project> <key> <to> <reason> <pr> [question] -> the verb's rc;
# the answer body lands in _PLC_BODY.
_plc_send() {
  local rc
  if [ $# -ge 6 ]; then
    _PLC_BODY=$(lifecycle_transition "$1" "$2" "$3" pool "$4" "$5" "$6" 2>/dev/null); rc=$?
  else
    _PLC_BODY=$(lifecycle_transition "$1" "$2" "$3" pool "$4" "$5" 2>/dev/null); rc=$?
  fi
  return "$rc"
}
_plc_why() { # sets _PLC_CUR and _PLC_ERR from the 409 body in _PLC_BODY
  _PLC_CUR=$(jq -r 'if has("current") then (.current // "<null>") else "<none>" end' <<<"$_PLC_BODY" 2>/dev/null) || _PLC_CUR="<none>"
  [ -n "$_PLC_CUR" ] || _PLC_CUR="<none>"
  _PLC_ERR=$(jq -r '.error // "?"' <<<"$_PLC_BODY" 2>/dev/null) || _PLC_ERR="?"
}

# _PLC_REFUSED is set to the current phase when the last pool_phase_set ended
# on a 409 that is not current == to, else it is empty.
pool_phase_set() {
  local p="${1:-}" key="${2:-}" to="${3:-}" why="${4:-}" pr="${5:-}" rc
  _PLC_REFUSED=""
  [ -n "$p" ] && [ -n "$to" ] && [ -n "$why" ] || return 0
  _plc_ticket_key "$key" || return 0
  _plc_load || return 0
  _plc_send "$p" "$key" "$to" "$why" "$pr" "${@:6}"; rc=$?
  if [ "$rc" = 9 ]; then
    _plc_why
    [ "$_PLC_CUR" = "$to" ] && return 0
    case "$to:$_PLC_CUR" in
      plan_blocked:"<null>"|plan_blocked:pr_open|pr_open:"<null>"|pr_open:triaged|pr_open:planned)
        _plc_send "$p" "$key" building "repair: $why" ""; rc=$?
        if [ "$rc" = 0 ]; then
          _plc_say "$key: phase -> building (repair)"
          _plc_send "$p" "$key" "$to" "$why" "$pr" "${@:6}"; rc=$?
        fi
        [ "$rc" = 9 ] && _plc_why ;;
    esac
  fi
  case "$rc" in
    0) _plc_say "$key: phase -> $to" ;;
    9) _PLC_REFUSED="${_PLC_CUR/<null>/none}"
       _plc_say "$key: phase -> $to refused ($_PLC_ERR; current $_PLC_REFUSED) — not retried" ;;
    2) _plc_say "$key: phase -> $to not written: no build_queue row" ;;
    3) _plc_say "$key: phase -> $to not written: bad arguments" ;;
    *) _plc_say "$key: phase -> $to not written: the lifecycle DB is unreadable (outage or no client)" ;;
  esac
  return 0
}

pool_phase_get() {
  local p="${1:-}" key="${2:-}" pu ku body rc
  [ -n "$p" ] && [ -n "$key" ] || return 1
  declare -F _jobs_req >/dev/null 2>&1 || return 1
  pu=$(jq -rn --arg v "$p" '$v|@uri' 2>/dev/null) && ku=$(jq -rn --arg v "$key" '$v|@uri' 2>/dev/null) || return 1
  body=$(_jobs_req GET "/api/queue?project=$pu&key=$ku&limit=1" 2>/dev/null); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  jq -e '.queue | type == "array"' <<<"$body" >/dev/null 2>&1 || return 1
  jq -er --arg p "$p" --arg k "$key" '
    def f: if . == null or . == "" then "-" else tostring | gsub("[\t\r\n]"; " ") end;
    [.queue[] | select(.project == $p and .ticket_key == $k)] | first
    | if . == null then empty else [(.phase | f), (.phase_at | f), (.question | f)] | join("\t") end' \
    <<<"$body" 2>/dev/null || return 2
}

# _plc_question <local-dir> <result line 1> -> the stored question text.
_plc_question() {
  local d="$1" l1="$2" q max
  q=""
  declare -F pb_excerpt >/dev/null 2>&1 && [ -s "$d/plan.md" ] && q=$(pb_excerpt "$d/plan.md" 2>/dev/null)
  [ -n "$q" ] || { q="${l1#PLAN_BLOCKED}"; q="${q# }"; }
  [ -n "$q" ] || q="(no blocked section in the plan; see the hub record ${d##*/})"
  declare -F _ee_defang >/dev/null 2>&1 && q=$(printf '%s' "$q" | _ee_defang)
  # Bytes (LC_ALL=C) are never fewer than the route's UTF-16 length, so a cut
  # here can never reach the route's 400.
  max="${POOL_LIFECYCLE_QUESTION_MAX:-2000}" # knob POOL_LIFECYCLE_QUESTION_MAX (catalog/lanes.d/fly-pool.knobs.d)
  case "$max" in ''|*[!0-9]*) max=2000 ;; esac
  max=$((10#$max)); { [ "$max" -ge 1 ] && [ "$max" -le 2000 ]; } || max=2000
  _plc_cut "$q" "$max"
}
_plc_cut() { # _plc_cut <text> <max bytes> -> the text, cut on a line end when it is longer
  local LC_ALL=C cut
  if [ "${#1}" -gt "$2" ]; then
    cut="${1:0:$2}"
    case "$cut" in *$'\n'*) cut="${cut%$'\n'*}" ;; esac
    printf '%s' "$cut"
  else
    printf '%s' "$1"
  fi
}

# _plc_hold <project> <ticket> <key> <local-dir> <current> <question> -> the
# rc of bin/needs-human-hold.sh (127 when it is not on this box). It writes
# <local-dir>/lifecycle-refused.held only on rc 0. The fp is per key, so a
# second record of the same key while the hold stands posts nothing
# (needs-human-hold.sh step 4). The action carries no hold or lift word of
# bin/lib/hold.sh (BH-5911): it must not read as a HOLD comment.
_plc_hold() {
  local p="$1" t="$2" key="$3" d="$4" cur="$5" q="$6" r fp act rc
  r="${HARNESS:-${H:-}}"
  [ -n "$r" ] && [ -x "$r/bin/needs-human-hold.sh" ] || return 127
  fp=$(printf '%s' "$p:$key:plan_blocked-refused" | sha1sum 2>/dev/null | cut -c1-16)
  case "$fp" in ''|*[!0-9a-f]*) return 3 ;; esac
  act="PLAN_BLOCKED on $key, and its ticket phase is $cur, so the DB cannot store the stop. The pool does not build it again until a person answers on this ticket. Question: $q"
  HARNESS="$r" "$r/bin/needs-human-hold.sh" "$p" "$t" "$fp" "$act" plan-blocked </dev/null >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    : > "$d/lifecycle-refused.held" 2>/dev/null
    _plc_say "$key: PLAN_BLOCKED not stored (current $cur) — hold placed on #$t"
  fi
  return "$rc"
}

pool_phase_reap() {
  local p="${1:-}" key="${2:-}" d="${3:-}" t="${4:-}" l1 w n q r hrc tail
  [ -n "$p" ] && [ -f "$d/RESULT" ] || return 0
  _plc_ticket_key "$key" || return 0
  l1=$(head -1 "$d/RESULT" 2>/dev/null)
  case "$l1" in
    PLAN_BLOCKED|"PLAN_BLOCKED "*)
      q=$(_plc_question "$d" "$l1")
      pool_phase_set "$p" "$key" plan_blocked "PLAN_BLOCKED at ${d##*/}" "" "$q"
      [ -n "${_PLC_REFUSED:-}" ] || return 0
      [ -e "$d/lifecycle-refused.held" ] && return 0
      tail=""
      case "$_PLC_REFUSED" in
        merged|closed)
          case "$t" in
            ''|*[!0-9]*) tail="; board ticket, no issue to hold; the per-key spawn cap bounds a relaunch" ;;
            *) _plc_hold "$p" "$t" "$key" "$d" "$_PLC_REFUSED" "$q"; hrc=$?
               [ "$hrc" = 0 ] && return 0
               tail="; hold not placed (rc $hrc)" ;;
          esac ;;
      esac
      # One ALERTS line per record: the marker keeps a second reap quiet.
      r="${HARNESS:-${H:-}}"
      if [ -n "$r" ] && [ ! -e "$d/lifecycle-refused.alerted" ]; then
        [ -x "$r/bin/alert-line.sh" ] && HARNESS="$r" "$r/bin/alert-line.sh" --project "$p" \
          "[pool/$p] $key: PLAN_BLOCKED not stored (current $_PLC_REFUSED)$tail" </dev/null >/dev/null 2>&1
        : > "$d/lifecycle-refused.alerted" 2>/dev/null
      fi ;;
    PR_CREATED|"PR_CREATED "*)
      read -r _ w _ <<<"$l1"
      n=""; [[ "${w:-}" =~ /pull/0*([1-9][0-9]{0,15})([^0-9]|$) ]] && n="${BASH_REMATCH[1]}"
      if [ -z "$n" ]; then
        _plc_say "$key: PR_CREATED with no PR number in '${w:-}' — no pr_open phase written"
        return 0
      fi
      pool_phase_set "$p" "$key" pr_open "PR_CREATED $w" "$n" ;;
  esac
  return 0
}

#!/bin/bash
# bin/lib/budget-stop.sh — HARD CAPS on every stage and scope (BH-4488 wave 1,
# widened by BH-4489 wave 2 of BH-4475). Sourced by bin/agent-call.sh and by
# the launch gate in bin/lib/rb/gates.sh; no side effect at source time beyond
# defining functions and capturing this file's own directory.
#
# THREE SCOPES, each with its own unit, keys and running total:
#
#   scope        unit                     settings rows                      total read from
#   build-stage  (build dir, stage)       budget.stage.<s>.max_calls          <build>/cost.csv
#                                         budget.stage.<s>.max_usd
#                                         budget.stage.<s>.max_tokens
#   stage-day    (project, stage, UTC day) budget.stage.<s>.day_usd           D1 GET /api/metrics/
#                                         budget.stage.<s>.day_calls           llm-spend?project=&stage=
#   project-day  (project, UTC day)       budget.project.<p>.day_usd          D1 llm-spend?project=
#
# build-stage engages on a call whose $OUT lands in a build dir, ANY stage
# (wave 1 was execute only). The day scopes engage on any call with a project
# and a configured jobs client (HARNESS_SECRET + JOBS_URL), build or not: that
# is how triage, lead-review, Archie, research and every lane outside a build
# get a cap. Tokens = input_toks + output_toks + cache_read + cache_write of the
# same rows counted as calls; a non-numeric token cell adds 0. Day calls are
# billed calls: calls - refused - settled, so a refusal costs no call.
#
# CAP RESOLUTION, per axis: the specific row, then the `_default` row
# (budget.stage._default.<axis>, budget.project._default.day_usd), then no cap.
# A stage or project whose name cannot make a legal key ([a-z0-9_.-]{1,64})
# skips straight to `_default`, so a bad name never becomes a refusal; one the
# spend query cannot carry ([A-Za-z0-9._-]) has no day scope at all. `off` on
# the specific row unarms that axis outright (no fallback). `0` is a real cap:
# refuse everything on that axis (the opposite of llm-gate's 0 = unlimited).
# Rows are read from the settings cache (state/settings-cache.json, filled by
# lane-gate's _lg_settings_refresh), exactly as wave 1 reads them.
#
# A TERMINAL VERDICT WINS, THEN THE TIGHTEST. Every engaged scope is evaluated.
# Any build-stage axis at or over its cap wins outright: it is terminal, and a
# day deferral in its place would re-offer the ticket as a fresh build with
# fresh build-stage totals, so the overrun would be forgotten. Among the day
# scopes (and among build-stage axes) the refusal belongs to the axis with the
# smallest headroom (cap - spent) / cap, cap 0 counting as minus infinity; ties
# go stage-day, then project-day. The refusal line names every other over axis
# after `also over:`.
#
# THE CONSEQUENCE FOLLOWS THE WINNER.
#   build-stage: terminal, wave 1 unchanged — $BUILD/BUDGET_STOP written once
#     (line 1 = the verdict), one alert, and CC() ends the build with
#     RESULT "BUILD_REFUSED BUDGET_STOP <line 1>".
#   stage-day / project-day: NOT terminal, the day resets. agent-call refuses
#     rc 74 with `AGENT_CALL_REFUSED budget-stage-day|budget-project-day ...`,
#     a zero-cost refused row and one alert per (scope, name, UTC day). Inside
#     a build CC() answers BUILD_DEFERRED and the pool does not count it.
#     Nothing RESUMES that build: resume-dead.sh leaves a first run's
#     BUILD_DEFERRED to triage and skips pool dirs, so the ticket comes back as
#     a fresh build, and checkpoint adopt keeps only its code. What stops that
#     fresh build from buying plan and execute again is the launch gate:
#     bs_launch_check refuses while the project-day cap OR the stage-day cap of
#     any build stage (BS_BUILD_STAGES) is over, so a re-offer buys nothing
#     until 00:00Z. The calls the deferred run already bought are lost.
#   EXCEPT IN AN ADMITTED BUILD (BH-5526). The launch gate is the ticket
#     boundary: when it lets a build through it writes $BUILD/ADMITTED. A day
#     scope never refuses a call whose build dir holds that marker and no
#     RESULT, from the build's own lane (bs_admitted), so a ticket
#     that started finishes plan, execute and review. The call is allowed and
#     ONE line per build goes to <build>/pipeline.log with the refusal it
#     would have written (marker <build>/.cap-overrun-noted). build-stage is
#     unchanged: it is the in-ticket runaway guard and still stops the build.
#
# UNREADABLE. build-stage keeps wave 1: an unreadable cap, settings cache or
# cost.csv trips the terminal marker with its own reason. A day scope that
# cannot be read (cap row junk, settings cache corrupt, llm-spend down) FAILS
# CLOSED inside a build — `AGENT_CALL_REFUSED budget-cap-unreadable <stage>
# <reason>`, which CC() defers on — except an admitted build, where it is
# allowed and noted as above — and FAILS OPEN outside one, with one alert
# per (stage, project, UTC day). Outside a build there is no job to defer, and
# the lanes that report a worker outage must keep running through one.
# Spend is read only for a scope that resolved a cap: no rows, no reads.
#
# FINISHES NOTHING MID-CALL. Every check runs before the call and nothing here
# ever signals a running child. D1 is fed by the fleet's cost mirror push, so a
# day scope can overshoot by what was spent inside that lag; that is the
# accepted bound. The call that crosses a cap finishes; the next one is refused.
#
# KILL SWITCH: lane_switch budget-stop-off (settings row switch.budget-stop-off
# or flags/budget-stop-off) turns every scope off, call gate and launch gate.
# A build that already holds BUDGET_STOP stays stopped.
#
# Root: ${HARNESS:-${H:-}} and nothing else.
#
#   bs_applies <stage> <out>           rc 0 = the build-stage scope engages
#   bs_cap <stage> <field>             rc 0 + value (printed and in BS_VALUE) |
#                                      rc 1 unarmed | rc 2 + BS_REASON. Fields:
#                                      max_calls max_usd max_tokens day_usd
#                                      day_calls. Call it in this shell, not in
#                                      $(...), to keep BS_VALUE / BS_REASON.
#   bs_pcap <project>                  the same for budget.project.<p>.day_usd
#   bs_total <csv> <stage>             prints "calls usd unpriced"; rc 2 unreadable
#   bs_tokens <csv> <stage>            prints the token sum; rc 2 unreadable
#   bs_check <project> <stage> <dir>   build-stage only: rc 0 allow | rc 1
#                                      refuse, BS_LINE = verdict, marker tripped
#   bs_trip <project> <dir> <line>     marker + one alert, first caller only; rc 0
#   bs_gate <project> <stage> <out>    every scope: rc 0 allow | 1 build-stage
#                                      stop (BS_LINE, marker tripped) | 2 day
#                                      refusal (BS_REFUSE) | 3 unreadable inside
#                                      a build (BS_REFUSE); never 2 or 3 in an
#                                      admitted build dir
#   bs_admitted <dir>                  rc 0 = <dir>/ADMITTED exists (the launch
#                                      gate passed for this build), <dir>/RESULT
#                                      does not (the ticket has not ended), and
#                                      AGENT_CALL_LANE is unset or fly-pool
#   bs_launch_check <project>          project-day, and stage-day for every
#                                      build stage: rc 0 allow | 1 over
#                                      (BS_REFUSE) | 2 unreadable (BS_REASON)

# The stages a build's CC() calls (bin/run-build.sh, bin/lib/rb/*.sh). The
# launch gate checks each one's stage-day cap, because a build that defers on
# its review cap has already paid for plan and execute.
BS_BUILD_STAGES="plan execute review fix qa"

_BS_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
BS_REASON=""
BS_VALUE=""
BS_LINE=""
BS_REFUSE=""

_bs_root() { printf '%s' "${HARNESS:-${H:-}}"; }

_bs_key_ok() { grep -Eq '^[a-z0-9_.-]{1,64}$' <<<"${1:-}"; }

# A ticket is in progress while its dir holds ADMITTED and no RESULT (RESULT()
# in bin/run-build.sh writes it at ticket end; a resume removes it). A call
# from a lane other than the build's own (fly-pool, or unset as inside
# run-build) is its own start: post-merge QA writes into an ended build dir,
# and an explicit lane such as postmerge-qa never rides the exemption.
bs_admitted() {
  [ -n "${1:-}" ] && [ -f "${1%/}/ADMITTED" ] && [ ! -e "${1%/}/RESULT" ] || return 1
  case "${AGENT_CALL_LANE:-}" in ""|fly-pool) return 0 ;; esac
  return 1
}

# _bs_overrun_note <dir> <text> — the one pipeline.log line an admitted build
# gets when a day scope would have refused it. First caller only.
_bs_overrun_note() {
  ( set -C; : > "$1/.cap-overrun-noted" ) 2>/dev/null || return 0
  printf '%s day cap over/unreadable during an admitted ticket — call ALLOWED (BH-5526): %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" >> "$1/pipeline.log" 2>/dev/null
  return 0
}

bs_applies() {
  local s="${1:-}" o="${2:-}"
  case "$o" in */builds/*/*) ;; *) return 1 ;; esac
  [ -n "$s" ]
}

# _bs_off — rc 0 when the budget-stop-off kill switch is ON.
_bs_off() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$_BS_LIB/lane-switch.sh" ] && { . "$_BS_LIB/lane-switch.sh" 2>/dev/null || true; }
    command -v lane_switch >/dev/null 2>&1 \
      || lane_switch() { [ -n "$(_bs_root)" ] && [ -f "$(_bs_root)/flags/$1" ]; }
  fi
  lane_switch budget-stop-off file >/dev/null 2>&1
}

# _bs_settings — the settings cache path in BS_SETTINGS; rc 1 when this box
# has none (unarmed).
_bs_settings() {
  BS_SETTINGS=""
  if ! command -v _lg_settings_file >/dev/null 2>&1 && [ -r "$_BS_LIB/lane-gate.sh" ]; then
    # shellcheck source=bin/lib/lane-gate.sh
    . "$_BS_LIB/lane-gate.sh" 2>/dev/null || true
  fi
  command -v _lg_settings_refresh >/dev/null 2>&1 && { _lg_settings_refresh >/dev/null 2>&1 || true; }
  if command -v _lg_settings_file >/dev/null 2>&1; then BS_SETTINGS=$(_lg_settings_file)
  elif [ -n "$(_bs_root)" ]; then BS_SETTINGS="$(_bs_root)/state/settings-cache.json"; fi
  [ -n "$BS_SETTINGS" ] && [ -e "$BS_SETTINGS" ]
}

# _bs_row <key> <regex> — rc 0 value in BS_VALUE | 1 absent | 2 unreadable
# (BS_REASON) | 3 the value `off`.
_bs_row() {
  local key="$1" re="$2" v
  BS_VALUE=""
  _bs_settings || return 1
  if ! jq -e '.values|type=="object"' "$BS_SETTINGS" >/dev/null 2>&1; then
    BS_REASON="settings-unreadable"; return 2
  fi
  jq -e --arg k "$key" '.values|has($k)' "$BS_SETTINGS" >/dev/null 2>&1 || return 1
  v=$(jq -r --arg k "$key" '.values[$k]|if type=="string" then . else tojson end' "$BS_SETTINGS" 2>/dev/null) \
    || { BS_REASON="settings-unreadable"; return 2; }
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ "$v" = off ] && return 3
  if grep -Eq "$re" <<<"$v"; then BS_VALUE="$v"; return 0; fi
  BS_REASON="cap-unreadable:$key"
  return 2
}

# _bs_resolve <specific-key> <default-key> <regex> — the D4 resolution.
_bs_resolve() {
  local rc=1
  if _bs_key_ok "$1"; then
    _bs_row "$1" "$3"; rc=$?
    case "$rc" in 0) return 0 ;; 2) return 2 ;; 3) return 1 ;; esac
  fi
  _bs_row "$2" "$3"; rc=$?
  case "$rc" in 0) return 0 ;; 2) return 2 ;; esac
  return 1
}

bs_cap() {
  local stage="${1:-}" field="${2:-}" re rc
  BS_REASON=""; BS_VALUE=""
  case "$field" in
    max_calls|max_tokens|day_calls) re='^[0-9]+$' ;;
    max_usd|day_usd)                re='^[0-9]+(\.[0-9]+)?$' ;;
    *) BS_REASON="cap-unreadable:budget.stage.$stage.$field"; return 2 ;;
  esac
  rc=0; _bs_resolve "budget.stage.$stage.$field" "budget.stage._default.$field" "$re" || rc=$?
  [ "$rc" = 0 ] && printf '%s' "$BS_VALUE"
  return "$rc"
}

bs_pcap() {
  local p="${1:-}" rc
  BS_REASON=""; BS_VALUE=""
  rc=0; _bs_resolve "budget.project.$p.day_usd" "budget.project._default.day_usd" '^[0-9]+(\.[0-9]+)?$' || rc=$?
  [ "$rc" = 0 ] && printf '%s' "$BS_VALUE"
  return "$rc"
}

bs_total() {
  local csv="${1:-}" stage="${2:-}"
  [ -e "$csv" ] || { printf '0 0.00 0\n'; return 0; }
  [ -r "$csv" ] || return 2
  awk -F, -v S="$stage" '
    NR == 1 && ($0 ~ /(^|,)stage(,|$)/) {
      for (i = 1; i <= NF; i++) { if ($i == "stage") sc = i; if ($i == "cost_usd") cc = i }
      next
    }
    { if (!sc) sc = 4; if (!cc) cc = 13 }
    $sc == S {
      n++
      if ($cc ~ /^[0-9]+(\.[0-9]+)?$/) usd += $cc; else u++
    }
    END { printf "%d %.2f %d\n", n, usd, u }' "$csv" 2>/dev/null || return 2
}

bs_tokens() {
  local csv="${1:-}" stage="${2:-}"
  [ -e "$csv" ] || { printf '0\n'; return 0; }
  [ -r "$csv" ] || return 2
  awk -F, -v S="$stage" '
    NR == 1 && ($0 ~ /(^|,)stage(,|$)/) {
      for (i = 1; i <= NF; i++) {
        if ($i == "stage") sc = i
        if ($i == "input_toks") t1 = i; if ($i == "output_toks") t2 = i
        if ($i == "cache_read") t3 = i; if ($i == "cache_write") t4 = i
      }
      next
    }
    { if (!sc) sc = 4; if (!t1) t1 = 9; if (!t2) t2 = 10; if (!t3) t3 = 11; if (!t4) t4 = 12 }
    $sc == S {
      if ($t1 ~ /^[0-9]+$/) n += $t1; if ($t2 ~ /^[0-9]+$/) n += $t2
      if ($t3 ~ /^[0-9]+$/) n += $t3; if ($t4 ~ /^[0-9]+$/) n += $t4
    }
    END { printf "%.0f\n", n }' "$csv" 2>/dev/null || return 2
}

# _bs_build_eval <stage> <dir> — the build-stage caps and totals into _BB_*.
# rc 0 = something armed | 1 nothing armed | 2 unreadable (BS_REASON).
_bs_build_eval() {
  local stage="$1" b="$2" f rc tot
  _BB_MC=""; _BB_MU=""; _BB_MT=""; _BB_CALLS=0; _BB_USD=0.00; _BB_UNP=0; _BB_TOK=0
  for f in max_calls max_usd max_tokens; do
    rc=0; bs_cap "$stage" "$f" >/dev/null || rc=$?
    case "$rc" in
      0) case "$f" in max_calls) _BB_MC="$BS_VALUE" ;; max_usd) _BB_MU="$BS_VALUE" ;; *) _BB_MT="$BS_VALUE" ;; esac ;;
      1) ;;
      *) return 2 ;;
    esac
  done
  [ -z "$_BB_MC$_BB_MU$_BB_MT" ] && return 1
  if tot=$(bs_total "$b/cost.csv" "$stage") && [ -n "$tot" ]; then
    read -r _BB_CALLS _BB_USD _BB_UNP <<<"$tot"
  else
    BS_REASON="total-unreadable"; return 2
  fi
  if [ -n "$_BB_MT" ]; then
    _BB_TOK=$(bs_tokens "$b/cost.csv" "$stage") && [ -n "$_BB_TOK" ] || { BS_REASON="total-unreadable"; return 2; }
  fi
  return 0
}

# _bs_line <stage> <reason> — the wave-1 verdict line, plus the token pair when
# that axis is armed.
_bs_line() {
  local l="budget_stop $1 $2 calls=$_BB_CALLS max_calls=${_BB_MC:--} usd=$_BB_USD max_usd=${_BB_MU:--} unpriced=$_BB_UNP"
  [ -n "${_BB_MT:-}" ] && l="$l tokens=$_BB_TOK max_tokens=$_BB_MT"
  printf '%s' "$l"
}

_bs_ge() { awk -v a="$1" -v c="$2" 'BEGIN{exit !(a + 0 >= c + 0)}'; }

bs_check() {
  local p="${1:-}" stage="${2:-}" b="${3:-}" rc reason=""
  BS_LINE=""
  b="${b%/}"
  if [ -f "$b/BUDGET_STOP" ]; then
    BS_LINE=$(head -1 "$b/BUDGET_STOP" 2>/dev/null | tr -d '\r')
    [ -n "$BS_LINE" ] || BS_LINE="budget_stop $stage marker-present"
    return 1
  fi
  rc=0; _bs_build_eval "$stage" "$b" || rc=$?
  # Nothing armed and nothing unreadable: no total is read, nothing is written.
  [ "$rc" = 1 ] && return 0
  if [ "$rc" = 2 ]; then reason="$BS_REASON"; _BB_MC=""; _BB_MU=""; _BB_MT=""; fi
  [ -z "$reason" ] && [ -n "$_BB_MC" ] && [ "$_BB_CALLS" -ge "$_BB_MC" ] && reason=max_calls
  [ -z "$reason" ] && [ -n "$_BB_MU" ] && _bs_ge "$_BB_USD" "$_BB_MU" && reason=max_usd
  [ -z "$reason" ] && [ -n "$_BB_MT" ] && _bs_ge "$_BB_TOK" "$_BB_MT" && reason=max_tokens
  [ -n "$reason" ] || return 0
  BS_LINE=$(_bs_line "$stage" "$reason")
  bs_trip "$p" "$b" "$BS_LINE"
  return 1
}

bs_trip() {
  local p="${1:-}" b="${2:-}" v="${3:-}" root stage text
  b="${b%/}"
  [ -n "$b" ] && [ -d "$b" ] || return 0
  ( set -C; : > "$b/.budget-stop.claim" ) 2>/dev/null || return 0
  stage=$(printf '%s' "$v" | awk '{print $2}')
  {
    printf '%s\n' "$v"
    printf 'caps read: budget.stage.%s.max_calls, .max_usd, .max_tokens (settings rows; budget.stage._default.* when the stage has none)\n' "${stage:-?}"
    printf 'raise or clear: PUT /api/settings with the key above (value off unarms it); a fresh build starts a fresh total\n'
  } > "$b/BUDGET_STOP.tmp" 2>/dev/null && mv -f "$b/BUDGET_STOP.tmp" "$b/BUDGET_STOP" 2>/dev/null
  root=$(_bs_root)
  text="BUDGET_STOP $p build ${b##*/}: $v. Nothing more is called for it. Caps are settings rows budget.stage.${stage:-?}.max_calls / max_usd / max_tokens; marker $b/BUDGET_STOP"
  if [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ]; then
    "$root/bin/lane-alert.sh" --id "budget-stop:$p:${b##*/}" budget-stop "$text" >/dev/null 2>&1 \
      || echo "$(date -u '+%FT%TZ') [$p] budget-stop alert failed for ${b##*/}" >> "$root/logs/failovers.log" 2>/dev/null
  elif [ -n "$root" ] && [ -x "$root/bin/alert-line.sh" ]; then
    "$root/bin/alert-line.sh" --id "budget-stop:$p:${b##*/}" --project "$p" "[budget-stop] $text" >/dev/null 2>&1 \
      || echo "$(date -u '+%FT%TZ') [$p] budget-stop alert failed for ${b##*/}" >> "$root/logs/failovers.log" 2>/dev/null
  fi
  return 0
}

# --- the day scopes (BH-4489) ------------------------------------------------

_bs_slug() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

# _bs_day_on <project> — the day scopes need a project the spend query can
# name and a jobs client.
_bs_day_on() {
  _bs_slug "${1:-}" && command -v _jobs_req >/dev/null 2>&1 \
    && [ -n "${HARNESS_SECRET:-}" ] && [ -n "${JOBS_URL:-}" ]
}

# _bs_spend <project> [stage] — "usd billed_calls" for the worker's UTC day.
# rc 1 = not known. The query string is built from slugs only.
_bs_spend() {
  local p="${1:-}" s="${2:-}" q resp out
  case "$p" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$s" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  q="project=$p"; [ -n "$s" ] && q="$q&stage=$s"
  resp=$(_jobs_req GET "/api/metrics/llm-spend?$q" 2>/dev/null) || return 1
  out=$(printf '%s' "$resp" | jq -r '
    if ([.usd, .calls, .refused, .settled] | map(type == "number") | all)
    then "\(.usd) \([.calls - .refused - .settled, 0] | max)" else empty end' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# _bs_alert_once <flag-suffix> <project> <text> — one alert per flag per box;
# the caller puts the UTC day in the suffix.
_bs_alert_once() {
  local root; root=$(_bs_root)
  [ -n "$root" ] || return 0
  mkdir -p "$root/flags" 2>/dev/null
  ( set -C; : > "$root/flags/alerted-$1" ) 2>/dev/null || return 0
  [ -x "$root/bin/alert-line.sh" ] \
    && "$root/bin/alert-line.sh" --id "$1" --project "$2" "$3" >/dev/null 2>&1 && return 0
  mkdir -p "$root/logs" 2>/dev/null
  echo "$(date -u '+%FT%TZ') [$2] budget alert failed for $1" >> "$root/logs/failovers.log" 2>/dev/null
  return 0
}

# _bs_tightest — reads "scope axis spent cap" lines on stdin, prints the over
# ones, winner first: any build-stage axis beats every day scope (terminal),
# then smallest headroom (cap 0 = minus infinity), first listed wins a tie.
# Prints nothing when no axis is over.
_bs_tightest() {
  awk '
    NF == 4 && ($3 + 0 >= $4 + 0) {
      r = ($4 + 0 == 0) ? -1e300 : ($4 - $3) / $4
      k = ($1 == "build-stage") ? 0 : 1
      n++; l[n] = $0
      if (n == 1 || k < bk || (k == bk && r < best)) { best = r; bk = k; w = n }
    }
    END { if (n) { print l[w]; for (i = 1; i <= n; i++) if (i != w) print l[i] } }'
}

bs_gate() {
  local p="${1:-}" stage="${2:-}" out="${3:-}" inb=0 b="" rc axes="" unread="" over win rest also
  local sdu="" sdc="" pdu="" sp scope axis spent cap name
  BS_LINE=""; BS_REFUSE=""; BS_REASON=""
  _bs_off && return 0
  if bs_applies "$stage" "$out"; then
    inb=1; b=$(dirname "$out")
    if [ -f "$b/BUDGET_STOP" ]; then
      BS_LINE=$(head -1 "$b/BUDGET_STOP" 2>/dev/null | tr -d '\r')
      [ -n "$BS_LINE" ] || BS_LINE="budget_stop $stage marker-present"
      return 1
    fi
    rc=0; _bs_build_eval "$stage" "$b" || rc=$?
    if [ "$rc" = 2 ]; then
      _BB_MC=""; _BB_MU=""; _BB_MT=""
      BS_LINE=$(_bs_line "$stage" "$BS_REASON")
      bs_trip "$p" "$b" "$BS_LINE"
      return 1
    fi
    if [ "$rc" = 0 ]; then
      [ -n "$_BB_MC" ] && axes="${axes}build-stage calls $_BB_CALLS $_BB_MC"$'\n'
      [ -n "$_BB_MU" ] && axes="${axes}build-stage usd $_BB_USD $_BB_MU"$'\n'
      [ -n "$_BB_MT" ] && axes="${axes}build-stage tokens $_BB_TOK $_BB_MT"$'\n'
    fi
  fi
  if _bs_day_on "$p"; then
    # A stage the spend query cannot name has no stage-day scope: a bad name is
    # never a refusal, and "unreadable" inside a build would defer it forever.
    if _bs_slug "$stage"; then
      rc=0; bs_cap "$stage" day_usd >/dev/null || rc=$?
      case "$rc" in 0) sdu="$BS_VALUE" ;; 1) ;; *) unread="$BS_REASON" ;; esac
      rc=0; bs_cap "$stage" day_calls >/dev/null || rc=$?
      case "$rc" in 0) sdc="$BS_VALUE" ;; 1) ;; *) [ -n "$unread" ] || unread="$BS_REASON"; sdu=""; sdc="" ;; esac
    fi
    rc=0; bs_pcap "$p" >/dev/null || rc=$?
    case "$rc" in 0) pdu="$BS_VALUE" ;; 1) ;; *) [ -n "$unread" ] || unread="$BS_REASON" ;; esac
    if [ -n "$sdu$sdc" ]; then
      if sp=$(_bs_spend "$p" "$stage"); then
        [ -n "$sdu" ] && axes="${axes}stage-day usd ${sp% *} $sdu"$'\n'
        [ -n "$sdc" ] && axes="${axes}stage-day calls ${sp#* } $sdc"$'\n'
      else
        [ -n "$unread" ] || unread="budget-total-unreadable:stage-day"
      fi
    fi
    if [ -n "$pdu" ]; then
      if sp=$(_bs_spend "$p"); then
        axes="${axes}project-day usd ${sp% *} $pdu"$'\n'
      else
        [ -n "$unread" ] || unread="budget-total-unreadable:project-day"
      fi
    fi
  fi
  over=$(printf '%s' "$axes" | _bs_tightest)
  win=$(head -1 <<<"$over")
  if [ -n "$unread" ]; then
    if [ "$inb" = 1 ]; then
      # Fail closed in a build. A build-stage axis that is over still stops it
      # (that verdict is certain and terminal); otherwise an over day scope
      # refuses as itself, and with neither the outage refuses.
      case "$win" in
        project-day*|stage-day*|build-stage*) ;;
        *) BS_REFUSE="budget-cap-unreadable $stage $unread"
           if bs_admitted "$b"; then _bs_overrun_note "$b" "$BS_REFUSE"; BS_REFUSE=""; return 0; fi
           return 3 ;;
      esac
    else
      _bs_alert_once "budget-unreadable-$(printf '%s' "$stage-$p" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)" "$p" \
        "[budget-unreadable] $p/$stage: a day budget cap could not be read ($unread); the call was allowed (fail open outside a build). Check the settings cache and GET /api/metrics/llm-spend."
    fi
  fi
  [ -n "$win" ] || return 0
  read -r scope axis spent cap <<<"$win"
  rest=$(printf '%s\n' "$over" | tail -n +2 | awk 'NF == 4 { printf "%s%s %s %s/%s", (n++ ? ", " : ""), $1, $2, $3, $4 }')
  also=""; [ -n "$rest" ] && also=" also over: $rest"
  case "$scope" in
    build-stage)
      BS_LINE="$(_bs_line "$stage" "max_$axis")$also"
      bs_trip "$p" "$b" "$BS_LINE"
      return 1 ;;
    stage-day)
      sp=$(_bs_spend_pair "$axes" stage-day)
      BS_REFUSE="budget-stage-day $stage project=$p stage=$stage $sp$also"
      name="$p-$stage" ;;
    *)
      BS_REFUSE="budget-project-day $stage project=$p usd=$spent/$cap$also"
      name="$p" ;;
  esac
  if [ "$inb" = 1 ] && bs_admitted "$b"; then
    _bs_overrun_note "$b" "$BS_REFUSE"; BS_REFUSE=""; return 0
  fi
  _bs_alert_once "budget-$scope-$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)" "$p" \
    "[budget-$scope] $p: ${BS_REFUSE%% also over:*}. Calls in this scope are refused until 00:00Z; a call already running finishes. Raise the cap with bin/jobs-client.sh setting-set <key> <value>."
  return 2
}

# _bs_spend_pair <axes> <scope> — "usd=<x>/<cap|-> calls=<n>/<cap|->" for the
# stage-day refusal line.
_bs_spend_pair() {
  printf '%s' "$1" | awk -v S="$2" '
    $1 == S && $2 == "usd"   { u = $3 "/" $4 }
    $1 == S && $2 == "calls" { c = $3 "/" $4 }
    END { printf "usd=%s calls=%s", (u == "" ? "-" : u), (c == "" ? "-" : c) }'
}

bs_launch_check() {
  local p="${1:-}" rc cap sp st du dc
  BS_REFUSE=""; BS_REASON=""
  _bs_off && return 0
  _bs_day_on "$p" || return 0
  rc=0; bs_pcap "$p" >/dev/null || rc=$?
  case "$rc" in
    0) cap="$BS_VALUE"
       sp=$(_bs_spend "$p") || { BS_REASON="budget-total-unreadable:project-day"; return 2; }
       if _bs_ge "${sp% *}" "$cap"; then
         BS_REFUSE="budget-project-day project=$p usd=${sp% *}/$cap"; return 1
       fi ;;
    1) ;;
    *) return 2 ;;
  esac
  for st in $BS_BUILD_STAGES; do
    du=""; dc=""
    rc=0; bs_cap "$st" day_usd >/dev/null || rc=$?
    case "$rc" in 0) du="$BS_VALUE" ;; 1) ;; *) return 2 ;; esac
    rc=0; bs_cap "$st" day_calls >/dev/null || rc=$?
    case "$rc" in 0) dc="$BS_VALUE" ;; 1) ;; *) return 2 ;; esac
    [ -n "$du$dc" ] || continue
    sp=$(_bs_spend "$p" "$st") || { BS_REASON="budget-total-unreadable:stage-day"; return 2; }
    if { [ -n "$du" ] && _bs_ge "${sp% *}" "$du"; } || { [ -n "$dc" ] && _bs_ge "${sp#* }" "$dc"; }; then
      BS_REFUSE="budget-stage-day project=$p stage=$st usd=${sp% *}/${du:--} calls=${sp#* }/${dc:--}"
      return 1
    fi
  done
  return 0
}

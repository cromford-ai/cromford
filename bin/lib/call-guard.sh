#!/bin/bash
# bin/lib/call-guard.sh — K3, THE PRE-CALL GUARD: never pay twice for the same
# work. Sourced by bin/agent-call.sh; no side effect at source time beyond
# defining functions.
#
# ── WHY ──────────────────────────────────────────────────────────────────────
# The 09-17..19 audit (docs/HARNESS_SPEND_AND_STATE_AUDIT_2026-09-19.html): one
# PR reviewed 52 times on one head, 460 verdicts on 122 distinct heads, triage
# shards re-run 60-153 times on an unchanged ticket, 152 stale re-plans a day.
# Every one of those loops had a dedup check, read before the call. What failed
# was the STORE: a file on one box. So this guard keeps its count in the D1 jobs
# worker, at the one place every paid call already passes through.
#
# NOT A BUDGET. There is no dollar figure anywhere in this file (the operator: no
# per-ticket dollar budgets). It counts paid CALLS of one piece of WORK.
#
# ── WHAT IT DOES ─────────────────────────────────────────────────────────────
# Before the first rung runs, call_guard_precall claims a slot for
#   (project, guard stage, fingerprint)
# on POST /api/call-guard/claim. The worker counts that key's PAID calls in the
# last CALL_GUARD_WINDOW_S and, in the same statement, either records this one
# or refuses it. A refusal exits 74 (bin/agent-call.sh's "the lane's own gate
# refused it: nothing was called and nothing was billed" — every caller already
# defers on it), with `AGENT_CALL_REFUSED call-guard repeat ...` in $OUT.
# On the way out call_guard_finish settles the row: ok | empty | failed count
# as paid, unbilled (no rung ran) frees the slot. An `empty` result — the vendor
# answered with nothing and billed for it — is a paid call like any other, so
# success-with-nothing-in-it can never loop.
#
# PER-WORK OVERRIDE: AGENT_CALL_GUARD_FORCE=1 (a hand-run path) records the
# call as paid even at the ceiling, and logs FORCED. An operator who wants the
# slate wiped for one piece of work runs `bin/jobs-client.sh call-guard-reset
# <project> <stage> <fp> [reason]` (DELETE /api/call-guard, an audit row).
#
# THE FINGERPRINT is the stable identity of the work. A caller that knows it
# says so: AGENT_CALL_FP (a PR and its head sha, a ticket and its board-state
# digest) and AGENT_CALL_GUARD_STAGE (the family, e.g. triage-shard, when the
# agent-call stage is shared by several lanes). A caller that says nothing gets
#   <ticket>:<cwd git HEAD>:p<prompt sha>
# which only ever matches the IDENTICAL prompt on the IDENTICAL checkout, so the
# fallback can never fold two different pieces of work together (a build's
# review lenses, or a fix round's re-review on a moved head, stay distinct).
#
# THE BUILD FINGERPRINT (BH-2413). A build's prompts embed its own $BUILD dir,
# so under the fallback every new build of one ticket is new work and the guard
# only ever capped repeats inside one build. call_guard_build_fp prints
#   <ticket>:th<sha256 of the ticket body + thread, 16 hex>:m<main sha, 12 hex>
# and bin/lib/rb/plan.sh's CC() hands it to plan, execute and fix, so the
# same plan of the same unchanged ticket on the same main is ONE piece of work
# however many builds buy it. Any missing input means no build fp at all, and
# those calls use the fallback above.
#
# ── WHEN THE COUNTER CANNOT BE READ ──────────────────────────────────────────
# Two different answers, both deliberate, both tested:
#   METERED runner (bin/billing-mode.sh says `metered`: an API key, GROK_BILLING=
#     api, openrouter, fireworks) -> FAIL CLOSED. Nothing is called, rc 74. The
#     primary is refused at the claim; a metered rung further down the ladder
#     is refused at the rung (call_guard_rung_ok), so a subscription primary
#     that fails cannot descend into unguarded cash.
#   SUBSCRIPTION runner -> FAIL OPEN. Liveness over money: a flat-rate lane that
#     stops whenever the worker blinks costs more than the loop this stops.
# "Cannot be read" is an ANSWER we did not get: a transport failure, a timeout,
# a 5xx. A worker that answers 404 "unknown endpoint" has no call-guard route
# yet (a box synced ahead of the worker deploy): that is `unconfigured`, fail
# open for every runner, one warn line a day (ROUTE MISSING). A box with NO coordination DB configured (no
# jobs-client, or JOBS_URL empty on purpose) is `unconfigured`: the guard does
# not engage at all, exactly as before this shipped. That box is a fork or a
# fixture, and jobs-client already says so once a day.
#
# ── KNOBS (catalog/lanes.d/_lib.call-guard.json; settings rows
#    lib.call-guard.<env lowercased>, applied by agent-call.sh through
#    lib_env_apply call-guard; each read below keeps its code default) ─────────
#   CALL_GUARD                    1 | 0 — the global kill switch (also the
#                                 switch call-guard-off: a switch.call-guard-off
#                                 settings row, else the file flags/call-guard-off)
#   CALL_GUARD_STAGES             which guard stages are enforced: a space/comma
#                                 list, `all`, or `none`. Default (BH-2305):
#                                 review triage-shard mc-rereview plan preplan
#                                 execute fix triage prodqa lead-review, plus
#                                 (BH-2603) the raw-claude families
#                                 orchestrator box-chat greenfield, and
#                                 (BH-3930) review-head lead-head, the
#                                 head-bound review stages: K=1 on the shared
#                                 per-head fp review:<slug>#<n>@<sha> /
#                                 lead:..., a named ~reason suffix being the
#                                 paid exception (bin/lib/review-bought.sh;
#                                 each lane moves onto them in its own
#                                 ticket). Each has its own K in
#                                 CALL_GUARD_MAX_MAP. A row
#                                 narrows the set; the default only reaches a
#                                 box without one.
#   CALL_GUARD_MAX_MAP            stage=K pairs, `default=` for the rest. K is
#                                 the paid calls one fingerprint may have in the
#                                 window. K=0 turns that stage off.
#   CALL_GUARD_WINDOW_S           the window, seconds (86400)
#   CALL_GUARD_FAIL_CLOSED_METERED  1 | 0 — refuse a metered call when the
#                                 counter is unreadable (1)
#   CALL_GUARD_TIMEOUT_S          the claim's worker timeout, seconds (5)
#
# Deterministic. No model is ever asked anything on this path.

CALL_GUARD_STAGES_DEFAULT="review triage-shard mc-rereview plan preplan execute fix triage prodqa lead-review orchestrator box-chat greenfield review-head lead-head"
CALL_GUARD_MAX_MAP_DEFAULT="review=2 triage-shard=2 mc-rereview=5 triage=2 plan=3 preplan=2 execute=3 fix=3 prodqa=2 lead-review=2 orchestrator=6 box-chat=3 greenfield=2 review-head=1 lead-head=1 default=2"

CG_STATE=""; CG_STAGE=""; CG_FP=""; CG_MAX=""; CG_COUNT=""; CG_CALL_ID=""
CG_REASON=""; CG_TOP=""; CG_SETTLED=""

_cg_h()     { printf '%s' "${HARNESS:-/root/harness}"; }
_cg_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
_cg_day()   { date -u '+%Y%m%d'; }
_cg_log() {
  local h; h=$(_cg_h)
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s [call-guard] %s\n' "$(_cg_stamp)" "$1" >> "$h/logs/call-guard.log" 2>/dev/null
}
_cg_slug() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'; }

# call_guard_stage <agent-call-stage> — the GUARD stage: the caller's family
# name when it gave one, else the agent-call stage.
call_guard_stage() {
  local s="${AGENT_CALL_GUARD_STAGE:-${1:-}}"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_' | cut -c1-64
}

# call_guard_map_get <map> <stage> — the value for <stage>, else `default=`.
# read -a, not an unquoted split: a settings row is operator text.
call_guard_map_get() {
  local map="${1:-}" st="${2:-}" w k v def="" words=()
  read -r -a words <<<"$(printf '%s' "$map" | tr ',' ' ')"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in *=*) ;; *) continue ;; esac
    k="${w%%=*}"; v="${w#*=}"
    [ "$k" = "$st" ] && { printf '%s' "$v"; return 0; }
    [ "$k" = default ] && def="$v"
  done
  printf '%s' "$def"
}

# call_guard_max <guard-stage> — K for the stage; anything not a whole number
# is 0 (off), said in the log, never guessed upward.
call_guard_max() {
  local v
  v=$(call_guard_map_get "${CALL_GUARD_MAX_MAP:-$CALL_GUARD_MAX_MAP_DEFAULT}" "${1:-}")
  case "$v" in
    ''|*[!0-9]*) [ -n "$v" ] && _cg_log "CALL_GUARD_MAX_MAP gives '$v' for ${1:-?} — not a whole number, the stage is OFF"
                 printf 0 ;;
    *) printf '%s' "$((10#$v))" ;;
  esac
}

# call_guard_enabled <guard-stage> — rc 0 when the guard is enforced for it.
call_guard_enabled() {
  local st="${1:-}" list
  [ -n "$st" ] || return 1
  [ "${CALL_GUARD:-1}" = 0 ] && return 1
  # The switch is a settings row before it is a file (BH-2432). Loaded here, not
  # at source time, so sourcing this lib alone still loads nothing else.
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null || true
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }
  fi
  HARNESS="$(_cg_h)" lane_switch call-guard-off file && return 1
  list=" $(printf '%s' "${CALL_GUARD_STAGES:-$CALL_GUARD_STAGES_DEFAULT}" | tr ',' ' ') "
  case "$list" in *" none "*) return 1 ;; esac
  case "$list" in *" all "*|*" $st "*) ;; *) return 1 ;; esac
  [ "$(call_guard_max "$st")" -gt 0 ]
}

# call_guard_fp <prompt-sha> — the work's fingerprint (see the header).
call_guard_fp() {
  local fp="${AGENT_CALL_FP:-}" tk head
  if [ -z "$fp" ]; then
    tk="${AGENT_CALL_TICKET:-${HARNESS_TICKET:-}}"
    head=$(git rev-parse --short=12 HEAD 2>/dev/null) || head=""
    case "$head" in *[!0-9a-f]*) head="" ;; esac
    fp="${tk:--}:${head:--}:p$(printf '%s' "${1:-}" | cut -c1-16)"
  fi
  printf '%s' "$fp" | tr -c 'A-Za-z0-9._:@/#+=-' '_' | cut -c1-300
}

# call_guard_build_fp <key> <base-sha> < material — the build fingerprint (see
# the header). rc 1 and nothing printed when the key is empty, the material is
# empty or whitespace, or the sha is not at least 7 lowercase hex characters:
# a missing input is no fingerprint, never a fingerprint of nothing.
call_guard_build_fp() {
  local key="${1:-}" sha="${2:-}" mat
  [ -n "$key" ] || return 1
  case "$sha" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#sha}" -ge 7 ] || return 1
  mat=$(cat)
  [ -n "${mat//[[:space:]]/}" ] || return 1
  printf '%s:th%s:m%s\n' "$key" "$(printf '%s' "$mat" | sha256sum | cut -c1-16)" "${sha:0:12}"
}

# call_guard_metered <runner> — rc 0 when a call on it costs CASH on this box.
# bin/billing-mode.sh is the one answer to that question in this fleet; a box
# without it knows at least that openrouter and fireworks have no flat tier.
call_guard_metered() {
  local r="${1:-}" m=""
  if [ -x "$(_cg_h)/bin/billing-mode.sh" ]; then
    m=$(eval "${ACCT_EXPORTS:-}"; "$(_cg_h)/bin/billing-mode.sh" "$r" 2>/dev/null)
  else
    case "$r" in openrouter|fireworks) m=metered ;; esac
  fi
  [ "$m" = metered ]
}

_cg_call_id() {
  local u=""
  command -v cost_row_uuid >/dev/null 2>&1 && u=$(cost_row_uuid)
  [ -n "$u" ] || u="$(_cg_slug "${JOBS_BOX:-$(hostname 2>/dev/null)}")-$$-$(date +%s%N 2>/dev/null)"
  printf '%s' "$u"
}

# _cg_once <kind> <project> <stage> <line> — ONE ALERTS line per (kind,
# project, stage) per UTC day. The line lands in the WARN digest by
# bin/lib/alert-state.sh's builtin severity rule for `[call-guard]` — never a
# triaged:true beat, which pages at once. The flag is set before the line.
_cg_once() {
  local h f
  h=$(_cg_h)
  f="$h/flags/alerted-call-guard-$(_cg_slug "$1-$2-$3")-$(_cg_day)"
  [ -f "$f" ] && return 0
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null
  touch "$f" 2>/dev/null
  printf '%s %s\n' "$(_cg_stamp)" "$4" >> "$h/logs/ALERTS.log" 2>/dev/null
  # Yesterday's markers of this family are dead weight.
  find "$h/flags" -maxdepth 1 -type f -name 'alerted-call-guard-*' ! -name "*-$(_cg_day)" -delete 2>/dev/null
  return 0
}

# call_guard_precall <agent-call-stage> <project> <primary-runner> <prompt-sha>
#   rc 0 -> run the call. rc 1 -> REFUSE it (CG_REASON says why; nothing has
#   been called). Sets CG_STATE: off | unconfigured | allowed | refused |
#   unreadable.
call_guard_precall() {
  local stage="${1:-}" project="${2:-}" runner="${3:-}" psha="${4:-}" resp win to allowed force crc
  CG_STATE=off; CG_REASON=""; CG_CALL_ID=""; CG_COUNT=""; CG_TOP=""; CG_SETTLED=""
  CG_STAGE=$(call_guard_stage "$stage")
  call_guard_enabled "$CG_STAGE" || return 0
  CG_MAX=$(call_guard_max "$CG_STAGE")
  CG_FP=$(call_guard_fp "$psha")
  if ! command -v call_guard_claim >/dev/null 2>&1 || [ -z "${JOBS_URL:-}" ]; then
    CG_STATE=unconfigured
    return 0
  fi
  win="${CALL_GUARD_WINDOW_S:-86400}"; case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  to="${CALL_GUARD_TIMEOUT_S:-5}";     case "$to"  in ''|*[!0-9]*|0) to=5 ;; esac
  CG_CALL_ID=$(_cg_call_id)
  force=0
  if [ "${AGENT_CALL_GUARD_FORCE:-0}" = 1 ]; then
    # An LLM session (IS_SANDBOX=1, what every agent session on the fleet runs
    # under) cannot force its OWN calls through the guard: the override is for
    # a human's hand-run path.
    if [ "${IS_SANDBOX:-0}" = 1 ]; then
      _cg_log "FORCE ignored [$project] $CG_STAGE fp=$CG_FP: AGENT_CALL_GUARD_FORCE=1 inside a sandboxed (IS_SANDBOX=1) session"
    else
      force=1
    fi
  fi
  resp=$(JOBS_TIMEOUT="$to" call_guard_claim "$project" "$CG_STAGE" "$CG_FP" "$CG_CALL_ID" "$CG_MAX" "$win" "$runner" "$force" 2>/dev/null); crc=$?
  if [ "$crc" = 2 ]; then
    # THE ROUTE IS NOT DEPLOYED on this worker (404 "unknown endpoint"): a box
    # synced ahead of the worker. That is `unconfigured`, not an outage — a
    # metered lane must not stop fleet-wide on a deploy-order gap. Fail open,
    # one warn line a day. Timeouts and 5xx stay `unreadable` (below).
    CG_STATE=unconfigured; CG_CALL_ID=""
    _cg_log "no call-guard route on the worker [$project] $CG_STAGE — running UNGUARDED (deploy the worker)"
    _cg_once noroute "$project" "$CG_STAGE" \
      "[call-guard] ROUTE MISSING [$project] $CG_STAGE: the harness-jobs worker has no /api/call-guard route (404), so calls run UNGUARDED until it is deployed. Deploy worker/jobs (bin/harness-sync.sh) — the worker goes out BEFORE the boxes (docs/CALL-GUARD.md)."
    return 0
  fi
  if [ "$crc" = 0 ]; then
    allowed=$(printf '%s' "$resp" | jq -r '.allowed' 2>/dev/null)
    CG_COUNT=$(printf '%s' "$resp" | jq -r '.count // ""' 2>/dev/null)
    if [ "$allowed" = true ]; then
      CG_STATE=allowed
      [ "$force" = 1 ] && _cg_log "FORCED [$project] $CG_STAGE fp=$CG_FP paid=${CG_COUNT:-?}/$CG_MAX (AGENT_CALL_GUARD_FORCE=1) — recorded as paid"
      return 0
    fi
    CG_STATE=refused
    CG_TOP=$(printf '%s' "$resp" | jq -r '[.top[]? | "\(.fp) (paid \(.paid), refused \(.refused))"] | join("; ")' 2>/dev/null)
    CG_REASON="call-guard:repeat"
    _cg_log "REFUSED [$project] $CG_STAGE fp=$CG_FP paid=${CG_COUNT:-?}/$CG_MAX in ${win}s runner=$runner — nothing called"
    _cg_once repeat "$project" "$CG_STAGE" \
      "[call-guard] REPEAT CALLS REFUSED [$project] $CG_STAGE: fingerprint $CG_FP already had ${CG_COUNT:-?} paid call(s) in the last $((win / 3600))h (ceiling $CG_MAX), so the call was refused before anything was bought. Top repeat fingerprints: ${CG_TOP:-$CG_FP}. Every later refusal today is in logs/call-guard.log. Knobs: lib.call-guard.call_guard_max_map / call_guard_stages, or CALL_GUARD=0."
    return 1
  fi
  CG_STATE=unreadable; CG_CALL_ID=""
  if [ "${CALL_GUARD_FAIL_CLOSED_METERED:-1}" != 0 ] && call_guard_metered "$runner"; then
    CG_REASON="call-guard:counter-unreadable"
    _cg_log "REFUSED [$project] $CG_STAGE fp=$CG_FP: counter unreadable and runner $runner is METERED — fail-closed, nothing called"
    _cg_once unreadable "$project" "$CG_STAGE" \
      "[call-guard] COUNTER UNREADABLE [$project] $CG_STAGE: the harness-jobs call-guard counter did not answer, so a call on the METERED runner $runner was refused (fail-closed; nothing billed). Subscription lanes keep running unguarded until it answers. Check the worker (bin/jobs-client.sh call-guard) or set CALL_GUARD_FAIL_CLOSED_METERED=0."
    return 1
  fi
  _cg_log "counter unreadable [$project] $CG_STAGE fp=$CG_FP — runner $runner is not metered, running UNGUARDED (fail-open)"
  return 0
}

# call_guard_peek <agent-call-stage> <project> — BH-7792: the guard's answer for
#   the work AGENT_CALL_FP names, WITHOUT a claim (GET /api/call-guard?fp=, no
#   row written, nothing spent). rc 0 and `<paid>/<max>` on stdout when a call
#   now would be refused (paid >= max in the window). rc 1 otherwise, and also
#   when the guard is off for the stage, unconfigured or unreadable: then the
#   claim at the call decides, as before.
call_guard_peek() {
  local st fp max win resp paid
  st=$(call_guard_stage "${1:-}")
  call_guard_enabled "$st" || return 1
  command -v call_guard_list >/dev/null 2>&1 && [ -n "${JOBS_URL:-}" ] || return 1
  max=$(call_guard_max "$st"); fp=$(call_guard_fp "")
  win="${CALL_GUARD_WINDOW_S:-86400}"; case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  resp=$(JOBS_TIMEOUT="${CALL_GUARD_TIMEOUT_S:-5}" call_guard_list "${2:-}" "$st" "$(( (win + 3599) / 3600 ))" "$fp" 2>/dev/null) || return 1
  paid=$(printf '%s' "$resp" | jq -r --arg f "$fp" '[.rows[]? | select(.fp == $f) | .paid] | add // 0' 2>/dev/null)
  case "$paid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$paid" -ge "$max" ] || return 1
  printf '%s/%s' "$paid" "$max"
}

# call_guard_rung_ok <runner> — rc 1 when a LOWER rung must not run: the
# counter was unreadable and this rung costs cash. Every other state is rc 0 —
# an allowed claim covers the whole call, whichever rung serves it.
call_guard_rung_ok() {
  [ "$CG_STATE" = unreadable ] || return 0
  [ "${CALL_GUARD_FAIL_CLOSED_METERED:-1}" != 0 ] || return 0
  call_guard_metered "${1:-}" || return 0
  CG_REASON="call-guard:counter-unreadable"
  _cg_log "rung ${1:-?} refused: counter unreadable and the rung is METERED — fail-closed"
  return 1
}

# call_guard_finish <rc> <any-ran> <outfile> [nothing-billed] — settle once.
#   unbilled  no rung ran at all (every rung refused / routed before a call),
#             or [nothing-billed]: the call failed and agent-call.sh's
#             cg_nothing_billed found only SUBSCRIPTION runners failing on
#             quota / credits / auth / a named 429 — nothing was billed
#   ok        rc 0 and a non-whitespace byte in <outfile>
#   empty     rc 0 and <outfile> blank: billed, and TERMINAL (it keeps its slot)
#   failed    anything else that ran
call_guard_finish() {
  local rc="${1:-1}" ran="${2:-}" out="${3:-}" nobill="${4:-}" oc
  [ "$CG_STATE" = allowed ] && [ -n "$CG_CALL_ID" ] && [ -z "$CG_SETTLED" ] || return 0
  CG_SETTLED=1
  if [ -z "$ran" ]; then oc=unbilled
  elif [ "$rc" != 0 ] && [ -n "$nobill" ]; then
    # a subscription lane's quota / auth / 429 failure: nothing was billed
    oc=unbilled
    _cg_log "settled UNBILLED: $CG_STAGE fp=$CG_FP failed rc=$rc on a subscription lane's quota/auth/rate limit — the slot is not spent"
  elif [ "$rc" = 0 ] && grep -q '[^[:space:]]' "$out" 2>/dev/null; then oc=ok
  elif [ "$rc" = 0 ]; then oc=empty
  else oc=failed; fi
  command -v call_guard_settle >/dev/null 2>&1 || return 0
  JOBS_TIMEOUT="${CALL_GUARD_TIMEOUT_S:-5}" call_guard_settle "$CG_CALL_ID" "$oc" >/dev/null 2>&1 \
    || _cg_log "settle $CG_CALL_ID=$oc did not land — the row stays claimed and counts as paid"
  return 0
}

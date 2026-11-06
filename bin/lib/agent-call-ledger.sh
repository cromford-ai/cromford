# shellcheck shell=bash
# bin/lib/agent-call-ledger.sh — BH-9064, DEDUP BEFORE SPEND. Sourced by
# bin/agent-call.sh (beside bin/lib/call-guard.sh) and bin/claude-cost.sh. No
# side effect at source time beyond defining functions and loading the jobs
# client file bin/lib/jobs/agent-call-ledger.sh.
#
# ── WHY ──────────────────────────────────────────────────────────────────────
# K3 (bin/lib/call-guard.sh) COUNTS paid calls per piece of work and refuses at
# a ceiling, but it stores no answer and has no terminal states: 3,021 calls
# repeated one fingerprint inside 60 minutes in the week to 2026-11-04 ($2,225),
# and 278 calls that ended rc != 0 still cost $1,322. The metered-API rule asks
# for a persisted check before the billable call, three terminal states and an
# attempt cap. This is that check. Its store is the jobs worker (D1 table
# agent_call_ledger), not a file on one box: a fly-pool machine is gone after
# one build, so a box-local store never sees the repeat.
#
# ── WHAT IT DOES ─────────────────────────────────────────────────────────────
# acl_precall asks POST /api/agent-call-ledger/begin for (project, guard stage,
# fingerprint) BEFORE the model call. The worker answers in one upsert:
#   run       go ahead; the row is `running` and this is one more attempt.
#   replay    an `ok` answer inside AGENT_LEDGER_WINDOW_S, for a stage whose
#             deliverable is the answer text (AGENT_LEDGER_REPLAY_STAGES). The
#             stored answer comes back, no call.
#   terminal  `empty` (billed and blank: terminal at once), `failed` at
#             AGENT_LEDGER_MAX_ATTEMPTS, `running` inside AGENT_LEDGER_RUNNING_
#             TTL_S (another box is buying it now) or `parked`. The stored rc
#             comes back (74 when none is stored), with one log line, no call.
# acl_finish settles the row with what happened: ok (with the answer), empty,
# failed, or unbilled (nothing was bought: the attempt is given back).
#
# A REPLAY NEEDS A FINGERPRINT THE CALLER CHOSE. A call with no AGENT_CALL_FP
# is keyed on call_guard_fp "$PROMPT_SHA" (K3's own fallback: ticket, checkout
# HEAD and prompt sha; the guard stage is the row's key column), so every call
# is keyed and its terminal states hold. But that key is never replayed: the
# run-build review lenses run stage `review` with no fp, and their deliverable
# is the review.md FILE their session writes, not the text this returns (the
# BH-1037 lesson in bin/agent-call.sh's choke_guard). Agentic stages (execute,
# fix) are not replay stages either: a replayed transcript makes none of the
# edits.
#
# AN ANSWER OVER AGENT_LEDGER_ANSWER_MAX_BYTES is settled `ok` with no body and
# its size in answer_bytes. It never replays: a miss costs one more purchase,
# never a wrong answer. Nothing is copied to the box.
#
# ── WHEN THE WORKER CANNOT BE READ ───────────────────────────────────────────
# The ledger never refuses on its own read failure. No JOBS_URL, no client, a
# 404 (the route is not deployed yet: one warn line a day in
# logs/agent-call-ledger.log), a timeout, a 5xx or an answer that is not a
# decision: ACL_DECISION=run and the call runs. K3 applies its own fail-open /
# fail-closed rules before this, unchanged.
#
# ── KNOBS (catalog/lanes.d/_lib.agent-call-ledger.json; settings rows
#    lib.agent-call-ledger.<env lowercased>; each read keeps its code default) ─
#   AGENT_LEDGER                 1 | 0, the switch (also the switch agent-ledger-off:
#                                a switch.agent-ledger-off settings row, else the
#                                file flags/agent-ledger-off)
#   AGENT_LEDGER_STAGES          guard stages the ledger keys (default: K3's
#                                stages plus canary; `all` | `none`)
#   AGENT_LEDGER_REPLAY_STAGES   guard stages whose ok answer replays
#   AGENT_LEDGER_WINDOW_S        the replay and attempt window (3600)
#   AGENT_LEDGER_CANARY_WINDOW_S the window of a stage-canary call with a caller
#                                fp (86400): the auth canary's day fp
#   AGENT_LEDGER_MAX_ATTEMPTS    failed attempts before terminal (3). A
#                                stage's cap is never below its K3 ceiling
#                                (call_guard_max: orchestrator=6), so K3 refuses
#                                first, rc 74, and a fallback ladder that K3
#                                allows (2 models x 3 accounts) is never cut
#                                short by the ledger (acl_max_attempts).
#   AGENT_LEDGER_RUNNING_TTL_S   how long a `running` row holds the work (7200)
#   AGENT_LEDGER_ANSWER_MAX_BYTES  answer bytes stored in the D1 row (262144)
#   AGENT_LEDGER_TIMEOUT_S       the worker timeout of one request (5)
# The code defaults below are the documented fallbacks of those rows.
# Deterministic. No model is ever asked anything on this path.

_ACL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=bin/lib/jobs/agent-call-ledger.sh
[ -r "$_ACL_LIB_DIR/jobs/agent-call-ledger.sh" ] && . "$_ACL_LIB_DIR/jobs/agent-call-ledger.sh"

# Code fallbacks of the lib.agent-call-ledger.* rows (catalog/lanes.d/_lib.agent-call-ledger.json).
ACL_DEF_WINDOW_S=3600
# lib.agent-call-ledger.agent_ledger_canary_window_s: the auth canary names a day
# fp (canary:<runner>:<account>:<UTC day>) and runs every hour, so its answer
# must replay for the whole day, not for one hour.
ACL_DEF_CANARY_WINDOW_S=86400
ACL_DEF_MAX_ATTEMPTS=3
ACL_DEF_RUNNING_TTL_S=7200
ACL_DEF_ANSWER_MAX_BYTES=262144
ACL_DEF_TIMEOUT_S=5
ACL_DEF_REPLAY_STAGES="review lead-review triage-shard canary mc-rereview"

ACL_STATE=""; ACL_STAGE=""; ACL_FP=""; ACL_FP_SRC=""; ACL_DECISION=""; ACL_RESP=""
ACL_STATUS=""; ACL_ATTEMPTS=""; ACL_RC=""; ACL_SETTLED=""; ACL_PROJECT=""

_acl_h()     { printf '%s' "${HARNESS:-${H:-}}"; }
_acl_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
_acl_log() {
  local h; h=$(_acl_h); [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s %s\n' "$(_acl_stamp)" "$1" >> "$h/logs/agent-call-ledger.log" 2>/dev/null
}
_acl_int() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac; }
_acl_in_list() { # _acl_in_list <word> <list>
  case " $(printf '%s' "${2:-}" | tr ',' ' ') " in *" none "*) return 1 ;; *" all "*|*" ${1:-} "*) return 0 ;; esac
  return 1
}
_acl_timeout() { _acl_int "${AGENT_LEDGER_TIMEOUT_S:-}" "$ACL_DEF_TIMEOUT_S"; }

# acl_max_attempts <guard-stage> — the attempt cap of the stage: the larger of
# AGENT_LEDGER_MAX_ATTEMPTS and K3's own ceiling for the stage (call_guard_max).
# K3 sizes each ceiling to the ladder of that stage (orchestrator=6 is 2 models
# x (2 named accounts + the default token), all on one fp). A lower ledger cap
# would refuse the rung that makes the turn answer, with the stored rc and not
# K3's rc 74.
acl_max_attempts() {
  local m k
  m=$(_acl_int "${AGENT_LEDGER_MAX_ATTEMPTS:-}" "$ACL_DEF_MAX_ATTEMPTS")
  if command -v call_guard_max >/dev/null 2>&1; then
    k=$(_acl_int "$(call_guard_max "${1:-}" 2>/dev/null)" 0)
    [ "$k" -gt "$m" ] && m="$k"
  fi
  [ "$m" -ge 1 ] || m=1
  printf '%s' "$m"
}

# acl_stage <agent-call-stage> — the guard stage, exactly as K3 names it.
acl_stage() {
  if command -v call_guard_stage >/dev/null 2>&1; then call_guard_stage "${1:-}"; return; fi
  printf '%s' "${AGENT_CALL_GUARD_STAGE:-${1:-}}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_' | cut -c1-64
}

# acl_computed_fp <prompt-sha> — the fingerprint of a call whose caller named
# none: K3's own call_guard_fp, so K3 and the ledger key one piece of work
# alike. The fallback (no call-guard.sh on the box) prints the same string.
acl_computed_fp() {
  if command -v call_guard_fp >/dev/null 2>&1; then call_guard_fp "${1:-}"; return; fi
  local tk head
  tk="${AGENT_CALL_TICKET:-${HARNESS_TICKET:-}}"
  head=$(git rev-parse --short=12 HEAD 2>/dev/null) || head=""
  case "$head" in *[!0-9a-f]*) head="" ;; esac
  printf '%s:%s:p%s' "${tk:--}" "${head:--}" "$(printf '%s' "${1:-}" | cut -c1-16)" \
    | tr -c 'A-Za-z0-9._:@/#+=-' '_' | cut -c1-300
}

# acl_fp <prompt-sha> — sets ACL_FP and ACL_FP_SRC (caller|computed).
acl_fp() {
  if [ -n "${AGENT_CALL_FP:-}" ]; then
    ACL_FP=$(printf '%s' "$AGENT_CALL_FP" | tr -c 'A-Za-z0-9._:@/#+=-' '_' | cut -c1-300); ACL_FP_SRC=caller
  else
    ACL_FP=$(acl_computed_fp "${1:-}"); ACL_FP_SRC=computed
  fi
}

acl_enabled() { # acl_enabled <guard-stage>
  [ -n "${1:-}" ] || return 1
  [ "${AGENT_LEDGER:-1}" = 1 ] || return 1
  # The switch is a settings row before it is a file (lane_switch, BH-2432).
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$_ACL_LIB_DIR/lane-switch.sh" 2>/dev/null || true
  fi
  command -v lane_switch >/dev/null 2>&1 && HARNESS="$(_acl_h)" lane_switch agent-ledger-off file && return 1
  _acl_in_list "$1" "${AGENT_LEDGER_STAGES:-${CALL_GUARD_STAGES_DEFAULT:-review triage-shard mc-rereview plan preplan execute fix triage prodqa lead-review orchestrator box-chat greenfield review-head lead-head} canary}"
}

# acl_replay_ok <guard-stage> — rc 0 when an ok answer of this call may replay.
acl_replay_ok() {
  [ "$ACL_FP_SRC" = caller ] || return 1
  [ "${ACL_NO_REPLAY:-0}" = 1 ] && return 1
  _acl_in_list "${1:-}" "${AGENT_LEDGER_REPLAY_STAGES:-$ACL_DEF_REPLAY_STAGES}"
}

# _acl_route_missing <project> <stage> — one warn line per box per UTC day in
# logs/agent-call-ledger.log when the worker has no ledger route (a box synced
# ahead of the worker deploy). The log is its own once-a-day marker.
_acl_route_missing() {
  local h day
  h=$(_acl_h); [ -n "$h" ] || return 0
  day=$(date -u +%Y-%m-%d)
  grep -q "^$day .*ROUTE MISSING" "$h/logs/agent-call-ledger.log" 2>/dev/null && return 0
  _acl_log "WARN ROUTE MISSING [$1] $2: the harness-jobs worker has no /api/agent-call-ledger route (404), so calls run with no dedup ledger until it is deployed (bin/harness-sync.sh). One line a day."
}

# acl_precall <agent-call-stage> <project> <prompt-sha>
#   rc 0 -> run the call. ACL_DECISION=run. ACL_STATE is run (a row was
#           opened), or off | unconfigured | unreadable (no row: fail open).
#   rc 1 -> do NOT call: ACL_DECISION is replay or terminal, and ACL_RESP holds
#           the worker's answer. The caller hands it back (acl_agent_call_exit).
acl_precall() {
  local stage="${1:-}" project="${2:-}" psha="${3:-}" resp rc replay=0 win
  ACL_STATE=off; ACL_DECISION=run; ACL_RESP=""; ACL_STATUS=""; ACL_ATTEMPTS=""; ACL_RC=""; ACL_SETTLED=""
  ACL_PROJECT="$project"
  ACL_STAGE=$(acl_stage "$stage")
  acl_fp "$psha"
  acl_enabled "$ACL_STAGE" || return 0
  if ! command -v acl_req_begin >/dev/null 2>&1 || [ -z "${JOBS_URL:-}" ]; then
    ACL_STATE=unconfigured; return 0
  fi
  acl_replay_ok "$ACL_STAGE" && replay=1
  if [ "$ACL_STAGE" = canary ] && [ "$ACL_FP_SRC" = caller ]; then
    win=$(_acl_int "${AGENT_LEDGER_CANARY_WINDOW_S:-}" "$ACL_DEF_CANARY_WINDOW_S")
  else
    win=$(_acl_int "${AGENT_LEDGER_WINDOW_S:-}" "$ACL_DEF_WINDOW_S")
  fi
  resp=$(JOBS_TIMEOUT="$(_acl_timeout)" acl_req_begin "$project" "$ACL_STAGE" "$ACL_FP" \
    "$(acl_max_attempts "$ACL_STAGE")" "$win" \
    "$(_acl_int "${AGENT_LEDGER_RUNNING_TTL_S:-}" "$ACL_DEF_RUNNING_TTL_S")" "$replay" 2>/dev/null); rc=$?
  if [ "$rc" = 2 ]; then
    ACL_STATE=unconfigured
    _acl_route_missing "$project" "$ACL_STAGE"
    return 0
  fi
  if [ "$rc" != 0 ]; then
    ACL_STATE=unreadable
    _acl_log "[$project] $ACL_STAGE fp=$ACL_FP: ledger unreadable — the call runs (the ledger never refuses on its own read failure)"
    return 0
  fi
  ACL_RESP="$resp"
  ACL_STATUS=$(printf '%s' "$resp" | jq -r '.status // ""')
  ACL_ATTEMPTS=$(printf '%s' "$resp" | jq -r '.attempts // ""')
  ACL_RC=$(printf '%s' "$resp" | jq -r '.rc // "" | tostring')
  [ "$ACL_RC" = null ] && ACL_RC=""
  case "$(printf '%s' "$resp" | jq -r '.decision')" in
    run) ACL_STATE=run; return 0 ;;
    replay)   ACL_STATE=replay;   ACL_DECISION=replay;   return 1 ;;
    terminal) ACL_STATE=terminal; ACL_DECISION=terminal; return 1 ;;
  esac
  ACL_STATE=unreadable
  return 0
}

# acl_answer_to <file> — write the replayed answer to <file>. rc 1 (a MISS)
# when the body is blank or absent. A miss costs one more purchase; a phantom
# answer costs the window.
acl_answer_to() {
  local f="${1:-}"
  [ -n "$f" ] || return 1
  printf '%s' "$ACL_RESP" | jq -e '(.answer_body // "") | test("[^[:space:]]")' >/dev/null 2>&1 || return 1
  printf '%s' "$ACL_RESP" | jq -j '.answer_body' > "$f" 2>/dev/null
}

# acl_refusal_line — the first line of a terminal refusal. The first words are
# K3's repeat marker on purpose: every reader that defers on "this work was
# already bought" (triage-shard, box-chat, rt/, the build stages) routes it with
# no edit. `ledger-<status>` says which store answered.
acl_refusal_line() {
  printf 'AGENT_CALL_REFUSED call-guard repeat ledger-%s attempts=%s fp=%s\n' "$ACL_STATUS" "${ACL_ATTEMPTS:-?}" "$ACL_FP"
}

# acl_terminal_rc — the rc a terminal row hands back: the stored rc of an
# `empty` (0) or `failed` row, else 74 (agent-call's before-billing code).
acl_terminal_rc() {
  case "$ACL_STATUS" in
    empty)  _acl_int "$ACL_RC" 0 ;;
    failed) _acl_int "$ACL_RC" 74 ;;
    *)      printf '74' ;;
  esac
}

# acl_agent_call_exit <outfile> — bin/agent-call.sh's half of a replay or a
# terminal: hand the stored answer back and EXIT. Returns (and the call runs)
# only when a replay turns out to be a miss. The runner list check uses
# runner_allowed, the K3 settle call_guard_finish and the zero-cost row
# ac_refused_row, each when defined.
acl_agent_call_exit() {
  local out="${1:-}" runner model rc
  runner=$(printf '%s' "$ACL_RESP" | jq -r '.runner // ""')
  model=$(printf '%s' "$ACL_RESP" | jq -r '.model // ""')
  if [ "$ACL_STATE" = replay ]; then
    # The caller's own lane list applies to a replay too (BH-1019): a row a
    # wide-open ladder bought is not an answer to a claude-only ask.
    if command -v runner_allowed >/dev/null 2>&1 && ! runner_allowed "${runner:-claude}"; then
      _acl_log "[$ACL_PROJECT] $ACL_STAGE: LEDGER MISS fp=$ACL_FP served-by=${runner:-?} is outside AGENT_CALL_RUNNERS — the call runs"
      ACL_STATE=off; ACL_DECISION=run; return 0
    fi
    if ! acl_answer_to "$out.acl.$$"; then
      rm -f "$out.acl.$$" 2>/dev/null
      _acl_log "[$ACL_PROJECT] $ACL_STAGE: LEDGER MISS fp=$ACL_FP — the ok row has no answer to hand back; the call runs"
      ACL_STATE=off; ACL_DECISION=run; return 0
    fi
    mv -f "$out.acl.$$" "$out" 2>/dev/null || { rm -f "$out.acl.$$"; ACL_STATE=off; ACL_DECISION=run; return 0; }
    [ -n "$runner" ] && printf '%s\n' "$runner" > "$out.runner" 2>/dev/null
    [ -n "$model" ]  && printf '%s\n' "$model"  > "$out.model"  2>/dev/null
    printf 'ok agent-call-ledger %s\n' "$ACL_FP" > "$out.replay" 2>/dev/null
    # The sidecars describe a run that did not happen (the choke_lookup list).
    rm -f "$out.json" "$out.err" "$out.events" "$out.account" "$out.envelope" "$out.session" 2>/dev/null
    rc=$(_acl_int "$ACL_RC" 0)
    command -v call_guard_finish >/dev/null 2>&1 && call_guard_finish 0 "" "$out"
    _acl_log "[$ACL_PROJECT] $ACL_STAGE: LEDGER REPLAY fp=$ACL_FP age=$(printf '%s' "$ACL_RESP" | jq -r '.age_s // "?"')s attempts=${ACL_ATTEMPTS:-?} served-by=${runner:-?}/${model:-?} — no vendor call"
    command -v ac_refused_row >/dev/null 2>&1 && ac_refused_row "agent-call-ledger:replay" 2>/dev/null
    exit "$rc"
  fi
  # terminal
  rm -f "$out.json" "$out.events" "$out.account" "$out.envelope" "$out.session" "$out.replay" 2>/dev/null
  if [ "$ACL_STATUS" = empty ]; then
    # Billed and blank: the honest replay of a blank answer is a blank answer.
    : > "$out" 2>/dev/null; rm -f "$out.err" 2>/dev/null
  else
    acl_refusal_line | tee "$out.err" > "$out" 2>/dev/null
  fi
  rc=$(acl_terminal_rc)
  command -v call_guard_finish >/dev/null 2>&1 && call_guard_finish 0 "" "$out"
  _acl_log "[$ACL_PROJECT] $ACL_STAGE: LEDGER TERMINAL $ACL_STATUS fp=$ACL_FP attempts=${ACL_ATTEMPTS:-?} rc=$rc — nothing called, nothing billed"
  command -v ac_refused_row >/dev/null 2>&1 && ac_refused_row "agent-call-ledger:terminal" 2>/dev/null
  exit "$rc"
}

# acl_finish <rc> <any-ran> <outfile> [nothing-billed] [error-envelope]
#   Settles a `run` row once. unbilled: no rung ran, or [nothing-billed] (a
#   subscription quota / auth / 429 failure, agent-call.sh's cg_nothing_billed).
#   failed: rc != 0, or rc 0 with [error-envelope] set (the CLI's error JSON).
#   ok: rc 0 and a non-blank <outfile>. empty: rc 0 and blank. The body rides in
#   the same request as the status, so a row can never say ok without its
#   answer. Over AGENT_LEDGER_ANSWER_MAX_BYTES, or with ACL_NO_BODY=1 (a caller
#   that keeps no copy: bin/claude-cost.sh), it is ok with no body: never replayed.
acl_finish() {
  local rc="${1:-1}" ran="${2:-}" out="${3:-}" nobill="${4:-}" envl="${5:-}" st max bytes=0 body=/dev/null j
  [ "$ACL_STATE" = run ] && [ -z "$ACL_SETTLED" ] || return 0
  ACL_SETTLED=1
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  if [ -z "$ran" ]; then st=unbilled
  elif [ "$rc" != 0 ] && [ -n "$nobill" ]; then st=unbilled
  elif [ "$rc" != 0 ] || [ -n "$envl" ]; then st=failed
  elif grep -q '[^[:space:]]' "$out" 2>/dev/null; then st=ok
  else st=empty
  fi
  if [ "$st" = ok ] && [ "${ACL_NO_BODY:-0}" != 1 ]; then
    max=$(_acl_int "${AGENT_LEDGER_ANSWER_MAX_BYTES:-}" "$ACL_DEF_ANSWER_MAX_BYTES")
    bytes=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ "$bytes" -le "$max" ]; then body="$out"
    else
      _acl_log "[$ACL_PROJECT] $ACL_STAGE fp=$ACL_FP: answer is $bytes bytes, over AGENT_LEDGER_ANSWER_MAX_BYTES=$max — settled ok with no body; it never replays"
    fi
  fi
  j=$(mktemp "${TMPDIR:-/tmp}/acl-fin.XXXXXX") || return 0
  if ! jq -n --arg p "$ACL_PROJECT" --arg s "$ACL_STAGE" --arg f "$ACL_FP" --arg st "$st" --arg rc "$rc" \
       --arg runner "$(head -1 "$out.runner" 2>/dev/null)" --arg model "$(head -1 "$out.model" 2>/dev/null)" \
       --arg bytes "$bytes" --rawfile b "$body" \
       '{project:$p,stage:$s,fp:$f,status:$st,rc:($rc|tonumber),runner:$runner,model:$model}
        + (if $b != "" then {answer_body:$b} elif $st == "ok" and ($bytes|tonumber) > 0 then {answer_bytes:($bytes|tonumber)} else {} end)' \
       > "$j" 2>/dev/null; then
    rm -f "$j"; _acl_log "[$ACL_PROJECT] $ACL_STAGE fp=$ACL_FP: settle $st could not be built — the row stays running (counts as paid)"; return 0
  fi
  JOBS_TIMEOUT="$(_acl_timeout)" acl_req_finish "$j" >/dev/null 2>&1 \
    || _acl_log "[$ACL_PROJECT] $ACL_STAGE fp=$ACL_FP: settle $st did not land — the row stays running (counts as paid after its TTL)"
  rm -f "$j"
  return 0
}

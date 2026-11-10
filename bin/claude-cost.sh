#!/bin/bash
# bin/claude-cost.sh <claude args...> — run the claude CLI and leave a cost row.
#
# Same argv as `claude`, same stdin, same stdout, same stderr, same exit code.
# The only difference is that afterwards logs/cost.csv has a row for the call,
# priced from the session transcript, tagged with who asked for it.
#
# WHY. bin/agent-call.sh is the instrumented lane, but it is a STAGE runner —
# it owns the model ladder, the failover, the budget flag, the no-tools
# contract. Callers that genuinely need raw claude (the orchestrator's turns,
# greenfield's pipeline, the per-box chat's `-c` continuation) could not use it,
# so they called the CLI directly and their spend was invisible: not a lane
# reporting wrong numbers, a lane reporting nothing. This is the thin path for
# exactly those callers, and it writes through the SAME cost_append every
# agent-call row goes through (bin/lib/cost-row.sh) so there is one ledger
# writer rather than two that drift.
#
# TAGS come from the environment, so a call site needs no new argv:
#   COST_STAGE    the lane name for the row's stage column (default: raw)
#   COST_PROJECT  the project column                        (default: fleet)
#   COST_KEY      the ticket                                (default: $HARNESS_TICKET)
#   COST_JOB      the jobs-ledger row                       (default: $JOB_ID)
#   COST_PR       the PR this call is for
#   COST_RUN_ID   the run/build this call belongs to
# Box id (hostname) and the auth fingerprint + account label are resolved here,
# live, the same way agent-call.sh resolves them — only the box that made the
# call, at the moment it made it, can say which credential paid.
#
# SESSION ID. A uuid is generated up front and passed as --session-id, so the
# transcript path is known BEFORE the call and a run that is killed still gets
# priced. Three cases where it is not injected, and all three still get a row:
#   * argv already names --session-id: the caller's id is used.
#   * argv continues a conversation (-c/--continue/-r/--resume/--from-pr): the
#     CLI owns the id, so the transcript is DISCOVERED afterwards — the newest
#     session file under this cwd's project directory touched since the call
#     began — and priced with --since, so a continued session contributes this
#     turn rather than its whole history.
#   * the switch is off (COST_TRANSCRIPT_ROWS=0 / flags/transcript-cost-off):
#     the row is written with row_source=none and empty token columns, which is
#     what every raw caller had before this file existed.
#
# WHAT IS GATED (BH-2534). Before claude starts, the call goes through the same
# two checks bin/agent-call.sh runs: bin/lib/llm-gate.sh (LLM_LANE_ENABLED,
# LLM_RUNNER_ALLOWED, LLM_USD_CAP_DAY for the lane in $AGENT_CALL_LANE, else the
# lane the stage resolves to) and K3, bin/lib/call-guard.sh, when the guard
# enforces $COST_STAGE. A refusal runs nothing, leaves a zero-cost
# row_source=refused row, prints `AGENT_CALL_REFUSED ...` on stderr and exits
# 74, agent-call's before-billing code. Then the dedup ledger (BH-9064,
# bin/lib/agent-call-ledger.sh): a terminal row (empty, failed at the attempt
# cap, running elsewhere, parked) runs nothing and exits with the stored rc.
# This path never replays an answer. The one path still ungated is a box
# with no bin/lib/cost-row.sh, which execs claude below: without a ledger
# writer a refusal could not leave its row.
#
# INSTRUMENTATION MUST NEVER BREAK THE THING IT MEASURES. Everything after the
# CLI exits is best-effort and silent; nothing here writes to the caller's
# stdout or stderr, and the exit code is claude's, always — except the gate's
# refusal above, which is 74 and happens before claude exists.
set -uo pipefail
# The lane is THIS call's (BH-2303, the same rule as agent-call.sh): it stays a
# shell variable for the gate and the cost row, and never reaches the claude
# session or anything that session launches.
export -n AGENT_CALL_LANE 2>/dev/null || true
# The run id is this call's by the same rule (BH-9127): cost_row_tags reads it
# below as a shell variable, and a build the claude session starts does not
# inherit it, so that build's rows keep their build dir as run_id.
export -n COST_RUN_ID 2>/dev/null || true
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HARNESS/logs/claude-cost.log"
mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null

# Repo sibling first so tests drive the checkout's copy; $HARNESS/bin is the
# deployed path. A missing library degrades to "run claude, write nothing"
# rather than to "refuse to run".
# shellcheck source=/dev/null
if   [ -r "$HERE/lib/cost-row.sh" ];        then . "$HERE/lib/cost-row.sh"
elif [ -r "$HARNESS/bin/lib/cost-row.sh" ]; then . "$HARNESS/bin/lib/cost-row.sh"; fi
# shellcheck source=/dev/null
if   [ -r "$HERE/auth-fingerprint.sh" ];        then . "$HERE/auth-fingerprint.sh"
elif [ -r "$HARNESS/bin/auth-fingerprint.sh" ]; then . "$HARNESS/bin/auth-fingerprint.sh"; fi
# The env dir resolver, so cost_row_auth_account reads the account registry
# where it lives (/etc/harness/env), not through the compat symlink (BH-3986).
# shellcheck source=/dev/null
command -v harness_env_dir >/dev/null 2>&1 || . "$HERE/lib/env-path.sh" 2>/dev/null || . "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || true
command -v auth_fp_for_runner  >/dev/null 2>&1 || auth_fp_for_runner()  { echo none; }
command -v auth_account_for_fp >/dev/null 2>&1 || auth_account_for_fp() { echo unknown; }
# ...and for the canonical account label and the served-model note (BH-3986).
# Under set -u a missing cost_row_auth_account leaves COST_ROW_AUTH_ACCOUNT
# unbound and aborts the row AFTER the paid call; the stub is the rule before
# this shipped (fingerprint, else a pinned name verbatim, else acct:<name>), and
# the note stub adds nothing.
command -v cost_row_auth_account >/dev/null 2>&1 || cost_row_auth_account() {
  COST_ROW_AUTH_ACCOUNT="${1:-unknown}"; COST_ROW_ACCT_FROM=fp
  [ "$COST_ROW_AUTH_ACCOUNT" = unknown ] || return 0
  COST_ROW_ACCT_FROM=none
  if [ "${4:-0}" = 1 ] && [ -n "${2:-}" ]; then COST_ROW_AUTH_ACCOUNT="$2"; COST_ROW_ACCT_FROM=pinned
  elif [ -n "${2:-}" ] && [ "$2" != default ]; then COST_ROW_AUTH_ACCOUNT="acct:$2"; COST_ROW_ACCT_FROM=name; fi
  return 0
}
command -v cost_row_model_note >/dev/null 2>&1 || cost_row_model_note() { :; }

# No library, no row — but the call still runs. This is the one failure this
# script is allowed to have, and it is loud once a day rather than silent.
if ! command -v cost_append >/dev/null 2>&1; then
  F="$HARNESS/flags/alerted-claude-cost-nolib-$(date -u +%Y%m%d)"
  [ -f "$F" ] || { mkdir -p "$HARNESS/flags" 2>/dev/null; touch "$F" 2>/dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [claude-cost] bin/lib/cost-row.sh missing — raw claude calls on this box are running UNBILLED. Deploy the harness: bin/harness-sync.sh." >> "$HARNESS/logs/ALERTS.log" 2>/dev/null; }
  exec claude "$@"
fi

COST="$HARNESS/logs/cost.csv"
[ -f "$COST" ] || printf '%s\n' "$COST_ROW_HDR" > "$COST"

# THE GATE LIBRARIES (BH-2534), after cost-row.sh and $COST because a refusal
# writes its row through the same writer. Same sibling-first chain and the same
# "allow" stubs agent-call.sh uses: a box whose sync has not landed a lib runs
# the call exactly as it ran before. jobs-client.sh is how both libs reach the
# worker (the day's spend, the K3 claim/settle, the settings rows).
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/llm-gate.sh
if   [ -r "$HERE/lib/llm-gate.sh" ];        then . "$HERE/lib/llm-gate.sh"
elif [ -r "$HARNESS/bin/lib/llm-gate.sh" ]; then . "$HARNESS/bin/lib/llm-gate.sh"; fi
command -v llm_gate_precall     >/dev/null 2>&1 || llm_gate_precall()     { return 0; }
command -v llm_gate_runner_ok   >/dev/null 2>&1 || llm_gate_runner_ok()   { return 0; }
command -v llm_gate_refused_row >/dev/null 2>&1 || llm_gate_refused_row() { return 0; }
# shellcheck source=bin/lib/call-guard.sh
if   [ -r "$HERE/lib/call-guard.sh" ];        then . "$HERE/lib/call-guard.sh"
elif [ -r "$HARNESS/bin/lib/call-guard.sh" ]; then . "$HARNESS/bin/lib/call-guard.sh"; fi
command -v call_guard_precall >/dev/null 2>&1 || call_guard_precall() { CG_STATE=off; return 0; }
command -v call_guard_finish  >/dev/null 2>&1 || call_guard_finish()  { return 0; }
CG_STATE=""; CG_REASON=""
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply call-guard; } || true
# The dedup ledger (BH-9064), the same lib bin/agent-call.sh asks.
# shellcheck source=bin/lib/agent-call-ledger.sh
if   [ -r "$HERE/lib/agent-call-ledger.sh" ];        then . "$HERE/lib/agent-call-ledger.sh"
elif [ -r "$HARNESS/bin/lib/agent-call-ledger.sh" ]; then . "$HARNESS/bin/lib/agent-call-ledger.sh"; fi
command -v acl_precall >/dev/null 2>&1 || acl_precall() { return 0; }
command -v acl_finish  >/dev/null 2>&1 || acl_finish()  { return 0; }
ACL_STATE=""
[ "${LANE_GATE_DISABLE:-0}" = 1 ] || { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply agent-call-ledger; } || true

# ── read argv (never rewrite it beyond the one flag we may add) ──────────────
SID=""; CONTINUES=0; ARGMODEL=""
prev=""
for a in "$@"; do
  case "$prev" in
    --session-id) SID="$a" ;;
    --model|-m)   ARGMODEL="$a" ;;
  esac
  case "$a" in
    -c|--continue|-r|--resume|--from-pr) CONTINUES=1 ;;
    --session-id=*) SID="${a#--session-id=}" ;;
    --model=*)      ARGMODEL="${a#--model=}" ;;
    # Bundled short flags (`-pc`) still continue a conversation.
    -[a-z]*) case "$a" in --*) ;; *[cr]*) CONTINUES=1 ;; esac ;;
  esac
  prev="$a"
done

ARGS=("$@")
if [ -z "$SID" ] && [ "$CONTINUES" -eq 0 ] && cost_transcript_enabled; then
  SID=$(cost_row_uuid)
  [ -n "$SID" ] && ARGS=(--session-id "$SID" "$@")
fi

# ── THE GATE, before anything is spawned ───────────────────────────────────
GSTAGE="${COST_STAGE:-raw}"; GPROJ="${COST_PROJECT:-fleet}"
_cc_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# _cc_refuse <marker> <reason> <failovers line> — nothing ran, nothing billed.
_cc_refuse() {
  printf 'AGENT_CALL_REFUSED %s\n' "$1" >&2
  echo "$(_cc_stamp) [$GPROJ] $GSTAGE (claude-cost) $3" >> "$HARNESS/logs/failovers.log" 2>/dev/null
  llm_gate_refused_row "$GSTAGE" "$GPROJ" claude "${ARGMODEL:-unknown}" 74 "$2"
  exit 74
}
if ! llm_gate_precall "$GSTAGE" "$GPROJ" || ! llm_gate_runner_ok "$GSTAGE" "$GPROJ" claude; then
  _cc_refuse "llm-gate ${LLM_GATE_REASON:-gated}" "${LLM_GATE_REASON:-gated}" \
    "GATE REFUSED before the call: ${LLM_GATE_REASON:-gated} — nothing was called and nothing was billed. Change it with bin/harness-ctl.sh set <lane> LLM_LANE_ENABLED 1 (or LLM_USD_CAP_DAY <n> / LLM_RUNNER_ALLOWED <list>), or turn the gate off with LLM_GATE_DISABLE=1."
fi
# K3. The work is the caller's argv (not the --session-id added above), so a
# retry of the same argv is the same work. A prompt on a stdin stream is part
# of the work too (BH-9064): it is saved to a file first, and the prompt sha is
# of the argv AND that file, so two different stdin prompts are two pieces of
# work and the same one twice is one. claude then reads the saved file. Every
# call is claimed; with no AGENT_CALL_FP the fingerprint is K3's computed one
# (call_guard_fp: <ticket>:<HEAD>:p<prompt sha>).
CC_STDIN=""
_cc_cleanup() { [ -z "$CC_STDIN" ] || rm -f "$CC_STDIN"; return 0; }
if [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
  CC_STDIN=$(mktemp "${TMPDIR:-/tmp}/claude-cost-stdin.XXXXXX" 2>/dev/null) || CC_STDIN=""
  # Every exit after this point removes the copy (a refusal, the end of the call).
  trap _cc_cleanup EXIT
  # Reads ALL of stdin before claude starts. A --input-format stream-json
  # caller (none today) would hang here; give it a no-read path first.
  [ -z "$CC_STDIN" ] || cat > "$CC_STDIN"
fi
CC_PSHA=$( { printf '%s\0' "$@"; [ -z "$CC_STDIN" ] || cat "$CC_STDIN"; } | sha256sum | cut -c1-64)
if ! call_guard_precall "$GSTAGE" "$GPROJ" claude "$CC_PSHA"; then
  case "$CG_REASON" in
    call-guard:repeat) CC_M="call-guard repeat $CG_STAGE paid=${CG_COUNT:-?}/$CG_MAX fp=$CG_FP" ;;
    *)                 CC_M="call-guard counter-unreadable metered claude" ;;
  esac
  _cc_refuse "$CC_M" "$CG_REASON" \
    "CALL-GUARD REFUSED before the call ($CG_REASON, guard stage $CG_STAGE, fp $CG_FP) — nothing was called and nothing was billed. logs/call-guard.log has the detail; knobs are lib.call-guard.* (CALL_GUARD=0 turns it off)."
fi
# The dedup ledger, after K3. This wrapper streams claude's stdout to its
# caller and keeps no copy, so it never replays (ACL_NO_REPLAY) and stores no
# answer body: it enforces the terminal states and records the attempts.
if ! ACL_NO_REPLAY=1 acl_precall "$GSTAGE" "$GPROJ" "$CC_PSHA"; then
  command -v call_guard_finish >/dev/null 2>&1 && call_guard_finish 0 "" /dev/null
  CC_LRC=$(acl_terminal_rc)
  acl_refusal_line >&2
  _acl_log "[$GPROJ] $ACL_STAGE: LEDGER TERMINAL $ACL_STATUS fp=$ACL_FP attempts=${ACL_ATTEMPTS:-?} rc=$CC_LRC (claude-cost) — nothing called, nothing billed"
  llm_gate_refused_row "$GSTAGE" "$GPROJ" claude "${ARGMODEL:-unknown}" 74 "agent-call-ledger:terminal"
  exit "$CC_LRC"
fi
# The guard has read its per-call env; it describes THIS call, not the session.
export -n AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE 2>/dev/null || true

T0=$(date +%s)
CC_CWD=$(pwd -P 2>/dev/null || pwd)

# ── RUN IT, AND SURVIVE THE SIGNAL THAT KILLS IT ────────────────────────────
# Callers wrap this in `timeout N`, and timeout signals its DIRECT child — which
# is now this wrapper rather than claude. Two things go wrong if the signal is
# just left to the default: bash running a foreground external command defers
# SIGTERM until that command returns, so the timeout would stop cutting the call
# short (claude runs to completion, then the shell dies), and the row for the
# killed run — the row this whole wave exists to produce — is never written.
#
# So claude runs in the background, the signal is forwarded to it, and the code
# after `wait` still runs. `<&0` is load-bearing: an async command in a
# non-interactive shell has its stdin redirected from /dev/null unless it is
# redirected explicitly, and bin/orchestrate.sh pipes its prompt in on stdin.
CHILD=""
_cc_forward() { [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null; return 0; }
trap _cc_forward TERM INT HUP
if [ -n "$CC_STDIN" ]; then claude "${ARGS[@]}" < "$CC_STDIN" &
else claude "${ARGS[@]}" <&0 &
fi
CHILD=$!
# `wait` returns 128+signo when a trap interrupts it and the child is still
# running, so wait again until it is genuinely reaped; RC is then claude's own.
wait "$CHILD"; RC=$?
while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD"; RC=$?; done
trap - TERM INT HUP
T1=$(date +%s)

# ── the row ─────────────────────────────────────────────────────────────────
IN=""; OUTT=""; CR=""; CW=""; USD=""; SRC=none; TMODEL=""; TC=""; PRICEV=""
if cost_transcript_enabled; then
  if   [ -x "$HERE/transcript-cost.sh" ];        then TC="$HERE/transcript-cost.sh"
  elif [ -x "$HARNESS/bin/transcript-cost.sh" ]; then TC="$HARNESS/bin/transcript-cost.sh"; fi
fi
if [ -n "$TC" ]; then
  TARGET="$SID"; SINCE_ARG=()
  if [ -z "$TARGET" ]; then
    # Discovery path: the CLI chose the id. The newest session file under THIS
    # cwd's project directory that was touched since the call started is this
    # call's — scoped, because several claude processes share a box and the
    # unscoped answer is whichever session was written last (the 15x
    # mis-attribution bin/claude-usage.sh was built to stop).
    PDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$CC_CWD" | tr '/' '-')"
    TARGET=$(find "$PDIR" -maxdepth 1 -name '*.jsonl' -newermt "@$((T0 - 2))" -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | head -1 | cut -d' ' -f2-)
    SINCE_ARG=(--since "$T0")
  fi
  if [ -n "$TARGET" ]; then
    TCL=$("$TC" "$TARGET" --cwd "$CC_CWD" ${SINCE_ARG[@]+"${SINCE_ARG[@]}"} --price-version 2>>"$LOG")
    TCRC=$?
    if [ "$TCRC" -eq 0 ] && [ -n "$TCL" ]; then
      IFS='|' read -r IN OUTT CR CW USD TMODEL _M _F _UP PRICEV <<<"$TCL"
      SRC=transcript
      [ -n "${_UP:-}" ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [claude-cost] ${COST_STAGE:-raw}/${COST_PROJECT:-fleet} session=${SID:-?}: UNPRICED model(s) ${_UP} — cost_usd is partial" >> "$LOG"
    fi
  fi
fi

MODEL="${TMODEL:-}"; [ -n "$MODEL" ] || MODEL="${ARGMODEL:-unknown}"
BMODE=$("$HARNESS/bin/billing-mode.sh" claude 2>/dev/null || echo unknown)
[ -n "$BMODE" ] || BMODE=unknown
AUTH_FP=$(auth_fp_for_runner claude 2>/dev/null) || AUTH_FP=none
[ -n "$AUTH_FP" ] || AUTH_FP=none
AUTH_ACCT=$(auth_account_for_fp "$AUTH_FP" 2>/dev/null) || AUTH_ACCT=unknown
[ -n "$AUTH_ACCT" ] || AUTH_ACCT=unknown
# A routed account whose token fingerprint has no catalog label rides the
# free-text column as its canonical label: the pick's label=, else the
# registry's ACCOUNT_LABEL, else acct:<name> (BH-3986, the same rule
# agent-call.sh calls; a live fingerprint label still wins). COST_ACCT_NAME and
# ORC_ACCOUNT_LABEL are set by bin/lib/orc-account.sh for turns. The raw name
# rides the note when the column holds a label it resolved to.
cost_row_auth_account "$AUTH_ACCT" "${COST_ACCT_NAME:-}" "${ORC_ACCOUNT_LABEL:-}" 0
AUTH_ACCT="$COST_ROW_AUTH_ACCOUNT"; CC_NOTE=""
case "$COST_ROW_ACCT_FROM" in label|registry|name) CC_NOTE="acct=$COST_ACCT_NAME" ;; esac
# The transcript priced this row from a versioned price row (BH-5652): the note
# says which version, by the same rule cost_row_price writes it.
if [ -n "$PRICEV" ] && command -v cost_price_version_token >/dev/null 2>&1; then
  _PVT=$(cost_price_version_token "$PRICEV") && CC_NOTE="${CC_NOTE:+$CC_NOTE;}$_PVT"
fi

ROW="$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$(cost_csv_field "${COST_PROJECT:-fleet}"),$(cost_csv_field "${COST_STAGE:-raw}"),claude,$(cost_csv_field "$MODEL"),$RC,$((T1-T0)),$IN,$OUTT,$CR,$CW,$USD,$BMODE,$AUTH_FP,$AUTH_ACCT,$(cost_csv_field "$SID"),$SRC,,$(cost_row_tags),$(cost_csv_field "$CC_NOTE"),$(cost_csv_field "${AGENT_CALL_LANE:-}")"
cost_append "$ROW" 2>/dev/null || true

# ── the ledger settle (BH-9064): the status only, never a body (see above) ──
if [ "$ACL_STATE" = run ]; then
  CC_ACLOUT=$(mktemp 2>/dev/null) || CC_ACLOUT=""
  if [ -n "$CC_ACLOUT" ]; then
    { [ "$SRC" = transcript ] && [ "${OUTT:-}" = 0 ]; } || printf 'x' > "$CC_ACLOUT"
    # A failed call whose transcript shows no token in or out bought nothing (a
    # quota, auth or 429 answer before any model turn): it settles `unbilled`
    # and gives the attempt back, as agent-call.sh's cg_nothing_billed does. A
    # call with no transcript stays `failed` (counted as paid: over, never under).
    CC_NOBILL=""
    if [ "$RC" != 0 ] && [ "$SRC" = transcript ] \
       && [ "${IN:-x}" = 0 ] && [ "${OUTT:-x}" = 0 ] && [ "${CR:-0}" = 0 ] && [ "${CW:-0}" = 0 ]; then
      CC_NOBILL=1
    fi
    ACL_NO_BODY=1 acl_finish "$RC" 1 "$CC_ACLOUT" "$CC_NOBILL"
    rm -f "$CC_ACLOUT"
  fi
fi

# ── K3 settle ───────────────────────────────────────────────────────────────
# ok and empty are both paid and terminal, so the label never changes a count:
# empty only when the transcript says the call produced 0 output tokens. No
# nothing-billed argument, so a failed call counts as paid (over, never under).
if [ "$CG_STATE" = allowed ]; then
  CC_CGOUT=$(mktemp 2>/dev/null) || CC_CGOUT=""
  if [ -n "$CC_CGOUT" ]; then
    { [ "$SRC" = transcript ] && [ "${OUTT:-}" = 0 ]; } || printf 'x' > "$CC_CGOUT"
    call_guard_finish "$RC" 1 "$CC_CGOUT"
    rm -f "$CC_CGOUT"
  else
    call_guard_finish "$RC" 1 /dev/null
  fi
fi
exit $RC

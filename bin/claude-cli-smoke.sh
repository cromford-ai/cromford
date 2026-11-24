#!/bin/bash
# bin/claude-cli-smoke.sh [--force] — lane claude-cli-smoke (BH-9911), every box,
# hourly at :47. It does something ONLY on the canary box (settings row
# claude_cli.canary_box), when the pin is on (claude_cli.pin.enabled=1), a
# canary version C is set (claude_cli.canary_version), C is newer than the pin
# (claude_cli.pinned_version: after promote sets the pin to C the canary has
# nothing left to prove) and the claude on PATH reports C. Everywhere else it
# exits 0 at once: no row, no spend.
#
# THE SMOKE: five model steps, each one call through bin/agent-call.sh
# (AGENT_CALL_RUNNERS=claude, lane claude-cli-smoke, model route
# claude-cli.smoke), so each one writes a priced cost row:
#   stdin       "Reply exactly: OK" on stdin (agent-call pipes the prompt)
#   late_stdin  the same, through a `claude` wrapper first on PATH that holds
#               stdin back claude_cli.smoke_late_stdin_s seconds. 2.1.317 gave
#               up on stdin after 3 s and broke every orchestrator turn.
#   tool_call   AGENT_CALL_TOOLS=Bash: run `echo -n <nonce> | sha256sum`; pass
#               = the answer holds the first 12 hex digits (a model cannot make
#               them up, so the tool really ran)
#   haiku       AGENT_CALL_NO_TOOLS=1 (the `--tools ""` shape), "Reply exactly: OK"
#   lane_tick   one run of bin/lane-probe.sh claude (a real lane script)
# and one step with no spend:
#   fail_classes  the RUNNER_* failure class tokens in logs/failovers.log since
#               C was installed, against the same length of time before it (at
#               most claude_cli.fail_class_window_h). A token after that is not
#               in before is a new class: ok=0. It blocks promotion, it is not
#               a red smoke and it sends no alert.
# Each step runs under an outer `timeout` of claude_cli.smoke_step_timeout_s +
# claude_cli.smoke_step_grace_s, KILL claude_cli.smoke_step_kill_after_s later.
# Pass rule of a model step: rc 0, the answer's first line is not an
# AGENT_CALL_REFUSED marker, and the last non-empty line is OK (tool_call: the
# answer holds the digest).
#
# DEDUP BEFORE SPEND, in order: (1) pending rows from an earlier run are sent
# first, and while any stay unsent nothing runs; (2) the rows of (box, C) are
# read (claude_cli.smoke_list_limit), and a failed read runs nothing; (3) a red
# model step row for C means C is red, and red is terminal (--force runs it
# again); (4) a run younger than claude_cli.smoke_interval_h runs nothing, and
# a dead-<run_id>.json of C younger than that counts as a run (its rows never
# reached D1, so without it a refused POST would spend again every hour).
# LLM_USD_CAP_DAY (lane claude-cli-smoke) caps the day's spend in agent-call.
#
# OUTPUT: six rows {box, version, run_id, step, ok, rc, ms, detail, at} written
# first to state/claude-cli-smoke/pending-<run_id>.json, then POSTed to
# /api/claude-cli/smoke (table claude_cli_smoke); the file goes after the POST.
# A detail is cut to claude_cli.smoke_detail_max (the row the worker checks),
# a step excerpt to claude_cli.smoke_excerpt_max. A pending file the worker
# refuses with a 4xx moves to state/claude-cli-smoke/dead-<run_id>.json with
# ONE ALERTS line `CLAUDE CLI SMOKE ROWS REFUSED: ...`; it is never resent.
# When a model step failed: ONE ALERTS line
#   CLAUDE CLI CANARY RED: <C> on <box> failed <step> (rc <rc>): <detail> — promotion of <C> is blocked
# through bin/alert-line.sh.
# Log: logs/claude-cli-smoke.log. Off: flags/lane-off-claude-cli-smoke.
# Test seams, read only when HARNESS_TEST_SANDBOX=1: CCP_NOW (epoch seconds),
# CCP_AGENT_CALL and CCP_LANE_PROBE (paths of stand-ins with the same argv).
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FORCE=0; [ "${1:-}" = --force ] && FORCE=1
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# >>> lane gate (BH-1165): flags/lane-off-claude-cli-smoke stops this lane;
# lane_env_apply brings its LLM_* knobs (catalog/lanes.d/claude-cli-smoke.json).
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit claude-cli-smoke
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    claude-cli-smoke
# shellcheck source=bin/jobs-client.sh
. "$HERE/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/claude-cli-pin.sh
. "$HERE/lib/claude-cli-pin.sh"
PEND="$H/state/claude-cli-smoke"
mkdir -p "$H/logs" "$PEND" 2>/dev/null
LOG="$H/logs/claude-cli-smoke.log"
BOX=$(tr -dc 'A-Za-z0-9._-' 2>/dev/null < "$H/state/box-id" || true)
[ -n "$BOX" ] || BOX=$(hostname -s 2>/dev/null || echo unknown)
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$BOX] $*" >> "$LOG" 2>/dev/null; }
redact() { sed -E 's/(sk-ant-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|gho_[A-Za-z0-9]+|xox[baprs]-[A-Za-z0-9-]+|Bearer [A-Za-z0-9._-]+)/[REDACTED]/g'; }

NOW=$(date -u +%s)
AC="$HERE/agent-call.sh"; LP="$HERE/lane-probe.sh"
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  [[ ${CCP_NOW:-} =~ ^[0-9]+$ ]] && NOW="$CCP_NOW"
  [ -n "${CCP_AGENT_CALL:-}" ] && AC="$CCP_AGENT_CALL"
  [ -n "${CCP_LANE_PROBE:-}" ] && LP="$CCP_LANE_PROBE"
fi
iso_of() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# send_pending <file> -> rc 0 sent (file removed); rc 2 the worker refused the
# rows (a 4xx other than auth, no route, timeout or rate limit): the file moves
# to dead-<run_id>.json with ONE ALERTS line, so a refused file never stops
# every later run; rc 1 kept (outage, 5xx), sent again next run.
send_pending() {
  local f="$1" b dead
  b=$(basename "$f")
  if ccp_smoke_post "$f"; then rm -f "$f"; return 0; fi
  case "${JOBS_HTTP:-}" in
    401|403|404|408|429) return 1 ;;
    4??) dead="$PEND/dead-${b#pending-}"
         mv -f "$f" "$dead" 2>/dev/null || return 1
         log "$b refused (http=$JOBS_HTTP) — moved to $(basename "$dead"), not resent"
         HARNESS="$H" "$H/bin/alert-line.sh" "CLAUDE CLI SMOKE ROWS REFUSED: the worker answered http $JOBS_HTTP to $b on $BOX — moved to state/claude-cli-smoke/$(basename "$dead") and not resent (check claude_cli.smoke_detail_max and claude_cli.smoke_post_rows_max)"
         return 2 ;;
  esac
  return 1
}

# --- 1. resend pending rows --------------------------------------------------
for f in "$PEND"/pending-*.json; do
  [ -f "$f" ] || continue
  send_pending "$f"
  case $? in
    0) log "resent $(basename "$f")" ;;
    2) ;;
    *) log "resend of $(basename "$f") failed (http=${JOBS_HTTP:-none}) — kept" ;;
  esac
done
if compgen -G "$PEND/pending-*.json" >/dev/null; then
  log "rows of an earlier run are not sent yet — no smoke this run"; exit 0
fi

# --- 2. is this the canary, on the canary version? ---------------------------
ccp_enabled; EN=$?
[ "$EN" = 0 ] || exit 0
CB=$(ccp_canary_box)
ccp_is_canary "$BOX" "$CB" || exit 0
C=$(ccp_canary_version 2>>"$LOG")
[ -n "$C" ] || { log "no canary version set — no smoke"; exit 0; }
P=$(ccp_pinned_version 2>>"$LOG")
cli_version_gt "$C" "$P" || { log "canary $C is not newer than the pin $P — no smoke"; exit 0; }
REAL=$(command -v claude 2>/dev/null || true)
HAVE=$(cli_version_of "${REAL:-/nonexistent}")
[ "$HAVE" = "$C" ] || { log "claude on PATH is $HAVE, canary version is $C — no smoke until cli-update installs it"; exit 0; }

# --- 3. dedup before spend -----------------------------------------------------
LIM=$(ccp_knob_int claude_cli.smoke_list_limit "$CCP_SMOKE_LIST_LIMIT_FALLBACK" 2>>"$LOG")
ROWS=$(ccp_smoke_list "$BOX" "$C" "$LIM") || { log "smoke rows for $C not readable (http=${JOBS_HTTP:-none}) — no smoke"; exit 0; }
RED=$(jq -r --arg s "$CCP_MODEL_STEPS" '[.[] | select((.step as $x | ($s | split(" ") | index($x))) and .ok != 1)] | .[0] | select(. != null) | .step' <<<"$ROWS")
if [ -n "$RED" ] && [ "$FORCE" = 0 ]; then log "$C is red ($RED failed) — no smoke (--force runs it again)"; exit 0; fi
INTERVAL_H=$(ccp_knob_int claude_cli.smoke_interval_h "$CCP_SMOKE_INTERVAL_H_FALLBACK" 2>>"$LOG")
LAST=$(jq -r 'map(.at) | max // empty' <<<"$ROWS")
if [ -n "$LAST" ] && [ "$FORCE" = 0 ] && [[ $LAST > $(iso_of $((NOW - INTERVAL_H * 3600))) ]]; then
  log "last smoke of $C at $LAST is younger than ${INTERVAL_H}h — no smoke"; exit 0
fi
# A dead-letter file's rows never reach D1, so the read above cannot see that
# run: a dead-letter run of C younger than the interval counts as a run too.
for f in "$PEND"/dead-*.json; do
  [ -f "$f" ] && [ "$FORCE" = 0 ] || continue
  DL=$(jq -r --arg v "$C" '[.rows[]? | select(.version == $v) | .at] | max // empty' "$f" 2>/dev/null)
  if [ -n "$DL" ] && [[ $DL > $(iso_of $((NOW - INTERVAL_H * 3600))) ]]; then
    log "dead-letter run of $C at $DL ($(basename "$f")) is younger than ${INTERVAL_H}h — no smoke"; exit 0
  fi
done

# --- 4. the steps ----------------------------------------------------------------
# shellcheck source=bin/lib/model-route.sh
. "$HERE/lib/model-route.sh" 2>/dev/null && M=$(model_for claude-cli.smoke 2>>"$LOG") || M=""
[ -n "$M" ] || { log "no model route for claude-cli.smoke (model_routes) — no smoke"; exit 0; }
STEP_TO=$(ccp_knob_int claude_cli.smoke_step_timeout_s "$CCP_STEP_TIMEOUT_S_FALLBACK" 2>>"$LOG")
LATE_S=$(ccp_knob_int claude_cli.smoke_late_stdin_s "$CCP_LATE_STDIN_S_FALLBACK" 2>>"$LOG")
GRACE_S=$(ccp_knob_int claude_cli.smoke_step_grace_s "$CCP_STEP_GRACE_S_FALLBACK" 2>>"$LOG")
KILL_S=$(ccp_knob_int claude_cli.smoke_step_kill_after_s "$CCP_STEP_KILL_AFTER_S_FALLBACK" 2>>"$LOG")
# The worker refuses a detail longer than claude_cli.smoke_detail_max: read the
# same row, so lowering it never makes every POST a 400.
DETAIL_MAX=$(ccp_knob_int claude_cli.smoke_detail_max "$CCP_SMOKE_DETAIL_MAX_FALLBACK" 2>>"$LOG")
EXC=$(ccp_knob_int claude_cli.smoke_excerpt_max "$CCP_SMOKE_EXCERPT_MAX_FALLBACK" 2>>"$LOG")
RUN_ID="$(iso_of "$NOW" | tr -d ':-')-$$"
WD=$(mktemp -d "${TMPDIR:-/tmp}/claude-cli-smoke.XXXXXX") || { log "mktemp failed — no smoke"; exit 0; }
trap 'rm -rf "$WD"' EXIT
ROWS_OUT="$WD/rows.jsonl"; : > "$ROWS_OUT"

# The late-stdin wrapper: first on PATH for that one step, it holds stdin back
# LATE_S seconds and then hands it to the real binary.
mkdir -p "$WD/late-bin"
printf '#!/bin/bash\n{ sleep %s; cat; } | %q "$@"\n' "$LATE_S" "$REAL" > "$WD/late-bin/claude"
chmod +x "$WD/late-bin/claude"

add_row() { # add_row <step> <ok> <rc> <ms> <detail>
  jq -nc --arg b "$BOX" --arg v "$C" --arg r "$RUN_ID" --arg s "$1" --argjson ok "$2" --argjson rc "$3" \
    --argjson ms "$4" --arg d "$(redact <<<"$5" | tr '\n' ' ' | sed 's/ *$//' | cut -c1-"$DETAIL_MAX")" --arg at "$(iso_of "$NOW")" \
    '{box:$b, version:$v, run_id:$r, step:$s, ok:$ok, rc:$rc, ms:$ms, detail:$d, at:$at}' >> "$ROWS_OUT"
}
# answer_ok <file> <want> -> rc 0 when the answer passes. want = OK, or a
# string the answer must contain.
answer_ok() {
  local f="$1" want="$2" first last
  [ -s "$f" ] || return 1
  first=$(head -1 "$f")
  case "$first" in AGENT_CALL_REFUSED*) return 1 ;; esac
  if [ "$want" = OK ]; then
    last=$(grep -v '^[[:space:]]*$' "$f" | tail -1 | tr -d '[:space:]')
    [ "$last" = OK ] || [ "$last" = OK. ]
  else
    grep -qF -- "$want" "$f"
  fi
}
FAILED=""
# model_step <step> <want> <prompt> [VAR=value ...] — one agent-call.
model_step() {
  local step="$1" want="$2" prompt="$3" out rc t0 ms ok=0 detail
  shift 3
  out="$WD/$step.out"; t0=$(date +%s%N)
  env "$@" AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-cli-smoke \
    timeout --kill-after="$KILL_S" $((STEP_TO + GRACE_S)) "$AC" claude-cli-smoke fleet "$M" "$STEP_TO" "$out" "$prompt" </dev/null >/dev/null 2>"$WD/$step.err"
  rc=$?
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  answer_ok "$out" "$want" && [ "$rc" = 0 ] && ok=1
  detail=$(head -c "$EXC" "$out" 2>/dev/null)
  [ -n "$detail" ] || detail=$(tail -c "$EXC" "$WD/$step.err" 2>/dev/null)
  add_row "$step" "$ok" "$rc" "$ms" "$detail"
  [ "$ok" = 1 ] || { [ -n "$FAILED" ] || FAILED="$step|$rc|$detail"; }
  log "step $step: ok=$ok rc=$rc ${ms}ms"
}

NONCE="ccs-$RUN_ID"
DIGEST=$(printf '%s' "$NONCE" | sha256sum | cut -c1-12)
model_step stdin OK "Reply exactly: OK"
model_step late_stdin OK "Reply exactly: OK" PATH="$WD/late-bin:$PATH"
model_step tool_call "$DIGEST" "Use the Bash tool to run \`echo -n $NONCE | sha256sum\` and reply with its output only." AGENT_CALL_TOOLS=Bash
model_step haiku OK "Reply exactly: OK" AGENT_CALL_NO_TOOLS=1

# lane_tick: one real lane script.
t0=$(date +%s%N)
LT=$(timeout --kill-after="$KILL_S" $((STEP_TO + GRACE_S)) "$LP" claude 2>"$WD/lane_tick.err"); rc=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 )); ok=0
[ "$rc" = 0 ] && grep -q '[^[:space:]]' <<<"$LT" && ! grep -q '^AGENT_CALL_REFUSED' <<<"$LT" && ok=1
add_row lane_tick "$ok" "$rc" "$ms" "${LT:0:EXC}"
[ "$ok" = 1 ] || { [ -n "$FAILED" ] || FAILED="lane_tick|$rc|${LT:0:EXC}"; }
log "step lane_tick: ok=$ok rc=$rc ${ms}ms"

# fail_classes: no spend. T0 = when C was installed: the cli-update CSV row
# that moved claude to C, else the mtime of the binary PATH runs.
T0=$(awk -F, -v v="$C" '$3 == "claude" && $5 == v && $4 != v { a = $1 } END { print a }' "$H/logs/cli-versions.csv" 2>/dev/null)
T0E=""; [ -n "$T0" ] && T0E=$(date -u -d "$T0" +%s 2>/dev/null)
[ -n "$T0E" ] || T0E=$(stat -c %Y "$(readlink -f "$REAL")" 2>/dev/null)
[ -n "$T0E" ] || T0E="$NOW"
WIN_H=$(ccp_knob_int claude_cli.fail_class_window_h "$CCP_FAIL_CLASS_WINDOW_H_FALLBACK" 2>>"$LOG")
W=$((NOW - T0E)); [ "$W" -gt $((WIN_H * 3600)) ] && W=$((WIN_H * 3600)); [ "$W" -lt 0 ] && W=0
stamp_of() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
classes_between() { # classes_between <from-stamp> <to-stamp> -> sorted unique RUNNER_* failure tokens
  awk -v a="$1" -v b="$2" '{ s = substr($0, 1, 20) } s >= a && s < b' "$H/logs/failovers.log" 2>/dev/null \
    | grep -oE '\bRUNNER_[A-Z_]+\b' | grep -vE '^RUNNER_OK$|_FALLBACK$' | sort -u
}
BEFORE=$(classes_between "$(stamp_of $((T0E - W)))" "$(stamp_of "$T0E")")
AFTER=$(classes_between "$(stamp_of "$T0E")" "$(stamp_of $((NOW + 1)))")
NEW=$(comm -13 <(printf '%s\n' "$BEFORE" | grep .) <(printf '%s\n' "$AFTER" | grep .) | tr '\n' ' ' | sed 's/ $//')
if [ -n "$NEW" ]; then add_row fail_classes 0 0 0 "new failure class(es) since $C was installed: $NEW"
else add_row fail_classes 1 0 0 "no new failure class since $C was installed"; fi
log "step fail_classes: new=[${NEW}]"

# --- 5. write, then send -----------------------------------------------------------
PF="$PEND/pending-$RUN_ID.json"
jq -sc '{rows: .}' "$ROWS_OUT" > "$PF.tmp" && mv -f "$PF.tmp" "$PF" || { log "could not write $PF"; }
if [ -f "$PF" ]; then
  send_pending "$PF"
  case $? in
    0) log "run $RUN_ID: 6 rows sent" ;;
    2) ;;
    *) log "run $RUN_ID: POST failed (http=${JOBS_HTTP:-none}) — rows kept in $PF, sent next run" ;;
  esac
fi

# --- 6. one RED line ---------------------------------------------------------------------
if [ -n "$FAILED" ]; then
  IFS='|' read -r FS FRC FD <<<"$FAILED"
  FD=$(redact <<<"$FD" | tr '\n' ' ' | sed 's/ *$//' | cut -c1-"$EXC")
  LINE="CLAUDE CLI CANARY RED: $C on $BOX failed $FS (rc $FRC): $FD — promotion of $C is blocked"
  HARNESS="$H" "$H/bin/alert-line.sh" "$LINE"
  log "RED: $FS"
fi
exit 0

#!/bin/bash
# bin/claude-cli-pin.sh watch|promote|drift — HUB lane claude-cli-pin (BH-9911).
# The fleet runs ONE pinned Claude Code CLI version (settings row
# claude_cli.pinned_version). One canary box (claude_cli.canary_box) runs the
# next release (claude_cli.canary_version) first, and bin/claude-cli-smoke.sh
# tests it there. On 2026-11-03 a daily `latest` put 2.1.317 on the hub and
# broke every orchestrator turn (BH-9019); this lane is how a release reaches
# the fleet now.
#
#   watch    daily 04:37. Reads the newest npm release L. When L is newer than
#            the pin and newer than the canary version, it sets
#            claude_cli.canary_version = L. It never writes the pin.
#   promote  daily 04:47. Sets claude_cli.pinned_version = C (the canary
#            version) only when ALL hold: C is newer than the pin; the canary's
#            smoke rows for C were read; no model step row of C is red; one
#            complete green run is at least claude_cli.canary_soak_h old; the
#            newest complete run is green; the newest fail_classes row is ok.
#            Else one log line names the first condition that failed.
#   drift    daily 05:52 (after the 05:17 updates push box_status). One warn
#            per box whose cli_version is not its target, and one per pool
#            image (state/fly/<project>.cli) whose claude= is not the pin.
#            A warn key already in state/claude-cli-pin/drift-sent.tsv is not
#            sent again. Always one summary line; a failed read or an answer
#            with no boxes array is "not measured", never a 0 count.
#
# Every verb does nothing (one log line) unless claude_cli.pin.enabled is 1.
# Log: logs/claude-cli-pin.log (and stdout). Off: flags/lane-off-claude-cli-pin.
# Test seams, read only when HARNESS_TEST_SANDBOX=1: CCP_NOW (epoch seconds)
# and CCP_NPM_VIEW (the text npm view would print).
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VERB="${1:-}"
case "$VERB" in watch|promote|drift) ;; *) echo "usage: claude-cli-pin.sh watch|promote|drift" >&2; exit 64 ;; esac
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# >>> lane gate (BH-1165): flags/lane-off-claude-cli-pin stops this lane;
# lane_env_apply brings its settings rows (catalog/lanes.d/claude-cli-pin.json).
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit claude-cli-pin
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    claude-cli-pin
# shellcheck source=bin/jobs-client.sh
. "$HERE/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/claude-cli-pin.sh
. "$HERE/lib/claude-cli-pin.sh"
mkdir -p "$H/logs" "$H/state/claude-cli-pin" 2>/dev/null
LOG="$H/logs/claude-cli-pin.log"
log() { local l; l="$(date -u '+%Y-%m-%d %H:%M:%SZ') [claude-cli-pin] $VERB: $*"; echo "$l"; echo "$l" >> "$LOG" 2>/dev/null; }

NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${CCP_NOW:-} =~ ^[0-9]+$ ]] && NOW="$CCP_NOW"
iso_of() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

ccp_enabled; EN=$?
case "$EN" in
  0) ;;
  1) log "pin off (claude_cli.pin.enabled is not 1, or unreadable with no on state cached) — nothing to do"; exit 0 ;;
  *) log "pin state unknown (claude_cli.pin.enabled unreadable, last known on) — nothing done"; exit 0 ;;
esac
P=$(ccp_pinned_version 2>>"$LOG")

# ---------------------------------------------------------------------------
do_watch() {
  local raw L C to ka
  C=$(ccp_canary_version 2>>"$LOG")
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${CCP_NPM_VIEW+set}" ]; then
    raw="$CCP_NPM_VIEW"
  else
    to=$(ccp_knob_int claude_cli.watch_timeout_s "$CCP_WATCH_TIMEOUT_S_FALLBACK" 2>>"$LOG")
    ka=$(ccp_knob_int claude_cli.watch_kill_after_s "$CCP_WATCH_KILL_AFTER_S_FALLBACK" 2>>"$LOG")
    raw=$(timeout --kill-after="$ka" "$to" npm view @anthropic-ai/claude-code version 2>/dev/null) || {
      log "npm view failed (rc $?) — no change"; return 0; }
  fi
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  if ! [[ $raw =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "npm view gave no x.y.z version ('${raw:0:80}') — no change"; return 0
  fi
  L="$raw"
  if ! cli_version_gt "$L" "$P"; then log "latest $L is not newer than the pin $P — no change"; return 0; fi
  if [ -n "$C" ] && ! cli_version_gt "$L" "$C"; then log "latest $L is not newer than the canary $C — no change"; return 0; fi
  if setting_set claude_cli.canary_version "$L" "new release found by claude-cli-pin watch (pin $P)"; then
    log "NEW CANARY $L (pin $P, previous canary ${C:-none})"
  else
    log "could not write claude_cli.canary_version=$L (http=${JOBS_HTTP:-none}) — no change"
  fi
}

# ---------------------------------------------------------------------------
do_promote() {
  local C CB CBID SOAK LIM rows red runs first_green newest_complete fc n cutoff
  C=$(ccp_canary_version 2>>"$LOG")
  [ -n "$C" ] || { log "no canary version — no promotion"; return 0; }
  if ! cli_version_gt "$C" "$P"; then log "canary $C is not newer than the pin $P — no promotion"; return 0; fi
  CB=$(ccp_canary_box); CBID=$(ccp_box_id "$CB")
  SOAK=$(ccp_knob_int claude_cli.canary_soak_h "$CCP_SOAK_H_FALLBACK" 2>>"$LOG")
  LIM=$(ccp_knob_int claude_cli.smoke_list_limit "$CCP_SMOKE_LIST_LIMIT_FALLBACK" 2>>"$LOG")
  rows=$(ccp_smoke_list "$CBID" "$C" "$LIM") || { log "smoke rows for $C on $CBID not readable (http=${JOBS_HTTP:-none}) — no promotion"; return 0; }
  # Only the canary box's rows count, and ok counts only as the number 1.
  rows=$(jq -c --arg b "$CBID" --arg v "$C" '[.[] | select(.box == $b and .version == $v)]' <<<"$rows")
  red=$(jq -r --arg s "$CCP_MODEL_STEPS" '[.[] | select((.step as $x | ($s | split(" ") | index($x))) and .ok != 1)] | .[0] | select(. != null) | "\(.step) in run \(.run_id)"' <<<"$rows")
  [ -z "$red" ] || { log "canary $C has a red smoke step ($red) — no promotion"; return 0; }
  # runs: one object per run_id with its first at, and whether it holds all
  # five model steps (complete) and all five ok (green).
  runs=$(jq -c --arg s "$CCP_MODEL_STEPS" '
    ($s | split(" ")) as $need
    | [group_by(.run_id)[] | {run_id: .[0].run_id,
         at: (map(.at) | min),
         complete: ([.[] | select(.step as $x | $need | index($x)) | .step] | unique | length == ($need | length)),
         green: ([.[] | select((.step as $x | $need | index($x)) and .ok == 1)] | map(.step) | unique | length == ($need | length))}]
    | sort_by(.at)' <<<"$rows")
  cutoff=$(iso_of $((NOW - SOAK * 3600)))
  first_green=$(jq -r --arg c "$cutoff" '[.[] | select(.complete and .green and .at <= $c)] | .[0].at // empty' <<<"$runs")
  [ -n "$first_green" ] || { log "canary $C has no complete green run older than ${SOAK}h — no promotion"; return 0; }
  newest_complete=$(jq -r '[.[] | select(.complete)] | last | .green' <<<"$runs")
  [ "$newest_complete" = true ] || { log "the newest complete smoke run of $C is not green — no promotion"; return 0; }
  fc=$(jq -r '[.[] | select(.step == "fail_classes")] | sort_by(.at) | last | select(. != null) | (.ok == 1)' <<<"$rows")
  if [ -z "$fc" ]; then log "canary $C has no fail_classes check yet — no promotion"; return 0; fi
  [ "$fc" = true ] || { log "canary $C has a new agent-call failure class (newest fail_classes row) — no promotion"; return 0; }
  n=$(jq -r '[.[] | select(.complete and .green)] | length' <<<"$runs")
  if setting_set claude_cli.pinned_version "$C" "promoted by claude-cli-pin: $n green runs over ${SOAK}h on $CBID"; then
    log "PROMOTED $P -> $C ($n green runs on $CBID, first at $first_green)"
  else
    log "could not write claude_cli.pinned_version=$C (http=${JOBS_HTTP:-none}) — no promotion"
  fi
}

# ---------------------------------------------------------------------------
SENT="$H/state/claude-cli-pin/drift-sent.tsv"
# drift_warn <akey> <line> -> rc 0 when the warn reached the console or ALERTS.
drift_warn() {
  local akey="$1" line="$2" rc
  BEAT_STRICT=1 "$H/bin/beat.sh" "$(jq -nc --arg akey "$akey" --arg l "$line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,severity:"warn",line:$l}')" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 2 ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "$line" && return 0
  fi
  return 1
}

do_drift() {
  local resp C CB MAXH now_cut boxes m=0 n=0 j=0 k=0 box ver at exp akey f got proj keep="" new=0
  resp=$(_jobs_req GET /api/boxes) || { log "not measured (GET /api/boxes failed, http=${JOBS_HTTP:-none})"; return 0; }
  # No boxes array is not "0 boxes": it is not measured, never a 0 drift.
  jq -e '.boxes | type == "array"' >/dev/null 2>&1 <<<"$resp" \
    || { log "not measured (GET /api/boxes answer has no boxes array)"; return 0; }
  boxes=$(jq -r '.boxes[]? | [.box, (.cli_version // ""), (.cli_checked_at // "")] | @tsv' <<<"$resp" 2>/dev/null) \
    || { log "not measured (GET /api/boxes answer is not JSON)"; return 0; }
  C=$(ccp_canary_version 2>>"$LOG"); CB=$(ccp_canary_box)
  MAXH=$(ccp_knob_int claude_cli.drift_max_age_h "$CCP_DRIFT_MAX_AGE_H_FALLBACK" 2>>"$LOG")
  now_cut=$(iso_of $((NOW - MAXH * 3600)))
  touch "$SENT" 2>/dev/null
  while IFS=$'\t' read -r box ver at; do
    [ -n "$box" ] && [ -n "$ver" ] && [ -n "$at" ] || continue
    [[ $at < $now_cut ]] && continue
    m=$((m + 1))
    exp=$(ccp_target_for "$box" "$P" "$C" "$CB")
    [ "$ver" = "$exp" ] && continue
    n=$((n + 1))
    akey="claude-cli-drift:$box:$ver:$exp"; keep="$keep$akey"$'\n'
    grep -qxF "$akey" < <(cut -f1 "$SENT") && continue
    if drift_warn "$akey" "CLAUDE CLI DRIFT: box $box runs claude $ver, the pin wants $exp (claude_cli.pinned_version; bin/cli-update.sh at 05:17 moves it)"; then
      printf '%s\t%s\n' "$akey" "$(iso_of "$NOW")" >> "$SENT"; new=$((new + 1))
    else
      log "warn for $box not delivered (beat failed) — retried next run"
    fi
  done <<<"$boxes"
  for f in "$H"/state/fly/*.cli; do
    [ -f "$f" ] || continue
    j=$((j + 1)); proj=$(basename "$f" .cli)
    got=$(sed -n 's/^claude=//p' "$f" | head -1)
    [ "$got" = "$P" ] && continue
    k=$((k + 1))
    akey="claude-cli-drift:image:$proj:${got:-none}:$P"; keep="$keep$akey"$'\n'
    grep -qxF "$akey" < <(cut -f1 "$SENT") && continue
    if drift_warn "$akey" "CLAUDE CLI DRIFT: pool image builder-$proj bakes claude ${got:-none}, the pin is $P (bin/fly-image-build.sh rebuilds it nightly)"; then
      printf '%s\t%s\n' "$akey" "$(iso_of "$NOW")" >> "$SENT"; new=$((new + 1))
    else
      log "warn for image $proj not delivered (beat failed) — retried next run"
    fi
  done
  # Keep only the keys still off the pin: a box back on the pin warns again
  # the next time it drifts.
  awk -F'\t' 'NR == FNR { if ($0 != "") k[$0] = 1; next } ($1 in k)' <(printf '%s' "$keep") "$SENT" > "$SENT.tmp" 2>/dev/null \
    && mv -f "$SENT.tmp" "$SENT"
  log "$n of $m boxes and $k of $j images off the pin ($new new warn(s); pin $P, canary ${C:-none} on $CB)"
}

case "$VERB" in
  watch) do_watch ;;
  promote) do_promote ;;
  drift) do_drift ;;
esac
exit 0

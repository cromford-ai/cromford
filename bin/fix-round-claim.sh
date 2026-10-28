#!/bin/bash
# gh-identity: app-token
# bin/fix-round-claim.sh — every project box, every 2 minutes: claim the fix
# rounds blocked-resolver queued for THIS box and run each one detached, here
# (BH-2672, BH-2530.2). It replaces the hub's ssh hop (br_fix_remote in
# bin/blocked-resolver.sh) with a pull: the hub enqueues a fix_round_jobs row,
# this lane claims it, runs `blocked-resolver.sh --fix-here` on it and posts the
# answer back as the row's finish.
#
# THE TICK (no args, what cron runs):
#   the hub, the lane switch (flags/lane-off-fix-round-claim), FIX_ROUND_CLAIM=0,
#   no JOBS_URL / HARNESS_SECRET, or a box that cannot name itself: exit 0 with
#   no claim. Otherwise up to FIX_ROUND_CLAIM_MAX claims through
#   fix_round_claim <box> <stale_min>, where stale_min is
#   ceil((BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN) / 60) from the blocked-resolver
#   knobs (either one not a number: no cutoff is sent, so a claimed row is never
#   re-offered). Each claimed row is written to a temp file and handed to a
#   `setsid ... --run` child; the tick never waits for it. A lost race counts
#   toward the max; "none" (a 404 included) ends the tick quietly; an outage
#   ends it with one line.
#
# THE RUNNER (--run <id> <rowfile>):
#   0. a row whose project or cap_key is not [A-Za-z0-9._-]+, or whose args are
#      not six strings, finishes setup-blocked. Nothing reaches a path.
#   1. flock -n locks/fix-round-<p>-<ck>.lock. Held: a live runner owns the
#      park, exit 0 with no finish (the row stays claimed).
#   2. THE RE-OFFER GUARD (the BH-2038 re-read, box side). attempt > 1 means the
#      row was re-offered after a runner stopped answering. If this box's own
#      record (state/blocked-resolver/<p>/<ck>.json, this project's) holds MORE
#      attempts than the row's record_in, the round already ran here: finish
#      done with that record and do not buy it twice.
#   3. GH_TOKEN minted by bin/gh-token.sh for the project's repo, then
#      `timeout -k 60 BR_FIX_LANE_TIMEOUT bin/blocked-resolver.sh --fix-here
#      <args>` with record_in on stdin (/dev/null when there is none).
#   4. the last FIX_RECORD (kept only if it is this project's) and the first
#      FIX_RESULT, as br_fix_remote read them.
#   5. finish: a known FIX_RESULT passes through. No FIX_RESULT, or one this
#      lane does not know, is setup-blocked with the reason. Never done (D9).
#   6. a finish that fails leaves the row claimed (the stale re-offer and the
#      guard recover it); a 409 is logged once. Neither is retried.
#   Between 2 and 3, THE FLY PLACEMENT (BH-8065, bin/lib/fix-round-pool.sh):
#   with lane_placement.blocked-resolver-fix.<project> = fly (the project row
#   only) and the project pool-routed, the round is NOT run here. One
#   build_queue row FXR-<id>-<ck8> (target fly) is put, and the row stays
#   claimed by this box. A pool row already queued or claimed: nothing. Already
#   done or failed: finish setup-blocked, no second round. Unreadable, or the
#   put fails: nothing, the stale re-offer comes back. Never a local run after
#   the placement said fly. A missing lib is the box, with one log line.
#
# THE POOL RUNNER (--run-pool <id> <box> <project> <cap_key> [--blocked <why>]),
#   on a Fly pool machine (fly/builder-runner.sh run_fixround_job): reads the
#   row again with fix_round_get. Only when its id is <id>, its status claimed
#   and claimed_by <box> does it run steps 0-6 above as <box>, with no placement
#   read and the machine's own GH_TOKEN kept when bin/gh-token.sh answers empty.
#   It prints ONE word line, the machine's RESULT for the hub reap:
#     FIX_ROUND_FINISHED <result-word> finish=<ok|409|failed>  the round ran
#     FIX_ROUND_SKIPPED <why>     the row is not claimed by <box> (done,
#                                 adopted, another id, unreadable): nothing ran
#     FIX_ROUND_SETUP_FAILED <why> the lib is missing, the round did not start,
#                                 or --blocked: one setup-blocked finish
#
# Knobs: lane.fix-round-claim FIX_ROUND_CLAIM, FIX_ROUND_CLAIM_MAX;
#   lane.blocked-resolver BR_FIX_LANE_TIMEOUT, BR_FIX_HOP_MARGIN (read, not owned).
# Log: logs/fix-round-claim.log. Locks: locks/fix-round-<p>-<ck>.lock.
# Switch: flags/lane-off-fix-round-claim (bin/harness-ctl.sh off fix-round-claim "<reason>").
# Tests: tests/fix-round-claim.bh-2530-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LOG="$H/logs/fix-round-claim.log"

frc_log() { FRC_LAST="$*"; mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }
frc_b64() { printf '%s' "$1" | base64 -w0; }

# frc_run <id> <rowfile> — one claimed row, start to finish.
frc_run() {
  local id="$1" rowf="$2" box row p ck attempt rin args_json fin out rc=0 line rb64="" rjson="" res=""
  local f n0 n1 repo tmo result why where tok
  local -a args=()
  # FRC_AS_BOX (--run-pool): the claiming box, which the finish CAS needs.
  box="${FRC_AS_BOX:-$(local_box_name)}"
  row=$(cat "$rowf" 2>/dev/null)
  rm -f "$rowf"
  [ -n "$box" ] || { frc_log "row $id: this box cannot name itself, the row stays claimed"; return 0; }
  p=$(printf '%s' "$row" | jq -r '.project // empty | strings' 2>/dev/null)
  ck=$(printf '%s' "$row" | jq -r '.cap_key // empty | strings' 2>/dev/null)
  attempt=$(printf '%s' "$row" | jq -r '.attempt // empty' 2>/dev/null)
  # args is a TEXT column: an array, or a JSON string holding one.
  args_json=$(printf '%s' "$row" | jq -c '.args | (if type == "string" then (try fromjson catch null) else . end)
    | if type == "array" and length == 6 and all(.[]; type == "string") then . else empty end' 2>/dev/null)
  why=""
  grep -qE '^[A-Za-z0-9._-]+$' <<<"$p" && [ "$p" != . ] && [ "$p" != .. ] || why="project '$p' is not [A-Za-z0-9._-]+"
  [ -n "$why" ] || { grep -qE '^[A-Za-z0-9._-]+$' <<<"$ck" && [ "$ck" != . ] && [ "$ck" != .. ]; } || why="cap_key '$ck' is not [A-Za-z0-9._-]+"
  [ -n "$why" ] || case "$attempt" in ''|*[!0-9]*) why="attempt '$attempt' is not a number" ;; esac
  [ -n "$why" ] || [ -n "$args_json" ] || why="args are not six strings"
  if [ -n "$why" ]; then
    frc_finish "$id" "$box" "setup-blocked $(frc_b64 "row $id on $box is malformed: $why")" "" "malformed row ($why)"
    return 0
  fi
  mapfile -d '' -t args < <(printf '%s' "$args_json" | jq -j '.[] | (., "\u0000")')

  mkdir -p "$H/locks" 2>/dev/null
  exec 9>"$H/locks/fix-round-$p-$ck.lock" || { frc_log "row $id $p/$ck: cannot open its lock, the row stays claimed"; return 0; }
  if ! flock -n 9; then
    frc_log "row $id: a live runner owns $p/$ck, nothing run, nothing posted"
    return 0
  fi

  # record_in: a JSON string holding the record, or null (no record).
  rin=$(printf '%s' "$row" | jq -r '.record_in | strings' 2>/dev/null)
  f="$H/state/blocked-resolver/$p/$ck.json"
  if [ "$attempt" -gt 1 ] && [ -r "$f" ]; then
    if [ -n "$rin" ]; then n0=$(printf '%s' "$rin" | jq '(.attempts // []) | length' 2>/dev/null); else n0=0; fi
    n1=$(jq -e --arg p "$p" 'select(.project == $p) | (.attempts // []) | length' "$f" 2>/dev/null)
    if [ -n "$n0" ] && [ -n "$n1" ] && [ "$n1" -gt "$n0" ] 2>/dev/null; then
      frc_log "re-offered row $id: the round already ran here (attempts $n0→$n1), finished from the local record, no second round"
      frc_finish "$id" "$box" "done" "$(cat "$f")" "done from the local record"
      return 0
    fi
  fi

  # THE FLY PLACEMENT (BH-8065). FRC_POOL_RUN=1 is the pool machine itself:
  # no placement read there, so the round never loops back to the pool.
  if [ "${FRC_POOL_RUN:-0}" != 1 ] && command -v frp_placed >/dev/null 2>&1 && frp_placed "$p"; then
    frp_put "$id" "$box" "$p" "$ck" "$attempt"
    if [ "$FRP_WORD" = ran ]; then
      frc_finish "$id" "$box" "setup-blocked $(frc_b64 "the Fly pool already ran this round as $FRP_KEY ($FRP_ST: $FRP_REASON) and no finish landed; it is not run a second time")" "" "pool row $FRP_ST"
    fi
    return 0
  fi

  where="$box"; [ "${FRC_POOL_RUN:-0}" = 1 ] && where="the Fly pool for $box"
  tmo=$(lane_knob blocked-resolver BR_FIX_LANE_TIMEOUT "$p")
  case "$tmo" in ''|*[!0-9]*)
    frc_finish "$id" "$box" "setup-blocked $(frc_b64 "BR_FIX_LANE_TIMEOUT on $where is '$tmo', not a number of seconds, so the round was not started")" "" "no timeout"
    return 0 ;;
  esac
  fin=$(mktemp "${TMPDIR:-/tmp}/fix-round-in.XXXXXX") && out=$(mktemp "${TMPDIR:-/tmp}/fix-round-out.XXXXXX") || {
    rm -f "${fin:-}"
    frc_log "row $id $p/$ck: no scratch file, the row stays claimed"
    return 0
  }
  printf '%s' "$rin" > "$fin"
  [ -n "$rin" ] || { rm -f "$fin"; fin=/dev/null; }
  export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  repo=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  if [ -n "$repo" ]; then
    tok=$("$H/bin/gh-token.sh" "$repo" 2>/dev/null)
    # A pool machine already pushes as the project: an empty mint keeps its token.
    if [ -n "$tok" ] || [ "${FRC_POOL_RUN:-0}" != 1 ]; then GH_TOKEN="$tok"; export GH_TOKEN; fi
  fi
  frc_log "row $id $p/$ck attempt $attempt: fix round starting"
  # The round runs in a subshell with the build limits (BH-8281: CARGO_BUILD_JOBS
  # and a lower CPU priority), so this runner's own priority does not change.
  # bl_apply's stdout goes nowhere: $out is parsed for FIX_* lines.
  (
    if . "$H/bin/lib/build-limits.sh" 2>/dev/null; then
      bl_apply "$H" "$p" >/dev/null 2>>"$LOG" || :
    fi
    exec timeout -k 60 "$tmo" "$H/bin/blocked-resolver.sh" --fix-here "${args[@]}"
  ) < "$fin" > "$out" || rc=$?
  unset GH_TOKEN
  [ "$fin" = /dev/null ] || rm -f "$fin"
  while IFS= read -r line; do
    case "$line" in
      "FIX_RECORD "*) rb64="${line#FIX_RECORD }" ;;
      "FIX_RESULT "*) [ -n "$res" ] || res="${line#FIX_RESULT }" ;;
    esac
  done < "$out"
  rm -f "$out"
  if [ -n "$rb64" ]; then
    rjson=$(printf '%s' "$rb64" | base64 -d 2>/dev/null | jq -c --arg p "$p" 'select(.project == $p)' 2>/dev/null)
    [ -n "$rjson" ] || frc_log "row $id $p/$ck: the round sent back a record that is not $p's, it is not posted"
  fi
  if [ -z "$res" ]; then
    result="setup-blocked $(frc_b64 "the round on $where gave no FIX_RESULT (rc=$rc)")"
  elif grep -qE '^(done|terminal|rebuild-fresh|setup-blocked [^ ]+|box-paused [^ ]+)$' <<<"$res"; then
    result="$res"
  else
    result="setup-blocked $(frc_b64 "the round on $where answered an unrecognised FIX_RESULT: $res")"
  fi
  frc_finish "$id" "$box" "$result" "$rjson" "round rc=$rc"
}

# frc_finish <id> <box> <result> <record-or-empty> <what> — one finish, never
# retried, and a failure is never read as success. Sets FRC_FIN (ok|409|failed)
# and FRC_RESULT for --run-pool's word line.
frc_finish() {
  local rc=0
  FRC_RESULT="$3"
  fix_round_finish "$1" "$2" "$3" "$4" 2>>"$LOG" || rc=$?
  case "$rc" in
    0) FRC_FIN=ok;     frc_log "row $1 finished: ${3%% *} ($5)" ;;
    9) FRC_FIN=409;    frc_log "row $1: 409 on finish (the row is no longer claimed by $2), not retried ($5)" ;;
    *) FRC_FIN=failed; frc_log "row $1: finish failed, the row stays claimed; the stale re-offer and the guard recover it ($5)" ;;
  esac
}

# frc_run_pool <id> <box> <project> <cap_key> [--blocked <why>] — the pool
# machine's verb (see the header). Prints the ONE word line; always rc 0.
frc_run_pool() {
  local id="${1:-}" box="${2:-}" p="${3:-}" ck="${4:-}" blocked="" row rc=0 have rowf tmpd
  [ "${5:-}" = --blocked ] && blocked="${6:-no reason given}"
  FRC_FIN=""; FRC_RESULT=""; FRC_LAST=""
  case "$id" in ''|*[!0-9]*) echo "FIX_ROUND_SETUP_FAILED --run-pool needs a numeric id, got '$id'"; return 0 ;; esac
  for have in "$box" "$p" "$ck"; do
    grep -qE '^[A-Za-z0-9._-]+$' <<<"$have" || { echo "FIX_ROUND_SETUP_FAILED --run-pool argument '$have' is not [A-Za-z0-9._-]+"; return 0; }
  done
  # shellcheck source=jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck source=lib/fix-round-queue.sh
  . "$H/bin/lib/fix-round-queue.sh" 2>/dev/null || { echo "FIX_ROUND_SETUP_FAILED bin/lib/fix-round-queue.sh missing on the machine"; return 0; }
  row=$(fix_round_get "$p" "$ck" 2>>"$LOG") || rc=$?
  case "$rc" in
    0) ;;
    2) echo "FIX_ROUND_SKIPPED row $id $p/$ck has no open row (adopted or gone)"; return 0 ;;
    *) echo "FIX_ROUND_SKIPPED row $id $p/$ck is unreadable (rc $rc)"; return 0 ;;
  esac
  have=$(printf '%s' "$row" | jq -r '"\(.id // "-") \(.status // "-") \(.claimed_by // "-")"' 2>/dev/null)
  if [ "$have" != "$id claimed $box" ]; then
    echo "FIX_ROUND_SKIPPED row $id $p/$ck is not claimed by $box (id status claimed_by: ${have:-unreadable})"
    return 0
  fi
  if [ -n "$blocked" ]; then
    frc_finish "$id" "$box" "setup-blocked $(frc_b64 "the Fly pool machine for $box could not start the round: $blocked")" "" "pool setup failed"
    echo "FIX_ROUND_SETUP_FAILED $blocked finish=$FRC_FIN"
    return 0
  fi
  tmpd="$H/tmp"; mkdir -p "$tmpd" 2>/dev/null || tmpd="${TMPDIR:-/tmp}"
  rowf=$(mktemp "$tmpd/fix-round-XXXXXX.json") || { echo "FIX_ROUND_SETUP_FAILED no temp file for row $id"; return 0; }
  printf '%s' "$row" > "$rowf"
  FRC_AS_BOX="$box" FRC_POOL_RUN=1 frc_run "$id" "$rowf"
  if [ -n "$FRC_FIN" ]; then
    echo "FIX_ROUND_FINISHED ${FRC_RESULT%% *} finish=$FRC_FIN"
  else
    echo "FIX_ROUND_SETUP_FAILED the round did not start: ${FRC_LAST:-no reason logged}"
  fi
  return 0
}

# frc_tick — claim up to the max, spawn one detached runner per row.
frc_tick() {
  local box on max t m stale i rc job id rowf tmpd claimed=0 lost=0 failed=""
  on=$(lane_knob fix-round-claim FIX_ROUND_CLAIM)
  [ "$on" = 0 ] && return 0
  # shellcheck source=jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck source=lib/fix-round-queue.sh
  . "$H/bin/lib/fix-round-queue.sh" || { frc_log "bin/lib/fix-round-queue.sh missing, nothing claimed"; return 0; }
  if ! declare -F jobs_configured >/dev/null || ! jobs_configured || [ -z "${HARNESS_SECRET:-}" ]; then
    frc_log "not configured (JOBS_URL/HARNESS_SECRET unset), nothing claimed"
    return 0
  fi
  box=$(local_box_name)
  [ -n "$box" ] || { frc_log "this box cannot name itself (bin/box-name.sh), nothing claimed"; return 0; }
  max=$(lane_knob fix-round-claim FIX_ROUND_CLAIM_MAX)
  case "$max" in ''|*[!0-9]*) frc_log "FIX_ROUND_CLAIM_MAX is '$max', not a number, nothing claimed"; return 0 ;; esac
  t=$(lane_knob blocked-resolver BR_FIX_LANE_TIMEOUT)
  m=$(lane_knob blocked-resolver BR_FIX_HOP_MARGIN)
  stale=""
  case "$t$m" in ''|*[!0-9]*) ;; *) [ -n "$t" ] && [ -n "$m" ] && stale=$(( (t + m + 59) / 60 )) ;; esac
  tmpd="$H/tmp"; mkdir -p "$tmpd" 2>/dev/null || tmpd="${TMPDIR:-/tmp}"
  for (( i = 1; i <= max; i++ )); do
    rc=0; job=$(fix_round_claim "$box" "$stale" 2>>"$LOG") || rc=$?
    case "$rc" in
      0) ;;
      2) break ;;
      9) lost=$((lost + 1)); continue ;;
      *) failed="claim failed (outage)"; break ;;
    esac
    id=$(printf '%s' "$job" | jq -r '.id // empty' 2>/dev/null)
    case "$id" in ''|*[!0-9]*) failed="claim answered a job with no numeric id"; break ;; esac
    rowf=$(mktemp "$tmpd/fix-round-XXXXXX.json") || { failed="no temp file for row $id, it stays claimed"; break; }
    printf '%s' "$job" > "$rowf"
    claimed=$((claimed + 1))
    if [ "${FIX_ROUND_CLAIM_FOREGROUND:-0}" = 1 ]; then
      "$H/bin/fix-round-claim.sh" --run "$id" "$rowf" </dev/null >>"$LOG" 2>&1
    else
      setsid "$H/bin/fix-round-claim.sh" --run "$id" "$rowf" </dev/null >>"$LOG" 2>&1 &
    fi
  done
  if [ "$claimed" -gt 0 ] || [ "$lost" -gt 0 ] || [ -n "$failed" ]; then
    frc_log "tick on $box: claimed $claimed, lost $lost race(s)${stale:+, stale_min $stale}${failed:+, $failed}"
  fi
  return 0
}

. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# shellcheck source=lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { echo "fix-round-claim: bin/lib/hub-box.sh missing" >&2; exit 0; }
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_knob >/dev/null 2>&1 || lane_knob() { local v="${!2:-}"; printf '%s' "$v"; }

if [ "${1:-}" = --run-pool ]; then
  shift
  frc_run_pool "$@"
  exit 0
fi

if [ "${1:-}" = --run ]; then
  # The tick already passed the lane gate; --fix-here re-checks this box's own
  # off switches and answers box-paused, so the runner does not gate again.
  # shellcheck source=jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck source=lib/fix-round-queue.sh
  . "$H/bin/lib/fix-round-queue.sh" || { frc_log "row ${2:-?}: bin/lib/fix-round-queue.sh missing, the row stays claimed"; exit 0; }
  # The fly placement (BH-8065). Missing = the round runs on this box.
  # shellcheck source=lib/lane-placement.sh
  . "$H/bin/lib/lane-placement.sh" 2>/dev/null || frc_log "row ${2:-?}: bin/lib/lane-placement.sh missing; the round runs on this box"
  # shellcheck source=lib/fix-round-pool.sh
  . "$H/bin/lib/fix-round-pool.sh" 2>/dev/null || frc_log "row ${2:-?}: bin/lib/fix-round-pool.sh missing; the round runs on this box"
  case "${2:-}" in ''|*[!0-9]*) echo "fix-round-claim: --run needs <id> <rowfile>" >&2; exit 2 ;; esac
  [ -r "${3:-}" ] || { frc_log "row $2: no row file '${3:-}', the row stays claimed"; exit 0; }
  frc_run "$2" "$3"
  exit 0
fi

is_hub_box "$(local_box_name)" && exit 0
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fix-round-claim
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fix-round-claim
frc_tick
exit 0

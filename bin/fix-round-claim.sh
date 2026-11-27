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
#   no claim. Otherwise ONE claim pass at a time (flock -n
#   locks/frc-claim-pass.lock; busy: one line, no claim). THE RUN LIMIT
#   (BH-9906): before each claim the pass counts the live runners (the held
#   locks/fix-round-<p>-<ck>.lock files, read from /proc/locks by
#   bin/lib/fix-round-reap.sh) and stops at FIX_ROUND_RUN_MAX (the minimum of
#   the per-project rows over the projects this box owns, fallback 1) with one
#   line `held back: <running> of <max> running` and no alert: a row it does
#   not claim stays queued. At most FIX_ROUND_CLAIM_MAX claims a pass, each
#   through fix_round_claim <box> <stale_min>, where stale_min is ceil(T / 60)
#   and T = BR_FIX_AGENT_TIMEOUT + BR_FIX_VERIFY_TIMEOUT + BR_FIX_HOP_MARGIN
#   (stale_min 110 at the defaults). The round bound of a run uses the timeout
#   retry's larger agent budget in place of BR_FIX_AGENT_TIMEOUT when
#   BR_FIX_TIMEOUT_RETRIES > 0 (BH-10057: BR_FIX_AGENT_TIMEOUT *
#   BR_FIX_TIMEOUT_RETRY_PCT / 100, bin/lib/fix-retry-budget.sh; 8400 s at the
#   defaults); a re-offer of a live retry runs nothing, as frc_bound says (see
#   frc_bound below; when the agent or verify knob is not a number, the
#   fallback BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN; neither a number: no
#   cutoff is sent, so a claimed row is never re-offered). Each claimed row is
#   written to a temp file and handed to a `setsid ... --run` child; the pass
#   waits up to FIX_ROUND_SPAWN_WAIT_S for that runner to hold its key lock (or
#   exit) and counts again. A lost race counts toward the max; "none" (a 404
#   included) ends the pass quietly; an outage ends it with one line.
#
# THE DRAIN (--drain, BH-9906): the same claim pass, run by a runner as it
#   exits, so the next queued row starts without waiting for the cron tick. It
#   waits up to FIX_ROUND_PASS_WAIT_S for a live claim pass; past it, one line
#   and no claim (the 2-minute cron tick stays the fallback). It prints
#   `claimed <n>`. Not run on a pool machine.
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
#      `timeout -k FIX_ROUND_KILL_GRACE_S T bin/blocked-resolver.sh --fix-here
#      <args>` with record_in on stdin (/dev/null when there is none), in a
#      session of its own (setsid) with FRC_WT_OWNER=1. When it ends, for any
#      reason, every process left in that session is swept (TERM, KILL after
#      FIX_ROUND_KILL_GRACE_S; nested `timeout` commands are process groups of
#      their own and a group kill misses them), and only then is each worktree
#      the round named (FIX_WT <path>, under tmp/brfix/) removed, after a check
#      that no process has its cwd under it (BH-9906).
#   4. the last FIX_RECORD (kept only if it is this project's) and the first
#      FIX_RESULT, as br_fix_remote read them.
#   5. finish: a known FIX_RESULT passes through (verify-timeout included). No
#      FIX_RESULT, or one this lane does not know, is setup-blocked with the
#      reason. Never done (D9).
#      THE TIMEOUT RE-OFFER (BH-9906): FIX_RESULT verify-timeout, or no
#      FIX_RESULT with rc 124 (the round hit T), appends one entry to the
#      record's .timeout_requeues ({head, kind, at, rc, attempt, last}; head is
#      .agent_done.head). Under FIX_ROUND_TIMEOUT_RETRIES timeouts for that
#      head the row goes back to queued for this box at once
#      (fix_round_requeue, the record in record_in; no hub tick); at the count
#      it is finished (verify-timeout, or setup-blocked with no agent record)
#      with ONE alert that names every attempt. No record of this project to
#      carry the count: not re-offered, the normal finish.
#   6. a finish that fails leaves the row claimed (the stale re-offer and the
#      guard recover it); a 409 is logged once. Neither is retried. A requeue
#      that fails is the normal finish.
#   7. THE DRAIN: every exit after the key lock was taken closes the lock and
#      runs --drain (not on a pool machine, not under a foreground pass).
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
#     FIX_ROUND_FINISHED <result-word> finish=<ok|409|failed|requeued>  the
#                                 round ran (requeued: a timed-out round was
#                                 re-offered, the word is verify-timeout)
#     FIX_ROUND_SKIPPED <why>     the row is not claimed by <box> (done,
#                                 adopted, another id, unreadable): nothing ran
#     FIX_ROUND_SETUP_FAILED <why> the lib is missing, the round did not start,
#                                 or --blocked: one setup-blocked finish
#     FIX_ROUND_WRONG_TREE <why> finish=<ok|409|failed>  the round's worktree
#                                 was not the PR's (bin/lib/fix-round-tree.sh,
#                                 BH-8896): one setup-blocked finish, no agent call
#
# Knobs: lane.fix-round-claim FIX_ROUND_CLAIM, FIX_ROUND_CLAIM_MAX,
#   FIX_ROUND_RUN_MAX, FIX_ROUND_TIMEOUT_RETRIES, FIX_ROUND_KILL_GRACE_S,
#   FIX_ROUND_SPAWN_WAIT_S, FIX_ROUND_PASS_WAIT_S; lane.blocked-resolver
#   BR_FIX_AGENT_TIMEOUT, BR_FIX_VERIFY_TIMEOUT, BR_FIX_HOP_MARGIN,
#   BR_FIX_LANE_TIMEOUT (read, not owned).
# Feed: fleet_event beats fix_round_verify_timeout,
#   fix_round_requeued, fix_round_timeout_cap (rkey resolver:<p>/<ck>).
# Log: logs/fix-round-claim.log. Locks: locks/fix-round-<p>-<ck>.lock (a live
#   runner), locks/frc-claim-pass.lock (one claim pass at a time).
# Switch: flags/lane-off-fix-round-claim (bin/harness-ctl.sh off fix-round-claim "<reason>").
# Tests: tests/fix-round-claim.bh-2530-test.sh, tests/fix-round-run-max.bh-9906-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LOG="$H/logs/fix-round-claim.log"

frc_log() { FRC_LAST="$*"; mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }
frc_b64() { printf '%s' "$1" | base64 -w0; }

# frc_knob <lane> <env> <fallback> [project] — a number from lane_knob, else
#   the fallback (the caller's comment names the row).
frc_knob() {
  local v; v=$(lane_knob "$1" "$2" "${4:-}")
  case "$v" in ''|*[!0-9]*) printf '%s' "$3" ;; *) printf '%s' "$v" ;; esac
}

# frc_bound [project] — sets FRC_T (the round bound, seconds) and FRC_STALE_S
#   (the claim's stale cutoff, seconds). FRC_T is AX + V + M, AX being the
#   agent budget of the longest round: the timeout retry's (BH-10057,
#   frb_agent_max) when BR_FIX_TIMEOUT_RETRIES > 0, else BR_FIX_AGENT_TIMEOUT,
#   so the runner never kills a retry. FRC_STALE_S stays A + V + M with A =
#   BR_FIX_AGENT_TIMEOUT: a stale claim is re-offered to the SAME box only, and
#   a re-offer of a live round (a retry past A + V + M) runs nothing (the
#   fix-round-<p>-<ck>.lock its round holds; on the Fly pool its pool key), so
#   a dead claim is still re-offered as soon as before (BH-10115 F4). Either A
#   or V not a number: the fallback BR_FIX_LANE_TIMEOUT for the round and
#   LANE + M for the cutoff. Neither: both empty.
frc_bound() {
  local a v m l ax=""
  a=$(lane_knob blocked-resolver BR_FIX_AGENT_TIMEOUT "${1:-}")
  # BR_FIX_TIMEOUT_RETRIES: lane.blocked-resolver.BR_FIX_TIMEOUT_RETRIES (fallback 1, as brtr_knob);
  # BR_FIX_TIMEOUT_RETRY_PCT: lane.blocked-resolver.BR_FIX_TIMEOUT_RETRY_PCT (fallback 150, frb_pct)
  if command -v frb_agent_max >/dev/null 2>&1 \
     && ax=$(frb_agent_max "$a" "$(lane_knob blocked-resolver BR_FIX_TIMEOUT_RETRIES "${1:-}")" \
          "$(frb_pct "$(lane_knob blocked-resolver BR_FIX_TIMEOUT_RETRY_PCT "${1:-}")")"); then
    :
  else
    ax=$a
  fi
  v=$(lane_knob blocked-resolver BR_FIX_VERIFY_TIMEOUT "${1:-}")
  m=$(lane_knob blocked-resolver BR_FIX_HOP_MARGIN "${1:-}")
  l=$(lane_knob blocked-resolver BR_FIX_LANE_TIMEOUT "${1:-}")
  FRC_T=""; FRC_STALE_S=""
  case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -n "$m" ] && [[ "$a" =~ ^[0-9]+$ ]] && [[ "$v" =~ ^[0-9]+$ ]]; then
    FRC_T=$((ax + v + m)); FRC_STALE_S=$((a + v + m))
  elif [[ "$l" =~ ^[0-9]+$ ]]; then
    FRC_T=$l; [ -n "$m" ] && FRC_STALE_S=$((l + m))
  fi
}

# frc_event <event> <project> <cap_key> <detail> — one fleet_event beat, the
#   shape br_event writes (the console's feed renders it).
frc_event() {
  [ -x "$H/bin/beat.sh" ] || return 0
  "$H/bin/beat.sh" "$(jq -nc --arg e "$1" --arg p "$2" --arg k "$3" --arg d "$4" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{kind:"fleet_event",project:$p,rkey:("resolver:"+$p+"/"+$k),event:$e,reason:"fix-round-claim",detail:$d,ts:$ts}' 2>/dev/null)" \
    >/dev/null 2>&1 || true
}

# frc_run <id> <rowfile> — one claimed row, start to finish, then the drain
#   when the key lock was taken (BH-9906: every exit path after the lock).
frc_run() {
  FRC_LOCKED=0
  frc_run_round "$@"
  if [ "$FRC_LOCKED" = 1 ]; then
    exec 9>&-
    frc_drain
  fi
  return 0
}

# frc_drain — the claim pass a runner makes as it exits. Not on a pool machine
#   (each pool round has its own machine), not under a pass that runs this
#   runner in the foreground (that pass goes on claiming itself).
frc_drain() {
  local o
  [ "${FRC_POOL_RUN:-0}" = 1 ] && return 0
  [ "${FRC_IN_PASS:-0}" = 1 ] && return 0
  o=$("$H/bin/fix-round-claim.sh" --drain </dev/null 2>>"$LOG")
  case "$o" in "claimed "*) frc_log "drained on exit: $o" ;; esac
  return 0
}

# frc_timeout <id> <box> <p> <ck> <attempt> <kind> <rc> <result> <record> —
#   THE TIMEOUT RE-OFFER (see the header). rc 0: the row was re-offered or
#   finished at the cap here; rc 1: the caller makes the normal finish.
frc_timeout() {
  local id="$1" box="$2" p="$3" ck="$4" attempt="$5" kind="$6" rc="$7" res="$8" rec="$9"
  local f vf head n k last rec2 rrc=0 why result list
  if [ -z "$rec" ]; then
    f="$H/state/blocked-resolver/$p/$ck.json"
    rec=$(jq -c --arg p "$p" 'select(.project == $p)' "$f" 2>/dev/null)
  fi
  if [ -z "$rec" ]; then
    frc_log "row $id $p/$ck: timed out ($kind, rc=$rc) and there is no record of $p to carry the timeout count — not re-offered"
    return 1
  fi
  head=$(printf '%s' "$rec" | jq -r '.agent_done.head // "-" | ascii_downcase' 2>/dev/null); head="${head:--}"
  # FIX_ROUND_TIMEOUT_RETRIES: lane.fix-round-claim.FIX_ROUND_TIMEOUT_RETRIES (fallback 2)
  n=$(frc_knob fix-round-claim FIX_ROUND_TIMEOUT_RETRIES 2 "$p"); [ "$n" -ge 1 ] 2>/dev/null || n=1
  vf="$H/state/blocked-resolver/$p/$ck.fix-verify.txt"
  last=$(grep -E '^[A-Z_]+_EXIT: |^VERIFY_TIMEOUT: ' "$vf" 2>/dev/null | tail -1)
  [ "$kind" = round ] && last="killed at the round bound ${FRC_T}s${last:+; last verify line: $last}"
  rec2=$(printf '%s' "$rec" | jq -c --arg h "$head" --arg k "$kind" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg rc "$rc" --arg a "$attempt" --arg l "${last:-none}" \
      '.timeout_requeues = ((.timeout_requeues // []) + [{head:$h, kind:$k, at:$at, rc:($rc|tonumber? // $rc), attempt:($a|tonumber? // $a), last:$l}])' 2>/dev/null)
  [ -n "$rec2" ] || { frc_log "row $id $p/$ck: the timeout entry could not be added to the record — not re-offered"; return 1; }
  k=$(printf '%s' "$rec2" | jq --arg h "$head" '[.timeout_requeues[] | select(.head == $h)] | length' 2>/dev/null)
  [ "$kind" = verify ] && frc_event fix_round_verify_timeout "$p" "$ck" "row $id attempt $attempt: the agent is done, verification ran out (${last:-no step line})"
  if [ "${k:-0}" -lt "$n" ] 2>/dev/null; then
    fix_round_requeue "$id" "$box" "$rec2" 2>>"$LOG" || rrc=$?
    if [ "$rrc" = 0 ]; then
      FRC_FIN=requeued; FRC_RESULT="verify-timeout"
      frc_log "row $id re-offered after a timeout (attempt $((attempt + 1)), timeout $k of $n) — $kind, rc=$rc"
      frc_event fix_round_requeued "$p" "$ck" "row $id: retry queued on $box at once (attempt $((attempt + 1)), timeout $k of $n)"
      return 0
    fi
    frc_log "row $id $p/$ck: the re-offer after a timeout answered rc $rrc — finished instead"
    return 1
  fi
  why="$k timed-out rounds on head ${head:0:8} (FIX_ROUND_TIMEOUT_RETRIES=$n) on $box; last: ${last:-none}"
  case "$res" in
    "verify-timeout "*) result="$res" ;;
    *) if [ "$head" != - ]; then result="verify-timeout $(frc_b64 "$why")"; else result="setup-blocked $(frc_b64 "$why")"; fi ;;
  esac
  frc_finish "$id" "$box" "$result" "$rec2" "timeout cap"
  if [ "$FRC_FIN" = ok ]; then
    frc_log "row $id timeout cap reached ($k of $n timeouts on head ${head:0:8})"
    list=$(printf '%s' "$rec2" | jq -r --arg h "$head" '[.timeout_requeues[] | select(.head == $h)
      | "attempt \(.attempt): \(.kind), rc \(.rc), \(.last)"] | join("; ")' 2>/dev/null)
    "$H/bin/lane-alert.sh" --id "fix-round-timeout-cap-$p-$ck-${head:0:8}" fix-round-claim \
      "$p/$ck: fix-round row $id timed out $k times on head ${head:0:8} on $box (FIX_ROUND_TIMEOUT_RETRIES=$n), finished ${result%% *} — $list" \
      >/dev/null 2>&1 || true
    frc_event fix_round_timeout_cap "$p" "$ck" "row $id: $k timeouts on head ${head:0:8}, finished ${result%% *}"
  fi
  return 0
}

# frc_run_round <id> <rowfile> — the round itself (frc_run's body).
frc_run_round() {
  local id="$1" rowf="$2" box row p ck attempt rin args_json fin out rc=0 line rb64="" rjson="" res=""
  local f n0 n1 repo result why where tok grace sidf sid w kind nrq
  local -a args=() wts=()
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
    exec 9>&-
    frc_log "row $id: a live runner owns $p/$ck, nothing run, nothing posted"
    return 0
  fi
  FRC_LOCKED=1

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
  # no placement read there, so the round never loops back to the pool. A row
  # re-offered after a timeout (BH-9906) gets its own pool key.
  if [ "${FRC_POOL_RUN:-0}" != 1 ] && command -v frp_placed >/dev/null 2>&1 && frp_placed "$p"; then
    nrq=0; [ -n "$rin" ] && nrq=$(printf '%s' "$rin" | jq '(.timeout_requeues // []) | length' 2>/dev/null)
    frp_put "$id" "$box" "$p" "$ck" "$attempt" "${nrq:-0}"
    if [ "$FRP_WORD" = ran ]; then
      frc_finish "$id" "$box" "setup-blocked $(frc_b64 "the Fly pool already ran this round as $FRP_KEY ($FRP_ST: $FRP_REASON) and no finish landed; it is not run a second time")" "" "pool row $FRP_ST"
    fi
    return 0
  fi

  where="$box"; [ "${FRC_POOL_RUN:-0}" = 1 ] && where="the Fly pool for $box"
  frc_bound "$p"
  if [ -z "$FRC_T" ]; then
    frc_finish "$id" "$box" "setup-blocked $(frc_b64 "the round bound on $where is not a number of seconds (BR_FIX_AGENT_TIMEOUT + BR_FIX_VERIFY_TIMEOUT + BR_FIX_HOP_MARGIN, fallback BR_FIX_LANE_TIMEOUT), so the round was not started")" "" "no timeout"
    return 0
  fi
  # FIX_ROUND_KILL_GRACE_S: lane.fix-round-claim.FIX_ROUND_KILL_GRACE_S (fallback 60)
  grace=$(frc_knob fix-round-claim FIX_ROUND_KILL_GRACE_S 60 "$p")
  fin=$(mktemp "${TMPDIR:-/tmp}/fix-round-in.XXXXXX") && out=$(mktemp "${TMPDIR:-/tmp}/fix-round-out.XXXXXX") \
    && sidf=$(mktemp "${TMPDIR:-/tmp}/fix-round-sid.XXXXXX") || {
    rm -f "${fin:-}" "${out:-}"
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
  frc_log "row $id $p/$ck attempt $attempt: fix round starting (bound ${FRC_T}s)"
  # THE ROUND IN A SESSION OF ITS OWN (BH-9906), with the build limits
  # (BH-8281: CARGO_BUILD_JOBS and a lower CPU priority), so this runner's own
  # priority does not change. bl_apply's stdout goes nowhere: $out is parsed
  # for FIX_* lines. The round inherits the key lock (fd 9), so a re-offered
  # runner sees it held while any process of the round lives.
  FRC_WT_OWNER=1 FRC_KILL_GRACE="$grace" setsid -w bash -c '
    echo "$$" > "$1"
    if . "$2/bin/lib/build-limits.sh" 2>/dev/null; then
      bl_apply "$2" "$3" >/dev/null 2>>"$4" || :
    fi
    g="$5"; t="$6"; h="$2"; shift 6
    exec timeout -k "$g" "$t" "$h/bin/blocked-resolver.sh" --fix-here "$@"' _ "$sidf" "$H" "$p" "$LOG" "$grace" "$FRC_T" "${args[@]}" \
    < "$fin" > "$out" 8>&- || rc=$?
  unset GH_TOKEN
  [ "$fin" = /dev/null ] || rm -f "$fin"
  # Nothing of the round outlives it: every process of its session, then the
  # worktrees it named (only under tmp/brfix/, only with no cwd under them).
  sid=$(cat "$sidf" 2>/dev/null); rm -f "$sidf"
  if command -v frr_session_sweep >/dev/null 2>&1; then
    if frr_session_sweep "$sid" "$grace"; then frc_log "row $id: round session ${sid:-?} swept, no process left (rc=$rc)"
    else frc_log "row $id: round session ${sid:-?}: a process outlived the sweep (rc=$rc)"; fi
  fi
  while IFS= read -r line; do
    case "$line" in
      "FIX_RECORD "*) rb64="${line#FIX_RECORD }" ;;
      "FIX_RESULT "*) [ -n "$res" ] || res="${line#FIX_RESULT }" ;;
      "FIX_WT "*) wts+=("${line#FIX_WT }") ;;
    esac
  done < "$out"
  rm -f "$out"
  for w in ${wts[@]+"${wts[@]}"}; do
    case "$w" in
      "$H/tmp/brfix/"?*) [ -e "$w" ] && command -v frr_wt_remove >/dev/null 2>&1 && frr_wt_remove "$w" "$grace" \
                           && frc_log "row $id: removed the round's worktree $w after its session was empty" ;;
    esac
  done
  if [ -n "$rb64" ]; then
    rjson=$(printf '%s' "$rb64" | base64 -d 2>/dev/null | jq -c --arg p "$p" 'select(.project == $p)' 2>/dev/null)
    [ -n "$rjson" ] || frc_log "row $id $p/$ck: the round sent back a record that is not $p's, it is not posted"
  fi
  kind=""
  case "$res" in
    verify-timeout|"verify-timeout "*) kind=verify ;;
    "") [ "$rc" = 124 ] && kind=round ;;
  esac
  if [ -n "$kind" ] && frc_timeout "$id" "$box" "$p" "$ck" "$attempt" "$kind" "$rc" "$res" "$rjson"; then
    return 0
  fi
  if [ -z "$res" ]; then
    result="setup-blocked $(frc_b64 "the round on $where gave no FIX_RESULT (rc=$rc)")"
  elif grep -qE '^(done|terminal|rebuild-fresh|setup-blocked [^ ]+|box-paused [^ ]+|verify-timeout( [^ ]+)?)$' <<<"$res"; then
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
  local id="${1:-}" box="${2:-}" p="${3:-}" ck="${4:-}" blocked="" row rc=0 have rowf tmpd why
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
  # shellcheck source=lib/fix-round-reap.sh
  . "$H/bin/lib/fix-round-reap.sh" 2>/dev/null || frc_log "bin/lib/fix-round-reap.sh missing on the machine; no session sweep after the round"
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
    # The round found a worktree that is not the PR's (BH-8896): its own word,
    # so the hub reap closes the row failed, never done.
    case "$FRC_RESULT" in
      "setup-blocked "*)
        why=$(printf '%s' "${FRC_RESULT#setup-blocked }" | base64 -d 2>/dev/null | tr '\n\r' '  ')
        case "$why" in FIX_ROUND_WRONG_TREE*)
          echo "FIX_ROUND_WRONG_TREE ${why:0:200} finish=$FRC_FIN"; return 0 ;;
        esac ;;
    esac
    echo "FIX_ROUND_FINISHED ${FRC_RESULT%% *} finish=$FRC_FIN"
  else
    echo "FIX_ROUND_SETUP_FAILED the round did not start: ${FRC_LAST:-no reason logged}"
  fi
  return 0
}

# frc_run_max <box> — the box's run limit: the minimum of
#   lane.fix-round-claim.<p>.FIX_ROUND_RUN_MAX over the projects this box owns
#   (the fleet row when it owns none). Not a number: the fallback 1, one line.
frc_run_max() {
  local box="$1" p v min="" projs
  projs=$("$H/bin/fleet-conf.sh" --projects-on-box "$box" 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    v=$(lane_knob fix-round-claim FIX_ROUND_RUN_MAX "$p")
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
  done <<<"$projs"
  [ -n "$min" ] || min=$(lane_knob fix-round-claim FIX_ROUND_RUN_MAX)
  case "$min" in
    ''|*[!0-9]*)
      # FIX_ROUND_RUN_MAX: lane.fix-round-claim.FIX_ROUND_RUN_MAX (fallback 1)
      frc_log "FIX_ROUND_RUN_MAX is '$min', not a number — the fallback 1 is used"; min=1 ;;
  esac
  printf '%s' "$min"
}

# frc_wait_spawn <pid> <job-json> <seconds> — wait until the runner holds its
#   key lock or has exited, bounded.
frc_wait_spawn() {
  local pid="$1" job="$2" w="$3" p ck lock="" i
  p=$(printf '%s' "$job" | jq -r '.project // empty | strings' 2>/dev/null)
  ck=$(printf '%s' "$job" | jq -r '.cap_key // empty | strings' 2>/dev/null)
  if grep -qE '^[A-Za-z0-9._-]+$' <<<"$p" && grep -qE '^[A-Za-z0-9._-]+$' <<<"$ck"; then lock="$H/locks/fix-round-$p-$ck.lock"; fi
  for (( i = 0; i < w * 5; i++ )); do
    kill -0 "$pid" 2>/dev/null || return 0
    [ -n "$lock" ] && frr_lock_held "$lock" && return 0
    sleep 0.2
  done
  frc_log "the runner for row $(printf '%s' "$job" | jq -r '.id // "?"' 2>/dev/null) did not hold its lock within ${w}s — counted as not running"
  return 0
}

# frc_tick [drain] — ONE claim pass: count the live runners, claim up to the
#   run limit and the claim max, spawn one detached runner per row. Sets
#   FRC_CLAIMED; FRC_PASS=busy when another pass held the pass lock.
frc_tick() {
  local drain="${1:-}" box on max stale i rc job id rowf tmpd claimed=0 lost=0 failed="" pid
  local runmax running=0 held="" spawnw passw
  FRC_CLAIMED=0; FRC_PASS=""
  on=$(lane_knob fix-round-claim FIX_ROUND_CLAIM)
  [ "$on" = 0 ] && return 0
  # shellcheck source=jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck source=lib/fix-round-queue.sh
  . "$H/bin/lib/fix-round-queue.sh" || { frc_log "bin/lib/fix-round-queue.sh missing, nothing claimed"; return 0; }
  # shellcheck source=lib/fix-round-reap.sh
  . "$H/bin/lib/fix-round-reap.sh" || { frc_log "bin/lib/fix-round-reap.sh missing, nothing claimed (the run limit cannot be counted)"; return 0; }
  if ! declare -F jobs_configured >/dev/null || ! jobs_configured || [ -z "${HARNESS_SECRET:-}" ]; then
    frc_log "not configured (JOBS_URL/HARNESS_SECRET unset), nothing claimed"
    return 0
  fi
  box=$(local_box_name)
  [ -n "$box" ] || { frc_log "this box cannot name itself (bin/box-name.sh), nothing claimed"; return 0; }
  max=$(lane_knob fix-round-claim FIX_ROUND_CLAIM_MAX)
  case "$max" in ''|*[!0-9]*) frc_log "FIX_ROUND_CLAIM_MAX is '$max', not a number, nothing claimed"; return 0 ;; esac
  # ONE CLAIM PASS AT A TIME (BH-9906): the count and the claims are one step.
  mkdir -p "$H/locks" 2>/dev/null
  exec 8>"$H/locks/frc-claim-pass.lock" || { frc_log "cannot open locks/frc-claim-pass.lock, nothing claimed"; return 0; }
  if [ "$drain" = drain ]; then
    # FIX_ROUND_PASS_WAIT_S: lane.fix-round-claim.FIX_ROUND_PASS_WAIT_S (fallback 30)
    passw=$(frc_knob fix-round-claim FIX_ROUND_PASS_WAIT_S 30)
    if ! flock -w "$passw" 8; then
      FRC_PASS=busy
      frc_log "drain: another claim pass ran past ${passw}s, nothing claimed (the cron tick claims within 2 minutes)"
      return 0
    fi
  elif ! flock -n 8; then
    FRC_PASS=busy
    frc_log "tick: another claim pass is running (a runner's drain), nothing claimed"
    return 0
  fi
  runmax=$(frc_run_max "$box")
  # FIX_ROUND_SPAWN_WAIT_S: lane.fix-round-claim.FIX_ROUND_SPAWN_WAIT_S (fallback 10)
  spawnw=$(frc_knob fix-round-claim FIX_ROUND_SPAWN_WAIT_S 10)
  frc_bound
  stale=""; [ -n "$FRC_STALE_S" ] && stale=$(( (FRC_STALE_S + 59) / 60 ))
  tmpd="$H/tmp"; mkdir -p "$tmpd" 2>/dev/null || tmpd="${TMPDIR:-/tmp}"
  for (( i = 1; i <= max; i++ )); do
    running=$(frr_running "$H/locks")
    if [ "$running" -ge "$runmax" ]; then held=1; break; fi
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
      FRC_IN_PASS=1 "$H/bin/fix-round-claim.sh" --run "$id" "$rowf" </dev/null >>"$LOG" 2>&1 8>&-
    else
      setsid "$H/bin/fix-round-claim.sh" --run "$id" "$rowf" </dev/null >>"$LOG" 2>&1 8>&- &
      pid=$!
      frc_wait_spawn "$pid" "$job" "$spawnw"
    fi
  done
  if [ -n "$held" ]; then
    frc_log "held back: $running of $runmax running$([ "$claimed" -gt 0 ] && printf ' (claimed %s this pass)' "$claimed")"
  fi
  if [ "$claimed" -gt 0 ] || [ "$lost" -gt 0 ] || [ -n "$failed" ]; then
    frc_log "${drain:-tick} on $box: claimed $claimed, lost $lost race(s)${stale:+, stale_min $stale}${failed:+, $failed}"
  fi
  FRC_CLAIMED=$claimed
  exec 8>&-
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
# shellcheck source=lib/fix-retry-budget.sh
. "$H/bin/lib/fix-retry-budget.sh" 2>/dev/null || true   # BH-10057: frc_bound's retry agent budget

if [ "${1:-}" = --run-pool ]; then
  shift
  frc_run_pool "$@"
  exit 0
fi

if [ "${1:-}" = --drain ]; then
  # THE DRAIN (BH-9906): the claim pass a runner makes as it exits. No start
  # offset or wake gate (it is not a scheduled tick); the hub, the lane switch
  # and the factory stop still stop it.
  is_hub_box "$(local_box_name)" && exit 0
  if command -v lane_paused >/dev/null 2>&1 && lane_paused fix-round-claim; then
    frc_log "drain: the lane is paused (${LANE_PAUSED_WHY:-switch}), nothing claimed"; exit 0
  fi
  if command -v _lg_lane_fstop >/dev/null 2>&1 && [ -n "$(_lg_lane_fstop fix-round-claim)" ] \
     && command -v _lg_factory_stopped >/dev/null 2>&1 && _lg_factory_stopped; then
    frc_log "drain: the factory stop is on, nothing claimed"; exit 0
  fi
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply fix-round-claim
  frc_tick drain
  [ "$FRC_PASS" = busy ] || echo "claimed ${FRC_CLAIMED:-0}"
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
  # shellcheck source=lib/fix-round-reap.sh
  . "$H/bin/lib/fix-round-reap.sh" 2>/dev/null || frc_log "row ${2:-?}: bin/lib/fix-round-reap.sh missing; no session sweep after the round"
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

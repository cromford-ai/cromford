#!/bin/bash
# bin/staff/mr-red.sh — BH-9532 (C0, #9539): Mr Red, the staff agent that owns
# red minutes. Hub only, every 5 minutes (cron/lanes/781-staff-mr-red.cron).
#
#   bin/staff/mr-red.sh tick             one pass: collect, claim, record, act
#   bin/staff/mr-red.sh work <payload>   the lane-run pool side of a lever
#
# TICK, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jq, jobs client, staff-contract.sh, mr-red.sh,
#      lane-placement.sh or HARNESS_SECRET = `not-configured (<what>)`.
#   2  KILL, before any request of its own: mrr_killed (STAFF_ENABLED=0, then
#      the flags staff-off-all, staff-kill-all, staff-off-mr-red,
#      staff-kill-mr-red) = `killed by <switch>`.
#   3  lane_gate_or_exit staff-mr-red (flags/lane-off-staff-mr-red).
#   4  flock -n locks/staff-mr-red.lock (dedupe, never a queue).
#   5  GET /api/staff/agent?name=mr-red: the status must be active.
#   6  the knobs, once: staff.mr-red.level (staff_level), .max_items_tick (50),
#      .lookback_h (24), .tick_timeout_s (240).
#   7  prune the check-run cache: files older than 2 x lookback_h.
#   8  COLLECT: MRR_TICK=1 bin/staff/mr-red-collect.sh; its deferred= and
#      incomplete= lines are kept.
#   9  per item, at most max_items_tick (the rest are deferred=):
#      CLAIM  POST /api/staff/findings/claim (agent mr-red). 200 = new, 409
#             already_claimed by mr-red = repeat (seen_count grows); 409
#             agent_not_active stops the tick; any other 409 is dropped; a
#             failed claim is skipped (claim_failed=) and comes back next tick.
#      PICK   level act: the first bin/staff/mr-red.d/NN-<lever>.sh, in file
#             order, whose mrr_<lever>_match <item> returns 0 and whose
#             mrr_loop_check <fp> <target> <lever> <approach> answers ok (any
#             other answer skips that lever, evidence why=loop:<lever>). Any
#             other level, or no match = lever observe.
#      RECORD POST /api/mr-red/actions BEFORE any act: observe = state
#             observed (terminal), a lever = state started. existing:true =
#             replay, no act; a 409 or a failure = post_failed, no act.
#      ACT    mrr_<lever>_act <item> <action-json>; PATCH the row done (rc 0),
#             dispatched (rc 3) or failed (any other rc, or no _act function:
#             why=no-act).
#      Elapsed >= tick_timeout_s stops the loop: timed_out=1.
#  10  MRR_INCOMPLETE=<list|-> mrr_judge_tick (bin/staff/mr-red-judge.sh).
#  11  one summary line. Every count comes from a worker answer:
#      level= items= new= repeat= deferred= rows= observed= acted= dispatched=
#      failed= replay= claim_failed= post_failed= dropped= incomplete=<list|->
#      timed_out=<0|1>
# There is no push counter and no size cap: the control is the action row and
# the outcome judge (the operator, #9532, 2026-11-11T13:49:47Z).
#
# WORK <payload>: the kill check, then the payload must be JSON with lever and
# action_key; bin/staff/mr-red.d/*.sh are sourced and mrr_<lever>_work
# <payload> runs. Its rc is the exit code. An unknown lever or no _work = 2.
#
# WRITES. logs/staff-mr-red.log; the rows through the jobs worker
# (staff_findings, staff_finding_seen, mr_red_actions, lane_runs); the check-run
# cache state/mr-red/checks/ (box-local, catalog/state-paths.d/9532-mr-red.json).
# EXIT 0 every tick that ran; 2 bad arguments.
# Env (test seams, HARNESS_TEST_SANDBOX=1 only): MRR_NOW (epoch seconds, passed
# to the collector). OFF: flags/lane-off-staff-mr-red (bin/harness-ctl.sh off
# staff-mr-red), or any kill switch above. Registry:
# catalog/lanes.d/staff-mr-red.json. Doc: docs/notes/2026-11-11-BH-9532-mr-red.md.
set -uo pipefail

VERB="${1:-}"
case "$VERB" in
  tick) [ $# = 1 ] || { echo "usage: mr-red.sh tick | work <payload-json>" >&2; exit 2; } ;;
  work) [ $# = 2 ] || { echo "usage: mr-red.sh tick | work <payload-json>" >&2; exit 2; } ;;
  -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
  *) echo "usage: mr-red.sh tick | work <payload-json>" >&2; exit 2 ;;
esac

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
LIBD="$(cd "$SELF/.." && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$LIBD/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-mr-red.log"
log() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$VERB" "$*" >> "$LOG"; }

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
# shellcheck source=bin/lib/lane-placement.sh
. "$H/bin/lib/lane-placement.sh" 2>/dev/null || . "$LIBD/lib/lane-placement.sh" 2>/dev/null
# shellcheck source=bin/lib/mr-red.sh
. "$H/bin/lib/mr-red.sh" 2>/dev/null || . "$LIBD/lib/mr-red.sh" 2>/dev/null
# shellcheck source=bin/lib/mr-red-loop.sh
. "$H/bin/lib/mr-red-loop.sh" 2>/dev/null || . "$LIBD/lib/mr-red-loop.sh" 2>/dev/null
for fn in _jobs_req flag_active setting_get; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_level >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
command -v lp_enqueue >/dev/null 2>&1 || { log "not-configured (no bin/lib/lane-placement.sh)"; exit 0; }
command -v mrr_killed >/dev/null 2>&1 || { log "not-configured (no bin/lib/mr-red.sh)"; exit 0; }
command -v mrr_loop_check >/dev/null 2>&1 || { log "not-configured (no bin/lib/mr-red-loop.sh)"; exit 0; }
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }

# ── 2 kill, before any request of its own ─────────────────────────────────────
if K=$(mrr_killed); then log "killed by $K"; exit 0; fi

# mrr_levers — the lever names of bin/staff/mr-red.d/NN-<lever>.sh, file order.
mrr_levers() {
  local f l
  for f in "$SELF"/mr-red.d/*.sh; do
    [ -f "$f" ] || continue
    l=$(basename "$f" .sh); l=${l#*-}
    [[ $l =~ ^[a-z][a-z0-9_]{0,39}$ ]] && printf '%s\n' "$l"
  done
}
load_levers() {
  local f
  for f in "$SELF"/mr-red.d/*.sh; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "$f"
  done
}

# ── WORK: the pool side ────────────────────────────────────────────────────────
if [ "$VERB" = work ]; then
  PAY="$2"
  jq -e '(.lever | type) == "string" and (.action_key | type) == "string"' <<<"$PAY" >/dev/null 2>&1 \
    || { log "bad payload (want JSON with lever and action_key)"; exit 2; }
  L=$(jq -r .lever <<<"$PAY")
  export LC_ALL=C
  load_levers
  if ! grep -qxF -- "$L" <<<"$(mrr_levers)" || ! declare -F "mrr_${L}_work" >/dev/null; then
    log "unknown lever '$L' or no mrr_${L}_work; nothing ran"; exit 2
  fi
  "mrr_${L}_work" "$PAY"; rc=$?
  log "lever=$L action=$(jq -r .action_key <<<"$PAY" | cut -c1-12) rc=$rc"
  exit "$rc"
fi

# ── 3 lane gate ────────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
# A missing lane gate is not-configured, like every other lib above: never run
# with the lane-off flag unread.
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 || { log "not-configured (no bin/lib/lane-gate.sh)"; exit 0; }
lane_gate_or_exit staff-mr-red
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-mr-red

# ── 4 lock ─────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-mr-red.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another mr-red tick is running"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mr-red.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
T0=$(date +%s)

# ── 5 roster ───────────────────────────────────────────────────────────────────
_jobs_req GET "/api/staff/agent?name=mr-red" > "$WORK/agent" 9>&-; rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' "$WORK/agent" 2>/dev/null)" = active ] || { log "mr-red is not active on the roster; nothing ran"; exit 0; }

# ── 6 knobs ────────────────────────────────────────────────────────────────────
L=$(staff_level mr-red 2>/dev/null) || true
[ -n "$L" ] || L=observe
MAXI=$(staff_knob mr-red max_items_tick 50)    # fallback 50; row staff.mr-red.max_items_tick
LOOK=$(staff_knob mr-red lookback_h 24)        # fallback 24; row staff.mr-red.lookback_h
TTO=$(staff_knob mr-red tick_timeout_s 240)    # fallback 240; row staff.mr-red.tick_timeout_s

# ── 7 prune the check-run cache ────────────────────────────────────────────────
CDIR="$H/state/mr-red/checks"
[ -d "$CDIR" ] && find "$CDIR" -maxdepth 1 -type f -name '*.json' -mmin +$((LOOK * 120)) -delete 2>/dev/null

# ── 8 collect ──────────────────────────────────────────────────────────────────
# The collector stops each source at the deadline itself; the outer timeout is
# only a backstop against a runner that does not return.
MRR_TICK=1 MRR_LOOKBACK_H="$LOOK" MRR_MAX_ITEMS="$MAXI" MRR_DEADLINE=$((T0 + TTO)) \
  timeout -k 5 $((TTO + 10)) "$SELF/mr-red-collect.sh" > "$WORK/collect" 2>/dev/null 9>&-; crc=$?
INCOMPLETE=$(grep -E '^incomplete=' "$WORK/collect" | tail -1 | cut -d= -f2-)
[ "$crc" = 0 ] || [ -n "$INCOMPLETE" ] || INCOMPLETE=collector
DEFERRED=$(grep -E '^deferred=[0-9]+$' "$WORK/collect" | tail -1 | cut -d= -f2)
DEFERRED=${DEFERRED:-0}
jq -cR 'try fromjson catch empty | select(type == "object" and (.item | type) == "object")' "$WORK/collect" > "$WORK/items" 2>/dev/null
NITEMS=$(grep -c . "$WORK/items")

N_NEW=0 N_REP=0 ROWS=0 OBS=0 ACTED=0 DISP=0 FAILED=0 REPLAY=0 CLAIMF=0 POSTF=0 DROP=0 TIMED=0 DONE_N=0
# A collector that used the whole budget is a timed-out tick too.
[ $(( $(date +%s) - T0 )) -ge "$TTO" ] && TIMED=1
summary() {
  log "level=$L items=$NITEMS new=$N_NEW repeat=$N_REP deferred=$DEFERRED rows=$ROWS observed=$OBS acted=$ACTED dispatched=$DISP failed=$FAILED replay=$REPLAY claim_failed=$CLAIMF post_failed=$POSTF dropped=$DROP incomplete=${INCOMPLETE:--} timed_out=$TIMED"
}
export LC_ALL=C
[ "$L" = act ] && load_levers
LEVERS=$(mrr_levers)

# patch_state <key> <state> <evidence-json> — PATCH, count the 2xx answer.
patch_state() {
  jq -nc --arg s "$2" --argjson e "$3" '{state: $s, evidence_json: $e}' > "$WORK/patch.json"
  if mrr_action_patch "$1" "$(cat "$WORK/patch.json")" > "$WORK/patch.out" 9>&-; then
    case "$2" in done) ACTED=$((ACTED + 1)) ;; dispatched) DISP=$((DISP + 1)) ;; *) FAILED=$((FAILED + 1)) ;; esac
  else
    log "action ${1:0:12} not patched to $2 (HTTP ${JOBS_HTTP:-none})"
  fi
}

# ── 9 per item ─────────────────────────────────────────────────────────────────
while IFS= read -r it; do
  if [ "$DONE_N" -ge "$MAXI" ]; then DEFERRED=$((DEFERRED + 1)); continue; fi
  if [ "$TIMED" = 1 ] || [ $(( $(date +%s) - T0 )) -ge "$TTO" ]; then TIMED=1; DEFERRED=$((DEFERRED + 1)); continue; fi
  DONE_N=$((DONE_N + 1))
  # CLAIM
  jq -c '{agent: "mr-red", item, title, source, observedAt, class}' <<<"$it" > "$WORK/claim.json"
  JOBS_HTTP=""
  _jobs_req POST /api/staff/findings/claim "$(cat "$WORK/claim.json")" > "$WORK/claim.out" 9>&-; rc=$?
  SEEN=$(jq -r '.seen_count // empty' "$WORK/claim.out" 2>/dev/null)
  if [ "$rc" = 0 ] && jq -e '.claimed == true' "$WORK/claim.out" >/dev/null 2>&1; then
    N_NEW=$((N_NEW + 1))
  elif [ "$rc" = 9 ]; then
    case "$(jq -r '.error // ""' "$WORK/claim.out" 2>/dev/null)" in
      already_claimed)
        if [ "$(jq -r '.finding.agent // ""' "$WORK/claim.out")" = mr-red ]; then N_REP=$((N_REP + 1)); else DROP=$((DROP + 1)); continue; fi ;;
      agent_not_active) log "claim answered agent_not_active; tick stopped"; break ;;
      *) DROP=$((DROP + 1)); continue ;;
    esac
  else
    CLAIMF=$((CLAIMF + 1)); log "claim failed (rc=$rc HTTP ${JOBS_HTTP:-none}) for $(jq -r .target <<<"$it"); next tick"
    continue
  fi
  FP=$(jq -r .fingerprint <<<"$it"); TGT=$(jq -r .target <<<"$it")
  # PICK
  LEV=observe APPR=none WHY=""
  if [ "$L" = act ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      declare -F "mrr_${l}_match" >/dev/null || continue
      "mrr_${l}_match" "$it" 9>&- || continue
      a=none
      if declare -F "mrr_${l}_approach" >/dev/null; then a=$("mrr_${l}_approach" "$it" 9>&-) || a=none; [ -n "$a" ] || a=none; fi
      if [ "$(mrr_loop_check "$FP" "$TGT" "$l" "$a" 9>&-)" != ok ]; then WHY="${WHY:+$WHY,}loop:$l"; continue; fi
      LEV=$l; APPR=$a; break
    done <<<"$LEVERS"
  fi
  ST=started; [ "$LEV" = observe ] && ST=observed
  # RECORD, before any act
  jq -c --arg l "$LEV" --arg a "$APPR" --arg s "$ST" --arg w "$WHY" --arg seen "${SEEN:-}" '
    {lever: $l, target, fingerprint, repo, project, target_kind: (.target_kind // "pr"), approach: $a, state: $s,
     dry_run: 0, red_check: (.checks[0] // null),
     evidence_json: ({head, checks, seen_count: ($seen | tonumber? // null)} + (if $w == "" then {} else {why: $w} end))}' \
    <<<"$it" > "$WORK/action.json"
  JOBS_HTTP=""
  mrr_action_post "$(cat "$WORK/action.json")" > "$WORK/action.out" 9>&-; rc=$?
  if [ "$rc" = 0 ] && jq -e '.ok == true and .existing == false and (.action.action_key | type) == "string"' "$WORK/action.out" >/dev/null 2>&1; then
    ROWS=$((ROWS + 1)); [ "$LEV" = observe ] && OBS=$((OBS + 1))
  elif [ "$rc" = 0 ] && jq -e '.ok == true and .existing == true' "$WORK/action.out" >/dev/null 2>&1; then
    REPLAY=$((REPLAY + 1)); continue
  else
    POSTF=$((POSTF + 1)); log "action not recorded (rc=$rc HTTP ${JOBS_HTTP:-none}) for $TGT; no act"; continue
  fi
  [ "$LEV" = observe ] && continue
  # ACT
  AKEY=$(jq -r .action.action_key "$WORK/action.out")
  if ! declare -F "mrr_${LEV}_act" >/dev/null; then patch_state "$AKEY" failed '{"why":"no-act"}'; continue; fi
  "mrr_${LEV}_act" "$it" "$(jq -c .action "$WORK/action.out")" > "$WORK/act.out" 2>&1 9>&-; arc=$?
  case "$arc" in
    0) patch_state "$AKEY" done "$(jq -nc --argjson r 0 '{act_rc: $r}')" ;;
    3) patch_state "$AKEY" dispatched '{"act_rc":3}' ;;
    *) patch_state "$AKEY" failed "$(jq -nc --argjson r "$arc" '{act_rc: $r}')" ;;
  esac
done < "$WORK/items"

# ── 10 judge ───────────────────────────────────────────────────────────────────
# shellcheck source=bin/staff/mr-red-judge.sh
. "$SELF/mr-red-judge.sh" 2>/dev/null
if declare -F mrr_judge_tick >/dev/null; then
  MRR_INCOMPLETE="${INCOMPLETE:--}" mrr_judge_tick 9>&- || log "mrr_judge_tick rc=$?"
else
  log "no mrr_judge_tick (bin/staff/mr-red-judge.sh); judge skipped"
fi

# ── 11 summary ─────────────────────────────────────────────────────────────────
summary
exit 0

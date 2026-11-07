#!/bin/bash
# bin/pool-wake-poll.sh — the pool dispatcher on queue depth (BH-9074,
# BH-9067.2; docs/events-bh-9067/2-wake-pollers.bh-9074.md). A hub lane on a
# `* * * * *` line under `flock -n locks/pool-wake-poll.lock`
# (cron/lanes/241-pool-wake-poll.cron). One run polls
#
#   GET /api/wakes?repo=harness%2Fbuild-queue&since=<cursor>&limit=<LIMIT>
#
# every POOL_WAKE_POLL_S seconds while elapsed + POOL_WAKE_POLL_S fits in
# POOL_WAKE_POLL_WINDOW_S. A new queue row starts bin/fly-dispatch.sh and
# bin/fly-pool-tick.sh detached (the launch() shape of bin/wake-loop.sh) and
# only then moves the cursor, so a queued build starts in about 10 s instead of
# at the next */10 tick. The */10 lines of 190-fly-dispatch.cron and
# 240-fly-pool-tick.cron stay as the backstop.
#
# THE CURSOR. state/pool-wake-poll/cursor, one integer: the largest wakes id
# read. It moves to the largest id an answer returned (a capped page moves it
# only that far, and the next poll reads on). A row whose repo is not
# harness/build-queue moves the cursor and never launches (a mis-filtered
# answer). No cursor, or junk in it: the run SEEDS. It pages from 0 to the end
# without a launch (state/pool-wake-poll/cursor.seed holds the progress when the
# window ends first) and logs `seeded cursor=<id> pages=<n>`. History never
# launches a lane.
#
# Lines in logs/pool-wake-poll.log:
#   pool-wake-poll launched wake=<first id> rows=<n>
#   pool-wake-poll launch-failed wake=<id> (<name> not executable)   once per run, cursor kept
#   pool-wake-poll read-failed (<why>)                               once per run, cursor kept
#   pool-wake-poll seeded cursor=<id> pages=<n>
#   pool-wake-poll <KNOB>='<v>' is not a whole number <lo>..<hi> — using <d>
# Every path exits 0 (a cron line).
#
# Knobs (rows lane.pool-wake-poll.<env lowercased>): POOL_WAKE_POLL_S (10),
# POOL_WAKE_POLL_WINDOW_S (55), POOL_WAKE_POLL_LIMIT (100).
# Off switch: flags/lane-off-pool-wake-poll (bin/harness-ctl.sh off pool-wake-poll).
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
LOG="$H/logs/pool-wake-poll.log"
say() { mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "pool-wake-poll $*" >> "$LOG" 2>/dev/null; return 0; }

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pool-wake-poll
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pool-wake-poll
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" >/dev/null 2>&1 || true
command -v _jobs_req >/dev/null 2>&1 || { say "read-failed (no jobs client)"; exit 0; }
command -v jq >/dev/null 2>&1 || { say "read-failed (no jq)"; exit 0; }

# knob <name> <value> <lo> <hi> <fallback> — a whole number in bounds, else
# the fallback and one line.
knob() {
  local v="$2"
  if [[ $v =~ ^[0-9]{1,4}$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then
    printf '%s' "$((10#$v))"
  else
    say "$1='$v' is not a whole number $3..$4 — using $5"
    printf '%s' "$5"
  fi
}
# Code fallbacks = the registry defaults of the rows lane.pool-wake-poll.pool_wake_poll_s,
# .pool_wake_poll_window_s and .pool_wake_poll_limit.
S=$(knob POOL_WAKE_POLL_S "${POOL_WAKE_POLL_S:-10}" 1 60 10)
WINDOW=$(knob POOL_WAKE_POLL_WINDOW_S "${POOL_WAKE_POLL_WINDOW_S:-55}" 1 58 55)
LIMIT=$(knob POOL_WAKE_POLL_LIMIT "${POOL_WAKE_POLL_LIMIT:-100}" 1 500 100)

D="$H/state/pool-wake-poll"
CF="$D/cursor"
mkdir -p "$D" 2>/dev/null
# put <file> <id> — temp file, then mv.
put() { printf '%s\n' "$2" > "$1.$$" 2>/dev/null && mv -f "$1.$$" "$1" 2>/dev/null; }

T0=$(date +%s)
elapsed() { echo $(( $(date +%s) - T0 )); }
READ_SAID=0
# read_page <since> — WAKES = the answer's .wakes array, rc 1 (one line per run) when it fails.
read_page() {
  local out
  out=$(JOBS_TIMEOUT=$S JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 \
    _jobs_req GET "/api/wakes?repo=harness%2Fbuild-queue&since=$1&limit=$LIMIT" 2>/dev/null)
  local rc=$?
  WAKES=""
  if [ "$rc" -eq 0 ]; then
    WAKES=$(jq -ce '.wakes | select(type == "array")' <<<"$out" 2>/dev/null) || WAKES=""
  fi
  if [ -z "$WAKES" ]; then
    if [ "$READ_SAID" = 0 ]; then
      if [ "$rc" -ne 0 ]; then say "read-failed (${JOBS_HTTP:+http=}${JOBS_HTTP:-no answer})"
      else say "read-failed (bad answer)"; fi
      READ_SAID=1
    fi
    return 1
  fi
  return 0
}
# top_id — the largest numeric id in WAKES, or empty.
top_id() { jq -r '[.[] | .id | select(type == "number" and . == floor)] | max // empty' <<<"$WAKES"; }

CUR=$(tr -d '[:space:]' < "$CF" 2>/dev/null)
if ! [[ $CUR =~ ^[0-9]{1,18}$ ]]; then
  # SEED: page to the end, launch nothing.
  c=$(tr -d '[:space:]' < "$CF.seed" 2>/dev/null); [[ $c =~ ^[0-9]{1,18}$ ]] || c=0
  pages=0
  while :; do
    read_page "$c" || exit 0
    pages=$((pages + 1))
    t=$(top_id); [ -n "$t" ] && [ "$t" -gt "$c" ] && c=$t
    if [ "$(jq 'length' <<<"$WAKES")" -lt "$LIMIT" ]; then
      put "$CF" "$c" || { say "read-failed (cursor not written)"; exit 0; }
      rm -f "$CF.seed"
      say "seeded cursor=$c pages=$pages"
      exit 0
    fi
    if [ "$(elapsed)" -ge "$WINDOW" ]; then
      put "$CF.seed" "$c"
      say "seeding cursor=$c pages=$pages (the window ended; the next run reads on)"
      exit 0
    fi
  done
fi

LAUNCH_SAID=0
while :; do
  if read_page "$CUR"; then
    ours=$(jq -c --argjson c "$CUR" '[.[] | select(.repo == "harness/build-queue" and (.id | type) == "number" and .id > $c) | .id]' <<<"$WAKES")
    n=$(jq 'length' <<<"$ours")
    top=$(top_id)
    if [ "$n" -eq 0 ]; then
      [ -n "$top" ] && [ "$top" -gt "$CUR" ] && put "$CF" "$top" && CUR=$top
    else
      first=$(jq '.[0]' <<<"$ours")
      miss=""
      for s in fly-dispatch.sh fly-pool-tick.sh; do
        [ -f "$H/bin/$s" ] && [ -x "$H/bin/$s" ] || { miss=$s; break; }
      done
      if [ -n "$miss" ]; then
        [ "$LAUNCH_SAID" = 1 ] || say "launch-failed wake=$first ($miss not executable)"
        LAUNCH_SAID=1
      else
        # Launch first, cursor second: a crash in between repeats one launch,
        # which the fly lanes' own locks absorb. LANE_SINGLE_RUN=1 makes each
        # a scheduled tick of its lane (one run per lane), like the cron line.
        for s in fly-dispatch.sh fly-pool-tick.sh; do
          ( env -u LANE_GATE_RUN LANE_SINGLE_RUN=1 WAKE_LAUNCH=1 setsid "$H/bin/$s" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
        done
        say "launched wake=$first rows=$n"
        put "$CF" "$top" && CUR=$top
      fi
    fi
  fi
  [ $(( $(elapsed) + S )) -le "$WINDOW" ] || break
  sleep "$S"
done
exit 0

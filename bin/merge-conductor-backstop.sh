#!/bin/bash
# bin/merge-conductor-backstop.sh — BH-3436.2 (BH-3454): the */5 KEYED backstop
# for the merge conductor. Worst case green -> queued is 5 minutes without the
# heavy full tick, which stays */30 (BH-1389, cron/lanes/410).
#
# WHAT IT READS: state/merge-conductor/pr-state.tsv, nothing else. A candidate
# is a row in WAIT_CI or READY whose reviewed sha equals its head. No candidate
# = one log line and exit 0, with no GitHub call and no conductor run.
# Otherwise EVERY candidate gets its own detached keyed conductor run,
# `MC_ONLY_PR=<key>`, under its own `timeout MC_BACKSTOP_TIMEOUT_S` (default
# 240) and its own per-key flock (locks/mc-backstop-<key>.lock), with its PR
# worker capped below that timeout (MC_WORKER_DEADLINE_CAP_S, BH-4918). That
# run skips the fleet sweeps, the main-red detector and mc_tick_metrics (the
# cadence hold is not reset), and runs ae_project over its row, so a green row
# goes READY and is enqueued in the same run.
#
# NO CAP AND NO SHARED WINDOW (BH-6000, 2026-10-11). Until then one keyed run
# took at most MC_BACKSTOP_MAX_KEYS (6) keys under one shared worker window
# (MC_WORKERS_DONE_BY), carried the rest to later fires, and logged
# WINDOW_DEFERRED for a key the window could not fit: #4546, #5704, #5727,
# #5990 and #5999 logged it on every fire. Now a fire starts one run per
# candidate and returns at once. A key whose run from an earlier fire still
# holds its lock is left alone (logged) and offered again on the next fire, so
# a key is never started twice and never dropped. MC_BACKSTOP_MAX_KEYS is
# deprecated: read, named in the log when set, and otherwise ignored. The
# carry file (state/merge-conductor/backstop-carry) is no longer written.
#
# WHAT IT COSTS: nothing on an idle fleet. Per candidate, one conductor
# process (its own project-level reads: one ETag-cached open-PR list) plus the
# conductor's usual per-PR reads (pull, check-runs, thread; the read memo skips
# unchanged heads) and at most one `@mergifyio queue` post.
#
# OFF: bin/harness-ctl.sh off merge-conductor-backstop. It also stands down,
# exit 0, when flags/automerge-disabled or the conductor's own
# lane-off-merge-conductor is set.
set -uo pipefail
HARNESS="${HARNESS:-${H:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}}"
[ -n "$HARNESS" ] || { echo "merge-conductor-backstop: no harness root" >&2; exit 1; }
export HARNESS; H="$HARNESS"
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# HARNESS_REPO: the project this fire takes first. Fail-soft: without the file,
# no project goes first.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" 2>/dev/null || true

# >>> lane gate — flags/all-off or flags/lane-off-merge-conductor-backstop (or a
# pause_flags row driving either) exits 0; lane_env_apply then lets a settings
# row reach MC_BACKSTOP_MAX_KEYS and MC_BACKSTOP_TIMEOUT_S. Both fail OPEN.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-conductor-backstop
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-conductor-backstop
# <<< lane gate

say() { printf '%s merge-conductor-backstop: %s\n' "$(date -u '+%F %T')Z" "$*"; }
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
flag_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi; }
for _f in automerge-disabled lane-off-merge-conductor; do
  flag_on "$_f" && { say "flags/$_f is set — standing down"; exit 0; }
done

ROWS="$H/state/merge-conductor/pr-state.tsv"
# MC_BACKSTOP_MAX_KEYS is DEPRECATED (BH-6000): every candidate gets its own
# run, so there is nothing to cap. The row stays readable so an operator who set
# it sees it named, never silently ignored.
CAP="${MC_BACKSTOP_MAX_KEYS:-6}"
TO="${MC_BACKSTOP_TIMEOUT_S:-240}"
[[ "$TO" =~ ^[0-9]+$ ]] && [ "$TO" -gt 0 ] || TO=240
# key state since head reviewed alerted reason url — the harness's own repo
# first, then the oldest `since`. The order is only the launch order now: every
# candidate is launched this fire.
CANDS=$(awk -F'\t' -v own="${HARNESS_REPO:-}" '
  BEGIN { own = tolower(own) }
  ($2=="WAIT_CI"||$2=="READY") && $4!="" && $4!="-" && $4==$5 && $1 ~ /^[^#[:space:]]+#[0-9]+$/ {
  s=$3; if (s !~ /^[0-9]+$/) s=0; r = $1; sub(/#.*/, "", r)
  print (own != "" && tolower(r) == own ? 0 : 1) "\t" s "\t" $1 }' "$ROWS" 2>/dev/null \
  | sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f3 | awk 'NF && !seen[$0]++')
N=$(grep -c . <<<"$CANDS")
[ "$N" -gt 0 ] || { say "0 candidates — nothing to do"; exit 0; }
case "$CAP" in 6|0|'') ;; *) say "MC_BACKSTOP_MAX_KEYS=$CAP is deprecated and has no effect (BH-6000): every candidate gets its own run" ;; esac
# THE WORKER DEADLINE FIRES BEFORE THE TIMEOUT (BH-4918). Each run's PR worker
# is capped at TO - 45 (never under 30), so a slow PR is killed alone and the
# run still has time for its own fan-in and enqueue.
WD=$((TO - 45)); [ "$WD" -ge 30 ] || WD=30
say "keyed conductor run: worker deadline capped at ${WD}s under timeout ${TO}s (each run)"
LOCKS="$H/locks"; mkdir -p "$LOCKS" 2>/dev/null
# ONE DETACHED RUN PER CANDIDATE (BH-6000). Before this, one keyed run took at
# most 6 keys under one shared window (MC_WORKERS_DONE_BY): a key it could not
# fit logged WINDOW_DEFERRED on every fire (#4546, #5704, #5727, #5990, #5999,
# 2026-10-11), and the rest waited for later fires. Now every candidate starts
# its own `MC_ONLY_PR=<key> merge-conductor.sh` under its own `timeout` and its
# own per-key flock, detached (setsid), in this fire. There is no cap and no
# shared window. A key whose run from an earlier fire still holds its lock is
# left alone (one line), never started twice and never dropped: the next fire
# offers it again. Same shape as bin/lib/project-lanes.sh (BH-5913), per PR.
# The conductor run takes the PR's own lock inside (mc_pr_lock) as before.
launched=0
while IFS= read -r KEY; do
  [ -n "$KEY" ] || continue
  LK="$LOCKS/mc-backstop-${KEY//[^A-Za-z0-9._-]/_}.lock"
  # The lock is taken here, in the foreground, so a busy key is known and
  # logged before the next one; the detached child inherits it on fd 9 and
  # holds it for the life of the run. The conductor itself gets 9>&- so its
  # own PR lock (also fd 9 inside) is never confused with this one.
  exec 9>>"$LK" || { say "$KEY: cannot open $LK — not started this fire"; continue; }
  if ! flock -n 9; then
    exec 9>&-
    say "$KEY: its run from an earlier fire still holds $LK — left alone this fire"
    continue
  fi
  # Each run reports its own end on this lane's log, the line the old single
  # run wrote once per fire: `rc=<n>`, or `hit timeout` when `timeout` killed it.
  ( MC_ONLY_PR="$KEY" WAKE_LAUNCH=1 MC_WORKER_DEADLINE_CAP_S="$WD" \
      setsid timeout "$TO" "$H/bin/merge-conductor.sh" </dev/null >/dev/null 2>&1 9>&-
    rc=$?
    if [ "$rc" = 124 ]; then say "$KEY: keyed conductor run hit timeout $TO — killed"
    else say "$KEY: keyed conductor run rc=$rc"; fi
    exit 0 ) &
  exec 9>&-
  launched=$((launched + 1))
done <<<"$CANDS"
say "$N candidate(s): $launched detached keyed conductor run(s) started, one per PR (timeout ${TO}s, worker cap ${WD}s each)"
exit 0

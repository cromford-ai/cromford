#!/bin/bash
# SCALE-PLAN wave 3 — ephemeral runner pool (the operator go: 2026-08-13; substrate
# decision REVISED from Orgo→Fly with a month of evidence: the Fly builder
# image + dispatcher are proven, machines bill per-second, and Orgo wedged a
# box unrecoverably on 08-10).
#
# One Fly MACHINE per build instead of one persistent builder per project.
# Enable per project: echo <max-machines> > flags/fly-pool-<project>.
# The persistent-builder path in fly-dispatch.sh stays untouched — this script
# no-ops without the flag, so rollback is `rm flags/fly-pool-<project>`.
#
# Loop shape (cron every ~2 min, self-locking):
#   REAP: for each tracked machine — RESULT ready -> pull artifacts, hand result
#         to the normal handled/ flow, then REUSE the machine for the next
#         queued job when one is waiting (2026-08-13: a spawn costs ~5 min;
#         the runner idles 10 min for exactly this) or destroy it; dead/stale
#         -> requeue job (deaths+1, giving up at the SECOND OBSERVED DEATH).
#   SPAWN: ONE MACHINE PER QUEUED JOB, every tick (2026-09-14 autoscale) —
#          machine run (ephemeral rootfs, volume-less; entrypoint's re-clone path
#          handles a bare /data), push env bundle + job via per-machine console,
#          go. An explicit cap still caps; by default there is none.
# usage: fly-pool.sh <project>
#
# gh-rest: no-graphql
#
set -uo pipefail
P="${1:?project}"
# Overridable so this pool can be DRIVEN against a scratch tree — the same
# change run-build.sh, fly-dispatch.sh, merge-queue.sh and review-prs.sh took.
# Until now nothing in this file had ever been driven by a test, and a suite
# that set HARNESS passed VACUOUSLY: the script silently used /root/harness,
# found no flag, and exited 0 — so "no ssh happened" was true because nothing
# happened at all. Cron sets it nowhere, so production is the path it always had.
HARNESS="${HARNESS:-/root/harness}"
FLAG="$HARNESS/flags/fly-pool-$P"
[ -f "$FLAG" ] || exit 0
# ONE RUN PER PROJECT, DECIDED FIRST (BH-7139). The per-project lock is taken
# before any other work: before pool-cap.sh, the env load, the lane gate, the
# token resolve and `fly agent start`. On 2026-10-16 the hub ran up to 7
# fly-pool.sh per project at once, each paying that start-up under load 170+
# before it found the lock held. A second start now exits rc 0 at once with one
# line; the running tick already covers this project. Nothing is sourced above
# this point and mkdir runs only when a dir is missing (BH-7251), so a held-lock
# start costs bash, flock and the log line.
[ -d "$HARNESS/locks" ] && [ -d "$HARNESS/logs" ] || mkdir -p "$HARNESS/locks" "$HARNESS/logs" 2>/dev/null
exec 8>"$HARNESS/locks/fly-pool-$P.lock"
if ! flock -n 8; then
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$P] already running (locks/fly-pool-$P.lock held) — this start exits, the running tick covers $P" >> "$HARNESS/logs/fly-pool.log"
  exit 0
fi
# BH-7475: the row-boundary stop rule. The tick holds the lock above for its
# whole life, so at each row of the REAP and SPAWN walks it stops when its code
# was replaced or it ran past POOL_TICK_MAX_AGE_S. Missing, the walks run as before.
# shellcheck source=bin/lib/pool-tick-stop.sh
. "$HARNESS/bin/lib/pool-tick-stop.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-tick-stop.sh" 2>/dev/null || true
# PTS_STOP is the tick-stop state pts_stop_due sets, not a knob; it starts
# empty here so the REAP-walk check reads a defined local even without the lib.
PTS_STOP=""
command -v pts_init >/dev/null 2>&1 && pts_init
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# The cap: a number in the flag file, else fly/pool-caps.conf, else UNLIMITED —
# bin/pool-cap.sh is the one reader (2026-09-12), and since 2026-09-14 it prints
# 0 for "no ceiling" (the SPAWN section below turns that into queue depth). The
# `:-3` is not the default any more, it is the unreadable-script fallback: a
# missing or broken pool-cap.sh must not read as "unlimited".
CAP=$("$HARNESS/bin/pool-cap.sh" "$P" 2>/dev/null | tr -dc '0-9'); CAP="${CAP:-3}"
# FLY_BIN_DIR is the same kind of seam as HARNESS above, and it exists for the
# same reason: with the real flyctl prepended absolutely, a suite that stubs
# `fly` on PATH silently drove the REAL binary instead (every fly-pool test was
# red on any box that has flyctl installed — the hub — and green only where it
# is absent). Cron and production set it nowhere, so the path is the one it
# always had.
export PATH="${FLY_BIN_DIR:-/root/.fly/bin}:$PATH"
set -a; . "$HENV/fly.env"; . "$HENV/global.env" 2>/dev/null; set +a

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-fly-pool-<project>, or the D1 pause_flags row of the same
# name stops this tick (exit 0 — a paused lane is not a failure). With no flag
# and no row this returns immediately and the lane behaves exactly as it always
# has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fly-pool <project>.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# BH-5911: the EXECUTE_EMPTY stop gate (pool_spawn_decision 3b). Missing, the
# gate is skipped and the pool launches as before.
. "${HARNESS:-/root/harness}/bin/lib/execute-empty.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-pool "$P"
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-pool "$P"

TV="FLY_API_TOKEN_$(echo "$P" | tr '[:lower:].-' '[:upper:]__')"
# BH-7107: the project token, else the hub's org FLY_API_TOKEN, never an
# inherited FLY_ACCESS_TOKEN (bin/lib/fly-token.sh). Without the lib, the
# project token alone, as before.
# shellcheck source=bin/lib/fly-token.sh
. "$HARNESS/bin/lib/fly-token.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/fly-token.sh" 2>/dev/null || true
if command -v fly_token_resolve >/dev/null 2>&1; then fly_token_resolve "$P"
else FLY_TOKEN_VAL="${!TV:-}"; FLY_TOKEN_SRC=""; [ -n "$FLY_TOKEN_VAL" ] && FLY_TOKEN_SRC="$TV"; fi
export FLY_ACCESS_TOKEN="$FLY_TOKEN_VAL"
APP=$(jq -r '.app // ""' "$HARNESS/state/fly/$P.json" 2>/dev/null)
[ -n "$APP" ] || exit 0
FLY=$(command -v fly || command -v flyctl)
# NO FLYCTL, NO TICK (2026-10-21). Cron's PATH is /usr/bin:/bin and the Fly hub
# image puts flyctl in /usr/local/bin (BH-7715), so the lookup above can find
# nothing. FLY was then empty, the no-leak wrapper below became `exec ''`, and
# every flyctl call in the tick failed as "machines list unusable (exec: : not
# found)" (project-3 09:10Z). The PATH lookup stays first (a test's FLY_BIN_DIR
# stub must win); bin/lib/fly-bin.sh then checks the install dirs; nothing at
# all is one alert a day and a clean exit, never a tick run on an empty binary.
if [ -z "$FLY" ]; then
  # shellcheck source=bin/lib/fly-bin.sh
  [ -r "$HARNESS/bin/lib/fly-bin.sh" ] && . "$HARNESS/bin/lib/fly-bin.sh" && FLY=$(fly_bin) || FLY=""
fi
LOG="$HARNESS/logs/fly-pool.log"
if [ -z "$FLY" ]; then
  echo "$(date -u '+%F %TZ') [$P] no flyctl on this host (PATH=$PATH) — tick skipped" >> "$LOG"
  # The once-a-day stamp lives in the pool's state dir, not flags/: it is an
  # alert dedup mark, and new flags/ writes go through bin/lib/flags.sh (L1).
  mkdir -p "$HARNESS/state/fly-pool/$P" 2>/dev/null
  _NF="$HARNESS/state/fly-pool/$P/alerted-noflyctl-$(date -u +%Y%m%d)"
  if [ ! -e "$_NF" ]; then
    : > "$_NF" 2>/dev/null
    [ -x "$HARNESS/bin/alert-line.sh" ] && "$HARNESS/bin/alert-line.sh" --project "$P" --id "pool-noflyctl-$P" \
      "[pool/$P] no flyctl on $(hostname 2>/dev/null) — the pool tick is skipped until flyctl is installed or on cron's PATH (ls /usr/local/bin/flyctl /root/.fly/bin/flyctl)" </dev/null >/dev/null 2>&1 || true
  fi
  exit 0
fi
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HARNESS/bin/lib/preplan-lib.sh" ] && . "$HARNESS/bin/lib/preplan-lib.sh"
# shellcheck source=bin/lib/test-home-lib.sh
[ -r "$HARNESS/bin/lib/test-home-lib.sh" ] && . "$HARNESS/bin/lib/test-home-lib.sh" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) [pool/$P] $*" >> "$LOG"; }
# --- BH-7505: the pool tick of a project placed fly -------------------------
# With lane_placement.fly-pool.<project> = fly the hub enqueues ONE lane_runs
# row for bin/fly-pool-project.sh and does no row work here (rc 0 = handled).
# A fallback, a take-back, a backoff and a rollback return rc 1 with the project
# lease held, so a Fly run and this tick never run together. On a lane-run
# machine (POOL_ON_MACHINE=1) the gate stands aside. With no row, or without
# the lib, this is today's tick: pp_gate costs one jq read on a fresh settings
# cache. The lease is released by the EXIT traps below (pp_release).
# shellcheck source=bin/lib/pool-placement.sh
. "$HARNESS/bin/lib/pool-placement.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-placement.sh" 2>/dev/null || true
if command -v pp_gate >/dev/null 2>&1 && pp_gate "$P"; then exit 0; fi
# The lease this tick may now hold goes at any exit; both traps below carry it too.
trap 'command -v pp_release >/dev/null 2>&1 && pp_release; true' EXIT
# BH-7107: the stall alert and the in-flight HOLD cancel. A tree without the
# lib has neither, and a tick with no token exits silently, as before.
# shellcheck source=bin/lib/pool-stall.sh
. "$HARNESS/bin/lib/pool-stall.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-stall.sh" 2>/dev/null || true
# BH-7382: the under-use alert (queued work, free slots, few building).
# shellcheck source=bin/lib/pool-underuse.sh
. "$HARNESS/bin/lib/pool-underuse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-underuse.sh" 2>/dev/null || true
# BH-7382: release a claimed fly row that no hub file and no live machine owns.
# shellcheck source=bin/lib/pool-orphan-rows.sh
. "$HARNESS/bin/lib/pool-orphan-rows.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-orphan-rows.sh" 2>/dev/null || true
[ "$FLY_TOKEN_SRC" = FLY_API_TOKEN ] && say "using the org FLY_API_TOKEN: $TV is not set"
if [ -z "$FLY_ACCESS_TOKEN" ]; then
  command -v pool_stall_no_token >/dev/null 2>&1 && pool_stall_no_token "$TV" \
    "$(ls "$HARNESS/state/build-queue/$P"/*.json 2>/dev/null | grep -cv '\.failed\.json$')" \
    "$(ls "$HARNESS/state/fly-pool/$P"/*.json 2>/dev/null | grep -c .)"
  exit 0
fi
# --- the hotfix lane's two questions in this file (#368) ---------------------
# `hotfix:true` rides the queue file from bin/run-build.sh's enqueue and the
# hub's materialise, so the pool never has to ask GitHub anything: it reads the
# flag off the job. A grep rather than a jq call because it runs once per queued
# file per tick and the answer is a single literal key.
# The lane's kill flag reaches here through the same lib every other caller
# reads, so HOTFIX_LANE=0 / flags/hotfix-lane-off makes this file behave exactly
# as it did before #368 — no reordering, no exemption, no extra log field. A
# missing lib (a half-synced box) leaves the lane ON, which is only ever the
# behaviour a job file already asked for.
HOTFIX_ON=1
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
# BH-2523: fir_digest, the image pointer as a fly_images row.
[ -r "$HARNESS/bin/lib/fly-image-row.sh" ] && . "$HARNESS/bin/lib/fly-image-row.sh" 2>/dev/null
# BH-5001: the spawn ledger, terminal verdicts and holds as pool_* rows, read
# first while `pool_state_rows` is on. A tree without the lib reads its files.
# shellcheck source=bin/lib/pool-state-rows.sh
. "$HARNESS/bin/lib/pool-state-rows.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-state-rows.sh" 2>/dev/null || true
# BH-5006: closeout_age_out_s, pipeline-health check 4's own age ceiling, so the
# custody sweep and check 4 agree on which results are too old to chase.
# shellcheck source=bin/lib/closeout-terminal.sh
. "$HARNESS/bin/lib/closeout-terminal.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/closeout-terminal.sh" 2>/dev/null || true
# BH-5967: a stand-down that names its blocker (`After: <KEY>`) waits for it.
# A tree without the lib parks at JOBS_QUEUE_DEFER_MAX, as before.
# shellcheck source=bin/lib/deferral-after.sh
. "$HARNESS/bin/lib/deferral-after.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/deferral-after.sh" 2>/dev/null || true
# BH-6536: nh_sd_stage_lines, the ticket_stage reasons the pool tick prints.
# shellcheck source=bin/lib/needs-human.sh
. "$HARNESS/bin/lib/needs-human.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/needs-human.sh" 2>/dev/null || true
# BH-6957: pool_actor_gate, the trigger-actor check before a spawn. A tree
# without the lib spawns as before and the builder's gate decides.
# shellcheck source=bin/lib/pool-actor-gate.sh
. "$HARNESS/bin/lib/pool-actor-gate.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-actor-gate.sh" 2>/dev/null || true
command -v hotfix_lane_on >/dev/null 2>&1 && HOTFIX_ON=$(hotfix_lane_on "$HARNESS")
job_is_hot() {
  [ "$HOTFIX_ON" = 1 ] || return 1
  grep -q '"hotfix": *true' "${1:-/dev/null}" 2>/dev/null
}
# job_is_now <job.json> — an operator dispatched this key from the console
# (bin/cmd-dispatch-issue.sh writes state/dispatch-now/<p>/<KEY>).
job_is_now() {
  local k
  k=$(basename "${1:-}" .json)
  [ -n "$k" ] && [ -e "$HARNESS/state/dispatch-now/$P/$k" ]
}
# Hotfix files first, then dispatched keys, then the rest, order preserved
# within each group — so the emergency takes the machine the tick can afford,
# a reused machine takes the emergency job, and a dispatch goes next.
hotfix_first() {
  local f
  # Hotfix rows stay first: the SPAWN walk `break`s on the first non-hot row
  # once the budget is spent, so a hot row after any other row loses its cap
  # exemption (BH-7382). Then conductor rebase rows (RB-<pr>-<head8>) and
  # re-review rows (RR-<pr>-<head8>, BH-7635): each unblocks a merge and is one
  # short machine. Console preview rows (CP-<pr>-<head8>-<job>, BH-8030) go
  # with them: each is one short build a hub lane waits on. Newest by age, they starved
  # behind 130 older builds in the 600 s tick budget (project-6-os, 2026-10-19).
  for f in "$@"; do job_is_hot "$f" && printf '%s\n' "$f"; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|CP-*) job_is_hot "$f" || printf '%s\n' "$f" ;; esac; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|CP-*) continue ;; esac; job_is_hot "$f" || ! job_is_now "$f" || printf '%s\n' "$f"; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|CP-*) continue ;; esac; job_is_hot "$f" || job_is_now "$f" || printf '%s\n' "$f"; done
}
# Start the flyctl agent with fd 8 CLOSED: an agent auto-spawned by `machine
# exec` inside the locked section inherits fd 8 and holds the lock forever
# (2026-09-12: project-5 pool dark 66 min). It used to start before the lock;
# since BH-7139 the lock is taken at the top, so the agent gets `8>&-`.
# bin/fly-lock-guard.sh is the backstop.
"$FLY" agent start >/dev/null 2>&1 8>&- || true
# 2026-09-11 (project-4 TK-1566/1571/1576/1584 sat ~50m): bash `exec 8>` does not
# set FD_CLOEXEC. flyctl's agent inherited fd 8, held the pool lock after this
# tick exited, and the next tick `flock -n 8 || exit 0` skipped — RESULT sat
# unreaped. A child cannot set CLOEXEC on this process's fd; wrapping the
# flyctl exec so the agent never sees fd 8 is the same guarantee.
_FLY_BIN=$FLY
FLY=$(mktemp "${TMPDIR:-/tmp}/fly-noleak.XXXXXX") || exit 1
printf '#!/bin/bash\nexec %q "$@" 8>&-\n' "$_FLY_BIN" > "$FLY"
chmod +x "$FLY"
# $RQ is the per-tick rows queue (BH-1026.3, set ~40 lines down). Declared here
# so BOTH traps in this file can remove it without `set -u` tripping over a
# tick that never armed the flag.
RQ=""
trap 'rm -f -- "$FLY"; [ -n "${RQ:-}" ] && rm -rf -- "$RQ"; command -v pp_release >/dev/null 2>&1 && pp_release; true' EXIT
POOL="$HARNESS/state/fly-pool/$P"; PDIR="$HARNESS/state/pool/$P"
mkdir -p "$POOL" "$PDIR" "$HARNESS/state/build-queue/$P"
# SPRAWL GUARD (2026-08-12): the pool must run in its OWN Fly app, never the
# persistent-builder app — that app auto-recreates machines on destroy, so pool
# spawns multiplied uncontrollably. Require flags/fly-pool-app-<P> naming a
# dedicated app; without it the pool refuses to spawn (reap still runs).
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] && . "$HARNESS/bin/jobs-client.sh"
# BH-6350: the dispatch mode, read once per tick. In hotfix-only a queued job
# that dm_job_admit refuses (a plain fresh build: no hotfix, rebase, rebuild,
# death requeue or allow-list hit) is skipped and stays queued, in the spawn
# loop and in the reuse handoff alike. A tree without the lib reads normal.
DM_MODE=normal; DM_HELD=""
# shellcheck source=bin/lib/dispatch-mode.sh
. "$HARNESS/bin/lib/dispatch-mode.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/dispatch-mode.sh" 2>/dev/null || true
command -v dm_read >/dev/null 2>&1 && dm_read "$P"
# BH-6979: the scheduler's ready set (pool_spawn_decision gate 0c). Read only
# when the settings row scheduler.mode=enforce; a tree without the lib, or any
# other mode, is today's sibling-serial gate.
# shellcheck source=bin/lib/sched-gate.sh
. "$HARNESS/bin/lib/sched-gate.sh" 2>/dev/null || true
# BH-7706: the row walk decides its rows in parallel workers. Missing, the walk
# decides one row at a time, as before.
# shellcheck source=bin/lib/pool-decide.sh
. "$HARNESS/bin/lib/pool-decide.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-decide.sh" 2>/dev/null || true
# The hotfix-reserve check reads the workers' pending-hot count; a tree
# without the lib has no workers, so the count is 0.
PDC_PEND_HOT=${PDC_PEND_HOT:-0}
# The pool-result row (BH-2643): the reap reads a stopped machine's result from
# it. A tree without the lib reads nothing, and the reap is what it always was.
# shellcheck source=bin/lib/pool-result-row.sh
. "$HARNESS/bin/lib/pool-result-row.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-result-row.sh" 2>/dev/null || true
# The build record (BH-7429): the reap reads it instead of one ssh pull per
# file (POOL_RECORD_FILES is the same list as the ssh pull's).
# shellcheck source=bin/lib/pool-record.sh
. "$HARNESS/bin/lib/pool-record.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-record.sh" 2>/dev/null || true
# The Fly infra cost row (BH-4019): the live-machine reap writes one per job.
# A tree without the lib writes none, and the reap is what it always was.
# shellcheck source=bin/lib/fly-cost-row.sh
. "$HARNESS/bin/lib/fly-cost-row.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/fly-cost-row.sh" 2>/dev/null || true
# BH-7116: pb_hub_copy, the reap's plan.md copy when the machine is gone.
# shellcheck source=bin/lib/plan-blocked.sh
. "$HARNESS/bin/lib/plan-blocked.sh" 2>/dev/null || true
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
if command -v routing_pool_app >/dev/null 2>&1; then
  POOL_APP=$(routing_pool_app "$P" 2>/dev/null) || POOL_APP=""
else
  POOL_APP=$(cat "$HARNESS/flags/fly-pool-app-$P" 2>/dev/null)
fi
if [ -n "$POOL_APP" ]; then APP="$POOL_APP"; else
  say "no dedicated pool app (flags/fly-pool-app-$P) — reap-only, refusing to spawn into persistent-builder app"; POOL_SPAWN=0
fi
QDIR="$HARNESS/state/build-queue/$P"
# ONE KNOB for "how many stand-downs before this stops being re-offered here",
# shared with bin/jobs-watchdog.sh, which sweeps the same rows from the DB
# side and must not disagree with this loop about where the cap is. Past the
# cap the row is closed `failed` and bin/blocked-resolver.sh picks it up as a
# fresh-rebuild candidate — nothing sits waiting for a person.
DEFER_MAX="${JOBS_QUEUE_DEFER_MAX:-6}"

# --- A LANE FAILURE IS NOT THE TICKET'S (2026-09-23 pool loop) ----------------
# From 13:26Z every pool plan failed the same way: the leased Claude account was
# at its weekly limit and the OpenRouter floor under it answered 403 "Key limit
# exceeded". The reap counted each one as the TICKET deferring, requeued it and
# spawned again — 398 deferred runs over 71 tickets and ~201 machines, and every
# ticket that reached DEFER_MAX was handed to the blocked-resolver as a rebuild.
# Nothing about any ticket was wrong. A stage verdict that names the runner lane
# (RUNNER_EXHAUSTED, or class=auth) is a fact about the lane, so it:
#   - does not count as a deferral, and un-records this machine's spawn from the
#     per-key cap (the ticket keeps its place and its budget);
#   - requeues the ticket unchanged;
#   - holds EVERY spawn and reuse for this project for POOL_LANE_FAIL_HOLD_S,
#     because the next machine would meet the same lane. 0 turns the hold off,
#     and then the spawn is NOT un-recorded: POOL_SPAWN_CAP_PER_KEY is what
#     bounds the respawns instead.
#   - EXCEPT when the reap just cooled this machine's account (read back as
#     cooling) and pool_account_others_ok finds another account that can
#     serve (BH-1853): then there is no hold. Only this machine is destroyed,
#     and the next spawn takes a fresh lease.
# The hold is a file, state/pool/<p>/_spawn-hold ("<until-epoch> <why>"), so an
# operator can read it and remove it.
POOL_LANE_FAIL_HOLD_S="${POOL_LANE_FAIL_HOLD_S:-1800}"
case "$POOL_LANE_FAIL_HOLD_S" in ''|*[!0-9]*) POOL_LANE_FAIL_HOLD_S=1800 ;; esac
pool_lane_failure() { # <result-line> -> 0 when the stage verdict blames the runner lane
  case "${1:-}" in *RUNNER_EXHAUSTED*|*" class=auth"*) return 0 ;; esac
  # BH-4489: a project at its day budget cap is project-wide and every machine
  # would hit it, so it is the lane's condition too: requeue uncounted + hold.
  # BH-5526: the fly-pool lane's LLM_USD_CAP_DAY refused at the launch gate is
  # fleet-wide too. A cost autohalt hold (spend-hold) is the project's
  # condition, not the ticket's. BH-5526 C3: a lane over its runaway ceiling
  # is the lane's condition.
  case "${1:-}" in *" budget-project-day "*|*" budget-stage-day "*|*" usd-cap-day "*|*" spend-hold "*|*" spend-ceiling "*) return 0 ;; esac
  return 1
}
# AN OVERLAP OR After: DEFERRAL NEVER RAN THE TICKET (BH-5912). These are the
# four stand-down shapes bin/lib/rb/gates.sh writes when the key waits on a
# sibling: the plan-overlap / plan-sibling defer (`OVERLAP_DEFER …`), the
# pre-plan After: hold (`After: …`), the ten-minute floor (`plan overlap
# not-before …`) and the file-claim overlap (`file overlap — …`). Matched on
# the PREFIX after `BUILD_DEFERRED `, never mid-line. TK-7 (2026-10-09) spent
# all 12 capped spawns on such machines and no build ran.
pool_overlap_deferral() { # <result-line> -> 0 when the deferral is an overlap or After: wait
  case "${1:-}" in
    "BUILD_DEFERRED OVERLAP_DEFER"*|"BUILD_DEFERRED After: "*|\
    "BUILD_DEFERRED plan overlap not-before "*|"BUILD_DEFERRED file overlap "*) return 0 ;;
  esac
  return 1
}
# A GitHub 401 on the trigger-actor events read (BH-5025.2): the MACHINE's token
# is dead, not the ticket: deferrals unchanged, no hold, the machine destroyed.
pool_token_failure() { case "${1:-}" in *token-401*) return 0 ;; esac; return 1; }
pool_spawn_hold_path() { printf '%s/_spawn-hold\n' "$PDIR"; }
pool_spawn_held() { # prints the reason and returns 0 while the hold stands
  local f at why line
  # BH-5001: a spawn-hold ROW set on any hub holds this one too. The file still
  # holds on its own: a hold set during this tick reaches the file before this
  # tick's snapshot of the rows can show it, so the two are a union.
  if command -v psr_spawn_hold >/dev/null 2>&1 && line=$(psr_spawn_hold); then
    read -r at why <<<"$line"
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    if [ "$at" -gt "$(date -u +%s)" ]; then printf '%s\n' "${why:-lane failure}"; return 0; fi
  fi
  f=$(pool_spawn_hold_path)
  [ -r "$f" ] || return 1
  read -r at why < "$f" 2>/dev/null
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$at" -gt "$(date -u +%s)" ] || return 1
  printf '%s\n' "${why:-lane failure}"
}
pool_spawn_hold_set() { # <why> -> 0 when this call started the hold, 1 when one already stood
  local f hold_until why
  [ "$POOL_LANE_FAIL_HOLD_S" -gt 0 ] || return 1
  pool_spawn_held >/dev/null && return 1
  f=$(pool_spawn_hold_path)
  hold_until=$(( $(date -u +%s) + POOL_LANE_FAIL_HOLD_S ))
  why=$(printf '%s' "${1:-}" | tr '\n' ' ' | head -c 200)
  printf '%s %s\n' "$hold_until" "$why" > "$f.$$" 2>/dev/null \
    && mv "$f.$$" "$f" 2>/dev/null || return 1
  # BH-5001: the row too, so every hub holds. bin/pool-state.sh lift-hold lifts both.
  command -v psr_hold_put >/dev/null 2>&1 && { psr_hold_put "$P" spawn "" "" "$hold_until" "$why" "" || true; }
  return 0
}
# How much of a machine's failovers.log the reap brings home. The ladder's
# notes and the vendor's error text live there and nowhere on the hub.
POOL_RELAY_FAILOVERS_BYTES="${POOL_RELAY_FAILOVERS_BYTES:-65536}"
case "$POOL_RELAY_FAILOVERS_BYTES" in ''|*[!0-9]*) POOL_RELAY_FAILOVERS_BYTES=65536 ;; esac
# pool_custody_sweep (BH-5006): how old a custodyless pool RESULT must be before
# the sweep owns it (3600 = pipeline-health check 4's hour), and how many dirs
# it may act on per tick. 0 turns either off; garbage falls back.
POOL_CUSTODY_SWEEP_S="${POOL_CUSTODY_SWEEP_S:-3600}"
case "$POOL_CUSTODY_SWEEP_S" in ''|*[!0-9]*) POOL_CUSTODY_SWEEP_S=3600 ;; esac
POOL_CUSTODY_SWEEP_MAX="${POOL_CUSTODY_SWEEP_MAX:-10}"
case "$POOL_CUSTODY_SWEEP_MAX" in ''|*[!0-9]*) POOL_CUSTODY_SWEEP_MAX=10 ;; esac

# --- The queue row behind each file (2026-09-10) ------------------------------
# bin/fly-dispatch.sh now materialises this directory from `build_queue` rows
# instead of scp-ing it off the owning box, and it CLAIMS the row as it does so.
# A claim with no close is a build that can never be queued again, so every
# terminal outcome below writes the row back: `done` on a reaped RESULT,
# `queued` with attempt+1 on a death — or a DEFERRAL — that gets another go,
# `failed` when the attempts run out. Fail-open throughout — no client, no
# worker, no row, and this pool behaves exactly as it did before.
# Not twice: a re-source resets the routing memo the sync above filled.
# shellcheck source=/dev/null
command -v _jobs_req >/dev/null 2>&1 || { [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"; }

# pool_key_live <key> — rc 0 when <key> is already building somewhere in this
# pool (BH-5001). Under the rows-only flag the build_queue CLAIM answers first
# (it names the machine, wherever it was spawned); this hub's machine json
# answers second. A union: a missed answer is a second machine, an extra one
# only skips a tick. With the flag off it is exactly the old grep.
pool_key_live() {
  local key="${1:-}"
  [ -n "$key" ] || return 1
  if [ "${ROWS_ONLY:-0}" = 1 ] && command -v build_queue_active_key >/dev/null 2>&1 \
     && build_queue_active_key "$P" "$key" >/dev/null 2>&1; then
    return 0
  fi
  grep -ls "\"key\": *\"$key\"" "$POOL"/*.json >/dev/null 2>&1
}

# >>> rows-only queue (BH-1026.3)
# THE ROWS ARE THE QUEUE, AND THE DIRECTORY IS A PER-TICK SCRATCH. Every reader
# below — the depth count that sets the spawn budget, the hotfix count, the
# launch loop, the reuse handoff — reads `$QDIR/*.json`, and that is exactly
# right: what changes here is only where those files come from. With the flag on
# they are materialised from this project's `queued` rows into a PRIVATE mktemp
# directory that is removed when the tick exits, so
# state/build-queue/<p>/<KEY>.json is never written and the two sources for one
# decision become one.
#
# NOTHING IS CLAIMED HERE. The claim is at the point a machine is about to be
# spent (spawn_one, and the reuse handoff), because that is what makes "a
# refused claim spawns nothing" true — a claim taken at materialise time is a
# claim held through every gate that can still refuse the spawn.
#
# AN OUTAGE IS NOT AN EMPTY QUEUE: rc 1 leaves $QDIR pointing at the real
# directory and this tick behaves exactly as a flag-off one. The flag itself
# never reads ON from an unreadable settings row.
ROWS_ONLY=0
if command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on \
   && command -v queue_list >/dev/null 2>&1; then
  PROWS=$(queue_list "$P" queued fly 2>/dev/null)
  if [ "$?" -ne 1 ] && RQ=$(mktemp -d "${TMPDIR:-/tmp}/poolq-$P.XXXXXX" 2>/dev/null); then
    # shellcheck source=bin/lib/queue-row-job.sh
    . "$HARNESS/bin/lib/queue-row-job.sh" 2>/dev/null \
      || . "$(dirname "${BASH_SOURCE[0]}")/lib/queue-row-job.sh" 2>/dev/null || true
    if command -v queue_row_job_file >/dev/null 2>&1; then
      ROWS_ONLY=1
      QRJ_TAG="pool/$P"
      while IFS="$(printf '\t')" read -r _ RQK RQT _ _ RQA _ _ _ RQM; do
        [ -n "${RQK:-}" ] || continue
        # Already live on a machine in this pool: the guard the file path gets
        # for free (the spawn `mv`s the file away) has to be said out loud here.
        pool_key_live "$RQK" && continue
        queue_row_job_file "$P" "$RQ/$RQK.json" "$RQK" "$RQT" "$RQA" "$RQM" >/dev/null || true
      done <<POOLROWS
$PROWS
POOLROWS
      QDIR="$RQ"
    else
      rm -rf -- "$RQ"; RQ=""
      say "bin/lib/queue-row-job.sh is missing — the rows queue cannot be materialised, falling back to the files this tick"
    fi
  else
    RQ=""
  fi
fi

# pool_unclaim <key> [reason] — A WON CLAIM THAT NEVER BECAME A BUILD GOES BACK
# (BH-1026.3). Under the flag the row IS the queue, so every exit between the
# claim and a machine that actually holds the job has to hand the row back: with
# no $QDIR file to fall back to, the key would otherwise sit `claimed` with
# nothing building it until bin/jobs-watchdog.sh sweeps stale claims at
# JOBS_QUEUE_CLAIM_MIN (6h by default) — six hours of a queue that reads as busy,
# a ticket nobody is building, and a healthcheck count that cannot see it.
# It is also what keeps the "job stays queued" lines below TRUE under the flag:
# with the file gone, the row is the only thing that can still say it.
# FLAG-OFF IS A NO-OP, and has to be: the job file was never moved out of $QDIR,
# so it is still queued and the next */2 tick re-offers it exactly as today.
pool_unclaim() {
  [ "${ROWS_ONLY:-0}" = 1 ] || return 0
  command -v queue_release >/dev/null 2>&1 || return 0
  queue_release "$P" "$1" "${2:-}" >/dev/null 2>&1 || true
}
# <<< rows-only queue

# >>> machines rows (BH-1035)
# --- Fly machine registry advisory row writes (BH-1056) -----------------------
# ADVISORY, FAIL-OPEN, FILE FIRST. Every call below happens AFTER the file write
# it mirrors, and none of them can change what this tick does: the flag being
# off, the contract not being sourced, a missing verb, or a worker that refuses
# all land on the same `return 0`. The file is authoritative this cycle, the row
# is the hub's copy of it.
MROWS=0
command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on >/dev/null 2>&1 && MROWS=1
# One line per tick, not one per call: a worker that is down is down for every
# verb this tick tries, and eight identical lines say nothing the first did not.
MROW_FAIL_LOGGED=0
# machines_row <verb> <args...> — fail-open worker calls. Never changes caller rc.
machines_row() {
  [ "${MROWS:-0}" = 1 ] || return 0
  # A VERB THAT IS NOT THERE IS NOT A FAILURE (issue §1). A half-synced box has
  # no contract to call, which is the documented off state, not a worker refusal
  # — saying so would page for the flag being ahead of the sync.
  command -v "$1" >/dev/null 2>&1 || return 0
  if ! "$@" >/dev/null 2>&1; then
    if [ "${MROW_FAIL_LOGGED:-0}" = 0 ]; then
      say "machines row: $1 ${3:-} failed (worker unreachable or refused) — file is authoritative this cycle"
      MROW_FAIL_LOGGED=1
    fi
  fi
  return 0
}
# machines_row_close <machine-id> — close the row from DESTROY_* state.
# The state is computed from the rc destroy_machine actually answered with, read
# after the call and never before it: a row that says `destroyed` for a machine
# Fly refused to destroy is worse than no row at all.
machines_row_close() {
  local MID="$1" MCLOSE detail=""
  if [ "${DESTROY_GONE:-0}" = 1 ]; then MCLOSE=gone
  elif [ "${DESTROY_RC:-1}" = 0 ]; then MCLOSE=destroyed
  else MCLOSE=destroy_failed; detail="${DESTROY_ERR:-}"; fi
  machines_row machine_close "$P" "$APP" "$MID" "$MCLOSE" "$detail"
}
# <<< machines rows
# The hub half of a pool rebase (BH-486.2). Under REBASE_ON_POOL a machine in
# this pool does a rebase instead of a build, and the REAP hands its RESULT to
# mc_pool_rebase_apply (the RB-* stand-down arms call mc_pool_rebase_fail). A
# pool re-review (RR-*, BH-7635) goes to mc_pool_rereview_apply the same way,
# and its stand-down arms call mc_pool_rereview_fail.
# Type-guarded like every other lib here: a half-synced box defines nothing and
# the arm's own `command -v` miss is what reports it — one ALERTS line and a
# queue row left claimed — because a missing function must never read as
# "apply succeeded". No name in the lib or its guarded sub-sources
# (mc_*/_mc_*, plus the bg_*/pdg_*/rp_* and issue_close_shipped fallbacks)
# collides with one this file or its libs define (checked 2026-10-19).
# LAZY (BH-7428): the lib is ~45 files and 833 functions, 0.27 CPU s and 230
# forks per tick, and only the RB-* and RR-* arms use it. So each of those arms
# calls fp_mc_lib_load, and an idle or build-only tick never opens the file.
# The lib `exit 1`s when its mc/ modules do not load; the subshell probe keeps
# that exit from ending this tick mid-reap, and _FP_MC_LIB_TRIED stops a second
# probe in the same tick after a failure.
# shellcheck source=bin/lib/merge-conductor-lib.sh
fp_mc_lib_load() {
  command -v mc_pool_rebase_apply >/dev/null 2>&1 && return 0
  [ -z "${_FP_MC_LIB_TRIED:-}" ] || return 1
  _FP_MC_LIB_TRIED=1
  [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ] || return 1
  ( . "$HARNESS/bin/lib/merge-conductor-lib.sh" ) >/dev/null 2>&1 </dev/null || return 1
  . "$HARNESS/bin/lib/merge-conductor-lib.sh" 2>/dev/null
}
# A builder's GitHub credential (2026-09-14, the operator: "every throughput ceiling is a
# bug"). Sourced for gh_auth_armed only — the token itself is minted per machine
# in spawn_one below, never once for the tick. Unarmed, this defines two functions
# and changes nothing.
# >>> gh default auth
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# #469's rate-limit identity line, on the same fail-open terms as the lib above.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
# HOLD gate for the spawn loop (BH-1075)
# shellcheck source=bin/lib/hold.sh
[ -r "$HARNESS/bin/lib/hold.sh" ] && . "$HARNESS/bin/lib/hold.sh"
# The HOLD verdict kept across ticks, keyed on the issue listing (BH-6549)
# shellcheck source=bin/lib/pool-hold-cache.sh
[ -r "$HARNESS/bin/lib/pool-hold-cache.sh" ] && . "$HARNESS/bin/lib/pool-hold-cache.sh"
# A box off the tailnet is named once, not only per ticket (BH-6693)
# shellcheck source=bin/lib/pool-tailnet.sh
[ -r "$HARNESS/bin/lib/pool-tailnet.sh" ] && . "$HARNESS/bin/lib/pool-tailnet.sh"
# Per-tick REST caches for the spawn-decision reads (BH-1075)
declare -A _POOL_HEAD_CACHE=() _POOL_PR_CACHE=() _POOL_HOLD_CACHE=() _POOL_COMMENT_CACHE=()
# The listing key per issue number, and the per-tick hold-cache counters (BH-6549)
declare -A _POOL_HOLD_LKEY=()
_POOL_HOLD_LIST=""; _POOL_HOLD_LIB=""; _PHC_V=""; _PHC_TTL=""; _PHC_PAGES=""
_PHC_HITS=0; _PHC_MISSES=0; _PHC_BAD=0; _PHC_READ_S=0; _PHC_GATED=0
# The PR the open-PR gate found, so the one comment it posts can NAME it. Kept
# out of _POOL_PR_CACHE because that one answers y/n/u and a caller reads it
# with a case: a third value would have to be parsed everywhere it is read.
declare -A _POOL_PR_NUM=() _POOL_PR_URL=()
# The repo's open-PR list, read once per tick for the parent-done check
# (BH-6671): compact [{ref,title}], its read state (ok | u), and y/n/u per key.
_POOL_OPEN_LIST=""; _POOL_OPEN_LIST_ST=""
declare -A _POOL_PR_ANY_CACHE=()
# <<< gh default auth
# WHICH CREDENTIAL CAN SEE A REPO (BH-765). The reap gate below used to read
# env/github-admin.env by hand, which meant it spent the one org-admin PAT on
# every repo the default one cannot see and never asked the App installation
# token at all. One seam answers that question for the whole fleet; it is
# sourced HERE, at top level, because it captures the tick's own GH_TOKEN as
# "the caller's" and a source from inside the reap loop would capture whatever
# a previous iteration had exported.
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
# >>> gh default auth
# THE TICK'S OWN IDENTITY (BH-470, #424), for the `gh` calls this dispatcher
# makes itself — the reap-time PR verify reads. BELOW the two libs above on
# purpose: gh-repo-token.sh captures the caller's token as "the default" when it
# is sourced, and that default must stay the box PAT so its ladder still has a
# rung to fall back to. Per-machine minting in spawn_one, the POOL_GH_TOKEN_*
# rotation and the env bundle swap read FILES, not this variable, and are
# untouched.
command -v gh_default_auth_for_project >/dev/null 2>&1 && { gh_default_auth_for_project "$P" || true; }
# <<< gh default auth
# A builder's CLAUDE credential (2026-09-14, the operator: "use them for the builder
# lanes, the fly boxes"). Same seam as the GitHub token one line up: sourced for
# pool_account_lease/release only, the token itself picked per machine in
# spawn_one. Unarmed — no env/tokens.d, POOL_ACCOUNT_ROUTING=0,
# flags/pool-account-routing-off — this defines functions and changes nothing.
# shellcheck source=bin/lib/pool-account.sh
[ -r "$HARNESS/bin/lib/pool-account.sh" ] && . "$HARNESS/bin/lib/pool-account.sh"
# Which url on a reaped record is that record's OWN pr (BH-848). Guarded the same
# way: absent, the reap block keeps its first-url grep.
# shellcheck source=bin/lib/result-pr-url.sh
[ -r "$HARNESS/bin/lib/result-pr-url.sh" ] && . "$HARNESS/bin/lib/result-pr-url.sh"
# Is this build's result ALREADY a row the owning box can pull, and — the half
# this reap could not express on its own — could the question even be asked
# (BH-1041)? bd_result_in_ledger answers all three. Guarded like every lib
# above: on a half-synced box the function is absent, the reap reads that as
# "no client" and pushes over ssh exactly as it always has.
# shellcheck source=bin/lib/builder-direct.sh
[ -r "$HARNESS/bin/lib/builder-direct.sh" ] && . "$HARNESS/bin/lib/builder-direct.sh"
# Account leases outlive nothing: a machine that died between two ticks (or a
# whole pool destroyed by hand) would otherwise hold its account's lease for
# ever, and an account that looks busy is an account this picker stops using. The
# TTL sweep runs once per tick, before anything reads a lease count — and it has
# to sit BELOW the source above, or `command -v` is false and it never runs.
command -v pool_account_prune >/dev/null 2>&1 && pool_account_prune
# --- THE TOKEN HAS TO OUTLIVE THE BUILD (2026-09-14, project-5 TK-680/681/682) -
# An installation token lives exactly one hour. A pool build takes 40-75 minutes.
# The two numbers were never compared, so TK-680/681/682 were spawned 13:29Z on a
# token minted 12:42Z and their pre-PR push at 13:53Z answered `remote: Invalid
# username or token`; three finished builds were thrown away and requeued, and the
# orchestrator fell the whole fleet back to the PAT at 14:15Z.
#
# Three numbers fix it and all three are knobs, because the right answer is "longer
# than a build" and a build's length is a property of the project, not of this file:
#   MIN_LIFE     no bundle ships a token with less life than this (spawn side)
#   ROTATE_BEFORE  a live machine inside this much of expiry is handed a new one
#   ROTATE_EVERY   and never more often than this, per machine
# 55 + 20 minutes means a machine is re-tokened at roughly minute 40 of its hour
# and every build shorter than ~75 minutes never sees an expiry at all.
POOL_GH_TOKEN_MIN_LIFE="${POOL_GH_TOKEN_MIN_LIFE:-3300}"
POOL_GH_TOKEN_ROTATE_BEFORE="${POOL_GH_TOKEN_ROTATE_BEFORE:-1200}"
POOL_GH_TOKEN_ROTATE_EVERY="${POOL_GH_TOKEN_ROTATE_EVERY:-1800}"
# One slug lookup for the whole tick: it is the same answer for every machine and
# the rotation below needs it without a project env bundle to read REPO_SLUG from.
POOL_SLUG=$("$HARNESS/bin/fleet-conf.sh" "$P" repo 2>/dev/null || true)
case "$POOL_SLUG" in */*) ;; *) POOL_SLUG="" ;; esac
# BH-7421: the tick clock and its two knobs, both lane knobs (catalog/lanes.d/
# fly-pool.knobs.d): POOL_GH_READ_TIMEOUT_S (20) cuts one GitHub read;
# POOL_TICK_BUDGET_S (600) ends the row walk for this project (0 = off).
POOL_TICK_T0=$(date +%s)
case "${POOL_GH_READ_TIMEOUT_S:-}" in ''|*[!0-9]*) POOL_GH_READ_TIMEOUT_S=20 ;; esac
case "${POOL_TICK_BUDGET_S:-}" in ''|*[!0-9]*) POOL_TICK_BUDGET_S=600 ;; esac
[ "$POOL_GH_READ_TIMEOUT_S" -le 300 ] || POOL_GH_READ_TIMEOUT_S=300
[ "$POOL_TICK_BUDGET_S" -le 86400 ] || POOL_TICK_BUDGET_S=86400
# KILL FLAGS, and they are deliberately two. GH_APP_TOKENS=0 / flags/gh-app-tokens-off
# (or the `switch.gh-app-tokens-off` settings row) is the existing one and it
# turns the WHOLE App-token path off — no swap, no rotation, no
# /run/harness-env/gh-token, and fly/builder-runner.sh then keeps the credential
# helper it has today. GH_APP_ROTATE=0 / flags/gh-app-rotate-off (or the
# `switch.gh-app-rotate-off` settings row) turns off ONLY the rotation,
# for the case where the spawn-time swap is fine and the per-tick re-mint is what
# someone wants to stop.
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
gh_rotate_armed() {
  command -v gh_auth_armed >/dev/null 2>&1 || return 1
  gh_auth_armed || return 1
  [ -x "$HARNESS/bin/gh-token.sh" ] || return 1
  lane_switch gh-app-rotate-off && return 1
  [ "${GH_APP_ROTATE:-1}" = 0 ] && return 1
  return 0
}
# >>> builders App profile (BH-1578)
# WHICH GITHUB APP A MACHINE'S TOKEN IS MINTED FROM. Until 2026-09-23 every pool
# machine's token came from the hub App, so every builder clone, push and gh read
# spent the hub installation's 6,600/h — the bucket the merge lanes decide on —
# and it ran dry for an hour at a time. The builders have their own App now
# (env/github-app-builders.env, its own installation bucket), and bin/gh-token.sh
# mints from it under `--app <profile>` with its own cache.
#
# The profile is the POOL_GH_APP_PROFILE knob: registered in
# catalog/lanes.d/fly-pool.json as `required`, so lane_env_apply exports the
# settings row, or the registry default, and there is no literal here to drift.
# Empty or `hub` is today's hub App. A profile whose env file is not on this box
# falls back to the hub App — so merging this before the App was provisioned
# changed nothing — and says so in ONE line per tick. This tick's own GitHub
# reads (the default-auth block above) are hub lanes and never see the profile.
POOL_GH_APP_ARGS=()
_why=""
case "${POOL_GH_APP_PROFILE:-}" in
  ''|hub) ;;
  *[!a-z0-9-]*) _why="is not [a-z0-9-]" ;;
  *) if [ -r "$HENV/github-app-$POOL_GH_APP_PROFILE.env" ]; then POOL_GH_APP_ARGS=(--app "$POOL_GH_APP_PROFILE")
     else _why="has no $HENV/github-app-$POOL_GH_APP_PROFILE.env"; fi ;;
esac
# Logged only where a mint can happen at all: an unarmed box mints nothing, so
# it has nothing to fall back FROM.
if [ -n "$_why" ] && command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed; then
  say "gh App profile '$POOL_GH_APP_PROFILE' $_why — pool machines mint from the hub App (env/github-app.env) this tick"
fi
unset _why
# WHICH OWNERS THE PROFILE'S APP IS INSTALLED ON (BH-1602). POOL_GH_APP_OWNERS is
# a registered, required knob (default example-org): GitHub logins, comma or space
# separated, case-insensitive, `*` for every owner. A pool project owned by anyone
# else would fail every profile mint and take bin/gh-token.sh's hub retry, which
# pages once an HOUR; here it mints from the hub App directly instead — no profile
# attempt, no retry — and pages once per profile per owner per UTC day. Empty is
# every owner, which is only an unregistered or scratch run, and today's behaviour.
if [ "${#POOL_GH_APP_ARGS[@]}" -gt 0 ] && [ -n "$POOL_SLUG" ] && [ -n "${POOL_GH_APP_OWNERS:-}" ]; then
  # read, not an unquoted expansion: a bare `*` must never glob the cwd.
  _own="${POOL_SLUG%%/*}"; _hit=0; IFS=$', \t\n' read -r -a _os <<< "$POOL_GH_APP_OWNERS"
  for _o in ${_os[@]+"${_os[@]}"}; do
    if [ "$_o" = '*' ] || [ "${_o,,}" = "${_own,,}" ]; then _hit=1; break; fi
  done
  if [ "$_hit" = 0 ]; then
    POOL_GH_APP_ARGS=()
    if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed; then
      say "owner '$_own' is not in POOL_GH_APP_OWNERS — pool machines mint from the hub App (env/github-app.env), not the '$POOL_GH_APP_PROFILE' App"
      # ALERTS first, then the flag (gh-quota's order): a crash in between can
      # repeat one line, never mark an undelivered page as sent. Bounded (D21).
      find "$HARNESS/flags" -maxdepth 1 -name 'alerted-gh-app-profile-owner-*' -mmin +2880 -delete 2>/dev/null
      _flag="$HARNESS/flags/alerted-gh-app-profile-owner-$POOL_GH_APP_PROFILE-${_own,,}-$(date -u +%Y%m%d)"
      if [ ! -f "$_flag" ]; then
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] App profile '$POOL_GH_APP_PROFILE' is not installed on owner '$_own' (POOL_GH_APP_OWNERS) — pool/$P machines spend the HUB installation bucket. Install the App on $_own and add it to lane.fly-pool.pool_gh_app_owners, or leave it and accept the hub bucket."
        touch "$_flag" 2>/dev/null
      fi
      unset _flag
    fi
  fi
  unset _own _hit _o _os
fi
# Every per-machine mint and expiry read goes through this, so the spawn swap and
# the rotation can never disagree about which App (and which cache) they asked.
pool_gh_token() { "$HARNESS/bin/gh-token.sh" ${POOL_GH_APP_ARGS[@]+"${POOL_GH_APP_ARGS[@]}"} "$@"; }
# pool_gh_answered <stderr-of-the-mint> — the App that ACTUALLY answered a mint,
# for the log line (#1590 review B2). When the profile could not mint,
# bin/gh-token.sh asked the hub App, counted it and printed one `hub-retry` line
# on stderr; that line is said here rather than thrown away, and the answer is
# `hub`, never the profile the knob asked for.
pool_gh_answered() {
  local line
  line=$(grep -m 1 'hub-retry' "$1" 2>/dev/null)
  if [ -n "$line" ]; then
    say "${line#gh-token: } — the ${POOL_GH_APP_ARGS[1]:-?} App could not mint; the hub App answered, so this machine spends the HUB bucket (ALERTS once an hour, every retry in logs/gh-rate.log)"
    printf 'hub'; return 0
  fi
  if [ "${#POOL_GH_APP_ARGS[@]}" -gt 0 ]; then printf '%s' "${POOL_GH_APP_ARGS[1]}"; else printf 'hub'; fi
}
# <<< builders App profile
# >>> pr verify rest (BH-709)
# READING A PR'S STATE IS TWO QUESTIONS, NOT ONE: did the read happen at all,
# and only then, what did it say. The reap gate below used to ask one —
# `gh pr view --json state`, which is GraphQL, on a PAT whose GraphQL budget is
# chronically exhausted ("API rate limit already exceeded for user ID 2220366",
# 2026-09-17 20:15Z). A limited view exits non-zero with an EMPTY state, the
# empty state fell through to `!= OPEN`, and 75 alerts across 17 tickets told
# the medic that real, open PRs did not exist.
#
# THE READER IS NO LONGER THIS GATE'S (BH-781). It is bin/lib/gh-rest.sh, the
# one contract every decision path in the fleet reads GitHub through: rc 0 = act
# on the body, rc 44 = an affirmative 404, rc 75 = UNVERIFIABLE (403/429/5xx,
# no status line, an empty body on a 2xx). The gate below turns those three
# codes into its three answers and never reads a status off a silence again.
# (BH-1075's three spawn-gate reads still use a file-local pool_rest_read, for the
# reason written over its definition in the block right below this one.)
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HARNESS/bin/lib/gh-rest.sh" ] && . "$HARNESS/bin/lib/gh-rest.sh"
# <<< pr verify rest
# BH-6821: a push-rejected deferral whose push landed gets its PR from the hub.
# shellcheck source=bin/lib/pool-push-rejected.sh
[ -r "$HARNESS/bin/lib/pool-push-rejected.sh" ] && . "$HARNESS/bin/lib/pool-push-rejected.sh"
# BH-6576: a ticket body line `Spec-repo: <owner>/<repo>` names a repo its
# build may read; spawn_one unions it into the BH-5910 read-only token.
# shellcheck source=bin/lib/spec-repos.sh
[ -r "$HARNESS/bin/lib/spec-repos.sh" ] && . "$HARNESS/bin/lib/spec-repos.sh"
# >>> pool terminal / spawn cap / hold gate (BH-1075)
# THE THREE READS BELOW STILL HAVE THEIR OWN READER, AND ON PURPOSE (BH-781
# review round 2). BH-781 converted the PR_CREATED reap gate above to
# bin/lib/gh-rest.sh and deleted this file's `pool_rest_read`/`pr_state_rest`
# pair with it — correct, because that gate was the pair's only caller when
# BH-781 was planned. BH-1075 (#1097) then landed three NEW callers on main
# while BH-781 was in review: branch_head_rest, the open-PR probe, and the
# spawn-gate repo probe in pool_gates_applicable. Deleting the definition out
# from under them costs `pool_rest_read: command not found` on every */2 tick,
# which switches all four spawn gates (HOLD, open PR, push-rejected terminal,
# per-key cap) OFF and records head_sha as `unknown` — the runaway-launch class
# (#768/#781) reintroduced by the fix for it. So the reader stays until those
# three reads are ported to the gh-rest contract; #770 tracks that slice, and
# porting them is a change to BH-1075's gates, not to BH-781's.
#
# WHY IT IS NOT SIMPLY gh_rest GET. These three pass an EXPLICIT token
# (`$POOL_SLUG_TOK`, armed and reset per tick by pool_slug_token_arm) while the
# library reads the AMBIENT gh auth. Converting them means moving BH-1075's
# arming to the library's shape, which is its own build with its own suite.
# `gh api` is REST, so this reader is not what `# gh-rest: no-graphql` forbids.
#
# AND IT IS CALLED pool_rest_read (BH-1485). Under its old name it was the only
# thing in the `gh_rest*` namespace that is not a bin/lib/gh-rest.sh helper, and
# its three `_out=$(pool_rest_read …)` captures are CORRECT precisely because it
# answers in band — the HTTP code is line 1 of its stdout, so a subshell costs
# it nothing, which is the opposite of the library's contract. Under the old
# name the three reads read as violations of a rule they are exempt from, to
# `tests/gh-rest-no-subshell-lint.sh` and to a human alike. The port to the
# library is still #770's, unchanged and still not done here.
pool_rest_read() { # pool_rest_read <api-path> [token] -> line 1 = HTTP code (empty if none), rest = body
  local _path="$1" _tok="${2:-}" _raw=""
  # -i puts the status line on STDOUT even on a 4xx, which is the whole point:
  # a 404 and a 403 are both "gh exited 1" without it.
  # BH-7421: a read cut at POOL_GH_READ_TIMEOUT_S answers like any other read
  # that never produced a status line (empty code), never a hung tick.
  # A cut read prints the word TIMEOUT as line 1 (rc 124, or 137), so a caller can tell "the read was cut" from "the client cannot ask".
  local _to=() _lim="${POOL_GH_READ_TIMEOUT_S:-20}" _rc=0
  case "$_lim" in ''|*[!0-9]*) _lim=20 ;; esac
  if [ "$_lim" -gt 0 ] && command -v timeout >/dev/null 2>&1; then _to=(timeout "$_lim"); fi
  if [ -n "$_tok" ]; then _raw=$(GH_TOKEN="$_tok" "${_to[@]}" gh api -i "$_path" 2>/dev/null); _rc=$?
  else _raw=$("${_to[@]}" gh api -i "$_path" 2>/dev/null); _rc=$?; fi
  if [ "$_rc" = 124 ] || [ "$_rc" = 137 ]; then printf 'TIMEOUT\n'; return 0; fi
  awk 'NR==1 && $0 ~ /^HTTP\// {print $2; next}
       NR==1 {print ""}
       f {print}
       /^\r?$/ {f=1}' <<<"$_raw"
}
# Branch name the pool uses for a ticket key: ticket/<key-lower>.
pool_key_branch() { printf 'ticket/%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }

pool_terminal_path() { printf '%s/%s.terminal' "$PDIR" "$1"; }

pool_terminal_write() { # pool_terminal_write <key> <branch> <head_sha> <reason> [ticket_id]
  local key="${1:-}" br="${2:-}" sha="${3:-unknown}" reason="${4:-}" tid="${5:-}" ts
  ts=$(STAMP)
  mkdir -p "$PDIR"
  jq -nc --arg br "$br" --arg sha "$sha" --arg reason "$reason" --arg ts "$ts" --arg tid "$tid" \
    '{branch:$br,head_sha:$sha,reason:$reason,created_at:$ts} + (if $tid == "" or $tid == "null" then {} else {ticket_id:$tid} end)' > "$(pool_terminal_path "$key")"
  # BH-5001: and the row, so a respawn decided on ANY hub reads the verdict.
  command -v psr_terminal_put >/dev/null 2>&1 && { psr_terminal_put "$P" "$key" "$br" "$sha" "$reason" "$ts" || true; }
  return 0
}

# WHICH CREDENTIAL THE GATE READS WITH (review round 2, BLOCK-1; BH-765).
# Every read below — the applicability probe, the PR list, the branch head, the
# re-arm comments, and the one comment this file POSTS — used to run on whatever
# GH_TOKEN the tick happened to carry, i.e. the box default PAT. The reap gate
# 1000 lines down does not: it asks bin/lib/gh-repo-token.sh which of app ->
# default -> admin can SEE this repo and passes that token into its read, and
# that lib's header records why — "the hub default PAT 404s on
# example-org/project-5 ... six Fable-approved PRs sat unmerged for days". Read on
# the default PAT, a 404 from an invisible repo is indistinguishable from a real
# answer: pr_exists_for_key_rest returns 2, every row of that project is skipped
# as "PR check unreadable — will retry" on every tick with nothing paging, and
# the project's pool silently stops spawning. That is the fleet-wide freeze this
# ticket's own fix rounds fought, arriving through the IDENTITY rather than the
# client. So the ladder answers once and its token rides into every read.
#
# ARMED IN THE CALLER'S SHELL, NEVER IN A SUBSTITUTION: gh-repo-token.sh caches
# its verdict in the shell that asks, and `$(gh_repo_use_token ...)` would throw
# that cache away with the subshell and re-probe the repo per read (the reap
# gate says the same thing about its use_token/token_for ordering). The TOKEN is
# what the reads carry, so nothing this file does depends on which identity is
# installed in the environment at the time — including whatever hold_check armed
# and reset a moment earlier. Re-armed after POOL_SLUG_TOK_TTL because an `app`
# verdict is perishable (that lib ages its own app rung out at 1800s) and this
# script's reap loop can outlive one.
POOL_SLUG_TOK=""; POOL_SLUG_TOK_WHICH=""; _POOL_SLUG_TOK_AT=0
pool_slug_token_arm() {
  local _now
  [ -n "$POOL_SLUG" ] || return 0
  command -v gh_repo_use_token >/dev/null 2>&1 || return 0   # stripped box: ambient auth, as before
  _now=$(date +%s)
  [ -n "$POOL_SLUG_TOK_WHICH" ] \
    && [ "$(( _now - _POOL_SLUG_TOK_AT ))" -lt "${POOL_SLUG_TOK_TTL:-900}" ] && return 0
  if gh_repo_use_token "$POOL_SLUG"; then POOL_SLUG_TOK="${GH_TOKEN:-}"; else POOL_SLUG_TOK=""; fi
  POOL_SLUG_TOK_WHICH=$(gh_repo_token_for "$POOL_SLUG")
  gh_repo_token_reset
  _POOL_SLUG_TOK_AT=$_now
  return 0
}

# branch_head_rest <branch> -> the remote head sha, or empty on a failed/unreadable read.
branch_head_rest() {
  local br="${1:-}" _path _out _code _body _sha=""
  [ -n "$br" ] && [ -n "$POOL_SLUG" ] || return 1
  _sha="${_POOL_HEAD_CACHE[$br]:-}"
  [ -n "$_sha" ] && { printf '%s\n' "$_sha"; return 0; }
  _path="repos/$POOL_SLUG/git/ref/heads/$br"
  _out=$(pool_rest_read "$_path" "${POOL_SLUG_TOK:-}")
  _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
  if [ "$_code" = 200 ]; then
    _sha=$(jq -r '.object.sha // empty' 2>/dev/null <<<"$_body")
  fi
  [ -n "$_sha" ] && _POOL_HEAD_CACHE[$br]="$_sha"
  printf '%s\n' "$_sha"
  [ -n "$_sha" ]
}

# pr_exists_for_key_rest <key> -> rc 0 if an open PR exists, 1 if none, 2 if unreadable.
pr_exists_for_key_rest() {
  local key="${1:-}" br _path _out _code _body _n=""
  [ -n "$key" ] && [ -n "$POOL_SLUG" ] || return 2
  _n="${_POOL_PR_CACHE[$key]:-}"
  if [ -n "$_n" ]; then
    case "$_n" in
      y) return 0 ;;
      n) return 1 ;;
      *) return 2 ;;
    esac
  fi
  # BH-7421: one unreadable PR read stops PR reads for this project for the rest
  # of the tick. Each later read would wait out its own timeout.
  [ "${_POOL_PR_UNREADABLE:-0}" = 1 ] && return 2
  br=$(pool_key_branch "$key")
  local owner="${POOL_SLUG%%/*}"
  _path="repos/$POOL_SLUG/pulls?state=open&head=${owner}:$br&per_page=1"
  _out=$(pool_rest_read "$_path" "${POOL_SLUG_TOK:-}")
  _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
  if [ "$_code" = 200 ]; then
    _n=$(jq -r 'length // 0' 2>/dev/null <<<"$_body")
    case "$_n" in ''|*[!0-9]*) _POOL_PR_CACHE[$key]=u; pool_pr_unreadable_note "$key" "200-bad-body"; return 2 ;; esac
    if [ "$_n" -gt 0 ]; then
      # The number and url ride along from the body already fetched: naming the
      # PR in the board comment costs no second read.
      _POOL_PR_NUM[$key]=$(jq -r '.[0].number // empty' 2>/dev/null <<<"$_body")
      _POOL_PR_URL[$key]=$(jq -r '.[0].html_url // empty' 2>/dev/null <<<"$_body")
      _POOL_PR_CACHE[$key]=y; return 0
    else _POOL_PR_CACHE[$key]=n; return 1; fi
  fi
  _POOL_PR_CACHE[$key]=u
  pool_pr_unreadable_note "$key" "${_code:-none}"
  return 2
}

# pool_pr_unreadable_note <key> <http-code|none> (BH-7421)
# The first PR read that did not answer 200 in a tick: stop PR reads for the
# project this tick and raise ONE alert per project per hour. The hour is the
# mtime of flags/alerted-pool-pr-unreadable-<P> (ALERTS first, then the flag).
pool_pr_unreadable_note() {
  local key="${1:-}" code="${2:-none}" flag
  # "none" covers a timeout, no credential and a network failure alike; a 200
  # with a broken body (a read cut after the status line) is also no answer.
  case "$code" in TIMEOUT|200-bad-body) code=none ;; esac
  _POOL_PR_UNREADABLE=1; _POOL_PR_UNREADABLE_CODE="$code"
  say "PR read for $key answered '$code' (limit ${POOL_GH_READ_TIMEOUT_S:-20}s): no more PR reads for $P this tick"
  # One alert per project per UTC hour: the hour is in the flag name, and
  # bin/alerts-groom.sh prunes old alerted-* flags (bin/lib/flags.sh).
  command -v flag_set >/dev/null 2>&1 || . "$HARNESS/bin/lib/flags.sh" 2>/dev/null || return 0
  flag="alerted-pool-pr-unreadable-$P-$(date -u +%Y%m%d%H)"
  flag_has --cached "$flag" 2>/dev/null && return 0
  flag_set "$flag" on "fly-pool: PR-unreadable alert sent" >/dev/null 2>&1
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --id "pool-pr-unreadable-$P" "[pool/$P] PR reads are not answering (key $key, answer '$code', limit ${POOL_GH_READ_TIMEOUT_S:-20}s). PR reads for $P stop for the rest of this tick. A new build still spawns; a row with a prior branch or PR waits. Check the hub load and the GitHub token chain." >/dev/null 2>&1 || true
  return 0
}

# pool_row_is_new_build <job-file> <key> (BH-7421): rc 0 when local evidence says
# no build ever ran for the key: attempt 0 (the queue requeues at attempt+1),
# no deferral or death, no spawn file, no spawn row in the pool-state rows (an
# unreadable row count is NOT new), no terminal file. A build branch exists only
# after a build ran.
pool_row_is_new_build() {
  local jf="${1:-}" key="${2:-}" a d x f n
  a=$(jq -r '.attempt // 0' "$jf" 2>/dev/null); d=$(jq -r '.deferrals // 0' "$jf" 2>/dev/null); x=$(jq -r '.deaths // 0' "$jf" 2>/dev/null)
  [ "${a:-0}" = 0 ] && [ "${d:-0}" = 0 ] && [ "${x:-0}" = 0 ] || return 1
  f="$(pool_terminal_path "$key")"
  { [ ! -s "${f%.terminal}.spawns" ] && [ ! -e "$f" ]; } || return 1
  # With pool_state_rows on, the rows must answer 0 (rc 2 = unknown = not new).
  # The snapshot covers the spawn-cap window; the .spawns file covers older keys.
  if command -v psr_on >/dev/null 2>&1 && psr_on; then
    n=$(psr_spawn_count "$key" 0 2>/dev/null) || return 1
    [ "${n:-x}" = 0 ] || return 1
  fi
  return 0
}

# pool_tick_budget_spent (BH-7421): rc 0 when this tick has run longer than
# POOL_TICK_BUDGET_S (default 600, 0 = no budget).
pool_tick_budget_spent() {
  local b="${POOL_TICK_BUDGET_S:-600}"
  case "$b" in ''|*[!0-9]*) b=600 ;; esac
  [ "$b" -gt 0 ] && [ $(( $(date +%s) - ${POOL_TICK_T0:-$(date +%s)} )) -ge "$b" ]
}

# pr_open_for_key_any_rest <key> -> rc 0 if an open PR belongs to <key>, 1 if
# none, 2 if unreadable (BH-6671). pr_exists_for_key_rest reads head= exactly,
# so a re-run PR on `ticket/bh-6518-r2` (#6647) was "no open PR" and the pool
# released BH-6501 while its parent was open. This reads the open-PR list (paged,
# once per tick) and matches a head ref `ticket/<key>` or `ticket/<key>-r<N>`
# (the grammar of bin/lib/ticket-branch.sh; `-<N>` split children and `-local`
# are other branches) or a title that starts `<KEY>:`. Only the parent-done
# check asks it: the self open-PR gate keeps the exact read, because the rebuild
# ladder opens a `-r<N>` re-plan while the PARKED PR it replaces stays open.
# Ten full pages with no short one is a capped read, not "none": rc 2.
pr_open_for_key_any_rest() {
  local key="${1:-}" k K _p _out _code _body _n _hit
  [ -n "$key" ] && [ -n "$POOL_SLUG" ] || return 2
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || return 2
  case "${_POOL_PR_ANY_CACHE[$key]:-}" in y) return 0 ;; n) return 1 ;; u) return 2 ;; esac
  if [ -z "$_POOL_OPEN_LIST_ST" ]; then
    _POOL_OPEN_LIST="[]"; _POOL_OPEN_LIST_ST=u
    for _p in 1 2 3 4 5 6 7 8 9 10; do
      _out=$(pool_rest_read "repos/$POOL_SLUG/pulls?state=open&per_page=100&page=$_p" "${POOL_SLUG_TOK:-}")
      _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
      [ "$_code" = 200 ] || break
      _n=$(jq -r 'if type == "array" then length else empty end' 2>/dev/null <<<"$_body")
      case "$_n" in ''|*[!0-9]*) break ;; esac
      _POOL_OPEN_LIST=$(jq -c --argjson acc "$_POOL_OPEN_LIST" \
        '$acc + [.[] | {ref: (.head.ref // ""), title: (.title // "")}]' 2>/dev/null <<<"$_body") || break
      [ "$_n" -lt 100 ] && { _POOL_OPEN_LIST_ST=ok; break; }
    done
  fi
  [ "$_POOL_OPEN_LIST_ST" = ok ] || { _POOL_PR_ANY_CACHE[$key]=u; return 2; }
  k=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  K=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  _hit=$(jq -r --arg k "$k" --arg K "$K" \
    'any(.[]; (.ref | ascii_downcase | test("^ticket/" + $k + "(-r[0-9]+)?$"))
              or (.title | ascii_upcase | startswith($K + ":")))' 2>/dev/null <<<"$_POOL_OPEN_LIST")
  case "$_hit" in
    true)  _POOL_PR_ANY_CACHE[$key]=y; return 0 ;;
    false) _POOL_PR_ANY_CACHE[$key]=n; return 1 ;;
  esac
  _POOL_PR_ANY_CACHE[$key]=u
  return 2
}

# pool_hold_check <ticket-id> -> cached hold_check, rc 0 clear / 1 held / 2 unreadable.
pool_hold_check() {
  local ticket="${1:-}" v
  [ -n "$ticket" ] && [ -n "$POOL_SLUG" ] || { printf 'unreadable\tmissing slug or ticket\n'; return 2; }
  # A BOARD TICKET HAS NO ISSUE TO READ (2026-09-21). The hold gate reads a
  # GitHub ISSUE (bin/lib/hold.sh: HOLD/lift comments on `repos/<slug>/issues/N`),
  # so it only applies to the GitHub-Issues projects (project-5, project-6,
  # cromford), whose ticket_id IS the issue number. On the in-app boards
  # (project-3, project-1, project-2, project-4, project-8) ticket_id is the
  # board's own row id — a cuid — and hold_check answers `unreadable / no issue
  # number to read` for it. BH-1075 read that as "could not read, retry next
  # tick", which froze every board project's pool from 2026-09-20 23:58Z: seven
  # rows across four projects skipped every two minutes for fifteen hours, no
  # machine ever spawned, and the only symptom was one log line per tick.
  # bin/blocked-resolver.sh's br_hold_gate already answers this case as "the
  # hold gate has nothing to read, proceeding as before" (rc 2 -> return 0); the
  # pool now says the same. A board ticket's holds live on the board (status,
  # the triage HOLD verdict), which the watcher applies before it ever enqueues.
  case "$ticket" in
    ''|*[!0-9]*)
      v='clear	board ticket: the hold gate reads GitHub issues, and this ticket lives on its board'
      _POOL_HOLD_CACHE[$ticket]="$v"; printf '%s\n' "$v"; return 0 ;;
  esac
  # bin/lib/hold.sh is sourced only when it is readable, so a box without it has
  # no hold reading to offer. bin/blocked-resolver.sh answers that the same way
  # (`command -v hold_check ... || return 0`): an absent library is a gate that
  # does not apply, not a ticket that could not be read. Said out loud here
  # because the previous spelling reached the same answer only by an empty
  # string falling off the end of a case, which is not a decision anyone wrote.
  command -v hold_check >/dev/null 2>&1 || { printf 'clear\tno hold library on this box\n'; return 0; }
  v="${_POOL_HOLD_CACHE[$ticket]:-}"
  if [ -n "$v" ]; then
    printf '%s\n' "$v"
    case "$v" in held*) return 1 ;; clear*) return 0 ;; *) return 2 ;; esac
  fi
  v=$(hold_check "$POOL_SLUG" "$ticket" 2>/dev/null) || true
  # THE TOKEN GOES BACK. hold_check arms the App installation token for the repo
  # (hold__arm -> gh_auth_for) and says in its own header that the CALLER owns
  # the reset. Without one, every later read in this tick — the PR list, the
  # branch head, the reap-time pr_state_rest — runs on an identity other than
  # the one gh_default_auth_for_project declared for this project (BH-470), and
  # a lane that documents its identity this carefully must not quietly change it
  # halfway through a tick. The two-rung reset was the retired tier-2 sweep's
  # (BH-470): gh_default_auth_reset puts the PROJECT's identity back, which is
  # what line 178 installed; gh_auth_reset alone would put the BOX default back
  # and quietly undo it.
  if command -v gh_default_auth_reset >/dev/null 2>&1; then gh_default_auth_reset
  else command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; fi
  _POOL_HOLD_CACHE[$ticket]="$v"
  printf '%s\n' "$v"
  case "$v" in held*) return 1 ;; clear*) return 0 ;; *) return 2 ;; esac
}

# THE PR GATE READS THE OPEN-PR LIST ONCE PER TICK, NOT ONCE PER ROW (hotfix,
# 2026-10-19). Under hub load each per-key read took 10-16 s, so 156 queued rows
# walked about 40 minutes and spawned nothing, and no read hit the 20 s limit
# that stops the BH-7421 path. pool_pr_bulk_prime fills _POOL_PR_CACHE (and the
# PR number and url) for every queued key from `pulls?state=open&per_page=100`,
# so pr_exists_for_key_rest answers from the cache. A key absent from a COMPLETE
# listing is cached "no PR"; a failed page, a body that is not a list or the page
# cap on a full page leaves the cache empty and every row reads its own PR as
# before, so a half-read listing never says "no PR". POOL_PR_BULK=0 turns it off.
declare -A _PBR_OPEN=()
_PBR_N=0; _PBR_PAGES=0; _PBR_WHY=""
# pool_pr_bulk_read — fills _PBR_OPEN[<head ref>]="<number>|<url>" from this
# repo's own branches (a fork PR on the same branch name is no PR for the pool,
# as in the per-key read's head=<owner>:<branch>). rc 0 = complete listing,
# rc 1 = incomplete, with the reason in _PBR_WHY.
pool_pr_bulk_read() {
  local owner="${POOL_SLUG%%/*}" page=1 cap=10 _out _code _body _len _rows ref num url acc="[]"
  local bud="${POOL_PR_BULK_BUDGET_S:-60}" t0; t0=$(date +%s)
  case "$bud" in ''|*[!0-9]*) bud=60 ;; esac
  while [ "$page" -le "$cap" ]; do
    _out=$(pool_rest_read "repos/$POOL_SLUG/pulls?state=open&per_page=100&page=$page" "${POOL_SLUG_TOK:-}")
    _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
    [ "$_code" = 200 ] || { _PBR_WHY="page $page answered ${_code:-none}"; return 1; }
    _len=$(jq 'if type == "array" then length else -1 end' 2>/dev/null <<<"$_body")
    case "$_len" in ''|-1|*[!0-9]*) _PBR_WHY="page $page body is not a list"; return 1 ;; esac
    _rows=$(jq -r --arg o "$owner" '.[] | select((.head.repo.owner.login // "" | ascii_downcase) == ($o | ascii_downcase)) | [.head.ref, (.number | tostring), (.html_url // "")] | @tsv' 2>/dev/null <<<"$_body") \
      || { _PBR_WHY="page $page body is not readable"; return 1; }
    while IFS=$'\t' read -r ref num url; do
      [ -n "$ref" ] && _PBR_OPEN[$ref]="$num|$url"
    done <<<"$_rows"
    # The same pages are the open-PR list pr_open_for_key_any_rest (BH-6671)
    # reads once per tick: every PR, forks included, as {ref, title}. Handed
    # over only from a complete listing, so that function reads no second copy
    # (tests/pool-after-rn-branch.bh-6671-test.sh R8: one list read per tick).
    acc=$(jq -c --argjson acc "$acc" '$acc + [.[] | {ref: (.head.ref // ""), title: (.title // "")}]' 2>/dev/null <<<"$_body") \
      || { _PBR_WHY="page $page body is not readable"; return 1; }
    _PBR_N=$((_PBR_N + _len)); _PBR_PAGES=$page
    if [ "$_len" -lt 100 ]; then
      _POOL_OPEN_LIST="$acc"; _POOL_OPEN_LIST_ST=ok
      return 0
    fi
    # A bounded read: each page is cut at POOL_GH_READ_TIMEOUT_S, and the whole
    # listing at POOL_PR_BULK_BUDGET_S, so a slow hub never spends the tick here.
    [ $(( $(date +%s) - t0 )) -lt "$bud" ] \
      || { _PBR_WHY="bulk budget ${bud}s spent after page $page"; return 1; }
    page=$((page + 1))
  done
  _PBR_WHY="page cap $cap reached on a full page"
  return 1
}

# pool_pr_bulk_prime — once per tick, before the row walk. One line in the log.
pool_pr_bulk_prime() {
  local files=() jf k br e keys=0
  [ "${POOL_PR_BULK:-1}" = 0 ] && { say "PR bulk read: off (POOL_PR_BULK=0)"; return 0; }
  for jf in "$QDIR"/*.json; do
    [ -e "$jf" ] || continue
    case "$jf" in *.failed.json) ;; *) files+=("$jf") ;; esac
  done
  [ "${#files[@]}" -ge 2 ] || { say "PR bulk read: off (fewer than 2 queued rows)"; return 0; }
  pool_gates_applicable || { say "PR bulk read: off (PR gate not applicable)"; return 0; }
  pool_pr_bulk_read || { say "PR bulk read: off ($_PBR_WHY)"; return 0; }
  while read -r k; do
    [ -n "$k" ] || continue
    br=$(pool_key_branch "$k"); e="${_PBR_OPEN[$br]:-}"
    if [ -n "$e" ]; then
      _POOL_PR_NUM[$k]="${e%%|*}"; _POOL_PR_URL[$k]="${e#*|}"; _POOL_PR_CACHE[$k]=y
    elif [ "$_PBR_PAGES" = 1 ]; then
      # "No PR" only from a one-page listing: across pages, a PR that closes
      # between two page reads shifts the next page by one, so the PR at the
      # boundary is never seen. A key absent from a longer listing reads its own
      # PR, as before (review note on the bulk read, 2026-10-19).
      _POOL_PR_CACHE[$k]=n
    fi
    keys=$((keys + 1))
  # Each row's `after` blocker too (BH-7706): pool_after_open asks its PR.
  done < <(jq -r '.key // empty, .after // empty' "${files[@]}" 2>/dev/null | awk '!s[$0]++')
  say "PR bulk read: $_PBR_N open PRs in $_PBR_PAGES pages, cache filled for $keys keys"
  return 0
}

# THE HOLD VERDICT ACROSS TICKS (BH-6549). pool_hold_check above reads the
# issue and its whole thread for every held row on every tick, and its
# _POOL_HOLD_CACHE dies with the $( ) it runs in. On the loaded hub a thread
# read costs 30-45 s, so 19 held project-6 tickets cost about 12 min of a 30
# min cycle. The three functions below run in the CALLER's shell: one open
# ai-build issue listing per tick gives each issue's "<updated_at>|<comments>",
# and bin/lib/pool-hold-cache.sh answers a held verdict from
# $PDIR/hold-cache/<n>.json while that key, the hold.sh checksum and the TTL
# all still match. It keeps only held verdicts, so it can keep a row held and
# never release one; every other case is the full read above.

# pool_hold_cache_knobs — POOL_HOLD_CACHE_TTL_S and POOL_HOLD_LIST_MAX_PAGES
# (lane knobs, exported by lane_env_apply), read once per process. A value that
# is not a number in range falls back to its default with one line.
pool_hold_cache_knobs() {
  [ -n "$_PHC_TTL" ] && return 0
  _PHC_TTL="${POOL_HOLD_CACHE_TTL_S:-21600}"
  case "$_PHC_TTL" in
    ''|*[!0-9]*) say "POOL_HOLD_CACHE_TTL_S=$_PHC_TTL is not a number of seconds (0-604800) — using 21600"; _PHC_TTL=21600 ;;
    *) [ "$_PHC_TTL" -le 604800 ] || { say "POOL_HOLD_CACHE_TTL_S=$_PHC_TTL is not a number of seconds (0-604800) — using 21600"; _PHC_TTL=21600; } ;;
  esac
  _PHC_PAGES="${POOL_HOLD_LIST_MAX_PAGES:-10}"
  case "$_PHC_PAGES" in
    ''|*[!0-9]*) say "POOL_HOLD_LIST_MAX_PAGES=$_PHC_PAGES is not a number of pages (1-50) — using 10"; _PHC_PAGES=10 ;;
    *) [ "$_PHC_PAGES" -ge 1 ] && [ "$_PHC_PAGES" -le 50 ] \
         || { say "POOL_HOLD_LIST_MAX_PAGES=$_PHC_PAGES is not a number of pages (1-50) — using 10"; _PHC_PAGES=10; } ;;
  esac
  return 0
}

# pool_hold_list_prime — the open ai-build issue listing, once per process,
# into _POOL_HOLD_LKEY[<n>]. _POOL_HOLD_LIST says how it went: ok, truncated
# (the page cap was reached on a full page; later issues miss) or
# unreadable(<code>) (every row misses: the table is emptied).
pool_hold_list_prime() {
  [ -n "$_POOL_HOLD_LIST" ] && return 0
  local page=1 _out _code _body _rows _len n u c
  _POOL_HOLD_LIB=$(cksum < "$HARNESS/bin/lib/hold.sh" 2>/dev/null | awk '{print $1 "-" $2}')
  while [ "$page" -le "$_PHC_PAGES" ]; do
    _out=$(pool_rest_read "repos/$POOL_SLUG/issues?state=open&labels=ai-build&per_page=100&page=$page" "${POOL_SLUG_TOK:-}")
    _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
    if [ "$_code" != 200 ]; then
      _POOL_HOLD_LKEY=(); _POOL_HOLD_LIST="unreadable(${_code:-none})"; return 0
    fi
    if ! _rows=$(phc_listing_keys "$_body"); then
      _POOL_HOLD_LKEY=(); _POOL_HOLD_LIST="unreadable(body)"; return 0
    fi
    while IFS=$'\t' read -r n u c; do
      [ -n "$n" ] && [ -n "$c" ] && _POOL_HOLD_LKEY[$n]="$u|$c"
    done <<<"$_rows"
    _len=$(jq 'length' <<<"$_body" 2>/dev/null)
    case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
    [ "$_len" -ge 100 ] || { _POOL_HOLD_LIST=ok; return 0; }
    page=$((page + 1))
  done
  _POOL_HOLD_LIST=truncated
  return 0
}

# pool_hold_cache_lookup <ticket> — rc 0 hit (the verdict is in _PHC_V), rc 1
# miss: read the thread. A board ticket (not a number) is never looked up.
pool_hold_cache_lookup() {
  local t="${1:-}" key rc
  _PHC_V=""
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  command -v phc_get >/dev/null 2>&1 && command -v hold_check >/dev/null 2>&1 || return 1
  pool_hold_cache_knobs
  _PHC_GATED=1
  if [ "$_PHC_TTL" = 0 ]; then _POOL_HOLD_LIST=off; return 1; fi
  pool_hold_list_prime
  key="${_POOL_HOLD_LKEY[$t]:-}"
  _PHC_V=$(phc_get "$PDIR/hold-cache" "$t" "$key" "$_POOL_HOLD_LIB" "$_PHC_TTL" "$(date +%s)"); rc=$?
  if [ "$rc" = 0 ] && [ -n "$_PHC_V" ]; then _PHC_HITS=$((_PHC_HITS + 1)); return 0; fi
  _PHC_V=""; _PHC_MISSES=$((_PHC_MISSES + 1))
  [ "$rc" = 3 ] && _PHC_BAD=$((_PHC_BAD + 1))
  return 1
}

# pool_hold_cache_store <ticket> <verdict> — after a full read. The key is the
# one the listing gave BEFORE the read, so a comment that lands between the two
# costs one extra read next tick, never a stale hit.
pool_hold_cache_store() {
  local t="${1:-}"
  case "$t" in ''|*[!0-9]*) return 0 ;; esac
  command -v phc_put >/dev/null 2>&1 || return 0
  [ -n "$_PHC_TTL" ] && [ "$_PHC_TTL" != 0 ] || return 0
  phc_put "$PDIR/hold-cache" "$t" "${_POOL_HOLD_LKEY[$t]:-}" "$_POOL_HOLD_LIB" "$(date +%s)" "${2:-}" || true
  return 0
}

# A RE-ARM IS AN INSTRUCTION, NOT A HEARTBEAT (review round 1, Important-4).
# The first spelling of this took the newest comment whose `user.type` was not
# "Bot" — and every comment this harness posts with the PAT is `type: "User"`:
# the blocked-resolver's adjudication (bin/blocked-resolver.sh), the decompose
# close-out, the open-PR note this very file writes. Any of them would have
# re-armed a terminal the pool had just decided not to spend another machine on,
# which is bin/lib/hold.sh's own incident ("the harness's own PAT-posted comment
# would have lifted the operator's hold") — here it costs a build rather than a rebuild.
# So the same answer hold.sh gives: a SHORT, EXPLICIT, CAPITALISED vocabulary,
# and a negation or condition in front of the verb is not an instruction. Lower
# case is harness prose ("Rebuilt this ticket fresh against current main") and
# never re-arms.
POOL_REARM_RE='(?<![A-Za-z])(RETRY|REBUILD|RESUME|UNHOLD)(?![A-Za-z])'
POOL_REARM_NEG_RE='(?i:(?<![A-Za-z])(not|never|don\x27?t|do\s+not|until|unless|before|once|if|when)(\W+\w+){0,3}\W+(retry|rebuild|resum|unhold))'
# Newest EXPLICIT human re-arm timestamp (ISO 8601), or empty. Caches per tick.
pool_newest_rearm_at() {
  local ticket="${1:-}" raw cj ts
  [ -n "$ticket" ] && [ -n "$POOL_SLUG" ] || return 1
  ts="${_POOL_COMMENT_CACHE[$ticket]:-}"
  [ -n "$ts" ] && { printf '%s\n' "$ts"; return 0; }
  # The ladder's token, for the reason pool_slug_token_arm gives: on a repo the
  # box PAT cannot see this read 404s, the answer is empty, and "no human ever
  # said RETRY" is then indistinguishable from "nobody could ask" — a terminal
  # row no operator can lift. `--paginate` is why this is not pool_rest_read.
  if [ -n "${POOL_SLUG_TOK:-}" ]; then
    raw=$(GH_TOKEN="$POOL_SLUG_TOK" gh api --paginate "repos/$POOL_SLUG/issues/$ticket/comments?per_page=100" 2>/dev/null) || { printf '\n'; return 0; }
  else
    raw=$(gh api --paginate "repos/$POOL_SLUG/issues/$ticket/comments?per_page=100" 2>/dev/null) || { printf '\n'; return 0; }
  fi
  cj=$(printf '%s' "$raw" | jq -sc '[ .[] | if type=="array" then .[] else . end ]' 2>/dev/null) || cj=""
  if [ -n "$cj" ]; then
    ts=$(printf '%s' "$cj" | jq -r --arg re "$POOL_REARM_RE" --arg neg "$POOL_REARM_NEG_RE" '
      [ .[] | select(type=="object")
            | select(((((.user // {}).type // "") | tostring) | ascii_downcase) != "bot")
            | select((((.body // "") | tostring) | test($re)))
            | select(((((.body // "") | tostring) | test($neg))) | not)
            | .created_at // "" ] | max // empty' 2>/dev/null)
  fi
  [ -n "$ts" ] && _POOL_COMMENT_CACHE[$ticket]="$ts"
  printf '%s\n' "$ts"
}

# BH-7190: this project's own cap row, `lane.fly-pool.<project>.pool_spawn_cap_per_key`
# (the lane-knob key form, bin/lib/lane-gate.sh _lg_setting_key). It wins over the
# fleet-wide row, so one project can run "never wait" while the rest keep the
# fleet value. Prints digits, or nothing for no row, a junk value or an illegal key.
pool_spawn_cap_project_row() {
  local k v
  k=$(printf 'lane.fly-pool.%s.pool_spawn_cap_per_key' "${P:-}" | tr '[:upper:]' '[:lower:]')
  case "$k" in *[!a-z0-9_.-]*) return 0 ;; esac
  [ "${#k}" -le 64 ] || return 0
  v=$("$HARNESS/bin/jobs-client.sh" setting-get "$k" 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$v"
}

# Load cap/window for this tick. Defaults: 2 / 86400.
pool_spawn_cap_load() {
  local v w
  v=$(pool_spawn_cap_project_row)
  [ -n "$v" ] || v=$("$HARNESS/bin/jobs-client.sh" setting-get pool_spawn_cap_per_key 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v="${POOL_SPAWN_CAP_PER_KEY:-}" ;; esac
  case "$v" in ''|*[!0-9]*) v=2 ;; esac
  w=$("$HARNESS/bin/jobs-client.sh" setting-get pool_spawn_cap_window_s 2>/dev/null) || w=""
  case "$w" in ''|*[!0-9]*) w="${POOL_SPAWN_CAP_WINDOW_S:-}" ;; esac
  case "$w" in ''|*[!0-9]*) w=86400 ;; esac
  POOL_SPAWN_CAP=$v; POOL_SPAWN_CAP_WINDOW=$w
}

# pool_spawn_cap_check <key> -> rc 0 if under cap, 1 if cap reached.
pool_spawn_cap_check() {
  local key="${1:-}" now window limit f n ts nd
  f="$(pool_terminal_path "$key")"; f="${f%.terminal}.spawns"
  limit=${POOL_SPAWN_CAP:-2}; window=${POOL_SPAWN_CAP_WINDOW:-86400}
  now=$(date +%s)
  n=0
  if [ -f "$f" ]; then
    while read -r ts; do
      [ -n "$ts" ] || continue
      case "$ts" in *[!0-9]*) continue ;; esac
      [ "$((now - ts))" -le "$window" ] && n=$((n+1))
    done < "$f"
  fi
  # BH-5001: the rows count too, and the LARGER count decides. A row write that
  # failed in an outage leaves the DB short, and an undercount is a machine, so
  # the file can only raise the count; on a rebuilt hub with no file the rows
  # alone decide. rc 2 (no answer) leaves the file's count, as before.
  if command -v psr_spawn_count >/dev/null 2>&1 && nd=$(psr_spawn_count "$key" "$((now - window))"); then
    [ "$nd" -gt "$n" ] && n=$nd
  fi
  [ "$n" -lt "$limit" ]
}

# pool_spawn_cap_next_at <key> -> the epoch at which the key's in-window spawn
# count drops below the cap again (BH-4859): the in-window entries sorted
# oldest first, entry n-cap+1 plus the window plus one second, because
# pool_spawn_cap_check still counts an entry at exactly ts + window. Prints nothing when the key is
# not over the cap, so a caller says "when the window rolls" instead of a time.
pool_spawn_cap_next_at() {
  local key="${1:-}" now window limit f
  f="$(pool_terminal_path "$key")"; f="${f%.terminal}.spawns"
  [ -f "$f" ] || return 0
  limit=${POOL_SPAWN_CAP:-2}; window=${POOL_SPAWN_CAP_WINDOW:-86400}
  now=$(date +%s)
  awk -v now="$now" -v w="$window" '/^[0-9]+$/ && now - $0 <= w' "$f" | sort -n \
    | awk -v lim="$limit" -v w="$window" '{ t[NR] = $0 } END { k = NR - lim + 1; if (lim > 0 && k >= 1) print t[k] + w + 1 }'
}

# pool_spawn_cap_count <key> -> how many of the key's spawns are in the window.
pool_spawn_cap_count() {
  local f now
  f="$(pool_terminal_path "${1:-}")"; f="${f%.terminal}.spawns"
  [ -f "$f" ] || { echo 0; return 0; }
  now=$(date +%s)
  awk -v now="$now" -v w="${POOL_SPAWN_CAP_WINDOW:-86400}" '/^[0-9]+$/ && now - $0 <= w { n++ } END { print n + 0 }' "$f"
}

# pool_spawn_cap_record <key> -> append this attempt's epoch timestamp, and
# print it. BH-1279: the printed value is what the caller carries onto the
# machine json (spawn_cap_ts), so a reap that later learns the claim was
# REFUSED — never ran — can remove exactly this line with
# pool_spawn_cap_unrecord instead of a refusal counting the same as a real
# build forever.
pool_spawn_cap_record() { # <key> [machine]
  local key="${1:-}" f now
  f="$(pool_terminal_path "$key")"; f="${f%.terminal}.spawns"
  mkdir -p "$PDIR"
  now=$(date +%s)
  printf '%s\n' "$now" >> "$f"
  # BH-5001: the same line as a pool_spawns row. The machine is known only on
  # the reuse handoff; a spawn records before `fly machine run` has an id.
  command -v psr_spawn_add >/dev/null 2>&1 && { psr_spawn_add "$P" "$key" "$now" "${2:-}" >/dev/null 2>&1 || true; }
  printf '%s\n' "$now"
}

# pool_spawn_cap_unrecord <key> <ts> -> remove ONE entry equal to <ts> (the
# LAST matching line, in case two spawns landed in the same second) from the
# key's .spawns log.
#
# BH-1279: a claim REFUSED by job_open (RESULT "BUILD_DEFERRED REFUSED <scope>
# :: <reason>" — a phase-6 concurrency rule, a pause, or a stale retry, never
# an ordinary deferral) never started real work, so it must not count against
# POOL_SPAWN_CAP_PER_KEY. Before this fix every entry into spawn_one recorded
# unconditionally (BH-1075's own rule — a cap that only counted the attempts
# that worked could not bound a loop of attempts that did not), so a
# fleet-wide concurrency rule refusing every claim converted into per-key
# POOL_DEFER_TO_HUMAN parking within two ticks: 17 keys parked twice on
# 2026-09-21 alone. Only pool_spawn_cap_record ever wrote this line, on the
# SAME machine this reap is looking at, so removing exactly its own timestamp
# back out undoes exactly the one entry that spawn added — an ordinary
# deferral (busy slot, file overlap, push-rejected) still counts, because that
# machine genuinely ran.
pool_spawn_cap_unrecord() {
  local key="${1:-}" ts="${2:-}" f
  [ -n "$ts" ] || return 0
  case "$ts" in *[!0-9]*) return 0 ;; esac
  f="$(pool_terminal_path "$key")"; f="${f%.terminal}.spawns"
  if [ -f "$f" ]; then
    awk -v t="$ts" '
      $0 == t { last = NR }
      { line[NR] = $0 }
      END { for (i = 1; i <= NR; i++) if (i != last) print line[i] }
    ' "$f" > "$f.bh1279.$$" && mv "$f.bh1279.$$" "$f"
  fi
  # BH-5001: and ONE matching row, on whichever hub recorded it.
  command -v psr_spawn_remove >/dev/null 2>&1 && { psr_spawn_remove "$P" "$key" "$ts" || true; }
  return 0
}

# pool_terminal_rearm_row <key> <ticket-id> — a re-armed key's row goes back to
# `queued` (BH-5006). pool_terminal_noted closed it `failed` on the flag-off
# path, and the spawn's bookkeeping queue_claim is a queued->claimed CAS that
# refuses a failed row: the build would run while every surface read `failed`.
# Only a row that reads `failed` is re-enqueued; an outage or no row writes
# nothing, and a queued/claimed row is already right.
pool_terminal_rearm_row() {
  local key="${1:-}" ticket="${2:-}" st
  command -v queue_status >/dev/null 2>&1 && command -v queue_put >/dev/null 2>&1 || return 0
  st=$(queue_status "$P" "$key" 2>/dev/null) || return 0
  [ "$st" = failed ] || return 0
  queue_put "$P" "$key" "$ticket" fly >/dev/null 2>&1 || true
}

# pool_terminal_check <key> <ticket-id> -> rc 0 if spawn should proceed (terminal removed on re-arm).
pool_terminal_check() {
  local key="${1:-}" ticket="${2:-}" tp br cur old created rearm_ts rearm_at created_at
  local row="" rrc=2 src=file reason="" cleared="" cleared_at=0 file_at=0 heal=""
  tp=$(pool_terminal_path "$key")
  # BH-5001: THE ROW FIRST. A verdict written on another hub (or before this hub
  # was rebuilt) is a row with no file here. A row decides when it exists:
  # active, it is the verdict; cleared at or after this file's verdict, the file
  # is stale (a re-arm on another hub) and goes. A file NEWER than the clear is a
  # verdict that never reached the row, so the file decides and heals the row.
  # No row: the file decides exactly as before and heals the row (if_absent).
  # No answer (rc 2): the file, as before.
  command -v psr_terminal >/dev/null 2>&1 && { row=$(psr_terminal "$key"); rrc=$?; }
  if [ "$rrc" = 0 ]; then
    cleared=$(jq -r '.cleared_at // empty' <<<"$row" 2>/dev/null)
    if [ -n "$cleared" ]; then
      cleared_at=$(date -u -d "$cleared" +%s 2>/dev/null) || cleared_at=0
      if [ -f "$tp" ]; then
        file_at=$(date -u -d "$(jq -r '.created_at // empty' "$tp" 2>/dev/null)" +%s 2>/dev/null) || file_at=0
      fi
      if [ ! -f "$tp" ] || [ "$cleared_at" -ge "$file_at" ]; then
        rm -f "$tp"
        return 0
      fi
      heal=full
    else
      src=row
      br=$(jq -r '.branch // empty' <<<"$row" 2>/dev/null)
      old=$(jq -r '.head_sha // empty' <<<"$row" 2>/dev/null)
      created=$(jq -r '.created_at // empty' <<<"$row" 2>/dev/null)
    fi
  fi
  if [ "$src" = file ]; then
    [ -f "$tp" ] || return 0
    br=$(jq -r '.branch // empty' "$tp" 2>/dev/null)
    old=$(jq -r '.head_sha // empty' "$tp" 2>/dev/null)
    created=$(jq -r '.created_at // empty' "$tp" 2>/dev/null)
    [ "$rrc" = 1 ] && heal=if_absent
    if [ -n "$heal" ] && command -v psr_terminal_put >/dev/null 2>&1; then
      reason=$(jq -r '.reason // empty' "$tp" 2>/dev/null)
      psr_terminal_put "$P" "$key" "$br" "$old" "$reason" "$created" "${heal#full}" || true
    fi
  fi
  cur=$(branch_head_rest "$br")
  # AN UNKNOWN HEAD IS NOT A CHANGED HEAD (review round 1, Important-3). The
  # reap writes `unknown` when the head read failed AT THAT MOMENT (see the
  # push-rejected terminal block below, `${HEADSHA:-unknown}`). Comparing a real
  # sha against it reads as "the branch moved" on the very next readable tick,
  # and buys a machine whose push will be rejected again — a respawn bought with
  # nothing but an unreadable read, which is the loop this ticket exists to
  # close. Record the head instead and stay terminal; a LATER change off this
  # recorded sha is a real one.
  if [ "$old" = unknown ] && [ -n "$cur" ]; then
    local recorded=0
    if [ -f "$tp" ] && jq --arg s "$cur" '.head_sha=$s' "$tp" > "$tp.tmp" 2>/dev/null && mv -f "$tp.tmp" "$tp"; then
      recorded=1
    else
      rm -f "$tp.tmp"
    fi
    # BH-5001: the row records it too; a row-only verdict is recorded there alone.
    if command -v psr_terminal_patch >/dev/null 2>&1 && psr_terminal_patch "$P" "$key" head_sha "$cur"; then
      [ "$src" = row ] && recorded=1
    fi
    if [ "$recorded" = 1 ]; then
      old="$cur"
      say "terminal $key: reap-time head was unreadable — recording $cur, not re-arming"
    else
      say "terminal $key: reap-time head was unreadable and $cur could not be recorded — not re-arming"
      return 1
    fi
  fi
  if [ -n "$cur" ] && [ "$cur" != "$old" ]; then
    say "terminal $key: remote head changed ($old -> $cur) — re-arming one attempt"
    rm -f "$tp" "${tp%.terminal}.terminal-noted" "${tp%.terminal}.terminal-alerted" "${tp%.terminal}.held"
    command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$key" terminal-noted terminal-alerted || true; }
    command -v psr_hold_clear >/dev/null 2>&1 && { psr_hold_clear "$P" ticket "$key" || true; }
    command -v psr_terminal_patch >/dev/null 2>&1 && { psr_terminal_patch "$P" "$key" clear "remote head changed ($old -> $cur)" || true; }
    pool_terminal_rearm_row "$key" "$ticket"
    return 0
  fi
  rearm_ts=$(pool_newest_rearm_at "$ticket")
  if [ -n "$rearm_ts" ] && [ -n "$created" ]; then
    rearm_at=$(date -u -d "$rearm_ts" +%s 2>/dev/null) || rearm_at=0
    created_at=$(date -u -d "$created" +%s 2>/dev/null) || created_at=0
    if [ "$rearm_at" -gt "$created_at" ] 2>/dev/null; then
      say "terminal $key: an explicit human re-arm ($rearm_ts) re-arms one attempt"
      rm -f "$tp" "${tp%.terminal}.terminal-noted" "${tp%.terminal}.terminal-alerted" "${tp%.terminal}.held"
      command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$key" terminal-noted terminal-alerted || true; }
      command -v psr_hold_clear >/dev/null 2>&1 && { psr_hold_clear "$P" ticket "$key" || true; }
      command -v psr_terminal_patch >/dev/null 2>&1 && { psr_terminal_patch "$P" "$key" clear "human re-arm ($rearm_ts)" || true; }
      pool_terminal_rearm_row "$key" "$ticket"
      return 0
    fi
  fi
  say "skipping $key: terminal head unchanged ($old)"
  return 1
}

# pool_pr_comment_once <key> <ticket-id> -> one issue comment when we first see an open PR.
#
# REST, NEVER `gh issue comment` (review round 1, Important-1). That subcommand
# resolves the issue and posts through the GraphQL `addComment` mutation — two
# calls on the 5000/hr GraphQL bucket that is chronically exhausted on the hub
# and that this whole file was moved OFF for exactly that reason (BH-709, the
# comment above pr_state_rest; bin/lib/hold.sh's header; the fleet rule
# "comments via gh api …/issues/<n>/comments -F body=@file"). An exhausted
# bucket also means the sentinel is never written, so the failing pair of calls
# repeats every tick. The body goes by FILE, the way bin/hotfix-after-deploy.sh
# posts, so it never reaches argv or a process listing.
#
# AND IT SAYS SOMETHING A CLIENT CAN USE. These boards are read by the people we
# build for; "Pool spawn skipped for BH-1016" is harness jargon and named no PR.
# The number and url were already in the PR-list body the gate just read.
# ── A HELD SKIP IS NOT A SILENT ONE (BH-1461) ────────────────────────────────
# 2026-09-22: BH-1325, BH-1381 and BH-1419 were skipped here every tick for four
# hours, and the only evidence anywhere was one line per tick in the hub's own
# fly-pool.log. Their authors saw a ticket that simply never built. Two things
# come out of the skip now, and both are cheap:
#
#   <KEY>.held       refreshed every held tick, deleted the moment the gate says
#                    clear. It is what bin/fleet-status-push.sh counts so the
#                    fleet page stops calling a held row "queued" (the same
#                    incident: 8 queued / oldest 265 min for a pool with nothing
#                    to do, which is also what the watchdog pages on).
#   <KEY>.hold-noted the once-sentinel for the comment, beside .pr-noted, so the
#                    ticket is told ONCE and not 120 times in four hours. It is
#                    removed with the marker, so a re-hold after a RESUME speaks
#                    again rather than staying mute for ever.
#
# The marker is written before the comment is attempted: a POST that fails on a
# rate limit must still leave the fleet page honest.
pool_hold_marker_path() { local p; p="$(pool_terminal_path "$1")"; printf '%s\n' "${p%.terminal}.held"; }

# pool_hold_marked <key> <ticket> <verdict> — write/refresh the marker, then say
# it on the ticket once. Never fails the caller: this is evidence, not a gate.
pool_hold_marked() {
  local key="${1:-}" ticket="${2:-}" v="${3:-}" mk line first now
  mk="$(pool_hold_marker_path "$key")"
  # The why's tail is the LINE that decided (bin/lib/hold.sh): `hold:body HOLD:
  # waiting on the client`. Keep the whole tail — the verdict word tells the
  # reader where it came from and the line tells them what to change.
  line="${v#*	}"
  now="$(STAMP)"
  first="$now"
  [ -f "$mk" ] && first=$(jq -r '.first_seen // empty' "$mk" 2>/dev/null)
  [ -n "$first" ] || first="$now"
  mkdir -p "$PDIR"
  jq -nc --arg k "$key" --arg t "$ticket" --arg w "$line" --arg f "$first" --arg s "$now" \
    '{key:$k,ticket_id:$t,why:$w,first_seen:$f,last_seen:$s}' > "$mk" 2>/dev/null
  # BH-5001: the row the fleet page counts first.
  command -v psr_hold_put >/dev/null 2>&1 && { psr_hold_put "$P" ticket "$key" "$ticket" "" "$line" "$first" || true; }
  pool_hold_comment_once "$key" "$ticket" "$line"
  return 0
}

# pool_hold_clear <key> — the gate answered clear: the row is not held any more,
# so neither the fleet page's count nor the once-sentinel may survive.
pool_hold_clear() {
  local p had=0; p="$(pool_terminal_path "$1")"; p="${p%.terminal}"
  [ -f "$p.held" ] && had=1
  rm -f "$p.held" "$p.hold-noted" 2>/dev/null
  # BH-5001: the row goes too — only when there is one to lift, because this
  # runs for every clear row on every tick.
  if command -v psr_hold_clear >/dev/null 2>&1 \
     && { [ "$had" = 1 ] || psr_held_keys 2>/dev/null | grep -qxF -- "$1"; }; then
    psr_hold_clear "$P" ticket "$1" || true
  fi
  return 0
}

# pool_hold_comment_once <key> <ticket> <why-tail> — REST, body by file, on the
# credential that can see the repo: the same three rules pool_pr_comment_once
# follows, and for the same reasons (never GraphQL, never argv, never the box
# default PAT on a repo it cannot see).
pool_hold_comment_once() {
  local key="${1:-}" ticket="${2:-}" why="${3:-}" sentinel body rc=1
  [ -n "$ticket" ] && [ -n "$POOL_SLUG" ] || return 1
  case "$ticket" in ''|*[!0-9]*) return 1 ;; esac
  sentinel="$(pool_terminal_path "$key")"; sentinel="${sentinel%.terminal}.hold-noted"
  [ -f "$sentinel" ] && return 0
  body=$(mktemp "${TMPDIR:-/tmp}/pool-hold-note.XXXXXX") || return 1
  {
    printf 'This ticket is on HOLD, so the build pool is not starting a build for it.\n\n'
    printf 'What it read as the hold:\n\n```\n%s\n```\n\n' "$why"
    # THE LIFT WORD, SPELLED OUT. bin/lib/hold.sh lifts on the capital words
    # RESUME or UNHOLD only — lower case is harness prose and never lifts — and
    # a negation in front of them ("do NOT RESUME yet") is not a lift either.
    # Saying so here is the difference between a park and a dead end.
    printf 'Comment `RESUME` (or `UNHOLD`) on this ticket to lift it and the next pool tick picks it up.\n'
    # WHERE IT WAS READ DECIDES THE REMEDY. The tail names the arm that decided
    # — `hold:title`, `hold:comment <at>`, `hold:body` — and "re-word the body"
    # is the wrong instruction for two of the three: a title hold survives every
    # edit to the body, and a comment hold is lifted by another comment, not by
    # editing anything. Sending the author to the wrong place is how a park
    # becomes a dead end, which is the whole thing this comment exists to stop.
    case "$why" in
      hold:title*)   printf 'That line is the TITLE: a title holds on `(HOLD)`, `(ON HOLD)` or `[HOLD]` anywhere, or on `HOLD:` / `HOLD —` / `ON HOLD:` opening it (after the ticket key). Retitle it, or comment `RESUME`.\n' ;;
      hold:comment*) printf 'That line is a COMMENT: the newest decisive comment on this thread says HOLD. Editing the ticket will not lift it — comment `RESUME`.\n' ;;
      *)             printf 'If that quoted line is ordinary prose rather than an instruction, a body hold has to be a line that BEGINS with `HOLD`, `HOLD:` or `HOLD —`; re-word it and the hold goes away.\n' ;;
    esac
  } > "$body"
  if GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" gh api "repos/$POOL_SLUG/issues/$ticket/comments" -F "body=@$body" >/dev/null 2>&1; then
    : > "$sentinel"
    rc=0
  fi
  rm -f "$body"
  return "$rc"
}

# >>> terminal skip noted (BH-5006)
# pool_terminal_noted <key> <ticket> — the terminal gate's skip, said out loud.
# BH-4764: a push-rejected terminal on an unchanged branch was skipped here every
# tick with one fly-pool.log line and nothing else. The row was left `claimed`,
# the watchdog released it to `queued`, and fly-dispatch never re-claims a key
# whose hub file still exists, so the ticket read queued everywhere for 26h and
# never built. Now the skip:
#   - writes <KEY>.held (the BH-1461 shape) so the fleet page counts it held.
#     The HOLD gate's clear arm removes .held every tick before this gate runs,
#     so first_seen is the terminal's own created_at, which does not move;
#   - flag-off only (see below), closes the row `failed` with a reason that
#     is neither `died N times` nor `deferred N times` (br_from_queue reads
#     both as a rebuild trigger). The
#     queue FILE stays (Important-2) so a moved head can still re-arm. An
#     unreadable status (rc 1) or no row (rc 2) writes nothing: unknown is not
#     a state;
#   - pages ONCE (<KEY>.terminal-alerted) and comments ONCE (<KEY>.terminal-noted,
#     written only after the POST lands, so a failed POST retries next tick
#     without a second page). pool_terminal_check's re-arm removes all three
#     and puts a `failed` row back to `queued` (pool_terminal_rearm_row).
# Never fails the caller: this is evidence, not a gate.
pool_terminal_noted() {
  local key="${1:-}" ticket="${2:-}" tp base br sha created why mk now st body
  tp=$(pool_terminal_path "$key"); base="${tp%.terminal}"
  [ -f "$tp" ] || return 0
  br=$(jq -r '.branch // empty' "$tp" 2>/dev/null)
  sha=$(jq -r '.head_sha // empty' "$tp" 2>/dev/null)
  created=$(jq -r '.created_at // empty' "$tp" 2>/dev/null)
  now="$(STAMP)"
  why="terminal: push to ${br:-?} rejected at ${sha:-?} since ${created:-?}; head unchanged, no open PR"
  mk="$base.held"
  local had=0; [ -f "$mk" ] && had=1
  jq -nc --arg k "$key" --arg t "$ticket" --arg w "$why" --arg f "${created:-$now}" --arg s "$now" \
    '{key:$k,ticket_id:$t,why:$w,first_seen:$f,last_seen:$s}' > "$mk.$$" 2>/dev/null \
    && mv -f "$mk.$$" "$mk" 2>/dev/null || rm -f "$mk.$$"
  # BH-5001: the row the fleet page counts first (mirrors pool_hold_marked).
  # Once per hold (review of 72b69292): a marker already here means the row was
  # put on an earlier tick, and a re-put every tick is a DB write for nothing.
  [ "$had" = 1 ] || { command -v psr_hold_put >/dev/null 2>&1 && { psr_hold_put "$P" ticket "$key" "$ticket" "" "$why" "${created:-$now}" || true; }; }
  # ONLY WHEN A FILE CAN STILL RE-ARM IT. Under build_queue_rows_only the row
  # IS the queue: this tick's job file was materialised from `queue_list
  # queued`, so a row closed `failed` is never listed again, this gate never
  # runs for the key again, and the push or RETRY the note offers would re-arm
  # nothing. There the row stays `queued` and is re-checked every tick, which is
  # what it did before BH-5006; the .held marker and the notes still say why.
  if [ "${ROWS_ONLY:-0}" != 1 ] && command -v queue_status >/dev/null 2>&1; then
    st=$(queue_status "$P" "$key" 2>/dev/null) \
      && [ "$st" != failed ] \
      && QROW failed "$key" "terminal: push to ${br:-?} rejected at ${sha:-?}, head unchanged — not respawned until the branch moves or a RETRY comment (state/pool/$P/$key.terminal)"
  fi
  # BH-7431: a pool_markers row counts as the marker too (a failed-over hub).
  if ! { [ -f "$base.terminal-alerted" ] || { command -v psr_marker_has >/dev/null 2>&1 && psr_marker_has "$key" terminal-alerted "$base.terminal-alerted"; }; }; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $key: queued but never spawned — push-rejected terminal on ${br:-?} at ${sha:-?} since ${created:-?}; the branch has no open PR and has not moved. Re-arm: push to the branch, or comment RETRY on the ticket (a deleted branch reads as unchanged). Evidence: state/pool/$P/$key.terminal"
    : > "$base.terminal-alerted"
    command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$key" terminal-alerted "" || true; }
  fi
  { [ -f "$base.terminal-noted" ] || { command -v psr_marker_has >/dev/null 2>&1 && psr_marker_has "$key" terminal-noted "$base.terminal-noted"; }; } && return 0
  [ -n "$POOL_SLUG" ] || return 0
  case "$ticket" in ''|*[!0-9]*) return 0 ;; esac
  body=$(mktemp "${TMPDIR:-/tmp}/pool-terminal-note.XXXXXX") || return 0
  {
    printf 'The build pool is not starting a build for this ticket right now.\n\n'
    printf 'An earlier attempt could not push to `%s` (the push was rejected at `%s`). That branch has no open PR and has not moved since, so another attempt would hit the same rejection.\n\n' "${br:-?}" "${sha:-?}"
    # "if needed, comment RETRY" ON PURPOSE: POOL_REARM_NEG_RE reads `if` within
    # three words of the word as a negation. This comment may go out on a PAT
    # (a User, not a Bot), and a bare "comment RETRY" would then re-arm the very
    # terminal it describes — the respawn loop BH-1075 closed.
    printf 'If needed, comment `RETRY` on this ticket, or push to `%s`, and the next pool tick picks it up.\n' "${br:-?}"
  } > "$body"
  if GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" gh api "repos/$POOL_SLUG/issues/$ticket/comments" -F "body=@$body" >/dev/null 2>&1; then
    : > "$base.terminal-noted"
    command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$key" terminal-noted "" || true; }
  fi
  rm -f "$body"
  return 0
}
# <<< terminal skip noted (BH-5006)

pool_pr_comment_once() {
  local key="${1:-}" ticket="${2:-}" br owner sentinel body num url ref rc=1
  [ -n "$ticket" ] && [ -n "$POOL_SLUG" ] || return 1
  sentinel="$(pool_terminal_path "$key")"; sentinel="${sentinel%.terminal}.pr-noted"
  [ -f "$sentinel" ] && return 0
  br=$(pool_key_branch "$key")
  owner="${POOL_SLUG%%/*}"
  num="${_POOL_PR_NUM[$key]:-}"; url="${_POOL_PR_URL[$key]:-}"
  if [ -n "$num" ]; then ref="#$num"; else ref="an open pull request"; fi
  body=$(mktemp "${TMPDIR:-/tmp}/pool-pr-note.XXXXXX") || return 1
  {
    printf 'This ticket already has an open pull request — %s, on branch `%s:%s`.\n\n' "$ref" "$owner" "$br"
    [ -n "$url" ] && printf '%s\n\n' "$url"
    printf 'So I have not started another build for it. Review and merge (or close) that PR; if it closes without merging, the next run picks this ticket up again.\n'
  } > "$body"
  # ...ON THE CREDENTIAL THAT CAN SEE THE REPO, like every read above: a POST
  # the box PAT cannot make 404s, the sentinel is never written, and the pair of
  # calls repeats every tick for ever.
  if GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" gh api "repos/$POOL_SLUG/issues/$ticket/comments" -F "body=@$body" >/dev/null 2>&1; then
    : > "$sentinel"
    rc=0
  fi
  rm -f "$body"
  return "$rc"
}

# NOT CONFIGURED IS NOT UNREADABLE. Every gate below reads GitHub, so all four
# need a repo to read and a client to read it with. When this project has no
# `owner/repo` in fleet.conf, or no `gh` on PATH, there is no read to fail: the
# gate does not apply and the tick spawns exactly as it did before BH-1075. Only
# a read that was ATTEMPTED and came back unusable fails closed. Collapsing the
# two turned the gate into a fleet-wide spawn freeze for any project without a
# slug, which is how tests/pool-autoscale-test.sh caught it (12 of 29 red, every
# one "got 0"). The same shape as the token-rotation gate above, which returns 0
# on an empty POOL_SLUG rather than refusing to rotate.
pool_gates_applicable() {
  [ -n "$POOL_SLUG" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  # AND THE CLIENT MUST ACTUALLY BE ABLE TO ASK. `gh` on PATH is not the same
  # as `gh` that can reach GitHub: an unconfigured, logged-out or network-less
  # client exits non-zero with no output, and pool_rest_read hands that back as an
  # EMPTY status line — which every gate below then reads as "unreadable" and
  # fails closed on, freezing spawns for every project at once. A read that
  # came back 403 or 404 IS a read and still fails closed; one that never
  # produced a status line was never made. One probe per tick, cached.
  case "${_POOL_GATES_OK:-}" in y) return 0 ;; n) return 1 ;; esac
  # ...WITH THE CREDENTIAL THAT CAN SEE THIS REPO (review round 2, BLOCK-1).
  # Armed before the probe, so the probe itself is asked on the same identity
  # every gate below will use — otherwise a 404 from the box PAT counts as "the
  # client can ask" and the gates arm on precisely the repos that identity
  # cannot read.
  pool_slug_token_arm
  local _out _code
  # AND A REPO NO CREDENTIAL CAN SEE IS A PAGE, NOT A FROZEN PROJECT. When the
  # ladder answers `none` there is no read to make at all — the same class as no
  # slug and no gh — so the gates do not apply and the tick spawns as it did
  # before BH-1075. What must never happen is the silent version: every row
  # refused every tick as "unreadable" with nothing but a log line, which is the
  # 2026-09-12 project-5 shape gh-repo-token.sh exists to end ("a repo NO
  # credential can see is an ALERT, never a quiet skip"). Its alert is one line
  # per (lane, repo) per day and names which rung answered what.
  if [ "${POOL_SLUG_TOK_WHICH:-}" = none ]; then
    command -v gh_repo_invisible_alert >/dev/null 2>&1 \
      && gh_repo_invisible_alert "fly-pool/$P" "$POOL_SLUG" "the pool spawn gates (HOLD, open PR, push-rejected terminal, per-key cap) are not applied to any queued row of this project — it spawns ungated until a credential can see the repo"
    _POOL_GATES_OK=n; return 1
  fi
  _out=$(pool_rest_read "repos/$POOL_SLUG" "${POOL_SLUG_TOK:-}")
  _code=$(head -n 1 <<<"$_out")
  # A CUT probe is a slow hub, not "the client cannot ask": the gates apply
  # (HOLD, open PR, terminal, the per-key cap guard metered spend, BH-7421).
  if [ -z "$_code" ]; then _POOL_GATES_OK=n; return 1; fi
  _POOL_GATES_OK=y
  return 0
}

# >>> after release (BH-5967)
# pool_after_loop_alert <key> <blocker> <stand-downs> <why> — ONE ALERTS line
# when a ticket has stood down on the same blocker DEFER_AFTER_LOOP_ALERT times
# (0 = never). The marker is per (key, blocker); a release removes it.
pool_after_loop_alert() {
  local key="$1" other="$2" n="$3" why="$4" lim mk
  command -v defer_after_loop_n >/dev/null 2>&1 || return 0
  lim=$(defer_after_loop_n)
  [ "$lim" -gt 0 ] && [ "$n" -ge "$lim" ] || return 0
  mkdir -p "$PDIR" 2>/dev/null
  mk="$PDIR/$key.after-loop"
  [ "$( { command -v psr_marker_read >/dev/null 2>&1 && psr_marker_read "$key" after-loop "$mk"; } || cat "$mk" 2>/dev/null)" = "$other" ] && return 0
  printf '%s\n' "$other" > "$mk" 2>/dev/null
  command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$key" after-loop "$other" || true; }
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $key: AFTER LOOP — stood down $n times waiting for $other ($why). The row stays queued and is re-offered the tick $other has no open PR and nothing in flight; this line is said once per blocker (DEFER_AFTER_LOOP_ALERT=$lim). If $other is stuck, that is the thing to move."
}
# pool_after_churned <key> <blocker> — rc 0 when the gate has released <key>
# from <blocker> three or more times in the last 24 h (<key>.after-released).
pool_after_churned() {
  local ro rn rt v
  v=$( { command -v psr_marker_read >/dev/null 2>&1 && psr_marker_read "$1" after-released "$PDIR/$1.after-released"; } || cat "$PDIR/$1.after-released" 2>/dev/null) || return 1
  IFS=$'\t' read -r ro rn rt <<<"$v"
  [ "$ro" = "$2" ] || return 1
  case "$rn" in ''|*[!0-9]*) return 1 ;; esac
  case "$rt" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rn" -ge 3 ] && [ $(( $(date -u +%s) - rt )) -lt 86400 ]
}
# pool_after_open <blocker-key> — rc 0 when the blocker still holds: it is in
# flight in this pool (a pool json or a queue file names it, or its queue row is
# queued/claimed), or an open PR is on its branch, on a `-r<N>` re-run branch, or
# titled `<KEY>:` (BH-6671). rc 1 when it is done. rc 2 when a PR read did not
# answer: the row waits, it is not released on silence.
# A key this tick already handed to spawn_one is in flight too (TICK_KEYS):
# spawn_one runs in the background and moves the queue file away BEFORE it
# writes the pool json, so for that moment neither file names the key, and a
# later row in the same tick that waits on it would read it as done.
pool_after_open() {
  local other="$1" st
  case "${TICK_KEYS:-}" in *" $other "*) return 0 ;; esac
  grep -lsE "\"key\": *\"$other\"" "$POOL"/*.json >/dev/null 2>&1 && return 0
  [ -e "$QDIR/$other.json" ] && return 0
  # BH-7706: the tick read the queued and claimed rows once (pdc_queue_prime).
  # From a complete listing a key that is absent is neither; any other listing
  # leaves the per-key read below.
  if [ "${_PDC_QOK:-0}" = 1 ]; then
    case "${_PDC_QSTATE[$other]:-}" in queued|claimed) return 0 ;; esac
  elif command -v queue_status >/dev/null 2>&1; then
    st=$(queue_status "$P" "$other" 2>/dev/null) || st=""
    case "$st" in queued|claimed) return 0 ;; esac
  fi
  pr_exists_for_key_rest "$other"
  case $? in 0) return 0 ;; 1) ;; *) return 2 ;; esac
  pr_open_for_key_any_rest "$other"
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
# pool_after_cycle <key> — rc 0 and the cycle's byte-smallest key when the
# `after` chain from <key> through this pool's queue files comes back to <key>
# (BH-A waits for BH-B, BH-B for BH-A; or longer). bin/plan-after.sh's MUTUAL
# rule, applied to the pool: the byte-smallest key of the cycle goes first, so
# a cycle can never hold every member for ever (review of 99682a0c6). The walk
# stops after 20 hops; rc 1 when there is no cycle back to <key>.
pool_after_cycle() {
  local key="$1" k="$1" n=0 seen=" " nxt
  while [ "$n" -lt 20 ]; do
    nxt=$(jq -r '.after // empty' "$QDIR/$k.json" 2>/dev/null)
    [ -n "$nxt" ] || return 1
    seen="$seen$k "
    [ "$nxt" = "$key" ] && { printf '%s\n' $seen | LC_ALL=C sort | head -n 1; return 0; }
    case "$seen" in *" $nxt "*) return 1 ;; esac
    k="$nxt"; n=$((n + 1))
  done
  return 1
}
# pool_after_gate <job-file> <key> <ticket-id> — rc 0 go on to the other gates,
# rc 1 skip this tick. A row with no `after` passes untouched. A row is
# RELEASED here, in this tick, when its blocker is done, when it is the
# byte-smallest key of a wait cycle, or when it has waited POOL_AFTER_MAX_MIN
# (default 360, the PLAN_AFTER_MAX_MIN ceiling; one alert). A release is a fresh
# queue row with `after` dropped and the deferral count reset to 0, so the
# ticket is offered on the tick its blocker merges, not after a resolver pass.
# THE THIRD RELEASE FOR THE SAME BLOCKER IN 24 H KEEPS THE COUNT: a blocker this
# gate cannot see in flight would otherwise release the row every tick, the
# machine would stand down again, and the reset would keep it under
# JOBS_QUEUE_DEFER_MAX and DEFER_AFTER_LOOP_ALERT for ever (review of 99682a0c6).
pool_after_gate() {
  local JF="$1" KEY="$2" TICKET="$3" other rc att now sf so st age max why="" cyc rf ro rn rt keep d v
  other=$(jq -r '.after // empty' "$JF" 2>/dev/null)
  [ -n "$other" ] || return 0
  now=$(date -u +%s)
  # The wait's clock: <key>.after-since holds "<blocker>\t<epoch>", started on
  # the first held tick for that blocker.
  sf="$PDIR/$KEY.after-since"; so=""; st=""
  v=$( { command -v psr_marker_read >/dev/null 2>&1 && psr_marker_read "$KEY" after-since "$sf"; } || cat "$sf" 2>/dev/null) && IFS=$'\t' read -r so st <<<"$v"
  case "$st" in ''|*[!0-9]*) st="" ;; esac
  if [ "$so" != "$other" ] || [ -z "$st" ]; then
    mkdir -p "$PDIR" 2>/dev/null; printf '%s\t%s\n' "$other" "$now" > "$sf"; st="$now"
    command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$KEY" after-since "$other"$'\t'"$now" || true; }
  fi
  age=$(( now - st ))
  max="${POOL_AFTER_MAX_MIN:-360}"; case "$max" in ''|*[!0-9]*) max=360 ;; esac
  if cyc=$(pool_after_cycle "$KEY"); then
    if [ "$cyc" != "$KEY" ]; then
      say "skipping $KEY: waits for $other in a wait cycle; $cyc, the byte-smallest key, goes first — no machine"; return 1
    fi
    why="mutual: $KEY is the byte-smallest key of a wait cycle through $other"
  else
    pool_after_open "$other"; rc=$?
    case "$rc" in
      1) why="$other is done (no open PR, nothing in flight)" ;;
      *) if [ "$max" -gt 0 ] && [ "$age" -ge $(( max * 60 )) ]; then
           why="ceiling: held $((age / 60)) min for $other (POOL_AFTER_MAX_MIN=$max)"
           HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: AFTER CEILING — waited $((age / 60)) min for $other (POOL_AFTER_MAX_MIN=$max), so the hold is released and the ticket is offered again; its machine re-checks the overlap. If $other is stuck, that is the thing to move."
         elif [ "$rc" = 0 ]; then
           say "skipping $KEY: waits for $other (still in flight or its PR is open) — no machine"; return 1
         else
           say "skipping $KEY: waits for $other, and its PR read did not answer — retried next tick"; return 1
         fi ;;
    esac
  fi
  # The release count for this blocker in the last 24 h.
  rf="$PDIR/$KEY.after-released"; ro=""; rn=0; rt=0
  v=$( { command -v psr_marker_read >/dev/null 2>&1 && psr_marker_read "$KEY" after-released "$rf"; } || cat "$rf" 2>/dev/null) && IFS=$'\t' read -r ro rn rt <<<"$v"
  case "$rn" in ''|*[!0-9]*) rn=0 ;; esac; case "$rt" in ''|*[!0-9]*) rt=0 ;; esac
  # A new blocker, or a 24 h window that ran out, starts the count again, and
  # only then may the AFTER LOOP page speak again for this row. Within the
  # window the marker stays, so the page is said once however many release
  # cycles there are (review of 22e7719c5).
  # (A new blocker needs no removal: the marker names its blocker, and
  # pool_after_loop_alert speaks for any other one.)
  if [ "$ro" != "$other" ]; then
    rn=0; rt="$now"
  elif [ $(( now - rt )) -ge 86400 ]; then
    rn=0; rt="$now"; rm -f "$PDIR/$KEY.after-loop" 2>/dev/null
    command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$KEY" after-loop || true; }
  fi
  d=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null); case "$d" in ''|*[!0-9]*) d=0 ;; esac
  keep=0; [ "$rn" -ge 2 ] && keep=1
  [ "$keep" = 1 ] || d=0
  att=$(jq -r '.attempt // 0' "$JF" 2>/dev/null); case "$att" in ''|*[!0-9]*) att=0 ;; esac
  if QROW requeue "$KEY" "released: $why" "$att" "{\"deferrals\":$d}" "$TICKET"; then
    :
  else
    say "$KEY: released ($why), but the ticket was abandoned by an operator — not re-offered"
    rm -f "$JF"
    return 1
  fi
  jq -c --argjson d "$d" 'del(.after) | .deferrals = $d' "$JF" > "$JF.tmp" 2>/dev/null && mv -f "$JF.tmp" "$JF"
  rm -f "$JF.tmp" "$sf" 2>/dev/null
  command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$KEY" after-since || true; }
  printf '%s\t%s\t%s\n' "$other" "$((rn + 1))" "$rt" > "$rf" 2>/dev/null
  command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$KEY" after-released "$other"$'\t'"$((rn + 1))"$'\t'"$rt" || true; }
  if [ "$keep" = 1 ]; then
    say "RELEASED $KEY: $why — re-offered this tick with a fresh row; release $((rn + 1)) for $other in 24 h, so deferrals stay at $d"
  else
    say "RELEASED $KEY: $why — re-offered this tick with a fresh row, deferrals reset to 0"
  fi
  return 0
}
# <<< after release (BH-5967)
# pool_spawn_decision <job-file> <key> <ticket-id> -> rc 0 spawn, 1 skip.
# pool_sibling_stack <jf> <key> <ticket> <branch> <sibling> — gate 0c's stack
# arm (BH-6374). Requeue the row with stack_base=<branch>, its attempt, counts
# and hotfix flag kept, then add stack_base to the queue file. Says the stack
# line only when both the requeue and the rewrite worked. An abandoned ticket
# (QROW rc 1) is closed by QROW and its file is left as it is.
pool_sibling_stack() {
  local jf="$1" k="$2" t="$3" b="$4" s="$5" att d x hf meta
  att=$(jq -r '.attempt // 0' "$jf" 2>/dev/null); case "$att" in ''|*[!0-9]*) att=0 ;; esac
  d=$(jq -r '.deferrals // 0' "$jf" 2>/dev/null); case "$d" in ''|*[!0-9]*) d=0 ;; esac
  x=$(jq -r '.deaths // 0' "$jf" 2>/dev/null); case "$x" in ''|*[!0-9]*) x=0 ;; esac
  hf=$(jq -r '.hotfix // false' "$jf" 2>/dev/null)
  meta=$(jq -nc --argjson d "$d" --argjson x "$x" --arg sb "$b" --arg hf "$hf" \
    '{deferrals:$d,deaths:$x,stack_base:$sb} + (if $hf == "true" then {hotfix:true} else {} end)')
  if QROW requeue "$k" "sibling stack on $b (BH-6374)" "$att" "$meta" "$t"; then
    if jq --arg sb "$b" '. + {stack_base:$sb}' "$jf" > "$jf.sib.$$" 2>/dev/null && mv -f "$jf.sib.$$" "$jf"; then
      say "SIBLING_SERIAL $k stacks on $b (open PR of $s) — requeued with stack_base; spawns next tick"
      return 0
    fi
    rm -f "$jf.sib.$$"
    say "SIBLING_SERIAL $k: requeued with stack_base=$b but the queue file $jf could not be rewritten — re-checked next tick"
    return 1
  fi
  say "SIBLING_SERIAL $k: not stacked on $b — the ticket was abandoned by an operator, the row is closed and the queue file is left"
  return 1
}

pool_spawn_decision() {
  local JF="${1:-}" KEY="${2:-}" TICKET="${3:-}" v _pr_rc _psd_sentinel _psd_ss _psd_ssrc _psd_t0 _psd_sb _psd_sgrc
  # 0. A REBASE ROW IS NOT A TICKET, AND ALL FOUR GATES BELOW READ IT AS ONE
  # (review round 1, BLOCK-1). bin/merge-conductor.sh enqueues its pool rebases
  # as `RB-<pr>-<head8>` rows whose ticket_id is the PR NUMBER
  # (mc_pool_rebase_key in bin/lib/merge-conductor-lib.sh; the row is written by
  # bin/fly-dispatch.sh). Every gate here then asks the wrong question of it:
  #   HOLD      hold_check reads that number as an ISSUE, and hold_classify
  #             answers `held label-absent` for anything without the `ai-build`
  #             label — which no harness PR carries. Proven against the real
  #             library: `hold_check example-org/cromford 1127` -> `held
  #             label-absent`. Every pool rebase would be skipped on every tick
  #             with its queue file left in place, no machine would ever spawn,
  #             and the conductor would fail the rebase at
  #             MC_REBASE_POOL_TIMEOUT_SECS: the merge lane stalled fleet-wide.
  #   open PR   an open PR is the POINT of a rebase, not a reason to refuse one
  #             — and the comment would land on that PR as noise.
  #   terminal  the terminal file is keyed on a ticket's branch and its
  #             push-rejected reason; a rebase row has neither.
  #   cap       its refusal DELETES the queue file without failing the row, so
  #             the conductor's view of the row and the pool's would disagree
  #             (and the RB key already carries the head it is rebasing, so a
  #             repeat is a new key, not a re-spawn of this one).
  # The reap side already special-cases RB-* for the same reason (the
  # BUILD_DEFERRED arm below). A rebase row spawns exactly as it did before
  # BH-1075; bin/merge-conductor.sh owns that lane's timeout and its retries.
  # An RR-<pr>-<head8> re-review row (BH-7635) is the same kind of row for the
  # same reasons: a conductor read of an open PR, never a ticket.
  case "$KEY" in
    RB-*) say "$KEY: rebase row — the ticket spawn gates do not apply"; return 0 ;;
    RR-*) say "$KEY: re-review row — the ticket spawn gates do not apply"; return 0 ;;
    # A console preview row (BH-8030): a build of one PR head for the hub's
    # console preview lane, which owns its retries. Never a ticket.
    CP-*) say "$KEY: console preview row — the ticket spawn gates do not apply"; return 0 ;;
  esac
  if [ "${_POOL_ROWS_DECIDED:-0}" -ge 1 ] && pool_tick_budget_spent; then
    [ -n "${_POOL_BUDGET_SAID:-}" ] || say "tick budget of ${POOL_TICK_BUDGET_S:-600}s spent for $P: no more rows are decided this tick, the lock is released at the end"
    _POOL_BUDGET_SAID=1; return 1
  fi
  _POOL_ROWS_DECIDED=$(( ${_POOL_ROWS_DECIDED:-0} + 1 ))
  # >>> execute-empty stop (BH-5911)
  # 0b. A key whose execute stage ended EXECUTE_EMPTY POOL_EXECUTE_EMPTY_MAX
  # times (2) in POOL_EXECUTE_EMPTY_WINDOW_S (24 h) is not relaunched: it gets
  # ONE NEEDS_HUMAN ask with the last stop reason (bin/lib/execute-empty.sh).
  # The row stays queued, like the HOLD arm; the window rolling lifts it. It
  # sits ABOVE pool_gates_applicable on purpose: it reads only the hub's own
  # build records, so it needs no repo slug and no GitHub, and a project whose
  # spawn gates are inactive must not loop either.
  if command -v ee_stop_check >/dev/null 2>&1 && ! ee_stop_check "$P" "$KEY" "$TICKET"; then
    return 1
  fi
  # <<< execute-empty stop
  # 0c. A SIBLING PART WAITS FOR ITS SIBLING (BH-6374). bin/sibling-serial.sh
  # answers rc 3 and one SIBLING_SERIAL line when a part (TK-142.2) shares a
  # planned file with a sibling in flight, an open sibling PR, or a lower
  # sibling queued. The row stays queued: no QROW write, no deferral count, no
  # alert. It reads only hub state, so it sits above pool_gates_applicable.
  # A line that ends ` stackable base=<branch>` (one open sibling PR is the only
  # blocker) on a row with no stack_base yet is requeued ONCE with that
  # stack_base instead (C1): the next tick builds it on the BH-1174 STACK path,
  # and check skips the PR the row stacks on (SIBLING_STACK_BASE).
  # BH-6979: with scheduler.mode=enforce the scheduler's ready set decides
  # first (bin/lib/sched-gate.sh). A wait (verdict no or unknown, or not in the
  # set) holds the row like a SIBLING_SERIAL wait: no machine, no QROW write,
  # no deferral count. A ready verdict spawns without asking sibling-serial:
  # the scheduler already read its data. Any pass (not enforced, in flight, an
  # unusable set) falls through to today's sibling-serial check.
  _psd_sgrc=2
  if command -v sched_gate >/dev/null 2>&1; then
    sched_gate "$P" "$KEY" >/dev/null 2>>"$LOG"; _psd_sgrc=$?
  fi
  if [ "$_psd_sgrc" = 3 ]; then
    say "$SCHED_LINE — no machine spawned; re-checked next tick"; return 1
  elif [ "$_psd_sgrc" = 0 ]; then
    say "$SCHED_LINE — sibling-serial not consulted (scheduler.mode=enforce)"
  elif [ -x "$HARNESS/bin/sibling-serial.sh" ]; then
    _psd_sb=$(jq -r '.stack_base // ""' "$JF" 2>/dev/null); case "$_psd_sb" in *[!A-Za-z0-9._/-]*) _psd_sb="" ;; esac
    _psd_ss=$(HARNESS="$HARNESS" SIBLING_QDIR="$QDIR" SIBLING_STACK_BASE="$_psd_sb" "$HARNESS/bin/sibling-serial.sh" check "$P" "$KEY" 2>>"$LOG"); _psd_ssrc=$?
    if [ "$_psd_ssrc" = 3 ] && [ -n "$_psd_ss" ]; then
      if [ -z "$_psd_sb" ] && [[ "$_psd_ss" =~ \ stackable\ base=([A-Za-z0-9._/-]+)$ ]]; then
        pool_sibling_stack "$JF" "$KEY" "$TICKET" "${BASH_REMATCH[1]}" "$(printf '%s\n' "$_psd_ss" | awk '{print $5}')"
        return 1
      fi
      say "$_psd_ss — no machine spawned; re-checked next tick"; return 1
    fi
    case "$_psd_ss" in SIBLING_SERIAL_RELEASED*) say "$_psd_ss" ;; esac
  fi
  if ! pool_gates_applicable; then
    [ -n "${_POOL_GATES_SAID:-}" ] || {
      # NOT "pool $P: ..." — that exact prefix is the per-tick throughput line
      # tests/pool-autoscale-test.sh reads back with `grep -o 'pool <p>: .*'`,
      # and a second line wearing it would shadow the one that reports depth.
      say "$P spawn gates inactive: no repo slug, a gh client that cannot reach GitHub, or a repo no credential can see (that one also writes an ALERTS line naming the rungs) — HOLD/open-PR/terminal/cap checks not applied"
      _POOL_GATES_SAID=1
    }
    return 0
  fi
  # 0b. A ROW WAITING ON A NAMED BLOCKER (BH-5967): held with no machine until
  # the blocker is done, then released in the same tick. Before the HOLD read,
  # because a held row needs no other read.
  pool_after_gate "$JF" "$KEY" "$TICKET" || return 1
  # 1. HOLD gate (skip and retry next tick; leave the queue file). A cached
  # held verdict whose listing key did not change answers without a read
  # (BH-6549); it takes the same held arm below as a fresh one.
  if command -v pool_hold_cache_lookup >/dev/null 2>&1 && pool_hold_cache_lookup "$TICKET"; then
    v="$_PHC_V"
  else
    _psd_t0=$SECONDS
    v=$(pool_hold_check "$TICKET" 2>/dev/null) || true
    _PHC_READ_S=$((_PHC_READ_S + SECONDS - _psd_t0))
    command -v pool_hold_cache_store >/dev/null 2>&1 && pool_hold_cache_store "$TICKET" "$v"
  fi
  case "$v" in
    held*)
      # A HOLD THAT CAN NEVER LIFT ITSELF PARKS THE ROW (review round 2, Nit-1).
      # hold_classify answers `held<TAB>closed` for a ticket that is no longer
      # open and `held<TAB>label-absent` for one whose ai-build label is gone.
      # Neither is a "come back next tick" condition the way a HOLD comment is:
      # nothing about the pool's own state will ever change them, so the retry
      # arm below reads two REST calls per row per tick for ever and nothing
      # says why the ticket never builds. Before BH-1075 such a row spawned and
      # was refused on the box, which at least closed it. Park it instead — the
      # row is failed with the reason, the queue file goes, and re-opening or
      # re-labelling the ticket is what enqueues it again.
      case "$v" in
        *"	closed"|*"	label-absent")
          say "skipping $KEY: ${v#held	} — parking the row (nothing here can lift that)"
          QROW failed "$KEY" "ticket ${TICKET:-?} is ${v#held	} — pool row parked, not retried"
          rm -f "$JF"
          # The row is failed, not held: it must not keep counting as held on
          # the fleet page after its queue file is gone (BH-1461).
          pool_hold_clear "$KEY" || true
          return 1 ;;
      esac
      say "skipping $KEY: HOLD ($v)"
      # THE SKIP IS EVIDENCE, NOT A GATE (BH-1461): mark the row for the fleet
      # page and say it on the ticket once. Never allowed to change the answer
      # above — a failed POST still leaves the row held and retried next tick.
      pool_hold_marked "$KEY" "$TICKET" "$v" || true
      return 1 ;;
    unreadable*)
      # NEITHER pool_hold_marked NOR pool_hold_clear, on purpose: a read that
      # did not answer says nothing about the ticket, so a `<KEY>.held` left by
      # an earlier tick is KEPT as the last known state. Clearing it here would
      # let a rate-limited read quietly empty the fleet page's held count, and
      # marking here would invent a hold GitHub never confirmed.
      say "skipping $KEY: hold check unreadable ($v) — will retry"
      return 1 ;;
    *)
      # CLEAR. A row that was held and is not any more must stop being counted
      # as held on the fleet page, and must be able to speak again if re-held.
      # A terminal key keeps its hold (review of 72b69292): pool_terminal_noted
      # owns that hold, and the terminal gate below lifts it on a re-arm.
      # Clearing it here deleted and re-wrote the hold row on every tick.
      [ -f "$(pool_terminal_path "$KEY")" ] || pool_hold_clear "$KEY" || true ;;
  esac
  # 2. Existing open PR for this branch: comment once and park the queue file.
  pr_exists_for_key_rest "$KEY"
  _pr_rc=$?
  if [ "$_pr_rc" -eq 0 ]; then
    say "skipping $KEY: open PR exists"
    pool_pr_comment_once "$KEY" "$TICKET"
    # THE LEDGER ROW CLOSES WITH THE QUEUE FILE (review round 2, Important-3).
    # Deleting the file while the row stayed `claimed` left the two views of one
    # row disagreeing: the ledger watchdog eventually requeues the abandoned
    # claim, the gate refuses it again and deletes it again, for ever. `failed`
    # with the reason is the honest state — the build did not happen and will
    # not until that PR is merged or closed — and bin/blocked-resolver.sh, which
    # reads failed rows, can say so on the ticket.
    QROW failed "$KEY" "an open PR already exists for ticket/$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]') — no build started"
    rm -f "$JF"
    return 1
  elif [ "$_pr_rc" -eq 2 ]; then
    # Only a read that got NO HTTP answer (a timeout, a dead client) is the
    # load shape. An affirmative 403/429/5xx keeps the row waiting, as before.
    if [ "${_POOL_PR_UNREADABLE_CODE:-none}" = none ] && pool_row_is_new_build "$JF" "$KEY"; then
      say "$KEY: PR check unreadable, but this is a new build (attempt 0, no spawn record, no terminal) — no PR read needed, spawning"
    else
      say "skipping $KEY: PR check unreadable — will retry"
      return 1
    fi
  fi
  # 3. Terminal push-rejected state. Re-arm if the remote head changed or an
  # explicit human re-arm appeared.
  if ! pool_terminal_check "$KEY" "$TICKET"; then
    # NOT SILENTLY (BH-5006): .held, the row closed failed, one page, one note.
    pool_terminal_noted "$KEY" "$TICKET" || true
    # THE QUEUE FILE STAYS (review round 1, Important-2). Deleting it made the
    # re-arm unreachable through the pool's own state: nothing in this file
    # re-creates a queue file, so "a changed head re-arms one attempt" could
    # only ever fire if the ledger watchdog happened to requeue the still-
    # `claimed` row first — a gap this build had declared open rather than
    # closed. Keeping the row is what lets the NEXT tick read the new head and
    # re-arm on its own. It costs nothing: the row is skipped on the same two
    # cached reads every tick, exactly like the HOLD arm above, and never
    # reaches a machine — next_job_or_destroy's reuse handoff runs this same
    # decision before it hands a row to a reaped machine.
    return 1
  fi
  # 3b. A live After: hold spawns no machine (BH-5912). A key that stood down
  # behind a sibling would only boot, read the same hold in the pre-plan gate
  # (bin/lib/rb/gates.sh, `# >>> overlap not-before`) and defer again. The same
  # bin/plan-after.sh check answers here: with no local marker it reads the
  # key's `overlap_defer` fleet row, then the sibling's claims and open PR.
  # Only a key that has deferred can hold one, so a fresh row is not asked.
  # Only rc 3 with output skips; any other answer spawns, as before. The row
  # stays queued (the HOLD arm's shape), with no QROW and no ALERTS line: a wait
  # on a sibling is normal. Before the cap on purpose: a held key must not log
  # or page a cap. A hotfix row is never held (BH-6292: a hotfix is never
  # deferred). The machine's gates.sh skips the same hold on HOTFIX=1, so a key
  # labelled hotfix after its defer spawns now.
  local _psd_d _psd_pa _psd_parc
  _psd_d=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null)
  case "$_psd_d" in ''|*[!0-9]*) _psd_d=0 ;; esac
  if [ "$_psd_d" -gt 0 ] && job_is_hot "$JF"; then
    say "$KEY is a hotfix: After: hold not checked — a hotfix is never deferred"
  elif [ "$_psd_d" -gt 0 ] && [ -x "$HARNESS/bin/plan-after.sh" ]; then
    _psd_pa=$(HARNESS="$HARNESS" "$HARNESS/bin/plan-after.sh" check "$P" "$KEY" 2>/dev/null); _psd_parc=$?
    if [ "$_psd_parc" = 3 ] && [ -n "$_psd_pa" ]; then
      say "skipping $KEY: After: ${_psd_pa#AFTER } — no machine spawned; re-checked next tick"
      return 1
    fi
  fi
  # 4. Per-key spawn cap: a TIMED RETRY, never a park (BH-4859).
  # THE ROW STAYS QUEUED. This arm used to close the row `failed … deferred to a
  # human` and delete the queue file, and nothing read that reason again:
  # bin/blocked-resolver.sh only picks up `died N times` / `deferred N times`,
  # and a resolver hand-off would re-enqueue the SAME key into the same cap. The
  # cap check is already a window timer, so the row simply waits for it, the
  # same shape as the HOLD and terminal arms above: rows-only re-materialises it
  # next tick, flag-off keeps the file. The ladder still ends: only machines
  # that really got their job count (spawn_one un-records every infra exit), and
  # builds that die or defer have their own owned terminals.
  if ! pool_spawn_cap_check "$KEY"; then
    local _psd_at _psd_when _psd_n
    _psd_at=$(pool_spawn_cap_next_at "$KEY")
    if [ -n "$_psd_at" ]; then _psd_when="after $(date -u -d "@$_psd_at" '+%H:%MZ' 2>/dev/null || date -u -r "$_psd_at" '+%H:%MZ')"
    else _psd_when="when the window rolls"; fi
    _psd_n=$(pool_spawn_cap_count "$KEY")
    say "skipping $KEY: spawn cap reached ($_psd_n of ${POOL_SPAWN_CAP:-2} in ${POOL_SPAWN_CAP_WINDOW:-86400}s) — retried $_psd_when, when the oldest counted spawn leaves the window"
    # THE SENTINEL IS READ, NOT JUST WRITTEN: one page per key per cap episode,
    # not one per tick. The log line above is the per-tick diagnostic. The file
    # name `.defer-to-human` is LEGACY (BH-4859): hub boxes hold live ones, and
    # renaming it would re-page every key mid-episode.
    local sentinel; sentinel="$(pool_terminal_path "$KEY")"; sentinel="${sentinel%.terminal}.defer-to-human"
    if ! { [ -f "$sentinel" ] || { command -v psr_marker_has >/dev/null 2>&1 && psr_marker_has "$KEY" cap-wait "$sentinel"; }; }; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: POOL_SPAWN_CAP_WAIT — spawn cap of ${POOL_SPAWN_CAP:-2} in ${POOL_SPAWN_CAP_WINDOW:-86400}s reached; row stays queued and spawns again $_psd_when"
      : > "$sentinel"
      command -v psr_marker_put >/dev/null 2>&1 && { psr_marker_put "$P" "$KEY" cap-wait "" || true; }
    fi
    return 1
  fi
  # Under the cap again — the window rolled, or an operator cleared the spawn
  # log. Drop the page sentinel so the NEXT cap trip is a fresh interrupt: a
  # sentinel that is only ever written silences this key for the life of the
  # box, which is a page that stops arriving rather than a page sent once.
  _psd_sentinel="$(pool_terminal_path "$KEY")"
  rm -f "${_psd_sentinel%.terminal}.defer-to-human"
  command -v psr_marker_clear >/dev/null 2>&1 && { psr_marker_clear "$P" "$KEY" cap-wait || true; }
  # 5. Who added the label (BH-6957): the builder's own trigger-actor gate,
  # asked before a machine is spent. After the cap on purpose: a capped or held
  # row costs no events read. bin/lib/pool-actor-gate.sh owns the answer.
  if command -v pool_actor_gate >/dev/null 2>&1; then pool_actor_gate "$JF" "$KEY" "$TICKET" || return 1; fi
  return 0
}
# <<< pool terminal / spawn cap / hold gate
QROW() { # QROW done|failed|requeue <key> <reason> [attempt] [meta] [ticket-id]
  # rc 1 ONLY from `requeue`, when an operator ABANDONED the ticket (BH-2406):
  # the row is closed and nothing is enqueued, so a caller must not write the
  # queue file or a line claiming a requeue. Every other path answers 0.
  command -v queue_done >/dev/null 2>&1 || return 0
  local _qr_jid
  case "$1" in
    # A requeue is CLOSE-THEN-ENQUEUE, not a status flip: enqueueing over a row
    # that is still `claimed` is a duplicate by design (that guard is what stops
    # a key being re-queued mid-build), so the dead attempt has to be closed
    # first. The worker then treats the re-queue of a terminal row as what it
    # is — a real new attempt, carrying the count forward.
    requeue) queue_done "$P" "$2" failed "$3" >/dev/null 2>&1 || true
             # AN ABANDONED TICKET IS FINAL (BH-2406). The operator ended the
             # ticket's newest build row, so this death or deferral is the end of
             # it, not a reason to spawn again. The row stays FAILED under a
             # reason br_from_queue never reads as a park (no `died N times`,
             # no `deferred N times`). rc 1/2 (not abandoned, or the worker did
             # not answer) is today's requeue, byte for byte.
             if command -v job_ticket_abandoned >/dev/null 2>&1 \
                && _qr_jid=$(job_ticket_abandoned "$P" "$2" 2>/dev/null); then
               queue_done "$P" "$2" failed "ABANDONED by an operator (job $_qr_jid): the pool does not requeue it" >/dev/null 2>&1 || true
               say "$2: job $_qr_jid was abandoned by an operator — row FAILED, not requeued"
               return 1
             fi
             # THE TICKET ID RIDES THE REQUEUE (2026-09-14). It used to be sent
             # empty, and the handoff below quarantines exactly that row
             # ("malformed queue entry (ticket='')") — so the retry this was
             # meant to buy was a machine that could never build. No id, no
             # enqueue: the row stays FAILED and bin/blocked-resolver.sh, which
             # can look the id up, owns the retry.
             if [ -z "${6:-}" ] || [ "${6:-}" = null ]; then
               HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $2: requeue has no ticket id — the row is left FAILED rather than enqueued blank; bin/blocked-resolver.sh owns the retry"
               return 0
             fi
             queue_put  "$P" "$2" "$6" fly "${4:-}" "${5:-}" >/dev/null 2>&1 || true ;;
    *)       queue_done "$P" "$2" "$1" "$3" >/dev/null 2>&1 || true ;;
  esac
  return 0
}

# >>> mput error note (BH-7174)
# A failed push used to log "FAILED" with no reason: mexec sent flyctl's stderr
# to /dev/null. mexec still does that for every caller but mput (many read its
# stdout as data, so stderr must never join it); mput alone sets _mexec_err to
# a temp file and, on a non-zero rc, writes ONE line per machine with flyctl's
# last stderr line. Lowercase on purpose: it is a per-call local, not a knob.
mexec() { # mexec <machine-id> <cmd>
  timeout 90 "$FLY" ssh console -a "$APP" --machine "$1" -C "/bin/sh -c $(printf '%q' "$2")" 2>"${_mexec_err:-/dev/null}"
}
mput() { # mput <machine-id> <local-file> <remote-path>  (base64 through console)
  # Seed mode (BH-7430): the file goes to the machine's --file-local seed.
  if [ -n "${POOL_SEED_DIR:-}" ]; then pool_seed_put "$2" "$3"; return; fi
  local B64 rc _mexec_err; B64=$(base64 -w0 "$2")
  _mexec_err=$(mktemp "${TMPDIR:-/tmp}/mput-err.XXXXXX" 2>/dev/null) || _mexec_err=""
  mexec "$1" "mkdir -p $(dirname "$3") && echo $B64 | base64 -d > $3 && chmod 600 $3" >/dev/null
  rc=$?
  [ "$rc" = 0 ] || mput_fail_note "$1" "$3" "$rc" "$_mexec_err"
  [ -n "$_mexec_err" ] && rm -f "$_mexec_err"
  return "$rc"
}
# >>> seed put (BH-7430)
# pool_seed_put <local-file> <remote-path>: in seed mode ($POOL_SEED_DIR set by
# pool_pull_decide), mput copies the file to $POOL_SEED_DIR/<remote-path>, and
# `fly machine run --file-local /run/harness-seed/<remote-path>=<copy>` writes
# it on the machine before boot. fly/entrypoint.sh moves it to <remote-path>.
# Only the three trees the push path writes are allowed, so a bad path in a
# relay can never place a file anywhere else on the machine.
pool_seed_put() {
  case "${2:-}" in
    /run/harness/*|/run/harness-env/*|/data/harness/state/*) ;;
    *) return 1 ;;
  esac
  case "$2" in *..*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ -r "${1:-}" ] || return 1
  ( umask 077; mkdir -p "$POOL_SEED_DIR$(dirname "$2")" && cp "$1" "$POOL_SEED_DIR$2" ) 2>/dev/null
}
# <<< seed put
# mput_fail_note <mid> <remote-path> <rc> <errfile> -> one `push of <path>
# FAILED rc=<n>: <text>` line, the first time a machine fails a push. The marker
# $POOL/.<mid>.puterr goes with the machine's other state. The command line
# carries the base64 of the env bundle, so if flyctl echoes it, every run of 40+
# base64 characters is withheld, and a credential shape withholds the text.
mput_fail_note() {
  local why
  ( set -C; : > "$POOL/.$1.puterr" ) 2>/dev/null || return 0
  if [ -z "${4:-}" ] || [ ! -r "$4" ]; then
    why="(stderr not captured)"
  else
    why=$(grep -v '^[[:space:]]*$' "$4" | tail -n 1 | tr -d '\000-\037' \
          | sed -E 's#[A-Za-z0-9+/=]{40,}#<base64 withheld>#g' | cut -c1-240)
    [ -n "$why" ] || why="(flyctl printed nothing)"
    if grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|sk-ant-|sk-or-|=[A-Za-z0-9_./+-]{32,}' <<<"$why"; then
      why="reason withheld: flyctl output looked like a credential"
    fi
  fi
  [ "$3" = 124 ] && why="$why (timeout 90s)"
  say "$1: push of $2 FAILED rc=$3: $why"
  return 0
}
# <<< mput error note

# >>> machine destroy (BH-660)
# EVERY DESTROY ANSWERS FOR ITSELF (BH-660). Until now all six destroy sites in
# this file were `timeout 60 "$FLY" machine destroy … >/dev/null 2>&1` with the
# exit code dropped on the floor, and the two tracked ones then `rm -f`'d the
# machine's json whatever had happened. ONE refused destroy — API weather, a 60s
# timeout, a machine still `stopping` — turned a tracked machine into an
# untracked one, and nothing in this script could ever see it again: the REAP
# loop below only visits machines that have a file. It idled out, stopped, and
# stayed in the app for good. That is the shape of the leaked machines BH-660
# counted.
#
# Idempotent against Fly: "not found" means the machine is already in the state
# this call was asking for, so it is a success and pages nobody. Anything else is
# a FAILURE and says so — flyctl's own error body goes to fly-pool.log and, once
# per machine per UTC day, to ALERTS.log. The machine is not lost either way: the
# sweep re-lists the app every tick and retries it.
#
# DESTROY_RC / DESTROY_ERR are left set for the sweep's .sweep.json row.
destroy_machine() { # destroy_machine <machine-id> <why>   rc 0 = gone, 1 = still there
  local MID="${1:-}" WHY="${2:-}" OUT AF
  DESTROY_RC=0; DESTROY_ERR=""; DESTROY_GONE=0
  [ -n "$MID" ] || { DESTROY_RC=2; DESTROY_ERR="no machine id"; return 1; }
  # BH-7505: a destroy ends somebody's build, so it needs the lease too. No alert:
  # the run that holds the lease now owns the machine, and the sweep retries.
  if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
    DESTROY_RC=99; DESTROY_ERR="project lease lost"
    say "destroy $MID skipped: the project lease is lost ($WHY)"
    return 1
  fi
  OUT=$(timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force 2>&1); DESTROY_RC=$?
  if [ "$DESTROY_RC" = 0 ]; then say "destroyed $MID ($WHY)"; return 0; fi
  case "$OUT" in
    *"was not found in app"*|*"not found"*|*"Could not find"*)
      DESTROY_GONE=1; say "destroy $MID: already gone ($WHY)"; DESTROY_RC=0; return 0 ;;
  esac
  # rc 124 is `timeout` killing flyctl, and flyctl then prints nothing at all —
  # an empty error body would read as "no reason given" rather than as the one
  # reason we actually know.
  [ "$DESTROY_RC" = 124 ] && OUT="timeout after 60s"
  DESTROY_ERR=$(printf '%s' "$OUT" | tr '\n\r\t' '   ' | cut -c1-300)
  say "destroy $MID FAILED rc=$DESTROY_RC: $DESTROY_ERR ($WHY)"
  AF="$HARNESS/flags/alerted-pool-destroy-$P-$MID-$(date -u +%Y%m%d)"
  if [ ! -f "$AF" ]; then
    mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$AF" 2>/dev/null
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] machine destroy $MID FAILED rc=$DESTROY_RC: $DESTROY_ERR — still in $APP; the sweep retries it next tick"
  fi
  return 1
}
# <<< machine destroy

# >>> pool cost rows (2026-09-14)
# THE MACHINE'S BILL, LANDED EVEN WHEN THE MACHINE DID NOT (2026-09-14).
# fly/builder-runner.sh mirrors a live machine's logs/cost.csv into cost_rows
# every COST_ROWS_PUSH_S seconds and once more at every terminal path. This is
# the backstop for the one case that loop cannot cover: a machine SIGKILLed,
# OOM'd or stopped between its last push and its RESULT. The reap has already
# copied that build's cost.csv onto the hub (agent-call.sh tees every row into
# the build dir as it writes it), so the rows exist here — they just need
# sending.
#
# ONE IDENTITY, NEVER THE HUB'S. These rows are pushed under
# pool-<project>-<machine-id>, the exact string fly/entrypoint.sh gave the
# machine, because the PK is (box, row_hash): the same string means the
# machine's own push and this one collapse onto one row, and a different string
# would silently double the pool's bill. The rows are NEVER appended to the
# hub's own logs/cost.csv — that file is the hub's write-ahead log of calls the
# HUB made, and a pool row in it would be counted a second time under box=hub by
# the hub's own 10-minute mirror.
#
# Cursor lives in the build dir, so a re-reap of the same directory sends
# nothing and a partial push resumes. Fail-open: every path returns 0, and the
# dup count in the log line is the evidence that the machine's own loop worked.
push_pool_cost_rows() { # push_pool_cost_rows <build-dir> <box>
  local d="${1:-}" box="${2:-}" out
  [ -s "$d/cost.csv" ] && [ -n "$box" ] || return 0
  [ -x "$HARNESS/bin/cost-rows-push.sh" ] || return 0
  out=$(timeout "${COST_ROWS_REAP_TIMEOUT_S:-120}" "$HARNESS/bin/cost-rows-push.sh" \
          --box "$box" --csv "$d/cost.csv" --cursor "$d/.cost-rows.cursor" 2>/dev/null) || true
  say "cost rows: ${out:-push produced no answer} for $box"
  return 0
}
# <<< pool cost rows
# >>> fly cost row (BH-3989)
# The machine's own seconds for this job, as ONE infra row in the build dir's
# cost.csv, so the push_pool_cost_rows call right after it carries the row to
# cost_rows under pool-<p>-<mid>. Start is the job's spawned_at, end is this
# tick, or the listing's updated_at for a machine that is no longer running;
# size comes from the live listing only (unusable listing = unpriced).
# job_id is the build's own, read from its cost.csv by header name, or empty.
# Once per (mid, key, spawned_at) via state/fly-cost/ledger.tsv. Returns 0.
pool_fly_cost_row() {
  local kind="" cpus="" mem="" mst="" mup="" end e s0 job="" out rc word
  command -v fly_cost_row_once >/dev/null 2>&1 || return 0
  if [ -z "${SPAT:-}" ]; then say "fly cost row: skipped:no-spawned-at $MID $KEY"; return 0; fi
  if [ "${LIST_OK:-0}" = 1 ] && [ -s "${LISTING:-}" ]; then
    read -r kind cpus mem mst mup < <(jq -r --arg m "$MID" \
      '.[]|select(.id==$m)|"\(.config.guest.cpu_kind // "-") \(.config.guest.cpus // "-") \(.config.guest.memory_mb // "-") \(.state // "-") \(.updated_at // "-")"' \
      "$LISTING" 2>/dev/null | head -1)
    [ "$kind" = - ] && kind=""; [ "$cpus" = - ] && cpus=""; [ "$mem" = - ] && mem=""
  fi
  # A machine that is no longer running stopped at its listing's updated_at
  # (BH-7719): bill to then, not to this tick, when that time is after the
  # spawn and not in the future. Anything else ends now, as before.
  end=$(date -u +%s)
  case "${mst:-}" in
    stopped|suspended|failed|destroyed)
      e=""; [ -n "${mup:-}" ] && { e=$(date -u -d "${mup:-}" +%s 2>/dev/null) || e=""; }
      s0=""; [ -n "${SPAT:-}" ] && { s0=$(date -u -d "$SPAT" +%s 2>/dev/null) || s0=""; }
      [[ "$e" =~ ^[0-9]+$ ]] && [[ "$s0" =~ ^[0-9]+$ ]] && [ "$e" -gt "$s0" ] && [ "$e" -le "$end" ] && end="$e" ;;
  esac
  [ -s "$LOCAL/cost.csv" ] && job=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="job_id") c=i; next}
    c && $c!=""{j=$c} END{print j}' "$LOCAL/cost.csv" 2>/dev/null)
  out=$(fly_cost_row_once "$LOCAL/cost.csv" "$HARNESS/state/fly-cost/ledger.tsv" "$P" "pool-$P-$MID" \
        "$MID" "$KEY" "$job" "$(basename "$LOCAL")" "$SPAT" "$end" \
        "$kind" "$cpus" "$mem" "$HARNESS/catalog/fly-prices.json"); rc=$?
  case "$rc" in 0) word=written ;; 3) word=already ;; 2) word=skipped:bad-interval ;; *) word="skipped:rc$rc" ;; esac
  say "fly cost row: $word $MID $KEY${out:+ ${out%% *}s \$${out##* }}"
  return 0
}
# <<< fly cost row
# >>> preplan relay (the operator, 2026-09-14)
# A pool builder has NO hub state: it runs bin/run-build.sh out of a baked image
# against a tarball of bin/, so plans/<project>-<KEY>/ — where bin/run-preplan.sh
# leaves the plan it already paid for — does not exist on it. Without this push,
# speculative pre-planning would be a hub-only optimisation and every pool build
# (which is every build on project-5 and project-4) would re-plan from scratch.
#
# It rides the SAME console push as the env bundle and job.json rather than the
# queue row, because the row's meta column is capped at 4000 chars in the worker
# and a plan is an order of magnitude longer — a truncated plan is the one
# failure mode worse than no plan at all.
#
# `key` is written LAST and it is the gate: bin/lib/preplan-lib.sh:preplan_find
# refuses a relay directory whose key does not match the job, so a half-pushed
# pre-plan is simply not adopted instead of being adopted in pieces. That same
# check is what stops a REUSED machine (next_job_or_destroy below) from handing
# job B the plan for job A — the TK-493 shape, where a reused machine's leftover
# artifacts were relayed home under the wrong ticket.
#
# THE HUB HAS NO plans/ DIRECTORY (BH-658, 2026-09-17). This function runs on
# the hub, and the hub is forbidden to pre-plan (bin/run-preplan.sh's
# hub-no-build block via bin/lib/hub-box.sh), so the local read below has ALWAYS
# missed here: every Fly build re-planned from scratch and no log line said so.
# The box that wrote the plan now publishes it to the coordination DB, and this
# is where it is read back — into a temp dir of exactly the same shape, so the
# push loop underneath is unchanged and one layout means one set of bugs.
#
# Never fatal: every path returns 0. A failed relay costs one PLAN stage — and
# now SAYS so, because a relay that quietly ships nothing is indistinguishable
# from a relay that was never called.
push_preplan() { # push_preplan <machine-id> <key>
  local mid="${1:-}" k="${2:-}" d="$HARNESS/plans/$P-${2:-}" kf f tmp="" src=local rc why
  command -v preplan_speculative >/dev/null 2>&1 || return 0
  [ "$(preplan_speculative "$HARNESS")" = 1 ] || return 0
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  if [ ! -s "$d/plan.md" ]; then
    command -v preplan_fetch >/dev/null 2>&1 \
      || { say "no pre-plan for $k (db: no client on this host) — builder will PREPLAN_MISS"; return 0; }
    tmp=$(mktemp -d /tmp/preplan-relay.XXXXXX) \
      || { say "no pre-plan for $k (relay: mktemp failed) — builder will PREPLAN_MISS"; return 0; }
    preplan_fetch "$HARNESS" "$P" "$k" "$tmp"; rc=$?
    if [ "$rc" != 0 ]; then
      case "$rc" in 1) why=miss ;; *) why=outage ;; esac
      say "no pre-plan for $k (db: $why) — builder will PREPLAN_MISS"
      case "$tmp" in /tmp/preplan-relay.*) rm -rf "$tmp" ;; esac
      return 0
    fi
    d="$tmp"; src=db
  fi
  # A `once` block, so every exit from the push has the SAME cleanup after it:
  # the fetched directory is temporary and must not outlive the attempt.
  while :; do
    mput "$mid" "$d/plan.md" /run/harness/preplan/plan.md || break
    for f in base-sha planned-files.txt ticket-fp plan-thread-at; do
      [ -s "$d/$f" ] || continue
      mput "$mid" "$d/$f" "/run/harness/preplan/$f" || break 2
    done
    kf=$(mktemp) || break
    printf '%s\n' "$k" > "$kf"
    mput "$mid" "$kf" /run/harness/preplan/key && say "relayed pre-plan for $k to $mid (source: $src)"
    rm -f "$kf"
    break
  done
  case "$tmp" in /tmp/preplan-relay.*) rm -rf "$tmp" ;; esac
  return 0
}
# <<< preplan relay
# >>> reroute relay (BH-584)
# The same reason as the pre-plan above, for a different file: a pool machine has
# no hub state, so the record bin/overlap-guard.sh just wrote — "this ticket's
# test cases go to <per-ticket>, a sibling is holding <shared>" — has to ride
# with the job or the builder never sees it. Every project-5 and project-4 build is a
# pool build, so without this the reroute would be a hub-only rule.
#
# NOT gated on preplan_speculative: the record exists whenever the guard
# rerouted, with or without a speculative pre-plan, and dropping it on boxes
# with pre-planning off would send them to build on the file they were routed
# away from.
#
# Never fatal: every path returns 0. A failed relay costs the shared-file
# conflict this ticket would have had before the reroute existed.
push_reroute() { # push_reroute <machine-id> <key>
  local mid="${1:-}" k="${2:-}" rec
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  command -v th_record_path >/dev/null 2>&1 || return 0
  rec=$(th_record_path "$HARNESS" "$P" "$k")
  [ -r "$rec" ] && [ -s "$rec" ] || return 0
  if mput "$mid" "$rec" "$(th_relay_path "$P" "$k")"; then
    say "relayed test reroute for $k to $mid"
  else
    say "test reroute relay for $k to $mid failed — machine builds without it"
  fi
  return 0
}
# <<< reroute relay
# >>> build-note relay (policy, the operator 2026-09-24)
# The same reason again: bin/blocked-resolver.sh carries a note to the NEXT build
# of a ticket in state/build-notes/<project>/<key>.md (an adjudication ruling,
# or, since the CI-repair park, the failing-CI evidence of an automatic narrower
# re-plan), and a pool machine has no hub state. Relayed beside the job to
# build-note-<project>-<key>.md in the relay dir, where bin/run-build.sh's plan
# stage looks first. CONSUMED ON A GOOD PUSH (renamed .relayed-<epoch>), so a
# later, unrelated build of the key never inherits it — the same read-once rule
# the hub build applies with its mv. Never fatal: a failed push costs the brief,
# never the build, and the note stays for the next machine.
#
# BH-5003: the note is also the ledger row build_note/"$P $k"
# (bin/lib/build-note-db.sh), which a watcher box consumes directly. A row a
# box already used (`consumed`/`relayed`, and its detail is THIS file: bn_used)
# retires the hub file without a push;
# a good push marks a still-`pending` row `relayed`. Fail-open: no lib, the
# knob at 0, or an outage relays exactly as before.
# shellcheck source=bin/lib/build-note-db.sh
{ [ -r "$HARNESS/bin/lib/build-note-db.sh" ] && . "$HARNESS/bin/lib/build-note-db.sh"; } || true
# push_build_note_file <machine-id> <key> -> the hub note to relay, or nothing.
# A note the ledger says was already used is retired here, never relayed.
# build_note_relayed <machine-id> <key> <file> consumes it after a good relay.
# Split out for the seed (BH-7430): a seeded note is consumed only after
# `fly machine run` answers, so a launch that fails keeps it for the next one.
push_build_note_file() {
  local mid="${1:-}" k="${2:-}" f st=""
  f="$HARNESS/state/build-notes/$P/$k.md"
  [ -s "$f" ] || return 0
  command -v bn_used >/dev/null 2>&1 && st=$(bn_used "$P" "$k" "$f" 2>/dev/null)
  case "$st" in
    consumed|relayed)
      mv -f "$f" "$f.relayed-$(date +%s)" 2>/dev/null || rm -f "$f"
      say "the carried build note for $k was already used on another box (ledger row $st) — retired, not relayed to $mid"
      return 0 ;;
  esac
  printf '%s\n' "$f"
}
build_note_relayed() {
  local mid="${1:-}" k="${2:-}" f="${3:-}"
  mv -f "$f" "$f.relayed-$(date +%s)" 2>/dev/null || rm -f "$f"
  say "relayed the carried build note for $k to $mid"
  if command -v bn_mark >/dev/null 2>&1; then bn_mark "$P" "$k" relayed >/dev/null 2>&1 || true; fi
}
push_build_note() { # push_build_note <machine-id> <key>
  local mid="${1:-}" k="${2:-}" f
  [ -n "$mid" ] && [ -n "$k" ] || return 0
  f=$(push_build_note_file "$mid" "$k")
  [ -n "$f" ] || return 0
  if mput "$mid" "$f" "/run/harness/build-note-$P-$k.md"; then
    build_note_relayed "$mid" "$k" "$f"
  else
    say "$mid: build-note push for $k FAILED — kept for the next machine; this build plans without it"
  fi
  return 0
}
# <<< build-note relay
# >>> bake-evidence relay (BH-6259)
# The hub's pool-bake evidence (the `bake phases` lines of
# logs/fleet-propagate.log and the step timings of logs/fly-image-build/) exists
# only on the hub, and a cromford ticket about a slow bake is planned on a
# pool machine. bin/bake-evidence.sh prints a bounded digest of it, copied to
# /data/harness/state/bake-evidence.txt at dispatch. Only for the harness's own
# project: the pool's repo (POOL_SLUG, from bin/fleet-conf.sh) equals
# HARNESS_REPO (bin/lib/deployment.sh), so no project name is written here. Never
# fatal: no digest or a failed push costs the evidence, never the build.
push_bake_evidence() { # push_bake_evidence <machine-id>
  local mid="${1:-}" tmp rc=0 hrepo
  [ -n "$mid" ] && [ -n "${POOL_SLUG:-}" ] || return 0
  hrepo=$( . "$HARNESS/bin/lib/deployment.sh" 2>/dev/null && printf '%s' "${HARNESS_REPO:-}" )
  [ -n "$hrepo" ] && [ "${POOL_SLUG,,}" = "${hrepo,,}" ] || return 0
  [ -x "$HARNESS/bin/bake-evidence.sh" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/bake-ev-XXXX") || return 0
  HARNESS="$HARNESS" timeout 20 "$HARNESS/bin/bake-evidence.sh" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ] && [ -s "$tmp" ]; then
    if mput "$mid" "$tmp" /data/harness/state/bake-evidence.txt; then
      say "relayed the hub bake evidence to $mid"
    else
      say "$mid: bake-evidence push FAILED — this build plans without it"
    fi
  fi
  rm -f "$tmp"; return 0
}
# <<< bake-evidence relay

# >>> App-token rotation (the operator, 2026-09-14)
# The hub already walks every live machine once a tick and already knows each
# one's id — so the tick is where a token that is about to die gets replaced, with
# no new loop, no new lock and no extra GitHub call for machines that are fine:
# the machine record carries the expiry the spawn shipped, so "is this one due"
# is a date comparison against a local file.
#
# NEVER FATAL, by construction. Every path returns 0 and every failure leaves the
# machine with the token it already has — which is the state this function exists
# to improve, never to break. A machine whose record has no expiry (it shipped the
# PAT, or it was spawned before this change) is left alone entirely.
#
# THE PUSHED TOKEN MUST BE NEWER THAN THE ONE IT REPLACES, and that test is the
# one that keeps a PAT off the machine: bin/gh-token.sh prints the fleet PAT rather
# than nothing when a mint fails, and a PAT carries no cache expiry, so an expiry
# that did not move forward means no mint happened and nothing is shipped.
rotate_gh_token() { # rotate_gh_token <machine-id> <machine-json>
  local mid="$1" mf="$2" expat exp now left rotat tok newexp nexp tf ghe gapp=hub ninst
  gh_rotate_armed || return 0
  [ -n "$POOL_SLUG" ] || return 0
  expat=$(jq -r '.gh_token_expires_at // ""' "$mf" 2>/dev/null)
  [ -n "$expat" ] || return 0
  exp=$(date -u -d "$expat" +%s 2>/dev/null) || return 0
  now=$(date -u +%s); left=$((exp - now))
  [ "$left" -le "$POOL_GH_TOKEN_ROTATE_BEFORE" ] || return 0
  # Once per 30 min per machine. Without this a machine whose push keeps failing
  # would buy a token every two minutes for the rest of its life.
  rotat=$(jq -r '.gh_token_rotated_at // ""' "$mf" 2>/dev/null)
  if [ -n "$rotat" ]; then
    rotat=$(date -u -d "$rotat" +%s 2>/dev/null) || rotat=0
    [ "$((now - rotat))" -ge "$POOL_GH_TOKEN_ROTATE_EVERY" ] || return 0
  fi
  # The expiry is asked with the SAME --min-life as the token, so both answers
  # come from the same cache row: a stale profile row is never the expiry of a
  # token the hub App answered (#1590 review B2 — rotation stalled on it).
  ghe=$(mktemp 2>/dev/null) || ghe=""
  tok=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>"${ghe:-/dev/null}") || tok=""
  gapp=$(pool_gh_answered "${ghe:-/dev/null}"); [ -z "$ghe" ] || rm -f "$ghe"
  newexp=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$POOL_SLUG" 2>/dev/null) || newexp=""
  nexp=0; [ -n "$newexp" ] && nexp=$(date -u -d "$newexp" +%s 2>/dev/null) || nexp=0
  if [ -z "$tok" ] || [ "$nexp" -le "$exp" ]; then
    say "$mid: no fresher App token for $POOL_SLUG — it keeps the one it has (expires $expat)"
    return 0
  fi
  # The installation that minted it, from the same cache row (same --min-life).
  ninst=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --installation-id "$POOL_SLUG" 2>/dev/null) || ninst=""
  case "$ninst" in *[!0-9]*) ninst="" ;; esac
  tf=$(mktemp /dev/shm/ghtok.XXXX 2>/dev/null) || tf=$(mktemp) || return 0
  ( umask 077; printf '%s\n' "$tok" > "$tf" )
  if mput "$mid" "$tf" /run/harness-env/gh-token; then
    rotate_gh_hint "$mid" "$ninst"
    # BH-5025: the next job on $mid sources global.env, so its GH_TOKEN= follows the file just pushed.
    mexec "$mid" "HARNESS=/data/harness bash -c '. /data/harness/bin/lib/gh-token-live.sh && gh_token_live_sync_env /run/harness-env/global.env'" >/dev/null \
      || say "$mid: pushed a fresh App token but could not sync GH_TOKEN in its global.env — new jobs on it sync at load_env"
    # The record is what carries the 30-minute floor, so a record that did not
    # update says so rather than being reported as a clean rotation: without the
    # stamp the next tick rotates this machine again.
    if jq --arg e "$newexp" --arg r "$(STAMP)" '.gh_token_expires_at=$e | .gh_token_rotated_at=$r' \
         "$mf" > "$mf.tmp" 2>/dev/null && mv "$mf.tmp" "$mf"; then
      say "rotated App token on $mid for $POOL_SLUG (expires $(date -u -d "$newexp" '+%H:%MZ' 2>/dev/null || echo "$newexp")) from the $gapp App, installation ${ninst:-unknown}"  # determinism: ok date-empty-stamp only reached when nexp>exp, which needs a non-empty newexp
    else
      say "$mid: pushed a fresh App token but could not stamp its machine record — the next tick will rotate it again"
    fi
  else
    say "$mid: could not push the rotated App token — it keeps the one it has (expires $expat)"
  fi
  rm -f "$tf" "$mf.tmp"; tok=""
  return 0
}
# rotate_gh_hint <machine-id> <installation-id|""> — THE BUCKET TRAVELS WITH THE
# ROTATED TOKEN TOO (BH-1602). The spawn wrote GH_TOKEN_INSTALLATION_ID into the
# bundle once; a rotation that changed App (builders -> hub retry, or back) left
# the builder's ledger naming the spawn-time installation. The id goes to a file
# of its own, which bin/lib/gh-token-live.sh reads with the token. Not named
# gh-token.*: that prefix is the token. An unknown id ships an EMPTY file, which
# unsets the hint on the builder (flat `app`), never a guessed id. Called only
# after the token itself was pushed, and a failure here is said, never fatal.
rotate_gh_hint() {
  local hf
  hf=$(mktemp /dev/shm/ghinst.XXXX 2>/dev/null) || hf=$(mktemp) || return 0
  ( umask 077; printf '%s\n' "$2" > "$hf" )
  mput "$1" "$hf" /run/harness-env/gh-installation-id \
    || say "$1: pushed a fresh App token but not its installation hint — ledger lines on $1 may name the previous installation"
  rm -f "$hf"
  return 0
}
# <<< App-token rotation

# mq_touch <box> <project> <pr>
#   The merge-queue hand-off over ssh, for a tier-1 APPROVE whose merge_queue
#   row failed. Tried at most twice (one retry) and the last rc returned
#   (BH-1957): this was `2>/dev/null || true`, so an unreachable box swallowed
#   the APPROVE, the log said "sent", and it sat queued nowhere.
mq_touch() {
  local box="$1" p="$2" pr="$3" try rc=1
  for try in 1 2; do
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
      "mkdir -p /root/harness/state/merge-queue/$p; touch /root/harness/state/merge-queue/$p/$pr" \
      2>/dev/null && return 0
    rc=$?
  done
  return "$rc"
}

# >>> pool full push (BH-1041)
# pool_push_full <project> <key> <ticket> <local-dir> <box> <pr-url> <tier>
#   THE SSH FALLBACK, lifted out of the reap so the deferral retry below can
#   reach the same code rather than growing a second copy of it. Everything it
#   does, the reap did in line before this ticket: the ingest-shaped json into
#   the box's state/remote-results, the RESULT/review/plan into the box's own
#   build dir, and then the bookkeeping — hub json removed only because the box
#   copy is now live, RELAYED stamped only because both pushes returned 0, and
#   ONE ALERTS line when they did not.
#   rc 0 pushed and stamped; rc 1 the push failed, hub json kept, alert written.
pool_push_full() {
  local p="$1" k="$2" t="$3" loc="$4" box="$5" pr="$6" tier="$7"
  local bd pay ok=1 art mbd
  bd=$(basename "$loc")
  # The MACHINE's own build dir, which is what the ledger row for this build is
  # named after and therefore the only identity the owning box can dedupe this
  # json against. The hub's `build_dir` above is a different name for the same
  # build and always has been.
  mbd=$(grep -oE '^BUILD_DIR: .*' "$loc/RESULT" 2>/dev/null | sed 's/^BUILD_DIR: //' | head -1)
  pay=$(jq -nc --arg k "$k" --arg t "$t" --arg r "$(head -1 "$loc/RESULT")" \
    --arg pr "$pr" --arg tier "$tier" --arg bd "$bd" --arg mbd "$mbd" --arg ts "$(STAMP)" \
    '{key:$k,ticket_id:$t,result:$r,pr_url:$pr,tier:$tier,build_dir:$bd,machine_build_dir:$mbd,ingested_at:$ts,source:"pool"}')
  # NO -n on the payload ssh: the json rides stdin into cat (medic 2026-07-31).
  ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
    "mkdir -p /root/harness/state/remote-results/$p; cat > /root/harness/state/remote-results/$p/$k.json" \
    <<<"$pay" || ok=0
  for art in RESULT review.md plan.md; do
    [ -s "$loc/$art" ] || continue
    ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
      "mkdir -p /root/harness/builds/$bd; cat > /root/harness/builds/$bd/$art" \
      < "$loc/$art" || ok=0
  done
  if [ "$ok" = 1 ]; then
    rm -f "$HARNESS/state/remote-results/$p/$k.json"
    touch "$loc/RELAYED"
    say "relayed $k result+artifacts to $box (tier=${tier:-?})"
    return 0
  fi
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$p] $k: RELAY to $box FAILED — result parked hub-side in state/remote-results/$p/$k.json + $loc; hand-deliver or re-run the relay"
  say "RELAY FAILED $k to $box — hub json kept"
  return 1
}
# <<< pool full push

# >>> pool relay retry (BH-1041)
# pool_relay_retry — re-ask the ledger about every result this hub PARKED rather
#   than pushed. Runs once per tick, before the reap, inside the per-project
#   flock the tick already holds.
#
#   WHY IT EXISTS. A reap that could not read the ledger now pushes nothing
#   (unknown is not "absent"), which is only safe because this asks again two
#   minutes later. Without it a blink of the coordination DB would strand a
#   finished build hub-side for ever, which is the TK-124 class the row path was
#   built to end.
#
#   BOUNDED BY CONSTRUCTION: one iteration per RELAY_DEFERRED marker on this
#   hub, one ledger read each, no network call for a dir that has none. Nothing
#   waits: a dir the ledger still cannot answer for is silently left for the
#   next tick, and bin/pipeline-health.sh pages if it never resolves.
pool_relay_retry() {
  command -v bd_result_in_ledger >/dev/null 2>&1 || return 0
  command -v job_artifact_feed  >/dev/null 2>&1 || return 0
  local d k t line pr tier rc rbox mbd
  for d in "$HARNESS/builds/pool-$P-"*; do
    [ -f "$d/RELAY_DEFERRED" ] || continue
    # A dir that got its custody some other way (a re-reap, a hand delivery) is
    # done: drop the marker and make no call.
    [ -f "$d/RELAYED" ] && { rm -f "$d/RELAY_DEFERRED"; continue; }
    [ -s "$d/RESULT" ] || continue
    # The reap names the dir pool-<project>-<key>-<ts>; the key is what is left
    # once its own prefix and the timestamp come off. `%-*` takes ONE trailing
    # -field, which is right only because the timestamp is `date +%Y%m%d%H%M`
    # with no hyphen in it (the reap, below). Change that format and this
    # derivation has to change with it — there is no other copy of the key in
    # the parked dir, and the hub json this function reads for ticket_id is
    # itself named by the key.
    k=$(basename "$d"); k=${k#"pool-$P-"}; k=${k%-*}
    [ -n "$k" ] || continue
    line=$(head -1 "$d/RESULT")
    # The parked RESULT still carries the machine's own BUILD_DIR: line, so the
    # retry asks about THIS BUILD's row exactly as the reap did (BH-1041).
    mbd=$(grep -oE '^BUILD_DIR: .*' "$d/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
    bd_result_in_ledger "$P" "$k" "$line" "${mbd:-}"; rc=$?
    case "$rc" in
      0)
        # The row turned up. Custody moved through the ledger exactly as it does
        # on the reap's own row path: the hub json stays (the box has not read
        # the row yet, so this is still the only other copy) and RELAYED marks
        # the close-out checks.
        touch "$d/RELAYED"; rm -f "$d/RELAY_DEFERRED"
        say "$k: the ledger now carries the deferred result — no ssh push; the box pulls it"
        ;;
      1)
        # Answered, and the row is genuinely not there. Push it, once. The
        # marker comes off either way: a failed push leaves the hub json, the
        # RELAY FAILED alert and today's hand-delivery story, and re-trying that
        # every two minutes would page every two minutes without changing it.
        rbox=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || rbox=""
        if [ -z "$rbox" ]; then
          say "$k: the ledger has no row for the deferred result and $P has no tailnet_ip in fleet.conf — still parked hub-side in $d"
          continue
        fi
        t=$(jq -r '.ticket_id // ""' "$HARNESS/state/remote-results/$P/$k.json" 2>/dev/null)
        if command -v result_own_pr_url >/dev/null 2>&1; then
          pr=$(result_own_pr_url "$d/RESULT" || true)
        else
          pr=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$d/RESULT" | head -1)
        fi
        tier=$(grep -oE '^TIER: [12]' "$d/RESULT" | grep -oE '[12]' | head -1)
        pool_push_full "$P" "$k" "${t:-}" "$d" "$rbox" "${pr:-}" "${tier:-}"
        rm -f "$d/RELAY_DEFERRED"
        ;;
      *)
        # Still cannot ask. Nothing is pushed and nothing is said: the reap
        # already wrote the one line this outage gets.
        ;;
    esac
  done
}
# <<< pool relay retry

# >>> pool custody sweep (BH-5006)
# pool_custody_sweep — give every finished pool build on this hub an owner.
#   Three reap paths leave builds/pool-<p>-* with a RESULT and NO custody
#   marker, and nothing ever revisits it: pool_push_full failing at reap, the
#   rc-1 arm of pool_relay_retry above (RELAY_DEFERRED comes off whether or not
#   the push landed), and a project with no tailnet_ip ("parked hub-side").
#   pipeline-health check 4 then counts the dir as "no board close-out" every
#   10 minutes for ever (pool-cromford-BH-4583-202610050404). For a dir
#   older than POOL_CUSTODY_SWEEP_S, oldest RESULT first, one of:
#     SUPERSEDED     a newer exact-key result already has RELAYED or COMMENTED
#                    (no network; bin/lib/closeout-terminal.sh honours it)
#     RELAYED        the ledger carries this build's row
#     one push       the ledger answered and has no row: pool_push_full, once in
#                    the dir's lifetime (RELAY_RETRIED)
#     one page       still no owner after that, or nothing can push it:
#                    CUSTODY_ALERTED, never repeated
#   An unreadable ledger (rc 2+) does nothing: unknown is not absent. BOUNDED:
#   at most POOL_CUSTODY_SWEEP_MAX dirs acted on per tick, one ledger read
#   each. Runs inside the per-project flock, after pool_relay_retry, and a
#   reap writes RESULT and its marker under that same flock, so the sweep
#   never sees a dir half-written.
pool_custody_sweep() {
  [ "$POOL_CUSTODY_SWEEP_S" -gt 0 ] && [ "$POOL_CUSTODY_SWEEP_MAX" -gt 0 ] || return 0
  local now d m mt bn k n nk own line mbd rc rbox t pr tier why ledger=0 acted=0 cands="" ceil
  now=$(date -u +%s)
  # AGED OUT (review of 72b69292): a RESULT older than check 4's ceiling
  # (CLOSEOUT_AGE_OUT_H, default 168h) is not chased. Its box has long since
  # rebuilt or merged that ticket, and a push would close out a stale result.
  # It is marked SUPERSEDED "aged out" with no network, no ledger read and no
  # page, so the sweep and check 4 agree about it.
  ceil=$(closeout_age_out_s 2>/dev/null) || ceil=604800
  case "$ceil" in ''|*[!0-9]*) ceil=604800 ;; esac
  command -v bd_result_in_ledger >/dev/null 2>&1 && command -v job_artifact_feed >/dev/null 2>&1 && ledger=1
  for d in "$HARNESS/builds/pool-$P-"*; do
    [ -s "$d/RESULT" ] || continue
    for m in RELAYED RELAY_DEFERRED COMMENTED DEFERRED TERMINAL SUPERSEDED; do
      [ -f "$d/$m" ] && continue 2
    done
    head -1 "$d/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED' && continue
    mt=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    [ $((now - mt)) -gt "$POOL_CUSTODY_SWEEP_S" ] || continue
    if [ $((now - mt)) -gt "$ceil" ]; then
      printf 'aged out: RESULT %sh old, past CLOSEOUT_AGE_OUT_H (BH-5006 custody sweep)\n' "$(( (now - mt) / 3600 ))" > "$d/SUPERSEDED"
      say "custody: $(basename "$d") aged out ($(( (now - mt) / 3600 ))h), SUPERSEDED with no push or page"
      continue
    fi
    cands="$cands$mt $d
"
  done
  [ -n "$cands" ] || return 0
  while read -r mt d; do
    [ -n "${d:-}" ] || continue
    [ "$acted" -lt "$POOL_CUSTODY_SWEEP_MAX" ] || break
    bn=$(basename "$d")
    # The key, derived exactly as pool_relay_retry derives it (read its comment:
    # the timestamp field has no hyphen, so ONE trailing -field comes off).
    k=${bn#"pool-$P-"}; k=${k%-*}
    [ -n "$k" ] || continue
    own=""
    for n in "$HARNESS/builds/pool-$P-$k-"*; do
      [ -d "$n" ] && [ "$n" != "$d" ] || continue
      nk=$(basename "$n"); nk=${nk#"pool-$P-"}; nk=${nk%-*}
      [ "$nk" = "$k" ] && [ "$n/RESULT" -nt "$d/RESULT" ] || continue
      { [ -f "$n/RELAYED" ] || [ -f "$n/COMMENTED" ]; } && own=$(basename "$n")
    done
    if [ -n "$own" ]; then
      printf 'superseded by %s (BH-5006 custody sweep)\n' "$own" > "$d/SUPERSEDED"
      say "custody: $bn superseded by $own"
      acted=$((acted + 1)); continue
    fi
    [ -f "$d/CUSTODY_ALERTED" ] && continue
    acted=$((acted + 1))
    line=$(head -1 "$d/RESULT")
    why="the ledger could not be asked from this hub (no jobs client)"
    if [ "$ledger" = 1 ]; then
      mbd=$(grep -oE '^BUILD_DIR: .*' "$d/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
      bd_result_in_ledger "$P" "$k" "$line" "${mbd:-}"; rc=$?
      case "$rc" in
        0)
          touch "$d/RELAYED"
          say "custody: $bn — the ledger carries it, stamped RELAYED"
          continue ;;
        1)
          rbox=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || rbox=""
          if [ ! -f "$d/RELAY_RETRIED" ] && [ -n "$rbox" ]; then
            : > "$d/RELAY_RETRIED"
            t=$(jq -r '.ticket_id // ""' "$HARNESS/state/remote-results/$P/$k.json" 2>/dev/null)
            if command -v result_own_pr_url >/dev/null 2>&1; then
              pr=$(result_own_pr_url "$d/RESULT" || true)
            else
              pr=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$d/RESULT" | head -1)
            fi
            tier=$(grep -oE '^TIER: [12]' "$d/RESULT" | grep -oE '[12]' | head -1)
            if pool_push_full "$P" "$k" "${t:-}" "$d" "$rbox" "${pr:-}" "${tier:-}"; then
              say "custody: $bn — the ledger had no row; pushed once to $rbox"
            else
              say "custody: $bn — the ledger had no row and the one push to $rbox failed; paged next tick if nothing else takes it"
            fi
            continue
          fi
          if [ -f "$d/RELAY_RETRIED" ]; then
            why="the ledger still has no row for this build after one ssh push to ${rbox:-a box with no tailnet_ip}"
          else
            why="the ledger has no row for this build and this project has no tailnet_ip to push it to"
          fi ;;
        *)
          say "custody: $bn — ledger unreadable, left for the next tick"
          continue ;;
      esac
    fi
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $bn: finished $(( (now - mt) / 3600 ))h ago (RESULT: $(printf '%s' "$line" | cut -c1-120)) and no box has it — $why. Nothing else retries this dir. Hand-deliver state/remote-results/$P/$k.json + $d, or touch $d/SUPERSEDED if a later build replaced it."
    : > "$d/CUSTODY_ALERTED"
    say "custody: $bn — no owner, paged once"
  done <<CUSTODY
$(printf '%s' "$cands" | sort -n)
CUSTODY
}
# <<< pool custody sweep (BH-5006)

next_job_or_destroy() { # hand this machine the next queued job, or destroy it
  # Reads the REAP loop's own variables (MID, MSTATE, KEY, MF) the way PR_ALERT
  # below reads $KEY — this is the loop's tail, lifted out so BOTH terminal
  # paths can reach it: a reaped RESULT and a reaped BUILD_DEFERRED. A deferral
  # leaves a machine that did nothing at all, so it is the one most worth
  # handing straight on rather than paying ~5 min to spawn its replacement.
  # ---- machine reuse within a burst (2026-08-13) ---------------------------
  # A spawn costs ~5 min (boot + harness sync + env + warm-up). If another job
  # is already queued for this project, hand it to the machine we just reaped
  # instead of destroying it: the runner's idle loop (fly/builder-runner.sh)
  # waits up to 10 min for a new job.json. Reset order matters — clear the
  # canonical RESULT FIRST (or the next tick would reap the OLD result under
  # the NEW key), kill QA strays, then land job.json atomically via tmp+mv.
  # env bundle, harness sync, and the preview snapshot stay: same project,
  # same machine. Everything job-scoped (branch, build dir) is re-derived by
  # run-build.sh per job. Any reuse failure falls back to destroy; the job
  # stays queued for a normal spawn next tick.
  REUSED=0
  # ---- no reuse of a default-token machine (the operator, 2026-09-15 "no reuse") ----
  # The Claude account rides with the MACHINE (see below), so a machine that
  # booted with the default project-6 token would keep spending project-6 on
  # every job it is handed, however many max accounts have headroom. While
  # account routing is armed, such a machine is destroyed at reap instead: the
  # queued job spawns fresh next tick and takes a max lease (~1-2 min of boot
  # per job is the price). A machine that already carries a lease is still
  # reused, and so is every machine when routing is not armed — then there is
  # no better token to boot into. POOL_REUSE_DEFAULT_TOKEN=1 restores the old
  # behaviour for a rollback without touching the routing itself.
  REUSE_OK=1
  if [ "$MSTATE" = "started" ] && [ -z "${MACCT:-}" ] && [ "${POOL_REUSE_DEFAULT_TOKEN:-0}" != 1 ] \
     && command -v pool_account_armed >/dev/null 2>&1 && pool_account_armed >/dev/null 2>&1; then
    REUSE_OK=0
    say "$MID shipped the default token and account routing is armed — destroying instead of reusing (the next spawn takes a max lease)"
  fi
  # ...and no reuse under a lane-failure hold: the next job would meet the same
  # exhausted lane on this machine (2026-09-23). Guarded, because the routing
  # suite sources this function alone.
  if [ "$REUSE_OK" = 1 ] && command -v pool_spawn_held >/dev/null 2>&1 && pool_spawn_held >/dev/null; then
    REUSE_OK=0
    say "$MID: project spawn hold is on (runner lane failed) — destroying instead of reusing"
  fi
  # ...and never reuse the machine whose own account the reap just cooled: its
  # token IS that account. The next spawn takes a fresh lease (BH-1853).
  if [ "$REUSE_OK" = 1 ] && [ "${ACOOLED:-}" = 1 ]; then
    REUSE_OK=0
    say "$MID: its account ${MACCT:-?} just ran out — destroying instead of reusing (the next spawn re-leases)"
  fi
  # ...and never reuse a machine whose GitHub token answered 401 (BH-5025.2).
  if [ "$REUSE_OK" = 1 ] && [ "${TOKFAIL:-0}" = 1 ]; then
    REUSE_OK=0
    say "$MID: its GitHub token answered 401 — destroying instead of reusing"
  fi
  # ...and never reuse a machine whose last build deferred because a build slot
  # was still held on it after the runner's own cleanup (BH-5021). The runner
  # preflight and the BUILDER_EXEC slot gate are the only writers of that
  # wording; the plain box `all N slots busy` does not match. `${LOCAL:-}`
  # because the suites that source this function alone set no LOCAL.
  if [ "$REUSE_OK" = 1 ] && [ -n "${LOCAL:-}" ] && [ -r "${LOCAL:-}/RESULT" ]; then
    case "$(head -1 "$LOCAL/RESULT" 2>/dev/null)" in
      BUILD_DEFERRED*"slot held on this machine"*)
        REUSE_OK=0
        say "$MID: its build deferred on a build slot still held on the machine — destroying instead of reusing" ;;
    esac
  fi
  # ...and never reuse a machine that holds a read token for its ticket's spec
  # repos (BH-6576): the next ticket did not ask for that access.
  if [ "$REUSE_OK" = 1 ] && command -v spec_repos_machine_has >/dev/null 2>&1 && spec_repos_machine_has "$MF"; then
    REUSE_OK=0
    say "$MID carries a read token for $KEY's spec repos — destroying instead of reusing"
  fi
  # ...and never reuse a machine that ran a console preview row (BH-8030): the
  # hub pushed it the Pages token for that row alone.
  case "${KEY:-}" in
    CP-*) if [ "$REUSE_OK" = 1 ]; then
            REUSE_OK=0
            say "$MID ran console preview row $KEY — destroying instead of reusing"
          fi ;;
  esac
  if [ "$MSTATE" = "started" ] && [ "$REUSE_OK" = 1 ]; then
    # Hotfix jobs first when the helper is there, today's mtime order when it is
    # not. The fallback is not defensive noise: tests/pool-account-routing-test.sh
    # extracts THIS FUNCTION ALONE and sources it with nothing else from the
    # file, so a hard dependency on a helper defined 250 lines up makes the reuse
    # loop find no jobs at all and destroy a machine that had work waiting.
    NJLIST=$(ls -tr "$QDIR"/*.json 2>/dev/null)
    command -v hotfix_first >/dev/null 2>&1 && NJLIST=$(hotfix_first $NJLIST)
    for NJ in $NJLIST; do
      # THE TICK BUDGET ENDS THIS SEARCH TOO (hub incident 2026-10-19). Each row
      # below can cost an issue read (spec_repos_load, 5-20 s) BEFORE the spawn
      # gate that knows the budget, so 156 queued rows ran a tick 25 minutes past
      # its 600 s budget with the pool lock held. A spent budget leaves REUSED=0:
      # the machine is destroyed below exactly as when no row fits, and every row
      # stays queued. `command -v` because tests/pool-account-routing-test.sh
      # sources this function alone; POOL_TICK_T0 unset means no budget applies.
      if [ -n "${POOL_TICK_T0:-}" ] && command -v pool_tick_budget_spent >/dev/null 2>&1 && pool_tick_budget_spent; then
        say "$MID: tick budget of ${POOL_TICK_BUDGET_S:-600}s spent — the reuse search stops, the machine is destroyed and its rows stay queued"
        break
      fi
      case "$NJ" in *.failed.json) continue;; esac
      [ -f "$NJ" ] || continue
      NKEY=$(jq -r '.key // ""' "$NJ"); NTICKET=$(jq -r '.ticket_id // ""' "$NJ"); NATT=$(jq -r '.attempt // 0' "$NJ")
      NDEF=$(jq -r '.deferrals // 0' "$NJ" 2>/dev/null); case "$NDEF" in ''|*[!0-9]*) NDEF=0 ;; esac
      NDTH=$(jq -r '.deaths // 0' "$NJ" 2>/dev/null); case "$NDTH" in ''|*[!0-9]*) NDTH=0 ;; esac
      NSB=$(jq -r '.stack_base // ""' "$NJ" 2>/dev/null); case "$NSB" in *[!A-Za-z0-9._/-]*) NSB="" ;; esac
      NHF=$(jq -r '.hotfix // false' "$NJ" 2>/dev/null); case "$NHF" in true) NHF=true ;; *) NHF=false ;; esac
      NFS=$(jq -r '.fresh_spawn // false' "$NJ" 2>/dev/null); case "$NFS" in true) ;; *) NFS=false ;; esac
      [ -n "$NKEY" ] || continue
      # never the key we just reaped (the runner detects new work partly by
      # key change), never a key already running elsewhere in the pool
      [ "$NKEY" = "$KEY" ] && continue
      # ...and never a console preview row (BH-8030): its token is pushed at
      # spawn, so it takes a fresh machine.
      case "$NKEY" in CP-*) continue ;; esac
      # pool_key_live (BH-5001) reads the claim too; the bare grep is the
      # fallback for the suites that source this function alone.
      if command -v pool_key_live >/dev/null 2>&1; then pool_key_live "$NKEY" && continue
      else grep -ls "\"key\": *\"$NKEY\"" "$POOL"/*.json >/dev/null 2>&1 && continue; fi
      # ...and never a hotfix that already deferred on a reused machine: its
      # next attempt is a fresh spawn (BH-5025.2). Before pool_spawn_decision,
      # so a skipped row neither records a spawn nor takes a claim.
      if [ "$NHF" = true ] && [ "$NFS" = true ] && [ "${POOL_HOTFIX_FRESH_AFTER_DEFER:-1}" != 0 ]; then
        say "$NKEY: hotfix deferred on a reused machine last time — left for a fresh spawn (POOL_HOTFIX_FRESH_AFTER_DEFER)"
        continue
      fi
      # ...and never a ticket whose body declares spec repos (BH-6576): this
      # machine has no read token for them. A fresh spawn mints one.
      # The read uses the token the spawn gates read this repo with: the hub's
      # default PAT can 404 on a project repo (see pool_slug_token_arm).
      SPEC_REPOS=""
      if command -v spec_repos_load >/dev/null 2>&1; then
        command -v pool_slug_token_arm >/dev/null 2>&1 && pool_slug_token_arm
        SPEC_REPOS_GH_TOKEN="${POOL_SLUG_TOK:-}" spec_repos_load "${POOL_SLUG:-}" "$NTICKET" 2>>"${LOG:-/dev/null}"
        if [ -n "$SPEC_REPOS" ]; then
          say "$NKEY declares spec repos — left for a fresh spawn"
          continue
        fi
      fi
      # ...and never a row the spawn gate would refuse (BH-1075, review round 1).
      # THIS HANDOFF IS A BUILD, metered exactly like a spawned one — it just
      # skips the ~5 minutes of boot. Without this line every gate in
      # pool_spawn_decision (HOLD, an open PR, a push-rejected terminal, the
      # per-key cap) applies to a machine the pool SPAWNS and to nothing else,
      # so a held or terminal row still reaches a builder through the back door.
      # Guarded with `command -v` for the reason the hotfix_first fallback above
      # states: tests/pool-account-routing-test.sh extracts THIS FUNCTION alone
      # and sources it with nothing else from this file, and a hard dependency
      # on a helper defined 1000 lines up would make the reuse loop find no jobs
      # at all and destroy a machine that had work waiting.
      # ...and never a job the dispatch mode holds (BH-6350): the spawn loop's
      # one tick line names it, so nothing is said here.
      if command -v dm_job_admit >/dev/null 2>&1 && ! dm_job_admit "$NJ"; then continue; fi
      # BH-7519: a handoff starts a build, which is a spend, so it needs the
      # project lease like a spawn does. Before the cap record and the claim:
      # nothing is taken yet, so a lost lease leaves every row queued, and
      # REUSED=0 destroys the machine (destroy_machine fences too; the sweep
      # retries it).
      if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
        say "$MID: the project lease is lost — no handoff of $NKEY, the rows stay queued"
        break
      fi
      if command -v pool_spawn_decision >/dev/null 2>&1; then
        if ! pool_spawn_decision "$NJ" "$NKEY" "$NTICKET"; then
          # BH-7421: the gate answered "budget spent" (it said so once already):
          # end the search like the main walk does, no more rows are read.
          [ -n "${_POOL_BUDGET_SAID:-}" ] && break
          continue
        fi
        # AND IT COUNTS (review round 2, Important-2). The gate above CHECKS the
        # per-key cap on this path and, until this line, nothing ever RECORDED
        # against it: only spawn_one appended to .spawns. A key whose builds
        # keep deferring on a non-push reason is requeued by the reap and handed
        # to the next reaped machine, build after build, with the ledger frozen
        # — so "at most N pool builds per key per 24h regardless of outcome"
        # counted cold spawns only, while this path is a BUILD metered exactly
        # like one (the comment four lines up says so). Recorded HERE, before
        # the mexec that starts it, on spawn_one's own rule: every entry counts
        # regardless of outcome, because a cap that only counts the attempts
        # that worked cannot bound a loop of attempts that do not. RB-* and RR-*
        # rows are exempt from the cap on both paths, so they record nothing here.
        # NHANDOFFTS (BH-1279) carries the recorded line onto $MF below, exactly
        # as SPAWNCAPTS does in spawn_one, so a REFUSED claim on THIS machine's
        # next reap can be un-recorded too.
        NHANDOFFTS=""
        case "$NKEY" in RB-*|RR-*|CP-*) ;; *) command -v pool_spawn_cap_record >/dev/null 2>&1 && NHANDOFFTS=$(pool_spawn_cap_record "$NKEY" "$MID"); esac
      fi
      # THE CLAIM COMES BEFORE THE HANDOFF (BH-1026.3), for the same reason it
      # comes before a spawn: this is a BUILD, metered exactly like a spawned one
      # (the comment 30 lines up says so), so the row's compare-and-swap is what
      # stops two machines taking one key. It passes the MACHINE — unlike the
      # spawn path, the id is known before the push, and a claimed row that names
      # the machine is what makes "is this key building, and where" answerable
      # without an ssh. A refusal moves to the next queued job rather than
      # destroying this machine: another job may still be waiting for it.
      # `command -v` guarded like every other helper in this function — two
      # suites source it alone.
      if [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_claim >/dev/null 2>&1; then
        if ! queue_claim "$P" fly "$NKEY" "$MID" >/dev/null 2>&1; then
          say "$NKEY: the queue row refused this claim — not handing it to $MID"
          continue
        fi
      fi
      # AND EVERY EXIT BELOW HANDS IT BACK. The claim is won from here on, and
      # under the flag $NJ lives in this tick's scratch directory — it vanishes
      # with the tick, so the ROW is the only thing that can re-offer this key.
      # Left claimed, it is a build in flight that nothing is running until
      # bin/jobs-watchdog.sh's 6h stale-claim sweep. Written inline rather than
      # through pool_unclaim because tests/pool-account-routing-test.sh and
      # tests/hotfix-cap-exempt-test.sh source THIS FUNCTION ALONE.
      # pkill patterns are bracketed so they don't match mexec's own shell.
      # NO BUILD SLOT RIDES INTO THE NEXT JOB (BH-5021): bin/pool-slot-clean.sh
      # kills whatever still holds a build-slot lock and answers one SLOTCLEAN
      # line. `held` means the kill did not free it, so the machine is destroyed
      # instead of reused, on the same path as a cleanup that failed. An empty
      # answer, or `absent` from a machine whose tarball predates the script,
      # reuses as before: the runner's own preflight is the backstop there.
      SLOTANS=""
      if ! SLOTANS=$(mexec "$MID" "rm -f /run/harness/RESULT; rm -rf /run/harness/preplan; rm -f /run/harness/test-reroute-*; pkill -f '[p]laywright' 2>/dev/null; pkill -f '[c]hromium' 2>/dev/null; if [ -x /data/harness/bin/pool-slot-clean.sh ]; then /data/harness/bin/pool-slot-clean.sh 2>/dev/null; else echo 'SLOTCLEAN absent'; fi; true"); then
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "machine $MID could not be cleaned for the handoff" >/dev/null 2>&1 || true; }
        break
      fi
      SLOTANS=$(grep -m1 '^SLOTCLEAN ' <<<"$SLOTANS" | tr -d '\r')
      case "$SLOTANS" in
        "SLOTCLEAN held"*)
          say "$MID: build slot still held after cleanup (${SLOTANS#SLOTCLEAN held }) — destroying instead of reusing"
          [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
            && { queue_release "$P" "$NKEY" "machine $MID still held a build slot after cleanup" >/dev/null 2>&1 || true; }
          # ...and the handoff recorded above never started a build.
          [ -n "${NHANDOFFTS:-}" ] && command -v pool_spawn_cap_unrecord >/dev/null 2>&1 \
            && pool_spawn_cap_unrecord "$NKEY" "$NHANDOFFTS"
          break ;;
        "SLOTCLEAN ok cleaned="*)
          say "$MID: killed a stray build-slot holder before the handoff (${SLOTANS#SLOTCLEAN ok }) — reusing" ;;
      esac
      if mput "$MID" "$NJ" /run/harness/job.json.next \
         && mexec "$MID" "mv /run/harness/job.json.next /run/harness/job.json" >/dev/null; then
        rm -f "$NJ"
        # The token rides with the MACHINE, not with the job: a reused machine keeps
        # the credential it booted with, so dropping its expiry here would make the
        # tick blind to a rotation that is due — which is exactly the long-running
        # machine this whole change is about.
        # The Claude account rides with the MACHINE too, and for a stronger reason
        # than the GitHub token: the account's token is already in the bundle on
        # the machine's tmpfs and its lease is already counted, so dropping the
        # name here would leave a lease nothing can attribute and a reap that
        # cannot cool the account down when it refuses.
        jq -nc --arg m "$MID" --arg k "$NKEY" --arg t "$NTICKET" --argjson a "$NATT" --argjson d "$NDEF" --argjson x "$NDTH" --arg ts "$(STAMP)" --arg prev "$KEY" --arg sb "$NSB" --arg hf "$NHF" --arg ge "${GHEXP:-}" --arg gr "${GHROT:-}" --arg aa "${MACCT:-}" --arg sct "${NHANDOFFTS:-}" \
          '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts,reused_from:$prev}
           + (if $sb == "" then {} else {stack_base:$sb} end)
           + (if $hf == "true" then {hotfix:true} else {} end)
           + (if $ge == "" then {} else {gh_token_expires_at:$ge} end)
           + (if $gr == "" then {} else {gh_token_rotated_at:$gr} end)
           + (if $aa == "" then {} else {auth_account:$aa} end)
           + (if $sct == "" then {} else {spawn_cap_ts:$sct} end)' > "$MF"
        # >>> machines rows (BH-1035)
        # Record the reuse in the machine registry. Guarded because this
        # function is sourced alone by some pool tests.
        #
        # THE IMAGE FIELD IS EMPTY HERE ON PURPOSE (issue §4). `IMAGE` is first
        # assigned ~900 lines down, in the SPAWN half of the tick, and this
        # function runs from the REAP loop above it — under `set -u` naming it
        # here killed the whole tick with `IMAGE: unbound variable`, after the
        # queue file was consumed and the machine json rewritten but before the
        # reuse was pushed, logged or beaten. A reused machine is still running
        # the image it booted with, which the row already carries from its
        # spawn, so the empty string is the honest value, not a placeholder.
        command -v machines_row >/dev/null 2>&1 && machines_row machine_put "$P" "$APP" "$MID" pool "$NKEY" "$NTICKET" "${MACCT:-}" "" started
        # <<< machines rows
        push_preplan "$MID" "$NKEY"
        push_reroute "$MID" "$NKEY"
        push_build_note "$MID" "$NKEY"
        push_bake_evidence "$MID"
        # Flag-off only: under the flag this claim ran above the push, as a gate.
        [ "${ROWS_ONLY:-0}" = 1 ] || \
          { command -v queue_claim >/dev/null 2>&1 && queue_claim "$P" fly "$NKEY" >/dev/null 2>&1; }
        say "reused $MID for $NKEY (was $KEY)"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$NKEY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_reused"}')" >/dev/null 2>&1 || true
        REUSED=1
      else
        say "reuse push FAILED to $MID for $NKEY — destroying, job stays queued"
        # ...and under the flag "stays queued" is only true if the row goes back.
        [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_release >/dev/null 2>&1 \
          && { queue_release "$P" "$NKEY" "reuse push to $MID failed" >/dev/null 2>&1 || true; }
      fi
      break
    done
  fi
  # BH-7519: on a lane-run machine the reap's results (the parked
  # state/remote-results record, the build dir, the closed queue row's files) exist
  # only here until a write-back carries them home. Post them before the machine
  # is destroyed or handed on: a machine that stops hard after this point has
  # already left the result with the hub. No-op on the hub; fail-open (the final
  # write-back retries).
  command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "reap ${KEY:-?}"
  if [ "$REUSED" = 0 ]; then
    # `command -v` because tests/pool-account-routing-test.sh and
    # tests/hotfix-cap-exempt-test.sh source THIS FUNCTION ALONE, with nothing
    # else from the file: a hard dependency on a helper defined 200 lines up is
    # the same trap the hotfix fallback above exists for.
    if command -v destroy_machine >/dev/null 2>&1; then destroy_machine "$MID" "reaped after $KEY"; else timeout 60 "$FLY" machine destroy "$MID" -a "$APP" --force >/dev/null 2>&1; fi
    # The file goes whatever the destroy answered: a reaped RESULT must still
    # close its row and free its account. The machine is not lost — the sweep
    # re-lists the app every tick and destroys it once it stops.
    rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.puterr"
    # >>> machines rows (BH-1035)
    # Close the registry row using the actual destroy outcome. `command -v` for
    # the same reason the destroy above has it: the two suites that source THIS
    # FUNCTION ALONE define none of the helpers, and an unguarded call there is
    # a `command not found` on stderr of a path that is meant to be silent.
    command -v machines_row_close >/dev/null 2>&1 && machines_row_close "$MID"
    # <<< machines rows
    # The machine is gone, so its account is free — released HERE rather than left
    # to the TTL, because an account that still looks busy is an account the next
    # launch ranks worse than it is. A reused machine keeps its lease: it is still
    # building, just something else.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
  fi
  # THE STAMP IS THE LAST STEP (BH-7429). A record stamped reaped is a record the
  # next tick cannot read; stamped earlier, a tick that died before the end left a
  # finished build with no record and a stopped machine ssh cannot reach, and the
  # BH-2643 row path requeued it.
  if [ "${RECSTAMP:-0}" = 1 ]; then
    RECSTAMP=0
    pool_record_reaped "$P" "$KEY" "$MID" "${RECINFO%%$'\t'*}" \
      || say "build record for $KEY not stamped reaped — the unread retention rule deletes it"
  fi
}

# >>> pool listing (BH-660)
# ONE LISTING PER TICK, and it answers two questions the script used to ask one
# machine at a time or not at all: "is this tracked machine still alive" (a
# `machine status` call per machine, which is where a machine Fly no longer
# returns has to error CLEANLY for the job to be requeued) and "what else is
# sitting in this app" (nothing asked that before — a machine with no tracking
# file was invisible for ever).
#
# FAIL-OPEN, because an unusable listing is not an empty pool. A `[]` answer
# beside tracking files is AMBIGUOUS — it is also what every existing pool
# fixture's flyctl stub returns while a live machine is on file — and reading it
# as "everything is gone" would requeue every running build on one flaky call.
# Unusable means: fall back to the per-machine `machine status` this loop has
# always used, and skip the sweep entirely rather than sweep on a guess.
LISTING=""; LIST_OK=0; LIST_WHY=""
if [ -n "${POOL_APP:-}" ]; then
  LISTING=$(mktemp "${TMPDIR:-/tmp}/pool-listing.XXXXXX") || LISTING=""
fi
if [ -n "$LISTING" ]; then
  trap 'rm -f -- "$FLY" "$LISTING" "$LISTING.err" "$LISTING.rows"; [ -n "${RQ:-}" ] && rm -rf -- "$RQ"; command -v pp_release >/dev/null 2>&1 && pp_release; true' EXIT
  if timeout 30 "$FLY" machines list -a "$APP" --json > "$LISTING" 2>"$LISTING.err"; then
    if jq -e 'type=="array"' "$LISTING" >/dev/null 2>&1; then
      LIST_OK=1
    else
      LIST_WHY="flyctl did not print a machine array: $(head -c 120 "$LISTING" 2>/dev/null | tr '\n\r\t' '   ')"
    fi
  else
    LIST_WHY=$(head -1 "$LISTING.err" 2>/dev/null | cut -c1-120)
    [ -n "$LIST_WHY" ] || LIST_WHY="machines list exited non-zero with no error text"
  fi
  if [ "$LIST_OK" = 1 ] && [ "$(jq -r 'length' "$LISTING" 2>/dev/null)" = 0 ] \
     && ls "$POOL"/*.json >/dev/null 2>&1; then
    LIST_OK=0; LIST_WHY=empty-with-tracked
  fi
  if [ "$LIST_OK" = 0 ]; then
    say "machines list unusable (${LIST_WHY:-no answer}) — liveness falls back to machine status, sweep skipped"
    # A listing that fails every tick is a sweep that is silently dark, which is
    # the exact failure this change exists to end. Once per project per day.
    LAF="$HARNESS/flags/alerted-pool-listing-$P-$(date -u +%Y%m%d)"
    if [ ! -f "$LAF" ]; then
      mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$LAF" 2>/dev/null
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] machines list for $APP unusable (${LIST_WHY:-no answer}) — dead-machine sweep skipped; stopped machines are not being reclaimed until it answers"
    fi
  fi
fi
# <<< pool listing

# Per-key spawn cap for this tick (BH-1075). LOADED BEFORE THE REAP, not beside
# the spawn loop where it started (review round 2, Important-1): the reap's
# reuse handoff (next_job_or_destroy) runs the same pool_spawn_decision, and
# with POOL_SPAWN_CAP still unset there the handoff judged every row against the
# hardcoded fallback 2/86400 whatever the operator had put in D1 — so a cap
# raised to 5 refused a row at 2, deleted its queue file and PAGED
# POOL_DEFER_TO_HUMAN for a key under the operator's own cap, and a cap lowered
# to 1 was honoured by the spawn loop and ignored by the handoff. One knob, one
# answer, both paths.
pool_spawn_cap_load
# BH-5001: ONE read of this project's pool_* rows for the whole tick, in this
# shell so every reader below (and every $( ... ) under it) shares it. No
# answer is one line, and every reader then uses its state/pool/ file.
if command -v psr_on >/dev/null 2>&1 && psr_on; then
  psr_load "$P" "$(( $(date +%s) - ${POOL_SPAWN_CAP_WINDOW:-86400} ))" || psr_fallback_note "$P" "pool-state read"
fi

# Results this hub PARKED on an earlier tick because the ledger could not be
# asked. Re-asked here, once per tick, before anything is reaped — a deferral
# that nothing re-asks is a stranded close-out (BH-1041).
pool_relay_retry
# Finished builds no reap path took custody of (BH-5006), right after the retry.
pool_custody_sweep
  # >>> machines rows (BH-1035)
  # Refresh the machine registry with this tick listing before the reap mutates
  # any state. Fail-open: a broken worker leaves the file lifecycle unchanged.
  # INSIDE the listing block and BEFORE the REAP on purpose: a machine the reap
  # destroys this tick has to end `destroyed`, and an observe running after it
  # would re-stamp the row live with a listing read before the destroy.
  # `LIST_OK=0` — rc≠0, non-array, empty-beside-tracked — sends nothing at all,
  # because an unusable listing is not an empty pool.
  if [ "$LIST_OK" = 1 ]; then
    machines_row machines_observe "$P" "$APP" "$LISTING"
  fi
  # <<< machines rows

# ---------- REAP ----------
# BH-7429: read each finished machine's build record from the jobs API before
# any ssh. Lane knob POOL_RECORD_READ (default 0; project-6-os is seeded 1).
# lane_knob reads the env value of the same name, so nothing is assigned first.
POOL_RECORD_READ=$( { command -v lane_knob && command -v pool_record_get; } >/dev/null 2>&1 \
  && lane_knob fly-pool POOL_RECORD_READ "$P")
[ "$POOL_RECORD_READ" = 1 ] || POOL_RECORD_READ=0
REAPED_IDS=" "   # machines this tick's REAP owns; the sweep below never touches one
for MF in "$POOL"/*.json; do
  [ -f "$MF" ] || continue
  # BH-7475: a replaced code file or a tick past its max age stops at this row.
  command -v pts_stop_due >/dev/null 2>&1 && pts_stop_due && break
  MID=$(jq -r '.machine' "$MF"); KEY=$(jq -r '.key' "$MF"); TICKET=$(jq -r '.ticket_id' "$MF")
  # Claimed for the whole tick, not just while the file exists: the reap DELETES
  # the file on every terminal path, and without this the sweep would see the
  # machine it just destroyed, still in the listing this tick read before the
  # reap ran, and destroy it a second time.
  REAPED_IDS="$REAPED_IDS$MID "
  ATT=$(jq -r '.attempt // 0' "$MF"); BD=$(jq -r '.build_dir // ""' "$MF")
  # DEATHS ARE COUNTED, NOT INFERRED (2026-09-13). `attempt` is whatever the
  # ENQUEUER put on the row: bin/blocked-resolver.sh and the 09-13 rebuild wave
  # both enqueue at attempt>=1, and the old rule (NEXT=ATT+1 >= 2) then read the
  # FIRST death of a brand-new build as its second and parked a ticket that had
  # never failed once. `deaths` is written here and nowhere else, so it counts
  # only deaths this loop actually OBSERVED. Absent (a machine json from before
  # this change) = 0, which costs at most one extra attempt and never an
  # unearned park.
  DTHS=$(jq -r '.deaths // 0' "$MF" 2>/dev/null); case "$DTHS" in ''|*[!0-9]*) DTHS=0 ;; esac
  # DEATHS AND STAND-DOWNS ARE DIFFERENT COUNTERS (2026-09-11). `attempt` is
  # deaths — the liveness path below parks on it at 2 ("died twice"). Spending
  # it on deferrals made ONE real death after two refusals read as two deaths
  # and parked a ticket that had never actually failed. `deferrals` rides
  # beside it through the pool json, the queue file and the row's meta.
  DEFC=$(jq -r '.deferrals // 0' "$MF" 2>/dev/null); case "$DEFC" in ''|*[!0-9]*) DEFC=0 ;; esac
  # The parent branch a STACKED child build is being cut from (2026-09-14).
  # It rides the machine json for exactly the reason `deferrals` does: the
  # requeue paths below rebuild the queue entry from these fields, and a base
  # dropped here would silently retry the child against main — which is the
  # chain wait this whole lane exists to remove. Absent = no field, as before.
  SBASE=$(jq -r '.stack_base // ""' "$MF" 2>/dev/null)
  case "$SBASE" in *[!A-Za-z0-9._/-]*) SBASE="" ;; esac
  SBMETA=""; [ -n "$SBASE" ] && SBMETA=$(jq -nc --arg sb "$SBASE" '{stack_base:$sb}' 2>/dev/null)
  # The hotfix flag rides the machine json for exactly the reason `stack_base`
  # does (#368): every requeue path below rebuilds the queue entry from these
  # fields, and a flag dropped here is an emergency that quietly stops being one
  # — the next tick would defer it for the cap it was exempt from a minute ago.
  MHF=$(jq -r '.hotfix // false' "$MF" 2>/dev/null); case "$MHF" in true) MHF=true ;; *) MHF=false ;; esac
  # The key this machine ran before, when it was handed this job by a reuse
  # (BH-5025.2). Absent = a fresh spawn.
  MREUSED=$(jq -r '.reused_from // ""' "$MF" 2>/dev/null); [ "$MREUSED" = null ] && MREUSED=""
  # The exact line spawn_one (or the reuse handoff) appended to this key's
  # .spawns log when it recorded THIS machine against the per-key cap
  # (BH-1279). Read back here so the BUILD_DEFERRED REFUSED arm below can
  # remove exactly this one entry — never a different spawn's — when the claim
  # this machine tried never ran at all. Absent on a machine json predating
  # this change, or a rebase (never recorded in the first place): the arm
  # below then un-records nothing, which is the same "no worse than before"
  # behaviour every other absent field on this json degrades to.
  SPAWNCAPTS=$(jq -r '.spawn_cap_ts // ""' "$MF" 2>/dev/null)
  # When this machine took this key (spawn or reuse handoff). The pool-result
  # row below is only this machine's answer if it was written after it.
  SPAT=$(jq -r '.spawned_at // ""' "$MF" 2>/dev/null)
  # When the App token this machine is carrying dies, and when it was last
  # replaced (2026-09-14). Absent = this machine shipped the PAT, or its record
  # predates the change: rotate_gh_token leaves both alone.
  GHEXP=$(jq -r '.gh_token_expires_at // ""' "$MF" 2>/dev/null)
  GHROT=$(jq -r '.gh_token_rotated_at // ""' "$MF" 2>/dev/null)
  # The max account this machine is spending, by NAME (2026-09-14). Absent = it
  # shipped the project-6 token, and every account path below then no-ops.
  MACCT=$(jq -r '.auth_account // ""' "$MF" 2>/dev/null)
  case "$MACCT" in null|*[!a-z0-9._-]*) MACCT="" ;; esac
  # 1 once the reap below has cooled MACCT and read the cooldown back (BH-1853).
  ACOOLED=""
  # 1 once the reap below has read a token-401 deferral (BH-5025.2). Reset per
  # machine: next_job_or_destroy reads it, and it must never reach the next one.
  TOKFAIL=0
  # 1 once the record arm below took this machine's result from the build record
  # (BH-7429): next_job_or_destroy stamps it reaped as its last step.
  RECSTAMP=0
  # The tick's own listing answers this for every machine at once when it is
  # usable, and a machine ABSENT from it reads as the empty string — exactly what
  # an errored `machine status` yields today, so the dead path below is reached
  # by the same route it always was. No listing, no guessing: ask Fly per machine.
  if [ "$LIST_OK" = 1 ]; then
    MSTATE=$(jq -r --arg m "$MID" '.[] | select(.id==$m) | .state // ""' "$LISTING" 2>/dev/null | head -1)
  else
    MSTATE=$(timeout 30 "$FLY" machine status "$MID" -a "$APP" 2>/dev/null | grep -oE "State: [a-z]+" | cut -d' ' -f2)
  fi
  # /run/harness/RESULT is the runner's CANONICAL result — it exists even when
  # run-build never produced a build dir (BUILD_ERROR/DEFERRED paths). Reading
  # only the build-dir glob made those failures silent (TK-143, 2026-08-13).
  # THE RECORD BEFORE THE SSH (BH-7429). The runner posted its build record
  # (bin/lib/pool-record.sh); when it is this machine's from this run, the
  # result and every file come from it, and this machine costs no ssh call. A
  # miss, a record of another machine or run, or an unreadable worker is the
  # ssh path below, exactly as before. Never for an RB- rebase.
  RES=""; RES_FROM_RECORD=0; RECSTAGE=""; RECINFO=""
  if [ "$POOL_RECORD_READ" = 1 ] && [ "${KEY#RB-}" = "$KEY" ] \
     && RECSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/pool-record.XXXXXX"); then
    RECINFO=$(pool_record_get "$P" "$KEY" "$MID" "$SPAT" "$RECSTAGE"); RECRC=$?
    if [ "$RECRC" = 0 ]; then
      RES=$(head -1 "$RECSTAGE/RESULT"); RES_FROM_RECORD=1
    else
      rm -rf "$RECSTAGE"; RECSTAGE=""
      [ "$RECRC" = 1 ] && say "build record for $KEY unreadable (machine $MID) — the reap reads it over ssh"
    fi
  fi
  [ "$RES_FROM_RECORD" = 1 ] || RES=$(mexec "$MID" "head -1 /run/harness/RESULT 2>/dev/null")
  # GATE (2026-08-30, MEDIC 4467): mexec stdout is not proof of a RESULT — a
  # flyctl ssh-console panic prints "Oops"/goroutine noise on stdout, and this
  # loop then reaped and force-destroyed a machine mid-build. Anything without
  # a canonical RESULT prefix is a mexec MISS: leave the machine alone.
  if [ -n "$RES" ] && ! "$HARNESS/bin/result-prefix-ok.sh" "$RES"; then
    echo "[fly-pool] $MID: mexec returned non-RESULT stdout (mexec miss, not a build result) — skipping reap" >&2
    RES=""
  fi
  # THE ROW BEFORE THE MACHINE STATE (BH-2643). A machine that answered `job
  # done` and idled out to autostop is `stopped`, and ssh cannot reach it, so
  # RES is empty and the liveness path below used to count a death — two of
  # those parked a ticket that had only ever deferred. The runner also writes
  # its result to a pool-result row (bin/lib/pool-result-row.sh); for a machine
  # that is not started, that row is read here, and only this machine's row
  # from this run counts. Every row pool_result_row_get accepts (rc 0: a
  # canonical RESULT prefix, this machine, this run) IS the result and takes
  # the same path below as an ssh-read one (BH-7719): a BUILD_DEFERRED goes
  # through the deferral arm, a PLAN_BLOCKED is held by its `done` queue row,
  # a PR_CREATED is verified and relayed. A requeue only re-ran the same plan
  # into the same answer. rc 1 (unreadable) and rc 2 (no row, a stale row, a
  # row of another machine) are never read as a result: those are deaths.
  # An RB- rebase row carries the whole RESULT (BH-7656): a rebase word in it is
  # the finished rebase, and the whole text becomes $LOCAL/RESULT for the
  # rebase arm below. Any other word in an RB- row is a miss, and its dead arm
  # fails the row as it always did.
  ROW_RLINE=""; RES_FROM_ROW=0; RBROWF=""
  if [ -z "$RES" ] && command -v pool_result_row_get >/dev/null 2>&1; then
    case "$KEY" in
      RB-*)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            RBROWF=$(mktemp)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT" "$RBROWF"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            case "${ROW_RLINE%% *}" in
              REBASED|CONFLICT|GATE_RED|REBASE_LEASE_REJECTED|REBASE_SETUP_FAILED)
                RES="$ROW_RLINE"; RES_FROM_ROW=1
                say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)" ;;
              *) ROW_RLINE=""; rm -f "$RBROWF"; RBROWF="" ;;
            esac ;;
        esac ;;
      RR-*) ;;
      # A CP- console preview row carries the whole RESULT too (BH-8030); only a
      # CPV_ word in it is the finished job.
      CP-*)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            RBROWF=$(mktemp)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT" "$RBROWF"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            case "${ROW_RLINE%% *}" in
              CPV_*)
                RES="$ROW_RLINE"; RES_FROM_ROW=1
                say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)" ;;
              *) ROW_RLINE=""; rm -f "$RBROWF"; RBROWF="" ;;
            esac ;;
        esac ;;
      *)
        case "$MSTATE" in
          ""|stopped|destroyed|failed|suspended)
            ROW_RLINE=$(pool_result_row_get "$P" "$KEY" "$MID" "$SPAT"); ROWRC=$?
            [ "$ROWRC" = 0 ] || ROW_RLINE=""
            [ "$ROWRC" = 1 ] && say "pool-result row for $KEY unreadable (machine $MID state=${MSTATE:-gone}) — reaped as it always was"
            if [ -n "$ROW_RLINE" ]; then
              RES="$ROW_RLINE"; RES_FROM_ROW=1
              say "result for $KEY taken from the pool-result row (machine $MID state=${MSTATE:-gone}, unreachable)"
            fi ;;
        esac ;;
    esac
  fi
  if [ -n "$RES" ]; then
    LOCAL="$HARNESS/builds/pool-$P-$KEY-$(date -u +%Y%m%d%H%M)"; mkdir -p "$LOCAL"
    if [ "$RES_FROM_ROW" = 1 ]; then
      # Nothing on the machine can be fetched: the RESULT is the row's (the
      # whole text for an RB- row, else its first line).
      if [ -n "$RBROWF" ] && [ -s "$RBROWF" ]; then cp "$RBROWF" "$LOCAL/RESULT"; else echo "$RES" > "$LOCAL/RESULT"; fi
      [ -z "$RBROWF" ] || rm -f "$RBROWF"
      echo "pool-result row" > "$LOCAL/result-source"
      # The machine's Fly seconds, ended at its stop time (BH-7719). Braced and
      # "|| true", as the record arm below, so the cost-row suite's pins (B3a,
      # B3c) still name the ssh arm's pair.
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      case "$(head -1 "$LOCAL/RESULT")" in
        PLAN_BLOCKED*) say "held $KEY: PLAN_BLOCKED from the pool-result row — not requeued; the stranded watch re-offers it only after a person answers" ;;
      esac
    elif [ "$RES_FROM_RECORD" = 1 ]; then
      # The same files the ssh arm below fetches, from the record. A file too
      # big for a D1 row was skipped by the machine: it is fetched over ssh
      # while the machine is up, and named as absent when it is not.
      RECSUM=$(pool_record_install "$RECSTAGE" "$LOCAL" "$MID" "$MSTATE" "$RECINFO") \
        || say "build record for $KEY: a staged file could not be moved into $LOCAL"
      read -r RECN RECM RECABS <<<"$RECSUM"
      say "record for $KEY taken from the jobs API (${RECN:-0} files, ${RECM:-0} skipped${RECABS:+; not on the hub: $RECABS})"
      # The bill, as the ssh arm below does. Written with "|| true" and braces so
      # the cost-row suite's one-call-above-the-push pin (B3a, B3c) still names
      # the ssh arm's pair, the first full-form push line in this file.
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      [ -s "$LOCAL/RESULT" ] || echo "$RES" > "$LOCAL/RESULT"
      echo "build record" > "$LOCAL/result-source"
      RECSTAMP=1
    else
      [ "$POOL_RECORD_READ" = 1 ] && [ "${KEY#RB-}" = "$KEY" ] \
        && say "no build record for $KEY from $MID — its files are pulled over ssh"
      # THE BUILD'S OWN DIRECTORY, NEVER THE FIRST ONE ON DISK (2026-09-13, project-5
      # TK-493/#520). A reused pool machine holds every build it has run; `ls | head -1`
      # picked the alphabetically-first one, so #520's record carried TK-291's
      # review.md and pipeline.log — a BLOCK the ledger's APPROVE contradicted, and
      # the sweep parked it. RESULT names the directory (BUILD_DIR:);
      # the listing is only the fallback for a RESULT that predates that line.
      RB=$(printf '%s\n' "$RES" | sed -n 's/^BUILD_DIR: //p' | head -1)
      if [ -n "$RB" ]; then RB="/data/harness/builds/${RB##*/}"
      else RB=$(mexec "$MID" 'ls -dt /data/harness/builds/* 2>/dev/null | head -1'); fi
      # THE RELAY IS THE MERGE GATE'S EYES (2026-09-12, project-5 TK-419/TK-290).
      # Everything downstream — bin/merge-sweep.sh, the conductor, an operator
      # reading a park — runs on the HUB and reads HUB build dirs. An artifact
      # left on the machine is an artifact the gate cannot see, and two of these
      # are safety holes rather than conveniences:
      #   e2e.md      — merge-sweep.sh:291 treats an ABSENT e2e.md as "the stage
      #                 never ran" and merges. A pool build whose E2E FAILED was
      #                 therefore merging silently.
      #   reviewed-sha — merge-sweep.sh:332's documented fallback when the ledger
      #                 has no row, and mc_rebase's record rebind (which only
      #                 writes the file when it already exists). Both were no-ops
      #                 for every pool build.
      # The rest are the head-bound and refuter evidence: the findings that caused
      # a demotion, the suite re-run the re-review was told outranks everything,
      # and headbound-outcome — the one word that tells a reader whether a
      # reviewer said BLOCK or nobody answered at all.
      # The loop is [ -s ]-guarded, so an absent file costs one mexec and writes
      # nothing.
      # merged-review2.md and harness-suite-fix.txt join them 2026-09-12, when the
      # three lenses started running together: under LENSES_PARALLEL=1 the one
      # re-review that adjudicates all of them writes merged-review2.md, and the
      # suite re-run the re-reviewer is told outranks every claim goes to
      # harness-suite-fix.txt. Without these two, a pool build's fanned-back
      # verdicts would arrive on the hub with their reasoning left on the machine.
      # This list is pinned equal to POOL_RECORD_FILES (bin/lib/pool-record.sh,
      # BH-7429) by tests/pool-record-lib.bh-7429-test.sh: the machine's build
      # record carries the same names, and tests grep this file for them.
      for A in plan.md review.md security-review.md security-review-run.txt refute-review.md \
               merged-review2.md harness-suite-fix.txt \
               qa.md e2e.md evidence.md changed-files.txt \
               reviewed-sha headbound-outcome headbound-review.md headbound-review-run.txt harness-suite-head.txt \
               pipeline.log cost.csv validate.txt red.txt green.txt mutation-check.txt context.json gh-stderr.log \
               execute-transcript.md stop-reason.txt ticket-meta.json; do
        T=$(mktemp); if mexec "$MID" "base64 -w0 $RB/$A 2>/dev/null" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/$A" 2>/dev/null; fi; rm -f "$T"
      done
      # The machine's bill, under the machine's own box id. Before the RESULT is
      # assembled and long before the machine is reused or destroyed: from here on
      # every path leads to next_job_or_destroy, and a destroyed machine's rows
      # would have nowhere left to come from. Covers the deferral path too — a
      # deferred build still paid for whatever stages it ran. The machine's own
      # Fly seconds for this job join them first, as one infra row (BH-4019).
      pool_fly_cost_row
      push_pool_cost_rows "$LOCAL" "pool-$P-$MID"
      # THE MACHINE'S FAILOVERS.LOG COMES HOME TOO (2026-09-23 pool loop). The
      # ladder's class notes and the vendor's own error text are written there
      # and nowhere else, so a machine destroyed after a failed stage took the
      # only evidence of WHY with it. Tail-bounded: a reused machine's log holds
      # every job it ran.
      T=$(mktemp); if mexec "$MID" "tail -c $POOL_RELAY_FAILOVERS_BYTES /data/harness/logs/failovers.log 2>/dev/null | base64 -w0" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/failovers.log" 2>/dev/null; fi; rm -f "$T"
      # Full canonical RESULT (rline + TIER + PR lines), not just the head-1.
      T=$(mktemp); if mexec "$MID" "base64 -w0 /run/harness/RESULT 2>/dev/null" > "$T" && [ -s "$T" ]; then base64 -d "$T" > "$LOCAL/RESULT" 2>/dev/null; fi; rm -f "$T"
      [ -s "$LOCAL/RESULT" ] || echo "$RES" > "$LOCAL/RESULT"
    fi
    RLINE=$(head -1 "$LOCAL/RESULT")
    # BH-7116: a row-sourced PLAN_BLOCKED gets plan.md from the ledger.
    command -v pb_hub_copy >/dev/null 2>&1 && { PBH=$(pb_hub_copy "$HARNESS" "$P" "$LOCAL" 2>/dev/null); [ -z "$PBH" ] || say "$KEY: $PBH"; }
    # DID THE ACCOUNT REFUSE? (2026-09-14; re-read 2026-09-23) A pool machine
    # cannot cool its own account down: bin/agent-call.sh's cooldown is fenced on
    # ACCOUNT_ROUTING + ACCT_NAME, and neither rides the bundle. So the hub
    # decides here, while it still knows which account the machine leased.
    #
    # It used to grep the machine's failovers.log for usage-limit words. That
    # matched 0 times, ever: the CLI prints "You've hit your weekly limit", and
    # the ladder's own notes in that file carry the class, never the vendor's
    # text. The stage's verdict line is the one place the fact is always stated:
    # RUNNER_EXHAUSTED (or seen=...account-exhausted) is in the RESULT, and
    # `exhausted=` names the runners that ran out — so an OpenRouter key at its
    # limit does not park a healthy Claude account. A line from an older image
    # with no `exhausted=` is read the way it always meant: this account.
    # `resets_at=` is the CLI's own reset time; the cooldown then lasts until it.
    # And the ticket's pin to this account goes, or its next launch would be
    # steered straight back to it.
    if [ -n "$MACCT" ] && command -v pool_account_cooldown >/dev/null 2>&1; then
      case "$RLINE" in
        *RUNNER_EXHAUSTED*|*seen=*account-exhausted*)
          XRUN=$(printf '%s\n' "$RLINE" | sed -n 's/.* exhausted=\([a-z0-9,._-]*\).*/\1/p' | head -1)
          case ",${XRUN:-claude}," in
            *,claude,*)
              XRESET=$(printf '%s\n' "$RLINE" | sed -n 's/.* resets_at=\([0-9][0-9]*\).*/\1/p' | head -1)
              pool_account_cooldown "$MACCT" "pool-$P-$KEY" "$XRESET"
              # Verified, not assumed: pool_account_cooldown answers 0 even
              # when its write failed, and the hold decision below trusts this.
              command -v account_cooling >/dev/null 2>&1 && account_cooling claude "$MACCT" && ACOOLED=1
              command -v pool_account_unpin >/dev/null 2>&1 && pool_account_unpin "$P" "$KEY" "$MACCT"
              say "account $MACCT ran out on $MID during $KEY — cooled down on the hub${XRESET:+ until $(date -u -d "@$XRESET" '+%Y-%m-%d %H:%MZ' 2>/dev/null || echo "$XRESET")} and unpinned; the next launches skip it" ;;
          esac ;;
      esac
    fi
    # >>> pool console preview reap
    # --- A CONSOLE PREVIEW IS NOT A BUILD (BH-8030) ---------------------------
    # A CP-<pr>-<head8>-<job> machine ran the console preview lane's build and
    # Pages upload (bin/lib/console-preview-job.sh). Its RESULT line 1 closes
    # the row `done`, and the hub lane (bin/console-preview-deploy.sh) reads it
    # there: QA, the comment and the state file are the lane's. There is no PR
    # to verify and no board close-out. A CPV_ word on any other key, or any
    # other word on a CP key (a stand-down excepted: the BUILD_DEFERRED arm
    # below owns it), is a RESULT nobody can apply: the row is FAILED, and the
    # build path never sees it.
    CPK=0; case "$KEY" in CP-*) CPK=1 ;; esac
    CPW=0; case "$RLINE" in CPV_*) CPW=1 ;; esac
    if [ "$CPW" = 1 ] || { [ "$CPK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$CPW" = 1 ] && [ "$CPK" = 1 ]; then
        QROW done "$KEY" "$(head -1 "$LOCAL/RESULT" | head -c 400)"
        say "reaped console preview $KEY from $MID: $(head -1 "$LOCAL/RESULT" | head -c 120)"
      else
        QROW failed "$KEY" "console preview RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a CPV_ word belongs to a CP- row and a CP- row answers only a CPV_ word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build. The RESULT is at $LOCAL/RESULT"
        say "console preview $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool console preview reap
    # >>> pool rereview reap
    # --- A RE-REVIEW IS NOT A BUILD EITHER (BH-7635) --------------------------
    # An RR-<pr>-<head8> machine ran the conductor's head-bound re-review
    # (bin/lib/rereview-job.sh). Its RESULT goes to mc_pool_rereview_apply,
    # which writes the hub job file headbound_review reads; nothing here posts,
    # and there is no PR to verify and no board close-out. A REREVIEW word on
    # any other key, or any other word on an RR key (a stand-down excepted: the
    # BUILD_DEFERRED arm below owns it), is a RESULT nobody can apply, so the
    # row is FAILED and the build path never sees it. rc 127 is seeded, as in
    # the rebase reap, so a box without the lib takes the refusal path.
    RRK=0; case "$KEY" in RR-*) RRK=1 ;; esac
    RRW=0; case "$RLINE" in REREVIEWED*|REREVIEW_*) RRW=1 ;; esac
    if [ "$RRW" = 1 ] || { [ "$RRK" = 1 ] && [[ "$RLINE" != BUILD_DEFERRED* ]]; }; then
      : > "$LOCAL/COMMENTED"
      if [ "$RRW" = 1 ] && [ "$RRK" = 1 ]; then
        RRRC=127
        fp_mc_lib_load || true
        command -v mc_pool_rereview_apply >/dev/null 2>&1 \
          && { mc_pool_rereview_apply "$P" "$KEY" "$LOCAL/RESULT"; RRRC=$?; }
        if [ "$RRRC" = 0 ]; then
          QROW done "$KEY" "$(head -1 "$LOCAL/RESULT" | head -c 200)"
          say "pool rereview RESULT reaped for $KEY from $MID: $(head -1 "$LOCAL/RESULT" | head -c 80) — job file written"
          "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -1 "$LOCAL/RESULT" | head -c 120)" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_rereview",detail:$r}')" >/dev/null 2>&1 || true
        else
          # Left CLAIMED, as a refused rebase apply is: nothing re-materialises a
          # claimed row, so the read is not bought twice while someone looks.
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool rereview RESULT reaped ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) but mc_pool_rereview_apply answered rc=$RRRC — the queue row stays CLAIMED, no hub re-review job file was written, and nothing retries this on its own. The RESULT is at $LOCAL/RESULT"
          say "rereview $KEY: apply refused rc=$RRRC — row left claimed, RESULT at $LOCAL/RESULT"
        fi
      else
        RRREC="no hub job file was marked"
        fp_mc_lib_load || true
        case "$KEY" in
          RR-*) command -v mc_pool_rereview_fail >/dev/null 2>&1 \
                  && mc_pool_rereview_fail "$P" "$KEY" "the pool machine answered a RESULT that is not a re-review" \
                  && RRREC="the hub re-review job file is marked lane-failed, so the conductor retries the read with no strike on the PR" ;;
          RB-*) command -v mc_pool_rebase_fail >/dev/null 2>&1 \
                  && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered a re-review RESULT to a rebase job" \
                  && RRREC="the hub rebase job file is marked failed" ;;
        esac
        QROW failed "$KEY" "re-review RESULT and row key do not match; row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RESULT ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) and the row key do not match — a re-review word belongs to an RR- row and an RR- row answers only a re-review word. The queue row is FAILED and NOT requeued, and the RESULT is never read as a build; $RRREC. The RESULT is at $LOCAL/RESULT"
        say "rereview $KEY: RESULT/key mismatch — row failed, RESULT at $LOCAL/RESULT"
      fi
      next_job_or_destroy
      continue
    fi
    # <<< pool rereview reap
    # >>> pool rebase reap
    # --- A REBASE IS NOT A BUILD (BH-486.2, #542) -----------------------------
    # Under REBASE_ON_POOL the machine this loop just reaped ran a rebase, not a
    # build: there is no PR to verify against GitHub, no result the owning box
    # owes a client a comment for, and nothing for the merge queue. The five
    # first words are bin/lib/rebase-job.sh's vocabulary and nothing else on
    # this branch; everything below it is the build path, untouched.
    #
    # The apply is the hub's half — it writes the rebase job file and the ledger
    # row and attempts the approval rebind. It either did that (rc 0) or it did
    # not, and "did not" includes the function not being here at all: rc 127 is
    # seeded before the call so a half-synced box takes the refusal path rather
    # than falling through to the build one.
    case "$RLINE" in
      REBASED*|CONFLICT*|GATE_RED*|REBASE_*)
        RBRC=127
        fp_mc_lib_load || true
        command -v mc_pool_rebase_apply >/dev/null 2>&1 \
          && { mc_pool_rebase_apply "$P" "$KEY" "$LOCAL/RESULT"; RBRC=$?; }
        # This directory owes no board close-out — there is no ticket to comment
        # on — and without the sentinel three sweeps read it as one that does:
        # bin/pipeline-health.sh check 4 ("uncommented result >1h", forever),
        # bin/triage-gate.sh's results-sweep gate (it globs builds/pool-<p>-*)
        # and bin/orphan-reconcile.sh's UNSWEPT loop, which would each hand a
        # REBASED dir to a session to close out "ticket <pr>".
        # DEFERRED would claim the build stood down and RELAYED that custody
        # moved to a box; both are false. Stamped on BOTH paths: on the refused
        # one the ALERTS line below is the page, and check 4 paging the same
        # directory an hour later is the same fact a second time.
        : > "$LOCAL/COMMENTED"
        if [ "$RBRC" = 0 ]; then
          : > "$LOCAL/REBASE"
          QROW done "$KEY" "$(head -c 200 "$LOCAL/RESULT")"
          RBTIM=$(sed -n 's/^TIMINGS: //p' "$LOCAL/RESULT" 2>/dev/null | head -1)
          say "reaped rebase $KEY from $MID: $(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')${RBTIM:+ timings: $RBTIM}"
          "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -c 120 "$LOCAL/RESULT")" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_rebase",detail:$r}')" >/dev/null 2>&1 || true
        else
          # The row is left CLAIMED on purpose: nothing re-materialises a claimed
          # row, so the rebase does not silently run twice while someone reads
          # this line. Nothing requeues it either — bin/jobs-watchdog.sh sweeps
          # only the triage/preplan/pr-* classes — so this is manual cleanup, and
          # the line says where the evidence is. No beat either: a rebase that
          # did not apply is not a finished anything.
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool rebase RESULT reaped ($(head -c 80 "$LOCAL/RESULT" | tr '\n' ' ')) but mc_pool_rebase_apply answered rc=$RBRC — the queue row stays CLAIMED, no hub-side rebase job file was written, and nothing retries this on its own. The RESULT is at $LOCAL/RESULT"
          say "rebase $KEY: apply refused rc=$RBRC — row left claimed, RESULT at $LOCAL/RESULT"
        fi
        next_job_or_destroy
        continue ;;
    esac
    # <<< pool rebase reap
    # A push reported rejected whose push in fact landed (BH-6821): the hub
    # opens the PR and RLINE becomes PR_CREATED, which the gate below verifies.
    command -v ppr_reap_landed >/dev/null 2>&1 && { ppr_reap_landed || true; }
    # --- A DEFERRAL IS NOT A RESULT (2026-09-11, the pool-cap refusal class) --
    # bin/run-build.sh writes BUILD_DEFERRED + exit 3 for "not now, not a
    # failure" — a busy slot, a key already building, a file overlap, or a
    # ledger claim REFUSED by a concurrency rule. On a normal box that is
    # harmless: nothing closes the queue row and the next tick re-offers the
    # ticket. Here it was fatal, because the reap below files ANY reaped RESULT
    # as `done` — so a build that never started was recorded as a finished one
    # and the ticket was never offered again. That is how project-5 TK-268 and
    # TK-270 each burned three machines today, and project-4 TK-1515/1566/1571/1576
    # one apiece: every pool machine boots as box `pool-<project>`, so the
    # `box * build 1` rule counted the whole pool as one box and refused every
    # claim after the first.
    #
    # So a deferral is REQUEUED, not closed, and it says so where the hub can
    # see it — the run-build ALERT line is written on the machine's own
    # ALERTS.log and dies with the machine. The build dir stays for audit; the
    # relay does not run, because there is no result to hand anyone and a
    # close-out sweep has nothing to close.
    if [ "${RLINE#BUILD_DEFERRED}" != "$RLINE" ]; then
      # A CLAIM REFUSED BY THE DB NEVER RAN (BH-1279). "BUILD_DEFERRED REFUSED
      # <scope> :: <reason>" is job_open's rc=9 shape (bin/lib/jobs/jobs.sh) —
      # a phase-6 concurrency rule, a pause flag, or a stale retry (job-retry's
      # own REFUSED) — and run-build.sh writes it before anything else runs.
      # This machine's spawn already counted against POOL_SPAWN_CAP_PER_KEY
      # (spawn_one records unconditionally, BH-1075), and for every OTHER
      # BUILD_DEFERRED shape that is correct: a busy slot, this key already
      # building, a file overlap, a push rejected downstream all mean the
      # machine genuinely ran for a while. A refused claim never did, so
      # counting it the same way turned one fleet-wide concurrency-rule
      # refusal into per-key POOL_DEFER_TO_HUMAN parking within two ticks (17
      # keys, 2026-09-21). Un-record ONLY this shape; the deferral bookkeeping
      # below (deferrals, requeue) is unchanged either way.
      # A LANE FAILURE NEVER RAN THE TICKET EITHER (2026-09-23): the same
      # un-record, for the same reason — see POOL_LANE_FAIL_HOLD_S. Only while
      # the hold is armed: with it off, the per-key cap is the one thing left
      # that bounds a lane failure's respawns, so it keeps counting.
      # A DIRTY MACHINE NEVER RAN THE TICKET EITHER (BH-5021): a build slot was
      # still held on it after the runner's cleanup, so the machine was at
      # fault, not the ticket. Un-recorded and uncounted like a lane failure,
      # but no project hold: one dirty machine is not a lane outage, and
      # next_job_or_destroy destroys it rather than reusing it.
      LANEFAIL=0; pool_lane_failure "$RLINE" && LANEFAIL=1
      DIRTYSLOT=0; case "$RLINE" in BUILD_DEFERRED*"slot held on this machine"*) DIRTYSLOT=1 ;; esac
      # A DEAD TOKEN IS NOT THE TICKET (BH-5025.2): requeued with the deferral
      # count unchanged and no hold, and the machine is destroyed, not reused.
      # The spawn stays on the per-key cap, which bounds a broken hub mint. A
      # lane failure wins, so its hold is never weakened.
      pool_token_failure "$RLINE" && [ "$LANEFAIL" = 0 ] && TOKFAIL=1
      # A HOTFIX THAT DEFERRED ON A REUSED MACHINE gets a fresh one next time
      # (BH-5025.2): `fresh_spawn` rides the queue file and the row meta, and the
      # reuse handoff in next_job_or_destroy skips it.
      DFS=false
      [ "$MHF" = true ] && [ -n "$MREUSED" ] && [ "$LANEFAIL" = 0 ] && [ "${POOL_HOTFIX_FRESH_AFTER_DEFER:-1}" != 0 ] && DFS=true
      # AN OVERLAP OR After: WAIT NEVER RAN THE TICKET EITHER (BH-5912): the
      # machine stood down before a plan, on a sibling's build. Counting it let
      # a key behind a chain of siblings spend its whole cap on stand-downs.
      # The cap does not bound this loop; `deferrals` below still advances, so
      # DEFER_MAX and then the resolver's capped rebuild ladder do.
      if [[ "$RLINE" == "BUILD_DEFERRED REFUSED "* ]] || [ "$DIRTYSLOT" = 1 ] \
         || pool_overlap_deferral "$RLINE" \
         || { [ "$LANEFAIL" = 1 ] && [ "$POOL_LANE_FAIL_HOLD_S" -gt 0 ]; }; then
        pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      fi
      # >>> push-rejected terminal (BH-1075)
      if [[ "$RLINE" == "BUILD_DEFERRED push of ticket/"* ]] && [[ "$RLINE" == *"rejected"* ]]; then
        # A remote that diverged from the built head is requeued ONCE from the
        # remote head instead (BH-6821, bin/lib/pool-push-rejected.sh).
        if command -v ppr_reap_diverged >/dev/null 2>&1 && ppr_reap_diverged; then
          next_job_or_destroy
          continue
        fi
        BR=$(pool_key_branch "$KEY")
        HEADSHA=$(branch_head_rest "$BR")
        pool_terminal_write "$KEY" "$BR" "${HEADSHA:-unknown}" "$RLINE" "$TICKET"
        : > "$LOCAL/TERMINAL"
        : > "$LOCAL/COMMENTED"
        # AND THE ROW CLOSES (review round 2, Important-3). A terminal that left
        # its row `claimed` was a row nothing could act on: the watchdog requeues
        # it on a TTL, the gate refuses it, and the ledger never says what
        # happened. `failed` with the reason is what the terminal file already
        # records, in the one place a human or bin/blocked-resolver.sh looks.
        QROW failed "$KEY" "push to ticket/$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]') rejected at ${HEADSHA:-unknown} — terminal, not respawned (state/pool/$P/$KEY.terminal)"
        say "terminal $KEY: push rejected at ${HEADSHA:-unknown} — not requeued"
        command -v ppr_terminal_note >/dev/null 2>&1 && ppr_terminal_note
        next_job_or_destroy
        continue
      fi
      # <<< push-rejected terminal
      # The stand-down this deferral advances — `deferrals`, never `attempt`.
      # The pool json carries what the queue file said when the machine was
      # spawned; when that was lost, the deferral build dirs for this key are
      # the honest floor — one per reaped deferral, including this one.
      # A lane failure advances nothing, and the floor below does not count one
      # either — otherwise the first ordinary deferral after a lane outage would
      # be charged for every lane failure that preceded it.
      DNEXT=$((DEFC+1))
      DSEEN=0
      for DRF in "$HARNESS/builds/pool-$P-$KEY-"*/RESULT; do
        [ -f "$DRF" ] || continue
        DRL=$(head -1 "$DRF" 2>/dev/null)
        case "$DRL" in
          BUILD_DEFERRED*"slot held on this machine"*) ;;
          BUILD_DEFERRED*) pool_lane_failure "$DRL" || pool_token_failure "$DRL" || DSEEN=$((DSEEN+1)) ;;
        esac
      done
      [ "$DSEEN" -gt "$DNEXT" ] && DNEXT="$DSEEN"
      { [ "$LANEFAIL" = 1 ] || [ "$DIRTYSLOT" = 1 ]; } && DNEXT="$DEFC"
      [ "$TOKFAIL" = 1 ] && DNEXT="$DEFC"
      DWHY=$(head -c 120 "$LOCAL/RESULT" | tr '\n' ' ')
      # THE BLOCKER THIS STAND-DOWN NAMES (BH-5967), read off the whole first
      # line: the `After:` clause can sit past the 120 characters DWHY keeps.
      DAFTER=""
      command -v defer_after_key >/dev/null 2>&1 && DAFTER=$(defer_after_key "$RLINE") || DAFTER=""
      DMETA=$(jq -nc --argjson d "$DNEXT" --argjson x "$DTHS" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" --arg af "$DAFTER" '{deferrals:$d,deaths:$x} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end) + (if $af == "" then {} else {after:$af} end)')
      # The sentinel is what tells this dir from a build that owes the board a
      # close-out: it has a RESULT and will never have a COMMENTED, so without
      # it bin/pipeline-health.sh pages "uncommented result >1h" for a build
      # that never ran, forever.
      : > "$LOCAL/DEFERRED"
      # A REBASE IS NEVER REQUEUED, IT IS FAILED (BH-542). Both arms below
      # rebuild the queue FILE out of the machine json, and that json carries no
      # `rebase` object — so a requeued RB- row arrives at the next machine as
      # {ticket_id:"21",key:"RB-21-…"}, which the pool dispatches as an ordinary
      # BUILD of "ticket 21" of this project, with a PR and a board comment
      # nobody asked for. That is the same failure bin/fly-dispatch.sh REFUSES a
      # row for; manufacturing it here would walk straight around it.
      #
      # The reason string deliberately contains neither `died N times` nor
      # `deferred N times`: those two are br_from_queue's triggers
      # (bin/blocked-resolver.sh:613-614) and either one would have the resolver
      # rebuild "ticket <pr>" from scratch. No `$QDIR/$KEY.failed.json` either —
      # br_from_queue turns EVERY such file into a pool-died-twice rebuild.
      # Nothing in this pool retries. What DOES recover the PR is the hub job
      # file: mc_pool_rebase_fail marks it `failed` below, so the conductor's
      # failed/stale arm parks the PR in NEEDS_REBASE on its next tick instead
      # of reading a `pool` file as `running` for MC_REBASE_POOL_TIMEOUT_SECS
      # (BH-986 — that claim used to say "re-enqueues on its next tick", which
      # overstated the recovery by up to 90 minutes).
      #
      # COMMENTED because this dir owes the board no close-out (the same
      # reasoning the rebase reap block above states); DEFERRED is already
      # stamped. No `pool_deferred` beat: a rebase is not a build that stood
      # down, and the console would read it as one.
      case "$KEY" in
        RB-*)
          : > "$LOCAL/COMMENTED"
          # The hub job file first: a `pool` file left alone reads as `running`
          # to mc_rb_state until MC_REBASE_POOL_TIMEOUT_SECS, and the ALERTS
          # text below says which of the two recoveries this PR actually gets.
          # `command -v` guarded like the apply above — a half-synced box
          # defines neither, and a missing function must never read as done.
          RBREC="no hub rebase job file could be marked failed, so recovery waits for the pool timeout (MC_REBASE_POOL_TIMEOUT_SECS, default 5400s) to fail the job, and then the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) before a fresh rebase can be queued"
          fp_mc_lib_load || true
          if command -v mc_pool_rebase_fail >/dev/null 2>&1 \
             && mc_pool_rebase_fail "$P" "$KEY" "the pool machine answered BUILD_DEFERRED before the rebase ran"; then
            RBREC="the hub rebase job file for this PR is marked failed, so bin/merge-conductor.sh parks the PR back in NEEDS_REBASE on its next tick; the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) is then what forgets this head's attempt and lets a later tick queue a fresh rebase"
          fi
          # The row reason is a CONSTANT: the runner's own text belongs in the
          # ALERTS line and the log, not in the ledger row (BH-986). It also
          # cannot contain `died N times` / `deferred N times` — br_from_queue
          # pattern-matches those anywhere in a reason and would rebuild ticket
          # $TICKET, which is exactly what this arm exists to prevent.
          QROW failed "$KEY" "rebase machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: rebase machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the rebase object and the next machine would run an ordinary BUILD of ticket $TICKET. $RBREC. Evidence: $LOCAL"
          say "rebase $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
        RR-*)
          # A RE-REVIEW ROW STANDS DOWN THE SAME WAY (BH-7635): the requeue would
          # lose the rereview object too. The hub job file goes lane-failed, not
          # failed: the machine stood down, which says nothing about the PR.
          : > "$LOCAL/COMMENTED"
          RRREC="no hub re-review job file could be marked lane-failed, so the conductor finds no job for this head and decides again on a later tick"
          fp_mc_lib_load || true
          if command -v mc_pool_rereview_fail >/dev/null 2>&1 \
             && mc_pool_rereview_fail "$P" "$KEY" "the pool machine answered BUILD_DEFERRED before the re-review ran"; then
            RRREC="the hub re-review job file for this head is marked lane-failed, so the conductor retries the read on its next tick with no strike on the PR (MC_RR_LANEFAIL_MAX)"
          fi
          QROW failed "$KEY" "re-review machine stood down before the job ran; row FAILED, not requeued"
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: re-review machine answered BUILD_DEFERRED ($DWHY) — the queue row is FAILED and NOT requeued, because the requeue rebuilds the queue file without the rereview object and the next machine would run an ordinary BUILD of ticket $TICKET. $RRREC. Evidence: $LOCAL"
          say "rereview $KEY: deferred ($DWHY) — row failed, not requeued"
          next_job_or_destroy
          continue ;;
        CP-*)
          # A CONSOLE PREVIEW ROW STANDS DOWN THE SAME WAY (BH-8030): the
          # requeue would lose the console_preview object. The hub lane reads
          # the failed row as the box's fault and queues a new row.
          : > "$LOCAL/COMMENTED"
          QROW failed "$KEY" "console preview machine stood down before the job ran; row FAILED, not requeued"
          say "console preview $KEY: deferred ($DWHY) — row failed, not requeued; the hub lane queues a new row"
          next_job_or_destroy
          continue ;;
      esac
      if [ "$LANEFAIL" = 1 ]; then
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.json"
        # ONE ACCOUNT OUT IS NOT THE LANE OUT (BH-1853). When the reap just
        # cooled this machine's account and another account can take the next
        # lease, holding the whole project would only park healthy machines.
        # This machine is destroyed below (its token is the exhausted account)
        # and the next spawn re-leases. Anything else holds, exactly as before.
        if [ "${ACOOLED:-}" = 1 ] && command -v pool_account_others_ok >/dev/null 2>&1 && pool_account_others_ok "$MACCT"; then
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: account $MACCT ran out ($DWHY). It is cooled on the hub and another account can serve, so there is no project hold: the ticket is requeued with its deferral count unchanged ($DNEXT), $MID is destroyed rather than reused, and the next spawn takes a fresh lease. Evidence: $LOCAL"
        elif pool_spawn_hold_set "$KEY: $DWHY"; then
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the RUNNER LANE failed, not the ticket ($DWHY). The ticket is requeued with its deferral count unchanged ($DNEXT), and this project's pool spawns and reuses NOTHING for ${POOL_LANE_FAIL_HOLD_S}s (state/pool/$P/_spawn-hold — remove it to lift the hold early; with pool_state_rows on, run bin/pool-state.sh lift-hold $P, which lifts the file and the row). Evidence: $LOCAL"
        fi
        say "LANE FAILURE $KEY: $DWHY — requeued, deferrals unchanged ($DNEXT); project spawn hold $(pool_spawn_held >/dev/null && echo on || echo off)"
        else
          # No project hold for an abandoned ticket's failure: its lines would
          # say the ticket was requeued. The next ticket that hits the lane sets it.
          say "LANE FAILURE $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      elif [ "$TOKFAIL" = 1 ]; then
        # Before the DEFER_MAX arm, so a dead token can never park a ticket.
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end)' > "$QDIR/$KEY.json"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: $MID's GitHub token answered 401 (trigger-actor events read). The ticket is requeued with its deferral count unchanged ($DNEXT) and $MID is destroyed rather than reused; the per-key spawn cap still counts this spawn. Evidence: $LOCAL"
        say "TOKEN-401 $KEY: $DWHY — requeued, deferrals unchanged ($DNEXT), $MID destroyed"
        else
          say "TOKEN-401 $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      # A WAIT IS NOT PARKED BY ITS COUNT, UNTIL IT CHURNS (review of
      # 22e7719c5): after three releases for the same blocker in 24 h the gate
      # keeps the count, and a stand-down at or over the cap then parks here
      # like any other, with its one alert.
      elif [ "$DNEXT" -ge "$DEFER_MAX" ] && { [ -z "$DAFTER" ] || pool_after_churned "$KEY" "$DAFTER"; }; then
        QROW failed "$KEY" "deferred $DNEXT times ($DWHY) — parked for the blocked-resolver"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool build DEFERRED ($DWHY) — deferred $DNEXT times now, so the queue row is FAILED. This pool will not re-offer it; bin/blocked-resolver.sh picks the row up on its next tick and rebuilds the ticket fresh against current main (3 tries, then an ABANDONED outcome record). Evidence: $LOCAL"
        say "DEFERRED $KEY x$DNEXT — parked for the blocked-resolver"
      else
        # A WAIT ON A NAMED BLOCKER NEVER PARKS (BH-5967). The row stays queued
        # with `after` in it, past JOBS_QUEUE_DEFER_MAX too, and the spawn gate
        # (pool_after_gate) holds it with no machine until that blocker is done.
        if QROW requeue "$KEY" "$DWHY" "$ATT" "$DMETA" "$TICKET"; then
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATT" --argjson d "$DNEXT" --argjson x "$DTHS" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" --arg fs "$DFS" --arg af "$DAFTER" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end) + (if $fs == "true" then {fresh_spawn:true} else {} end) + (if $af == "" then {} else {after:$af} end)' > "$QDIR/$KEY.json"
        if [ -n "$DAFTER" ]; then
          say "DEFERRED $KEY: waits for $DAFTER (stand-down $DNEXT) — row stays queued, held until $DAFTER is done"
          pool_after_loop_alert "$KEY" "$DAFTER" "$DNEXT" "$DWHY"
        else
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: pool build DEFERRED ($DWHY) — requeued attempt $DNEXT"
        say "DEFERRED $KEY: $DWHY — requeued attempt $DNEXT"
        fi
        else
          say "DEFERRED $KEY: $DWHY — abandoned by an operator, not requeued"
        fi
      fi
      # The beat says DEFERRED. Beating this as a pool_result would put a build
      # that never ran on the console as one that finished.
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$DWHY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_deferred",detail:$r}')" >/dev/null 2>&1 || true
      next_job_or_destroy
      continue
    fi
    # --- GATE: PR_CREATED is verified against GitHub before the handoff -------
    # (2026-08-14) Stale-RESULT class: a builder writes PR_CREATED and dies (the
    # TK-143/TK-82 branch-collision family) — the reap then hands the watcher a
    # RESULT naming a PR whose push actually rejected, and the board gets a
    # comment linking a PR that does not exist. GitHub is the truth, not the
    # runner's last words: the URL must resolve to an OPEN or MERGED PR, or the
    # first line is rewritten RESULT_UNVERIFIED (which no close-out handler
    # matches) and ONE ALERTS line names it for the alert medic.
    # (BH-709, 2026-09-17) A FAILED READ IS NOT A STATE. The read is REST and
    # answers the status code first — gh_rest_pr_state, the library sourced
    # above — and only an affirmative 404, with the repo itself provably visible
    # to the same token, may be read as "no such PR". Everything else is
    # UNKNOWN: the RESULT is left exactly as the builder wrote it and ONE alert
    # says we could not read it. ONE READ PER TICK (BH-781): 75 means "skip this
    # tick, leave state as it is", and the next */2 reap is the retry.
    # >>> pr verify gate (BH-709)
    # (BH-765, 2026-09-18) A CLAIM WITH NO URL IS A BUILDER DEFECT, and the
    # bare `PR_CREATED` with nothing after it is the same defect as
    # `PR_CREATED  | SIZE: …` — both enter here, and the shape check below
    # decides them from the line alone.
    if [ "${RLINE#PR_CREATED }" != "$RLINE" ] || [ "$RLINE" = "PR_CREATED" ]; then
      PRURL=$(echo "$RLINE" | awk '{print $2}')
      # >>> pr url shape (BH-765)
      # THE ALERT MUST NAME THE RIGHT CULPRIT. Four project-5 builds reaped a
      # RESULT whose first line was `PR_CREATED  | SIZE: 614 product lines … |
      # STACKED on ticket/TK-2212`: the claim was there, the URL was not, so
      # field 2 came out as the literal `|`, the read could not be made at all,
      # and the gate then blamed a gh token that was working perfectly. The
      # shape of field 2 is knowable from the line, before any credential is
      # involved.
      # `RESULT_MALFORMED` starts with `RESULT_`, so it matches neither the
      # `PR_CREATED *` readers (bin/blocked-resolver.sh) nor the
      # `PR_CREATED http*` ones (bin/board-closeout.sh) — the same argument #749
      # makes for PR_CREATE_FAILED and BH-709 for RESULT_UNVERIFIED — and the
      # alert names the build record for the medic.
      if ! [[ "$PRURL" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
        # printf, not sed: RESULT lines legitimately carry '|'.
        { printf 'RESULT_MALFORMED %s\n' "$RLINE"; tail -n +2 "$LOCAL/RESULT"; } > "$LOCAL/RESULT.new" \
          && mv "$LOCAL/RESULT.new" "$LOCAL/RESULT"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: reaped RESULT claims PR_CREATED but field 2 is '$PRURL', not a PR URL — the BUILDER wrote a url-less claim (bin/run-build.sh's result ratchet refuses these since #749; this machine's image predates it or wrote RESULT another way) — rewritten RESULT_MALFORMED. No gh call was made: this is not a token or visibility problem. The build record is at $LOCAL"
        say "MALFORMED $KEY: PR_CREATED with no PR URL in field 2 ('$PRURL') — rewritten RESULT_MALFORMED, no credential involved"
      else
      # <<< pr url shape
      # (2026-09-11) The hub's default gh PAT does not reach every repo the pool
      # builds for (example-org/project-5 and project-7 404 on it), so this check
# rewrote six REAL PRs as RESULT_UNVERIFIED in one evening.
      # (BH-765) Which credential to verify with is not this file's question:
      # bin/lib/gh-repo-token.sh answers it for the whole fleet — the App
      # installation token first when this box is armed, then the default PAT,
      # then the org-admin one — and the by-hand read of the admin env file that
      # used to live here is gone. With the lib absent (a stripped box) nothing
      # is armed and the read falls back to the ambient gh auth, which is what
      # this gate did before 2026-09-11. Only the WORDS app/default/admin/none
      # are ever logged, never the value.
      _VSLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PRURL")
      _VNUM=$(sed -E 's|.*/pull/([0-9]+)$|\1|' <<<"$PRURL")
      _VWHICH=default
      # >>> PR_CREATED verify
      # THE CREDENTIAL IS ARMED FOR THE WHOLE BLOCK (BH-781). The library reads
      # the AMBIENT gh auth, so capturing a token and resetting it immediately —
      # what this gate did while it passed the value to its own reader — would
      # leave every read on the wrong identity. use_token BEFORE token_for, and
      # that order is load-bearing: the seam caches its verdict in the CALLER's
      # shell and `$(gh_repo_token_for …)` is a subshell, so asked in this order
      # the name is a cache hit and the whole gate costs one probe per slug.
      if command -v gh_repo_use_token >/dev/null 2>&1; then
        gh_repo_use_token "$_VSLUG" || true
        _VWHICH=$(gh_repo_token_for "$_VSLUG")
      fi
      # Only ever asked on a path that is about to WRITE an alert: composing the
      # sentence costs a probe of the rungs the ladder did not need, and the
      # point of BH-765 is to stop spending requests nobody reads.
      _vtried() { command -v gh_repo_tried_words >/dev/null 2>&1 && printf ' (%s)' "$(gh_repo_tried_words "$_VSLUG")"; }
      _VRELABEL=""; _VWHY=""
      if [ "$_VWHICH" = none ]; then
        # No identity can see the repo, so there is no read to make: a 404 from
        # a credential that cannot see the repo is the 2026-09-12 shape and may
        # never be read as "no such PR". Fail open — the RESULT stands.
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] repo $_VSLUG is INVISIBLE to the default gh token$(_vtried) — $KEY's PR_CREATED ($PRURL) could NOT be verified and is left as-is, NOT relabeled (2026-09-12 shape)"
        say "UNVERIFIABLE $KEY: no identity can see $_VSLUG — RESULT left as PR_CREATED"
      elif ! command -v gh_rest_pr_state >/dev/null 2>&1; then
        # A box whose sync has not landed bin/lib/gh-rest.sh. There is no read,
        # so there is no answer: this is rc 75 by another route, and it takes
        # the rc-75 treatment — RESULT untouched, one alert, next tick retries.
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: PR_CREATED ($PRURL) could NOT be verified — bin/lib/gh-rest.sh is not on this box, so there is no REST reader to ask. The RESULT is left as-is, NOT relabeled; the next reap retries. The build record is at $LOCAL"
        say "UNVERIFIABLE $KEY: bin/lib/gh-rest.sh absent — RESULT left as PR_CREATED"
      else
        # A PLAIN COMMAND WITH `> file`, never `$( )`: GH_REST_STATUS is set in
        # the shell that CALLS the helper, and a command substitution takes it
        # to the subshell's grave. BH-781 is the build that got this wrong and
        # made every alert say "HTTP 000" for a 403 the library had classified.
        _VOUT=$(mktemp "${TMPDIR:-/tmp}/pool-prstate.XXXXXX") || _VOUT=""
        if [ -z "$_VOUT" ]; then
          # EVERY unverifiable path writes exactly one ALERTS line, including
          # this one: a `say` goes to the pool log nobody greps, and a box that
          # cannot mktemp leaves every PR_CREATED unverified in silence. The
          # status is set by hand because no request was made — 000 with a
          # reason is what the library itself writes when it never reached the
          # wire, so the line reads the same as any other skip.
          GH_REST_STATUS=000; GH_REST_REASON=no-tmp
          gh_rest_alert "$P" "$KEY PR_CREATED" "$PRURL"
          say "UNVERIFIABLE $KEY: no temp file for the PR read — RESULT left as PR_CREATED"
        else
        gh_rest_pr_state "$_VSLUG" "$_VNUM" > "$_VOUT"; _VRC=$?
        _VSTATE=$(cat "$_VOUT" 2>/dev/null); rm -f "$_VOUT"
        case "$_VRC" in
          0)
            case "$_VSTATE" in
              open|merged) ;;   # verified: RESULT untouched, nothing logged
              closed) _VRELABEL="a CLOSED, unmerged PR"; _VWHY="CLOSED" ;;
              *) _VUNREADABLE=1 ;;
            esac ;;
          44)
            # "No such PR" and "this token cannot see the repo" are different
            # facts (2026-09-12): the second relabeled six REAL PRs as
            # RESULT_UNVERIFIED on 2026-09-11 with an alert that blamed a
            # builder death. So a 404 is only believed once the same identity
            # has answered 2xx for the REPO — and that probe reads its own
            # status too, so a rate-limited probe cannot pass for a visible one.
            gh_rest GET "repos/$_VSLUG" > /dev/null; _PRC=$?
            case "$_PRC" in
              0)  _VRELABEL="no such PR (REST 404, repo visible to the $_VWHICH token)"; _VWHY="ABSENT 404" ;;
              44) HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] repo $_VSLUG is INVISIBLE to the $_VWHICH gh token$(_vtried) — $KEY's PR_CREATED ($PRURL) could NOT be verified and is left as-is, NOT relabeled; fix that token's access to the repo (2026-09-12 shape)"
                  say "UNVERIFIABLE $KEY: repo $_VSLUG invisible to the $_VWHICH gh token — RESULT left as PR_CREATED" ;;
              *)  gh_rest_alert "$P" "$KEY PR_CREATED repo-probe" "$PRURL"
                  say "UNVERIFIABLE $KEY: the repo probe for $_VSLUG answered HTTP $GH_REST_STATUS — RESULT left as PR_CREATED" ;;
            esac ;;
          *) _VUNREADABLE=1 ;;
        esac
        if [ "${_VUNREADABLE:-0}" = 1 ]; then
          # ONE line, naming the HTTP status the library classified and WHICH
          # identity answered. Never the words "no such PR", never a relaunch,
          # never a requeue change: the RESULT is byte-identical.
          gh_rest_alert "$P" "$KEY PR_CREATED" "$PRURL"
          say "UNVERIFIABLE $KEY: HTTP $GH_REST_STATUS reading $PRURL with the $_VWHICH token — RESULT left as PR_CREATED"
          _VUNREADABLE=0
        fi
        fi
      fi
      if [ -n "$_VRELABEL" ]; then
        # printf, not sed: RESULT lines legitimately carry '|' (QA/migration
        # gate notes), which breaks any sed delimiter choice.
        { printf 'RESULT_UNVERIFIED %s\n' "$RLINE"; tail -n +2 "$LOCAL/RESULT"; } > "$LOCAL/RESULT.new" \
          && mv "$LOCAL/RESULT.new" "$LOCAL/RESULT"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: reaped RESULT claims PR_CREATED but GitHub answers $_VRELABEL at '$PRURL' — rewritten RESULT_UNVERIFIED (stale RESULT after a builder death?); the alert medic (bin/alerts-medic.sh) owns this line; the build record is at $LOCAL"
        say "UNVERIFIED $KEY: PR_CREATED did not check out against GitHub ($PRURL -> $_VWHY)"
      fi
      command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
      # <<< PR_CREATED verify
      fi   # end: field 2 is a PR URL
    fi
    # <<< pr verify gate
    # The row this key was claimed under is CLOSED HERE, before the machine is
    # reused or destroyed and before any relay is attempted: a row left
    # `claimed` can never be queued again, and one left `queued` would be
    # materialised into a second build of work that has just finished.
    # >>> reap row close (BH-614)
    # ...but a build that opened NO PR is not finished work, and `done` is the
    # queue saying it was. Both failed-create words close the row FAILED: the
    # ratchet's own PR_CREATE_FAILED and the RESULT_MALFORMED the shape gate
    # above writes for an older image's url-less claim. RESULT_UNVERIFIED keeps
    # closing `done` — that is a PR nobody could READ, which the alert medic
    # owns, not a create that failed. bin/blocked-resolver.sh deliberately does
    # NOT read this row: the RECORD is its intake, behind a 90-minute floor that
    # is bin/pr-url-reconcile.sh's window to prove the PR did open after all.
    case "$(head -1 "$LOCAL/RESULT")" in
      PR_CREATE_FAILED*|"RESULT_MALFORMED PR_CREATED"*) QROW failed "$KEY" "$(head -c 200 "$LOCAL/RESULT")" ;;
      *)                                                QROW done   "$KEY" "$(head -c 200 "$LOCAL/RESULT")" ;;
    esac
    # <<< reap row close
    say "reaped $KEY from $MID: $(head -c 80 "$LOCAL/RESULT")"
    beat_json=$(jq -nc --arg p "$P" --arg k "$KEY" --arg r "$(head -c 120 "$LOCAL/RESULT")" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_result",detail:$r}')
    "$HARNESS/bin/beat.sh" "$beat_json" >/dev/null 2>&1 || true
    command -v ppr_after_reap >/dev/null 2>&1 && { ppr_after_reap || true; }
    mkdir -p "$HARNESS/state/remote-results/$P"
    # machine_build_dir IS THE CROSS-PATH IDENTITY (BH-1041) — the dir the
    # MACHINE built in, which is also what this build's ledger row is named
    # after. `result` here is truncated at 200 bytes and `build_dir` is the
    # hub's own path, so neither could ever be compared with the row.
    MBDIR=$(grep -oE '^BUILD_DIR: .*' "$LOCAL/RESULT" | sed 's/^BUILD_DIR: //' | head -1)
    jq -nc --arg k "$KEY" --arg t "$TICKET" --arg d "$LOCAL" --arg r "$(head -c 200 "$LOCAL/RESULT")" \
      --arg mbd "${MBDIR:-}" \
      '{key:$k,ticket_id:$t,build_dir:$d,result:$r,machine_build_dir:$mbd}' > "$HARNESS/state/remote-results/$P/$KEY.json"
    # BH-7519: the reap park. On a lane-run machine this record and the build
    # dir are only here until a write-back carries them home, and the run-end
    # write-back is not reached by a machine that stops hard. Post it now.
    command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "reap park $KEY"
    # ---- relay to the owning box (2026-08-16, TK-124 stranding) --------------
    # Only project-1 triage runs on the hub, so a non-local project's result
    # parked in the hub's state/remote-results strands forever (PR #318 sat a
    # day until the medic hand-delivered it). Same hand-off fly-results-ingest
    # has had all along: json in the ingest shape + RESULT/review/plan into the
    # box's own build dir, tier-1 APPROVE onto the box merge-queue. On success
    # the hub json is removed (the box copy is live) and the hub dir is stamped
    # RELAYED so pipeline-health's close-out checks know custody moved; on any
    # failure the hub json stays for hand delivery and ONE ALERTS line says so.
    # THE ADDRESS COMES FROM THE REGISTRY (2026-09-11). This was a four-entry
    # case table, one of nine copies across bin/ — a box that moved had to be
    # found in all nine. fleet.conf carries `tailnet_ip` now. Unknown fails
    # CLOSED: no address, no ssh, because an empty target is `root@` and that
    # hangs rather than errors.
    RBOX=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$P" 2>/dev/null) || RBOX=""
    # The record's OWN pr, never the first url on it: a failed create folded the
    # STACKED note's PARENT url into line 1 and this grep relayed it as the
    # build's PR (BH-848). No lib on this hub yet = the grep it always did.
    if command -v result_own_pr_url >/dev/null 2>&1; then
      RPR=$(result_own_pr_url "$LOCAL/RESULT" || true)
    else
      RPR=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$LOCAL/RESULT" | head -1)
    fi
    RTIER=$(grep -oE '^TIER: [12]' "$LOCAL/RESULT" | grep -oE '[12]' | head -1)
    RVERDICT=$(verdict_parse -L "$LOCAL/review.md" 2>/dev/null) || RVERDICT=""

    # ---- ROW FIRST, ssh ONLY IF THE ROW IS NOT THERE (2026-09-11) -----------
    # The box already PULLS this result: bin/run-triage.sh's ledger staging loop
    # reads the `result` artifact and stages the same build dir, with the
    # one-dir guard that stops it and the ssh push both landing. So both paths
    # have been running and the guard has been deduping them. This makes the
    # ssh push what it should be — a fallback for the case where the ledger did
    # not take the result.
    #
    # READ BACK, do not assume. The artifact is written by run-build.sh ON THE
    # MACHINE, not here, so "the row exists" is something this reap can only
    # learn by asking. A write we did not make and did not verify is exactly
    # the kind of assumption that would silently strand a close-out.
    # THREE OUTCOMES, NOT TWO, and they are genuinely different failures:
    #   FEED_OK=0   the ledger could not be read at all — say nothing about what
    #               it contains. Unknown is not "absent".
    #   RES_ROW=0   the ledger answered and this build's result is NOT in it.
    #   RES_ROW=1   the result is there and the box will pull it.
    # Collapsing the first two into one message sends a human to look for a
    # missing row when the real fault is a dead worker, or the reverse — and
    # until BH-1041 it also sent the same ssh push for both, which is the
    # duplicate close-out this ticket removes. bin/lib/builder-direct.sh's
    # bd_result_in_ledger is the one place the three answers are decided now;
    # this reap and the hub's ingest read the same rc.
    #
    # FEED_ASKABLE separates "the ledger blinked" from "this hub has no jobs
    # client at all". The second can never answer, so deferring on it would
    # defer for ever: it pushes over ssh exactly as this reap always has.
    FEED_OK=0; RES_ROW=0; FEED_ASKABLE=0
    if command -v job_artifact_feed >/dev/null 2>&1 \
       && command -v bd_result_in_ledger >/dev/null 2>&1; then
      FEED_ASKABLE=1
      # MBDIR (the machine's own build dir, read off the RESULT above) is what
      # makes this "is THIS BUILD's row there", not "is a row for this ticket
      # key there" — a second build of a key whose first build has a row would
      # otherwise read as delivered and never be relayed (BH-1041 round-1).
      bd_result_in_ledger "$P" "$KEY" "$(head -1 "$LOCAL/RESULT")" "${MBDIR:-}"
      case "$?" in
        0) FEED_OK=1; RES_ROW=1 ;;
        1) FEED_OK=1 ;;
        *) ;;
      esac
    fi

    # The tier-1 APPROVE hand-off is a ROW too (#224). Its failure counts as the
    # ledger not having taken this result: a merge that never gets queued is
    # invisible, which is the one outcome worth an ssh for.
    # The tier-1 APPROVE hand-off is a ROW too (#224). A FAILED merge row is its
    # own fault and its own remedy: the RESULT is still in the ledger and the box
    # will still pull it, so re-pushing the whole result over ssh would be a
    # duplicate of work that is already travelling. Only the merge-queue touch
    # is missing, so only the merge-queue touch is sent.
    RPRNUM=""; MQ_NEEDED=0; MQ_ROW=0
    if [ "${RTIER:-}" = "1" ] && [ "${RVERDICT:-}" = "APPROVE" ] && [ -n "$RPR" ]; then
      RPRNUM=$(grep -oE '[0-9]+$' <<<"$RPR")
      if [ -n "$RPRNUM" ]; then
        MQ_NEEDED=1
        if command -v merge_queue_put >/dev/null 2>&1 \
           && merge_queue_put "$P" "$RPRNUM" "" "tier-1 APPROVE from pool build $KEY" >/dev/null 2>&1; then
          MQ_ROW=1
          say "tier-1 APPROVE $KEY -> merge_queue row for #$RPRNUM (no ssh touch)"
        fi
      fi
    fi

    # ONE ALERT PER PROJECT PER DAY, PER REASON. The dated flag carries the
    # reason so a merge-row failure cannot silence a dead ledger, or the other
    # way round — they are different outages with different remedies.
    PR_ALERT() { # PR_ALERT <reason-slug> <line>
      local f="$HARNESS/flags/alerted-pool-relay-$1-$P-$(date -u +%Y%m%d)"
      say "$KEY: $2"
      [ -f "$f" ] && return 0
      mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$f" 2>/dev/null
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $2"
      return 0
    }

    # The merge-queue touch failed twice (mq_touch). Its own reason slug, so the
    # mergerow flag of the same day cannot swallow it; PR_ALERT's say line puts
    # every affected key, rc included, in fly-pool.log after the flag is set.
    MQT_RC=0
    MQ_TOUCH_FAILED() {
      PR_ALERT mergetouch "MERGE-QUEUE TOUCH FAILED — the tier-1 APPROVE for #$RPRNUM ($KEY) is queued NOWHERE: the merge_queue row failed and the ssh touch to $RBOX failed rc=$MQT_RC after one retry. Deliver it by hand: ssh root@$RBOX touch /root/harness/state/merge-queue/$P/$RPRNUM. (One alert per project per day; every affected key is in fly-pool.log.)"
    }

    RELAY_MODE=none
    if [ "$FEED_OK" = 0 ] && [ "$FEED_ASKABLE" = 1 ]; then
      RELAY_MODE=defer
      PR_ALERT unreadable "LEDGER UNREADABLE — the coordination DB did not answer, so nothing was pushed for $KEY: the result is held hub-side in $LOCAL + state/remote-results/$P/$KEY.json, re-asked every pool tick, and nothing goes to the box until the ledger answers. Pushing on an unknown is how one build became two close-out comments on a client's ticket. Check worker/jobs + HARNESS_SECRET. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$FEED_OK" = 0 ]; then
      RELAY_MODE=full
      PR_ALERT unreadable "LEDGER UNREADABLE — this hub has no jobs client at all, so the result for $KEY was pushed to ${RBOX:-no box} over ssh instead. Results are NOT lost; the row path is. Check that bin/jobs-client.sh and bin/lib/builder-direct.sh are synced onto this box. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$RES_ROW" = 0 ]; then
      RELAY_MODE=full
      PR_ALERT noresultrow "NO RESULT ROW — the ledger answered but carries no result for $KEY, so it was pushed to ${RBOX:-no box} over ssh instead. The build's own run-build.sh did not record its result artifact. (One alert per project per day; every affected key is in fly-pool.log.)"
    elif [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ]; then
      # The result travels by row; ONLY the merge enqueue needs a hand.
      RELAY_MODE=touch
      PR_ALERT mergerow "MERGE-QUEUE ROW FAILED — the result for $KEY is in the ledger and the box will pull it, but the tier-1 APPROVE for #$RPRNUM could not be enqueued as a row, so only the merge-queue touch went over ssh. (One alert per project per day; every affected key is in fly-pool.log.)"
    fi

    if [ "$RELAY_MODE" = none ]; then
      # Custody moved through the LEDGER. The hub json stays where it is: nothing
      # was pushed, so nothing has provably arrived, and deleting the hub-side
      # copy on the strength of a row the box has not read yet would throw away
      # the only other copy. RELAYED still marks custody for the close-out
      # checks (bin/queued-fly-relayed.sh).
      touch "$LOCAL/RELAYED"
      say "result $KEY is in the ledger (tier=${RTIER:-?} verdict=${RVERDICT:-?}) — no ssh push; the box pulls it"
    elif [ "$RELAY_MODE" = defer ]; then
      # ---- HELD: THE LEDGER COULD NOT BE ASKED (BH-1041) ---------------------
      # NOTHING is pushed and NOTHING is stamped. RELAYED would say custody
      # moved, and it has not. The hub json written above stays where it is —
      # it and this dir are the whole record until the ledger answers — and
      # pool_relay_retry re-asks at the top of every tick.
      touch "$LOCAL/RELAY_DEFERRED"
      say "$KEY held hub-side: the ledger could not be asked whether its result is already a row, so nothing was pushed. Re-asked every tick; the record is at $LOCAL"
      # The merge enqueue needs no ledger, so it still rides: a tier-1 APPROVE
      # whose #224 row failed would otherwise wait out the whole outage.
      if [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ] && [ -n "$RPRNUM" ] && [ -n "$RBOX" ]; then
        mq_touch "$RBOX" "$P" "$RPRNUM"; MQT_RC=$?
        [ "$MQT_RC" = 0 ] || MQ_TOUCH_FAILED
      fi
    elif [ -n "$RBOX" ]; then
      # The merge-queue touch rides BOTH fallbacks, and only when the row did
      # not take it: a successful #224 row needs no filename.
      if [ "$MQ_NEEDED" = 1 ] && [ "$MQ_ROW" = 0 ] && [ -n "$RPRNUM" ]; then
        mq_touch "$RBOX" "$P" "$RPRNUM"; MQT_RC=$?
        [ "$MQT_RC" = 0 ] || MQ_TOUCH_FAILED
      fi

      if [ "$RELAY_MODE" = touch ]; then
        # The RESULT is travelling by row, so the hub json stays exactly as it
        # does on the row path and custody is still the ledger's.
        touch "$LOCAL/RELAYED"
        if [ "$MQT_RC" = 0 ]; then
          say "merge-queue touch for #$RPRNUM sent to $RBOX; the result itself travels by row"
        else
          say "merge-queue touch for #$RPRNUM to $RBOX FAILED rc=$MQT_RC; the result itself travels by row"
        fi
      else
        # ---- FULL FALLBACK: the ledger has no usable result for this build ---
        # The push, the hub-json removal, the RELAYED stamp and the failure
        # alert all live in pool_push_full, so the deferral retry above does
        # exactly what this reap does rather than a near-copy of it.
        pool_push_full "$P" "$KEY" "$TICKET" "$LOCAL" "$RBOX" "${RPR:-}" "${RTIER:-}"
      fi
    else
      # No row AND no address: the result stays hub-side and says so loudly.
      # This is the fail-closed end of the registry lookup — never `root@`.
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: the ssh fallback is needed ($RELAY_MODE) and $P has no tailnet_ip in fleet.conf — parked hub-side in state/remote-results/$P/$KEY.json + $LOCAL for hand delivery"
      say "$KEY needs the $RELAY_MODE fallback and there is no tailnet_ip for $P — parked hub-side"
    fi
    next_job_or_destroy
    continue
  fi
  # liveness: machine gone or heartbeat stale -> requeue
  DEAD=0
  # `failed` and `suspended` are deaths too (BH-660). They used to fall through
  # to the heartbeat probe, whose mexec cannot reach a machine that is not
  # started: HB came back empty, DEAD stayed 0, and the file and the machine both
  # survived the tick — for ever, tick after tick, with the job never requeued.
  case "$MSTATE" in ""|stopped|destroyed|failed|suspended) DEAD=1 ;; esac
  if [ "$DEAD" = 0 ]; then
    HB=$(mexec "$MID" 'now=$(date +%s); h=$(stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0); echo $((now-h))' | tr -dc '0-9')
    [ -n "$HB" ] && [ "$HB" -gt 900 ] && DEAD=1
  fi
  # BH-7107: a HOLD or a closed issue cancels this live build once the verdict
  # has stood POOL_INFLIGHT_HOLD_GRACE_S, and releases its slot.
  if [ "$DEAD" = 0 ] && command -v pool_inflight_hold_step >/dev/null 2>&1 && pool_inflight_hold_step; then continue; fi
  if [ "$DEAD" = 0 ]; then
    # A live machine may be most of the way through its token's hour — replace it
    # before the push that would otherwise be rejected, not after.
    rotate_gh_token "$MID" "$MF"
    # Preview-snapshot refresh (2026-08-13): wait-preview.sh on the machine
    # resolves QA preview URLs from state/vercel-deploys/<project>.json (the
    # Deployments API 403s the fleet PAT). One mput per live machine per tick,
    # and only when the hub copy's mtime moved — tracked in a dotfile sidecar
    # (invisible to this loop's *.json glob).
    SNAP_SRC="$HARNESS/state/vercel-deploys/$P.json"
    if [ -s "$SNAP_SRC" ]; then
      SNAP_MT=$(stat -c %Y "$SNAP_SRC" 2>/dev/null || echo 0)
      LAST_MT=$(cat "$POOL/.$MID.snapmt" 2>/dev/null || echo 0)
      if [ "$SNAP_MT" != "$LAST_MT" ]; then
        mput "$MID" "$SNAP_SRC" "/data/harness/state/vercel-deploys/$P.json" \
          && echo "$SNAP_MT" > "$POOL/.$MID.snapmt"
      fi
    fi
  fi
  if [ "$DEAD" = 1 ]; then
    NEXT=$((ATT+1))
    # The park is decided on DNEXT (deaths this loop has OBSERVED, including
    # this one), never on NEXT (the enqueuer's attempt number). `attempt` is
    # still carried forward untouched so every existing reader — the dispatcher,
    # the ledger, bin/jobs-watchdog.sh — sees exactly what it always did.
    DNEXT=$((DTHS+1))
    # The disposition is named here because an RB- key is NOT requeued (the arm
    # below): announcing a requeue that never happens is how a log stops being
    # evidence. Every other key reads byte-for-byte the line it always did.
    DDISP="requeue attempt=$NEXT deaths=$DNEXT"
    case "$KEY" in RB-*) DDISP="rebase row FAILED, not requeued" ;; RR-*) DDISP="re-review row FAILED, not requeued" ;; CP-*) DDISP="console preview row FAILED, not requeued" ;; esac
    # A JOB THAT FINISHED NEVER GETS HERE (BH-2643, BH-7719): a not-started
    # machine whose own pool-result row carries a result was reaped from that
    # row above. What reaches this line has no result at all.
    DWORD="died"; DKIND="dead machine"
    say "machine $MID for $KEY dead (state=${MSTATE:-gone}) attempt=$ATT deaths=$DTHS -> $DDISP"
    destroy_machine "$MID" "$DKIND for $KEY (state=${MSTATE:-gone})"
    # The dead machine's Fly seconds too (BH-7719): nothing else bills them.
    # A temp dir stands in for the build dir; ledger.tsv keeps it to one row.
    # Its own name, not $LOCAL: $LOCAL is a $HARNESS build dir everywhere else.
    if DCOST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pool-dead-cost.XXXXXX" 2>/dev/null); then
      LOCAL="$DCOST_DIR"
      pool_fly_cost_row || true
      push_pool_cost_rows "$LOCAL" "pool-${P}-${MID}"
      case "$DCOST_DIR" in */pool-dead-cost.*) rm -rf -- "$DCOST_DIR" ;; esac
    else
      say "fly cost row: skipped:no-temp-dir $MID $KEY"
    fi
    LOCAL=""
    # Same rule as next_job_or_destroy: the row is closed and the job requeued
    # whatever the destroy answered, and the sweep is what recovers the machine.
    rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.puterr"
    # >>> machines rows (BH-1035)
    # Close the registry row using the actual destroy outcome.
    machines_row_close "$MID"
    # <<< machines rows
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    # A DEAD REBASE IS FAILED, NEVER REQUEUED (BH-542) — the same reasoning the
    # deferral arm above states, for the same reason: both branches below
    # rebuild the queue file from the machine json, which carries no `rebase`,
    # so the next machine would run an ordinary BUILD of ticket $TICKET (= the
    # PR number). This runs BEFORE the `DNEXT -ge 2` park, so no
    # `$QDIR/$KEY.failed.json` is written at either death count —
    # br_from_queue turns every one of those into a pool-died-twice rebuild of
    # the same ticket. The reason matches neither `died N times` nor
    # `deferred N times`, br_from_queue's two row triggers. The machine is
    # already destroyed and its file removed, exactly as for any other key.
    # Recovery is the hub job file, not this pool: mc_pool_rebase_fail marks it
    # `failed` so the conductor parks the PR in NEEDS_REBASE on its next tick
    # (BH-986 — the old text promised a re-enqueue that could not happen for up
    # to MC_REBASE_POOL_TIMEOUT_SECS).
    case "$KEY" in
      RB-*)
        RBREC="no hub rebase job file could be marked failed, so recovery waits for the pool timeout (MC_REBASE_POOL_TIMEOUT_SECS, default 5400s) to fail the job, and then the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) before a fresh rebase can be queued"
        fp_mc_lib_load || true
        if command -v mc_pool_rebase_fail >/dev/null 2>&1 \
           && mc_pool_rebase_fail "$P" "$KEY" "the pool machine died (state=${MSTATE:-gone}) with no RESULT"; then
          RBREC="the hub rebase job file for this PR is marked failed, so bin/merge-conductor.sh parks the PR back in NEEDS_REBASE on its next tick; the NEEDS_REBASE TTL (MC_TTL_NEEDS_REBASE, default 1800s) is then what forgets this head's attempt and lets a later tick queue a fresh rebase"
        fi
        QROW failed "$KEY" "rebase machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: rebase machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no rebase object, and the next machine would run an ordinary BUILD of ticket $TICKET. $RBREC; nothing here retries."
        continue ;;
      RR-*)
        # A DEAD RE-REVIEW is failed and never requeued, for the reason above;
        # its hub job file goes lane-failed (BH-7635): a dead machine is our
        # outage, so the PR loses no strike and the conductor retries the read.
        RRREC="no hub re-review job file could be marked lane-failed, so the conductor finds no job for this head and decides again on a later tick"
        fp_mc_lib_load || true
        if command -v mc_pool_rereview_fail >/dev/null 2>&1 \
           && mc_pool_rereview_fail "$P" "$KEY" "the pool machine died (state=${MSTATE:-gone}) with no RESULT"; then
          RRREC="the hub re-review job file for this head is marked lane-failed, so the conductor retries the read on its next tick with no strike on the PR (MC_RR_LANEFAIL_MAX)"
        fi
        QROW failed "$KEY" "re-review machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] $KEY: re-review machine $MID died (state=${MSTATE:-gone}) with no RESULT — the queue row is FAILED and NOT requeued, because a requeue rebuilds the queue file from the machine json, which carries no rereview object, and the next machine would run an ordinary BUILD of ticket $TICKET. $RRREC; nothing here retries."
        continue ;;
      CP-*)
        # A DEAD CONSOLE PREVIEW is failed and never requeued (BH-8030), for
        # the reason above. The hub lane reads the failed row as the box's
        # fault, alerts once, and queues a new row on its next tick.
        QROW failed "$KEY" "console preview machine $MID died (state=${MSTATE:-gone}); row FAILED, not requeued"
        continue ;;
    esac
    if [ "$DNEXT" -ge 2 ]; then
      QROW failed "$KEY" "died $DNEXT times (state=${MSTATE:-gone}) — parked for the blocked-resolver"
      # THE ROW ON THE LINE ABOVE IS THE PARK (BH-1026.3). Under the flag $QDIR
      # is this tick's scratch directory, so a sidecar written here would vanish
      # with it — and it is not needed: br_from_queue reads the `died N times`
      # reason the QROW just wrote, and bin/healthcheck.sh counts the same rows.
      # REDUNDANT BY CONSTRUCTION TODAY, and deliberately kept: ROWS_ONLY=1 can
      # only be true when $QDIR is the temp dir, so this is belt and braces
      # against a later change that points $QDIR back at state/build-queue/<p>/
      # and silently starts writing parks into it again.
      [ "${ROWS_ONLY:-0}" = 1 ] || \
        jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$NEXT" --argjson d "$DEFC" --argjson x "$DNEXT" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.failed.json"
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg akey "pool-fail:$P:$KEY" --arg l "Pool build $KEY died $DNEXT times — row FAILED, handed to bin/blocked-resolver.sh for a fresh rebuild against current main." '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    else
      if QROW requeue "$KEY" "machine ${MID} $DWORD (state=${MSTATE:-gone})" "$NEXT" "$(jq -nc --argjson d "$DEFC" --argjson x "$DNEXT" --arg sb "$SBASE" --arg hf "$MHF" '{deferrals:$d,deaths:$x} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)')" "$TICKET"; then
      jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$NEXT" --argjson d "$DEFC" --argjson x "$DNEXT" --arg ts "$(STAMP)" --arg sb "$SBASE" --arg hf "$MHF" '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,deaths:$x,enqueued_at:$ts} + (if $sb == "" then {} else {stack_base:$sb} end) + (if $hf == "true" then {hotfix:true} else {} end)' > "$QDIR/$KEY.json"
      else
        say "$KEY: machine ${MID} died (state=${MSTATE:-gone}) — abandoned by an operator, not requeued"
      fi
    fi
  fi
done
# BH-7475: a stop in the REAP walk ends the tick here. Unvisited machines keep
# their files for the next tick; the sweep and the spawn walk wait for it too.
if [ -n "${PTS_STOP:-}" ]; then wait; exit 0; fi

# >>> dead-machine sweep (BH-660)
# THE SWEEP fly/builder-runner.sh:459-462 has been promising since wave 3 ("a
# stopped pool machine is then destroyed by fly-pool.sh's dead-machine sweep").
# It was never written. The REAP above only ever visits machines that have a
# tracking file, so the moment a destroy failed — or a machine was spawned by a
# rollout smoke run, or reaped by a tick that then lost its file — the machine
# left the harness's field of view entirely and idled to a `stopped` state
# nothing looked at again. BH-660 counted 18 of them across two pools.
#
# It lives HERE rather than in a second cleaner script on its own cron line: same
# tick, same flock, same listing, same destroy helper the reap uses. Two cleaners
# racing one app is the sprawl this pool already learned about.
#
# It runs ONLY with a dedicated pool app (SPRAWL GUARD, above) and ONLY on a
# usable listing.
if [ -n "${POOL_APP:-}" ]; then
  SWEEP_F="$POOL/.sweep.json"   # dotfile: invisible to every *.json glob that reads this dir
  if [ "$LIST_OK" != 1 ]; then
    jq -nc --arg at "$(STAMP)" --arg why "${LIST_WHY:-no answer}" \
      '{at:$at,listing:"failed",reason:$why}' > "$SWEEP_F.tmp" 2>/dev/null \
      && mv "$SWEEP_F.tmp" "$SWEEP_F" || rm -f "$SWEEP_F.tmp"
  else
    # KNOBS, resolved once per tick, with the fallback documented in
    # docs/verification-map/fly-pool-sweep.md. A value that is not a number is
    # never silently clamped — it is named in the log and the fallback is used.
    pool_knob() { # pool_knob <env-value> <setting-key|""> <default> <label>
      local v="${1:-}" key="${2:-}" def="$3" label="$4"
      case "$v" in
        '') ;;
        *[!0-9]*) say "ignoring unusable $label='$v' (not a number) — falling back" ;;
        *) printf '%s\n' "$v"; return 0 ;;
      esac
      if [ -n "$key" ] && command -v setting_get >/dev/null 2>&1; then
        v=$(setting_get "$key" 2>/dev/null) || v=""
        case "$v" in
          '') ;;
          *[!0-9]*) say "ignoring unusable setting $key='$v' (not a number) — falling back to the documented default $def" ;;
          *) printf '%s\n' "$v"; return 0 ;;
        esac
      fi
      printf '%s\n' "$def"
    }
    TTL_S=$(pool_knob "${POOL_STOPPED_TTL_S:-}" pool_stopped_ttl_s 600 POOL_STOPPED_TTL_S)
    MAX_D=$(pool_knob "${POOL_SWEEP_MAX_DESTROY:-}" "" 25 POOL_SWEEP_MAX_DESTROY)
    NOWS=$(date -u +%s)
    SW_STOPPED='[]'; SW_UNAGED='[]'; SW_DESTROYED='[]'; SW_FAILED='[]'; SW_ORPHANS='[]'
    NLISTED=0; NSTOP=0; NUNAGED=0; NDESTROY=0; NFAIL=0; NORPH=0; NSPENT=0; CAPPED=false
    jq -r '.[] | [(.id // ""),(.state // ""),(.updated_at // "")] | @tsv' "$LISTING" 2>/dev/null > "$LISTING.rows"
    while IFS=$'\t' read -r SID SST SUP; do
      [ -n "$SID" ] || continue
      NLISTED=$((NLISTED+1))
      # A machine the REAP owns this tick is never the sweep's to touch. Its file
      # is the reap's claim on it; if the reap's own destroy failed, the file is
      # gone by now and this sweep picks the machine up on a later tick, once it
      # has actually stopped.
      [ -f "$POOL/$SID.json" ] && continue
      case "$REAPED_IDS" in *" $SID "*) continue ;; esac
      # Everything that is running, booting or already on its way out is left
      # alone — including bin/fly-pool-rollout.sh's untracked `started` smoke
      # machine, which is somebody else's in-flight work.
      case "$SST" in stopped|failed|suspended|destroyed) ;; *) continue ;; esac
      # AN UNKNOWN AGE IS NOT AN OLD AGE. A machine whose updated_at is missing or
      # unparseable is reported, never destroyed: this gate stands in front of an
      # irreversible call.
      SAGE=-1
      if [ -n "$SUP" ]; then
        SEP=$(date -u -d "$SUP" +%s 2>/dev/null) || SEP=""
        case "$SEP" in ''|*[!0-9]*) SEP="" ;; esac
        [ -n "$SEP" ] && SAGE=$((NOWS - SEP))
      fi
      if [ "$SAGE" -lt 0 ]; then
        SW_UNAGED=$(jq -c --arg m "$SID" '. + [$m]' <<<"$SW_UNAGED"); NUNAGED=$((NUNAGED+1)); continue
      fi
      if [ "$SAGE" -lt "$TTL_S" ] || [ "$NSPENT" -ge "$MAX_D" ]; then
        [ "$SAGE" -ge "$TTL_S" ] && CAPPED=true
        SW_STOPPED=$(jq -c --arg m "$SID" --arg s "$SST" --argjson a "$SAGE" \
          '. + [{machine:$m,state:$s,age_s:$a}]' <<<"$SW_STOPPED"); NSTOP=$((NSTOP+1)); continue
      fi
      if destroy_machine "$SID" "swept: $SST for ${SAGE}s"; then
        SW_DESTROYED=$(jq -c --arg m "$SID" '. + [$m]' <<<"$SW_DESTROYED")
      else
        SW_FAILED=$(jq -c --arg m "$SID" --argjson rc "${DESTROY_RC:-1}" --arg e "${DESTROY_ERR:-}" \
          '. + [{machine:$m,rc:$rc,error:$e}]' <<<"$SW_FAILED"); NFAIL=$((NFAIL+1))
      fi
      # >>> machines rows (BH-1035)
      # Close the sweep machine row from the actual destroy outcome. Placed
      # after the if/else so BOTH arms close: a destroy the API refused is a
      # `destroy_failed` row, not a missing one.
      machines_row_close "$SID"
      # <<< machines rows
      # A refused destroy spent the same API call a successful one did, so it
      # counts against the per-tick bound either way.
      NSPENT=$((NSPENT+1))
    done < "$LISTING.rows"
    NDESTROY=$(jq -r 'length' <<<"$SW_DESTROYED")
    # ORPHANS: a job still tracked on a machine Fly no longer returns, AFTER the
    # reap has run. Normally none — the reap's dead path closed them. One that
    # survives is a job nothing will ever finish, so it pages — once per tick,
    # after the loop: pool/*.json has no bound when the cap is unlimited, and a
    # partial Fly listing orphans every row at once.
    ORPH=()
    for OMF in "$POOL"/*.json; do
      [ -f "$OMF" ] || continue
      OMID=$(jq -r '.machine // ""' "$OMF" 2>/dev/null)
      [ -n "$OMID" ] && [ "$OMID" != null ] || continue
      jq -e --arg m "$OMID" 'any(.[]; .id==$m)' "$LISTING" >/dev/null 2>&1 && continue
      OKEY=$(jq -r '.key // ""' "$OMF" 2>/dev/null); OTIC=$(jq -r '.ticket_id // ""' "$OMF" 2>/dev/null)
      SW_ORPHANS=$(jq -c --arg m "$OMID" --arg k "$OKEY" --arg t "$OTIC" \
        '. + [{machine:$m,key:$k,ticket_id:$t}]' <<<"$SW_ORPHANS"); NORPH=$((NORPH+1))
      OAF="$HARNESS/flags/alerted-pool-orphan-$P-$OKEY-$(date -u +%Y%m%d)"
      if [ ! -f "$OAF" ]; then
        mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$OAF" 2>/dev/null
        ORPH+=("$OKEY still tracked on $OMID")
      fi
    done
    if [ "${#ORPH[@]}" = 1 ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] ${ORPH[0]} which Fly no longer returns after the reap — the dead path did not close it"
    elif [ "${#ORPH[@]}" -gt 1 ]; then
      _OJ=$(printf '%s; ' "${ORPH[@]}")
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] ${#ORPH[@]} jobs still tracked on machines Fly no longer returns after the reap — the dead path did not close them: ${_OJ%; }"
    fi
    # BH-7382: a claimed fly row of this hub with no queue file, no job file and
    # no live machine goes back to queued after POOL_ORPHAN_ROW_RELEASE_S.
    command -v pool_orphan_rows_step >/dev/null 2>&1 && pool_orphan_rows_step
    jq -nc --arg at "$(STAMP)" --argjson listed "$NLISTED" --argjson ttl "$TTL_S" \
      --argjson capped "$CAPPED" --argjson stopped "$SW_STOPPED" --argjson unaged "$SW_UNAGED" \
      --argjson destroyed "$SW_DESTROYED" --argjson df "$SW_FAILED" --argjson oj "$SW_ORPHANS" \
      '{at:$at,listing:"ok",listed:$listed,ttl_s:$ttl,capped:$capped,stopped:$stopped,
        unaged:$unaged,destroyed:$destroyed,destroy_failed:$df,orphan_jobs:$oj}' \
      > "$SWEEP_F.tmp" 2>/dev/null && mv "$SWEEP_F.tmp" "$SWEEP_F" || rm -f "$SWEEP_F.tmp"
    # ONE GREPPABLE LINE, and only when there is something to say: a count that
    # lives only in a JSON field is a count nobody reads (BH-660 asks for exactly
    # this). A clean tick stays quiet.
    if [ $((NSTOP + NUNAGED + NDESTROY + NFAIL + NORPH)) -gt 0 ]; then
      say "sweep $P: listed=$NLISTED stopped=$((NSTOP + NUNAGED)) destroyed=$NDESTROY destroy_failed=$NFAIL orphans=$NORPH ttl=${TTL_S}s$([ "$CAPPED" = true ] && echo " capped")"
    fi
  fi
fi
# <<< dead-machine sweep

# ---------- SPAWN ----------
# EVERY QUEUED JOB THIS TICK CAN AFFORD, ALL AT ONCE (the operator, 2026-09-13: "change
# the rule so we never lock and serialize"). Each spawn is ~40-60s of waiting —
# `machine run`, a 20s boot sleep, an sftp harness push, an env bundle — and this
# loop used to do them one after another inside the tick, so 14 queued jobs took
# 7 ticks (~15 min) to reach a pool that could hold them all immediately. The
# waiting is now concurrent: the budget is computed ONCE up front, that many
# subshells are launched, and each writes its own $POOL/<mid>.json exactly as
# before. Nothing takes turns, and since 2026-09-14 nothing is capped either
# unless someone wrote a number down (see the budget just below).
if [ "${POOL_SPAWN:-1}" = 0 ]; then exit 0; fi
# The lane-failure hold (2026-09-23, see POOL_LANE_FAIL_HOLD_S): while it stands
# a new machine would only meet the same exhausted lane, so nothing is spawned.
if HOLDWHY=$(pool_spawn_held); then
  say "spawn hold: the runner lane failed ($HOLDWHY) — no spawns until $(date -u -d "@$(cut -d' ' -f1 "$(pool_spawn_hold_path)" 2>/dev/null)" '+%H:%MZ' 2>/dev/null || echo 'the hold expires')"
  exit 0
fi
# LOAD SHED (BH-7509): while state/hub-load/verdict says the hub is over
# hub_load.max_runnable, this tick spawns nothing. REAP and the sweep above
# already ran; the queued job files stay for the next tick. No verdict file
# (every box but the hub, every Fly machine) or a stale one: no shed.
# shellcheck source=bin/lib/hub-load-shed.sh
. "$HARNESS/bin/lib/hub-load-shed.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/hub-load-shed.sh" 2>/dev/null \
  || hls_over() { return 1; }
if hls_over "$HARNESS"; then
  say "$HLS_LINE — no spawns this tick (reap ran)"
  exit 0
fi
LIVE=$(ls "$POOL" 2>/dev/null | wc -l)
# --- AUTOSCALE: THE QUEUE SETS THE MACHINE COUNT (the operator, 2026-09-14) -----------
# "we can launch unlimited builders with fly.io" — so the budget is the DEPTH of
# this project's queue, not a countdown to a number we picked. Every queued build
# gets its own machine THIS tick: 40 queued tickets spawn 40 machines, and they
# do not wait on a sibling project's tick either (bin/fly-pool-tick.sh ticks the
# projects together for the same reason).
# WHAT COUNTS AS QUEUED: the files in state/build-queue/<p>, which are this
# project's materialised ledger rows — bin/fly-dispatch.sh writes one per
# `queued` row and CLAIMS the row as it does — minus the *.failed.json parks. A
# job that is already running had its file moved away at spawn, so the count is
# what is genuinely waiting, and `running` below is the live machines serving
# the rest.
# An explicit cap (flags/fly-pool-<p>, fly/pool-caps.conf, POOL_CAP_MAX) still
# binds, for cost safety only; bin/pool-cap.sh prints 0 when there is none.
# KILL FLAG: POOL_AUTOSCALE=0 restores the pre-autoscale budget exactly — cap
# minus live, no queue reading, and no per-tick line.
QUEUED=$(ls "$QDIR"/*.json 2>/dev/null | grep -cv '\.failed\.json$')
# --- THE HOTFIX EXEMPTION (#368) ---------------------------------------------
# A cap is a COST ceiling, and an emergency ticket is the one row allowed past
# it — by one machine per hotfix, never a suspension of the cap: every plain job
# behind it still waits for the next tick.
#
# A PAUSE IS NOT A CAP. flags/paused-<p> is a human saying "stop building this
# project", and #368 puts overriding it explicitly out of scope — so the
# exemption is withheld there and the wait is logged instead. pool-halt-<p> (a
# health stop after repeated gate refusals) and the box slot lock are the same
# kind of decision and are likewise untouched: this block only ever adds to the
# budget a CAP produced.
HOT=0
if [ "$HOTFIX_ON" = 1 ]; then
  HOT=$(grep -l '"hotfix": *true' "$QDIR"/*.json 2>/dev/null | grep -cv '\.failed\.json$')
  case "$HOT" in ''|*[!0-9]*) HOT=0 ;; esac
fi
HOTFIX_EXTRA=0; HOT_TXT=""
if [ "$HOT" -gt 0 ]; then
  HOT_TXT=" hotfix=$HOT"
  if { command -v flag_active >/dev/null 2>&1 && flag_active "paused-$P" >/dev/null 2>&1; } \
     || { ! command -v flag_active >/dev/null 2>&1 && [ -f "$HARNESS/flags/paused-$P" ]; }; then
    say "$HOT hotfix job(s) queued but paused-$P is set — exemption not applied, waiting on the pause (a pause is a human decision)"
  else
    HOTFIX_EXTRA=$HOT
  fi
fi
if [ "${POOL_AUTOSCALE:-1}" = 0 ]; then
  BUDGET=$((CAP - LIVE)); CAPTXT="$CAP"
else
  if [ "$CAP" -gt 0 ] 2>/dev/null; then
    BUDGET=$((CAP - LIVE)); [ "$BUDGET" -gt "$QUEUED" ] && BUDGET="$QUEUED"
    CAPTXT="$CAP"
  else
    BUDGET="$QUEUED"; CAPTXT=unlimited
  fi
  [ "$BUDGET" -lt 0 ] && BUDGET=0
  # ONE line per tick, because throughput that nobody can grep is a claim: this
  # is how "the pool is keeping up" stops being a guess (the operator, 2026-09-14).
  say "pool $P: queued=$QUEUED running=$LIVE spawning=$BUDGET cap=$CAPTXT$HOT_TXT"
fi
# BH-7107: queued work, no slot and nothing building for POOL_STALL_ALERT_S pages once an hour, with its cause.
command -v pool_stall_tick >/dev/null 2>&1 && pool_stall_tick
# BH-7382: queued > POOL_UNDERUSE_QUEUE_MIN and building < POOL_UNDERUSE_PCT of capacity for POOL_UNDERUSE_ALERT_S pages once an hour.
command -v pool_underuse_tick >/dev/null 2>&1 && pool_underuse_tick
# BH-6536: a ticket held in the review column by a human step says why it is not queued.
command -v nh_sd_stage_lines >/dev/null 2>&1 && while IFS=$'\t' read -r SK _ SST _ SRE; do
  [ -e "$QDIR/$SK.json" ] || say "pool $P: $SK not queued :: $SST: $SRE"
done < <(nh_sd_stage_lines "$P")
[ "$BUDGET" -gt 0 ] || [ "$HOTFIX_EXTRA" -gt 0 ] || exit 0
# pipeline-health halts spawns after 2 consecutive gate refusals — every
# refused spawn costs ~10min of performance-8x proving the same drift again.
# A harness deploy clears the flag (new code = new chance).
if command -v routing_halted >/dev/null 2>&1; then _POOL_HALTED() { routing_halted "$P"; }; else _POOL_HALTED() { [ -f "$HARNESS/flags/pool-halt-$P" ]; }; fi
_POOL_HALTED && { say "spawns halted for $P (pool-halt flag; deploy clears)"; exit 0; }
# An ephemeral pool app is routinely EMPTY (every machine is destroyed after
# its job), so the copy-the-first-machine trick can't bootstrap it — fall back
# to the ref fly-image-build.sh recorded. Machines-list first so a live pool
# keeps cloning exactly what it's already running.
# Resolved ONCE per tick rather than once per job: it is the same answer for every
# spawn in the burst, and it is two API calls each.
IMAGE=$(timeout 30 "$FLY" machines list -a "$APP" --json 2>/dev/null | jq -r '.[0].config.image // ""')
# Prefer the REF fly-image-build.sh recorded when it is NEWER than what the
# live pool runs: deployment ids are ULIDs, so a plain string compare orders
# them. Cloning the running machine's image kept every spawn on the stale
# bake until the pool emptied — the 2026-09-11 per-machine box-name fix sat
# unused while an old-image build held the pool open (TK-270 refused x6).
# BH-2523: the fly_images row's active digest first, the file when it gives none.
REC=""
declare -F fir_digest >/dev/null 2>&1 && { REC=$(fir_digest "$P" 2>/dev/null) || REC=""; }
[ -n "$REC" ] || REC=$(cat "$HARNESS/state/fly/$P.image" 2>/dev/null)
if [ -n "$REC" ] && { [ -z "$IMAGE" ] || [ "${REC##*:}" \> "${IMAGE##*:}" ]; }; then IMAGE="$REC"; fi
[ -n "$IMAGE" ] || { say "no image found for $APP — cannot spawn"; exit 0; }

# >>> bundle reason (BH-4859)
# pool_bundle_reason <rc> <stderr> -> ONE line saying why fly-envbundle.sh
# failed: its last FATAL message, else its last non-empty line, else that it
# said nothing. Control characters go (a tab or newline would split the queue
# row's reason), it is cut to 240 chars, and anything shaped like a credential
# is withheld. The bundler's die lines name variables, hosts and paths, never
# values; this is the backstop so a future one cannot leak into a queue row.
pool_bundle_reason() {
  local rc="${1:-1}" err="${2:-}" why
  why=$(printf '%s\n' "$err" | grep 'FATAL:' | tail -n 1 | sed 's/^.*FATAL: //')
  [ -n "$why" ] || why=$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1)
  why=$(printf '%s' "$why" | tr -d '\000-\037' | cut -c1-240)
  [ -n "$why" ] || why="fly-envbundle.sh exited rc $rc and printed no reason"
  if grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|sk-ant-|sk-or-|=[A-Za-z0-9_./+-]{32,}' <<<"$why"; then
    why="reason withheld: the bundler's output looked like a credential"
  fi
  printf '%s\n' "$why"
}
# <<< bundle reason

# >>> warmup note (BH-7215)
# pool_warmup_note <mid> <key> <launch-epoch> <push-epoch> <wait-s>
# One log line per spawn: the seconds from `fly machine run` to the first env
# push, against the machine's warmup wait. Over POOL_WARMUP_ALERT_PCT (lane knob,
# default 80, 0 = off) of the wait, ONE ALERTS line per project per UTC day: a
# slower hub setup would lose the spawn (#7174). Spawns run in parallel
# subshells; only the first writer of the day flag alerts.
# The day flag goes through bin/lib/flags.sh (flag_has --cached /
# flag_set, the file flags/alerted-pool-warmup-<P>-<YYYYMMDD>); bin/alerts-groom.sh
# prunes old alerted-* days. The alert carries --id pool-warmup-<P>, so two
# parallel spawns that both pass flag_has open one alerts row, not two.
pool_warmup_note() {
  local mid="${1:-}" key="${2:-}" t0="${3:-0}" t1="${4:-0}" w="${5:-0}" sp pct flag
  case "$t0" in ''|*[!0-9]*) t0=0 ;; esac
  case "$t1" in ''|*[!0-9]*) t1=0 ;; esac
  case "$w" in ''|*[!0-9]*) w=0 ;; esac
  sp=$(( t1 - t0 )); [ "$sp" -ge 0 ] || sp=0
  say "$mid: launch→first push ${sp}s (warmup wait ${w}s)"
  pct="${POOL_WARMUP_ALERT_PCT:-80}"; case "$pct" in ''|*[!0-9]*) pct=80 ;; esac
  [ "$pct" -gt 0 ] && [ "$w" -gt 0 ] || return 0
  [ $(( sp * 100 )) -gt $(( w * pct )) ] || return 0
  # shellcheck source=bin/lib/flags.sh
  command -v flag_set >/dev/null 2>&1 || . "$HARNESS/bin/lib/flags.sh" 2>/dev/null || return 0
  flag="alerted-pool-warmup-$P-$(date -u +%Y%m%d)"
  flag_has --cached "$flag" 2>/dev/null && return 0
  flag_set "$flag" on "fly-pool: warmup alert sent" >/dev/null 2>&1
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --id "pool-warmup-$P" "[pool/$P] $key: launch→first push ${sp}s on $mid is over ${pct}% of the ${w}s warmup wait (WARMUP_WAIT_S). A slower hub setup loses the spawn: the machine exits before its job. Raise lane.fly-pool.$P.warmup_wait_s or find the slow setup step in logs/fly-pool.log." >/dev/null 2>&1 || true
  return 0
}
# <<< warmup note

# >>> machine pull (BH-7430)
# THE MACHINE TAKES ITS OWN HARNESS, ENV AND JOB (BH-6896 S3). On the push path
# every spawn costs the hub an ssh to the owning box (fly-envbundle.sh), a fixed
# `sleep 20`, a 6.49 MB tarball over `ssh sftp` and 4 to 9 `ssh console` pushes.
# On the pull path the spawn ends at ONE `fly machine run`:
#   harness  the machine fetches HARNESS_SHA of HARNESS_SLUG itself
#            (fly/harness-fetch.sh), with a read token from the seed;
#   env      the static bundle is in the pool app's Fly secrets (HBUNDLE_*,
#            written by bin/fly-pool-secrets-sync.sh); the per-machine lines
#            (App token, leased account, OPENROUTER_FALLBACK, read tokens) go in
#            the seed as global.override.env, computed here BEFORE the launch;
#   job      job.json and every relay (pre-plan, reroute, build note, bake
#            evidence, deploy snapshot) go in the seed: `--file-local
#            /run/harness-seed/<push path>=<file>`. mput's seed mode stages them,
#            so the relay functions are the same ones the push path runs.
# fly/entrypoint.sh moves the seed to the push paths, composes the env and
# fetches the harness. POOL_MACHINE_PULL (lane knob, default 0) is the switch;
# at 0 nothing here runs and the spawn is byte-identical to the push path. Any
# precondition missing for one spawn sends that spawn down the push path, with
# one `<key>: push path (<why>)` line.
POOL_PULL_PRIMED=0; POOL_PULL_ON=0; POOL_PULL_WHY=""; POOL_PULL_SHA=""; POOL_PULL_SLUG=""
POOL_PULL_BASE=__HBUNDLE_BASE__
# pool_pull_prime: once per tick, in the tick's own shell, before the first
# spawn (spawns run in background subshells and cannot share a memo). ONE
# `fly secrets list` per tick, never per spawn.
pool_pull_prime() {
  [ "$POOL_PULL_PRIMED" = 0 ] || return 0
  POOL_PULL_PRIMED=1
  local k="${POOL_MACHINE_PULL:-0}" names
  k="${k//[[:space:]]/}"
  [ "$k" = 1 ] || return 0
  POOL_PULL_ON=1
  POOL_PULL_SLUG=$( . "$HARNESS/bin/lib/deployment.sh" 2>/dev/null && printf '%s' "${HARNESS_REPO:-}" )
  if ! [[ "$POOL_PULL_SLUG" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    POOL_PULL_WHY="no harness repo slug (bin/lib/deployment.sh HARNESS_REPO)"; return 0
  fi
  # The checkout beside the harness: /root/harness-checkout in production, the
  # tree harness_tarball ships on the push path.
  POOL_PULL_SHA=$(git -C "${HARNESS%/}-checkout" rev-parse HEAD 2>/dev/null)
  if ! [[ "$POOL_PULL_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    POOL_PULL_SHA=""; POOL_PULL_WHY="no git HEAD in the harness checkout"; return 0
  fi
  # Names only: `fly secrets list` prints a digest, never a value. A hung call
  # costs ONE 10 s wait: the marker below sends every spawn of the next 5
  # minutes down the push path without calling it again.
  local hang="$POOL/.secrets-list-hang" out rc
  if [ -n "$(find "$hang" -mmin -5 2>/dev/null)" ]; then
    POOL_PULL_WHY="fly secrets list timed out in the last 5 minutes"; return 0
  fi
  out=$(timeout 10 "$FLY" secrets list -a "$APP" --json 2>/dev/null); rc=$?
  if [ "$rc" = 124 ]; then
    : > "$hang" 2>/dev/null
    POOL_PULL_WHY="fly secrets list timed out (10 s)"; return 0
  fi
  names=$(jq -r '.[]? | (.Name // .name // empty)' 2>/dev/null <<<"$out")
  pool_pull_sweep "$names"
  if ! grep -qx HBUNDLE_SYNCED_AT <<<"$names"; then
    POOL_PULL_WHY="no HBUNDLE_SYNCED_AT in the $APP secrets"; return 0
  fi
  say "machine pull: on (harness ${POOL_PULL_SHA:0:12} of $POOL_PULL_SLUG, $APP secrets synced)"
}
# pool_pull_sweep <secret names>: a per-machine SEED_<epoch>_<hex> secret
# (pool_pull_seal) has done its job once its machine has booted. Unset every one
# older than POOL_SEED_SECRET_TTL_S, staged, in one call, from the names the
# prime already listed (no extra list call). A failed unset is one line; the
# next tick tries again.
POOL_SEED_SECRET_TTL_S=900
pool_pull_sweep() {
  local now n t stale=()
  now=$(date +%s)
  while IFS= read -r n; do
    [[ "$n" =~ ^SEED_([0-9]{10})_[0-9a-f]{12}$ ]] || continue
    t="${BASH_REMATCH[1]}"
    [ $((now - 10#$t)) -gt "$POOL_SEED_SECRET_TTL_S" ] && stale+=("$n")
  done <<<"${1:-}"
  [ "${#stale[@]}" -gt 0 ] || return 0
  if timeout 60 "$FLY" secrets unset --stage -a "$APP" "${stale[@]}" >/dev/null 2>&1; then
    say "seed secrets: unset ${#stale[@]} spent SEED_ secret(s) from $APP"
  else
    say "seed secrets: could not unset ${#stale[@]} spent SEED_ secret(s) on $APP, retried next tick"
  fi
}
# pool_pull_decide <key> <job-file> <tmp> -> rc 0 pull, rc 1 push (after one
# `<key>: push path (<why>)` line). Called before the env bundle, so a push
# answer still runs fly-envbundle.sh exactly as today. On rc 0 the seed dir
# $tmp/seed holds the job and the relays; the env lines join it at launch.
pool_pull_decide() {
  local k="$1" jf="$2" tmp="$3" why="${POOL_PULL_WHY:-}" exp ht max bytes
  # BH-8030: a console preview row pushes the Pages token after the launch,
  # never in a seed.
  [ -n "$why" ] || case "$k" in CP-*) why="a console preview row carries the Pages token" ;; esac
  if [ -z "$why" ]; then
    if ! { command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed && [ -x "$HARNESS/bin/gh-token.sh" ]; }; then
      why="App tokens are not armed"
    elif [ -z "${POOL_SLUG:-}" ]; then
      why="no repo slug for $P in fleet.conf"
    fi
  fi
  # The App token must be MINTED (an expiry), never the PAT fallback: the pull
  # bundle has no PAT. The swap block mints again below and gets the cache.
  if [ -z "$why" ]; then
    pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" >/dev/null 2>&1
    exp=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$POOL_SLUG" 2>/dev/null) || exp=""
    [ -n "$exp" ] || why="no App token"
  fi
  if [ -z "$why" ]; then
    if [ "${POOL_PULL_SLUG,,}" = "${POOL_SLUG,,}" ]; then
      ht=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>/dev/null) || ht=""
    else
      ht=$(pool_gh_token --extra-read "$POOL_PULL_SLUG" --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$POOL_SLUG" 2>/dev/null) || ht=""
    fi
    ht="${ht%%$'\n'*}"
    if [ -n "$ht" ]; then ( umask 077; printf '%s\n' "$ht" > "$tmp/gh-token-harness" ); else why="no harness read token"; fi
    ht=""
  fi
  if [ -z "$why" ]; then
    local POOL_SEED_DIR="$tmp/seed"
    mkdir -p "$POOL_SEED_DIR" && chmod 700 "$POOL_SEED_DIR"
    push_preplan "the seed" "$k"
    push_reroute "the seed" "$k"
    PULL_NOTE=$(push_build_note_file "the seed" "$k")
    [ -z "$PULL_NOTE" ] || mput "the seed" "$PULL_NOTE" "/run/harness/build-note-$P-$k.md" || why="seed copy failed"
    push_bake_evidence "the seed"
    if [ -s "$HARNESS/state/vercel-deploys/$P.json" ]; then
      mput "the seed" "$HARNESS/state/vercel-deploys/$P.json" "/data/harness/state/vercel-deploys/$P.json" || why="seed copy failed"
    fi
    if [ -s "${POOL_MR_BUNDLE:-}" ]; then
      mput "the seed" "$POOL_MR_BUNDLE" /run/harness-env/model-routes.tsv || why="seed copy failed"
    fi
    mput "the seed" "$tmp/gh-token-harness" /run/harness-env/gh-token-harness || why="seed copy failed"
    mput "the seed" "$jf" /run/harness/job.json || why="seed copy failed"
    # The env lines and tokens join at launch: 8 KB covers them.
    max="${POOL_SEED_MAX_BYTES:-262144}"; case "$max" in ''|*[!0-9]*) max=262144 ;; esac
    bytes=$(find "$POOL_SEED_DIR" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+8192}')
    [ -n "$why" ] || [ "$bytes" -le "$max" ] || why="seed too big: $bytes bytes over POOL_SEED_MAX_BYTES=$max"
  fi
  [ -z "$why" ] && return 0
  say "$k: push path ($why)"
  rm -rf "$tmp/seed" "$tmp/gh-token-harness"; PULL_NOTE=""
  return 1
}
# pool_pull_skeleton <tmp>: the bundle the swap and lease blocks edit on the
# pull path. global.env carries ONE placeholder line, so the blocks below run
# unchanged and only what they write becomes an override; <p>.env carries the
# slug they read. The machine's base lines come from the HBUNDLE_* secrets.
pool_pull_skeleton() {
  ( umask 077
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$POOL_PULL_BASE" > "$1/global.env"
    printf 'REPO_SLUG=%s\n' "$POOL_SLUG" > "$1/$P.env" )
}
# pool_pull_override <global.env> -> the override lines fly/entrypoint.sh
# applies over the base: every line the blocks wrote replaces its key; the
# untouched placeholder means "keep the base token"; a token line the lease
# STRIPPED (a pinned project whose token is missing, bin/lib/pool-account.sh)
# becomes `-CLAUDE_CODE_OAUTH_TOKEN`, which removes the base line.
pool_pull_override() {
  awk -v b="CLAUDE_CODE_OAUTH_TOKEN=$POOL_PULL_BASE" '
    /^CLAUDE_CODE_OAUTH_TOKEN=/ { c = 1; if ($0 == b) next }
    { print }
    END { if (!c) print "-CLAUDE_CODE_OAUTH_TOKEN" }' "$1"
}
# pool_pull_seal <tmp>: NO TOKEN GOES IN THE MACHINE CONFIG. flyctl stores a
# --file-local file as config.files[].raw_value, which `machines list --json`
# returns to anyone with the app's Fly token, also after the machine is gone
# (and bin/fly-idle-reaper.sh, bin/lane-fleet.sh and this file write that
# listing to hub files). So the files that hold a token travel as ONE Fly
# secret-backed file instead: they are tarred, gzipped and base64'd into a
# per-machine app secret SEED_<epoch>_<hex> (imported by stdin, staged, so no
# live machine restarts), and the launch carries `--file-secret
# /run/harness-seed-secret/bundle.b64=SEED_...`; the config then holds only the
# secret's name. fly/entrypoint.sh unpacks it into the RAM-only tmpfs.
# pool_pull_prime's sweep unsets the secret after POOL_SEED_SECRET_TTL_S.
# Sets PULL_SECRET (empty when no file holds a token).
POOL_SEED_SECRET_PATHS="/run/harness-env/global.override.env /run/harness-env/gh-token /run/harness-env/gh-token-read /run/harness-env/gh-token-harness /data/harness/state/auth-accounts.local.json"
POOL_SEED_SECRET_MAX_B64=20000
pool_pull_seal() {
  local sd="$1/seed" rel list=() name bytes
  PULL_SECRET=""
  for rel in $POOL_SEED_SECRET_PATHS; do [ -f "$sd$rel" ] && list+=(".$rel"); done
  [ "${#list[@]}" -gt 0 ] || return 0
  ( umask 077
    tar -C "$sd" -czf "$1/seed-secret.tgz" "${list[@]}" && base64 -w0 "$1/seed-secret.tgz" > "$1/seed-secret.b64" ) || return 1
  bytes=$(stat -c %s "$1/seed-secret.b64" 2>/dev/null) || bytes=0
  if [ "$bytes" -le 0 ] || [ "$bytes" -gt "$POOL_SEED_SECRET_MAX_B64" ]; then
    say "seed secret staging FAILED: the token bundle is $bytes bytes (limit $POOL_SEED_SECRET_MAX_B64)"; return 1
  fi
  name="SEED_$(date +%s)_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  # The value goes by stdin (never argv: ps shows argv) and is never echoed.
  if ! { printf '%s=' "$name"; cat "$1/seed-secret.b64"; printf '\n'; } \
       | timeout 60 "$FLY" secrets import --stage -a "$APP" >/dev/null 2>&1; then
    say "seed secret staging FAILED: fly secrets import for $name exited non-zero"; return 1
  fi
  for rel in $POOL_SEED_SECRET_PATHS; do rm -f "$sd$rel"; done
  rm -f "$1/seed-secret.tgz" "$1/seed-secret.b64"
  PULL_SECRET="$name"
}
# pool_pull_args <tmp>: stage the env lines and tokens, then fill PULL_ARGS
# (spawn_one's array) with the -e pins, one --file-local per seed file that
# holds no token and one --file-secret for the files that do.
pool_pull_args() {
  local tmp="$1" POOL_SEED_DIR="$1/seed" f
  ( umask 077; pool_pull_override "$tmp/global.env" > "$tmp/global.override.env" ) || return 1
  mput "the seed" "$tmp/global.override.env" /run/harness-env/global.override.env || return 1
  if [ -s "$tmp/gh-token" ]; then mput "the seed" "$tmp/gh-token" /run/harness-env/gh-token || return 1; fi
  if [ -s "$tmp/gh-token-read" ]; then mput "the seed" "$tmp/gh-token-read" /run/harness-env/gh-token-read || return 1; fi
  if [ -s "$tmp/auth-accounts.local.json" ]; then
    mput "the seed" "$tmp/auth-accounts.local.json" /data/harness/state/auth-accounts.local.json || return 1
  fi
  pool_pull_seal "$tmp" || return 1
  PULL_ARGS=(-e "HARNESS_SHA=$POOL_PULL_SHA" -e "HARNESS_SLUG=$POOL_PULL_SLUG")
  [ -z "${PULL_SECRET:-}" ] || PULL_ARGS+=(--file-secret "/run/harness-seed-secret/bundle.b64=$PULL_SECRET")
  # The row stamp moves to the machine (fly/entrypoint.sh), only where the hub
  # would have made it.
  [ "${ROWS_ONLY:-0}" = 1 ] && PULL_ARGS+=(-e POOL_CLAIM_MACHINE=1)
  while IFS= read -r -d '' f; do
    PULL_ARGS+=(--file-local "/run/harness-seed${f#"$POOL_SEED_DIR"}=$f")
  done < <(find "$POOL_SEED_DIR" -type f -print0 2>/dev/null | sort -z)
  return 0
}
# pool_pull_landed <mid> <key> <tmp>: what the push path does after its pushes,
# for a seeded machine: the snapshot mtime for the reap, the build note consumed.
pool_pull_landed() {
  local n
  n=$(find "$3/seed" -type f 2>/dev/null | grep -c .)
  if [ -e "$3/seed/data/harness/state/vercel-deploys/$P.json" ]; then
    stat -c %Y "$HARNESS/state/vercel-deploys/$P.json" > "$POOL/.$1.snapmt" 2>/dev/null || true
  fi
  [ -z "${PULL_NOTE:-}" ] || build_note_relayed "$1" "$2" "$PULL_NOTE"
  say "$1: seeded $n file(s) for $2 at launch; the machine fetches harness ${POOL_PULL_SHA:0:12} itself"
}
# <<< machine pull

spawn_one() { # spawn_one <job-file> <key> <ticket-id> <attempt> <deferrals> <deaths> [stack-base]
  local JF="$1" KEY="$2" TICKET="$3" ATT="$4" SDEF="$5" SDTH="$6" SSB="${7:-}"
  # BH-7505: a spawn spends a machine, so it runs only under a lease this run
  # still holds (a lane-run machine's, or a hub tick's that a Fly run could
  # contest). Before the queue claim: nothing is claimed, so nothing to hand back.
  if command -v pp_fence_ok >/dev/null 2>&1 && ! pp_fence_ok; then
    say "$KEY: the project lease is lost — no machine spawned, the job stays queued"
    return 1
  fi
  # Every spawn that reaches a machine counts against the per-key cap (BH-1075)
  # — except a REBASE row, which pool_spawn_decision exempts from the cap
  # entirely (its key carries the head it is rebasing, so a repeat is a new key;
  # bin/merge-conductor.sh owns that lane's timeout). A ledger nothing ever
  # reads would be one file per rebase left in state/pool.
  #
  # INFRASTRUCTURE FAILURES NEVER COUNT (BH-4859). The cap exists to bound a
  # loop of BUILDS. An env bundle that fails records nothing (it runs before the
  # record), and every exit below where no build ever reached the machine (no
  # machine id, harness sync failed, env/job push failed) takes its entry back
  # out with pool_spawn_cap_unrecord. Before this, every bundle failure bought a
  # machine and spent a cap slot, so a flaky bundler could cap a key that never
  # built once. SPAWNCAPTS also rides onto the machine json as
  # spawn_cap_ts (BH-1279), so a reap that learns the claim was REFUSED by a
  # concurrency rule removes exactly this entry too.
  # THE CLAIM COMES BEFORE THE MACHINE (BH-1026.3). With the rows as the queue,
  # the compare-and-swap on the row IS the dedupe for this spend, so it has to
  # happen before `fly machine run` — a claim taken after the spawn would have
  # already bought the machine it is deciding about, and a 409 would then have to
  # destroy one. rc 9 (someone else has it), rc 2 (no `queued` row for this key
  # any more) and rc 1 (an outage after a successful list) are all the same
  # answer to this function: one line, no machine. It also sits above
  # pool_spawn_cap_record deliberately — a spawn that never happened must not
  # spend a slot of the per-key cap (BH-1279's lesson, without needing the
  # un-record).
  local CRC=0
  if [ "${ROWS_ONLY:-0}" = 1 ] && command -v queue_claim >/dev/null 2>&1; then
    queue_claim "$P" fly "$KEY" >/dev/null 2>&1 || CRC=$?
    if [ "$CRC" != 0 ]; then
      say "$KEY: the queue row refused this claim (rc $CRC) — no machine spawned, re-offered next tick"
      return 1
    fi
  fi
  # BUNDLE BEFORE SPAWN (BH-4859). The bundle takes only $P and an outdir and
  # never reads $MID, so nothing it needs comes from the machine. Running it
  # first makes "can this spawn be used at all?" the check before paying for a
  # machine: a failure here buys nothing, records nothing, and hands the row
  # back with the bundler's own reason. The dir holds secrets, so every exit
  # from here to the push below removes it.
  local TMP EB_ERR="" EB_RC=0 EB_WHY
  TMP=$(mktemp -d /dev/shm/pool.XXXX); chmod 700 "$TMP"
  # PULL OR PUSH (BH-7430), decided before the bundle: a push answer runs the
  # bundler below exactly as before. See the `machine pull` block above.
  local PULL=0 PULL_TAG="" PULL_NOTE="" PULL_ARGS=() PULL_SECRET=""
  if [ "${POOL_PULL_ON:-0}" = 1 ] && pool_pull_decide "$KEY" "$JF" "$TMP"; then PULL=1; PULL_TAG="pull, "; fi
  # --pool (BH-4798): a box with no PAT is a WARN here, not a dead spawn, because
  # the token block below swaps the line for an App token. Its stderr is captured
  # ($LOG is the capture fd inside the substitution) so a failure can be named;
  # on success it (a WARN, paths and slugs only) goes to the pool log next to our
  # own line, and on failure only the filtered reason does.
  if [ "$PULL" = 1 ]; then
    pool_pull_skeleton "$TMP"
  else
  EB_ERR=$(exec 3>&1; LOG=/dev/fd/3
           "$HARNESS/bin/fly-envbundle.sh" "$P" "$TMP" --pool >/dev/null 2>>"$LOG") || EB_RC=$?
  fi
  if [ "$EB_RC" = 0 ]; then
    [ -z "$EB_ERR" ] || printf '%s\n' "$EB_ERR" >> "$LOG"
  else
    EB_WHY=$(pool_bundle_reason "$EB_RC" "$EB_ERR")
    rm -rf "$TMP"
    say "env bundle FAILED for $KEY: $EB_WHY — no machine spawned, job stays queued"
    command -v ptn_note >/dev/null 2>&1 && ptn_note "$P" "$EB_WHY"
    pool_unclaim "$KEY" "env bundle failed: $EB_WHY"; return 1
  fi
  local SPAWNCAPTS=""
  case "$KEY" in RB-*|RR-*|CP-*) ;; *) SPAWNCAPTS=$(pool_spawn_cap_record "$KEY") ;; esac
  # A CONSOLE PREVIEW ROW CARRIES THE PAGES TOKEN (BH-8030). Its machine
  # uploads the preview, so the hub's cloudflare.env (the token and account
  # lines only) goes to /run/harness-env/cloudflare.env, mode 0600, on the push
  # path only (pool_pull_decide sends a CP- row there: a pull seed can end up in
  # the machine config). No token on the hub: the row is FAILED before any
  # machine is bought, and the console preview lane reads that as the box's.
  if [[ "$KEY" == CP-* ]]; then
    grep -E '^(export[[:space:]]+)?CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)=' "$HENV/cloudflare.env" 2>/dev/null > "$TMP/cloudflare.env"
    if ! grep -qE '^(export[[:space:]]+)?CLOUDFLARE_API_TOKEN=.' "$TMP/cloudflare.env"; then
      rm -rf "$TMP"; rm -f "$JF"
      QROW failed "$KEY" "console preview: no CLOUDFLARE_API_TOKEN in the hub env/cloudflare.env; no machine spawned"
      say "$KEY: no Cloudflare token on the hub — console preview row FAILED, no machine spawned"
      return 1
    fi
  fi
  local MID TB SYNC_OK OK SNAP_SRC SNAP_MT MEXP="" MINST="" MAPP=hub SHF=false
  # `hotfix` is read off the JOB FILE rather than passed as an argument: the
  # spawn call's argument list is pinned by tests/no-serialize-test.sh (it is the
  # proof that spawns still run in the background), and a flag the file already
  # carries needs no eighth positional to travel.
  # READ IT HERE, at the top: the dispatch `mv` further down DELETES the job
  # file, so asking the question beside the jq that uses it answered false for
  # every hotfix the pool ever spawned — and the machine json is where the reap
  # reads the flag back to put it on the deferral and death requeues.
  job_is_hot "$JF" && SHF=true
  # SETUP BEFORE LAUNCH (BH-7215). A new machine waits WARMUP_WAIT_S for its
  # job and then exits. The steps below (spec repos, App token mint, account
  # lease, OpenRouter check, label overlay, harness tarball) need no machine, so
  # they run BEFORE `fly machine run`: on project-6-os they took about 12
  # minutes, and the machine had exited when the first push came (#7174). Only
  # the steps that need the machine (row stamp, lease rebind, tarball copy,
  # pushes) run after the launch. Every exit before the launch removes $TMP.
  local SETUP_T LEASE_ID=""; SETUP_T=$(date +%s)
  # SPEC REPOS (BH-6576): the repos this ticket's body names on a `Spec-repo:`
  # line. The swap block below adds them to the read-only token; the machine
  # json records them, so next_job_or_destroy never hands this machine on.
  SPEC_REPOS=""
  command -v spec_repos_load >/dev/null 2>&1 \
    && SPEC_REPOS_GH_TOKEN="${POOL_SLUG_TOK:-}" spec_repos_load "$POOL_SLUG" "$TICKET" 2>>"$LOG"
  [ -n "$SPEC_REPOS" ] && say "$KEY declares spec repos $SPEC_REPOS (read-only)"
  # PER-MACHINE GITHUB CREDENTIAL (2026-09-14). fly-envbundle.sh puts the owning
  # box's PAT in the bundle as GH_TOKEN, which is how a builder pushes and opens
  # its PR. That PAT is the fleet's whole GitHub identity, it never expires, and
  # every pool machine that ever booted got a copy of it — with 4000 builders that
  # is 4000 live copies of one credential sharing one 5000/h rate bucket. So the
  # machine gets its OWN token instead: scoped to this project's repo, dead in an
  # hour, and useless to anyone who finds it on a destroyed machine's rootfs.
  # The PAT line is REPLACED rather than appended to, because a second GH_TOKEN=
  # later in the file is what the builder's `set -a; . global.env` would actually
  # use — an append would silently keep the PAT.
  # Unarmed (no env/github-app.env, GH_APP_TOKENS=0, flags/gh-app-tokens-off) this
  # whole block is skipped and the bundle ships exactly the bytes it ships today.
  #
  # AND IT MUST OUTLIVE THE BUILD (2026-09-14, TK-680/681/682). The cache hands a
  # token out until 5 minutes before it dies, which is right for a lane that spends
  # it in seconds and wrong for a 40-75 minute build: three of them were spawned on
  # a 47-minute-old token and their pre-PR push was rejected an hour after the mint.
  # --min-life is the ask — a cached token with less than POOL_GH_TOKEN_MIN_LIFE
  # left is re-minted rather than shipped.
  #
  # The same token is ALSO written to /run/harness-env/gh-token, which is the file
  # rotate_gh_token replaces under a live build and fly/gh-credential.sh and
  # bin/lib/gh-token-live.sh read at call time. The GH_TOKEN= line in global.env is
  # unchanged and still the fallback, so everything that never learns about the file
  # keeps working exactly as it does today.
  #
  # NO CREDENTIAL, NO MACHINE (BH-4798). A --pool bundle may arrive with no PAT
  # (fly-envbundle.sh lets it through only when armed, i.e. only into this block).
  # If the mint then answers nothing too, the builder would have no GitHub
  # credential and fail at push 40+ minutes later, so the spawn is refused now.
  # BEFORE THE LAUNCH (BH-7215): this block runs before `fly machine run`, so
  # it names the KEY (there is no machine id yet), it pushes nothing, and its
  # refusals buy no machine. The read-only token file it writes is pushed in
  # the push phase below.
  # >>> pool gh credential swap
  if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed && [ -x "$HARNESS/bin/gh-token.sh" ]; then
    PSLUG=$(sed -n 's/^REPO_SLUG=//p' "$TMP/$P.env" 2>/dev/null | head -n 1)
    # gh-token.sh's stderr is kept for ONE line: `hub-retry`, which says the
    # profile could not mint and the hub App answered (#1590 review B2).
    # pool_gh_answered logs it and names the App that actually answered.
    MTOK=""; MAPP=hub
    if [ -n "$PSLUG" ]; then
      MTOK=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$PSLUG" 2>"$TMP/ghtok.err") || MTOK=""
      MAPP=$(pool_gh_answered "$TMP/ghtok.err"); rm -f "$TMP/ghtok.err"
    fi
    if [ -n "$MTOK" ]; then
      # THE BUCKET TRAVELS WITH THE TOKEN (BH-1578). A builder has no token cache
      # to look its installation up in, so the #1484 ledger there would file every
      # call under the flat `app`; GH_TOKEN_INSTALLATION_ID names the bucket this
      # token spends. A cache miss ships no line, never a guessed one. The same
      # --min-life as the mint, so a stale profile row can never answer for a
      # token the hub App minted.
      MINST=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --installation-id "$PSLUG" 2>/dev/null) || MINST=""
      case "$MINST" in *[!0-9]*) MINST="" ;; esac
      ( umask 077
        grep -v '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_TOKEN_INSTALLATION_ID=' > "$TMP/global.env.new"
        printf 'GH_TOKEN=%s\n' "$MTOK" >> "$TMP/global.env.new"
        [ -n "$MINST" ] && printf 'GH_TOKEN_INSTALLATION_ID=%s\n' "$MINST" >> "$TMP/global.env.new"
        printf '%s\n' "$MTOK" > "$TMP/gh-token" )
      if [ -s "$TMP/global.env.new" ]; then
        mv "$TMP/global.env.new" "$TMP/global.env"
        # Recorded on the machine json below so the tick can decide about rotation
        # from a local file rather than a second API call. Empty when the answer was
        # the PAT, and an empty expiry is what tells rotate_gh_token to stay out.
        MEXP=$(pool_gh_token --min-life "$POOL_GH_TOKEN_MIN_LIFE" --expires-at "$PSLUG" 2>/dev/null) || MEXP=""
        say "$KEY gets a repo-scoped App token for $PSLUG from the $MAPP App (expires ${MEXP:-?}) instead of the fleet PAT"
        # EXTRA READ REPOS (BH-5910). The token above sees one repo. When
        # lane.fly-pool.<project>.extra_read_repos names more, a SECOND token reads
        # them (contents+metadata read); fly/gh-credential.sh answers it for those
        # repos only. No token: the machine still ships, and the plan stage stops
        # a build that needs the repo (PLAN_BLOCKED cross-repo-read).
        # SPEC REPOS (BH-6576): the ticket's own `Spec-repo:` repos join the
        # knob's list, the project slug and the knob's own repos dropped. Empty
        # for every other ticket, so the list and the mint are the knob's alone.
        XREAD_SPEC=""
        [ -n "${SPEC_REPOS:-}" ] && command -v spec_repos_extra >/dev/null 2>&1 \
          && XREAD_SPEC=$(spec_repos_extra "${EXTRA_READ_REPOS:-}" "$SPEC_REPOS" "$PSLUG")
        XREAD_SRC="${EXTRA_READ_REPOS:-}"
        [ -n "$XREAD_SPEC" ] && XREAD_SRC="${XREAD_SRC:+$XREAD_SRC,}$XREAD_SPEC"
        if [ -n "$MEXP" ] && [ -n "$XREAD_SRC" ]; then
          XTOK=$(pool_gh_token --extra-read "$XREAD_SRC" --min-life "$POOL_GH_TOKEN_MIN_LIFE" "$PSLUG" 2>"$TMP/xread.err") || XTOK=""
          XMISS=""
          while IFS= read -r XLINE; do
            XREPO=$(printf '%s' "$XLINE" | sed -n 's/.*EXTRA_READ_REPO_MISSING \([^ ]*\).*/\1/p')
            [ -n "$XREPO" ] || continue
            XMISS="$XMISS $XREPO"
            say "$KEY: ${XLINE#gh-token: } — not readable on this machine"
            # ALERTS first, then the flag; one per project per repo per UTC day (D21).
            find "$HARNESS/flags" -maxdepth 1 -name 'alerted-extra-read-missing-*' -mmin +2880 -delete 2>/dev/null
            XFLAG="$HARNESS/flags/alerted-extra-read-missing-$P-$(printf '%s' "$XREPO" | tr -c 'A-Za-z0-9._-' '-')-$(date -u +%Y%m%d)"
            if [ ! -f "$XFLAG" ]; then
              # A repo the knob does not name came from the ticket's Spec-repo line.
              if [[ ",${XREAD_SPEC,,}," == *",${XREPO,,},"* ]]; then
                HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] EXTRA_READ_REPO_MISSING $XREPO — ticket $KEY declares it as Spec-repo, but the pool App cannot read it. Install the builders App on $XREPO (same owner as $PSLUG)."
              else
                HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] EXTRA_READ_REPO_MISSING $XREPO — lane.fly-pool.$P.extra_read_repos names it, but the pool App cannot read it, so pool/$P builds cannot read it. Install the builders App on $XREPO (same owner as $PSLUG), or remove it from the setting."
              fi
              touch "$XFLAG" 2>/dev/null
            fi
          done < "$TMP/xread.err"
          rm -f "$TMP/xread.err"
          # The list the builder sources (global.env is `. `-loaded as root) is
          # NEVER the raw row: only owner/repo words, the project and the missing
          # repos dropped, deduped, sorted and capped as gh-token.sh mints them,
          # joined by commas. A space-separated row or a `$(...)` word cannot
          # reach the builder's shell.
          XLIST=""; XSEEN=" "; XN=0
          IFS=$', \t\n' read -r -d '' -a XWORDS <<< "$XREAD_SRC" || true
          while IFS= read -r XW; do
            [[ "$XW" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || continue
            [ "${XW,,}" = "${PSLUG,,}" ] && continue
            case "$XSEEN" in *" ${XW,,} "*) continue ;; esac
            XSEEN="$XSEEN${XW,,} "; XN=$((XN + 1))
            [ "$XN" -le 10 ] || continue
            case " ${XMISS,,} " in *" ${XW,,} "*) continue ;; esac
            XLIST="${XLIST:+$XLIST,}$XW"
          done < <(printf '%s\n' ${XWORDS[@]+"${XWORDS[@]}"} | sort -f)
          [ -n "$XLIST" ] || XTOK=""
          if [ -n "$XTOK" ]; then
            ( umask 077
              grep -v '^GH_EXTRA_READ_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_EXTRA_READ_REPOS=' > "$TMP/global.env.new"
              printf 'GH_EXTRA_READ_TOKEN=%s\nGH_EXTRA_READ_REPOS=%s\n' "$XTOK" "$XLIST" >> "$TMP/global.env.new"
              printf '%s\n' "$XTOK" > "$TMP/gh-token-read" )
            if [ -s "$TMP/global.env.new" ] && grep -q '^GH_TOKEN=' "$TMP/global.env.new"; then
              mv "$TMP/global.env.new" "$TMP/global.env"
              # The file stays in $TMP: the push phase after the launch sends
              # it (BH-7215), and `rm -rf "$TMP"` removes it on every exit.
              say "$KEY gets a read-only token for the extra repos of $PSLUG ($XLIST; left out:${XMISS:- none})"
            else
              rm -f "$TMP/global.env.new" "$TMP/gh-token-read"
              say "$KEY: read-only token bundle write failed — no extra repos on this machine"
            fi
          else
            grep -v '^GH_EXTRA_READ_TOKEN=' "$TMP/global.env" 2>/dev/null | grep -v '^GH_EXTRA_READ_REPOS=' > "$TMP/global.env.x" \
              && mv "$TMP/global.env.x" "$TMP/global.env" && chmod 600 "$TMP/global.env" 2>/dev/null
            say "$KEY: no read-only token for $XREAD_SRC — the machine ships with the $PSLUG token only"
          fi
          XTOK=""; XMISS=""; XLIST=""; XWORDS=()
        fi
        XREAD_SRC=""; XREAD_SPEC=""
      else
        rm -f "$TMP/global.env.new" "$TMP/gh-token"
        if ! grep -q '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null; then
          say "$KEY: token swap produced an empty bundle and the bundle carries no PAT — no machine spawned, job stays queued"
          MTOK=""; rm -rf "$TMP"
          # This runs before the launch (BH-7215), so no machine exists to
          # destroy. Nothing was built, so it does not count against the cap
          # (BH-4859). ${SPAWNCAPTS:-}: this block is lifted by its markers into
          # tests/fly-envbundle-pool-nopat.bh-4798-test.sh under set -u, and an
          # empty ts is already a no-op in pool_spawn_cap_unrecord.
          pool_spawn_cap_unrecord "$KEY" "${SPAWNCAPTS:-}"
          pool_unclaim "$KEY" "no GitHub credential for $KEY"; return 1
        fi
        say "$KEY token swap produced an empty bundle — shipping the PAT"
      fi
    elif ! grep -q '^GH_TOKEN=' "$TMP/global.env" 2>/dev/null; then
      say "$KEY: no App token for ${PSLUG:-unknown repo} and the bundle carries no PAT — no machine spawned, job stays queued"
      rm -rf "$TMP"
      # Before the launch (BH-7215): no machine to destroy, no cap slot spent (BH-4859).
      pool_spawn_cap_unrecord "$KEY" "${SPAWNCAPTS:-}"
      pool_unclaim "$KEY" "no GitHub credential for $KEY"; return 1
    else
      say "$KEY: no App token for ${PSLUG:-unknown repo} — shipping the PAT"
    fi
    MTOK=""
  fi
  # <<< pool gh credential swap
  # PER-MACHINE CLAUDE ACCOUNT (2026-09-14). Exactly the swap above, one
  # credential over: the bundle's CLAUDE_CODE_OAUTH_TOKEN is the owning box's
  # project-6 setup-token and every machine in the pool got the same one, so a
  # 20-machine burst was 20 heavy sessions on one account (fly/account-capacity.conf
  # says ~4) and every cost row those machines wrote was attributed to that one
  # account. bin/lib/pool-account.sh leases one of env/accounts.d's max accounts to
  # THIS machine, replaces the token line, and drops an fp->label overlay beside
  # the bundle so the machine's own cost rows carry the account name.
  #
  # It cannot refuse a launch: unarmed, saturated or broken, it answers `default`
  # and the bundle ships exactly the bytes it ships today.
  # BEFORE THE LAUNCH (BH-7215): there is no machine id yet, so the lease is
  # taken under a pre-launch id and pool_account_rebind moves it to the machine
  # id right after `fly machine run`. Every reap path then frees it by machine
  # id, as before.
  MACCT=""
  LEASE_ID="pre-$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '-')-$(date +%s)-$BASHPID"
  LEASE_ID="${LEASE_ID:0:64}"
  if command -v pool_account_lease >/dev/null 2>&1; then
    PALINE=$(pool_account_lease "$P" "$KEY" "$TMP/global.env" "$LEASE_ID" 2>/dev/null)
    PANAME=""; PAREASON=""; PALEASES=""; PAFIVE=""
    for KV in $PALINE; do
      case "$KV" in
        name=*)   PANAME="${KV#name=}" ;;
        reason=*) PAREASON="${KV#reason=}" ;;
        leases=*) PALEASES="${KV#leases=}" ;;
        five_h=*) PAFIVE="${KV#five_h=}" ;;
      esac
    done
    if [ -n "$PANAME" ] && [ "$PANAME" != default ]; then
      MACCT="$PANAME"
      say "$KEY gets account $MACCT (5h ${PAFIVE:-?}%, leases ${PALEASES:-?}) instead of the default token"
      # NO OPENROUTER WHILE CLAUDE OAUTH WORKS (the operator, 2026-09-24). A machine
      # carries ONE leased token and no account routing, so when that account
      # runs out, agent-call's "exhausted-only" reading is true ON THE MACHINE —
      # its only account is gone — and it would descend to OpenRouter while the
      # hub holds healthy accounts. Every attributable OpenRouter dollar on
      # 09-21..23 (~$1.1K/day) came from pool machines this way. So when the hub
      # has another account that could serve, the machine is told
      # OPENROUTER_FALLBACK=off: the stage ends RUNNER_EXHAUSTED, the reap cools
      # this account (F2), requeues without charging the ticket (F3), and the
      # next machine leases a healthy one. Replaced, never appended: the bundle
      # already carries the hub's own OPENROUTER_* lines.
      if command -v pool_account_others_ok >/dev/null 2>&1 && pool_account_others_ok "$MACCT"; then
        { grep -v '^OPENROUTER_FALLBACK=' "$TMP/global.env" 2>/dev/null; printf 'OPENROUTER_FALLBACK=off\n'; } > "$TMP/global.env.or" \
          && mv "$TMP/global.env.or" "$TMP/global.env" && chmod 600 "$TMP/global.env" 2>/dev/null
        say "$KEY: another claude account can serve, so OpenRouter is off on this machine (OPENROUTER_FALLBACK=off)"
      fi
    else
      say "$KEY ships the default project-6 token (${PAREASON:-no answer})"
    fi
  fi
  # THE DEFAULT TOKEN STILL NEEDS A LABEL (2026-09-16). The lease path writes
  # TMP/auth-accounts.local.json for the leased account. The default path
  # (all_unreadable / saturated / unarmed) ships the hub's project-6 token
  # and, until now, no overlay — so every cost row landed auth_account=unknown,
  # cost-reconcile never fetched those pool rows (box=pool-* is not in
  # boxes.cost_rows; unknown is not in auth_accounts), and the 1h window then
  # substituted jobs.spent_usd. 00:50Z 1h: meter $19.35, labelled rows $11.45,
  # jobs $73.71, gap -340%. 24h: $2538 of pool claude on fp 52bec8da8a5d sat
  # unlabelled against a $4211 meter. The hub overlay already maps that fp to
  # claude:operator@example.com; copy it when the lease did not write one. A
  # missing hub overlay is the unarmed box and stays a no-op.
  if [ ! -s "$TMP/auth-accounts.local.json" ] && [ -s "$HARNESS/state/auth-accounts.local.json" ]; then
    cp "$HARNESS/state/auth-accounts.local.json" "$TMP/auth-accounts.local.json" 2>/dev/null || true
  fi
  # Volume-less pool machines never receive the dispatcher's harness sync, so
  # without this push /data/harness/bin/run-build.sh does not exist and the
  # runner dies No-such-file after a clean clone+install (TK-143, 2026-08-13).
  # Include catalog/ as in fly-sync-harness.sh: transcript pricing needs the
  # model price table on this fresh rootfs or every measured call costs $0.
  # Built here, before the launch (BH-7215): it is local work, and the machine
  # should not wait for it.
  # The pull path ships no tarball: the machine fetches the pinned sha.
  if [ "$PULL" = 1 ]; then
    TB=""
    if ! pool_pull_args "$TMP"; then
      say "seed staging FAILED for $KEY — no machine spawned, job stays queued"
      rm -rf "$TMP"
      command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
      pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      pool_unclaim "$KEY" "seed staging failed for $KEY"; return 1
    fi
  else
  TB=$(mktemp /tmp/poolsync-XXXX.tgz)
  # shellcheck source=bin/lib/harness-tarball.sh
  . "$HARNESS/bin/lib/harness-tarball.sh" \
    || say "bin/lib/harness-tarball.sh missing under $HARNESS — $KEY ships no harness tree"
  harness_tarball "$TB" /root/harness-checkout bin prompts rules catalog fleet.conf fly
  [ $? = 2 ] && say "no git HEAD in /root/harness-checkout — $KEY ships with no HARNESS_COMMIT stamp, so its box reports no harness commit"
  fi
  # BH-7215: the machine waits WARMUP_WAIT_S for its job (lane knob
  # lane.fly-pool.<project>.warmup_wait_s), then exits 0.
  local WW="${WARMUP_WAIT_S:-1800}"; case "$WW" in ''|*[!0-9]*|0) WW=1800 ;; esac
  say "$KEY: setup before launch took $(( $(date +%s) - SETUP_T ))s"
  # BH-7519: the fence at the top of this function is minutes old (the setup
  # above took about 12 on project-6-os). Ask again right before the spend. A
  # lost lease buys no machine and hands the claim back, as a launch with no
  # machine id does.
  if command -v pp_fence_ok >/dev/null 2>&1; then
    pp_fence_ok; local FRC=$?
    if [ "$FRC" = 99 ]; then
      say "$KEY: the project lease was lost during setup — no machine spawned, job stays queued"
      rm -rf "$TMP"; rm -f "$TB"
      command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
      pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
      pool_unclaim "$KEY" "project lease lost before the launch of $KEY"; return 1
    fi
  fi
  # Parse the id off the "Machine ID:" line ONLY — the first bare 14-hex run in
  # the output is the image's sha256 digest when IMAGE carries one, and treating
  # that as the id orphans the real machine (2026-08-12, pool-project-3).
  MID=$(timeout 180 "$FLY" machine run "$IMAGE" -a "$APP" --detach --vm-size performance-8x --vm-memory 16384 \
        -e PROJECT="$P" -e POOL_MODE=1 -e HARNESS_CHECKOUT=/data/harness -e WARMUP_WAIT_S="$WW" ${PULL_ARGS[@]+"${PULL_ARGS[@]}"} 2>/dev/null | grep -i 'machine id' | grep -oE "[0-9a-f]{14}" | head -1)
  # EVERY EXIT FROM HERE DOWN HANDS THE ROW BACK (see pool_unclaim): the claim is
  # already won, and under the flag a claim nobody releases is a key stranded in
  # flight for the stale-claim sweep's six hours.
  [ -n "$MID" ] || { say "machine run FAILED for $KEY — job stays queued"
                     rm -rf "$TMP"; rm -f "$TB"
                     command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$LEASE_ID"
                     pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
                     pool_unclaim "$KEY" "fly machine run produced no machine for $KEY"; return 1; }
  local LAUNCH_T; LAUNCH_T=$(date +%s)
  # BH-5001: the claim above was won before the machine existed; name it now,
  # so "is this key building, and where" is answerable from the row on any hub.
  # Fail-open: the build goes ahead, and the reap and parity lanes own the rest.
  # On the pull path the machine stamps its own row (POOL_CLAIM_MACHINE).
  if [ "$PULL" != 1 ] && [ "${ROWS_ONLY:-0}" = 1 ] && command -v psr_claim_machine >/dev/null 2>&1; then
    psr_claim_machine "$P" "$KEY" "$MID" || say "$KEY: the claimed row could not be stamped with machine $MID (http=${JOBS_HTTP:-none}) — the build goes ahead"
  fi
  if [ -n "$MACCT" ] && command -v pool_account_rebind >/dev/null 2>&1; then
    pool_account_rebind "$LEASE_ID" "$MID" "$MACCT" "$P" "$KEY" \
      || say "$MID: the account lease could not move from $LEASE_ID to the machine id — the pre-launch row frees at its TTL"
  fi
  if [ "$PULL" = 1 ]; then
    # Everything the machine needs was in the launch: nothing waits, nothing pushes.
    OK=1
    pool_pull_landed "$MID" "$KEY" "$TMP"
  else
  sleep 20   # boot + entrypoint
  # The tarball was built before the launch (BH-7215); only the copy is here.
  SYNC_OK=1
  timeout 120 "$FLY" ssh sftp put -a "$APP" --machine "$MID" "$TB" /run/harness/.hsync.tgz >/dev/null 2>&1 || SYNC_OK=0
  if [ "$SYNC_OK" = 1 ]; then
    mexec "$MID" "mkdir -p /data/harness && tar xzf /run/harness/.hsync.tgz -C /data/harness && mkdir -p /data/harness/logs /data/harness/state /data/harness/locks /data/harness/builds && rm -f /run/harness/.hsync.tgz" >/dev/null || SYNC_OK=0
  fi
  rm -f "$TB"
  if [ "$SYNC_OK" != 1 ]; then
    say "harness sync FAILED to $MID for $KEY — destroying, job stays queued"
    destroy_machine "$MID" "harness sync failed for $KEY"; rm -rf "$TMP"
    # The lease was taken before the launch (BH-7215), so this exit frees it too.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
    pool_unclaim "$KEY" "harness sync to $MID failed"; return 1
  fi
  OK=1
  if [ -s "$TMP/gh-token-read" ]; then
    mput "$MID" "$TMP/gh-token-read" /run/harness-env/gh-token-read \
      || say "$MID: gh-token-read push FAILED — git answers the project token for the extra repos"
  fi
  mput "$MID" "$TMP/global.env" /run/harness-env/global.env || OK=0
  # BH-7215: launch→first push seconds, on pass and fail.
  pool_warmup_note "$MID" "$KEY" "$LAUNCH_T" "$(date +%s)" "$WW"
  mput "$MID" "$TMP/$P.env" "/run/harness-env/$P.env" || OK=0
  # A failed overlay push costs ATTRIBUTION, never the build: the machine then
  # writes its cost rows under an unlabelled fingerprint.
  if [ -s "$TMP/auth-accounts.local.json" ]; then
    mput "$MID" "$TMP/auth-accounts.local.json" /data/harness/state/auth-accounts.local.json \
      || say "$MID: account label overlay push FAILED — its cost rows will land unlabelled"
  fi
  # Only written when the swap happened, so an unarmed box pushes exactly the two
  # files it pushes today and the builder finds no file to prefer.
  if [ -s "$TMP/gh-token" ]; then mput "$MID" "$TMP/gh-token" /run/harness-env/gh-token || OK=0; fi
  # This tick's model-route answers (BH-1572, pool_mr_bundle below), before the
  # job file the runner starts on. A failed push costs the outage cover, never
  # the build: the machine resolves its own ladders, as it did before.
  if [ -s "${POOL_MR_BUNDLE:-}" ]; then
    mput "$MID" "$POOL_MR_BUNDLE" /run/harness-env/model-routes.tsv \
      || say "$MID: model-routes bundle push FAILED — it resolves its own ladders at job start"
  fi
  if [ -s "$TMP/cloudflare.env" ]; then mput "$MID" "$TMP/cloudflare.env" /run/harness-env/cloudflare.env || OK=0; fi
  mput "$MID" "$JF" /run/harness/job.json || OK=0
  fi
  rm -rf "$TMP"
  if [ "$OK" = 1 ]; then
    # Seed the fresh machine with the current preview snapshot so wait-preview
    # has state from minute zero; the REAP tick refreshes it on mtime change.
    # A pull machine got all of this in its seed (pool_pull_landed).
    if [ "$PULL" != 1 ]; then
    SNAP_SRC="$HARNESS/state/vercel-deploys/$P.json"
    if [ -s "$SNAP_SRC" ] && mput "$MID" "$SNAP_SRC" "/data/harness/state/vercel-deploys/$P.json"; then
      stat -c %Y "$SNAP_SRC" > "$POOL/.$MID.snapmt" 2>/dev/null || true
    fi
    push_preplan "$MID" "$KEY"
    push_reroute "$MID" "$KEY"
    push_build_note "$MID" "$KEY"
    push_bake_evidence "$MID"
    fi
    mv "$JF" "$QDIR/.$KEY.dispatched" 2>/dev/null; rm -f "$QDIR/.$KEY.dispatched"
    # `deaths` rides from the job file onto the machine json: the REAP pass
    # reads it back off $MF, so dropping it here would reset the count and the
    # blocked-resolver would never see a job die twice.
    # `auth_account` is the NAME of the leased account and never its token: the
    # reap reads it back to attribute the build and to cool the account down when
    # it refused, and the console reads it to say which account paid for this
    # machine. Absent = this machine shipped the project-6 token.
    # `hotfix` ($SHF) was read off the job file at the top of this function,
    # before the dispatch `mv` removed it.
    # `spawn_cap_ts` ($SPAWNCAPTS, BH-1279) is the exact line pool_spawn_cap_record
    # appended to this key's .spawns log above. Absent for a RB-* key, which the
    # cap never charges in the first place.
    # `spec_repos` (BH-6576) names the repos this machine's read-only token was
    # asked for by the ticket's `Spec-repo:` line. Absent for every other ticket;
    # next_job_or_destroy never reuses a machine that carries it.
    jq -nc --arg m "$MID" --arg k "$KEY" --arg t "$TICKET" --argjson a "$ATT" --argjson d "$SDEF" --argjson x "$SDTH" --arg ts "$(STAMP)" --arg sb "$SSB" --arg hf "$SHF" --arg ge "$MEXP" --arg aa "$MACCT" --arg sct "$SPAWNCAPTS" --arg sr "${SPEC_REPOS:-}" \
      '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts}
       + (if $sb == "" then {} else {stack_base:$sb} end)
       + (if $hf == "true" then {hotfix:true} else {} end)
       + (if $ge == "" then {} else {gh_token_expires_at:$ge} end)
       + (if $aa == "" then {} else {auth_account:$aa} end)
       + (if $sct == "" then {} else {spawn_cap_ts:$sct} end)
       + (if $sr == "" then {} else {spec_repos:$sr} end)' > "$POOL/$MID.json"
    # >>> machines rows (BH-1035)
    # Record the spawn in the machine registry, after the json the pool itself
    # reads. Fail-open: a broken worker does not stop the pool from running the
    # build on this machine. IMAGE/MACCT come from the enclosing scope — no new
    # positional, because tests/no-serialize-test.sh pins this argument list.
    machines_row machine_put "$P" "$APP" "$MID" pool "$KEY" "$TICKET" "${MACCT:-}" "$IMAGE" spawned
    # <<< machines rows
    # BH-7505: on a lane-run machine the record above exists only on this
    # machine until a write-back carries it home. Post it NOW, so a machine that
    # stops after this spawn leaves the hub with a record of the build machine,
    # not an untracked one. Fail-open: the final write-back retries.
    command -v pp_checkpoint >/dev/null 2>&1 && pp_checkpoint "$P" "$MID"
    # Bookkeeping: rc 2 (no such queued row) is the common case — the
    # dispatcher already claimed it when it materialised the file. Only on the
    # FLAG-OFF path: under the flag this claim already happened at the top of
    # this function, and it was a gate there rather than a `|| true`.
    [ "${ROWS_ONLY:-0}" = 1 ] || \
      { command -v queue_claim >/dev/null 2>&1 && queue_claim "$P" fly "$KEY" >/dev/null 2>&1; }
    # The live count is the DIRECTORY, and with spawns running concurrently it is
    # the only honest answer: this subshell cannot see its siblings' increments.
    say "spawned $MID for $KEY (${PULL_TAG}live=$(ls "$POOL" 2>/dev/null | wc -l | tr -d ' ')/$CAPTXT, budget $BUDGET this tick)"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$P" --arg k "$KEY" '{kind:"build",project:$p,ticket_key:$k,stage:"pool_spawned"}')" >/dev/null 2>&1 || true
  else
    say "env/job push FAILED to $MID — destroying, job stays queued"
    destroy_machine "$MID" "env/job push failed for $KEY"
    rm -f "$POOL/.$MID.puterr"
    # The lease was taken before the push; a machine that never got its job must
    # not keep an account busy until the TTL.
    command -v pool_account_release >/dev/null 2>&1 && pool_account_release "$MID"
    # No build reached this machine, so it does not count against the cap (BH-4859).
    pool_spawn_cap_unrecord "$KEY" "$SPAWNCAPTS"
    # ...and neither must it keep the QUEUE ROW busy (BH-1026.3).
    pool_unclaim "$KEY" "env/job push to $MID failed"
    return 1
  fi
  return 0
}

# THE BUILD'S MODEL ROUTES, RESOLVED ONCE PER TICK (BH-1572). A fresh machine's
# route cache is empty, so a worker blip at its job start used to defer its build
# (no route, no guessed model). This box resolves the build's roles for $P once,
# before the first spawn of the tick, and every machine the tick spawns gets the
# answers with its env bundle (bin/lib/model-route.sh model_routes_bundle, which
# bounds the asking and stamps each ladder with when it was resolved). Once per
# tick and not per spawn: the spawns run concurrently, and N machines asking the
# worker the same seventeen questions at once is N-1 times too many. In its own
# subshell, so the resolver never changes this script's shell. Fail-open: no
# file means no bundle, and a machine without one behaves exactly as before.
POOL_MR_BUNDLE=""
pool_mr_bundle() {
  [ -z "$POOL_MR_BUNDLE" ] || return 0
  POOL_MR_BUNDLE=$(mktemp "${TMPDIR:-/tmp}/pool-mr.XXXXXX" 2>/dev/null) || { POOL_MR_BUNDLE=""; return 0; }
  ( . "$HARNESS/bin/lib/model-route.sh" 2>/dev/null && model_routes_bundle "$P" "$POOL_MR_BUNDLE" ) >/dev/null 2>&1
  if [ -s "$POOL_MR_BUNDLE" ]; then
    say "model routes: bundling $(cut -f1 "$POOL_MR_BUNDLE" | sort -u | wc -l | tr -d ' ') resolved ladder(s) for this tick's spawns"
  else
    say "model routes: nothing to bundle this tick — spawned machines resolve their own ladders"
  fi
}

# The launch loop itself is pure bookkeeping — jq reads and a flock-free dedupe —
# so it costs nothing to run to the end of the budget before anything waits.
# >>> machines rows (BH-1035)
# Advisory row liveness before launch (BH-1056): a row that says a key is live
# but has no local file here still spawns, because the file is the truth this
# tick owns. Log-only. ONE list per tick, read before the loop.
LIVE_ROWS=""
if [ "$MROWS" = 1 ] && command -v machines_list >/dev/null 2>&1; then
  LIVE_ROWS=$(machines_list "$P" live 2>/dev/null || true)
fi
# <<< machines rows

LAUNCHED=0
HOT_LAUNCHED=0
TICK_KEYS=" "
# Malformed entries quarantined this tick: paged ONCE after the loop, however
# many there are, so a bad producer is one alert and not one per file.
QUAR=()
# BH-7421: the budget clock starts at the row walk, not at the lock: a long reap
# phase must not leave the walk no time. The first row is always decided. Rows
# walk oldest first, so a slow head row can use the budget on every tick; the
# budget stops the tick, it does not reorder the queue.
# The bulk read only when a row can spawn this tick: a free budget slot or a
# hotfix exemption. A full pool makes no PR read, as before the bulk read.
if [ "$BUDGET" -gt 0 ] 2>/dev/null || [ "${HOTFIX_EXTRA:-0}" -gt 0 ] 2>/dev/null; then
  pool_pr_bulk_prime
else
  say "PR bulk read: off (no free slot and no hotfix this tick)"
fi
# BH-7706: the reads every row shares, once, before the budget clock starts.
PDC_ON=0; command -v pdc_prime >/dev/null 2>&1 && { pdc_prime; PDC_ON=1; }
# pool_walk_spawn <hot> <jf> <key> <ticket> <attempt> <deaths> <stack-base> —
# a row the decision let through: its machine, in the background.
pool_walk_spawn() {
  local JF_HOT="$1" JF="$2" KEY="$3" TICKET="$4" ATT="$5" SDTH="$6" SSB="$7" SDEF
  # A release in the gate rewrote the file (BH-5967): the machine carries the
  # reset count, not the one read above.
  SDEF=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null); case "$SDEF" in ''|*[!0-9]*) SDEF=0 ;; esac
  # SAY THE LINE THIS EXCEEDED. The WIP gate's exemption announces itself in
  # bin/run-build.sh; the pool's did not, and the tick line above only ever
  # reported the BUDGET — so a machine past the cap read as a cap that had never
  # been reached. One line, only when the exemption is actually spent.
  [ "$JF_HOT" = 1 ] && say "hotfix $KEY: pool at cap $CAPTXT (budget spent) — exceeding it by one machine"
  pool_pull_prime
  pool_mr_bundle
  spawn_one "$JF" "$KEY" "$TICKET" "$ATT" "$SDEF" "$SDTH" "$SSB" &
  if [ "$JF_HOT" = 1 ]; then HOT_LAUNCHED=$((HOT_LAUNCHED+1)); else LAUNCHED=$((LAUNCHED+1)); fi
}
PDC_SEEN=0; PDC_FIRST=0
POOL_TICK_T0=$(date +%s)
for JF in $(hotfix_first $(ls -tr "$QDIR"/*.json 2>/dev/null)); do
  case "$JF" in *.failed.json) continue;; esac
  # BH-7475: the same stop rule at each queued row; the tail below still waits.
  command -v pts_stop_due >/dev/null 2>&1 && pts_stop_due && { PDC_STOP=stop; break; }
  # BH-7706: a slot is held from the start of a row's decision to its verdict
  # (PDC_PEND_PLAIN, PDC_PEND_HOT). With every budget slot held, a row first
  # waits for the pending verdicts, so the rule below reads what a serial walk
  # would: a skipped row's slot goes to the next row, and a hotfix spends the
  # exemption only when the budget is really spent. A hotfix never waits for
  # an exemption: HOTFIX_EXTRA is the count of hotfix rows, so one is free.
  while [ "$PDC_ON" = 1 ] && [ "$PDC_PEND_PLAIN" -gt 0 ] && [ $((LAUNCHED + PDC_PEND_PLAIN)) -ge "$BUDGET" ]; do pdc_collect || break; done
  # A hotfix spends a FREE BUDGET SLOT first and the exemption only when the
  # pool is genuinely at cap — `LAUNCHED -ge BUDGET` is the whole of that
  # sentence. Taking the exemption while the budget still had room is a machine
  # past a cap the pool never reached: cap 2, one live, one hotfix + one plain
  # queued would end the tick at THREE machines, and the plain row that rode the
  # freed budget slot is exactly the build the cap was there to refuse.
  # Hotfix files beyond the exemption are ordinary rows and take their turn on
  # the budget like any other, so a project that files six emergencies does not
  # get six free machines on top of six more.
  JF_HOT=0
  if [ "$LAUNCHED" -ge "$BUDGET" ] && [ $((HOT_LAUNCHED + ${PDC_PEND_HOT:-0})) -lt "$HOTFIX_EXTRA" ] && job_is_hot "$JF"; then JF_HOT=1; fi
  if [ "$JF_HOT" = 0 ]; then
    [ "$LAUNCHED" -lt "$BUDGET" ] || break
  fi
  PDC_SEEN=$((PDC_SEEN + 1))
  KEY=$(jq -r '.key // ""' "$JF"); TICKET=$(jq -r '.ticket_id // ""' "$JF"); ATT=$(jq -r '.attempt // 0' "$JF")
  SDEF=$(jq -r '.deferrals // 0' "$JF" 2>/dev/null); case "$SDEF" in ''|*[!0-9]*) SDEF=0 ;; esac
  SDTH=$(jq -r '.deaths // 0' "$JF" 2>/dev/null); case "$SDTH" in ''|*[!0-9]*) SDTH=0 ;; esac
  SSB=$(jq -r '.stack_base // ""' "$JF" 2>/dev/null); case "$SSB" in *[!A-Za-z0-9._/-]*) SSB="" ;; esac
  # Partial-data guard (2026-08-15): a queue entry with no key spawned a machine
  # "for " that idled to death (project-2 d897350c). Validate at the handoff; a bad
  # payload is quarantined loudly, never half-consumed.
  if [ -z "$KEY" ] || [ "$KEY" = "null" ] || [ -z "$TICKET" ] || [ "$TICKET" = "null" ]; then
    mv -f "$JF" "$JF.bad"
    [ -n "$KEY" ] && [ "$KEY" != null ] && QROW failed "$KEY" "malformed queue entry quarantined"
    QUAR+=("$(basename "$JF") (key='$KEY' ticket='$TICKET')")
    continue
  fi
  # skip jobs already running in the pool
  grep -ls "\"key\": *\"$KEY\"" "$POOL"/*.json >/dev/null 2>&1 && continue
  # >>> machines rows (BH-1035)
  # advisory: a live row with no matching file still spawns; log-only, no
  # `continue`. The row is not the gate this slice — it only says out loud that
  # it disagrees with the files, so the disagreement is countable before
  # anything starts trusting it.
  if [ "$MROWS" = 1 ] && [ -n "${LIVE_ROWS:-}" ]; then
    LIVE_ROW=$(printf "%s\n" "$LIVE_ROWS" | awk -F"\t" -v k="$KEY" '$5==k {print $1; exit}')
    [ -n "$LIVE_ROW" ] && say "row says $KEY is live on $LIVE_ROW and no file says so — spawning anyway this cycle (BH-1035 advisory; the row becomes the gate next slice)"
  fi
  # <<< machines rows
  # ...and jobs already launched by THIS tick. The pool json a sibling subshell
  # will write does not exist yet, so the guard above cannot see it: two queue
  # files for one key (a requeue racing its own leftover) would otherwise get two
  # machines. This is the dedupe the parallelism made necessary.
  case "$TICK_KEYS" in *" $KEY "*) continue ;; esac
  TICK_KEYS="$TICK_KEYS$KEY "
  # Dispatch mode (BH-6350): a held job stays queued; LAUNCHED is untouched.
  if command -v dm_job_admit >/dev/null 2>&1 && ! dm_job_admit "$JF"; then
    DM_HELD="${DM_HELD:+$DM_HELD }$KEY"; continue
  fi
  # Spawn-decision gate: HOLD, open PR, terminal state, per-key cap (BH-1075).
  # BH-7706: in a background worker (bin/lib/pool-decide.sh). The tick budget
  # is checked here before each row after the first, as pool_spawn_decision
  # does in a serial walk; workers already started finish and spawn.
  if [ "$PDC_ON" = 1 ]; then
    case "$KEY" in
      RB-*|RR-*|CP-*) ;;
      *) if [ "$PDC_BUDGET_N" -ge 1 ] && pool_tick_budget_spent; then
           [ -n "${_POOL_BUDGET_SAID:-}" ] || say "tick budget of ${POOL_TICK_BUDGET_S:-600}s spent for $P: no more rows are decided this tick, the lock is released at the end"
           _POOL_BUDGET_SAID=1; PDC_STOP=budget; PDC_SEEN=$((PDC_SEEN - 1)); break
         fi ;;
    esac
    pdc_start "$JF_HOT" "$JF" "$KEY" "$TICKET" "$ATT" "$SDTH" "$SSB"
    # The first counted row is decided alone, as the serial walk did: the
    # budget, the stop rule and its PR-unreadable state apply from row 2 on.
    if [ "$PDC_BUDGET_N" = 1 ] && [ "$PDC_FIRST" = 0 ]; then PDC_FIRST=1; pdc_drain; fi
    while [ "${#_PDC_PID[@]}" -ge "$PDC_PAR" ]; do pdc_collect || break; done
    continue
  fi
  if ! pool_spawn_decision "$JF" "$KEY" "$TICKET"; then
    # BH-7421: a spent tick budget ends the walk, so the lock is released.
    [ -n "${_POOL_BUDGET_SAID:-}" ] && break
    continue
  fi
  pool_walk_spawn "$JF_HOT" "$JF" "$KEY" "$TICKET" "$ATT" "$SDTH" "$SSB"
done
# BH-7706: every verdict still out, then one line with what the walk did.
if [ "$PDC_ON" = 1 ]; then
  pdc_drain
  PDC_LEFT=$((PDC_Q - PDC_SEEN)); [ "$PDC_LEFT" -ge 0 ] || PDC_LEFT=0
  [ "$PDC_LEFT" -gt 0 ] && [ -z "$PDC_STOP" ] && PDC_STOP=cap
  pdc_walk_line "$PDC_LEFT"
  pdc_cleanup
fi
# One hold-cache line per tick (BH-6549), only when a GitHub-issue row reached
# the HOLD gate. NOT "pool $P: ..." (tests/pool-autoscale-test.sh reads that).
[ "$_PHC_GATED" = 1 ] && say "hold cache: hits=$_PHC_HITS misses=$_PHC_MISSES bad=$_PHC_BAD listing=${_POOL_HOLD_LIST:-none} read_s=$_PHC_READ_S ttl_s=$_PHC_TTL"
if [ -n "$DM_HELD" ]; then
  DM_N=$(printf '%s' "$DM_HELD" | wc -w | tr -d ' ')
  say "DISPATCH-MODE hotfix-only: held $DM_N queued job(s) ($DM_HELD) — they stay queued; allow-list: $(dm_allow_text)"
fi
if [ "${#QUAR[@]}" = 1 ]; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] QUARANTINED malformed queue entry ${QUAR[0]} — find its producer"
elif [ "${#QUAR[@]}" -gt 1 ]; then
  _QJ=$(printf '%s; ' "${QUAR[@]}")
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$P] QUARANTINED ${#QUAR[@]} malformed queue entries: ${_QJ%; } — find their producer"
fi
# The tick owns its spawns: it does not exit until every one of them has either a
# machine with a job on it or a destroyed machine and a job still queued. Cron's
# next tick then sees a settled pool rather than half-pushed machines.
wait
[ -n "$POOL_MR_BUNDLE" ] && rm -f "$POOL_MR_BUNDLE"
exit 0

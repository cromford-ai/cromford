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
# BH-8318: the guest size and memory of a pool machine (rows vm_size, vm_memory_mb).
# shellcheck source=bin/lib/pool-vm-size.sh
. "$HARNESS/bin/lib/pool-vm-size.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-vm-size.sh" 2>/dev/null || true
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
# BH-7874: the unblock rank (pur_prime, pur_order) orders hotfix_first's last
# group. Missing, that group keeps its age order.
# shellcheck source=bin/lib/pool-unblock-rank.sh
. "$HARNESS/bin/lib/pool-unblock-rank.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-unblock-rank.sh" 2>/dev/null || true
# BH-7643: RB rows — the per-tick limit and the closed/merged PR check
# (pool_rb_max_per_tick, pool_rb_close_if_pr_closed). Missing, RB rows spawn
# as before: no limit, no PR read.
# shellcheck source=bin/lib/pool-rb-rows.sh
. "$HARNESS/bin/lib/pool-rb-rows.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-rb-rows.sh" 2>/dev/null || true
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
  # with them, and so do lead-review rows (LR-<pr>-<head8>, BH-8027) and
  # fix-round rows (FXR-<id>-<ck8>, BH-8065): each is
  # one short machine a merge or a hub lane waits on. Newest by age, they starved
  # behind 130 older builds in the 600 s tick budget (project-6-os, 2026-10-19).
  for f in "$@"; do job_is_hot "$f" && printf '%s\n' "$f"; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) job_is_hot "$f" || printf '%s\n' "$f" ;; esac; done
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) continue ;; esac; job_is_hot "$f" || ! job_is_now "$f" || printf '%s\n' "$f"; done
  # The rest, by unblock count when the lib is there (BH-7874), else by age.
  # Suites cut this function out alone, so pur_order is optional.
  local rest=()
  for f in "$@"; do case "${f##*/}" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) continue ;; esac; job_is_hot "$f" || job_is_now "$f" || rest+=("$f"); done
  [ "${#rest[@]}" -gt 0 ] || return 0
  if [ "${#rest[@]}" -gt 1 ] && command -v pur_order >/dev/null 2>&1; then pur_order "${rest[@]}"
  else printf '%s\n' "${rest[@]}"; fi
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
# BH-8309: pbs_stop_check, the spawn gate for a key whose newest record is
# PLAN_BLOCKED. Missing, the gate is skipped and the pool spawns as before.
# shellcheck source=bin/lib/plan-blocked-stop.sh
. "$HARNESS/bin/lib/plan-blocked-stop.sh" 2>/dev/null || true
# BH-8335: ptr_build/ptr_push, a machine's own route to the Fly test host.
# A tree without the lib ships no route, and the gate names the miss.
# shellcheck source=bin/lib/pool-testhost-route.sh
. "$HARNESS/bin/lib/pool-testhost-route.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-testhost-route.sh" 2>/dev/null || true
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
# The listed issue object per issue number, and the hold-read counters (BH-7942)
declare -A _POOL_HOLD_IJ=()
_PHR_V=""; _PHR_BATCHED=0; _PHR_RETRIES=0; _PHR_RETRY_OK=0; _PHR_RETRY_OFF=0; _PHC_LIST_RETRIED=0
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
# BH-7942: POOL_HOLD_READ_TIMEOUT_S (45, a lane knob) cuts every HOLD read: the
# ai-build listing pages, an issue GET and a comments read. 0 = no cut.
case "${POOL_HOLD_READ_TIMEOUT_S:-}" in
  '') POOL_HOLD_READ_TIMEOUT_S=45 ;;
  *[!0-9]*) say "POOL_HOLD_READ_TIMEOUT_S=$POOL_HOLD_READ_TIMEOUT_S is not a number of seconds (0-300) — using 45"; POOL_HOLD_READ_TIMEOUT_S=45 ;;
esac
[ "$POOL_HOLD_READ_TIMEOUT_S" -le 300 ] || POOL_HOLD_READ_TIMEOUT_S=300
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
pool_rest_read() { # pool_rest_read <api-path> [token] -> line 1 = HTTP code (empty if none, TIMEOUT if the read was cut), rest = body
  local _path="$1" _tok="${2:-}" _raw=""
  # -i puts the status line on STDOUT even on a 4xx, which is the whole point:
  # a 404 and a 403 are both "gh exited 1" without it.
  # BH-7421: a read cut at POOL_GH_READ_TIMEOUT_S (rc 124, or 137) prints the
  # word TIMEOUT as line 1, never a hung tick, so a caller can tell "the read
  # was cut" from "no status line" (an empty line 1).
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
  # BH-7942: a ticket the tick's ai-build listing carries is classified from
  # that listed object (one comments read, no issue GET); any other ticket
  # reads its own issue. Both are cut at POOL_HOLD_READ_TIMEOUT_S.
  local ij="${_POOL_HOLD_IJ[$ticket]:-}"
  if [ -n "$ij" ] && command -v hold_check_issue >/dev/null 2>&1; then
    v=$(POOL_GH_READ_TIMEOUT_S="${POOL_HOLD_READ_TIMEOUT_S:-45}" hold_check_issue "$POOL_SLUG" "$ticket" "$ij" 2>/dev/null) || true
  else
    v=$(POOL_GH_READ_TIMEOUT_S="${POOL_HOLD_READ_TIMEOUT_S:-45}" hold_check "$POOL_SLUG" "$ticket" 2>/dev/null) || true
  fi
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

# pool_hold_read <ticket> (BH-7942) — pool_hold_check, in the CALLER's shell,
# with ONE retry inside the tick: a read that did not answer is read again
# before the row is skipped. The verdict is in _PHR_V; rc 0 always. A why that
# no second read can change (no slug, no number, no jq) is not retried. After
# one row's retry also fails, the rest of the tick reads once per row
# (_PHR_RETRY_OFF), so a GitHub that is down does not double every row's cost.
# A retry never touches a hold marker: the caller's unreadable arm still keeps
# the last known state.
pool_hold_read() {
  local t="${1:-}"
  case "$t" in ''|*[!0-9]*) ;; *)
    [ -n "${_POOL_HOLD_IJ[$t]:-}" ] && command -v hold_check_issue >/dev/null 2>&1 && _PHR_BATCHED=$((_PHR_BATCHED + 1)) ;;
  esac
  _PHR_V=$(pool_hold_check "$t" 2>/dev/null) || true
  case "$_PHR_V" in
    "unreadable	"*) ;;
    *) return 0 ;;
  esac
  case "${_PHR_V#unreadable	}" in
    "no owner/repo"*|"no issue number"*|"jq is not on PATH"*|"missing slug or ticket"*|"no issue json"*) return 0 ;;
  esac
  [ "$_PHR_RETRY_OFF" = 0 ] || return 0
  _PHR_RETRIES=$((_PHR_RETRIES + 1))
  say "hold read for ${KEY:-$t} unreadable (${_PHR_V#unreadable	}): retrying once"
  _PHR_V=$(pool_hold_check "$t" 2>/dev/null) || true
  case "$_PHR_V" in
    "unreadable	"*)
      _PHR_RETRY_OFF=1
      say "hold reads: retry off for the rest of this tick (the retry for ${KEY:-$t} did not answer either)" ;;
    *) _PHR_RETRY_OK=$((_PHR_RETRY_OK + 1)) ;;
  esac
  return 0
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

# pool_ai_listing_page <page> — one page of the open ai-build issue listing,
# answered in pool_rest_read's shape into _PAL_OUT (caller's shell, never a
# substitution). A 200 page is kept for the rest of the process, so the unblock
# rank (pur_prime, BH-7874) and the hold cache below share ONE listing per tick
# (tests/fly-pool-decide-all.bh-7706-test.sh A1). A failed page is not kept:
# the next reader asks again, as it did before the share. The listing is a
# hold read whoever reads it first, so it takes the hold read's cut (BH-7942).
declare -A _POOL_AI_LIST_PAGE=()
pool_ai_listing_page() {
  local pg="${1:-1}"
  local POOL_GH_READ_TIMEOUT_S="${POOL_HOLD_READ_TIMEOUT_S:-45}"
  if [ -n "${_POOL_AI_LIST_PAGE[$pg]+x}" ]; then _PAL_OUT="200"$'\n'"${_POOL_AI_LIST_PAGE[$pg]}"; return 0; fi
  _PAL_OUT=$(pool_rest_read "repos/$POOL_SLUG/issues?state=open&labels=ai-build&per_page=100&page=$pg" "${POOL_SLUG_TOK:-}")
  case "$_PAL_OUT" in 200$'\n'*) _POOL_AI_LIST_PAGE[$pg]=${_PAL_OUT#*$'\n'} ;; esac
  return 0
}

# pool_hold_list_prime — the open ai-build issue listing, once per process,
# into _POOL_HOLD_LKEY[<n>]. _POOL_HOLD_LIST says how it went: ok, truncated
# (the page cap was reached on a full page; later issues miss) or
# unreadable(<code>) (every row misses: the table is emptied).
pool_hold_list_prime() {
  [ -n "$_POOL_HOLD_LIST" ] && return 0
  local page=1 _out _code _body _rows _len n u c j
  # BH-7942: the listing is a hold read, so it takes the hold read's cut.
  local POOL_GH_READ_TIMEOUT_S="${POOL_HOLD_READ_TIMEOUT_S:-45}"
  _POOL_HOLD_LIB=$(cksum < "$HARNESS/bin/lib/hold.sh" 2>/dev/null | awk '{print $1 "-" $2}')
  while [ "$page" -le "$_PHC_PAGES" ]; do
    pool_ai_listing_page "$page"; _out=$_PAL_OUT
    _code=$(head -n 1 <<<"$_out"); _body=$(tail -n +2 <<<"$_out")
    # BH-7942: one page that did not answer is read once more in this tick.
    [ "$_code" != 200 ] && [ "$_PHC_LIST_RETRIED" = 0 ] && { _PHC_LIST_RETRIED=1; continue; }
    if [ "$_code" != 200 ]; then
      _POOL_HOLD_LKEY=(); _POOL_HOLD_IJ=(); _POOL_HOLD_LIST="unreadable(${_code:-none})"; return 0
    fi
    if ! _rows=$(phc_listing_keys "$_body"); then
      _POOL_HOLD_LKEY=(); _POOL_HOLD_IJ=(); _POOL_HOLD_LIST="unreadable(body)"; return 0
    fi
    while IFS=$'\t' read -r n u c; do
      [ -n "$n" ] && [ -n "$c" ] && _POOL_HOLD_LKEY[$n]="$u|$c"
    done <<<"$_rows"
    # BH-7942: each complete listed issue, so its row reads only its comments.
    if command -v phc_listing_issues >/dev/null 2>&1; then
      while IFS=$'\t' read -r n j; do
        [ -n "$n" ] && [ -n "$j" ] && _POOL_HOLD_IJ[$n]="$j"
      done < <(phc_listing_issues "$_body")
    fi
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
# pool_key_slice_merged <key> — rc 0 when a local build record for <key>
# (builds/pool-<P>-<key>-*/RESULT or builds/<P>-<key>-*/RESULT, the record
# names mc_record_for reads) has line 1 `PR_CREATED <url>` and that url is a line of
# state/merge-sweep-done.txt, which both merge lanes write on a merge. rc 1
# otherwise. Local files only, no network read.
pool_key_slice_merged() {
  local key="$1" f url done="$HARNESS/state/merge-sweep-done.txt"
  [ -n "$key" ] && [ -r "$done" ] || return 1
  for f in "$HARNESS/builds/pool-$P-$key-"*/RESULT "$HARNESS/builds/$P-$key-"*/RESULT; do
    [ -r "$f" ] || continue
    url=$(head -n 1 "$f" 2>/dev/null)
    case "$url" in "PR_CREATED https://"*) url="${url#PR_CREATED }"; url="${url%% *}" ;; *) continue ;; esac
    grep -qxF "$url" "$done" && return 0
  done
  return 1
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
# A QUEUED BLOCKER WHOSE SLICE MERGED IS NOT IN FLIGHT (BH-7731). A multi-slice
# ticket stays open after a slice merges, and its next slice is queued but not
# built. A queue file or a `queued` row then held every sibling until the
# 360-min ceiling. When pool_key_slice_merged says the key's build PR merged,
# a queued (not claimed) blocker is judged by its PR reads alone.
pool_after_open() {
  local other="$1" st queued=0
  case "${TICK_KEYS:-}" in *" $other "*) return 0 ;; esac
  grep -lsE "\"key\": *\"$other\"" "$POOL"/*.json >/dev/null 2>&1 && return 0
  [ -e "$QDIR/$other.json" ] && queued=1
  # BH-7706: the tick read the queued and claimed rows once (pdc_queue_prime).
  # From a complete listing a key that is absent is neither; any other listing
  # leaves the per-key read below.
  if [ "${_PDC_QOK:-0}" = 1 ]; then
    case "${_PDC_QSTATE[$other]:-}" in claimed) return 0 ;; queued) queued=1 ;; esac
  elif command -v queue_status >/dev/null 2>&1; then
    st=$(queue_status "$P" "$other" 2>/dev/null) || st=""
    case "$st" in claimed) return 0 ;; queued) queued=1 ;; esac
  fi
  [ "$queued" = 1 ] && ! pool_key_slice_merged "$other" && return 0
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
    # BH-7643: a rebase of a closed or merged PR gets no machine (the row is
    # closed and its file removed). This covers the reuse handoff too.
    RB-*) if command -v pool_rb_close_if_pr_closed >/dev/null 2>&1 \
             && pool_rb_close_if_pr_closed "$JF" "$KEY" "$TICKET"; then return 1; fi
          say "$KEY: rebase row — the ticket spawn gates do not apply"; return 0 ;;
    RR-*) say "$KEY: re-review row — the ticket spawn gates do not apply"; return 0 ;;
    LR-*) say "$KEY: lead-review row — the ticket spawn gates do not apply"; return 0 ;;
    # A console preview row (BH-8030): a build of one PR head for the hub's
    # console preview lane, which owns its retries. Never a ticket.
    CP-*) say "$KEY: console preview row — the ticket spawn gates do not apply"; return 0 ;;
    # A fix-round row (BH-8065): one blocked-resolver round the project box
    # placed on the pool; the box's stale re-offer owns its retries.
    FXR-*-*) say "$KEY: fix-round row — the ticket spawn gates do not apply"; return 0 ;;
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
  # >>> plan-blocked stop (BH-8309)
  # 0a. A key whose newest hub record is PLAN_BLOCKED is not relaunched into the
  # same stop (bin/lib/plan-blocked-stop.sh): "already done on main by <sha>"
  # closes the ticket once, a named prerequisite holds the row until it closes,
  # and any other reason stops after POOL_PLAN_BLOCKED_MAX in the window with
  # one NEEDS_HUMAN hold. The row stays queued. Below pool_gates_applicable
  # because it reads GitHub; above the HOLD gate and the cap, so a refusal
  # costs no spawn-cap count.
  if command -v pbs_stop_check >/dev/null 2>&1 && ! pbs_stop_check "$P" "$KEY" "$TICKET" "$JF"; then
    return 1
  fi
  # <<< plan-blocked stop
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
    pool_hold_read "$TICKET"; v="$_PHR_V"
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

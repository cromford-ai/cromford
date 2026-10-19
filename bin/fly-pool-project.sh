#!/bin/bash
# bin/fly-pool-project.sh <project> [<project>] — the pool tick of ONE project
# on a lane-run machine, under the project lease (BH-7505, part of #6881).
# bin/fly-pool-project.sh --preflight <project> prints what a spawn needs and
# this machine lacks (below), and runs nothing else.
#
# The hub enqueues this as a lane_runs row of lane fly-pool, project <project>
# (bin/lib/pool-placement.sh, with lane_placement.fly-pool.<project> = fly).
# bin/lane-run-worker.sh runs it through bin/project-lane-run.sh, which appends
# the row's project as the last argument, so a second argument must equal the
# first. Steps:
#
#   1. check    the project has a repo in fleet.conf. Else exit 2.
#   2. lease    pjl_acquire fly-pool <project> <holder> (holder: FLY_MACHINE_ID,
#               else machine-<hostname>). 409 `held` prints
#               `PROF fly-pool-project state=LEASE_HELD ...` and exits 0: the
#               hub or another machine runs the project, and this run does
#               nothing. No answer prints state=LEASE_UNAVAILABLE and exits 75.
#   3. preflight  a spawn from a machine needs four things the image and the
#               secrets of the lane-run app must give it, and each one that is
#               missing is a word in the list `deferred=`:
#                 fly-binary   flyctl in FLY_BIN_DIR (default /root/.fly/bin) or on PATH
#                 fly-token    FLY_API_TOKEN_<PROJECT> (or the org FLY_API_TOKEN)
#                                in the machine's environment, as a Fly secret
#                 harness-src  POOL_HARNESS_SRC (default /root/harness-checkout)
#                                holding bin prompts rules catalog fly: the tree
#                                a spawn tars to its build machine
#                 env-bundle   the owning box answers over the tailnet (ssh and
#                                a key), or the project is owned by the hub
#                                (tailnet_ip `local`): the env bundle comes from there
#               With any missing, the run does no pool work: it releases the
#               lease, prints `PROF fly-pool-project state=DEFERRED ...
#               deferred=<words>` and exits 0, and the hub runs the tick
#               itself (fallback=machine-deferred) and holds off a new row for
#               POOL_FLY_TAKEBACK_BACKOFF_S. A tick that spawned from a
#               machine that lacked one of them would only fail its spawns.
#   4. run      bin/fly-pool.sh <project> with POOL_ON_MACHINE=1
#               and the lease exported (POOL_LEASE_FENCE, POOL_LEASE_PROJECT,
#               POOL_LEASE_HOLDER, POOL_STOP_FILE). Before a spawn and before a
#               destroy the tick renews the fence (pp_fence_ok); a lease that
#               answers `lost` touches the stop file and the tick spends
#               nothing more. After each spawn record the tick posts a
#               write-back (pp_checkpoint). A background loop renews the lease
#               every POOL_PROJECT_RENEW_S (default 60) seconds and ends with
#               this script.
#   5. write    lri_checkpoint fly-pool <project> (when LANE_RUN_ID is set and
#      back     the lease was not lost): the files the run changed go to the
#               hub as one write-back. A failure exits 75.
#   6. release  pjl_release, then ONE line
#               `PROF fly-pool-project state=<S> spawned=<n> reaped=<n> deferred=<w|-> fence=<f>`.
#               S is TICKED, FAILED (the tick's rc is not 0; the rc is kept),
#               LEASE_LOST, STOPPED (a TERM) or DEFERRED. spawned and reaped
#               count the `spawned <id>` and `reaped ... from <id>` lines the
#               tick added to logs/fly-pool.log.
#
# The run's own start and end are two lines in logs/fly-pool.log
# (`[pool/<p>] fly run start on <holder> ...`), which rides back to the hub with
# the write-back, so the hub log shows which lines a machine wrote.
#
# TERM or INT (a Fly stop; bin/lane-run-worker.sh TERMs the run's process
# group): the stop file is touched, the tick gets up to POOL_PROJECT_TERM_WAIT_S
# (default 12, under lane_run.term_grace_s 20) to end its running spawns, then
# its whole process tree is TERMed and KILLed. The write-back is posted, the
# lease released and the run exits 0; the worker then releases the row to
# `queued` (the BH-6495 hand-off). A spawn killed between `fly machine run` and
# its record leaves a build machine the hub's orphan release and the machine's
# own warmup exit end (bin/lib/pool-orphan-rows.sh, WARMUP_WAIT_S).
#
# The exit code is the tick's own. Note: docs/notes/2026-10-19-BH-7505-pool-tick-on-fly.md.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"

usage() { echo "usage: fly-pool-project.sh [--preflight] <project> [<project>]" >&2; exit 2; }
PREFLIGHT=0
[ "${1:-}" = --preflight ] && { PREFLIGHT=1; shift; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
P="$1"
[ "$#" = 2 ] && [ "$2" != "$P" ] && { echo "fly-pool-project: run project '$2' is not '$P'" >&2; exit 2; }
[[ $P =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "fly-pool-project: project '$P' is not a path-safe name" >&2; exit 2; }
REPO=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || REPO=""
case "$REPO" in */*) ;; *) echo "fly-pool-project: no fleet.conf repo for '$P'" >&2; exit 2 ;; esac

# project-lane-run.sh holds locks/fly-pool-<p>.lock on PL_LOCK_FD, the file
# bin/fly-pool.sh locks for itself. Two open descriptions of one file would turn
# the tick away, so the run's copy goes now: one live row per project
# (lane_runs_live) and the lease keep the run single.
if [[ ${PL_LOCK_FD:-} =~ ^[0-9]+$ ]]; then eval "exec ${PL_LOCK_FD}>&-"; unset PL_LOCK_FD; fi

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
set +e
# shellcheck source=bin/lib/project-lease.sh
. "$H/bin/lib/project-lease.sh" || exit 1
# shellcheck source=bin/lib/lane-run-inputs.sh
[ -r "$H/bin/lib/lane-run-inputs.sh" ] && . "$H/bin/lib/lane-run-inputs.sh"
# shellcheck source=bin/lib/pool-placement.sh
. "$H/bin/lib/pool-placement.sh" || exit 1
# shellcheck source=bin/lib/fly-token.sh
. "$H/bin/lib/fly-token.sh" 2>/dev/null || true

LANE=fly-pool
HOLDER="${FLY_MACHINE_ID:-machine-$(hostname 2>/dev/null)}"
HOLDER="${HOLDER//[^A-Za-z0-9._-]/_}"; HOLDER="${HOLDER:0:64}"
RENEW_S="${POOL_PROJECT_RENEW_S:-60}"; [[ $RENEW_S =~ ^[0-9]+$ ]] && [ "$RENEW_S" -ge 1 ] || RENEW_S=60
WAIT_S="${POOL_PROJECT_TERM_WAIT_S:-12}"; [[ $WAIT_S =~ ^[0-9]+$ ]] || WAIT_S=12
LOG="$H/logs/fly-pool.log"

# pfp_missing <project> — a comma list of what a spawn needs and this machine
# lacks, empty when nothing is missing.
pfp_missing() {
  local p="$1" miss="" fb src d ip
  fb="${FLY_BIN_DIR:-/root/.fly/bin}"
  if ! [ -x "$fb/fly" ] && ! [ -x "$fb/flyctl" ] && ! command -v fly >/dev/null 2>&1 && ! command -v flyctl >/dev/null 2>&1; then
    miss+="${miss:+,}fly-binary"
  fi
  if declare -F fly_token_resolve >/dev/null 2>&1; then fly_token_resolve "$p" || miss+="${miss:+,}fly-token"
  else miss+="${miss:+,}fly-token"; fi
  src="${POOL_HARNESS_SRC:-/root/harness-checkout}"
  for d in bin prompts rules catalog fly; do
    [ -d "$src/$d" ] || { miss+="${miss:+,}harness-src"; break; }
  done
  ip=$("$H/bin/fleet-conf.sh" --tailnet-ip "$p" 2>/dev/null)
  if [ "$ip" != local ]; then
    { [ -n "$ip" ] && command -v ssh >/dev/null 2>&1 && compgen -G "${HOME:-/root}/.ssh/id_*" >/dev/null 2>&1; } \
      || miss+="${miss:+,}env-bundle"
  fi
  printf '%s' "$miss"
}

if [ "$PREFLIGHT" = 1 ]; then
  m=$(pfp_missing "$P")
  if [ -z "$m" ]; then echo "preflight $P: ok"; exit 0; fi
  echo "preflight $P: missing $m"; exit 1
fi

prof() { printf 'PROF fly-pool-project state=%s spawned=%s reaped=%s deferred=%s fence=%s\n' "$@"; }
mlog() { printf '%s [pool/%s] %s\n' "$(date -u '+%F %TZ')" "$P" "$*" >> "$LOG" 2>/dev/null; }
mkdir -p "$H/state/fly-pool-project" "$H/logs" 2>/dev/null

# A TERM before the tick starts only marks it: each step below checks.
TERMED=0; FENCE=""; CPID=""; RPID=""; TMP=""; DEFERRED="-"; LOG0=0
trap 'TERMED=1' TERM INT

FENCE=$(pjl_acquire "$LANE" "$P" "$HOLDER"); arc=$?
case "$arc" in
  0) ;;
  3) mlog "fly run on $HOLDER: the project lease is held by another holder — nothing run"; prof LEASE_HELD 0 0 - -; exit 0 ;;
  *) mlog "fly run on $HOLDER: the project lease was not answered (http ${JOBS_HTTP:-none}) — nothing run"; prof LEASE_UNAVAILABLE 0 0 - -; exit 75 ;;
esac
if [ "$TERMED" = 1 ]; then
  pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1
  mlog "fly run on $HOLDER: TERM before the run — lease released, nothing run"; prof STOPPED 0 0 - "$FENCE"; exit 0
fi

TMP=$(mktemp -d "$H/state/fly-pool-project/run.XXXXXX") || { pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1; exit 1; }
STOP="$TMP/stop"; LOST="$TMP/lost"
# The lane log's size now: spawned= and reaped= count what this run adds.
LOG0=$(stat -c %s "$LOG" 2>/dev/null || echo 0)

# counts <pattern> — the lines the tick added to the lane log since LOG0 that match.
counts() {
  local n
  n=$(tail -c "+$((LOG0 + 1))" "$LOG" 2>/dev/null | grep -cE -- "$1")
  printf '%s' "${n:-0}"
}

# renew_loop — renews the lease every RENEW_S seconds; on `lost` it touches the
# stop file and the lost mark, and ends. It ends with its parent.
renew_loop() {
  local rc parent="$1"
  trap - TERM INT
  while kill -0 "$parent" 2>/dev/null; do
    sleep "$RENEW_S"
    kill -0 "$parent" 2>/dev/null || break
    pjl_renew "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 3 ]; then
      : > "$LOST"; : > "$STOP"
      mlog "fly run on $HOLDER: project lease lost (fence $FENCE) — the tick spends nothing more"
      return 0
    fi
  done
}

# tree <pid> — <pid> and every live descendant, parents first.
tree() {
  local c
  printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done
}
any_alive() {
  local x
  for x in "$@"; do kill -0 "$x" 2>/dev/null && return 0; done
  return 1
}
# reap — TERM the tick's whole tree, then KILL what is left (at most 5 s).
reap() {
  local pids i=0
  [ -n "$CPID" ] || return 0
  pids=$(tree "$CPID" | tr '\n' ' ')
  kill -TERM -- "-$CPID" 2>/dev/null
  # shellcheck disable=SC2086 # a list of pids
  kill -TERM $pids 2>/dev/null
  # shellcheck disable=SC2086
  while [ "$i" -lt 10 ] && any_alive $pids; do sleep 0.5; i=$((i + 1)); done
  kill -KILL -- "-$CPID" 2>/dev/null
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  wait "$CPID" 2>/dev/null
}

# finish <rc> <state-or-empty> — steps 5 and 6, once.
finish() {
  local rc="$1" st="${2:-}" n_s n_r out
  trap '' TERM INT
  [ -n "$RPID" ] && { kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; }
  [ -n "$CPID" ] && [ -n "$(pgrep -P "$CPID" 2>/dev/null)" ] && reap
  n_s=$(counts 'spawned [0-9a-f]{14} for '); n_r=$(counts 'reaped .* from [0-9a-f]{14}')
  if [ -z "$st" ]; then
    # The stop file without a TERM is a lost lease: the renew loop, or the
    # tick's own renew (pp_fence_ok), touched it.
    if [ -e "$LOST" ] || { [ -e "$STOP" ] && [ "$TERMED" = 0 ]; }; then st=LEASE_LOST
    elif [ "$TERMED" = 1 ]; then st=STOPPED
    elif [ "$rc" != 0 ]; then st=FAILED
    else st=TICKED; fi
  fi
  mlog "fly run end on $HOLDER: state=$st spawned=$n_s reaped=$n_r rc=$rc"
  if [ "$st" != LEASE_LOST ] && [ -n "${LANE_RUN_ID:-}" ] && declare -F lri_checkpoint >/dev/null 2>&1; then
    if ! out=$(lri_checkpoint "$LANE" "$P" 2>&1); then
      mlog "fly run on $HOLDER: write-back failed ($(printf '%s' "$out" | tail -n 1))"
      [ "$rc" = 0 ] && rc=75
    fi
  fi
  pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1 || mlog "fly run on $HOLDER: lease release not answered — it expires at its TTL"
  prof "$st" "$n_s" "$n_r" "$DEFERRED" "$FENCE"
  case "$TMP" in "$H/state/fly-pool-project/run."?*) rm -rf "$TMP" ;; esac
  exit "$rc"
}

on_term() {
  local i=0
  trap '' TERM INT
  TERMED=1
  : > "$STOP"
  mlog "fly run on $HOLDER: TERM — no new spawn (wait ${WAIT_S}s)"
  if [ -n "$CPID" ]; then
    while kill -0 "$CPID" 2>/dev/null && [ "$i" -lt "$WAIT_S" ]; do sleep 1; i=$((i + 1)); done
    reap
  fi
  finish 0
}
trap on_term TERM INT
[ "$TERMED" = 1 ] && on_term

# The preflight, after the lease: a machine that cannot spawn does no pool work.
DEFERRED=$(pfp_missing "$P")
if [ -n "$DEFERRED" ]; then
  mlog "fly run on $HOLDER: this machine cannot run the pool tick (missing: $DEFERRED) — nothing run, the hub takes the tick back"
  finish 0 DEFERRED
fi
DEFERRED="-"

# An empty fleet env file: bin/fly-pool.sh sources fly.env, and a lane-run
# machine has the Fly token as a Fly secret in its environment instead.
# shellcheck source=bin/lib/env-path.sh
if [ -r "$H/bin/lib/env-path.sh" ]; then
  . "$H/bin/lib/env-path.sh" 2>/dev/null
  ENVD=$(harness_env_dir "$H" 2>/dev/null)
  [ -n "$ENVD" ] && mkdir -p "$ENVD" 2>/dev/null && { [ -e "$ENVD/fly.env" ] || : > "$ENVD/fly.env"; }
fi

mlog "fly run start on $HOLDER (row ${LANE_RUN_ID:-none}, fence $FENCE)"
renew_loop "$$" 8>&- & RPID=$!

CENV=(POOL_ON_MACHINE=1
  POOL_LEASE_FENCE="$FENCE" POOL_LEASE_PROJECT="$P" POOL_LEASE_HOLDER="$HOLDER" POOL_STOP_FILE="$STOP")
# A TERM between the fork and `CPID=$!` is held (ignored), then replayed once
# CPID is known.
trap 'TERMED=1' TERM INT
if command -v setsid >/dev/null 2>&1; then
  setsid env "${CENV[@]}" "$H/bin/fly-pool.sh" "$P" </dev/null &
else
  env "${CENV[@]}" "$H/bin/fly-pool.sh" "$P" </dev/null &
fi
CPID=$!
trap on_term TERM INT
[ "$TERMED" = 1 ] && on_term
wait "$CPID"; crc=$?
# A TERM during the wait runs on_term, which never returns here.
finish "$crc"

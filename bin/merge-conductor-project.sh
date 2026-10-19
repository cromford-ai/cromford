#!/bin/bash
# bin/merge-conductor-project.sh <project> [<project>] — the merge conductor
# for ONE whole project on a lane-run machine, under the project lease
# (BH-6890, BH-6881.6).
#
# The hub enqueues this as a lane_runs row of lane merge-conductor, project
# <project> (bin/lib/mc/project-placement.sh, with
# lane_placement.merge-conductor.<project> = fly). bin/lane-run-worker.sh runs
# it through bin/project-lane-run.sh, which appends the row's project as the
# last argument, so a second argument must equal the first. Steps:
#
#   1. check    the project has a repo in fleet.conf. Else exit 2.
#   2. lease    pjl_acquire merge-conductor <project> <holder> (holder:
#               FLY_MACHINE_ID, else machine-<hostname>). 409 `held` prints
#               `PROF mc-project state=LEASE_HELD ...` and exits 0: the hub
#               enqueues again on its next tick. No answer prints
#               state=LEASE_UNAVAILABLE and exits 75.
#   3. run      bin/merge-conductor.sh with MC_ONLY_PROJECT=<project>,
#               MC_ON_MACHINE=1, MC_LEASED_RUN=1 and the lease exported
#               (MC_LEASE_FENCE, MC_LEASE_PROJECT, MC_LEASE_HOLDER): a full
#               tick of this project only, which may enqueue READY PRs into
#               the repo's merge queue. Every landing writer renews the fence
#               first (mc_lease_fence_ok). A background loop renews the lease
#               every MC_PROJECT_RENEW_S (default 60) seconds. A renew that
#               answers `lost` touches the stop file: the conductor starts no
#               further PR worker (the PR boundary) and writes nothing more.
#   4. write    lri_checkpoint merge-conductor <project> (when LANE_RUN_ID is
#      back     set, and not after a lost lease): the files the run changed
#               go to the hub as one write-back. A failure exits 75.
#   5. release  pjl_release, then ONE line
#               `PROF mc-project state=<S> landed=<n> queued=<n> deferred=<w|-> fence=<f>`.
#               S is MERGED when the run saw one of its landings merged,
#               QUEUED when it enqueued one, LEASE_LOST when the lease was
#               lost, STOPPED after a TERM, else TICKED. deferred= names the
#               steps the machine left to the hub (rebase, rereview, settle,
#               ...), comma-joined; the hub's next tick of the project runs
#               them (fallback=machine-deferred).
#
# TERM or INT (a Fly stop; bin/lane-run-worker.sh TERMs the run's process
# group): the stop file is touched, the conductor gets up to
# MC_PROJECT_TERM_WAIT_S (default 12, under lane_run.term_grace_s 20) to
# finish its running PR workers, then its whole process tree is TERMed and
# KILLed (reap; walked by pid where there is no setsid). Only then are the
# stop file and the run dir removed. The write-back is posted, the lease
# released and the run exits 0; the worker then releases the row to `queued`
# (the BH-6495 hand-off). The conductor runs in its own process group, so the
# group TERM reaches it only through this script. A TERM before the conductor
# starts releases the lease and runs nothing.
#
# A run that lost its lease (LEASE_LOST) posts no write-back of its own.
# bin/lane-run-worker.sh still posts its final one after the run; the hub
# applies it compare-and-set, so a newer copy of a file on the hub wins.
#
# The exit code is the conductor's own. Contract:
# docs/notes/2026-10-19-BH-6890-conductor-per-project.md.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"

usage() { echo "usage: merge-conductor-project.sh <project> [<project>]" >&2; exit 2; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
P="$1"
[ "$#" = 2 ] && [ "$2" != "$P" ] && { echo "merge-conductor-project: run project '$2' is not '$P'" >&2; exit 2; }
[[ $P =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "merge-conductor-project: project '$P' is not a path-safe name" >&2; exit 2; }
REPO=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || REPO=""
case "$REPO" in */*) ;; *) echo "merge-conductor-project: no fleet.conf repo for '$P'" >&2; exit 2 ;; esac

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
set +e
# shellcheck source=bin/lib/project-lease.sh
. "$H/bin/lib/project-lease.sh" || exit 1
# shellcheck source=bin/lib/lane-run-inputs.sh
[ -r "$H/bin/lib/lane-run-inputs.sh" ] && . "$H/bin/lib/lane-run-inputs.sh"

LANE=merge-conductor
HOLDER="${FLY_MACHINE_ID:-machine-$(hostname 2>/dev/null)}"
HOLDER="${HOLDER//[^A-Za-z0-9._-]/_}"; HOLDER="${HOLDER:0:64}"
RENEW_S="${MC_PROJECT_RENEW_S:-60}"; [[ $RENEW_S =~ ^[0-9]+$ ]] && [ "$RENEW_S" -ge 1 ] || RENEW_S=60
WAIT_S="${MC_PROJECT_TERM_WAIT_S:-12}"; [[ $WAIT_S =~ ^[0-9]+$ ]] || WAIT_S=12

prof() { printf 'PROF mc-project state=%s landed=%s queued=%s deferred=%s fence=%s\n' "$@"; }
mlog() { printf '%s [merge-conductor-project] %s: %s\n' "$(date -u '+%F %TZ')" "$P" "$*" >> "$H/logs/merge-conductor.log" 2>/dev/null; }
mkdir -p "$H/state/merge-conductor-project" "$H/logs" 2>/dev/null

# A TERM before the conductor starts only marks it: each step below checks.
TERMED=0; FENCE=""; CPID=""; RPID=""; TMP=""
trap 'TERMED=1' TERM INT

FENCE=$(pjl_acquire "$LANE" "$P" "$HOLDER"); arc=$?
case "$arc" in
  0) ;;
  3) mlog "project lease held by another holder — nothing run"; prof LEASE_HELD 0 0 - -; exit 0 ;;
  *) mlog "project lease not answered (http ${JOBS_HTTP:-none}) — nothing run"; prof LEASE_UNAVAILABLE 0 0 - -; exit 75 ;;
esac
if [ "$TERMED" = 1 ]; then
  pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1
  mlog "TERM before the run — lease released, nothing run"; prof STOPPED 0 0 - "$FENCE"; exit 0
fi

TMP=$(mktemp -d "$H/state/merge-conductor-project/run.XXXXXX") || { pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1; exit 1; }
STOP="$TMP/stop"; LOST="$TMP/lost"; DEF="$TMP/deferred"; LANDED="$TMP/landed"
: > "$DEF"; : > "$LANDED"

# renew_loop — renews the lease every RENEW_S seconds; on `lost` it touches
# the stop file and the lost mark, and ends.
renew_loop() {
  local rc
  trap - TERM INT
  while :; do
    sleep "$RENEW_S"
    pjl_renew "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 3 ]; then
      : > "$LOST"; : > "$STOP"
      mlog "project lease lost (fence $FENCE) — stop at the next PR boundary"
      return 0
    fi
  done
}

# tree <pid> — <pid> and every live descendant, parents first. A host with
# no setsid (a Mac) cannot signal the conductor's group, so the tree is
# walked while the conductor still lives: its children are not orphaned yet.
tree() {
  local c
  printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done
}

# any_alive <pid>... — rc 0 when one of them lives.
any_alive() {
  local x
  for x in "$@"; do kill -0 "$x" 2>/dev/null && return 0; done
  return 1
}

# reap — TERM the conductor's whole tree, then KILL what is left, then wait
# until no process of it lives (at most 5 s). The stop file is removed only
# after this, so no worker can miss it.
reap() {
  local pids i=0
  [ -n "$CPID" ] || return 0
  pids=$(tree "$CPID" | tr '\n' ' ')
  kill -TERM -- "-$CPID" 2>/dev/null
  # shellcheck disable=SC2086 # a list of pids
  kill -TERM $pids 2>/dev/null
  while [ "$i" -lt 10 ] && any_alive $pids; do sleep 0.5; i=$((i + 1)); done
  kill -KILL -- "-$CPID" 2>/dev/null
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  wait "$CPID" 2>/dev/null
}

# finish <rc> — step 4 and 5, once.
finish() {
  local rc="$1" st n_m n_q defw out
  trap '' TERM INT
  [ -n "$RPID" ] && { kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; }
  # A stragglers' check: a normal exit leaves no worker, a TERM path reaped.
  [ -n "$CPID" ] && [ -n "$(pgrep -P "$CPID" 2>/dev/null)" ] && reap
  n_m=$(grep -c '^merged ' "$LANDED" 2>/dev/null); n_q=$(grep -c '^queued ' "$LANDED" 2>/dev/null)
  defw=$(sort -u "$DEF" 2>/dev/null | tr -cd 'a-z\n' | grep . | paste -sd, -)
  # The stop file without a TERM is a lost lease: the renew loop, or a landing
  # writer's renew (mc_lease_fence_ok), touched it.
  if [ -e "$LOST" ] || { [ -e "$STOP" ] && [ "$TERMED" = 0 ]; }; then st=LEASE_LOST
  elif [ "$TERMED" = 1 ]; then st=STOPPED
  elif [ "${n_m:-0}" -gt 0 ]; then st=MERGED
  elif [ "${n_q:-0}" -gt 0 ]; then st=QUEUED
  else st=TICKED; fi
  # A run that lost its lease posts no write-back of its own. (bin/lane-run-
  # worker.sh still posts its final one; the hub applies it compare-and-set,
  # so a newer hub or machine copy of a file wins.)
  if [ "$st" != LEASE_LOST ] && [ -n "${LANE_RUN_ID:-}" ] && command -v lri_checkpoint >/dev/null 2>&1; then
    if ! out=$(lri_checkpoint "$LANE" "$P" 2>&1); then
      mlog "write-back failed ($(printf '%s' "$out" | tail -n 1))"
      [ "$rc" = 0 ] && rc=75
    fi
  fi
  pjl_release "$LANE" "$P" "$HOLDER" "$FENCE" >/dev/null 2>&1 || mlog "lease release not answered — it expires at its TTL"
  prof "$st" "${n_m:-0}" "${n_q:-0}" "${defw:--}" "$FENCE"
  case "$TMP" in "$H/state/merge-conductor-project/run."?*) rm -rf "$TMP" ;; esac
  exit "$rc"
}

on_term() {
  local i=0
  trap '' TERM INT
  TERMED=1
  : > "$STOP"
  mlog "TERM — stop at the next PR boundary (wait ${WAIT_S}s)"
  if [ -n "$CPID" ]; then
    while kill -0 "$CPID" 2>/dev/null && [ "$i" -lt "$WAIT_S" ]; do sleep 1; i=$((i + 1)); done
    reap
  fi
  finish 0
}
trap on_term TERM INT
[ "$TERMED" = 1 ] && on_term

renew_loop & RPID=$!

CENV=(MC_ONLY_PROJECT="$P" MC_ON_MACHINE=1 MC_LEASED_RUN=1
  MC_LEASE_FENCE="$FENCE" MC_LEASE_PROJECT="$P" MC_LEASE_HOLDER="$HOLDER"
  MC_STOP_FILE="$STOP" MC_PR_DEFERRED_FILE="$DEF" MC_LANDED_FILE="$LANDED")
# The TERM-before-CPID window: a TERM between the fork and `CPID=$!` is held
# (ignored), then replayed once CPID is known.
trap 'TERMED=1' TERM INT
if command -v setsid >/dev/null 2>&1; then
  setsid env "${CENV[@]}" "$H/bin/merge-conductor.sh" </dev/null &
else
  env "${CENV[@]}" "$H/bin/merge-conductor.sh" </dev/null &
fi
CPID=$!
trap on_term TERM INT
[ "$TERMED" = 1 ] && on_term
wait "$CPID"; crc=$?
# A TERM during the wait runs on_term, which never returns here.
finish "$crc"

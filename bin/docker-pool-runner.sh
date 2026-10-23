#!/bin/bash
# bin/docker-pool-runner.sh — the docker-pool host runner (BH-7347, slice C1
# of #7300). It runs ON a Docker host (a Mac with Docker Desktop), never on the
# hub, and builds ONE queued pool ticket in local Docker with the Fly builder
# image. Contract, knobs and go-live steps:
# docs/notes/2026-10-18-BH-7347-docker-pool-runner.md.
#
#   bin/docker-pool-runner.sh run <project> <key>
#       Builds the key the caller names (it never picks a row). Preflight
#       (docker, image, key, a queued target=fly row), the docker-pool claim
#       (docker_pool.max_concurrent and docker_pool.kill decide there), the
#       file set, the HOLD gate, docker run, a heartbeat per
#       DOCKER_POOL_BEAT_S, then stop, reap and release.
#       Exit: 0 finished (RESULT reaped, released done); 2 nothing queued for
#       the key; 9 refused (off, full, killed, lost, held, fenced); 1 a setup
#       failure or no RESULT (a claimed row is released queued); 143 / 130
#       TERM / INT hand-off.
#   bin/docker-pool-runner.sh smoke <project>
#       A SMOKE job in local Docker: no claim, no lease, no hold gate. Prints
#       RESULT line 1. Exit 0 on SMOKE_OK, else 1.
#   bin/docker-pool-runner.sh reap-orphans
#       Stops labeled docker-pool containers whose lease file is past due.
#       Prints `<stopped> <kept>`.
#
# JOBS_BOX must name this host's box: the claim lease is held per box.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
export HARNESS
DPH_CHECKOUT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DPH_CHECKOUT_DEFAULT

usage() {
  cat <<'EOF'
usage: bin/docker-pool-runner.sh run <project> <key>
       bin/docker-pool-runner.sh smoke <project>
       bin/docker-pool-runner.sh reap-orphans
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  run|smoke|reap-orphans) ;;
  *) usage >&2; exit 1 ;;
esac

mkdir -p "$HARNESS/logs" 2>/dev/null
# shellcheck source=bin/jobs-client.sh
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || { echo "docker-pool-runner: no jobs client under $HARNESS" >&2; exit 1; }
# shellcheck source=bin/lib/docker-pool.sh
. "$HARNESS/bin/lib/docker-pool.sh" || exit 1
# shellcheck source=bin/lib/docker-pool-host.sh
. "$HARNESS/bin/lib/docker-pool-host.sh" || exit 1

# _tag — dk-<UTC stamp>-<4 hex>. Never a Fly machine id ([0-9a-f]{14}).
_tag() { printf 'dk-%s-%s' "$(date -u +%Y%m%d%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }

cmd_reap_orphans() { dph_reap_orphans; }

cmd_smoke() {
  local p="${1:-}" img tag base work cid waited=0 cap line rc=1
  case "$p" in ''|*[!A-Za-z0-9._-]*) usage >&2; return 1 ;; esac
  docker info >/dev/null 2>&1 || { echo "docker-pool-runner: docker info does not answer" >&2; return 1; }
  img=$(dph_image "$p") || { echo "docker-pool-runner: no builder image for $p" >&2; return 1; }
  base=$(dph_knob DOCKER_POOL_ROOT); [ -n "$base" ] || return 1
  tag=$(_tag); work="$base/$p/SMOKE-$tag"
  mkdir -p "$work/run" || return 1
  DPH_P="$p"; DPH_KEY=SMOKE; DPH_WORK="$work"; DPH_TAG="$tag"; DPH_CID=""; DPH_CLAIMED=""
  trap 'dph_handoff 143' TERM; trap 'dph_handoff 130' INT
  printf '{"key":"SMOKE","ticket_id":"0","attempt":0}\n' > "$work/run/job.json"
  cap=$(dph_knob DOCKER_POOL_SMOKE_S)
  _dph_lease_write "$work" $(( $(date +%s) + cap + $(dph_knob DOCKER_POOL_STOP_S) ))
  dph_fileset "$p" SMOKE "$work" "$tag" || { _dph_cleanup "" "$work" "$tag"; return 1; }
  DPH_CID=$(dph_container_start "$p" SMOKE "$work" "$tag" "$img") \
    || { _dph_log "$p SMOKE: docker run gave no container"; _dph_cleanup "" "$work" "$tag"; return 1; }
  while [ ! -s "$work/run/RESULT" ] && [ "$waited" -lt "$cap" ]; do
    [ "$(dph_state "$DPH_CID" "$work")" = exited ] && break
    sleep 1 & DPH_SLEEP=$!; wait "$DPH_SLEEP"; DPH_SLEEP=""
    waited=$((waited + 1))
  done
  line=$(head -n 1 "$work/run/RESULT" 2>/dev/null)
  _dph_stop "$DPH_CID"
  _dph_cleanup "$DPH_CID" "$work" "$tag"
  trap - TERM INT
  case "$line" in SMOKE_OK*) rc=0 ;; esac
  _dph_log "$p SMOKE: ${line:-no RESULT after ${waited}s}"
  printf '%s\n' "${line:-SMOKE_FAIL no RESULT after ${waited}s}"
  return "$rc"
}

cmd_run() {
  local p="${1:-}" key="${2:-}" row img claim rc ckey tid att lu meta base hv
  [ -n "${JOBS_BOX:-}" ] || { echo "docker-pool-runner: JOBS_BOX must name this host's box" >&2; return 1; }
  dph_key_ok "$key" || { _dph_log "refused: key '$key' is not a plain ticket key (RB-*, RR-*, CP-*, SMOKE and odd characters are refused)"; return 1; }
  dph_retention
  dph_reap_orphans >/dev/null
  row=$(dph_preflight "$p" "$key"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  meta=$(printf '%s' "$row" | cut -f10)
  img=$(dph_image "$p") || return 1
  claim=$(docker_pool_claim "$p" "$key"); rc=$?
  case "$rc" in
    0) ;;
    9) _dph_log "$p $key: claim refused on $JOBS_BOX"; return 9 ;;
    2) _dph_log "$p $key: nothing queued at the claim"; return 2 ;;
    *) _dph_log "$p $key: claim failed (rc $rc)"; return 1 ;;
  esac
  IFS=$'\t' read -r ckey tid att lu <<<"$claim"
  base=$(dph_knob DOCKER_POOL_ROOT)
  DPH_P="$p"; DPH_KEY="$key"; DPH_TAG=$(_tag); DPH_CID=""; DPH_CLAIMED=1; DPH_ACCT=default; DPH_SLUG=""
  DPH_WORK="$base/$p/$key-$DPH_TAG"
  trap 'dph_handoff 143' TERM; trap 'dph_handoff 130' INT
  _dph_log "$p $ckey claimed on $JOBS_BOX as $DPH_TAG ticket=$tid attempt=$att lease_until=$lu"
  mkdir -p "$DPH_WORK/run" || { dph_finish "$p" "$key" "" "$DPH_WORK" setup-failed >/dev/null; return 1; }
  _dph_lease_write "$DPH_WORK" "$(_dph_epoch "$lu" || date +%s)"
  dph_job_file "$p" "$key" "$DPH_WORK/run/job.json" "$tid" "$att" "$meta" >/dev/null; rc=$?
  if [ "$rc" != 0 ]; then
    # rc 3: queue_row_job_file closed the row failed itself; release the lease.
    dph_finish "$p" "$key" "" "$DPH_WORK" "job-file-rc$rc"; return 1
  fi
  dph_fileset "$p" "$key" "$DPH_WORK" "$DPH_TAG" || { dph_finish "$p" "$key" "" "$DPH_WORK" setup-failed; return 1; }
  hv=$(dph_hold_gate "$DPH_SLUG" "$tid" "$DPH_WORK/env"); rc=$?
  _dph_log "$p $key: hold gate: $(printf '%s' "$hv" | tr '\t' ' ')"
  if [ "$rc" != 0 ]; then dph_finish "$p" "$key" "" "$DPH_WORK" held; return 9; fi
  _dph_c2
  DPH_COST_BOX=""
  declare -F docker_pool_cost_box >/dev/null && DPH_COST_BOX=$(docker_pool_cost_box "$p" "$DPH_TAG" 2>/dev/null)
  [ -n "$DPH_COST_BOX" ] || DPH_COST_BOX="pool-$p-$DPH_TAG"
  DPH_CID=$(dph_container_start "$p" "$key" "$DPH_WORK" "$DPH_TAG" "$img") \
    || { _dph_log "$p $key: docker run gave no container"; dph_finish "$p" "$key" "" "$DPH_WORK" no-container; return 1; }
  _dph_log "$p $key: container $DPH_CID started ($img)"
  dph_beat_loop "$p" "$key" "$DPH_CID" "$DPH_WORK" "$lu"
  case "$DPH_OUTCOME" in
    lost|killed|fenced) dph_drop "$p" "$key" "$DPH_CID" "$DPH_WORK" "$DPH_OUTCOME"; trap - TERM INT; return 9 ;;
  esac
  dph_finish "$p" "$key" "$DPH_CID" "$DPH_WORK" "$DPH_OUTCOME"; rc=$?
  trap - TERM INT
  return "$rc"
}

verb="$1"; shift
case "$verb" in
  run) cmd_run "$@" ;;
  smoke) cmd_smoke "$@" ;;
  reap-orphans) cmd_reap_orphans ;;
esac

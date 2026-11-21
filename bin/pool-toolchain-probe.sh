#!/bin/bash
# bin/pool-toolchain-probe.sh --builder <project> | --check | --run <project>
# BH-9435 (T6): the daily pool toolchain probe.
#
# WHY. Two pool toolchain defects hid behind narrowed test scopes for weeks: the
# pool Postgres had no pgvector (`extension "vector" is not available`, TK-1378)
# and the rebase typecheck aborted at exit 134 on a 6144 MB heap (TK-3772). This
# lane checks both once a day per pool project, on the pool image itself, and a
# failure is one alert line.
#
# WHERE IT RUNS. Only a pool builder has the image under test (/opt/pgtest with
# pgvector) and the project's warm clone. A lane-run machine has neither, and
# the hub is not the pool image. So the checks run on the pool builder, and the
# alert is raised on the hub, where the alert state machine lives:
#
#   --builder <p>  fly/builder-runner.sh calls this before each pool job (SMOKE
#                  excepted). It takes the day's claim in the worker ledger
#                  (job_ledger_claim, kind pool-toolchain-probe, key <p>:<YYYY-MM-DD
#                  UTC>), so ONE job per project per UTC day runs the checks, on
#                  whatever pool machine runs it first. A claim already taken
#                  (rc 3) or a ledger that does not answer runs nothing: with no
#                  shared claim, every build would pay for a probe. After the
#                  checks it PUTs ok or fail onto the same key, with the verdict
#                  line as the detail. It never fails the job.
#   --check        (hub cron, hourly at :47, behind bin/hub-lease.sh) reads, per
#                  pool project (flags/fly-pool-<p>, app-name flags skipped), the
#                  ledger row of today, else of yesterday. fail = ONE
#                  `bin/lane-alert.sh --id pool-toolchain-<p> --severity warn` call
#                  with the verdict line (the state machine dedupes the repeats).
#                  ok = one --resolve of that id. running, or no row (no pool job
#                  ran), or a ledger that does not answer = one log line, no alert.
#   --run <p>      the two checks only, and one verdict line on stdout and in
#                  logs/pool-toolchain-probe.log (by hand on a pool builder):
#                    POOL_PROBE <p> pg=<ok|off|fail:why> tsc=<ok|off|off:low-disk|fail:rc|fail:why> heap=<MB src>
#                  pg   when POOL_TEST_POSTGRES resolves to 1 (pgt_enabled): pgt_start,
#                       then in single-user mode (no psql in the image) `CREATE
#                       EXTENSION IF NOT EXISTS vector` and `SELECT '[1,2]'::vector`,
#                       pgt_stop. Off otherwise.
#                  tsc  first a disk check: free MB under ${TMPDIR:-/tmp} below the
#                       disk-guard row DISK_HEADROOM_MIN_FREE_MB (fallback 8192) is
#                       tsc=off:low-disk, with no clone and no npm ci (the probe must
#                       not push a full disk into ENOSPC; df unreadable = go on).
#                       Then a fresh shallow fetch of the DEFAULT branch of
#                       ${REPOS_ROOT:-/root/repos}/<p> (the machine's warm clone;
#                       file://, no network): refs/remotes/origin/HEAD, else
#                       refs/remotes/origin/main, never the branch the warm clone
#                       has checked out (a red ticket branch is not a toolchain
#                       fault); neither ref = tsc=fail:no-default-branch. `npm ci
#                       --prefer-offline` from the warm npm cache, then `npx tsc
#                       --noEmit` (-p tsconfig.build.json when it exists) at
#                       NODE_OPTIONS --max-old-space-size=<rebase_tsc_heap <p>>
#                       (bin/lib/tsc-heap.sh). Off when the clone has no tsconfig.
#
# OFF: flags/lane-off-pool-toolchain-probe (bin/harness-ctl.sh off
# pool-toolchain-probe): every mode exits 0 and calls nothing. The row
# lane.pool-toolchain-probe.pool_probe_on_builder = 0 stops --builder alone.
# PTP_LIB_ONLY=1 is a test seam: source the file, define the functions, run nothing.
set -uo pipefail

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PTP_LANE=pool-toolchain-probe

# shellcheck source=bin/lib/pg-test.sh
. "$SELF/lib/pg-test.sh" 2>/dev/null || . "$H/bin/lib/pg-test.sh" 2>/dev/null || true
# shellcheck source=bin/lib/tsc-heap.sh
. "$SELF/lib/tsc-heap.sh" 2>/dev/null || . "$H/bin/lib/tsc-heap.sh" 2>/dev/null || true
# shellcheck source=bin/lib/disk-headroom.sh
. "$SELF/lib/disk-headroom.sh" 2>/dev/null || . "$H/bin/lib/disk-headroom.sh" 2>/dev/null || true

ptp_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
ptp_log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(ptp_stamp) [$PTP_LANE] $*" >> "$H/logs/$PTP_LANE.log"; }
# shellcheck source=bin/lib/lane-switch.sh
. "$SELF/lib/lane-switch.sh" 2>/dev/null || . "$H/bin/lib/lane-switch.sh" 2>/dev/null || true
# The switch is read with lane_switch (a settings row, else the flag file). With
# no lib, the flag file alone, as harness-ctl.sh writes it.
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }
ptp_off() { lane_switch "lane-off-$PTP_LANE"; }

# ptp_knob <ENV> <fallback> [project] — a whole-number knob of this lane.
ptp_knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob "$PTP_LANE" "$1" "${3:-}" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$v" -gt 0 ] || v="$2"
  printf '%s' "$v"
}

# ptp_alert <args...> — never fails the probe.
ptp_alert() { "$H/bin/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# ptp_pg <project> <outfile> — prints ok | off | fail:<why>.
# The image bakes postgres, initdb and pg_ctl into /opt/pgtest and no psql, so the
# SQL runs in single-user mode: pgt_start proves the server starts on a fresh
# cluster, pg_ctl stops the postmaster (the data dir stays), and `postgres
# --single` runs CREATE EXTENSION vector and SELECT '[1,2]'::vector on that
# cluster. Single-user mode exits 0 after an ERROR, so the verdict reads the
# output: ok only with no ERROR/FATAL line and the vector value printed.
ptp_pg() {
  local p="$1" out="$2" rc d log tstop
  ( PROJECT="$p"; pgt_enabled ) 2>/dev/null || { echo off; return 0; }
  command -v pgt_start >/dev/null 2>&1 || { echo fail:no-pg-lib; return 0; }
  PROJECT="$p" pgt_start "$out"; rc=$?
  [ "$rc" = 0 ] || { pgt_stop "$out" >/dev/null 2>&1; echo "fail:start-rc$rc"; return 0; }
  d="$PGT_DIR/data"; log="$PGT_DIR/single.log"
  # The row lane.pool-toolchain-probe.<project>.pool_probe_pg_stop_timeout_s; 30 is
  # its fallback (seconds pg_ctl waits for the postmaster to stop).
  tstop=$(ptp_knob POOL_PROBE_PG_STOP_TIMEOUT_S 30 "$p")
  if ! _pgt_as pg_ctl -D "$d" -m fast -w -t "$tstop" stop >> "$out" 2>&1; then
    echo fail:stop-for-single
  else
    printf '%s\n' 'CREATE EXTENSION IF NOT EXISTS vector;' "SELECT '[1,2]'::vector AS v;" \
      | _pgt_as postgres --single -D "$d" -c fsync=off postgres > "$log" 2>&1
    cat "$log" >> "$out" 2>/dev/null
    if grep -qE '(^|[[:space:]])(ERROR|FATAL|PANIC):' "$log" 2>/dev/null; then
      echo fail:create-extension
    elif grep -qF '[1,2]' "$log" 2>/dev/null; then
      echo ok
    else
      echo fail:no-answer
    fi
  fi
  pgt_stop "$out" >/dev/null 2>&1
  return 0
}

# ptp_tsc <project> <workdir> <outfile> — sets PTP_TSC (ok | off | off:low-disk |
# fail:<rc|why>) and PTP_HEAP ("<MB> <src>").
ptp_tsc() {
  local p="$1" w="$2" out="$3" src flags="" rc tnpm ttsc free min ref
  PTP_TSC=""; PTP_HEAP="- -"
  src="${REPOS_ROOT:-/root/repos}/$p"
  [ -d "$src/.git" ] || { PTP_TSC=fail:no-repo; return 0; }
  # Disk first: the disk-guard row lane.disk-guard.<project>.disk_headroom_min_free_mb
  # (no row of its own; 8192 is its fallback). df unreadable: the check runs.
  if command -v dh_free_mb >/dev/null 2>&1 && free=$(dh_free_mb "${TMPDIR:-/tmp}"); then
    min=$(PROJECT="$p" dh_knob DISK_HEADROOM_MIN_FREE_MB 8192)
    if [ "$free" -lt "$min" ]; then
      PTP_TSC=off:low-disk
      ptp_log "$p: tsc off: ${free} MB free under ${TMPDIR:-/tmp}, below DISK_HEADROOM_MIN_FREE_MB ${min} — no clone, no npm ci"
      return 0
    fi
  fi
  # The default branch of the warm clone, never its checked-out branch.
  ref=$(git -C "$src" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)
  if [ -z "$ref" ] || ! git -C "$src" show-ref -q --verify "$ref" 2>/dev/null; then
    ref=""
    git -C "$src" show-ref -q --verify refs/remotes/origin/main 2>/dev/null && ref=refs/remotes/origin/main
  fi
  [ -n "$ref" ] || { PTP_TSC=fail:no-default-branch; return 0; }
  { git init -q "$w/clone" \
      && git -C "$w/clone" fetch -q --depth 1 "file://$src" "$ref" \
      && git -C "$w/clone" -c advice.detachedHead=false checkout -q FETCH_HEAD; } >> "$out" 2>&1 \
    || { PTP_TSC=fail:clone; return 0; }
  ( cd "$w/clone" && { [ -f tsconfig.build.json ] || [ -f tsconfig.json ]; } ) || { PTP_TSC=off; return 0; }
  # The rows lane.pool-toolchain-probe.<project>.pool_probe_npm_timeout_s and
  # .pool_probe_tsc_timeout_s; 900 is the fallback of each (the rebase verify's tsc timeout).
  tnpm=$(ptp_knob POOL_PROBE_NPM_TIMEOUT_S 900 "$p")
  ttsc=$(ptp_knob POOL_PROBE_TSC_TIMEOUT_S 900 "$p")
  PTP_HEAP=$(cd "$w/clone" && rebase_tsc_heap "$p" 2>/dev/null)
  [ -n "$PTP_HEAP" ] || PTP_HEAP="- -"
  ( cd "$w/clone" && timeout "$tnpm" npm ci --prefer-offline --no-audit --no-fund ) >> "$out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { PTP_TSC="fail:npm-ci-$rc"; return 0; }
  [ -f "$w/clone/tsconfig.build.json" ] && flags="-p tsconfig.build.json"
  # shellcheck disable=SC2086 # flags is empty or two words on purpose
  ( cd "$w/clone" && NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=${PTP_HEAP%% *}" \
      timeout "$ttsc" npx tsc $flags --noEmit ) >> "$out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then PTP_TSC=ok; else PTP_TSC="fail:$rc"; fi
  return 0
}

# ptp_run <project> — both checks and one verdict line (stdout and the lane log).
# Sets PTP_LINE. rc 0 = no check failed (ok or off), 1 = a check failed, 2 = a bad
# project name. It raises no alert: --check does that on the hub.
ptp_run() {
  local p="$1" w pg
  PTP_LINE=""
  [[ "$p" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "pool-toolchain-probe: bad project '$p'" >&2; return 2; }
  w=$(mktemp -d "${TMPDIR:-/tmp}/ptp-$p.XXXXXX") || { ptp_log "$p: no temp dir"; PTP_LINE="POOL_PROBE $p pg=fail:no-tmp tsc=fail:no-tmp heap=- -"; return 1; }
  pg=$(ptp_pg "$p" "$w/pg.txt")
  ptp_tsc "$p" "$w" "$w/tsc.txt"
  PTP_LINE="POOL_PROBE $p pg=$pg tsc=$PTP_TSC heap=$PTP_HEAP"
  echo "$PTP_LINE"
  ptp_log "$PTP_LINE"
  case "$pg $PTP_TSC" in
    *fail:*)
      ptp_log "$p: pg: $(grep -m1 -E "ERROR|FATAL|could-not-start" "$w/pg.txt" 2>/dev/null | tr -s "[:space:]" " " | cut -c1-200); tsc tail: $(tail -1 "$w/tsc.txt" 2>/dev/null | cut -c1-200)"
      rm -rf -- "$w"; return 1 ;;
  esac
  rm -rf -- "$w"
  return 0
}

# ptp_ledger <job_ledger_* function> <args...> — one jobs-client ledger call in a
# SUBSHELL, so the client's `set -uo pipefail` and module loader never touch this
# shell (the bin/lib/cred-probe.sh _cp_ledger shape). rc 9 = no client.
ptp_ledger() {
  local client="$H/bin/jobs-client.sh"
  [ -r "$client" ] || client="$SELF/jobs-client.sh"
  [ -r "$client" ] || return 9
  ( . "$client" >/dev/null 2>&1 || exit 9; "$@" )
}

# ptp_builder <project> — on a pool builder: today's claim, the checks, the
# verdict onto the claim's ledger row. Always rc 0: a probe never fails a job.
ptp_builder() {
  local p="$1" on key stale st rc
  ptp_off && return 0
  [[ "$p" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { ptp_log "builder: bad project '$p'"; return 0; }
  # The row lane.pool-toolchain-probe.<project>.pool_probe_on_builder; 1 is its
  # fallback, 0 stops the builder half (--check still reads the ledger).
  on=""; command -v lane_knob >/dev/null 2>&1 && on=$(lane_knob "$PTP_LANE" POOL_PROBE_ON_BUILDER "$p" 2>/dev/null)
  [ -n "$on" ] || on="${POOL_PROBE_ON_BUILDER:-1}"
  [ "$on" = 0 ] && { ptp_log "builder: $p off (row lane.pool-toolchain-probe.$p.pool_probe_on_builder = 0)"; return 0; }
  key="$p:$(date -u +%F)"
  # The row lane.pool-toolchain-probe.<project>.pool_probe_claim_stale_s; 7200 is
  # its fallback: a claim whose machine died mid-probe is taken again after it.
  stale=$(ptp_knob POOL_PROBE_CLAIM_STALE_S 7200 "$p")
  st=$(ptp_ledger job_ledger_claim "$PTP_LANE" "$key" running "$stale" ok,fail "box=$(hostname 2>/dev/null)"); rc=$?
  case "$rc" in
    0) ;;
    3) ptp_log "builder: $key already claimed (${st:-?}) — not probed again"; return 0 ;;
    *) ptp_log "builder: $key ledger claim rc=$rc — not probed (with no shared claim every job would probe)"; return 0 ;;
  esac
  if ptp_run "$p"; then st=ok; else st=fail; fi
  [ -n "$PTP_LINE" ] || PTP_LINE="POOL_PROBE $p pg=fail:no-verdict tsc=fail:no-verdict heap=- -"
  ptp_ledger job_ledger_put "$PTP_LANE" "$key" "$st" "$PTP_LINE" >/dev/null 2>&1 \
    || ptp_log "builder: $key verdict PUT failed — the claim goes stale after ${stale}s and the next job probes again"
  return 0
}

# ptp_check — on the hub: one alert or one resolve per pool project, from the
# newest ledger row (today, else yesterday). Always rc 0.
ptp_check() {
  local f p d row rc st det key alerts=0 resolves=0 quiet=0 down=0
  ptp_off && return 0
  for f in "$H"/flags/fly-pool-*; do
    [ -f "$f" ] || continue
    case "$f" in *fly-pool-app-*) continue ;; esac   # app-name flag, not a project
    p="${f##*fly-pool-}"
    [[ "$p" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || continue
    row=""; rc=2
    for d in "$(date -u +%F)" "$(date -u -d yesterday +%F)"; do
      key="$p:$d"
      row=$(ptp_ledger job_ledger_row "$PTP_LANE" "$key"); rc=$?
      [ "$rc" = 2 ] || break
    done
    case "$rc" in
      0)
        st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
        det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
        [ -n "$det" ] || det="POOL_PROBE $p ($key: $st)"
        case "$st" in
          fail) ptp_alert --id "pool-toolchain-$p" --severity warn "$PTP_LANE" "$det"; alerts=$((alerts + 1)) ;;
          ok)   ptp_alert --resolve --id "pool-toolchain-$p" "$PTP_LANE" "$det"; resolves=$((resolves + 1)) ;;
          *)    ptp_log "check: $p $key is $st — no verdict yet"; quiet=$((quiet + 1)) ;;
        esac ;;
      2) ptp_log "check: $p no probe today or yesterday (no pool job ran)"; quiet=$((quiet + 1)) ;;
      *) ptp_log "check: $p ledger read rc=$rc — no verdict read"; down=$((down + 1)) ;;
    esac
  done
  ptp_log "check: alerts $alerts, resolves $resolves, no verdict $quiet, ledger down $down"
  return 0
}

[ "${PTP_LIB_ONLY-}" = 1 ] && return 0 2>/dev/null

case "${1:-}" in
  --run|--builder)
    ptp_off && exit 0
    # lane_knob for this lane's rows and pgt_enabled's POOL_TEST_POSTGRES row; no
    # lane_gate_or_exit here: fly/builder-runner.sh owns this run.
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
    # This lane's rows for the project into the env (ptp_knob reads lane_knob first anyway).
    command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply pool-toolchain-probe "${2:-}"
    if [ "$1" = --run ]; then ptp_run "${2:?project}"; exit 0; fi
    ptp_builder "${2:?project}"; exit 0 ;;
  --check)
    ptp_off && exit 0
    . "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
      || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
    HENV=$(harness_env_dir "$H")
    # shellcheck disable=SC1091
    [ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
    command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pool-toolchain-probe
    # After the env load, so global.env does not overwrite a row (tests/lanes-registry-test.sh 16).
    command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pool-toolchain-probe
    ptp_check; exit 0 ;;
  -h|--help) sed -n '2,57p' "$0"; exit 0 ;;
  *) echo "usage: pool-toolchain-probe.sh --builder <project> | --check | --run <project>" >&2; exit 2 ;;
esac

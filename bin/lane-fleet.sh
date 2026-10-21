#!/bin/bash
# bin/lane-fleet.sh tick — the lane-run Fly fleet autoscaler (BH-6126,
# BH-6047 part 3 of 5). Hub cron, every minute, behind the hub lease.
#
# Lanes placed `fly` queue as lane_runs rows (BH-6124). Machines in the Fly app
# `lane-run` run bin/lane-run-worker.sh and claim them. One tick:
#
#   1. gate      lane_gate_or_exit lane-fleet; flock -n locks/lane-fleet.lock
#                (held = exit 0, one log line). JOBS_URL empty = "not
#                configured", exit 0, no Fly call.
#   2. knobs     settings rows lane_fleet.* through setting_get; a missing or
#                out-of-range row uses the code default: warm_floor 1 (0..100),
#                scale_up_wait_s 60 (0..86400), idle_stop_s 600 (60..86400),
#                max_machines 0 (0..1000, 0 = no ceiling), vm_size
#                shared-cpu-2x, vm_memory_mb 2048 (256..65536), start_grace_s
#                180 (30..3600), failed_start_backoff_s 900 (60..86400),
#                image registry.fly.io/lane-run:latest, target_drain_s 60
#                (10..3600), max_starts_per_tick 5 (1..50). The image row must name
#                a tag or digest of registry.fly.io/lane-run: the machine gets
#                the lane-run Fly secrets, so any other image uses the default.
#   3. read      GET /api/lane-runs/stats?run_p50=1 (W = the largest
#                oldest_queued_wait_s, none when no lane is queued; WORK = the
#                sum over queued lanes of queued x run_p50_s, a lane with no
#                done sample adds 0), `flyctl machine list -a lane-run
#                --json`, GET /api/lane-fleet/machines. A failed read does
#                nothing else this tick (no start, no stop) and writes one
#                ALERTS line per read kind per UTC day. After the listing,
#                lfi_log_images (lib/lane-fleet-image.sh) logs one `image <id>
#                <ref> digest=<d> harness_commit=<c>` line per started machine
#                whose digest is new (state/lane-fleet/images.tsv).
#   4. adopt     a Fly `started` machine with no starting/started row is
#                recorded: `starting` when Fly's updated_at is younger than
#                start_grace_s (a lost record write), else `started`.
#      reconcile a `started` row whose machine Fly lists as stopped, or does
#                not list, is marked stopped (destroyed when Fly lists it
#                destroyed or not at all) at Fly's updated_at, then gets its
#                last cost rows up to that time. At most 20 per tick.
#      failed    a `starting` row (no claim since its started_at) that is past
#                start_grace_s, or whose machine Fly lists stopped/destroyed, is
#                a failed start, except a busy row (a live claim) and a row Fly
#                lists `started` while no queued run waited its whole life
#                (W none or W < its age): that one is promoted to `started`.
#                A failed start is: one ALERTS line per UTC day, `machine stop`
#                when Fly still runs it, the row marked stopped (destroyed when
#                Fly lists it destroyed or not at all) with failed:true and
#                Fly's stop time, then its last cost rows. A failed stop keeps
#                the row `starting`, so the next tick tries again. At most 20
#                per tick.
#   5. count     INFLIGHT = rows the worker answers in_flight, Fly machines in
#                created|starting, and the adopted lost-record machines. LIVE
#                = Fly `started` machines that are not in flight. A failed
#                start counts in neither.
#   6. decide    lf_decide: in flight -> none; a failed start this tick, or a
#                last_failed_at younger than failed_start_backoff_s -> none
#                (a start that never claims is not retried every minute); max
#                set and LIVE+INFLIGHT >= max -> none. Else n = the largest of
#                floor - LIVE, ceil(WORK / target_drain_s) - LIVE, and 1 when
#                W > scale_up_wait_s (equal is not over); n <= 0 -> none. n is
#                capped by max_starts_per_tick and by the room under max (BH-6885).
#                Only when no start is due and W is none (no queued run a stop
#                could kill): lf_pick_stop stops the not-busy, not-in-flight
#                machine with the largest idle_s > idle_stop_s, and only while
#                LIVE > floor. At most n starts or one stop per tick.
#   7. start     up to n machines: each Fly `stopped` machine in id order is
#                reused (`machine start`), then `machine run` with the size
#                rows; the id comes from the `Machine ID:` line only. Each id is
#                recorded as `starting`, with started_at = the tick's decision
#                time, before the tick exits. The first failure ends the batch
#                (one `start batch stopped after <k> of <n>` line when k > 0):
#                a failed reuse destroys the machine (not found = gone); a run
#                with no id records nothing and writes one ALERTS line per UTC
#                day. The next tick retries.
#   8. stop      last cost rows first, then `machine stop`, then the row is
#                marked stopped. A failed stop changes no row and writes one
#                ALERTS line per machine per UTC day.
#   9. cost      for each Fly `started` machine with a row: POST
#                /api/lane-fleet/cost through the current minute, priced by
#                fly_price_per_s on the listing's config.guest (unknown size =
#                usd_per_s null, an UNPRICED row, never $0).
#  10. log       one line in logs/lane-fleet.log:
#                tick wait=<W|none> live=<n> inflight=<n> floor=<n> max=<n|none>
#                action=<start <mid>[,<mid>...] <reason>|stop <mid> idle=<s>|none <reason>>
#                cost=<written>/<already> work=<s>s desired=<n>
#
# FLEET GROUPS (BH-7434). A settings row lane_fleet.group.<name> = JSON
# {app, vm_size, vm_memory, max_machines, warm_floor, projects:[...]} is one
# more fleet: its own Fly app (lane-run-<x>) and size, for its own projects.
# The jobs worker validates the rows (GET /api/lane-fleet/groups; a 404 from
# an older worker = no group). No valid row = ONE pass exactly as above. With
# groups, the tick runs one pass for the default fleet (app lane-run, the
# projects of no group) and one per group, each in its own subshell, so a
# failed read or an exit in one pass never touches another:
#   - stats read GET /api/lane-runs/stats?run_p50=1&fleet=<default|name> (that
#     fleet's queued rows only; the default fleet also counts a grouped row
#     that waited past lane_run.group_fallback_s), machine rows GET
#     /api/lane-fleet/machines?app=<app>, and every row it writes says its app;
#   - a group's vm_size, vm_memory, max_machines and warm_floor replace the
#     lane_fleet.* rows (absent = the row), its machines get
#     -e LANE_RUN_GROUP=<name> (bin/lane-run-worker.sh claims with
#     only_prefixes), its log lines say [lane-fleet:<name>], its alert flags
#     are its own, its token is FLY_API_TOKEN_<APP> else FLY_API_TOKEN;
#   - before its Fly reads, a group pass checks its app once: an app Fly does
#     not know is created (`apps create <app> --org $FLY_ORG`, from
#     env/fly.env; no FLY_ORG = no create, one ALERTS line per UTC day), and an
#     app without the HARNESS_SECRET and JOBS_URL secrets starts nothing, with
#     one ALERTS line per UTC day naming the operator command. A ready app is
#     remembered in state/lane-fleet/group-<name>/app-ready;
#   - fallback: a group whose oldest queued run waited longer than
#     lane_run.group_fallback_s (the worker's answer, 0 = never) writes one
#     ALERTS line per UTC day; the worker then lets the default fleet claim
#     those rows, so a project never stalls because its fleet is gone.
# BOX GROUPS (BH-7716). A group object with `box` set (`projects: []`; the
# worker validates box, volume [a-z0-9_]{1,30}, volume_gb 1..500, workers
# 1..16) is a dedicated host for the lanes a lane_placement row puts on that
# box (lane_fleet.group.dedicated, box fly-dedicated). Its stats read answers
# the rows routed to the box plus `placed` (a placement row resolves to the box
# now). Every rule above holds, with four changes; a group without `box` keeps
# every rule above unchanged:
#   - its machines get -e LANE_RUN_BOX=<box> -e LANE_RUN_WORKERS=<workers,
#     default 1> -e LANE_RUN_WARM_CLONES=1 and NO LANE_RUN_GROUP (a box group
#     has no projects, so a group claim would refuse it); with `volume` set,
#     also -v <volume>:/root/repos --region ${FLY_REGION:-iad};
#   - before its first `machine run` of a tick: `volumes list --app <app>
#     --json`; no volume of that name (not destroyed) = ONE `volumes create
#     <volume> --app <app> --size <volume_gb, default 20> --region
#     ${FLY_REGION:-iad} --yes`. A failed list or create runs no machine this
#     tick (action=none volume-failed), one log line, one ALERTS line per UTC
#     day (kind volume). A reused stopped machine keeps its volume, no check;
#   - floor: the group's warm_floor only while the stats answer says
#     `placed: true`; else 0 (log `box <box>: no placement row; floor 0`), so
#     idle_stop_s stops the machine after a rollback to `hub`;
#   - not placed, no queued run (W none) and no starting/started machine row:
#     one log line `box <box>: no placement row and no machine; nothing to
#     do` and the pass ends BEFORE the app check and any Fly call (no apps
#     create, no secrets alert): the row exists before the app does.
# The idle reaper covers the group apps through the `lane-run-` prefix in
# catalog/fly-idle-signals.json; the exact entry lane-run-dedicated is exempt
# (this pass stops it).
#
# Exit 0 on every path but a usage error (2). Seams for tests: LANE_FLEET_NOW
# (epoch), LANE_FLEET_FLY (the flyctl binary; empty uses fly_bin from
# bin/lib/fly-bin.sh: PATH, then $FLYCTL_INSTALL/bin, $HOME/.fly/bin,
# ${FLY_BIN_DIR:-/root/.fly/bin}, so cron's bare PATH still finds it). No flyctl
# = one log line and one fly-missing ALERTS line per UTC hour. Sourcing this
# file defines the pure lf_decide / lf_pick_stop and runs nothing.
set -uo pipefail

LF_APP=lane-run

# lf_decide <W|none> <LIVE> <INFLIGHT> <FLOOR> <UPWAIT> <MAX> [HOLD] [WORK_S]
#           [TARGET_S] [MAXSTARTS]
#   prints `start <n> <reason>` or `none <reason>`. W none (or empty) = no
#   queue. HOLD > 0 = a failed start this tick or inside the backoff: no start.
#   WORK_S = queued run seconds (default 0); desired machines =
#   ceil(WORK_S / TARGET_S) (default 60). n = the largest of floor - LIVE,
#   desired - LIVE and 1 when W > UPWAIT, capped by MAXSTARTS (default 1) and
#   by MAX - LIVE - INFLIGHT when MAX > 0. Reasons: below-floor, queue-depth,
#   queue-wait.
lf_decide() {
  local w="${1:-none}" live="$2" inflight="$3" floor="$4" up="$5" max="$6" hold="${7:-0}"
  local work="${8:-0}" target="${9:-60}" maxs="${10:-1}" nf nw nq n why
  [ -n "$w" ] || w=none
  [ "$target" -gt 0 ] 2>/dev/null || target=60
  [ "$maxs" -gt 0 ] 2>/dev/null || maxs=1
  if [ "$inflight" -gt 0 ]; then echo "none start-in-flight"; return 0; fi
  if [ "$hold" -gt 0 ]; then echo "none failed-start-hold"; return 0; fi
  if [ "$max" -gt 0 ] && [ $((live + inflight)) -ge "$max" ]; then echo "none at-max"; return 0; fi
  nf=$((floor - live))
  nw=$(( (work + target - 1) / target - live ))
  nq=0; [ "$w" != none ] && [ "$w" -gt "$up" ] && nq=1
  n=$nf; [ "$nw" -gt "$n" ] && n=$nw; [ "$nq" -gt "$n" ] && n=$nq
  if [ "$n" -le 0 ]; then echo "none wait-under-threshold"; return 0; fi
  if [ "$nf" -gt 0 ]; then why=below-floor; elif [ "$nw" -ge "$nq" ]; then why=queue-depth; else why=queue-wait; fi
  [ "$n" -gt "$maxs" ] && n=$maxs
  [ "$max" -gt 0 ] && [ "$n" -gt $((max - live - inflight)) ] && n=$((max - live - inflight))
  echo "start $n $why"
}

# lf_pick_stop <LIVE> <FLOOR> <IDLE_S> <machines json array>
#   prints the machine_id of the not-busy, not-in-flight machine with the
#   largest idle_s > IDLE_S, or nothing when LIVE <= FLOOR or none qualifies.
lf_pick_stop() {
  local live="$1" floor="$2" idle="$3" ms="${4:-[]}"
  [ "$live" -gt "$floor" ] || return 0
  printf '%s' "$ms" | jq -r --argjson t "$idle" '
    [ .[] | select((.busy != true) and (.in_flight != true) and ((.idle_s // 0) > $t)) ]
    | sort_by(-(.idle_s), .machine_id) | .[0].machine_id // empty' 2>/dev/null
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  tick) ;;
  *) echo "usage: lane-fleet.sh tick" >&2; exit 2 ;;
esac

H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
mkdir -p "$H/logs" "$H/locks" "$H/flags" "$H/state/lane-fleet" 2>/dev/null
LOG="$H/logs/lane-fleet.log"
NOW="${LANE_FLEET_NOW:-$(date -u +%s)}"
DAY=$(date -u -d "@$NOW" +%Y%m%d)
# LF_TAG is `:<group>` inside a group pass, empty otherwise (BH-7434).
LF_TAG=""; LF_KPFX=""
lf_log() { echo "$(date -u -d "@$NOW" '+%F %TZ') [lane-fleet$LF_TAG] $*" >> "$LOG"; }
# lf_epoch <iso> — epoch seconds; rc 1 and nothing printed on an empty or bad stamp.
lf_epoch() { [ -n "${1:-}" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-fleet
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lane-fleet

exec 9>"$H/locks/lane-fleet.lock"
flock -n 9 || { lf_log "lock held; another tick is running"; exit 0; }

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 0
# shellcheck source=bin/lib/fly-cost-row.sh
. "$H/bin/lib/fly-cost-row.sh" || exit 0
# shellcheck source=bin/lib/fly-bin.sh
. "$H/bin/lib/fly-bin.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lane-fleet-image.sh
. "$H/bin/lib/lane-fleet-image.sh" 2>/dev/null || true
[ -n "${JOBS_URL:-}" ] || { lf_log "not configured (JOBS_URL empty); no Fly call"; exit 0; }

# lf_alert <kind> <text> [hour] — one ALERTS line per kind per UTC day; with
# `hour`, one per UTC hour, and the kind's flags of earlier hours are removed.
lf_alert() {
  local b="$DAY"
  [ "${3:-}" = hour ] && b=$(date -u -d "@$NOW" +%Y%m%d%H)
  local k="$LF_KPFX$1"
  local f="$H/flags/alerted-lane-fleet-$k-$b"
  [ -f "$f" ] && return 0
  [ "${3:-}" = hour ] && find "$H/flags" -maxdepth 1 -type f -name "alerted-lane-fleet-$k-*" ! -name "*-$b" -delete 2>/dev/null
  touch "$f" 2>/dev/null
  HARNESS="$H" "$H/bin/alert-line.sh" "[lane-fleet$LF_TAG] $2"
}

# lf_int <key> <fallback> <min> <max> — the lw_poll_s shape.
lf_int() {
  local v
  v=$(setting_get "lane_fleet.$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "${#v}" -le 6 ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] || v=$2
  printf '%s' "$((10#$v))"
}
lf_str() {
  local v
  v=$(setting_get "lane_fleet.$1" 2>/dev/null) || v=""
  [[ "$v" =~ $3 ]] || v=$2
  printf '%s' "$v"
}

FLY="${LANE_FLEET_FLY:-$(fly_bin 2>/dev/null || true)}"
[ -n "$FLY" ] || { lf_log "flyctl not found (PATH, \$HOME/.fly/bin, \${FLY_BIN_DIR:-/root/.fly/bin}); nothing done"; lf_alert fly-missing "flyctl not found on $(hostname 2>/dev/null) (PATH, \$HOME/.fly/bin, \${FLY_BIN_DIR:-/root/.fly/bin}); the lane-run fleet starts and stops no machine" hour; exit 0; }

# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
set -a; . "$HENV/fly.env" 2>/dev/null; set +a

# lf_group_json <name> — the group's object from the groups answer.
lf_group_json() { jq -c --arg n "$1" '.groups[] | select(.name == $n)' "$GROUPS_F" 2>/dev/null | head -1; }
# lf_gint <field> <current> <min> <max> — a group field in range, else current.
lf_gint() {
  local v
  v=$(jq -r --arg k "$1" '.[$k] // empty' <<<"$GJ" 2>/dev/null)
  [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] && { printf '%s' "$((10#$v))"; return; }
  printf '%s' "$2"
}

# lf_app_ready — a group app exists and has its secrets (BH-7434). Creates an
# app Fly does not know, in $FLY_ORG. rc 1 = start nothing this pass.
lf_app_ready() {
  local out names
  [ -f "$W_DIR/app-ready" ] && return 0
  if ! out=$(timeout 60 "$FLY" secrets list -a "$LF_APP" --json 2>&1); then
    if ! grep -qiE 'could not find app|app not found' <<<"$out"; then
      lf_log "secrets list $LF_APP failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200); no start, no stop"
      lf_alert app-read "flyctl secrets list -a $LF_APP failed ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); group $LF_GROUP starts and stops no machine until it answers"
      return 1
    fi
    if [ -z "${FLY_ORG:-}" ]; then
      lf_log "app $LF_APP does not exist and FLY_ORG is not set in $HENV/fly.env; not created"
      lf_alert app-org "Fly app $LF_APP of group $LF_GROUP does not exist, and FLY_ORG is not set in $HENV/fly.env, so it is not created; the group's projects wait, then fall back to lane-run"
      return 1
    fi
    if ! out=$(timeout 120 "$FLY" apps create "$LF_APP" --org "$FLY_ORG" 2>&1); then
      lf_log "apps create $LF_APP failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      lf_alert app-create "flyctl apps create $LF_APP --org $FLY_ORG failed ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); the next tick retries"
      return 1
    fi
    lf_log "created Fly app $LF_APP in $FLY_ORG for group $LF_GROUP"
    out='[]'
  fi
  names=$(jq -r '[.[]? | (.Name // .name // empty)] | join(" ")' <<<"$out" 2>/dev/null)
  if [[ " $names " == *" HARNESS_SECRET "* ]] && [[ " $names " == *" JOBS_URL "* ]]; then
    touch "$W_DIR/app-ready"; return 0
  fi
  lf_log "app $LF_APP has no HARNESS_SECRET or JOBS_URL secret; no start"
  lf_alert app-secrets "Fly app $LF_APP has no HARNESS_SECRET or JOBS_URL secret, so group $LF_GROUP starts no machine. Set the lane-run secrets (fly/lane-run.toml): flyctl secrets set HARNESS_SECRET=... JOBS_URL=... GH_APP_ID=... GH_APP_PRIVATE_KEY=... GH_APP_INSTALLATION_<OWNER>=... CLAUDE_CODE_OAUTH_TOKEN=... CODEX_AUTH_JSON=... CODEX_CONFIG_TOML=... -a $LF_APP --stage, and FLY_API_TOKEN_<PROJECT> (only for a group whose projects run the pool tick on Fly) through stdin: ( set -a; . $HENV/fly.env; printf 'FLY_API_TOKEN_<PROJECT>=%s\\n' \"\$FLY_API_TOKEN_<PROJECT>\" ) | flyctl secrets import -a $LF_APP --stage. The full list per project: bin/lane-run-secrets.sh fly-pool <project>."
  return 1
}

# lf_pass [default|<group>] — one fleet's tick, steps 2-10. Empty = the only
# fleet (no group row): every read, write and log line exactly as before
# BH-7434. Always run in a subshell: its `exit 0` ends only this pass.
lf_pass() {
# Every pass reads and writes only its own app's rows (review F1 of #7447): a
# single pass that read every row would mark a running group machine destroyed
# once its group row is gone. Rows from before BH-7434 carry app lane-run.
LF_GROUP="${1:-}"; GJ=""; LF_APP=lane-run; LF_SQ=""; LF_MQ="?app=lane-run"; LF_RAPP=lane-run; LF_GENV=()
LF_BOX=""; LF_VOL=""; LF_VOL_OK=""
W_DIR="$H/state/lane-fleet"
if [ -n "$LF_GROUP" ]; then
  LF_SQ="&fleet=$LF_GROUP"
fi
if [ -n "$LF_GROUP" ] && [ "$LF_GROUP" != default ]; then
  GJ=$(lf_group_json "$LF_GROUP")
  LF_APP=$(jq -r '.app // empty' <<<"$GJ")
  [[ "$LF_APP" =~ ^lane-run-[a-z0-9][a-z0-9-]{0,39}$ ]] || { lf_log "group $LF_GROUP has no valid app; skipped"; exit 0; }
  LF_MQ="?app=$LF_APP"; LF_RAPP="$LF_APP"; LF_TAG=":$LF_GROUP"; LF_KPFX="group-$LF_GROUP-"
  LF_GENV=(-e "LANE_RUN_GROUP=$LF_GROUP")
  W_DIR="$H/state/lane-fleet/group-$LF_GROUP"
  # A box group (BH-7716): the machine claims by box, not by group.
  LF_BOX=$(jq -r '.box // empty' <<<"$GJ")
  if [ -n "$LF_BOX" ]; then
    [[ "$LF_BOX" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || { lf_log "group $LF_GROUP has an invalid box; skipped"; exit 0; }
    LF_VOL=$(jq -r '.volume // empty' <<<"$GJ")
    [ -z "$LF_VOL" ] || [[ "$LF_VOL" =~ ^[a-z0-9_]{1,30}$ ]] || { lf_log "group $LF_GROUP has an invalid volume; skipped"; exit 0; }
    LF_GENV=(-e "LANE_RUN_BOX=$LF_BOX" -e "LANE_RUN_WORKERS=$(lf_gint workers 1 1 16)" -e LANE_RUN_WARM_CLONES=1)
    [ -z "$LF_VOL" ] || LF_GENV+=(-v "$LF_VOL:/root/repos" --region "${FLY_REGION:-iad}")
  fi
fi
mkdir -p "$W_DIR" 2>/dev/null
FLOOR=$(lf_int warm_floor 1 0 100)
UPWAIT=$(lf_int scale_up_wait_s 60 0 86400)
IDLE=$(lf_int idle_stop_s 600 60 86400)
MAX=$(lf_int max_machines 0 0 1000)
GRACE=$(lf_int start_grace_s 180 30 3600)
BACKOFF=$(lf_int failed_start_backoff_s 900 60 86400)
TARGET=$(lf_int target_drain_s 60 10 3600)
MAXSTARTS=$(lf_int max_starts_per_tick 5 1 50)
MEM=$(lf_int vm_memory_mb 2048 256 65536)
SIZE=$(lf_str vm_size shared-cpu-2x '^[a-z0-9-]{1,40}$')
if [ -n "$GJ" ]; then
  FLOOR=$(lf_gint warm_floor "$FLOOR" 0 100); MAX=$(lf_gint max_machines "$MAX" 0 1000)
  MEM=$(lf_gint vm_memory "$MEM" 256 65536)
  v=$(jq -r '.vm_size // empty' <<<"$GJ"); [[ "$v" =~ ^[a-z0-9-]{1,40}$ ]] && SIZE="$v"
fi
# Pinned to the app's own repository: Fly gives every machine in lane-run the
# app secrets (the GitHub App key among them), so a settings row must never
# choose an image from another registry.
IMAGE=$(lf_str image registry.fly.io/lane-run:latest '^registry\.fly\.io/lane-run[:@][A-Za-z0-9._:-]{1,128}$')

# ---- the Fly token (BH-6741) -----------------------------------------------
# env/fly.env, loaded the way bin/fly-pool.sh loads it. The lane-run app's own
# token wins, else the org token. flyctl reads FLY_ACCESS_TOKEN; with no token it
# falls back to the interactive login in ~/.fly/config.yml, which expires (the
# hub tick of 2026-10-14 17:52Z: "your flyctl session has expired"). So with no
# token there is no Fly call at all, and one ALERTS line per UTC hour.
# The app token's name follows bin/fly-pool.sh's rule: FLY_API_TOKEN_<APP>,
# here FLY_API_TOKEN_LANE_RUN (a group app: FLY_API_TOKEN_LANE_RUN_<X>). A
# credential, so it is not a registry knob.
TV="FLY_API_TOKEN_$(echo "$LF_APP" | tr '[:lower:].-' '[:upper:]__')"
FLY_ACCESS_TOKEN="${!TV:-${FLY_API_TOKEN:-}}"
if [ -z "$FLY_ACCESS_TOKEN" ]; then
  lf_log "Fly token missing for $LF_APP (no $TV or FLY_API_TOKEN in $HENV/fly.env); no Fly call, no start, no stop"
  lf_alert fly-token-missing "Fly token missing for $LF_APP: $HENV/fly.env has no $TV or FLY_API_TOKEN; the lane-run fleet starts and stops no machine" hour
  exit 0
fi
export FLY_ACCESS_TOKEN FLY_API_TOKEN="$FLY_ACCESS_TOKEN"

STATS="$W_DIR/stats.json"; LIST="$W_DIR/fly-list.json"; ROWS="$W_DIR/machines.json"

# ---- read (any failure: no action) ------------------------------------------
lf_read_fail() { lf_log "tick read failed: $1 ($2); no start, no stop"; lf_alert "$1" "$1 read failed ($2); no machine is started or stopped until it answers"; exit 0; }
_jobs_req GET "/api/lane-runs/stats?run_p50=1$LF_SQ" > "$STATS" || lf_read_fail stats "http ${JOBS_HTTP:-none}"
jq -e '.lanes | type == "array"' "$STATS" >/dev/null 2>&1 || lf_read_fail stats "no lanes array"
W=$(jq -r '[.lanes[].oldest_queued_wait_s | select(type == "number")] | max // "none" | tostring' "$STATS")
case "$W" in none) ;; *[!0-9]*|'') lf_read_fail stats "bad wait '$W'" ;; esac
# The queued work in run seconds (BH-6885). A lane with no done sample
# (run_p50_s null) adds 0; the wait rule still starts one machine for it.
WORK=$(jq -r '[.lanes[] | select((.run_p50_s | type) == "number" and (.queued | type) == "number")
  | .queued * .run_p50_s] | add // 0 | floor | tostring' "$STATS")
case "$WORK" in *[!0-9]*|'') lf_read_fail stats "bad work '$WORK'" ;; esac
if [ -n "$GJ" ]; then
  # Fallback (BH-7434): past group_fallback_s the worker lets lane-run claim
  # this group's rows; say so once per UTC day.
  FB=$(jq -r '.group_fallback_s // 0' "$GROUPS_F" 2>/dev/null); [[ "$FB" =~ ^[0-9]+$ ]] || FB=0
  if [ "$FB" -gt 0 ] && [ "$W" != none ] && [ "$W" -gt "$FB" ]; then
    lf_log "fallback: a queued run waited ${W}s > lane_run.group_fallback_s ${FB}s; lane-run may claim this group's rows"
    lf_alert fallback "group $LF_GROUP: a queued run waited ${W}s, over lane_run.group_fallback_s ${FB}s; the default lane-run fleet claims its rows until $LF_APP takes them again (fleet down, at max_machines, or failing starts)"
  fi
  if [ -n "$LF_BOX" ]; then
    # The warm floor holds only while a placement row points at the box (A4).
    # Not placed, no queued run and no starting/started row: nothing to stop or
    # start, so no Fly call at all (the operator row can exist before the app).
    if [ "$(jq -r '.placed == true' "$STATS")" != true ]; then
      FLOOR=0
      _jobs_req GET "/api/lane-fleet/machines$LF_MQ" > "$ROWS" || lf_read_fail machines "http ${JOBS_HTTP:-none}"
      jq -e '.machines | type == "array"' "$ROWS" >/dev/null 2>&1 || lf_read_fail machines "no machines array"
      if [ "$W" = none ] && [ "$(jq '[.machines[] | select(.state == "starting" or .state == "started")] | length' "$ROWS")" = 0 ]; then
        lf_log "box $LF_BOX: no placement row and no machine; nothing to do"; exit 0
      fi
      lf_log "box $LF_BOX: no placement row; floor 0"
    fi
  fi
  lf_app_ready || { lf_log "tick fleet=$LF_GROUP app=$LF_APP not ready; no start, no stop"; exit 0; }
fi
if ! timeout 30 "$FLY" machine list -a "$LF_APP" --json > "$LIST" 2> "$LIST.err"; then
  FERR=$(tr '\n' ' ' < "$LIST.err" | cut -c1-200)
  # An auth answer is the token, not Fly: name the cause (BH-6741).
  if grep -qiE 'unauthori[sz]ed|not authorized|session has expired|\b401\b|(invalid|expired|bad) (access )?token|token (is )?(invalid|expired|not valid)' <<<"$FERR"; then
    lf_log "tick read failed: Fly token rejected for $LF_APP ($FERR); no start, no stop"
    lf_alert fly-token-rejected "Fly token rejected for $LF_APP ($FERR); renew $TV or FLY_API_TOKEN in $HENV/fly.env; no machine is started or stopped until it works" hour
    exit 0
  fi
  lf_read_fail fly-list "$FERR"
fi
jq -e 'type == "array"' "$LIST" >/dev/null 2>&1 || lf_read_fail fly-list "not a JSON array"
command -v lfi_log_images >/dev/null 2>&1 && lfi_log_images "$LIST" "$W_DIR/images.tsv" lf_log
_jobs_req GET "/api/lane-fleet/machines$LF_MQ" > "$ROWS" || lf_read_fail machines "http ${JOBS_HTTP:-none}"
jq -e '.machines | type == "array"' "$ROWS" >/dev/null 2>&1 || lf_read_fail machines "no machines array"

# lf_record <mid> <state> [started_at|stopped_at] [cpu_kind cpus memory_mb] [failed]
#   the third field is started_at for starting|started, stopped_at otherwise.
lf_record() {
  local b
  b=$(jq -nc --arg m "$1" --arg s "$2" --arg at "${3:-}" --arg k "${4:-}" --arg c "${5:-}" --arg mb "${6:-}" --arg f "${7:-}" \
        --arg app "$LF_RAPP" '
    {machine_id:$m, state:$s, box:"lane-fleet"}
    + (if $app == "" then {} else {app:$app} end)
    + (if $at == "" then {} elif ($s == "starting" or $s == "started") then {started_at:$at} else {stopped_at:$at} end)
    + (if $f == "failed" then {failed:true} else {} end)
    + (if $k == "" then {} else {cpu_kind:$k} end)
    + (if ($c | test("^[0-9]+$")) then {cpus:($c|tonumber)} else {} end)
    + (if ($mb | test("^[0-9]+$")) then {memory_mb:($mb|tonumber)} else {} end)')
  _jobs_req POST /api/lane-fleet/machines "$b" > /dev/null
}
# lf_guest <mid> -> "<cpu_kind> <cpus> <memory_mb>" from the listing.
lf_guest() {
  jq -r --arg m "$1" '.[] | select(.id == $m) | .config.guest // {}
    | "\(.cpu_kind // "") \(.cpus // "") \(.memory_mb // "")"' "$LIST" | head -1
}
COST_W=0; COST_A=0
# lf_cost <mid> — post this machine's minutes through the current minute.
lf_cost() {
  local kind cpus mem rate _src b out
  read -r kind cpus mem <<<"$(lf_guest "$1")"
  if read -r rate _src < <(fly_price_per_s "$H/catalog/fly-prices.json" "$kind" "$cpus" "$mem") && [ -n "$rate" ]; then :; else rate=null; fi
  b=$(jq -nc --arg m "$1" --arg th "$(date -u -d "@$(( NOW / 60 * 60 ))" +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$rate" \
        --arg k "$kind" --arg c "$cpus" --arg mb "$mem" '
    {machine_id:$m, through:$th, usd_per_s:$r}
    + (if ($k | test("^[a-z0-9-]{1,32}$")) then {cpu_kind:$k} else {} end)
    + (if ($c | test("^[0-9]+$")) then {cpus:($c|tonumber)} else {} end)
    + (if ($mb | test("^[0-9]+$")) then {memory_mb:($mb|tonumber)} else {} end)')
  if out=$(_jobs_req POST /api/lane-fleet/cost "$b"); then
    COST_W=$(( COST_W + $(jq -r '.written // 0' <<<"$out") ))
    COST_A=$(( COST_A + $(jq -r '.already // 0' <<<"$out") ))
  else
    lf_log "cost $1 failed (http ${JOBS_HTTP:-none}); the next tick resumes from costed_until"
  fi
}

# ---- adopt and reconcile ----------------------------------------------------
FLY_STARTED=$(jq -c '[.[] | select(.state == "started") | .id]' "$LIST")
ROW_IDS=$(jq -c '[.machines[].machine_id]' "$ROWS")
LOST=0
while IFS=$'\t' read -r mid upd; do
  [ -n "$mid" ] || continue
  read -r kind cpus mem <<<"$(lf_guest "$mid")"
  age=$(( NOW - $(lf_epoch "$upd" || echo 0) ))
  if [ "$age" -lt "$GRACE" ]; then
    LOST=$((LOST + 1)); lf_record "$mid" starting "$upd" "$kind" "$cpus" "$mem" \
      || lf_log "adopt $mid failed (http ${JOBS_HTTP:-none})"
  else
    lf_record "$mid" started "$upd" "$kind" "$cpus" "$mem" || lf_log "adopt $mid failed (http ${JOBS_HTTP:-none})"
  fi
  lf_log "adopted $mid (Fly started, no row; updated ${age}s ago)"
done < <(jq -r --argjson rows "$ROW_IDS" '.[] | select(.state == "started" and (.id as $i | $rows | index($i) | not))
  | [.id, (.updated_at // .created_at // "")] | @tsv' "$LIST" | head -50)
# lf_fly_state <mid> -> "<Fly state|absent> <updated_at|->" from the listing.
lf_fly_state() {
  jq -r --arg m "$1" '(map(select(.id == $m)) | .[0]) as $x
    | "\(($x.state // "absent")) \(($x.updated_at // "-"))"' "$LIST"
}
# lf_stop_at <Fly updated_at|-> — Fly's stop time as an ISO stamp, or nothing.
lf_stop_at() {
  local e
  e=$(lf_epoch "$1") || return 0
  [ "$e" -le "$NOW" ] || e=$NOW
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}
# The row is stopped at Fly's stop time BEFORE its cost, so the cost route
# caps the bill there, not at the minute the tick noticed it.
while IFS=$'\t' read -r mid; do
  [ -n "$mid" ] || continue
  read -r fst fupd <<<"$(lf_fly_state "$mid")"
  st=stopped; [ "$fst" = absent ] || [ "$fst" = destroyed ] && st=destroyed
  if lf_record "$mid" "$st" "$(lf_stop_at "$fupd")"; then
    lf_log "reconciled $mid: Fly $fst, row $st"; lf_cost "$mid"
  else
    lf_log "reconcile $mid failed (http ${JOBS_HTTP:-none})"
  fi
done < <(jq -r --slurpfile l "$LIST" '.machines[] | select(.state == "started") | .machine_id as $i
  | (($l[0] | map(select(.id == $i)) | .[0].state) // "absent") as $s
  | select($s == "stopped" or $s == "destroyed" or $s == "absent") | $i' "$ROWS" | head -20)

# ---- failed starts ----------------------------------------------------------
# A `starting` row has made no claim since its started_at (the first claim
# promotes it). Past grace, or with its machine already exited, it never will:
# stop it, alert, and hold every start for the backoff (lf_decide HOLD).
# Two cases are NOT failed starts (re-review of 2c0d0898, findings 1 and 2):
#   - a row whose machine holds a live claim (busy): it is working, and a stop
#     would kill its run;
#   - a row past grace whose machine Fly lists `started` while no queued run
#     waited for the machine's whole life (W none, or W < its age): a healthy
#     idle machine with nothing to claim, the warm floor's normal state. It is
#     promoted to `started` (proof of life), so the floor holds.
FAILED=0; FAILED_IDS="[]"
while IFS=$'\t' read -r mid inf sa busy; do
  [ -n "$mid" ] || continue
  [ "$busy" = true ] && continue
  read -r fst fupd <<<"$(lf_fly_state "$mid")"
  case "$inf:$fst" in
    true:stopped|true:destroyed|false:*) ;;
    *) continue ;;
  esac
  age=$(( NOW - $(lf_epoch "$sa" || echo "$NOW") ))
  if [ "$inf:$fst" = false:started ] && { [ "$W" = none ] || [ "$W" -lt "$age" ]; }; then
    read -r kind cpus mem <<<"$(lf_guest "$mid")"
    if lf_record "$mid" started "$sa" "$kind" "$cpus" "$mem"; then
      lf_log "promoted $mid to started: Fly started, ${age}s old, no run waited for it (wait $W)"
    else
      lf_log "promote $mid failed (http ${JOBS_HTTP:-none})"
    fi
    continue
  fi
  FAILED=$((FAILED + 1)); FAILED_IDS=$(jq -c --arg m "$mid" '. + [$m]' <<<"$FAILED_IDS")
  lf_log "start $mid made no claim in ${age}s (Fly $fst); stopping it, no start for ${BACKOFF}s"
  lf_alert no-claim "start $mid made no claim in ${age}s (Fly $fst); the fleet starts nothing for ${BACKOFF}s after each such start; check the machine log (flyctl logs -a $LF_APP -i $mid)"
  st=stopped; at=""
  case "$fst" in
    stopped) at=$(lf_stop_at "$fupd") ;;
    destroyed|absent) st=destroyed; at=$(lf_stop_at "$fupd") ;;
    *)
      if ! out=$(timeout 120 "$FLY" machine stop "$mid" -a "$LF_APP" 2>&1); then
        lf_log "machine stop $mid failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        lf_alert "stop-$mid" "machine stop $mid in $LF_APP failed; it made no claim and still runs; the next tick retries"
        continue
      fi ;;
  esac
  if lf_record "$mid" "$st" "$at" "" "" "" failed; then lf_cost "$mid"
  else lf_log "record of failed start $mid failed (http ${JOBS_HTTP:-none})"; fi
done < <(jq -r '.machines[] | select(.state == "starting") | [.machine_id, (.in_flight == true | tostring), .started_at, (.busy == true | tostring)] | @tsv' "$ROWS" | head -20)
HOLD=$FAILED
LASTF=$(jq -r '.last_failed_at // empty' "$ROWS")
if [ "$HOLD" = 0 ] && [ -n "$LASTF" ] && lf_epoch "$LASTF" >/dev/null; then
  [ $(( NOW - $(lf_epoch "$LASTF") )) -lt "$BACKOFF" ] && HOLD=1
fi

# ---- count ------------------------------------------------------------------
INFL_IDS=$(jq -c --slurpfile l "$LIST" --argjson fl "$FAILED_IDS" '
  ($l[0] | map({(.id): .state}) | add // {}) as $fs
  | [ (.machines[] | select(.in_flight == true and (($fs[.machine_id] // "absent") | IN("stopped","destroyed") | not)) | .machine_id),
      ($l[0][] | select(.state == "created" or .state == "starting") | .id) ]
  | map(select(. as $i | $fl | index($i) | not)) | unique' "$ROWS")
INFLIGHT=$(( $(jq 'length' <<<"$INFL_IDS") + LOST ))
LIVE=$(jq --argjson inf "$INFL_IDS" --argjson fl "$FAILED_IDS" '[.[] | select(. as $i | ($inf | index($i) | not) and ($fl | index($i) | not))] | length' <<<"$FLY_STARTED")
LIVE=$(( LIVE - LOST )); [ "$LIVE" -ge 0 ] || LIVE=0
# The stop candidates: rows Fly reports `started`.
CANDS=$(jq -c --argjson fs "$FLY_STARTED" --argjson fl "$FAILED_IDS" '[.machines[] | select(.machine_id as $i | ($fs | index($i)) and ($fl | index($i) | not))]' "$ROWS")

# lf_volume_ready — the box group's volume exists, else ONE create (BH-7716).
# rc 1 = a failed list or create: no machine run this tick, one ALERTS line per
# UTC day, and the next tick retries.
lf_volume_ready() {
  local out n gb rg="${FLY_REGION:-iad}"
  if ! out=$(timeout 60 "$FLY" volumes list --app "$LF_APP" --json 2>&1); then
    lf_log "volume $LF_VOL: volumes list failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200); no machine run"
    lf_alert volume "flyctl volumes list --app $LF_APP failed ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); group $LF_GROUP starts no new machine until it answers"
    return 1
  fi
  n=$(jq --arg v "$LF_VOL" '[.[]? | select((.name // .Name) == $v and (((.state // .State // "") | test("destroy")) | not))] | length' <<<"$out" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || { lf_log "volume $LF_VOL: volumes list is not a JSON array; no machine run"
    lf_alert volume "flyctl volumes list --app $LF_APP gave no JSON array; group $LF_GROUP starts no new machine until it answers"; return 1; }
  [ "$n" -gt 0 ] && return 0
  gb=$(lf_gint volume_gb 20 1 500)
  if ! out=$(timeout 180 "$FLY" volumes create "$LF_VOL" --app "$LF_APP" --size "$gb" --region "$rg" --yes 2>&1); then
    lf_log "volume $LF_VOL: volumes create failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200); no machine run"
    lf_alert volume "flyctl volumes create $LF_VOL --app $LF_APP --size $gb --region $rg failed ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)); group $LF_GROUP starts no machine; the next tick retries"
    return 1
  fi
  lf_log "volume $LF_VOL: created ${gb} GB in $rg"
}

# ---- decide -----------------------------------------------------------------
read -r DEC N WHY <<<"$(lf_decide "$W" "$LIVE" "$INFLIGHT" "$FLOOR" "$UPWAIT" "$MAX" "$HOLD" "$WORK" "$TARGET" "$MAXSTARTS")"
[ "$DEC" = start ] || { WHY="$N${WHY:+ $WHY}"; N=0; }
ACTION="none $WHY"
STOPPED=""
if [ "$DEC" = start ]; then
  # Every start is recorded at the tick's decision time, before `machine start`
  # or `machine run`, never at the POST time: a machine that claims a run
  # before the POST lands still counts that claim (re-review finding 2).
  DECIDED_AT=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  mapfile -t REUSES < <(jq -r '[.[] | select(.state == "stopped") | .id] | sort | .[]' "$LIST")
  kind=""; cpus=""
  [[ "$SIZE" =~ ^(shared-cpu|performance)-([0-9]+)x$ ]] && { kind=${BASH_REMATCH[1]%-cpu}; cpus=${BASH_REMATCH[2]}; }
  STARTED=""; K=0; RI=0; FAILWHY=""
  while [ "$K" -lt "$N" ]; do
    if [ "$RI" -lt "${#REUSES[@]}" ]; then
      REUSE=${REUSES[$RI]}; RI=$((RI + 1))
      if out=$(timeout 120 "$FLY" machine start "$REUSE" -a "$LF_APP" 2>&1); then
        read -r rkind rcpus rmem <<<"$(lf_guest "$REUSE")"
        lf_record "$REUSE" starting "$DECIDED_AT" "$rkind" "$rcpus" "$rmem" || {
          lf_log "record of start $REUSE failed (http ${JOBS_HTTP:-none}); Fly's state holds the next tick back"
          lf_alert record "machine $REUSE started but its row was not written (http ${JOBS_HTTP:-none})"; }
        lf_log "start $REUSE: machine start image=$(command -v lfi_ref >/dev/null 2>&1 && lfi_ref "$LIST" "$REUSE")"
        STARTED="$STARTED,$REUSE"; K=$((K + 1))
      else
        lf_log "machine start $REUSE failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200); destroying it"
        dout=$(timeout 60 "$FLY" machine destroy "$REUSE" -a "$LF_APP" --force 2>&1); drc=$?
        case "$drc:$dout" in
          0:*|*"not found"*|*"Could not find"*) lf_record "$REUSE" destroyed >/dev/null; lf_log "destroyed $REUSE" ;;
          *) lf_log "destroy $REUSE FAILED rc=$drc: $(printf '%s' "$dout" | tr '\n' ' ' | cut -c1-200)"
             lf_alert "destroy-$REUSE" "machine destroy $REUSE FAILED rc=$drc; it is still in $LF_APP and the next tick retries the reuse" ;;
        esac
        FAILWHY="reuse-failed $REUSE"; break
      fi
    else
      if [ -n "$LF_VOL" ] && [ -z "$LF_VOL_OK" ]; then
        lf_volume_ready || { FAILWHY="volume-failed"; break; }
        LF_VOL_OK=1
      fi
      out=$(timeout 180 "$FLY" machine run "$IMAGE" --app "$LF_APP" --detach --restart no \
              --vm-size "$SIZE" --vm-memory "$MEM" -e LANE_RUN=1 ${LF_GENV[@]+"${LF_GENV[@]}"} 2>&1)
      # The id comes off the "Machine ID:" line ONLY (fly-pool.sh: the first bare
      # hex run can be the image digest).
      mid=$(printf '%s\n' "$out" | sed -n 's/.*[Mm]achine ID:[[:space:]]*\([0-9a-z]\{8,32\}\).*/\1/p' | head -1)
      if [ -z "$mid" ]; then
        lf_log "machine run gave no Machine ID: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        lf_alert start "flyctl machine run in $LF_APP gave no machine id; nothing recorded, the next tick retries"
        FAILWHY="start-failed"; break
      fi
      lf_record "$mid" starting "$DECIDED_AT" "$kind" "$cpus" "$MEM" || {
        lf_log "record of start $mid failed (http ${JOBS_HTTP:-none}); Fly's state holds the next tick back"
        lf_alert record "machine $mid started but its row was not written (http ${JOBS_HTTP:-none})"; }
      lf_log "start $mid: machine run image=$IMAGE"
      STARTED="$STARTED,$mid"; K=$((K + 1))
    fi
  done
  if [ "$K" -gt 0 ]; then
    ACTION="start ${STARTED#,} $WHY"
    [ -z "$FAILWHY" ] || lf_log "start batch stopped after $K of $N: $FAILWHY"
  else
    ACTION="none $FAILWHY"
  fi
elif [ "$W" = none ]; then
  SMID=$(lf_pick_stop "$LIVE" "$FLOOR" "$IDLE" "$CANDS")
  if [ -n "$SMID" ]; then
    sidle=$(jq -r --arg m "$SMID" '.[] | select(.machine_id == $m) | .idle_s' <<<"$CANDS")
    lf_cost "$SMID"
    if out=$(timeout 120 "$FLY" machine stop "$SMID" -a "$LF_APP" 2>&1); then
      lf_record "$SMID" stopped || lf_log "record of stop $SMID failed (http ${JOBS_HTTP:-none})"
      ACTION="stop $SMID idle=$sidle"; STOPPED="$SMID"
    else
      lf_log "machine stop $SMID failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      lf_alert "stop-$SMID" "machine stop $SMID in $LF_APP failed; the next tick retries"
      ACTION="none stop-failed $SMID"
    fi
  fi
fi

# ---- cost -------------------------------------------------------------------
while read -r mid; do
  [ -n "$mid" ] && [ "$mid" != "$STOPPED" ] && lf_cost "$mid"
done < <(jq -r --argjson fl "$FAILED_IDS" '.[] | select(. as $i | $fl | index($i) | not)' <<<"$FLY_STARTED" | head -500)

MAXS=$MAX; [ "$MAX" = 0 ] && MAXS=none
lf_log "tick wait=$W live=$LIVE inflight=$INFLIGHT floor=$FLOOR max=$MAXS action=$ACTION cost=$COST_W/$COST_A work=${WORK}s desired=$(( (WORK + TARGET - 1) / TARGET ))"
exit 0
}

# ---- the fleets (BH-7434) ---------------------------------------------------
# GET /api/lane-fleet/groups: 404 (a worker without the route) = no group; any
# other failure = no pass at all this tick (a pass without the split would
# reconcile a group's machines as gone). The groups answer is part of the
# tick's stats read, so it alerts under the same `stats` kind and day flag.
GROUPS_F="$H/state/lane-fleet/groups.json"
if ! _jobs_req GET /api/lane-fleet/groups > "$GROUPS_F"; then
  if [ "${JOBS_HTTP:-}" = 404 ]; then echo '{"groups":[]}' > "$GROUPS_F"
  else
    lf_log "tick read failed: stats (groups http ${JOBS_HTTP:-none}); no start, no stop"
    lf_alert stats "stats read failed (groups http ${JOBS_HTTP:-none}); no machine is started or stopped until it answers"
    exit 0
  fi
fi
jq -e '.groups | type == "array"' "$GROUPS_F" >/dev/null 2>&1 || {
  lf_log "tick read failed: stats (groups: no groups array); no start, no stop"
  lf_alert stats "stats read failed (groups: no groups array); no machine is started or stopped until it answers"; exit 0; }
LF_GROUPS=()
while IFS= read -r g; do [ -n "$g" ] && LF_GROUPS+=("$g"); done \
  < <(jq -r '.groups[].name | select(test("^[a-z0-9][a-z0-9-]{0,29}$"))' "$GROUPS_F")
# Orphaned group machines (review F1 of #7447): a starting/started row whose
# app is neither lane-run nor a current group's app (its group row was deleted
# or went invalid). No pass reads it, so nothing scales, stops or costs it:
# one ALERTS line per UTC day naming each. A failed read skips the check.
if _jobs_req GET /api/lane-fleet/machines > "$H/state/lane-fleet/all-machines.json"; then
  ORPH=$(jq -r --slurpfile g "$GROUPS_F" '(["lane-run"] + [$g[0].groups[]?.app]) as $k
    | [.machines[]? | (.app // "lane-run") as $a | select($k | index($a) | not) | "\($a)/\(.machine_id)"] | join(" ")' \
    "$H/state/lane-fleet/all-machines.json" 2>/dev/null)
  if [ -n "$ORPH" ]; then
    lf_log "orphaned group machines (no lane_fleet.group row names their app): $ORPH"
    lf_alert orphan "machines of a fleet group whose lane_fleet.group row is gone or invalid are still started and are not scaled, stopped or costed: $ORPH. Restore the row, or stop each with flyctl machine stop <id> -a <app> (the rows reconcile once the app is a group again)"
  fi
fi
if [ "${#LF_GROUPS[@]}" = 0 ]; then
  ( lf_pass )
  exit 0
fi
( lf_pass default )
for g in "${LF_GROUPS[@]}"; do ( lf_pass "$g" ); done
exit 0

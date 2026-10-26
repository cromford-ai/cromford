#!/bin/bash
# bin/box-move.sh — move a project box to a Fly machine (BH-8322, MKF-7; parent
# #8315 D2-a). An operator runs it on the hub. The runbook is
# docs/notes/2026-10-25-BH-8322-MKF-7-box-move.md.
#
# usage:
#   bin/box-move.sh inventory <oldbox> <newbox>
#   bin/box-move.sh provision [--plan] <oldbox> <newbox>
#   bin/box-move.sh seed <oldbox> <newbox> [<ts>|latest]
#   bin/box-move.sh tick <oldbox> <newbox>
#   bin/box-move.sh proof <oldbox> <newbox>
#
# <oldbox> and <newbox> are fleet box names (box-project-6-os-1,
# box-mkfly). The old box id, address and projects come from the rows
# (bin/fleet-conf.sh --boxes-with-roles, --tailnet-ip-of-box, --projects-on-box;
# REGISTRY_SOURCE=db reads the D1 registry), never from a file on the old box.
# The new machine keeps the old box id, so render-cron.sh <box id> renders the
# old box's crontab there. This slice writes no fleet row, no crontab and no
# file on the old box.
#
# inventory  names only: the rows, the old box's active crontab line count, the
#            rendered line count, the env file and KEY names on the old box,
#            its state/backup-last.json ts, the target.json fields. Read-only.
# provision  Fly only, through bin/lib/hub-move-fly.sh (bin/lib/box-move/provision.sh):
#            app, volume box_data, the staged secrets TS_AUTHKEY (from
#            TS_AUTHKEY_BOX in fly.env) and HUB_AUTHORIZED_KEY, the machine;
#            each created only after its find answered absent. The app must be
#            exempt in catalog/fly-idle-signals.json. Then the tailnet wait and
#            state/box-move/<newbox>/target.json. --plan prints each action
#            and calls nothing.
# seed       code from the hub, env BOX TO BOX (old box tar into new box tar,
#            never a hub file), state-restore of the MKF-6 backup on the new
#            box, the box-id check, box-name, repos, then a local flags/all-off
#            and the markers (bin/lib/box-move/seed.sh).
# tick       bin/hub-move.sh tick (no-write: the shim bin/lib/hub-move-nowrite.sh)
#            on the new box; the table is copied to
#            state/box-move/<newbox>/tick-<ts>.tsv with its summary line in
#            tick-<ts>.summary. Exit 4 when the tick rc is not 0 or no
#            tick-file line came back. --real is refused (exit 2): this slice
#            has no cut-over step to run it in.
# proof      on the new box: load1 load5 load15 nproc load5_per_vcpu, the
#            active crontab line count, flags/all-off; the newest tick summary
#            on the hub; the projects the rows put on each box. Read-only.
#
# Knobs (env, operator-run, no lane row; the value after each name is the
# fallback): BOX_MOVE_APP (<newbox>), BOX_MOVE_REGION (iad), BOX_MOVE_VM_SIZE
# (performance-4x), BOX_MOVE_MEM_MB (8192), BOX_MOVE_VOLUME_GB (100),
# BOX_MOVE_TS_HOSTNAME (<newbox>), BOX_MOVE_IMAGE (required for provision, no
# fallback), BOX_MOVE_TS_WAIT_S (300), BOX_MOVE_TS_POLL_S (10),
# BOX_MOVE_SSH_CONNECT_TIMEOUT_S (15), BOX_MOVE_TARGET_HARNESS (/root/harness,
# the harness on the new box), BOX_MOVE_OLD_HARNESS (/root/harness, on the old
# box), BOX_MOVE_TARGET_ORCH (/root/orchestrator, on the new box),
# BOX_MOVE_SSH_DIR ($HOME/.ssh, the hub keys), BOX_MOVE_PROC_LOADAVG
# (/proc/loadavg on the new box) and BOX_MOVE_NPROC (the new box's nproc) for
# proof. HUB_MOVE_REACH_HOST, when set, is passed to the tick; else the old
# box address is.
#
# Exit: 0 done; 2 usage or a bad knob (nothing done); 3 preflight refused
# (nothing done, one stderr line, one alert-line row box-move-preflight); 4 a
# step failed (no later step ran); 75 Fly answered "rate limited".
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
# shellcheck source=bin/lib/env-path.sh
. "$SELF_DIR/lib/env-path.sh" || exit 2
# shellcheck source=bin/lib/hub-move-fly.sh
. "$SELF_DIR/lib/hub-move-fly.sh" || exit 2
# shellcheck source=bin/lib/box-move/common.sh
. "$SELF_DIR/lib/box-move/common.sh" || exit 2
# shellcheck source=bin/lib/box-move/provision.sh
. "$SELF_DIR/lib/box-move/provision.sh" || exit 2
# shellcheck source=bin/lib/box-move/seed.sh
. "$SELF_DIR/lib/box-move/seed.sh" || exit 2

BIN="$SELF_DIR"
BM_TH="${BOX_MOVE_TARGET_HARNESS:-/root/harness}"
BM_OH="${BOX_MOVE_OLD_HARNESS:-/root/harness}"
BM_TORCH="${BOX_MOVE_TARGET_ORCH:-/root/orchestrator}"
BM_SSH_DIR="${BOX_MOVE_SSH_DIR:-$HOME/.ssh}"
# The git checkout render-cron.sh runs from (bin/harness-sync.sh's default);
# the deployed $HARNESS has no cron/.
BM_CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
BM_IDLE_SIGNALS="$SELF_DIR/../catalog/fly-idle-signals.json"
BM_VOLUME_NAME=box_data

usage() { sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---- sandbox guard (as bin/hub-move.sh's) ------------------------------------
sandbox_guard() {
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] || return 0
  local base pair label p r n
  base=$(realpath -m "${TMPDIR:-/tmp}" 2>/dev/null) || base=""
  for pair in "HARNESS=$HARNESS" "BOX_MOVE_TARGET_HARNESS=$BM_TH" "BOX_MOVE_OLD_HARNESS=$BM_OH" \
      "BOX_MOVE_TARGET_ORCH=$BM_TORCH" "BOX_MOVE_SSH_DIR=$BM_SSH_DIR" "HARNESS_CHECKOUT=$BM_CHECKOUT"; do
    label="${pair%%=*}"; p="${pair#*=}"
    r=$(realpath -m "$p" 2>/dev/null) || r=""
    case "$r" in /root/orchestrator|/root/orchestrator/*|/root/harness|/root/harness/*) r="" ;; esac
    case "$r" in "$base"/scratch.??????/*) [ -n "$base" ] && continue ;; esac
    echo "box-move: refused: HARNESS_TEST_SANDBOX=1 and $label=$p is outside the test scratch root ${base:-?}/scratch.*" >&2
    exit 2
  done
  # Every remote step is an ssh: under the sandbox it must be the suite's stub.
  for n in ssh rsync tailscale; do
    p=$(command -v "$n" 2>/dev/null) || continue
    r=$(realpath -m "$p" 2>/dev/null) || r=""
    case "$r" in "$base"/scratch.??????/*) [ -n "$base" ] && continue ;; esac
    echo "box-move: refused: HARNESS_TEST_SANDBOX=1 and $n=$p is outside the test scratch root ${base:-?}/scratch.*" >&2
    exit 2
  done
}

check_knobs() {
  local k
  for k in BM_MEM_MB BM_VOLUME_GB BM_TS_POLL_S BM_SSH_CONNECT_TIMEOUT_S; do
    bm_is_posint "${!k}" || { echo "box-move: BOX_MOVE_${k#BM_}='${!k}' is not a positive integer" >&2; exit 2; }
  done
  bm_is_uint "$BM_TS_WAIT_S" || { echo "box-move: BOX_MOVE_TS_WAIT_S='$BM_TS_WAIT_S' is not a whole number" >&2; exit 2; }
  [ -z "$BM_NPROC" ] || bm_is_posint "$BM_NPROC" || { echo "box-move: BOX_MOVE_NPROC='$BM_NPROC' is not a positive integer" >&2; exit 2; }
  for k in BM_APP BM_REGION BM_VM_SIZE BM_TS_HOSTNAME; do
    bm_is_name "${!k}" || { echo "box-move: BOX_MOVE_${k#BM_}='${!k}' is not a valid name" >&2; exit 2; }
  done
  if [ -n "$BM_REACH" ] && { [[ "$BM_REACH" == *$'\n'* ]] || ! grep -qE '^[A-Za-z0-9][A-Za-z0-9._:-]*$' <<<"$BM_REACH"; }; then
    echo "box-move: HUB_MOVE_REACH_HOST='$BM_REACH' is not a host name or address" >&2; exit 2
  fi
}

# ==== inventory ================================================================
# The old box side of inventory, run there: names and counts only.
BM_S_OLD_INVENTORY="$BM_ENV_RESOLVE"'
n=$(crontab -l 2>/dev/null | grep -cvE "^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=")
echo "old_crontab_active=${n:-0}"
for f in "$d"/*; do
  [ -f "$f" ] || continue
  b=${f##*/}
  case "$b" in *.pem|*.key) echo "env_file=$b (key file)"; continue ;; esac
  echo "env_file=$b keys: $(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p" "$f" | tr "\n" " ")"
done
echo "backup_last=$(jq -r ".ts // empty" "$1/state/backup-last.json" 2>/dev/null || true)"'

cmd_inventory() {
  local old="$1" new="$2" role cron rc out k v
  bm_rows_resolve "$old" "$new"
  role=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null | awk -F'\t' -v b="$old" '$1 == b {print $3; exit}')
  local plist="${BM_PROJECTS// /,}"
  echo "box-move inventory: old=$old new=$new registry_source=$BM_REG_SOURCE"
  echo "rows: box=$old box_id=$BM_BOX_ID ip=$BM_OLD_IP role=${role:--} projects=${plist:--}"
  echo "rows: box=$new projects=-"
  rc=0; cron=$("$BM_CHECKOUT/bin/render-cron.sh" "$BM_BOX_ID" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "rendered: ERROR $BM_CHECKOUT/bin/render-cron.sh $BM_BOX_ID rc=$rc"
  else
    echo "rendered: render-cron.sh $BM_BOX_ID rendered_lines=$(grep -c . <<<"$cron") rendered_commands=$(grep -cvE '^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' <<<"$cron")"
  fi
  out=$(bm_sh "$BM_OLD_IP" "$BM_S_OLD_INVENTORY" "$BM_OH" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out" | sed 's/^/old: /'
  else
    echo "old: ERROR cannot read $old ($BM_OLD_IP) rc=$rc"
  fi
  if [ -s "$BM_TJ" ]; then
    for k in provider app region size volume_id machine_id ts_hostname ts_ip provisioned_at old_box old_ip box_id; do
      v=$(bm_tj_get "$k"); [ -n "$v" ] && echo "target: $k=$v"
    done
  else
    echo "target: none (no $BM_TJ; run provision)"
  fi
}

# ==== tick =====================================================================
BM_S_TICK='HUB_MOVE_REACH_HOST="$2" HARNESS="$1" HARNESS_CHECKOUT="$3" "$1/bin/hub-move.sh" tick'

cmd_tick() {
  local old="$1" ip reach out rc f base
  ip=$(bm_tj_get ts_ip)
  [ -n "$ip" ] || bm_refuse "$BM_TJ has no ts_ip (run provision first)"
  grep -qE '^[0-9A-Fa-f.:]+$' <<<"$ip" || bm_refuse "$BM_TJ ts_ip '$ip' is not an address"
  reach="$BM_REACH"
  [ -n "$reach" ] || reach=$(bm_tj_get old_ip)
  [ -n "$reach" ] || reach=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$old" 2>/dev/null)
  bm_say "tick: hub-move.sh tick (no-write) on $ip, the crontab of box id $(bm_tj_get box_id)"
  out=$(bm_sh "$ip" "$BM_S_TICK" "$BM_TH" "$reach" "$BM_CHECKOUT"); rc=$?
  printf '%s\n' "$out"
  f=$(sed -n 's/^tick-file: //p' <<<"$out" | tail -1)
  # Fetch the table before the rc check: a stopped tick leaves a marked table.
  if [ -n "$f" ]; then
    base=$(basename "$f")
    case "$f" in "$BM_TH/state/hub-move/tick-"*.tsv) ;; *) bm_fail "tick on $ip named a table outside $BM_TH/state/hub-move: $f" ;; esac
    grep -qE '^tick-[0-9A-Za-z-]+\.tsv$' <<<"$base" || bm_fail "tick on $ip named a bad table $base"
    mkdir -p "$BM_STATE" || bm_fail "mkdir $BM_STATE"
    bm_sh "$ip" 'cat "$1"' "$f" > "$BM_STATE/$base.tmp" && mv -f "$BM_STATE/$base.tmp" "$BM_STATE/$base" || bm_fail "fetch $f"
    grep '^tick: lanes=' <<<"$out" | tail -1 > "$BM_STATE/${base%.tsv}.summary"
  fi
  [ "$rc" -eq 0 ] || bm_fail "tick on $ip rc=$rc"
  [ -n "$f" ] || bm_fail "tick on $ip printed no tick-file line"
  bm_say "tick: done; table in $BM_STATE/$base"
}

# ==== proof ====================================================================
BM_S_PROOF='la=$(cat "$2") || { echo "box-move: cannot read $2" >&2; exit 1; }
np="$3"; [ -n "$np" ] || np=$(nproc)
printf "%s\n" "$la" | awk -v n="$np" -v h="$(hostname)" "{ printf \"proof host=%s load1=%s load5=%s load15=%s nproc=%d load5_per_vcpu=%.2f\n\", h, \$1, \$2, \$3, n, \$2/n }"
c=$(crontab -l 2>/dev/null | grep -cvE "^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=")
echo "crontab_active=${c:-0}"
if HARNESS="$1" "$1/bin/jobs-client.sh" flag-has all-off >/dev/null 2>&1; then echo "all_off=on"; else echo "all_off=off"; fi
s=$(cat "$1/state/box-move/seeded" 2>/dev/null); echo "seeded=${s:-none}"'

cmd_proof() {
  local old="$1" new="$2" ip rc out f p
  ip=$(bm_tj_get ts_ip)
  [ -n "$ip" ] || bm_refuse "$BM_TJ has no ts_ip (run provision first)"
  out=$(bm_sh "$ip" "$BM_S_PROOF" "$BM_TH" "$BM_LOADAVG" "$BM_NPROC"); rc=$?
  [ "$rc" -eq 0 ] || bm_fail "proof on $ip rc=$rc"
  printf '%s\n' "$out"
  f=$(ls -t "$BM_STATE"/tick-*.summary 2>/dev/null | head -1)
  if [ -n "$f" ]; then echo "newest $(basename "$f"): $(cat "$f")"; else echo "newest tick: none"; fi
  for p in "$old" "$new"; do
    out=$("$BIN/fleet-conf.sh" --projects-on-box "$p" 2>/dev/null | paste -sd, -)
    echo "rows: $p projects=${out:--}"
  done
}

# ==== main =====================================================================
sandbox_guard || exit 2
VERB="${1:-}"; [ $# -gt 0 ] && shift
PLAN=0; REAL=0; POS=()
for a in "$@"; do
  case "$a" in
    --plan) PLAN=1 ;;
    --real) REAL=1 ;;
    -*) usage ;;
    *) POS+=("$a") ;;
  esac
done
case "$VERB" in inventory|provision|seed|tick|proof) ;; *) usage ;; esac
[ "$PLAN" -eq 0 ] || [ "$VERB" = provision ] || usage
if [ "$REAL" -eq 1 ]; then
  [ "$VERB" = tick ] || usage
  echo "box-move: tick --real runs only inside cutover (C1); this slice (C0) has no cutover step" >&2
  exit 2
fi
if [ "$VERB" = seed ]; then
  [ "${#POS[@]}" -eq 2 ] || [ "${#POS[@]}" -eq 3 ] || usage
else
  [ "${#POS[@]}" -eq 2 ] || usage
fi
OLD="${POS[0]}"; NEW="${POS[1]}"
for a in "$OLD" "$NEW"; do bm_is_name "$a" || { echo "box-move: '$a' is not a box name" >&2; exit 2; }; done

BM_APP="${BOX_MOVE_APP:-$NEW}"
BM_REGION="${BOX_MOVE_REGION:-iad}"
BM_VM_SIZE="${BOX_MOVE_VM_SIZE:-performance-4x}"
BM_MEM_MB="${BOX_MOVE_MEM_MB:-8192}"
BM_VOLUME_GB="${BOX_MOVE_VOLUME_GB:-100}"
BM_TS_HOSTNAME="${BOX_MOVE_TS_HOSTNAME:-$NEW}"
BM_IMAGE="${BOX_MOVE_IMAGE:-}"
BM_TS_WAIT_S="${BOX_MOVE_TS_WAIT_S:-300}"
BM_TS_POLL_S="${BOX_MOVE_TS_POLL_S:-10}"
BM_SSH_CONNECT_TIMEOUT_S="${BOX_MOVE_SSH_CONNECT_TIMEOUT_S:-15}"
BM_LOADAVG="${BOX_MOVE_PROC_LOADAVG:-/proc/loadavg}"
BM_NPROC="${BOX_MOVE_NPROC:-}"
BM_REACH="${HUB_MOVE_REACH_HOST:-}"
check_knobs
BM_SSH_OPTS=(-o BatchMode=yes -o "ConnectTimeout=$BM_SSH_CONNECT_TIMEOUT_S" -o StrictHostKeyChecking=accept-new)
BM_STATE="$HARNESS/state/box-move/$NEW"
BM_TJ="$BM_STATE/target.json"

case "$VERB" in
  provision|seed|tick)
    # Dedupe, never a queue: a held lock means another run is on this box.
    # --plan writes nothing, so it takes no lock.
    if [ "$PLAN" -eq 0 ]; then
      mkdir -p "$HARNESS/locks" 2>/dev/null
      exec 9>"$HARNESS/locks/box-move-$NEW.lock" || bm_fail "cannot open locks/box-move-$NEW.lock"
      flock -n 9 || { echo "box-move: already running (locks/box-move-$NEW.lock held)"; exit 0; }
    fi ;;
esac
case "$VERB" in
  inventory) cmd_inventory "$OLD" "$NEW" ;;
  provision) bm_provision "$PLAN" "$OLD" "$NEW" ;;
  seed)      bm_seed "${POS[2]:-latest}" "$OLD" "$NEW" ;;
  tick)      cmd_tick "$OLD" ;;
  proof)     cmd_proof "$OLD" "$NEW" ;;
esac

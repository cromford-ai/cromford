#!/bin/bash
# bin/lib/box-move/provision.sh — `bin/box-move.sh provision [--plan]`
# (BH-8322). Sourced by bin/box-move.sh after bin/lib/hub-move-fly.sh and
# bin/lib/box-move/common.sh; every Fly call is an hmf_* function of that seam.
#
# bm_provision <plan 0|1> <oldbox> <newbox>
#   plan=1: one `PLAN provision n/6:` line per action, then the knobs; no
#   flyctl, tailscale, ssh or fly.env read.
#   plan=0: preflight (image set; the app is `exempt` in
#   catalog/fly-idle-signals.json; the rows name the old box; fly.env has
#   FLY_ORG, FLY_API_TOKEN and TS_AUTHKEY_BOX; a hub ssh public key exists),
#   then app, volume, secrets and machine, each created only after its find
#   answered absent (rc 1). A find rc 2 stops the run with nothing created
#   (exit 4); rc 75 is exit 75. Then the tailnet wait and target.json.

bm_provision() {
  local plan="$1" old="$2" new="$3"
  if [ "$plan" -eq 1 ]; then
    [ -n "$BM_IMAGE" ] || echo "box-move: BOX_MOVE_IMAGE is not set: a real provision exits 2"
    echo "PLAN provision 1/6: app $BM_APP (find, then create in org \$FLY_ORG if absent)"
    echo "PLAN provision 2/6: volume $BM_VOLUME_NAME ${BM_VOLUME_GB} GB in $BM_REGION (find, then create if absent)"
    echo "PLAN provision 3/6: stage secret TS_AUTHKEY from TS_AUTHKEY_BOX (only when no machine exists)"
    echo "PLAN provision 4/6: stage secret HUB_AUTHORIZED_KEY from the hub id_*.pub (only when no machine exists)"
    echo "PLAN provision 5/6: machine image=${BM_IMAGE:-<BOX_MOVE_IMAGE>} --vm-size $BM_VM_SIZE --vm-memory $BM_MEM_MB -v <volume>:/data --restart always (find, then run if absent)"
    echo "PLAN provision 6/6: wait up to ${BM_TS_WAIT_S}s for tailnet host $BM_TS_HOSTNAME, then write state/box-move/$new/target.json"
    echo "knobs: app=$BM_APP region=$BM_REGION vm_size=$BM_VM_SIZE mem_mb=$BM_MEM_MB volume_gb=$BM_VOLUME_GB ts_hostname=$BM_TS_HOSTNAME ts_wait_s=$BM_TS_WAIT_S"
    return 0
  fi
  [ -n "$BM_IMAGE" ] || { echo "box-move: BOX_MOVE_IMAGE is not set (the pushed hub image ref)" >&2; exit 2; }

  # preflight: every input before the first Fly call.
  bm_idle_exempt "$BM_APP" "$BM_IDLE_SIGNALS" \
    || bm_refuse "app $BM_APP is not exempt in $BM_IDLE_SIGNALS: bin/fly-idle-reaper.sh would judge it on metrics and can stop it"
  bm_rows_resolve "$old" "$new"
  local flyenv pub
  flyenv="$(harness_env_dir "$HARNESS")/fly.env"
  [ -r "$flyenv" ] || bm_refuse "$flyenv is not readable"
  set -a
  # shellcheck disable=SC1090
  . "$flyenv" || bm_refuse "$flyenv did not source"
  set +a
  [ -n "${FLY_ORG:-}" ] || bm_refuse "FLY_ORG is not set in fly.env"
  [ -n "${FLY_API_TOKEN:-}" ] || bm_refuse "FLY_API_TOKEN is not set in fly.env"
  [ -n "${TS_AUTHKEY_BOX:-}" ] || bm_refuse "TS_AUTHKEY_BOX is not set in fly.env (mint a tagged key for project boxes)"
  pub=$(ls "$BM_SSH_DIR"/id_*.pub 2>/dev/null | head -1)
  [ -n "$pub" ] || bm_refuse "no hub ssh public key in $BM_SSH_DIR"
  export FLY_API_TOKEN FLY_ACCESS_TOKEN="$FLY_API_TOKEN"

  local rc vid mid ip waited
  # 1. app
  hmf_app_exists "$BM_APP"; rc=$?
  case "$rc" in
    0) bm_say "app $BM_APP exists" ;;
    1) bm_say "creating app $BM_APP"; hmf_app_create "$BM_APP" "$FLY_ORG"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; bm_fail "apps create $BM_APP"; } ;;
    75) exit 75 ;;
    *) bm_fail "cannot read the Fly app list; nothing created" ;;
  esac
  bm_tj_set provider fly; bm_tj_set app "$BM_APP"; bm_tj_set region "$BM_REGION"
  bm_tj_set size "$BM_VM_SIZE/${BM_MEM_MB}MB/${BM_VOLUME_GB}GB"; bm_tj_set ts_hostname "$BM_TS_HOSTNAME"
  bm_tj_set old_box "$old"; bm_tj_set old_ip "$BM_OLD_IP"; bm_tj_set box_id "$BM_BOX_ID"

  # 2. volume
  vid=$(hmf_volume_find "$BM_APP" "$BM_VOLUME_NAME"); rc=$?
  case "$rc" in
    0) bm_say "volume $BM_VOLUME_NAME exists ($vid)" ;;
    1) bm_say "creating volume $BM_VOLUME_NAME ${BM_VOLUME_GB} GB in $BM_REGION"
       hmf_volume_create "$BM_APP" "$BM_VOLUME_NAME" "$BM_VOLUME_GB" "$BM_REGION"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; bm_fail "volumes create"; }
       vid=$(hmf_volume_find "$BM_APP" "$BM_VOLUME_NAME") || bm_fail "volume created but not found" ;;
    75) exit 75 ;;
    *) bm_fail "cannot read the volumes of $BM_APP; nothing created" ;;
  esac
  bm_tj_set volume_id "$vid"

  # 3-5. machine (the secrets are staged only for a machine that does not exist yet)
  mid=$(hmf_machine_find "$BM_APP"); rc=$?
  case "$rc" in
    0) bm_say "machine exists ($mid)" ;;
    1) bm_say "staging secrets TS_AUTHKEY, HUB_AUTHORIZED_KEY"
       printf '%s\n' "$TS_AUTHKEY_BOX" | hmf_secret_set_stage "$BM_APP" TS_AUTHKEY; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; bm_fail "secrets import TS_AUTHKEY"; }
       hmf_secret_set_stage "$BM_APP" HUB_AUTHORIZED_KEY < "$pub"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; bm_fail "secrets import HUB_AUTHORIZED_KEY"; }
       bm_say "creating machine $BM_VM_SIZE ${BM_MEM_MB} MB image=$BM_IMAGE"
       hmf_machine_run "$BM_APP" "$BM_IMAGE" "$BM_VM_SIZE" "$BM_MEM_MB" "$vid" "$BM_REGION" "$BM_TS_HOSTNAME"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; bm_fail "machine run"; }
       mid=$(hmf_machine_find "$BM_APP") || bm_fail "machine created but not found" ;;
    75) exit 75 ;;
    *) bm_fail "cannot read the machines of $BM_APP; nothing created" ;;
  esac
  bm_tj_set machine_id "$mid"

  # 6. tailnet
  waited=0
  while :; do
    ip=$(tailscale status --json 2>/dev/null | jq -r --arg h "$BM_TS_HOSTNAME" \
      '[(.Peer // {})[] | select((.HostName // "" | ascii_downcase) == $h) | .TailscaleIPs[]? | select(test(":") | not)][0] // empty' 2>/dev/null)
    [ -n "$ip" ] && break
    [ "$waited" -ge "$BM_TS_WAIT_S" ] && bm_fail "tailnet host $BM_TS_HOSTNAME did not appear in ${BM_TS_WAIT_S}s"
    sleep "$BM_TS_POLL_S"; waited=$((waited + BM_TS_POLL_S))
  done
  bm_tj_set ts_ip "$ip"; bm_tj_set provisioned_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  bm_say "provision: DONE app=$BM_APP machine=$mid volume=$vid ts_ip=$ip box_id=$BM_BOX_ID"
}

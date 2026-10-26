#!/bin/bash
# tests/box-move-provision.bh-8322-test.sh — bin/box-move.sh provision,
# inventory, proof, the knobs, the CLI frame and the reaper exemption (BH-8322).
#
# Cases: P1 provision --plan calls nothing (AT1); P2-P5 an unreadable find or a
# rate limit creates nothing (AT2); P6 happy path and the target.json round
# trip; P7 a re-run creates nothing; P8 the old box must be a known row;
# X1-X6 the idle-exempt rule; K1-K5 knobs, verbs, sandbox guard, lock; I1-I2
# inventory names only and writes nothing; Q1 proof; N1-N2 no cron row and the
# Fly seam rule; B1 no real vendor binary on PATH.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-provision.bh-8322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-fixture.bh-8322.sh" || exit 1
CREATES='apps create|volumes create|machine run|secrets import'

# ==== P: provision ============================================================
bm_newcase p1
out=$(bm provision --plan "$BM_OLD" "$BM_NEW" 2>&1); check P1-rc "$?" 0
check P1-six-actions "$(grep -c '^PLAN provision [1-6]/6:' <<<"$out")" 6
for w in "app $BM_NEW" "volume box_data 100 GB in iad" "TS_AUTHKEY from TS_AUTHKEY_BOX" "HUB_AUTHORIZED_KEY" \
    "--vm-size performance-4x --vm-memory 8192" "tailnet host $BM_NEW"; do has "P1 $w" "$out" "$w"; done
check P1-no-vendor-call "$(wc -l < "$VC")" 0
check P1-no-bin-call "$(wc -l < "$CALLS")" 0
check P1-no-target-json "$( [ -e "$H/state/box-move/$BM_NEW/target.json" ] && echo yes || echo no)" no
check P1-no-lock "$(ls -A "$H/locks" 2>/dev/null | wc -l)" 0

bm_newcase p2; bm_peer_json; touch "$FLYD/fail-list"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P2-app-unreadable-rc "$?" 4
check P2-no-create "$(grep -cE "$CREATES" "$VC")" 0
check P2-no-target-json "$( [ -e "$H/state/box-move/$BM_NEW/target.json" ] && echo yes || echo no)" no
bm_newcase p3; bm_peer_json; echo "$BM_NEW" > "$FLYD/apps"; touch "$FLYD/fail-vol"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P3-volume-unreadable-rc "$?" 4
check P3-no-create "$(grep -cE "$CREATES" "$VC")" 0
bm_newcase p4; bm_peer_json; echo "$BM_NEW" > "$FLYD/apps"
printf '[{"id":"vol_x","name":"box_data"}]' > "$FLYD/volumes.json"; touch "$FLYD/fail-mach"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P4-machine-unreadable-rc "$?" 4
check P4-no-create "$(grep -cE "$CREATES" "$VC")" 0
bm_newcase p4b; bm_peer_json; printf '{}' > "$FLYD/volumes.json"; echo "$BM_NEW" > "$FLYD/apps"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P4b-volume-object-not-array-rc "$?" 4
check P4b-no-create "$(grep -cE "$CREATES" "$VC")" 0
bm_newcase p5; bm_peer_json; touch "$FLYD/ratelimit"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P5-ratelimit-rc "$?" 75
check P5-no-create "$(grep -cE "$CREATES" "$VC")" 0

bm_newcase p6; bm_peer_json
bm provision "$BM_OLD" "$BM_NEW" >"$C/out" 2>&1; check P6-rc "$?" 0
check P6-order "$(grep -oE 'apps create|volumes create|machine run' "$VC" | tr '\n' ',')" "apps create,volumes create,machine run,"
check P6-each-once "$(grep -cE "apps create|volumes create|machine run" "$VC")" 3
has P6-app-org "$(grep 'apps create' "$VC")" "apps create $BM_NEW --org fixture-org"
has P6-size "$(grep 'machine run' "$VC")" "--vm-size performance-4x --vm-memory 8192"
has P6-image "$(grep 'machine run' "$VC")" "registry.example/hub:fixture"
has P6-ts-hostname "$(grep 'machine run' "$VC")" "HUB_TS_HOSTNAME=$BM_NEW"
has P6-volume "$(grep 'volumes create' "$VC")" "volumes create box_data -a $BM_NEW --size 100 -r iad"
check P6-secrets "$(sort "$FLYD/secret-keys" | tr '\n' ' ')" "HUB_AUTHORIZED_KEY TS_AUTHKEY "
hasnt P6-no-secret-in-argv "$(cat "$VC")" tskey-fixture-box
has P6-done "$(cat "$C/out")" "provision: DONE"
TJ="$H/state/box-move/$BM_NEW/target.json"
for kv in "provider=fly" "app=$BM_NEW" "region=iad" "size=performance-4x/8192MB/100GB" "volume_id=vol_fixture1" \
    "machine_id=m_fixture1" "ts_hostname=$BM_NEW" "ts_ip=$BM_NEW_IP" "old_box=$BM_OLD" "old_ip=$BM_OLD_IP" "box_id=project-6-os"; do
  check "P6-tj-${kv%%=*}" "$(jq -r --arg k "${kv%%=*}" '.[$k] // "none"' "$TJ")" "${kv#*=}"
done
check P6-tj-provisioned-at "$(jq -r '.provisioned_at // "" | length > 0' "$TJ")" true
check P6-tj-names-only "$(grep -c 'fixture-org\|tok-fixture\|tskey' "$TJ")" 0
check P6-no-ssh "$(grep -c '^ssh ' "$VC")" 0
: > "$VC"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P7-rerun-rc "$?" 0
check P7-rerun-no-create "$(grep -cE "$CREATES" "$VC")" 0

bm_newcase p8; bm_peer_json
bm provision box-nosuch "$BM_NEW" >/dev/null 2>"$C/err"; check P8-unknown-old-rc "$?" 3
check P8-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
has P8-alert "$(cat "$CALLS")" "hub:alert-line --id box-move-preflight"
bm_newcase p9; bm_peer_json; sed -i '/TS_AUTHKEY_BOX/d' "$H/env/fly.env"
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>"$C/err"; check P9-no-box-authkey-rc "$?" 3
check P9-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
has P9-says "$(cat "$C/err")" "TS_AUTHKEY_BOX"
bm_newcase p10; bm_peer_json; unset BOX_MOVE_IMAGE
bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check P10-no-image-rc "$?" 2
check P10-no-fly-call "$(grep -c '^flyctl' "$VC")" 0

# ==== X: idle-exempt rule (bm_idle_exempt, the reaper's rule) =================
bm_newcase x
CAT="$C/signals.json"
printf '{"apps":{"box-metrics":{"source":"metrics"},"box-exact":{"source":"exempt","reason":"r"}},"prefixes":{"box-":{"source":"exempt","reason":"r"},"pool-":{"source":"pool"}}}\n' > "$CAT"
xr() { ( . "$H/bin/lib/box-move/common.sh" && bm_idle_exempt "$1" "$CAT" ) >/dev/null 2>&1; echo $?; }
check X1-exact-exempt "$(xr box-exact)" 0
check X2-prefix-exempt "$(xr box-mkfly)" 0
check X3-prefix-from-start "$(xr xbox-mkfly)" 1
check X4-shorter-than-prefix "$(xr box)" 1
check X5-other-source "$(xr pool-a1)" 1
check X6-exact-metrics-wins "$(xr box-metrics)" 1
check X7-repo-catalog-exempt "$(jq -e '.prefixes["box-"].source == "exempt" and (.prefixes["box-"].reason | length > 0)' "$REPO/catalog/fly-idle-signals.json" >/dev/null; echo $?)" 0
bm_newcase x8; bm_peer_json
BOX_MOVE_APP=xbox-mkfly bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>"$C/err"; check X8-cli-not-exempt-rc "$?" 3
check X8-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
has X8-says "$(cat "$C/err")" "not exempt"

# ==== K: knobs, verbs, sandbox, lock ==========================================
bm_newcase k1
BOX_MOVE_VOLUME_GB=abc bm provision "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K1-bad-int-rc "$?" 2
BOX_MOVE_APP='Bad App' bm provision --plan "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K1-bad-name-rc "$?" 2
BOX_MOVE_TS_WAIT_S=-1 bm seed "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K1-bad-wait-rc "$?" 2
bm provision --plan "$BM_OLD" 'Bad Box' >/dev/null 2>&1; check K1-bad-box-name-rc "$?" 2
check K1-no-vendor-call "$(wc -l < "$VC")" 0
check K1-no-lock "$(ls -A "$H/locks" 2>/dev/null | wc -l)" 0
bm_newcase k2
out=$(bm provision --plan "$BM_OLD" "$BM_NEW" 2>&1)
for w in "app=$BM_NEW" "region=iad" "vm_size=performance-4x" "mem_mb=8192" "volume_gb=100" "ts_hostname=$BM_NEW" "ts_wait_s=0"; do
  has "K2 default $w" "$out" "$w"
done
bm_newcase k3
for v in frobnicate cutover rollback ""; do
  bm $v "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check "K3-verb-[$v]-rc" "$?" 2
done
bm provision "$BM_OLD" >/dev/null 2>&1; check K3-one-box-rc "$?" 2
bm provision --nope "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K3-bad-flag-rc "$?" 2
usage_out=$(bm 2>&1)
hasnt K3-usage-no-cutover "$usage_out" cutover
hasnt K3-usage-no-rollback "$usage_out" rollback
has K3-usage-tick "$usage_out" "tick <oldbox> <newbox>"
check K3-no-vendor-call "$(wc -l < "$VC")" 0
bm_newcase k4
HARNESS_TEST_SANDBOX=1 HARNESS=/root/harness bm inventory "$BM_OLD" "$BM_NEW" >/dev/null 2>"$C/err"; check K4-sandbox-harness-rc "$?" 2
has K4-sandbox-says "$(cat "$C/err")" "outside the test scratch root"
HARNESS_TEST_SANDBOX=1 BOX_MOVE_TARGET_HARNESS=/root/harness bm seed "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K4-sandbox-target-rc "$?" 2
HARNESS_TEST_SANDBOX=1 BOX_MOVE_OLD_HARNESS=/tmp/elsewhere bm inventory "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K4-sandbox-old-rc "$?" 2
check K4-no-vendor-call "$(wc -l < "$VC")" 0
bm_newcase k5; bm_target_ready
mkdir -p "$H/locks"; exec 8>"$H/locks/box-move-$BM_NEW.lock"; flock -n 8 || bad "K5: cannot take the fixture lock"
out=$(bm seed "$BM_OLD" "$BM_NEW" 2>&1); check K5-held-rc "$?" 0
has K5-held-says "$out" "already running"
check K5-held-no-ssh "$(grep -c '^ssh ' "$VC")" 0
exec 8>&-

# ==== I: inventory, Q: proof ==================================================
bm_newcase i1; bm_target_ready
out=$(bm inventory "$BM_OLD" "$BM_NEW" 2>&1); check I1-rc "$?" 0
hasnt I1-no-marker "$out" "$BM_SECRET"
hasnt I1-no-secret "$out" secret-fixture-value
hasnt I1-no-token "$out" alpha-fixture-token
has I1-key-names "$out" "GH_APP_SECRET"
has I1-key-names-2 "$out" "ALPHA_TOKEN"
has I1-box-id "$out" "box_id=project-6-os"
has I1-ip "$out" "ip=$BM_OLD_IP"
has I1-projects "$out" "projects=alpha-os,beta-os"
has I1-registry "$out" "registry_source=file"
has I1-old-cron "$out" "old_crontab_active=2"
has I1-rendered "$out" "rendered_commands=3"
has I1-backup "$out" "backup_last=20261025T120000Z"
has I1-target "$out" "ts_ip=$BM_NEW_IP"
bm_newcase i2; bm_seeded_target
printf '0.50 2.00 1.00 1/100 1\n' > "$C/loadavg"
export BOX_MOVE_PROC_LOADAVG="$C/loadavg" BOX_MOVE_NPROC=4
mkdir -p "$H/state/box-move/$BM_NEW"
printf '# mode=nowrite at=1\nlane\trc\tsecs\trefused\ttimed_out\n' > "$H/state/box-move/$BM_NEW/tick-20261025T010000Z.tsv"
printf 'tick: lanes=1 ok=1 fail=0 timeout=0 refused_writes=0 mode=nowrite skipped=0 missing=0\n' > "$H/state/box-move/$BM_NEW/tick-20261025T010000Z.summary"
printf 'tick: lanes=4 ok=1 fail=3 timeout=0 refused_writes=3 mode=nowrite skipped=0 missing=0\n' > "$H/state/box-move/$BM_NEW/tick-20261025T020000Z.summary"
touch -d '2026-10-25 01:00' "$H/state/box-move/$BM_NEW/tick-20261025T010000Z.summary"
touch -d '2026-10-25 02:00' "$H/state/box-move/$BM_NEW/tick-20261025T020000Z.summary"
before=$(bm_tree_sum "$H")
bm inventory "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check I2-inventory-rc "$?" 0
out=$(bm proof "$BM_OLD" "$BM_NEW" 2>&1); check Q1-rc "$?" 0
check I2-hub-tree-unchanged "$(bm_tree_sum "$H")" "$before"
check I2-no-fly-call "$(grep -c '^flyctl' "$VC")" 0
check I2-no-lock "$(ls -A "$H/locks" 2>/dev/null | wc -l)" 0
has Q1-load "$out" "load1=0.50 load5=2.00 load15=1.00 nproc=4 load5_per_vcpu=0.50"
has Q1-crontab "$out" "crontab_active=0"
has Q1-all-off "$out" "all_off=on"
has Q1-newest-tick "$out" "refused_writes=3"
hasnt Q1-not-older-tick "$out" "lanes=1 ok=1"
has Q1-projects-old "$out" "$BM_OLD projects=alpha-os,beta-os"
has Q1-projects-new "$out" "$BM_NEW projects=-"
unset BOX_MOVE_PROC_LOADAVG BOX_MOVE_NPROC

# ==== N: no cron row, the Fly seam; B: no real vendor ==========================
check N1-no-cron-row "$(grep -rl 'box-move' "$REPO/cron/" "$REPO/catalog/lanes.d/" 2>/dev/null | wc -l)" 0
BM_SRC=("$REPO/bin/box-move.sh" "$REPO/bin/lib/box-move/common.sh" "$REPO/bin/lib/box-move/provision.sh" "$REPO/bin/lib/box-move/seed.sh")
for f in "${BM_SRC[@]}"; do [ -f "$f" ] && ok || bad "N2: $f missing"; done
check N2-no-flyctl-outside-seam "$(cat "${BM_SRC[@]}" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -cE '(^|[^A-Za-z_-])(flyctl|fly)[[:space:]]')" 0
check N2-no-hmf-redefinition "$(cat "${BM_SRC[@]}" 2>/dev/null | grep -cE '^[[:space:]]*_?hmf_[a-z_]+\(\)')" 0
check N2-sources-the-seam "$(grep -qE '^\. "\$SELF_DIR/lib/hub-move-fly.sh"' "$REPO/bin/box-move.sh" 2>/dev/null && echo yes)" yes
for n in flyctl tailscale ssh scp rsync crontab gh curl wrangler claude codex aws npx; do
  check "B1-$n-is-stub" "$(command -v "$n")" "$STUB/$n"
done

bm_done box-move-provision

#!/bin/bash
# tests/box-move-seed.bh-8322-test.sh — bin/box-move.sh seed and the rows
# rules (BH-8322).
#
# Cases: S1 env goes box to box and no env value reaches the hub (AT3); S2,
# S2b a failed old-side tar stops the seed before state-restore; S3-S5 the BACKUP_S3
# name table; S7 a restored box id that differs from the rows; S8 the happy
# path markers, box-name, repos and swap; S9 state-restore has no --identity;
# S10 a symlinked new env dir; S11 the ts argument; R1-R7 the rows rules.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-seed.bh-8322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-fixture.bh-8322.sh" || exit 1
seed() { bm seed "$BM_OLD" "$BM_NEW" "$@"; }
seeded_marker() { [ -e "$NEW/state/hub-move/target-seeded" ] && echo yes || echo no; }

# ==== S1: env box to box, never through the hub (AT3) =========================
# The case sits in its own TMPDIR ($T/htmp), so a hub-side temp file is inside
# the scanned tree; the sandbox guard needs every path under
# $TMPDIR/scratch.??????/, so the case and a copy of the stubs live there.
S1T="$T/htmp"; mkdir -p "$S1T/scratch.s1case"
bm_newcase htmp/scratch.s1case/s1
cp -a "$STUB" "$S1T/scratch.s1case/stub"; export PATH="$S1T/scratch.s1case/stub:${BM_BASEPATH#"$STUB:"}"
bm_target_ready
old_sum=$(bm_tree_sum "$OLD")
TMPDIR="$S1T" seed >"$C/out" 2>&1; check S1-rc "$?" 0
check S1-new-env-has-value "$(grep -c "GH_APP_SECRET=$BM_SECRET" "$NEW/env/global.env" 2>/dev/null)" 1
check S1-new-env-project-file "$(grep -c 'ALPHA_TOKEN' "$NEW/env/alpha-os.env" 2>/dev/null)" 1
check S1-new-env-mode "$(stat -c %a "$NEW/env/global.env" 2>/dev/null)" 600
check S1-new-env-dir-mode "$(stat -c %a "$NEW/env" 2>/dev/null)" 700
hits=$(grep -rlF "$BM_SECRET" "$S1T" 2>/dev/null | grep -vE "^($OLD|$NEW)/")
check S1-no-value-on-hub "$(printf '%s' "$hits" | grep -c .)" 0
[ -z "$hits" ] || echo "  S1 hits: $hits"
check S1-no-value-in-argv-log "$(grep -cF "$BM_SECRET" "$VC")" 0
check S1-no-value-in-calls "$(grep -cF "$BM_SECRET" "$CALLS")" 0
check S1-no-value-in-output "$(grep -cF "$BM_SECRET" "$C/out")" 0
check S1-no-hub-env-dir "$(ls "$H/env" | tr '\n' ' ')" "fly.env "
check S1-no-scp "$(grep -c '^scp ' "$VC")" 0
check S1-old-box-unchanged "$(bm_tree_sum "$OLD")" "$old_sum"
export PATH="$BM_BASEPATH"

# ==== S2: the old-side tar fails ==============================================
bm_newcase s2; bm_target_ready
BM_FAIL_TAR_CREATE=1 seed >"$C/out" 2>&1; check S2-rc "$?" 4
check S2-no-state-restore "$(grep -c 'new:state-restore' "$CALLS")" 0
check S2-no-bootstrap "$(grep -c 'new:bootstrap-machine' "$CALLS")" 0
check S2-no-marker "$(seeded_marker)" no
has S2-says "$(cat "$C/out")" "env pipe"
# S2b: the old tar writes a whole archive, then exits 2. The new side unpacks
# it with rc 0, so only the old-side rc can stop the seed.
bm_newcase s2b; bm_target_ready
BM_FAIL_TAR_CREATE=late seed >"$C/out" 2>&1; check S2b-rc "$?" 4
has S2b-old-rc-named "$(cat "$C/out")" "old=2 new=0"
check S2b-no-state-restore "$(grep -c 'new:state-restore' "$CALLS")" 0
check S2b-no-marker "$(seeded_marker)" no

# ==== S3-S5: the BACKUP_S3 names on the old box ===============================
s3() { # s3 <case> <want rc> <sed expression on the old global.env> [<extra file> <content>]
  bm_newcase "$1"; bm_target_ready
  sed -i "$3" "$OLD/env/global.env"
  [ -z "${4:-}" ] || printf '%s\n' "$5" > "$OLD/env/$4"
  seed >"$C/out" 2>&1; check "$1-rc" "$?" "$2"
  if [ "$2" = 3 ]; then
    check "$1-no-env-copied" "$( [ -e "$NEW/env/global.env" ] && echo yes || echo no)" no
    check "$1-no-state-restore" "$(grep -c 'new:state-restore' "$CALLS")" 0
    has "$1-alert" "$(cat "$CALLS")" "hub:alert-line --id box-move-preflight"
    check "$1-no-value-in-output" "$(grep -c 'secret-fixture-value\|s3.example' "$C/out")" 0
  fi
}
s3 S3-absent 3 '/^BACKUP_S3_ENDPOINT=/d'
s3 S3b-commented 3 's/^BACKUP_S3_ENDPOINT=/# BACKUP_S3_ENDPOINT=/'
s3 S3c-only-in-bak 3 '/^BACKUP_S3_ENDPOINT=/d' global.env.bak 'BACKUP_S3_ENDPOINT=https://s3.example'
s3 S4-export-form 0 's/^BACKUP_S3_ENDPOINT=/export BACKUP_S3_ENDPOINT=/'
s3 S5-empty-value 3 's/^BACKUP_S3_ENDPOINT=.*/BACKUP_S3_ENDPOINT=/'
s3 S6-other-env-file 0 '/^BACKUP_S3_ENDPOINT=/d' backup.env 'BACKUP_S3_ENDPOINT=https://s3.example'

# ==== S7: the restored box id differs from the rows ===========================
bm_newcase s7; bm_target_ready
RESTORE_BOX_ID=other seed >"$C/out" 2>&1; check S7-rc "$?" 4
has S7-says "$(cat "$C/out")" "box-id is 'other', want 'project-6-os'"
check S7-no-marker "$(seeded_marker)" no
check S7-no-all-off "$( [ -e "$NEW/flags/all-off" ] && echo yes || echo no)" no
check S7-no-bootstrap "$(grep -c 'new:bootstrap-machine' "$CALLS")" 0

# ==== S8 / S9 / R5: the happy path ============================================
bm_newcase s8; bm_target_ready
mkdir -p "$NEW/state" && printf 'pre-seed\n' > "$NEW/state/cursor"
old_flags=$(bm_tree_sum "$OLD/flags"); old_state=$(bm_tree_sum "$OLD/state")
seed >"$C/out" 2>&1; check S8-rc "$?" 0
has S8-done "$(cat "$C/out")" "seed: done (latest) box_id=project-6-os projects=alpha-os,beta-os"
check S8-box-name "$(cat "$NEW/state/box-name")" "$BM_NEW"
check S8-box-id "$(cat "$NEW/state/box-id")" project-6-os
check S8-all-off "$(HARNESS="$NEW" bash "$NEW/bin/jobs-client.sh" flag-has all-off >/dev/null 2>&1; echo $?)" 0
check S8-all-off-local-file "$( [ -e "$NEW/flags/all-off" ] && echo yes || echo no)" yes
check S8-target-seeded "$(seeded_marker)" yes
has S8-box-move-seeded "$(cat "$NEW/state/box-move/seeded" 2>/dev/null)" " $BM_OLD project-6-os"
check S8-bootstrap-each "$(grep -c 'new:bootstrap-machine .* --repos-only' "$CALLS")" 2
has S8-bootstrap-alpha "$(cat "$CALLS")" "new:bootstrap-machine alpha-os --repos-only"
has S8-bootstrap-beta "$(cat "$CALLS")" "new:bootstrap-machine beta-os --repos-only"
check S8-state-swapped "$(cat "$NEW/state/cursor")" snapshot
check S8-builds-copied "$(cat "$NEW/builds/BH-1/RESULT" 2>/dev/null)" snapshot
check S8-orch-swapped "$(cat "$C/torch/orch-state" 2>/dev/null)" snapshot
check S8-old-state-kept "$(cat "$NEW"/tmp/box-move-prev-*/state/cursor 2>/dev/null)" pre-seed
check S8-old-flags-unchanged "$(bm_tree_sum "$OLD/flags")" "$old_flags"
check S8-old-state-unchanged "$(bm_tree_sum "$OLD/state")" "$old_state"
check S8-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
has S8-code-rsync "$(grep '^rsync ' "$VC")" "root@$BM_NEW_IP:$NEW/bin/"
has S9-restore-args "$(grep 'new:state-restore' "$CALLS")" "new:state-restore project-6-os latest --apply --live $NEW/tmp/box-move-fresh-"
has S9-restore-dest "$(grep 'new:state-restore' "$CALLS")" "--dest $NEW/tmp/box-move-restore-"
hasnt S9-no-identity "$(grep 'new:state-restore' "$CALLS")" "--identity"
hasnt R5-not-the-old-box-file "$(grep 'new:state-restore' "$CALLS")" "wrong"

# ==== S10: a symlinked env dir on the new box =================================
bm_newcase s10; bm_target_ready
mkdir -p "$C/elsewhere"; ln -s "$C/elsewhere" "$NEW/env"
seed >"$C/out" 2>&1; check S10-rc "$?" 3
check S10-nothing-copied "$(ls -A "$C/elsewhere" | wc -l)" 0
check S10-no-state-restore "$(grep -c 'new:state-restore' "$CALLS")" 0

# ==== S11: the ts argument ====================================================
bm_newcase s11; bm_target_ready
seed 20261025T120000Z >/dev/null 2>&1; check S11-ts-rc "$?" 0
has S11-ts-passed "$(grep 'new:state-restore' "$CALLS")" "project-6-os 20261025T120000Z --apply"
seed yesterday >/dev/null 2>&1; check S11-bad-ts-rc "$?" 2
bm_newcase s12
seed >/dev/null 2>"$C/err"; check S12-no-target-json-rc "$?" 3
check S12-no-ssh "$(grep -c '^ssh ' "$VC")" 0

# ==== R: the rows rules =======================================================
bm_newcase r1; bm_target_ready
bm seed box-nosuch "$BM_NEW" >/dev/null 2>&1; check R1-unknown-old-rc "$?" 3
check R1-no-ssh "$(grep -c '^ssh ' "$VC")" 0
bm_newcase r2; bm_target_ready; echo '# @boxrole box-noip noip build' >> "$H/fleet.conf"
bm seed box-noip "$BM_NEW" >/dev/null 2>&1; check R2-old-no-ip-rc "$?" 3
check R2-no-ssh "$(grep -c '^ssh ' "$VC")" 0
bm_newcase r3; bm_target_ready
bm seed "$BM_OLD" "$BM_OLD" >/dev/null 2>&1; check R3-same-box-rc "$?" 3
check R3-no-ssh "$(grep -c '^ssh ' "$VC")" 0
bm_newcase r4; bm_target_ready
bm seed "$BM_OLD" box-other >/dev/null 2>&1; check R4-new-runs-a-project-rc "$?" 3
check R4-no-ssh "$(grep -c '^ssh ' "$VC")" 0
bm_newcase r6; bm_target_ready
printf '192.0.2.24 %s\n' "$OLD" >> "$HOSTS"
bm seed box-idle "$BM_NEW" >"$C/out" 2>&1; check R6-idle-box-rc "$?" 0
check R6-no-bootstrap "$(grep -c 'new:bootstrap-machine' "$CALLS")" 0
has R6-box-id "$(grep 'new:state-restore' "$CALLS")" "new:state-restore idle latest"
has R6-done "$(cat "$C/out")" "projects=-"
bm_newcase r7; bm_target_ready
export REGISTRY_SOURCE=db
mkdir -p "$H/state/registry"; echo '{"version":1}' > "$H/state/registry/registry.json"
sed "s/$BM_OLD_IP/192.0.2.31/" "$H/fleet.conf" > "$H/state/registry/fleet.conf"
out=$(bm inventory "$BM_OLD" "$BM_NEW" 2>&1); check R7-rc "$?" 0
has R7-registry-db "$out" "registry_source=db"
has R7-ip-from-cache "$out" "ip=192.0.2.31"
unset REGISTRY_SOURCE

bm_done box-move-seed

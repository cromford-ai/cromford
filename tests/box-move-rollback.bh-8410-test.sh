#!/bin/bash
# tests/box-move-rollback.bh-8410-test.sh — bin/box-move.sh rollback (BH-8410,
# MKF-7 slice C1; parent #8322 acceptance test 5: "rollback restores the old
# fleet.conf rows and the old box cron in one command").
#
# Cases: RB1 B1..B5 then ONE rollback --confirm restores the rows and the old
# crontab byte for byte (AT5); RB2 rollback after B2 only; RB3 no --confirm is
# WOULD RUN; RB4 no saved crontab refuses; RB5 an unreachable new box;
# RB6 a failed move back; RB7 a saved crontab with 0 active lines; RB8 a second
# rollback; RB9 a cutover again after a rollback (B1..B5: B4 patches the retired
# new box row back to its role, since the add route answers 409 on a field
# that differs), with a project that came to the old box between the two runs.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-rollback.bh-8410-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-cutover-fixture.bh-8410.sh" || exit 1
ST() { printf '%s' "$H/state/box-move/$BM_NEW"; }
on_box() { bash "$H/bin/fleet-conf.sh" --projects-on-box "$1" | tr '\n' ' '; }

# ==== RB1: AT5, one command ===================================================
bmc_newcase rb1; bm_target_ready; bmc_tick_table
cp "$OLD/crontab" "$C/orig-crontab"
bmc_through B5
check RB1-cutover-done "$(bmc_status B5)" ok
check RB1-pre-new-projects "$(on_box "$BM_NEW")" "alpha-os beta-os "
rb --confirm >"$C/out" 2>&1; check RB1-rc "$?" 0
check RB1-old-crontab-restored "$(cmp -s "$OLD/crontab" "$C/orig-crontab" && echo same || echo differ)" same
check RB1-old-all-off "$(bmc_flag "$OLD" all-off)" off
check RB1-old-lane-off-update-runners "$(bmc_flag "$OLD" lane-off-update-runners)" off
check RB1-old-projects "$(on_box "$BM_OLD")" "alpha-os beta-os "
check RB1-new-projects "$(on_box "$BM_NEW")" ""
check RB1-new-retired "$(grep -c "^registry set-box-role $BM_NEW retired" "$CALLS")" 1
check RB1-new-crontab-gone "$( [ -e "$NEW/crontab" ] && echo yes || echo no)" no
check RB1-new-all-off "$(bmc_flag "$NEW" all-off)" on
check RB1-steps "$(bmc_steps | tr ' ' '\n' | tail -6 | tr '\n' ' ')" "B1:reset B2:reset B3:reset B4:reset B5:reset rollback:ok "
has RB1-done "$(cat "$C/out")" "Rollback done."
check RB1-no-drain-box "$(grep -c 'drain-box' "$CALLS")" 0
check RB1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
# RB8: a second rollback ends in the same state.
rb --confirm >"$C/out2" 2>&1; check RB8-rerun-rc "$?" 0
check RB8-old-crontab-same "$(cmp -s "$OLD/crontab" "$C/orig-crontab" && echo same || echo differ)" same
check RB8-old-projects "$(on_box "$BM_OLD")" "alpha-os beta-os "
check RB8-new-projects "$(on_box "$BM_NEW")" ""
# After rollback a cutover starts at B1 again: B2 refuses until B1 is ok.
cstep --step B2 --confirm >/dev/null 2>&1; check RB1-gate-reset-rc "$?" 3

# ==== RB2: rollback after B2 only =============================================
bmc_newcase rb2; bm_seeded_target; bmc_tick_table
cp "$OLD/crontab" "$C/orig-crontab"
bmc_through B2
rb --confirm >"$C/out" 2>&1; check RB2-rc "$?" 0
check RB2-old-crontab-restored "$(cmp -s "$OLD/crontab" "$C/orig-crontab" && echo same || echo differ)" same
check RB2-no-registry-call "$(grep -c '^registry' "$CALLS")" 0
check RB2-old-lane-off-update-runners "$(bmc_flag "$OLD" lane-off-update-runners)" off

# ==== RB3: no --confirm =======================================================
bmc_newcase rb3; bm_seeded_target; bmc_tick_table
bmc_through B2
osum=$(bm_tree_sum "$OLD"); nsum=$(bm_tree_sum "$NEW"); : > "$VC"; : > "$CALLS"
out=$(rb 2>&1); check RB3-rc "$?" 0
has RB3-would-run "$out" "WOULD RUN rollback"
has RB3-nothing "$out" "nothing changed: add --confirm to run"
check RB3-old-unchanged "$(bm_tree_sum "$OLD")" "$osum"
check RB3-new-unchanged "$(bm_tree_sum "$NEW")" "$nsum"
check RB3-no-ssh "$(grep -c '^ssh ' "$VC")" 0
check RB3-no-registry-call "$(grep -c '^registry' "$CALLS")" 0

# ==== RB4: B2 never ran =======================================================
bmc_newcase rb4; bm_seeded_target
rb --confirm >/dev/null 2>"$C/err"; check RB4-rc "$?" 3
check RB4-no-ssh "$(grep -c '^ssh ' "$VC")" 0
has RB4-says "$(cat "$C/err")" "old-crontab"
check RB4-old-crontab-untouched "$(bmc_active "$OLD/crontab")" 2

# ==== RB5: the new box is unreachable =========================================
bmc_newcase rb5; bm_target_ready; bmc_tick_table
cp "$OLD/crontab" "$C/orig-crontab"
bmc_through B4
touch "$NEW/.ssh-down"
rb --confirm >"$C/out" 2>&1; check RB5-rc "$?" 4
has RB5-says "$(cat "$C/out")" "--force-drain"
check RB5-rows-not-moved "$(on_box "$BM_NEW")" "alpha-os beta-os "
check RB5-old-crontab-not-installed "$( [ -e "$OLD/crontab" ] && echo yes || echo no)" no
rb --confirm --force-drain >"$C/out" 2>&1; check RB5-forced-rc "$?" 0
check RB5-forced-rows "$(on_box "$BM_OLD")" "alpha-os beta-os "
check RB5-forced-crontab "$(cmp -s "$OLD/crontab" "$C/orig-crontab" && echo same || echo differ)" same

# ==== RB6: the second move back fails =========================================
bmc_newcase rb6; bm_target_ready; bmc_tick_table
cp "$OLD/crontab" "$C/orig-crontab"
bmc_through B4
touch "$C/reg-fail-once-beta-os"
rb --confirm >"$C/out" 2>&1; check RB6-rc "$?" 4
check RB6-old-crontab-not-installed "$( [ -e "$OLD/crontab" ] && echo yes || echo no)" no
check RB6-old-all-off-kept "$(bmc_flag "$OLD" all-off)" on
check RB6-no-rollback-ok "$(bmc_status rollback)" ""
rb --confirm >"$C/out" 2>&1; check RB6-rerun-rc "$?" 0
check RB6-rerun-rows "$(on_box "$BM_OLD")" "alpha-os beta-os "
check RB6-rerun-crontab "$(cmp -s "$OLD/crontab" "$C/orig-crontab" && echo same || echo differ)" same

# ==== RB7: the saved crontab has no active line ===============================
bmc_newcase rb7; bm_seeded_target; bmc_tick_table
bmc_through B2
printf '# only a comment\nPATH=/usr/bin\n' > "$(ST)/old-crontab"
osum=$(bm_tree_sum "$OLD"); : > "$VC"
rb --confirm >/dev/null 2>"$C/err"; check RB7-rc "$?" 3
check RB7-old-unchanged "$(bm_tree_sum "$OLD")" "$osum"
check RB7-no-ssh "$(grep -c '^ssh ' "$VC")" 0

# ==== RB9: a cutover again after a rollback ===================================
bmc_newcase rb9; bm_target_ready; bmc_tick_table
bmc_through B4
rb --confirm >"$C/out" 2>&1; check RB9-rollback-rc "$?" 0
check RB9-new-retired "$(bash "$H/bin/fleet-conf.sh" --boxes-with-roles | awk -F'\t' -v b="$BM_NEW" '$1 == b {print $3}')" retired
# A project lands on the old box between the two cut-overs.
printf 'delta-os o/delta https://delta.example /api/board 8 %s %s\n' "$BM_OLD" "$BM_OLD_IP" >> "$H/fleet.conf"
# The next B3 must see a new snapshot.
sed -i 's/20261026T010203Z/20261026T020304Z/g' "$OLD/bin/state-backup.sh"
: > "$CALLS"
for s in B1 B2 B3 B4; do
  cstep --step "$s" --confirm >"$C/out-r-$s" 2>&1; check "RB9-$s-rc" "$?" 0
done
check RB9-b4-ok "$(bmc_status B4)" ok
check RB9-no-second-add-box "$(grep -c '^registry add-box' "$CALLS")" 0
check RB9-role-patched "$(grep -c "^registry set-box-role $BM_NEW build" "$CALLS")" 1
check RB9-new-role "$(bash "$H/bin/fleet-conf.sh" --boxes-with-roles | awk -F'\t' -v b="$BM_NEW" '$1 == b {print $3}')" build
check RB9-new-projects "$(on_box "$BM_NEW")" "alpha-os beta-os delta-os "
check RB9-old-projects "$(on_box "$BM_OLD")" ""
check RB9-old-rows-refreshed "$(grep -c '^project' "$(ST)/old-rows.tsv")" 3

bm_done box-move-rollback

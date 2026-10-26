#!/bin/bash
# tests/box-move-cutover.bh-8410-test.sh — bin/box-move.sh cutover --step
# B1..B5 and tick --real (BH-8410, MKF-7 slice C1).
#
# Cases: U1-U5 the CLI frame (step names, flag scope, knobs, lock); W1 WOULD
# RUN for each step, nothing written; G1-G3 the previous-step gate; P1-P10 the
# B1 tick judgment (P11 a tick stamped in the future); S1-S5 B2 stop the old
# box; C1-C3 B3 copy; R1-R5 (+R2b) B4 rows, R6 a new box row that exists at
# another address; N1-N6 B5 start the new box and tick --real (N6 a failure
# after update-runners stands the new box down, so a re-run passes the
# split-brain check); B1x no real vendor binary on PATH and no jobs row.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-cutover.bh-8410-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-cutover-fixture.bh-8410.sh" || exit 1
ST() { printf '%s' "$H/state/box-move/$BM_NEW"; }

# ==== U: the CLI frame ========================================================
bmc_newcase u1
cstep >/dev/null 2>&1; check U1-no-step-rc "$?" 2
bm cutover --confirm "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check U1-confirm-no-step-rc "$?" 2
for s in B6 C1 b1 ""; do
  cstep --step "$s" >/dev/null 2>&1; check "U2-step-[$s]-rc" "$?" 2
done
bm tick --confirm "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check U3-confirm-on-tick-rc "$?" 2
bm proof --force-drain "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check U3-force-drain-on-proof-rc "$?" 2
bm rollback --step B1 "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check U3-step-on-rollback-rc "$?" 2
bm cutover --step B1 --plan "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check U3-plan-on-cutover-rc "$?" 2
BOX_MOVE_DRAIN_TIMEOUT_S=0 cstep --step B1 >/dev/null 2>&1; check U4-drain-0-rc "$?" 2
BOX_MOVE_TICK_MAX_AGE_S=x cstep --step B1 >/dev/null 2>&1; check U4-age-x-rc "$?" 2
BOX_MOVE_B1_ALLOW='a b' cstep --step B1 >/dev/null 2>&1; check U4-allow-space-rc "$?" 2
BOX_MOVE_B1_ALLOW='a,b~2' cstep --step B1 >/dev/null 2>&1; check U4-allow-list-ok-rc "$?" 0
check U-no-vendor-call "$(wc -l < "$VC")" 0
bmc_newcase u5; bm_target_ready; bmc_tick_table
mkdir -p "$H/locks"; exec 8>"$H/locks/box-move-$BM_NEW.lock"; flock -n 8 || bad "U5: cannot take the fixture lock"
out=$(cstep --step B1 --confirm 2>&1); check U5-held-rc "$?" 0
has U5-held-says "$out" "already running"
check U5-no-step-row "$( [ -e "$(ST)/steps.tsv" ] && echo yes || echo no)" no
out=$(cstep --step B1 2>&1); check U5-no-confirm-no-lock-rc "$?" 0
has U5-no-confirm-would-run "$out" "WOULD RUN B1"
exec 8>&-

# ==== W: WOULD RUN ============================================================
bmc_newcase w1; bm_seeded_target; bmc_tick_table
hsum=$(bm_tree_sum "$H"); osum=$(bm_tree_sum "$OLD"); nsum=$(bm_tree_sum "$NEW")
for s in B1 B2 B3 B4 B5; do
  out=$(cstep --step "$s" 2>&1); check "W1-$s-rc" "$?" 0
  has "W1-$s-would-run" "$out" "WOULD RUN $s"
  has "W1-$s-nothing" "$out" "nothing changed: add --confirm to run"
done
out=$(cstep --step B2 2>&1); has W1-drain-default "$out" "1800s"
out=$(cstep --step B1 2>&1); has W1-age-default "$out" "86400s"; has W1-allow-default "$out" "BOX_MOVE_B1_ALLOW=none"
check W1-no-vendor-call "$(wc -l < "$VC")" 0
check W1-no-registry-call "$(grep -c '^registry' "$CALLS")" 0
check W1-hub-unchanged "$(bm_tree_sum "$H")" "$hsum"
check W1-old-unchanged "$(bm_tree_sum "$OLD")" "$osum"
check W1-new-unchanged "$(bm_tree_sum "$NEW")" "$nsum"

# ==== G: the previous-step gate ===============================================
bmc_newcase g1; bm_seeded_target
cstep --step B3 --confirm >/dev/null 2>"$C/err"; check G1-rc "$?" 3
check G1-no-ssh "$(grep -c '^ssh ' "$VC")" 0
check G1-one-alert "$(grep -c 'hub:alert-line --id box-move-preflight' "$CALLS")" 1
has G1-says "$(cat "$C/err")" "step B2 is not ok"
check G1-no-row "$( [ -e "$(ST)/steps.tsv" ] && echo yes || echo no)" no
bmc_newcase g2; bm_seeded_target; mkdir -p "$(ST)"
printf '2026-10-26T00:00:00Z\tB1\tok\tx\n2026-10-26T00:00:01Z\tB2\tfail\tdrain timeout\n' > "$(ST)/steps.tsv"
cstep --step B3 --confirm >/dev/null 2>&1; check G2-prev-fail-rc "$?" 3
check G2-no-ssh "$(grep -c '^ssh ' "$VC")" 0
bmc_newcase g3; bm_seeded_target; mkdir -p "$(ST)"
printf '2026-10-26T00:00:00Z\tB1\tok\tx\n2026-10-26T00:00:01Z\tB2\tok\tx\n2026-10-26T00:00:02Z\tB2\treset\trollback\n' > "$(ST)/steps.tsv"
cstep --step B3 --confirm >/dev/null 2>&1; check G3-last-row-wins-rc "$?" 3
check G3-no-ssh "$(grep -c '^ssh ' "$VC")" 0

# ==== P: B1 judges the newest no-write tick ===================================
# p_case <name> <want rc> [<tick line1>] [<rows>] [<BOX_MOVE_B1_ALLOW>] — one
# B1 run on a fresh case.
p_case() {
  local n="$1" want="$2"
  bmc_newcase "$n"; bm_target_ready
  bmc_tick_table "${3:-}" "${4:-}"
  BOX_MOVE_B1_ALLOW="${5:-}" cstep --step B1 --confirm >"$C/out" 2>&1; check "$n-rc" "$?" "$want"
  if [ "$want" = 0 ]; then check "$n-row" "$(bmc_status B1)" ok; else check "$n-row" "$(bmc_status B1)" fail; fi
  check "$n-no-ssh" "$(grep -c '^ssh ' "$VC")" 0
}
p_case P1 0
p_case P2 0 "" 'lib\t1\t2\t1\t0\n'
p_case P3 0 "" 'slow\t124\t300\t0\t1\n'
p_case P4 0 "" 'lib~2\t1\t2\t0\t0\n' lib
p_case P5 4 "" 'lib\t1\t2\t0\t0\n'
has P5-names-lane "$(cat "$C/out")" "lib(rc=1)"
p_case P11 4 "# mode=nowrite at=$((HUB_MOVE_NOW + 3600))"
has P11-says "$(cat "$C/out")" "stamped in the future"
p_case P6 4 "" 'lib\t1\t2\t0\t0\n' li
p_case P7 4 "# mode=real at=$HUB_MOVE_NOW"
has P7-says "$(cat "$C/out")" "not a no-write tick"
p_case P8a 4 "# mode=nowrite-crontab-found at=$HUB_MOVE_NOW"
p_case P8b 4 "# mode=nowrite-reach-failed at=$HUB_MOVE_NOW"
p_case P9a 4 "# mode=nowrite at=$((HUB_MOVE_NOW - 86401))"
p_case P9b 0 "# mode=nowrite at=$((HUB_MOVE_NOW - 86399))"
bmc_newcase P10; bm_target_ready
cstep --step B1 --confirm >"$C/out" 2>&1; check P10-no-table-rc "$?" 4
check P10-row "$(bmc_status B1)" fail
bmc_newcase P10b; bm_target_ready
bmc_tick_table "" "" tick-20261025T000000Z.tsv
bmc_tick_table "" 'lib\t1\t2\t0\t0\n' tick-20261026T000000Z.tsv
cstep --step B1 --confirm >/dev/null 2>&1; check P10b-newest-wins-rc "$?" 4
bmc_newcase P10c; bmc_tick_table
mkdir -p "$(ST)"; printf '{"ts_ip":"%s","box_id":"other"}\n' "$BM_NEW_IP" > "$(ST)/target.json"
cstep --step B1 --confirm >"$C/out" 2>&1; check P10c-box-id-mismatch-rc "$?" 4
has P10c-says "$(cat "$C/out")" "box_id"
bmc_newcase P10d; bmc_tick_table "" ""
cstep --step B1 --confirm >/dev/null 2>&1; check P10d-no-target-rc "$?" 4

# ==== S: B2 stop the old box ==================================================
bmc_newcase s1; bm_seeded_target; bmc_tick_table
orig_cron=$(cat "$OLD/crontab")
bmc_through B2
check S1-b2-ok "$(bmc_status B2)" ok
check S1-old-crontab-saved "$(cat "$(ST)/old-crontab" 2>/dev/null)" "$orig_cron"
check S1-rows-box "$(grep '^box' "$(ST)/old-rows.tsv" 2>/dev/null)" "$(printf 'box\t%s\tmkos\t%s\tbuild' "$BM_OLD" "$BM_OLD_IP")"
check S1-rows-projects "$(grep '^project' "$(ST)/old-rows.tsv" | cut -f2 | tr '\n' ' ')" "alpha-os beta-os "
check S1-old-crontab-gone "$( [ -e "$OLD/crontab" ] && echo yes || echo no)" no
check S1-lane-off-update-runners "$(bmc_flag "$OLD" lane-off-update-runners)" on
check S1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
check S5-no-registry-call "$(grep -c '^registry' "$CALLS")" 0
# S2: a re-run after crontab -r keeps the saved crontab.
cstep --step B2 --confirm >/dev/null 2>&1; check S2-rerun-rc "$?" 0
check S2-old-crontab-kept "$(bmc_active "$(ST)/old-crontab")" 2
check S2-rows-kept "$(grep -c '^project' "$(ST)/old-rows.tsv")" 2

bmc_newcase s3; bm_seeded_target; bmc_tick_table
mkdir -p "$OLD/bin"; printf '#!/bin/bash\nsleep 30\n' > "$OLD/bin/x.sh"; chmod +x "$OLD/bin/x.sh"
"$OLD/bin/x.sh" & XPID=$!
cstep --step B1 --confirm >/dev/null 2>&1
BOX_MOVE_DRAIN_TIMEOUT_S=1 cstep --step B2 --confirm >"$C/out" 2>&1; check S3-drain-timeout-rc "$?" 4
check S3-row "$(bmc_status B2)" fail
BOX_MOVE_DRAIN_TIMEOUT_S=1 cstep --step B2 --confirm --force-drain >"$C/out" 2>&1; check S3-forced-rc "$?" 0
check S3-forced-row "$(bmc_status B2)" ok
has S3-forced-detail "$(tail -1 "$(ST)/steps.tsv")" "(forced)"
kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null

bmc_newcase s4; bm_seeded_target; bmc_tick_table
cstep --step B1 --confirm >/dev/null 2>&1
touch "$OLD/.ssh-down"
cstep --step B2 --confirm >"$C/out" 2>&1; check S4-unreachable-rc "$?" 4
check S4-row "$(bmc_status B2)" fail
check S4-no-old-crontab "$( [ -s "$(ST)/old-crontab" ] && echo yes || echo no)" no
check S4-old-crontab-kept-on-box "$(bmc_active "$OLD/crontab")" 2

# ==== C: B3 copy ==============================================================
bmc_newcase c1; bm_target_ready; bmc_tick_table
bmc_through B3
check C1-b3-ok "$(bmc_status B3)" ok
has C1-forced-backup "$(cat "$CALLS")" "old:state-backup BACKUP_FORCE=1"
has C1-seed-new-ts "$(grep 'new:state-restore' "$CALLS")" "project-6-os 20261026T010203Z --apply"
check C1-old-all-off "$(bmc_flag "$OLD" all-off)" on
check C1-new-all-off "$(bmc_flag "$NEW" all-off)" on
has C1-detail-ts "$(tail -1 "$(ST)/steps.tsv")" "20261026T010203Z"
check C1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0

bmc_newcase c2; bm_target_ready; bmc_tick_table; touch "$C/backup-stuck"
bmc_through B2
cstep --step B3 --confirm >"$C/out" 2>&1; check C2-no-new-backup-rc "$?" 4
check C2-row "$(bmc_status B3)" fail
check C2-no-restore "$(grep -c 'new:state-restore' "$CALLS")" 0
check C2-no-old-all-off "$(bmc_flag "$OLD" all-off)" off

bmc_newcase c3; bm_target_ready; bmc_tick_table
bmc_through B2
RESTORE_BOX_ID=wrong cstep --step B3 --confirm >"$C/out" 2>&1; check C3-seed-fails-rc "$?" 4
check C3-row "$(bmc_status B3)" fail
check C3-no-old-all-off "$(bmc_flag "$OLD" all-off)" off

# ==== R: B4 rows ==============================================================
bmc_newcase r1; bm_target_ready; bmc_tick_table
gs0=$(git -C "$REPO" status --porcelain)
bmc_through B4
check R1-b4-ok "$(bmc_status B4)" ok
check R1-add-box-once "$(grep -c "^registry add-box $BM_NEW --ip $BM_NEW_IP --like project-6-os --id project-6-os --role build --actor box-move-$BM_NEW" "$CALLS")" 1
check R1-move-alpha "$(grep -c "^registry move-project alpha-os --box $BM_NEW" "$CALLS")" 1
check R1-move-beta "$(grep -c "^registry move-project beta-os --box $BM_NEW" "$CALLS")" 1
check R1-new-projects "$(bash "$H/bin/fleet-conf.sh" --projects-on-box "$BM_NEW" | tr '\n' ' ')" "alpha-os beta-os "
check R1-old-projects "$(bash "$H/bin/fleet-conf.sh" --projects-on-box "$BM_OLD" | tr '\n' ' ')" ""
check R1-gamma-stays "$(bash "$H/bin/fleet-conf.sh" --projects-on-box box-other | tr '\n' ' ')" "gamma-os "
check R1-new-ip "$(bash "$H/bin/fleet-conf.sh" --tailnet-ip-of-box "$BM_NEW")" "$BM_NEW_IP"
check R1-repo-unchanged "$(git -C "$REPO" status --porcelain)" "$gs0"
check R5-no-drain-box-call "$(grep -c 'drain-box' "$CALLS")" 0
check R5-no-drain-box-code "$(grep -n 'drain-box' "$REPO/bin/box-move.sh" "$REPO/bin/lib/box-move/cutover.sh" "$REPO"/bin/lib/box-move/*.sh | grep -cv ':[[:space:]]*#')" 0
check R1-no-curl "$(grep -c '^curl ' "$VC")" 0

bmc_newcase r2; bm_target_ready; bmc_tick_table
bmc_through B3
: > "$CALLS"
REGISTRY_SOURCE=file cstep --step B4 --confirm >/dev/null 2>"$C/err"; check R2-file-mode-rc "$?" 3
has R2-says "$(cat "$C/err")" "box-register.sh"
check R2-no-registry-call "$(grep -c '^registry' "$CALLS")" 0
check R2-no-row "$(bmc_status B4)" ""
REGISTRY_SOURCE=DB cstep --step B4 --confirm >/dev/null 2>&1; check R2b-upper-db-rc "$?" 3
env -u REGISTRY_SOURCE bash "$H/bin/box-move.sh" cutover --step B4 --confirm "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check R2b-unset-rc "$?" 3
check R2b-no-registry-call "$(grep -c '^registry' "$CALLS")" 0
REGISTRY_ADMIN_TOKEN= cstep --step B4 --confirm >/dev/null 2>"$C/err"; check R3-no-token-rc "$?" 3
has R3-names-var "$(cat "$C/err")" "REGISTRY_ADMIN_TOKEN"
hasnt R3-no-token-value "$(cat "$C/err")" "$BMC_ADMIN_TOKEN"
HARNESS_SECRET= cstep --step B4 --confirm >/dev/null 2>&1; check R3-no-secret-rc "$?" 3
check R3-no-registry-call "$(grep -c '^registry' "$CALLS")" 0

bmc_newcase r4; bm_target_ready; bmc_tick_table
bmc_through B3
touch "$C/reg-fail-once-beta-os"
cstep --step B4 --confirm >"$C/out" 2>&1; check R4-second-move-fails-rc "$?" 4
check R4-row "$(bmc_status B4)" fail
check R4-alpha-moved "$(bash "$H/bin/fleet-conf.sh" --projects-on-box "$BM_NEW" | tr '\n' ' ')" "alpha-os "
: > "$CALLS"
cstep --step B4 --confirm >"$C/out" 2>&1; check R4-rerun-rc "$?" 0
check R4-rerun-row "$(bmc_status B4)" ok
check R4-rerun-moves-beta-only "$(grep '^registry move-project' "$CALLS" | awk '{print $3}' | tr '\n' ' ')" "beta-os "

# R6: the new box row exists at another address (the box was provisioned
# again): B4 stops before any write, and names the fix.
bmc_newcase r6; bm_target_ready; bmc_tick_table
bmc_through B3
printf '# @box %s 192.0.2.99\n# @boxrole %s project-6-os build\n' "$BM_NEW" "$BM_NEW" >> "$H/fleet.conf"
: > "$CALLS"
cstep --step B4 --confirm >"$C/out" 2>&1; check R6-ip-mismatch-rc "$?" 4
check R6-row "$(bmc_status B4)" fail
has R6-says "$(cat "$C/out")" "192.0.2.99"
check R6-no-registry-write "$(grep -c '^registry' "$CALLS")" 0
check R6-projects-stay "$(bash "$H/bin/fleet-conf.sh" --projects-on-box "$BM_OLD" | tr '\n' ' ')" "alpha-os beta-os "

# ==== N: B5 start the new box, tick --real ====================================
bmc_newcase n1; bm_target_ready; bmc_tick_table
bmc_through B5
check N1-b5-ok "$(bmc_status B5)" ok
has N1-done-line "$(cat "$C/out-B5")" "cutover: B5 done"
real_tbl=$(ls "$NEW"/state/hub-move/tick-*.tsv 2>/dev/null | sort | tail -1)
check N1-tick-real "$(head -1 "$real_tbl" 2>/dev/null | cut -d' ' -f2)" "mode=real"
check N1-marker-gone "$( [ -e "$NEW/state/hub-move/target-seeded" ] && echo yes || echo no)" no
check N1-update-runners-once "$(grep -c '^new:update-runners' "$CALLS")" 1
check N1-update-runners-after-marker "$(grep '^new:update-runners' "$CALLS")" "new:update-runners marker=absent"
check N1-new-crontab "$(bmc_active "$NEW/crontab")" 3
check N1-new-all-off "$(bmc_flag "$NEW" all-off)" off
check N1-old-all-off "$(bmc_flag "$OLD" all-off)" on
check N1-old-crontab-empty "$( [ -e "$OLD/crontab" ] && echo yes || echo no)" no
check N1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
# N5: tick --real on the command line after B4 stays refused.
: > "$VC"
bm tick --real "$BM_OLD" "$BM_NEW" >"$C/out" 2>&1; check N5-cli-tick-real-rc "$?" 2
has N5-says "$(cat "$C/out")" "tick --real runs only inside cutover --step B5"
check N5-no-ssh "$(grep -c '^ssh ' "$VC")" 0

bmc_newcase n2; bm_target_ready; bmc_tick_table
bmc_through B4
printf '* * * * * /root/harness/bin/a.sh\n' > "$OLD/crontab"
cstep --step B5 --confirm >"$C/out" 2>&1; check N2-old-crontab-rc "$?" 4
check N2-row "$(bmc_status B5)" fail
check N2-new-all-off-kept "$(bmc_flag "$NEW" all-off)" on
check N2-no-tick "$(ls "$NEW"/state/hub-move/tick-*.tsv 2>/dev/null | wc -l)" 0
check N2-no-update-runners "$(grep -c '^new:update-runners' "$CALLS")" 0
bmc_newcase n2b; bm_target_ready; bmc_tick_table
bmc_through B4
rm -f "$OLD/flags/all-off"
cstep --step B5 --confirm >/dev/null 2>&1; check N2b-old-all-off-off-rc "$?" 4
check N2b-no-tick "$(ls "$NEW"/state/hub-move/tick-*.tsv 2>/dev/null | wc -l)" 0

bmc_newcase n3; bm_target_ready; bmc_tick_table
bmc_through B4
rm -f "$NEW/flags/all-off"
cstep --step B5 --confirm >/dev/null 2>&1; check N3-new-all-off-missing-rc "$?" 4
check N3-no-tick "$(ls "$NEW"/state/hub-move/tick-*.tsv 2>/dev/null | wc -l)" 0

bmc_newcase n4; bm_target_ready; bmc_tick_table
bmc_through B4
printf '#!/bin/bash\n[ "$1" = drain ] && exit 0\necho "hub-move: failed: fixture tick failure" >&2\nexit 4\n' > "$NEW/bin/hub-move.sh"
cstep --step B5 --confirm >"$C/out" 2>&1; check N4-tick-fails-rc "$?" 4
check N4-row "$(bmc_status B5)" fail
has N4-says "$(cat "$C/out")" "fixture tick failure"
check N4-marker-kept "$( [ -e "$NEW/state/hub-move/target-seeded" ] && echo yes || echo no)" yes
check N4-no-update-runners "$(grep -c '^new:update-runners' "$CALLS")" 0
check N4-new-all-off-rearmed "$(bmc_flag "$NEW" all-off)" on

# N6: update-runners fails after all-off is cleared: the new box stands down
# again (all-off on, crontab removed), so a B5 re-run passes the split-brain check.
bmc_newcase n6; bm_target_ready; bmc_tick_table
bmc_through B4
cp "$NEW/bin/update-runners.sh" "$C/update-runners.good"
printf '#!/bin/bash\nt=$(mktemp); printf "* * * * * /root/harness/bin/a.sh\\n" > "$t"; crontab "$t"; rm -f "$t"; exit 3\n' > "$NEW/bin/update-runners.sh"
cstep --step B5 --confirm >"$C/out" 2>&1; check N6-update-runners-fails-rc "$?" 4
check N6-row "$(bmc_status B5)" fail
check N6-new-all-off-rearmed "$(bmc_flag "$NEW" all-off)" on
check N6-new-crontab-removed "$( [ -e "$NEW/crontab" ] && echo yes || echo no)" no
cp "$C/update-runners.good" "$NEW/bin/update-runners.sh"
cstep --step B5 --confirm >"$C/out" 2>&1; check N6-rerun-rc "$?" 0
check N6-rerun-row "$(bmc_status B5)" ok
check N6-rerun-new-all-off "$(bmc_flag "$NEW" all-off)" off

# ==== B1x: no real vendor =====================================================
for n in flyctl tailscale ssh rsync crontab gh curl wrangler claude codex aws npx; do
  case "$(command -v "$n")" in "$STUB/"*) ok ;; *) bad "B1x: $n resolves to $(command -v "$n"), not the stub" ;; esac
done

bm_done box-move-cutover

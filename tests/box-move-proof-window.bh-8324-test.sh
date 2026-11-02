#!/bin/bash
# tests/box-move-proof-window.bh-8324-test.sh — `bin/box-move.sh proof`
# compares the 24 h after the cut-over with the 24 h before (BH-8324, MKF-9),
# and rollback records its own time.
#
# Cases: W1-W6 the windows from steps.tsv; C1-C10 the lane counters and their
# NA rules; S1-S3 lane-silent alerts; V1-V5 the verdict rule; D1 the rollback
# drill budget; R1 rollback writes elapsed_s and proof reads it back; E1 the
# CLI is read-only; K1-K2 the knobs; B1 every vendor binary is a stub; N1 no
# destructive call in the lib. Every case runs `bin/box-move.sh proof` (the
# real CLI) in its own scratch tree.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-proof-window.bh-8324-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-proof-fixture.bh-8324.sh" || exit 1
ST() { printf '%s' "$H/state/box-move/$BM_NEW"; }
BS=$(( BMP_E2 - BMP_W ))   # before window start
SEARCH0='{"total_count":0,"incomplete_results":false,"items":[]}'

# ==== W: the windows ==========================================================
bmp_newcase w1; rm -f "$(ST)/steps.tsv"; : > "$VC"
out=$(pf 2>&1); check W1-rc "$?" 0
has W1-none "$out" "window: none (no steps.tsv)"
has W1-verdict "$out" "proof verdict=NA"
hasnt W1-no-count "$out" "count "
check W1-no-gh "$(grep -c '^gh ' "$VC")" 0
check W1-no-curl "$(grep -c '^curl ' "$VC")" 0
check W1-one-ssh "$(grep -c '^ssh ' "$VC")" 1
has W1-old-lines-stay "$out" "load1=0.50 load5=2.00 load15=1.00 nproc=4"

bmp_newcase w2
for s in B1 B2 B3 B4 B5; do bmp_step $(( BMP_E5 + 900 )) "$s" reset rollback; done
bmp_step $(( BMP_E5 + 900 )) rollback ok "old crontab 2 lines elapsed_s=300"
: > "$VC"; out=$(pf 2>&1); check W2-rc "$?" 0
has W2-none "$out" "window: none (the last B5 row is reset, not ok)"
has W2-drill "$out" "rollback_drill elapsed_s=300 budget_s=900 verdict=pass"
check W2-no-gh "$(grep -c '^gh ' "$VC")" 0

bmp_newcase w3
out=$(pf 2>&1); check W3-rc "$?" 0
has W3-bounds "$out" "window before=2026-10-26T00:00:00Z..2026-10-27T00:00:00Z after=2026-10-27T00:10:00Z..2026-10-28T00:10:00Z width_s=86400 after_state=complete"
# W4: steps.tsv holds the drill cut-over too; the bounds use the LAST B2/B5 ok.
hasnt W4-not-drill-b2 "$out" "..$(bmp_iso $(( BMP_E2 - 9000 )))"
hasnt W4-not-drill-b5 "$out" "after=$(bmp_iso $(( BMP_E2 - 9000 )))"

bmp_newcase w5; export HUB_MOVE_NOW=$(( BMP_E5 + BMP_W - 1 ))
out=$(pf 2>&1); check W5-rc "$?" 0
has W5-partial "$out" "after_state=partial"
check W5-no-verdict "$(grep '^count ' <<<"$out" | grep -c 'verdict=pass\|verdict=fail')" 0
check W5-all-na "$(grep -c '^count .* verdict=NA' <<<"$out")" 12
has W5-marked "$out" "count alpha-os triage_ticks before=0 after=0(partial) verdict=NA"
has W5-proof-na "$out" "proof verdict=NA"
export HUB_MOVE_NOW=$(( BMP_E5 + BMP_W ))
out=$(pf 2>&1)
has W5-edge-complete "$out" "after_state=complete"

bmp_newcase w6; export BOX_MOVE_PROOF_WINDOW_S=3600
bmp_search o/alpha $(( BMP_E2 - 3600 )) "$BMP_E2" "$SEARCH0"; bmp_search o/alpha "$BMP_E5" $(( BMP_E5 + 3600 )) "$SEARCH0"
out=$(pf 2>&1); check W6-rc "$?" 0
has W6-bounds "$out" "window before=2026-10-26T23:00:00Z..2026-10-27T00:00:00Z after=2026-10-27T00:10:00Z..2026-10-27T01:10:00Z width_s=3600"
unset BOX_MOVE_PROOF_WINDOW_S

# ==== C: the counters =========================================================
bmp_newcase c1
bmp_triage "$OLD" alpha-os $(( BMP_E2 - 5000 )) 5
bmp_triage "$NEW" alpha-os $(( BMP_E5 + 5000 )) 4
out=$(pf 2>&1); check C1-rc "$?" 0
has C1-triage "$out" "count alpha-os triage_ticks before=5 after=4 verdict=pass"
has C1-other-project "$out" "count beta-os triage_ticks before=0 after=0 verdict=pass"

bmp_newcase c2
L="$OLD/logs/alpha-os.log"
bmp_log "$L" "$BS" "[alpha-os] rc=0 :: at the window start (in)"
bmp_log "$L" $(( BMP_E2 - 100 )) "[alpha-os] rc=75 :: tickets=1"
bmp_log "$L" $(( BMP_E2 - 50 )) "[alpha-os] rc=0 :: tickets=2"
bmp_log "$L" $(( BS - 1 )) "[alpha-os] rc=0 :: one second before the window (out)"
bmp_log "$L" "$BMP_E2" "[alpha-os] rc=0 :: at the window end (out)"
bmp_log "$L" $(( BMP_E2 - 40 )) "[alpha-os] paused via console, skipping"
bmp_log "$L" $(( BMP_E2 - 30 )) "[alpha-os2] rc=0 :: another project"
bmp_log "$L" $(( BMP_E2 - 20 )) "[beta-os] rc=0 :: another project"
bmp_log "$L" $(( BMP_E2 - 10 )) "[pool/alpha-os] rc=0 :: another tag"
bmp_log "$L" $(( BMP_E2 - 5 )) "[pool/alpha-os] m_fx: the tag later in the line [alpha-os] rc=0"
out=$(pf 2>&1)
has C2-triage "$out" "count alpha-os triage_ticks before=3 after=0 verdict=fail"

bmp_newcase c3
L="$H/logs/fly-pool.log"
bmp_log "$L" $(( BMP_E2 - 900 )) "[pool/alpha-os] m_fx1: launch→first push 40s (warmup wait 300s)"
bmp_log "$L" $(( BMP_E2 - 800 )) "[pool/alpha-os] m_fx2: launch→first push 41s (warmup wait 300s)"
for i in 1 2 3; do bmp_log "$L" $(( BMP_E5 + 100 * i )) "[pool/alpha-os] m_fa$i: launch→first push 4${i}s (warmup wait 300s)"; done
bmp_log "$L" $(( BMP_E5 + 500 )) "[pool/beta-os] m_fb1: launch→first push 30s (warmup wait 300s)"
bmp_log "$L" $(( BMP_E5 + 600 )) "[pool/alpha-os] spawned m_fa9 for BH-1"
bmp_log "$L" $(( BMP_E5 + 700 )) "[pool/alpha-os2] m_fz: launch→first push 30s (warmup wait 300s)"
out=$(pf 2>&1)
has C3-spawns "$out" "count alpha-os pool_spawns before=2 after=3 verdict=pass"
has C3-other "$out" "count beta-os pool_spawns before=0 after=1 verdict=pass"

bmp_newcase c4
L="$H/logs/fly-pool.log"
bmp_log "$L" $(( BMP_E2 - 900 )) "[pool/alpha-os] pool lead review reaped for LR-11-fx from m_fx1: LEAD_REVIEWED APPROVE — the machine posted its own result"
bmp_log "$L" $(( BMP_E5 + 100 )) "[pool/alpha-os] pool lead review reaped for LR-12-fx from m_fx2: LEAD_REVIEWED APPROVE — the machine posted its own result"
bmp_log "$L" $(( BMP_E5 + 200 )) "[pool/alpha-os] leadreview LR-1-abc: RESULT/key mismatch"
bmp_log "$L" $(( BMP_E5 + 300 )) "[pool/alpha-os] pool rereview RESULT reaped for RR-3-fx from m_fx3: done — job file written"
out=$(pf 2>&1)
has C4-lead "$out" "count alpha-os lead_reviews before=1 after=1 verdict=pass"

bmp_newcase c5
bmp_fr_rows alpha-os done $(( BMP_E5 + 100 )) $(( BMP_E5 + 200 )) $(( BS - 500 ))
bmp_fr_rows alpha-os adopted $(( BMP_E2 - 100 ))
out=$(pf 2>&1)
has C5-fix "$out" "count alpha-os fix_rounds before=1 after=2 verdict=pass"
has C5-calls "$(cat "$VC")" "/api/fix-rounds?project=alpha-os&status=done&limit=500"
bmp_fr alpha-os done '{"fix_round_jobs":[],"truncated":true}'
out=$(pf 2>&1)
has C5-truncated "$out" "count alpha-os fix_rounds before=NA(truncated) after=NA(truncated) verdict=NA"
rm -f "$C/fr-alpha-os-adopted.json"; bmp_fr_rows alpha-os done
out=$(pf 2>&1)
has C5-worker-down "$out" "count alpha-os fix_rounds before=NA(worker rc=1) after=NA(worker rc=1) verdict=NA"
check C5-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0

bmp_newcase c6
bmp_search o/alpha $(bmp_after) '{"total_count":3,"incomplete_results":false,"items":[{"number":11},{"number":12},{"number":13}]}'
bmp_gh "repos/o/alpha/pulls/11 " '{"number":11,"merged_by":{"login":"mergify[bot]"}}'
bmp_gh "repos/o/alpha/pulls/12 " '{"number":12,"merged_by":{"login":"mergify[bot]"}}'
bmp_gh "repos/o/alpha/pulls/13 " '{"number":13,"merged_by":{"login":"fixture-user"}}'
bmp_search o/alpha $(bmp_before) '{"total_count":2,"incomplete_results":false,"items":[{"number":9},{"number":10}]}'
bmp_gh "repos/o/alpha/pulls/9 " '{"number":9,"merged_by":{"login":"mergify[bot]"}}'
bmp_gh "repos/o/alpha/pulls/10 " '{"number":10,"merged_by":{"login":"mergify[bot]"}}'
out=$(pf 2>&1)
has C6-merges "$out" "count alpha-os merges before=2 after=3 verdict=pass mergify_before=2 mergify_after=2"
check C6-no-graphql "$(grep -c '^gh pr \|graphql' "$VC")" 0
bmp_search o/alpha $(bmp_before) FAIL1
out=$(pf 2>&1)
has C6-gh-fail "$out" "count alpha-os merges before=NA(gh rc=1) after=3 verdict=NA"
bmp_search o/alpha $(bmp_before) '{"total_count":150,"incomplete_results":false,"items":[{"number":9}]}'
out=$(pf 2>&1)
has C6-page "$out" "count alpha-os merges before=150 after=3 verdict=fail mergify_before=NA(truncated) mergify_after=2"
bmp_search o/alpha $(bmp_before) '{"total_count":2,"incomplete_results":true,"items":[]}'
out=$(pf 2>&1)
has C6-incomplete "$out" "count alpha-os merges before=NA(incomplete)"

bmp_newcase c7
L="$H/logs/fly-pool.log"
: > "$L"; bmp_log "$L" $(( BMP_E5 + 50 )) "[pool/alpha-os] tick start"
bmp_log "$L.1" $(( BS - 3600 )) "[pool/alpha-os] tick start"
bmp_log "$L.1" $(( BMP_E2 - 900 )) "[pool/alpha-os] m_fx1: launch→first push 40s (warmup wait 300s)"
bmp_log "$L.1" $(( BMP_E2 - 800 )) "[pool/alpha-os] m_fx2: launch→first push 41s (warmup wait 300s)"
bmp_log "$C/lr" $(( BMP_E2 - 700 )) "[pool/alpha-os] pool lead review reaped for LR-11-fx from m_fx1: LEAD_REVIEWED APPROVE"
gzip -c "$C/lr" > "$L.2.gz"
out=$(pf 2>&1)
has C7-rotated "$out" "count alpha-os pool_spawns before=2 after=0 verdict=fail"
has C7-gz "$out" "count alpha-os lead_reviews before=1 after=0 verdict=pass"

bmp_newcase c8
L="$H/logs/fly-pool.log"
: > "$L"; bmp_log "$L" $(( BMP_E2 - 3600 )) "[pool/alpha-os] tick start"
out=$(pf 2>&1)
has C8-partial "$out" "count alpha-os pool_spawns before=NA(partial oldest=2026-10-26T23:00:00Z) after=0 verdict=NA"

bmp_newcase c9
sed -i "/^$BM_OLD_IP /d" "$HOSTS"
out=$(pf 2>&1); check C9-rc "$?" 0
has C9-unreachable "$out" "count alpha-os triage_ticks before=NA(old box unreachable) after=0 verdict=NA"
has C9-proof "$out" "proof verdict=NA"

bmp_newcase c10
rm -f "$NEW/logs/alpha-os.log"
out=$(pf 2>&1)
has C10-missing "$out" "count alpha-os triage_ticks before=0 after=NA(missing) verdict=NA"

# ==== S: lane-silent alerts ===================================================
bmp_newcase s1
bmp_log "$H/logs/ALERTS.log" $(( BMP_E5 + 3600 )) "[jobs-watchdog] LANE SILENT: alpha-os@$BM_NEW no tick for 95m. Threshold 60m."
out=$(pf 2>&1)
has S1-silent "$out" "count alpha-os lane_silent after=1 verdict=fail"
has S1-other "$out" "count beta-os lane_silent after=0 verdict=pass"
has S1-proof "$out" "proof verdict=fail"

bmp_newcase s2
bmp_log "$H/logs/ALERTS.log" $(( BMP_E5 + 3600 )) "[jobs-watchdog] LANE RESUMED: alpha-os@$BM_NEW ticked again."
bmp_log "$H/logs/ALERTS.log" $(( BMP_E5 + 3700 )) "[jobs-watchdog] LANE SILENT: alpha-os-x@$BM_NEW no tick for 95m."
out=$(pf 2>&1)
has S2-not-silent "$out" "count alpha-os lane_silent after=0 verdict=pass"

bmp_newcase s3
bmp_log "$H/logs/ALERTS.log" $(( BMP_E2 - 3600 )) "[jobs-watchdog] LANE SILENT: alpha-os@$BM_OLD no tick for 95m."
out=$(pf 2>&1)
has S3-before-only "$out" "count alpha-os lane_silent after=0 verdict=pass"

# ==== V: the verdict rule (triage ticks) ======================================
vcase() { # <name> <before n> <after n> <want verdict>
  bmp_newcase "$1"
  [ "$2" -gt 0 ] && bmp_triage "$OLD" alpha-os $(( BMP_E2 - 5000 )) "$2"
  [ "$3" -gt 0 ] && bmp_triage "$NEW" alpha-os $(( BMP_E5 + 5000 )) "$3"
  out=$(pf 2>&1)
  has "$1-verdict" "$out" "count alpha-os triage_ticks before=$2 after=$3 verdict=$4"
}
vcase v1 5 4 pass
vcase v2 5 3 fail
vcase v3 0 0 pass
bmp_newcase v4; rm -f "$OLD/logs/alpha-os.log"; bmp_triage "$NEW" alpha-os $(( BMP_E5 + 5000 )) 9
out=$(pf 2>&1)
has V4-na "$out" "count alpha-os triage_ticks before=NA(missing) after=9 verdict=NA"
has V4-proof "$out" "proof verdict=NA"
bmp_newcase v5
bmp_triage "$OLD" alpha-os $(( BMP_E2 - 5000 )) 5; bmp_triage "$NEW" alpha-os $(( BMP_E5 + 5000 )) 4
out=$(BOX_MOVE_PROOF_SLACK=0 pf 2>&1); check V5-slack0-rc "$?" 0
has V5-slack0 "$out" "count alpha-os triage_ticks before=5 after=4 verdict=fail"

# ==== D: the rollback drill and the full pass =================================
bmp_newcase d1
sed -i 's/elapsed_s=120/elapsed_s=901/' "$(ST)/steps.tsv"
out=$(pf 2>&1)
has D1-over "$out" "rollback_drill elapsed_s=901 budget_s=900 verdict=fail"
has D1-over-proof "$out" "proof verdict=fail"
sed -i 's/elapsed_s=901/elapsed_s=899/' "$(ST)/steps.tsv"
out=$(pf 2>&1)
has D1-under "$out" "rollback_drill elapsed_s=899 budget_s=900 verdict=pass"
has D1-pass "$out" "proof verdict=pass"
awk -F'\t' '$2 != "rollback"' "$(ST)/steps.tsv" > "$C/steps" && mv "$C/steps" "$(ST)/steps.tsv"
out=$(pf 2>&1)
has D1-none "$out" "rollback_drill elapsed_s=none budget_s=900 verdict=NA"
has D1-none-proof "$out" "proof verdict=NA"

# ==== R: rollback writes elapsed_s, proof reads it ============================
bmc_newcase r1; bm_target_ready; bmc_tick_table
# The old box row, as the registry holds it: the BH-8410 registry stub moves a
# project back to the address of the box row, and the second B1 needs it.
printf '# @box %s %s\n' "$BM_OLD" "$BM_OLD_IP" >> "$H/fleet.conf"
bmc_through B5
rb --confirm >"$C/out" 2>&1; check R1-rollback-rc "$?" 0
row=$(awk -F'\t' '$2 == "rollback" && $3 == "ok"' "$(ST)/steps.tsv")
el=$(grep -oE 'elapsed_s=[0-9]+' <<<"$row" | cut -d= -f2)
check R1-row-has-elapsed "${el:+yes}" yes
has R1-done-line "$(cat "$C/out")" "elapsed_s=$el"
# The real cut-over again after the drill (as the runbook); B3 needs a new snapshot.
sed -i 's/20261026T010203Z/20261026T020304Z/g' "$OLD/bin/state-backup.sh"
bmc_through B5
out=$(bm proof "$BM_OLD" "$BM_NEW" 2>&1); check R1-proof-rc "$?" 0
has R1-drill "$out" "rollback_drill elapsed_s=$el budget_s=900"

# ==== E: the CLI is read-only =================================================
bmp_newcase e1
bmp_triage "$OLD" alpha-os $(( BMP_E2 - 5000 )) 2
bmp_triage "$NEW" alpha-os $(( BMP_E5 + 5000 )) 2
# The new box sum leaves out the two files the existing proof line's
# `jobs-client.sh flag-has` writes there when the box has no worker URL (its
# degraded-mode log and its once-a-day flag); proof.sh adds no new box write.
nbsum() { (cd "$NEW" && find . -type f ! -path './locks/*' ! -path './logs/jobs-client.log' ! -name 'alerted-jobs-not-configured-*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1; }
hsum=$(bm_tree_sum "$H"); osum=$(bm_tree_sum "$OLD"); nsum=$(nbsum); : > "$VC"
out=$(pf 2>&1); check E1-rc "$?" 0
check E1-hub-unchanged "$(bm_tree_sum "$H")" "$hsum"
check E1-old-unchanged "$(bm_tree_sum "$OLD")" "$osum"
check E1-new-unchanged "$(nbsum)" "$nsum"
check E1-no-lock "$(ls -A "$H/locks" 2>/dev/null | wc -l)" 0
check E1-no-fly "$(grep -c '^flyctl' "$VC")" 0
check E1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
check E1-count-lines "$(grep -c '^count ' <<<"$out")" 12
has E1-pass "$out" "proof verdict=pass"
has E1-rows-line-stays "$out" "rows: $BM_NEW projects=-"

# ==== K: the knobs ============================================================
bmp_newcase k1
BOX_MOVE_PROOF_WINDOW_S=abc bm proof "$BM_OLD" "$BM_NEW" >/dev/null 2>"$C/err"; check K1-window-rc "$?" 2
check K1-one-line "$(wc -l < "$C/err")" 1
has K1-says "$(cat "$C/err")" "BOX_MOVE_PROOF_WINDOW_S='abc'"
BOX_MOVE_ROLLBACK_BUDGET_S=0 bm proof "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K1-budget-rc "$?" 2
BOX_MOVE_PROOF_SLACK=-1 bm proof "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K1-slack-rc "$?" 2
out=$(BOX_MOVE_ROLLBACK_BUDGET_S=60 pf 2>&1)
has K2-budget-override "$out" "rollback_drill elapsed_s=120 budget_s=60 verdict=fail"

# ==== B: no real vendor =======================================================
for n in gh curl ssh flyctl; do
  check "B1-stub-$n" "$(command -v "$n")" "$STUB/$n"
done

# ==== N: no destructive call in the lib =======================================
LIB="$REPO/bin/lib/box-move/proof.sh"
check N1-lib-exists "$( [ -s "$LIB" ] && echo yes || echo no)" yes
check N1-no-destructive "$(grep -vE '^[[:space:]]*#' "$LIB" 2>/dev/null | grep -cE 'flyctl|crontab -r|registry\.sh|orgo|--delete')" 0

bm_done box-move-proof-window

#!/bin/bash
# tests/box-move-isolation.bh-8325-test.sh — `bin/box-move.sh isolation`
# (BH-8325, MKF-10): the drill stops the old Orgo computer through box-ops and
# its report proves the hub no longer needs it.
#
# Cases: S1-S6 isolation --step I1 (dry run, refusals, the stop, the report
# reads the drill, a box-ops failure, a held lock); A1-A9 the old-address
# counter; P1 the pull-path pairs; L1-L4 the triage dispatch, lead review,
# merge and fix-round counters; T1-T6 the tailnet answer and the tracked-file
# check; V1-V6 the verdict; R1-R5 retire_ready; F1-F2 the report file; K1-K2
# the knobs; B1 every vendor binary is a stub; N1 no delete call path; D1 the
# runbook's command lines run. Every case runs the real bin/box-move.sh (and
# through it the real bin/box-ops.sh) in its own scratch tree.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-isolation.bh-8325-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-isolation-fixture.bh-8325.sh" || exit 1
ST() { printf '%s' "$H/state/box-move/$BM_NEW"; }
FP() { printf '%s' "$H/logs/fly-pool.log"; }
T0ISO=$(bmp_iso "$BMI_T0")
nlines() { grep -c -- "$1" "$2" 2>/dev/null; }

# ==== S: isolation --step I1 ==================================================
bmi_newcase s1; : > "$VC"
out=$(iso --step I1 2>&1); check S1-rc "$?" 0
has S1-would "$out" "WOULD RUN I1:"
has S1-plan-stop "$out" "PLAN stop POST /computers/c-project-6-os-fixture/stop"
has S1-no-project "$out" "stop: no project on project-6-os"
has S1-box-ops-plan "$out" "result=PLAN"
check S1-no-baseline "$( [ -e "$(ST)/isolation-baseline.tsv" ] && echo yes || echo no)" no
check S1-no-i1-row "$(awk -F'\t' '$2 == "I1"' "$(ST)/steps.tsv" | wc -l)" 0
check S1-no-post "$(grep -c '^orgo POST' "$VC")" 0

bmi_newcase s2; printf '%s\tB5\treset\trollback\n' "$(bmp_iso "$BMI_T0")" >> "$(ST)/steps.tsv"; : > "$VC"; : > "$CALLS"
out=$(iso --step I1 --confirm 2>&1); check S2-no-b5-rc "$?" 3
has S2-no-b5-why "$out" "the last B5 row is reset, not ok"
check S2-no-b5-orgo "$(grep -c '^orgo ' "$VC")" 0
check S2-no-b5-alert "$(grep -c '^hub:alert-line --id box-move-preflight' "$CALLS")" 1
check S2-no-b5-baseline "$( [ -e "$(ST)/isolation-baseline.tsv" ] && echo yes || echo no)" no
bmi_newcase s2b; printf 'delta-os o/delta https://delta.example /api/board 2 %s %s\n' "$BM_OLD" "$BM_OLD_IP" >> "$H/fleet.conf"; : > "$VC"
out=$(iso --step I1 --confirm 2>&1); check S2-project-rc "$?" 3
has S2-project-why "$out" "the rows still put delta-os on $BM_OLD"
check S2-project-orgo "$(grep -c '^orgo ' "$VC")" 0
bmi_newcase s2c; printf '{"provider":"fly","box_id":"project-6-os"}\n' > "$(ST)/target.json"; : > "$VC"
out=$(iso --step I1 --confirm 2>&1); check S2-tsip-rc "$?" 3
has S2-tsip-why "$out" "has no ts_ip"
check S2-tsip-orgo "$(grep -c '^orgo ' "$VC")" 0

bmi_newcase s3; : > "$VC"
out=$(iso --step I1 --confirm 2>&1); check S3-rc "$?" 0
check S3-one-stop "$(grep -c '^orgo POST /computers/c-project-6-os-fixture/stop$' "$VC")" 1
check S3-no-pause-call "$(grep -c 'paused-' "$VC")" 0
check S3-no-pause-flag "$(ls "$H/flags" 2>/dev/null | grep -c '^paused-')" 0
check S3-stopped "$(jq -r .status "$ORGO_D/comp.json")" stopped
row=$(awk -F'\t' '$2 == "I1"' "$(ST)/steps.tsv")
has S3-row-ok "$row" "I1	ok	since=$T0ISO old_ip=$BM_OLD_IP box_id=project-6-os host=$BM_OLD"
check S3-baseline-head "$(head -1 "$(ST)/isolation-baseline.tsv")" "# since=$T0ISO epoch=$BMI_T0 old_ip=$BM_OLD_IP"
has S3-baseline-fly-pool "$(cat "$(ST)/isolation-baseline.tsv")" "	fly-pool.log"
has S3-box-ops-log "$(cat "$H/logs/box-ops-orgo.log")" "verb=stop box=project-6-os orgo=c-project-6-os-fixture result=OK stopped"

# S4: the report reads the drill I1 wrote.
export HUB_MOVE_NOW=$(( BMI_T0 + 3600 ))
out=$(iso 2>&1); check S4-rc "$?" 0
has S4-since "$out" "isolation since=$T0ISO until=$(bmp_iso $(( BMI_T0 + BMI_W ))) elapsed_s=3600 window_s=$BMI_W state=running old_box=$BM_OLD box_id=project-6-os"
has S4-running-na "$out" "isolation verdict=NA"

bmi_newcase s5; printf '500\n' > "$ORGO_D/stop-code"
out=$(iso --step I1 --confirm 2>&1); check S5-rc "$?" 4
has S5-row "$(awk -F'\t' '$2 == "I1" {print $3 " " $4}' "$(ST)/steps.tsv")" "fail box-ops rc=1"
check S5-baseline-left "$( [ -s "$(ST)/isolation-baseline.tsv" ] && echo yes || echo no)" yes
out=$(iso 2>&1)
has S5-report-none "$out" "isolation: none (the last I1 row is fail, not ok)"

bmi_newcase s6; mkdir -p "$H/locks"; : > "$VC"
exec 7>"$H/locks/box-move-$BM_NEW.lock"; flock -n 7 || bad "S6 cannot take the lock"
out=$(iso --step I1 --confirm 2>&1); check S6-rc "$?" 0
has S6-held "$out" "already running"
exec 7>&-
check S6-no-orgo "$(grep -c '^orgo ' "$VC")" 0
check S6-no-row "$(awk -F'\t' '$2 == "I1"' "$(ST)/steps.tsv" | wc -l)" 0

# ==== A: the old-address counter (AC1) ========================================
# A4 setup: a line with the address before the drill stays out of the count.
bmi_newcase a1
bmi_log "$(FP)" $(( BMI_T0 - 500 )) "[pool/alpha-os] env bundle FAILED ssh env extract from $BM_OLD_IP failed (ssh rc 255)"
# An unstamped line: only the baseline offset keeps it out (no stamp to drop).
printf 'unstamped pre-drill root@%s\n' "$BM_OLD_IP" >> "$(FP)"
bmi_start
out=$(iso 2>&1); check A4-rc "$?" 0
has A4-pre-baseline-out "$out" "count old_ip_lines n=0 files=0 verdict=pass"
bmi_log "$(FP)" $(( BMI_T0 + 10 )) "[pool/alpha-os] env bundle FAILED ssh env extract from $BM_OLD_IP failed (ssh rc 255)"
out=$(iso 2>&1)
has A1-ssh "$out" "count old_ip_lines n=1 files=1 verdict=fail"
has A1-file "$out" "old_ip_file fly-pool.log n=1"
bmi_log "$H/logs/ALERTS.log" $(( BMI_T0 + 20 )) "[x] ssh root@$BM_OLD_IP: timed out"
bmi_log "$H/logs/ALERTS.log" $(( BMI_T0 + 21 )) "[pool/x] box $BM_OLD_IP unreachable"
out=$(iso 2>&1)
has A2-root-and-box "$out" "count old_ip_lines n=3 files=2 verdict=fail"
has A2-alerts-file "$out" "old_ip_file ALERTS.log n=2"

bmi_newcase a3; bmi_start
for l in "${BM_OLD_IP}0 is another box" "1$BM_OLD_IP is another box" "${BM_OLD_IP%1} is a prefix" "$BM_OLD alone" "x.$BM_OLD_IP dotted prefix"; do
  bmi_log "$(FP)" $(( BMI_T0 + 30 )) "[pool/alpha-os] $l"
done
out=$(iso 2>&1)
has A3-near-miss "$out" "count old_ip_lines n=0 files=0 verdict=pass"
bmi_log "$(FP)" $(( BMI_T0 + 31 )) "[pool/alpha-os] at end $BM_OLD_IP."
out=$(iso 2>&1)
has A3-trailing-dot-counts "$out" "count old_ip_lines n=1 files=1"

# A5: a rotation renames fly-pool.log (same inode); a line appended after the
# baseline counts, the line before it does not.
bmi_newcase a5
bmi_log "$(FP)" $(( BMI_T0 - 500 )) "[pool/alpha-os] old $BM_OLD_IP line"
bmi_start
mv "$(FP)" "$(FP).1"
bmi_log "$(FP).1" $(( BMI_T0 + 40 )) "[pool/alpha-os] ssh root@$BM_OLD_IP"
out=$(iso 2>&1)
has A5-rotated "$out" "count old_ip_lines n=1 files=1 verdict=fail"
has A5-file "$out" "old_ip_file fly-pool.log.1 n=1"

# A6: a new .gz: lines stamped before T0 drop, a line after T0 counts.
bmi_newcase a6; bmi_start
{ printf '%s old %s\n' "$(bmp_stamp $(( BMI_T0 - 100 )))" "$BM_OLD_IP"
  printf '%sT%s old iso %s\n' "$(date -u -d "@$(( BMI_T0 - 90 ))" +%F)" "$(date -u -d "@$(( BMI_T0 - 90 ))" +%TZ)" "$BM_OLD_IP"
  printf '[%s] bracketed old %s\n' "$(bmp_stamp $(( BMI_T0 - 80 )))" "$BM_OLD_IP"; } | gzip > "$H/logs/fly-pool.log.2.gz"
touch -d "@$(( BMI_T0 + 60 ))" "$H/logs/fly-pool.log.2.gz"
out=$(iso 2>&1)
has A6-gz-old "$out" "count old_ip_lines n=0 files=0 verdict=pass"
{ printf '%s new %s\n' "$(bmp_stamp $(( BMI_T0 + 100 )))" "$BM_OLD_IP"; printf 'unstamped %s\n' "$BM_OLD_IP"; } | gzip > "$H/logs/x.log.gz"
touch -d "@$(( BMI_T0 + 60 ))" "$H/logs/x.log.gz"
out=$(iso 2>&1)
has A6-gz-new "$out" "old_ip_file x.log.gz n=2"

# A7: a new file whose mtime is before T0 is not read.
bmi_newcase a7; bmi_start
printf '%s copied %s\n' "$(bmp_stamp $(( BMI_T0 + 5 )))" "$BM_OLD_IP" > "$H/logs/copied.log"
touch -d "@$(( BMI_T0 - 60 ))" "$H/logs/copied.log"
out=$(iso 2>&1)
has A7-old-mtime "$out" "count old_ip_lines n=0 files=0 verdict=pass"

# A8: the same inode rewritten with other first bytes (a reused inode) is
# read whole, so a line at its start is not hidden by the baseline offset.
bmi_newcase a8; bmi_start
f="$(FP)"; ino=$(stat -c %i "$f")
{ printf '%s rewritten %s\n' "$(bmp_stamp $(( BMI_T0 + 50 )))" "$BM_OLD_IP"; head -c 4096 /dev/zero | tr '\0' 'x'; echo; } > "$f"
touch -d "@$(( BMI_T0 + 60 ))" "$f"
check A8-same-inode "$(stat -c %i "$f")" "$ino"
out=$(iso 2>&1)
has A8-head-changed "$out" "count old_ip_lines n=1 files=1 verdict=fail"
# A truncated file (smaller than the baseline) is read whole too.
bmi_newcase a8b; bmi_start
printf '%s short %s\n' "$(bmp_stamp $(( BMI_T0 + 50 )))" "$BM_OLD_IP" > "$(FP)"; touch -d "@$(( BMI_T0 + 60 ))" "$(FP)"
out=$(iso 2>&1)
has A8-truncated "$out" "count old_ip_lines n=1 files=1 verdict=fail"

# A9: an unreadable log is NA, never 0.
bmi_newcase a9; bmi_start; bmi_fill alpha-os
printf '\037\213garbage-not-gzip' > "$H/logs/broken.log.gz"; touch -d "@$(( BMI_T0 + 60 ))" "$H/logs/broken.log.gz"
out=$(iso 2>&1)
has A9-na "$out" "count old_ip_lines n=NA(read broken.log.gz)"
has A9-verdict "$out" "isolation verdict=NA"
has A9-not-ready "$out" "retire_ready=no"

# ==== P: pull-path spawns that reached RESULT (AC2) ===========================
bmi_newcase p1; bmi_start
pl() { bmi_log "$(FP)" "$1" "$2"; }
pl $(( BMI_T0 + 10 )) "[pool/alpha-os] m1: seeded 3 file(s) for BH-1 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 20 )) "[pool/alpha-os] reaped BH-1 from m1: DONE"
pl $(( BMI_T0 + 30 )) "[pool/alpha-os] m1: seeded 2 file(s) for BH-2 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 40 )) "[pool/alpha-os] reaped BH-2 from m1: DONE"
pl $(( BMI_T0 + 50 )) "[pool/alpha-os] m2: seeded 2 file(s) for BH-3 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 60 )) "[pool/alpha-os] m3: seeded 2 file(s) for BH-4 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 70 )) "[pool/alpha-os] reaped BH-4 from m9: DONE"
pl $(( BMI_T0 + 80 )) "[pool/alpha-os] m4: seeded 2 file(s) for BH-5 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 90 )) "[pool/alpha-os] reaped console preview BH-5 from m4: DONE"
pl $(( BMI_T0 + 100 )) "[pool/alpha-os2] m5: seeded 2 file(s) for BH-6 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 110 )) "[pool/alpha-os2] reaped BH-6 from m5: DONE"
pl $(( BMI_T0 - 10 )) "[pool/alpha-os] m6: seeded 2 file(s) for BH-7 at launch; the machine fetches harness abc itself"
pl $(( BMI_T0 + 120 )) "[pool/alpha-os] reaped BH-7 from m6: DONE"
pl $(( BMI_T0 + 130 )) "[pool/alpha-os] reaped BH-8 from m7: DONE"
pl $(( BMI_T0 + 140 )) "[pool/alpha-os] m7: seeded 2 file(s) for BH-8 at launch; the machine fetches harness abc itself"
out=$(iso 2>&1); check P1-rc "$?" 0
has P1-pairs "$out" "count alpha-os pull_spawns_result n=2 min=5 verdict=fail"
for i in 3 4 5; do
  pl $(( BMI_T0 + 200 + i )) "[pool/alpha-os] reaped BH-$i from m$((i - 1)): DONE"
done
out=$(iso 2>&1)
has P1-five "$out" "count alpha-os pull_spawns_result n=5 min=5 verdict=pass"
out=$(BOX_MOVE_ISOLATION_MIN_PULL=6 iso 2>&1)
has P1-knob "$out" "count alpha-os pull_spawns_result n=5 min=6 verdict=fail"

# ==== L: AC3 counters =========================================================
bmi_newcase l1; bmi_start
NL="$NEW/logs/alpha-os.log"
bmi_log "$NL" $(( BMI_T0 + 10 )) "[alpha-os] dispatched 2 shards: s1 s2 — skipped 0 held [gate=fixture]"
bmi_log "$NL" $(( BMI_T0 + 20 )) "[alpha-os] dispatched 0 shards: (none) — skipped 1 held [gate=fixture]"
bmi_log "$NL" $(( BMI_T0 + 30 )) "[alpha-os] triage shards: 2 dispatching anyway"
bmi_log "$NL" $(( BMI_T0 + 40 )) "[beta-os] dispatched 3 shards: s1 [gate=fixture]"
bmi_log "$NL" $(( BMI_T0 - 40 )) "[alpha-os] dispatched 4 shards: s1 [gate=fixture]"
bmi_log "$(FP)" $(( BMI_T0 + 50 )) "[pool/alpha-os] pool lead review reaped for LR-1 from m1: APPROVE"
bmi_log "$(FP)" $(( BMI_T0 + 60 )) "[pool/alpha-os] pool lead review reaped for LR-2 from m2: APPROVE"
bmi_log "$(FP)" $(( BMI_T0 + 70 )) "[pool/beta-os] pool lead review reaped for LR-3 from m3: APPROVE"
bmp_fr_rows alpha-os done $(( BMI_T0 + 100 ))
bmp_fr_rows alpha-os adopted $(( BMI_T0 - 100 ))
bmp_search o/alpha "$BMI_T0" $(( BMI_T0 + BMI_W )) '{"total_count":1,"incomplete_results":false,"items":[{"number":11}]}'
bmp_gh "repos/o/alpha/pulls/11" '{"merged_by":{"login":"mergify[bot]"}}'
out=$(iso 2>&1); check L1-rc "$?" 0
has L1-dispatch "$out" "count alpha-os triage_dispatches n=1 min=1 verdict=pass"
has L2-lead "$out" "count alpha-os lead_reviews n=2 min=1 verdict=pass"
has L3-merges "$out" "count alpha-os conductor_merges n=1 min=1 mergify=1 verdict=pass"
has L4-fix "$out" "count alpha-os fix_rounds n=1 min=1 verdict=pass"

# ==== T: AC4 ==================================================================
bmi_newcase t1; bmi_start
out=$(iso 2>&1)
has T1-tailnet "$out" "tailnet_ip alpha-os answer=$BM_NEW_IP want=$BM_NEW_IP verdict=pass"
has T1-tracked "$out" "tracked_old_ip ref=$(bmi_git rev-parse --short=12 HEAD) files=0 allow=bin/share/mapping.py,.harness/specs/ verdict=pass"
awk -v i="$BM_OLD_IP" '!/^[[:space:]]*(#|$)/ && $1 == "alpha-os" {$7 = i} {print}' "$H/fleet.conf" > "$C/fc" && mv "$C/fc" "$H/fleet.conf"
out=$(iso 2>&1)
has T2-old-answer "$out" "tailnet_ip alpha-os answer=$BM_OLD_IP want=$BM_NEW_IP verdict=fail"
has T2-verdict "$out" "isolation verdict=fail"
out=$(BOX_MOVE_ISOLATION_PROJECTS=ghost-os iso 2>&1)
has T3-no-row "$out" "tailnet_ip ghost-os answer=none want=$BM_NEW_IP verdict=fail"

bmi_newcase t4; bmi_start
mkdir -p "$C/co/bin/share" "$C/co/.harness/specs/BH-1"
printf 'MAP = {"%s": "203.0.113.14"}\n' "$BM_OLD_IP" > "$C/co/bin/share/mapping.py"
printf 'old box at %s\n' "$BM_OLD_IP" > "$C/co/.harness/specs/BH-1/plan.md"
printf 'a near miss %s0\n' "$BM_OLD_IP" > "$C/co/docs/near.md"
bmi_commit allowed
out=$(iso 2>&1)
has T5-allowed "$out" "files=0 allow=bin/share/mapping.py,.harness/specs/ verdict=pass"
hasnt T6-near-miss "$out" "tracked_old_ip_file docs/near.md"
printf 'ssh root@%s\n' "$BM_OLD_IP" > "$C/co/docs/leak.md"
out=$(iso 2>&1)
has T4-uncommitted-not-read "$out" "files=0 allow="
bmi_commit leak
out=$(iso 2>&1)
has T4-leak "$out" "tracked_old_ip ref=$(bmi_git rev-parse --short=12 HEAD) files=1 allow=bin/share/mapping.py,.harness/specs/ verdict=fail"
has T4-named "$out" "tracked_old_ip_file docs/leak.md"
out=$(BOX_MOVE_ISOLATION_IP_ALLOW="bin/share/mapping.py .harness/specs/ docs/" iso 2>&1)
has T5-knob "$out" "files=0 allow=bin/share/mapping.py,.harness/specs/,docs/ verdict=pass"

# ==== V: the verdict ==========================================================
bmi_newcase v1; bmi_start; bmi_fill alpha-os
out=$(iso 2>&1); check V1-rc "$?" 0
has V1-complete "$out" "state=complete"
check V1-no-fail-or-na "$(grep -E '^(count|tailnet_ip|tracked_old_ip) ' <<<"$out" | grep -cv 'verdict=pass')" 0
has V1-pass "$out" "isolation verdict=pass"
export HUB_MOVE_NOW=$(( BMI_T0 + BMI_W - 1 ))
out=$(iso 2>&1)
has V2-running "$out" "state=running"
has V2-count-na "$out" "count alpha-os pull_spawns_result n=5 min=5 verdict=NA"
has V2-ip-na "$out" "count old_ip_lines n=0 files=0 verdict=NA"
has V2-verdict "$out" "isolation verdict=NA"
bmi_log "$H/logs/ALERTS.log" $(( BMI_T0 + 500 )) "ssh root@$BM_OLD_IP refused"
out=$(iso 2>&1)
has V3-final-fail "$out" "count old_ip_lines n=1 files=1 verdict=fail"
has V3-verdict "$out" "isolation verdict=fail"

bmi_newcase v4; bmi_start; bmi_fill alpha-os; rm -f "$NEW/logs/alpha-os.log"
out=$(iso 2>&1)
has V4-missing "$out" "count alpha-os triage_dispatches n=NA(missing) min=1 verdict=NA"
has V4-verdict "$out" "isolation verdict=NA"

bmi_newcase v5; bmi_start; bmi_fill alpha-os
grep -v 'reaped BH-5 from' "$(FP)" > "$C/fp" && cat "$C/fp" > "$(FP)"; touch -d "@$(( BMI_T0 + 60 ))" "$(FP)"
out=$(iso 2>&1)
has V5-four "$out" "count alpha-os pull_spawns_result n=4 min=5 verdict=fail"
has V5-verdict "$out" "isolation verdict=fail"
# V6: the default projects are every old-rows project: beta-os is judged too.
unset BOX_MOVE_ISOLATION_PROJECTS
out=$(iso 2>&1)
has V6-beta "$out" "count beta-os pull_spawns_result n=0 min=5 verdict=fail"

# ==== R: retire_ready =========================================================
bmi_newcase r1; bmi_start; bmi_fill alpha-os; : > "$VC"
export HUB_MOVE_NOW=$(( BMI_T0 + 604799 ))
out=$(iso 2>&1)
has R1-pass "$out" "isolation verdict=pass"
has R1-not-yet "$out" "retire_ready=no (clean_s 604799 < 604800) clean_s=604799 need_s=604800"
hasnt R1-no-next "$out" "NEXT"
export HUB_MOVE_NOW=$(( BMI_T0 + 604800 ))
out=$(iso 2>&1)
has R2-ready "$out" "retire_ready=yes clean_s=604800 need_s=604800"
has R2-next "$out" "NEXT (the operator runs this, never this tool): bin/box-ops.sh retire project-6-os --host $BM_OLD --delete --apply"
check R2-no-delete-call "$(grep -c '^orgo DELETE' "$VC")" 0
check R2-computer-stays "$(jq -r .id "$ORGO_D/comp.json")" c-project-6-os-fixture
out=$(BOX_MOVE_RETIRE_CLEAN_S=864000 iso 2>&1)
has R5-knob "$out" "retire_ready=no (clean_s 604800 < 864000) clean_s=604800 need_s=864000"
bmi_log "$H/logs/ALERTS.log" $(( BMI_T0 + 5 * 86400 )) "[pool/x] box $BM_OLD_IP unreachable"
out=$(iso 2>&1)
has R3-day5 "$out" "isolation verdict=fail"
has R3-not-ready "$out" "retire_ready=no (isolation verdict=fail)"
bmi_newcase r4
out=$(iso 2>&1); check R4-rc "$?" 0
has R4-none "$out" "isolation: none (the last I1 row is absent, not ok)"
has R4-not-ready "$out" "retire_ready=no (no drill)"

# ==== F: the report file ======================================================
bmi_newcase f1; bmi_start
out=$(iso 2>&1)
rf=$(sed -n 's/^report: //p' <<<"$out")
check F1-name "$rf" "$(ST)/isolation-report-$(date -u -d "@$(( BMI_T0 + BMI_W ))" +%Y%m%dT%H%M%SZ).txt"
check F1-same "$(cat "$rf")" "$(grep -v '^report: ' <<<"$out")"
export HUB_MOVE_NOW=$(( BMI_T0 + BMI_W + 60 ))
iso >/dev/null 2>&1
check F2-two-files "$(ls "$(ST)"/isolation-report-*.txt | wc -l)" 2

# ==== K: the knobs ============================================================
bmi_newcase k1; bmi_start; n0=$(ls "$(ST)" | wc -l)
for kv in BOX_MOVE_ISOLATION_WINDOW_S=abc BOX_MOVE_ISOLATION_MIN_PULL=0 BOX_MOVE_ISOLATION_MIN_EACH=-1 BOX_MOVE_RETIRE_CLEAN_S=7d; do
  env "$kv" bash "$H/bin/box-move.sh" isolation "$BM_OLD" "$BM_NEW" >/dev/null 2>"$C/err"; check "K1-${kv%%=*}-rc" "$?" 2
  has "K1-${kv%%=*}-says" "$(cat "$C/err")" "${kv%%=*}='${kv#*=}'"
done
for kv in "BOX_MOVE_ISOLATION_IP_ALLOW=docs/;x" "BOX_MOVE_ISOLATION_PROJECTS=Bad!" "BOX_MOVE_ORGO_ACCOUNT=a b"; do
  env "$kv" bash "$H/bin/box-move.sh" isolation "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check "K2-${kv%%=*}-rc" "$?" 2
done
check K2-nothing-written "$(ls "$(ST)" | wc -l)" "$n0"
# --step on isolation takes only I1; --force-drain is not an isolation flag.
bm isolation --step I2 "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K2-step-I2 "$?" 2
bm isolation --confirm "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K2-confirm-no-step "$?" 2
bm isolation --step I1 --force-drain "$BM_OLD" "$BM_NEW" >/dev/null 2>&1; check K2-force-drain "$?" 2

# ==== B: no real vendor =======================================================
for n in gh curl ssh flyctl claude; do
  check "B1-stub-$n" "$(command -v "$n")" "$STUB/$n"
done
check B1-orgo-base "$ORGO_API_BASE" https://orgo.fixture/api

# ==== N: no delete call path ==================================================
LIB="$REPO/bin/lib/box-move/isolation.sh"
check N1-lib-exists "$( [ -s "$LIB" ] && echo yes || echo no)" yes
check N1-no-delete "$(grep -vE '^[[:space:]]*#' "$LIB" 2>/dev/null | grep -E 'DELETE|--delete|flyctl|crontab -r|registry\.sh' | grep -cv 'echo "NEXT ')" 0

# ==== D: the runbook's commands run ===========================================
NOTE="$REPO/docs/notes/2026-11-02-BH-8325-MKF-10-isolation.md"
bmi_newcase d1
cmds=$(grep -E '^([A-Z_]+=[^ ]+ )*bin/(box-move|box-ops)\.sh ' "$NOTE" 2>/dev/null)
check D1-has-commands "$( [ "$(grep -c . <<<"$cmds")" -ge 5 ] && echo yes || echo no)" yes
while IFS= read -r c; do
  [ -n "$c" ] || continue
  # The fixture runs the dry run of each: no --confirm, no --apply.
  dc=$(sed -E 's/ --(confirm|apply)//g; s|bin/|'"$H"'/bin/|' <<<"$c")
  JOBS_URL=https://jobs.example REGISTRY_SOURCE=file bash -c "$dc" >"$C/d1out" 2>&1; rc=$?
  check "D1 [$c]" "$rc" 0
done <<<"$cmds"
has D1-step-i1 "$cmds" "bin/box-move.sh isolation --step I1 --confirm $BM_OLD $BM_NEW"
has D1-delete "$cmds" "bin/box-ops.sh retire project-6-os --host $BM_OLD --delete --apply"

bm_done box-move-isolation

#!/bin/bash
# tests/box-move-tick.bh-8322-test.sh — bin/box-move.sh tick: the no-write
# shadow tick of the old box's rendered crontab on the new box (BH-8322).
#
# The new box runs the real bin/hub-move.sh tick (installed by
# scratch_install_closure), so the no-write shim is the real
# bin/lib/hub-move-nowrite.sh.
#
# Cases: T1 three write lanes make 0 GitHub writes, 0 curl calls and 0 jobs
# rows (AT4); T2 the table is copied to the hub; T3 an unseeded target stops;
# T4 --real is refused before any call; T5 a tick with no tick-file line.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-move-tick.bh-8322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/box-move-fixture.bh-8322.sh" || exit 1
tick() { bm tick "$@" "$BM_OLD" "$BM_NEW"; }
write_lanes() {
  cat > "$C/cron.txt" <<'EOF'
* * * * * gh issue comment 1 --body x
*/5 * * * * gh api -X POST repos/o/r/issues
*/10 * * * * curl -X POST "$JOBS_URL/api/rows"
EOF
}

# ==== T1 / T2: the shadow tick (AT4) ==========================================
bm_newcase t1; bm_seeded_target; write_lanes
out=$(tick 2>&1); check T1-rc "$?" 0
has T1-summary "$out" "refused_writes=3 mode=nowrite"
check T1-no-gh-write "$(grep '^gh ' "$VC" | grep -cE 'comment|POST|-X')" 0
check T1-no-gh-call "$(grep -c '^gh ' "$VC")" 0
check T1-no-curl-call "$(grep -c '^curl ' "$VC")" 0
check T1-no-jobs-row "$(wc -l < "$JOBS_ROWS")" 0
check T1-ran-on-new-box "$(grep -c "^ssh root@$BM_NEW_IP" "$VC")" 2
check T1-all-off-reset "$( [ -e "$NEW/flags/all-off" ] && echo yes || echo no)" yes
f=$(sed -n 's/^tick-file: //p' <<<"$out" | tail -1)
case "$f" in "$NEW/state/hub-move/tick-"*.tsv) ok ;; *) bad "T1: tick-file [$f]" ;; esac
hub_copy="$H/state/box-move/$BM_NEW/$(basename "$f")"
check T2-hub-copy-equal "$(cmp -s "$f" "$hub_copy" && echo same || echo differ)" same
check T2-rows "$(grep -v '^#' "$hub_copy" | tail -n +2 | wc -l)" 4
check T2-refused-per-lane "$(awk -F'\t' 'NR>2 && $1 != "harness-sync-deploy" {s+=$4} END{print s}' "$hub_copy")" 3
has T2-summary-file "$(cat "${hub_copy%.tsv}.summary" 2>/dev/null)" "refused_writes=3"
has T1-old-box-id-rendered "$out" "lanes=4"

# ==== T3: an unseeded target ==================================================
bm_newcase t3; bm_seeded_target; write_lanes; rm -f "$NEW/state/hub-move/target-seeded"
tick >"$C/out" 2>&1; check T3-rc "$?" 4
has T3-hub-move-refused "$(cat "$C/out")" "not a seeded hub-move target"
check T3-no-lane-ran "$(grep -cE '^(gh|curl) ' "$VC")" 0
check T3-no-hub-copy "$(ls "$H/state/box-move/$BM_NEW/"tick-* 2>/dev/null | wc -l)" 0

# ==== T4: --real is refused in this slice =====================================
bm_newcase t4; bm_seeded_target; write_lanes
tick --real >"$C/out" 2>&1; check T4-rc "$?" 2
check T4-no-ssh "$(grep -c '^ssh ' "$VC")" 0
has T4-says "$(cat "$C/out")" "tick --real runs only inside cutover"

# ==== T5: the target prints no tick-file line =================================
bm_newcase t5; bm_seeded_target
printf '#!/bin/bash\necho "tick: lanes=0"\nexit 0\n' > "$NEW/bin/hub-move.sh"
tick >"$C/out" 2>&1; check T5-rc "$?" 4
has T5-says "$(cat "$C/out")" "no tick-file"
# T6: a failed tick that still names its table: the table is fetched, rc 4.
bm_newcase t6; bm_seeded_target
mkdir -p "$NEW/state/hub-move"; printf '# mode=nowrite-crontab-found at=1\nlane\trc\tsecs\trefused\ttimed_out\n' > "$NEW/state/hub-move/tick-20261025T030000Z.tsv"
printf '#!/bin/bash\necho "tick-file: %s"\nexit 4\n' "$NEW/state/hub-move/tick-20261025T030000Z.tsv" > "$NEW/bin/hub-move.sh"
tick >"$C/out" 2>&1; check T6-rc "$?" 4
check T6-table-fetched "$(head -1 "$H/state/box-move/$BM_NEW/tick-20261025T030000Z.tsv" 2>/dev/null)" "# mode=nowrite-crontab-found at=1"
# T7: no target.json: refused before any ssh.
bm_newcase t7
tick >/dev/null 2>&1; check T7-no-target-rc "$?" 3
check T7-no-ssh "$(grep -c '^ssh ' "$VC")" 0

bm_done box-move-tick

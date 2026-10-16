#!/bin/bash
# tests/lane-cpu-sample.bh-6173-test.sh — bin/lane-cpu-sample.sh measures the
# CPU share per lane: ticks over a window, each process counted under its
# nearest bin/<name>.sh ancestor (BH-6173, acceptance bullet 3).
#
# Drives the REAL bin/lane-cpu-sample.sh against fake /proc trees built under
# $T (--proc-root), and against hand-written snapshot files (--diff).
#   S1  round-trip: --snapshot of tree A and tree B, then --diff; tar and zstd
#       count under state-backup; a comm with ") " in it still parses.
#   S2  the lane walk: zstd -> tar -> state-backup; a ppid loop is "other" and
#       the tool does not hang.
#   S3  default verdict: no flags gives the state-backup line, limit 2%.
#   S4  the limit: 1.9 / 2.0 / 2.1 against --max-pct 2 give PASS FAIL FAIL
#       (BH-6712: under the limit is PASS; equal is FAIL); an absent lane is
#       share=0.0% PASS.
#   S5  exit paths: 0 total ticks is exit 2; bad arguments are exit 64; a pid
#       only in B counts from 0; a reused pid counts its B ticks; the default
#       mode leaves no temp file, on a normal exit and on SIGTERM.
#   S6  a child that exits inside the window (lead review lr-6328): its ticks
#       inside the window reach its parent's cutime+cstime and count for the
#       parent's lane; what snapshot A already showed of it does not.
#   S7  the lane script itself exits inside the window: its reaper's child
#       ticks count for the lane the A-only child had (A's tree).
#   S8  /usr/bin/<x>.sh is not a lane; bin/jobs-client.sh is a helper, so it
#       counts for the lane that started it.
#   S9  --interval: a bad value is exit 64; a 2 s window at a 1 s interval adds
#       the pairs up to the same verdict as one pair.
#   S10 a child seen in an earlier interval and reaped in a later one counts
#       once: --diff A B C adds the pairs, and the reaped ticks minus what A
#       already showed of the child are only its last interval (lead review
#       lr-6328 of d3288ba23: zstd counted twice gave 50.0% for a true 25.0%).
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LCS="$DIR/bin/lane-cpu-sample.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

# mkproc <root> <pid> <ppid> <utime> <stime> <comm> [argv...]
# Writes <root>/<pid>/stat in the kernel's layout (utime and stime are fields
# 14 and 15) and <root>/<pid>/cmdline NUL-separated.
# CUT and CST in the environment set cutime and cstime (fields 16 and 17).
mkproc() {
  local root="$1" pid="$2" ppid="$3" ut="$4" st="$5" comm="$6"; shift 6
  mkdir -p "$root/$pid"
  printf '%s (%s) S %s %s %s 0 -1 4194304 0 0 0 0 %s %s %s %s 20 0 1 0 100\n' \
    "$pid" "$comm" "$ppid" "$pid" "$pid" "$ut" "$st" "${CUT:-0}" "${CST:-0}" > "$root/$pid/stat"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" > "$root/$pid/cmdline"; else : > "$root/$pid/cmdline"; fi
}

# tree <root> <bump>: the S1 tree. bump=0 is snapshot A; bump=1 adds the deltas
# state-backup 1+2+7=10, merge-conductor 60, other 20, odd 10 (total 100).
tree() {
  local r="$1" b="$2"
  mkproc "$r" 1  0  0 0 systemd /sbin/init
  mkproc "$r" 10 1  $((100 + b*1)) 0 bash bash /root/harness/bin/state-backup.sh
  mkproc "$r" 11 10 $((50 + b*1)) $((0 + b*1)) tar tar -cf - state logs
  mkproc "$r" 12 11 $((200 + b*5)) $((3 + b*2)) zstd zstd -1 -T1
  mkproc "$r" 20 1  $((900 + b*40)) $((100 + b*20)) bash bash bin/merge-conductor.sh
  mkproc "$r" 30 1  $((10 + b*20)) 0 flyctl flyctl machine list
  mkproc "$r" 40 1  $((5 + b*10)) 0 'my ) proc' bash /root/harness/bin/odd.sh
  mkproc "$r" 41 1  0 0 kthreadd
}

# ── S1 round-trip ───────────────────────────────────────────────────────────
tree "$T/pA" 0
tree "$T/pB" 1
"$LCS" --snapshot --proc-root "$T/pA" > "$T/a.tsv"; eq "S1 snapshot A rc" "$?" 0
"$LCS" --snapshot --proc-root "$T/pB" > "$T/b.tsv"; eq "S1 snapshot B rc" "$?" 0
eq "S1 snapshot row count" "$(wc -l < "$T/b.tsv" | tr -d ' ')" 8
# TEST-CHANGE (lead review lr-6328 of 8aea09438): a snapshot row has a 5th
# column, the reaped children's ticks (cutime + cstime). The 4 columns before
# it are unchanged; the expected rows add that column (0 in this tree).
eq "S1 zstd row" "$(awk -F'\t' '$1==12' "$T/b.tsv")" "$(printf '12\t11\t210\t-\t0')"
eq "S1 state-backup row" "$(awk -F'\t' '$1==10' "$T/b.tsv")" "$(printf '10\t1\t101\tstate-backup\t0')"
eq "S1 comm with ') ' parsed" "$(awk -F'\t' '$1==40' "$T/b.tsv")" "$(printf '40\t1\t15\todd\t0')"
eq "S1 kernel thread has no lane" "$(awk -F'\t' '$1==41' "$T/b.tsv")" "$(printf '41\t1\t0\t-\t0')"
out=$("$LCS" --diff "$T/a.tsv" "$T/b.tsv"); rc=$?
# TEST-CHANGE (BH-6712): the default verdict line ends every report, and a
# 10.0% state-backup share is over the 2% default limit.
eq "S1 diff rc" "$rc" 1
eq "S1 diff table" "$out" "$(printf '60.0\tmerge-conductor\n20.0\tother\n10.0\todd\n10.0\tstate-backup\nstate-backup share=10.0%% FAIL (limit 2%%)')"
# The plan's REPRO reads the committed copies of these two snapshots.
eq "S1 fixture A is the snapshot" "$(cat "$DIR/tests/fixtures/lcs-a.tsv")" "$(cat "$T/a.tsv")"
eq "S1 fixture B is the snapshot" "$(cat "$DIR/tests/fixtures/lcs-b.tsv")" "$(cat "$T/b.tsv")"

# ── S2 lane walk ────────────────────────────────────────────────────────────
# Only zstd moves, so the whole sample must land on state-backup.
cp "$T/a.tsv" "$T/a2.tsv"
awk -F'\t' 'BEGIN{OFS="\t"} $1==12{$3+=9} {print}' "$T/a.tsv" > "$T/b2.tsv"
out=$("$LCS" --diff "$T/a2.tsv" "$T/b2.tsv"); rc=$?
eq "S2 zstd->tar->state-backup" "$out|$rc" "$(printf '100.0\tstate-backup\nstate-backup share=100.0%% FAIL (limit 2%%)')|1"
# A ppid loop with no lane, and a parent that is not in B: both "other".
printf '50\t51\t0\t-\n51\t50\t0\t-\n52\t999\t0\t-\n' > "$T/loopA.tsv"
printf '50\t51\t5\t-\n51\t50\t5\t-\n52\t999\t10\t-\n' > "$T/loopB.tsv"
out=$(timeout 5 "$LCS" --diff "$T/loopA.tsv" "$T/loopB.tsv"); rc=$?
eq "S2 ppid loop is other, no hang" "$out|$rc" "$(printf '100.0\tother\nstate-backup share=0.0%% PASS (limit 2%%)')|0"

# ── S3 default verdict ──────────────────────────────────────────────────────
# TEST-CHANGE (BH-6712): with no --lane the verdict is for state-backup at 2%.
out=$("$LCS" --diff "$T/a.tsv" "$T/b.tsv" 2>&1); rc=$?
eq "S3 default verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 2%)|1"

# ── S4 the limit ────────────────────────────────────────────────────────────
# limit_case <sb-ticks>: state-backup gets <n> of 1000 ticks (pids only in B).
limit_case() {
  printf '1\t0\t0\t-\n' > "$T/lA.tsv"
  printf '1\t0\t0\t-\n10\t1\t%s\tstate-backup\n20\t1\t%s\tmerge-conductor\n' "$1" $((1000 - $1)) > "$T/lB.tsv"
  "$DIR/bin/lane-cpu-sample.sh" --diff "$T/lA.tsv" "$T/lB.tsv" --lane state-backup --max-pct 2
}
out=$(limit_case 19); rc=$?
eq "S4 1.9 verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=1.9% PASS (limit 2%)|0"
out=$(limit_case 20); rc=$?
# TEST-CHANGE (BH-6712, comment 6172692190): "under 2%" passes, so 2.0 FAILs.
eq "S4 2.0 verdict (strict)" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=2.0% FAIL (limit 2%)|1"
out=$(limit_case 21); rc=$?
eq "S4 2.1 verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=2.1% FAIL (limit 2%)|1"
eq "S4 table still printed before FAIL" "$(head -n 1 <<<"$out")" "$(printf '97.9\tmerge-conductor')"
out=$("$LCS" --diff "$T/a.tsv" "$T/b.tsv" --lane nosuch-lane --max-pct 2); rc=$?
eq "S4 absent lane" "$(tail -n 1 <<<"$out")|$rc" "nosuch-lane share=0.0% PASS (limit 2%)|0"
out=$("$LCS" --diff "$T/a.tsv" "$T/b.tsv" --lane state-backup --max-pct 9.9); rc=$?
eq "S4 decimal limit" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 9.9%)|1"

# ── S5 exit paths ───────────────────────────────────────────────────────────
out=$("$LCS" --diff "$T/a.tsv" "$T/a.tsv" 2>&1); rc=$?
eq "S5 zero ticks" "$out|$rc" "LCS total 0 ticks|2"
# TEST-CHANGE (BH-6712): "--lane state-backup" and "--max-pct 2" alone are
# valid now (each has a default), so they left this list; T5 of
# tests/lane-cpu-sample.bh-6712-test.sh pins that each works alone.
for args in "--bogus" "--seconds abc" "--seconds 0" \
            "--max-pct 2x --lane x" "--diff $T/a.tsv" "--diff $T/a.tsv $T/nope.tsv" \
            "--snapshot --lane x --max-pct 2" "--proc-root $T/nope"; do
  # shellcheck disable=SC2086
  "$LCS" $args >/dev/null 2>"$T/err"; rc=$?
  eq "S5 bad args [$args] rc" "$rc" 64
  [ -s "$T/err" ] && ok || bad "S5 bad args [$args] printed no usage line"
done
printf '10\t1\tabc\tstate-backup\n' > "$T/badrow.tsv"
"$LCS" --diff "$T/a.tsv" "$T/badrow.tsv" >/dev/null 2>&1; eq "S5 malformed row rc" "$?" 64
# Only in B counts from 0; a reused pid (B ticks < A ticks) counts its B ticks.
printf '60\t1\t500\tbusy\n' > "$T/rA.tsv"
printf '60\t1\t30\tbusy\n61\t1\t70\tfresh\n' > "$T/rB.tsv"
out=$("$LCS" --diff "$T/rA.tsv" "$T/rB.tsv"); rc=$?
eq "S5 new pid + reused pid" "$out|$rc" "$(printf '70.0\tfresh\n30.0\tbusy\nstate-backup share=0.0%% PASS (limit 2%%)')|0"

# Default mode, normal exit: a helper bumps tree D's ticks once the first
# snapshot is fully written, so the window sees the S1 deltas.
mkdir -p "$T/tmpd"
tree "$T/pD" 0
( for _ in $(seq 1 200); do
    for f in "$T"/tmpd/lcs.*; do
      if [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" = 8 ]; then tree "$T/pD" 1; exit 0; fi
    done
    sleep 0.05
  done; exit 1 ) &
helper=$!
out=$(TMPDIR="$T/tmpd" "$LCS" --seconds 2 --proc-root "$T/pD" --lane state-backup --max-pct 2); rc=$?
wait "$helper"; eq "S5 helper saw the first snapshot" "$?" 0
eq "S5 default mode verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 2%)|1"
eq "S5 default mode left no temp file" "$(ls -A "$T/tmpd")" ""
# Default mode with nothing moving: exit 2, still no temp file.
out=$(TMPDIR="$T/tmpd" "$LCS" --seconds 1 --proc-root "$T/pA" 2>&1); rc=$?
eq "S5 default mode zero ticks" "$out|$rc" "LCS total 0 ticks|2"
eq "S5 zero-tick run left no temp file" "$(ls -A "$T/tmpd")" ""
# SIGTERM mid-window: the trap still removes the snapshots.
TMPDIR="$T/tmpd" "$LCS" --seconds 30 --proc-root "$T/pA" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 400); do
  [ -n "$(ls -A "$T/tmpd")" ] && break
  sleep 0.05
done
[ -n "$(ls -A "$T/tmpd")" ] && ok || bad "S5 default mode never wrote a snapshot"
kill -TERM "$pid"; wait "$pid"; rc=$?
eq "S5 SIGTERM rc" "$rc" 143
eq "S5 SIGTERM left no temp file" "$(ls -A "$T/tmpd")" ""

# ── S6 a child exits inside the window ──────────────────────────────────────
# A: state-backup 1 tick, its zstd 100, merge-conductor 1000. B: zstd is gone
# and reaped (its 150 ticks are now state-backup's cutime), state-backup 2,
# merge-conductor 1100. The lane share is (1 + 150) / (1 + 150 + 100) = 60.2%.
mkproc "$T/p6a" 1 0 0 0 systemd /sbin/init
mkproc "$T/p6a" 10 1 1 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p6a" 12 10 100 0 zstd zstd -1
mkproc "$T/p6a" 20 1 1000 0 bash bash bin/merge-conductor.sh
mkproc "$T/p6b" 1 0 0 0 systemd /sbin/init
CUT=150 mkproc "$T/p6b" 10 1 2 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p6b" 20 1 1100 0 bash bash bin/merge-conductor.sh
"$LCS" --snapshot --proc-root "$T/p6a" > "$T/6a.tsv"; "$LCS" --snapshot --proc-root "$T/p6b" > "$T/6b.tsv"
out=$("$LCS" --diff "$T/6a.tsv" "$T/6b.tsv" --lane state-backup --max-pct 2); rc=$?
# TEST-CHANGE (lead review lr-6328 of d3288ba23): 60.2 counted zstd's 100
# ticks from before the window. Only its last 50 ticks fall inside it:
# (1 + 50) / (1 + 50 + 100) = 33.8%.
eq "S6 an exited child counts for its lane" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=33.8% FAIL (limit 2%)|1"

# ── S7 the lane script itself exits inside the window ──────────────────────────
# A: cron (pid 5, no lane) runs state-backup (10, 5 ticks) and its zstd (12,
# 100). B: both are gone; cron reaped them, so its cstime grew by 300.
mkproc "$T/p7a" 1 0 0 0 systemd /sbin/init
mkproc "$T/p7a" 5 1 1 0 cron /usr/sbin/cron -f
mkproc "$T/p7a" 10 5 5 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p7a" 12 10 100 0 zstd zstd -1
mkproc "$T/p7a" 20 1 1000 0 bash bash bin/merge-conductor.sh
mkproc "$T/p7b" 1 0 0 0 systemd /sbin/init
CST=300 mkproc "$T/p7b" 5 1 1 0 cron /usr/sbin/cron -f
mkproc "$T/p7b" 20 1 1100 0 bash bash bin/merge-conductor.sh
"$LCS" --snapshot --proc-root "$T/p7a" > "$T/7a.tsv"; "$LCS" --snapshot --proc-root "$T/p7b" > "$T/7b.tsv"
out=$("$LCS" --diff "$T/7a.tsv" "$T/7b.tsv" --lane state-backup --max-pct 2); rc=$?
# TEST-CHANGE (lead review lr-6328 of d3288ba23): 75.0 counted the 5 + 100
# ticks state-backup and its zstd had before the window. The window holds the
# other 195: 195 / (195 + 100) = 66.1%.
eq "S7 a lane that exits counts its reaped ticks" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=66.1% FAIL (limit 2%)|1"
# Old 4-column snapshots still read (no child ticks).
out=$("$LCS" --diff "$T/loopA.tsv" "$T/loopB.tsv"); rc=$?
eq "S7 4-column rows still read" "$out|$rc" "$(printf '100.0\tother\nstate-backup share=0.0%% PASS (limit 2%%)')|0"

# ── S8 which scripts are lanes ───────────────────────────────────────────────
mkproc "$T/p8" 1 0 0 0 systemd /sbin/init
mkproc "$T/p8" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p8" 11 10 0 0 bash bash /root/harness/bin/jobs-client.sh push
mkproc "$T/p8" 12 1 0 0 sh /bin/sh /usr/bin/gettext.sh
mkproc "$T/p8" 13 1 0 0 sh /bin/sh /usr/local/bin/tool.sh
"$LCS" --snapshot --proc-root "$T/p8" > "$T/8.tsv"
eq "S8 jobs-client.sh is a helper, not a lane" "$(awk -F'\t' '$1==11{print $4}' "$T/8.tsv")" "-"
eq "S8 /usr/bin/<x>.sh is not a lane" "$(awk -F'\t' '$1==12{print $4}' "$T/8.tsv")" "-"
eq "S8 /usr/local/bin/<x>.sh is not a lane" "$(awk -F'\t' '$1==13{print $4}' "$T/8.tsv")" "-"

# ── S9 --interval ────────────────────────────────────────────────────────────
for args in "--interval abc" "--interval 0"; do
  # shellcheck disable=SC2086
  "$LCS" $args >/dev/null 2>&1; eq "S9 bad args [$args] rc" "$?" 64
done
tree "$T/pE" 0
( for _ in $(seq 1 200); do
    for f in "$T"/tmpd/lcs.*; do
      if [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" = 8 ]; then tree "$T/pE" 1; exit 0; fi
    done
    sleep 0.05
  done; exit 1 ) &
helper=$!
out=$(TMPDIR="$T/tmpd" "$LCS" --seconds 2 --interval 1 --proc-root "$T/pE" --lane state-backup --max-pct 2); rc=$?
wait "$helper"; eq "S9 helper saw the first snapshot" "$?" 0
eq "S9 interval run verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 2%)|1"
eq "S9 interval run left no temp file" "$(ls -A "$T/tmpd")" ""

# ── S10 a multi-interval child counts once ─────────────────────────────────────
# A: state-backup -> tar -> zstd, all at 0, merge-conductor 0. B: zstd 100,
# merge-conductor 150. C: zstd gone, tar reaped it (cutime 100), merge-conductor
# 300. True: state-backup 100 of 400 ticks = 25.0%.
mkproc "$T/pa10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pa10" 11 10 0 0 tar tar -cf - state
mkproc "$T/pa10" 12 11 0 0 zstd zstd -1
mkproc "$T/pa10" 20 1 0 0 bash bash bin/merge-conductor.sh
mkproc "$T/pb10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pb10" 11 10 0 0 tar tar -cf - state
mkproc "$T/pb10" 12 11 100 0 zstd zstd -1
mkproc "$T/pb10" 20 1 150 0 bash bash bin/merge-conductor.sh
mkproc "$T/pc10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
CUT=100 mkproc "$T/pc10" 11 10 0 0 tar tar -cf - state
mkproc "$T/pc10" 20 1 300 0 bash bash bin/merge-conductor.sh
for x in a b c; do "$LCS" --snapshot --proc-root "$T/p${x}10" > "$T/10$x.tsv"; done
out=$("$LCS" --diff "$T/10a.tsv" "$T/10b.tsv" "$T/10c.tsv" --lane state-backup --max-pct 30); rc=$?
eq "S10 a reaped child seen before counts once" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=25.0% PASS (limit 30%)|0"
# One level (no tar): state-backup reaps zstd directly. True 100 of 400.
mkproc "$T/pd10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pd10" 12 10 0 0 zstd zstd -1
mkproc "$T/pd10" 20 1 0 0 bash bash bin/merge-conductor.sh
mkproc "$T/pe10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pe10" 12 10 100 0 zstd zstd -1
mkproc "$T/pe10" 20 1 150 0 bash bash bin/merge-conductor.sh
CUT=100 mkproc "$T/pf10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pf10" 20 1 300 0 bash bash bin/merge-conductor.sh
for x in d e f; do "$LCS" --snapshot --proc-root "$T/p${x}10" > "$T/10$x.tsv"; done
out=$("$LCS" --diff "$T/10d.tsv" "$T/10e.tsv" "$T/10f.tsv" --lane state-backup --max-pct 30); rc=$?
eq "S10 one level, counted once" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=25.0% PASS (limit 30%)|0"
# The child ran 20 more ticks in its last, unseen interval: those count.
CUT=120 mkproc "$T/pg10" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/pg10" 20 1 300 0 bash bash bin/merge-conductor.sh
"$LCS" --snapshot --proc-root "$T/pg10" > "$T/10g.tsv"
out=$("$LCS" --diff "$T/10d.tsv" "$T/10e.tsv" "$T/10g.tsv" --lane state-backup --max-pct 30); rc=$?
eq "S10 the last unseen interval counts" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=28.6% PASS (limit 30%)|0"
"$LCS" --diff "$T/10a.tsv" >/dev/null 2>&1; eq "S10 --diff with one file rc" "$?" 64

echo "lane-cpu-sample.bh-6173: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

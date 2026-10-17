#!/bin/bash
# tests/lane-cpu-sample-cpu-s.bh-7252-test.sh — the opt-in --cpu-s column of
# bin/lane-cpu-sample.sh (BH-7252 C0): CPU seconds per hour per lane.
#
# Drives the REAL bin/lane-cpu-sample.sh in sample mode against fake /proc
# trees (--proc-root). A helper bumps the tree once the first snapshot is
# written, so the window sees a known tick delta. LCS_CLK_TCK sets the tick
# rate, so a 2 s window gives the same ratio as the plan's 60 s and 3600 s
# windows: cpu_s_h = ticks * 3600 / (CLK_TCK * seconds).
#   C1  300 ticks of merge-conductor, CLK_TCK 3000, 2 s -> 180.0 (the plan's
#       300 ticks at CLK_TCK 100 over 60 s); 100 ticks of other -> 60.0
#   C2  rounding: CLK_TCK 180000, 2 s (= CLK_TCK 100 over 3600 s): 1 tick ->
#       0.0, 5 ticks -> 0.1 (half up), 15 ticks -> 0.2
#   C3  without --cpu-s the output is the 2-column output, byte for byte, and
#       equals the --cpu-s output with column 3 cut
#   C4  --cpu-s with --snapshot or --diff exits 64
#   C5  a non-digit LCS_CLK_TCK is ignored: getconf CLK_TCK is used
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
mkproc() {
  local root="$1" pid="$2" ppid="$3" ut="$4" st="$5" comm="$6"; shift 6
  mkdir -p "$root/$pid"
  printf '%s (%s) S %s %s %s 0 -1 4194304 0 0 0 0 %s %s 0 0 20 0 1 0 100\n' \
    "$pid" "$comm" "$ppid" "$pid" "$pid" "$ut" "$st" > "$root/$pid/stat"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" > "$root/$pid/cmdline"; else : > "$root/$pid/cmdline"; fi
}

# tree1 <root> <0|1>: init, merge-conductor and a cron child with no lane.
# State 1 adds 300 ticks to merge-conductor and 100 to the cron child.
tree1() {
  local r="$1" s="$2"
  mkproc "$r" 1 0 0 0 systemd /sbin/init
  mkproc "$r" 20 1 $((s * 300)) 0 bash bash /root/harness/bin/merge-conductor.sh
  mkproc "$r" 30 1 $((s * 60)) $((s * 40)) cron /usr/sbin/cron
}
# tree2 <root> <0|1>: three lanes that move 1, 5 and 15 ticks.
tree2() {
  local r="$1" s="$2"
  mkproc "$r" 1 0 0 0 systemd /sbin/init
  mkproc "$r" 41 1 $((s * 1)) 0 bash bash bin/one.sh
  mkproc "$r" 42 1 $((s * 5)) 0 bash bash bin/five.sh
  mkproc "$r" 43 1 $((s * 15)) 0 bash bash bin/fifteen.sh
}

mkdir -p "$T/tmpd"
# sample <treefn> <root> <rows> [env...] -- [args...]: build state 0, start a
# helper that writes state 1 once the first snapshot holds <rows> lines, run
# the sampler. Sets OUT and RC.
sample() {
  local fn="$1" root="$2" rows="$3"; shift 3
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  [ ! -e "$root" ] || { bad "sample: $root is not a fresh tree"; return 1; }
  "$fn" "$root" 0
  ( for _ in $(seq 1 200); do
      for f in "$T"/tmpd/lcs.*; do
        if [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" = "$rows" ]; then "$fn" "$root" 1; exit 0; fi
      done
      sleep 0.05
    done; exit 1 ) &
  local helper=$!
  OUT=$(env TMPDIR="$T/tmpd" "${envs[@]}" "$LCS" --seconds 2 --proc-root "$root" "$@" 2>&1); RC=$?
  wait "$helper" || bad "helper never saw the first snapshot ($fn)"
}

# ── C1 ──────────────────────────────────────────────────────────────────────
sample tree1 "$T/p1" 3 LCS_CLK_TCK=3000 -- --cpu-s --lane merge-conductor --max-pct 100
eq "C1 cpu-s table" "$OUT|$RC" \
  "$(printf '75.0\tmerge-conductor\t180.0\n25.0\tother\t60.0\nmerge-conductor share=75.0%% PASS (limit 100%%)')|0"
C1_OUT=$OUT

# ── C2 ──────────────────────────────────────────────────────────────────────
sample tree2 "$T/p2" 4 LCS_CLK_TCK=180000 -- --cpu-s
eq "C2 rounding rows" "$(grep -v ' share=' <<<"$OUT")" \
  "$(printf '71.4\tfifteen\t0.2\n23.8\tfive\t0.1\n4.8\tone\t0.0')"
eq "C2 verdict line unchanged" "$(tail -n 1 <<<"$OUT")|$RC" "state-backup share=0.0% PASS (limit 2%)|0"

# ── C3 ──────────────────────────────────────────────────────────────────────
sample tree1 "$T/p3" 3 LCS_CLK_TCK=3000 -- --lane merge-conductor --max-pct 100
eq "C3 default output is 2 columns" "$OUT|$RC" \
  "$(printf '75.0\tmerge-conductor\n25.0\tother\nmerge-conductor share=75.0%% PASS (limit 100%%)')|0"
eq "C3 --cpu-s minus column 3 is the default output" "$(cut -f1,2 <<<"$C1_OUT")" "$OUT"
eq "C3 no temp file left" "$(ls -A "$T/tmpd")" ""

# ── C4 ──────────────────────────────────────────────────────────────────────
printf '10\t1\t0\tx\n' > "$T/a.tsv"; printf '10\t1\t5\tx\n' > "$T/b.tsv"
"$LCS" --cpu-s --snapshot --proc-root "$T/p1" >/dev/null 2>&1; eq "C4 --cpu-s --snapshot rc" "$?" 64
"$LCS" --snapshot --cpu-s --proc-root "$T/p1" >/dev/null 2>&1; eq "C4 --snapshot --cpu-s rc" "$?" 64
"$LCS" --cpu-s --diff "$T/a.tsv" "$T/b.tsv" >/dev/null 2>&1; eq "C4 --cpu-s --diff rc" "$?" 64
"$LCS" --diff "$T/a.tsv" "$T/b.tsv" --cpu-s >/dev/null 2>&1; eq "C4 --diff a b --cpu-s rc" "$?" 64
out=$("$LCS" --diff "$T/a.tsv" "$T/b.tsv"); eq "C4 --diff alone still works" "$out" \
  "$(printf '100.0\tx\nstate-backup share=0.0%% PASS (limit 2%%)')"

# ── C5 ──────────────────────────────────────────────────────────────────────
CT=$(getconf CLK_TCK 2>/dev/null); [[ "$CT" =~ ^[1-9][0-9]*$ ]] || CT=100
want=$(( (300 * 36000 * 2 + CT * 2) / (CT * 2 * 2) ))
sample tree1 "$T/p5" 3 LCS_CLK_TCK=abc -- --cpu-s --lane merge-conductor --max-pct 100
eq "C5 bad LCS_CLK_TCK falls back to getconf ($CT)" "$(head -n 1 <<<"$OUT")" \
  "$(printf '75.0\tmerge-conductor\t%d.%d' $((want / 10)) $((want % 10)))"

echo "lane-cpu-sample-cpu-s: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

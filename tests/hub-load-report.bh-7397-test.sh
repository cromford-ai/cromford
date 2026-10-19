#!/bin/bash
# tests/hub-load-report.bh-7397-test.sh — BH-7397: bin/hub-load-report.sh, the
# read-only hub baseline report, run as shipped against a scratch $HARNESS.
# TICK and FANIN lines come from the REAL writers (mc_tick_metrics through
# bin/lib/merge-conductor-lib.sh, _fanin_report through bin/lib/fanin.sh); only
# their timestamp prefix is set to a fixed time.
#
#   R1  runnable 1..10: p90 9.1, over the default cap 8; --cap 20: under, (flag)
#   R2  TICK secs 100 200 1600: n=3, max 1600, over_window=1
#   R3  FANIN runs: deferred_runs, all_deferred_runs, deferred_pr_share; no tsv
#       gives samples=0 runnable_p90=NA
#   R4  gh-calls: total and per caller, top first
#   R5  a window older than the oldest gh-calls line: partial(oldest=...)
#   R6  since is in, until is out
#   R7  bad flag, bad ISO, since >= until: rc 2 + usage; no input: rc 0, NA
#   R8  two windows print the same key set in the same order
#   R9  --help prints the header usage, rc 0; the report writes no file
#
# Run from anywhere: tests/hub-load-report.bh-7397-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

REPORT=bin/hub-load-report.sh
[ -s "$REPO/$REPORT" ] && ok "source exists: $REPORT" || bad "missing source $REPORT"
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env"
for L in "$REPORT" bin/lib/merge-conductor-lib.sh bin/lib/fanin.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

OUT="$T/out"
run() { ( unset MC_FULL_TICK_BUDGET_S; HARNESS="$H" "$H/$REPORT" "$@" ) > "$OUT" 2>"$T/err"; RC=$?; }
line() { grep "^$1 " "$OUT"; }
has() { line "$1" | tr ' ' '\n' | grep -qx -- "$2"; }
W=(--since 2026-10-18T16:00:00Z --until 2026-10-18T17:00:00Z)
reset_h() { local d; for d in "$H/state/hub-load" "$H/logs/gh-calls" "$H/logs/merge-conductor.log" "$H/state/merge-conductor" "$H/state/fanin"; do scratch_rm "$d"; done; }
# restamp <log stamp> — the real writer's line with its two-field stamp replaced.
restamp() { sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z /$1 /"; }

# ── R1 load ──────────────────────────────────────────────────────────────────
reset_h; mkdir -p "$H/state/hub-load"
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf '2026-10-18T16:%02d:00Z\trunnable=%s\tsteal=0\tforks_s=1.0\tcpu=us:1,sy:1,id:98,wa:0\tsamples=30/30\tfly-pool.sh=50.0\t(jq)=%s\n' \
    "$((i * 5))" "$i" "$((i * 2)).0" >> "$H/state/hub-load/2026-10-18.tsv"
done
run "${W[@]}"
has load samples=10 && has load runnable_p90=9.1 && has load runnable_max=10 && has load "cap=8(default)" && has load over_cap=yes \
  && ok "R1 p90 9.1 over the default cap 8" || bad "R1: $(line load)"
line lane_share | grep -q '^lane_share fly-pool.sh=50.0 (jq)=11.0$' && ok "R1 lane_share: mean share, top first" || bad "R1 share: $(line lane_share)"
run "${W[@]}" --cap 20
has load "cap=20(flag)" && has load over_cap=no && ok "R1 --cap 20: under, source flag" || bad "R1 cap: $(line load)"

# ── R2 ticks from the real mc_tick_metrics ───────────────────────────────────
reset_h
( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_tick_metrics o/r 1000 1100; mc_tick_metrics o/r 1000 1200; mc_tick_metrics o/r 1000 2600 )
grep -c ' TICK o/r ' "$H/logs/merge-conductor.log" | grep -qx 3 && ok "R2 setup: 3 real TICK lines" || bad "R2 setup: $(cat "$H/logs/merge-conductor.log")"
restamp '2026-10-18 16:10:00Z' < "$H/logs/merge-conductor.log" > "$T/l" && mv "$T/l" "$H/logs/merge-conductor.log"
run "${W[@]}"
has conductor_ticks n=3 && has conductor_ticks secs_max=1600 && has conductor_ticks secs_p50=200 \
  && has conductor_ticks tick_window=1500 && has conductor_ticks over_window=1 \
  && ok "R2 n=3 max 1600 over_window=1" || bad "R2: $(line conductor_ticks)"
run "${W[@]}" --tick-window 150
has conductor_ticks over_window=2 && ok "R2 --tick-window 150: over_window=2" || bad "R2 window: $(line conductor_ticks)"

# ── R3 fan-in from the real _fanin_report ────────────────────────────────────
reset_h
( export HARNESS="$H"; . "$H/bin/lib/fanin.sh"
  L="$H/logs/merge-conductor.log"
  fanin_begin merge-conductor o/r "$L"; for i in 1 2 3; do fanin_enumerate "o/r#$i"; fanin_account "o/r#$i" deferred:window; done; fanin_end
  fanin_begin merge-conductor o/r "$L"; fanin_enumerate o/r#4; fanin_account o/r#4 READY; fanin_enumerate o/r#5; fanin_account o/r#5 deferred:window; fanin_end )
( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$H/bin/lib/fanin.sh"; mc_window_defer o/r#5 )
restamp '2026-10-18 16:20:00Z' < "$H/logs/merge-conductor.log" > "$T/l" && mv "$T/l" "$H/logs/merge-conductor.log"
grep -c ' FANIN merge-conductor o/r: ' "$H/logs/merge-conductor.log" | grep -qx 2 && ok "R3 setup: 2 real FANIN lines" || bad "R3 setup: $(cat "$H/logs/merge-conductor.log")"
run "${W[@]}"
has conductor_fanin runs=2 && has conductor_fanin deferred_runs=2 && has conductor_fanin deferred_run_share=100% \
  && has conductor_fanin all_deferred_runs=1 && has conductor_fanin deferred_pr_share=80% && has conductor_fanin window_deferred_lines=1 \
  && ok "R3 deferred_runs=2 all_deferred_runs=1 deferred_pr_share=80%" || bad "R3: $(line conductor_fanin)"
has load samples=0 && has load runnable_p90=NA && has load over_cap=NA && ok "R3 no tsv: samples=0 runnable_p90=NA" || bad "R3 no tsv: $(line load)"

# ── R4 / R5 gh calls ─────────────────────────────────────────────────────────
reset_h; mkdir -p "$H/logs/gh-calls"
S=$(date -u -d 2026-10-18T16:00:00Z +%s)
{ for i in 1 2 3; do echo "$((S + 60 + i)) merge-conductor.sh api repos"; done
  for i in 1 2; do echo "$((S + 120 + i)) fly-pool.sh pr list"; done
  echo "$((S + 200)) reaper.sh api x"; } > "$H/logs/gh-calls/2026101816.log"
echo "$((S - 30)) early.sh api x" > "$H/logs/gh-calls/2026101815.log"
run "${W[@]}"
line gh_calls | grep -qx 'gh_calls total=6 merge-conductor.sh=3 fly-pool.sh=2 reaper.sh=1' \
  && ok "R4 total 6, per caller, top first" || bad "R4: $(line gh_calls)"
run --since 2026-10-18T15:00:00Z --until 2026-10-18T17:00:00Z
line gh_calls | grep -q "total=7 .*partial(oldest=2026-10-18T15:59:30Z)" && ok "R5 a window before the oldest line: partial" || bad "R5: $(line gh_calls)"

# ── R6 boundaries ────────────────────────────────────────────────────────────
reset_h; mkdir -p "$H/logs/gh-calls" "$H/state/hub-load"
E=$(date -u -d 2026-10-18T17:00:00Z +%s)
printf '%s a.sh x y\n%s b.sh x y\n%s c.sh x y\n' "$((S - 1))" "$S" "$E" > "$H/logs/gh-calls/2026101816.log"
printf '2026-10-18T15:59:59Z\trunnable=50\n2026-10-18T16:00:00Z\trunnable=2\n2026-10-18T17:00:00Z\trunnable=60\n' > "$H/state/hub-load/2026-10-18.tsv"
( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_tick_metrics o/r 1000 1005; mc_tick_metrics o/r 1000 1500; mc_tick_metrics o/r 1000 1900 )
awk 'NR == 1 { sub(/^[^T]*TICK/, "2026-10-18 15:59:59Z TICK") } NR == 2 { sub(/^[^T]*TICK/, "2026-10-18 16:00:00Z TICK") }
     NR == 3 { sub(/^[^T]*TICK/, "2026-10-18 17:00:00Z TICK") } { print }' "$H/logs/merge-conductor.log" > "$T/l" && mv "$T/l" "$H/logs/merge-conductor.log"
run "${W[@]}"
line gh_calls | grep -qx 'gh_calls total=1 b.sh=1' && has load samples=1 && has load runnable_max=2 \
  && has conductor_ticks n=1 && has conductor_ticks secs_max=500 && ok "R6 since in, until out (gh, tsv, TICK)" \
  || bad "R6: $(line gh_calls) | $(line load) | $(line conductor_ticks)"

# ── R7 flags and no input ────────────────────────────────────────────────────
for args in "--bogus" "--since yesterday" "--since 2026-10-18T17:00:00Z --until 2026-10-18T16:00:00Z" "--cap 0" "--since"; do
  # shellcheck disable=SC2086
  run $args
  [ "$RC" = 2 ] && grep -q '^usage: bin/hub-load-report.sh' "$T/err" && ok "R7 '$args': rc 2 + usage" || bad "R7 '$args': rc=$RC $(cat "$T/err")"
done
reset_h; run "${W[@]}"
[ "$RC" = 0 ] && has load runnable_p90=NA && line lane_share | grep -q '^lane_share NA' && line gh_calls | grep -q '^gh_calls total=NA' \
  && has conductor_ticks n=NA && has conductor_ticks secs_p90=NA && has conductor_fanin runs=NA && has conductor_fanin deferred_pr_share=NA \
  && ok "R7 no input at all: rc 0, NA lines" || bad "R7 no input: rc=$RC $(cat "$OUT")"
zeros=$(tr ' ' '\n' < "$OUT" | grep -E '^[a-z_]+=0$' | grep -v '^samples=')
[ -n "$zeros" ] && bad "R7 no input printed a 0: $zeros" || ok "R7 no input prints no 0"

# ── R8 same keys, two windows ────────────────────────────────────────────────
reset_h; mkdir -p "$H/state/hub-load" "$H/logs/gh-calls"
printf '2026-10-18T16:10:00Z\trunnable=3\tsamples=30/30\tx.sh=10.0\n2026-10-18T18:10:00Z\trunnable=9\tsamples=30/30\ty.sh=20.0\n' > "$H/state/hub-load/2026-10-18.tsv"
echo "$((S - 3600)) a.sh x y" > "$H/logs/gh-calls/2026101815.log"
( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_tick_metrics o/r 1000 1100 )
restamp '2026-10-18 16:10:00Z' < "$H/logs/merge-conductor.log" > "$T/l" && mv "$T/l" "$H/logs/merge-conductor.log"
keys() { awk '$1 != "lane_share" && $1 != "gh_calls" { printf "%s", $1; for (i = 2; i <= NF; i++) if ($i ~ /=/) { k = $i; sub(/=.*/, "", k); printf " %s", k } print "" }' "$OUT"; }
run "${W[@]}"; k1=$(keys)
run --since 2026-10-18T18:00:00Z --until 2026-10-18T19:00:00Z; k2=$(keys)
[ -n "$k1" ] && [ "$k1" = "$k2" ] && [ "$(awk '{ print $1 }' "$OUT" | tr '\n' ' ')" = "hub-load-report load lane_share gh_calls conductor_ticks conductor_fanin " ] \
  && ok "R8 two windows: same key set, same order" || bad "R8: [$k1] vs [$k2]"

# ── R9 --help, and nothing written ───────────────────────────────────────────
touch -d '2000-01-01' "$H/$REPORT"; before=$(find "$H" -type f -newer "$H/$REPORT" | LC_ALL=C sort)
run "${W[@]}"; run --help
after=$(find "$H" -type f -newer "$H/$REPORT" | LC_ALL=C sort)
[ "$RC" = 0 ] && grep -q '^usage: bin/hub-load-report.sh' "$OUT" && ok "R9 --help: usage, rc 0" || bad "R9 help: rc=$RC $(cat "$OUT")"
[ "$before" = "$after" ] && ok "R9 the report writes no file" || bad "R9 wrote: $(comm -13 <(echo "$before") <(echo "$after"))"

echo "hub-load-report: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

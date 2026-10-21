#!/bin/bash
# tests/hub-load-report-acceptance.bh-7769-test.sh — BH-7769: the acceptance
# verdict of bin/hub-load-report.sh (--acceptance), run as shipped against a
# scratch $HARNESS. TICK, FANIN and WINDOW_DEFERRED lines come from the REAL
# writers (mc_tick_metrics, fanin_begin/fanin_account/fanin_end,
# mc_window_defer); only their timestamp prefix is set to a fixed time.
#
#   A1  all pass: the exact acceptance line, rc 0
#   A2  p90 9.1 over the default cap 8: load fail, rc 1; --cap 20: pass, rc 0
#   A3  tick 1600 over window 1500: fail, rc 1; tick exactly 1500: pass
#   A4  one deferred:window + one WINDOW_DEFERRED: fail, rc 1; deferred:stop only: pass
#   A5  no conductor log: conductor values NA, verdict NA, rc 3; load still judged
#   A6  log present, no conductor line in the window: NA, rc 3
#   A7  no input: every value NA, rc 3; no samples + a tick over the window: fail, rc 1
#   A8  no flag: no acceptance line, rc 0; the six lines are byte-equal; no file written
#
# Run from anywhere: tests/hub-load-report-acceptance.bh-7769-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

REPORT=bin/hub-load-report.sh
[ -s "$REPO/$REPORT" ] && ok "source exists: $REPORT" || bad "missing source $REPORT"
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env"
for L in "$REPORT" bin/lib/merge-conductor-lib.sh bin/lib/fanin.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

OUT="$T/out"
W=(--since 2026-10-18T16:00:00Z --until 2026-10-18T17:00:00Z)
run() { ( unset MC_FULL_TICK_BUDGET_S; HARNESS="$H" "$H/$REPORT" "$@" ) > "$OUT" 2>"$T/err"; RC=$?; }
acc() { grep '^acceptance ' "$OUT"; }
has() { acc | tr ' ' '\n' | grep -qx -- "$1"; }
reset_h() { local d; for d in "$H/state/hub-load" "$H/logs/gh-calls" "$H/logs/merge-conductor.log" "$H/state/merge-conductor" "$H/state/fanin"; do scratch_rm "$d"; done; }
# load_n <N> — one hub-load sample per minute in the window, runnable 1..N.
load_n() { local i; mkdir -p "$H/state/hub-load"
  for i in $(seq 1 "$1"); do printf '2026-10-18T16:%02d:00Z\trunnable=%s\tsamples=30/30\tfly-pool.sh=50.0\n' "$i" "$i"; done >> "$H/state/hub-load/2026-10-18.tsv"; }
# ticks <secs>... — one real TICK line per value.
ticks() { ( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  local s; for s in "$@"; do mc_tick_metrics o/r 1000 "$((1000 + s))"; done ); }
# fanin <outcome>... — one real FANIN merge-conductor run, one PR per outcome.
fanin() { ( export HARNESS="$H"; . "$H/bin/lib/fanin.sh"
  local i=0 o; fanin_begin merge-conductor o/r "$H/logs/merge-conductor.log"
  for o in "$@"; do i=$((i + 1)); fanin_enumerate "o/r#$i"; fanin_account "o/r#$i" "$o"; done; fanin_end ); }
# wdefer <key> — one real WINDOW_DEFERRED line.
wdefer() { ( export HARNESS="$H"; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$H/bin/lib/fanin.sh"; mc_window_defer "$1" ); }
# stamp [<log stamp>] — every log line restamped (default: inside the window).
stamp() { sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z /${1:-2026-10-18 16:20:00Z} /" "$H/logs/merge-conductor.log" > "$T/l" \
  && mv "$T/l" "$H/logs/merge-conductor.log"; }

# ── A1 all pass ──────────────────────────────────────────────────────────────
reset_h; load_n 5; ticks 100 200; fanin READY READY; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 0 ] && acc | grep -qx 'acceptance load_p90_le_cap=pass conductor_ticks_in_window=pass window_deferred_zero=pass verdict=pass' \
  && ok "A1 all pass: exact line, rc 0" || bad "A1: rc=$RC $(cat "$OUT")"

# ── A2 load over the cap ─────────────────────────────────────────────────────
reset_h; load_n 10; ticks 100 200; fanin READY; stamp
run "${W[@]}" --acceptance
[ "$RC" = 1 ] && grep -q '^load .*cap=8(default)' "$OUT" && has load_p90_le_cap=fail && has conductor_ticks_in_window=pass \
  && has window_deferred_zero=pass && has verdict=fail && ok "A2 p90 9.1 over the default cap 8: fail, rc 1" || bad "A2: rc=$RC $(cat "$OUT")"
run "${W[@]}" --cap 20 --acceptance
[ "$RC" = 0 ] && has load_p90_le_cap=pass && has verdict=pass && ok "A2 --cap 20: pass, rc 0" || bad "A2 cap 20: rc=$RC $(acc)"

# ── A3 a tick over the window ────────────────────────────────────────────────
reset_h; load_n 5; ticks 100 1600; fanin READY; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && has load_p90_le_cap=pass && has conductor_ticks_in_window=fail && has verdict=fail \
  && ok "A3 tick 1600 over window 1500: fail, rc 1" || bad "A3: rc=$RC $(acc)"
reset_h; load_n 5; ticks 100 1500; fanin READY; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 0 ] && has conductor_ticks_in_window=pass && has verdict=pass && ok "A3 tick exactly 1500: pass, rc 0" || bad "A3 edge: rc=$RC $(acc)"

# ── A4 WINDOW_DEFERRED ───────────────────────────────────────────────────────
reset_h; load_n 5; ticks 100; fanin READY deferred:window; wdefer o/r#2; stamp
grep -q ' WINDOW_DEFERRED: ' "$H/logs/merge-conductor.log" && ok "A4 setup: a real WINDOW_DEFERRED line" || bad "A4 setup: $(cat "$H/logs/merge-conductor.log")"
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && has window_deferred_zero=fail && has conductor_ticks_in_window=pass && has verdict=fail \
  && ok "A4 deferred:window + WINDOW_DEFERRED: fail, rc 1" || bad "A4: rc=$RC $(acc)"
cp "$H/logs/merge-conductor.log" "$T/a4.log"
reset_h; load_n 5; ticks 100; wdefer o/r#2; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && has window_deferred_zero=fail && ok "A4 a WINDOW_DEFERRED line with no deferred:window run: fail" || bad "A4 line only: rc=$RC $(acc)"
reset_h; load_n 5; ticks 100; fanin READY deferred:window; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && has window_deferred_zero=fail && ok "A4 a deferred:window run with no WINDOW_DEFERRED line: fail" || bad "A4 run only: rc=$RC $(acc)"
reset_h; load_n 5; ticks 100; fanin READY deferred:stop; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 0 ] && has window_deferred_zero=pass && has verdict=pass && ok "A4 deferred:stop only: pass, rc 0" || bad "A4 stop: rc=$RC $(acc)"

# ── A5 no conductor log ──────────────────────────────────────────────────────
reset_h; load_n 5
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 3 ] && acc | grep -qx 'acceptance load_p90_le_cap=pass conductor_ticks_in_window=NA window_deferred_zero=NA verdict=NA' \
  && ok "A5 no conductor log: NA, rc 3, load judged" || bad "A5: rc=$RC $(cat "$OUT")"
reset_h; load_n 10
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && has load_p90_le_cap=fail && has verdict=fail && ok "A5 no conductor log + load over the cap: fail, rc 1" || bad "A5 fail: rc=$RC $(acc)"

# ── A6 log present, nothing in the window ────────────────────────────────────
reset_h; load_n 5; ticks 100; fanin READY; stamp '2026-10-18 18:20:00Z'
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 3 ] && has conductor_ticks_in_window=NA && has window_deferred_zero=NA && has verdict=NA \
  && ok "A6 no conductor line in the window: NA, rc 3" || bad "A6: rc=$RC $(cat "$OUT")"
reset_h; load_n 5; fanin READY; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 3 ] && has conductor_ticks_in_window=NA && has window_deferred_zero=pass && has verdict=NA \
  && ok "A6 a FANIN run and no TICK: ticks NA, deferred pass, rc 3" || bad "A6 fanin only: rc=$RC $(acc)"

# ── A7 no input; a fail beats an NA ──────────────────────────────────────────
reset_h
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 3 ] && acc | grep -qx 'acceptance load_p90_le_cap=NA conductor_ticks_in_window=NA window_deferred_zero=NA verdict=NA' \
  && ok "A7 no input: every value NA, rc 3" || bad "A7: rc=$RC $(cat "$OUT")"
reset_h; ticks 1600; stamp
run "${W[@]}" --cap 8 --acceptance
[ "$RC" = 1 ] && acc | grep -qx 'acceptance load_p90_le_cap=NA conductor_ticks_in_window=fail window_deferred_zero=pass verdict=fail' \
  && ok "A7 no samples + a tick over the window: fail, rc 1" || bad "A7 fail: rc=$RC $(acc)"

# ── A8 without the flag ──────────────────────────────────────────────────────
reset_h; load_n 5; cp "$T/a4.log" "$H/logs/merge-conductor.log"
run "${W[@]}" --cap 8; cp "$OUT" "$T/plain"
[ "$RC" = 0 ] && ! grep -q '^acceptance' "$T/plain" && [ "$(wc -l < "$T/plain")" = 6 ] \
  && ok "A8 no flag: no acceptance line, rc 0" || bad "A8: rc=$RC $(cat "$T/plain")"
touch -d '2000-01-01' "$H/$REPORT"; before=$(find "$H" -type f -newer "$H/$REPORT" | LC_ALL=C sort)
run "${W[@]}" --cap 8 --acceptance
after=$(find "$H" -type f -newer "$H/$REPORT" | LC_ALL=C sort)
[ "$RC" = 1 ] && head -6 "$OUT" | cmp -s - "$T/plain" && [ "$(wc -l < "$OUT")" = 7 ] \
  && ok "A8 the six lines are byte-equal with the flag; acceptance is line 7" || bad "A8 diff: $(diff "$T/plain" "$OUT")"
[ "$before" = "$after" ] && ok "A8 --acceptance writes no file" || bad "A8 wrote: $(comm -13 <(echo "$before") <(echo "$after"))"
reset_h; run "${W[@]}" --cap 8
[ "$RC" = 0 ] && ! grep -q '^acceptance' "$OUT" && ok "A8 no flag, no conductor log: rc 0, no acceptance line" || bad "A8 missing log: rc=$RC $(cat "$OUT")"
run --help
grep -q -- '--acceptance' "$OUT" && ok "A8 --help names --acceptance" || bad "A8 help: $(cat "$OUT")"

echo "hub-load-report-acceptance: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

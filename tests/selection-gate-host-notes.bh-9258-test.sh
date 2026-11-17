#!/bin/bash
# tests/selection-gate-host-notes.bh-9258-test.sh — BH-9258 (#9061 Fix 3):
# host-note rows for the context-kill family
# (catalog/selection-gate-host-notes.d/bh-9258.tsv, the BH-8725 seam).
#
# THE EVIDENCE. #9061 asks for each ERE to be proven against a real run.txt,
# and for no row without one. A pool machine holds no hub gate record, so the
# fixtures are the real output of each suite under CPU load on main b3a3541c
# (2026-11-08), the BH-9047 way: 2 x nproc busy loops, the suite run up to 10
# times, the first failing output kept, wrapped in the remote-gate section form.
# The cost row is cut after its first 3 fields with its box name scrubbed to
# fixture-box, and the stub's model string is scrubbed to fixture-model.
#   context-kill-lanes-2538.run.txt  tests/context-kill-lanes.bh-2538-test.sh,
#     run 1 of 10 failed: 7 `FAIL: E:` lines, `111 pass, 7 fail`.
#   tests/context-kill.bh-653-test.sh had no failure in 10 loaded runs, so it
#     has no row and no fixture (N5 holds that).
#
# PINNED. The REAL bin/selection-gate.sh runs with a stub planner and a stub
# runner that prints a fixture as the run output. No network.
#   N0 no bh-9258.tsv: no fixture dir either, "no rows", pass
#   N1 each fixture is noted: rc 0, red -, host-noted <suite>=host-timing
#   N2 near misses stay red: an extra `FAIL: A1:` line (a config red, not
#      timing); the fixture's lines under tests/context-kill.bh-653-test.sh;
#      the fixture with its `<n> fail` summary raised by 1
#   N3 every bh-9258 row loads with no skipped line, and its ERE matches at
#      least one FAIL line of its fixture
#   N5 every row's suite has a fixture, and every fixture has a row
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-host-notes.bh-9258-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SG="$DIR/bin/selection-gate.sh"
NOTES="$DIR/catalog/selection-gate-host-notes.d/bh-9258.tsv"
FX="$DIR/tests/fixtures/selection-gate-host-notes.bh-9258"
CK2538=tests/context-kill-lanes.bh-2538-test.sh
CK653=tests/context-kill.bh-653-test.sh
[ -x "$SG" ] || { echo "FAIL: bin/selection-gate.sh is missing"; exit 1; }
# fixture_of <suite> — the fixture file name of a suite this ticket covers.
fixture_of() {
  case "$1" in
    "$CK2538") echo "$FX/context-kill-lanes-2538.run.txt" ;;
    "$CK653") echo "$FX/context-kill-653.run.txt" ;;
    *) echo "" ;;
  esac
}

# ── N0 ───────────────────────────────────────────────────────────────────────
if [ ! -e "$NOTES" ]; then
  [ ! -e "$FX" ] && ok || bad "N0 no bh-9258.tsv, but $FX exists (a fixture with no row)"
  echo "selection-gate-host-notes.bh-9258: no rows; $PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]; exit
fi
SUITES=$(grep -v '^#' "$NOTES" | cut -f1)

# ── N5: a fixture for every row, a row for every fixture ─────────────────────
for s in $SUITES; do
  f=$(fixture_of "$s")
  [ -n "$f" ] && [ -r "$f" ] && ok || bad "N5 row $s has no fixture run.txt (want ${f:-a fixture this suite names})"
done
NFX=$(find "$FX" -maxdepth 1 -name '*.run.txt' 2>/dev/null | wc -l)
[ "$NFX" = "$(grep -cv '^#' "$NOTES")" ] && ok || bad "N5 $NFX fixture(s) for $(grep -cv '^#' "$NOTES") row(s)"

# ── the scratch repo, with only the bh-9258 notes ────────────────────────────
R="$T/repo"; mkdir -p "$R/catalog/selection-gate-host-notes.d"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; echo a > "$R/a.txt"; g add -A; g commit -qm base
g checkout -q -b ticket/bh-9258; echo b > "$R/b.txt"
cp "$NOTES" "$R/catalog/selection-gate-host-notes.d/"
g add -A; g commit -qm change
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' "$STUB_SUITES" > "$out"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
cat "$STUB_FILE"
exit 1
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
run() { # run <case> <suite> <run file> — one REAL bin/selection-gate.sh
  mkdir -p "$T/$1"
  env -u CI_QUARANTINE -u SELECTION_GATE_WHY_MAX -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S \
    -u SELECTION_GATE_BASELINE_RESERVE_PAD_S -u SELECTION_GATE_MAIN_TIMEOUT_MIN_S \
    HARNESS="$T/no-harness" REPO_SLUG= SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    STUB_SUITES="$2" STUB_FILE="$3" \
    bash "$SG" --tree "$R" --base main --out "$T/$1/out" --timeout 60 > "$T/$1/stdout" 2> "$T/$1/stderr"
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
red_ok() { # red_ok <case> <suite> <what>
  [ "$RC" = 1 ] && [ "$(gv "$1" red)" = "$2" ] && [ "$(gv "$1" host-noted)" = - ] && ok \
    || bad "$3 stays red (exit $RC; $(cat "$T/$1/out/gate.txt" 2>/dev/null); $(cat "$T/$1/stderr"))"
}
# raise <file> — the same file with its `<n> fail` summary raised by 1.
raise() { awk '{ if (match($0, /, [0-9]+ fail$/)) { n = substr($0, RSTART + 2, RLENGTH - 7) + 1; $0 = substr($0, 1, RSTART + 1) n " fail" } print }' "$1"; }

# ── N1 / N2 per row ──────────────────────────────────────────────────────────
i=0
for s in $SUITES; do
  i=$((i+1)); f=$(fixture_of "$s"); [ -r "$f" ] || continue
  run "n1-$i" "$s" "$f"
  [ "$RC" = 0 ] && [ "$(gv "n1-$i" rc)" = 0 ] && [ "$(gv "n1-$i" red)" = - ] && [ "$(gv "n1-$i" host-noted)" = "$s=host-timing" ] && ok \
    || bad "N1 $s is noted host-timing (exit $RC; $(cat "$T/n1-$i/out/gate.txt" 2>/dev/null); $(cat "$T/n1-$i/stderr"))"
  # a config red in the same section (A1 of 2538, 4 of 653), summary raised to match
  case "$s" in "$CK2538") x='FAIL: A1: triage resolves to 100000, want project-triage'"'"'s number' ;; *) x='FAIL: 4: a kill fired under the ceiling' ;; esac
  awk -v x="$x" '{ print } /^===== / { print x }' "$f" | raise /dev/stdin > "$T/n2a-$i.run"
  [ "$(grep -c '^FAIL: ' "$T/n2a-$i.run")" = "$(( $(grep -c '^FAIL: ' "$f") + 1 ))" ] && ok || bad "N2 setup: the extra line is in the section"
  run "n2a-$i" "$s" "$T/n2a-$i.run"; red_ok "n2a-$i" "$s" "N2 $s with an extra ${x%%: *}${x#FAIL}"
  # the same lines under another context-kill suite's name
  other=$CK653; [ "$s" = "$CK653" ] && other=$CK2538
  sed "s|$s|$other|g" "$f" > "$T/n2b-$i.run"
  run "n2b-$i" "$other" "$T/n2b-$i.run"; red_ok "n2b-$i" "$other" "N2 the $s lines under $other"
  # a summary that counts one more failure than the FAIL lines show
  raise "$f" > "$T/n2c-$i.run"
  cmp -s "$f" "$T/n2c-$i.run" && bad "N2 setup: the summary of $f did not change" || ok
  run "n2c-$i" "$s" "$T/n2c-$i.run"; red_ok "n2c-$i" "$s" "N2 $s with its fail summary raised by 1"
done

# ── N3: every row loads and matches its fixture ──────────────────────────────
N3=$( TREE="$R"; OUT="$T/n3"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2> "$T/n3.err"
  for j in "${!HN_SUITE[@]}"; do
    f=$(fixture_of "${HN_SUITE[$j]}")
    [ "${HN_CLASS[$j]}" = host-timing ] || { echo "class ${HN_SUITE[$j]}=${HN_CLASS[$j]}"; continue; }
    if [ -r "$f" ] && grep -qE -- "${HN_ERE[$j]}" <<<"$(grep -E '(^|[[:space:]])FAIL[: ]' "$f")"; then echo "match ${HN_SUITE[$j]}"; else echo "nomatch ${HN_SUITE[$j]}"; fi
  done )
WANT=$(for s in $SUITES; do echo "match $s"; done)
[ -n "$WANT" ] && [ "$N3" = "$WANT" ] && [ ! -s "$T/n3.err" ] && ok \
  || bad "N3 every bh-9258 row parses, is host-timing and matches its fixture (got '$N3', want '$WANT'; $(cat "$T/n3.err" 2>/dev/null))"
# no row is a bare ^FAIL: (it must name the case letters it saw)
grep -qxE '\^FAIL: ?' <<<"$(grep -v '^#' "$NOTES" | cut -f3)" && bad "N3 a row's ERE is a bare ^FAIL:" || ok
N3R=$( TREE="$DIR"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2>&1 >/dev/null | grep -F 'bh-9258.tsv' )
[ -z "$N3R" ] && ok || bad "N3 the real tree skips a bh-9258 row ($N3R)"

echo "selection-gate-host-notes.bh-9258: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

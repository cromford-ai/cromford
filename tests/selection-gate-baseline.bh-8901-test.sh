#!/bin/bash
# tests/selection-gate-baseline.bh-8901-test.sh — BH-8901: the selection gate
# runs each suite that is still red once on the merge base, and a suite that is
# red on the base too is baseline-red and does not fail the gate.
#
# THE BUG. BH-8775 round 5 went GATE_RED on 8 suites that were red on main on
# the test host that day; its diff could not reach them. bin/selection-gate.sh
# made every red that survived the quarantine a red of the head, so a red main
# failed every build.
#
# PINNED. The REAL bin/selection-gate.sh (or $SG, to run this file against an
# older copy) runs with a stub planner and a stub runner. The stub runner prints
# $STUB_DIR/head.out for the head tree and $STUB_DIR/base.out for any other
# tree, and logs each call (kind, the tree's HEAD, the suites). The REAL
# bin/lib/selection-gate.sh sg_block and the REAL resolver fragment run from
# scratch checkouts. No network, one HARNESS and one TMPDIR per case.
#   B1  red on head and base: exit 0, rc 0, red -, baseline-red X, ran 1
#   B2  red on head, green on base: exit 1, red X
#   B3a base rc 125 (a FAIL X line beside it): could-not-run, red X
#   B3b a RUNNER-FAILURE line: could-not-run: runner-failure, red X
#   B3c base past the timeout knob: could-not-run: timeout, red X
#   B3d base FAIL X (rc 127): red X       B3e base BLIND X: red X
#   B3f base names only Y: red X          B3g `FAIL: expected 3`, x.sh.bak: red X
#   B3h the base worktree cannot be made: could-not-run: no-worktree, red X
#   B4  X red on base, Y green on base: red Y, baseline-red X
#   B5  the base result is cached per (base, suite): a second run makes no base
#       call; a cached green stays red; a could-not-run writes no cache
#   B6  knob unset: gate.txt is the 10-line BH-8062 file, one runner call
#   B7  HEAD equals MB: skipped: head-is-base, one runner call, red X
#   B8  X's own file changed in MB..HEAD: never sent to the base, red X
#   B9  a quarantined suite is never sent to the base
#   B10 a cache dir older than the keep window is deleted, a fresh one stays
#   B11 sg_block: rc 0, baseline-red=1 on the log line, the PR-body sentence;
#       knob 0: GATE_RED, rc 6
#   B12 the resolver fragment's verify: SELECTION_GATE_EXIT: 0
#   B13 no worktree and no temp dir left after a run, a could-not-run included
#   B14 the three knob rows: defaults 1, 900, 2, read in bin/lib/selection-gate.sh
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-baseline.bh-8901-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SG="${SG:-$DIR/bin/selection-gate.sh}"
LIB="$DIR/bin/lib/selection-gate.sh"
FRAG="$DIR/bin/blocked-resolver.d/bh-8062-selection-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -r "$SG" ] || { echo "FAIL: $SG is missing"; exit 1; }
X=tests/x.sh; Y=tests/y.sh

# A scratch repo: base commit on main (the gate script, x and y), one change on
# a ticket branch. The gate script rides in the tree for B11 and B12.
R="$T/repo"; mkdir -p "$R/tests" "$R/bin"
g() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }
cp "$SG" "$R/bin/selection-gate.sh"; chmod +x "$R/bin/selection-gate.sh"
echo 'exit 0' > "$R/$X"; echo 'exit 0' > "$R/$Y"
g "$R" init -q -b main; g "$R" add -A; g "$R" commit -qm base
MB=$(g "$R" rev-parse HEAD)
g "$R" checkout -q -b ticket/bh-1; echo b > "$R/b.txt"; g "$R" add -A; g "$R" commit -qm change
# R8: the ticket also edits X's own file. R7: HEAD is the base.
R8="$T/repo8"; cp -a "$R" "$R8"; echo 'exit 1' > "$R8/$X"; g "$R8" add -A; g "$R8" commit -qm 'edit x'
R7="$T/repo7"; cp -a "$R" "$R7"; g "$R7" checkout -q main

cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/x.sh} > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
# The runner stub: head.out / head.rc for $STUB_HEAD_TREE, base.out / base.rc /
# base.sleep for any other tree. One `calls` line per call: kind, HEAD, suites.
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
tree="$1"; shift
k=base; [ "$(cd "$tree" && pwd -P)" = "$(cd "$STUB_HEAD_TREE" && pwd -P)" ] && k=head
echo "$k $(git -C "$tree" rev-parse HEAD 2>/dev/null) $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/$k.out" ] && cat "$STUB_DIR/$k.out"
[ -f "$STUB_DIR/$k.sleep" ] && sleep "$(cat "$STUB_DIR/$k.sleep")"   # determinism: ok the stub runner IS the slow host under test
exit "$(cat "$STUB_DIR/$k.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"

# stub <case> <kind> <rc> <line...> — the runner's answer for that tree kind.
stub() {
  local c="$1" k="$2" rc="$3"; shift 3
  mkdir -p "$T/$c/stub"; printf '%s\n' "$@" > "$T/$c/stub/$k.out"; echo "$rc" > "$T/$c/stub/$k.rc"
}
# run <case> <tree> [VAR=value …] — one gate run into $T/<case>/out, with the
# case's own HARNESS ($T/<case>/h, unless the args set one) and TMPDIR.
run() {
  local c="$1" tr="$2"; shift 2
  mkdir -p "$T/$c/stub" "$T/$c/tmp" "$T/$c/h"
  env -u CI_QUARANTINE -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S -u SELECTION_GATE_BASELINE_KEEP_DAYS \
    HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" REPO_SLUG= STUB_DIR="$T/$c/stub" STUB_HEAD_TREE="$tr" \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    "$@" bash "$SG" --tree "$tr" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
gate() { cat "$T/$1/out/gate.txt" 2>/dev/null; cat "$T/$1/stdout" 2>/dev/null; }
calls() { awk -v k="$2" '$1 == k { n++ } END { print n + 0 }' "$T/$1/stub/calls" 2>/dev/null; }
HFAIL="FAIL $X (rc 1)"

# ── B1: red on head and on base ──────────────────────────────────────────────
stub b1 head 1 "$HFAIL"; stub b1 base 1 "$HFAIL"
run b1 "$R" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 0 ] && [ "$(gv b1 rc)" = 0 ] && [ "$(gv b1 red)" = - ] && [ "$(gv b1 baseline-red)" = "$X" ] && ok \
  || bad "B1 red on head and base: exit 0, rc 0, red -, baseline-red $X (exit $RC; $(gate b1))"
[ "$(gv b1 baseline)" = "ran 1 on ${MB:0:12} (0 cached)" ] && ok || bad "B1 baseline: ran 1 on ${MB:0:12} (0 cached) (got '$(gv b1 baseline)')"
grep -qx "base $MB $X" "$T/b1/stub/calls" 2>/dev/null && ok || bad "B1 the base run is on MB with X only ($(cat "$T/b1/stub/calls" 2>/dev/null))"
[ "$(cat "$T/b1/h/state/selection-gate/baseline/$MB/tests_x.sh" 2>/dev/null)" = red ] && ok || bad "B1 the cache holds red for (MB, X)"
grep -q "baseline-red=$X" "$T/b1/stdout" && ok || bad "B1 the summary line names baseline-red ($(cat "$T/b1/stdout"))"

# ── B2: red on head, green on base ───────────────────────────────────────────
stub b2 head 1 "$HFAIL"; stub b2 base 0 "PASS $X"
run b2 "$R" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 1 ] && [ "$(gv b2 rc)" = 1 ] && [ "$(gv b2 red)" = "$X" ] && [ "$(gv b2 baseline-red)" = - ] && ok \
  || bad "B2 green on base: exit 1, red $X, baseline-red - (exit $RC; $(gate b2))"

# ── B3: the base answer is not a clean red: the suite stays red ──────────────
stub b3a head 1 "$HFAIL"; stub b3a base 125 "$HFAIL" 'remote-gate: no flyctl'
run b3a "$R" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 1 ] && [ "$(gv b3a red)" = "$X" ] && [ "$(gv b3a baseline-red)" = - ] \
  && [ "$(gv b3a baseline)" = "could-not-run: runner-rc-125: remote-gate: no flyctl" ] && ok \
  || bad "B3a base rc 125: red $X, could-not-run: runner-rc-125 with the reason (exit $RC; $(gate b3a))"
[ ! -e "$T/b3a/h/state/selection-gate/baseline/$MB/tests_x.sh" ] && ok || bad "B3a a could-not-run base wrote a cache entry"

stub b3b head 1 "$HFAIL"; stub b3b base 1 "$HFAIL" "RUNNER-FAILURE $Y"
run b3b "$R" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 1 ] && [ "$(gv b3b red)" = "$X" ] && [ "$(gv b3b baseline-red)" = - ] && [ "$(gv b3b baseline)" = "could-not-run: runner-failure" ] && ok \
  || bad "B3b a RUNNER-FAILURE line: red $X, could-not-run: runner-failure (exit $RC; $(gate b3b))"

stub b3c head 1 "$HFAIL"; stub b3c base 1 "$HFAIL"; echo 6 > "$T/b3c/stub/base.sleep"
run b3c "$R" SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=2
[ "$RC" = 1 ] && [ "$(gv b3c red)" = "$X" ] && [ "$(gv b3c baseline-red)" = - ] && [ "$(gv b3c baseline)" = "could-not-run: timeout" ] && ok \
  || bad "B3c base past the timeout: red $X, could-not-run: timeout (exit $RC; $(gate b3c))"

b3red() {   # <case> <base rc> <base line...> — X stays red, nothing is baseline-red
  local c="$1" brc="$2"; shift 2
  stub "$c" head 1 "$HFAIL"; stub "$c" base "$brc" "$@"
  run "$c" "$R" SELECTION_GATE_BASELINE_RUN=1
  [ "$RC" = 1 ] && [ "$(gv "$c" red)" = "$X" ] && [ "$(gv "$c" baseline-red)" = - ] && ok \
    || bad "$c base [$*]: red $X, baseline-red - (exit $RC; $(gate "$c"))"
}
b3red b3d 1 "FAIL $X (rc 127)"
b3red b3e 0 "BLIND $X (printed no merge base, rc 0)"
b3red b3f 1 "FAIL $Y (rc 1)"
b3red b3g 1 'FAIL: expected 3' "FAIL $X.bak (rc 1)" "FAIL $X (rc 1) trailing"

# B3h: the base worktree cannot be made (.git/worktrees is a file here).
R3H="$T/repo3h"; cp -a "$R" "$R3H"; scratch_rm "$R3H/.git/worktrees"; : > "$R3H/.git/worktrees"
stub b3h head 1 "$HFAIL"; stub b3h base 1 "$HFAIL"
run b3h "$R3H" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 1 ] && [ "$(gv b3h red)" = "$X" ] && [ "$(gv b3h baseline)" = "could-not-run: no-worktree" ] && [ "$(calls b3h base)" = 0 ] && ok \
  || bad "B3h no worktree: red $X, could-not-run: no-worktree, no base call (exit $RC; $(gate b3h))"

# ── B4: two reds, one red on base, one green on base ─────────────────────────
stub b4 head 2 "$HFAIL" "FAIL $Y (rc 1)"; stub b4 base 1 "$HFAIL" "PASS $Y"
run b4 "$R" SELECTION_GATE_BASELINE_RUN=1 STUB_SUITES="$X $Y"
[ "$RC" = 1 ] && [ "$(gv b4 red)" = "$Y" ] && [ "$(gv b4 baseline-red)" = "$X" ] && ok \
  || bad "B4 red $Y, baseline-red $X (exit $RC; $(gate b4))"

# ── B5: the cache ────────────────────────────────────────────────────────────
stub b5 head 1 "$HFAIL"; stub b5 base 1 "$HFAIL"
run b5 "$R" SELECTION_GATE_BASELINE_RUN=1 HARNESS="$T/b5/h"
stub b5 base 0 "PASS $X"; : > "$T/b5/stub/calls"
run b5 "$R" SELECTION_GATE_BASELINE_RUN=1 HARNESS="$T/b5/h"
[ "$RC" = 0 ] && [ "$(gv b5 baseline-red)" = "$X" ] && [ "$(gv b5 baseline)" = "ran 1 on ${MB:0:12} (1 cached)" ] && ok \
  || bad "B5 the second run reads the cached red: baseline-red $X, (1 cached) (exit $RC; $(gate b5))"
[ "$(calls b5 base)" = 0 ] && ok || bad "B5 the second run made a base call ($(cat "$T/b5/stub/calls"))"
# A cached green stays red, and is never re-run.
stub b5g head 1 "$HFAIL"; stub b5g base 0 "PASS $X"
run b5g "$R" SELECTION_GATE_BASELINE_RUN=1 HARNESS="$T/b5g/h"
stub b5g base 1 "$HFAIL"; : > "$T/b5g/stub/calls"
run b5g "$R" SELECTION_GATE_BASELINE_RUN=1 HARNESS="$T/b5g/h"
[ "$RC" = 1 ] && [ "$(gv b5g red)" = "$X" ] && [ "$(calls b5g base)" = 0 ] && ok \
  || bad "B5 a cached green stays red with no base call (exit $RC; $(gate b5g); $(cat "$T/b5g/stub/calls"))"

# ── B6: the knob unset is the BH-8062 gate ───────────────────────────────────
stub b6 head 1 "$HFAIL"; stub b6 base 1 "$HFAIL"
run b6 "$R"
[ "$RC" = 1 ] && [ "$(grep -c . "$T/b6/out/gate.txt")" = 10 ] && [ "$(tail -n 1 "$T/b6/out/gate.txt" | cut -d: -f1)" = host-noted ] && ok \
  || bad "B6 knob unset: 10 lines, host-noted: last, exit 1 (exit $RC; $(gate b6))"
[ "$(grep -c . "$T/b6/stub/calls")" = 1 ] && ! grep -q baseline "$T/b6/stdout" && ok || bad "B6 knob unset: one runner call, no baseline word ($(cat "$T/b6/stub/calls"))"

# ── B7: HEAD is the base ─────────────────────────────────────────────────────
stub b7 head 1 "$HFAIL"; stub b7 base 1 "$HFAIL"
run b7 "$R7" SELECTION_GATE_BASELINE_RUN=1
[ "$RC" = 1 ] && [ "$(gv b7 red)" = "$X" ] && [ "$(gv b7 baseline)" = "skipped: head-is-base" ] && [ "$(grep -c . "$T/b7/stub/calls")" = 1 ] && ok \
  || bad "B7 HEAD is MB: skipped: head-is-base, red $X, one call (exit $RC; $(gate b7); $(cat "$T/b7/stub/calls"))"

# ── B8: the diff edits X's own file ──────────────────────────────────────────
stub b8 head 2 "$HFAIL" "FAIL $Y (rc 1)"; stub b8 base 2 "$HFAIL" "FAIL $Y (rc 1)"
run b8 "$R8" SELECTION_GATE_BASELINE_RUN=1 STUB_SUITES="$X $Y"
[ "$RC" = 1 ] && [ "$(gv b8 red)" = "$X" ] && [ "$(gv b8 baseline-red)" = "$Y" ] && ok \
  || bad "B8 a changed suite stays red: red $X, baseline-red $Y (exit $RC; $(gate b8))"
grep -qw "$X" <<<"$(grep '^base ' "$T/b8/stub/calls")" && bad "B8 X was sent to the base ($(cat "$T/b8/stub/calls"))" || ok

# ── B9: a quarantined red is never sent to the base ──────────────────────────
stub b9 head 2 "$HFAIL" "FAIL $Y (rc 1)"; stub b9 base 2 "$HFAIL" "FAIL $Y (rc 1)"
run b9 "$R" SELECTION_GATE_BASELINE_RUN=1 STUB_SUITES="$X $Y" CI_QUARANTINE="$X"
[ "$RC" = 0 ] && [ "$(gv b9 noted)" = "$X" ] && [ "$(gv b9 baseline-red)" = "$Y" ] && grep -qx "base $MB $Y" "$T/b9/stub/calls" && ok \
  || bad "B9 noted $X, baseline-red $Y, base argv $Y only (exit $RC; $(gate b9); $(cat "$T/b9/stub/calls"))"

# ── B10: retention ───────────────────────────────────────────────────────────
CD="$T/b10/h/state/selection-gate/baseline"; mkdir -p "$CD/oldsha" "$CD/freshsha"
echo red > "$CD/oldsha/tests_x.sh"; touch -d '10 days ago' "$CD/oldsha/tests_x.sh" "$CD/oldsha"
stub b10 head 1 "$HFAIL"; stub b10 base 1 "$HFAIL"
run b10 "$R" SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_KEEP_DAYS=2
[ ! -e "$CD/oldsha" ] && [ -d "$CD/freshsha" ] && [ -f "$CD/$MB/tests_x.sh" ] && ok \
  || bad "B10 the old cache dir is gone, the fresh ones stay ($(ls "$CD" 2>/dev/null | tr '\n' ' '))"

# ── B13: nothing left behind ─────────────────────────────────────────────────
for c in b1 b3a b3c; do
  [ "$(git -C "$R" worktree list | grep -c .)" = 1 ] && [ -z "$(ls -A "$T/$c/tmp" 2>/dev/null)" ] && ok \
    || bad "B13 $c left a worktree or a temp dir ($(git -C "$R" worktree list); $(ls -A "$T/$c/tmp"))"
done

# ── B11: the real sg_block from a checkout where HEAD is not the base ────────
HH="$T/hh"; mkdir -p "$HH/bin"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
lib() {
  local c="$1"; shift
  C="$T/c/$c"; mkdir -p "$C/build" "$C/stub" "$C/tmp"; cp "$T/b1/stub/head.out" "$T/b1/stub/head.rc" "$T/b1/stub/base.out" "$T/b1/stub/base.rc" "$C/stub/"
  ( cd "$R" || exit 99
    env -u SELECTION_GATE -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S -u SELECTION_GATE_BASELINE_KEEP_DAYS -u CI_QUARANTINE \
      HARNESS="$HH" BUILD="$C/build" PROJECT=demo-os KEY=BH-8901 TICKET=8901 BASE=main JOBS_URL='' REPO_SLUG= TMPDIR="$C/tmp" \
      STUB_DIR="$C/stub" STUB_HEAD_TREE="$R" SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- "$@" bash -c '
      STAMP() { echo 2026-11-01T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      . "$1" || exit 98
      sg_block; echo "$?" > "$BUILD/rc"
      printf "%s" "$SG_MARKER" > "$BUILD/marker"' _ "$LIB"
  ) > "$C/out" 2>&1
}
lib b11
HS=$(g "$R" rev-parse HEAD)
[ "$(cat "$T/c/b11/build/rc" 2>/dev/null)" = 0 ] && [ ! -e "$T/c/b11/build/RESULT" ] && ok \
  || bad "B11 sg_block rc 0, no RESULT (rc $(cat "$T/c/b11/build/rc" 2>/dev/null); $(cat "$T/c/b11/build/RESULT" 2>/dev/null); $(cat "$T/c/b11/out"))"
grep -q 'SELECTION-GATE rc=0 suites=1 red=- exit=0 baseline-red=1$' "$T/c/b11/build/pipeline.log" 2>/dev/null && ok \
  || bad "B11 the log line carries baseline-red=1 ($(cat "$T/c/b11/build/pipeline.log" 2>/dev/null))"
[ "$(head -n 1 "$T/c/b11/build/marker" 2>/dev/null)" = "<!-- selection-gate: head=$HS suites=1 rc=0 -->" ] \
  && grep -qF "Selection gate: 1 suite(s) also failed on the base ${MB:0:12} and did not count (baseline-red): \`$X\`." "$T/c/b11/build/marker" && ok \
  || bad "B11 SG_MARKER is the exact marker line, then the baseline-red sentence ($(cat "$T/c/b11/build/marker" 2>/dev/null))"
lib b11off SELECTION_GATE_BASELINE_RUN=0
[ "$(cat "$T/c/b11off/build/rc" 2>/dev/null)" = 6 ] && grep -q "^GATE_RED 1 red: $X" "$T/c/b11off/build/RESULT" 2>/dev/null && ok \
  || bad "B11 knob 0: rc 6, GATE_RED 1 red: $X (rc $(cat "$T/c/b11off/build/rc" 2>/dev/null); $(cat "$T/c/b11off/build/RESULT" 2>/dev/null))"

# ── B12: the resolver fragment's verify ──────────────────────────────────────
mkdir -p "$T/b12/stub" "$T/b12/tmp"; cp "$T/b1/stub/"*.out "$T/b1/stub/"*.rc "$T/b12/stub/"
O12=$(env -u SELECTION_GATE -u SELECTION_GATE_BASELINE_RUN -u CI_QUARANTINE H="$HH" HARNESS="$HH" TMPDIR="$T/b12/tmp" REPO_SLUG= JOBS_URL='' \
  STUB_DIR="$T/b12/stub" STUB_HEAD_TREE="$R" SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
  bash -c '. "$1" || exit 98; br_sg_verify "$2" main "$3" demo-os' _ "$FRAG" "$R" "$T/b12/od" 2>&1)
grep -qx 'SELECTION_GATE_EXIT: 0' <<<"$O12" && ok || bad "B12 the resolver verify is green on a baseline red ($O12; $(cat "$T/b12/od/gate.txt" 2>/dev/null))"

# ── B14: the knob rows ───────────────────────────────────────────────────────
KD="$DIR/catalog/lanes.d/fly-pool.knobs.d"
for kv in SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 SELECTION_GATE_BASELINE_KEEP_DAYS=2; do
  k=${kv%%=*}; d=${kv#*=}
  [ "$(jq -r '.default' "$KD/$k.json" 2>/dev/null)" = "$d" ] && [ "$(jq -r '.read_in' "$KD/$k.json" 2>/dev/null)" = bin/lib/selection-gate.sh ] \
    && [ "$(jq -r '.env' "$KD/$k.json" 2>/dev/null)" = "$k" ] && ok || bad "B14 $k.json: default $d, read_in bin/lib/selection-gate.sh"
done

echo "selection-gate-baseline.bh-8901: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

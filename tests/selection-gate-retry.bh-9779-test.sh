#!/bin/bash
# tests/selection-gate-retry.bh-9779-test.sh — BH-9779 step 7: a selection-gate
# red only on suites outside this change's impact set runs those suites once
# more; a suite that passes then leaves red: and gets one ci_flakes row.
#
# The REAL bin/selection-gate.sh and bin/lib/selection-gate-retry.sh run from a
# scratch repo, with a stub planner, a stub runner that answers per call
# (call<N>.out / .rc / .sleep), a stub impact command and a stub
# bin/jobs-client.sh that logs its arguments. The REAL bin/lib/selection-gate.sh
# sg_block runs G11 and G12. No network.
#   G1  outside red, FAIL then PASS: rc 0, red -, retry ran 1 green, 2 runner
#       calls, one metric-flake row
#   G2  FAIL twice: rc 1, red, retry red, no metric-flake
#   G3  a red with a `source` row (inside): rc 1, one call, skipped: inside 1
#   G4  the retry run is rc 125 / RUNNER-FAILURE / past its timeout: rc 1,
#       could-not-run
#   G5  an impact `full` row, rc 1 or no output: no retry
#   G6  one inside and one outside red: no retry
#   G7  4 outside reds at max 3: skipped: 4 > 3
#   G8  no REPO_SLUG: rc 0 and flake-record: failed
#   G9  knob unset: no retry: line, one call, the same selection.txt;
#       fresh-main: stays the last line
#   G10 a BLIND line on the retry keeps the suite red
#   G11 sg_block: rc 0, no GATE_RED, the marker sentence
#   G12 the row lane.fly-pool.selection_gate_retry_outside = 0: GATE_RED, one call
#   K1  the registry defaults equal the fallbacks
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-retry.bh-9779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=1794900000
A=tests/a.sh; B=tests/b.sh
export GIT_AUTHOR_DATE="2026-11-17T02:00:00Z" GIT_COMMITTER_DATE="2026-11-17T02:00:00Z"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

# The repo: the gate and its retry lib on main, one change on a ticket branch.
R="$T/repo"; mkdir -p "$R/tests"
scratch_install_closure bin/selection-gate.sh "$R" >/dev/null || { echo "FAIL: setup: closure install"; exit 1; }
[ -r "$R/bin/lib/selection-gate-retry.sh" ] && ok || bad "setup: the retry lib rides the gate's closure"
for s in a b c d; do echo 'exit 0' > "$R/tests/$s.sh"; done
git -C "$R" init -q -b main; git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" checkout -q -b ticket/bh-9779; echo change > "$R/b.txt"; git -C "$R" add -A; git -C "$R" commit -qm change
HS=$(git -C "$R" rev-parse HEAD)

cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/a.sh} > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
# The runner: a call on the head tree is call 1, 2, ... (call<N>.out/.rc/.sleep);
# a call on any other tree (the base run of sg_block) answers base.out, rc 0.
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
tree="$1"; shift
if [ "$(cd "$tree" && pwd -P)" != "$(cd "$STUB_HEAD_TREE" && pwd -P)" ]; then
  echo "base $*" >> "$STUB_DIR/calls"; cat "$STUB_DIR/base.out" 2>/dev/null; exit 0
fi
n=$(( $(grep -c '^head ' "$STUB_DIR/calls" 2>/dev/null || true) + 1 ))
echo "head $n $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/call$n.out" ] && cat "$STUB_DIR/call$n.out"
[ -f "$STUB_DIR/call$n.sleep" ] && sleep "$(cat "$STUB_DIR/call$n.sleep")"   # determinism: ok — the stub IS the slow host under test
exit "$(cat "$STUB_DIR/call$n.rc" 2>/dev/null || echo 0)"
SH
cat > "$T/impact.sh" <<'SH'
#!/bin/bash
echo "impact $*" >> "$STUB_DIR/impact.log"
[ -f "$STUB_DIR/impact.out" ] && cat "$STUB_DIR/impact.out"
exit "$(cat "$STUB_DIR/impact.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/plan.sh" "$T/runner.sh" "$T/impact.sh"

# A harness root with a stub jobs client that logs each argument list.
H="$T/h"; mkdir -p "$H/bin" "$H/state"
# jc_stub <root> — the stub client, written (never copied) into <root>/bin.
jc_stub() {
  mkdir -p "$1/bin"
  cat > "$1/bin/jobs-client.sh" <<'SH'
#!/bin/bash
[ "${1:-}" = metric-flake ] || exit 1
printf '%s|' "$@" >> "$STUB_DIR/jobs.log"; echo >> "$STUB_DIR/jobs.log"
exit "${JC_RC:-0}"
SH
}
jc_stub "$H"

# stub <case> <n> <rc> <line...> — the runner's answer to head call n.
stub() { local c="$1" n="$2" rc="$3"; shift 3; mkdir -p "$T/$c/stub"; printf '%s\n' "$@" > "$T/$c/stub/call$n.out"; echo "$rc" > "$T/$c/stub/call$n.rc"; }
# imp <case> <rc> <row...> — the impact command's rows (printf %b, so \t works).
imp() { local c="$1" rc="$2"; shift 2; mkdir -p "$T/$c/stub"; : > "$T/$c/stub/impact.out"; local r; for r in "$@"; do printf '%b\n' "$r" >> "$T/$c/stub/impact.out"; done; echo "$rc" > "$T/$c/stub/impact.rc"; }
run() { # run <case> [VAR=value ...]
  local c="$1"; shift
  mkdir -p "$T/$c/stub" "$T/$c/tmp"
  env -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_SUITE_QUARANTINE -u SELECTION_GATE_FRESH_MAIN -u SELECTION_GATE_SUITE_REUSE \
    -u SELECTION_GATE_RETRY_TIMEOUT_S -u SELECTION_GATE_RETRY_MAX \
    HARNESS="$H" TMPDIR="$T/$c/tmp" REPO_SLUG=fixture-org/fixture-repo STUB_DIR="$T/$c/stub" STUB_HEAD_TREE="$R" \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" SELECTION_GATE_IMPACT="$T/impact.sh" CI_QUARANTINE=- \
    SELECTION_GATE_RETRY_OUTSIDE=1 "$@" bash "$R/bin/selection-gate.sh" --tree "$R" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
# A missing log is 0 lines (grep -c on a missing file prints nothing).
calls() { cat "$T/$1/stub/calls" 2>/dev/null | grep -c "^head "; }
flakes() { cat "$T/$1/stub/jobs.log" 2>/dev/null | grep -c '^metric-flake|'; }
gate() { cat "$T/$1/out/gate.txt" "$T/$1/stdout" 2>/dev/null; }
F1="FAIL $A (rc 1)"
OUTSIDE="$A\talways\t*"

# ── G1 ───────────────────────────────────────────────────────────────────────
stub g1 1 1 "$F1"; stub g1 2 0 "PASS $A"; imp g1 0 "$OUTSIDE"
run g1
[ "$RC" = 0 ] && [ "$(gv g1 rc)" = 0 ] && [ "$(gv g1 red)" = - ] && ok || bad "G1 rc 0, red - (exit $RC): $(gate g1)"
[ "$(gv g1 retry)" = "ran 1: green $A; red -" ] && ok || bad "G1 retry: ran 1: green $A; red - (got '$(gv g1 retry)')"
[ "$(calls g1)" = 2 ] && grep -qx "head 2 $A" "$T/g1/stub/calls" && ok || bad "G1 two runner calls, the second with $A only: $(cat "$T/g1/stub/calls")"
[ "$(flakes g1)" = 1 ] && grep -qx "metric-flake|fixture-org/fixture-repo|selection-gate|$A|$HS||flake|" "$T/g1/stub/jobs.log" && ok \
  || bad "G1 one metric-flake row (selection-gate $A <head> flake): $(cat "$T/g1/stub/jobs.log" 2>/dev/null)"
grep -q "^impact select --why --map-only --changed " "$T/g1/stub/impact.log" && grep -qx 'b.txt' "$T/g1/out/retry-changed.txt" && ok \
  || bad "G1 the impact command gets the diff's changed list: $(cat "$T/g1/stub/impact.log" 2>/dev/null)"

# ── G2 ───────────────────────────────────────────────────────────────────────
stub g2 1 1 "$F1"; stub g2 2 1 "$F1"; imp g2 0 "$OUTSIDE"
run g2
[ "$RC" = 1 ] && [ "$(gv g2 red)" = "$A" ] && [ "$(gv g2 retry)" = "ran 1: green -; red $A" ] && [ "$(flakes g2)" = 0 ] && ok \
  || bad "G2 red twice is red, no flake row (exit $RC): $(gate g2)"

# ── G3 ───────────────────────────────────────────────────────────────────────
stub g3 1 1 "$F1"; imp g3 0 "$A\tsource\tb.txt"
run g3
[ "$RC" = 1 ] && [ "$(calls g3)" = 1 ] && [ "$(gv g3 retry)" = "skipped: inside 1" ] && ok || bad "G3 an inside red: no retry (exit $RC): $(gate g3)"
for k in self reads named learned closure regression; do
  stub "g3$k" 1 1 "$F1"; imp "g3$k" 0 "$A\t$k\tb.txt"; run "g3$k"
  [ "$RC" = 1 ] && [ "$(calls "g3$k")" = 1 ] && ok || bad "G3 a $k row is inside (exit $RC): $(gate "g3$k")"
done

# ── G4 ───────────────────────────────────────────────────────────────────────
stub g4a 1 1 "$F1"; stub g4a 2 125 "remote-gate: fixture host failure"; imp g4a 0 "$OUTSIDE"; run g4a
[ "$RC" = 1 ] && [ "$(gv g4a retry)" = "could-not-run: runner-rc-125" ] && [ "$(gv g4a red)" = "$A" ] && ok || bad "G4 rc 125 (exit $RC): $(gate g4a)"
stub g4b 1 1 "$F1"; stub g4b 2 0 "PASS $A" "RUNNER-FAILURE $A"; imp g4b 0 "$OUTSIDE"; run g4b
[ "$RC" = 1 ] && [ "$(gv g4b retry)" = "could-not-run: runner-failure" ] && ok || bad "G4 RUNNER-FAILURE (exit $RC): $(gate g4b)"
stub g4c 1 1 "$F1"; stub g4c 2 0 "PASS $A"; echo 4 > "$T/g4c/stub/call2.sleep"; imp g4c 0 "$OUTSIDE"; run g4c SELECTION_GATE_RETRY_TIMEOUT_S=1
[ "$RC" = 1 ] && [ "$(gv g4c retry)" = "could-not-run: timeout" ] && ok || bad "G4 past the retry timeout (exit $RC): $(gate g4c)"

# ── G5 ───────────────────────────────────────────────────────────────────────
stub g5a 1 1 "$F1"; imp g5a 0 "$A\tfull\tfull: unknown reach (x)"; run g5a
stub g5b 1 1 "$F1"; imp g5b 1 "$OUTSIDE"; run g5b
stub g5c 1 1 "$F1"; imp g5c 0; run g5c
for c in g5a g5b g5c; do
  RCC=$(gv "$c" rc)
  [ "$RCC" = 1 ] && [ "$(calls "$c")" = 1 ] && [[ "$(gv "$c" retry)" == "skipped: inside 1"* ]] && ok || bad "G5 $c: no retry: $(gate "$c")"
done

# ── G6 ───────────────────────────────────────────────────────────────────────
stub g6 1 1 "$F1" "FAIL $B (rc 1)"; imp g6 0 "$OUTSIDE" "$B\tsource\tb.txt"
run g6 STUB_SUITES="$A $B"
[ "$RC" = 1 ] && [ "$(calls g6)" = 1 ] && [ "$(gv g6 retry)" = "skipped: inside 1" ] && [ "$(gv g6 red)" = "$A,$B" ] && ok || bad "G6 mixed: no retry (exit $RC): $(gate g6)"

# ── G7 ───────────────────────────────────────────────────────────────────────
stub g7 1 1 "$F1" "FAIL $B (rc 1)" "FAIL tests/c.sh (rc 1)" "FAIL tests/d.sh (rc 1)"; imp g7 0 "$OUTSIDE"
run g7 STUB_SUITES="$A $B tests/c.sh tests/d.sh" SELECTION_GATE_RETRY_MAX=3
[ "$RC" = 1 ] && [ "$(calls g7)" = 1 ] && [ "$(gv g7 retry)" = "skipped: 4 > 3" ] && ok || bad "G7 4 outside reds at max 3 (exit $RC): $(gate g7)"
stub g7b 1 1 "$F1" "FAIL $B (rc 1)"; stub g7b 2 0 "PASS $A" "PASS $B"; imp g7b 0 "$OUTSIDE"
run g7b STUB_SUITES="$A $B" SELECTION_GATE_RETRY_MAX=3
[ "$RC" = 0 ] && [ "$(gv g7b retry)" = "ran 2: green $A,$B; red -" ] && [ "$(flakes g7b)" = 2 ] && ok || bad "G7 two outside reds (no row at all for $B) both retried (exit $RC): $(gate g7b)"

# ── G8 ───────────────────────────────────────────────────────────────────────
stub g8 1 1 "$F1"; stub g8 2 0 "PASS $A"; imp g8 0 "$OUTSIDE"
run g8 REPO_SLUG=
[ "$RC" = 0 ] && [ "$(gv g8 retry)" = "ran 1: green $A; red - flake-record: failed $A" ] && ok || bad "G8 no REPO_SLUG: green stands, the write is named (exit $RC): $(gate g8)"
stub g8b 1 1 "$F1"; stub g8b 2 0 "PASS $A"; imp g8b 0 "$OUTSIDE"
run g8b JC_RC=1
[ "$RC" = 0 ] && [[ "$(gv g8b retry)" == *"flake-record: failed $A" ]] && ok || bad "G8 a failed write is named (exit $RC): $(gate g8b)"

# ── G9 ───────────────────────────────────────────────────────────────────────
stub g9 1 1 "$F1"; stub g9 2 0 "PASS $A"; imp g9 0 "$OUTSIDE"
run g9 SELECTION_GATE_RETRY_OUTSIDE=0
[ "$RC" = 1 ] && [ "$(calls g9)" = 1 ] && ! grep -q '^retry:' "$T/g9/out/gate.txt" && [ "$(wc -l < "$T/g9/out/gate.txt")" = 10 ] && ok \
  || bad "G9 knob 0: no retry line, one call, the 10-line file (exit $RC): $(gate g9)"
cmp -s "$T/g9/out/selection.txt" "$T/g1/out/selection.txt" && ok || bad "G9 the selection is the same with the knob at 0 and at 1"
stub g9b 1 1 "$F1"; stub g9b 2 0 "PASS $A"; imp g9b 0 "$OUTSIDE"
run g9b SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
[ "$(tail -n 1 "$T/g9b/out/gate.txt" | cut -d: -f1)" = fresh-main ] && grep -q '^retry: ran 1' "$T/g9b/out/gate.txt" && ok \
  || bad "G9 fresh-main: stays the last line: $(gate g9b)"

# ── G10 ──────────────────────────────────────────────────────────────────────
stub g10 1 1 "$F1"; stub g10 2 0 "BLIND $A"; imp g10 0 "$OUTSIDE"
run g10
[ "$RC" = 1 ] && [ "$(gv g10 retry)" = "ran 1: green -; red $A" ] && [ "$(flakes g10)" = 0 ] && ok || bad "G10 BLIND keeps it red (exit $RC): $(gate g10)"

# ── G11 / G12: the real sg_block ─────────────────────────────────────────────
HH="$T/hh"; mkdir -p "$HH/state"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
jc_stub "$HH"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$HH/state/settings-cache.json"; }
# The other steps off by row, so the head calls are the main run and the retry.
OFF='"lane.fly-pool.selection_gate_baseline_run":"0","lane.fly-pool.selection_gate_suite_reuse":"0","lane.fly-pool.selection_gate_suite_quarantine":"0","lane.fly-pool.selection_gate_fresh_main":"0"'
lib() {
  local c="$1"; C="$T/c/$c"; scratch_rm "$C"; mkdir -p "$C/build" "$C/stub" "$C/tmp"
  cp "$T/g1/stub/call1.out" "$T/g1/stub/call1.rc" "$T/g1/stub/call2.out" "$T/g1/stub/call2.rc" "$T/g1/stub/impact.out" "$T/g1/stub/impact.rc" "$C/stub/"
  ( cd "$R" || exit 99
    env -u SELECTION_GATE -u SELECTION_GATE_RETRY_OUTSIDE -u CI_QUARANTINE \
      HARNESS="$HH" BUILD="$C/build" PROJECT=demo-os KEY=BH-9779 TICKET=9779 BASE=main REPO_SLUG=fixture-org/fixture-repo TMPDIR="$C/tmp" \
      LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW" STUB_DIR="$C/stub" STUB_HEAD_TREE="$R" \
      SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" SELECTION_GATE_IMPACT="$T/impact.sh" CI_QUARANTINE=- bash -c '
      STAMP() { echo 2026-11-17T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      . "$1" || exit 98
      sg_block; echo "$?" > "$BUILD/rc"
      printf "%s" "$SG_MARKER" > "$BUILD/marker"' _ "$DIR/bin/lib/selection-gate.sh"
  ) > "$C/out" 2>&1
}
settings "{$OFF}"
lib g11
[ "$(cat "$T/c/g11/build/rc" 2>/dev/null)" = 0 ] && [ ! -e "$T/c/g11/build/RESULT" ] && ok \
  || bad "G11 sg_block rc 0, no GATE_RED (rc $(cat "$T/c/g11/build/rc" 2>/dev/null); $(cat "$T/c/g11/build/RESULT" 2>/dev/null); $(cat "$T/c/g11/out"); $(cat "$T/c/g11/build/gate.txt" 2>/dev/null))"
[ "$(head -n 1 "$T/c/g11/build/marker" 2>/dev/null)" = "<!-- selection-gate: head=$HS suites=1 rc=0 -->" ] \
  && grep -qF "Selection gate: 1 suite(s) failed once outside this change's impact set and passed on one retry (flaky, recorded): \`$A\`." "$T/c/g11/build/marker" && ok \
  || bad "G11 the marker, then the retry sentence: $(cat "$T/c/g11/build/marker" 2>/dev/null)"
[ "$(grep -c '^metric-flake|' "$T/c/g11/stub/jobs.log" 2>/dev/null)" = 1 ] && ok || bad "G11 one flake row: $(cat "$T/c/g11/stub/jobs.log" 2>/dev/null)"
settings "{$OFF,\"lane.fly-pool.selection_gate_retry_outside\":\"0\"}"
lib g12
[ "$(cat "$T/c/g12/build/rc" 2>/dev/null)" = 6 ] && grep -q "^GATE_RED 1 red: $A" "$T/c/g12/build/RESULT" 2>/dev/null \
  && [ "$(grep -c '^head ' "$T/c/g12/stub/calls")" = 1 ] && ok \
  || bad "G12 the row at 0: GATE_RED, one runner call (rc $(cat "$T/c/g12/build/rc" 2>/dev/null); $(cat "$T/c/g12/build/RESULT" 2>/dev/null); $(cat "$T/c/g12/stub/calls" 2>/dev/null))"

# ── K1 ───────────────────────────────────────────────────────────────────────
KD="$DIR/catalog/lanes.d/fly-pool.knobs.d"
for kv in SELECTION_GATE_RETRY_OUTSIDE=1 SELECTION_GATE_RETRY_TIMEOUT_S=600 SELECTION_GATE_RETRY_MAX=3; do
  k=${kv%%=*}; d=${kv#*=}
  [ "$(jq -r .default "$KD/$k.json" 2>/dev/null)" = "$d" ] && grep -q "_sg_knob $k $d)" "$DIR/bin/lib/selection-gate.sh" && ok \
    || bad "K1 $k: the row default and the lib fallback are $d"
done

echo "selection-gate-retry.bh-9779: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

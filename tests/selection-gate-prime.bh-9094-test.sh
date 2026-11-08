#!/bin/bash
# tests/selection-gate-prime.bh-9094-test.sh — BH-9094: an hourly hub lane
# primes the selection gate's base-run cache for the current origin/main sha,
# and the pool gates read it through a relayed state/selection-gate/prime.tsv.
#
# THE BUG. On 2026-11-04, 25 of 38 GATE_REDs had `baseline: could-not-run:
# timeout`. Nothing filled state/selection-gate/baseline except a gate's own
# base run on its own machine, and every cromford gate runs on a fresh
# pool machine, so every base run was a cold run of every red suite.
#
# PINNED. The REAL bin/selection-gate-prime.sh runs against a scratch origin
# (a local bare repo) with a stub runner. The REAL bin/selection-gate.sh then
# runs with a stub planner and a stub runner (the BH-8901 suite's shape). The
# REAL bin/lib/sg-prime-relay.sh runs with a stub mput. No network, one
# HARNESS and one TMPDIR per case.
#   P1  X red 3 times, Y once, SUITES=2: one runner call `X Y` on the main sha;
#       cache red/green, .primed, 2 prime.tsv rows, the `primed` log line
#   P2  the top-N decision table, through --dry-run; nothing written
#   P3  could-not-run (rc 125, a RUNNER-FAILURE line, past the timeout): no
#       cache, no .primed, prime.tsv unchanged, one `could-not-run` log line
#   P4  a second run on the same sha: 0 runner calls, `already primed`
#   P5  PASS / FAIL rc 1 / FAIL rc 127 / BLIND / no line: green, red, none x3
#   P6  hub round-trip: prime, then the real gate: baseline-red X, 0 base calls
#   P7  pool round-trip: only prime.tsv in a fresh HARNESS: the same, (1 cached)
#   P8  another sha, `maybe`, a 12-hex prefix, a CRLF row, a near-miss name:
#       not a hit (1 base call). P8b a per-file green beats a prime.tsv red
#   P9  `bin/selection-gate.sh --classify` is the gate's own classifier
#   P10 no worktree and no temp dir left, after success and after could-not-run
#   P11 SUITES=0 and SUITES=abc: exit 1, one ALERTS line, 0 runner calls
#   P12 every SELECTION_GATE_PRIME_* read has its knob row with the same
#       default; the cron line runs behind hub-lease.sh check
#   P13 retention by KEEP_DAYS; prime.tsv holds at most RELAY_SHAS shas
#   P14 the relay: put once per mtime, cromford only, retry after a failed
#       put; bin/fly-pool.sh calls it in the live-machine refresh block
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-prime.bh-9094-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PRIME="$DIR/bin/selection-gate-prime.sh"
SG="$DIR/bin/selection-gate.sh"
RELAY="$DIR/bin/lib/sg-prime-relay.sh"
LANE_JSON="$DIR/catalog/lanes.d/selection-gate-prime.json"
CRON="$DIR/cron/lanes/779-selection-gate-prime.cron"
FLYPOOL="$DIR/bin/fly-pool.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
g() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }
X=tests/x.sh; Y=tests/y.sh

# The origin: one commit on main with the suites the cases name. tests/h.sh is
# never in the tree (a suite gone from main).
ORIGIN="$T/origin.git"; SEED="$T/seed"
mkdir -p "$SEED/tests"
for s in a b c d e f g x y; do echo 'exit 0' > "$SEED/tests/$s.sh"; done
g "$SEED" init -q -b main; g "$SEED" add -A; g "$SEED" commit -qm base
git clone -q --bare "$SEED" "$ORIGIN"
MAIN=$(g "$SEED" rev-parse HEAD)

# The gate's tree: a ticket branch one commit past origin/main.
CO="$T/co"; git clone -q "$ORIGIN" "$CO"
g "$CO" checkout -q -b ticket/bh-1; echo b > "$CO/b.txt"; g "$CO" add -A; g "$CO" commit -qm change

# The prime runner stub: one `calls` line per call (the tree's HEAD, P, the
# suites); prints $STUB_DIR/out, sleeps $STUB_DIR/sleep, exits $STUB_DIR/rc.
cat > "$T/prunner.sh" <<'SH'
#!/bin/bash
tree="$1"; shift
echo "$(git -C "$tree" rev-parse HEAD 2>/dev/null) P=${REMOTE_GATE_P:-} $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/out" ] && cat "$STUB_DIR/out"
[ -f "$STUB_DIR/sleep" ] && sleep "$(cat "$STUB_DIR/sleep")"   # determinism: ok the stub runner IS the slow host under test
exit "$(cat "$STUB_DIR/rc" 2>/dev/null || echo 0)"
SH
# The gate's planner and runner stubs (the BH-8901 shape): head.out / head.rc
# for $STUB_HEAD_TREE, base.out / base.rc for any other tree.
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/x.sh} > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
cat > "$T/grunner.sh" <<'SH'
#!/bin/bash
tree="$1"; shift
k=base; [ "$(cd "$tree" && pwd -P)" = "$(cd "$STUB_HEAD_TREE" && pwd -P)" ] && k=head
echo "$k $(git -C "$tree" rev-parse HEAD 2>/dev/null) $*" >> "$STUB_DIR/gcalls"
[ -f "$STUB_DIR/$k.out" ] && cat "$STUB_DIR/$k.out"
exit "$(cat "$STUB_DIR/$k.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/prunner.sh" "$T/plan.sh" "$T/grunner.sh"

# rec <case> <build dir name> <gate.txt line...> — one gate record.
rec() {
  local c="$1" b="$2"; shift 2
  mkdir -p "$T/$c/h/builds/$b"; printf '%s\n' "$@" > "$T/$c/h/builds/$b/gate.txt"
}
# answer <case> <rc> <line...> — the prime runner's answer.
answer() {
  local c="$1" rc="$2"; shift 2
  mkdir -p "$T/$c/stub"; printf '%s\n' "$@" > "$T/$c/stub/out"; echo "$rc" > "$T/$c/stub/rc"
}
# prime <case> [VAR=value …] — one run of the real lane with the case's own
# HARNESS, TMPDIR and repo clone (named cromford, as on the hub). $PA
# holds the lane's own arguments.
PA=""
prime() {
  local c="$1"; shift
  mkdir -p "$T/$c/h/bin" "$T/$c/h/logs" "$T/$c/tmp" "$T/$c/stub"
  [ -d "$T/$c/repos/cromford" ] || git clone -q "$ORIGIN" "$T/$c/repos/cromford"
  # The alert seam: one line per call into logs/ALERTS.log.
  printf '#!/bin/bash\necho "$*" >> "%s/logs/ALERTS.log"\n' "$T/$c/h" > "$T/$c/h/bin/alert-line.sh"
  chmod +x "$T/$c/h/bin/alert-line.sh"
  # shellcheck disable=SC2086
  env -u SELECTION_GATE_PRIME_SUITES -u SELECTION_GATE_PRIME_WINDOW_DAYS -u SELECTION_GATE_PRIME_TIMEOUT_S \
      -u SELECTION_GATE_PRIME_P -u SELECTION_GATE_PRIME_KEEP_DAYS -u SELECTION_GATE_PRIME_RELAY_SHAS \
      -u SELECTION_GATE_PRIME_FETCH_TIMEOUT_S \
    HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" STUB_DIR="$T/$c/stub" \
    SELECTION_GATE_PRIME_REPO="$T/$c/repos/cromford" SELECTION_GATE_PRIME_RUNNER="$T/prunner.sh" \
    "$@" bash "$PRIME" $PA > "$T/$c/stdout" 2> "$T/$c/stderr"
  RC=$?
}
pcalls() { grep -c . "$T/$1/stub/calls" 2>/dev/null || echo 0; }
cache() { cat "$T/$1/h/state/selection-gate/baseline/$MAIN/$2" 2>/dev/null; }
plog() { cat "$T/$1/h/logs/selection-gate-prime.log" 2>/dev/null; }
say_case() { echo "exit $RC; stdout: $(cat "$T/$1/stdout" 2>/dev/null); stderr: $(cat "$T/$1/stderr" 2>/dev/null); log: $(plog "$1")"; }

# gate <case> <harness> [VAR=value …] — one run of the real gate on $CO.
gate() {
  local c="$1" h="$2"; shift 2
  mkdir -p "$T/$c/gstub" "$T/$c/gtmp" "$h"
  env -u CI_QUARANTINE -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S -u SELECTION_GATE_BASELINE_KEEP_DAYS \
    HARNESS="$h" TMPDIR="$T/$c/gtmp" REPO_SLUG= STUB_DIR="$T/$c/gstub" STUB_HEAD_TREE="$CO" \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/grunner.sh" CI_QUARANTINE=- \
    SELECTION_GATE_BASELINE_RUN=1 "$@" bash "$SG" --tree "$CO" --base origin/main --out "$T/$c/gout" > "$T/$c/gstdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/gout/gate.txt" 2>/dev/null; }
gcalls() { awk -v k="$2" '$1 == k { n++ } END { print n + 0 }' "$T/$1/gstub/gcalls" 2>/dev/null; }
gstub() { # gstub <case> <kind> <rc> <line...>
  local c="$1" k="$2" rc="$3"; shift 3
  mkdir -p "$T/$c/gstub"; printf '%s\n' "$@" > "$T/$c/gstub/$k.out"; echo "$rc" > "$T/$c/gstub/$k.rc"
}
HFAIL="FAIL $X (rc 1)"

[ -r "$PRIME" ] || bad "setup: bin/selection-gate-prime.sh is missing"
[ -r "$RELAY" ] || bad "setup: bin/lib/sg-prime-relay.sh is missing"

# ── P1: the prime writes the top-N for the main sha ──────────────────────────
rec p1 pool-cromford-BH-1-1 "red: $X" "baseline-red: -"
rec p1 pool-cromford-BH-2-1 "red: $X,$Y"
rec p1 cromford-BH-3-1 "red: -" "baseline-red: $X"
answer p1 1 "$HFAIL" "PASS $Y"
prime p1 SELECTION_GATE_PRIME_SUITES=2
[ "$RC" = 0 ] && ok || bad "P1 exit 0 ($(say_case p1))"
[ "$(pcalls p1)" = 1 ] && grep -qx "$MAIN P=4 $X $Y" "$T/p1/stub/calls" && ok \
  || bad "P1 one runner call '$MAIN P=4 $X $Y' (calls: $(cat "$T/p1/stub/calls" 2>/dev/null))"
[ "$(cache p1 tests_x.sh)" = red ] && [ "$(cache p1 tests_y.sh)" = green ] && ok \
  || bad "P1 cache: tests_x.sh red, tests_y.sh green (got '$(cache p1 tests_x.sh)' '$(cache p1 tests_y.sh)')"
grep -q "^primed .* suites=2 red=1 green=1 unknown=0$" "$T/p1/h/state/selection-gate/baseline/$MAIN/.primed" 2>/dev/null && ok \
  || bad "P1 .primed stamp ($(cat "$T/p1/h/state/selection-gate/baseline/$MAIN/.primed" 2>/dev/null))"
TSV1="$T/p1/h/state/selection-gate/prime.tsv"
[ "$(grep -c . "$TSV1" 2>/dev/null)" = 2 ] && grep -qxF "$MAIN	$X	red" "$TSV1" && grep -qxF "$MAIN	$Y	green" "$TSV1" && ok \
  || bad "P1 prime.tsv: 2 rows for $MAIN ($(cat "$TSV1" 2>/dev/null))"
grep -q "selection-gate-prime: primed ${MAIN:0:12} sent=2 red=1 green=1 unknown=0 cached=0 tsv_rows=2$" <<<"$(plog p1)" && ok \
  || bad "P1 the primed log line ($(plog p1))"

# ── P4: the same sha again: no runner call ───────────────────────────────────
prime p1 SELECTION_GATE_PRIME_SUITES=2
[ "$RC" = 0 ] && [ "$(pcalls p1)" = 1 ] && grep -q "already primed ${MAIN:0:12}" <<<"$(plog p1)" && ok \
  || bad "P4 a primed sha: 0 new runner calls, 'already primed' ($(say_case p1); calls $(pcalls p1))"

# ── P2: the top-N decision table, through --dry-run ──────────────────────────
rec p2 pool-cromford-BH-1-1 "red: tests/a.sh,tests/b.sh" "unattributed: tests/a.sh,tests/b.sh"
rec p2 pool-cromford-BH-2-1 "red: tests/a.sh,tests/h.sh" "baseline-red: tests/c.sh"
rec p2 pool-cromford-BH-3-1 "red: tests/b.sh,tests/h.sh" "noted: tests/d.sh"
rec p2 pool-cromford-BH-4-1 "red: -" "baseline-red: tests/h.sh"
rec p2 cromford-BH-5-1 "red: tests/a.sh.bak,tests/../x.sh,bin/x.sh,tests/g.sh"
rec p2 pool-cromford-BH-6-1 "red: tests/e.sh"
touch -d '8 days ago' "$T/p2/h/builds/pool-cromford-BH-6-1/gate.txt"
rec p2 pool-project-6-os-TK-1-1 "red: tests/f.sh"
PA=--dry-run
prime p2
PA=""
EXP2=$(printf '%s\n' tests/a.sh tests/b.sh tests/c.sh tests/g.sh)
[ "$RC" = 0 ] && [ "$(cat "$T/p2/stdout")" = "$EXP2" ] && ok \
  || bad "P2 the dry-run list is a, b, c, g in that order ($(say_case p2))"
[ "$(pcalls p2)" = 0 ] && [ ! -e "$T/p2/h/state/selection-gate" ] && [ ! -e "$T/p2/h/logs/selection-gate-prime.log" ] && ok \
  || bad "P2 a dry run sends nothing and writes nothing (calls $(pcalls p2); $(find "$T/p2/h/state" "$T/p2/h/logs" -type f 2>/dev/null))"
PA=--dry-run
prime p2 SELECTION_GATE_PRIME_SUITES=2
PA=""
[ "$(cat "$T/p2/stdout")" = "$(printf '%s\n' tests/a.sh tests/b.sh)" ] && ok \
  || bad "P2 SUITES=2 keeps the first 2 (a, b) ($(say_case p2))"

# ── P3: a prime that could not run caches nothing ────────────────────────────
p3() { # p3 <case> <what>
  local c="$1"
  mkdir -p "$T/$c/h/state/selection-gate"
  printf '%s\t%s\t%s\n' "$MAIN" tests/q.sh red > "$T/$c/h/state/selection-gate/prime.tsv"
  touch -d '1 hour ago' "$T/$c/h/state/selection-gate/prime.tsv"
  local before; before=$(stat -c %Y "$T/$c/h/state/selection-gate/prime.tsv")
  rec "$c" pool-cromford-BH-1-1 "red: $X"
  prime "$c" "${@:3}"
  [ "$RC" = 0 ] && [ ! -e "$T/$c/h/state/selection-gate/baseline/$MAIN/tests_x.sh" ] \
    && [ ! -e "$T/$c/h/state/selection-gate/baseline/$MAIN/.primed" ] \
    && [ "$(stat -c %Y "$T/$c/h/state/selection-gate/prime.tsv")" = "$before" ] \
    && [ "$(grep -c 'could-not-run' <<<"$(plog "$c")")" = 1 ] && ok \
    || bad "P3 $2: no cache, no .primed, prime.tsv unchanged, one could-not-run line ($(say_case "$c"))"
}
answer p3a 125 "$HFAIL" 'remote-gate: no flyctl'
p3 p3a "runner rc 125"
grep -q 'could-not-run: runner-rc-125' <<<"$(plog p3a)" && ok || bad "P3a the log names runner-rc-125 ($(plog p3a))"
answer p3b 1 "$HFAIL" "RUNNER-FAILURE $X"
p3 p3b "a RUNNER-FAILURE line"
grep -q 'could-not-run: runner-failure' <<<"$(plog p3b)" && ok || bad "P3b the log names runner-failure ($(plog p3b))"
answer p3c 1 "$HFAIL"; echo 9 > "$T/p3c/stub/sleep"
p3 p3c "past the timeout" SELECTION_GATE_PRIME_TIMEOUT_S=5
grep -q 'could-not-run: timeout' <<<"$(plog p3c)" && ok || bad "P3c the log names timeout ($(plog p3c))"

# ── P5: the classification of the prime run ──────────────────────────────────
rec p5 pool-cromford-BH-1-1 "red: tests/a.sh,tests/b.sh,tests/c.sh,tests/d.sh,tests/e.sh"
answer p5 2 "PASS tests/a.sh" "FAIL tests/b.sh (rc 1)" "FAIL tests/c.sh (rc 127)" "BLIND tests/d.sh (no output)"
prime p5
[ "$RC" = 0 ] && [ "$(cache p5 tests_a.sh)" = green ] && [ "$(cache p5 tests_b.sh)" = red ] \
  && [ ! -e "$T/p5/h/state/selection-gate/baseline/$MAIN/tests_c.sh" ] \
  && [ ! -e "$T/p5/h/state/selection-gate/baseline/$MAIN/tests_d.sh" ] \
  && [ ! -e "$T/p5/h/state/selection-gate/baseline/$MAIN/tests_e.sh" ] && ok \
  || bad "P5 PASS green, FAIL rc 1 red, rc 127 / BLIND / no line: no write ($(say_case p5); $(ls -A "$T/p5/h/state/selection-gate/baseline/$MAIN" 2>/dev/null | tr '\n' ' '))"
grep -q "suites=5 red=1 green=1 unknown=3$" "$T/p5/h/state/selection-gate/baseline/$MAIN/.primed" 2>/dev/null && ok \
  || bad "P5 .primed counts 3 unknown ($(cat "$T/p5/h/state/selection-gate/baseline/$MAIN/.primed" 2>/dev/null))"
[ "$(grep -c . "$T/p5/h/state/selection-gate/prime.tsv" 2>/dev/null)" = 2 ] && ok \
  || bad "P5 prime.tsv carries only the red and the green row ($(cat "$T/p5/h/state/selection-gate/prime.tsv" 2>/dev/null))"

# ── P6: the hub round-trip: the gate reads the primed per-file cache ─────────
gstub p6 head 1 "$HFAIL"; gstub p6 base 0 "PASS $X"
gate p6 "$T/p1/h"
[ "$RC" = 0 ] && [ "$(gv p6 baseline-red)" = "$X" ] && [ "$(gv p6 red)" = - ] && [ "$(gcalls p6 base)" = 0 ] && ok \
  || bad "P6 hub: exit 0, baseline-red $X, 0 base calls (exit $RC; $(cat "$T/p6/gout/gate.txt" 2>/dev/null); base calls $(gcalls p6 base))"

# ── P7: the pool round-trip: only prime.tsv on the machine ───────────────────
mkdir -p "$T/p7/h/state/selection-gate"; cp "$TSV1" "$T/p7/h/state/selection-gate/prime.tsv"
gstub p7 head 1 "$HFAIL"; gstub p7 base 0 "PASS $X"
gate p7 "$T/p7/h"
[ "$RC" = 0 ] && [ "$(gv p7 baseline-red)" = "$X" ] && [ "$(gcalls p7 base)" = 0 ] \
  && [ "$(gv p7 baseline)" = "ran 1 on ${MAIN:0:12} (1 cached)" ] && ok \
  || bad "P7 pool: exit 0, baseline-red $X, (1 cached), 0 base calls (exit $RC; $(cat "$T/p7/gout/gate.txt" 2>/dev/null); base calls $(gcalls p7 base))"
[ ! -e "$T/p7/h/state/selection-gate/baseline/$MAIN/tests_x.sh" ] || [ "$(cat "$T/p7/h/state/selection-gate/baseline/$MAIN/tests_x.sh")" = red ] && ok \
  || bad "P7 a prime hit writes no other value into the per-file cache"

# ── P8: rows that are not a hit ──────────────────────────────────────────────
OTHER=$(printf '%040d' 7 | tr 0 a)
p8() { # p8 <case> <what> <tsv row printf format> <args…>
  local c="$1" what="$2" fmt="$3"; shift 3
  mkdir -p "$T/$c/h/state/selection-gate"
  # shellcheck disable=SC2059
  printf "$fmt" "$@" > "$T/$c/h/state/selection-gate/prime.tsv"
  gstub "$c" head 1 "$HFAIL"; gstub "$c" base 0 "PASS $X"
  gate "$c" "$T/$c/h"
  [ "$RC" = 1 ] && [ "$(gv "$c" red)" = "$X" ] && [ "$(gcalls "$c" base)" = 1 ] && ok \
    || bad "P8 $what: not a hit, 1 base call, red $X (exit $RC; $(cat "$T/$c/gout/gate.txt" 2>/dev/null); base calls $(gcalls "$c" base))"
}
p8 p8a "another sha" '%s\t%s\t%s\n' "$OTHER" "$X" red
p8 p8b "the value maybe" '%s\t%s\t%s\n' "$MAIN" "$X" maybe
p8 p8c "a 12-hex prefix" '%s\t%s\t%s\n' "${MAIN:0:12}" "$X" red
p8 p8d "a CRLF row" '%s\t%s\t%s\r\n' "$MAIN" "$X" red
p8 p8e "a near-miss name" '%s\t%s\t%s\n' "$MAIN" "$X.bak" red
p8 p8f "an empty value" '%s\t%s\t\n' "$MAIN" "$X"
# P8b: a per-file green wins over a prime.tsv red.
mkdir -p "$T/p8g/h/state/selection-gate/baseline/$MAIN"
echo green > "$T/p8g/h/state/selection-gate/baseline/$MAIN/tests_x.sh"
printf '%s\t%s\t%s\n' "$MAIN" "$X" red > "$T/p8g/h/state/selection-gate/prime.tsv"
gstub p8g head 1 "$HFAIL"; gstub p8g base 1 "$HFAIL"
gate p8g "$T/p8g/h"
[ "$RC" = 1 ] && [ "$(gv p8g red)" = "$X" ] && [ "$(gv p8g baseline-red)" = - ] && [ "$(gcalls p8g base)" = 0 ] && ok \
  || bad "P8b a per-file green beats a prime red: red $X, 0 base calls (exit $RC; $(cat "$T/p8g/gout/gate.txt" 2>/dev/null))"

# ── P9: one classifier, the gate's ───────────────────────────────────────────
printf '%s\n' "PASS tests/a.sh" "FAIL tests/b.sh (rc 1)" "FAIL tests/c.sh (rc 127)" "BLIND tests/d.sh" \
  "PASS tests/f.sh" "FAIL tests/f.sh (rc 1)" > "$T/p9.run"
p9got=""
for s in a b c d e f; do p9got="$p9got $(bash "$SG" --classify "$T/p9.run" "tests/$s.sh" 2>/dev/null)"; done
[ "$p9got" = " green red unknown unknown unknown unknown" ] && ok \
  || bad "P9 --classify: green red unknown unknown unknown unknown (got '$p9got')"
bash "$SG" --classify "$T/p9.run" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "P9 --classify with one argument is exit 2"
grep -q 'selection-gate.sh.*--classify' "$PRIME" && ! grep -qE '^[[:space:]]*(bl_class|[a-z_]*class[a-z_]*)\(\)' "$PRIME" && ok \
  || bad "P9 the prime lane classifies through bin/selection-gate.sh --classify and defines no classifier"

# ── P10: nothing left behind ─────────────────────────────────────────────────
for c in p1 p3a p3c p5; do
  [ "$(git -C "$T/$c/repos/cromford" worktree list 2>/dev/null | grep -c .)" = 1 ] \
    && [ -z "$(ls -A "$T/$c/tmp" 2>/dev/null)" ] && ok \
    || bad "P10 $c left a worktree or a temp dir ($(git -C "$T/$c/repos/cromford" worktree list 2>/dev/null); $(ls -A "$T/$c/tmp" 2>/dev/null))"
done

# ── P11: a bad knob ──────────────────────────────────────────────────────────
for v in 0 abc 201; do
  c="p11-$v"; rec "$c" pool-cromford-BH-1-1 "red: $X"; answer "$c" 0 "PASS $X"
  prime "$c" SELECTION_GATE_PRIME_SUITES="$v"
  [ "$RC" = 1 ] && [ "$(grep -c . "$T/$c/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && [ "$(pcalls "$c")" = 0 ] \
    && grep -q 'SELECTION_GATE_PRIME_SUITES' "$T/$c/h/logs/ALERTS.log" && ok \
    || bad "P11 SUITES=$v: exit 1, one ALERTS line, 0 runner calls ($(say_case "$c"); alerts: $(cat "$T/$c/h/logs/ALERTS.log" 2>/dev/null))"
done

# ── P12: knobs and the cron line ─────────────────────────────────────────────
reads=$(grep -oE '\$\{SELECTION_GATE_PRIME_[A-Z_]+:-[^}]*\}' "$PRIME" 2>/dev/null | sort -u)
[ -n "$reads" ] && ok || bad "P12 the lane reads no SELECTION_GATE_PRIME_* knob"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  name=${r#\$\{}; name=${name%%:-*}; def=${r#*:-}; def=${def%\}}
  case "$name" in SELECTION_GATE_PRIME_RUNNER|SELECTION_GATE_PRIME_REPO)
    [ "$(jq -r --arg e "$name" '.knobs[] | select(.env == $e) | .settable' "$LANE_JSON" 2>/dev/null)" = false ] && ok \
      || bad "P12 $name is a knob row with settable false"; continue ;;
  esac
  [ "$(jq -r --arg e "$name" '.knobs[] | select(.env == $e) | .default' "$LANE_JSON" 2>/dev/null)" = "$def" ] && ok \
    || bad "P12 $name: the knob row default is not the code default $def"
done <<<"$reads"
grep -qE '^[^#].*/root/harness/bin/hub-lease\.sh check && /root/harness/bin/selection-gate-prime\.sh ' "$CRON" 2>/dev/null \
  && [ "$(jq -r .cadence "$LANE_JSON" 2>/dev/null)" = "$(grep -E '^[^#]' "$CRON" | grep -v '^$' | awk '{print $1,$2,$3,$4,$5}' | tail -n 1)" ] && ok \
  || bad "P12 the cron line runs behind hub-lease.sh check at the lane cadence"

# ── P13: retention and the relay window ──────────────────────────────────────
OLD=$(printf '%040d' 1 | tr 0 b); S2=$(printf '%040d' 2 | tr 0 c); S3=$(printf '%040d' 3 | tr 0 d)
CD13="$T/p13/h/state/selection-gate/baseline"
mkdir -p "$CD13/$OLD" "$CD13/$S2" "$CD13/$S3"
for s in "$OLD" "$S2" "$S3"; do
  echo red > "$CD13/$s/tests_a.sh"; printf 'primed 2026-11-01T00:00:00Z suites=1 red=1 green=0 unknown=0\ntests/a.sh\tred\n' > "$CD13/$s/.primed"
done
touch -d '3 days ago' "$CD13/$OLD"; touch -d '2 hours ago' "$CD13/$S2"; touch -d '1 hour ago' "$CD13/$S3"
rec p13 pool-cromford-BH-1-1 "red: $X"; answer p13 1 "$HFAIL"
prime p13 SELECTION_GATE_PRIME_KEEP_DAYS=2 SELECTION_GATE_PRIME_RELAY_SHAS=2
[ "$RC" = 0 ] && [ ! -e "$CD13/$OLD" ] && [ -d "$CD13/$S2" ] && [ -d "$CD13/$S3" ] && ok \
  || bad "P13 a dir 3 days old goes with KEEP_DAYS=2, fresh ones stay ($(say_case p13); $(ls "$CD13" | tr '\n' ' '))"
shas13=$(cut -f1 "$T/p13/h/state/selection-gate/prime.tsv" 2>/dev/null | sort -u | tr '\n' ' ')
[ "$shas13" = "$(printf '%s\n' "$MAIN" "$S3" | sort | tr '\n' ' ')" ] && ok \
  || bad "P13 RELAY_SHAS=2: prime.tsv holds the 2 newest primed shas ($MAIN, $S3) (got '$shas13')"

# ── P14: the relay ───────────────────────────────────────────────────────────
H14="$T/p14/h"; POOL14="$T/p14/pool"; mkdir -p "$H14/state/selection-gate" "$POOL14"
scratch_install_closure bin/lib/deployment.sh "$H14" >/dev/null || bad "P14 setup: cannot install bin/lib/deployment.sh"
printf '%s\t%s\t%s\n' "$MAIN" "$X" red > "$H14/state/selection-gate/prime.tsv"
touch -d '10 minutes ago' "$H14/state/selection-gate/prime.tsv"
relay() { # relay <pool slug> <mput rc> — one sg_prime_relay m-fixture call
  ( unset HARNESS_REPO
    HARNESS="$H14"; POOL="$POOL14"; POOL_SLUG="$1"; MPUT_RC="$2"
    mput() { echo "$1 $3" >> "$T/p14/mput.calls"; [ "$MPUT_RC" = 0 ]; }
    say() { :; }
    # shellcheck disable=SC1090
    . "$RELAY" || exit 9
    sg_prime_relay m-fixture )
}
puts() { grep -c . "$T/p14/mput.calls" 2>/dev/null || echo 0; }
relay example-org/cromford 0; r1=$?
[ "$r1" = 0 ] && [ "$(puts)" = 1 ] && grep -qx 'm-fixture /data/harness/state/selection-gate/prime.tsv' "$T/p14/mput.calls" \
  && [ "$(cat "$POOL14/.m-fixture.sgprimemt")" = "$(stat -c %Y "$H14/state/selection-gate/prime.tsv")" ] && ok \
  || bad "P14 first call: 1 put to /data/harness/state/selection-gate/prime.tsv, sidecar = mtime (rc $r1; puts $(puts))"
relay example-org/cromford 0
[ "$(puts)" = 1 ] && ok || bad "P14 same mtime: no second put (puts $(puts))"
touch -d '1 minute ago' "$H14/state/selection-gate/prime.tsv"
relay example-org/cromford 0
[ "$(puts)" = 2 ] && ok || bad "P14 a new mtime: one more put (puts $(puts))"
touch -d '30 seconds ago' "$H14/state/selection-gate/prime.tsv"
relay example-org/project-6-os 0
[ "$(puts)" = 2 ] && ok || bad "P14 another project's pool: no put (puts $(puts))"
relay example-org/cromford 1; r5=$?
[ "$r5" = 0 ] && [ "$(puts)" = 3 ] && [ "$(cat "$POOL14/.m-fixture.sgprimemt")" != "$(stat -c %Y "$H14/state/selection-gate/prime.tsv")" ] && ok \
  || bad "P14 a failed put returns 0 and writes no sidecar (rc $r5; puts $(puts))"
relay example-org/cromford 0
[ "$(puts)" = 4 ] && ok || bad "P14 after a failed put the next call puts again (puts $(puts))"
: > "$H14/state/selection-gate/prime.tsv"
relay example-org/cromford 0
[ "$(puts)" = 4 ] && ok || bad "P14 an empty prime.tsv is not sent (puts $(puts))"
# The production wiring: bin/fly-pool.sh sources the lib, calls it in the
# live-machine refresh block (after the Vercel snapshot refresh, before the
# DEAD branch) and deletes the sidecar with the machine file.
grep -qE '^\. "\$HARNESS/bin/lib/sg-prime-relay\.sh"' "$FLYPOOL" && ok || bad "P14 bin/fly-pool.sh does not source bin/lib/sg-prime-relay.sh"
blk=$(awk '/# Preview-snapshot refresh \(2026-08-13\)/ { on = 1 } on && /^  if \[ "\$DEAD" = 1 \]; then/ { exit } on { print }' "$FLYPOOL")
grep -qE '^[[:space:]]*command -v sg_prime_relay >/dev/null 2>&1 && sg_prime_relay "\$MID"$' <<<"$blk" && ok \
  || bad "P14 the live-machine refresh block does not call sg_prime_relay \"\$MID\""
[ "$(grep -c 'rm -f "$MF" "$POOL/.$MID.snapmt" "$POOL/.$MID.sgprimemt"' "$FLYPOOL")" = 2 ] && ok \
  || bad "P14 both machine-file deletes remove the .sgprimemt sidecar"

echo "selection-gate-prime: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

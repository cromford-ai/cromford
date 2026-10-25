#!/bin/bash
# tests/selection-gate.bh-8062-test.sh — BH-8062 T2: bin/selection-gate.sh runs
# the merge-queue batch's selection for one head on the fleet test host and
# writes gate.txt. The planner and the runner are stubs through the script's
# seams (SELECTION_GATE_PLAN, SELECTION_GATE_RUNNER); the git repo is a scratch
# one. No network.
#
#   A   300 suites: the runner gets all 300, gate.txt suites: 300, rc: 0, head:
#       equals HEAD, base: the merge-base; the planner ran in batch mode
#   B   one FAIL line, rc 1: red names it, exit 1
#   C   three FAIL lines, rc 3, a PASS line beside them: three names, no PASS
#   D   rc 1 with no FAIL line: could-not-run why=red-without-names
#   E   125: could-not-run, no red names, exit 3
#   F   a runner past --timeout 2: could-not-run why=timeout
#   G   rc 2 with no FAIL line (remote-gate's bad arguments): could-not-run
#   H   a RUNNER-FAILURE line: could-not-run, not red
#   I   adversarial: `FAIL: expected 3` inside a printed log is not a red name
#   J   the planner exits 2: could-not-run why=plan-rc-2
#   K   an empty list: no-selection, exit 4
#   L   a quarantined red only: rc 0, noted: names it
#   M   a quarantined red and a real red: red has the real one only
#   N   the quarantine unreadable: every red counts
#   O   the builder gate's cap knobs in env change nothing (300 still run)
#   P   no merge base: could-not-run why=no-merge-base
#   Q   bad arguments: exit 2
#   R   gate.txt is written whole (no tmp file left)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SG="$DIR/bin/selection-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -x "$SG" ] || { echo "FAIL: bin/selection-gate.sh is missing or not executable"; exit 1; }

# A scratch repo: base commit on main, one change on a ticket branch.
R="$T/repo"; mkdir -p "$R/tests"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; echo a > "$R/a.txt"; g add -A; g commit -qm base
MB=$(g rev-parse HEAD)
g checkout -q -b ticket/bh-1; echo b > "$R/b.txt"; g add -A; g commit -qm change
HEADSHA=$(g rev-parse HEAD)
# An unrelated root: no merge base with HEAD.
g checkout -q --orphan lonely; g rm -rfq . >/dev/null; echo z > "$R/z.txt"; g add -A; g commit -qm lonely
g checkout -q ticket/bh-1

# The planner stub: STUB_N suites (tests/s001.sh …) to --out, its env to
# $T/plan.env, mode=batch-selected to GITHUB_OUTPUT, exit STUB_PLAN_RC.
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
env | grep -E '^(CI_EVENT|TI_PR_HEAD_REF|TI_BASE|CI_PLAN_ESCALATION|CI_PLAN_OWN_BASE)=' | sort > "$STUB_DIR/plan.env"
[ "${STUB_PLAN_RC:-0}" = 0 ] || exit "$STUB_PLAN_RC"
: > "$out"; i=1; while [ "$i" -le "${STUB_N:-0}" ]; do printf 'tests/s%03d.sh\n' "$i" >> "$out"; i=$((i+1)); done
echo "mode=batch-selected" >> "$GITHUB_OUTPUT"
exit 0
SH
# The runner stub: argv to $T/argv (one per line), REMOTE_GATE_P to $T/par,
# $STUB_RUN_OUT to stdout, sleeps STUB_SLEEP, exits STUB_RC.
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_DIR/argv"; printf '%s\n' "${REMOTE_GATE_P:-}" > "$STUB_DIR/par"
[ -n "${STUB_RUN_OUT:-}" ] && printf '%b\n' "$STUB_RUN_OUT"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"   # determinism: ok the stub runner IS the slow host under test
exit "${STUB_RC:-0}"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"

# run <case> [VAR=value …] — one gate run; sets RC and leaves $T/<case>/gate.txt.
run() {
  local c="$1"; shift
  mkdir -p "$T/$c/stub"
  env -u CI_QUARANTINE -u TEST_IMPACT_GATE_CAP -u TEST_IMPACT_GATE_BUDGET_S \
    HARNESS="$T/no-harness" REPO_SLUG= STUB_DIR="$T/$c/stub" SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" \
    "$@" bash "$SG" --tree "$R" --base main --out "$T/$c/out" ${SG_ARGS:-} > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
argc() { grep -c . "$T/$1/stub/argv" 2>/dev/null || echo 0; }

# ── A: 300 suites, green ─────────────────────────────────────────────────────
run a STUB_N=300 CI_QUARANTINE=-
[ "$RC" = 0 ] && ok || bad "A exit 0 (got $RC; $(cat "$T/a/stdout"))"
[ "$(argc a)" = 301 ] && ok || bad "A the runner got the tree plus 300 suites (got $(argc a) args)"
[ "$(sed -n 1p "$T/a/stub/argv")" = "$R" ] && ok || bad "A the runner's first arg is the tree ($(sed -n 1p "$T/a/stub/argv"))"
[ "$(sed -n 301p "$T/a/stub/argv")" = tests/s300.sh ] && ok || bad "A the last suite reached the runner"
[ "$(gv a suites)" = 300 ] && [ "$(gv a rc)" = 0 ] && ok || bad "A gate.txt suites: 300 rc: 0 ($(cat "$T/a/out/gate.txt" 2>/dev/null))"
[ "$(gv a head)" = "$HEADSHA" ] && ok || bad "A gate.txt head: equals HEAD ($(gv a head) vs $HEADSHA)"
[ "$(gv a base)" = "$MB" ] && ok || bad "A gate.txt base: is the merge-base ($(gv a base) vs $MB)"
[ "$(gv a red)" = - ] && [ "$(gv a mode)" = batch-selected ] && ok || bad "A red: - and mode: batch-selected ($(cat "$T/a/out/gate.txt" 2>/dev/null))"
grep -qx 'CI_EVENT=pull_request' "$T/a/stub/plan.env" && grep -qx 'TI_PR_HEAD_REF=mergify/merge-queue/selection-gate' "$T/a/stub/plan.env" \
  && grep -qx "TI_BASE=$MB" "$T/a/stub/plan.env" && grep -qx 'CI_PLAN_ESCALATION=-' "$T/a/stub/plan.env" \
  && ok || bad "A the planner ran in batch mode over the merge-base ($(cat "$T/a/stub/plan.env" 2>/dev/null))"
[ "$(cat "$T/a/stub/par")" = 12 ] && ok || bad "A REMOTE_GATE_P defaults to 12 ($(cat "$T/a/stub/par"))"
[ "$(sed -n 300p "$T/a/out/selection.txt")" = tests/s300.sh ] && ok || bad "A selection.txt holds the list"

# ── B: one red ───────────────────────────────────────────────────────────────
run b STUB_N=20 STUB_RC=1 CI_QUARANTINE=- STUB_RUN_OUT='PASS tests/s001.sh\nFAIL tests/s017.sh (rc 1)'
[ "$RC" = 1 ] && [ "$(gv b rc)" = 1 ] && [ "$(gv b red)" = tests/s017.sh ] && ok || bad "B rc 1, red: tests/s017.sh (exit $RC; $(cat "$T/b/out/gate.txt" 2>/dev/null))"

# ── C: three reds, one PASS beside them ──────────────────────────────────────
run c STUB_N=20 STUB_RC=3 CI_QUARANTINE=- STUB_RUN_OUT='FAIL tests/s003.sh (rc 1)\nPASS tests/fail-fast.bh-1-test.sh\nFAIL tests/s001.sh (rc 2)\nFAIL tests/s002.sh (rc 9)'
[ "$(gv c red)" = "tests/s001.sh,tests/s002.sh,tests/s003.sh" ] && ok || bad "C three names, no PASS (got '$(gv c red)')"

# ── D: a red rc with no FAIL line ────────────────────────────────────────────
run d STUB_N=5 STUB_RC=1 CI_QUARANTINE=- STUB_RUN_OUT='something broke'
[ "$RC" = 3 ] && [ "$(gv d rc)" = could-not-run ] && [ "$(gv d why)" = red-without-names ] && ok || bad "D could-not-run why=red-without-names (exit $RC; $(cat "$T/d/out/gate.txt" 2>/dev/null))"
[ "$(gv d rc)" != 0 ] && ok || bad "D never rc: 0"

# ── E: 125, the run could not happen ─────────────────────────────────────────
run e STUB_N=5 STUB_RC=125 CI_QUARANTINE=- STUB_RUN_OUT='remote-gate: no flyctl'
[ "$RC" = 3 ] && [ "$(gv e rc)" = could-not-run ] && [ "$(gv e red)" = - ] && [ "$(gv e why)" = runner-rc-125 ] && ok || bad "E 125: could-not-run, no red (exit $RC; $(cat "$T/e/out/gate.txt" 2>/dev/null))"

# ── F: the timeout ───────────────────────────────────────────────────────────
SG_ARGS="--timeout 2" run f STUB_N=5 STUB_SLEEP=6 CI_QUARANTINE=-
[ "$RC" = 3 ] && [ "$(gv f rc)" = could-not-run ] && [ "$(gv f why)" = timeout ] && ok || bad "F could-not-run why=timeout (exit $RC; $(cat "$T/f/out/gate.txt" 2>/dev/null))"

# ── G: rc 2 with no FAIL line ────────────────────────────────────────────────
run g STUB_N=5 STUB_RC=2 CI_QUARANTINE=- STUB_RUN_OUT='remote-gate: unknown flag'
[ "$(gv g rc)" = could-not-run ] && ok || bad "G rc 2, no FAIL line: could-not-run ($(cat "$T/g/out/gate.txt" 2>/dev/null))"

# ── H: a RUNNER-FAILURE line ─────────────────────────────────────────────────
run h STUB_N=5 STUB_RC=1 CI_QUARANTINE=- STUB_RUN_OUT='RUNNER-FAILURE tests/s001.sh\nFAIL tests/s002.sh (rc 1)'
[ "$(gv h rc)" = could-not-run ] && [ "$(gv h why)" = runner-failure ] && [ "$(gv h red)" = - ] && ok || bad "H RUNNER-FAILURE: could-not-run, not red ($(cat "$T/h/out/gate.txt" 2>/dev/null))"

# ── I: adversarial lines inside a printed log ────────────────────────────────
run i STUB_N=5 STUB_RC=1 CI_QUARANTINE=- STUB_RUN_OUT='FAIL tests/s004.sh (rc 1)\n  FAIL: expected 3\nFAIL tests/s005.sh (rc 1) trailing\nFAIL tests/s001.sh'
[ "$(gv i red)" = tests/s004.sh ] && ok || bad "I only an exact FAIL line names a red (got '$(gv i red)')"

# ── J: the planner fails ─────────────────────────────────────────────────────
run j STUB_N=5 STUB_PLAN_RC=2 CI_QUARANTINE=-
[ "$RC" = 3 ] && [ "$(gv j why)" = plan-rc-2 ] && [ ! -s "$T/j/stub/argv" ] && ok || bad "J plan rc 2: could-not-run why=plan-rc-2, runner not called (exit $RC; $(cat "$T/j/out/gate.txt" 2>/dev/null))"

# ── K: an empty selection ────────────────────────────────────────────────────
run k STUB_N=0 CI_QUARANTINE=-
[ "$RC" = 4 ] && [ "$(gv k rc)" = no-selection ] && [ ! -s "$T/k/stub/argv" ] && ok || bad "K empty: no-selection, exit 4, runner not called (exit $RC; $(cat "$T/k/out/gate.txt" 2>/dev/null))"

# ── L: a quarantined red only ────────────────────────────────────────────────
run l STUB_N=20 STUB_RC=1 CI_QUARANTINE='tests/s009.sh tests/s010.sh' STUB_RUN_OUT='FAIL tests/s009.sh (rc 1)'
[ "$RC" = 0 ] && [ "$(gv l rc)" = 0 ] && [ "$(gv l red)" = - ] && [ "$(gv l noted)" = tests/s009.sh ] && [ "$(gv l quarantine)" = env ] \
  && ok || bad "L quarantined red only: rc 0, noted names it (exit $RC; $(cat "$T/l/out/gate.txt" 2>/dev/null))"

# ── M: a quarantined red and a real one ──────────────────────────────────────
run m STUB_N=20 STUB_RC=2 CI_QUARANTINE='tests/s009.sh' STUB_RUN_OUT='FAIL tests/s009.sh (rc 1)\nFAIL tests/s011.sh (rc 1)'
[ "$RC" = 1 ] && [ "$(gv m red)" = tests/s011.sh ] && [ "$(gv m noted)" = tests/s009.sh ] && ok || bad "M red keeps the real one (exit $RC; $(cat "$T/m/out/gate.txt" 2>/dev/null))"

# ── N: the quarantine unreadable ─────────────────────────────────────────────
run n STUB_N=20 STUB_RC=1 STUB_RUN_OUT='FAIL tests/s009.sh (rc 1)'
[ "$RC" = 1 ] && [ "$(gv n red)" = tests/s009.sh ] && [ "$(gv n quarantine)" = unreadable ] && ok || bad "N unreadable quarantine: every red counts (exit $RC; $(cat "$T/n/out/gate.txt" 2>/dev/null))"

# ── O: the builder gate's caps do not bind ───────────────────────────────────
run o STUB_N=300 CI_QUARANTINE=- TEST_IMPACT_GATE_CAP=80 TEST_IMPACT_GATE_BUDGET_S=450
[ "$(argc o)" = 301 ] && [ "$(gv o suites)" = 300 ] && ok || bad "O the cap knobs change nothing (got $(argc o) args, suites $(gv o suites))"

# ── P: no merge base ─────────────────────────────────────────────────────────
mkdir -p "$T/p/stub"
env -u CI_QUARANTINE HARNESS="$T/no-harness" STUB_DIR="$T/p/stub" SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" STUB_N=5 \
  bash "$SG" --tree "$R" --base lonely --out "$T/p/out" > "$T/p/stdout" 2>&1; RC=$?
[ "$RC" = 3 ] && [ "$(gv p why)" = no-merge-base ] && [ ! -s "$T/p/stub/argv" ] && ok || bad "P no merge base: could-not-run (exit $RC; $(cat "$T/p/out/gate.txt" 2>/dev/null))"

# ── Q: bad arguments ─────────────────────────────────────────────────────────
bash "$SG" --tree "$R" --out "$T/q" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "Q no --base: exit 2"
bash "$SG" --tree "$R" --base main --out "$T/q" --timeout x >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "Q a bad --timeout: exit 2"

# ── R: one whole write ───────────────────────────────────────────────────────
[ -z "$(find "$T" -name 'gate.txt.tmp.*' 2>/dev/null)" ] && ok || bad "R no gate.txt tmp file left"
[ "$(grep -c '' "$T/b/out/gate.txt")" = 9 ] && ok || bad "R gate.txt has its nine lines ($(cat "$T/b/out/gate.txt"))"

echo "selection-gate.bh-8062: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

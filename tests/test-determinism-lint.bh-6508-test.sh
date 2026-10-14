#!/bin/bash
# tests/test-determinism-lint.bh-6508-test.sh — BH-6508: the race-wall-bound
# rule warns on a shell test that captures elapsed wall-clock time for a bound.
#
#   THE PROPERTY UNDER TEST: stuck-work-dispatch AT-1a did `SECONDS=0; dispatch;
#   D1=$SECONDS; [ "$D1" -le 5 ]`. A loaded runner stretched that to 7 s and 19 s
#   on PRs that did not touch the code. The rule reports the two capture shapes
#   (a `SECONDS=0` reset, an `X=$((SECONDS - t0))` / EPOCHSECONDS elapsed capture)
#   at warn, so the run stays rc 0. It does not report a start capture, a deadline
#   or a deadline loop. A NOW= pin does not exempt it (the name is not clock-*).
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf.
#
# determinism: ok-file race-wall-bound the fixtures are lint input as data; this suite reads no clock
# Run from anywhere: tests/test-determinism-lint.bh-6508-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run <dir-or-file> [flags...] -> stdout+stderr in $OUT, rc in $RC. HARNESS
# points at a scratch tree so a box-local flags/determinism-lint.conf cannot
# leak in and change the answer.
run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }
nhits() { local n; n=$(grep -cE "$1" <<<"$OUT"); printf '%s' "${n:-0}"; }
# fix <name> : writes stdin to $T/c/tests/<name>-test.sh in a fresh case dir
fix() { rm -rf "$T/c"; mkdir -p "$T/c/tests"; cat > "$T/c/tests/$1-test.sh"; }

# ── L1. the old AT-1a text: one warning at the SECONDS=0 line, rc 0 ─────────
fix l1 <<'EOF'
#!/bin/bash
SECONDS=0
dispatch STUCK_WORK_PROJECTS=all
D1=$SECONDS
check "AT-1a returns within 5 s (${D1}s)" '[ "$D1" -le 5 ]'
EOF
run "$T/c"
{ [ "$RC" = 0 ] && has 'tests/l1-test\.sh:2: race-wall-bound' && [ "$(nhits 'race-wall-bound')" = 1 ]; } && ok \
  || bad "L1: the old AT-1a shape did not give exactly one race-wall-bound warning at line 2 (rc=$RC): $OUT"

# ── L2. an elapsed capture, top level and inside a function ─────────────────
fix l2 <<'EOF'
#!/bin/bash
EL=$((SECONDS - S0))
run() { local s=$SECONDS; X; EL=$((SECONDS - s)); }
EOF
run "$T/c"
{ has 'tests/l2-test\.sh:2: race-wall-bound' && has 'tests/l2-test\.sh:3: race-wall-bound'; } && ok \
  || bad "L2: an elapsed SECONDS capture was not reported on both lines: $OUT"

# ── L3. EPOCHSECONDS, spaces, and the ${SECONDS} form ────────────────────────
fix l3 <<'EOF'
#!/bin/bash
X=$(( EPOCHSECONDS - t0 ))
X=$((${SECONDS} - t0))
EOF
run "$T/c"
{ has 'tests/l3-test\.sh:2: race-wall-bound' && has 'tests/l3-test\.sh:3: race-wall-bound'; } && ok \
  || bad "L3: the EPOCHSECONDS or \${SECONDS} capture was not reported: $OUT"

# ── L4. a start capture, a deadline, a deadline loop, SECONDS=05, a comment ──
fix l4 <<'EOF'
#!/bin/bash
s0=$SECONDS
END=$((SECONDS + 11))
while [ "$SECONDS" -lt "$END" ]; do :; done
SECONDS=05
# SECONDS=0
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-wall-bound'; } && ok \
  || bad "L4: a shape that asserts no duration was reported (rc=$RC): $OUT"

# ── L5. a NOW= pin does not exempt it ────────────────────────────────────────
fix l5 <<'EOF'
#!/bin/bash
NOW=1789999520
SECONDS=0
EOF
run "$T/c"
has 'tests/l5-test\.sh:3: race-wall-bound' && ok || bad "L5: a NOW= pin exempted race-wall-bound: $OUT"

# ── L6. a line waiver and a file waiver, each with a reason ──────────────────
fix l6 <<'EOF'
#!/bin/bash
SECONDS=0  # determinism: ok race-wall-bound a 300 s ceiling that only catches a hang
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-wall-bound' && ! has 'waiver-no-reason'; } && ok \
  || bad "L6a: the line waiver did not quiet race-wall-bound (rc=$RC): $OUT"
fix l6 <<'EOF'
#!/bin/bash
# determinism: ok-file race-wall-bound a hang ceiling, not a speed claim
SECONDS=0
EL=$((SECONDS - s0))
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-wall-bound'; } && ok \
  || bad "L6b: the file waiver did not quiet race-wall-bound (rc=$RC): $OUT"

# ── L7. a warning, not a finding: rc 0 with no --warn-only ───────────────────
fix l7 <<'EOF'
#!/bin/bash
SECONDS=0
EOF
run "$T/c"
{ [ "$RC" = 0 ] && has 'determinism warnings' && ! has 'determinism findings' && has ' 1 warnings'; } && ok \
  || bad "L7: race-wall-bound is not a rc-0 warning (rc=$RC): $OUT"
# ... and raised to error (a settings row can do that), it fails and says why
sed -E 's/^(rule[[:space:]]+race-wall-bound[[:space:]]+)warn/\1error/' "$DIR/catalog/determinism-lint.conf" > "$T/err.conf"
OUT=$(HARNESS="$T/h" DETERMINISM_LINT_CONF="$T/err.conf" bash "$LINT" "$T/c" 2>&1); RC=$?
{ [ "$RC" = 1 ] && has 'tests/l7-test\.sh:2: race-wall-bound: elapsed wall-clock time captured for a bound' \
    && has 'assert the order of events' && has '# determinism: ok race-wall-bound'; } && ok \
  || bad "L7b: at error, race-wall-bound does not fail with its message (rc=$RC): $OUT"

# ── L8. --rules prints the conf line verbatim, at warn ───────────────────────
run --rules
LINE=$(grep -E '^rule[[:space:]]+race-wall-bound[[:space:]]' "$DIR/catalog/determinism-lint.conf")
{ [ "$RC" = 0 ] && [ -n "$LINE" ] && has '^rule[[:space:]]+race-wall-bound[[:space:]]+warn[[:space:]]+sh[[:space:]]' \
    && grep -qxF -- "$LINE" <<<"$OUT"; } && ok \
  || bad "L8: --rules does not print the race-wall-bound line at warn (rc=$RC): $OUT"

# ── L9. the fixed suite carries no wall-clock bound; the real tree stays rc 0 ─
run "$DIR/tests/stuck-work-dispatch.bh-5943-test.sh"
{ [ "$RC" = 0 ] && ! has 'race-wall-bound'; } && ok \
  || bad "L9a: tests/stuck-work-dispatch.bh-5943-test.sh still has a wall-clock bound (rc=$RC): $OUT"
run "$DIR/tests"
SHOWN=$(nhits '^[^ ].*: race-wall-bound: ')
MORE=$(sed -n 's/^  \.\.\. and \([0-9]*\) more race-wall-bound warnings$/\1/p' <<<"$OUT")
{ ! awk '/determinism findings/{f=1} /determinism warnings/{f=0} f && /race-wall-bound/{x=1} END{exit !x}' <<<"$OUT"; } && ok \
  || bad "L9b: race-wall-bound reported a fail finding on the real tree: $OUT"
echo "test-determinism-lint.bh-6508: real tree race-wall-bound warnings: $((SHOWN + ${MORE:-0}))"

echo "test-determinism-lint.bh-6508: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

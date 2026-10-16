#!/bin/bash
# tests/test-determinism-lint.bh-6657-test.sh — BH-6657: race-sigpipe-echo
# reaches bin/.
#
#   THE PROPERTY UNDER TEST: the SHIPPED catalog/determinism-lint.conf carries
#   `scope race-sigpipe-echo (^|/)bin/.*\.sh$`, so a `printf`/`echo` pipe into a
#   short-circuiting consumer in any bin/**/*.sh is a finding, the here-string
#   and process-substitution answers stay quiet, a waiver with a reason still
#   silences a bin/ line, and a .sh outside bin/ that is not a test file stays
#   out of scope.
#
# Every case drives bin/test-determinism-lint.sh against the shipped conf (no
# DETERMINISM_LINT_CONF override): the claim is about the conf this repo ships.
#
# determinism: ok-file the fixtures below are deliberate printf/echo-pipe leaks
# as DATA; this suite itself reads no clock, rolls no dice, and puts no
# short-circuiting consumer on a pipe.
# Run from anywhere: tests/test-determinism-lint.bh-6657-test.sh  (exit 0 = all pass)
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
count() { grep -c "$1" <<<"$OUT"; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/tests" "$T/c/bin/lib" "$T/c/scripts"; }

# ── A. the printf pipe in a bin/ script is caught ────────────────────────────
case_dir
cat > "$T/c/bin/x.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$X" | grep -q y && echo hit
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'bin/x\.sh:3: race-sigpipe-echo'; } && ok \
  || bad "A: a printf pipe into grep -q in bin/ was not caught (rc=$RC): $OUT"

# ── B. a nested bin/lib file, an echo producer and grep -m ───────────────────
case_dir
cat > "$T/c/bin/lib/y.sh" <<'EOF'
#!/bin/bash
FIRST=$(echo "$X" | head -1)
printf '%s' "$X" | grep -m1 y
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'bin/lib/y\.sh:2: race-sigpipe-echo' && has 'bin/lib/y\.sh:3: race-sigpipe-echo'; } && ok \
  || bad "B: an echo|head or printf|grep -m1 in bin/lib/ was not caught (rc=$RC): $OUT"

# ── C. the recommended answers and the non-short-circuiting shapes ───────────
case_dir
cat > "$T/c/bin/x.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
grep -q y <<<"$X" && echo hit
grep -q y < <(printf '%s' "$X") && echo hit
printf '%s\n' "$X" | grep -c y
echo x | wc -l
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe-echo'; } && ok \
  || bad "C: a shape that is not a race was reported in bin/ (rc=$RC): $OUT"

# ── D. the waiver still works on a bin/ line, and still wants a reason ───────
case_dir
cat > "$T/c/bin/w.sh" <<'EOF'
#!/bin/bash
echo git-ish | grep -q x && echo hit   # determinism: ok race-sigpipe-echo seven bytes, written before grep reads
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe-echo'; } && ok \
  || bad "D: a line waiver with a reason did not silence a bin/ finding (rc=$RC): $OUT"
# The reasonless marker is split in this source so marker-reason-lint does
# not read the fixture as a real waiver; the written file carries it whole.
printf '%s\n' '#!/bin/bash' 'echo git-ish | grep -q x && echo hit   # determinism: o''k' > "$T/c/bin/w.sh"
run "$T/c"
{ [ "$RC" = 1 ] && has 'waiver-no-reason'; } && ok \
  || bad "D: a reasonless waiver in a bin/ file was accepted (rc=$RC): $OUT"

# ── E. --rules echoes the scope directive back ───────────────────────────────
run --rules
{ [ "$RC" = 0 ] && has '^scope race-sigpipe-echo'; } && ok \
  || bad "E: --rules did not print the race-sigpipe-echo scope line: $OUT"

# ── F. a .sh outside bin/ that is not a test file stays out of scope ─────────
case_dir
cat > "$T/c/scripts/x.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$X" | grep -q y && echo hit
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe-echo'; } && ok \
  || bad "F: scripts/x.sh was flagged; the scope is bin/*.sh, not every .sh (rc=$RC): $OUT"

# ── G. the whole tree on the shipped conf is clean with the scope armed ──────
# This is CI's lint step. Every bin/ hit is swept in the same diff that arms
# the scope, so main is rc 0 the tick it lands.
run "$DIR"
{ [ "$RC" = 0 ] && [ "$(count ': race-sigpipe-echo:')" = 0 ]; } && ok \
  || bad "G: the full tree has race-sigpipe-echo findings on the shipped conf (rc=$RC): $(grep ': race-sigpipe-echo:' <<<"$OUT" | cut -d: -f1,2)"

echo "test-determinism-lint.bh-6657: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

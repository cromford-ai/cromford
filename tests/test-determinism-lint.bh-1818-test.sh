#!/bin/bash
# tests/test-determinism-lint.bh-1818-test.sh — BH-1818: a NEGATIVE check fed by
# a pipe into `grep -q` passes falsely under pipefail, and the lint says so.
#
#   THE PROPERTY UNDER TEST: `cmd | grep -q X && bad … || ok` is the check
#   "X must not appear". When X DOES appear, grep -q exits at the first match,
#   cmd takes SIGPIPE (141), pipefail hands the pipeline 141, and `|| ok` fires:
#   the check passes in exactly the case it exists to catch. The
#   sigpipe-negative rule flags that shape (and `! cmd | grep -q …`, which reads
#   a present X as absent the same way), stays quiet on the here-string form
#   `grep -q X <<<"$(cmd)"`, and stays quiet on a POSITIVE check, which fails
#   loudly instead of passing quietly.
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf (no DETERMINISM_LINT_CONF override): the claim
# is about the conf this repo ships, so a copy would prove nothing.
#
# determinism: ok-file sigpipe-negative race-sigpipe-echo waiver-no-reason the heredocs below are the false-pass shape as DATA; this suite's own checks read here-strings
# Run from anywhere: tests/test-determinism-lint.bh-1818-test.sh  (exit 0 = all pass)
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
N=0
case_dir() { N=$((N + 1)); C="$T/c$N"; mkdir -p "$C/tests"; }

# ── 0. the trap is real, and the here-string closes it ───────────────────────
# Deterministic, not a race: head writes ~700 KB (ten pipe buffers) and the
# match is on its FIRST line, so grep has always exited while head still has
# bytes to write.
PIPED=$(bash -c 'set -o pipefail; yes present | head -n 100000 | grep -q present && echo BAD || echo OK')
[ "$PIPED" = OK ] && ok \
  || bad "0: expected the piped negative check to pass FALSELY on this host (got '$PIPED') — the fixture no longer reproduces the trap"
HERE=$(bash -c 'set -o pipefail; grep -q present <<<"$(yes present | head -n 100000)" && echo BAD || echo OK')
[ "$HERE" = BAD ] && ok || bad "0: the here-string form must catch the present X (got '$HERE')"

# ── A. the ticket's own fixture pair ─────────────────────────────────────────
case_dir
cat > "$C/tests/neg-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
cmd | grep -qx X && bad "X must not appear" || ok
EOF
run "$C"
{ [ "$RC" = 1 ] && has 'neg-test\.sh:3: sigpipe-negative'; } && ok \
  || bad "A: 'cmd | grep -qx X && bad || ok' was not flagged (rc=$RC): $OUT"
has 'grep -q X <<<' && ok || bad "A: the finding must name the here-string fix: $OUT"

case_dir
cat > "$C/tests/neg-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
grep -qx X <<<"$(cmd)" && bad "X must not appear" || ok
EOF
run "$C"
{ [ "$RC" = 0 ] && ! has 'sigpipe-negative'; } && ok \
  || bad "A: the here-string form was flagged (rc=$RC): $OUT"

# ── B. the shapes the sweep found, each one a finding ────────────────────────
case_dir
cat > "$C/tests/shapes-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$OUT" \
  | grep -q 'secret' \
  && bad "a pipe continued onto the next line, and the && on the line after" || ok
calls | grep -qE -- '-X (POST|PATCH)'    && bad "flags between -q and the pattern" || ok
alerts | grep --quiet 'INVISIBLE' && bad "the long spelling" || ok
! grep 'beat-53' <<<"$(tlog)" | grep -q 'lease lapses' \
  && ok || bad "negated with !"
if ! ledger | grep -q 'ghp_x'; then ok; else bad "negated inside an if"; fi
[ -s "$F" ] && log | grep -q 'swept' && bad "an && chain that ends in bad" || ok
log | grep -q 'swept' && [ "$RC" = 0 ] && bad "a later && link still feeds bad" || ok
note | grep -qi 'weakened' && { bad "a braced bad"; }
calls | grep -q 'a\|b' && fail "the other assertion verb" || ok
EOF
run "$C"
for L in 3 6 7 8 10 11 12 13 14; do
  has "shapes-test\.sh:$L: sigpipe-negative" && ok \
    || bad "B: line $L of the shapes fixture was not flagged: $OUT"
done
[ "$(count 'sigpipe-negative')" = 9 ] && ok \
  || bad "B: expected exactly 9 findings, one per shape, reported at the line the pipeline starts: $OUT"

# ── C. what must stay quiet ──────────────────────────────────────────────────
# The lint gates CI red, so what it must NOT match is as load-bearing as what
# it must.
case_dir
cat > "$C/tests/quiet-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
cmd | grep -q X && ok || bad "a POSITIVE check fails loudly, it never passes quietly"
cmd | grep -q X || bad "positive, bare"
if cmd | grep -q X; then ok; else bad "positive inside an if"; fi
[ "$(cmd | grep -c X)" = 0 ] && ok || bad "grep -c reads to EOF"
grep -q X <<<"$(cmd)" && bad "here-string" || ok
! grep -q X <<<"$(cmd)" && ok || bad "negated here-string"
grep -q X "$F" && bad "a file operand, no pipe" || ok
[ "$RC" = 0 ] && bad "prose quoting the shape: cmd | grep -q X && bad" || ok
[ "$RC" = 0 ] && bad "$(cmd | grep -q X && echo y)" || ok
# cmd | grep -q X && bad "a comment is not a check" || ok
cmd | grep -q X && ok || bad "then" && echo done
cmd | grep -v X | wc -l
[ ! -s "$F" ] && [ "$RC" = 75 ] && head -1 "$F" | grep -q '^ROUTE' && ok || bad "a positive chain"
EOF
run "$C"
{ [ "$RC" = 0 ] && ! has 'sigpipe-negative'; } && ok \
  || bad "C: a shape that is not a false-pass negative check was flagged (rc=$RC): $OUT"

# ── D. the waiver mechanism applies, and a reason is still required ──────────
case_dir
cat > "$C/tests/waived-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
echo abc | grep -q X && bad "never" || ok   # determinism: ok echo writes three bytes before grep reads one
EOF
run "$C"
{ [ "$RC" = 0 ] && ! has 'sigpipe-negative'; } && ok \
  || bad "D: a line waiver with a reason did not silence the finding (rc=$RC): $OUT"
cat > "$C/tests/waived-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
echo abc | grep -q X && bad "never" || ok   # determinism: ok
EOF
run "$C"
{ [ "$RC" = 1 ] && has 'waiver-no-reason'; } && ok \
  || bad "D: a reasonless waiver was accepted (rc=$RC): $OUT"

# ── E. bin/ is not in this rule's scope ──────────────────────────────────────
# The ticket is about test assertions. A bin/ script has no bad/ok, and its
# `! producer | grep -q` sites are BH-806's lane, not this lint's.
case_dir
mkdir -p "$C/bin"
cat > "$C/bin/lane.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
if ! printf '%s' "$MOVED" | grep -q "$TO_STATUS"; then exit 1; fi
EOF
run "$C"
! has 'sigpipe-negative' && ok || bad "E: the rule followed into bin/: $OUT"

# ── F. --rules shows it as an error (the shipped tree: the lint job) ───────
run --rules
has '^rule sigpipe-negative[[:space:]]+error' && ok || bad "F: --rules must list sigpipe-negative as an error rule: $OUT"
# The shipped-tree half of F: --rules above pins sigpipe-negative as an ERROR,
# so the job's rc 0 means no sigpipe-negative finding in the tree.
# The whole-tree scan is not repeated here. The "Test determinism lint" job in
# .github/workflows/harness-ci.yml runs bin/test-determinism-lint.sh over this
# repo's tree on every PR, batch and push, and a finding fails it with rc 1.
# Re-running that scan here only doubled its cost in every batch.
# tests/dedicated-job-coverage-test.sh checks that the job keeps running it.

echo "test-determinism-lint.bh-1818: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

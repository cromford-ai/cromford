#!/bin/bash
# tests/test-determinism-lint.bh-6109-test.sh — BH-6109: a printf/echo pipe
# into a short-circuiting consumer (grep -q/-m, head) reads a TRUE match as a
# miss under pipefail, and the race-sigpipe-echo rule says so.
#
#   THE PROPERTY UNDER TEST: `printf '%s\n' "$X" | grep -q y` exits 0 only when
#   printf finished writing before grep exited. With a big $X, grep -q exits at
#   the first match, printf takes SIGPIPE (141), and pipefail hands the pipeline
#   141: the match reads as a miss (tests/llm-call-ratchet-test.sh, PR #6108).
#   The rule flags that shape for a printf or echo producer, and stays quiet on
#   the here-string form `grep -q y <<<"$X"` and on consumers that read to EOF.
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf (no DETERMINISM_LINT_CONF override): the claim
# is about the conf this repo ships, so a copy would prove nothing.
#
# determinism: ok-file race-sigpipe-echo waiver-no-reason the heredocs below are the printf/echo pipe shape as DATA; this suite reads here-strings
# Run from anywhere: tests/test-determinism-lint.bh-6109-test.sh  (exit 0 = all pass)
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
N=0
case_dir() { N=$((N + 1)); C="$T/c$N"; mkdir -p "$C/tests"; }
# one_line <body line> -> a scratch tests/x-test.sh whose line 3 is the body
one_line() {
  case_dir
  printf '#!/bin/bash\nset -uo pipefail\n%s\n' "$1" > "$C/tests/x-test.sh"
}
# flagged <case> <body line>: the line is a race-sigpipe-echo finding at :3
flagged() {
  one_line "$2"; run "$C"
  { [ "$RC" = 1 ] && has 'x-test\.sh:3: race-sigpipe-echo'; } && ok \
    || bad "$1: '$2' was not flagged (rc=$RC): $OUT"
}
# quiet <case> <body line>: the line is no race-sigpipe-echo finding
quiet() {
  one_line "$2"; run "$C"
  ! has 'race-sigpipe-echo' && ok || bad "$1: '$2' was flagged: $OUT"
}

# ── R0. the trap is real, and the here-string closes it ──────────────────────
# Deterministic, not a race: X is ~800 KB and the match is on its FIRST line,
# so grep has always exited while printf still has bytes to write.
PIPED=$(bash -c 'set -o pipefail; X=$(yes present | head -n 100000); printf "%s\n" "$X" | grep -q present && echo HIT || echo MISS')
[ "$PIPED" = MISS ] && ok \
  || bad "R0: expected the printf pipe to read a TRUE match as a miss on this host (got '$PIPED') — the fixture no longer reproduces the trap"
HERE=$(bash -c 'set -o pipefail; X=$(yes present | head -n 100000); grep -q present <<<"$X" && echo HIT || echo MISS')
[ "$HERE" = HIT ] && ok || bad "R0: the here-string form must find the match (got '$HERE')"

# ── A. the ticket's own fixture pair ─────────────────────────────────────────
one_line 'printf '"'"'%s\n'"'"' "$X" | grep -qxF y'
run "$C"
{ [ "$RC" = 1 ] && has 'x-test\.sh:3: race-sigpipe-echo'; } && ok \
  || bad "A1: printf | grep -qxF was not flagged (rc=$RC): $OUT"
has 'grep -q X <<<' && ok || bad "A1: the finding must name the here-string fix: $OUT"

one_line 'grep -qxF y <<<"$X"'
run "$C"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe-echo'; } && ok \
  || bad "A2: the here-string form was flagged (rc=$RC): $OUT"

# ── B. the shapes the rule must flag ─────────────────────────────────────────
flagged B1 'echo "$X" | grep -q y'
flagged B2 'printf '"'"'%s'"'"' "$X" | grep -m1 y'
flagged B3 'printf '"'"'%s\n'"'"' "$X" | grep --quiet y'
flagged B3 'printf '"'"'%s\n'"'"' "$X" | grep --max-count=1 y'
flagged B4 'printf '"'"'%s'"'"' "$X" | head -1'
flagged B4 'printf '"'"'%s'"'"' "$X" | head'
flagged B6 'if ! printf '"'"'%s\n'"'"' "$X" | grep -q y; then :; fi'

# B5: a pipe split over two lines is one pipeline, reported at its first line
case_dir
cat > "$C/tests/x-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$X" |
  grep -q y && echo yes
EOF
run "$C"
{ [ "$RC" = 1 ] && has 'x-test\.sh:3: race-sigpipe-echo'; } && ok \
  || bad "B5: a pipe split over two lines was not flagged at line 3 (rc=$RC): $OUT"

# ── N. the shapes the rule must leave alone ──────────────────────────────────
quiet N1 'printf '"'"'%s\n'"'"' "$X" | grep -c y'
quiet N2 'printf '"'"'%s\n'"'"' "$X" | grep y'
quiet N3 'printf '"'"'%s\n'"'"' "$X" | wc -l'
quiet N4 'cat "$F" | grep -q y'
quiet N5 'grep -q y < <(printf '"'"'%s'"'"' "$X")'
quiet N6 '# printf '"'"'%s\n'"'"' "$X" | grep -q y'
quiet N7 'echo "$(id -u) $(printf x | wc -c)"'
quiet N7 'echo "$(id -u) $(cat "$F" | head -1)"'
quiet N8 'myprintf x | grep -q y'

# ── W. a waiver with a reason quiets it; a bare waiver is its own finding ────
one_line 'printf '"'"'%s\n'"'"' "$X" | grep -qxF y  # determinism: ok race-sigpipe-echo one short value'
run "$C"
{ [ "$RC" = 0 ] && ! has 'race-sigpipe-echo'; } && ok \
  || bad "W: a reasoned waiver did not quiet the line (rc=$RC): $OUT"
one_line 'printf '"'"'%s\n'"'"' "$X" | grep -qxF y  # determinism: ok race-sigpipe-echo'
run "$C"
{ [ "$RC" = 1 ] && has 'x-test\.sh:3: waiver-no-reason'; } && ok \
  || bad "W: a waiver with no reason was not reported (rc=$RC): $OUT"

# ── T1. the shipped conf carries the rule at error severity ──────────────────
run --rules
has '(^|[[:space:]])rule race-sigpipe-echo +error +sh ' && ok \
  || bad "T1: --rules shows no 'rule race-sigpipe-echo error sh' line: $OUT"

# ── R. the ratchet: the whole checkout carries no hit ────────────────────────
run "$DIR"
{ [ "$RC" = 0 ] && ! has ': race-sigpipe-echo:'; } && ok \
  || bad "R: the full-tree lint is not clean of race-sigpipe-echo (rc=$RC): $(grep -E 'race-sigpipe-echo|findings' <<<"$OUT" | head -20)"

echo "test-determinism-lint.bh-6109: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

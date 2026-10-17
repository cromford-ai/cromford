#!/bin/bash
# tests/prepush-record.bh-7289-test.sh — bin/lib/prepush-record.sh, the record
# of the suites the pre-push gate ran green on one head, and the writer in the
# `prepush gate` span of bin/lib/rb/pr.sh (BH-7289).
#
#   R1  ppr_write -> a body with other sections -> ppr_read gives the same suites
#   R2  a CRLF body reads the same
#   R3  another head, a bad sha, no end marker, a second marker of another
#       version: rc 1, no output
#   R4  a red rules-pack row adds no rules-pack suite; a fast-lints rc 1 row is
#       left out; a pre-existing (red) rules-pack component is left out
#   R5  the pr.sh span in a git checkout with the lib and a green stub gate: the
#       section holds a v1 marker with head = git rev-parse HEAD; mode off: no
#       marker; no lib: no marker, and the push is still reached
#   R6  ppr_list_build on this tree is a subset of the always set
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prepush-record.bh-7289-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
. "$DIR/bin/lib/prepush-record.sh" || { echo "FAIL: cannot source bin/lib/prepush-record.sh"; exit 1; }

H1=abcdefabcdefabcdefabcdefabcdefabcdefabcd
H2=0123456789012345678901234567890123456789
RP1=tests/model-literal-lint.sh        # a kind=suite row of catalog/rules-pack.tsv (model-literal)
RP2=tests/switch-ratchet.bh-2320-test.sh  # another (switch)

# gate <dir> <rules-pack state> — a stub gate out dir in the formats bin/prepush-gate.sh,
# bin/fast-lints.sh --run and bin/rules-pack.sh --out write.
gate() {
  local d="$1" st="$2"
  mkdir -p "$d/fast-lints.d" "$d/rules-pack.d"
  printf 'rules-pack\t%s\t%s\t4\trules-pack\nfast-lints\tgreen\t0\t9\tfast-lints\norphans\tgreen\t0\t2\torphans\n' "$st" "$([ "$st" = green ] && echo 0 || echo 1)" > "$d/summary.tsv"
  printf 'tests/b-test.sh\t2\t0\ntests/a-test.sh\t1\t0\ntests/red-test.sh\t3\t1\n../evil.sh\t1\t0\n' > "$d/fast-lints.d/timings.tsv"
  printf '%s\n%s\n' "$RP1" "$RP2" > "$d/rules-pack.d/suites.txt"
  printf '{"state":"clean","components":[{"id":"model-literal","shape":"tree","rc":0,"state":"green","seconds":1},{"id":"switch","shape":"delta","rc":1,"state":"pre-existing","seconds":1},{"id":"grep-q","shape":"delta","rc":0,"state":"green","seconds":1}]}\n' > "$d/rules-pack.d/summary.json"
}

# ── R1. the round trip.
gate "$T/g1" green
W=$(ppr_write "$T/g1" "$H1" "$DIR"); RC=$?
check "R1 ppr_write rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "R1 one v1 marker with the head" '[ "$(grep -c "^<!-- prepush-gate-record v1 head=$H1 -->$" <<<"$W")" = 1 ]'
check "R1 the summary counts 3 suites" 'grep -qF "ran green on this head (3)</summary>" <<<"$W"'
{ printf '## What\n\nprose\n'; printf '%s\n' "$W"; printf '\n## Pre-push gate: could-not-run\n\nother text\n'; } > "$T/body1"
R=$(ppr_read "$T/body1" "$H1"); RC=$?
WANT=$(printf '%s\n' "$RP1" tests/a-test.sh tests/b-test.sh | LC_ALL=C sort)
check "R1 ppr_read rc 0 and the same suites: [$(tr '\n' ' ' <<<"$R")]" '[ "$RC" = 0 ] && [ "$R" = "$WANT" ]'

# ── R2. CRLF.
sed 's/$/\r/' "$T/body1" > "$T/body2"
R=$(ppr_read "$T/body2" "$H1"); RC=$?
check "R2 a CRLF body reads the same (rc=$RC)" '[ "$RC" = 0 ] && [ "$R" = "$WANT" ]'

# ── R3. the refusals.
R=$(ppr_read "$T/body1" "$H2"); RC=$?
check "R3 another head: rc 1, no output" '[ "$RC" = 1 ] && [ -z "$R" ]'
R=$(ppr_read "$T/body1" abc); RC=$?
check "R3 a short sha: rc 1" '[ "$RC" = 1 ] && [ -z "$R" ]'
grep -v '^<!-- /prepush-gate-record -->$' "$T/body1" > "$T/body3"
R=$(ppr_read "$T/body3" "$H1"); RC=$?
check "R3 no end marker: rc 1" '[ "$RC" = 1 ] && [ -z "$R" ]'
{ cat "$T/body1"; printf '<!-- prepush-gate-record v2 head=%s -->\n<!-- /prepush-gate-record -->\n' "$H1"; } > "$T/body3b"
R=$(ppr_read "$T/body3b" "$H1"); RC=$?
check "R3 a v1 and a v2 marker in one body: rc 1" '[ "$RC" = 1 ] && [ -z "$R" ]'
R=$(ppr_write "$T/g1" "not-a-sha" "$DIR"); RC=$?
check "R3 ppr_write with a bad sha: rc 1, no output" '[ "$RC" = 1 ] && [ -z "$R" ]'
R=$(ppr_write "$T/nothing-here" "$H1" "$DIR"); RC=$?
check "R3 ppr_write with no summary.tsv: rc 1" '[ "$RC" = 1 ] && [ -z "$R" ]'

# ── R4. red and pre-existing are left out.
check "R4 the fast-lints rc 1 row is left out" '! grep -qF "prepush-ran: tests/red-test.sh" <<<"$W"'
check "R4 a ../ path is left out" '! grep -qF "evil" <<<"$W"'
check "R4 a pre-existing rules-pack component ($RP2) is left out" '! grep -qF "$RP2" <<<"$W"'
gate "$T/g4" red
W4=$(ppr_write "$T/g4" "$H1" "$DIR")
check "R4 a red rules-pack row adds no rules-pack suite" '! grep -qF "$RP1" <<<"$W4" && grep -qF "prepush-ran: tests/a-test.sh" <<<"$W4"'
mkdir -p "$T/g5"; printf 'rules-pack\tred\t1\t4\tx\n' > "$T/g5/summary.tsv"
R=$(ppr_write "$T/g5" "$H1" "$DIR"); RC=$?
check "R4 no green suite at all: rc 1, no output" '[ "$RC" = 1 ] && [ -z "$R" ]'

# ── R5. the pr.sh span.
span() { awk '/^# >>> prepush gate/{f=1} f{print} /^# <<< prepush gate/{exit}' "$1"; }
span "$DIR/bin/lib/rb/pr.sh" > "$T/span.sh"
check "R5 the span exists" '[ -s "$T/span.sh" ]'
# mk <case> <lib:yes|no> — a git checkout whose bin/prepush-gate.sh is a green stub
# that writes the formats the real gate writes.
mk() {
  local d="$T/$1"
  mkdir -p "$d/co/bin/lib" "$d/co/catalog" "$d/build"
  cp "$DIR/catalog/rules-pack.tsv" "$d/co/catalog/"
  if [ "$2" = yes ]; then
    ( cd "$DIR" && scratch_install_closure bin/lib/prepush-record.sh "$d/co" ) > /dev/null \
      || { echo "FAIL: setup: cannot install the bin/lib/prepush-record.sh closure"; exit 1; }
  fi
  cat > "$d/co/bin/prepush-gate.sh" <<'EOS'
#!/bin/bash
O=""; while [ $# -gt 0 ]; do case "$1" in --out) O=$2; shift ;; esac; shift; done
mkdir -p "$O/fast-lints.d" "$O/rules-pack.d"
printf 'rules-pack\tgreen\t0\t3\trules-pack\nfast-lints\tgreen\t0\t5\tfast-lints\n' > "$O/summary.tsv"
printf 'tests/a-test.sh\t1\t0\n' > "$O/fast-lints.d/timings.tsv"
printf 'tests/model-literal-lint.sh\n' > "$O/rules-pack.d/suites.txt"
printf '{"state":"clean","components":[{"id":"model-literal","state":"green"}]}\n' > "$O/rules-pack.d/summary.json"
exit 0
EOS
  chmod +x "$d/co/bin/prepush-gate.sh"
  git -C "$d/co" init -q && git -C "$d/co" add -A \
    && git -C "$d/co" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm fixture \
    || { echo "FAIL: setup: cannot commit the fixture checkout"; exit 1; }
}
spanrun() { # spanrun <case> [SETV] — runs the span in the case's checkout; prints the exit code
  local d="$T/$1"
  ( cd "$d/co" && env BUILD="$d/build" PROJECT=cromford KEY=BH-1 BASE=HEAD HARNESS="$d/h" ${2:+SETV="$2"} \
      bash -c '
        set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
        escalate_block() { :; }
        PREPR_SECTION=""
        if [ -n "${SETV+x}" ]; then setting_get() { printf "%s" "$SETV"; }; fi
        . "$0"
        printf "%s" "$PREPR_SECTION" > "$BUILD/section"
        echo PUSH_REACHED
      ' "$T/span.sh" > "$d/out.txt" 2>&1; echo $? )
}
mk r5a yes; RC=$(spanrun r5a)
HEAD5=$(git -C "$T/r5a/co" rev-parse HEAD)
check "R5 green with the lib: rc 0 and the push is reached (rc=$RC)" '[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/r5a/out.txt"'
check "R5 the section holds the v1 marker with head = HEAD ($HEAD5)" 'grep -qxF "<!-- prepush-gate-record v1 head=$HEAD5 -->" "$T/r5a/build/section"'
R=$(ppr_read "$T/r5a/build/section" "$HEAD5")
check "R5 the section reads back as the two suites: [$(tr '\n' ' ' <<<"$R")]" '[ "$R" = "$(printf "tests/a-test.sh\ntests/model-literal-lint.sh")" ]'
check "R5 the pipeline log names the record" 'grep -q "PREPUSH-GATE record head=${HEAD5:0:12} suites=2" "$T/r5a/build/pipeline.log"'
mk r5b yes; RC=$(spanrun r5b off)
check "R5 mode off: no marker, push reached (rc=$RC)" '[ "$RC" = 0 ] && ! grep -q "prepush-gate-record" "$T/r5b/build/section" && grep -q PUSH_REACHED "$T/r5b/out.txt"'
mk r5c no; RC=$(spanrun r5c)
check "R5 no lib: no marker, push reached (rc=$RC)" '[ "$RC" = 0 ] && ! grep -q "prepush-gate-record" "$T/r5c/build/section" && grep -q PUSH_REACHED "$T/r5c/out.txt"'

# ── R6. ppr_list_build on this tree.
( cd "$DIR" && bin/test-impact.sh always 2>/dev/null ) | LC_ALL=C sort -u > "$T/always"
ppr_list_build "$DIR" > "$T/built" 2>/dev/null; RC=$?
check "R6 ppr_list_build rc 0 (rc=$RC)" '[ "$RC" = 0 ] && [ -s "$T/built" ]'
NOTIN=$(LC_ALL=C awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$T/always" "$T/built" | paste -sd' ' -)
check "R6 every built line is an always-suite (not: ${NOTIN:-none})" '[ -z "$NOTIN" ]'
check "R6 the rules-pack always-suite $RP1 is in it" 'grep -qxF "$RP1" "$T/built"'
check "R6 ppr_list_build on a missing tree: rc 1" '! ppr_list_build "$T/no-tree" >/dev/null 2>&1'

echo "prepush-record.bh-7289: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

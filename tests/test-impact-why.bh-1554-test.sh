#!/bin/bash
# tests/test-impact-why.bh-1554-test.sh — BH-1554 / S1: the `named` kind stops
# matching on COMMENT lines.
#
# The #1541 round-2 review counted a selection where three of six `named` picks
# were suites whose only mention of the changed script's function was a comment.
# A comment is not a reference: the suite cannot go red because that function
# changed. A name on a line that RUNS still counts (conservative), including a
# trailing comment on a code line.
#
#   S1a  a suite whose only `widget_close_all` mention is a `# …` line is NOT
#        selected as named
#   S1b  a suite that names it on a code line still IS (the absent-symbol
#        guard: S1a alone would pass if named stopped selecting anything)
#   S1c  whole-word only, both ways: `widget_close_all_extra` is NOT a match and
#        `${widget_close_all}/x` IS. The round-3 review replaced the per-suite
#        `sed | grep -owF` with one awk token pass over the corpus (732 suites
#        = 1464 forks on the gate's critical path), and these are `-w`.
#   S1d  a suite whose PATH carries an `=` is still scanned. awk has no `--` and
#        `name=value` on argv is an assignment, not a file, so a selector that
#        ever puts a bare basename there loses the suite in silence. (Green
#        today either way — see the case for exactly what it is worth.)
#
# --map-only is the builder gate's own question (bin/test-impact-gate.sh): this
# scratch tree has no suite that runs widget.sh, so a plain select answers the
# whole corpus for unknown reach and the map's picks are what say WHY.
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-why-1554: git is required for this suite"; exit 2; }
[ -x "$TI" ] || { echo "FAIL: bin/test-impact.sh is missing"; echo "test-impact-why-1554: 0 passed, 1 failed"; exit 1; }

R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/docs"
cat > "$R/bin/lib/widget.sh" <<'SH'
#!/bin/bash
widget_count_open() { echo 3; }
widget_close_all() { echo closed; }
SH
# comment-test: names widget_close_all ONLY in full-line comments, indented and
# not. Nothing here can break when widget.sh changes.
cat > "$R/tests/comment-test.sh" <<'SH'
#!/bin/bash
# widget_close_all used to be checked here, see BH-000
   # TODO: widget_close_all
echo "comment: 1 passed, 0 failed"
SH
# code-test: the real pin — the name on a line that runs.
cat > "$R/tests/code-test.sh" <<'SH'
#!/bin/bash
n=$(grep -c 'widget_close_all' /dev/null)
echo "code: 1 passed, 0 failed"
SH
# trailing-test: a code line with the name in its TRAILING comment still counts.
cat > "$R/tests/trailing-test.sh" <<'SH'
#!/bin/bash
: "$PWD" # widget_close_all is the pin
echo "trailing: 1 passed, 0 failed"
SH
# substring-test: names widget_close_all_extra, which CONTAINS the name but is
# not it. `grep -owF` never matched a substring and the awk token pass must not
# either — this is the whole-word half of the round-3 rewrite (advisory 3).
cat > "$R/tests/substring-test.sh" <<'SH'
#!/bin/bash
widget_close_all_extra=1
echo "substring: 1 passed, 0 failed"
SH
# punct-test: the name touching non-word bytes on both sides ($...) still IS a
# whole-word match, which is what the token split has to preserve.
cat > "$R/tests/punct-test.sh" <<'SH'
#!/bin/bash
echo "${widget_close_all}/x"
echo "punct: 1 passed, 0 failed"
SH
# a suite whose PATH carries an `=`, scanned end to end. awk has no `--` and a
# bare operand that looks like `name=value` is a VARIABLE ASSIGNMENT, not a
# file — awk never opens it and the suite leaves the selection with no error
# anywhere. HONEST NOTE ON WHAT THIS CASE IS WORTH: it passes with or without
# the `./` prefix ti_named_rows adds, because the name part has to be a valid
# awk identifier and `tests/n` is not one. So it does not pin the prefix; it
# pins that a `=` path survives the selector at all, which is the assertion
# that goes red if anyone ever passes basenames or cd's into tests/ (either of
# which puts `n=eq-test.sh` on argv as a real assignment). The prefix stays as
# belt and braces and is documented as such in bin/test-impact.sh.
cat > "$R/tests/n=eq-test.sh" <<'SH'
#!/bin/bash
n=$(grep -c 'widget_close_all' /dev/null)
echo "eq: 1 passed, 0 failed"
SH
echo note > "$R/docs/n.md"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam "touch widget"

GOT=$("$TI" --root "$R" select "$BASE..HEAD" --map-only --why 2>"$T/reason")
named() { grep -qxF "$(printf '%s\tnamed\tbin/lib/widget.sh#widget_close_all' "$1")" <<<"$GOT"; }

# S1a — the comment-only suite is not a named pick.
named tests/comment-test.sh \
  && bad "S1a: a suite whose only widget_close_all mention is a comment line must not be selected as named (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))" \
  || ok
# S1b — the code-line suite still is. This is the absent-symbol guard.
named tests/code-test.sh \
  && ok || bad "S1b: a suite naming widget_close_all on a code line must still be named (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"
# a trailing comment on a real code line is still a match (conservative).
named tests/trailing-test.sh \
  && ok || bad "S1b: a name in a TRAILING comment on a code line stays a match (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"
# and the comment-only suite is not picked by some OTHER kind either, so the
# selection genuinely shrank.
grep -q '^tests/comment-test.sh' <<<"$(printf '%s\n' "$GOT")" \
  && bad "S1a: the comment-only suite must not be selected at all for this diff (got: $(printf '%s' "$GOT" | grep '^tests/comment-test' | tr '\t\n' ' |'))" \
  || ok

# S1c — whole-word only: a longer identifier that CONTAINS the name is not a
# match. The awk token pass replaced `grep -owF` and this is its `-w`.
named tests/substring-test.sh \
  && bad "S1c: widget_close_all_extra contains the name but is not it — must not be a named match (got: $(printf '%s' "$GOT" | grep '^tests/substring-test' | tr '\t\n' ' |'))" \
  || ok
# S1c — ...and the name surrounded by non-word bytes still IS one.
named tests/punct-test.sh \
  && ok || bad "S1c: \${widget_close_all}/x is a whole-word match and must stay named (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"
# S1d — a suite whose PATH carries an `=` is still READ. As a bare awk operand
# `tests/n=eq-test.sh` is the assignment `tests/n` = `eq-test.sh` and awk never
# opens the file, so the suite leaves the selection with no error at all.
named tests/n=eq-test.sh \
  && ok || bad "S1d: a suite whose PATH holds an \`=\` must still be scanned, not read as an awk assignment (got: $(printf '%s' "$GOT" | tr '\t\n' ' |'))"

echo "test-impact-why-1554: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

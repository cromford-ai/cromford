#!/bin/bash
# tests/prepush-gate.bh-7187-test.sh — BH-7187 (HOTFIX TOC lever 1): ONE
# pre-push gate, bin/prepush-gate.sh, runs every deterministic ratchet on the
# builder before the push, so a "no" comes at the start and not from the merge
# queue. The builder calls it in bin/lib/rb/pr.sh (the `prepush gate` span).
#
#   G1  a fixture diff with a stale-stamped schema fragment, a hand-copied
#       bin/lib in a test, a file-grep piped into grep -q and a new bin/lib
#       script no suite names: RED, rc 1, four named findings (the real
#       bin/rules-pack.sh and the real bin/test-impact.sh orphans --check)
#   G2  --restamp renames the stale fragment (bin/lib/schema-restamp.sh), and
#       the gate prints the exact `git mv` while the fragment is stale
#   G3  the same diff fixed: GREEN, rc 0
#   G4  a component that cannot start (missing script, rc 125, timeout) is
#       could-not-run, rc 1, never green; a red one beats it in the verdict
#   G5  bad args and an unresolvable base are rc 2
#   G6  the default table: the ids the ticket names, every script exists
#   G7  pr.sh span: red refuses the push (exit 6) and the text names the
#       component; stale stamp -> restamp -> green passes; could-not-run
#       passes with a note; no gate script in the checkout is a no-op
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/prepush-gate.bh-7187-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
GATE="$DIR/bin/prepush-gate.sh"
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT (stdout and stderr together)
run() { "$@" >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out"); }
has() { grep -qF -- "$1" <<<"$OUT"; }
state_of() { awk -F'\t' -v i="$2" '$1==i {print $2}' "$1/summary.tsv" 2>/dev/null; }

# --- G5 / G6 need no fixture ------------------------------------------------
run bash "$GATE" --bogus
[ "$RC" = 2 ] && ok || bad "G5: --bogus rc $RC, want 2"
run bash "$GATE" --base no-such-ref-7187 --tree "$DIR" --out "$T/g5"
[ "$RC" = 2 ] && ok || bad "G5: unresolvable base rc $RC, want 2: $OUT"
run bash "$GATE" --list
[ "$RC" = 0 ] && ok || bad "G6: --list rc $RC"
for id in rules-pack fast-lints checks-run list-file-lint orphans determinism llm-sites context-budgets config-inventory render-rules render-cron render-env render-doc-sections schema-build; do
  awk -v i="$id" '$1==i {f=1} END {exit !f}' <<<"$OUT" && ok || bad "G6: --list has no component $id"
done
# every default component runs a script that exists in the repo
while IFS=$'\t' read -r id argv; do
  [ -n "$id" ] || continue
  s=${argv%% *}
  [ -f "$DIR/$s" ] && ok || bad "G6: component $id runs $s, which is not in the repo"
done < <(awk -F'\t' 'NF >= 2 {print $1 "\t" $2}' <<<"$OUT")

# --- the fixture: a git archive of this checkout, origin/main = its HEAD ----
R="$T/r"; mkdir -p "$R"
git -C "$DIR" archive HEAD | tar -x -C "$R" || { echo "FAIL: cannot archive HEAD"; exit 1; }
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0; rd_git "$R" config maintenance.auto false
B0=$(rd_git "$R" rev-parse HEAD)
rd_git "$R" update-ref refs/remotes/origin/main "$B0"
rd_git "$R" checkout -qf -B work "$B0"
# The new gate must be in the fixture (the archive is HEAD, the gate may be uncommitted here).
mkdir -p "$R/bin"; cp -p "$GATE" "$R/bin/prepush-gate.sh"
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "$1"; }
commit "fixture: the gate"
rd_git "$R" update-ref refs/remotes/origin/main HEAD

# The restamp clock: one day after the newest fragment in the fixture, so a
# restamped fragment is later than every fragment at the base (a fixed epoch
# goes stale as soon as main gets a newer fragment).
NEWEST=$(ls "$R/worker/jobs/schema.d" | sed -n 's/^\([0-9]\{12\}\)-.*/\1/p' | sort | tail -n 1)
NOW_E=$(( $(date -u -d "${NEWEST:0:8} ${NEWEST:8:2}:${NEWEST:10:2}" +%s) + 86400 ))

# The two real components that judge the four defects; the table seam keeps
# this suite to the findings it asserts (the full table runs in G6/preflight).
TBL="$T/table.tsv"
{ printf 'rules-pack\tbin/rules-pack.sh --runner local --tree . --base <base> --only schema-fragment-name,scratch-closure,grep-q --out <out>/rules-pack.d\n'
  printf 'orphans\tbin/test-impact.sh orphans --check\n'; } > "$TBL"
gate() { # gate <out> [args...] — the real gate on the fixture with the seam table
  local o="$1"; shift
  ( cd "$R" && PREPUSH_GATE_TABLE="$TBL" SR_NOW_EPOCH="$NOW_E" HARNESS_TEST_SANDBOX=1 bash bin/prepush-gate.sh --base origin/main --out "$T/$o" "$@" ) >"$T/out" 2>&1
  RC=$?; OUT=$(cat "$T/out")
}

# --- G1: four defects, RED, four named findings ---------------------------------
L='bin/''lib'
printf 'CREATE TABLE IF NOT EXISTS stale_t7187 (id INTEGER);\n-- no-index: stale_t7187 fixture\n' > "$R/worker/jobs/schema.d/202001010000-bh-7187-stale.sql"
printf '#!/bin/bash\nfor f in a.sh; do cp "$DIR/%s/$f" "$T/%s/"; done\n' "$L" "$L" > "$R/tests/zz-copy-7187-test.sh"
printf '#!/bin/bash\ngrep foo "$F" %s grep -q bar\n' '|' > "$R/tests/zz-grepq-7187-test.sh"
printf '#!/bin/bash\n: new lib script\n' > "$R/$L/zz-unnamed-7187.sh"
commit "fixture: four defects"
gate g1
[ "$RC" = 1 ] && ok || bad "G1: rc $RC, want 1: $OUT"
for n in schema-fragment-name scratch-closure grep-q orphans; do
  has "$n" && ok || bad "G1: the output does not name $n: $OUT"
done
has "RED" && ok || bad "G1: no RED verdict line"
[ "$(state_of "$T/g1" rules-pack)" = red ] && [ "$(state_of "$T/g1" orphans)" = red ] && ok \
  || bad "G1: summary.tsv states: rules-pack=$(state_of "$T/g1" rules-pack) orphans=$(state_of "$T/g1" orphans)"
has "git mv" && ok || bad "G2: the stale stamp finding prints no git mv hint"
has "zz-unnamed-7187.sh" && ok || bad "G1: the orphan finding does not name the script"

# --- G2: --restamp renames the fragment, one commit ---------------------------------
H0=$(rd_git "$R" rev-parse HEAD)
( cd "$R" && SR_NOW_EPOCH="$NOW_E" bash bin/prepush-gate.sh --restamp --base origin/main ) >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out")
[ "$RC" = 0 ] && ok || bad "G2: --restamp rc $RC: $OUT"
[ ! -e "$R/worker/jobs/schema.d/202001010000-bh-7187-stale.sql" ] && ok || bad "G2: the stale fragment is still there"
[ "$(rd_git "$R" rev-list --count "$H0..HEAD")" = 1 ] && ok || bad "G2: --restamp did not make exactly one commit"

# --- G3: the same diff, fixed -> GREEN -------------------------------------------------
printf '#!/bin/bash\nscratch_install_closure bin/x.sh "$T"\n' > "$R/tests/zz-copy-7187-test.sh"
printf '#!/bin/bash\ngrep -q bar <<<"$F"\nbash "$DIR/%s/zz-unnamed-7187.sh"\n' "$L" > "$R/tests/zz-grepq-7187-test.sh"
commit "fixture: fixed"
gate g3
[ "$RC" = 0 ] && ok || bad "G3: rc $RC, want 0: $OUT"
has "GREEN" && ok || bad "G3: no GREEN verdict line"
[ "$(state_of "$T/g3" rules-pack)" = green ] && [ "$(state_of "$T/g3" orphans)" = green ] && ok || bad "G3: states not green"

# --- G4: could-not-run is never green ------------------------------------------------------
printf 'ghost\tbin/no-such-tool-7187.sh --check\n' > "$T/t4a.tsv"
printf 'stuck\tbash -c "exit 125"\n' >> "$T/t4a.tsv"
printf 'slow\tbash -c "sleep 30"\n' >> "$T/t4a.tsv"  # determinism: ok the sleep is the component under test; the gate's 1 s timeout kills it, nothing waits on it
printf 'fine\ttrue\n' >> "$T/t4a.tsv"
( cd "$R" && PREPUSH_GATE_TABLE="$T/t4a.tsv" PREPUSH_GATE_TIMEOUT_S=1 bash bin/prepush-gate.sh --base origin/main --out "$T/g4a" ) >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out")
[ "$RC" = 1 ] && ok || bad "G4: rc $RC, want 1: $OUT"
[ "$(state_of "$T/g4a" ghost)" = could-not-run ] && [ "$(state_of "$T/g4a" stuck)" = could-not-run ] && ok \
  || bad "G4: ghost=$(state_of "$T/g4a" ghost) stuck=$(state_of "$T/g4a" stuck)"
[ "$(state_of "$T/g4a" slow)" = could-not-run ] && ok || bad "G4: a timed-out component is '$(state_of "$T/g4a" slow)', want could-not-run"
[ "$(state_of "$T/g4a" fine)" = green ] && ok || bad "G4: the fine component is '$(state_of "$T/g4a" fine)'"
has "COULD-NOT-RUN" && ok || bad "G4: no COULD-NOT-RUN verdict: $OUT"
case "$OUT" in *GREEN*) bad "G4: the verdict says GREEN with components that could not run" ;; *) ok ;; esac
printf 'bad\tbash -c "echo boom; exit 1"\nghost\tbin/no-such-tool-7187.sh\n' > "$T/t4b.tsv"
( cd "$R" && PREPUSH_GATE_TABLE="$T/t4b.tsv" bash bin/prepush-gate.sh --base origin/main --out "$T/g4b" ) >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out")
[ "$RC" = 1 ] && has "RED" && has "boom" && ok || bad "G4: red plus could-not-run: rc $RC, want RED with the finding: $OUT"

# --- G8: the seed row ---
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-7187-prepush-gate-mode.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && grep -q "'prepush.gate_mode','block'" "$SEED" && ok || bad "G8: no schema.d seed of prepush.gate_mode = block"

# --- G7: the pr.sh span ------------------------------------------------------------------------
span() { awk '/^# >>> prepush gate/{f=1} f{print} /^# <<< prepush gate/{exit}' "$1"; }
span "$DIR/bin/lib/rb/pr.sh" > "$T/span.sh"
[ -s "$T/span.sh" ] && ok || bad "G7: no '# >>> prepush gate' span in bin/lib/rb/pr.sh"
L_SPAN=$(grep -n '^# >>> prepush gate' "$DIR/bin/lib/rb/pr.sh" | head -1 | cut -d: -f1)
L_PUSH=$(grep -n '^# >>> pr push' "$DIR/bin/lib/rb/pr.sh" | head -1 | cut -d: -f1)
[ -n "$L_SPAN" ] && [ -n "$L_PUSH" ] && [ "$L_SPAN" -lt "$L_PUSH" ] && ok || bad "G7: the span (line ${L_SPAN:-none}) is not before the pr push span (line ${L_PUSH:-none})"
# mk <case> <mode> — a checkout whose bin/prepush-gate.sh is a stub: mode red | stale | cnr | green
mk() {
  local m="$2" d="$T/$1"
  mkdir -p "$d/co/bin" "$d/build"
  { printf '#!/bin/bash\nM=%s\nD=%s\n' "$m" "$d"
    cat <<'EOS'
O=""; while [ $# -gt 0 ]; do
  case "$1" in --restamp) : > "$D/restamped"; echo restamped; exit 0 ;; --out) O=$2; shift ;; esac; shift
done
echo run >> "$D/calls"; mkdir -p "$O"
case "$M" in
  red) printf 'rules-pack\tred\t1\t3\tgrep-q\n' > "$O/summary.tsv"; echo "prepush-gate: rules-pack red: grep-q"; exit 1 ;;
  stale) if [ -e "$D/restamped" ]; then printf 'rules-pack\tgreen\t0\t3\t-\n' > "$O/summary.tsv"; exit 0; fi
         printf 'rules-pack\tred\t1\t3\tschema-fragment-name\n' > "$O/summary.tsv"; exit 1 ;;
  cnr) printf 'orphans\tcould-not-run\t125\t3\t-\n' > "$O/summary.tsv"; exit 1 ;;
  fixable) if [ -e "$D/fixed" ]; then printf 'rules-pack\tgreen\t0\t3\t-\n' > "$O/summary.tsv"; exit 0; fi
           printf 'rules-pack\tred\t1\t3\tgrep-q\n' > "$O/summary.tsv"; exit 1 ;;
  *) printf 'rules-pack\tgreen\t0\t3\t-\n' > "$O/summary.tsv"; exit 0 ;;
esac
EOS
  } > "$d/co/bin/prepush-gate.sh"
  chmod +x "$d/co/bin/prepush-gate.sh"
}
spanrun() { # spanrun <case> — runs the span in the case's checkout; prints the exit code
  local d="$T/$1"
  ( cd "$d/co" && env FIXFLAG="$d/fixed" BUILD="$d/build" PROJECT=cromford KEY=BH-1 BASE=origin/main HARNESS="$d/h" \
      bash -c '
        set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
        escalate_block() { printf "%s\n%s\n" "$1" "$2" > "$BUILD/escalate"; }
        PREPR_SECTION=""
        if [ -n "${FIXCC+x}" ]; then CC() { echo "$1" >> "$BUILD/cc-calls"; [ "$FIXCC" = fix ] && : > "$FIXFLAG"; return 0; }; FIX_MODEL=m; BRANCH=b; fi
        if [ -n "${SETV+x}" ]; then setting_get() { [ "$SETV" = UNREADABLE ] && return 1; printf "%s" "$SETV"; }; fi
        . "$0"
        echo "$PREPR_SECTION" > "$BUILD/section"
        echo PUSH_REACHED
      ' "$T/span.sh" > "$d/out.txt" 2>&1; echo $? )
}
mk s1 red; RC=$(spanrun s1)
[ "$RC" = 6 ] && ok || bad "G7: red -> exit $RC, want 6: $(cat "$T/s1/out.txt")"
grep -q PUSH_REACHED "$T/s1/out.txt" && bad "G7: red reached the push" || ok
grep -q 'REVIEW_BLOCKED prepush-gate' "$T/s1/build/RESULT" 2>/dev/null && grep -q 'rules-pack' "$T/s1/build/RESULT" 2>/dev/null && ok \
  || bad "G7: the refusal text does not name the component: $(cat "$T/s1/build/RESULT" 2>/dev/null)"
grep -q '^prepush-gate$' "$T/s1/build/escalate" 2>/dev/null && ok || bad "G7: escalate_block was not called with the prepush-gate gate"
# one fix round on the box before a red stops the push (the rules-pack prepr pattern)
mk f1 fixable; RC=$(FIXCC=fix spanrun f1)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/f1/out.txt" && ok || bad "G7: a red the fix round clears -> exit $RC, want the push: $(cat "$T/f1/out.txt")"
[ "$(grep -c . "$T/f1/build/cc-calls" 2>/dev/null)" = 1 ] && [ "$(wc -l < "$T/f1/calls" | tr -d ' ')" = 2 ] && ok || bad "G7: want 1 fix round and 2 gate runs, got cc=$(grep -c . "$T/f1/build/cc-calls" 2>/dev/null) runs=$(wc -l < "$T/f1/calls" | tr -d ' ')"
mk f2 fixable; RC=$(FIXCC=nofix spanrun f2)
[ "$RC" = 6 ] && [ "$(grep -c . "$T/f2/build/cc-calls" 2>/dev/null)" = 1 ] && ok || bad "G7: still red after the one fix round -> exit $RC, want 6 after 1 round"
mk s2 stale; RC=$(spanrun s2)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/s2/out.txt" && [ -e "$T/s2/restamped" ] && ok || bad "G7: stale stamp -> exit $RC, restamped=$([ -e "$T/s2/restamped" ] && echo y || echo n): $(cat "$T/s2/out.txt")"
[ "$(wc -l < "$T/s2/calls" | tr -d ' ')" = 2 ] && ok || bad "G7: the gate ran $(wc -l < "$T/s2/calls" | tr -d ' ') times, want 2 (before and after the restamp)"
mk s3 cnr; RC=$(spanrun s3)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/s3/out.txt" && ok || bad "G7: could-not-run -> exit $RC, want the push to go on: $(cat "$T/s3/out.txt")"
grep -q 'could-not-run' "$T/s3/build/section" 2>/dev/null && grep -q 'orphans' "$T/s3/build/section" 2>/dev/null && ok || bad "G7: the PR section does not say orphans could-not-run: $(cat "$T/s3/build/section" 2>/dev/null)"
mk s4 green; RC=$(spanrun s4)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/s4/out.txt" && ok || bad "G7: green -> exit $RC: $(cat "$T/s4/out.txt")"
# the off switch: prepush.gate_mode (warn | off | unreadable | junk)
mk m1 red; RC=$(SETV=warn spanrun m1)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/m1/out.txt" && grep -q 'mode warn' "$T/m1/build/section" && ok || bad "G7: warn -> exit $RC, want the push to go on with a note: $(cat "$T/m1/out.txt")"
mk m2 red; RC=$(SETV=off spanrun m2)
[ "$RC" = 0 ] && [ ! -e "$T/m2/calls" ] && ok || bad "G7: off -> exit $RC, gate calls: $(cat "$T/m2/calls" 2>/dev/null)"
mk m3 red; RC=$(SETV=UNREADABLE spanrun m3)
[ "$RC" = 6 ] && ok || bad "G7: an unreadable row -> exit $RC, want 6 (block)"
mk m4 red; RC=$(SETV=banana spanrun m4)
[ "$RC" = 6 ] && ok || bad "G7: a junk value -> exit $RC, want 6 (block)"
mkdir -p "$T/s5/co" "$T/s5/build"; RC=$(spanrun s5)
[ "$RC" = 0 ] && grep -q PUSH_REACHED "$T/s5/out.txt" && ok || bad "G7: no gate script -> exit $RC, want a no-op: $(cat "$T/s5/out.txt")"

echo "prepush-gate.bh-7187: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

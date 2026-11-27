#!/bin/bash
# tests/fast-lints-run.bh-3860-test.sh — bin/fast-lints.sh --run,
# --assert-budget and --share-precheck, and the two PR `lint` steps that call
# them (BH-3860 / BH-3862).
#
# Every case drives the real bin/fast-lints.sh, copied into a fixture repo, so
# ROOT is the fixture. HARNESS points at an empty tree so no live settings row
# reaches a knob. Nothing asserts wall-clock seconds; only rc, row shape and
# the rc column.
#   A1  --run: a real always-lint (tests/gh-rest-no-subshell-lint.sh) red on
#       an offender, green without it; skip file (argv form, unreadable);
#       empty set -> rc 2; the budget knob never changes --run's rc
#   A2  --share-precheck: RUN/SKIP over added, renamed, deleted, mixed, spaced
#       and upper-case paths; the sets are read from bin/share/mapping.py;
#       no merge base / no mapping.py -> rc 2
#   A3  --assert-budget: within; over budget and a slow row are notes at rc 0
#       (BH-5292); missing/empty/malformed -> rc 2; --budget-s overrides the knob
#   W1-4 the two workflow steps: placement, PR-only gate, the call shapes,
#       env-passed values and no ${{ }} inside run:
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REAL="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

mkdir -p "$T/h"
export HARNESS="$T/h"
unset FAST_LINTS_MAX_S FAST_LINTS_BUDGET_S PROJECT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TAB=$'\t'

N=0
fx() { # fx -> sets F to a fresh fixture repo
  N=$((N + 1)); F="$T/f$N"
  mkdir -p "$F/bin/lib" "$F/bin/share" "$F/catalog" "$F/tests/lib"
  git -C "$F" init -q
  cp "$REAL/bin/fast-lints.sh" "$REAL/bin/test-impact.sh" "$F/bin/"
  cp "$REAL/bin/share/mapping.py" "$REAL/bin/share/sanitize.py" "$REAL/bin/share/leakcheck.py" "$REAL/bin/share/diffcheck.py" \
     "$REAL/bin/share/js_rewrite.py" "$REAL/bin/share/public_test_fixes.py" "$F/bin/share/"
  cp "$REAL/tests/lib/scratch.sh" "$F/tests/lib/"
}
run() { # run [args...] -> RC, $F.out, $F.err
  FAST_LINTS_DURATIONS="$F/dur.tsv" "$F/bin/fast-lints.sh" "$@" > "$F.out" 2> "$F.err"
  RC=$?
}
errl() { cat "$F.err"; }

# ── A1: --run ───────────────────────────────────────────────────────────────
echo "A1: --run"
fx
cp "$REAL/tests/gh-rest-no-subshell-lint.sh" "$F/tests/"
printf '#!/bin/bash\nexit 0\n' > "$F/tests/a-test.sh"
printf '#!/bin/bash\nexit 0\n' > "$F/tests/b-test.sh"
printf 'tests/gh-rest-no-subshell-lint.sh x\ntests/a-test.sh a\ntests/b-test.sh b\n' > "$F/catalog/test-impact-always.txt"
printf 'tests/gh-rest-no-subshell-lint.sh\t1\t1\ntests/a-test.sh\t1\t1\ntests/b-test.sh\t1\t1\n' > "$F/dur.tsv"
printf '#!/bin/bash\nx=$(gh_rest GET repos/o/r)\necho "$x"\n' > "$F/bin/lib/x.sh"

run --list
grep -qxF tests/gh-rest-no-subshell-lint.sh "$F.out" && ok "A1a --list has the lint" || bad "A1a --list rc=$RC out=$(cat "$F.out")"
LIST=$(cat "$F.out")

run --run --out "$T/o1"
row=$(grep "^tests/gh-rest-no-subshell-lint.sh$TAB" "$T/o1/timings.tsv" 2>/dev/null)
nf=$(printf '%s\n' "$row" | awk -F'\t' '{print NF}')
c3=$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')
[ "$RC" = 1 ] && [ "$nf" = 3 ] && [ -n "$c3" ] && [ "$c3" != 0 ] \
  && ok "A1a offender -> rc 1, 3-field row with rc $c3" || bad "A1a rc=$RC row='$row' err=$(errl)"
grep -q -- '--- tests/gh-rest-no-subshell-lint.sh ---' "$F.err" \
  && ok "A1a the red suite's log is on stderr" || bad "A1a no log markers on stderr: $(errl)"

rm "$F/bin/lib/x.sh"
run --run --out "$T/o2"
c3s=$(awk -F'\t' '{print $3}' "$T/o2/timings.tsv" 2>/dev/null | sort -u)
[ "$RC" = 0 ] && [ "$c3s" = 0 ] && [ "$(wc -l < "$T/o2/timings.tsv")" = 3 ] \
  && ok "A1b clean -> rc 0, every rc column 0" || bad "A1b rc=$RC rcs='$c3s' err=$(errl)"
[ "$(cat "$T/o2/suites.txt" 2>/dev/null)" = "$LIST" ] && ok "A1b suites.txt == --list" \
  || bad "A1b suites.txt='$(cat "$T/o2/suites.txt" 2>/dev/null)'"
[ "$(grep -cE '^fast-lints: done tests/[^ ]+ rc=0 [0-9]+s$' "$F.out")" = 3 ] \
  && ok "A1b one done line per suite" || bad "A1b stdout=$(cat "$F.out")"
awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { exit 1 }' "$T/o2/timings.tsv" \
  && ok "A1b every row <suite>\\t<secs>\\t<rc>" || bad "A1b row shape: $(cat "$T/o2/timings.tsv")"
run --run --out "$T/o2"
[ "$(wc -l < "$T/o2/timings.tsv")" = 3 ] && ok "A1b a rerun into the same --out starts fresh" \
  || bad "A1b rerun rows=$(wc -l < "$T/o2/timings.tsv")"

printf '# rules pack ran\ntests/a-test.sh --flag\n\n' > "$T/skip"
run --run --out "$T/o3" --skip-suites "$T/skip"
[ "$RC" = 0 ] && ! grep -q 'a-test' "$T/o3/suites.txt" "$T/o3/timings.tsv" \
  && grep -qxF tests/b-test.sh "$T/o3/suites.txt" && grep -qxF tests/gh-rest-no-subshell-lint.sh "$T/o3/suites.txt" \
  && ok "A1c argv-form skip line skips a, runs the rest" || bad "A1c rc=$RC suites=$(cat "$T/o3/suites.txt" 2>/dev/null)"

run --run --out "$T/o5" --skip-suites "$T/nonexistent"
[ "$RC" = 0 ] && [ "$(grep -c unreadable "$F.err")" = 1 ] && [ "$(wc -l < "$T/o5/suites.txt")" = 3 ] \
  && ok "A1e unreadable skip file -> one note, nothing skipped" || bad "A1e rc=$RC err=$(errl)"

FAST_LINTS_BUDGET_S=1 run --run --out "$T/o6"
[ "$RC" = 0 ] && ok "A1f FAST_LINTS_BUDGET_S=1 leaves --run green" || bad "A1f rc=$RC"

printf 'tests/gh-rest-no-subshell-lint.sh\t5\t1\ntests/a-test.sh\t5\t1\ntests/b-test.sh\t5\t1\n' > "$F/dur.tsv"
run --run --out "$T/o4" --max-s 1
[ "$RC" = 2 ] && [ ! -s "$T/o4/timings.tsv" ] && grep -q 'empty' "$F.err" \
  && ok "A1d empty set -> rc 2, no rows" || bad "A1d rc=$RC err=$(errl)"

# ── A2: --share-precheck ────────────────────────────────────────────────────
echo "A2: --share-precheck"
fx
echo a > "$F/a.txt"; echo x > "$F/x.bin"
git -C "$F" add -A && git -C "$F" commit -qm base && git -C "$F" branch -q base
case_br() { git -C "$F" checkout -q -B "c$1" base; }
commit() { git -C "$F" add -A && git -C "$F" commit -qm "$1"; }
pre() { run --share-precheck --base "${1:-base}"; }
line1() { head -1 "$F.out"; }

case_br a; mkdir -p "$F/tests/fixtures"; echo b > "$F/tests/fixtures/foo.bin"; commit a; pre
[ "$RC" = 0 ] && [ "$(line1)" = RUN ] && grep -qxF '  tests/fixtures/foo.bin (.bin)' "$F.out" \
  && ok "A2a .bin -> RUN, named" || bad "A2a rc=$RC out=$(cat "$F.out") err=$(errl)"
case_br b; echo '{}' > "$F/foo.json"; echo f > "$F/foo.woff2"; echo m > "$F/Makefile"; echo '*.o' > "$F/.gitignore"; commit b; pre
[ "$RC" = 0 ] && [ "$(cat "$F.out")" = SKIP ] && ok "A2b json/woff2/extensionless/.gitignore -> SKIP" \
  || bad "A2b rc=$RC out=$(cat "$F.out") err=$(errl)"
case_br c; git -C "$F" mv a.txt a.bin; commit c; pre
[ "$RC" = 0 ] && [ "$(line1)" = RUN ] && grep -qxF '  a.bin (.bin)' "$F.out" \
  && ok "A2c rename a.txt -> a.bin -> RUN" || bad "A2c rc=$RC out=$(cat "$F.out")"
case_br d; git -C "$F" rm -q x.bin; commit d; pre
[ "$RC" = 0 ] && [ "$(cat "$F.out")" = SKIP ] && ok "A2d deleted .bin -> SKIP" || bad "A2d rc=$RC out=$(cat "$F.out")"
case_br e; echo p > "$F/my file.PNG"; commit e; pre
[ "$RC" = 0 ] && [ "$(line1)" = RUN ] && grep -qxF '  my file.PNG (.png)' "$F.out" \
  && ok "A2e spaced upper-case .PNG -> RUN (.png)" || bad "A2e rc=$RC out=$(cat "$F.out")"
case_br f; echo '{}' > "$F/m.json"; echo b > "$F/m.bin"; commit f; pre
[ "$RC" = 0 ] && [ "$(cat "$F.out")" = $'RUN\n  m.bin (.bin)' ] && ok "A2f mixed -> RUN listing only .bin" \
  || bad "A2f rc=$RC out=$(cat "$F.out")"
case_br g; printf '#!/bin/bash\n' > "$F/tool"; chmod +x "$F/tool"; echo q > "$F/blob.bin"; commit g; pre
[ "$RC" = 0 ] && [ "$(cat "$F.out")" = $'RUN\n  blob.bin (.bin)' ] && ok "A2g' extensionless stays out of RUN" \
  || bad "A2g' rc=$RC out=$(cat "$F.out")"

# The sets are READ from mapping.py: add .bin to the fixture's TEXT_EXT.
case_br a2; mkdir -p "$F/tests/fixtures"; echo b > "$F/tests/fixtures/foo.bin"; commit a2
sed -i 's/"\.drop", "",/".drop", "", ".bin",/' "$F/bin/share/mapping.py"
grep -q '"\.bin",' "$F/bin/share/mapping.py" || bad "A2g fixture edit did not land"
pre
[ "$RC" = 0 ] && [ "$(cat "$F.out")" = SKIP ] && ok "A2g .bin in mapping.py TEXT_EXT -> SKIP (read, not copied)" \
  || bad "A2g rc=$RC out=$(cat "$F.out")"
git -C "$F" checkout -q -- bin/share/mapping.py

pre nosuchref
[ "$RC" = 2 ] && [ ! -s "$F.out" ] && grep -q 'no merge base' "$F.err" \
  && ok "A2h no merge base -> rc 2" || bad "A2h rc=$RC out=$(cat "$F.out") err=$(errl)"
mv "$F/bin/share/mapping.py" "$T/mapping.py.bak"; pre
[ "$RC" = 2 ] && [ ! -s "$F.out" ] && grep -q 'mapping.py' "$F.err" \
  && ok "A2h no mapping.py -> rc 2" || bad "A2h' rc=$RC out=$(cat "$F.out") err=$(errl)"
mv "$T/mapping.py.bak" "$F/bin/share/mapping.py"

# ── A3: --assert-budget ─────────────────────────────────────────────────────
echo "A3: --assert-budget"
fx
tm() { printf '%b' "$1" > "$T/tm.tsv"; }
tm 'a\t3\t0\nb\t4\t0\n'
FAST_LINTS_BUDGET_S=10 run --assert-budget "$T/tm.tsv"
[ "$RC" = 0 ] && grep -q '7s within the 10s budget (2 suites)' "$F.out" "$F.err" \
  && ok "A3a 7s within 10 -> rc 0" || bad "A3a rc=$RC out=$(cat "$F.out") err=$(errl)"
# TEST-CHANGE BH-5292 (A3b, A3c, A3c'): over budget and a slow suite were rc 1.
# the operator changed the rule (2026-10-07): time is reported, never a red. Each case
# still proves the finding is NAMED (budget, slowest, the slow suite), and that
# a within-budget run does not print it; only the rc moved from 1 to 0.
FAST_LINTS_BUDGET_S=5 run --assert-budget "$T/tm.tsv"
[ "$RC" = 0 ] && grep -q '7s over the 5s budget' "$F.err" && grep -q 'slowest: b (4s), a (3s)' "$F.err" \
  && ! grep -q 'within' "$F.out" && ok "A3b 7s over 5 -> rc 0, budget + slowest named as a note" || bad "A3b rc=$RC err=$(errl)"
tm 'a\t3\t0\nb\t4\t0\nc\t25\t0\n'
FAST_LINTS_MAX_S=10 FAST_LINTS_BUDGET_S=600 run --assert-budget "$T/tm.tsv"
[ "$RC" = 0 ] && grep -q '^fast-lints: c took 25s, over 2 x FAST_LINTS_MAX_S (20s)' "$F.err" && ! grep -q 'over the' "$F.err" \
  && ok "A3c 25s row over 2 x 10 -> rc 0 naming c" || bad "A3c rc=$RC err=$(errl)"
FAST_LINTS_MAX_S=10 FAST_LINTS_BUDGET_S=20 run --assert-budget "$T/tm.tsv"
[ "$RC" = 0 ] && grep -q 'over the 20s budget' "$F.err" && grep -q 'c took 25s' "$F.err" \
  && ok "A3c' both findings print, rc 0" || bad "A3c' rc=$RC err=$(errl)"
run --assert-budget "$T/missing.tsv"
[ "$RC" = 2 ] && ok "A3d missing -> rc 2" || bad "A3d rc=$RC err=$(errl)"
: > "$T/tm.tsv"; run --assert-budget "$T/tm.tsv"
[ "$RC" = 2 ] && ok "A3e empty -> rc 2" || bad "A3e rc=$RC err=$(errl)"
tm '\n\n'; run --assert-budget "$T/tm.tsv"
[ "$RC" = 2 ] && ok "A3e blank lines only -> rc 2" || bad "A3e' rc=$RC err=$(errl)"
for m in 'a\tx\t0\n' 'a\t3\n' 'a\t3\t0\r\n' 'a\t3\t0\textra\n' 'a\t-1\t0\n'; do
  tm "b\t1\t0\n$m"; run --assert-budget "$T/tm.tsv"
  [ "$RC" = 2 ] && grep -q 'line 2' "$F.err" && ok "A3f malformed '$m' -> rc 2 naming line 2" || bad "A3f '$m' rc=$RC err=$(errl)"
done
tm 'a\t3\t0\nb\t4\t0\n'
FAST_LINTS_BUDGET_S=5 run --assert-budget "$T/tm.tsv" --budget-s 10
[ "$RC" = 0 ] && ok "A3g --budget-s 10 overrides FAST_LINTS_BUDGET_S=5" || bad "A3g rc=$RC err=$(errl)"

# ── W: the two workflow steps ──────────────────────────────────────────────
echo "W: the lint steps"
if ! python3 -c 'import yaml' 2>/dev/null; then
  if [ -n "${CI:-}" ]; then bad "W PyYAML missing on CI"; else echo "  skip: no PyYAML"; fi
else
  W=$(python3 - "$REAL/.github/workflows/harness-ci.yml" <<'PY'
import sys, yaml
# BH-4968: a batch runs its impact set, not the corpus, so both steps run on
# every pull_request, the merge-queue draft included.
GATE = "github.event_name == 'pull_request'"
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["lint"]["steps"]
names = [s.get("name") for s in steps]
def out(tag, cond): print(("ok   " if cond else "FAIL ") + tag)
try:
    i0 = names.index("model-id literal lint (BH-1510)")
    i1 = names.index("fast always-lints (BH-3860)")
    i2 = names.index("share-mirror leakcheck pre-check (BH-3860)")
except ValueError as e:
    out("W1 steps present: %s" % e, False); sys.exit(0)
out("W1 both steps after model-id literal lint", i0 < i1 < i2)
fast, share = steps[i1], steps[i2]
out("W1 fast step PR-only gate", fast.get("if") == GATE)
out("W1 share step PR-only gate", share.get("if") == GATE)
fr = fast.get("run", "")
for s in ('set +e', '--run --out "$o"', '--skip-suites "$o/rp/suites.txt"', '--assert-budget "$o/timings.tsv"',
          'bin/rules-pack.sh --runner local --base "origin/$BASE_REF" --skip determinism --out "$o/rp"'):
    out("W2 fast run has %s" % s, s in fr)
out("W2 --assert-budget comes after --run", 0 <= fr.find("--run --out") < fr.find("--assert-budget"))
# TEST-CHANGE BH-5292: the step used to require brc too. the operator changed the rule
# (2026-10-07): the budget is a report. The last line decides on the rules pack
# and the suites only, and the budget is still measured and printed.
last = [l.strip() for l in fr.splitlines() if l.strip()][-1] if fr.strip() else ""
out("W2 the last line requires only prc and frc", last == '[ "$prc" = 0 ] && [ "$frc" = 0 ]')
out("W2 the budget rc is still printed", "budget rc=$brc" in fr)
sr = share.get("run", "")
k = sr.find("= SKIP ] && exit 0"); s = sr.find("tests/share-publish-clean.bh-795-test.sh")
out("W3 SKIP exit precedes the share suite", 0 <= k < s)
out("W3 precheck answer gates first", 0 <= sr.find("--share-precheck --base \"origin/$BASE_REF\"") < k)
out("W4 no ${{ in either run", "${{" not in fr and "${{" not in sr)
fe, se = fast.get("env") or {}, share.get("env") or {}
out("W4 fast env carries BASE_REF + both knobs", {"BASE_REF", "FAST_LINTS_MAX_S", "FAST_LINTS_BUDGET_S"} <= set(fe))
out("W4 share env carries BASE_REF", "BASE_REF" in se)
PY
  )
  while IFS= read -r l; do
    case "$l" in "ok   "*) ok "${l#ok   }" ;; "FAIL "*) bad "${l#FAIL }" ;; esac
  done <<<"$W"
  [ -n "$W" ] || bad "W the workflow parse printed nothing"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

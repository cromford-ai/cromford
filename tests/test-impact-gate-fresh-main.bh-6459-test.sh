#!/bin/bash
# tests/test-impact-gate-fresh-main.bh-6459-test.sh — the builder gate runs the
# whole-repo suites on HEAD merged with fresh main, and `select --why` prints a
# learned path edge as `learned`, ranked above `closure` (BH-6459, C2 of #6390).
#
# A whole-repo ratchet can be green on HEAD and green on main, and red on the
# merge of the two. Before this the gate ran it on HEAD only, so the first run
# on the merge was the merge-queue batch. The fixture is that exact shape:
# tests/ceiling-test.sh fails when bin/ holds more than 4 one-letter scripts;
# HEAD adds bin/h.sh (4), main adds bin/m.sh (4), the merge has 5.
#
# The real gate, the real selector and the real suite runner, installed into a
# committed scratch repo. Every suite appends `<name> <fresh|head>` to
# $FIXTURE_LOG ("fresh" when bin/m.sh is in its tree).
#
#   F1-F14  the fresh-main pass: on, off, and the off reasons
#   O1      run order: segment A on HEAD, the fresh list, segment B on HEAD
#   B1      the prep and segment A share one budget
#   S1      suite reuse never sees a fresh suite
#   T1      the --table tag and header sentence
#   I1      the isolated runner (root with setpriv only)
#   X1-X2   --also (BH-6335): segment A, or the merge for an always suite
#   X3-X5   the fresh phase in either order still passes X1's phase order (BH-8358)
#   TR1-TR2 --runner traced: every segment runs under the trace
#   K1-K4   the `learned` kind in select --why
#   R1-R2   closure stays closure; the gate ranks learned above closure
#   P1-P4   HARNESS_IMPACT_GATE_RUN passes the knob; the registry rows
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0 FAIL=0
TAB=$(printf '\t')
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v git > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "test-impact-gate-fresh-main: SKIPPED — needs git and jq"
  echo "test-impact-gate-fresh-main: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── the fixture repo ────────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog/test-impact-learned.d"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\necho a\n' > "$R/bin/a.sh"
printf '#!/bin/bash\n# shellcheck source=bin/h0.sh\n. "$(dirname "$0")/h0.sh"\necho b\n' > "$R/bin/b.sh"
printf '#!/bin/bash\necho h0\n' > "$R/bin/h0.sh"
printf 'tests/ceiling-test.sh\n' > "$R/catalog/test-impact-always.txt"
# mark <name> — the log line every suite writes; "fresh" when bin/m.sh is here.
# The suite runner starts each suite in the tree root. A `$(dirname "$0")/..`
# here would give every suite a tests/ row, and the changed s-test would pick them all.
LOGLINE='where=head; ls bin | grep -qx m.sh && where=fresh
[ -n "${FIXTURE_LOG:-}" ] && echo "$(basename "$0" .sh) $where" >> "$FIXTURE_LOG"'
{ echo '#!/bin/bash'; echo "$LOGLINE"
  echo 'n=$(ls bin | grep -cE "^[a-z][0-9]?\.sh$")'
  echo '[ "$n" -le 4 ] || { echo "ceiling: $n one-letter scripts, the ceiling is 4"; exit 1; }'
  echo 'echo "ceiling: 1 passed, 0 failed"'; } > "$R/tests/ceiling-test.sh"
{ echo '#!/bin/bash'; echo "$LOGLINE"; echo 'echo "w: 1 passed, 0 failed"'; } > "$R/tests/w-test.sh"
{ echo '#!/bin/bash'; echo "$LOGLINE"; echo 'echo "l: 1 passed, 0 failed"'; } > "$R/tests/l-test.sh"
{ echo '#!/bin/bash'; echo "$LOGLINE"; echo 'bash "$DIR/bin/a.sh" > /dev/null'; echo 'echo "a: 1 passed, 0 failed"'; } \
  | sed '2i DIR=$PWD' > "$R/tests/a-test.sh"
{ echo '#!/bin/bash'; echo "$LOGLINE"; echo 'bash "$DIR/bin/b.sh" > /dev/null'; echo 'echo "c: 1 passed, 0 failed"'; } \
  | sed '2i DIR=$PWD' > "$R/tests/c-test.sh"
# s-test: the diff's own suite (self). Under FAKE_CLOCK it adds SLOW_SUITE
# seconds to the stub clock instead of sleeping (the bh-1524 G9 pattern).
{ echo '#!/bin/bash'; echo "$LOGLINE"
  echo 'if [ -n "${FAKE_CLOCK:-}" ]; then echo $(( $(cat "$FAKE_CLOCK") + ${SLOW_SUITE:-0} )) > "$FAKE_CLOCK"; fi'
  echo 'echo "s: 1 passed, 0 failed"'; } > "$R/tests/s-test.sh"
printf '*\ttests/w-test.sh\tbatch-1\t2026-10-01\n' > "$R/catalog/test-impact-learned.d/w.tsv"
printf 'bin/h0.sh\ttests/l-test.sh\tbatch-2\t2026-10-01\n' > "$R/catalog/test-impact-learned.d/l.tsv"
# A stub tracer for --runner traced (bh-6335's suites pin the real one). It
# runs the one suite, and calls the trace dirty for w-test on the merged tree.
cat > "$R/bin/test-trace-safety.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in --gate) ;; --only-file) f=$2; shift ;; --verdict) v=$2; shift ;; *) root=$1 ;; esac
  shift
done
cd "$root" || exit 2
bash bin/test-suite-run.sh --only-file "$f" tests tests/mc; r=$?
t=clean; [ -e bin/m.sh ] && grep -qx tests/w-test.sh "$f" && t=dirty
echo "trace=$t" > "$v"
[ "$t" = clean ] && exit "$r"; exit 1
SH
chmod +x "$R"/tests/*.sh "$R"/bin/*.sh
G() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q -b main && G add -A && G commit -qm A || { echo "cannot build the fixture"; exit 1; }
A=$(G rev-parse HEAD)
G checkout -q -b head
printf '#!/bin/bash\necho h\n' > "$R/bin/h.sh"
printf '#!/bin/bash\necho a-head\n' > "$R/bin/a.sh"
printf '#!/bin/bash\necho h0-head\n' > "$R/bin/h0.sh"
printf '# touched\n' >> "$R/tests/s-test.sh"
G add -A && G commit -qm H || exit 1
H=$(G rev-parse HEAD)
G checkout -q -b conflict "$A"
printf '#!/bin/bash\necho a-conflict\n' > "$R/bin/a.sh"
G commit -qam conflict || exit 1
G checkout -q main
printf '#!/bin/bash\necho m\n' > "$R/bin/m.sh"
G add -A && G commit -qm M || exit 1
M=$(G rev-parse HEAD)
G checkout -q head
M12=${M:0:12}; M8=${M:0:8}

export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
export TEST_IMPACT_GATE_TIERS="$T/no-tiers.tsv"
unset TEST_IMPACT_GATE_FRESH_MAIN SUITE_REUSE SUITE_REUSE_RUN_KEY GITHUB_ACTIONS
: > "$T/fast.empty"

# gate <tag> [args...] — the real gate in $R; output $T/<tag>.out, rc GRC,
# suite log $T/<tag>.log, failed list $T/<tag>.failed, table $T/<tag>.md.
gate() {
  local tag="$1"; shift
  : > "$T/$tag.log"
  ( cd "$R" && FIXTURE_LOG="$T/$tag.log" bin/test-impact-gate.sh --base "$A" \
      --failed "$T/$tag.failed" --table "$T/$tag.md" "$@" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
has()  { grep -qxF "$2" "$T/$1.log"; }
outs() { grep -qF -- "$2" "$T/$1.out"; }
# phase_order <tag> — the done-line order of $T/<tag>.out, with each contiguous
# run of fresh suites (rows `<name> fresh` in $T/<tag>.log) printed as one
# sorted {set}. The phases are ordered; the suites inside the fresh phase are
# not, because the gate sorts a tier by the recorded duration, a hint (BH-8358).
# A fresh suite split from its group by a HEAD suite gives two groups.
phase_order() {
  local fresh s grp="" out=""
  fresh=$(awk '$2 == "fresh" { print "tests/" $1 ".sh" }' "$T/$1.log")
  while read -r s; do
    if [ -n "$fresh" ] && grep -qxF -- "$s" <<<"$fresh"; then grp+="$s"$'\n'; continue; fi
    if [ -n "$grp" ]; then out+="{$(printf '%s' "$grp" | LC_ALL=C sort | paste -sd' ' -)} "; grp=""; fi
    out+="$s "
  done < <(grep '^impact-gate: done ' "$T/$1.out" | awk '{ print $3 }')
  [ -n "$grp" ] && out+="{$(printf '%s' "$grp" | LC_ALL=C sort | paste -sd' ' -)} "
  printf '%s' "${out% }"
}
# raw_order <tag> — the done-line order as it ran, space-joined.
raw_order() { grep '^impact-gate: done ' "$T/$1.out" | awk '{ print $3 }' | paste -sd' ' -; }

# ── F1 / F3 / O1: main ahead, merges clean, the ceiling is red on the merge ─
gate f1 --fresh-main on --fresh-ref main --runner local
[ "$GRC" = 1 ] && ok "F1 rc 1" || bad "F1 rc=$GRC: $(tail -8 "$T/f1.out")"
has f1 "ceiling-test fresh" && has f1 "w-test fresh" && ok "F1 the whole-repo suites ran on the merge" \
  || bad "F1 log: $(cat "$T/f1.log")"
outs f1 "impact-gate: fresh main $M12: ran 2 of 2 whole-repo suite(s) on HEAD merged with it: FAILED" \
  && ok "F1 the fresh line says FAILED, 2 of 2" || bad "F1 no fresh line: $(grep fresh "$T/f1.out")"
grep -qxF tests/ceiling-test.sh "$T/f1.failed" && ok "F1 --failed names the ceiling suite" \
  || bad "F1 failed list: $(cat "$T/f1.failed")"
has f1 "a-test head" && has f1 "l-test head" && has f1 "c-test head" && has f1 "s-test head" \
  && ok "F3 path picks run on HEAD" || bad "F3 log: $(cat "$T/f1.log")"
ORDER=$(phase_order f1)
[ "$ORDER" = "tests/s-test.sh {tests/ceiling-test.sh tests/w-test.sh} tests/a-test.sh tests/l-test.sh tests/c-test.sh" ] \
  && ok "O1 order: self on HEAD, fresh, then the rest on HEAD" || bad "O1 order: $ORDER plan: $(grep "^plan:" "$T/f1.out")"

# ── F2: the switch off is today's gate ──────────────────────────────────────
gate f2 --fresh-main off --runner local
[ "$GRC" = 0 ] && ok "F2 rc 0" || bad "F2 rc=$GRC: $(tail -5 "$T/f2.out")"
has f2 "ceiling-test head" && ok "F2 the ceiling ran on HEAD" || bad "F2 log: $(cat "$T/f2.log")"
grep -q fresh "$T/f2.out" && bad "F2 the output names fresh: $(grep fresh "$T/f2.out")" || ok "F2 no fresh line"

# ── F4: main is already in HEAD ─────────────────────────────────────────────
gate f4 --fresh-main on --fresh-ref "$A" --runner local
[ "$GRC" = 0 ] && outs f4 "impact-gate: fresh-main: off (head already contains main" && ok "F4 off: head contains main" \
  || bad "F4 rc=$GRC: $(grep fresh "$T/f4.out")"
grep -q '^impact-gate: fresh main .* ran ' "$T/f4.out" && bad "F4 a ran line on an off pass" || ok "F4 no ran line"

# ── F5: a conflict is off, never red ───────────────────────────────────────
gate f5 --fresh-main on --fresh-ref conflict --runner local
[ "$GRC" = 0 ] && outs f5 "impact-gate: fresh-main: off (head conflicts with main" && has f5 "ceiling-test head" \
  && ok "F5 off: conflict, the ceiling ran on HEAD" || bad "F5 rc=$GRC: $(grep fresh "$T/f5.out") log: $(cat "$T/f5.log")"

# ── F6 / F7 / F8: no origin, a bad ref, the plan runner ─────────────────────
gate f6 --fresh-main on --runner local
[ "$GRC" = 0 ] && outs f6 "impact-gate: fresh-main: off (no origin remote)" && ok "F6 off: no origin" \
  || bad "F6 rc=$GRC: $(grep fresh "$T/f6.out")"
gate f7 --fresh-main on --fresh-ref nosuch --runner local
outs f7 "impact-gate: fresh-main: off (cannot resolve nosuch)" && ok "F7 off: cannot resolve" || bad "F7: $(grep fresh "$T/f7.out")"
gate f8 --fresh-main on --fresh-ref main --runner plan
outs f8 "impact-gate: fresh-main: off (runner plan)" && outs f8 "NOT RUN" && ok "F8 off: runner plan" \
  || bad "F8: $(grep -e fresh -e 'NOT RUN' "$T/f8.out")"

# ── F9 / F10: the env switch, and bad values ────────────────────────────────
TEST_IMPACT_GATE_FRESH_MAIN=1 gate f9 --fresh-ref main --runner local
[ "$GRC" = 1 ] && has f9 "ceiling-test fresh" && ok "F9 env 1 turns it on" || bad "F9 rc=$GRC log: $(cat "$T/f9.log")"
gate f9b --fresh-ref main --runner local
[ "$GRC" = 0 ] && has f9b "ceiling-test head" && ! grep -q fresh-main "$T/f9b.out" && ok "F9 env unset is off" \
  || bad "F9b rc=$GRC: $(grep fresh "$T/f9b.out")"
gate f10 --fresh-main maybe --runner local
[ "$GRC" = 2 ] && ok "F10 --fresh-main maybe is rc 2" || bad "F10 rc=$GRC"
TEST_IMPACT_GATE_FRESH_MAIN=x gate f10b --runner local
[ "$GRC" = 2 ] && ok "F10 env x is rc 2" || bad "F10b rc=$GRC"

# ── F11: the real fetch from origin, into a private ref only ────────────────
git clone -q --bare "$R" "$T/origin.git" || exit 1
G remote add origin "$T/origin.git"
G update-ref refs/remotes/origin/main "$A"
gate f11 --fresh-main on --runner local
[ "$GRC" = 1 ] && has f11 "ceiling-test fresh" && ok "F11 fetched main from origin and ran on the merge" \
  || bad "F11 rc=$GRC: $(grep -e fresh "$T/f11.out") log: $(cat "$T/f11.log")"
[ -z "$(G for-each-ref refs/harness/)" ] && ok "F11 no refs/harness/ ref is left" || bad "F11 left: $(G for-each-ref refs/harness/)"
[ "$(G rev-parse refs/remotes/origin/main)" = "$A" ] && ok "F11 origin/main did not move" \
  || bad "F11 origin/main moved to $(G rev-parse refs/remotes/origin/main)"
G remote remove origin

# ── F12: an always suite the cap left is not run anywhere ───────────────────
gate f12 --fresh-main on --fresh-ref main --runner local --cap 1
awk '/left to CI by the cap/{f=1} f' "$T/f12.out" | grep -q 'tests/ceiling-test.sh' && ! grep -q ceiling "$T/f12.log" \
  && ok "F12 the capped ceiling is left to CI and never ran" || bad "F12: $(cat "$T/f12.out") log: $(cat "$T/f12.log")"

# ── F13 / F14: a fetch that fails, and a merge-tree that fails ──────────────
G remote add origin "$T/no-such-origin.git"
gate f13 --fresh-main on --runner local
G remote remove origin
[ "$GRC" = 0 ] && outs f13 "impact-gate: fresh-main: off (fetch of origin main failed (rc " && has f13 "ceiling-test head" \
  && ok "F13 off: the fetch failed, the ceiling ran on HEAD" || bad "F13 rc=$GRC: $(grep fresh "$T/f13.out")"
G checkout -q --orphan unrelated && printf 'x\n' > "$R/unrelated.txt" && G add -A && G commit -qm U || exit 1
G checkout -q -f head
gate f14 --fresh-main on --fresh-ref unrelated --runner local
[ "$GRC" = 0 ] && outs f14 "impact-gate: fresh-main: off (merge-tree failed (rc " && has f14 "ceiling-test head" \
  && ok "F14 off: unrelated histories, the ceiling ran on HEAD" || bad "F14 rc=$GRC: $(grep fresh "$T/f14.out")"

# ── B1: the budget is one counter across the segments ───────────────────────
mkdir -p "$T/fakebin"
cat > "$T/fakebin/date" <<SH
#!/bin/bash
[ -n "\${FAKE_CLOCK:-}" ] && [ "\$*" = "+%s" ] && { cat "\$FAKE_CLOCK"; exit 0; }
exec $(command -v date) "\$@"
SH
chmod +x "$T/fakebin/date"
echo 1000000 > "$T/clock"
PATH="$T/fakebin:$PATH" FAKE_CLOCK="$T/clock" SLOW_SUITE=2 \
  gate b1 --fresh-main on --fresh-ref main --runner local --budget 2
outs b1 "impact-gate: fresh main $M12: ran 0 of 2 whole-repo suite(s)" && ok "B1 the fresh line says ran 0 of 2" \
  || bad "B1: $(grep fresh "$T/b1.out")"
awk '/not started, left to CI/{f=1} f' "$T/b1.out" | grep -q 'tests/ceiling-test.sh' && ! grep -q ceiling "$T/b1.log" \
  && ok "B1 the fresh suites are left to CI by the budget" || bad "B1: $(cat "$T/b1.out")"

# ── S1: suite reuse never sees a fresh suite ────────────────────────────────
cat > "$R/bin/suite-reuse.sh" <<SH
#!/bin/bash
[ "\$1" = plan ] || exit 0
while [ \$# -gt 0 ]; do
  case "\$1" in --suites) in=\$2 ;; --run) run=\$2 ;; --reused) ru=\$2 ;; --fingerprints) fp=\$2 ;; esac
  shift
done
cp "\$in" "\$SR_COPY"; cp "\$in" "\$run"; : > "\$ru"; : > "\$fp"
SH
chmod +x "$R/bin/suite-reuse.sh"
G remote add origin https://github.com/example/fixture-repo.git
SR_COPY="$T/s1-on.in" gate s1a --fresh-main on --fresh-ref main --runner local
SR_COPY="$T/s1-off.in" gate s1b --fresh-main off --runner local
G remote remove origin; rm -f "$R/bin/suite-reuse.sh"
if [ -r "$T/s1-on.in" ] && ! grep -q -e ceiling -e w-test "$T/s1-on.in" && grep -q a-test "$T/s1-on.in"; then
  ok "S1 fresh on: no fresh suite in the reuse input"
else bad "S1 on: $(cat "$T/s1-on.in" 2>/dev/null) out: $(grep suite-reuse "$T/s1a.out")"; fi
grep -q ceiling "$T/s1-off.in" 2>/dev/null && grep -q w-test "$T/s1-off.in" && ok "S1 fresh off: both in the reuse input" \
  || bad "S1 off: $(cat "$T/s1-off.in" 2>/dev/null)"

# ── T1: the table ───────────────────────────────────────────────────────────
grep -F '`tests/ceiling-test.sh`' "$T/f1.md" | grep -qF "(fresh main $M8)" && ok "T1 the ceiling row is tagged" \
  || bad "T1 table: $(cat "$T/f1.md")"
sed -n 2p "$T/f1.md" | grep -qF "Ran on HEAD merged with main $M8: 2." && ok "T1 the header names the merge" \
  || bad "T1 header: $(sed -n 2p "$T/f1.md")"
grep -qi fresh "$T/f2.md" && bad "T1 a switch-off table names fresh" || ok "T1 switch off: no fresh in the table"
sed -n 2p "$T/f4.md" | grep -qF "Fresh main: off (head already contains main" && ok "T1 an off pass says why in the table" \
  || bad "T1 off header: $(sed -n 2p "$T/f4.md")"

# ── I1: the isolated runner ─────────────────────────────────────────────────
if [ "$(id -u)" = 0 ] && command -v setpriv > /dev/null 2>&1 && id nobody > /dev/null 2>&1 \
   && setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups true > /dev/null 2>&1; then
  gate i1 --fresh-main on --fresh-ref main --runner isolated
  [ "$GRC" = 1 ] && grep -q '^impact-gate: done tests/ceiling-test.sh rc=1' "$T/i1.out" \
    && outs i1 "fresh main $M12: ran 2 of 2 whole-repo suite(s) on HEAD merged with it: FAILED" \
    && grep -q '^impact-gate: done tests/s-test.sh rc=0' "$T/i1.out" \
    && ok "I1 isolated: the ceiling is red on the merge only" || bad "I1 rc=$GRC: $(tail -15 "$T/i1.out")"
else
  echo "  I1: isolated runner not available here — not run"
fi

# ── X1 / X2: --also suites (BH-6335) ────────────────────────────────────────
# X1: a learned --also suite runs first, on HEAD, in segment A.
printf 'tests/c-test.sh\n' > "$T/also-c.txt"
gate x1 --fresh-main on --fresh-ref main --runner local --also "$T/also-c.txt"
X1_ORDER="tests/c-test.sh tests/s-test.sh {tests/ceiling-test.sh tests/w-test.sh} tests/a-test.sh tests/l-test.sh"
ORDER=$(phase_order x1)
[ "$GRC" = 1 ] && has x1 "c-test head" \
  && [ "$ORDER" = "$X1_ORDER" ] \
  && ok "X1 the --also suite runs first on HEAD, then self, fresh, the rest" \
  || bad "X1 rc=$GRC order: $ORDER log: $(cat "$T/x1.log")"
# X2: an --also suite that is also an always suite runs on the merge, once.
printf 'tests/w-test.sh\n' > "$T/also-w.txt"
gate x2 --fresh-main on --fresh-ref main --runner local --also "$T/also-w.txt"
has x2 "w-test fresh" && ! has x2 "w-test head" && ok "X2 the --also always suite ran on the merge only" \
  || bad "X2 log: $(cat "$T/x2.log")"
grep -F '`tests/w-test.sh`' "$T/x2.md" | grep -qF "(fresh main $M8) learned (failed merge-queue batches)" \
  && ok "X2 its row has the fresh tag and keeps the learned reason first" || bad "X2 table: $(grep w-test "$T/x2.md")"
# X3 / X4: the fresh phase in both orders (BH-8358). Each case seeds its own
# durations file, so the gate's shortest-first hint runs w-test first in X3 and
# ceiling-test first in X4. X1's phase order holds for both.
printf 'tests/ceiling-test.sh\t5\ntests/w-test.sh\t0\n' > "$T/x3.tsv"
TEST_IMPACT_DURATIONS_FILE="$T/x3.tsv" gate x3 --fresh-main on --fresh-ref main --runner local --also "$T/also-c.txt"
RAW=$(raw_order x3)
[ "$GRC" = 1 ] && [[ "$RAW" == *"tests/w-test.sh tests/ceiling-test.sh"* ]] && [ "$(phase_order x3)" = "$X1_ORDER" ] \
  && ok "X3 w-test ran first in the fresh phase, the phase order holds" \
  || bad "X3 rc=$GRC raw: $RAW phases: $(phase_order x3)"
printf 'tests/ceiling-test.sh\t0\ntests/w-test.sh\t5\n' > "$T/x4.tsv"
TEST_IMPACT_DURATIONS_FILE="$T/x4.tsv" gate x4 --fresh-main on --fresh-ref main --runner local --also "$T/also-c.txt"
RAW=$(raw_order x4)
[ "$GRC" = 1 ] && [[ "$RAW" == *"tests/ceiling-test.sh tests/w-test.sh"* ]] && [ "$(phase_order x4)" = "$X1_ORDER" ] \
  && ok "X4 ceiling-test ran first in the fresh phase, the phase order holds" \
  || bad "X4 rc=$GRC raw: $RAW phases: $(phase_order x4)"
# X5: phase_order itself. A HEAD suite between two fresh suites is two groups,
# so an interleaved run never matches X1's phase order.
printf 'c-test head\ns-test head\nceiling-test fresh\na-test head\nw-test fresh\nl-test head\n' > "$T/x5.log"
for s in c s ceiling a w l; do echo "impact-gate: done tests/$s-test.sh rc=0 (0s)"; done > "$T/x5.out"
[ "$(phase_order x5)" = "tests/c-test.sh tests/s-test.sh {tests/ceiling-test.sh} tests/a-test.sh {tests/w-test.sh} tests/l-test.sh" ] \
  && ok "X5 a split fresh phase gives two groups" || bad "X5 phases: $(phase_order x5)"

# ── TR1 / TR2: --runner traced (BH-6335) ────────────────────────────────────
gate tr1 --fresh-main on --fresh-ref main --runner traced --trace-hits "$T/tr1.hits"
[ "$GRC" = 1 ] && has tr1 "ceiling-test fresh" && has tr1 "w-test fresh" && has tr1 "s-test head" && has tr1 "a-test head" \
  && ok "TR1 traced: the fresh list ran on the merge, the rest on HEAD" || bad "TR1 rc=$GRC log: $(cat "$T/tr1.log") out: $(tail -5 "$T/tr1.out")"
[ "$(cat "$T/tr1.hits" 2>/dev/null)" = tests/w-test.sh ] && ok "TR1 the fresh segment ran under the trace (hit named)" \
  || bad "TR1 hits: '$(cat "$T/tr1.hits" 2>/dev/null)'"
outs tr1 "impact-gate: fresh main $M12: ran 2 of 2 whole-repo suite(s) on HEAD merged with it: FAILED" \
  && ok "TR1 the fresh line says FAILED, 2 of 2" || bad "TR1: $(grep fresh "$T/tr1.out")"
gate tr2 --fresh-main off --runner traced --trace-hits "$T/tr2.hits"
[ "$GRC" = 0 ] && [ -e "$T/tr2.hits" ] && [ ! -s "$T/tr2.hits" ] && has tr2 "w-test head" \
  && ok "TR2 traced, switch off: rc 0, no hit" || bad "TR2 rc=$GRC hits '$(cat "$T/tr2.hits" 2>/dev/null)'"

# ── K: the learned kind ─────────────────────────────────────────────────────
( cd "$R" && bin/test-impact.sh --root "$R" select "$A..$H" --map-only --why ) > "$T/why" 2> "$T/why.err"
grep -qxF "tests/l-test.sh${TAB}learned${TAB}bin/h0.sh" "$T/why" && ok "K1 l-test learned bin/h0.sh" \
  || bad "K1: $(grep l-test "$T/why" | tr '\t' ' ') err: $(tail -2 "$T/why.err")"
grep -qxF "tests/w-test.sh${TAB}always${TAB}*" "$T/why" && ! grep -q "^tests/w-test.sh${TAB}learned" "$T/why" \
  && ok "K3 a learned * row stays always" || bad "K3: $(grep w-test "$T/why" | tr '\t' ' ')"
grep -qxF "tests/c-test.sh${TAB}closure${TAB}bin/h0.sh" "$T/why" && ok "R1 closure is still closure" \
  || bad "R1: $(grep c-test "$T/why" | tr '\t' ' ')"
# K2: a learned row for a path the suite also runs is source.
cp -a "$R" "$T/k2"
printf 'bin/a.sh\ttests/a-test.sh\tbatch-3\t2026-10-01\n' > "$T/k2/catalog/test-impact-learned.d/a.tsv"
"$T/k2/bin/test-impact.sh" --root "$T/k2" select "$A..$H" --map-only --why > "$T/why-k2" 2> /dev/null
grep -qxF "tests/a-test.sh${TAB}source${TAB}bin/a.sh" "$T/why-k2" && ! grep -q "^tests/a-test.sh${TAB}learned" "$T/why-k2" \
  && ok "K2 learned + named stays source" || bad "K2: $(grep a-test "$T/why-k2" | tr '\t' ' ')"
# K4: a learned directory row, and --map with a prebuilt map.
cp -a "$R" "$T/k4"
printf 'bin/\ttests/l-test.sh\tbatch-4\t2026-10-01\n' > "$T/k4/catalog/test-impact-learned.d/dir.tsv"
"$T/k4/bin/test-impact.sh" --root "$T/k4" select "$A..$H" --map-only --why > "$T/why-k4" 2> /dev/null
grep -qxF "tests/l-test.sh${TAB}learned${TAB}bin/h.sh" "$T/why-k4" && ok "K4 a learned directory row prints learned" \
  || bad "K4: $(grep l-test "$T/why-k4" | tr '\t' ' ')"
"$R/bin/test-impact.sh" --root "$R" map > "$T/prebuilt.map" 2> /dev/null
"$R/bin/test-impact.sh" --root "$R" --map "$T/prebuilt.map" select "$A..$H" --map-only --why > "$T/why-map" 2> /dev/null
grep -qxF "tests/l-test.sh${TAB}learned${TAB}bin/h0.sh" "$T/why-map" && ok "K4 --map still prints learned" \
  || bad "K4 --map: $(grep l-test "$T/why-map" | tr '\t' ' ')"

# ── R2: the gate ranks learned above closure ────────────────────────────────
gate r2 --runner plan --cap 5
grep -qE '^plan: tests/l-test\.sh +learned bin/h0\.sh' "$T/r2.out" && ok "R2 l-test is in the plan, learned" \
  || bad "R2 l-test: $(grep l-test "$T/r2.out")"
awk '/left to CI by the cap/{f=1} f' "$T/r2.out" | grep -q 'tests/c-test.sh' && ok "R2 c-test (closure) is left by the cap" \
  || bad "R2: $(cat "$T/r2.out")"

# ── P: HARNESS_IMPACT_GATE_RUN hands the knob to the gate ───────────────────
awk '/^HARNESS_IMPACT_GATE_RUN\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DIR/bin/lib/rb/gates.sh" > "$T/gate-fn.sh"
W="$T/wt"; mkdir -p "$W/bin" "$T/build"
printf '#!/bin/bash\necho "FM=${TEST_IMPACT_GATE_FRESH_MAIN-unset}" > %q\necho "$*" >> %q\nexit 0\n' "$T/p-env" "$T/p-env" \
  > "$W/bin/test-impact-gate.sh"
chmod +x "$W/bin/test-impact-gate.sh"
# prun <lane_knob answer, or "none"> — the extracted function with a stub gate.
prun() {
  rm -f "$T/p-env"
  ( cd "$W" && unset TEST_IMPACT_GATE_FRESH_MAIN; BUILD="$T/build" BASE=bbb PROJECT=cromford KEY=K-1
    STAMP() { echo TS; }
    if [ "$1" != none ]; then eval "lane_knob() { [ \"\$2\" = TEST_IMPACT_GATE_FRESH_MAIN ] && echo '$1'; }"; fi
    . "$T/gate-fn.sh"; HARNESS_IMPACT_GATE_RUN suite.txt lenses ) > /dev/null 2>&1
  head -1 "$T/p-env" 2>/dev/null
}
[ "$(prun 0)" = FM=0 ] && ok "P1 knob 0 reaches the gate as 0" || bad "P1: $(prun 0)"
[ "$(sed -n 2p "$T/p-env")" = "--base bbb --project cromford --table $T/build/impact-gate-lenses.md" ] \
  && ok "P1 the gate argv is unchanged" || bad "P1 argv: $(sed -n 2p "$T/p-env")"
[ "$(prun 1)" = FM=1 ] && ok "P2 knob 1 reaches the gate as 1" || bad "P2: $(prun 1)"
[ "$(prun 7)" = FM=1 ] && ok "P2 knob 7 reaches the gate as 1" || bad "P2 7: $(prun 7)"
[ "$(prun none)" = FM=1 ] && ok "P4 no lane_knob is 1" || bad "P4: $(prun none)"
# The knob rows are fragments (BH-4987: a new knob is its own file).
KD="$DIR/catalog/lanes.d/fly-pool.knobs.d"
[ "$(jq -c '[.default, .min, .max]' "$KD/TEST_IMPACT_GATE_FRESH_MAIN.json" 2>/dev/null)" = '[1,0,1]' ] \
  && ok "P3 TEST_IMPACT_GATE_FRESH_MAIN 1 in 0..1" || bad "P3 fresh-main row"
[ "$(jq -c '[.default, .min, .max]' "$KD/TEST_IMPACT_GATE_FRESH_FETCH_S.json" 2>/dev/null)" = '[60,5,120]' ] \
  && ok "P3 TEST_IMPACT_GATE_FRESH_FETCH_S 60 in 5..120" || bad "P3 fetch row"

echo "test-impact-gate-fresh-main: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

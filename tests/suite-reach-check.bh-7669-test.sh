#!/bin/bash
# tests/suite-reach-check.bh-7669-test.sh — BH-7669: bin/suite-reach-check.sh
# runs every shell suite that names a file the PR changes, on the PR head and,
# when it is red there, on the merge base. A suite green on base and red on
# head (twice) stops the build through suite_reach_block
# (bin/lib/suite-reach-gate.sh), called from bin/lib/rb/execute.sh.
#
#   AT1-AT5  the ticket's evidence shapes: a knob default flip, deleted worker
#            tests behind a package.json test script, a selection-independent
#            lead-verdict break, red on both trees, a transient rc 75
#   L1-L10   the reach list (--list-only): path, $DIR/ prefix, near misses,
#            unique basename, non-unique basename, glob, package.json with no
#            test script, fixture-implied, `*/*` token, rank order
#   R1-R13   the runs: table, head-green skips base, flaky, base rc 75, head
#            timeout, cap, new suite, bad base, amended suite, budget, cap 0,
#            deleted suite, isolated runner that cannot start
#   G1-G7    the gate function over the real check and stub checks
#   W1       the `# >>> suite reach gate` block of bin/lib/rb/execute.sh
# Each case builds its own fixture git repo under $T/<case>; no clock, no
# network, no $RANDOM.
# Run from anywhere: tests/suite-reach-check.bh-7669-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_DATE='2026-10-20T00:00:00Z' GIT_COMMITTER_DATE='2026-10-20T00:00:00Z'
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONDUCTOR_LAUNCH

H="$T/h"
mkdir -p "$H"
scratch_install_closure bin/suite-reach-check.sh "$H" >/dev/null || bad "install bin/suite-reach-check.sh"
scratch_install_closure bin/lib/suite-reach-gate.sh "$H" >/dev/null || bad "install bin/lib/suite-reach-gate.sh"
CHECK="$H/bin/suite-reach-check.sh"
GATE_LIB="$H/bin/lib/suite-reach-gate.sh"

# ── fixture helpers ─────────────────────────────────────────────────────────
# put <repo> <path> <content> — write one file (parents made).
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; }
# snap <repo> <msg> — commit everything, print the sha.
snap() { git -C "$1" add -A >/dev/null && git -C "$1" commit -qm "$2" >/dev/null && git -C "$1" rev-parse HEAD; }
newrepo() { scratch_rm "$1"; mkdir -p "$1"; git -C "$1" init -q -b main >/dev/null; }
# suite <repo> <path> <body> — a tiny suite: <body> sets P and F, then the
# summary line and the exit.
suite() {
  put "$1" "$2" "#!/bin/bash
P=0; F=0
$3
echo \"$(basename "$2" .sh): \$P passed, \$F failed\"
[ \"\$F\" = 0 ]"
}
# runchk <outfile> <args...> — run the check, the rc on stdout.
runchk() { local o="$1"; shift; "$CHECK" "$@" > "$o" 2>"$o.err"; echo $?; }

# withcheck <repo> — the gate runs the worktree's own check, so a gate fixture
# carries the installed copy from its base commit on.
withcheck() { scratch_install_closure bin/suite-reach-check.sh "$1" >/dev/null || bad "install the check into $1"; }

# ── AT1 fixture: a knob default flip ───────────────────────────────────────
at1() { # at1 <dir> [check] — base: default 1 and two suites; head: default 0. Prints BASE.
  local d="$1" b
  newrepo "$d"
  [ -n "${2:-}" ] && withcheck "$d"
  put "$d" bin/wake-loop.sh 'CONDUCTOR_LAUNCH="${CONDUCTOR_LAUNCH:-1}"
echo "$CONDUCTOR_LAUNCH"'
  suite "$d" tests/wake-loop-test.sh '[ -n "${SR_LOG:-}" ] && echo "wake-loop-test $PWD" >> "$SR_LOG"
out=$(bash bin/wake-loop.sh)
if [ "$out" = 1 ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: conductor-launch default is 1"; fi'
  suite "$d" tests/wake-loop-shape-test.sh '[ -n "${SR_LOG:-}" ] && echo "shape-test $PWD" >> "$SR_LOG"
if [ -f bin/wake-loop.sh ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: bin/wake-loop.sh exists"; fi'
  b=$(snap "$d" base)
  sed -i 's/:-1}/:-0}/' "$d/bin/wake-loop.sh"
  snap "$d" head >/dev/null
  echo "$b"
}

# ── AT1 ──────────────────────────────────────────────────────────────────────
B=$(at1 "$T/at1")
export SR_LOG="$T/at1.runs"; : > "$SR_LOG"
RC=$(runchk "$T/at1.out" --tree "$T/at1" --base "$B" --runner local --table "$T/at1.md")
unset SR_LOG
[ "$RC" = 1 ] && ok || bad "AT1: rc $RC, want 1: $(cat "$T/at1.out" "$T/at1.out.err")"
grep -q '^RED: tests/wake-loop-test.sh .*case: FAIL: conductor-launch default is 1' "$T/at1.out" && ok \
  || bad "AT1: no RED line naming the suite and its case: $(cat "$T/at1.out")"
[ "$(tail -1 "$T/at1.out" | cut -d' ' -f1-2)" = "SUITE_REACH_VERDICT: red" ] && ok || bad "AT1: last line '$(tail -1 "$T/at1.out")'"
# R1: the table has a header and one row per suite, with p/f rc=n on both sides.
grep -q '^| suite | why | base | head | state |$' "$T/at1.md" && ok || bad "R1: no table header: $(cat "$T/at1.md")"
grep -q '^| tests/wake-loop-test.sh | .* | 1/0 rc=0 | 0/1 rc=1; 0/1 rc=1 | green→red |$' "$T/at1.md" && ok \
  || bad "R1: wake-loop-test row: $(grep wake-loop-test "$T/at1.md")"
# R2: a head-green suite never runs on base.
grep -q '^| tests/wake-loop-shape-test.sh | .* | not run (head green) | 1/0 rc=0 | green |$' "$T/at1.md" && ok \
  || bad "R2: shape-test row: $(grep shape-test "$T/at1.md")"
[ "$(grep -c '^shape-test ' "$T/at1.runs")" = 1 ] && ok || bad "R2: shape-test ran $(grep -c '^shape-test ' "$T/at1.runs") times, want 1"
[ "$(grep -c '^wake-loop-test ' "$T/at1.runs")" = 3 ] && ok || bad "AT1: wake-loop-test ran $(grep -c '^wake-loop-test ' "$T/at1.runs") times, want 3 (head, base, head)"

# ── AT2: a deleted worker test behind a package.json test script ────────────
D2="$T/at2"; newrepo "$D2"
put "$D2" worker/cloud/package.json '{"name":"cloud","scripts":{"test":"node --test test/"}}'
put "$D2" worker/cloud/test/a.test.js 'require("node:test");'
suite "$D2" tests/harness-ci-worker-jobs.bh-1137-test.sh 'DIR=$(cd "$(dirname "$0")/.." && pwd)
for p in "$DIR"/worker/*/package.json; do
  grep -q "\"test\"" "$p" || continue
  if compgen -G "$(dirname "$p")/test/*.test.js" >/dev/null; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $p has a test script and no test/*.test.js"; fi
done'
B=$(snap "$D2" base)
git -C "$D2" rm -q worker/cloud/test/a.test.js; snap "$D2" head >/dev/null
RC=$(runchk "$T/at2.out" --tree "$D2" --base "$B" --runner local)
[ "$RC" = 1 ] && ok || bad "AT2: rc $RC, want 1: $(cat "$T/at2.out" "$T/at2.out.err")"
grep -q '^RED: tests/harness-ci-worker-jobs.bh-1137-test.sh ' "$T/at2.out" && ok || bad "AT2: suite not named RED: $(cat "$T/at2.out")"
RC=$(runchk "$T/at2.list" --tree "$D2" --base "$B" --runner local --list-only)
[ "$RC" = 0 ] && ok || bad "AT2: --list-only rc $RC"
grep -qP '^tests/harness-ci-worker-jobs.bh-1137-test.sh\timplied worker/cloud/package.json ' "$T/at2.list" && ok \
  || bad "AT2: list why: $(cat "$T/at2.list")"

# ── AT3: lead-verdict, with no selector in the repo ─────────────────────────
D3="$T/at3"; newrepo "$D3"
put "$D3" bin/lead-verdict.sh '#!/bin/bash
set -u
extra=()
printf "%s\n" post ${extra[@]+"${extra[@]}"}'
suite "$D3" tests/lead-verdict-bash32.bh-3565-test.sh '# bash < 4.4 calls "${arr[@]}" of an empty array unbound under set -u.
if grep -nE "[^+]\"\\\$\{[a-z]+\[@\]\}\"" bin/lead-verdict.sh | grep -v "@]+" >/dev/null; then F=$((F+1)); echo "FAIL: unguarded array expansion in bin/lead-verdict.sh"; else P=$((P+1)); fi
out=$(bash bin/lead-verdict.sh); [ "$out" = post ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL: post prints post"; }'
B=$(snap "$D3" base)
put "$D3" bin/lead-verdict.sh '#!/bin/bash
set -u
extra=()
printf "%s\n" post "${extra[@]}"'
snap "$D3" head >/dev/null
[ ! -e "$D3/bin/test-impact.sh" ] && ok || bad "AT3: the fixture must carry no selector"
RC=$(runchk "$T/at3.out" --tree "$D3" --base "$B" --runner local)
[ "$RC" = 1 ] && ok || bad "AT3: rc $RC, want 1: $(cat "$T/at3.out" "$T/at3.out.err")"
grep -q '^RED: tests/lead-verdict-bash32.bh-3565-test.sh .*case: FAIL: unguarded array expansion' "$T/at3.out" && ok \
  || bad "AT3: suite not named RED: $(cat "$T/at3.out")"
# Real-text arm: this repo's own tests/ and bin/ at HEAD, plus one commit that
# touches bin/lead-verdict.sh.
D3R="$T/at3-real"; newrepo "$D3R"
git -C "$REPO" archive HEAD tests bin | tar -x -C "$D3R"
B=$(snap "$D3R" base)
printf '# touched\n' >> "$D3R/bin/lead-verdict.sh"; snap "$D3R" head >/dev/null
RC=$(runchk "$T/at3r.list" --tree "$D3R" --base "$B" --runner local --list-only)
[ "$RC" = 0 ] && ok || bad "AT3 real: --list-only rc $RC: $(cat "$T/at3r.list.err")"
grep -qP '^tests/lead-verdict-bash32.bh-3565-test.sh\tpath bin/lead-verdict.sh$' "$T/at3r.list" && ok \
  || bad "AT3 real: lead-verdict-bash32 not listed by path: $(head -5 "$T/at3r.list")"

# ── AT4: red on both trees is a NOTE ────────────────────────────────────────
at4() { # at4 <dir> [check] — a suite red on both trees. Prints BASE.
  local d="$1" b
  newrepo "$d"
  [ -n "${2:-}" ] && withcheck "$d"
  put "$d" bin/a.sh 'echo v1'
  suite "$d" tests/a-test.sh 'grep -q never-there bin/a.sh && P=$((P+1)) || { F=$((F+1)); echo "FAIL: bin/a.sh says never-there"; }'
  b=$(snap "$d" base); put "$d" bin/a.sh 'echo v2'; snap "$d" head >/dev/null
  echo "$b"
}
D4="$T/at4"; B=$(at4 "$D4")
RC=$(runchk "$T/at4.out" --tree "$D4" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "AT4: rc $RC, want 0: $(cat "$T/at4.out")"
grep -q '^\[NOTE\] tests/a-test.sh red on base and head' "$T/at4.out" && ok || bad "AT4: no NOTE line: $(cat "$T/at4.out")"
[ "$(tail -1 "$T/at4.out" | cut -d' ' -f1-2)" = "SUITE_REACH_VERDICT: clean" ] && ok || bad "AT4: last line '$(tail -1 "$T/at4.out")'"

# ── AT5: rc 75 on head is transient ─────────────────────────────────────────
D5="$T/at5"; newrepo "$D5"
put "$D5" bin/a.sh 'echo v1'
suite "$D5" tests/a-test.sh 'grep -q v2 bin/a.sh && { echo "a-test: rate limited"; exit 75; }; P=1'
B=$(snap "$D5" base); put "$D5" bin/a.sh 'echo v2'; snap "$D5" head >/dev/null
RC=$(runchk "$T/at5.out" --tree "$D5" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "AT5: rc $RC, want 0: $(cat "$T/at5.out")"
grep -q '^TRANSIENT: tests/a-test.sh rc=75' "$T/at5.out" && ok || bad "AT5: no TRANSIENT rc=75 line: $(cat "$T/at5.out")"
grep -q '^RED:' "$T/at5.out" && bad "AT5: a RED line on a transient" || ok

# ── L1-L10: the reach list ──────────────────────────────────────────────────
DL="$T/l"; newrepo "$DL"
put "$DL" bin/lead-verdict.sh 'echo lv'
put "$DL" bin/other.sh 'echo other'
put "$DL" bin/uniq-name.sh 'echo uniq'
put "$DL" worker/jobs/package.json '{"name":"jobs","scripts":{"test":"node --test test/"}}'
put "$DL" worker/nt/package.json '{"name":"nt"}'
put "$DL" worker/nt/test/b.test.js 'require("node:test");'
put "$DL" package.json '{"name":"root"}'
put "$DL" lib/gone.sh 'echo gone'
put "$DL" tests/fixtures/x/list.txt 'lib/gone.sh'
put "$DL" tests/s-path.sh 'bash bin/lead-verdict.sh'
put "$DL" tests/s-dir.sh 'bash "$DIR"/bin/other.sh'
put "$DL" tests/s-near.sh 'cat bin/lead-verdict.sh.bak xbin/lead-verdict.sh'
put "$DL" tests/s-base.sh 'run uniq-name.sh'
put "$DL" tests/s-pkg.sh 'jq . package.json'
put "$DL" tests/s-glob.sh 'for p in "$DIR"/worker/*/package.json; do :; done'
put "$DL" tests/s-nt.sh 'cat worker/nt/package.json'
put "$DL" tests/s-fix.sh 'cat tests/fixtures/x/list.txt'
put "$DL" tests/s-star.sh 'ls */*'
put "$DL" tests/s-comment.sh '# see bin/other.sh
true'
put "$DL" tests/s-self.sh 'true'
B=$(snap "$DL" base)
for f in bin/lead-verdict.sh bin/other.sh bin/uniq-name.sh; do printf '# head\n' >> "$DL/$f"; done
put "$DL" worker/jobs/package.json '{"name":"jobs","scripts":{"test":"node --test test/","lint":"true"}}'
put "$DL" tests/s-self.sh 'true # head'
git -C "$DL" rm -q worker/nt/test/b.test.js lib/gone.sh
snap "$DL" head >/dev/null
RC=$(runchk "$T/l.list" --tree "$DL" --base "$B" --runner local --list-only)
[ "$RC" = 0 ] && ok || bad "L: --list-only rc $RC: $(cat "$T/l.list.err")"
why() { awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$T/l.list"; }
[ "$(why tests/s-path.sh)" = "path bin/lead-verdict.sh" ] && ok || bad "L1: s-path why '$(why tests/s-path.sh)'"
[ "$(why tests/s-dir.sh)" = "path bin/other.sh" ] && ok || bad "L2: s-dir why '$(why tests/s-dir.sh)'"
[ -z "$(why tests/s-near.sh)" ] && ok || bad "L3: near miss listed: '$(why tests/s-near.sh)'"
[ "$(why tests/s-base.sh)" = "basename uniq-name.sh (bin/uniq-name.sh)" ] && ok || bad "L4: s-base why '$(why tests/s-base.sh)'"
[ -z "$(why tests/s-pkg.sh)" ] && ok || bad "L5: non-unique package.json listed: '$(why tests/s-pkg.sh)'"
[ "$(why tests/s-glob.sh)" = "glob worker/*/package.json ~ worker/jobs/package.json" ] && ok || bad "L6: s-glob why '$(why tests/s-glob.sh)'"
[ -z "$(why tests/s-nt.sh)" ] && ok || bad "L7: a package.json with no test script was implied: '$(why tests/s-nt.sh)'"
[ "$(why tests/s-fix.sh)" = "implied tests/fixtures/x/list.txt (fixture names deleted lib/gone.sh)" ] && ok \
  || bad "L8: s-fix why '$(why tests/s-fix.sh)'"
[ -z "$(why tests/s-star.sh)" ] && ok || bad "L9: a */* token matched: '$(why tests/s-star.sh)'"
[ "$(cut -f1 "$T/l.list" | tr '\n' ' ')" = "tests/s-self.sh tests/s-dir.sh tests/s-path.sh tests/s-fix.sh tests/s-glob.sh tests/s-base.sh tests/s-comment.sh " ] \
  && ok || bad "L10: rank order: $(cut -f1 "$T/l.list" | tr '\n' ' ')"
[ "$(why tests/s-self.sh)" = self ] && ok || bad "L10: s-self why '$(why tests/s-self.sh)'"
[ "$(why tests/s-comment.sh)" = "comment bin/other.sh" ] && ok || bad "L10: s-comment why '$(why tests/s-comment.sh)'"
[ ! -s "$T/l.list.err" ] || [ -z "$(grep -v '^suite-reach: warning' "$T/l.list.err")" ] && ok || bad "L: stderr: $(cat "$T/l.list.err")"

# ── R3: red then green on the second head run is flaky, not red ─────────────
DR="$T/r3"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
suite "$DR" tests/a-test.sh 'if grep -q v2 bin/a.sh && [ ! -e "$SR_FLAKE" ]; then : > "$SR_FLAKE"; F=1; echo "FAIL: first run"; else P=1; fi'
B=$(snap "$DR" base); put "$DR" bin/a.sh 'echo v2'; snap "$DR" head >/dev/null
RC=$(SR_FLAKE="$T/r3.flake" runchk "$T/r3.out" --tree "$DR" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "R3: rc $RC, want 0: $(cat "$T/r3.out")"
grep -q '^TRANSIENT: tests/a-test.sh .*flaky' "$T/r3.out" && ok || bad "R3: no flaky TRANSIENT line: $(cat "$T/r3.out")"

# ── R4: base rc 75 ──────────────────────────────────────────────────────────
DR="$T/r4"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
suite "$DR" tests/a-test.sh 'grep -q v1 bin/a.sh && exit 75; F=1; echo "FAIL: v2"'
B=$(snap "$DR" base); put "$DR" bin/a.sh 'echo v2'; snap "$DR" head >/dev/null
RC=$(runchk "$T/r4.out" --tree "$DR" --base "$B" --runner local --table "$T/r4.md")
[ "$RC" = 0 ] && ok || bad "R4: rc $RC, want 0: $(cat "$T/r4.out")"
grep -q '^TRANSIENT: tests/a-test.sh rc=75 (base)' "$T/r4.out" && ok || bad "R4: no base TRANSIENT line: $(cat "$T/r4.out")"
grep -q '| transient (base) |$' "$T/r4.md" && ok || bad "R4: table state: $(cat "$T/r4.md")"

# ── R5: a head timeout ──────────────────────────────────────────────────────
DR="$T/r5"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
# A head that hangs until the timeout ends it (exec: the timeout's TERM
# reaches the hung process itself).
suite "$DR" tests/a-test.sh 'grep -q v2 bin/a.sh && exec tail -f /dev/null; P=1'
B=$(snap "$DR" base); put "$DR" bin/a.sh 'echo v2'; snap "$DR" head >/dev/null
RC=$(runchk "$T/r5.out" --tree "$DR" --base "$B" --runner local --suite-timeout 1)
[ "$RC" = 0 ] && ok || bad "R5: rc $RC, want 0: $(cat "$T/r5.out")"
grep -q '^TRANSIENT: tests/a-test.sh rc=124' "$T/r5.out" && ok || bad "R5: no rc=124 TRANSIENT line: $(cat "$T/r5.out")"

# ── R6 / R10 / R11: cap, budget, cap 0 ──────────────────────────────────────
DR="$T/r6"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
suite "$DR" tests/a-test.sh 'cat bin/a.sh >/dev/null; P=1'
suite "$DR" tests/b-test.sh 'cat bin/a.sh >/dev/null; P=1'
B=$(snap "$DR" base); put "$DR" bin/a.sh 'echo v2'; snap "$DR" head >/dev/null
RC=$(runchk "$T/r6.out" --tree "$DR" --base "$B" --runner local --cap 1 --table "$T/r6.md")
[ "$RC" = 0 ] && ok || bad "R6: rc $RC, want 0: $(cat "$T/r6.out")"
grep -q '^NOT RUN: tests/b-test.sh (cap)$' "$T/r6.out" && ok || bad "R6: no NOT RUN cap line: $(cat "$T/r6.out")"
grep -q '^| tests/b-test.sh | .* | not run (cap) |$' "$T/r6.md" && ok || bad "R6: no NOT RUN row: $(cat "$T/r6.md")"
RC=$(runchk "$T/r10.out" --tree "$DR" --base "$B" --runner local --budget 0)
[ "$RC" = 0 ] && ok || bad "R10: rc $RC, want 0"
[ "$(grep -c '^NOT RUN: tests/[ab]-test.sh (budget)$' "$T/r10.out")" = 2 ] && ok || bad "R10: budget lines: $(cat "$T/r10.out")"
RC=$(runchk "$T/r11.out" --tree "$DR" --base "$B" --runner local --cap 0)
[ "$RC" = 0 ] && ok || bad "R11: rc $RC, want 0"
[ "$(tail -1 "$T/r11.out")" = "SUITE_REACH_VERDICT: clean (cap 0: not run)" ] && ok || bad "R11: last line '$(tail -1 "$T/r11.out")'"

# ── R7: a new suite red on head ─────────────────────────────────────────────
DR="$T/r7"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
B=$(snap "$DR" base)
suite "$DR" tests/new-test.sh 'cat bin/a.sh >/dev/null; F=1; echo "FAIL: new"'
snap "$DR" head >/dev/null
RC=$(runchk "$T/r7.out" --tree "$DR" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "R7: rc $RC, want 0: $(cat "$T/r7.out")"
grep -q '^\[NOTE\] tests/new-test.sh new at head and red' "$T/r7.out" && ok || bad "R7: no new-suite NOTE: $(cat "$T/r7.out")"

# ── R8: a bad base ──────────────────────────────────────────────────────────
RC=$(runchk "$T/r8.out" --tree "$DR" --base no-such-ref-fixture --runner local)
[ "$RC" = 2 ] && ok || bad "R8: rc $RC, want 2"
RC=$(runchk "$T/r8b.out" --tree "$DR" --runner local)
[ "$RC" = 2 ] && ok || bad "R8: no --base: rc $RC, want 2"

# ── R9: the PR amends the suite to the new expectation ──────────────────────
D9="$T/r9"; B=$(at1 "$D9")
sed -i 's/= 1 ]/= 0 ]/; s/default is 1/default is 0/' "$D9/tests/wake-loop-test.sh"
printf 'TEST-CHANGE: the default is 0 now\n' > "$D9/CHANGE.txt"
snap "$D9" amend >/dev/null
RC=$(runchk "$T/r9.out" --tree "$D9" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "R9: rc $RC, want 0: $(cat "$T/r9.out")"

# ── R12: a suite the head deletes ───────────────────────────────────────────
DR="$T/r12"; newrepo "$DR"
put "$DR" bin/a.sh 'echo v1'
suite "$DR" tests/a-test.sh 'cat bin/a.sh >/dev/null; P=1'
B=$(snap "$DR" base); git -C "$DR" rm -q tests/a-test.sh; snap "$DR" head >/dev/null
RC=$(runchk "$T/r12.out" --tree "$DR" --base "$B" --runner local)
[ "$RC" = 0 ] && ok || bad "R12: rc $RC, want 0: $(cat "$T/r12.out")"
grep -q '^\[NOTE\] tests/a-test.sh deleted at head' "$T/r12.out" && ok || bad "R12: no deleted NOTE: $(cat "$T/r12.out")"

# ── R13: the isolated runner cannot start → rc 125, never red or clean ──────
mkdir -p "$T/nosetpriv"
printf '#!/bin/sh\nexit 1\n' > "$T/nosetpriv/setpriv"; chmod +x "$T/nosetpriv/setpriv"
RC=$(PATH="$T/nosetpriv:$PATH" runchk "$T/r13.out" --tree "$T/at1" --base "$(git -C "$T/at1" rev-parse HEAD~1)" --runner isolated)
[ "$RC" = 125 ] && ok || bad "R13: rc $RC, want 125: $(cat "$T/r13.out" "$T/r13.out.err")"
grep -q '^SUITE_REACH_VERDICT' "$T/r13.out" && bad "R13: a verdict on a run that could not start" || ok

# ── G1-G7: the gate ─────────────────────────────────────────────────────────
# gate <case> <worktree> [VAR=value...] — run suite_reach_block in a subshell
# with stub pipeline functions. Prints the subshell's rc; leaves
# $T/<case>/{RESULT,esc,alerts,gates_note,build/}.
gate() {
  local c="$1" wt="$2"; shift 2
  local g="$T/$c"
  scratch_rm "$g"; mkdir -p "$g/build"
  (
    cd "$wt" || exit 99
    export HARNESS="$H" BUILD="$g/build" ALERTS="$g/alerts" PROJECT=cromford KEY=BH-7669
    export HARNESS_ROOT_OVERRIDE="$T/no-live-harness"
    SCOPE_BASE=$(git rev-parse HEAD~1); GATES_NOTE=""
    for kv in "$@"; do export "${kv?}"; done
    STAMP() { echo 2026-10-20T00:00:00Z; }
    RESULT() { printf '%s\n' "$1" > "$g/RESULT"; }
    escalate_block() { printf '%s|%s\n' "$1" "$2" >> "$g/esc"; }
    trap 'printf "%s" "$GATES_NOTE" > "$g/gates_note"' EXIT
    . "$GATE_LIB" || exit 98
    suite_reach_block execute
  )
  echo $?
}
at1 "$T/g-at1" check >/dev/null
RC=$(gate g1 "$T/g-at1")
[ "$RC" = 6 ] && ok || bad "G1: gate rc $RC, want 6: $(cat "$T/g1/build/suite-reach.txt" 2>/dev/null)"
case "$(cat "$T/g1/RESULT" 2>/dev/null)" in
  "REVIEW_BLOCKED suite-reach: 1 suite(s) green on base, red on head: tests/wake-loop-test.sh (FAIL: conductor-launch default is 1)"*) ok ;;
  *) bad "G1: RESULT '$(cat "$T/g1/RESULT" 2>/dev/null)'" ;;
esac
[ "$(grep -c '^suite-reach|' "$T/g1/esc" 2>/dev/null)" = 1 ] && ok || bad "G1: escalate_block calls: $(cat "$T/g1/esc" 2>/dev/null)"
grep -q 'SUITE_REACH rc=1 verdict=red red=1 ' "$T/g1/build/pipeline.log" 2>/dev/null && ok || bad "G1: pipeline.log: $(cat "$T/g1/build/pipeline.log" 2>/dev/null)"
# G2: both artifacts in the build dir.
grep -q '^| tests/wake-loop-test.sh |' "$T/g1/build/suite-reach.md" 2>/dev/null && ok || bad "G2: no table in the build dir"
grep -q '^SUITE_REACH_VERDICT: red' "$T/g1/build/suite-reach.txt" 2>/dev/null && ok || bad "G2: no suite-reach.txt in the build dir"

# G3: red on both → return 0, NOTE in GATES_NOTE, no RESULT.
at4 "$T/g-at4" check >/dev/null
RC=$(gate g3 "$T/g-at4")
[ "$RC" = 0 ] && ok || bad "G3: gate rc $RC, want 0"
grep -q '^SUITE-REACH GATE: clean' "$T/g3/gates_note" && grep -q '^\[NOTE\] tests/a-test.sh' "$T/g3/gates_note" && ok \
  || bad "G3: GATES_NOTE '$(cat "$T/g3/gates_note")'"
[ ! -e "$T/g3/RESULT" ] && ok || bad "G3: a RESULT on a clean verdict"

# G4: SUITE_REACH_BLOCK=0 → warn only.
RC=$(gate g4 "$T/g-at1" SUITE_REACH_BLOCK=0)
[ "$RC" = 0 ] && ok || bad "G4: gate rc $RC, want 0"
grep -q 'warn-only, SUITE_REACH_BLOCK=0' "$T/g4/gates_note" && grep -q '^RED: tests/wake-loop-test.sh' "$T/g4/gates_note" && ok \
  || bad "G4: GATES_NOTE '$(cat "$T/g4/gates_note")'"
[ ! -e "$T/g4/RESULT" ] && ok || bad "G4: a RESULT in warn-only mode"

# G5: a check that exits 1 with no verdict never blocks.
stubwt() { # stubwt <dir> <script body> — a worktree whose check is a stub
  newrepo "$1"; put "$1" README 'base'; snap "$1" base >/dev/null
  put "$1" bin/suite-reach-check.sh "#!/bin/bash
$2"; chmod +x "$1/bin/suite-reach-check.sh"; snap "$1" head >/dev/null
}
stubwt "$T/g5wt" 'echo "RED: tests/x.sh half a report"; exit 1'
RC=$(gate g5 "$T/g5wt")
[ "$RC" = 0 ] && ok || bad "G5: gate rc $RC, want 0"
grep -q 'could not run (rc=1)' "$T/g5/gates_note" && ok || bad "G5: GATES_NOTE '$(cat "$T/g5/gates_note")'"
[ "$(grep -c 'suite-reach' "$T/g5/alerts" 2>/dev/null)" = 1 ] && ok || bad "G5: ALERTS '$(cat "$T/g5/alerts" 2>/dev/null)'"
[ ! -e "$T/g5/RESULT" ] && ok || bad "G5: a RESULT on a crashed check"

# G6: a worktree with no check is skipped.
newrepo "$T/g6wt"; put "$T/g6wt" README 'a'; snap "$T/g6wt" a >/dev/null; put "$T/g6wt" README 'b'; snap "$T/g6wt" b >/dev/null
RC=$(gate g6 "$T/g6wt")
[ "$RC" = 0 ] && ok || bad "G6: gate rc $RC, want 0"
grep -q 'suite-reach: skipped (repo carries no bin/suite-reach-check.sh)' "$T/g6/build/pipeline.log" 2>/dev/null && ok || bad "G6: no skipped line"
[ ! -s "$T/g6/alerts" ] && ok || bad "G6: an alert from a repo with no check"

# G7: a check that exits 125.
stubwt "$T/g7wt" 'echo "suite-reach: snapshot failed" >&2; exit 125'
RC=$(gate g7 "$T/g7wt")
[ "$RC" = 0 ] && ok || bad "G7: gate rc $RC, want 0"
grep -q 'could not run (rc=125)' "$T/g7/gates_note" && ok || bad "G7: GATES_NOTE '$(cat "$T/g7/gates_note")'"

# ── W1: the execute.sh block, as shipped ───────────────────────────────────
awk '/^# >>> suite reach gate/{f=1} f{print} /^# <<< suite reach gate/{exit}' "$REPO/bin/lib/rb/execute.sh" > "$T/w1-block.sh"
grep -q 'suite_reach_block execute' "$T/w1-block.sh" && ok || bad "W1: no suite reach gate block in bin/lib/rb/execute.sh"
L_GATES=$(grep -n '^STAGE_END gates "\$T_GATES"$' "$REPO/bin/lib/rb/execute.sh" | cut -d: -f1)
L_SR=$(grep -n '^# >>> suite reach gate' "$REPO/bin/lib/rb/execute.sh" | cut -d: -f1)
[ -n "$L_GATES" ] && [ -n "$L_SR" ] && [ "$L_SR" -gt "$L_GATES" ] && ok || bad "W1: the block must follow STAGE_END gates (${L_GATES:-none} vs ${L_SR:-none})"
at1 "$T/w1wt" check >/dev/null
scratch_rm "$T/w1"; mkdir -p "$T/w1/build"
(
  cd "$T/w1wt" || exit 99
  HARNESS="$H" BUILD="$T/w1/build" ALERTS="$T/w1/alerts" PROJECT=cromford KEY=BH-7669
  export HARNESS_ROOT_OVERRIDE="$T/no-live-harness"
  SCOPE_BASE=$(git rev-parse HEAD~1); BASE=main; GATES_NOTE=""
  STAMP() { echo 2026-10-20T00:00:00Z; }
  RESULT() { printf '%s\n' "$1" > "$T/w1/RESULT"; }
  escalate_block() { :; }
  # shellcheck disable=SC1090
  . "$T/w1-block.sh"
  exit 0
)
RC=$?
[ "$RC" = 6 ] && ok || bad "W1: the execute.sh block exited $RC, want 6"
case "$(cat "$T/w1/RESULT" 2>/dev/null)" in "REVIEW_BLOCKED suite-reach: "*"tests/wake-loop-test.sh"*) ok ;; *) bad "W1: RESULT '$(cat "$T/w1/RESULT" 2>/dev/null)'" ;; esac

echo "suite-reach-check (BH-7669): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

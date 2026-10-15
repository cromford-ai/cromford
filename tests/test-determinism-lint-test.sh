#!/bin/bash
# tests/test-determinism-lint-test.sh — bin/test-determinism-lint.sh driven over
# fixture trees: leaks, pins, waivers, thresholds, and the regression it was
# written for.
#
#   THE PROPERTY UNDER TEST: the lint fails on a test that reads the wall clock
#   or rolls dice, stays quiet when the file pins its time or the line says WHY
#   it is safe, and refuses a waiver that gives no reason. Plus the shape that
#   caused it: fixtures frozen to a calendar date + a rolling window (#360).
#
# determinism: ok-file the fixtures below contain deliberate clock, random and
# git-pipe leaks as DATA; this suite itself uses only literal values, no
# wall-clock read, and no short-circuiting consumer on a pipe.
# Run from anywhere: tests/test-determinism-lint-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run <dir-or-file> [flags...] -> stdout in $OUT, rc in $RC. HARNESS points at a
# scratch tree so a box-local flags/determinism-lint.conf can never leak in.
run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }
# count <re> -> the findings that match. The "first finding:" line a failing run
# ends with (BH-6880) repeats one finding's rule, so it is not counted again.
count() { grep -v '^test-determinism-lint: first finding: ' <<<"$OUT" | grep -c "$1"; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/tests" "$T/c/pkg/test" "$T/c/bin"; }

# ── 1. what gets scanned ─────────────────────────────────────────────────────
case_dir
: > "$T/c/tests/a-test.sh"; : > "$T/c/pkg/test/b.test.js"; : > "$T/c/tests/c.test.js"
mkdir -p "$T/c/tests/fixtures" "$T/c/node_modules/x/tests"
: > "$T/c/tests/fixtures/seed-test.sh"; : > "$T/c/node_modules/x/tests/d-test.sh"
: > "$T/c/bin/some-script.sh"; : > "$T/c/README.md"
run "$T/c" --list
{ has 'tests/a-test\.sh' && has 'pkg/test/b\.test\.js' && has 'tests/c\.test\.js'; } && ok || bad "selection missed a test file: $OUT"
# BH-1248: bin/**.sh is now in the list, for the one rule that names it in a
# `scope` line. The rules it runs there are pinned by
# tests/test-determinism-lint.bh-1248-test.sh cases A and A'.
{ ! has 'fixtures/seed-test' && ! has 'node_modules' && ! has 'README'; } && ok \
  || bad "selection scanned something that is neither a test nor scoped: $OUT"
has 'bin/some-script\.sh' && ok || bad "a scope line must put its path in --list: $OUT"

# ── 2. a leak fails, with file:line ──────────────────────────────────────────
case_dir
cat > "$T/c/tests/leaky-test.sh" <<'EOF'
#!/bin/bash
KEY="build-$RANDOM"
echo "$KEY"
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'tests/leaky-test\.sh:2: rand-bash'; } && ok || bad "a \$RANDOM leak did not fail with file:line (rc=$RC): $OUT"

# ── 3. a waiver with a reason silences that line ─────────────────────────────
case_dir
cat > "$T/c/tests/leaky-test.sh" <<'EOF'
#!/bin/bash
KEY="build-$RANDOM"   # determinism: ok the key only has to be unique within the run
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'rand-bash'; } && ok || bad "a waived line still failed (rc=$RC): $OUT"

# ── 4. a waiver with no reason is itself a finding ───────────────────────────
case_dir
cat > "$T/c/tests/leaky-test.sh" <<'EOF'
#!/bin/bash
KEY="build-$RANDOM"   # determinism: ok
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'waiver-no-reason'; } && ok || bad "a reasonless waiver was accepted (rc=$RC): $OUT"

# ── 5. a file waiver can name the rules it covers, and only those ────────────
case_dir
cat > "$T/c/tests/leaky-test.sh" <<'EOF'
#!/bin/bash
# determinism: ok-file rand-bash the ids only have to be unique inside one run
KEY="build-$RANDOM"
sleep 4
EOF
run "$T/c"
{ [ "$RC" = 1 ] && ! has 'rand-bash' && has 'race-sleep'; } && ok \
  || bad "a rule-scoped file waiver covered the wrong rules (rc=$RC): $OUT"
# ... and it can name several
cat > "$T/c/tests/leaky-test.sh" <<'EOF'
#!/bin/bash
# determinism: ok-file rand-bash race-sleep ids are per-run and the sleep is the fixture
KEY="build-$RANDOM"
sleep 4
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'rand-bash' && ! has 'race-sleep'; } && ok || bad "a multi-rule file waiver failed (rc=$RC): $OUT"

# ── 6. a time pin exempts the clock rules, and ONLY the clock rules ──────────
case_dir
cat > "$T/c/tests/dated-test.sh" <<'EOF'
#!/bin/bash
D=$(date -u +%Y-%m-%d)
echo "$D"
EOF
run "$T/c"
has 'clock-date-cmd' && ok || bad "an unpinned calendar date read was not reported: $OUT"
[ "$RC" = 0 ] && ok || bad "a warn-severity rule must not fail the run (rc=$RC): $OUT"
cat > "$T/c/tests/dated-test.sh" <<'EOF'
#!/bin/bash
NOW=$(date -u +%s)
D=$(date -u -d "@$NOW" +%Y-%m-%d)
KEY="k-$RANDOM"
EOF
run "$T/c"
{ ! has 'clock-date-cmd' && has 'rand-bash'; } && ok \
  || bad "a NOW= pin must cover the clock rules and nothing else: $OUT"

# ── 7. JS: the wall clock, and the fake-timer pin ────────────────────────────
case_dir
cat > "$T/c/pkg/test/b.test.js" <<'EOF'
const now = Date.now();
const then = new Date();
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'clock-now-js' && has 'clock-new-date'; } && ok || bad "JS clock reads were not reported (rc=$RC): $OUT"
cat > "$T/c/pkg/test/b.test.js" <<'EOF'
vi.useFakeTimers({ now: new Date('2026-09-14T00:00:00Z') });
const now = Date.now();
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'clock-now-js'; } && ok || bad "useFakeTimers must pin the file (rc=$RC): $OUT"

# ── 8. THE #360 SHAPE: frozen fixtures + a rolling window ────────────────────
# Fixtures pinned to a calendar date, a route asked for the last 24h: green on
# the day it merges, red on a day nobody chose.
case_dir
cat > "$T/c/pkg/test/cost.test.js" <<'EOF'
const ROUTE_STATE = {
  rows: [{ day: '2026-09-14', usd: 12 }, { day: '2026-09-14', usd: 4 }],
};
test('the route answers', async () => {
  const r = await call('/api/metrics/cost-anchored?window=24h', { state: ROUTE_STATE });
  assert.equal(r.status, 200);
});
test('the day-pinned read still works', async () => {
  const r = await call('/api/metrics/cost-anchored?day=2026-09-14', { state: ROUTE_STATE });
  assert.equal(r.status, 200);
});
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'cost\.test\.js:5: clock-rolling-window'; } && ok \
  || bad "the rolling-window-over-frozen-fixtures shape was not caught (rc=$RC): $OUT"
# THE PIN IS PER LINE, NOT PER FILE: the broken file already carried a ?day= in
# another test, so a file-level pin would have read it as safe.
[ "$(count 'clock-rolling-window')" = 1 ] && ok || bad "the day-pinned call was reported too: $OUT"
# fix it the way #360 did
sed -i 's|cost-anchored?window=24h|cost-anchored?day=2026-09-14|' "$T/c/pkg/test/cost.test.js"
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'clock-rolling-window'; } && ok || bad "the #360 fix still fails the lint (rc=$RC): $OUT"
# fixtures built RELATIVE to now are the other correct answer, and are quiet
case_dir
cat > "$T/c/pkg/test/rel.test.js" <<'EOF'
// determinism: ok-file clock-now-js one anchor, every fixture an offset off it
const iso = (daysAgo) => new Date(Date.now() - daysAgo * 86400000).toISOString();
const state = { rows: [{ at: iso(1), usd: 12 }], seeded: '2026-09-14' };
const r = await call('/api/metrics/dora?days=14', { state });
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'clock-rolling-window'; } && ok || bad "relative fixtures must not trip the window rule (rc=$RC): $OUT"

# ── 9. sleeps: a wait is a race, a lock holder is not ────────────────────────
case_dir
cat > "$T/c/tests/sleepy-test.sh" <<'EOF'
#!/bin/bash
launch_in_background
sleep 3
assert_result
sleep 0.2
( flock 9; sleep 30 ) 9>"$T/l.lock" &
for i in $(seq 1 40); do [ -f "$T/done" ] && break; sleep 3; done
# sleep 9 in a comment is not a race
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'sleepy-test\.sh:3: race-sleep'; } && ok || bad "a foreground wait was not reported (rc=$RC): $OUT"
[ "$(count 'race-sleep')" = 1 ] && ok \
  || bad "sub-threshold sleeps, lock holders, retry loops or comments were reported: $OUT"

# ── 10. every threshold and pattern is config, not a constant ────────────────
sed 's/^opt race_sleep_min_s .*/opt race_sleep_min_s 5/' "$DIR/catalog/determinism-lint.conf" > "$T/conf-5.conf"
OUT=$(DETERMINISM_LINT_CONF="$T/conf-5.conf" HARNESS="$T/h" bash "$LINT" "$T/c" 2>&1); RC=$?
{ [ "$RC" = 0 ] && ! has 'race-sleep'; } && ok || bad "race_sleep_min_s is not honoured from the conf (rc=$RC): $OUT"
OUT=$(DETERMINISM_LINT_CONF="$T/conf-5.conf" HARNESS="$T/h" bash "$LINT" --rules 2>&1); RC=$?
{ [ "$RC" = 0 ] && has 'opt race_sleep_min_s 5'; } && ok || bad "--rules must print the resolved table: $OUT"

# ── 11. --warn-only reports and does not fail ────────────────────────────────
case_dir
printf '#!/bin/bash\nKEY=$RANDOM\n' > "$T/c/tests/leaky-test.sh"
run "$T/c" --warn-only
{ [ "$RC" = 0 ] && has 'rand-bash'; } && ok || bad "--warn-only must report and exit 0 (rc=$RC): $OUT"

# ── 12. no rule file: rc 2, never a vacuous green ────────────────────────────
mkdir -p "$T/lonely/bin"; cp "$LINT" "$T/lonely/bin/"
OUT=$(HARNESS="$T/h" bash "$T/lonely/bin/test-determinism-lint.sh" "$T/c" 2>&1); RC=$?
{ [ "$RC" = 2 ] && has 'no rule file found'; } && ok || bad "a missing conf must exit 2 (rc=$RC): $OUT"

# ── 13. THE BH-1232 SHAPE: a short-circuiting consumer on a git pipe ─────────
# tests/blocked-resolver-test.sh case 8e asserted its checkpoint commit with
# `git log --oneline <branch> | grep -q <subject>`. grep -q exits at the FIRST
# match, git goes on writing the rest of the history into a pipe nobody is
# reading, takes SIGPIPE, and `set -o pipefail` hands the && git's 141 — so the
# assertion went red while the commit it asserts was on the branch the whole
# time. 75 of 400 runs of that one line on the test host; it put main red at
# 4ffd1811 and sank the trains behind it. The three answers that are NOT a
# race are in the fixture too, and must stay quiet: capture the output first,
# ask git the question directly, or use a consumer that reads to EOF.
case_dir
cat > "$T/c/tests/piped-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
git -C "$T/origin.git" log --oneline ticket/x | grep -q 'the commit' && ok || bad "gone"
R=$(git -C "$T/r" show --name-only --format= ticket/x | head -1)
grep -q 'the commit' <<<"$(git -C "$T/origin.git" log --oneline ticket/x)" && ok || bad "gone"
git -C "$T/r" merge-base --is-ancestor "$SHA" ticket/x && ok || bad "gone"
[ "$(git -C "$T/r" log --oneline ticket/x | grep -c 'the commit')" = 1 ] && ok || bad "gone"
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'piped-test\.sh:3: race-sigpipe' && has 'piped-test\.sh:4: race-sigpipe'; } && ok \
  || bad "a short-circuiting consumer on a git pipe was not caught (rc=$RC): $OUT"
[ "$(count 'race-sigpipe')" = 2 ] && ok \
  || bad "capture-first, merge-base and a read-to-EOF consumer are not races and must be quiet: $OUT"

# ── 14. this repo's own tree is clean ────────────────────────────────────────
# The lint is only worth having if it passes on the tree it ships with; that
# check is also what catches a waiver deleted along with the line it explained.
# The whole-tree scan is not repeated here. The "Test determinism lint" job in
# .github/workflows/harness-ci.yml runs bin/test-determinism-lint.sh over this
# repo's tree on every PR, batch and push, and a finding fails it with rc 1.
# Re-running that scan here only doubled its cost in every batch.
# tests/dedicated-job-coverage-test.sh checks that the job keeps running it.

echo "test-determinism-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

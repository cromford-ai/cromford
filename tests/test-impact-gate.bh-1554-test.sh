#!/bin/bash
# tests/test-impact-gate.bh-1554-test.sh — BH-1554: the #1541 round-2 follow-ups
# on the builder's impact gate (bin/test-impact-gate.sh).
#
#   D1  the default budget is 450 s in the registry AND in the script's last
#       fallback, and the registry note records the measurement
#   D2  the registry max leaves headroom under the stage's `timeout 1500`
#   B1  N1: a suite the budget never STARTED is marked `(not started: budget)`
#       in the --table run table, a suite that ran is not, and the header's
#       "ran R of N" stays true
#   O1  ordering: within a rank tier, shortest recorded duration first — and a
#       weaker tier still follows a stronger one whatever the durations say
#   O2  a suite with no recorded duration sorts after every suite that has one,
#       alphabetically among the unknowns
#   O3  a local run RECORDS one duration row per suite it ran, none for a
#       suite the budget skipped, and a second run rewrites rather than appends
#   O4  a durations file that cannot be written is a warning on stderr, never a
#       nonzero rc
#
# Real git repos under $T, the real gate and the real selector, no mocks.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-gate-1554: git is required for this suite"; exit 2; }
command -v jq  >/dev/null || { echo "test-impact-gate-1554: jq is required for this suite"; exit 2; }
TAB=$(printf '\t')

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"

# ── the fixture: this repo's shape, in miniature ────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/docs"
for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f"
done
chmod +x "$R/bin/"*.sh
cat > "$R/bin/lib/widget.sh" <<'SH'
#!/bin/bash
widget_count_open() { echo 3; }
widget_close_all() { echo closed; }
SH
# aa-slow / zy-fast / zz-fast: three suites the diff CHANGES, so all three are
# the `self` tier and only the ordering inside that tier can separate them.
cat > "$R/tests/aa-slow-test.sh" <<'SH'
#!/bin/bash
sleep "${SLOW_SUITE:-0}"
echo "aa-slow: 1 passed, 0 failed"
SH
cat > "$R/tests/zy-fast-test.sh" <<'SH'
#!/bin/bash
echo "zy-fast: 1 passed, 0 failed"
SH
cat > "$R/tests/zz-fast-test.sh" <<'SH'
#!/bin/bash
echo "zz-fast: 1 passed, 0 failed"
SH
# reads-test: the weaker tier — it greps widget.sh's text, so it is `reads`.
cat > "$R/tests/reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh" || exit 1
echo "reads: 1 passed, 0 failed"
SH
echo note > "$R/docs/n.md"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"
for s in aa-slow zy-fast zz-fast; do echo '# touched' >> "$R/tests/$s-test.sh"; done
gitc commit -qam "touch widget and three suites"

DUR="$T/durations.tsv"
# No live harness answers for any gate run here: its lane-gate.sh would refresh
# that box's settings cache, and a box setting would move the budget under test.
export HARNESS="$T/empty"
gate() { ( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$DUR" bin/test-impact-gate.sh --base "$BASE" "$@" ); }

# ── D1. the default budget is 450 s ────────────────────────────────────────
J="$DIR/catalog/lanes.d/fly-pool.json"
DEF=$(jq -r '.knobs[]|select(.env=="TEST_IMPACT_GATE_BUDGET_S")|.default' "$J")
[ "$DEF" = 450 ] && ok || bad "D1: the registry default budget must be 450 s (got $DEF)"
jq -r '.knobs[]|select(.env=="TEST_IMPACT_GATE_BUDGET_S")|.note' "$J" | grep -q 450 \
  && ok || bad "D1: the registry note must record the 450 s measurement"
# The script's own last fallback, with no resolver and no env: HARNESS points at
# an empty dir so no lane-gate.sh and no settings cache can answer.
OUT=$( cd "$R" && HARNESS="$T/empty" TEST_IMPACT_GATE_BUDGET_S= \
       bin/test-impact-gate.sh --base "$BASE" --runner plan 2>&1 )
grep -q 'budget 450s' <<<"$OUT" \
  && ok || bad "D1: with no row and no env the gate's own default must be 450s (got: $(grep 'running up to' <<<"$OUT"))"

# ── D2. the registry max keeps headroom under `timeout 1500` ───────────────
MAX=$(jq -r '.knobs[]|select(.env=="TEST_IMPACT_GATE_BUDGET_S")|.max' "$J")
[ "$MAX" -le 1250 ] && [ "$((MAX + 190))" -le 1500 ] \
  && ok || bad "D2: the registry max must be <= 1250 so the slowest suite still finishes inside timeout 1500 (got $MAX)"

# ── B1. N1: what the budget never started is marked, not shown as run ──────
# aa-slow sleeps 3 s against a 2 s budget and is ranked first (no durations
# recorded yet, so the tier is alphabetical): the two fast self suites are never
# started, and reads-test is a weaker tier behind them.
: > "$DUR"
export SLOW_SUITE=3
gate --runner local --budget 2 --table "$T/b1.md" > "$T/b1.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "B1: running out of budget is not a failure of what ran (rc $RC: $(tail -3 "$T/b1.out" | tr '\n' '|'))"
grep -q 'impact-gate: ran 1 of 4' "$T/b1.out" \
  && ok || bad "B1: the header must still say how many RAN (got: $(grep 'impact-gate: ran' "$T/b1.out"))"
grep -qF '| `tests/zz-fast-test.sh` | (not started: budget)' "$T/b1.md" \
  && grep -qF '| `tests/zy-fast-test.sh` | (not started: budget)' "$T/b1.md" \
  && ok || bad "B1: a suite the budget never started must be marked in the run table (got: $(grep fast "$T/b1.md" | tr '\n' '|'))"
grep -q 'not started' <<<"$(grep -F '| `tests/aa-slow-test.sh` |' "$T/b1.md")" \
  && bad "B1: the suite that RAN must not be marked as not started" || ok
TAGS=$(grep -c 'not started: budget' "$T/b1.md")
BCOUNT=$(grep -o '[0-9]* by the budget' "$T/b1.md" | head -1 | cut -d' ' -f1)
[ -n "$BCOUNT" ] && [ "$TAGS" = "$BCOUNT" ] \
  && ok || bad "B1: the tag count ($TAGS) must equal the budget count on the summary line (${BCOUNT:-none})"
grep -qF -- '- `tests/zz-fast-test.sh`' "$T/b1.md" \
  && ok || bad "B1: the unstarted suites must still be listed as left to CI"

# ── O1/O2. ordering: shortest first inside a tier, unknowns last ───────────
plan_order() { gate --runner plan 2>/dev/null | sed -n 's/^plan: *\([^ ]*\).*/\1/p'; }
printf 'tests/zz-fast-test.sh\t1\ntests/aa-slow-test.sh\t30\ntests/reads-test.sh\t0\n' > "$DUR"
ORDER=$(plan_order)
[ "$(head -1 <<<"$ORDER")" = tests/zz-fast-test.sh ] \
  && ok || bad "O1: the shortest recorded suite in the tier must be planned first (got: $(printf '%s' "$ORDER" | tr '\n' ' '))"
SELF_LAST=$(printf '%s\n' "$ORDER" | grep -n 'aa-slow\|zy-fast\|zz-fast' | tail -1 | cut -d: -f1)
READS_AT=$(printf '%s\n' "$ORDER" | grep -n 'reads-test' | cut -d: -f1)
[ -n "$READS_AT" ] && [ "$READS_AT" -gt "$SELF_LAST" ] \
  && ok || bad "O1: a reads suite must still follow every self suite whatever its duration (got: $(printf '%s' "$ORDER" | tr '\n' ' '))"
# zy-fast has NO recorded duration: it sorts after both knowns in its tier.
[ "$(printf '%s\n' "$ORDER" | sed -n '3p')" = tests/zy-fast-test.sh ] \
  && ok || bad "O2: a suite with no recorded duration sorts after the knowns in its tier (got: $(printf '%s' "$ORDER" | tr '\n' ' '))"
# two unknowns: alphabetical between themselves, still after the known one.
printf 'tests/zz-fast-test.sh\t1\n' > "$DUR"
ORDER=$(plan_order)
[ "$(printf '%s\n' "$ORDER" | sed -n '1p;2p;3p' | tr '\n' ' ')" = "tests/zz-fast-test.sh tests/aa-slow-test.sh tests/zy-fast-test.sh " ] \
  && ok || bad "O2: unknown durations sort after the knowns, alphabetically among themselves (got: $(printf '%s' "$ORDER" | tr '\n' ' '))"

# ── O3. a local run records the durations it measured ──────────────────────
: > "$DUR"
gate --runner local --budget 2 --table "$T/o3.md" > "$T/o3.out" 2>&1
[ "$(grep -c . "$DUR")" = 1 ] \
  && ok || bad "O3: exactly the suites that RAN get a duration row (got: $(tr '\n' '|' < "$DUR"))"
grep -qE "^tests/aa-slow-test\.sh${TAB}[0-9]+$" "$DUR" \
  && ok || bad "O3: the row is <suite>TAB<whole seconds> (got: $(tr '\n' '|' < "$DUR"))"
grep -q 'zz-fast' "$DUR" && bad "O3: a suite the budget never started has no duration to record" || ok
unset SLOW_SUITE
gate --runner local > "$T/o3b.out" 2>&1
[ "$(grep -c . "$DUR")" = 4 ] && [ "$(cut -f1 "$DUR" | sort -u | grep -c .)" = 4 ] \
  && ok || bad "O3: a second run REWRITES one row per suite, it does not append (got: $(tr '\n' '|' < "$DUR"))"

# ── O4. a durations file that cannot be written is a warning, not a failure ─
# The parent is a FILE, so neither the mkdir nor the write can succeed — even
# as root, which is who a pool builder is.
: > "$T/not-a-dir"
( cd "$R" && TEST_IMPACT_DURATIONS_FILE="$T/not-a-dir/durations.tsv" \
    bin/test-impact-gate.sh --base "$BASE" --runner local ) > "$T/o4.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "O4: an unwritable durations file must not change the gate's rc (got $RC: $(tail -3 "$T/o4.out" | tr '\n' '|'))"
grep -q 'could not record durations' "$T/o4.out" \
  && ok || bad "O4: it must SAY it could not record (got: $(tail -3 "$T/o4.out" | tr '\n' '|'))"

echo "test-impact-gate-1554: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

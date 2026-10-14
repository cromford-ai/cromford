#!/bin/bash
# tests/test-trace-safety-shapes.bh-5541-test.sh — every shape the retired
# tests/trap-target-safety-test.sh caught is caught by bin/test-trace-safety.sh
# (the shard tracer) alone, red on the bad shape and green on the good one.
#
# The old guard re-ran about 190 suites under `bash -x` and read each `+ rm -rf`
# line on their stderr. The shard tracer already traces every suite, so the
# guard was a second copy of the same check (842 s a batch). Before it could go,
# each shape it read had to be a tracer test:
#   S1  the 2026-09-15 incident: `trap 'rm -rf "$H"' EXIT`, then a sourced bin
#       lib sets H="${HARNESS:-<bad>}"
#   S2  `rm -r` without -f
#   S3  rm inside `$( … )` and inside `( … )`
#   S4  rm inside a `bash -c` child
#   S5  a sourced lib's EXIT trap function removes a var the suite reassigns
#   S6  the suite sets PS4="+ ", then rm (trace lines lose the stamp)
#   S7  a subshell runs `export PS4="+ "`, then rm
#   S8  a `bash -x <script>` child whose stderr reaches the suite's stderr
# S6-S8 were misses on main before BH-5541. The bounds of the new reading:
#   - a relative target on an unstamped line has no known cwd and is skipped,
#   - `echo 'PS4=…'` is not a reassign, so loose reading stays off.
#
# Every fixture is a heredoc under $T, never a file in the repo. Every bad
# target is /dev/null/no-such-harness-bh5541/<id>: /dev/null is not a
# directory, so the rm is inert even if something runs the fixture directly.
# Never /dev/null itself: `rm -rf /dev/null` as root removes the device.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The runner mirrors scratch.sh's live-harness guard (tests/tests-trace-safety-test.sh).
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

BADT="/dev/null/no-such-harness-bh5541"

# ── the bad tree: one fixture per shape ─────────────────────────────────────
B="$T/bad"; mkdir -p "$B/tests" "$B/bin"
cat > "$B/bin/clobber.sh" <<'FIXEOF'
H="${HARNESS:-/dev/null/no-such-harness-bh5541/s1}"
FIXEOF
cat > "$B/tests/s1-test.sh" <<'FIXEOF'
#!/bin/bash
trap 'rm -rf "$H" 2>/dev/null; true' EXIT
H=$(mktemp -d)
rmdir "$H"
. "$PWD/bin/clobber.sh"
exit 0
FIXEOF
cat > "$B/tests/s2-test.sh" <<'FIXEOF'
#!/bin/bash
rm -r /dev/null/no-such-harness-bh5541/s2 2>/dev/null
exit 0
FIXEOF
cat > "$B/tests/s3-test.sh" <<'FIXEOF'
#!/bin/bash
X=$(rm -rf /dev/null/no-such-harness-bh5541/s3 2>&1)
( rm -rf /dev/null/no-such-harness-bh5541/s3sub 2>/dev/null )
exit 0
FIXEOF
cat > "$B/tests/s4-test.sh" <<'FIXEOF'
#!/bin/bash
bash -c 'rm -rf /dev/null/no-such-harness-bh5541/s4' 2>/dev/null
exit 0
FIXEOF
cat > "$B/bin/td.sh" <<'FIXEOF'
td_cleanup() { rm -rf "$SCR" 2>/dev/null; true; }
SCR=$(mktemp -d)
trap td_cleanup EXIT
FIXEOF
cat > "$B/tests/s5-test.sh" <<'FIXEOF'
#!/bin/bash
. "$PWD/bin/td.sh"
rmdir "$SCR"
SCR=/dev/null/no-such-harness-bh5541/s5
exit 0
FIXEOF
cat > "$B/tests/s6-test.sh" <<'FIXEOF'
#!/bin/bash
PS4="+ "
rm -rf /dev/null/no-such-harness-bh5541/s6 2>/dev/null
exit 0
FIXEOF
cat > "$B/tests/s7-test.sh" <<'FIXEOF'
#!/bin/bash
( export PS4="+ "; rm -rf /dev/null/no-such-harness-bh5541/s7 2>/dev/null )
exit 0
FIXEOF
cat > "$B/bin/s8child.sh" <<'FIXEOF'
rm -rf /dev/null/no-such-harness-bh5541/s8 2>/dev/null
true
FIXEOF
cat > "$B/tests/s8-test.sh" <<'FIXEOF'
#!/bin/bash
bash -x "$PWD/bin/s8child.sh"
exit 0
FIXEOF
# The control twin of the "quoted PS4" case below: a real reassign, then one raw
# unstamped deletion line written straight to the trace fd.
cat > "$B/tests/qc-test.sh" <<'FIXEOF'
#!/bin/bash
PS4="+ "
printf '%s\n' '+ rm -rf /dev/null/no-such-harness-bh5541/qc' >&199
exit 0
FIXEOF

OUT=$("$RUN" "$B" 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then ok; else bad "bad tree: rc must be 1, got $RC"; fi
for id in s1 s2 s3 s3sub s4 s5 s6 s7 s8; do
  sid=${id%sub}
  if grep -qE "^HIT ${sid}-test\.sh rm ${BADT}/${id}( |$)" <<<"$OUT"; then ok
  else bad "${id}: the tracer must print 'HIT ${sid}-test.sh rm ${BADT}/${id}'"; fi
done
if grep -qE "^HIT qc-test\.sh rm ${BADT}/qc( |$)" <<<"$OUT"; then ok
else bad "quoted-PS4 control: a raw deletion line after a real PS4 reassign must be a HIT"; fi

# ── the good tree: the same shapes, each removing its own mktemp -d dir ──────
G="$T/good"; mkdir -p "$G/tests" "$G/bin"
cat > "$G/bin/noclobber.sh" <<'FIXEOF'
H="${H:-/dev/null/no-such-harness-bh5541/s1}"
FIXEOF
cat > "$G/tests/s1-test.sh" <<'FIXEOF'
#!/bin/bash
trap 'rm -rf "$H"' EXIT
H=$(mktemp -d)
. "$PWD/bin/noclobber.sh"
exit 0
FIXEOF
cat > "$G/tests/s2-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
rm -r "$D"
exit 0
FIXEOF
cat > "$G/tests/s3-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d); E=$(mktemp -d)
X=$(rm -rf "$D" 2>&1)
( rm -rf "$E" )
exit 0
FIXEOF
cat > "$G/tests/s4-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
bash -c "rm -rf '$D'"
exit 0
FIXEOF
cat > "$G/bin/td.sh" <<'FIXEOF'
td_cleanup() { rm -rf "$SCR"; }
SCR=$(mktemp -d)
trap td_cleanup EXIT
FIXEOF
cat > "$G/tests/s5-test.sh" <<'FIXEOF'
#!/bin/bash
. "$PWD/bin/td.sh"
mkdir -p "$SCR/sub"
exit 0
FIXEOF
cat > "$G/tests/s6-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
PS4="+ "
rm -rf "$D"
exit 0
FIXEOF
cat > "$G/tests/s7-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
( export PS4="+ "; rm -rf "$D" )
exit 0
FIXEOF
cat > "$G/bin/s8child.sh" <<'FIXEOF'
rm -rf "$1"
FIXEOF
cat > "$G/tests/s8-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
bash -x "$PWD/bin/s8child.sh" "$D"
exit 0
FIXEOF
# S6 relative: after a PS4 reassign the line has no cwd stamp, so a relative
# target cannot be resolved. It is skipped, never guessed against the runner's
# own cwd (the runner below is started from /, where a guess would be a HIT).
cat > "$G/tests/s6rel-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
PS4="+ "
cd "$D" || exit 1
mkdir x
rm -rf ./x
cd / || exit 1
rmdir "$D"
exit 0
FIXEOF
# quoted PS4: printing the text `PS4=…` is not a reassign, so the raw line that
# follows stays unread (its twin in the bad tree is a HIT).
cat > "$G/tests/q-test.sh" <<'FIXEOF'
#!/bin/bash
echo 'PS4=+ quoted' >/dev/null
printf '%s\n' '+ rm -rf /dev/null/no-such-harness-bh5541/q' >&199
exit 0
FIXEOF

OUT=$(cd / && "$RUN" "$G" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "TRACE: 10 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
else bad "good tree: rc must be 0 with 10 tests, 0 nonzero exits and 0 hits (rc=$RC)"; fi
if grep -q '^HIT ' <<<"$OUT"; then
  bad "good tree: no HIT line allowed, got: $(printf '%s\n' "$OUT" | grep '^HIT ' | cut -d' ' -f1-4 | tr '\n' ';')"
else ok; fi

# ── the incident through the batch path, with no trap-target suite present ───
I="$T/inc"; mkdir -p "$I/tests" "$I/bin"
cp "$B/bin/clobber.sh" "$I/bin/"
cp "$B/tests/s1-test.sh" "$I/tests/"
"$RUN" --gate --shard 0/1 --verdict "$T/v.txt" "$I" > "$T/inc.out" 2>&1; RC=$?
if [ "$RC" -eq 1 ]; then ok; else bad "incident: --gate --shard 0/1 must exit 1, got $RC"; fi
if [ -f "$T/v.txt" ] && grep -qx 'hits=1' "$T/v.txt" && grep -qx 'trace=dirty' "$T/v.txt" && grep -qx 'pure=pass' "$T/v.txt"; then ok
else bad "incident: the verdict must say hits=1, trace=dirty, pure=pass [$(tr '\n' ' ' < "$T/v.txt" 2>/dev/null)]"; fi

# ── R. the old guard is retired ─────────────────────────────────────────────
for f in tests/trap-target-safety-test.sh tests/trap-target-safety.bh-5191-test.sh; do
  if [ -e "$DIR/$f" ]; then bad "R1: $f must be deleted"; else ok; fi
done
if awk -F'\t' '$1 == "tests/trap-target-safety-test.sh" { f = 1 } END { exit !f }' "$DIR/catalog/test-tiers.tsv"; then
  bad "R2: catalog/test-tiers.tsv still has a tests/trap-target-safety-test.sh row"
else ok; fi
"$RUN" --list "$DIR" > "$T/list.out" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && ! grep -q 'trap-target-safety' "$T/list.out"; then ok
else bad "R3: the shard list must not name trap-target-safety (rc=$RC)"; fi
bash "$DIR/bin/test-impact.sh" --root "$DIR" always > "$T/always.out" 2>&1; RC=$?
if [ "$RC" -eq 0 ] && ! grep -q 'trap-target-safety' "$T/always.out"; then ok
else bad "R3: the always-run set must not name trap-target-safety (rc=$RC)"; fi

echo "test-trace-safety-shapes: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

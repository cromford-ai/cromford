#!/bin/bash
# tests/test-trace-find-leading-opts.bh-8403-test.sh — bin/test-trace-safety.sh
# reads the path operands of `find` after find's leading options.
#
# find's synopsis is `find [-H] [-L] [-P] [-D debugopts] [-Olevel] [path…]
# [expression]`. Before BH-8403 the scan() find branch stopped at the first
# word that starts with `-`, so `find -P "$D/x" -name y -delete` had no path
# operand and fell back to `.`. The reader resolved `.` against the traced cwd
# (the checkout in CI) and printed a false HIT.
#
#   good    a leading option, then a path inside a temp root: 0 HITs
#   bad     a leading option, then a path outside: 1 HIT naming that path
#   dflt    no path operand at all: `.` against the cwd, as before
#
# Every fixture runs `cd /` (or `cd /dev`) first, so the cwd is outside every
# temp root (the CI shape). Every bad target is
# /dev/null/no-such-harness-bh8403/<id>: /dev/null is not a directory, so the
# find is inert even if something runs the fixture directly.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="${BH8403_RUN:-$DIR/bin/test-trace-safety.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
hits_for() { # <id> <output> — the count of HIT lines for <id>-test.sh
  printf '%s\n' "$2" | grep -c "^HIT $1-test\.sh " || true
}

# The runner mirrors scratch.sh's live-harness guard (tests/tests-trace-safety-test.sh).
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

BADT="/dev/null/no-such-harness-bh8403"

good_fixture() { # <dir> <id> <find options…>
  local d=$1 id=$2; shift 2
  cat > "$d/tests/$id-test.sh" <<FIXEOF
#!/bin/bash
D=\$(mktemp -d); mkdir "\$D/x"
cd /
find $* "\$D/x" -name y -delete 2>/dev/null
rm -rf "\$D"
exit 0
FIXEOF
}

bad_fixture() { # <dir> <id> <find options…>
  local d=$1 id=$2; shift 2
  cat > "$d/tests/$id-test.sh" <<FIXEOF
#!/bin/bash
cd /
find $* $BADT/$id -name y -delete 2>/dev/null
exit 0
FIXEOF
}

# ── 1. the good tree: a leading option, then a path inside a temp root ──────
G="$T/good"; mkdir -p "$G/tests"
good_fixture "$G" p    -P
good_fixture "$G" h    -H
good_fixture "$G" l    -L
good_fixture "$G" o3   -O3
good_fixture "$G" dtree  -D tree
good_fixture "$G" dtreeat -Dtree
good_fixture "$G" pl   -P -L
cat > "$G/tests/inside-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
cd "$D" && find -P -maxdepth 0 -name nothing-bh8403 -delete
cd /
rm -rf "$D"
exit 0
FIXEOF

OUT=$(cd / && "$RUN" "$G" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && has "TRACE: 8 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT"; then ok
else bad "good tree: rc must be 0 with 8 tests, 0 nonzero exits and 0 hits (rc=$RC)"; fi
for id in p h l o3 dtree dtreeat pl inside; do
  n=$(hits_for "$id" "$OUT")
  if [ "$n" -eq 0 ]; then ok
  else bad "good $id: no HIT allowed, got: $(printf '%s\n' "$OUT" | grep "^HIT $id-test\.sh " | cut -d' ' -f1-4 | tr '\n' ';')"; fi
done

# ── 2. the bad tree: a leading option, then a path outside every temp root ─
B="$T/bad"; mkdir -p "$B/tests"
bad_fixture "$B" p     -P
bad_fixture "$B" h     -H
bad_fixture "$B" l     -L
bad_fixture "$B" o3    -O3
bad_fixture "$B" dtree -D tree

OUT=$(cd / && "$RUN" "$B" 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then ok; else bad "bad tree: rc must be 1, got $RC"; fi
for id in p h l o3 dtree; do
  n=$(hits_for "$id" "$OUT")
  if [ "$n" -eq 1 ] && grep -qE "^HIT $id-test\.sh find-delete $BADT/$id( |$)" <<<"$OUT"; then ok
  else bad "bad $id: want exactly 1 'HIT $id-test.sh find-delete $BADT/$id', got $n: $(printf '%s\n' "$OUT" | grep "^HIT $id-test\.sh " | cut -d' ' -f1-4 | tr '\n' ';')"; fi
done
if grep -qE "^HIT [a-z0-9]+-test\.sh find-delete /( |$)" <<<"$OUT"; then
  bad "bad tree: no fixture may resolve to '/' (a leading option read as no path)"
else ok; fi

# ── 3. no path operand: `.` against the cwd, as before ─────────────────────
F="$T/dflt"; mkdir -p "$F/tests"
cat > "$F/tests/bare-test.sh" <<'FIXEOF'
#!/bin/bash
cd /dev && find -maxdepth 0 -name nothing-bh8403 -delete
exit 0
FIXEOF
cat > "$F/tests/opt-test.sh" <<'FIXEOF'
#!/bin/bash
cd /dev && find -L -maxdepth 0 -name nothing-bh8403 -delete
exit 0
FIXEOF
# Near miss: -name is an expression, not a leading option.
cat > "$F/tests/expr-test.sh" <<'FIXEOF'
#!/bin/bash
cd /dev && find -name nothing-bh8403-never -delete 2>/dev/null
exit 0
FIXEOF
# Near miss: a leading option with no -delete is not a deletion.
cat > "$F/tests/nodel-test.sh" <<'FIXEOF'
#!/bin/bash
cd /dev && find -P /dev/null/no-such-harness-bh8403/nodel -name y 2>/dev/null
exit 0
FIXEOF

OUT=$(cd / && "$RUN" "$F" 2>&1); RC=$?
if [ "$RC" -eq 1 ]; then ok; else bad "default tree: rc must be 1, got $RC"; fi
for id in bare opt expr; do
  n=$(hits_for "$id" "$OUT")
  if [ "$n" -eq 1 ] && grep -qE "^HIT $id-test\.sh find-delete /dev( |$)" <<<"$OUT"; then ok
  else bad "default $id: want exactly 1 'HIT $id-test.sh find-delete /dev', got $n"; fi
done
n=$(hits_for nodel "$OUT")
if [ "$n" -eq 0 ]; then ok; else bad "default nodel: a find with no -delete must give no HIT, got $n"; fi

echo "test-trace-find-leading-opts.bh-8403: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

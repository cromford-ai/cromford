#!/bin/bash
# tests/ci-share-mirror-warm.bh-9465-test.sh — bin/ci-share-mirror-warm.sh
# builds the public mirror once per CI shard, untraced, before the traced run,
# and only when the shard holds a suite that sources the share-mirror lib
# (BH-9465).
#
# Each share-mirror suite paid one full mirror build under the tracer, about 2x
# the untraced cost, and a shard of them passed the job's 45-minute cap. The
# warm step fills the same cache the suites read (tests/lib/share-mirror.sh),
# so the traced suites log `reused`. It is fail-open: rc 0 always, and a
# failure is one ::warning:: line, after which each suite builds for itself.
#
#   W1  a list with no consumer builds nothing (no cache entry); a suite that
#       names the lib only in a comment is not a consumer
#   W2  a list with one consumer among others builds one entry under the
#       default cache root, and a following consumer run logs `reused`
#   W3  a sanitize that exits 1 still gives rc 0, one ::warning::, no entry
#   W4  an unreadable list file (and no argument) gives rc 0 and one ::warning::
#
# A small committed scratch repo with a stub bin/share/sanitize.py, the shape
# of tests/share-mirror-cache.bh-5543-test.sh. No network, no real mirror.
#
# Sources under test: "$DIR/bin/ci-share-mirror-warm.sh" "$DIR/tests/lib/share-mirror.sh"
#
# Run from anywhere: tests/ci-share-mirror-warm.bh-9465-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export PYTHONDONTWRITEBYTECODE=1 HARNESS_TEST_SANDBOX=1
unset SHARE_MIRROR_CACHE SHARE_MIRROR_CACHE_KEEP SHARE_MIRROR_LOCK_WAIT_S
GIT=(git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)

WARM=bin/ci-share-mirror-warm.sh
[ -f "$DIR/$WARM" ] || { echo "FAIL: $WARM is missing"; echo "ci-share-mirror-warm.bh-9465: 0 pass, 1 fail"; exit 1; }

# ── the scratch repo ────────────────────────────────────────────────────────
R="$T/r"
mkdir -p "$R/bin/share" "$R/tests/lib"
# The warm script sources no bin/lib file, only the two tests/lib files it
# drives, which scratch_install_closure does not resolve from bin/; so the
# script and those two files are copied as they are.
cp "$DIR/$WARM" "$R/bin/" || bad "fixture: cannot copy $WARM"
cp "$DIR/tests/lib/scratch.sh" "$DIR/tests/lib/share-mirror.sh" "$R/tests/lib/"
# The stub sanitize copies the source tree and exits with bin/share/rc.
cat > "$R/bin/share/sanitize.py" <<'PY'
import os, shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2])
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rc")) as fh:
    sys.exit(int(fh.read().strip()))
PY
echo 0 > "$R/bin/share/rc"
# The consumer's source line is built with printf, so this file holds no line
# that sources the lib and the warm matcher never picks this suite itself.
SRC_LINE='. "$(dirname "$0")/lib/share-mirror.sh" || exit 1'
{
  printf '#!/bin/bash\n'
  printf '. "$(dirname "$0")/lib/scratch.sh" || exit 1\n'
  printf '%s\n' "$SRC_LINE"
  printf 'share_mirror_get "$(cd "$(dirname "$0")/.." && pwd)"\n'
  printf 'echo "how=$SM_HOW"\n'
} > "$R/tests/consumer.sh"
printf '#!/bin/bash\necho plain\n' > "$R/tests/plain.sh"
printf '#!/bin/bash\n# reads the mirror the way lib/share-mirror.sh builds it, but never sources it\necho comment\n' \
  > "$R/tests/comment-only.sh"
printf 'tests that use lib/share-mirror.sh\n' > "$R/tests/README.md"
echo 'a file the mirror ships' > "$R/keep.md"
( cd "$R" && "${GIT[@]}" init -q -b main && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m base ) \
  || { echo "FAIL: fixture: cannot commit the scratch repo"; exit 1; }

entries() { find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp.*' 2>/dev/null | wc -l; }
nwarn() { grep -c '::warning::' <<< "$1"; }

# warm <list> [env...] — run the warm script from the scratch repo; OUT, RC.
warm() {
  local list="$1"; shift
  OUT=$(cd "$R" && env "$@" bash "$R/$WARM" ${list:+"$list"} 2>&1); RC=$?
}

# ── W1 no consumer, no build ────────────────────────────────────────────────
printf 'tests/plain.sh\ntests/comment-only.sh\ntests/README.md\ntests/mc/x.sh\n' > "$T/w1.txt"
C1="$T/c1"
warm "$T/w1.txt" SHARE_MIRROR_CACHE="$C1"
[ "$RC" = 0 ] && grep -qx 'share-mirror-warm: no share-mirror suite in this shard' <<< "$OUT" && ok \
  || bad "W1 a list with no consumer must say so and exit 0 (rc=$RC: $OUT)"
[ "$(entries "$C1")" = 0 ] && ok || bad "W1 no consumer must build nothing (entries: $(entries "$C1"))"
[ "$(nwarn "$OUT")" = 0 ] && ok || bad "W1 no consumer is not a warning (got: $OUT)"
: > "$T/w1-empty.txt"
warm "$T/w1-empty.txt" SHARE_MIRROR_CACHE="$C1"
[ "$RC" = 0 ] && grep -qx 'share-mirror-warm: no share-mirror suite in this shard' <<< "$OUT" \
  && [ "$(entries "$C1")" = 0 ] && ok || bad "W1 an empty list builds nothing (rc=$RC: $OUT)"

# ── W2 one consumer among others: one build, then reused ────────────────────
printf 'tests/plain.sh\ntests/consumer.sh\ntests/comment-only.sh\n' > "$T/w2.txt"
TD="$T/tmp-w2"; mkdir -p "$TD"
C2="$TD/bh-share-mirror"
warm "$T/w2.txt" TMPDIR="$TD"
[ "$RC" = 0 ] && grep -qE '^share-mirror-warm: built [0-9a-f]{12} ' <<< "$OUT" && ok \
  || bad "W2 a consumer in the list must build the mirror (rc=$RC: $OUT)"
[ "$(entries "$C2")" = 1 ] && compgen -G "$C2/*/DONE" >/dev/null && ok \
  || bad "W2 the build must leave one complete entry under the default cache root (entries: $(ls "$C2" 2>/dev/null))"
[ "$(nwarn "$OUT")" = 0 ] && ok || bad "W2 a good build is not a warning (got: $OUT)"
K2=$(sed -nE 's/^share-mirror-warm: built ([0-9a-f]{12}) .*/\1/p' <<< "$OUT")
COUT=$(cd "$R" && TMPDIR="$TD" bash "$R/tests/consumer.sh" 2>&1)
[ -n "$K2" ] && grep -q "share-mirror: reused $K2 for consumer.sh" <<< "$COUT" && grep -qx 'how=reused' <<< "$COUT" && ok \
  || bad "W2 the consumer after the warm must reuse $K2 (got: $COUT)"
warm "$T/w2.txt" TMPDIR="$TD"
[ "$RC" = 0 ] && grep -qE "^share-mirror-warm: reused $K2 " <<< "$OUT" && [ "$(entries "$C2")" = 1 ] && ok \
  || bad "W2 a second warm on the same tree reuses the entry (rc=$RC: $OUT)"

# ── W3 a failing sanitize: rc 0, one warning, nothing stored ────────────────
echo 1 > "$R/bin/share/rc"
C3="$T/c3"
warm "$T/w2.txt" SHARE_MIRROR_CACHE="$C3"
[ "$RC" = 0 ] && [ "$(nwarn "$OUT")" = 1 ] && grep -q '::warning::share-mirror-warm: ' <<< "$OUT" && ok \
  || bad "W3 a failed sanitize must be rc 0 with one ::warning:: (rc=$RC: $OUT)"
[ "$(entries "$C3")" = 0 ] && ok || bad "W3 a failed build must not be stored (entries: $(entries "$C3"))"
echo 0 > "$R/bin/share/rc"

# ── W4 an unreadable list, or none ──────────────────────────────────────────
C4="$T/c4"
warm "$T/no-such-list.txt" SHARE_MIRROR_CACHE="$C4"
[ "$RC" = 0 ] && [ "$(nwarn "$OUT")" = 1 ] && [ "$(entries "$C4")" = 0 ] && ok \
  || bad "W4 a missing list must be rc 0 with one ::warning:: and no build (rc=$RC: $OUT)"
warm "" SHARE_MIRROR_CACHE="$C4"
[ "$RC" = 0 ] && [ "$(nwarn "$OUT")" = 1 ] && [ "$(entries "$C4")" = 0 ] && ok \
  || bad "W4 no argument must be rc 0 with one ::warning:: (rc=$RC: $OUT)"
if [ "$(id -u)" != 0 ]; then
  printf 'tests/consumer.sh\n' > "$T/w4-locked.txt"; chmod 000 "$T/w4-locked.txt"
  warm "$T/w4-locked.txt" SHARE_MIRROR_CACHE="$C4"
  [ "$RC" = 0 ] && [ "$(nwarn "$OUT")" = 1 ] && [ "$(entries "$C4")" = 0 ] && ok \
    || bad "W4 an unreadable list must be rc 0 with one ::warning:: (rc=$RC: $OUT)"
  chmod 600 "$T/w4-locked.txt"
fi

echo "ci-share-mirror-warm.bh-9465: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/config-slice-snapshot.bh-7717-test.sh — BH-7717: the P1 history check of
# tests/config-slice-small.bh-1938-test.sh skips a harness snapshot history.
#
# bin/lib/rules-pack-snapshot.sh rp_snapshot_build makes the HEAD snapshot a
# fresh `git init` with two commits (base, head) by rules-pack@harness, and
# bin/suite-reach-check.sh commits its base as suite-reach@harness. Neither
# history can hold the pre-BH-1938 literal, so P1 must not fail there. A real
# history with no literal must still fail. An exported GIT_AUTHOR_EMAIL (as on
# a builder box) beats `git -c user.email`, so the snapshot shape counts too.
#
#   C1  base + head through the real _rp_snapshot_commit: root author
#       rules-pack@harness, exit 0, 0 failed.
#   C1e the same with GIT_AUTHOR_EMAIL/GIT_COMMITTER_EMAIL exported to another
#       address: exit 0 (the shape rule).
#   C2  2 commits by suite-reach@harness, subjects not `base`: exit 0 (the
#       author rule alone).
#   C3  2 commits by dev@example.com, subjects not `base`: exit 1 and
#       "full git history holds no" (the check still bites).
#   C3b the same by rules-pack@example.com (near miss): exit 1.
#   C3c 3 commits by dev@example.com, root subject `base`: exit 1 (the shape
#       rule stops at 2 commits).
#   C4  1 commit, any author: exit 0 (as before this ticket).
#
# The tree is this checkout's tracked files as they stand in the work tree.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/config-slice-snapshot.bh-7717-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SUITE=tests/config-slice-small.bh-1938-test.sh

R="$T/repo"; mkdir -p "$R"
(cd "$DIR" && git ls-files -z | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) | tar -x -C "$R" \
  || { echo "FAIL: could not copy the tracked tree"; exit 1; }
[ -f "$R/$SUITE" ] || { echo "FAIL: $SUITE missing from the copy"; exit 1; }

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# shellcheck source=bin/lib/rules-pack-snapshot.sh
. "$DIR/bin/lib/rules-pack-snapshot.sh" || exit 1

# mkhist <author email> <subject>... — a fresh history over the copied tree,
# one commit per subject (each after the first changes README.md).
mkhist() {
  local a="$1" s; shift
  scratch_rm "$R/.git"; git -C "$R" init -q || return 1
  for s in "$@"; do
    [ "$s" = "$1" ] || echo "# $s" >> "$R/README.md"
    git -C "$R" add -A && git -C "$R" -c user.email="$a" -c user.name=t -c commit.gpgsign=false \
      commit -q --no-verify --allow-empty -m "$s" || return 1
  done
}
# mksnap — base + head exactly as rp_snapshot_build commits them.
mksnap() {
  scratch_rm "$R/.git"; git -C "$R" init -q || return 1
  _rp_snapshot_commit "$R" base 2>/dev/null || return 1
  echo "# head" >> "$R/README.md"
  _rp_snapshot_commit "$R" head 2>/dev/null
}
root_author() { git -C "$R" log --max-parents=0 --format=%ae HEAD | tail -1; }
# runsuite — OUT, RC of the bh-1938 suite inside the copy.
runsuite() { OUT=$(cd "$R" && HARNESS_TEST_SANDBOX=1 bash "$SUITE" 2>&1); RC=$?; }
passes() { [ "$RC" = 0 ] && grep -q ', 0 failed' <<<"$OUT"; }
bites()  { [ "$RC" = 1 ] && grep -q 'full git history holds no' <<<"$OUT"; }

mksnap || bad "C1 setup"
[ "$(root_author)" = rules-pack@harness ] && ok || bad "C1 setup: root author $(root_author)"
runsuite; passes && ok || bad "C1 rules-pack snapshot: rc $RC: $(tail -5 <<<"$OUT")"

(export GIT_AUTHOR_EMAIL=other@example.com GIT_COMMITTER_EMAIL=other@example.com; mksnap) || bad "C1e setup"
[ "$(root_author)" = other@example.com ] && ok || bad "C1e setup: root author $(root_author)"
runsuite; passes && ok || bad "C1e snapshot under an exported identity: rc $RC: $(tail -5 <<<"$OUT")"

mkhist suite-reach@harness init next || bad "C2 setup"
runsuite; passes && ok || bad "C2 suite-reach@harness history: rc $RC: $(tail -5 <<<"$OUT")"

mkhist dev@example.com init next || bad "C3 setup"
runsuite; bites && ok || bad "C3 a real 2-commit history did not fail P1: rc $RC: $(tail -5 <<<"$OUT")"

mkhist rules-pack@example.com init next || bad "C3b setup"
runsuite; bites && ok || bad "C3b near-miss author skipped P1: rc $RC: $(tail -5 <<<"$OUT")"

mkhist dev@example.com base head more || bad "C3c setup"
runsuite; bites && ok || bad "C3c a 3-commit history rooted at base skipped P1: rc $RC: $(tail -5 <<<"$OUT")"

mkhist dev@example.com init || bad "C4 setup"
runsuite; [ "$RC" = 0 ] && ok || bad "C4 1-commit history: rc $RC: $(tail -5 <<<"$OUT")"

echo "config-slice-snapshot bh-7717: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

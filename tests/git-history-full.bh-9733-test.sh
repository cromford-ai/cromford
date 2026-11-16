#!/bin/bash
# tests/git-history-full.bh-9733-test.sh — ghf_full (tests/lib/git-history-full.bh-9733.sh)
# and the B1 case of tests/schema-compose-deploy.bh-6005-0-test.sh that uses it.
#
# WHY (BH-9733). B1 looks in the real git history for the commit that deleted
# worker/jobs/schema.sql. The gate's snapshot (bin/test-impact-gate.sh
# snapshot_tree: 1 or 2 fresh commits) and a shallow clone never hold it, so B1
# was red there and the suite was quarantined. B1 now prints a NOTE on such a
# history and still fails on full history with no deletion commit.
#
#   F1-F6  ghf_full rc per history shape (full, 1- and 2-commit snapshot,
#          shallow clone, plain dir, near miss with root subject `base`).
#   S1     the 6005 suite in a 1-commit snapshot of this tree: rc 0, B1 NOTE.
#   S2     the 6005 suite in a 3-commit full-history copy that never tracked
#          worker/jobs/schema.sql: `FAIL: B1: no commit ...` (not weakened).
#
# Run from anywhere: tests/git-history-full.bh-9733-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/git-history-full.bh-9733.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
# commits <repo> <subject>... — one commit per subject, each changes a file.
commits() {
  local r="$1" s; shift
  for s in "$@"; do
    printf '%s\n' "$s" >> "$r/f.txt"
    gitc -C "$r" add -A >/dev/null; gitc -C "$r" commit -qm "$s"
  done
}
# expect <name> <want-rc> <dir>
expect() {
  local rc=0; ghf_full "$3" || rc=1
  [ "$rc" = "$2" ] && ok || bad "$1: ghf_full $3 rc $rc, want $2"
}

# F1. full history, 3 commits → rc 0.
git init -q "$T/f1"; commits "$T/f1" one two three
expect F1 0 "$T/f1"
# F2. gate snapshot, 1 commit `snapshot` → rc 1.
git init -q "$T/f2"; commits "$T/f2" snapshot
expect F2 1 "$T/f2"
# F3. gate snapshot, 2 commits `base`, `head` → rc 1 (the edge at count 2).
git init -q "$T/f3"; commits "$T/f3" base head
expect F3 1 "$T/f3"
# F4. shallow clone of F1 → rc 1, though its source is full.
git clone -q --depth 1 "file://$T/f1" "$T/f4" 2>/dev/null
[ "$(git -C "$T/f4" rev-parse --is-shallow-repository)" = true ] || bad "F4: fixture is not shallow"
expect F4 1 "$T/f4"
# F5. plain dir, not a repo → rc 1.
mkdir -p "$T/f5"
expect F5 1 "$T/f5"
# F6. near miss: full repo, 3 commits, root subject `base` → rc 0 (count decides).
git init -q "$T/f6"; commits "$T/f6" base head third
expect F6 0 "$T/f6"

# The tree as it is on disk (tracked + new, not ignored), so S1/S2 test this
# checkout's suite and helper, committed or not.
copy_tree() {
  mkdir -p "$1"
  (cd "$DIR" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) 2>/dev/null \
    | tar -xf - -C "$1"
  rm -f "$1/worker/jobs/schema.sql"
}
S6005=tests/schema-compose-deploy.bh-6005-0-test.sh

# S1. 1-commit snapshot (the gate's shape): rc 0, NOTE line, no FAIL: B1.
copy_tree "$T/s1"
git init -q "$T/s1"
git -C "$T/s1" -c user.email=gate@harness -c user.name=gate add -A >/dev/null
git -C "$T/s1" -c user.email=gate@harness -c user.name=gate commit -qm snapshot
OUT=$(HARNESS_TEST_SANDBOX=1 bash "$T/s1/$S6005" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S1: 6005 suite in a snapshot rc $rc, want 0: $OUT"
grep -q '^NOTE: B1 not run' <<<"$OUT" && ok || bad "S1: no 'NOTE: B1 not run' line"
grep -q '^FAIL: B1' <<<"$OUT" && bad "S1: B1 failed in a snapshot" || ok

# S2. full history (3 commits) that never tracked worker/jobs/schema.sql:
#     B1 must still fail.
copy_tree "$T/s2"
git init -q "$T/s2"
printf 'a\n' > "$T/s2/.s2-a"; gitc -C "$T/s2" add .s2-a; gitc -C "$T/s2" commit -qm one
printf 'b\n' > "$T/s2/.s2-b"; gitc -C "$T/s2" add .s2-b; gitc -C "$T/s2" commit -qm two
gitc -C "$T/s2" add -A >/dev/null; gitc -C "$T/s2" commit -qm three
ghf_full "$T/s2" && ok || bad "S2: fixture is not full history"
OUT=$(HARNESS_TEST_SANDBOX=1 bash "$T/s2/$S6005" 2>&1); rc=$?
grep -q '^FAIL: B1: no commit in this repo tracks worker/jobs/schema.sql$' <<<"$OUT" && ok \
  || bad "S2: full history with no deletion commit did not fail B1: $OUT"
[ "$rc" != 0 ] && ok || bad "S2: 6005 suite rc 0 on full history with no deletion commit"
grep -q '^NOTE: B1 not run' <<<"$OUT" && bad "S2: B1 printed the NOTE on full history" || ok

echo "git-history-full.bh-9733-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

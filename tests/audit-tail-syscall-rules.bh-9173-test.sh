#!/bin/bash
# tests/audit-tail-syscall-rules.bh-9173-test.sh — the tailer reads what the
# BH-9173 syscall rules record.
#
# BH-9173 swapped the installer's `-w <root> -p wa -k harness` watches for
# `-a always,exit -S unlink,unlinkat,rmdir,rename,... -F dir=<root> -k harness`
# syscall rules. bin/audit-tail.sh did not change: it classes an event by its
# `syscall=` and its PATH `nametype=`, never by the rule that produced it, and
# the new records carry the same `key=harness`. This suite proves that on the
# record shape `ausearch -i` prints for `rm -rf /root/harness`: unlinkat on two
# files, unlinkat AT_REMOVEDIR on bin/lib, then rmdir(2) on bin/ itself.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/audit-tail-syscall-rules.bh-9173-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/audit/rmrf-syscall-rules.bh-9173.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h" "$T/claims" "$T/builds"
scratch_install_closure bin/audit-tail.sh "$T/h" >/dev/null || { echo "FAIL: cannot install the audit-tail closure"; exit 1; }
ROOTS="/root/harness /root/orchestrator /etc/harness /root/.ssh"
P() { HARNESS="$T/h" bash "$T/h/bin/audit-tail.sh" --parse --claims "$T/claims" --builds "$T/builds" \
        --worktrees /root/worktrees --roots "$ROOTS" < "$FX"; }

[ -s "$FX" ] && ok || bad "the fixture $FX is missing"
[ "$(grep -c 'key=harness$' "$FX")" -eq 4 ] && ok || bad "the fixture holds 4 SYSCALL records keyed harness"

OUT=$(P); RC=$?
[ "$RC" -eq 0 ] && ok || bad "--parse must exit 0 (rc=$RC)"
[ "$(grep -c . <<<"$OUT")" -eq 1 ] && ok || bad "one rm -rf pid is exactly one burst line: $OUT"
for want in 'class=delete' ' n=4 ' 'sev=critical' 'root=/root/harness ' 'pid=9173 ' 'comm=rm '; do
  grep -qF -- "$want" <<<"$OUT" && ok || bad "the burst must carry '$want': $OUT"
done

# The directory removal alone makes it critical, not the count: 4 events are far
# under a page threshold of 99.
OUT=$(AUDIT_PAGE_MIN=99 P)
grep -qF 'sev=critical' <<<"$OUT" && ok || bad "an rm -rf ending in rmdir is critical at AUDIT_PAGE_MIN=99: $OUT"

# The rmdir(2) record alone (the last syscall of a wipe of each top-level dir)
# is a delete burst with the dir flag set. Moved to builds/, which is not a
# protected prefix, so the dir removal is the only thing that makes it critical.
awk 'BEGIN{RS="----\n"; ORS=""} /syscall=rmdir/ {print "----\n" $0} END{print "----\n"}' "$FX" \
  | sed 's|/root/harness/bin|/root/harness/builds|g' > "$T/rmdir-only.txt"
OUT=$(HARNESS="$T/h" AUDIT_PAGE_MIN=99 bash "$T/h/bin/audit-tail.sh" --parse --claims "$T/claims" --builds "$T/builds" \
        --worktrees /root/worktrees --roots "/root/harness" < "$T/rmdir-only.txt")
grep -qF 'syscall=rmdir' <<<"$OUT" && grep -qF 'class=delete' <<<"$OUT" && grep -qF 'sev=critical' <<<"$OUT" && ok \
  || bad "a lone rmdir(2) of /root/harness/builds is a critical delete: $OUT"

echo "audit-tail-syscall-rules: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

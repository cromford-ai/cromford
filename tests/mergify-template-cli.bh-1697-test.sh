#!/bin/bash
# tests/mergify-template-cli.bh-1697-test.sh — THE BH-1673 CONTRACT HOLDS.
#
# BH-1697 (BH-1673 child 1 of 4) froze the CLI of bin/mergify-template.sh and
# the per-repo conf format under config/mergify/repos/. The siblings build
# against both, so this suite pins only what stays true once the renderer
# lands: usage errors are rc 2 with a usage line on stderr, and every conf
# parses as key=value with one slug, at least one check and only known keys.
# It never asserts the stub's rc 3.
# The ticket's scope check (no .mergify.yml, bin/merge-conductor.sh or
# bin/lib/mc/ in the diff) judges THIS PR's diff once, so it lives in the PR
# body, not here: a standing suite would fail every later conductor PR.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$DIR/bin/mergify-template.sh"
ok=0; bad=0
pass() { ok=$((ok+1)); }
fail() { bad=$((bad+1)); echo "FAIL: $*"; }

# 1-4: a usage error is rc 2, for every verb's wrong arg count.
usage_rc() {  # usage_rc <label> [args...]
  local label=$1; shift
  "$BIN" "$@" >"$T/out" 2>"$T/err"; local rc=$?
  if [ "$rc" = 2 ] && grep -q 'usage' "$T/err"; then pass
  else fail "$label: rc $rc (want 2), stderr: $(head -c 200 "$T/err")"; fi
}
usage_rc "no args"
usage_rc "unknown verb" frobnicate
usage_rc "compare with one arg" compare "$DIR/config/mergify/repos/project-5.conf"
usage_rc "render with no arg" render
usage_rc "render with two args" render a b
usage_rc "marker with two args" marker a b
usage_rc "--check with an arg" --check a

# 5: each conf is key=value lines with one slug, >=1 check, only known keys.
# queue_check joined the interface on 2026-09-24 (the corpus runs only on the
# batch draft; tests/mergify-queue-check-test.sh pins it). status_check joined it
# on 2026-09-29 (BH-3348, the lead-verdict status; tests/mergify-status-check.bh-3348-test.sh).
# queue_mode and scope_default_capacity joined it on 2026-10-07 (BH-4979, the
# parallel impact lanes; tests/queue-partition.bh-4979-test.sh R1-R4 pins them).
# batch_failure_attempts joined it on 2026-10-07 (BH-4980, Mergify's bisect
# switch; tests/queue-eject-culprit.bh-4980-test.sh M1-M3 pins it).
# solo_label joined it on 2026-10-08 (BH-5430, the size-1 solo queue;
# tests/mergify-solo-queue.bh-5430-test.sh pins it).
# flake_fix_label joined it on 2026-10-17 (BH-7279, the size-1 flake-fix queue;
# tests/mergify-flake-fix-queue.bh-7279-test.sh pins it).
known="slug check queue_check status_check merge_method batch_size batch_max_wait_time checks_timeout max_parallel_checks max_checks_retries base override queue_mode scope_default_capacity batch_failure_attempts solo_label flake_fix_label"
conf_ok() {  # conf_ok <file> -> prints problems, one per line
  awk -v known="$known" '
    BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) K[k[i]] = 1 }
    /^[[:space:]]*(#|$)/ { next }
    !/^[a-z_]+=[^[:space:]]/ { print "line " NR " not key=value: " $0; next }
    { key = substr($0, 1, index($0, "=") - 1); c[key]++
      if (!(key in K)) print "line " NR " unknown key: " key }
    END { if (c["slug"] != 1) print "slug count " c["slug"] + 0 " (want 1)"
          if (c["check"] < 1) print "no check= line" }' "$1"
}
n=0
for f in "$DIR"/config/mergify/repos/*.conf; do
  [ -f "$f" ] || continue
  n=$((n+1))
  probs=$(conf_ok "$f")
  if [ -z "$probs" ]; then pass; else fail "${f#"$DIR"/}: $probs"; fi
done
# 6: a deleted conf fails rather than passing vacuously.
if [ "$n" -ge 2 ]; then pass; else fail "config/mergify/repos/*.conf matched $n files (want >=2)"; fi
for want in project-5 cromford; do
  if [ -f "$DIR/config/mergify/repos/$want.conf" ]; then pass; else fail "config/mergify/repos/$want.conf missing"; fi
done

echo "$ok passed, $bad failed"
[ "$bad" = 0 ]

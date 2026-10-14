#!/bin/bash
# tests/responder-per-project.bh-6571-test.sh — BH-6571: R1 of
# tests/responder-per-project.bh-5942-test.sh read projfix-b's lock before the
# run that holds it had exited (CI merge-queue batch #6555: "FAIL: R1:
# projfix-b's lock is free once its run ended").
#
# The run holds locks/watchdog-responder-<p>.lock until bin/watchdog-responder.sh
# exits, and it still logs, stamps handled.json and resets the token after the
# agent-call stub writes done.txt. This suite replays that window on purpose: it
# runs a copy of the bh-5942 suite whose stub sleeps BH6571_TAIL seconds after
# projfix-b's done.txt write, so the lock stays held that long after done.txt
# names projfix-b. The bh-5942 suite file itself is never edited.
#
#   D1  a 1 s tail: the suite exits 0, no "FAIL: R1" line, "0 failed"
#   D2  no tail: the suite exits 0
#   D3  a 12 s tail (over R1's 10 s bound): the suite exits non-zero with
#       "FAIL: R1: projfix-b's lock is free once its run ended"
#
# The stubs of both runs also probe the old locks/responder.lock at the same
# moment. An exclusive probe made the other session's probe read "held" (1 of
# 30 parallel runs on the build box). The probe is shared now:
#   D4  an exclusive holder of locks/responder.lock during R1 still fails R1
#       with "the old global locks/responder.lock is not held"
#   D5  a shared holder (what the other session's probe is) passes
#
# BH6571_SUITE names the suite to replay (default: this repo's bh-5942 suite).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/responder-per-project.bh-6571-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SRC="${BH6571_SUITE:-$DIR/tests/responder-per-project.bh-5942-test.sh}"
COPY="$T/replay-5942.sh"
ANCHOR='echo "\$p" >> "$T/done.txt"'
R1START='RESET; touch "$T/hold.projfix-a"'
# The two anchors must each be in the suite, or the replay proves nothing.
[ -r "$SRC" ] || { echo "FAIL: setup: cannot read $SRC"; exit 1; }
[ "$(grep -cF "$ANCHOR" "$SRC")" = 1 ] && ok || bad "setup: the stub's done.txt line is in $SRC exactly once"
[ "$(grep -cxF "$R1START" "$SRC")" = 1 ] && ok || bad "setup: R1's start line is in $SRC exactly once"
grep -qF 'dirname "$0"' "$SRC" && ok || bad "setup: $SRC resolves its paths from dirname \"\$0\""
# BH6571_OLDLOCK=excl|shared holds locks/responder.lock from R1's start (fd 6).
# The strings reach awk through ENVIRON, never -v or an awk string literal:
# both process backslash escapes, and mawk/gawk on the CI runner turn `\$`
# into `$` (with a warning), so the anchor stopped matching and the inserted
# lines lost their backslash (BH-6571 fix round, batch #6606).
TAIL_LINE='[ "\$p" = projfix-b ] && sleep "${BH6571_TAIL:-0}"'
LOCK_LINE='case "${BH6571_OLDLOCK:-}" in excl) exec 6>"$H/locks/responder.lock"; flock -n 6 ;; shared) exec 6>"$H/locks/responder.lock"; flock -n -s 6 ;; esac'
AW_A="$ANCHOR" AW_R="$R1START" AW_TESTS="$DIR/tests" AW_TAIL="$TAIL_LINE" AW_LOCK="$LOCK_LINE" awk '
  BEGIN { a = ENVIRON["AW_A"]; r = ENVIRON["AW_R"]; tests = ENVIRON["AW_TESTS"] }
  { gsub(/\$\(dirname "\$0"\)/, tests); print }
  index($0, a) { print ENVIRON["AW_TAIL"] }
  $0 == r { print ENVIRON["AW_LOCK"] }
' "$SRC" > "$COPY"
grep -qF 'dirname "$0"' "$COPY" && bad "setup: the copy still resolves paths from its own location" || ok
[ "$(grep -cF '[ "\$p" = projfix-b ] && sleep "${BH6571_TAIL:-0}"' "$COPY")" = 1 ] && ok \
  || bad "setup: the copy has the tail sleep exactly once"
[ "$(grep -c '^case "${BH6571_OLDLOCK:-}" in excl)' "$COPY")" = 1 ] && ok \
  || bad "setup: the copy has the old-lock holder exactly once"
[ "$FAIL" -eq 0 ] || { echo "responder-per-project.bh-6571: $PASS passed, $FAIL failed"; exit 1; }

# replay <tail seconds> [excl|shared] — runs the copy; sets ROUT and RRC.
replay() { ROUT=$(BH6571_TAIL="$1" BH6571_OLDLOCK="${2:-}" HARNESS_TEST_SANDBOX="${HARNESS_TEST_SANDBOX:-}" bash "$COPY" 2>&1); RRC=$?; }

# D1 — the lock is released 1 s after done.txt names projfix-b.
replay 1
[ "$RRC" = 0 ] && ok || bad "D1: a 1 s tail exits 0 (rc=$RRC): $(grep '^FAIL' <<<"$ROUT")"
grep -q '^FAIL: R1' <<<"$ROUT" && bad "D1: a 1 s tail prints no R1 failure: $(grep '^FAIL: R1' <<<"$ROUT")" || ok
grep -q '^responder-per-project.bh-5942: [0-9]* passed, 0 failed$' <<<"$ROUT" && ok \
  || bad "D1: the summary says 0 failed: $(tail -1 <<<"$ROUT")"

# D2 — no tail: the normal path.
replay 0
[ "$RRC" = 0 ] && ok || bad "D2: no tail exits 0 (rc=$RRC): $(grep '^FAIL' <<<"$ROUT")"

# D3 — a lock still held past the 10 s bound fails R1 with the same text.
replay 12
[ "$RRC" != 0 ] && ok || bad "D3: a 12 s tail exits non-zero"
grep -qx "FAIL: R1: projfix-b's lock is free once its run ended" <<<"$ROUT" && ok \
  || bad "D3: a 12 s tail fails R1 on projfix-b's lock: $(grep '^FAIL' <<<"$ROUT")"

# D4 — something holds the old lock exclusively: R1 still says so.
OLDFAIL='FAIL: R1: the old global locks/responder.lock is not held (a=held b=held)'
replay 0 excl
[ "$RRC" != 0 ] && grep -qxF "$OLDFAIL" <<<"$ROUT" && ok \
  || bad "D4: an exclusive holder fails R1's old-lock check (rc=$RRC): $(grep '^FAIL' <<<"$ROUT")"

# D5 — a shared holder, as the other session's probe is: R1 passes.
replay 0 shared
[ "$RRC" = 0 ] && ok || bad "D5: a shared holder of the old lock exits 0 (rc=$RRC): $(grep '^FAIL' <<<"$ROUT")"

echo "responder-per-project.bh-6571: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

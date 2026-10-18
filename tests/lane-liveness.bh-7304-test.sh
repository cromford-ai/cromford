#!/bin/bash
# tests/lane-liveness.bh-7304-test.sh — BH-7304 (BH-7191.2): the liveness post
# of bin/lib/lane-gate.sh sends the box's harness sha when it CHANGES, else
# hourly, and on those send ticks also harness_synced_at and sync_timer.
#
#   C1-C6  the send decision (_lg_harness_commit + the <epoch> <sha> stamp)
#   P1-P2  harness_synced_at from state/harness-sync-phase (done only)
#   T1-T5  sync_timer from crontab -l (only with bin/harness-sync-timer.sh)
#   G1     no git exec on any path
#
# The production entry is _lg_liveness, the call lane_gate_or_exit makes on
# every tick. _jobs_req is stubbed to record the body it is handed.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-liveness.bh-7304-test.sh
set -u
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd -P)
LIB="$DIR/bin/lib/lane-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

NOW=1792000000
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
S="$T/h"; CO="$T/co"; STUB="$T/stub"
mkdir -p "$S/state/lane-gate" "$S/bin" "$CO/.git/refs/heads" "$STUB"
printf 'ref: refs/heads/main\n' > "$CO/.git/HEAD"
printf '%s\n' "$SHA" > "$CO/.git/refs/heads/main"
STAMP="$S/state/lane-gate/.harness-commit-sent"
PHASE="$S/state/harness-sync-phase"

# git records every call. crontab answers from $T/crontab.txt (rc 1 when the
# file is absent, as `crontab -l` does with no crontab) and records each call.
printf '#!/bin/sh\necho "git $*" >> "%s/git.calls"\nexit 99\n' "$T" > "$STUB/git"
cat > "$STUB/crontab" <<EOF
#!/bin/sh
echo "crontab \$*" >> "$T/crontab.calls"
[ -f "$T/crontab.txt" ] || { echo "no crontab for fixture" >&2; exit 1; }
cat "$T/crontab.txt"
EOF
chmod +x "$STUB/git" "$STUB/crontab"

# live [post_rc] — one tick through _lg_liveness. Prints the body it posted
# (empty when it posted none).
live() {
  : > "$T/body"
  ( export HARNESS="$S" HARNESS_CHECKOUT="$CO" LANE_GATE_NOW="$NOW" JOBS_BOX=box-fixture PATH="${LIVE_STUB:-$STUB}:$PATH"
    unset H JOBS_HTTP
    # shellcheck source=bin/lib/lane-gate.sh
    . "$LIB" || exit 9
    flag_sync() { :; }
    _jobs_req() { printf '%s' "$3" > "$T/body"; return "${POST_RC:-0}"; }
    _lg_liveness merge-conductor "" ran ) >/dev/null 2>&1
  cat "$T/body"
}
key() { jq -r --arg k "$2" 'if has($k) then (.[$k] | tojson) else "absent" end' <<<"$1" 2>/dev/null; }
stamp() { printf '%s\n' "$1" > "$STAMP"; }
rm -f "$T/git.calls"

echo "C: the send decision"
stamp "$((NOW - 600)) $SHA"
b=$(live); eq "C1 same sha, 10 min old: no harness_commit" "$(key "$b" harness_commit)" absent
eq "C1 the tick itself still posts" "$(jq -r .lane <<<"$b")" merge-conductor
eq "C1 the stamp is untouched" "$(cat "$STAMP")" "$((NOW - 600)) $SHA"
stamp "$((NOW - 600)) $OTHER"
b=$(live); eq "C2 a different sha, 10 min old: sent" "$(key "$b" harness_commit)" "\"$SHA\""
eq "C2 the stamp now holds the new sha" "$(cat "$STAMP")" "$NOW $SHA"
stamp "$((NOW - 3660)) $SHA"
b=$(live); eq "C3 same sha, 61 min old: sent (hourly)" "$(key "$b" harness_commit)" "\"$SHA\""
stamp "$((NOW - 3599)) $SHA"
b=$(live); eq "C3b same sha, 3599 s old: not sent" "$(key "$b" harness_commit)" absent
stamp "$((NOW - 3600)) $SHA"
b=$(live); eq "C3c same sha, 3600 s old: sent" "$(key "$b" harness_commit)" "\"$SHA\""
stamp "$((NOW - 600))"
b=$(live); eq "C4 an old epoch-only stamp: sent" "$(key "$b" harness_commit)" "\"$SHA\""
eq "C4 the stamp is rewritten as <epoch> <sha>" "$(cat "$STAMP")" "$NOW $SHA"
stamp "$((NOW - 600)) $OTHER"
b=$(POST_RC=1 live); eq "C5 a failed post still carried the sha" "$(key "$b" harness_commit)" "\"$SHA\""
eq "C5 a failed post leaves the stamp unchanged" "$(cat "$STAMP")" "$((NOW - 600)) $OTHER"
# The failed post armed the one-minute .post-miss throttle; clear it for the next case.
rm -f "$S/state/lane-gate/.post-miss"
rm -f "$STAMP"
b=$(live); eq "C6 no stamp: sent" "$(key "$b" harness_commit)" "\"$SHA\""
stamp "$((NOW + 600)) $SHA"
b=$(live); eq "C6b a stamp in the future: sent" "$(key "$b" harness_commit)" "\"$SHA\""
stamp "$((NOW - 600)) $SHA"$'\r'
b=$(live); eq "C6c a stamp with a trailing CR: same sha, not sent" "$(key "$b" harness_commit)" absent

echo "P: harness_synced_at"
rm -f "$STAMP"
printf 'done %s 2026-10-18T02:00:00Z\n' "$SHA" > "$PHASE"
b=$(live); eq "P1 phase done: harness_synced_at sent" "$(key "$b" harness_synced_at)" '"2026-10-18T02:00:00Z"'
rm -f "$STAMP"
printf 'step=worker-phase %s 2026-10-18T02:10:00Z\n' "$SHA" > "$PHASE"
b=$(live); eq "P2 phase step=x: the key is absent" "$(key "$b" harness_synced_at)" absent
rm -f "$STAMP"
printf 'done %s not-a-time\n' "$SHA" > "$PHASE"
b=$(live); eq "P2b phase done with a bad time: the key is absent" "$(key "$b" harness_synced_at)" absent
printf 'done %s 2026-10-18T02:00:00Z\n' "$SHA" > "$PHASE"
stamp "$((NOW - 600)) $SHA"
b=$(live); eq "P3 a non-send tick carries no harness_synced_at" "$(key "$b" harness_synced_at)" absent

echo "T: sync_timer"
rm -f "$STAMP" "$T/crontab.calls" "$T/crontab.txt"
b=$(live); eq "T1 no bin/harness-sync-timer.sh: the key is absent" "$(key "$b" sync_timer)" absent
eq "T1 and crontab is not read" "$(cat "$T/crontab.calls" 2>/dev/null)" ""
printf '#!/bin/sh\nexit 0\n' > "$S/bin/harness-sync-timer.sh"; chmod +x "$S/bin/harness-sync-timer.sh"
printf '# m h dom mon dow command\n*/5 * * * * %s/bin/harness-sync-timer.sh >/dev/null 2>&1\n' "$S" > "$T/crontab.txt"
rm -f "$STAMP"
b=$(live); eq "T2 a crontab line names harness-sync-timer: 1" "$(key "$b" sync_timer)" 1
printf '#*/5 * * * * %s/bin/harness-sync-timer.sh\n0 * * * * true\n' "$S" > "$T/crontab.txt"
rm -f "$STAMP"
b=$(live); eq "T3 only a commented line: 0" "$(key "$b" sync_timer)" 0
rm -f "$T/crontab.txt" "$STAMP"
b=$(live); eq "T4 crontab -l rc 1 (no crontab): 0" "$(key "$b" sync_timer)" 0
rm -f "$T/crontab.calls"
stamp "$((NOW - 600)) $SHA"
b=$(live); eq "T5 a non-send tick: no sync_timer" "$(key "$b" sync_timer)" absent
eq "T5 a non-send tick does not call crontab" "$(cat "$T/crontab.calls" 2>/dev/null)" ""

# T6 needs a PATH with no crontab at all, so it runs only where the box has none.
mkdir -p "$T/stub-nocron"; cp "$STUB/git" "$T/stub-nocron/git"
if command -v crontab >/dev/null 2>&1; then
  echo "  skip T6: this box has a crontab binary"
else
  rm -f "$STAMP"
  b=$(LIVE_STUB="$T/stub-nocron" live); eq "T6 no crontab on PATH: the key is absent" "$(key "$b" sync_timer)" absent
  eq "T6 the sha still rides" "$(key "$b" harness_commit)" "\"$SHA\""
fi

echo "G: no git"
eq "G1 no case ran git" "$(cat "$T/git.calls" 2>/dev/null)" ""

echo
echo "lane-liveness.bh-7304: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

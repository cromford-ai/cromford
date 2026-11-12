#!/bin/bash
# tests/fixround-waiting-conditions.bh-9612-test.sh — BH-9612: a fix round on a
# PR whose only Mergify check says "Waiting for queue conditions to match" is
# pushed. That PR (a lead or a person blocked it) is in no queue and no batch.
# Every other "queued" answer keeps the BH-8592 guard: not pushed.
#
#   W1 waiting-only check, mc_queue_state queued        -> rc 0, pushed, said
#   W2 two waiting lines                                -> rc 0
#   W3 waiting + an in-queue line                       -> rc 1, fix-round-queued
#   W4 queued with no Mergify check (label only)        -> rc 1
#   W5 the check read fails                             -> rc 1
#   W6 not queued (ejected): no check read at all       -> rc 0
#   W7 merged                                           -> rc 0
#   W8 no mc_mergify_check in scope                     -> rc 1 (today's answer)
#
# No network, no gh: every vendor verb is a stub.
#   HARNESS_TEST_SANDBOX=1 bash tests/fixround-waiting-conditions.bh-9612-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FRAG="$DIR/bin/blocked-resolver.d/bh-8592-fixround-nochange.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$FRAG" ] || { echo "FAIL: $FRAG missing"; exit 1; }

URL=https://github.com/o/r/pull/91
LEASE=0123456789abcdef0123456789abcdef01234567
WAIT='completed|neutral|Waiting for queue conditions to match'

# G <qstate> <check-lines|FAIL|NONE> [nofn] -> prints "rc:<rc>" and fills $T/*.log
G() {
  : > "$T/say.log"; : > "$T/record.log"; : > "$T/check.log"
  printf '%s' "$1" > "$T/qstate"; printf '%s' "$2" > "$T/check"
  bash -c '
    T="$1"; FRAG="$2"; NOFN="$3"
    say() { printf "%s\n" "$*" >> "$T/say.log"; }
    br_record() { printf "%s\n" "$*" >> "$T/record.log"; }
    br_event() { :; }
    br_wt_drop() { :; }
    mc_git_auth_clear() { :; }
    mc_slug_of_url() { printf "o/r"; }
    mc_queue_state() { cat "$T/qstate"; }
    mc_mergify_check() {
      printf "%s\n" "$*" >> "$T/check.log"
      case "$(cat "$T/check")" in FAIL) return 75 ;; NONE) return 0 ;; *) cat "$T/check" ;; esac
    }
    [ "$NOFN" = nofn ] && unset -f mc_mergify_check
    . "$FRAG"
    brnc_queued_guard tproj ck-1 o-r-91 review-changes-requested "'"$URL"'" "'"$LEASE"'" "'"$LEASE"'"
  ' _ "$T" "$FRAG" "${3:-}"
  printf 'rc:%s' "$?"
}

R=$(G queued "$WAIT")
[ "$R" = rc:0 ] && ok || bad "W1 waiting-only is pushed (got $R; say: $(cat "$T/say.log"))"
grep -q "only waits for queue conditions on ${LEASE:0:8}" "$T/say.log" && ok || bad "W1 one line says why: $(cat "$T/say.log")"
[ ! -s "$T/record.log" ] && ok || bad "W1 no fix-round-queued record: $(cat "$T/record.log")"
grep -qx "o/r $URL $LEASE" "$T/check.log" && ok || bad "W1 the check is read on the lease: $(cat "$T/check.log")"

R=$(G queued "$WAIT"$'\n'"$WAIT")
[ "$R" = rc:0 ] && ok || bad "W2 two waiting lines are pushed (got $R)"

R=$(G queued "$WAIT"$'\n''in_progress||The pull request is embarked in a merge queue')
[ "$R" = rc:1 ] && ok || bad "W3 waiting + an in-queue line is not pushed (got $R)"
grep -q "fix-round-queued" "$T/record.log" && ok || bad "W3 fix-round-queued recorded: $(cat "$T/record.log")"

R=$(G queued NONE)
[ "$R" = rc:1 ] && ok || bad "W4 queued with no check is not pushed (got $R)"

R=$(G queued FAIL)
[ "$R" = rc:1 ] && ok || bad "W5 a failed check read is not pushed (got $R)"

R=$(G ejected "$WAIT")
[ "$R" = rc:0 ] && ok || bad "W6 ejected is pushed (got $R)"
[ ! -s "$T/check.log" ] && ok || bad "W6 no check read when not queued: $(cat "$T/check.log")"

R=$(G merged "$WAIT")
[ "$R" = rc:0 ] && ok || bad "W7 merged is pushed (got $R)"

R=$(G queued "$WAIT" nofn)
[ "$R" = rc:1 ] && ok || bad "W8 no mc_mergify_check keeps today's answer (got $R)"

echo "fixround-waiting-conditions.bh-9612: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

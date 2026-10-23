#!/bin/bash
# tests/scale-fakes.bh-7906-test.sh — BH-7906: the scale knobs on the shared
# vendor fakes, and scale_wrap. Every vendor here is a local fake: 0 network
# calls. Each case builds its own subdir of $T, so no case reads another's
# state and the order of cases does not matter.
#
#   F1  "$DIR/tests/lib/gh-rest-stub.sh" through the REAL gh_rest of
#       "$DIR/bin/lib/gh-rest.sh": SCALE_FAKE_RATE_LIMIT_EVERY=3 makes calls
#       3 and 6 a 403 with x-ratelimit-remaining: 0 (rc 75, rate-limit), and
#       calls 1, 2 and 4 answer 2xx.
#   F2  SCALE_FAKE_LATENCY_MS=50: one call to each fake takes >= 50 ms. With
#       the knobs unset the stub writes the same bytes as with the hook armed
#       but not firing, and makes no counter file.
#   F3  "$DIR/tests/lib/fake-jobs-attempts.bh-4156.sh" through the REAL
#       _jobs_req of "$DIR/bin/lib/jobs/req.sh": EVERY=2, call 2 is a 503 whose
#       body says "D1 DB is overloaded"; the default overload retry reads it as
#       an overload and retries.
#   F4  "$DIR/tests/lib/pool-reap-fixture.sh" write_fly_stub: EVERY=1, exit 1
#       and 429 on stderr.
#   F5  0, -3, abc, 3.5: ignored, the fake answers as normal, one
#       `scale-fake: ignored` line.
#   W1  "$DIR/tests/lib/scale.sh" scale_wrap: 10 calls under xargs -P 4 record
#       calls=10 max_in_flight=4 in_flight=0; -P 1 records max_in_flight=1.
#   W2  scale_wrap false returns 1 and still counts the call.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/fake-jobs-attempts.bh-4156.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: [$3] not in [$2]"; fi; }
ms_now() { date +%s%N | cut -c1-13; }

unset SCALE_FAKE_LATENCY_MS SCALE_FAKE_RATE_LIMIT_EVERY

# ── the real gh_rest, with its closure in a scratch harness ──────────────────
GH_H="$T/gh-h"; mkdir -p "$GH_H"
( cd "$DIR" && scratch_install_closure bin/lib/gh-rest.sh "$GH_H" ) >/dev/null || { echo "setup: closure install failed"; exit 1; }

f1_run() { # f1_run <case dir> <calls> — every call's "n rc status reason remaining"
  local c="$1" calls="$2"
  ( export HARNESS="$c/h" GHT="$c" GH_ETAG=0
    mkdir -p "$c/h"
    . "$GH_H/bin/lib/gh-rest.sh" || exit 1
    gh() { case "$*" in *"-i -X "*) . "$DIR/tests/lib/gh-rest-stub.sh" || return 1; gh_rest_stub "$@" ;; *) return 1 ;; esac; }
    i=1
    while [ "$i" -le "$calls" ]; do
      rc=0; gh_rest GET repos/fixture-org/fixture-repo/pulls/9 > "$c/body-$i" || rc=$?
      echo "$i $rc $GH_REST_STATUS ${GH_REST_REASON:--} ${GH_REST_QUOTA_REMAINING:--}"
      i=$((i+1))
    done )
}

# ── F1 ───────────────────────────────────────────────────────────────────────
C="$T/f1"; mkdir -p "$C"; printf 'OPEN\n' > "$C/prstate"
OUT=$(SCALE_FAKE_RATE_LIMIT_EVERY=3 f1_run "$C" 6)
eq "F1 call 1 answers 2xx" "$(echo "$OUT" | awk '$1==1{print $2,$3}')" "0 200"
eq "F1 call 2 answers 2xx" "$(echo "$OUT" | awk '$1==2{print $2,$3}')" "0 200"
eq "F1 call 3 is the rate-limit shape (rc, status, reason, remaining)" "$(echo "$OUT" | awk '$1==3{print $2,$3,$4,$5}')" "75 403 rate-limit 0"
eq "F1 call 4 is not rate limited" "$(echo "$OUT" | awk '$1==4{print $2,$3}')" "0 200"
eq "F1 call 6 is rate limited again" "$(echo "$OUT" | awk '$1==6{print $2,$3,$4}')" "75 403 rate-limit"
has "F1 call 1 body is the stub's PR object" "$(cat "$C/body-1")" '"state":"open"'
eq "F1 the github counter counted 6 calls" "$(cat "$C/scale-fake.github.calls")" "6"
# Near miss: the knob unset, the same six calls are all 2xx and count nothing.
C="$T/f1-unset"; mkdir -p "$C"
OUT=$(f1_run "$C" 6)
eq "F1 knobs unset: no call is rate limited" "$(echo "$OUT" | awk '$3!=200' | wc -l | tr -d ' ')" "0"
eq "F1 knobs unset: no counter file" "$([ -e "$C/scale-fake.github.calls" ] && echo yes || echo no)" "no"

# ── F2 ───────────────────────────────────────────────────────────────────────
C="$T/f2-gh"; mkdir -p "$C"; printf 'OPEN\n' > "$C/prstate"
t0=$(ms_now); ( GHT="$C" SCALE_FAKE_LATENCY_MS=50; export SCALE_FAKE_LATENCY_MS
  . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub api -i -X GET repos/fixture-org/fixture-repo/pulls/9 > "$C/out" ); t1=$(ms_now)
d=$((t1 - t0)); [ "$d" -ge 50 ] && ok || bad "F2 github fake took ${d} ms, want >= 50"
has "F2 github fake still answers after the delay" "$(cat "$C/out")" "HTTP/2 200"
# Near miss on bytes: unset vs armed-but-not-firing (EVERY=1000) are the same bytes.
C="$T/f2-bytes"; mkdir -p "$C/a" "$C/b"; printf 'OPEN\n' | tee "$C/a/prstate" > "$C/b/prstate"
( GHT="$C/a"; . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub api -i -X GET repos/fixture-org/fixture-repo/pulls/9 ) > "$C/unset.out"
( GHT="$C/b" SCALE_FAKE_RATE_LIMIT_EVERY=1000; export SCALE_FAKE_RATE_LIMIT_EVERY
  . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub api -i -X GET repos/fixture-org/fixture-repo/pulls/9 ) > "$C/armed.out"
if cmp -s "$C/unset.out" "$C/armed.out" && [ -s "$C/unset.out" ]; then ok; else bad "F2 knobs unset changed the stub's bytes"; fi
eq "F2 knobs unset: the hook made no counter" "$([ -e "$C/a/scale-fake.github.calls" ] && echo yes || echo no)" "no"
eq "F2 armed: the hook counted the call" "$(cat "$C/b/scale-fake.github.calls" 2>/dev/null)" "1"

C="$T/f2-jobs"; fja_install "$C" || exit 1
t0=$(ms_now); SCALE_FAKE_LATENCY_MS=50 "$C/bin/curl" -sS -X GET https://jobs.invalid/api/verdicts > "$C/out"; t1=$(ms_now)
d=$((t1 - t0)); [ "$d" -ge 50 ] && ok || bad "F2 jobs fake took ${d} ms, want >= 50"
has "F2 jobs fake still answers after the delay" "$(cat "$C/out")" '"standing":null'

C="$T/f2-fly"; mkdir -p "$C/fakebin"
( T="$C"; . "$DIR/tests/lib/pool-reap-fixture.sh" || exit 1; write_fly_stub ) || exit 1
t0=$(ms_now); SCALE_FAKE_LATENCY_MS=50 "$C/fakebin/fly" machine status --machine m1 > "$C/out" 2>&1; rc=$?; t1=$(ms_now)
d=$((t1 - t0)); [ "$d" -ge 50 ] && ok || bad "F2 fly fake took ${d} ms, want >= 50"
eq "F2 fly fake still answers after the delay" "$rc $(cat "$C/out")" "0 State: started"

# ── F3 ───────────────────────────────────────────────────────────────────────
f3_run() { # f3_run <fake dir> <calls> [VAR=value...] — "n rc http" per call
  local w="$1" calls="$2"; shift 2
  ( unset -f curl; export PATH="$w/bin:$PATH" HARNESS="$w/h" HARNESS_ENV_DIR="$w/h/env" \
      JOBS_URL=https://jobs.invalid HARNESS_SECRET=secret-fixture-7906 JOBS_RETRIES=0 JOBS_ALERT=0 \
      JOBS_OVERLOAD_SLEEP=0 JOBS_OVERLOAD_JITTER_S=0 "$@"
    mkdir -p "$w/h/logs" "$w/h/env"
    . "$JOBS_H/bin/jobs-client.sh" >/dev/null 2>&1 || { echo "client load failed"; exit 1; }
    i=1
    while [ "$i" -le "$calls" ]; do
      rc=0; _jobs_req GET /api/verdicts > /dev/null 2>&1 || rc=$?
      printf '%s %s %s\n' "$i" "$rc" "$JOBS_HTTP"
      printf '%s' "$JOBS_BODY" > "$w/body-$i"
      i=$((i+1))
    done )
}
JOBS_H="$T/jobs-h"; mkdir -p "$JOBS_H"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$JOBS_H" ) >/dev/null || { echo "setup: jobs closure install failed"; exit 1; }
C="$T/f3"; fja_install "$C" || exit 1
OUT=$(f3_run "$C" 2 SCALE_FAKE_RATE_LIMIT_EVERY=2 JOBS_OVERLOAD_RETRIES=0)
eq "F3 call 1 sees the normal answer" "$(echo "$OUT" | awk '$1==1{print $2,$3}')" "0 200"
eq "F3 call 2 sees a 503" "$(echo "$OUT" | awk '$1==2{print $2,$3}')" "1 503"
has "F3 call 2 body says the D1 overload" "$(cat "$C/body-2")" "D1 DB is overloaded"
# The production retry reads the shape as an overload: with its default of one
# retry, call 2 is answered by a third request.
C="$T/f3-retry"; fja_install "$C" || exit 1
OUT=$(f3_run "$C" 2 SCALE_FAKE_RATE_LIMIT_EVERY=2)
eq "F3 the real overload retry answers call 2" "$(echo "$OUT" | awk '$1==2{print $2,$3}')" "0 200"
eq "F3 the retry made a third request" "$(wc -l < "$C/req.log" | tr -d ' ')" "3"

# ── F4 ───────────────────────────────────────────────────────────────────────
C="$T/f4"; mkdir -p "$C/fakebin"
( T="$C"; . "$DIR/tests/lib/pool-reap-fixture.sh" || exit 1; write_fly_stub ) || exit 1
SCALE_FAKE_RATE_LIMIT_EVERY=1 "$C/fakebin/fly" machines list > "$C/out" 2> "$C/err"; rc=$?
eq "F4 fly fake exits 1 when rate limited" "$rc" "1"
has "F4 fly fake prints 429 on stderr" "$(cat "$C/err")" "429"
eq "F4 fly fake prints nothing on stdout" "$(cat "$C/out")" ""
"$C/fakebin/fly" machines list > "$C/out2" 2>&1; rc=$?
eq "F4 knobs unset: the fly fake answers as before" "$rc $(cat "$C/out2")" "0 []"

# ── F5 ───────────────────────────────────────────────────────────────────────
for v in 0 -3 abc 3.5; do
  k="f5-${v//[^a-z0-9]/x}"
  C="$T/$k-gh"; mkdir -p "$C"; printf 'OPEN\n' > "$C/prstate"
  ( GHT="$C" SCALE_FAKE_RATE_LIMIT_EVERY="$v"; export SCALE_FAKE_RATE_LIMIT_EVERY
    . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub api -i -X GET repos/fixture-org/fixture-repo/pulls/9 ) > "$C/out" 2> "$C/err"
  has "F5 EVERY=$v github answers as normal" "$(head -n1 "$C/out")" "HTTP/2 200"
  eq "F5 EVERY=$v one ignored line" "$(grep -c '^scale-fake: ignored SCALE_FAKE_RATE_LIMIT_EVERY=' "$C/err")" "1"
  C="$T/$k-lat"; mkdir -p "$C"; printf 'OPEN\n' > "$C/prstate"
  ( GHT="$C" SCALE_FAKE_LATENCY_MS="$v"; export SCALE_FAKE_LATENCY_MS
    . "$DIR/tests/lib/gh-rest-stub.sh" || exit 1; gh_rest_stub api -i -X GET repos/fixture-org/fixture-repo/pulls/9 ) > "$C/out" 2> "$C/err"
  eq "F5 LATENCY=$v one ignored line" "$(grep -c '^scale-fake: ignored SCALE_FAKE_LATENCY_MS=' "$C/err")" "1"
  C="$T/$k-jobs"; fja_install "$C" || exit 1
  SCALE_FAKE_RATE_LIMIT_EVERY="$v" "$C/bin/curl" -sS https://jobs.invalid/api/verdicts > "$C/out" 2> "$C/err"
  has "F5 EVERY=$v jobs answers as normal" "$(cat "$C/out")" "200"
  eq "F5 EVERY=$v jobs one ignored line" "$(grep -c '^scale-fake: ignored' "$C/err")" "1"
  C="$T/$k-fly"; mkdir -p "$C/fakebin"
  ( T="$C"; . "$DIR/tests/lib/pool-reap-fixture.sh" || exit 1; write_fly_stub ) || exit 1
  SCALE_FAKE_RATE_LIMIT_EVERY="$v" "$C/fakebin/fly" machines list > "$C/out" 2> "$C/err"; rc=$?
  eq "F5 EVERY=$v fly answers as normal" "$rc $(cat "$C/out")" "0 []"
  eq "F5 EVERY=$v fly one ignored line" "$(grep -c '^scale-fake: ignored' "$C/err")" "1"
done

# ── W1, W2 ───────────────────────────────────────────────────────────────────
mkdir -p "$T/w1"
SCALE_STATE="$T/w1/state" SCALE_LIB="$DIR/tests/lib/scale.sh" bash -c 'export SCALE_STATE SCALE_LIB; seq 10 | xargs -P 4 -I{} bash -c ". \"\$SCALE_LIB\" || exit 1; scale_wrap sleep 1"'
eq "W1 10 calls under 4 slots" "$(tr '\n' ' ' < "$T/w1/state")" "calls=10 in_flight=0 max_in_flight=4 "
mkdir -p "$T/w1-serial"
SCALE_STATE="$T/w1-serial/state" SCALE_LIB="$DIR/tests/lib/scale.sh" bash -c 'export SCALE_STATE SCALE_LIB; seq 3 | xargs -P 1 -I{} bash -c ". \"\$SCALE_LIB\" || exit 1; scale_wrap true"'
eq "W1 near miss: -P 1 records max_in_flight=1" "$(tr '\n' ' ' < "$T/w1-serial/state")" "calls=3 in_flight=0 max_in_flight=1 "
mkdir -p "$T/w2"
rc=0; ( SCALE_STATE="$T/w2/state"; . "$DIR/tests/lib/scale.sh" || exit 9; scale_wrap false ) || rc=$?
eq "W2 scale_wrap false returns 1" "$rc" "1"
eq "W2 the failed call still counts and leaves in_flight 0" "$(tr '\n' ' ' < "$T/w2/state")" "calls=1 in_flight=0 max_in_flight=1 "
rc=0; ( SCALE_STATE="$T/w2/state"; . "$DIR/tests/lib/scale.sh" || exit 9; scale_wrap sh -c 'exit 7' ) || rc=$?
eq "W2 scale_wrap returns the command's own rc" "$rc" "7"

echo "scale-fakes.bh-7906: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

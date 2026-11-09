#!/bin/bash
# tests/box-id-required-test.sh — a lane with no box identity writes NO row and
# says so once (BH-1043, audit §2.4).
#
# THE BUG. `box` is half the primary key of every row this fleet writes. A box
# whose state/box-id never landed — a machine mid-bootstrap, a restored tree, a
# checkout with no cron wiring — fell through to `hostname`, and every Orgo box
# answers the image default "orgo-desktop". So the rows landed under a name that
# is not a box, a PHANTOM appeared in every metrics table beside the real ones,
# and nothing ever said a word: the push reported success, the rows were there,
# they were just filed under a fiction that silently merges several machines.
#
# THE RULE. Identity is asserted at lane start, not guessed at row-write time.
# bin/lib/box-id.sh resolves $BOX_ID, then state/box-id — and NOTHING else. No
# id means the lane writes nothing and appends exactly one ALERTS line per lane
# per day, so an unprovisioned box is loud once instead of wrong forever.
#
# Everything below drives the REAL bin/cost-rows-push.sh (the highest-volume row
# writer in the fleet) and the REAL bin/lib/box-id.sh against a scratch tree and
# a curl that RECORDS every request, so "wrote no row" is measured on the wire.
#
# Sections:
#   A  no box-id: no request leaves the box, and exactly one ALERT
#   B  the alert is once per lane per day, not once per tick
#   C  with state/box-id the lane pushes normally, under the id from the file
#   D  an explicit id (argv / --box) is identity too: the pool path is unaffected
#   E  the hostname is never identity — not even as a last resort
#   F  bootstrap writes state/box-id before anything can write a row
#   G  the pool's account-label overlay lands before the machine's job does
#
# Run from anywhere: tests/box-id-required-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: this suite asserts the POST to its own stub; the sandbox flag would refuse it.
unset HARNESS_TEST_SANDBOX
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$T/fakebin"
cp "$DIR/bin/cost-rows-push.sh" "$H/bin/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/box-id.sh" "$H/bin/lib/" 2>/dev/null || true
# A REAL BOX HAS BOTH LIBRARIES, so the fixture does too (BH-1032 rebase).
# bin/cost-rows-push.sh resolves through bin/lib/cost-row.sh's
# cost_row_box_id — the same resolver the at-source writer files its row
# under — and that function reaches box_id_get. Without this copy the lane
# under test skipped that hop entirely, so E below could not see a hostname
# fallback reintroduced one file over.
cp "$DIR/bin/lib/cost-row.sh" "$H/bin/lib/" 2>/dev/null || true
chmod +x "$H/bin/cost-rows-push.sh"
: > "$H/env/global.env"

REQ="$T/requests.log"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2 ;;
    -H) shift 2 ;;
    -H*|-sS|-s) shift ;;
    -m|--connect-timeout|-w) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s %s\n' "$METHOD" "${URL#*workers.dev}" "$BODY" >> "$REQ"
printf '{"inserted":1,"rows":1}\n200'
CURL
chmod +x "$T/fakebin/curl"
# The hostname a real Orgo box answers: if this string ever reaches a row or a
# request, identity was guessed.
cat > "$T/fakebin/hostname" <<'HN'
#!/bin/bash
echo orgo-desktop
HN
chmod +x "$T/fakebin/hostname"

# A cost.csv with one data row in the shape metric_cost_rows reads.
seed_csv() {
  cat > "$H/logs/cost.csv" <<'CSV'
ts,host,project,ticket,stage,runner,model,input_tokens,output_tokens,cache_read,cache_write,cost_usd,rc
2026-09-19T10:00:00Z,box,proj,TK-1,execute,claude,claude-opus-5,100,10,0,0,0.12,0
CSV
  rm -f "$H/state/cost-rows-push.cursor"
}

push() { # push [args...] — the real script, with every request recorded
  env PATH="$T/fakebin:$PATH" HARNESS="$H" REQ="$REQ" HARNESS_SECRET=test-secret \
      JOBS_URL=https://harness-jobs.operator.workers.dev \
    bash "$H/bin/cost-rows-push.sh" "$@" 2>&1
}
# `grep -c` prints 0 AND exits 1 when it matches nothing, so a `|| echo 0`
# fallback prints TWO zeros and every comparison below would be against "0\n0".
alerts() { local n; n=$(grep -c 'box-id' "$H/logs/ALERTS.log" 2>/dev/null); printf '%s\n' "${n:-0}"; }
reqs()   { local n; n=$(grep -c '' "$REQ" 2>/dev/null); printf '%s\n' "${n:-0}"; }

# =============================================================================
# A. NO BOX-ID — NO REQUEST, AND EXACTLY ONE ALERT
# =============================================================================
rm -f "$H/state/box-id" "$H/logs/ALERTS.log"
rm -f "$H/flags"/alerted-box-id-* 2>/dev/null
: > "$REQ"
seed_csv
OUT=$(push)
[ "$(reqs)" = 0 ] \
  && ok || bad "A: a box with no identity still wrote rows: $(cat "$REQ")"
[ "$(alerts)" = 1 ] \
  && ok || bad "A: expected exactly one box-id ALERT, got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'state/box-id' "$H/logs/ALERTS.log" \
  && ok || bad "A: the alert does not name the file an operator must write: $(cat "$H/logs/ALERTS.log")"
grep -qi 'orgo-desktop' "$H/logs/ALERTS.log" \
  && bad "A: the alert quotes the hostname as if it were a usable identity" || ok
# The cursor must not move: the rows are still owed, not lost.
[ ! -s "$H/state/cost-rows-push.cursor" ] \
  && ok || bad "A: the cursor advanced over rows that were never sent"

# =============================================================================
# B. ONCE PER LANE PER DAY, NOT ONCE PER TICK
# =============================================================================
for _ in 1 2 3 4; do push >/dev/null 2>&1; done
[ "$(alerts)" = 1 ] \
  && ok || bad "B: five ticks produced $(alerts) alerts — the dedupe flag is not holding"
[ "$(reqs)" = 0 ] \
  && ok || bad "B: a later tick wrote rows without an identity: $(cat "$REQ")"

# =============================================================================
# C. WITH state/box-id THE LANE PUSHES NORMALLY
# =============================================================================
printf 'box-project-4-1\n' > "$H/state/box-id"
: > "$REQ"; : > "$H/logs/ALERTS.log"
seed_csv
push >/dev/null 2>&1
[ "$(reqs)" -ge 1 ] \
  && ok || bad "C: a box WITH an identity pushed nothing"
grep -q 'box-project-4-1' "$REQ" \
  && ok || bad "C: the rows did not go out under the id from state/box-id: $(cat "$REQ")"
[ "$(alerts)" = 0 ] \
  && ok || bad "C: a healthy box alerted about its identity"

# =============================================================================
# D. AN EXPLICIT ID IS IDENTITY TOO (the pool path is unaffected)
# =============================================================================
# fly/builder-runner.sh and the hub reap both pass `--box pool-<project>-<machine>`
# on a machine that has no state/box-id at all. That is a DECLARED identity, not
# a guess, and it must keep working.
rm -f "$H/state/box-id"
: > "$REQ"; : > "$H/logs/ALERTS.log"
seed_csv
OUT=$(push --box pool-project-4-m1234567890)
grep -q 'pool-project-4-m1234567890' "$REQ" \
  && ok || bad "D: an explicit --box id was refused: $OUT / $(cat "$REQ")"
[ "$(alerts)" = 0 ] \
  && ok || bad "D: an explicit id alerted anyway: $(cat "$H/logs/ALERTS.log")"
: > "$REQ"; seed_csv
push box-project-3-1 >/dev/null 2>&1
grep -q 'box-project-3-1' "$REQ" \
  && ok || bad "D: the argv id (the cron shape) was refused: $(cat "$REQ")"

# =============================================================================
# E. THE HOSTNAME IS NEVER IDENTITY
# =============================================================================
rm -f "$H/state/box-id"; : > "$REQ"; : > "$H/logs/ALERTS.log"
rm -f "$H/flags"/alerted-box-id-* 2>/dev/null
seed_csv
push >/dev/null 2>&1
grep -q 'orgo-desktop' "$REQ" \
  && bad "E: rows went out under the image-default hostname: $(cat "$REQ")" || ok
grep -q '$(hostname' "$H/bin/lib/box-id.sh" 2>/dev/null \
  && bad "E: bin/lib/box-id.sh still calls hostname" || ok

# The library's own contract, driven directly: rc 1 and no output with no id,
# rc 0 and the id with one.
boxid() { # boxid <lane> [extra env...]
  local L="$1"; shift
  env PATH="$T/fakebin:$PATH" HARNESS="$H" "$@" \
    bash -c '. "$1/bin/lib/box-id.sh"; box_id_require "$2"; echo "rc=$?"' _ "$H" "$L" 2>&1
}
OUT=$(boxid probe)
grep -q 'rc=1' <<<"$OUT" && ok || bad "E: box_id_require with no id did not return 1: $OUT"
grep -q 'orgo-desktop' <<<"$OUT" && bad "E: box_id_require printed the hostname" || ok
printf 'box-project-4-1\n' > "$H/state/box-id"
OUT=$(boxid probe)
grep -q '^box-project-4-1' <<<"$OUT" && ok || bad "E: box_id_require did not print the id: $OUT"
grep -q 'rc=0' <<<"$OUT" && ok || bad "E: box_id_require with an id did not return 0: $OUT"
# $BOX_ID overrides the file, so a lane can declare its own identity.
OUT=$(boxid probe BOX_ID=pool-project-3-m42)
grep -q '^pool-project-3-m42' <<<"$OUT" && ok || bad "E: \$BOX_ID did not override the file: $OUT"

# =============================================================================
# F. BOOTSTRAP WRITES state/box-id BEFORE ANYTHING CAN WRITE A ROW
# =============================================================================
# The id has to exist before the first lane runs, or A is the permanent state of
# a fresh machine. bin/bootstrap-machine.sh writes it in its own `== identity ==`
# step, and that step comes before the sync that installs the cron lanes.
BS="$DIR/bin/bootstrap-machine.sh"
IDLINE=$(grep -n 'state/box-id' "$BS" | head -1 | cut -d: -f1)
[ -n "$IDLINE" ] && ok || bad "F: bin/bootstrap-machine.sh never writes state/box-id"
CRONLINE=$(grep -n 'crontab -l 2>/dev/null' "$BS" | head -1 | cut -d: -f1)
if [ -n "$IDLINE" ] && [ -n "$CRONLINE" ]; then
  [ "$IDLINE" -lt "$CRONLINE" ] \
    && ok || bad "F: box-id is written at line $IDLINE, AFTER the cron wiring at line $CRONLINE"
else
  ok
fi

# =============================================================================
# G. THE POOL'S ACCOUNT-LABEL OVERLAY LANDS BEFORE THE MACHINE'S JOB
# =============================================================================
# The third no-twin in the audit: a pool machine spawned before its fp->label
# overlay writes cost_rows.auth_account=unknown. The overlay is pushed by
# bin/fly-pool.sh, and it only helps if it is on the machine before the job file
# that starts the build.
FP="$DIR/bin/fly-pool.sh"
OVL=$(grep -n '/data/harness/state/auth-accounts.local.json' "$FP" | head -1 | cut -d: -f1)
JOB=$(grep -nE 'mput "\$MID" "\$JF(PUSH)?" /run/harness/job.json' "$FP" | head -1 | cut -d: -f1)
[ -n "$OVL" ] && [ -n "$JOB" ] \
  && ok || bad "G: could not find the overlay push ($OVL) or the job push ($JOB) in bin/fly-pool.sh"
if [ -n "$OVL" ] && [ -n "$JOB" ]; then
  [ "$OVL" -lt "$JOB" ] \
    && ok || bad "G: the overlay is pushed at line $OVL, after the job at line $JOB — the first cost rows land unlabelled"
fi

echo "box-id-required: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

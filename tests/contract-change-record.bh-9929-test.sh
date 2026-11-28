#!/bin/bash
# tests/contract-change-record.bh-9929-test.sh — cc_record, the write of one
# contract-change step row (BH-9929, bin/lib/contract-change-record.sh).
#
# Sources the REAL lib. The one edge stubbed is bin/jobs-client.sh: a scratch
# $HARNESS holds a stub whose _jobs_req records the method, the path and the
# body, and answers per $FIX/mode. gh and curl on PATH fail, so the suite makes
# 0 network calls.
#
#   R1 a full call POSTs one JSON body to /api/contract-changes with project,
#      parent_ticket as a number, step and every key given; rc 0
#   R2 an empty value (`backup_ref=`) is not sent; a later call with only
#      verdict and approved_by sends only those keys
#   R3 a failed POST (rc 1) and a 200 with no row are rc 1, with ONE line in
#      $BUILD/pipeline.log, and the caller's shell goes on (no exit)
#   R4 without BUILD the one failure line goes to stderr
#   R5 a bad step, a bad ticket, a bad project or an unknown key is rc 1 and
#      makes no request
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/contract-change-record.bh-9929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

HARNESS="$T/h"; FIX="$T/fix"
mkdir -p "$HARNESS/bin/lib" "$FIX" "$T/build"
export HARNESS FIX
cat > "$HARNESS/bin/jobs-client.sh" <<'JC'
# stub jobs client (BH-9929 test): records each request, answers per $FIX/mode
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FIX/calls"
  printf '%s\n' "${3:-}" >> "$FIX/bodies"
  case "$(cat "$FIX/mode" 2>/dev/null)" in
    fail) return 1 ;;
    norow) printf '{"error":"x"}'; return 0 ;;
    *) printf '{"row":{"id":7}}'; return 0 ;;
  esac
}
JC
# shellcheck source=bin/lib/contract-change-record.sh
. "$DIR/bin/lib/contract-change-record.sh" || { echo "FAIL: cannot source the lib"; exit 1; }

reset() { : > "$FIX/calls"; : > "$FIX/bodies"; printf '%s' "${1:-ok}" > "$FIX/mode"; : > "$T/build/pipeline.log"; }
ncalls() { grep -c . "$FIX/calls" 2>/dev/null || true; }

# ---- R1 ----
reset ok
BUILD="$T/build" cc_record project-6-os 41 contract pr_url=https://github.com/example-org/project-6/pull/9 \
  head_sha=abc1234 classes=drop-column backup_ref='branch mk-pre-41' restore_ref='scratch rc 0'
rc=$?
[ "$rc" = 0 ] && ok || bad "R1 rc $rc, want 0"
[ "$(cat "$FIX/calls")" = "POST /api/contract-changes" ] && ok || bad "R1 calls: $(cat "$FIX/calls")"
want='{"backup_ref":"branch mk-pre-41","classes":"drop-column","head_sha":"abc1234","parent_ticket":41,"pr_url":"https://github.com/example-org/project-6/pull/9","project":"project-6-os","restore_ref":"scratch rc 0","step":"contract"}'
got=$(jq -cS . "$FIX/bodies" 2>/dev/null)
[ "$got" = "$want" ] && ok || bad "R1 body: $got"
[ "$(jq -r '.parent_ticket | type' "$FIX/bodies")" = number ] && ok || bad "R1 parent_ticket is not a number"
[ ! -s "$T/build/pipeline.log" ] && ok || bad "R1 logged on success: $(cat "$T/build/pipeline.log")"

# ---- R2 ----
reset ok
cc_record project-6-os 41 contract backup_ref= verdict=MERGE approved_by=operator; rc=$?
[ "$rc" = 0 ] && ok || bad "R2 rc $rc"
got=$(jq -cS . "$FIX/bodies" 2>/dev/null)
[ "$got" = '{"approved_by":"operator","parent_ticket":41,"project":"project-6-os","step":"contract","verdict":"MERGE"}' ] \
  && ok || bad "R2 body: $got"

# ---- R3 ----
for mode in fail norow; do
  reset "$mode"
  out=$(BUILD="$T/build" cc_record project-3 7 expand pr_url=https://github.com/o/r/pull/1 2>&1); rc=$?
  [ "$rc" = 1 ] && ok || bad "R3 $mode rc $rc, want 1"
  [ -z "$out" ] && ok || bad "R3 $mode wrote to the terminal with BUILD set: $out"
  n=$(grep -c . "$T/build/pipeline.log")
  [ "$n" = 1 ] && ok || bad "R3 $mode pipeline.log lines $n, want 1"
  grep -q 'contract-change: record failed: project-3 #7 expand: POST /api/contract-changes' "$T/build/pipeline.log" \
    && ok || bad "R3 $mode line: $(cat "$T/build/pipeline.log")"
done
# The caller's shell goes on after a failure (no exit).
reset fail
( cc_record project-3 7 expand 2>/dev/null; echo "after rc=$?" ) > "$T/after" 2>&1
[ "$(cat "$T/after")" = "after rc=1" ] && ok || bad "R3 the caller did not go on: $(cat "$T/after")"

# ---- R4 ----
reset fail
err=$(env -u BUILD bash -c '. "$1"; . "$2"; cc_record project-3 7 migrate' _ "$HARNESS/bin/jobs-client.sh" "$DIR/bin/lib/contract-change-record.sh" 2>&1 >/dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "R4 rc $rc"
[ "$(printf '%s\n' "$err" | grep -c 'record failed')" = 1 ] && ok || bad "R4 stderr: $err"
[ ! -s "$T/build/pipeline.log" ] && ok || bad "R4 wrote pipeline.log without BUILD"

# ---- R5 ----
for args in "project-3 7 drop" "project-3 0 expand" "project-3 x7 expand" "project-3 7 expand" " 7 expand" "project-3 7 expand nope=1" "project-3 7 expand verdict"; do
  reset ok
  # shellcheck disable=SC2086
  cc_record $args 2>/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "R5 '$args' rc $rc, want 1"
  [ "$(ncalls)" = 0 ] && ok || bad "R5 '$args' made a request"
done

printf 'contract-change-record: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

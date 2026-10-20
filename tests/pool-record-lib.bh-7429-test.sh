#!/bin/bash
# tests/pool-record-lib.bh-7429-test.sh — BH-7429 (BH-6896 S2): the build
# record a pool machine posts to the jobs API, and the hub reader for it
# (bin/lib/pool-record.sh). The writer is driven through a fixture
# _jobs_req_file that keeps the body it was handed; the reader through a
# fixture _jobs_req that serves a GET answer of the worker's shape. Then the
# runner's own pool_record_write and run_job, lifted out of
# fly/builder-runner.sh, prove a pool job posts its record after it finishes.
#   L1-L4 writer   L6-L13 reader   L14 the file list pin   E1-E4 knob
#   W1-W6 the runner hook (W5 BUILD_DIR line, W6 the newest dir: L5)
#   N the node suites: the route rules and the round trip
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/pool-record.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB does not exist"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$T/settings" "$T/tmp"
scratch_install_closure fly/builder-runner.sh "$H" >/dev/null || { echo "FAIL: cannot install the runner closure"; exit 1; }
cp "$DIR/bin/result-prefix-ok.sh" "$H/bin/" && chmod +x "$H/bin/result-prefix-ok.sh"
# The jobs client, for setting-get only: the value is $T/settings/<key>, a
# missing file is the 404 answer (rc 2), $T/settings/_down makes every read rc 1.
cat > "$H/bin/jobs-client.sh" <<JC
#!/bin/bash
[ "\$1" = setting-get ] || exit 1
echo "\$2" >> "$T/settings/reads"
[ -e "$T/settings/_down" ] && exit 1
[ -f "$T/settings/\$2" ] || exit 2
cat "$T/settings/\$2"; echo
JC
chmod +x "$H/bin/jobs-client.sh"
export HARNESS="$H" TMPDIR="$T/tmp"
# The retry backoff (BH-7429): no real sleeping in this suite.
export POOL_RECORD_BACKOFF_S=0

# The fixture transport. A POST body is copied to $T/posted/<n>.json; the
# rc is $T/post-rc. A GET prints $T/get-answer with rc $T/get-rc; every path
# goes to $T/calls.
_jobs_req_file() {
  echo "$1 $2" >> "$LIBFIX/calls"
  mkdir -p "$LIBFIX/posted"; cp "$3" "$LIBFIX/posted/$(ls "$LIBFIX/posted" | wc -l).json"
  # $T/post-rc-seq (one rc per line) answers the first POST with its first
  # line, the next with its second, and so on; past the end, or absent: post-rc.
  local seq="$LIBFIX/post-rc-seq" n; n=$(grep -c '^POST' "$LIBFIX/calls")
  [ -s "$seq" ] && [ "$n" -le "$(wc -l < "$seq")" ] && return "$(sed -n "${n}p" "$seq")"
  return "$(cat "$LIBFIX/post-rc" 2>/dev/null || echo 0)"
}
_jobs_req() {
  echo "$1 $2${3:+ $3}" >> "$LIBFIX/calls"
  local rc; rc=$(cat "$LIBFIX/get-rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] && [ "$1" = GET ] && cat "$LIBFIX/get-answer"
  return "$rc"
}
export LIBFIX="$T"
export -f _jobs_req_file _jobs_req
# shellcheck source=bin/lib/pool-record.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

reset() { rm -rf "$T/posted" "$T/calls" "$T/post-rc-seq" "$T/post-rc" "$T/get-rc" "$T/get-answer" "$T/stage" "$T/settings"/*; : > "$T/calls"; }
body() { cat "$T/posted/0.json"; }
file_b64() { body | jq -r --arg n "$1" '.files[] | select(.name==$n) | .b64 // empty'; }

# A build dir the way run-build.sh leaves one.
BD="$T/m/data/harness/builds/project-5-BH-9-202610191500"
mkdir -p "$BD" "$T/m/data/harness/logs"
printf '# plan\nline two\n' > "$BD/plan.md"
printf 'VERDICT: APPROVE\n' > "$BD/review.md"
printf 'E2E: PASS\n' > "$BD/e2e.md"
printf 'abc123\n' > "$BD/reviewed-sha"
printf 'not a record file\n' > "$BD/scratch-notes.txt"
head -c 200000 /dev/zero | tr '\0' 'f' > "$T/m/data/harness/logs/failovers.log"
printf '\ntail-marker\n' >> "$T/m/data/harness/logs/failovers.log"
RF="$T/m/RESULT"
printf 'PR_CREATED https://github.com/o/r/pull/9\nTIER: 2\nBUILD_DIR: /data/harness/builds/project-5-BH-9-202610191500\n' > "$RF"

# ── L14 the file list is the 27 names the reap pulled before BH-7429 ───────
WANT="plan.md review.md security-review.md security-review-run.txt refute-review.md merged-review2.md harness-suite-fix.txt qa.md e2e.md evidence.md changed-files.txt reviewed-sha headbound-outcome headbound-review.md headbound-review-run.txt harness-suite-head.txt pipeline.log cost.csv validate.txt red.txt green.txt mutation-check.txt context.json gh-stderr.log execute-transcript.md stop-reason.txt ticket-meta.json"
[ "${POOL_RECORD_FILES[*]:-}" = "$WANT" ] && ok || bad "L14 POOL_RECORD_FILES drifted: ${POOL_RECORD_FILES[*]:-<unset>}"
[ "${#POOL_RECORD_FILES[@]}" = 27 ] && ok || bad "L14 count ${#POOL_RECORD_FILES[@]}"
# L14b the hub's ssh pull in bin/fly-pool.sh names the same files in the same order
SSHLIST=$(awk '/^      for A in plan\.md /{f=1} f{print} f&&/; do$/{exit}' "$DIR/bin/fly-pool.sh" \
  | sed -e 's/^      for A in //' -e 's/; do$//' -e 's/\\$//' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')
[ "$SSHLIST" = "$WANT" ] && ok || bad "L14b the ssh pull list in bin/fly-pool.sh drifted from POOL_RECORD_FILES: $SSHLIST"

# ── L1 the body: RESULT, every present listed file, the failovers tail ─────
reset
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "$T/m/data/harness/logs/failovers.log"; RC=$?
[ "$RC" = 0 ] && ok || bad "L1 put rc=$RC"
grep -q '^POST /api/pool/records$' "$T/calls" && ok || bad "L1 calls: $(cat "$T/calls")"
[ "$(body | jq -r '[.project,.key,.machine,.build_dir]|join(" ")')" = "project-5 BH-9 m1 project-5-BH-9-202610191500" ] \
  && ok || bad "L1 header fields: $(body | jq -c 'del(.files)')"
[ "$(body | jq -r '[.files[].name]|sort|join(" ")')" = "RESULT e2e.md failovers.log plan.md review.md reviewed-sha" ] \
  && ok || bad "L1 file names: $(body | jq -c '[.files[].name]')"
[ "$(file_b64 RESULT | base64 -d)" = "$(cat "$RF")" ] && ok || bad "L1 RESULT body"
[ "$(file_b64 plan.md | base64 -d | od -An -c | tr -d ' \n')" = "$(od -An -c < "$BD/plan.md" | tr -d ' \n')" ] && ok || bad "L1 plan.md body"
FOB=$(file_b64 failovers.log | base64 -d | wc -c)
[ "$FOB" = 65536 ] && ok || bad "L1 failovers.log tail is $FOB bytes, want 65536"
[ "$(file_b64 failovers.log | base64 -d | tail -1)" = tail-marker ] && ok || bad "L1 failovers.log is not the tail"
[ -z "$(file_b64 scratch-notes.txt)" ] && ok || bad "L1 a file outside the list was posted"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "L1 temp files left behind: $(ls -A "$T/tmp")"

# ── L2 a missing file is omitted (security-review.md is absent above) ──────
body | jq -e '[.files[].name] | index("security-review.md") == null' >/dev/null && ok || bad "L2 an absent file was posted"

# ── L3 a file over the cap goes as {name, skipped, bytes} ──────────────────
reset
POOL_RECORD_FILE_MAX_BYTES=12 pool_record_put project-5 BH-9 m1 "$RF" "$BD" "$T/m/data/harness/logs/failovers.log" >/dev/null 2>&1
# RESULT itself is over 12 bytes: no record can be built, nothing is posted.
[ ! -e "$T/posted" ] && ok || bad "L3 a RESULT over the cap was posted"
reset
POOL_RECORD_FILE_MAX_BYTES=200 pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "L3 put rc=$RC"
S=$(body | jq -r '.files[] | select(.name=="plan.md") | [.b64, (.skipped // false)] | map(tostring) | join(" ")')
[ "$S" = "IyBwbGFuCmxpbmUgdHdvCg== false" ] && ok || bad "L3 a small file: $S"
printf '%0300d\n' 0 > "$BD/validate.txt"
reset
POOL_RECORD_FILE_MAX_BYTES=200 pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null 2>&1
S=$(body | jq -r '.files[] | select(.name=="validate.txt") | [.skipped, .bytes, (.b64 // "no-body")] | map(tostring) | join(" ")')
[ "$S" = "true 301 no-body" ] && ok || bad "L3 the big file: $S"
body | jq -e '[.files[].name] | index("failovers.log") == null' >/dev/null && ok || bad "L3 no failovers path: failovers.log was posted"
rm -f "$BD/validate.txt"

# ── L4 a refused or failed post: rc 9 / rc 1, nothing left on disk ─────────
reset; echo 9 > "$T/post-rc"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" ""; RC=$?
[ "$RC" = 9 ] && ok || bad "L4 a 409 answered rc=$RC, want 9"
reset; echo 1 > "$T/post-rc"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" ""; RC=$?
[ "$RC" = 1 ] && ok || bad "L4 an outage answered rc=$RC, want 1"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "L4 temp files left behind: $(ls -A "$T/tmp")"
reset
pool_record_put project-5 BH-9 "" "$RF" "$BD" "" && bad "L4 no machine id answered 0" || ok
pool_record_put project-5 BH-9 m1 "$T/nope" "$BD" "" && bad "L4 no RESULT answered 0" || ok
pool_record_put "a b" BH-9 m1 "$RF" "$BD" "" && bad "L4 a bad project answered 0" || ok
[ -s "$T/calls" ] && bad "L4 a put with a bad input still posted: $(cat "$T/calls")" || ok
# ── L15 the POST is tried again (BH-7429): a first POST that fails and a ───
# later one that lands is a written record, not a fallback to ssh.
posts() { grep -c '^POST' "$T/calls"; }
reset; printf '1\n0\n' > "$T/post-rc-seq"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 2 ] && ok || bad "L15 fail then ok: rc=$RC posts=$(posts) (want rc 0, 2 POSTs)"
reset; printf '1\n1\n0\n' > "$T/post-rc-seq"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(posts)" = 3 ] && ok || bad "L15 fail, fail, ok: rc=$RC posts=$(posts) (want rc 0, 3 POSTs)"
reset; echo 1 > "$T/post-rc"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null; RC=$?
[ "$RC" = 1 ] && [ "$(posts)" = 3 ] && ok || bad "L15 outage: rc=$RC posts=$(posts) (want rc 1 after 3 POSTs)"
# ── L16 a 409 already_reaped is final: one POST, rc 9 ───────────────────────
reset; printf '9\n0\n' > "$T/post-rc-seq"
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "" >/dev/null; RC=$?
[ "$RC" = 9 ] && [ "$(posts)" = 1 ] && ok || bad "L16 a 409 was retried: rc=$RC posts=$(posts) (want rc 9, 1 POST)"
# ── L17 the worst case stays inside the runner's 600 s idle window ─────────
( unset POOL_RECORD_BACKOFF_S
  budget=$(pool_record_post_budget_s) && [ "$budget" -lt 600 ] ) && ok || bad "L17 the default POST budget is not under 600 s"
# No build dir at all (a deferral before run-build made one): RESULT only,
# build_dir "none".
reset
pool_record_put project-5 BH-9 m1 "$RF" "" "" >/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(body | jq -r '.build_dir + " " + ([.files[].name]|join(","))')" = "none RESULT" ] \
  && ok || bad "L4 no build dir: rc=$RC $(body | jq -c 'del(.files[].b64)')"

# ── the reader ──────────────────────────────────────────────────────────────
# The GET answer, built from the body the real writer posted above, in the
# worker's GET shape (worker/jobs/src/routes/pool-records.js).
SPAT="2026-10-19 15:00:00Z"
reset
pool_record_put project-5 BH-9 m1 "$RF" "$BD" "$T/m/data/harness/logs/failovers.log" >/dev/null
cp "$T/posted/0.json" "$T/written.json"
answer() { # answer [jq filter applied to the record]
  jq -c --arg m "${ANS_MACHINE:-m1}" '{record:{build_dir, machine:$m, posted_at:"2026-10-19T15:10:00Z",
    files:[.files[] | {name, body:(.b64 // null), bytes:(.bytes // ((.b64|length)/4*3|floor)), skipped:(if .skipped then 1 else 0 end)}]}}' \
    "$T/written.json" | jq -c "${1:-.}" > "$T/get-answer"
}

# L6 rc 0: every file written byte for byte; prints build_dir and the skipped names
reset; answer
OUT=$(pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage"); RC=$?
[ "$RC" = 0 ] && ok || bad "L6 get rc=$RC"
[ "$OUT" = "project-5-BH-9-202610191500	" ] && ok || bad "L6 printed '$OUT'"
for f in plan.md review.md e2e.md reviewed-sha; do
  cmp -s "$BD/$f" "$T/stage/$f" && ok || bad "L6 $f differs"
done
cmp -s "$RF" "$T/stage/RESULT" && ok || bad "L6 RESULT differs"
cmp -s <(tail -c 65536 "$T/m/data/harness/logs/failovers.log") "$T/stage/failovers.log" && ok || bad "L6 failovers.log differs"
[ "$(ls "$T/stage" | wc -l)" = 6 ] && ok || bad "L6 stage holds: $(ls "$T/stage" | tr '\n' ' ')"
# since = spawned_at less 60 s, ISO.
grep -qx 'GET /api/pool/records?project=project-5&key=BH-9&machine=m1&since=2026-10-19T14:59:00Z' "$T/calls" \
  && ok || bad "L6 request: $(cat "$T/calls")"
# A skipped file is named, not written.
reset; answer '.record.files += [{name:"pipeline.log",body:null,bytes:2000000,skipped:1}]'
OUT=$(pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "project-5-BH-9-202610191500	pipeline.log" ] && [ ! -e "$T/stage/pipeline.log" ] \
  && ok || bad "L6 skipped: rc=$RC out='$OUT'"

# L7 a 404 is rc 2, no stage dir
reset; echo 2 > "$T/get-rc"
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/stage" ] && ok || bad "L7 rc=$RC stage=$(ls -d "$T/stage" 2>/dev/null)"

# L8 another machine's record is rc 2
reset; ANS_MACHINE=m2 answer
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/stage" ] && ok || bad "L8 rc=$RC"

# L9 a RESULT whose line 1 is ssh noise is rc 2; a record with no RESULT too
reset; answer "(.record.files[] | select(.name==\"RESULT\") | .body) = \"$(printf 'Oops goroutine 1 [running]:\n' | base64 -w0)\""
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/stage" ] && ok || bad "L9 noise rc=$RC"
reset; answer '.record.files |= map(select(.name!="RESULT"))'
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/stage" ] && ok || bad "L9 no RESULT rc=$RC"
reset; answer '(.record.files[] | select(.name=="RESULT")) |= (.body=null | .skipped=1)'
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "L9 skipped RESULT rc=$RC"

# L10 a name off the list, or with a path in it, is never written; the rest is
reset; answer ".record.files += [{name:\"../x\",body:\"$(printf 'pwned\n' | base64 -w0)\",bytes:6,skipped:0},{name:\"evil.sh\",body:\"$(printf 'rm -rf /\n' | base64 -w0)\",bytes:9,skipped:0}]"
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "L10 rc=$RC"
[ ! -e "$T/x" ] && [ ! -e "$T/stage/evil.sh" ] && ok || bad "L10 an off-list file was written"
[ -s "$T/stage/plan.md" ] && ok || bad "L10 the listed files were not written"

# L11 a body that does not decode is rc 1 and leaves no stage dir
reset; answer '(.record.files[] | select(.name=="plan.md") | .body) = "not*base64!"'
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/stage" ] && ok || bad "L11 rc=$RC stage=$(ls "$T/stage" 2>/dev/null | tr '\n' ' ')"
reset; echo 'not json' > "$T/get-answer"
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/stage" ] && ok || bad "L11 bad JSON rc=$RC"

# L12 a spawned_at not in STAMP or ISO shape is rc 1 and makes no request
for bad_at in "" "2026-10-19T15:45:00+00:00" "yesterday" "1760886000"; do
  reset; answer
  pool_record_get project-5 BH-9 m1 "$bad_at" "$T/stage" >/dev/null; RC=$?
  [ "$RC" = 1 ] && [ ! -s "$T/calls" ] && ok || bad "L12 spawned_at='$bad_at' rc=$RC calls=$(cat "$T/calls")"
done
reset; answer
pool_record_get project-5 BH-9 m1 "2026-10-19T15:00:00Z" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "L12 the ISO shape is accepted: rc=$RC"

# L13 the worker is down: rc 1
reset; echo 1 > "$T/get-rc"
pool_record_get project-5 BH-9 m1 "$SPAT" "$T/stage" >/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/stage" ] && ok || bad "L13 rc=$RC"

# The stamp: one POST with the record's identity; its rc is passed through.
reset
pool_record_reaped project-5 BH-9 m1 project-5-BH-9-202610191500; RC=$?
[ "$RC" = 0 ] && grep -q '^POST /api/pool/records/reaped {"project":"project-5","key":"BH-9","machine":"m1","build_dir":"project-5-BH-9-202610191500"}$' "$T/calls" \
  && ok || bad "stamp rc=$RC calls=$(cat "$T/calls")"
reset; echo 1 > "$T/get-rc"
pool_record_reaped project-5 BH-9 m1 project-5-BH-9-202610191500 && bad "a failed stamp answered 0" || ok

# ── E1-E4 the knob, as the machine reads it ────────────────────────────────
reset
[ "$(pool_record_enabled project-6-os)" = 0 ] && ok || bad "E1 no rows must read 0"
reset; echo 1 > "$T/settings/lane.fly-pool.project-6-os.pool_record_read"
[ "$(pool_record_enabled project-6-os)" = 1 ] && ok || bad "E2 project row 1 must read 1"
reset; echo 1 > "$T/settings/lane.fly-pool.pool_record_read"
[ "$(pool_record_enabled project-5)" = 1 ] && ok || bad "E3 the lane-wide row 1 must read 1"
echo 0 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
[ "$(pool_record_enabled project-5)" = 0 ] && ok || bad "E3 a project row 0 must win over the lane row 1"
reset; echo 1 > "$T/settings/lane.fly-pool.project-6-os.pool_record_read"; : > "$T/settings/_down"
[ "$(pool_record_enabled project-6-os)" = 0 ] && ok || bad "E4 an unreadable setting must read 0"
rm -f "$T/settings/_down"

# ── W1-W6 the runner: pool_record_write and run_job, lifted ────────────────
mkdir -p "$T/drv" "$H/builds" "$H/logs"
awk '/^pool_record_write\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/drv/write.sh"
awk '/^run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/drv/runjob.sh"
grep -q 'pool_record_put' "$T/drv/write.sh" && grep -q 'pool_record_write' "$T/drv/runjob.sh" \
  && ok || bad "W0 could not lift pool_record_write / a run_job that calls it out of fly/builder-runner.sh"
cat > "$T/drv/main.sh" <<'MAIN'
set -uo pipefail
log() { echo "LOG: $*"; }
_run_job() { cp "$RESULT_SRC" "$RESULT_FILE"; return 0; }
pool_result_row_write() { :; }
cost_rows_flush() { :; }
. "$DRV/write.sh"
. "$DRV/runjob.sh"
run_job; echo "run_job rc=$?"
MAIN
mkdir -p "$H/builds/project-5-BH-9-202610191500" "$H/builds/project-5-BH-8-202610181500"
cp "$BD"/plan.md "$H/builds/project-5-BH-9-202610191500/"
printf 'older build\n' > "$H/builds/project-5-BH-8-202610181500/plan.md"
touch -d '2026-10-18 15:00' "$H/builds/project-5-BH-9-202610191500"
touch -d '2026-10-19 16:00' "$H/builds/project-5-BH-8-202610181500"
drive() { # drive <job-key> [env...]
  local k="$1"; shift
  jq -nc --arg k "$k" '{key:$k,ticket_id:"9"}' > "$T/job.json"
  # POOL_MODE comes from the case alone, never from the box running the suite.
  ( unset POOL_MODE
    export HARNESS="$H" PROJECT=project-5 JOB="$T/job.json" RESULT_FILE="$T/RESULT.out" RESULT_SRC="${RSRC:-$RF}" \
           FLY_MACHINE_ID=m1 DRV="$T/drv" "$@"
    bash "$T/drv/main.sh" ) 2>&1
}
reset; echo 1 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
OUT=$(drive BH-9)
[ "$OUT" = "run_job rc=0" ] && [ ! -s "$T/calls" ] && ok || bad "W1 POOL_MODE unset must not post: $OUT / $(cat "$T/calls")"
reset; echo 1 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
OUT=$(drive RB-12-abc POOL_MODE=1)
[ ! -s "$T/calls" ] && ok || bad "W2 an RB- key must not post: $(cat "$T/calls")"
reset
OUT=$(drive BH-9 POOL_MODE=1)
[ ! -s "$T/calls" ] && ok || bad "W3 knob off must not post: $(cat "$T/calls")"
reset; echo 1 > "$T/settings/lane.fly-pool.pool_record_read"; echo 0 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
OUT=$(drive BH-9 POOL_MODE=1)
[ ! -s "$T/calls" ] && ok || bad "W4 project row 0 over lane row 1 must not post: $(cat "$T/calls")"
reset; echo 1 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
OUT=$(drive BH-9 POOL_MODE=1)
[ "$OUT" = "run_job rc=0" ] && [ "$(grep -c '^POST /api/pool/records$' "$T/calls")" = 1 ] && ok || bad "W5 knob on: one post: $OUT / $(cat "$T/calls")"
# The BUILD_DIR: line wins over the newer dir on disk.
[ "$(body | jq -r .build_dir)" = project-5-BH-9-202610191500 ] && [ "$(file_b64 plan.md | base64 -d)" = "$(cat "$BD/plan.md")" ] \
  && ok || bad "W5 build dir: $(body | jq -r .build_dir)"
# L5 / W6: no BUILD_DIR: line -> the newest build dir.
printf 'BUILD_ERROR x\n' > "$T/RESULT.nobd"
reset; echo 1 > "$T/settings/lane.fly-pool.project-5.pool_record_read"
OUT=$(RSRC="$T/RESULT.nobd" drive BH-9 POOL_MODE=1)
[ "$(body | jq -r .build_dir)" = project-5-BH-8-202610181500 ] && ok || bad "W6 newest dir: $(body | jq -r .build_dir 2>/dev/null)"
# A failed post is one log line, and the job's rc stays.
reset; echo 1 > "$T/settings/lane.fly-pool.project-5.pool_record_read"; echo 1 > "$T/post-rc"
OUT=$(drive BH-9 POOL_MODE=1)
grep -q '^LOG: build record for BH-9 not posted' <<<"$OUT" && grep -qx 'run_job rc=0' <<<"$OUT" \
  && ok || bad "W5 a failed post: $OUT"

# ── N the worker side: the route rules and the bash -> worker -> bash round trip
ROUTE="$DIR/worker/jobs/src/routes/pool-records.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-7429-pool-records.txt"
[ -r "$ROUTE" ] && [ -r "$FRAG" ] && ok || bad "N the route $ROUTE or its fragment is missing"
if command -v node >/dev/null 2>&1 && node -e "import('node:sqlite').then(()=>process.exit(0),()=>process.exit(3))" 2>/dev/null; then
  ( cd "$DIR/worker/jobs" && node --test "$DIR/worker/jobs/test/pool-records.bh-7429.test.js" \
      "$DIR/worker/jobs/test/pool-records-roundtrip.bh-7429.test.js" > "$T/node.out" 2>&1 ) \
    && ok || bad "N node suites: $(grep -E '^not ok|^# fail|Cannot find' "$T/node.out" | head -5)"
else
  echo "  SKIP N: node:sqlite unavailable"
fi

echo "pool-record-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

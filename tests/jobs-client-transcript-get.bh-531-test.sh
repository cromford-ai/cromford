#!/bin/bash
# tests/jobs-client-transcript-get.bh-531-test.sh — the `transcript-get` verb
# added by BH-531, driven against a stubbed transport.
#
# WHY IT EXISTS. bin/jobs-client.sh could PUT a transcript and LIST the index,
# but nothing could fetch a BODY back. BH-531 needs exactly that on the watcher
# box: a build that ended PLAN_BLOCKED on a pool machine pushed its plan.md as a
# transcript row, and the box has to pull it down and write it beside the staged
# RESULT.
#
# WHAT HAS TO BE TRUE:
#   1. a hit prints the body and NOTHING else — the caller redirects stdout
#      straight into the file it is about to stage;
#   2. a miss is rc 1 with EMPTY stdout, and so is an outage: a box that wrote
#      an error page into plan.md and quoted it to a client would be worse than
#      one that wrote nothing;
#   3. `source=<kind>` resolves through the index, because the box knows the
#      kind of body it wants and not which slot it landed on;
#   4. a non-numeric address makes NO request at all — an unvalidated phase id
#      goes straight into the query string.
# Run from anywhere: tests/jobs-client-transcript-get.bh-531-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jobs-client-transcript-get.bh-531-test: SKIPPED — jq is not installed"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"

# The worker's real answers: 200 with a row, 404 on a miss. The index is ordered
# phase_id ASC, attempt ASC, exactly as worker/jobs/src/index.js serves it.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
esac
case "$URL" in
  */transcripts)
    printf '{"transcripts":[{"phase_id":0,"attempt":100,"stage":"plan","runner":"pipeline","source":"plan_md","bytes":31},{"phase_id":7,"attempt":1,"stage":"plan","runner":"claude","source":"session_jsonl","bytes":99}]}\n200\n' ;;
  */transcript\?phase_id=7\&attempt=1)
    printf '{"transcript":{"phase_id":7,"attempt":1,"body":"BODY-7-1","truncated":0}}\n200\n' ;;
  */transcript\?phase_id=0\&attempt=100)
    printf '{"transcript":{"phase_id":0,"attempt":100,"body":"PLAN BODY","truncated":1}}\n200\n' ;;
  */transcript\?*)
    printf '{"error":"no transcript for this attempt"}\n404\n' ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

CLI() { # CLI <curl-mode> <args...> — the real dispatch, as an operator runs it
  local mode="$1"; shift
  : > "$T/req.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
           REQ_SINK="$T/req.log" CURL_MODE="$mode"
    bash "$T/h/bin/jobs-client.sh" "$@" 2>/dev/null )
}
reqs() { cat "$T/req.log" 2>/dev/null; }

# ══ 1. A HIT PRINTS THE BODY, AND NOTHING ELSE ══════════════════════════════
OUT=$(CLI ok transcript-get j 7 1); RC=$?
[ "$RC" = 0 ] && ok || bad "transcript-get on a live row exited $RC"
[ "$OUT" = "BODY-7-1" ] && ok || bad "transcript-get must print exactly the body, got '$OUT'"

# ══ 2. A MISS IS rc 1 AND SILENT ════════════════════════════════════════════
OUT=$(CLI ok transcript-get j 7 9); RC=$?
[ "$RC" = 1 ] && ok || bad "an unknown attempt must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "a miss must print nothing, got '$OUT'"

OUT=$(CLI down transcript-get j 7 1); RC=$?
[ "$RC" = 1 ] && ok || bad "an unreachable worker must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "an outage must print nothing, got '$OUT'"

OUT=$(CLI err500 transcript-get j 7 1); RC=$?
[ "$RC" = 1 ] && ok || bad "a 500 must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "a 500 must print nothing, got '$OUT'"

# ══ 3. source=<kind> RESOLVES THROUGH THE INDEX ═════════════════════════════
OUT=$(CLI ok transcript-get j source=plan_md); RC=$?
[ "$RC" = 0 ] && ok || bad "transcript-get by source exited $RC"
[ "$OUT" = "PLAN BODY" ] && ok || bad "transcript-get by source must print the body, got '$OUT'"
[ "$(reqs | sed -n 1p | grep -c '/transcripts$')" = 1 ] \
  && ok || bad "the index must be read first: $(reqs)"
reqs | sed -n 2p | grep -q 'transcript?phase_id=0&attempt=100' \
  && ok || bad "the body must be fetched from the slot the index named: $(reqs)"

OUT=$(CLI ok transcript-get j source=review_md); RC=$?
[ "$RC" = 1 ] && ok || bad "a source with no row must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "a source with no row must print nothing, got '$OUT'"

OUT=$(CLI down transcript-get j source=plan_md); RC=$?
[ "$RC" = 1 ] && ok || bad "source lookup with the worker down must be rc 1, got $RC"
[ -z "$OUT" ] && ok || bad "source lookup with the worker down must print nothing, got '$OUT'"

# ══ 4. BAD ADDRESSES MAKE NO REQUEST ════════════════════════════════════════
OUT=$(CLI ok transcript-get); RC=$?
[ "$RC" = 1 ] && ok || bad "transcript-get with no job must be rc 1, got $RC"
[ -z "$(reqs)" ] && ok || bad "transcript-get with no job must not call the worker: $(reqs)"

OUT=$(CLI ok transcript-get j 7x 1); RC=$?
[ "$RC" = 1 ] && ok || bad "a non-numeric phase id must be rc 1, got $RC"
[ -z "$(reqs)" ] && ok || bad "a non-numeric phase id must make NO request: $(reqs)"

OUT=$(CLI ok transcript-get j 7 "1 OR 1"); RC=$?
[ "$RC" = 1 ] && ok || bad "a non-numeric attempt must be rc 1, got $RC"
[ -z "$(reqs)" ] && ok || bad "a non-numeric attempt must make NO request: $(reqs)"

# ══ 5. SOURCED: the truncation flag reaches the caller ══════════════════════
# The box prefixes a "tail only" line onto the staged file, and it can only know
# to do that from this variable.
OUT=$( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
              HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
              REQ_SINK="$T/req.log" CURL_MODE=ok
       . "$T/h/bin/jobs-client.sh" 2>/dev/null
       job_transcript_get_source j plan_md >/dev/null 2>&1
       printf '%s' "${JOBS_TRANSCRIPT_TRUNCATED:-unset}" )
[ "$OUT" = 1 ] && ok || bad "a truncated row must set JOBS_TRANSCRIPT_TRUNCATED=1, got '$OUT'"
OUT=$( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
              HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
              REQ_SINK="$T/req.log" CURL_MODE=ok
       . "$T/h/bin/jobs-client.sh" 2>/dev/null
       job_transcript_get j 7 1 >/dev/null 2>&1
       printf '%s' "${JOBS_TRANSCRIPT_TRUNCATED:-unset}" )
[ "$OUT" = 0 ] && ok || bad "a whole row must set JOBS_TRANSCRIPT_TRUNCATED=0, got '$OUT'"

# ══ 6. THE VERB IS DISCOVERABLE ═════════════════════════════════════════════
# An operator reads the usage string; a verb missing from it is a verb nobody
# outside this diff knows about.
USAGE=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
                  HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
           bash "$T/h/bin/jobs-client.sh" no-such-verb ) 2>&1 )
grep -q 'transcript-get <job-id>' <<<"$USAGE" \
  && ok || bad "transcript-get is missing from the usage string"

echo "jobs-client-transcript-get.bh-531-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

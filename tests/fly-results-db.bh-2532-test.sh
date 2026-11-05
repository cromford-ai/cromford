#!/bin/bash
# tests/fly-results-db.bh-2532-test.sh — a finished Fly build's RESULT reaches
# the hub through the coordination DB first, and over flyctl sftp only when the
# DB cannot give it (BH-2625, slice 3 of BH-2532).
#
# TWO HALVES, BOTH DRIVEN:
#   * THE BUILDER (fly/builder-runner.sh fly_result_put): the real function body,
#     run with the real bin/jobs-client.sh against a curl stub that records every
#     request. One PUT per build, ref = RESULT line 1 verbatim, detail under the
#     worker's 4000-char cap, truncated:true when it had to cut, and a failed PUT
#     costs one log line and nothing else. B6 pins the one call inside _run_job,
#     because the runner's forever-loop cannot be driven whole.
#   * THE HUB (bin/fly-results-ingest.sh): driven whole against a flyctl stub
#     that can fail every call. "source=db" must produce a real build dir with
#     RESULT + pipeline.log while flyctl is down; every unusable row (absent,
#     truncated, wrong key, wrong ref, unreadable, not JSON) must take the old
#     sftp path and never leave an empty dir.
# Run from anywhere: tests/fly-results-db.bh-2532-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "fly-results-db.bh-2532-test: SKIPPED — jq is not installed"; exit 0; }

# ONE CLOCK READ FOR THE WHOLE FILE (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ENQ_EPOCH=$((NOW - 600))
ENQ_ISO=$(date -u -d "@$ENQ_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')

RUNNER="$DIR/fly/builder-runner.sh"
INGEST="$DIR/bin/fly-results-ingest.sh"

# ══════════════════════════════════════════════════════════════════════════════
# THE BUILDER — fly_result_put
# ══════════════════════════════════════════════════════════════════════════════
BH="$T/bh"
mkdir -p "$BH/bin/lib/jobs" "$T/bfake" "$T/run"
cp "$DIR/bin/jobs-client.sh" "$BH/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$BH/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$BH/bin/lib/"
# The worker, as far as a PUT can tell: records method + url and the body.
cat > "$T/bfake/curl" <<'STUB'
#!/bin/bash
m=GET body=""
while [ $# -gt 1 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) body="$2"; shift ;;
  esac
  shift
done
URL="$1"
[ "${BCURL:-ok}" = down ] && exit 7
printf '%s %s\n' "$m" "$URL" >> "$BREQ"
printf '%s\n' "$body" >> "$BBODY"
printf '{"ok":true}\n200'
STUB
chmod +x "$T/bfake/curl"

FN=$(sed -n '/^fly_result_put() {$/,/^}$/p' "$RUNNER")
[ -n "$FN" ] && ok || bad "B0 fly/builder-runner.sh has no top-level fly_result_put()"

# run_put <bdir> <key>   — prints nothing; rc is the function's
run_put() {
  : > "$T/breq.txt"; : > "$T/bbody.txt"; : > "$T/runner.log"
  ( export HARNESS="$BH" JOBS_HARNESS="$BH" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=builder-project-3 JOBS_RETRIES=0 \
           BREQ="$T/breq.txt" BBODY="$T/bbody.txt" BCURL="${BCURL:-ok}" PATH="$T/bfake:$PATH"
    RESULT_FILE="$T/run/RESULT"
    log() { echo "[t] $*" >> "$T/runner.log"; }
    eval "$FN"
    fly_result_put "$1" "$2" ) >/dev/null 2>&1
}
seed_bdir() { # seed_bdir <name> <job.json>
  local b="$T/b/$1"; scratch_rm "$b"; mkdir -p "$b"
  printf '%s\n' "$2" > "$b/job.json"
  printf '[x] execute start\n[x] GATES tamper=0 repro=0 intent=0 scope=0\n[x] review done\n' > "$b/pipeline.log"
  printf 'evidence line one\nevidence line two\n' > "$b/evidence.md"
  printf 'PR_CREATED https://github.com/o/r/pull/9 | tier 2\nTIER: 2\nBUILD_DIR: %s\n' "$1" > "$T/run/RESULT"
  echo "$b"
}
det() { jq -r '.detail' "$T/bbody.txt"; }

# ── B1 one PUT, ref verbatim, detail carries the whole RESULT ────────────────
B=$(seed_bdir project-3-TK-9-m1 '{"job_id":"J42"}')
run_put "$B" TK-9; rc=$?
[ "$rc" = 0 ] && ok || bad "B1 rc must be 0, got $rc"
[ "$(cat "$T/breq.txt")" = "PUT https://jobs.invalid/api/jobs/J42/artifacts" ] \
  && ok || bad "B1 exactly one PUT on J42 expected, got: $(cat "$T/breq.txt")"
jq -e '.artifact_kind == "fly_result"' "$T/bbody.txt" >/dev/null 2>&1 \
  && ok || bad "B1 artifact_kind must be fly_result: $(cat "$T/bbody.txt")"
jq -e --arg l "$(head -1 "$T/run/RESULT")" '.artifact_ref == $l' "$T/bbody.txt" >/dev/null 2>&1 \
  && ok || bad "B1 artifact_ref must be RESULT line 1 verbatim"
det | jq -e --rawfile r "$T/run/RESULT" --rawfile e "$B/evidence.md" \
  '.result == $r and .evidence == $e and .key == "TK-9" and .build_dir == "project-3-TK-9-m1" and .truncated == false' >/dev/null 2>&1 \
  && ok || bad "B1 detail must carry result/evidence byte-equal, key, build_dir, truncated:false: $(det)"
det | jq -e '.pipeline_tail | contains("] GATES tamper=0")' >/dev/null 2>&1 \
  && ok || bad "B1 pipeline_tail must carry the GATES line"

# ── B2 a 60KB log: capped, GATES line kept, last line kept, NOT truncated ────
B=$(seed_bdir project-3-TK-9-m2 '{"job_id":"J42"}')
{ for i in $(seq 1 400); do printf '[x] filler line %04d %s\n' "$i" "$(printf '%0.sa' $(seq 1 60))"; done
  echo '[x] GATES tamper=0 repro=0 intent=4 scope=2'
  for i in $(seq 401 800); do printf '[x] filler line %04d %s\n' "$i" "$(printf '%0.sa' $(seq 1 60))"; done
  echo '[x] LAST LINE of the log'; } > "$B/pipeline.log"
[ "$(LC_ALL=C wc -c < "$B/pipeline.log")" -gt 50000 ] && ok || bad "B2 fixture must be > 50KB"
run_put "$B" TK-9
n=$(det | LC_ALL=C wc -c)
[ "$n" -le 4000 ] && ok || bad "B2 detail must be <= 4000 bytes, was $n"
det | jq -e '.pipeline_tail | contains("] GATES tamper=0 repro=0 intent=4 scope=2") and contains("LAST LINE of the log")' >/dev/null 2>&1 \
  && ok || bad "B2 tail must keep the GATES line and the log's last line"
det | jq -e '.truncated == false' >/dev/null 2>&1 \
  && ok || bad "B2 a tail shorter than the log is the design, not truncation"

# ── B3 a 5000-byte evidence.md: truncated:true, result whole ─────────────────
B=$(seed_bdir project-3-TK-9-m3 '{"job_id":"J42"}')
head -c 5000 /dev/zero | tr '\0' 'e' > "$B/evidence.md"
run_put "$B" TK-9
n=$(det | LC_ALL=C wc -c)
[ "$n" -gt 0 ] && [ "$n" -le 4000 ] && ok || bad "B3 detail must be sent and <= 4000 bytes, was $n"
det | jq -e --rawfile r "$T/run/RESULT" '.truncated == true and .result == $r' >/dev/null 2>&1 \
  && ok || bad "B3 an oversized evidence must set truncated:true and keep result whole: $(det | head -c 300)"

# ── B3b evidence fits, the GATES lines do not: tail dropped, truncated:true ──
B=$(seed_bdir project-3-TK-9-m3b '{"job_id":"J42"}')
head -c 3000 /dev/zero | tr '\0' 'e' > "$B/evidence.md"
for i in $(seq 1 40); do printf '[x] GATES tamper=0 repro=0 intent=0 scope=0 round=%02d\n' "$i"; done > "$B/pipeline.log"
run_put "$B" TK-9
n=$(det | LC_ALL=C wc -c)
[ "$n" -gt 0 ] && [ "$n" -le 4000 ] && ok || bad "B3b detail must be sent and <= 4000 bytes, was $n"
det | jq -e --rawfile e "$B/evidence.md" '.truncated == true and .pipeline_tail == "" and .evidence == $e' >/dev/null 2>&1 \
  && ok || bad "B3b GATES lines that cannot fit must set truncated:true (evidence kept): $(det | jq -c '{truncated,t:(.pipeline_tail|length),e:(.evidence|length)}' 2>/dev/null)"

# ── B4 no job id: zero requests, one log line, rc 0 ──────────────────────────
B=$(seed_bdir project-3-TK-9-m4 '{}')
run_put "$B" TK-9; rc=$?
[ "$rc" = 0 ] && ok || bad "B4 rc must be 0, got $rc"
[ ! -s "$T/breq.txt" ] && ok || bad "B4 no job id must send nothing: $(cat "$T/breq.txt")"
[ "$(grep -c 'fly_result: no job id' "$T/runner.log")" = 1 ] \
  && ok || bad "B4 exactly one 'no job id' log line expected: $(cat "$T/runner.log")"

# ── B5 worker down: rc 0, one PUT-failed line, the RESULT file untouched ─────
B=$(seed_bdir project-3-TK-9-m5 '{"job_id":"J42"}')
before=$(cksum < "$T/run/RESULT")
BCURL=down run_put "$B" TK-9; rc=$?
[ "$rc" = 0 ] && ok || bad "B5 rc must be 0 on a failed PUT, got $rc"
[ "$(grep -c 'fly_result: PUT failed' "$T/runner.log")" = 1 ] \
  && ok || bad "B5 exactly one 'PUT failed' log line expected: $(cat "$T/runner.log")"
[ "$(cksum < "$T/run/RESULT")" = "$before" ] && ok || bad "B5 the RESULT file must be unchanged"

# ── B6 the call site: inside _run_job, after the RESULT write, in the block ──
pin=$(awk '
  /^_run_job\(\) \{$/ { inf=1 }
  inf && /^\}$/ { inf=0 }
  inf && /\} > "\$RESULT_FILE"/ { w=1; next }
  inf && w && /# <<< result assemble/ { w=0 }
  inf && w && $0 !~ /^[[:space:]]*#/ && index($0, "fly_result_put \"$bdir\"") { print "found" }
' "$RUNNER")
[ "$pin" = found ] && ok || bad "B6 fly_result_put \"\$bdir\" must be called in _run_job right after the RESULT write"

# ══════════════════════════════════════════════════════════════════════════════
# THE HUB — bin/fly-results-ingest.sh driven whole
# ══════════════════════════════════════════════════════════════════════════════
HI="$T/hi"
mkdir -p "$HI/bin/lib/jobs" "$HI/env" "$HI/flags" "$HI/logs" "$HI/state/fly" "$HI/builds" "$T/fakebin"
cp "$DIR/bin/lib/builder-direct.sh" "$HI/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$HI/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$HI/bin/lib/jobs/"
printf 'FLY_API_TOKEN_PROJECT_3_OS=tok\n' > "$HI/env/fly.env"
printf '#!/bin/bash\nexit 0\n' > "$HI/bin/beat.sh"; chmod +x "$HI/bin/beat.sh"
cat > "$HI/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-}" in --tailnet-ip) echo 10.0.0.9; exit 0 ;; esac
exit 1
SH
chmod +x "$HI/bin/fleet-conf.sh"

# flyctl: counts sftp, records rm, and with FLY_MODE=fail every call exits 1.
cat > "$T/fakebin/flyctl" <<'SH'
#!/bin/bash
case "$*" in *sftp*) echo sftp >> "$SFTP_SINK" ;; esac
case "$*" in *rm*RESULT*job.json*) printf 'rm %s\n' "$*" >> "$RM_SINK" ;; esac
[ "${FLY_MODE:-ok}" = fail ] && exit 1
case "$*" in
  *sftp*)       : ;;
  *echo*yes*)   echo yes ;;
  *cat*RESULT*) cat "$RESULT_SRC" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/flyctl"
cp "$T/fakebin/flyctl" "$T/fakebin/fly"
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$SSH_SINK"
case "$*" in *remote-results*) cat > /dev/null ;; esac
exit 0
SH
chmod +x "$T/fakebin/ssh"
# The worker: the fly_result feed, the job's artifacts, and the `result` feed
# the relay decision asks, each switchable on its own.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$REQ_SINK"
[ "${CURL_DOWN:-0}" = 1 ] && exit 7
row() { jq -nc --rawfile d "$1" --rawfile r "$FR_REF" --arg ts "$FIX_TS" \
  '{artifacts:[{job_id:"J7",artifact_kind:"fly_result",artifact_ref:($r|rtrimstr("\n")),box:"builder-project-3",ticket_id:"T1",updated_at:$ts,detail:$d}]}'; }
case "$URL" in
  */api/artifacts*kind=fly_result*)
    case "${FR_FEED:-empty}" in
      down) exit 7 ;;
      has)  row "$FR_FEED_DETAIL"; printf '200' ;;
      *)    printf '{"artifacts":[]}\n200' ;;
    esac ;;
  */api/artifacts*kind=result*)
    case "${RES_FEED:-empty}" in
      down) exit 7 ;;
      *)    printf '{"artifacts":[]}\n200' ;;
    esac ;;
  */api/queue\?*)
    jq -nc --arg e "${QUEUE_ENQ:-}" '{queue:[{project:"project-3",ticket_key:"TK-9",ticket_id:"T1",status:"claimed",target:"fly",
      enqueued_at:(if $e == "" then null else $e end)}]}'; printf '200' ;;
  */api/jobs/J7/artifacts)
    case "${FR_JOB:-ok}" in
      down) exit 7 ;;
      *)    row "$FR_JOB_DETAIL"; printf '200' ;;
    esac ;;
  *) printf '{}\n200' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

# The DB copy and the sftp copy differ on purpose, so every assertion can tell
# which door the RESULT came through.
printf 'PR_CREATED https://github.com/o/r/pull/9 | tier 2\nTIER: 2\nBUILD_DIR: project-3-TK-9-m1\nARTIFACT: /data/harness/builds/project-3-TK-9-m1/review.md\nVIA: db\n' > "$T/db-result.txt"
printf 'PR_CREATED https://github.com/o/r/pull/9 | tier 2\nTIER: 2\nBUILD_DIR: project-3-TK-9-m1\nVIA: sftp\n' > "$T/result.src"
mkdetail() { # mkdetail <out> <jq-overrides>
  jq -nc --rawfile result "$T/db-result.txt" \
    '{key:"TK-9",build_dir:"project-3-TK-9-m1",result:$result,
      pipeline_tail:"[x] execute start\n[x] GATES tamper=0 repro=0 intent=0 scope=0\n[x] review done",
      evidence:"evidence body\n",truncated:false} | '"${2:-.}" > "$1"
}
mkdetail "$T/detail-good.json"
head -1 "$T/db-result.txt" > "$T/ref-good.txt"

seed() {
  local d; for d in "$HI/builds/fly-"* "$HI/state/remote-results"; do scratch_rm "$d"; done
  rm -f "$HI/flags/builder-direct-off" "$HI/state/fly/project-3-TK-9.relay-deferred"
  jq -nc '{key:"TK-9",ticket_id:"T1"}' > "$HI/state/fly/project-3-active.json"
  touch -d "@$ENQ_EPOCH" "$HI/state/fly/project-3-active.json"
  jq -nc '{app:"builder-project-3"}' > "$HI/state/fly/project-3.json"
  : > "$T/rm.txt"; : > "$T/ssh.txt"; : > "$T/req.txt"; : > "$T/sftp.txt"
  : > "$HI/logs/ALERTS.log"; : > "$HI/logs/fly-dispatch.log"
}
hub() { # env: FLY_MODE FR_FEED FR_JOB RES_FEED CURL_DOWN FR_FEED_DETAIL FR_JOB_DETAIL FR_REF
  ( export HARNESS="$HI" JOBS_HARNESS="$HI" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           REQ_SINK="$T/req.txt" RESULT_SRC="$T/result.src" SSH_SINK="$T/ssh.txt" \
           RM_SINK="$T/rm.txt" SFTP_SINK="$T/sftp.txt" FIX_TS="$ENQ_ISO" \
           FLY_MODE="${FLY_MODE:-ok}" FR_FEED="${FR_FEED:-empty}" FR_JOB="${FR_JOB:-ok}" \
           RES_FEED="${RES_FEED:-empty}" CURL_DOWN="${CURL_DOWN:-0}" \
           BUILD_QUEUE_ROWS_ONLY="${BUILD_QUEUE_ROWS_ONLY:-0}" QUEUE_ENQ="${QUEUE_ENQ:-}" \
           FR_FEED_DETAIL="${FR_FEED_DETAIL:-$T/detail-good.json}" \
           FR_JOB_DETAIL="${FR_JOB_DETAIL:-$T/detail-good.json}" FR_REF="${FR_REF:-$T/ref-good.txt}" \
           PATH="$T/fakebin:$PATH"
    bash "$INGEST" project-3 >/dev/null 2>&1 )
}
bdir()   { ls -d "$HI/builds"/fly-project-3-TK-9-* 2>/dev/null | head -1; }
nsftp()  { wc -l < "$T/sftp.txt" | tr -d ' '; }
logged() { grep -qF -- "$1" "$HI/logs/fly-dispatch.log"; }
# via_sftp <case> <why>   — the old path ran and the RESULT is the sftp copy
via_sftp() {
  local d; d=$(bdir)
  [ -n "$d" ] && cmp -s "$d/RESULT" "$T/result.src" \
    && ok || bad "$1 the RESULT must come from console cat (sftp path): $(cat "${d:-/dev/null}/RESULT" 2>/dev/null)"
  logged "source=sftp ($2)" && ok || bad "$1 log must say 'source=sftp ($2)': $(grep ingesting "$HI/logs/fly-dispatch.log")"
}

# ── H1 flyctl down, row present: ingest from the DB (red on main) ────────────
seed; FLY_MODE=fail FR_FEED=has hub
D=$(bdir)
[ -n "$D" ] && ok || bad "H1 a builddir must exist with flyctl down and the fly_result row present"
cmp -s "${D:-/nonexistent}/RESULT" "$T/db-result.txt" && ok || bad "H1 RESULT must equal the row's .result byte for byte"
grep -q '] GATES tamper=0' "${D:-/nonexistent}/pipeline.log" 2>/dev/null \
  && ok || bad "H1 pipeline.log must carry the GATES line (D34's grep)"
[ -s "${D:-/nonexistent}/evidence.md" ] && ok || bad "H1 evidence.md must be written"
logged "source=db" && ok || bad "H1 log must say source=db"
[ ! -e "$HI/state/fly/project-3-active.json" ] && ok || bad "H1 the active file must be cleared"
[ -s "$T/rm.txt" ] && ok || bad "H1 the builder rm must still be attempted"
[ "$(nsftp)" -gt 0 ] && ok || bad "H1 artifacts must still be attempted over sftp"

# ── H2 no row: the old sftp path, unchanged ──────────────────────────────────
seed; FR_FEED=empty hub
[ "$(nsftp)" -gt 0 ] && ok || bad "H2 the sftp stub must be called"
via_sftp H2 "no fly_result row"
[ -s "$T/rm.txt" ] && ok || bad "H2 the builder rm must still run"

# ── H3 worker unreachable: sftp, never an empty builddir ─────────────────────
seed; touch "$HI/flags/builder-direct-off"; CURL_DOWN=1 hub
D=$(bdir)
[ -s "${D:-/nonexistent}/RESULT" ] && ok || bad "H3 the builddir RESULT must be non-empty"
via_sftp H3 "worker unreachable"

# ── H4 truncated row: sftp ───────────────────────────────────────────────────
mkdetail "$T/detail-trunc.json" '.truncated = true'
seed; FR_FEED=has FR_FEED_DETAIL="$T/detail-trunc.json" FR_JOB_DETAIL="$T/detail-trunc.json" hub
via_sftp H4 "row truncated or unusable"

# ── H5 a db read then an rc-2 hold: nothing half-made is left ────────────────
seed; FLY_MODE=fail FR_FEED=has RES_FEED=down hub
[ -z "$(bdir)" ] && ok || bad "H5 a held result must leave no builds/fly-* dir: $(ls -A "$(bdir)" 2>/dev/null)"
[ -e "$HI/state/fly/project-3-TK-9.relay-deferred" ] && ok || bad "H5 the hold flag must be written"
[ ! -s "$T/rm.txt" ] && ok || bad "H5 a held result must not clear the builder"
[ -e "$HI/state/fly/project-3-active.json" ] && ok || bad "H5 a held result keeps the active file"

# ── H6 the job's detail is another key's: sftp ───────────────────────────────
mkdetail "$T/detail-fr8.json" '.key = "TK-8"'
seed; FR_FEED=has FR_JOB_DETAIL="$T/detail-fr8.json" hub
via_sftp H6 "row truncated or unusable"

# ── H7 ref differs from the result's line 1: sftp ────────────────────────────
printf 'PR_CREATED https://github.com/o/r/pull/10\n' > "$T/ref-other.txt"
seed; FR_FEED=has FR_REF="$T/ref-other.txt" hub
via_sftp H7 "row truncated or unusable"

# ── H8 the feed is bounded by this attempt's enqueue time ────────────────────
seed; FR_FEED=empty hub
grep -q "/api/artifacts?kind=fly_result&project=project-3&.*since=$ENQ_ISO" "$T/req.txt" \
  && ok || bad "H8 the fly_result feed must carry kind=fly_result and since=$ENQ_ISO: $(grep fly_result "$T/req.txt")"

# ── H9 nothing in flight: no artifact read, no dir ─────────────────────────────────
seed; rm -f "$HI/state/fly/project-3-active.json"; FR_FEED=has hub
# The rows-only settings read is today's behaviour; an artifact read is not.
! grep -q '/api/artifacts\|/api/jobs/' "$T/req.txt" && ok || bad "H9 a quiet project must not read artifacts: $(cat "$T/req.txt")"
[ -z "$(bdir)" ] && ok || bad "H9 a quiet project must not create a builddir"

# ── H10 feed answered, detail read down: sftp, and not held ──────────────────
seed; FR_FEED=has FR_JOB=down hub
via_sftp H10 "worker unreachable"
[ ! -e "$HI/state/fly/project-3-TK-9.relay-deferred" ] && ok || bad "H10 must not be held"

# ── H11 a detail that is not JSON: sftp ──────────────────────────────────────
printf 'not json at all' > "$T/detail-bad.json"
seed; FR_FEED=has FR_JOB_DETAIL="$T/detail-bad.json" hub
via_sftp H11 "row truncated or unusable"

# ── H12 an empty .result: sftp ───────────────────────────────────────────────
mkdetail "$T/detail-empty.json" '.result = ""'
seed; FR_FEED=has FR_JOB_DETAIL="$T/detail-empty.json" hub
via_sftp H12 "row truncated or unusable"

# ── H13 rows-only, no active file: the claimed row's enqueued_at bounds it ───
seed; rm -f "$HI/state/fly/project-3-active.json"
BUILD_QUEUE_ROWS_ONLY=1 QUEUE_ENQ="$ENQ_ISO" FLY_MODE=fail FR_FEED=has hub
D=$(bdir)
cmp -s "${D:-/nonexistent}/RESULT" "$T/db-result.txt" && ok || bad "H13 a rows-only build must ingest from the DB with flyctl down"
grep -q "kind=fly_result&.*since=$ENQ_ISO" "$T/req.txt" \
  && ok || bad "H13 the feed must be bounded by the claimed row's enqueued_at: $(grep fly_result "$T/req.txt")"

# ── H14 rows-only, row has no enqueued_at: not asked, sftp, honest reason ───
seed; rm -f "$HI/state/fly/project-3-active.json"
BUILD_QUEUE_ROWS_ONLY=1 QUEUE_ENQ="" FR_FEED=has hub
! grep -q 'kind=fly_result' "$T/req.txt" && ok || bad "H14 no enqueue time must mean no unbounded fly_result read"
via_sftp H14 "no enqueue time to bound the DB read"

echo "fly-results-db.bh-2532-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

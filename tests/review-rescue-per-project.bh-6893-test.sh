#!/bin/bash
# tests/review-rescue-per-project.bh-6893-test.sh — BH-6893 (BH-6881.11):
# bin/review-rescue.sh runs per project (`--project <p>`), the cron tick is a
# dispatcher (`--dispatch`, pl_dispatch), and the manifest pair
# catalog/lane-run-inputs.d/review-rescue.{ro,rw} names what one project run
# reads and writes.
#
# The REAL lane runs end to end on a scratch hub that holds its own install
# closure (scratch_install_closure). Stubbed: gh (every ticket is closed, so a
# candidate retires through the closed-ticket path with no git and no review)
# and curl (the jobs worker). Fleet: pa, pa-x (a name pa is a prefix of) and pb.
#
#   P1  --project pa: pa's records get their markers; pa-x's, pb's and the
#       negative-list records are byte for byte unchanged
#   P2  no flag: every eligible record of every project gets its marker;
#       RESCUE_PER_TICK=1 over 3 projects: the fleet run takes 1 (the oldest),
#       three --project runs take 1 each. P2b: an unknown argument is a fleet
#       run plus one log line
#   P3  a root built from the lri_publish snapshot only: --project pa exits 0
#       with P1's outcome, every file it writes is in .rw or NOT CARRIED, and
#       the lri_checkpoint write-back passes _lri_validate
#   P5  --dispatch --project pa: rc 2, no marker
#   P6  --project zz | '' | ../pa: rc 2, one log line each, no marker
#   P7  the project lock is held: rc 0, no marker
#   P7r the runner's lock (PL_LANE, PL_PROJECT, PL_LOCK_FD) is used
#   P10 the schema fragments seed lane_placement.review-rescue = hub, once
#   D1  --dispatch under hub placement: the summary line (period 600s), one
#       `project run <p>` line per project, no [lane-placement] alert
#   D2  --dispatch under fly placement: no hub run, the enqueues name exactly
#       pa, pa-x and pb
#   D3  no bin/lib/project-lanes.sh: --dispatch is the fleet run, and
#       --project=pa takes its lock by hand
#   D4  RESCUE_DISPATCH_SPREAD_SECS=abc: one log line, period 600s
#   D5  bin/render-cron.sh hub holds the --dispatch line once
#
# Run from anywhere: tests/review-rescue-per-project.bh-6893-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 \
  || { echo "SKIP: jq, flock or pgrep missing"; exit 0; }
# ONE clock read: every fixture mtime is derived from it.
NOW=$(date -u +%s)
unset RESCUE_ONLY RESCUE_PER_TICK RESCUE_DISPATCH_SPREAD_SECS PL_LANE PL_PROJECT PL_LOCK_FD PL_STATE_DIR PL_SLUG \
      JOB_ID JOB_PHASE_ID LANE_RUN_ID GH_TOKEN VERDICT_WINDOW_LINES _VP_WINDOW

# --- the install every case copies --------------------------------------------
BASE="$T/base"
mkdir -p "$BASE/bin" "$T/fakebin" "$T/repos"
for L in bin/review-rescue.sh bin/project-of.sh bin/fleet-conf.sh bin/fleet-projects-or-alert.sh \
         bin/alert-line.sh bin/jobs-client.sh bin/project-lane-run.sh bin/test-tamper-scan.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$BASE" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$BASE/bin/"*.sh
# bin/lib/verdict-parse.sh reads its window from this registry (the settings
# fake answers 404). Without it every review.md reads unknown and no backfill runs.
mkdir -p "$BASE/catalog/lanes.d"
cp "$DIR/catalog/lanes.d/_lib.json" "$BASE/catalog/lanes.d/" || { echo "setup: could not copy catalog/lanes.d/_lib.json"; exit 1; }

# --- stubs --------------------------------------------------------------------
# gh: every issue is closed; everything else answers nothing. One line per call.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB/gh-calls.log"
case "$*" in
  *"-i -X GET"*"/issues/"*"/comments"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-i -X GET"*"/issues/"*) printf 'HTTP/2 200\r\n\r\n{"state":"closed"}' ;;
esac
exit 0
EOF
# curl: the jobs worker in the jobs-client wire shape (body, newline, status).
# Every request is one line "METHOD URL BODY" in $STUB/req.txt.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary|-d) BODY="$2"; shift 2 ;; *) shift ;; esac
done
case "$BODY" in @-) BODY=$(cat) ;; @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
printf '%s %s %s\n' "$METHOD" "$URL" "$(printf '%s' "$BODY" | tr '\n' ' ')" >> "$STUB/req.txt"
case "$METHOD $URL" in
  "GET "*/api/settings/lane_placement.review-rescue)
    if [ -f "$STUB/placement" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$STUB/placement")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  # The batch answer names every row it took (bin/lib/lane-placement.sh lp_enqueue_batch).
  "POST "*/api/lane-runs/batch)
    printf '%s\n200\n' "$(printf '%s' "$BODY" | jq -c '{rows: [.rows | to_entries[] | {project: .value.project, status: "enqueued", id: (.key + 1)}]}')" ;;
  "POST "*/api/lane-runs*) printf '{"run":{"id":1}}\n201\n' ;;
  "GET "*/api/artifacts*kind=result*) printf '%s\n200\n' "$(cat "$STUB/feed" 2>/dev/null || echo '{"artifacts":[]}')" ;;
  "GET "*/api/artifacts*) printf '{"artifacts":[]}\n200\n' ;;
  "GET "*/api/jobs/*/artifacts) printf '{"artifacts":[{"artifact_kind":"result","artifact_ref":"x"}]}\n200\n' ;;
  "PUT "*/api/jobs/*/artifacts) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# mkhub <name> [root] — a scratch hub: the install, the fleet, the env. The
# root defaults to $T/<name>. Sets H.
mkhub() {
  H="${2:-$T/$1}"
  cp -a "$BASE" "$H"
  mkdir -p "$H/builds" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state"
  printf '%s\n' 'pa o/pa - - 2 box-pa 192.0.2.1' 'pa-x o/pa-x - - 2 box-pax 192.0.2.2' 'pb o/pb - - 2 box-pb 192.0.2.3' \
    > "$H/fleet.conf"
  printf '%s\n' JOBS_URL=https://jobs.invalid HARNESS_SECRET=secret-fixture JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
    JOBS_SETTINGS_CACHE_S=0 JOBS_BOX=box-fixture > "$H/env/global.env"
  : > "$H/req.txt"; : > "$H/gh-calls.log"
}
# rec <dir> <line 1> <age seconds> — one build record under $H/builds.
rec() { local d="$H/builds/$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/RESULT"; touch -d "@$((NOW - $3))" "$d/RESULT"; }
# feed <dir>... — the ledger's result feed names a job for each fly record.
feed() { local d i=0
  { printf '{"artifacts":['
    for d in "$@"; do
      [ "$i" = 0 ] || printf ','
      printf '{"job_id":"job-%s","artifact_ref":"ok","box":"pool-1","ticket_id":"t","updated_at":"u","detail":"{\\"build_dir\\":\\"%s\\"}"}' \
        "$d" "${d#fly-}"
      i=$((i + 1))
    done
    printf ']}'; } > "$H/feed"; }
BLOCKED="REVIEW_BLOCKED review: the review session died"
FAILED="PR_CREATE_FAILED: the create died"
# seed — the P1 fixture: three projects' records and the negative list.
seed() {
  local d
  rec pa-PA-1-202610010000 "$BLOCKED" 259200
  rec pool-pa-PA-2-202610010000 "$BLOCKED" 252000
  rec pa-PA-4-202610010000 "$BLOCKED" 245000; echo 2 > "$H/builds/pa-PA-4-202610010000/.rescue-attempts"
  rec fly-pa-PA-3-202610010000 "$FAILED" 240000
  rec pa-x-PX-1-202610010000 "$BLOCKED" 230000
  rec pool-pa-x-PX-2-202610010000 "$BLOCKED" 220000
  rec fly-pa-x-PX-3-202610010000 "$FAILED" 210000
  rec pb-TK-1-202610010000 "$BLOCKED" 200000
  rec fly-pb-TK-3-202610010000 "$FAILED" 190000
  for d in fly-pa-PA-3 fly-pa-x-PX-3 fly-pb-TK-3; do
    printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$H/builds/$d-202610010000/review.md"
  done
  # The negative list: a half-built tmp record, a young record, a rescued one.
  rec .pool-pa-PA-9.tmp.123 "$BLOCKED" 250000; touch -d "@$((NOW - 1800))" "$H/builds/.pool-pa-PA-9.tmp.123"
  rec pa-PA-5-202610010000 "$BLOCKED" 600
  rec pa-PA-6-202610010000 "$BLOCKED" 250000; : > "$H/builds/pa-PA-6-202610010000/.review-rescued"
  feed fly-pa-PA-3-202610010000 fly-pa-x-PX-3-202610010000 fly-pb-TK-3-202610010000
}
# run [ENV=...] -- [args...] — the real lane, from its own install. Sets RC.
run() {
  local e=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB="$H" REPOS_ROOT="$T/repos" \
    ${e[@]+"${e[@]}"} bash "$H/bin/review-rescue.sh" "$@" > "$H/out.txt" 2>&1
  RC=$?
}
# state <dir>... — a byte-level fingerprint of record dirs (names, sizes, mtimes, sums).
state() { local d
  for d in "$@"; do
    ( cd "$H/builds" && find "$d" -printf '%p %s %T@\n' 2>/dev/null | LC_ALL=C sort
      find "$d" -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort )
  done; }
has()  { [ -e "$H/builds/$1/$2" ]; }
logc() { grep -c -- "$1" "$H/logs/review-rescue.log" 2>/dev/null; }
alerts() { grep -c -- "$1" "$H/logs/ALERTS.log" 2>/dev/null; }
newmarks() { find "$H/builds" -newer "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
WAITFOR() { local i; for i in $(seq 1 150); do eval "$1" && return 0; sleep 0.2; done; return 1; }
OTHERS=(pa-x-PX-1-202610010000 pool-pa-x-PX-2-202610010000 fly-pa-x-PX-3-202610010000 pb-TK-1-202610010000
        fly-pb-TK-3-202610010000 .pool-pa-PA-9.tmp.123 pa-PA-5-202610010000 pa-PA-6-202610010000)
# p1_outcome <label> — the pa half of P1, on $H.
p1_outcome() {
  has pa-PA-1-202610010000 .review-rescued && has pool-pa-PA-2-202610010000 .review-rescued \
    && ok "$1: pa's closed-ticket candidates (plain and pool-) are retired" \
    || bad "$1: pa's closed-ticket candidates retired (out: $(tail -3 "$H/out.txt"); log: $(tail -5 "$H/logs/review-rescue.log" 2>/dev/null))"
  [ "$(logc 'is closed')" = 2 ] && ok "$1: two 'is closed' lines" || bad "$1: 'is closed' lines: $(logc 'is closed')"
  has pa-PA-4-202610010000 .review-rescued && [ "$(alerts 'GIVING UP on pa-PA-4')" = 1 ] \
    && ok "$1: pa's give-up record is retired with one ALERTS line" \
    || bad "$1: give-up: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
  has fly-pa-PA-3-202610010000 .verdict-backfilled \
    && [ "$(grep -c '^PUT .*/api/jobs/job-fly-pa-PA-3-202610010000/artifacts' "$H/req.txt")" = 1 ] \
    && ok "$1: pa's fly- PR_CREATE_FAILED + APPROVE record is backfilled once" \
    || bad "$1: backfill: $(grep '^PUT' "$H/req.txt")"
}

# ============================================================================
echo "P1: --project pa touches pa's records only"
mkhub p1; seed
BEFORE=$(state "${OTHERS[@]}")
run -- --project pa
[ "$RC" = 0 ] && ok "P1 rc 0" || bad "P1 rc=$RC: $(tail -5 "$H/out.txt")"
p1_outcome P1
[ "$(state "${OTHERS[@]}")" = "$BEFORE" ] && ok "P1 pa-x, pb and the negative list are byte for byte unchanged" \
  || bad "P1 changed: $(diff <(printf '%s\n' "$BEFORE") <(state "${OTHERS[@]}"))"
grep -qE '/o/(pa-x|pb)/' "$H/gh-calls.log" && bad "P1 a gh call for another project: $(grep -E 'o/(pa-x|pb)' "$H/gh-calls.log")" \
  || ok "P1 no gh call for pa-x or pb"
grep -qE 'PUT .*job-fly-(pa-x|pb)-' "$H/req.txt" && bad "P1 another project's verdict was written" || ok "P1 no verdict row for pa-x or pb"
grep -qE 'pa-x|pb-' "$H/logs/ALERTS.log" 2>/dev/null && bad "P1 an alert for another project: $(cat "$H/logs/ALERTS.log")" \
  || ok "P1 no alert for pa-x or pb"
[ "$(logc 'project run pa')" = 1 ] && ok "P1 one 'project run pa' line" || bad "P1 project run line: $(logc 'project run pa')"

# ============================================================================
echo "P2: no flag is the fleet run of today"
mkhub p2; seed
run RESCUE_PER_TICK=10 --
[ "$RC" = 0 ] && ok "P2 rc 0" || bad "P2 rc=$RC: $(tail -5 "$H/out.txt")"
N=0
for d in pa-PA-1 pool-pa-PA-2 pa-PA-4 pa-x-PX-1 pool-pa-x-PX-2 pb-TK-1; do has "$d-202610010000" .review-rescued && N=$((N + 1)); done
for d in fly-pa-PA-3 fly-pa-x-PX-3 fly-pb-TK-3; do has "$d-202610010000" .verdict-backfilled && N=$((N + 1)); done
[ "$N" = 9 ] && ok "P2 all 9 eligible records of pa, pa-x and pb have their marker" || bad "P2 $N of 9 markers"
has pa-PA-5-202610010000 .review-rescued && bad "P2 the young record was taken" || ok "P2 the young record is left"
[ -d "$H/builds/.pool-pa-PA-9.tmp.123" ] && [ ! -e "$H/builds/.pool-pa-PA-9.tmp.123/.review-rescued" ] \
  && ok "P2 the tmp record is never a candidate" || bad "P2 the tmp record was touched"
grep -qE ' project run (pa|pa-x|pb)$' "$H/logs/review-rescue.log" && bad "P2 a fleet run wrote a project run line" || ok "P2 no project run line"

echo "P2: RESCUE_PER_TICK=1 is per run"
mkhub p2cap
rec pb-TK-7-202610010000 "$BLOCKED" 300000
rec pa-PA-7-202610010000 "$BLOCKED" 200000
rec pa-x-PX-7-202610010000 "$BLOCKED" 100000
run RESCUE_PER_TICK=1 --
TAKEN=$(find "$H/builds" -name .review-rescued | sed "s#$H/builds/##; s#/.review-rescued##")
[ "$TAKEN" = pb-TK-7-202610010000 ] && ok "P2 the fleet run takes 1, the oldest" || bad "P2 fleet run took: $TAKEN"
mkhub p2cap2
rec pb-TK-7-202610010000 "$BLOCKED" 300000
rec pa-PA-7-202610010000 "$BLOCKED" 200000
rec pa-PA-8-202610010000 "$BLOCKED" 150000
rec pa-x-PX-7-202610010000 "$BLOCKED" 100000
for p in pa pa-x pb; do run RESCUE_PER_TICK=1 -- --project "$p"; done
TAKEN=$(find "$H/builds" -name .review-rescued | sed "s#$H/builds/##; s#/.review-rescued##" | LC_ALL=C sort | tr '\n' ' ')
[ "$TAKEN" = "pa-PA-7-202610010000 pa-x-PX-7-202610010000 pb-TK-7-202610010000 " ] \
  && ok "P2 three --project runs take 1 each (pa's oldest)" || bad "P2 project runs took: $TAKEN"

echo "P2b: an unknown argument is the fleet run plus one log line"
mkhub p2b; seed
run RESCUE_PER_TICK=10 -- junk
N=0
for d in pa-PA-1 pa-x-PX-1 pb-TK-1; do has "$d-202610010000" .review-rescued && N=$((N + 1)); done
[ "$RC" = 0 ] && [ "$N" = 3 ] && ok "P2b rc 0 and the fleet run's markers" || bad "P2b rc=$RC markers=$N"
[ "$(logc "unknown argument")" = 1 ] && ok "P2b one log line" || bad "P2b log lines: $(logc 'unknown argument')"

# ============================================================================
echo "P3: a root built from the snapshot only"
mkhub p3hub; seed; HUB="$H"
# The jobs client of the lib, as functions: PUT parts and the commit are kept,
# and GET answers the snapshot they made. Write-backs are kept as files.
mkdir -p "$T/p3"
_jobs_req() {
  local m="$1" p="$2"
  JOBS_HTTP=200
  case "$m $p" in
    "GET /api/lane-snapshots/review-rescue/pa/writebacks") echo '{"writebacks":[]}' ;;
    "GET /api/lane-snapshots/review-rescue/pa")
      [ -f "$T/p3/commit.json" ] || { JOBS_HTTP=404; return 2; }
      jq -c '{sha, parts, age_s: 0, truncated: false, writebacks: []}' "$T/p3/commit.json" ;;
    "GET /api/lane-snapshots/review-rescue/pa/parts/"*) p="${p#*/parts/}"; cat "$T/p3/part.${p%%\?*}.json" ;;
    "POST /api/lane-snapshots/review-rescue/pa/commit") printf '%s' "$3" > "$T/p3/commit.json"; echo '{}' ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
}
_jobs_req_file() {
  JOBS_HTTP=200
  case "$1 $2" in
    "PUT /api/lane-snapshots/review-rescue/pa/parts/"*) cp "$3" "$T/p3/part.${2##*/}.json"; echo '{}' ;;
    "POST /api/lane-snapshots/review-rescue/pa/writebacks") cp "$3" "$T/p3/wb.json"; echo '{"id":7}' ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
}
setting_get() { return 2; }
_jobs_box_name() { echo box-fixture; }
LRI() { local r="$1"; shift; ( export HARNESS="$r"; . "$DIR/bin/lib/lane-run-inputs.sh" || exit 99; "$@" ); }
OUT=$(LRI "$HUB" lri_publish review-rescue pa); rc=$?
[ "$rc" = 0 ] && [ -f "$T/p3/commit.json" ] && ok "P3 lri_publish review-rescue pa: $OUT" || bad "P3 publish rc=$rc: $OUT"
# The machine root: the lane's install, the machine's own env, nothing of the hub.
R="$T/p3root"
cp -a "$BASE" "$R"; mkdir -p "$R/env" "$R/logs" "$R/locks"; cp "$HUB/env/global.env" "$R/env/"
OUT=$(LRI "$R" lri_fetch review-rescue pa "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "P3 lri_fetch: $OUT" || bad "P3 fetch rc=$rc: $OUT"
for f in builds/pa-PA-1-202610010000/RESULT builds/fly-pa-PA-3-202610010000/review.md fleet.conf; do
  [ -f "$R/$f" ] && ok "P3 the snapshot carries $f" || bad "P3 the snapshot lacks $f"
done
for f in builds/pa-x-PX-1-202610010000 builds/pb-TK-1-202610010000 builds/.pool-pa-PA-9.tmp.123; do
  [ -e "$R/$f" ] && bad "P3 the snapshot carries $f" || ok "P3 the snapshot does not carry $f"
done
cp "$HUB/feed" "$R/feed"
touch "$T/p3/mark"
H="$R"
run -- --project pa
[ "$RC" = 0 ] && ok "P3 --project pa on the snapshot root: rc 0" || bad "P3 rc=$RC: $(tail -5 "$H/out.txt")"
p1_outcome P3
# Every file the run created or changed is in .rw, or on the NOT CARRIED list
# of review-rescue.rw.
NC_ERE='^(env/.*|logs/ALERTS\.log|logs/review-rescue\.log|logs/jobs-client\.log|logs/gh-calls/.*|logs/cost\.csv|locks/.*|state/alert-line-sent/.*|state/alerts/.*|flags/alerted-.*|state/gh-.*|state/settings-cache\.json|state/lane-gate/.*|state/lane-run-inputs/.*|out\.txt|req\.txt|gh-calls\.log|feed)$'
STRAY=""; NW=0
while IFS= read -r f; do
  rel="${f#"$R"/}"; NW=$((NW + 1))
  LRI "$R" lri_member_ok pa "$rel" - rw review-rescue && continue
  [[ $rel =~ $NC_ERE ]] && continue
  STRAY="$STRAY $rel"
done < <(find "$R" -path "$R/bin" -prune -o -type f -newer "$T/p3/mark" -print)
[ "$NW" -gt 0 ] && [ -z "$STRAY" ] && ok "P3 all $NW written files are in .rw or NOT CARRIED" || bad "P3 written outside the manifest:$STRAY"
OUT=$(LANE_RUN_ID=1 LRI "$R" lri_checkpoint review-rescue pa 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -f "$T/p3/wb.json" ]; then
  ok "P3 lri_checkpoint posted a write-back ($OUT)"
  jq -j .b64 "$T/p3/wb.json" | base64 -d > "$T/p3/wb.tgz"
  ( export HARNESS="$HUB"; . "$DIR/bin/lib/lane-run-inputs.sh" || exit 99; LRI_LANE=review-rescue _lri_validate pa "$T/p3/wb.tgz" writeback ) \
    && ok "P3 _lri_validate accepts the write-back" || bad "P3 _lri_validate refused: $(tar -tzf "$T/p3/wb.tgz" | tr '\n' ' ')"
  WBM=$(tar -tzf "$T/p3/wb.tgz" 2>/dev/null)
  grep -q 'pa-PA-1-202610010000/.review-rescued' <<<"$WBM" && ok "P3 the write-back carries the rescue marker" \
    || bad "P3 the write-back lacks the marker: $(tar -tzf "$T/p3/wb.tgz" | tr '\n' ' ')"
else
  bad "P3 lri_checkpoint rc=$rc: $OUT"
fi
if command -v strace >/dev/null 2>&1; then
  echo "  note P3 strace is on PATH; the open() sub-check is not wired in this suite"
else
  echo "  SKIP P3 open()/openat() trace: strace is not on PATH"
fi
unset -f _jobs_req _jobs_req_file setting_get _jobs_box_name

# ============================================================================
echo "P5: --dispatch with --project is refused"
mkhub p5; seed; touch "$T/p5.mark"
run -- --dispatch --project pa
[ "$RC" = 2 ] && [ "$(newmarks "$T/p5.mark")" = 0 ] && ok "P5 rc 2, nothing written" || bad "P5 rc=$RC new=$(newmarks "$T/p5.mark")"
[ "$(grep -c . "$H/out.txt")" = 1 ] && ok "P5 one stderr line" || bad "P5 out: $(cat "$H/out.txt")"

echo "P6: a bad --project is refused"
mkhub p6; seed; touch "$T/p6.mark"
for a in zz '' ../pa; do
  B=$(logc .); B=${B:-0}
  run -- --project "$a"
  A=$(logc .); A=${A:-0}
  [ "$RC" = 2 ] && [ "$((A - B))" = 1 ] && ok "P6 --project '$a': rc 2, one log line" || bad "P6 --project '$a': rc=$RC lines=$((A - B))"
done
[ "$(newmarks "$T/p6.mark")" = 0 ] && ok "P6 no record touched" || bad "P6 $(newmarks "$T/p6.mark") record files written"

echo "P7: a held project lock"
mkhub p7; seed; touch "$T/p7.mark"
exec 8>"$H/locks/review-rescue-pa.lock"; flock -n 8 || bad "P7 setup: the test could not take the lock"
run -- --project pa
[ "$RC" = 0 ] && [ "$(newmarks "$T/p7.mark")" = 0 ] && ok "P7 rc 0, no marker" || bad "P7 rc=$RC new=$(newmarks "$T/p7.mark")"
[ "$(logc 'still live')" = 1 ] && ok "P7 one 'still live' line" || bad "P7 log: $(tail -2 "$H/logs/review-rescue.log")"

echo "P7r: the runner's lock is used"
# fd 8 holds locks/review-rescue-pa.lock; a run that opened its own would be refused.
run PL_LANE=review-rescue PL_PROJECT=pa PL_LOCK_FD=8 -- --project pa
exec 8>&-
[ "$RC" = 0 ] && has pa-PA-1-202610010000 .review-rescued && ok "P7r the run works under the runner's lock" \
  || bad "P7r rc=$RC log: $(tail -3 "$H/logs/review-rescue.log")"

# ============================================================================
echo "P10: the placement seed"
ROWS=$(grep -h "'lane_placement.review-rescue'" "$DIR"/worker/jobs/schema.d/*.sql 2>/dev/null)
[ "$(printf '%s' "$ROWS" | grep -c .)" = 1 ] && ok "P10 one lane_placement.review-rescue row" || bad "P10 rows: $ROWS"
grep -q "'lane_placement.review-rescue'[[:space:]]*,[[:space:]]*'hub'" <<<"$ROWS" && ok "P10 seeded hub" || bad "P10 value: $ROWS"
grep -q "'lane_placement.review-rescue'[[:space:]]*,[[:space:]]*'fly'" <<<"$ROWS" && bad "P10 a fragment sets fly" || ok "P10 no fragment sets fly"

# ============================================================================
busy() { pgrep -f "$H/bin/(project-lane-run|review-rescue)\.sh" >/dev/null 2>&1; }
echo "D1: --dispatch under hub placement"
mkhub d1; seed
run -- --dispatch
[ "$RC" = 0 ] && ok "D1 rc 0" || bad "D1 rc=$RC: $(cat "$H/out.txt")"
grep -q 'review-rescue dispatch: started 3 project run(s) (period 600s' "$H/logs/review-rescue.log" \
  && ok "D1 the summary line: 3 runs, period 600s" || bad "D1 summary: $(cat "$H/logs/review-rescue.log")"
# The default spread sleeps the runs; stop them and dispatch with no spread.
pkill -f "$H/bin/project-lane-run.sh" 2>/dev/null; WAITFOR '! busy'
run RESCUE_DISPATCH_SPREAD_SECS=0 -- --dispatch
WAITFOR '[ "$(grep -c "project run" "$H/logs/review-rescue.log")" -ge 3 ] && ! busy' || bad "D1 the runs did not end"
for p in pa pa-x pb; do
  [ "$(grep -c "project run $p\$" "$H/logs/review-rescue.log")" = 1 ] && ok "D1 one 'project run $p' line" \
    || bad "D1 'project run $p': $(grep 'project run' "$H/logs/review-rescue.log")"
done
N=0
for d in pa-PA-1 pa-x-PX-1 pb-TK-1; do has "$d-202610010000" .review-rescued && N=$((N + 1)); done
[ "$N" = 3 ] && ok "D1 every project's run did its work" || bad "D1 $N of 3 projects' records retired (cron: $(tail -5 "$H/logs/review-rescue-cron.log" 2>/dev/null))"
grep -q 'lane-placement' "$H/logs/ALERTS.log" 2>/dev/null && bad "D1 a [lane-placement] alert" || ok "D1 no [lane-placement] alert"

echo "D2: --dispatch under fly placement"
mkhub d2; seed; echo fly > "$H/placement"; touch "$T/d2.mark"
run RESCUE_DISPATCH_SPREAD_SECS=0 -- --dispatch
sleep 0.5; WAITFOR '! busy'
[ "$RC" = 0 ] && ok "D2 rc 0" || bad "D2 rc=$RC: $(cat "$H/out.txt")"
grep -qE ' project run (pa|pa-x|pb)$' "$H/logs/review-rescue.log" && bad "D2 a hub run started" || ok "D2 no hub run"
[ "$(newmarks "$T/d2.mark")" = 0 ] && ok "D2 the dispatcher touches no record" || bad "D2 $(newmarks "$T/d2.mark") record files written"
[ ! -s "$H/logs/review-rescue-cron.log" ] && ok "D2 no runner output" || bad "D2 runner output: $(cat "$H/logs/review-rescue-cron.log")"
POSTS=$(grep '^POST .*/api/lane-runs' "$H/req.txt")
NAMED=$(grep -oE '"project":"[^"]*"' <<<"$POSTS" | LC_ALL=C sort -u | tr '\n' ' ')
[ "$NAMED" = '"project":"pa" "project":"pa-x" "project":"pb" ' ] && ok "D2 the enqueues name exactly pa, pa-x and pb" || bad "D2 named: $NAMED"
grep -q '"args":\["bin/review-rescue.sh","--project"\]' <<<"$POSTS" && ok "D2 args: bin/review-rescue.sh --project" || bad "D2 args: $POSTS"
if ( export HARNESS="$H"; . "$H/bin/lib/project-lanes.sh"; command -v lp_enqueue_batch >/dev/null ); then
  [ "$(grep -c '^POST .*/api/lane-runs/batch' "$H/req.txt")" = 1 ] && ok "D2 one batch POST" || bad "D2 batch POSTs: $POSTS"
else
  [ "$(grep -c '^POST .*/api/lane-runs ' "$H/req.txt")" = 3 ] && ok "D2 one POST per project (no lp_enqueue_batch on this base)" \
    || bad "D2 POSTs: $POSTS"
fi
grep -q 'placed: 3 fly, 0 hub' "$H/logs/review-rescue.log" && ok "D2 placed: 3 fly, 0 hub" || bad "D2 summary: $(cat "$H/logs/review-rescue.log")"

echo "D3: no project-lanes lib"
mkhub d3; seed; rm -f "$H/bin/lib/project-lanes.sh"
run RESCUE_PER_TICK=10 -- --dispatch
N=0
for d in pa-PA-1 pa-x-PX-1 pb-TK-1; do has "$d-202610010000" .review-rescued && N=$((N + 1)); done
[ "$RC" = 0 ] && [ "$N" = 3 ] && ok "D3 --dispatch is the fleet run" || bad "D3 rc=$RC markers=$N"
[ "$(logc 'project-lanes.sh not loaded')" = 1 ] && ok "D3 one log line" || bad "D3 log: $(tail -3 "$H/logs/review-rescue.log")"
mkhub d3b; seed; rm -f "$H/bin/lib/project-lanes.sh"; touch "$T/d3.mark"
exec 8>"$H/locks/review-rescue-pa.lock"; flock -n 8
run -- --project=pa
[ "$RC" = 0 ] && [ "$(newmarks "$T/d3.mark")" = 0 ] && ok "D3 --project=pa takes locks/review-rescue-pa.lock by hand" \
  || bad "D3 held lock: rc=$RC new=$(newmarks "$T/d3.mark")"
exec 8>&-
run -- --project=pa
[ "$RC" = 0 ] && has pa-PA-1-202610010000 .review-rescued && ! has pa-x-PX-1-202610010000 .review-rescued \
  && ok "D3 --project=pa runs pa only" || bad "D3 --project=pa rc=$RC"

echo "D4: a junk spread"
mkhub d4
run RESCUE_DISPATCH_SPREAD_SECS=abc -- --dispatch
pkill -f "$H/bin/project-lane-run.sh" 2>/dev/null; WAITFOR '! busy'
[ "$(logc "RESCUE_DISPATCH_SPREAD_SECS='abc'")" = 1 ] && ok "D4 one log line" || bad "D4 log: $(cat "$H/logs/review-rescue.log")"
grep -q '(period 600s' "$H/logs/review-rescue.log" && ok "D4 period 600s" || bad "D4 summary: $(cat "$H/logs/review-rescue.log")"

echo "D5: the rendered hub crontab"
OUT=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" --root "$DIR" hub 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'review-rescue.sh --dispatch' <<<"$OUT")" = 1 ] \
  && ok "D5 one review-rescue.sh --dispatch line" || bad "D5 rc=$rc: $(grep review-rescue <<<"$OUT")"
grep -q 'hub-lease.sh check && .*review-rescue.sh --dispatch' <<<"$OUT" && ok "D5 the hub-lease gate stays" || bad "D5 gate: $(grep review-rescue <<<"$OUT")"

echo
echo "review-rescue-per-project: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

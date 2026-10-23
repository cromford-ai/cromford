#!/bin/bash
# tests/job-abandon.bh-2406-test.sh — ABANDON a job from Mission Control, and
# the three things that re-offer a ticket treat it as FINAL (BH-2406).
#
# The operator's ABANDON is an audited worker transition to `abandoned`
# (worker/jobs/src/routes/job-abandon.js, proved by
# worker/jobs/test/job-abandon.bh-2406.test.js). This suite is the shell half:
#   0. the new and touched sources, named by rooted path, so the impact lane and
#      the orphan ratchet (`bin/test-impact.sh orphans --check`) can see them.
#   0b. lib/job-actions.js DRIVEN with node: which rows get ABANDON, the reason
#      rule, and a blank reason never reaching the network.
#   1. job_ticket_abandoned (bin/lib/jobs/jobs.sh): the one question all three
#      consumers ask, "is this ticket's NEWEST job row abandoned".
#   2. the resume pass (bin/lib/resume-dead.sh resume_dead_pass) ends an
#      abandoned build's dir instead of relaunching it.
#   3. the pool's QROW requeue (bin/fly-pool.sh) refuses to re-enqueue an
#      abandoned ticket.
#   4. the blocked-resolver's br_one (bin/blocked-resolver.sh) takes no rung on
#      an abandoned ticket.
#   5. the node suites, run for real when the dependencies are installed.
#   6. a NEWER triage / lead-review / orc-job / migration row for the ticket does
#      not un-abandon it for the pool or the resolver (only a newer build does).
# Run from anywhere: tests/job-abandon.bh-2406-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "job-abandon: SKIPPED — jq is not installed"; exit 0; }

LIB="$DIR/console-ui/src/lib/job-actions.js"
UI="$DIR/console-ui/src/ui/JobActions.js"
PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
API="$DIR/console-ui/src/api.js"
ROUTE="$DIR/worker/jobs/src/routes/job-abandon.js"
JOBSLIB="$DIR/bin/lib/jobs/jobs.sh"
RESUME="$DIR/bin/lib/resume-dead.sh"
POOL="$DIR/bin/fly-pool.sh"
BR="$DIR/bin/blocked-resolver.sh"

# --- 0: the sources exist ------------------------------------------------------
for f in "$LIB" "$UI" "$PROXY" "$API" "$ROUTE" "$JOBSLIB" "$RESUME" "$POOL" "$BR"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# --- 0b: the lib, driven ---------------------------------------------------------
if command -v node >/dev/null 2>&1 && [ -f "$LIB" ]; then
  OUT=$(node --input-type=module -e "
import * as L from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const row = (o) => ({ id: 'J1', status: 'running', heartbeating: true, beat_age_s: 30, activity_age_s: 30, ...o });
eq('stalled',  L.availableActions(row({ beat_age_s: 1200, activity_age_s: 1200 })), ['retry', 'requeue', 'abandon']);
eq('orphaned', L.availableActions(row({ status: 'orphaned' })), ['requeue', 'abandon']);
eq('parked',   L.availableActions(row({ status: 'parked' })), ['abandon']);
eq('failed',   L.availableActions(row({ status: 'failed' })), ['abandon']);
eq('running',  L.availableActions(row({})), []);
eq('done',     L.availableActions(row({ status: 'done' })), []);
eq('abandoned', L.availableActions(row({ status: 'abandoned' })), []);
eq('blank-reason', typeof L.abandonReasonError === 'function' && L.abandonReasonError('  '), 'Say why you are abandoning this job.');
eq('body',     L.requestBody('abandon', ' why '), { reason: 'why' });
let sent = 0;
const apiObj = { abandonJob: async () => { sent++; return { decision: 'abandoned', reason: 'r' }; } };
const out = await L.runJobAction({ apiObj, job: row({ status: 'parked' }), action: 'abandon',
  reasonForm: (t, form) => ({ form }), confirm: async (o) => { o.body.form.reason = ' '; return true; }, reload: () => {} });
eq('blank-sends-none', [sent, out && out.tone], [0, 'bad']);
" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      ok\ *) ok ;;
      no\ *) bad "lib: ${line#no }" ;;
      *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
    esac
  done <<< "$OUT"
  # No native dialog anywhere in the job-action UI (the ticket's in-app confirm).
  CODE=$(grep -hvE '^[[:space:]]*//' "$UI" "$LIB")
  # A native call passes its message as a string literal; the in-app hook is
  # called with an options object (`confirm(confirmOpts(...))`), so it never matches.
  if [[ "$CODE" =~ (window\.|globalThis\.|[^.a-zA-Z_])(confirm|alert|prompt)[[:space:]]*\([[:space:]]*[\'\"\`] ]]; then
    bad "a native dialog call in the job actions"
  else ok; fi
else
  echo "job-abandon: lib section SKIPPED — node is not installed"
fi

# --- 1: job_ticket_abandoned -------------------------------------------------------
# _jobs_req is stubbed with canned worker answers. The path it was asked is
# recorded, so the filter the helper sends is asserted too.
jta() { # jta <canned-json|DOWN> <project> <key> -> "rc|stdout|path"
  ( . "$JOBSLIB" 2>/dev/null
    _jobs_req() { printf '%s' "$2" > "$T/jta-path"; [ "$CANNED" = DOWN ] && return 1; printf '%s' "$CANNED"; }
    CANNED="$1"
    out=$(job_ticket_abandoned "$2" "$3"); rc=$?
    printf '%s|%s|%s' "$rc" "$out" "$(cat "$T/jta-path" 2>/dev/null)" )
}
J() { jq -nc --arg id "$1" --arg t "$2" --arg s "$3" --arg k "${4:-build}" '{jobs:[{id:$id,project:"p1",ticket_id:$t,kind:$k,status:$s}]}'; }
R=$(jta "$(J job-9 BH-9 abandoned)" p1 BH-9)
[ "${R%%|*}" = 0 ] && ok || bad "§1 an abandoned newest row must answer rc 0 (got $R)"
[ "$(cut -d'|' -f2 <<<"$R")" = job-9 ] && ok || bad "§1 it must print the job id (got $R)"
case "$(cut -d'|' -f3 <<<"$R")" in
  "/api/jobs?project=p1&ticket_id=BH-9&kind=build&limit=1") ok ;;
  *) bad "§1 the helper must ask for the ticket's newest BUILD row by project, ticket_id and kind (got $R)" ;;
esac
R=$(jta "$(J job-9 'BH 9&x' abandoned)" 'p 1' 'BH 9&x')
case "$(cut -d'|' -f3 <<<"$R")" in *"project=p%201&ticket_id=BH%209%26x&kind=build&limit=1") ok ;; *) bad "§1 both values must be URI-encoded (got $R)" ;; esac
for s in running orphaned parked failed "done" queued_for_retry; do
  R=$(jta "$(J job-9 BH-9 "$s")" p1 BH-9)
  [ "${R%%|*}" = 1 ] && ok || bad "§1 a newest row in $s must answer rc 1 (got $R)"
done
R=$(jta '{"jobs":[]}' p1 BH-9); [ "${R%%|*}" = 1 ] && ok || bad "§1 no row must answer rc 1 (got $R)"
# An older worker ignores the ticket filter and answers the project's newest
# row: an abandoned row for ANOTHER ticket must never read as a match.
R=$(jta "$(J job-8 BH-8 abandoned)" p1 BH-9); [ "${R%%|*}" = 1 ] && ok || bad "§1 a mismatched ticket_id must answer rc 1 (got $R)"
# A worker older than the kind filter answers the ticket's newest row of ANY
# kind: an abandoned triage or lead-review row is not the ticket's build.
for k in triage lead_review orc migration orchestrator; do
  R=$(jta "$(J job-9 BH-9 abandoned "$k")" p1 BH-9)
  [ "${R%%|*}" = 1 ] && ok || bad "§1 a newest $k row must not answer as the build (got $R)"
done
R=$(jta DOWN p1 BH-9); [ "${R%%|*}" = 2 ] && ok || bad "§1 a worker that did not answer must be rc 2 (got $R)"
R=$(jta 'not json' p1 BH-9); [ "${R%%|*}" = 2 ] && ok || bad "§1 an unparseable answer must be rc 2 (got $R)"
R=$(jta "$(J job-9 BH-9 abandoned)" '' BH-9); [ "${R%%|*}" = 2 ] && ok || bad "§1 no project is not a question (got $R)"

# --- 2: the resume pass does not relaunch an abandoned build -------------------------
H2="$T/h2"
mkdir -p "$H2/builds" "$H2/locks" "$H2/logs" "$H2/flags" "$H2/state"
printf '#!/bin/bash\necho "$RESUME_BUILD|$1|$2|$3" >> "%s/launches"\n' "$H2" > "$H2/run-build-stub.sh"
printf '#!/bin/bash\necho "2 (0 build(s) running, 2 box slot(s))"\n' > "$H2/free-slots-stub.sh"
chmod +x "$H2/run-build-stub.sh" "$H2/free-slots-stub.sh"
mk2() { # mk2 <dir> <key>
  local D="$H2/builds/$1" TS
  mkdir -p "$D"
  printf '{"project":"p1","ticket_id":"board-%s","key":"%s"}\n' "$2" "$2" > "$D/job.json"
  TS=$(date -u -d "60 min ago" +%Y%m%d%H%M 2>/dev/null || date -v-60M +%Y%m%d%H%M)
  touch -t "$TS" "$D" "$D/job.json"
  printf '%s' "$D"
}
ROWSTATUS=abandoned
rows_by_status() { # the seam resume_dead_pass eval's with the status it asks for
  [ "${1:-}" = "$ROWSTATUS" ] && printf 'job-bh9\tp1\tbuild\texecute\tbox\tBH-9\t9000\t150\t3\t-\t1\n'
  return 0
}
run_resume() {
  ( export HARNESS="$H2" RUN_BUILD="$H2/run-build-stub.sh" FREE_SLOTS="$H2/free-slots-stub.sh" \
           RESUME_ROWS_CMD=rows_by_status RESUME_REQUEUE_CMD=true RESUME_LOCK_CMD=true ROWSTATUS
    export -f rows_by_status
    . "$RESUME"; resume_dead_pass ) 2>/dev/null
  sleep 1
}
D2=$(mk2 p1-BH-9-202609250000 BH-9); : > "$H2/launches"
run_resume
[ ! -s "$H2/launches" ] && ok || bad "§2 an abandoned build was relaunched: $(cat "$H2/launches")"
head -1 "$D2/RESULT" 2>/dev/null | grep -q '^ABANDONED job job-bh9 ' && ok \
  || bad "§2 RESULT must start 'ABANDONED job <id> ' (got: $(cat "$D2/RESULT" 2>/dev/null))"
[ -f "$D2/.blocked-resolver-abandoned" ] && ok || bad "§2 the dir must carry .blocked-resolver-abandoned so br_from_builds skips it"
[ -f "$D2/COMMENTED" ] && ok || bad "§2 the dir must carry COMMENTED so the sweep does not report it as a verdict"
grep -q 'abandoned by an operator' "$H2/logs/resume-dead.log" 2>/dev/null && ok || bad "§2 one log line must say why"
grep -q 'BH-9' "$H2/logs/ALERTS.log" 2>/dev/null && bad "§2 an obeyed ABANDON is not an alert" || ok
# The RESULT prefix is none of br_from_builds' reasons: BUILD_DEAD, BUILD_DEFERRED ...
grep -qE '^(BUILD_|PR_|ABANDONED_TIMEOUT)' <<<"$(head -1 "$D2/RESULT" 2>/dev/null)" && bad "§2 the RESULT must not read as a resolver reason" || ok
# The same dir with its row ORPHANED is resumed, exactly as before.
scratch_rm "$D2"; D2=$(mk2 p1-BH-9-202609250001 BH-9); : > "$H2/launches"
ROWSTATUS=orphaned run_resume
grep -q "^$D2|p1|board-BH-9|BH-9$" "$H2/launches" && ok || bad "§2 an orphaned row must still resume (launches: $(cat "$H2/launches"))"

# --- 3: the pool's QROW requeue refuses an abandoned ticket -----------------------------
QFN=$(awk '/^QROW\(\) \{/{on=1} on{print} on&&/^\}$/{exit}' "$POOL")
[ -n "$QFN" ] && ok || bad "§3 QROW not found in bin/fly-pool.sh"
H3="$T/h3"; mkdir -p "$H3/logs"
qrow() { # qrow <abandoned-rc|undef> -> "rc|calls"
  ( HARNESS="$H3" P=p1 LOG="$H3/logs/pool.log"
    STAMP() { echo 2026-09-25T00:00:00Z; }
    say() { echo "$*" >> "$LOG"; }
    queue_done() { echo "done $*" >> "$H3/calls"; }
    queue_put()  { echo "put $*" >> "$H3/calls"; }
    if [ "$1" != undef ]; then
      eval "job_ticket_abandoned() { echo job-bh9; return $1; }"
    fi
    eval "$QFN"
    : > "$H3/calls"
    QROW requeue BH-9 "machine m1 died" 2 '{}' tid-9; rc=$?
    printf '%s|%s' "$rc" "$(tr '\n' ';' < "$H3/calls")" )
}
R=$(qrow 0)
[ "${R%%|*}" = 1 ] && ok || bad "§3 an abandoned ticket: QROW requeue must return 1 (got $R)"
case "$R" in *"put "*) bad "§3 an abandoned ticket must never reach queue_put (got $R)" ;; *) ok ;; esac
LASTDONE=$(tr ';' '\n' <<<"${R#*|}" | grep '^done ' | tail -1)
case "$LASTDONE" in "done p1 BH-9 failed ABANDONED"*) ok ;; *) bad "§3 the row must be closed failed ABANDONED... (got $LASTDONE)" ;; esac
case "$LASTDONE" in *"died "*|*"deferred "*) bad "§3 the reason must not read as a br_from_queue park: $LASTDONE" ;; *) ok ;; esac
for rc in 1 2 undef; do
  R=$(qrow "$rc")
  [ "${R%%|*}" = 0 ] && ok || bad "§3 abandoned rc=$rc: QROW requeue must return 0 (got $R)"
  case "$R" in *"put p1 BH-9 tid-9 fly 2 {}"*) ok ;; *) bad "§3 abandoned rc=$rc: the requeue must still enqueue (got $R)" ;; esac
done
# Every caller honours the answer: no line claims a requeue that did not happen.
N_ALL=$(grep -c 'QROW requeue ' "$POOL"); N_IF=$(grep -cE '^[[:space:]]*if QROW requeue ' "$POOL")
[ "$N_ALL" -ge 3 ] && [ "$N_ALL" = "$N_IF" ] && ok || bad "§3 every QROW requeue call site must branch on its rc ($N_IF of $N_ALL do)"

# --- 4: br_one takes no rung on an abandoned ticket -------------------------------------
BFN=$(awk '/^br_one\(\) \{/{on=1} on{print} on&&/^\}$/{exit}' "$BR")
[ -n "$BFN" ] && ok || bad "§4 br_one not found in bin/blocked-resolver.sh"
H4="$T/h4"; mkdir -p "$H4/logs" "$H4/bin"
brone() { # brone <abandoned-rc|undef> [calls] -> "rc|log|reached|asked"
  ( H="$H4" LOG="$H4/logs/br.log"
    : > "$LOG"; : > "$H4/reached"; : > "$H4/asked"
    STAMP() { echo T; }
    say() { echo "$*" >> "$LOG"; }
    br_action() { echo ladder; }
    br_use_token() { :; }
    br_reset_token() { :; }
    br_cap_key() { echo "$1-$3"; }
    br_load() { echo '{}'; }
    br_already_merged() { echo reached >> "$H4/reached"; return 0; }
    if [ "$1" != undef ]; then
      eval "job_ticket_abandoned() { echo \"\$1/\$2\" >> '$H4/asked'; echo job-bh9; return $1; }"
    fi
    eval "$BFN"
    n="${2:-1}"
    while [ "$n" -gt 0 ]; do br_one build-dead p1 p1-BH-9 build-dead - - BH-9; rc=$?; n=$((n-1)); done
    printf '%s|%s|%s|%s' "$rc" "$(tr '\n' ';' < "$LOG")" "$(wc -l < "$H4/reached" | tr -d ' ')" "$(tr '\n' ';' < "$H4/asked")" ) 2>/dev/null
}
R=$(brone 0)
[ "${R%%|*}" = 3 ] && ok || bad "§4 an abandoned ticket must answer rc 3, a terminal that takes no PER_TICK slot (got $R)"
[ "$(cut -d'|' -f3 <<<"$R")" = 0 ] && ok || bad "§4 no rung (not even the merged guard) may run on an abandoned ticket (got $R)"
case "$(cut -d'|' -f2 <<<"$R")" in *"job job-bh9 for BH-9 was abandoned by an operator"*) ok ;; *) bad "§4 one line must say it was abandoned (got $R)" ;; esac
[ "$(cut -d'|' -f4 <<<"$R")" = "p1/BH-9;" ] && ok || bad "§4 it must ask about the candidate's project and ticket key (got $R)"
R=$(brone 0 2)
[ "$(cut -d'|' -f4 <<<"$R")" = "p1/BH-9;" ] && ok || bad "§4 the answer is memoised for the tick: asked once for two candidates (got $R)"
for rc in 1 2 undef; do
  R=$(brone "$rc")
  [ "${R%%|*}" = 0 ] && [ "$(cut -d'|' -f3 <<<"$R")" = 1 ] && ok \
    || bad "§4 abandoned rc=$rc: the ladder must run as before (got $R)"
done

# --- 6: a LATER non-build row does not un-abandon the ticket (review of #2481) ---------
# The review's case, end to end through the REAL job_ticket_abandoned: the build
# row is abandoned, then triage-shard / lead-review / orc-job / migration opens a
# NEWER row for the same ticket key. The pool's requeue and the resolver must
# still see the operator's ABANDON. _jobs_req is a fake worker over a rows file
# that applies GET /api/jobs's filters the way the route does (project, status,
# box, ticket_id, kind; an unknown param ignored), newest created_at first.
H6="$T/h6"; mkdir -p "$H6/logs"
fake_worker_src='
_jobs_req() {
  [ "$1" = GET ] || return 1
  local q="${2#*\?}"
  jq -c --arg q "$q" --arg filters "$FAKE_FILTERS" '"'"'
    ($q | split("&") | map(split("=") | {(.[0]): (.[1] | @text | gsub("%20"; " "))}) | add) as $p
    | ($filters | split(",")) as $known
    | { jobs: ( [ .[] | . as $r
                  | select(all($known[]; . as $c | ($p[$c] == null) or ($r[$c] == $p[$c]))) ]
                | sort_by(.created_at) | reverse | .[0:(($p.limit // "100") | tonumber)] ) }
  '"'"' "$FAKE_ROWS"
}'
rows6() { # rows6 <kind-of-the-newer-row>
  jq -nc --arg k "$1" '[
    {id:"build-p1-BH-9-1", project:"p1", ticket_id:"BH-9", kind:"build", status:"abandoned", created_at:"2026-09-25T10:00:00Z"},
    {id:("\($k)-p1-BH-9-2"), project:"p1", ticket_id:"BH-9", kind:$k, status:"running", created_at:"2026-09-25T11:00:00Z"}
  ]' > "$H6/rows.json"
}
real_jta() { # real_jta -> "rc|stdout"
  ( . "$JOBSLIB" 2>/dev/null; eval "$fake_worker_src"
    FAKE_ROWS="$H6/rows.json" FAKE_FILTERS="$FAKE_FILTERS"
    out=$(job_ticket_abandoned p1 BH-9); printf '%s|%s' "$?" "$out" )
}
real_qrow() { # real_qrow -> "rc|calls"
  ( . "$JOBSLIB" 2>/dev/null; eval "$fake_worker_src"
    FAKE_ROWS="$H6/rows.json"
    HARNESS="$H6" P=p1 LOG="$H6/logs/pool.log"
    STAMP() { echo 2026-09-25T00:00:00Z; }
    say() { echo "$*" >> "$LOG"; }
    queue_done() { echo "done $*" >> "$H6/calls"; }
    queue_put()  { echo "put $*" >> "$H6/calls"; }
    eval "$QFN"
    : > "$H6/calls"
    QROW requeue BH-9 "machine m1 died" 2 '{}' tid-9; rc=$?
    printf '%s|%s' "$rc" "$(tr '\n' ';' < "$H6/calls")" )
}
real_brone() { # real_brone -> "rc|reached"
  ( . "$JOBSLIB" 2>/dev/null; eval "$fake_worker_src"
    FAKE_ROWS="$H6/rows.json"
    H="$H6" LOG="$H6/logs/br.log"; : > "$H6/reached"
    STAMP() { echo T; }
    say() { echo "$*" >> "$LOG"; }
    br_action() { echo ladder; }
    br_use_token() { :; }
    br_reset_token() { :; }
    br_cap_key() { echo "$1-$3"; }
    br_load() { echo '{}'; }
    br_already_merged() { echo reached >> "$H6/reached"; return 0; }
    eval "$BFN"
    br_one build-dead p1 p1-BH-9 build-dead - - BH-9; rc=$?
    printf '%s|%s' "$rc" "$(wc -l < "$H6/reached" | tr -d ' ')" ) 2>/dev/null
}
export FAKE_FILTERS=project,status,box,ticket_id,kind
for k in triage lead_review orchestrator migration; do
  rows6 "$k"
  R=$(real_jta)
  [ "$R" = "0|build-p1-BH-9-1" ] && ok || bad "§6 a newer $k row must not un-abandon the ticket (job_ticket_abandoned got $R)"
  R=$(real_qrow)
  [ "${R%%|*}" = 1 ] && ok || bad "§6 a newer $k row: the pool must still refuse the requeue (got $R)"
  case "$R" in *"put "*) bad "§6 a newer $k row: an abandoned ticket was re-enqueued (got $R)" ;; *) ok ;; esac
  R=$(real_brone)
  [ "$R" = "3|0" ] && ok || bad "§6 a newer $k row: the resolver must still take no rung (got $R)"
done
# A newer BUILD attempt is the one thing that re-offers the ticket, as before.
rows6 build
R=$(real_jta); [ "${R%%|*}" = 1 ] && ok || bad "§6 a newer build row must un-finalize the ticket (got $R)"
R=$(real_qrow)
case "$R" in "0|"*"put p1 BH-9 tid-9 fly 2 {}"*) ok ;; *) bad "§6 a newer build row: the requeue must enqueue as before (got $R)" ;; esac
R=$(real_brone); [ "$R" = "0|1" ] && ok || bad "§6 a newer build row: the ladder must run as before (got $R)"

# --- 5: the node suites, driven ----------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "job-abandon: node suites SKIPPED — node is not installed"
else
  # The worker imports catalog/lanes.json, which is GENERATED and not committed
  # (BH-1247): the worker is copied into $T beside a rendered registry rather
  # than rendering into this checkout.
  #
  # WORKER_JOBS_CI_JOB=1 is set by harness-ci.yml's tests-shard step, which runs
  # only when the "Jobs worker — routes + schema" job runs too (both need
  # corpus == '1'). That job runs `npm test` in worker/jobs, which covers every
  # test/*.test.js file, so running these node files again in a shard is the same
  # test twice. Without the flag (a builder's bin/test-impact-gate.sh, a laptop)
  # they run here. tests/dedicated-job-coverage-test.sh checks all of this.
  if [ "${WORKER_JOBS_CI_JOB:-}" = 1 ]; then
    echo "job-abandon: worker node suites not repeated here — the Jobs worker CI job runs them on this run"
  else
    WK="$T/wk"; mkdir -p "$WK/worker" "$WK/catalog"
    cp -R "$DIR/worker/jobs" "$WK/worker/" && cp "$(rendered_registry)" "$WK/catalog/lanes.json" && cp "$DIR/catalog/llm-sites.json" "$DIR/catalog/context-budgets.json" "$DIR/catalog/prompt-markers.json" "$WK/catalog/"
    # The staff routes import agent-core/ by a relative path (BH-5559), so the
    # scratch tree carries it beside worker/, as the deployed bundle does.
    cp -R "$DIR/agent-core" "$WK/agent-core" || bad "cannot copy agent-core (the worker imports it, BH-5559)"
    if NOUT=$(cd "$WK/worker/jobs" && node --test test/job-abandon.bh-2406.test.js test/route-table.test.js test/requeue.test.js 2>&1); then ok
    else bad "worker job-abandon node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
    fi
  fi
  if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    echo "job-abandon: console-ui node suites SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs them)"
  elif NOUT=$(cd "$DIR/console-ui" && node --test tests/job-abandon.bh-2406.test.js tests/job-abandon-proxy.bh-2406.test.js 2>&1); then ok
  else bad "console-ui job-abandon node suites failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "job-abandon: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# reads-run-build: raw — it EXECUTES the driver against a scratch $HARNESS, so it needs the real runnable path; the flatten is not runnable. See tests/rb-raw-readers-baseline/queue-producers-test.sh.txt.
# tests/queue-producers-test.sh — bin/run-build.sh writes the queue to the DB as
# well as to the directory, and CLOSES what it claimed.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about control flow around a
# side channel: the file must still be written when the worker is down, the
# build must still run when the claim is refused, and a DEFERRED build must put
# its row back rather than mark it finished. `grep -q queue_put bin/run-build.sh`
# would pass just as happily on a version that exits when the enqueue fails —
# which would stop the fleet building the moment a coordination database
# blinked, the exact failure this whole layer exists to remove.
#
# curl is stubbed (no network in tests) and the pipeline is driven only as far
# as its worktree setup, which fails on a scratch tree and lands the build in
# BUILD_DEFERRED — the path that proves the release. The worker's own behaviour
# is proven by worker/jobs/test/index.test.js.
# Run from anywhere: tests/queue-producers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state" "$T/h/env" "$T/repos/x-os" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" x-os || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
mkdir -p "$T/h/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/h/bin/lib/rt/"
mkdir -p "$T/h/bin/lib/rb" && cp "$DIR"/bin/lib/rb/*.sh "$T/h/bin/lib/rb/"
# BH-8930: gates.sh sources its gates.d/ fragments and defers the build when
# one is missing, so the fixture box carries the directory too.
cp -r "$DIR/bin/lib/rb/gates.d" "$T/h/bin/lib/rb/"
: > "$T/h/env/global.env"
# BH-4490: the trigger actor gate fails closed when its allowlist row cannot be
# read, which is every outage case below. This suite pins the QUEUE's outage
# fallback, so the gate is switched off by its own kill switch (a box without a
# readable row reads the flags/ file); tests/trigger-actor-gate.bh-4490-test.sh
# pins the gate's own outage behaviour.
: > "$T/h/flags/trigger-actor-off"
# The context gate runs before everything; a scratch tree has no rules to drift.
printf '#!/bin/bash\necho "gate ok"\nexit 0\n' > "$T/h/bin/context-gate.sh"
chmod +x "$T/h/bin/context-gate.sh"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) BODY="$2"; shift 2 ;;
    -X) M="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)  exit 7 ;;
  dup)   case "$URL" in
           */api/queue) printf '{"queued":{"project":"x-os","ticket_key":"TK-9","status":"queued"},"duplicate":true}\n200\n' ;;
           *)           printf '{"ok":true}\n200\n' ;;
         esac ;;
  taken) case "$URL" in
           */api/queue/claim) printf '{"refused":true,"scope":"queue","reason":"another claimant took x-os/TK-9 first"}\n409\n' ;;
           */api/jobs)        printf '{"job":{"id":"job-1","budget_usd":50}}\n201\n' ;;
           *)                 printf '{"ok":true}\n200\n' ;;
         esac ;;
  queuerows) case "$URL" in
           */api/queue\?*) printf '{"queue":[{"project":"x-os","ticket_key":"TK-77","ticket_id":"77","status":"queued","target":"fly","attempt":1,"claimed_by":null,"enqueued_at":"2026-09-10T01:02:03Z"}]}\n200\n' ;;
           # TEST-CHANGE BH-4153: paused-<project> is a harness_flags row; an
           # {"ok":true} 200 is an unreadable row, which with nothing cached a stop
           # switch reads as ON and the tick stands down. No row = not paused.
           */api/flags/*)  printf '{"error":"not found"}\n404\n' ;;
           */api/jobs)     printf '{"job":{"id":"job-1","budget_usd":50}}\n201\n' ;;
           *)              printf '{"ok":true}\n200\n' ;;
         esac ;;
  *) case "$URL" in
       */api/queue/claim) printf '{"queued":{"project":"x-os","ticket_key":"TK-9","ticket_id":"9","target":"local","attempt":0,"status":"claimed"},"claimed":true}\n200\n' ;;
       */api/queue)       printf '{"queued":{"project":"x-os","ticket_key":"TK-9","status":"queued"},"duplicate":false}\n201\n' ;;
       */api/jobs)        printf '{"job":{"id":"job-1","budget_usd":50}}\n201\n' ;;
       */api/flags/*)     printf '{"error":"not found"}\n404\n' ;;   # TEST-CHANGE BH-4153: as in queuerows
       *)                 printf '{"ok":true}\n200\n' ;;
     esac ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# flock is not under test and is not on every developer machine (macOS has
# none). Stubbing it makes this suite behave identically on the box and in CI,
# for the same reason curl is stubbed: what is being driven is the pipeline's
# control flow, not the OS's locking.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/flock"

# build <curl-mode> <key> -> the pipeline's rc; requests land in $T/req.txt
build() {
  local mode="$1" key="$2"
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" REPOS_ROOT="$T/repos" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_BOX=test-box JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt"
    bash "$DIR/bin/run-build.sh" x-os "${key#TK-}" "$key" >/dev/null 2>&1 )
  echo $?
}
req() { grep -c "^$1 https://jobs.invalid$2" "$T/req.txt" 2>/dev/null | head -1; }
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2 " "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'
}
# TEST-CHANGE (flake fix): read the NEWEST build dir. run-build.sh names the
# dir to the minute, so two builds that straddle a minute boundary leave two
# dirs, and `cat dir*/RESULT | head -1` answered the OLDER run's RESULT.
result_of() { local d; d=$(ls -1d "$T/h/builds/x-os-$1-"* 2>/dev/null | tail -1); [ -n "$d" ] && head -1 "$d/RESULT" 2>/dev/null; }
clean() { rm -rf "$T/h/builds"/* "$T/h/state/build-queue" "$T/h/logs"/*; }

# ══ 1. THE FLY ENQUEUE — the row carries it ═════════════════════════════════
# CONTRACT CHANGED 2026-09-11, and this section changed with it rather than
# being deleted. It used to assert that a watcher wrote the queue FILE as well
# as the row ("it is still the queue"). Writing that file is the entire reason
# the hub holds ssh into every box, so once the row is landing the file is no
# longer written and section 1b below asserts its ABSENCE. What has not changed,
# and is still asserted here, is the body of the row and the rc/RESULT contract.
touch "$T/h/flags/builder-fly-x-os"
RC=$(build ok TK-9)
[ "$RC" = 0 ] && ok || bad "the QUEUED_FLY branch must exit 0, got $RC"
case "$(result_of TK-9)" in QUEUED_FLY*) ok ;; *) bad "expected a QUEUED_FLY result, got '$(result_of TK-9)'" ;; esac
B=$(body_of POST /api/queue)
[ "$(jq -r .project <<<"$B")" = x-os ] && ok || bad "the enqueue must name the project, got: $B"
[ "$(jq -r .key <<<"$B")" = TK-9 ] && ok || bad "the KEY is the row's identity — the same one the FILE is named for, got: $B"
[ "$(jq -r .target <<<"$B")" = fly ] && ok || bad "a QUEUED_FLY enqueue must be target=fly, got: $B"
[ "$(jq -r .ticket_id <<<"$B")" = 9 ] && ok || bad "the ticket_id must ride along for the launch, got: $B"

# FAIL OPEN. With the worker unreachable the file IS written (that is the outage
# fallback, and 1b asserts it is loud), the RESULT is the same, and the rc is the
# same. A coordination DB that can stop a build from being queued is worse than
# no coordination DB.
clean
RC=$(build down TK-9)
[ "$RC" = 0 ] && ok || bad "with the worker down the enqueue must still exit 0, got $RC"
[ -f "$T/h/state/build-queue/x-os/TK-9.json" ] && ok || bad "with the worker down the queue file must still be written"
case "$(result_of TK-9)" in QUEUED_FLY*) ok ;; *) bad "with the worker down the RESULT must be unchanged, got '$(result_of TK-9)'" ;; esac

# The file queue's own dedup still runs FIRST and still short-circuits, so a
# second enqueue of a key already queued does not even reach the wire.
RC=$(build ok TK-9)
[ "$RC" = 0 ] && ok || bad "a duplicate enqueue must exit 0, got $RC"
case "$(result_of TK-9)" in *"already queued"*) ok ;; *) bad "the file dedup must still short-circuit, got '$(result_of TK-9)'" ;; esac
rm -f "$T/h/flags/builder-fly-x-os"
clean

# ══ 1b. ON A WATCHER, THE ROW REPLACES THE BOX FILE ═════════════════════════
# state/build-queue/<p>/<KEY>.json on a watcher is the whole reason the hub
# holds ssh into every box: a queue living on a box can only be read by reaching
# into the box. With the row written there is nothing for that hop to carry, so
# the file is not written at all.
touch "$T/h/flags/builder-fly-x-os"
clean
RC=$(build ok TK-9)
[ "$RC" = 0 ] && ok || bad "the watcher enqueue must still exit 0, got $RC"
case "$(result_of TK-9)" in QUEUED_FLY*) ok ;; *) bad "the RESULT must still be QUEUED_FLY, got '$(result_of TK-9)'" ;; esac
[ ! -f "$T/h/state/build-queue/x-os/TK-9.json" ] \
  && ok || bad "THE POINT: with the row written, a watcher must leave no box file for the hub to ssh for"
[ -z "$(ls -A "$T/h/state/build-queue/x-os" 2>/dev/null)" ] \
  && ok || bad "the queue directory must be EMPTY: $(ls -A "$T/h/state/build-queue/x-os" 2>/dev/null)"
B=$(body_of POST /api/queue)
[ "$(jq -r .key <<<"$B")" = TK-9 ] && ok || bad "the row must still carry the key, got: $B"
grep -q 'no box file written' "$T/h/logs/x-os.log" 2>/dev/null \
  && ok || bad "the tick must say the row carries it: $(cat "$T/h/logs/x-os.log" 2>/dev/null)"

# A DUPLICATE row (the build was already queued) is equally "the row exists",
# so it must not fall back to writing a file either.
clean
RC=$(build dup TK-9)
[ ! -f "$T/h/state/build-queue/x-os/TK-9.json" ] \
  && ok || bad "a duplicate row means the row EXISTS — no box file should be written"

# THE FALLBACK IS FOR AN OUTAGE ONLY, AND IT IS LOUD. A silent fallback is how
# the fleet drifts back onto the ssh path with nobody noticing: the build still
# runs, so nothing else would ever say so.
# The per-day flag is cleared first because THIS case is about what the alert
# SAYS; §1c below is the one that tests how often it is said.
clean
rm -f "$T/h/flags"/alerted-queue-row-*
RC=$(build down TK-9)
[ "$RC" = 0 ] && ok || bad "with the DB down the enqueue must still exit 0, got $RC"
[ -f "$T/h/state/build-queue/x-os/TK-9.json" ] \
  && ok || bad "with the DB down the box file MUST be written — the build must not be lost"
grep -q 'QUEUE ROW REFUSED OR UNREACHABLE' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the fallback must ALERT, not fall back silently: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'NOT lost' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the alert must say the build is not lost, or it reads as a dropped build"

# THE HUB IS UNCHANGED: its file is the local queue bin/fly-pool.sh drains, not
# an ssh hop, so nothing about it moves in this change.
clean
: > "$T/h/env/fly.env"
RC=$(build ok TK-9)
[ -f "$T/h/state/build-queue/x-os/TK-9.json" ] \
  && ok || bad "the HUB must still write its local queue file — the pool drains that directory"
rm -f "$T/h/env/fly.env"
rm -f "$T/h/flags/builder-fly-x-os"
clean

# ══ 1c. THE OUTAGE ALERT PAGES ONCE PER PROJECT PER DAY ════════════════════
# A D1 outage is a per-BOX condition, not a per-build one: every build queued
# while it lasts would page the identical sentence, so a wave of five tickets
# would send five copies. The FILE short-circuit is untouched and every affected
# build is still named in the project log.
touch "$T/h/flags/builder-fly-x-os"
clean
rm -f "$T/h/flags"/alerted-queue-row-*
build down TK-1 >/dev/null
build down TK-2 >/dev/null
build down TK-3 >/dev/null
N=$(grep -c 'QUEUE ROW REFUSED OR UNREACHABLE' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] && ok || bad "three builds during one outage must page ONCE, got $N"
for K in TK-1 TK-2 TK-3; do
  [ -f "$T/h/state/build-queue/x-os/$K.json" ] \
    || bad "the file fallback must still run for every build during the outage ($K)"
done
ok
NL=$(grep -c 'QUEUE ROW REFUSED OR UNREACHABLE' "$T/h/logs/x-os.log" 2>/dev/null || echo 0)
[ "$NL" = 3 ] \
  && ok || bad "every affected build must still be named in the project log, got $NL"
ls "$T/h/flags"/alerted-queue-row-x-os-* >/dev/null 2>&1 \
  && ok || bad "the dedupe must be a per-day flag, like every other daily alert here"
rm -f "$T/h/flags"/alerted-queue-row-*
build down TK-4 >/dev/null
N=$(grep -c 'QUEUE ROW REFUSED OR UNREACHABLE' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 2 ] && ok || bad "a new day (a fresh flag) must page again, got $N"
rm -f "$T/h/flags/builder-fly-x-os"
clean

# ══ 2. THE LOCAL LAUNCH — claim, then close with the same verdict ═══════════
# No fly flag: this box builds. The pipeline is driven to its worktree setup,
# which cannot succeed on a scratch tree, so it lands BUILD_DEFERRED — the exact
# path that must put the queue row BACK rather than mark it finished.
RC=$(build ok TK-9)
[ "$RC" = 3 ] && ok || bad "a scratch tree must land BUILD_DEFERRED (rc 3), got $RC"
case "$(result_of TK-9)" in BUILD_DEFERRED*) ok ;; *) bad "expected BUILD_DEFERRED, got '$(result_of TK-9)'" ;; esac
[ "$(req POST /api/queue/claim)" -ge 1 ] && ok || bad "the local launch must claim its queue row: $(cat "$T/req.txt")"
B=$(body_of POST /api/queue/claim)
[ "$(jq -r .key <<<"$B")" = TK-9 ] && ok || bad "the local claim must name THIS key, not take the oldest, got: $B"
[ "$(jq -r .box <<<"$B")" = test-box ] && ok || bad "the claiming box must be recorded, got: $B"
B=$(body_of PATCH /api/queue)
[ "$(jq -r .status <<<"$B")" = queued ] && ok || bad "a DEFERRED build must put its row back to queued — it is re-offered next tick, not finished. Got: $B"

# A REFUSED queue claim must never stop the build: job_open is the authority for
# whether this work may run, and a second refusal path here could only ever turn
# a legitimate build into a no-op.
clean
RC=$(build taken TK-9)
[ "$RC" = 3 ] && ok || bad "a taken queue row must not change the pipeline's rc, got $RC"
case "$(result_of TK-9)" in BUILD_DEFERRED*) ok ;; *) bad "a taken queue row must not change the RESULT, got '$(result_of TK-9)'" ;; esac
grep -q "queue row was taken" "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a lost queue claim must say so once: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
# ...and having claimed nothing, it must not close a row it does not hold.
[ "$(req PATCH /api/queue)" = 0 ] && ok || bad "a build that never claimed the row must not mark it finished"

# With the worker down the local path is byte-identical to today.
clean
RC=$(build down TK-9)
[ "$RC" = 3 ] && ok || bad "with the worker down the local path must be unchanged (rc 3), got $RC"
case "$(result_of TK-9)" in BUILD_DEFERRED*) ok ;; *) bad "with the worker down the RESULT must be unchanged, got '$(result_of TK-9)'" ;; esac


# ══ 4. THE TRIAGE TICK READS THE QUEUE FROM THE DB ══════════════════════════
# The queue-pending scope listed a DIRECTORY, so a session could only ever see
# the builds queued on ITS OWN box. The rows are the same entries fleet-wide,
# plus the two things a filename could not carry: which target is expected to
# run it and how many attempts it has already had.
mkdir -p "$T/h/prompts" "$T/h/catalog/agent-contracts" "$T/h/state/build-queue/x-os"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$T/h/catalog/agent-contracts/"
cp "$DIR/bin/triage-contract.sh" "$T/h/bin/"
printf 'SOP BODY\n' > "$T/h/prompts/x-os.md"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN queue-pending"\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/h/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/decision-log.sh"
cat > "$T/h/bin/agent-call.sh" <<'AC'
#!/bin/bash
printf '%s' "${6:-}" > "$HARNESS/state/last-prompt.txt"
printf 'tickets=0\n' > "${5:-/dev/null}"
exit 0
AC
chmod +x "$T/h/bin/triage-gate.sh" "$T/h/bin/gate-diff.sh" "$T/h/bin/beat.sh" \
         "$T/h/bin/decision-log.sh" "$T/h/bin/agent-call.sh" "$T/h/bin/triage-contract.sh"
# A file in the directory AND a different key in the DB, so the assertions below
# cannot pass by accident on the fallback.
printf '{"key":"FILE-ONLY"}\n' > "$T/h/state/build-queue/x-os/FILE-ONLY.json"

triage() { # triage <curl-mode>
  : > "$T/req.txt"; rm -f "$T/h/state/last-prompt.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           JOBS_BEAT_SECS=3600 CURL_MODE="$1" REQ_SINK="$T/req.txt"
    bash "$DIR/bin/run-triage.sh" x-os >/dev/null 2>&1 )
  cat "$T/h/state/last-prompt.txt" 2>/dev/null
}

P=$(triage queuerows)
grep -q 'TK-77' <<<"$P" && ok || bad "the tick scope must carry the DB's queued builds"
grep -q 'target fly' <<<"$P" && ok || bad "a row carries what a filename could not — the target it is queued for"
grep -q 'attempt 1' <<<"$P" && ok || bad "a row carries the attempt count, so a re-queued build is visible as one"
grep -q 'FILE-ONLY' <<<"$P" && bad "with rows present the directory must not also be listed — two queue notions is the thing being removed" || ok

# FAIL OPEN, both ways. An unreachable worker AND an empty table (which is what
# the transition looks like until the producers land) both fall straight back to
# the directory this line has always listed.
# TEST-CHANGE BH-4153: with the worker down and nothing cached, paused-x-os is
# unknown and fails closed (plan Decision 7). A box that has read its pause once
# has a cached "off", which is the state this fallback is about.
mkdir -p "$T/h/state/flags-cache/fleet"
printf '%s\n' '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":1700000000}' \
  > "$T/h/state/flags-cache/fleet/paused-x-os"
P=$(triage down)
grep -q 'FILE-ONLY' <<<"$P" && ok || bad "with the worker down the tick must fall back to the queue directory"
P=$(triage ok)
grep -q 'FILE-ONLY' <<<"$P" && ok || bad "with an EMPTY table the tick must fall back to the queue directory"

# ══ 3. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log under logs/" || ok
grep -rq test-secret "$T/h/builds" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a build record" || ok

echo "queue-producers-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

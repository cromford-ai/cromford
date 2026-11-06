#!/bin/bash
# tests/resume-dead-builds-test.sh — assertions for the dead-build resume pass,
# which lives in bin/lib/resume-dead.sh since BH-1031 (state→DB slice 6) folded
# bin/resume-dead-builds.sh into bin/jobs-watchdog.sh. The FILE NAME is kept on
# purpose: these are the assertions that lane arrived with, and they are about
# behaviour the fold preserved, not about which script a cron line names.
#
# WHAT THE FOLD CHANGED, and therefore what changed here: death used to be a free
# flock plus twenty quiet minutes, and the twenty-minute quiet window is gone —
# it was true of a perfectly healthy build whose agent was thinking. The JOB ROW
# replaces it: a claim that is running and beating is alive.
#
# THE LOCK STAYED (round 1 on #1150). It answers a different question from the
# row and is ground truth for the one machine that can hold it, so it is the
# local pre-check in front of the ledger test rather than a second detector:
# the row cannot see a live build whose claim the hub orphaned after a worker
# blip, and relaunching that build writes a false verdict into a live dir.
#
# Added on top, because the row makes them possible: a ledger that cannot answer
# must judge NOTHING, a worker that parks the row writes the terminal RESULT
# instead of relaunching, a row somebody else already settled is never
# relaunched on top of, and the row is looked up across the statuses a judged
# build actually lands in (orphaned/parked), not just `running`.
#
# Run from anywhere: tests/resume-dead-builds-test.sh   (exit 0 = all pass)
# Uses a scratch HARNESS dir + a stub run-build (RUN_BUILD env) so no real
# pipeline, LLM, or repo is touched.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the launch, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

fresh() { # fresh harness scratch dir with a stub run-build; sets T, STUB_LOG
  T=$(mktemp -d)
  export HARNESS="$T"
  mkdir -p "$T/builds" "$T/locks" "$T/logs" "$T/flags" "$T/state"
  echo 4 > "$T/flags/build-slots"
  STUB_LOG="$T/stub-calls.log"
  cat > "$T/run-build-stub.sh" <<EOF
#!/bin/bash
echo "\$RESUME_BUILD|\$1|\$2|\$3" >> "$STUB_LOG"
exit 0
EOF
  chmod +x "$T/run-build-stub.sh"
  export RUN_BUILD="$T/run-build-stub.sh"
  # free-slots stub: slots available. The seam moved from COUNT_BUILDS to
  # FREE_SLOTS on 2026-09-11 — the script no longer does the
  # build-slots-minus-running arithmetic itself, because nine prompt files and
  # four scripts were each doing their own version of it and disagreeing. The
  # stub answers in free-slots.sh's shape: the count first, then why.
  cat > "$T/free-slots-stub.sh" <<'EOF'
#!/bin/bash
echo "2 (0 build(s) running, 2 box slot(s))"
EOF
  chmod +x "$T/free-slots-stub.sh"
  export FREE_SLOTS="$T/free-slots-stub.sh"
  # THE LEDGER IS THE LIVENESS TEST NOW. The default feed answers successfully
  # with no running rows — "the ledger says nothing is building", which is what a
  # free lock and twenty quiet minutes used to stand in for. rc 0 with no output
  # is an ANSWER; rc 1 is an outage, and the cases below drive both.
  export RESUME_ROWS_CMD='true'
  export RESUME_REQUEUE_CMD='true'
}

backdate() { # backdate <age-min> <path...> — portable GNU/BSD
  local TS
  TS=$(date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 min ago" +%Y%m%d%H%M)
  shift; touch -t "$TS" "$@"
}

# mkbuild <dirname> <project> <board-id> <key> [age-min]
# THE TWO IDENTITIES ARE DIFFERENT STRINGS, always, because in production they
# are: job.json's `ticket_id` is the BOARD id run-build.sh was called with (a
# uuid on a product board, an issue number on GitHub) and `key` is the ticket
# KEY (TK-42). The job ROW's ticket_id column carries the KEY — run-build.sh
# calls job_open "$PROJECT" "$KEY" — so a fixture that puts the same string in
# both columns cannot see a pass that looks the row up by the wrong one.
mkbuild() {
  local D="$HARNESS/builds/$1"
  mkdir -p "$D"
  printf '{"project":"%s","ticket_id":"%s","key":"%s"}\n' "$2" "$3" "$4" > "$D/job.json"
  echo plan > "$D/plan.md"
  backdate "${5:-60}" "$D" "$D"/*
  echo "$D"
}

# The pass itself, sourced the way bin/jobs-watchdog.sh sources it. A subshell
# per call, so one case's seams cannot leak into the next.
RDB() { ( . "$DIR/bin/lib/resume-dead.sh"; resume_dead_pass "$@" ) 2>/dev/null; }

# 1. dead build (job.json, no RESULT, old, lock free) is selected and resumed via stub
fresh
D1=$(mkbuild p1-T-7-202608230101 p1 tid7 T-7 60)
RDB; wait_for 10 grep -q "T-7" "$STUB_LOG"   # launch is backgrounded: wait for the stub's line
grep -q "^$D1|p1|tid7|T-7$" "$STUB_LOG" 2>/dev/null && ok || bad "dead build not resumed (stub log: $(cat "$STUB_LOG" 2>/dev/null))"
[ "$(cat "$D1/resume-attempts" 2>/dev/null)" = 1 ] && ok || bad "attempt counter not written"

# 2. RESULT present -> skipped; no job.json -> skipped; too fresh -> skipped
fresh
D=$(mkbuild p1-T-1-x p1 t1 T-1 60); echo "PR_CREATED url" > "$D/RESULT"; backdate 60 "$D/RESULT"
DNJ="$HARNESS/builds/p1-T-2-x"; mkdir -p "$DNJ"; echo plan > "$DNJ/plan.md"
mkbuild p1-T-3-x p1 t3 T-3 5 >/dev/null   # only 5 min old
RDB
[ ! -s "$STUB_LOG" ] && ok || bad "terminal/fresh/no-json dir was resumed: $(cat "$STUB_LOG")"

# 3. A LIVE PIPELINE IS ONE WHOSE ROW IS BEATING -> skipped.
# The row is the fleet-wide answer the lock could never give: it is legible from
# any box, so a build whose MACHINE is gone is visible here too.
#
# It does not replace the lock (round 1 on #1150). The lock is the one thing
# that is ground truth ON THIS BOX and needs no network at all: `flock` is
# released by the kernel when the holder dies, so a held lock means a live
# process, full stop — including the case the row gets wrong, where the hub
# watchdog ORPHANED a running build's row after a worker blip and the pipeline
# is still going. Both are asked; the free one (the row) first, the one that
# costs a process last.
fresh
mkbuild p1-T-9-x p1 bid9 T-9 60 >/dev/null
export RESUME_ROWS_CMD='printf "build-p1-T-9\tp1\tbuild\texecute\tbox\TK-9\t60\t150\t3\t2026-09-19T11:59:00Z\t1\n"'
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok || bad "a build whose claim is still beating was resumed"
# ...and a row that NEVER beat is not evidence of life: that is the shape a box
# running an older bin/ leaves behind, and reading it as alive would strand the
# dir for ever.
export RESUME_ROWS_CMD='printf "build-p1-T-9\tp1\tbuild\texecute\tbox\TK-9\t60\t150\t3\t-\t1\n"'
RDB; wait_for 10 grep -q "T-9" "$STUB_LOG"
grep -q "T-9" "$STUB_LOG" 2>/dev/null && ok || bad "a claim that never beat must not read as alive"
export RESUME_ROWS_CMD='true'

# 3a. THE HELD KEY LOCK IS STILL DEATH'S VETO, and it is the ONLY probe that
# covers the case the row gets wrong. The hub watchdog orphans a claim after ten
# minutes without a beat — a worker blip does that to a build that is still
# running — and the heartbeat route never puts the row back to `running`, so
# from the row alone that live pipeline reads dead. Relaunching it makes
# run-build write BUILD_DEFERRED into the LIVE build's dir (and, six launches
# later, BUILD_DEAD), which the sweep then reports to the client's board.
# flock is released by the kernel on process death, so a held lock is a live
# process and nothing else.
fresh
mkbuild p1-T-7-x p1 t7 T-7 60 >/dev/null
python3 - "$HARNESS/locks/build-key-p1-T-7.lock" <<'PY' &   # hold it like a live pipeline
import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
time.sleep(8)
PY
HOLDER=$!
sleep 0.5
RDB; sleep 1
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ ! -s "$STUB_LOG" ] && ok || bad "a build whose key lock is HELD is alive — it was resumed anyway: $(cat "$STUB_LOG")"
[ ! -f "$HARNESS/builds/p1-T-7-x/resume-attempts" ] && ok \
  || bad "a live (locked) build must not even spend an attempt"
# ...and the lock file LEFT BEHIND by a dead process is not a held lock: the
# same dir, nobody holding it, is resumed.
RDB; wait_for 10 grep -q "T-7" "$STUB_LOG"
grep -q "T-7" "$STUB_LOG" 2>/dev/null && ok || bad "a leftover lock FILE must not read as a live process"

# 3b. THE LEDGER COULD NOT ANSWER -> nothing is judged at all. Fail-CLOSED, the
# opposite of everything else in this harness: an outage would otherwise make
# every build in the fleet look dead at once, and that storm lands exactly when
# the worker is already in trouble.
fresh
mkbuild p1-T-8-x p1 t8 T-8 60 >/dev/null
export RESUME_ROWS_CMD='false'
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok || bad "a ledger outage must not resume anything"
[ ! -f "$HARNESS/builds/p1-T-8-x/resume-attempts" ] && ok \
  || bad "a ledger outage must not spend an attempt"
export RESUME_ROWS_CMD='true'

# 4. one resume per tick: two dead builds -> only the OLDER one launches
fresh
DA=$(mkbuild p1-T-20-x p1 t20 T-20 240)
DB=$(mkbuild p1-T-21-x p1 t21 T-21 60)
RDB; wait_for 10 grep -q "T-20" "$STUB_LOG"; sleep 1   # negative window: a second launch would land here
[ "$(grep -c . "$STUB_LOG")" = 1 ] && grep -q "T-20" "$STUB_LOG" && ok \
  || bad "one-per-tick/oldest-first violated: $(cat "$STUB_LOG")"

# 5. attempt cap: attempts=2 -> BUILD_DEAD RESULT + alert, no launch
fresh
D5=$(mkbuild p1-T-30-x p1 t30 T-30 60)
echo 2 > "$D5/resume-attempts"; backdate 60 "$D5/resume-attempts" "$D5"
RDB
head -1 "$D5/RESULT" 2>/dev/null | grep -q '^BUILD_DEAD' && grep -q "T-30" "$HARNESS/logs/ALERTS.log" \
  && [ ! -s "$STUB_LOG" ] && ok || bad "cap not enforced (RESULT: $(cat "$D5/RESULT" 2>/dev/null))"

# 6. deferred resume: RESULT=BUILD_DEFERRED + attempts>0 -> RESULT cleared, attempt refunded, no launch this tick
fresh
D6=$(mkbuild p1-T-40-x p1 t40 T-40 60)
echo 1 > "$D6/resume-attempts"
echo "BUILD_DEFERRED all 4 slots busy" > "$D6/RESULT"
RDB
[ ! -f "$D6/RESULT" ] && [ "$(cat "$D6/resume-attempts")" = 0 ] && ok \
  || bad "deferred-resume not recycled (RESULT exists: $([ -f "$D6/RESULT" ] && echo yes), attempts=$(cat "$D6/resume-attempts" 2>/dev/null))"
# ...but an ORIGINAL run's BUILD_DEFERRED (no resume-attempts) is left alone
D6b=$(mkbuild p1-T-41-x p1 t41 T-41 60)
echo "BUILD_DEFERRED wip-limit" > "$D6b/RESULT"
RDB
[ -f "$D6b/RESULT" ] && ok || bad "original BUILD_DEFERRED was recycled"

# 7. fly-flagged project -> skipped (pool machinery owns those)
fresh
mkbuild p2-T-50-x p2 t50 T-50 60 >/dev/null
touch "$HARNESS/flags/builder-fly-p2"
RDB
[ ! -s "$STUB_LOG" ] && ok || bad "fly-flagged project resumed locally"

# 8. kill switch
fresh
mkbuild p1-T-60-x p1 t60 T-60 60 >/dev/null
touch "$HARNESS/flags/resume-disabled"
RDB
[ ! -s "$STUB_LOG" ] && ok || bad "kill switch ignored"

# 9. dry-run: prints candidate, launches nothing, writes nothing
fresh
D9=$(mkbuild p1-T-70-x p1 t70 T-70 60)
OUT=$(RDB --dry-run)
grep -q "RESUME $D9" <<<"$OUT" && [ ! -s "$STUB_LOG" ] && [ ! -f "$D9/resume-attempts" ] && ok \
  || bad "dry-run behavior (out: $OUT)"

# 10. slots busy -> no launch (free-slots reports none)
fresh
mkbuild p1-T-80-x p1 t80 T-80 60 >/dev/null
echo 4 > "$HARNESS/flags/build-slots"
cat > "$T/free-slots-stub.sh" <<'EOF'
#!/bin/bash
echo "0 (4 build(s) running, 4 box slot(s))"
EOF
RDB
[ ! -s "$STUB_LOG" ] && ok || bad "resumed despite full slots"

# 11. B1: COMMENTED is cleared on refund AND on relaunch — a deferred resume's
# close-out marker must not suppress the eventual real close-out.
fresh
D11=$(mkbuild p1-T-90-x p1 t90 T-90 60)
echo 1 > "$D11/resume-attempts"
echo "BUILD_DEFERRED all slots busy" > "$D11/RESULT"
touch "$D11/COMMENTED"
RDB
[ ! -f "$D11/RESULT" ] && [ ! -f "$D11/COMMENTED" ] && ok \
  || bad "refund left RESULT/COMMENTED ($(ls "$D11"))"
fresh
D11b=$(mkbuild p1-T-91-x p1 t91 T-91 60)
touch "$D11b/COMMENTED"; backdate 60 "$D11b/COMMENTED" "$D11b"
RDB; wait_for 10 grep -q "T-91" "$STUB_LOG"
grep -q "T-91" "$STUB_LOG" 2>/dev/null && [ ! -f "$D11b/COMMENTED" ] && ok \
  || bad "relaunch did not clear COMMENTED (stub: $(cat "$STUB_LOG" 2>/dev/null), commented: $([ -f "$D11b/COMMENTED" ] && echo yes))"

# 12. B2: never-refunded total counter caps permanent-deferral loops
fresh
D12=$(mkbuild p1-T-92-x p1 t92 T-92 60)
echo 0 > "$D12/resume-attempts"
echo 6 > "$D12/resume-total"
backdate 60 "$D12/resume-attempts" "$D12/resume-total" "$D12"
RDB
head -1 "$D12/RESULT" 2>/dev/null | grep -q '^BUILD_DEAD' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "total cap not enforced (RESULT: $(cat "$D12/RESULT" 2>/dev/null))"

# 13. B2: launch increments resume-total; refund decrements only resume-attempts
fresh
D13=$(mkbuild p1-T-93-x p1 t93 T-93 60)
RDB; sleep 1
[ "$(cat "$D13/resume-total" 2>/dev/null)" = 1 ] && ok || bad "resume-total not written on launch"
echo "BUILD_DEFERRED weather" > "$D13/RESULT"
RDB
[ "$(cat "$D13/resume-total" 2>/dev/null)" = 1 ] && [ "$(cat "$D13/resume-attempts")" = 0 ] && ok \
  || bad "refund touched resume-total (total=$(cat "$D13/resume-total" 2>/dev/null) attempts=$(cat "$D13/resume-attempts" 2>/dev/null))"

# 14. I3: a recorded branch whose PR already merged/open -> terminal RESULT, no relaunch.
# Through bin/lib/gh-rest.sh since round 1 on #1150 — REST, not the
# GraphQL-backed `gh pr list`, which answers an EMPTY STRING when rate-limited
# (#768) and so cannot tell "no such PR" from "come back later". The stub is a
# fake `gh` on PATH answering `gh api -i` in the shape the library parses.
gh_fix() { # gh_fix <mode: merged|open|none|ratelimited>
  fresh
  printf 'p1 owner/p1 - - 0 local\n' > "$T/fleet.conf"
  export FLEET_CONF="$T/fleet.conf"
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "$1" in
  merged) printf 'HTTP/2 200\r\n\r\n[{"html_url":"https://github.com/owner/p1/pull/9","state":"closed","merged_at":"2026-09-01T00:00:00Z"}]\n' ;;
  open)   printf 'HTTP/2 200\r\n\r\n[{"html_url":"https://github.com/owner/p1/pull/9","state":"open","merged_at":null}]\n' ;;
  none)   printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *)      printf 'HTTP/2 403\r\n\r\n{"message":"API rate limit exceeded for installation"}\n' ;;
esac
EOF
  chmod +x "$T/fakebin/gh"
  export PATH="$T/fakebin:$PATH"
  D14=$(mkbuild p1-T-94-x p1 t94 T-94 60)
  echo "ticket/t-94" > "$D14/branch"; backdate 60 "$D14/branch" "$D14"
}
gh_fix merged; RDB; sleep 1
head -1 "$D14/RESULT" 2>/dev/null | grep -q '^PR_MERGED' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "merged-PR guard (RESULT: $(cat "$D14/RESULT" 2>/dev/null), stub: $(cat "$STUB_LOG" 2>/dev/null))"
grep -q 'pull/9' "$D14/RESULT" 2>/dev/null && ok \
  || bad "the terminal RESULT must carry the PR url REST returned (got: $(cat "$D14/RESULT" 2>/dev/null))"
gh_fix open; RDB; sleep 1
head -1 "$D14/RESULT" 2>/dev/null | grep -q '^PR_CREATED' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "open-PR guard (RESULT: $(cat "$D14/RESULT" 2>/dev/null))"
gh_fix none; RDB; wait_for 10 grep -q "T-94" "$STUB_LOG"
grep -q "T-94" "$STUB_LOG" 2>/dev/null && [ ! -f "$D14/RESULT" ] && ok \
  || bad "no-PR branch should resume (stub: $(cat "$STUB_LOG" 2>/dev/null))"
# A RATE LIMIT IS NOT AN ANSWER. rc 75 from the library, nothing launched,
# nothing written, no attempt spent — the tick is skipped and tried again.
gh_fix ratelimited; RDB; sleep 1
[ ! -s "$STUB_LOG" ] && [ ! -f "$D14/RESULT" ] && [ ! -f "$D14/resume-attempts" ] && ok \
  || bad "an unverifiable PR-state read should skip conservatively"
unset FLEET_CONF

# 15. empty ticket_id in job.json -> skipped (field-shift guard)
fresh
DE="$HARNESS/builds/p1-T-95-x"; mkdir -p "$DE"
printf '{"project":"p1","ticket_id":"","key":"T-95"}\n' > "$DE/job.json"
backdate 60 "$DE/job.json" "$DE"
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok || bad "empty ticket_id not skipped"

# 16. THE ROW IS THE BOUND (BH-1031). A worker that PARKS the claim is the
# lane's retry policy saying it has paid enough for this ticket, and the honest
# outcome is the terminal RESULT the sweep reports — never a relaunch on top.
fresh
D16=$(mkbuild p1-T-96-x p1 bid96 T-96 60)
export RESUME_ROWS_CMD='printf "build-p1-T-96\tp1\tbuild\texecute\tbox\TK-96\t9000\t150\t3\t-\t3\n"'
export RESUME_REQUEUE_CMD='printf "parked\t3\t3\tretries exhausted\n"'
RDB; sleep 1
head -1 "$D16/RESULT" 2>/dev/null | grep -q '^BUILD_DEAD' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "a parked row must end in BUILD_DEAD, not a relaunch (RESULT: $(cat "$D16/RESULT" 2>/dev/null))"

# ...and `already` is the worker saying the row is no longer running and nothing
# was written — somebody else settled it. Relaunching on top of that is exactly
# the double build this pass must never cause, and it is also what makes
# "requeued once, never twice" a fact about a row instead of a race between two
# crons.
fresh
D16b=$(mkbuild p1-T-97-x p1 bid97 T-97 60)
export RESUME_ROWS_CMD='printf "build-p1-T-97\tp1\tbuild\texecute\tbox\TK-97\t9000\t150\t3\t-\t1\n"'
export RESUME_REQUEUE_CMD='printf "already\t1\t3\tthe row is no longer running\n"'
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok || bad "a row somebody else already settled must not be relaunched"
[ ! -f "$D16b/RESULT" ] && ok || bad "an already-settled row says nothing about the build dir"
export RESUME_ROWS_CMD='true'; export RESUME_REQUEUE_CMD='true'

# 16c. THE BOUND IS ONLY A BOUND IF THE ROW CAN BE FOUND (round 1 on #1150).
# A row this pass meets has almost never still `running`: run-build beats its
# claim the instant it opens, so a build that died leaves a row the watchdog has
# already moved to `orphaned` — and looking only at `running` rows meant the
# requeue (and therefore the lane's retry policy) was never consulted at all.
rows_by_status() { # rows_by_status <status> — the seam eval's this with the status
  case "${1:-}" in
    orphaned) printf "build-p1-T-95\tp1\tbuild\texecute\tbox\TK-95\t9000\t150\t3\t-\t2\n" ;;
    *) : ;;
  esac
}
fresh
D16c=$(mkbuild p1-T-95-x p1 bid95 T-95 60)
export RESUME_ROWS_CMD='rows_by_status'
export RESUME_REQUEUE_CMD='printf "queued_for_retry\t2\t3\trequeued\n"'
RDB; wait_for 10 grep -q "T-95" "$STUB_LOG"
grep -q "T-95" "$STUB_LOG" 2>/dev/null && ok \
  || bad "an orphaned row must still be resumed after the worker requeued it"
grep -q 'job build-p1-T-95' "$HARNESS/logs/resume-dead.log" 2>/dev/null && ok \
  || bad "the orphaned row's job id must reach the requeue, or the retry policy never sees this ticket: $(cat "$HARNESS/logs/resume-dead.log" 2>/dev/null)"

# ...and a row the hub already PARKED is the policy saying it has paid enough:
# the honest outcome is the terminal RESULT, never another launch.
rows_by_status() {
  case "${1:-}" in
    parked) printf "build-p1-T-94\tp1\tbuild\texecute\tbox\TK-94\t9000\t150\t3\t-\t3\n" ;;
    *) : ;;
  esac
}
fresh
D16d=$(mkbuild p1-T-94-x p1 bid94 T-94 60)
export RESUME_ROWS_CMD='rows_by_status'
export RESUME_REQUEUE_CMD='printf "already\t3\t3\tjob is parked\n"'
RDB; sleep 1
head -1 "$D16d/RESULT" 2>/dev/null | grep -q '^BUILD_DEAD' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "a parked row must end in BUILD_DEAD, not a relaunch (RESULT: $(cat "$D16d/RESULT" 2>/dev/null), stub: $(cat "$STUB_LOG"))"
export RESUME_ROWS_CMD='true'; export RESUME_REQUEUE_CMD='true'

# 16e. THE ROW IS FOUND BY THE TICKET KEY, NOT BY job.json's BOARD ID
# (round 2 on #1150). This is the whole contract between the two halves of the
# pass: bin/run-build.sh opens the claim with job_open "$PROJECT" "$KEY", so the
# row's ticket_id COLUMN is the ticket KEY — while job.json's `ticket_id` FIELD
# is the BOARD id the build was launched with (a uuid on a product board). Look
# the row up by the field and it is never found in production: the requeue is
# never asked, a hub-parked ticket is relaunched instead of ending in
# BUILD_DEAD, and every bound above is a bound over fixtures only. Driven here
# in the exact production shape — a uuid in the dir, a TK- key in the row.
fresh
D16e=$(mkbuild p1-TK-42-x p1 a1b2c3-uuid TK-42 60)
export RESUME_ROWS_CMD='printf "build-p1-TK-42\tp1\tbuild\texecute\tbox\tPB-42\t9000\t150\t3\t-\t3\n"'
export RESUME_REQUEUE_CMD='printf "parked\t3\t3\tretries exhausted\n"'
RDB; sleep 1
head -1 "$D16e/RESULT" 2>/dev/null | grep -q '^BUILD_DEAD' && [ ! -s "$STUB_LOG" ] && ok \
  || bad "the row must be found by the ticket KEY the claim carries, not by job.json's board id (RESULT: $(cat "$D16e/RESULT" 2>/dev/null), stub: $(cat "$STUB_LOG" 2>/dev/null))"
grep -q 'job build-p1-TK-42' "$HARNESS/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the parked row's job id must reach the alert: $(cat "$HARNESS/logs/ALERTS.log" 2>/dev/null)"
# ...and the liveness half is the same lookup: a BEATING row for TK-42 is this
# build, so nothing may be launched and no attempt may be spent.
fresh
D16e2=$(mkbuild p1-TK-43-x p1 d4e5f6-uuid TK-43 60)
export RESUME_ROWS_CMD='printf "build-p1-TK-43\tp1\tbuild\texecute\tbox\tPB-43\t60\t150\t3\t2026-09-19T11:59:00Z\t1\n"'
export RESUME_REQUEUE_CMD='true'
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok \
  || bad "a beating row keyed by the ticket key must read as alive: $(cat "$STUB_LOG")"
[ ! -f "$D16e2/resume-attempts" ] && ok || bad "a live build must not spend an attempt"
export RESUME_ROWS_CMD='true'; export RESUME_REQUEUE_CMD='true'

# 16f. `held` IS NOT A LICENCE TO LAUNCH (round 2 on #1150). The worker answers
# `held` when another LIVE row already owns this project+ticket ("requeuing this
# row would be a second attempt on work that has an owner") or when the row is a
# ticketless lane tick. Launching on top of that is the double build this pass
# exists to avoid: run-build's own job_open refuses (rc 9), writes
# BUILD_DEFERRED into the dead dir, and the next tick refunds the attempt but
# not resume-total — so the dir churns to BUILD_DEAD with an ALERTS line for a
# ticket that is being built right now. Treated exactly like `already`.
fresh
D16f=$(mkbuild p1-T-98-x p1 bid98 T-98 60)
export RESUME_ROWS_CMD='printf "build-p1-T-98\tp1\tbuild\texecute\tbox\TK-98\t9000\t150\t3\t-\t1\n"'
export RESUME_REQUEUE_CMD='printf "held\t1\t3\tp1/T-98 is already live as build-p1-T-98-b\n"'
RDB; sleep 1
[ ! -s "$STUB_LOG" ] && ok || bad "a held row must not be relaunched on top of its live owner: $(cat "$STUB_LOG")"
[ ! -f "$D16f/RESULT" ] && ok || bad "a held row says nothing about this build dir: $(cat "$D16f/RESULT" 2>/dev/null)"
[ ! -f "$D16f/resume-attempts" ] && ok || bad "a held row must not spend an attempt"
export RESUME_ROWS_CMD='true'; export RESUME_REQUEUE_CMD='true'

# 17. The fold is real: one detector, and the cron lines agree with it.
[ ! -e "$DIR/bin/resume-dead-builds.sh" ] \
  && ok || bad "bin/resume-dead-builds.sh is the second death detector this fold removes"
# CODE, not prose: hub.cron carries a comment saying where the line went, and
# that is correct. What must be gone is a cron line that RUNS it.
[ -z "$(grep -h 'resume-dead-builds[.]sh' "$(rendered_cron_dir)"/*.cron 2>/dev/null | grep -v '^[[:space:]]*#')" ] \
  && ok || bad "a cron line still runs the deleted script"
grep -q 'resume_dead_pass' "$DIR/bin/jobs-watchdog.sh" \
  && ok || bad "bin/jobs-watchdog.sh must run the pass it absorbed"

echo "resume-dead-builds-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]

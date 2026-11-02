#!/bin/bash
# reads-run-build: raw — BH-557: it EXECUTES the driver against a scratch $HARNESS the same way queue-producers-test.sh does, with the real stage modules beside it. See tests/rb-raw-readers-baseline/run-build-issue-stamp-test.sh.txt.
# tests/run-build-issue-stamp-test.sh — bin/run-build.sh stamps the GitHub
# issue's createdAt onto the job it opens, so the ledger can measure how long a
# ticket waited between being filed and being picked up (launch lead time).
#
# WHY DRIVEN AND NOT GREPPED. Everything that can go wrong here is control flow
# around an OPTIONAL read. `grep -q 'gh_rest GET' bin/run-build.sh` would pass
# on a version that aborts the build when GitHub answers 403, and on a version
# that hands the ledger the string "yesterday". So the real pipeline is driven,
# the POST body it actually sends is read back off a curl recorder, and the four
# ways the read can fail are each asserted to produce the SAME build outcome.
#
# curl and gh are stubbed (no network in tests) and the pipeline is driven only
# as far as its worktree setup, which fails on a scratch tree and lands the
# build in BUILD_DEFERRED — past the job_open call, which is the point.
# Run from anywhere: tests/run-build-issue-stamp-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# The stamp the fixture issue was filed at. The ONLY timestamp in this file:
# every assertion is a literal, so nothing here reads the wall clock.
FILED=2026-09-16T05:53:02Z

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state" "$T/h/env" "$T/repos/x-os" "$T/repos/app-os" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# The driver sources every bin/lib/rb/<stage>.sh off $HARNESS and exits 2 when
# one is missing (BH-478's half-synced-box guard), so the fixture box needs the
# stage modules or nothing past line 136 ever runs.
mkdir -p "$T/h/bin/lib/rb" && cp "$DIR"/bin/lib/rb/*.sh "$T/h/bin/lib/rb/"
# BH-8930: gates.sh sources its gates.d/ fragments and defers the build when
# one is missing, so the fixture box carries the directory too.
cp -r "$DIR/bin/lib/rb/gates.d" "$T/h/bin/lib/rb/"
# BH-1649: the created-at read goes through the REST library the driver sources
# off $HARNESS, so the fixture box carries it (and its etag/ledger siblings).
cp "$DIR"/bin/lib/gh-rest*.sh "$T/h/bin/lib/"
# BH-4490: the trigger actor gate fails closed when the harness cannot tell
# its own identity, so the fixture box carries the gate lib and the self-app
# trust list. No lane-gate.sh here, so HARNESS_SELF_APPS comes from the env
# (build() sets it), the way env/global.env sets it on a real box.
for s in bin/lib/trigger-actor.sh bin/lib/harness-self.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "gate ok"\nexit 0\n' > "$T/h/bin/context-gate.sh"
chmod +x "$T/h/bin/context-gate.sh"

# Two projects, because the whole point of the board_prefix column here is that
# an IN-APP board has no GitHub issue to ask about. x-os is the GitHub-Issues
# lane (prefix "-"), app-os is the in-app lane.
cat > "$T/h/fleet.conf" <<'CONF'
x-os    Org/x-os    https://x.test    -                   1 box-x 10.0.0.9
app-os  Org/app-os  https://app.test  /api/feature-board  2 box-x 10.0.0.9
CONF

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
case "$URL" in
  */api/jobs) printf '{"job":{"id":"job-1","budget_usd":50}}\n201\n' ;;
  *)          printf '{"ok":true}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# The GitHub read, stubbed three ways: answering, failing, and answering with a
# string that is not a timestamp. Every call is recorded, so "did not ask at
# all" is an assertable outcome too.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_SINK:-}" ] && printf '%s\n' "$*" >> "$GH_SINK"
# GH_FAIL fails every ISSUE read, the subject of this suite. The trigger actor
# gate's events read (BH-4490) still answers: that gate fails closed on its
# own read by design (tests/trigger-actor-gate.bh-4490-test.sh B7), and a
# deferral there would end the run before the claim this suite inspects.
case "$*" in *"/issues/"*"/events"*) ;; *) [ "${GH_FAIL:-0}" = 1 ] && exit 1 ;; esac
# GH_FAIL_FIRST=1: the FIRST issue read (the closed-issue skip's) dies, every
# later one answers — the "enqueue read failed, the metric read did not" shape.
if [ "${GH_FAIL_FIRST:-0}" = 1 ] && [ ! -e "$GH_SINK.first" ]; then : > "$GH_SINK.first"; exit 1; fi
case "$*" in
  # BH-4490: the trigger actor gate's events read. No labeled event: no trigger.
  *"/issues/"*"/events"*)
    printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/issues/"*)
    printf 'HTTP/2 200\r\n\r\n'
    if [ "${GH_BAD:-0}" = 1 ]; then printf '{"state":"open","created_at":"yesterday"}\n'
    else printf '{"state":"open","created_at":"%s"}\n' "${GH_STAMP:-2026-09-16T05:53:02Z}"; fi ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# flock is stubbed for the same reason curl is: what is driven here is the
# pipeline's control flow, not the OS's locking.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/flock"

# The pool's live-token lib, stubbed so that ARMING is observable in the same
# sink as the gh calls: every other gh spend in the driver re-mints the minute-0
# token first, and a metric read that skips it records `unknown` on any box
# whose token has aged out — silently, because the read fails open.
cat > "$T/h/bin/lib/gh-token-live.sh" <<'EOF'
gh_token_live() { [ -n "${GH_SINK:-}" ] && printf 'LIVE %s\n' "${1:-}" >> "$GH_SINK"; return 0; }
EOF

# build <project> <key> -> the pipeline's rc. Requests land in $T/req.txt, gh
# calls in $T/gh.txt. GH_FAIL / GH_BAD are read from the caller's environment.
build() {
  local project="$1" key="$2"
  : > "$T/req.txt"; : > "$T/gh.txt"; rm -f "$T/gh.txt.first"
  # REPO_SLUG is unset because a builder box exports it and this suite must
  # resolve the slug from its OWN fleet.conf — an ambient value would make the
  # "asks GitHub for the right repo" assertion pass or fail on whose shell ran it.
  ( unset REPO_SLUG
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" REPOS_ROOT="$T/repos" \
           FLEET_CONF="$T/h/fleet.conf" HARNESS_SELF_APPS="cromford-builders" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_BOX=test-box JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           REQ_SINK="$T/req.txt" GH_SINK="$T/gh.txt" GH_ETAG=0 \
           GH_FAIL="${GH_FAIL:-0}" GH_BAD="${GH_BAD:-0}" GH_FAIL_FIRST="${GH_FAIL_FIRST:-0}"
    [ -n "${ISSUES_REPO:-}" ] && export GH_ISSUES_REPO="$ISSUES_REPO"
    bash "$DIR/bin/run-build.sh" "$project" "${key#*-}" "$key" >/dev/null 2>&1 )
  echo $?
}
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2 " "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'
}
result_of() { cat "$T/h/builds/$1-$2-"*/RESULT 2>/dev/null | head -1; }
plog()      { cat "$T/h/builds/$1-$2-"*/pipeline.log 2>/dev/null; }
issue_views() { grep -cE 'api -i -X GET repos/.*/issues/[0-9]+$' "$T/gh.txt" 2>/dev/null | head -1; }
clean()     { rm -rf "$T/h/builds"/* "$T/h/state/build-queue" "$T/h/logs"/*; }

# ══ 1. A GITHUB-ISSUES PROJECT: THE STAMP RIDES THE CLAIM ═══════════════════
RC=$(build x-os TK-9)
eq "a scratch tree still lands BUILD_DEFERRED (rc 3)" "$RC" "3"
case "$(result_of x-os TK-9)" in BUILD_DEFERRED*) ok ;; *) bad "expected BUILD_DEFERRED, got '$(result_of x-os TK-9)'" ;; esac
B=$(body_of POST /api/jobs)
eq "the claim carries the issue's createdAt" "$(jq -r '.issue_created_at' <<<"$B")" "$FILED"
# ONE GET of this issue per enqueue (BH-1735). Two callers need it: the
# queue-time closed-issue skip (bin/lib/issue-state-lib.sh issue_state, REST
# since BH-1424 #1448) and, later, this metric read. The skip keeps the JSON it
# read in the build's issue memo and the metric read is served from it, so the
# issue is read exactly once and no metric read follows the skip's. Before
# BH-1735 this line was 2 and the metric read was a GET of its own.
metric_reads() {
  awk '/^LIVE Org\/x-os$/ { f = 1 } f && $0 == "api -i -X GET repos/Org/x-os/issues/9" { n++ } END { print n + 0 }' "$T/gh.txt"
}
eq "the issue is read ONCE per enqueue, for THIS issue, on the project's slug" \
   "$(grep -c "^api -i -X GET repos/Org/x-os/issues/9$" "$T/gh.txt")" "1"
eq "and it is the closed-issue skip's read: no metric GET follows it" "$(metric_reads)" "0"
eq "the build logs the stamp it sent" \
   "$(plog x-os TK-9 | grep -c "ISSUE-CREATED-AT $FILED")" "1"
eq "and says it came from the enqueue read" \
   "$(plog x-os TK-9 | grep -c 'issue created-at served from the closed-issue read')" "1"
eq "the issue memo does not outlive the stamp" \
   "$(find "$T/h/builds" -name 'issue-memo.*' | wc -l | tr -d ' ')" "0"
# ...and the token is re-armed FIRST. On a pool box the minute-0 App token has
# often aged out by the time a build claims, and this read fails open, so an
# unarmed read is not an error anyone sees — it is a column that quietly reads
# `unknown` for the whole fleet. Asserted as the line immediately before the
# read, not merely "LIVE appears somewhere", because only adjacency pins order.
arm_before_read() { # the sink line immediately preceding THIS read: the LAST
  # issue GET (the closed-issue skip's GET of the same issue comes much earlier)
  local n; n=$(grep -n -x -- 'api -i -X GET repos/Org/x-os/issues/9' "$T/gh.txt" | tail -1 | cut -d: -f1)
  [ -n "$n" ] && [ "$n" -gt 1 ] && sed -n "$((n-1))p" "$T/gh.txt"
}
# (With the memo serving the stamp there is no metric read to arm in the case
# above; the arm-before-read rule is pinned on every path that DOES read: the
# skip switched off below, and §1b/§1c, where the memo cannot serve.)
# ...and the other GET really is the closed-issue skip's: with that switch off
# (its kill-switch flag), the metric read is the ONLY read of the issue.
clean; touch "$T/h/flags/skip-closed-off"
RC=$(build x-os TK-9)
eq "with the closed-issue skip off, a scratch tree still lands BUILD_DEFERRED" "$RC" "3"
eq "with the closed-issue skip off, the issue is read exactly once" \
   "$(grep -c "^api -i -X GET repos/Org/x-os/issues/9$" "$T/gh.txt")" "1"
eq "and that one read is still armed immediately before" "$(arm_before_read)" "LIVE Org/x-os"
rm -f "$T/h/flags/skip-closed-off"

# ══ 1b. THE ENQUEUE READ FAILED: THE METRIC READS FOR ITSELF ════════════════
# The memo is only ever this enqueue's successful read. When the closed-issue
# skip could not read the issue (UNKNOWN, build as today), the metric read makes
# its own armed GET and still stamps — a dead first read must not cost the
# metric.
clean
RC=$(GH_FAIL_FIRST=1 build x-os TK-9)
eq "1b: a failed enqueue read still lands BUILD_DEFERRED" "$RC" "3"
eq "1b: the metric read made its own GET (2 in all)" \
   "$(grep -c "^api -i -X GET repos/Org/x-os/issues/9$" "$T/gh.txt")" "2"
eq "1b: and it was armed immediately before" "$(arm_before_read)" "LIVE Org/x-os"
eq "1b: the claim still carries the stamp" \
   "$(jq -r '.issue_created_at' <<<"$(body_of POST /api/jobs)")" "$FILED"

# ══ 1c. A DIFFERENT ISSUE IS NEVER SERVED ═══════════════════════════════════
# The skip reads GH_ISSUES_REPO when a project sets one; the metric reads the
# build's own slug. The memo is keyed on (slug, number), so the other repo's
# issue is never taken for this one.
clean
RC=$(ISSUES_REPO=Org/tracker build x-os TK-9)
eq "1c: a split issues repo still lands BUILD_DEFERRED" "$RC" "3"
eq "1c: the skip read the issues repo" \
   "$(grep -c "^api -i -X GET repos/Org/tracker/issues/9$" "$T/gh.txt")" "1"
eq "1c: and the metric read its own slug, armed" \
   "$(grep -c "^api -i -X GET repos/Org/x-os/issues/9$" "$T/gh.txt")" "1"
eq "1c: armed immediately before" "$(arm_before_read)" "LIVE Org/x-os"

# ══ 2. GITHUB FAILS: FAIL OPEN, AND SAY SO ══════════════════════════════════
# A metric read that can stop a build is worse than no metric. The rc, the
# RESULT and the claim itself must be exactly what they are in §1.
clean
RC=$(GH_FAIL=1 build x-os TK-9)
eq "a failed gh must not change the pipeline's rc" "$RC" "3"
case "$(result_of x-os TK-9)" in BUILD_DEFERRED*) ok ;; *) bad "a failed gh must not change the RESULT, got '$(result_of x-os TK-9)'" ;; esac
B=$(body_of POST /api/jobs)
eq "no stamp is invented when the read failed" "$(jq -r 'has("issue_created_at")' <<<"$B")" "false"
eq "the log says the stamp is unknown" "$(plog x-os TK-9 | grep -c 'ISSUE-CREATED-AT unknown')" "1"

# ══ 3. GITHUB ANSWERS SOMETHING THAT IS NOT A TIMESTAMP ═════════════════════
# The regex gate is load-bearing: a string the ledger cannot parse is worse in
# the column than a null, because a null is visibly missing.
clean
RC=$(GH_BAD=1 build x-os TK-9)
eq "a garbage answer must not change the pipeline's rc" "$RC" "3"
B=$(body_of POST /api/jobs)
eq "a non-timestamp never reaches the ledger" "$(jq -r 'has("issue_created_at")' <<<"$B")" "false"
eq "and the log calls it unknown" "$(plog x-os TK-9 | grep -c 'ISSUE-CREATED-AT unknown')" "1"

# ══ 4. AN IN-APP BOARD HAS NO ISSUE TO ASK ABOUT ════════════════════════════
# Not "asks and gets nothing" — does not ask. Every build on the four in-app
# boards would otherwise spend a GitHub read to learn that GitHub has never
# heard of the ticket.
clean
RC=$(build app-os AP-4)
eq "an in-app project still lands BUILD_DEFERRED (rc 3)" "$RC" "3"
case "$(result_of app-os AP-4)" in BUILD_DEFERRED*) ok ;; *) bad "expected BUILD_DEFERRED, got '$(result_of app-os AP-4)'" ;; esac
eq "no issue is looked up for an in-app board" "$(issue_views)" "0"
B=$(body_of POST /api/jobs)
eq "and the claim carries no stamp" "$(jq -r 'has("issue_created_at")' <<<"$B")" "false"
eq "the log records the absence" "$(plog app-os AP-4 | grep -c 'ISSUE-CREATED-AT unknown')" "1"

# ══ 5. THE CLAIM BLOCK DOES NOT REQUIRE THE STAMP TO BE SET ════════════════
# tests/claim-rules-test.sh extracts `if command -v job_open ... fi` out of the
# driver and sources it under `set -u` with only the pipeline's identity vars
# defined — the same contract `${RUNNER_PLAN:-claude}` beside it already obeys.
# An unguarded $ISSUE_CREATED_AT there turns a REFUSED claim from "defer, rc 3"
# into "unbound variable, rc 1": the refusal stops being reversible and the
# ticket's RESULT never gets written. Pinned here, at the ticket that added the
# variable, so the guard cannot be dropped without this suite saying so.
clean
. "$DIR/tests/lib/rb-all.sh" || exit 1
RBALL=$(rb_all "$DIR" "$T/rb-all.txt") || bad "rb_all could not flatten the pipeline"
awk '/^if command -v job_open/,/^fi$/' "$RBALL" > "$T/claim-block.sh"
grep -q 'job_open "$PROJECT"' "$T/claim-block.sh" \
  && ok || bad "could not extract the claim block from the pipeline — this step would test nothing"
mkdir -p "$T/h/builds/none"
# The block ends in `exit 3`, so its rc is the SUBSHELL's rc — a command
# substitution here would swallow it with the exit.
( set -uo pipefail
  PROJECT=x-os; KEY=TK-9; TICKET=9
  BUILD="$T/h/builds/none"; ALERTS="$T/h/logs/ALERTS.log"
  STAMP() { echo run; }
  RESULT() { echo "$*" > "$BUILD/RESULT"; }
  job_open() { printf 'REFUSED ticket :: ticket max 1 already running'; return 9; }
  . "$T/claim-block.sh" ) >/dev/null 2>"$T/setu.txt"; RC=$?
grep -q 'ISSUE_CREATED_AT: unbound variable' "$T/setu.txt" 2>/dev/null \
  && bad "the claim block dies under set -u when the stamp was never set: $(cat "$T/setu.txt")" || ok
eq "a refused claim still defers with rc 3" "$RC" "3"
grep -q '^BUILD_DEFERRED REFUSED ticket' "$T/h/builds/none/RESULT" 2>/dev/null \
  && ok || bad "the deferral RESULT was not written: $(cat "$T/h/builds/none/RESULT" 2>/dev/null)"

# ══ 6. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log under logs/" || ok
grep -rq test-secret "$T/h/builds" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a build record" || ok

echo "run-build-issue-stamp-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

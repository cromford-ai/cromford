#!/bin/bash
# tests/run-decompose.bh-1341-test.sh — GitHub-Issues decomposition lane resume.
#
# WHY. A partial split that fails mid-loop used to be treated as complete on
# rerun: bin/run-decompose.sh exited 0 whenever children.txt was non-empty,
# and bin/lib/fc-issues.sh truncated children.txt at the start of every run.
# This suite drives the real production entry point, stubs gh to fail on child 2,
# and asserts that reruns file only the missing children idempotently.
#
# No network, no model, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/run-decompose.bh-1341-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
[ -x "$DEC" ] && ok || bad "bin/run-decompose.sh is missing or not executable"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -  9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"

cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

SPEC='[
 {"title":"metrics table + read API","contract":"src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics","after":[],"body":"Create the table and the read endpoint.\n\nFiles: src/db/metrics.ts, src/api/metrics.ts\nTests: tests/metrics.test.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[1],"body":"Render the tile against the read API.\n\nFiles: src/app/dashboard/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"weekly digest email","after":[],"body":"Send the digest.\n\nFiles: src/jobs/digest.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'

export TITLE0='TK-552.0: contract — metrics table + read API'
export TITLE1='TK-552.1: dashboard tile'
export TITLE2='TK-552.2: weekly digest email'

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" post "$@" && exit 0
echo "$*" >> "$GH_CALLS"
# A REAL kill of the run-decompose process, not a simulated one: the resume
# record has to survive a container that goes away mid-loop, so the suite takes
# the process away mid-loop.
#
# NO WAIT IS NEEDED AND NONE IS RACY. run-decompose called this stub inside a
# command substitution, so it is blocked in wait() on this very process and runs
# no further line until this one exits. kill(2) has the SIGKILL pending on it
# before it returns here, and SIGKILL cannot be trapped or ignored — so the
# parent can never reach the code after its gh call, whatever the scheduler
# does. Sleeping to "let the kill land" would be the race, not the fix.
KILL_DRIVER() {
  local pid; pid=$(cat "${DRIVE_PIDFILE:-/dev/null}" 2>/dev/null)
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  exit 137
}
case "$1 $2" in
  "issue view")
    ISSUE="$3"
    # The real gh -q flag extracts a field from the JSON; simulate it.
    if grep -qF '.title' <<<"$*"; then
      # A transport failure of the title read: gh exits non-zero and prints
      # nothing. This is the ordinary transient (502, rate limit, token blip) a
      # rerun meets, and it must never be read as "the title differs".
      [ "${GH_FAIL_MODE:-}" = "view-fail" ] && exit 1
      [ "${GH_FAIL_MODE:-}" = "kill-on-view-702" ] && [ "$ISSUE" = "702" ] && KILL_DRIVER
      case "$ISSUE" in
        701) printf '%s\n' "$TITLE0" ;;
        702) printf '%s\n' "$TITLE1" ;;
        703) printf '%s\n' "$TITLE2" ;;
        *)   printf 'unknown\n' ;;
      esac
    fi
    ;;
  "issue create")
    TITLE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) TITLE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "${GH_FAIL_MODE:-}" = "kill-on-create-child3" ] && [ "$TITLE" = "$TITLE2" ] && KILL_DRIVER
    case "$TITLE" in
      "$TITLE0") echo "https://github.com/example-org/scoutish/issues/701" ;;
      "$TITLE1")
        if [ "${GH_FAIL_MODE:-}" = "fail-child2" ] || [ "${GH_FAIL_MODE:-}" = "fail-child2-again" ]; then
          echo "gh: HTTP 401: Bad credentials"; exit 1
        else
          echo "https://github.com/example-org/scoutish/issues/702"
        fi ;;
      "$TITLE2") echo "https://github.com/example-org/scoutish/issues/703" ;;
    esac ;;
  "issue comment"|"issue edit") echo "ok" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

_drive() {
  local mode="$1"; shift
  mkdir -p "$T/b"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300; files=18>12\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  # Every artifact this run is judged on starts empty, so a later assertion can
  # never pass on a line an earlier section wrote.
  : > "$T/agent.log"; : > "$T/gh.calls"; : > "$T/drive.pid"
  : > "$T/b/pipeline.log"; : > "$T/b/decompose-run.txt"
  # exec so the recorded pid IS the run-decompose process the gh stub kills.
  env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" GH_CALLS="$T/gh.calls" \
      GH_FAIL_MODE="$mode" DRIVE_PIDFILE="$T/drive.pid" PATH="$T/fakebin:$PATH" "$@" \
      bash -c 'echo $$ > "$DRIVE_PIDFILE"; exec "$0" scoutish 552 TK-552 "$1" 300 12' "$DEC" "$T/b" 2>&1
}

# creates_so_far — how many `gh issue create` calls the run under test made.
_creates() { grep -c '^issue create' "$T/gh.calls"; }
# record_is <expected-comma-list> — children.txt as the sweep would read it.
_record() { paste -sd, "$T/b/children.txt" 2>/dev/null; }

# ===========================================================================
# 1. first run: child 2 fails, child 1 is filed, exit is non-zero
# ===========================================================================
OUT=$(_drive fail-child2); RC=$?
[ "$RC" -ne 0 ] && ok || bad "first run with child 2 failing must exit non-zero (rc=$RC)"
[ "$(paste -sd, "$T/b/children.txt")" = "TK-701" ] \
  && ok || bad "children.txt must hold exactly the contract child after first failure (got: $(paste -sd, "$T/b/children.txt"))"
grep -q 'DECOMPOSE_FAILED:' "$T/b/decompose-run.txt" \
  && ok || bad "decompose-run.txt must carry a DECOMPOSE_FAILED line (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"
grep -q 'missing children:' "$T/b/decompose-run.txt" \
  && ok || bad "DECOMPOSE_FAILED line must name the still-missing children (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"
[ "$(grep -c '^issue create' "$T/gh.calls")" -eq 2 ] \
  && ok || bad "first run must issue exactly two creates before failing (got: $(grep -c '^issue create' "$T/gh.calls"))"
grep -q '^issue comment' "$T/gh.calls" \
  && bad "parent must not be commented after a partial split" || ok
grep -q 'remove-label' "$T/gh.calls" \
  && bad "parent must keep its ai-build label after a partial split" || ok

# Keep the build dir (children.txt + children.json) for the resume runs.

# ===========================================================================
# 2. resume: child 2 and 3 are filed, child 1 is skipped, exit is 0
# ===========================================================================
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "resume run must exit 0 (rc=$RC): $OUT"
[ "$(paste -sd, "$T/b/children.txt")" = "TK-701,TK-702,TK-703" ] \
  && ok || bad "resume must file all three children (got: $(paste -sd, "$T/b/children.txt"))"
RESUME_CREATES=$(grep -c '^issue create' "$T/gh.calls")
[ "$RESUME_CREATES" -eq 2 ] \
  && ok || bad "resume must create exactly the two missing children (creates=$RESUME_CREATES)"
# child 1 was verified, not created
! grep -qF 'metrics table + read API' "$T/gh.calls" && ok || bad "resume must not create the contract child again"
grep -q '^issue comment' "$T/gh.calls" \
  && ok || bad "parent must be commented once the split completes"
grep -q 'remove-label' "$T/gh.calls" \
  && ok || bad "parent must lose its ai-build label once the split completes"

# ===========================================================================
# 3. resume still failing: child 2 still fails, children.txt unchanged
# ===========================================================================
# Reset to the partial state from section 1.
printf 'TK-701\n' > "$T/b/children.txt"
OUT=$(_drive fail-child2-again); RC=$?
[ "$RC" -ne 0 ] && ok || bad "still-failing resume must exit non-zero (rc=$RC)"
[ "$(paste -sd, "$T/b/children.txt")" = "TK-701" ] \
  && ok || bad "children.txt must be unchanged when child 2 still fails (got: $(paste -sd, "$T/b/children.txt"))"
grep -q 'DECOMPOSE_FAILED:' "$T/b/decompose-run.txt" \
  && ok || bad "still-failing run must write DECOMPOSE_FAILED (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"
[ "$(grep -c '^issue create' "$T/gh.calls")" -eq 1 ] \
  && ok || bad "still-failing resume must attempt only child 2 (creates=$(grep -c '^issue create' "$T/gh.calls"))"

# ===========================================================================
# APPEND-ONLY RESUME (review of PR #1400, round 1).
#
# children.txt is the ONLY record that a child was filed on the client's repo.
# The resume path used to read it, truncate it, and rebuild it line by line as
# each child was re-proven — so any transient failure or kill between the
# truncation and the last line erased children that really exist, and the next
# rerun filed a second set of issues on someone's repo. The record is now
# append-only: a recorded child is proven and left exactly as written, only a
# newly filed ordinal is appended, and every failure to prove one leaves the
# file byte-identical. These cases hold that line.
# ===========================================================================

# ---------------------------------------------------------------------------
# 4. a rerun on a COMPLETE split files nothing, exits 0, and says so
# ---------------------------------------------------------------------------
printf 'TK-701\nTS-702\nTS-703\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "complete rerun must exit 0 (rc=$RC): $OUT"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "complete rerun must file nothing (creates=$(_creates))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "complete rerun must leave children.txt byte-identical (got: $(_record))"
grep -q 'nothing re-filed' "$T/b/pipeline.log" \
  && ok || bad "complete rerun must log that it re-filed nothing"
grep -q '^issue comment' "$T/gh.calls" \
  && bad "complete rerun must not re-comment the parent" || ok

# ---------------------------------------------------------------------------
# 5. a `gh issue view` TRANSPORT failure mid-rerun: fail closed, record intact
#    (the review's reproduction: a 502 on the title read erased the record)
# ---------------------------------------------------------------------------
printf 'TK-701\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive view-fail); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a view failure on a recorded child must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "a view failure must file nothing (creates=$(_creates))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "a view failure must leave children.txt byte-identical (got: '$(_record)')"
grep -q 'cannot read issue #701' "$T/b/decompose-run.txt" \
  && ok || bad "a view failure must read as unreadable, not as a title mismatch (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"

# ---------------------------------------------------------------------------
# 6. a TITLE/ORDINAL mismatch on a recorded child: fail closed, record intact
# ---------------------------------------------------------------------------
printf 'TK-799\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a title mismatch on a recorded child must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "a title mismatch must file nothing (creates=$(_creates))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "a title mismatch must leave children.txt byte-identical (got: '$(_record)')"
grep -q 'title does not match' "$T/b/decompose-run.txt" \
  && ok || bad "a title mismatch must say so (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"

# ---------------------------------------------------------------------------
# 7. a real KILL after child 2 of 3, then a rerun that is itself killed, then a
#    rerun that files EXACTLY the missing child — and no child is filed twice
# ---------------------------------------------------------------------------
: > "$T/b/children.txt"
OUT=$(_drive kill-on-create-child3); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a killed run must not report success (rc=$RC)"
[ "$(_record)" = "TK-701,TK-702" ] \
  && ok || bad "a kill during child 3 must leave children 1 and 2 on the record (got: '$(_record)')"
cp "$T/b/children.txt" "$T/ref.txt"

# The rerun dies while re-proving child 2. Nothing it did may touch the record.
OUT=$(_drive kill-on-view-702); RC=$?
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "a kill while re-proving child 2 must leave children.txt byte-identical (got: '$(_record)')"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "a rerun killed during verification must have filed nothing (creates=$(_creates))"

# And now the rerun that completes it.
OUT=$(_drive succeed); RC=$?
[ "$RC" -eq 0 ] && ok || bad "the completing rerun must exit 0 (rc=$RC): $OUT"
[ "$(_creates)" -eq 1 ] \
  && ok || bad "the completing rerun must file exactly the one missing child (creates=$(_creates))"
grep -qF -- "--title $TITLE0" "$T/gh.calls" \
  && bad "the contract child must never be filed a second time" || ok
grep -qF -- "--title $TITLE1" "$T/gh.calls" \
  && bad "child 2 must never be filed a second time" || ok
[ "$(_record)" = "TK-701,TK-702,TK-703" ] \
  && ok || bad "the completed record must hold each child exactly once (got: '$(_record)')"

# ---------------------------------------------------------------------------
# 8. a record LONGER than the spec is not silently trimmed
# ---------------------------------------------------------------------------
printf 'TK-701\nTS-702\nTS-703\nTS-999\n' > "$T/b/children.txt"
cp "$T/b/children.txt" "$T/ref.txt"
OUT=$(_drive succeed); RC=$?
[ "$RC" -ne 0 ] && ok || bad "a record longer than the spec must exit non-zero (rc=$RC)"
[ "$(_creates)" -eq 0 ] \
  && ok || bad "a record longer than the spec must file nothing (creates=$(_creates))"
cmp -s "$T/b/children.txt" "$T/ref.txt" \
  && ok || bad "a record longer than the spec must not be rewritten (got: '$(_record)')"
grep -q '4 children but the spec has 3' "$T/b/decompose-run.txt" \
  && ok || bad "the mismatch must name both counts (got: $(cat "$T/b/decompose-run.txt" 2>/dev/null))"

echo "run-decompose.bh-1341: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/reverse-dep-wake-test.sh — a closure is about the tickets it RELEASED.
# docs/EVENTS.md §5.4.
#
# THE TWO HOLES THIS SUITE HOLDS SHUT (the operator, 2026-09-15, both seen on project-5):
#
#   1. Every wake names the object that MOVED. When that object is an issue that
#      just closed, or the issue a merged PR closed, the one thing the tick can
#      act on is the OTHER tickets — the ones whose bodies say `Blocked-by:
#      #<it>`. #721 waited while #718, #719 and #720 all closed at 05:33Z; #671
#      waited on a #670 that had been closed by hand.
#   2. bin/run-decompose.sh parks a decomposed parent open and unlabelled, and
#      nothing ever closes it. Six were closed by hand in one day, and until
#      each one was, every ticket chained behind it stayed chained.
#
# WHAT IS STUBBED AND WHAT IS UNDER TEST. `gh` is a file-backed shim (it is the
# only thing here that would touch the network) and the owning scripts are
# recorders. The REAL bin/wake-loop.sh, bin/unblocked-children.sh,
# bin/decompose-parent-close.sh and bin/lib/revdep-lib.sh do the deciding, so
# what is exercised is the expansion itself: which keys a launch carries, which
# closure it writes for the owning box's own pass, and which parents get closed — and the
# negatives, which are the half that matters: an issue that did NOT close
# expands nothing, a parent with a live child is never closed, and a second run
# closes nothing twice.
#
# BH-2637: the loop runs on EVERY box and never ssh's. A project's wake is
# claimed and launched by its OWNING box, so the keys file, the closure file and
# the run-triage launch are all LOCAL to the box the loop runs as (BOX_NAME). The
# worker is tests/lib/wake-claim-stub.sh; every section asserts ssh is never
# called.
#
# Run from anywhere: tests/reverse-dep-wake-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
# BH-949: decompose-parent-close.sh reads the PR list and the parent over REST too.
export GH_CLI_REST_READS=1
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
mkdir -p "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"

# --- the harness tree the loop runs out of ----------------------------------
# Real scripts, every one of them: the contract under test is what they decide
# between them, and a stub of any would be a test of the stub.
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/wake-loop.sh" "$DIR/bin/unblocked-children.sh" \
   "$DIR/bin/decompose-parent-close.sh" "$DIR/bin/box-for.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/bin/lib/"
chmod +x "$T/bin/"*.sh
# BH-7919: issue_closures decides the issues lane through bin/lib/tracker.sh tracker_kind.
scratch_install_closure bin/lib/tracker.sh "$T" >/dev/null || exit 1
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "reverse-dep-wake: wcs_identity failed"; exit 1; }
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE

# project-5 is owned by box-project-5-1 (the box its sections run as),
# project-6 is `local` — the hub's (section 4 runs as the hub) — both GitHub-Issues boards, which is the only kind that has a
# Blocked-by convention at all.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-5\nproject-6\n'; exit 0; }
case "$1/$2" in
  project-5/repo)          echo example-org/project-5 ;;
  project-6/repo)          echo example-org/project-6-runtime ;;
  project-5/board_prefix)  echo - ;;
  project-6/board_prefix)  echo - ;;
  project-5/box)           echo box-project-5-1 ;;
  project-6/box)           echo local ;;
  *) exit 1 ;;
esac
SH
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
done
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
# TEST-CHANGE BH-2637: the wake routes are the claim/cursor/cooldown worker
# (tests/lib/wake-claim-stub.sh), not GET /api/wakes.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
# gh: every shape these three scripts ask for, answered from a file, so a test
# says what GitHub knows. A close WRITES — the issue reads CLOSED from then on,
# which is what makes "the second run is a no-op" a fact about state rather than
# about a marker.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
echo "$*" >> "$HARNESS/calls/gh"
case "$*" in
  # (BH-781) The parent close is TWO REST calls — the comment first, then the
  # close — through bin/lib/gh-rest.sh, which verifies the close with its own
  # re-read. The stub answers in that library's wire shape and keeps writing the
  # same artifacts the assertions below read.
  *"-X POST"*"/comments"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    bf=$(printf '%s' "$*" | sed -nE 's/.*-F body=@([^ ]+).*/\1/p')
    cat "$bf" > "$HARNESS/calls/close-comment-$n" 2>/dev/null
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"-X PATCH"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    echo "$n" >> "$HARNESS/calls/issue-close"
    printf '{"number":%s,"state":"CLOSED","title":"parent %s"}\n' "$n" "$n" > "$HARNESS/issue-$n.json"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
  # TEST-CHANGE BH-1651: closed_diff lists through gh_rest_issue_list, same fixture.
  *"-i -X GET"*"/issues"*"state=closed"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -c 'map(. + {closed_at: .closedAt})' "$HARNESS/gh-closed.json" 2>/dev/null || echo '[]' ;;
  *"-X GET"*"/issues/"*)
    n=$(printf '%s' "$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    if [ -f "$HARNESS/issue-$n.json" ]; then
      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"%s"}\n' "$(jq -r '.state | ascii_downcase' "$HARNESS/issue-$n.json")"
    else
      printf 'HTTP/2.0 404 Not Found\nx-stub: 1\n\n{"message":"Not Found"}\n'; exit 1
    fi ;;
  *"issue view"*)
    n=$(printf '%s' "$*" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    [ -f "$HARNESS/issue-$n.json" ] || { echo "gh: no issue $n" >&2; exit 1; }
    case "$*" in
      *"-q .state"*) jq -r .state "$HARNESS/issue-$n.json" ;;
      *)             cat "$HARNESS/issue-$n.json" ;;
    esac ;;
  *"pr list"*"--state merged"*)     cat "$HARNESS/gh-merged.json" 2>/dev/null || echo '[]' ;;
  *"pr list"*)                      cat "$HARNESS/prs.json"       2>/dev/null || echo '[]' ;;
  *"issue list"*"--state closed"*)  cat "$HARNESS/gh-closed.json" 2>/dev/null || echo '[]' ;;
  *"issue list"*)                   cat "$HARNESS/gh-all.json"    2>/dev/null || echo '[]' ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
command -v jq >/dev/null 2>&1 || { echo "reverse-dep-wake: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "reverse-dep-wake: python3 is required"; exit 1; }

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <kind> <key> [repo]
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"ev","at":"2026-09-15T05:33:04Z"}' \
    "$1" "${4:-example-org/project-5}" "$2" "$3"
}
reset() {
  rm -rf "$T/calls" "$T/state"; mkdir -p "$T/calls" "$T/state"
  rm -f "$T/gh-closed.json" "$T/gh-all.json" "$T/gh-merged.json" "$T/prs.json" "$T/issue-"*.json
  echo '[]' > "$T/gh-closed.json"; echo '[]' > "$T/gh-merged.json"; echo '[]' > "$T/prs.json"
}
# The launches are detached (the expansion is a gh lookup per key plus a whole
# dependency pass), so an assertion that something DID happen waits for the file
# rather than sleeping a fixed amount — a suite that goes green by luck is worse
# than no suite.
waitfor() { local i; for i in $(seq 1 60); do [ -s "$1" ] && return 0; sleep 0.25; done; return 1; }
settle()  { local prev="" cur i; for i in $(seq 1 16); do sleep 0.25
  cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
  [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0; prev="$cur"; done; return 0; }
# run [box] — the loop as <box> (default: project-5's owning box).
run() { BOX_NAME="${1:-box-project-5-1}" "$T/bin/wake-loop.sh"; settle; }
ssh_cmd() { cat "$T/calls/ssh" 2>/dev/null; }
# What the owning box's launch wrote for its own triage tick, locally.
keys_of()   { cat "$T/state/wake-keys-$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
closed_of() { cat "$T/state/wake-closed-$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# The 05:33Z wave: three blockers closed, one child that nothing ever launched.
CHAIN='[{"number":718,"state":"CLOSED","title":"TK-717.1 schema","body":"Part of #717"},
 {"number":719,"state":"CLOSED","title":"TK-717.2 ingest","body":"Part of #717\nBlocked-by: #718"},
 {"number":720,"state":"CLOSED","title":"TK-717.3 rollup","body":"Part of #717\nBlocked-by: #719"},
 {"number":721,"state":"OPEN","title":"TK-721 the screen","body":"Blocked-by: #718, #719, #720"}]'

# ---------------------------------------------------------------------------
# 1. an issue wake for an issue that CLOSED carries the tickets it released
# ---------------------------------------------------------------------------
# The whole bug in one assertion: before this, the launch carried "720" — the one
# ticket in the wave with nothing left to do — and #721 was never named.
reset
printf '%s\n' "$CHAIN" > "$T/gh-all.json"
echo '{"number":720,"state":"CLOSED","title":"TK-717.3 rollup"}' > "$T/issue-720.json"
wakes "$(W 1 issue 720)"
run
# TEST-CHANGE BH-2637: the owning box launches run-triage LOCALLY; no ssh.
waitfor "$T/calls/run-triage" || bad "an issue wake must still launch this project's triage"
grep -qx project-5 "$T/calls/run-triage" 2>/dev/null && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "the owning box must launch project-5's triage here, never over ssh: run-triage=$(cat "$T/calls/run-triage" 2>/dev/null) ssh=$(ssh_cmd)"
# TEST-CHANGE BH-2637: the keys ride in the owning box's LOCAL state file, not an ssh argv.
[ -f "$T/state/wake-keys-project-5" ] && ok || bad "the launch must still carry the wake's keys: $(keys_of project-5)"
[ "$(keys_of project-5)" = "720 721" ] && ok \
  || bad "the closed issue's Blocked-by child must be in the scope: $(keys_of project-5)"
# TEST-CHANGE BH-2637: the closure is written where the owning box's own pass reads it, locally.
[ "$(closed_of project-5)" = "720" ] && ok \
  || bad "the CLOSURE must reach the owning box's pass too — it cannot see a de-labelled close: $(closed_of project-5)"
grep -q 'ticket(s) released by the close of #720' "$T/logs/wake-loop.log" && ok \
  || bad "the expansion must say what it released: $(grep -c . "$T/logs/wake-loop.log") lines"

# ---------------------------------------------------------------------------
# 2. an issue wake for an issue that did NOT close expands nothing
# ---------------------------------------------------------------------------
# A comment, an edit and a close arrive identical (docs/EVENTS.md §3: the
# receiver keeps identifiers and nothing else), so the state is looked up — and
# an OPEN issue has released nothing, whatever its children say.
reset
printf '%s\n' "$CHAIN" > "$T/gh-all.json"
echo '{"number":721,"state":"OPEN","title":"TK-721 the screen"}' > "$T/issue-721.json"
wakes "$(W 2 issue 721)"
run
# TEST-CHANGE BH-2637: local launch on the owning box, local files, no ssh.
waitfor "$T/calls/run-triage" || bad "an issue wake on an open ticket must still launch triage"
[ "$(keys_of project-5)" = "721" ] && ok \
  || bad "an open issue's launch must carry its own key and nothing else: $(keys_of project-5)"
[ -e "$T/state/wake-closed-project-5" ] && bad "nothing closed, so no closure may be written: $(closed_of project-5)" || ok
[ ! -s "$T/calls/ssh" ] && ok || bad "the owning box's launch must never ssh: $(ssh_cmd)"

# ---------------------------------------------------------------------------
# 3. a merged PR that closed an issue the ai-build list cannot see
# ---------------------------------------------------------------------------
# closed_diff() asks for `--label ai-build --state closed`, and #670 is a
# decomposed parent: the size gate stripped that label months ago. The PR itself
# is the only thing that knows, so the merge's `closes #670` is what releases
# #671 — the CEO chain, in the shape it actually failed in.
reset
cat > "$T/gh-all.json" <<'J'
[{"number":671,"state":"OPEN","title":"TK-671 lifecycle rollup","body":"Blocked-by: #670"}]
J
printf '[{"number":880,"mergedAt":"%s","title":"TK-669.4: last slice","body":"what/why\\n\\nCloses #670","closingIssuesReferences":[{"number":670}]}]\n' "$NOW_ISO" > "$T/gh-merged.json"
wakes "$(W 3 push abc1234)"
run
# TEST-CHANGE BH-2637: the owning box launches locally and writes both files itself; no ssh.
waitfor "$T/calls/run-triage" || bad "a push whose merge closed something must launch triage on the owning box"
grep -qx '671' "$T/state/wake-keys-project-5" 2>/dev/null && ok \
  || bad "the dependents of the issue the merge closed must be in the scope: $(keys_of project-5)"
[ "$(closed_of project-5)" = "670" ] && ok \
  || bad "the merged PR's closing issue must ride as the closure: $(closed_of project-5)"
[ ! -s "$T/calls/ssh" ] && ok || bad "a push on the owning box must never ssh: $(ssh_cmd)"
[ -f "$T/calls/deploy-train" ] && ok || bad "the deploy train must still depart on the same push"

# ---------------------------------------------------------------------------
# 4. a `local` project is the hub's: it writes the same two facts where it reads them
# ---------------------------------------------------------------------------
reset
cat > "$T/gh-all.json" <<'J'
[{"number":40,"state":"CLOSED","title":"TK-40 blocker","body":""},
 {"number":41,"state":"OPEN","title":"TK-41 child","body":"Blocked-by: #40"}]
J
echo '{"number":40,"state":"CLOSED","title":"TK-40 blocker"}' > "$T/issue-40.json"
wakes "$(W 4 issue 40 example-org/project-6-runtime)"
run box-hub
waitfor "$T/calls/run-triage" || bad "a project fleet.conf says is local must be triaged here"
grep -qx '41' "$T/state/wake-keys-project-6" && ok \
  || bad "the released child must be in the local keys file: $(cat "$T/state/wake-keys-project-6" 2>/dev/null)"
grep -qx '40' "$T/state/wake-closed-project-6" && ok \
  || bad "the closure must be written where this box's own pass reads it: $(cat "$T/state/wake-closed-project-6" 2>/dev/null)"
[ ! -f "$T/calls/ssh" ] && ok || bad "a local project must never be launched over ssh"

# ---------------------------------------------------------------------------
# 5. flags/revdep-wake-off is the loop of 2026-09-14, byte for byte
# ---------------------------------------------------------------------------
reset
printf '%s\n' "$CHAIN" > "$T/gh-all.json"
echo '{"number":720,"state":"CLOSED","title":"TK-717.3 rollup"}' > "$T/issue-720.json"
touch "$T/flags/revdep-wake-off"
wakes "$(W 5 issue 720)"
run
# TEST-CHANGE BH-2637: the launch, keys and closure are local to the owning box; no ssh.
waitfor "$T/calls/run-triage" || bad "the flag must not stop the triage launch itself"
grep -qx '721' "$T/state/wake-keys-project-5" 2>/dev/null && bad "with the flag set nothing may be expanded: $(keys_of project-5)" || ok
[ -e "$T/state/wake-closed-project-5" ] && bad "with the flag set no closure may be written: $(closed_of project-5)" || ok
[ "$(keys_of project-5)" = "720" ] && [ ! -s "$T/calls/ssh" ] && ok \
  || bad "with the flag set the launch carries exactly the wake's own key, locally: keys=$(keys_of project-5) ssh=$(ssh_cmd)"
grep -q 'issue view' "$T/calls/gh" 2>/dev/null && bad "with the flag set GitHub must not even be asked for the state" || ok
rm -f "$T/flags/revdep-wake-off"

# ---------------------------------------------------------------------------
# 6. the decompose parent closes when EVERY child has closed, and says so
# ---------------------------------------------------------------------------
# The parent is unlabelled (bin/run-decompose.sh strips ai-build when it parks
# it), so it is not in the ai-build list at all and has to be fetched by number.
reset
export PARENT_CLOSE_COOLDOWN_S=0
cat > "$T/gh-all.json" <<'J'
[{"number":856,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.1 the model","body":"Part of #855\nOrder: 1 of 2"},
 {"number":857,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.2 the screen","body":"Part of #855\nOrder: 2 of 2\nBlocked-by: #856"},
 {"number":671,"state":"OPEN","title":"TK-671 lifecycle rollup","body":"Blocked-by: #855"}]
J
cat > "$T/prs.json" <<'J'
[{"number":870,"url":"https://github.com/example-org/project-5/pull/870","title":"TK-856: the model","headRefName":"ticket/TK-856","state":"MERGED"},
 {"number":871,"url":"https://github.com/example-org/project-5/pull/871","title":"TK-857: the screen","headRefName":"ticket/TK-857","state":"MERGED"}]
J
echo '{"number":855,"state":"OPEN","title":"TK-855 client dashboard","labels":[]}' > "$T/issue-855.json"
OUT=$("$T/bin/decompose-parent-close.sh" project-5 2>/dev/null)
[ "$OUT" = 855 ] && ok || bad "a parent whose every child is closed must be closed and named (got '$OUT')"
grep -qx '855' "$T/calls/issue-close" 2>/dev/null && ok || bad "the close must actually be made"
C=$(cat "$T/calls/close-comment-855" 2>/dev/null)
grep -q '#856' <<<"$C" && grep -q '#857' <<<"$C" && ok || bad "the comment must list the children: $C"
grep -q 'pull/870' <<<"$C" && grep -q 'pull/871' <<<"$C" && ok || bad "the comment must link each child's PR: $C"
grep -q 'PARENT_CLOSED #855' "$T/logs/project-5.log" && ok || bad "the close must leave a log line: $(cat "$T/logs/project-5.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 7. …and a SECOND run closes nothing: the state is what makes it idempotent
# ---------------------------------------------------------------------------
# The cooldown is disabled throughout this section on purpose — a no-op that is
# only a cooldown is not idempotence, it is a delay.
OUT=$("$T/bin/decompose-parent-close.sh" project-5 2>/dev/null)
[ -z "$OUT" ] && ok || bad "a closed parent must not be closed again (got '$OUT')"
[ "$(grep -c . "$T/calls/issue-close" 2>/dev/null || echo 0)" = 1 ] && ok \
  || bad "exactly one close, ever (got $(cat "$T/calls/issue-close" 2>/dev/null))"

# ---------------------------------------------------------------------------
# 8. one child still open = the master stays open
# ---------------------------------------------------------------------------
reset
cat > "$T/gh-all.json" <<'J'
[{"number":856,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.1 the model","body":"Part of #855"},
 {"number":857,"state":"OPEN","title":"TK-855.2 the screen","body":"Part of #855"}]
J
echo '{"number":855,"state":"OPEN","title":"TK-855 client dashboard","labels":[]}' > "$T/issue-855.json"
OUT=$("$T/bin/decompose-parent-close.sh" project-5 2>/dev/null)
[ -z "$OUT" ] && [ ! -f "$T/calls/issue-close" ] && ok \
  || bad "a split with a slice still building must never be closed (got '$OUT')"

# ---------------------------------------------------------------------------
# 9. a parent that still carries ai-build is somebody's ticket, not a master
# ---------------------------------------------------------------------------
# The label IS the handoff (prompts/project-5.md). A labelled issue is buildable
# work whatever a child's body says about it, so this pass leaves it alone.
reset
cat > "$T/gh-all.json" <<'J'
[{"number":855,"state":"OPEN","title":"TK-855 still a ticket","body":"the ask"},
 {"number":856,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.1","body":"Part of #855"}]
J
echo '{"number":855,"state":"OPEN","title":"TK-855 still a ticket","labels":[{"name":"ai-build"}]}' > "$T/issue-855.json"
OUT=$("$T/bin/decompose-parent-close.sh" project-5 2>/dev/null)
[ -z "$OUT" ] && [ ! -f "$T/calls/issue-close" ] && ok \
  || bad "a labelled parent must never be auto-closed (got '$OUT')"

# ---------------------------------------------------------------------------
# 9b. a split whose children this list cannot all carry is not a finished split
# ---------------------------------------------------------------------------
# The issue list is `--limit 1000`. A split of five whose fourth and fifth
# children fall off the end would otherwise read as "every child I can see is
# closed" — so the filer's own `Order: n of m` line is the check.
reset
cat > "$T/gh-all.json" <<'J'
[{"number":856,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.1","body":"Part of #855\nOrder: 1 of 3"},
 {"number":857,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.2","body":"Part of #855\nOrder: 2 of 3"}]
J
echo '{"number":855,"state":"OPEN","title":"TK-855 client dashboard","labels":[]}' > "$T/issue-855.json"
OUT=$("$T/bin/decompose-parent-close.sh" project-5 2>/dev/null)
[ -z "$OUT" ] && [ ! -f "$T/calls/issue-close" ] && ok \
  || bad "two of a declared three children is not a finished split (got '$OUT')"

# ---------------------------------------------------------------------------
# 10. the parent's own close releases the parent's dependents, same pass
# ---------------------------------------------------------------------------
# #671 says `Blocked-by: #855`, not `Blocked-by: #857`. Closing the master is the
# ONLY thing that can release it, and the release has to come out of the same
# dependency pass or nothing carries it to a tick.
reset
cat > "$T/gh-all.json" <<'J'
[{"number":856,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.1 the model","body":"Part of #855"},
 {"number":857,"state":"CLOSED","stateReason":"COMPLETED","title":"TK-855.2 the screen","body":"Part of #855"},
 {"number":671,"state":"OPEN","title":"TK-671 lifecycle rollup","body":"Blocked-by: #855"}]
J
cat > "$T/prs.json" <<'J'
[{"number":870,"url":"https://github.com/example-org/project-5/pull/870","title":"TK-856: the model","headRefName":"ticket/TK-856","state":"MERGED"},
 {"number":871,"url":"https://github.com/example-org/project-5/pull/871","title":"TK-857: the screen","headRefName":"ticket/TK-857","state":"MERGED"}]
J
echo '{"number":855,"state":"OPEN","title":"TK-855 client dashboard","labels":[]}' > "$T/issue-855.json"
OUT=$("$T/bin/unblocked-children.sh" project-5 </dev/null 2>/dev/null)
grep -q '^board issues: UNBLOCKED 671 .*#855 is now CLOSED' <<<"$OUT" && ok \
  || bad "closing the master must release the ticket chained behind it, in the same pass (got: $OUT)"
grep -qx '855' "$T/calls/issue-close" 2>/dev/null && ok || bad "…and the master must really be closed"
# The second pass has nothing left to close and nothing left to release: the
# child's release line is an EVENT, and the event has been carried.
: > "$T/calls/issue-close"
OUT=$("$T/bin/unblocked-children.sh" project-5 </dev/null 2>/dev/null)
[ ! -s "$T/calls/issue-close" ] && ok || bad "the second pass must close nothing"
grep -q 'is now CLOSED' <<<"$OUT" && bad "a closure already carried must not be re-announced as an event (got: $OUT)" || ok

# ---------------------------------------------------------------------------
# 11. the closure a wake shipped is read ONCE on the box, and it is the release
# ---------------------------------------------------------------------------
# state/wake-closed-<project> is the fact the ai-build fingerprint can never
# carry: on the box, with an empty diff, it is what turns "#721 is blocked" into
# an UNBLOCKED line.
reset
printf '%s\n' "$CHAIN" > "$T/gh-all.json"
printf '718\n719\n720\n' > "$T/state/wake-closed-project-5"
OUT=$("$T/bin/unblocked-children.sh" project-5 </dev/null 2>/dev/null)
grep -q '^board issues: UNBLOCKED 721 .*is now CLOSED' <<<"$OUT" && ok \
  || bad "a shipped closure must release its dependents on the box (got: $OUT)"
[ ! -f "$T/state/wake-closed-project-5" ] && ok || bad "the shipped closure must be consumed one-shot"
# …and a closure older than its window is not this tick's event either.
printf '718\n' > "$T/state/wake-closed-project-5"
touch -d '1970-01-01' "$T/state/wake-closed-project-5" 2>/dev/null || touch -t 197001020000 "$T/state/wake-closed-project-5"
OUT=$("$T/bin/unblocked-children.sh" project-5 </dev/null 2>/dev/null)
grep -q 'UNBLOCKED 721 .*is now CLOSED' <<<"$OUT" && bad "a stale closure file must not scope a later tick (got: $OUT)" || ok
[ ! -f "$T/state/wake-closed-project-5" ] && ok || bad "a stale closure file must be removed, not left to fire later"

echo "reverse-dep-wake: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

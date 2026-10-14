#!/bin/bash
# tests/merge-sweep-identity.bh-800-test.sh — BH-800: bin/merge-sweep.sh must not
# write a bare `skipped: mergeState=BLOCKED (will retry)` for a PR whose base
# branch requires nothing and whose push allow-list this identity is not on.
#
# THE INCIDENT. On 2026-09-18 the hub ran on a GitHub App installation token.
# `example-org/cromford`'s main branch requires no check and no review, but
# its protection DOES restrict who may push, and the App is not on that list.
# GitHub answers `mergeStateStatus: BLOCKED` for exactly that, so the sweep
# logged 42 identical "will retry" lines in 40 minutes for PRs that could never
# land on that identity, and nothing anywhere named the token or paged.
#
# WHAT IS ASSERTED: the sweep's own artifacts — logs/merge-sweep.log,
# logs/ALERTS.log, flags/, state/merge-sweep-done.txt and the gh calls the stub
# recorded. The sweep is copied standalone into a scratch tree and run whole,
# exactly like tests/merge-sweep-invisible-repo-test.sh does, so what is driven
# is the production entry point and not a seam (D2).
#
# Run from anywhere: tests/merge-sweep-identity.bh-800-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/bin/lib/"
# The sweep's state read goes through bin/lib/merge-conductor-lib.sh ->
# bin/lib/gh-rest.sh (BH-784), and the lib sources bin/lib/mc/*.sh (BH-680). A
# tree without them leaves the sweep's fail-closed shim answering "unverifiable"
# to every read, and every section below would be green on a sweep that never
# read a PR at all.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/lib/gh-push-identity.sh" "$T/bin/lib/" 2>/dev/null || true
# BH-1586: protection and CI reads go through gh_rest (protection via the policy
# cache; no lane-gate here, so its TTL resolves to 0 and every read is live).
cp "$DIR"/bin/lib/gh-rest*.sh "$DIR/bin/lib/gh-policy-cache.sh" "$T/bin/lib/"
for stub in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$stub"; chmod +x "$T/bin/$stub"; done
printf '#!/bin/bash\nexit 2\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") echo ts ;;
  "ts repo") echo "o/r" ;;
  "ts board_prefix") echo "/api/board" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# The gh stub. `pr view` answers whichever --json list the sweep asked for — and
# $T/prshape can force the OLD four-word answer even for the new list, which is
# what every existing sweep fixture gives this script. The protection endpoint
# answers $T/protmode with gh's real failure shape (nonzero rc, `(HTTP nnn)` on
# stderr), because that suffix is the only thing the reader may classify on.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
MSTATE=$(cat "$T/mergestate" 2>/dev/null || echo BLOCKED)
case "$*" in
  "api repos/o/r -q .id") exit 0 ;;
  "api user -q .login")   cat "$T/userlogin" 2>/dev/null; exit 0 ;;
  *"/branches/"*"/protection"*)
    MODE=$(cat "$T/protmode" 2>/dev/null || echo ok)
    # BH-1586: gh_rest reads protection, so each mode is a whole HTTP answer
    # and the reader classifies on the STATUS LINE.
    case "$MODE" in
      ok)   restpr --raw 200 "$(cat "$T/protection.json")"; exit 0 ;;
      404)  restpr --raw 404 '{"message":"Branch not protected"}'; exit 0 ;;
      403)  restpr --raw 403 '{"message":"Resource not accessible by integration"}'; exit 0 ;;
    esac ;;
  # THE STATE READ IS REST (BH-784): ONE pull object carries the state, the
  # merge state, the author, the head sha and the base that the --json arms
  # below used to answer. `restpr` (tests/lib/rest-emit.sh) prints the whole
  # HTTP response, because bin/lib/gh-rest.sh judges the STATUS LINE and not
  # gh's exit code. $T/prshape=old is the same object with NO base — GitHub
  # renders it null — which is the four-word answer BH-800's fixtures gave.
  *"api -i -X GET repos/o/r/pulls/"*"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/o/r/pulls/"*)
    if [ "$(cat "$T/prshape" 2>/dev/null)" = old ]; then
      restpr --raw 200 "$(jq -nc --arg ms "$MSTATE" \
        '{state:"open",merged_at:null,head:{sha:"headsha",ref:"ticket/x"},base:{ref:null},
          labels:[],mergeable:true,mergeable_state:($ms|ascii_downcase),
          user:{login:"operator",type:"User"},merge_commit_sha:null,body:"b",draft:false}')"
    else
      restpr OPEN headsha ticket/x main "" MERGEABLE "$MSTATE" operator
    fi ;;
  # The new read (BH-800) carries baseRefName at the END of the field list, and
  # the jq template puts it BEFORE closedAt — closedAt is empty on an open PR
  # and `read` collapses whitespace, so a field after it would shift.
  *"--json state,mergeStateStatus,author,headRefOid,closedAt,baseRefName"*)
    if [ "$(cat "$T/prshape" 2>/dev/null)" = old ]; then echo "OPEN $MSTATE operator headsha "
    else echo "OPEN $MSTATE operator headsha main "; fi ;;
  *"--json state,mergeStateStatus,author,headRefOid"*)
    echo "OPEN $MSTATE operator headsha " ;;
  *"--json state,isInMergeQueue"*) echo "OPEN false" ;;
  *"--json state -q .state"*) echo OPEN ;;
  *"pr diff"*) echo "+ const x = 1;" ;;
  *"--json mergeCommit"*) echo "" ;;
  *"pr merge"*) echo merged >> "$MERGE_SINK"; exit 0 ;;
  # BH-1586: the CI read is gh_rest — a whole HTTP response, REST-shaped runs.
  *"actions/runs"*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# The ticket's own protection document: nothing required (both toggles present
# and OFF, which is what GitHub actually returns), and a push allow-list of
# human logins that this lane's identity is not one of.
TICKET_PROT='{"required_status_checks":null,"required_pull_request_reviews":null,
  "required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},
  "restrictions":{"users":[{"login":"operator"}],"apps":[]}}'
prot() { printf '%s\n' "$1" | jq -c . > "$T/protection.json"; }

setup() { # setup — three approved tier-2 PRs of one repo, nothing swept yet
  rm -rf "$T/builds"
  for N in 7 8 9; do
    REC="$T/builds/pool-ts-TK-80$N-20260918000$N"; mkdir -p "$REC"
    echo "PR_CREATED https://github.com/o/r/pull/$N" > "$REC/RESULT"
    printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
    : > "$REC/pipeline.log"
  done
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merges.txt"; : > "$T/gh.txt"; echo somebody-else > "$T/userlogin"
  rm -f "$T"/flags/alerted-identity-not-permitted-* "$T"/flags/alerted-repo-invisible-*
  echo BLOCKED > "$T/mergestate"; echo ok > "$T/protmode"; echo new > "$T/prshape"
  prot "$TICKET_PROT"
}
sweep() { # sweep [<GH_TOKEN value; unset when empty>]
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" T="$T" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid JOBS_BOX=b \
           MERGE_SINK="$T/merges.txt" GH_SINK="$T/gh.txt"
    if [ -n "${1:-}" ]; then export GH_TOKEN="$1"; else unset GH_TOKEN; fi
    bash "$T/bin/sweep.sh" >/dev/null 2>"$T/err.txt" )
}
BARE="skipped: mergeState=BLOCKED (will retry)"

# ---------------------------------------------------------------------------
# S1 (REPRO) — the ticket's own protection document, on an identity that is not
#              on the list: a distinct line naming the repo and the identity in
#              the lane log AND in ALERTS.log, and NOT the bare retry line.
# ---------------------------------------------------------------------------
setup
sweep ""
grep -q "pull/7 IDENTITY_NOT_PERMITTED o/r somebody-else" "$T/logs/merge-sweep.log" \
  && ok || bad "S1: no IDENTITY_NOT_PERMITTED line for pull/7 (log: $(grep pull/7 "$T/logs/merge-sweep.log" | head -2) err=$(head -5 "$T/err.txt"))"
grep -q "IDENTITY_NOT_PERMITTED o/r somebody-else" "$T/logs/ALERTS.log" \
  && ok || bad "S1: nothing paged (ALERTS: $(cat "$T/logs/ALERTS.log"))"
grep -q "protection/restrictions" "$T/logs/ALERTS.log" \
  && ok || bad "S1: the ALERT must name exactly what is needed and from whom"
grep -q "$BARE" "$T/logs/merge-sweep.log" \
  && bad "S1: the bare retry line is still written for an identity block: $(grep "$BARE" "$T/logs/merge-sweep.log" | head -1)" || ok
grep -q "push allow-list: operator" "$T/logs/merge-sweep.log" \
  && ok || bad "S1: the line must name the allow-list it is not on"

# ---------------------------------------------------------------------------
# S2 — the retries this ticket says must not burn: nothing merged, and NO
#      ledger row. A ledger row is permanent (sweep_seen reads it for ever), so
#      stamping one on a PR that can still land the day an admin fixes the list
#      is how it would never land at all.
# ---------------------------------------------------------------------------
[ ! -s "$T/merges.txt" ] && ok || bad "S2: merged a BLOCKED PR"
grep -q "pr merge" "$T/gh.txt" && bad "S2: a merge was attempted on an identity block" || ok
grep -q "pull/7" "$T/state/merge-sweep-done.txt" \
  && bad "S2: an identity block was ledgered — it must be re-offered every run until the list is fixed" || ok
[ "$(grep -c "branches/main/protection" "$T/gh.txt")" = 1 ] \
  && ok || bad "S2: three PRs of one repo must cost ONE protection read (got $(grep -c "branches/main/protection" "$T/gh.txt"))"

# ---------------------------------------------------------------------------
# S3 — one ALERT per day however many ticks run, and never a silent tick: the
#      log still says so on every PR of every run.
# ---------------------------------------------------------------------------
[ "$(grep -c IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "S3: exactly one ALERT after the first sweep (got $(grep -c IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log"))"
ls "$T/flags/"alerted-identity-not-permitted-merge-sweep-o_r-somebody-else-* >/dev/null 2>&1 \
  && ok || bad "S3: the daily dedup flag must exist ($(ls "$T/flags" 2>/dev/null | tr '\n' ' '))"
sweep ""
[ "$(grep -c IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "S3: the second tick must not page again the same day (got $(grep -c IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log"))"
[ "$(grep -c IDENTITY_NOT_PERMITTED "$T/logs/merge-sweep.log")" -ge 6 ] \
  && ok || bad "S3: every PR of every tick must still say so in the log (got $(grep -c IDENTITY_NOT_PERMITTED "$T/logs/merge-sweep.log"))"

# ---------------------------------------------------------------------------
# S4 — on an App installation token the identity is the App's own word, and
#      /user is never called (an installation token cannot call it).
# ---------------------------------------------------------------------------
setup
sweep ghs_x
grep -q "pull/7 IDENTITY_NOT_PERMITTED o/r app/cromford" "$T/logs/merge-sweep.log" \
  && ok || bad "S4: the App identity must be named app/<slug> (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q "IDENTITY_NOT_PERMITTED o/r app/cromford" "$T/logs/ALERTS.log" \
  && ok || bad "S4: the ALERT must carry the App identity too"
grep -q "api user" "$T/gh.txt" && bad "S4: /user must never be called on an App installation token" || ok
grep -rq ghs_x "$T/logs/" && bad "S4: a token VALUE reached a log" || ok
grep -q ghs_x <<<"$(ls "$T/flags/")" && bad "S4: a token VALUE reached a flag filename" || ok

# ---------------------------------------------------------------------------
# S5 — BLOCKED with a REAL required check is a real not-ready skip: today's
#      line byte-for-byte, no alert. The negative that proves the classifier is
#      about the allow-list and not about the word BLOCKED.
# ---------------------------------------------------------------------------
setup; prot '{"required_status_checks":{"contexts":["Typecheck"]},"required_pull_request_reviews":null,"restrictions":null}'
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S5: a genuinely required check must keep the bare line unchanged (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/merge-sweep.log" "$T/logs/ALERTS.log" \
  && bad "S5: a required check must never page as an identity error" || ok
# ...and a required REVIEW with no checks at all is the same answer.
setup; prot '{"required_status_checks":null,"required_pull_request_reviews":{"required_approving_review_count":1},"restrictions":null}'
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S5: a required review must keep the bare line unchanged"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S5: a required review must not page" || ok
# ...and so is a branch whose only gate is conversation resolution or a lock:
# nothing is "required" in the two fields #846 looked at, and both still block.
setup; prot '{"required_status_checks":null,"required_pull_request_reviews":null,"required_conversation_resolution":{"enabled":true},"restrictions":{"users":[{"login":"operator"}],"apps":[]}}'
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S5: required conversation resolution keeps the bare line (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S5: conversation resolution must not page as an identity error" || ok
setup; prot '{"required_status_checks":null,"required_pull_request_reviews":null,"lock_branch":{"enabled":true},"restrictions":{"users":[{"login":"operator"}],"apps":[]}}'
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S5: a locked branch keeps the bare line"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S5: a locked branch must not page as an identity error" || ok

# ---------------------------------------------------------------------------
# S6 — a block we cannot explain is ANNOTATED, never claimed. `restrictions`
#      absent means there is no allow-list to be absent from (the review of
#      #846: the literal reading pages about a list that does not exist); an
#      API error is never read as pipeline state (the #796 family).
# ---------------------------------------------------------------------------
setup; prot '{"required_status_checks":null,"required_pull_request_reviews":null,"restrictions":null}'
sweep ""
grep -q "pull/7 $BARE — branch protection unexplained$" "$T/logs/merge-sweep.log" \
  && ok || bad "S6: no restrictions at all is 'unexplained', annotated on the bare line (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S6: an unexplained block must not page" || ok
setup; echo 403 > "$T/protmode"
sweep ""
grep -q "pull/7 $BARE — branch protection unreadable 403$" "$T/logs/merge-sweep.log" \
  && ok || bad "S6: a 403 must annotate the bare line, never invent a verdict (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S6: an unreadable protection must not page" || ok
setup; echo 404 > "$T/protmode"
sweep ""
grep -q "pull/7 $BARE — branch protection unprotected$" "$T/logs/merge-sweep.log" \
  && ok || bad "S6: a 404 is 'not protected', which is somebody else's BLOCKED (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S6: an unprotected branch must not page" || ok

# ---------------------------------------------------------------------------
# S7 — everything that must keep today's behaviour exactly: an allow-listed
#      identity, a state that is not BLOCKED, a fixture that answers the old
#      four-word read, and a tree with no lib in it at all.
# ---------------------------------------------------------------------------
setup; echo operator > "$T/userlogin"
sweep ""
grep -q "pull/7 skipped: mergeState=BLOCKED (will retry; identity operator is on the push allow-list, cause not readable from here)" "$T/logs/merge-sweep.log" \
  && ok || bad "S7: an allow-listed identity must keep retrying and say why (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
grep -q IDENTITY_NOT_PERMITTED "$T/logs/ALERTS.log" && bad "S7: an allow-listed identity must never page" || ok
grep -q "api user" "$T/gh.txt" && ok || bad "S7: a PAT identity comes from /user"

setup; echo UNSTABLE > "$T/mergestate"
sweep ""
grep -q "pull/7 skipped: mergeState=UNSTABLE (will retry)$" "$T/logs/merge-sweep.log" \
  && ok || bad "S7: UNSTABLE must keep today's line (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
[ "$(grep -c "branches/main/protection" "$T/gh.txt")" = 0 ] \
  && ok || bad "S7: UNSTABLE must not buy a protection read"

setup; echo old > "$T/prshape"
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S7: a fixture answering the OLD four-word read gets today's line, byte for byte (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
[ "$(grep -c "branches/main/protection" "$T/gh.txt")" = 0 ] \
  && ok || bad "S7: no base means no protection read — never a guess"

setup; mv "$T/bin/lib/gh-push-identity.sh" "$T/lib-parked.sh"
sweep ""
grep -q "pull/7 $BARE$" "$T/logs/merge-sweep.log" \
  && ok || bad "S7: a tree without the lib behaves exactly as it did before BH-800 (got '$(grep pull/7 "$T/logs/merge-sweep.log" | head -1)')"
mv "$T/lib-parked.sh" "$T/bin/lib/gh-push-identity.sh"
grep -rq admintok "$T/logs/" "$T/flags/" 2>/dev/null && bad "S7: an admin token VALUE reached an artifact" || ok

echo "merge-sweep-identity.bh-800: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

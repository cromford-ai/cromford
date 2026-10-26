#!/bin/bash
# tests/review-autopilot.bh-1066-test.sh — BH-1066: the review autopilot must be
# honest about what it bought, what it could not read, and what it already said.
#
# The four defects this pins, all found by the head-bound review of #1050:
#
#   1. THE AGENT-CALL RC WAS THROWN AWAY (`|| true`), and the daily cap was
#      charged on the next line whatever happened. So rc 76 ("no account with
#      headroom" — nothing called, nothing billed) wrote its one-line refusal
#      marker into $OUT, and the tick posted THAT to the PR as the review,
#      stamped the key `reviewed … verdict=UNPARSED`, and charged a spend that
#      never happened. Now: 75/76/77/78/79 write nothing and retry next tick;
#      any other nonzero rc is counted, parked as `failed n=<k> rc=<rc>` for
#      REVIEW_AUTOPILOT_FAIL_TRIES attempts, then terminal — and never posted.
#   2. A ZERO-BYTE OR CORRUPT KEY fell into `*) continue` with no log line, so
#      the lane was silently disabled for that head for ever. Now one line per
#      key per tick, naming the key and the words "unreadable state".
#   3. A `gh pr comment` THAT LANDS BUT EXITS NONZERO re-posted on every retry
#      tick (probed: three comments in three ticks). Now a re-post reads the
#      PR's comments once first and, if the head's marker is already there,
#      promotes the key to `reviewed` and posts nothing.
#   4. `unposted-terminal` ALERTED NOBODY and the 90-day sweep deleted the
#      paid-for `.body`. Now the transition fires one ALERTS line + one
#      fleet_alert beat, and the body survives the sweep until its PR is no
#      longer open.
#
# Everything below asserts what a RUN DID — files, counts, bytes, exit codes —
# against the REAL bin/review-autopilot.sh in a scratch $HARNESS with gh,
# agent-call and beat stubbed. Nothing greps the script's source (D3).
#
# Run from anywhere: bash tests/review-autopilot.bh-1066-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): the PR's
# created_at and the "older than the sweep window" mtime are both derived from
# it, so the fixtures are true whatever the wall clock says.
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
DAY=$(date -u -d "@$NOW" '+%Y%m%d')

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$H/env/global.env"
# BH-1510.1: this lane's model is a model_routes row, read through review_model;
# this worker-less box carries the resolver's cache of #1507's table.
cp "$DIR/bin/lib/review-model.sh" "$H/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1

SHA=aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd
HEAD12=${SHA:0:12}
STATE="$H/state/review-autopilot"
KEY="$STATE/o-p1-7-$HEAD12"
CNTF="$STATE/count-p1-$DAY"
RLOG="$H/logs/review-autopilot.log"
ALOG="$H/logs/ALERTS.log"

# The one open PR every tick sees: harness-authored, non-draft, a day old.
jq -n --arg sha "$SHA" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls-open.json"
cp "$T/pulls-open.json" "$T/pulls.json"

# --- the stubs --------------------------------------------------------------
# Every gh call is recorded and every posted comment is kept, so "did this tick
# post, how many times, and what bytes" is a fact about the run.
#
#   $T/gh-comment-fails          -> `gh pr comment` exits 1 and posts NOTHING
#   $T/gh-comment-lands-nonzero  -> it POSTS and THEN exits 1 (defect 3)
#   $T/gh-api-comments-fails     -> the issue-comments read exits 1
#   $T/gh-pulls-fails            -> the open-PR list fails on EVERY rung it has
#                                   (the REST pulls page AND the per-author
#                                   `gh pr list` fallback bin/lib/gh-pr-list.sh
#                                   drops to). Failing only the REST page is not
#                                   a failed list — the fallback then answers
#                                   "no open PRs", which is a different fact.
#   $T/comments.json             -> what the comments read answers (else [])
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  if [ -f "$T/gh-comment-fails" ]; then
    echo "gh: the comment could not be posted (HTTP 502)" >&2; exit 1
  fi
  cat "$BF" >> "$T/posted.txt"; echo post >> "$T/post-count.txt"
  # The shape that made this ticket: the comment IS on the PR and gh still
  # exits nonzero (a 502 on the response read, a token that expired after the
  # write). The caller cannot tell the two failures apart from the rc alone.
  [ -f "$T/gh-comment-lands-nonzero" ] && { echo "gh: HTTP 502 reading the response" >&2; exit 1; }
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = list ] && [ -f "$T/gh-pulls-fails" ]; then
  echo "gh: HTTP 502" >&2; exit 1
fi
case "$*" in
  api\ repos/o/p1/issues/7/comments*)
    [ -f "$T/gh-api-comments-fails" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [ -f "$T/comments.json" ]; then cat "$T/comments.json"; else printf '[]\n'; fi ;;
  *repos/o/p1/pulls/7)
    # The per-PR read the drain earns its delete with, answered the way
    # bin/lib/gh-rest.sh drives it (`gh api -i`: status line, blank line, body).
    # It is a DIFFERENT fact from the open-PR list — the list can come back
    # short with rc 0, this cannot. `gh-pulls-fails` takes the whole pulls
    # endpoint down with it, and a 5xx is rc 75 ("we could not look").
    if [ -f "$T/gh-pulls-fails" ] || [ -f "$T/gh-pr7-fails" ]; then
      printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0
    fi
    printf 'HTTP/2.0 200 OK\r\n\r\n'
    if [ -f "$T/pr-7.json" ]; then cat "$T/pr-7.json"; else printf '{"number":7,"state":"open","merged_at":null}\n'; fi ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    # TEST-CHANGE (BH-782): the open-PR list is a REST read through
    # bin/lib/gh-rest.sh now (`gh api -i -X GET ...`), so the argv carries -i
    # and the answer needs the status line the library parses. `gh-pulls-fails`
    # still takes the list down — as the 502 the library classifies, which is
    # the same fact the bare rc 1 was.
    if [ -f "$T/gh-pulls-fails" ]; then
      case "$*" in
        *" -i "*) printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0 ;;
      esac
      echo "gh: HTTP 502" >&2; exit 1
    fi
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# THE BILLABLE CALL. Its argv is appended (so the count of spends is a file) and
# its exit code is whatever $T/agent-rc says — the whole point of item 1.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
cat "$T/model-out" > "$5"
exit "$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
EOF
} > "$H/bin/agent-call.sh"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "${1:-}" >> "$T/beats.txt"
exit 0
EOF
} > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

GOOD_REVIEW='Nothing load-bearing was deferred; the diff does what the body says.

VERDICT: MERGE — reads fine'

PT=6
RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          REVIEW_AUTOPILOT_POST_TRIES="$PT" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
# `wc -l <`, not `grep -c`: grep exits 1 on a file with no matches, and the
# `|| echo 0` that would cover that prints a SECOND count.
CALLS()  { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS()  { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
CAP()    { cat "$CNTF" 2>/dev/null || echo 0; }
K1()     { head -1 "$KEY" 2>/dev/null; }
# Lines, never `grep -c` (same reason), and fixed-string so a scratch path full
# of dots cannot match something it does not equal.
COUNTF() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
APV() { ( HARNESS="$H" PATH="$T/fakebin:$PATH"
          # shellcheck source=/dev/null
          . "$H/bin/lib/gh-pr-list.sh"
          # shellcheck source=/dev/null
          . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
          mc_autopilot_verdict o/p1 7 'o/p1#7' "$SHA" ) 2>/dev/null; }
RESET()  { scratch_rm "$STATE"
           PT=6
           printf '0\n' > "$T/agent-rc"
           printf '%s\n' "$GOOD_REVIEW" > "$T/model-out"
           cp "$T/pulls-open.json" "$T/pulls.json"
           : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
           : > "$T/gh-calls.txt"; : > "$T/beats.txt"; : > "$RLOG"; : > "$ALOG"
           rm -f "$T/gh-comment-fails" "$T/gh-comment-lands-nonzero" \
                 "$T/gh-api-comments-fails" "$T/gh-pulls-fails" "$T/comments.json" \
                 "$T/gh-pr7-fails" "$T/pr-7.json"; }

: > "$T/run.log"

# ============================================================================
# 1. NOTHING WAS CALLED AND NOTHING WAS BILLED -> write nothing, retry next tick
# ============================================================================
for RC in 76 79; do
  case "$RC" in
    76) MARK="AGENT_CALL_REFUSED no account with headroom" ;;
    *)  MARK="PROMPT_TOO_LARGE argv-only lane refused the prompt" ;;
  esac
  RESET
  printf '%s\n' "$RC" > "$T/agent-rc"
  printf '%s\n' "$MARK" > "$T/model-out"
  RUN
  [ "$(CALLS)" = 1 ] && ok || bad "rc $RC: the tick must attempt exactly one call (calls=$(CALLS))"
  [ "$(POSTS)" = 0 ] && ok || bad "rc $RC: a refusal marker must never be posted as a review (posts=$(POSTS))"
  [ -e "$KEY" ] && bad "rc $RC: a call that never happened must write no key (got '$(K1)')" || ok
  [ -e "$CNTF" ] && bad "rc $RC: a call that was never billed must not charge the daily cap (cap=$(CAP))" || ok
  grep -q "before billing (rc=$RC" "$RLOG" && ok \
    || bad "rc $RC: the tick must log that it returned before billing"
  RUN
  [ "$(CALLS)" = 2 ] && ok || bad "rc $RC: the next tick must try again (calls=$(CALLS))"
  [ -e "$KEY" ] && bad "rc $RC: still no key after a second not-billed exit" || ok
  [ "$(POSTS)" = 0 ] && ok || bad "rc $RC: still nothing posted (posts=$(POSTS))"
done

# ============================================================================
# 2. THE CALL DIED (billed or unknowable) -> counted, parked, NEVER posted
# ============================================================================
RESET
printf '1\n' > "$T/agent-rc"
printf 'partial text, no verdict anywhere\n' > "$T/model-out"
RUN
K1 | grep -qE '^failed .* n=1 rc=1$' && ok || bad "a died call must park as failed n=1 (got '$(K1)')"
[ "$(CAP)" = 1 ] && ok || bad "a died call is billed-or-unknowable and must count (cap=$(CAP))"
[ "$(POSTS)" = 0 ] && ok || bad "a partial body on a nonzero rc must never be posted (posts=$(POSTS))"
[ -e "$KEY.body" ] && bad "a died call must cache no body" || ok
[ -z "$(APV)" ] && ok || bad "a failed row must be no verdict at all (got '$(APV)')"
RUN
K1 | grep -qE '^failed .* n=2 rc=1$' && ok || bad "the second died call must be n=2 (got '$(K1)')"
[ "$(CAP)" = 2 ] && ok || bad "two died calls are two spends (cap=$(CAP))"
RUN
K1 | grep -qE '^failed-terminal .* n=3 rc=1$' && ok \
  || bad "the third died call must be terminal (got '$(K1)')"
[ "$(CAP)" = 3 ] && ok || bad "three died calls are three spends (cap=$(CAP))"
[ "$(CALLS)" = 3 ] && ok || bad "three ticks, three calls (calls=$(CALLS))"
RUN
[ "$(CALLS)" = 3 ] && ok || bad "a failed-terminal head must never buy a fourth review (calls=$(CALLS))"
[ "$(POSTS)" = 0 ] && ok || bad "a failed-terminal head must never post (posts=$(POSTS))"
[ -z "$(APV)" ] && ok || bad "a failed-terminal row must claim no verdict (got '$(APV)')"

# ============================================================================
# 3. A parked `failed` head recovers: the next good call posts and settles
# ============================================================================
RESET
mkdir -p "$STATE"
printf 'failed 2026-09-19 00:00:00Z n=1 rc=1\n' > "$KEY"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "a failed n=1 head must be retried (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "the recovered review must post once (posts=$(POSTS))"
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok \
  || bad "the recovery must overwrite the failed row with the mirror format (got '$(K1)')"
# TEST-CHANGE (BH-1951): the conductor no longer reads this key FILE; it reads
# the source=box row the lane POSTs before writing it (this worker-less rig has
# none, so the lane logs "not configured" and posts no row). The row path is
# pinned end to end in tests/verdict-files-retired.bh-1951-test.sh (A1-A4).
[ -z "$(APV)" ] && ok || bad "the recovered key file alone must not be read by the conductor (got '$(APV)')"

# ============================================================================
# 4. rc 0 with an empty answer is STILL billed and terminal-tracked (unchanged)
# ============================================================================
RESET
: > "$T/model-out"
RUN
K1 | grep -qE '^empty .* n=1$' && ok \
  || bad "rc 0 + empty output must stay on the empty track, not the not-billed one (got '$(K1)')"
[ "$(CAP)" = 1 ] && ok || bad "rc 0 + empty output is billed and must count (cap=$(CAP))"

# ============================================================================
# 5. AN UNREADABLE KEY IS LOUD, and still buys nothing
# ============================================================================
for JUNK in "" "banana"; do
  RESET
  mkdir -p "$STATE"
  if [ -z "$JUNK" ]; then : > "$KEY"; WHAT="a zero-byte key"; else printf '%s\n' "$JUNK" > "$KEY"; WHAT="a corrupt key"; fi
  RUN
  [ "$(CALLS)" = 0 ] && ok || bad "$WHAT must buy no review (calls=$(CALLS))"
  [ "$(POSTS)" = 0 ] && ok || bad "$WHAT must post nothing (posts=$(POSTS))"
  [ "$(COUNTF "$RLOG" "key $KEY has unreadable state")" = 1 ] && ok \
    || bad "$WHAT must log exactly one unreadable-state line naming the key (got $(COUNTF "$RLOG" "key $KEY has unreadable state"))"
  RUN
  [ "$(COUNTF "$RLOG" "key $KEY has unreadable state")" = 2 ] && ok \
    || bad "$WHAT must log once PER TICK (got $(COUNTF "$RLOG" "key $KEY has unreadable state"))"
done
# The known terminal shapes are readable and must stay silent.
for GOODK in 'reviewed 2026-09-19 00:00:00Z verdict=MERGE' \
             'skipped 2026-09-19 00:00:00Z: review-prs.sh reviewed this head' \
             'empty-terminal 2026-09-19 00:00:00Z n=2' \
             'unposted-terminal 2026-09-19 00:00:00Z verdict=MERGE tries=6' \
             'failed-terminal 2026-09-19 00:00:00Z n=3 rc=1'; do
  RESET
  mkdir -p "$STATE"
  printf '%s\n' "$GOODK" > "$KEY"
  RUN
  [ "$(COUNTF "$RLOG" 'unreadable state')" = 0 ] && ok \
    || bad "'${GOODK%% *}' is a known terminal state and must not log unreadable (got $(COUNTF "$RLOG" 'unreadable state'))"
  [ "$(CALLS)" = 0 ] && ok || bad "'${GOODK%% *}' must buy nothing (calls=$(CALLS))"
done

# ============================================================================
# 6. A POST THAT LANDED AND EXITED NONZERO IS NEVER POSTED TWICE
# ============================================================================
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 1 ] && ok || bad "the first tick posts once (posts=$(POSTS))"
K1 | grep -qE '^status=reviewed-unposted .* tries=1$' && ok \
  || bad "a nonzero post must park at tries=1 (got '$(K1)')"
[ "$(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments')" = 0 ] && ok \
  || bad "the FIRST post must buy no comments read (got $(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments'))"
# The PR now genuinely carries that comment. The next tick must see it.
# BH-8419: the harness posts it as the hub App; the operator login is a person.
jq -Rs '[{body:.,user:{login:"cromford[bot]",type:"Bot"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 1 ] && ok || bad "a review already on the PR must not be posted again (posts=$(POSTS))"
[ "$(CALLS)" = 1 ] && ok || bad "the promote must buy no model call (calls=$(CALLS))"
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok \
  || bad "the promote must settle the key in the mirror format (got '$(K1)')"
[ -e "$KEY.body" ] && bad "the promote must drop the cached body" || ok
[ "$(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments')" = 1 ] && ok \
  || bad "a re-post must read the PR's comments exactly ONCE (got $(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments'))"
# TEST-CHANGE (BH-1951): as above, the promoted key file is the lane's own
# ledger only; the conductor's read is the row (verdict-files-retired A3).
[ -z "$(APV)" ] && ok || bad "the promoted key file alone must not be read by the conductor (got '$(APV)')"

# Negative A: a marker for a DIFFERENT head is not this head's review.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
# BH-8419: the hub App's marker, so the head is the only thing that differs.
jq -n '[{body:"<!-- harness-review-autopilot ffffffffffff -->\nsome other review",user:{login:"cromford[bot]",type:"Bot"}}]' \
  > "$T/comments.json"
RUN
[ "$(POSTS)" = 2 ] && ok \
  || bad "a marker for another head must NOT suppress this head's post (posts=$(POSTS))"

# Negative B: a comments read that fails must not promote and must not post blind.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
touch "$T/gh-api-comments-fails"
RUN
[ "$(POSTS)" = 1 ] && ok || bad "an unreadable comments endpoint must not re-post blind (posts=$(POSTS))"
K1 | grep -qE '^status=reviewed-unposted .* tries=2$' && ok \
  || bad "a failed comments read still counts as a try (got '$(K1)')"

# ============================================================================
# 7. unposted-terminal alerts ONCE, and the paid-for body outlives the sweep
# ============================================================================
RESET
PT=2
touch "$T/gh-comment-fails"
RUN
K1 | grep -qE '^status=reviewed-unposted .* tries=1$' && ok || bad "tick 1 parks at tries=1 (got '$(K1)')"
[ "$(COUNTF "$ALOG" 'unposted-terminal')" = 0 ] && ok \
  || bad "a first failed post must not alert (got $(COUNTF "$ALOG" 'unposted-terminal'))"
RUN
K1 | grep -q '^unposted-terminal ' && ok || bad "tick 2 must go terminal at POST_TRIES=2 (got '$(K1)')"
[ "$(COUNTF "$ALOG" "unposted-terminal: review paid for and cached at $KEY.body")" = 1 ] && ok \
  || bad "the transition must write exactly one ALERTS line naming the cached body"
grep -F "gh pr comment 7 -R o/p1 --body-file $KEY.body" "$ALOG" >/dev/null 2>&1 && ok \
  || bad "the alert must name the real command an operator runs by hand"
[ "$(COUNTF "$T/beats.txt" "review-autopilot-unposted:o/p1#7:$HEAD12")" = 1 ] && ok \
  || bad "the transition must fire exactly one keyed beat (got $(COUNTF "$T/beats.txt" "review-autopilot-unposted:o/p1#7:$HEAD12"))"
grep -F 'review-autopilot-unposted' "$T/beats.txt" | grep -qF '"kind":"fleet_alert"' && ok \
  || bad "that beat must be a fleet_alert"
RUN
[ "$(COUNTF "$ALOG" "unposted-terminal: review paid for and cached at $KEY.body")" = 1 ] && ok \
  || bad "a terminal key must not re-alert on the next tick"
[ "$(COUNTF "$T/beats.txt" "review-autopilot-unposted:o/p1#7:$HEAD12")" = 1 ] && ok \
  || bad "a terminal key must not re-beat on the next tick"
[ -s "$KEY.body" ] && ok || bad "the paid-for body must be kept for the operator"

# The 90-day sweep must not delete it.
touch -d "@$((NOW - 100*86400))" "$KEY.body"
RUN
[ -s "$KEY.body" ] && ok || bad "the 90-day sweep must no longer delete a cached review body"

# A still-open PR keeps its body; a PR that is no longer open loses it.
RUN
[ -s "$KEY.body" ] && ok || bad "a body whose PR is still open must not be drained"
# The delete is earned by ASKING the PR (8a) — the list only ever short-circuits
# "still open, skip", so this fixture has to say what the read answers.
printf '[]\n' > "$T/pulls.json"
printf '{"number":7,"state":"closed","merged_at":null}\n' > "$T/pr-7.json"
RUN
[ -e "$KEY.body" ] && bad "a body whose PR is no longer open must be dropped" || ok
[ -f "$KEY" ] && ok || bad "the drain must drop the body, never the key"
grep -qF "dropped the cached review body $KEY.body" "$RLOG" && ok \
  || bad "the drain must log what it dropped"

# A list we could not read drains NOTHING (D12: completeness is earned).
cp "$T/pulls-open.json" "$T/pulls.json"
rm -f "$T/pr-7.json"
printf 'cached review bytes\n' > "$KEY.body"
touch "$T/gh-pulls-fails"
RUN
[ -s "$KEY.body" ] && ok || bad "a failed open-PR list must never drain a paid-for body"
rm -f "$T/gh-pulls-fails"

# ============================================================================
# 8. THE FIX ROUND of the head-bound review of this PR (2026-09-20).
# ============================================================================

# 8a. THE DRAIN DELETES ON A POSITIVE READ, NEVER ON ABSENCE FROM A LIST.
# `harness_pr_list` can return rc 0 and a SHORT list: the REST rung walks a
# bounded number of pages of ALL open PRs newest-first and only logs
# `cap_reached`, and the `gh pr list` fallback returns rc 0 when one author's
# list succeeded and another's failed (the BH-847 rate-limit shape). Both drop
# the OLDEST harness PRs — exactly the long-lived heads that go
# `unposted-terminal` and own a paid-for body. So the list may only ever say
# "still open, skip"; the delete is earned by asking the PR itself.
RESET
PT=2
touch "$T/gh-comment-fails"
RUN; RUN
[ -s "$KEY.body" ] && ok || bad "8a setup: the parked head must own a cached body"
rm -f "$T/gh-comment-fails"
printf '[]\n' > "$T/pulls.json"                 # the list no longer carries it ...
printf '{"number":7,"state":"open","merged_at":null}\n' > "$T/pr-7.json"   # ... but the PR IS open
RUN
[ -s "$KEY.body" ] && ok \
  || bad "an OPEN PR missing from a short list must keep its paid-for body"
touch "$T/gh-pr7-fails"                          # and a read that failed proves nothing
RUN
[ -s "$KEY.body" ] && ok \
  || bad "a per-PR read that FAILED must never drain a paid-for body"
rm -f "$T/gh-pr7-fails"
printf '{"number":7,"state":"closed","merged_at":null}\n' > "$T/pr-7.json"
RUN
[ -e "$KEY.body" ] && bad "a PR the read says is closed must lose its cached body" || ok
[ -f "$KEY" ] && ok || bad "8a: the drain must still drop the body, never the key"

# An EMPTY list is not a `[` error. `[ "" -lt 100 ]` printed to stderr on every
# failed-list tick; nothing in this run may.
[ "$(COUNTF "$T/run.log" 'integer expression expected')" = 0 ] && ok \
  || bad "an empty or unreadable list must not run a numeric test on an empty string"

# 8b. `empty` AND `failed` SHARE ONE COUNTER. Read separately they reset each
# other, so a head that alternates rc!=0 and rc 0/empty cycles n=1 for ever —
# billed every tick, never terminal, unbounded at the default cap of 0.
RESET
printf '1\n' > "$T/agent-rc"; printf 'partial, no verdict\n' > "$T/model-out"
RUN
printf '0\n' > "$T/agent-rc"; : > "$T/model-out"
RUN
K1 | grep -qE '^empty-terminal .* n=2$' && ok \
  || bad "failed then empty must reach n=2 and go terminal (got '$(K1)')"
RUN
[ "$(CALLS)" = 2 ] && ok \
  || bad "an alternating head must buy no third call (calls=$(CALLS))"

RESET                                            # and the other way round
printf '0\n' > "$T/agent-rc"; : > "$T/model-out"
RUN
printf '1\n' > "$T/agent-rc"; printf 'partial, no verdict\n' > "$T/model-out"
RUN
printf '0\n' > "$T/agent-rc"; : > "$T/model-out"
RUN
K1 | grep -qE '^(empty|failed)-terminal .* n=3$' && ok \
  || bad "empty/failed/empty must be terminal by tick 3 (got '$(K1)')"
RUN
[ "$(CALLS)" = 3 ] && ok || bad "a terminal alternating head buys nothing more (calls=$(CALLS))"

# 8c. THE REVIEW MODEL IS RESOLVED, NOT A LITERAL (repo convention:
# bin/blocked-resolver.sh:198).
RESET
RUN
grep -qE '(^| )claude-opus-5-5( |$)' "$T/agent-calls.txt" && ok \
  || bad "the default review model must be claude-opus-5-5 since BH-1507 (got '$(cat "$T/agent-calls.txt")')"
RESET
( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
  REVIEW_AUTOPILOT_POST_TRIES="$PT" REVIEW_MODEL=claude-opus-5 \
  bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true
grep -qE '(^| )claude-opus-5( |$)' "$T/agent-calls.txt" && ok \
  || bad "REVIEW_MODEL must choose the review model (got '$(cat "$T/agent-calls.txt")')"

# 8d. A PROMOTE IS NOT A POST. Nothing went to the PR this tick, so nothing may
# be logged as posted or counted into the run's "reviewed" beat.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
# BH-8419: the harness's own comment is the hub App's.
jq -Rs '[{body:.,user:{login:"cromford[bot]",type:"Bot"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
RUN
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok || bad "8d setup: the promote must settle (got '$(K1)')"
[ "$(COUNTF "$RLOG" 'cached review posted on retry')" = 0 ] && ok \
  || bad "a promote posted nothing and must not be logged as a post"
[ "$(COUNTF "$RLOG" 'settled without posting')" = 1 ] && ok \
  || bad "a promote must say so once (got $(COUNTF "$RLOG" 'settled without posting'))"
[ "$(COUNTF "$T/beats.txt" 'pr_review')" = 0 ] && ok \
  || bad "a tick that posted nothing must not beat a dispatched review"

# The GENUINE re-post keeps its words and its beat.
RESET
touch "$T/gh-comment-fails"
RUN
K1 | grep -qE '^status=reviewed-unposted .* tries=1$' && ok || bad "8d setup: parked at tries=1 (got '$(K1)')"
rm -f "$T/gh-comment-fails"
RUN
[ "$(POSTS)" = 1 ] && ok || bad "the cached review must actually post on retry (posts=$(POSTS))"
[ "$(COUNTF "$RLOG" 'cached review posted on retry')" = 1 ] && ok \
  || bad "a real re-post must be logged as a post (got $(COUNTF "$RLOG" 'cached review posted on retry'))"
[ "$(COUNTF "$T/beats.txt" 'pr_review')" = 1 ] && ok \
  || bad "a real re-post must be beaten as a dispatched review"

# ============================================================================
# 9. ROUND-2 of the head-bound review of this PR (2026-09-20): the promote must
#    be AUTHOR-BOUND, and the terminal alert must name what actually failed.
# ============================================================================

# 9a. A STRANGER'S MARKER MUST NOT SETTLE THE KEY (round-2 finding 2, probed:
# with the author swapped to `total-stranger` the suite still passed 101/0 —
# the key went `reviewed`, the `.body` was deleted, and the paid-for review
# never reached the PR). The marker is a dedup hint, not a credential: anyone
# with comment rights could otherwise paste `<!-- harness-review-autopilot
# <head12> -->` on a parked head and delete the review nobody ever read.
# The comment must be written by a login in harness_pr_authors_json — the same
# binding mc_autopilot_verdict applies, for the same reason.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 1 ] && ok || bad "9a setup: the first tick posts once (posts=$(POSTS))"
jq -Rs '[{body:.,user:{login:"total-stranger"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 2 ] && ok \
  || bad "a marker from a login outside the harness author set must NOT suppress the post (posts=$(POSTS))"
[ "$(COUNTF "$RLOG" 'settled without posting')" = 0 ] && ok \
  || bad "a stranger's marker must never be logged as a settled promote"
[ "$(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments')" = 1 ] && ok \
  || bad "9a: the re-post still reads the comments exactly once (got $(COUNTF "$T/gh-calls.txt" 'api repos/o/p1/issues/7/comments'))"

# 9b. AND THE REAL PATH STILL PROMOTES ACROSS SPELLINGS. Since bin/gh-token.sh
# went live the harness posts as the App as often as as the PAT, and REST spells
# that login `cromford[bot]` while HARNESS_PR_AUTHORS carries
# `app/cromford`. Compare them raw and the binding would break the very
# duplicate-suppression this ticket exists to add.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
jq -Rs '[{body:.,user:{login:"cromford[bot]"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 1 ] && ok \
  || bad "the App's own marker must still promote — app/x and x[bot] are one actor (posts=$(POSTS))"
K1 | grep -qE '^reviewed .* verdict=MERGE$' && ok \
  || bad "9b: the promote must settle the key in the mirror format (got '$(K1)')"
[ -e "$KEY.body" ] && bad "9b: the promote must drop the cached body" || ok
[ "$(COUNTF "$RLOG" 'settled without posting')" = 1 ] && ok \
  || bad "9b: the promote must say so once (got $(COUNTF "$RLOG" 'settled without posting'))"

# 9c. THE SET IS DATA, NOT A LITERAL. Same comment, same head, same bytes — with
# the App taken OUT of HARNESS_PR_AUTHORS it is a stranger again and the review
# is delivered. A hardcoded login, or an author check that matches anything,
# fails exactly one of 9b and 9c.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
jq -Rs '[{body:.,user:{login:"cromford[bot]"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
  REVIEW_AUTOPILOT_POST_TRIES="$PT" HARNESS_VERDICT_AUTHORS=app/some-other-app \
  bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true
# TEST-CHANGE (BH-1668): the marker's author is judged against the VERDICT
# author set now (HARNESS_VERDICT_AUTHORS), split from the PR-author set, so that
# is the knob this case narrows. Same assertion. BH-8419: the narrowed set is
# another App, since the operator login is dropped from the set.
[ "$(POSTS)" = 2 ] && ok \
  || bad "an actor outside HARNESS_VERDICT_AUTHORS must not settle the key (posts=$(POSTS))"

# 9e. THE BUILDERS APP AUTHORS PRS BUT ISSUES NO VERDICTS (BH-1668, review of
# #1926 blocking 2). Its marker is a stranger's marker: the review is delivered.
RESET
touch "$T/gh-comment-lands-nonzero"
RUN
jq -Rs '[{body:.,user:{login:"cromford-builders[bot]"}}]' < "$T/posted.txt" > "$T/comments.json"
rm -f "$T/gh-comment-lands-nonzero"
RUN
[ "$(POSTS)" = 2 ] && ok \
  || bad "9e: the builders App's marker must not settle the key — it is not a verdict author (posts=$(POSTS))"

# 9d. THE TERMINAL ALERT MUST NAME WHAT FAILED (round-2 finding 3). A failed
# comments read falls through to `tries+1` — correctly, it is what keeps the
# lane bounded when the endpoint stays down — so `tries` counts post attempts
# AND reads. The old sentence said "gh refused to post it <tries> times", which
# sends an operator hunting for six post failures that never happened: below,
# ONE post attempt and TWO failed reads reach the bound.
RESET
PT=3
touch "$T/gh-comment-lands-nonzero"
RUN
rm -f "$T/gh-comment-lands-nonzero"
touch "$T/gh-api-comments-fails"
RUN
RUN
K1 | grep -qE '^unposted-terminal .* tries=3$' && ok \
  || bad "9d setup: one post attempt plus two failed reads must reach the bound (got '$(K1)')"
[ "$(POSTS)" = 1 ] && ok \
  || bad "9d setup: only the FIRST tick may reach gh pr comment (posts=$(POSTS))"
[ "$(COUNTF "$ALOG" 'gh refused to post it')" = 0 ] && ok \
  || bad "the alert must not claim post refusals it did not count"
[ "$(COUNTF "$ALOG" 'could not be delivered 3 times (post attempts + comment reads)')" = 1 ] && ok \
  || bad "the alert must say what the number counts (got '$(grep -F unposted-terminal "$ALOG" | head -1)')"
grep -F "gh pr comment 7 -R o/p1 --body-file $KEY.body" "$ALOG" >/dev/null 2>&1 && ok \
  || bad "9d: the reworded alert must still name the command an operator runs"
# TEST-CHANGE: BH-2365 — the ALERTS line now also beats kind:"alert" through bin/alert-line.sh,
# so the fleet_alert beat and the alert-line beat each carry the sentence once.
[ "$(grep -F '"kind":"fleet_alert"' "$T/beats.txt" | grep -cF 'could not be delivered 3 times')" = 1 ] && ok \
  || bad "the beat carries the same sentence as the ALERTS line"
[ "$(grep -F '"kind":"alert"' "$T/beats.txt" | grep -cF 'could not be delivered 3 times')" = 1 ] && ok \
  || bad "the alert-line beat carries the same sentence as the ALERTS line"

echo "review-autopilot.bh-1066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/resolver-review-consumer-test.sh — the review lane's verdict has a
# CONSUMER (BH-872, workstream B).
#
# WHY THIS IS THE TEST THAT MATTERS. Before this, bin/review-prs.sh posted
# REQUEST_CHANGES on a harness PR and NOTHING read it: the PR sat blocked, the
# merge queue ejected it on `github-review-approved`, and the lane re-posted the
# same findings on the same head for ever. So the claim under test is not "a
# function exists" — it is that a verdict on the CURRENT head of a HARNESS PR
# becomes exactly ONE fix round, that a second verdict on the same head becomes
# NOTHING, and that a spent cap becomes ONE ABANDONED outcome (the PR closed
# with what was tried) and then silence. Before BH-4149 that terminal was an
# ESCALATED park left open for a person; legacy ESCALATED records stay terminal.
#
# Every assertion is a fact about the run: the TSV br_from_reviews really prints,
# the gh call log, the agent call log, the record under state/blocked-resolver/,
# ALERTS.log and the beats. Never a grep over the script's source.
#
# The adversarial negatives are the point of §2: a `operator` changes-requested
# review WITHOUT the lane's footer is a HUMAN's review and must never brief an
# agent; a footer review at an OLDER commit must never speak for the new head;
# an APPROVE body must never buy a fix round; a draft must never be a candidate;
# and the newest footer review at the head is the only one that counts.
# Run from anywhere: tests/resolver-review-consumer-test.sh   (exit 0 = all pass)
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

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# updatedAt below is derived from it, so "updated within the lookback" is true
# whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# gh-rest.sh (BH-783) and hold.sh (BH-1019) landed on main after this fixture
# was written; the resolver HARD-requires gh-rest.sh and exits 1 without it, so
# a fixture that skips it lifts an empty library.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/rebuild-ledger.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/git-identity.sh" "$H/bin/lib/"
# BH-1134: the fix round pushes only commits authored AS the global git identity
# (bin/lib/git-identity.sh, fail-closed when absent). The scratch global is the
# t@t this suite's commits already carry; the real ~/.gitconfig is never read.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# ahead of its first line of logic, so a fixture that copies the lib alone gets a
# lib that cannot load.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# beat.sh and lane-alert.sh are RECORDED, never stubbed silent: "the escalation
# went quiet instead of paging" is one of the failures under test.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/lane-alert.sh"
# A jobs client whose queue_put is recorded rather than sent: "the escalation
# must not enqueue a rebuild" is only provable against a recorder.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: a rebuild would be a queue row

# ---------------------------------------------------------------------------
# The fixtures: the REST shapes GitHub really answers with, and the review body
# bin/review-prs.sh really posts (its footer line and its `VERDICT:` line).
# ---------------------------------------------------------------------------
FOOTER='_Automated harness review (Fable) of '
RBODY() { # RBODY <APPROVE|REQUEST_CHANGES> <sha> — the posted review, verbatim shape
  printf 'Two sentences of summary.\n\n1. HIGH src/rate.ts:12 the route is unauthenticated — add the session guard.\n\nTIER: 2\nVERDICT: %s\n\n---\n%s%s. Static review — no build run. Push fixes and the next pass re-reviews; approved PRs merge automatically._\n' \
    "$1" "$FOOTER" "$2"
}
# A HUMAN's review: no footer. It deliberately CONTAINS a `VERDICT:` line —
# people quote the bot when they agree with it — so this fixture pins the FOOTER
# as the identity mark rather than letting the verdict parse do that job by
# accident. HBODY_PLAIN is the same review without the quote.
HBODY='Please rename the variable before this lands. I agree with the bot on this one: VERDICT: REQUEST_CHANGES'
HBODY_PLAIN='Please rename the variable before this lands.'

# $T/openprs IS THE OPEN-PR LIST FIXTURE. BH-782 moved harness_pr_list's
# `repos/<slug>/pulls?state=open` page from a bare `gh api` onto gh_rest, so the
# list now arrives at the shared stub (tests/lib/gh-rest-stub.sh) under the
# `-i -X GET` envelope and is answered from $T/openprs — the name every converted
# suite writes. The local `/pulls?` arm below is kept for a caller that still
# pages it bare, and both read ONE file so the two answers can never disagree.
PRWRITE() { jq -s . "$T/prrows" > "$T/openprs"; cp "$T/openprs" "$T/prlist.json"; }
PRRESET() { : > "$T/prrows"; PRWRITE
            rm -f "$T/reviews-"*.json "$T/revrows-"* "$T/pr-"*.json 2>/dev/null; }
PRADD() { # PRADD <num> <head> <branch> <login> <draft> <age-secs>
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --arg l "$4" --argjson d "$5" \
        --arg u "$(ISO "$6")" --arg url "https://github.com/o/tproj/pull/$1" \
    '{number:$n, html_url:$url, title:("TK-"+($n|tostring)+": the work"), body:"body",
      head:{sha:$h, ref:$b}, base:{ref:"main"}, draft:$d,
      user:{login:$l, type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}' > "$T/pr-$1.json"
  cat "$T/pr-$1.json" >> "$T/prrows"
  PRWRITE
}
REVADD() { # REVADD <num> <id> <state> <commit_id> <login> <body>
  jq -nc --argjson i "$2" --arg s "$3" --arg c "$4" --arg l "$5" --arg b "$6" \
    '{id:$i, state:$s, commit_id:$c, user:{login:$l}, body:$b}' >> "$T/revrows-$1"
  jq -s . "$T/revrows-$1" > "$T/reviews-$1.json"
}
REVADDA() { # REVADDA <num> <id> <state> <commit_id> <login> <association> <body> — with GitHub's author_association
  jq -nc --argjson i "$2" --arg s "$3" --arg c "$4" --arg l "$5" --arg a "$6" --arg b "$7" \
    '{id:$i, state:$s, commit_id:$c, user:{login:$l, type:"User"}, author_association:$a, body:$b}' >> "$T/revrows-$1"
  jq -s . "$T/revrows-$1" > "$T/reviews-$1.json"
}
RL_HEALTHY='{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'
RL_LOW='{"resources":{"core":{"remaining":5,"limit":5000,"reset":0},"graphql":{"remaining":5,"limit":5000,"reset":0}}}'
printf '%s\n' "$RL_HEALTHY" > "$T/ratelimit.json"
# The budget cache must never decide a later case: every gh_budget_low call
# re-reads the stub.
export GH_BUDGET_TTL_S=0

# Every gh call is recorded. The reviews read is recorded SEPARATELY, because
# "the budget guard read no reviews" is an assertion about the absence of a call.
echo '[]' > "$T/empty.json"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p' | head -1)
# gh applies --jq ITSELF. A stub that ignores it hands its caller raw JSON and
# proves nothing about the parse under test, so the fixture applies it too.
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq) JQX="\$A" ;; esac; PREV="\$A"; done
emit() {
  local f="\$1"; [ -s "\$f" ] || f="$T/empty.json"
  if [ -n "\$JQX" ]; then jq -r "\$JQX" < "\$f" 2>/dev/null; else cat "\$f"; fi
}
case "\$*" in
  # bin/blocked-resolver.sh decides over REST since BH-783, so the \`gh api -i\`
  # envelope is answered by the shared stub every converted suite uses. The PR
  # fields it reads are derived from this fixture's own pr-<n>.json.
  # A comment POST GitHub ACCEPTED, which is what "posted exactly one comment"
  # means: the shared stub logs every attempt, refusals included, so the accepted
  # ones are counted here where the per-route status is still visible.
  *"-i -X POST"*"/comments"*)
    GHT="$T"
    [ -s "$T/st-comment" ] || printf 'comment %s\n' "\$*" >> "$T/posted.txt"
    jq -r '.head.sha // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-i -X "*)
    GHT="$T"
    jq -r '.head.sha // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prhead"
    jq -r '.head.ref // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prbranch"
    jq -r '.title // ""'    "$T/pr-\$N.json" 2>/dev/null > "$T/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"api rate_limit"*) cat "$T/ratelimit.json" ;;
  *"/pulls/"*"/reviews"*)
    printf '%s\n' "\$*" >> "$T/revreads.txt"
    if [ -f "$T/reviews-fail" ]; then
      echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1
    fi
    emit "$T/reviews-\$N.json" ;;
  *"/pulls?"*)        emit "$T/prlist.json" ;;
  *"pr close"*)       printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  # ONE LINE per comment in comments.txt (a body is multi-line, and "exactly one
  # comment" must be a count of CALLS, not of lines of prose); the body itself
  # goes to its own file for the assertions about what it says.
  *"pr comment"*)     [ -f "$T/comment-fail" ] && exit 1
                      printf 'pr comment %s\n' "\$2" >> "$T/comments.txt"
                      printf '%s\n' "\$*" >> "$T/comment-bodies.txt"; exit 0 ;;
  *"issue comment"*)  exit 0 ;;
  *"--json state"*)   cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  # br_pr_ref's paired REST read and br_findings' head-only one are the SAME
  # call with different jq, so one fixture object answers both.
  *"/pulls/"*)        emit "$T/pr-\$N.json" ;;
  *"--json headRefName"*) echo "ticket/ts-\$N" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
echo OPEN > "$T/prstate"
: > "$T/gh.txt"; : > "$T/revreads.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"
: > "$T/posted.txt"
: > "$T/queue.txt"; : > "$T/beats.txt"; : > "$T/lane-alert.txt"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""

# ============================================================================
# 1. The classifier: the new reason routes straight to a fix round, is NOT a
#    ladder class, and its cap is the knob the ticket named.
#    Extracted and DRIVEN — sourcing the whole script would run the drain.
# ============================================================================
: > "$T/cls.sh"
# br_shape and br_num ride along because br_fix_cap reads the RECORD for every
# reason but this one (BH-579's shape + contested bonus), exactly as
# tests/blocked-resolver-test.sh extracts them.
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
for fn in br_action br_reason_of br_ladder_class br_ladder_rung br_fix_cap br_shape br_num; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/cls.sh"
done
export CLS="$T/cls.sh"
CL() { bash -c '. "$CLS"; "$@"' _ "$@"; }
[ -s "$T/cls.sh" ] && ok || bad "could not extract the classifier from bin/blocked-resolver.sh"
grep -q '^br_fix_cap()' "$T/cls.sh" && ok || bad "br_fix_cap must exist — the per-reason fix-round cap is what bounds the review rounds"

got=$(CL br_reason_of 'review-changes-requested: o/tproj#7 at 00602a33')
[ "$got" = review-changes-requested ] && ok \
  || bad "a review park reason must normalise to review-changes-requested, got '$got'"
got=$(CL br_action review-changes-requested)
[ "$got" = fix-round ] && ok || bad "review-changes-requested must act as fix-round, got '$got'"
got=$(CL br_ladder_class review-changes-requested)
[ -z "$got" ] && ok || bad "review-changes-requested must have NO ladder class (no mechanical rung, no rebuild fallthrough), got '$got'"
# With the ladder switched off the answer must not change: this reason was never
# a ladder class, so BR_LADDER has nothing to do with it.
got=$(env BR_LADDER=0 bash -c '. "$CLS"; br_action review-changes-requested')
[ "$got" = fix-round ] && ok || bad "BR_LADDER=0 must still answer fix-round for a review verdict, got '$got'"
# The cap: 2 for this reason, today's MAX_FIXROUNDS for every other, and both
# are configuration rather than constants. br_fix_cap takes the RECORD first and
# the reason second (BH-579 landed the shape-driven cap on main while this
# branch was open): the review reason answers without reading the record at all,
# every other reason reads the record exactly as BH-579 left it.
got=$(CL br_fix_cap '{}' review-changes-requested)
[ "$got" = 2 ] && ok || bad "the review fix-round cap must default to 2, got '$got'"
got=$(env BR_REVIEW_FIX_ROUNDS=3 bash -c '. "$CLS"; br_fix_cap "{}" review-changes-requested')
[ "$got" = 3 ] && ok || bad "BR_REVIEW_FIX_ROUNDS must be the documented knob, got '$got'"
got=$(CL br_fix_cap '{}' conflict-unresolvable)
[ "$got" = 1 ] && ok || bad "every other reason must keep today's cap of 1, got '$got'"
got=$(env BR_MAX_FIXROUNDS=4 bash -c '. "$CLS"; br_fix_cap "{}" conflict-unresolvable')
[ "$got" = 4 ] && ok || bad "BR_MAX_FIXROUNDS must still be the knob for every other reason, got '$got'"
# And the two caps do not read each other: a small contested record buys BH-579's
# shape+bonus rounds on a conflict park, and the review park is still the knob.
got=$(CL br_fix_cap '{"conflict_lines":5,"fixround_bonus":1}' conflict-unresolvable)
[ "$got" = 3 ] && ok || bad "a non-review reason must keep the record's shape+bonus cap (BH-579), got '$got'"
got=$(CL br_fix_cap '{"conflict_lines":5,"fixround_bonus":1}' review-changes-requested)
[ "$got" = 2 ] && ok || bad "the review cap is the reason's, and a conflict record must not raise it, got '$got'"

# ============================================================================
# 2. br_from_reviews: the candidate source, driven for its real output.
#
#    Everything above the drain loop is sourced — the real libs, the real
#    harness_pr_list (REST), the real budget guard — so each row below is the
#    TSV the lane would hand to br_one.
# ============================================================================
awk '/^DONE_KEYS=/{exit} {print}' "$H/bin/blocked-resolver.sh" > "$T/br-lib.sh"
[ -s "$T/br-lib.sh" ] && ok || bad "could not lift the resolver's functions out of the script"
export BRLIB="$T/br-lib.sh"
CAND() { # the candidate rows this source prints, with $1 as ONLY
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" ONLYARG="${1:-}" \
    bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY="$ONLYARG"; br_from_reviews' 2>/dev/null )
}
ROWS() { CAND "${1:-}" | grep -F $'\treview-changes-requested\t' || true; }
NROWS() { ROWS "${1:-}" | grep -c . || true; }

# --- 2a. the happy path: one PR, one footer REQUEST_CHANGES at its head ------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
: > "$T/revreads.txt"
[ "$(NROWS)" = 1 ] && ok || bad "one harness PR with a footer REQUEST_CHANGES review at its head must be exactly ONE candidate, got $(NROWS): $(ROWS)"
ROW=$(ROWS)
[ "$(cut -f1 <<<"$ROW")" = reviews ] && ok || bad "the source column must be 'reviews', got '$(cut -f1 <<<"$ROW")'"
[ "$(cut -f2 <<<"$ROW")" = tproj ] && ok || bad "the project column must be the fleet.conf name, got '$(cut -f2 <<<"$ROW")'"
[ "$(cut -f3 <<<"$ROW")" = o-tproj-7 ] && ok || bad "the rkey must be the sanitised slug#num so it dedupes against the conductor source, got '$(cut -f3 <<<"$ROW")'"
[ "$(cut -f5 <<<"$ROW")" = "https://github.com/o/tproj/pull/7" ] && ok || bad "the candidate must carry the PR url, got '$(cut -f5 <<<"$ROW")'"
[ "$(cut -f7 <<<"$ROW")" = TK-7 ] && ok || bad "the ticket key must be derived from the branch, got '$(cut -f7 <<<"$ROW")'"
[ -s "$T/revreads.txt" ] && ok || bad "the source must actually read the PR's reviews from GitHub"

# --- 2b. the App's own spelling of the same author counts -------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 "cromford[bot]" false 600
REVADD 7 11 CHANGES_REQUESTED S1sha "cromford[bot]" "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 1 ] && ok || bad "the App identity (cromford[bot]) is one of ours in REST spelling — got $(NROWS) candidates"

# --- 2c. a footer review at an OLDER commit never speaks for the new head ---
PRRESET
PRADD 7 S2sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a footer review at an OLD head must not be a candidate on the new head, got: $(ROWS)"

# --- 2d. an APPROVE body is never a fix round ------------------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 APPROVED S1sha operator "$(RBODY APPROVE S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a footer review whose body says APPROVE must never be a candidate, got: $(ROWS)"

# --- 2e. a HUMAN's changes-requested (no footer) is for a human ------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$HBODY"
[ "$(NROWS)" = 0 ] && ok || bad "a operator CHANGES_REQUESTED review WITHOUT the lane's footer must never brief an agent, even when it quotes the verdict line, got: $(ROWS)"
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$HBODY_PLAIN"
[ "$(NROWS)" = 0 ] && ok || bad "a plain human changes-requested review must never be a candidate, got: $(ROWS)"

# --- 2e2. BH-2200: a LEAD's changes-requested (write access proved) IS a brief
# The same footer-less operator review as 2e, but GitHub says MEMBER: that is the
# lead, and a lead-blocked PR is exactly ONE fix-round candidate (2e's rows carry
# no association, which proves no write access, so they stay non-candidates).
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADDA 7 11 CHANGES_REQUESTED S1sha operator MEMBER "$HBODY_PLAIN"
[ "$(NROWS)" = 1 ] && ok || bad "BH-2200: a lead's (MEMBER) CHANGES_REQUESTED at the head must be ONE candidate, got $(NROWS): $(ROWS)"
grep -q $'\treview-changes-requested\t' <<<"$(ROWS)" && ok || bad "BH-2200: the lead-blocked candidate's reason must be review-changes-requested: $(ROWS)"
# ...and a later APPROVE by the same lead lifts it.
REVADDA 7 12 APPROVED S1sha operator MEMBER "LGTM"
[ "$(NROWS)" = 0 ] && ok || bad "BH-2200: a lead CR the lead later APPROVED must not be a candidate, got: $(ROWS)"

# --- 2f. a footer review by somebody who is not ours -----------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha outsider "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a footer review by a non-harness login must not be a candidate, got: $(ROWS)"

# --- 2g. a draft PR is never a candidate -----------------------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator true 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a DRAFT PR must never be a candidate, got: $(ROWS)"

# --- 2h. an external-author PR is not this lane's business -----------------
PRRESET
PRADD 7 S1sha ticket/TK-7 outsider false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "an external-author PR must never be fix-rounded by this lane, got: $(ROWS)"

# --- 2i. the NEWEST footer review at the head is the only one that counts --
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
REVADD 7 12 APPROVED S1sha operator "$(RBODY APPROVE S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "an APPROVE that came AFTER the block must end the park, got: $(ROWS)"
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 APPROVED S1sha operator "$(RBODY APPROVE S1sha)"
REVADD 7 12 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 1 ] && ok || bad "a block that came AFTER an approve on the same head IS the verdict, got $(NROWS)"

# --- 2j. the lookback bounds the read, and it is a knob --------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 300000
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a PR untouched for longer than BR_REVIEW_LOOKBACK_SECS must not be read, got: $(ROWS)"
export BR_REVIEW_LOOKBACK_SECS=400000
[ "$(NROWS)" = 1 ] && ok || bad "BR_REVIEW_LOOKBACK_SECS must be the documented knob, not a constant"
unset BR_REVIEW_LOOKBACK_SECS

# --- 2k. ONLY is respected ------------------------------------------------
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS otherproj)" = 0 ] && ok || bad "a tick scoped to another project must produce no candidate here"
[ "$(NROWS tproj)" = 1 ] && ok || bad "a tick scoped to THIS project must still produce it"

# --- 2l. a low GitHub budget reads NOTHING --------------------------------
printf '%s\n' "$RL_LOW" > "$T/ratelimit.json"
: > "$T/revreads.txt"
[ "$(NROWS)" = 0 ] && ok || bad "a low API budget must produce no candidates, got: $(ROWS)"
[ -s "$T/revreads.txt" ] && bad "a low API budget must read NO reviews: $(cat "$T/revreads.txt")" || ok
printf '%s\n' "$RL_HEALTHY" > "$T/ratelimit.json"

# --- 2m. an UNREADABLE reviews list is not "no review" --------------------
touch "$T/reviews-fail"
: > "$H/logs/blocked-resolver.log"
[ "$(NROWS)" = 0 ] && ok || bad "a failed reviews read must not invent a candidate, got: $(ROWS)"
grep -qi 'unreadable\|could not be read' "$H/logs/blocked-resolver.log" && ok \
  || bad "a failed reviews read must be SAID (D11: unreadable is not absent), log: $(cat "$H/logs/blocked-resolver.log")"
rm -f "$T/reviews-fail"

# --- 2n. a DISMISSED footer review is a review GitHub no longer counts ------
#         (#891 review, item 2: rp_dismiss_own retracts the lane's own legacy
#         CHANGES_REQUESTED on a pipeline-built PR whose head it approved; a fix
#         round briefed off that row would push under a queued PR and eject it).
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 DISMISSED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 0 ] && ok || bad "a DISMISSED footer REQUEST_CHANGES at the head must never be a candidate, got: $(ROWS)"
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
REVADD 7 12 DISMISSED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
[ "$(NROWS)" = 1 ] && ok || bad "a dismissed row must not hide a standing verdict on the same head, got $(NROWS)"

# --- 2o. an ESCALATED record is terminal for this source, before the read --
#         (#891 review, item 3: the PR was handed to a person with one comment;
#         re-offering it every tick spent a reviews read and a log line each.)
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-7",fixrounds:2,rebuilds:0,outcome:"ESCALATED",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-7.json"
: > "$T/revreads.txt"
[ "$(NROWS)" = 0 ] && ok || bad "an ESCALATED record must produce no candidate, got: $(ROWS)"
[ -s "$T/revreads.txt" ] && bad "an ESCALATED record must skip the PR BEFORE the reviews read: $(cat "$T/revreads.txt")" || ok
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-7.json"
[ "$(NROWS)" = 1 ] && ok || bad "with the record gone the same verdict is a candidate again, got $(NROWS)"

# --- 2o2. BH-2200: a head whose lead-blocked round ended fix-round-noop is a
#          candidate again since BH-4149, so br_fix_round's frozen-head gate can
#          take it to its terminal instead of parking it for a person. A NEW head
#          is a candidate as before.
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADDA 7 11 CHANGES_REQUESTED S1sha operator MEMBER "$HBODY_PLAIN"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-7",fixrounds:1,rebuilds:0,outcome:"",noop_heads:["S1sha"],attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-7.json"
: > "$T/revreads.txt"
# TEST-CHANGE BH-4140 the source no longer skips a frozen head: skipping it was the indefinite park this ticket removes (the terminal is pinned in tests/blocked-resolver-no-person.bh-4140-test.sh P3)
[ "$(NROWS)" = 1 ] && ok || bad "BH-4149: a noop-frozen head must be a candidate, so the frozen-head gate can end it, got $(NROWS): $(ROWS)"
PRRESET
PRADD 7 S2sha ticket/TK-7 operator false 600
REVADDA 7 11 CHANGES_REQUESTED S2sha operator MEMBER "$HBODY_PLAIN"
[ "$(NROWS)" = 1 ] && ok || bad "BH-2200: a NEW head re-arms the lead-blocked PR, got $(NROWS)"
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-7.json"

# --- 2p. ESCALATED is terminal for the ESCALATED PR, not for the TICKET ----
#         (#891 round 1, Important 5). br_cap_key keys on the ticket whenever
#         the branch names one, so a SECOND hand PR for TK-7 inherited the
#         escalation of the first and could never be a candidate — the same
#         "no consumer" state, recreated for that ticket and silent.
PRRESET
PRADD 9 S9sha ticket/TK-7 operator false 600
REVADD 9 21 CHANGES_REQUESTED S9sha operator "$(RBODY REQUEST_CHANGES S9sha)"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-7",fixrounds:2,rebuilds:0,outcome:"ESCALATED",escalated_rkey:"o-tproj-7",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-7.json"
[ "$(NROWS)" = 1 ] && ok || bad "a SECOND PR for an escalated ticket key must still be a candidate, got $(NROWS): $(ROWS)"
# ... and the PR that WAS escalated stays terminal.
PRRESET
PRADD 7 S1sha ticket/TK-7 operator false 600
REVADD 7 11 CHANGES_REQUESTED S1sha operator "$(RBODY REQUEST_CHANGES S1sha)"
: > "$T/revreads.txt"
[ "$(NROWS)" = 0 ] && ok || bad "the escalated PR itself must stay terminal, got: $(ROWS)"
[ -s "$T/revreads.txt" ] && bad "the escalated PR must still be skipped BEFORE the reviews read: $(cat "$T/revreads.txt")" || ok
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-7.json"

# ============================================================================
# 3. THE WHOLE LANE, END TO END. The real script, the real candidate wiring
#    (br_candidates), a real local git clone, and an "agent" that either
#    commits or does not.
#
#    THE GIT IS REAL. The fix round works in a worktree of the PR branch, merges
#    origin/main, and pushes under a lease — so a scenario that does not build a
#    real remote proves nothing about the rung.
# ============================================================================
ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
mkbranch() {
  git -C "$SEED" checkout -q main
  git -C "$SEED" checkout -q -b "$1"
  printf '%s\n' "$1" > "$SEED/f-${1##*/}.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q origin "$1"
}
mkbranch ticket/TK-71
mkbranch ticket/TK-72
mkbranch ticket/TK-73
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
osha() { git -C "$ORIGIN" rev-parse "$1"; }

# The "agent": it runs with the worktree as its cwd, exactly as
# bin/agent-call.sh is invoked, and records the prompt it was given.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'agent-call %s %s\n' "\$1" "\$2" >> "$T/agent.txt"
printf '%s' "\$6" >> "$T/prompt.txt"
if [ -f "$T/agent-commits" ]; then
  printf 'the finding, answered\n' > answered.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: answered the review findings" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
RESET() { : > "$T/agent.txt"; : > "$T/prompt.txt"; : > "$T/closed.txt"
          : > "$T/comments.txt"; : > "$T/comment-bodies.txt"; : > "$T/posted.txt"
          : > "$T/queue.txt"; : > "$T/beats.txt"; : > "$T/lane-alert.txt"
          : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
          scratch_rm "$H/state/gh-budget"; }
NAGENT() { grep -c . "$T/agent.txt" || true; }
NCOMMENTS() { grep -c . "$T/posted.txt" 2>/dev/null || true; }

# --- 3a. ONE fix round per (PR, head), and the review body is the brief ----
S71=$(osha ticket/TK-71)
PRRESET
PRADD 71 "$S71" ticket/TK-71 operator false 600
REVADD 71 11 CHANGES_REQUESTED "$S71" operator "$(RBODY REQUEST_CHANGES "$S71")"
touch "$T/agent-commits"
RESET
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "a REQUEST_CHANGES verdict on a harness PR must buy exactly ONE fix round, got $(NAGENT) agent calls (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
grep -q 'the route is unauthenticated' "$T/prompt.txt" && ok \
  || bad "the review BODY must be the brief the agent is given (got: $(head -c 400 "$T/prompt.txt"))"
grep -q 'REVIEW FINDINGS AS POSTED ON THE PR' "$T/prompt.txt" && ok \
  || bad "the findings must ride in as findings, not as some other evidence"
grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" && ok \
  || bad "a verified fix round must push to the PR branch (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
# WHO JUDGES THE PUSHED HEAD (#891 round 1, Nit 10). This park came from the
# review lane on a PR the conductor never queued, so the conductor's head-bound
# re-review is not what looks at it next — the project box's review lane is.
grep -q "the project box's review lane re-reviews it" "$T/comment-bodies.txt" && ok \
  || bad "the push comment must name the lane that actually re-reviews a review park (got: $(cat "$T/comment-bodies.txt"))"
grep -q "conductor's head-bound re-review" "$T/comment-bodies.txt" \
  && bad "the push comment still names the conductor on a review park: $(cat "$T/comment-bodies.txt")" || ok
[ "$(osha ticket/TK-71)" != "$S71" ] && ok || bad "the fix round must move the PR branch on the remote"
[ "$(STATEJSON tproj-TK-71 | jq -r '.review_fix_heads | join(",")')" = "$S71" ] && ok \
  || bad "the head must be recorded on the record as the (PR, head) key, got '$(STATEJSON tproj-TK-71 | jq -c '.review_fix_heads')'"
[ "$(STATEJSON tproj-TK-71 | jq -r .fixrounds)" = 1 ] && ok \
  || bad "one round must be counted, got '$(STATEJSON tproj-TK-71 | jq -r .fixrounds)'"
[ -s "$T/closed.txt" ] && bad "a review fix round must never close the PR: $(cat "$T/closed.txt")" || ok
[ -s "$T/queue.txt" ] && bad "a review fix round must never enqueue a rebuild: $(cat "$T/queue.txt")" || ok
[ "$(STATEJSON tproj-TK-71 | jq -r .outcome)" = "" ] && ok \
  || bad "a landed fix round is not a terminal, got outcome '$(STATEJSON tproj-TK-71 | jq -r .outcome)'"

# --- 3b. the SAME verdict on the SAME head again buys NOTHING -------------
: > "$T/agent.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "a second verdict on the same head must enqueue NO second job, got $(NAGENT) agent calls"
grep -q 'fix round already ran on' "$H/logs/blocked-resolver.log" && ok \
  || bad "the dedupe must say why it did nothing (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-71 | jq -r .fixrounds)" = 1 ] && ok \
  || bad "the deduped tick must spend no rung, got fixrounds=$(STATEJSON tproj-TK-71 | jq -r .fixrounds)"
[ "$(STATEJSON tproj-TK-71 | jq -r '.review_fix_heads | length')" = 1 ] && ok \
  || bad "the head must be recorded once, got $(STATEJSON tproj-TK-71 | jq -c '.review_fix_heads')"

# --- 3c. a round whose agent produces nothing is ABANDONED (BH-4149) -------
# TEST-CHANGE BH-4140 this section pinned the ESCALATED park (PR left open, a
# comment asking a person to push, an ESCALATED ALERTS line and beat). The
# terminal is br_abandon now, so the same facts are asserted for ABANDONED.
rm -f "$T/agent-commits"
S72=$(osha ticket/TK-72)
PRRESET
PRADD 72 "$S72" ticket/TK-72 operator false 600
REVADD 72 11 CHANGES_REQUESTED "$S72" operator "$(RBODY REQUEST_CHANGES "$S72")"
RESET
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "the first round on a new head must run, got $(NAGENT) agent calls"
[ "$(STATEJSON tproj-TK-72 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "a fix round that produced nothing must end ABANDONED, got outcome '$(STATEJSON tproj-TK-72 | jq -r .outcome)' (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ "$(NCOMMENTS)" = 1 ] && ok || bad "the abandon must post exactly ONE comment (the close reason), got $(NCOMMENTS): $(cat "$T/comments.txt")"
grep -q 'What was tried' "$T/comment-bodies.txt" && ok \
  || bad "the close comment must say what was tried (got: $(cat "$T/comment-bodies.txt"))"
grep -q 'ABANDONED tproj/tproj-TK-72' "$H/logs/ALERTS.log" && ok \
  || bad "the abandon must write ONE outcome ALERTS line (got: $(cat "$H/logs/ALERTS.log"))"
[ "$(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true)" = 1 ] && ok \
  || bad "exactly one ALERTS line, got $(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true)"
grep -q 'blocked-resolver-abandoned:tproj:tproj-TK-72' "$T/beats.txt" && ok \
  || bad "the abandon must fire one fleet_alert beat with its own akey (got: $(cat "$T/beats.txt"))"
grep -q 'fleet_alert' "$T/beats.txt" && ok || bad "the abandon beat must be a fleet_alert"
grep -qiE 'a person must|person picks|push a fix' "$H/logs/ALERTS.log" "$T/comment-bodies.txt" \
  && bad "nothing may ask a person to act: $(cat "$H/logs/ALERTS.log" "$T/comment-bodies.txt")" || ok
[ "$(grep -c 'pulls/72 ' "$T/closed.txt" || true)" = 1 ] && ok || bad "the abandon must close the PR exactly once: $(cat "$T/closed.txt")"
grep -q . <<<"$(grep -v '^done ' "$T/queue.txt")" && bad "the abandon must NOT enqueue a rebuild: $(cat "$T/queue.txt")" || ok
[ -s "$T/lane-alert.txt" ] && bad "the abandon pages nobody through lane-alert: $(cat "$T/lane-alert.txt")" || ok
[ "$(osha ticket/TK-72)" = "$S72" ] && ok || bad "a round that produced nothing must never push"

# --- 3d. and the NEXT tick says nothing at all ----------------------------
: > "$T/comments.txt"; : > "$T/comment-bodies.txt"; : > "$T/posted.txt"; : > "$T/agent.txt"
: > "$H/logs/ALERTS.log"; : > "$T/beats.txt"
RUN
# TEST-CHANGE BH-4140 the same silence, asserted for the ABANDONED terminal instead of ESCALATED
[ "$(NCOMMENTS)" = 0 ] && ok || bad "an abandoned PR must never be commented on twice: $(cat "$T/comments.txt")"
[ "$(NAGENT)" = 0 ] && ok || bad "an abandoned PR must buy no further rounds, got $(NAGENT)"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" && bad "a second ALERTS line is noise: $(cat "$H/logs/ALERTS.log")" || ok
grep -q 'blocked-resolver-abandoned' "$T/beats.txt" && bad "a second beat is noise: $(cat "$T/beats.txt")" || ok
grep -q 'already ran' "$H/logs/blocked-resolver.log" \
  && bad "an abandoned PR must not be re-offered to the ladder every tick (#891 item 3): $(grep 'already ran' "$H/logs/blocked-resolver.log")" || ok

# --- 3e. THE CAP: two heads already spent, a third verdict is ABANDONED ---
#         0 agent calls, one close comment naming what was tried, no rebuild.
# TEST-CHANGE BH-4140 the cap terminal was ESCALATED (PR left open, findings
# quoted in a comment for a person); it is br_abandon now, which closes the PR
# with the attempt list. The findings stay on the PR's own review thread.
S73=$(osha ticket/TK-73)
PRRESET
PRADD 73 "$S73" ticket/TK-73 operator false 600
REVADD 73 11 CHANGES_REQUESTED "$S73" operator "$(RBODY REQUEST_CHANGES "$S73")"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg h "$S73" '{project:"tproj",rkey:"tproj-TK-73",fixrounds:2,rebuilds:0,mechanicals:0,
   outcome:"",review_fix_heads:["oldheadone","oldheadtwo"],
   attempts:[{at:"2026-09-18T10:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed aaaa111 to ticket/TK-73"},
             {at:"2026-09-18T11:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed bbbb222 to ticket/TK-73"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-73.json"
RESET
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "a spent cap must buy NO third round, got $(NAGENT) agent calls"
[ "$(NCOMMENTS)" = 1 ] && ok || bad "the cap terminal must post exactly one comment, got $(NCOMMENTS)"
grep -q 'pushed aaaa111' "$T/comment-bodies.txt" && ok \
  || bad "the cap's comment must say what was already tried (got: $(cat "$T/comment-bodies.txt"))"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the cap terminal is ABANDONED, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(STATEJSON tproj-TK-73 | jq -r .fixrounds)" = 2 ] && ok \
  || bad "the cap terminal must spend no further round, got $(STATEJSON tproj-TK-73 | jq -r .fixrounds)"
[ "$(grep -c 'pulls/73 ' "$T/closed.txt" || true)" = 1 ] && ok || bad "the cap terminal closes the PR once: $(cat "$T/closed.txt")"
grep -q . <<<"$(grep -v '^done ' "$T/queue.txt")" && bad "the cap terminal must not rebuild: $(cat "$T/queue.txt")" || ok
[ "$(osha ticket/TK-73)" = "$S73" ] && ok || bad "the cap terminal must not push"
# The outcome must never read as a review request, or as a person's job.
grep -qiE 'needs a human review|please review|waiting for review|a person picks|push a fix' "$T/comment-bodies.txt" \
  && bad "the abandon is an outcome record, not a request: $(cat "$T/comment-bodies.txt")" || ok

# --- 3f. a footer review at an OLD head buys nothing END TO END -----------
PRRESET
PRADD 71 "oldheadsha" ticket/TK-71 operator false 600
REVADD 71 11 CHANGES_REQUESTED "someotherhead" operator "$(RBODY REQUEST_CHANGES someotherhead)"
RESET
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "a verdict that is not on the current head must buy nothing, got $(NAGENT)"
[ "$(NCOMMENTS)" = 0 ] && ok || bad "and it must post nothing: $(cat "$T/comments.txt")"

# --- 3g. observe mode takes no action at all -----------------------------
PRRESET
PRADD 73 "$S73" ticket/TK-73 operator false 600
REVADD 73 11 CHANGES_REQUESTED "$S73" operator "$(RBODY REQUEST_CHANGES "$S73")"
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-73.json"
RESET
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NAGENT)" = 0 ] && ok || bad "observe mode must buy no fix round, got $(NAGENT)"
[ "$(NCOMMENTS)" = 0 ] && ok || bad "observe mode must post nothing: $(cat "$T/comments.txt")"

# --- 3h. a REFUSED close records nothing and retries ---------------------
#         br_close_pr comments before it closes, so a refused comment POST is a
#         refused close: rc 75, no outcome, no ALERTS line, retried next tick.
# TEST-CHANGE BH-4140 this pinned the ESCALATED comment's refusal (one ALERTS
# line paged on the first refused tick). br_abandon pages nothing until the
# close lands, so the refused ticks write no ALERTS line at all.
PRRESET
PRADD 73 "$S73" ticket/TK-73 operator false 600
REVADD 73 11 CHANGES_REQUESTED "$S73" operator "$(RBODY REQUEST_CHANGES "$S73")"
jq -nc '{project:"tproj",rkey:"tproj-TK-73",fixrounds:2,rebuilds:0,mechanicals:0,
   outcome:"",review_fix_heads:["oldheadone","oldheadtwo"],
   attempts:[{at:"2026-09-18T10:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed aaaa111 to ticket/TK-73"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-73.json"
RESET
printf '403\n' > "$T/st-comment"   # the shared REST stub's per-route status
RUN
RUN
rm -f "$T/st-comment"
[ "$(NCOMMENTS)" = 0 ] && ok || bad "a refused comment must not be counted as posted: $(cat "$T/posted.txt")"
[ -s "$T/closed.txt" ] && bad "a refused comment must leave the PR open: $(cat "$T/closed.txt")" || ok
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = "" ] && ok \
  || bad "a refused close must write NO outcome, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true)" = 0 ] && ok \
  || bad "a refused close pages nothing, got $(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true) ALERTS lines"
grep -q 'ABANDON deferred' "$H/logs/blocked-resolver.log" && ok \
  || bad "a refused close must be SAID in the lane log (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
RUN
[ "$(NCOMMENTS)" = 1 ] && ok || bad "once gh answers, the retry must post exactly one comment, got $(NCOMMENTS)"
[ "$(grep -c 'pulls/73 ' "$T/closed.txt" || true)" = 1 ] && ok || bad "and close the PR once: $(cat "$T/closed.txt")"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the closed retry stamps ABANDONED, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true)" = 1 ] && ok \
  || bad "the closed retry writes exactly one ALERTS line, got $(grep -c 'ABANDONED' "$H/logs/ALERTS.log" || true)"
[ "$(NAGENT)" = 0 ] && ok || bad "none of these ticks may buy a round, got $(NAGENT)"

# ============================================================================
# 4. The knob is documented where an operator looks (B5).
# ============================================================================
grep -q 'BR_REVIEW_FIX_ROUNDS' "$DIR/bin/blocked-resolver.sh" && ok \
  || bad "BR_REVIEW_FIX_ROUNDS must be named in the resolver's own header"
grep -q 'BR_REVIEW_LOOKBACK_SECS' "$DIR/bin/blocked-resolver.sh" && ok \
  || bad "BR_REVIEW_LOOKBACK_SECS must be named in the resolver's own header"
grep -q 'BR_REVIEW_FIX_ROUNDS' "$DIR/docs/MERGE-CONDUCTOR.md" && ok \
  || bad "BR_REVIEW_FIX_ROUNDS must be documented in docs/MERGE-CONDUCTOR.md"
grep -q 'BR_REVIEW_LOOKBACK_SECS' "$DIR/docs/MERGE-CONDUCTOR.md" && ok \
  || bad "BR_REVIEW_LOOKBACK_SECS must be documented in docs/MERGE-CONDUCTOR.md"

echo "resolver-review-consumer-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

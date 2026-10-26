#!/bin/bash
# tests/blocked-resolver-no-person.bh-4140-test.sh — BH-4149 (BH-4140 slice 5):
# no blocked-resolver terminal waits on a person.
#
# THE RULE (the operator, 2026-09-13): nothing in this harness waits on a human review.
# A BLOCKED_HUMAN reason whose agent rungs are spent ends in ONE ABANDONED
# outcome record (the PR closed with what was tried, re-filed through the
# board), never in an indefinite park a person has to pick up.
#
# THE ROWS (plan.md "Acceptance tests"):
#   N1  real tick, review-changes-requested at its fix-round cap -> ABANDONED,
#       PR closed once, one ABANDONED ALERTS line + beat, no ESCALATED anywhere
#   N2  that tick pages nobody: lane-alert silent, no "a person must / person
#       picks / push a fix" in ALERTS.log or any posted body
#   N3  a second tick writes no record, no alert, no close, no comment
#   N4  negative: rungs NOT spent (fixrounds=0) -> one fix round, no terminal
#   N5  a refused close records nothing and is retried; the retry closes once
#   N6  observe mode: WOULD abandon, nothing closed, nothing recorded
#   N7  a legacy ESCALATED record stays terminal (no backfill, no mass close)
#   N8  a hand PR with no ticket key: ABANDONED and closed, no queue/ledger row
#   N9  a lead MERGE standing on the PR's head keeps it open at the review
#       terminal (the conductor merges it); an unreadable verdicts table closes
#       nothing that tick; a lead BLOCK there still ends ABANDONED
#   P1  lifted br_fix_round: a lead-blocked round that answers nothing records
#       fix-round-noop, pushes nothing, pages nobody, and runs br_fix_terminal
#   P2  a head already frozen in noop_heads goes to br_fix_terminal with no
#       agent call and no review/compare/permission read
#   P3  real tick: a review PR whose head is frozen in noop_heads is a
#       candidate again, ends ABANDONED, and a second tick adds nothing
#   U1  a hotfix-migration-hold row: one log line naming the production-DB gate,
#       no alert, no close, no record
#   U2  an unmapped reason's warn alert no longer offers "human-only"
#
# Run from anywhere: tests/blocked-resolver-no-person.bh-4140-test.sh  (exit 0 = all pass)
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
    '{id:$i, state:$s, commit_id:$c, user:{login:$l, type:(if ($l | endswith("[bot]")) then "Bot" else "User" end)}, body:$b}' >> "$T/revrows-$1"
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
# The real lane, end to end: a real local clone, an "agent" that commits only
# when asked to, and the real bin/blocked-resolver.sh tick.
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
mkbranch ticket/TK-73
mkbranch ticket/TK-74
mkbranch ticket/TK-75
mkbranch hand/fixup
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
osha() { git -C "$ORIGIN" rev-parse "$1"; }

cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf 'agent-call %s %s\n' "\$1" "\$2" >> "$T/agent.txt"
if [ -f "$T/agent-commits" ]; then
  printf 'the finding, answered\n' > answered.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: answered the review findings" >/dev/null 2>&1
fi
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
RECF() { printf '%s' "$H/state/blocked-resolver/tproj/$1.json"; }
STATEJSON() { cat "$(RECF "$1")" 2>/dev/null; }
RESET() { : > "$T/agent.txt"; : > "$T/closed.txt"
          : > "$T/comments.txt"; : > "$T/comment-bodies.txt"; : > "$T/posted.txt"
          : > "$T/queue.txt"; : > "$T/beats.txt"; : > "$T/lane-alert.txt"
          : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
          rm -f "$T/st-patch" "$T/patch-noflip" "$T/agent-commits"
          scratch_rm "$H/state/gh-budget"; }
NAGENT()  { grep -c . "$T/agent.txt" || true; }
NCLOSES() { grep -c -- "-X PATCH repos/o/tproj/pulls/$1 " "$T/closed.txt" 2>/dev/null || true; }
NABAND()  { grep -c '^.*\[blocked-resolver\] ABANDONED tproj/' "$H/logs/ALERTS.log" 2>/dev/null || true; }
NATT()    { STATEJSON "$1" | jq -r '(.attempts // []) | length' 2>/dev/null; }
PERSON='a person must|person picks|push a fix'
SPENT() { # SPENT <num> <head> <fixrounds> [extra-json] — a review record at tproj-TK-<num>
  mkdir -p "$H/state/blocked-resolver/tproj"
  local x="${4:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg k "tproj-TK-$1" --argjson n "$3" --argjson x "$x" \
    '{project:"tproj",rkey:$k,fixrounds:$n,rebuilds:0,mechanicals:0,outcome:"",
      review_fix_heads:["oldheadone","oldheadtwo"],
      attempts:[{at:"2026-09-18T10:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed aaaa111"},
                {at:"2026-09-18T11:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed bbbb222"}]} + $x' \
    > "$(RECF "tproj-TK-$1")"
}
REVPR() { # REVPR <num> <head> <branch> — one open harness PR with a footer CR at its head
  # BH-8419: the operator opens the PR, but the harness's footer review is the
  # App's (cromford[bot], type Bot); a operator review is a person's.
  PRADD "$1" "$2" "$3" operator false 600
  REVADD "$1" 11 CHANGES_REQUESTED "$2" 'cromford[bot]' "$(RBODY REQUEST_CHANGES "$2")"
}

# --- N1 + N2: the spent review row ends ABANDONED and pages nobody ---------
S73=$(osha ticket/TK-73)
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2
RESET
RUN
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "N1 a review row with its fix rounds spent must end ABANDONED, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)' (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(NAGENT)" = 0 ] && ok || bad "N1 a spent cap buys no agent call, got $(NAGENT)"
[ "$(NCLOSES 73)" = 1 ] && ok || bad "N1 the PR must be closed exactly once, got $(NCLOSES 73): $(cat "$T/closed.txt")"
[ "$(NABAND)" = 1 ] && ok || bad "N1 exactly one ABANDONED ALERTS line, got $(NABAND): $(cat "$H/logs/ALERTS.log")"
grep -q 'blocked-resolver-abandoned:tproj:tproj-TK-73' "$T/beats.txt" && ok \
  || bad "N1 the abandon must fire its fleet_alert beat (beats: $(cat "$T/beats.txt"))"
[ "$(STATEJSON tproj-TK-73 | jq '[.attempts[] | select(.action == "abandoned")] | length')" = 1 ] && ok \
  || bad "N1 exactly one abandoned attempt on the record: $(STATEJSON tproj-TK-73 | jq -c .attempts)"
grep -q 'pushed aaaa111' "$T/comment-bodies.txt" && ok \
  || bad "N1 the close comment must carry what was tried (got: $(cat "$T/comment-bodies.txt"))"
grep -q 'ESCALATED' "$H/logs/ALERTS.log" "$T/beats.txt" "$H/logs/blocked-resolver.log" "$(RECF tproj-TK-73)" \
  && bad "N1 nothing may be ESCALATED any more: $(grep -h ESCALATED "$H/logs/ALERTS.log" "$T/beats.txt" "$H/logs/blocked-resolver.log" "$(RECF tproj-TK-73)")" || ok
[ ! -s "$T/lane-alert.txt" ] && ok || bad "N2 the terminal pages nothing through lane-alert: $(cat "$T/lane-alert.txt")"
grep -qiE "$PERSON" "$H/logs/ALERTS.log" "$T/comment-bodies.txt" "$T/beats.txt" \
  && bad "N2 nothing may ask a person to act: $(grep -hiE "$PERSON" "$H/logs/ALERTS.log" "$T/comment-bodies.txt" "$T/beats.txt")" || ok
[ "$(osha ticket/TK-73)" = "$S73" ] && ok || bad "N1 the terminal pushes nothing"

# --- N3: the second tick writes nothing ----------------------------------
A0=$(NATT tproj-TK-73); C0=$(NCLOSES 73)
: > "$H/logs/ALERTS.log"; : > "$T/beats.txt"; : > "$T/posted.txt"; : > "$T/agent.txt"; : > "$T/lane-alert.txt"
RUN
[ "$(NATT tproj-TK-73)" = "$A0" ] && ok || bad "N3 a second tick must add no record, attempts $A0 -> $(NATT tproj-TK-73)"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "N3 a second tick must write no ALERTS line: $(cat "$H/logs/ALERTS.log")"
[ "$(NCLOSES 73)" = "$C0" ] && ok || bad "N3 a second tick must close nothing ($C0 -> $(NCLOSES 73))"
[ ! -s "$T/posted.txt" ] && ok || bad "N3 a second tick must post nothing: $(cat "$T/posted.txt")"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "N3 and page nothing: $(cat "$T/lane-alert.txt")"
[ "$(NAGENT)" = 0 ] && ok || bad "N3 and buy no round, got $(NAGENT)"

# --- N4: rungs NOT spent still run the next agent rung -------------------
S74=$(osha ticket/TK-74)
PRRESET; REVPR 74 "$S74" ticket/TK-74
rm -f "$(RECF tproj-TK-74)"
RESET; touch "$T/agent-commits"
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "N4 an unspent review row must run its fix round, got $(NAGENT) agent calls (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-74 | jq -r '.outcome // ""')" = "" ] && ok \
  || bad "N4 a fix round is not a terminal, got '$(STATEJSON tproj-TK-74 | jq -r .outcome)'"
[ "$(NCLOSES 74)" = 0 ] && ok || bad "N4 nothing may be closed: $(cat "$T/closed.txt")"
[ "$(NABAND)" = 0 ] && ok || bad "N4 no ABANDONED line: $(cat "$H/logs/ALERTS.log")"

# --- N5: a refused close records nothing, and the retry closes once -------
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2
RESET
printf '403\n' > "$T/st-patch"; touch "$T/patch-noflip"
RUN
rm -f "$T/st-patch" "$T/patch-noflip"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = "" ] && ok \
  || bad "N5 a refused close must record NO outcome, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(NABAND)" = 0 ] && ok || bad "N5 a refused close must write no ABANDONED line: $(cat "$H/logs/ALERTS.log")"
grep -q 'ABANDON deferred' "$H/logs/blocked-resolver.log" && ok \
  || bad "N5 the deferral must be said in the lane log (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
: > "$T/closed.txt"
RUN
[ "$(NCLOSES 73)" = 1 ] && ok || bad "N5 the retry must close exactly once, got $(NCLOSES 73)"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "N5 the retry stamps ABANDONED, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(NABAND)" = 1 ] && ok || bad "N5 exactly one ABANDONED line across both ticks, got $(NABAND)"

# --- N6: observe mode -----------------------------------------------------
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2
RESET
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'WOULD abandon' "$H/logs/blocked-resolver.log" && ok \
  || bad "N6 observe mode must say WOULD abandon (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(NCLOSES 73)" = 0 ] && ok || bad "N6 observe mode closes nothing: $(cat "$T/closed.txt")"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = "" ] && [ "$(NATT tproj-TK-73)" = 2 ] && ok \
  || bad "N6 observe mode records nothing: $(STATEJSON tproj-TK-73)"

# --- N7: a legacy ESCALATED record stays terminal (no backfill) ------------
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2 '{"outcome":"ESCALATED","escalated_rkey":"o-tproj-73"}'
RESET
RUN
[ "$(NCLOSES 73)" = 0 ] && ok || bad "N7 a legacy ESCALATED PR must not be closed on deploy: $(cat "$T/closed.txt")"
[ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ESCALATED ] && ok \
  || bad "N7 the legacy outcome stays as written, got '$(STATEJSON tproj-TK-73 | jq -r .outcome)'"
[ "$(NAGENT)" = 0 ] && [ "$(NABAND)" = 0 ] && ok || bad "N7 no round and no ABANDONED line (agent $(NAGENT), abandoned $(NABAND))"

# --- N8: a hand PR with no ticket key ------------------------------------
S80=$(osha hand/fixup)
PRRESET; REVPR 80 "$S80" hand/fixup
jq -c '.title = "a hand fix with no ticket"' "$T/pr-80.json" > "$T/pr-80.tmp" && mv "$T/pr-80.tmp" "$T/pr-80.json"
jq -c '.title = "a hand fix with no ticket"' "$T/prrows" > "$T/prrows.tmp" && mv "$T/prrows.tmp" "$T/prrows"; PRWRITE
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"o-tproj-80",fixrounds:2,rebuilds:0,mechanicals:0,outcome:"",review_fix_heads:["x","y"],
   attempts:[{at:"2026-09-18T10:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed cccc333"}]}' \
  > "$(RECF o-tproj-80)"
RESET
RUN
[ "$(STATEJSON o-tproj-80 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "N8 a keyless hand PR at its cap ends ABANDONED too, got '$(STATEJSON o-tproj-80 | jq -r .outcome)' (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(NCLOSES 80)" = 1 ] && ok || bad "N8 and is closed once, got $(NCLOSES 80)"
grep -q '^done ' "$T/queue.txt" && bad "N8 no ticket key means no queue row: $(cat "$T/queue.txt")" || ok
[ ! -s "$T/lane-alert.txt" ] && ok || bad "N8 pages nobody: $(cat "$T/lane-alert.txt")"

# --- N9: the review terminal asks the verdicts table first -----------------
# A STUB of bin/lib/verdicts.sh keyed on files, the shape
# tests/blocked-resolver-supersede.bh-1642-test.sh uses: $T/verdicts is
# "<full-sha> <VERDICT>" per line, $T/vd-down makes every read unreadable.
cat > "$H/bin/lib/verdicts.sh" <<EOF
vd_standing() {
  [ -e "$T/vd-down" ] && return 2
  [[ "\$3" =~ ^[0-9a-f]{40}\$ ]] || return 2
  local v; v=\$(awk -v h="\$3" '\$1==h {print \$2; exit}' "$T/verdicts" 2>/dev/null)
  [ -n "\$v" ] || return 1
  printf '%s\tlead\t7\t2026-10-04T00:00:00Z\t-\toperator\n' "\$v"
}
EOF
for v in MERGE MERGE-WITH-NOTES; do
  PRRESET; REVPR 73 "$S73" ticket/TK-73
  SPENT 73 "$S73" 2
  RESET; printf '%s %s\n' "$S73" "$v" > "$T/verdicts"
  RUN
  [ "$(NCLOSES 73)" = 0 ] && [ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = "" ] && [ "$(NABAND)" = 0 ] && ok \
    || bad "N9 a lead $v on the head must keep the PR open (closes $(NCLOSES 73), outcome '$(STATEJSON tproj-TK-73 | jq -r .outcome)'; log: $(tail -3 "$H/logs/blocked-resolver.log"))"
  grep -q "lead $v stands on" "$H/logs/blocked-resolver.log" && ok \
    || bad "N9 the lane log says the lead cleared the head (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
  [ ! -s "$T/lane-alert.txt" ] && ok || bad "N9 a cleared head pages nobody: $(cat "$T/lane-alert.txt")"
done
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2
RESET; : > "$T/verdicts"; touch "$T/vd-down"
RUN
rm -f "$T/vd-down"
[ "$(NCLOSES 73)" = 0 ] && [ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = "" ] && ok \
  || bad "N9 an unreadable verdicts table closes nothing (closes $(NCLOSES 73), outcome '$(STATEJSON tproj-TK-73 | jq -r .outcome)')"
PRRESET; REVPR 73 "$S73" ticket/TK-73
SPENT 73 "$S73" 2
RESET; printf '%s BLOCK\n' "$S73" > "$T/verdicts"
RUN
[ "$(NCLOSES 73)" = 1 ] && [ "$(STATEJSON tproj-TK-73 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "N9 a lead BLOCK on the head is no clearance: ABANDONED, closed once (closes $(NCLOSES 73), outcome '$(STATEJSON tproj-TK-73 | jq -r .outcome)')"
rm -f "$H/bin/lib/verdicts.sh" "$T/verdicts"

# --- P3: a review head frozen by fix-round-noop is finished, not parked ---
S75=$(osha ticket/TK-75)
PRRESET
PRADD 75 "$S75" ticket/TK-75 operator false 600
REVADDA 75 11 CHANGES_REQUESTED "$S75" operator MEMBER "$HBODY_PLAIN"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg h "$S75" '{project:"tproj",rkey:"tproj-TK-75",fixrounds:1,rebuilds:0,mechanicals:0,outcome:"",
   noop_heads:[$h],review_fix_heads:[$h],
   attempts:[{at:"2026-09-24T10:00:00Z",action:"fix-round-noop",reason:"review-changes-requested",detail:"changed no file the lead names"}]}' \
  > "$(RECF tproj-TK-75)"
RESET
RUN
[ "$(STATEJSON tproj-TK-75 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "P3 a noop-frozen review head must end ABANDONED, not park, got '$(STATEJSON tproj-TK-75 | jq -r .outcome)' (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(NAGENT)" = 0 ] && ok || bad "P3 a frozen head buys no agent call, got $(NAGENT)"
[ "$(NCLOSES 75)" = 1 ] && ok || bad "P3 the PR is closed once, got $(NCLOSES 75)"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "P3 pages nobody: $(cat "$T/lane-alert.txt")"
A0=$(NATT tproj-TK-75); : > "$H/logs/ALERTS.log"; : > "$T/posted.txt"
RUN
[ "$(NATT tproj-TK-75)" = "$A0" ] && [ ! -s "$H/logs/ALERTS.log" ] && [ "$(NCLOSES 75)" = 1 ] && [ ! -s "$T/posted.txt" ] && ok \
  || bad "P3 a second tick adds nothing (attempts $A0 -> $(NATT tproj-TK-75), closes $(NCLOSES 75), alerts: $(cat "$H/logs/ALERTS.log"))"

# --- U1 + U2: the conductor's unmapped reasons -----------------------------
PRRESET
MCS="$H/state/merge-conductor"
UROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#$1" "$NOW" "$S73" "$S73" "$2" \
           "https://github.com/o/tproj/pull/$1" >> "$MCS/pr-state.tsv"; }
: > "$MCS/pr-state.tsv"
UROW 90 "hotfix-migration-hold: 0042_add_ledger.sql needs the prod apply"
UROW 91 "static-guards-red"
scratch_rm "$H/state/blocked-resolver/unmapped"; scratch_rm "$H/state/blocked-resolver/unmapped-family"
RESET
RUN
[ "$(grep -c 'o/tproj#90' "$H/logs/blocked-resolver.log" || true)" = 1 ] && ok \
  || bad "U1 exactly one log line for the migration hold (log: $(grep '#90' "$H/logs/blocked-resolver.log"))"
grep 'o/tproj#90' "$H/logs/blocked-resolver.log" | grep -q 'production-DB' && ok \
  || bad "U1 the line must name the production-DB gate (log: $(grep '#90' "$H/logs/blocked-resolver.log"))"
grep -q 'hotfix-migration-hold' "$T/lane-alert.txt" && bad "U1 a migration hold raises no alert: $(cat "$T/lane-alert.txt")" || ok
[ "$(NCLOSES 90)" = 0 ] && [ ! -e "$H/state/blocked-resolver/tproj/o-tproj-90.json" ] && ok \
  || bad "U1 a migration hold is never closed or recorded"
grep -q -- '--severity warn --id br-unmapped-static-guards-red ' "$T/lane-alert.txt" && ok \
  || bad "U2 an unmapped reason keeps its warn alert (got: $(cat "$T/lane-alert.txt"))"
grep -q 'human-only' "$T/lane-alert.txt" && bad "U2 the alert must not offer 'human-only': $(cat "$T/lane-alert.txt")" || ok
grep 'br-unmapped-static-guards-red' "$T/lane-alert.txt" | grep -q 'no agent rung' && ok \
  || bad "U2 the alert names the missing agent rung (got: $(cat "$T/lane-alert.txt"))"
: > "$MCS/pr-state.tsv"

# ============================================================================
# P1 + P2 — br_fix_round itself, lifted by name with git, the agent and the
# bookkeeping stubbed (the fixture of tests/fixround-lead-reviews.bh-2200-test.sh,
# copied, not shared). br_fix_terminal is a RECORDER here: P1/P2 pin that the
# noop path and the frozen-head gate hand the park to it, and the N/P3 rows
# above pin what it does. Runs LAST: its fake gh goes first on PATH.
# ============================================================================
P="$T/p"
BR="$DIR/bin/blocked-resolver.sh"
SLUG=o/tproj
URL="https://github.com/$SLUG/pull/7"
HEAD1=1111111111111111111111111111111111111111   # the PR head the lead reviewed
HEAD2=2222222222222222222222222222222222222222   # the head after a main merge
NEWHEAD=3333333333333333333333333333333333333333 # what the fix round commits
LEAD_HDR='LEAD FINDINGS — every item must be addressed in code'
LBODY='1. bin/lib/widget.sh:42 still builds the SQL by hand — bind it.
2. tests/widget-test.sh never covers the empty list.'
FOOTER='_Automated harness review (Fable) of '
HBODY_FOOTER="1. HIGH src/rate.ts:12 the route is unauthenticated.

TIER: 2
VERDICT: REQUEST_CHANGES

---
${FOOTER}${HEAD1}. Static review — no build run._"

mkdir -p "$P/fakebin" "$P/gh"
# A SCRATCH HARNESS, before anything sources bin/lib/gh-rest.sh: its ETag cache
# (gh-rest-etag.sh) reads and deletes under $HARNESS/state/gh-etag, and the
# default is /root/harness. Every child shell below inherits this.
export HARNESS="$P/h"
mkdir -p "$HARNESS/state/gh-etag" "$HARNESS/logs"

# --- the fake GitHub ----------------------------------------------------------
#   $P/gh/reviews.json            pulls/7/reviews (--paginate, --jq applied)
#   $P/gh/reviews-fail            that read fails
#   $P/gh/perm-<login>.json       collaborators/<login>/permission
#   $P/gh/perm-fail               that read fails
#   $P/gh/compare-<a>-<b>.json    compare/<a>...<b>
#   $P/gh/pr.json                 pulls/7
cat > "$P/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$P/gh.log"
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
emit() { if [ -n "\$JQX" ]; then jq -r "\$JQX" "\$1"; else cat "\$1"; fi; }
# The REST contract (bin/lib/gh-rest.sh) reads under -i: a status line, a blank
# line, the body. Every decision read in this suite arrives that way.
send() { printf 'HTTP/1.1 %s\r\ncontent-type: application/json\r\n\r\n' "\$1"; [ -n "\${2:-}" ] && cat "\$2"; printf '\n'; }
case "\$*" in
  *"-i -X GET"*"/pulls/7/reviews"*)
    [ -f "$P/gh/reviews-fail" ] && { printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}\n'; exit 1; }
    send "200 OK" "$P/gh/reviews.json" ;;
  *"-i -X GET"*"/collaborators/"*"/permission"*)
    [ -f "$P/gh/perm-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{}\n'; exit 1; }
    L=\$(printf '%s' "\$*" | sed -nE 's#.*/collaborators/([^/]+)/permission.*#\1#p')
    [ -f "$P/gh/perm-\$L.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
    send "200 OK" "$P/gh/perm-\$L.json" ;;
  *"-i -X GET"*"/compare/"*)
    [ -f "$P/gh/compare-fail" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{}\n'; exit 1; }
    C=\$(printf '%s' "\$*" | sed -nE 's#.*/compare/([^ ?]+).*#\1#p' | sed 's#\.\.\.#-#')
    [ -f "$P/gh/compare-\$C.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
    send "200 OK" "$P/gh/compare-\$C.json" ;;
  *"-i -X GET"*"/issues/7/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"/pulls/7"*) emit "$P/gh/pr.json" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$P/fakebin/gh"
export PATH="$P/fakebin:$PATH"

REV() { # REV <id> <state> <commit> <login> <association> <type> <body> — appended, oldest first
  jq -nc --argjson i "$1" --arg s "$2" --arg c "$3" --arg l "$4" --arg a "$5" --arg ty "$6" --arg b "$7" \
    '{id:$i, state:$s, commit_id:$c, user:{login:$l, type:$ty}, author_association:$a, body:$b}' >> "$P/gh/revrows"
  jq -s . "$P/gh/revrows" > "$P/gh/reviews.json"
}
RESET() { scratch_rm "$P/gh"; mkdir -p "$P/gh"; : > "$P/gh/revrows"; echo '[]' > "$P/gh/reviews.json"; : > "$P/gh.log"
          jq -nc --arg h "$HEAD1" '{number:7, head:{sha:$h, ref:"ticket/TK-7"}, base:{ref:"main"}}' > "$P/gh/pr.json"; }
PERM() { jq -nc --arg p "$2" '{permission:$p, role_name:$p}' > "$P/gh/perm-$1.json"; }
COMPARE() { # COMPARE <base> <head> <status> <json-array-of-{sha,parents:n}>
  jq -nc --arg s "$3" --argjson c "$4" '{status:$s, commits:[$c[] | {sha:.sha, parents:[range(.parents) | {sha:"p"}]}]}' > "$P/gh/compare-$1-$2.json"
}

# --- the functions under test, lifted by name ------------------------------------
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BR"; }
{
  grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BR"
  for fn in br_review_rows br_review_harness_pick br_review_harness_newest br_lead_merges_only br_lead_pick \
            br_lead_review br_review_newest br_findings br_findings_join; do lift "$fn"; done
} > "$P/lib.sh"
cat > "$P/stubs.sh" <<EOF
say() { printf '%s\n' "\$*" >> "$P/say.log"; }
harness_verdict_author_match() { case "\${1:-}" in operator|cromford|cromford\[bot\]|app/cromford) return 0 ;; esac; return 1; }
harness_verdict_authors_json() { echo '["operator","cromford[bot]","cromford"]'; }
br_slug_of_url() { printf '%s' "$SLUG"; }
mc_num_of_url() { printf '%s' "\$1" | sed -nE 's#.*/pull/([0-9]+).*#\1#p'; }
EOF
# The REAL REST contract: every review / permission / compare read goes through it.
printf '. "%s/bin/lib/gh-rest.sh"\n' "$DIR" >> "$P/stubs.sh"
L() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$P/stubs.sh" "$P/lib.sh" "$@"; }
H="$P/h"; ST="$P/st"; REPOS="$P/repos"
mkdir -p "$H/bin" "$ST/tproj" "$REPOS/tproj/.git"
printf '#!/bin/bash\n[ "$2" = repo ] && echo %s\nexit 0\n' "$SLUG" > "$H/bin/fleet-conf.sh"
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s' "\$6" > "$P/prompt.txt"
printf 'agent %s\n' "\$1" >> "$P/agent.log"
[ -n "\${AGENT_UNADDR:-}" ] && printf '%s\n' "\$AGENT_UNADDR" > "$ST/tproj/ck.unaddressed.md"
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$P/alerts.log"
EOF
chmod +x "$H/bin/"*.sh
lift br_fix_round > "$P/fixround.sh"
[ -s "$P/fixround.sh" ] && ok || bad "F0 br_fix_round could not be lifted"
cat > "$P/fr-stubs.sh" <<EOF
OBSERVE=0; H="$H"; ST="$ST"; LOG="$P/br.log"; REPOS="$REPOS"; FIX_AGENT_TIMEOUT=60; BR_EXECUTE_MODEL_ENV=BR_EXECUTE_MODEL
LEASE=$HEAD1
STAMP() { printf '2026-09-24 00:00:00Z'; }
br_event() { printf '%s\n' "\$*" >> "$P/events.log"; }
br_file() { printf '%s' "$P/rec.json"; }
br_load() { cat "$P/rec.json" 2>/dev/null || echo '{}'; }
br_push_field() { local c; c=\$(br_load | jq -c --arg k "\$3" --arg v "\$4" '.[\$k] = (((.[\$k] // []) + [\$v]) | unique)') && printf '%s\n' "\$c" > "$P/rec.json"; }
br_has_field_value() { printf '%s' "\${1:-}" | jq -e --arg k "\$2" --arg v "\$3" '((.[\$k] // []) | index(\$v)) != null' >/dev/null 2>&1; }
br_json_edit() { :; }
br_cap_key() { printf ck; }
br_num() { printf 0; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal %s\n' "\$3" >> "$P/terminal.log"; }
br_pr_ref() { printf '%s ticket/TK-7 %s\n' "$SLUG" "$HEAD1"; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$P/terminal.log"; }
br_ladder_class() { case "\$1" in head-not-reapproved) echo review-blocked ;; *) echo "" ;; esac; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$P/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
br_pr_comment() { printf 'comment %s\n' "\$2" >> "$P/comments.log"; }
br_fix_push_note() { :; }
gi_check() { return 0; }
br_rebuild_fresh() { printf 'rebuild %s\n' "\$3" >> "$P/terminal.log"; }
# BH-2504: the push goes through bin/lib/hold-push.sh (sourced in FR below). This
# suite is about the findings, not the hold, so its park has no GitHub issue
# behind it (rc 1 = a board ticket): the push is the lease alone.
br_hold_issue() { return 1; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  printf 'git %s\n' "\${a[*]}" >> "$P/git.log"
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/main") echo mainsha ;;
    "rev-parse --verify -q origin/"*) echo "\$LEASE" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD"|"rev-parse --short HEAD") echo "$NEWHEAD" ;;
    "log --no-merges --name-only --format= HEAD --not"*) cat "$P/own-files" 2>/dev/null ;;
    # the subcommand is spelled split: this stub never scans the tree, and an
    # unsplit literal puts the suite in test-impact's always-run set (ti_always_re).
    "ls""-files") cat "$P/tracked-files" 2>/dev/null ;;
    "push "*) printf '%s\n' "\${a[*]}" >> "$P/push.log" ;;
    *) return 0 ;;
  esac
}
EOF
FR() { # FR <reason> — the real br_fix_round in a fresh shell
  rm -f "$P/prompt.txt" "$P/agent.log" "$P/git.log" "$P/terminal.log" "$P/record.log" "$P/push.log" \
        "$P/comments.log" "$P/alerts.log" "$P/events.log" "$ST/tproj/ck.unaddressed.md"
  bash -c '. "$7/bin/lib/hold-push.sh"; . "$1"; . "$2"; . "$3"; . "$4"; br_fix_round tproj rk "$5" "$6" /rec TK-7' _ \
    "$P/stubs.sh" "$P/lib.sh" "$P/fr-stubs.sh" "$P/fixround.sh" "$1" "$URL" "$DIR" >/dev/null 2>&1
}
LEADPR() { RESET; REV 11 CHANGES_REQUESTED "$HEAD1" operator MEMBER User "${1:-$LBODY}"; rm -f "$P/rec.json"; }
# The files the repo tracks (git's tracked-file list): a finding names a file only when it is one of these.
printf '%s\n' bin/lib/widget.sh tests/widget-test.sh README.md catalog/lanes.d/x.conf catalog/lanes.d/y.conf src/app.ts > "$P/tracked-files"

# --- P1: a lead-blocked round that answers nothing ends on the ladder ------
LEADPR; : > "$P/own-files"
FR head-not-reapproved
[ -s "$P/agent.log" ] && ok || bad "P1 the fix round must run (say: $(tail -3 "$P/say.log" 2>/dev/null))"
grep -q 'fix-round-noop' "$P/record.log" 2>/dev/null && ok || bad "P1 the attempt is still recorded fix-round-noop: $(cat "$P/record.log" 2>/dev/null)"
[ ! -s "$P/push.log" ] && ok || bad "P1 a noop pushes nothing: $(cat "$P/push.log")"
jq -e --arg h "$HEAD1" '(.noop_heads // []) | index($h) != null' "$P/rec.json" >/dev/null 2>&1 && ok \
  || bad "P1 the head is still remembered in noop_heads: $(cat "$P/rec.json" 2>/dev/null)"
[ ! -s "$P/alerts.log" ] && ok || bad "P1 a noop must page nobody: $(cat "$P/alerts.log")"
[ "$(grep -c '^terminal head-not-reapproved$' "$P/terminal.log" 2>/dev/null || true)" = 1 ] && [ "$(grep -c . "$P/terminal.log")" = 1 ] && ok \
  || bad "P1 the noop must hand the park to br_fix_terminal exactly once: $(cat "$P/terminal.log" 2>/dev/null)"

# --- P2: a head already frozen goes to the terminal, reading nothing --------
: > "$P/gh.log"
FR head-not-reapproved
[ ! -s "$P/agent.log" ] && ok || bad "P2 a frozen head buys no agent call"
grep -E '/reviews|/compare/|/permission' "$P/gh.log" >/dev/null 2>&1 \
  && bad "P2 a frozen head makes ZERO review/compare/permission reads: $(cat "$P/gh.log")" || ok
[ "$(grep -c '^terminal head-not-reapproved$' "$P/terminal.log" 2>/dev/null || true)" = 1 ] && ok \
  || bad "P2 a frozen head must go to br_fix_terminal exactly once, not return silently: $(cat "$P/terminal.log" 2>/dev/null)"
[ ! -s "$P/alerts.log" ] && ok || bad "P2 and page nobody: $(cat "$P/alerts.log")"
# ...and the review family: the gate sits before the (PR, head) dedupe, which a
# frozen review head also carries (its round was marked before the spend).
printf '{"noop_heads":["%s"],"review_fix_heads":["%s"]}\n' "$HEAD1" "$HEAD1" > "$P/rec.json"
: > "$P/gh.log"
FR review-changes-requested
[ "$(grep -c '^terminal review-changes-requested$' "$P/terminal.log" 2>/dev/null || true)" = 1 ] && ok \
  || bad "P2 a frozen REVIEW head must reach br_fix_terminal, not the 'already ran' dedupe: $(cat "$P/terminal.log" 2>/dev/null; tail -2 "$P/say.log")"

echo "blocked-resolver-no-person.bh-4140: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

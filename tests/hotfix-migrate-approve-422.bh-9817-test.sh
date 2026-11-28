#!/bin/bash
# tests/hotfix-migrate-approve-422.bh-9817-test.sh — BH-9817: the before-merge
# approval of bin/lib/hotfix-migrate-workflow.sh (hm_wf_approve_head).
#
# What it pins:
#   * the approval goes out as the reviewer (hub) App when a builders App is the
#     PR author, and on the default credential when the reviewer App is the
#     author (the rule bin/review-prs.sh rp_author_is_reviewer_app applies);
#   * GitHub's response body (message, errors) reaches the proof comment and
#     $BUILD/hotfix-approve.err. `gh api` prints that body on STDOUT;
#   * a 422 is terminal for that head: decision needs-operator, the ledger
#     records approve_refused.head, and a re-run on the same head makes 0 review
#     calls and posts 0 comments. A new head is tried again once;
#   * any other status (500, 403, a network error) stays `retry`.
#
# The real bin/hotfix-migrate.sh runs end to end against a scratch $HARNESS. A
# fake `gh` logs argv plus GH_TOKEN and answers from a per-case fixture dir
# ($FX). Like the real gh, it writes a refused POST's JSON body to stdout and
# `gh: <text> (HTTP <code>)` to stderr. A fake bin/gh-token.sh mints one fixture
# token per App profile. 0 network calls. Each case has its own fixture dir,
# build dir and PR number.
#
# Cases: R1 the repro (the body is on stdout only); B1 a 422 on every identity;
# B2 a re-run on the same head; B3 a new head; B4 the status table; I1 the
# builders App is the author; I2 the reviewer App is the author.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hotfix-migrate-approve-422.bh-9817-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: hotfix-migrate-approve-422: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }

# ---- the scratch harness ----------------------------------------------------
HH="$T/h"
mkdir -p "$HH/logs" "$HH/state" "$HH/locks" "$HH/env" "$HH/builds" "$T/fakebin" "$T/set"
scratch_install_closure bin/hotfix-migrate.sh "$HH" >/dev/null || bad "closure install of hotfix-migrate.sh"
scratch_install_closure bin/check-migration-appliable.sh "$HH" >/dev/null || bad "closure install of check-migration-appliable.sh"
[ -r "$HH/bin/lib/hotfix-migrate-workflow.sh" ] && ok || bad "the closure must carry bin/lib/hotfix-migrate-workflow.sh"
printf '#!/bin/bash\nexit 0\n' > "$HH/bin/beat.sh"; chmod +x "$HH/bin/beat.sh"
# One fixture installation token per App profile: the hub (reviewer) App when
# GH_APP_PROFILE is empty or `hub`, the builders App when it is `builders`.
cat > "$HH/bin/gh-token.sh" <<'EOF'
#!/bin/bash
case "$1" in --*) exit 0 ;; esac
case "${GH_APP_PROFILE:-}" in
  ''|hub)   echo ghs_hub-fixture ;;
  builders) echo ghs_builders-fixture ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$HH/bin/gh-token.sh"
# The reviewer App's slug, in the file gh-app-auth.sh and gh-pr-list.sh read.
printf 'GH_APP_SLUG=cromford\nGH_APP_ID=1\n' > "$HH/env/github-app.env"
: > "$HH/env/global.env"
cat > "$HH/bin/jobs-client.sh" <<EOF
setting_get() { [ -f "$T/set/\$1" ] || return 2; cat "$T/set/\$1"; }
EOF
cat > "$HH/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
exit 0
EOF
chmod +x "$HH/bin/alert-line.sh"
MKROW='{"before_merge":1,"workflow":"migrate-branch.yml","files_input":"file","max_files":1,"per_file":1,"dispatch_ref":"main","branch_input":"ref","file_form":"basename","glob":"prisma/sql/*.sql","approve_head":1,"needs_quiet":"off","local_gate":"advisory","gate_workflows":"migration-ledger.yml","require_word":1}'
printf '%s' "$MKROW" > "$T/set/hotfix_migrate.conf.mk-os"
printf 'gate' > "$T/set/mc.migration_gate_checks.mk-os"

# ---- the fake gh ------------------------------------------------------------
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
FX="${FX:?FX unset}"
printf '%s\n' "$*" >> "$FX/gh.log"
q=""; prev=""
for a in "$@"; do [ "$prev" = "-q" ] && q="$a"; prev="$a"; done
key() { printf '%s' "$1" | tr '/' '_'; }
case "$*" in
  *"/reviews"*) printf '%s %s\n' "${GH_TOKEN:-none}" "$*" >> "$FX/reviews.log" ;;
esac
case "$*" in
  "auth "*) exit 0 ;;
  "api -X POST repos/"*"/pulls/"*"/reviews"*)
    printf '%s\n' "${GH_TOKEN:-none}" >> "$FX/approve.log"
    st=""; [ -f "$FX/approve.status" ] && st=$(cat "$FX/approve.status")
    case "$st" in
      '') echo '{"id":1,"state":"APPROVED"}'; exit 0 ;;
      net) echo 'error connecting to api.github.com' >&2; exit 1 ;;
      *) cat "$FX/approve.body"; echo "gh: $(cat "$FX/approve.text") (HTTP $st)" >&2; exit 1 ;;
    esac ;;
  "api --paginate repos/"*"/reviews"*) jq -r "$q" "$FX/reviews.json" 2>/dev/null; exit 0 ;;
  "api repos/"*"/issues/"*"/comments"*)
    n=$(( $(cat "$FX/comment.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/comment.seq"
    for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$FX/comment.md"; cp "${a#body=@}" "$FX/comment-$n.md" ;; esac; done
    echo $((4240 + n)); exit 0 ;;
  "api repos/"*"/actions/variables/"*)
    printf '%s\n' "$*" >> "$FX/variables.log"
    echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  "api repos/"*"/pulls/"[0-9]*)
    printf '%s\n' "$*" >> "$FX/pulls.log"
    jq -n --arg h "$(cat "$FX/head.sha")" --arg a "$(cat "$FX/author" 2>/dev/null)" \
      '{head:{sha:$h}, user:{login:$a}}' | jq -r "${q:-.}"; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*) cat "$FX/checks.out" 2>/dev/null; exit "$(cat "$FX/checks.rc" 2>/dev/null || echo 0)" ;;
  "workflow run"*)
    printf '%s\n' "$*" >> "$FX/dispatch.log"; printf '%s\n' "${GH_TOKEN:-none}" >> "$FX/dispatch.tok"
    tok=""; for a in "$@"; do case "$a" in file=*) tok="${a#file=}" ;; esac; done
    n=$(( $(cat "$FX/run.seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/run.seq"; id=$((700 + n))
    printf '%s' "$tok" > "$FX/run-$id.tok"
    printf '{"databaseId":%s,"createdAt":"2099-01-01T00:00:%02dZ","status":"queued","event":"workflow_dispatch"}\n' "$id" "$n" >> "$FX/runs.jsonl"
    exit 0 ;;
  "run list"*) if [ -s "$FX/runs.jsonl" ]; then jq -s . "$FX/runs.jsonl"; else echo '[]'; fi; exit 0 ;;
  "run watch "*) exit 0 ;;
  "run view "*"--log"*) tok=$(cat "$FX/run-$3.tok" 2>/dev/null); cat "$FX/log-$(key "$tok")" 2>/dev/null; exit 0 ;;
  "run view "*) [ -n "$q" ] || q=.; echo '{"status":"completed","conclusion":"success"}' | jq -r "$q"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$FX/unknown.log"
exit 99
EOF
chmod +x "$T/fakebin/gh"

# ---- the worktree: one add-only file --------------------------------------
WT1="$T/wt1"
git init -q -b main "$WT1" 2>/dev/null
git -C "$WT1" config user.email t@t; git -C "$WT1" config user.name t
echo readme > "$WT1/README.md"; git -C "$WT1" add -A >/dev/null; git -C "$WT1" commit -qm init
git -C "$WT1" remote add origin https://github.com/o/p.git
git -C "$WT1" checkout -q -b ticket/x
X1F=prisma/sql/20261118000000_x.sql
mkdir -p "$WT1/prisma/sql"
printf '%s\n' 'CREATE TABLE "Alpha" ("id" TEXT NOT NULL); ALTER TABLE "Alpha" ENABLE ROW LEVEL SECURITY;' > "$WT1/$X1F"
git -C "$WT1" add -A >/dev/null; git -C "$WT1" commit -qm sql
HEAD1=$(printf 'a%.0s' $(seq 40)); HEAD2=$(printf 'b%.0s' $(seq 40))
OWN='{"message":"Unprocessable Entity","errors":["Review Can not approve your own pull request"],"documentation_url":"https://docs.github.com/rest/pulls/reviews#create-a-review-for-a-pull-request","status":"422"}'

# ---- one case = one fixture dir, one build dir, one PR number ---------------
CN=0
newcase() { # newcase [author] -> FX, BD, PRN; green checks, head HEAD1, the run log says applied
  CN=$((CN+1)); PRN=$((300 + CN))
  FX="$T/fx$CN"; BD="$HH/builds/mk-os-BH-$PRN-202611180000"
  mkdir -p "$FX" "$BD"
  printf 'build\tpass\t1s\n' > "$FX/checks.out"; echo 0 > "$FX/checks.rc"
  printf '%s\n' "$HEAD1" > "$FX/head.sha"; echo '[]' > "$FX/reviews.json"
  printf '%s' "${1-cromford-builders[bot]}" > "$FX/author"
  printf '2026-11-18T00:00:01.0Z applied: %s (2 statements)\n' "${X1F##*/}" > "$FX/log-${X1F##*/}"
  : > "$FX/gh.log"
}
refuse() { # refuse <status> <text> [body] -> every POST answers this
  printf '%s' "$1" > "$FX/approve.status"; printf '%s' "$2" > "$FX/approve.text"; printf '%s\n' "${3:-}" > "$FX/approve.body"
}
run_hm() { # run_hm [VAR=VAL...] -> prints rc. A pool builder: GH_APP_PROFILE=builders.
  ( cd "$T" && PATH="$T/fakebin:$PATH" env FX="$FX" HARNESS="$HH" WT="$WT1" BASE=main SLUG=o/p \
      BRANCH=ticket/x PR_URL="https://github.com/o/p/pull/$PRN" HOTFIX_CI_WAIT=2 \
      HOTFIX_RUN_WAIT=5 HOTFIX_RUN_LOCATE_WAIT=0 HM_BEFORE_MERGE=1 HM_VERDICT=APPROVE \
      HM_REVIEWED_SHA="$HEAD1" HM_TODAY=2026-11-18 GH_TOKEN=tok-fixture-default GH_APP_PROFILE=builders \
      "$@" bash "$HH/bin/hotfix-migrate.sh" mk-os "$BD" > "$FX/hm.out" 2> "$FX/hm.err" )
  echo $?
}
cnt() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }
marker() { head -n1 "$FX/comment.md" 2>/dev/null; }

# ============================================================================
# R1. the repro: the 422 body is on stdout only, as the real gh prints it
# ============================================================================
newcase; refuse 422 'Unprocessable Entity' "$OWN"
RC=$(run_hm)
grep -q 'Review Can not approve your own pull request' "$FX/comment.md" 2>/dev/null && ok \
  || bad "R1 the proof comment must carry GitHub's errors text (rc $RC; comment: $(grep -m1 'approval' "$FX/comment.md" 2>/dev/null))"
grep -q 'Review Can not approve your own pull request' "$BD/hotfix-approve.err" 2>/dev/null && ok \
  || bad "R1 hotfix-approve.err must keep the response body (got: $(cat "$BD/hotfix-approve.err" 2>/dev/null))"
grep -q 'Review Can not approve your own pull request' "$FX/hm.err" && ok \
  || bad "R1 the stage's stderr (the build log) must name the errors text"

# ============================================================================
# B1. a 422 on every identity: terminal for this head
# ============================================================================
newcase; refuse 422 'Unprocessable Entity' "$OWN"; B1FX="$FX"; B1BD="$BD"; B1PRN="$PRN"
RC=$(run_hm)
[ "$RC" = 3 ] && ok || bad "B1 rc 3 (got $RC: $(tail -2 "$FX/hm.err"))"
marker | grep -qE '^<!-- hotfix-migrate-proof fp=[0-9a-f]{64} decision=needs-operator -->$' && ok \
  || bad "B1 the proof decision must be needs-operator (got $(marker))"
[ "$(jq -r '.decision' "$BD/hotfix-migrate.json" 2>/dev/null)" = needs-operator ] && ok \
  || bad "B1 the ledger decision must match the marker (got $(jq -c . "$BD/hotfix-migrate.json" 2>/dev/null))"
[ "$(jq -r '.approve_refused.head // ""' "$BD/hotfix-migrate.json" 2>/dev/null)" = "$HEAD1" ] && ok \
  || bad "B1 the ledger must record approve_refused.head = HEAD1"
[ "$(jq -r '.approve_refused.status // ""' "$BD/hotfix-migrate.json" 2>/dev/null)" = 422 ] && ok \
  || bad "B1 the ledger must record approve_refused.status 422"
[ "$(jq -r '.approve_refused.errors[0] // ""' "$BD/hotfix-migrate.json" 2>/dev/null)" = "Review Can not approve your own pull request" ] && ok \
  || bad "B1 the ledger must keep GitHub's errors"
grep -q 'Review Can not approve your own pull request' "$FX/comment.md" 2>/dev/null && ok || bad "B1 the comment holds the errors text"
[ "$(cnt "$FX/dispatch.log")" = 0 ] && ok || bad "B1 0 dispatch (got $(cnt "$FX/dispatch.log"))"
[ "$(cnt "$FX/comment.seq")" = 1 ] && [ "$(cat "$FX/comment.seq" 2>/dev/null)" = 1 ] && ok || bad "B1 exactly 1 comment (got $(cat "$FX/comment.seq" 2>/dev/null))"
# the hub App first, then the own-PR fallback on the default credential: 2 POSTs
[ "$(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null)" = "ghs_hub-fixture tok-fixture-default " ] && ok \
  || bad "B1 POSTs: the hub App, then the default credential (got $(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null))"
grep -q "gh workflow run migrate-branch.yml -R o/p --ref main -f file=${X1F##*/} -f ref=ticket/x" "$FX/comment.md" 2>/dev/null && ok \
  || bad "B1 the comment names the operator step (approve, then the exact dispatch)"
grep -q '/migrate' "$FX/comment.md" 2>/dev/null && bad "B1 the comment must never name /migrate" || ok

# ============================================================================
# B2. a second run on the same head: 0 review calls, 0 comments, rc 3
# ============================================================================
FX="$B1FX"; BD="$B1BD"; PRN="$B1PRN"
R0=$(cnt "$FX/reviews.log"); C0=$(cat "$FX/comment.seq" 2>/dev/null || echo 0)
RC=$(run_hm)
[ "$RC" = 3 ] && ok || bad "B2 rc 3 (got $RC)"
[ "$(cnt "$FX/reviews.log")" = "$R0" ] && ok || bad "B2 0 new review calls (before $R0, after $(cnt "$FX/reviews.log"))"
[ "$(cat "$FX/comment.seq" 2>/dev/null || echo 0)" = "$C0" ] && ok || bad "B2 0 new comments (before $C0, after $(cat "$FX/comment.seq" 2>/dev/null))"
[ "$(cnt "$FX/dispatch.log")" = 0 ] && ok || bad "B2 0 dispatch"
[ "$(jq -r '.approve_refused.head // ""' "$BD/hotfix-migrate.json" 2>/dev/null)" = "$HEAD1" ] && ok || bad "B2 the ledger keeps the terminal head"

# ============================================================================
# B3. a new head on the same PR: tried again once
# ============================================================================
printf '%s\n' "$HEAD2" > "$FX/head.sha"; R0=$(cnt "$FX/approve.log")
RC=$(run_hm HM_REVIEWED_SHA="$HEAD2")
[ "$(( $(cnt "$FX/approve.log") - R0 ))" = 2 ] && ok || bad "B3 a new head: 1 POST plus the own-PR fallback (got $(( $(cnt "$FX/approve.log") - R0 )))"
[ "$(jq -r '.approve_refused.head // ""' "$BD/hotfix-migrate.json" 2>/dev/null)" = "$HEAD2" ] && [ "$(cat "$FX/comment.seq")" = 2 ] && ok \
  || bad "B3 a 422 on the new head is terminal for that head, with its own comment (head $(jq -r '.approve_refused.head' "$BD/hotfix-migrate.json"), comments $(cat "$FX/comment.seq"))"
# the stub now accepts: the next head posts 1 approval and dispatches once
rm -f "$FX/approve.status"; HEAD3=$(printf 'c%.0s' $(seq 40)); printf '%s\n' "$HEAD3" > "$FX/head.sha"; R0=$(cnt "$FX/approve.log")
RC=$(run_hm HM_REVIEWED_SHA="$HEAD3")
[ "$RC" = 0 ] && [ "$(( $(cnt "$FX/approve.log") - R0 ))" = 1 ] && [ "$(cnt "$FX/dispatch.log")" = 1 ] && ok \
  || bad "B3 an accepted approval on a new head: rc 0, 1 POST, 1 dispatch (rc $RC, posts $(( $(cnt "$FX/approve.log") - R0 )), dispatches $(cnt "$FX/dispatch.log"): $(tail -2 "$FX/hm.err"))"
marker | grep -q 'decision=applied' && ok || bad "B3 the applied run's proof says applied (got $(marker))"

# ============================================================================
# B4. the status table: only a 422 is terminal
# ============================================================================
b4() { # b4 <label> <status> <text> <body> <want-decision>
  newcase; refuse "$2" "$3" "$4"
  RC=$(run_hm)
  [ "$RC" = 3 ] && marker | grep -q "decision=$5 " && [ "$(cnt "$FX/dispatch.log")" = 0 ] && ok \
    || bad "B4 $1: rc 3, decision $5, 0 dispatch (rc $RC, $(marker))"
  if [ "$5" = retry ]; then
    [ "$(jq -r 'has("approve_refused")' "$BD/hotfix-migrate.json" 2>/dev/null)" = false ] && ok || bad "B4 $1: no approve_refused in a retry ledger"
  fi
}
b4 "500" 500 'Internal Server Error' '{"message":"Server Error"}' retry
grep -q 'HTTP 500' "$FX/comment.md" && grep -q 'Server Error' "$FX/comment.md" && ok || bad "B4 a 500: the comment names the status and the message"
b4 "403" 403 'Forbidden' '{"message":"Resource not accessible by integration"}' retry
grep -q 'Resource not accessible by integration' "$FX/comment.md" && ok || bad "B4 a 403: the comment names GitHub's message"
b4 "a network error" net '' '' retry
b4 "422 closed" 422 'Unprocessable Entity' '{"message":"Unprocessable Entity","errors":["Pull request is closed"]}' needs-operator
grep -q 'Pull request is closed' "$FX/comment.md" && ok || bad "B4 422 closed: the comment names the errors text"
# an errors[] of objects: each object's .message
b4 "422 object errors" 422 'Unprocessable Entity' '{"message":"Validation Failed","errors":[{"resource":"PullRequestReview","message":"commit_id is not part of the pull request"}]}' needs-operator
grep -q 'commit_id is not part of the pull request' "$FX/comment.md" && ok || bad "B4 errors[] objects: the comment names each .message"

# ============================================================================
# I. which identity posts the approval
# ============================================================================
# I1 the builders App opened the PR: the reviewer (hub) App approves, 1 POST.
newcase 'cromford-builders[bot]'
RC=$(run_hm)
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null)" = "ghs_hub-fixture " ] && ok \
  || bad "I1 author builders App: 1 POST as the hub App (rc $RC, tokens: $(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null))"
[ "$(cnt "$FX/dispatch.log")" = 1 ] && ok || bad "I1 then 1 dispatch"
# the dispatch goes back out on the lane's own (builders) token
[ "$(cat "$FX/dispatch.tok" 2>/dev/null)" = ghs_builders-fixture ] && ok || bad "I1 the dispatch keeps the lane's own token (got $(cat "$FX/dispatch.tok" 2>/dev/null))"
# I2 the reviewer App opened the PR: the default credential approves, 1 POST.
newcase 'cromford[bot]'
RC=$(run_hm)
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null)" = "tok-fixture-default " ] && ok \
  || bad "I2 author reviewer App: 1 POST on the default credential (rc $RC, tokens: $(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null))"
# I3 the author could not be read: the token in hand (today's path)
newcase ''
RC=$(run_hm)
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null)" = "ghs_builders-fixture " ] && ok \
  || bad "I3 author unknown: 1 POST on the token in hand (rc $RC, tokens: $(tr '\n' ' ' < "$FX/approve.log" 2>/dev/null))"
# one pulls read for head and author together (BH-9403 A2b counts these reads)
[ "$(grep -c 'user.login' "$FX/pulls.log" 2>/dev/null)" = 1 ] && ok || bad "I3 one pulls read carries head and author"

for f in "$T"/fx*/unknown.log; do [ -s "$f" ] && bad "the fake gh saw a verb it does not know: $(head -1 "$f")"; done

echo "hotfix-migrate-approve-422: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/conductor-review-block-park.bh-9260-test.sh — BH-9260: a MACHINE review
# BLOCK on a READY head becomes a blocked-resolver park on the same tick.
#
# THE INCIDENT. example-org/project-4-site#4 was READY on a carried verdict. The review
# autopilot posted `[BLOCK core-flow-broken]` on the head, and the conductor
# logged `MERGE_REFUSED block-gate` 22 ticks in a row. The row stayed READY, so
# bin/blocked-resolver.sh never saw it and no fix round ran.
#
#   U1      mc_rbp_eligible over every row of the plan's decision table
#   U2      the knob, the CI-block hook rc and enforcement decline the park
#   U3      mc_rbp_recheck rc 0 / 1 / 2
#   U4      the stuck counter: one warn alert past MC_REVIEW_BLOCK_STUCK_TICKS
#   C1..C8  bin/merge-conductor.sh WHOLE against a stubbed gh: park, sticky,
#           a park the resolver released (C2b), UNBLOCK release, other-login UNBLOCK, new head, a person's BLOCK,
#           the operator-login autopilot BLOCK, an unreadable block body
#
# GitHub is a PATH stub answering from files in $T; nothing reads the network.
# Every fixture time is a literal. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/conductor-review-block-park.bh-9260-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/review-block-park.sh" ] || { echo "FAIL: bin/lib/mc/review-block-park.sh is missing (BH-9260)"; exit 1; }
[ -f "$DIR/bin/merge-conductor.d/bh-9260-review-block-park.sh" ] || { echo "FAIL: bin/merge-conductor.d/bh-9260-review-block-park.sh is missing (BH-9260)"; exit 1; }

SLUG=example-org/demo-os
NUM=42
KEY="$SLUG#$NUM"
PRURL="https://github.com/$SLUG/pull/$NUM"
H1=a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0
H2=b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0e1
OLDH=c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0e1f2
BOT='cromford[bot]'
BURL="https://github.com/$SLUG/pull/$NUM#issuecomment-9001"
T_HEAD_OLD=2026-11-07T18:40:00Z
T_HEAD_NEW=2026-11-08T03:00:00Z
T_BLOCK=2026-11-08T00:42:58Z
T_CLEAR=2026-11-08T01:30:00Z
AP_BODY="<!-- harness-review-autopilot ${H1:0:12} -->
## Review

- [BLOCK core-flow-broken] the sign-in form posts to a route the CSP blocks
- [BLOCK wrong-data] a second finding

VERDICT: BLOCK"

# ============================================================================
# U. The lib on its own, through the real bin/lib/merge-conductor-lib.sh loader
#    in a scratch tree. gh_rest is a function over files in $T/u/gh.
# ============================================================================
U="$T/u"; mkdir -p "$U/h/state" "$U/h/logs" "$U/h/bin" "$U/gh" "$U/fakebin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$U" > "$U/h/bin/lane-alert.sh"; chmod +x "$U/h/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 1\n' > "$U/fakebin/curl"; chmod +x "$U/fakebin/curl"
cmtjson() { # cmtjson <id> <login> <body> — a REST issue comment
  jq -nc --arg id "$1" --arg l "$2" --arg b "$3" --arg u "https://github.com/$SLUG/pull/$NUM#issuecomment-$1" \
    '{id:($id|tonumber), user:{login:$l}, html_url:$u, body:$b, issue_url:"https://api.github.com/repos/'"$SLUG"'/issues/'"$NUM"'"}'
}
ufx() { printf '%s\n' "$3" > "$U/gh/$1-$2"; }   # ufx c|r <id> <json>
ustatus() { echo "$3" > "$U/gh/$1-$2.status"; }
uline() { printf '%s\t%s\t%s\t%s' "https://github.com/$SLUG/pull/$NUM#issuecomment-$2" "$1" "$T_BLOCK" "$2"; }
# ulib <commands…> — run in a subshell with the conductor lib loaded.
ulib() {
  ( export HARNESS="$U/h" PATH="$U/fakebin:$PATH" HARNESS_OPERATOR_LOGIN=operator HARNESS_VERDICT_AUTHORS=app/cromford
    unset MC_REVIEW_BLOCK_PARK MC_REVIEW_BLOCK_STUCK_TICKS BLOCK_GATE_ENFORCE
    # The conductor sources gh-pr-list.sh itself (bin/merge-conductor.sh), and
    # so does the resolver: the operator-login rule reads it.
    . "$DIR/bin/lib/gh-pr-list.sh" >/dev/null 2>&1 || { echo "cannot load gh-pr-list.sh"; exit 9; }
    . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || { echo "cannot load merge-conductor-lib.sh"; exit 9; }
    mc_init >/dev/null 2>&1
    gh_rest() {
      local p="$2" f=""
      printf '%s %s\n' "$1" "$p" >> "$U/calls.txt"
      case "$p" in
        "repos/$SLUG/issues/comments/"*)      f="$U/gh/c-${p##*/}" ;;
        "repos/$SLUG/pulls/$NUM/reviews/"*)   f="$U/gh/r-${p##*/}" ;;
      esac
      [ -n "$f" ] && [ -f "$f.status" ] && { GH_REST_STATUS=$(cat "$f.status"); [ "$GH_REST_STATUS" = 404 ] && return 44; return 75; }
      [ -n "$f" ] && [ -f "$f" ] && { cat "$f"; return 0; }
      GH_REST_STATUS=404; return 44
    }
    eval "$*" )
}
elig() { ulib "mc_rbp_eligible '$SLUG' '$NUM' '$1' \"\$(printf '%s\t%s\t%s\t%s' '$BURL' '$2' '$T_BLOCK' '$3')\"; echo \"|\$(mc_rbp_tag \"\$MC_RBP_BODY\")\""; }
ucase() { # ucase <name> <want> <got>
  [ "$3" = "$2" ] && ok || bad "$1: want '$2' got '$3'"
}

echo "U1: mc_rbp_eligible, the decision table"
ufx c 9001 "$(cmtjson 9001 "$BOT" "$AP_BODY")"
ucase "U1a bot BLOCK on this head" "yes|[BLOCK core-flow-broken]" "$(elig "$H1" "$BOT" 9001)"
ufx c 9002 "$(cmtjson 9002 operator "$AP_BODY")"
ucase "U1b operator login + autopilot marker of THIS head (project-4-site#4 shape)" "yes|[BLOCK core-flow-broken]" "$(elig "$H1" operator 9002)"
ufx c 9003 "$(cmtjson 9003 app/cromford "<!-- harness-review-autopilot ${H1:0:12} -->
findings

VERDICT: BLOCK")"
ucase "U1c app/ spelling, VERDICT: BLOCK with no tag" "yes|[BLOCK]" "$(elig "$H1" app/cromford 9003)"
ufx c 9004 "$(cmtjson 9004 "$BOT" "<!-- harness-review-autopilot ${H1:0:12} -->
- [BLOCK wrong-data] first
- [BLOCK secret] second
VERDICT: BLOCK")"
ucase "U1d two tags -> the first" "yes|[BLOCK wrong-data]" "$(elig "$H1" "$BOT" 9004)"
ufx c 9005 "$(cmtjson 9005 operator "BLOCK — I do not want this merged yet")"
ucase "U1e near miss: a person's BLOCK (operator login, no marker)" "no|[BLOCK]" "$(elig "$H1" operator 9005)"
ufx c 9006 "$(cmtjson 9006 operator "<!-- harness-review-autopilot ${OLDH:0:12} -->
- [BLOCK core-flow-broken] x
VERDICT: BLOCK")"
ucase "U1f near miss: operator login, marker of an OLDER head" "no|[BLOCK core-flow-broken]" "$(elig "$H1" operator 9006)"
ufx c 9007 "$(cmtjson 9007 someuser "$AP_BODY")"
ucase "U1g near miss: a stranger pasting the marker" "no|[BLOCK core-flow-broken]" "$(elig "$H1" someuser 9007)"
ucase "U1h near miss: cr-* (CHANGES_REQUESTED)" "no|[BLOCK]" "$(elig "$H1" "$BOT" "cr-77@$OLDH")"
ucase "U1i near miss: verdict-* (lead/human row)" "no|[BLOCK]" "$(elig "$H1" "$BOT" verdict-55)"
ustatus c 9008 500
ucase "U1j body read 500 -> unknown" "unknown|[BLOCK]" "$(elig "$H1" "$BOT" 9008)"
ufx c 9009 "$(cmtjson 9009 "$BOT" "$AP_BODY")"
ucase "U1k the scan's login is not the comment's author" "no|[BLOCK core-flow-broken]" "$(elig "$H1" someuser 9009)"
ustatus c 9010 404
ufx r 9010 "$(jq -nc --arg b "$AP_BODY" '{id:9010,user:{login:"cromford[bot]"},html_url:"https://github.com/x/y/pull/42#pullrequestreview-9010",body:$b}')"
ucase "U1l a REVIEW id (issue comment 404) is read as a review" "yes|[BLOCK core-flow-broken]" "$(elig "$H1" "$BOT" 9010)"
ustatus c 9011 404
ucase "U1m no comment and no review by that id" "no|[BLOCK]" "$(elig "$H1" "$BOT" 9011)"
# A bot login is NOT a credential on its own (lead review of fa4e21ee): the
# comment becomes the fix round's brief, so only a verdict author (or the
# operator login) with the marker of THIS head parks.
ufx c 9012 "$(cmtjson 9012 'github-actions[bot]' "$AP_BODY")"
ucase "U1n near miss: github-actions[bot] (not a verdict author) with this head's marker" "no|[BLOCK core-flow-broken]" "$(elig "$H1" 'github-actions[bot]' 9012)"
ufx c 9013 "$(cmtjson 9013 'dependabot[bot]' "BLOCK
- [BLOCK secret] echoed PR text")"
ucase "U1o near miss: dependabot[bot], a BLOCK line, no marker" "no|[BLOCK secret]" "$(elig "$H1" 'dependabot[bot]' 9013)"
ufx c 9014 "$(cmtjson 9014 app/other-app "$AP_BODY")"
ucase "U1p near miss: a third-party app/ login with this head's marker" "no|[BLOCK core-flow-broken]" "$(elig "$H1" app/other-app 9014)"
ufx c 9015 "$(cmtjson 9015 "$BOT" "- [BLOCK core-flow-broken] x
VERDICT: BLOCK")"
ucase "U1q near miss: verdict-author bot, no marker" "no|[BLOCK core-flow-broken]" "$(elig "$H1" "$BOT" 9015)"
ufx c 9016 "$(cmtjson 9016 "$BOT" "<!-- harness-review-autopilot ${OLDH:0:12} -->
- [BLOCK core-flow-broken] x
VERDICT: BLOCK")"
ucase "U1r near miss: verdict-author bot, marker of a DIFFERENT head" "no|[BLOCK core-flow-broken]" "$(elig "$H1" "$BOT" 9016)"
ucase "U1s near miss: verdict-author bot, a short head (fail closed)" "no|[BLOCK core-flow-broken]" "$(elig "${H1:0:8}" "$BOT" 9001)"
# No trust set loaded -> nothing is trusted, whatever the login.
ucase "U1t no harness_own_review_match on the box (fail closed)" "no|[BLOCK core-flow-broken]" \
  "$(ulib "unset -f harness_own_review_match; mc_rbp_eligible '$SLUG' '$NUM' '$H1' \"\$(printf '%s\t%s\t%s\t%s' '$BURL' '$BOT' '$T_BLOCK' 9001)\"; echo \"|\$(mc_rbp_tag \"\$MC_RBP_BODY\")\"")"

echo "U2: what declines the park"
upark() { # upark <bci-rc> [env…] -> "<rc>|<state>|<why>"
  scratch_rm "$U/h/state/merge-conductor"
  ulib "${2:-} mc_transition '$KEY' READY 'clean approved checks green' '$H1' '$H1' '$PRURL' APPROVE CLEAN - >/dev/null
        mc_rbp_park '$KEY' '$SLUG' '$NUM' '$PRURL' - '$H1' '$H1' CLEAN \"\$(printf '%s\t%s\t%s\t%s' '$BURL' '$BOT' '$T_BLOCK' 9001)\" '$1'; rc=\$?
        printf '%s|%s|%s' \"\$rc\" \"\$(mc_row_field '$KEY' 2)\" \"\$(mc_row_field '$KEY' 7)\""
}
ucase "U2a hook declined (2) -> parked" "0|BLOCKED_HUMAN|review-block: 9001 [BLOCK core-flow-broken] $BURL" "$(upark 2)"
grep -qxF "rvblock $KEY $H1" "$U/h/state/merge-conductor/attempts.txt" && ok || bad "U2a the park writes the rvblock attempt line"
for r in 0 1 3; do ucase "U2b hook rc $r (CI-only block) -> not parked" "1|READY|clean approved checks green" "$(upark $r)"; done
ucase "U2c MC_REVIEW_BLOCK_PARK=0 -> not parked" "1|READY|clean approved checks green" "$(upark 2 'export MC_REVIEW_BLOCK_PARK=0;')"
ucase "U2d BLOCK_GATE_ENFORCE=0 -> not parked" "1|READY|clean approved checks green" "$(upark 2 'export BLOCK_GATE_ENFORCE=0;')"
ucase "U2e mc_state_display of the park" "BLOCKED_AGENT" "$(ulib "mc_state_display BLOCKED_HUMAN 'review-block: 9001 [BLOCK x] u'")"

echo "U3: mc_rbp_recheck"
urecheck() { # urecheck <scan rc> <scan id> [env…] -> "<rc>|<rvblock line left>"
  scratch_rm "$U/h/state/merge-conductor"
  ulib "${3:-} mc_transition '$KEY' BLOCKED_HUMAN 'review-block: 9001 [BLOCK x] $BURL' '$H1' '$H1' '$PRURL' BLOCK CLEAN - >/dev/null
        mc_attempt_put 'rvblock $KEY $H1'
        bg_scan_read() { [ '$1' = 1 ] && printf '%s\t%s\t%s\t%s' u l t '$2'; [ '$1' = 2 ] && printf comments; return $1; }
        mc_rbp_recheck demo-os '$KEY' '$SLUG' '$NUM' '$PRURL' - ticket/x '$H1'; rc=\$?
        printf '%s|%s' \"\$rc\" \"\$(grep -c 'rvblock' \"\$MC_ATTEMPTS\")\""
}
ucase "U3a the same block stands -> 0, line kept" "0|1" "$(urecheck 1 9001)"
ucase "U3b the thread is clean -> 1, line cleared" "1|0" "$(urecheck 0 -)"
ucase "U3c a different block is the newest -> 1" "1|0" "$(urecheck 1 9050)"
ucase "U3d unreadable -> 2, nothing written" "2|1" "$(urecheck 2 -)"
ucase "U3e knob off -> 1 (released)" "1|0" "$(urecheck 1 9001 'export MC_REVIEW_BLOCK_PARK=0;')"
ucase "U3f a row that is not a review-block park -> 1, nothing read" "1" \
  "$(scratch_rm "$U/h/state/merge-conductor"; ulib "mc_transition '$KEY' READY x '$H1' '$H1' '$PRURL' APPROVE CLEAN - >/dev/null; mc_rbp_recheck demo-os '$KEY' '$SLUG' '$NUM' '$PRURL' - b '$H1'; echo \$?")"

echo "U4: the stuck counter"
scratch_rm "$U/h/state/merge-conductor"; : > "$U/alerts.txt"
ustuck() { ulib "${2:-} mc_rbp_stuck_note '$KEY' '$H1' 9001 $1"; }
ustuck unknown; ustuck unknown
[ -s "$U/alerts.txt" ] && bad "U4a no alert on refusal 2 (got $(cat "$U/alerts.txt"))" || ok
ustuck unknown
[ "$(grep -c "review-block-unparked:$KEY:${H1:0:12}:9001" "$U/alerts.txt")" = 1 ] && ok || bad "U4b one alert on refusal 3: $(cat "$U/alerts.txt")"
grep -q -- "--severity warn" "$U/alerts.txt" && ok || bad "U4b the alert is a warn"
ustuck unknown
[ "$(grep -c 'review-block-unparked' "$U/alerts.txt")" = 1 ] && ok || bad "U4c refusal 4 raises no second alert"
ustuck no
[ -e "$U/h/state/merge-conductor/review-block/stuck-example-org_demo-os_42" ] && bad "U4d 'no' must delete the counter" || ok
: > "$U/alerts.txt"
for i in 1 2 3; do ustuck unknown 'export MC_REVIEW_BLOCK_STUCK_TICKS=3;'; done
[ -s "$U/alerts.txt" ] && bad "U4e MC_REVIEW_BLOCK_STUCK_TICKS=3: no alert on refusal 3" || ok
ustuck unknown 'export MC_REVIEW_BLOCK_STUCK_TICKS=3;'
[ -s "$U/alerts.txt" ] && ok || bad "U4e MC_REVIEW_BLOCK_STUCK_TICKS=3: alert on refusal 4"

# ============================================================================
# C. THE WHOLE TICK. One project, one PR, approved at its head and CI-green, so
#    the thread is the only thing between READY and `gh pr merge`.
# ============================================================================
export HARNESS="$T/h"
( fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || { echo "FAIL: fixture setup"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || { echo "FAIL: closure install"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-9260-review-block-park.sh "$T/h" ) >/dev/null || { echo "FAIL: fragment install"; exit 1; }
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
REC="$T/h/builds/demo-os-TK-21-202611070001"; mkdir -p "$REC"
echo "PR_CREATED $PRURL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  # The lead fence and the verdicts table: no lead PR, no verdict row.
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }
# The head is a FILE, so a section can move it between ticks.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
HS=\$(cat "$T/head")
case "\$*" in
  *"pr merge $PRURL --squash --match-head-commit \$HS"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH repos/"*|*"api -i -X POST repos/"*"/comments"*\\
  |*"pr edit"*|*"issue close"*|*"issue comment"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"
    case "\$*" in *"api -i -X"*) restpr --raw 500 '{"message":"refused"}'; exit 0 ;; esac
    exit 1 ;;
  # The open list and its lazy per-PR reads, REST-shaped here: the conductor
  # binds an App token with \`env GH_TOKEN=…\`, which runs this file, not the
  # exported gh-list-bridge function.
  *"api -i -X GET repos/$SLUG/pulls?state=open"*)
    restpr --raw 200 "[{\"number\":$NUM,\"html_url\":\"$PRURL\",\"title\":\"t\",\"body\":\"\",\"draft\":false,\"state\":\"open\",\"merged_at\":null,\"closed_at\":null,\"labels\":[],\"user\":{\"login\":\"operator\",\"type\":\"User\"},\"created_at\":\"2026-11-07T00:00:00Z\",\"updated_at\":\"2026-11-07T00:00:00Z\",\"head\":{\"ref\":\"ticket/TK-21\",\"sha\":\"\$HS\",\"repo\":{\"full_name\":\"$SLUG\"}},\"base\":{\"ref\":\"main\",\"repo\":{\"full_name\":\"$SLUG\"}},\"mergeable_state\":\"clean\",\"mergeable\":true}]"
    exit 0 ;;
  # The HOLD and autopilot-verdict reads of the thread (gh_rest, paged): this
  # suite's thread carries neither, so they read an empty page.
  *"api -i -X GET repos/$SLUG/issues/$NUM/comments"*) restpr --raw 200 '[]'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/$NUM/files"*) restpr --raw 200 '[{"filename":"src/x.ts"}]'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/issues/comments/"*)
    id=\$(sed -E 's#.*issues/comments/([0-9]+).*#\1#' <<<"\$*")
    if [ -f "$T/rest/c-\$id.status" ]; then restpr --raw "\$(cat "$T/rest/c-\$id.status")" '{"message":"x"}'
    elif [ -f "$T/rest/c-\$id" ]; then restpr --raw 200 "\$(cat "$T/rest/c-\$id")"
    else restpr --raw 404 '{"message":"Not Found"}'; fi
    exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/$NUM/reviews/"*) restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
  *"api repos/$SLUG/issues/$NUM/comments"*) cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$NUM/reviews"*)   cat "$T/reviews" 2>/dev/null; exit 0 ;;
  "api repos/$SLUG/pulls/$NUM")
    if [ -f "$T/merged" ]; then st=closed; ma='"2026-11-08T05:00:00Z"'; mc='"cccccccc3333"'; else st=open; ma=null; mc=null; fi
    echo "{\"number\":$NUM,\"html_url\":\"$PRURL\",\"title\":\"t\",\"body\":\"\",\"state\":\"\$st\",\"merged_at\":\$ma,\"merge_commit_sha\":\$mc,\"mergeable_state\":\"clean\",\"draft\":false,\"head\":{\"sha\":\"\$HS\",\"ref\":\"ticket/TK-21\"},\"base\":{\"ref\":\"main\"},\"user\":{\"login\":\"operator\",\"type\":\"User\"},\"labels\":[],\"created_at\":\"2026-11-07T00:00:00Z\",\"updated_at\":\"2026-11-07T00:00:00Z\",\"closed_at\":null}"
    exit 0 ;;
  *"repos/$SLUG/pulls/$NUM/files"*) echo '[[{"filename":"src/x.ts"}]]'; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/$NUM"*)
    if [ -f "$T/merged" ]; then restpr MERGED "\$HS" ticket/TK-21 main "" MERGEABLE CLEAN operator cccccccc3333
    else restpr OPEN "\$HS" ticket/TK-21 main "" MERGEABLE CLEAN operator; fi ;;
  *"api repos/$SLUG/pulls/$NUM/commits"*) cat "$T/headtime" 2>/dev/null; exit 0 ;;
  *"--json state,headRefOid,baseRefName"*) [ -f "$T/merged" ] && echo "MERGED \$HS main" || echo "OPEN \$HS main" ;;
  *"--json state,headRefOid"*)             [ -f "$T/merged" ] && echo "MERGED \$HS" || echo "OPEN \$HS" ;;
  *"pr view"*"--json state"*)              [ -f "$T/merged" ] && echo MERGED || echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo "cccccccc3333" ;;
  *"pr list -R $SLUG --state open"*)
    echo "[{\"number\":$NUM,\"url\":\"$PRURL\",\"headRefOid\":\"\$HS\",\"headRefName\":\"ticket/TK-21\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"labels\":[],\"baseRefName\":\"main\"}]" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=\$HS"*) printf 'completed|success\n' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x-fixture JOBS_URL=http://worker.test \
                 HARNESS_OPERATOR_LOGIN=operator HARNESS_VERDICT_AUTHORS=app/cromford \
                 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
# MC_TTL_READY: the seeded row's `since` is a fixture literal, so the stuck
# detector must not read its age off the wall clock and start a keyed run.
TICK() { run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_TTL_READY=-1 "$@"; }
MCLOG="$T/h/logs/merge-conductor.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
row_f() { awk -F'\t' -v k="$KEY" -v n="$1" '$1==k {print $n}' "$ROWS" 2>/dev/null; }
# reset <head-time> — a fresh tree with the PR seeded READY on $H1, as the
# conductor left project-4-site#4 (a carried verdict, CI green, a clean merge state).
reset() {
  rm -f "$T/merged" "$T/tick.err"
  for d in "$T/h/state/merge-conductor" "$T/h/state/block-gate" "$T/h/logs" "$T/h/locks" "$T/rest"; do scratch_rm "$d"; done
  mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/state/merge-conductor" "$T/rest"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-comments.txt"; : > "$T/gh-calls.txt"; : > "$T/alerts.txt"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
  printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
  : > "$T/prcomments"; : > "$T/reviews"
  echo "$H1" > "$T/head"; printf '%s\n' "$1" > "$T/headtime"
  printf '%s\tREADY\t1794099652\t%s\t%s\t-\tclean approved checks green\t%s\n' "$KEY" "$H1" "$H1" "$PRURL" > "$ROWS"
}
restc() { cmtjson "$1" "$2" "$3" > "$T/rest/c-$1"; }   # restc <id> <login> <body>

echo "C1: a bot BLOCK on the READY head parks the row on the same tick"
reset "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" "$BOT" "$BURL" "$AP_BODY" > "$T/prcomments"
restc 9001 "$BOT" "$AP_BODY"
BEFORE=$(cat "$ROWS")
TICK
[ -s "$T/gh-merges.txt" ] && bad "C1 merged over a machine BLOCK: $(cat "$T/gh-merges.txt")" || ok
[ "$(row_f 2)" = BLOCKED_HUMAN ] && ok || bad "C1 THE DEFECT: the row must leave READY for BLOCKED_HUMAN (got '$(row_f 2)'; log: $(grep -o 'MERGE_REFUSED.*' "$MCLOG" | head -1))"
[ "$(row_f 7)" = "review-block: 9001 [BLOCK core-flow-broken] $BURL" ] && ok || bad "C1 reason: got '$(row_f 7)'"
[ "$(grep -c " -> " "$MCLOG")" = 1 ] && grep -q "$KEY READY -> BLOCKED_HUMAN .*reason=review-block: 9001" "$MCLOG" && ok \
  || bad "C1 exactly one transition, READY -> BLOCKED_HUMAN review-block: $(grep ' -> ' "$MCLOG")"
[ "$(wc -l < "$ROWS")" = 1 ] && [ "$BEFORE" != "$(cat "$ROWS")" ] && ok || bad "C1 pr-state.tsv must change in that one row: $(cat "$ROWS")"
tl=$(grep -n "READY -> BLOCKED_HUMAN" "$MCLOG" | head -1 | cut -d: -f1)
hl=$(grep -n "BLOCKED_AGENT review-block: 9001 \[BLOCK core-flow-broken\] .*handed to bin/blocked-resolver.sh.*: $PRURL\$" "$MCLOG" | head -1 | cut -d: -f1)
[ -n "$tl" ] && [ -n "$hl" ] && [ "$hl" -gt "$tl" ] && ok || bad "C1 the hand-off line must follow the row write (transition line ${tl:-none}, hand-off line ${hl:-none})"
grep -qxF "rvblock $KEY $H1" "$T/h/state/merge-conductor/attempts.txt" && ok || bad "C1 the rvblock attempt line"
[ -s "$T/h/state/merge-conductor/handoff/example-org_demo-os_42" ] && ok || bad "C1 the hand-off file must be written (mc_handoff_owns review-block)"
grep -q "BLOCKED_HUMAN" "$T/alerts.txt" && bad "C1 a resolver-owned park must not page: $(cat "$T/alerts.txt")" || ok

echo "C2: tick 2 on the same head stays parked, writes no transition"
TICK
[ "$(grep -c " -> " "$MCLOG")" = 1 ] && ok || bad "C2 no second transition: $(grep ' -> ' "$MCLOG")"
grep -q "$KEY PARKED .*BLOCKED_AGENT (review-block: 9001" "$MCLOG" && ok || bad "C2 the sticky PARKED line (log tail: $(tail -3 "$MCLOG"))"
[ "$(grep -c "$KEY MERGE_REFUSED block-gate" "$MCLOG")" = 1 ] && ok || bad "C2 the parked row is not re-refused READY every tick (the state this ticket removes)"
[ "$(row_f 2)" = BLOCKED_HUMAN ] && ok || bad "C2 still BLOCKED_HUMAN (got '$(row_f 2)')"
[ -s "$T/gh-merges.txt" ] && bad "C2 merged" || ok
grep -q "BLOCKED_HUMAN" "$T/alerts.txt" && bad "C2 no page: $(cat "$T/alerts.txt")" || ok

echo "C2b: the resolver released the hand-off (a rung ran) and the BLOCK stands: still parked"
# The resolver's own release marker, written as mc_handoff_release writes it:
# the sticky branch no longer stops the tick, so the PR classifies READY, and
# mc_rbp_hold must keep the park instead of flipping it back to READY.
mkdir -p "$T/h/state/merge-conductor/handoff-released"
printf '1794150000\tblocked-resolver\n' > "$T/h/state/merge-conductor/handoff-released/example-org_demo-os_42"
TICK
[ "$(row_f 2)" = BLOCKED_HUMAN ] && [ "$(row_f 7)" = "review-block: 9001 [BLOCK core-flow-broken] $BURL" ] && ok \
  || bad "C2b the released park must stay BLOCKED_HUMAN review-block while its BLOCK stands (row: $(cat "$ROWS"))"
[ "$(grep -c " -> " "$MCLOG")" = 1 ] && ok || bad "C2b no READY flip: $(grep ' -> ' "$MCLOG")"
[ -s "$T/gh-merges.txt" ] && bad "C2b merged" || ok

echo "C3: the same bot login posts UNBLOCK -> READY and merged on the next tick"
cmt 9002 "$T_CLEAR" "$BOT" "$BURL-2" "UNBLOCK — the CSP finding was a false positive" >> "$T/prcomments"
# No resolver release this time: the sticky branch itself (mc_rbp_unpark) must
# notice the clear.
scratch_rm "$T/h/state/merge-conductor/handoff-released"
TICK
[ -e "$T/h/state/merge-conductor/handoff-released/example-org_demo-os_42" ] && ok || bad "C3 the park's hand-off must be released"
grep -q "$KEY review-block cleared on ${H1:0:8} .*park released" "$MCLOG" && ok || bad "C3 the release line (log tail: $(tail -4 "$MCLOG"))"
[ "$(grep -c "review-block cleared" "$MCLOG")" = 1 ] && ok || bad "C3 one release line per release"
grep -q "$KEY BLOCKED_HUMAN -> READY" "$MCLOG" && ok || bad "C3 the row must classify READY again: $(grep ' -> ' "$MCLOG")"
grep -qxF "rvblock $KEY $H1" "$T/h/state/merge-conductor/attempts.txt" && bad "C3 the rvblock line must be cleared" || ok
[ -s "$T/gh-merges.txt" ] && ok || bad "C3 the cleared head must merge (log tail: $(tail -4 "$MCLOG"))"

echo "C4: a DIFFERENT login's UNBLOCK does not release it"
reset "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" "$BOT" "$BURL" "$AP_BODY" > "$T/prcomments"
restc 9001 "$BOT" "$AP_BODY"
TICK
cmt 9002 "$T_CLEAR" someone-else "$BURL-2" "UNBLOCK" >> "$T/prcomments"
TICK
[ "$(row_f 2)" = BLOCKED_HUMAN ] && ok || bad "C4 stays BLOCKED_HUMAN (got '$(row_f 2)')"
grep -q "review-block cleared" "$MCLOG" && bad "C4 released on another login's UNBLOCK" || ok
[ -s "$T/gh-merges.txt" ] && bad "C4 merged" || ok

echo "C5: a new head ends the park"
echo "$H2" > "$T/head"; printf '%s\n' "$T_HEAD_NEW" > "$T/headtime"
TICK
[ "$(row_f 2)" = BLOCKED_HUMAN ] && bad "C5 the park must end on a new head (row: $(cat "$ROWS"))" || ok
[ "$(row_f 4)" = "$H2" ] && ok || bad "C5 the row follows the new head (got '$(row_f 4)')"
[ "$(grep -c "BLOCKED_AGENT review-block" "$MCLOG")" = 1 ] && ok || bad "C5 no re-park on the old block id"

echo "C6: a person's BLOCK keeps BH-762: READY, refused, no park"
reset "$T_HEAD_OLD"
cmt 9005 "$T_BLOCK" operator "$BURL" "BLOCK — hold this until I talk to the client" > "$T/prcomments"
restc 9005 operator "BLOCK — hold this until I talk to the client"
TICK
[ "$(row_f 2)" = READY ] && ok || bad "C6 stays READY (got '$(row_f 2)')"
grep -q "$KEY MERGE_REFUSED block-gate" "$MCLOG" && ok || bad "C6 the refusal line"
grep -q "BLOCKED_AGENT review-block" "$MCLOG" && bad "C6 a person's BLOCK must not be handed to an agent" || ok
[ -s "$T/gh-merges.txt" ] && bad "C6 merged" || ok

echo "C6b: github-actions[bot] BLOCK with this head's marker keeps BH-762: READY, refused, no park"
reset "$T_HEAD_OLD"
cmt 9012 "$T_BLOCK" 'github-actions[bot]' "https://github.com/$SLUG/pull/$NUM#issuecomment-9012" "$AP_BODY" > "$T/prcomments"
restc 9012 'github-actions[bot]' "$AP_BODY"
TICK
[ "$(row_f 2)" = READY ] && ok || bad "C6b a non-verdict-author bot must not park the row (got '$(row_f 2)' / '$(row_f 7)')"
grep -q "MERGE_REFUSED block-gate" "$MCLOG" && ok || bad "C6b the merge must still be refused (log: $(tail -3 "$MCLOG"))"
[ -s "$T/gh-merges.txt" ] && bad "C6b merged over a BLOCK: $(cat "$T/gh-merges.txt")" || ok
grep -q "rvblock" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "C6b no rvblock attempt line" || ok

echo "C7: the operator-login autopilot BLOCK of this head parks (project-4-site#4)"
reset "$T_HEAD_OLD"
cmt 9002 "$T_BLOCK" operator "$BURL" "$AP_BODY" > "$T/prcomments"
restc 9002 operator "$AP_BODY"
TICK
[ "$(row_f 2)" = BLOCKED_HUMAN ] && [ "$(row_f 7)" = "review-block: 9002 [BLOCK core-flow-broken] $BURL" ] && ok \
  || bad "C7 parked review-block: 9002 (row: $(cat "$ROWS"))"

echo "C8: an unreadable block body: READY, refused, counted, not parked"
reset "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" "$BOT" "$BURL" "$AP_BODY" > "$T/prcomments"
echo 500 > "$T/rest/c-9001.status"
TICK
[ "$(row_f 2)" = READY ] && ok || bad "C8 stays READY (got '$(row_f 2)')"
grep -q "$KEY MERGE_REFUSED block-gate" "$MCLOG" && ok || bad "C8 the refusal line"
f="$T/h/state/merge-conductor/review-block/stuck-example-org_demo-os_42"
[ "$(cat "$f" 2>/dev/null)" = "$H1 9001 1 0" ] && ok || bad "C8 the stuck counter: '$(cat "$f" 2>/dev/null)'"

echo "G: no gh write verb beyond the refusal comment and the C3 merge"
[ -s "$T/gh-writes.txt" ] && bad "G unexpected gh writes: $(cat "$T/gh-writes.txt")" || ok

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

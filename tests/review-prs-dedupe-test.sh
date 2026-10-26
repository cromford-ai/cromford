#!/bin/bash
# tests/review-prs-dedupe-test.sh — the review lane must not buy a second review
# of a head GitHub already holds a review for, and its verdict on a HARNESS PR
# must not sit on the merge queue as a blocking state (BH-872).
#
# THE DEFECT THIS PINS. state/<project>.pr-reviews.json was the ONLY dedupe
# ledger, and it fails silent: `jq -r '.["7"].sha // ""'` on an empty file prints
# nothing with rc 0, and the record write (`jq … f > tmp && mv`) on the same file
# writes an empty file with rc 0. From that moment every tick re-reviewed every
# open head — a paid Fable session and a fresh CHANGES_REQUESTED review each time
# — and on a harness-authored PR that review is the state Mergify reads as
# `github-review-approved = false`, so the PR left the queue and stayed out.
# A pool-built PR reached the review at all only because the pipeline-skip marker
# (`harness build`, printed by bin/run-build.sh after the What/Why/verify
# sections) sits past the 2000-byte window the skip used to read.
#
# So the ledger is GitHub itself: a review row by one of HARNESS_PR_AUTHORS whose
# commit_id is this head and whose body carries the lane's footer. Everything
# below drives the REAL bin/review-prs.sh with only GitHub and the model stubbed,
# and asserts on the gh call log (with the token each call went out on) and the
# files under state/ — never on the script's text.
#
#   bash tests/review-prs-dedupe-test.sh      exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export TEST_ROOT="$T"
mkdir -p "$T/fakebin"

# ── the gh stub ───────────────────────────────────────────────────────────────
# `gh api` answers from a JSON FIXTURE and applies the real `-q` filter with jq,
# so the lane's own jq expressions are under test rather than a hand-shaped TSV.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
# The PR body, in one place: the lane reads it over REST since #891 round 1
# (Nit 6), and `pr view` stays here so a regression back to GraphQL is visible
# as a call in the log rather than as a body the stub refuses to serve.
pr_body() {
  case "${PR_BODY_MODE:-none}" in
    marker_late)
      # 2500+ bytes of ordinary PR body, THEN the pipeline marker — exactly
      # the shape bin/run-build.sh prints (Plan line after What/Why/verify).
      printf '## What\n'
      for i in $(seq 1 50); do printf 'A line of ordinary PR body text that says what changed and why it changed. (%02d)\n' "$i"; done
      printf '\nPlan: harness build BH-1 spec\n' ;;
    marker_prose)
      # The phrase in PROSE, never at line start: this is a HAND PR that talks
      # about the pipeline, and skipping it would mean it is never reviewed.
      printf '## What\nThis changes how a harness build names its spec file.\nNothing here is a Plan line.\n' ;;
    none) printf '## What\nSomething an outside author wrote.\n' ;;
  esac
}
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; exit 0 ;;
    view) pr_body; exit 0 ;;
    review|comment)
      # keep the posted body so the footer can be asserted on
      VERB="$2"
      while [ $# -gt 0 ]; do
        if [ "$1" = --body ]; then printf '%s' "${2:-}" > "$TEST_ROOT/last-post-body.txt"; fi
        shift
      done
      # One switch for "GitHub refused the review": the 422 an App token gets on
      # its own PR prints a REASON, and the lane must keep it (#891 round 1,
      # Important 4).
      if [ "${REVIEW_POST_FAIL:-0}" = 1 ] && [ "$VERB" = review ]; then
        echo 'HTTP 422: Unprocessable Entity — Can not approve your own pull request' >&2
        exit 1
      fi
      exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  shift
  Q=""; METHOD=GET; PATHARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) Q="${2:-}"; shift 2 ;;
      -X|--method) METHOD="${2:-}"; shift 2 ;;
      -f|-F|--field|--raw-field) shift 2 ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  emit() { if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s' "$1"; fi; }
  case "$PATHARG" in
    */reviews/*/dismissals)
      [ "${DISMISS_FAIL:-0}" = 1 ] && exit 1
      exit 0 ;;
    */pulls/*/reviews/*)
      emit "$(jq -c --argjson id "${PATHARG##*/}" '.[] | select(.id == $id)' "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/*/reviews|*/pulls/*/reviews\?*)
      # Two shapes reach here: rp_reviews_tsv's bare path, and the BH-1017
      # rehydrate rung's `…/reviews?per_page=100`. Same rows, same fixture.
      [ "${REVIEWS_MODE:-ok}" = error ] && exit 1
      emit "$(cat "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    *actions/runs*)
      exit 0 ;;
    */pulls/[0-9]*)
      # The pipeline-marker read, over REST (#891 round 1, Nit 6).
      emit "$(jq -nc --arg b "$(pr_body)" '{body:$b}')"
      exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: 2\nVERDICT: %s\n' "${AGENT_VERDICT:-REQUEST_CHANGES}" > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

# ── the fixture harness tree ──────────────────────────────────────────────────
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  rm -rf "$T/h"
  rm -f "$T/agent-calls.log" "$T/gh-calls.log" "$T/last-post-body.txt" "$T/reviews.json"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" tproj
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 100.0.0.1\n' > "$T/h/fleet.conf"
  printf '[]\n' > "$T/reviews.json"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
}

# An armed box: env/github-app.env present and bin/gh-token.sh minting ghs_x.
arm_app() {
  printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$T/h/env/github-app.env"
  printf '#!/bin/bash\nprintf "ghs_x\\n"\n' > "$T/h/bin/gh-token.sh"
  chmod +x "$T/h/bin/gh-token.sh"
}

reviews() { printf '%s\n' "$1" > "$T/reviews.json"; }

# The lane's own footer is the identity mark; the body shape is the one
# bin/review-prs.sh actually posts.
footer_body() { # footer_body <sha> <APPROVE|REQUEST_CHANGES>
  printf 'Static review.\n1. lib/x.ts:4 leaks a token into the log — read it from env.\nTIER: 2\nVERDICT: %s\n\n---\n_Automated harness review (Fable) of %s. Static review — no build run._' "$2" "$1"
}

# BH-8419: the lane's own footer review is posted by the App
# (cromford[bot], type Bot). operator is the operator, a PERSON: a review by
# operator is never the harness's verdict, footer or not.
review_row() { # review_row <id> <state> <commit> <login> <body>
  jq -nc --argjson id "$1" --arg st "$2" --arg c "$3" --arg l "$4" --arg b "$5" \
    '{id:$id, state:$st, commit_id:$c, user:({login:$l} + (if ($l | endswith("[bot]")) then {type:"Bot"} else {} end)), body:$b}'
}

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
    GH_TOKEN="${GH_TOKEN_FIXTURE:-ghp_default}" \
    PR_HEAD="${PR_HEAD:-S1}" PR_AUTHOR="${PR_AUTHOR:-externaldev}" \
    PR_BODY_MODE="${PR_BODY_MODE:-none}" REVIEWS_MODE="${REVIEWS_MODE:-ok}" \
    DISMISS_FAIL="${DISMISS_FAIL:-0}" AGENT_VERDICT="${AGENT_VERDICT:-REQUEST_CHANGES}" \
    REVIEW_POST_FAIL="${REVIEW_POST_FAIL:-0}" \
    bash "$RP" tproj >/dev/null 2>&1
}

calls() { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" || echo 0; }
ghlog() { cat "$T/gh-calls.log" 2>/dev/null; }
ghgrep() { grep -c -F -- "$1" "$T/gh-calls.log" 2>/dev/null || true; }
state_sha() { jq -r '.["7"].sha // ""' "$T/h/state/tproj.pr-reviews.json" 2>/dev/null; }
rplog() { cat "$T/h/logs/pr-reviews.log" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. A standing footer review AT THIS HEAD is the ledger: nothing is bought,
#    nothing is posted, and the local cache is healed from it.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 "cromford[bot]" "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=externaldev run_lane
[ "$(calls)" -eq 0 ] && ok || bad "1: a head GitHub already has our review for bought another review"
[ "$(ghgrep 'pr review')" = 0 ] && ok || bad "1: the lane posted a review on an already-reviewed head"
[ "$(ghgrep 'pr comment')" = 0 ] && ok || bad "1: the lane posted a comment on an already-reviewed head"
[ "$(state_sha)" = "S1" ] && ok || bad "1: the local record was not healed from GitHub (sha='$(state_sha)')"
[ "$(jq -r '.["7"].verdict // ""' "$T/h/state/tproj.pr-reviews.json")" = "REQUEST_CHANGES" ] \
  && ok || bad "1: the healed record did not take the verdict from the review body"
# The skip line is BH-1017's rehydrate line since the rebase: the dedupe half of
# BH-872 was superseded by it (see bin/review-prs.sh, "the DEDUPE half is GONE").
# Same behaviour asserted above — nothing bought, nothing posted, record healed.
grep -q 'not re-reviewed' <<<"$(rplog)" \
  && ok || bad "1: the skip was not logged: $(rplog)"
[ "$(ghgrep 'dismissals')" = 0 ] && ok || bad "1: an EXTERNAL author's PR had a review dismissed"

# 2. The same, with a 0-byte state file — the state loss that started this.
fresh_harness
: > "$T/h/state/tproj.pr-reviews.json"
reviews "[$(review_row 11 CHANGES_REQUESTED S1 "cromford[bot]" "$(footer_body S1 REQUEST_CHANGES)")]"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "2: an empty state file re-bought a review of a reviewed head"
[ "$(ghgrep 'pr review')" = 0 ] && ok || bad "2: an empty state file re-posted a review"
jq -e 'type == "object"' "$T/h/state/tproj.pr-reviews.json" >/dev/null 2>&1 \
  && ok || bad "2: the unparseable state file was not reseeded to a JSON object"
[ "$(state_sha)" = "S1" ] && ok || bad "2: the reseeded record did not record the head"
# The reseed and its log line are main's BH-977 state-load block (one ALERTS.log
# line per repair); BH-872's own reseed was folded into it on rebase.
grep -q 'reseeded' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "2: the reseed was not logged: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

# 3. An UNREADABLE reviews list. Absent is not the same as unreadable (D11) —
#    but WHAT the two halves do with "unreadable" diverged on the rebase, and
#    this case is rewritten to the behaviour main actually ships:
#      * the PAID review fails OPEN (BH-1017, tests/review-prs-gh-dedup-test.sh
#        G3): a read outage must never be able to stop the review lane, and the
#        cost of being wrong is one duplicate review. BH-872 deferred here
#        instead; main landed the opposite decision afterwards and owns it.
#      * the DISMISSAL — the half BH-872 still owns — is what must NOT happen on
#        an unreadable read, and that is asserted below.
#    The assertion this replaces (0 calls, nothing posted, a 'deferred' line)
#    pinned the reverted behaviour, so it could not survive as written.
fresh_harness
REVIEWS_MODE=error PR_AUTHOR=operator run_lane
[ "$(calls)" -eq 1 ] && ok || bad "3: an unreadable reviews list stopped the lane reviewing (fail-open, BH-1017 G3): $(calls) call(s)"
[ "$(ghgrep 'dismissals')" = 0 ] \
  && ok || bad "3: a review was dismissed off a reviews list this box could not read: $(ghlog)"
[ "$(state_sha)" = "S1" ] && ok || bad "3: the bought review was not recorded: $(state_sha)"
grep -q 'could not read' <<<"$(rplog)" && ok || bad "3: the failed read was not logged: $(rplog)"

# 4. No standing review + a HARNESS-authored PR: the verdict posts as a COMMENT
#    review, never a blocking state, and the footer says so.
fresh_harness
PR_AUTHOR=operator run_lane
[ "$(calls)" -eq 1 ] && ok || bad "4: an unreviewed head did not get its review"
grep -qE 'pr review 7 .*--comment' <<<"$(ghlog)" \
  && ok || bad "4: a harness PR's REQUEST_CHANGES did not post as a COMMENT review: $(ghlog)"
[ "$(ghgrep '--request-changes')" = 0 ] \
  && ok || bad "4: the lane posted a BLOCKING state on a harness-authored PR"
grep -q 'Automated harness review (Fable) of S1' "$T/last-post-body.txt" \
  && ok || bad "4: the posted body lost the lane's footer (the ledger's identity mark)"
grep -q 'does not block the queue' "$T/last-post-body.txt" \
  && ok || bad "4: the comment-review footer does not say the verdict is non-blocking"

# 5. An EXTERNAL author's REQUEST_CHANGES still blocks — a real one should.
fresh_harness
PR_AUTHOR=externaldev run_lane
[ "$(calls)" -eq 1 ] && ok || bad "5: an external PR was not reviewed"
grep -qE 'pr review 7 .*--request-changes' <<<"$(ghlog)" \
  && ok || bad "5: an external author's REQUEST_CHANGES stopped blocking: $(ghlog)"

# 6. The pipeline marker is searched over the WHOLE body: a pool-built PR whose
#    `Plan: harness build` line sits past byte 2000 is skipped as designed.
fresh_harness
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(calls)" -eq 0 ] && ok || bad "6: a pipeline PR was reviewed because its marker sits past byte 2000"
[ "$(ghgrep 'pr review')" = 0 ] && ok || bad "6: a pipeline PR got a second review posted"
# The marker read itself is REST, never `gh pr view --json body` (#891 round 1,
# Nit 6) — on a skipped PR that is the ONLY body read the tick makes, so this
# case is where the GraphQL call would show up if it came back.
[ "$(ghgrep 'pr view')" = 0 ] \
  && ok || bad "6: the pipeline-marker read went over GraphQL (\`gh pr view --json body\`): $(ghlog)"
grep -q 'api repos/o/tproj/pulls/7 ' <<<"$(ghlog)" \
  && ok || bad "6: the pipeline-marker read did not go over REST: $(ghlog)"

# 7. Negative control: a harness-authored PR with NO marker is still reviewed.
fresh_harness
PR_AUTHOR=operator PR_BODY_MODE=none run_lane
[ "$(calls)" -eq 1 ] && ok || bad "7: a harness PR without the pipeline marker stopped being reviewed"

# 8. The lane's OWN legacy blocking review on a harness PR is dismissed, and an
#    old-head review never stands in for the current head (it is still reviewed).
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator run_lane
[ "$(ghgrep 'reviews/11/dismissals')" = 1 ] \
  && ok || bad "8: the lane's own standing CHANGES_REQUESTED was not dismissed exactly once: $(ghlog)"
[ "$(calls)" -eq 1 ] && ok || bad "8: a review at an OLD head wrongly skipped the current head"
grep -q 'dismissed' <<<"$(rplog)" && ok || bad "8: the dismissal was not logged: $(rplog)"

# 9. A human's changes-requested is for a human: no footer, no dismissal.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 operator 'Please rename this function before I merge it.')]"
PR_AUTHOR=operator run_lane
[ "$(ghgrep 'dismissals')" = 0 ] \
  && ok || bad "9: a changes-requested review WITHOUT the lane's footer was dismissed"

# 10. Never on an external author's PR, footer or not.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=externaldev run_lane
[ "$(ghgrep 'dismissals')" = 0 ] && ok || bad "10: a review on an EXTERNAL author's PR was dismissed"

# 11. Only a blocking state is dismissed: an APPROVED footer review is left alone.
fresh_harness
reviews "[$(review_row 11 APPROVED S0 "cromford[bot]" "$(footer_body S0 APPROVE)")]"
PR_AUTHOR=operator run_lane
[ "$(ghgrep 'dismissals')" = 0 ] && ok || bad "11: an APPROVED review was dismissed"

# 12. The parked-PR case this ticket was filed for: a pool-built PR (marker in
#     the body, so no review is bought) whose head already carries the lane's
#     blocking review — the review is dismissed so the queue can take the PR
#     back, and not one paid session is spent.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 "cromford[bot]" "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(calls)" -eq 0 ] && ok || bad "12: the parked pipeline PR bought another review"
[ "$(ghgrep 'reviews/11/dismissals')" = 1 ] \
  && ok || bad "12: the parked PR's blocking review was not dismissed: $(ghlog)"

# 13. A failed dismissal is logged and nothing pretends it worked (D9).
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator DISMISS_FAIL=1 run_lane
grep -q 'could not dismiss' <<<"$(rplog)" \
  && ok || bad "13: a failed dismissal was not logged: $(rplog)"

# 14. Identity: the WRITES go out on the App token when the box mints them; the
#     reads keep the lane's own credential.
fresh_harness
arm_app
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator run_lane
grep -E 'pr review 7 ' "$T/gh-calls.log" | grep -q '^ghs_x ' \
  && ok || bad "14: the review post did not go out on the App token: $(ghlog)"
grep -E 'dismissals' "$T/gh-calls.log" | grep -q '^ghs_x ' \
  && ok || bad "14: the dismissal did not go out on the App token: $(ghlog)"
grep -E 'pr list' "$T/gh-calls.log" | grep -q '^ghp_default ' \
  && ok || bad "14: the PR list stopped using the lane's default credential: $(ghlog)"

# 15. An UNARMED box is byte-for-byte what it was: every call on the one token.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator run_lane
grep -q '^ghp_default | pr review' "$T/gh-calls.log" \
  && ok || bad "15: an unarmed box did not post on its own credential: $(ghlog)"
grep -q '^ghs_' "$T/gh-calls.log" \
  && bad "15: an unarmed box minted a token anyway: $(ghlog)" || ok

# 16. The second tick on an unchanged head is silent: the healed record
#     short-circuits locally, so not even the ledger is read again.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 "cromford[bot]" "$(footer_body S1 REQUEST_CHANGES)")]"
run_lane
: > "$T/gh-calls.log"
run_lane
[ "$(calls)" -eq 0 ] && ok || bad "16: the second tick on an unchanged head bought a review"
[ "$(ghgrep 'pr review')" = 0 ] && ok || bad "16: the second tick posted a review"
[ "$(ghgrep 'pr comment')" = 0 ] && ok || bad "16: the second tick posted a comment"

# 17. A HAND harness PR (harness author, no pipeline marker) whose CURRENT head
#     already carries this lane's blocking review: the row is NOT dismissed.
#     Dismissing it is the "no consumer" state — BH-1017's rehydrate has no
#     DISMISSED filter so it heals the ledger and posts nothing, and
#     br_review_newest skips a DISMISSED row, so findings that were blocking
#     stop being anything at all (#891 round 1, Important 3). Case 12 above is
#     the other side of the same rule: on a PIPELINE PR the row at the head DOES
#     go, because the lane walks away and the conductor needs the queue back.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 "cromford[bot]" "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=none run_lane
[ "$(ghgrep 'dismissals')" = 0 ] \
  && ok || bad "17: an AT-HEAD review on a hand harness PR was dismissed with nothing to consume the verdict: $(ghlog)"
grep -q 'left its own CHANGES_REQUESTED review 11 standing' <<<"$(rplog)" \
  && ok || bad "17: the kept review was not logged: $(rplog)"
[ "$(calls)" -eq 0 ] && ok || bad "17: the head GitHub already holds our review for was re-bought"

# 18. The same PR one head later: the review is now STALE, so it IS dismissed —
#     that is what lets a pushed branch re-enter the merge queue.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=none run_lane
[ "$(ghgrep 'reviews/11/dismissals')" = 1 ] \
  && ok || bad "18: a STALE blocking review on a hand harness PR was not dismissed: $(ghlog)"

# 19. The pipeline marker is ANCHORED (#891 round 1, Nit 8): a hand PR whose
#     body merely TALKS about a harness build is still reviewed. An unanchored
#     match skips it, and a skipped PR is never reviewed at all.
fresh_harness
PR_AUTHOR=operator PR_BODY_MODE=marker_prose run_lane
[ "$(calls)" -eq 1 ] && ok || bad "19: a hand PR that mentions 'harness build' in prose was skipped as a pipeline PR"
grep -q 'api repos/o/tproj/pulls/7 ' <<<"$(ghlog)" \
  && ok || bad "19: the pipeline-marker read did not go over REST: $(ghlog)"

# 20. An APPROVE on a PR the reviewing App ITSELF opened goes out on the lane's
#     DEFAULT credential even on an armed box (#891 round 1, Important 4):
#     under the App token GitHub 422s that approval, the comment fallback
#     silently downgrades the verdict, and the GitHub rung of the dedup loses
#     its review row. TEST-CHANGE (BH-2119): this case used a operator-authored
#     PR, where the default credential used to carry EVERY APPROVE. Every other
#     APPROVE now goes out on the App (tests/review-prs-app-approve.bh-2119-test.sh
#     A1/A4), so the default credential is pinned on the one case that keeps it.
fresh_harness
arm_app
AGENT_VERDICT=APPROVE PR_AUTHOR='cromford[bot]' run_lane
grep -E 'pr review 7 ' "$T/gh-calls.log" | grep -q -- '--approve' \
  && ok || bad "20: the APPROVE verdict did not post as an approval: $(ghlog)"
grep -E 'pr review 7 ' "$T/gh-calls.log" | grep -q '^ghp_default ' \
  && ok || bad "20: the approval went out on the App token, which 422s on the App's own PR: $(ghlog)"

# 21. A refused post keeps the REASON. `2>/dev/null` on the review write is how
#     a 422 became a blank line (#891 round 1, Important 4).
fresh_harness
REVIEW_POST_FAIL=1 PR_AUTHOR=operator run_lane
grep -q 'was refused' <<<"$(rplog)" \
  && ok || bad "21: a refused \`gh pr review\` was not logged: $(rplog)"
grep -q 'Can not approve your own pull request' <<<"$(rplog)" \
  && ok || bad "21: the refusal was logged without gh's own reason: $(rplog)"
[ "$(ghgrep 'pr comment')" = 1 ] \
  && ok || bad "21: the comment fallback did not run after the refused review: $(ghlog)"

# 22. A PERMANENTLY refused dismissal pages once instead of logging a line a
#     tick for ever (#891 round 1, Nit 11). Three ticks, one ALERTS line.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 "cromford[bot]" "$(footer_body S0 REQUEST_CHANGES)")]"
for _ in 1 2 3 4; do
  rm -f "$T/h/state/tproj.pr-reviews.json"; printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
  PR_AUTHOR=operator DISMISS_FAIL=1 run_lane
done
[ "$(grep -c 'has refused to dismiss this lane' "$T/h/logs/ALERTS.log" 2>/dev/null || echo 0)" = 1 ] \
  && ok || bad "22: a permanently refused dismissal did not page exactly once: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"

echo "review-prs-dedupe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

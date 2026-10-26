#!/bin/bash
# tests/review-prs-followups.bh-989-test.sh — the ONE BH-872 (#891) review
# follow-up that is still unshipped, plus regression cover for the two that
# #891's own fix rounds absorbed. Every assertion is on the gh call log, state/
# and logs/ — never on the script's text.
#
# D3 (the deliverable). `pulls/N/reviews` was read for EVERY open harness PR on
#     EVERY tick, ~110 paginated reads an hour per box, for a lane that walks
#     past most of those PRs. #891 round 1 (Nit 7) added the `gh_budget_low`
#     half. This adds the LOCAL-CACHE half: `.ledger_sha` — written only when a
#     dismissal pass at this head completed with nothing left that had to go —
#     answers for free, so a second tick at the same head asks GitHub nothing.
#     It is deliberately NOT `.sha`: a head can be reviewed on a tick whose
#     dismissal pass was deferred (budget low) or refused, and skipping on
#     `.sha` would leave a stale-head blocking row standing until the branch
#     moved again. Cases 4-9.
#
# D1 and D2 of the ticket are NOT implemented here — #891's own fix rounds
# shipped both, in another form, before this branch was rebased onto it:
#   D1 (a self-authored APPROVE 422s) — #891 round 1, Important 4: an `--approve`
#      now goes out on the lane's DEFAULT credential, which is never the PR's
#      author, so GitHub is never asked to refuse it; and the post's stderr is
#      captured, so a refusal logs its reason. Pinned by cases 20/21 of
#      tests/review-prs-dedupe-test.sh. Case 1 below is the surviving cross-check
#      that a refused post still keeps gh's reason and falls back.
#   D2 (the at-head row was dismissed) — #891 round 1, Important 3: whether a PR
#      is a PIPELINE PR is decided FIRST, and `rp_dismiss_own` takes a keep-sha:
#      empty on the pipeline path, the current head on a hand PR. Cases 2 and 3
#      below are regression cover for that shipped behaviour, which D3's
#      watermark now depends on.
#
#   bash tests/review-prs-followups.bh-989-test.sh      exit 0 = pass
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
# Same construction as tests/review-prs-dedupe-test.sh: `gh api` answers from a
# JSON fixture and applies the real `-q` filter with jq, so the lane's own jq is
# under test. Knobs: REVIEW_POST_FAIL (the 422), DISMISS_FAIL, RATE_LOW.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; exit 0 ;;
    view)
      case "$*" in
        *--json\ state*) printf 'OPEN\n'; exit 0 ;;
        *--json\ mergeCommit*) printf '\n'; exit 0 ;;
      esac
      case "${PR_BODY_MODE:-none}" in
        marker_late)
          printf '## What\n'
          for i in $(seq 1 50); do printf 'A line of ordinary PR body text that says what changed and why it changed. (%02d)\n' "$i"; done
          printf '\nPlan: harness build BH-1 spec\n' ;;
        none) printf '## What\nSomething an outside author wrote.\n' ;;
      esac
      exit 0 ;;
    review)
      while [ $# -gt 0 ]; do
        if [ "$1" = --body ]; then printf '%s' "${2:-}" > "$TEST_ROOT/last-post-body.txt"; fi
        shift
      done
      if [ "${REVIEW_POST_FAIL:-0}" = 1 ]; then
        echo 'gh: Review Can not approve your own pull request (HTTP 422)' >&2
        exit 1
      fi
      exit 0 ;;
    comment)
      while [ $# -gt 0 ]; do
        if [ "$1" = --body ]; then printf '%s' "${2:-}" > "$TEST_ROOT/last-post-body.txt"; fi
        shift
      done
      exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  shift
  Q=""; PATHARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) Q="${2:-}"; shift 2 ;;
      -X|--method) shift 2 ;;
      -f|-F|--field|--raw-field) shift 2 ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  emit() { if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s' "$1"; fi; }
  # The ledger gate asks for `…/reviews?per_page=100`; the dismissal pass asks
  # for `…/reviews`. Both are the same fixture, so the query string is dropped
  # before the match — a stub that answered only one of them would make the
  # rehydrate rung look absent and every case below buy a review.
  PATHARG="${PATHARG%%\?*}"
  case "$PATHARG" in
    rate_limit)
      # A LITERAL reset epoch: no wall-clock read (bin/test-determinism-lint.sh).
      case "${RATE_LOW:-0}" in
        1) REM=10 ;;
        unknown) exit 0 ;;   # empty answer -> gh_budget_low rc 2 (unknown)
        *) REM=5000 ;;
      esac
      printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":2000000000},"graphql":{"remaining":%s,"limit":5000,"reset":2000000000}}}\n' "$REM" "$REM"
      exit 0 ;;
    */reviews/*/dismissals)
      [ "${DISMISS_FAIL:-0}" = 1 ] && exit 1
      exit 0 ;;
    */pulls/*/reviews/*)
      emit "$(jq -c --argjson id "${PATHARG##*/}" '.[] | select(.id == $id)' "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/*/reviews)
      [ "${REVIEWS_MODE:-ok}" = error ] && exit 1
      emit "$(cat "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/[0-9]*)
      # The PR body over REST (#891 round 1, Nit 6): the lane reads the pipeline
      # marker here, not through `gh pr view --json body` (GraphQL), and matches
      # it ANCHORED at line start (Nit 8).
      case "${PR_BODY_MODE:-none}" in
        marker_late)
          BODY='## What'$'\n'
          for i in $(seq 1 50); do BODY="$BODY"$(printf 'A line of ordinary PR body text that says what changed and why it changed. (%02d)' "$i")$'\n'; done
          BODY="$BODY"$'\n''Plan: harness build BH-1 spec'$'\n' ;;
        marker_unanchored) BODY='## What'$'\n''We talked about a Plan: harness build once.'$'\n' ;;
        *) BODY='## What'$'\n''Something an outside author wrote.'$'\n' ;;
      esac
      emit "$(jq -nc --arg b "$BODY" '{body:$b}')"
      exit 0 ;;
    *actions/runs*) exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: %s\nVERDICT: %s\n' \
  "${AGENT_TIER:-2}" "${AGENT_VERDICT:-REQUEST_CHANGES}" > "$5"
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
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" tproj
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 100.0.0.1\n' > "$T/h/fleet.conf"
  printf '[]\n' > "$T/reviews.json"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
  # A box whose harness sync HAS landed the rate-limit lib: the lane loads it
  # from $HARNESS/bin/lib and guards every call with `command -v`, so a tree
  # without it reads exactly as it did before (that is the lib's own contract,
  # #891 round 1 Nit 7 — and the reason this fixture has to install it to test
  # the guarded path at all).
  cp "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/gh-budget.sh"
}

# An armed box: env/github-app.env names the App this lane posts as, and
# bin/gh-token.sh mints ghs_x for it.
arm_app() {
  printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$T/h/env/github-app.env"
  printf '#!/bin/bash\nprintf "ghs_x\\n"\n' > "$T/h/bin/gh-token.sh"
  chmod +x "$T/h/bin/gh-token.sh"
}

reviews() { printf '%s\n' "$1" > "$T/reviews.json"; }

footer_body() { # footer_body <sha> <APPROVE|REQUEST_CHANGES>
  printf 'Static review.\n1. lib/x.ts:4 leaks a token into the log — read it from env.\nTIER: 2\nVERDICT: %s\n\n---\n_Automated harness review (Fable) of %s. Static review — no build run._' "$2" "$1"
}

# BH-8419: the lane's own footer reviews are posted as the App
# (cromford[bot], type Bot); the operator login operator is a person and
# stays only the PR author below.
review_row() { # review_row <id> <state> <commit> <login> <body>
  jq -nc --argjson id "$1" --arg st "$2" --arg c "$3" --arg l "$4" --arg b "$5" \
    '{id:$id, state:$st, commit_id:$c, user:{login:$l, type:(if ($l | endswith("[bot]")) then "Bot" else "User" end)}, body:$b}'
}

state_put() { printf '%s\n' "$1" > "$T/h/state/tproj.pr-reviews.json"; }

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
    GH_TOKEN="${GH_TOKEN_FIXTURE:-ghp_default}" \
    PR_HEAD="${PR_HEAD:-S1}" PR_AUTHOR="${PR_AUTHOR:-externaldev}" \
    PR_BODY_MODE="${PR_BODY_MODE:-none}" REVIEWS_MODE="${REVIEWS_MODE:-ok}" \
    DISMISS_FAIL="${DISMISS_FAIL:-0}" REVIEW_POST_FAIL="${REVIEW_POST_FAIL:-0}" \
    RATE_LOW="${RATE_LOW:-0}" GH_BUDGET_TTL_S=0 \
    AGENT_VERDICT="${AGENT_VERDICT:-REQUEST_CHANGES}" AGENT_TIER="${AGENT_TIER:-2}" \
    bash "$RP" tproj >/dev/null 2>&1
}

calls() { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" || echo 0; }
ghlog() { cat "$T/gh-calls.log" 2>/dev/null; }
ghgrep() { grep -c -F -- "$1" "$T/gh-calls.log" 2>/dev/null || true; }
# COUNTER CHANGED (BH-1585): the re-review prompt's THREAD context is a REST
# read of the same reviews path now (it was `gh pr view --json comments,reviews`,
# which never matched here), spelled `api -i -X GET …/reviews?per_page=100`. It
# is prompt context bought AFTER the gate, not one of the reads below, so it is
# excluded — every claim that uses reads() keeps its number.
reads() { local a b; a=$(ghgrep 'pulls/7/reviews'); b=$(ghgrep 'api -i -X GET repos/o/tproj/pulls/7/reviews?per_page=100'); echo $(( a - b )); }
# reads() counts every call whose path STARTS pulls/7/reviews — the dismissal
# list, a single review body, a dismissal PUT, and the ledger gate's own
# `?per_page=100` read. Where a scenario asserts an exact count AND expects a
# dismissal, count the dismissal-pass LIST only.
list_reads() { ghgrep 'pulls/7/reviews --paginate'; }
dismissals() { grep -c -F -- "/reviews/$1/dismissals" "$T/gh-calls.log" 2>/dev/null || true; }
st() { jq -r --arg k "$1" '.["7"][$k] // ""' "$T/h/state/tproj.pr-reviews.json" 2>/dev/null; }
rplog() { cat "$T/h/logs/pr-reviews.log" 2>/dev/null; }

# ── 1. a refused post keeps gh's reason (D1's surviving half) ─────────────────
# #891 round 1, Important 4 captures the review's stderr. Without it a 422 read
# as "could not be posted" with no reason, and the reason is the diagnosis.
fresh_harness
PR_AUTHOR=externaldev AGENT_VERDICT=APPROVE REVIEW_POST_FAIL=1 run_lane
[ "$(ghgrep 'pr comment')" -ge 1 ] \
  && ok || bad "1: a refused review post lost its comment fallback: $(ghlog)"
grep -q '422' <<<"$(rplog)" \
  && ok || bad "1: the refused post did not log why (the 422 body): $(rplog)"

# ── 2-3. the row bound to the current head (D2, shipped by #891 round 1) ──────
# 2. A harness-authored, NON-pipeline PR carrying our own CHANGES_REQUESTED at
#    the CURRENT head: the row stays (the resolver's fix round consumes it), the
#    ledger gate heals the cache, nothing is bought and nothing is posted.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 'cromford[bot]' "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=operator run_lane
[ "$(ghgrep 'dismissals')" = 0 ] \
  && ok || bad "2: the at-head review was dismissed, so the resolver skips the findings: $(ghlog)"
[ "$(calls)" -eq 0 ] && ok || bad "2: an already-reviewed head bought another review"
[ "$(st verdict)" = REQUEST_CHANGES ] && [ "$(st sha)" = S1 ] \
  && ok || bad "2: the cache was not healed from the kept row (verdict='$(st verdict)' sha='$(st sha)')"
grep -q 'standing — it is AT the current head' <<<"$(rplog)" \
  && ok || bad "2: keeping the at-head row was not logged: $(rplog)"

# 3. Stale-head rows still go; only the current head's row is kept — and the
#    PIPELINE-skip path still dismisses the at-head row, because there the
#    build's own lenses approved the head and br_review_newest relies on it.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)"),$(review_row 12 CHANGES_REQUESTED S1 'cromford[bot]' "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=operator run_lane
[ "$(dismissals 11)" = 1 ] \
  && ok || bad "3: the stale-head blocking review stopped being dismissed: $(ghlog)"
[ "$(dismissals 12)" = 0 ] \
  && ok || bad "3: the row at the current head was dismissed: $(ghlog)"
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S1 'cromford[bot]' "$(footer_body S1 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(dismissals 11)" = 1 ] \
  && ok || bad "3: a pipeline PR's at-head dismissal was lost: $(ghlog)"
[ "$(calls)" -eq 0 ] && ok || bad "3: a pipeline PR was reviewed"

# ── 4-9. D3: the per-tick read ────────────────────────────────────────────────
# 4. A pipeline PR gets no `.sha` row ever — the lane never reviews it — so a
#    clean dismissal pass leaves its own watermark, and tick 2 reads nothing.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(reads)" -ge 1 ] && ok || bad "4: tick 1 never read the ledger: $(ghlog)"
[ "$(dismissals 11)" = 1 ] && ok || bad "4: tick 1 did not dismiss the stale-head row: $(ghlog)"
[ "$(st ledger_sha)" = S1 ] \
  && ok || bad "4: a clean dismissal pass left no watermark (ledger_sha='$(st ledger_sha)')"
[ -z "$(st verdict)" ] \
  && ok || bad "4: the watermark wrote a verdict onto a pipeline PR's row (verdict='$(st verdict)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(reads)" = 0 ] \
  && ok || bad "4: tick 2 read the ledger again on a watermarked head: $(ghlog)"

# 5. The watermark is keyed on the HEAD: a new head reads again.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(st ledger_sha)" = S1 ] && ok || bad "5: tick 1 left no watermark"
: > "$T/gh-calls.log"
PR_HEAD=S2 PR_AUTHOR=operator PR_BODY_MODE=marker_late run_lane
[ "$(reads)" -ge 1 ] \
  && ok || bad "5: a NEW head skipped the read on the previous head's watermark: $(ghlog)"

# 6. `.sha` alone is NOT a skip. A head can be reviewed on a tick whose
#    dismissal pass never ran; skipping on `.sha` would leave a stale-head
#    blocking row standing until the branch moved again.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
state_put '{"7":{"sha":"S1","verdict":"REQUEST_CHANGES","tier":"2","served":"claude"}}'
PR_AUTHOR=operator run_lane
[ "$(reads)" -ge 1 ] \
  && ok || bad "6: a reviewed head with no dismissal watermark skipped the read: $(ghlog)"
[ "$(dismissals 11)" = 1 ] \
  && ok || bad "6: the stale-head blocking row was left standing: $(ghlog)"
[ "$(calls)" -eq 0 ] && ok || bad "6: a reviewed head bought another review"

# 6b. A BUDGET-LOW tick may cost a tick, never a dismissal. The pass is deferred
#     and the ledger gate then buys the review and records `.sha` — so if the
#     skip were on `.sha`, the legacy CHANGES_REQUESTED at the OLD head would
#     block Mergify until the head moved again. It is on `.ledger_sha`, which
#     that tick never wrote, so the next healthy tick reads and dismisses.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator RATE_LOW=1 run_lane
[ "$(list_reads)" = 0 ] \
  && ok || bad "6b: the deferred pass read the list anyway: $(ghlog)"
[ "$(dismissals 11)" = 0 ] && ok || bad "6b: the deferred tick dismissed: $(ghlog)"
[ "$(st sha)" = S1 ] && [ -z "$(st ledger_sha)" ] \
  && ok || bad "6b: the bought review left a watermark (sha='$(st sha)' ledger_sha='$(st ledger_sha)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator run_lane
[ "$(list_reads)" = 1 ] \
  && ok || bad "6b: the next healthy tick skipped the read on .sha and stranded the stale row: $(ghlog)"
[ "$(dismissals 11)" = 1 ] \
  && ok || bad "6b: the stale-head blocking row was stranded, so it blocks the queue until the head moves: $(ghlog)"
[ "$(calls)" -eq 1 ] \
  && ok || bad "6b: the second tick bought a second review"

# 6c. The dismissal pass is for OUR rows only: an external author's PR is read
#     by the same gate and nothing of theirs is ever dismissed.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 externaldev "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=externaldev run_lane
[ "$(ghgrep 'dismissals')" = 0 ] \
  && ok || bad "6c: a review on an external author's PR was dismissed: $(ghlog)"

# 7. A FAILED dismissal writes no watermark: the next tick must retry.
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late DISMISS_FAIL=1 run_lane
[ -z "$(st ledger_sha)" ] \
  && ok || bad "7: a failed dismissal was watermarked as done (ledger_sha='$(st ledger_sha)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator PR_BODY_MODE=marker_late DISMISS_FAIL=1 run_lane
[ "$(reads)" -ge 1 ] \
  && ok || bad "7: the next tick did not retry the failed dismissal: $(ghlog)"

# 7b. An UNREADABLE reviews list writes no watermark either.
fresh_harness
PR_AUTHOR=operator PR_BODY_MODE=marker_late REVIEWS_MODE=error run_lane
[ -z "$(st ledger_sha)" ] \
  && ok || bad "7b: an unreadable reviews list was watermarked as done (ledger_sha='$(st ledger_sha)')"

# 8. Budget low: the per-tick read is non-essential and skips, with a line in
#    both logs (ours names the PR, the lib's names the lane).
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late RATE_LOW=1 run_lane
[ "$(reads)" = 0 ] \
  && ok || bad "8: the reviews read ran with the GitHub budget low: $(ghlog)"
grep -q 'the GitHub API budget is low' <<<"$(rplog)" \
  && ok || bad "8: the skipped read was not logged: $(rplog)"
grep -q 'budget low' "$T/h/logs/review-prs.log" 2>/dev/null \
  && ok || bad "8: the budget lib logged nothing: $(cat "$T/h/logs/review-prs.log" 2>/dev/null)"
[ -z "$(st ledger_sha)" ] \
  && ok || bad "8: a deferred read was watermarked as a completed pass (ledger_sha='$(st ledger_sha)')"

# 9. The LEDGER GATE is not budget-guarded: it is the last dedupe check before
#    a paid review, so an unreviewed non-pipeline head still reads once and the
#    review is bought. And UNKNOWN is not low — an unreadable rate_limit reads.
fresh_harness
PR_AUTHOR=operator RATE_LOW=1 run_lane
[ "$(reads)" = 1 ] \
  && ok || bad "9: the last check before the money did not run exactly once: $(ghlog)"
[ "$(calls)" -eq 1 ] && ok || bad "9: the review was not bought (reads=$(reads)): $(ghlog)"
grep -qE 'pr review 7 .*--comment' <<<"$(ghlog)" \
  && ok || bad "9: the verdict did not post: $(ghlog)"
fresh_harness
reviews "[$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")]"
PR_AUTHOR=operator PR_BODY_MODE=marker_late RATE_LOW=unknown run_lane
[ "$(reads)" -ge 1 ] \
  && ok || bad "9: an UNKNOWN budget was read as low and skipped the read: $(ghlog)"

echo "review-prs-followups.bh-989: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/harness-pr-authors-test.sh — bin/lib/gh-pr-list.sh against a gh stub.
#
# The rule under test (2026-09-14). GitHub App installation tokens went live and
# a PR opened on one is authored by the App, not by the PAT's owner:
#   gh pr view 696 -R example-org/project-5 --json author
#   -> {"login":"app/cromford","is_bot":true}
# Every consumer that discovered harness PRs with a hardcoded `--author operator`
# went blind to them — project-5 #696/#697 (APPROVE on record, CI green) sat
# unmerged with zero merge-conductor log lines. So: the list runs once PER
# AUTHOR and unions the answers, one author failing never costs the other's PRs,
# and no script under bin/ carries a bare `--author operator` any more.
# Run from anywhere: tests/harness-pr-authors-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# gh stub: each author owns a different slice of o/repo, with #2 in BOTH so the
# union has something real to dedupe. o/flaky answers only for the PAT login —
# that is the "one author's list fails" case. o/dark fails for everyone.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
A=""; R=""
while [ $# -gt 0 ]; do
  case "$1" in -R) R="$2"; shift 2 ;; --author) A="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s\n' "$R" "$A" >> "$GH_CALLS"
case "$R/$A" in
  o/repo/operator)             echo '[{"number":1,"title":"pat-one"},{"number":2,"title":"both"}]' ;;
  o/repo/app/cromford)  echo '[{"number":2,"title":"both"},{"number":3,"title":"app-three"}]' ;;
  o/repo/app/cromford-builders) echo '[]' ;;
  o/repo/app/cromford-board) echo '[]' ;;
  o/flaky/operator)            echo '[{"number":7,"title":"survivor"}]' ;;
  o/flaky/app/cromford) exit 1 ;;
  o/empty/*)                 echo '[]' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

drive() { # drive <bash snippet>; the lib is sourced fresh with HARNESS=$T/h
  # TEST-CHANGE (BH-1585): mergeStateStatus is a (lazy) REST field now and the
  # per-author path is opt-in (GH_PR_LIST_GRAPHQL_FALLBACK=1), so the cases below
  # reach it with a field nothing else carries (potentialMergeCommit) and the
  # switch on — the same move BH-374/BH-782 made here. Assertions unchanged.
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALLS="$T/calls.txt" GH_PR_LIST_GRAPHQL_FALLBACK=1
    # TEST-CHANGE (BH-8530): the default derives from HARNESS_SELF_APPS, so a
    # runner that exports it must not change the exact strings pinned below.
    unset HARNESS_PR_AUTHORS HARNESS_SELF_APPS
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-pr-list.sh"; eval "$1" )
}

# 1. the default author set covers the incident with no operator action
# TEST-CHANGE (BH-1668): the default now carries the second App, the builders
# App BH-1578 moved pool machines onto; "operator app/cromford" was the set
# that hid every pool-built PR. Same assertion, the new default.
# TEST-CHANGE (BH-8530): the default derives from HARNESS_SELF_APPS and gains the
# board App, cromford-board, whose PRs (project-6-desktop #6) it dropped.
[ "$(drive 'harness_pr_authors')" = "operator app/cromford app/cromford-builders app/cromford-board" ] \
  && ok || bad "default author set: $(drive 'harness_pr_authors')"


# TEST-CHANGE (BH-374): the next two cases include `mergeStateStatus`, which is
# outside the REST mappable set, so this fixture's stub continues to exercise
# the per-author fallback path and the call-count assertion stays valid.
# 2. union of both authors, deduped by number, first-seen order
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/repo open number,title,potentialMergeCommit')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[1,2,3]" ] \
  && ok || bad "union by number (stable order, no duplicates): $OUT"
[ "$(jq 'length' <<<"$OUT")" = 3 ] && ok || bad "duplicate #2 was not deduped: $OUT"
[ "$(jq -r '.[1].title' <<<"$OUT")" = "both" ] && ok || bad "the union dropped a field: $OUT"
# ...and it really did ask once per author, never once for everybody
# TEST-CHANGE (BH-1668): three authors in the default now, so three calls.
# TEST-CHANGE (BH-8530): four (the board App joined the default), so four calls.
[ "$(grep -c . "$T/calls.txt")" = 4 ] && ok || bad "expected one gh call per author, got: $(cat "$T/calls.txt")"
grep -qx "o/repo operator" "$T/calls.txt" && grep -qx "o/repo app/cromford" "$T/calls.txt" \
  && ok || bad "both authors should have been listed: $(cat "$T/calls.txt")"

# 3. one author failing keeps the other's PRs (the whole point: the App list
#    404ing on an un-installed repo must not hide the PAT's work, and vice versa)
#
# TEST-CHANGE (BH-782): `mergeStateStatus` joins the field list in cases 3 and 4
# for the same reason it joined case 2 under BH-374 — it is outside the REST
# mappable set, so these cases keep exercising the PER-AUTHOR path, which is
# what they are about. Without it the call now takes the REST path and this
# fixture's stub (which only speaks `gh pr list`) would be measuring a network
# failure instead of a failing author. The assertions are unchanged.
OUT=$(drive 'harness_pr_list o/flaky open number,title,potentialMergeCommit'); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[7]" ] \
  && ok || bad "a failing author emptied the list: rc=$RC out=$OUT"
drive 'harness_pr_list o/flaky open number,title,potentialMergeCommit >/dev/null'
grep -q "gh pr list --author app/cromford failed" "$T/h/logs/gh-pr-list.log" \
  && ok || bad "a failing author must be logged, never swallowed: $(cat "$T/h/logs/gh-pr-list.log" 2>/dev/null)"

# 4. empty only when ALL authors fail — and that is rc 1, so every call site's
#    existing failure path (gh_repo_list_failed, the invisible-repo alert) fires
OUT=$(drive 'harness_pr_list o/dark open number,title,potentialMergeCommit'); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "all-authors-fail should be rc 1 and empty: rc=$RC out=$OUT"
# a repo with no harness PRs is a SUCCESS with an empty array, not a failure
OUT=$(drive 'harness_pr_list o/empty open number,title,potentialMergeCommit'); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c . <<<"$OUT")" = "[]" ] && ok || bad "no PRs must read as [] rc 0: rc=$RC out=$OUT"

# 5. env override: a box that renames the App sets one variable
OUT=$(drive 'HARNESS_PR_AUTHORS="operator" harness_pr_list o/repo open number,title,potentialMergeCommit')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[1,2]" ] \
  && ok || bad "HARNESS_PR_AUTHORS override ignored: $OUT"
[ "$(drive 'HARNESS_PR_AUTHORS="a b" harness_pr_authors')" = "a b" ] \
  && ok || bad "HARNESS_PR_AUTHORS override ignored by harness_pr_authors"
# the App slug named in env/github-app.env is unioned in, slugified like GitHub does
printf 'GH_APP_SLUG=Cromford Two\n' > "$T/h/env/github-app.env"
# TEST-CHANGE (BH-8530): the board App sits before the env file's slug.
[ "$(drive 'harness_pr_authors')" = "operator app/cromford app/cromford-builders app/cromford-board app/cromford-two" ] \
  && ok || bad "env/github-app.env slug not unioned in: $(drive 'harness_pr_authors')"
# ...and reading that file must not export GH_APP_* into the caller
[ -z "$(drive 'printf %s "${GH_APP_SLUG:-}"')" ] \
  && ok || bad "github-app.env was sourced, not read — GH_APP_SLUG leaked into the caller"
rm -f "$T/h/env/github-app.env"

# 6. one actor, three spellings: GraphQL says app/x, REST says x[bot], a git
#    author name says x. A consumer comparing strings needs all three.
drive 'harness_pr_author_match "app/cromford"' && ok || bad "app/ spelling should match"
drive 'harness_pr_author_match "cromford[bot]"' && ok || bad "REST [bot] spelling should match"
drive 'harness_pr_author_match "operator"' && ok || bad "the PAT login should still match"
drive 'harness_pr_author_match "collaborator-1"' && bad "a third-party lane must NOT read as ours" || ok
drive 'harness_pr_author_match ""' && bad "an empty author must NOT read as ours" || ok
# TEST-CHANGE (BH-1668): the builders App's three spellings follow the hub App's.
# TEST-CHANGE (BH-8530): and the board App's three follow the builders App's.
[ "$(drive 'harness_pr_authors_csv')" = "operator,app/cromford,cromford[bot],cromford,app/cromford-builders,cromford-builders[bot],cromford-builders,app/cromford-board,cromford-board[bot],cromford-board" ] \
  && ok || bad "SELF_ACTORS csv: $(drive 'harness_pr_authors_csv')"
[ "$(drive 'harness_pr_authors_json')" = '["operator","app/cromford","cromford[bot]","cromford","app/cromford-builders","cromford-builders[bot]","cromford-builders","app/cromford-board","cromford-board[bot]","cromford-board"]' ] \
  && ok || bad "jq --argjson array: $(drive 'harness_pr_authors_json')"

# 7. THE REGRESSION GUARD. No script under bin/ may discover harness PRs by a
#    hardcoded login again — that is the whole incident, and a new call site
#    written from an old one is exactly how it would come back.
HITS=$(grep -rn -- '--author operator' "$DIR/bin" 2>/dev/null | grep -v 'bin/lib/gh-pr-list.sh')
[ -z "$HITS" ] && ok || bad "bare --author operator still under bin/: $HITS"
# every consumer names the shared helper rather than re-deriving the set
for f in merge-conductor.sh merge-sweep.sh review-prs.sh review-autopilot.sh rebase-train.sh \
         tickets-snapshot-push.sh pipeline-health.sh cost-rollup.sh triage-gate.sh \
         migration-autopilot.sh; do
  grep -q 'gh-pr-list.sh' "$DIR/bin/$f" \
    && ok || bad "bin/$f does not source bin/lib/gh-pr-list.sh"
done
# merge-sweep carries an inline fallback (the fixtures copy it standalone, the
# same reason its token probe is inline). If the two defaults ever disagree, a
# scratch tree silently goes back to the 2026-09-14 behaviour.
# TEST-CHANGE (BH-8530): HARNESS_PR_AUTHORS_DEFAULT is derived from
# HARNESS_SELF_APPS, not one literal line, so read the SOURCED value and check
# merge-sweep's fallback carries the operator-login variable and every App of it.
DEF=$(drive 'printf %s "$HARNESS_PR_AUTHORS_DEFAULT"')
MS=$(grep -o 'HARNESS_PR_AUTHORS:-\${HARNESS_OPERATOR_LOGIN:-}[^}]*}' "$DIR/bin/merge-sweep.sh"); MS="${MS%\}}"
MISS=""; for a in $DEF; do case "$a" in app/*) case "$MS " in *" $a "*) ;; *) MISS="$MISS $a" ;; esac ;; esac; done
[ -n "$DEF" ] && [ -n "$MS" ] && [ -z "$MISS" ] \
  && ok || bad "bin/merge-sweep.sh's inline fallback has drifted from HARNESS_PR_AUTHORS_DEFAULT ($DEF); missing:$MISS"

echo "harness-pr-authors: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/gh-pr-list-builders-author.bh-1668-test.sh — the second App's PRs are
# ours, and a harness-branch PR the author filter drops is never silent.
#
# THE INCIDENT (2026-09-23 13:18Z -> 2026-09-24). BH-1578 moved pool builders
# onto a second GitHub App, cromford-builders, so every PR a pool machine
# opened from then on was authored `cromford-builders[bot]`. The author set
# in bin/lib/gh-pr-list.sh was still "operator app/cromford" and neither
# env/github-app*.env names a slug, so the REST filter dropped every one of them.
# merge-conductor logged `TICK project-5 ... prs=0` for 22 hours while 14 green,
# ledger-APPROVE PRs sat open, and the BH-1668 self-enqueue never saw a row. The
# list was READABLE — it was the filter that emptied it, and it said nothing.
#
# What this pins:
#   B1  the default author set carries app/cromford-builders
#   B2  a REST open list returns cromford-builders[bot] PRs
#   B3  an App profile file (env/github-app-<profile>.env) naming GH_APP_SLUG
#       is unioned in, like env/github-app.env always was
#   B4  a ticket/* PR by an author the set does not know is still dropped (the
#       filter keeps its meaning) but is LOGGED with its number and login, and
#       raises ONE fleet alert per repo per day
#   B5  a non-harness branch by a stranger, and closed lists, raise nothing
#   B6  merge-sweep's inline fallback matches the lib default
# Run from anywhere: tests/gh-pr-list-builders-author.bh-1668-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/h/flags" "$T/h/bin" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# beat stub: records every fleet alert the lib sends.
cat > "$T/h/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEATS"
SH
chmod +x "$T/h/bin/beat.sh"

# gh shim (REST only). FIXTURE rows:
#   o/ts      #11 operator ticket/TK-11, #12 cromford-builders[bot] ticket/TK-12,
#             #13 cromford[bot] ticket/TK-13, #14 mergify[bot] mergify/merge-queue/x
#   o/strange #21 operator ticket/a, #22 other-app[bot] ticket/b, #23 stranger feature/c
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
[ "$1" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
printf '%s\n' "$P" >> "$GH_CALLS"
repo="${P%%/pulls*}"; repo="${repo#repos/}"
row() { # row <num> <login> <ref>
  jq -nc --argjson n "$1" --arg l "$2" --arg r "$3" --arg repo "$repo" '{
    number: $n, html_url: "https://github.com/\($repo)/pull/\($n)", title: "FIXTURE \($n)",
    head: {sha: "s\($n)", ref: $r, repo: {full_name: $repo}}, base: {ref: "main", repo: {full_name: $repo}},
    draft: false, user: {login: $l, type: "Bot"},
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
    merged_at: null, closed_at: null, state: "open", labels: []}'
}
case "$repo" in
  o/ts)      R=$(row 11 operator ticket/TK-11; row 12 'cromford-builders[bot]' ticket/TK-12; row 13 'cromford[bot]' ticket/TK-13; row 14 'mergify[bot]' mergify/merge-queue/x) ;;
  o/strange) R=$(row 21 operator ticket/a; row 22 'other-app[bot]' ticket/b; row 23 stranger feature/c) ;;
  *) printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n'
printf '%s\n' "$R" | jq -sc .
GH
chmod +x "$T/fakebin/gh"

drive() { # drive <bash snippet>; the lib sourced fresh with HARNESS=$T/h
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALLS="$T/calls.txt" BEATS="$T/beats.txt"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES HARNESS_SELF_APPS  # TEST-CHANGE (BH-8530): the default derives from it
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-pr-list.sh"; eval "$1" )
}
F=number,url,headRefName,author

# B1 — the second App is in the default set, in every spelling
case " $(drive 'harness_pr_authors') " in *" app/cromford-builders "*) ok ;; *) bad "B1 default set lacks app/cromford-builders: $(drive 'harness_pr_authors')" ;; esac
drive 'harness_pr_author_match "cromford-builders[bot]"' && ok || bad "B1 REST spelling cromford-builders[bot] must match"

# B2 — the REST open list keeps the builders PR (the incident: it did not)
OUT=$(drive "harness_pr_list o/ts open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[11,12,13]" ] \
  && ok || bad "B2 open list should be [11,12,13] (builders #12 included, mergify #14 not): rc=$RC $OUT"
# ...and o/ts has nothing unknown on a harness branch, so nothing is raised
[ ! -s "$T/beats.txt" ] && ok || bad "B2 a fully-known repo raised an alert: $(cat "$T/beats.txt")"
grep -q "UNKNOWN-AUTHOR" "$T/h/logs/gh-pr-list.log" 2>/dev/null && bad "B2 logged UNKNOWN-AUTHOR on a clean repo" || ok

# B3 — an App profile file naming its slug is unioned in
printf 'GH_APP_ID=1\nGH_APP_SLUG=Other App\n' > "$T/h/env/github-app-other.env"
case " $(drive 'harness_pr_authors') " in *" app/other-app "*) ok ;; *) bad "B3 profile slug not unioned: $(drive 'harness_pr_authors')" ;; esac
OUT=$(drive "harness_pr_list o/strange open $F 100")
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21,22]" ] && ok || bad "B3 other-app[bot] PR should list once its profile names it: $OUT"
[ -z "$(drive 'printf %s "${GH_APP_SLUG:-}"')" ] && ok || bad "B3 a profile file was sourced, not read — GH_APP_SLUG leaked"
rm -f "$T/h/env/github-app-other.env"

# B4 — without the profile, other-app's ticket/* PR is dropped, LOUDLY
: > "$T/h/logs/gh-pr-list.log"; : > "$T/beats.txt"
OUT=$(drive "harness_pr_list o/strange open $F 100"); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$OUT")" = "[21]" ] \
  && ok || bad "B4 the filter must still drop the unknown author: rc=$RC $OUT"
L=$(grep "UNKNOWN-AUTHOR" "$T/h/logs/gh-pr-list.log" 2>/dev/null)
case "$L" in *"o/strange"*"#22"*"other-app[bot]"*) ok ;; *) bad "B4 log line must name repo, PR and login: '$L'" ;; esac
case "$L" in *"#23"*) bad "B4 a non-ticket branch (#23 feature/c) must not be reported: '$L'" ;; *) ok ;; esac
[ "$(grep -c . "$T/beats.txt" 2>/dev/null)" = 1 ] && ok || bad "B4 expected exactly one fleet alert: $(cat "$T/beats.txt" 2>/dev/null)"
jq -e 'select(.kind=="fleet_alert") | (.line | test("o/strange")) and (.line | test("other-app"))' "$T/beats.txt" >/dev/null 2>&1 \
  && ok || bad "B4 the fleet alert must be a fleet_alert naming repo and login: $(cat "$T/beats.txt" 2>/dev/null)"
grep -q "o/strange" "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "B4 ALERTS.log has no line for o/strange"
# a second read the same day logs again but pages no more
drive "harness_pr_list o/strange open $F 100" >/dev/null
[ "$(grep -c UNKNOWN-AUTHOR "$T/h/logs/gh-pr-list.log")" = 2 ] && ok || bad "B4 every read must log: $(grep -c UNKNOWN-AUTHOR "$T/h/logs/gh-pr-list.log")"
[ "$(grep -c . "$T/beats.txt")" = 1 ] && ok || bad "B4 the alert must page once per repo per day, got $(grep -c . "$T/beats.txt")"

# B5 — closed lists never raise (history holds PRs by anyone, forever)
: > "$T/h/logs/gh-pr-list.log"
drive "harness_pr_list o/strange closed $F 100" >/dev/null
grep -q "UNKNOWN-AUTHOR" "$T/h/logs/gh-pr-list.log" && bad "B5 a closed list raised UNKNOWN-AUTHOR" || ok

# B6 — merge-sweep's inline fallback is the lib default, word for word
# TEST-CHANGE (BH-8530): the default is derived from HARNESS_SELF_APPS, not one
# literal line. Same assertion: the sourced default, with the operator login
# put back as its variable, is merge-sweep's fallback word for word.
DEF=$(drive 'printf %s "$HARNESS_PR_AUTHORS_DEFAULT"'); OP=$(drive 'printf %s "${HARNESS_OPERATOR_LOGIN:-}"')
DEF='${HARNESS_OPERATOR_LOGIN:-}'"${DEF#"$OP"}"
grep -qF "HARNESS_PR_AUTHORS:-$DEF}" "$DIR/bin/merge-sweep.sh" \
  && ok || bad "B6 bin/merge-sweep.sh's inline fallback drifted from '$DEF'"

# B7 — THE VERDICT-AUTHOR SET IS SEPARATE AND EXCLUDES THE BUILDERS APP
# (review of #1926, blocking 2). Listing a PR is not issuing a verdict: the
# builders App is the identity the pool build boxes hold, so a verdict comment it
# posts must never count.
# BH-8419: the set holds Apps only; the operator login is a person.
[ "$(drive 'harness_verdict_authors')" = "app/cromford" ] \
  && ok || bad "B7 default verdict set: '$(drive 'harness_verdict_authors')'"
drive 'harness_verdict_author_match "cromford-builders[bot]"' && bad "B7 the builders App must NOT be a verdict author" || ok
drive 'harness_verdict_author_match "app/cromford-builders"' && bad "B7 the builders App (app/ spelling) must NOT be a verdict author" || ok
drive 'harness_verdict_author_match "cromford[bot]"' && ok || bad "B7 the hub App must stay a verdict author"
drive 'harness_verdict_author_match "operator"' && bad "B7 the operator (PAT) login must NOT be a verdict author (BH-8419)" || ok
case "$(drive 'harness_verdict_authors_json')" in *builders*) bad "B7 verdict json carries builders: $(drive 'harness_verdict_authors_json')" ;; *'"cromford[bot]"'*) ok ;; *) bad "B7 verdict json lacks the REST spelling: $(drive 'harness_verdict_authors_json')" ;; esac
# a profile file naming a slug makes that App a PR author, never a verdict author
printf 'GH_APP_SLUG=cromford-builders\n' > "$T/h/env/github-app-builders.env"
drive 'harness_verdict_author_match "cromford-builders[bot]"' && bad "B7 a profile slug must never grant verdict trust" || ok
rm -f "$T/h/env/github-app-builders.env"
# the knob narrows it; it is registered, and NOT settable from a DB row
[ "$(drive 'HARNESS_VERDICT_AUTHORS=app/acme-review harness_verdict_authors')" = app/acme-review ] && ok || bad "B7 HARNESS_VERDICT_AUTHORS override ignored"
[ -z "$(drive 'HARNESS_VERDICT_AUTHORS=operator harness_verdict_authors')" ] && ok || bad "B7 an override that lists the operator login must drop it (BH-8419)"
jq -e '.libs[] | select(.id=="gh-pr-list") | .knobs[] | select(.env=="HARNESS_VERDICT_AUTHORS") | .settable == false and .default == "app/cromford"' "$DIR/catalog/lanes.d/_lib.json" >/dev/null \
  && ok || bad "B7 HARNESS_VERDICT_AUTHORS must be registered (catalog/lanes.d/_lib.json, gh-pr-list) with settable:false and the default"
# every verdict-reading site uses the verdict set, never the PR-author set
grep -q 'harness_verdict_authors_json' "$DIR/bin/lib/mc/classify.sh" && ! grep -q 'harness_pr_authors_json' "$DIR/bin/lib/mc/classify.sh" \
  && ok || bad "B7 bin/lib/mc/classify.sh must read verdict comments against harness_verdict_authors_json"
grep -q 'harness_verdict_authors_json' "$DIR/bin/review-autopilot.sh" && ! grep -q 'harness_pr_authors_json' "$DIR/bin/review-autopilot.sh" \
  && ok || bad "B7 bin/review-autopilot.sh must read its marker against harness_verdict_authors_json"
[ "$(grep -c 'harness_verdict_author_match' "$DIR/bin/blocked-resolver.sh")" -ge 1 ] && ok || bad "B7 blocked-resolver's harness-review reader must use harness_verdict_author_match"
[ "$(grep -c 'harness_verdict_author_match' "$DIR/bin/review-prs.sh")" -ge 2 ] && ok || bad "B7 review-prs' own-review readers (dismiss + marker) must use harness_verdict_author_match"

echo "gh-pr-list-builders-author: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

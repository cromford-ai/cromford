#!/bin/bash
# tests/merged-build-closeout.bh-7731-test.sh — BH-7731 T4: the one-time
# backfill bin/merged-build-closeout.sh, driven as a process against a routed
# REST stub (tests/lib/gh-rest-fx.sh). Fixtures:
# tests/fixtures/merged-build-closeout.bh-7731/{project-6,lab}.tsv.
#
#   F1   project-6 dry run: TK-1364 and TK-1741 close, the 11 slice tickets keep
#   A1   a dry run writes nothing to GitHub and no ledger row
#   A2   --apply closes #1364 and #1741, one comment and one CLOSED line each,
#        and one comment-once ledger row each (no state/ dir);
#        a second --apply posts nothing and says skip:already-closed
#   A3   a close whose PATCH answers 403 is skip:close-deferred, not closed
#   A4   a comment-once row already there: the close lands with no comment
#   A5   a ledger that cannot answer is skip:ledger-read: no comment, no close
#   M/D  the lab project: the PR match and the close-vs-keep rules
#   X1   a bad flag exits 2, a board project exits 2, every list read failing exits 1
#   L1   every stdout line has 6 TSV fields
#   K1   a settings row for MBC_PR_PAGE_CAP changes the PR page cap
#
#   HARNESS_TEST_SANDBOX=1 bash tests/merged-build-closeout.bh-7731-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
FX="$DIR/tests/fixtures/merged-build-closeout.bh-7731"
[ -r "$DIR/bin/merged-build-closeout.sh" ] && [ -r "$FX/project-6.tsv" ] || { echo "FAIL: script or fixture missing"; exit 1; }

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/tmp"
scratch_install_closure bin/merged-build-closeout.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
# The jobs-DB seam: a fake bin/jobs-client.sh with the two ledger verbs over a
# TSV file (kind, key, status, detail). MBC_FX_LEDGER_DOWN=1 answers rc 1, an
# outage. The real client would reach the network.
mkdir -p "$T/h/bin/lib/jobs"; [ -e "$T/h/bin/lib/jobs/req.sh" ] || : > "$T/h/bin/lib/jobs/req.sh"
cat > "$T/h/bin/jobs-client.sh" <<'JC'
job_ledger_get() {
  [ "${MBC_FX_LEDGER_DOWN:-0}" = 1 ] && return 1
  awk -F'\t' -v k="$1" -v v="$2" '$1 == k && $2 == v { s = $3 } END { if (s == "") exit 2; print s }' "$MBC_FX_LEDGER"
}
job_ledger_put() {
  [ "${MBC_FX_LEDGER_DOWN:-0}" = 1 ] && return 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$MBC_FX_LEDGER"
}
JC
export MBC_FX_LEDGER="$T/ledger.tsv"; : > "$MBC_FX_LEDGER"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/h/env/global.env"
cat > "$T/h/fleet.conf" <<'FC'
project-6 example-org/project-6 - - 3 box-mk
lab       example-org/lab       - - 3 box-mk
boardy    example-org/boardy    https://boardy.example /api/board 1 box-mk
FC
ghfx_init
# Tripwire: no call leaves the box. curl records every call.
printf '#!/bin/bash\necho "$*" >> "%s/curl-calls"\nexit 7\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# A PATCH closes the issue for the re-read; a comment POST is recorded.
ghfx_extra <<'SH'
case "$A" in
  *"-X PATCH repos/"*"/issues/"*) n="${A#*-X PATCH repos/}"; n="${n%% *}"; touch "$GHFX/closed-${n//\//_}" ;;
esac
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0
SINCE=2026-10-17T00:00:00Z
OUT="$T/out.tsv"
mbc() { bash "$T/h/bin/merged-build-closeout.sh" "$@" > "$OUT" 2>"$T/err.txt"; }
verdict() { awk -F'\t' -v n="#$1" '$3 == n { v = $5 } END { print v }' "$OUT"; }
summary() { awk -F'\t' '$3 == "summary" { print $5 }' "$OUT"; }
n_method() { grep -c -- "-X $1 " "$T/gh-argv.log"; }

# load_fixture <slug> <tsv>: the issue list, the closed-PR list (page 1 is 100
# filler PRs, so every fixture PR is on page 2), each pull, its files and the
# issue timelines become routes.
load_fixture() {
  local S="$1" f="$2" iss="[]" prs="[]" fill
  while IFS=$'\t' read -r n it pn pt ref mat body files tl; do
    case "$n" in '#'*|'') continue ;; esac
    if [ "$n" != - ]; then
      iss=$(jq -c --argjson n "$n" --arg t "$it" '. + [{number:$n,title:$t,state:"open",labels:[{name:"ai-build"}]}]' <<<"$iss")
      # The issue reads open until a PATCH touched closed-<owner>_<repo>_issues_<n>.
      ghfx_route GET "repos/$S/issues/$n" 200 '{"state":"closed","labels":[{"name":"ai-build"}]}' "$T/closed-${S//\//_}_issues_$n"
      ghfx_route GET "repos/$S/issues/$n" 200 '{"state":"open","labels":[{"name":"ai-build"}]}'
      case "$tl" in
        broken)  ghfx_route GET "repos/$S/issues/$n/timeline*" 502 '{}' ;;
        child:*) ghfx_route GET "repos/$S/issues/$n/timeline*" 200 \
                   "$(jq -nc --argjson c "${tl#child:}" --arg b "Part of #$n" '[{event:"cross-referenced",source:{type:"issue",issue:{number:$c,state:"open",body:$b}}}]')" ;;
        *)       ghfx_route GET "repos/$S/issues/$n/timeline*" 200 '[]' ;;
      esac
      ghfx_route POST   "repos/$S/issues/$n/comments" 201 '{"id":1}'
      ghfx_route PATCH  "repos/$S/issues/$n" 200 '{"state":"closed"}'
      ghfx_route DELETE "repos/$S/issues/$n/labels/ai-build" 200 '[]'
    fi
    [ "$pn" = - ] && continue
    local pj
    pj=$(jq -nc --argjson n "$pn" --arg t "$pt" --arg r "$ref" --arg m "$mat" --arg b "$(printf '%b' "$body")" --arg s "$S" \
      '{number:$n,title:$t,head:{ref:$r},state:"closed",merged_at:(if $m == "-" then null else $m end),
        updated_at:"2026-10-20T07:00:00Z",body:$b,html_url:("https://github.com/" + $s + "/pull/" + ($n|tostring))}')
    prs=$(jq -c --argjson p "$pj" '. + [$p]' <<<"$prs")
    ghfx_route GET "repos/$S/pulls/$pn" 200 "$pj"
    if [ "$files" = docs ]; then
      ghfx_route GET "repos/$S/pulls/$pn/files*" 200 '[{"filename":"docs/x.md"},{"filename":"README.md"}]'
    else
      ghfx_route GET "repos/$S/pulls/$pn/files*" 200 '[{"filename":"bin/x.sh"},{"filename":"docs/x.md"}]'
    fi
  done < "$f"
  fill=$(jq -nc --arg s "$S" '[range(0;100) | {number:(9000+.),title:("ZZ-\(9000+.): filler"),head:{ref:"feature/filler"},
           state:"closed",merged_at:"2026-10-20T08:00:00Z",updated_at:"2026-10-20T08:00:00Z",
           html_url:("https://github.com/" + $s + "/pull/\(9000+.)")}]')
  ghfx_route GET "repos/$S/issues" 200 "$iss"
  ghfx_route GET "repos/$S/pulls?state=closed*&page=1" 200 "$fill"
  ghfx_route GET "repos/$S/pulls?state=closed*&page=2" 200 "$prs"
}
fresh() { # fresh: routes for both projects, empty logs, no ledger, all issues open
  ghfx_routes_reset; ghfx_log_reset; rm -f "$T"/closed-*; : > "$T/posted.txt"; : > "$T/curl-calls"
  : > "$MBC_FX_LEDGER"; unset MBC_FX_LEDGER_DOWN; : > "$T/h/logs/merged-build-closeout.log"
  load_fixture example-org/project-6 "$FX/project-6.tsv"
  load_fixture example-org/lab "$FX/lab.tsv"
}

# ── F1 + A1: project-6 dry run ────────────────────────────────────────────────
fresh
mbc --project project-6 --since "$SINCE"; RC=$?
[ "$RC" = 0 ] && ok || bad "F1: dry run exits 0 (rc $RC; $(cat "$T/err.txt"))"
[ "$(verdict 1364)" = close ] && ok || bad "F1: TK-1364 (#1936, Closes #1364) is close, got '$(verdict 1364)'"
[ "$(verdict 1741)" = close ] && ok || bad "F1: TK-1741 (#2004, Closes #1741) is close, got '$(verdict 1741)'"
for i in 1523 1525 1527 1531 1545 1559 1577 1580 1581 1686 1993; do
  [ "$(verdict "$i")" = keep:slice:no-keyword ] && ok || bad "F1: TK-$i (Part of + SLICE:) stays open, got '$(verdict "$i")'"
done
summary | grep -q '^checked 13, close 2, keep 11, skip 0, closed 0 (dry-run)$' && ok || bad "F1: summary is close 2, keep 11 (got '$(summary)')"
awk -F'\t' '$3 == "#1364" { print $4, $6 }' "$OUT" | grep -qx 'TK-1364 https://github.com/example-org/project-6/pull/1936' && ok \
  || bad "F1: the #1364 line names TK-1364 and #1936 ($(grep '#1364' "$OUT"))"
for m in POST PATCH DELETE; do [ "$(n_method "$m")" = 0 ] && ok || bad "A1: a dry run sends no $m ($(n_method "$m"))"; done
[ ! -s "$MBC_FX_LEDGER" ] && ok || bad "A1: a dry run writes no ledger row ($(cat "$MBC_FX_LEDGER"))"
[ "$(grep -c . "$T/h/logs/merged-build-closeout.log")" = 14 ] && ok || bad "A1: the log holds the 13 lines and the summary"

# ── L1: six TSV fields on every stdout line ───────────────────────────────────
[ "$(awk -F'\t' 'NF != 6' "$OUT" | wc -l)" = 0 ] && [ -s "$OUT" ] && ok || bad "L1: every line has 6 TSV fields: $(awk -F'\t' 'NF != 6' "$OUT" | head -2)"

# ── A2: apply, then apply again ───────────────────────────────────────────────
mbc --project project-6 --since "$SINCE" --apply; RC=$?
[ "$RC" = 0 ] && ok || bad "A2: apply exits 0 (rc $RC)"
[ "$(verdict 1364)" = closed ] && [ "$(verdict 1741)" = closed ] && ok || bad "A2: #1364 and #1741 are closed (got '$(verdict 1364)' '$(verdict 1741)')"
[ "$(grep -c -- '-X POST repos/example-org/project-6/issues/1364/comments' "$T/gh-argv.log")" = 1 ] \
  && [ "$(grep -c -- '-X POST repos/example-org/project-6/issues/1741/comments' "$T/gh-argv.log")" = 1 ] && ok \
  || bad "A2: one comment each on #1364 and #1741 ($(grep -- '-X POST' "$T/gh-argv.log"))"
[ "$(n_method POST)" = 2 ] && ok || bad "A2: no comment on any slice ticket ($(n_method POST) POSTs)"
grep -qE -- '-X PATCH repos/example-org/project-6/issues/(1523|1525|1527|1531|1545|1559|1577|1580|1581|1686|1993) ' "$T/gh-argv.log" \
  && bad "A2: a slice ticket was PATCHed" || ok
[ "$(grep -c ' CLOSED project-6 #' "$T/h/logs/merged-build-closeout.log")" = 2 ] && ok || bad "A2: two CLOSED audit lines"
grep -q 'CLOSED project-6 #1364 by https://github.com/example-org/project-6/pull/1936 (stripped)' "$T/h/logs/merged-build-closeout.log" && ok \
  || bad "A2: the audit line names the PR and the strip word ($(grep CLOSED "$T/h/logs/merged-build-closeout.log"))"
grep -q '^Merged in https://github.com/example-org/project-6/pull/1936, but the issue stayed open. Closing it now (BH-7731 backfill).$' "$T/posted.txt" && ok \
  || bad "A2: the comment text (posted: $(cat "$T/posted.txt"))"
grep -qxF "$(printf 'mbc-issue-commented\texample-org/project-6#1364@pr1936\tcommented\tpr=https://github.com/example-org/project-6/pull/1936')" "$MBC_FX_LEDGER" && ok \
  || bad "A2: the comment-once ledger row for #1364 (ledger: $(cat "$MBC_FX_LEDGER"))"
[ "$(grep -c '^mbc-issue-commented' "$MBC_FX_LEDGER")" = 2 ] && ok || bad "A2: one ledger row per comment ($(cat "$MBC_FX_LEDGER"))"
[ ! -e "$T/h/state/merged-build-closeout" ] && ok || bad "A2: no state/ dir is written"
summary | grep -q 'close 2, keep 11, skip 0, closed 2 (apply)$' && ok || bad "A2: summary (got '$(summary)')"
ghfx_log_reset
mbc --project project-6 --since "$SINCE" --apply
[ "$(n_method POST)" = 0 ] && [ "$(n_method PATCH)" = 0 ] && ok || bad "A2: a second apply posts and patches nothing ($(n_method POST) POST, $(n_method PATCH) PATCH)"
[ "$(verdict 1364)" = skip:already-closed ] && ok || bad "A2: a second apply says skip:already-closed (got '$(verdict 1364)')"

# ── A3: a PATCH that answers 403 is deferred, not counted closed ──────────────
fresh
sed -i '/^PATCH|repos\/example-org\/project-6\/issues\/1364|/s/|200|/|403|/' "$T/routes"
mbc --project project-6 --since "$SINCE" --apply
[ "$(verdict 1364)" = skip:close-deferred ] && ok || bad "A3: a 403 PATCH is skip:close-deferred (got '$(verdict 1364)')"
grep -q 'CLOSED project-6 #1364' "$T/h/logs/merged-build-closeout.log" && bad "A3: no CLOSED line for a refused close" || ok
summary | grep -q 'closed 1 (apply)$' && ok || bad "A3: only #1741 counts as closed (got '$(summary)')"

# ── A4: a comment-once row already there closes with no second comment ──────
fresh
printf 'mbc-issue-commented\texample-org/project-6#1364@pr1936\tcommented\t-\n' > "$MBC_FX_LEDGER"
mbc --project project-6 --since "$SINCE" --apply
[ "$(verdict 1364)" = closed ] && ok || bad "A4: #1364 still closes (got '$(verdict 1364)')"
[ "$(grep -c -- '-X POST repos/example-org/project-6/issues/1364/comments' "$T/gh-argv.log")" = 0 ] && ok \
  || bad "A4: no second comment on #1364 ($(grep -- '-X POST' "$T/gh-argv.log"))"
[ "$(grep -c -- '-X POST repos/example-org/project-6/issues/1741/comments' "$T/gh-argv.log")" = 1 ] && ok \
  || bad "A4: #1741 (no row) still gets its comment"

# ── A5: a ledger that cannot answer fails closed ─────────────────────────────
fresh
export MBC_FX_LEDGER_DOWN=1
mbc --project project-6 --since "$SINCE" --apply
[ "$(verdict 1364)" = skip:ledger-read ] && [ "$(verdict 1741)" = skip:ledger-read ] && ok \
  || bad "A5: an unreadable ledger is skip:ledger-read (got '$(verdict 1364)' '$(verdict 1741)')"
[ "$(n_method POST)" = 0 ] && [ "$(n_method PATCH)" = 0 ] && ok || bad "A5: no comment and no close ($(n_method POST) POST, $(n_method PATCH) PATCH)"
unset MBC_FX_LEDGER_DOWN

# ── M / D: the lab decision tables ────────────────────────────────────────────
fresh
mbc --project lab --since "$SINCE"
want() { # want <issue> <verdict> <case>
  [ "$(verdict "$1")" = "$2" ] && ok || bad "$3: #$1 must be $2, got '$(verdict "$1")'"
}
want 1364 close                          "M1/D1 title 'LB-1364: LB-1327.4: ...', Closes"
want 1741 close                          "M2/D2 title 'LB-1741: Drive 1/6', Fixes"
want 301  close                          "M3 lower-case title"
want 302  close                          "M4 head ticket/lb-302-r2, another title"
want 303  keep:no-pr                     "M5 'LB-303.2:' is a slice title"
want 304  keep:no-pr                     "M6 'LB-3040:' near miss"
want 305  keep:no-pr                     "M7 'LB-1/LB-305:' two keys"
want 306  keep:no-pr                     "M7 'LB-306, LB-307:' two keys"
want 308  keep:no-pr                     "M8 no leading key"
want 309  keep:no-pr                     "M9 closed, not merged"
want 310  keep:no-pr                     "M10 merged before --since"
want 311  close                          "M11 the newest of two merged PRs decides"
want 312  keep:slice:no-keyword          "D3 Part of + SLICE: C1"
want 313  keep:slice:no-keyword          "D5 a title with a Refs body"
want 314  keep:docs-only                 "D6 a docs-only PR"
want 315  keep:slice:no-keyword          "D7 Closes #3150 near miss"
want 316  keep:slice:open-children:#900  "D8 an open Part of child"
want 317  skip:timeline-read             "D9 an unreadable timeline"
want 319  skip:no-key                    "no key in the title and no launch line"
awk -F'\t' '$3 == "#311" { print $6 }' "$OUT" | grep -qx 'https://github.com/example-org/lab/pull/3013' && ok || bad "M11: #311 names the newer PR #3013"
grep -q -- '-X GET repos/example-org/lab/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=2' "$T/gh-argv.log" && ok \
  || bad "paging: a full page 1 reads page 2"

# ── X1: exit codes ────────────────────────────────────────────────────────────
bash "$T/h/bin/merged-build-closeout.sh" --bogus >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "X1: a bad flag exits 2 (rc $RC)"
bash "$T/h/bin/merged-build-closeout.sh" --since yesterday >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "X1: a bad --since exits 2 (rc $RC)"
bash "$T/h/bin/merged-build-closeout.sh" --project boardy >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "X1: a board project exits 2 (rc $RC)"
ghfx_routes_reset
ghfx_route GET "repos/example-org/project-6/issues" 502 '{}'
ghfx_route GET "repos/example-org/lab/issues" 502 '{}'
mbc --since "$SINCE"; RC=$?
[ "$RC" = 1 ] && ok || bad "X1: every list read failing exits 1 (rc $RC)"
grep -q $'\tproject-6\t-\t-\tskip:issue-list-read\t-' "$OUT" && ok || bad "X1: the failed read is said ($(cat "$OUT"))"
grep -q boardy "$OUT" && bad "X1: a board project is never read" || ok

# ── K1: the PR page cap is a settings row, not a literal (lead review lr-7750) ─
# Page 1 of every fixture is 100 filler PRs, so the fixture PRs sit on page 2.
# A row lib.merged-build-closeout.mbc_pr_page_cap = 1 stops the read after page
# 1: every issue is skip:capped and page 2 is never read. With the row gone the
# fallback 10 reads page 2 again (F1 above is the same run with no row).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: K1 cannot render the lane registry"; exit 1; }
[ "$(jq -r '[.libs[] | select(.id == "merged-build-closeout") | .knobs[].env] | sort | join(" ")' "$T/lanes.json")" \
  = "MBC_FILES_PAGE_CAP MBC_ISSUE_CAP MBC_PR_PAGE_CAP MBC_SINCE_DAYS" ] && ok \
  || bad "K1: the registry declares the four merged-build-closeout knobs"
kcache() { jq -n --argjson fa "$(date +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/h/state/settings-cache.json"; }
fresh
kcache '{"lib.merged-build-closeout.mbc_pr_page_cap":"1"}'
LANE_REGISTRY="$T/lanes.json" mbc --project project-6 --since "$SINCE"; RC=$?
[ "$RC" = 0 ] && ok || bad "K1: a capped dry run exits 0 (rc $RC; $(cat "$T/err.txt"))"
[ "$(verdict 1364)" = skip:capped ] && [ "$(verdict 1993)" = skip:capped ] && ok \
  || bad "K1: row mbc_pr_page_cap=1 makes every issue skip:capped (got '$(verdict 1364)' '$(verdict 1993)')"
grep -q -- 'pulls?state=closed&sort=updated&direction=desc&per_page=100&page=2' "$T/gh-argv.log" \
  && bad "K1: row mbc_pr_page_cap=1 still read page 2" || ok
summary | grep -q '^checked 13, close 0, keep 0, skip 13, closed 0 (dry-run)$' && ok || bad "K1: summary is skip 13 (got '$(summary)')"
fresh
kcache '{}'
LANE_REGISTRY="$T/lanes.json" mbc --project project-6 --since "$SINCE"
[ "$(verdict 1364)" = close ] && ok || bad "K1: with no row the fallback 10 reads page 2 and #1364 is close (got '$(verdict 1364)')"
fresh
LANE_REGISTRY="$T/lanes.json" MBC_PR_PAGE_CAP=junk mbc --project project-6 --since "$SINCE"
[ "$(verdict 1364)" = close ] && ok || bad "K1: a non-number reads the fallback 10 (got '$(verdict 1364)')"
rm -f "$T/h/state/settings-cache.json"

[ ! -s "$T/curl-calls" ] && ok || bad "budget: curl was called ($(head -3 "$T/curl-calls"))"

echo "merged-build-closeout (BH-7731): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

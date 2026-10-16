#!/bin/bash
# tests/group-findings.bh-6902-test.sh — BH-6902: a QA run collects its
# findings first, then files ONE issue per screen or flow.
#
# Drives the real "$DIR/bin/lib/group-findings.sh" (installed with its source
# closure into a scratch harness) against a fake GitHub (tests/lib/gh-rest-fx.sh)
# and the real lane registry, so the on/off knob is a real settings row.
#
#   T1  10 findings on 2 screens -> 2 issues, each with its full checklist
#   T2  an open issue with the group marker -> 1 comment, 0 new issues
#   T3  the matched issue's PR is approved on its head -> a follow-up issue,
#       Blocked-by that PR, and no new scope on the approved one
#   T4  a high data-leak finding is filed at once AND stays in the group
#   E1-E9, B1, R1, K1, C1 (the qa-drive converter), P1 (the prompt sentence)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/group-findings.bh-6902-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "group-findings.bh-6902: jq is required"; exit 1; }

LIB="$DIR/bin/lib/group-findings.sh"
FIX="$DIR/tests/fixtures/bh-6902"
SLUG=example-org/demo
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/tmp"
if ! scratch_install_closure bin/lib/group-findings.sh "$H" >/dev/null; then
  echo "FAIL: cannot install the closure of $LIB"; echo "group-findings.bh-6902: 0 passed, 1 failed"; exit 1
fi
REG=$(rendered_registry)
ghfx_init
export HARNESS="$H" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" LANE_REGISTRY="$REG" \
       LANE_GATE_NOW=2000000000 GH_ETAG=0
unset GROUP_FINDINGS GROUP_FINDINGS_URGENT_RANK LANE_GATE_DISABLE
# shellcheck source=bin/lib/group-findings.sh
. "$H/bin/lib/group-findings.sh" || { echo "FAIL: cannot source the lib"; exit 1; }

# Every POST is answered here, so issue numbers count up (101, 102, ...) and a
# copy of each body is kept: the temp file the lib posts from is gone after.
ghfx_extra <<'SH'
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  n=$(( $(cat "$GHFX/post.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHFX/post.n"
  mkdir -p "$GHFX/posts"; printf '%s\n' "$5" > "$GHFX/posts/$n.path"
  for a in "$@"; do
    case "$a" in
      title=*) printf '%s\n' "${a#title=}" > "$GHFX/posts/$n.title" ;;
      body=@*) cp "${a#body=@}" "$GHFX/posts/$n.body" ;;
    esac
  done
  case "$5" in
    */comments) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":%s,"html_url":"https://github.com/fixture/issues/1#issuecomment-%s"}' "$n" "$n" ;;
    *) if [ -e "$GHFX/post.nonumber" ]; then printf 'HTTP/1.1 201 Created\r\n\r\n{}'
       else printf 'HTTP/1.1 201 Created\r\n\r\n{"number":%s,"html_url":"https://github.com/fixture/issues/%s"}' $((100+n)) $((100+n)); fi ;;
  esac
  exit 0
fi
SH

knob() { # knob [board...] — a FRESH settings cache with grouping on for these boards
  local v='{}' b
  for b in "$@"; do v=$(jq -c --arg k "lib.group-findings.$b.group_findings" '. + {($k): "1"}' <<<"$v"); done
  scratch_rm "$H/state/lane-gate"
  jq -nc --argjson v "$v" '{fetched_at:2000000000, values:$v, seeded:{}}' > "$H/state/settings-cache.json"
}
fnd() { # fnd <key> <severity> <title> [class] [files-csv] [board]
  jq -nc --arg b "${6:-project-3}" --arg k "$1" --arg s "$2" --arg t "$3" --arg c "${4:-}" --arg f "${5:-}" \
    '{board:$b, screen_or_flow:$k, severity:$s, title:$t,
      repro:("Open " + $k + " as the QA user."), cause:("fixture cause: " + $t)}
     + (if $c != "" then {class:$c} else {} end)
     + (if $f != "" then {files:($f | split(","))} else {} end)'
}
iss() { # iss <number> <body> [state] — one REST issue object
  jq -nc --argjson n "$1" --arg b "$2" --arg s "${3:-open}" '{number:$n, state:$s, title:"fixture issue", body:$b}'
}
mk() { printf '<!-- findings-group: project-3|%s -->' "$1"; }
new_run() { # new_run <name> — a fresh run dir, no routes, no posts
  RD="$T/runs/$1"; mkdir -p "$RD"; : > "$RD/in.jsonl"
  ghfx_routes_reset; ghfx_log_reset
  scratch_rm "$T/posts"; rm -f "$T/post.n" "$T/post.nonumber"
}
issues() { ghfx_route GET "repos/$SLUG/issues" "${2:-200}" "$1"; }
gfrun() { # gfrun [--dry-run] — sets RC; output in $RD/out.txt
  ( gf_run "$RD/in.jsonl" "$RD" "$SLUG" "$@" ) > "$RD/out.txt" 2>&1; RC=$?
}
nposts() { # nposts <path-glob> — POSTs whose path matches
  local f n=0
  for f in "$T"/posts/*.path; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) n=$((n+1)) ;; esac
  done
  echo "$n"
}
post_body() { # post_body <path-glob> [nth] — the body of the nth POST to that path
  local f k=0
  for f in $(ls "$T"/posts/*.path 2>/dev/null | sort -V); do
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) k=$((k+1)); [ "$k" = "${2:-1}" ] && { cat "${f%.path}.body"; return 0; } ;; esac
  done
}
rows() { jq -s --arg a "$1" '[.[] | select(.action == $a)] | length' "$RD/findings-ledger.jsonl" 2>/dev/null || echo -1; }
last_rows() { # last_rows <action> — findings whose LAST ledger row has this action
  jq -s --arg a "$1" 'group_by(.fp) | map(select(.[0].fp != null) | last) | [.[] | select(.action == $a)] | length' \
    "$RD/findings-ledger.jsonl" 2>/dev/null || echo -1
}
items() { grep -c '^- \[ \] ' <<<"$1"; }

# --- T1: 10 findings on 2 screens -> 2 issues ------------------------------------
new_run t1; knob project-3; issues '[]'
for i in 1 2 3; do fnd "/clients@1280" medium "Console error $i" >> "$RD/in.jsonl"; done
for i in 1 2 3; do fnd "/clients@375" low "Overflow $i" >> "$RD/in.jsonl"; done
for i in 1 2 3 4; do fnd "flow:rep/new-quote" high "Step $i failed" >> "$RD/in.jsonl"; done
gfrun
[ "$RC" = 0 ] && ok || bad "T1: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 2 ] && ok || bad "T1: want exactly 2 issue POSTs, got $(nposts "repos/$SLUG/issues")"
[ "$(nposts '*/comments')" = 0 ] && ok || bad "T1: no comment expected"
B1=$(post_body "repos/$SLUG/issues" 1); B2=$(post_body "repos/$SLUG/issues" 2)
grep -qF "$(mk /clients)" <<<"$B1" && ok || bad "T1: issue 1 lacks the /clients marker: $B1"
[ "$(items "$B1")" = 6 ] && ok || bad "T1: issue 1 must carry 6 checklist items, got $(items "$B1")"
grep -qF "$(mk flow:rep/new-quote)" <<<"$B2" && ok || bad "T1: issue 2 lacks the flow marker: $B2"
[ "$(items "$B2")" = 4 ] && ok || bad "T1: issue 2 must carry 4 checklist items, got $(items "$B2")"
grep -q 'Repro: Open /clients@375' <<<"$B1" && ok || bad "T1: the checklist must carry each repro"
grep -q 'Cause: fixture cause: Overflow 2' <<<"$B1" && ok || bad "T1: the checklist must carry each cause"
grep -q '^QA findings: /clients (6 items)$' "$T/posts/1.title" && ok || bad "T1: title 1: $(cat "$T/posts/1.title")"
[ "$(last_rows filed)" = 10 ] && ok || bad "T1: all 10 ledger findings must end filed, got $(last_rows filed)"
[ "$(rows pending)" = 10 ] && ok || bad "T1: the ledger must record 10 pending rows before any filing"
[ "$(jq -s '[.[] | select(.action == "filed") | .issue] | unique' "$RD/findings-ledger.jsonl" | jq -c .)" = '[101,102]' ] \
  && ok || bad "T1: filed rows must carry the POSTed numbers 101 and 102"
grep -q '^group-findings: 10 findings, 2 groups, filed 2, commented 0, followup 0, urgent 0, deferred 0, failed 0' "$RD/group-findings.md" \
  && ok || bad "T1: totals line: $(tail -1 "$RD/group-findings.md" 2>/dev/null)"
case "$RD/findings-ledger.jsonl" in "$RD"/*) ok ;; *) bad "T1: the ledger must live in the run dir" ;; esac

# --- R1: a second run on the same run dir posts nothing --------------------------
before=$(grep -c '' "$RD/findings-ledger.jsonl")
ghfx_log_reset; scratch_rm "$T/posts"
gfrun
[ "$RC" = 0 ] && ok || bad "R1: rc=$RC"
[ "$(nposts '*')" = 0 ] && ok || bad "R1: a rerun must make 0 POSTs, got $(nposts '*')"
[ "$(last_rows filed)" = 10 ] && ok || bad "R1: the terminal rows must be unchanged"
[ "$(rows pending)" = 10 ] && ok || bad "R1: a rerun must not add pending rows again"
[ "$(grep -c '' "$RD/findings-ledger.jsonl")" -ge "$before" ] && ok || bad "R1: the ledger shrank"

# --- T2: an open issue with the marker gets a comment ---------------------------
new_run t2; knob project-3
issues "[$(iss 50 "$(mk /clients)
old checklist")]"
ghfx_route GET "repos/$SLUG/pulls" 200 '[]'
ghfx_route GET "repos/$SLUG/issues/50/comments" 200 '[]'
for i in 1 2 3; do fnd "/clients" medium "New thing $i" >> "$RD/in.jsonl"; done
gfrun
[ "$RC" = 0 ] && ok || bad "T2: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 1 ] && ok || bad "T2: want 1 comment on #50"
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "T2: no new issue expected"
C=$(post_body "repos/$SLUG/issues/50/comments")
[ "$(items "$C")" = 3 ] && ok || bad "T2: the comment must carry 3 items, got $(items "$C"): $C"
grep -q 'findings-run: t2' <<<"$C" && ok || bad "T2: the comment must carry the run marker"
[ "$(last_rows commented)" = 3 ] && ok || bad "T2: 3 ledger rows must end commented"

# --- T3: the matched issue's PR is approved on its head -> follow-up -------------
t3_setup() { # t3_setup <reviews-status> <reviews-body> [pr-comments-body]
  issues "[$(iss 50 "$(mk /clients)")]"
  ghfx_route GET "repos/$SLUG/pulls" 200 '[{"number":51,"state":"open","body":"Closes #50","head":{"sha":"abc1234def5678abc1234def5678abc1234def56","ref":"ticket/project-3-x"}}]'
  ghfx_route GET "repos/$SLUG/pulls/51/reviews" "$1" "$2"
  ghfx_route GET "repos/$SLUG/issues/51/comments" 200 "${3:-[]}"
  ghfx_route GET "repos/$SLUG/issues/50/comments" 200 '[]'
}
new_run t3; knob project-3
t3_setup 200 '[{"state":"APPROVED","commit_id":"abc1234def5678abc1234def5678abc1234def56","user":{"login":"operator"}}]'
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 0 ] && ok || bad "T3: an approved PR's issue must get no new scope"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "T3: want 1 follow-up issue, got $(nposts "repos/$SLUG/issues")"
F=$(post_body "repos/$SLUG/issues")
grep -q '^Blocked-by: #51$' <<<"$F" && ok || bad "T3: the follow-up must say Blocked-by: #51: $F"
grep -qF 'findings-followup-of: #50' <<<"$F" && ok || bad "T3: the follow-up must name #50"
grep -qF "$(mk /clients)" <<<"$F" && ok || bad "T3: the follow-up keeps the group marker"
[ "$(last_rows followup)" = 1 ] && ok || bad "T3: the ledger row must end followup"

# E4: approved on an OLDER sha -> scope comment
new_run e4; knob project-3
t3_setup 200 '[{"state":"APPROVED","commit_id":"0000000aaaaaaa","user":{"login":"operator"}}]'
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 1 ] && ok || bad "E4: an approval on an old sha must not block scope"
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "E4: no follow-up on an old-sha approval"

# E5: the reviews read answers 500 -> fail closed, follow-up
new_run e5; knob project-3
t3_setup 500 '{"message":"boom"}'
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 0 ] && ok || bad "E5: an unreadable review state must not add scope"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E5: an unreadable review state files a follow-up"

# E5d: a reviews list at its 300-row cap is not the whole list -> fail closed
new_run e5d; knob project-3
t3_setup 200 "$(jq -nc '[range(0;100) | {state:"COMMENTED", commit_id:"0000000aaaaaaa", user:{login:"x"}}]')"
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 0 ] && ok || bad "E5d: a capped reviews list must not add scope"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E5d: a capped reviews list files a follow-up"

# A bot APPROVE comment that names the head counts; a human's does not.
new_run e5b; knob project-3
t3_setup 200 '[]' '[{"body":"VERDICT: APPROVE\nhead abc1234def56","user":{"login":"harness-app[bot]"}}]'
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E5b: a bot APPROVE on the head must count as approved"
new_run e5c; knob project-3
t3_setup 200 '[]' '[{"body":"VERDICT: APPROVE\nhead abc1234def56","user":{"login":"some-person"}}]'
fnd "/clients" medium "Late finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 1 ] && ok || bad "E5c: a human APPROVE comment is not a machine approval"

# --- T4: urgent first, still in the group -------------------------------------------
new_run t4; knob project-3; issues '[]'
fnd "/clients" medium "Slow table" >> "$RD/in.jsonl"
fnd "/clients" high "Other client rows visible" data-leak >> "$RD/in.jsonl"
fnd "/clients" medium "Wrong sort" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 0 ] && ok || bad "T4: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 2 ] && ok || bad "T4: want 2 issues (urgent + group), got $(nposts "repos/$SLUG/issues")"
U=$(post_body "repos/$SLUG/issues" 1); G=$(post_body "repos/$SLUG/issues" 2)
grep -q 'findings-urgent:' <<<"$U" && ok || bad "T4: the FIRST issue must be the urgent one: $U"
[ "$(items "$G")" = 3 ] && ok || bad "T4: the group issue must keep all 3 items, got $(items "$G")"
grep -q '^- \[ \] high Other client rows visible (filed at once as #101)$' <<<"$G" \
  && ok || bad "T4: the urgent item must name its own issue in the group: $G"
[ "$(rows urgent)" = 1 ] && ok || bad "T4: one ledger row urgent"
grep -q 'urgent 1,' "$RD/group-findings.md" && ok || bad "T4: totals must count the urgent filing"

# E6: high with no class, medium data-leak, high + unknown class -> no urgent issue
new_run e6; knob project-3; issues '[]'
fnd "/clients" high "Plain high" >> "$RD/in.jsonl"
fnd "/clients" medium "Medium leak" data-leak >> "$RD/in.jsonl"
fnd "/clients" high "Cosmetic high" cosmetic >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E6: only the group issue may be filed, got $(nposts "repos/$SLUG/issues")"
[ "$(rows urgent)" = 0 ] && ok || bad "E6: no finding is urgent here"
# ...and critical + launch-blocker is urgent
new_run e6b; knob project-3; issues '[]'
fnd "flow:rep/checkout" critical "Checkout dead" launch-blocker >> "$RD/in.jsonl"
gfrun
[ "$(rows urgent)" = 1 ] && ok || bad "E6b: critical + launch-blocker must be urgent"

# --- E1/E2/E3: what is NOT a match -----------------------------------------------------
new_run e1; knob project-3
issues "[$(iss 50 "$(mk /clients)" closed)]"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E1: a closed issue with the marker is not a match"
new_run e2; knob project-3
issues "[$(iss 50 "no marker in the body")]"
ghfx_route GET "repos/$SLUG/issues/50/comments" 200 "[{\"body\":\"$(mk /clients)\",\"user\":{\"login\":\"x\"}}]"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E2: a marker in a comment only is not a match"
new_run e3; knob project-3
issues "[$(iss 50 "$(mk /clients/123)"), $(iss 51 '<!-- findings-group: other-board|/clients -->')]"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E3: /clients/123 or another board's marker is not a match"
# two open matches: the lowest number wins, the other is untouched
new_run e3b; knob project-3
issues "[$(iss 70 "$(mk /clients)"), $(iss 60 "$(mk /clients)")]"
ghfx_route GET "repos/$SLUG/pulls" 200 '[]'
ghfx_route GET "repos/$SLUG/issues/60/comments" 200 '[]'
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts "repos/$SLUG/issues/60/comments")" = 1 ] && ok || bad "E3b: the lowest open match (#60) must get the comment"
[ "$(nposts "repos/$SLUG/issues/70/comments")" = 0 ] && ok || bad "E3b: #70 must not be touched"

# --- E7: an issue list at the cap, or rate limited -> nothing filed --------------------
new_run e7; knob project-3
page=$(jq -nc '[range(0;100) | {number:(1000+.), state:"open", title:"t", body:"b"}]')
issues "$page"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; fnd "/reports" low "Y" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 75 ] && ok || bad "E7: a capped issue list must answer rc 75, got $RC"
[ "$(nposts '*')" = 0 ] && ok || bad "E7: a capped issue list must make no write"
[ "$(last_rows deferred)" = 2 ] && ok || bad "E7: every row must end deferred"
new_run e7b; knob project-3
issues '{"message":"API rate limit exceeded"}' 403
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$RC" = 75 ] && ok || bad "E7b: a rate-limited list must answer rc 75, got $RC"
[ "$(nposts '*')" = 0 ] && ok || bad "E7b: a rate-limited list must make no write"

# --- E8: a POST that answers no number is a failure, never a success -------------------
new_run e8; knob project-3; issues '[]'; touch "$T/post.nonumber"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$RC" = 1 ] && ok || bad "E8: a POST with no number must answer rc 1, got $RC"
[ "$(last_rows failed)" = 1 ] && ok || bad "E8: the row must end failed"
[ "$(last_rows filed)" = 0 ] && ok || bad "E8: no filed row without a number"
jq -se '[.[] | select(.action == "failed")][0].http == "201"' "$RD/findings-ledger.jsonl" >/dev/null \
  && ok || bad "E8: the failed row must carry http=201"
grep -q 'filed 0,.* failed 1' "$RD/group-findings.md" && ok || bad "E8: totals: $(tail -1 "$RD/group-findings.md")"
# ...and the rerun retries exactly that group
rm -f "$T/post.nonumber"; scratch_rm "$T/posts"; rm -f "$T/post.n"; gfrun
[ "$RC" = 0 ] && [ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E8: a rerun must retry the failed group (rc=$RC)"

# --- E9: knob off -> no GitHub call, rows off -------------------------------------------
new_run e9; knob; issues '[]'
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$RC" = 0 ] && ok || bad "E9: knob off must answer rc 0, got $RC"
[ ! -s "$T/gh-argv.log" ] && ok || bad "E9: knob off must make 0 GitHub calls: $(cat "$T/gh-argv.log")"
[ "$(last_rows off)" = 1 ] && ok || bad "E9: the row must end off"
# the knob is per board: on for project-3 only, a project-4 finding stays off
new_run e9b; knob project-3; issues '[]'
fnd "/clients" medium "X" >> "$RD/in.jsonl"; fnd "/clients" medium "Y" "" "" project-4 >> "$RD/in.jsonl"; gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "E9b: only the board with the knob on files"
[ "$(last_rows off)" = 1 ] && ok || bad "E9b: the other board's row must end off"

# --- B1: two groups on one file -> the second is Blocked-by the first ------------------
new_run b1; knob project-3; issues '[]'
fnd "/a" medium "A1" "" "bin/x.sh" >> "$RD/in.jsonl"
fnd "/b" medium "B1" "" "bin/y.sh,bin/x.sh" >> "$RD/in.jsonl"
fnd "/c" medium "C1" "" "bin/z.sh" >> "$RD/in.jsonl"
gfrun
BB=$(post_body "repos/$SLUG/issues" 2); BC=$(post_body "repos/$SLUG/issues" 3)
grep -q '^Blocked-by: #101$' <<<"$BB" && ok || bad "B1: group /b must be Blocked-by #101: $BB"
grep -q 'Blocked-by' <<<"$BC" && bad "B1: group /c shares no file and must not be blocked" || ok

# --- idempotency across a lost ledger row: our own issue is recognised -----------------
new_run own; knob project-3
issues "[$(iss 90 "$(mk /clients)
<!-- findings-run: own -->")]"
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts '*')" = 0 ] && ok || bad "OWN: an issue this run already filed must not get a comment"
[ "$(last_rows filed)" = 1 ] && ok || bad "OWN: it is recorded filed"
# ...and a comment this run already posted is not posted twice
new_run own2; knob project-3
issues "[$(iss 50 "$(mk /clients)")]"
ghfx_route GET "repos/$SLUG/pulls" 200 '[]'
ghfx_route GET "repos/$SLUG/issues/50/comments" 200 '[{"body":"<!-- findings-run: own2 -->\n- [ ] medium X","user":{"login":"x[bot]"}}]'
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun
[ "$(nposts '*')" = 0 ] && ok || bad "OWN2: a comment carrying this run's marker must not be posted again"
[ "$(last_rows commented)" = 1 ] && ok || bad "OWN2: it is recorded commented"

# --- edge cases: empty input, malformed line, unknown severity, dry run ----------------
new_run empty; knob project-3; gfrun
[ "$RC" = 0 ] && ok || bad "EMPTY: rc=$RC"
[ ! -s "$T/gh-argv.log" ] && ok || bad "EMPTY: an empty run must make no GitHub call"
grep -q '^group-findings: 0 findings, 0 groups, filed 0' "$RD/group-findings.md" && ok || bad "EMPTY: zero totals line"
new_run bad; knob project-3; issues '[]'
{ echo '{not json'; fnd "/clients" severe "Odd severity"; fnd "  " medium "No key"; } >> "$RD/in.jsonl"; gfrun
[ "$(rows invalid)" = 2 ] && ok || bad "BAD: a malformed line and a keyless finding must each leave an invalid row, got $(rows invalid)"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "BAD: the valid line must still be filed"
jq -se '[.[] | select(.severity_coerced == true)] | length >= 1' "$RD/findings-ledger.jsonl" >/dev/null \
  && ok || bad "BAD: an unknown severity must be coerced and say so"
grep -q '^- \[ \] medium Odd severity$' <<<"$(post_body "repos/$SLUG/issues")" && ok || bad "BAD: the coerced severity is medium"
new_run dry; knob project-3; issues '[]'
fnd "/clients" medium "X" >> "$RD/in.jsonl"; gfrun --dry-run
[ "$(nposts '*')" = 0 ] && ok || bad "DRY: a dry run must not POST"
[ "$(last_rows would_file)" = 1 ] && ok || bad "DRY: the row must end would_file"

# --- K1: one key normaliser ---------------------------------------------------------------
for k in "/clients@375" "/Clients/" "/clients?x=1" " /clients@1280 " "/clients/?tab=2"; do
  [ "$(gf_key "$k")" = /clients ] && ok || bad "K1: gf_key '$k' -> '$(gf_key "$k")', want /clients"
done
[ "$(gf_key /clients/123)" = /clients/123 ] && ok || bad "K1: /clients/123 must stay its own key"
[ "$(gf_key 'flow:Rep/New-Quote')" = flow:rep/new-quote ] && ok || bad "K1: flow keys keep the prefix, lower-cased"
[ "$(gf_key /)" = / ] && ok || bad "K1: the root stays /"

# --- C1: the qa-drive converter -----------------------------------------------------------
gf_from_observed project-3 "$FIX/observed-fail.json" > "$T/conv.jsonl"; CRC=$?
[ "$CRC" = 0 ] && ok || bad "C1: rc=$CRC"
[ "$(grep -c '' "$T/conv.jsonl")" = 8 ] && ok || bad "C1: want 8 findings, got $(grep -c '' "$T/conv.jsonl")"
jq -se 'all(.[]; .board == "project-3")' "$T/conv.jsonl" >/dev/null && ok || bad "C1: every finding carries the board"
jq -se '[.[] | select(.screen_or_flow == "/settings")] | length == 1' "$T/conv.jsonl" >/dev/null \
  && ok || bad "C1: the sign-in wall is not an app finding (only the 404 is)"
jq -se '[.[] | select(.screen_or_flow == "flow:rep/new-quote" and .severity == "high")] | length == 1' "$T/conv.jsonl" >/dev/null \
  && ok || bad "C1: the failed flow is one high finding"
jq -se '[.[] | select(.screen_or_flow | startswith("flow:rep/browse") or startswith("flow:admin"))] | length == 0' "$T/conv.jsonl" >/dev/null \
  && ok || bad "C1: pass and skipped flows are not findings"
jq -se '[.[] | select(.screen_or_flow == "/reports" and .severity == "high")] | length == 2' "$T/conv.jsonl" >/dev/null \
  && ok || bad "C1: HTTP 500 and a page error are high"
jq -se '[.[] | select(.title | test("Horizontal body scroll")) | .severity] == ["low"]' "$T/conv.jsonl" >/dev/null \
  && ok || bad "C1: the 375 scroll is low"
jq -se 'all(.[]; has("class") | not)' "$T/conv.jsonl" >/dev/null && ok || bad "C1: a drive sets no class"
# Cross-check against the drive's OWN verdict function: every screenFailures line
# but the sign-in wall becomes exactly one finding.
if command -v node >/dev/null 2>&1; then
  NSF=$(node --input-type=module -e "
    import { screenFailures } from '$DIR/bin/qa-drive.mjs';
    import { readFileSync } from 'fs';
    const o = JSON.parse(readFileSync('$FIX/observed-fail.json', 'utf8'));
    console.log(o.screens.flatMap(screenFailures).filter((l) => !l.includes('sign-in wall')).length);" 2>&1)
  NCONV=$(jq -s '[.[] | select(.screen_or_flow | startswith("flow:") | not)] | length' "$T/conv.jsonl")
  [ "$NSF" = "$NCONV" ] && ok || bad "C1: screenFailures says $NSF screen findings, the converter made $NCONV"
fi
echo '{not json' > "$T/broken.json"
gf_from_observed project-3 "$T/broken.json" > /dev/null 2>"$T/conv.err"; CRC=$?
[ "$CRC" != 0 ] && ok || bad "C1: an unreadable observed.json must not read as zero findings"

# --- P1: the prompt sentence ----------------------------------------------------------------
want="bin/lib/rb/plan.sh:1 bin/lib/rb/execute.sh:1 bin/lib/rb/review.sh:3 bin/lib/rb/result.sh:1 bin/lib/rb/pr.sh:1 bin/run-preplan.sh:1 bin/review-prs.sh:1"
for w in $want; do
  f="${w%%:*}"; n="${w##*:}"
  got=$(grep -c 'FOLLOW-UPS ARE GROUPED' "$DIR/$f")
  [ "$got" = "$n" ] && ok || bad "P1: $f carries the sentence $got time(s), want $n"
  bash -n "$DIR/$f" && ok || bad "P1: $f does not parse"
done

echo "group-findings.bh-6902: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

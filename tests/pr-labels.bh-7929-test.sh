#!/bin/bash
# tests/pr-labels.bh-7929-test.sh — BH-7929: a ticket body line
# `PR-Labels: <label>[, <label>]` labels the PR the builder opens for it.
#
# WHY. project-6's E2E-debt tickets need `full-ci` on their PR's first CI run.
# Two rebuilds (project-6 #2229, #2235) opened without it, ran only the 1-shard
# impact set, and a person added the label by hand.
#
#   P1  `PR-Labels: full-ci`, label exists      -> one POST labels[]=full-ci, `labelled`
#   P2  no PR-Labels line                       -> 0 GET, 0 POST, empty log
#   P3  `full-ci, nope`, nope unknown           -> POST only full-ci, ONE skip line for 'nope'
#   P4  every label unknown                     -> 0 POST, one skip line per label, rc 0
#   P5  the POST fails                          -> `could NOT label`, no `labelled`, rc 0
#   P6  label read gives no HTTP status         -> `could not read`, not posted
#   P7  parser near misses                      -> no POST
#   P8  parser hits (bullet, backtick, case, spaces, dedupe, cap 10)
#   P9  meta missing or not JSON                -> rc 0, no POST, no log line
#   P10 the bin/lib/rb/pr.sh block calls prl_apply only when PR_URL is set
#   P11 ppr_reap_landed (bin/lib/pool-push-rejected.sh) labels the PR it opens
#
# A stub `gh` answers label reads from $T/known and $T/broken and records every
# call: 0 network calls. Each case writes its own meta file under $T/<case>/.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-labels.bh-7929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/rb-pr-labels.sh" ] || bad "setup: bin/lib/rb-pr-labels.sh is missing"   # impact: bin/lib/rb-pr-labels.sh bin/lib/rb/pr.sh bin/lib/pool-push-rejected.sh

export HARNESS="$T/h"
mkdir -p "$T/h/bin" "$T/fakebin"
scratch_install_closure bin/lib/rb-pr-labels.sh "$T/h" >/dev/null || bad "setup: the lib's closure did not install"
scratch_install_closure bin/lib/pool-push-rejected.sh "$T/h" >/dev/null || bad "setup: pool-push-rejected's closure did not install"

# The stub gh. `api -i repos/<slug>/labels/<enc>`: 200 when the decoded name is
# a line of $T/known, a body with no status line when it is in $T/broken, else
# 404. `api -X POST .../labels`: recorded to $T/posts.txt, exit 1 if $T/post.fail.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.txt"
case "\$*" in
  *"-X POST repos/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/posts.txt"; [ -e "$T/post.fail" ] && exit 1; echo '[]'; exit 0 ;;
  "api -i repos/"*"/labels/"*)
    enc="\${3##*/labels/}"; name=\$(printf '%b' "\${enc//%/\\\\x}")
    if grep -qxF -- "\$name" "$T/broken" 2>/dev/null; then echo '{}'; exit 1; fi
    if grep -qxF -- "\$name" "$T/known" 2>/dev/null; then
      printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"name":"x"}\n'; exit 0
    fi
    printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
[ -r "$T/h/bin/lib/rb-pr-labels.sh" ] && . "$T/h/bin/lib/rb-pr-labels.sh"
URL=https://github.com/example-org/project-6/pull/2235
LOG="$T/pipeline.log"
printf 'full-ci\nneeds review\nbug\n' > "$T/known"
: > "$T/broken"

# meta <case> <body> — a ticket-meta.json in the {title,labels,body} shape
# TICKET_META writes for a GitHub issue (bin/lib/rb/plan.sh).
meta() { mkdir -p "$T/$1"; jq -n --arg b "$2" '{title:"E2E debt",labels:[{name:"ai-build"}],body:$b}' > "$T/$1/meta.json"; }
reset() { : > "$T/posts.txt"; : > "$T/calls.txt"; : > "$LOG"; rm -f "$T/post.fail"; }
apply() { local rc=0; prl_apply project-6-os "$URL" "$T/$1/meta.json" "$LOG" || rc=$?; echo "$rc" > "$T/rc"; }
P="POST repos/example-org/project-6/issues/2235/labels"

# P1 — the ticket's own line.
reset; meta p1 $'## Problem\nE2E debt.\n\nPR-Labels: full-ci\n'; apply p1
[ "$(grep -c -- "$P -f labels\[\]=full-ci\$" "$T/posts.txt")" = 1 ] && [ "$(wc -l < "$T/posts.txt")" = 1 ] \
  && ok || bad "P1: one POST with labels[]=full-ci (posts: $(cat "$T/posts.txt"))"
grep -q "pr labels: labelled $URL 'full-ci' from the ticket's PR-Labels line" "$LOG" && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "P1: a labelled line (log: $(cat "$LOG"))"
# A rebuild runs the same block on the same ticket: the same POST again.
reset; apply p1
[ "$(grep -c -- "$P -f labels\[\]=full-ci\$" "$T/posts.txt")" = 1 ] && ok || bad "P1: a rebuild labels its PR the same way"

# P2 — no line: nothing.
reset; meta p2 $'## Problem\nNo labels wanted.\n'; apply p2
[ ! -s "$T/calls.txt" ] && [ ! -s "$LOG" ] && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "P2: no line means 0 gh calls and no log line (calls: $(cat "$T/calls.txt"); log: $(cat "$LOG"))"

# P3 — one unknown label: skipped with exactly one line, the rest posted.
reset; meta p3 'PR-Labels: full-ci, nope'; apply p3
grep -q -- "$P -f labels\[\]=full-ci\$" "$T/posts.txt" && ! grep -q nope "$T/posts.txt" \
  && ok || bad "P3: only full-ci is posted (posts: $(cat "$T/posts.txt"))"
[ "$(grep -c "'nope'" "$LOG")" = 1 ] && grep -q "'nope' is not a label in example-org/project-6 — skipped" "$LOG" \
  && [ "$(cat "$T/rc")" = 0 ] && ok || bad "P3: one skip line names 'nope' (log: $(cat "$LOG"))"

# P4 — every label unknown: no POST, one line each.
reset; meta p4 'PR-Labels: nope, nada'; apply p4
[ ! -s "$T/posts.txt" ] && [ "$(grep -c 'skipped' "$LOG")" = 2 ] && [ "$(wc -l < "$LOG")" = 2 ] && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "P4: no POST and two skip lines (posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"))"

# P5 — the POST fails: one line, rc 0, never `labelled`.
reset; touch "$T/post.fail"; apply p1
grep -q "pr labels: could NOT label $URL ($P failed)" "$LOG" && [ "$(cat "$T/rc")" = 0 ] \
  && ok || bad "P5: a failed POST is one line and rc 0 (rc $(cat "$T/rc"); log: $(cat "$LOG"))"
grep -q 'labelled' "$LOG" && bad "P5: a failed POST never says labelled" || ok

# P6 — a label read with no status: skipped, not posted.
reset; echo bug > "$T/broken"; meta p6 'PR-Labels: bug, full-ci'; apply p6
grep -q "pr labels: could not read label 'bug' in example-org/project-6 (HTTP none) — skipped" "$LOG" \
  && ! grep -q 'labels\[\]=bug' "$T/posts.txt" && grep -q 'labels\[\]=full-ci' "$T/posts.txt" \
  && ok || bad "P6: an unread label is skipped (posts: $(cat "$T/posts.txt"); log: $(cat "$LOG"))"
: > "$T/broken"

# P7 — near misses: none of these is a PR-Labels line.
n=0
for b in 'we need PR-Labels: full-ci here' $'```\nPR-Labels: full-ci\n```' $'~~~\nPR-Labels: full-ci\n~~~' \
         'PR-Labels:' 'PR-Labels:  ,  ' 'PR-Labelz: full-ci' '> PR-Labels: full-ci'; do
  n=$((n+1)); reset; meta "p7-$n" "$b"; apply "p7-$n"
  [ ! -s "$T/calls.txt" ] && [ ! -s "$LOG" ] && ok || bad "P7.$n: '$b' is not a PR-Labels line (calls: $(cat "$T/calls.txt"))"
done
# The key only in a comment: body only.
reset; mkdir -p "$T/p7c"; jq -n '{title:"t",labels:[],body:"nothing",comments:[{body:"PR-Labels: full-ci"}]}' > "$T/p7c/meta.json"
apply p7c
[ ! -s "$T/calls.txt" ] && ok || bad "P7: a comment's PR-Labels line does not count"

# P8 — parser hits.
pp() { printf '%s' "$1" | prl_parse | paste -sd'|' -; }
[ "$(pp '- PR-Labels: full-ci')" = full-ci ] && ok || bad "P8: bullet (got '$(pp '- PR-Labels: full-ci')')"
[ "$(pp '  * PR-Labels: full-ci')" = full-ci ] && ok || bad "P8: star bullet"
[ "$(pp '`PR-Labels: full-ci`')" = full-ci ] && ok || bad "P8: backticked line (got '$(pp '`PR-Labels: full-ci`')')"
[ "$(pp 'pr-label: full-ci')" = full-ci ] && ok || bad "P8: singular key, lower case"
[ "$(pp $'PR-Labels: `full-ci`, `needs review`\r')" = 'full-ci|needs review' ] && ok \
  || bad "P8: backticked values keep inner spaces (got '$(pp $'PR-Labels: `full-ci`, `needs review`\r')')"
[ "$(pp 'PR-Labels: full-ci, full-ci')" = full-ci ] && ok || bad "P8: duplicates are dropped"
[ "$(pp "PR-Labels: $(seq -s, -f 'l%g' 1 12)" | tr '|' '\n' | wc -l)" = 10 ] && ok || bad "P8: 12 values keep PRL_MAX=10"
[ -z "$(pp "PR-Labels: $(printf 'x%.0s' $(seq 1 51))")" ] && ok || bad "P8: a value over 50 chars is dropped"
# A spaced label reaches GitHub url-encoded and is posted whole.
reset; meta p8 'PR-Labels: needs review'; apply p8
grep -q 'api -i repos/example-org/project-6/labels/needs%20review' "$T/calls.txt" && grep -q 'labels\[\]=needs review$' "$T/posts.txt" \
  && ok || bad "P8: 'needs review' is read encoded and posted whole (calls: $(cat "$T/calls.txt"))"

# P9 — no meta, or junk: nothing, rc 0.
reset; rc=0; prl_apply project-6-os "$URL" "$T/none/meta.json" "$LOG" || rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.txt" ] && [ ! -s "$LOG" ] && ok || bad "P9: a missing meta is a no-op (rc $rc)"
reset; mkdir -p "$T/p9"; echo 'not json PR-Labels: full-ci' > "$T/p9/meta.json"; apply p9
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/calls.txt" ] && [ ! -s "$LOG" ] && ok || bad "P9: a junk meta is a no-op"
# Not a PR url: one line, no gh call.
reset; rc=0; prl_apply project-6-os "https://example.com/x" "$T/p1/meta.json" "$LOG" || rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/calls.txt" ] && grep -q "is not a PR url" "$LOG" && ok || bad "P9: a non-PR url is one line"

# P10 — the pr.sh block, first thing after RB_PR_OPEN.
BLK=$(sed -n '/# >>> pr labels (BH-7929)/,/# <<< pr labels/p' "$DIR/bin/lib/rb/pr.sh")
[ -n "$BLK" ] || bad "P10: the '# >>> pr labels (BH-7929)' block is missing from bin/lib/rb/pr.sh"
ORDER=$(grep -nE '^\[ -n "\$PR_URL" \] && RB_PR_OPEN=1|# >>> pr labels \(BH-7929\)|^HF_PR=0' "$DIR/bin/lib/rb/pr.sh" | cut -d: -f2- | paste -sd'|' -)
[ "$ORDER" = '[ -n "$PR_URL" ] && RB_PR_OPEN=1|# >>> pr labels (BH-7929)|HF_PR=0' ] && ok \
  || bad "P10: the block sits right after RB_PR_OPEN=1, before the hotfix label (got: $ORDER)"
(
  prl_apply() { echo "called $*" >> "$T/prl.calls"; }
  : > "$T/prl.calls"
  PROJECT=project-6-os; BUILD="$T/b"; PR_URL=""
  eval "$BLK"
  [ ! -s "$T/prl.calls" ] || echo "no-url called" >> "$T/prl.bad"
  PR_URL="$URL"
  eval "$BLK"
)
[ ! -e "$T/prl.bad" ] && ok || bad "P10: no PR_URL, no call"
[ "$(grep -c . "$T/prl.calls")" = 1 ] && grep -q "called project-6-os $URL $T/b/ticket-meta.json $T/b/pipeline.log" "$T/prl.calls" \
  && ok || bad "P10: with PR_URL the block calls prl_apply once with project, url, meta, log (got: $(cat "$T/prl.calls"))"
# The real lib through the block, as run-build.sh loads it.
reset; mkdir -p "$T/b"; cp "$T/p1/meta.json" "$T/b/ticket-meta.json"
( unset -f prl_apply; PROJECT=project-6-os; BUILD="$T/b"; PR_URL="$URL"; eval "$BLK" )
grep -q -- "$P -f labels\[\]=full-ci\$" "$T/posts.txt" && grep -q 'pr labels: labelled' "$T/b/pipeline.log" \
  && ok || bad "P10: the block loads the lib and labels (posts: $(cat "$T/posts.txt"))"

# P11 — the hub's push-rejected open path labels the PR it opens.
printf '#!/bin/bash\necho x\n' > "$T/h/bin/fleet-conf.sh"; chmod +x "$T/h/bin/fleet-conf.sh"
ppr11() {
  (
    unset -f prl_apply
    # shellcheck source=bin/lib/pool-push-rejected.sh
    . "$T/h/bin/lib/pool-push-rejected.sh" || exit 9
    ppr_rejected_line() { return 0; }; ppr_decide() { PPR_CMP=landed; }
    hold_push_verdict() { return 0; }; gh_pr_create_ladder() { echo "$URL"; }
    ppr_title() { echo "TK-2235: t"; }; ppr_plan_from_branch() { :; }; ppr_body() { :; }
    pr_trailers_apply() { :; }; say() { :; }
    P=project-6-os KEY=TK-2235 LOCAL="$T/p11" PDIR="$T/p11" RLINE="BUILD_DEFERRED push" POOL_SLUG=example-org/project-6
    ppr_reap_landed
  )
}
mkdir -p "$T/p11"; echo 'BUILD_DEFERRED push' > "$T/p11/RESULT"
reset; ppr11 && [ "$(head -n 1 "$T/p11/RESULT" | cut -d' ' -f1-2)" = "PR_CREATED $URL" ] && ok || bad "P11: setup: ppr_reap_landed did not open the PR"
[ ! -s "$T/posts.txt" ] && ok || bad "P11: no ticket-meta.json, no label POST"
echo 'BUILD_DEFERRED push' > "$T/p11/RESULT"; cp "$T/p1/meta.json" "$T/p11/ticket-meta.json"
reset; ppr11
grep -q -- "$P -f labels\[\]=full-ci\$" "$T/posts.txt" && grep -q 'pr labels: labelled' "$T/p11/pipeline.log" \
  && ok || bad "P11: the hub-opened PR gets the ticket's labels (posts: $(cat "$T/posts.txt"); log: $(cat "$T/p11/pipeline.log" 2>/dev/null))"

echo "pr-labels.bh-7929: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

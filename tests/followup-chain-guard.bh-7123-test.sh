#!/bin/bash
# tests/followup-chain-guard.bh-7123-test.sh — BH-7123 wave B: no follow-up
# chains, and the follow-up floor.
#
#   F1-F5  bin/lib/group-findings.sh: a group under review.followup_min_level
#          files nothing (rows `floor`); `core` files only a group with a
#          high|critical row or a core-flow screen (review.core_flows.<board>);
#          `never` files no group ticket (an urgent data-leak still files);
#          no row = today's behaviour; a group whose only open issue is itself a
#          follow-up gets a comment, never a follow-up of a follow-up.
#   G1-G8  bin/lib/gh-shim/issue-write.sh gshim_cmd_issue_create: refuses (rc 1,
#          one stderr line, no POST) when the running build's ticket is itself
#          a follow-up (`Follow-up-of: #<n>` first line or the
#          findings-followup-of marker) unless review.followup_chain is 1;
#          prepends `Follow-up-of: #<ticket>` to every issue a build files; the
#          ticket body comes from $HARNESS/builds/<project>-<ticket>-*/ticket-meta.json
#          or ONE cached issue GET.
#
# Part F drives the real lib against tests/lib/gh-rest-fx.sh with the real jobs
# client over a settings cache; part G drives the real shim through
# tests/lib/gh-shim-stub.sh. Run: HARNESS_TEST_SANDBOX=1 bash tests/followup-chain-guard.bh-7123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# The guard lib is named here BY PATH so bin/test-impact.sh maps a change to it
# onto this suite (an unnamed script is an orphan the impact lane never selects).
[ -r "$DIR/bin/lib/gh-shim/followup-guard.sh" ] && ok || bad "G0 bin/lib/gh-shim/followup-guard.sh is missing"
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }
command -v jq >/dev/null || { echo "followup-chain-guard: jq is required"; exit 1; }

# ═════ Part F: the group-findings floor ═════════════════════════════════════
SLUG=example-org/demo
H2="$T/h2"; mkdir -p "$H2/state" "$H2/logs" "$T/tmp"
for L in bin/lib/group-findings.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H2" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
REG=$(rendered_registry)
ghfx_init
export HARNESS="$H2" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" LANE_REGISTRY="$REG" LANE_GATE_NOW=2000000000 GH_ETAG=0 JOBS_URL=
unset GROUP_FINDINGS GROUP_FINDINGS_URGENT_RANK LANE_GATE_DISABLE REVIEW_LEVEL_FOLLOWUP_MIN_LEVEL REVIEW_LEVEL_CORE_FLOWS HARNESS_SECRET
# shellcheck source=bin/lib/group-findings.sh
. "$H2/bin/lib/group-findings.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
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
    *) printf 'HTTP/1.1 201 Created\r\n\r\n{"number":%s,"html_url":"https://github.com/fixture/issues/%s"}' $((100+n)) $((100+n)) ;;
  esac
  exit 0
fi
SH
cache() { # cache <k=v>... — a FRESH settings cache: grouping on for project-3 plus these rows
  local v='{"lib.group-findings.project-3.group_findings":"1"}' kv
  for kv in "$@"; do v=$(jq -c --arg k "${kv%%=*}" --arg val "${kv#*=}" '. + {($k): $val}' <<<"$v"); done
  scratch_rm "$H2/state/lane-gate" 2>/dev/null
  jq -nc --argjson v "$v" '{fetched_at:2000000000, values:$v, seeded:{}}' > "$H2/state/settings-cache.json"
}
fnd() { # fnd <key> <severity> <title> [class]
  jq -nc --arg k "$1" --arg s "$2" --arg t "$3" --arg c "${4:-}" \
    '{board:"project-3", screen_or_flow:$k, severity:$s, title:$t, repro:("Open " + $k), cause:("cause: " + $t)}
     + (if $c != "" then {class:$c} else {} end)'
}
iss() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n, state:"open", title:"fixture issue", body:$b}'; }
mk() { printf '<!-- findings-group: project-3|%s -->' "$1"; }
new_run() { RD="$T/runs/$1"; mkdir -p "$RD"; : > "$RD/in.jsonl"; ghfx_routes_reset; ghfx_log_reset; scratch_rm "$T/posts" 2>/dev/null; rm -f "$T/post.n"; }
issues() { ghfx_route GET "repos/$SLUG/issues" 200 "$1"; }
gfrun() { ( gf_run "$RD/in.jsonl" "$RD" "$SLUG" "$@" ) > "$RD/out.txt" 2>&1; RC=$?; }
nposts() { local f n=0; for f in "$T"/posts/*.path; do [ -e "$f" ] || continue; case "$(cat "$f")" in $1) n=$((n+1)) ;; esac; done; echo "$n"; }
post_title() { local f; for f in $(ls "$T"/posts/*.path 2>/dev/null | sort -V); do case "$(cat "$f")" in $1) cat "${f%.path}.title"; return ;; esac; done; }
last_rows() { jq -s --arg a "$1" 'group_by(.fp) | map(select(.[0].fp != null) | last) | [.[] | select(.action == $a)] | length' "$RD/findings-ledger.jsonl" 2>/dev/null || echo -1; }

# F1: core — a medium/low group is under the floor; a group with a high files
new_run f1; cache review.followup_min_level=core; issues '[]'
fnd /settings medium "Padding is 14px" >> "$RD/in.jsonl"; fnd /settings low "Sort indicator missing" >> "$RD/in.jsonl"
fnd flow:checkout high "Pay button does nothing" >> "$RD/in.jsonl"; fnd flow:checkout low "Copy nit" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 0 ] && ok || bad "F1 rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "F1 want 1 issue POST (the high group), got $(nposts "repos/$SLUG/issues")"
[ "$(post_title "repos/$SLUG/issues")" = "QA findings: flow:checkout (2 items)" ] && ok || bad "F1 the filed group must be the checkout flow: $(post_title "repos/$SLUG/issues")"
[ "$(last_rows floor)" = 2 ] && ok || bad "F1 the two /settings findings must end 'floor', got $(last_rows floor)"
[ "$(last_rows filed)" = 2 ] && ok || bad "F1 the two checkout findings must end filed"
grep -q 'floor' "$RD/group-findings.md" && grep -q '/settings' "$RD/group-findings.md" && ok || bad "F1 the summary names the floored group: $(cat "$RD/group-findings.md")"

# F2: never — no group ticket even with a high; an urgent data-leak still files
new_run f2; cache review.followup_min_level=never; issues '[]'
fnd /clients high "Totals wrong" >> "$RD/in.jsonl"
fnd /admin high "Any member can read every company" data-leak >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "F2 want exactly the urgent POST, got $(nposts "repos/$SLUG/issues")"
case "$(post_title "repos/$SLUG/issues")" in "QA urgent:"*) ok ;; *) bad "F2 the one POST must be the urgent one: $(post_title "repos/$SLUG/issues")" ;; esac
[ "$(last_rows floor)" -ge 1 ] && ok || bad "F2 the /clients finding must end floor"

# F3: core + a core-flow screen — a medium-only group on a core flow files
new_run f3; cache review.followup_min_level=core "review.core_flows.project-3=clients, quotes"; issues '[]'
fnd /clients medium "Table does not sort" >> "$RD/in.jsonl"
fnd /reports medium "Chart legend overlaps" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "F3 want 1 POST (the core-flow screen), got $(nposts "repos/$SLUG/issues")"
[ "$(post_title "repos/$SLUG/issues")" = "QA findings: /clients (1 items)" ] && ok || bad "F3 the core-flow screen files: $(post_title "repos/$SLUG/issues")"
[ "$(last_rows floor)" = 1 ] && ok || bad "F3 /reports stays under the floor"

# F4: the only open issue is itself a follow-up with an approved PR -> comment, no chain
new_run f4; cache review.followup_min_level=core
issues "[$(iss 50 "$(mk /clients)
<!-- findings-followup-of: #40 -->
QA findings for /clients")]"
ghfx_route GET "repos/$SLUG/pulls" 200 '[{"number":51,"state":"open","body":"Closes #50","head":{"sha":"abc1234def5678abc1234def5678abc1234def56","ref":"ticket/project-3-x"}}]'
ghfx_route GET "repos/$SLUG/pulls/51/reviews" 200 '[{"state":"APPROVED","commit_id":"abc1234def5678abc1234def5678abc1234def56","user":{"login":"operator"}}]'
ghfx_route GET "repos/$SLUG/issues/51/comments" 200 '[]'
ghfx_route GET "repos/$SLUG/issues/50/comments" 200 '[]'
fnd /clients high "Late high finding" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "F4 a follow-up of a follow-up was filed"
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 1 ] && ok || bad "F4 want one comment on #50, got $(nposts "repos/$SLUG/issues/50/comments")"
[ "$(last_rows commented)" = 1 ] && ok || bad "F4 the ledger row must end commented"
grep -q 'itself a follow-up' "$RD/group-findings.md" && ok || bad "F4 the summary says why: $(cat "$RD/group-findings.md")"

# F5: no review.* row and no row readable -> today's behaviour (a medium-only group files)
new_run f5; cache; issues '[]'
fnd /settings medium "Padding is 14px" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "F5 with no floor row the group files as before, got $(nposts "repos/$SLUG/issues")"
# the env knob wins over the row (REVIEW_LEVEL_* is rl_knob's env family)
new_run f5b; cache review.followup_min_level=always; issues '[]'
fnd /settings medium "Padding is 14px" >> "$RD/in.jsonl"
REVIEW_LEVEL_FOLLOWUP_MIN_LEVEL=never gfrun
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "F5b the env knob never must floor the group"

# ═════ Part G: the gh shim guard ════════════════════════════════════════════
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
gshim_stub_setup
unset LANE_REGISTRY LANE_GATE_NOW
# The shim needs bash 4 (declare -g). On a box whose /bin/bash is 3.x (macOS)
# the shebang cannot be honoured, so the shim runs through the newest bash on
# PATH instead; on CI (bash 5) this branch is inert.
if [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ] && command -v bash >/dev/null 2>&1 \
   && [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]; then
  rm -f "$T/shim/gh"
  printf '#!/bin/sh\nGH_REAL=%q exec %q %q "$@"\n' "$T/real/gh" "$(command -v bash)" "$DIR/bin/gh-rest-shim" > "$T/shim/gh"
  chmod +x "$T/shim/gh"
fi
printf 'https://github.com/o/r\n' >"$T/fixtures/git-origin.txt"
printf '{"html_url":"https://github.com/o/r/issues/9","number":9,"title":"T"}\n' | gshim_fixture repos_o_r_issues
printf '{"number":7,"title":"child","body":"Follow-up-of: #5\\n\\nchild body","state":"open"}\n' | gshim_fixture repos_o_r_issues_7
printf '{"number":8,"title":"parent","body":"a normal ticket","state":"open"}\n' | gshim_fixture repos_o_r_issues_8
calls_no_bodies() { gshim_calls | sed 's/ input=.*//'; }
ngets() { gshim_calls | grep -c "repos/o/r/issues/$1$" || true; }
build() { # build <key> <body> — the running build's ticket under $HARNESS/builds
  local d="$HARNESS/builds/demo-$1-202610161200"; scratch_rm "$HARNESS/builds"; mkdir -p "$d"
  jq -nc --arg b "$2" '{number: 8, title: "T", body: $b}' > "$d/ticket-meta.json"
}
unset HARNESS_TICKET HARNESS_LANE_PROJECT REVIEW_FOLLOWUP_CHAIN

# G1: no running build -> untouched
gshim_reset; scratch_rm "$HARNESS/builds"
gshim_run issue create --title T --body "plain"
[ "$RC" = 0 ] && ok || bad "G1 rc=$RC: $ERR"
has "G1 body untouched" "$(gshim_calls)" 'input={"title":"T","body":"plain"}'

# G2: a build on a normal ticket -> allowed, Follow-up-of prepended
gshim_reset; build 8 "a normal ticket"
export HARNESS_TICKET=8 HARNESS_LANE_PROJECT=demo
gshim_run issue create --title T --body "plain"
[ "$RC" = 0 ] && ok || bad "G2 rc=$RC: $ERR"
has "G2 prepended" "$(gshim_calls)" 'input={"title":"T","body":"Follow-up-of: #8\n\nplain"}'
[ "$(ngets 8)" = 0 ] && ok || bad "G2 the build dir answers; no issue GET"

# G3: the build's ticket is itself a follow-up -> refused
gshim_reset; build 8 "Follow-up-of: #5

the child ticket"
gshim_run issue create --title T --body "grandchild"
[ "$RC" = 1 ] && ok || bad "G3 rc=$RC (want 1)"
hasnt "G3 no POST" "$(gshim_calls)" "-X POST repos/o/r/issues"
[ "$(printf '%s\n' "$ERR" | grep -c .)" = 1 ] && ok || bad "G3 one stderr line, got: $ERR"
has "G3 stderr says follow-up" "$ERR" "follow-up"
has "G3 stderr names the ticket" "$ERR" "BH-7123"
gshim_reset; build 8 "QA findings for /clients
<!-- findings-followup-of: #40 -->
items"
gshim_run issue create --title T --body "grandchild"
[ "$RC" = 1 ] && ok || bad "G3b marker: rc=$RC (want 1)"
hasnt "G3b no POST" "$(gshim_calls)" "-X POST repos/o/r/issues"

# G4: review.followup_chain=1 turns the guard off (env, then the settings row)
gshim_reset
REVIEW_FOLLOWUP_CHAIN=1 gshim_run issue create --title T --body "grandchild"
[ "$RC" = 0 ] && ok || bad "G4 env chain=1 rc=$RC: $ERR"
has "G4 still prepends" "$(gshim_calls)" '"body":"Follow-up-of: #8\n\ngrandchild"'
gshim_reset
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$HARNESS" ) >/dev/null || bad "G4 scratch_install_closure bin/jobs-client.sh"
mkdir -p "$HARNESS/state"
jq -nc --argjson t "$(date -u +%s)" '{fetched_at:$t, values:{"review.followup_chain":"1"}, seeded:{}}' > "$HARNESS/state/settings-cache.json"
gshim_run issue create --title T --body "grandchild"
[ "$RC" = 0 ] && ok || bad "G4b settings row chain=1 rc=$RC: $ERR"
rm -f "$HARNESS/state/settings-cache.json"
gshim_reset; gshim_run issue create --title T --body "grandchild"
[ "$RC" = 1 ] && ok || bad "G4c with the row gone the guard is back: rc=$RC"

# G5: no build dir, numeric ticket -> ONE issue GET, cached
gshim_reset; scratch_rm "$HARNESS/builds"; scratch_rm "$HARNESS/state/gh-shim"
export HARNESS_TICKET=7
gshim_run issue create --title T --body "x"
[ "$RC" = 1 ] && ok || bad "G5 a follow-up read from GitHub must refuse: rc=$RC $ERR"
[ "$(ngets 7)" = 1 ] && ok || bad "G5 exactly one GET of issue 7, got $(ngets 7)"
gshim_run issue create --title T --body "x"
[ "$RC" = 1 ] && [ "$(ngets 7)" = 1 ] && ok || bad "G5 second call must use the cache: rc=$RC gets=$(ngets 7)"
gshim_reset; export HARNESS_TICKET=8; scratch_rm "$HARNESS/state/gh-shim"
gshim_run issue create --title T --body "x"
[ "$RC" = 0 ] && ok || bad "G5b a normal ticket read from GitHub is allowed: rc=$RC $ERR"
has "G5b prepended from the GET path" "$(gshim_calls)" '"body":"Follow-up-of: #8\n\nx"'

# G6: the line is never doubled; G7: --body-file; G8: a non-numeric key
gshim_reset; build 8 "normal"
gshim_run issue create --title T --body "Follow-up-of: #8

already there"
has "G6 not doubled" "$(gshim_calls)" '"body":"Follow-up-of: #8\n\nalready there"'
gshim_reset; printf 'from a file' > "$T/b.md"
gshim_run issue create --title T -F "$T/b.md"
has "G7 body-file prepended" "$(gshim_calls)" '"body":"Follow-up-of: #8\n\nfrom a file"'
gshim_reset; scratch_rm "$HARNESS/builds"; mkdir -p "$HARNESS/builds/demo-BH-8-202610161200"
jq -nc '{number: 8, title: "T", body: "normal"}' > "$HARNESS/builds/demo-BH-8-202610161200/ticket-meta.json"
export HARNESS_TICKET=BH-8
gshim_run issue create --title T --body "x"
[ "$RC" = 0 ] && ok || bad "G8 rc=$RC: $ERR"
has "G8 the key as given" "$(gshim_calls)" '"body":"Follow-up-of: #BH-8\n\nx"'
unset HARNESS_TICKET HARNESS_LANE_PROJECT

# the seed row exists, INSERT OR IGNORE, default 0
FRAG=$(ls "$DIR"/worker/jobs/schema.d/*-bh-7123-wave-b.sql 2>/dev/null | head -1)
[ -n "$FRAG" ] && grep -q "INSERT OR IGNORE INTO settings" "$FRAG" && grep -q "'review.followup_chain','0'" "$FRAG" && ok || bad "S1 schema.d fragment seeding review.followup_chain=0 is missing"
[ -n "$FRAG" ] && ! grep -qiE 'CREATE TABLE|ALTER TABLE|DROP' "$FRAG" && ok || bad "S1 the wave adds settings rows only"

echo "followup-chain-guard.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

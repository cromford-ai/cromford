#!/bin/bash
# tests/unblock-act-levers.bh-8817-test.sh — BH-8817: the three writer arms
# bin/lib/unblock/act.sh (ub_act) gained for Archie's levers: update_branch
# (rebase), ticket_comment and file_ticket. Sources the REAL lib, as
# tests/unblock-act.bh-7726-test.sh does, and stubs only `gh` on PATH (a local
# store, one line per call in $CALLS, 0 network) and the scratch $HARNESS/bin
# scripts it reads (jobs-client.sh for the mode row, lane-alert.sh).
#
#   V1  bad input: rc 1 and 0 calls (no repo, no issue, no lines, no title,
#       a title with a newline, update_branch with no head)
#   V2  the gates stand: never-auto class, no mode row, shadow = would, and
#       update_branch on a moved head is refused head-moved (0 writes)
#   V3  update_branch: one PUT with expected_head_sha = the record's head;
#       a failed PUT = failed update-branch-failed
#   V4  ticket_comment: one comment with the marker; the marker already on the
#       issue = done marker-found and 0 writes; a failed read = failed
#   V5  file_ticket: one POST with label ai-build and the marker in the body,
#       done "filed #<n>"; an open ai-build issue with the marker = done
#       marker-found, 0 writes; the marker search reads page 2 with `&`
#   V6  0 network calls (the stub is the only gh)
#   V7  main's arms (BH-8736) still answer through the union UB_ACTIONS, as
#       tests/unblock-lifecycle.bh-8736-test.sh pins them: rebuild = the
#       phase to planned, then launch_fastpath, done launched; rebuild in
#       shadow = would WOULD_REBUILD; rebuild with no lifecycle lib = failed
#       lifecycle-libs-not-loaded; ask = escalated card <id>, one critical
#       alert, UB_ACT_CARD with .lifecycle
#
# MUTATIONS (D1), each tried once by hand: drop expected_head_sha -> V3 red;
# skip the marker search in ticket_comment -> V4 red; build the list path
# with a second `?` -> V5 red; drop ticket_comment from UB_ISSUE_ACTIONS'
# repo check -> V1 red; drop rebuild or ask from the union UB_ACTIONS -> V7
# red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-act-levers.bh-8817-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SLUG=example-org/cromford
H42=4242f1c74242f1c74242f1c74242f1c74242f1c7
export UB_NOW=1792512000

mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'EOF'
#!/bin/bash
[ "${1:-}" = api ] || { echo "gh stub: only gh api" >&2; exit 2; }
shift
m=GET path="" input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -*) echo "gh stub: unknown flag $1" >&2; exit 2 ;;
    *) path="$1"; shift ;;
  esac
done
echo "gh $m $path" >> "$CALLS"
[ -n "$input" ] && { jq -c . "$input" >> "$GHF/inputs.log" 2>/dev/null || echo bad-json >> "$GHF/inputs.log"; }
p="${path%%\?*}"
page=$(printf '%s' "$path" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p'); page="${page:-1}"
slice() { [ -f "$1" ] || echo '[]' > "$1"; jq -c --argjson pg "$page" '.[(($pg - 1) * 100):($pg * 100)]' "$1"; }
if [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/pulls/([0-9]+)$ ]]; then
  jq -nc --arg s "$(cat "$GHF/head-${BASH_REMATCH[1]}" 2>/dev/null)" '{head: {sha: $s}}'
elif [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/(issues/[0-9]+/comments|pulls/[0-9]+/reviews)$ ]]; then
  [ -f "$GHF/fail-read" ] && exit 1
  slice "$GHF/$(printf '%s' "${BASH_REMATCH[1]}" | tr / -).json"
elif [[ "$m $p" =~ ^GET\ repos/[^/]+/[^/]+/issues$ ]]; then
  [ -f "$GHF/fail-read" ] && exit 1
  case "$path" in *'?state=open&labels=ai-build&per_page=100&page='*) ;; *) echo "gh stub: bad list path $path" >&2; exit 1 ;; esac
  slice "$GHF/open-issues.json"
elif [[ "$m $p" =~ ^POST\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments$ ]]; then
  [ -f "$GHF/fail-write" ] && exit 1; echo '{"id": 1}'
elif [[ "$m $p" =~ ^POST\ repos/[^/]+/[^/]+/issues$ ]]; then
  [ -f "$GHF/fail-write" ] && exit 1; echo '{"number": 9001}'
elif [[ "$m $p" =~ ^PUT\ repos/[^/]+/[^/]+/pulls/[0-9]+/update-branch$ ]]; then
  [ -f "$GHF/fail-write" ] && exit 1; echo '{"message": "Updating pull request branch."}'
else
  echo "gh stub: no route for $m $path" >&2; exit 1
fi
EOF
chmod +x "$T/pathbin/gh"
export PATH="$T/pathbin:$PATH"

mkdir -p "$T/stubbin"
cat > "$T/stubbin/jobs-client.sh" <<'EOF'
#!/bin/bash
[ "$1" = setting-get ] || exit 2
echo "jobs-client setting-get $2" >> "$CALLS"
f="$HARNESS/stub/setting/$2"; [ -f "$f" ] || exit 2
cat "$f"; echo
EOF
printf '#!/bin/bash\necho "lane-alert $*" >> "$CALLS"\nexit 0\n' > "$T/stubbin/lane-alert.sh"
chmod +x "$T/stubbin/"*.sh

# shellcheck source=../bin/lib/unblock/act.sh
. "$DIR/bin/lib/unblock/act.sh" || { echo "FAIL: bin/lib/unblock/act.sh could not be sourced"; exit 1; }

newcase() {
  CASE="$1"
  export HARNESS="$T/c-$1"
  CALLS="$HARNESS/calls.txt"; GHF="$HARNESS/gh"; export CALLS GHF
  mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/stub/setting" "$GHF"
  cp -p "$T/stubbin/"*.sh "$HARNESS/bin/"
  : > "$CALLS"
  printf act > "$HARNESS/stub/setting/unblock.project.cromford.mode"
  printf '%s' "$H42" > "$GHF/head-42"
  export UNBLOCK_ACT=1
}
key() { printf 'archie:u-%s' "$(printf '%s' "$CASE" | md5sum | cut -c1-6)"; }
marker() { printf '<!-- tackler:%s -->' "$(key)"; }
# mk <action> <args-json> [jq filter] — one record of PR 42.
mk() {
  jq -nc --arg k "$(key)" --arg n "$1" --argjson a "$2" --arg s "$SLUG" --arg h "$H42" \
    "{decision_key: \$k, project: \"cromford\", repo: \$s, subject_kind: \"pr\", subject: (\$s + \"#42\"),
      pr: 42, head: \$h, rule_id: \"archie-card\", class: \"queue-requeue\", cites: [], action: {name: \$n, args: \$a}} | ${3:-.}"
}
run() { ub_act "$1" > "$HARNESS/out.txt" 2>&1; RC=$?; }
expect() { # expect <label> <outcome> <detail>
  if [ "$RC" = 0 ] && [ "${UB_ACT_OUTCOME:-}" = "$2" ] && [ "${UB_ACT_DETAIL:-}" = "$3" ]; then ok
  else bad "$1: want rc 0 '$2' '$3', got rc $RC '${UB_ACT_OUTCOME:-}' '${UB_ACT_DETAIL:-}' calls: $(tr '\n' '|' < "$CALLS")"; fi
}
writes() { grep -cE '^gh (POST|PUT|PATCH|DELETE) ' "$CALLS"; }

# ── V1 bad input ─────────────────────────────────────────────────────────────
newcase v1
LINES='{"lines":["x"]}'
for r in "$(mk ticket_comment "$LINES" 'del(.repo)')" "$(mk ticket_comment "$LINES")" \
         "$(mk ticket_comment '{"issue":42}')" "$(mk ticket_comment '{"issue":42,"lines":[""]}')" \
         "$(mk file_ticket "$LINES")" "$(mk file_ticket '{"title":"a\nb","lines":["x"]}')" \
         "$(mk file_ticket '{"title":"t","lines":["x"]}' '.repo = "not a slug"')" "$(mk update_branch '{}' 'del(.head)')"; do
  : > "$CALLS"; UB_ACT_OUTCOME=stale; run "$r"
  [ "$RC" = 1 ] && [ -z "$UB_ACT_OUTCOME" ] && [ ! -s "$CALLS" ] && ok || bad "V1 bad input rc 1, 0 calls: rc $RC '$UB_ACT_OUTCOME' for $r"
done

# ── V2 the gates ─────────────────────────────────────────────────────────────
newcase v2a; run "$(mk file_ticket '{"title":"t","lines":["x"]}' '.class = "spend"')"
expect "V2 never-auto class" refused never-auto:spend; [ "$(writes)" = 0 ] && ok || bad "V2 never-auto: 0 writes"
newcase v2b; rm -f "$HARNESS/stub/setting/unblock.project.cromford.mode"; run "$(mk ticket_comment '{"issue":42,"lines":["x"]}')"
expect "V2 no mode row" refused no-opt-in; [ "$(grep -c '^gh ' "$CALLS")" = 0 ] && ok || bad "V2 no mode row: 0 gh calls"
newcase v2c; UNBLOCK_ACT=0 run "$(mk update_branch '{}')"
expect "V2 UNBLOCK_ACT=0" would WOULD_UPDATE_BRANCH; [ "$(grep -c '^gh ' "$CALLS")" = 0 ] && ok || bad "V2 shadow: 0 gh calls"
newcase v2d; printf '%s' "0000f1c70000f1c70000f1c70000f1c70000f1c7" > "$GHF/head-42"; run "$(mk update_branch '{}')"
expect "V2 head moved" refused head-moved; [ "$(writes)" = 0 ] && ok || bad "V2 head moved: 0 writes"

# ── V3 update_branch ─────────────────────────────────────────────────────────
newcase v3; run "$(mk update_branch '{}')"
expect "V3 update_branch" done update-branch-requested
[ "$(grep -c "^gh PUT repos/$SLUG/pulls/42/update-branch$" "$CALLS")" = 1 ] && ok || bad "V3 one PUT: $(cat "$CALLS")"
[ "$(tail -1 "$GHF/inputs.log")" = "{\"expected_head_sha\":\"$H42\"}" ] && ok || bad "V3 body: $(cat "$GHF/inputs.log")"
grep -q "act cromford $SLUG#42 archie-card update_branch done update-branch-requested" "$HARNESS/logs/unblock.log" && ok \
  || bad "V3 the unblock.log line: $(cat "$HARNESS/logs/unblock.log")"
newcase v3b; touch "$GHF/fail-write"; run "$(mk update_branch '{}')"; expect "V3 PUT fails" failed update-branch-failed

# ── V4 ticket_comment ────────────────────────────────────────────────────────
newcase v4; run "$(mk ticket_comment '{"issue":8798,"lines":["the gate is red on main","Archie answered Tackler card u-abc123."]}')"
expect "V4 ticket_comment" done "commented #8798"
[ "$(writes)" = 1 ] && grep -q "^gh POST repos/$SLUG/issues/8798/comments$" "$CALLS" && ok || bad "V4 one comment POST: $(cat "$CALLS")"
B=$(tail -1 "$GHF/inputs.log" | jq -r .body)
case "$B" in *"the gate is red on main"*"$(marker)") ok ;; *) bad "V4 body has the lines and ends with the marker: $B" ;; esac
newcase v4b; jq -nc --arg m "$(marker)" '[{body: "older"}, {body: ("x " + $m)}]' > "$GHF/issues-8798-comments.json"
run "$(mk ticket_comment '{"issue":8798,"lines":["x"]}')"
expect "V4 marker already there" done marker-found; [ "$(writes)" = 0 ] && ok || bad "V4 marker: 0 writes"
newcase v4c; touch "$GHF/fail-read"; run "$(mk ticket_comment '{"issue":8798,"lines":["x"]}')"
expect "V4 comments unreadable" failed marker-unreadable; [ "$(writes)" = 0 ] && ok || bad "V4 unreadable: 0 writes"

# ── V5 file_ticket ───────────────────────────────────────────────────────────
newcase v5; run "$(mk file_ticket '{"title":"Archie: box-hung on box:orgo-7","lines":["the box hangs every hour"]}')"
expect "V5 file_ticket" done "filed #9001"
[ "$(writes)" = 1 ] && grep -q "^gh POST repos/$SLUG/issues$" "$CALLS" && ok || bad "V5 one issue POST: $(cat "$CALLS")"
eq_in=$(tail -1 "$GHF/inputs.log" | jq -c --arg m "$(marker)" '{title, labels, marked: (.body | endswith($m))}')
[ "$eq_in" = '{"title":"Archie: box-hung on box:orgo-7","labels":["ai-build"],"marked":true}' ] && ok || bad "V5 the issue body: $eq_in"
newcase v5b
jq -nc --arg m "$(marker)" '[range(0; 100) | {body: "other"}] + [{body: ("filed " + $m)}]' > "$GHF/open-issues.json"
run "$(mk file_ticket '{"title":"t","lines":["x"]}')"
expect "V5 an open issue on page 2 has the marker" done marker-found; [ "$(writes)" = 0 ] && ok || bad "V5 marker: 0 writes"
grep -q "^gh GET repos/$SLUG/issues?state=open&labels=ai-build&per_page=100&page=2$" "$CALLS" && ok || bad "V5 page 2 read with &: $(cat "$CALLS")"
newcase v5c; touch "$GHF/fail-write"; run "$(mk file_ticket '{"title":"t","lines":["x"]}')"; expect "V5 POST fails" failed file-ticket-failed

# ── V7 main's rebuild and ask arms (BH-8736) through the union UB_ACTIONS ──
printf '#!/bin/bash\necho "launch-fastpath $*" >> "$CALLS"\nexit 0\n' > "$T/stubbin/launch-fastpath.sh"
chmod +x "$T/stubbin/launch-fastpath.sh"
# mkt <action> <args-json> — one ticket record, the lifecycle collector's subject.
mkt() { mk "$1" "$2" '.subject_kind = "build" | .subject = "cromford:BH-9201" | .class = "triage-launch" | del(.pr, .head)'; }
# v7 <nolib|lib> <record> — ub_act in a subshell with card.sh and (lib) a
# lifecycle_transition stub; prints "<outcome>|<detail>", UB_ACT_CARD to card.json.
v7() {
  ( [ "$1" = nolib ] || lifecycle_transition() { echo "lifecycle_transition $1 $2 $3 $4" >> "$CALLS"; return 0; }
    # shellcheck source=../bin/lib/unblock/card.sh
    . "$DIR/bin/lib/unblock/card.sh" || exit 1
    ub_act "$2" > "$HARNESS/out.txt" 2>&1
    printf '%s' "$UB_ACT_CARD" > "$HARNESS/card.json"
    printf '%s|%s' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL" )
}
newcase v7a; out=$(v7 lib "$(mkt rebuild '{"key":"BH-9201"}')")
[ "$out" = "done|launched" ] && ok || bad "V7 rebuild: done launched, got $out"
[ "$(grep -E '^(lifecycle_transition|launch-fastpath) ' "$CALLS" | tr '\n' ';')" = "lifecycle_transition cromford BH-9201 planned lifecycle;launch-fastpath cromford BH-9201;" ] \
  && ok || bad "V7 rebuild: the phase, then the launch: $(tr '\n' '|' < "$CALLS")"
newcase v7b; out=$(UNBLOCK_ACT=0 v7 lib "$(mkt rebuild '{"key":"BH-9201"}')")
[ "$out" = "would|WOULD_REBUILD" ] && [ "$(grep -c '^lifecycle_transition\|^launch-fastpath' "$CALLS")" = 0 ] && ok || bad "V7 rebuild shadow: $out $(cat "$CALLS")"
newcase v7c; out=$(v7 nolib "$(mkt rebuild '{"key":"BH-9201"}')")
[ "$out" = "failed|lifecycle-libs-not-loaded" ] && ok || bad "V7 rebuild with no lifecycle lib: $out"
newcase v7d; out=$(v7 lib "$(mkt ask '{"key":"BH-9201","question":"Which fee field does the rep set?","age_min":1500}')")
CID=$(jq -r .id "$HARNESS/card.json" 2>/dev/null)
[ "$out" = "escalated|card $CID" ] && [[ $CID =~ ^u-[0-9a-f]{6}$ ]] && ok || bad "V7 ask: escalated card <id>, got $out ($CID)"
[ "$(grep -c '^lane-alert .*--critical' "$CALLS")" = 1 ] && ok || bad "V7 ask: one critical alert: $(tr '\n' '|' < "$CALLS")"
[ "$(jq -c '[.lifecycle, has("route")]' "$HARNESS/card.json" 2>/dev/null)" = '[{"project":"cromford","ticket_key":"BH-9201"},false]' ] \
  && ok || bad "V7 ask: the card carries .lifecycle and no .route: $(cat "$HARNESS/card.json")"
[ "$(grep -c '^lifecycle_transition\|^launch-fastpath' "$CALLS")" = 0 ] && ok || bad "V7 ask: no transition, no launch"

# ── V6 ───────────────────────────────────────────────────────────────────────
[ "$(command -v gh)" = "$T/pathbin/gh" ] && ok || bad "V6 the only gh is the stub"

echo "unblock-act-levers.bh-8817: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

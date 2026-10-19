#!/bin/bash
# tests/lead-enqueue-body-lint.bh-5790-test.sh — BH-5790: the lead-review
# enqueue runs the PR-body section rules (catalog/pr-self-check.tsv, body-*)
# before it asks for a review, so no Opus round is spent on a body that is
# missing a section the review would BLOCK on.
#
#   E1  a body with no `## Why`: not requested, one comment naming body-why
#   E2  a complete body: requested (acceptance test 3)
#   E3  PR_SELF_CHECK=0: E1's body is requested
#   E4  the linked issue's Done when names a probe and the body shows none:
#       held, naming body-live-probe; the issue is read once a tick
#   E5  a `note` body rule (body-mutation, here made to fire on every PR):
#       requested at once with "self-check notes: ..." in the scope notes, no
#       comment, and the re-confirm sends the same notes
#
# The rig was the BH-5798 self-check suite's (deleted in BH-7235): the script runs
# WHOLE against a scratch harness, a real git origin and hub clone, and stubs
# for curl (the jobs worker) and gh (REST, now also the linked issue).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-body-lint.bh-5790-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# ───────────── the fixture repo: the PR adds bin/a.sh and its plan ─────────────
OR="$T/origin/demo-os.git"; WK="$T/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
echo base > "$WK/README"; git -C "$WK" add -A; git -C "$WK" commit -qm base
git -C "$WK" checkout -qb pr; mkdir -p "$WK/bin" "$WK/.harness/specs/BH-41"
printf '# plan\n\n## Files to touch\n- `bin/a.sh`\n\n## Acceptance tests\n- a test\n' > "$WK/.harness/specs/BH-41/plan.md"
echo a > "$WK/bin/a.sh"; git -C "$WK" add -A; git -C "$WK" commit -qm "the pr"; C=$(git -C "$WK" rev-parse HEAD)
git -C "$WK" push -q "$OR" main pr
A="$C"
Q="$T/hq"; mkdir -p "$Q/bin/lib/jobs" "$Q/state" "$Q/logs" "$Q/catalog/lanes.d" "$T/cfg" "$T/qrepos" "$T/log" "$T/qbin"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/post"
exit 0
EOF
cat > "$Q/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/qalerts"
EOF
chmod +x "$Q/bin/lead-verdict.sh" "$Q/bin/lane-alert.sh"
scratch_install_closure bin/lead-review-enqueue.sh "$Q" >/dev/null || bad "closure of bin/lead-review-enqueue.sh"
scratch_install_closure bin/jobs-client.sh "$Q" >/dev/null || bad "closure of bin/jobs-client.sh"
scratch_install_closure bin/lead-review.sh "$Q" >/dev/null || bad "closure of bin/lead-review.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$SRC/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/qbin" "$LPPF" "$LPPDOWN"
cp "$SRC/catalog/pr-self-check.tsv" "$Q/catalog/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$Q/fleet.conf"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' >> "$Q/fleet.conf"
git clone -q "$OR" "$T/qrepos/demo-os"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"

# The jobs worker. A second POST for a (pr, head) it already holds answers
# existing:true, the way the real worker's ON CONFLICT does.
cat > "$T/qbin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/qworker"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*standing_only=1*)
    h=\$(printf '%s' "\$p" | tr '&?' '\n\n' | sed -n 's/^head_sha=//p')
    out=\$(jq -c --arg h "\$h" '{standing:([.rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | last // null),
      rows:[], truncated:false}' "$T/vrows.json") ;;
  "GET /api/verdicts?"*) out=\$(cat "$T/vrows.json") ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true}' ;;
  "POST /api/lead-reviews")
    h=\$(jq -r .head_sha <<<"\$body")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif grep -qxF "\$h" "$T/log/held" 2>/dev/null; then out=\$(jq -c '{existing:true, request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body")
    else echo "\$h" >> "$T/log/held"; printf '%s\n' "\$body" >> "$T/log/created"
      code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/qbin/gh" <<EOF
#!/bin/bash
H=\$(cat "$T/qhead"); SL=\$(cat "$T/slug")
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" --arg sl "\$SL" '[{number:41, html_url:("https://github.com/"+\$sl+"/pull/41"), title:"t", draft:false, state:"open",
      user:{login:"operator",type:"User"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/"*"/pulls/41"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$H" --arg u "\$(cat "$T/author" 2>/dev/null || echo operator)" --rawfile b "$T/prbody" '{head:{sha:\$s,ref:"ticket/bh-41"},base:{ref:"main"},user:{login:\$u},body:\$b}' ;;
  *"-X GET repos/example-org/"*"/issues/41"*)
    echo x >> "$T/log/issueread"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --rawfile b "$T/issue" '{number:41, body:\$b}' ;;
  *"-X POST repos/example-org/"*"/issues/41/comments"*)
    echo post >> "$T/log/comments"
    f=\$(printf '%s' "\$*" | grep -oE 'body=@[^ ]+' | cut -c7-); cat "\$f" >> "$T/log/comment-bodies" 2>/dev/null
    printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/example-org/"*"/contents/.mergify.yml"*)
    echo x >> "$T/log/ciread"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/"*"/commits/"*"/check-runs"*)
    echo x >> "$T/log/ciread"
    st=\$(cat "$T/ci" 2>/dev/null || echo green)
    case "\$st" in
      green)   s=completed; c=success ;;
      pending) s=in_progress; c=null ;;
      *)       s=completed; c=failure ;;
    esac
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$H" --arg s "\$s" --arg c "\$c" '{total_count:1, check_runs:[{name:"CI", head_sha:\$h, status:\$s,
      conclusion:(if \$c == "null" then null else \$c end), app:{slug:"github-actions"}}]}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    if [ -f "$T/cmp.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"fix: outside"}}],"files":[]}\n'; fi ;;
esac
exit 0
EOF
chmod +x "$T/qbin/curl" "$T/qbin/gh"

QLOG="$Q/logs/lead-review-enqueue.log"
# reset <head> [lead word on A] [lead word on head]
reset() {
  printf '## Done when\n- the suite passes\n' > "$T/issue"; rm -f "$T/log/issueread"
  rm -f "$T/log"/q* "$T/log/comments" "$T/log/comment-bodies" "$T/log/post" "$T/log/created" "$T/log/held" "$T/log/ciread" "$T/ci" "$T/author" "$T/cmp.json" "$QLOG"
  echo example-org/demo-os > "$T/slug"; scratch_rm "$T/set"; mkdir -p "$T/set"
  scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo box-hub > "$Q/state/box-name"
  scratch_rm "$T/jv"; mkdir -p "$T/jv"
  echo "$1" > "$T/qhead"
  jq -nc --arg s "$A" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg a "$A" --arg h "$1" --arg wa "${2:-}" --arg wh "${3:-}" '{rows:([{id:4,repo:"example-org/demo-os",pr:41,head_sha:$a,source:"box",verdict:"APPROVE",note:""}]
    + (if $wa == "" then [] else [{id:5,repo:"example-org/demo-os",pr:41,head_sha:$a,source:"lead",verdict:$wa,note:"lead-review:lr-3"}] end)
    + (if $wh == "" then [] else [{id:6,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"lead",verdict:$wh,note:"lead-review:lr-4"}] end)),
    truncated:false}' > "$T/vrows.json"
}
tick() {
  ( cd "$T" && PATH="$T/qbin:$PATH" HARNESS="$Q" REPOS_ROOT="$T/qrepos" FLEET_CONF="$Q/fleet.conf" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS="$(cat "$T/slug")" \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$Q/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
created() { [ -f "$T/log/created" ] && wc -l < "$T/log/created" | tr -d ' ' || echo 0; }
body1() { head -1 "$T/log/created" 2>/dev/null; }
ciread() { [ -f "$T/log/ciread" ] && wc -l < "$T/log/ciread" | tr -d ' ' || echo 0; }
summ() { grep ' tick repos=' "$QLOG" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }


approve() { # approve <head> <body-text>
  reset "$1"
  printf '%s\n' "$2" > "$T/prbody"
  jq -nc --arg s "$1" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  jq -nc --arg h "$1" '{rows:[{id:4,repo:"example-org/demo-os",pr:41,head_sha:$h,source:"box",verdict:"APPROVE",note:""}],truncated:false}' > "$T/vrows.json"
}
comments() { [ -f "$T/log/comments" ] && wc -l < "$T/log/comments" | tr -d ' ' || echo 0; }
WHY=$'## Why\nThe merge queue drops this PR shape every batch today, and nothing says so.\n'
ACC=$'## Acceptance tests\n| case | result |\n|---|---|\n| E1 | pass |\n'
NOWHY="Refs #41

$ACC
<!-- evidence-head: $C -->"
FULL="Refs #41

$WHY
$ACC
<!-- evidence-head: $C -->"

# ── E1: no Why: held, one comment naming body-why ──
approve "$C" "$NOWHY"; tick
[ "$(created)" = 0 ] && ok || bad "E1 a body with no Why was requested: $(body1)"
[ "$(comments)" = 1 ] && grep -q "body-why" "$T/log/comment-bodies" 2>/dev/null && ok || bad "E1 want one comment naming body-why, got $(comments): $(cat "$T/log/comment-bodies" 2>/dev/null)"
hasw skipped_selfcheck=1 && ok || bad "E1 summary: $(summ)"

# ── E2: a complete body: requested (acceptance test 3) ──
approve "$C" "$FULL"; tick
[ "$(created)" = 1 ] && [ "$(comments)" = 0 ] && ok || bad "E2 a complete body must be requested with no comment (created=$(created) comments=$(comments)): $(tail -4 "$QLOG")"

# ── E3: the knob off ──
approve "$C" "$NOWHY"; PR_SELF_CHECK=0 tick
[ "$(created)" = 1 ] && ok || bad "E3 PR_SELF_CHECK=0 must request as before: $(summ)"

# ── E4: the linked issue names a probe ──
approve "$C" "$FULL"; printf '## Done when\n- the live hub probe `bin/hub-lease.sh check` answers rc=0\n' > "$T/issue"; tick
[ "$(created)" = 0 ] && grep -q "body-live-probe" "$T/log/comment-bodies" 2>/dev/null && ok || bad "E4 a ticket probe with no probe output was requested or not named (created=$(created)): $(cat "$T/log/comment-bodies" 2>/dev/null)"
[ "$(cat "$T/log/issueread" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && ok || bad "E4 the issue was read $(cat "$T/log/issueread" 2>/dev/null | wc -l) times in one tick"

# ── E5: a `note` body rule rides in the request notes and holds nothing ──
awk -F'\t' -v OFS='\t' '$1 == "body-mutation" {$3 = "always"} {print}' "$Q/catalog/pr-self-check.tsv" > "$T/cat-note.tsv"
approve "$C" "$FULL"; PR_SELF_CHECK_CATALOG="$T/cat-note.tsv" tick
[ "$(created)" = 1 ] && [ "$(comments)" = 0 ] && ok || bad "E5 a note rule held the PR or commented (created=$(created) comments=$(comments))"
jq -r .scope_notes "$T/log/created" 2>/dev/null | grep -q "self-check notes: body-mutation: the body is missing" && ok \
  || bad "E5 the request notes do not carry the note: $(cat "$T/log/created" 2>/dev/null)"
NOTE1=$(jq -r .scope_notes "$T/log/created" 2>/dev/null | head -1)
rm -f "$T/log/qworker"; PR_SELF_CHECK_CATALOG="$T/cat-note.tsv" tick
grep '^POST /api/lead-reviews ' "$T/log/qworker" 2>/dev/null | head -1 | grep -qF "self-check notes: body-mutation" && ok \
  || bad "E5 the re-confirm did not send the same notes: $(grep '^POST /api/lead-reviews' "$T/log/qworker" 2>/dev/null | head -1 | cut -c1-300)"

echo "lead-enqueue-body-lint.bh-5790: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

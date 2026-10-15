#!/bin/bash
# tests/lead-enqueue-self-check-zero.bh-5905-test.sh — BH-5905: the
# pre-review self-check comment when PR_SELF_CHECK_MAX_WAIT_MIN=0.
#
# WHY. With the wait at 0 the lead review is requested on the same tick, but
# the comment said "no lead review is requested yet" and "After 0 minutes the
# lead review is requested anyway". Both were false. At 0 the comment says the
# review is requested now.
#
#   Z1  wait 0, a refused body: one comment; it names closes-not-met and says
#       "The lead review is requested now"; no "After 0 minutes", no
#       "no lead review is requested yet"
#   Z2  the same tick requests the review, and the scope note carries
#       `self-check:`
#   Z3  the default wait (unset): the comment still says "After 30 minutes"
#
# The rig is tests/lead-enqueue-self-check.bh-5798-test.sh's, copied: the
# script runs WHOLE against a scratch harness, with curl and gh stubs.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-self-check-zero.bh-5905-test.sh
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
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV. The lead protected
# paths are the lead_protected_paths rows (tests/lib/lpp-stub.sh); the rows are
# the cromford globs the TSV held (the fixture).
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
  *"/api/lead-protected-paths"*) lpp-answer "\$m" "\$url" "\$body"; exit 0 ;;
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
BAD="Closes #41

## Acceptance self-check
- [ ] a test: not met (the seed returned 0 rows)

<!-- evidence-head: $C -->"
GOOD="Refs #41

## Acceptance self-check
- [ ] a test: not met (the seed returned 0 rows)

<!-- evidence-head: $C -->"

# ── Z1: wait 0: the comment says the review is requested now ──
approve "$C" "$BAD"; PR_SELF_CHECK_MAX_WAIT_MIN=0 tick
[ "$RC" -eq 0 ] && ok || bad "Z1 rc=$RC out=$(cat "$T/out")"
[ "$(comments)" = 1 ] && ok || bad "Z1 want one comment, got $(comments)"
CB=$(cat "$T/log/comment-bodies" 2>/dev/null)
grep -q "closes-not-met" <<<"$CB" && ok || bad "Z1 the comment must name closes-not-met: $CB"
grep -qF "The lead review is requested now" <<<"$CB" && ok || bad "Z1 the comment must say the review is requested now: $CB"
grep -qF "After 0 minutes" <<<"$CB" && bad "Z1 the comment says 'After 0 minutes': $CB" || ok
grep -qF "no lead review is requested yet" <<<"$CB" && bad "Z1 the comment says no review is requested yet: $CB" || ok

# ── Z2: the same tick requests the review, with the findings in the note ──
[ "$(created)" = 1 ] && ok || bad "Z2 wait 0 must request the review on the same tick: $(summ) $(tail -4 "$QLOG")"
jq -r .scope_notes "$T/log/created" 2>/dev/null | grep -q "self-check: " && ok || bad "Z2 the scope note must carry the findings: $(cat "$T/log/created" 2>/dev/null)"

# ── Z3: the default wait keeps today's words ──
approve "$C" "$BAD"; tick
grep -qF "After 30 minutes the lead review is requested anyway" "$T/log/comment-bodies" 2>/dev/null \
  && ok || bad "Z3 the default comment changed: $(cat "$T/log/comment-bodies" 2>/dev/null)"
[ "$(created)" = 0 ] && ok || bad "Z3 the default wait must hold the request (created=$(created))"

echo "lead-enqueue-self-check-zero.bh-5905: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

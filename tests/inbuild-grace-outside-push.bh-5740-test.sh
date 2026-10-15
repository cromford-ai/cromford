#!/bin/bash
# tests/inbuild-grace-outside-push.bh-5740-test.sh — BH-5740: the BH-5023
# in-build grace holds a medium head only while a build job for that PR is
# running or queued and bound to that head. A head pushed from outside a build
# (a person, the Mac, a main merge, a conflict fix) is requested in the same tick.
# "$DIR/bin/lead-review-enqueue.sh" runs WHOLE (`tick`) against a scratch harness
# carrying its real bin closure (scratch_install_closure). Stubbed:
#   * curl — the jobs worker: GET /api/verdict?pr= from $T/jv/<n>.json (404 when
#            absent; every call counted in $T/log/vcount; from call N on a 500
#            when $T/v500-from holds N), settings from $T/set/<key>, standing
#            verdicts none, POST /api/lead-reviews recorded in $T/log/created.
#   * gh   — the PR list ($T/prs.json), the PR, the compare (one modified
#            bin/lib/thing.sh 40/10 = medium), .mergify.yml and green check runs.
# Every case: example-org/cromford, risk tier enforce, medium, live head B.
#   G1  no build job (404): requested in the same tick, no marker, one skipped line.
#   G2  build running bound to B: held, as before.
#   G3  build done on an older head A: requested, `is done`.
#   G4  build running bound to A: requested, `is bound to <A12>`.
#   G5  build running bound to B, provisional row: held. G5b queued_for_retry: held.
#   G6  build done on B: requested. G6b a review job running on B: requested.
#   G7  the grace's job read answers 500: held, one `read failed` line.
#   G8  grace row 0: requested, no job-read decision line.
#   G9  two outside-pushed medium PRs, cap 1: requested=1 deferred=1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/inbuild-grace-outside-push.bh-5740-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_REVIEW_REQUIRE_BUILDER_APPROVE BOX_NAME JOBS_BOX HUB_BOX_NAME

H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog/lanes.d" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/repos"
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || exit 1
cp "$DIR/catalog/lanes.d/_lib.json" "$DIR/catalog/lanes.d/_lib.lead-delta.json" "$H/catalog/lanes.d/"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"

A=$(printf 'a%.0s' {1..40}); A12=${A:0:12}
B=$(printf 'b%.0s' {1..40}); B12=${B:0:12}

cat > "$T/fakebin/curl" <<EOF
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
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"; echo "\$n" >> "$T/log/vcount"; k=\$(wc -l < "$T/log/vcount")
    if [ -f "$T/v500-from" ] && [ "\$k" -ge "\$(cat "$T/v500-from")" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json")
    else code=404; out='{"error":"no job has recorded this PR"}'; fi ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true}' ;;
  "POST /api/lead-reviews")
    k=\$(jq -r '"\(.pr) \(.head_sha)"' <<<"\$body")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif grep -qxF "\$k" "$T/log/held" 2>/dev/null; then out=\$(jq -c '{existing:true, request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body")
    else echo "\$k" >> "$T/log/held"; printf '%s\n' "\$body" >> "$T/log/created"
      code=201; out=\$(jq -c '{request:(. + {id:"lr-9", status:"requested"})}' <<<"\$body"); fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/"*"/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s},base:{ref:"main"},user:{login:"cromford[bot]"}}' ;;
  *"-X GET repos/example-org/"*"/contents/.mergify.yml"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/"*"/commits/"*"/check-runs"*)
    a="\$*"; h="\${a##*/commits/}"; h="\${h%%/*}"
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$h" '{total_count:1, check_runs:[{name:"CI", head_sha:\$h, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"fix: outside"}}],
      files:[{filename:"bin/lib/thing.sh", status:"modified", additions:40, deletions:10}]}' ;;
  *"-X POST repos/example-org/"*"/statuses/"*)
    printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh"

LOGF="$H/logs/lead-review-enqueue.log"
WD="$H/state/lead-review-enqueue"
reset() {
  rm -f "$T/log"/* "$T/v500-from" "$LOGF"
  scratch_rm "$H/state"; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"
  for d in jv head set; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'enforce' > "$T/set/risk_tier.mode.example-org.cromford"; printf 'operator' > "$T/set/lead_pr_authors"
  echo '[]' > "$T/prs.json"
  pr 41 "$B"
}
pr() { # pr <n> <head>
  jq -c --argjson n "$1" --arg h "$2" '[.[] | select(.number != $n)] + [{number:$n, html_url:("https://github.com/example-org/cromford/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# jv <reviewed_sha|""> <kind> <status> [settled true|false] — PR 41's /api/verdict
# answer, the shape worker/jobs/src/routes/verdict.js returns (.job is the
# ledger's build-first jobs row, .reviewed_sha the verdict detail's head).
jv() {
  jq -nc --arg s "$1" --arg k "$2" --arg st "$3" --argjson se "${4:-true}" '{pr:"https://github.com/example-org/cromford/pull/41",
    job_id:"job-b", job:{id:"job-b", kind:$k, status:$st, project:"cromford"},
    verdict:"APPROVE", tier:"2", provenance:"claude", reviewed_sha:(if $s == "" then null else $s end),
    artifacts:[{artifact_kind:"verdict", artifact_ref:"APPROVE", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:$se}|tojson)}]}' > "$T/jv/41.json"
}
tick() {
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" \
      LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" LEAD_REVIEW_AUTO_REPOS=example-org/cromford LANE_GATE_DISABLE=1 \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK="${CAP:-5}" LEAD_REVIEW_MAX_PER_PR_DAY=4 JOBS_URL=https://jobs.test \
      HARNESS_SECRET=test-secret JOBS_RETRIES=0 GH_ETAG=0 \
      bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?
}
created() { [ -f "$T/log/created" ] && wc -l < "$T/log/created" | tr -d ' ' || echo 0; }
body1() { head -1 "$T/log/created" 2>/dev/null; }
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
hasw() { summ | grep -qw -- "$1"; }
mark() { [ -e "$WD/inbuild-wait-example-org_cromford-${1:-41}-$B12" ]; }
skipped() { grep -c "inbuild-grace skipped #${1:-41} head=$B12: no build job for this head" "$LOGF" 2>/dev/null; }
skipline() { grep "inbuild-grace skipped #41 head=$B12" "$LOGF" 2>/dev/null | head -1; }
# requested <label> <why>: one lead request for B in this tick, no marker, one skipped line naming <why>.
requested() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc=$RC out=$(cat "$T/out")"
  [ "$(created)" = 1 ] && [ "$(jq -r .head_sha <<<"$(body1)" 2>/dev/null)" = "$B" ] && ok \
    || bad "$1 want one lead request for B in the same tick, got $(created): $(summ) log: $(tail -4 "$LOGF" 2>/dev/null)"
  mark && bad "$1 an in-build wait marker was written for a head no build reviews" || ok
  [ "$(skipped)" = 1 ] && ok || bad "$1 want one skipped line, got $(skipped): $(tail -4 "$LOGF" 2>/dev/null)"
  case "$(skipline)" in *"$2"*) ok ;; *) bad "$1 the skipped line does not say '$2': $(skipline)" ;; esac
  hasw risk_inbuild_wait=0 && hasw risk_medium=1 && ok || bad "$1 summary: $(summ)"
}
# held <label>: nothing requested, the marker is there, one awaiting line, no skipped line.
held() {
  [ "$RC" -eq 0 ] && ok || bad "$1 rc=$RC out=$(cat "$T/out")"
  [ "$(created)" = 0 ] && ok || bad "$1 a head a live build reviews was requested: $(body1)"
  mark && ok || bad "$1 no in-build wait marker"
  grep -Eq "@$B12: awaiting the in-build lead-grade review \(3[0-9]{3}s left\)" "$LOGF" && ok || bad "$1 no awaiting line: $(tail -4 "$LOGF")"
  [ "$(skipped)" = 0 ] && ok || bad "$1 a skipped line on a held head: $(skipline)"
  hasw risk_inbuild_wait=1 && ok || bad "$1 summary: $(summ)"
}

# ── G1 (red first): no job recorded the PR ──
reset; tick; requested G1 "no job recorded the PR"
hasw requested=1 && ok || bad "G1 summary: $(summ)"

# ── G2: a build running, bound to B ──
reset; jv "$B" build running; tick; held G2

# ── G3 (red first): a build done on the older head A ──
reset; jv "$A" build done; tick; requested G3 "is done"

# ── G4: a build still running, bound to A ──
reset; jv "$A" build running; tick; requested G4 "is bound to $A12"

# ── G5: a provisional build row on B; G5b queued_for_retry on B ──
reset; jv "$B" build running false; tick; held G5
reset; jv "$B" build queued_for_retry; tick; held G5b

# ── G6: a build done on B; G6b a review job running on B ──
reset; jv "$B" build done; tick; requested G6 "is done"
reset; jv "$B" review running; tick; requested G6b "not a build"

# ── G7: the grace's job read fails (call 2 on): the grace holds as before ──
reset; jv "$B" build running; echo 2 > "$T/v500-from"; tick; held G7
grep -q "@$B12: build job read failed (rc [0-9]*); the in-build grace holds as before" "$LOGF" && ok || bad "G7 no read-failed line: $(tail -4 "$LOGF")"

# ── G8: a grace row of 0 holds nothing and reads no job ──
reset; jv "$B" build running; printf '0' > "$T/set/risk_tier.inbuild_grace_s"; tick
[ "$(created)" = 1 ] && ok || bad "G8 want one request, got $(created): $(tail -4 "$LOGF")"
[ "$(skipped)" = 0 ] && ok || bad "G8 a skipped line with the grace off: $(skipline)"
grep -q 'awaiting the in-build' "$LOGF" && bad "G8 an awaiting line with the grace off" || ok

# ── G9: two outside-pushed medium PRs, cap 1: the cap still bounds the burst ──
reset; pr 42 "$B"; CAP=1 tick
[ "$(created)" = 1 ] && ok || bad "G9 want one request, got $(created)"
hasw requested=1 && hasw deferred=1 && ok || bad "G9 summary: $(summ)"
[ "$(skipped 41)" = 1 ] && [ "$(skipped 42)" = 1 ] && ok || bad "G9 want a skipped line per PR: $(grep 'inbuild-grace skipped' "$LOGF")"

# ── secrets stay out of the log ──
grep -rqE 'test-secret|lead-test-token' "$H/logs" "$T/out" && bad "a secret reached a log" || ok

echo "inbuild-grace-outside-push.bh-5740: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

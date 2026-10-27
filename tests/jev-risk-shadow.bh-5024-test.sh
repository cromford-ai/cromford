#!/bin/bash
# tests/jev-risk-shadow.bh-5024-test.sh — BH-5024 (BH-4973.3): Jev, a second
# opinion on the rule-based risk tier, in shadow only. The production entry
# point runs WHOLE against a scratch harness carrying its real bin closure:
#   * "$DIR/bin/jev-risk.sh" ask — the ONLY code path that spends on Jev:
#     claim in the ledger, call TypeSafe, write the answer locally, settle.
# The shadow hook (gate 60 on the worklist) is
# tests/lead-gates-risk-jev-ports.bh-8629-test.sh RJ4-RJ8 and
# tests/lead-gates-risk.bh-5875-test.sh R13, R14.
# Stubbed:
#   * curl — a STATEFUL jobs worker (the tests/lead-review-enqueue-risk.bh-5022
#            one) plus the jev-risk ledger ($T/jev.json, the worker's claim and
#            settle rules: 201/200/409 terminal|in_flight|attempt_cap, max 2
#            attempts; a settle 503 while $T/settle503 holds a count), settings
#            from $T/set/<key> (a 500 from $T/set500/<key>), and the TypeSafe
#            vendor at https://typesafe.test: every call is one line in
#            $T/log/jev-hits; it answers $T/jev-answer with HTTP $T/jev-code
#            (default 200) after $T/jev-sleep seconds.
#   * gh, bin/lead-verdict.sh, bin/lane-alert.sh, bin/agent-call.sh — as in BH-5022.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/jev-risk-shadow.bh-5024-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

[ -f "$DIR/bin/jev-risk.sh" ] && ok || bad "bin/jev-risk.sh does not exist"
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/repos"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
[ -f "$DIR/bin/jev-risk.sh" ] && { scratch_install_closure bin/jev-risk.sh "$H" >/dev/null || exit 1; }
mkdir -p "$H/catalog"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

SHA=$(printf 'a%.0s' {1..40})
H2=$(printf 'b%.0s' {1..40})
KEY=tsk-secret-5024-do-not-log

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""; outf=""; maxt=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
    -o) outf="\$a" ;;
    --max-time|-m) maxt="\$a" ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
# ── the TypeSafe vendor ──
case "\$url" in https://typesafe.test*)
  printf '%s\n' "\$*" >> "$T/log/jev-argv"
  printf '%s\n' "\$hdrs" | grep -i '^authorization:' >> "$T/log/jev-auth"
  printf '%s\n' "\$body" >> "$T/log/jev-bodies"
  echo "\$m \$url" >> "$T/log/jev-hits"
  [ -f "$T/jev-sleep" ] && sleep "\$(cat "$T/jev-sleep")"
  # a connection error or timeout: real curl writes 000 and exits non-zero
  if [ -f "$T/jev-curlrc" ]; then printf '000'; exit "\$(cat "$T/jev-curlrc")"; fi
  code=\$(cat "$T/jev-code" 2>/dev/null || echo 200)
  if [ -n "\$outf" ]; then cat "$T/jev-answer" > "\$outf" 2>/dev/null; else cat "$T/jev-answer" 2>/dev/null; fi
  printf '%s' "\$code"
  exit 0 ;;
esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
[ -f "$T/jev.json" ] || echo '[]' > "$T/jev.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
jkey() { jq -r '[.repo, (.pr|tostring), (.head_sha|ascii_downcase), .question_version] | join("|")' <<<"\$body"; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/risk_tier.mode.example-org.cromford")
    if [ -f "$T/mode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/mode")" '{setting:{key:"risk_tier.mode.example-org.cromford",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set500/\$k" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true,"id":1}' ;;
  "POST /api/jev-risk/claim")
    if [ -f "$T/claim503" ]; then printf '{"error":"down"}\n503'; exit 0; fi
    k=\$(jkey); row=\$(jq -c --arg k "\$k" '[.[] | select(.k == \$k)] | first // empty' "$T/jev.json")
    if [ -z "\$row" ]; then
      row=\$(jq -c --arg k "\$k" '{k:\$k, repo, pr, head_sha:(.head_sha|ascii_downcase), question_version, rule_tier, caller, model, status:"claimed", attempts:1}' <<<"\$body")
      jq -c --argjson r "\$row" '. + [\$r]' "$T/jev.json" > "$T/jev.tmp" && mv "$T/jev.tmp" "$T/jev.json"
      code=201; out=\$(jq -c '{ok:true,row:.}' <<<"\$row")
    else
      st=\$(jq -r .status <<<"\$row"); at=\$(jq -r .attempts <<<"\$row")
      if [ "\$st" = ok ] || [ "\$st" = empty ]; then code=409; out=\$(jq -c --arg s "\$st" '{error:"terminal",status:\$s,row:.}' <<<"\$row")
      elif [ "\$st" = claimed ]; then code=409; out=\$(jq -c '{error:"in_flight",status:"claimed",row:.}' <<<"\$row")
      elif [ "\$at" -ge 2 ]; then code=409; out=\$(jq -c '{error:"attempt_cap",status:.status,row:.}' <<<"\$row")
      else
        jq -c --arg k "\$k" 'map(if .k == \$k then .status = "claimed" | .attempts += 1 else . end)' "$T/jev.json" > "$T/jev.tmp" && mv "$T/jev.tmp" "$T/jev.json"
        out=\$(jq -c --arg k "\$k" '{ok:true,row:([.[] | select(.k == \$k)] | first)}' "$T/jev.json")
      fi
    fi ;;
  "POST /api/jev-risk/settle")
    n503=\$(cat "$T/settle503" 2>/dev/null || echo 0)
    if [ "\$n503" -gt 0 ]; then echo \$((n503 - 1)) > "$T/settle503"; code=503; out='{"error":"down"}'
    else
      k=\$(jkey); row=\$(jq -c --arg k "\$k" '[.[] | select(.k == \$k)] | first // empty' "$T/jev.json")
      st=\$(jq -r '.status // empty' <<<"\$row"); want=\$(jq -r .status <<<"\$body")
      at=\$(jq -r '.attempts // empty' <<<"\$row"); bat=\$(jq -r '.attempts // empty' <<<"\$body")
      echo "\$bat" >> "$T/log/settle-attempts"
      if [ -z "\$row" ]; then code=404; out='{"error":"no claim for this head"}'
      elif [ "\$st" = claimed ] && [ "\$bat" != "\$at" ]; then code=409; out=\$(jq -c '{error:"superseded",status:"claimed",row:.}' <<<"\$row")
      elif [ "\$st" = claimed ]; then
        jq -c --arg k "\$k" --argjson b "\$body" 'map(if .k == \$k then .status = \$b.status | .jev_tier = \$b.jev_tier | .jev_prob = \$b.jev_prob | .raw = \$b.raw | .error = \$b.error else . end)' "$T/jev.json" > "$T/jev.tmp" && mv "$T/jev.tmp" "$T/jev.json"
        out=\$(jq -c --arg k "\$k" '{ok:true,row:([.[] | select(.k == \$k)] | first)}' "$T/jev.json")
      elif [ "\$st" = "\$want" ]; then out=\$(jq -c '{ok:true,replay:true,row:.}' <<<"\$row")
      else code=409; out=\$(jq -c '{error:"not claimed",row:.}' <<<"\$row"); fi
    fi ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/cromford/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/cromford/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s},base:{ref:"main"},user:{login:"cromford[bot]"}}' ;;
  *"-X GET repos/example-org/cromford/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json" ;;
  *"-X POST repos/example-org/cromford/statuses/"*)
    printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit \$(cat "$T/lvrc" 2>/dev/null || echo 0)
EOF
for s in lane-alert agent-call; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/%s"\nexit 0\n' "$T" "$s" > "$H/bin/$s.sh"; done
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/cromford \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/repos" TYPESAFE_API_KEY="$KEY"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

# cmpx <head> <files json: [[name, add, del]...]> — every file carries a patch line.
cmpx() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[$f[] | {filename:.[0], status:"modified", additions:.[1], deletions:.[2],
      patch:("@@ -1 +1 @@\n-old line\n+echo hello-patch-" + .[0])}]}' > "$T/cmp/$1.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{lrrows.json,jev.json,mode,lvrc,jev-answer,jev-code,jev-curlrc,jev-sleep,settle503,claim503} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head cmp set set500; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'operator' > "$T/set/lead_pr_authors"
  # BH-5023 (on main since this suite was written) holds a medium head under
  # enforce for the in-build lead review. These cases test the lead request
  # itself, so the grace is 0 and the hold never applies.
  printf 0 > "$T/set/risk_tier.inbuild_grace_s"
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
# jev_on [mode-row] — the vendor configured, and the jev_risk.mode row (default shadow)
jev_on() { printf 'https://typesafe.test/v1/choice' > "$T/set/jev_risk.api_url"; printf '%s' "${1-shadow}" > "$T/set/jev_risk.mode"; }
answer() { printf '%s' "$1" > "$T/jev-answer"; }
MED='[["bin/lib/thing.sh",40,10]]'
CMPF="$T/cmp-ask.json"
ask() { ( cd "$T" && bash "$H/bin/jev-risk.sh" ask example-org/cromford 41 "${1:-$SHA}" "${2:-medium}" "$CMPF" ) > "$T/askout" 2>"$T/askerr"; ARC=$?; AOUT=$(cat "$T/askout"); }
hits() { [ -f "$T/log/jev-hits" ] && wc -l < "$T/log/jev-hits" | tr -d ' ' || echo 0; }
claims() { wlog | grep -c '^POST /api/jev-risk/claim '; }
jrow() { jq -r --arg h "${2:-$SHA}" "[.[] | select(.head_sha == \$h)] | first | $1" "$T/jev.json" 2>/dev/null; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
SPOOL="$H/state/jev-risk"

# ══ the client: bin/jev-risk.sh ask ══
reset; jev_on; cmpx "$SHA" "$MED"; cp "$T/cmp/$SHA.json" "$CMPF"

# ── A1 ok: the vendor sees jev-latest, the rule tier and the diff; the key rides a header only ──
answer '{"choice":"medium","probability":0.81}'; ask
[ "$ARC" = 0 ] && ok || bad "A1 rc=$ARC out=$AOUT err=$(cat "$T/askerr")"
[ "$AOUT" = "$(printf 'ok\tmedium\t0.81\tmedium')" ] && ok || bad "A1 output: '$AOUT'"
[ "$(hits)" = 1 ] && ok || bad "A1 want one vendor hit, got $(hits)"
[ "$(jrow '[.status, .jev_tier, (.jev_prob|tostring), .rule_tier] | join(" ")')" = "ok medium 0.81 medium" ] && ok || bad "A1 ledger row: $(cat "$T/jev.json")"
JB=$(head -1 "$T/log/jev-bodies" 2>/dev/null)
[ "$(jq -r .model <<<"$JB" 2>/dev/null)" = jev-latest ] && ok || bad "A1 the request does not name jev-latest: $JB"
[ "$(jq -c .choices <<<"$JB" 2>/dev/null)" = '["low","medium","high"]' ] && ok || bad "A1 choices: $JB"
jq -r .input <<<"$JB" 2>/dev/null | grep -q 'Rule tier: medium' && ok || bad "A1 the question lacks the rule tier"
jq -r .input <<<"$JB" 2>/dev/null | grep -q '^+echo hello-patch-bin/lib/thing.sh' && ok || bad "A1 the question lacks the diff's patch line"
[ "$(head -1 "$T/log/jev-auth" 2>/dev/null)" = "Authorization: Bearer $KEY" ] && ok || bad "A1 the key did not reach the vendor's Authorization header: $(cat "$T/log/jev-auth" 2>/dev/null)"
grep -qF "$KEY" "$T/log/jev-argv" "$T/log/worker" "$T/askout" "$T/askerr" 2>/dev/null && bad "A1 the TypeSafe key leaked into argv, the worker or the output" || ok
[ -z "$(ls -A "$SPOOL" 2>/dev/null)" ] && ok || bad "A1 a settled answer was left in the spool: $(ls "$SPOOL")"
[ "$(cat "$T/log/settle-attempts" 2>/dev/null)" = 1 ] && ok || bad "A1 the settle did not name its claim's attempt: $(cat "$T/log/settle-attempts" 2>/dev/null)"

# ── A2 the same head again never reaches the vendor; a new head does ──
ask
[ "$(hits)" = 1 ] && ok || bad "A2 a second ask for the same head reached the vendor ($(hits) hits)"
[ "$ARC" = 0 ] && [ "$AOUT" = "$(printf 'ok\tmedium\t0.81\tmedium\tcached')" ] && ok || bad "A2 cached output rc=$ARC '$AOUT'"
ask "$H2"
[ "$(hits)" = 2 ] && ok || bad "A2 a new head was not asked ($(hits) hits)"

# ── A3 empty is terminal: a 2xx with no usable choice is billed and never asked again ──
N=0
for a in '{}' '{"choice":"LOW"}' '{"choice":"none","probability":0.4}' '<html><body>502 Bad Gateway</body></html>' '' '{"choice":"low","probability":1.5}'; do
  N=$((N + 1)); h=$(printf '%040x' "$N")
  reset; jev_on; answer "$a"; ask "$h"
  [ "$(jrow .status "$h")" = empty ] && [ "$ARC" = 0 ] && case "$AOUT" in empty*) true ;; *) false ;; esac && ok || bad "A3 answer '$a' was not empty: rc=$ARC '$AOUT' $(cat "$T/jev.json")"
  answer '{"choice":"high","probability":0.9}'; ask "$h"
  [ "$(hits)" = 1 ] && ok || bad "A3 answer '$a': an empty head was asked again ($(hits) hits)"
  [ "$(jrow .status "$h")" = empty ] && ok || bad "A3 answer '$a': the empty row moved: $(cat "$T/jev.json")"
done

# ── A4 failed is retried once (max 2 attempts), then the ledger refuses ──
reset; jev_on; answer '{"error":"boom"}'; echo 500 > "$T/jev-code"; ask
[ "$ARC" = 1 ] && [ "$(jrow .status)" = failed ] && ok || bad "A4 a 500 was not failed: rc=$ARC '$AOUT' $(cat "$T/jev.json")"
ask; [ "$(hits)" = 2 ] && [ "$(jrow .attempts)" = 2 ] && ok || bad "A4 the retry did not call: hits $(hits) attempts $(jrow .attempts)"
[ "$(tr '\n' ' ' < "$T/log/settle-attempts" 2>/dev/null)" = "1 2 " ] && ok || bad "A4 the retry's settle did not name attempt 2: $(cat "$T/log/settle-attempts" 2>/dev/null)"
ask; [ "$(hits)" = 2 ] && ok || bad "A4 a capped head reached the vendor ($(hits) hits)"
[ "$ARC" = 4 ] && case "$AOUT" in skipped*attempt_cap*) true ;; *) false ;; esac && ok || bad "A4 cap output rc=$ARC '$AOUT'"
# a timeout is failed too, never ok
reset; jev_on; answer '{"choice":"low","probability":0.9}'; echo 28 > "$T/jev-code"; ask
[ "$(jrow .status)" = failed ] && ok || bad "A4 a non-2xx code was not failed: $(cat "$T/jev.json")"
# a real curl timeout (rc 28, code 000) is failed, and the ledger names curl's rc
reset; jev_on; answer '{"choice":"low","probability":0.9}'; echo 28 > "$T/jev-curlrc"; ask
[ "$ARC" = 1 ] && [ "$(jrow '[.status, .error] | join(" ")')" = "failed curl rc 28" ] && ok || bad "A4 a curl timeout was not recorded as curl rc 28: rc=$ARC $(cat "$T/jev.json")"

# ── A5 not configured: no api_url row, or no key -> no claim, no call ──
reset; answer '{"choice":"low","probability":0.9}'; ask
[ "$ARC" = 3 ] && case "$AOUT" in not-configured*) true ;; *) false ;; esac && ok || bad "A5 no api_url: rc=$ARC '$AOUT'"
[ "$(claims)" = 0 ] && [ "$(hits)" = 0 ] && ok || bad "A5 no api_url still claimed ($(claims)) or called ($(hits))"
reset; jev_on; answer '{"choice":"low","probability":0.9}'; TYPESAFE_API_KEY="" ask
[ "$ARC" = 3 ] && [ "$(claims)" = 0 ] && [ "$(hits)" = 0 ] && ok || bad "A5 no key: rc=$ARC claims $(claims) hits $(hits)"
# a worker that cannot answer the claim is never "call and hope"
reset; jev_on; answer '{"choice":"low","probability":0.9}'; : > "$T/claim503"; ask; rm -f "$T/claim503"
[ "$(claims)" = 1 ] && [ "$(hits)" = 0 ] && [ "$ARC" = 4 ] && ok || bad "A5 an unanswered claim reached the vendor: rc=$ARC claims $(claims) hits $(hits)"

# ── A6 paid but unsettled: the local answer settles it next time, with no second call ──
reset; jev_on; answer '{"choice":"high","probability":0.7}'; echo 1 > "$T/settle503"; ask
[ "$(hits)" = 1 ] && [ -n "$(ls -A "$SPOOL" 2>/dev/null)" ] && ok || bad "A6 the paid answer was not kept locally: hits $(hits), spool $(ls "$SPOOL" 2>/dev/null)"
[ "$(jrow .status)" = claimed ] && ok || bad "A6 setup: the row is not claimed: $(cat "$T/jev.json")"
ask
[ "$(hits)" = 1 ] && ok || bad "A6 the spooled answer was bought again ($(hits) hits)"
[ "$(jrow '[.status, .jev_tier] | join(" ")')" = "ok high" ] && ok || bad "A6 the spool did not settle the row: $(cat "$T/jev.json")"
[ -z "$(ls -A "$SPOOL" 2>/dev/null)" ] && ok || bad "A6 the spool survived its settle"

# ── A7 the question, as shipped: `question` prints what `ask` sends; jev_risk.max_diff_chars cuts it ──
Q=$(bash "$H/bin/jev-risk.sh" question high "$CMPF"); QRC=$?
[ "$QRC" = 0 ] && grep -q '^Rule tier: high$' <<<"$Q" && grep -q '^modified bin/lib/thing.sh +40 -10$' <<<"$Q" \
  && grep -q '^+echo hello-patch-bin/lib/thing.sh' <<<"$Q" && ok || bad "A7 question rc=$QRC: $Q"
Q=$(JEV_MAX_DIFF_CHARS=120 bash "$H/bin/jev-risk.sh" question high "$CMPF")
[ "$(tail -1 <<<"$Q")" = '[truncated]' ] && [ "${#Q}" -le 133 ] && ok || bad "A7 JEV_MAX_DIFF_CHARS=120 did not cut: ${#Q} chars"
reset; jev_on; printf 150 > "$T/set/jev_risk.max_diff_chars"; answer '{"choice":"low","probability":0.5}'; ask
JI=$(head -1 "$T/log/jev-bodies" 2>/dev/null | jq -r .input 2>/dev/null)
[ "$(tail -1 <<<"$JI")" = '[truncated]' ] && [ "${#JI}" -le 163 ] && ok || bad "A7 the max_diff_chars row did not cut the sent question: ${#JI} chars"
bash "$H/bin/jev-risk.sh" ask example-org/cromford 41 nothex medium "$CMPF" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "A7 a junk head was not a usage error"
Q=$(bash "$H/bin/jev-risk.sh" question high "$CMPF")
[ "$(tail -1 <<<"$Q")" = '[truncated]' ] && [ "${#Q}" -le 163 ] && ok || bad "A7 question did not read the max_diff_chars row ask reads: ${#Q} chars"

# ── no secret anywhere in the lane log ──
grep -qF "$KEY" "$T/log/worker" "$T/log/jev-argv" 2>/dev/null && bad "the TypeSafe key reached a log" || ok
[ -s "$T/log/agent-call" ] && bad "agent-call.sh ran" || ok

echo "jev-risk-shadow.bh-5024: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

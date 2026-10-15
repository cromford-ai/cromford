#!/bin/bash
# tests/lead-review-enqueue-human-step-done.bh-6696-test.sh — BH-6696: a builder
# REQUEST_CHANGES (or BLOCK) on the PR head that raised a NEEDS-HUMAN step is
# answered by a person's HUMAN-STEP-DONE: (or RESUME) comment newer than the
# verdict. Then the hub trigger asks for the lead review on the same head, and
# the comment rides in scope_notes. Anything else is today's no-approve skip.
#   U1-U12 lsd_answer (bin/lib/lead-step-done.sh), pure, on thread fixtures.
#   E1-E13 "$DIR/bin/lead-review-enqueue.sh" tick, WHOLE, in a scratch harness
#          with its real bin closure: the tests/lead-review-enqueue-no-silent-
#          skip.bh-5779-test.sh stub worker and stub gh, plus a PR body
#          (Closes #<issue>) and the issue thread from $T/thread/<issue>.json
#          (absent = HTTP 500), and the verdict artifact's updated_at.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-human-step-done.bh-6696-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lead-review-enqueue.sh" ] || { echo "FAIL: no bin/lead-review-enqueue.sh"; exit 1; }
[ -f "$DIR/bin/lib/lead-step-done.sh" ] || { echo "FAIL: no bin/lib/lead-step-done.sh"; exit 1; }

H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
# The stubs go first: scratch_install_closure never clobbers a file already there.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit 0
EOF
chmod +x "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh" "$H/bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/lead-step-done.sh "$H" >/dev/null || exit 1
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

NOW=$(date +%s)
SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
OLD=$(printf 'c%.0s' {1..40})

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
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -e "$T/jv500/\$n" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    if [ -f "$T/rows/\$n" ]; then rw=\$(cat "$T/rows/\$n"); else rw='[]'; fi
    out=\$(jq -nc --argjson s "\$st" --argjson r "\$rw" '{standing:\$s, rows:\$r, truncated:false}') ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/lead-reviews/reclaim-stale")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"reclaimed":[],"deadline_s":3600,"as_of":"2026-10-09T00:00:00Z","truncated":false}'; fi ;;
  "POST /api/lead-reviews/"*"/reset")
    id="\${p#/api/lead-reviews/}"; id="\${id%/reset}"
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      jq -c --arg i "\$id" 'map(if .id == \$i then .status = "requested" | .detail = null | .reset_count = ((.reset_count // 0) + 1) else . end)' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
      row=\$(jq -c --arg i "\$id" '[.[] | select(.id == \$i)] | first // empty' "$T/lrrows.json")
      if [ -n "\$row" ]; then out=\$(jq -c '{request:.}' <<<"\$row"); else code=404; out='{"error":"no such lead review"}'; fi
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
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/head500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" --arg u "\$(cat "$T/author/\$n" 2>/dev/null || echo "cromford[bot]")" \
      --arg b "\$(cat "$T/body/\$n" 2>/dev/null)" --arg r "ticket/bh-\$n" \
      '{head:{sha:\$s,ref:\$r},base:{ref:"main"},user:{login:\$u},body:\$b}'; fi ;;
  *"-X GET repos/example-org/demo-os/issues/"*"/comments"*)
    a="\$*"; n="\${a##*/issues/}"; n="\${n%%/*}"
    if [ -f "$T/thread/\$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/thread/\$n.json"
    else printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'; fi ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n'; fi ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/norepos"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_FAILED_RETRY_MAX LEAD_REVIEW_REQUIRE_BUILDER_APPROVE

# sha <n> — a distinct full head per PR number
sha() { printf '%s%038d' "$1" 0; }
# pr <n> <head> [draft] — an open PR on example-org/demo-os at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# verdict <n> <word> <reviewed_sha> — the builder's ledger verdict row
verdict() {
  jq -nc --arg v "$2" --arg s "$3" '{verdict:$v, tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
approve() { verdict "$1" APPROVE "$2"; }
reset() {
  rm -f "$T/log"/* "$T/lrrows.json" "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv jv500 standing rows head head500 cmp set author body thread; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'operator' > "$T/set/lead_pr_authors"
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/lead-review-enqueue.log"
LEDGER="$H/state/lead-review-enqueue/requested.tsv"
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
alines() { cat "$T/log/alerts" 2>/dev/null; }
# skips <n> — the [skip lines for PR #<n>; skipn <n> — how many
skips() { grep -E "example-org/demo-os#$1( |:).*\[skip " "$LOGF" 2>/dev/null; }
skipn() { skips "$1" | grep -c .; }
# vat <n> <word> <reviewed_sha> <updated_at> — the builder's ledger verdict row,
# its verdict artifact stamped <updated_at>
vat() {
  jq -nc --arg v "$2" --arg s "$3" --arg at "$4" '{verdict:$v, tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", artifact_ref:$v, updated_at:$at, detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
# closes <n> <issue> — the PR body names its ticket issue
closes() { printf 'The fix.\n\nCloses #%s\n' "$2" > "$T/body/$1"; }
# cm <login> <User|Bot> <created_at> <body> — one issue comment, on stdout
CMI=0
cm() { CMI=$((CMI + 1)); jq -nc --arg w "$1" --arg t "$2" --arg at "$3" --arg b "$4" --argjson i "$CMI" \
  '{id:$i, html_url:("https://github.com/example-org/demo-os/issues/900#issuecomment-" + ($i|tostring)), user:{login:$w, type:$t}, created_at:$at, body:$b}'; }
# thread <issue> <comment>... — the issue's comment array
thread() { local n="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$T/thread/$n.json"; }
MARK='NEEDS-HUMAN: deploy the jobs worker (npx wrangler deploy) before this PR can land.'
DONE='HUMAN-STEP-DONE: deployed worker/jobs at 11:58Z, version 4f1c.'
VAT=2026-10-14T05:43:37Z
lsd() { ( . "$H/bin/lib/lead-step-done.sh" || exit 9; lsd_answer "$@" ); }
skips() { grep -E "example-org/demo-os#$1( |:).*\[skip " "$LOGF" 2>/dev/null; }
skipn() { skips "$1" | grep -c .; }
notes_of() { jq -r --argjson n "$1" '[.[] | select(.pr == $n) | .scope_notes] | first // ""' "$T/lrrows.json" 2>/dev/null; }
answered() { grep -c "example-org/demo-os#$1 @.*is answered by" "$LOGF" 2>/dev/null; }

# ── U1-U12: lsd_answer ──
reset
M=$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")
D=$(cm operator-a5 User 2026-10-14T12:00:47Z "$DONE")
OUT=$(lsd "$(printf '%s\n' "$M" "$D" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qx 'kind: done' <<<"$OUT" && grep -qF 'deployed worker/jobs' <<<"$OUT" \
  && grep -q '^comment: https://github.com/example-org/demo-os/issues/900#issuecomment-' <<<"$OUT" \
  && grep -qx 'author: @operator-a5 at 2026-10-14T12:00:47Z' <<<"$OUT" && ok || bad "U1 rc=$URC out=$OUT"
lsd "$(printf '%s\n' "$D" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U2 no marker: want rc 1, got $URC"
lsd "$(printf '%s\n' "$M" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U3 marker, no answer: want rc 1, got $URC"
R=$(cm operator-a5 User 2026-10-14T12:01:00Z 'RESUME')
OUT=$(lsd "$(printf '%s\n' "$M" "$R" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qx 'kind: resume' <<<"$OUT" && ok || bad "U4 RESUME: rc=$URC out=$OUT"
D5=$(cm operator-a5 User 2026-10-14T05:43:36Z "$DONE")
# The marker is older than the done, so only the verdict time can refuse it.
M0=$(cm cromford[bot] Bot 2026-10-14T05:00:00Z "$MARK")
lsd "$(printf '%s\n' "$M0" "$D5" | jq -sc .)" "$VAT" >/dev/null; URC5=$?
[ "$URC5" = 1 ] && ok || bad "U5 a done 1 s before the verdict: want rc 1, got $URC5"
D6=$(cm operator-a5 User "$VAT" "$DONE")
lsd "$(printf '%s\n' "$M0" "$D6" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U6 a done at the verdict second: want rc 1, got $URC"
M7=$(cm cromford[bot] Bot 2026-10-14T13:53:00Z "$MARK")
lsd "$(printf '%s\n' "$M" "$D" "$M7" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U7 a newer marker after the done: want rc 1, got $URC"
D8=$(cm some-app Bot 2026-10-14T12:00:47Z "$DONE")
lsd "$(printf '%s\n' "$M" "$D8" | jq -sc .)" "$VAT" >/dev/null; URC=$?
[ "$URC" = 1 ] && ok || bad "U8 a Bot's done: want rc 1, got $URC"
for b in 'RESUME once #12 merges' 'do not RESUME yet' 'Resume' 'Ok, RESUME it' \
         $'RESUME\n\nActually, do not resume yet: the key is not rotated.' \
         $'Looks fine.\n\n> HUMAN-STEP-DONE: deployed' $'We ran it.\nHUMAN-STEP-DONE: deployed'; do
  X=$(cm operator-a5 User 2026-10-14T12:00:50Z "$b")
  lsd "$(printf '%s\n' "$M" "$X" | jq -sc .)" "$VAT" >/dev/null; URC=$?
  [ "$URC" = 1 ] && ok || bad "U9 '$b' answered the step (rc $URC)"
done
lsd '{"message":"boom"}' "$VAT" >/dev/null; URC=$?
[ "$URC" = 2 ] && ok || bad "U10 a non-array thread: want rc 2, got $URC"
lsd "$(printf '%s\n' "$M" "$D" | jq -sc .)" 2026-10-14 >/dev/null; URC=$?
[ "$URC" = 2 ] && ok || bad "U11 a since that is not ISO: want rc 2, got $URC"
D12=$(cm operator-a5 User 2026-10-14T12:30:00Z 'HUMAN-STEP-DONE: second run, all green.')
OUT=$(lsd "$(printf '%s\n' "$M" "$D" "$D12" | jq -sc .)" "$VAT"); URC=$?
[ "$URC" = 0 ] && grep -qF 'second run, all green' <<<"$OUT" && ! grep -qF 'version 4f1c' <<<"$OUT" \
  && ok || bad "U12 want the newest done: rc=$URC out=$OUT"

# ── E1 (red): REQUEST_CHANGES on H, marker, then a person's done, no push ──
e1() {
  pr 41 "$SHA"; closes 41 900; vat 41 REQUEST_CHANGES "$SHA" "$VAT"
  thread 900 "$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")" "$(cm operator-a5 User 2026-10-14T12:00:47Z "$DONE")"
}
reset; e1; tick
[ "$RC" -eq 0 ] && ok || bad "E1 rc=$RC out=$(cat "$T/out")"
[ "$(posts)" = 1 ] && ok || bad "E1 want one POST /api/lead-reviews, got $(posts): $(cat "$LOGF")"
[ "$(jq -r '[.[] | select(.pr == 41) | .head_sha] | first // ""' "$T/lrrows.json" 2>/dev/null)" = "$SHA" ] && ok || bad "E1 the request is not on the head $SHA"
grep -qF "auto: HUMAN-STEP-DONE after the builder's REQUEST_CHANGES on $SHA12" <<<"$(notes_of 41)" && ok || bad "E1 notes lack the auto line: $(notes_of 41)"
grep -qF 'deployed worker/jobs at 11:58Z, version 4f1c.' <<<"$(notes_of 41)" && ok || bad "E1 notes lack the comment text: $(notes_of 41)"
grep -qF '@operator-a5 at 2026-10-14T12:00:47Z' <<<"$(notes_of 41)" && ok || bad "E1 notes lack the author and time: $(notes_of 41)"
[ "$(answered 41)" = 1 ] && ok || bad "E1 want one 'is answered by' line: $(cat "$LOGF")"
grep -q "example-org/demo-os#41 @$SHA12: lead review requested (lr-1)" "$LOGF" && ok || bad "E1 no requested line: $(cat "$LOGF")"
[ "$(skipn 41)" = 0 ] && ok || bad "E1 a skip line for the requested PR: $(skips 41)"
grep -q '\[skip no-approve\]' "$LOGF" && bad "E1 a no-approve skip: $(cat "$LOGF")" || ok

# ── E2: the same with no HUMAN-STEP-DONE comment -> today's skip ──
reset; e1; thread 900 "$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")"; tick
[ "$(posts)" = 0 ] && ok || bad "E2 want no request, got $(posts)"
[ "$(skipn 41)" = 1 ] && grep -q 'the fix round owns it.*\[skip no-approve\]$' <<<"$(skips 41)" && ok || bad "E2 want today's skip: $(skips 41)"
grep -q 'human-step check' <<<"$(skips 41)" && bad "E2 a readable no-answer must keep today's text: $(skips 41)" || ok
grep -q ' skipped_no_approve=1' <<<"$(summ)" && ok || bad "E2 summary: $(summ)"

# ── E2b: the REQUEST_CHANGES is on an older head; the PR head moved ──
reset; e1; vat 41 REQUEST_CHANGES "$OLD" "$VAT"; tick
[ "$(posts)" = 0 ] && ok || bad "E2b want no request, got $(posts)"
[ "$(answered 41)" = 0 ] && ok || bad "E2b an older head's refusal took the new path: $(cat "$LOGF")"

# ── E3: the done is older than the REQUEST_CHANGES ──
reset; e1
thread 900 "$(cm cromford[bot] Bot 2026-10-14T05:00:00Z "$MARK")" "$(cm operator-a5 User 2026-10-14T05:40:00Z "$DONE")"; tick
[ "$(posts)" = 0 ] && ok || bad "E3 an older done requested a review: $(cat "$LOGF")"
[ "$(skipn 41)" = 1 ] && grep -q 'the fix round owns it' <<<"$(skips 41)" && ok || bad "E3 want today's skip: $(skips 41)"

# ── E4: BLOCK on H, a person's RESUME after the verdict and the marker ──
reset; e1; vat 41 BLOCK "$SHA" "$VAT"
thread 900 "$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")" "$(cm operator-a5 User 2026-10-14T12:00:47Z $'RESUME\n\nThe key is rotated.')"; tick
[ "$(posts)" = 1 ] && ok || bad "E4 want one request, got $(posts): $(cat "$LOGF")"
grep -qF "auto: HUMAN-STEP-DONE after the builder's BLOCK on $SHA12" <<<"$(notes_of 41)" && grep -qF 'The key is rotated.' <<<"$(notes_of 41)" \
  && ok || bad "E4 notes: $(notes_of 41)"

# ── E5: a newer NEEDS-HUMAN marker after the done ──
reset; e1
thread 900 "$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")" "$(cm operator-a5 User 2026-10-14T12:00:00Z "$DONE")" \
  "$(cm operator User 2026-10-14T13:53:00Z 'NEEDS-HUMAN: the deploy is the wrong version; run it again.')"; tick
[ "$(posts)" = 0 ] && ok || bad "E5 a done before the newest marker requested a review: $(cat "$LOGF")"

# ── E6: the thread read fails (HTTP 500) ──
reset; e1; rm -f "$T/thread/900.json"; tick
[ "$(posts)" = 0 ] && ok || bad "E6 an unreadable thread requested a review"
grep -q 'the fix round owns it; human-step check: the thread of #900 is unreadable \[skip no-approve\]$' <<<"$(skips 41)" \
  && ok || bad "E6 skip reason: $(skips 41)"

# ── E6b: a lead-authored PR keeps today's skip, with its owner ──
reset; e1; echo operator > "$T/author/41"; tick
[ "$(posts)" = 0 ] && ok || bad "E6b a lead-authored PR was requested"
grep -qF 'lead-authored (operator)' <<<"$(skips 41)" && ok || bad "E6b skip: $(skips 41)"
[ "$(answered 41)" = 0 ] && ok || bad "E6b took the new path: $(cat "$LOGF")"

# ── E7: E1, then a second tick re-confirms with the same notes ──
reset; e1; tick; tick
[ "$(jq length "$T/lrrows.json")" = 1 ] && ok || bad "E7 want one row, got $(jq length "$T/lrrows.json")"
[ "$(posts)" = 2 ] && ok || bad "E7 want two POSTs (request, re-confirm), got $(posts)"
grep -q 'other notes already exists' "$LOGF" && bad "E7 the re-confirm sent other notes (409): $(cat "$LOGF")" || ok
grep -q ' existing=1' <<<"$(summ)" && ok || bad "E7 the second tick must count existing=1: $(summ)"

# ── E8: six answered PRs, one tick, cap 5 ──
reset
for n in 81 82 83 84 85 86; do
  pr "$n" "$(sha "$n")"; closes "$n" "9$n"; vat "$n" REQUEST_CHANGES "$(sha "$n")" "$VAT"
  thread "9$n" "$(cm cromford[bot] Bot 2026-10-14T05:43:40Z "$MARK")" "$(cm operator-a5 User 2026-10-14T12:00:47Z "$DONE")"
done
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 tick
[ "$(posts)" = 5 ] && ok || bad "E8 want 5 requests (the tick cap), got $(posts)"
grep -q ' deferred=1' <<<"$(summ)" && ok || bad "E8 want one deferred: $(summ)"

# ── E9: an earlier lead MERGE on another head is never replayed or delta-read here ──
reset; e1
jq -nc --arg g "$OLD" '[{id:8, verdict:"MERGE", source:"lead", head_sha:$g, note:"", created_at:"2026-10-13T00:00:00Z"}]' > "$T/rows/41"
tick
[ "$(posts)" = 1 ] && ok || bad "E9 want one request, got $(posts): $(cat "$LOGF")"
grep -q "example-org/demo-os#41 @$SHA12: .*\(no checkout at\|since ${OLD:0:12}\|replayed\)" "$LOGF" \
  && bad "E9 the replay block ran for a head the builder refused: $(cat "$LOGF")" || ok
grep -q 'lead-delta:' <<<"$(notes_of 41)" && bad "E9 a delta note on a refused head: $(notes_of 41)" || ok

# ── E10-E12 (operator-a5 14:34Z, second case): a builder REQUEST_CHANGES or BLOCK
#   bound to an EARLIER head does not stand on the current head (a fix round
#   pushed since). The head is unapproved, like a builder APPROVE on an earlier
#   head: it goes on to the CI gate, never to "stands; the fix round owns it". ──
reset; pr 42 "$SHA"; closes 42 901; vat 42 REQUEST_CHANGES "$OLD" "$VAT"; tick
grep -q "stands; the fix round owns it" <<<"$(skips 42)" && bad "E10 an old-head REQUEST_CHANGES still stands on the new head: $(skips 42)" || ok
grep -q "example-org/demo-os#42 @$SHA12: the builder's REQUEST_CHANGES is on ${OLD:0:12}, an earlier head; it does not stand on this head" "$LOGF" \
  && ok || bad "E10 no 'does not stand' line: $(cat "$LOGF")"
grep -q "no builder APPROVE on this head and CI not known green .*\[skip ci\]$" <<<"$(skips 42)" \
  && ok || bad "E10 the head must reach the CI gate: $(skips 42)"
reset; pr 43 "$SHA"; closes 43 902; vat 43 BLOCK "$OLD" "$VAT"; tick
grep -q "stands; the fix round owns it" <<<"$(skips 43)" && bad "E11 an old-head BLOCK still stands: $(skips 43)" || ok
reset; pr 44 "$SHA"; closes 44 903; vat 44 REQUEST_CHANGES "$OLD" "$VAT"; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
grep -q "the builder's REQUEST_CHANGES is on ${OLD:0:12}, not this head, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 \[skip no-approve\]$" <<<"$(skips 44)" \
  && ok || bad "E12 with the builder gate on, an old-head REQUEST_CHANGES is a no-approve skip with its own reason: $(skips 44)"
[ "$(posts)" = 0 ] && ok || bad "E12 a request was posted with the gate on"
# E13: a REQUEST_CHANGES on THIS head with no human step still stands (today).
reset; pr 45 "$SHA"; closes 45 904; vat 45 REQUEST_CHANGES "$SHA" "$VAT"; tick
grep -q "the builder's REQUEST_CHANGES on $SHA12 stands; the fix round owns it" <<<"$(skips 45)" && ok || bad "E13 a current-head REQUEST_CHANGES must still stand: $(skips 45)"

[ -s "$T/log/agent" ] && bad "agent-call.sh ran: $(cat "$T/log/agent")" || ok
grep -q 'test-secret\|lead-test-token' "$LOGF" && bad "a secret reached the log" || ok
echo "lead-review-enqueue-human-step-done.bh-6696: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

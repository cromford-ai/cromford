#!/bin/bash
# tests/lead-verdict-risk-tier.bh-5022-test.sh — BH-5022 (BH-4973.1): the three
# places a risk-tier sign-off is read or written outside the enqueue lane.
#   C1/C2/C5  "$DIR/bin/lead-verdict.sh" post --source risk-tier, run whole on its
#             real closure: the lead token rides the POST, the status is
#             success with the --note text as its description; a refused post
#             publishes nothing; a protected-path hit, or an undecidable
#             authority, is withheld (exit 5) and writes NO verdict row.
#   C3        "$DIR/bin/lead-review.sh" tick, run whole: a requested head on
#             which a risk-tier MERGE stands is reviewed for every requester,
#             the enqueue's own rows included (BH-8525 removed the supersede;
#             worklist gate 60 holds a risk-tier head before the start). The
#             same request with nothing standing, or a lead row standing, is
#             reviewed (the controls).
#   C6        C5's withheld post, then the lead-review.sh tick on what it left
#             standing: the fallback lead review runs and is not superseded.
#   C4        to_lane_lead_fence in "$DIR/bin/lib/ticket-ownership.sh": a
#             risk-tier MERGE never clears a lead-authored PR; a lead MERGE does.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-risk-tier.bh-5022-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID BOX_NAME JOBS_BOX

SLUG=example-org/demo-os
SHA=$(printf 'a%.0s' {1..40})
LEAD=operator

# ════════════════════════════════════════════════════════════════════════════
# C1/C2/C5: bin/lead-verdict.sh post --source risk-tier
# ════════════════════════════════════════════════════════════════════════════
VH="$T/lv/h"; VF="$T/lv/fx"; mkdir -p "$VH/state" "$VH/logs" "$VF" "$T/lv/fakebin" "$T/tmp"
scratch_install_closure bin/jobs-client.sh "$VH" >/dev/null || exit 1
scratch_install_closure bin/lead-verdict.sh "$VH" >/dev/null || exit 1
# TEST-CHANGE BH-4148 (merge of main): globs come from the DB, not the TSV.
# The lead_protected_paths rows (tests/lib/lpp-stub.sh): only example-org/other has
# one, so demo-os is not governed.
LPPF="$T/lv/lpp.json"; DOWNF="$T/lv/lpp-down"
lpp_install "$T/lv/fakebin" "$LPPF" "$DOWNF"
lpp_set "$LPPF" example-org/other x
printf 'lead-test-token\n' > "$T/lv/token"; chmod 600 "$T/lv/token"
cat > "$T/lv/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$VF/worker"
case "\$m \$p" in
$(lpp_curl_case m url body)
  "POST /api/verdicts")
    if [ -f "$VF/c400" ]; then printf '{"error":"source risk-tier may only say MERGE"}\n400'
    else printf '%s\n201' "\$(jq -c '{verdict:(. + {id:31,created_at:"2026-10-07T00:00:00Z"})}' <<<"\$body")"; fi ;;
  *) printf '{"error":"no such setting"}\n404' ;;
esac
EOF
cat > "$T/lv/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$VF/gh"
case "\$*" in
  *"/pulls/41/files"*) printf 'HTTP/2 200\r\n\r\n'; cat "$VF/files.json" ;;
  *"-X GET repos/$SLUG/pulls/41"*) printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$SHA" '{head:{sha:\$s},base:{ref:"main"}}' ;;
  *"-X POST repos/$SLUG/statuses/"*) printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
  *"-X POST repos/$SLUG/issues/"*) printf 'HTTP/2 201\r\n\r\n{"id":2}\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/lv/fakebin/curl" "$T/lv/fakebin/gh"
echo '[{"filename":"docs/a.md"}]' > "$VF/files.json"
lv() {
  ( cd "$T/lv" && PATH="$T/lv/fakebin:$PATH" HARNESS="$VH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/lv/token" GH_ETAG=0 LANE_GATE_DISABLE=1 \
      bash "$VH/bin/lead-verdict.sh" "$@" ) > "$VF/out" 2>&1; LRC=$?
}
lvreset() { rm -f "$VF"/{worker,gh,c400,out}; }
statuses() { grep "statuses/$SHA" "$VF/gh" 2>/dev/null; }

# C1: a MERGE with the lead token, source risk-tier, status success + the note
lvreset; lv post "$SLUG" 41 "$SHA" MERGE --source risk-tier --reviewer risk-tier:hub --note "low risk: docs only"
[ "$LRC" = 0 ] && ok || bad "C1 rc=$LRC: $(cat "$VF/out")"
grep -q '^POST /api/verdicts .* lead=1$' "$VF/worker" && ok || bad "C1 the POST did not carry x-lead-verdict-token: $(cat "$VF/worker" 2>/dev/null)"
[ "$(sed -n 's#^POST /api/verdicts \(.*\) lead=.$#\1#p' "$VF/worker" | jq -r '.source + " " + .verdict' 2>/dev/null)" = "risk-tier MERGE" ] && ok || bad "C1 body: $(cat "$VF/worker")"
[ "$(statuses | wc -l | tr -d ' ')" = 1 ] && ok || bad "C1 want one statuses POST: $(cat "$VF/gh")"
statuses | grep -q 'state=success' && statuses | grep -q 'context=lead-verdict' && ok || bad "C1 state/context: $(statuses)"
statuses | grep -qE 'description=low risk: docs only( |$)' && ok || bad "C1 description: $(statuses)"

# C2: the worker refuses (400) -> exit 1, nothing published
lvreset; : > "$VF/c400"; lv post "$SLUG" 41 "$SHA" BLOCK --source risk-tier --note "low risk: x"
[ "$LRC" = 1 ] && ok || bad "C2 a BLOCK with risk-tier: rc=$LRC"
[ -z "$(statuses)" ] && ok || bad "C2 published on a refused post: $(statuses)"
lvreset; : > "$VF/c400"; lv post "$SLUG" 41 "$SHA" MERGE --source risk-tier --note "low risk: x"
[ "$LRC" = 1 ] && [ -z "$(statuses)" ] && ok || bad "C2 a worker 400: rc=$LRC $(statuses)"
# ...and a risk-tier post with no note is refused before anything is written
lvreset; lv post "$SLUG" 41 "$SHA" MERGE --source risk-tier
[ "$LRC" = 1 ] && [ ! -s "$VF/worker" ] && ok || bad "C2 no --note: rc=$LRC $(cat "$VF/worker" 2>/dev/null)"

# C5: a protected-path hit is never published by risk-tier (lane mode), exit 5
lpp_set "$LPPF" "$SLUG" 'docs/**'
lvreset; lv post "$SLUG" 41 "$SHA" MERGE --source risk-tier --note "low risk: docs only"
[ "$LRC" = 5 ] && ok || bad "C5 rc=$LRC: $(cat "$VF/out")"
[ -z "$(statuses)" ] && ok || bad "C5 published on a protected path: $(statuses)"
# ...and NO row: a standing risk-tier advice row would cancel the lead review
grep -q '^POST /api/verdicts ' "$VF/worker" 2>/dev/null && bad "C5 a withheld risk-tier sign-off wrote a row: $(cat "$VF/worker")" || ok
grep -q 'no row written' "$VF/out" && ok || bad "C5 no 'no row written' line: $(cat "$VF/out")"
cp "$VF/worker" "$VF/worker.c5" 2>/dev/null || : > "$VF/worker.c5"
# ...while a lead MERGE on the same head publishes (lane mode), so the hold is risk-tier's alone
lvreset; lv post "$SLUG" 41 "$SHA" MERGE --source lead --note "x"
[ "$LRC" = 0 ] && [ -n "$(statuses)" ] && ok || bad "C5 control: a lead MERGE rc=$LRC $(statuses)"
# C5b: an undecidable authority (the PR files unreadable, la_decide rc 2) is withheld the same way
mv "$VF/files.json" "$VF/files.json.keep"
lvreset; lv post "$SLUG" 41 "$SHA" MERGE --source risk-tier --note "low risk: docs only"
[ "$LRC" = 5 ] && ok || bad "C5b unreadable files rc=$LRC: $(cat "$VF/out")"
[ -z "$(statuses)" ] && ok || bad "C5b published: $(statuses)"
grep -q '^POST /api/verdicts ' "$VF/worker" 2>/dev/null && bad "C5b a withheld risk-tier sign-off wrote a row: $(cat "$VF/worker")" || ok
mv "$VF/files.json.keep" "$VF/files.json"
lpp_set "$LPPF" "$SLUG"

# ════════════════════════════════════════════════════════════════════════════
# C3: bin/lead-review.sh tick reviews a request on a risk-tier head
# ════════════════════════════════════════════════════════════════════════════
RH="$T/lr/h"; RX="$T/lr"; mkdir -p "$RH/state" "$RH/prompts" "$RH/catalog/lanes.d" "$RX/fakebin" "$RX/log" "$RX/repos" "$RX/standing"
scratch_install_closure bin/jobs-client.sh "$RH" >/dev/null || exit 1
scratch_install_closure bin/lead-review.sh "$RH" >/dev/null || exit 1
scratch_install_closure bin/box-for.sh "$RH" >/dev/null || exit 1
[ -f "$DIR/bin/fleet-conf.sh" ] && { scratch_install_closure bin/fleet-conf.sh "$RH" >/dev/null || exit 1; }
cp "$DIR/catalog/lanes.d/_lib.json" "$RH/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$RH/prompts/"
echo box-demo > "$RH/state/box-name"
printf 'demo-os   example-org/demo-os   https://demo.test  /api/board 1 box-demo\n' > "$RH/fleet.conf"
# a real origin with the PR head, as tests/lead-review-lane.bh-2202-test.sh builds it
O="$RX/origin.git"; W="$RX/work"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\n## Verification Contract\n\n```bash\nexit 0\n```\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
git -C "$W" push -q "$O" "HEAD:refs/pull/41/head"; git clone -q "$O" "$RX/repos/demo-os"
RSHA=$(git -C "$W" rev-parse HEAD)
cat > "$RX/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$RX/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$RX/requests.json") ;;
  "GET /api/verdicts?"*"standing_only=1"*)
    if [ -f "$RX/standing/41" ]; then out=\$(jq -nc --argjson s "\$(cat "$RX/standing/41")" '{standing:\$s,rows:[]}'); else out='{"standing":null,"rows":[]}'; fi ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "PATCH /api/jobs/"*) ;;
  "POST /api/lead-reviews/"*/claim) ;;
  "POST /api/lead-reviews/"*/result) ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$RX/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$RSHA" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body"}' ;;
esac
exit 0
EOF
cat > "$RH/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$RX/log/agent"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$RX/fakebin/curl" "$RX/fakebin/gh" "$RH/bin/agent-call.sh"
# reqs <requested_by> — the one requested row the tick reads
reqs() { jq -nc --arg s "$RSHA" --arg by "$1" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:"auto",requested_by:$by,status:"requested"}],truncated:false}' > "$RX/requests.json"; }
reqs lead-review-enqueue:hub
lrtick() {
  rm -f "$RX/log"/*; scratch_rm "$RH/state/lead-reviews"
  ( cd "$RX" && PATH="$RX/fakebin:$PATH" HARNESS="$RH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$RX/repos" FLEET_CONF="$RH/fleet.conf" LANE_GATE_DISABLE=1 GH_ETAG=0 \
      bash "$RH/bin/lead-review.sh" tick ) > "$RX/out" 2>&1
}
resultpost() { grep '^POST /api/lead-reviews/lr-1/result ' "$RX/log/worker" 2>/dev/null; }

jq -nc '{verdict:"MERGE",source:"risk-tier",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"risk-tier:hub"}' > "$RX/standing/41"
# TEST-CHANGE BH-8525: C3 asserted that a request filed by the enqueue (requested_by lead-review-enqueue:hub) on a head with a standing risk-tier MERGE is posted superseded with no model call; BH-8525 removes that supersede (the enqueue has no launch, and worklist gate 60 holds a risk-tier head before the start), so that row is now reviewed like any other request; C3 asserts it in the C3b loop, and asserts the signed off by risk-tier line is absent from logs/lead-review.log.
# C3b: the same risk-tier head, whoever asked for the review -> it runs
for by in lead-review-enqueue:hub operator 'lead-verdict.sh:mac' ''; do
  reqs "$by"; lrtick
  grep -q '"outcome":"superseded"' <<<"$(resultpost)" && bad "C3b a request filed by '$by' was superseded: $(tail -3 "$RH/logs/lead-review.log" 2>/dev/null)" || ok
  [ -s "$RX/log/agent" ] && resultpost | grep -q '"outcome":"done"' && ok || bad "C3b a request filed by '$by' was not reviewed: $(resultpost) $(tail -3 "$RH/logs/lead-review.log" 2>/dev/null)"
done
grep -q "signed off by risk-tier" "$RH/logs/lead-review.log" 2>/dev/null && bad "C3 a risk-tier supersede line: $(grep "signed off by risk-tier" "$RH/logs/lead-review.log")" || ok
reqs lead-review-enqueue:hub
# control: a lead row standing (not risk-tier), and nothing standing, are reviewed
jq -nc '{verdict:"MERGE",source:"lead",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"box:x"}' > "$RX/standing/41"
lrtick
[ -s "$RX/log/agent" ] && ok || bad "C3 control (lead row): no review ran: $(tail -5 "$RH/logs/lead-review.log" 2>/dev/null)"
rm -f "$RX/standing/41"; lrtick
[ -s "$RX/log/agent" ] && resultpost | grep -q '"outcome":"done"' && ok || bad "C3 control (none): $(resultpost) $(tail -5 "$RH/logs/lead-review.log" 2>/dev/null)"
# C6 end to end: the withheld C5 post (exit 5) is followed by the lead review it
# falls back to. Whatever C5 made the worker stand on the head is what this
# tick reads; the request must be REVIEWED, never superseded.
rm -f "$RX/standing/41"
sed -n 's#^POST /api/verdicts \(.*\) lead=.$#\1#p' "$VF/worker.c5" | tail -1 \
  | jq -c 'select(.source == "risk-tier") | . + {id:31,created_at:"2026-10-07T00:00:00Z",report_url:null}' > "$RX/standing/41.c5" 2>/dev/null
[ -s "$RX/standing/41.c5" ] && mv "$RX/standing/41.c5" "$RX/standing/41" || rm -f "$RX/standing/41.c5"
lrtick
grep -q '"outcome":"superseded"' <<<"$(resultpost)" && bad "C6 the lead review after a withheld risk-tier post was superseded: $(tail -5 "$RH/logs/lead-review.log" 2>/dev/null)" || ok
[ -s "$RX/log/agent" ] && resultpost | grep -q '"outcome":"done"' && ok || bad "C6 no lead review ran after the withheld post: $(resultpost) $(tail -5 "$RH/logs/lead-review.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# C4: the lead-PR fence never clears on risk-tier
# ════════════════════════════════════════════════════════════════════════════
FH="$T/fence/h"; FX="$T/fence/fx"; mkdir -p "$FH/state" "$FH/logs" "$FX" "$T/fence/fakebin"
scratch_install_closure bin/jobs-client.sh "$FH" >/dev/null || exit 1
scratch_install_closure bin/lib/ticket-ownership.sh "$FH" >/dev/null || exit 1
scratch_install_closure bin/lib/verdicts.sh "$FH" >/dev/null || exit 1
printf '#!/bin/bash\nexit 0\n' > "$FH/bin/lane-alert.sh"; chmod +x "$FH/bin/lane-alert.sh"
cat > "$T/fence/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "GET "*/api/verdicts\?*)
    if [ -f "$FX/standing" ]; then printf '%s\n200\n' "\$(jq -nc --argjson s "\$(cat "$FX/standing")" '{standing:\$s,rows:[]}')"
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"$LEAD"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
printf '#!/bin/bash\necho ""\nexit 0\n' > "$T/fence/fakebin/gh"
chmod +x "$T/fence/fakebin/curl" "$T/fence/fakebin/gh"
fence() {
  ( cd "$T/fence" && PATH="$T/fence/fakebin:$PATH" HARNESS="$FH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_BOX=box-l \
      bash -c '. "$HARNESS/bin/lib/ticket-ownership.sh"; to_lane_lead_fence demo '"$SLUG"' 41 '"$SHA"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo "rc=$?"' ) 2>/dev/null | tail -1
}
jq -nc '{verdict:"MERGE",source:"risk-tier",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"risk-tier:hub"}' > "$FX/standing"
[ "$(fence)" = rc=0 ] && ok || bad "C4 a risk-tier MERGE cleared a lead PR: $(fence)"
grep -q 'risk-tier sign-off never clears a lead PR' "$FH/logs/lane.log" 2>/dev/null && ok || bad "C4 the held line does not say why: $(cat "$FH/logs/lane.log" 2>/dev/null)"
jq -nc '{verdict:"MERGE",source:"lead",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"mac"}' > "$FX/standing"
[ "$(fence)" = rc=1 ] && ok || bad "C4 a lead MERGE did not clear: $(fence)"
jq -nc '{verdict:"MERGE",source:"human",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"operator"}' > "$FX/standing"
[ "$(fence)" = rc=1 ] && ok || bad "C4 a human MERGE did not clear: $(fence)"

echo "lead-verdict-risk-tier.bh-5022: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

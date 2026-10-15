#!/bin/bash
# tests/lead-review-postscript.bh-6090-test.sh — BH-6090: the lead review keeps
# the review, not the postscript. The claude CLI's `.result` is the model's LAST
# assistant message only, so a short postscript after the review ("The monitor
# expired ... The review above is final. VERDICT: BLOCK", #5980) became the
# whole report, the artifact and the REQUEST_CHANGES review.
#
# Part P runs the REAL bin/lead-review.sh tick against a scratch harness (its
# bin/lib closure, the real jobs client), with only these stubbed:
#   * curl — the jobs worker (lead-review list/claim/result, job rows,
#            artifacts, model routes); every call is logged with its body;
#   * gh   — the REST PR read, head sha from $T/livehead;
#   * bin/agent-call.sh — for call n it writes $P/answer.<n> (else $P/answer)
#            to $5, and $P/session.<n> (else $P/session) to $5.session: it
#            plays the writer that tests/agent-call-session-sidecar.bh-6090-test.sh
#            proves the real bin/agent-call.sh is.
# The session transcripts are fixture jsonl files in the CLI's own shape: one
# line per content block, the blocks of one API message sharing .message.id.
#   P1  review then postscript: the report and the artifact keep the review
#   P2  one message, a verdict and no findings: failed detail=empty, two calls
#   P3  a normal review is byte-identical to today, the transcript is not read
#   P4  a normal review with no sidecar is done
#   P5  postscript and no sidecar / a missing jsonl / a bad session id: failed
#   P6  only a sidechain has findings / the review has no verdict: failed;
#       P6c a later draft with findings and no verdict is skipped
#   P7  the lr_has_findings decision table
#   P8  the review's verdict wins over the postscript's
#   P9  two reviews then a postscript: the later review is kept
#
# Part L runs the REAL bin/lead-review-land.sh (the hub land lane) with curl,
# gh and bin/lane-alert.sh stubbed:
#   L1  a BLOCK report with no `- [BLOCK` line: no review, one ALERTS line,
#       stamped, a second tick adds nothing
#   L1b a BLOCK report with only `- [NOTE]` lines: the same
#   L1c the ALERTS append fails: nothing posted, nothing stamped
#   L1d a re-landed empty BLOCK dismisses nothing (BH-5400 arm skipped)
#   L2  a `- [BLOCK] a.sh:3` report posts as today
#   L3  a `- [BLOCK needs-human]` report posts as today
#   L4  a truncated artifact posts as today
#   L5  no artifact: the `Full report:` pointer posts as today
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-postscript.bh-6090-test.sh
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
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT
export LEAD_REVIEW_MAX_PER_PR_DAY=50

POSTSCRIPT='The monitor expired after it delivered all 10 results, so I do not need it again. The review above is final and does not change.

VERDICT: BLOCK'

# ════════════════════════════ Part P: bin/lead-review.sh tick ════════════════
P="$T/p"; HP="$P/h"
mkdir -p "$HP/bin" "$HP/prompts" "$HP/catalog/lanes.d" "$HP/state" "$P/fakebin" "$P/log" "$P/repos" "$P/tmp" "$P/cfg/projects/-scratch"
scratch_install_closure bin/lead-review.sh "$HP" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HP" >/dev/null || bad "closure of bin/jobs-client.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HP/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$HP/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$HP/prompts/"
echo box-demo > "$HP/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$HP/fleet.conf"

OR="$P/origin.git"; WK="$P/work"
git init -q --bare -b main "$OR"; git init -q -b main "$WK"
printf '# demo\n\nNo contract here.\n' > "$WK/CLAUDE.md"; echo one > "$WK/a.txt"
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$OR" main
echo two >> "$WK/a.txt"; git -C "$WK" commit -qam "pr change"; git -C "$WK" push -q "$OR" "HEAD:refs/pull/41/head"
git clone -q "$OR" "$P/repos/demo-os"
SHA=$(git -C "$WK" rev-parse HEAD); SHA12=${SHA:0:12}
KEY="lr-41-$SHA12"; REPORT="$HP/state/lead-reviews/$KEY.md"; EMPTY="$HP/state/lead-reviews/$KEY.empty"

cat > "$P/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$P/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$P/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$P/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$P/livehead")" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
cat > "$HP/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$P/log/agent-count"; n=\$(wc -l < "$P/log/agent-count")
if [ -f "$P/answer.\$n" ]; then cp "$P/answer.\$n" "\$5"; else cp "$P/answer" "\$5"; fi
if [ -f "$P/session.\$n" ]; then cp "$P/session.\$n" "\$5.session"
elif [ -f "$P/session" ]; then cp "$P/session" "\$5.session"; fi
exit 0
EOF
chmod +x "$P/fakebin/curl" "$P/fakebin/gh" "$HP/bin/agent-call.sh"
echo "$SHA" > "$P/livehead"

# Session ids are uuid-shaped, like the CLI's. Built at run time: the public
# mirror's leakcheck refuses a uuid-shaped literal in the tree, fake or not.
fxsid() { printf '%s-%s-%s-%s-%s' 5e55a0b1 0000 4000 8000 "$1"; }
SID1=$(fxsid 000000000001)
TX="$P/cfg/projects/-scratch/$SID1.jsonl"
# tl <message-id> <sidechain:true|false> text <text>  |  tl <message-id> <sidechain> tool
tl() {
  if [ "$3" = tool ]; then
    jq -nc --arg m "$1" --argjson s "$2" '{type:"assistant",isSidechain:$s,sessionId:"fixture",
      message:{id:$m,role:"assistant",content:[{type:"tool_use",id:"toolu_fixture",name:"Bash",input:{command:"true"}}]}}'
  else
    jq -nc --arg m "$1" --argjson s "$2" --arg t "$4" '{type:"assistant",isSidechain:$s,sessionId:"fixture",
      message:{id:$m,role:"assistant",content:[{type:"text",text:$t}]}}'
  fi
}
tu() { jq -nc '{type:"user",isSidechain:false,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_fixture",content:"ok"}]}}'; }
sidecar() { printf '%s\t%s\n' "${1:-$SID1}" "${2:-$P/cfg}" > "$P/session"; }

preset() {
  rm -f "$P/log"/* "$P"/answer* "$P"/session* "$HP/logs/lead-review.log"
  rm -f "$P/cfg/projects/-scratch"/*.jsonl
  scratch_rm "$HP/state/lead-reviews"; scratch_rm "$HP/state/lead-review"; scratch_rm "$HP/state/model-routes"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,
    scope_notes:"only the lane",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$P/requests.json"
}
ptick() {
  ( cd "$P" && PATH="$P/fakebin:$PATH" HARNESS="$HP" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$P/tmp" REPOS_ROOT="$P/repos" FLEET_CONF="$HP/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HP/bin/lead-review.sh" tick ) > "$P/out" 2>&1
}
agents() { [ -f "$P/log/agent-count" ] && wc -l < "$P/log/agent-count" | tr -d ' ' || echo 0; }
pw() { cat "$P/log/worker" 2>/dev/null; }
results() { pw | grep '^POST /api/lead-reviews/lr-1/result ' | sed 's#^POST [^ ]* ##'; }
done_result() { results | jq -c 'select(.outcome == "done")' 2>/dev/null; }
failed_empty() { results | jq -e -s 'any(.[]; .outcome == "failed" and .detail == "empty")' >/dev/null 2>&1; }
art_body() { pw | grep '^PUT /api/jobs/job-7/artifacts ' | sed 's#^PUT [^ ]* ##' | jq -r '.detail | fromjson | .body // empty' 2>/dev/null; }
plog() { cat "$HP/logs/lead-review.log" 2>/dev/null; }
REVIEW_A='Findings
- [BLOCK] a.sh:3 the guard is inverted'
REVIEW_B='- [NOTE] b.sh:1 x

VERDICT: BLOCK'

# ── P1: the review (two text blocks, one message id), a tool call, then the postscript ──
preset
printf '%s\n' "$POSTSCRIPT" > "$P/answer"; sidecar
{ tl msg_fixture_a false text "I found 1 BLOCK and 1 NOTE."; tl msg_fixture_b false text "$REVIEW_A"; tl msg_fixture_b false text "$REVIEW_B"
  tl msg_fixture_c false tool; tu; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX"
ptick
grep -qF -- '- [BLOCK] a.sh:3 the guard is inverted' "$REPORT" 2>/dev/null && ok || bad "P1 the stored report lacks the BLOCK line: $(cat "$REPORT" 2>/dev/null)"
grep -qF -- '- [NOTE] b.sh:1 x' "$REPORT" 2>/dev/null && ok || bad "P1 the report lost the second text block of the review message"
grep -qF 'The monitor expired' "$REPORT" 2>/dev/null && bad "P1 the report is still the postscript" || ok
art_body | grep -qF -- '- [BLOCK] a.sh:3' && ok || bad "P1 the lead_review_report artifact body lacks the BLOCK line: $(art_body | head -c 400)"
[ "$(done_result | jq -r .verdict)" = BLOCK ] && ok || bad "P1 want a done BLOCK result, got: $(results)"
[ "$(agents)" = 1 ] && ok || bad "P1 the agent ran $(agents) time(s) (want 1: a recovered review costs nothing)"
plog | grep -q "kept review message 2 of 3 from session $SID1 for $KEY" && ok || bad "P1 no 'kept review message' log line: $(plog | tail -3)"

# ── P2: one message with a valid verdict and no findings, no sidecar ──
preset; printf 'Some text.\n\nVERDICT: BLOCK\n' > "$P/answer"; ptick
[ "$(agents)" = 2 ] && ok || bad "P2 the agent ran $(agents) time(s) (want 2: one retry)"
failed_empty && ok || bad "P2 no outcome=failed detail=empty result: $(results)"
[ -z "$(done_result)" ] && ok || bad "P2 a done result was posted for a findings-less answer: $(done_result)"
[ -e "$EMPTY" ] && ok || bad "P2 no $KEY.empty marker"
[ -e "$REPORT" ] && bad "P2 a report was written" || ok
plog | grep -q "no readable review (findings and a verdict) from stub-model for $KEY after one retry" && ok || bad "P2 no unreadable log line: $(plog | tail -3)"

# ── P3: a normal one-message review, sidecar present: byte-identical, transcript unread ──
preset
printf 'Findings\n- [BLOCK] a.txt:2 it breaks\n\nVERDICT: BLOCK\n' > "$P/answer"; sidecar
tl msg_fixture_x false text "$POSTSCRIPT" > "$TX"
ptick
# the body starts after the blank line that ends the `- key: value` header
awk 'f {print; next} /^- (checklist|review mode):/ {c=1; next} c && /^$/ {f=1}' "$REPORT" > "$P/body" 2>/dev/null
cmp -s "$P/body" "$P/answer" && ok || bad "P3 the report body is not byte-identical to the answer: $(diff "$P/answer" "$P/body" | head -5)"
grep -q 'kept review message' <<<"$(plog)" && bad "P3 the transcript was read for a readable answer" || ok
[ "$(done_result | jq -r .verdict)" = BLOCK ] && ok || bad "P3 no done BLOCK: $(results)"

# ── P4: the same normal review, no sidecar: done as today ──
preset; printf 'Findings\n- [BLOCK] a.txt:2 it breaks\n\nVERDICT: BLOCK\n' > "$P/answer"; ptick
[ "$(done_result | jq -r .verdict)" = BLOCK ] && [ "$(agents)" = 1 ] && ok || bad "P4 want a done BLOCK on one call: agents=$(agents) $(results)"

# ── P5: the postscript with no usable transcript ──
review_tx() { { tl msg_fixture_a false text "$REVIEW_A"; tl msg_fixture_a false text "$REVIEW_B"; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$1"; }
for c in nosidecar missing badsid; do
  preset; printf '%s\n' "$POSTSCRIPT" > "$P/answer"
  case "$c" in
    nosidecar) review_tx "$TX" ;;
    missing) sidecar "$(fxsid 0000000000ff)" ;;
    badsid)
      # the review IS on disk at projects/etc.jsonl, where the glob
      # projects/*/../etc.jsonl lands if the id is not checked first.
      review_tx "$P/cfg/projects/etc.jsonl"; sidecar '../etc' ;;
  esac
  ptick
  failed_empty && ok || bad "P5/$c no failed detail=empty result: $(results)"
  [ -z "$(done_result)" ] && ok || bad "P5/$c posted a done result: $(done_result)"
  plog | grep -q 'unreadable' && ok || bad "P5/$c no unreadable log line: $(plog | tail -3)"
  grep -q 'No such file' "$P/out" && bad "P5/$c the tick printed a shell error: $(grep 'No such file' "$P/out")" || ok
done

# ── P6: findings only in a sidechain / a review with no VERDICT line ──
for c in sidechain noverdict; do
  preset; printf '%s\n' "$POSTSCRIPT" > "$P/answer"; sidecar
  case "$c" in
    sidechain) { tl msg_fixture_s true text "$REVIEW_A"; tl msg_fixture_s true text "$REVIEW_B"; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX" ;;
    noverdict) { tl msg_fixture_a false text "$REVIEW_A"; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX" ;;
  esac
  ptick
  failed_empty && ok || bad "P6/$c no failed detail=empty result: $(results)"
  [ -z "$(done_result)" ] && ok || bad "P6/$c posted a done result: $(done_result)"
done

# ── P6c: a full review, then a later draft with findings and no verdict ──
# The draft is skipped: the kept message needs findings AND a verdict.
preset; printf '%s\n' "$POSTSCRIPT" > "$P/answer"; sidecar
{ tl msg_fixture_a false text "$REVIEW_A"; tl msg_fixture_a false text "$REVIEW_B"
  tl msg_fixture_b false text $'Findings\n- [NOTE] a draft with no verdict line'; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX"
ptick
[ "$(done_result | jq -r .verdict)" = BLOCK ] && grep -qF -- '- [BLOCK] a.sh:3' "$REPORT" 2>/dev/null \
  && ok || bad "P6c the full review was not kept over a later draft: $(results)"
grep -qF 'a draft with no verdict line' "$REPORT" 2>/dev/null && bad "P6c the report holds the draft" || ok

# ── P8: the review says MERGE-WITH-NOTES, the postscript says BLOCK ──
preset; printf '%s\n' "$POSTSCRIPT" > "$P/answer"; sidecar
{ tl msg_fixture_a false text $'Findings\n- [NOTE] b.sh:1 rename it\n\nVERDICT: MERGE-WITH-NOTES'; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX"
ptick
[ "$(done_result | jq -r .verdict)" = MERGE-WITH-NOTES ] && ok || bad "P8 want verdict MERGE-WITH-NOTES, got: $(results)"

# ── P9: two reviews, then a postscript: the LATER review ──
preset; printf '%s\n' "$POSTSCRIPT" > "$P/answer"; sidecar
{ tl msg_fixture_a false text $'Findings\n- [NOTE] first\n\nVERDICT: MERGE-WITH-NOTES'; tl msg_fixture_b false tool; tu
  tl msg_fixture_c false text $'Findings\n- [BLOCK] second\n\nVERDICT: BLOCK'; tl msg_fixture_d false text "$POSTSCRIPT"; } > "$TX"
ptick
grep -qF -- '- [BLOCK] second' "$REPORT" 2>/dev/null && ok || bad "P9 the report lacks the later review"
grep -qF -- '- [NOTE] first' "$REPORT" 2>/dev/null && bad "P9 the report holds the earlier review" || ok

# ── P7: the lr_has_findings decision table ──
sed -n '/^lr_has_findings() {/,/^}/p' "$SRC/bin/lead-review.sh" > "$P/hf.sh"
if [ -s "$P/hf.sh" ]; then
  ok
  . "$P/hf.sh"
  hf() { printf '%s' "$1" > "$P/hf.in"; if lr_has_findings "$P/hf.in"; then echo findings; else echo none; fi; }
  while IFS='|' read -r want text; do
    [ -n "$want" ] || continue
    text=$(printf '%b' "$text")
    [ "$(hf "$text")" = "$want" ] && ok || bad "P7 lr_has_findings on '$text': want $want"
  done <<'TABLE'
findings|Findings\n- [BLOCK] a.sh:3 x\nVERDICT: BLOCK
findings|**Findings**\n\n- [NOTE] b.sh:1 y
findings|## Findings\n- none
findings|Findings:\n- [BLOCK needs-human] c.sh:2 z
findings|FINDINGS\n- None.
findings|Findings: none
findings|Findings\r\n- [BLOCK] a.sh:3 x\r\n
none|The monitor expired after it delivered all 10 results. The review above is final.\n\nVERDICT: BLOCK
none|- [BLOCK] a.sh:3 x
none|Findings\nnothing to add
none|The findings are above.\n- [BLOCK] a.sh:3
none|- verdict: BLOCK\n- rules pack: red
none|
TABLE
else
  bad "P7 lr_has_findings is not in bin/lead-review.sh"
fi

# ════════════════════════════ Part L: bin/lead-review-land.sh ═══════════════
L="$T/l"; HL="$L/h"; ST="$HL/state/lead-review-land"
mkdir -p "$HL/state" "$HL/logs" "$HL/catalog" "$L/fakebin" "$L/log" "$L/tmp" "$L/cfg"
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || bad "closure of bin/lead-review-land.sh"
scratch_install_closure bin/lead-verdict.sh "$HL" >/dev/null || bad "closure of bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || bad "closure of bin/jobs-client.sh (land)"
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV. The lead protected
# paths are the lead_protected_paths rows (tests/lib/lpp-stub.sh). demo-os has
# none, as it had no TSV line: an empty rows file.
lpp_install "$L/fakebin" "$L/lpp.json" "$L/lpp-down"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$L/log/alerts" > "$HL/bin/lane-alert.sh"
chmod +x "$HL/bin/lane-alert.sh"
echo box-hub > "$HL/state/box-name"
printf 'lead-test-token-fixture\n' > "$L/cfg/token"; chmod 600 "$L/cfg/token"
LSHA=$(printf 'a%.0s' {1..40}); SLUG=example-org/demo-os

cat > "$L/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary) body="$a" ;;
    -H) case "$a" in @*) hdrs="$hdrs$(cat "${a#@}")"$'\n' ;; *) hdrs="$hdrs$a"$'\n' ;; esac ;;
  esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token-fixture' <<<"$hdrs" && lead=1
p="${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "$m" "$p" "$body" "$lead" >> "@L@/log/worker"
[ -f "@L@/vrows.json" ] || echo '[]' > "@L@/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
code=200; out='{}'
case "$m $p" in
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "GET /api/lead-reviews"*) out=$(cat "@L@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-10-12T00:00:00Z"}}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -f "@L@/artifacts-$j.json" ]; then out=$(cat "@L@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq 'map(.id) | max // 0' "@L@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-12T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@L@/vrows.json" > "@L@/vrows.tmp" && mv "@L@/vrows.tmp" "@L@/vrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h, standing:([$rows[] | select(.head_sha == $h and .source == "lead")] | first),
         rows:$rows, truncated:false}' "@L@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF
cat > "$L/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; cid=""; body=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) v="${a#*=}"; case "$v" in @*) v=$(cat "${v#@}") ;; esac
           case "${a%%=*}" in event) ev="$v" ;; commit_id) cid="$v" ;; body) body="$v" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s commit_id=%s\n' "$m" "$path" "$ev" "$cid" >> "@L@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@L@/reviews-$n.json"
case "$m $path" in
  "PUT repos/"*"/pulls/"*"/reviews/"*"/dismissals")
    rid=$(printf '%s' "$path" | sed -nE 's#.*/reviews/([0-9]+)/dismissals$#\1#p')
    jq -c --argjson i "$rid" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"state":"DISMISSED"}' ;;
  "POST repos/"*"/pulls/"*"/reviews")
    [ -f "$rf" ] || echo '[]' > "$rf"
    printf '%s' "$body" > "@L@/log/body-$n-$(( $(jq length "$rf") + 1 ))"
    case "$ev" in REQUEST_CHANGES) s=CHANGES_REQUESTED ;; COMMENT) s=COMMENTED ;; *) s=PENDING ;; esac
    jq -c --arg c "$cid" --arg s "$s" --arg b "$body" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:$s, body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*)
    reply 200 "{\"head\":{\"sha\":\"@SHA@\",\"ref\":\"ticket/bh-1\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@L@#$L#g; s#@SHA@#$LSHA#g" "$L/fakebin/curl" "$L/fakebin/gh"
chmod +x "$L/fakebin/curl" "$L/fakebin/gh"

# lreq <id> <status> <verdict> <job> [reset_count] -> one request on PR 7 @ $LSHA
lreq() {
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --arg j "$4" --arg rc "${5:-}" --arg h "$LSHA" \
    '{id:$i, repo:"example-org/demo-os", pr:7, head_sha:$h, status:$s, verdict:$v, reviewer_model:"stub-model",
      report_ref:"state/lead-reviews/lr-7.md", promoted_verdict_at:null, job_id:$j, box:"box-demo",
      detail:null, created_at:"2026-10-12T00:00:00Z", updated_at:"2026-10-12T00:00:00Z"}
     + (if $rc == "" then {} else {reset_count:($rc|tonumber)} end)'
}
lsetreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$L/requests.json"; }
# lart <job> <report-body> [truncated]
lart() {
  jq -nc --arg b "$2" --arg t "${3:-}" '{body:$b, path:"state/lead-reviews/lr-7.md", verdict:"BLOCK"}
    + (if $t == "" then {} else {truncated:true} end)' \
    | jq -Rc '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/lr-7.md", phase_id:null, detail:.}]}' \
    > "$L/artifacts-$1.json"
}
# lreport <text> — this head's stored report: the header lead-review.sh writes, then <text>
lreport() { printf '# Lead review lr-7-%s (%s#7 at %s)\n\n- verdict: BLOCK\n- rules pack: red\n\n%s\n' "${LSHA:0:12}" "$SLUG" "$LSHA" "$1"; }
lreset() {
  scratch_rm "$L/log"; mkdir -p "$L/log"; : > "$L/log/gh"; : > "$L/log/worker"; : > "$L/log/alerts"
  rm -f "$L/vrows.json" "$L"/reviews-*.json "$L"/artifacts-*.json "$HL/logs/lead-review-land.log"
  scratch_rm "$HL/logs/ALERTS.log"
  scratch_rm "$ST"
  lsetreqs "$(lreq lr-1 done BLOCK j1)"
}
ltick() {
  ( cd "$L" && PATH="$L/fakebin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 TMPDIR="$L/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$L/cfg/token" GH_ETAG=0 \
      bash "$HL/bin/lead-review-land.sh" ) > "$L/out" 2>&1; LRC=$?
}
rposts()  { grep -c "^POST repos/$SLUG/pulls/7/reviews " "$L/log/gh"; }
stamps()  { grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$L/log/worker"; }
dismissals() { grep -c "^PUT repos/$SLUG/pulls/7/reviews/[0-9]*/dismissals " "$L/log/gh"; }
alerts_empty() { cat "$HL/logs/ALERTS.log" 2>/dev/null | grep -c "no '- \[BLOCK' finding line"; }
lbody() { cat "$L/log/body-7-$1" 2>/dev/null; }
llog() { cat "$HL/logs/lead-review-land.log" 2>/dev/null; }

# ── L1: this head's report is the postscript only ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; ltick
[ "$LRC" = 0 ] && ok || bad "L1 rc=$LRC $(cat "$L/out")"
[ "$(rposts)" = 0 ] && ok || bad "L1 posted $(rposts) review(s) for a BLOCK with no finding line: $(lbody 1)"
[ "$(alerts_empty)" = 1 ] && ok || bad "L1 want one ALERTS line, got $(alerts_empty): $(cat "$HL/logs/ALERTS.log" 2>/dev/null)"
grep -qF "$SLUG#7 @${LSHA:0:12} lead review lr-1" "$HL/logs/ALERTS.log" 2>/dev/null && ok || bad "L1 the ALERTS line does not name the PR and request"
[ "$(stamps)" = 1 ] && ok || bad "L1 want one stamp, got $(stamps)"
[ "$(dismissals)" = 0 ] && ok || bad "L1 dismissed a review"
[ -e "$ST/findings-lr-1" ] && bad "L1 wrote the findings flag for a review it never posted" || ok
llog | grep -q 'BLOCK report has no finding line; review withheld, alerted' && ok || bad "L1 no log line: $(llog | tail -2)"
ltick
[ "$(alerts_empty)" = 1 ] && ok || bad "L1 a second tick alerted again ($(alerts_empty))"
[ "$(rposts)" = 0 ] && ok || bad "L1 a second tick posted"

# ── L1b: only NOTE lines under a BLOCK verdict ──
lreset; lart j1 "$(lreport $'Findings\n- [NOTE] b.sh:1 rename it\n\nVERDICT: BLOCK')"; ltick
[ "$(rposts)" = 0 ] && [ "$(alerts_empty)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L1b posts=$(rposts) alerts=$(alerts_empty) stamps=$(stamps)"

# ── L1c: the ALERTS append fails: nothing posted, nothing stamped ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; mkdir -p "$HL/logs/ALERTS.log"; ltick
[ "$(rposts)" = 0 ] && ok || bad "L1c posted with no alert written"
[ "$(stamps)" = 0 ] && ok || bad "L1c stamped with no alert written ($(stamps))"
llog | grep -q 'empty BLOCK withheld but the alert was not written' && ok || bad "L1c no log line: $(llog | tail -2)"
scratch_rm "$HL/logs/ALERTS.log"

# ── L1d: landed BLOCK (job j1), reset, the re-review's report is a postscript (job j2) ──
lreset; lart j1 "$(lreport $'Findings\n- [BLOCK] a.sh:3 the guard is inverted\n\nVERDICT: BLOCK')"; ltick
[ "$(rposts)" = 1 ] && ok || bad "L1d tick 1 did not post the real review ($(rposts))"
: > "$L/log/gh"; : > "$L/log/worker"
lart j2 "$(lreport "$POSTSCRIPT")"; lsetreqs "$(lreq lr-1 done BLOCK j2 1)"; ltick
[ "$(rposts)" = 0 ] && ok || bad "L1d the re-land posted the postscript"
[ "$(dismissals)" = 0 ] && ok || bad "L1d the re-land dismissed the standing review ($(dismissals)) with nothing to replace it"
[ "$(alerts_empty)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L1d alerts=$(alerts_empty) stamps=$(stamps)"

# ── L2: a real BLOCK line posts as today ──
lreset; lart j1 "$(lreport $'Findings\n- [BLOCK] a.sh:3 the guard is inverted\n\nVERDICT: BLOCK')"; ltick
[ "$(rposts)" = 1 ] && grep -q "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$LSHA\$" "$L/log/gh" \
  && ok || bad "L2 want one REQUEST_CHANGES: $(cat "$L/log/gh")"
lbody 1 | grep -qF -- '- [BLOCK] a.sh:3' && ok || bad "L2 the review body lacks the finding: $(lbody 1)"
[ "$(alerts_empty)" = 0 ] && ok || bad "L2 alerted on a real BLOCK"

# ── L3: only a needs-human BLOCK posts (the hold path) ──
lreset; lart j1 "$(lreport $'Findings\n- [BLOCK needs-human] cfg.sh:1 which vendor tier do we buy\n\nVERDICT: BLOCK')"; ltick
[ "$(rposts)" = 1 ] && [ "$(alerts_empty)" = 0 ] && ok || bad "L3 posts=$(rposts) alerts=$(alerts_empty)"

# ── L4: a truncated artifact whose prefix has no BLOCK line posts ──
lreset; lart j1 "$(lreport $'Findings\n- [NOTE] b.sh:1 a long note')" truncated; ltick
[ "$(rposts)" = 1 ] && lbody 1 | grep -qF 'Report truncated here' && ok || bad "L4 posts=$(rposts) body: $(lbody 1)"
[ "$(alerts_empty)" = 0 ] && ok || bad "L4 alerted on a truncated artifact"

# ── L5: no artifact: the Full report pointer posts ──
lreset; ltick
[ "$(rposts)" = 1 ] && lbody 1 | grep -qF 'Full report: state/lead-reviews/lr-7.md on box box-demo' \
  && ok || bad "L5 posts=$(rposts) body: $(lbody 1)"

echo "lead-review-postscript.bh-6090: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

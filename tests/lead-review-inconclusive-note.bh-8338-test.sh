#!/bin/bash
# tests/lead-review-inconclusive-note.bh-8338-test.sh — BH-8338: the lead
# review's outcome cap (bin/lib/lead-outcome-cap.sh, BH-6372.3) never records a
# BLOCK with no finding. A capped report carries ONE finding line that names
# the INCONCLUSIVE claims and the fix. Under the default knob the cap is a
# BLOCK only when the ticket carries the `perf-gate` label; a perf match by
# phrase, perf/cost label, target line or parent hop is MERGE-WITH-NOTES plus a
# `- [NOTE] outcome cap:` line. The writer (bin/lead-review.sh) refuses a BLOCK
# report with no `- [BLOCK` line.
#
# Unit cases, the lib alone:
#   U1  ten rows, #5354 text (perf phrase), labels `hotfix`: MERGE-WITH-NOTES,
#       line 3 a `- [NOTE] outcome cap:` line naming claim 1..claim 10 and the fix
#   U2  the same with `hotfix,perf-gate`: BLOCK, a `- [BLOCK wrong-data]` line
#       with the same claim list
#   U3  label near misses never BLOCK; ` Perf-Gate ` does
#   U4  `perf-gate` on the #6049 text (non-perf): BLOCK
#   U5  no ticket file, repo + number: #8401 (perf-gate) BLOCK with one read;
#       #5368 (parent #5354 perf) MERGE-WITH-NOTES, #5368 read once; a perf-gate
#       label on the parent only is still MERGE-WITH-NOTES; #77 (404) not capped
#   U6  knob all on #6049: BLOCK naming =all; knob off with perf-gate: not capped
#   U7  agent MERGE on #5354: MERGE-WITH-NOTES
#   U8  the writer's refusal predicate on report fixtures
# Tick cases, the REAL bin/lead-review.sh tick (the rig of
# tests/lead-review-inconclusive-block.bh-6381-test.sh):
#   L1  ten rows, Closes #5354, agent MERGE-WITH-NOTES: MERGE-WITH-NOTES, one
#       NOTE cap line, lr_verdict and findings() (mcp/tools/lead-review.mjs) agree
#   L2  Closes #8401 (perf-gate): BLOCK, one `- [BLOCK wrong-data] outcome cap:`
#   L3  strict mode, agent answers NOTE lines + VERDICT: BLOCK: refused, posted
#       outcome failed detail block-no-finding, no BLOCK done post
#   L4  all rows CONFIRMED: the agent verdict, no cap line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-inconclusive-note.bh-8338-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/bh-6372"; FX2="$SRC/tests/fixtures/bh-6381"; FX3="$SRC/tests/fixtures/bh-8338"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in "$FX/issue-5354.json" "$FX/issue-5368.json" "$FX/issue-6049.json" "$FX2/body-all-confirmed.md" \
         "$FX3/body-ten-inconclusive.md" "$FX3/issue-8401.json"; do
  [ -r "$f" ] || { echo "FAIL: fixture missing: $f"; exit 1; }
done
LIB_SRC="$SRC/bin/lib/lead-outcome-cap.sh"
TEN="$FX3/body-ten-inconclusive.md"

H="$T/h"; mkdir -p "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/fx"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure of bin/jobs-client.sh"
scratch_install_closure bin/box-for.sh "$H" >/dev/null || bad "closure of bin/box-for.sh"
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "closure of bin/fleet-conf.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$SRC/catalog/perf-ticket.tsv" "$H/catalog/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$H/fleet.conf"
for n in 5354 5368 6049; do cp "$FX/issue-$n.json" "$T/fx/$n.json"; done
cp "$FX3/issue-8401.json" "$T/fx/8401.json"

o="$T/origin.git"; w="$T/work"
git init -q --bare -b main "$o"; git init -q -b main "$w"
printf '# bh\n' > "$w/CLAUDE.md"; echo one > "$w/a.txt"
git -C "$w" add -A; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qm base
git -C "$w" push -q "$o" main
echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qam "pr change"
git -C "$w" push -q "$o" "HEAD:refs/pull/83/head"
git clone -q "$o" "$T/repos/cromford"
SHA=$(git -C "$w" rev-parse HEAD)

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    if [ "\$(cat "$T/jobstate" 2>/dev/null)" = running ]; then code=409; out='{"job":{"id":"job-83","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-83"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# gh: the PR, its comments, and issues/<n> from $T/fx/<n>.json; any other issue
# answers 404. Every argv is logged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" --rawfile b "$T/prbody" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:\$b}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*)
    printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-X GET repos/"*"/issues/"*)
    n=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    if [ -r "$T/fx/\$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/\$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; fi ;;
esac
exit 0
EOF
# The agent stub answers $T/agent-answer when it exists, else NOTE + MERGE-WITH-NOTES.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
if [ -r "$T/agent-answer" ]; then cp "$T/agent-answer" "\$5"
else printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES\n' > "\$5"; fi
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/rules-pack.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$H/bin/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_THREAD_MAX_BYTES=60000
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW \
  LEAD_REVIEW_INCONCLUSIVE_BLOCK PERF_TICKET_CATALOG GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID REVIEW_LEVEL_MODE
jq -nc --arg s "$SHA" '{requests:[{id:"lr-8338",repo:"example-org/cromford",pr:83,head_sha:$s,scope_notes:"x",prior_verdict_ref:"v",status:"requested"}],truncated:false}' \
  > "$T/requests.json"
R=example-org/cromford

# ════ Unit cases ════════════════════════════════════════════════════════════
run() { OUT=$(bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" "$@" 2>"$T/err"); RC=$?; }
l1() { sed -n 1p <<<"$OUT"; }
l3() { sed -n 3p <<<"$OUT"; }
claims_of() { sed -nE 's/.*read[s]? INCONCLUSIVE \(([^)]*)\).*/\1/p' <<<"$1"; }
jq -r '.body' "$FX/issue-5354.json" > "$T/t5354"
jq -r '.body' "$FX/issue-6049.json" > "$T/t6049"
T5354=$(jq -r '.title' "$FX/issue-5354.json"); T6049=$(jq -r '.title' "$FX/issue-6049.json")
ALL10="claim 1, claim 2, claim 3, claim 4, claim 5, claim 6, claim 7, claim 8, claim 9, claim 10"

# U1
run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t5354" "$T5354" "hotfix"
U1F=$(l3)
[ "$RC" = 0 ] && [ "$(l1)" = MERGE-WITH-NOTES ] && ok || bad "U1 want MERGE-WITH-NOTES rc 0, got rc $RC: $OUT"
case "$U1F" in "- [NOTE] outcome cap: 10 claim rows"*) ok ;; *) bad "U1 line 3 is not a NOTE cap line: '$U1F'" ;; esac
[ "$(claims_of "$U1F")" = "$ALL10" ] && grep -q 'Evidence table' <<<"$U1F" && grep -q 'artifact line' <<<"$U1F" \
  && ! grep -q '\[BLOCK' <<<"$OUT" && ok || bad "U1 the NOTE line does not name claim 1..10 and the fix: '$U1F'"
# U2
run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t5354" "$T5354" "hotfix,perf-gate"
[ "$RC" = 0 ] && [ "$(l1)" = BLOCK ] && ok || bad "U2 perf-gate: want BLOCK rc 0, got rc $RC: $OUT"
case "$(l3)" in "- [BLOCK wrong-data] outcome cap: 10 claim rows"*) ok ;; *) bad "U2 line 3 is not a BLOCK cap line: '$(l3)'" ;; esac
[ "$(claims_of "$(l3)")" = "$(claims_of "$U1F")" ] && ok || bad "U2 the claim list differs from U1: '$(l3)'"
# U3: near misses on the perf-phrase ticket never BLOCK; a padded mixed-case label does
for lab in perf cost perf-gates gate perf_gate perf-gate-off "hotfix,perfgate" ""; do
  run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t5354" "$T5354" "$lab"
  [ "$RC" = 0 ] && [ "$(l1)" = MERGE-WITH-NOTES ] && case "$(l3)" in "- [NOTE] outcome cap:"*) true ;; *) false ;; esac \
    && ok || bad "U3 label '$lab' must be MERGE-WITH-NOTES with a NOTE, got rc $RC: $OUT"
done
{ cat "$T/t6049"; printf '\nThis needs the perf-gate label one day.\n'; } > "$T/t6049-phrase"
run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t6049-phrase" "perf-gate in the title" ""
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && ok || bad "U3 the text perf-gate with no label must not cap, got rc $RC: $OUT"
run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t5354" "$T5354" "hotfix, Perf-Gate "
[ "$RC" = 0 ] && [ "$(l1)" = BLOCK ] && ok || bad "U3 ' Perf-Gate ' must BLOCK, got rc $RC: $OUT"
# U4
run loc_cap MERGE-WITH-NOTES "$TEN" "$T/t6049" "$T6049" "perf-gate"
[ "$RC" = 0 ] && [ "$(l1)" = BLOCK ] && case "$(l3)" in "- [BLOCK wrong-data] outcome cap:"*"perf-gate label"*) true ;; *) false ;; esac \
  && grep -q 'on label:perf-gate' <<<"$(sed -n 2p <<<"$OUT")" && ok || bad "U4 perf-gate on #6049: want BLOCK + finding, got rc $RC: $OUT"
# U5: no ticket file, repo + number
: > "$T/log/gh"
run loc_cap MERGE-WITH-NOTES "$TEN" "" "" "" "$R" 8401
[ "$RC" = 0 ] && [ "$(l1)" = BLOCK ] && case "$(l3)" in "- [BLOCK wrong-data] outcome cap:"*) true ;; *) false ;; esac \
  && [ "$(grep -c 'issues/8401' "$T/log/gh")" = 1 ] && ok || bad "U5 #8401: want BLOCK with one read, got rc $RC: $OUT / $(cat "$T/log/gh")"
: > "$T/log/gh"
run loc_cap MERGE-WITH-NOTES "$TEN" "" "" "" "$R" 5368
[ "$RC" = 0 ] && [ "$(l1)" = MERGE-WITH-NOTES ] && grep -q 'perf parent:#5354' <<<"$OUT" \
  && [ "$(grep -c 'issues/5368' "$T/log/gh")" = 1 ] && [ "$(grep -c 'issues/5354' "$T/log/gh")" = 1 ] \
  && [ "$(grep -n 'issues/53' "$T/log/gh" | head -1 | grep -c 5368)" = 1 ] \
  && ok || bad "U5 #5368: want MERGE-WITH-NOTES via the parent, one read each, got rc $RC: $OUT / $(cat "$T/log/gh")"
jq '.labels += [{"name":"perf-gate"}]' "$FX/issue-5354.json" > "$T/fx/5354.json"
run loc_cap MERGE-WITH-NOTES "$TEN" "" "" "" "$R" 5368
[ "$RC" = 0 ] && [ "$(l1)" = MERGE-WITH-NOTES ] && ok || bad "U5 a perf-gate label on the parent only must not BLOCK, got rc $RC: $OUT"
cp "$FX/issue-5354.json" "$T/fx/5354.json"
: > "$T/log/gh"
run loc_cap MERGE-WITH-NOTES "$TEN" "" "" "" "$R" 77
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && [ "$(grep -c . "$T/err")" = 1 ] && grep -q 'perf class unknown (#77 HTTP 404' "$T/err" \
  && [ "$(grep -c 'issues/77' "$T/log/gh")" = 1 ] && ok || bad "U5 #77: want not capped, one unknown line, one read; got rc $RC: $OUT / $(cat "$T/err")"
# U6
OUT=$(LEAD_REVIEW_INCONCLUSIVE_BLOCK=all bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" \
  loc_cap MERGE-WITH-NOTES "$TEN" "$T/t6049" "$T6049" "" 2>"$T/err"); RC=$?
[ "$RC" = 0 ] && [ "$(l1)" = BLOCK ] && case "$(l3)" in "- [BLOCK wrong-data] outcome cap:"*"LEAD_REVIEW_INCONCLUSIVE_BLOCK=all"*) true ;; *) false ;; esac \
  && ok || bad "U6 knob all: want BLOCK + a line naming =all, got rc $RC: $OUT"
OUT=$(LEAD_REVIEW_INCONCLUSIVE_BLOCK=off bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" \
  loc_cap MERGE-WITH-NOTES "$TEN" "$T/t5354" "$T5354" "perf-gate" 2>"$T/err"); RC=$?
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && ok || bad "U6 knob off with perf-gate: want not capped, got rc $RC: $OUT"
# U7
run loc_cap MERGE "$TEN" "$T/t5354" "$T5354" ""
[ "$RC" = 0 ] && [ "$(l1)" = MERGE-WITH-NOTES ] && grep -q 'agent verdict MERGE$' <<<"$OUT" \
  && ok || bad "U7 agent MERGE: want MERGE-WITH-NOTES rc 0, got rc $RC: $OUT"
# U8: the writer's refusal predicate, lr_block_no_finding in
# bin/lib/lead-review/outcome-cap.sh (the anchored grep bin/lead-review-land.sh
# uses): has_block rc 0 = the BLOCK report has a BLOCK finding line.
OC_SRC="$SRC/bin/lib/lead-review/outcome-cap.sh"
# shellcheck source=bin/lib/lead-review/outcome-cap.sh
. "$OC_SRC" || { bad "U8 cannot source $OC_SRC"; }
has_block() { printf '%b' "$1" > "$T/rpt"; ! lr_block_no_finding BLOCK "$T/rpt"; }
grep -q 'lr_block_no_finding "\$verdict" "\$report"' "$SRC/bin/lead-review.sh" && ok \
  || bad "U8 bin/lead-review.sh does not call lr_block_no_finding on \$report"
printf -- '- [NOTE] a\n' > "$T/rpt"
lr_block_no_finding MERGE-WITH-NOTES "$T/rpt" && bad "U8 a non-BLOCK verdict is never refused" || ok
for c in '- [BLOCK wrong-data] x\n' '- [BLOCK] x\n' '- [NOTE] a\n- [BLOCK] b\n'; do
  has_block "$c" && ok || bad "U8 '$c' must count as a BLOCK finding"
done
for c in '- [NOTE] a\nVERDICT: BLOCK\n' '  - [BLOCK] x\n' '> - [BLOCK] x\n' 'text [BLOCK] mid\n'; do
  has_block "$c" && bad "U8 '$c' must not count as a BLOCK finding" || ok
done

# ════ Tick cases ════════════════════════════════════════════════════════════
drive() {
  rm -f "$T/log"/* "$T/jobstate"; scratch_rm "$H/state/lead-reviews"
  mkdir -p "$H/logs"; : > "$H/logs/lead-review.log"
  cp "$1" "$T/prbody"
  ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
  RPT=$(ls "$H"/state/lead-reviews/*.md 2>/dev/null | head -1)
}
withcloses() { { printf 'Closes #%s\n\n' "$1"; cat "$2"; } > "$T/body-$1-$(basename "$2")"; printf '%s' "$T/body-$1-$(basename "$2")"; }
rv() { sed -n 's/^- verdict: //p' "$RPT" 2>/dev/null | head -1; }
lastline() { awk 'NF {l=$0} END {print l}' "$RPT" 2>/dev/null; }
posted() { grep -c '"verdict":"'"$1"'"' "$T/log/worker" 2>/dev/null; }
lrlog() { cat "$H/logs/lead-review.log" "$T/out" 2>/dev/null; }
lrv() { bash -c '. "$1/bin/lib/verdict-parse.sh"; eval "$(sed -n "/^lr_verdict() {/,/^}/p" "$1/bin/lead-review.sh")"; lr_verdict "$2"' lrv "$H" "$1" 2>&1; }

# L1
drive "$(withcloses 5354 "$TEN")"
[ "$RC" = 0 ] && [ -n "$RPT" ] && ok || bad "L1 tick rc=$RC, no report: $(tail -5 "$T/out")"
[ "$(rv)" = MERGE-WITH-NOTES ] && ok || bad "L1 report verdict '$(rv)', want MERGE-WITH-NOTES"
[ "$(grep -c '^- \[NOTE\] outcome cap: ' "$RPT" 2>/dev/null)" = 1 ] && ! grep -q '^- \[BLOCK' "$RPT" \
  && ok || bad "L1 want exactly one NOTE cap line and no BLOCK line: $(grep '^- \[' "$RPT" 2>/dev/null)"
[ "$(lastline)" = "VERDICT: MERGE-WITH-NOTES" ] && ok || bad "L1 last line '$(lastline)'"
grep -qx '> VERDICT: MERGE-WITH-NOTES' "$RPT" 2>/dev/null && ok || bad "L1 the agent verdict line is not kept as a blockquote"
[ -n "$RPT" ] && [ "$(lrv "$RPT")" = MERGE-WITH-NOTES ] && ok || bad "L1 lr_verdict reads '$( [ -n "$RPT" ] && lrv "$RPT")'"
[ "$(posted MERGE-WITH-NOTES)" -ge 1 ] && [ "$(posted BLOCK)" = 0 ] && ok || bad "L1 posts: $(grep -o '"verdict":"[^"]*"' "$T/log/worker" 2>/dev/null)"
if command -v node >/dev/null 2>&1 && [ -n "$RPT" ]; then
  nf=$(node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const { findings } = await import(process.argv[1]);
    const f = findings(readFileSync(process.argv[2], "utf8"));
    const hit = f.note.filter((n) => n.tag === "NOTE" && n.text.includes("claim 10"));
    console.log(`${f.block.length} ${hit.length}`);' "$SRC/mcp/tools/lead-review.mjs" "$RPT" 2>&1)
  [ "$nf" = "0 1" ] && ok || bad "L1 findings() want 0 BLOCK and 1 NOTE naming claim 10, got '$nf'"
else echo "note: node missing, L1 findings() check skipped"
fi

# L2
drive "$(withcloses 8401 "$TEN")"
[ "$(rv)" = BLOCK ] && ok || bad "L2 perf-gate: report verdict '$(rv)', want BLOCK ($(tail -3 "$T/out"))"
[ "$(grep -c '^- \[BLOCK wrong-data\] outcome cap: ' "$RPT" 2>/dev/null)" = 1 ] && ok || bad "L2 want one BLOCK cap line: $(grep '^- \[' "$RPT" 2>/dev/null)"
[ "$(lastline)" = "VERDICT: BLOCK" ] && [ -n "$RPT" ] && [ "$(lrv "$RPT")" = BLOCK ] && ok || bad "L2 last line '$(lastline)'"
[ "$(posted BLOCK)" -ge 1 ] && grep -q '^- \[BLOCK' "$RPT" 2>/dev/null && ok || bad "L2 no BLOCK post or the land grep misses"

# L3: strict mode keeps a classless BLOCK; the writer refuses it
printf 'Findings\n- [NOTE] a.txt:2: x\n\nVERDICT: BLOCK\n' > "$T/agent-answer"
REVIEW_LEVEL_MODE=strict drive "$(withcloses 5354 "$FX2/body-all-confirmed.md")"
grep -q '"outcome":"failed".*block-no-finding' "$T/log/worker" 2>/dev/null && ok \
  || bad "L3 no failed post with block-no-finding: $(grep -o '"outcome":"[^"]*"[^}]*' "$T/log/worker" 2>/dev/null)"
[ "$(posted BLOCK)" = 0 ] && ok || bad "L3 a BLOCK verdict was posted: $(grep -o '"verdict":"[^"]*"' "$T/log/worker")"
lrlog | grep -q "has no '- \[BLOCK' finding line; refused" && ok || bad "L3 no refusal line: $(tail -5 "$T/out")"
rm -f "$T/agent-answer"

# L4
drive "$(withcloses 5354 "$FX2/body-all-confirmed.md")"
[ "$(rv)" = MERGE-WITH-NOTES ] && ! grep -q 'outcome cap' "$RPT" 2>/dev/null && ok || bad "L4 all CONFIRMED: verdict '$(rv)'"
[ "$(awk 'f; /^- pr body: /{getline; f=1}' "$RPT")" = "$(printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES')" ] \
  && ok || bad "L4 the report body is not the agent output verbatim"

echo "lead-review-inconclusive-note.bh-8338: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

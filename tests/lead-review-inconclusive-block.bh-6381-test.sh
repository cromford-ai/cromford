#!/bin/bash
# tests/lead-review-inconclusive-block.bh-6381-test.sh — BH-6381 (BH-6372.3):
# an INCONCLUSIVE claim row in a perf/cost PR's evidence table caps the lead
# verdict at BLOCK (bin/lib/lead-outcome-cap.sh, wired into bin/lead-review.sh).
#
# Unit cases, the lib alone:
#   U1  loc_inconclusive_rows on the real #5454 body: the 18 INCONCLUSIVE claim
#       rows, claim 8 (CONFIRMED) not among them
#   U2  the settled-tier row, the EVIDENCE VERDICTS line, REBASE_VERIFY_INCONCLUSIVE
#       and prose are not rows (rc 1)
#   U3  a blockquoted row, a lower-case row, a CONFIRMED row whose note says
#       "inconclusive" are not rows
#   U4  loc_cap MERGE-WITH-NOTES on a one-row body and a perf ticket: BLOCK and a
#       reason naming claim 2 and the perf phrase
#   U5  loc_demote blockquotes each verdict-shaped line, nothing else
#   U6  verdict BLOCK in: BLOCK out, rc 1, no reason
#   U7  verdict MERGE on a perf ticket: BLOCK, rc 0
#   U8  no ticket at all, or a ticket read that fails: not capped, one stderr
#       line `perf class unknown`
#   U9  a bad knob value reads as perf, with one stderr line naming it
# Tick cases, the REAL bin/lead-review.sh tick (the rig of
# tests/lead-review-thread-refs.bh-5905-test.sh; the agent stub answers
# findings and `VERDICT: MERGE-WITH-NOTES`):
#   L1  one INCONCLUSIVE row, Closes #5354 (perf): the report says BLOCK, has an
#       `- outcome cap:` line, ends `VERDICT: BLOCK`; the result posts BLOCK
#   L2  all rows CONFIRMED: the agent verdict, no cap line, the agent text verbatim
#   L3a a non-perf ticket (#6049) under the default knob: not capped
#   L3b the same under LEAD_REVIEW_INCONCLUSIVE_BLOCK=all: capped
#   L4  knob off: not capped
#   L5  only the settled-tier row: not capped
#   R2  the #5454 body verbatim (Closes #5368): capped through the parent hop to
#       #5354, 18 rows named
#   R3  the real lr_verdict on R2's report reads BLOCK
#   N1  a second tick on R2's head replays the report: no agent call, BLOCK posted
#   N2  R2 with the #5368 read failing: not capped, one `perf class unknown` log line
#   C1  the checklist is version 7 and names the outcome replay
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-inconclusive-block.bh-6381-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/bh-6372"; FX2="$SRC/tests/fixtures/bh-6381"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in "$FX/pr-5454.json" "$FX/issue-5354.json" "$FX/issue-5368.json" "$FX/issue-6049.json" \
         "$FX2/body-one-inconclusive.md" "$FX2/body-all-confirmed.md" "$FX2/body-negatives.md"; do
  [ -r "$f" ] || { echo "FAIL: fixture missing: $f"; exit 1; }
done
LIB_SRC="$SRC/bin/lib/lead-outcome-cap.sh"

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
jq -r '.body' "$FX/pr-5454.json" > "$T/body-5454.md"

o="$T/origin.git"; w="$T/work"
git init -q --bare -b main "$o"; git init -q -b main "$w"
printf '# bh\n' > "$w/CLAUDE.md"; echo one > "$w/a.txt"
git -C "$w" add -A; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qm base
git -C "$w" push -q "$o" main
echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@example.invalid -c user.name=t commit -qam "pr change"
git -C "$w" push -q "$o" "HEAD:refs/pull/41/head"
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
    if [ "\$(cat "$T/jobstate" 2>/dev/null)" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# gh: the PR, its comments, and issues/<n> from $T/fx/<n>.json; any other issue
# (and any number listed in $T/gh-fail) answers 404. Every argv is logged.
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
    if [ -r "$T/fx/\$n.json" ] && ! grep -qx "\$n" "$T/gh-fail" 2>/dev/null; then
      printf 'HTTP/2 200\r\n\r\n'; cat "$T/fx/\$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; fi ;;
esac
exit 0
EOF
# The agent stub counts its calls in $T/calls (outside $T/log, which drive clears).
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/calls"
printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES\n' > "\$5"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/rules-pack.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$H/bin/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 LEAD_REVIEW_THREAD_MAX_BYTES=60000
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW \
  LEAD_REVIEW_INCONCLUSIVE_BLOCK PERF_TICKET_CATALOG GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID
jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,scope_notes:"x",prior_verdict_ref:"v",status:"requested"}],truncated:false}' \
  > "$T/requests.json"
R=example-org/cromford

# ════ Unit cases ════════════════════════════════════════════════════════════
# The lib under test is the checkout's own file, sourced in a fresh shell.
run() { OUT=$(bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" "$@" 2>"$T/err"); RC=$?; }
errn() { grep -c . "$T/err"; }
jq -r '.body' "$FX/issue-5354.json" > "$T/t5354"
jq -r '.body' "$FX/issue-6049.json" > "$T/t6049"
T5354_TITLE=$(jq -r '.title' "$FX/issue-5354.json"); T6049_TITLE=$(jq -r '.title' "$FX/issue-6049.json")

# U1
run loc_inconclusive_rows "$T/body-5454.md"
[ "$RC" = 0 ] && [ "$(grep -c . <<<"$OUT")" = 18 ] && [ "$(grep -c '^| claim ' <<<"$OUT")" = 18 ] \
  && ! grep -q '^| claim 8:' <<<"$OUT" && ok || bad "U1 want 18 claim rows without claim 8, got rc $RC: $(grep -c . <<<"$OUT") lines"
# U2 / U3
run loc_inconclusive_rows "$FX2/body-negatives.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "U2/U3 negatives counted as rows (rc $RC): $OUT"
run loc_inconclusive_rows "$T/nonexistent"
[ "$RC" = 2 ] && ok || bad "U2 an unreadable body is rc 2, got $RC"
run loc_inconclusive_rows "$FX2/body-all-confirmed.md"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "U3 a CONFIRMED row whose note says inconclusive counted: $OUT"
# U4
run loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "$T/t5354" "$T5354_TITLE" "hotfix"
[ "$RC" = 0 ] && [ "$(sed -n 1p <<<"$OUT")" = BLOCK ] && grep -q '(claim 2)' <<<"$(sed -n 2p <<<"$OUT")" \
  && grep -q 'perf phrase:' <<<"$(sed -n 2p <<<"$OUT")" && grep -q '^1 INCONCLUSIVE claim row ' <<<"$(sed -n 2p <<<"$OUT")" \
  && ok || bad "U4 want BLOCK and a reason naming claim 2 and perf phrase:, got rc $RC: $OUT"
# U5
printf 'Findings\n- [NOTE] the verdict is fine\nVERDICT: MERGE-WITH-NOTES\n**VERDICT:** MERGE\n## Verdict: MERGE\nplain line\n' > "$T/demote-in"
run loc_demote "$T/demote-in"
[ "$OUT" = "$(printf 'Findings\n- [NOTE] the verdict is fine\n> VERDICT: MERGE-WITH-NOTES\n> **VERDICT:** MERGE\n> ## Verdict: MERGE\nplain line')" ] \
  && ok || bad "U5 loc_demote output: $OUT"
# U6
run loc_cap BLOCK "$FX2/body-one-inconclusive.md" "$T/t5354" "$T5354_TITLE" ""
[ "$RC" = 1 ] && [ "$OUT" = BLOCK ] && ok || bad "U6 BLOCK in: want BLOCK rc 1, got rc $RC: $OUT"
# U7
run loc_cap MERGE "$FX2/body-one-inconclusive.md" "$T/t5354" "$T5354_TITLE" ""
[ "$RC" = 0 ] && [ "$(sed -n 1p <<<"$OUT")" = BLOCK ] && grep -q 'agent verdict MERGE$' <<<"$OUT" \
  && ok || bad "U7 MERGE on a perf ticket: want BLOCK rc 0, got rc $RC: $OUT"
# U8: no ticket at all
run loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "" "" ""
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && [ "$(errn)" = 1 ] && grep -q 'perf class unknown' "$T/err" \
  && ok || bad "U8 no ticket: want MERGE-WITH-NOTES rc 1 and one 'perf class unknown' line, got rc $RC: $OUT / $(cat "$T/err")"
# U8: the ticket read fails (issue 77 is not served)
: > "$T/log/gh"
run loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "" "" "" "$R" 77
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && [ "$(errn)" = 1 ] && grep -q 'perf class unknown (#77 HTTP 404' "$T/err" \
  && grep -q 'issues/77' "$T/log/gh" && ok || bad "U8 failed read: want not capped and one line naming #77, got rc $RC: $OUT / $(cat "$T/err")"
# U8b: a non-perf ticket is no, not unknown: not capped and no stderr line
run loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "$T/t6049" "$T6049_TITLE" ""
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && [ "$(errn)" = 0 ] && ok || bad "U8b #6049: want not capped, silent; got rc $RC: $OUT / $(cat "$T/err")"
# U9
OUT=$(LEAD_REVIEW_INCONCLUSIVE_BLOCK=bogus bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" \
  loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "$T/t5354" "$T5354_TITLE" "" 2>"$T/err"); RC=$?
[ "$RC" = 0 ] && [ "$(sed -n 1p <<<"$OUT")" = BLOCK ] && [ "$(errn)" = 1 ] && grep -q "'bogus'" "$T/err" \
  && grep -q 'LEAD_REVIEW_INCONCLUSIVE_BLOCK=perf' <<<"$OUT" && ok || bad "U9 bogus on a perf ticket: want BLOCK and one line naming bogus, got rc $RC: $OUT / $(cat "$T/err")"
OUT=$(LEAD_REVIEW_INCONCLUSIVE_BLOCK=bogus bash -c '. "$1" || exit 9; shift; "$@"' loc-run "$LIB_SRC" \
  loc_cap MERGE-WITH-NOTES "$FX2/body-one-inconclusive.md" "$T/t6049" "$T6049_TITLE" "" 2>"$T/err"); RC=$?
[ "$RC" = 1 ] && [ "$OUT" = MERGE-WITH-NOTES ] && grep -q "'bogus'" "$T/err" && ok || bad "U9 bogus on #6049: want not capped, got rc $RC: $OUT"

# ════ Tick cases ════════════════════════════════════════════════════════════
# drive <pr body file> [keep] — one tick. Without `keep` the stored reviews are
# cleared first. The report is $RPT, the tick output $T/out.
drive() {
  rm -f "$T/log"/* "$T/jobstate"; [ "${2:-}" = keep ] || scratch_rm "$H/state/lead-reviews"
  mkdir -p "$H/logs"; : > "$H/logs/lead-review.log"
  cp "$1" "$T/prbody"
  ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?
  RPT=$(ls "$H"/state/lead-reviews/*.md 2>/dev/null | head -1)
}
withcloses() { { printf 'Closes #%s\n\n' "$1"; cat "$2"; } > "$T/body-$1-$(basename "$2")"; printf '%s' "$T/body-$1-$(basename "$2")"; }
rv() { sed -n 's/^- verdict: //p' "$RPT" 2>/dev/null | head -1; }
capline() { grep '^- outcome cap: ' "$RPT" 2>/dev/null; }
lastline() { awk 'NF {l=$0} END {print l}' "$RPT" 2>/dev/null; }
posted() { grep -c '"verdict":"'"$1"'"' "$T/log/worker" 2>/dev/null; }
lrlog() { cat "$H/logs/lead-review.log" "$T/out" 2>/dev/null; }

# L1
drive "$(withcloses 5354 "$FX2/body-one-inconclusive.md")"
[ "$RC" = 0 ] && [ -n "$RPT" ] && ok || bad "L1 tick rc=$RC, no report: $(tail -5 "$T/out")"
[ "$(rv)" = BLOCK ] && ok || bad "L1 report verdict '$(rv)', want BLOCK"
capline | grep -q '(claim 2) on perf phrase:' && ok || bad "L1 no outcome cap line naming claim 2: '$(capline)'"
[ "$(lastline)" = "VERDICT: BLOCK" ] && ok || bad "L1 last line '$(lastline)', want VERDICT: BLOCK"
grep -qx '> VERDICT: MERGE-WITH-NOTES' "$RPT" 2>/dev/null && ok || bad "L1 the agent verdict line is not kept as a blockquote"
[ "$(posted BLOCK)" -ge 1 ] && [ "$(posted MERGE-WITH-NOTES)" = 0 ] && ok || bad "L1 the result post does not carry BLOCK: $(grep -o '"verdict":"[^"]*"' "$T/log/worker")"

# L2
drive "$(withcloses 5354 "$FX2/body-all-confirmed.md")"
[ "$(rv)" = MERGE-WITH-NOTES ] && [ -z "$(capline)" ] && ok || bad "L2 all CONFIRMED: verdict '$(rv)', cap '$(capline)'"
[ "$(awk 'f; /^- pr body: /{getline; f=1}' "$RPT")" = "$(printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES')" ] \
  && ok || bad "L2 the report body is not the agent output verbatim: $(awk 'f; /^- pr body: /{f=1}' "$RPT")"
[ "$(posted MERGE-WITH-NOTES)" -ge 1 ] && ok || bad "L2 the result post does not carry MERGE-WITH-NOTES"

# L3a / L3b
drive "$(withcloses 6049 "$FX2/body-one-inconclusive.md")"
[ "$(rv)" = MERGE-WITH-NOTES ] && [ -z "$(capline)" ] && ok || bad "L3a non-perf under perf: verdict '$(rv)', cap '$(capline)'"
LEAD_REVIEW_INCONCLUSIVE_BLOCK=all drive "$(withcloses 6049 "$FX2/body-one-inconclusive.md")"
[ "$(rv)" = BLOCK ] && capline | grep -q 'on any PR (LEAD_REVIEW_INCONCLUSIVE_BLOCK=all)' && ok \
  || bad "L3b non-perf under all: verdict '$(rv)', cap '$(capline)'"

# L4
LEAD_REVIEW_INCONCLUSIVE_BLOCK=off drive "$(withcloses 5354 "$FX2/body-one-inconclusive.md")"
[ "$(rv)" = MERGE-WITH-NOTES ] && [ -z "$(capline)" ] && ok || bad "L4 knob off: verdict '$(rv)', cap '$(capline)'"

# L5
drive "$(withcloses 5354 "$FX2/body-negatives.md")"
[ "$(rv)" = MERGE-WITH-NOTES ] && [ -z "$(capline)" ] && ok || bad "L5 settled-tier row only: verdict '$(rv)', cap '$(capline)'"

# R2
rm -f "$T/calls"
drive "$T/body-5454.md"
[ "$(rv)" = BLOCK ] && ok || bad "R2 #5454 body: verdict '$(rv)', want BLOCK ($(tail -3 "$T/out"))"
CL=$(capline)
grep -q '^- outcome cap: 18 INCONCLUSIVE claim rows (claim 1, claim 2, ' <<<"$CL" && grep -q 'perf parent:#5354' <<<"$CL" \
  && ! grep -q 'claim 8,' <<<"$CL" && ok || bad "R2 cap line: '$CL'"
grep -q 'issues/5368' "$T/log/gh" && grep -q 'issues/5354' "$T/log/gh" && ok || bad "R2 gh did not read #5368 and #5354: $(cat "$T/log/gh")"
# R3: the real lr_verdict on R2's report
cp "$RPT" "$T/r2-report.md"
OUT=$(bash -c '. "$1/bin/lib/verdict-parse.sh"; eval "$(sed -n "/^lr_verdict() {/,/^}/p" "$1/bin/lead-review.sh")"; lr_verdict "$2"' r3 "$H" "$T/r2-report.md" 2>&1)
[ "$OUT" = BLOCK ] && ok || bad "R3 lr_verdict on the capped report: '$OUT', want BLOCK"
# N1: the second tick on the same head replays, no agent call
c1=$(grep -c . "$T/calls" 2>/dev/null)
drive "$T/body-5454.md" keep
c2=$(grep -c . "$T/calls" 2>/dev/null)
[ "$c1" = 1 ] && [ "$c1" = "$c2" ] && ok || bad "N1 agent calls $c1 then $c2, want 1 and no second call"
lrlog | grep -q 'reusing .* no agent call' && ok || bad "N1 the tick did not take the replay path: $(tail -5 "$T/out")"
[ "$(posted BLOCK)" -ge 1 ] && [ "$(posted MERGE-WITH-NOTES)" = 0 ] && ok || bad "N1 the replay posted $(grep -o '"verdict":"[^"]*"' "$T/log/worker")"

# N2: the #5368 read fails
echo 5368 > "$T/gh-fail"
drive "$T/body-5454.md"
[ "$(rv)" = MERGE-WITH-NOTES ] && [ -z "$(capline)" ] && ok || bad "N2 failed ticket read: verdict '$(rv)', cap '$(capline)'"
[ "$(lrlog | grep -c 'perf class unknown')" = 1 ] && ok || bad "N2 want one 'perf class unknown' log line, got $(lrlog | grep -c 'perf class unknown')"
rm -f "$T/gh-fail"

# ════ C1: the checklist ═════════════════════════════════════════════════════
head -1 "$SRC/prompts/lead-review-checklist.md" | grep -qx 'Checklist-Version: 7' && ok || bad "C1 checklist is not version 7"
grep -q 'outcome replay' "$SRC/prompts/lead-review-checklist.md" && grep -q 'k of N' "$SRC/prompts/lead-review-checklist.md" \
  && ok || bad "C1 checklist does not name the outcome replay and k of N"

echo "lead-review-inconclusive-block.bh-6381: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

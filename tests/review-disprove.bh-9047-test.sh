#!/bin/bash
# tests/review-disprove.bh-9047-test.sh — BH-9047 (C0): the disprove pass on a
# lead review BLOCK. After the lead verdict is BLOCK, ONE bounded model call
# per model BLOCK finding (route review-disprove) tries to prove the finding
# wrong. shadow records and changes nothing; enforce turns a DISPROVED finding
# into a [NOTE]. Fixture model answers only (tests/fixtures/review-disprove.bh-9047/);
# bin/agent-call.sh is a stub, and claude/codex sentinels on PATH record any
# real vendor call (R5 asserts none).
#
#   part U  "$SRC/bin/lib/review-disprove.sh" in a scratch repo with a real
#           diff, with stub setting_get / model_for / llm_gate_spend_today /
#           _jobs_req and a stub bin/agent-call.sh:
#     U1  enforce, 2 findings both DISPROVED: 2 calls, 0 BLOCK lines, 2 NOTE
#         disproved lines, MERGE-WITH-NOTES; the call env and the prompt.
#     U2  shadow, the same answers: the out file is byte-identical.
#     U3  one CONFIRMED, one DISPROVED: BLOCK with only the confirmed finding.
#     U4  rc 1, an empty answer, rc 75: BLOCK unchanged, failed/failed/refused.
#     U5  a secret and an untagged finding DISPROVED: both BLOCKs kept.
#     U6  T-ans, U7 T-find, U10 T-gate: the decision tables.
#     U8  max_findings; U9 the day cap and the spend read; U9t the time floor.
#     U11 a rewrite that leaves no readable verdict: restored, BLOCK stands.
#     U12 the record: the POST body; cost null with no .json; a failed POST.
#     U13 a BLOCK of another shape (`* [BLOCK`, `1. **[BLOCK`, indented, lower
#         case) or a NEEDS_HUMAN: line holds the verdict BLOCK in enforce.
#     U14 (r2) class spelling: only an exact droppable class (any case, trimmed)
#         is dropped; `Secret`, `auth bypass`, `secret, money`, an unknown or
#         an empty class stays BLOCK; `Needs-Human` is skipped.
#     U15 (r2) a location path that starts with `-` or holds `..` is no
#         location, and a DISPROVED answer that cites one is CONFIRMED.
#   part R  "$SRC/bin/lead-review.sh" tick, whole (the BH-6970 part R harness):
#     R1  shadow, a model BLOCK with 2 findings: roles lead.review then
#         review-disprove twice, the header line above `- pr body:`, BLOCK
#         posted, one POST /api/review-disprove.
#     R2  enforce, both DISPROVED: MERGE-WITH-NOTES posted, [NOTE] disproved:.
#     R3  a rules-pack BLOCK: 0 disprove calls, no header line, no POST.
#     R4  a model MERGE: 0 disprove calls; no enabled row: 0 disprove calls.
#     R5  0 real vendor calls over parts U and R.
#   part S  the composed schema: the 8 settings rows, route review-disprove =
#           lead.review rung 0, stage.disprove; a re-apply changes nothing; a
#           model_route_changes row means no seed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-disprove.bh-9047-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
. "$(dirname "$0")/lib/worker-catalogs.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/review-disprove.bh-9047"
LIB="$SRC/bin/lib/review-disprove.sh"
FRAG="$SRC/bin/lib/lead-review/libs.d/202611041848-bh-9047-review-disprove.sh"
PROMPT="$SRC/prompts/lead-review.d/disprove.md"
SEED="$SRC/worker/jobs/schema.d/202611041848-bh-9047-review-disprove.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE AGENT_CALL_ROLE AGENT_CALL_BUDGET_USD AGENT_CALL_NO_TOOLS \
  LEAD_REVIEW_BUILDS_ON_BUILDER HARNESS_VERDICT_AUTHORS HARNESS_OPERATOR_LOGIN BOX_NAME JOBS_BOX HUB_BOX_NAME

[ -f "$LIB" ] && ok || bad "U0 bin/lib/review-disprove.sh does not exist"
[ -f "$FRAG" ] && grep -q 'bin/lib/review-disprove.sh' "$FRAG" && ok || bad "U0 the libs.d fragment does not source bin/lib/review-disprove.sh"
[ -f "$PROMPT" ] && grep -q '^DISPROVED <reason' "$PROMPT" && ok || bad "U0 prompts/lead-review.d/disprove.md is missing or has no answer contract"

# The vendor sentinels (R5): a real claude or codex run anywhere in this suite
# writes $T/vendor-calls. Part U also puts a curl sentinel first on PATH.
mkdir -p "$T/sentinel" "$T/usentinel"
for v in claude codex; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor-calls"\nexit 99\n' "$v" "$T" > "$T/sentinel/$v"; done
printf '#!/bin/bash\necho "curl $*" >> "%s/vendor-calls"\nexit 99\n' "$T" > "$T/usentinel/curl"
chmod +x "$T/sentinel/"* "$T/usentinel/curl"
PATH0="$PATH"; PATH="$T/usentinel:$T/sentinel:$PATH"; export PATH

# ── the scratch repo: bin/a.sh has 50 lines; the head changes lines 4 and 12 ──
ORIG="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$ORIG"; git init -q -b main "$WK"
mkdir -p "$WK/bin"
for i in $(seq 1 50); do echo "line $i"; done > "$WK/bin/a.sh"
printf 'dash %s\n' 1 2 3 4 5 > "$WK/-oops.sh"   # U15: a real head file whose name starts with a dash
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$ORIG" main
sed -i -e 's/^line 4$/line 4 parses the flag/' -e 's/^line 12$/line 12 reads the name/' "$WK/bin/a.sh"
git -C "$WK" commit -qam "BH-9001: a"; HS=$(git -C "$WK" rev-parse HEAD); git -C "$WK" push -q "$ORIG" "HEAD:refs/heads/h"
WT="$T/wt"; git clone -q "$ORIG" "$WT"; git -C "$WT" fetch -q origin h; git -C "$WT" checkout -q --detach "$HS"

# ═══════════════════════ part U: bin/lib/review-disprove.sh ═══════════════════════
UH="$T/uh"; mkdir -p "$UH/bin" "$UH/prompts/lead-review.d" "$T/log" "$T/set" "$T/ans"
cp "$PROMPT" "$UH/prompts/lead-review.d/" 2>/dev/null
# agent-call stub: call n answers $T/ans/<n> (else $T/ans/default), exits
# $T/acrc.<n> (else 0) and writes <answer>.json when $T/cost.<n> exists.
cat > "$UH/bin/agent-call.sh" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/log/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/log/n"
echo "\$*" >> "$T/log/calls"
env | grep '^AGENT_CALL_' | sort > "$T/log/env.\$n"
cp "\${6#@}" "$T/log/prompt.\$n"
if [ -f "$T/ans/\$n" ]; then cat "$T/ans/\$n" > "\$5"; else cat "$T/ans/default" > "\$5" 2>/dev/null; fi
[ -f "$T/cost.\$n" ] && printf '{"total_cost_usd":%s}\n' "\$(cat "$T/cost.\$n")" > "\$5.json"
exit "\$(cat "$T/acrc.\$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$UH/bin/agent-call.sh"
HARNESS="$UH"; H="$UH"
setting_get() { [ -e "$T/set-unreadable" ] && return 1; [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
model_for() { [ -e "$T/no-route" ] && return 75; [ "$1" = review-disprove ] && echo fixture-disprove-model; }
log() { echo "$*" >> "$T/log/lane"; }
llm_gate_spend_today() { echo "$1" >> "$T/log/spend"; [ -f "$T/spend" ] || return 1; cat "$T/spend"; }
_jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/log/jobs"; JOBS_HTTP=201; return "$(cat "$T/jobsrc" 2>/dev/null || echo 0)"; }
# lr_verdict, as bin/lead-review.sh reads a verdict: the last non-blank line
# is exactly `VERDICT: <word>`. Part R runs the real one.
lr_verdict() {
  local last; last=$(tr -d '\r' < "$1" | awk 'NF { l = $0 } END { print l }' | sed 's/[[:space:]]*$//')
  case "$last" in "VERDICT: MERGE-WITH-NOTES"|"VERDICT: BLOCK"|"VERDICT: MERGE") printf '%s' "${last#VERDICT: }" ;; *) printf unknown ;; esac
}
# shellcheck source=bin/lib/review-disprove.sh
. "$LIB" 2>/dev/null || bad "U0 bin/lib/review-disprove.sh does not source"
# The real gate after the review (bin/lead-review.sh): a BLOCK with no
# `- [BLOCK` line is refused as block-no-finding. U13 runs it on each rewrite.
# shellcheck source=bin/lib/lead-review/outcome-cap.sh
. "$SRC/bin/lib/lead-review/outcome-cap.sh" 2>/dev/null || bad "U0 bin/lib/lead-review/outcome-cap.sh does not source"
OUTF="$T/review.out"
reset_u() { # reset_u <report fixture> <mode|-> [enabled, default 1] — a clean slate
  rm -rf "$T/log" "$T/wt.dp"; mkdir -p "$T/log"
  rm -f "$T/acrc."* "$T/cost."* "$T/ans/"* "$T/no-route" "$T/set/"* "$T/set-unreadable" "$T/jobsrc"
  printf '0' > "$T/spend"
  cp "$FX/answer-disproved.txt" "$T/ans/default"
  printf '%s' "${3-1}" > "$T/set/review.disprove.demo-os.enabled"
  [ "$2" = - ] || printf '%s' "$2" > "$T/set/review.disprove.mode"
  cp "$FX/$1" "$OUTF"; cp "$OUTF" "$T/out.before"
}
review() { DPR=$(dp_review example-org/demo-os 77 "$HS" demo-os "$WT" main "$OUTF" "${1:-600}" lr-1); }
calls() { [ -f "$T/log/calls" ] && wc -l < "$T/log/calls" | tr -d ' ' || echo 0; }
nblock() { grep -c '^- \[BLOCK' "$OUTF"; }
outcomes() { cut -f2 "$T/wt.dp/outcomes.tsv" 2>/dev/null | paste -sd, -; }
rec() { jq -r "$1" "$T/wt.dp/record.json" 2>/dev/null; }

# ── U1 enforce, 2 findings, both DISPROVED ──
reset_u report-two.md enforce; review
[ "$DPR" = "ran enforce 1" ] && ok || bad "U1 dp_review printed '$DPR', want 'ran enforce 1': $(cat "$T/log/lane" 2>/dev/null)"
[ "$(calls)" = 2 ] && ok || bad "U1 $(calls) agent call(s), want 2"
[ "$(nblock)" = 0 ] && ok || bad "U1 $(nblock) BLOCK line(s) left: $(cat "$OUTF")"
[ "$(grep -c '^- \[NOTE\] disproved:' "$OUTF")" = 2 ] && ok || bad "U1 want 2 NOTE disproved lines: $(cat "$OUTF")"
grep -qxF -- '- [NOTE] disproved: (wrong-data) bin/a.sh:12: line 12 drops the name when the input is empty | disprove: the guard at bin/a.sh:11 returns first on an empty name' "$OUTF" \
  && ok || bad "U1 the wrong-data NOTE line: $(grep disproved "$OUTF")"
[ "$(lr_verdict "$OUTF")" = MERGE-WITH-NOTES ] && ok || bad "U1 verdict '$(lr_verdict "$OUTF")', want MERGE-WITH-NOTES"
grep -qxF -- '- [NOTE] bin/a.sh:30: a comment says "lines" for one line' "$OUTF" && ok || bad "U1 a NOTE the model wrote changed"
for k in 1 2; do
  E="$T/log/env.$k"
  grep -qx 'AGENT_CALL_ROLE=review-disprove' "$E" && ok || bad "U1 call $k role: $(cat "$E" 2>/dev/null)"
  grep -qx 'AGENT_CALL_GUARD_STAGE=lead-head' "$E" && ok || bad "U1 call $k guard stage is not lead-head"
  grep -qx 'AGENT_CALL_NO_TOOLS=1' "$E" && ok || bad "U1 call $k has tools"
  grep -qx 'AGENT_CALL_BUDGET_USD=0.50' "$E" && ok || bad "U1 call $k budget is not the 0.50 fallback"
  grep -qE "^AGENT_CALL_FP=lead:example-org/demo-os#77@$HS~dp[0-9a-f]{12}\$" "$E" && ok || bad "U1 call $k fp: $(grep FP "$E")"
done
[ "$(sed -n 's/^AGENT_CALL_FP=//p' "$T/log/env.1")" != "$(sed -n 's/^AGENT_CALL_FP=//p' "$T/log/env.2")" ] && ok || bad "U1 two findings share one fp"
case "$(head -n 1 "$T/log/calls" 2>/dev/null)" in "disprove demo-os fixture-disprove-model "*) ok ;; *) bad "U1 agent-call args: $(head -n 1 "$T/log/calls")" ;; esac
P="$T/log/prompt.1"
n=$(wc -l < "$PROMPT"); head -n "$n" "$P" 2>/dev/null | cmp -s - "$PROMPT" && ok || bad "U1 the prompt does not start with disprove.md verbatim"
grep -qxF -- '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' "$P" && ok || bad "U1 the prompt lacks the finding"
grep -qxF -- '+line 12 reads the name' "$P" && ok || bad "U1 the prompt lacks the hunk"
grep -qE '^ +12  line 12 reads the name$' "$P" && grep -qE '^ +52  ' "$P" && bad "U1 the excerpt passes the file end" || ok
grep -qE '^ +12  line 12 reads the name$' "$P" && grep -qE '^ +1  line 1$' "$P" && grep -qE '^ +50  line 50$' "$P" && ok || bad "U1 the prompt lacks the file excerpt at head"
grep -qxF -- '- [BLOCK core-flow-broken] bin/a.sh:4-5: the flag parse exits before the main call' "$T/log/prompt.2" && ok || bad "U1 call 2 prompt lacks its own finding"
grep -q 'line 12 drops' "$T/log/prompt.2" && bad "U1 call 2 prompt carries the other finding" || ok
grep -q '^- disprove (BH-9047): mode enforce; 2 finding(s): 0 confirmed, 2 disproved, 0 kept (protected), 0 unchecked; verdict BLOCK -> MERGE-WITH-NOTES$' "$T/wt.dp/report" \
  && ok || bad "U1 the report header: $(head -n 1 "$T/wt.dp/report" 2>/dev/null)"
grep -qE '^  - disprove DISPROVED wrong-data bin/a.sh:12: ' "$T/wt.dp/report" && ok || bad "U1 no indented line for the wrong-data finding"
grep -qE '\[BLOCK|^VERDICT' "$T/wt.dp/report" && bad "U1 the report lines carry a BLOCK or VERDICT token" || ok

# ── U2 shadow, the same answers: byte-identical ──
reset_u report-two.md shadow; review
[ "$DPR" = "ran shadow 0" ] && ok || bad "U2 '$DPR', want 'ran shadow 0'"
cmp -s "$OUTF" "$T/out.before" && ok || bad "U2 shadow changed the review out"
[ "$(calls)" = 2 ] && ok || bad "U2 shadow made $(calls) calls, want 2"
[ "$(rec .disproved)" = 2 ] && [ "$(rec .verdict_after)" = BLOCK ] && [ "$(rec .mode)" = shadow ] && ok \
  || bad "U2 the record: disproved=$(rec .disproved) verdict_after=$(rec .verdict_after) mode=$(rec .mode)"
grep -q '(shadow: unchanged)$' "$T/wt.dp/report" && ok || bad "U2 the header does not say shadow: $(head -n 1 "$T/wt.dp/report")"
reset_u report-two.md -; review
[ "$DPR" = "ran shadow 0" ] && cmp -s "$OUTF" "$T/out.before" && ok || bad "U2 no mode row is not shadow: '$DPR'"

# ── U3 one CONFIRMED, one DISPROVED ──
reset_u report-two.md enforce; cp "$FX/answer-confirmed.txt" "$T/ans/1"; review
[ "$(lr_verdict "$OUTF")" = BLOCK ] && ok || bad "U3 verdict '$(lr_verdict "$OUTF")', want BLOCK"
[ "$(nblock)" = 1 ] && grep -qxF -- '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' "$OUTF" && ok \
  || bad "U3 want only the confirmed BLOCK: $(grep BLOCK "$OUTF")"
[ "$(grep -c '^- \[NOTE\] disproved: (core-flow-broken)' "$OUTF")" = 1 ] && ok || bad "U3 want 1 NOTE disproved line"
[ "$(outcomes)" = "CONFIRMED,DISPROVED" ] && [ "$(rec .confirmed)" = 1 ] && [ "$(rec .disproved)" = 1 ] && ok || bad "U3 outcomes '$(outcomes)'"
[ "$DPR" = "ran enforce 1" ] && ok || bad "U3 '$DPR'"

# ── U4 the call fails: rc 1 (with a DISPROVED answer), an empty answer, rc 75 ──
reset_u report-three.md enforce; echo 1 > "$T/acrc.1"; : > "$T/ans/2"; echo 75 > "$T/acrc.3"; review
[ "$(outcomes)" = "failed,failed,unchecked:refused" ] && ok || bad "U4 outcomes '$(outcomes)', want failed,failed,unchecked:refused"
cmp -s "$OUTF" "$T/out.before" && ok || bad "U4 a failed call changed the review out"
[ "$(lr_verdict "$OUTF")" = BLOCK ] && [ "$DPR" = "ran enforce 0" ] && ok || bad "U4 '$DPR', verdict $(lr_verdict "$OUTF")"
[ "$(rec .confirmed)" = 2 ] && [ "$(rec .unchecked)" = 1 ] && [ "$(rec .disproved)" = 0 ] && ok || bad "U4 counts: $(cat "$T/wt.dp/record.json")"

# ── U5 protected classes: secret and untagged keep their BLOCK ──
reset_u report-protected.md enforce; review
[ "$(lr_verdict "$OUTF")" = BLOCK ] && ok || bad "U5 verdict '$(lr_verdict "$OUTF")', want BLOCK"
grep -q '^- \[BLOCK secret\] bin/a.sh:12: line 12 prints a token to the log | disprove-said: DISPROVED the guard at bin/a.sh:11 returns first on an empty name (kept: secret is never auto-dropped)$' "$OUTF" \
  && ok || bad "U5 the secret line: $(grep secret "$OUTF")"
grep -q '^- \[BLOCK\] bin/a.sh:4: the flag parse exits before the main call | disprove-said: DISPROVED .*(kept: untagged is never auto-dropped)$' "$OUTF" \
  && ok || bad "U5 the untagged line: $(grep 'BLOCK\]' "$OUTF")"
grep -q 'disproved:' "$OUTF" && bad "U5 a protected finding became a NOTE" || ok
[ "$(outcomes)" = "KEPT,KEPT" ] && [ "$(rec .kept_protected)" = 2 ] && [ "$(rec .disproved)" = 0 ] && ok || bad "U5 outcomes '$(outcomes)'"

# ── U6 T-ans: the last non-blank line of the answer → outcome ──
A="$T/ans.txt"
while IFS='|' read -r pre last want; do
  { [ -n "$pre" ] && printf '%s\n\n' "$pre"; printf '%s\n' "$last"; } > "$A"
  got=$(dp_parse_answer "$A" "$WT" "$HS" | cut -f1)
  [ "$got" = "$want" ] && ok || bad "U6 T-ans '$pre' / '$last': $got, want $want"
done <<'TABLE'
|DISPROVED the guard at bin/a.sh:40 returns first|DISPROVED
|DISPROVED see bin/a.sh:4-9|DISPROVED
|CONFIRMED bin/a.sh:12|CONFIRMED
|CONFIRMED|CONFIRMED
|DISPROVED it is fine|CONFIRMED
|DISPROVED nope/ghost.sh:3|CONFIRMED
|DISPROVED bin/a.sh:0|CONFIRMED
|DISPROVED bin/a.sh:999 is past the end|CONFIRMED
|disproved bin/a.sh:4|CONFIRMED
|NOT DISPROVED bin/a.sh:4|CONFIRMED
|> DISPROVED bin/a.sh:4|CONFIRMED
|**DISPROVED** bin/a.sh:4|CONFIRMED
DISPROVED the guard bin/a.sh:4|CONFIRMED bin/a.sh:2|CONFIRMED
CONFIRMED bin/a.sh:12|DISPROVED the guard at bin/a.sh:4|DISPROVED
|DISPROVED ../a.sh:4 climbs out|CONFIRMED
TABLE
printf '\n\n' > "$A"; [ "$(dp_parse_answer "$A" "$WT" "$HS" | cut -f1)" = CONFIRMED ] && ok || bad "U6 T-ans an empty answer is not CONFIRMED"
# The empty answer through dp_review is `failed` (counted confirmed), and an
# injected DISPROVED line inside the answer does not count.
reset_u report-two.md enforce; : > "$T/ans/1"; cp "$FX/answer-injected.txt" "$T/ans/2"; review
[ "$(outcomes)" = "failed,CONFIRMED" ] && cmp -s "$OUTF" "$T/out.before" && ok || bad "U6 empty + injected: '$(outcomes)'"
printf 'x\nDISPROVED a reason [with] `ticks` at bin/a.sh:4\r\n' > "$A"
[ "$(dp_parse_answer "$A" "$WT" "$HS" | cut -f2)" = "a reason with ticks at bin/a.sh:4" ] && ok || bad "U6 the reason is not cleaned: $(dp_parse_answer "$A" "$WT" "$HS" | cut -f2)"

# ── U7 T-find: a review line → selection (kind, protected, class, loc) ──
dp_extract "$FX/report-mixed.md" | cut -f2- > "$T/find.got"
cat > "$T/find.want" <<'EOF'
check	0	wrong-data	bin/a.sh:12
check	1	secret	bin/a.sh:3
check	1	-	bin/a.sh:3
skip	0	needs-human	bin/a.sh:3
skip	0	split-required	-
skip	0	red-build	bin/a.sh:3
skip	0	wrong-data	-
noloc	0	wrong-data	-
check	0	model-id	bin/a.sh:7
noloc	0	wrong-data	-
EOF
cmp -s "$T/find.got" "$T/find.want" && ok || bad "U7 T-find: $(diff "$T/find.want" "$T/find.got")"
# Only model findings with a location are called; a no-location one is unchecked:no-loc.
reset_u report-mixed.md shadow; printf '9' > "$T/set/review.disprove.max_findings"; review
[ "$(calls)" = 4 ] && ok || bad "U7 report-mixed made $(calls) call(s), want 4"
[ "$(rec .findings)" = 6 ] && [ "$(rec .unchecked)" = 2 ] && ok || bad "U7 findings $(rec .findings) unchecked $(rec .unchecked), want 6 and 2"
reset_u report-mixed.md enforce; printf '9' > "$T/set/review.disprove.max_findings"; review
[ "$(lr_verdict "$OUTF")" = BLOCK ] && grep -q '^- \[BLOCK needs-human\]' "$OUTF" && grep -qxF -- '- [BLOCK wrong-data] the whole flow is wrong' "$OUTF" \
  && ok || bad "U7 enforce on report-mixed dropped a mechanical or unchecked BLOCK"

# ── U8 max_findings: 7 findings, 5 calls by default; the row 2: 2 calls ──
# (usd_cap_day 50: the 2 USD day cap would stop the pass after 4 calls of 0.50)
reset_u report-seven.md shadow; printf '50' > "$T/set/review.disprove.usd_cap_day"; review
[ "$(calls)" = 5 ] && [ "$(outcomes)" = "DISPROVED,DISPROVED,DISPROVED,DISPROVED,DISPROVED,unchecked:cap,unchecked:cap" ] && ok \
  || bad "U8 default: $(calls) call(s), outcomes '$(outcomes)'"
reset_u report-seven.md shadow; printf ' 2 ' > "$T/set/review.disprove.max_findings"; review
[ "$(calls)" = 2 ] && ok || bad "U8 max_findings=2: $(calls) call(s)"
reset_u report-seven.md shadow; printf '0' > "$T/set/review.disprove.max_findings"; printf '50' > "$T/set/review.disprove.usd_cap_day"; review
[ "$(calls)" = 5 ] && ok || bad "U8 max_findings=0 did not fall back to 5: $(calls)"

# ── U9 the day cap and the spend read ──
reset_u report-two.md enforce; printf '1.6' > "$T/spend"; review
[ "$(calls)" = 0 ] && [ "$(outcomes)" = "unchecked:cap,unchecked:cap" ] && ok || bad "U9 spend 1.6: $(calls) call(s), '$(outcomes)'"
cmp -s "$OUTF" "$T/out.before" && ok || bad "U9 a capped pass changed the review out"
grep -q 'usd_cap_day (2 USD) reached' "$T/log/lane" && ok || bad "U9 the cap is not logged"
grep -qx disprove "$T/log/spend" && ok || bad "U9 the spend read is not stage disprove: $(cat "$T/log/spend" 2>/dev/null)"
reset_u report-two.md enforce; rm -f "$T/spend"; review
[ "$(calls)" = 0 ] && [ "$(outcomes)" = "unchecked:spend-unknown,unchecked:spend-unknown" ] && ok || bad "U9 spend unreadable: $(calls) call(s), '$(outcomes)'"
reset_u report-two.md enforce; printf 'lots' > "$T/spend"; review
[ "$(calls)" = 0 ] && ok || bad "U9 a non-number spend made $(calls) call(s)"
reset_u report-two.md enforce; printf '0' > "$T/spend"; review
[ "$(calls)" = 2 ] && ok || bad "U9 spend 0: $(calls) call(s), want 2"
# the pass's own spend counts: 1.0 spent, budget 0.50, cap 2 → 2 calls, then cap
reset_u report-seven.md shadow; printf '1.0' > "$T/spend"; review
[ "$(calls)" = 2 ] && ok || bad "U9 spend 1.0 + 0.50 a call: $(calls) call(s), want 2"
reset_u report-two.md shadow; printf '0' > "$T/spend"; printf '0.10' > "$T/set/review.disprove.usd_cap_day"; review
[ "$(calls)" = 0 ] && ok || bad "U9 usd_cap_day 0.10 under one 0.50 call: $(calls) call(s)"
reset_u report-two.md shadow; printf '0.75' > "$T/set/review.disprove.call_budget_usd"; review
grep -qx 'AGENT_CALL_BUDGET_USD=0.75' "$T/log/env.1" && ok || bad "U9 the budget row 0.75 is not the call budget"
# U9t the time floor: 100 s left under min_left_s 120 → no call
reset_u report-two.md shadow; review 100
[ "$(calls)" = 0 ] && [ "$(outcomes)" = "unchecked:time,unchecked:time" ] && ok || bad "U9t 100 s left: $(calls) call(s), '$(outcomes)'"

# ── U10 T-gate: enabled and mode rows → behavior ──
while IFS='|' read -r en mode want; do
  reset_u report-two.md "$mode" "$en"
  [ "$en" = '<none>' ] && rm -f "$T/set/review.disprove.demo-os.enabled"
  [ "$en" = '<unreadable>' ] && : > "$T/set-unreadable"
  review
  [ "$DPR" = "$want" ] && ok || bad "U10 T-gate enabled '$en' mode '$mode': '$DPR', want '$want'"
  case "$want" in skipped:*) [ "$(calls)" = 0 ] && [ ! -e "$T/wt.dp/record.json" ] && ok || bad "U10 T-gate '$en': a skipped pass called or recorded" ;; esac
done <<'TABLE'
1|shadow|ran shadow 0
 1 | Enforce |ran enforce 1
1|enforced|ran shadow 0
1|-|ran shadow 0
0|enforce|skipped:off off 0
yes|enforce|skipped:off off 0
<none>|enforce|skipped:off off 0
<unreadable>|enforce|skipped:off off 0
TABLE
reset_u report-two.md enforce; : > "$T/no-route"; review
[ "$DPR" = "skipped:no-route enforce 0" ] && [ "$(calls)" = 0 ] && ok || bad "U10 no route: '$DPR', $(calls) call(s)"
reset_u lead-merge.md enforce; review
[ "$DPR" = "skipped:not-block enforce 0" ] && [ "$(calls)" = 0 ] && ok || bad "U10 a MERGE: '$DPR'"
reset_u report-two.md enforce; printf '## Findings\n\n- [BLOCK needs-human] bin/a.sh:3: a key\n\nVERDICT: BLOCK\n' > "$OUTF"; review
[ "$DPR" = "skipped:no-finding enforce 0" ] && [ "$(calls)" = 0 ] && [ ! -s "$T/log/jobs" ] && ok || bad "U10 a mechanical-only BLOCK: '$DPR'"

# ── U11 a rewrite that leaves no readable verdict: restored, BLOCK stands ──
# The verdict reader is the one that decides; it is made to fail on the rewrite.
eval "$(declare -f lr_verdict | sed '1s/lr_verdict/lr_verdict_real/')"
lr_verdict() { grep -q 'disproved:' "$1" && { printf unknown; return 0; }; lr_verdict_real "$1"; }
reset_u report-two.md enforce; review
[ "$DPR" = "ran enforce 0" ] && ok || bad "U11 '$DPR', want 'ran enforce 0'"
cmp -s "$OUTF" "$T/out.before" && ok || bad "U11 the out is not restored"
[ ! -e "$OUTF.dpkeep" ] && [ ! -e "$OUTF.dpnew" ] && ok || bad "U11 a temp file is left"
grep -q 'verdict BLOCK -> BLOCK (the rewrite left no readable verdict; the BLOCK stands)$' "$T/wt.dp/report" && ok || bad "U11 header: $(head -n 1 "$T/wt.dp/report")"
[ "$(rec .verdict_after)" = BLOCK ] && ok || bad "U11 the record says verdict_after $(rec .verdict_after)"
eval "$(declare -f lr_verdict_real | sed '1s/lr_verdict_real/lr_verdict/')"

# ── U12 the record ──
reset_u report-two.md enforce; review
B=$(sed -n 's#^POST /api/review-disprove ##p' "$T/log/jobs" 2>/dev/null)
[ "$(grep -c '^POST /api/review-disprove ' "$T/log/jobs")" = 1 ] && ok || bad "U12 want one POST: $(cat "$T/log/jobs" 2>/dev/null)"
[ "$(jq -r '[.repo, .pr, .head_sha, .review_id, .lane, .mode, .project] | join(" ")' <<<"$B")" = "example-org/demo-os 77 $HS lr-1 lead enforce demo-os" ] && ok \
  || bad "U12 the body ids: $B"
[ "$(jq -r '[.findings, .checked, .confirmed, .disproved, .kept_protected, .unchecked] | join(",")' <<<"$B")" = "2,2,0,2,0,0" ] && ok || bad "U12 counts: $B"
[ "$(jq -r '.verdict_before + ">" + .verdict_after' <<<"$B")" = "BLOCK>MERGE-WITH-NOTES" ] && ok || bad "U12 verdicts: $B"
[ "$(jq -r '.cost_usd' <<<"$B")" = null ] && ok || bad "U12 cost with no .json is not null: $(jq -r .cost_usd <<<"$B")"
[ "$(jq -r '.detail[0] | [.cls, .loc, .outcome] | join(" ")' <<<"$B")" = "wrong-data bin/a.sh:12 DISPROVED" ] && ok || bad "U12 detail[0]: $(jq -c '.detail[0]' <<<"$B")"
reset_u report-two.md shadow; echo 0.12 > "$T/cost.1"; echo 0.03 > "$T/cost.2"; review
[ "$(rec '.cost_usd')" = 0.15 ] && ok || bad "U12 the cost sum is $(rec .cost_usd), want 0.15"
reset_u report-two.md shadow; echo 0.12 > "$T/cost.1"; review
[ "$(rec '.cost_usd')" = null ] && ok || bad "U12 one unknown cost is not null: $(rec .cost_usd)"
{ printf '## Findings\n\n'; for i in $(seq 1 22); do printf -- '- [BLOCK wrong-data] finding %s with no location\n' "$i"; done; printf '\nVERDICT: BLOCK\n'; } > "$T/r22.md"
reset_u report-two.md shadow; cp "$T/r22.md" "$OUTF"; review
[ "$(rec '.detail | length')" = 20 ] && [ "$(rec .findings)" = 22 ] && ok || bad "U12 detail length $(rec '.detail | length'), want 20"
reset_u report-two.md enforce; echo 1 > "$T/jobsrc"; review; rc=$?
[ "$rc" = 0 ] && [ "$DPR" = "ran enforce 1" ] && ok || bad "U12 a failed POST changed the pass: rc $rc '$DPR'"
[ "$(grep -c 'POST /api/review-disprove failed' "$T/log/lane")" = 1 ] && ok || bad "U12 a failed POST is not one log line: $(cat "$T/log/lane")"

# ── U13 a BLOCK of another shape holds the verdict (security + refute review) ──
# dp_extract checks only `- [BLOCK` at column 0. The reviewer also counts
# `* [BLOCK x]`, `1. **[BLOCK x]**`, an indented `- [BLOCK x]` and any case
# (bin/lib/review-level.sh RL_FIND_RE). Those are never checked, so with the
# one checked finding DISPROVED the verdict must stay BLOCK.
reset_u report-two.md enforce
printf '%s\n' '## Findings' '' \
  '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' \
  '* [BLOCK secret] bin/a.sh:3: line 3 prints a token' \
  '1. **[BLOCK auth-bypass]** bin/a.sh:5: the token check fails open' \
  '  - [BLOCK money] bin/a.sh:7: double charge' \
  '- [block tenant-leak] bin/a.sh:9: a cross-company read' \
  '' 'VERDICT: BLOCK' > "$OUTF"
for shape in '* [BLOCK secret]' '1. **[BLOCK auth-bypass]**' '  - [BLOCK money]' '- [block tenant-leak]'; do
  cp "$OUTF" "$T/u13.full"
  { sed -n '1,3p' "$T/u13.full"; grep -F -- "$shape" "$T/u13.full"; printf '\nVERDICT: BLOCK\n'; } > "$OUTF"
  cp "$OUTF" "$T/out.before"; rm -rf "$T/log" "$T/wt.dp"; mkdir -p "$T/log"; review
  [ "$(calls)" = 1 ] && ok || bad "U13 '$shape': $(calls) call(s), want 1 (only the column-0 dash line is checked)"
  [ "$(lr_verdict "$OUTF")" = BLOCK ] && ok || bad "U13 '$shape': verdict '$(lr_verdict "$OUTF")', want BLOCK: $(cat "$OUTF")"
  grep -qF -- "$shape" "$OUTF" && ok || bad "U13 '$shape': the unchecked BLOCK line changed"
  # The only `- [BLOCK` line stays a BLOCK with the disprove text, so the
  # report passes lr_block_no_finding and the fix round reads it.
  grep -q '^- \[BLOCK wrong-data\] bin/a.sh:12: .* | disprove-said: DISPROVED .*(kept: another BLOCK holds the verdict)$' "$OUTF" && ok || bad "U13 '$shape': the checked finding is not kept as a BLOCK with the disprove text: $(cat "$OUTF")"
  ! lr_block_no_finding BLOCK "$OUTF" && ok || bad "U13 '$shape': lr_block_no_finding refuses the rewritten report: $(cat "$OUTF")"
  cp "$T/u13.full" "$OUTF"
done
# All four shapes together, as the two reviews ran it.
cp "$OUTF" "$T/out.before"; rm -rf "$T/log" "$T/wt.dp"; mkdir -p "$T/log"; review
[ "$(lr_verdict "$OUTF")" = BLOCK ] && [ "$(calls)" = 1 ] && ok || bad "U13 the mixed review: verdict '$(lr_verdict "$OUTF")', $(calls) call(s)"
! lr_block_no_finding BLOCK "$OUTF" && ok || bad "U13 the mixed review: lr_block_no_finding refuses it: $(cat "$OUTF")"
# A NEEDS_HUMAN: line also holds the verdict.
reset_u report-two.md enforce
printf '%s\n' '## Findings' '' \
  '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' \
  'NEEDS_HUMAN: set the live connector key' '' 'VERDICT: BLOCK' > "$OUTF"
review
[ "$(lr_verdict "$OUTF")" = BLOCK ] && ok || bad "U13 a NEEDS_HUMAN: line: verdict '$(lr_verdict "$OUTF")', want BLOCK"
! lr_block_no_finding BLOCK "$OUTF" && ok || bad "U13 a NEEDS_HUMAN: line: lr_block_no_finding refuses the rewritten report: $(cat "$OUTF")"
grep -q '^- \[BLOCK wrong-data\] .* | disprove-said: DISPROVED ' "$OUTF" && ok || bad "U13 a NEEDS_HUMAN: line: the checked finding lost its BLOCK line: $(cat "$OUTF")"
# A second column-0 BLOCK the model keeps: the DISPROVED one still drops.
reset_u report-two.md enforce
printf '%s\n' '## Findings' '' \
  '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' \
  '- [BLOCK secret] bin/a.sh:3: line 3 prints a token' \
  '* [BLOCK money] bin/a.sh:7: double charge' '' 'VERDICT: BLOCK' > "$OUTF"
review
grep -q '^- \[NOTE\] disproved: (wrong-data)' "$OUTF" && grep -q '^- \[BLOCK secret\] .*never auto-dropped' "$OUTF" \
  && [ "$(lr_verdict "$OUTF")" = BLOCK ] && ! lr_block_no_finding BLOCK "$OUTF" && ok || bad "U13 a kept dash BLOCK: $(cat "$OUTF")"

# ── U14 (r2) class spelling: a finding drops only on an exact droppable class ──
# Every answer is DISPROVED with a real head line (answer-disproved.txt).
dp_extract "$FX/report-classes.md" | cut -f2- > "$T/find.got"
cat > "$T/find.want" <<'EOF'
check	1	Secret	bin/a.sh:3
check	1	AUTH-BYPASS	bin/a.sh:4
check	1	auth bypass	bin/a.sh:5
check	1	secret, money	bin/a.sh:6
check	1	injection	bin/a.sh:7
check	1	-	bin/a.sh:8
check	0	Wrong-Data	bin/a.sh:12
check	0	core-flow-broken	bin/a.sh:13
skip	0	Needs-Human	bin/a.sh:9
EOF
cmp -s "$T/find.got" "$T/find.want" && ok || bad "U14 T-find r2 rows: $(diff "$T/find.want" "$T/find.got")"
reset_u report-classes.md enforce; printf '20' > "$T/set/review.disprove.max_findings"; printf '10' > "$T/set/review.disprove.usd_cap_day"; review
[ "$(calls)" = 8 ] && ok || bad "U14 $(calls) call(s), want 8 (Needs-Human makes none)"
for c in 'Secret' 'AUTH-BYPASS' 'auth bypass' 'secret, money' 'injection' ''; do
  grep -qE "^- \[BLOCK ${c}\] .* \| disprove-said: DISPROVED " "$OUTF" && ok || bad "U14 '[BLOCK $c]' was not kept with disprove-said: $(grep -F "[BLOCK $c]" "$OUTF")"
done
grep -q '^- \[NOTE\] disproved: (Wrong-Data) bin/a.sh:12:' "$OUTF" && ok || bad "U14 Wrong-Data is not a NOTE: $(grep -i wrong-data "$OUTF")"
grep -q '^- \[NOTE\] disproved: (core-flow-broken) bin/a.sh:13:' "$OUTF" && ok || bad "U14 'core-flow-broken ' is not a NOTE: $(grep core-flow "$OUTF")"
grep -qxF -- '- [BLOCK Needs-Human] bin/a.sh:9: fixture a live key is needed' "$OUTF" && ok || bad "U14 the Needs-Human line changed"
[ "$(nblock)" = 7 ] && [ "$(lr_verdict "$OUTF")" = BLOCK ] && ok || bad "U14 $(nblock) BLOCK line(s), verdict '$(lr_verdict "$OUTF")', want 7 and BLOCK"
[ "$(rec .kept_protected)" = 6 ] && [ "$(rec .disproved)" = 2 ] && ok || bad "U14 record kept $(rec .kept_protected) disproved $(rec .disproved), want 6 and 2"

# ── U15 (r2) path shape: a `-` or `..` path is no location ──
reset_u report-two.md enforce
printf '%s\n' '## Findings' '' '- [BLOCK wrong-data] -oops.sh:3: x' '- [BLOCK wrong-data] a/../b.sh:3: x' '' 'VERDICT: BLOCK' > "$OUTF"
cp "$OUTF" "$T/out.before"
[ "$(dp_extract "$OUTF" | cut -f2,5 | paste -sd, -)" = $'noloc\t-,noloc\t-' ] && ok || bad "U15 dp_extract: $(dp_extract "$OUTF" | cut -f2,5 | paste -sd, -)"
review
[ "$(calls)" = 0 ] && [ "$(outcomes)" = "unchecked:no-loc,unchecked:no-loc" ] && cmp -s "$OUTF" "$T/out.before" \
  && ok || bad "U15 $(calls) call(s), outcomes '$(outcomes)', want 0 and unchecked:no-loc x2, out unchanged"
for a in 'DISPROVED see -oops.sh:3' 'DISPROVED see ../a.sh:3' 'DISPROVED see bin/../-oops.sh:3'; do
  printf '%s\n' "$a" > "$A"
  [ "$(dp_parse_answer "$A" "$WT" "$HS" | cut -f1)" = CONFIRMED ] && ok || bad "U15 '$a' is not CONFIRMED"
done
git -C "$WT" cat-file -e "$HS:-oops.sh" && ok || bad "U15 the scratch head has no -oops.sh (the answer check would be vacuous)"
unset -f setting_get model_for log llm_gate_spend_today _jobs_req lr_verdict lr_verdict_real
unset HARNESS H
PATH="$T/sentinel:$PATH0"; export PATH

# ═══════════════════════ part R: bin/lead-review.sh tick ═══════════════════════
# The BH-6970 part R scratch repo: bin/greet.sh, the head at PR 77.
RO="$T/rorigin.git"; RW="$T/rwork"
git init -q --bare -b main "$RO"; git init -q -b main "$RW"
mkdir -p "$RW/bin" "$RW/tests"
printf '#!/bin/bash\necho "hi $1"\n' > "$RW/bin/greet.sh"; printf '#!/bin/bash\nexit 0\n' > "$RW/tests/base-test.sh"
git -C "$RW" add -A; git -C "$RW" commit -qm base; git -C "$RW" push -q "$RO" main
printf '#!/bin/bash\n# greet <name>: hello <name>; no name says hello world\necho "hello ${1}"\n' > "$RW/bin/greet.sh"
git -C "$RW" commit -qam "BH-9001: greet"; RS=$(git -C "$RW" rev-parse HEAD)
git -C "$RW" push -q "$RO" "$RS:refs/pull/77/head"
HB="$T/hb"; mkdir -p "$HB/bin" "$HB/prompts/lead-review.d" "$HB/catalog/lanes.d" "$HB/state" "$HB/env" "$T/brepos" "$T/bbin" "$T/rlog" "$T/rset" "$T/tmp"
cat > "$HB/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "\${AGENT_CALL_ROLE:-<unset>}" >> "$T/rlog/roles"
if [ "\${AGENT_CALL_ROLE:-}" = review-disprove ]; then cat "$T/rdp-answer" > "\$5"; else cat "$T/rlead-answer" > "\$5"; fi
exit 0
EOF
chmod +x "$HB/bin/agent-call.sh"
scratch_install_closure bin/lead-review.sh "$HB" >/dev/null || bad "R closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$HB" >/dev/null || bad "R closure of bin/jobs-client.sh"
[ -f "$HB/bin/lib/review-disprove.sh" ] && ok || bad "R the closure of bin/lead-review.sh lacks bin/lib/review-disprove.sh"
cp "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$HB/bin/"
cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$HB/catalog/lanes.d/"
cp "$SRC/catalog/review-always-block.tsv" "$SRC/catalog/review-nits.tsv" "$SRC/catalog/review-golive.tsv" "$HB/catalog/" 2>/dev/null
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$SRC/prompts/lead-review-builds-on.md" "$HB/prompts/"
cp "$PROMPT" "$HB/prompts/lead-review.d/" 2>/dev/null
echo box-demo > "$HB/state/box-name"
BLOG="$HB/logs/lead-review.log"
git clone -q "$RO" "$T/brepos/demo-os"; git clone -q "$RO" "$T/brepos/cromford"
# The jobs worker: settings rows from $T/rset/<key>, a zero spend, the routes,
# and every request logged.
cat > "$T/bbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""; body=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/rlog/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "POST /api/review-disprove") code=201; out='{"row":{"id":1},"existing":false}' ;;
  "GET /api/metrics/llm-spend"*) out='{"usd":0}' ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"; k="\${k%%\?*}"
    if [ -f "$T/rset/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/rset/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/model-routes/review-disprove"*) out='{"ladder":[{"position":0,"model":"fixture-disprove-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"fixture-lead-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/bbin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/rlog/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/reviews"*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$RS" '{state:"open",head:{sha:\$s,ref:"ticket/bh-9001",repo:{full_name:"example-org/demo-os"}},base:{ref:"main"},title:"BH-9001: greet",body:"BH-9001\n"}' ;;
esac
exit 0
EOF
chmod +x "$T/bbin/curl" "$T/bbin/gh"
# tick <tag> <project> — one bin/lead-review.sh tick on PR 77 at $RS, the repo
# owned by <project> in fleet.conf.
tick() {
  rm -f "$T/rlog/"*; scratch_rm "$HB/state/lead-reviews"; scratch_rm "$HB/state/lead-review"
  scratch_rm "$HB/state/model-routes"; rm -f "$HB/state/settings-cache.json"; mkdir -p "$HB/state/lead-reviews"; rm -f "$BLOG"
  printf '%s example-org/demo-os https://demo.test /api/board 1 box-demo\n' "$2" > "$HB/fleet.conf"
  jq -nc --arg s "$RS" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:77,head_sha:$s,
    scope_notes:"auto: builder APPROVE on x",prior_verdict_ref:"v",status:"requested"}],truncated:false}' > "$T/requests.json"
  ( cd "$T" && env PATH="$T/bbin:$PATH" HARNESS="$HB" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/brepos" FLEET_CONF="$HB/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$HB/bin/lead-review.sh" tick ) > "$T/rout.$1" 2>&1
  cp "$HB/state/lead-reviews/lr-77-${RS:0:12}.md" "$T/report.$1" 2>/dev/null || : > "$T/report.$1"
  cp "$BLOG" "$T/rlane.$1" 2>/dev/null || : > "$T/rlane.$1"
  RVER=$(sed -n 's#^POST /api/lead-reviews/lr-1/result \(.*\)$#\1#p' "$T/rlog/worker" 2>/dev/null | head -n 1 | jq -r '.verdict // ""' 2>/dev/null)
  RDPOST=0; [ -f "$T/rlog/worker" ] && RDPOST=$(grep -c '^POST /api/review-disprove ' "$T/rlog/worker")
  RDP=0; [ -f "$T/rlog/roles" ] && RDP=$(grep -cx review-disprove "$T/rlog/roles")
}
cp "$FX/answer-greet-disproved.txt" "$T/rdp-answer"
# ── R1 shadow, a model BLOCK with 2 findings ──
cp "$FX/lead-block.md" "$T/rlead-answer"; printf '1' > "$T/rset/review.disprove.demo-os.enabled"; printf 'shadow' > "$T/rset/review.disprove.mode"
tick r1 demo-os
[ "$(paste -sd, "$T/rlog/roles" 2>/dev/null)" = "lead.review,review-disprove,review-disprove" ] && ok \
  || bad "R1 agent roles '$(paste -sd, "$T/rlog/roles" 2>/dev/null)', want lead.review,review-disprove,review-disprove: $(tail -n 8 "$T/rlane.r1")"
[ "$RVER" = BLOCK ] && ok || bad "R1 shadow posted verdict '$RVER', want BLOCK: $(tail -n 5 "$T/rlane.r1")"
dl=$(grep -n -- '^- disprove (BH-9047): mode shadow; 2 finding(s): 0 confirmed, 2 disproved, 0 kept (protected), 0 unchecked; verdict BLOCK -> BLOCK (shadow: unchanged)$' "$T/report.r1" | cut -d: -f1)
pl=$(grep -n -- '^- pr body:' "$T/report.r1" | head -n 1 | cut -d: -f1)
[ -n "$dl" ] && [ -n "$pl" ] && [ "$dl" -lt "$pl" ] && ok || bad "R1 the report lacks the disprove line above - pr body: $(head -n 16 "$T/report.r1")"
[ "$(sed -n "$((dl + 1)),$((pl - 1))p" "$T/report.r1" 2>/dev/null | grep -c '^  - disprove DISPROVED ')" = 2 ] && ok || bad "R1 want 2 indented disprove lines above - pr body:"
grep -q '^- \[BLOCK wrong-data\] bin/greet.sh:3:' "$T/report.r1" && ok || bad "R1 shadow dropped the model's BLOCK line"
[ "$RDPOST" = 1 ] && ok || bad "R1 $RDPOST POST /api/review-disprove, want 1"
grep -q 'disprove: ran (mode shadow)' "$T/rlane.r1" && ok || bad "R1 no lane log line"
# ── R2 enforce, both DISPROVED ──
printf 'enforce' > "$T/rset/review.disprove.mode"; tick r2 demo-os
[ "$RVER" = MERGE-WITH-NOTES ] && ok || bad "R2 enforce posted '$RVER', want MERGE-WITH-NOTES: $(tail -n 8 "$T/rlane.r2")"
grep -qx -- '- verdict: MERGE-WITH-NOTES' "$T/report.r2" && ok || bad "R2 the report verdict: $(grep '^- verdict' "$T/report.r2")"
[ "$(grep -c '^- \[NOTE\] disproved: ' "$T/report.r2")" = 2 ] && ok || bad "R2 the report lacks 2 [NOTE] disproved: lines: $(grep -i disprov "$T/report.r2")"
grep -q '^- \[BLOCK' "$T/report.r2" && bad "R2 a BLOCK line is left" || ok
grep -q 'block-no-finding' "$T/rlane.r2" "$T/rlog/worker" && bad "R2 the report was refused as block-no-finding" || ok
# ── R3 a rules-pack BLOCK: no disprove call ──
printf '#!/bin/bash\necho "tests/x-ratchet.sh: 1 new hit"\nexit 1\n' > "$HB/bin/rules-pack.sh"; chmod +x "$HB/bin/rules-pack.sh"
printf '1' > "$T/rset/review.disprove.cromford.enabled"; tick r3 cromford
grep -qx -- '- reviewer model: rules-pack' "$T/report.r3" && ok || bad "R3 not a rules-pack BLOCK: $(head -n 8 "$T/report.r3"); $(tail -n 5 "$T/rlane.r3")"
[ "$RDP" = 0 ] && [ "$RDPOST" = 0 ] && ok || bad "R3 a rules-pack BLOCK made $RDP disprove call(s) and $RDPOST POST(s)"
grep -q -- '- disprove' "$T/report.r3" && bad "R3 a rules-pack report has a disprove line" || ok
rm -f "$HB/bin/rules-pack.sh"
# ── R4 a model MERGE; and no enabled row ──
cp "$FX/lead-merge.md" "$T/rlead-answer"; tick r4 demo-os
[ "$RVER" = MERGE ] && [ "$RDP" = 0 ] && [ "$RDPOST" = 0 ] && ok || bad "R4 a MERGE: verdict '$RVER', $RDP disprove call(s)"
grep -q -- '- disprove' "$T/report.r4" && bad "R4 a MERGE report has a disprove line" || ok
cp "$FX/lead-block.md" "$T/rlead-answer"; rm -f "$T/rset/review.disprove.demo-os.enabled"; tick r4n demo-os
[ "$RVER" = BLOCK ] && [ "$RDP" = 0 ] && [ "$RDPOST" = 0 ] && ok || bad "R4 no enabled row: verdict '$RVER', $RDP disprove call(s), $RDPOST POST(s)"
grep -q -- '- disprove' "$T/report.r4n" && bad "R4 no enabled row: the report has a disprove line" || ok
grep -q 'disprove: skipped:off' "$T/rlane.r4n" && ok || bad "R4 no enabled row: no skipped:off log line"

# ── R5 the budget test: 0 real vendor calls over parts U and R ──
[ -e "$T/vendor-calls" ] && bad "R5 a real vendor call ran: $(head -n 3 "$T/vendor-calls")" || ok

# ═══════════════════════ part S: the seed ═══════════════════════
[ -f "$SEED" ] && ok || bad "S1 the seed fragment $SEED does not exist"
grep -qiE "'(claude|gpt|gemini)-" "$SEED" 2>/dev/null && bad "S1 the seed carries a model literal" || ok
if [ -f "$SEED" ] && command -v python3 >/dev/null 2>&1 && jobs_schema_render; then
  python3 -I - "$SRC/worker/jobs/schema.sql" "$SEED" "$T/hub.sqlite" > "$T/s1.out" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[3])
db.executescript(open(sys.argv[1]).read())
db.commit()
for k, v in db.execute("SELECT key, value FROM settings WHERE key LIKE 'review.disprove.%' OR key = 'retention.review_disprove_runs.days' ORDER BY key"):
    print("set", k, v)
for role in ("review-disprove", "stage.disprove"):
    for p, m, rn in db.execute("SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role=? ORDER BY position", (role,)):
        print("rung", role, p, m, rn)
for role in ("lead.review", "stage.execute"):
    r = db.execute("SELECT model, runner FROM model_routes WHERE project IS NULL AND role=? AND position=0", (role,)).fetchone()
    print("src", role, (r[0] + " " + r[1]) if r else "-")
print("table", db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='review_disprove_runs' AND name LIKE 'idx_review_disprove_runs_%'").fetchone()[0])
db.execute("UPDATE settings SET value='enforce' WHERE key='review.disprove.mode'")
db.executescript(open(sys.argv[1]).read())
print("after", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-disprove'").fetchone()[0],
      db.execute("SELECT value FROM settings WHERE key='review.disprove.mode'").fetchone()[0])
db.execute("DELETE FROM model_routes WHERE role='review-disprove'")
db.execute("INSERT INTO model_route_changes (scope, project, role, position, actor, at) VALUES ('hub', NULL, 'review-disprove', 0, 'op', '2026-11-04T00:00:00Z')")
db.executescript(open(sys.argv[2]).read())
print("cut", db.execute("SELECT COUNT(*) FROM model_routes WHERE role='review-disprove'").fetchone()[0])
PY
  [ "$?" = 0 ] && ok || bad "S1 the schema did not apply: $(head -n 3 "$T/s1.out")"
  for kv in "review.disprove.cromford.enabled 1" "review.disprove.mode shadow" "review.disprove.max_findings 5" \
            "review.disprove.usd_cap_day 2" "review.disprove.call_budget_usd 0.50" "review.disprove.max_context_bytes 24000" \
            "review.disprove.min_left_s 120" "retention.review_disprove_runs.days 90" "review.disprove.list_limit 100" "review.disprove.list_max 500"; do
    grep -qx "set $kv" "$T/s1.out" && ok || bad "S1 not seeded: $kv: $(grep '^set' "$T/s1.out")"
  done
  grep -q '^set review.disprove.demo-os' "$T/s1.out" && bad "S1 a project other than cromford is seeded on" || ok
  LEADM=$(sed -n 's/^src lead.review //p' "$T/s1.out"); EXM=$(sed -n 's/^src stage.execute //p' "$T/s1.out")
  [ "$LEADM" != - ] && grep -qx "rung review-disprove 0 $LEADM" "$T/s1.out" && ok || bad "S1 review-disprove rung 0 is not lead.review rung 0 ($LEADM): $(grep rung "$T/s1.out")"
  [ "$(grep -c '^rung review-disprove ' "$T/s1.out")" = 1 ] && ok || bad "S1 want 1 review-disprove rung"
  grep -qx "rung stage.disprove 0 $EXM" "$T/s1.out" && ok || bad "S1 stage.disprove is not stage.execute rung 0 ($EXM)"
  grep -qx 'table 2' "$T/s1.out" && ok || bad "S1 review_disprove_runs lacks its 2 indexes: $(grep table "$T/s1.out")"
  grep -qx 'after 1 enforce' "$T/s1.out" && ok || bad "S1 a re-apply changed a row: $(grep after "$T/s1.out")"
  grep -qx 'cut 0' "$T/s1.out" && ok || bad "S1 an operator cut was put back: $(grep cut "$T/s1.out")"
else
  bad "S1 the composed schema could not be checked (no seed, no python3 or jobs_schema_render failed)"
fi

# The node suite of the route, when node is on PATH (it needs no package; the
# worker half: worker/jobs/src/routes/review-disprove.js and its retention rule
# worker/jobs/src/routes/retention.d/bh-9047-review-disprove.js).
if [ -f "$SRC/worker/jobs/src/routes/review-disprove.js" ] && [ -f "$SRC/worker/jobs/src/routes/retention.d/bh-9047-review-disprove.js" ]; then ok
else bad "W the worker route or its retention rule is missing"; fi
worker_catalogs "$SRC" || exit 1
if command -v node >/dev/null 2>&1; then
  ( cd "$SRC/worker/jobs" && node --test test/review-disprove.bh-9047.test.js ) > "$T/w.out" 2>&1 && ok || bad "W the node suite failed: $(tail -n 15 "$T/w.out")"
else
  echo "note: node missing; the node suite is not run here (CI runs it)"
fi

echo "review-disprove.bh-9047: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

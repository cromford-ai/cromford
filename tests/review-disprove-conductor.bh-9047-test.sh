#!/bin/bash
# tests/review-disprove-conductor.bh-9047-test.sh — BH-9047 (C1): the disprove
# pass on a CONDUCTOR re-review BLOCK (mc_rereview, bin/lib/mc/rebase.sh). The
# same lib as the lead lane (bin/lib/review-disprove.sh), with DP_LANE=conductor:
# APPROVE is the clearing word, verdict_parse the reader, lane/actor conductor/
# merge-conductor in the D1 row. Fixture model answers only
# (tests/fixtures/review-disprove-conductor.bh-9047/); bin/agent-call.sh is a
# stub and claude/codex/curl sentinels record any real vendor call (V1).
#
#   part L  the lane switch in "$SRC/bin/lib/review-disprove.sh":
#     L1  DP_LANE unset: MERGE-WITH-NOTES, record lane lead / actor lead-review.
#     L2  T-prot: GUARD_SILENCED and FRAUD: lines are protected; a near miss
#         (lower case, no colon) is not.
#     L3  _dp_verdict conductor: APPROVE / BLOCK / MERGE-WITH-NOTES (unknown).
#     L4  DP_DIR set: the files land there and <wt>.dp is not made.
#   part D  dpc_run / dpc_gate_on with stub mc_patch_wt, a stub agent-call.sh:
#     D1  enforce, 2 findings DISPROVED: 2 calls, role review-disprove, the
#         prompt sections, last line VERDICT: APPROVE, 2 NOTE lines, the report
#         above the verdict, <out>.dp removed, mc_git_auth_clear ran.
#     D2  a DISPROVED answer with no head path:line: CONFIRMED, BLOCK.
#     D3  the POST body: lane conductor, actor merge-conductor, review_id.
#     D4  agent-call rc 1 / empty / rc 75: BLOCK unchanged.
#     D5  secret, GUARD_SILENCED, FRAUD: DISPROVED and kept.
#     D6  no checkout / a failed fetch: skipped:no-checkout, 0 calls, the
#         auth cleared; the day cap; the conductor_left_s knob; the gate table;
#         off / not-block / no-finding make no checkout.
#     D7  a BLOCK outside the grammar (a heading, a table row) holds BLOCK in
#         enforce, the DISPROVED grammar line stays a BLOCK; a BLOCK word only
#         inside a ``` fence does not hold the verdict.
#     D8  a partial (--filter=blob:none) clone: the changed file's hunk and
#         file at head reach the model after the auth clear; a finding on a
#         path outside the diff stays CONFIRMED (near miss).
#   part M  the REAL mc_rereview (scratch $HARNESS, stub agent-call.sh, a stub
#           jobs worker as curl, local bare origin):
#     M1  shadow: the grammar sentence, 2 disprove calls, BLOCK rc 0, log line.
#     M2  shadow: <out> byte-equal to the answer; rrverdict BLOCK; one POST.
#     M3  enforce, both DISPROVED: APPROVE; rrverdict APPROVE; report above.
#     M4  enforce, one CONFIRMED: BLOCK; only the confirmed BLOCK line.
#     M5  no enabled row: no sentence (prompt = the gate-on prompt minus it),
#         0 disprove calls.
#     M6  an APPROVE: 0 calls; no grammar line: skipped:no-finding, 0 calls.
#     M7  MC_RR_REASON=noverdict: review_id rr~noverdict.
#     M8  enforce, a heading-shaped data-loss and a table-shaped money BLOCK
#         beside one DISPROVED grammar line: mc_rereview prints BLOCK, rrverdict BLOCK.
#   part S  the composed schema: review.disprove.conductor_left_s = 900 after
#           two applies; an operator value is kept.
#   V1  0 real vendor calls over the whole suite.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-disprove-conductor.bh-9047-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/review-disprove-conductor.bh-9047"
LIB="$SRC/bin/lib/review-disprove.sh"
PROMPT="$SRC/prompts/lead-review.d/disprove.md"
SEED="$SRC/worker/jobs/schema.d/202611072205-bh-9047-disprove-conductor.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_ROW_NOTE AGENT_CALL_ROLE AGENT_CALL_BUDGET_USD AGENT_CALL_NO_TOOLS \
  DP_LANE DP_DIR MC_RR_REASON MC_RR_SCRATCH_ROOT MC_RR_EVIDENCE BOX_NAME JOBS_BOX HUB_BOX_NAME

# The vendor sentinels (V1).
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
git -C "$WK" add -A; git -C "$WK" commit -qm base; git -C "$WK" push -q "$ORIG" main
sed -i -e 's/^line 4$/line 4 parses the flag/' -e 's/^line 12$/line 12 reads the name/' "$WK/bin/a.sh"
git -C "$WK" commit -qam "BH-9001: a"; HS=$(git -C "$WK" rev-parse HEAD); git -C "$WK" push -q "$ORIG" "HEAD:refs/heads/h"
# The checkout dpc_run fetches into: main only, so the fetch of $HS is real.
WT="$T/wt"; git clone -q "$ORIG" "$WT"

# ═══════════════════════ parts L and D: the lib, with stubs ═══════════════════════
UH="$T/uh"; mkdir -p "$UH/bin" "$UH/prompts/lead-review.d" "$T/log" "$T/set" "$T/ans"
cp "$PROMPT" "$UH/prompts/lead-review.d/" 2>/dev/null
cat > "$UH/bin/agent-call.sh" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/log/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/log/n"
echo "\$*" >> "$T/log/calls"
env | grep '^AGENT_CALL_' | sort > "$T/log/env.\$n"
cp "\${6#@}" "$T/log/prompt.\$n"
if [ -f "$T/ans/\$n" ]; then cat "$T/ans/\$n" > "\$5"; else cat "$T/ans/default" > "\$5" 2>/dev/null; fi
exit "\$(cat "$T/acrc.\$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$UH/bin/agent-call.sh"
export HARNESS="$UH"; H="$UH"
setting_get() { [ -f "$T/set/$1" ] || return 2; cat "$T/set/$1"; }
model_for() { [ "$1" = review-disprove ] && echo fixture-disprove-model; }
log() { echo "$*" >> "$T/log/lane"; }
llm_gate_spend_today() { [ -f "$T/spend" ] || return 1; cat "$T/spend"; }
_jobs_req() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$T/log/jobs"; JOBS_HTTP=201; return 0; }
lead_fp() { printf 'lead:%s#%s@%s~%s' "$1" "$2" "$3" "$4"; }
# lr_verdict as bin/lead-review.sh reads one (the C0 suite's stub), for L1.
lr_verdict() {
  local last; last=$(tr -d '\r' < "$1" | awk 'NF { l = $0 } END { print l }' | sed 's/[[:space:]]*$//')
  case "$last" in "VERDICT: MERGE-WITH-NOTES"|"VERDICT: BLOCK"|"VERDICT: MERGE") printf '%s' "${last#VERDICT: }" ;; *) printf unknown ;; esac
}
# The conductor's checkout and its auth: stubs that log.
mc_patch_wt() { echo "$*" >> "$T/log/patchwt"; [ -e "$T/patch-fail" ] && return 1; MC_PATCH_WT="$WT"; }
mc_git_auth_clear() { echo clear >> "$T/log/authclear"; }
mc_log() { echo "$*" >> "$T/log/mclog"; }
# shellcheck source=bin/lib/review-disprove.sh
. "$LIB" 2>/dev/null || bad "L0 bin/lib/review-disprove.sh does not source"
OUTF="$T/rr.out"
reset_d() { # reset_d <fixture> <mode|-> [enabled, default 1]
  rm -rf "$T/log" "$OUTF.dp" "$T/wt.dp"; mkdir -p "$T/log"
  rm -f "$T/acrc."* "$T/ans/"* "$T/set/"* "$T/patch-fail"
  printf '0' > "$T/spend"
  cp "$FX/answer-disproved.txt" "$T/ans/default"
  printf '%s' "${3-1}" > "$T/set/review.disprove.demo-os.enabled"
  [ "$2" = - ] || printf '%s' "$2" > "$T/set/review.disprove.mode"
  cp "$FX/$1" "$OUTF"; cp "$OUTF" "$T/out.before"
}
run_d() { DPR=$(dpc_run example-org/demo-os 51 demo-os "$HS" "$OUTF" "${1:-rr}" 2>/dev/null); }
calls() { [ -f "$T/log/calls" ] && wc -l < "$T/log/calls" | tr -d ' ' || echo 0; }
nblock() { grep -c '^- \[BLOCK' "$OUTF"; }
post() { sed -n 's#^POST /api/review-disprove ##p' "$T/log/jobs" 2>/dev/null | tail -n 1 | jq -r "$1" 2>/dev/null; }
nposts() { [ -f "$T/log/jobs" ] || { echo 0; return; }; grep -c '^POST /api/review-disprove ' "$T/log/jobs"; }
lastline() { awk 'NF { l = $0 } END { print l }' "$OUTF"; }

# ── L1 the lead lane is the default ──
[ "$(_dp_clear_word)" = MERGE-WITH-NOTES ] && ok || bad "L1 DP_LANE unset: clear word '$(_dp_clear_word)'"
[ "$(DP_LANE=conductor _dp_clear_word)" = APPROVE ] && ok || bad "L1 DP_LANE=conductor: clear word '$(DP_LANE=conductor _dp_clear_word)'"
reset_d rr-block.md enforce
DPR=$(dp_review example-org/demo-os 51 "$HS" demo-os "$WT" main "$OUTF" 600 lr-1)
[ "$DPR" = "ran enforce 1" ] && ok || bad "L1 lead dp_review printed '$DPR'"
[ "$(lastline)" = "VERDICT: MERGE-WITH-NOTES" ] && ok || bad "L1 lead clearing line '$(lastline)'"
[ "$(post .lane)" = lead ] && [ "$(post .actor)" = lead-review ] && ok || bad "L1 lead record lane '$(post .lane)' actor '$(post .actor)'"
[ -d "$T/wt.dp" ] && ok || bad "L1 the lead lane does not write <wt>.dp"

# ── L2 T-prot ──
printf '%s\n' '- [BLOCK weakened-test] a.sh:4 GUARD_SILENCED the guard rule was edited' \
  '- [BLOCK scalable-tests] a.sh:4 FRAUD: weakened-tests' \
  '- [BLOCK wrong-data] a.sh:4 guard silenced in prose' \
  '- [BLOCK wrong-data] a.sh:4 fraud weakened-tests in prose' \
  '```' '- [BLOCK wrong-data] a.sh:9 in a fence' '```' > "$T/prot.md"
dp_extract "$T/prot.md" | cut -f1-3 > "$T/prot.got"
printf '1\tcheck\t1\n2\tcheck\t1\n3\tcheck\t0\n4\tcheck\t0\n' > "$T/prot.want"
cmp -s "$T/prot.got" "$T/prot.want" && ok || bad "L2 T-prot rows: $(diff "$T/prot.want" "$T/prot.got")"

# ── L3 the conductor's verdict reader ──
for c in "APPROVE:APPROVE" "BLOCK:BLOCK" "MERGE-WITH-NOTES:unknown"; do
  printf 'text\n\nVERDICT: %s\n' "${c%%:*}" > "$T/v.md"
  [ "$(DP_LANE=conductor _dp_verdict "$T/v.md" x)" = "${c#*:}" ] && ok || bad "L3 conductor reads VERDICT: ${c%%:*} as '$(DP_LANE=conductor _dp_verdict "$T/v.md" x)', want ${c#*:}"
done

# ── L4 DP_DIR ──
reset_d rr-block.md shadow
DPR=$(DP_DIR="$T/l4.dp" dp_review example-org/demo-os 51 "$HS" demo-os "$WT" main "$OUTF" 600 lr-1)
[ -s "$T/l4.dp/record.json" ] && [ -s "$T/l4.dp/report" ] && ok || bad "L4 DP_DIR has no record/report"
[ -e "$T/wt.dp" ] && bad "L4 DP_DIR set and <wt>.dp was made" || ok

# ── D1 conductor enforce, 2 findings DISPROVED ──
reset_d rr-block.md enforce; run_d
[ "$DPR" = "ran enforce 1" ] && ok || bad "D1 dpc_run printed '$DPR': $(cat "$T/log/lane" "$T/log/mclog" 2>/dev/null)"
[ "$(calls)" = 2 ] && ok || bad "D1 $(calls) call(s), want 2"
for k in 1 2; do
  grep -qx 'AGENT_CALL_ROLE=review-disprove' "$T/log/env.$k" 2>/dev/null && ok || bad "D1 call $k role: $(cat "$T/log/env.$k" 2>/dev/null)"
  for s in '## Finding' '## Hunk' '## File at head'; do
    grep -q "^$s" "$T/log/prompt.$k" 2>/dev/null && ok || bad "D1 prompt $k lacks '$s'"
  done
done
grep -qxF -- '+line 12 reads the name' "$T/log/prompt.1" && ok || bad "D1 the prompt lacks the hunk of the fetched head"
case "$(head -n 1 "$T/log/calls" 2>/dev/null)" in "disprove demo-os fixture-disprove-model "*) ok ;; *) bad "D1 agent-call args: $(head -n 1 "$T/log/calls" 2>/dev/null)" ;; esac
[ "$(lastline)" = "VERDICT: APPROVE" ] && ok || bad "D1 last line '$(lastline)', want VERDICT: APPROVE"
[ "$(verdict_parse "$OUTF")" = APPROVE ] && ok || bad "D1 verdict_parse reads '$(verdict_parse "$OUTF")'"
[ "$(grep -c '^- \[NOTE\] disproved:' "$OUTF")" = 2 ] && [ "$(nblock)" = 0 ] && ok || bad "D1 want 2 NOTE disproved, 0 BLOCK: $(cat "$OUTF")"
dl=$(grep -n '^- disprove (BH-9047): mode enforce; 2 finding(s): 0 confirmed, 2 disproved, 0 kept (protected), 0 unchecked; verdict BLOCK -> APPROVE$' "$OUTF" | cut -d: -f1)
vl=$(grep -n '^VERDICT: APPROVE$' "$OUTF" | cut -d: -f1)
[ -n "$dl" ] && [ -n "$vl" ] && [ "$dl" -lt "$vl" ] && ok || bad "D1 the report header is not above the verdict: $(cat "$OUTF")"
[ "$(grep -c '^  - disprove DISPROVED ' "$OUTF")" = 2 ] && ok || bad "D1 want 2 indented report lines"
[ -e "$OUTF.dp" ] && bad "D1 <out>.dp is left" || ok
[ "$(cat "$T/log/patchwt" 2>/dev/null)" = "example-org/demo-os demo-os" ] && ok || bad "D1 mc_patch_wt args: $(cat "$T/log/patchwt" 2>/dev/null)"
[ -s "$T/log/authclear" ] && ok || bad "D1 mc_git_auth_clear did not run"

# ── D2 a DISPROVED answer with no head path:line ──
reset_d rr-block.md enforce; printf 'It is fine.\n\nDISPROVED the code is fine\n' > "$T/ans/default"; run_d
[ "$(post '[.detail[].outcome] | join(",")')" = "CONFIRMED,CONFIRMED" ] && ok || bad "D2 outcomes '$(post '[.detail[].outcome] | join(",")')'"
cmp -s "$OUTF" "$T/out.before" && [ "$(verdict_parse "$OUTF")" = BLOCK ] && ok || bad "D2 the out changed or is not BLOCK"

# ── D3 the POST body ──
reset_d rr-block.md shadow; run_d
[ "$(nposts)" = 1 ] && ok || bad "D3 $(nposts) POST(s), want 1"
[ "$(post .lane)" = conductor ] && [ "$(post .actor)" = merge-conductor ] && [ "$(post .review_id)" = rr ] && ok \
  || bad "D3 lane '$(post .lane)' actor '$(post .actor)' review_id '$(post .review_id)'"
[ "$(post .verdict_before)" = BLOCK ] && [ "$(post .verdict_after)" = BLOCK ] && [ "$(post .disproved)" = 2 ] && [ "$(post .mode)" = shadow ] && ok \
  || bad "D3 before '$(post .verdict_before)' after '$(post .verdict_after)' disproved '$(post .disproved)' mode '$(post .mode)'"
[ "$DPR" = "ran shadow 0" ] && cmp -s "$OUTF" "$T/out.before" && ok || bad "D3 shadow: '$DPR' or the out changed"
reset_d rr-block.md shadow; run_d "rr~noverdict"
[ "$(post .review_id)" = "rr~noverdict" ] && ok || bad "D3 review_id '$(post .review_id)', want rr~noverdict"

# ── D4 the call fails ──
reset_d rr-block.md enforce; echo 1 > "$T/acrc.1"; : > "$T/ans/2"; run_d
[ "$(post '[.detail[].outcome] | join(",")')" = "failed,failed" ] && ok || bad "D4 rc 1 / empty: '$(post '[.detail[].outcome] | join(",")')'"
cmp -s "$OUTF" "$T/out.before" && [ "$(verdict_parse "$OUTF")" = BLOCK ] && ok || bad "D4 rc 1 / empty changed the out"
reset_d rr-block.md enforce; echo 75 > "$T/acrc.1"; echo 75 > "$T/acrc.2"; run_d
[ "$(post '[.detail[].outcome] | join(",")')" = "unchecked:refused,unchecked:refused" ] && ok || bad "D4 rc 75: '$(post '[.detail[].outcome] | join(",")')'"
cmp -s "$OUTF" "$T/out.before" && ok || bad "D4 rc 75 changed the out"

# ── D5 protected lines ──
reset_d rr-guard.md enforce; run_d
[ "$(verdict_parse "$OUTF")" = BLOCK ] && grep -q '^- \[BLOCK weakened-test\] bin/a.sh:4: GUARD_SILENCED .*| disprove-said: DISPROVED .*(kept: a GUARD_SILENCED or FRAUD: finding is never auto-dropped)$' "$OUTF" \
  && ok || bad "D5 GUARD_SILENCED: $(cat "$OUTF")"
reset_d rr-fraud.md enforce; run_d
[ "$(verdict_parse "$OUTF")" = BLOCK ] && grep -q '^- \[BLOCK scalable-tests\] bin/a.sh:4: FRAUD: .*| disprove-said: DISPROVED ' "$OUTF" \
  && ok || bad "D5 FRAUD: $(cat "$OUTF")"
reset_d rr-block.md enforce; sed -i 's/\[BLOCK wrong-data\]/[BLOCK secret]/; /core-flow-broken/d' "$OUTF"; run_d
[ "$(verdict_parse "$OUTF")" = BLOCK ] && grep -q '^- \[BLOCK secret\] .*(kept: secret is never auto-dropped)$' "$OUTF" && ok || bad "D5 secret: $(cat "$OUTF")"

# ── D6 checkout, fetch, cap, knob, gate ──
reset_d rr-block.md enforce; : > "$T/patch-fail"; run_d
[ "$DPR" = "skipped:no-checkout enforce 0" ] && [ "$(calls)" = 0 ] && [ -s "$T/log/authclear" ] && ok \
  || bad "D6 no checkout: '$DPR', $(calls) call(s), authclear '$(cat "$T/log/authclear" 2>/dev/null)'"
cmp -s "$OUTF" "$T/out.before" && [ "$(nposts)" = 0 ] && ok || bad "D6 no checkout changed the out or posted"
reset_d rr-block.md enforce; DPR=$(dpc_run example-org/demo-os 51 demo-os 0123456789abcdef0123456789abcdef01234567 "$OUTF" rr 2>/dev/null)
[ "$DPR" = "skipped:no-checkout enforce 0" ] && [ "$(calls)" = 0 ] && [ -s "$T/log/authclear" ] && ok || bad "D6 failed fetch: '$DPR', $(calls) call(s)"
reset_d rr-block.md enforce; printf '2' > "$T/spend"; run_d
[ "$(post '[.detail[].outcome] | join(",")')" = "unchecked:cap,unchecked:cap" ] && [ "$(calls)" = 0 ] && cmp -s "$OUTF" "$T/out.before" && ok \
  || bad "D6 the day cap: '$(post '[.detail[].outcome] | join(",")')', $(calls) call(s)"
reset_d rr-block.md enforce; printf '61' > "$T/set/review.disprove.conductor_left_s"; run_d
[ "$(post '[.detail[].outcome] | join(",")')" = "unchecked:time,unchecked:time" ] && [ "$(calls)" = 0 ] && ok \
  || bad "D6 conductor_left_s 61 < min_left_s 120: '$(post '[.detail[].outcome] | join(",")')', $(calls) call(s)"
reset_d rr-block.md enforce; printf '30' > "$T/set/review.disprove.conductor_left_s"; run_d
[ "$(calls)" = 2 ] && ok || bad "D6 conductor_left_s 30 (out of range) is not the 900 fallback: $(calls) call(s)"
for g in "1:shadow:0" "1 :shadow:0" "01:shadow:1" "true:shadow:1" "1:Enforce :0"; do
  reset_d rr-block.md "$(echo "$g" | cut -d: -f2)" "${g%%:*}"
  dpc_gate_on demo-os; rc=$?
  [ "$rc" = "${g##*:}" ] && ok || bad "D6 T-gate enabled '${g%%:*}': dpc_gate_on rc $rc, want ${g##*:}"
done
reset_d rr-block.md 'Enforce '; [ "$(dp_gate demo-os)" = enforce ] && ok || bad "D6 T-gate mode 'Enforce ' is '$(dp_gate demo-os)'"
reset_d rr-block.md shadow 0; run_d
[ "$DPR" = "skipped:off off 0" ] && [ ! -e "$T/log/patchwt" ] && [ "$(calls)" = 0 ] && ok || bad "D6 off: '$DPR'"
reset_d rr-approve.md shadow; run_d
[ "$DPR" = "skipped:not-block shadow 0" ] && [ ! -e "$T/log/patchwt" ] && ok || bad "D6 not-block: '$DPR'"
reset_d rr-nogrammar.md enforce; run_d
[ "$DPR" = "skipped:no-finding enforce 0" ] && [ ! -e "$T/log/patchwt" ] && [ "$(calls)" = 0 ] && cmp -s "$OUTF" "$T/out.before" && ok || bad "D6 no-finding: '$DPR'"
# ── D7 a BLOCK outside the grammar holds the verdict (refute review) ──
for fx in rr-stray-heading.md rr-stray-table.md; do
  reset_d "$fx" enforce; run_d
  [ "$(calls)" = 1 ] && ok || bad "D7 $fx: $(calls) call(s), want 1: $DPR $(cat "$T/log/lane" "$T/log/mclog" 2>/dev/null)"
  [ "$(post '[.detail[].outcome] | join(",")')" = DISPROVED ] && ok || bad "D7 $fx outcomes '$(post '[.detail[].outcome] | join(",")')'"
  [ "$(verdict_parse "$OUTF")" = BLOCK ] && [ "$(lastline)" = "VERDICT: BLOCK" ] && ok || bad "D7 $fx: verdict '$(verdict_parse "$OUTF")', want BLOCK: $(cat "$OUTF")"
  grep -q '^- \[BLOCK wrong-data\] bin/a.sh:12: .*| disprove-said: DISPROVED' "$OUTF" && [ "$(grep -c '^- \[NOTE\] disproved:' "$OUTF")" = 0 ] && ok \
    || bad "D7 $fx: the DISPROVED grammar line is not kept a BLOCK: $(cat "$OUTF")"
  grep -qE 'data-loss|money' "$OUTF" && ok || bad "D7 $fx: the stray finding is gone"
done
DP_LANE=conductor _dp_stray_block "$FX/rr-stray-heading.md" && ok || bad "D7 _dp_stray_block misses a heading BLOCK"
DP_LANE=conductor _dp_stray_block "$FX/rr-stray-table.md" && ok || bad "D7 _dp_stray_block misses a table BLOCK"
reset_d rr-stray-fenced.md enforce; run_d
[ "$(verdict_parse "$OUTF")" = APPROVE ] && [ "$(grep -c '^- \[NOTE\] disproved:' "$OUTF")" = 1 ] && ok || bad "D7 a fenced BLOCK word held the verdict: $(cat "$OUTF")"
# The lead lane keeps its own check (its template and lr_block_no_finding).
reset_d rr-stray-table.md enforce
DPR=$(dp_review example-org/demo-os 51 "$HS" demo-os "$WT" main "$OUTF" 600 lr-1)
[ "$(lastline)" = "VERDICT: MERGE-WITH-NOTES" ] && ok || bad "D7 the lead lane changed: '$(lastline)'"

# ── D8 a partial (--filter=blob:none) conductor clone: the hunk reaches the
# model after mc_git_auth_clear (r8, T2). The auth clear stub points origin at
# a dead URL, as the real clear leaves a remote with no credential. ──
PORIG="$T/porigin.git"; PWK="$T/pwork"; PC="$T/pclone"
git init -q --bare -b main "$PORIG"; git -C "$PORIG" config uploadpack.allowFilter true
git -C "$PORIG" config uploadpack.allowAnySHA1InWant true
git init -q -b main "$PWK"; mkdir -p "$PWK/bin"
for i in $(seq 1 50); do echo "line $i"; done > "$PWK/bin/a.sh"
for i in $(seq 1 20); do echo "other $i"; done > "$PWK/bin/b.sh"
git -C "$PWK" add -A; git -C "$PWK" commit -qm base; git -C "$PWK" push -q "$PORIG" main
sed -i 's/^line 12$/line 12 reads the name/' "$PWK/bin/a.sh"
git -C "$PWK" commit -qam "BH-9001: a"; PHS=$(git -C "$PWK" rev-parse HEAD); git -C "$PWK" push -q "$PORIG" "HEAD:refs/heads/h"
git clone -q --no-checkout --filter=blob:none "file://$PORIG" "$PC" 2>/dev/null
[ "$(git -C "$PC" config remote.origin.promisor)" = true ] && ok || bad "D8 the scratch clone is not a partial clone"
[ "$(git -C "$PC" rev-list --objects --missing=print origin/main 2>/dev/null | grep -c '^?')" = 2 ] && ok || bad "D8 the partial clone does not miss the 2 main blobs"
git -C "$PC" remote set-url origin "file://$PORIG"
mc_patch_wt() { echo "$*" >> "$T/log/patchwt"; MC_PATCH_WT="$PC"; }
mc_git_auth_clear() { echo clear >> "$T/log/authclear"; git -C "$PC" remote set-url origin file:///nonexistent/bh-9047-d8; }
run_p() { DPR=$(dpc_run example-org/demo-os 51 demo-os "$PHS" "$OUTF" rr 2>/dev/null); }
reset_d rr-block.md enforce
printf '%s\n' 'The head changes bin/a.sh at line 12.' '' \
  '- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty' '' 'VERDICT: BLOCK' > "$OUTF"
cp "$OUTF" "$T/out.before"; run_p
[ "$(calls)" = 1 ] && ok || bad "D8 changed path: $(calls) call(s), want 1: '$DPR'"
grep -qxF -- '+line 12 reads the name' "$T/log/prompt.1" 2>/dev/null && ok || bad "D8 the hunk of the changed file did not reach the model: $(sed -n '/^## Hunk/,/^## File/p' "$T/log/prompt.1" 2>/dev/null | head -n 8)"
grep -qF '(the diff could not be read)' "$T/log/prompt.1" 2>/dev/null && bad "D8 the prompt says the diff could not be read" || ok
grep -qF '(bin/a.sh is not in the PR head)' "$T/log/prompt.1" 2>/dev/null && bad "D8 the prompt has no file at head" || ok
[ "$(post '[.detail[].outcome] | join(",")')" = DISPROVED ] && [ "$(verdict_parse "$OUTF")" = APPROVE ] && ok \
  || bad "D8 changed path: outcomes '$(post '[.detail[].outcome] | join(",")')', verdict '$(verdict_parse "$OUTF")'"
[ "$(git -C "$PC" remote get-url origin)" = file:///nonexistent/bh-9047-d8 ] && ok || bad "D8 the auth clear did not run"
# Near miss: a finding on a path outside the diff. Its blob was never fetched,
# so the DISPROVED answer has no head path:line and the BLOCK stands.
git -C "$PC" remote set-url origin "file://$PORIG"
reset_d rr-block.md enforce
printf '%s\n' 'The head changes bin/a.sh at line 12.' '' \
  '- [BLOCK wrong-data] bin/b.sh:3: other 3 drops the name' '' 'VERDICT: BLOCK' > "$OUTF"
cp "$OUTF" "$T/out.before"; printf 'It is fine.\n\nDISPROVED the guard at bin/b.sh:3 returns first\n' > "$T/ans/default"; run_p
[ "$(post '[.detail[].outcome] | join(",")')" = CONFIRMED ] && ok || bad "D8 outside the diff: outcomes '$(post '[.detail[].outcome] | join(",")')', want CONFIRMED"
cmp -s "$OUTF" "$T/out.before" && [ "$(verdict_parse "$OUTF")" = BLOCK ] && ok || bad "D8 outside the diff: the out changed: $(cat "$OUTF")"

unset -f setting_get model_for log llm_gate_spend_today _jobs_req lead_fp lr_verdict mc_patch_wt mc_git_auth_clear mc_log
unset HARNESS H

# ═══════════════════════ part M: the real mc_rereview ═══════════════════════
PATH="$T/sentinel:$PATH0"; export PATH
MH="$T/mh"; mkdir -p "$MH/bin/lib/mc" "$MH/logs" "$MH/state" "$MH/flags" "$MH/locks" "$MH/prompts/lead-review.d" "$T/mbin" "$T/mlog" "$T/mset" "$T/repos" "$T/tmpdir"
for L in bin/lib/merge-conductor-lib.sh bin/alert-line.sh bin/jobs-client.sh; do
  ( cd "$SRC" && scratch_install_closure "$L" "$MH" ) >/dev/null || bad "M closure of $L"
done
[ -f "$MH/bin/lib/review-disprove.sh" ] && ok || bad "M the closure of merge-conductor-lib.sh lacks bin/lib/review-disprove.sh"
cp "$PROMPT" "$MH/prompts/lead-review.d/"
. "$SRC/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$MH" demo-os
cp "$SRC/tests/lib/rest-emit.sh" "$T/mbin/restpr"; chmod +x "$T/mbin/restpr"
git clone -q "$ORIG" "$T/repos/demo-os"
# agent-call: the review answers $T/m-review; a review-disprove call answers
# $T/m-dp.<n> (else $T/m-dp).
cat > "$MH/bin/agent-call.sh" <<EOF
#!/bin/bash
if [ "\${AGENT_CALL_ROLE:-}" = review-disprove ]; then
  n=\$(( \$(cat "$T/mlog/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/mlog/n"
  echo "\$*" >> "$T/mlog/dpcalls"
  if [ -f "$T/m-dp.\$n" ]; then cat "$T/m-dp.\$n" > "\$5"; else cat "$T/m-dp" > "\$5"; fi
  exit 0
fi
cp "\${6#@}" "$T/mlog/review-prompt"
cat "$T/m-review" > "\$5"; printf 'claude\n' > "\$5.runner"; printf 'fixture-review-model\n' > "\$5.model"
exit 0
EOF
chmod +x "$MH/bin/agent-call.sh"
cat > "$T/mbin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/bin/a.sh
+++ b/bin/a.sh
+line 12 reads the name
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/51"*) restpr OPEN "$HEADSHA" ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
# The jobs worker: settings rows from $T/mset/<key>, a zero spend, the routes,
# every request logged to $T/mlog/worker.
cat > "$T/mbin/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""; body=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/mlog/worker"
code=200; out='{}'
case "\$m \$p" in
  "POST /api/review-disprove") code=201; out='{"row":{"id":1},"existing":false}' ;;
  "GET /api/metrics/llm-spend"*) out='{"usd":0}' ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"; k="\${k%%\?*}"
    if [ -f "$T/mset/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/mset/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"fixture-disprove-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
chmod +x "$T/mbin/gh" "$T/mbin/curl"
export PATH="$T/mbin:$PATH" HARNESS="$MH" MC_H="$MH" MC_RR_LIVE_CI=0 TMPDIR="$T/tmpdir" MC_REPOS="$T/repos" \
  HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_SETTINGS_CACHE_S=0 LANE_GATE_DISABLE=1 GH_ETAG=0
export HEADSHA="$HS"
# shellcheck source=/dev/null
. "$MH/bin/lib/merge-conductor-lib.sh"; mc_init
# The remote is the local bare origin; no token.
mc_git_auth() { MC_REMOTE="$ORIG"; return 0; }
URL=https://github.com/example-org/demo-os/pull/51
MOUT="$T/m.out"
mrun() { # mrun <review fixture> <mode|-> [enabled, default 1]
  rm -rf "$T/mlog" "$MOUT"*; mkdir -p "$T/mlog"; rm -f "$T/mset/"* "$T/m-dp."*
  cp "$FX/$1" "$T/m-review"; cp "$FX/answer-disproved.txt" "$T/m-dp"
  [ -n "${MDP1:-}" ] && cp "$MDP1" "$T/m-dp.1"
  printf '%s' "${3-1}" > "$T/mset/review.disprove.demo-os.enabled"
  [ "$2" = - ] || printf '%s' "$2" > "$T/mset/review.disprove.mode"
  : > "$MC_LOG"
  MV=$(mc_rereview example-org/demo-os 51 demo-os "$URL" - "$HS" "" "$MOUT"); MRC=$?
}
mdp() { [ -f "$T/mlog/dpcalls" ] && wc -l < "$T/mlog/dpcalls" | tr -d ' ' || echo 0; }
mposts() { [ -f "$T/mlog/worker" ] || { echo 0; return; }; grep -c '^POST /api/review-disprove ' "$T/mlog/worker"; }
mpost() { sed -n 's#^POST /api/review-disprove ##p' "$T/mlog/worker" 2>/dev/null | tail -n 1 | jq -r "$1" 2>/dev/null; }
rrv() { sed -n 's#^PUT /api/pr-attempts ##p' "$T/mlog/worker" 2>/dev/null | jq -r 'select(.kind == "rrverdict") | .sha' 2>/dev/null | awk '{ print $2 }' | tail -n 1; }
SENT='FINDING LINES: write each blocking finding as ONE line at column 0'

# ── M1, M2 shadow ──
mrun rr-block.md shadow
[ "$MRC" = 0 ] && [ "$MV" = BLOCK ] && ok || bad "M1 rc $MRC verdict '$MV', want 0 BLOCK: $(tail -n 5 "$MC_LOG" 2>/dev/null)"
grep -qF "$SENT" "$T/mlog/review-prompt" 2>/dev/null && ok || bad "M1 the review prompt lacks the grammar sentence"
cp "$T/mlog/review-prompt" "$T/prompt.on" 2>/dev/null
[ "$(mdp)" = 2 ] && ok || bad "M1 $(mdp) disprove call(s), want 2: $(tail -n 5 "$MC_LOG" 2>/dev/null)"
grep -q 'example-org/demo-os#51 disprove (conductor): ran (mode shadow)' "$MC_LOG" && ok || bad "M1 no log line: $(grep -i disprove "$MC_LOG")"
cmp -s "$MOUT" "$FX/rr-block.md" && ok || bad "M2 shadow changed the out: $(diff "$FX/rr-block.md" "$MOUT")"
[ "$(rrv)" = BLOCK ] && ok || bad "M2 rrverdict '$(rrv)', want BLOCK: $(grep pr-attempts "$T/mlog/worker")"
[ "$(mposts)" = 1 ] && [ "$(mpost .lane)" = conductor ] && [ "$(mpost .review_id)" = rr ] && ok || bad "M2 $(mposts) POST(s), lane '$(mpost .lane)' rid '$(mpost .review_id)'"
[ -e "$MOUT.dp" ] && bad "M2 <out>.dp is left" || ok
ls "$TMPDIR"/mc-askpass-* >/dev/null 2>&1 && bad "M2 an askpass helper is left" || ok

# ── M3 enforce, both DISPROVED ──
mrun rr-block.md enforce
[ "$MRC" = 0 ] && [ "$MV" = APPROVE ] && ok || bad "M3 rc $MRC verdict '$MV', want APPROVE: $(tail -n 5 "$MC_LOG")"
[ "$(rrv)" = APPROVE ] && ok || bad "M3 rrverdict '$(rrv)', want APPROVE"
[ "$(awk 'NF { l = $0 } END { print l }' "$MOUT")" = "VERDICT: APPROVE" ] && ok || bad "M3 last line of the out: $(tail -n 2 "$MOUT")"
dl=$(grep -n '^- disprove (BH-9047): mode enforce; 2 finding' "$MOUT" | cut -d: -f1); vl=$(grep -n '^VERDICT: APPROVE$' "$MOUT" | cut -d: -f1)
[ -n "$dl" ] && [ -n "$vl" ] && [ "$dl" -lt "$vl" ] && [ "$(grep -c '^- \[NOTE\] disproved:' "$MOUT")" = 2 ] && ok || bad "M3 the report and NOTE lines: $(cat "$MOUT")"

# ── M4 enforce, one CONFIRMED ──
MDP1="$FX/answer-confirmed.txt" mrun rr-block.md enforce
[ "$MRC" = 0 ] && [ "$MV" = BLOCK ] && ok || bad "M4 rc $MRC verdict '$MV', want BLOCK"
[ "$(grep -c '^- \[BLOCK' "$MOUT")" = 1 ] && grep -q '^- \[BLOCK wrong-data\] bin/a.sh:12:' "$MOUT" && ok || bad "M4 want only the confirmed BLOCK: $(grep BLOCK "$MOUT")"
[ "$(awk 'NF { l = $0 } END { print l }' "$MOUT")" = "VERDICT: BLOCK" ] && ok || bad "M4 last line: $(tail -n 1 "$MOUT")"

# ── M5 no enabled row ──
mrun rr-block.md shadow 0
[ "$MV" = BLOCK ] && [ "$(mdp)" = 0 ] && [ "$(mposts)" = 0 ] && ok || bad "M5 verdict '$MV', $(mdp) call(s), $(mposts) POST(s)"
grep -qF "$SENT" "$T/mlog/review-prompt" && bad "M5 the gate is off and the prompt carries the sentence" || ok
grep -q 'disprove (conductor)' "$MC_LOG" && bad "M5 the gate is off and the pass logged" || ok
python3 -I - "$T/prompt.on" "$T/mlog/review-prompt" <<'PY' && ok || bad "M5 the gate-off prompt is not the gate-on prompt minus the sentence"
import sys, re
on = open(sys.argv[1]).read(); off = open(sys.argv[2]).read()
on2 = re.sub(r" FINDING LINES: [^\n]*?`- \[NOTE\] <text>`\.", "", on, count=1)
sys.exit(0 if on2 == off and on2 != on else 1)
PY

# ── M6 APPROVE, no grammar ──
mrun rr-approve.md shadow
[ "$MV" = APPROVE ] && [ "$(mdp)" = 0 ] && [ "$(mposts)" = 0 ] && ok || bad "M6 APPROVE: verdict '$MV', $(mdp) call(s)"
grep -q 'disprove (conductor)' "$MC_LOG" && bad "M6 an APPROVE ran the pass" || ok
mrun rr-nogrammar.md enforce
[ "$MV" = BLOCK ] && [ "$(mdp)" = 0 ] && grep -q 'disprove (conductor): skipped:no-finding (mode enforce)' "$MC_LOG" && ok || bad "M6 no grammar: verdict '$MV', $(mdp) call(s): $(grep disprove "$MC_LOG")"

# ── M7 the reason key ──
MC_RR_REASON=noverdict mrun rr-block.md shadow
[ "$(mpost .review_id)" = "rr~noverdict" ] && ok || bad "M7 review_id '$(mpost .review_id)', want rr~noverdict"
unset MC_RR_REASON

# ── M8 a stray protected BLOCK beside a DISPROVED grammar line (refute review) ──
for fx in rr-stray-heading.md rr-stray-table.md; do
  mrun "$fx" enforce
  [ "$MRC" = 0 ] && [ "$MV" = BLOCK ] && ok || bad "M8 $fx: rc $MRC verdict '$MV', want BLOCK: $(tail -n 5 "$MC_LOG")"
  [ "$(rrv)" = BLOCK ] && ok || bad "M8 $fx: rrverdict '$(rrv)', want BLOCK"
  [ "$(mdp)" = 1 ] && ok || bad "M8 $fx: $(mdp) disprove call(s), want 1"
done

# ═══════════════════════ part S: the knob row ═══════════════════════
[ -f "$SEED" ] && ok || bad "S1 the seed fragment $SEED does not exist"
if [ -f "$SEED" ] && command -v python3 >/dev/null 2>&1 && jobs_schema_render; then
  python3 -I - "$SRC/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/s1.out" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
sql = open(sys.argv[1]).read()
db.executescript(sql); db.commit()
print("first", db.execute("SELECT value FROM settings WHERE key='review.disprove.conductor_left_s'").fetchone()[0])
db.executescript(sql)
print("twice", db.execute("SELECT COUNT(*), MAX(value) FROM settings WHERE key='review.disprove.conductor_left_s'").fetchone())
db.execute("UPDATE settings SET value='600' WHERE key='review.disprove.conductor_left_s'")
db.executescript(sql)
print("kept", db.execute("SELECT value FROM settings WHERE key='review.disprove.conductor_left_s'").fetchone()[0])
PY
  [ "$?" = 0 ] && ok || bad "S1 the schema did not apply: $(head -n 3 "$T/s1.out")"
  grep -qx 'first 900' "$T/s1.out" && grep -qx "twice (1, '900')" "$T/s1.out" && grep -qx 'kept 600' "$T/s1.out" && ok || bad "S1 rows: $(cat "$T/s1.out")"
else
  bad "S1 the composed schema could not be checked"
fi

# ── V1 0 real vendor calls ──
[ -e "$T/vendor-calls" ] && bad "V1 a real vendor call ran: $(head -n 3 "$T/vendor-calls")" || ok

echo "review-disprove-conductor.bh-9047: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

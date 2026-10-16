#!/bin/bash
# tests/lesson-propose-floor.bh-7123-test.sh — BH-7123 wave B: the ratchet
# ignores a cowboy sprint and never proposes a gate for a non-floor cause.
#
#   L1  a category whose cause is NOT on the ALWAYS-BLOCK list
#       (catalog/review-ratchet-categories.tsv) gets a NOTE-level check: the
#       issue body says `Level: note`, that the check never refuses or stops a
#       build, and the drafting prompt asked for that.
#   L2  a category on the list (iron-law) gets `Level: gate` naming its class.
#   L3  BLOCK verdicts whose lead report was judged under cowboy/off are
#       dropped from a trigger: 2 of 3 cowboy -> under min_blocks, no model
#       call, no issue; 0 of 3 cowboy -> the call happens.
#   J1  bin/lib/review-judged.sh rj_pr_mode reads the newest local report of a
#       PR, falls back to the verdict row's `report:` token, says unknown
#       (rc 1) when nothing is reachable.
#   T1  bin/review-tighten.sh drops merges judged under cowboy/off from its
#       reverted/merges ratio: 3 reverted of 10, all 3 judged cowboy -> no
#       TIGHTENED line, the log counts the skipped merges.
#
# Driven through the SHIPPED lanes against a scratch harness: a stub
# bin/jobs-client.sh (triggers, verdicts and ledger answers from $T), a stub
# agent-call.sh that answers from $T/answer, tests/lib/gh-rest-fx.sh for GitHub.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose-floor.bh-7123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }
command -v jq >/dev/null || { echo "lesson-propose-floor: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "lesson-propose-floor: python3 is required"; exit 1; }

H="$T/h"; FXT="$T/fxt"; mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/flags" "$H/state/lead-reviews" "$H/catalog" "$FXT" "$T/fakebin" "$T/tmp"
export FXT
# Stubs that must be in place BEFORE the closure install (it never overwrites).
cat > "$H/bin/lib/lane-model.sh" <<'SH'
lane_role_model() { echo fake-model; }
SH
cat > "$H/bin/jobs-client.sh" <<'SH'
JOBS_BOX=test-box
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/reqlog"
  case "$1 $2" in
    "GET /api/lesson-propose/triggers") cat "$FXT/triggers.json" ;;
    "GET /api/verdicts?"*) pr=$(printf '%s' "$2" | sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p')
       if [ -f "$FXT/verdicts-$pr.json" ]; then cat "$FXT/verdicts-$pr.json"; else echo '{"rows":[]}'; fi ;;
    "GET /api/ledger?"*) echo '{"ledgers":[]}' ;;
    "GET /api/settings/"*) return 2 ;;
    *) return 2 ;;
  esac
}
job_ledger_row() { return 2; }
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FXT/ledger.log"; }
job_ledger_claim() { return 0; }
job_ledger_list() { return 1; }
setting_get() { return 2; }
SH
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
n=$(( $(cat "$FXT/agentcalls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/agentcalls"
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
cat "$FXT/answer" > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
( cd "$DIR" && scratch_install_closure bin/lesson-propose.sh "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure bin/lesson-propose.sh"; exit 1; }
[ -f "$DIR/bin/lib/review-judged.sh" ] && ( cd "$DIR" && scratch_install_closure bin/lib/review-judged.sh "$H" ) >/dev/null
cp "$DIR"/catalog/review-*.tsv "$H/catalog/" 2>/dev/null
: > "$H/env/global.env"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }
command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/bash\nshasum -a 256 "$@"\n' > "$T/fakebin/sha256sum"; chmod +x "$T/fakebin/sha256sum"; }
REG=$(rendered_registry)
ghfx_init
export HARNESS="$H" PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" LANE_REGISTRY="$REG" LANE_GATE_DISABLE=1 \
       HARNESS_REPO=o/r LESSON_PROPOSE_NOW=2026-10-16T12:00:00Z JOBS_URL=
unset HARNESS_SECRET GH_TOKEN LESSON_PROPOSE_ENABLED LESSON_PROPOSE_MAX_PER_TICK
b64() { base64 < "$1" | tr -d '\n'; }
ghfx_route GET "repos/o/r/issues*" 200 '[]'
ghfx_route GET "repos/o/r/pulls*" 200 '[]'
ghfx_route GET "repos/o/r/contents/prompts/plan-contract.md*" 200 "$(jq -nc --arg c "$(b64 "$DIR/prompts/plan-contract.md")" '{content:$c}')"
ghfx_route GET "repos/o/r/contents/prompts/build-discipline.md*" 200 "$(jq -nc --arg c "$(b64 "$DIR/prompts/build-discipline.md")" '{content:$c}')"
ghfx_extra <<'SH'
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  n=$(( $(cat "$GHFX/post.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHFX/post.n"
  mkdir -p "$GHFX/posts"; printf '%s\n' "$5" > "$GHFX/posts/$n.path"
  prev=""; for a in "$@"; do [ "$prev" = --input ] && cp "$a" "$GHFX/posts/$n.body"; prev="$a"; done
  printf 'HTTP/1.1 201 Created\r\n\r\n{"number":%s,"html_url":"https://github.com/o/r/issues/%s"}' $((200+n)) $((200+n))
  exit 0
fi
SH

sha() { printf 'a%039d' "$1"; }
report() { # report <pr> <mode> — a local lead report of o/r#<pr> judged under <mode>
  local f="$H/state/lead-reviews/lr-$1-$(sha "$1" | cut -c1-12).md"
  { printf '# Lead review lr-%s-%s (o/r#%s at %s)\n\n- verdict: BLOCK\n' "$1" "$(sha "$1" | cut -c1-12)" "$1" "$(sha "$1")"
    [ "$2" = none ] || printf -- '- review level (BH-7123): mode=%s demoted=1 standing=1 verdict=BLOCK\n' "$2"
    printf '\n- [BLOCK] x\n'
    [ "$2" = none ] || printf 'Review level (BH-7123): mode %s, 1 finding(s) demoted to NOTE, 1 BLOCK stands; verdict BLOCK.\n' "$2"
    printf 'VERDICT: BLOCK\n'; } > "$f"
  printf '%s' "$f"
}
verdicts() { # verdicts <pr> <id> <report-rel-path>
  jq -nc --argjson id "$2" --argjson pr "$1" --arg r "$3" \
    '{rows:[{id:$id, repo:"o/r", pr:$pr, head_sha:"x", source:"lead", verdict:"BLOCK", note:("lead-review:lr-x report:" + $r)}]}' > "$FXT/verdicts-$1.json"
}
trigger() { # trigger <category-id> <name> <stage> — one category over verdicts 1,2,3 on prs 11,12,13
  jq -nc --arg id "$1" --arg n "$2" --arg st "$3" '{since:"2026-10-02T12:00:00Z",
    settings:{since_days:14, cooldown_days:14, max_attempts:3, min_blocks:3}, clusters:[],
    categories:[{id:$id, name:$n, description:"d", suggested_stage:$st, blocks:3, findings:3, infra_false:0,
      verdict_ids:[1,2,3],
      prs:[{repo:"o/r",pr:11,report_url:null,ticket:null},{repo:"o/r",pr:12,report_url:null,ticket:null},{repo:"o/r",pr:13,report_url:null,ticket:null}],
      evidence:[{text:"finding one",cause:"c1",files:["a.sh"],repo:"o/r",pr:11},{text:"finding two",cause:"c2",files:[],repo:"o/r",pr:12},{text:"finding three",cause:"c3",files:[],repo:"o/r",pr:13}]}]}' > "$FXT/triggers.json"
}
reset() {
  rm -f "$FXT"/agentcalls "$FXT"/prompt.* "$FXT"/reqlog "$FXT"/ledger.log "$FXT"/verdicts-*.json "$H/logs/lesson-propose.log" "$T/post.n"
  scratch_rm "$T/posts" 2>/dev/null; rm -f "$H/state/lead-reviews/"*.md
  for p in 11 12 13; do report "$p" levels >/dev/null; done
}
run() { ( cd "$T" && bash "$H/bin/lesson-propose.sh" ) > "$T/out" 2>&1; RC=$?; }
calls() { cat "$FXT/agentcalls" 2>/dev/null || echo 0; }
nposts() { ls "$T"/posts/*.path 2>/dev/null | wc -l | tr -d ' '; }
body() { local f; f=$(ls "$T"/posts/*.body 2>/dev/null | head -1); [ -n "$f" ] && jq -r '.body' "$f"; }
LOG="$H/logs/lesson-propose.log"

# ── L1: a non-floor category -> NOTE-level check ─────────────────────────────
reset; trigger missing-body-section "Required PR-body section missing" check
printf '{"target":"check","title":"Lint the PR body for the gate table","text":"Refuse a PR whose body lacks the gate table.","acceptance_tests":["a body without the table is refused"],"why":"it repeats"}\n' > "$FXT/answer"
run
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC: $(cat "$T/out"; cat "$LOG" 2>/dev/null)"
[ "$(calls)" = 1 ] && ok || bad "L1 one model call, got $(calls): $(cat "$LOG" 2>/dev/null)"
[ "$(nposts)" = 1 ] && ok || bad "L1 one issue POST, got $(nposts): $(cat "$LOG" 2>/dev/null)"
B=$(body)
has "L1 body level" "$B" "Level: note"
has "L1 body says the check never refuses" "$B" "never refuses"
has "L1 body names the floor" "$B" "ALWAYS-BLOCK"
hasnt "L1 body is not a gate" "$B" "Level: gate"
P=$(cat "$FXT/prompt.1" 2>/dev/null)
has "L1 prompt asks for a NOTE-level check" "$P" "NOTE-level"
has "L1 prompt says why" "$P" "not on the ALWAYS-BLOCK"

# ── L2: a floor category -> a gate, naming its class ─────────────────────────
reset; trigger iron-law "Iron law broken" check
run
[ "$(nposts)" = 1 ] && ok || bad "L2 one issue POST, got $(nposts): $(cat "$LOG" 2>/dev/null)"
B=$(body)
has "L2 body level gate" "$B" "Level: gate"
has "L2 body names a class" "$B" "model-id"
P=$(cat "$FXT/prompt.1" 2>/dev/null)
has "L2 prompt allows a gate" "$P" "may refuse"

# ── L3: cowboy-judged verdicts leave the trigger ─────────────────────────────
reset; trigger missing-body-section "Required PR-body section missing" check
report 11 cowboy >/dev/null; report 12 off >/dev/null
run
[ "$(calls)" = 0 ] && ok || bad "L3 2 of 3 judged cowboy/off must not call the model: calls=$(calls)"
[ "$(nposts)" = 0 ] && ok || bad "L3 nothing filed"
has "L3 log says why" "$(cat "$LOG" 2>/dev/null)" "2 of 3"
has "L3 log names cowboy" "$(cat "$LOG" 2>/dev/null)" "cowboy"
reset; trigger missing-body-section "Required PR-body section missing" check
report 11 cowboy >/dev/null
run
[ "$(calls)" = 0 ] && ok || bad "L3b 1 of 3 judged cowboy leaves 2 < min_blocks 3: calls=$(calls)"
# the verdict row's report: token reaches the same file when no local glob matches the repo
reset; trigger missing-body-section "Required PR-body section missing" check
rm -f "$H/state/lead-reviews/"*.md
f=$(report 11 cowboy); mv "$f" "$H/state/lead-reviews/other-name.md"
verdicts 11 1 "state/lead-reviews/other-name.md"
run
[ "$(calls)" = 0 ] && ok || bad "L3c the report: token path must be read: calls=$(calls) $(cat "$LOG")"
has "L3c the verdicts row was read" "$(cat "$FXT/reqlog")" "/api/verdicts?"
reset; trigger missing-body-section "Required PR-body section missing" check
run
[ "$(calls)" = 1 ] && ok || bad "L3d with every report at levels the call happens: calls=$(calls) $(cat "$LOG")"
reset; trigger missing-body-section "Required PR-body section missing" check
rm -f "$H/state/lead-reviews/"*.md
run
[ "$(calls)" = 1 ] && ok || bad "L3e unreachable reports keep every verdict (fail-open): calls=$(calls) $(cat "$LOG")"

# ── J1: rj_pr_mode ───────────────────────────────────────────────────────────
if [ -f "$DIR/bin/lib/review-judged.sh" ] && . "$DIR/bin/lib/review-judged.sh" && command -v rj_pr_mode >/dev/null 2>&1; then
  . "$H/bin/jobs-client.sh"
  rm -f "$H/state/lead-reviews/"*.md "$FXT"/verdicts-*.json
  report 11 cowboy >/dev/null; report 12 none >/dev/null
  [ "$(rj_pr_mode o/r 11)" = cowboy ] && ok || bad "J1 local report: $(rj_pr_mode o/r 11)"
  [ "$(rj_pr_mode o/r 12)" = strict ] && ok || bad "J1 a report with no marker reads strict: $(rj_pr_mode o/r 12)"
  [ "$(rj_pr_mode other/repo 11)" = unknown ] && ok || bad "J1 another repo's PR 11 must not match: $(rj_pr_mode other/repo 11)"
  out=$(rj_pr_mode o/r 99); rc=$?
  [ "$out" = unknown ] && [ "$rc" = 1 ] && ok || bad "J1 nothing reachable: out=$out rc=$rc"
  f=$(report 13 off); mv "$f" "$H/state/lead-reviews/renamed.md"; verdicts 13 7 "state/lead-reviews/renamed.md"
  [ "$(rj_pr_mode o/r 13)" = off ] && ok || bad "J1 verdict row report: token: $(rj_pr_mode o/r 13)"
  [ "$(rj_verdict_modes o/r 13)" = "7	off" ] && ok || bad "J1 rj_verdict_modes: $(rj_verdict_modes o/r 13)"
else
  bad "J bin/lib/review-judged.sh with rj_pr_mode is missing"
fi

# ── T1: review-tighten skips cowboy-judged merges ────────────────────────────
H4="$T/h4"; mkdir -p "$H4/logs" "$H4/state/lead-reviews" "$H4/flags" "$H4/locks" "$H4/env" "$T/resp"
for L in bin/review-tighten.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H4" ) >/dev/null || bad "T1 scratch_install_closure $L"
done
echo "HARNESS_SECRET=test-secret" > "$H4/env/global.env"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*"/api/ledger"*)           cat "$RESP/ledger.json"; echo; echo 200 ;;
  "GET "*"/api/metrics/outcomes"*) cat "$RESP/outcomes.json"; echo; echo 200 ;;
  "GET "*"/api/review-gate"*)      echo '{"thresholds":[],"gates":[]}'; echo 200 ;;
  "PUT "*"/api/review-gate"*)      echo '{"gate":{}}'; echo 200 ;;
  "GET "*"/api/verdicts"*)         echo '{"rows":[]}'; echo 200 ;;
  "GET "*"/api/flags/"*)           echo '{}'; echo 404 ;;
  "PUT "*"/api/flags"*)            echo '{"flag":{"updated_at":"2026-10-16T00:00:00Z"}}'; echo 200 ;;
  *)                               echo '{}'; echo 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
D_AGO() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok the lane counts BLOCKs inside its own since_days window measured from now, so fixture ages are relative on purpose and every assertion is on a count, never a date
{ printf '{"ledgers":['
  for n in 1 2 3 4 5 6 7 8 9 10; do [ "$n" = 1 ] || printf ','
    printf '{"key":"https://github.com/o/hot/pull/%s","status":"merged","job_id":"b%s","updated_at":"%s"}' "$n" "$n" "$(D_AGO 3)"; done
  printf ']}'; } > "$T/resp/ledger.json"
printf '[]' > "$T/resp/outcomes.json"
cat > "$T/resp/outcomes.csv" <<EOF
date,repo,pr,outcome
$(D_AGO 2),o/hot,https://github.com/o/hot/pull/1,reverted
$(D_AGO 2),o/hot,https://github.com/o/hot/pull/2,reverted
$(D_AGO 2),o/hot,https://github.com/o/hot/pull/3,reopened
EOF
cp "$T/resp/outcomes.csv" "$H4/logs/outcome-metrics.csv"
for n in 1 2 3; do
  printf '# Lead review lr-%s-aaaaaaaaaaaa (o/hot#%s at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)\n\n- verdict: MERGE-WITH-NOTES\n- review level (BH-7123): mode=cowboy demoted=2 standing=0 verdict=MERGE-WITH-NOTES\n\nbody\n' "$n" "$n" > "$H4/state/lead-reviews/lr-$n-aaaaaaaaaaaa.md"
done
tighten() { ( cd "$T" && env HARNESS="$H4" RESP="$T/resp" JOBS_URL=https://jobs.test HARNESS_SECRET=test-secret JOBS_RETRIES=0 LANE_GATE_DISABLE=1 PATH="$T/fakebin:$PATH" bash "$H4/bin/review-tighten.sh" ) >/dev/null 2>&1; }
tighten
TL=$(cat "$H4/logs/review-tighten.log" 2>/dev/null)
has "T1 the log counts the skipped merges" "$TL" "cowboy_skipped=3"
! grep -q 'TIGHTENED' "$H4/logs/ALERTS.log" 2>/dev/null && ok || bad "T1 three cowboy-judged reverts must not tighten: $(cat "$H4/logs/ALERTS.log")"
[ -z "$(ls "$H4/flags" 2>/dev/null | grep review-tighten)" ] && ok || bad "T1 no tighten flag: $(ls "$H4/flags")"
rm -f "$H4/state/lead-reviews/"*.md "$H4/logs/review-tighten.log"
tighten
TL=$(cat "$H4/logs/review-tighten.log" 2>/dev/null)
has "T1b without reports nothing is skipped" "$TL" "cowboy_skipped=0"
grep -q 'TIGHTENED' "$H4/logs/ALERTS.log" 2>/dev/null && ok || bad "T1b the same reverts, judged normally, tighten: $(cat "$H4/logs/ALERTS.log" 2>/dev/null)"

echo "lesson-propose-floor.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

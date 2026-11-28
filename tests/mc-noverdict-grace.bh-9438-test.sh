#!/bin/bash
# tests/mc-noverdict-grace.bh-9438-test.sh — BH-9438 item 1: no paid re-review
# before the first verdict can bind (bin/merge-conductor.d/
# bh-9438-noverdict-grace.sh, wired into pr_worker, mc_classify and
# headbound_review).
#
# WHY. 343 of 921 HEAD_MOVED events on the hub (2026-10-27..11-10) were the
# conductor's FIRST sight of a PR, before the builder's own verdict bound to
# it. mc_classify said `no verdict bound to head … — fresh detached review` and
# headbound_review bought a paid re-review of a head the builder was about to
# verdict anyway.
#
#   G1-G9   mc_nvg_in_grace: the decision table (in grace / not in grace)
#   G10     the `nvseen` first-seen line round trip: file store and row twin
#   R1      mc_classify under MC_NV_GRACE=1: HEAD_MOVED, the new reason
#   R2      headbound_review moved in grace: 0 spawns, 0 budget, 0 daily-cap
#           takes, one NV_GRACE line (said once)
#   R3      in grace, an autopilot MERGE on this head still binds (free consume)
#   R5      in grace, a BH-9693 buy on an autopilot BLOCK still spawns
#   R4      grace over (MC_NV_GRACE=0, and an `nvseen` line 900 s old): 1 spawn
#   W1      THE REPRODUCTION, a whole bin/merge-conductor.sh tick: a PR with no
#           verdict is HEAD_MOVED with the grace reason and buys no review
#   D1      the four BH-9438 knob rows: catalog entries, code fallbacks
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-noverdict-grace.bh-9438-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-9438-noverdict-grace.sh"
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1   # impact: bin/merge-conductor.sh bin/lib/mc/classify.sh bin/merge-conductor.d/bh-9438-noverdict-grace.sh

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The fragment under test, where the driver sources it (absent on the merge base).
mkdir -p "$T/h/bin/merge-conductor.d"
[ -f "$FRAG" ] && cp "$FRAG" "$T/h/bin/merge-conductor.d/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'nvg example-org/nvg-os - - 2 box-n\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

KEY='example-org/nvg-os#41'
URL=https://github.com/example-org/nvg-os/pull/41
HA=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
HB=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
N0=1800000000

# lib — the conductor lib, mc_init, and the fragment under test (absent on the
# merge base: every G case is then red).
LIB=". '$T/h/bin/lib/merge-conductor-lib.sh' >/dev/null 2>&1; mc_init >/dev/null 2>&1; [ -r '$FRAG' ] && . '$FRAG'"
# g <now> <reviewed> <verdict> [head] — rc of mc_nvg_in_grace, then MC_NVG_LEFT.
g() {
  bash -c "$LIB
    mc_now() { echo $1; }
    lane_knob() { [ \"\$2\" = MC_NOVERDICT_GRACE_S ] && [ -n \"\${KNOB:-}\" ] && echo \"\$KNOB\"; return 0; }
    mc_nvg_in_grace '$KEY' '${4:-$HA}' '$2' '$3'; echo \"rc=\$? left=\${MC_NVG_LEFT:-}\"" 2>/dev/null
}
ATT="$T/h/state/merge-conductor/attempts.txt"
nvseen_lines() { awk -v p="nvseen $KEY ${1:-$HA} " 'index($0, p) == 1 { n++ } END { print n + 0 }' "$ATT" 2>/dev/null; }
reset_att() { mkdir -p "${ATT%/*}"; : > "$ATT"; }

# ============================================================================
# G1-G9: the decision table.
# ============================================================================
reset_att
O=$(g $N0 - "")
[ "$O" = "rc=0 left=900" ] && [ "$(nvseen_lines)" = 1 ] && grep -qx "nvseen $KEY $HA $N0" "$ATT" \
  && pass "G1: no verdict, reviewed -, first sight: in grace, 900 s left, one nvseen line" || fail "G1: got '$O', nvseen $(nvseen_lines)"
reset_att; echo "nvseen $KEY $HA $((N0 - 899))" > "$ATT"
O=$(g $N0 "" "")
[ "$O" = "rc=0 left=1" ] && pass "G2: no verdict, reviewed empty, first seen 899 s ago (grace 900): in grace" || fail "G2: got '$O'"
reset_att
g $N0 - - >/dev/null; O=$(g $((N0 + 300)) - -)
[ "$O" = "rc=0 left=600" ] && [ "$(nvseen_lines)" = 1 ] \
  && pass "G3: verdict -, a second tick 300 s later: still in grace, the first-seen line is not rewritten" || fail "G3: got '$O', nvseen $(nvseen_lines)"
reset_att; echo "nvseen $KEY $HA $((N0 - 900))" > "$ATT"
O=$(g $N0 - "")
[ "${O%% *}" = rc=1 ] && pass "G4: first seen exactly 900 s ago: grace over" || fail "G4: got '$O'"
reset_att
O=$(g $N0 "$HB" "")
[ "${O%% *}" = rc=1 ] && [ "$(nvseen_lines)" = 0 ] && pass "G5: reviewed is another sha (a real drift): not in grace, no line" || fail "G5: got '$O', nvseen $(nvseen_lines)"
O=$(g $N0 "$HA" "")
[ "${O%% *}" = rc=1 ] && [ "$(nvseen_lines)" = 0 ] && pass "G6: reviewed = head, verdict empty (a cleared verdict): not in grace" || fail "G6: got '$O'"
O=$(g $N0 - APPROVE); O2=$(g $N0 - BLOCK)
[ "${O%% *}" = rc=1 ] && [ "${O2%% *}" = rc=1 ] && [ "$(nvseen_lines)" = 0 ] \
  && pass "G7: verdict APPROVE or BLOCK: not in grace" || fail "G7: got '$O' / '$O2'"
O=$(KNOB=0 g $N0 - "")
[ "${O%% *}" = rc=1 ] && [ "$(nvseen_lines)" = 0 ] && pass "G8: knob 0: off, nothing written" || fail "G8: got '$O', nvseen $(nvseen_lines)"
reset_att
O=$(KNOB=abc g $N0 - "")
[ "$O" = "rc=0 left=900" ] && pass "G8: knob not a number: the 900 s fallback applies" || fail "G8 junk knob: got '$O'"
O=$(KNOB=60 g $((N0 + 60)) - "")
[ "${O%% *}" = rc=1 ] && pass "G8: knob 60 (a settings row): 60 s after first sight the grace is over" || fail "G8 knob 60: got '$O'"
O=$(bash -c "$LIB
  mc_now() { echo $N0; }; MC_ATTEMPTS='$T/no-such-dir/attempts.txt'
  mc_nvg_in_grace '$KEY' '$HA' - ''; echo rc=\$?" 2>/dev/null)
[ "$O" = rc=1 ] && pass "G9: an attempts ledger that gives no epoch back: today's path" || fail "G9: got '$O'"
reset_att
g $N0 - "" >/dev/null; O=$(g $((N0 + 1000)) - "" "$HB")
[ "$O" = "rc=0 left=900" ] && [ "$(nvseen_lines "$HB")" = 1 ] \
  && pass "G9: a new head on the same PR gets its own first-seen line and its own grace" || fail "G9 new head: got '$O'"

# ============================================================================
# G10: the nvseen round trip, rows twin on.
# ============================================================================
reset_att; : > "$T/rows.txt"
O=$(bash -c "$LIB
  mc_now() { echo \${NOWX:-$N0}; }
  pr_rows_on() { return 0; }
  pr_attempt_put() { printf '%s %s %s %s\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\" >> '$T/rows.txt'; }
  pr_attempt_list() { local o; o=\$(awk -v r=\"\$1\" -v n=\"\$2\" -v k=\"\$3\" '\$1==r && \$2==n && \$3==k { sub(/^[^ ]+ [^ ]+ [^ ]+ /, \"\"); print }' '$T/rows.txt' | tac); [ -n \"\$o\" ] || return 2; printf '%s\n' \"\$o\"; }
  mc_nvg_in_grace '$KEY' '$HA' - ''; a=\$?
  : > '$ATT'
  NOWX=$((N0 + 120)) mc_nvg_in_grace '$KEY' '$HA' - ''; echo \"\$a \$? \$MC_NVG_LEFT\"" 2>/dev/null)
[ "$O" = "0 0 780" ] && [ "$(grep -c "^example-org/nvg-os 41 nvseen $HA $N0" "$T/rows.txt")" = 1 ] && [ "$(wc -l < "$T/rows.txt")" = 1 ] \
  && pass "G10: rows twin: the first-seen epoch is read back from the row (file emptied), not rewritten" \
  || fail "G10: got '$O', rows: $(tr '\n' '|' < "$T/rows.txt")"

# ============================================================================
# R1: mc_classify.
# ============================================================================
R1=$(bash -c "$LIB; MC_NV_GRACE=1 MC_NVG_LEFT=900 mc_classify OPEN CLEAN MERGEABLE $HA - - - green 0 0 0 0 - -" 2>/dev/null)
case "$R1" in
  "HEAD_MOVED	no verdict yet on head ${HA:0:8} — first-verdict grace, 900s left; no review bought") pass "R1: in grace: HEAD_MOVED, reason 'no verdict yet … first-verdict grace'" ;;
  *) fail "R1: got '$R1'" ;;
esac
R1b=$(bash -c "$LIB; mc_classify OPEN CLEAN MERGEABLE $HA - - - green 0 0 0 0 - -" 2>/dev/null)
[ "$R1b" = "HEAD_MOVED	no verdict bound to head ${HA:0:8} — fresh detached review" ] \
  && pass "R1: MC_NV_GRACE unset: the reason is byte-identical to before" || fail "R1 unset: got '$R1b'"
R1c=$(bash -c "$LIB; MC_NV_GRACE=1 mc_classify OPEN CLEAN MERGEABLE $HA $HB APPROVE claude green 0 0 0 0 - -" 2>/dev/null)
[ "$(cut -f2 <<<"$R1c")" = "reviewed ${HB:0:8} head ${HA:0:8}" ] && pass "R1: a real drift (reviewed another sha) keeps its reason" || fail "R1 drift: got '$R1c'"

# ============================================================================
# R2-R4: headbound_review moved, the spawn and its neighbours stubbed.
# ============================================================================
CLOG="$T/h/logs/merge-conductor.log"
# hb <grace 0|1> [autopilot verdict] — one moved-mode headbound_review of #41
#   on a green head; the counters land in $T/calls.txt.
hb() {
  bash -c "$LIB
    mc_now() { echo \${NOWX:-$N0}; }
    lane_knob() { return 0; }
    CAPFILE='$T/cap.txt'; REREVIEW_CAP=5; REREVIEW_BUDGET=5; MC_TICK_ID=r-\${TICKN:-1}
    mc_job_running() { return 1; }
    mc_lane_next_review_account() { echo fixture-acct; }
    mc_lane_down_for_account() { return 1; }
    review_dedupe_on() { return 1; }
    mc_day_budget_take() { echo daytake >> '$T/calls.txt'; echo 2026-11-11; }
    mc_day_budget_give() { :; }
    mc_rereview_spawn() { echo spawn >> '$T/calls.txt'; return 0; }
    mc_ap_consumed() { [ -z \"\${APV:-}\" ]; }
    mc_autopilot_verdict() { printf '%s' \"\${APV:-}\"; }
    hb_approve_bind() { echo bind >> '$T/calls.txt'; return 1; }
    mc_hnr_decide() { printf '%s\\t%s\\n' \"\${HNR:-park}\" 'fixture hnr'; }
    MC_NV_GRACE=0
    if [ '$1' = auto ]; then mc_nvg_in_grace '$KEY' '$HA' - - && MC_NV_GRACE=1; else MC_NV_GRACE='$1'; MC_NVG_AGE=0; MC_NVG_GRACE=900; fi
    headbound_review moved '$KEY' example-org/nvg-os 41 nvg '$URL' - '$HA' - - CLEAN green
    echo \"rc=\$? budget=\$(mc_count_get nvg budget-rereview)\"" 2>"$T/hb.err"
}
cnt() { awk -v w="$1" '$0 == w { n++ } END { print n + 0 }' "$T/calls.txt" 2>/dev/null; }
reset_att; : > "$T/calls.txt"; : > "$CLOG"; : > "$T/cap.txt"
O=$(hb 1)
[ "$(cnt spawn)" = 0 ] && [ "$(cnt daytake)" = 0 ] && [ "$O" = "rc=0 budget=0" ] \
  && pass "R2: in grace: 0 spawns, 0 daily-cap takes, 0 tick budget units" || fail "R2: got '$O', spawns $(cnt spawn), daytakes $(cnt daytake); err: $(tail -3 "$T/hb.err")"
[ "$(grep -c "NV_GRACE $KEY ${HA:0:8} — no verdict bound yet; first seen 0s ago, grace 900s; no review bought" "$CLOG")" = 1 ] \
  && pass "R2: one NV_GRACE line" || fail "R2: log: $(tail -3 "$CLOG")"
TICKN=2 hb 1 >/dev/null
[ "$(grep -c "NV_GRACE $KEY" "$CLOG")" = 1 ] && [ "$(cnt spawn)" = 0 ] && pass "R2: a second call in grace adds no line and no spawn" || fail "R2 second: $(grep -c "NV_GRACE" "$CLOG") lines, $(cnt spawn) spawns"
reset_att; : > "$T/calls.txt"
O=$(APV=MERGE hb 1)
[ "$(cnt bind)" = 1 ] && [ "$(cnt spawn)" = 0 ] && pass "R3: in grace, an autopilot MERGE on this head still binds (free consume first)" || fail "R3: got '$O', binds $(cnt bind), spawns $(cnt spawn)"
# R5 — a BH-9693 buy (an autopilot BLOCK bound to this head, mc_hnr_decide
#   answers buy) is a verdict already on the head, not "no verdict yet": the
#   grace must not hold it (lr-9493 NOTE).
reset_att; : > "$T/calls.txt"; : > "$CLOG"
O=$(APV=BLOCK HNR=buy hb 1)
[ "$(cnt spawn)" = 1 ] && ! grep -q "NV_GRACE $KEY" "$CLOG" \
  && pass "R5: in grace, a BH-9693 buy on an autopilot BLOCK still spawns its review" || fail "R5: got '$O', spawns $(cnt spawn), log $(tail -2 "$CLOG" | tr '\n' '|')"
reset_att; : > "$T/calls.txt"; : > "$CLOG"
O=$(hb 0)
[ "$(cnt spawn)" = 1 ] && [ "$(cnt daytake)" = 1 ] && ! grep -q NV_GRACE "$CLOG" \
  && pass "R4: MC_NV_GRACE=0: today's path, 1 spawn" || fail "R4: got '$O', spawns $(cnt spawn)"
reset_att; : > "$T/calls.txt"; echo "nvseen $KEY $HA $((N0 - 900))" > "$ATT"
O=$(hb auto)
[ "$(cnt spawn)" = 1 ] && pass "R4: first seen 900 s ago: the grace is over and the review is bought" || fail "R4 expired: got '$O', spawns $(cnt spawn)"
reset_att; : > "$T/calls.txt"
O=$(hb auto)
[ "$(cnt spawn)" = 0 ] && pass "R4: first sight through mc_nvg_in_grace: no spawn" || fail "R4 first sight: got '$O', spawns $(cnt spawn)"

# ============================================================================
# W1: the whole tick. #41 has no build record and no verdict: first sight.
# ============================================================================
M=cccccccccccccccccccccccccccccccccccccccc
{ printf '#!/bin/bash\nT=%s\nM=%s\n' "$T" "$M"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$*" in
  *"api -i -X GET repos/example-org/nvg-os/pulls?state=open"*|*"api -i -X GET repos/example-org/nvg-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/nvg-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/nvg-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/nvg-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  *"api -i -X GET repos/example-org/nvg-os/commits/main"*) restpr --raw 200 "{\"sha\":\"$M\"}" ;;
  *"api -i -X GET repos/example-org/nvg-os/commits/"*) restpr --raw 200 '{"commit":{"committer":{"date":"2026-11-10T20:00:00Z"}}}' ;;
  *"api -X POST repos/"*"/comments"*|*"api -i -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":901}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/nv-$PN" main "" MERGEABLE CLEAN operator ;;
  *"api repos/example-org/nvg-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/nvg-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
MCD="$T/h/state/merge-conductor"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
printf '[{"number":41,"url":"%s","headRefOid":"%s","headRefName":"ticket/nv-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[],"baseRefName":"main"}]' \
  "$URL" "$HA" > "$T/list.json"
echo "$HA" > "$T/head-41"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
row_of() { awk -F'\t' -v k="$KEY" '$1==k {print $2 "|" $7}' "$MCD/pr-state.tsv" 2>/dev/null; }
rm -f "$MCD/pr-state.tsv"; : > "$ATT"; : > "$CLOG"
run_tick
W=$(row_of)
case "$W" in
  "HEAD_MOVED|no verdict yet on head ${HA:0:8} — first-verdict grace, "*"s left; no review bought") pass "W1: a whole tick: HEAD_MOVED with the first-verdict grace reason" ;;
  *) fail "W1: row '$W'; log: $(grep -o "$KEY.*" "$CLOG" | tail -4 | tr '\n' '|')" ;;
esac
grep -qE "REREVIEW_SPAWNED|REREVIEW_QUEUED|detached re-review could not be spawned|re-review deferred" "$CLOG" \
  && fail "W1: the tick tried to buy a review: $(grep -oE "$KEY (REREVIEW|detached|re-review).*" "$CLOG" | head -2)" \
  || pass "W1: the tick bought no review"
[ "$(grep -c "NV_GRACE $KEY ${HA:0:8}" "$CLOG")" = 1 ] && pass "W1: one NV_GRACE line" || fail "W1: NV_GRACE lines $(grep -c "NV_GRACE" "$CLOG")"
grep -q "^nvseen $KEY $HA [0-9]*$" "$ATT" && pass "W1: the first-seen line is written" || fail "W1: attempts: $(tr '\n' '|' < "$ATT")"

# ============================================================================
# D1: the knob rows.
# ============================================================================
KD="$DIR/catalog/lanes.d/merge-conductor.knobs.d"
D1=$(for k in MC_NOVERDICT_GRACE_S MC_EJECT_REREAD MC_EJECT_REREAD_PER_TICK MC_EJECT_REREAD_UNREAD_MAX; do
  jq -r '"\(.env)=\(.default):\(.min)-\(.max):\(.zero_means):\(.read_in)"' "$KD/$k.json" 2>/dev/null || echo "$k=missing"; done | tr '\n' ' ')
[ "$D1" = "MC_NOVERDICT_GRACE_S=900:0-1500:off:bin/merge-conductor.d/bh-9438-noverdict-grace.sh MC_EJECT_REREAD=1:0-1:off:bin/merge-conductor.d/bh-9438-eject-reread.sh MC_EJECT_REREAD_PER_TICK=10:0-200:off:bin/merge-conductor.d/bh-9438-eject-reread.sh MC_EJECT_REREAD_UNREAD_MAX=3:1-20:null:bin/merge-conductor.d/bh-9438-eject-reread.sh " ] \
  && pass "D1: the four knob rows exist with their defaults, bounds and readers" || fail "D1: got '$D1'"
grep -q '_mc_nvg_knob MC_NOVERDICT_GRACE_S 900)' "$FRAG" 2>/dev/null \
  && grep -q 'ec_knob MC_EJECT_REREAD 1)' "$DIR/bin/merge-conductor.d/bh-9438-eject-reread.sh" 2>/dev/null \
  && grep -q 'ec_knob MC_EJECT_REREAD_PER_TICK 10)' "$DIR/bin/merge-conductor.d/bh-9438-eject-reread.sh" 2>/dev/null \
  && grep -q 'ec_knob MC_EJECT_REREAD_UNREAD_MAX 3)' "$DIR/bin/merge-conductor.d/bh-9438-eject-reread.sh" 2>/dev/null \
  && pass "D1: each code fallback equals its catalog default" || fail "D1: a code fallback is missing or differs"
D1K=0
for k in MC_NOVERDICT_GRACE_S MC_EJECT_REREAD MC_EJECT_REREAD_PER_TICK MC_EJECT_REREAD_UNREAD_MAX; do
  grep -q "lane.merge-conductor.$(tr 'A-Z' 'a-z' <<<"$k")" "$KD/$k.json" 2>/dev/null || { fail "D1: $k names no settings row"; D1K=1; }
done
[ "$D1K" = 0 ] && pass "D1: each knob row names its settings key"

echo "mc-noverdict-grace.bh-9438: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

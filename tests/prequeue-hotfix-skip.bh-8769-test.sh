#!/bin/bash
# tests/prequeue-hotfix-skip.bh-8769-test.sh — BH-8769 item 1: a READY head
# labelled MC_MAIN_RED_LABEL (default fix-main-red) in a mergify repo skips the
# pre-queue verdict. The batch-of-1 hotfix queue runs that head alone, so a
# prequeue-gate.yml run in front of it only adds time.
#
# Every gate case runs the REAL pq_gate (bin/lib/mc-prequeue.sh) with every
# real hook in bin/lib/mc-prequeue.d/ (hotfix-skip.sh, dispatch.sh, status.sh,
# group.sh), the real lane_knob (bin/lib/lane-gate.sh) over a settings cache,
# and a stub gh / gh_rest / vs_publish. No network call. The labels are RAWLBL,
# the READY row's csv that pr_worker holds in its dynamic scope.
#
#   S0  hotfix-skip.sh reads no knob: the skip has no switch of its own
#   S1  `merge-queue,fix-main-red`: proceed, 0 dispatch, nothing under
#       prequeue/, one prequeue-verdict success with the skipped text, one
#       PREQUEUE_SKIPPED line
#   S2  the label alone, S3 the label first: skip
#   S4  `fix-main-red-2`, S4b `Fix-Main-Red`, S4c `hotfix`: no skip, 1 dispatch
#   S5  the github provider: no skip
#   S6  an empty MC_MAIN_RED_LABEL, S6b `,,` with an empty label: no skip
#   S7  the label and a restamp push: hold, nothing published (the hook ran)
#   S7b the label and a red fast lint: red, a failure status, no skipped text
#   S8  MC_MAIN_RED_LABEL=custom-red with `custom-red`: skip, text names it
#   S9  two ticks on the same head: 1 PREQUEUE_SKIPPED line, 1 POST in total
#   S10 the real ec_requeue_gate with RAWLBL=fix-main-red: no skip, the
#       verdict path (the eject requeue never skips)
#   S10b one shell, two projects: a skipped PR in a project with the gate on,
#        then an unlabelled PR in a project whose row is 0 publishes `gate off`,
#        never the first PR's skipped text (PQ_OFF_WHY reset)
#   S11 bin/merge-conductor.sh WHOLE in a scratch tree: a fix-main-red READY
#       row with a cached red verdict is enqueued on the same tick (D2)
#   S12 the gate row 0 and a could-not-run selection-gate record: the skip
#       wins, 0 PR body reads, no PREQUEUE_FALLBACK line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-hotfix-skip.bh-8769-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.d/hotfix-skip.sh" ] || bad "setup: bin/lib/mc-prequeue.d/hotfix-skip.sh is missing"

NOW=1792900800   # 2026-10-25T00:00:00Z, the settings cache's fetched_at
SLUG=example-org/demo-os
MAIN=$(printf 'c%.0s' $(seq 40))
SKIPPED='skipped (fix-main-red: the hotfix queue runs this head alone)'
GKEY=lane.merge-conductor.mc_prequeue_gate

REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || REG=""
[ -r "$REG" ] || { echo "FAIL: setup: catalog/lanes.json could not be rendered"; exit 1; }

# cache <case> <values-json> — the box settings cache lane_knob reads.
cache() {
  mkdir -p "$T/$1/state"
  jq -nc --argjson fa "$NOW" --argjson v "$2" '{fetched_at:$fa, values:$v, seeded:{}}' > "$T/$1/state/settings-cache.json"
}

# gate <case> <call>... — each call `<num>=<labels-csv>[:<project>]` runs the
#   real pq_gate once, in ONE shell, on head <num>0eee...; `<num>=~` leaves
#   RAWLBL unset, and <project> is the conductor's P for that call. Env: PROV
#   (default mergify), LABEL (MC_MAIN_RED_LABEL, default fix-main-red; `~` =
#   empty), RS_WORD, FL_WORD (a fast lint answer; set = the hook can act),
#   VIA=ec (call through the real ec_requeue_gate). A case dir that exists keeps
#   its attempt ledger and log (a second tick).
#   Sinks: $C/gh, $C/status, $C/log, $C/out, $C/attempts, $C/pullreads,
#   $C/state/prequeue/.
gate() {
  local c="$1"; shift
  local C="$T/$c"
  mkdir -p "$C/state" "$C/tick" "$C/tmp" "$C/logs" "$C/bin"
  touch "$C/gh" "$C/status" "$C/log" "$C/hooks" "$C/attempts" "$C/out"
  [ -r "$C/state/settings-cache.json" ] || cache "$c" '{}'
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
  ( export HARNESS="$C" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL='' TMPDIR="$C/tmp"
    P=""; MC_H="$C"; MC_STATE_DIR="$C/state"; MC_TICK_ID=t8769; MC_TICK_DIR="$C/tick"; MC_LOG="$C/mclog"
    PROVIDER="${PROV:-mergify}"
    if [ "${LABEL:-}" = '~' ]; then MC_MAIN_RED_LABEL=""; else MC_MAIN_RED_LABEL="${LABEL:-fix-main-red}"; fi
    . "$DIR/bin/lib/lane-gate.sh" || exit 1
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"
    . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
    . "$DIR/bin/lib/mc-eject-cause.sh" || exit 1
    mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$C/log"; }
    mc_attempt_has() { grep -qxF -- "$1" "$C/attempts"; }
    mc_attempt_put() { printf '%s\n' "$1" >> "$C/attempts"; }
    mc_use_token() { :; }
    vs_publish() { printf '%s %s %s %s\n' "$LEAD_VERDICT_CONTEXT" "${2:0:12}" "$3" "$4" >> "$C/status"; }
    pq_restamp_wanted() { return 0; }
    pq_restamp() { echo restamp >> "$C/hooks"; echo "${RS_WORD:-none}"; }
    pq_mignum_wanted() { return 0; }
    pq_mignum() { echo mignum >> "$C/hooks"; echo none; }
    pq_fastlint_wanted() { [ -n "${FL_WORD:-}" ]; }
    pq_fastlint() { echo fastlint >> "$C/hooks"; echo "$FL_WORD"; }
    pq_adopt_run() { return 1; }
    pq_impact_reuse() { _pq_ir=none; }; pq_dispatch_veto() { return 1; }
    gh() { printf '%s\n' "$*" >> "$C/gh"; return 0; }
    gh_rest() {
      case "$2" in
        */commits/*) printf '{"sha":"%s"}' "$MAIN" ;;
        */pulls/*) echo pull >> "$C/pullreads"
          jq -nc --arg b "${BODY:-}" '{body:$b}' ;;
        */actions/workflows/prequeue-gate.yml) printf '{}' ;;
        */runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    local s n l hd u
    for s in "$@"; do
      P=""; case "$s" in *:*) P="${s##*:}"; s="${s%:*}" ;; esac
      n="${s%%=*}"; l="${s#*=}"; hd=$(printf '%s0%s' "$n" "$(printf 'e%.0s' $(seq 40))"); hd="${hd:0:40}"
      u="https://github.com/$SLUG/pull/$n"
      if [ "$l" = '~' ]; then unset RAWLBL; else RAWLBL="$l"; fi
      if [ "${VIA:-}" = ec ]; then
        ec_requeue_gate "$SLUG" "$n" "$u" "$hd" main
        printf '%s word=%s why=%s ec=%s\n' "$n" "$PQ_VERDICT" "$PQ_WHY" "$EC_PQ_WORD" >> "$C/out"
      else
        pq_gate "$SLUG" "$n" "$u" "$hd" main > "$C/word"
        printf '%s word=%s why=%s\n' "$n" "$(cat "$C/word")" "$PQ_WHY" >> "$C/out"
      fi
    done
  ) >> "$C/err" 2>&1
}
dispatches() { grep -c '^workflow run prequeue-gate.yml ' "$T/$1/gh" 2>/dev/null; }
store() { find "$T/$1/state/prequeue" -type f 2>/dev/null | wc -l | tr -d ' '; }
skips() { grep -c 'PREQUEUE_SKIPPED' "$T/$1/log" 2>/dev/null; }
word() { grep "^$2 " "$T/$1/out" | tail -n1 | sed 's/^[0-9]* word=\([a-z]*\).*/\1/'; }
dump() { cat "$T/$1/out" "$T/$1/status" "$T/$1/err" 2>/dev/null | head -20; }

# expect_skip <case> <num> [desc] — the skip: proceed, no dispatch, no store, the text.
expect_skip() {
  local c="$1" n="$2" d="${3:-$SKIPPED}"
  [ "$(word "$c" "$n")" = proceed ] && ok || bad "$c the answer is proceed ($(dump "$c"))"
  [ "$(dispatches "$c")" = 0 ] && ok || bad "$c no prequeue-gate.yml dispatch (got $(dispatches "$c"))"
  [ "$(store "$c")" = 0 ] && ok || bad "$c nothing under prequeue/, no group file (got $(store "$c"))"
  grep -q "^prequeue-verdict [0-9a-f]* success $d\$" "$T/$c/status" && ok || bad "$c prequeue-verdict success '$d' ($(cat "$T/$c/status"))"
  [ "$(skips "$c")" = 1 ] && ok || bad "$c one PREQUEUE_SKIPPED line (got $(skips "$c"))"
}
# expect_gated <case> <num> — no skip: the verdict path ran (1 dispatch, hold).
expect_gated() {
  local c="$1" n="$2"
  [ "$(word "$c" "$n")" = hold ] && ok || bad "$c the answer is hold ($(dump "$c"))"
  [ "$(dispatches "$c")" = 1 ] && ok || bad "$c the verdict path dispatches once (got $(dispatches "$c"))"
  ! grep -q 'skipped' "$T/$c/status" && ok || bad "$c no skipped text ($(cat "$T/$c/status"))"
  [ "$(skips "$c")" = 0 ] && ok || bad "$c no PREQUEUE_SKIPPED line (got $(skips "$c"))"
}

# ── S0: the skip reads no knob ───────────────────────────────────────────────
! grep -Eq 'pq_knob|lane_knob' "$DIR/bin/lib/mc-prequeue.d/hotfix-skip.sh" && ok \
  || bad "S0 hotfix-skip.sh reads no knob ($(grep -nE 'pq_knob|lane_knob' "$DIR/bin/lib/mc-prequeue.d/hotfix-skip.sh"))"

# ── S1-S3, S8: the skip ──────────────────────────────────────────────────────
gate s1 '101=merge-queue,fix-main-red'; expect_skip s1 101
grep -q "$SLUG#101 PREQUEUE_SKIPPED head=1010eeeeeeee reason=" "$T/s1/log" && ok || bad "S1 the line names the head ($(cat "$T/s1/log"))"
[ "$(tr '\n' ' ' < "$T/s1/hooks")" = "restamp mignum " ] && ok || bad "S1 pq_restamp and pq_mignum still run (got '$(tr '\n' ' ' < "$T/s1/hooks")')"
grep -qx "pqskip $SLUG#101 1010eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$T/s1/attempts" && ok || bad "S1 the pqskip attempt line ($(cat "$T/s1/attempts"))"
gate s2 '102=fix-main-red'; expect_skip s2 102
gate s3 '103=fix-main-red,hotfix'; expect_skip s3 103
LABEL=custom-red gate s8 '108=merge-queue,custom-red'
expect_skip s8 108 'skipped (custom-red: the hotfix queue runs this head alone)'

# ── S4-S6b: no skip ──────────────────────────────────────────────────────────
gate s4 '104=fix-main-red-2,merge-queue'; expect_gated s4 104
gate s4b '114=Fix-Main-Red'; expect_gated s4b 114
gate s4c '124=hotfix'; expect_gated s4c 124
PROV=github gate s5 '105=fix-main-red'; expect_gated s5 105
LABEL='~' gate s6 '106=fix-main-red'; expect_gated s6 106
LABEL='~' gate s6b '116=,,'; expect_gated s6b 116

# ── S10: the eject requeue never skips ───────────────────────────────────────
VIA=ec gate s10 '110=fix-main-red'; expect_gated s10 110
grep -q '^110 .* ec=wait$' "$T/s10/out" && ok || bad "S10 ec_requeue_gate waits for the verdict ($(dump s10))"

# ── S7: the hooks still hold a skipped head ──────────────────────────────────
RS_WORD="pushed $MAIN 1" gate s7 '107=fix-main-red'
[ "$(word s7 107)" = hold ] && grep -q 'why=restamped 1 schema fragment' "$T/s7/out" && ok || bad "S7 a restamp push holds a skipped head ($(dump s7))"
[ ! -s "$T/s7/status" ] && ok || bad "S7 a hold publishes nothing ($(cat "$T/s7/status"))"
[ "$(dispatches s7)" = 0 ] && ok || bad "S7 no dispatch (got $(dispatches s7))"

# ── S7b: a red fast lint still parks a skipped head ──────────────────────────
FL_WORD="red tests/x-test.sh" gate s7b '117=fix-main-red'
[ "$(word s7b 117)" = red ] && ok || bad "S7b a red fast lint parks a skipped head ($(dump s7b))"
grep -q '^prequeue-verdict [0-9a-f]* failure ' "$T/s7b/status" && ! grep -q skipped "$T/s7b/status" && ok \
  || bad "S7b a failure status, no skipped text ($(cat "$T/s7b/status"))"

# ── S9: a second tick on the same head ───────────────────────────────────────
gate s9 '109=fix-main-red'; gate s9 '109=fix-main-red'
[ "$(grep -c '^109 word=proceed' "$T/s9/out")" = 2 ] && ok || bad "S9 both ticks proceed ($(dump s9))"
[ "$(skips s9)" = 1 ] && ok || bad "S9 one PREQUEUE_SKIPPED line over two ticks (got $(skips s9))"
[ "$(wc -l < "$T/s9/status" | tr -d ' ')" = 1 ] && ok || bad "S9 one status POST over two ticks ($(cat "$T/s9/status"))"

# ── S10b: PQ_OFF_WHY does not leak to the next PR ────────────────────────────
cache s10b '{"lane.merge-conductor.demo-off.mc_prequeue_gate":"0","lane.merge-conductor.demo-off.mc_prequeue_fallback":"0"}'
gate s10b '111=fix-main-red:demo-on' '112=~:demo-off'
grep -q "^prequeue-verdict 1110eeeeeeee success $SKIPPED\$" "$T/s10b/status" && ok || bad "S10b the labelled PR is skipped ($(cat "$T/s10b/status"))"
grep -qx 'prequeue-verdict 1120eeeeeeee success gate off' "$T/s10b/status" && ok || bad "S10b the next PR publishes 'gate off', not the skipped text ($(cat "$T/s10b/status"))"

# ── S12: the skip wins over the BH-8801 fallback ─────────────────────────────
cache s12 "{\"$GKEY\":\"0\"}"
BODY="<!-- selection-gate: head=1120eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee suites=3 rc=could-not-run -->" gate s12 '112=fix-main-red'
expect_skip s12 112
[ ! -s "$T/s12/pullreads" ] && ok || bad "S12 the skip reads no PR body ($(wc -l < "$T/s12/pullreads") reads)"
! grep -q PREQUEUE_FALLBACK "$T/s12/log" && ok || bad "S12 no PREQUEUE_FALLBACK line ($(cat "$T/s12/log"))"
# The control: the same head with no label falls back (the body is read).
cache s12c "{\"$GKEY\":\"0\"}"
BODY="<!-- selection-gate: head=1120eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee suites=3 rc=could-not-run -->" gate s12c '112=merge-queue'
grep -q 'PREQUEUE_FALLBACK .* gate-record=could-not-run' "$T/s12c/log" && ok || bad "S12 control: no label, the fallback runs ($(cat "$T/s12c/log"))"

# ── S11: bin/merge-conductor.sh whole, the READY arm (D2) ────────────────────
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
H="$T/c11/h"; FB="$T/c11/fakebin"; K41="$SLUG#41"; H41=$(printf 'a%.0s' $(seq 40)); U="https://github.com/$SLUG/pull"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" "$FB"
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\nto_lead_merge_hold() { return 1; }\n' > "$H/bin/lib/ticket-ownership.sh"
# The conductor's whole closure: main-red-gate.sh (MC_MAIN_RED_LABEL), every
# pre-queue hook (hotfix-skip.sh, status.sh, dispatch.sh ...). A cached red
# for (41, head, main) is what parks an unlabelled row.
printf 'bg_enforce() { return 0; }\nbg_scan_read() { return 0; }\nbg_scan() { return 0; }\nbg_why() { :; }\nbg_reason() { :; }\nbg_refuse() { return 0; }\n' > "$H/bin/lib/block-gate.sh"
: > "$H/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_rm "$H/bin/lib/gh-limit-logger.sh"
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/logs/ALERTS.log"\n' "$H" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/" || exit 1
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$FB/flock"; chmod +x "$FB/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s.sh"; chmod +x "$H/bin/$s.sh"; done
REC="$H/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
echo "PR_CREATED $U/41" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H41" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cp "$DIR/tests/lib/rest-emit.sh" "$FB/restpr"; chmod +x "$FB/restpr"
: > "$T/c11/enq"; : > "$T/c11/dispatch"
cat > "$FB/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 '{"sha":"$MAIN"}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c11/enq"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c11/enq" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c11/enq" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c11/enq"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c11/enq"; restpr --raw 200 '{"merged":true}' ;;
  *"workflow run prequeue-gate.yml"*|*"prequeue-gate.yml/dispatches"*) printf '%s\n' "\$*" >> "$T/c11/dispatch" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "$H41" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/c11/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$FB/gh"
cat > "$FB/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$FB/curl"
MCD="$H/state/merge-conductor"
# tick11 <labels-json> — a fresh state, a red verdict cached for (41, head,
#   main), one whole conductor run. Prints the row's state.
tick11() {
  scratch_rm "$MCD"; scratch_rm "$H/state/tier2-autoenqueue.txt"; rm -f "$H/logs/"*.log; mkdir -p "$MCD"; : > "$MCD/pr-state.tsv"
  : > "$T/c11/enq"; : > "$T/c11/dispatch"
  printf '[{"number":41,"url":"%s/41","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s}]\n' \
    "$U" "$H41" "$1" > "$T/c11/list.json"
  touch "$H/flags/merge-conductor-actions" "$H/flags/merge-conductor-merge"
  ( MC_STATE_DIR="$MCD" P=demo; . "$H/bin/lib/mc-prequeue.sh" || exit 1
    pq_cache_put "$(pq_key "$SLUG" 41 "$H41" "$MAIN")" red 1759626000 - tests/a.sh ) || bad "S11 fixture: pq_cache_put"
  ( cd "$T/c11" && env PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 bash "$H/bin/merge-conductor.sh" >/dev/null 2>"$T/c11/tick.err" ) || true
  awk -F'\t' -v k="$K41" '$1==k {print $2}' "$MCD/pr-state.tsv"
}
enq11() { grep -c "issues/41/comments\|issues/41/labels\|pulls/41/merge\|pr merge $U/41" "$T/c11/enq" 2>/dev/null || true; }
# The control: no label, the cached red parks the row and nothing is enqueued.
st=$(tick11 '[]')
[ "$st" = BLOCKED_HUMAN ] && [ "$(enq11)" = 0 ] && ok || bad "S11 control: an unlabelled row with a cached red parks, not enqueued (state '$st'; $(cat "$T/c11/enq"); $(tail -3 "$T/c11/tick.err"))"
! grep -q PREQUEUE_SKIPPED "$H/logs/merge-conductor.log" 2>/dev/null && ok || bad "S11 control: no PREQUEUE_SKIPPED line"
st=$(tick11 '[{"name":"merge-queue"},{"name":"fix-main-red"}]')
[ "$(enq11)" -ge 1 ] && ok || bad "S11 a fix-main-red READY row is enqueued on the same tick (state '$st'; enq: $(cat "$T/c11/enq"); log: $(grep -F "$K41" "$H/logs/merge-conductor.log" 2>/dev/null | tail -5); err: $(tail -3 "$T/c11/tick.err"))"
grep -q "$K41 PREQUEUE_SKIPPED head=${H41:0:12}" "$H/logs/merge-conductor.log" 2>/dev/null && ok || bad "S11 one PREQUEUE_SKIPPED line ($(grep -F PREQUEUE "$H/logs/merge-conductor.log" 2>/dev/null | tail -3))"
[ ! -s "$T/c11/dispatch" ] && ok || bad "S11 no prequeue-gate.yml dispatch ($(cat "$T/c11/dispatch"))"
[ -z "$(find "$MCD/prequeue" -name '*group*' 2>/dev/null)" ] && ok || bad "S11 no pre-queue group file"

echo "prequeue-hotfix-skip.bh-8769: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

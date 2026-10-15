#!/bin/bash
# tests/mc-step-held.bh-6670-test.sh — BH-6670: the merge-conductor head-lag
# span is split into named sub-steps, and a step timeout in a read-only
# sub-step is a held result, not a page.
#
# Sentry CROMFORD-HARNESS-Q: 6 conductor-step-timeout events, step head-lag,
# project project-6-os. One `head-lag` step covered six sub-calls, so the event
# could not name the slow one, and every first stall paged (alert + Sentry).
#
#   E1  the real bin/merge-conductor.sh tick: the head-lag branch read stalls
#       past MC_STEP_TIMEOUT_S=4. One STEP_HELD step=head-lag line, hold 1 of
#       2, 0 STEP_TIMEOUT, 0 lane alerts, 0 conductor-step-timeout events, the
#       tally counts killed:slow-read, the row is unchanged; a second tick with
#       no stall works the PR with no STEP_HELD
#   P1  a real tick killed at its deadline in ci-read: the `earlier:` list
#       names lane-epoch, head-lag, handoff-sticky and park-holds with seconds
#   P2  a real tick whose head-lag read takes 2 s with MC_STEP_SLOW_S=1: a
#       STEP_END step=head-lag took=<n>s line; MC_STEP_LOG=1 through mc_step:
#       one STEP_END per sub-step, in order
#   H1  mc_fanin_outcome, head-lag, holds 0, max 2: held, the mark and .calls
#       gone, one stephold line
#   H2  the decision table: lane-epoch hold 2 of 2, park-holds with max 1; the
#       write and other steps page; a deadline kill in head-lag is unchanged
#   H3  three kills on one head (file ledger): hold 1, hold 2, then one page
#   H4  a new head starts at hold 1
#   H5  MC_STEP_HOLD_MAX=0 pages at hold 0
#   H6  MC_STEP_HOLD_MAX=abc reads as 2
#   S1  a STEP_TIMEOUT in dep-gate: Sentry tags pr, worker_key, step; title
#       and log line unchanged
#   K1  the catalog knob fragment matches the code default
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-step-held.bh-6670-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s)
hd() { printf '%02d%038d' "$1" 0; }

# ============================================================================
# H/S — mc_fanin_outcome on the repo's own fanin.sh and the real file ledger
# of bin/lib/mc/locks.sh (no pr_rows_on: the attempts.txt half only).
# ============================================================================
UL="$T/u"; mkdir -p "$UL/hh/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$UL" > "$UL/hh/bin/lane-alert.sh"; chmod +x "$UL/hh/bin/lane-alert.sh"
: > "$UL/alerts"
ROW() { printf '%s\tx\t%s\tb\tfalse\tCLEAN' "$1" "${2:-$(hd "$1")}"; }

# hand <case> <pr> <step> <kind> <ledger> [head] [env...] — a hand-written
# 7-field mark (the shape mc_worker_bounded writes), a .calls file, then the
# outcome. The ledger file is shared by the calls that name it.
hand() { local c="$1" n="$2" step="$3" kind="$4" led="$5" head="${6:-}"; shift 6 2>/dev/null || shift $#
  mkdir -p "$UL/$c" "$UL/state/worker-deadline"; touch "$led"
  ( [ $# -gt 0 ] && export "$@"
    SLUG=example-org/demo MC_STATE_DIR="$UL/state" MC_TICK_ID=t6670 MC_FANIN_T0=0 HARNESS="$UL/hh" MC_H="$UL/hh"
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/locks.sh"
    MC_ATTEMPTS="$led"
    unset -f pr_rows_on 2>/dev/null
    mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
    eval "mc_log() { printf '%s\n' \"\$*\" >> '$UL/$c/log'; }"
    mc_row_field() { echo READY; }
    eval "sentry_report() { printf '%s\n' \"\$@\" >> '$UL/$c/sentry'; echo ---- >> '$UL/$c/sentry'; }"
    m=$(_mc_deadline_mark "example-org/demo#$n")
    printf '30\t%s\t%s\t5\tstart=0s\t%s\t4\n' "$step" "$step" "$kind" > "$m"
    printf '%s\tgh\tGET repos/o/r/branches/x\t5000\t200\n' "$step" > "$m.calls"
    echo "word=$(mc_fanin_outcome 0 "$(ROW "$n" "$head")")"
    [ -e "$m" ] && echo "mark-after=y" || echo "mark-after=n"
    [ -e "$m.calls" ] && echo "calls-after=y" || echo "calls-after=n"
  ) >> "$UL/$c/out" 2>&1; }
word() { grep '^word=' "$UL/$1/out" | sed -n "${2:-1}p" | cut -d= -f2-; }
nlines() { grep -c "$2" "$UL/$1/log" 2>/dev/null || true; }
nalerts() { grep -c "$1" "$UL/alerts" 2>/dev/null || true; }
nsentry() { grep -c '^conductor-step-timeout$' "$UL/$1/sentry" 2>/dev/null || true; }
H81=$(hd 81)

# H1 — head-lag, no hold yet, default max (2).
: > "$UL/alerts"
hand h1 81 head-lag step-timeout "$UL/h1.att"
[ "$(word h1)" = killed:slow-read ] && ok || bad "H1 the outcome is killed:slow-read ($(cat "$UL/h1/out"))"
HL=$(grep 'STEP_HELD' "$UL/h1/log" 2>/dev/null)
[ "$(grep -c . <<<"$HL")" = 1 ] && [ -n "$HL" ] && ok || bad "H1 one STEP_HELD line ($(cat "$UL/h1/log" 2>/dev/null))"
[[ "$HL" == "example-org/demo#81 STEP_HELD step=head-lag after 5s on ${H81:0:8} (step timeout 4s, hold 1 of 2): a read-only step ran slow; worker stopped, row left READY, the next tick works it again | calls: "* ]] \
  && ok || bad "H1 the STEP_HELD line format ($HL)"
[ "$(nlines h1 STEP_TIMEOUT)" = 0 ] && [ "$(nalerts .)" = 0 ] && [ ! -e "$UL/h1/sentry" ] && ok || bad "H1 no STEP_TIMEOUT, no alert, no Sentry ($(cat "$UL/h1/log" "$UL/alerts" "$UL/h1/sentry" 2>/dev/null))"
grep -qx 'mark-after=n' "$UL/h1/out" && grep -qx 'calls-after=n' "$UL/h1/out" && ok || bad "H1 the mark and .calls are removed ($(cat "$UL/h1/out"))"
[ "$(cat "$UL/h1.att")" = "stephold example-org/demo#81 $H81 head-lag" ] && ok || bad "H1 exactly one stephold line in the ledger ($(cat "$UL/h1.att"))"

# H2 — the decision table.
# lane-epoch with one hold already: held, hold 2 of 2.
printf 'stephold example-org/demo#82 %s lane-epoch\n' "$(hd 82)" > "$UL/h2a.att"
hand h2a 82 lane-epoch step-timeout "$UL/h2a.att"
[ "$(word h2a)" = killed:slow-read ] && grep -q 'STEP_HELD step=lane-epoch .*hold 2 of 2)' "$UL/h2a/log" 2>/dev/null \
  && ok || bad "H2 lane-epoch, holds 1, max 2: held, hold 2 of 2 ($(cat "$UL/h2a/out" "$UL/h2a/log" 2>/dev/null))"
# park-holds with max 1, no hold yet: held, hold 1 of 1.
hand h2b 83 park-holds step-timeout "$UL/h2b.att" "" MC_STEP_HOLD_MAX=1
[ "$(word h2b)" = killed:slow-read ] && grep -q 'STEP_HELD step=park-holds .*hold 1 of 1)' "$UL/h2b/log" 2>/dev/null \
  && ok || bad "H2 park-holds, holds 0, max 1: held ($(cat "$UL/h2b/out" "$UL/h2b/log" 2>/dev/null))"
# Steps that page at hold 0: a write in flight, or not a read-only step.
i=84
for s in head-lag-kick handoff-sticky dep-gate enqueue merge lock-probe verdict-read; do
  : > "$UL/alerts"
  hand "h2-$s" "$i" "$s" step-timeout "$UL/h2-$s.att"
  [ "$(word "h2-$s")" = killed:step-timeout ] && [ "$(nlines "h2-$s" STEP_HELD)" = 0 ] \
    && [ "$(nlines "h2-$s" "STEP_TIMEOUT step=$s ")" = 1 ] && [ "$(nalerts "STEP_TIMEOUT example-org/demo#$i")" = 1 ] && [ "$(nsentry "h2-$s")" = 1 ] \
    && ok || bad "H2 step $s pages: STEP_TIMEOUT line, one alert, one event ($(cat "$UL/h2-$s/out" "$UL/h2-$s/log" 2>/dev/null))"
  ! grep -q '^stephold ' "$UL/h2-$s.att" && ok || bad "H2 step $s writes no stephold line ($(cat "$UL/h2-$s.att"))"
  i=$((i + 1))
done
# A deadline kill in head-lag: WORKER_DEADLINE, as today.
hand h2d 95 head-lag deadline "$UL/h2d.att"
[ "$(word h2d)" = killed:deadline ] && [ "$(nlines h2d STEP_HELD)" = 0 ] && [ "$(nlines h2d WORKER_DEADLINE)" = 1 ] \
  && ok || bad "H2 a deadline kill in head-lag is killed:deadline, no hold ($(cat "$UL/h2d/out" "$UL/h2d/log" 2>/dev/null))"

# H3 — three kills on one head, one ledger: hold 1, hold 2, then a page.
: > "$UL/alerts"
for k in 1 2 3; do hand h3 81 head-lag step-timeout "$UL/h3.att"; done
[ "$(word h3 1)|$(word h3 2)|$(word h3 3)" = 'killed:slow-read|killed:slow-read|killed:step-timeout' ] \
  && ok || bad "H3 the words are slow-read, slow-read, step-timeout ($(grep '^word=' "$UL/h3/out" | tr '\n' ' '))"
grep 'STEP_HELD' "$UL/h3/log" 2>/dev/null | sed -n 1p | grep -q 'hold 1 of 2)' && grep 'STEP_HELD' "$UL/h3/log" 2>/dev/null | sed -n 2p | grep -q 'hold 2 of 2)' \
  && [ "$(nlines h3 STEP_HELD)" = 2 ] && ok || bad "H3 two STEP_HELD lines, hold 1 of 2 then 2 of 2 ($(cat "$UL/h3/log" 2>/dev/null))"
[ "$(nlines h3 'STEP_TIMEOUT step=head-lag ')" = 1 ] && [ "$(nalerts 'STEP_TIMEOUT example-org/demo#81')" = 1 ] && [ "$(nsentry h3)" = 1 ] \
  && ok || bad "H3 the third kill pages once: line, alert, event ($(cat "$UL/h3/log" "$UL/alerts" 2>/dev/null))"
[ "$(grep -c "^stephold example-org/demo#81 $H81 head-lag\$" "$UL/h3.att")" = 2 ] && [ "$(grep -c "^steptimeout example-org/demo#81 $H81 head-lag\$" "$UL/h3.att")" = 1 ] \
  && ok || bad "H3 the ledger holds 2 stephold lines and 1 steptimeout line ($(cat "$UL/h3.att"))"

# H4 — a new head on the same ledger starts at hold 1.
hand h4 81 head-lag step-timeout "$UL/h3.att" "$(hd 99)"
[ "$(word h4)" = killed:slow-read ] && grep -q "on $(hd 99 | cut -c1-8) .*hold 1 of 2)" "$UL/h4/log" 2>/dev/null \
  && ok || bad "H4 a new head is held at hold 1 of 2 ($(cat "$UL/h4/out" "$UL/h4/log" 2>/dev/null))"

# H5 — MC_STEP_HOLD_MAX=0: off, the first stall pages.
hand h5 96 head-lag step-timeout "$UL/h5.att" "" MC_STEP_HOLD_MAX=0
[ "$(word h5)" = killed:step-timeout ] && [ "$(nlines h5 STEP_HELD)" = 0 ] && [ "$(nsentry h5)" = 1 ] \
  && ok || bad "H5 MC_STEP_HOLD_MAX=0 pages at hold 0 ($(cat "$UL/h5/out" "$UL/h5/log" 2>/dev/null))"

# H6 — MC_STEP_HOLD_MAX=abc reads as 2.
hand h6a 97 head-lag step-timeout "$UL/h6a.att" "" MC_STEP_HOLD_MAX=abc
[ "$(word h6a)" = killed:slow-read ] && grep -q 'hold 1 of 2)' "$UL/h6a/log" 2>/dev/null && ok || bad "H6 abc, holds 0: held, of 2 ($(cat "$UL/h6a/out" "$UL/h6a/log" 2>/dev/null))"
printf 'stephold example-org/demo#98 %s head-lag\nstephold example-org/demo#98 %s head-lag\n' "$(hd 98)" "$(hd 98)" > "$UL/h6b.att"
hand h6b 98 head-lag step-timeout "$UL/h6b.att" "" MC_STEP_HOLD_MAX=abc
[ "$(word h6b)" = killed:step-timeout ] && [ "$(nsentry h6b)" = 1 ] && ok || bad "H6 abc, holds 2: pages ($(cat "$UL/h6b/out" "$UL/h6b/log" 2>/dev/null))"

# S1 — a STEP_TIMEOUT in dep-gate: the tags name the PR.
hand s1 81 dep-gate step-timeout "$UL/s1.att"
SL=$(grep 'STEP_TIMEOUT' "$UL/s1/log" 2>/dev/null)
[[ "$SL" == "example-org/demo#81 STEP_TIMEOUT step=dep-gate after 5s on ${H81:0:8} "* ]] && ok || bad "S1 the log line has <slug>#81 and the head8 ($SL)"
[ "$(sed -n 4p "$UL/s1/sentry" 2>/dev/null)" = "STEP_TIMEOUT: step dep-gate passed 4s on ${H81:0:8}" ] && ok || bad "S1 the title is unchanged ($(sed -n 4p "$UL/s1/sentry" 2>/dev/null))"
TG=$(sed -n 6p "$UL/s1/sentry" 2>/dev/null)
[ "$(jq -r '.pr' <<<"$TG" 2>/dev/null)|$(jq -r '.worker_key' <<<"$TG" 2>/dev/null)|$(jq -r '.step' <<<"$TG" 2>/dev/null)" = '81|example-org/demo#81|dep-gate' ] \
  && ok || bad "S1 the 6th argument is the tags: pr, worker_key, step ($TG)"
[ "$(sed -n 5p "$UL/s1/sentry" 2>/dev/null | jq -r '.tags.step' 2>/dev/null)" = dep-gate ] && ok || bad "S1 extra.tags.step is kept ($(sed -n 5p "$UL/s1/sentry" 2>/dev/null))"

# K1 — the knob fragment.
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_STEP_HOLD_MAX.json"
[ "$(jq -r '.env, .default, .min, .read_in' "$KF" 2>/dev/null | tr '\n' ' ')" = 'MC_STEP_HOLD_MAX 2 0 bin/lib/fanin.sh ' ] && ok || bad "K1 the knob fragment: env, default 2, min 0, read_in ($(cat "$KF" 2>/dev/null))"

# ============================================================================
# E1, P1, P2 — the real conductor, one PR, gh/curl stubbed.
# ============================================================================
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$F" > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
REC="$F/h/builds/pool-demo-BH-1-202610140001"; mkdir -p "$REC"
echo "PR_CREATED $U/1" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
hd 1 > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
jq -nc --arg s "$SLUG" --arg h "$(hd 1)" '[{number:1, html_url:("https://github.com/"+$s+"/pull/1"),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-14T00:00:00Z", head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$F/open.json"
# The gh stub. Every call is logged. The matching-refs read answers no ref, so
# the head-lag tip is the branches/ read: $F/tipstall holds its sleep seconds.
# $F/cistall holds the check-runs read's sleep seconds (step ci-read).
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
HEADN=\$(printf '%02d%038d' 1 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/branches/"*) [ -s "$F/tipstall" ] && sleep "\$(cat "$F/tipstall")"   # determinism: ok the stub IS the slow read under test
    restpr --raw 200 '{"name":"ticket/bh-1","commit":{"sha":"'"\$HEADN"'"}}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) [ -s "$F/cistall" ] && sleep "\$(cat "$F/cistall")"   # determinism: ok the stub IS the stall the deadline kills
    restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) [ -s "$F/cistall" ] && sleep "\$(cat "$F/cistall")"   # determinism: ok the stub IS the stall the deadline kills
    restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$HEADN" "ticket/bh-1" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
cat > "$F/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$URL" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;; esac
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$F/fakebin/curl"
# TEST-CHANGE BH-4148: the lead reads protected paths from the jobs route; the demo
# repo has no rows, so it is not governed, as under the old catalog file.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" "$SLUG"
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
# The Sentry curl: keeps each envelope it is handed, answers 200.
cat > "$F/fakebin/sentry-curl" <<EOF
#!/bin/bash
cat > /dev/null
f=""; while [ \$# -gt 0 ]; do case "\$1" in --data-binary) f="\${2#@}"; shift 2 ;; *) shift ;; esac; done
k=\$(ls "$F"/sentry-env-*.txt 2>/dev/null | wc -l)
[ -n "\$f" ] && cp "\$f" "$F/sentry-env-\$k.txt"
printf 200
EOF
chmod +x "$F/fakebin/sentry-curl"
touch "$F/h/flags/merge-conductor-actions" "$F/h/flags/merge-conductor-merge" "$F/h/flags/conductor-owns-merges"
CLOG="$F/h/logs/merge-conductor.log"
ROWS="$F/h/state/merge-conductor/pr-state.tsv"
ROW1=$(printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s' "$SLUG#1" WAIT_CI $((NOW-600)) "$(hd 1)" "$(hd 1)" "$U" 1)
# fresh — a clean state dir with the one row, no stalls, empty call logs.
fresh() { scratch_rm "$F/h/state"; mkdir -p "$F/h/state/merge-conductor"; printf '%s\n' "$ROW1" > "$ROWS"
  rm -f "$F/tipstall" "$F/cistall" "$F"/sentry-env-*.txt; : > "$F/c-calls.txt"; : > "$F/c-alerts.txt"; touch "$F/c-writes.txt"; }
# tick [env...] — one real conductor tick.
tick() { ( unset -f gh; cd "$F" && env -u MC_STEP_HOLD_MAX PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator \
  HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 HARNESS_SENTRY_CURL="$F/fakebin/sentry-curl" \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_STEP_POLL_S=1 \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 \
  "$@" bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }
events() { local f; for f in "$F"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done | jq -c "select(.tags.reason == \"$1\")" 2>/dev/null; }

# E1 — the head-lag branch read stalls 60 s; the step timeout is 4 s.
fresh; echo 60 > "$F/tipstall"
M0=$(loglen); S0=$SECONDS
tick MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=4
E1_S=$((SECONDS - S0))
[ "$E1_S" -lt 30 ] && ok || bad "E1 the tick ends in under 30 s (took ${E1_S}s)"
grep -q "GET repos/$SLUG/branches/ticket/bh-1" "$F/c-calls.txt" && ok || bad "E1 setup: the head-lag tip read is the branches/ read ($(cat "$F/c-calls.txt"))"
HL=$(since "$M0" | grep -F "$SLUG#1 STEP_HELD step=head-lag ")
[ "$(grep -c . <<<"$HL")" = 1 ] && [ -n "$HL" ] && ok || bad "E1 one STEP_HELD step=head-lag line (log: $(since "$M0" | grep -F "$SLUG#1" | tail -5))"
grep -Eq "after [4-9]s on $(hd 1 | cut -c1-8) \(step timeout 4s, hold 1 of 2\): a read-only step ran slow; worker stopped, row left WAIT_CI, the next tick works it again \| calls: .+$" <<<"$HL" \
  && ok || bad "E1 the STEP_HELD line names the timeout, the hold and the row ($HL)"
! grep -q 'STEP_TIMEOUT' <<<"$(since "$M0")" && ok || bad "E1 no STEP_TIMEOUT line ($(since "$M0" | grep STEP_TIMEOUT))"
[ ! -s "$F/c-alerts.txt" ] && ok || bad "E1 no lane alert ($(cat "$F/c-alerts.txt"))"
[ -z "$(events conductor-step-timeout)" ] && ok || bad "E1 no conductor-step-timeout event ($(events conductor-step-timeout))"
grep -Eq 'killed:slow-read( rc=[0-9]+)? 1(,|\))' <<<"$(tally "$M0")" && ok || bad "E1 the tally counts one killed:slow-read ($(tally "$M0"))"
[ "$(cut -f2 "$ROWS")" = WAIT_CI ] && [ "$(cut -f4 "$ROWS")" = "$(hd 1)" ] && ok || bad "E1 the row is unchanged in pr-state.tsv ($(cat "$ROWS"))"
# The second tick: no stall, the PR is worked.
rm -f "$F/tipstall"; M1=$(loglen)
tick MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=4
! grep -qE 'STEP_HELD|STEP_TIMEOUT|WORKER_DEADLINE' <<<"$(since "$M1")" && ok || bad "E1 the next tick: no STEP_HELD, STEP_TIMEOUT or WORKER_DEADLINE ($(since "$M1" | tail -5))"
T2=$(tally "$M1")
grep -q 'enumerated 1 accounted 1' <<<"$T2" && ! grep -q 'killed:' <<<"$T2" && ok || bad "E1 the next tick works the PR to an outcome ($T2)"

# P1 — killed at the deadline in ci-read: the earlier list names the sub-steps.
fresh; echo 60 > "$F/cistall"
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=8 MC_STEP_TIMEOUT_S=0
DL=$(since "$M0" | grep -F "$SLUG#1 WORKER_DEADLINE")
grep -q '| step: ci-read (' <<<"$DL" && ok || bad "P1 setup: the deadline fires in ci-read ($DL; $(since "$M0" | tail -3))"
EAR=$(sed -E 's/.*\| earlier: (.*) \| calls: .*/\1/' <<<"$DL")
for s in lane-epoch head-lag handoff-sticky park-holds; do
  grep -Eq "(^| )$s=[0-9]+s( |$)" <<<"$EAR" && ok || bad "P1 earlier names $s=<n>s ($EAR)"
done
grep -Eq 'lane-epoch=[0-9]+s head-lag=[0-9]+s handoff-sticky=[0-9]+s park-holds=[0-9]+s verdict-read=' <<<"$EAR" && ok || bad "P1 the sub-steps are in order, before verdict-read ($EAR)"

# P2 — a 2 s head-lag read with MC_STEP_SLOW_S=1: its own STEP_END line.
fresh; echo 2 > "$F/tipstall"
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=20 MC_STEP_SLOW_S=1
since "$M0" | grep -Eq "$SLUG#1 STEP_END step=head-lag took=[2-9]s( started=.*)?$" && ok || bad "P2 a slow head-lag sub-step logs its STEP_END ($(since "$M0" | grep STEP_ | tail -5))"
! grep -qE 'STEP_HELD|STEP_TIMEOUT' <<<"$(since "$M0")" && ok || bad "P2 a read under the step timeout is not held ($(since "$M0" | grep -E 'STEP_HELD|STEP_TIMEOUT'))"
# MC_STEP_LOG=1 through mc_step: one STEP_END per sub-step, in order.
( . "$DIR/bin/lib/fanin.sh"
  KEY="$SLUG#2"; mc_log() { printf '%s\n' "$*" >> "$UL/p2.log"; }; unset GH_REST_AUTH_FAIL_FILE
  MC_STEP_FILE="$UL/p2.steps"; : > "$MC_STEP_FILE"; MC_STEP_LOG=1
  mc_step lane-epoch; mc_step head-lag; mc_step handoff-sticky; mc_step park-holds; mc_step verdict-read
) > /dev/null 2>&1
[ "$(grep STEP_END "$UL/p2.log" 2>/dev/null | sed -E 's/took=[0-9]+s/took=Ns/' | tr '\n' '|')" = \
  "$SLUG#2 STEP_END step=lane-epoch took=Ns|$SLUG#2 STEP_END step=head-lag took=Ns|$SLUG#2 STEP_END step=handoff-sticky took=Ns|$SLUG#2 STEP_END step=park-holds took=Ns|" ] \
  && ok || bad "P2 MC_STEP_LOG=1: one STEP_END per sub-step, in order ($(cat "$UL/p2.log" 2>/dev/null))"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-step-held.bh-6670: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

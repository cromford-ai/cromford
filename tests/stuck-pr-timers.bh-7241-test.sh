#!/bin/bash
# tests/stuck-pr-timers.bh-7241-test.sh — BH-7241: a timer on three stuck PR
# states, so no state waits on a person.
#
# THE IDLE TIME THIS KILLS (project-6, 2026-10-17). #930 waited 8.7 h with no
# workflow run on its head. #990's rebase failed and the PR sat 2 h before it
# reached a person. #991 stayed red for 1.5 h. the operator cleared all three by hand.
#
#   A  CI never started: a head with no run for MC_CI_NOSTART_MIN minutes gets
#      ONE workflow_dispatch of a workflow that declares pull_request AND
#      workflow_dispatch, and ONE alert. Never an empty commit.
#   B  A failed rebase or main merge (conflict-unresolvable, rebase-gate-red)
#      starts bin/blocked-resolver.sh for that PR in the same tick.
#   C  Red on two consecutive heads: RED_TWICE at once (no second rerun rung),
#      with the failing check names, and the resolver starts in the same tick.
#   D  One alert per stuck PR per state.
#   K  The knobs and the kill switch (MC_STUCK_TIMERS=0 is today's path).
#   R  The writer/reader round-trips.
#
# A, B1/B2, C and D drive the real bin/merge-conductor.sh in a scratch tree
# against a stub gh. B3-B8, C9, C10, K and R call the lib functions directly.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/stuck-pr-timers.bh-7241-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-stuck-timers.sh" ] || bad "setup: bin/lib/mc-stuck-timers.sh is missing"   # impact: bin/lib/mc-stuck-timers.sh bin/merge-conductor.sh bin/lib/mc/settle.sh bin/lib/mc/classify.sh bin/blocked-resolver.sh
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
NOW=$(date -u +%s)
SLUG=example-org/demo-os
P=demo-os
hx() { printf '%-40s' "$1" | tr ' ' 0; }   # a 40-hex head from a short hex prefix

# ── the scratch harness: the conductor's whole closure, three files stubbed ──
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin"
# The flake ledger, stubbed: the failed runs of a head are $T/failed.<head>
# (`id|path|name|sha` lines); every failure is a known flake while $T/allknown
# exists.
cat > "$T/h/bin/lib/flaky.sh" <<EOF
flaky_failed_runs() { cat "$T/failed.\$2" 2>/dev/null; }
flaky_run_tests() { echo "test_\$2"; }
flaky_all_known() { cat >/dev/null; [ -e "$T/allknown" ]; }
EOF
: > "$T/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
[ -f "$T/h/bin/lib/mc-stuck-timers.sh" ] || bad "setup: the conductor's closure must carry bin/lib/mc-stuck-timers.sh (the source line in bin/merge-conductor.sh)"
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
for s in agent-call beat codegraph-ensure deploy-request pre-arm-guards; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
# The resolver, faked: it records its project and BR_ONLY_PR, one line a launch.
printf '#!/bin/bash\necho "launch p=$1 only=${BR_ONLY_PR:-}" >> "%s/launch.txt"\n' "$T" > "$T/h/bin/blocked-resolver.sh"
chmod +x "$T/h/bin/blocked-resolver.sh"
printf '%s %s - - 2 box-demo\n' "$P" "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"

# ── the stub gh ─────────────────────────────────────────────────────────────
#   $T/list.json            the open PRs (GraphQL shape; the bridge serves REST)
#   $T/runs.<head>          that head's workflow runs (`status|conclusion|id|name`)
#   $T/wf/<branch>/<file>   a workflow file at that branch, else $T/wf/default/<file>
#   $T/wf.fail              the workflows list answers 500
#   $T/dispatch.<branch>    the HTTP status the dispatch POST answers (default 204)
#   $T/checks.<head>        that head's check-runs JSON; absent = 500
# Every write lands in $T/writes.txt.
mkdir -p "$T/wf/default"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
T="$T"; SLUG="$SLUG"
printf '%s\n' "\$*" >> "\$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo tok-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr list -R \$SLUG --state open"*) cat "\$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*)
    h=\$(printf '%s' "\$*" | sed -n 's/.*head_sha=\([0-9a-f]*\).*/\1/p')
    if [ -s "\$T/runs.\$h" ]; then restpr --runs - < "\$T/runs.\$h"; else restpr --runs; fi ;;
  *"-X POST repos/\$SLUG/actions/workflows/"*"/dispatches"*)
    printf '%s\n' "\$*" >> "\$T/writes.txt"
    br=\$(printf '%s' "\$*" | sed -n 's/.*ref=\([^ ]*\).*/\1/p'); st=\$(cat "\$T/dispatch.\${br//\//_}" 2>/dev/null || echo 204)
    restpr --raw "\$st" ;;
  *"-X GET repos/\$SLUG/actions/workflows"|*"-X GET repos/\$SLUG/actions/workflows?"*)
    [ -e "\$T/wf.fail" ] && { restpr --raw 500 '{"message":"fixture"}'; exit 0; }
    restpr --raw 200 "\$(cd "\$T/wf/default" && ls | jq -R -s -c '{total_count:0,workflows:[split("\n")[]|select(length>0)|{path:(".github/workflows/"+.),state:"active"}]}')" ;;
  *"-X GET repos/\$SLUG/contents/.github/workflows/"*)
    f=\$(printf '%s' "\$*" | sed -n 's|.*contents/.github/workflows/\([^?]*\)?ref=\([^ ]*\).*|\1|p')
    br=\$(printf '%s' "\$*" | sed -n 's|.*?ref=\([^ ]*\).*|\1|p' | sed 's/%2F/\//g')
    src="\$T/wf/\${br//\//_}/\$f"; [ -f "\$src" ] || src="\$T/wf/default/\$f"
    [ -f "\$src" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
    restpr --raw 200 "\$(jq -nc --arg c "\$(base64 -w0 < "\$src")" '{content:\$c,encoding:"base64"}')" ;;
  *"-X GET repos/\$SLUG/commits/"*"/check-runs"*)
    echo checkruns >> "\$T/checkrun-reads.txt"
    h=\$(printf '%s' "\$*" | sed -n 's|.*commits/\([0-9a-f]*\)/check-runs.*|\1|p')
    if [ -s "\$T/checks.\$h" ]; then restpr --raw 200 "\$(cat "\$T/checks.\$h")"; else restpr --raw 500 '{"message":"fixture"}'; fi ;;
  *"-X GET repos/\$SLUG/pulls/"*)
    [ "\${HPL_READ_ROLE:-}" = list-lazy ] && exit 0
    n=\$(printf '%s' "\$*" | sed -n 's|.*/pulls/\([0-9]*\).*|\1|p')
    hd=\$(jq -r --argjson n "\$n" '.[]|select(.number==\$n)|.headRefOid' "\$T/list.json")
    restpr OPEN "\$hd" "ticket/pb-\$n" main "" MERGEABLE CLEAN operator ;;
  *"run rerun"*) printf '%s\n' "\$*" >> "\$T/writes.txt"; printf '%s\n' "\$*" >> "\$T/reruns.txt"; exit 0 ;;
  *"api -X PATCH repos/"*) printf '%s\n' "\$*" >> "\$T/writes.txt"; printf '%s\n' "\$*" >> "\$T/patches.txt"; exit 0 ;;
  *"commit --allow-empty"*|*"git push"*) printf '%s\n' "\$*" >> "\$T/writes.txt"; exit 0 ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
: > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/launch.txt"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"; touch "$A"
ALOG="$T/h/logs/ALERTS.log"; touch "$ALOG"
CLOG="$T/h/logs/merge-conductor.log"
RCD="$T/h/state/merge-conductor/red-checks"

mkrec() { # mkrec <num> <reviewed-sha>
  local d="$T/h/builds/pool-demo-os-TK-$1-202610170$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
}
list_row() { # list_row <num> <head> <mergeState> <mergeable>
  printf '{"number":%s,"url":"https://github.com/%s/pull/%s","headRefOid":"%s","headRefName":"ticket/pb-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","labels":[],"baseRefName":"main"}' \
    "$1" "$SLUG" "$1" "$2" "$1" "$3" "$4"
}
set_list() { local IFS=,; printf '[%s]' "$*" > "$T/list.json"; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_KICK_REOPEN_SLEEP=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
K() { printf '%s#%s' "$SLUG" "$1"; }
U() { printf 'https://github.com/%s/pull/%s' "$SLUG" "$1"; }
# wait_launch <pattern> — the resolver launch is detached; give it 5 s.
wait_launch() { local i; for i in $(seq 1 50); do grep -q -- "$1" "$T/launch.txt" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
nalert() { grep -c -- "$1" "$ALOG" 2>/dev/null || true; }
# said <pr-num> <text> — rc 0 when that PR's CI_NEVER_STARTED alert carries <text>.
said() { local l; l=$(grep -F -- "$(K "$1") CI_NEVER_STARTED" "$ALOG" 2>/dev/null); case "$l" in *"$2"*) return 0 ;; esac; return 1; }

# The workflows of the repo: ci.yml runs on pull_request and can be dispatched;
# deploy-worker.yml can be dispatched and runs on push only.
printf 'name: ci\non:\n  pull_request:\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {}\n' > "$T/wf/default/ci.yml"
printf 'name: deploy\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {}\n' > "$T/wf/default/deploy-worker.yml"
touch "$T/h/flags/merge-conductor-actions"

# ============================================================================
# A. CI never started
# ============================================================================
HA1=$(hx a1); HA3=$(hx a3); HA4=$(hx a4); HA5=$(hx a5); HA6=$(hx a6); HA7=$(hx a7); HA8=$(hx a8)
mkrec 10 "$HA1"; mkrec 11 "$HA3"; mkrec 12 "$HA4"; mkrec 13 "$HA5"; mkrec 14 "$HA6"; mkrec 15 "$HA7"; mkrec 16 "$HA8"
echo "cinone $(K 10) $HA1 $((NOW-960))" >> "$A"     # A1: 16 min with no run
echo "cinone $(K 11) $HA3 $((NOW-840))" >> "$A"     # A3: 14 min
echo "cinone $(K 12) $HA4 $((NOW-960))" >> "$A"     # A4: DIRTY
echo "cinone $(K 13) $HA5 $((NOW-960))" >> "$A"     # A5: cancelled-only runs
echo "cinone $(K 14) $HA6 $((NOW-960))" >> "$A"     # A6: already kicked
echo "cikick $(K 14) $HA6" >> "$A"
echo "cinone $(K 15) $HA7 $((NOW-960))" >> "$A"     # A7: the dispatch answers 422
echo 422 > "$T/dispatch.ticket_pb-15"
echo "cinone $(K 16) $HA8 $((NOW-960))" >> "$A"     # A8: no workflow is both
mkdir -p "$T/wf/ticket_pb-16"
printf 'name: ci\non:\n  pull_request:\njobs: {}\n' > "$T/wf/ticket_pb-16/ci.yml"
echo 'completed|cancelled|905|compile' > "$T/runs.$HA5"
set_list "$(list_row 10 "$HA1" UNKNOWN UNKNOWN)" "$(list_row 11 "$HA3" CLEAN MERGEABLE)" \
  "$(list_row 12 "$HA4" DIRTY CONFLICTING)" "$(list_row 13 "$HA5" CLEAN MERGEABLE)" \
  "$(list_row 14 "$HA6" CLEAN MERGEABLE)" "$(list_row 15 "$HA7" CLEAN MERGEABLE)" "$(list_row 16 "$HA8" CLEAN MERGEABLE)"
: > "$T/writes.txt"
run_tick MC_DETACHED_REBASE=0

# A1 — one dispatch of ci.yml on the head branch, one alert, three marks.
[ "$(grep -c 'actions/workflows/ci.yml/dispatches -f ref=ticket/TK-10' "$T/writes.txt")" = 1 ] \
  && ok || bad "A1: a head 16 min with no run must get ONE workflow_dispatch of ci.yml on its branch (writes: $(cat "$T/writes.txt"))"
[ "$(nalert "$(K 10) CI_NEVER_STARTED")" = 1 ] && ok || bad "A1: one CI_NEVER_STARTED alert (ALERTS: $(cat "$ALOG"))"
said 10 'dispatched ci.yml on ticket/TK-10' \
  && ok || bad "A1: the alert says what was done (got: $(grep "$(K 10)" "$ALOG"))"
for m in cikick cikickalert cinostart; do
  grep -qxF "$m $(K 10) $HA1" "$A" && ok || bad "A1: the $m mark is written (attempts: $(grep "$(K 10)" "$A"))"
done
grep -q 'allow-empty\|git push' "$T/writes.txt" && bad "A1: never an empty commit" || ok
grep -q 'pulls/10 -f state=closed' "$T/writes.txt" && bad "A1: the timer never closes and reopens" || ok
# A3 — 14 min is a run that has not appeared yet.
grep -q 'ref=ticket/TK-11' "$T/writes.txt" && bad "A3: 14 min must not dispatch" || ok
[ "$(nalert "$(K 11)")" = 0 ] && ok || bad "A3: 14 min must not alert"
# A4 — a DIRTY head runs nothing by design: the rebase owns it.
grep -q 'ref=ticket/TK-12' "$T/writes.txt" && bad "A4: a DIRTY head is never dispatched" || ok
[ "$(nalert "$(K 12) CI_NEVER_STARTED")" = 0 ] && ok || bad "A4: a DIRTY head never alerts CI_NEVER_STARTED"
# A5 — cancelled-only runs are the flake ladder's.
grep -q 'ref=ticket/TK-13' "$T/writes.txt" && bad "A5: a cancelled-only head is the flake ladder's, not the timer's" || ok
[ "$(nalert "$(K 13) CI_NEVER_STARTED")" = 0 ] && ok || bad "A5: no CI_NEVER_STARTED for a flake head"
# A6 — kicked by close/reopen already: no dispatch, one alert that says so.
grep -q 'ref=ticket/TK-14' "$T/writes.txt" && bad "A6: a head another arm already kicked is not dispatched again" || ok
[ "$(nalert "$(K 14) CI_NEVER_STARTED")" = 1 ] && said 14 'already kicked' \
  && ok || bad "A6: one alert naming the earlier kick (got: $(grep "$(K 14)" "$ALOG"))"
# A7 — a refused dispatch: the alert says so, and no cikick is written.
[ "$(nalert "$(K 15) CI_NEVER_STARTED")" = 1 ] && said 15 'dispatch of ci.yml on ticket/TK-15 FAILED (HTTP 422)' \
  && ok || bad "A7: a 422 dispatch must be said in the alert (got: $(grep "$(K 15)" "$ALOG"))"
grep -q "^cikick $(K 15) " "$A" && bad "A7: a failed dispatch must not write cikick" || ok
grep -qxF "cinostart $(K 15) $HA7" "$A" && ok || bad "A7: the timer mark is still written (one try per head)"
# A8 — deploy-worker.yml declares workflow_dispatch but not pull_request.
grep -q 'ref=ticket/TK-16' "$T/writes.txt" && bad "A8: a workflow with no pull_request trigger is never dispatched (writes: $(cat "$T/writes.txt"))" || ok
said 16 'no workflow declares pull_request + workflow_dispatch, so nothing was re-triggered' \
  && ok || bad "A8: the alert says nothing was re-triggered (got: $(grep "$(K 16)" "$ALOG"))"
grep -q 'push an empty commit' "$ALOG" && bad "A: no alert text asks for an empty commit" || ok

# A2 — the same fixtures on a second tick: no new write, no new alert.
W1=$(wc -l < "$T/writes.txt"); A1N=$(wc -l < "$ALOG")
run_tick MC_DETACHED_REBASE=0
[ "$(wc -l < "$T/writes.txt")" = "$W1" ] && ok || bad "A2: a second tick must add no write (new: $(tail -n +"$((W1+1))" "$T/writes.txt"))"
[ "$(wc -l < "$ALOG")" = "$A1N" ] && ok || bad "A2: a second tick must add no alert (new: $(tail -n +"$((A1N+1))" "$ALOG"))"

# A9 — observe mode: one WOULD line, nothing written.
HA9=$(hx a9); mkrec 17 "$HA9"
echo "cinone $(K 17) $HA9 $((NOW-960))" >> "$A"
set_list "$(list_row 17 "$HA9" CLEAN MERGEABLE)"
rm -f "$T/h/flags/merge-conductor-actions"
: > "$T/writes.txt"; AB=$(wc -l < "$A")
run_tick MC_DETACHED_REBASE=0
[ ! -s "$T/writes.txt" ] && ok || bad "A9: observe mode writes nothing to GitHub (got: $(cat "$T/writes.txt"))"
grep -q "cinostart $(K 17)\|cikick $(K 17)" "$A" && bad "A9: observe mode writes no mark" || ok
[ "$(grep -c "$(K 17) would dispatch CI" "$CLOG")" = 1 ] && ok || bad "A9: one WOULD line (got: $(grep "$(K 17)" "$CLOG" | tail -3))"
[ "$(nalert "$(K 17)")" = 0 ] && ok || bad "A9: observe mode sends no alert"
touch "$T/h/flags/merge-conductor-actions"

# A10 — 12 run-less PRs on one project: 5 a tick (MC_STUCK_TIMERS_MAX_PER_TICK).
ROWS=()
for n in $(seq 40 51); do
  h=$(hx "c$n"); mkrec "$n" "$h"; echo "cinone $(K "$n") $h $((NOW-960))" >> "$A"
  ROWS+=("$(list_row "$n" "$h" CLEAN MERGEABLE)")
done
set_list "${ROWS[@]}"
nfire() { grep -c 'CI_NEVER_STARTED' "$ALOG" | awk '{print $1}'; }
B0=$(nfire)
run_tick MC_DETACHED_REBASE=0; B1=$(nfire)
run_tick MC_DETACHED_REBASE=0; B2=$(nfire)
run_tick MC_DETACHED_REBASE=0; B3=$(nfire)
[ "$((B1-B0)) $((B2-B1)) $((B3-B2))" = "5 5 2" ] && ok || bad "A10: 12 run-less PRs fire 5, 5, 2 over three ticks (got $((B1-B0)) $((B2-B1)) $((B3-B2)))"

# D1 — the A1 head again, now WAIT_CI checks none on MERGEABLE and 21 min old:
# the catch-all's escalate arm sees cikick, and cikickalert keeps it quiet.
set_list "$(list_row 10 "$HA1" CLEAN MERGEABLE)"
mc_row_put "$(K 10)" WAIT_CI $((NOW-1300)) "$HA1" "$HA1" - "checks none" "$(U 10)"
: > "$T/writes.txt"
run_tick MC_DETACHED_REBASE=0
[ "$(nalert "$(K 10) CI_NEVER_STARTED")" = 1 ] && ok || bad "D1: exactly one CI_NEVER_STARTED for the A1 head after three ticks"
[ "$(nalert "CI_ABSENT_TWICE.*$(K 10)\|$(K 10).*CI_ABSENT_TWICE")" = 0 ] && ok || bad "D1: no CI_ABSENT_TWICE on the head the timer already alerted (ALERTS: $(grep "$(K 10)" "$ALOG"))"
[ ! -s "$T/writes.txt" ] && ok || bad "D1: and no second re-trigger (got: $(cat "$T/writes.txt"))"

# ============================================================================
# C. Red on two consecutive heads
# ============================================================================
red_pr() { # red_pr <num> <head> [prev-head prev-outcome]
  mkrec "$1" "$2"
  echo "completed|failure|7$1|ci" > "$T/runs.$2"
  echo "7$1|.github/workflows/ci.yml|ci|$2" > "$T/failed.$2"
  [ -n "${3:-}" ] && echo "cihead $(K "$1") $3 $4" >> "$A"
  return 0
}
CHECKS='{"total_count":3,"check_runs":[{"name":"ci","status":"completed","conclusion":"failure"},{"name":"unit (3)","status":"completed","conclusion":"timed_out"},{"name":"lint","status":"completed","conclusion":"success"}]}'
HC1=$(hx d1); HC2=$(hx d2)
red_pr 30 "$HC2" "$HC1" red;   printf '%s' "$CHECKS" > "$T/checks.$HC2"          # C1
HG1=$(hx e1); HG2=$(hx e2); red_pr 31 "$HG2" "$HG1" green                         # C2
HN2=$(hx f2); red_pr 32 "$HN2"                                                    # C3
HK1=$(hx b1); HK2=$(hx b2); red_pr 33 "$HK2" "$HK1" red                           # C4 (known flake)
HV1=$(hx c1); HV2=$(hx c2); mkrec 34 "$HV2"; echo "cihead $(K 34) $HV1 red" >> "$A"
echo 'completed|success|734|ci' > "$T/runs.$HV2"                                  # C5
HU1=$(hx 61); HU2=$(hx 62); red_pr 36 "$HU2" "$HU1" red                           # C8: checks unreadable
set_list "$(list_row 30 "$HC2" BLOCKED MERGEABLE)" "$(list_row 31 "$HG2" BLOCKED MERGEABLE)" \
  "$(list_row 32 "$HN2" BLOCKED MERGEABLE)" "$(list_row 34 "$HV2" CLEAN MERGEABLE)" "$(list_row 36 "$HU2" BLOCKED MERGEABLE)"
: > "$T/writes.txt"; : > "$T/reruns.txt"; : > "$T/launch.txt"; : > "$T/checkrun-reads.txt"; AC0=$(wc -l < "$ALOG")
run_tick MC_DETACHED_REBASE=0

# C1 — red after red: no rerun, RED_TWICE with the names, file, launch.
grep -q " 730 \| 730$" "$T/reruns.txt" && bad "C1: red on two consecutive heads must skip the one-rerun rung (reruns: $(cat "$T/reruns.txt"))" || ok
[ "$(state_of "$(K 30)")" = RED_TWICE ] && ok || bad "C1: the row must be RED_TWICE (got $(state_of "$(K 30)") / $(reason_of "$(K 30)"))"
[ "$(reason_of "$(K 30)")" = "red-twice: red on consecutive heads ${HC1:0:8} and ${HC2:0:8}; failing checks: ci, unit (3)" ] \
  && ok || bad "C1: the reason names both heads and the failing checks (got: $(reason_of "$(K 30)"))"
F30="$RCD/$(mc_handoff_id "$(K 30)")"
[ "$(head -1 "$F30" 2>/dev/null)" = "$HC2" ] && [ "$(tail -n +2 "$F30" 2>/dev/null | tr '\n' '|')" = "ci|unit (3)|" ] \
  && ok || bad "C1: the red-checks file holds the head and the names (got: $(cat "$F30" 2>/dev/null))"
wait_launch "only=$(K 30)" && grep -q "p=$P only=$(K 30)" "$T/launch.txt" \
  && ok || bad "C1: the resolver is started for this PR in the same tick (launches: $(cat "$T/launch.txt"))"
grep -qxF "fixnow $(K 30) $HC2 red" "$A" && ok || bad "C1: the fixnow mark is written"
grep -q "$(K 30) red — bin/blocked-resolver.sh launch requested for this PR now" "$CLOG" \
  && ok || bad "C1: the launch line says launch requested (got: $(grep "$(K 30)" "$CLOG" | tail -2))"
[ "$(tail -n +"$((AC0+1))" "$ALOG" | grep -c "$(K 30)")" = 0 ] && ok || bad "D1: the hand-off sends no new alert"
# C2 — green, then red: the old ladder (one rerun, WAIT_CI).
[ "$(grep -c "run rerun 731 --failed" "$T/reruns.txt")" = 1 ] && ok || bad "C2: green then red keeps the one rerun (reruns: $(cat "$T/reruns.txt"))"
[ "$(state_of "$(K 31)")" = WAIT_CI ] && ok || bad "C2: and stays WAIT_CI (got $(state_of "$(K 31)"))"
# C3 — no earlier settled head: the old ladder.
[ "$(grep -c "run rerun 732 --failed" "$T/reruns.txt")" = 1 ] && ok || bad "C3: no previous head keeps the one rerun"
[ "$(state_of "$(K 32)")" = WAIT_CI ] && ok || bad "C3: and stays WAIT_CI (got $(state_of "$(K 32)"))"
# C5 — red, then green: nothing to hand off.
case "$(state_of "$(K 34)")" in RED_TWICE|BLOCKED_HUMAN) bad "C5: a green head after a red one is not a hand-off" ;; *) ok ;; esac
grep -q "only=$(K 34)" "$T/launch.txt" && bad "C5: no launch for a green head" || ok
grep -qxF "cihead $(K 34) $HV2 green" "$A" && ok || bad "C5: the green head is recorded"
# C8 — the check-runs read failed: `unread`, and still handed off.
[ "$(state_of "$(K 36)")" = RED_TWICE ] && case "$(reason_of "$(K 36)")" in *'failing checks: unread') true ;; *) false ;; esac \
  && ok || bad "C8: an unreadable check-runs read still hands off, with the name unread (got: $(state_of "$(K 36)") / $(reason_of "$(K 36)"))"
wait_launch "only=$(K 36)" && ok || bad "C8: and the resolver is started"

# C6 — the same red head on a second tick: one cihead line, one check-runs
# read, one launch.
CR=$(wc -l < "$T/checkrun-reads.txt")
run_tick MC_DETACHED_REBASE=0
sleep 0.5
[ "$(grep -c "^cihead $(K 30) $HC2 " "$A")" = 1 ] && ok || bad "C6: one cihead line per head (got $(grep -c "^cihead $(K 30) $HC2 " "$A"))"
[ "$(wc -l < "$T/checkrun-reads.txt")" = "$CR" ] && ok || bad "C6: the check names are read once per head"
[ "$(grep -c "only=$(K 30)" "$T/launch.txt")" = 1 ] && ok || bad "C6: one launch per (PR, head) (launches: $(cat "$T/launch.txt"))"
[ "$(state_of "$(K 30)")" = RED_TWICE ] && ok || bad "C6: the row stays RED_TWICE"
grep -q " 730 \| 730$" "$T/reruns.txt" && bad "C6: and no rerun on the second tick either" || ok

# C4 — red after red, every failure a known flake: the flake rerun, not RED_TWICE.
touch "$T/allknown"
set_list "$(list_row 33 "$HK2" BLOCKED MERGEABLE)"
: > "$T/reruns.txt"
run_tick MC_DETACHED_REBASE=0
rm -f "$T/allknown"
[ "$(grep -c "run rerun 733 --failed" "$T/reruns.txt")" = 1 ] && ok || bad "C4: a known-flake red takes the flake rerun (reruns: $(cat "$T/reruns.txt"))"
[ "$(state_of "$(K 33)")" != RED_TWICE ] && ok || bad "C4: and is not RED_TWICE"

# C7 — observe mode: the old ladder, no MC_RED_CONSEC.
HO1=$(hx 71); HO2=$(hx 72); red_pr 35 "$HO2" "$HO1" red; printf '%s' "$CHECKS" > "$T/checks.$HO2"
set_list "$(list_row 35 "$HO2" BLOCKED MERGEABLE)"
rm -f "$T/h/flags/merge-conductor-actions"
run_tick MC_DETACHED_REBASE=0
touch "$T/h/flags/merge-conductor-actions"
[ "$(state_of "$(K 35)")" = WAIT_CI ] && [ "$(reason_of "$(K 35)")" = "checks red once" ] \
  && ok || bad "C7: observe mode keeps the old ladder (got $(state_of "$(K 35)") / $(reason_of "$(K 35)"))"
[ -e "$RCD/$(mc_handoff_id "$(K 35)")" ] && bad "C7: observe mode writes no red-checks file" || ok

# ============================================================================
# B. A failed rebase: the resolver starts in the same tick (the real tick)
# ============================================================================
job_done() { # job_done <num> <head> <rc> <out-text>
  local jf of
  jf=$(mc_rb_file "$SLUG" "$1" "$2"); of="${jf%.json}.out"
  mkdir -p "$(dirname "$jf")"
  printf '%s' "$4" > "$of"
  mc_rb_write "$jf" done 0 "$((NOW-600))" "$((NOW-300))" "$3" "$2" - "$of"
}
HB1=$(hx 81); HB2=$(hx 82)
mkrec 20 "$HB1"; mkrec 21 "$HB2"
mc_row_put "$(K 20)" REBASING $((NOW-400)) "$HB1" "$HB1" - "REBASING ${HB1:0:8}" "$(U 20)"
mc_row_put "$(K 21)" REBASING $((NOW-400)) "$HB2" "$HB2" - "REBASING ${HB2:0:8}" "$(U 21)"
job_done 20 "$HB1" 1 "CONFLICT (content): Merge conflict in a.ts"
job_done 21 "$HB2" 2 "gate red"
set_list "$(list_row 20 "$HB1" DIRTY CONFLICTING)" "$(list_row 21 "$HB2" DIRTY CONFLICTING)"
: > "$T/launch.txt"; AB0=$(wc -l < "$ALOG")
run_tick
# B1 — conflict-unresolvable.
[ "$(state_of "$(K 20)")" = BLOCKED_HUMAN ] && case "$(reason_of "$(K 20)")" in conflict-unresolvable*) true ;; *) false ;; esac \
  && ok || bad "B1: the fixture must park conflict-unresolvable (got $(state_of "$(K 20)") / $(reason_of "$(K 20)"))"
wait_launch "only=$(K 20)" && grep -q "p=$P only=$(K 20)" "$T/launch.txt" \
  && ok || bad "B1: a failed rebase starts the resolver for this PR in the same tick (launches: $(cat "$T/launch.txt"))"
grep -qxF "fixnow $(K 20) $HB1 rebase" "$A" && ok || bad "B1: the fixnow mark is written"
[ -s "$(mc_handoff_file "$(K 20)")" ] && ok || bad "B1: the hand-off file is still written"
# B2 — rebase-gate-red.
[ "$(reason_of "$(K 21)")" = rebase-gate-red ] && wait_launch "only=$(K 21)" \
  && ok || bad "B2: rebase-gate-red starts the resolver too (got $(reason_of "$(K 21)"); launches: $(cat "$T/launch.txt"))"
[ "$(tail -n +"$((AB0+1))" "$ALOG" | grep -c "$(K 20)\|$(K 21)")" = 0 ] && ok || bad "D1: a rebase hand-off sends no new alert"

# ============================================================================
# B3-B8, C9, C10, R, K: the lib, called directly
# ============================================================================
# shellcheck source=/dev/null
[ -r "$T/h/bin/lib/mc-stuck-timers.sh" ] && . "$T/h/bin/lib/mc-stuck-timers.sh"
: > "$T/launch.txt"
ACTIONS=1; MC_FIX_NOW_ON=1; unset BR_ONLY_PR
trans() { mc_transition "$(K "$1")" "$2" "$3" "$4" "$4" "$(U "$1")" APPROVE BLOCKED - >/dev/null; }
nlaunch() { sleep 0.5; grep -c "only=$(K "$1")" "$T/launch.txt" | awk '{print $1}'; }
HX=$(hx 91)
# B3 — the same park again (no state change): no second launch.
mc_row_put "$(K 60)" WAIT_CI $((NOW-60)) "$HX" "$HX" - "checks pending" "$(U 60)"
trans 60 BLOCKED_HUMAN "conflict-unresolvable: a.ts" "$HX"; trans 60 BLOCKED_HUMAN "conflict-unresolvable: a.ts" "$HX"
[ "$(nlaunch 60)" = 1 ] && ok || bad "B3: one launch per park, not one per tick (got $(nlaunch 60))"
# B4 — a lease rejection is a retry, not a hand-off.
mc_row_put "$(K 61)" REBASING $((NOW-60)) "$HX" "$HX" - "REBASING" "$(U 61)"
trans 61 NEEDS_REBASE "lease rejected, retry" "$HX"
[ "$(nlaunch 61)" = 0 ] && ok || bad "B4: NEEDS_REBASE lease rejected starts nothing"
# B5 — a resolver-process caller (MC_FIX_NOW_ON unset) never launches a resolver.
mc_row_put "$(K 62)" REBASING $((NOW-60)) "$HX" "$HX" - "REBASING" "$(U 62)"
( unset MC_FIX_NOW_ON; trans 62 BLOCKED_HUMAN "conflict-unresolvable: b.ts" "$HX" )
[ "$(nlaunch 62)" = 0 ] && ok || bad "B5: a caller without MC_FIX_NOW_ON starts nothing"
# B6 — a one-PR resolver run (BR_ONLY_PR set) never launches another.
mc_row_put "$(K 63)" REBASING $((NOW-60)) "$HX" "$HX" - "REBASING" "$(U 63)"
( BR_ONLY_PR="$(K 63)"; trans 63 BLOCKED_HUMAN "rebase-gate-red" "$HX" )
[ "$(nlaunch 63)" = 0 ] && ok || bad "B6: BR_ONLY_PR set starts nothing"
# B7 — RED_TWICE on the same head (the old rung 2) is handed over at once too.
mc_row_put "$(K 64)" WAIT_CI $((NOW-60)) "$HX" "$HX" - "checks red once" "$(U 64)"
trans 64 RED_TWICE "red-twice: still red on ${HX:0:8} after its failed jobs were re-run once" "$HX"
[ "$(nlaunch 64)" = 1 ] && grep -qxF "fixnow $(K 64) $HX red" "$A" && ok || bad "B7: RED_TWICE starts the resolver (kind red)"
# B8 — a park the resolver does not own this way: nothing.
mc_row_put "$(K 65)" WAIT_REVIEW $((NOW-60)) "$HX" "$HX" - "x" "$(U 65)"
trans 65 BLOCKED_HUMAN "no-verdict" "$HX"
[ "$(nlaunch 65)" = 0 ] && ok || bad "B8: BLOCKED_HUMAN no-verdict starts nothing here"
# B9 — observe mode: one WOULD line, no mark, no launch.
mc_row_put "$(K 66)" REBASING $((NOW-60)) "$HX" "$HX" - "REBASING" "$(U 66)"
( ACTIONS=0; trans 66 BLOCKED_HUMAN "conflict-unresolvable: c.ts" "$HX" )
[ "$(nlaunch 66)" = 0 ] && ! grep -q "fixnow $(K 66)" "$A" && grep -q "$(K 66) would start bin/blocked-resolver.sh" "$CLOG" \
  && ok || bad "B9: observe mode logs WOULD and writes nothing"

# C9 — the resolver reads the consecutive reason as its ci-red word.
# shellcheck source=/dev/null
. "$DIR/bin/lib/br/ladder.sh"
[ "$(br_reason_of "$(reason_of "$(K 30)")")" = red-twice ] && ok || bad "C9: br_reason_of reads the C1 reason as red-twice"

# C10 — the fix-round brief block, run on the C1 file.
BLK=$(sed -n '/# >>> red checks brief (BH-7241)/,/# <<< red checks brief/p' "$DIR/bin/blocked-resolver.sh")
[ -n "$BLK" ] || bad "C10: the '# >>> red checks brief (BH-7241)' block is missing from bin/blocked-resolver.sh"
brief="FINDINGS"; slug="$SLUG"; url="$(U 30)"; head="$HC2"
eval "$BLK"
grep -q 'THE CHECKS THAT FAILED ON THIS HEAD' <<<"$brief" && grep -qx 'unit (3)' <<<"$brief" \
  && ok || bad "C10: the brief carries the failing check names (got: $brief)"
brief="FINDINGS"; head="$HC1"; eval "$BLK"
[ "$brief" = FINDINGS ] && ok || bad "C10: another head's names never reach the brief (got: $brief)"

# R1 — cihead round-trip: three heads, the previous of the third.
R1=$(hx 11a); R2=$(hx 11b); R3=$(hx 11c)
mst_cihead_put "$(K 70)" "$R1" green; mst_cihead_put "$(K 70)" "$R2" red; mst_cihead_put "$(K 70)" "$R3" red
mst_cihead_put "$(K 70)" "$R3" red
[ "$(grep -c "^cihead $(K 70) $R3 red$" "$A")" = 1 ] && ok || bad "R1: one line per (head, outcome)"
[ "$(mst_red_consecutive "$(K 70)" "$R3")" = "$R2" ] && ok || bad "R1: the previous settled head of R3 is R2 (got $(mst_red_consecutive "$(K 70)" "$R3"))"
mst_cihead_put "$(K 70)" "$R2" green     # R2's rerun went green: no longer red
mst_red_consecutive "$(K 70)" "$R3" >/dev/null && bad "R1: a head whose last answer is green is not a red predecessor" || ok
mst_red_consecutive "$(K 70)" "$R1" >/dev/null && bad "R1: the first head has no predecessor" || ok
# R2 — red-checks round-trip.
printf '%s' "$CHECKS" > "$T/checks.$R3"
mst_red_checks_put "$SLUG" "$(K 70)" "$R3" >/dev/null
[ "$(mst_red_checks_read "$(K 70)" "$R3" | tr '\n' '|')" = "ci|unit (3)|" ] && ok || bad "R2: the names read back for the head (got $(mst_red_checks_read "$(K 70)" "$R3"))"
mst_red_checks_read "$(K 70)" "$R2" >/dev/null && bad "R2: another head reads nothing" || ok

# K1/K2 — MC_CI_NOSTART_MIN through lane_knob: no row 15, a project row 30.
mkdir -p "$T/reg/catalog" && cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 \
  || bad "K: the lane registry does not render"
KH="$T/kh"; mkdir -p "$KH/state"
scratch_install_closure bin/lib/lane-gate.sh "$KH" >/dev/null || exit 1
kmin() { ( HARNESS="$KH" LANE_REGISTRY="$T/reg/catalog/lanes.json" JOBS_URL="" bash -c \
  ". '$KH/bin/lib/lane-gate.sh'; . '$T/h/bin/lib/mc-stuck-timers.sh'; mst_nostart_min '$1'" 2>/dev/null ); }
printf '{"fetched_at":%s,"values":{}}' "$NOW" > "$KH/state/settings-cache.json"
[ "$(kmin demo-os)" = 15 ] && ok || bad "K1: no row reads the default 15 (got $(kmin demo-os))"
printf '{"fetched_at":%s,"values":{"lane.merge-conductor.demo-os.mc_ci_nostart_min":"30"}}' "$NOW" > "$KH/state/settings-cache.json"
[ "$(kmin demo-os)" = 30 ] && ok || bad "K2: a project row of 30 reads 30 (got $(kmin demo-os))"
[ "$(kmin other-os)" = 15 ] && ok || bad "K2: and another project still reads 15 (got $(kmin other-os))"

# K3 — MC_STUCK_TIMERS=0: a run-less head and a red-after-red head take
# today's path and no new mark is written.
HZ1=$(hx 9a); HZ2=$(hx 9b); HZ0=$(hx 9c)
mkrec 55 "$HZ1"; echo "cinone $(K 55) $HZ1 $((NOW-960))" >> "$A"
red_pr 56 "$HZ2" "$HZ0" red; printf '%s' "$CHECKS" > "$T/checks.$HZ2"
set_list "$(list_row 55 "$HZ1" UNKNOWN UNKNOWN)" "$(list_row 56 "$HZ2" BLOCKED MERGEABLE)"
: > "$T/writes.txt"; : > "$T/reruns.txt"; : > "$T/launch.txt"; AK=$(wc -l < "$ALOG")
run_tick MC_DETACHED_REBASE=0 MC_STUCK_TIMERS=0
sleep 0.5
grep -q 'dispatches' "$T/writes.txt" && bad "K3: the switch off dispatches nothing" || ok
[ "$(wc -l < "$ALOG")" = "$AK" ] && ok || bad "K3: the switch off sends no new alert (new: $(tail -n +"$((AK+1))" "$ALOG"))"
[ "$(grep -c "run rerun 756 --failed" "$T/reruns.txt")" = 1 ] && ok || bad "K3: the switch off keeps the one rerun (reruns: $(cat "$T/reruns.txt"))"
[ "$(state_of "$(K 56)")" = WAIT_CI ] && ok || bad "K3: and the row stays WAIT_CI (got $(state_of "$(K 56)"))"
grep -q "cinostart $(K 55)\|cihead $(K 56) $HZ2\|fixnow $(K 56)" "$A" && bad "K3: the switch off writes no new mark" || ok
[ ! -s "$T/launch.txt" ] && ok || bad "K3: the switch off launches nothing"

echo "stuck-pr-timers.bh-7241: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

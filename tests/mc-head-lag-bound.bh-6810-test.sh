#!/bin/bash
# tests/mc-head-lag-bound.bh-6810-test.sh — BH-6810: the head-lag branch-tip
# read has a time bound, a timed-out read is a named HELD reason (no
# STEP_TIMEOUT, no Sentry), and the head-lag step logs STEP_START/STEP_END on
# every run.
#
# Sentry CROMFORD-HARNESS-R: conductor-step-timeout, step head-lag, project
# project-9. `gh_rest` ran `gh api` with no time bound, so a stalled branch
# read held the step until the watchdog killed the whole worker.
#
#   G1  gh_rest, GH_REST_TIMEOUT_S=2, gh stub `exec sleep 300`: rc 75, status
#       000, reason timeout, under 10 s
#   G2  same var, a fast 500: rc 75, reason not timeout
#   G3  after G1: no gh-rest.* temp file left
#   G4  var unset, a 3 s answer: rc 0 after >= 3 s (no bound)
#   G5  var `abc`, and var 2 with a gh() function stub: no bound
#   G6  var 2 with the gh-limit-logger wrapper (_ghll_count defined): bounded
#   B1  head_lag_tip, MC_HEAD_LAG_READ_TIMEOUT_S=2, branch read stalls: rc 75
#       in under 10 s, HEAD_LAG_WHY = "HTTP 000 timeout"
#   B2  knob 0: no bound, a 3 s branch read answers rc 0 after >= 3 s
#   E1  the real bin/merge-conductor.sh tick, branch read `exec sleep 300`,
#       knob 2: the tick ends in under 60 s, one HEAD_LAG_HELD line, 0
#       STEP_TIMEOUT / STEP_HELD / WORKER_DEADLINE, 0 alerts, 0 Sentry events,
#       the PR is worked to an outcome
#   E2  a second tick on the same head: no second HEAD_LAG_HELD line
#   H1  a 429 rate-limit branch read: the old "head-lag check skipped" line, no
#       HEAD_LAG_HELD
#   N1  two PRs, only #1 stalls: enumerated 2 accounted 2, #2 worked, no
#       HEAD_LAG_HELD for #2
#   N2  knob 0 and MC_STEP_TIMEOUT_S=4: #1 killed:slow-read, #2 still worked
#   L1  a normal tick: one STEP_START and one STEP_END step=head-lag took=<n>s,
#       no STEP_START step=handoff-sticky (the flag is restored)
#   L2  MC_STEP_LOG_HEAD_LAG=0: no head-lag STEP line
#   L3  MC_STEP_LOG_HEAD_LAG=x reads as 1
#   K1  both knob fragments match the code defaults
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-head-lag-bound.bh-6810-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }
# No GitHub credential or install id from the box reaches a stub (D60).
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID
NOW=$(date +%s)
hd() { printf '%02d%038d' "$1" 0; }

# ============================================================================
# G — gh_rest on its own. $G/mode picks the stub's answer.
# ============================================================================
G="$T/g"; mkdir -p "$G/bin" "$G/tmp" "$G/h/logs"
cat > "$G/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$(cat "$G/mode" 2>/dev/null)" in
  stall) exec sleep 20 ;;   # determinism: ok the stub IS the stalled read under test
  slow)  sleep 3; printf 'HTTP/1.1 200 OK\r\n\r\n{"ok":1}\n' ;;   # determinism: ok a slow answer the bound must not cut when off
  500)   printf 'HTTP/1.1 500 Oops\r\n\r\n{"message":"boom"}\n' ;;
  *)     printf 'HTTP/1.1 200 OK\r\n\r\n{"ok":1}\n' ;;
esac
exit 0
EOF
chmod +x "$G/bin/gh"
# gr <mode> [env...] -- <bash after the call> — one gh_rest GET in a fresh shell.
gr() { local mode="$1"; shift; echo "$mode" > "$G/mode"
  ( export "$@" 2>/dev/null; unset GH_REST_LIB
    HARNESS="$G/h" TMPDIR="$G/tmp" GH_ETAG=0 PATH="$G/bin:$PATH"
    . "$DIR/bin/lib/gh-rest.sh"
    [ -n "${GR_PRE:-}" ] && eval "$GR_PRE"
    s=$SECONDS; rc=0
    gh_rest GET repos/o/r/branches/x > "$G/out" || rc=$?
    echo "rc=$rc st=$GH_REST_STATUS why=$GH_REST_REASON took=$((SECONDS - s)) out=$(cat "$G/out")"
  ) 2>&1; }

R=$(gr stall GH_REST_TIMEOUT_S=2)
TOOK=$(sed -E 's/.*took=([0-9]+).*/\1/' <<<"$R")
grep -q '^rc=75 st=000 why=timeout ' <<<"$R" && [ "$TOOK" -lt 10 ] && ok || bad "G1 a stalled read with the var 2: rc 75, 000, timeout, < 10 s ($R)"
R=$(gr 500 GH_REST_TIMEOUT_S=2)
grep -q '^rc=75 st=500 why= ' <<<"$R" && ok || bad "G2 a fast 500 is not a timeout ($R)"
[ -z "$(ls "$G/tmp" 2>/dev/null | grep '^gh-rest\.')" ] && ok || bad "G3 no gh-rest.* temp file left ($(ls "$G/tmp"))"
R=$(gr slow GH_REST_TIMEOUT_S=)
TOOK=$(sed -E 's/.*took=([0-9]+).*/\1/' <<<"$R")
grep -q '^rc=0 st=200 why= ' <<<"$R" && [ "$TOOK" -ge 3 ] && ok || bad "G4 var unset: no bound, a 3 s answer is read ($R)"
R=$(gr slow GH_REST_TIMEOUT_S=abc)
grep -q '^rc=0 st=200 ' <<<"$R" && ok || bad "G5 var abc: no bound ($R)"
R=$(GR_PRE='gh() { sleep 3; printf "HTTP/1.1 200 OK\r\n\r\n{\"fn\":1}\n"; }' gr stall GH_REST_TIMEOUT_S=1)   # determinism: ok the stub IS the slow answer a function stub must get unbounded
grep -q '^rc=0 st=200 .*"fn":1' <<<"$R" && ok || bad "G5 a gh() function stub runs unbounded and is returned ($R)"
R=$(GR_PRE='_ghll_count() { :; }; gh() { _ghll_count "$1" "$2"; command gh "$@"; }' gr stall GH_REST_TIMEOUT_S=2)
TOOK=$(sed -E 's/.*took=([0-9]+).*/\1/' <<<"$R")
grep -q '^rc=75 st=000 why=timeout ' <<<"$R" && [ "$TOOK" -lt 10 ] && ok || bad "G6 the gh-limit-logger wrapper is bounded ($R)"

# K1 — the knob fragments.
for kv in MC_HEAD_LAG_READ_TIMEOUT_S:30:bin/lib/mc/rebase.sh MC_STEP_LOG_HEAD_LAG:1:bin/merge-conductor.sh; do
  IFS=: read -r k v r <<<"$kv"
  KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/$k.json"
  [ "$(jq -r '.env, .default, .min, .read_in' "$KF" 2>/dev/null | tr '\n' ' ')" = "$k $v 0 $r " ] && ok || bad "K1 the $k fragment: default $v, min 0, read_in $r ($(cat "$KF" 2>/dev/null))"
done

# ============================================================================
# B, E, H, N, L — the real conductor, gh/curl stubbed (the BH-6670 harness).
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
for n in 1 2; do
  REC="$F/h/builds/pool-demo-BH-$n-20261014000$n"; mkdir -p "$REC"
  echo "PR_CREATED $U/$n" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  hd "$n" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
done
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
# openprs <n>... — the open list: PR <n> on ticket/bh-<n>, head hd <n>.
openprs() { printf '%s\n' "$@" | jq -Rsc --arg s "$SLUG" '[split("\n")[] | select(length > 0) | tonumber | {number:., html_url:("https://github.com/"+$s+"/pull/"+tostring),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-14T00:00:00Z", head:{ref:("ticket/bh-"+tostring), sha:((if . < 10 then "0" else "" end)+tostring+("0"*38)), repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$F/open.json"; }
# The gh stub. The matching-refs read answers no ref, so the head-lag tip is
# the branches/ read. $F/tip-<n> says how branch ticket/bh-<n> answers:
# `stall` (exec sleep 300), `slow` (3 s, then the tip), `429`, else at once.
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/branches/ticket/bh-"*)
    B=\$(grep -oE 'branches/ticket/bh-[0-9]+' <<<"\$A" | grep -oE '[0-9]+\$')
    case "\$(cat "$F/tip-\$B" 2>/dev/null)" in
      stall) exec sleep 300 ;;   # determinism: ok the stub IS the stalled read under test
      slow) sleep 3 ;;   # determinism: ok a slow read the bound must not cut when off
      429) restpr --raw 429 '{"message":"API rate limit exceeded"}'; exit 0 ;;
    esac
    restpr --raw 200 '{"name":"ticket/bh-'"\$B"'","commit":{"sha":"'"\$(printf '%02d%038d' "\$B" 0)"'"}}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$(printf '%02d%038d' "\$N" 0)" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
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
# The lead reads protected paths from the jobs route (BH-4148); the demo repo
# has no rows, so it is not governed (as tests/mc-step-held.bh-6670-test.sh).
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" "$SLUG"
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
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
row() { printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$1" WAIT_CI $((NOW-600)) "$(hd "$1")" "$(hd "$1")" "$U" "$1"; }
# fresh <n>... — a clean state dir with one row per PR, no stalls.
fresh() { scratch_rm "$F/h/state"; mkdir -p "$F/h/state/merge-conductor"; : > "$ROWS"
  local n; for n in "$@"; do row "$n" >> "$ROWS"; done; openprs "$@"
  rm -f "$F"/tip-* "$F"/sentry-env-*.txt; : > "$F/c-calls.txt"; : > "$F/c-alerts.txt"; touch "$F/c-writes.txt"; }
ENVC=(PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator
  HARNESS_SENTRY_DSN=https://k-fixture@sentry.test/1 SENTRY_MAX_PER_FP_HOUR=50 HARNESS_SENTRY_CURL="$F/fakebin/sentry-curl"
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_STEP_POLL_S=1
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0)
# tick [env...] — one real conductor tick.
tick() { ( unset -f gh; cd "$F" && env -u MC_STEP_HOLD_MAX -u MC_HEAD_LAG_READ_TIMEOUT_S -u MC_STEP_LOG_HEAD_LAG -u MC_STEP_SLOW_S "${ENVC[@]}" \
  "$@" bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }
events() { local f; for f in "$F"/sentry-env-*.txt; do [ -f "$f" ] && tail -1 "$f"; done | jq -c "select(.tags.reason == \"$1\")" 2>/dev/null; }

# B1/B2 — head_lag_tip through the real conductor lib.
cat > "$F/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
mc_init
s=$SECONDS; rc=0
head_lag_tip example-org/demo ticket/bh-1 "$TMPDIR/tip" "$(printf '%02d%038d' 9 0)" || rc=$?
echo "rc=$rc why=${HEAD_LAG_WHY:-} took=$((SECONDS - s)) tip=$(cat "$TMPDIR/tip" 2>/dev/null)"
EOF
DRVN=0
drv() { DRVN=$((DRVN + 1)); ( unset -f gh; cd "$F" && timeout -k 5 30 env "${ENVC[@]}" TMPDIR="$F/h/tmp" MC_TICK_ID="drv$DRVN" "$@" bash "$F/drv.sh" 2>&1 | tail -1 ); }
fresh 1; echo stall > "$F/tip-1"
R=$(drv MC_HEAD_LAG_READ_TIMEOUT_S=2)
TOOK=$(sed -E 's/.*took=([0-9]+).*/\1/' <<<"$R")
grep -q '^rc=75 why=HTTP 000 timeout took=' <<<"$R" && [ "$TOOK" -lt 10 ] && ok || bad "B1 knob 2, a stalled branch read: rc 75, HTTP 000 timeout, < 10 s ($R)"
fresh 1; echo slow > "$F/tip-1"
R=$(drv MC_HEAD_LAG_READ_TIMEOUT_S=0 GH_REST_TIMEOUT_S=1)
TOOK=$(sed -E 's/.*took=([0-9]+).*/\1/' <<<"$R")
grep -q "^rc=0 why= took=.* tip=$(hd 1)\$" <<<"$R" && [ "$TOOK" -ge 3 ] && ok || bad "B2 knob 0: no bound, a 3 s read answers the tip ($R)"

# E1 — the branch read of #1 stalls for good; the read bound is 2 s.
fresh 1; echo stall > "$F/tip-1"
M0=$(loglen); S0=$SECONDS
tick MC_WORKER_DEADLINE_S=60 MC_HEAD_LAG_READ_TIMEOUT_S=2
E1_S=$((SECONDS - S0)); E1=$(since "$M0")
[ "$E1_S" -lt 60 ] && ok || bad "E1 the tick ends in under 60 s (took ${E1_S}s)"
grep -q "GET repos/$SLUG/branches/ticket/bh-1" "$F/c-calls.txt" && ok || bad "E1 setup: the head-lag tip read is the branches/ read ($(cat "$F/c-calls.txt"))"
HL=$(grep -F "$SLUG#1 HEAD_LAG_HELD" <<<"$E1")
[ "$(grep -c . <<<"$HL")" = 1 ] && [ -n "$HL" ] && ok || bad "E1 one HEAD_LAG_HELD line ($(grep -F "$SLUG#1" <<<"$E1" | tail -8))"
[ "${HL#* * }" = "$SLUG#1 HEAD_LAG_HELD reason=tip-read-timeout: the tip read of ticket/bh-1 passed 2s — head-lag not checked on $(hd 1 | cut -c1-8) this tick; the PR carries on, asked again every tick" ] \
  && ok || bad "E1 the HEAD_LAG_HELD line format ($HL)"
! grep -qE 'STEP_TIMEOUT|STEP_HELD|WORKER_DEADLINE' <<<"$E1" && ok || bad "E1 no STEP_TIMEOUT, STEP_HELD or WORKER_DEADLINE ($(grep -E 'STEP_TIMEOUT|STEP_HELD|WORKER_DEADLINE' <<<"$E1"))"
! grep -q 'head-lag check skipped' <<<"$E1" && ok || bad "E1 the held read is not the unread line ($(grep 'head-lag check skipped' <<<"$E1"))"
[ ! -s "$F/c-alerts.txt" ] && ok || bad "E1 no lane alert ($(cat "$F/c-alerts.txt"))"
[ -z "$(events conductor-step-timeout)" ] && ok || bad "E1 no conductor-step-timeout event ($(events conductor-step-timeout))"
T1=$(tally "$M0")
grep -q 'enumerated 1 accounted 1' <<<"$T1" && ! grep -q 'killed:' <<<"$T1" && ok || bad "E1 the PR is worked to an outcome, not killed ($T1)"
[ ! -e "$F/h/state/merge-conductor/head-lag/$(printf '%s' "$SLUG#1" | tr -c 'A-Za-z0-9' '_')" ] && [ -z "$(ls "$F/h/state/merge-conductor/head-lag" 2>/dev/null)" ] \
  && ok || bad "E1 no head-lag record is written ($(ls "$F/h/state/merge-conductor/head-lag" 2>/dev/null))"
# E2 — a second tick on the same head: the line is not said again.
M1=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_HEAD_LAG_READ_TIMEOUT_S=2
[ "$(since "$M1" | grep -c 'HEAD_LAG_HELD')" = 0 ] && ok || bad "E2 no second HEAD_LAG_HELD on the same head ($(since "$M1" | grep HEAD_LAG_HELD))"
grep -q 'enumerated 1 accounted 1' <<<"$(tally "$M1")" && ok || bad "E2 the PR is still worked ($(tally "$M1"))"

# H1 — a 429 rate-limit branch read is not a timeout.
fresh 1; echo 429 > "$F/tip-1"
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_HEAD_LAG_READ_TIMEOUT_S=2
H=$(since "$M0")
grep -qF "$SLUG#1 head-lag check skipped: the tip of ticket/bh-1 could not be read (HTTP 429 rate-limit)" <<<"$H" && ! grep -q HEAD_LAG_HELD <<<"$H" \
  && ok || bad "H1 a 429 writes the unread line, no HEAD_LAG_HELD ($(grep -F "$SLUG#1" <<<"$H" | grep -i 'head' | tail -4))"

# N1 — two PRs, only #1 stalls.
fresh 1 2; echo stall > "$F/tip-1"
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_HEAD_LAG_READ_TIMEOUT_S=2
N=$(since "$M0"); TN=$(tally "$M0")
grep -q 'enumerated 2 accounted 2' <<<"$TN" && ! grep -q 'killed:' <<<"$TN" && ok || bad "N1 both PRs are worked to an outcome ($TN)"
grep -qF "$SLUG#1 HEAD_LAG_HELD" <<<"$N" && ! grep -qF "$SLUG#2 HEAD_LAG_HELD" <<<"$N" && ok || bad "N1 HEAD_LAG_HELD for #1 only ($(grep HEAD_LAG_HELD <<<"$N"))"
grep -q "GET repos/$SLUG/branches/ticket/bh-2" "$F/c-calls.txt" && ok || bad "N1 #2's tip is read in the same tick"
# N2 — no read bound; the BH-6670 hold kills #1, and #2 is still worked.
fresh 1 2; echo stall > "$F/tip-1"
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_HEAD_LAG_READ_TIMEOUT_S=0 MC_STEP_TIMEOUT_S=4
N=$(since "$M0"); TN=$(tally "$M0")
grep -q 'enumerated 2 accounted 2' <<<"$TN" && grep -Eq 'killed:slow-read( rc=[0-9]+)? 1(,|\))' <<<"$TN" && ok || bad "N2 #1 killed:slow-read and both accounted ($TN)"
grep -qF "$SLUG#1 STEP_HELD step=head-lag" <<<"$N" && ! grep -qF "$SLUG#2 STEP_HELD" <<<"$N" && ok || bad "N2 the hold is #1's only ($(grep STEP_HELD <<<"$N"))"
grep -q "GET repos/$SLUG/branches/ticket/bh-2" "$F/c-calls.txt" && ok || bad "N2 #2's tip is read in the same tick"

# L1 — a normal tick logs the head-lag step.
fresh 1
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60
L=$(since "$M0")
[ "$(grep -c "^.*$SLUG#1 STEP_START step=head-lag\$" <<<"$L")" = 1 ] && [ "$(grep -Ec "$SLUG#1 STEP_END step=head-lag took=[0-9]+s\$" <<<"$L")" = 1 ] \
  && ok || bad "L1 one STEP_START and one STEP_END step=head-lag took=<n>s ($(grep STEP_ <<<"$L"))"
! grep -q 'STEP_START step=handoff-sticky' <<<"$L" && ! grep -q 'STEP_START step=lane-epoch' <<<"$L" && ok || bad "L1 the flag is set for head-lag only ($(grep STEP_START <<<"$L"))"
# L2 — the knob off: no head-lag STEP line.
fresh 1
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_STEP_LOG_HEAD_LAG=0
! grep -q 'STEP_[A-Z]* step=head-lag' <<<"$(since "$M0")" && ok || bad "L2 MC_STEP_LOG_HEAD_LAG=0: no head-lag STEP line ($(since "$M0" | grep STEP_))"
# L3 — a knob that is not 0/1 reads as 1.
fresh 1
M0=$(loglen)
tick MC_WORKER_DEADLINE_S=60 MC_STEP_LOG_HEAD_LAG=x
grep -q "$SLUG#1 STEP_START step=head-lag\$" <<<"$(since "$M0")" && ok || bad "L3 MC_STEP_LOG_HEAD_LAG=x reads as 1 ($(since "$M0" | grep STEP_))"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-head-lag-bound.bh-6810: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

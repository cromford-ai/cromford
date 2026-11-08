#!/bin/bash
# tests/conductor-fly-hotfix-hub.bh-9198-test.sh — BH-9198: with the per-PR fly
# path on (conductor_workers_on_fly=1), two kinds of PR run on the hub instead
# of going to the lane-run pool:
#   - a hotfix PR (the hotfix label on the PR, or on the ticket in its build
#     record): the pool cannot land it, so `fallback=hotfix`, no lane_runs row.
#   - a PR whose newest machine run ended done rc 0 with `PROF mc-pr
#     state=READY ... deferred=-`: the machine reached READY, stopped at one of
#     pr_worker's READY gates and deferred nothing, so a new row would do the
#     same thing every tick and nobody lands it (#9188, STUCK 299m).
#     BH-9202 (#9207) reads that row as `deferred=hold` first, so the tick
#     logs `fallback=machine-deferred (hold)`; rc 9 stays a second guard.
#
# Driven through the REAL bin/merge-conductor.sh tick (gh and git stubbed, the
# fixture of tests/conductor-fly-fallback.bh-6817-test.sh) against the REAL
# jobs worker (tests/lib/lane-runs-worker.bh-6124.mjs), over real curl. A
# "local worker" is a PR whose CI the tick read: only pr_worker reads
# actions/runs for a head. Project demo-os; every case has its own worker (an
# empty lane_runs) and its own PR numbers.
#
#   C1  N+3 open PRs, N=1: #31 hotfix, #32-#34 plain -> #31 fallback=hotfix,
#       runs on the hub, 0 rows; the three plain PRs are enqueued
#   C2  labels `bug,Hotfix` -> fallback=hotfix
#   C3  a done rc 0 READY deferred=- row -> fallback=machine-deferred (hold),
#       runs on the hub, no new row
#   C4  near misses: READY deferred=land, WAIT_CI deferred=-, READY rc 3; a
#       queued row newer than a READY row -> hold (BH-9202 reads done rows only)
#   C5  hotfix near misses: hotfix-later, not-hotfix, no labels, a draft, the
#       hotfix lane off
#   C6  mc_fly_ready_undeferred_for itself
#
# Run from anywhere: tests/conductor-fly-hotfix-hub.bh-9198-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
# The worker imports the two git-ignored catalog renders (CI writes them first).
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/mc/fly-workers.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/hotfix-lib.sh "$T/h" ) >/dev/null || exit 1
# The same seam as tests/fanin-solo.bh-4842-test.sh: gh-limit-logger.sh's gh
# function would step around tests/lib/gh-list-bridge.sh.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

# The first 40 characters with a bash substring, not `printf | head -c`: head
# exits early and the writer takes SIGPIPE under pipefail (race-sigpipe-echo).
hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
for n in 31 32 33 34 35 36 41 42 43 44 51 52 53 54 55; do eval "H$n=$(hd "$n")"; done
MAIN1=1111111111111111111111111111111111111111

# mklist <n>[:<labels-csv>[:draft]] ... — the open list of this case's tick.
mklist() {
  local spec n lbl dr h lj out="["
  for spec in "$@"; do
    IFS=: read -r n lbl dr <<<"$spec"
    eval "h=\$H$n"
    lj=$(jq -nc --arg l "${lbl:-}" '$l | split(",") | map(select(. != "") | {name: .})')
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/demo-os/pull/$n\",\"headRefOid\":\"$h\",\"headRefName\":\"ticket/pb-$n\",\"isDraft\":$([ "${dr:-}" = draft ] && echo true || echo false),\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"labels\":$lj},"
  done
  printf '%s\n' "${out%,}]" > "$T/list.json"
}
mklist 31 32

# gh: the open list, CI in progress on every head, and a read log. A
# `actions/runs?head_sha=<head>` read is a local pr_worker for that PR.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$T/list.json" ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha="*)
    a="\$*"; h="\${a##*head_sha=}"
    printf '%s\n' "\${h:0:2}" >> "$T/worker-reads.txt"
    printf 'in_progress|\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
echo "$MAIN1" > "$T/ctl-main-sha"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case "\$*" in
  *--version*) echo "git version 2.45.0" ;;
  *ls-remote*"refs/heads/"*) printf '%s\trefs/heads/main\n' "\$(cat "$T/ctl-main-sha")" ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
: > "$T/gh-writes.txt"; : > "$T/c-alerts.txt"
CLOG="$T/h/logs/merge-conductor.log"; : > "$CLOG"

PIDS=()
# srv [env...] -> JOBS_URL of a fresh worker (an empty lane_runs), or rc 3
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  JOBS_URL="http://127.0.0.1:$PORT"; SLOG="$T/$n.log"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
rows() { curl -sS "$JOBS_URL/__lane_runs"; }
api() { curl -sS -X "$1" -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
          ${3:+-d "$3"} "$JOBS_URL$2"; }
# ctick [VAR=value...] — one real full tick in its own session.
ctick() {
  : > "$T/worker-reads.txt"; : > "$CLOG"
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret \
      JOBS_URL="$JOBS_URL" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
locals() { sort -u "$T/worker-reads.txt" | tr '\n' ' '; }
nreads() { grep -c "^$1\$" "$T/worker-reads.txt"; }
key() { local h; eval "h=\$H$1"; printf 'demo-os.%s.%s' "$1" "${h:0:12}"; }
krows() { rows | jq --arg k "$(key "$1")" '[.rows[] | select(.project == $k)] | length'; }
prows() { rows | jq --arg p "demo-os.$1." '[.rows[] | select(.project | startswith($p))] | length'; }
nfb() { grep -c "example-org/demo-os#$1 fallback=" "$CLOG"; }
# ran_row <pr> <rc> <prof> — a run of that PR's current head, enqueued, claimed
# and reported through the real routes, as a machine does.
ran_row() {
  local n="$1" h k args id; eval "h=\$H$n"; k="demo-os.$n.${h:0:12}"
  args=$(jq -nc --arg h "$h" --arg n "$n" '["bin/merge-conductor-pr.sh","demo-os",("example-org/demo-os#"+$n),$h]')
  id=$(api POST /api/lane-runs "$(jq -nc --arg p "$k" --argjson a "$args" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
  api POST /api/lane-runs/claim '{"machine":"m9"}' >/dev/null
  api POST "/api/lane-runs/$id/report" "$(jq -nc --argjson rc "$2" --arg pr "$3" '{machine:"m9",rc:$rc,prof:$pr}')" > "$T/report.json"
}
# The PROF line bin/merge-conductor-pr.sh writes (its `prof` format string).
prof() { printf 'PROF mc-pr state=%s reason=%s deferred=%s' "$1" "$2" "$3"; }

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
ctick
grep -q 'demo-os LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" || bad "setup: no land baseline: $(grep LAND "$CLOG")"

# ============================================================================
echo "C1: N+3 open PRs, N=1: the hotfix PR #31 runs on the hub"
srv; setting conductor_workers_on_fly 1
mklist 31:hotfix 32 33 34
ctick
grep -q 'example-org/demo-os#31 heads this tick.s order' "$CLOG" && ok "C1 #31 heads this tick's order" \
  || bad "C1 order: $(grep 'demo-os#31' "$CLOG" | head -3)"
[ "$(grep -c 'example-org/demo-os#31 fallback=hotfix — this PR runs on the hub this tick' "$CLOG")" = 1 ] \
  && ok "C1 one fallback=hotfix line for #31" || bad "C1 log: $(grep 'demo-os#31' "$CLOG" | tail -3)"
[ "$(nreads 31)" -ge 1 ] && [ "$(locals)" = "31 " ] && ok "C1 #31 (and only #31) ran a local worker" \
  || bad "C1 local: '$(locals)'; stderr: $(tail -3 "$T/tick.err")"
[ "$(prows 31)" = 0 ] && ok "C1 no lane_runs row for #31" || bad "C1 rows of #31: $(prows 31)"
c1=1; for n in 32 33 34; do
  [ "$(krows "$n")" = 1 ] && [ "$(nfb "$n")" = 0 ] \
    && grep -q "example-org/demo-os#$n enqueued merge-conductor-pr $(key "$n") — no local worker" "$CLOG" || c1=0
done
[ "$c1" = 1 ] && ok "C1 #32-#34 each have one queued row and no fallback" || bad "C1 plain: $(grep -E 'demo-os#3[234] ' "$CLOG" | tail -6)"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=3 skipped=0 fallback=1' "$CLOG" && ok "C1 FLY-ENQUEUE enqueued=3 fallback=1" \
  || bad "C1 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"

# ============================================================================
echo "C2: labels bug,Hotfix -> fallback=hotfix"
srv; setting conductor_workers_on_fly 1
mklist 35:bug,Hotfix 36
ctick
grep -q 'example-org/demo-os#35 fallback=hotfix' "$CLOG" && ok "C2 #35 fallback=hotfix" || bad "C2 log: $(grep 'demo-os#35' "$CLOG" | tail -3)"
[ "$(locals)" = "35 " ] && [ "$(prows 35)" = 0 ] && [ "$(krows 36)" = 1 ] && ok "C2 #35 on the hub, #36 in the pool" \
  || bad "C2 local '$(locals)', rows #35 $(prows 35), #36 $(krows 36)"

# ============================================================================
echo "C3: a done rc 0 READY deferred=- row -> fallback=machine-deferred (hold)"
srv; setting conductor_workers_on_fly 1
mklist 32 33 34
ran_row 32 0 "$(prof READY clean-approved-checks-green -)"
[ "$(jq -r .status "$T/report.json")" = done ] && ok "C3 setup: the report answers done" || bad "C3 setup: $(cat "$T/report.json")"
ctick
[ "$(grep -cF "example-org/demo-os#32 fallback=machine-deferred (hold) — this PR runs on the hub this tick" "$CLOG")" = 1 ] \
  && ok "C3 one fallback=machine-deferred (hold) line" || bad "C3 log: $(grep 'demo-os#32' "$CLOG" | tail -3)"
[ "$(locals)" = "32 " ] && ok "C3 #32 (and only #32) ran a local worker" || bad "C3 local: '$(locals)'"
[ "$(krows 32)" = 1 ] && ok "C3 no new row for #32's key" || bad "C3 rows of the key: $(krows 32)"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=2 skipped=0 fallback=1' "$CLOG" && ok "C3 FLY-ENQUEUE enqueued=2 fallback=1" \
  || bad "C3 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"

# ============================================================================
echo "C4: near misses of the READY rule"
srv; setting conductor_workers_on_fly 1
mklist 41 42 43 44
ran_row 41 0 "$(prof READY machine-deferred land)"
ran_row 42 0 "$(prof WAIT_CI ci-running -)"
ran_row 43 3 "$(prof READY clean-approved-checks-green -)"
ran_row 44 0 "$(prof READY clean-approved-checks-green -)"
api POST /api/lane-runs "$(jq -nc --arg p "$(key 44)" --arg h "$H44" '{lane:"merge-conductor-pr",project:$p,args:["bin/merge-conductor-pr.sh","demo-os","example-org/demo-os#44",$h]}')" >/dev/null
ctick
grep -q 'example-org/demo-os#41 fallback=machine-deferred (land)' "$CLOG" && ok "C4 deferred=land -> machine-deferred" \
  || bad "C4 #41: $(grep 'demo-os#41' "$CLOG" | tail -2)"
[ "$(nfb 42)" = 0 ] && [ "$(krows 42)" = 2 ] && ok "C4 WAIT_CI deferred=- -> enqueued again, no fallback" \
  || bad "C4 #42: rows $(krows 42); $(grep 'demo-os#42' "$CLOG" | tail -2)"
grep -q "example-org/demo-os#43 fallback=machine-failed (rc=3 at $(key 43))" "$CLOG" && ok "C4 READY rc 3 -> machine-failed" \
  || bad "C4 #43: $(grep 'demo-os#43' "$CLOG" | tail -2)"
grep -q 'example-org/demo-os#44 fallback=machine-deferred (hold)' "$CLOG" && [ "$(krows 44)" = 2 ] \
  && ok "C4 a queued row over a READY row -> hold, no third row" || bad "C4 #44: rows $(krows 44); $(grep 'demo-os#44' "$CLOG" | tail -2)"
! grep -qE 'demo-os#4[123] fallback=machine-deferred \(hold\)' "$CLOG" && ok "C4 no hold line for #41-#43" \
  || bad "C4 log: $(grep -E 'demo-os#4[123] fallback' "$CLOG")"
! grep -q 'fallback=machine-ready-undeferred' "$CLOG" && ok "C4 no machine-ready-undeferred line" \
  || bad "C4 log: $(grep 'machine-ready-undeferred' "$CLOG")"

# ============================================================================
echo "C5: hotfix near misses"
srv; setting conductor_workers_on_fly 1
mklist 51:hotfix-later 52:not-hotfix 53 54:hotfix:draft
ctick
! grep -q 'fallback=hotfix' "$CLOG" && ok "C5 hotfix-later, not-hotfix, no labels, a draft -> no fallback=hotfix" \
  || bad "C5 log: $(grep 'fallback=hotfix' "$CLOG")"
[ "$(krows 51)" = 1 ] && [ "$(krows 52)" = 1 ] && [ "$(krows 53)" = 1 ] && ok "C5 #51-#53 are enqueued" \
  || bad "C5 rows: $(krows 51) $(krows 52) $(krows 53)"
srv; setting conductor_workers_on_fly 1
mklist 55:hotfix
ctick HOTFIX_LANE=0
! grep -q 'fallback=hotfix' "$CLOG" && [ "$(krows 55)" = 1 ] && ok "C5 the hotfix lane off -> #55 is enqueued, no fallback=hotfix" \
  || bad "C5 lane off: rows $(krows 55); $(grep 'demo-os#55' "$CLOG" | tail -2)"

# ============================================================================
echo "C6: mc_fly_ready_undeferred_for"
K=k.1.aaaaaaaaaaaa
ru() { ( . "$T/h/bin/lib/mc/fly-workers.sh" && mc_fly_ready_undeferred_for "$1" "$K" ) >/dev/null 2>&1; echo "rc$?"; }
r6() { jq -nc --arg k "${4:-$K}" --arg s "$1" --argjson rc "$2" --arg p "$3" '{project:$k,status:$s,rc:$rc,prof_line:$p}'; }
check6() { local got; got=$(ru "$2"); [ "$got" = "$3" ] && ok "C6 $1" || bad "C6 $1: got $got, want $3"; }
check6 "the live #9188 shape -> rc0"      "{\"rows\":[$(r6 done 0 "$(prof READY clean-approved-checks-green -)")]}" rc0
check6 "rc null (an old worker) -> rc0"   "{\"rows\":[$(r6 done null "$(prof READY clean-approved-checks-green -)")]}" rc0
check6 "state=READYISH -> rc1"            "{\"rows\":[$(r6 done 0 "$(prof READYISH x -)")]}" rc1
check6 "state=NOT_READY -> rc1"           "{\"rows\":[$(r6 done 0 "$(prof NOT_READY x -)")]}" rc1
check6 "deferred=land -> rc1"             "{\"rows\":[$(r6 done 0 "$(prof READY x land)")]}" rc1
check6 "deferred=-x -> rc1"               "{\"rows\":[$(r6 done 0 "$(prof READY x -x)")]}" rc1
check6 "status queued -> rc1"             "{\"rows\":[$(r6 queued null "$(prof READY x -)")]}" rc1
check6 "rc 75 -> rc1"                     "{\"rows\":[$(r6 done 75 "$(prof READY x -)")]}" rc1
check6 "another key's READY row -> rc1"   "{\"rows\":[$(r6 done 0 "$(prof READY x -)" k.1.bbbbbbbbbbbb)]}" rc1
check6 "a newer WAIT_CI over READY -> rc1" "{\"rows\":[$(r6 done 0 "$(prof WAIT_CI x -)"),$(r6 done 0 "$(prof READY x -)")]}" rc1
check6 "no PROF mc-pr prefix -> rc1"      "{\"rows\":[$(r6 done 0 "PROF lane-run state=READY deferred=-")]}" rc1
check6 "an empty rows array -> rc1"       '{"rows":[]}' rc1
check6 "not JSON -> rc1"                  'not json' rc1

echo "conductor-fly-hotfix-hub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/conductor-fly-fallback.bh-6817-test.sh — BH-6817 item 3: a `failed`
# merge-conductor-pr row (the by-prefix read answers `failed` for a run with
# rc != 0) makes the next conductor tick run that PR on the hub, so a broken
# lane-run machine never drops a PR's conductor step. Project demo-os, not
# cromford: the switch is a fleet row (comment 6185730848).
#
# Driven through the REAL bin/merge-conductor.sh tick (gh and git stubbed, the
# fixture of tests/conductor-enqueue-only.bh-6495-test.sh) against the REAL
# jobs worker (tests/lib/lane-runs-worker.bh-6124.mjs), over real curl. A
# "local worker" is a PR whose CI the tick read: only pr_worker reads
# actions/runs for a head.
#
#   C1  newest row of #21's key reported rc 127 -> by-prefix `failed`
#       command-missing; the tick logs `fallback=machine-failed
#       (command-missing at <key>)` and runs #21 on the hub once, no new row
#   C2  newest row reported rc 3 -> `rc=3`, with the fallback
#   C3  newest row done rc 0 + PROF mc-pr -> no fallback, no local worker
#   C4  a queued newest row over an older failed row of the same key -> no
#       fallback (already live), no local worker
#   C5  mc_fly_failed_for itself, every `failed` shape
#
# Run from anywhere: tests/conductor-fly-fallback.bh-6817-test.sh (exit 0 = pass)
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
if [ -f "$DIR/bin/lib/mc/fly-workers.sh" ]; then
  ( cd "$DIR" && scratch_install_closure bin/lib/mc/fly-workers.sh "$T/h" ) >/dev/null || exit 1
fi
# The same seam as tests/fanin-solo.bh-4842-test.sh: gh-limit-logger.sh's gh
# function would step around tests/lib/gh-list-bridge.sh.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

NUMS="21 22 23"
# The first 40 characters with a bash substring, not `printf | head -c`: head
# exits early and the writer takes SIGPIPE under pipefail (race-sigpipe-echo).
hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
for n in $NUMS; do eval "H$n=$(hd "$n")"; done
MAIN1=1111111111111111111111111111111111111111
MAIN2=2222222222222222222222222222222222222222

LIST="["
for n in $NUMS; do
  eval "h=\$H$n"
  LIST="$LIST{\"number\":$n,\"url\":\"https://github.com/example-org/demo-os/pull/$n\",\"headRefOid\":\"$h\",\"headRefName\":\"ticket/pb-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\"},"
done
LIST="${LIST%,}]"
printf '%s\n' "$LIST" > "$T/list.json"

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
  # mc_git_auth asks gh for a token before the land ls-remote. With no token the
  # main sha is "unreadable" and no land baseline is ever recorded, so a box with
  # no GH_TOKEN (CI, a clean container) failed setup and F6.
  *"auth token"*) echo fixture-token ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# git: ls-remote answers the base sha from a control file (the land trigger,
# tests/land-rebase.bh-870-test.sh's seam); everything else is a no-op.
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
nrows() { rows | jq '[.rows[] | select(.lane == "merge-conductor-pr")] | length'; }
api() { curl -sS -X "$1" -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
          ${3:+-d "$3"} "$JOBS_URL$2"; }
# ctick [VAR=value...] — one real full tick in its own session.
ctick() {
  : > "$T/worker-reads.txt"; : > "$CLOG"
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret \
      JOBS_URL="$JOBS_URL" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
nlocal() { sort -u "$T/worker-reads.txt" | grep -c .; }
locals() { sort -u "$T/worker-reads.txt" | tr '\n' ' '; }
fanin() { grep -F 'FANIN merge-conductor example-org/demo-os:' "$CLOG" | grep -v ALERT | tail -1; }

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
ctick
grep -q 'demo-os LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" || bad "setup: no land baseline: $(grep LAND "$CLOG")"

# ran_row <pr> <rc> <prof> — a run of that PR's current head, enqueued, claimed
# and reported through the real routes, as a machine does.
ran_row() {
  local n="$1" h key args id; eval "h=\$H$n"; key="demo-os.$n.${h:0:12}"
  args=$(jq -nc --arg h "$h" --arg n "$n" '["bin/merge-conductor-pr.sh","demo-os",("example-org/demo-os#"+$n),$h]')
  id=$(api POST /api/lane-runs "$(jq -nc --arg p "$key" --argjson a "$args" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
  api POST /api/lane-runs/claim '{"machine":"m9"}' >/dev/null
  api POST "/api/lane-runs/$id/report" "$(jq -nc --argjson rc "$2" --arg pr "$3" '{machine:"m9",rc:$rc,prof:$pr}')" > "$T/report.json"
}
key() { local h; eval "h=\$H$1"; printf 'demo-os.%s.%s' "$1" "${h:0:12}"; }
byprefix() { api GET "/api/lane-runs/by-prefix?lane=merge-conductor-pr&project_prefix=demo-os.$1."; }
nreads() { grep -c "^$1\$" "$T/worker-reads.txt"; }
krows() { rows | jq --arg k "$(key "$1")" '[.rows[] | select(.project == $k)] | length'; }

# ============================================================================
echo "C1: a failed rc 127 row -> #21 runs on the hub this tick"
srv; setting conductor_workers_on_fly 1
ran_row 21 127 "PROF lane-run rc=127 reason=command-missing err=bin/merge-conductor-pr.sh not in harness unknown"
[ "$(jq -r .status "$T/report.json")" = failed ] && [ "$(jq -r .reason "$T/report.json")" = command-missing ] \
  && ok "C1 setup: the report answers failed command-missing" || bad "C1 setup: report $(cat "$T/report.json")"
B=$(byprefix 21)
[ "$(jq -r '.rows[0].status' <<<"$B")" = failed ] && [ "$(jq -r '.rows[0].reason' <<<"$B")" = command-missing ] \
  && ok "C1 setup: by-prefix lists the row failed command-missing" || bad "C1 setup: by-prefix $B"
ctick
K21=$(key 21)
grep -qF "example-org/demo-os#21 fallback=machine-failed (command-missing at $K21) — this PR runs on the hub this tick" "$CLOG" \
  && ok "C1 logs fallback=machine-failed (command-missing at $K21)" || bad "C1 log: $(grep 'demo-os#21' "$CLOG" | tail -3)"
[ "$(nreads 21)" -ge 1 ] && [ "$(locals)" = "21 " ] && ok "C1 #21 (and only #21) ran a local worker" \
  || bad "C1 local: $(locals); stderr: $(tail -3 "$T/tick.err")"
[ "$(grep -c 'example-org/demo-os#21 fallback=' "$CLOG")" = 1 ] && ok "C1 one fallback for #21 this tick" \
  || bad "C1 fallbacks: $(grep -c 'example-org/demo-os#21 fallback=' "$CLOG")"
[ "$(krows 21)" = 1 ] && ok "C1 no new row for the failed key" || bad "C1 rows of the key: $(krows 21)"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=2 skipped=0 fallback=1' "$CLOG" && ok "C1 FLY-ENQUEUE enqueued=2 fallback=1" \
  || bad "C1 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"

# ============================================================================
echo "C2: a failed rc 3 row -> rc=3, with the fallback"
srv; setting conductor_workers_on_fly 1
ran_row 22 3 "PROF lane-run rc=3 reason=exit-nonzero err=boom"
ctick
grep -qF "example-org/demo-os#22 fallback=machine-failed (rc=3 at $(key 22))" "$CLOG" \
  && ok "C2 logs fallback=machine-failed (rc=3 at <key>)" || bad "C2 log: $(grep 'demo-os#22' "$CLOG" | tail -3)"
[ "$(locals)" = "22 " ] && ok "C2 #22 ran on the hub" || bad "C2 local: $(locals)"

# ============================================================================
echo "C3: a done rc 0 row with PROF mc-pr -> no fallback"
srv; setting conductor_workers_on_fly 1
ran_row 23 0 "PROF mc-pr state=WAIT_CI reason=ci-running deferred=-"
[ "$(jq -r .status "$T/report.json")" = done ] && ok "C3 setup: the report answers done" || bad "C3 setup: $(cat "$T/report.json")"
ctick
! grep -q '#[0-9]* fallback=' "$CLOG" && ok "C3 no fallback line" || bad "C3 log: $(grep '#[0-9]* fallback=' "$CLOG")"
[ "$(nlocal)" = 0 ] && ok "C3 no local worker" || bad "C3 local: $(locals)"

# ============================================================================
echo "C4: a queued newest row over an older failed row -> no fallback"
srv; setting conductor_workers_on_fly 1
ran_row 21 127 "PROF lane-run rc=127 reason=command-missing err=x"
api POST /api/lane-runs "$(jq -nc --arg p "$(key 21)" --arg h "$H21" '{lane:"merge-conductor-pr",project:$p,args:["bin/merge-conductor-pr.sh","demo-os","example-org/demo-os#21",$h]}')" >/dev/null
[ "$(jq -r '.rows[0].status' <<<"$(byprefix 21)")" = queued ] && ok "C4 setup: the newest row is queued" || bad "C4 setup: $(byprefix 21)"
ctick
! grep -q 'demo-os#21 fallback=' "$CLOG" && ok "C4 no fallback for #21" || bad "C4 log: $(grep 'demo-os#21' "$CLOG" | tail -2)"
grep -q "example-org/demo-os#21 enqueued merge-conductor-pr $(key 21) (already live)" "$CLOG" \
  && ok "C4 #21 is already live" || bad "C4 log: $(grep 'demo-os#21' "$CLOG" | tail -2)"
[ "$(nlocal)" = 0 ] && ok "C4 no local worker" || bad "C4 local: $(locals)"

# ============================================================================
echo "C5: mc_fly_failed_for, the failed shapes"
ff() { ( . "$T/h/bin/lib/mc/fly-workers.sh" && mc_fly_failed_for "$1" k.1.aaaaaaaaaaaa ); echo " rc$?"; }
row() { jq -nc --arg s "$1" --argjson rc "$2" '{project:"k.1.aaaaaaaaaaaa",status:$s,rc:$rc,prof_line:"PROF lane-run"}'; }
check5() { [ "$(ff "$2")" = "$3" ] && ok "C5 $1" || bad "C5 $1: got '$(ff "$2")', want '$3'"; }
check5 "failed 127 -> command-missing"    "{\"rows\":[$(row failed 127)]}"                 "command-missing rc0"
check5 "failed 126 -> command-missing"    "{\"rows\":[$(row failed 126)]}"                 "command-missing rc0"
check5 "failed 3 -> rc=3"                 "{\"rows\":[$(row failed 3)]}"                   "rc=3 rc0"
check5 "done 1 (an old worker) -> rc=1"   "{\"rows\":[$(row done 1)]}"                     "rc=1 rc0"
check5 "done 127 (an old worker) -> rc=127" "{\"rows\":[$(row done 127)]}"                 "rc=127 rc0"
check5 "queued over failed -> not failed" "{\"rows\":[$(row queued null),$(row failed 127)]}" " rc1"
check5 "another key's failed row -> ok"   '{"rows":[{"project":"k.1.bbbbbbbbbbbb","status":"failed","rc":127}]}' " rc1"

echo "conductor-fly-fallback: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

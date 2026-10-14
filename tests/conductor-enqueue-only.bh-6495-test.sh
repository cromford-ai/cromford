#!/bin/bash
# tests/conductor-enqueue-only.bh-6495-test.sh — BH-6495 (BH-6047.5): with the
# settings switch conductor_workers_on_fly on, the hub's conductor tick writes
# one lane_runs row per PR (lane merge-conductor-pr, project
# <project>.<pr>.<head12>) and starts no local per-PR worker. With it off, the
# tick is today's: one local worker per PR and no row.
#
# Driven through the REAL bin/merge-conductor.sh tick (gh and git stubbed, the
# fixture of tests/fanin-solo.bh-4842-test.sh) against the REAL jobs worker on
# node:sqlite (tests/lib/lane-runs-worker.bh-6124.mjs), over real curl.
# A "local worker" is a PR whose CI the tick read: only pr_worker reads
# actions/runs for a head.
#
#   F1  no switch row -> 5 local workers, 0 rows
#   F2  fleet row 1 -> 0 local workers, 5 rows with the run key and the
#       entry's argv, 5 `enqueued` log lines, FANIN accounts enqueued:fly 5,
#       one FLY-ENQUEUE line
#   F3  per-project 0 under fleet 1 -> 5 local, 0 rows; per-project ' 1 '
#       under fleet 0 -> 0 local, 5 rows
#   F4  every enqueue answers 500 -> 5 local, 5 fallback=enqueue-failed
#   F5  a stored done row with deferred=rebase at #21's head -> #21 local
#       (fallback=machine-deferred), 4 rows; a live row at another head of
#       #22 -> #22 skipped, no worker and no new row
#   F6  a land-fire tick -> 5 local, 5 fallback=land-fire
#   F7  values yes / 2 / true / on -> off; a settings outage -> off
#   F8  MC_ON_MACHINE=1 -> never enqueues
#   F9  a failed machine run sends the PR back to the hub (lead review of
#       #6624): the newest row of the key done with rc 1, done with rc 75
#       (UNVERIFIABLE) or done with no PROF mc-pr line -> that PR runs locally
#       with fallback=machine-failed and no new row; a died row and the other
#       shapes through mc_fly_failed_for itself
#   F10 no machine claims the rows (no capacity, no fleet): a row queued
#       MC_FLY_QUEUE_STALE_S or longer -> that PR runs on the hub with
#       fallback=no-capacity, and no second row; mc_fly_stale_for itself
#
# Run from anywhere: tests/conductor-enqueue-only.bh-6495-test.sh (exit 0 = pass)
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

NUMS="21 22 23 24 25"
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
# A first tick records the land baseline, so no later case fires a land rebase
# unless it moves the sha on purpose (F6).
ctick
grep -q 'demo-os LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" || bad "setup: no land baseline: $(grep LAND "$CLOG")"

# ============================================================================
echo "F1: no switch row -> 5 local workers, 0 rows"
srv; ctick
[ "$(nlocal)" = 5 ] && ok "F1 5 local workers" || bad "F1 local workers: $(nlocal) ($(locals)); stderr: $(tail -3 "$T/tick.err")"
[ "$(nrows)" = 0 ] && ok "F1 0 lane_runs rows" || bad "F1 rows: $(nrows)"
grep -q 'enumerated 5 accounted 5' <<<"$(fanin)" && ok "F1 fan-in accounts 5" || bad "F1 fanin: $(fanin)"
! grep -q 'FLY-ENQUEUE\|enqueued merge-conductor-pr\|fallback=' "$CLOG" && ok "F1 no fly line when the switch is off" \
  || bad "F1 fly lines: $(grep -e FLY-ENQUEUE -e 'fallback=' "$CLOG")"

# ============================================================================
echo "F2: fleet row 1 -> 0 local workers, 5 rows"
srv; setting conductor_workers_on_fly 1; ctick
[ "$(nlocal)" = 0 ] && ok "F2 0 local workers" || bad "F2 local workers: $(nlocal) ($(locals)); stderr: $(tail -3 "$T/tick.err")"
R=$(rows)
[ "$(jq '[.rows[] | select(.lane == "merge-conductor-pr" and .status == "queued")] | length' <<<"$R")" = 5 ] \
  && ok "F2 5 queued merge-conductor-pr rows" || bad "F2 rows: $(jq -c '[.rows[] | {lane,project,status}]' <<<"$R")"
WANT=$(for n in $NUMS; do eval "h=\$H$n"; printf 'demo-os.%s.%s\n' "$n" "${h:0:12}"; done)
GOT=$(jq -r '.rows[] | select(.lane == "merge-conductor-pr") | .project' <<<"$R" | sort)
[ "$GOT" = "$WANT" ] && ok "F2 project is <project>.<pr>.<head12>" || bad "F2 projects: $GOT"
A21=$(jq -c '.rows[] | select(.project == "demo-os.21.'"${H21:0:12}"'") | .args' <<<"$R")
[ "$A21" = "[\"bin/merge-conductor-pr.sh\",\"demo-os\",\"example-org/demo-os#21\",\"$H21\"]" ] \
  && ok "F2 args are the machine entry, the project, the PR key and the full head" || bad "F2 args: $A21"
[ "$(grep -c 'example-org/demo-os#[0-9]* enqueued merge-conductor-pr demo-os\.' "$CLOG")" = 5 ] \
  && ok "F2 5 'enqueued' log lines" || bad "F2 enqueued lines: $(grep -c enqueued "$CLOG")"
grep -q 'enumerated 5 accounted 5 (enqueued:fly 5)' <<<"$(fanin)" && ok "F2 fan-in accounts enqueued:fly 5" || bad "F2 fanin: $(fanin)"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=5 skipped=0 fallback=0' "$CLOG" && ok "F2 one FLY-ENQUEUE line" \
  || bad "F2 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"
[ ! -s "$T/gh-writes.txt" ] && ok "F2 no GitHub write" || bad "F2 writes: $(cat "$T/gh-writes.txt")"
# The same tick again: every key is live, so 409 is still enqueued, no new row.
ctick
[ "$(nlocal)" = 0 ] && [ "$(nrows)" = 5 ] && ok "F2 a second tick: 0 local, still 5 rows (409 = already live)" \
  || bad "F2 second tick: local $(nlocal), rows $(nrows)"

# ============================================================================
echo "F3: per-project scope"
srv; setting conductor_workers_on_fly 1; setting conductor_workers_on_fly.demo-os 0; ctick
[ "$(nlocal)" = 5 ] && [ "$(nrows)" = 0 ] && ok "F3 per-project 0 under fleet 1: 5 local, 0 rows" \
  || bad "F3 off: local $(nlocal), rows $(nrows)"
srv; setting conductor_workers_on_fly 0; setting conductor_workers_on_fly.demo-os ' 1 '; ctick
[ "$(nlocal)" = 0 ] && [ "$(nrows)" = 5 ] && ok "F3 per-project ' 1 ' under fleet 0: 0 local, 5 rows" \
  || bad "F3 on: local $(nlocal), rows $(nrows)"

# ============================================================================
echo "F4: every enqueue answers 500 -> the PRs run on the hub"
srv FAIL_ENQUEUE_N=5; setting conductor_workers_on_fly 1; ctick
[ "$(nlocal)" = 5 ] && ok "F4 5 local workers" || bad "F4 local: $(nlocal)"
[ "$(nrows)" = 0 ] && ok "F4 0 rows" || bad "F4 rows: $(nrows)"
[ "$(grep -c 'fallback=enqueue-failed' "$CLOG")" = 5 ] && ok "F4 5 fallback=enqueue-failed lines" \
  || bad "F4 fallback lines: $(grep -c 'fallback=enqueue-failed' "$CLOG")"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=0 skipped=0 fallback=5' "$CLOG" && ok "F4 FLY-ENQUEUE counts 5 fallbacks" \
  || bad "F4 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"
grep -q 'enqueued:fly' <<<"$(fanin)" && bad "F4 a failed enqueue is never accounted enqueued: $(fanin)" || ok "F4 no enqueued:fly account"

# ============================================================================
echo "F5: a machine deferral and a live row at another head"
srv; setting conductor_workers_on_fly 1
K21="demo-os.21.${H21:0:12}"
ARGS21=$(jq -nc --arg h "$H21" '["bin/merge-conductor-pr.sh","demo-os","example-org/demo-os#21",$h]')
ID=$(api POST /api/lane-runs "$(jq -nc --arg p "$K21" --argjson a "$ARGS21" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
api POST /api/lane-runs/claim '{"machine":"m1"}' >/dev/null
api POST "/api/lane-runs/$ID/report" '{"machine":"m1","rc":0,"prof":"PROF mc-pr state=NEEDS_REBASE reason=conflict deferred=rebase"}' >/dev/null
OLD22="demo-os.22.0123456789ab"
api POST /api/lane-runs "$(jq -nc --arg p "$OLD22" '{lane:"merge-conductor-pr",project:$p,args:["bin/merge-conductor-pr.sh","demo-os","example-org/demo-os#22","0123456789ab0123456789ab0123456789ab0123"]}')" >/dev/null
ctick
[ "$(locals)" = "21 " ] && ok "F5 only #21 ran on the hub" || bad "F5 local: $(locals)"
grep -q 'example-org/demo-os#21 fallback=machine-deferred' "$CLOG" && ok "F5 #21 logs fallback=machine-deferred" \
  || bad "F5 log: $(grep 'demo-os#21' "$CLOG" | grep -i fly)"
grep -q 'example-org/demo-os#22 skipped:fly-live-other-head' "$CLOG" && ok "F5 #22 logs skipped:fly-live-other-head" \
  || bad "F5 #22 log: $(grep 'demo-os#22' "$CLOG" | tail -3)"
R=$(rows)
[ "$(jq '[.rows[] | select(.lane == "merge-conductor-pr" and .status == "queued")] | length' <<<"$R")" = 4 ] \
  && ok "F5 4 queued rows: #23-#25 and the old #22 head" || bad "F5 rows: $(jq -c '[.rows[] | {project,status}]' <<<"$R")"
[ "$(jq '[.rows[] | select(.project | startswith("demo-os.22."))] | length' <<<"$R")" = 1 ] \
  && ok "F5 no second #22 row while another head is live" || bad "F5 #22 rows: $(jq -c '[.rows[] | select(.project | startswith("demo-os.22.")) | .project]' <<<"$R")"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=3 skipped=1 fallback=1' "$CLOG" && ok "F5 FLY-ENQUEUE enqueued=3 skipped=1 fallback=1" \
  || bad "F5 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"

# ============================================================================
echo "F6: a land-fire tick runs every PR on the hub"
srv; setting conductor_workers_on_fly 1
echo "$MAIN2" > "$T/ctl-main-sha"; ctick
grep -q 'demo-os LAND main moved' "$CLOG" && ok "F6 setup: the land fan-out fired" || bad "F6 setup: $(grep LAND "$CLOG")"
[ "$(nlocal)" = 5 ] && [ "$(nrows)" = 0 ] && ok "F6 5 local, 0 rows" || bad "F6 local $(nlocal), rows $(nrows)"
[ "$(grep -c 'fallback=land-fire' "$CLOG")" = 5 ] && ok "F6 5 fallback=land-fire lines" || bad "F6 lines: $(grep -c 'fallback=land-fire' "$CLOG")"
# Observe mode never records a land sha, so the base goes back to the recorded
# one: a later case must not run as a land-fire tick.
echo "$MAIN1" > "$T/ctl-main-sha"

# ============================================================================
echo "F7: values that are not 1, and a settings outage, are off"
for v in yes 2 true on; do
  srv; setting conductor_workers_on_fly "$v"; ctick
  [ "$(nlocal)" = 5 ] && [ "$(nrows)" = 0 ] && ! grep -q 'LAND main moved\|fallback=' "$CLOG" \
    && ok "F7 '$v' is off" || bad "F7 '$v': local $(nlocal), rows $(nrows), $(grep -c 'LAND main moved\|fallback=' "$CLOG") land/fallback lines"
done
# A whole-worker outage stops the tick before the launch loop (the provider
# probe answers UNKNOWN), so the outage case asks the switch itself, in the
# tick's own environment, with the rows on a live worker and the URL dead.
srv; setting conductor_workers_on_fly 1; setting conductor_workers_on_fly.demo-os 1
sw() { ( export HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$1" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
         . "$T/h/bin/jobs-client.sh" && . "$T/h/bin/lib/mc/fly-workers.sh" && mc_fly_workers_on demo-os ) >/dev/null 2>&1; echo "rc$?"; }
[ "$(sw "$JOBS_URL")" = rc0 ] && ok "F7 control: the same call on the live worker is on" || bad "F7 control: $(sw "$JOBS_URL")"
[ "$(sw http://127.0.0.1:1)" = rc1 ] && ok "F7 a settings outage is off" || bad "F7 outage: $(sw http://127.0.0.1:1)"

# ============================================================================
echo "F8: a run on a machine never enqueues"
srv; setting conductor_workers_on_fly 1; ctick
[ "$(nrows)" = 5 ] && ok "F8 control: the same tick without MC_ON_MACHINE enqueues 5" || bad "F8 control: rows $(nrows)"
srv; setting conductor_workers_on_fly 1; ctick MC_ON_MACHINE=1
[ "$(nlocal)" = 5 ] && [ "$(nrows)" = 0 ] && ! grep -q 'LAND main moved\|fallback=' "$CLOG" \
  && ok "F8 MC_ON_MACHINE=1: 5 local, 0 rows" || bad "F8 local $(nlocal), rows $(nrows)"
! grep -q 'enqueued merge-conductor-pr' "$CLOG" && ok "F8 no enqueued line" || bad "F8 log: $(grep enqueued "$CLOG")"

# ============================================================================
echo "F9: a failed machine run sends the PR back to the hub"
srv; setting conductor_workers_on_fly 1
# done_row <pr> <rc> <prof> — a run of that PR's current head, claimed and
# reported as a machine would.
done_row() {
  local n="$1" h key args id; eval "h=\$H$n"; key="demo-os.$n.${h:0:12}"
  args=$(jq -nc --arg h "$h" --arg n "$n" '["bin/merge-conductor-pr.sh","demo-os",("example-org/demo-os#"+$n),$h]')
  id=$(api POST /api/lane-runs "$(jq -nc --arg p "$key" --argjson a "$args" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
  api POST /api/lane-runs/claim '{"machine":"m9"}' >/dev/null
  api POST "/api/lane-runs/$id/report" "$(jq -nc --argjson rc "$2" --arg pr "$3" '{machine:"m9",rc:$rc,prof:$pr}')" >/dev/null
}
done_row 21 1 ""
done_row 22 75 ""
done_row 23 0 "some other line"
ctick
[ "$(locals)" = "21 22 23 " ] && ok "F9 #21-#23 ran on the hub" || bad "F9 local: $(locals); stderr: $(tail -3 "$T/tick.err")"
for n in 21 22 23; do
  grep -q "example-org/demo-os#$n fallback=machine-failed" "$CLOG" && ok "F9 #$n logs fallback=machine-failed" \
    || bad "F9 #$n log: $(grep "demo-os#$n" "$CLOG" | tail -2)"
done
R=$(rows)
[ "$(jq '[.rows[] | select(.lane == "merge-conductor-pr" and .status == "queued")] | length' <<<"$R")" = 2 ] \
  && ok "F9 only #24 and #25 got a new row" || bad "F9 rows: $(jq -c '[.rows[] | {project,status,rc}]' <<<"$R")"
grep -q 'FLY-ENQUEUE example-org/demo-os enqueued=2 skipped=0 fallback=3' "$CLOG" && ok "F9 FLY-ENQUEUE enqueued=2 fallback=3" \
  || bad "F9 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"
# The pure decision, every row shape. Rows are newest first, as by-prefix answers.
ff() { ( . "$T/h/bin/lib/mc/fly-workers.sh" && mc_fly_failed_for "$1" k.1.aaaaaaaaaaaa ); echo " rc$?"; }
row() { jq -nc --arg s "$1" --argjson rc "$2" --arg pl "$3" '{project:"k.1.aaaaaaaaaaaa",status:$s,rc:$rc,prof_line:(if $pl == "" then null else $pl end)}'; }
OKP="PROF mc-pr state=WAIT_CI reason=ci-running deferred=-"
check9() { [ "$(ff "$2")" = "$3" ] && ok "F9 $1" || bad "F9 $1: got '$(ff "$2")', want '$3'"; }
check9 "died -> failed (died)"           "{\"rows\":[$(row died 137 "")]}"                      "died rc0"
check9 "done rc 1 -> failed (rc=1)"      "{\"rows\":[$(row done 1 "$OKP")]}"                    "rc=1 rc0"
check9 "done rc 75 -> failed (rc=75)"    "{\"rows\":[$(row done 75 "")]}"                       "rc=75 rc0"
check9 "done rc 0, no PROF -> failed"    "{\"rows\":[$(row done 0 "")]}"                        "no-prof rc0"
check9 "done rc 0 + PROF mc-pr -> ok"    "{\"rows\":[$(row done 0 "$OKP")]}"                    " rc1"
check9 "a live newest row -> not failed" "{\"rows\":[$(row queued null ""),$(row died 137 "")]}" " rc1"
check9 "another key's died row -> ok"    '{"rows":[{"project":"k.1.bbbbbbbbbbbb","status":"died","rc":137,"prof_line":null}]}' " rc1"
check9 "no row -> not failed"            '{"rows":[]}'                                           " rc1"

# ============================================================================
echo "F10: rows nobody claims send the PRs back to the hub"
srv; setting conductor_workers_on_fly 1; ctick
[ "$(nrows)" = 5 ] && [ "$(nlocal)" = 0 ] && ok "F10 setup: 5 queued rows, 0 local" || bad "F10 setup: rows $(nrows), local $(nlocal)"
ctick
[ "$(nlocal)" = 0 ] && ok "F10 control: a row inside the default 600 s still waits for a machine" || bad "F10 control: local $(nlocal)"
ctick MC_FLY_QUEUE_STALE_S=0
[ "$(nlocal)" = 5 ] && ok "F10 every unclaimed row runs on the hub" || bad "F10 local: $(nlocal) ($(locals))"
[ "$(grep -c 'fallback=no-capacity' "$CLOG")" = 5 ] && ok "F10 5 fallback=no-capacity lines" \
  || bad "F10 lines: $(grep -c 'fallback=no-capacity' "$CLOG")"
[ "$(nrows)" = 5 ] && ok "F10 no second row for a key" || bad "F10 rows: $(nrows)"
st() { ( . "$T/h/bin/lib/mc/fly-workers.sh" && mc_fly_stale_for "$1" k.1.aaaaaaaaaaaa 1791979200 600 ); echo " rc$?"; }
qrow() { jq -nc --arg s "$1" --arg at "$2" '{project:"k.1.aaaaaaaaaaaa",status:$s,enqueued_at:$at}'; }
check10() { [ "$(st "$2")" = "$3" ] && ok "F10 $1" || bad "F10 $1: got '$(st "$2")', want '$3'"; }
check10 "queued 11 min -> stale 660 s"   "{\"rows\":[$(qrow queued 2026-10-14T11:49:00Z)]}" "660 rc0"
check10 "queued 9 min -> not stale"      "{\"rows\":[$(qrow queued 2026-10-14T11:51:00Z)]}" " rc1"
check10 "claimed 20 min -> not stale"    "{\"rows\":[$(qrow claimed 2026-10-14T11:40:00Z)]}" " rc1"
check10 "no enqueued_at -> not stale"    '{"rows":[{"project":"k.1.aaaaaaaaaaaa","status":"queued"}]}' " rc1"

echo "conductor-enqueue-only: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/bash
# tests/conductor-fly-takeback-no-pr.bh-8238-test.sh — BH-8238 (#6895 wave 2):
# a hub tick of a project placed on a machine (lane_placement
# .merge-conductor.<p> = fly or box:<name>) never enqueues a merge-conductor-pr
# row, even when the per-PR switch conductor_workers_on_fly.<p> reads 1. A
# machine runs a merge-conductor-pr row with MC_ON_MACHINE=1 and defers every
# land, rebase and re-review to the hub, so a hub take-back (MC_PROJ_TAKEBACK=1)
# or a gate fallback to the hub that handed its PRs to those machines landed
# nothing. mc_fly_workers_on (bin/lib/mc/fly-workers.sh) answers off when the
# hub takes the project back (MC_PROJ_TAKEBACK=1) or the project carries the
# gate's mark state/merge-conductor/project-fly/<p>.placed.
#
#   D1-D11  mc_fly_workers_on, the decision table of the BH-8238 plan
#           (the real lib, the settings client stubbed)
#   W1  a keyed tick (the wake shape, MC_ONLY_PR) with MC_PROJ_TAKEBACK=1 and
#       the switch 1 -> 0 merge-conductor-pr rows, that PR ran on the hub,
#       one `per-PR fly path off` line
#   W2  a full take-back tick -> 0 rows, 5 local workers
#   W3  lane_placement fly with fallback hub; the gate cannot enqueue the
#       project row (no fresh snapshot in this fixture) and falls back to the
#       hub (rc 1) -> 0 rows, 5 local workers
#   W4  near miss: no mark, no take-back, switch 1 -> 5 rows (today's path)
#   W5  near miss: placement hub with a stale mark -> the gate removes the
#       mark, and the tick enqueues 5 rows
#
# The W cases drive the REAL bin/merge-conductor.sh tick with the fixture of
# tests/conductor-enqueue-only.bh-6495-test.sh (gh and git stubbed, the
# node:sqlite jobs worker tests/lib/lane-runs-worker.bh-6124.mjs). Each case
# starts its own worker and its own state dir; no vendor call.
#
# Run from anywhere: tests/conductor-fly-takeback-no-pr.bh-8238-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

# ============================================================================
echo "D: mc_fly_workers_on with the switch read on"
# dcase <name> <want-rc> <want-log-lines> <want-why> <project> <per-project|fleet|zero|outage>
#       <takeback> <mark-file-or-dir:content ...>
dcase() {
  local name="$1" want="$2" wantlog="$3" wantwhy="$4" p="$5" sw="$6" tb="$7"; shift 7
  local d="$T/d-$name" m got why nlog
  mkdir -p "$d/state/merge-conductor/project-fly"
  for m in "$@"; do
    case "$m" in
      dir:*) mkdir -p "$d/state/merge-conductor/project-fly/${m#dir:}" ;;
      *) printf '%s\n' "${m#*:}" > "$d/state/merge-conductor/project-fly/${m%%:*}" ;;
    esac
  done
  : > "$d/log"
  read -r got why < <(HARNESS="$d" SW="$sw" P="$p" TB="$tb" LOGF="$d/log" bash -c '
    . "$1/bin/lib/mc/fly-workers.sh" || exit 9
    _mc_fly_client() { return 0; }
    _setting_key_ok() { return 0; }
    mc_log() { printf "%s\n" "$*" >> "$LOGF"; }
    setting_get() {
      case "$SW:$1" in
        outage:*) return 1 ;;
        per-project:conductor_workers_on_fly.*) echo 1 ;;
        zero:conductor_workers_on_fly.*) echo 0 ;;
        fleet:conductor_workers_on_fly.*) return 2 ;;
        fleet:conductor_workers_on_fly) echo 1 ;;
        *) echo 0 ;;
      esac
    }
    unset MC_PROJ_TAKEBACK; [ "$TB" = - ] || export MC_PROJ_TAKEBACK="$TB"
    MC_FLY_OFF_WHY=""
    mc_fly_workers_on "$P"; echo "$? ${MC_FLY_OFF_WHY:-}"' _ "$DIR")
  nlog=$(grep -c 'per-PR fly path off' "$d/log")
  if [ "$got" = "$want" ] && [ "$nlog" = "$wantlog" ] && [ "$why" = "$wantwhy" ]; then
    ok "$name rc $want, $wantlog log line(s)${wantwhy:+, why '$wantwhy'}"
  else
    bad "$name: rc $got (want $want), log lines $nlog (want $wantlog), why '$why' (want '$wantwhy'); log: $(cat "$d/log")"
  fi
}
dcase D1  1 1 "take-back"           cromford per-project 1
dcase D2  1 1 "placed fly"          cromford per-project - cromford.placed:fly
dcase D3  1 1 "placed box:hub2"     cromford per-project - cromford.placed:box:hub2
dcase D4  1 1 "take-back"           cromford fleet       1 cromford.placed:fly
dcase D5  0 0 ""                    cromford per-project -
dcase D6  0 0 ""                    cromford per-project 0
dcase D7  0 0 ""                    cromford per-project - mk.placed:fly
dcase D8  0 0 ""                    cromford per-project - dir:cromford.placed.old cromford.placed-x:fly
dcase D9  1 0 ""                    cromford zero        1 cromford.placed:fly
dcase D10 1 0 ""                    cromford outage      - cromford.placed:fly
dcase D11 0 0 ""                    a/b           per-project -
# The log line names the project and the reason.
grep -q '^cromford per-PR fly path off: cromford is placed fly (placed box:hub2) — the hub runs this tick.s PRs itself$' \
  "$T/d-D3/log" && ok "D3 the log line names the project and the placement" || bad "D3 log: $(cat "$T/d-D3/log")"

# ============================================================================
# The whole tick. The fixture of tests/conductor-enqueue-only.bh-6495-test.sh.
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/mc/fly-workers.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/mc/project-placement.sh "$T/h" ) >/dev/null || exit 1
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

NUMS="21 22 23 24 25"
hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
LIST="["
for n in $NUMS; do
  LIST="$LIST{\"number\":$n,\"url\":\"https://github.com/example-org/demo-os/pull/$n\",\"headRefOid\":\"$(hd "$n")\",\"headRefName\":\"ticket/pb-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\"},"
done
LIST="${LIST%,}]"
printf '%s\n' "$LIST" > "$T/list.json"
# gh: the open list and CI in progress on every head. An actions/runs read of a
# head is a local pr_worker for that PR.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
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
echo 1111111111111111111111111111111111111111 > "$T/ctl-main-sha"
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
PF="$T/h/state/merge-conductor/project-fly"

PIDS=()
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  JOBS_URL="http://127.0.0.1:$PORT"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
nrows() { curl -sS "$JOBS_URL/__lane_runs" | jq '[.rows[] | select(.lane == "merge-conductor-pr")] | length'; }
# A fresh worker with the per-PR switch on for demo-os, and a clean
# project-fly state dir: every case owns its rows and its marks.
fresh() { srv || return; setting conductor_workers_on_fly.demo-os 1; scratch_rm "$PF"; mkdir -p "$PF"; }
ctick() {
  : > "$T/worker-reads.txt"; : > "$CLOG"
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret \
      JOBS_URL="$JOBS_URL" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
nlocal() { sort -u "$T/worker-reads.txt" | grep -c .; }
locals() { sort -u "$T/worker-reads.txt" | tr '\n' ' '; }
noff() { grep -c 'demo-os per-PR fly path off' "$CLOG"; }

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; echo "conductor-fly-takeback-no-pr: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
# The land baseline, so no case below fires a land rebase.
ctick
grep -q 'demo-os LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" || bad "setup: no land baseline: $(grep LAND "$CLOG")"

# ============================================================================
echo "W1: a keyed (wake) take-back tick -> no merge-conductor-pr row"
fresh; ctick MC_ONLY_PR="example-org/demo-os#22" MC_ONLY_PROJECT=demo-os MC_PROJ_TAKEBACK=1
[ "$(nrows)" = 0 ] && ok "W1 0 merge-conductor-pr rows" || bad "W1 rows: $(nrows)"
[ "$(locals)" = "22 " ] && ok "W1 #22 ran on the hub (its CI was read)" || bad "W1 local: $(locals); stderr: $(tail -3 "$T/tick.err")"
[ "$(noff)" = 1 ] && ok "W1 one 'per-PR fly path off' line" || bad "W1 off lines: $(noff); $(grep 'fly path' "$CLOG")"
grep -q 'per-PR fly path off: demo-os is placed fly (take-back)' "$CLOG" && ok "W1 the line names the take-back" \
  || bad "W1 line: $(grep 'fly path' "$CLOG")"
! grep -q 'FLY-ENQUEUE' "$CLOG" && ok "W1 no FLY-ENQUEUE line" || bad "W1 FLY-ENQUEUE: $(grep FLY-ENQUEUE "$CLOG")"

# ============================================================================
echo "W2: a full take-back tick -> 5 local workers, no row"
fresh; ctick MC_ONLY_PROJECT=demo-os MC_PROJ_TAKEBACK=1
[ "$(nrows)" = 0 ] && ok "W2 0 merge-conductor-pr rows" || bad "W2 rows: $(nrows)"
[ "$(nlocal)" = 5 ] && ok "W2 5 local workers" || bad "W2 local: $(nlocal) ($(locals)); stderr: $(tail -3 "$T/tick.err")"
[ "$(noff)" = 1 ] && ok "W2 one 'per-PR fly path off' line" || bad "W2 off lines: $(noff)"

# ============================================================================
echo "W3: placed fly, the gate falls back to the hub -> no merge-conductor-pr row"
fresh; setting lane_placement.merge-conductor.demo-os fly; setting lane_fallback.merge-conductor.demo-os hub; ctick
grep -q 'demo-os project-fly: fallback=enqueue-failed' "$CLOG" && ok "W3 the real gate fell back to the hub (enqueue-failed)" \
  || bad "W3 gate: $(grep 'project-fly' "$CLOG" | tail -3)"
[ "$(head -n 1 "$PF/demo-os.placed" 2>/dev/null)" = fly ] && ok "W3 the gate wrote the .placed mark" || bad "W3 no mark: $(ls "$PF")"
[ "$(nrows)" = 0 ] && ok "W3 0 merge-conductor-pr rows" || bad "W3 rows: $(nrows)"
[ "$(nlocal)" = 5 ] && ok "W3 5 local workers" || bad "W3 local: $(nlocal) ($(locals)); stderr: $(tail -3 "$T/tick.err")"
grep -q 'per-PR fly path off: demo-os is placed fly (placed fly)' "$CLOG" && ok "W3 the line names the placement" \
  || bad "W3 line: $(grep 'fly path' "$CLOG")"

# ============================================================================
echo "W4: near miss — no mark, no take-back -> today's 5 rows"
fresh; ctick
[ "$(nrows)" = 5 ] && ok "W4 5 merge-conductor-pr rows" || bad "W4 rows: $(nrows)"
[ "$(nlocal)" = 0 ] && ok "W4 0 local workers" || bad "W4 local: $(nlocal)"
[ "$(noff)" = 0 ] && ok "W4 no 'per-PR fly path off' line" || bad "W4 off lines: $(noff)"

# ============================================================================
echo "W5: near miss — placement hub with a stale mark -> mark removed, 5 rows"
fresh; setting lane_placement.merge-conductor.demo-os hub; echo fly > "$PF/demo-os.placed"; ctick
[ ! -e "$PF/demo-os.placed" ] && ok "W5 the gate removed the stale mark" || bad "W5 the mark is still there"
[ "$(nrows)" = 5 ] && ok "W5 5 merge-conductor-pr rows" || bad "W5 rows: $(nrows); stderr: $(tail -3 "$T/tick.err")"
[ "$(noff)" = 0 ] && ok "W5 no 'per-PR fly path off' line" || bad "W5 off lines: $(noff)"

[ ! -s "$T/gh-writes.txt" ] && ok "no GitHub write in any case" || bad "writes: $(cat "$T/gh-writes.txt")"
echo "conductor-fly-takeback-no-pr: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

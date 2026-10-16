#!/bin/bash
# tests/repair-on-push.bh-6963-test.sh — BH-6963 (BH-6542 wave 1): a push to
# main wakes repair on the PRs it touches.
#
# Driven through the REAL bin/repair-on-push.sh over real curl against the REAL
# jobs worker (tests/lib/repair-on-push-worker.bh-6963.mjs). The wake row is
# written by the real signed POST /webhooks/github (wakeOf, worker/jobs
# src/lib/core.js), so the lane parses the event string the production writer
# stores. Stubbed: mc_rebase (bin/lib/merge-conductor-lib.sh, it pushes
# branches), bor_list (bin/lib/builds-of-record.sh) and gh (fixtures on PATH).
#
#   P1  one wake, PR 11 overlaps (changed-files.txt), PR 12 does not (gh files),
#       PR 13 MERGED: 1 mc_rebase call, the REPAIR lines, cursor = max_id
#   P2  budget row 1, three overlapping PRs: 1 call, 2 `budget`, cursor below
#       the wake; P2b: rerun, PR 21 now `current`, 1 more call for PR 22
#   P3  flags/lane-off-repair-on-push: 0 calls, no wake read, cursor unchanged
#   P4  two runs on one wake: 1 call in total
#   P5  no budget row, no env: the registry default 8 (9 PRs: 8 calls, 1 budget)
#   P6  no cursor row: cursor planted at max_id, 0 calls
#   P7  lock held -> locked; stub rc 1 -> conflict; draft -> draft; QUEUED -> none
#   P8  compare answers HTTP 500: 0 calls, cursor unchanged
#   P9  a push with no range (new branch, before all zeros): no-range, cursor moves
#   P10 flags/automerge-disabled: 0 calls, cursor unchanged
#
# Run from anywhere: tests/repair-on-push.bh-6963-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/repair-on-push-worker.bh-6963.mjs"
SCRIPT_REL=bin/repair-on-push.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }

SLUG=Example-Org/example-repo
B=$(printf 'b%.0s' $(seq 1 40))
A=$(printf 'a%.0s' $(seq 1 40))
ZERO=$(printf '0%.0s' $(seq 1 40))
export LANE_REGISTRY
LANE_REGISTRY=$(cd "$DIR" && . bin/lib/lanes-registry.sh && lanes_json_path "$DIR") \
  || { echo "setup: the lane registry did not compose"; exit 1; }

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT

# fresh — a new scratch harness H and a new worker; exports JOBS_URL.
N=0
fresh() {
  N=$((N+1))
  H="$T/h$N"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$H/builds" "$T/gh$N" "$T/ghbin"
  # The stubs go in first: scratch_install_closure never overwrites a file.
  cat > "$H/bin/lib/merge-conductor-lib.sh" <<'STUB'
# stub: the conductor helpers bin/repair-on-push.sh calls
MC_LOCK_DIR="$HARNESS/locks"
mc_pr_lock() { printf '%s/merge-conductor-%s-%s.lock' "$MC_LOCK_DIR" "$1" "$2"; }
mc_rb_state() { jq -r '.status // ""' "$1" 2>/dev/null; }
mc_rebase() {
  printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >> "$STUB_CALLS"
  local n="${3##*-}" rc="${STUB_RC:-0}"
  [ -r "$STUB_DIR/rc.$n" ] && rc=$(cat "$STUB_DIR/rc.$n")
  printf 'ffffffffffffffffffffffffffffffffffffffff\n'
  return "$rc"
}
STUB
  cat > "$H/bin/lib/builds-of-record.sh" <<'STUB'
# stub: the builds of record, from a fixture TSV in the real column order
bor_list() { [ -s "$STUB_DIR/bor.tsv" ] || return 2; cat "$STUB_DIR/bor.tsv"; }
bor_local_dir() { [ -d "$HARNESS/builds/$1" ] && printf '%s\n' "$HARNESS/builds/$1"; }
STUB
  ( cd "$DIR" && scratch_install_closure "$SCRIPT_REL" "$H" && scratch_install_closure bin/jobs-client.sh "$H" \
    && scratch_install_closure bin/fleet-conf.sh "$H" ) >/dev/null 2>&1 || bad "setup: closure install"
  chmod +x "$H/bin/"*.sh
  printf 'proj %s https://proj.example /api/board 0 local -\n' "$SLUG" > "$H/fleet.conf"
  : > "$T/calls$N"; : > "$T/w$N.log"; : > "$T/w$N.port"
  export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB_CALLS="$T/calls$N" STUB_DIR="$T/gh$N" GHFIX="$T/gh$N"
  export HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
  export LANE_GATE_CACHE_S=0 BOX_NAME=hub PATH="$T/ghbin:$PATH"
  unset STUB_RC REPAIR_PUSH_BUDGET REPAIR_PUSH_WAKES
  node "$SRV" "$T/w$N.log" > "$T/w$N.port" 2> "$T/w$N.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/w$N.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$N.port")
  if [ -z "$PORT" ]; then wait "$pid"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/w$N.err")"; exit 1; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}

# The gh stub: `gh api [--paginate] <path> [--jq <expr>]` answers from
# $GHFIX/<path with / as _>.json through jq, `.err` = print it and exit 1, and a
# missing fixture is GitHub's 404. Every call is one line in $GHFIX/calls.
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'STUB'
#!/bin/bash
[ "${1:-}" = api ] || exit 0
shift; P=""; Q="."
while [ $# -gt 0 ]; do
  case "$1" in --paginate) ;; --jq) Q="$2"; shift ;; *) P="$1" ;; esac; shift
done
echo "$P" >> "$GHFIX/calls"
F="$GHFIX/$(printf '%s' "$P" | tr '/' '_')"
[ -e "$F.err" ] && { cat "$F.err" >&2; exit 1; }
[ -e "$F.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
jq -r "$Q" "$F.json"
STUB
chmod +x "$T/ghbin/gh"

run() { "$H/$SCRIPT_REL" > "$T/run.out" 2>&1; RC=$?; }
calls() { grep -c . "$STUB_CALLS"; }
cursor() { curl -sS "$JOBS_URL/__cursor" | jq -r '.cursor // "null"'; }
maxid() { curl -sS "$JOBS_URL/__cursor" | jq -r '.max_id'; }
LOGF() { printf '%s' "$H/logs/repair-on-push.log"; }
has() { grep -qF -- "$1" "$(LOGF)"; }
cnt() { grep -cF -- "$1" "$(LOGF)"; }
fx() { printf '%s' "$2" > "$GHFIX/$(printf '%s' "$1" | tr '/' '_').json"; }
push() { # push <before> <after> <delivery> — through the real webhook route
  curl -sS -X POST "$JOBS_URL/__push" -d "$(jq -nc --arg b "$1" --arg a "$2" --arg d "$3" --arg r "$SLUG" \
    '{delivery:$d, payload:{ref:"refs/heads/main", before:$b, after:$a, repository:{full_name:$r, default_branch:"main"}}}')" >/dev/null
}
merged() { # merged <file>... — the push's compare answer
  fx "repos/$SLUG/compare/$B...$A" "$(printf '%s\n' "$@" | jq -R . | jq -sc '{files: map({filename: .})}')"
}
# pr <n> [state] [draft] [cmp-status] [base] — a pr_state row, the PR's facts and
# its compare against the push. Its files come from files_cf or files_gh.
pr() {
  local n="$1" st="${2:-READY}" dr="${3:-false}" cs="${4:-behind}" base="${5:-main}"
  local head; head=$(printf '%040d' "$n")
  curl -sS -X PUT "$JOBS_URL/__pr" -d "$(jq -nc --arg r "$SLUG" --argjson n "$n" --arg s "$st" '{repo:$r,number:$n,state:$s}')" >/dev/null
  fx "repos/$SLUG/pulls/$n" "$(jq -nc --arg h "$head" --arg b "$base" --argjson d "$dr" --arg n "$n" \
    '{state:"open", draft:$d, base:{ref:$b}, head:{ref:("ticket/pr-" + $n), sha:$h}, html_url:("https://github.com/x/y/pull/" + $n)}')"
  fx "repos/$SLUG/compare/$A...$head" "{\"status\":\"$cs\"}"
}
files_gh() { local n="$1"; shift; fx "repos/$SLUG/pulls/$n/files" "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename: .})')"; }
files_cf() { # files_cf <n> <file>... — a build of record with a changed-files.txt
  local n="$1"; shift
  mkdir -p "$H/builds/proj-BH-$n-202610150000"
  printf '%s\n' "$@" > "$H/builds/proj-BH-$n-202610150000/changed-files.txt"
  printf 'BH-%s\tproj-BH-%s-202610150000\thub\t2026-10-15T00:00:00Z\tPR_OPENED\thttps://github.com/%s/pull/%s\t%s\n' \
    "$n" "$n" "$SLUG" "$n" "$n" >> "$STUB_DIR/bor.tsv"
}
plant() { run; [ "$(cursor)" != null ] || bad "setup: the first tick planted no cursor"; : > "$(LOGF)"; }

for f in "$DIR/$SCRIPT_REL" "$DIR/tests/lib/repair-on-push-worker.bh-6963.mjs" \
         "$DIR/catalog/lanes.d/repair-on-push.json" "$DIR/cron/lanes/733-repair-on-push.cron"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done

# --- P1 ----------------------------------------------------------------------
fresh; plant
push "$B" "$A" d-p1
merged src/a.js docs/x.md
pr 11; files_cf 11 src/a.js lib/b.js
pr 12; files_gh 12 lib/other.js
pr 13 MERGED; files_gh 13 src/a.js
run
[ "$RC" = 0 ] && ok "P1 exit 0" || bad "P1 rc $RC: $(cat "$T/run.out")"
[ "$(calls)" = 1 ] && ok "P1 exactly one mc_rebase call" || bad "P1 calls=$(calls): $(cat "$STUB_CALLS")"
grep -qx "$SLUG proj ticket/pr-11 $(printf '%040d' 11) https://github.com/x/y/pull/11" "$STUB_CALLS" \
  && ok "P1 the call is PR 11 with the head and branch read this tick" || bad "P1 call: $(cat "$STUB_CALLS")"
has "REPAIR pr=11 files=1 action=rebase reason=pushed repo=$SLUG wake=" && has " rc=0" \
  && ok "P1 PR 11 line: files=1 action=rebase reason=pushed rc=0" || bad "P1 PR 11 line: $(cat "$(LOGF)")"
has "REPAIR pr=12 files=0 action=skip reason=no-overlap" && ok "P1 PR 12 left alone: no-overlap" || bad "P1 PR 12 line"
has "pr=13 " && bad "P1 a MERGED PR got a line" || ok "P1 a MERGED pr_state row is not considered"
grep -qx "repos/$SLUG/compare/$B...$A" "$GHFIX/calls" && [ "$(grep -c "compare/$B" "$GHFIX/calls")" = 1 ] \
  && ok "P1 the push's changed paths are read once, from compare <before>...<after>" || bad "P1 compare calls: $(cat "$GHFIX/calls")"
grep -q "pulls/11/files" "$GHFIX/calls" && bad "P1 PR 11 files were fetched despite changed-files.txt" \
  || ok "P1 PR 11 files come from changed-files.txt (no files GET)"
grep -q "pulls/12/files" "$GHFIX/calls" && ok "P1 PR 12 files come from one GET pulls/12/files" || bad "P1 no files GET for PR 12"
[ "$(cursor)" = "$(maxid)" ] && ok "P1 cursor = max_id ($(cursor))" || bad "P1 cursor $(cursor) max $(maxid)"
has "tick wakes=1 rebased=1 budget=8" && ok "P1 tick summary" || bad "P1 summary: $(tail -1 "$(LOGF)")"

# --- P2 / P2b: a budget row of 1 ------------------------------------------------
fresh; plant
curl -sS -X PUT "$JOBS_URL/__setting" -d '{"key":"lane.repair-on-push.repair_push_budget","value":"1"}' >/dev/null
curl -sS -X PUT "$JOBS_URL/__noise" -d '{"n":1}' >/dev/null
push "$B" "$A" d-p2
for n in 21 22 23; do pr "$n"; files_gh "$n" src/a.js; done
merged src/a.js
run
WID=$(curl -sS "$JOBS_URL/__cursor" | jq -r '.push_id')
[ "$(calls)" = 1 ] && ok "P2 budget 1: one call" || bad "P2 calls=$(calls)"
[ "$(cnt "action=skip reason=budget")" = 2 ] && ok "P2 two REPAIR lines reason=budget" || bad "P2 budget lines: $(cat "$(LOGF)")"
C=$(cursor)
[ "$C" -lt "$WID" ] && ok "P2 cursor $C stays below the capped wake $WID" || bad "P2 cursor $C wake $WID"
has "wake=$WID left for next tick" && ok "P2 the capped wake is named as left for next tick" || bad "P2 no left line"
fx "repos/$SLUG/compare/$A...$(printf '%040d' 21)" '{"status":"identical"}'
: > "$(LOGF)"; run
has "REPAIR pr=21 files=1 action=skip reason=current" && ok "P2b PR 21 already contains the push: current" || bad "P2b PR 21: $(cat "$(LOGF)")"
[ "$(calls)" = 2 ] && tail -1 "$STUB_CALLS" | grep -q "ticket/pr-22 " && ok "P2b one more call, for PR 22" \
  || bad "P2b calls: $(cat "$STUB_CALLS")"
[ "$(cursor)" -lt "$WID" ] && ok "P2b PR 23 still capped: cursor below the wake" || bad "P2b cursor $(cursor)"

# --- P3: the lane flag ----------------------------------------------------------
fresh; plant
push "$B" "$A" d-p3; merged src/a.js; pr 31; files_gh 31 src/a.js
C0=$(cursor); : > "$T/w$N.log"
touch "$H/flags/lane-off-repair-on-push"
run
[ "$RC" = 0 ] && ok "P3 lane off exits 0" || bad "P3 rc $RC"
[ "$(calls)" = 0 ] && ok "P3 no mc_rebase call" || bad "P3 calls=$(calls)"
grep -q "/api/wakes" "$T/w$N.log" && bad "P3 a wake request reached the worker: $(cat "$T/w$N.log")" \
  || ok "P3 no wake or cursor request with the lane off"
[ "$(cursor)" = "$C0" ] && ok "P3 cursor unchanged" || bad "P3 cursor moved"
rm -f "$H/flags/lane-off-repair-on-push"

# --- P4: the same wake twice ----------------------------------------------------
fresh; plant
push "$B" "$A" d-p4; merged src/a.js; pr 41; files_gh 41 src/a.js
run; run
[ "$(calls)" = 1 ] && ok "P4 two ticks on one wake: one call in total" || bad "P4 calls=$(calls)"

# --- P5: the registry default ---------------------------------------------------
fresh; plant
push "$B" "$A" d-p5; merged src/a.js
for n in 51 52 53 54 55 56 57 58 59; do pr "$n"; files_gh "$n" src/a.js; done
run
[ "$(calls)" = 8 ] && ok "P5 no row and no env: budget 8 (8 calls)" || bad "P5 calls=$(calls)"
[ "$(cnt "reason=budget")" = 1 ] && has "REPAIR pr=59 " && ok "P5 the ninth PR (59) is reason=budget" || bad "P5 budget lines"

# --- P6: the first tick -----------------------------------------------------------
fresh
curl -sS -X PUT "$JOBS_URL/__noise" -d '{"n":3}' >/dev/null
push "$B" "$A" d-p6; merged src/a.js; pr 61; files_gh 61 src/a.js
run
[ "$(cursor)" = "$(maxid)" ] && [ "$(cursor)" = 4 ] && ok "P6 no cursor row: planted at max_id 4" || bad "P6 cursor $(cursor) max $(maxid)"
[ "$(calls)" = 0 ] && ok "P6 the first tick rebases nothing" || bad "P6 calls=$(calls)"
has "first tick — cursor planted at 4" && ok "P6 the plant is logged" || bad "P6 log: $(cat "$(LOGF)")"

# --- P7: lock, conflict, draft, QUEUED -------------------------------------------
fresh; plant
push "$B" "$A" d-p7; merged src/a.js
pr 71; files_gh 71 src/a.js
pr 72; files_gh 72 src/a.js; echo 1 > "$STUB_DIR/rc.72"
pr 73 READY true; files_gh 73 src/a.js
pr 74 QUEUED; files_gh 74 src/a.js
pr 75 READY false behind release; files_gh 75 src/a.js
( flock -n 9 && sleep 30 ) 9>"$H/locks/merge-conductor-proj-71.lock" &
LPID=$!; PIDS+=("$LPID"); sleep 0.3
run
has "REPAIR pr=71 files=1 action=skip reason=locked" && ok "P7 a held PR lock: locked" || bad "P7 lock: $(cat "$(LOGF)")"
grep -q "ticket/pr-71 " "$STUB_CALLS" && bad "P7 PR 71 was rebased under a held lock" || ok "P7 no call for the locked PR"
has "REPAIR pr=72 files=1 action=rebase reason=conflict" && has "rc=1" && ok "P7 stub rc 1: reason=conflict" || bad "P7 conflict"
has "REPAIR pr=73 files=1 action=skip reason=draft" && ok "P7 a draft: draft" || bad "P7 draft"
has "pr=74 " && bad "P7 a QUEUED PR got a line" || ok "P7 a QUEUED PR is not considered"
has "REPAIR pr=75 files=1 action=skip reason=base" && ok "P7 base release: base" || bad "P7 base"
[ "$(calls)" = 1 ] && ok "P7 one call in total (PR 72)" || bad "P7 calls=$(calls): $(cat "$STUB_CALLS")"
kill "$LPID" 2>/dev/null

# --- P8: compare answers 500 -------------------------------------------------------
fresh; plant
push "$B" "$A" d-p8; pr 81; files_gh 81 src/a.js
C0=$(cursor)
echo "gh: Server Error (HTTP 500)" > "$GHFIX/$(printf '%s' "repos/$SLUG/compare/$B...$A" | tr '/' '_').err"
run
[ "$RC" = 0 ] && ok "P8 exit 0" || bad "P8 rc $RC"
[ "$(calls)" = 0 ] && ok "P8 no call" || bad "P8 calls=$(calls)"
[ "$(cursor)" = "$C0" ] && ok "P8 cursor unchanged ($C0)" || bad "P8 cursor $(cursor)"
has "tick stopped, cursor stays at $C0" && ok "P8 the stop is logged" || bad "P8 log: $(cat "$(LOGF)")"

# --- P9: a wake with no range --------------------------------------------------------
fresh; plant
push "$ZERO" "$A" d-p9; pr 91; files_gh 91 src/a.js
run
has "REPAIR pr=- files=0 action=skip reason=no-range" && ok "P9 no range: no-range" || bad "P9 log: $(cat "$(LOGF)")"
[ "$(calls)" = 0 ] && [ "$(cursor)" = "$(maxid)" ] && ok "P9 no call, cursor moves past it" || bad "P9 calls=$(calls) cursor $(cursor)"

# --- P10: automerge-disabled ---------------------------------------------------------
fresh; plant
push "$B" "$A" d-p10; merged src/a.js; pr 101; files_gh 101 src/a.js
C0=$(cursor); touch "$H/flags/automerge-disabled"
run
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && ok "P10 automerge-disabled: exit 0, no call" || bad "P10 rc $RC calls=$(calls)"
[ "$(cursor)" = "$C0" ] && ok "P10 cursor unchanged" || bad "P10 cursor $(cursor)"
rm -f "$H/flags/automerge-disabled"

echo "repair-on-push.bh-6963: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

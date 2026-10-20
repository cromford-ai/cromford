#!/bin/bash
# tests/repair-on-push-files-memo.bh-7616-test.sh — BH-7616 (C3): the lane reads
# each PR's file list once per (project, PR) per tick, not once per push wake.
#
# Driven through the REAL bin/repair-on-push.sh over real curl against the REAL
# jobs worker (tests/lib/repair-on-push-worker.bh-6963.mjs), as
# tests/repair-on-push.bh-6963-test.sh does. Stubbed: mc_rebase, bor_list and gh
# (fixtures on PATH; every gh call is one line in $GHFIX/calls).
#
#   M1  3 wakes, 2 gh-files PRs, no overlap: 1 files call per PR,
#       files_get=2 files_memo=4, 6 no-overlap lines, cursor = max_id
#   M2  3 wakes, PR 51 overlaps only the third push: 1 files call, 1 mc_rebase
#       call, on the third wake
#   M3  a changed-files.txt PR and a gh PR, 2 wakes: 0 and 1 files calls,
#       files_get=1 files_memo=1
#   M4  a failed files read is not memoized: tick 1 skips, tick 2 reads again
#   M5  an empty file list is memoized: 1 call, 2 no-overlap lines, files_memo=1
#
# Run from anywhere: tests/repair-on-push-files-memo.bh-7616-test.sh (exit 0 = pass)
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
C=$(printf 'c%.0s' $(seq 1 40))
D=$(printf 'd%.0s' $(seq 1 40))
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
  printf 'ffffffffffffffffffffffffffffffffffffffff\n'
  return 0
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
  unset REPAIR_PUSH_BUDGET REPAIR_PUSH_WAKES
  : > "$GHFIX/calls"
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
pushid() { curl -sS "$JOBS_URL/__cursor" | jq -r '.push_id'; }
LOGF() { printf '%s' "$H/logs/repair-on-push.log"; }
has() { grep -qF -- "$1" "$(LOGF)"; }
cnt() { grep -cF -- "$1" "$(LOGF)"; }
ghcnt() { grep -cx -- "repos/$SLUG/$1" "$GHFIX/calls"; }
fxpath() { printf '%s/%s' "$GHFIX" "$(printf '%s' "$1" | tr '/' '_')"; }
fx() { printf '%s' "$2" > "$(fxpath "$1").json"; }
push() { # push <before> <after> <delivery> — through the real webhook route
  curl -sS -X POST "$JOBS_URL/__push" -d "$(jq -nc --arg b "$1" --arg a "$2" --arg d "$3" --arg r "$SLUG" \
    '{delivery:$d, payload:{ref:"refs/heads/main", before:$b, after:$a, repository:{full_name:$r, default_branch:"main"}}}')" >/dev/null
}
merged() { # merged <before> <after> <file>... — the push's compare answer
  local b="$1" a="$2"; shift 2
  fx "repos/$SLUG/compare/$b...$a" "$(printf '%s\n' "$@" | jq -R . | jq -sc '{files: map({filename: .})}')"
}
# pr <n> — a READY pr_state row and the PR's facts. The compare of a push
# against the PR head is set per wake with pr_cmp.
pr() {
  local n="$1" head; head=$(printf '%040d' "$1")
  curl -sS -X PUT "$JOBS_URL/__pr" -d "$(jq -nc --arg r "$SLUG" --argjson n "$n" '{repo:$r,number:$n,state:"READY"}')" >/dev/null
  fx "repos/$SLUG/pulls/$n" "$(jq -nc --arg h "$head" --arg n "$n" \
    '{state:"open", draft:false, base:{ref:"main"}, head:{ref:("ticket/pr-" + $n), sha:$h}, html_url:("https://github.com/x/y/pull/" + $n)}')"
}
pr_cmp() { fx "repos/$SLUG/compare/$2...$(printf '%040d' "$1")" "{\"status\":\"$3\"}"; } # pr_cmp <n> <after> <status>
files_gh() { local n="$1"; shift; fx "repos/$SLUG/pulls/$n/files" "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename: .})')"; }
files_cf() { # files_cf <n> <file>... — a build of record with a changed-files.txt
  local n="$1"; shift
  mkdir -p "$H/builds/proj-BH-$n-202610150000"
  printf '%s\n' "$@" > "$H/builds/proj-BH-$n-202610150000/changed-files.txt"
  printf 'BH-%s\tproj-BH-%s-202610150000\thub\t2026-10-15T00:00:00Z\tPR_OPENED\thttps://github.com/%s/pull/%s\t%s\n' \
    "$n" "$n" "$SLUG" "$n" "$n" >> "$STUB_DIR/bor.tsv"
}
plant() { run; [ "$(cursor)" != null ] || bad "setup: the first tick planted no cursor"; : > "$(LOGF)"; : > "$GHFIX/calls"; }
three_wakes() { # pushes B..A, A..C, C..D; each push changes one docs file
  push "$B" "$A" "d-$1-1"; push "$A" "$C" "d-$1-2"; push "$C" "$D" "d-$1-3"
  merged "$B" "$A" docs/one.md; merged "$A" "$C" docs/two.md; merged "$C" "$D" docs/three.md
}

# --- M1: 3 wakes, 2 PRs, no overlap ---------------------------------------------
fresh; plant
three_wakes m1
pr 41; files_gh 41 src/x.js
pr 42; files_gh 42 src/y.js lib/z.js
run
[ "$RC" = 0 ] && ok "M1 exit 0" || bad "M1 rc $RC: $(cat "$T/run.out")"
[ "$(cnt "range=")" = 3 ] && ok "M1 three push wakes read in one tick" || bad "M1 wakes: $(cat "$(LOGF)")"
[ "$(ghcnt pulls/41/files)" = 1 ] && ok "M1 PR 41 files read once over 3 wakes" || bad "M1 PR 41 files calls=$(ghcnt pulls/41/files)"
[ "$(ghcnt pulls/42/files)" = 1 ] && ok "M1 PR 42 files read once over 3 wakes" || bad "M1 PR 42 files calls=$(ghcnt pulls/42/files)"
has "files_get=2 files_memo=4" && ok "M1 tick line: files_get=2 files_memo=4" || bad "M1 tick line: $(grep 'tick wakes=' "$(LOGF)")"
[ "$(cnt "files=0 action=skip reason=no-overlap")" = 6 ] && [ "$(cnt "REPAIR pr=41 files=0 action=skip reason=no-overlap")" = 3 ] \
  && ok "M1 six no-overlap lines (2 PRs x 3 wakes), memo answers judged as live ones" || bad "M1 lines: $(cat "$(LOGF)")"
[ "$(calls)" = 0 ] && ok "M1 no mc_rebase call" || bad "M1 calls=$(calls)"
[ "$(cursor)" = "$(maxid)" ] && ok "M1 cursor = max_id ($(cursor))" || bad "M1 cursor $(cursor) max $(maxid)"

# --- M2: PR 51 overlaps only the third push ----------------------------------------
fresh; plant
three_wakes m2
pr 51; files_gh 51 docs/three.md src/x.js; pr_cmp 51 "$D" behind
run
[ "$(ghcnt pulls/51/files)" = 1 ] && ok "M2 PR 51 files read once" || bad "M2 files calls=$(ghcnt pulls/51/files)"
[ "$(calls)" = 1 ] && grep -qx "$SLUG proj ticket/pr-51 $(printf '%040d' 51) https://github.com/x/y/pull/51" "$STUB_CALLS" \
  && ok "M2 one mc_rebase call, for PR 51" || bad "M2 calls: $(cat "$STUB_CALLS")"
W3=$(pushid)
has "REPAIR pr=51 files=1 action=rebase reason=pushed repo=$SLUG wake=$W3 rc=0" \
  && ok "M2 the rebase is on the third wake ($W3), judged from the memo" || bad "M2 rebase line: $(cat "$(LOGF)")"
[ "$(cnt "REPAIR pr=51 files=0 action=skip reason=no-overlap")" = 2 ] && ok "M2 two no-overlap lines before it" \
  || bad "M2 no-overlap lines: $(cat "$(LOGF)")"
has "files_get=1 files_memo=2" && ok "M2 tick line: files_get=1 files_memo=2" || bad "M2 tick line: $(grep 'tick wakes=' "$(LOGF)")"

# --- M3: changed-files.txt is read first and is not a files call ------------------------
fresh; plant
push "$B" "$A" d-m3-1; push "$A" "$C" d-m3-2
merged "$B" "$A" docs/one.md; merged "$A" "$C" docs/two.md
pr 61; files_cf 61 src/a.js
pr 62; files_gh 62 src/b.js
run
[ "$(ghcnt pulls/61/files)" = 0 ] && ok "M3 changed-files.txt PR: 0 files calls" || bad "M3 PR 61 files calls=$(ghcnt pulls/61/files)"
[ "$(ghcnt pulls/62/files)" = 1 ] && ok "M3 gh PR: 1 files call over 2 wakes" || bad "M3 PR 62 files calls=$(ghcnt pulls/62/files)"
has "files_get=1 files_memo=1" && ok "M3 tick line: files_get=1 files_memo=1" || bad "M3 tick line: $(grep 'tick wakes=' "$(LOGF)")"
[ "$(cnt "reason=no-overlap")" = 4 ] && ok "M3 both PRs judged on both wakes" || bad "M3 lines: $(cat "$(LOGF)")"

# --- M4: a failed files read is not memoized -------------------------------------------
fresh; plant
push "$B" "$A" d-m4-1; merged "$B" "$A" docs/one.md
pr 71; files_gh 71 src/x.js
echo "gh: Server Error (HTTP 502)" > "$(fxpath "repos/$SLUG/pulls/71/files").err"
W1=$(pushid)
run
has "REPAIR pr=71 files=0 action=skip reason=files-unreadable" && ok "M4 tick 1: files-unreadable" || bad "M4 tick 1: $(cat "$(LOGF)")"
C1=$(cursor)
[ "$C1" -lt "$W1" ] && ok "M4 tick 1: cursor $C1 stays below the wake $W1" || bad "M4 cursor $C1 wake $W1"
has "files_get=1 files_memo=0" && ok "M4 tick 1: files_get=1 files_memo=0" || bad "M4 tick 1 line: $(grep 'tick wakes=' "$(LOGF)")"
rm -f "$(fxpath "repos/$SLUG/pulls/71/files").err"
: > "$(LOGF)"
run
[ "$(ghcnt pulls/71/files)" = 2 ] && ok "M4 tick 2 reads the files again (2 calls in total)" || bad "M4 files calls=$(ghcnt pulls/71/files)"
has "REPAIR pr=71 files=0 action=skip reason=no-overlap" && ok "M4 tick 2: PR 71 judged" || bad "M4 tick 2: $(cat "$(LOGF)")"
has "files_get=1 files_memo=0" && ok "M4 tick 2: files_get=1" || bad "M4 tick 2 line: $(grep 'tick wakes=' "$(LOGF)")"
[ "$(cursor)" = "$(maxid)" ] && ok "M4 tick 2: cursor = max_id ($(cursor))" || bad "M4 cursor $(cursor) max $(maxid)"

# --- M5: an empty file list is memoized -------------------------------------------------
fresh; plant
push "$B" "$A" d-m5-1; push "$A" "$C" d-m5-2
merged "$B" "$A" docs/one.md; merged "$A" "$C" docs/two.md
pr 81; fx "repos/$SLUG/pulls/81/files" '[]'
run
[ "$(ghcnt pulls/81/files)" = 1 ] && ok "M5 empty list: 1 files call over 2 wakes" || bad "M5 files calls=$(ghcnt pulls/81/files)"
[ "$(cnt "REPAIR pr=81 files=0 action=skip reason=no-overlap")" = 2 ] && ok "M5 two no-overlap lines" || bad "M5 lines: $(cat "$(LOGF)")"
has "files_get=1 files_memo=1" && ok "M5 tick line: files_get=1 files_memo=1" || bad "M5 tick line: $(grep 'tick wakes=' "$(LOGF)")"
[ "$(cursor)" = "$(maxid)" ] && ok "M5 cursor = max_id ($(cursor))" || bad "M5 cursor $(cursor) max $(maxid)"

echo "repair-on-push-files-memo.bh-7616: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

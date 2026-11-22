#!/bin/bash
# tests/pool-cheap-list.bh-9440-test.sh — BH-9440 C3: a queued pool part with no
# file list gets bin/planned-files-cheap.sh's first list (free tiers only)
# before the sibling-serial check, so its hold names a FILE, not
# "(no pre-plan list)".
#
#   L1  TK-142.2 queued with no list, its row body naming src/x/board.tsx, and
#       TK-142.1 in flight planning src/x/board.tsx: the cheap list is written
#       (SOURCE: ticket-body), the hold line names src/x/board.tsx, the list
#       source is `cheap`, and the run had PLANNED_FILES_FREE_ONLY=1
#   L2  a second tick within POOL_CHEAP_LIST_TTL_S (6 h) does not run it again
#       even after the list is removed; past the window it runs once more
#   L3  a key with a plans-dir list gets no run; a list-less key that is not a
#       part gets one too (its hub list feeds the overlap guard)
#   W   the two parts that declare one file: .2 waits while .1 builds; when .1
#       is done (its machine gone), .2 spawns
#
# Driven through bin/fly-pool.sh against a scratch HARNESS (the
# tests/fly-pool-sibling-serial.bh-6374-test.sh scaffold): no repo slug, so the
# body comes from the queue row, and no GitHub read is possible.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN PLANNED_FILES_FREE_ONLY POOL_CHEAP_LIST_TTL_S
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
H="$T/h"
QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"; PM="$H/state/pool-marks/project-5"; MD="$H/state/fly-pool/project-5"
# The wait clock is box-local, not a pool row (catalog/state-paths.json).
SD="$H/state/sibling-serial/project-5"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/project-5" \
         "$PD" "$SD" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 - - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The alert stub is written BEFORE the closure installs, which never clobbers it.
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || bad "closure install of bin/sibling-serial.sh failed"
# The jobs client, so the job_claims rows can be read (P4c). With no JOBS_URL
# configured, every other case reads as before: no worker.
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure install of bin/jobs-client.sh failed"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" \
         "$H/bin/alert-line.sh" "$T/fakebin"/*

write_fly_stub() { # write_fly_stub [RESULT] [only-machine]
  local result="${1:-}" only="${2:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"$only"*"head"*"RESULT"*|*"ssh console"*"head"*"RESULT"*"$only"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" \
           SIBLING_SERIAL_NOW="$NOW" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$PM"/* "$SD"/* "$H/plans"/* "$T/alert-calls" "$T/fly-calls"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/project-5-$k"
  printf '%s\n' "$@" > "$H/plans/project-5-$k/planned-files.txt"
}
queue() { # queue <KEY> <ticket-id> [enqueued_at]
  jq -nc --arg k "$1" --arg t "$2" --arg e "${3:-2026-10-13T02:30:00Z}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:$e}' > "$QD/$1.json"
}
machine() { # machine <id> <KEY> <ticket-id> — a live machine building KEY
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-13T02:30:00Z"}' \
    > "$MD/$1.json"
}
machine_for() { grep -ls "\"key\": *\"$1\"" "$MD"/*.json 2>/dev/null | grep -c .; }
spawns_of() { grep -c . "$PD/$1.spawns" 2>/dev/null || echo 0; }
# The real cheap-list script behind a wrapper that records what it was given.
( cd "$DIR" && scratch_install_closure bin/planned-files-cheap.sh "$H" ) >/dev/null || { echo "setup: could not install bin/planned-files-cheap.sh"; exit 1; }
mv "$H/bin/planned-files-cheap.sh" "$H/bin/planned-files-cheap.real.sh"
printf '#!/bin/bash\necho "$1 $2 free=${PLANNED_FILES_FREE_ONLY:-unset} body=${PLANNED_FILES_BODY_FILE:+yes}" >> "%s/cheap-calls"\nexec "$(dirname "$0")/planned-files-cheap.real.sh" "$@"\n' "$T" > "$H/bin/planned-files-cheap.sh"
chmod +x "$H/bin/planned-files-cheap.sh"
mkdir -p "$T/repos"   # REPOS_ROOT: no checkout, so every named path is kept
qbody() { # qbody <KEY> <ticket-id> <body> — a queued row that carries its body
  jq -nc --arg k "$1" --arg t "$2" --arg b "$3" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z",body:$b}' > "$QD/$1.json"
}
calls() { local n; n=$(grep -c "^project-5 $1 " "$T/cheap-calls" 2>/dev/null); echo "${n:-0}"; }
pool() { run_pool REPOS_ROOT="$T/repos" "$@"; }
lfix() { # .1 builds src/x/board.tsx; .2 is queued with no list, its body names the file
  reset_state; : > "$T/cheap-calls"; { [ -e "$H/plans/project-5-TK-142.2" ] && scratch_rm "$H/plans/project-5-TK-142.2"; }
  write_fly_stub ""
  plan_files TK-142.1 src/x/board.tsx
  machine m-one TK-142.1 1421
  qbody TK-142.2 1422 'Add the lane badge in `src/x/board.tsx` next to the header.'
}

# ── L1 ──────────────────────────────────────────────────────────────────────
lfix
pool
L="$H/plans/project-5-TK-142.2/planned-files.txt"
[ "$(head -n 1 "$L" 2>/dev/null)" = "SOURCE: ticket-body" ] && grep -qx 'src/x/board.tsx' "$L" && ok \
  || bad "L1: THE GAP: a cheap list for TK-142.2 ($(cat "$L" 2>/dev/null || echo none); calls: $(cat "$T/cheap-calls"))"
grep -q 'SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx' "$H/logs/fly-pool.log" && ok \
  || bad "L1: the hold line names the file: $(grep TK-142.2 "$H/logs/fly-pool.log" | tail -3)"
grep -q 'TK-142.2 waits for TK-142.1 on (no pre-plan list)' "$H/logs/fly-pool.log" && bad "L1: the hold is not blind any more" || ok
grep -q 'list sources: TK-142.2=cheap' "$H/logs/fly-pool.log" && ok || bad "L1: the list source is named cheap: $(grep 'list sources' "$H/logs/fly-pool.log" | tail -1)"
grep -q '^project-5 TK-142.2 free=1 body=yes$' "$T/cheap-calls" && ok || bad "L1: free tiers only, the row body handed over: $(cat "$T/cheap-calls")"
[ "$(machine_for TK-142.2)" = 0 ] && ok || bad "L1: no machine for .2 while .1 builds"
[ -s "$PM/TK-142.2.cheap-at" ] && ok || bad "L1: the back-off marker is written"

# ── L2: the 6 h back-off ────────────────────────────────────────────────────
{ [ -e "$H/plans/project-5-TK-142.2" ] && scratch_rm "$H/plans/project-5-TK-142.2"; }
pool
[ "$(calls TK-142.2)" = 1 ] && ok || bad "L2: no second run inside the window ($(calls TK-142.2) runs)"
grep -q 'TK-142.2 waits for TK-142.1 on (no pre-plan list)' "$H/logs/fly-pool.log" && ok \
  || bad "L2: with no list and the window open, the hold is blind as before: $(grep TK-142.2 "$H/logs/fly-pool.log" | tail -2)"
printf '%s\n' "$((NOW - 21601))" > "$PM/TK-142.2.cheap-at"
pool
[ "$(calls TK-142.2)" = 2 ] && ok || bad "L2: past the window it runs again ($(calls TK-142.2) runs)"
pool POOL_CHEAP_LIST_TTL_S=0
[ "$(calls TK-142.2)" = 2 ] && ok || bad "L2: a list on disk is never re-made ($(calls TK-142.2) runs)"

# ── L3: a listed key, a non-part key ────────────────────────────────────────
lfix
plan_files TK-142.2 src/x/board.tsx
qbody BH-1016 1016 'Touch `src/y/other.ts`.'
pool
[ "$(calls TK-142.2)" = 0 ] && ok || bad "L3: no run for a listed key: $(cat "$T/cheap-calls")"
[ "$(calls BH-1016)" = 1 ] && grep -qx 'src/y/other.ts' "$H/plans/project-5-BH-1016/planned-files.txt" 2>/dev/null && ok \
  || bad "L3: a list-less non-part key gets its first list: $(cat "$T/cheap-calls")"

# ── W: .2 waits on the shared file, then spawns when .1 is done ─────────────
lfix
pool
[ "$(machine_for TK-142.2)" = 0 ] && grep -q 'TK-142.2 waits for TK-142.1 on src/x/board.tsx' "$H/logs/fly-pool.log" && ok \
  || bad "W: .2 waits for .1 on the file: $(grep TK-142.2 "$H/logs/fly-pool.log" | tail -2)"
scratch_rm "$MD/m-one.json"
pool
[ "$(machine_for TK-142.2)" = 1 ] && ok || bad "W: .2 spawns once .1 is done: $(grep TK-142.2 "$H/logs/fly-pool.log" | tail -3)"

[ -z "${GH_TOKEN:-}" ] && ok || bad "no token in the test"
echo "pool-cheap-list.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

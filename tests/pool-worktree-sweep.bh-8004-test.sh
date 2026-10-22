#!/bin/bash
# tests/pool-worktree-sweep.bh-8004-test.sh — a reused pool machine removes the
# worktrees of earlier jobs before the disk guard, and a disk deferral names the
# machine (BH-8004).
#
#   W1  the REAL _run_job (lifted from fly/builder-runner.sh), POOL_MODE=1, a
#       stale registered worktree under the worktrees root and a df that says
#       100% while it exists: the sweep removes it BEFORE the disk guard reads
#       df, the guard passes and run-build.sh runs once
#   W2  the same, but a live process has its cwd in the stale dir: it is kept
#       (busy), the guard defers with a RESULT that names the machine id inside
#       the hub's 120-char DWHY, and one fleet_alert beat names it too
#   W3  bin/pool-worktree-sweep.sh against the plan's decision table, row by row
#   W4  a removed registered worktree keeps its branch and commit in the repo,
#       and `git worktree list` no longer lists it
#   W5  rc 2 and nothing removed: no --root, a relative root, root /, no <proc>/self
#   W6  a removal that fails is counted failed, never removed
#   W7  the sweep script absent: the runner logs it and the build goes on
#   W8  POOL_MODE unset: the sweep is never called
#   W9  the W2 RESULT through the hub's lifted pool_overlap_deferral and
#       pool_lane_failure: neither claims it, and it is not a dirty-machine line
# Run from anywhere: bash tests/pool-worktree-sweep.bh-8004-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
unset HOTFIX BUILDER_EXEC POOL_MODE POOL_WORKTREES_ROOT FLY_MACHINE_ID
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "pool-worktree-sweep.bh-8004: jq absent — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "pool-worktree-sweep.bh-8004: git absent — skipping"; exit 0; }
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

HOLDERS=()
trap 'for p in "${HOLDERS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done' EXIT
# busy_in <dir> -> a background process with its cwd in <dir>; sets BP
busy_in() {
  ( cd "$1" && exec sleep 300 ) </dev/null >/dev/null 2>&1 &  # determinism: ok a cwd holder, killed by drop or the EXIT trap
  BP=$!; HOLDERS+=("$BP")
  local i=0; while [ "$(readlink -f "/proc/$BP/cwd" 2>/dev/null)" != "$(readlink -f "$1")" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded wait for the holder's cd, 5s cap
}
drop() { kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# mkrepo <dir> -> a scratch repo with one commit on main
mkrepo() {
  git init -q -b main "$1" && git -C "$1" commit -q --allow-empty -m base
}
# mkwt <repo> <path> <branch> -> a registered worktree with one commit of its own
mkwt() {
  git -C "$1" worktree add -q -b "$3" "$2" main && git -C "$2" commit -q --allow-empty -m "work on $3"
}

H="$T/h"
mkdir -p "$H/logs" "$H/bin" "$H/builds" "$T/path" "$T/job"
scratch_install_closure bin/pool-worktree-sweep.sh "$H" >/dev/null 2>&1 || bad "bin/pool-worktree-sweep.sh could not be installed into the scratch harness"
SW="$H/bin/pool-worktree-sweep.sh"

# ═══ the runner: the real slot_preflight, pool_worktree_sweep and _run_job ═══
awk '/^slot_preflight\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/runner.sh"
awk '/^pool_worktree_sweep\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" >> "$T/runner.sh"
grep -q 'pool-worktree-sweep.sh' "$T/runner.sh" && ok || bad "could not extract pool_worktree_sweep from fly/builder-runner.sh"
awk '/^_run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" >> "$T/runner.sh"
grep -q 'warm_up' "$T/runner.sh" && ok || bad "could not extract _run_job from fly/builder-runner.sh"
printf '#!/bin/bash\necho "gh $*" >> "%s/called"\nexit 0\n' "$T" > "$T/path/gh"; chmod +x "$T/path/gh"
printf '#!/bin/bash\necho "run-build.sh $*" >> "%s/called"\nexit 0\n' "$T" > "$H/bin/run-build.sh"; chmod +x "$H/bin/run-build.sh"
# df: the disk guard's `df --output=pcent` answers 100% while the stale dir is
# on disk and 40% once it is gone, and records which it saw; every other df
# (the sweep's own freed_kb read) is the real one.
REAL_DF=$(command -v df)
cat > "$T/path/df" <<EOF
#!/bin/bash
case "\$*" in
  *--output=pcent*)
    if [ -e "\$STALE_DIR" ]; then echo "guard-saw-stale" >> "$T/df-calls"; printf 'Use%%\n100%%\n'
    else echo "guard-saw-clean" >> "$T/df-calls"; printf 'Use%%\n 40%%\n'; fi ;;
  *) exec "$REAL_DF" "\$@" ;;
esac
EOF
chmod +x "$T/path/df"

# runner <root> <stale-dir> [POOL_MODE] -> RESULT, $T/called, $T/df-calls, $T/log, $T/beats
runner() {
  rm -f "$T/called" "$T/df-calls" "$T/log" "$T/beats" "$T/job/RESULT"
  printf '%s\n' '{"key":"TK-1582","ticket_id":"1582"}' > "$T/job/job.json"
  timeout 60 env PATH="$T/path:$PATH" HARNESS="$H" JOB="$T/job/job.json" JOBDIR="$T/job" RESULT_FILE="$T/job/RESULT" \
      PROJECT=project-6-os REPO="$T/repo" POOL_MODE="${3:-}" POOL_WORKTREES_ROOT="$1" STALE_DIR="$2" \
      FLY_MACHINE_ID=m-fixture-8004 TT="$T" \
      bash -c '
    [ -n "$POOL_MODE" ] || unset POOL_MODE
    log() { echo "$*" >> "$TT/log"; }; load_env() { :; }; model_routes_warm() { :; }
    start_heartbeat() { :; }; stop_heartbeat() { :; }; fly_result_put() { :; }
    beat() { echo "$1" >> "$TT/beats"; }
    warm_up() { echo warm_up >> "$TT/called"; return 0; }
    . "$0"; _run_job' "$T/runner.sh" >/dev/null 2>&1
  RESULT=$(head -1 "$T/job/RESULT" 2>/dev/null)
}

# ═══ W1 a stale worktree is gone before the disk guard reads df ══════════════
R1="$T/w1"; mkdir -p "$R1/worktrees"; mkrepo "$R1/repo"
mkwt "$R1/repo" "$R1/worktrees/project-6-os-TK-1861" ticket/TK-1861
mkdir -p "$R1/worktrees/project-6-os-TK-1582/src" "$R1/worktrees/project-6-os-slot1/node_modules"
runner "$R1/worktrees" "$R1/worktrees/project-6-os-TK-1861" 1
[ ! -e "$R1/worktrees/project-6-os-TK-1861" ] && ok || bad "W1: the stale worktree survived the build"
[ -d "$R1/worktrees/project-6-os-TK-1582/src" ] && ok || bad "W1: the current key's worktree (key TK-1582) was removed"
[ -d "$R1/worktrees/project-6-os-slot1/node_modules" ] && ok || bad "W1: the warm_up pre-seed project-6-os-slot1 was removed"
[ "$(cat "$T/df-calls" 2>/dev/null)" = guard-saw-clean ] && ok \
  || bad "W1: the disk guard must read df once, after the sweep: $(tr '\n' '|' < "$T/df-calls" 2>/dev/null)"
[ "$(grep -c '^run-build.sh ' "$T/called" 2>/dev/null)" = 1 ] && ok || bad "W1: run-build.sh must run once: $(tr '\n' '|' < "$T/called" 2>/dev/null)"
[[ "$RESULT" == "BUILD_DEFERRED disk"* ]] && bad "W1: the build deferred on disk: $RESULT" || ok
grep -q '^worktree sweep: WTSWEEP ok removed=1 busy=0 kept=2 failed=0 freed_kb=[0-9]* (rc=0)$' "$T/log" 2>/dev/null && ok \
  || bad "W1: the runner must log the sweep's line: $(grep 'worktree sweep' "$T/log" 2>/dev/null)"
grep -q '^warm_up$' "$T/called" 2>/dev/null && ok || bad "W1: warm_up did not run after the sweep"

# ═══ W2 a busy stale dir is kept; the deferral names the machine ═════════════
R2="$T/w2"; mkdir -p "$R2/worktrees/project-6-os-TK-1861"
busy_in "$R2/worktrees/project-6-os-TK-1861"; B2=$BP
runner "$R2/worktrees" "$R2/worktrees/project-6-os-TK-1861" 1
drop "$B2"
[ -d "$R2/worktrees/project-6-os-TK-1861" ] && ok || bad "W2: a worktree a live process uses was removed"
W2RESULT=$RESULT
[[ "$RESULT" == "BUILD_DEFERRED disk 100% used on /data on machine m-fixture-8004 (WTSWEEP ok removed=0 busy=1"* ]] && ok \
  || bad "W2: the disk RESULT must name the machine and the sweep, got '$RESULT'"
[[ "${RESULT:0:120}" == *m-fixture-8004* ]] && ok || bad "W2: the machine id is not inside the hub's 120-char DWHY: '$RESULT'"
[ "$(grep -c '"kind":"fleet_alert"' "$T/beats" 2>/dev/null)" = 1 ] && ok || bad "W2: exactly one fleet_alert beat expected: $(cat "$T/beats" 2>/dev/null)"
jq -e 'select(.kind=="fleet_alert") | (.machine=="m-fixture-8004") and (.detail|contains("m-fixture-8004"))' "$T/beats" >/dev/null 2>&1 && ok \
  || bad "W2: the fleet_alert beat must carry the machine id: $(grep fleet_alert "$T/beats" 2>/dev/null)"
grep -q '^run-build.sh ' "$T/called" 2>/dev/null && bad "W2: run-build.sh ran on a full disk" || ok

# ═══ W3 the decision table, through the script ═══════════════════════════════
R3="$T/w3"; WR="$R3/worktrees"; mkdir -p "$WR" "$R3/outside"; echo keep > "$R3/outside/file"
mkrepo "$R3/repo"
mkwt "$R3/repo" "$WR/project-6-os-TK-1861" ticket/TK-1861
W4SHA=$(git -C "$WR/project-6-os-TK-1861" rev-parse HEAD)
mkdir -p "$WR/project-6-os-TK-15820" "$WR/project-6-os-slot10" "$WR/other-project-x/sub" "$WR/.leftover" \
         "$WR/project-6-os-TK-1582" "$WR/project-6-os-slot1" "$WR/project-6-os-TK-1700/apps/web" \
         "$WR/project-6-os-TK-1701" "$WR/project-6-os-TK-17"
ln -s "$R3/outside" "$WR/link-out"
busy_in "$WR/project-6-os-TK-1700/apps/web"; B3A=$BP
busy_in "$WR/project-6-os-TK-1701"; B3B=$BP
OUT=$("$SW" --root "$WR" --keep project-6-os-TK-1582 --keep project-6-os-slot1 --harness "$H" 2>/dev/null); RC=$?
drop "$B3A"; drop "$B3B"
[ "$RC" = 0 ] && ok || bad "W3: rc=$RC out=$OUT"
for n in project-6-os-TK-1861 project-6-os-TK-15820 project-6-os-slot10 other-project-x .leftover link-out project-6-os-TK-17; do
  { [ ! -e "$WR/$n" ] && [ ! -L "$WR/$n" ]; } && ok || bad "W3: $n must be removed"
done
for n in project-6-os-TK-1582 project-6-os-slot1 project-6-os-TK-1700 project-6-os-TK-1701; do
  [ -d "$WR/$n" ] && ok || bad "W3: $n must be kept"
done
[ -d "$WR/project-6-os-TK-1700/apps/web" ] && ok || bad "W3: the busy worktree's contents were touched"
[ "$(cat "$R3/outside/file" 2>/dev/null)" = keep ] && ok || bad "W3: the symlink's target was followed"
[[ "$OUT" =~ ^WTSWEEP\ ok\ removed=7\ busy=2\ kept=2\ failed=0\ freed_kb=[0-9]+$ ]] && ok || bad "W3: summary line '$OUT'"
grep -q 'busy project-6-os-TK-1700 pid=' "$H/logs/pool-worktree-sweep.log" 2>/dev/null && ok || bad "W3: a busy entry must be logged with its pid"

# ═══ W4 the removed worktree's branch and commit survive ═════════════════════
[ "$(git -C "$R3/repo" rev-parse ticket/TK-1861 2>/dev/null)" = "$W4SHA" ] && ok || bad "W4: branch ticket/TK-1861 lost its commit"
WTL=$(git -C "$R3/repo" worktree list 2>&1)
grep -q 'project-6-os-TK-1861' <<<"$WTL" && bad "W4: git worktree list still lists the removed worktree" || ok

# ═══ W5 refusals remove nothing ══════════════════════════════════════════════
R5="$T/w5"; mkdir -p "$R5/relative/dir/x" "$R5/worktrees/x" "$R5/noproc"
OUT=$("$SW" --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && [[ "$OUT" == "WTSWEEP unreadable "* ]] && ok || bad "W5: no --root must be rc 2 (rc=$RC out=$OUT)"
OUT=$(cd "$R5" && "$SW" --root relative/dir --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && [ -d "$R5/relative/dir/x" ] && ok || bad "W5: a relative root must be rc 2 and remove nothing (rc=$RC out=$OUT)"
OUT=$("$SW" --root / --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "W5: root / must be rc 2 (rc=$RC out=$OUT)"
OUT=$("$SW" --root "$R5/worktrees" --proc "$R5/noproc" --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && [ -d "$R5/worktrees/x" ] && ok || bad "W5: no <proc>/self must be rc 2 and remove nothing (rc=$RC out=$OUT)"
OUT=$("$SW" --root "$R5/does-not-exist" --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "WTSWEEP ok removed=0 busy=0 kept=0 failed=0 freed_kb=0" ] && ok || bad "W5: an absent root is an empty sweep (rc=$RC out=$OUT)"

# ═══ W6 a failed removal is failed, not removed ══════════════════════════════
R6="$T/w6"; mkdir -p "$R6/worktrees/stuck/sub" "$R6/path"
for c in rm git; do printf '#!/bin/bash\nexit 1\n' > "$R6/path/$c"; chmod +x "$R6/path/$c"; done
OUT=$(PATH="$R6/path:$PATH" "$SW" --root "$R6/worktrees" --harness "$H" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "W6: rc=$RC"
[[ "$OUT" == "WTSWEEP ok removed=0 busy=0 kept=0 failed=1 "* ]] && ok || bad "W6: summary line '$OUT'"
[ -d "$R6/worktrees/stuck" ] && ok || bad "W6: the entry must still exist"

# ═══ W7 the sweep script absent ═════════════════════════════════════════════
mv "$SW" "$T/sweep.real"
R7="$T/w7"; mkdir -p "$R7/worktrees"
runner "$R7/worktrees" "$R7/none" 1
grep -qx 'worktree sweep: absent' "$T/log" 2>/dev/null && ok || bad "W7: the runner must log 'worktree sweep: absent': $(cat "$T/log" 2>/dev/null)"
grep -q '^run-build.sh ' "$T/called" 2>/dev/null && ok || bad "W7: run-build.sh must still run"

# ═══ W8 POOL_MODE unset: no sweep ════════════════════════════════════════════
printf '#!/bin/bash\necho sweep >> "%s/sweep-calls"\nexit 0\n' "$T" > "$SW"; chmod +x "$SW"
rm -f "$T/sweep-calls"
runner "$R7/worktrees" "$R7/none" ""
[ ! -s "$T/sweep-calls" ] && ok || bad "W8: the sweep ran with POOL_MODE unset"
grep -q 'worktree sweep' "$T/log" 2>/dev/null && bad "W8: a non-pool runner logged a sweep" || ok
runner "$R7/worktrees" "$R7/none" 1
[ "$(grep -c . "$T/sweep-calls" 2>/dev/null)" = 1 ] && ok || bad "W8: with POOL_MODE=1 the sweep must run once"
mv "$T/sweep.real" "$SW"

# ═══ W9 the hub reads the disk RESULT as neither overlap, lane nor dirty ═════
awk '/^pool_lane_failure\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/hub.sh"
awk '/^pool_overlap_deferral\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" >> "$T/hub.sh"
grep -q 'pool_overlap_deferral' "$T/hub.sh" && grep -q 'pool_lane_failure' "$T/hub.sh" && ok || bad "W9: could not lift the hub's readers"
# shellcheck disable=SC1090
. "$T/hub.sh"
[ -n "$W2RESULT" ] && ok || bad "W9: no W2 RESULT to read"
pool_overlap_deferral "$W2RESULT" && bad "W9: pool_overlap_deferral claimed the disk RESULT" || ok
pool_lane_failure "$W2RESULT" && bad "W9: pool_lane_failure claimed the disk RESULT" || ok
[[ "$W2RESULT" == *"slot held on this machine"* ]] && bad "W9: the disk RESULT reads as a dirty-machine line" || ok

echo "pool-worktree-sweep.bh-8004: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/tmp-sweep.bh-5608-test.sh — BH-5608: the /tmp sweep also removes the
# builder and reviewer scratch checkouts (rv*, wt*, r[0-9]*, bh[0-9]*-*, pb*-*,
# lanes-build.*, review-prs-*), at a 180 min age, every 15 min and at the start
# of each review-prs and lead-review tick.
#
# The shipped bin/tmp-sweep.sh is installed with its source closure into a
# scratch harness and DRIVEN against a fixture /tmp under $T (TMP_SWEEP_ROOT),
# with a fixed clock (TMP_SWEEP_NOW), real live processes for the held case
# and a bin/jobs-client.sh stub that records every job_ledger_put. The pool
# case sources the real bin/lib/review-pool.sh and calls rpool_init. Cases:
#   T1  a 4 h old rv1234 that nothing holds is removed (red on main);
#   T2  a 30 min old rv1234 is kept and counted skipped_fresh;
#   T3  a 4 h old rv5 a live process sits in (cwd) is kept, skipped_held;
#   T4  a 4 h old mysql.sock.d is kept: not a scratch name;
#   T5  flags/lane-off-tmp-sweep: nothing removed, no summary;
#   T6  a removed git worktree leaves no `git worktree list` entry;
#   T7  a live job claim naming a path under rv77 keeps rv77;
#   T8  a real sweep writes the box_health ledger row with freed_bytes; a
#       dry run writes none;
#   T9  the removal line carries the path, the KB and the age in minutes;
#   T10 rpool_init runs the sweep once before it sizes the pool, never when
#       REVIEW_POOL_TMP_SWEEP is empty;
#   T11 under HARNESS_TEST_SANDBOX=1 with no TMP_SWEEP_ROOT the sweep reads
#       nothing in the real /tmp;
#   T12 the MIN_AGE_MIN registry row: default 180 and the note the ticket asks;
#   N1  one positive per ticket pattern is removed, and the adversarial names
#       are all kept.
# Run from anywhere: tests/tmp-sweep.bh-5608-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset MIN_AGE_MIN TMP_ALERT_PCT TMP_SWEEP_SCAN_TIMEOUT_S TMP_SWEEP_RUN_DEADLINE_S TMP_SWEEP_PATTERNS \
      TMP_SWEEP_ROOT TMP_SWEEP_PROC TMP_SWEEP_NOW TMP_SWEEP_STOPGAP_FILE TMP_SWEEP_CLAIMS \
      REVIEW_POOL_TMP_SWEEP 2>/dev/null || true
HOST=$(hostname)

HOLDERS=()
stop_holders() {
  local p
  for p in "${HOLDERS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  HOLDERS=()
}
T11_ENTRY=""
__bh5608_exit() {
  stop_holders
  [ -n "$T11_ENTRY" ] && rmdir -- "$T11_ENTRY" 2>/dev/null
  return 0
}
trap '__bh5608_exit; __scratch_exit_trap' EXIT

# ── the scratch harness ──────────────────────────────────────────────────────
scratch_install_closure bin/tmp-sweep.sh "$T/h" >/dev/null || { echo "FAIL: cannot install bin/tmp-sweep.sh's closure"; exit 1; }
mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/h/env" "$T/fx/cron.d"
cat > "$T/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/h/bin/lane-alert.sh"
# the jobs client: a stub that records every ledger write, one line each
cat > "$T/h/bin/jobs-client.sh" <<'SH'
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$TS_LEDGER"; }
SH
mkdir -p "$T/fakebin"
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
printf 'Filesystem     1024-blocks     Used Available Capacity Mounted on\ntmpfs 4194304 2000000 2097152 48%% /tmp\n'
SH
chmod +x "$T/fakebin/df"
FPATH="$T/fakebin:$PATH"

NOW=1790000000
OLD=$((NOW - 4 * 3600))
FX="$T/fx/tmp"
LOG="$T/h/logs/tmp-sweep.log"
export TS_LEDGER="$T/ledger.log"

age() { find "$1" -exec touch -h -d "@$2" {} + 2>/dev/null; }
reset_fx() {
  stop_holders
  scratch_rm "$FX"; mkdir -p "$FX"
  scratch_rm "$T/h/state/claims"
  rm -f "$LOG" "$TS_LEDGER"
}
mkold() { # mkold <name> [epoch] — a dir with a 64 KB file, every mtime 4 h ago
  mkdir -p "$FX/$1/d"
  head -c 65536 /dev/zero > "$FX/$1/d/blob"
  age "$FX/$1" "${2:-$OLD}"
}
run() { # run [VAR=val ...] [-- args] — drive the shipped script, bounded
  local -a envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  local rc
  timeout 120 env PATH="$FPATH" HARNESS_ROOT="$T/h" HARNESS="$T/h" HOME="$T" \
      TMP_SWEEP_ROOT="$FX" TMP_SWEEP_NOW="$NOW" TMP_SWEEP_STOPGAP_FILE="$T/fx/cron.d/tmp-sweep" \
      "${envs[@]}" bash "$T/h/bin/tmp-sweep.sh" "${args[@]}"
  rc=$?
  [ "$rc" = 124 ] && bad "a run of bin/tmp-sweep.sh did not finish in 120 s (${envs[*]} ${args[*]})" >&2
  return "$rc"
}
summary() { grep -E ' tmp-sweep(: dry-run)? removed=' "$LOG" 2>/dev/null; }
field() { summary | tail -1 | grep -oE "(^| )$1=[^ ]*" | cut -d= -f2; }

# ══ T1 the ticket's red case, T9 the removal line, T8 the box-health row ═════
reset_fx; mkold rv1234
run >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "T1 rc must be 0 (got $RC)"
[ ! -e "$FX/rv1234" ] && ok || bad "T1 a 4 h old rv1234 that nothing holds must be removed ($(cat "$LOG" 2>/dev/null))"
[ "$(field removed)" = 1 ] && ok || bad "T1 summary must say removed=1 ($(summary))"
[ "$(field min_age_min)" = 180 ] && ok || bad "T1 the default age is 180 min ($(summary))"
grep -qE " removed $FX/rv1234 [0-9]+ KB age_min=2[34][0-9]$" "$LOG" && ok \
  || bad "T9 the removal line is 'removed <path> <kb> KB age_min=<n>' ($(grep ' removed ' "$LOG"))"
grep -qE " removed $FX/rv1234 [0-9]+ KB age_min=240$" "$LOG" && ok \
  || bad "T9 a dir last written 4 h before TMP_SWEEP_NOW is age_min=240 ($(grep ' removed ' "$LOG"))"
fk=$(field freed_kb)
row=$(grep -c . "$TS_LEDGER" 2>/dev/null)
[ "$row" = 1 ] && ok || bad "T8 one ledger write per real sweep (got ${row:-0}: $(cat "$TS_LEDGER" 2>/dev/null))"
lk=""; lkey=""; lst=""; ldet=""
[ -f "$TS_LEDGER" ] && IFS=$'\t' read -r lk lkey lst ldet < "$TS_LEDGER"
[ "${lk:-}" = box_health ] && [ "${lkey:-}" = "tmp-sweep $HOST" ] && [ "${lst:-}" = ok ] && ok \
  || bad "T8 the row is box_health / 'tmp-sweep $HOST' / ok ($(cat "$TS_LEDGER" 2>/dev/null))"
[ -n "$fk" ] && [ "$fk" -gt 0 ] && [ "$(jq -r .freed_bytes <<<"${ldet:-}" 2>/dev/null)" = "$((fk * 1024))" ] && ok \
  || bad "T8 freed_bytes is 1024 x freed_kb=$fk (detail '${ldet:-}')"
[ "$(jq -r '[.removed,.failed,.tmp_use_pct,.tmp_avail_mb]|map(tostring)|join(",")' <<<"${ldet:-}" 2>/dev/null)" = "1,0,48,2048" ] && ok \
  || bad "T8 the detail carries removed, failed and the df reading (detail '${ldet:-}')"

# a dry run writes no row; a sweep that removes nothing still writes one
reset_fx; mkold rv1234
run -- --dry-run >/dev/null 2>&1
[ -d "$FX/rv1234" ] && [ ! -s "$TS_LEDGER" ] && ok || bad "T8 --dry-run removes nothing and writes no ledger row ($(cat "$TS_LEDGER" 2>/dev/null))"
reset_fx
run >/dev/null 2>&1
[ "$(cut -f1 "$TS_LEDGER" 2>/dev/null)" = box_health ] && [ "$(cut -f4 "$TS_LEDGER" | jq -r .freed_bytes 2>/dev/null)" = 0 ] && ok \
  || bad "T8 a sweep that removed nothing writes freed_bytes=0 ($(cat "$TS_LEDGER" 2>/dev/null))"
# no jobs client: a log line, and the exit code stays 0
mv "$T/h/bin/jobs-client.sh" "$T/jobs-client.sh.off"
reset_fx; run >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'box-health row not written (no jobs client)' "$LOG" && ok \
  || bad "T8 no jobs client: rc 0 and a log line (rc=$RC, $(cat "$LOG"))"
mv "$T/jobs-client.sh.off" "$T/h/bin/jobs-client.sh"

# ══ T2 fresh, T3 held by cwd, T4 not a scratch name ═════════════════════════
reset_fx; mkold rv1234 $((NOW - 30 * 60))
run >/dev/null 2>&1
[ -d "$FX/rv1234" ] && [ "$(field skipped_fresh)" = 1 ] && ok || bad "T2 a 30 min old rv1234 is kept, skipped_fresh=1 ($(summary))"

reset_fx; mkold rv5; mkold mysql.sock.d
(cd "$FX/rv5" && exec sleep 120) & HOLDERS+=("$!")   # determinism: ok race-sleep the sleep is the background holder's lifetime; the loop below polls /proc for readiness
for _ in $(seq 1 200); do [ "$(readlink "/proc/${HOLDERS[0]}/cwd" 2>/dev/null)" = "$FX/rv5" ] && break; sleep 0.05; done
[ "$(readlink "/proc/${HOLDERS[0]}/cwd" 2>/dev/null)" = "$FX/rv5" ] && ok || bad "T3 fixture: the holder's cwd must really be rv5"
run >/dev/null 2>&1
[ -d "$FX/rv5" ] && [ "$(field skipped_held)" = 1 ] && ok || bad "T3 rv5, a live process's cwd, is kept, skipped_held=1 ($(summary))"
[ -d "$FX/mysql.sock.d" ] && ok || bad "T4 a 4 h old mysql.sock.d is not a scratch name and is kept"
[ "$(field removed)" = 0 ] && ok || bad "T3/T4 nothing in this fixture is removable ($(summary))"
stop_holders

# ══ T5 the kill switch ══════════════════════════════════════════════════════
reset_fx; mkold rv1234
: > "$T/h/flags/lane-off-tmp-sweep"
run >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ -d "$FX/rv1234" ] && [ -z "$(summary)" ] && [ ! -s "$TS_LEDGER" ] && ok \
  || bad "T5 flags/lane-off-tmp-sweep: rc 0, nothing removed, no summary, no row (rc=$RC)"
rm -f "$T/h/flags/lane-off-tmp-sweep"

# ══ T6 a removed worktree is pruned from its repo ═══════════════════════════
reset_fx
REPO="$T/repo"; scratch_rm "$REPO"
git init -q "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init \
  && git -C "$REPO" worktree add -q "$FX/wt5608" >/dev/null 2>&1 \
  || bad "T6 fixture: git worktree add failed"
age "$FX/wt5608" "$OLD"
wtl=$(git -C "$REPO" worktree list --porcelain 2>&1)
grep -qxF "worktree $FX/wt5608" <<<"$wtl" && ok \
  || bad "T6 fixture: before the sweep the repo lists the worktree"
run >/dev/null 2>&1
[ ! -e "$FX/wt5608" ] && ok || bad "T6 the 4 h old worktree wt5608 is removed ($(cat "$LOG"))"
wtl=$(git -C "$REPO" worktree list --porcelain 2>&1); wrc=$?
[ "$wrc" = 0 ] && ! grep -qF "$FX/wt5608" <<<"$wtl" && ok || bad "T6 the repo still lists the removed worktree (rc=$wrc: $wtl)"
grep -qxE ".* pruned worktrees in $REPO/\.git" "$LOG" && ok || bad "T6 the log names the prune ($(cat "$LOG"))"
# a dry run never prunes
reset_fx
git -C "$REPO" worktree add -q "$FX/wt5609" >/dev/null 2>&1; age "$FX/wt5609" "$OLD"
run -- --dry-run >/dev/null 2>&1
grep -q 'pruned worktrees' "$LOG" && bad "T6 --dry-run never prunes" || ok

# ══ T7 a live job claim holds its path ══════════════════════════════════════
reset_fx; mkold rv77; mkold rv78
mkdir -p "$T/h/state/claims/cromford"
printf 'bin/x.sh\n%s\n' "$FX/rv77/sub" > "$T/h/state/claims/cromford/BH-1"
run >/dev/null 2>&1
[ -d "$FX/rv77" ] && ok || bad "T7 rv77, named by a live claim, is kept ($(summary))"
[ ! -e "$FX/rv78" ] && ok || bad "T7 rv78, named by no claim, is removed"
[ "$(field skipped_held)" = 1 ] && ok || bad "T7 the claim counts as held, skipped_held=1 ($(summary))"

# ══ N1 one positive per ticket pattern, and the adversarial negatives ═══════
reset_fx
POS="rv9 wt3 r42 scratch.Q1 bh12-x pb7-y lanes-build.ab"
for n in $POS; do mkold "$n"; done
printf 'x\n' > "$FX/review-prs-list.cd"; touch -d "@$OLD" "$FX/review-prs-list.cd"
NEG="mysql.sock.d systemd-private-abc123-chrony.service-Xy tmux-0 .X11-unix ssh-AbCdEf hsperfdata_root node-compile-cache v8-compile-cache-0 npm-1234 claude-0 lead-review-land.ab12cd r bh-x"
for n in $NEG; do mkold "$n"; done
mkdir -p "$T/fx/target"; echo t > "$T/fx/target/f"; age "$T/fx/target" "$OLD"
ln -s "$T/fx/target" "$FX/rv"; touch -h -d "@$OLD" "$FX/rv"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FX/wt" 2>/dev/null; touch -h -d "@$OLD" "$FX/wt" 2>/dev/null
run >/dev/null 2>&1
for n in $POS review-prs-list.cd; do
  [ ! -e "$FX/$n" ] && ok || bad "N1 the 4 h old scratch name $n is removed"
done
for n in $NEG; do
  [ -e "$FX/$n" ] && ok || bad "N1 $n is not a scratch name and must be kept"
done
[ -L "$FX/rv" ] && [ -f "$T/fx/target/f" ] && ok || bad "N1 a symlink named rv and its target are kept"
if [ -S "$FX/wt" ]; then ok; else echo "tmp-sweep.bh-5608: no unix socket fixture (python3 missing); N1 wt-socket case not run"; fi
[ "$(field removed)" = 8 ] && ok || bad "N1 removed=8 ($(summary))"

# ══ T10 the pre-tick sweep in rpool_init ════════════════════════════════════
scratch_install_closure bin/lib/review-pool.sh "$T/p" >/dev/null || bad "T10 cannot install review-pool.sh's closure"
cat > "$T/stub-sweep" <<'SH'
#!/bin/bash
printf 'SWEEP %s\n' "$*" >> "$TS_CALLS"
SH
chmod +x "$T/stub-sweep"
export TS_CALLS="$T/sweep.calls"
pool() { # pool [VAR=val ...] — rpool_init in a fresh shell, its log lines into $TS_CALLS
  rm -f "$TS_CALLS"
  timeout 60 env "$@" REVIEW_BOX_MAX=1 bash -c '
    . "$0/bin/lib/review-pool.sh" || exit 9
    lg() { printf "LOG %s\n" "$*" >> "$TS_CALLS"; }
    rpool_init review-prs REVIEW 4 "$1/pool" lg' "$T/p" "$T" >/dev/null 2>&1
}
pool HARNESS="$T/p" REVIEW_POOL_TMP_SWEEP="$T/stub-sweep"
[ "$(grep -c '^SWEEP' "$TS_CALLS" 2>/dev/null)" = 1 ] && ok || bad "T10 rpool_init runs the sweep exactly once ($(cat "$TS_CALLS" 2>/dev/null))"
[ "$(grep -n . "$TS_CALLS" 2>/dev/null | grep -E '^1:SWEEP')" != "" ] && grep -q '^LOG concurrency capped at 1 by REVIEW_BOX_MAX=1' "$TS_CALLS" && ok \
  || bad "T10 the sweep runs before the pool sizes itself ($(cat "$TS_CALLS" 2>/dev/null))"
pool HARNESS="$T/p" REVIEW_POOL_TMP_SWEEP=
[ "$(grep -c '^SWEEP' "$TS_CALLS" 2>/dev/null)" = 0 ] && ok || bad "T10 REVIEW_POOL_TMP_SWEEP= turns the pre-tick sweep off ($(cat "$TS_CALLS"))"
# the default is the harness's own bin/tmp-sweep.sh
cp "$T/stub-sweep" "$T/p/bin/tmp-sweep.sh"
pool HARNESS="$T/p"
[ "$(grep -c '^SWEEP' "$TS_CALLS" 2>/dev/null)" = 1 ] && ok || bad "T10 with no override rpool_init runs \$HARNESS/bin/tmp-sweep.sh ($(cat "$TS_CALLS" 2>/dev/null))"
# no harness root: nothing to run, and the pool still sizes itself
pool
[ "$(grep -c '^SWEEP' "$TS_CALLS" 2>/dev/null)" = 0 ] && grep -q '^LOG concurrency capped at 1' "$TS_CALLS" && ok \
  || bad "T10 with no HARNESS, no sweep and the pool still sizes ($(cat "$TS_CALLS" 2>/dev/null))"
# the pre-tick run is the shipped sweep against the real lane: an old scratch dir goes
rm -f "$T/p/bin/tmp-sweep.sh"
reset_fx; mkold rv4321
pool HARNESS="$T/p" REVIEW_POOL_TMP_SWEEP="$T/h/bin/tmp-sweep.sh" HARNESS_ROOT="$T/h" PATH="$FPATH" \
  TMP_SWEEP_ROOT="$FX" TMP_SWEEP_NOW="$NOW" TMP_SWEEP_STOPGAP_FILE="$T/fx/cron.d/tmp-sweep"
[ ! -e "$FX/rv4321" ] && [ "$(field removed)" = 1 ] && ok || bad "T10 rpool_init's pre-tick run of bin/tmp-sweep.sh removes an old rv4321 ($(cat "$LOG" 2>/dev/null))"

# ══ T11 the sandbox never sweeps the real /tmp ══════════════════════════════
# An old rv entry in the REAL /tmp, which a sweep with no TMP_SWEEP_ROOT would
# list. Dry run only: the real /tmp is read, never written, even when red.
T11_ENTRY=$(mktemp -d /tmp/rv5608t11.XXXXXX)
touch -d "@$((NOW - 7 * 3600))" "$T11_ENTRY"
rm -f "$LOG"
out=$(timeout 120 env -u TMP_SWEEP_ROOT PATH="$FPATH" HARNESS_ROOT="$T/h" HARNESS="$T/h" HOME="$T" HARNESS_TEST_SANDBOX=1 \
      TMP_SWEEP_NOW="$NOW" TMP_SWEEP_STOPGAP_FILE="$T/fx/cron.d/tmp-sweep" bash "$T/h/bin/tmp-sweep.sh" --dry-run 2>&1)
grep -q 'TMP_SWEEP_ROOT unset under HARNESS_TEST_SANDBOX - sweep skipped' "$LOG" && ok \
  || bad "T11 the sandbox guard logs the skip ($(cat "$LOG" 2>/dev/null))"
[[ $out != *"would remove"* ]] && [ -z "$(summary)" ] && ok || bad "T11 the sandbox lists nothing in the real /tmp ('$out')"
[ -d "$T11_ENTRY" ] && ok || bad "T11 the real /tmp entry is untouched"
rmdir -- "$T11_ENTRY"; T11_ENTRY=""

# ══ T12 the registry row and the cron line ══════════════════════════════════
J="$DIR/catalog/lanes.d/tmp-sweep.json"
[ "$(jq -r '.knobs[]|select(.env=="MIN_AGE_MIN").default' "$J")" = 180 ] && ok || bad "T12 the MIN_AGE_MIN default is 180"
note=$(jq -r '.knobs[]|select(.env=="MIN_AGE_MIN").note' "$J")
[[ $note == *"live scratch of a running job"* && $note == *"costs nothing"* ]] && ok \
  || bad "T12 the MIN_AGE_MIN note says what it protects and what a firing costs ('$note')"
jq -e '.knobs[]|select(.env=="TMP_SWEEP_CLAIMS").settable==false' "$J" >/dev/null && ok \
  || bad "T12 TMP_SWEEP_CLAIMS is a test seam, not settable from a page"
[ "$(jq -r .cadence "$J")" = '8,23,38,53 * * * *' ] && ok || bad "T12 the registry cadence is every 15 min"
grep -qxF '8,23,38,53 * * * * /root/harness/bin/tmp-sweep.sh >/dev/null 2>&1' "$DIR/cron/lanes/647-tmp-sweep.cron" && ok \
  || bad "T12 cron/lanes/647-tmp-sweep.cron runs the sweep every 15 min"

echo "tmp-sweep.bh-5608: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

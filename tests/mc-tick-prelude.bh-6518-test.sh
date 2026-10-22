#!/bin/bash
# tests/mc-tick-prelude.bh-6518-test.sh — BH-6518 slice C3: the conductor's
# tick prelude (the spend budgets, the isInMergeQueue knobs, the re-review cap
# file, the knobs the detached lanes inherit and the tick id) lives in
# bin/lib/mc/tick-scope.sh as mc_tick_prelude. The driver calls it at the old
# place, after mc_init and hb_start, and refuses the tick when tick-scope.sh
# does not define it. use_token and reset_token stay in the driver (BH-685).
#
#   P1     defaults: the function sourced alone, with no knob in the env.
#   P2     every knob the prelude reads is honoured from the env.
#   P3     export attributes: MC_TICK_ID and the ten detached-lane knobs are
#          exported (a child shell reads them), the budgets, the cap, CAPFILE
#          and the three isInMergeQueue knobs are not.
#   D1     the real driver (production entry point) with an empty fleet exits
#          0 and touches the day's re-review cap file; with the call line
#          deleted no cap file is made.
#   D2     tick-scope.sh with the parse, the window and the mode and no
#          mc_tick_prelude: rc 1, one CONDUCTOR MODULE MISSING alert, no gh
#          call; with the new guard clause dropped the driver does not refuse.
#   L1     the shim (bin/lib/merge-conductor-lib.sh) never defines
#          mc_tick_prelude.
# Run from anywhere: tests/mc-tick-prelude.bh-6518-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

KNOBS="MC_REBASE_BUDGET MC_REREVIEW_BUDGET MC_MERGE_BUDGET MC_LIST_INQUEUE MC_INQUEUE_PROBE_TTL_SECS MC_INQUEUE_STATES MC_REREVIEW_DAILY_CAP"
XKNOBS="MC_REREVIEW_PARALLEL MC_REREVIEW_TIMEOUT_SECS MC_RR_PATH MC_REBASE_PARALLEL MC_REBASE_TIMEOUT_SECS MC_DETACHED_REBASE MC_DV_TIMEOUT_SECS MC_DETACHED_DEPLOY_VERIFY MC_PR_PARALLEL MC_MERGE_LOCK_WAIT"

# ── P1-P3. the prelude, sourced alone ───────────────────────────────────────
# prelude_case <env-assignment>... — runs mc_tick_prelude in a clean subshell
# with a stub mc_tick_id and a scratch MC_STATE_DIR. Prints one line per value
# (`name=value`), then `x:<name>=x|-` export attributes, then `child=<…>`
# (what a fresh bash sees) and `capfiles=<n>`.
prelude_case() {
  ( SD="$T/state-p"; scratch_rm "$SD" 2>/dev/null; mkdir -p "$SD"
    # shellcheck disable=SC2086
    unset $KNOBS REBASE_BUDGET REREVIEW_BUDGET MERGE_BUDGET REREVIEW_CAP CAPFILE MC_TICK_ID
    for kv in "$@"; do export "${kv?}"; done
    # The detached-lane knobs are set but NOT exported, as the libs set them.
    for v in $XKNOBS; do export -n "$v" 2>/dev/null; printf -v "$v" '%s' "v-$v"; done
    MC_STATE_DIR="$SD"
    mc_tick_id() { printf 'tick-fixture-1'; }
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    mc_tick_prelude || exit 7
    for v in REBASE_BUDGET REREVIEW_BUDGET MERGE_BUDGET MC_LIST_INQUEUE MC_INQUEUE_PROBE_TTL_SECS MC_INQUEUE_STATES REREVIEW_CAP MC_TICK_ID; do
      printf '%s=%s\n' "$v" "${!v-unset}"
    done
    case "$CAPFILE" in "$SD"/rereviews-*.txt) printf 'capfile=in-state-dir\n' ;; *) printf 'capfile=%s\n' "$CAPFILE" ;; esac
    for v in MC_TICK_ID $XKNOBS REBASE_BUDGET REREVIEW_BUDGET MERGE_BUDGET REREVIEW_CAP CAPFILE MC_LIST_INQUEUE MC_INQUEUE_PROBE_TTL_SECS MC_INQUEUE_STATES; do
      dp=$(declare -p "$v" 2>/dev/null)
      case "$dp" in "declare -x"*) printf 'x:%s=x\n' "$v" ;; *) printf 'x:%s=-\n' "$v" ;; esac
    done
    printf 'child=%s\n' "$(bash -c 'printf "%s/%s/%s" "${MC_TICK_ID:-none}" "${MC_PR_PARALLEL:-none}" "${REBASE_BUDGET:-none}"')"
    n=0; for f in "$SD"/rereviews-*.txt; do [ -f "$f" ] && n=$((n+1)); done
    printf 'capfiles=%s\n' "$n" )
}
P1=$(prelude_case 2>&1)
want_val() { # want_val <case-id> <output> <line>
  grep -qxF -- "$3" <<<"$2" && ok || bad "$1: want line '$3', got:
$2"
}
for l in REBASE_BUDGET=2 REREVIEW_BUDGET=2 MERGE_BUDGET=5 MC_LIST_INQUEUE=auto \
         MC_INQUEUE_PROBE_TTL_SECS=86400 'MC_INQUEUE_STATES=CLEAN QUEUED' REREVIEW_CAP=0 \
         MC_TICK_ID=tick-fixture-1 capfile=in-state-dir capfiles=1; do
  want_val P1 "$P1" "$l"
done

P2=$(prelude_case MC_REBASE_BUDGET=7 MC_REREVIEW_BUDGET=3 MC_MERGE_BUDGET=0 MC_LIST_INQUEUE=0 \
                  MC_INQUEUE_PROBE_TTL_SECS=60 MC_INQUEUE_STATES=CLEAN MC_REREVIEW_DAILY_CAP=6 2>&1)
for l in REBASE_BUDGET=7 REREVIEW_BUDGET=3 MERGE_BUDGET=0 MC_LIST_INQUEUE=0 \
         MC_INQUEUE_PROBE_TTL_SECS=60 MC_INQUEUE_STATES=CLEAN REREVIEW_CAP=6 capfiles=1; do
  want_val P2 "$P2" "$l"
done

for v in MC_TICK_ID $XKNOBS; do want_val P3 "$P1" "x:$v=x"; done
for v in REBASE_BUDGET REREVIEW_BUDGET MERGE_BUDGET REREVIEW_CAP CAPFILE; do want_val P3 "$P1" "x:$v=-"; done
want_val P3 "$P1" "child=tick-fixture-1/v-MC_PR_PARALLEL/none"

# ── D1-D2. the real driver ──────────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install bin/merge-conductor.sh"; exit 1; }
cp "$HD/bin/merge-conductor.sh" "$T/driver.pristine" || exit 1
# An empty fleet: the tick runs its prelude, logs, and has no project to touch.
: > "$HD/fleet.conf"
cat > "$HD/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$HD/fakebin/curl"
chmod +x "$HD/fakebin/gh" "$HD/fakebin/curl"
resetd() { : > "$HD/logs/merge-conductor.log"; : > "$HD/logs/ALERTS.log"; : > "$T/gh.txt"
           rm -f "$HD/flags/"* "$HD/state/merge-conductor/"rereviews-*.txt
           cp "$T/driver.pristine" "$HD/bin/merge-conductor.sh"; }
# tick — one unkeyed conductor tick; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR='' MC_FULL_TICK_BUDGET_S=1500
    unset GH_TOKEN MC_WORKERS_DONE_BY MC_MODE MC_TICK_ID
    bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
nlog() { grep -c -- "$1" "$HD/logs/merge-conductor.log" 2>/dev/null || true; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }
capfiles() { local n=0 f; for f in "$HD/state/merge-conductor/"rereviews-*.txt; do [ -f "$f" ] && n=$((n+1)); done; echo "$n"; }

# D1: the real tick runs the prelude: the day's cap file exists after it.
resetd
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D1: a tick with an empty fleet exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(capfiles)" = 1 ] && ok || bad "D1: want one rereviews-<day>.txt cap file after a tick, got $(capfiles)"
[ "$(alerts)" = 0 ] && ok || bad "D1: a tick that loaded tick-scope.sh raised CONDUCTOR MODULE MISSING"

# D1 mutation: the driver no longer calls the prelude, so no cap file is made.
resetd
sed -i '/^mc_tick_prelude$/d' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D1-mutation: the driver has no 'mc_tick_prelude' call line to delete"
else
  rc=$(tick)
  [ "$(capfiles)" = 0 ] && ok \
    || bad "D1-mutation: with the call line deleted a cap file still appears (rc $rc) — the test does not pin the call"
fi

# D2: tick-scope.sh defines the parse, the window and the mode and not the
# prelude. The fan-out stub keeps the mc_tick_fanout (BH-7879) guard clause
# satisfied, so the mutation below drops the only clause that refuses.
# D2 and its mutation are the last driver cases: they replace the
# installed file and nothing after them needs the real one back.
c2_ts() { cat > "$HD/bin/lib/mc/tick-scope.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
mc_keyed_tick_parse() { MC_ONLY_KEYS=""; }
mc_full_tick_window() { :; }
mc_tick_mode() { KILL=0 ACTIONS=0 MERGES=0 MODE=observe; MC_MODE=observe; export MC_MODE; }
mc_tick_fanout() { :; }
SH
}
resetd; c2_ts
rc=$(tick)
[ "$rc" = 1 ] && ok || bad "D2: a tick with no mc_tick_prelude exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "D2: want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
[ ! -s "$T/gh.txt" ] && ok || bad "D2: a refused tick called gh: $(head -3 "$T/gh.txt")"
[ "$(capfiles)" = 0 ] && ok || bad "D2: a refused tick made a cap file"
[ "$(nlog 'bin/lib/mc/tick-scope.sh is missing or unusable — refusing the tick')" = 1 ] && ok \
  || bad "D2: want one refusal line in logs/merge-conductor.log: $(mclog)"

# D2 mutation: drop the new guard clause, and the driver no longer refuses.
resetd; c2_ts
sed -i 's/ || ! declare -F mc_tick_prelude >\/dev\/null//' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D2-mutation: the driver has no 'declare -F mc_tick_prelude' guard clause to drop"
else
  rc=$(tick)
  [ "$(alerts)" = 0 ] && ok \
    || bad "D2-mutation: with the guard clause dropped the driver still alerted (rc $rc) — the test does not pin the clause"
fi

# ── L1. the shim ────────────────────────────────────────────────────────────
HL="$T/hl"; mkdir -p "$HL"
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; declare -F mc_tick_prelude >/dev/null && echo defined || echo absent' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ "$shim" = absent ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok \
  || bad "L1: after sourcing the shim, mc_tick_prelude is '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-tick-prelude: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

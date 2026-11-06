#!/bin/bash
# tests/triage-shards-building.bh-9113-test.sh — BH-9113 cause 2: the shard loop
# (bin/lib/rt/shards.sh rt_shards) gave a slot to a ticket with a running build.
# project-3, 2026-11-05: TK-698 got a shard at 20:36, 20:46, 20:56, 21:06 and
# 21:16Z, and each one ended `claim refused: ticket :: ticket max 1 already
# running`. Now the dispatcher reads the running builds once per tick
# (bin/lib/shard-building.sh) and skips such a key before any slot or cap.
#
#   M1-M11  shard_building_why: the matcher table (skip / no skip)
#   S1      acceptance 4: the building key gets no shard and one skip line, the
#           summary names it, no fingerprint is stamped for it
#   S2      the skip uses no slot: cap 2, the other two keys are dispatched
#   S3      the census is unreadable: one line, every key dispatched
#   S4      no jobs client and no lock: the tick as before
#   S5      the skipped key is re-armed (offered again next tick)
#   S6      a held local build-key lock skips the key too
#   V       0 vendor calls
#
# Run from anywhere: tests/triage-shards-building.bh-9113-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset STUB_RUNNING STUB_RUNNING_RC

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks"
cat > "$H/bin/triage-shard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$2" >> "$T/calls/shard-\$1"
STUB
chmod +x "$H/bin/"*.sh
# The lib under test, where rt_shards looks for it ($HARNESS/bin/lib).
scratch_install_closure bin/lib/shard-building.sh "$H" >/dev/null 2>&1 || bad "install bin/lib/shard-building.sh"
export HARNESS="$H"

unhold() { pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
hold() { # hold <lockfile> — a live flock holder; its pid in HOLDER
  flock "$1" sleep 30 &
  HOLDER=$!
  for _ in $(seq 1 50); do flock -n "$1" true 2>/dev/null || break; sleep 0.1; done
}

# ═══ M: the matcher ═════════════════════════════════════════════════════════
# why <gh> <key> <census rows...> — shard_building_why over a census file
why() {
  local gh="$1" k="$2"; shift 2
  printf '%s\n' "$@" > "$T/census.tsv"
  ( . "$H/bin/lib/shard-building.sh" 2>/dev/null || exit 9
    PROJECT=mp; shard_building_why "$H" mp "$gh" "$T/census.tsv" "$k"; echo " rc=$?" )
}
R=$'\t'
[ "$(why 0 TK-698 "j1${R}TK-698${R}-${R}box-a${R}build")" = "jobs ledger: build j1 on box-a rc=0" ] && ok || bad "(M1) row ticket_key TK-698: skip [$(why 0 TK-698 "j1${R}TK-698${R}-${R}box-a${R}build")]"
[ "$(why 0 TK-698 "j2${R}TK-698-r2${R}TK-698${R}box-b${R}build")" = "jobs ledger: build j2 on box-b rc=0" ] && ok || bad "(M2) meta ticket id TK-698 on key TK-698-r2: skip"
[ "$(why 1 412 "j3${R}BH-412${R}-${R}box-c${R}build")" = "jobs ledger: build j3 on box-c rc=0" ] && ok || bad "(M3) GitHub key 412, row BH-412: skip"
[ "$(why 0 TK-698 "j4${R}TK-6980${R}TK-6980${R}box-a${R}build")" = " rc=1" ] && ok || bad "(M4) row TK-6980 is not TK-698"
[ "$(why 0 TK-698 "j5${R}TK-698.2${R}TK-698.2${R}box-a${R}build")" = " rc=1" ] && ok || bad "(M5) a dotted child TK-698.2 is not TK-698"
[ "$(why 1 412 "j6${R}BH-4120${R}-${R}box-a${R}build")" = " rc=1" ] && ok || bad "(M6) GitHub key 412, row BH-4120: no skip"
[ "$(why 0 412 "j7${R}BH-412${R}-${R}box-a${R}build")" = " rc=1" ] && ok || bad "(M7) an in-app key never takes the GitHub prefix form"
[ "$(why 0 TK-698 "#unreadable")" = " rc=1" ] && ok || bad "(M8) an unreadable census skips nothing"
[ "$(why 0 TK-698 "")" = " rc=1" ] && ok || bad "(M9) an empty census and no lock: no skip"
[ "$(why 0 TK-701 "j1${R}TK-698${R}-${R}box-a${R}build")" = " rc=1" ] && ok || bad "(M10) another key's row: no skip"
hold "$H/locks/build-key-mp-TK-698.lock"
[ "$(why 0 TK-698 "")" = "local build-key lock held rc=0" ] && ok || bad "(M11) a held build-key lock: skip [$(why 0 TK-698 "")]"
unhold "$HOLDER"
[ "$(why 0 TK-698 "")" = " rc=1" ] && ok || bad "(M11) a free build-key lock file: no skip"

# ═══ S: the real rt_shards ══════════════════════════════════════════════════
bline() { local k; for k in "$@"; do printf 'board changed: NEW %s "ticket %s"\n' "$k" "$k"; done; }
# shards <max> <keys...> — one tick through the real rt_shards. The stub jobs
# client answers job_builds_running from STUB_RUNNING (rc STUB_RUNNING_RC);
# NOJOBS=1 leaves it undefined.
shards() {
  local max="$1"; shift
  ( set +u
    PROJECT=$P; STAMP="t"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
    GATE_DECISION="RUN board-changed"; GATE_REASON=board-changed; SCOPE_N=1
    TICK_SCOPE="$(bline "$@")"; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""; PROMPT_TEXT="SOP"
    TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    LANE_TICK() { :; }; rt_gate_consume() { :; }
    . "$DIR/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo 0; }; triage_shard_fp_ttl() { echo 3600; }
    triage_shards_max() { echo "$max"; }; triage_caps_on() { echo 0; }
    triage_prstates_ingest() { :; }; triage_prstates_refresh() { :; }; triage_prstates_prune() { :; }
    triage_shard_fp() { echo "fp-$3"; }; triage_shard_fp_fresh() { return 1; }
    triage_shard_fp_put() { printf '%s\n' "$3" >> "$T/calls/fpput-$P"; }
    triage_shard_rearm() { printf '%s\n' "$3" >> "$T/calls/rearm-$P"; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    if [ "${NOJOBS:-0}" != 1 ]; then
      job_builds_running() { [ "$1" = "$P" ] || return 1; [ -n "${STUB_RUNNING:-}" ] && printf '%s\n' "$STUB_RUNNING"; return "${STUB_RUNNING_RC:-0}"; }
    fi
    . "$DIR/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
newp() { P="bld-$1-$$"; }
dispatched() { tr '\n' ' ' < "$T/calls/shard-$P" 2>/dev/null; }
summary() { grep "dispatched .* shards:" "$H/logs/$P.log" 2>/dev/null | tail -1; }

# S1 / acceptance 4: TK-698 has a running build
newp s1
export STUB_RUNNING="j1${R}TK-698${R}-${R}box-a${R}build"
shards 0 TK-698 TK-701
[ "$(dispatched)" = "TK-701 " ] && ok || bad "(S1) the building key gets no shard: [$(dispatched)]"
[ "$(grep -c "triage shards: TK-698 skipped — build running (jobs ledger: build j1 on box-a)" "$H/logs/$P.log" 2>/dev/null)" = 1 ] \
  && ok || bad "(S1) one skip line with the reason: [$(grep TK-698 "$H/logs/$P.log" 2>/dev/null)]"
case "$(summary)" in *"dispatched 1 shards: TK-701"*" — building: TK-698"*) ok ;; *) bad "(S1) the summary names the building key: [$(summary)]" ;; esac
[ "$(tr '\n' ' ' < "$T/calls/fpput-$P" 2>/dev/null)" = "TK-701 " ] && ok || bad "(S1) no fingerprint stamped for the building key: [$(cat "$T/calls/fpput-$P" 2>/dev/null)]"
# S5: the skipped key is re-armed, so the next tick offers it again
[ "$(cat "$T/calls/rearm-$P" 2>/dev/null)" = TK-698 ] && ok || bad "(S5) the building key is re-armed: [$(cat "$T/calls/rearm-$P" 2>/dev/null)]"

# S2: cap 2, three keys, the first one building — the skip used no slot
newp s2
shards 2 TK-698 TK-701 TK-703
[ "$(dispatched)" = "TK-701 TK-703 " ] && ok || bad "(S2) cap 2: the other two keys fill the slots: [$(dispatched)]"
case "$(summary)" in *"left in scope"*) bad "(S2) no key is left over the cap: [$(summary)]" ;; *) ok ;; esac
unset STUB_RUNNING

# S3: the census read fails — every key dispatches, one line says so
newp s3
export STUB_RUNNING_RC=1
shards 0 TK-698 TK-701
[ "$(dispatched)" = "TK-698 TK-701 " ] && ok || bad "(S3) an unreadable census skips nothing: [$(dispatched)]"
[ "$(grep -c "triage shards: running-build census unreadable" "$H/logs/$P.log" 2>/dev/null)" = 1 ] && ok || bad "(S3) one census-unreadable line"
unset STUB_RUNNING_RC

# S4: no jobs client, no lock — the tick as before
newp s4
NOJOBS=1 shards 0 TK-698 TK-701
[ "$(dispatched)" = "TK-698 TK-701 " ] && ok || bad "(S4) no census: all dispatched: [$(dispatched)]"
case "$(summary)" in *building*) bad "(S4) no building segment: [$(summary)]" ;; "") bad "(S4) the summary line is written" ;; *) ok ;; esac
grep -q "skipped — build running\|census unreadable" "$H/logs/$P.log" 2>/dev/null && bad "(S4) no skip or census line" || ok

# S6: a held local build-key lock (a build on this box, ledger silent)
newp s6
hold "$H/locks/build-key-$P-TK-701.lock"
shards 0 TK-698 TK-701
unhold "$HOLDER"
[ "$(dispatched)" = "TK-698 " ] && ok || bad "(S6) a held build-key lock skips the key: [$(dispatched)]"
grep -q "triage shards: TK-701 skipped — build running (local build-key lock held)" "$H/logs/$P.log" && ok || bad "(S6) the skip line names the lock"

[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 vendor calls: [$(cat "$T/calls/vendor")]"

echo "triage-shards-building.bh-9113: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/triage-state-pr-contract.bh-3418-test.sh — BH-3418 (BH-3417 slice 1):
# the PR pre-check seams, wired end to end but INERT.
#
#   K1  ts_pr_mode resolves PR_STATE_MODE from the settings rows (per project),
#       garbage reads as shadow
#   K2  the triage-state-off kill switch answers `off` before any settings read
#   NR  no root: ts_pr_precheck sets the four TS_PR_* defaults, writes nothing
#   S1  the stub leaves READY=0 / SKIPSET=" " / DRAFTS="" and writes nothing
#   U1  ts_unit_skip's pr-* branch (and the ticket branch beside it)
#   U2  ts_tick through the real stub never sets TS_PR_ENFORCING; with a ready
#       pre-check it does, only on an allowlisted gate reason
#   E1  _ts_enforce_reason's allowlist
#   P1  _ts_owned still answers owned:pr-unreadable; P2 one PR fetch per tick
#   R1  ts_precheck clears pr-decisions.tsv
#   L1  _ts_libs loads triage-state-pr.sh and verdicts.sh
#   Y1  bin/triage-state-pr.py CLI stubs
#   B1  shards.sh untouched, no GraphQL, the `^board prs:` $0-end guard intact
#
# Run from anywhere: tests/triage-state-pr-contract.bh-3418-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

LIB="$DIR/bin/lib/triage-state.sh"
PRLIB="$DIR/bin/lib/triage-state-pr.sh"
PRPY="$DIR/bin/triage-state-pr.py"
[ -r "$PRLIB" ] && ok || bad "bin/lib/triage-state-pr.sh must exist"
[ -r "$PRPY" ] && ok || bad "bin/triage-state-pr.py must exist"

# ── NR: no root ─────────────────────────────────────────────────────────────
NR="$T/noroot"; mkdir -p "$NR"
NROUT=$( cd "$NR" && unset HARNESS H LOG && PROJECT=p && . "$LIB" && . "$PRLIB" \
         && ts_pr_precheck p; echo "rc=$? mode=$TS_PR_MODE ready=$TS_PR_READY skip=[$TS_PR_SKIPSET] drafts=[$TS_PR_DRAFTS]" ) 2>&1
[ "$NROUT" = "rc=0 mode=off ready=0 skip=[ ] drafts=[]" ] && ok || bad "(NR) no root: the four defaults, rc 0 [$NROUT]"
[ -z "$(cd "$NR" && find . -mindepth 1 | head -1)" ] && ok || bad "(NR) no root writes nothing: $(cd "$NR" && find . -mindepth 1)"
! grep -n '/root/harness' "$PRLIB" >/dev/null 2>&1 && ok || bad "(NR) triage-state-pr.sh carries no /root/harness literal (D43)"

# ── the scratch harness ─────────────────────────────────────────────────────
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
H="$T/h"; P=project-5
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/flags" "$H/catalog"
cp "$DIR"/bin/lib/*.sh "$H/bin/lib/"
cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
cache() { # cache <json values> — a fresh settings cache, as lib_env_apply reads it
  printf '{"fetched_at":%s,"values":%s,"seeded":{}}' "$(date -u +%s)" "$1" > "$H/state/settings-cache.json"   # determinism: ok — a fresh cache
}
# mode_of — ts_pr_mode through the production loader (_ts_libs), in a clean shell
mode_of() {
  env -u PR_STATE_MODE -u TRIAGE_STATE_MODE HARNESS="$H" PROJECT="$P" LOG="$T/lane.log" \
    bash -c '. "$1" && _ts_libs && ts_pr_mode "$2"' _ "$LIB" "$P" 2>/dev/null
}

# ── L1: _ts_libs loads the PR lib and the verdicts lib ──────────────────────
L1=$( env HARNESS="$H" bash -c '. "$1" && _ts_libs && command -v ts_pr_precheck && command -v vd_standing' _ "$LIB" 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "(L1) _ts_libs defines ts_pr_precheck and vd_standing [$L1]"

# ── K1: the knob ────────────────────────────────────────────────────────────
cache '{}'
[ "$(mode_of)" = shadow ] && ok || bad "(K1) no row reads shadow: [$(mode_of)]"
cache '{"lib.triage-state.project-5.pr_state_mode":"enforce"}'
[ "$(mode_of)" = enforce ] && ok || bad "(K1) the per-project row enforce reads enforce: [$(mode_of)]"
cache '{"lib.triage-state.pr_state_mode":"off"}'
[ "$(mode_of)" = off ] && ok || bad "(K1) the fleet row off reads off: [$(mode_of)]"
cache '{"lib.triage-state.project-5.pr_state_mode":"banana"}'
[ "$(mode_of)" = shadow ] && ok || bad "(K1) garbage reads shadow: [$(mode_of)]"
jq -e '.libs[] | select(.id=="triage-state") | .knobs[] | select(.env=="PR_STATE_MODE" and .settable==true and .default=="shadow" and .read_in=="bin/lib/triage-state-pr.sh")' \
  "$DIR/catalog/lanes.json" >/dev/null 2>&1 && ok || bad "(K1) PR_STATE_MODE is a registered, settable lib knob"

# ── K2: the kill switch comes first ─────────────────────────────────────────
cache '{"lib.triage-state.project-5.pr_state_mode":"enforce"}'
touch "$H/flags/triage-state-off"; rm -f "$T/lea.calls" "$T/lane.log"
K2=$( env -u PR_STATE_MODE HARNESS="$H" PROJECT="$P" LOG="$T/lane.log" CALLS="$T/lea.calls" bash -c '
  . "$1" && _ts_libs
  lib_env_apply() { echo "$*" >> "$CALLS"; }
  ts_pr_mode "$2"' _ "$LIB" "$P" 2>&1 )
[ "$K2" = off ] && ok || bad "(K2) the kill switch reads off: [$K2]"
[ ! -s "$T/lea.calls" ] && ok || bad "(K2) no settings read under the switch: $(cat "$T/lea.calls")"
[ ! -e "$T/lane.log" ] && [ ! -e "$H/logs/$P.log" ] && ok || bad "(K2) no lane-log line under the switch"
rm -f "$H/flags/triage-state-off"
grep -q 'bin/lib/triage-state-pr.sh' <(jq -r '.readers[]' "$DIR/catalog/switches.d/triage-state-off.json") && ok \
  || bad "(K2) the switch registry names bin/lib/triage-state-pr.sh as a reader"

# ── S1: the stub, with a root ───────────────────────────────────────────────
for m in shadow enforce; do
  cache "{\"lib.triage-state.project-5.pr_state_mode\":\"$m\"}"
  S1=$( env -u PR_STATE_MODE HARNESS="$H" PROJECT="$P" LOG="$T/lane.log" bash -c '
    . "$1" && _ts_libs && ts_pr_precheck "$2"; echo "rc=$? mode=$TS_PR_MODE ready=$TS_PR_READY skip=[$TS_PR_SKIPSET] drafts=[$TS_PR_DRAFTS]"' _ "$LIB" "$P" 2>&1 )
  [ "$S1" = "rc=0 mode=$m ready=0 skip=[ ] drafts=[]" ] && ok || bad "(S1) $m: the stub is inert [$S1]"
done
[ ! -e "$H/state/triage-state" ] && [ ! -e "$T/lane.log" ] && ok || bad "(S1) the stub writes and logs nothing: $(find "$H/state/triage-state" "$T/lane.log" 2>/dev/null)"

# ── U1 / E1 / P1 / P2 run in this shell against the real libs ───────────────
# shellcheck source=/dev/null
. "$LIB"
# shellcheck source=/dev/null
. "$PRLIB"
u() { ( eval "$1"; ts_unit_skip "" "$2" ); echo $?; }
[ "$(u 'TS_PR_ENFORCING=1 TS_PR_SKIPSET=" pr-7 "' pr-7)" = 0 ] && ok || bad "(U1) enforcing and in the set: skip"
[ "$(u 'TS_PR_ENFORCING=0 TS_PR_SKIPSET=" pr-7 "' pr-7)" = 1 ] && ok || bad "(U1) not enforcing: dispatch"
[ "$(u 'TS_PR_ENFORCING=1 TS_PR_SKIPSET=" pr-8 "' pr-7)" = 1 ] && ok || bad "(U1) key absent: dispatch"
[ "$(u 'TS_PR_ENFORCING=1 TS_PR_SKIPSET=" pr-12 "' pr-1)" = 1 ] && ok || bad "(U1) pr-1 is not pr-12: dispatch"
[ "$(u 'TS_ENFORCING=1 TS_SKIPSET=" pr-7 " TS_PR_ENFORCING=0' pr-7)" = 1 ] && ok || bad "(U1) a pr key never rides the ticket set"
[ "$(u 'TS_ENFORCING=0 TS_PR_ENFORCING=1 TS_PR_SKIPSET=" 11 "' 11)" = 1 ] && ok || bad "(U1) a ticket key ignores the PR set"
[ "$(u 'TS_ENFORCING=1 TS_SKIPSET=" 11 "' 11)" = 0 ] && ok || bad "(U1) the ticket branch skips as today"

for r in board-changed event-wake daily-sweep queue-pending results-sweep remote-results-pending split-ready; do
  ( GATE_REASON=$r; _ts_enforce_reason ) && ok || bad "(E1) $r is an enforce reason"
done
for r in forced gate-error ""; do
  ( GATE_REASON=$r; _ts_enforce_reason ) && bad "(E1) '$r' is not an enforce reason" || ok
done

OWNH="$T/own"; mkdir -p "$OWNH/state/triage-state/$P"
P1=$( HARNESS="$OWNH"; PROJECT="$P"; TRIAGE_GH_SLUG=org/x
      queue_status() { return 2; }; gh_rest_pr_list() { return 1; }
      _ts_owned 11 TK-11 h "" 1 ); RC=$?
[ "$RC" = 0 ] && [ "$P1" = owned:pr-unreadable ] && ok || bad "(P1) a failed PR read owns the launch [rc=$RC out=$P1]"
[ "$(cat "$OWNH/state/triage-state/$P/prs.json")" = unreadable ] && ok || bad "(P1) prs.json carries the unreadable marker"
rm -f "$OWNH/state/triage-state/$P/prs.json"; : > "$T/prcalls"
( HARNESS="$OWNH"; PROJECT="$P"; TRIAGE_GH_SLUG=org/x
  gh_rest_pr_list() { echo "$*" >> "$T/prcalls"; echo '[]'; }
  _ts_prs_json "$P" "$OWNH/state/triage-state/$P"; _ts_prs_json "$P" "$OWNH/state/triage-state/$P" )
[ "$(wc -l < "$T/prcalls")" = 1 ] && [ "$(cat "$T/prcalls")" = "org/x open  100" ] && ok || bad "(P2) one REST fetch per tick: [$(cat "$T/prcalls")]"
[ "$(cat "$OWNH/state/triage-state/$P/prs.json")" = "[]" ] && ok || bad "(P2) prs.json is the array"

# ── R1: ts_precheck clears the PR decisions file ────────────────────────────
mkdir -p "$H/state/triage-state/$P"; : > "$H/state/triage-state/$P/pr-decisions.tsv"
touch "$H/flags/triage-state-off"
( HARNESS="$H" PROJECT="$P" LOG="$T/lane.log"; ts_precheck ) >/dev/null 2>&1
[ ! -e "$H/state/triage-state/$P/pr-decisions.tsv" ] && ok || bad "(R1) ts_precheck removes pr-decisions.tsv"
rm -f "$H/flags/triage-state-off"; scratch_rm "$H/state/triage-state"

# ── U2: ts_tick, the production hook ────────────────────────────────────────
# tick <gate-reason> [ready-stub] — ts_tick with the ticket pre-check stubbed to
# shadow, in a fresh shell over the real libs; prints TS_PR_ENFORCING and
# ts_unit_skip's rc for pr-3381.
tick() {
  env -u TRIAGE_STATE_MODE HARNESS="$H" PROJECT="$P" LOG="$T/lane.log" PR_STATE_MODE=enforce GATE_REASON="$1" READY="${2:-}" \
    BOARD_SEC=$'board changes:\nboard prs: NEW 3381' bash -c '
    . "$1"; _ts_libs
    ts_precheck() { TS_MODE=shadow; TS_READY=1; TS_SUMMARY=x; }
    if [ -n "$READY" ]; then
      ts_pr_precheck() { TS_PR_MODE=$(ts_pr_mode "$PROJECT"); TS_PR_READY=1; TS_PR_SKIPSET=" pr-3381 "; TS_PR_DRAFTS=""; }
    fi
    ts_tick; echo "rc=$? enf=$TS_PR_ENFORCING mode=$TS_PR_MODE"
    ts_unit_skip "" pr-3381; echo "skip=$?"' _ "$LIB" 2>&1
}
cache '{}'
U2=$(tick board-changed)
[ "$U2" = $'rc=0 enf=0 mode=enforce\nskip=1' ] && ok || bad "(U2) the real stub never enforces, pr-3381 is dispatched [$U2]"
U2=$(tick board-changed ready)
[ "$U2" = $'rc=0 enf=1 mode=enforce\nskip=0' ] && ok || bad "(U2) a ready enforce pre-check on a board tick enforces [$U2]"
U2=$(tick forced ready)
[ "$U2" = $'rc=0 enf=0 mode=enforce\nskip=1' ] && ok || bad "(U2) a forced tick never enforces the PR set [$U2]"
U2=$(env -u TRIAGE_STATE_MODE HARNESS="$H" PROJECT="$P" LOG="$T/lane.log" PR_STATE_MODE=shadow GATE_REASON=board-changed bash -c '
       . "$1"; _ts_libs
       ts_precheck() { TS_MODE=shadow; TS_READY=1; TS_SUMMARY=x; }
       ts_pr_precheck() { TS_PR_MODE=$(ts_pr_mode "$PROJECT"); TS_PR_READY=1; TS_PR_SKIPSET=" pr-3381 "; TS_PR_DRAFTS=""; }
       ts_tick; echo "enf=$TS_PR_ENFORCING"' _ "$LIB" 2>&1)
[ "$U2" = "enf=0" ] && ok || bad "(U2) READY=1 in shadow never enforces [$U2]"
# a box mid-sync with no PR lib: ts_tick still runs, the defaults stand
MID="$T/mid"; mkdir -p "$MID/bin/lib" "$MID/state" "$MID/logs" "$MID/flags" "$MID/catalog"
cp "$DIR"/bin/lib/*.sh "$MID/bin/lib/"; rm -f "$MID/bin/lib/triage-state-pr.sh"; cp "$H/catalog/lanes.json" "$MID/catalog/"
MO=$( env HARNESS="$MID" PROJECT="$P" LOG="$T/mid.log" bash -c '
  . "$1"; ts_precheck() { TS_MODE=shadow; TS_READY=0; }
  ts_tick; echo "rc=$? enf=$TS_PR_ENFORCING mode=$TS_PR_MODE"' _ "$LIB" 2>&1 )
[ "$MO" = "rc=0 enf=0 mode=off" ] && ok || bad "(U2) no PR lib on the box: defaults, no error [$MO]"
[ ! -e "$T/lane.log" ] && ok || bad "(U2) the PR path logs nothing: $(cat "$T/lane.log")"

# ── Y1: the Python CLI stubs ────────────────────────────────────────────────
python3 "$DIR/bin/triage-state-pr.py" pr-hash --thread a --pr b --reviews c --lead d >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "(Y1) pr-hash is a stub: rc 1 [$RC]"
python3 "$DIR/bin/triage-state-pr.py" pr-draft --title t --head-ref r >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "(Y1) pr-draft is a stub: rc 1 [$RC]"
python3 -c 'import importlib.util as u, sys; s=u.spec_from_file_location("m", sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m); sys.exit(0 if m.mergify_state([]) is None else 1)' \
  "$DIR/bin/triage-state-pr.py" 2>/dev/null && ok || bad "(Y1) mergify_state([]) is None"

# ── B1 / D1: what this slice must not touch ─────────────────────────────────
# The fence is the BH-3418 slice's own (D57): it binds only a range that holds
# a BH-3418 commit. A later ticket may edit shards.sh (BH-9113 did).
if git -C "$DIR" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  B1_OWN=$(git -C "$DIR" log --format=%h -i -E --grep='^bh-3418([^0-9]|$)' origin/main..HEAD 2>/dev/null)
  if [ -z "$B1_OWN" ]; then
    echo "triage-state-pr-contract: (B1) no BH-3418 commit in origin/main..HEAD, the shards.sh fence is skipped"
  else
    [ -z "$(git -C "$DIR" diff origin/main -- bin/lib/rt/shards.sh)" ] && ok || bad "(B1) bin/lib/rt/shards.sh is not edited"
  fi
else
  echo "triage-state-pr-contract: (B1) no origin/main here, shards.sh diff check skipped"
fi
[ "$(cat "$PRLIB" "$PRPY" 2>/dev/null | grep -ci graphql)" = 0 ] && ok || bad "(D1) no GraphQL in the new files"
TICKSRC=$(sed -n '/^ts_tick()/,/^}/p' "$LIB")
case "$TICKSRC" in *"grep -qE 'UNBLOCKED|STACKABLE|^board prs:'"*) ok ;; *) bad "(B1) the ^board prs: \$0-end guard is intact" ;; esac

echo "triage-state-pr-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

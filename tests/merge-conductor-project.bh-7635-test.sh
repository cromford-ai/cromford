#!/bin/bash
# tests/merge-conductor-project.bh-7635-test.sh — BH-7635 (C0): a step a Fly
# project run of the merge conductor leaves to the hub (deferred=<words>)
# never hands the WHOLE project tick back to the hub. The machine records the
# PR of each deferred step (MC_PR_DEFERRED_KEYS_FILE -> the PROF field
# deferred_prs=), and the hub gate turns such a row into a KEYED hub tick of
# only those PRs (mc_proj_gate rc 4 -> mc_proj_takeback_keyed). A failed run
# still hands the hub one full tick.
#
# The real bin/lib/mc/project-placement.sh, bin/lib/mc/fly-workers.sh and
# bin/lib/mc/log.sh run in a scratch HARNESS root. The gate's jobs worker and
# settings I/O are stubs (the bh-7462 suite's set), fleet-conf.sh answers
# example-org/mk for project mk, and bin/merge-conductor.sh in the scratch root
# is a stub that records the env it was started with. tick_project is the
# REAL function body of bin/merge-conductor.sh down to `# <<< project on a
# machine`, cut out and closed with `return 99` (= "the full tick runs on").
#
#   W1-W4  mc_defer_word, and the real writers (mc_rereview_spawn,
#          mc_rebase_spawn, _mc_remote_defer, conductor_settle) on a machine
#   F1-F4  mc_proj_defer_field values and the 512-byte PROF bound
#   R1     the real bin/merge-conductor-project.sh prints deferred_prs=
#   D-a..n the keyed/full decision of mc_proj_defer_keys
#   G1-G4  the gate's rc 4, the keyed child, the next-tick enqueue, fallback off
#   X1-X2  a failed row keeps rc 2 and the full tick
#   E1     the write-back apply fails: owed, no keyed child
#   L1-L2  one route line per tick, both shapes
#   RT1-2  the round trips
#   RP1    the 2026-10-19 22:30Z-23:30Z replay: 40 ticks
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-project.bh-7635-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"; D="$H/state/merge-conductor/project-fly"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/locks" "$H/state" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh bin/merge-conductor-project.sh bin/lib/merge-conductor-lib.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
for f in bin/lib/mc/log.sh bin/lib/mc/project-placement.sh; do
  [ -f "$H/$f" ] || cp "$DIR/$f" "$H/$f"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
printf '#!/usr/bin/env bash\n[ "$1" = mk ] && [ "$2" = repo ] && { echo example-org/mk; exit 0; }\nexit 1\n' > "$H/bin/fleet-conf.sh"
# The stub conductor: one env line per start, then (R1) an optional script.
cat > "$H/bin/merge-conductor.sh" <<EOF
#!/usr/bin/env bash
printf 'run only_pr=%s only_project=%s takeback=%s single=%s\n' "\${MC_ONLY_PR:-}" "\${MC_ONLY_PROJECT:-}" "\${MC_PROJ_TAKEBACK:-}" "\${MC_FULL_TICK_SINGLE:-}" >> "$T/runs.txt"
[ -r "$T/conductor-body.sh" ] && . "$T/conductor-body.sh"
exit 0
EOF
chmod +x "$H/bin/"*.sh

cat > "$T/stubs.sh" <<EOF
lp_decide() { LP_PLACE=fly; LP_WHY="row fly"; }
_lp_client() { return 0; }
_setting_key_ok() { return 0; }
setting_get() { cat "$T/settings/\$1" 2>/dev/null; }
lp_enqueue() { echo "enqueue \$2" >> "$T/enqueues.txt"; return 0; }
lri_apply_pending() { [ -e "$T/apply-fail" ] && { echo "applied=0 (lock busy)"; return 1; }; echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
_jobs_req() {
  [ "\$1" = GET ] && { cat "$T/rows.json"; return 0; }
  JOBS_HTTP=200; JOBS_BODY='{}'; return 0
}
EOF

# The REAL tick_project, down to the end of its BH-6890 gate block.
{ sed -n '/^tick_project() {/,/# <<< project on a machine/p' "$DIR/bin/merge-conductor.sh"; printf '  return 99\n}\n'; } > "$T/tick_project.sh"
grep -q 'mc_fly_project_gate "\$P"' "$T/tick_project.sh" || bad "setup: tick_project's gate block was not found in bin/merge-conductor.sh"
cat > "$T/driver.sh" <<EOF
. "$H/bin/lib/mc/fly-workers.sh"
. "$T/stubs.sh"
MC_LOG="$H/logs/merge-conductor.log"; MC_LOCK_DIR="$H/locks"; H="$H"
mc_log() { printf '%s\n' "\$*" >> "\$MC_LOG"; }
mc_safe_name() { printf '%s' "\${1//[^A-Za-z0-9._-]/_}"; }
hb_tick() { :; }
. "$T/tick_project.sh"
EOF

row() { # row <id> <status> [prof_line] [rc] [age-s] [project]
  jq -nc --argjson id "$1" --arg s "$2" --arg pl "${3:-}" --arg rc "${4:-}" --arg at "$(date -u -d "@$(( $(date -u +%s) - ${5:-30} ))" +%FT%TZ)" --arg p "${6:-mk}" \
    '{rows:[{id:$id, project:$p, status:$s, prof_line:$pl, rc:($rc|tonumber? // null), enqueued_at:$at}]}' > "$T/rows.json"
}
DONE2="PROF mc-project state=TICKED landed=0 queued=0 deferred=rebase,rereview fence=4 deferred_prs=2:rebase/14,rereview/12"
# gate — mc_proj_gate mk in its own process. Sets RC; prints the keys line.
gate() {
  HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_gate mk 600; rc=\$?; echo \"keys=\${MC_PROJ_TAKEBACK_KEYS:-}\" > \"$T/gate.keys\"; mc_proj_hub_unmark mk; exit \$rc" 2>>"$T/gate.log"; RC=$?
}
# tick [keyed] — one hub tick of mk through the real tick_project, then the
# unmark (the driver's tick subshell). keyed = a backstop tick (MC_ONLY_KEYS
# set). Writes `full` to $T/fulls.txt when the full tick runs on (rc 99).
tick() {
  local k=""; [ "${1:-}" = keyed ] && k=" example-org/mk#99 "
  HARNESS="$H" MC_LOG_K="$k" bash -c ". \"$T/driver.sh\"; MC_ONLY_KEYS=\"\$MC_LOG_K\"; tick_project mk; rc=\$?; mc_proj_hub_unmark mk; [ \"\$rc\" = 99 ] && echo full >> \"$T/fulls.txt\"; exit 0" 2>>"$T/gate.log"
}
reset() {
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/apply-fail" "$T/enqueues.txt" "$T/runs.txt" "$T/fulls.txt" "$T/conductor-body.sh"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"; : > "$H/logs/merge-conductor.log"
}
cnt() { [ -f "$1" ] && grep -c "${2:-.}" "$1" || echo 0; }
LOGS() { cat "$T/gate.log" "$H/logs/merge-conductor.log" 2>/dev/null; }

# ============================================================================
echo "W: mc_defer_word and the real writers"
# shellcheck source=/dev/null
( HARNESS="$H" . "$H/bin/lib/mc/log.sh" 2>/dev/null
  W="$T/w"; mkdir -p "$W"; : > "$W/words"; : > "$W/keys"
  MC_PR_DEFERRED_FILE="$W/words" MC_PR_DEFERRED_KEYS_FILE="$W/keys" mc_defer_word rebase example-org/mk#14
  echo "rc=$?" > "$W/w1.rc"
  : > "$W/words2"; MC_PR_DEFERRED_FILE="$W/words2" mc_defer_word settle example-org/mk#9
  : > "$W/words3"; : > "$W/keys3"
  MC_PR_DEFERRED_FILE="$W/words3" MC_PR_DEFERRED_KEYS_FILE="$W/keys3" mc_defer_word dv ""
  MC_PR_DEFERRED_FILE="$W/words3" MC_PR_DEFERRED_KEYS_FILE="$W/keys3" mc_defer_word land "example-org/mk#x1"
  MC_PR_DEFERRED_FILE="$W/words3" MC_PR_DEFERRED_KEYS_FILE="$W/keys3" mc_defer_word land "a b#3"
  echo "rc=$?" > "$W/w3.rc" )
[ "$(cat "$T/w/words")" = rebase ] && [ "$(cat "$T/w/keys")" = "rebase example-org/mk#14" ] && [ "$(cat "$T/w/w1.rc")" = rc=0 ] \
  && ok "W1 the word goes to the words file and '<word> <key>' to the keys file" || bad "W1 words='$(cat "$T/w/words")' keys='$(cat "$T/w/keys")'"
[ "$(cat "$T/w/words2")" = settle ] && ok "W2 no keys file: only the word, as today" || bad "W2 words='$(cat "$T/w/words2")'"
[ "$(paste -sd, "$T/w/words3")" = dv,land,land ] && [ ! -s "$T/w/keys3" ] && [ "$(cat "$T/w/w3.rc")" = rc=0 ] \
  && ok "W3 an empty or bad key: the word only, rc 0" || bad "W3 words='$(paste -sd, "$T/w/words3")' keys='$(cat "$T/w/keys3")'"
# W4: the production writers on a lane-run machine (MC_ON_MACHINE=1).
mkdir -p "$T/w4"; : > "$T/w4/words"; : > "$T/w4/keys"
( export HARNESS="$H" MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$T/w4/words" MC_PR_DEFERRED_KEYS_FILE="$T/w4/keys"
  # shellcheck source=/dev/null
  . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
  mc_remote_on() { return 1; }
  mc_rereview_spawn example-org/mk 12 mk "https://github.com/example-org/mk/pull/12" r h rec >/dev/null 2>&1
  mc_rebase_spawn example-org/mk 14 mk ticket/x h "https://github.com/example-org/mk/pull/14" >/dev/null 2>&1
  _mc_remote_defer "example-org/mk#15" dd why >/dev/null 2>&1
  conductor_settle "example-org/mk#9" u mk example-org/mk br rec job h rev v CLEAN why >/dev/null 2>&1 ) 2>/dev/null
[ "$(paste -sd, "$T/w4/words")" = rereview,rebase,rebase,settle ] \
  && ok "W4 the words file is unchanged in form (rereview,rebase,rebase,settle)" || bad "W4 words='$(paste -sd, "$T/w4/words")'"
[ "$(paste -sd, "$T/w4/keys")" = "rereview example-org/mk#12,rebase example-org/mk#14,rebase example-org/mk#15,settle example-org/mk#9" ] \
  && ok "W4 each real writer records its PR (rereview #12, rebase #14, remote rebase #15, settle #9)" || bad "W4 keys='$(paste -sd, "$T/w4/keys")'"
grep -q 'mc_defer_word land "\$KEY"' "$DIR/bin/merge-conductor.sh" && ! grep -q 'echo land >> "\$MC_PR_DEFERRED_FILE"' "$DIR/bin/merge-conductor.sh" \
  && ok "W4 the driver's land writer records its key" || bad "W4 the land writer at bin/merge-conductor.sh does not call mc_defer_word"

# ============================================================================
echo "F: mc_proj_defer_field"
# shellcheck source=bin/lib/mc/project-placement.sh
HARNESS="$H" . "$H/bin/lib/mc/project-placement.sh"
fld() { printf '%s' "$1" > "$T/kf"; HARNESS="$H" mc_proj_defer_field "$T/kf" "${2:-example-org/mk}"; }
[ "$(fld $'rereview example-org/mk#12\nrebase example-org/mk#14\nrebase example-org/mk#14\n')" = "2:rebase/14,rereview/12" ] \
  && ok "F1 two steps give 2:rebase/14,rereview/12 (sorted, unique)" || bad "F1 got '$(fld $'rereview example-org/mk#12\nrebase example-org/mk#14\n')'"
[ "$(fld '')" = - ] && ok "F2 no lines give -" || bad "F2 got '$(fld '')'"
[ "$(HARNESS="$H" mc_proj_defer_field "$T/no-such-file" example-org/mk)" = - ] && ok "F2 no file gives -" || bad "F2 no file"
[ "$(fld $'rebase Other/repo#3\nsettle example-org/MK#9\n')" = "1:settle/9" ] \
  && ok "F3 a different slug is dropped; the slug compare ignores case" || bad "F3 got '$(fld $'rebase Other/repo#3\nsettle example-org/MK#9\n')'"
K60=$(for i in $(seq 1000 1059); do echo "rereview example-org/mk#$i"; done)
[ "$(fld "$K60")" = overflow ] && ok "F4 60 keys give overflow" || bad "F4 got '$(fld "$K60")'"
MAXOK=""; for n in $(seq 1 60); do
  v=$(fld "$(for i in $(seq 100000 $((100000 + n - 1))); do echo "rereview example-org/mk#$i"; done)")
  [ "$v" = overflow ] && break; MAXOK="$v"
done
LINE="PROF mc-project state=LEASE_UNAVAILABLE landed=999 queued=999 deferred=dv,enqueue,land,merge,rebase,rereview,settle fence=99999999999 deferred_prs=$MAXOK"
[ "${#MAXOK}" -le 360 ] && [ "${#LINE}" -le 512 ] && ok "F4 the longest kept value (${#MAXOK} B) fits a worst-case PROF line (${#LINE} B <= 512)" \
  || bad "F4 value ${#MAXOK} B, line ${#LINE} B"

# ============================================================================
echo "R1: the real bin/merge-conductor-project.sh prints deferred_prs="
R1="$T/r1"; mkdir -p "$R1/h/bin/lib/mc" "$R1/h/logs"
cp -a "$H/bin/." "$R1/h/bin/"
cat > "$R1/h/bin/jobs-client.sh" <<'EOF'
_jobs_req() { return 1; }
EOF
cat > "$R1/h/bin/lib/project-lease.sh" <<'EOF'
pjl_acquire() { echo 7; }
pjl_renew() { return 0; }
pjl_release() { return 0; }
EOF
: > "$R1/h/bin/lib/lane-run-inputs.sh"
cat > "$T/conductor-body.sh" <<EOF
. "$R1/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
mc_remote_on() { return 1; }
mc_rereview_spawn example-org/mk 12 mk "https://github.com/example-org/mk/pull/12" r h rec >/dev/null 2>&1
EOF
# To a file, not $(...): the renew loop's orphaned `sleep` would hold a pipe.
HARNESS="$R1/h" "$R1/h/bin/merge-conductor-project.sh" mk >"$T/r1.out" 2>"$T/r1.err"; rc=$?; OUT=$(cat "$T/r1.out")
rm -f "$T/conductor-body.sh"
[ "$rc" = 0 ] && grep -qE '^PROF mc-project state=TICKED landed=0 queued=0 deferred=rereview fence=7 deferred_prs=1:rereview/12$' <<<"$OUT" \
  && ok "R1 PROF ... deferred=rereview fence=7 deferred_prs=1:rereview/12" || bad "R1 rc=$rc out='$OUT' err=$(tail -3 "$T/r1.err")"
HARNESS="$R1/h" "$R1/h/bin/merge-conductor-project.sh" mk >"$T/r1.out" 2>>"$T/r1.err"; OUT=$(cat "$T/r1.out")
grep -qE '^PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=7 deferred_prs=-$' <<<"$OUT" \
  && ok "R1 a run that defers nothing prints deferred_prs=-" || bad "R1 clean out='$OUT'"

# ============================================================================
echo "D: the keyed/full decision"
rows1() { jq -nc --arg pl "$1" --argjson rc "${2:-0}" --arg p "${3:-mk}" '{rows:[{id:5, project:$p, status:"done", rc:$rc, prof_line:$pl}]}'; }
dk() { # dk <case> <prof> <words> <want rc> <want out> [rows-json]
  local rows out rc; rows="${6:-$(rows1 "$2")}"
  out=$(HARNESS="$H" mc_proj_defer_keys "$rows" mk example-org/mk "$3"); rc=$?
  if [ "$rc" = "$4" ] && [ "$out" = "$5" ]; then ok "D-$1 rc $rc '$out'"; else bad "D-$1 rc=$rc out='$out' (want rc $4 '$5')"; fi
}
P0="PROF mc-project state=TICKED landed=0 queued=0"
dk a "$P0 deferred=rebase,rereview fence=4 deferred_prs=2:rebase/14,rereview/12" rebase,rereview 0 "example-org/mk#12,example-org/mk#14"
MC_PROJ_DEFER_ROUTE=""; HARNESS="$H" mc_proj_defer_keys "$(rows1 "$P0 deferred=rebase,rereview fence=4 deferred_prs=2:rebase/14,rereview/12")" mk example-org/mk rebase,rereview >/dev/null
[ "$MC_PROJ_DEFER_ROUTE" = "rebase -> hub keyed example-org/mk#14; rereview -> hub keyed example-org/mk#12" ] \
  && ok "D-a MC_PROJ_DEFER_ROUTE names each step's PR" || bad "D-a route='$MC_PROJ_DEFER_ROUTE'"
dk b "$P0 deferred=settle fence=4 deferred_prs=1:settle/9" settle 0 "example-org/mk#9"
dk c "$P0 deferred=rereview fence=4 deferred_prs=2:rereview/12,rereview/13" rereview 0 "example-org/mk#12,example-org/mk#13"
dk d "$P0 deferred=land,settle fence=4 deferred_prs=2:land/7,settle/7" land,settle 0 "example-org/mk#7"
dk e "$P0 deferred=settle fence=4" settle 1 "no PR names"
dk f "$P0 deferred=rebase,settle fence=4 deferred_prs=1:rebase/14" rebase,settle 1 "settle has no PR"
dk g "$P0 deferred=rebase,rereview fence=4 deferred_prs=3:rebase/14,rereview/12" rebase,rereview 1 "list truncated"
dk h "$P0 deferred=rebase,rereview fence=4 deferred_prs=2:rebase/14,rereview/1x" rebase,rereview 1 "bad token rereview/1x"
dk i "$P0 deferred=rebase fence=4 deferred_prs=overflow" rebase 1 "overflow"
dk j "$P0 deferred=rebase fence=4 deferred_prs=-" rebase 1 "no PR names"
dk k "$P0 deferred=rebase fence=4 deferred_prs=2:rebase/14,land/3" rebase 1 "step land not in deferred="
dk l "$P0 deferred=rebase fence=4 xdeferred_prs=1:rebase/14" rebase 1 "no PR names"
NROWS=$(jq -nc --arg a "$P0 deferred=rebase fence=4 deferred_prs=1:rebase/14" --arg b "$P0 deferred=settle fence=4" \
  '{rows:[{id:9, project:"mkx", status:"done", rc:0, prof_line:$a}, {id:8, project:"mk", status:"done", rc:0, prof_line:$b}]}')
dk n "(rows: mkx newest)" settle 1 "no PR names" "$NROWS"
# D-m: a failed row that carries a valid field stays machine-failed (gate).
reset; row 61 done "$P0 deferred=rebase fence=4 deferred_prs=1:rebase/14" 1; gate
[ "$RC" = 2 ] && grep -q 'fallback=machine-failed (row 61: rc=1)' "$T/gate.log" && ! grep -q 'hub keyed' "$T/gate.log" \
  && ok "D-m a failed row with a valid field: rc 2, machine-failed" || bad "D-m rc=$RC log: $(LOGS)"

# ============================================================================
echo "G: the gate answers rc 4 and the hub runs a keyed tick"
reset; row 41 done "$DONE2" 0; gate
[ "$RC" = 4 ] && [ "$(cat "$T/gate.keys")" = "keys=example-org/mk#12,example-org/mk#14" ] \
  && ok "G1 rc 4 with MC_PROJ_TAKEBACK_KEYS=example-org/mk#12,example-org/mk#14" || bad "G1 rc=$RC $(cat "$T/gate.keys") log: $(LOGS)"
[ "$(head -n1 "$D/mk.taken" 2>/dev/null)" = 41 ] && [ "$(cnt "$T/enqueues.txt")" = 0 ] && ok "G1 the row is taken once, nothing enqueued" || bad "G1 taken/enqueue"
echo "L1: the route line"
[ "$(grep -c 'project-fly: deferred row' "$T/gate.log")" = 1 ] \
  && grep -qx 'mk project-fly: deferred row 41: rebase -> hub keyed example-org/mk#14; rereview -> hub keyed example-org/mk#12 — no full hub tick' "$T/gate.log" \
  && ok "L1 exactly one route line names each step's PR" || bad "L1 log: $(cat "$T/gate.log")"
for mode in full keyed; do
  reset; row 42 done "$DONE2" 0; tick "$mode"
  [ "$(cnt "$T/fulls.txt")" = 0 ] && [ "$(cnt "$T/runs.txt")" = 1 ] \
    && grep -qx 'run only_pr=example-org/mk#12,example-org/mk#14 only_project=mk takeback=1 single=0' "$T/runs.txt" \
    && ok "G2 ($mode tick) 0 full ticks, 1 keyed run of exactly the 2 named PRs" || bad "G2 ($mode) fulls=$(cnt "$T/fulls.txt") runs: $(cat "$T/runs.txt" 2>/dev/null) log: $(LOGS)"
  grep -q "TICK mk: the hub runs the machine's deferred steps — a keyed tick of example-org/mk#12,example-org/mk#14 (no full tick)" "$H/logs/merge-conductor.log" \
    && ok "G2 ($mode tick) the keyed take-back logs its keys" || bad "G2 ($mode) log: $(LOGS)"
  [ ! -e "$D/mk.hubtick" ] && ok "G2 ($mode tick) the hub mark ends with the tick" || bad "G2 ($mode) mark left"
done
tick
[ "$(cnt "$T/enqueues.txt")" = 1 ] && [ "$(cnt "$T/runs.txt")" = 1 ] && [ "$(cnt "$T/fulls.txt")" = 0 ] \
  && ok "G3 the same row on the next tick enqueues a new row, no hub work" || bad "G3 enq=$(cnt "$T/enqueues.txt") runs=$(cnt "$T/runs.txt")"
reset; echo off > "$T/settings/lane_fallback.merge-conductor.mk"; row 43 done "$DONE2" 0; tick
[ "$(cnt "$T/enqueues.txt")" = 1 ] && [ "$(cnt "$T/runs.txt")" = 0 ] && [ "$(cnt "$T/fulls.txt")" = 0 ] \
  && ok "G4 fallback off: one enqueue, nothing on the hub" || bad "G4 enq=$(cnt "$T/enqueues.txt") runs=$(cnt "$T/runs.txt") fulls=$(cnt "$T/fulls.txt")"

# ============================================================================
echo "X: a failed row still hands the hub one full tick"
reset; row 51 done "$P0 deferred=rebase fence=4 deferred_prs=1:rebase/14" 1; gate
[ "$RC" = 2 ] && grep -q 'fallback=machine-failed (row 51: rc=1)' "$T/gate.log" \
  && ok "X1 rc 2, fallback=machine-failed (even with deferred_prs=)" || bad "X1 rc=$RC log: $(LOGS)"
reset; row 52 died "" ""; tick
[ "$(cnt "$T/fulls.txt")" = 1 ] && [ "$(cnt "$T/runs.txt")" = 0 ] && ok "X2 (full tick) the full tick runs on, no keyed run" || bad "X2 fulls=$(cnt "$T/fulls.txt") runs: $(cat "$T/runs.txt" 2>/dev/null)"
reset; row 53 died "" ""; tick keyed
[ "$(cnt "$T/runs.txt")" = 1 ] && grep -qx 'run only_pr= only_project=mk takeback=1 single=0' "$T/runs.txt" \
  && ok "X2 (keyed tick) one full take-back tick of mk" || bad "X2 keyed runs: $(cat "$T/runs.txt" 2>/dev/null) log: $(LOGS)"

# ============================================================================
echo "E1: the write-back apply fails"
reset; touch "$T/apply-fail"; row 44 done "$DONE2" 0; tick
[ "$(cnt "$T/runs.txt")" = 0 ] && [ "$(cnt "$T/fulls.txt")" = 0 ] && [ -e "$D/mk.owed" ] && ! grep -q 'no full hub tick' "$T/gate.log" \
  && ok "E1 no keyed run, no route line, owed" || bad "E1 runs=$(cnt "$T/runs.txt") log: $(LOGS)"

# ============================================================================
echo "L2: a legacy row keeps the full tick and says why"
reset; row 45 done "$P0 deferred=settle fence=4" 0; gate
[ "$RC" = 2 ] && [ "$(grep -c 'project-fly: deferred row' "$T/gate.log")" = 1 ] \
  && grep -qx 'mk project-fly: deferred row 45: settle -> hub full tick (no PR names)' "$T/gate.log" \
  && ok "L2 rc 2 and exactly one route line: settle -> hub full tick (no PR names)" || bad "L2 rc=$RC log: $(cat "$T/gate.log")"

# ============================================================================
echo "RT: the round trips"
mkdir -p "$T/rt"; : > "$T/rt/words"; : > "$T/rt/keys"
( HARNESS="$H" . "$H/bin/lib/mc/log.sh" 2>/dev/null
  export MC_PR_DEFERRED_FILE="$T/rt/words" MC_PR_DEFERRED_KEYS_FILE="$T/rt/keys"
  mc_defer_word rereview example-org/mk#12; mc_defer_word rebase example-org/mk#14 )
DEFW=$(sort -u "$T/rt/words" | tr -cd 'a-z\n' | grep . | paste -sd, -)
LINE="PROF mc-project state=TICKED landed=0 queued=0 deferred=$DEFW fence=4 deferred_prs=$(HARNESS="$H" mc_proj_defer_field "$T/rt/keys" example-org/mk)"
RJ=$(rows1 "$LINE")
[ "$(HARNESS="$H" mc_proj_newest "$RJ" mk "$(date -u +%s)" 600)" = "deferred 5 rebase,rereview" ] \
  && ok "RT1 mc_proj_newest still reads deferred= with the new field" || bad "RT1 newest: $(HARNESS="$H" mc_proj_newest "$RJ" mk "$(date -u +%s)" 600) line: $LINE"
[ "$(HARNESS="$H" mc_proj_defer_keys "$RJ" mk example-org/mk "$DEFW")" = "example-org/mk#12,example-org/mk#14" ] \
  && ok "RT1 mc_proj_defer_keys reads the same keys back" || bad "RT1 keys: $(HARNESS="$H" mc_proj_defer_keys "$RJ" mk example-org/mk "$DEFW")"
[ "$(tr -cd 'a-z\n' < "$T/rt/words" | sort -u | paste -sd, -)" = rebase,rereview ] \
  && ok "RT2 the per-PR lane's reader of the words file is unchanged" || bad "RT2 words: $(cat "$T/rt/words")"

# ============================================================================
echo "RP1: replay of 2026-10-19 22:30Z-23:30Z (40 hub ticks)"
reset
# Two Fly runs end done with deferred=rebase,rereview and named PRs; live
# rows between them. Every 6th tick is a cron full tick, the rest backstop
# keyed ticks.
for i in $(seq 1 40); do
  if [ "$i" -le 1 ]; then row 100 done "$DONE2" 0
  elif [ "$i" -le 19 ]; then
    if [ "$(cnt "$T/enqueues.txt")" -ge 1 ]; then row 101 claimed; fi
  elif [ "$i" -le 20 ]; then row 101 done "$P0 deferred=rebase,rereview fence=5 deferred_prs=2:rebase/21,rereview/22" 0
  else
    if [ "$(cnt "$T/enqueues.txt")" -ge 2 ]; then row 102 claimed; fi
  fi
  if [ $((i % 6)) = 0 ]; then tick; else tick keyed; fi
done
FULLS=$(cnt "$T/fulls.txt"); FULLS=$((FULLS + $(grep -c 'only_pr= ' "$T/runs.txt" 2>/dev/null || true)))
KEYED=$(grep -c 'only_pr=example-org' "$T/runs.txt" 2>/dev/null || true)
ENQ=$(cnt "$T/enqueues.txt")
[ "$FULLS" = 0 ] && [ "${KEYED:-0}" -le 2 ] && [ $((FULLS + KEYED)) -le 2 ] && [ "$ENQ" = 2 ] \
  && ok "RP1 full hub ticks 0, keyed take-backs $KEYED, hub ticks $((FULLS + KEYED)) <= 2, enqueues 2" \
  || bad "RP1 full=$FULLS keyed=$KEYED enqueues=$ENQ runs: $(cat "$T/runs.txt" 2>/dev/null)"
[ "$(grep -c 'still runs' "$T/gate.log")" = 0 ] && ok "RP1 no 'a hub tick of mk still runs' line" || bad "RP1 still-runs lines: $(grep -c 'still runs' "$T/gate.log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

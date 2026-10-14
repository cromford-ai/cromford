#!/bin/bash
# tests/switch-convert-scripts-a.bh-2409-test.sh — six script kill switches
# read through lane_switch (BH-2427, slice a of BH-2409): plan-overlap-off,
# planned-files-cheap-off, postmerge-qa-disabled, pr-owner-sweep-off,
# pr-url-reconcile-off and remediation-disabled.
#
# Each REAL script runs from a scratch bin/ (tests/lib/switch-fixture.sh)
# against a stub settings worker, and each one is observed by a side effect
# it only has when it runs PAST its switch line:
#   base  no row, no file                       -> the script runs past
#   (a)   row switch.<name>=1, no file          -> honoured (stops)
#   (b)   row switch.<name>=0 + flags/<name>    -> NOT honoured, and
#         logs/lane-gate.log says `flags/<name> ignored`
#   (c)   no row + flags/<name>                 -> honoured (the file decides)
#   G1    catalog/switches.d/<name>.json: name, box_scoped boolean, readers exist
#   GREP  no bare `[ -e|-f …flags/<name>` read left in the six scripts
# Run from anywhere: tests/switch-convert-scripts-a.bh-2409-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NAMES="plan-overlap-off planned-files-cheap-off postmerge-qa-disabled pr-owner-sweep-off pr-url-reconcile-off remediation-disabled"
SCRIPTS="bin/plan-overlap.sh bin/planned-files-cheap.sh bin/postmerge-qa.sh bin/pr-owner-sweep.sh bin/pr-url-reconcile.sh bin/remediate-agent.sh"

# G1 — the registry.
for n in $NAMES; do
  f="$DIR/catalog/switches.d/$n.json"
  if ! jq -e --arg n "$n" '.name==$n and (.box_scoped|type=="boolean") and (.readers|type=="array" and length>0) and (.what|type=="string" and length>0)' "$f" >/dev/null 2>&1; then
    bad "G1 catalog/switches.d/$n.json missing or not the pilot's shape"; continue
  fi
  ok
  while IFS= read -r r; do
    [ -f "$DIR/$r" ] && ok || bad "G1 $n reader $r does not exist"
  done < <(jq -r '.readers[]' "$f")
done

# GREP — no bare read of the six names left in the six scripts.
for s in $SCRIPTS; do
  hit=$(grep -nE '\[ -[ef] [^]]*flags/(plan-overlap-off|planned-files-cheap-off|postmerge-qa-disabled|pr-owner-sweep-off|pr-url-reconcile-off|remediation-disabled)' "$DIR/$s")
  [ -z "$hit" ] && ok || bad "GREP bare switch read left in $s: $hit"
done

# The scratch harness: the real scripts, and a stub for each first call past a
# switch. An empty env/ dir keeps harness_env_dir off the box's own env files.
swf_setup "$T/h" || { echo "switch-fixture setup failed"; exit 1; }
# Each script with every bin/lib file it sources (BH-4552); swf_setup's own
# lane-gate.sh, lane-switch.sh and stub jobs-client.sh are kept (no-clobber).
for s in $SCRIPTS; do scratch_install_closure "$s" "$SWF_ROOT" >/dev/null || exit 1; done
mkdir -p "$SWF_ROOT/env" "$SWF_ROOT/plans" "$SWF_ROOT/builds" "$T/fakebin" "$T/build"
printf '#!/bin/bash\ntouch "$HARNESS/.swf/pf-called"\n' > "$SWF_ROOT/bin/planned-files.sh"
printf '#!/bin/bash\ntouch "$HARNESS/.swf/fc-called"\nexit 1\n' > "$SWF_ROOT/bin/fleet-conf.sh"
printf '#!/bin/bash\ntouch "$HARNESS/.swf/gh-called"\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$SWF_ROOT/bin/planned-files.sh" "$SWF_ROOT/bin/fleet-conf.sh" "$T/fakebin/gh"
printf '# plan\n\nFILES: 1\n' > "$T/build/plan.md"
OUT=""; RC=0

# run <script> [args] — the real script from the scratch bin/, bounded, with
# every env knob that could turn it off by another route unset.
run() {
  local s="$1"; shift
  OUT=$(env -u OVERLAP_SCHED -u PLANNED_FILES_CHEAP -u POSTMERGE_QA_DISABLED \
            -u PR_OWNER_SWEEP -u PR_URL_RECONCILE -u LANE_GATE_DISABLE \
            PATH="$T/fakebin:$PATH" timeout 60 "$SWF_ROOT/bin/$s" "$@" 2>/dev/null)
  RC=$?
}
fresh() {
  rm -f "$SWF_ROOT"/flags/* "$SWF_ROOT"/.swf/*-called "$SWF_ROOT"/logs/* "$SWF_ROOT"/locks/*
  rm -f "$T/build/planned-files.txt"
  : > "$CALLS"
}
ignored() { grep -q "flags/$1 ignored" "$SWF_ROOT/logs/lane-gate.log" 2>/dev/null; }

# Per switch: go_<n> runs the script, past_<n> is rc 0 when it ran past the switch.
# S1 plan-overlap.sh — side effect: the stub bin/planned-files.sh is called
# (there is no planned-files.txt), which leaves .swf/pf-called.
go_plan_overlap_off()  { run plan-overlap.sh proj "$T/build/plan.md"; }
past_plan_overlap_off() { [ -e "$SWF_ROOT/.swf/pf-called" ]; }
# S2 planned-files-cheap.sh — side effect: logs/preplan.log gets
# `handed-in body is unreadable` for PLANNED_FILES_BODY_FILE=/nonexistent.
go_planned_files_cheap_off()  { PLANNED_FILES_BODY_FILE=/nonexistent run planned-files-cheap.sh proj BH-1; }
past_planned_files_cheap_off() { grep -q 'handed-in body is unreadable' "$SWF_ROOT/logs/preplan.log" 2>/dev/null; }
# S3 postmerge-qa.sh — side effect: the stub bin/fleet-conf.sh is called,
# which leaves .swf/fc-called. Honoured, the log says `kill switch on`.
go_postmerge_qa_disabled()  { run postmerge-qa.sh proj; }
past_postmerge_qa_disabled() { [ -e "$SWF_ROOT/.swf/fc-called" ]; }
# S4 pr-owner-sweep.sh — side effect: its dedupe lock file
# locks/pr-owner-sweep.lock (the fake gh on PATH fails every call).
go_pr_owner_sweep_off()  { run pr-owner-sweep.sh; }
past_pr_owner_sweep_off() { [ -e "$SWF_ROOT/locks/pr-owner-sweep.lock" ]; }
# S5 pr-url-reconcile.sh — side effect: `exec 9>` creates locks/pr-url-reconcile.lock.
go_pr_url_reconcile_off()  { run pr-url-reconcile.sh; }
past_pr_url_reconcile_off() { [ -e "$SWF_ROOT/locks/pr-url-reconcile.lock" ]; }
# S6 remediate-agent.sh — no flags/remediation-agent-enabled, so past the switch
# it stops on `tier-2 remediator is not enabled`; honoured it prints the kill line.
go_remediation_disabled()  { run remediate-agent.sh some-akey; }
past_remediation_disabled() { [ "$RC" = 1 ] && grep -q 'tier-2 remediator is not enabled' <<<"$OUT"; }

for n in $NAMES; do
  fn=${n//-/_}
  # base — no row, no file: the script runs past its switch.
  fresh; swf_rows; "go_$fn"
  "past_$fn" && ok || bad "$n base: no row and no file, but the script never ran past its switch (rc=$RC)"
  # (a) — the fleet row alone turns it off.
  fresh; swf_rows "switch.$n=1"; "go_$fn"
  "past_$fn" && bad "$n (a): row switch.$n=1 not honoured (rc=$RC)" || ok
  # (b) — a 0 row beats a stale file, and says so.
  fresh; swf_rows "switch.$n=0"; swf_flag "$n"; "go_$fn"
  "past_$fn" && ok || bad "$n (b): row switch.$n=0 lost to flags/$n (rc=$RC)"
  ignored "$n" && ok || bad "$n (b): logs/lane-gate.log has no 'flags/$n ignored' line"
  # (c) — no row: the file decides, as before.
  fresh; swf_rows; swf_flag "$n"; "go_$fn"
  "past_$fn" && bad "$n (c): no row + flags/$n not honoured (rc=$RC)" || ok
done

# The honoured actions, byte for byte.
fresh; swf_rows switch.postmerge-qa-disabled=1; go_postmerge_qa_disabled
grep -q 'kill switch on — nothing driven' "$SWF_ROOT/logs/postmerge-qa.log" 2>/dev/null && ok \
  || bad "S3 (a): postmerge-qa.log has no 'kill switch on — nothing driven'"
for rows in switch.remediation-disabled=1 ""; do
  fresh; swf_rows $rows; [ -z "$rows" ] && swf_flag remediation-disabled; go_remediation_disabled
  if [ "$RC" = 1 ] && [ "$OUT" = "remediation kill switch is set" ]; then ok
  else bad "S6 (${rows:-c}): expected rc 1 and 'remediation kill switch is set', got rc=$RC '$OUT'"; fi
done
for s in plan-overlap-off pr-owner-sweep-off pr-url-reconcile-off planned-files-cheap-off; do
  fresh; swf_rows "switch.$s=1"; "go_${s//-/_}"
  [ "$RC" = 0 ] && ok || bad "$s (a): honoured switch exits $RC, expected 0"
done

echo "switch-convert-scripts-a.bh-2409: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

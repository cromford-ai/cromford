#!/bin/bash
# tests/harness-ctl-project-hold.bh-1464-test.sh — `harness-ctl.sh off|on <hub
# lane> --project <p> "<reason>"` (BH-1464, the CLI slice of BH-1419).
#
# WHY. BH-1463 landed the reader: `lane_project_held <id> <project>` answers
# from the `lane-off-<id>-<project>` row, and five hub lanes declare
# `per_project_hold`. Nothing could WRITE that row — `harness-ctl.sh` refuses a
# project on a hub lane, by design (BH-1165: `off merge-conductor project-3
# "spend"` read the project as the first word of the reason and stopped the
# conductor FLEET-WIDE while printing a line an operator reads as "I stopped
# project-3"). So the hold existed and no operator could set one.
#
# The project therefore arrives as a FLAG, before the reason, which is
# unambiguous at any spacing. What is proved here:
#   1. off <hold lane> --project <p> "<reason>" writes lane-off-<id>-<p>: the
#      FILE and the pause_flags row, through the REAL flag_set (file first);
#   2. on <hold lane> --project <p> "<reason>" clears ONLY that row — the
#      lane-wide switch and all-off still hold, and the line says so;
#   3. every lane the registry marks per_project_hold takes the flag, and the
#      set is read from the registry, never hardcoded here alone;
#   4. a hub lane WITHOUT the field refuses --project, naming the lanes that do
#      take it — writing flags/lane-off-alert-triage-project-3 would be a file
#      nothing ever reads and a stop that stops nothing;
#   5. the BH-1165 POSITIONAL refusal is untouched, and a project-scoped lane's
#      positional form still works;
#   6. an illegal project name dies before any write;
#   7. --help prints both new forms, on a box with no jobs-client to source;
#   8. the row-write failure path: the file is written, the row is not, the
#      command exits non-zero and NEVER prints a success line.
# Run from anywhere: tests/harness-ctl-project-hold.bh-1464-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED and not committed.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/jobs" "$T/h/catalog" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/empty"
cp "$DIR/bin/harness-ctl.sh" "$T/h/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/lib/jobs/flags.sh" "$T/h/bin/lib/jobs/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
printf 'project-2\nproject-3\n' > "$T/h/fleet.conf"

# THE REAL flag_set RUNS. Only the transport is stubbed: _jobs_req records every
# call and can be told to refuse the PUT. So "the file is written before the row"
# and "the row carries this body" are observed on the production code path
# (bin/lib/jobs/flags.sh), not on a recorder that reimplements it.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
JOBS_BOX=testbox
JOBS_HARNESS="${HARNESS:-/root/harness}"
_jobs_req() {
  echo "req $1 $2 ${3:-}" >> "$OPS"
  if [ "$1" = PUT ] && [ "${REFUSE_PUT:-0}" = 1 ]; then return 1; fi
  printf '{"flag":{"updated_at":"2026-09-22T18:00:00Z","reason":"r"}}'
}
setting_set() { echo "setting_set $1 $2" >> "$OPS"; }
# shellcheck disable=SC1091
. "$JOBS_HARNESS/bin/lib/jobs/flags.sh"
SH

# Every run records stdout and stderr SEPARATELY: section 8 is about a success
# line that must not print while the error does.
ctl() {
  env HARNESS="$T/h" OPS="$T/ops" REFUSE_PUT="${REFUSE_PUT:-0}" \
    bash "$T/h/bin/harness-ctl.sh" "$@" >"$T/out" 2>"$T/err"
}
reset() { : > "$T/ops"; : > "$T/out"; : > "$T/err"; rm -f "$T/h/flags"/* 2>/dev/null; }
puts()      { grep -c '^req PUT /api/flags ' "$T/ops"; }
put_body()  { sed -n 's|^req PUT /api/flags ||p' "$T/ops" | head -1; }
no_put()    { ! grep -q '^req PUT /api/flags ' "$T/ops"; }
flags_now() { ls -1 "$T/h/flags" 2>/dev/null | sort | tr '\n' ' '; }

# 1 — off on a per_project_hold hub lane writes the per-project switch
reset; ctl off blocked-resolver --project projb "drain"; RC=$?
[ "$RC" -eq 0 ] || bad "1a off --project was refused on a per_project_hold lane: rc=$RC $(cat "$T/err")"
[ -f "$T/h/flags/lane-off-blocked-resolver-projb" ] && ok \
  || bad "1b the flag FILE was not written: $(flags_now)"
[ "$(puts)" = 1 ] && ok || bad "1c expected exactly one PUT /api/flags, got: $(cat "$T/ops")"
printf '%s' "$(put_body)" | jq -e '
  .name=="lane-off-blocked-resolver-projb" and .active==1 and .reason=="drain"' >/dev/null 2>&1 \
  && ok || bad "1d the row body is wrong: $(put_body)"
case "$(cat "$T/out")" in
  "OFF blocked-resolver/projb (flags/lane-off-blocked-resolver-projb) — drain"*) ok ;;
  *) bad "1e the operator line does not name the project and the switch: $(cat "$T/out")" ;;
esac

# 2 — on clears ONLY that row. The lane-wide switch and the fleet stop still hold.
reset
touch "$T/h/flags/lane-off-blocked-resolver" "$T/h/flags/all-off" \
      "$T/h/flags/lane-off-blocked-resolver-projb"
ctl on blocked-resolver --project projb "done"; RC=$?
[ "$RC" -eq 0 ] || bad "2a on --project was refused: rc=$RC $(cat "$T/err")"
[ ! -e "$T/h/flags/lane-off-blocked-resolver-projb" ] && ok \
  || bad "2b on did not clear the per-project file"
[ -f "$T/h/flags/lane-off-blocked-resolver" ] && [ -f "$T/h/flags/all-off" ] && ok \
  || bad "2c on --project cleared a switch it was not asked about: $(flags_now)"
[ "$(puts)" = 1 ] && printf '%s' "$(put_body)" | jq -e '
  .name=="lane-off-blocked-resolver-projb" and .active==0' >/dev/null 2>&1 \
  && ok || bad "2d the resume row is wrong: $(cat "$T/ops")"
case "$(cat "$T/out")" in
  *"other switches may still hold it"*) ok ;;
  *) bad "2e the resume did not warn that other switches may still hold it: $(cat "$T/out")" ;;
esac

# 3 — every lane the REGISTRY marks per_project_hold takes the flag. The set is
# read from catalog/lanes.json, so a lane that gains the field tomorrow is
# covered here without editing this file.
HOLD_IDS=$(jq -r '.lanes[]|select(.per_project_hold==true)|.id' "$T/h/catalog/lanes.json" | sort | tr '\n' ' ')
# merge-sweep was the fifth until BH-1388 retired its lane; the entry it
# declared the field in is gone. split-watchdog (BH-1793) declares it.
# TEST-CHANGE (BH-6972): component-watch declares it; its project is a
# component, so `off component-watch --project <component>` holds one component.
[ "$HOLD_IDS" = "blocked-resolver component-watch main-red-pr-pair merge-conductor review-autopilot split-watchdog " ] \
  && ok || bad "3a the registry's per_project_hold set changed: '$HOLD_IDS'"
for id in $HOLD_IDS; do
  reset; ctl off "$id" --project projb "x"; RC=$?
  [ "$RC" -eq 0 ] && [ -f "$T/h/flags/lane-off-$id-projb" ] && ok \
    || bad "3b $id declares per_project_hold but --project did not hold it: rc=$RC $(cat "$T/err")"
done

# 4 — a hub lane WITHOUT the field refuses --project, and says which lanes take it
for verb in off on; do
  reset; ctl "$verb" alert-triage --project projb "x"; RC=$?
  [ "$RC" -ne 0 ] && [ -z "$(flags_now)" ] && no_put && ok \
    || bad "4a $verb --project was accepted on a lane with no reader for it: rc=$RC $(flags_now) $(cat "$T/ops")"
  E=$(cat "$T/err")
  case "$E" in
    *alert-triage*blocked-resolver*|*blocked-resolver*alert-triage*) ok ;;
    *) bad "4b the $verb refusal did not name the lane and the ones that do take it: $E" ;;
  esac
  # The LAST id in the printed set, so this still proves the whole list is
  # printed and not just the first. It was merge-sweep until BH-1388 retired
  # that lane and it left the per_project_hold set.
  case "$E" in *review-autopilot*) ok ;; *) bad "4c the $verb refusal did not list the whole set: $E" ;; esac
done

# 5a — the BH-1165 POSITIONAL refusal on a hub lane is untouched
reset; ctl off merge-conductor project-3 "spend"; RC=$?
[ "$RC" -ne 0 ] && [ -z "$(flags_now)" ] && no_put && ok \
  || bad "5a a positional project on a hub lane was accepted: rc=$RC $(flags_now)"
# 5b — a project-scoped lane's positional form still works
reset; ctl off review-prs project-2 "flaky ci"; RC=$?
[ "$RC" -eq 0 ] && [ -f "$T/h/flags/lane-off-review-prs-project-2" ] && ok \
  || bad "5b the project lane's positional form broke: rc=$RC $(cat "$T/err")"

# 5c — one grammar for one switch: on a PROJECT-scoped lane the flag is an alias
# of the positional form and writes the SAME name. Refusing it here would be a
# second rule to remember for a command whose meaning is not in doubt.
reset; ctl off review-prs --project project-2 "flaky ci"; RC=$?
[ "$RC" -eq 0 ] && [ -f "$T/h/flags/lane-off-review-prs-project-2" ] && ok \
  || bad "5c --project on a project-scoped lane did not write the same switch: rc=$RC $(cat "$T/err")"

# 6 — an illegal project name dies BEFORE any write
for p in "a b" "../x" ""; do
  reset; ctl off blocked-resolver --project "$p" "x"; RC=$?
  [ "$RC" -ne 0 ] && [ -z "$(flags_now)" ] && no_put && ok \
    || bad "6 --project '$p' was accepted: rc=$RC $(flags_now) $(cat "$T/ops")"
done

# 7 — --help prints both forms, on a box where jobs-client.sh is not readable
OUT=$(env HARNESS="$T/empty" bash "$T/h/bin/harness-ctl.sh" --help 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "7a --help did not answer without a jobs client: rc=$RC"
N=$(printf '%s\n' "$OUT" | grep -c -- '--project')
[ "$N" = 2 ] && ok || bad "7b --help printed $N of the 2 --project forms: $OUT"

# 8 — the row was refused: the FILE is written, the command fails, and no
# success line is printed. An operator told OFF who walks away while the page
# still says on is the failure this whole tool exists to prevent.
reset; REFUSE_PUT=1 ctl off review-autopilot --project projb "x"; RC=$?
[ "$RC" -ne 0 ] && ok || bad "8a a refused row was reported as a stop: rc=$RC"
grep -q '^OFF ' "$T/out" && bad "8b a success line printed while the row was refused: $(cat "$T/out")" || ok
grep -q 'the box is stopped, the page is not' "$T/err" && ok \
  || bad "8c the refusal did not say the box and the page disagree: $(cat "$T/err")"
[ -f "$T/h/flags/lane-off-review-autopilot-projb" ] && ok \
  || bad "8d the file was not written first — the box is not stopped either: $(flags_now)"

echo "harness-ctl-project-hold: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

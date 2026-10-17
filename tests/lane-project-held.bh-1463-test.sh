#!/bin/bash
# tests/lane-project-held.bh-1463-test.sh — lane_project_held (BH-1463, the
# contract slice of BH-1419).
#
# WHY. A hub-scoped lane can only be stopped FLEET-WIDE today: harness-ctl
# refuses a project argument on one, and the resolver's only switches are
# global. lane_project_held is the per-project HOLD the five hub lanes will ask
# per project, so a fix round can be paused on ONE project while every other
# project keeps running and that project's builds stay on.
#
# It is DARK in this slice — nothing calls it yet — so the only proof available
# is the function's own contract, which is what this file pins:
#   1. the row decides: on -> rc 0 and LANE_HELD_FLAG names the switch; off -> rc 1;
#      and the LANE-WIDE switch is never read here (the lane already exited on it);
#      a hold posts NO liveness row, NO .paused stamp and NO flag sighting;
#   2. absence is never a hold: empty id, empty project, `-`, and a project
#      carrying a character _lg_name refuses all answer RUN, having read nothing;
#   3. LANE_GATE_DISABLE=1 is the escape hatch, before the memo;
#   4. FAIL OPEN: an unreachable worker with nothing cached runs the lane;
#   5. exact filename, never a prefix: lane-off-<id>-project-3 does not hold `project-3`;
#   6. the memo: N asks for one (id, project) cost ONE worker call in a process,
#      because merge-sweep asks per record, hundreds of times a tick;
#   7. lane_paused and lane_gate_or_exit are unchanged — a project row does not
#      stop a lane that passed no project, and all-off still stops everything;
#   8. the registry ratchet: exactly the four surviving hub lanes carry
#      per_project_hold, and no build lane does ("keep project-5 builds on").
#      merge-sweep declared it too until BH-1388 retired that lane; a lane with
#      no registry entry cannot carry the field, so it left this set with it.
# Run from anywhere: tests/lane-project-held.bh-1463-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json is GENERATED and not committed.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date -u +%s)      # ONE clock read, injected as LANE_GATE_NOW everywhere
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# The stub worker, in tests/lane-gate-test.sh's shape. flag_sync DRIVES the file
# from the row and answers rc 0 reconciled / rc 2 no row / rc 1 outage; _jobs_req
# records every POST, so "the hold posted nothing" is a countable fact.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
flag_sync() {
  echo "$1" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  mkdir -p "$HARNESS/flags"
  case " ${PAUSED:-} " in
    *" $1 "*) touch "$HARNESS/flags/$1"; return 0 ;;
  esac
  return 2
}
flag_active() { flag_sync "$1" >/dev/null 2>&1 || true; [ -f "$HARNESS/flags/$1" ]; }
_jobs_req() { echo "$1 ${2:-} ${3:-}" >> "$REQS"; JOBS_HTTP=""
              [ -n "${UNREACHABLE:-}" ] && return 1
              printf '{}'; }
SH

# A caller asking the question, the way a hub lane will: one process, one or
# more asks. REPEAT is what makes the memo observable.
cat > "$T/h/bin/fake-held.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
ask() {
  if lane_project_held "$1" "$2"; then echo "HELD flag=$LANE_HELD_FLAG"
  else echo "RUN flag=$LANE_HELD_FLAG"; fi
}
i=0
while [ "$i" -lt "${REPEAT:-1}" ]; do
  # ${X-default}, not ${X:-default}: a deliberately EMPTY id or project is one
  # of the inputs under test and must reach the function as empty.
  ask "${LANE_ID-merge-conductor}" "${LANE_PROJECT-project-3}"
  [ -n "${LANE_PROJECT2:-}" ] && ask "${LANE_ID-merge-conductor}" "$LANE_PROJECT2"
  i=$((i+1))
done
exit 0
SH
chmod +x "$T/h/bin/fake-held.sh"

# The OTHER two entry points of the same library, with no project argument —
# section 7's subject.
cat > "$T/h/bin/fake-gate.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
if lane_paused merge-conductor; then echo "PAUSED=$LANE_PAUSED_FLAG"; else echo NOTPAUSED; fi
lane_gate_or_exit merge-conductor
echo WORKED
SH
chmod +x "$T/h/bin/fake-gate.sh"

held() { env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" REQS="$T/reqs" JOBS_BOX=box7 "$@" "$T/h/bin/fake-held.sh" 2>/dev/null; }
gate() { env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" REQS="$T/reqs" JOBS_BOX=box7 "$@" "$T/h/bin/fake-gate.sh" 2>/dev/null; }
reset() { rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"; rm -f "$T/h/flags"/*; : > "$T/calls"; : > "$T/reqs"; }
ncalls() { wc -l < "$T/calls" | tr -d ' '; }

# 1 — the row decides, and it is the PROJECT row.
reset
OUT=$(held PAUSED=lane-off-merge-conductor-project-3)
[ "$OUT" = "HELD flag=lane-off-merge-conductor-project-3" ] && ok \
  || bad "1a a project hold row did not hold: '$OUT'"

reset
OUT=$(held)
[ "$OUT" = "RUN flag=" ] && ok \
  || bad "1b no row anywhere did not run with an empty LANE_HELD_FLAG: '$OUT'"

# the LANE-WIDE switch is not this function's question: the lane already exited
# on it at its own lane_gate_or_exit, and reading it here double-counts the
# sighting rail.
reset
OUT=$(held PAUSED=lane-off-merge-conductor)
[ "$OUT" = "RUN flag=" ] && ok \
  || bad "1c the lane-wide switch was read as a project hold: '$OUT'"
{ [ "$(ncalls)" = 1 ] && grep -qx 'lane-off-merge-conductor-project-3' "$T/calls"; } && ok \
  || bad "1d the hold read something other than the project row: '$(tr '\n' ' ' < "$T/calls")'"

# and a hold is SILENT: no liveness row, no .paused stamp, no flag sighting.
reset
held PAUSED=lane-off-merge-conductor-project-3 >/dev/null
[ ! -s "$T/reqs" ] && ok || bad "1e a hold posted to the worker: $(tr '\n' ' ' < "$T/reqs")"
ls "$T/h/state/lane-gate"/*.paused >/dev/null 2>&1 \
  && bad "1f a hold wrote a .paused stamp — the lane RAN this tick" || ok
ls "$T/h/state/lane-gate"/.seen-* >/dev/null 2>&1 \
  && bad "1g a hold posted a flag sighting" || ok

# 2 — absence is never a hold, and an input the name-builder refuses reads
# nothing at all.
for SPEC in 'LANE_PROJECT=' 'LANE_PROJECT=-' 'LANE_PROJECT=../project-3' 'LANE_PROJECT=project-3 os' 'LANE_ID='; do
  reset
  OUT=$(held PAUSED='all-off lane-off-merge-conductor lane-off-merge-conductor-project-3' "$SPEC")
  if [ "$OUT" = "RUN flag=" ] && [ ! -s "$T/calls" ]; then ok
  else bad "2 guard [$SPEC]: out='$OUT' calls='$(tr '\n' ' ' < "$T/calls")'"; fi
done

# 3 — the escape hatch wins, even over a row that is on.
reset
OUT=$(held LANE_GATE_DISABLE=1 PAUSED=lane-off-merge-conductor-project-3)
{ [ "$OUT" = "RUN flag=" ] && [ ! -s "$T/calls" ]; } && ok \
  || bad "3 LANE_GATE_DISABLE=1 did not run the lane: '$OUT'"

# 4 — FAIL OPEN. A control plane that stops lanes when D1 blinks is what
# BH-1132 forbids.
reset
OUT=$(held UNREACHABLE=1)
[ "$OUT" = "RUN flag=" ] && ok \
  || bad "4 an unreachable worker with nothing cached held the project: '$OUT'"

# 5 — exact filename, never a prefix match.
reset; touch "$T/h/flags/lane-off-merge-conductor-project-3"
OUT=$(held LANE_PROJECT=project-3)
[ "$OUT" = "RUN flag=" ] && ok \
  || bad "5a lane-off-merge-conductor-project-3 held the project 'project-3': '$OUT'"

reset; touch "$T/h/flags/lane-off-blocked-resolver-project-5"
OUT=$(held LANE_ID=blocked-resolver LANE_PROJECT=project-5-labs)
[ "$OUT" = "RUN flag=" ] && ok \
  || bad "5b lane-off-blocked-resolver-project-5 held 'project-5-labs': '$OUT'"

reset
touch "$T/h/flags/lane-off-blocked-resolver-project-5" \
      "$T/h/flags/lane-off-blocked-resolver-project-5-labs"
OUT=$(held LANE_ID=blocked-resolver LANE_PROJECT=project-5-labs)
[ "$OUT" = "HELD flag=lane-off-blocked-resolver-project-5-labs" ] && ok \
  || bad "5c the project's OWN row did not hold it: '$OUT'"

# 6 — the memo. LANE_GATE_CACHE_S=0 takes the file cache out of the answer, so
# without a memo five asks are five flag_sync round trips; merge-sweep asks per
# record, hundreds of times a tick.
reset
OUT=$(held REPEAT=5 LANE_GATE_CACHE_S=0 PAUSED=lane-off-merge-conductor-project-3)
N=$(printf '%s\n' "$OUT" | grep -c '^HELD flag=lane-off-merge-conductor-project-3$')
[ "$N" = 5 ] && ok || bad "6a five asks answered HELD $N time(s): '$OUT'"
[ "$(ncalls)" = 1 ] && ok || bad "6b five asks cost $(ncalls) worker call(s) — the memo is not memoising"

reset
held REPEAT=3 LANE_GATE_CACHE_S=0 LANE_PROJECT=project-3 LANE_PROJECT2=project-4 \
     PAUSED=lane-off-merge-conductor-project-3 >/dev/null
[ "$(ncalls)" = 2 ] && ok \
  || bad "6c two projects over three rounds cost $(ncalls) worker call(s) (want 2 — one per project)"
{ grep -qx 'lane-off-merge-conductor-project-3' "$T/calls" \
  && grep -qx 'lane-off-merge-conductor-project-4' "$T/calls"; } && ok \
  || bad "6d the memo answered for a project it never read: '$(tr '\n' ' ' < "$T/calls")'"

# 7 — the two functions either side of it are untouched: a PROJECT row does not
# stop a lane that passed no project, and all-off still stops everything, still
# exiting 0 (cron mails on nonzero).
reset; touch "$T/h/flags/lane-off-merge-conductor-project-3"
OUT=$(gate)
case "$OUT" in
  *NOTPAUSED*WORKED*) ok ;;
  *) bad "7a a per-project row stopped the lane-wide gate: '$OUT'" ;;
esac

reset; touch "$T/h/flags/all-off"
OUT=$(gate); RC=$?
case "$OUT" in
  *WORKED*) bad "7b all-off no longer stops the lane: '$OUT'" ;;
  *) ok ;;
esac
[ "$RC" -eq 0 ] && ok || bad "7c a gated tick exited $RC — a paused lane must not page"
rm -f "$T/h/flags/all-off"

# 8 — the registry ratchet. Which lanes honour the hold is DECLARED, not a
# hardcoded list in any reader, and no build lane declares it.
GOT=$(jq -r 'select(.per_project_hold==true)|.id' "$DIR"/catalog/lanes.d/*.json | sort | tr '\n' ' ')
# TEST-CHANGE (BH-1808): split-watchdog declares per_project_hold. It is a hub
# lane that acts on a project's families (enqueue, close-parent), so a held
# project must stop it; it is not a build lane. Its spec (BH-1793) asks for it.
# TEST-CHANGE (BH-6972): component-watch declares per_project_hold. It is a hub
# lane, and its "project" is a component of catalog/components.tsv, so the
# ticket's flag lane-off-component-watch-<component> holds one component.
WANT="blocked-resolver component-watch main-red-pr-pair merge-conductor review-autopilot split-watchdog "
[ "$GOT" = "$WANT" ] && ok || bad "8a per_project_hold lanes are '$GOT' (want '$WANT')"

for L in run-triage fly-pool fly-pool-tick; do
  V=$(jq -r 'if has("per_project_hold") then (.per_project_hold|tostring) else "absent" end' \
        "$DIR/catalog/lanes.d/$L.json")
  [ "$V" = absent ] && ok \
    || bad "8b $L carries per_project_hold=$V — builds keep running while a project is held"
done

N=0; CARRIED=""
for F in "$DIR"/catalog/lanes.d/*build*.json; do
  [ -f "$F" ] || continue
  N=$((N+1))
  V=$(jq -r 'if has("per_project_hold") then (.per_project_hold|tostring) else "absent" end' "$F")
  [ "$V" = absent ] || CARRIED="$CARRIED $(basename "$F")=$V"
done
if [ "$N" -eq 0 ]; then bad "8c matched no catalog/lanes.d/*build*.json — the assertion is vacuous"
elif [ -n "$CARRIED" ]; then bad "8c a build lane carries per_project_hold:$CARRIED"
else ok; fi

echo "lane-project-held: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

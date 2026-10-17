#!/bin/bash
# tests/mergify-status-check.bh-3348-test.sh — bin/mergify-template.sh's
# status_check= key (BH-3348): Mergify's queue must require the head-bound
# `lead-verdict` commit status, so a hand `@Mergifyio queue` on a head no
# verdict covers never enters it (#3307 landed 4f4b3f914 under no review).
#
#   M1  status_check= lands in the default queue's queue_conditions, after the
#       queue checks
#   M2  ... and in the hotfix queue's
#   M3  ... and in NEITHER merge_conditions (the batch draft never carries it)
#   M4  the repo's own conf requires lead-verdict, --check is green, and the
#       committed .mergify.yml carries it in both queue_conditions only
#   M5  project-5's render does not move; a status_check that is also a
#       check=, one holding a quote, and a duplicate are refused
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
MT="$DIR/bin/mergify-template.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "mergify-status-check: PyYAML missing — skipping on this dev machine"; exit 0
fi
q() { # q <yaml-file> <queue> <key> — that queue's check-success names, one per line
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for r in d.get("queue_rules") or []:
    if r.get("name") == sys.argv[2]:
        for c in r.get(sys.argv[3]) or []:
            c = str(c)
            if c.startswith("check-success"): print(c.split("=", 1)[1].strip().strip('"'))
PY
}

printf 'slug=o/r\ncheck=fast\ncheck=slow\nqueue_check=fast\nstatus_check=lead-verdict\n' > "$T/s.conf"
"$MT" render "$T/s.conf" > "$T/s.yml" 2>"$T/err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "M1: a conf with status_check must render (rc=$RC): $(cat "$T/err")"
[ "$(q "$T/s.yml" default queue_conditions | tr '\n' ' ')" = "fast lead-verdict " ] && ok \
  || bad "M1: default.queue_conditions must be the queue checks then lead-verdict: $(q "$T/s.yml" default queue_conditions | tr '\n' ' ')"
[ "$(q "$T/s.yml" hotfix queue_conditions | tr '\n' ' ')" = "fast lead-verdict " ] && ok \
  || bad "M2: hotfix.queue_conditions must carry lead-verdict too: $(q "$T/s.yml" hotfix queue_conditions | tr '\n' ' ')"
for QN in hotfix default; do
  [ "$(q "$T/s.yml" "$QN" merge_conditions | tr '\n' ' ')" = "fast slow " ] && ok \
    || bad "M3: $QN.merge_conditions must stay every check= and no status: $(q "$T/s.yml" "$QN" merge_conditions | tr '\n' ' ')"
done
# Without queue_check= the status still rides queue_conditions only.
printf 'slug=o/r\ncheck=fast\nstatus_check=lead-verdict\n' > "$T/s2.conf"
"$MT" render "$T/s2.conf" > "$T/s2.yml" 2>"$T/err"
[ "$(q "$T/s2.yml" default queue_conditions | tr '\n' ' ')" = "fast lead-verdict " ] \
  && [ "$(q "$T/s2.yml" default merge_conditions | tr '\n' ' ')" = "fast " ] && ok \
  || bad "M3: with no queue_check the status is in queue_conditions only: $(cat "$T/s2.yml")"

# M4 — the repo itself.
grep -qx 'status_check=lead-verdict' "$DIR/config/mergify/repos/cromford.conf" && ok \
  || bad "M4: config/mergify/repos/cromford.conf must carry status_check=lead-verdict"
OUT=$(HARNESS_TEST_SANDBOX=1 "$MT" --check 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "M4: --check must be green: $OUT"
# BH-5430 added the solo queue (solo_label=); it takes the same queue gate.
QNS="hotfix default"; grep -q '^  - name: solo$' "$DIR/.mergify.yml" && QNS="hotfix solo default"
# BH-7279 added the flake-fix queue (flake_fix_label=); it takes the same gate.
grep -q '^  - name: flake-fix$' "$DIR/.mergify.yml" && QNS="flake-fix $QNS"
for QN in $QNS; do
  q "$DIR/.mergify.yml" "$QN" queue_conditions | grep -x lead-verdict >/dev/null && ok || bad "M4: .mergify.yml $QN.queue_conditions must require lead-verdict"
  grep -qx lead-verdict <<<"$(q "$DIR/.mergify.yml" "$QN" merge_conditions)" && bad "M4: .mergify.yml $QN.merge_conditions must not require lead-verdict" || ok
done
[ "$(grep -c 'check-success = "lead-verdict"' "$DIR/.mergify.yml")" = "$(wc -w <<<"$QNS")" ] && ok || bad "M4: lead-verdict appears exactly once per queue ($QNS) in .mergify.yml"

# M5 — project-5 does not move, and the refusals.
"$MT" render "$DIR/config/mergify/repos/project-5.conf" > "$T/ts.yml" 2>"$T/err"; RC=$?
[ "$RC" -eq 0 ] && ! grep -q lead-verdict "$T/ts.yml" && ok || bad "M5: project-5 renders with no lead-verdict (rc=$RC)"
printf 'slug=o/r\ncheck=fast\ncheck=lead-verdict\nstatus_check=lead-verdict\n' > "$T/b1.conf"
"$MT" render "$T/b1.conf" >/dev/null 2>"$T/err"; RC=$?
[ "$RC" -eq 2 ] && grep -q 'status_check' "$T/err" && ok || bad "M5: a status_check that is also a check= is refused (rc=$RC): $(cat "$T/err")"
printf 'slug=o/r\ncheck=fast\nstatus_check=lead"verdict\n' > "$T/b2.conf"
"$MT" render "$T/b2.conf" >/dev/null 2>"$T/err"; RC=$?
[ "$RC" -eq 2 ] && ok || bad "M5: a status_check holding a quote is refused (rc=$RC)"
printf 'slug=o/r\ncheck=fast\nstatus_check=lead-verdict\nstatus_check=lead-verdict\n' > "$T/b3.conf"
"$MT" render "$T/b3.conf" >/dev/null 2>"$T/err"; RC=$?
[ "$RC" -eq 2 ] && grep -q duplicate "$T/err" && ok || bad "M5: a duplicate status_check is refused (rc=$RC): $(cat "$T/err")"

echo "mergify-status-check: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

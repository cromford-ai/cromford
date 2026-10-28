#!/bin/bash
# tests/pool-tailnet-overload.bh-8281-test.sh — the env-bundle alert fires on
# the 2026-10-24 box-project-6-os-1 case and names load as a cause (BH-8281).
#
# WHY. From 11:20Z to 18:14Z the hub logged `env bundle FAILED … ssh env
# extract from <project-6-os tailnet ip> failed (ssh rc 255)` on every project-6-os pool
# tick. The tailnet was up; the box was at load 92. The alert said only
# "tailnet unreachable … Check tailscaled", which points at the wrong cause.
#
#   O1  3 notes with the ticket's own reason inside the window: exactly 1 line that
#       names the fixture address, "tailnet unreachable", "box overloaded" and "uptime"
#   O2  a 4th note: still 1 line
#   O3  `local env extract failed (rc 1)` x3: 0 lines
#   O4  3 notes at ages 2000, 1000, 0 s (wider than the 1800 s default window): 0 lines
#   O5  3 notes at ages 1200, 600, 0 s (3 pool ticks in a row, the tick is every
#       10 min, cron/lanes/240-fly-pool-tick.cron): exactly 1 line
#   O6  the registry default of POOL_TAILNET_WINDOW_S covers 3 ticks (>= 1800 s)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-tailnet-overload.bh-8281-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/pool-tailnet.sh"
H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/logs"
cat > "$H/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/alert-line.sh"
NOW=$(date +%s)
BOX=192.0.2.81  # RFC 5737 fixture address for the project-6-os box
WHY="ssh env extract from $BOX failed (ssh rc 255)"
note() { ( unset POOL_TAILNET_WINDOW_S POOL_TAILNET_FAILS; HARNESS="$H"; . "$LIB" || exit 9; ptn_note project-6-os "$1" ); }
alerts() { local n; n=$(grep -c . "$T/alerts" 2>/dev/null) || n=0; printf '%s' "$n"; }
fresh() { scratch_rm "$H/state/pool-tailnet"; rm -f "$T/alerts"; }
[ -r "$LIB" ] || bad "fixture: no $LIB"

# O1 — the ticket's line, three ticks.
fresh
note "$WHY"; note "$WHY"; note "$WHY"
if [ "$(alerts)" = 1 ] && grep -qF "$BOX" "$T/alerts" && grep -qF 'tailnet unreachable' "$T/alerts" \
   && grep -qF 'box overloaded' "$T/alerts" && grep -qF 'uptime' "$T/alerts"; then ok
else bad "O1 one line naming $BOX, both causes and uptime: $(cat "$T/alerts" 2>/dev/null)"; fi

# O2 — a fourth in the same episode.
note "$WHY"
[ "$(alerts)" = 1 ] && ok || bad "O2 a 4th failure writes no second line: $(cat "$T/alerts" 2>/dev/null)"

# O3 — a local extract failure is not a box failure.
fresh
for _ in 1 2 3; do note "local env extract failed (rc 1)"; done
[ "$(alerts)" = 0 ] && ok || bad "O3 local extract failures alert nothing: $(cat "$T/alerts" 2>/dev/null)"

# O4 — spread wider than the window.
fresh; mkdir -p "$H/state/pool-tailnet"
printf '%s\n%s\n' $((NOW - 2000)) $((NOW - 1000)) > "$H/state/pool-tailnet/$BOX.fails"
note "$WHY"
[ "$(alerts)" = 0 ] && ok || bad "O4 3 failures over 2000 s alert nothing: $(cat "$T/alerts" 2>/dev/null)"

# O5 — the ticket's acceptance 3: one queued row, 3 failed ticks 10 min apart.
fresh; mkdir -p "$H/state/pool-tailnet"
printf '%s\n%s\n' $((NOW - 1200)) $((NOW - 600)) > "$H/state/pool-tailnet/$BOX.fails"
note "$WHY"
[ "$(alerts)" = 1 ] && grep -qF "$BOX" "$T/alerts" && ok || bad "O5 3 failed ticks 600 s apart write 1 line: $(cat "$T/alerts" 2>/dev/null)"

# O6 — the shipped default is the one O5 relies on, and the cron is every 10 min.
KNOB="$DIR/catalog/lanes.d/fly-pool.knobs.d/POOL_TAILNET_WINDOW_S.json"
D=$(jq -r '.default' "$KNOB" 2>/dev/null)
case "$D" in ''|*[!0-9]*) bad "O6 no integer default in $KNOB: '$D'" ;;
  *) [ "$D" -ge 1800 ] && ok || bad "O6 POOL_TAILNET_WINDOW_S default $D does not cover 3 ticks of 600 s" ;; esac
grep -q '^\*/10 ' "$DIR/cron/lanes/240-fly-pool-tick.cron" 2>/dev/null && ok \
  || bad "O6 the fly-pool tick is no longer */10; re-check the window default: $(grep -v '^#' "$DIR/cron/lanes/240-fly-pool-tick.cron" 2>/dev/null | head -2)"

echo "pool-tailnet-overload: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

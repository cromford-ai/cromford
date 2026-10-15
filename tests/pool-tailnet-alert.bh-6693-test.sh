#!/bin/bash
# tests/pool-tailnet-alert.bh-6693-test.sh — the pool names a box that is off
# the tailnet, not only the ticket whose env bundle failed (BH-6693).
#
# WHY. On 2026-10-14 tailscaled died on box-small and the pool logged
# `env bundle FAILED for BH-6557: ssh env extract from 192.0.2.18 failed`
# 11 times in ~2 h. Each line named a ticket; no line named the box or the
# cause, and no alert fired.
#
#   P1  3 env-extract failures for one box inside the window: one ALERTS line
#       that names the box and says "tailnet unreachable"
#   P2  a 4th failure in the same episode: no second line
#   P3  2 failures, or 3 spread over more than the window: no line
#   P4  failures for two boxes are counted per box
#   P5  after a quiet window (no failure for longer than it), a new streak of
#       3 alerts again
#   P6  a bundle failure that is not an ssh env extract counts nothing
#   P7  bin/fly-pool.sh calls the lib at its env-bundle failure line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-tailnet-alert.bh-6693-test.sh
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
WHY() { printf 'ssh env extract from %s failed (ssh rc 255)' "$1"; }
note() { ( HARNESS="$H"; . "$LIB" || exit 9; ptn_note cromford "$1" ); }
alerts() { local n; n=$(grep -c . "$T/alerts" 2>/dev/null) || n=0; printf '%s' "$n"; }
fresh() { scratch_rm "$H/state/pool-tailnet"; rm -f "$T/alerts"; }
seed() { # seed <box> <age-s>... — failures already on record, that old
  local b="$1" a; shift; mkdir -p "$H/state/pool-tailnet"
  for a in "$@"; do echo $((NOW - a)) >> "$H/state/pool-tailnet/$b.fails"; done
}
[ -r "$LIB" ] || bad "fixture: no $LIB"

# P1 — three in the window.
fresh
note "$(WHY 192.0.2.18)"; note "$(WHY 192.0.2.18)"
[ "$(alerts)" = 0 ] && ok || bad "P1 two failures alert nothing: $(cat "$T/alerts" 2>/dev/null)"
note "$(WHY 192.0.2.18)"
[ "$(alerts)" = 1 ] && grep -q '192.0.2.18' "$T/alerts" && grep -q 'tailnet unreachable' "$T/alerts" && ok \
  || bad "P1 the third failure writes one line naming the box and the cause: $(cat "$T/alerts" 2>/dev/null)"
# P2 — a fourth in the same episode.
note "$(WHY 192.0.2.18)"
[ "$(alerts)" = 1 ] && ok || bad "P2 no second line in one episode: $(cat "$T/alerts" 2>/dev/null)"

# P3 — spread over more than the window.
fresh; seed 192.0.2.9 2000 1500
note "$(WHY 192.0.2.9)"
[ "$(alerts)" = 0 ] && ok || bad "P3 3 failures over more than 15 min alert nothing: $(cat "$T/alerts" 2>/dev/null)"

# P4 — per box.
fresh
note "$(WHY 192.0.2.1)"; note "$(WHY 192.0.2.2)"; note "$(WHY 192.0.2.1)"; note "$(WHY 192.0.2.2)"
[ "$(alerts)" = 0 ] && ok || bad "P4 2 + 2 failures on two boxes alert nothing: $(cat "$T/alerts" 2>/dev/null)"
note "$(WHY 192.0.2.2)"
[ "$(alerts)" = 1 ] && grep -q '192.0.2.2' "$T/alerts" && ok || bad "P4 the box with 3 alerts: $(cat "$T/alerts" 2>/dev/null)"

# P5 — a new episode after a quiet window.
fresh; seed 192.0.2.5 3000 2900 2800
mkdir -p "$H/state/pool-tailnet"; : > "$H/state/pool-tailnet/192.0.2.5.alerted"
note "$(WHY 192.0.2.5)"; note "$(WHY 192.0.2.5)"; note "$(WHY 192.0.2.5)"
[ "$(alerts)" = 1 ] && ok || bad "P5 a new streak after a quiet window alerts again: $(cat "$T/alerts" 2>/dev/null)"

# P6 — another bundle failure.
fresh
for _ in 1 2 3; do note "no owning box mapping for cromford"; done
[ "$(alerts)" = 0 ] && [ ! -d "$H/state/pool-tailnet" ] && ok || bad "P6 a non-ssh failure counts nothing: $(cat "$T/alerts" 2>/dev/null)"

# P7 — the wiring.
grep -q 'ptn_note "\$P" "\$EB_WHY"' "$DIR/bin/fly-pool.sh" && ok || bad "P7 bin/fly-pool.sh calls ptn_note at the env-bundle failure"
grep -q 'lib/pool-tailnet.sh' "$DIR/bin/fly-pool.sh" && ok || bad "P7 bin/fly-pool.sh sources bin/lib/pool-tailnet.sh"

echo "pool-tailnet-alert.bh-6693: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

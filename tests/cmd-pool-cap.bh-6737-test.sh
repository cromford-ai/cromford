#!/bin/bash
# tests/cmd-pool-cap.bh-6737-test.sh — BH-6737: the console's pool_cap command.
#
# bin/cmd-pool-cap.sh <project> <payload-json> <command_id> sets the Fly pool
# cap as ONE settings row, lane.fly-pool.<project>.pool_cap, through
# bin/jobs-client.sh setting-set (here a stub over a file store). It writes NO
# flags/ file (PR #7045, the operator 2026-10-16); flags/fly-pool-<p> is only read, as
# the pool's enable switch. The ack reports what bin/pool-cap.sh prints AFTER
# the write, never the requested number. A pool that is not enabled is refused
# and nothing is written.
#
# P1 cap 3, P2 cap 0, P2b cap 0 under a conf line / POOL_CAP_MAX, P2c a flag
# number wins, P3 no flag file, P4 bad caps (refused, never clamped), P5 bad
# project / payload, P6 a failed settings write; no flags/ change on any case.
# Run from anywhere: tests/cmd-pool-cap.bh-6737-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; S="$T/store"
mkdir -p "$H/flags" "$H/env" "$H/logs" "$H/state" "$S/kv"
for s in bin/cmd-pool-cap.sh bin/pool-cap.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
cat > "$H/fleet.conf" <<'FC'
# fixture
pa example-org/fixture-pa - - 1 hub
pb example-org/fixture-pb - - 2 hub
FC
# The stub replaces the real client the closure copied. $S/set_rc makes
# setting-set fail; $S/calls logs every call.
cat > "$H/bin/jobs-client.sh" <<STUB
#!/bin/bash
S="$S"
echo "\$*" >> "\$S/calls"
case "\${1:-}" in
  setting-get) [ -f "\$S/kv/\$2" ] || { echo; exit 2; }
               cat "\$S/kv/\$2"; echo; exit 0 ;;
  setting-set) rc=\$(cat "\$S/set_rc" 2>/dev/null || echo 0)
               [ "\$rc" = 0 ] || exit "\$rc"
               printf '%s' "\$3" > "\$S/kv/\$2"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/jobs-client.sh"
K=lane.fly-pool.pa.pool_cap

# pc <project> <payload> [VAR=value ...] -> OUT (the one result line), RC
pc() {
  local p="$1" pl="$2"; shift 2
  OUT=$(env -u POOL_CAP_MAX -u POOL_AUTOSCALE HARNESS="$H" FLEET_CONF="$H/fleet.conf" "$@" \
    bash "$H/bin/cmd-pool-cap.sh" "$p" "$pl" 31 2>"$T/err"); RC=$?
}
capnow() { env -u POOL_CAP_MAX -u POOL_AUTOSCALE HARNESS="$H" bash "$H/bin/pool-cap.sh" "$1" 2>/dev/null; }
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
row() { cat "$S/kv/$K" 2>/dev/null; }
sets() { cat "$S/calls" 2>/dev/null | grep -c '^setting-set'; }
# P6 half: no file under flags/ changes on any case. The marker is older than
# every case; each fixture write below goes in BEFORE a fresh marker.
mark() { sleep 1; touch "$T/marker"; sleep 1; }
flags_unchanged() { [ -z "$(find "$H/flags" -newer "$T/marker" 2>/dev/null)" ]; }

echo "--- P1: cap 3 on an enabled pool"
: > "$H/flags/fly-pool-pa"; mark
pc pa '{"cap":3}'
[ "$RC" = 0 ] && ok || bad "P1 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(row)" = 3 ] && ok || bad "P1 row $K holds '$(row)'"
grep -q "^setting-set $K 3 console pool_cap command 31" "$S/calls" && ok || bad "P1 setting-set call: $(cat "$S/calls")"
{ [ -f "$H/flags/fly-pool-pa" ] && [ ! -s "$H/flags/fly-pool-pa" ]; } && ok || bad "P1 flag file changed"
[ "$(jf .result)" = ok ] && ok || bad "P1 .result (out=$OUT)"
[ "$(jf .pool_cap)" = 3 ] && ok || bad "P1 .pool_cap (out=$OUT)"
[ "$(jf .cap_set)" = 3 ] && ok || bad "P1 .cap_set (out=$OUT)"
[ "$(jf .project)" = pa ] && ok || bad "P1 .project (out=$OUT)"
jf .reason | grep -qF "settings row $K = 3" && ok || bad "P1 reason names the row (out=$OUT)"
[ "$(capnow pa)" = 3 ] && ok || bad "P1 pool-cap.sh pa prints '$(capnow pa)'"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "P1 more than one stdout line"
flags_unchanged && ok || bad "P1 flags/ changed"

echo "--- P2: cap 0 is row 0; the flag file stays as it was"
pc pa '{"cap":0}'
[ "$RC" = 0 ] && ok || bad "P2 rc $RC (out=$OUT)"
[ "$(row)" = 0 ] && ok || bad "P2 row holds '$(row)'"
{ [ -f "$H/flags/fly-pool-pa" ] && [ ! -s "$H/flags/fly-pool-pa" ]; } && ok || bad "P2 flag file missing or changed"
[ "$(jf .result)" = ok ] && ok || bad "P2 .result (out=$OUT)"
[ "$(jf .pool_cap)" = 0 ] && ok || bad "P2 .pool_cap (out=$OUT)"
[ "$(jf .cap_set)" = 0 ] && ok || bad "P2 .cap_set (out=$OUT)"
[ "$(capnow pa)" = 0 ] && ok || bad "P2 pool-cap.sh pa prints '$(capnow pa)'"
flags_unchanged && ok || bad "P2 flags/ changed"

echo "--- P2b: cap 0 beats a fly/pool-caps.conf line; POOL_CAP_MAX trims it"
mkdir -p "$H/fly"; printf 'pa 5\n' > "$H/fly/pool-caps.conf"
pc pa '{"cap":0}'
[ "$RC" = 0 ] && ok || bad "P2b rc $RC (out=$OUT)"
[ "$(jf .pool_cap)" = 0 ] && ok || bad "P2b .pool_cap: the row wins over the conf (out=$OUT)"
pc pa '{"cap":0}' POOL_CAP_MAX=2
[ "$RC" = 0 ] && ok || bad "P2b MAX rc $RC (out=$OUT)"
[ "$(jf .pool_cap)" = 2 ] && ok || bad "P2b MAX .pool_cap is the read-back 2 (out=$OUT)"
jf .reason | grep -q 'POOL_CAP_MAX' && ok || bad "P2b reason names POOL_CAP_MAX (out=$OUT)"
grep -qi 'unlimited' <<<"$(jf .reason)" && bad "P2b reason claims unlimited (out=$OUT)" || ok
rm -f "$H/fly/pool-caps.conf"
flags_unchanged && ok || bad "P2b flags/ changed"

echo "--- P2c: a number inside the flag file wins over the row"
printf '4\n' > "$H/flags/fly-pool-pa"; mark
pc pa '{"cap":3}'
[ "$RC" = 0 ] && ok || bad "P2c rc $RC (out=$OUT)"
[ "$(jf .result)" = ok ] && ok || bad "P2c .result (out=$OUT)"
[ "$(jf .pool_cap)" = 4 ] && ok || bad "P2c .pool_cap is the read-back 4 (out=$OUT)"
[ "$(row)" = 3 ] && ok || bad "P2c row holds '$(row)'"
{ jf .reason | grep -q 'flags/fly-pool-pa' && jf .reason | grep -q 'wins'; } && ok || bad "P2c reason names the flag file (out=$OUT)"
[ "$(cat "$H/flags/fly-pool-pa")" = 4 ] && ok || bad "P2c flag file changed"
flags_unchanged && ok || bad "P2c flags/ changed"

echo "--- P3: no flag file -> refused, nothing written"
rm -f "$S/calls"
pc pb '{"cap":2}'
[ "$RC" = 3 ] && ok || bad "P3 rc $RC (out=$OUT)"
[ "$(jf .result)" = refused ] && ok || bad "P3 .result (out=$OUT)"
[ ! -e "$H/flags/fly-pool-pb" ] && ok || bad "P3 created flags/fly-pool-pb"
pc pb '{"cap":0}'
{ [ "$RC" = 3 ] && [ ! -e "$H/flags/fly-pool-pb" ]; } && ok || bad "P3 cap 0 with no flag rc $RC"
[ "$(sets)" = 0 ] && ok || bad "P3 setting-set was called: $(cat "$S/calls")"
[ ! -e "$S/kv/lane.fly-pool.pb.pool_cap" ] && ok || bad "P3 wrote a row for pb"
[ "$(find "$H/flags" -type f | wc -l)" = 1 ] && ok || bad "P3 stray files under flags/: $(ls -A "$H/flags")"
flags_unchanged && ok || bad "P3 flags/ changed"

echo "--- P4: bad caps are refused, never clamped"
: > "$H/flags/fly-pool-pa"; printf 3 > "$S/kv/$K"; rm -f "$S/calls"; mark
for c in '-1' '1.5' '"3"' 'null' '1000' 'true'; do
  pc pa "{\"cap\":$c}"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "P4 cap $c rc $RC (out=$OUT)"
  [ "$(row)" = 3 ] && ok || bad "P4 cap $c changed the row"
done
pc pa '{}'
[ "$RC" = 3 ] && ok || bad "P4 missing cap rc $RC"
[ "$(sets)" = 0 ] && ok || bad "P4 setting-set was called: $(cat "$S/calls")"
pc pa '{"cap":999}'
{ [ "$RC" = 0 ] && [ "$(jf .pool_cap)" = 999 ]; } && ok || bad "P4 cap 999 is allowed (rc $RC out=$OUT)"
flags_unchanged && ok || bad "P4 flags/ changed"

echo "--- P5: bad project / payload"
pc zz '{"cap":1}'
{ [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "P5 unknown project rc $RC (out=$OUT)"
pc pa 'not json'
{ [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "P5 bad payload rc $RC (out=$OUT)"
pc pa '[3]'
[ "$RC" = 3 ] && ok || bad "P5 array payload rc $RC"
pc '../pa' '{"cap":1}'
[ "$RC" = 3 ] && ok || bad "P5 path project rc $RC"

echo "--- P6: a failed settings write -> failed (retryable), nothing else changes"
printf 7 > "$S/kv/$K"; printf 1 > "$S/set_rc"
pc pa '{"cap":3}'
[ "$RC" = 1 ] && ok || bad "P6 rc $RC (out=$OUT)"
[ "$(jf .result)" = failed ] && ok || bad "P6 .result (out=$OUT)"
jf .reason | grep -q 'settings write failed' && ok || bad "P6 reason (out=$OUT)"
[ "$(row)" = 7 ] && ok || bad "P6 row changed to '$(row)'"
rm -f "$S/set_rc"
flags_unchanged && ok || bad "P6 flags/ changed"

echo "cmd-pool-cap: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

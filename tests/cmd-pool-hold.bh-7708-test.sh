#!/bin/bash
# tests/cmd-pool-hold.bh-7708-test.sh — BH-7708: the console's pool_hold command.
#
# bin/cmd-pool-hold.sh <project> <payload-json> <command_id> holds or releases
# one project's Fly pool spawns. It reuses the pool's own spawn hold: the file
# state/pool/<p>/_spawn-hold ("<until-epoch> <why>") and the pool_state spawn
# row (bin/lib/pool-state-rows.sh psr_hold_put / psr_hold_clear). The jobs
# client here is a stub that logs every request; no network.
#
# H1 hold:true writes the file and the row; H2 the fly-pool lane's own
# pool_spawn_held reads that file; H3 hold:false removes both; H4 a failed row
# clear is rc 1; H5 a failed row write on hold is rc 0 with row "not written";
# H6 refusals write nothing and send nothing; H7 a bad PAUSE_BOARD_TTL_S falls
# back to 604800; H8 the knob off sends no row.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cmd-pool-hold.bh-7708-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; S="$T/store"
mkdir -p "$H/flags" "$H/env" "$H/logs" "$H/state" "$S"
for s in bin/cmd-pool-hold.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
[ -x "$H/bin/cmd-pool-hold.sh" ] || bad "bin/cmd-pool-hold.sh was not installed"
cat > "$H/fleet.conf" <<'FC'
# fixture
pa example-org/fixture-pa - - 1 hub
pb example-org/fixture-pb - - 2 hub
FC
# The stub replaces the real client the closure copied. It is SOURCED by the
# command: _jobs_req logs "<method> <path> <body>" to $S/reqs and exits with
# the number in $S/req_rc; _flag_on_row reads the knob from $S/knob.
cat > "$H/bin/jobs-client.sh" <<STUB
#!/bin/bash
_jobs_req() { printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$S/reqs"; return "\$(cat "$S/req_rc" 2>/dev/null || echo 0)"; }
_flag_on_row() { [ "\$(cat "$S/knob" 2>/dev/null || echo 1)" = 1 ]; }
STUB
chmod +x "$H/bin/jobs-client.sh"
NOW=1800000000
F="$H/state/pool/pa/_spawn-hold"

# ph <project> <payload> [VAR=value ...] -> OUT (the one result line), RC
ph() {
  local p="$1" pl="$2"; shift 2
  OUT=$(env -u PAUSE_BOARD_TTL_S HARNESS="$H" FLEET_CONF="$H/fleet.conf" CMD_POOL_HOLD_NOW="$NOW" "$@" \
    bash "$H/bin/cmd-pool-hold.sh" "$p" "$pl" 81 2>"$T/err"); RC=$?
}
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
reset() { scratch_rm "$H/state/pool"; : > "$S/reqs"; echo 0 > "$S/req_rc"; echo 1 > "$S/knob"; }
reqs() { grep -c . "$S/reqs" 2>/dev/null; }

echo "--- H1: hold:true writes the file and the row"
reset; : > "$H/flags/fly-pool-pa"
ph pa '{"hold":true,"reason":"r"}'
[ "$RC" = 0 ] && ok || bad "H1 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(cat "$F" 2>/dev/null)" = "$((NOW + 604800)) operator hold (console pool_hold 81): r" ] \
  && ok || bad "H1 file holds '$(cat "$F" 2>/dev/null)'"
[ "$(reqs)" = 1 ] && ok || bad "H1 requests: $(cat "$S/reqs")"
B=$(sed -n 's#^PUT /api/pool-state/holds ##p' "$S/reqs")
{ [ "$(jq -r .kind <<<"$B")" = spawn ] && [ "$(jq -r .key <<<"$B")" = "" ] && [ "$(jq -r .project <<<"$B")" = pa ] \
  && [ "$(jq -r .until_at <<<"$B")" = "$((NOW + 604800))" ] \
  && [ "$(jq -r .why <<<"$B")" = "operator hold (console pool_hold 81): r" ]; } && ok || bad "H1 row PUT: $(cat "$S/reqs")"
{ [ "$(jf .result)" = ok ] && [ "$(jf .held)" = true ] && [ "$(jf .project)" = pa ] && [ "$(jf .row)" = written ] \
  && [ "$(jf .until)" = "$(date -u -d "@$((NOW + 604800))" +%Y-%m-%dT%H:%M:%SZ)" ]; } && ok || bad "H1 ack: $OUT"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "H1 more than one stdout line"
ph pa '{"hold":true}'
grep -q " operator hold (console pool_hold 81): held from console, no reason given$" "$F" && ok || bad "H1 default reason: $(cat "$F")"
ph pa "{\"hold\":true,\"reason\":\"a$(printf 'b%.0s' $(seq 1 300))\\nz\"}"
L=$(cat "$F"); W=${L#* }
{ [ "${#W}" -le 200 ] && [ "$(wc -l < "$F")" = 1 ]; } && ok || bad "H1 why is one line, at most 200 chars (${#W})"

echo "--- H2: the fly-pool lane's pool_spawn_held reads the file this command wrote"
reset
awk '/^pool_spawn_hold_path\(\)/{print} /^pool_spawn_held\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/reader.sh"
grep -q '^pool_spawn_held()' "$T/reader.sh" && ok || bad "H2 could not extract pool_spawn_held from bin/fly-pool.sh"
OUT=$(env -u PAUSE_BOARD_TTL_S HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/cmd-pool-hold.sh" pa '{"hold":true,"reason":"drain"}' 82 2>/dev/null)
WHY=$(PDIR="$H/state/pool/pa" bash -c '. "$1"; pool_spawn_held' _ "$T/reader.sh"); WRC=$?
{ [ "$WRC" = 0 ] && [ "$WHY" = "operator hold (console pool_hold 82): drain" ]; } && ok || bad "H2 reader rc=$WRC why='$WHY'"

echo "--- H3: hold:false removes the file and clears the row"
ph pa '{"hold":true}'; : > "$S/reqs"
ph pa '{"hold":false}'
{ [ "$RC" = 0 ] && [ ! -e "$F" ]; } && ok || bad "H3 rc $RC file $( [ -e "$F" ] && echo stays )"
B=$(sed -n 's#^PATCH /api/pool-state/holds ##p' "$S/reqs")
{ [ "$(reqs)" = 1 ] && [ "$(jq -r .clear <<<"$B")" = true ] && [ "$(jq -r .kind <<<"$B")" = spawn ] \
  && [ "$(jq -r .key <<<"$B")" = "" ]; } && ok || bad "H3 row PATCH: $(cat "$S/reqs")"
{ [ "$(jf .result)" = ok ] && [ "$(jf .held)" = false ] && [ "$(jf .row)" = cleared ]; } && ok || bad "H3 ack: $OUT"
rm -f "$H/flags/fly-pool-pa"
ph pa '{"hold":false}'
[ "$RC" = 0 ] && ok || bad "H3 a release with no pool flag is rc $RC ($OUT)"
: > "$H/flags/fly-pool-pa"

echo "--- H4: a row clear that fails is rc 1"
reset; ph pa '{"hold":true}'; echo 1 > "$S/req_rc"
ph pa '{"hold":false}'
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ] && [ ! -e "$F" ]; } && ok || bad "H4 rc $RC out=$OUT"
jf .reason | grep -q 'row' && ok || bad "H4 reason names the row: $OUT"

echo "--- H5: a row write that fails on hold is rc 0, row not written, file written"
reset; echo 1 > "$S/req_rc"
ph pa '{"hold":true}'
{ [ "$RC" = 0 ] && [ "$(jf .held)" = true ] && [ "$(jf .row)" = "not written" ] && [ -s "$F" ]; } && ok || bad "H5 rc $RC out=$OUT"

echo "--- H6: refusals are rc 3, write nothing and send nothing"
for pl in '{"hold":"true"}' '{"hold":1}' '{"hold":null}' '{}' '[]' 'nope'; do
  reset; ph pa "$pl"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ] && [ ! -e "$F" ] && [ "$(reqs)" = 0 ]; } && ok || bad "H6 payload $pl: rc $RC out=$OUT"
done
for p in '../x' 'a/b' 'zz' '' '#'; do
  reset; ph "$p" '{"hold":true}'
  { [ "$RC" = 3 ] && [ "$(reqs)" = 0 ] && [ ! -d "$H/state/pool" ]; } && ok || bad "H6 project '$p': rc $RC out=$OUT"
done
reset; ph pb '{"hold":true}'
{ [ "$RC" = 3 ] && [ ! -e "$H/state/pool/pb/_spawn-hold" ] && [ "$(reqs)" = 0 ]; } && ok || bad "H6 no flags/fly-pool-pb: rc $RC out=$OUT"
jf .reason | grep -q 'not enabled' && ok || bad "H6 no-flag reason: $OUT"

echo "--- H7: PAUSE_BOARD_TTL_S"
for v in abc 0 -5; do
  reset; ph pa '{"hold":true}' PAUSE_BOARD_TTL_S="$v"
  [ "$(cut -d' ' -f1 "$F" 2>/dev/null)" = "$((NOW + 604800))" ] && ok || bad "H7 TTL '$v' gave '$(cat "$F" 2>/dev/null)'"
done
reset; ph pa '{"hold":true}' PAUSE_BOARD_TTL_S=3600
[ "$(cut -d' ' -f1 "$F" 2>/dev/null)" = "$((NOW + 3600))" ] && ok || bad "H7 TTL 3600 gave '$(cat "$F" 2>/dev/null)'"

echo "--- H8: the pool_state_rows knob off sends no row"
reset; echo 0 > "$S/knob"
ph pa '{"hold":true}'
{ [ "$RC" = 0 ] && [ "$(jf .row)" = off ] && [ "$(reqs)" = 0 ] && [ -s "$F" ]; } && ok || bad "H8 hold: rc $RC out=$OUT"
ph pa '{"hold":false}'
{ [ "$RC" = 0 ] && [ "$(jf .row)" = off ] && [ "$(reqs)" = 0 ] && [ ! -e "$F" ]; } && ok || bad "H8 release: rc $RC out=$OUT"

echo "cmd-pool-hold.bh-7708-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

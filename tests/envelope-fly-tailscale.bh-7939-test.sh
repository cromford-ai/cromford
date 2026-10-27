#!/bin/bash
# tests/envelope-fly-tailscale.bh-7939-test.sh — BH-7976 (BH-7939.2, slice C0):
# the hub half of a fleet envelope, bin/lib/envelope-fleet.sh, plus the worker
# half (worker/jobs/src/routes/fleet-accounts.js and the `fleet:` scope in
# worker/jobs/src/routes/secret-envelopes.js), whose node suite this runs.
#
# 0 network calls: setting_set is a local stub that appends <key>=<value> to a
# file, and HARNESS_ENV_DIR points at a scratch dir. Every case has its own dir.
#   E1 fly: FLY_ORG + FLY_API_TOKEN replaced in place, mode 600, one flag
#   E2 tailscale: the fleet key flags, a project key does not; no value in output
#   E3 the round-trip through fly_token_resolve (FLY_TOKEN_SRC=FLY_API_TOKEN)
#   E4 telegram: one TELEGRAM_BOT_TOKEN line in global.env, mode 600, no flag
#   E5 the shared scope table (tests/fixtures/fleet-scopes.bh-7939.tsv)
#   E6 refused values write nothing; near-miss lines survive
#   E7 a failed read back is rc 2, a failed flag is rc 3 (`unflagged`)
#   E8 the library calls no network tool
#   W  the worker suite worker/jobs/test/fleet-accounts.bh-7939.test.js, 0 skipped
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/envelope-fly-tailscale.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/envelope-fleet.sh"
FIX="$DIR/tests/fixtures/fleet-scopes.bh-7939.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

[ -f "$LIB" ] || { echo "FAIL bin/lib/envelope-fleet.sh is missing"; echo "envelope-fly-tailscale.bh-7939: 0 passed, 1 failed"; exit 1; }
# shellcheck source=bin/lib/envelope-fleet.sh
. "$LIB" || { echo "FAIL cannot source bin/lib/envelope-fleet.sh"; exit 1; }
# shellcheck source=bin/lib/fly-token.sh
. "$DIR/bin/lib/fly-token.sh" || exit 1
# Keep the real read back: E7 replaces env_line_check and puts this one back.
eval "_real_env_line_check() $(declare -f env_line_check | tail -n +2)"

FLAGS=""
setting_set() { printf '%s=%s\n' "$1" "$2" >> "$FLAGS"; }

# new_case <name>: a fresh env dir and flag file. Sets C.
new_case() {
  C="$T/$1"; mkdir -p "$C/env"; : > "$C/flags"
  export HARNESS_ENV_DIR="$C/env"; FLAGS="$C/flags"
}
secret() { printf '%s' "$2" > "$C/$1"; printf '%s' "$C/$1"; }
count()  { grep -c -E "$1" "$2" 2>/dev/null || true; }

echo "E1: fleet:fly:acme replaces FLY_ORG and FLY_API_TOKEN in place"
new_case e1
printf '%s\n' 'OTHER=1' 'FLY_ORG=old' 'MID=2' "export FLY_API_TOKEN=old" 'FLY_API_TOKEN=dup' 'LAST=3' > "$C/env/fly.env"
chmod 644 "$C/env/fly.env"
OUT=$(envelope_fleet_apply fleet:fly:acme "$(secret s 'FlyV1 fm2_tok-fixture-e1')" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "E1 rc 0" || bad "E1 rc $RC: $OUT"
[ "$(count '^FLY_ORG=' "$C/env/fly.env")" = 1 ] && ok "E1 one FLY_ORG line" || bad "E1 FLY_ORG lines: $(cat "$C/env/fly.env")"
[ "$(count '^(export )?FLY_API_TOKEN=' "$C/env/fly.env")" = 1 ] && ok "E1 one FLY_API_TOKEN line" || bad "E1 FLY_API_TOKEN lines: $(cat "$C/env/fly.env")"
WANT=$(printf '%s\n' 'OTHER=1' "FLY_ORG='acme'" 'MID=2' "FLY_API_TOKEN='FlyV1 fm2_tok-fixture-e1'" 'LAST=3')
[ "$(cat "$C/env/fly.env")" = "$WANT" ] && ok "E1 lines in the first line's place, others kept" || bad "E1 file: $(cat "$C/env/fly.env")"
[ "$(stat -c %a "$C/env/fly.env")" = 600 ] && ok "E1 mode 600" || bad "E1 mode $(stat -c %a "$C/env/fly.env")"
[ "$(cat "$C/flags")" = "fly.token_present=1" ] && ok "E1 one flag fly.token_present=1" || bad "E1 flags: $(cat "$C/flags")"
case "$OUT" in "ENVELOPE_FLEET ok fly"*) ok "E1 prints ENVELOPE_FLEET ok" ;; *) bad "E1 output: $OUT" ;; esac
grep -q envtmp <<<"$(ls "$C/env")" && bad "E1 a tmp file is left" || ok "E1 no tmp file left"

echo "E2: fleet:tailscale and fleet:tailscale:cromford"
new_case e2
printf '%s\n' 'FLY_ORG=acme' > "$C/env/fly.env"
OUT=$(envelope_fleet_apply fleet:tailscale "$(secret s 'tskey-auth-fixture-fleet')" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "E2 fleet key rc 0" || bad "E2 fleet key rc $RC: $OUT"
[ "$(count '^TS_AUTHKEY=' "$C/env/fly.env")" = 1 ] && grep -qxF "TS_AUTHKEY='tskey-auth-fixture-fleet'" "$C/env/fly.env" \
  && ok "E2 one TS_AUTHKEY line" || bad "E2 file: $(cat "$C/env/fly.env")"
[ "$(cat "$C/flags")" = "tailscale.key_present=1" ] && ok "E2 tailscale.key_present=1" || bad "E2 flags: $(cat "$C/flags")"
OUT2=$(envelope_fleet_apply fleet:tailscale:cromford "$(secret p 'tskey-auth-fixture-proj')" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "E2 project key rc 0" || bad "E2 project key rc $RC: $OUT2"
grep -qxF "TS_AUTHKEY_CROMFORD='tskey-auth-fixture-proj'" "$C/env/fly.env" && ok "E2 TS_AUTHKEY_CROMFORD line" || bad "E2 file: $(cat "$C/env/fly.env")"
grep -qxF "TS_AUTHKEY='tskey-auth-fixture-fleet'" "$C/env/fly.env" && ok "E2 the fleet key line is unchanged" || bad "E2 fleet key changed"
[ "$(cat "$C/flags")" = "tailscale.key_present=1" ] && ok "E2 the project key sets no flag" || bad "E2 flags: $(cat "$C/flags")"
case "$OUT$OUT2" in *tskey-auth-fixture*) bad "E2 a secret value is in the output" ;; *) ok "E2 no secret value in stdout or stderr" ;; esac

echo "E3: the written fly.env round-trips through fly_token_resolve"
new_case e3
printf '%s\n' 'FLY_ORG=old' > "$C/env/fly.env"
VAL='FlyV1 fm2_tok-fixture-abc,fm2_tok-fixture-def'
envelope_fleet_apply fleet:fly:acme "$(secret s "$VAL")" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok "E3 rc 0" || bad "E3 rc $RC"
GOT=$(env -u FLY_API_TOKEN -u FLY_API_TOKEN_PROJ -u FLY_ORG bash -c '
  set -a; . "$1"; set +a; . "$2"; fly_token_resolve proj || exit 9
  printf "%s|%s|%s" "$FLY_TOKEN_SRC" "$FLY_TOKEN_VAL" "$FLY_ORG"' _ "$C/env/fly.env" "$DIR/bin/lib/fly-token.sh")
[ "$GOT" = "FLY_API_TOKEN|$VAL|acme" ] && ok "E3 FLY_TOKEN_SRC=FLY_API_TOKEN, the value and FLY_ORG round-trip" || bad "E3 got: $GOT"

echo "E4: fleet:telegram writes one TELEGRAM_BOT_TOKEN line in global.env"
new_case e4
printf '%s\n' 'JOBS_URL=https://jobs.example.test' 'TELEGRAM_BOT_TOKEN=old' > "$C/env/global.env"
OUT=$(envelope_fleet_apply fleet:telegram "$(secret s '123456:tok-fixture-telegram')" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "E4 rc 0" || bad "E4 rc $RC: $OUT"
[ "$(count '^TELEGRAM_BOT_TOKEN=' "$C/env/global.env")" = 1 ] && grep -qxF "TELEGRAM_BOT_TOKEN='123456:tok-fixture-telegram'" "$C/env/global.env" \
  && ok "E4 one TELEGRAM_BOT_TOKEN line" || bad "E4 file: $(cat "$C/env/global.env")"
grep -qxF 'JOBS_URL=https://jobs.example.test' "$C/env/global.env" && ok "E4 the other line is kept" || bad "E4 JOBS_URL lost"
[ "$(stat -c %a "$C/env/global.env")" = 600 ] && ok "E4 mode 600" || bad "E4 mode $(stat -c %a "$C/env/global.env")"
[ -s "$C/flags" ] && bad "E4 a flag was set: $(cat "$C/flags")" || ok "E4 no flag call"
[ -e "$C/env/fly.env" ] && bad "E4 fly.env was created" || ok "E4 fly.env not touched"
# A missing env file is created, mode 600.
new_case e4b
envelope_fleet_apply fleet:telegram "$(secret s '123456:tok-fixture-new')" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$C/env/global.env")" = "TELEGRAM_BOT_TOKEN='123456:tok-fixture-new'" ] && [ "$(stat -c %a "$C/env/global.env")" = 600 ] \
  && ok "E4 a missing global.env is created, mode 600" || bad "E4 create rc $RC: $(cat "$C/env/global.env" 2>&1)"

echo "E5: every row of tests/fixtures/fleet-scopes.bh-7939.tsv"
new_case e5
printf '%s\n' 'KEEP=1' > "$C/env/fly.env"; cp "$C/env/fly.env" "$C/env/global.env"
SUM0=$(cat "$C/env/fly.env" "$C/env/global.env" | sha256sum)
ROWS=0; MISS=""
while IFS=$'\t' read -r scope want parse; do
  case "$scope" in '#'*|'') continue ;; esac
  ROWS=$((ROWS+1))
  got=$(envelope_fleet_scope_parse "$scope"); rc=$?
  if [ "$want" = accept ]; then
    [ "$rc" = 0 ] && [ "$got" = "$parse" ] || MISS="$MISS [$scope: rc $rc '$got']"
  else
    [ "$rc" = 1 ] || MISS="$MISS [$scope: rc $rc]"
    envelope_fleet_apply "$scope" "$(secret s 'tok-fixture-e5')" >/dev/null 2>&1; rc=$?
    [ "$rc" = 1 ] || MISS="$MISS [$scope: apply rc $rc]"
  fi
done < "$FIX"
[ "$ROWS" -ge 30 ] && ok "E5 the fixture has $ROWS rows" || bad "E5 only $ROWS fixture rows"
[ -z "$MISS" ] && ok "E5 envelope_fleet_scope_parse agrees with every row" || bad "E5 disagrees:$MISS"
[ "$(cat "$C/env/fly.env" "$C/env/global.env" | sha256sum)" = "$SUM0" ] && [ ! -s "$C/flags" ] \
  && ok "E5 a refused scope writes nothing" || bad "E5 a refused scope wrote: $(cat "$C/flags")"

echo "E6: refused values write nothing; near-miss lines survive"
new_case e6
printf '%s\n' 'TS_AUTHKEY=old' 'TS_AUTHKEY_X=keep' '#TS_AUTHKEY=comment' 'XTS_AUTHKEY=keep2' > "$C/env/fly.env"
chmod 600 "$C/env/fly.env"
SUM0=$(sha256sum < "$C/env/fly.env")
printf "%s" "tskey-fixture'quote" > "$C/q"
printf 'tskey-fixture\nsecond' > "$C/lf"
printf 'tskey-fixture\r' > "$C/cr"
printf 'tskey-fixture\n' > "$C/tlf"
: > "$C/empty"
printf 'tskey-fixture\0nul' > "$C/nul"
for v in q lf cr tlf empty nul missing; do
  envelope_fleet_apply fleet:tailscale "$C/$v" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && ok "E6 value $v is rc 1" || bad "E6 value $v rc $rc"
done
[ "$(sha256sum < "$C/env/fly.env")" = "$SUM0" ] && ok "E6 fly.env bytes unchanged" || bad "E6 fly.env changed: $(cat "$C/env/fly.env")"
[ ! -s "$C/flags" ] && ok "E6 no flag call" || bad "E6 flags: $(cat "$C/flags")"
grep -q envtmp <<<"$(ls "$C/env")" && bad "E6 a tmp file is left" || ok "E6 no tmp file left"
envelope_fleet_apply fleet:tailscale "$(secret s 'tskey-fixture-new')" >/dev/null 2>&1; RC=$?
WANT=$(printf '%s\n' "TS_AUTHKEY='tskey-fixture-new'" 'TS_AUTHKEY_X=keep' '#TS_AUTHKEY=comment' 'XTS_AUTHKEY=keep2')
[ "$RC" = 0 ] && [ "$(cat "$C/env/fly.env")" = "$WANT" ] && ok "E6 TS_AUTHKEY_X, #TS_AUTHKEY and XTS_AUTHKEY survive" || bad "E6 rc $RC file: $(cat "$C/env/fly.env")"
# A bad NAME, and a missing env directory.
env_line_set "$C/env/fly.env" 'bad-name' "$C/q" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "E6 a bad NAME is rc 1" || bad "E6 bad NAME rc $rc"
printf 'v-fixture' > "$C/v"
env_line_set "$C/nodir/fly.env" 'OK_NAME' "$C/v" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$C/nodir" ] && ok "E6 a missing directory is rc 2" || bad "E6 missing dir rc $rc"
# A symlinked env file is written at its target, and stays a symlink.
mkdir -p "$C/real"; printf '%s\n' 'A=1' > "$C/real/g.env"; ln -s "$C/real/g.env" "$C/link.env"
env_line_set "$C/link.env" 'B_NAME' "$C/v" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -L "$C/link.env" ] && [ "$(cat "$C/real/g.env")" = "$(printf '%s\n' 'A=1' "B_NAME='v-fixture'")" ] \
  && ok "E6 a symlinked env file is written at its target" || bad "E6 symlink rc $rc"

echo "E7: a failed read back is rc 2 with no flag; a failed flag is rc 3"
new_case e7
env_line_check() { return 2; }
OUT=$(envelope_fleet_apply fleet:tailscale "$(secret s 'tskey-fixture-e7')" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "E7 a failed read back is rc 2" || bad "E7 read back rc $RC: $OUT"
[ ! -s "$C/flags" ] && ok "E7 a failed read back sets no flag" || bad "E7 flags: $(cat "$C/flags")"
case "$OUT" in "ENVELOPE_FLEET failed"*) ok "E7 prints ENVELOPE_FLEET failed" ;; *) bad "E7 output: $OUT" ;; esac
eval "env_line_check() $(declare -f _real_env_line_check | tail -n +2)"
setting_set() { return 1; }
OUT=$(envelope_fleet_apply fleet:tailscale "$(secret s 'tskey-fixture-e7')" 2>&1); RC=$?
[ "$RC" = 3 ] && ok "E7 a failed flag write is rc 3" || bad "E7 flag fail rc $RC: $OUT"
case "$OUT" in "ENVELOPE_FLEET unflagged"*) ok "E7 prints ENVELOPE_FLEET unflagged" ;; *) bad "E7 output: $OUT" ;; esac
grep -qxF "TS_AUTHKEY='tskey-fixture-e7'" "$C/env/fly.env" && ok "E7 the line is still written" || bad "E7 file: $(cat "$C/env/fly.env")"
unset -f setting_set
OUT=$(envelope_fleet_apply fleet:fly:acme "$(secret s 'tok-fixture-e7')" 2>&1); RC=$?
[ "$RC" = 3 ] && ok "E7 setting_set not loaded is rc 3" || bad "E7 no setting_set rc $RC: $OUT"
setting_set() { printf '%s=%s\n' "$1" "$2" >> "$FLAGS"; }
# A file that stops setting the name after the write is caught by the real read back.
printf '%s\n' "OTHER=1" > "$C/env/fly.env"
printf 'tok-fixture-e7' > "$C/v"
env_line_check "$C/env/fly.env" TS_AUTHKEY "$C/v"; rc=$?
[ "$rc" = 2 ] && ok "E7 env_line_check on a file without the name is rc 2" || bad "E7 env_line_check rc $rc"
# No env dir resolvable: HARNESS_ENV_DIR, HARNESS and H all unset.
OUT=$(env -u HARNESS_ENV_DIR -u HARNESS -u H bash -c '. "$1"; setting_set() { :; }; printf x > "$2/s"; envelope_fleet_apply fleet:telegram "$2/s"' _ "$LIB" "$C" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "E7 no env dir is rc 2" || bad "E7 no env dir rc $RC: $OUT"

echo "E8: the library calls no network tool"
if grep -nE '\b(curl|wget|nc|_jobs_req)\b' "$LIB" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
  bad "E8 a network call in bin/lib/envelope-fleet.sh"
else ok "E8 no curl, wget, nc or _jobs_req"; fi

echo "W: the worker suite"
for f in worker/jobs/src/routes/fleet-accounts.js \
         worker/jobs/src/routes/secret-envelopes.js \
         worker/jobs/test/route-table.d/bh-7939-fleet-accounts.txt \
         worker/jobs/test/fleet-accounts.bh-7939.test.js \
         tests/fixtures/fleet-scopes.bh-7939.tsv; do
  [ -f "$DIR/$f" ] && ok "W $f exists" || bad "W missing $f"
done
if ! command -v node >/dev/null 2>&1; then
  echo "envelope-fly-tailscale: node suite SKIPPED — node is not installed on this box"
else
  . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { bad "cannot compose catalog/context-budgets.json"; exit 1; }
  skipped() { sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' <<<"$1" | tail -1; }
  OUT=$(cd "$DIR/worker/jobs" && node --test test/fleet-accounts.bh-7939.test.js 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ "$(skipped "$OUT")" = 0 ]; then ok "W worker/jobs/test/fleet-accounts.bh-7939.test.js, 0 skipped"
  else bad "W the worker suite failed (rc=$RC, skipped=$(skipped "$OUT")):"; printf '%s\n' "$OUT" | grep -E '^not ok|^# (pass|fail|skip)|Error|expected|actual' | head -40; fi
fi

echo "envelope-fly-tailscale.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

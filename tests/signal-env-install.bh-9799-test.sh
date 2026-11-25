#!/bin/bash
# tests/signal-env-install.bh-9799-test.sh — BH-9799 T6: bin/signal-env-install.sh
# <project> <NAME> reads ONE value on stdin and writes NAME=<value> into
# env/<project>.env under locks/harden-state.lock, between
# bin/harden-state.sh --release and --rearm. The value is never printed.
#
# Scratch $H with a stub bin/harden-state.sh that logs its argv and whether
# the lock is held at that moment (flock -n on the same lock fails = held).
#
#   E1  a missing file: NAME=value, mode 600
#   E2  replace an existing NAME line, other lines kept; stdout line, no value
#   E3  refusals (bad NAME, two lines, empty, a quote, unknown project): rc 2,
#       file untouched, no harden-state call
#   E4  a failing mv: --rearm still runs, no "installed" line, rc not 0
#   E5  round trip: ss_env_value reads back the value written
#   E6  the harden-state log: --release then --rearm, both under the lock
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/signal-env-install.bh-9799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

[ -f "$DIR/bin/signal-env-install.sh" ] && ok || bad "missing $DIR/bin/signal-env-install.sh"

H="$T/h"; export FX="$T/fx"
mkdir -p "$H/env" "$H/locks" "$T/fakebin" "$FX"
scratch_install_closure bin/signal-env-install.sh "$H" >/dev/null || bad "closure install failed"
scratch_install_closure bin/lib/signal-source.sh "$H" >/dev/null || bad "closure install (signal-source) failed"
rm -f "$H/bin/harden-state.sh"
cat > "$H/bin/harden-state.sh" <<'SH'
#!/bin/bash
held=free
flock -n "$HARNESS/locks/harden-state.lock" true 2>/dev/null || held=held
printf '%s %s %s\n' "$1" "$(basename "$2")" "$held" >> "$FX/hs.log"
exit 0
SH
chmod +x "$H/bin/harden-state.sh"
printf '%s\n' "# fixture fleet" "alpha  example-org/fixture-alpha  https://alpha.example.com  -  1  box-fixture 192.0.2.1" > "$T/fleet.conf"

VAL="alpha-install-fixture-value-1"
run() { # run <stdin-text> <args...>; extra env in RUN_ENV
  local in=$1; shift
  rm -f "$FX/hs.log"
  printf '%s' "$in" | env -u HARNESS_ENV_DIR HARNESS="$H" HARNESS_TEST_SANDBOX=1 FLEET_CONF="$T/fleet.conf" JOBS_URL= \
    PATH="${RUN_PATH:-$PATH}" bash "$H/bin/signal-env-install.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
F="$H/env/alpha.env"

# ── E1: a missing file ──────────────────────────────────────────────────────
rm -f "$F"
run "$VAL"$'\n' alpha SENTRY_ALPHA_TOKEN
check "E1 rc 0 [$(cat "$T/err")]" '[ "$(cat "$T/rc")" = 0 ]'
check "E1 the file holds the line" '[ "$(cat "$F" 2>/dev/null)" = "SENTRY_ALPHA_TOKEN=$VAL" ]'
check "E1 mode 600 ($(stat -c %a "$F" 2>/dev/null))" '[ "$(stat -c %a "$F" 2>/dev/null)" = 600 ]'

# ── E2: replace one line, keep the others ───────────────────────────────────
printf '%s\n' "# alpha env" "OTHER=keep-fixture" "export SENTRY_ALPHA_TOKEN=old-fixture" "LAST=also-kept" > "$F"
run "$VAL-new" alpha SENTRY_ALPHA_TOKEN
check "E2 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "E2 the old line is gone, the new one is last" '! grep -q old-fixture "$F" && [ "$(tail -1 "$F")" = "SENTRY_ALPHA_TOKEN=$VAL-new" ]'
check "E2 the other lines are kept" '[ "$(sed -n 1,3p "$F")" = "$(printf "# alpha env\nOTHER=keep-fixture\nLAST=also-kept")" ]'
check "E2 stdout [$(cat "$T/out")]" '[ "$(cat "$T/out")" = "installed SENTRY_ALPHA_TOKEN for alpha (value not shown)" ]'
check "E2 the value is in no output" '! grep -qF "$VAL" <<<"$(cat "$T/out" "$T/err")"'

# ── E6: release then rearm, both under the lock ─────────────────────────────
check "E6 harden-state log [$(tr '\n' '|' < "$FX/hs.log")]" '[ "$(cat "$FX/hs.log")" = "$(printf -- "--release alpha.env held\n--rearm alpha.env held")" ]'

# ── E3: refusals touch nothing ──────────────────────────────────────────────
printf '%s\n' "OTHER=keep-fixture" > "$F"; BEFORE=$(cat "$F")
for c in "bad-name|$VAL|alpha|lower_name" "two-lines|a-fixture"$'\n'"b-fixture|alpha|SENTRY_ALPHA_TOKEN" \
         "empty||alpha|SENTRY_ALPHA_TOKEN" "quote|a\"fixture|alpha|SENTRY_ALPHA_TOKEN" \
         "space|a fixture|alpha|SENTRY_ALPHA_TOKEN" "project|$VAL|zeta|SENTRY_ALPHA_TOKEN"; do
  IFS='|' read -r -d '' tag v p n <<<"$c"; n=${n%$'\n'}
  run "$v" "$p" "$n"
  check "E3 $tag: rc 2 ($(cat "$T/rc"))" '[ "$(cat "$T/rc")" = 2 ]'
  check "E3 $tag: file untouched" '[ "$(cat "$F")" = "$BEFORE" ] && [ ! -e "$H/env/zeta.env" ]'
  check "E3 $tag: no harden-state call" '[ ! -s "$FX/hs.log" ]'
  check "E3 $tag: the value is not echoed" '[ -z "$v" ] || ! grep -qF -- "$v" <<<"$(cat "$T/out" "$T/err")"'
done
run "$VAL" alpha
check "E3 a missing NAME: rc 2" '[ "$(cat "$T/rc")" = 2 ]'

# ── E4: a failing mv still re-arms ──────────────────────────────────────────
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/mv"; chmod +x "$T/fakebin/mv"
printf '%s\n' "OTHER=keep-fixture" > "$F"
RUN_PATH="$T/fakebin:$PATH" run "$VAL" alpha SENTRY_ALPHA_TOKEN
check "E4 rc not 0" '[ "$(cat "$T/rc")" != 0 ]'
check "E4 --rearm still ran" 'grep -q "^--rearm alpha.env" "$FX/hs.log"'
check "E4 no installed line" '! grep -q installed "$T/out"'
check "E4 the file is unchanged" '[ "$(cat "$F")" = "OTHER=keep-fixture" ]'
check "E4 no temp file left" '[ -z "$(ls "$H/env" | grep -v "^alpha.env$")" ]'

# ── E5: round trip through ss_env_value ─────────────────────────────────────
run "$VAL-rt" alpha POSTHOG_ALPHA_KEY
GOT=$(HARNESS="$H" bash -c '. "$1/bin/lib/signal-source.sh" && ss_env_value "$2" POSTHOG_ALPHA_KEY' _ "$H" "$F")
check "E5 ss_env_value reads back the value" '[ "$GOT" = "$VAL-rt" ]'

echo "signal-env-install: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

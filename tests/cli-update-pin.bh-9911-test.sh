#!/bin/bash
# tests/cli-update-pin.bh-9911-test.sh — BH-9911: with claude_cli.pin.enabled=1,
# bin/cli-update.sh installs exactly the pinned claude version (the canary
# version on the canary box), never `latest`. Driven, not grepped: the real
# script runs on scratch boxes with a fake npm, a fake native launcher and a
# fake worker (curl stub) that serves the settings rows.
#
#   U1 pin on: npm gets @2.1.330, not @latest; ok=1
#   U2 the canary box (box-id small) installs the canary version 2.1.331
#   U3 a non-canary box (project-4) with a canary version set installs the pin
#   U4 2.1.340 -> 2.1.330 is a planned downgrade: ok=1, rc 0
#   U5 a NEWER link off the pin is repointed at the pinned install
#   U6 pin off (row 0): @latest, as today
#   U7 knob outage after an on read: claude is not touched, note pin-unknown,
#      codex still updates
#   U8 a failed pinned install that leaves another version: ok=0, rc 1,
#      note off-pin <after> want <pin>
#   U9 native install gets `install 2.1.330`, not `install latest`
#   U10 a failed pinned install that leaves a NEWER version (2.1.340, pin
#      2.1.330) is ok=0, rc 1: "newer than the pin" is still off the pin
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cli-update-pin.bh-9911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
BASE="$T"
mkdir -p "$BASE/sysbin"
for f in /usr/bin/* /bin/*; do
  n=$(basename "$f"); case "$n" in claude|codex|npm|curl) continue ;; esac
  [ -e "$BASE/sysbin/$n" ] || ln -s "$f" "$BASE/sysbin/$n" 2>/dev/null
done

new_box() { # new_box <box-id> -> path
  local B; B=$(mktemp -d "$BASE/box-XXXXXX")
  mkdir -p "$B/harness/logs" "$B/harness/state" "$B/harness/env" "$B/harness/flags" "$B/settings" \
           "$B/usr/bin" "$B/usr/lib/node_modules" "$B/usr/local/bin" "$B/home/.local/bin" \
           "$B/home/.local/share/claude/versions" "$B/fakebin"
  ln -s "$BASE/sysbin" "$B/sysbin"
  scratch_install_closure bin/jobs-client.sh "$B/harness" >/dev/null
  echo "HARNESS_SECRET=tok-fixture-bh9911" > "$B/harness/env/global.env"
  echo "$1" > "$B/harness/state/box-id"
  # fake npm: `install -g [--force] <pkg>@<ver>`; latest = NPM_LATEST_<cli>.
  cat > "$B/fakebin/npm" <<'NPM'
#!/bin/bash
echo "$*" >> "$NPM_CALLS"
[ "$1" = prefix ] && { echo "$NPM_PREFIX"; exit 0; }
SPEC=""; for a in "$@"; do case "$a" in @*) SPEC="$a" ;; esac; done
PKG="${SPEC%@*}"; VER="${SPEC##*@}"
case "$PKG" in *claude-code) CLI=claude; ENTRY=claude.exe ;; *codex) CLI=codex; ENTRY=codex.js ;; *) exit 1 ;; esac
MODE_VAR="NPM_MODE_$CLI"; [ "${!MODE_VAR:-ok}" = down ] && { echo "npm ERR! code ENOTFOUND"; exit 1; }
if [ "$VER" = latest ]; then L="NPM_LATEST_$CLI"; VER="${!L:-9.9.9}"; fi
D="$NPM_PREFIX/lib/node_modules/$PKG"; mkdir -p "$D/bin"
printf '#!/bin/bash\ncase "$1" in --version) echo "$(cat "$(dirname "$(readlink -f "$0")")/../VERSION") (fake)";; esac\n' > "$D/bin/$ENTRY"
chmod +x "$D/bin/$ENTRY"; echo "$VER" > "$D/VERSION"
ln -sfn "$D/bin/$ENTRY" "$NPM_PREFIX/bin/$CLI"
NPM
  # fake worker: settings rows from $B/settings/<key>; everything else 200.
  cat > "$B/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"
echo "$URL" >> "$REQ_SINK"
[ -e "$SETTINGS_DIR/../down" ] && exit 7
case "$URL" in
  */api/settings/*) k="${URL##*/api/settings/}"
    if [ -f "$SETTINGS_DIR/$k" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$SETTINGS_DIR/$k")"; else printf '{}\n404\n'; fi ;;
  *) printf '{"accepted":1,"inserted":1}\n200\n' ;;
esac
CURL
  chmod +x "$B/fakebin/npm" "$B/fakebin/curl"
  echo "$B"
}
npm_pkg() { # npm_pkg <box> <cli> <version>
  local B="$1" cli="$2" v="$3" P="$1/usr" pkg entry
  case "$cli" in claude) pkg="@anthropic-ai/claude-code"; entry=claude.exe ;; codex) pkg="@openai/codex"; entry=codex.js ;; esac
  mkdir -p "$P/lib/node_modules/$pkg/bin" "$P/bin"
  printf '#!/bin/bash\ncase "$1" in --version) echo "$(cat "$(dirname "$(readlink -f "$0")")/../VERSION") (fake)";; esac\n' > "$P/lib/node_modules/$pkg/bin/$entry"
  chmod +x "$P/lib/node_modules/$pkg/bin/$entry"; echo "$v" > "$P/lib/node_modules/$pkg/VERSION"
  ln -sfn "$P/lib/node_modules/$pkg/bin/$entry" "$P/bin/$cli"
}
native_claude() { # native_claude <box> <version>; `install <v>` adds <v> (NATIVE_MODE=fail: no change)
  local B="$1" v="$2" VD="$1/home/.local/share/claude/versions"
  cat > "$VD/$v" <<'NAT'
#!/bin/bash
ME=$(readlink -f "$0"); VD=$(dirname "$ME")
case "$1" in
  --version) echo "$(basename "$ME") (Claude Code)" ;;
  install) echo "install $2" >> "$NATIVE_CALLS"
           [ "${NATIVE_MODE:-ok}" = fail ] && exit 1
           V="$2"; [ "$V" = latest ] && V="$NATIVE_LATEST"
           cp "$ME" "$VD/$V"; ln -sfn "$VD/$V" "$VD/../../../bin/claude" ;;
esac
NAT
  chmod +x "$VD/$v"; ln -sfn "$VD/$v" "$B/home/.local/bin/claude"
}
set_row() { printf '%s' "$3" > "$1/settings/$2"; }
pin_on() { set_row "$1" claude_cli.pin.enabled 1; set_row "$1" claude_cli.pinned_version 2.1.330; }
run() { # run <box> [env...] -> OUT, RC
  local B="$1"; shift
  OUT=$(env -i PATH="$B/usr/bin:$B/fakebin:$B/sysbin" HOME="$B/home" "$@" \
        CLI_UPDATE_CLIS="claude codex" HARNESS="$B/harness" CLI_UPDATE_HOME="$B/home" CLI_UPDATE_NPM_PREFIX="$B/usr" \
        CLI_UPDATE_NPM_PREFIXES="$B/usr" CLI_UPDATE_LINK_DIRS="$B/usr/local/bin $B/usr/bin" JOBS_URL=https://jobs.test \
        NPM_PREFIX="$B/usr" NPM_CALLS="$B/npm.calls" NATIVE_CALLS="$B/native.calls" REQ_SINK="$B/req.log" SETTINGS_DIR="$B/settings" \
        bash "$DIR/bin/cli-update.sh" 2>"$B/stderr"); RC=$?
}
csv_ok() { awk -F, -v c="$2" '$3 == c { o = $7 } END { print o }' "$1/harness/logs/cli-versions.csv"; }

# U1
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.300; npm_pkg "$B" codex 0.150.1
run "$B" NPM_LATEST_claude=2.1.399 NPM_LATEST_codex=0.153.4
grep -q '@anthropic-ai/claude-code@2.1.330' "$B/npm.calls" && ok || bad "U1 npm not asked for @2.1.330: $(cat "$B/npm.calls")"
grep -q 'claude-code@latest' "$B/npm.calls" && bad "U1 @latest used with the pin on" || ok
[ "$RC" = 0 ] && grep -q '^claude 2.1.300 -> 2.1.330 method=npm ok=1' <<<"$OUT" && [ "$(csv_ok "$B" claude)" = 1 ] && ok || bad "U1 rc $RC: $OUT"
grep -q '@openai/codex@latest' "$B/npm.calls" && ok || bad "U1 codex is not pinned and must still go to latest"

# U2 / U3
B=$(new_box small); pin_on "$B"; set_row "$B" claude_cli.canary_version 2.1.331; npm_pkg "$B" claude 2.1.330; npm_pkg "$B" codex 0.153.4
run "$B" NPM_LATEST_codex=0.153.4
grep -q '@anthropic-ai/claude-code@2.1.331' "$B/npm.calls" && grep -q '^claude 2.1.330 -> 2.1.331 method=npm ok=1' <<<"$OUT" && ok \
  || bad "U2 canary box did not install 2.1.331: $(cat "$B/npm.calls") / $OUT"
B=$(new_box project-4); pin_on "$B"; set_row "$B" claude_cli.canary_version 2.1.331; npm_pkg "$B" claude 2.1.330; npm_pkg "$B" codex 0.153.4
run "$B" NPM_LATEST_codex=0.153.4
grep -q '@anthropic-ai/claude-code@2.1.330' "$B/npm.calls" && ! grep -q 'claude-code@2.1.331' "$B/npm.calls" && ok \
  || bad "U3 a non-canary box installed the canary: $(cat "$B/npm.calls")"

# U4
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.340; npm_pkg "$B" codex 0.153.4
run "$B" NPM_LATEST_codex=0.153.4
[ "$RC" = 0 ] && grep -q '^claude 2.1.340 -> 2.1.330 method=npm ok=1' <<<"$OUT" && ok || bad "U4 planned downgrade rc $RC: $OUT"
grep -q 'WORSE' "$B/harness/logs/cli-update.log" && bad "U4 a planned downgrade was logged WORSE" || ok

# U5 + U9: native launcher at 2.1.340 that refuses to install; npm at 2.1.330.
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.330; npm_pkg "$B" codex 0.153.4; native_claude "$B" 2.1.340
ln -sfn "$B/home/.local/bin/claude" "$B/usr/local/bin/claude"
run "$B" NPM_LATEST_codex=0.153.4 NATIVE_MODE=fail
grep -qx 'install 2.1.330' "$B/native.calls" && ok || bad "U9 native launcher not asked for 2.1.330: $(cat "$B/native.calls" 2>/dev/null)"
[ "$(readlink -f "$B/usr/local/bin/claude")" = "$B/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" ] && ok \
  || bad "U5 the newer link off the pin was not repointed: -> $(readlink -f "$B/usr/local/bin/claude")"
ls "$B/usr/local/bin"/claude.bak-* >/dev/null 2>&1 && ok || bad "U5 the old link was not backed up"
grep -q '^claude 2.1.330 -> 2.1.330 method=native+npm ok=1' <<<"$OUT" && ok || bad "U5 stdout: $OUT"

# U6
B=$(new_box project-4); set_row "$B" claude_cli.pin.enabled 0; npm_pkg "$B" claude 2.1.300; npm_pkg "$B" codex 0.153.4
run "$B" NPM_LATEST_claude=2.1.399 NPM_LATEST_codex=0.153.4
grep -q '@anthropic-ai/claude-code@latest' "$B/npm.calls" && grep -q '^claude 2.1.300 -> 2.1.399 method=npm ok=1' <<<"$OUT" && ok \
  || bad "U6 pin off did not go to latest: $(cat "$B/npm.calls") / $OUT"

# U7: an on read is cached; then the worker goes down.
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.330; npm_pkg "$B" codex 0.150.1
run "$B" NPM_LATEST_codex=0.150.1
: > "$B/npm.calls"; : > "$B/down"
run "$B" NPM_LATEST_claude=2.1.399 NPM_LATEST_codex=0.153.4
grep -q 'claude-code' "$B/npm.calls" && bad "U7 claude was updated while the pin state was unknown: $(cat "$B/npm.calls")" || ok
grep -q '^claude 2.1.330 -> 2.1.330 method=none ok=1 .*note=pin-unknown' <<<"$OUT" && ok || bad "U7 stdout: $OUT"
grep -q '^codex 0.150.1 -> 0.153.4 method=npm ok=1' <<<"$OUT" && ok || bad "U7 codex not updated: $OUT"
[ "$RC" = 0 ] && ok || bad "U7 rc $RC"

# U8
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.300; npm_pkg "$B" codex 0.153.4
run "$B" NPM_MODE_claude=down NPM_LATEST_codex=0.153.4
[ "$RC" = 1 ] && grep -q '^claude 2.1.300 -> 2.1.300 method=npm ok=0 .*off-pin 2.1.300 want 2.1.330' <<<"$OUT" && ok \
  || bad "U8 failed pinned install rc $RC: $OUT"

# U10
B=$(new_box project-4); pin_on "$B"; npm_pkg "$B" claude 2.1.340; npm_pkg "$B" codex 0.153.4
run "$B" NPM_MODE_claude=down NPM_LATEST_codex=0.153.4
[ "$RC" = 1 ] && grep -q '^claude 2.1.340 -> 2.1.340 method=npm ok=0 .*off-pin 2.1.340 want 2.1.330' <<<"$OUT" \
  && [ "$(csv_ok "$B" claude)" = 0 ] && ok || bad "U10 a newer version off the pin passed as ok: rc $RC: $OUT"

echo "cli-update-pin.bh-9911-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

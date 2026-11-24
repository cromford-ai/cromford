#!/bin/bash
# tests/fly-image-cli-pin.bh-9911-test.sh — BH-9911: bin/fly-image-build.sh bakes
# the pinned claude version (settings row claude_cli.pinned_version) into the
# pool image when claude_cli.pin.enabled=1. The real script runs with a stub
# fly (records the deploy argv) and a stub curl that serves the settings rows.
#
#   F1 pin on, pinned row 2.1.340 -> --build-arg CLAUDE_CODE_VERSION=2.1.340
#      (not the cli.claude_code.version row 2.1.280)
#   F2 pin on, no pinned row -> the fallback 2.1.330
#   F3 pin off -> cli.claude_code.version, as before (2.1.280)
#   F4 the knob unreadable after an on read -> FATAL, rc 1, fly deploy never runs
#   F5 the knob unreadable and never read on -> builds as before (no FATAL)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-image-cli-pin.bh-9911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/fly" <<'STUB'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo "[{\"Name\":\"${STUB_APP:-builder-demo}\"}]" ;;
  "apps create") exit 0 ;;
  deploy*) echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
           echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"
printf '#!/bin/bash\nexit 0\n' > "$FB/npm"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.200 (Claude Code)"\n' > "$FB/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.150.0"\n' > "$FB/codex"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2 ;; *) shift ;; esac; done
[ -e "$ROWS/../down" ] && exit 7
case "$METHOD $URL" in
  "GET "*"/api/settings/bake."*) printf '{"setting":{"value":"1.0.0"}}\n200\n' ;;
  "GET "*"/api/settings/"*) k="${URL##*/api/settings/}"
    if [ -f "$ROWS/$k" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$(cat "$ROWS/$k")"; else printf '{}\n404\n'; fi ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB"/*

new_h() {
  H=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$H/state/fly" "$H/env" "$H/logs" "$H/flags" "$H/rows"
  printf 'HARNESS_SECRET=tok-fixture-bh9911\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  printf '2.1.280' > "$H/rows/cli.claude_code.version"
  printf '0.153.4' > "$H/rows/cli.codex.version"
}
build_run() { # build_run <project> -> OUT, RC, deploy args in $H/deploy-args
  : > "$H/deploy-args"
  OUT=$(env -i PATH="$FB:/usr/bin:/bin" HOME="$T" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org ROWS="$H/rows" \
        DEPLOY_ARGS_SINK="$H/deploy-args" STUB_APP="builder-$1" bash "$DIR/bin/fly-image-build.sh" "$1" 2>&1); RC=$?
}
arg() { grep -oE -- "--build-arg CLAUDE_CODE_VERSION=[^ ]*" "$H/deploy-args" | head -1 | cut -d= -f2; }

new_h; printf 1 > "$H/rows/claude_cli.pin.enabled"; printf 2.1.340 > "$H/rows/claude_cli.pinned_version"
build_run f1
[ "$RC" = 0 ] && [ "$(arg)" = 2.1.340 ] && ok || bad "F1 want CLAUDE_CODE_VERSION=2.1.340, got '$(arg)' rc $RC: $OUT"
[ "$(sed -n 's/^claude=//p' "$H/state/fly/f1.cli")" = 2.1.340 ] && ok || bad "F1 state/fly/f1.cli does not record the pin"

new_h; printf 1 > "$H/rows/claude_cli.pin.enabled"
build_run f2
[ "$RC" = 0 ] && [ "$(arg)" = 2.1.330 ] && ok || bad "F2 want the fallback 2.1.330, got '$(arg)' rc $RC: $OUT"

new_h; printf 0 > "$H/rows/claude_cli.pin.enabled"; printf 2.1.340 > "$H/rows/claude_cli.pinned_version"
build_run f3
[ "$RC" = 0 ] && [ "$(arg)" = 2.1.280 ] && ok || bad "F3 pin off: want 2.1.280, got '$(arg)' rc $RC: $OUT"

new_h; mkdir -p "$H/state/claude-cli-pin"; echo 1 > "$H/state/claude-cli-pin/pin-enabled"; : > "$H/down"
build_run f4
[ "$RC" = 1 ] && grep -q 'FATAL: claude CLI pin state unknown' <<<"$OUT" && ok || bad "F4 want FATAL rc 1, got rc $RC: $OUT"
[ -s "$H/deploy-args" ] && bad "F4 fly deploy ran: $(cat "$H/deploy-args")" || ok

new_h; : > "$H/down"
build_run f5
grep -q 'pin state unknown' <<<"$OUT" && bad "F5 an outage with no on read refused the build: $OUT" || ok
grep -q '== pinning image CLIs: claude=2.1.200 ' <<<"$OUT" && ok || bad "F5 outage, never on: want the host claude 2.1.200: $OUT"

echo "fly-image-cli-pin.bh-9911-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

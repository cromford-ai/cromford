#!/bin/bash
# tests/fly-image-cli-pin.bh-1517-test.sh — BH-1517: Fly builder images must
# pin their baked claude/codex CLI to the hub's current version, not to
# whatever `npm install -g ...@latest` resolved the day the Depot layer cache
# last missed. Found preparing #1507: every Fly builder ran Claude Code
# 2.1.267 for weeks (logs/fly-image-build.log: `#21 CACHED` on every nightly
# rebuild) while the hub moved on to 2.1.280, because the unpinned install RUN
# line in fly/Dockerfile never changed and so never busted the cache.
#
# What this pins:
#   A. bin/fly-image-build.sh resolves CLAUDE_CODE_VERSION/CODEX_VERSION
#      DB-first (setting_get cli.claude_code.version / cli.codex.version),
#      falls back to this host's own installed CLI when no row exists, and
#      REFUSES to build (never "latest") when neither source resolves. The
#      resolved versions reach `fly deploy` as --build-arg, and are recorded
#      to state/fly/<project>.cli next to the image ref.
#   B. fly/Dockerfile's pin-and-verify RUN block (extracted VERBATIM by its
#      `# >>> cli-pin-verify` / `# <<< cli-pin-verify` markers, never restated)
#      exits 0 when the installed CLI reports the pinned ARG and FATALs when
#      it reports something else.
#   C. bin/fly-image-refresh.sh records the baked versions as a
#      fly_image_cli.<project> settings row, and raises ONE ALERTS.log line
#      per project per UTC day when a builder is more than CLI_DRIFT_MAX_PATCH
#      patch versions behind the hub's cli.claude_code.version /
#      cli.codex.version — deduped so a stuck image does not page every night.
#   D. cli_patch_drift (bin/lib/cli-version.sh), the pure function the floor
#      check is built on.
#
# Run from anywhere: tests/fly-image-cli-pin.bh-1517-test.sh   (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ===========================================================================
# Shared fakebin: fly / gh / npm no-ops, plus curl (the jobs-client transport)
# and claude/codex whose --version this project's fixtures control per test.
# ===========================================================================
FB="$T/fakebin"
mkdir -p "$FB"
cat > "$FB/fly" <<'STUB'
#!/bin/bash
echo "$*" >> "${STUB_CALLS:-/dev/null}"
case "$1 ${2:-}" in
  "apps list")
    if [ -n "${STUB_APPS_JSON:-}" ] && [ -f "${STUB_APPS_JSON:-}" ]; then cat "$STUB_APPS_JSON"
    else echo '[]'; fi ;;
  "apps create") exit 0 ;;
  deploy*)
    echo "$*" >> "${DEPLOY_ARGS_SINK:-/dev/null}"
    echo "image: registry.fly.io/${STUB_APP:-builder-demo}:deployment-01TEST" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$FB/gh"          # no gh token => warm bake stays cold
printf '#!/bin/bash\nexit 0\n' > "$FB/npm"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  *"GET "*"/api/settings/cli.claude_code.version")
    if [ -n "${SETTING_CLAUDE:-}" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$SETTING_CLAUDE"
    else printf '{}\n404\n'; fi ;;
  # BH-1528: every bake.<name>.version row the build now also pins; one
  # value serves them all (these suites are about the CLI rows).
  *"GET "*"/api/settings/bake."*) printf '{"setting":{"value":"1.0.0"}}\n200\n' ;;
  *"GET "*"/api/settings/cli.codex.version")
    if [ -n "${SETTING_CODEX:-}" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$SETTING_CODEX"
    else printf '{}\n404\n'; fi ;;
  *"PUT "*"/api/settings")
    printf '{"accepted":1}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB"/*

# claude/codex stubs: written per-test so the version they report varies.
stub_cli() { # stub_cli <name> <version-or-empty-for-not-installed>
  local name="$1" v="${2:-}"
  # Empty version = "not installed": write a stub that prints nothing and
  # exits 127. Deleting the stub let a real CLI later on the inherited PATH
  # (/usr/local/bin/claude on every build box) answer instead, so A3 went red
  # on build boxes only (BH-9985). The stub must shadow it.
  if [ -z "$v" ]; then printf '#!/bin/bash\nexit 127\n' > "$FB/$name"; chmod +x "$FB/$name"; return; fi
  case "$name" in
    claude) printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s (Claude Code)"\n' "$v" > "$FB/$name" ;;
    codex)  printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli %s"\n' "$v" > "$FB/$name" ;;
  esac
  chmod +x "$FB/$name"
}

new_h() { # new_h -> a scratch $HARNESS with jobs-client + its modules + cli-version, real bytes
  local h; h=$(mktemp -d "$T/h-XXXXXX")
  mkdir -p "$h/bin/lib/jobs" "$h/state/fly" "$h/env" "$h/logs" "$h/flags"
  cp "$DIR/bin/jobs-client.sh" "$h/bin/jobs-client.sh"
  cp "$DIR"/bin/lib/jobs/*.sh "$h/bin/lib/jobs/"
  cp "$DIR/bin/lib/cli-version.sh" "$h/bin/lib/cli-version.sh"
  cp "$DIR/bin/alert-line.sh" "$h/bin/alert-line.sh"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$h/env/global.env"
  echo "$h"
}

# ===========================================================================
# A. bin/fly-image-build.sh — version resolution + build-arg plumbing
# ===========================================================================
build_run() { # build_run <project> [env...] — runs the REAL script; sets RC, OUT
  local proj="$1"; shift
  : > "$T/deploy-args"; : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" HARNESS="$H" WARM_BAKE=0 FLY_ORG=stub-org \
        DEPLOY_ARGS_SINK="$T/deploy-args" REQ_SINK="$T/req.log" STUB_APP="builder-$proj" \
        "$@" bash "$DIR/bin/fly-image-build.sh" "$proj" 2>&1); RC=$?
}

# A1. DB-first: both settings rows present -> exact pinned values reach `fly
# deploy`, never "latest", and are recorded next to the image ref.
H=$(new_h)
SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
build_run demo1 SETTING_CLAUDE="$SETTING_CLAUDE" SETTING_CODEX="$SETTING_CODEX"
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC: $OUT"
grep -q -- '--build-arg CLAUDE_CODE_VERSION=2.1.280' "$T/deploy-args" && ok \
  || bad "A1: pinned claude version did not reach fly deploy: $(cat "$T/deploy-args" 2>/dev/null)"
grep -q -- '--build-arg CODEX_VERSION=0.153.4' "$T/deploy-args" && ok \
  || bad "A1: pinned codex version did not reach fly deploy: $(cat "$T/deploy-args" 2>/dev/null)"
grep -q -- '@latest' "$T/deploy-args" && bad "A1: an unpinned @latest arg reached fly deploy" || ok
[ "$(cat "$H/state/fly/demo1.cli" 2>/dev/null)" = "$(printf 'claude=2.1.280\ncodex=0.153.4')" ] && ok \
  || bad "A1: state/fly/demo1.cli not recorded: $(cat "$H/state/fly/demo1.cli" 2>/dev/null)"

# A2. No settings rows -> falls back to THIS host's own installed CLI, never
# "latest"; a log line says so.
H=$(new_h)
stub_cli claude 2.1.200; stub_cli codex 0.150.0
build_run demo2
[ "$RC" = 0 ] && ok || bad "A2: rc=$RC: $OUT"
grep -q -- '--build-arg CLAUDE_CODE_VERSION=2.1.200' "$T/deploy-args" && ok \
  || bad "A2: fallback claude version did not reach fly deploy: $(cat "$T/deploy-args" 2>/dev/null)"
grep -q -- '--build-arg CODEX_VERSION=0.150.0' "$T/deploy-args" && ok \
  || bad "A2: fallback codex version did not reach fly deploy: $(cat "$T/deploy-args" 2>/dev/null)"
grep -q 'falling back' <<<"$OUT" && ok || bad "A2: no fallback line: $OUT"
grep -q -- '@latest' "$T/deploy-args" && bad "A2: an unpinned @latest arg reached fly deploy" || ok

# A3. No settings rows AND no installed CLI -> FATAL, build never invoked.
H=$(new_h)
stub_cli claude ""; stub_cli codex ""
build_run demo3
[ "$RC" != 0 ] && ok || bad "A3: an unpinned build must refuse (rc=$RC)"
grep -qi 'FATAL' <<<"$OUT" && ok || bad "A3: no FATAL: $OUT"
[ -s "$T/deploy-args" ] && bad "A3: fly deploy ran with nothing pinned: $(cat "$T/deploy-args")" || ok
[ -f "$H/state/fly/demo3.cli" ] && bad "A3: state/fly/demo3.cli written despite the refusal" || ok

# A4. Mixed: claude from the DB, codex from the fallback (independent per CLI).
H=$(new_h)
stub_cli claude ""; stub_cli codex 0.140.0
build_run demo4 SETTING_CLAUDE=2.1.279
[ "$RC" = 0 ] && ok || bad "A4: rc=$RC: $OUT"
grep -q -- '--build-arg CLAUDE_CODE_VERSION=2.1.279' "$T/deploy-args" && ok || bad "A4: DB claude version missing: $(cat "$T/deploy-args")"
grep -q -- '--build-arg CODEX_VERSION=0.140.0' "$T/deploy-args" && ok || bad "A4: fallback codex version missing: $(cat "$T/deploy-args")"

# ===========================================================================
# B. fly/Dockerfile's pin-and-verify RUN block, extracted verbatim
# ===========================================================================
extract() { # extract <file> <marker>
  awk -v m="$1" '
    $0 ~ "^# >>> " m "$" { f=1; next }
    $0 ~ "^# <<< " m "$" { f=0 }
    f { print }
  ' "$2"
}
SNIPPET="$T/cli-pin-verify.sh"
extract cli-pin-verify "$DIR/fly/Dockerfile" | sed '1s/^RUN //' > "$SNIPPET"
[ -s "$SNIPPET" ] && ok || bad "B0: the cli-pin-verify block extracted empty — markers moved?"
grep -q 'npm install' "$SNIPPET" && ok || bad "B0: extracted block does not look like the install RUN"

DFB="$T/dockerbin"; mkdir -p "$DFB"
printf '#!/bin/bash\nexit 0\n' > "$DFB/npm"; chmod +x "$DFB/npm"

# B1. Installed CLIs report exactly the pinned ARGs -> exits 0.
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$DFB/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$DFB/codex"
chmod +x "$DFB/claude" "$DFB/codex"
OUT=$(env -i PATH="$DFB:$PATH" CLAUDE_CODE_VERSION=2.1.280 CODEX_VERSION=0.153.4 bash "$SNIPPET" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B1: a matching install must exit 0 (rc=$RC): $OUT"

# B2. claude reports a DIFFERENT version than the pinned ARG -> FATAL, nonzero.
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.261 (Claude Code)"\n' > "$DFB/claude"
chmod +x "$DFB/claude"
OUT=$(env -i PATH="$DFB:$PATH" CLAUDE_CODE_VERSION=2.1.280 CODEX_VERSION=0.153.4 bash "$SNIPPET" 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "B2: a version mismatch must fail the build (rc=$RC)"
grep -qi 'FATAL: claude --version reports 2.1.261, expected 2.1.280' <<<"$OUT" && ok || bad "B2: no FATAL line: $OUT"

# B3. codex reports a different version -> FATAL, nonzero (claude restored ok).
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$DFB/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.140.0"\n' > "$DFB/codex"
chmod +x "$DFB/claude" "$DFB/codex"
OUT=$(env -i PATH="$DFB:$PATH" CLAUDE_CODE_VERSION=2.1.280 CODEX_VERSION=0.153.4 bash "$SNIPPET" 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "B3: a codex version mismatch must fail the build (rc=$RC)"
grep -qi 'FATAL: codex --version reports 0.140.0, expected 0.153.4' <<<"$OUT" && ok || bad "B3: no FATAL line: $OUT"

# B4. Empty ARGs (a caller bug) -> FATAL, never silently installs "latest".
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$DFB/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$DFB/codex"
chmod +x "$DFB/claude" "$DFB/codex"
OUT=$(env -i PATH="$DFB:$PATH" bash "$SNIPPET" 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "B4: empty build args must fail (rc=$RC)"
grep -qi 'FATAL: CLAUDE_CODE_VERSION and CODEX_VERSION build args are required' <<<"$OUT" && ok || bad "B4: no FATAL line: $OUT"

# ===========================================================================
# C. bin/fly-image-refresh.sh — records baked versions + the drift floor
# ===========================================================================
stub_builder() { # stub_builder <h> <claude-baked> <codex-baked> [rc]
  local h="$1" cv="$2" xv="$3" rc="${4:-0}"
  cat > "$h/bin/fly-image-build.sh" <<STUB
#!/bin/bash
P="\$1"
echo "image: registry.fly.io/builder-\$P:deployment-STUBTAG"
mkdir -p "$h/state/fly"
printf 'claude=%s\ncodex=%s\n' "$cv" "$xv" > "$h/state/fly/\$P.cli"
exit "$rc"
STUB
  chmod +x "$h/bin/fly-image-build.sh"
}
refresh_run() { # refresh_run <h> [env...]
  local h="$1"; shift
  : > "$T/req.log"
  OUT=$(env -i PATH="$FB:$PATH" HOME="$T" HARNESS="$h" REQ_SINK="$T/req.log" "$@" \
        bash "$DIR/bin/fly-image-refresh.sh" 2>&1); RC=$?
}

# C1. A rebuild's baked versions are recorded as fly_image_cli.<project> (gated
# on machines_rows_on, same convention as the existing fly_image.<project> row).
H=$(new_h); : > "$H/flags/fly-pool-democ1"
stub_builder "$H" 2.1.280 0.153.4
refresh_run "$H" FLY_MACHINES_ROWS=on
[ "$RC" = 0 ] && ok || bad "C1: rc=$RC: $OUT"
grep -q 'PUT .*/api/settings' "$T/req.log" || bad "C1: no settings PUT at all: $(cat "$T/req.log")"
grep -q '"key":"fly_image_cli.democ1"' "$T/req.log" && ok || bad "C1: fly_image_cli.democ1 row not written: $(cat "$T/req.log")"
grep 'fly_image_cli.democ1' "$T/req.log" | grep -q '"value":"claude=2.1.280 codex=0.153.4"' && ok \
  || bad "C1: fly_image_cli.democ1 value wrong: $(grep fly_image_cli "$T/req.log")"

# C2. Drift beyond CLI_DRIFT_MAX_PATCH -> exactly ONE ALERTS.log line, even
# across two runs the same UTC day (the per-project-per-day dedupe).
H=$(new_h); : > "$H/flags/fly-pool-democ2"
stub_builder "$H" 2.1.270 0.150.0   # baked, stale
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$(grep -c 'democ2' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "C2: expected exactly one drift alert after run 1: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ "$(grep -c 'democ2' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "C2: a second same-day run must not duplicate the alert: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep 'democ2' "$H/logs/ALERTS.log" | grep -q 'claude baked=2.1.270 hub=2.1.280' && ok \
  || bad "C2: alert line missing the claude drift detail: $(grep democ2 "$H/logs/ALERTS.log")"

# C3. Within the floor -> no alert at all.
H=$(new_h); : > "$H/flags/fly-pool-democ3"
stub_builder "$H" 2.1.278 0.153.4
refresh_run "$H" CLI_DRIFT_MAX_PATCH=3 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
[ -f "$H/logs/ALERTS.log" ] && grep -q 'democ3' "$H/logs/ALERTS.log" && bad "C3: a 2-patch drift under a floor of 3 must not alert: $(cat "$H/logs/ALERTS.log")" || ok

# C4. A major/minor mismatch (e.g. the row is stale from a previous release)
# always trips the floor, however small CLI_DRIFT_MAX_PATCH's patch tolerance.
H=$(new_h); : > "$H/flags/fly-pool-democ4"
stub_builder "$H" 1.9.0 0.153.4
refresh_run "$H" CLI_DRIFT_MAX_PATCH=1000 SETTING_CLAUDE=2.1.280 SETTING_CODEX=0.153.4
grep -q 'democ4' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "C4: a major/minor mismatch must always alert regardless of the patch floor"

# ===========================================================================
# D. cli_patch_drift — the pure function the floor check is built on
# ===========================================================================
# shellcheck source=bin/lib/cli-version.sh
. "$DIR/bin/lib/cli-version.sh"
[ "$(cli_patch_drift 2.1.280 2.1.280)" = 0 ] && ok || bad "D: identical -> 0"
[ "$(cli_patch_drift 2.1.267 2.1.280)" = 13 ] && ok || bad "D: same major.minor -> patch delta"
[ "$(cli_patch_drift 2.1.280 2.1.267)" -lt 0 ] && ok || bad "D: baked AHEAD of hub -> negative, never a drift"
[ "$(cli_patch_drift missing 2.1.280)" = 999999 ] && ok || bad "D: missing baked -> sentinel"
[ "$(cli_patch_drift 1.9.0 2.1.280)" = 999999 ] && ok || bad "D: major.minor mismatch -> sentinel"
[ "$(cli_patch_drift 2.1.280 '')" = 0 ] && ok || bad "D: no hub version known -> 0 (nothing to compare)"

echo "fly-image-cli-pin.bh-1517-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

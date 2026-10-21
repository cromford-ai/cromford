#!/bin/bash
# tests/fly-pool-secrets-sync.bh-7430-test.sh — BH-7430: bin/fly-pool-secrets-sync.sh,
# the operator verb that puts the pool's static env bundle in the pool app's
# Fly secrets (HBUNDLE_*), so a pull-path spawn never ssh-es to the owning box.
#
# DRIVEN: the real verb and the real bin/fly-envbundle.sh run against a scratch
# $HARNESS; ssh (the owning box) and fly are counting stubs.
# PINNED:
#   S1  the import stdin: HBUNDLE_G_<KEY> / HBUNDLE_P_<KEY>, values verbatim,
#       the marker HBUNDLE_SYNCED_AT, one `secrets import --stage -a <app>`
#   S2  GH_TOKEN and GH_TOKEN_INSTALLATION_ID are not synced
#   S3  a stale HBUNDLE_* name on the app is unset (--stage); no stale, no unset
#   S4  --dry-run prints names only, never a value, and imports nothing
#   S5  a bundler failure imports nothing and writes ONE alert naming the app
#   S6  a failed import alerts once; no temp dir survives any run
# Run from anywhere: bash tests/fly-pool-secrets-sync.bh-7430-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/state/fly" "$H/flags" "$T/fakebin" "$T/flybin" "$T/tmp"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fly-envbundle.sh" "$H/bin/"
scratch_install_closure bin/fly-pool-secrets-sync.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
cat > "$H/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
EOF
# The owning box's bundle (what the real extractor prints).
cat > "$T/fakebin/ssh" <<'SSH'
#!/bin/bash
echo "ssh" >> "$SSH_SINK"
[ "${BOX_DOWN:-0}" = 1 ] && exit 255
printf '===GLOBAL===\n'
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude\nHARNESS_SECRET=fixture-secret\nRUNNER_NOTE=a b=c $d\n'
printf 'RUNNER_HASH=say "hi" # not a comment, tail\n'
[ "${QUOTE_BAD:-0}" = 1 ] && printf "RUNNER_BAD=it's\\n"
printf 'GH_TOKEN=fixture-pat\n'
printf '===PROJECT===\nBOARD_TOKEN=fixture-board\nGH_TOKEN_INSTALLATION_ID=99\n'
SSH
cat > "$T/flybin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "$FLY_SINK"
case "$*" in
  *"secrets list"*) printf '%s\n' "${FLY_LIST:-[]}" ;;
  *"secrets import"*) cat > "$IMPORT_SINK"; [ "${IMPORT_FAIL:-0}" = 1 ] && exit 1 ;;
  *"secrets unset"*) : ;;
esac
exit 0
FLY
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
chmod +x "$H/bin"/*.sh "$T/fakebin"/* "$T/flybin"/*
sync_run() { # sync_run [args] -- [VAR=val ...]
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  : > "$T/fly.txt"; : > "$T/import.txt"; : > "$T/ssh.txt"; : > "$T/alerts.txt"; rm -f "$T/import.txt"
  env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" \
      FLY_BIN_DIR="$T/flybin" FLY_SINK="$T/fly.txt" IMPORT_SINK="$T/import.txt" SSH_SINK="$T/ssh.txt" "$@" \
      bash "$DIR/bin/fly-pool-secrets-sync.sh" project-5 ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  echo $? > "$T/rc"
}
tmp_left() { find "$T/tmp" -mindepth 1 -maxdepth 1 | grep -c .; }

# ══ S1-S2: a good sync ═══════════════════════════════════════════════════════
sync_run
[ "$(cat "$T/rc")" = 0 ] && ok || bad "S1: rc 0, got $(cat "$T/rc"): $(cat "$T/out")"
[ "$(grep -c 'secrets import --stage -a pool-project-5' "$T/fly.txt")" = 1 ] && ok || bad "S1: one import --stage to pool-project-5: $(cat "$T/fly.txt")"
grep -qx 'HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN=fixture-claude' "$T/import.txt" && grep -qx 'HBUNDLE_G_HARNESS_SECRET=fixture-secret' "$T/import.txt" \
  && ok || bad "S1: the global lines as HBUNDLE_G_: $(cut -d= -f1 "$T/import.txt" | tr '\n' ' ')"
# `fly secrets import` parses dotenv: a value with a space, \$, # or a double quote
# is written in single quotes (literal in dotenv); the content is verbatim.
grep -qxF "HBUNDLE_G_RUNNER_NOTE='a b=c \$d'" "$T/import.txt" && ok || bad "S1: a value with spaces, = and \$ is single-quoted verbatim: $(grep RUNNER_NOTE "$T/import.txt")"
grep -qxF "HBUNDLE_G_RUNNER_HASH='say \"hi\" # not a comment, tail'" "$T/import.txt" && ok || bad "S1: a value with double quotes and # is single-quoted verbatim: $(grep RUNNER_HASH "$T/import.txt")"
grep -qx 'HBUNDLE_G_HARNESS_SECRET=fixture-secret' "$T/import.txt" && ok || bad "S1: a plain value is not quoted"
grep -qx 'HBUNDLE_P_BOARD_TOKEN=fixture-board' "$T/import.txt" && grep -qx 'HBUNDLE_P_REPO_SLUG=example-org/project-5' "$T/import.txt" \
  && ok || bad "S1: the project lines as HBUNDLE_P_ (REPO_SLUG included)"
grep -qE '^HBUNDLE_SYNCED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$T/import.txt" && ok || bad "S1: the marker HBUNDLE_SYNCED_AT=<UTC>"
[ "$(grep -c '^ssh' "$T/ssh.txt")" = 1 ] && ok || bad "S1: one box ssh, at operator time"
grep -q '^HBUNDLE_[GP]_GH_TOKEN=' "$T/import.txt" && bad "S2: GH_TOKEN must not be synced" || ok
grep -q '^HBUNDLE_[GP]_GH_TOKEN_INSTALLATION_ID=' "$T/import.txt" && bad "S2: GH_TOKEN_INSTALLATION_ID must not be synced" || ok
grep -q 'fixture' "$T/out" && bad "S1: no value on stdout/stderr: $(cat "$T/out")" || ok
grep -q 'secrets unset' "$T/fly.txt" && bad "S3: nothing stale, no unset" || ok
[ "$(tmp_left)" = 0 ] && ok || bad "S6: the temp dir must be removed: $(ls "$T/tmp")"
[ ! -s "$T/alerts.txt" ] && ok || bad "S1: a good sync alerts nothing"

# ══ S7: a value with a single quote cannot ride a dotenv import ═════════════
sync_run -- QUOTE_BAD=1
[ "$(cat "$T/rc")" = 1 ] && ok || bad "S7: rc 1 on an unquotable value"
grep -q 'secrets import' "$T/fly.txt" && bad "S7: nothing is imported" || ok
grep -q 'HBUNDLE_G_RUNNER_BAD' "$T/alerts.txt" && ok || bad "S7: the alert names the key: $(cat "$T/alerts.txt")"
grep -q "it's" "$T/alerts.txt" "$T/out" && bad "S7: the alert never carries the value" || ok
[ "$(tmp_left)" = 0 ] && ok || bad "S7: the temp dir is removed"

# ══ S3: a stale name is unset ════════════════════════════════════════════════
sync_run -- FLY_LIST='[{"Name":"HBUNDLE_G_OLD_KEY"},{"Name":"HBUNDLE_SYNCED_AT"},{"Name":"TS_AUTHKEY"}]'
grep -qx 'fly secrets unset --stage -a pool-project-5 HBUNDLE_G_OLD_KEY' "$T/fly.txt" && ok || bad "S3: the stale HBUNDLE name is unset, nothing else: $(cat "$T/fly.txt")"
IMP=$(grep -n 'secrets import' "$T/fly.txt" | cut -d: -f1); UNS=$(grep -n 'secrets unset' "$T/fly.txt" | cut -d: -f1)
[ -n "$IMP" ] && [ -n "$UNS" ] && [ "$IMP" -lt "$UNS" ] && ok || bad "S3: the import comes before the unset"

# ══ S4: --dry-run ════════════════════════════════════════════════════════════
sync_run --dry-run -- FLY_LIST='[{"Name":"HBUNDLE_G_OLD_KEY"}]'
[ "$(cat "$T/rc")" = 0 ] && ok || bad "S4: rc 0"
grep -q 'secrets import\|secrets unset' "$T/fly.txt" && bad "S4: a dry run changes nothing: $(cat "$T/fly.txt")" || ok
grep -q 'HBUNDLE_G_HARNESS_SECRET' "$T/out" && grep -q 'HBUNDLE_SYNCED_AT' "$T/out" && grep -q 'HBUNDLE_G_OLD_KEY' "$T/out" \
  && ok || bad "S4: the dry run names what it would import and unset: $(cat "$T/out")"
grep -q 'fixture\|=' "$T/out" && bad "S4: a dry run prints no value: $(cat "$T/out")" || ok
[ "$(tmp_left)" = 0 ] && ok || bad "S6: the dry run removes its temp dir"

# ══ S5: the bundler fails ════════════════════════════════════════════════════
sync_run -- BOX_DOWN=1
[ "$(cat "$T/rc")" = 1 ] && ok || bad "S5: rc 1 on a bundler failure"
grep -q 'secrets import' "$T/fly.txt" && bad "S5: nothing is imported" || ok
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && ok || bad "S5: ONE alert, got $(grep -c . "$T/alerts.txt")"
grep -q 'pool-project-5 FAILED at env bundle: ssh env extract from 192.0.2.9 failed' "$T/alerts.txt" && ok \
  || bad "S5: the alert names the app and the step: $(cat "$T/alerts.txt")"
[ "$(tmp_left)" = 0 ] && ok || bad "S6: the temp dir is removed on failure"

# ══ S6: the import fails ═════════════════════════════════════════════════════
sync_run -- IMPORT_FAIL=1
[ "$(cat "$T/rc")" = 1 ] && [ "$(grep -c . "$T/alerts.txt")" = 1 ] && grep -q 'FAILED at secrets import' "$T/alerts.txt" \
  && ok || bad "S6: a failed import is rc 1 and one alert: $(cat "$T/alerts.txt")"
[ "$(tmp_left)" = 0 ] && ok || bad "S6: the temp dir is removed after a failed import"
# No app record: rc 1, one alert, no fly call.
mv "$H/state/fly/project-5.json" "$T/app.json"
sync_run
[ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/fly.txt" ] && grep -q 'FAILED at app lookup' "$T/alerts.txt" && ok \
  || bad "S6: no app record: rc 1, no fly call, one alert: $(cat "$T/alerts.txt")"
mv "$T/app.json" "$H/state/fly/project-5.json"
# A bad argument.
sync_run --force
[ "$(cat "$T/rc")" = 2 ] && [ ! -s "$T/fly.txt" ] && ok || bad "S6: an unknown flag is rc 2 and does nothing"

echo "fly-pool-secrets-sync (BH-7430): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

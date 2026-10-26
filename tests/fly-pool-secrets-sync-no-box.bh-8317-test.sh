#!/bin/bash
# tests/fly-pool-secrets-sync-no-box.bh-8317-test.sh — BH-8317 (MKF-2):
# `bin/fly-pool-secrets-sync.sh <project> --no-box` rewrites the pool app's
# HBUNDLE_G_* from the HUB's own global.env, through the one fly-envbundle
# whitelist (`bin/fly-envbundle.sh --hub-global`), and never touches an
# HBUNDLE_P_* secret. It makes 0 ssh calls and 0 gh-token calls.
#
# DRIVEN: the real sync and the real bin/fly-envbundle.sh against a scratch
# $HARNESS, under env -i, on a PATH of stubs plus links to local tools only.
# PINNED:
#   N1 0 ssh, 0 gh-token.sh; the import holds the whitelisted G lines and the
#      marker, no HBUNDLE_P_ line, no TELEGRAM_/ORGO_/FLY_ line, and not the
#      hub's env/<project>.env value
#   N2 stale unset is exactly the stale HBUNDLE_G_* names (never HBUNDLE_P_*,
#      HBUNDLE_SYNCED_AT, HBUNDLE_GX or a non-HBUNDLE secret)
#   N3 settings row pool.envbundle_ssh.<p>=off does not block --no-box
#   N4 --no-box --dry-run in either order: names only, 0 import; unknown flag rc 2
#   N5 no HBUNDLE_P_* on the app: rc 0 and one WARN naming project-secrets.sh import
#   N-B1 budget: no real network tool is reachable; 0 ssh, 0 gh calls
# Each case resets its own capture dir; no order dependence.
# Run from anywhere: bash tests/fly-pool-secrets-sync-no-box.bh-8317-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

P=project-6-os
POOL=pool-project-6-os
H="$T/h"; STUB="$T/stub"; TOOLS="$T/tools"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state/fly" "$STUB" "$TOOLS" "$T/tmp" "$T/home" "$T/nofly"
for s in bin/fly-pool-secrets-sync.sh bin/fly-envbundle.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
printf 'FLY_API_TOKEN_project-6_OS=tok-fixture-fly\n' > "$H/env/fly.env"
printf '{"app":"%s"}\n' "$POOL" > "$H/state/fly/$P.json"
# The hub's own env: whitelisted keys, hub-only keys, and a project env that
# must never leave in no-box mode.
cat > "$H/env/global.env" <<'EOF'
CLAUDE_CODE_OAUTH_TOKEN=fixture-hub-claude
HARNESS_SECRET=fixture-hub-secret
RUNNER_X=fixture-runner
TELEGRAM_BOT_TOKEN=fixture-hub-telegram
ORGO_API_KEY=fixture-hub-orgo
FLY_API_TOKEN=fixture-hub-fly
GH_TOKEN=fixture-hub-pat
EOF
printf 'QA_CLERK_SECRET_KEY=fixture-hub-qa\n' > "$H/env/$P.env"
# Counting stubs: the owning-box lookup and the PAT mint must never run.
for s in fleet-conf.sh gh-token.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.calls"\necho 192.0.2.10\n' "$s" "$T" > "$H/bin/$s"
done
cat > "$H/bin/alert-line.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CAP/alerts.txt"
EOF

for b in bash sh jq awk grep sed cut sort comm tr mktemp rm cat date head tail chmod mkdir find wc env \
         dirname basename tee touch stat id ls uniq mv cp ln sleep true false expr xargs od readlink tac printf; do
  p=$(command -v "$b" 2>/dev/null) && case "$p" in /*) ln -sf "$p" "$TOOLS/$b" ;; esac
done
cat > "$STUB/fly" <<'EOF'
#!/bin/bash
echo "fly $*" >> "$CAP/fly.argv"
case "$*" in
  *"secrets list"*) printf '%s\n' "${FLY_LIST:-[]}" ;;
  *"secrets import"*) cat > "$CAP/import.txt" ;;
esac
exit 0
EOF
cp "$STUB/fly" "$STUB/flyctl"
for s in ssh gh curl; do printf '#!/bin/bash\necho "%s $*" >> "%s/net.calls"\nexit 7\n' "$s" "$T" > "$STUB/$s"; done
printf '#!/bin/bash\nshift; exec "$@"\n' > "$STUB/timeout"
chmod +x "$STUB"/* "$H/bin"/*.sh
: > "$T/net.calls"

reset() { CAP="$T/cap"; scratch_rm "$CAP"; mkdir -p "$CAP"; : > "$CAP/fly.argv"; : > "$CAP/alerts.txt"; rm -f "$H/state/settings-cache.json"; }
run() { # run <args...> [-- VAR=val ...]
  local args=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  env -i PATH="$STUB:$TOOLS" HOME="$T/home" HARNESS="$H" TMPDIR="$T/tmp" CAP="$CAP" \
    FLY_BIN_DIR="$T/nofly" "$@" \
    bash "$DIR/bin/fly-pool-secrets-sync.sh" "$P" "${args[@]}" > "$CAP/out" 2> "$CAP/err"
  RC=$?; OUT=$(cat "$CAP/out"); ERR=$(cat "$CAP/err")
}
tmp_clean() { [ -z "$(find "$T/tmp" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; }
WITH_P='[{"Name":"HBUNDLE_P_BOARD_TOKEN"},{"Name":"HBUNDLE_SYNCED_AT"}]'

# ══ N1 a no-box sync ═════════════════════════════════════════════════════════
reset; : > "$T/net.calls"
run --no-box -- FLY_LIST="$WITH_P"
[ "$RC" = 0 ] && ok || bad "N1: rc 0, got $RC: $ERR"
[ ! -s "$T/net.calls" ] && ok || bad "N1: 0 ssh, 0 gh-token, 0 owning-box lookups: $(cat "$T/net.calls")"
[ "$(grep -c "secrets import --stage -a $POOL" "$CAP/fly.argv")" = 1 ] && ok || bad "N1: one import --stage: $(cat "$CAP/fly.argv")"
grep -qx 'HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN=fixture-hub-claude' "$CAP/import.txt" 2>/dev/null && ok || bad "N1: the hub's CLAUDE_CODE_OAUTH_TOKEN as HBUNDLE_G_: $(cut -d= -f1 "$CAP/import.txt" 2>/dev/null | tr '\n' ' ')"
grep -qx 'HBUNDLE_G_RUNNER_X=fixture-runner' "$CAP/import.txt" 2>/dev/null && grep -qx 'HBUNDLE_G_HARNESS_SECRET=fixture-hub-secret' "$CAP/import.txt" 2>/dev/null && ok || bad "N1: RUNNER_* and HARNESS_SECRET ride"
grep -qE '^HBUNDLE_SYNCED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$CAP/import.txt" 2>/dev/null && ok || bad "N1: the marker"
grep -q '^HBUNDLE_P_' "$CAP/import.txt" 2>/dev/null && bad "N1: no HBUNDLE_P_ line in a no-box import" || ok
grep -qE 'TELEGRAM_|ORGO_API_KEY|FLY_|GH_TOKEN' "$CAP/import.txt" 2>/dev/null && bad "N1: no hub-only key leaves: $(cut -d= -f1 "$CAP/import.txt")" || ok
grep -rq 'fixture-hub-qa' "$CAP" && bad "N1: the hub's project env never leaves in no-box mode" || ok
grep -q 'fixture' <<<"$OUT$ERR" && bad "N1: no value on stdout/stderr" || ok
grep -q 'secrets unset' "$CAP/fly.argv" && bad "N1: nothing stale, no unset" || ok
grep -q 'no-box' <<<"$OUT" && ok || bad "N1: the summary says no-box: $OUT"
grep -q 'WARN' <<<"$ERR" && bad "N1: the app has HBUNDLE_P_*, so no WARN: $ERR" || ok
tmp_clean && ok || bad "N1: the temp dir is removed"

# ══ N2 the stale set is only HBUNDLE_G_* ═════════════════════════════════════
reset
run --no-box -- FLY_LIST='[{"Name":"HBUNDLE_G_OLD"},{"Name":"HBUNDLE_P_BOARD_TOKEN"},{"Name":"HBUNDLE_SYNCED_AT"},{"Name":"HBUNDLE_GX"},{"Name":"HARNESS_SECRET"},{"Name":"HBUNDLE_G_RUNNER_X"}]'
[ "$RC" = 0 ] && ok || bad "N2: rc 0, got $RC: $ERR"
grep -qx "fly secrets unset --stage -a $POOL HBUNDLE_G_OLD" "$CAP/fly.argv" && ok || bad "N2: the unset argv is exactly HBUNDLE_G_OLD: $(grep unset "$CAP/fly.argv")"
[ "$(grep -c 'secrets unset' "$CAP/fly.argv")" = 1 ] && ok || bad "N2: one unset call"

# ══ N3 the BH-8316 ssh-off row does not block --no-box ═══════════════════════
reset
jq -nc '{fetched_at: 1761400000, values: {"pool.envbundle_ssh.project-6-os": "off"}}' > "$H/state/settings-cache.json"
run --no-box -- FLY_LIST="$WITH_P" LANE_GATE_NOW=1761400000
[ "$RC" = 0 ] && [ ! -s "$T/net.calls" ] && [ ! -s "$CAP/alerts.txt" ] && ok || bad "N3: row off, --no-box still rc 0, 0 ssh, no alert: rc $RC $ERR"
rm -f "$H/state/settings-cache.json"

# ══ N4 --dry-run in either order; an unknown flag ════════════════════════════
for order in "--no-box --dry-run" "--dry-run --no-box"; do
  reset
  # shellcheck disable=SC2086 # two flags on purpose
  run $order -- FLY_LIST='[{"Name":"HBUNDLE_G_OLD"},{"Name":"HBUNDLE_P_BOARD_TOKEN"}]'
  [ "$RC" = 0 ] && ok || bad "N4 ($order): rc 0, got $RC: $ERR"
  grep -q 'secrets import\|secrets unset' "$CAP/fly.argv" && bad "N4 ($order): a dry run changes nothing" || ok
  grep -q 'HBUNDLE_G_CLAUDE_CODE_OAUTH_TOKEN' <<<"$OUT" && grep -q 'HBUNDLE_G_OLD' <<<"$OUT" && ok || bad "N4 ($order): names what it would import and unset: $OUT"
  grep -q 'HBUNDLE_P_BOARD_TOKEN' <<<"$OUT" && bad "N4 ($order): never lists an HBUNDLE_P_ name to unset" || ok
  grep -q 'fixture\|=' <<<"$OUT" && bad "N4 ($order): names only, no value" || ok
done
reset; run --no-box --force
[ "$RC" = 2 ] && [ ! -s "$CAP/fly.argv" ] && ok || bad "N4: an unknown flag is rc 2 and does nothing"
reset; run --no-box --dry-run --no-box
[ "$RC" = 2 ] && ok || bad "N4: a third argument is rc 2"

# ══ N5 no HBUNDLE_P_* yet: rc 0 and one WARN ════════════════════════════════
reset
run --no-box -- FLY_LIST='[{"Name":"HBUNDLE_G_RUNNER_X"}]'
[ "$RC" = 0 ] && [ "$(grep -c 'WARN' <<<"$ERR")" = 1 ] && grep -q "project-secrets.sh import $P" <<<"$ERR" && ok || bad "N5: rc 0 and one WARN naming project-secrets.sh import: rc $RC $ERR"

# ══ N-B1 budget ══════════════════════════════════════════════════════════════
for c in curl ssh fly flyctl gh wget nc; do
  w=$(env -i PATH="$STUB:$TOOLS" bash -c "command -v $c" 2>/dev/null)
  case "$w" in ''|"$T"/*) ok ;; *) bad "N-B1: $c resolves outside the scratch dir: $w" ;; esac
done
[ ! -s "$T/net.calls" ] && ok || bad "N-B1: 0 ssh, gh or curl calls over the suite: $(cat "$T/net.calls")"

echo "fly-pool-secrets-sync-no-box (BH-8317): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

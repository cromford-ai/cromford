#!/bin/bash
# tests/harness-sync-mcp.bh-8748-test.sh — bin/harness-sync.sh copies mcp/ to
# the live tree (BH-8748).
#
# WHY. The unblock lane's queue collector runs the batch_failure MCP tool from
# $HARNESS/mcp/tools/batch-failure.mjs (ubq_batch_failure). harness-sync never
# copied mcp/, so the hub had no such file, every red merge batch was read as
# queue-unreadable, and the Tackler sent 99 cards with no cause.
#
#   S0  safety probe: a dirty checkout refuses at rc 30.
#   M1  after one sync, $T/mcp/tools/batch-failure.mjs exists and equals the
#       checkout copy.
#   M2  a stale $T/mcp/tools/old.mjs is removed; $T/mcp/node_modules/x stays;
#       `diff -r -x node_modules` checkout vs live is empty.
#   M3  a checkout with no mcp/ dir: sync rc 0, no rsync error in
#       update-runners.log.
#
# Drives bin/harness-sync.sh against a scratch $HARNESS and a real bare origin
# + clone (the tests/harness-sync-sha-var.bh-6813-test.sh pattern).
# Run from anywhere: tests/harness-sync-mcp.bh-8748-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
command -v git >/dev/null && command -v flock >/dev/null && command -v rsync >/dev/null \
  || { echo "harness-sync-mcp.bh-8748-test: SKIPPED — git/flock/rsync missing"; exit 0; }

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$T/env/cloudflare.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/npx"
chmod +x "$T/fakebin/npx"

git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" "$T/ck/mcp/tools" "$T/ck/mcp/lib"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
cp "$DIR/mcp/tools/batch-failure.mjs" "$T/ck/mcp/tools/batch-failure.mjs"
cp "$DIR/mcp/lib/config.mjs" "$T/ck/mcp/lib/config.mjs"
cp "$DIR/mcp/package.json" "$T/ck/mcp/package.json"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
push() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }

# ── S0. SAFETY PROBE: a dirty checkout must refuse at rc 30 into
#    $HARNESS/logs/ALERTS.log, or the sync below would rsync this fixture over
#    the live /root/harness. ─────────────────────────────────────────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path."
  echo "harness-sync-mcp.bh-8748-test: 0 passed, 1 failed"
  exit 1
fi
ok "S0 dirty checkout refuses at rc 30"
git -C "$T/ck" checkout -q -- bin/x.sh
: > "$ALERTS"

# ── M1 ──────────────────────────────────────────────────────────────────────
sync
if [ "$RC" = 0 ] && [ -f "$T/mcp/tools/batch-failure.mjs" ] \
   && cmp -s "$T/ck/mcp/tools/batch-failure.mjs" "$T/mcp/tools/batch-failure.mjs"; then
  ok "M1 mcp/tools/batch-failure.mjs is live and equals the checkout copy"
else
  bad "M1 mcp/tools/batch-failure.mjs is live and equals the checkout copy (rc=$RC, $(ls "$T/mcp/tools" 2>&1 | head -c 200))"
fi

# ── M2 ──────────────────────────────────────────────────────────────────────
mkdir -p "$T/mcp/tools" "$T/mcp/node_modules"
printf 'stale\n' > "$T/mcp/tools/old.mjs"
printf 'dep\n' > "$T/mcp/node_modules/x"
printf '// touch\n' >> "$T/ck/mcp/lib/config.mjs"
push "M2 change"
sync
[ "$RC" = 0 ] && ok "M2 sync rc 0" || bad "M2 sync rc 0 (rc=$RC)"
[ ! -e "$T/mcp/tools/old.mjs" ] && ok "M2 stale mcp/tools/old.mjs removed" || bad "M2 stale mcp/tools/old.mjs removed"
[ -f "$T/mcp/node_modules/x" ] && ok "M2 mcp/node_modules/x kept" || bad "M2 mcp/node_modules/x kept"
if d=$(diff -r -x node_modules "$T/ck/mcp" "$T/mcp" 2>&1); then
  ok "M2 live mcp/ equals the checkout (node_modules aside)"
else
  bad "M2 live mcp/ equals the checkout (node_modules aside): $(head -c 300 <<< "$d")"
fi

# ── M3 ──────────────────────────────────────────────────────────────────────
git -C "$T/ck" rm -rq mcp
push "M3 no mcp"
: > "$ULOG"
sync
[ "$RC" = 0 ] && ok "M3 no mcp/ in the checkout: sync rc 0" || bad "M3 no mcp/ in the checkout: sync rc 0 (rc=$RC)"
if grep -qi 'rsync.*mcp\|mcp.*No such file' "$ULOG" "$T/err.txt" 2>/dev/null; then
  bad "M3 no rsync error for mcp/: $(grep -i 'mcp' "$ULOG" "$T/err.txt" | head -3)"
else
  ok "M3 no rsync error for mcp/"
fi

echo "harness-sync-mcp.bh-8748-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

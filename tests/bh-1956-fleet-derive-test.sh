#!/bin/bash
# tests/bh-1956-fleet-derive-test.sh — apply-migrations and board-invariants
# derive per-project facts from fleet.conf + the env file + the board response,
# not from a four-project table (BH-1956, items 15 and 17 of #232).
#
# WHY THIS EXISTS. apply-migrations.sh knew four projects by name and answered
# every other one with `*) NO_ENDPOINT`, which in cron mode is a silent exit 0:
# a fifth in-app board had a migration lane that never ran and never said so.
# board-invariants.sh derived a key-less ticket's key from a hardcoded KEYPFX
# map, so a board that SERVES its keyPrefix was ignored in favour of a table
# that did not list it. Both are driven here through the real scripts, with a
# fixture fleet.conf carrying a fifth in-app project (zeta-os), a GitHub-Issues
# row ("-" prefix), and the four originals, against stub curl and gh.
#
# Run from anywhere: tests/bh-1956-fleet-derive-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/fakebin"
# The production scripts, copied rather than symlinked so the lane gate and the
# wake backstop (which would call the settings worker) are not in the loop.
for f in apply-migrations.sh fleet-conf.sh board-invariants.sh internal-token-for.sh fleet-projects-or-alert.sh; do
  cp "$DIR/bin/$f" "$H/bin/$f"
done
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/internal-token.sh" "$H/bin/lib/"
: > "$H/env/global.env"

cat > "$T/fleet.conf" <<'EOF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [tailnet_ip]
project-1   Acme/project-1   https://project-1.example   /api/board                      2 bw-project-1
project-2 Acme/project-2 https://ta.example         /api/board                      4 bw-ta
project-3       Acme/project-3       https://project-3.example       /api/feature-board              6 bw-project-3
project-4       Acme/project-4       https://project-4.example       /api/accounting/requests-board  8 bw-project-4
zeta-os       Acme/zeta-os       https://zeta.example       /api/board                      1 bw-zeta
issues-only   Acme/issues-only   https://issues.example     -                               9 bw-issues
EOF

# curl logs every URL it is handed; the board endpoints answer from fixtures.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf '%s\n' "\$url" >> "$T/curl.log"
case "\$url" in
  */api/internal/migrations/status) echo '{"pending":[],"applied":[]}' ;;
  */boards) cat "$T/boards.json" ;;
  */boards/*/tickets) cat "$T/tickets.json" ;;
esac
exit 0
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"--state open"*) cat "$T/open-prs.json" ;;
  *) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# Hermetic: nothing from the caller's environment (a real *_APP_BASE, a real
# HARNESS_ENV_DIR) can leak into the scripts under test.
hrun() { env -i PATH="$T/fakebin:/usr/local/bin:/usr/bin:/bin" HOME="$T" HARNESS="$H" FLEET_CONF="$T/fleet.conf" "$@"; }
am() { hrun bash "$H/bin/apply-migrations.sh" "$@"; }
alerts() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null || true; }
reset() { : > "$T/curl.log"; : > "$H/logs/ALERTS.log"; rm -f "$H/state/apply-migrations-nobase-"*.stamp; }
migr_urls() { grep '/api/internal/migrations/' "$T/curl.log" 2>/dev/null || true; }

# --- 1. zeta-os with one app base resolves it generically ---------------------
reset
printf 'ZETA_APP_BASE=https://zeta.example.com\nMIGRATION_TOKEN=t\n' > "$H/env/zeta-os.env"
am zeta-os; RC=$?
[ "$RC" = 0 ] && ok || bad "1: zeta-os cron rc=$RC"
[ "$(migr_urls)" = "https://zeta.example.com/api/internal/migrations/status" ] && ok \
  || bad "1: zeta-os must GET its own base's status, curl saw: '$(migr_urls)'"
[ "$(alerts)" = 0 ] && ok || bad "1: a resolved base must not alert: $(cat "$H/logs/ALERTS.log")"

# --- 2. zeta-os with no base: one ALERTS line, deduped; --files stays rc 5 ----
reset
printf 'MIGRATION_TOKEN=t\n' > "$H/env/zeta-os.env"
am zeta-os; RC=$?
[ "$RC" = 0 ] && ok || bad "2: no-base cron must still exit 0 (rc=$RC)"
[ "$(alerts)" = 1 ] && ok || bad "2: no-base cron must write exactly one ALERTS line, got $(alerts)"
grep -q 'zeta-os.*no usable app base' "$H/logs/ALERTS.log" && ok || bad "2: ALERTS line must name zeta-os and 'no usable app base': $(cat "$H/logs/ALERTS.log")"
grep -q 'ambiguous' "$H/logs/ALERTS.log" && bad "2: a none case must not say ambiguous" || ok
grep -q 'MIGRATION_TOKEN=t\|=t\b' "$H/logs/ALERTS.log" && bad "2: ALERTS must never carry a value" || ok
[ -z "$(migr_urls)" ] && ok || bad "2: no base must mean no curl, saw '$(migr_urls)'"
am zeta-os; am zeta-os
[ "$(alerts)" = 1 ] && ok || bad "2: a repeat inside 24h must add no line, got $(alerts)"
reset
OUT=$(am zeta-os --files 2026-09-24-x.sql); RC=$?
[ "$RC" = 5 ] && ok || bad "2: --files with no base must exit 5 (rc=$RC)"
[ "$OUT" = '{"status":"no-endpoint"}' ] && ok || bad "2: --files must print no-endpoint, got '$OUT'"
[ "$(alerts)" = 0 ] && ok || bad "2: --files must not alert"

rm -f "$H/env/zeta-os.env"
am zeta-os; RC=$?
[ "$RC" = 0 ] && grep -q 'zeta-os.*env/zeta-os.env (the file is missing or unreadable)' "$H/logs/ALERTS.log" && ok \
  || bad "2: a missing env file must alert under its own reason (rc=$RC): $(cat "$H/logs/ALERTS.log")"

# --- 3. two base vars: ambiguous, never guessed ------------------------------
reset
printf 'ZETA_APP_BASE=https://a.example\nZETA_API_BASE=https://b.example\nMIGRATION_TOKEN=t\n' > "$H/env/zeta-os.env"
am zeta-os; RC=$?
[ "$RC" = 0 ] && ok || bad "3: ambiguous cron rc=$RC"
[ "$(alerts)" = 1 ] && ok || bad "3: ambiguous must write exactly one ALERTS line, got $(alerts)"
grep -q 'zeta-os.*ambiguous' "$H/logs/ALERTS.log" && ok || bad "3: ALERTS line must say ambiguous: $(cat "$H/logs/ALERTS.log")"
[ -z "$(migr_urls)" ] && ok || bad "3: ambiguous must not pick one and curl it, saw '$(migr_urls)'"

# --- 4. "-" prefix and unknown projects stay silent --------------------------
reset
printf 'ISSUES_APP_BASE=https://issues.example.com\nMIGRATION_TOKEN=t\n' > "$H/env/issues-only.env"
am issues-only; RC=$?
[ "$RC" = 0 ] && [ -z "$(migr_urls)" ] && [ "$(alerts)" = 0 ] && ok \
  || bad "4: a '-' prefix must stay silent (rc=$RC curl='$(migr_urls)' alerts=$(alerts))"
reset
printf 'NOSUCH_APP_BASE=https://nosuch.example.com\nMIGRATION_TOKEN=t\n' > "$H/env/nosuch-os.env"
am nosuch-os; RC=$?
[ "$RC" = 0 ] && [ -z "$(migr_urls)" ] && [ "$(alerts)" = 0 ] && ok \
  || bad "4: a project absent from fleet.conf must stay silent (rc=$RC curl='$(migr_urls)' alerts=$(alerts))"

# --- 5. the four originals resolve exactly what they did ---------------------
for pair in project-1:PROJECT_1_API_BASE project-2:PROJECT_2_APP_BASE project-3:PROJECT_3_APP_BASE project-4:PROJECT_4_API_BASE; do
  P=${pair%%:*}; V=${pair#*:}
  reset
  printf '%s=https://%s.legacy\nOTHER_APP_BASE=https://decoy.example.com\nMIGRATION_TOKEN=t\n' "$V" "$P" > "$H/env/$P.env"
  am "$P"; RC=$?
  [ "$RC" = 0 ] && [ "$(migr_urls)" = "https://$P.legacy/api/internal/migrations/status" ] && ok \
    || bad "5: $P must GET its legacy $V base, never the decoy (rc=$RC curl='$(migr_urls)')"
  # An empty legacy var stays the silent not-provisioned path, decoy or not.
  reset
  printf 'OTHER_APP_BASE=https://decoy.example.com\nMIGRATION_TOKEN=t\n' > "$H/env/$P.env"
  am "$P"; RC=$?
  [ "$RC" = 0 ] && [ -z "$(migr_urls)" ] && [ "$(alerts)" = 0 ] && ok \
    || bad "5: $P with no $V must stay silent (rc=$RC curl='$(migr_urls)' alerts=$(alerts))"
done

# --- 6. board-invariants: a served keyPrefix wins over the map ---------------
NOWISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bi() { hrun DRY=1 bash "$H/bin/board-invariants.sh" "$1"; }
printf 'ZT_INTERNAL_API_TOKEN=x\n' > "$H/env/zeta-os.env"
printf 'PROJECT_4_INTERNAL_API_TOKEN=x\n' > "$H/env/project-4.env"
printf '[{"number":7,"status":"done","lastActivityAt":"%s"}]\n' "$NOWISO" > "$T/tickets.json"

echo '[{"id":"b1","keyPrefix":"ZT"}]' > "$T/boards.json"
echo '[{"number":41,"url":"https://github.com/Acme/zeta-os/pull/41","headRefName":"ticket/zt-7"}]' > "$T/open-prs.json"
OUT=$(bi zeta-os)
grep -q '^DRY: zeta-os ZT-7 is DONE.*#41' <<<"$OUT" && ok || bad "6: a served keyPrefix ZT must name ZT-7, got '$OUT'"
echo '{"boards":[{"id":"b1","keyPrefix":"ZT"}]}' > "$T/boards.json"
OUT=$(bi zeta-os)
grep -q '^DRY: zeta-os ZT-7 is DONE' <<<"$OUT" && ok || bad "6: the {boards:[…]} shape must serve keyPrefix too, got '$OUT'"

echo '[{"id":"b1"}]' > "$T/boards.json"
echo '[{"number":42,"url":"https://github.com/Acme/project-4/pull/42","headRefName":"ticket/TK-7"}]' > "$T/open-prs.json"
OUT=$(bi project-4)
grep -q '^DRY: project-4 TK-7 is DONE.*#42' <<<"$OUT" && ok || bad "6: no keyPrefix must fall back to the map's AR, got '$OUT'"

echo '[{"id":"b1","keyPrefix":"ZT"}]' > "$T/boards.json"
printf '[{"key":"SRV-7","number":7,"status":"done","lastActivityAt":"%s"}]\n' "$NOWISO" > "$T/tickets.json"
echo '[{"number":43,"url":"u43","headRefName":"ticket/srv-7"},{"number":44,"url":"u44","headRefName":"ticket/zt-7"}]' > "$T/open-prs.json"
OUT=$(bi zeta-os)
grep -q '^DRY: zeta-os SRV-7 is DONE.*#43' <<<"$OUT" && ok || bad "6: a served .key must win, got '$OUT'"
grep -q 'ZT-7' <<<"$OUT" && bad "6: a served .key must not be overridden by keyPrefix, got '$OUT'" || ok

echo "bh-1956-fleet-derive: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

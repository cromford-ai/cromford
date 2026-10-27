#!/bin/bash
# tests/stale-owed-push-host.bh-8545-test.sh — THE STALE-OWED READY-QUEUE PUSH
# TARGETS THE FLEET.CONF TAILNET IP (BH-8545).
#
# bin/stale-owed-tickets.sh appends OWED-STALE lines to the owning box's
# logs/READY-QUEUE.log over ssh. It ssh'd `root@<box name>` (the variable was
# called IP but held bin/box-for.sh's box name), the same shape that froze the
# project-1 box's Vercel snapshot: a tailnet name that points at a dead device.
# The remote branch now resolves the host through bin/box-host.sh.
#
# Driven: the REAL lane script in project mode, with the REAL bin/box-for.sh,
# bin/box-host.sh and bin/fleet-conf.sh on a fixture fleet.conf. Stubs: `curl`
# (the board API: one board, one stale ticket), `ssh` (records argv + stdin,
# never connects), bin/internal-token-for.sh (a fixture token) and
# bin/fleet-projects-or-alert.sh (the fixture's board projects).
#
#   P1 box with IP 192.0.2.10 -> ssh got root@192.0.2.10, stdin held OWED-STALE
#   P2 box row with no IP     -> ssh got root@<box name>
#   P3 box `local`            -> no ssh; the line is in the scratch READY-QUEUE.log
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/stale-owed-push-host.bh-8545-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

FB="$T/fakebin"
mkdir -p "$FB"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$CURL_LOG"
case "$URL" in
  https://*.example.test/api/board/boards) echo '[{"id":"brd_fixture","keyPrefix":"FX"}]' ;;
  https://*.example.test/api/board/boards/brd_fixture/tickets)
    jq -nc --arg t "$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)" \
      '[{key:"FX-1", title:"fixture stale ticket", status:"todo", triageVerdict:"ready", waitingOn:"team", updatedAt:$t}]' ;;
  *) exit 7 ;;
esac
STUB
cat > "$FB/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
cat >> "$SSH_IN"
exit 0
STUB
chmod +x "$FB/curl" "$FB/ssh"

# sweep <case> <box> [ip] — a fresh scratch harness whose one project is on
# <box>, then one project-mode run of the real lane script.
sweep() {
  H="$T/$1"
  mkdir -p "$H/logs" "$H/flags" "$H/state" "$H/env" "$H/locks"
  scratch_install_closure bin/stale-owed-tickets.sh "$H" >/dev/null || bad "$1 setup: cannot install the lane script"
  scratch_install_closure bin/box-for.sh "$H" >/dev/null || bad "$1 setup: cannot install bin/box-for.sh"
  scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "$1 setup: cannot install bin/fleet-conf.sh"
  if [ -f "$DIR/bin/box-host.sh" ]; then
    scratch_install_closure bin/box-host.sh "$H" >/dev/null || bad "$1 setup: cannot install bin/box-host.sh"
  fi
  printf '#!/bin/sh\necho tok-fixture-1\n' > "$H/bin/internal-token-for.sh"
  printf '#!/bin/sh\nexec "$(dirname "$0")/fleet-conf.sh" --projects-with-board\n' > "$H/bin/fleet-projects-or-alert.sh"
  chmod +x "$H/bin/internal-token-for.sh" "$H/bin/fleet-projects-or-alert.sh"
  printf '# fixture fleet.conf (BH-8545)\nproj-fixture-a example-org/proj-fixture-a https://a.example.test /api/board 2 %s %s\n' "$2" "${3:-}" > "$H/fleet.conf"
  : > "$T/$1.ssh.log"; : > "$T/$1.ssh.in"; : > "$T/$1.curl.log"
  env PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" REGISTRY_SOURCE=file \
      LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/no-registry.json" JOBS_URL='' \
      CURL_LOG="$T/$1.curl.log" SSH_LOG="$T/$1.ssh.log" SSH_IN="$T/$1.ssh.in" \
      bash "$H/bin/stale-owed-tickets.sh" proj-fixture-a >"$T/$1.out" 2>&1
  RC=$?
}

# ---------- P1: the box's tailnet IP --------------------------------------------
sweep P1 box-fixture-dead 192.0.2.10
[ "$RC" -eq 0 ] && ok || bad "P1 rc 0 (got $RC: $(head -3 "$T/P1.out"))"
grep -q 'root@192\.0\.2\.10 ' "$T/P1.ssh.log" && ok || bad "P1 ssh got root@192.0.2.10 (ssh log: $(cat "$T/P1.ssh.log"); lane log: $(tail -3 "$T/P1/logs/stale-owed.log" 2>/dev/null))"
! grep -q 'root@box-fixture-dead ' "$T/P1.ssh.log" && ok || bad "P1 ssh never got root@box-fixture-dead"
grep -q '^FX-1 OWED-STALE .* project=proj-fixture-a$' "$T/P1.ssh.in" && ok || bad "P1 ssh stdin held the OWED-STALE line (got $(cat "$T/P1.ssh.in"))"

# ---------- P2: no IP column -> the box name ------------------------------------
sweep P2 box-fixture-noip
grep -q 'root@box-fixture-noip ' "$T/P2.ssh.log" && ok || bad "P2 ssh got root@box-fixture-noip (ssh log: $(cat "$T/P2.ssh.log"))"

# ---------- P3: local -> no ssh, the local append -------------------------------
sweep P3 local
[ ! -s "$T/P3.ssh.log" ] && ok || bad "P3 a local box costs no ssh (ssh log: $(cat "$T/P3.ssh.log"))"
grep -q '^FX-1 OWED-STALE ' "$T/P3/logs/READY-QUEUE.log" 2>/dev/null && ok || bad "P3 the line is in the local READY-QUEUE.log"

# ---------- budget: only the fixture board was read ----------------------------
! grep -qv '\.example\.test/' <<<"$(cat "$T"/P*.curl.log)" && ok || bad "budget: curl saw only fixture URLs ($(cat "$T"/P*.curl.log | grep -v '\.example\.test/' | head -3))"

echo "stale-owed-push-host.bh-8545: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/wake-loop-lane-rows.bh-9072-test.sh — BH-9072 (BH-9067.0): a lane wake
# (a `wakes` row with repo harness/lanes, kind lane, written by
# POST /api/lane-wakes/ring) is never launched by bin/wake-loop.sh. The worker
# claim never hands one out (worker/jobs/test/lane-wakes.bh-9072.test.js W8);
# this suite is the box half: when a mis-filtering worker does hand one out,
# the loop drops it as "not a fleet repo" and launches nothing.
#
# The fixture is the one of tests/wake-loop-test.sh, rebuilt here (not sourced):
# the stub worker tests/lib/wake-claim-stub.sh serves $T/wakes.json through
# the claim (CLAIM_ALL=1 = a worker that ignores the repo filter), and every
# owning script is a recorder that writes its argv to calls/<name>.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-lane-rows.bh-9072-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 BOX_NAME=box-hub WCS_WAKES="$T/wakes.json"
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=tok-fixture-bh9072\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
for L in bin/wake-loop.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$T" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3-fixture ;;
  project-3/box)  echo local ;;
  project-3/board_prefix) echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
for s in merge-conductor deploy-train postmerge-qa run-triage pm-groom; do
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$T/bin/$s.sh"
done
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
for s in ssh gh; do printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\nexit 7\n' "$s" > "$T/bin/$s"; done
printf '#!/bin/bash\nexec "$@"\n' > "$T/bin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8; do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d " ")
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}

# (a) a ring row, handed out by a worker that ignores the repo filter.
printf '{"wakes":[{"id":41,"repo":"harness/lanes","kind":"lane","key":"pm-groom:project-3","event":"lane-wake","at":"2026-11-09T11:00:00Z"}]}' > "$T/wakes.json"
CLAIM_ALL=1 "$T/bin/wake-loop.sh"; rc=$?; settle
[ "$rc" = 0 ] && ok || bad "the loop exits 0 (rc $rc)"
LOG=$(cat "$T/logs/wake-loop.log" 2>/dev/null)
grep -q 'not a fleet repo.*harness/lanes' <<<"$LOG" && ok || bad "the ring is dropped as not a fleet repo, naming harness/lanes: $(tail -3 "$T/logs/wake-loop.log" 2>/dev/null)"
launched=$(cat "$T/calls/"* 2>/dev/null)
[ -z "$launched" ] && ok || bad "a lane wake must launch nothing: $launched"
grep -q "unknown kind" <<<"$LOG" && bad "the row reached the kind switch" || ok

echo "wake-loop-lane-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# tests/pr-owner-sweep-heartbeat.bh-9114-test.sh — bin/pr-owner-sweep.sh is a
# `cron` heartbeat lane (BH-9114).
#
# It used to beat only through hb_tick (the one-line adoption), so every run
# left state/heartbeat/pr-owner-sweep.<pid>.json with no kind. The pid exited
# when the run ended, and bin/heartbeat-reaper.sh paged "pr-owner-sweep dead"
# under a new per-pid id each run (about 96 open console rows on 2026-11-05).
#   H1 a run with no repo to sweep completes: no instance file, and the
#      completion stamp state/heartbeat-done/pr-owner-sweep is <epoch>\t1800
#   H2 a run over one stub repo does the same, and its last beat carried the
#      run summary (owned=)
#   H3 the REAL reaper, run after H2 on the same tree, writes 0 ALERTS lines
# Driven, not grepped: the real sweep and the real reaper, with gh and curl as
# PATH shims (no network).
# Run from anywhere: tests/pr-owner-sweep-heartbeat.bh-9114-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
for s in bin/pr-owner-sweep.sh bin/jobs-client.sh bin/lib/hub-box.sh bin/heartbeat-reaper.sh bin/lane-alert.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
export GH_TOKEN=fixture-defaulttok
export GH_BUDGET_TTL_S=0
printf '#!/bin/bash\nprintf "%%s\\n" box-project-5-1\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\n' "$T" > "$H/bin/beat.sh"
# fleet-conf.sh: no projects at all (H1), so the sweep has no repo pair.
printf '#!/bin/bash\nexit 0\n' > "$H/bin/fleet-conf.sh"
chmod +x "$H/bin/"*.sh 2>/dev/null

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit")
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$now" "$now"
    exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   echo '[]' ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
# The DB write-through is the observation point for the run's beats: hb_* hand
# each one to HB_DB_CMD, so the recorder holds what the heartbeat said mid-run.
cat > "$T/fakebin/hbrec" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/hbdb.txt"
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl" "$T/fakebin/hbrec"
export PATH="$T/fakebin:$PATH"

HBD="$H/state/heartbeat"
STAMPF="$H/state/heartbeat-done/pr-owner-sweep"
# wait_file <path> <pattern> — the DB beat is detached (&), so its line is the one
# thing the sweep's exit does not order. Bounded; a timeout is a failed assertion.
wait_line() { local i=0
  while [ "$i" -lt 100 ]; do grep -q "$2" "${1:-}" 2>/dev/null && return 0; sleep 0.05; i=$((i + 1)); done
  return 1; }

# ── H1 no repo to sweep: the run still completes ────────────────────────────
B0=$(date +%s)
"$H/bin/pr-owner-sweep.sh" >/dev/null 2>&1; RC=$?
B1=$(date +%s)
[ "$RC" = 0 ] && ok || bad "H1 the sweep must exit 0 with no repo (rc=$RC)"
LEFT=$(ls "$HBD"/pr-owner-sweep.*.json 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "H1 a completed run must leave no instance file: $LEFT :: $(cat $LEFT 2>/dev/null)"
IFS=$'\t' read -r SEP SIV < "$STAMPF" 2>/dev/null
case "${SEP:-}" in ''|*[!0-9]*) SEP=0 ;; esac
[ "${SIV:-}" = 1800 ] && [ "$SEP" -ge "$B0" ] && [ "$SEP" -le "$B1" ] && ok \
  || bad "H1 the completion stamp must be <epoch>\\t1800: $(cat "$STAMPF" 2>/dev/null)"

# ── H2 one repo, the full path ──────────────────────────────────────────────
scratch_rm "$H/state/heartbeat-done" >/dev/null 2>&1
B0=$(date +%s)
HB_DB=1 HB_DB_CMD="$T/fakebin/hbrec" "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>&1; RC=$?
B1=$(date +%s)
[ "$RC" = 0 ] && ok || bad "H2 the sweep must exit 0 over one repo (rc=$RC)"
LEFT=$(ls "$HBD"/pr-owner-sweep.*.json 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "H2 a completed run must leave no instance file: $LEFT"
IFS=$'\t' read -r SEP SIV < "$STAMPF" 2>/dev/null
case "${SEP:-}" in ''|*[!0-9]*) SEP=0 ;; esac
[ "${SIV:-}" = 1800 ] && [ "$SEP" -ge "$B0" ] && [ "$SEP" -le "$B1" ] && ok \
  || bad "H2 the completion stamp must be <epoch>\\t1800: $(cat "$STAMPF" 2>/dev/null)"
wait_line "$T/hbdb.txt" 'pr-owner-sweep beat .*owned=' && ok \
  || bad "H2 the run's last beat must carry the summary (owned=): $(cat "$T/hbdb.txt" 2>/dev/null)"
wait_line "$T/hbdb.txt" 'pr-owner-sweep done' && ok \
  || bad "H2 the run must close with hb_done: $(cat "$T/hbdb.txt" 2>/dev/null)"

# ── H3 the reaper after the run: nothing to page ────────────────────────────
: > "$H/logs/ALERTS.log"
( unset HB_SILENT_FLOOR_S HB_STALE_MULT; HB_BOOT_AT=$((B0 - 86400)) timeout 20 "$H/bin/heartbeat-reaper.sh" ) >/dev/null 2>&1
N=$(grep -c 'heartbeat-reaper' "$H/logs/ALERTS.log" 2>/dev/null)
[ "${N:-0}" = 0 ] && ok || bad "H3 the reaper must not page a completed pr-owner-sweep run: $(cat "$H/logs/ALERTS.log")"

echo "pr-owner-sweep-heartbeat.bh-9114: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

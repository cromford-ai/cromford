#!/bin/bash
# bin/restore-lab.sh — hub cron (*/5): run ONE console-requested restore lab.
#
# WHY THIS EXISTS (#1909, BH-1944; the #388 wipe). The weekly restore drill
# (bin/restore-drill.sh) proves the newest hub backup once a week on a borrowed,
# billed Orgo computer. The restore lab answers a narrower question on demand,
# for free: "does THIS box's backup pull, verify and extract right now?" The
# console (or the MCP) asks through POST /api/hub/restore-lab; this lane claims
# the run, dry-runs bin/state-restore.sh into a /tmp scratch dir and posts the
# verdict back to restore_lab_runs. It never calls restore-drill.sh, never ssh,
# and never passes --apply: the live tree is never a destination.
#
# RUN ORDER (each step's failure is named in the log or the posted detail):
#   gate        lane_gate_or_exit restore-lab (flags/all-off,
#               flags/lane-off-restore-lab) — exit 0 before the lock.
#   lock        flock -n locks/restore-lab.lock; held = a run is going, exit 0.
#               Dedupe only, never a wait; the worker's claim CAS is the
#               cross-box guard.
#   guard       RESTORE_LAB_TMPDIR (default /tmp) and the scratch paths are
#               resolved with realpath (symlinks followed). One that is $H or
#               under $H/ is exit 2 + one ALERTS line, BEFORE anything is
#               created, claimed or removed — the rm -rf of the scratch dir must
#               never be able to land in the live harness.
#   scratch     mktemp -d; the EXIT trap that removes it is armed only now.
#   claim       POST /api/hub/restore-lab/claim {claimer: JOBS_BOX}. No run or
#               no answer = exit 0 (the jobs client already alerts an outage).
#   restore     state-restore.sh <prefix> <snapshot> --dest <S>/tree
#               --live <S>/empty-live under `timeout RESTORE_LAB_TIMEOUT_S`.
#               <prefix> is the bucket prefix of the run's box name
#               (cron_box_id_for: box-project-3-2 -> project-3).
#   verdict     ok only when ALL hold: rc 0; a `pulled <prefix>/<ts>.tar.zst`
#               line (drill_pulled_stamp, shared with the drill); a
#               `sha256 ok <64hex>` line; <S>/tree/<prefix>/<ts>/tree is
#               non-empty. Otherwise fail, the detail naming the first rule
#               that failed plus state-restore's own REFUSED/not configured/no
#               backups line (key names only; it never prints a value).
#   result      POST /api/hub/restore-lab/<id>/result {claimer, ok, detail,
#               sha256, snapshot_ts}. A POST that is not a 2xx leaves the run
#               claimed (re-offered after restore_lab_claim_ttl_s): ONE ALERTS
#               line and exit 1.
# Exit: 0 recorded / nothing to do / gated / locked / worker down, 1 result
# not recorded, 2 scratch guard refused.
#
# Knobs (catalog/lanes.d/restore-lab.json): RESTORE_LAB_TIMEOUT_S (1500; keep
# it below the worker's restore_lab_claim_ttl_s, 1800), RESTORE_LAB_TMPDIR
# (default /tmp; a path, not settable).
# Docs: docs/verification-map/restore-lab.md.
# Run by hand: bin/restore-lab.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
HENV=$(harness_env_dir "$H")
set -a
# shellcheck disable=SC1091
. "$HENV/global.env" 2>/dev/null
set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-restore-lab
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off restore-lab.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit restore-lab
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    restore-lab

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/cron-lines.sh
. "$H/bin/lib/cron-lines.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-steps.sh
. "$H/bin/lib/restore-drill-steps.sh" || exit 1

LOG="$H/logs/restore-lab.log"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
now() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { printf '%s [restore-lab] %s\n' "$(now)" "$*" >> "$LOG"; }
alert() { printf '%s [restore-lab] %s\n' "$(now)" "$*" >> "$ALERTS"; }

exec 9>"$H/locks/restore-lab.lock"
flock -n 9 || exit 0

# ---- guard: nothing below may create or remove anything inside $H ----------
HR=$(realpath -m "$H")
under_h() { local p; p=$(realpath -m "$1") || return 0; [ "$p" = "$HR" ] || [[ "$p" == "$HR"/* ]]; }
refuse() {
  alert "restore-lab: REFUSED — scratch path $1 resolves to $(realpath -m "$1") inside the live harness $HR; set RESTORE_LAB_TMPDIR outside it. Nothing was claimed or removed."
  exit 2
}
BASE="${RESTORE_LAB_TMPDIR:-/tmp}"
[ -n "${RESTORE_LAB_TMPDIR:-}" ] || BASE=/tmp
under_h "$BASE" && refuse "$BASE"
SCRATCH=$(mktemp -d "$BASE/restore-lab.XXXXXX") || { log "mktemp in $BASE failed"; exit 0; }
# Re-checked on the made paths: a base swapped for a symlink between the check
# and mktemp must still not arm an rm inside $H.
for p in "$SCRATCH/tree" "$SCRATCH/empty-live"; do
  under_h "$p" && refuse "$p"
done
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir "$SCRATCH/empty-live" || { log "cannot create $SCRATCH/empty-live"; exit 0; }

# ---- claim ----------------------------------------------------------------
CLAIM=$(_jobs_req POST /api/hub/restore-lab/claim "$(jq -nc --arg c "$JOBS_BOX" '{claimer:$c}')") \
  || { log "claim failed (HTTP ${JOBS_HTTP:-none}); nothing claimed"; exit 0; }
ID=$(jq -r '.run.id // empty' <<<"$CLAIM" 2>/dev/null)
[ -n "$ID" ] || exit 0
BOX=$(jq -r '.run.box // empty' <<<"$CLAIM")
SNAP=$(jq -r '.run.snapshot // empty' <<<"$CLAIM")
PREFIX=$(cron_box_id_for "$BOX")

# ---- restore + verdict ----------------------------------------------------
OK=false DETAIL="" SHA="" STAMP="" OUT="" RC=""
TIMEOUT_S="${RESTORE_LAB_TIMEOUT_S:-1500}"
if ! [[ "$ID" =~ ^[0-9]+$ ]]; then
  log "claim answered a non-numeric run id; nothing restored"; exit 0
elif ! [[ "$PREFIX" =~ ^[a-z0-9-]+$ ]]; then
  DETAIL="box '$BOX' maps to bucket prefix '$PREFIX', not [a-z0-9-]+"
elif ! [[ "$SNAP" = latest || "$SNAP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  DETAIL="snapshot '$SNAP' is not latest or YYYYMMDDTHHMMSSZ"
elif ! [[ "$TIMEOUT_S" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_S" -lt 1 ]; then
  DETAIL="RESTORE_LAB_TIMEOUT_S '$TIMEOUT_S' is not a positive integer"
else
  OUT=$(timeout "$TIMEOUT_S" "$H/bin/state-restore.sh" "$PREFIX" "$SNAP" \
    --dest "$SCRATCH/tree" --live "$SCRATCH/empty-live" 2>&1); RC=$?
  WHY=$(grep -m1 -E 'REFUSED|not configured|no backups?' <<<"$OUT" | cut -c1-200)
  if [ "$RC" = 124 ]; then
    DETAIL="state-restore timed out after ${TIMEOUT_S}s"
  elif [ "$RC" != 0 ]; then
    DETAIL="state-restore rc=$RC${WHY:+: $WHY}"
  elif ! STAMP=$(drill_pulled_stamp "$OUT" "$PREFIX"); then
    STAMP=""; DETAIL="no 'pulled $PREFIX/<ts>.tar.zst' line in state-restore output${WHY:+: $WHY}"
  elif ! SHA=$(printf '%s\n' "$OUT" | sed -nE 's/^sha256 ok ([0-9a-f]{64})$/\1/p' | head -1) || [ -z "$SHA" ]; then
    SHA=""; DETAIL="sha256 not verified: $(grep -m1 '^sha256' <<<"$OUT" | cut -c1-200)"
  elif [ -z "$(find "$SCRATCH/tree/$PREFIX/$STAMP/tree" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    DETAIL="extracted tree $PREFIX/$STAMP/tree is missing or empty"
  else
    OK=true DETAIL="restored $PREFIX/$STAMP into scratch, sha256 verified, tree non-empty"
  fi
fi

# ---- result ---------------------------------------------------------------
# A fail carries whatever was verified, or null; the worker refuses ok:true
# without both, so "ok with nothing verified" cannot be recorded.
BODY=$(jq -nc --arg c "$JOBS_BOX" --argjson ok "$OK" --arg d "$DETAIL" --arg s "$SHA" --arg ts "$STAMP" \
  '{claimer:$c, ok:$ok, detail:($d|.[0:500]), sha256:(if $s=="" then null else $s end), snapshot_ts:(if $ts=="" then null else $ts end)}')
# JOBS_ALERT=0: the line below IS this failure's alert, and the client's daily
# "unreachable" line on top of it would be a second one for the same event.
if ! JOBS_ALERT=0 _jobs_req POST "/api/hub/restore-lab/$ID/result" "$BODY" >/dev/null; then
  alert "restore-lab: result for run $ID not recorded (HTTP ${JOBS_HTTP:-none}); the run stays claimed and is re-offered after restore_lab_claim_ttl_s"
  log "run $ID box=$BOX snapshot=$SNAP verdict=$([ "$OK" = true ] && echo ok || echo fail) NOT RECORDED (HTTP ${JOBS_HTTP:-none})"
  exit 1
fi
log "run $ID box=$BOX snapshot=$SNAP verdict=$([ "$OK" = true ] && echo ok || echo fail): $DETAIL"
exit 0

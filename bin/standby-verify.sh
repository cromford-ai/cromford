#!/bin/bash
# bin/standby-verify.sh — standby cron (*/5): run ONE hub-requested verify of
# this standby's restore path (BH-2640, part of #2519).
#
# WHY THIS EXISTS. A standby streams its hub's state every 15 minutes, but
# "the stream ran" is not "this box could take over": the hub wants to ask a
# named standby, on demand, "does your hub's newest backup pull, verify and
# extract on YOU right now?" The hub queues that as a standby_verify_runs row
# for this box; this lane claims it, dry-runs bin/state-restore.sh into a /tmp
# scratch dir and posts the verdict back. It is bin/restore-lab.sh's drill run
# on the standby: never --apply, never --standby, so the live tree is never a
# destination and the stream's own watermark and run dirs are never touched.
#
# RUN ORDER (each step's failure is named in the log or the posted detail):
#   gate        lane_gate_or_exit standby-verify (flags/all-off,
#               flags/lane-off-standby-verify) — exit 0 before the lock.
#   lock        flock -n locks/standby-verify.lock; held = a run is going,
#               exit 0. Dedupe only, never a wait; the worker's claim CAS
#               (box = claimer) is the cross-box guard.
#   guard       STANDBY_VERIFY_TMPDIR (default /tmp) and the scratch paths are
#               resolved with realpath (symlinks followed). One that is $H or
#               under $H/ is exit 2 + one ALERTS line, BEFORE anything is
#               created, claimed or removed.
#   scratch     mktemp -d; the EXIT trap that removes it is armed only now.
#   identity    bin/box-name.sh; no name = nothing claimed, exit 0.
#   claim       POST /api/hub/standby/verify/claim {claimer: <box name>}. No
#               run or no answer (a 404 before the routes deploy) = exit 0,
#               one log line, no ALERTS line.
#   restore     state-restore.sh <of_hub> latest --dest <S>/tree
#               --live <S>/empty-live under `timeout STANDBY_VERIFY_TIMEOUT_S`.
#               <of_hub> is already a bucket prefix and must be [a-z0-9-]+.
#   verdict     ok only when ALL hold, in restore-lab's order: rc 0; a
#               `pulled <of_hub>/<ts>.tar.zst` line (drill_pulled_stamp); a
#               `sha256 ok <64hex>` line; <S>/tree/<of_hub>/<ts>/tree is
#               non-empty. Otherwise fail, the detail naming the first rule
#               that failed plus state-restore's own REFUSED/not configured/no
#               backups line (key names only; it never prints a value).
#   result      POST /api/hub/standby/verify/<id>/result {claimer, ok, detail,
#               sha256, snapshot_ts}. A POST that is not a 2xx leaves the run
#               claimed (re-offered after standby_verify_claim_ttl_s): ONE
#               ALERTS line and exit 1.
# Exit: 0 recorded / nothing to do / gated / locked / worker down, 1 result
# not recorded, 2 scratch guard refused.
#
# Knobs (catalog/lanes.d/standby-verify.json): STANDBY_VERIFY_TIMEOUT_S (1500;
# keep it below the worker's standby_verify_claim_ttl_s, 1800),
# STANDBY_VERIFY_TMPDIR (default /tmp; a path, not settable).
# Installed by bin/standby-install.sh behind `hub-lease.sh check ||`, so it is
# inert once this box holds the lease. No cron/*.cron runs it.
# Run by hand: bin/standby-verify.sh
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
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-standby-verify
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off standby-verify.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit standby-verify
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    standby-verify

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-steps.sh
. "$H/bin/lib/restore-drill-steps.sh" || exit 1

LOG="$H/logs/standby-verify.log"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
now() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { printf '%s [standby-verify] %s\n' "$(now)" "$*" >> "$LOG"; }
# Alerts go through bin/alert-line.sh (the alert-writer ratchet, BH-2314): it
# stamps, dedups and beats the line. \$ALERTS stays for any reads.
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[standby-verify] $*"; }

exec 9>"$H/locks/standby-verify.lock"
flock -n 9 || exit 0

# ---- guard: nothing below may create or remove anything inside $H ----------
HR=$(realpath -m "$H")
under_h() { local p; p=$(realpath -m "$1") || return 0; [ "$p" = "$HR" ] || [[ "$p" == "$HR"/* ]]; }
refuse() {
  alert "standby-verify: REFUSED — scratch path $1 resolves to $(realpath -m "$1") inside the live harness $HR; set STANDBY_VERIFY_TMPDIR outside it. Nothing was claimed or removed."
  exit 2
}
BASE="${STANDBY_VERIFY_TMPDIR:-/tmp}"
[ -n "${STANDBY_VERIFY_TMPDIR:-}" ] || BASE=/tmp
under_h "$BASE" && refuse "$BASE"
SCRATCH=$(mktemp -d "$BASE/standby-verify.XXXXXX") || { log "mktemp in $BASE failed"; exit 0; }
# Re-checked on the made paths: a base swapped for a symlink between the check
# and mktemp must still not arm an rm inside $H.
for p in "$SCRATCH/tree" "$SCRATCH/empty-live"; do
  under_h "$p" && refuse "$p"
done
trap 'rm -rf -- "$SCRATCH"' EXIT
mkdir "$SCRATCH/empty-live" || { log "cannot create $SCRATCH/empty-live"; exit 0; }

# ---- claim ----------------------------------------------------------------
CLAIMER=$(HARNESS="$H" "$H/bin/box-name.sh" 2>/dev/null)
[ -n "$CLAIMER" ] || { log "no box name; nothing claimed"; exit 0; }
# JOBS_ALERT=0: before the worker's routes deploy every claim is a 404, and a
# standby polls every 5 minutes; the stream's watchdog report is the paging path.
# The answer goes to a file, not $( ), so JOBS_HTTP survives for the log line.
JOBS_ALERT=0 _jobs_req POST /api/hub/standby/verify/claim "$(jq -nc --arg c "$CLAIMER" '{claimer:$c}')" \
  > "$SCRATCH/claim.json" \
  || { log "claim failed (HTTP ${JOBS_HTTP:-none}); nothing claimed"; exit 0; }
CLAIM=$(cat "$SCRATCH/claim.json")
ID=$(jq -r '.run.id // empty' <<<"$CLAIM" 2>/dev/null)
[ -n "$ID" ] || exit 0
OF=$(jq -r '.run.of_hub // empty' <<<"$CLAIM")

# ---- restore + verdict ----------------------------------------------------
OK=false DETAIL="" SHA="" STAMP="" OUT="" RC=""
TIMEOUT_S="${STANDBY_VERIFY_TIMEOUT_S:-1500}"
if ! [[ "$ID" =~ ^[0-9]+$ ]]; then
  log "claim answered a non-numeric run id; nothing restored"; exit 0
elif ! [[ "$OF" =~ ^[a-z0-9-]+$ ]]; then
  DETAIL="of_hub '$OF' is not a bucket prefix [a-z0-9-]+"
elif ! [[ "$TIMEOUT_S" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_S" -lt 1 ]; then
  DETAIL="STANDBY_VERIFY_TIMEOUT_S '$TIMEOUT_S' is not a positive integer"
else
  OUT=$(timeout "$TIMEOUT_S" "$H/bin/state-restore.sh" "$OF" latest \
    --dest "$SCRATCH/tree" --live "$SCRATCH/empty-live" 2>&1); RC=$?
  WHY=$(grep -m1 -E 'REFUSED|not configured|no backups?' <<<"$OUT" | cut -c1-200)
  if [ "$RC" = 124 ]; then
    DETAIL="state-restore timed out after ${TIMEOUT_S}s"
  elif [ "$RC" != 0 ]; then
    DETAIL="state-restore rc=$RC${WHY:+: $WHY}"
  elif ! STAMP=$(drill_pulled_stamp "$OUT" "$OF"); then
    STAMP=""; DETAIL="no 'pulled $OF/<ts>.tar.zst' line in state-restore output${WHY:+: $WHY}"
  elif ! SHA=$(printf '%s\n' "$OUT" | sed -nE 's/^sha256 ok ([0-9a-f]{64})$/\1/p' | head -1) || [ -z "$SHA" ]; then
    SHA=""; DETAIL="sha256 not verified: $(grep -m1 '^sha256' <<<"$OUT" | cut -c1-200)"
  elif [ -z "$(find "$SCRATCH/tree/$OF/$STAMP/tree" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    DETAIL="extracted tree $OF/$STAMP/tree is missing or empty"
  else
    OK=true DETAIL="restored $OF/$STAMP into scratch on $CLAIMER, sha256 verified, tree non-empty"
  fi
fi

# ---- result ---------------------------------------------------------------
# A fail carries whatever was verified, or null; the worker refuses ok:true
# without both, so "ok with nothing verified" cannot be recorded.
BODY=$(jq -nc --arg c "$CLAIMER" --argjson ok "$OK" --arg d "$DETAIL" --arg s "$SHA" --arg ts "$STAMP" \
  '{claimer:$c, ok:$ok, detail:($d|.[0:500]), sha256:(if $s=="" then null else $s end), snapshot_ts:(if $ts=="" then null else $ts end)}')
VERDICT=$([ "$OK" = true ] && echo ok || echo fail)
# JOBS_ALERT=0: the line below IS this failure's alert.
if ! JOBS_ALERT=0 _jobs_req POST "/api/hub/standby/verify/$ID/result" "$BODY" >/dev/null; then
  alert "standby-verify: result for run $ID not recorded (HTTP ${JOBS_HTTP:-none}); the run stays claimed and is re-offered after standby_verify_claim_ttl_s"
  log "run $ID of_hub=$OF verdict=$VERDICT NOT RECORDED (HTTP ${JOBS_HTTP:-none})"
  exit 1
fi
log "run $ID of_hub=$OF verdict=$VERDICT: $DETAIL"
exit 0

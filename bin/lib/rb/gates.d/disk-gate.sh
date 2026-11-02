# shellcheck shell=bash
# Sourced by rb_gate_claim_and_workspace in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> disk gate
# A BUILD IS NOT STARTED ON A FULL DISK (BH-1123). At or over
# DISK_BUILD_REFUSE_PCT (default 92, a knob on the disk-guard lane) the build
# answers BUILD_DEFERRED with the reading and the line, and is re-offered next
# tick, instead of buying a plan session and dying on ENOSPC halfway through.
# Here, below hub-no-build, so a hub build under HUB_BUILD_OK=1 is gated too,
# and above the overlap check and every claim, so nothing is left half-claimed.
# Pool machines (BUILDER_EXEC=1) are not gated: the ticket asked for board boxes
# and the hub. No reading, or no lib, fails OPEN: a broken probe must not stop
# the fleet. The alert id is the one bin/disk-guard.sh raises, so the two
# writers are one open condition.
if [ "${BUILDER_EXEC:-}" != 1 ]; then
  _dg=""
  for _dgf in "$(dirname "$0")/lib/disk-guard.sh" "$HARNESS/bin/lib/disk-guard.sh"; do
    # shellcheck source=bin/lib/disk-guard.sh
    [ -r "$_dgf" ] && . "$_dgf" && { _dg=1; break; }
  done
  if [ -z "$_dg" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] disk gate: bin/lib/disk-guard.sh not readable, not gated" >> "$BUILD/pipeline.log"
  elif DG_REASON=$(disk_build_refuse_reason); then
    echo "$(STAMP) [$PROJECT/$KEY] disk gate: $DG_REASON" >> "$BUILD/pipeline.log"
    "$HARNESS/bin/lane-alert.sh" --id "disk-refuse-$(hostname)" --severity critical disk-guard \
      "build $PROJECT/$KEY refused: $DG_REASON" >/dev/null 2>&1 || true
    RESULT "BUILD_DEFERRED $DG_REASON"
    exit 3
  fi
fi
# <<< disk gate

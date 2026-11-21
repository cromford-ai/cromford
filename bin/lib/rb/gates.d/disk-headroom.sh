# shellcheck shell=bash
# Sourced by rb_gate_claim_and_workspace in bin/lib/rb/gates.sh at its call site, never run (BH-8930: gates.d).
# >>> disk headroom
# FREE DISK AT BUILD START, AND HEADROOM BEFORE THE DISK GATE (BH-9435). Every
# machine, pool included, writes one `disk: <MB> MB free on / at build start`
# line, so a grep over builds/*/pipeline.log gives the per-host numbers. Under
# DISK_HEADROOM_MIN_FREE_MB (a knob on the disk-guard lane) bin/lib/disk-headroom.sh
# trims old settled build dirs (subdirs go, the dir and its top-level files stay), oldest first (dry run by default, one audit
# line in logs/disk-headroom.log). It never fails the build: no lib is one line,
# and the disk gate below still refuses at its percent line.
_dhl=""
for _dhf in "$(dirname "$0")/lib/disk-headroom.sh" "$HARNESS/bin/lib/disk-headroom.sh"; do
  # shellcheck source=bin/lib/disk-headroom.sh
  [ -r "$_dhf" ] && . "$_dhf" && { _dhl=1; break; }
done
if [ -n "$_dhl" ] && command -v dh_run >/dev/null 2>&1; then
  while IFS= read -r _dhline; do
    echo "$(STAMP) [$PROJECT/$KEY] $_dhline" >> "$BUILD/pipeline.log"
  done < <(dh_run "$HARNESS" "$BUILD" 2>&1)
else
  echo "$(STAMP) [$PROJECT/$KEY] disk headroom: bin/lib/disk-headroom.sh not readable, no measure" >> "$BUILD/pipeline.log"
fi
# <<< disk headroom

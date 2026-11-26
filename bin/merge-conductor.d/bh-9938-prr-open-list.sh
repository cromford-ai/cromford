# shellcheck shell=bash
# bin/merge-conductor.d/bh-9938-prr-open-list.sh - THE PR-RECORD STEP AND THE
# OPEN LIST THROUGH THE SEAM (BH-9938 slice C1, BH-9926 wave 6). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block), before the first tick.
#
# prr_pin pins the step (the row lane.merge-conductor.gh_source) once per
# process, so no prr_read makes a settings read. A step a parent lane pinned
# (GH_SOURCE_LANE=<parent>) is not this lane's (bin/lib/prr-shadow.sh).
# PRS_OPEN_PRR=merge-conductor makes prs_open_list (bin/lib/pr-snapshot.sh)
# read the open list through prr_read and the seam
# bin/lib/prr-shadow.d/merge-conductor.sh, which needs bin/lib/pr-record.sh.
# A missing lib or seam: no-op, and prs_open_list reads as before.
# shellcheck source=bin/lib/prr-shadow.sh
[ -r "$H/bin/lib/prr-shadow.sh" ] && . "$H/bin/lib/prr-shadow.sh" 2>/dev/null && prr_pin merge-conductor
if declare -F prr_seam_load >/dev/null 2>&1; then
  # shellcheck source=bin/lib/pr-record.sh
  { declare -F pr_record_open_rest >/dev/null 2>&1 || . "$H/bin/lib/pr-record.sh" 2>/dev/null; } \
    && prr_seam_load merge-conductor 2>/dev/null && export PRS_OPEN_PRR=merge-conductor
fi

# shellcheck shell=bash
# bin/merge-conductor.d/bh-9075-parks.sh - THE PARKS TABLE, CONDUCTOR SIDE
# (BH-9075, BH-9067.3). Sourced by bin/merge-conductor.sh (the BH-7453
# fragment block); it only sources two libs, no side effect at source time.
#
#   bin/lib/parks-write.sh    pw_conductor_sync: the BLOCKED_HUMAN / RED_TWICE
#                             rows of pr-state.tsv as `parks` rows (the writer)
#   bin/lib/mc/parks-delta.sh mc_parks_delta_skip and mc_parks_tick_end (the
#                             delta read, MC_PARKS_DELTA_MODE, default off)
#
# The driver's two call sites in tick_project are `command -v` guarded, so a
# box without these files ticks exactly as before.
# shellcheck source=../lib/parks-write.sh
[ -r "$H/bin/lib/parks-write.sh" ] && . "$H/bin/lib/parks-write.sh"
# shellcheck source=../lib/mc/parks-delta.sh
[ -r "$H/bin/lib/mc/parks-delta.sh" ] && . "$H/bin/lib/mc/parks-delta.sh"
true

# shellcheck shell=bash
# bin/merge-conductor.d/bh-10316-tick-memo.sh — loads the conductor's tick memo
# (BH-10316): bin/lib/mc/tick-memo.sh, whose header says what it keeps, what
# clears it and where it lives. The driver arms it before the fan-out
# (mc_tm_arm), logs its one line after (mc_tm_report) and removes its dir in the
# EXIT trap. A tree without the lib defines nothing, and every caller reads
# GitHub as before (each one asks `command -v mc_tm_on`).
# shellcheck source=bin/lib/mc/tick-memo.sh
if [ -r "${BASH_SOURCE[0]%/*}/../lib/mc/tick-memo.sh" ]; then
  . "${BASH_SOURCE[0]%/*}/../lib/mc/tick-memo.sh"
fi

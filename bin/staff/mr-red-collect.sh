#!/bin/bash
# bin/staff/mr-red-collect.sh — BH-9532 (C0, #9539): Mr Red's collector runner.
#
# WHO RUNS IT. Only bin/staff/mr-red.sh tick, with MRR_TICK=1. Without
# MRR_TICK=1 it prints nothing and exits 0: bin/staff.sh tick-all runs
# bin/staff/<agent>-collect.sh for every active roster agent, and Mr Red's
# findings must not reach that lane's model stage. So tick-all claims nothing
# for mr-red and makes no model call for it.
#
# WHAT. Runs every bin/staff/mr-red-collect.d/*.sh in LC_ALL=C file order,
# each under `timeout` for what is left of the tick budget (MRR_DEADLINE, epoch
# seconds; the tick sets it from staff.mr-red.tick_timeout_s). A source that
# exits 0 has its JSON object lines with an .item printed, and its last
# `deferred=<n>` line added to the total. A source that exits non-zero (or is
# out of time) has ALL its output dropped, because a partial read never counts,
# and its name goes on the incomplete list.
#
# OUTPUT. The item lines (the bin/staff.sh step-6 shape plus class, repo,
# target, target_kind, head, checks, fingerprint, project), then
# `deferred=<n>` when a source deferred items, then `incomplete=<a,b>` when a
# source failed. EXIT 0 every source read; 3 one or more did not.
# Note: docs/notes/2026-11-11-BH-9532-mr-red.md.
set -uo pipefail
[ "${MRR_TICK:-}" = 1 ] || exit 0
export LC_ALL=C
SELF="$(cd "$(dirname "$0")" && pwd)"
NOW=$(date +%s)
DEADLINE="${MRR_DEADLINE:-}"
# fallback: now + 240 s, the seed of staff.mr-red.tick_timeout_s
[[ $DEADLINE =~ ^[0-9]+$ ]] || DEADLINE=$((NOW + 240))
W=$(mktemp -d "${TMPDIR:-/tmp}/mr-red-collect.XXXXXX") || { echo "incomplete=collector"; exit 3; }
trap 'rm -rf "$W"' EXIT
FAILED=""; DEFERRED=0
for f in "$SELF"/mr-red-collect.d/*.sh; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .sh)
  left=$((DEADLINE - $(date +%s)))
  if [ "$left" -lt 1 ]; then FAILED="${FAILED:+$FAILED,}$name"; continue; fi
  rc=0
  timeout -k 2 "$left" bash "$f" > "$W/out" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then FAILED="${FAILED:+$FAILED,}$name"; continue; fi
  jq -cR 'try fromjson catch empty | select(type == "object" and .item != null)' "$W/out" 2>/dev/null
  d=$(grep -E '^deferred=[0-9]+$' "$W/out" | tail -1 | cut -d= -f2)
  [ -n "$d" ] && DEFERRED=$((DEFERRED + 10#$d))
done
[ "$DEFERRED" -gt 0 ] && echo "deferred=$DEFERRED"
if [ -n "$FAILED" ]; then echo "incomplete=$FAILED"; exit 3; fi
exit 0

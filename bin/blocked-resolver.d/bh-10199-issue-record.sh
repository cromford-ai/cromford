# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10199-issue-record.sh — BH-10199 (slice 1): the
# resolver's hold reads go through the issue record.
#
# WHY. On the hub, 2026-11-26 10:00Z..10:33Z, the resolver spent 262
# `issues/N/comments` and 259 `issues/N` GitHub reads. Both come from
# hold_read (bin/lib/hold-push.sh), which br_hold_gate and its two siblings
# call for the ticket of each park.
#
# WHAT. When both libs are on the box, this file sets IRR_LANE=blocked-resolver
# and IRR_STEP from the knob GH_SOURCE_ISSUES (settings row
# lane.blocked-resolver.gh_source_issues,
# catalog/lanes.d/blocked-resolver.knobs.d/GH_SOURCE_ISSUES.json, default
# shadow), read once when this file is sourced. hold_read then reads the
# thread through irr_read (bin/lib/issue-record.sh):
#   off     GitHub only: today's reads, 0 jobs calls (IRR_LANE is not set).
#   shadow  the lane acts on GitHub; a record that differs writes one
#           PRR_SHADOW line (key <repo>#<n>@thread) in logs/prr-shadow.log,
#           and GitHub's answer is written back into the record.
#   record  the record: 0 GitHub calls on a hit. A miss reads GitHub, logs
#           PRR_MISS and writes the answer back.
# The knob is separate from GH_SOURCE (the resolver's PR discovery reads),
# so this read starts in shadow whatever step that one is in. GH_SOURCE off
# (the step bh-10157-record-discovery.sh pinned) turns it off too: off makes
# no record read at all.
#
# FAIL OPEN. No bin/lib/issue-record.sh or bin/lib/prr-shadow.sh: nothing is
# set or sourced, and hold_read reads GitHub as before.
# BR_OPT_OFF=bh-10199-issue-record does not source this file (the same).
if [ "${GH_SOURCE_ISSUES:-}" != off ] && [ -n "${H:-}" ] \
   && [ -r "$H/bin/lib/issue-record.sh" ] && [ -r "$H/bin/lib/prr-shadow.sh" ]; then
  # shellcheck source=bin/lib/prr-shadow.sh
  . "$H/bin/lib/prr-shadow.sh"
  # shellcheck source=bin/lib/issue-record.sh
  . "$H/bin/lib/issue-record.sh"
  if command -v irr_read >/dev/null 2>&1 && command -v prr_read >/dev/null 2>&1 \
     && [ "$(prr_step blocked-resolver)" != off ]; then
    IRR_LANE=blocked-resolver
    IRR_STEP="${GH_SOURCE_ISSUES:-}"
  fi
fi

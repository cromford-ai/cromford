#!/bin/bash
# bin/lib/archie-repo-activity.sh — BH-8417 (scope F): the `## Repo activity
# (last <n>h)` block of Archie's check prompt. Sourced, never executed.
#
# archie_repo_activity_block prints the block on stdout: the header, then every
# UNREADABLE / INCOMPLETE line (always kept, a blind spot is never cut), then
# the newest ARCHIE_REPO_ACTIVITY_LINES event lines over every repo, newest
# first, each prefixed with its repo:
#
#   <owner/repo> <iso> <kind> #<n> <sha8> <detail>
#
# and, when the cap cut lines, one line that says how many. The lines come
# from bin/repo-activity.sh <repo> --since <n>h, run for HARNESS_REPO (default
# example-org/cromford) and for every repo in fleet.conf (bin/fleet-conf.sh),
# each repo once. A repo-activity run that exits non-zero with no UNREADABLE
# line of its own gets one (`UNREADABLE repo-activity rc <n>`): no repo is
# ever silently absent from the block.
#
# KNOB: ARCHIE_REPO_ACTIVITY_LINES (default 40; registry
# catalog/lanes.d/archie.knobs.d/ARCHIE_REPO_ACTIVITY_LINES.json, settings row
# lane.archie.archie_repo_activity_lines, applied by bin/archie.sh's
# lane_env_apply archie). Outside 1..400 is the default.
#
# KNOB: ARCHIE_REPO_ACTIVITY_SINCE_H (default 6; registry
# catalog/lanes.d/archie.knobs.d/ARCHIE_REPO_ACTIVITY_SINCE_H.json, settings
# row lane.archie.archie_repo_activity_since_h). The window, in hours, that the
# block reads and that its header names. Outside 1..168 is the default.
# archie_repo_activity_since_h prints the resolved value (env, else lane_knob
# when lane-gate.sh is loaded, else 6), so bin/orchestrate.sh names the same
# window in its header.
#
# SANDBOX. Under HARNESS_TEST_SANDBOX=1 the block makes no read unless
# ARCHIE_REPO_ACTIVITY_SANDBOX=1: the archie suites that run a tick have no gh
# stub, and a test must not call GitHub (BH-7563). It then prints the header
# and `(not read: test sandbox)`.
#
# Root: ${HARNESS:-${H:-}} only (D43). An empty root prints the header and an
# UNREADABLE line and returns 1.
# Test: tests/repo-activity.bh-8417-test.sh.

archie_repo_activity_since_h() {
  # Fallback 6 = the registry default of ARCHIE_REPO_ACTIVITY_SINCE_H
  # (catalog/lanes.d/archie.knobs.d/, row lane.archie.archie_repo_activity_since_h).
  # The env is what lane_env_apply archie set (bin/archie.sh). A caller that
  # did not apply the lane env but has lane-gate.sh loaded reads the row here.
  local s="${ARCHIE_REPO_ACTIVITY_SINCE_H:-}"
  if [ -z "$s" ] && command -v lane_knob >/dev/null 2>&1; then
    s=$(lane_knob archie ARCHIE_REPO_ACTIVITY_SINCE_H 2>/dev/null)
  fi
  s="${s:-6}"
  if ! [[ $s =~ ^[0-9]{1,3}$ ]] || [ "$((10#$s))" -lt 1 ] || [ "$((10#$s))" -gt 168 ]; then s=6; fi
  printf '%s\n' "$((10#$s))"
}

archie_repo_activity_block() {
  local h="${HARNESS:-${H:-}}" cap repos r rc w out since_h
  since_h=$(archie_repo_activity_since_h)
  printf '## Repo activity (last %sh)\n' "$since_h"
  if [ -z "$h" ]; then printf 'UNREADABLE repo-activity no harness root\n'; return 1; fi
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "${ARCHIE_REPO_ACTIVITY_SANDBOX:-}" != 1 ]; then
    printf '(not read: test sandbox)\n'; return 0
  fi
  # Fallback 40 = the registry default of ARCHIE_REPO_ACTIVITY_LINES
  # (catalog/lanes.d/archie.knobs.d/, row lane.archie.archie_repo_activity_lines).
  cap="${ARCHIE_REPO_ACTIVITY_LINES:-40}"
  if ! [[ $cap =~ ^[0-9]{1,3}$ ]] || [ "$((10#$cap))" -lt 1 ] || [ "$((10#$cap))" -gt 400 ]; then cap=40; fi
  cap=$((10#$cap))
  # HARNESS_REPO comes from bin/lib/deployment.sh (BH-4080), never a literal.
  # shellcheck source=bin/lib/deployment.sh
  . "${HARNESS_DEPLOYMENT_FILE-$h/bin/lib/deployment.sh}" 2>/dev/null || { printf 'UNREADABLE repo-activity no deployment.sh\n'; return 1; }
  w=$(mktemp -d "${TMPDIR:-/tmp}/archie-ra.XXXXXX") || { printf 'UNREADABLE repo-activity no temp dir\n'; return 1; }
  repos=$( { printf '%s\n' "$HARNESS_REPO"
             "$h/bin/fleet-conf.sh" --projects 2>/dev/null | while read -r p; do
               [ -n "$p" ] && "$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null
             done; } | awk 'NF && !seen[$1]++ {print $1}')
  : > "$w/notes"; : > "$w/events"
  while read -r r; do
    [ -n "$r" ] || continue
    rc=0
    "$h/bin/repo-activity.sh" "$r" --since "${since_h}h" > "$w/out" 2>/dev/null || rc=$?
    out="$w/out"
    grep -E '^(UNREADABLE|INCOMPLETE) ' "$out" | sed "s|^|$r |" >> "$w/notes"
    if [ "$rc" != 0 ]; then
      grep -q '^UNREADABLE ' "$out" || printf '%s UNREADABLE repo-activity rc %s\n' "$r" "$rc" >> "$w/notes"
      continue
    fi
    grep -vE '^(UNREADABLE|INCOMPLETE) ' "$out" | sed "s|^|$r |" >> "$w/events"
  done <<< "$repos"
  cat "$w/notes"
  LC_ALL=C sort -s -r -k2,2 "$w/events" > "$w/sorted"
  head -n "$cap" "$w/sorted"
  local n; n=$(wc -l < "$w/sorted")
  if [ "$n" -gt "$cap" ]; then
    printf '(%s older events cut at ARCHIE_REPO_ACTIVITY_LINES=%s; run bin/repo-activity.sh <repo> for all)\n' "$((n - cap))" "$cap"
  fi
  [ "$n" -gt 0 ] || [ -s "$w/notes" ] || printf '(no events in the last %sh)\n' "$since_h"
  rm -rf "$w"
  return 0
}

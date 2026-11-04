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

# archie_repo_activity_knobs — "<timeout> <budget>" on stdout. The rows win
# over the env (lib_env_apply orchestrate exports a row only), the env wins
# over the fallback, and the resolve runs in a subshell so no export and no
# sourced lane-gate.sh reaches the caller's shell.
archie_repo_activity_knobs() {
  local h="${HARNESS:-${H:-}}" v to bu
  v=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$h" ] && [ -r "$h/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=bin/lib/lane-gate.sh
      . "$h/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply orchestrate >/dev/null 2>&1
    printf '%s %s' "${REPO_ACTIVITY_TIMEOUT_S:-}" "${REPO_ACTIVITY_BUDGET_S:-}"
  )
  read -r to bu <<<"$v"
  # Fallback 5 = the registry default of REPO_ACTIVITY_TIMEOUT_S in
  # catalog/lanes.d/_lib.orchestrate.json (row lib.orchestrate.repo_activity_timeout_s).
  if ! [[ ${to:-} =~ ^[0-9]{1,3}$ ]] || [ "$((10#$to))" -lt 1 ] || [ "$((10#$to))" -gt 60 ]; then to=5; fi
  # Fallback 10 = the registry default of REPO_ACTIVITY_BUDGET_S in
  # catalog/lanes.d/_lib.orchestrate.json (row lib.orchestrate.repo_activity_budget_s).
  if ! [[ ${bu:-} =~ ^[0-9]{1,3}$ ]] || [ "$((10#$bu))" -lt 1 ] || [ "$((10#$bu))" -gt 120 ]; then bu=10; fi
  printf '%s %s\n' "$((10#$to))" "$((10#$bu))"
}

archie_repo_activity_block() {
  local h="${HARNESS:-${H:-}}" cap repos r rc w out since_h to budget t0 dl now i n_ok=0 n_un=0 n_to=0 late="" ln
  local -a list=() pids=()
  since_h=$(archie_repo_activity_since_h)
  printf '## Repo activity (last %sh)\n' "$since_h"
  if [ -z "$h" ]; then printf 'UNREADABLE repo-activity no harness root\n'; return 1; fi
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "${ARCHIE_REPO_ACTIVITY_SANDBOX:-}" != 1 ]; then
    printf '(not read: test sandbox)\n'; return 0
  fi
  t0=$(date +%s.%N)
  # Fallback 40 = the registry default of ARCHIE_REPO_ACTIVITY_LINES
  # (catalog/lanes.d/archie.knobs.d/, row lane.archie.archie_repo_activity_lines).
  cap="${ARCHIE_REPO_ACTIVITY_LINES:-40}"
  if ! [[ $cap =~ ^[0-9]{1,3}$ ]] || [ "$((10#$cap))" -lt 1 ] || [ "$((10#$cap))" -gt 400 ]; then cap=40; fi
  cap=$((10#$cap))
  read -r to budget <<<"$(archie_repo_activity_knobs)"
  # HARNESS_REPO comes from bin/lib/deployment.sh (BH-4080), never a literal.
  # shellcheck source=bin/lib/deployment.sh
  . "${HARNESS_DEPLOYMENT_FILE-$h/bin/lib/deployment.sh}" 2>/dev/null || { printf 'UNREADABLE repo-activity no deployment.sh\n'; return 1; }
  w=$(mktemp -d "${TMPDIR:-/tmp}/archie-ra.XXXXXX") || { printf 'UNREADABLE repo-activity no temp dir\n'; return 1; }
  repos=$( { printf '%s\n' "$HARNESS_REPO"
             "$h/bin/fleet-conf.sh" --projects 2>/dev/null | while read -r p; do
               [ -n "$p" ] && "$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null
             done; } | awk 'NF && !seen[$1]++ {print $1}')
  : > "$w/notes"; : > "$w/events"
  # One reader per repo, all at once. Every descendant writes to files and
  # reads /dev/null, so none of them holds the caller's $( ) pipe open past
  # the budget. `timeout` (budget + 1) is the backstop if the TERM below is lost.
  while read -r r; do
    [ -n "$r" ] || continue
    i=${#list[@]}; list+=("$r")
    {
      GH_REST_TIMEOUT_S=$to timeout -k 1 "$((budget + 1))" "$h/bin/repo-activity.sh" "$r" --since "${since_h}h" \
        > "$w/$i.out" 2> "$w/$i.err" < /dev/null
      echo $? > "$w/$i.rc.tmp" && mv -f "$w/$i.rc.tmp" "$w/$i.rc"
    } > /dev/null 2>&1 < /dev/null &
    pids+=("$!")
  done <<< "$repos"
  dl=$(awk -v a="$t0" -v b="$budget" 'BEGIN { printf "%.3f", a + b }')
  while :; do
    rc=0
    for i in "${!list[@]}"; do [ -e "$w/$i.rc" ] || { rc=1; break; }; done
    [ "$rc" = 0 ] && break
    now=$(date +%s.%N)
    awk -v n="$now" -v d="$dl" 'BEGIN { exit !(n < d) }' || break
    sleep 0.2
  done
  # Collect in repo-list order. A reader still running is not waited for:
  # TERM to it and to its timeout (which passes it on to the reader's group).
  for i in "${!list[@]}"; do
    r=${list[$i]}; out="$w/$i.out"
    rc=$(cat "$w/$i.rc" 2>/dev/null) || rc=""
    if [ -z "$rc" ] || [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      if [ -z "$rc" ]; then
        command -v pkill >/dev/null 2>&1 && pkill -TERM -P "${pids[$i]}" 2>/dev/null
        kill -TERM "${pids[$i]}" 2>/dev/null
      fi
      printf '%s UNREADABLE not finished in %ss\n' "$r" "$budget" >> "$w/notes"
      late="$late $r"; n_to=$((n_to + 1)); continue
    fi
    if [ "$rc" != 0 ] && grep -qE '^UNREADABLE .* HTTP 000 \(timeout\)$' "$out"; then
      printf '%s UNREADABLE timed out after %ss\n' "$r" "$to" >> "$w/notes"
      n_to=$((n_to + 1)); continue
    fi
    grep -E '^(UNREADABLE|INCOMPLETE) ' "$out" | sed "s|^|$r |" >> "$w/notes"
    if [ "$rc" = 0 ]; then
      n_ok=$((n_ok + 1))
      grep -vE '^(UNREADABLE|INCOMPLETE) ' "$out" | sed "s|^|$r |" >> "$w/events"
      continue
    fi
    n_un=$((n_un + 1))
    grep -q '^UNREADABLE ' "$out" || printf '%s UNREADABLE repo-activity rc %s\n' "$r" "$rc" >> "$w/notes"
    ln=$(grep -m 1 '^repo-activity: .* unparseable; first 200 bytes: ' "$w/$i.err" 2>/dev/null) || ln=""
    [ -n "$ln" ] && printf '%s repo-activity: %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$r" "${ln#"repo-activity: $r "}" \
      >> "$h/logs/repo-activity.log" 2>/dev/null
  done
  cat "$w/notes"
  [ -n "$late" ] && printf '(not finished in %ss:%s)\n' "$budget" "$late"
  LC_ALL=C sort -s -r -k2,2 "$w/events" > "$w/sorted"
  head -n "$cap" "$w/sorted"
  local n; n=$(wc -l < "$w/sorted")
  if [ "$n" -gt "$cap" ]; then
    printf '(%s older events cut at ARCHIE_REPO_ACTIVITY_LINES=%s; run bin/repo-activity.sh <repo> for all)\n' "$((n - cap))" "$cap"
  fi
  [ "$n" -gt 0 ] || [ -s "$w/notes" ] || printf '(no events in the last %sh)\n' "$since_h"
  printf '%s repo-activity: %s repos, %s ok, %s unreadable, %s timed out, took %s s (caller %s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#list[@]}" "$n_ok" "$n_un" "$n_to" \
    "$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')" "${0##*/}" \
    >> "$h/logs/repo-activity.log" 2>/dev/null
  rm -rf "$w"
  return 0
}

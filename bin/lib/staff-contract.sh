#!/bin/bash
# bin/lib/staff-contract.sh — BH-9187 (C0): the box side of the staff agent
# contract. Sourced by bin/staff.sh; it needs setting_get and _jobs_req_file
# (bin/jobs-client.sh) and jq. It holds no state and builds no path.
#
#   staff_level <agent>            prints observe | file | act. The row is
#                                  staff.<agent>.level, trimmed and lowercased.
#                                  rc 0 = the row gave the level; rc 3 = no row,
#                                  an outage or any other value, and the level
#                                  is the fallback observe.
#   staff_knob <agent> <name> <fallback>
#                                  a positive integer from staff.<agent>.<name>,
#                                  else the fallback.
#   staff_filed_today <state-dir> [now-epoch]
#                                  the count of <state-dir>/acted/*.json with
#                                  outcome `filed` and an mtime in the UTC day
#                                  of now (the day bin/archie-overlook.sh step 3
#                                  counts).
#   staff_action_post <json-file>  POST /api/staff/levers/actions
#   staff_metric_post <json-file>  POST /api/staff/levers/metric; both print the
#                                  answer and pass the worker rc through.
# Note: docs/notes/2026-11-06-BH-9187-staff-contract.md.

staff_level() {
  local v
  # The row is staff.<agent>.level (schema.d/202611100721-bh-9187-staff-contract.sql);
  # the fallback is observe: no row, an outage or a bad value never files.
  v=$(setting_get "staff.${1:-}.level" 2>/dev/null) || { printf 'observe\n'; return 3; }
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    observe|file|act) printf '%s\n' "$v" ;;
    *) printf 'observe\n'; return 3 ;;
  esac
}

staff_knob() {
  local v
  v=$(setting_get "staff.${1:-}.${2:-}" 2>/dev/null) || v=""
  v="${v//[[:space:]]/}"
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -gt 0 ]; then printf '%s\n' "$((10#$v))"; else printf '%s\n' "$3"; fi
}

staff_filed_today() {
  local d="${1:-}/acted" now="${2:-}" day0 f l
  [[ $now =~ ^[0-9]+$ ]] || now=$(date -u +%s)
  day0=$((now - now % 86400))
  [ -d "$d" ] || { printf '0\n'; return 0; }
  while IFS= read -r -d '' f; do
    l=""; IFS= read -r l < "$f" || true
    printf '%s\n' "$l"
  done < <(find "$d" -maxdepth 1 -type f -name '*.json' -newermt "@$((day0 - 1))" ! -newermt "@$((day0 + 86400 - 1))" -print0 2>/dev/null) \
    | jq -Rn '[inputs | (try fromjson catch null) | select(type == "object" and .outcome == "filed")] | length'
}

staff_action_post() { _jobs_req_file POST /api/staff/levers/actions "$1"; }
staff_metric_post() { _jobs_req_file POST /api/staff/levers/metric "$1"; }

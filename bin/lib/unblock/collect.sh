#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/collect.sh — the unblock lane's collector seam (BH-7722,
# UNB-0). Sourced by bin/unblock.sh, never run; nothing here runs on source.
#
#   ubc_collect <project> <repo> [dir]
#     For each <dir>/*.sh (default bin/lib/unblock/collectors/), the family is
#     the file's basename. The file is sourced in a SUBSHELL and
#     ub_collect_<family> <project> <repo> is called there (a `-` in the
#     family is `_` in the function name). A file that defines no such
#     function is counted UNWIRED and named on its own log line; it is never
#     run. Each wired collector prints JSONL stall records on stdout, with 0
#     model calls. A collector that exits non-zero is counted FAILED and its
#     output is dropped (a cut list never reads as "nothing stalled").
#
#   THE FILTER, per line (G6: a lane never reads its own output):
#     - a line that is not one JSON object (not JSON, an array, a string) is
#       dropped and counted `bad`
#     - a record that carries `<!-- tackler:` anywhere, nested fields
#       included, is dropped and counted `own`
#     - a record whose `labels` holds a `staff:` label (a string, or an object
#       with .name; trimmed and lowercased, as staff-findings isStaffLabel)
#       is dropped and counted `own`. `staffing` is not a staff label.
#   THE CAP: at most UBC_MAX records (the caller sets it from
#     UNBLOCK_MAX_RECORDS, default 200) leave per call, in collector order;
#     the rest are counted in UBC_TRUNCATED.
#
# OUTPUT: the kept records, one JSON object per line, on stdout. Call it in
#   the caller's shell (`ubc_collect p r > file`, never inside $( )) so these
#   counters are set there:
#   UBC_COLLECTORS (wired) UBC_UNWIRED UBC_FAILED UBC_RECORDS (kept, after the
#   cap) UBC_BAD UBC_OWN UBC_TRUNCATED, and UBC_UNWIRED_NAMES (space list).
#   rc 0 always; a missing dir is 0 collectors.
#
# Log: the caller's ubt_log when it is defined (one line per unwired or
# failed family). No root default (D43): the dir comes from the caller.

ubc_collect() {
  local p="$1" repo="$2" dir="${3:-}" f fam fn tmp rc kept
  UBC_COLLECTORS=0 UBC_UNWIRED=0 UBC_FAILED=0 UBC_RECORDS=0 UBC_BAD=0 UBC_OWN=0 UBC_TRUNCATED=0
  UBC_UNWIRED_NAMES=""
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/ubc.XXXXXX") || return 0
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    fam=$(basename "$f" .sh)
    [[ $fam =~ ^[a-z][a-z0-9-]{0,39}$ ]] || { _ubc_log "collector $fam: not a family name, skipped"; continue; }
    fn="ub_collect_${fam//-/_}"
    # shellcheck disable=SC1090
    ( . "$f" >/dev/null 2>&1 || exit 98
      declare -F "$fn" >/dev/null || exit 99
      "$fn" "$p" "$repo" ) > "$tmp.$fam" 2>/dev/null
    rc=$?
    case "$rc" in
      0) UBC_COLLECTORS=$((UBC_COLLECTORS + 1)); cat "$tmp.$fam" >> "$tmp" ;;
      99) UBC_UNWIRED=$((UBC_UNWIRED + 1)); UBC_UNWIRED_NAMES="${UBC_UNWIRED_NAMES:+$UBC_UNWIRED_NAMES }$fam"
          _ubc_log "unwired $fam (no $fn defined; 0 reads)" ;;
      *) UBC_FAILED=$((UBC_FAILED + 1)); _ubc_log "collector $fam failed rc $rc; its records are dropped" ;;
    esac
    rm -f "$tmp.$fam"
  done
  # One jq pass: classify every line, then cut the kept list at UBC_MAX.
  kept=$(jq -R -n -c --argjson max "${UBC_MAX:-200}" '
    def staff: type == "string" and (gsub("^\\s+"; "") | ascii_downcase | startswith("staff:"));
    [inputs | (try fromjson catch null) as $o
      | if ($o | type) != "object" then {k: "bad"}
        elif ($o | tojson | contains("<!-- tackler:")) then {k: "own"}
        elif (($o.labels // []) | if type == "array" then any(.[]; (if type == "object" then .name else . end) | staff) else false end)
          then {k: "own"}
        else {k: "keep", r: $o} end] as $all
    | [$all[] | select(.k == "keep") | .r] as $keep
    | {bad: ([$all[] | select(.k == "bad")] | length), own: ([$all[] | select(.k == "own")] | length),
       total: ($keep | length), keep: $keep[0:$max]}' < "$tmp" 2>/dev/null) || kept='{"bad":0,"own":0,"total":0,"keep":[]}'
  rm -f "$tmp"
  UBC_BAD=$(jq -r .bad <<<"$kept")
  UBC_OWN=$(jq -r .own <<<"$kept")
  UBC_RECORDS=$(jq -r '.keep | length' <<<"$kept")
  UBC_TRUNCATED=$(( $(jq -r .total <<<"$kept") - UBC_RECORDS ))
  jq -c '.keep[]' <<<"$kept"
  return 0
}

_ubc_log() { declare -F ubt_log >/dev/null && ubt_log "$*"; return 0; }

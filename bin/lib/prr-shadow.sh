#!/bin/bash
# bin/lib/prr-shadow.sh — "record first, compare with GitHub, log PRR_SHADOW"
# (BH-9926). Sourced, never executed. Defines functions only: no set -e, no
# exit.
#
# A lane that moves a GitHub read onto the PR record (bin/lib/pr-record.sh)
# moves in three steps, one settings row per lane, `lane.<id>.gh_source`:
#   off     GitHub only, today's read.
#   shadow  both: the lane acts on the GitHub answer, and a record answer that
#           differs from it writes one PRR_SHADOW line. The default.
#   record  the record only: 0 GitHub calls on a hit. A record miss reads
#           GitHub (fail open, the pr_record_get rule) and logs PRR_MISS.
#
#   prr_step <lane-id>
#       Prints off, shadow or record. Source order: $GH_SOURCE (lane_env_apply
#       exports the row lane.<id>.gh_source under that name), then setting_get
#       lane.<id>.gh_source when setting_get is already defined, then `shadow`,
#       the documented fallback of the knob GH_SOURCE. Any other value is
#       `shadow` plus one `PRR_STEP lane=<l> bad=<value>` line.
#       BH-9938 C1: $GH_SOURCE counts only when GH_SOURCE_LANE is empty or is
#       <lane-id>. A value a parent lane pinned (GH_SOURCE_LANE=<parent>) is
#       not this lane's step: lane_env_apply exports a row and never unsets an
#       inherited value, so a child would run under its parent's step.
#
#   prr_pin <lane-id>
#       Resolves prr_step <lane-id> once and exports GH_SOURCE=<step> and
#       GH_SOURCE_LANE=<lane-id>, so each later prr_read of that lane makes
#       no settings read. A child lane that inherits the pair ignores it.
#
#   prr_seam_load <lane-id>
#       Sources bin/lib/prr-shadow.d/<lane-id>.sh, the lane's record, github
#       and norm functions. rc 1 when the file is absent.
#
#   prr_read <lane-id> <key> <out-file> <record-fn> <github-fn> <norm-fn> [args...]
#       Each fn is called `<fn> <file> [args...]`. The record-fn writes the
#       lane's value to <file> and returns 0, or prints one miss word (the
#       pr_record_list words: off unreadable malformed no-sync stale
#       truncated unknown field:<f>) and returns non-zero. The github-fn
#       writes the value to <file> and returns its read's rc. The norm-fn
#       prints the compare form of a file: a JSON array of objects keyed on .n.
#       Sets PRR_SOURCE (github | record). Returns the rc of the source whose
#       value is in <out-file>. Writes only <out-file> and its log line.
#       BH-10213, two additions for step record (steps off and shadow call no
#       note and never set PRR_NOTE):
#       - A record-fn that returns 0 and prints exactly `hit-rc:<1-9>` is a
#         hit that answers that rc (a served "GitHub has none", the payload
#         seams' rc 1): prr_read returns it with PRR_SOURCE=record. In step
#         shadow, a `hit-rc:<n>` that is not the GitHub rc writes one
#         `PRR_SHADOW … rc_record=<n> rc_github=<n>` line. A record-fn that
#         prints nothing keeps the old behavior.
#       - After a miss, PRR_READ_AT is the UTC time the GitHub read starts
#         (PR_RECORD_NOW, the epoch test seam of bin/lib/pr-record.sh, when set),
#         and the github-fn runs with PRR_NOTE=1. Then, when the seam defines
#         <prefix>_note (<prefix> = the record-fn name less `_record`), it is
#         called ONCE as `<prefix>_note <out-file> <github-rc> <why> [args...]`
#         (stdout and rc ignored), to write the GitHub answer back into the
#         record. prr_read still returns the GitHub rc.
#
#   prr_note_statuses <out-file> <github-rc> <slug> <n> <head>     (BH-10213)
#       For a seam's <prefix>_note: GitHub rc 0 and .statuses an array ->
#       pr_record_gh_note statuses (an empty list is the "checked, empty"
#       marker of <head>). Any other rc or shape: nothing.
#   prr_note_payload <comment-file> <github-rc> <slug> <n>          (BH-10213)
#       GitHub rc 0 -> the chosen comment in <comment-file> (written by
#       sdq_payload_last under SDQ_PAYLOAD_COMMENT_OUT) -> pr_record_gh_note
#       mergify. rc 1 (read OK, no payload comment) -> `null`, the marker.
#       Any other rc (2, 3, 4, 75): nothing. The caller removes the file.
#       Both always return 0 and write at most one POST.
#
# Log: <root>/logs/prr-shadow.log, root ${HARNESS:-${H:-}} (no root, no line):
#   <UTC> PRR_SHADOW lane=<l> key=<k> record=<n> github=<n> only_record=<n> only_github=<n> changed=<n>
#   <UTC> PRR_SHADOW lane=<l> key=<k> rc_record=<n> rc_github=<n>   (BH-10213, a hit-rc answer)
#   <UTC> PRR_MISS lane=<l> key=<k> why=<word> fallback=<none|github>
#   <UTC> PRR_STEP lane=<l> bad=<value>
# Count one lane's mismatches: grep -c 'PRR_SHADOW lane=<l>' logs/prr-shadow.log
[ -n "${_PRR_SHADOW_LOADED:-}" ] && return 0
_PRR_SHADOW_LOADED=1
_PRR_SHADOW_DIR="${BASH_SOURCE[0]%/*}"

_prr_shadow_log() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$root/logs/prr-shadow.log" 2>/dev/null || true
}

prr_step() {
  local lane="${1:-}" v="" rc
  if [ -n "${GH_SOURCE+x}" ] && { [ -z "${GH_SOURCE_LANE:-}" ] || [ "$GH_SOURCE_LANE" = "$lane" ]; }; then
    v="$GH_SOURCE"
  elif command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get "lane.$lane.gh_source" 2>/dev/null); rc=$?
    [ "$rc" = 0 ] || v=""
  fi
  case "$v" in
    off|shadow|record) printf '%s\n' "$v" ;;
    '') printf 'shadow\n' ;;
    *) _prr_shadow_log "PRR_STEP lane=$lane bad=$v"; printf 'shadow\n' ;;
  esac
}

prr_pin() {
  local lane="${1:-}" v
  [[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 2
  v=$(prr_step "$lane")
  GH_SOURCE="$v"; GH_SOURCE_LANE="$lane"
  export GH_SOURCE GH_SOURCE_LANE
}

prr_seam_load() {
  local f="$_PRR_SHADOW_DIR/prr-shadow.d/${1:-}.sh"
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [ -r "$f" ] || return 1
  # shellcheck source=/dev/null
  . "$f"
}

# _prr_diff <norm-record> <norm-github> — "record=<n> github=<n> only_record=<n>
# only_github=<n> changed=<n>", keyed on .n.
_prr_diff() {
  jq -rn --argjson r "$1" --argjson g "$2" '
    ($r | map({key: (.n | tostring), value: .}) | from_entries) as $R
    | ($g | map({key: (.n | tostring), value: .}) | from_entries) as $G
    | "record=\($r | length) github=\($g | length)"
      + " only_record=\([$R | keys[] | select($G[.] == null)] | length)"
      + " only_github=\([$G | keys[] | select($R[.] == null)] | length)"
      + " changed=\([$R | keys[] | select($G[.] != null and $G[.] != $R[.])] | length)"' 2>/dev/null
}

# BH-10213, the write-back helpers a seam's <prefix>_note calls (rc always 0
# for the caller to ignore; bin/lib/pr-record.sh pr_record_gh_note does the POST).
prr_note_statuses() { # <out> <github-rc> <slug> <n> <head>
  [ "${2:-}" = 0 ] || return 0
  jq -e '.statuses | arrays' "${1:-/dev/null}" >/dev/null 2>&1 || return 0
  command -v pr_record_gh_note >/dev/null 2>&1 || return 0
  pr_record_gh_note "${3:-}" "${4:-}" statuses "$1" "${5:-}" "${PRR_READ_AT:-}" || true
}

prr_note_payload() { # <comment-file> <github-rc> <slug> <n>
  command -v pr_record_gh_note >/dev/null 2>&1 || return 0
  case "${2:-}" in
    0) jq -e 'type == "object"' "${1:-/dev/null}" >/dev/null 2>&1 || return 0 ;;
    1) [ -n "${1:-}" ] && printf 'null\n' > "$1" 2>/dev/null || return 0 ;;
    *) return 0 ;;
  esac
  pr_record_gh_note "${3:-}" "${4:-}" mergify "$1" "" "${PRR_READ_AT:-}" || true
}

prr_read() {
  local lane="${1:-}" key="${2:-}" out="${3:-}" rfn="${4:-}" gfn="${5:-}" nfn="${6:-}"
  local step tmp why rc grc nr ng
  shift 6 2>/dev/null || return 2
  [ -n "$out" ] || return 2
  step=$(prr_step "$lane")
  PRR_SOURCE=github
  case "$step" in
    off)
      "$gfn" "$out" "$@"; return $? ;;
    record)
      why=$("$rfn" "$out" "$@"); rc=$?
      if [ "$rc" = 0 ]; then
        PRR_SOURCE=record
        # BH-10213: a served "GitHub has none" answer (the seam's own rc).
        [[ "$why" =~ ^hit-rc:([1-9])$ ]] && return "${BASH_REMATCH[1]}"
        return 0
      fi
      _prr_shadow_log "PRR_MISS lane=$lane key=$key why=${why:-unknown} fallback=github"
      : > "$out" 2>/dev/null
      # BH-10213: the GitHub fn runs with PRR_NOTE=1, then the seam's
      # <prefix>_note (when defined) writes its answer back, once.
      if [[ "${PR_RECORD_NOW:-}" =~ ^[0-9]+$ ]]; then PRR_READ_AT=$(date -u -d "@$PR_RECORD_NOW" '+%Y-%m-%dT%H:%M:%SZ')
      else PRR_READ_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); fi
      PRR_NOTE=1 "$gfn" "$out" "$@"; grc=$?
      if declare -F "${rfn%_record}_note" >/dev/null 2>&1; then
        "${rfn%_record}_note" "$out" "$grc" "${why:-unknown}" "$@" >/dev/null 2>&1 || true
      fi
      return "$grc" ;;
  esac
  # shadow
  tmp=$(mktemp "${TMPDIR:-/tmp}/prr-shadow.XXXXXX") || { "$gfn" "$out" "$@"; return $?; }
  why=$("$rfn" "$tmp" "$@"); rc=$?
  "$gfn" "$out" "$@"; grc=$?
  if [ "$rc" != 0 ]; then
    _prr_shadow_log "PRR_MISS lane=$lane key=$key why=${why:-unknown} fallback=none"
  elif [[ "$why" =~ ^hit-rc:([1-9])$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$grc" ] \
      || _prr_shadow_log "PRR_SHADOW lane=$lane key=$key rc_record=${BASH_REMATCH[1]} rc_github=$grc"
  elif [ "$grc" = 0 ]; then
    nr=$("$nfn" "$tmp" 2>/dev/null); ng=$("$nfn" "$out" 2>/dev/null)
    if [ -n "$nr" ] && [ -n "$ng" ] && [ "$nr" != "$ng" ]; then
      _prr_shadow_log "PRR_SHADOW lane=$lane key=$key $(_prr_diff "$nr" "$ng")"
    fi
  fi
  rm -f "$tmp"
  return "$grc"
}

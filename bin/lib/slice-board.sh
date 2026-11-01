#!/bin/bash
# bin/lib/slice-board.sh — file the rest of a sliced IN-APP BOARD ticket when
# one slice merges (BH-8333). A plan that says `SLICE: C<k> of #<ticket-id>`
# builds one slice and names the others (C<k+1>..C<m>) as list items. On the
# GitHub-Issues lane bin/lib/slice-remainder.sh (BH-5961) files those as child
# issues. On a board nothing did: TK-360 shipped C0, read "This ticket is
# closed", and C1-C4 were filed by hand two days later.
#
# This reads the remainder with the same parser (slice_remainder_parse, which
# takes a board id token since BH-8333) and files one child ticket per slice
# through the board filer (fc_file_board, kind `slice`): `parentId` = the
# master, `dependsOn` from the plan's `after C<j>`. bin/decompose-parent-close.sh
# (BH-815) closes the master when every child is done. Nothing here moves a
# master to `done`.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time. Safe under `set -u`. The root is the caller's argument, else
# ${HARNESS:-${H:-}}, never a literal.
#
#   slice_board_line <plan.md>              <k>\t<token> of the first SLICE line
#                                           (token empty for "The build for THIS
#                                           ticket is C<k>"), rc 1 when none
#   slice_board_token <plan.md> <ticket-id> <KEY>
#       -> <token> rc 0 (a slice of THIS ticket; with no ticket id, a board
#          id token is a candidate the parent read must confirm)
#        | rc 1 no SLICE line | <token> rc 2 (a SLICE line for another ticket)
#   slice_board_settle <project> <KEY> <pr-url> <record-dir|-> [ticket-id] [park 0|1] [harness]
#       -> filed:<keys> rc 0 | deferred:<why> rc 1 | unknown:<why> rc 2 (paged)
#        | skip:<why> rc 3
#
# Ledger: <record>/slice-board/, or $HARNESS/state/slice-board/<project>-<KEY>-pr<n>/
# with no record. token, children.json, children.txt, children-board.tsv,
# filed, unknown-paged, fc-error.txt, settle.log. `filed` and `unknown-paged`
# are terminal. The switch is BH-5961's: lane_switch slice-remainder-off or
# SLICE_REMAINDER_FILE=0. Operator notes: docs/verification-map/entries/BH-8333.md.

_SBD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/slice-remainder.sh
command -v slice_remainder_parse >/dev/null 2>&1 || { [ -r "$_SBD_LIB/slice-remainder.sh" ] && . "$_SBD_LIB/slice-remainder.sh"; }

slice_board_line() {
  [ -r "${1:-}" ] || return 1
  local l
  # The guard regex of issue_close_guard, with the board token class.
  l=$(awk '
    { sub(/\r$/, "") }
    $0 ~ /^[ \t*_>]*SLICE:[ \t*_]*C[0-9]+[ \t]+of[ \t]+#[A-Za-z0-9]/ {
      s = $0; match(s, /SLICE:[ \t*_]*C[0-9]+/); k = substr(s, RSTART, RLENGTH); sub(/^.*C/, "", k)
      match(s, /[ \t]of[ \t]+#[A-Za-z0-9][A-Za-z0-9_-]*/); t = substr(s, RSTART, RLENGTH); sub(/^.*#/, "", t)
      printf "%d\t%s\n", k + 0, t; exit
    }
    $0 ~ /^[ \t*_>]*The build for THIS ticket is C[0-9]+/ {
      match($0, /is C[0-9]+/); printf "%d\t\n", substr($0, RSTART + 4, RLENGTH - 4) + 0; exit
    }' "$1" 2>/dev/null)
  [ -n "$l" ] || return 1
  printf '%s\n' "$l"
}

slice_board_token() {
  local plan="${1:-}" tid="${2:-}" key="${3:-}" l t
  l=$(slice_board_line "$plan") || return 1
  t="${l#*$'\t'}"
  # "The build for THIS ticket is C<k>" names no ticket: the plan is this
  # build's own, so it is this ticket's.
  if [ -z "$t" ]; then printf '%s\n' "${tid:-$key}"; return 0; fi
  if { [ -n "$tid" ] && [ "$t" = "$tid" ]; } \
     || { [ -n "$key" ] && [ "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')" = "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ]; }; then
    printf '%s\n' "$t"; return 0
  fi
  printf '%s\n' "$t"
  # No ticket id to compare (the conductor knows only the KEY): a board id
  # token is a CANDIDATE, and the parent read in slice_board_settle decides,
  # because the board's answer must carry <KEY>. A KEY-shaped token that is
  # not <KEY> is another ticket's line.
  if [ -z "$tid" ] && [ -n "$key" ] && ! [[ "$t" =~ ^[A-Za-z]+-[0-9]+$ ]]; then return 0; fi
  return 2
}

# _sbd_alert <harness> <id> <msg> — one critical page through bin/lane-alert.sh.
_sbd_alert() {
  if [ -n "$1" ] && [ -x "$1/bin/lane-alert.sh" ]; then
    "$1/bin/lane-alert.sh" --severity critical --id "$2" slice-board "$3" >/dev/null 2>&1 || true
  else
    echo "slice-board: $3 (no bin/lane-alert.sh to page with)" >&2
  fi
}

# _sbd_word <dir> <word> <rc> — print the word, log it, return rc.
_sbd_word() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" >> "$1/settle.log" 2>/dev/null
  printf '%s\n' "$2"
  return "$3"
}

slice_board_settle() {
  local project="${1:-}" key="${2:-}" pr="${3:-}" rec="${4:-}" tid="${5:-}" park="${6:-1}" h="${7:-${HARNESS:-${H:-}}}"
  local d prn rc=0
  [ "$rec" = - ] && rec=""
  [ -n "$project" ] && [ -n "$key" ] && [[ "$pr" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+ ]] \
    || { printf 'skip:bad-args\n'; return 3; }
  case "$park" in 0|1) ;; *) park=1 ;; esac
  # The switch is BH-5961's, so one row turns both lanes off.
  # shellcheck source=bin/lib/lane-switch.sh
  command -v lane_switch >/dev/null 2>&1 || . "$_SBD_LIB/lane-switch.sh" 2>/dev/null
  if [ -n "$h" ] && command -v lane_switch >/dev/null 2>&1 && HARNESS="$h" lane_switch slice-remainder-off file; then
    printf 'skip:off\n'; return 3
  fi
  case "$(_slr_env "$h" SLICE_REMAINDER_FILE 1)" in 0|no|off|false) printf 'skip:off\n'; return 3 ;; esac
  prn="${pr##*/pull/}"; prn="${prn%%[!0-9]*}"
  if [ -n "$rec" ] && [ -d "$rec" ]; then d="$rec/slice-board"
  elif [ -n "$h" ]; then d="$h/state/slice-board/$project-$key-pr$prn"
  else printf 'skip:no-record\n'; return 3; fi
  mkdir -p "$d" 2>/dev/null || { printf 'deferred:record-write\n'; return 1; }
  # A DEDUPE, not a queue: the builder close-out and the conductor spawn share
  # this ledger, and the second one is answered by `filed`.
  if command -v flock >/dev/null 2>&1; then
    _sbd_settle_locked "$project" "$key" "$pr" "$rec" "$tid" "$park" "$h" "$d" "$prn" 9>"$d/.lock" || rc=$?
  else
    _sbd_settle_locked "$project" "$key" "$pr" "$rec" "$tid" "$park" "$h" "$d" "$prn" || rc=$?
  fi
  # A skip that decided nothing leaves no ledger behind: the conductor settles
  # every board merge, and most of them are not slices.
  [ "$rc" = 3 ] && [ ! -s "$d/children.json" ] && rm -rf "$d"
  return "$rc"
}

_sbd_settle_locked() {
  local project="$1" key="$2" pr="$3" rec="$4" tid="$5" park="$6" h="$7" d="$8" prn="$9"
  local plan="" w slug tok id raw prc=0 pkey why lib frc=0 want got keys base trc=0
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { printf 'deferred:locked\n'; return 1; }
  fi
  # LEDGER FIRST: a second settle is answered before any read or write.
  if [ -s "$d/filed" ]; then printf 'filed:%s\n' "$(head -1 "$d/filed")"; return 0; fi
  if [ -e "$d/unknown-paged" ]; then printf 'unknown:%s\n' "$(head -1 "$d/unknown-paged")"; return 2; fi

  # ---- the plan: the record's, else the merged spec on main --------------
  if [ -n "$rec" ] && [ -r "$rec/plan.md" ]; then plan="$rec/plan.md"
  elif [ -s "$d/plan.md" ]; then plan="$d/plan.md"
  else
    # shellcheck source=bin/lib/slice-closeout.sh
    command -v sco_plan_fetch >/dev/null 2>&1 || { [ -r "$_SBD_LIB/slice-closeout.sh" ] && . "$_SBD_LIB/slice-closeout.sh"; }
    command -v sco_plan_fetch >/dev/null 2>&1 || { _sbd_word "$d" deferred:no-plan-reader 1; return 1; }
    slug="${pr#https://github.com/}"; slug="${slug%%/pull/*}"
    # An empty record makes sco_plan_fetch read the PR and its merged
    # .harness/specs/<KEY>/plan.md, never a local plan.
    w=$(sco_plan_fetch "$slug" "${key##*-}" "$pr" "" "$d" 2>/dev/null)
    case "$w" in
      ok:*) [ "$(printf '%s' "${w#ok:}" | tr '[:lower:]' '[:upper:]')" = "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ] \
              || { rm -f "$d/plan.md"; _sbd_word "$d" skip:other-ticket 3; return 3; }
            plan="$d/plan.md" ;;
      none:*) _sbd_word "$d" skip:no-plan 3; return 3 ;;
      *)      _sbd_word "$d" deferred:plan-read 1; return 1 ;;
    esac
  fi

  # ---- is it a slice of THIS ticket ----------------------------------------
  tok=$(slice_board_token "$plan" "$tid" "$key") || trc=$?
  case "$trc" in
    0) ;;
    2) _sbd_word "$d" skip:other-ticket 3; return 3 ;;
    *) printf 'skip:no-slice\n'; return 3 ;;
  esac
  printf '%s\n' "$tok" > "$d/token"
  id="${tid:-$tok}"

  # ---- the parent: it must be the ticket the KEY names ---------------------
  # shellcheck source=bin/lib/tracker.sh
  command -v tracker_context >/dev/null 2>&1 || . "$_SBD_LIB/tracker.sh" 2>/dev/null
  if ! command -v tracker_context >/dev/null 2>&1 \
     || ! HARNESS="$h" tracker_context "$project" slice-board 2>/dev/null \
     || [ "${TRK_ADAPTER:-}" != board ]; then
    _sbd_alert "$h" "slice-board-failed:$project:$key:$prn" \
      "slice-board-failed $project/$key: PR $pr merged slice C$(cut -f1 <<<"$(slice_board_line "$plan")") but there is no board context (${TRK_CTX_MISSING:-adapter}); rerun bin/slice-board-settle.sh $project $key $pr ${rec:--} once it is fixed"
    _sbd_word "$d" deferred:board-context 1; return 1
  fi
  raw=$(TRK_DRY=0 TRK_LOG="" TRK_ERR="" trk_board_ticket_raw "$id") || prc=$?
  # curl -f answers 22 for an HTTP error: the id names no readable ticket.
  # Anything else is the transport, and the next tick reads it again.
  if [ "$prc" != 0 ] && [ "$prc" != 22 ]; then _sbd_word "$d" deferred:parent-read 1; return 1; fi
  pkey=$(printf '%s' "$raw" | jq -r '(.ticket // .) | .key // empty | tostring' 2>/dev/null)
  why=""
  if [ "$prc" = 22 ] || [ -z "$pkey" ]; then why="parent"
  elif [ "$(printf '%s' "$pkey" | tr '[:lower:]' '[:upper:]')" != "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" ]; then why="parent"; fi

  # ---- the spec, decided once per ledger ------------------------------------
  if [ -z "$why" ] && [ ! -s "$d/children.json" ]; then
    w=$(slice_remainder_parse "$plan" "${tok:-$id}" "$d/children.json.tmp" "$pr" 2>>"$d/parse.log")
    if [ "${w%%:*}" = ok ]; then mv -f "$d/children.json.tmp" "$d/children.json"
    else rm -f "$d/children.json.tmp"; why="${w:-bad:parse}"; fi
  fi
  if [ -n "$why" ]; then
    # The page goes BEFORE the marker: a crash between them pages twice, and
    # the --id collapses that. It is never silent.
    _sbd_alert "$h" "slice-board-unknown:$project:$key:$prn" \
      "SLICE_BOARD_UNKNOWN $project/$key: PR $pr merged a slice but the remaining slices cannot be filed ($why${pkey:+, parent key $pkey}); file them as child tickets by hand"
    printf '%s\n' "$why" > "$d/unknown-paged"
    _sbd_word "$d" "unknown:$why" 2; return 2
  fi

  # ---- file the children ----------------------------------------------------
  lib="$_SBD_LIB"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-board.sh" ] || lib="$h/bin/lib"
  [ -r "$lib/file-children.sh" ] && [ -r "$lib/fc-board.sh" ] || { _sbd_word "$d" skip:no-filer 3; return 3; }
  base=$(( $(jq '.[0].ordinal' "$d/children.json") - 1 ))
  # A SUBSHELL: the filer sources its own libs and sets FC_* and TRK_*, and
  # none of that may leak into the lane that called this.
  (
    # shellcheck source=bin/lib/file-children.sh
    . "$lib/file-children.sh" || exit 1
    # shellcheck source=bin/lib/fc-board.sh
    . "$lib/fc-board.sh" || exit 1
    HARNESS="$h" FC_PROJECT="$project" FC_PARENT="$id" FC_KEY="$key" FC_BUILD="$d" \
      FC_SPEC="$d/children.json" FC_KIND=slice FC_LANE=board
    FC_SLICE_BASE="$base" FC_SLICE_PR="$pr" FC_BOARD_PARK="$park"
    export HARNESS FC_SLICE_BASE FC_SLICE_PR FC_BOARD_PARK
    fc_file_board || { printf '%s\n' "${FC_ERROR:-fc_file_board failed}" > "$d/fc-error.txt"; exit 1; }
    fc_dry && exit 10
    exit 0
  ) >>"$d/fc-out.txt" 2>&1 || frc=$?
  [ "$frc" = 10 ] && { _sbd_word "$d" skip:dry-run 3; return 3; }
  want=$(jq 'length' "$d/children.json" 2>/dev/null)
  got=$(grep -cE '^[A-Za-z]+-[0-9]+$' "$d/children.txt" 2>/dev/null)
  if [ "$frc" = 0 ] && [ -n "$want" ] && [ "${got:-0}" = "$want" ]; then
    keys=$(grep -E '^[A-Za-z]+-[0-9]+$' "$d/children.txt" | paste -sd, -)
    printf '%s\n' "$keys" > "$d/filed"
    _sbd_word "$d" "filed:$keys" 0; return 0
  fi
  [ -s "$d/fc-error.txt" ] || printf 'the filer filed %s of %s children (rc %s)\n' "${got:-0}" "${want:-?}" "$frc" > "$d/fc-error.txt"
  _sbd_alert "$h" "slice-board-failed:$project:$key:$prn" \
    "slice-board-failed $project/$key: filing the remaining slices of PR $pr did not finish ($(head -c 300 "$d/fc-error.txt")); rerun bin/slice-board-settle.sh $project $key $pr ${rec:--} --ticket $id, it resumes from $d"
  _sbd_word "$d" deferred:file-failed 1
  return 1
}

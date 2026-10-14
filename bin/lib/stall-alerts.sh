#!/bin/bash
# bin/lib/stall-alerts.sh — two stalls that sat silent (BH-6308). The judges
# bin/pipeline-health.sh's `# >>> stall alerts` block pages on.
#
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
# Safe under `set -u`. The root is ${HARNESS:-${H:-}}, nothing else.
#
# WHAT HAPPENED. #6000 sat on a HOLD for a day that named "the Mac lead session
# (fix-5129)": no such session was running, nothing measured the age of the
# HOLD, and the stuck-work classifier reads a held ticket as waiting. #5240 kept
# its hard dependents blocked after its last slice merged, and nothing joined a
# hard Blocked-by to its parent's merged slices.
#
#   stall_knob <NAME>                         a knob, clamped (catalog/lanes.d/_lib.stall-alerts.json)
#   stall_hold_candidates <slug>              the search items; rc 0 · 1 read failed · 2 page-cut
#   stall_hold_judge <issue> <comments> <now> PURE: stale<TAB>age<TAB>at<TAB>author<TAB>line rc 0
#                                             · fresh|clear|other rc 1 · other<TAB>unreadable rc 2
#   stall_owner_active <project> <slug> <n> <key> <line> <now> <prs-json|?> <participants-json|?>
#                                             active<TAB>why rc 0 · inactive<TAB>notes rc 1
#   stall_hard_blockers <body>                each hard Blocked-by parent number, one per line
#   stall_parent_judge <project> <slug> <child> <parent> <now> <open-issues-json> <prs-json|?> [key-prefix]
#                                             stale<TAB>pr-url<TAB>age rc 0 · ok<TAB>why rc 1 · unknown<TAB>why rc 2
#
# AN UNREADABLE SOURCE IS NEVER "CLEAR" AND NEVER "ACTIVE" (D9-D11). The owner
# check notes it and keeps looking; the parent judge answers unknown, and the
# block carries that key instead of retracting it.

_STALL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/hold.sh
command -v hold_classify >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/hold.sh"
# shellcheck source=bin/lib/dep-verify-lib.sh
command -v dep_declared_hard >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/dep-verify-lib.sh"
# shellcheck source=bin/lib/slice-prs.sh
command -v slice_merged_prs >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/slice-prs.sh"
# shellcheck source=bin/lib/issue-state-lib.sh
command -v _issue_open_children >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/issue-state-lib.sh"
# shellcheck source=bin/lib/preplan-lib.sh
command -v preplan_key_prefix >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/preplan-lib.sh"

# stall_knob <NAME> — settings row > env > the registry default, through
# lib_env_apply in a subshell (its fail-closed exit cannot end the caller), the
# sp_knob shape. Hour knobs are whole numbers >= 1, else the default. Switches
# are 0 or 1 (anything but 0 reads 1). STALL_MAX_THREADS is 1..100.
stall_knob() {
  local name="${1:-}" v
  v=$(
    exec 3>&1
    # shellcheck disable=SC2016 # expanded by the trap, at exit
    trap 'printf "%s" "${!name:-}" >&3' EXIT
    command -v lib_env_apply >/dev/null 2>&1 || . "$_STALL_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    lib_env_apply stall-alerts >/dev/null 2>&1) || true
  case "$name" in
    STALL_HOLD_CHECK|STALL_PARENT_CHECK) case "$v" in 0) printf '0\n' ;; *) printf '1\n' ;; esac ;;
    STALL_HOLD_MAX_H|STALL_OWNER_WINDOW_H)
      case "$v" in ''|*[!0-9]*) v=12 ;; esac; [ "$v" -ge 1 ] 2>/dev/null || v=12; printf '%s\n' "$((10#$v))" ;;
    STALL_HOLD_HOTFIX_H|STALL_PARENT_MERGED_H)
      case "$v" in ''|*[!0-9]*) v=3 ;; esac; [ "$v" -ge 1 ] 2>/dev/null || v=3; printf '%s\n' "$((10#$v))" ;;
    STALL_MAX_THREADS)
      case "$v" in ''|*[!0-9]*) v=30 ;; esac; [ "$v" -ge 1 ] 2>/dev/null || v=30
      [ "$v" -gt 100 ] && v=100; printf '%s\n' "$((10#$v))" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# _stall_arm <slug> — the App-token arming slice-prs.sh and issue-state-lib.sh
# do before a read (a no-op on a box without gh-app-auth.sh).
_stall_arm() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"; return 0; }

# _stall_epoch <iso> — epoch seconds, or nothing (rc 1) for an unparseable time.
_stall_epoch() {
  [ -n "${1:-}" ] || return 1
  jq -nr --arg t "$1" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null
}

# _stall_ticket_prs <prs-json> <key> — the open PRs of the ticket, one
# `number<TAB>head-sha` per line: the title leads with the key, or the head ref
# starts with ticket/<key lowercased> (A2), its rebuild form ticket/<key>-r<k>
# included (BH-3835). Word-bounded, so BH-5 is not BH-50.
_stall_ticket_prs() {
  printf '%s' "${1:-}" | jq -r --arg k "${2:-}" '
    ($k | ascii_downcase) as $lk
    | ("^[ \t\\[]*" + $k + "([^0-9]|$)") as $tre
    | ("^ticket/" + $lk + "(-r[0-9]+)?([^0-9]|$)") as $rre
    | .[] | select(type == "object")
    | select(((.title // "") | test($tre; "i")) or (((.head.ref // "") | ascii_downcase) | test($rre)))
    | [ (.number | tostring), (.head.sha // "") ] | @tsv' 2>/dev/null
}

# stall_hold_candidates <slug> — ONE search read. Prints the items array,
#   oldest-updated first (sort=updated&order=asc): a thread a person touched
#   lately, a RESUME for one, falls behind the stale ones, so the
#   STALL_MAX_THREADS cut keeps the threads most likely to be stale (lead
#   review lr-6333 of 65b1c1765).
stall_hold_candidates() {
  local slug="${1:-}" body
  [ -n "$slug" ] && command -v gh_rest >/dev/null 2>&1 || return 1
  body=$(_stall_arm "$slug"; gh_rest GET "search/issues?q=repo:$slug+is:issue+is:open+label:ai-build+HOLD+in:comments&sort=updated&order=asc&per_page=100" 2>/dev/null) || return 1
  printf '%s' "$body" | jq -ec '.items | if type == "array" then . else error("no items") end' 2>/dev/null || return 1
  [ "$(printf '%s' "$body" | jq -r '.total_count // 0' 2>/dev/null)" -gt 100 ] 2>/dev/null && return 2
  return 0
}

# stall_hold_judge <issue-json> <comments-json> <now> — PURE. Only a comment
# HOLD goes on: the newest decisive comment, from hold_classify.
stall_hold_judge() {
  local ij="${1:-}" cj="${2:-}" now="${3:-}" v r why at line at_e age author thr
  v=$(hold_classify "$ij" "$cj"); r=$?
  [ "$r" = 2 ] && { printf 'other\tunreadable\n'; return 2; }
  [ "$r" = 0 ] && { printf 'clear\t%s\n' "${v#*	}"; return 1; }
  why="${v#*	}"
  case "$why" in
    "hold:comment "*) ;;
    *) printf 'other\t%s\n' "$why"; return 1 ;;
  esac
  why="${why#hold:comment }"; at="${why%% *}"
  line=""; [ "$why" != "$at" ] && line="${why#* }"
  at_e=$(_stall_epoch "$at") || { printf 'other\tunreadable at %s\n' "$at"; return 2; }
  case "$at_e" in ''|*[!0-9]*) printf 'other\tunreadable at %s\n' "$at"; return 2 ;; esac
  author=$(printf '%s' "$cj" | jq -r --arg at "$at" '
    [ .[] | select(type == "object" and (.created_at // "") == $at
               and (((.user // {}).type // "") | ascii_downcase) != "bot")
      | (.user.login // "") ] | first // ""' 2>/dev/null)
  if printf '%s' "$ij" | jq -e '[(.labels // [])[] | if type == "object" then .name else . end] | index("hotfix") != null' >/dev/null 2>&1; then
    thr=$(stall_knob STALL_HOLD_HOTFIX_H)
  else
    thr=$(stall_knob STALL_HOLD_MAX_H)
  fi
  age=$(( now - at_e ))
  if [ "$age" -gt $(( thr * 3600 )) ]; then
    printf 'stale\t%s\t%s\t%s\t%s\n' "$age" "$at" "${author:-unknown}" "$line"; return 0
  fi
  printf 'fresh\t%s\n' "$age"; return 1
}

# stall_owner_active <project> <slug> <n> <key> <line> <now> <prs-json|?> <participants-json|?>
stall_owner_active() {
  local p="${1:-}" slug="${2:-}" key="${4:-}" line="${5:-}" now="${6:-}" prs="${7:-?}" part="${8:-?}"
  local win notes="" hit job rows num sha c ce
  win=$(( $(stall_knob STALL_OWNER_WINDOW_H) * 3600 ))
  # (a) an approved participant named in the line, seen inside online_window_s.
  if [ "$part" = "?" ] || ! printf '%s' "$part" | jq -e '(.participants | type) == "array"' >/dev/null 2>&1; then
    notes="participants unreadable"
  else
    hit=$(printf '%s' "$part" | jq -r --arg l "$line" --argjson now "$now" '
      (.online_window_s // 0) as $w
      | [ .participants[] | select(type == "object" and (.name // "") != "")
          | select((.last_seen_at // "") != "")
          | select(($now - (.last_seen_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) <= $w)
          | select(.name as $n | ($n | gsub("(?<c>[.*+?^${}()|\\[\\]\\\\/-])"; "\\\(.c)")) as $e
                   | $l | test("(^|[^A-Za-z0-9_-])" + $e + "([^A-Za-z0-9_-]|$)"; "i"))
          | .name ] | first // empty' 2>/dev/null) || hit=""
    [ -n "$hit" ] && { printf 'active\tparticipant %s live\n' "$hit"; return 0; }
  fi
  # (b) the newest build row for the key: open, or touched inside the window.
  if command -v _jobs_req >/dev/null 2>&1 && job=$(_jobs_req GET "/api/jobs?project=$p&ticket_id=$key&kind=build&limit=1" 2>/dev/null) \
     && printf '%s' "$job" | jq -e '(.jobs | type) == "array"' >/dev/null 2>&1; then
    hit=$(printf '%s' "$job" | jq -r --argjson now "$now" --argjson w "$win" '
      .jobs[0] // empty
      | if ((.status // "") | IN("queued", "claimed", "running")) then "build " + .status
        else [ .created_at, .updated_at, .last_beat_at
               | select(type == "string" and . != "")
               | (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) ] as $ts
          | if ($ts | length) > 0 and ($now - ($ts | max)) <= $w then "build " + (.status // "?") + " inside the window" else empty end
        end' 2>/dev/null) || hit=""
    [ -n "$hit" ] && { printf 'active\t%s\n' "$hit"; return 0; }
  else
    notes="${notes:+$notes, }jobs unreadable"
  fi
  # (c) an open PR of the ticket whose head commit was pushed inside the window.
  if [ "$prs" = "?" ] || ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    notes="${notes:+$notes, }PRs unreadable"
  else
    rows=$(_stall_ticket_prs "$prs" "$key")
    while IFS=$'\t' read -r num sha; do
      [ -n "${num:-}" ] || continue
      [ -n "${sha:-}" ] || { notes="${notes:+$notes, }PR #$num head unreadable"; continue; }
      c=$(_stall_arm "$slug"; gh_rest GET "repos/$slug/commits/$sha" 2>/dev/null) \
        && ce=$(_stall_epoch "$(printf '%s' "$c" | jq -r '.commit.committer.date // empty' 2>/dev/null)") \
        && [ -n "$ce" ] || { notes="${notes:+$notes, }head $sha unreadable"; continue; }
      [ $(( now - ce )) -le "$win" ] && { printf 'active\tPR #%s pushed inside the window\n' "$num"; return 0; }
    done <<<"$rows"
  fi
  printf 'inactive\t%s\n' "$notes"; return 1
}

# stall_hard_blockers <body> — each #N on a Blocked-by line that
# dep_declared_hard accepts as hard.
stall_hard_blockers() {
  local f n
  f=$(mktemp "${TMPDIR:-/tmp}/stall-body.XXXXXX") || return 1
  printf '%s\n' "${1:-}" > "$f"
  for n in $(grep -iE '^[[:space:]>*_#-]*blocked[- ]by\b' "$f" | grep -oE '#[0-9]+' | tr -d '#' | sort -nu); do
    dep_declared_hard "$n" "$f" && printf '%s\n' "$n"
  done
  rm -f "$f"
  return 0
}

# stall_parent_judge <project> <slug> <child> <parent> <now> <open-issues-json> <prs-json|?> [key-prefix]
stall_parent_judge() {
  local p="${1:-}" slug="${2:-}" par="${4:-}" now="${5:-}" open="${6:-}" prs="${7:-?}" pfx="${8:-}"
  local h="${HARNESS:-${H:-}}" st kids sl newest url age job
  [ -n "$pfx" ] || pfx=$(preplan_key_prefix "$h" "$p" 2>/dev/null) || { printf 'unknown\tno key prefix\n'; return 2; }
  # The parent is closed: from the open list, else one issue read.
  if ! printf '%s' "$open" | jq -e --argjson n "$par" 'any(.[]; .number == $n)' >/dev/null 2>&1; then
    st=$(_stall_arm "$slug"; gh_rest GET "repos/$slug/issues/$par" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
    case "$st" in
      closed) printf 'ok\tclosed\n'; return 1 ;;
      open) ;;
      *) printf 'unknown\tparent state unreadable\n'; return 2 ;;
    esac
  fi
  kids=$(_issue_open_children "$slug" "$par" "$h") || { printf 'unknown\tchildren %s\n' "$kids"; return 2; }
  [ -z "$kids" ] || { printf 'ok\tchildren %s\n' "$kids"; return 1; }
  sl=$(slice_merged_prs "$slug" "$par" "$h") || { printf 'unknown\tslices %s\n' "$sl"; return 2; }
  [ -n "$sl" ] || { printf 'ok\tno-slice\n'; return 1; }
  IFS=$'\t' read -r newest url _ <<<"$(head -n 1 <<<"$sl")"
  case "$newest" in ''|*[!0-9]*) printf 'unknown\tslices unparseable\n'; return 2 ;; esac
  age=$(( now - newest ))
  [ "$age" -gt $(( $(stall_knob STALL_PARENT_MERGED_H) * 3600 )) ] || { printf 'ok\tmerged %ss ago\n' "$age"; return 1; }
  if [ "$prs" = "?" ] || ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'unknown\tPRs unreadable\n'; return 2
  fi
  [ -z "$(_stall_ticket_prs "$prs" "$pfx-$par")" ] || { printf 'ok\tpr\n'; return 1; }
  command -v _jobs_req >/dev/null 2>&1 && job=$(_jobs_req GET "/api/jobs?project=$p&ticket_id=$pfx-$par&kind=build&limit=1" 2>/dev/null) \
    && printf '%s' "$job" | jq -e '(.jobs | type) == "array"' >/dev/null 2>&1 \
    || { printf 'unknown\tjobs unreadable\n'; return 2; }
  printf '%s' "$job" | jq -e '(.jobs[0].status // "") | IN("queued", "claimed", "running")' >/dev/null 2>&1 \
    && { printf 'ok\tbuild\n'; return 1; }
  printf 'stale\t%s\t%s\n' "$url" "$age"; return 0
}

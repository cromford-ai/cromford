#!/bin/bash
# bin/lib/untriaged-board-read.sh — the in-app board read shared by the
# untriaged lanes (BH-2756): the client apps' own boards, which have no GitHub
# issue list. It was the body of sweep() in bin/untriaged-sweep.sh; it lives
# here so bin/untriaged-digest.sh counts the same tickets the sweep alerts on.
# Sourced, never executed.
#
# WHICH boards is not this file's question. There is no project table here:
# the caller passes base, token and prefix, and the digest takes the project
# list from bin/fleet-conf.sh --projects-with-board (the registry), so a
# project enrolled later is read without anyone editing this file.
#
# A FAILED READ IS NEVER "NO TICKETS" (D9). ut_inapp_untriaged prints nothing
# and returns 1 when either request fails or answers something that is not a
# board; rc 0 with no rows is a real empty result.
#
# No `set -e`, no `exit`, no side effect at source time, `set -u` safe.
if [ -n "${UNTRIAGED_BOARD_READ_LIB:-}" ]; then return 0 2>/dev/null; fi
UNTRIAGED_BOARD_READ_LIB=1

UT_INAPP_CUTOFF="${UT_INAPP_CUTOFF:-2026-07-29T00:00:00Z}"   # ignore legacy pre-verdict-era tickets

# ut_inapp_untriaged <project> <base> <token> <prefix> <min_age_s> —
# `<id>\t<number>\t<ts>\t<title>` for every client-filed todo ticket with no
# triage verdict whose last activity (else creation) is after the cutoff and
# more than min_age_s ago.
ut_inapp_untriaged() {
  local base="${2:-}" tok="${3:-}" pfx="${4:-}" min="${5:-}" bid tmp out="" rc=0
  [ -n "$base" ] && [ -n "$tok" ] || return 1
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  bid=$(curl -s --fail --max-time 20 -H "Authorization: Bearer $tok" "$base$pfx/boards" 2>/dev/null) || return 1
  bid=$(jq -r 'if type=="array" then .[0].id else .boards[0].id end' <<<"$bid" 2>/dev/null)
  [ -n "$bid" ] && [ "$bid" != "null" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/utb.XXXXXX") || return 1
  curl -s --fail --max-time 30 -H "Authorization: Bearer $tok" "$base$pfx/boards/$bid/tickets" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ] && jq -e 'type=="array" or (type=="object" and (.tickets|type)=="array")' "$tmp" >/dev/null 2>&1; then
    out=$(jq -r --arg c "$UT_INAPP_CUTOFF" --argjson min "$min" '
        (if type=="array" then . else .tickets end)
        | .[] | select(.status == "todo" and .triageVerdict == null)
        | (.lastActivityAt // .createdAt // "") as $ts
        | select($ts > $c)
        | select((.reporter.userId // .reporterId // "") != "system")
        | select(((now - (($ts | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601?) // now))) > $min)
        | [.id, .number, $ts, (.title[0:70])] | @tsv' "$tmp" 2>/dev/null) || rc=1
  else
    rc=1
  fi
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1
  [ -z "$out" ] || printf '%s\n' "$out"
}

# ut_trk_untriaged <project> <min_age_s> [now_epoch] — the Jira/Linear twin of
# ut_inapp_untriaged (BH-8451): the open build-labelled list through the
# tracker contract (bin/lib/trk-lane.sh). `<key>\t<key>\t<updatedAt>\t<title>`
# for every row with commentCount 0 (a null count is not 0, D11), no triage
# verdict, and an updatedAt after UT_INAPP_CUTOFF and more than min_age_s
# before now. now_epoch is the test seam (default: the clock). The root is
# HARNESS, then H; with neither, rc 1. A failed read is rc 1 and no output.
ut_trk_untriaged() {
  local p="${1:-}" min="${2:-}" now="${3:-}" root="${HARNESS:-${H:-}}" d tl out
  [ -n "$p" ] && [ -n "$root" ] || return 1
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$now" ] || now=$(date -u +%s)
  case "$now" in *[!0-9]*) return 1 ;; esac
  if ! command -v trk_lane_list >/dev/null 2>&1; then
    d=$(dirname "${BASH_SOURCE[0]}")
    # shellcheck source=bin/lib/trk-lane.sh
    . "$d/trk-lane.sh" 2>/dev/null || . "$root/bin/lib/trk-lane.sh" 2>/dev/null || return 1
  fi
  tl=$(trk_lane_list "$root" "$p" untriaged --state open 2>/dev/null) || return 1
  out=$(printf '%s' "$tl" | jq -r --arg c "$UT_INAPP_CUTOFF" --argjson min "$min" --argjson now "$now" '
      .[] | select(.state == "open" and .commentCount == 0 and .triageVerdict == null)
      | select((.updatedAt | type) == "string" and .updatedAt > $c)
      | select(((.updatedAt | fromdateiso8601?) // null) as $u | $u != null and ($now - $u) > $min)
      | [.key, .key, .updatedAt, ((.title // "")[0:70])] | @tsv' 2>/dev/null) || return 1
  [ -z "$out" ] || printf '%s\n' "$out"
}

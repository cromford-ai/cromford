# bin/lib/lead-step-done.sh — BH-6696: is the builder's refusal of a PR head
# answered by a person's HUMAN-STEP-DONE? Sourced by bin/lead-review-enqueue.sh,
# never executed. A builder REQUEST_CHANGES that raised a NEEDS-HUMAN step stays
# on the head, the pool skips the ticket (an open PR exists), and no fix round
# pushes. Once a person answers the step, the enqueue asks for the lead review
# on the same head (#6648 and #6620 waited 80 minutes on 2026-10-14).
#
#   lsd_answer <thread-json> <since-iso>
#     Pure (jq). The thread is a REST issue-comments array. Oldest first by
#     created_at, the REST index breaks ties (nh_release_evidence's rule). The
#     marker is the NEWEST comment whose first non-blank line starts
#     NEEDS-HUMAN: (any author). The answer is the newest NON-bot comment after
#     it, created strictly after <since>, whose first non-blank line starts
#     HUMAN-STEP-DONE: (kind done), or starts with the capital word RESUME
#     (kind resume) when no negation (HOLD_NEG_RE) and no condition after the
#     word ("RESUME once #12 merges") is in it. rc 0 prints `comment: <url>`,
#     `author: @<login> at <created_at>`, `kind: <kind>`, then the body's first
#     40 lines. rc 1 = no marker or no answer. rc 2 = the thread is not an
#     array, or <since> is not YYYY-MM-DDTHH:MM:SSZ.
#   lsd_verdict_at <pr-url>
#     The builder verdict artifact's updated_at (GET /api/verdict), cut to
#     YYYY-MM-DDTHH:MM:SSZ. rc 2 when the read fails or the field is absent or
#     not ISO.
#   lsd_check <slug> <pr-json-file> <pr-url> [<word>]
#     PR -> ticket issue (to_pr_issue) -> verdict time -> thread
#     (_nh_rel_thread) -> lsd_answer. rc 0 sets LSDNOTE (one line, at most 600
#     chars: `human step answered after the builder's <word>: <url> by @<login>
#     at <at>: <body lines joined by " / ">`) and LSDLOG (`<url> (@<login> at
#     <at>)`). rc 1 = not answered. rc 2 sets LSDWHY (what could not be read).
#     A missing helper is rc 2.
# shellcheck shell=bash

# shellcheck source=bin/lib/needs-human/release.sh
. "$(dirname "${BASH_SOURCE[0]}")/needs-human/release.sh" 2>/dev/null || true
# shellcheck source=bin/lib/hold.sh
. "$(dirname "${BASH_SOURCE[0]}")/hold.sh" 2>/dev/null || true

# A condition right after the lift word holds it back: "RESUME once #12 merges".
# HOLD_NEG_RE only reads a negation in FRONT of the word.
LSD_COND_RE='(?i:^RESUME(\W+\w+){0,3}?\W+(once|until|unless|if|when|after|before)(?![A-Za-z]))'
LSD_ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

lsd_answer() { # lsd_answer <thread-json> <since-iso>
  local thread="${1:-}" since="${2:-}" out rc=0
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 2
  printf '%s' "$thread" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  out=$(printf '%s' "$thread" | jq -r --arg since "$since" --arg iso "$LSD_ISO_RE" \
    --arg neg "${HOLD_NEG_RE:-(?!)}" --arg cond "$LSD_COND_RE" '
    [ to_entries[] | select((.value | type) == "object")
      | ((.value.body // "") | tostring | gsub("\r"; "")) as $b
      | { b: $b, i: .key,
          at: ((.value.created_at // "") | tostring),
          url: ((.value.html_url // "") | tostring),
          who: (((.value.user // {}).login // "") | tostring),
          bot: ((((.value.user // {}).type // "") | tostring | ascii_downcase) == "bot"),
          first: ([ $b | split("\n")[] | sub("^[ \t]+"; "") | select(length > 0) ] | first // "") }
      | . + { k: (if (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) then .at else "" end) }
    ] | sort_by([.k, .i]) as $s
    | ([ range(0; $s | length) | select($s[.].first | startswith("NEEDS-HUMAN:")) ] | last) as $m
    | if $m == null then empty else
        [ $s[($m + 1):][] | select(.bot | not) | select((.at | test($iso)) and .at > $since)
          | if (.first | startswith("HUMAN-STEP-DONE:")) then . + {kind: "done"}
            elif (.first | test("^RESUME(?![A-Za-z0-9_?-])")) and ((.b | test($neg)) | not)
                 and ((.first | test($cond)) | not) then . + {kind: "resume"}
            else empty end ]
        | last // empty
        | "comment: \(.url)", "author: @\(.who) at \(.at)", "kind: \(.kind)", (.b | split("\n") | .[:40][])
      end' 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

lsd_verdict_at() { # lsd_verdict_at <pr-url>
  local q v at
  command -v _jobs_req >/dev/null 2>&1 || return 2
  q=$(jq -rn --arg u "${1:-}" '$u | @uri') || return 2
  v=$(JOBS_ALERT=0 _jobs_req GET "/api/verdict?pr=$q" 2>/dev/null) || return 2
  at=$(printf '%s' "$v" | jq -r '[.artifacts[]? | select(.artifact_kind == "verdict") | .updated_at // ""] | first // ""
    | tostring | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then .[0:19] + "Z" else "" end' 2>/dev/null)
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 2
  printf '%s\n' "$at"
}

lsd_check() { # lsd_check <slug> <pr-json-file> <pr-url> [<word>]
  local slug="${1:-}" pf="${2:-}" url="${3:-}" word="${4:-verdict}" issue since thread ans rc=0 curl who at body
  LSDNOTE=""; LSDLOG=""; LSDWHY=""
  local f
  for f in to_pr_issue _nh_rel_thread _jobs_req; do
    command -v "$f" >/dev/null 2>&1 || { LSDWHY="no $f loaded"; return 2; }
  done
  issue=$(to_pr_issue "$(cat "$pf" 2>/dev/null)") || { LSDWHY="no ticket issue in the PR body or branch"; return 2; }
  since=$(lsd_verdict_at "$url") || { LSDWHY="the builder verdict time is unreadable"; return 2; }
  thread=$(_nh_rel_thread "$slug" "$issue") || { LSDWHY="the thread of #$issue is unreadable"; return 2; }
  ans=$(lsd_answer "$thread" "$since") || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) LSDWHY="the thread of #$issue could not be parsed"; return 2 ;;
  esac
  curl=$(sed -n '1s/^comment: //p' <<<"$ans")
  who=$(sed -n '2s/^author: @\(.*\) at .*$/\1/p' <<<"$ans")
  at=$(sed -n '2s/^author: @.* at //p' <<<"$ans")
  body=$(sed '1,3d' <<<"$ans" | tr '\t' ' ' | awk '{ gsub(/^ +| +$/, "") } NF { printf "%s%s", (n++ ? " / " : ""), $0 }')
  LSDNOTE="human step answered after the builder's $word: $curl by @$who at $at: $body"
  LSDNOTE=${LSDNOTE:0:600}
  LSDLOG="$curl (@$who at $at)"
  return 0
}

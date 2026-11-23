#!/bin/bash
# bin/lib/mc/review-block-park.sh — BH-9260: a machine review BLOCK on a READY
# head becomes a blocked-resolver park. Sourced by bin/lib/merge-conductor-lib.sh
# (optional, like mc/block-ci.sh), never executed.
#
# THE GAP. The block gate (bin/merge-conductor.sh `# >>> block gate`) refuses a
# READY head on a BLOCK comment and writes no row (BH-762). A person's BLOCK
# must wait for that person. A MACHINE review BLOCK (the >12h review autopilot,
# a harness App) has nobody to wait for: example-org/project-4-site#4 logged 22
# `MERGE_REFUSED block-gate` ticks and the resolver saw 0 candidates.
#
# THE PARK. When the refused block is a machine review comment bound to this
# head (mc_rbp_eligible) and the CI-block hook declined it, the row moves to
#   BLOCKED_HUMAN  review-block: <comment id> <first [BLOCK …] tag> <comment url>
# on the same tick. mc_resolver_owns and mc_handoff_owns accept `review-block*`,
# so the row reads BLOCKED_AGENT, never pages, and is sticky until the head
# moves. bin/lib/br/ladder.sh maps it to head-not-reapproved (fix round first).
#
# THE RELEASE. Each later tick re-reads the thread for a parked row
# (mc_rbp_unpark on the sticky branch, mc_rbp_hold before the main transition
# once the resolver released the hand-off). A clean bg_scan_read (the same
# author's UNBLOCK / CLEARED / later head-bound VERDICT, a lead/human MERGE row
# lifting a machine block), enforcement off or the knob off release the park,
# and the row classifies READY on that same tick.
#
# Knobs (catalog/lanes.d/merge-conductor.knobs.d/):
#   MC_REVIEW_BLOCK_PARK         1 = park (default); 0 = BH-762 behaviour, and
#                                every existing park releases on its recheck
#   MC_REVIEW_BLOCK_STUCK_TICKS  refusals of an unparked machine BLOCK before
#                                one warn alert (default 2: alert on the 3rd)

# mc_rbp_knob <ENV> <fallback> — the knob through lane_knob, else the env, else
#   the fallback. Every caller validates the shape.
mc_rbp_knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob merge-conductor "$1" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# mc_rbp_on — rc 0 when the park is on. Fallback 1 is the documented default of
#   catalog/lanes.d/merge-conductor.knobs.d/MC_REVIEW_BLOCK_PARK.json.
mc_rbp_on() { [ "$(mc_rbp_knob MC_REVIEW_BLOCK_PARK 1)" = 1 ]; }

# mc_rbp_tag <body> — the first `[BLOCK …]` tag of the body, else `[BLOCK]`.
mc_rbp_tag() {
  local b="${1:-}" re
  re='\[BLOCK[^]'$'\n'']{0,80}\]'
  if [[ "$b" =~ $re ]]; then printf '%s' "${BASH_REMATCH[0]}"; else printf '[BLOCK]'; fi
}

# mc_rbp_why <id> <tag> <url> — the pr-state reason, one line, no tab.
mc_rbp_why() {
  local w="review-block: ${1:-?} ${2:-[BLOCK]} ${3:--}"
  w="${w//$'\t'/ }"; w="${w//$'\r'/}"; w="${w//$'\n'/ }"
  printf '%s' "$w"
}

# mc_rbp_trusted <login> <body> <head> — rc 0 when this comment is the review
#   autopilot's own BLOCK of THIS head. BOTH must hold, for every login:
#     1. the author is the harness's own identity (harness_own_review_match):
#        a verdict author (harness_verdict_author_match, an App in the trust
#        set) or the bare operator login the PAT posts under;
#     2. the body carries `<!-- harness-review-autopilot <head12> -->` for
#        exactly this head.
#   An App login alone is NOT a credential here (BH-9260 lead review): any
#   `*[bot]` (github-actions[bot], dependabot[bot], a third-party App) can post
#   a line starting BLOCK, and this check gates both the park (an agent fix
#   round) and mc_rbp_brief (the round's instructions). That is the BH-1992
#   rule: only a verdict author's comment is a brief. A person's BLOCK, a
#   stranger or another bot pasting the marker, a marker for another head, an
#   unreadable author or a short head answer 1: BH-762 behaviour (refused, not
#   parked, never a brief). Fail closed when the trust set is not loaded.
mc_rbp_trusted() {
  local login="${1:-}" body="${2:-}" head="${3:-}" h12
  case "$login" in ''|-) return 1 ;; esac
  h12="${head:0:12}"
  [ "${#h12}" -eq 12 ] || return 1
  case "$h12" in *[!0-9a-f]*) return 1 ;; esac
  command -v harness_own_review_match >/dev/null 2>&1 || return 1
  harness_own_review_match "$login" || return 1
  case "$body" in *"<!-- harness-review-autopilot ${h12} -->"*) return 0 ;; esac
  return 1
}

# mc_rbp_read <slug> <num> <id> — the comment (else the review) by id, as
#   "<login>\t<html_url>\n<body>". rc 0 read; 44 no such comment or review;
#   75 unreadable. One GET through gh_rest, a second only on a 404.
mc_rbp_read() {
  local slug="$1" num="$2" id="$3" j="" rc=0 head
  command -v mc_rest_var >/dev/null 2>&1 || return 75
  mc_rest_var j gh_rest GET "repos/$slug/issues/comments/$id" || rc=$?
  if [ "$rc" = 44 ]; then
    rc=0; mc_rest_var j gh_rest GET "repos/$slug/pulls/$num/reviews/$id" || rc=$?
  fi
  [ "$rc" = 0 ] || return "$rc"
  head=$(jq -r '[(.user.login // "-"), (.html_url // "-")] | @tsv' <<<"$j" 2>/dev/null) || return 75
  [ -n "$head" ] || return 75
  printf '%s\n' "$head"
  jq -r '.body // ""' <<<"$j" 2>/dev/null || return 75
}

# mc_rbp_eligible <slug> <num> <head> <bg_scan line> — prints yes | no | unknown
#   and sets MC_RBP_ELIG (the same word), MC_RBP_BODY (the block's body) and
#   MC_RBP_LOGIN. `unknown` = the body could not be read this tick (nothing
#   parks on an unread body). Call it WITHOUT $(…) to keep the variables.
mc_rbp_eligible() {
  local slug="$1" num="$2" head="$3" line="${4:-}" url login at id txt rc=0 rlogin
  MC_RBP_BODY=""; MC_RBP_LOGIN=""; MC_RBP_ELIG=no
  IFS=$'\t' read -r url login at id <<<"$line"
  if [[ "${id:-}" =~ ^[0-9]+$ ]]; then
    txt=$(mc_rbp_read "$slug" "$num" "$id") || rc=$?
    case "$rc" in
      0) IFS=$'\t' read -r rlogin _ <<<"${txt%%$'\n'*}"
         MC_RBP_BODY="${txt#*$'\n'}"
         # The author GitHub returns for that id is the credential, and it must
         # be the author the scan named.
         MC_RBP_LOGIN="${rlogin:--}"
         [ "$MC_RBP_LOGIN" = "$login" ] && mc_rbp_trusted "$MC_RBP_LOGIN" "$MC_RBP_BODY" "$head" && MC_RBP_ELIG=yes ;;
      44) ;;
      *) MC_RBP_ELIG=unknown ;;
    esac
  fi
  printf '%s' "$MC_RBP_ELIG"
}

# mc_rbp_hid <key> — the per-PR file id (mc_handoff_id when loaded).
mc_rbp_hid() {
  if command -v mc_handoff_id >/dev/null 2>&1; then mc_handoff_id "$1"; else printf '%s' "${1//[^A-Za-z0-9._-]/_}"; fi
}

# mc_rbp_stuck_note <key> <head> <id> <elig> — count the block-gate refusals of
#   a machine BLOCK that did NOT park (yes | unknown), and say so ONCE when the
#   count passes MC_REVIEW_BLOCK_STUCK_TICKS. `no` (a person's block, a block the
#   CI hook owns, the knob off) and a park delete the counter. One line per PR,
#   rewritten in place: `head id count alerted`. Never fails its caller.
mc_rbp_stuck_note() {
  local key="$1" head="$2" id="$3" elig="$4" dir f ph pid count=0 alerted=0 k txt
  [ -n "${MC_STATE_DIR:-}" ] && [ -n "$key" ] || return 0
  dir="$MC_STATE_DIR/review-block"; f="$dir/stuck-$(mc_rbp_hid "$key")"
  case "$elig" in yes|unknown) ;; *) rm -f "$f" 2>/dev/null; return 0 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 0
  [ -r "$f" ] && read -r ph pid count alerted < "$f"
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ "${alerted:-0}" = 1 ] || alerted=0
  if [ "${ph:-}" = "$head" ] && [ "${pid:-}" = "$id" ]; then count=$((count + 1)); else count=1; alerted=0; fi
  # Fallback 2 = catalog/lanes.d/merge-conductor.knobs.d/MC_REVIEW_BLOCK_STUCK_TICKS.json.
  k=$(mc_rbp_knob MC_REVIEW_BLOCK_STUCK_TICKS 2)
  case "$k" in ''|*[!0-9]*) k=2 ;; esac
  if [ "$count" -gt "$k" ] && [ "$alerted" = 0 ] && [ -n "${MC_H:-}" ] && [ -x "$MC_H/bin/lane-alert.sh" ]; then
    txt="$key: a machine review BLOCK ($id) has refused READY head ${head:0:8} for $count ticks and the conductor could not park it for bin/blocked-resolver.sh (block body $([ "$elig" = unknown ] && echo unreadable || echo 'eligible, park not written')). Nothing merges and no fix round runs until it parks or clears."
    "$MC_H/bin/lane-alert.sh" --severity warn --id "review-block-unparked:$key:${head:0:12}:$id" \
      merge-conductor "$txt" >/dev/null 2>&1 && alerted=1
  fi
  printf '%s %s %s %s\n' "$head" "$id" "$count" "$alerted" > "$f" 2>/dev/null
  return 0
}

# mc_rbp_park <key> <slug> <num> <url> <rec> <head> <reviewed> <mstate>
#             <bg_scan line> <ci-hook rc>
#   rc 0 = the row is parked BLOCKED_HUMAN review-block: … (the caller returns).
#   rc 1 = not parked: the refusal stands READY, exactly as BH-762 wrote it.
#   Parks only when ALL hold: enforcement on, the knob on, the CI-block hook
#   declined (rc 2) or is absent, and mc_rbp_eligible says yes.
mc_rbp_park() {
  local key="$1" slug="$2" num="$3" url="$4" rec="${5:--}" head="$6" reviewed="${7:--}" mstate="${8:-UNKNOWN}"
  local line="${9:-}" bci="${10:-2}" burl login at id elig tag why
  IFS=$'\t' read -r burl login at id <<<"$line"
  if ! { command -v bg_enforce >/dev/null 2>&1 && bg_enforce; } || ! mc_rbp_on || [ "$bci" != 2 ]; then
    mc_rbp_stuck_note "$key" "$head" "${id:--}" no; return 1
  fi
  mc_rbp_eligible "$slug" "$num" "$head" "$line" >/dev/null
  elig="$MC_RBP_ELIG"
  if [ "$elig" != yes ]; then mc_rbp_stuck_note "$key" "$head" "${id:--}" "$elig"; return 1; fi
  tag=$(mc_rbp_tag "$MC_RBP_BODY")
  why=$(mc_rbp_why "$id" "$tag" "$burl")
  mc_attempt_put "rvblock $key $head"
  mc_transition "$key" BLOCKED_HUMAN "$why" "$head" "$reviewed" "$url" BLOCK "$mstate" "$rec" >/dev/null
  if [ "$(mc_row_field "$key" 2)" != BLOCKED_HUMAN ]; then
    mc_rbp_stuck_note "$key" "$head" "$id" yes; return 1
  fi
  mc_log "$key BLOCKED_AGENT $why — machine review BLOCK on ${head:0:8}, handed to bin/blocked-resolver.sh (agent fix round against that finding): $url"
  mc_rbp_stuck_note "$key" "$head" "$id" no
  return 0
}

# mc_rbp_row_id <key> [head] — the comment id when the row is BLOCKED_HUMAN
#   `review-block: <id> …` (on <head> when one is given). rc 1 otherwise.
mc_rbp_row_id() {
  local key="$1" head="${2:-}" row st h why id
  row=$(mc_row_get "$key" 2>/dev/null); [ -n "$row" ] || return 1
  IFS=$'\t' read -r _ st _ h _ _ why _ <<<"$row"
  [ "$st" = BLOCKED_HUMAN ] || return 1
  case "$why" in review-block:\ *) ;; *) return 1 ;; esac
  [ -z "$head" ] || [ "$h" = "$head" ] || return 1
  read -r _ id _ <<<"$why"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$id"
}

# mc_rbp_recheck <project> <key> <slug> <num> <url> <rec> <branch> <head>
#   rc 0 the parked block still stands (the same comment id);
#   rc 1 cleared: the scan is clean, a different block is the newest (the
#        ordinary block gate judges that one), the knob or enforcement is off,
#        or the row is not a review-block park on this head. The `rvblock`
#        line is cleared and one line is logged;
#   rc 2 unreadable this tick: the park stays, nothing is written.
#   Reads through bg_scan_read, not bg_scan: a parked tick is not a refusal,
#   so it must not count toward the block gate's streak alert.
mc_rbp_recheck() {
  local p="$1" key="$2" slug="$3" num="$4" url="$5" rec="${6:--}" br="${7:-}" head="$8"
  local id out rc=0 issue="" why
  id=$(mc_rbp_row_id "$key" "$head") || return 1
  if ! mc_rbp_on; then why="MC_REVIEW_BLOCK_PARK=0"
  elif ! { command -v bg_enforce >/dev/null 2>&1 && bg_enforce; }; then why="BLOCK_GATE_ENFORCE=0"
  elif ! command -v bg_scan_read >/dev/null 2>&1; then return 2
  else
    if [ -n "${MC_H:-}" ] && [ -x "$MC_H/bin/fleet-conf.sh" ] && [ "$("$MC_H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)" = "-" ] \
       && command -v mc_issue_of >/dev/null 2>&1; then
      issue=$(mc_issue_of "$rec" "$br")
    fi
    out=$(bg_scan_read "$slug" "$num" "$url" "$head" "$issue") || rc=$?
    case "$rc" in
      0) why="the thread no longer blocks this head" ;;
      1) local o4; IFS=$'\t' read -r _ _ _ o4 <<<"$out"
         [ "$o4" = "$id" ] && return 0
         why="block $id is cleared; the newest block is now ${o4:-?}, which the block gate judges on its own" ;;
      *) return 2 ;;
    esac
  fi
  mc_attempt_clear rvblock "$key" "$head"
  mc_log "$key review-block cleared on ${head:0:8} ($why) — park released, classifying READY: $url"
  return 1
}

# mc_rbp_unpark <project> <key> <slug> <num> <url> <rec> <branch> <head>
#   The sticky branch's one call. rc 0 = this was a review-block park and its
#   block cleared: the hand-off is released and the caller classifies the PR
#   now. rc 1 = anything else (the park stands, or it is not this park).
mc_rbp_unpark() {
  local rc=0
  mc_rbp_row_id "$2" "$8" >/dev/null || return 1
  mc_rbp_recheck "$@" || rc=$?
  [ "$rc" = 1 ] || return 1
  mc_handoff_release "$2" review-block-cleared
  MC_RBP_RELEASED="$2 $8"   # mc_rbp_hold does not re-read this PR this tick
  return 0
}

# mc_rbp_hold <project> <key> <slug> <num> <url> <rec> <branch> <head>
#   Called when this tick classified a row READY. rc 0 = the row is a
#   review-block park on this head (the resolver released its hand-off, so the
#   sticky branch did not stop the tick) and its block still stands or cannot
#   be read: MC_RBP_WHY is the row's reason and the caller keeps BLOCKED_HUMAN.
#   rc 1 = not a park, or its block cleared: READY stands.
mc_rbp_hold() {
  local rc=0
  MC_RBP_WHY=""
  [ "${MC_RBP_RELEASED:-}" = "$2 $8" ] && return 1
  mc_rbp_row_id "$2" "$8" >/dev/null || return 1
  mc_rbp_recheck "$@" || rc=$?
  [ "$rc" = 1 ] && return 1
  MC_RBP_WHY=$(mc_row_field "$2" 7)
  return 0
}

# mc_rbp_brief <slug> <num> <head> — the fix round's brief for a review-block
#   park: a header line, then the BLOCK comment's body, read by id.
#   rc 0 printed; rc 1 not a review-block park on this head, or the comment is
#   gone or not a trusted machine review (the caller reads its usual brief);
#   rc 75 the comment could not be read (the caller spends no rung).
mc_rbp_brief() {
  local slug="$1" num="$2" head="${3:-}" id txt rc=0 login hurl body tag
  id=$(mc_rbp_row_id "$slug#$num" "$head") || return 1
  [ -n "$head" ] || head=$(mc_row_field "$slug#$num" 4)
  txt=$(mc_rbp_read "$slug" "$num" "$id") || rc=$?
  case "$rc" in 0) ;; 44) return 1 ;; *) return 75 ;; esac
  IFS=$'\t' read -r login hurl <<<"${txt%%$'\n'*}"
  body="${txt#*$'\n'}"
  mc_rbp_trusted "$login" "$body" "$head" || return 1
  tag=$(mc_rbp_tag "$body")
  printf 'Review BLOCK %s (%s) on %s:\n\n%s\n' "$tag" "$hurl" "${head:0:12}" "$body"
}

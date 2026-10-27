# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8307-review-skip-note.sh — say why a review that
# asks for changes did not start a fix round (BH-8307). Sourced by the
# driver's blocked-resolver.d block; functions only.
#
# br_from_reviews starts a fix round only from a lead brief (br_lead_pick) or
# from a harness verdict (br_review_harness_pick: a verdict author AND the
# lane's footer). Any other review was skipped with no trace. On 2026-10-25 a
# user-written "BLOCK ... VERDICT: REQUEST_CHANGES" review with no footer
# (project-6#2597, review 5643798807) was skipped in silence, and two sessions
# waited about 15 minutes for a fix round that never came.
#
# THE BOUNDARY DOES NOT MOVE. This file only NOTES the skip: one log line and
# one PR comment per (PR, review id). It never makes a candidate, so a
# user-written review still never starts a fix round (self-approval boundary).
# The driver calls br_rsn_note only on its no-candidate exits.
# BR_OPT_OFF=bh-8307-review-skip-note turns it off.

# br_rsn_pick <head> <rows-json> — the review to note, from the rows
# br_review_rows gives (oldest first: l login, s state, c commit_id, b body, id).
#   rc 0  "<id>\t<login>\t<reasons>" — the newest non-DISMISSED review on <head>
#         asks for changes (state CHANGES_REQUESTED, or a `VERDICT:
#         REQUEST_CHANGES` anywhere in its body) and is not a harness verdict;
#         <reasons> is `author`, `footer` or `author,footer`.
#   rc 1  nothing to note. The lead-review lane's own marker rows
#         (`<!-- lead-review:`) are never noted: their needs-human and
#         console-qa skips are on purpose (BH-3780, BH-5909).
br_rsn_pick() {
  local head="$1" rows="$2" row id login st body reasons=""
  row=$(printf '%s' "$rows" | jq -c --arg h "$head" \
        '[.[]? | select(.c == $h and .s != "DISMISSED")] | last // empty' 2>/dev/null)
  [ -n "$row" ] || return 1
  id=$(printf '%s' "$row" | jq -r '.id // "" | tostring' 2>/dev/null)
  login=$(printf '%s' "$row" | jq -r '.l // ""' 2>/dev/null)
  st=$(printf '%s' "$row" | jq -r '.s // ""' 2>/dev/null)
  body=$(printf '%s' "$row" | jq -r '.b // ""' 2>/dev/null)
  [ -n "$id" ] && [ "$id" != 0 ] && [ -n "$login" ] || return 1
  case "$body" in '<!-- lead-review:'*) return 1 ;; esac
  if [ "$st" != CHANGES_REQUESTED ] \
     && ! grep -qE 'VERDICT:[*[:space:]]*REQUEST_CHANGES' <<<"$body"; then
    return 1
  fi
  # the operator login a PAT post goes out as is the lane too, but only on a
  # footer row (BH-8466): with no footer it is a person, noted as author too
  harness_verdict_author_match "$login" 2>/dev/null || harness_own_review_row "$login" "$body" 2>/dev/null || reasons=author
  grep -qF "$BR_REVIEW_FOOTER" <<<"$body" || reasons="${reasons:+$reasons,}footer"
  [ -n "$reasons" ] || return 1
  printf '%s\t%s\t%s\n' "$id" "$login" "$reasons"
}

# br_rsn_note <p> <slug> <num> <head> <rows-file> — note the skipped review
# once. Always rc 0 and nothing on stdout (br_from_reviews's stdout is the
# candidate TSV). An unreadable rows file is silent: the note is advisory.
# Order is post, then mark: a failed post leaves no mark and is retried on the
# next pass. Observe mode logs the line and posts nothing.
br_rsn_note() {
  local p="$1" slug="$2" num="$3" head="$4" rf="$5" rows pick id login reasons key file line rc
  [ -s "$rf" ] && command -v cm_has >/dev/null 2>&1 || return 0
  rows=$(cat "$rf" 2>/dev/null)
  printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0
  pick=$(br_rsn_pick "$head" "$rows") || return 0
  IFS=$'\t' read -r id login reasons <<<"$pick"
  key="review-skip $slug#$num $id"
  file="$ST/review-skip/${slug//\//_}-$num-$id"
  cm_has "$key" - "$file" && return 0
  line="$p/$slug#$num: review $id by $login on ${head:0:12} is not a harness verdict ($reasons) — skipped; request a lead review to start a fix round"
  if [ "${OBSERVE:-0}" = 1 ]; then say "$line (observe mode: not posted)"; return 0; fi
  say "$line"
  rc=0; br_pr_comment "https://github.com/$slug/pull/$num" "$line" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    cm_put "$key" - "$file" 2>/dev/null || say "$p/$slug#$num: the review-skip note posted but its mark did not save — it can post again"
  else
    say "$p/$slug#$num: the review-skip note did not post (rc $rc) — retried next pass"
  fi
  return 0
}

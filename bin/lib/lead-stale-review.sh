#!/bin/bash
# bin/lib/lead-stale-review.sh — BH-5213: the lead lane dismisses its OWN
# standing CHANGES_REQUESTED review once a later MERGE / MERGE-WITH-NOTES
# supersedes it. Sourced, never executed.
#
# WHY. A lead BLOCK is posted to the PR as a REQUEST_CHANGES review
# (bin/lead-review-land.sh step 2b). GitHub keeps it standing across pushes
# until somebody dismisses it, and .mergify.yml queues only on
# #changes-requested-reviews-by=0, so a fixed PR with a green lead-verdict
# waited on "queue conditions" for ever (#4952, #4070, #4679). The land lane's
# own step 2d dismissed it only when THAT lane recorded the MERGE; a MERGE
# recorded any other way (a lead replay from bin/lead-review-enqueue.sh, a
# human post, a stamp-only retry after the head moved) left it standing.
#
# WHAT IS "THE LANE'S OWN" REVIEW. All three, never fewer:
#   * state CHANGES_REQUESTED on a commit other than the head the new verdict
#     is about (a review AT that head is a verdict on the very code: kept).
#     Mode verdict (BH-6548) drops that exception: a MERGE posted through
#     bin/lead-verdict.sh by source lead or human also supersedes a review AT
#     the same head, because that post is itself a verdict on the very code;
#   * the body carries the `<!-- lead-review:` marker lrl_findings writes;
#   * the author is a BOT whose login is in lsr_bots_json: LEAD_REVIEW_BOT_LOGINS
#     (default cromford[bot], the hub App every lead review posts as),
#     plus the [bot] spellings of harness_verdict_authors_json when
#     bin/lib/gh-pr-list.sh is loaded. A person's review is never one of
#     these, whatever its body says: user.type must be "Bot".
#
# API (bash 3.2 safe: bin/lead-verdict.sh sources it on the lead's Mac):
#   LSR_MODES                            -> the modes lsr_stale honours; a
#                                           caller checks it for verdict
#   lsr_bots_json                        -> JSON array of the bot logins
#   lsr_stale <reviews.json> <head>      -> id<TAB>commit_id per stale own review
#   lsr_stale <reviews.json> <head> <request-id> <job> <merge|block|verdict>
#                                        -> id<TAB>commit_id<TAB>relanded|older|same
#   lsr_reviews <repo> <pr> <out>        -> every page of the PR's reviews as ONE
#                                           array in <out>; rc 1 = not a whole read
#   lsr_dismiss_stale <repo> <pr> <head> <verdict> <row-ref> [<job> <merge|block|verdict> <request-id>]
#        reads the reviews and dismisses each stale own review, the message
#        naming the old head, the new head, the verdict and the verdict row.
#        With the three extra arguments (bin/lead-review-land.sh step 2d,
#        BH-5400) an earlier landing of the same request counts too, whatever
#        its commit, and mode block keeps only those; its message says
#        "re-landed", and LSR_RELANDED counts them apart from LSR_DISMISSED.
#        Mode verdict with no request id (bin/lead-verdict.sh, BH-6548) also
#        dismisses an own review AT <head>; its message names the verdict, the
#        verdict row and the head, and it counts in LSR_DISMISSED.
#        Prints one line per review: `dismissed <id> <old12>` or
#        `failed <id> <old12> HTTP <status>`. Sets LSR_DISMISSED / LSR_FAILED.
#        rc 0 = none stands any more (dismissed now, or none was there);
#        rc 1 = the read failed or a dismissal was refused: the caller retries.
#        Run it as a plain command (`> file`), never in $( ), so GH_REST_STATUS
#        and the LSR_* counters reach the caller.
#   lsr_sweep <repo> [--dry-run]
#        the one-time sweep: every open PR whose head carries a green
#        lead-verdict status and a stale own lead review. Prints one line per
#        PR it acted on (or would act on). rc 1 when any read or dismissal
#        failed. Never touches a PR whose lead-verdict is not success.
# Every GitHub call goes through gh_rest (bin/lib/gh-rest.sh, REST only).

LSR_MARK='<!-- lead-review:'
LSR_MODES='merge block verdict'

lsr_bots_json() {
  local l out=""
  for l in ${LEAD_REVIEW_BOT_LOGINS:-cromford[bot]}; do out="$out$l"$'\n'; done
  if command -v harness_verdict_authors_json >/dev/null 2>&1; then
    out="$out$(harness_verdict_authors_json 2>/dev/null | jq -r '.[]? | select(endswith("[bot]"))' 2>/dev/null)"
  fi
  printf '%s' "$out" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

lsr_stale() { # lsr_stale <reviews.json> <head> [<request-id> <job> <merge|block>]
  # BH-5400, with the three extra arguments: a review is also stale when it is
  # an earlier landing of THIS request (its `<!-- lead-review:<id> -->` marker
  # without this <job>'s `<!-- lead-job:<job> -->`), whatever its commit; mode
  # block drops the older-head case; a third column says `relanded`, `same`
  # (a review AT <head>) or `older`. BH-6548: mode verdict keeps an own review
  # whatever its commit, the same head included.
  # The own-review filter (state, marker, bot author) holds in every case.
  local three=0; [ $# -ge 5 ] && three=1
  jq -r --arg h "$2" --arg m "$LSR_MARK" --argjson bots "$(lsr_bots_json)" \
     --arg rm "<!-- lead-review:${3:-} -->" --arg jm "<!-- lead-job:${4:-} -->" --arg sj "${4:-}" \
     --arg mode "${5:-merge}" --arg three "$three" '
    .[]? | (.body // "") as $b
    | (($sj != "") and ($b | contains($rm)) and (($b | contains($jm)) | not)) as $re
    | select(.state == "CHANGES_REQUESTED"
      and ($b | contains($m))
      and ((.user.type // "") == "Bot")
      and ((.user.login // "") as $l | $bots | index($l) != null)
      and ($re or $mode == "verdict" or ($mode == "merge"
        and ((.commit_id // "") | ascii_downcase) != ($h | ascii_downcase))))
    | [(.id | tostring), (.commit_id // "")] + (if $three == "1" then [if $re then "relanded"
        elif ((.commit_id // "") | ascii_downcase) == ($h | ascii_downcase) then "same" else "older" end] else [] end)
    | @tsv' "$1" 2>/dev/null
}

lsr_reviews() { # lsr_reviews <repo> <pr> <out>
  local repo="$1" pr="$2" out="$3" f page grc len
  f=$(mktemp "${TMPDIR:-/tmp}/lead-stale-review-r.XXXXXX") || return 1
  echo '[]' > "$out"
  for page in 1 2 3 4 5 6 7 8 9 10; do
    grc=0; gh_rest GET "repos/$repo/pulls/$pr/reviews?per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then rm -f "$f"; return 1; fi
    jq -s '.[0] + .[1]' "$out" "$f" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || { rm -f "$f" "$out.tmp"; return 1; }
    len=$(jq 'length' "$f" 2>/dev/null)
    [ "${len:-0}" -lt 100 ] && { rm -f "$f"; return 0; }
  done
  rm -f "$f"; return 1
}

lsr_dismiss_stale() { # lsr_dismiss_stale <repo> <pr> <head> <verdict> <row-ref> [<job> <merge|block> <request-id>]
  local repo="$1" pr="$2" head="$3" verdict="$4" ref="${5:--}" job="${6:-}" mode="${7:-merge}" req="${8:-}" f rid cid kind grc msg
  LSR_DISMISSED=0; LSR_RELANDED=0; LSR_FAILED=0
  f=$(mktemp "${TMPDIR:-/tmp}/lead-stale-review-d.XXXXXX") || return 1
  if ! lsr_reviews "$repo" "$pr" "$f"; then rm -f "$f" "$f.tmp"; LSR_FAILED=1; return 1; fi
  if [ -n "$req" ]; then lsr_stale "$f" "$head" "$req" "$job" "$mode" > "$f.ids"
  elif [ "$mode" = verdict ]; then lsr_stale "$f" "$head" "" "" verdict > "$f.ids"
  else lsr_stale "$f" "$head" > "$f.ids"; fi
  while IFS=$'\t' read -r rid cid kind; do
    [ -n "$rid" ] || continue
    msg="Superseded: the lead verdict on ${head:0:12} is $verdict (verdict row $ref), so this lead BLOCK on ${cid:0:12} no longer stands. Dismissed by the lead lane that posted it (BH-5213); the findings stay in this review's body."
    [ "$kind" = same ] && msg="Superseded: verdict row $ref records $verdict on this same head ${head:0:12}, so this lead BLOCK on it no longer stands. Dismissed by the harness after the $verdict post (BH-5213, BH-6548); the findings stay in this review's body."
    [ "$kind" = relanded ] && msg="Superseded: lead review $req was re-landed as $verdict on ${head:0:12} (verdict row $ref), so this earlier landing on ${cid:0:12} no longer stands. Dismissed by the lead lane that posted it (BH-5213, BH-5400); the findings stay in this review's body."
    grc=0; gh_rest PUT "repos/$repo/pulls/$pr/reviews/$rid/dismissals" -f event=DISMISS -f message="$msg" > /dev/null 2>&1 || grc=$?
    if [ "$grc" = 0 ]; then
      if [ "$kind" = relanded ]; then LSR_RELANDED=$((LSR_RELANDED + 1)); else LSR_DISMISSED=$((LSR_DISMISSED + 1)); fi
      printf 'dismissed %s %s\n' "$rid" "${cid:0:12}"
    else
      LSR_FAILED=$((LSR_FAILED + 1)); printf 'failed %s %s HTTP %s\n' "$rid" "${cid:0:12}" "${GH_REST_STATUS:-000}"
    fi
  done < "$f.ids"
  rm -f "$f" "$f.ids"
  [ "$LSR_FAILED" = 0 ]
}

lsr_sweep() { # lsr_sweep <repo> [--dry-run]
  local repo="$1" dry=0 f st page grc len num head ctx state desc verdict ref rc=0 n line
  [ "${2:-}" = --dry-run ] && dry=1
  ctx=$(command -v vs_context >/dev/null 2>&1 && vs_context || printf 'lead-verdict')
  f=$(mktemp "${TMPDIR:-/tmp}/lead-stale-review-s.XXXXXX") || return 1
  echo '[]' > "$f.prs"
  for page in 1 2 3 4 5 6 7 8 9 10; do
    grc=0; gh_rest GET "repos/$repo/pulls?state=open&per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
      echo "sweep $repo: open PR list unreadable (HTTP ${GH_REST_STATUS:-000}); nothing swept" >&2; rm -f "$f" "$f.prs"; return 1
    fi
    jq -s '.[0] + .[1]' "$f.prs" "$f" > "$f.tmp" && mv "$f.tmp" "$f.prs"
    len=$(jq 'length' "$f" 2>/dev/null)
    [ "${len:-0}" -lt 100 ] && break
  done
  while IFS=$'\t' read -r num head; do
    [ -n "$num" ] && [ -n "$head" ] || continue
    st="$f.st"
    grc=0; gh_rest GET "repos/$repo/commits/$head/status" > "$st" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ]; then echo "sweep $repo#$num: status of ${head:0:12} unreadable (HTTP ${GH_REST_STATUS:-000}); skipped" >&2; rc=1; continue; fi
    IFS=$'\t' read -r state desc < <(jq -r --arg c "$ctx" \
      '[.statuses[]? | select(.context == $c)] | first // {} | [(.state // "none"), ((.description // "") | gsub("[\t\n]"; " "))] | @tsv' "$st" 2>/dev/null)
    [ "$state" = success ] || continue
    verdict=$(printf '%s' "$desc" | grep -oE '^(MERGE-WITH-NOTES|MERGE)' || true)
    [ -n "$verdict" ] || verdict="lead-verdict success"
    ref=$(printf '%s' "$desc" | grep -oE 'verdict #[0-9]+' | head -1 | sed 's/^verdict //')
    [ -n "$ref" ] || ref="status:${desc:0:60}"
    if [ "$dry" = 1 ]; then
      if ! lsr_reviews "$repo" "$num" "$f.rv"; then echo "sweep $repo#$num: reviews unreadable; skipped" >&2; rc=1; continue; fi
      while IFS=$'\t' read -r line n; do
        [ -n "$line" ] && printf '%s#%s would dismiss review %s on %s (head %s, %s, %s)\n' "$repo" "$num" "$line" "${n:0:12}" "${head:0:12}" "$verdict" "$ref"
      done < <(lsr_stale "$f.rv" "$head")
      continue
    fi
    lsr_dismiss_stale "$repo" "$num" "$head" "$verdict" "$ref" > "$f.out" || rc=1
    while read -r line; do
      [ -n "$line" ] && printf '%s#%s %s (head %s, %s, %s)\n' "$repo" "$num" "$line" "${head:0:12}" "$verdict" "$ref"
    done < "$f.out"
    [ "$LSR_FAILED" = 0 ] || [ -s "$f.out" ] || echo "sweep $repo#$num: reviews unreadable; skipped" >&2
  done < <(jq -r '.[] | select((.draft // false) | not) | [(.number | tostring), (.head.sha // "")] | @tsv' "$f.prs" 2>/dev/null)
  rm -f "$f" "$f.prs" "$f.st" "$f.rv" "$f.rv.tmp" "$f.out"
  return "$rc"
}

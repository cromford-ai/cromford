#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization/section-prs.sh — BH-4010 (BH-3988 tracer, slice 3): the
# prs section of a utilization snapshot. Sourced by bin/utilization-push.sh
# (every bin/lib/utilization/section-*.sh is), never run; needs
# bin/jobs-client.sh loaded for _jobs_req, pr_rows_on and pr_state_page.
#
# util_section_prs <project>
#   Prints {prs:{review,ci,merge_queue}, basis:{prs:"measured"|"unmeasured"}}.
#   merge_queue  rows of GET /api/merge-queue?project=&status=queued&limit=500.
#                null when the read failed, .merge_queue is not an array, or
#                it came back at the 500 cap (a capped list is not a count, D12).
#   review, ci   the project's PRs in the pr_state view (GET /api/pr-state per
#                `bin/fleet-conf.sh <p> repo`, 1000 rows a page, walked with
#                before=<min id>) whose state is in UTIL_PR_REVIEW_STATES or
#                UTIL_PR_CI_STATES; any other state counts toward neither.
#                Both null, never 0, when the pr-state-rows flag is off
#                (pr_rows_on, or flags/pr-state-rows without it), the project
#                has no repo, the first page answers 404 or fails, a later page
#                fails, or the walk is still on a full page after UTIL_PR_PAGES
#                pages. A 404 after a full page is the end of the rows. The
#                view keeps MERGED/CLOSED PRs forever, so a repo with more than
#                UTIL_PR_PAGES*1000 pr_state rows is null on every run: that is
#                the bound, not an outage.
#   basis.prs is "unmeasured" whenever any of the three is null.
# rc 1 and nothing printed when there is no project or no harness root
# (${HARNESS:-${H:-}}: a lib never defaults to a path, D43).

# The state-to-bucket table, in the conductor's vocabulary (bin/merge-conductor.sh).
UTIL_PR_REVIEW_STATES="WAIT_REVIEW HEAD_MOVED NEEDS_HUMAN_VERDICT WAIT_LEAD"
UTIL_PR_CI_STATES="WAIT_CI RED_TWICE"
UTIL_MQ_LIMIT=500
UTIL_PR_PAGE=1000
UTIL_PR_PAGES=5

util_section_prs() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" mq=null review=null ci=null uri out repo on=0 \
        states='[]' before="" page=0 rc n done=0
  [ -n "$p" ] && [ -n "$root" ] || return 1
  uri=$(jq -rn --arg v "$p" '$v|@uri') || return 1
  if command -v _jobs_req >/dev/null 2>&1 \
    && out=$(_jobs_req GET "/api/merge-queue?project=$uri&status=queued&limit=$UTIL_MQ_LIMIT"); then
    mq=$(printf '%s' "$out" | jq -r --argjson cap "$UTIL_MQ_LIMIT" \
      'if (.merge_queue|type) == "array" and (.merge_queue|length) < $cap then (.merge_queue|length) else "null" end' 2>/dev/null)
    [[ "$mq" =~ ^[0-9]+$ ]] || mq=null
  fi
  if declare -F pr_rows_on >/dev/null 2>&1; then
    pr_rows_on && on=1
  elif [ -f "$root/flags/pr-state-rows" ]; then
    on=1
  fi
  repo=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  if [ "$on" = 1 ] && [ -n "$repo" ] && [ "$repo" != "-" ] && declare -F pr_state_page >/dev/null 2>&1; then
    while [ "$page" -lt "$UTIL_PR_PAGES" ]; do
      page=$((page+1))
      out=$(pr_state_page "$UTIL_PR_PAGE" "$before" "$repo"); rc=$?
      if [ "$rc" = 2 ] && [ "$page" -gt 1 ]; then done=1; break; fi
      [ "$rc" = 0 ] || break
      n=$(printf '%s' "$out" | jq -r '.rows|length' 2>/dev/null)
      [[ "$n" =~ ^[0-9]+$ ]] || break
      # The page goes in on stdin, never argv: a production-width 1000-row page
      # is ~390 KB, over the kernel's 128 KiB cap on a single argument.
      states=$({ printf '%s\n' "$states"; printf '%s' "$out"; } | jq -sc '.[0] + [.[1].rows[].state]' 2>/dev/null) || break
      if [ "$n" -lt "$UTIL_PR_PAGE" ]; then done=1; break; fi
      before=$(printf '%s' "$out" | jq -r '[.rows[].id]|min' 2>/dev/null)
      [[ "$before" =~ ^[0-9]+$ ]] || break
    done
    if [ "$done" = 1 ]; then
      review=$(jq -r --arg b "$UTIL_PR_REVIEW_STATES" '($b|split(" ")) as $s | [.[]|select(. as $x | $s | any(. == $x))]|length' <<<"$states")
      ci=$(jq -r --arg b "$UTIL_PR_CI_STATES" '($b|split(" ")) as $s | [.[]|select(. as $x | $s | any(. == $x))]|length' <<<"$states")
      [[ "$review" =~ ^[0-9]+$ ]] && [[ "$ci" =~ ^[0-9]+$ ]] || { review=null; ci=null; }
    fi
  fi
  jq -nc --argjson r "$review" --argjson c "$ci" --argjson m "$mq" '
    {prs:{review:$r, ci:$c, merge_queue:$m},
     basis:{prs:(if $r == null or $c == null or $m == null then "unmeasured" else "measured" end)}}'
}

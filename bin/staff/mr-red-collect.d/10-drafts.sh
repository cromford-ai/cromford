#!/bin/bash
# bin/staff/mr-red-collect.d/10-drafts.sh — BH-9532 (C0, #9539): Mr Red's
# failed merge-queue batch source (class failed-batch). Run by
# bin/staff/mr-red-collect.sh, only with MRR_TICK=1.
#
# For each repo of fleet.conf (`<project> <repo>` lines, the first project of
# a repo wins), read-only, over REST (bin/lib/gh-rest.sh):
#   1  gh_budget_low staff-mr-red. Low = exit 75 before any read: a budget-low
#      read is an unread, never an empty one.
#   2  GET repos/<repo>/pulls?state=closed&sort=updated&direction=desc&
#      per_page=100&page=<p>, until a page is short or its oldest updated_at is
#      before the cutoff (now - MRR_LOOKBACK_H hours). A failed page = exit 75.
#   3  A candidate: user mergify[bot], head.ref starting mergify/merge-queue/,
#      state closed, merged_at null, closed_at at or after the cutoff, a 40-hex
#      head sha.
#   4  Its check runs: GET repos/<repo>/commits/<sha>/check-runs?filter=latest&
#      per_page=100&page=<p> until a page is short. A 404 = no runs (not an
#      item); any other failure = exit 75. When every run is completed the
#      answer is kept at state/mr-red/checks/<repo with / as _>__<sha>.json and
#      read from there next tick (a closed draft's runs do not change).
#   5  Failed = conclusion failure or timed_out. A draft with no failed run is
#      not an item.
#   6  One JSON line per item. After MRR_MAX_ITEMS items the check runs of the
#      rest are not read; their count is the last line, `deferred=<n>`.
#
# Env (set by bin/staff/mr-red.sh tick): MRR_TICK=1, MRR_LOOKBACK_H (fallback
# 24, row staff.mr-red.lookback_h), MRR_MAX_ITEMS (fallback 50, row
# staff.mr-red.max_items_tick), MRR_NOW (epoch seconds, honored only with
# HARNESS_TEST_SANDBOX=1). EXIT 0 every repo read; 75 a read failed.
set -uo pipefail
[ "${MRR_TICK:-}" = 1 ] || exit 0
H="${HARNESS:-/root/harness}"
LIBD="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null || . "$LIBD/lib/gh-rest.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-budget.sh
. "$H/bin/lib/gh-budget.sh" 2>/dev/null || . "$LIBD/lib/gh-budget.sh" 2>/dev/null
# shellcheck source=bin/lib/mr-red.sh
. "$H/bin/lib/mr-red.sh" 2>/dev/null || . "$LIBD/lib/mr-red.sh" 2>/dev/null
for fn in gh_rest gh_budget_low mrr_fingerprint; do command -v "$fn" >/dev/null 2>&1 || exit 75; done

LOOK="${MRR_LOOKBACK_H:-}"; [[ $LOOK =~ ^[0-9]+$ ]] && [ "$((10#$LOOK))" -gt 0 ] || LOOK=24   # fallback; row staff.mr-red.lookback_h
MAX="${MRR_MAX_ITEMS:-}"; [[ $MAX =~ ^[0-9]+$ ]] && [ "$((10#$MAX))" -gt 0 ] || MAX=50       # fallback; row staff.mr-red.max_items_tick
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${MRR_NOW:-} =~ ^[0-9]+$ ]] && NOW=$MRR_NOW
CUT=$(date -u -d "@$((NOW - 10#$LOOK * 3600))" +%FT%TZ)
CDIR="$H/state/mr-red/checks"
W=$(mktemp -d "${TMPDIR:-/tmp}/mr-red-drafts.XXXXXX") || exit 75
trap 'rm -rf "$W"' EXIT

REPOS=$(awk '$1 !~ /^#/ && NF >= 2 && $2 ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ && !seen[$2]++ { print $1, $2 }' \
  "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
[ -n "$REPOS" ] || exit 0
gh_budget_low staff-mr-red; [ $? = 0 ] && exit 75

ITEMS=0; DEFERRED=0
while read -r project slug; do
  # 2-3: the candidates, newest first.
  : > "$W/cand"
  p=1
  while :; do
    rc=0
    gh_rest GET "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$p" > "$W/pulls" < /dev/null || rc=$?
    [ "$rc" = 0 ] && jq -e 'type == "array"' "$W/pulls" >/dev/null 2>&1 || exit 75
    jq -c --arg c "$CUT" '.[] | select(.user.login == "mergify[bot]"
        and ((.head.ref // "") | startswith("mergify/merge-queue/"))
        and .state == "closed" and .merged_at == null and (.closed_at // "") >= $c
        and ((.head.sha // "") | test("^[0-9a-f]{40}$")))
      | {number, sha: .head.sha, url: .html_url, closed_at}' "$W/pulls" >> "$W/cand" || exit 75
    [ "$(jq length "$W/pulls")" -lt 100 ] && break
    [[ "$(jq -r '[.[].updated_at // ""] | min' "$W/pulls")" < "$CUT" ]] && break
    p=$((p + 1))
  done
  # 4-6: the check runs of each candidate, until the item cap.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ "$ITEMS" -ge "$MAX" ]; then DEFERRED=$((DEFERRED + 1)); continue; fi
    n=$(jq -r .number <<<"$c"); sha=$(jq -r .sha <<<"$c")
    cache="$CDIR/${slug//\//_}__$sha.json"
    if [ -s "$cache" ] && jq -e '.check_runs | type == "array"' "$cache" >/dev/null 2>&1; then
      cp "$cache" "$W/runs"
    else
      : > "$W/runs.l"; rp=1; gone=0
      while :; do
        rc=0
        gh_rest GET "repos/$slug/commits/$sha/check-runs?filter=latest&per_page=100&page=$rp" > "$W/r" < /dev/null || rc=$?
        [ "$rc" = 44 ] && { gone=1; break; }
        [ "$rc" = 0 ] && jq -e '.check_runs | type == "array"' "$W/r" >/dev/null 2>&1 || exit 75
        jq -c '.check_runs[]' "$W/r" >> "$W/runs.l"
        [ "$(jq '.check_runs | length' "$W/r")" -lt 100 ] && break
        rp=$((rp + 1))
      done
      [ "$gone" = 1 ] && continue
      jq -sc '{check_runs: .}' "$W/runs.l" > "$W/runs" || exit 75
      if jq -e '.check_runs | all(.status == "completed")' "$W/runs" >/dev/null 2>&1; then
        mkdir -p "$CDIR" 2>/dev/null && cp "$W/runs" "$cache.tmp" 2>/dev/null && mv -f "$cache.tmp" "$cache" 2>/dev/null
      fi
    fi
    checks=$(jq -r '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .name' "$W/runs" | LC_ALL=C sort -u)
    [ -n "$checks" ] || continue
    fp=$(mrr_fingerprint failed-batch "$slug" "#$n" "$checks" "$sha") || continue
    jq -nc --argjson c "$c" --arg r "$slug" --arg p "$project" --arg h "$sha" --arg fp "$fp" \
      --argjson ck "$(printf '%s\n' "$checks" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
      ("#" + ($c.number | tostring)) as $t
      | {item: {class: "failed-batch", repo: $r, target: $t, head: $h, checks: $ck},
         title: "Failed merge-queue batch \($t) (\($r))",
         source: {kind: "mr-red-failed-batch", url: ($c.url // "https://github.com/\($r)/pull/\($c.number)"), labels: []},
         observedAt: $c.closed_at, class: "failed-batch", project: $p, repo: $r, target: $t, target_kind: "pr",
         head: $h, checks: $ck, fingerprint: $fp}'
    ITEMS=$((ITEMS + 1))
  done < "$W/cand"
done <<<"$REPOS"
[ "$DEFERRED" -gt 0 ] && echo "deferred=$DEFERRED"
exit 0

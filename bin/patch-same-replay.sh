#!/bin/bash
# bin/patch-same-replay.sh — outcome replay for the review rungs of
# bin/lib/patch-same.sh (BH-9066, plan T6). Operator-invoked; no cron lane.
#
#   bin/patch-same-replay.sh --repo <owner/repo> --last <N> --clone <dir> [--json]
#
# --last is REQUIRED (a positive integer, no default). --clone is REQUIRED: the
# private clone the pairs are compared in (for example
# `git clone --no-checkout /root/repos/<project> /tmp/psr-clone`, origin set to
# the GitHub remote). The script writes refs into it, so never pass a live
# repo checkout.
#
# WHAT IT DOES. It reads the last N merged PRs of --repo (GitHub REST through
# bin/lib/gh-rest.sh, newest merged first) and each PR's verdict history
# (bin/jobs-client.sh, GET /api/verdicts?repo=&pr=). It keeps the lead rows a
# model answered: source "lead", not retracted, a MERGE / MERGE-WITH-NOTES /
# BLOCK verdict, a 40-hex head, and a note that does not contain `lead-replay:`
# (a replay is not a model answer). Ordered by id, consecutive rows on the same
# head collapse to one, and each consecutive pair of distinct heads is one
# pair. For each pair it runs patch_same_fetch, then `patch_same` (the byte
# rungs) and `patch_same_review` (the review rungs) on the clone, against the
# PR's BASE: main as it was before the PR landed, never today's main (a merged
# PR's heads are ancestors of today's main, so both diffs would be empty).
#
# THE BASE. Each merged PR carries its merge_commit_sha (the same REST page).
# The merge commit is fetched when the clone lacks it. With L = the last
# reviewed head and P = <merge>^1: if L is not an ancestor of P (the PR landed
# by its own merge commit, or a squash), the base is P. Otherwise a batch or
# train merge landed L first, and the base is the parent of the oldest
# first-parent commit of P that holds L (the landing commit, found by walking
# `git rev-list --first-parent L..P` newest first while it holds L).
# The base is stored as refs/psr/base/<pr> in the clone and passed as <main>.
# No merge sha, a merge that cannot be fetched, or no base -> every pair of
# that PR is a miss with reason "base unresolved". A pair where either head
# has an empty diff from its merge-base with the base is "base unresolved"
# too, never a hit and never "code changed".
#
# OUTPUT (stdout). One TSV row per pair:
#   pr  reviewed-head  next-head  byte-rung|-  review-rung|-  miss-reason|-
# Then the summary:
#   Target metric: lead-review-heads-per-merged-pr-p90
#   measured: <p90>
#   lead-review heads per merged PR measured: median=<m> p90=<p> max=<x>
#   lead-review heads per merged PR replayed: median=<m> p90=<p> max=<x>
#   rung <name>: hits=<n> rate=<pct>%     (identical, main-merge, patch-id,
#                                          restamp, restamp-rebase, full-review)
#   top miss reasons:
#     <count> <reason>                    (up to 5, most frequent first)
# --json prints one JSON object (the rows and the same summary) instead.
#
# DEFINITIONS. "Heads per merged PR" counts the distinct lead-reviewed heads
# of each PR whose verdict read succeeded and that has at least one lead row
# (a PR no model reviewed is left out). "Replayed" counts the first head plus
# each pair that patch_same_review did NOT cover (a fetch failure or a gone
# sha counts as not covered). Median and p90 are nearest-rank percentiles
# (rank = ceil(q * n) over the sorted values); with no PR they print 0. A
# rung rate is hits / pairs. full-review is the pairs no review rung covered.
# Miss reasons: "fetch failed" (patch_same_fetch rc 1), "sha gone" (a sha
# does not resolve after the fetch), "base unresolved" (above), "restamp plus
# code change" (the review rung missed, either head adds a worker/*/schema.d/
# fragment, and a file outside worker/*/schema.d/ has a different diff in the
# two heads; a rewritten reference to a fragment counts as such a file),
# "fragment order or suffix changed" (the review rung missed, either head
# adds a fragment, and every file outside worker/*/schema.d/ has the same
# diff), "code changed" (every other miss), "verdict read failed" (one per PR
# whose verdict read failed). Ties sort by reason name.
#
# EXIT. 0 printed; 2 usage (also: --clone not a git clone, a library missing); 3 every
# verdict read failed, or the merged PR list could not be read.
#
# READ-ONLY. No model call. It writes a mktemp scratch dir that it removes on
# exit, and refs/psr/base/<pr> in the clone it is given. patch_same_fetch
# fetches into the clone's origin/* refs and object store, the same fetch every
# review lane does. Use a private clone (--clone), not a live repo checkout.
#
# TEST SEAMS. When set, each names a shell function that the caller has
# exported (`export -f <fn>`); a name that is not a defined function is a
# usage error (exit 2).
#   PSR_GH_FN        called as `<fn> <repo> <N>`; prints `<pr><TAB><merge sha>`
#                    per merged PR, one per line, newest first (a bare `<pr>`
#                    line has no merge sha); rc != 0 is a failed list read.
#   PSR_VERDICTS_FN  called as `<fn> <repo> <pr>`; prints the verdicts JSON
#                    {"rows":[...]}; rc != 0 is a failed verdict read.
# With a seam set, the matching library (gh-rest.sh / jobs-client.sh) is not
# sourced. Driven by tests/patch-same-replay.bh-9066-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
[ -r "$H/bin/lib/patch-same.sh" ] || H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$H/bin/lib"

usage() { echo "usage: $0 --repo <owner/repo> --last <N> --clone <dir> [--json]" >&2; exit 2; }
die2() { echo "patch-same-replay: $*" >&2; exit 2; }

SLUG=""; LASTN=""; CLONE=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; SLUG="$2"; shift 2 ;;
    --last) [ $# -ge 2 ] || usage; LASTN="$2"; shift 2 ;;
    --clone) [ $# -ge 2 ] || usage; CLONE="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) usage ;;
  esac
done
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$LASTN" =~ ^[1-9][0-9]*$ ]] || usage
[ -n "$CLONE" ] || usage

for v in PSR_GH_FN PSR_VERDICTS_FN; do
  fn="${!v:-}"
  [ -z "$fn" ] || declare -F "$fn" >/dev/null || die2 "$v=$fn is not a defined (exported) function"
done

# shellcheck source=bin/lib/patch-same.sh
. "$LIB/patch-same.sh" || die2 "cannot source $LIB/patch-same.sh"
declare -F patch_same_review >/dev/null || die2 "patch_same_review is not defined by $LIB/patch-same.sh"
if [ -z "${PSR_GH_FN:-}" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "$LIB/gh-rest.sh" || die2 "cannot source $LIB/gh-rest.sh"
  # shellcheck source=/dev/null
  . "$LIB/gh-app-auth.sh" 2>/dev/null || true
fi
if [ -z "${PSR_VERDICTS_FN:-}" ]; then
  # jobs-client.sh exits its caller on a missing module, so check it first.
  [ -r "$H/bin/jobs-client.sh" ] && [ -r "$LIB/jobs/req.sh" ] || die2 "no $H/bin/jobs-client.sh"
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"
fi

[ -d "$CLONE/.git" ] || [ -f "$CLONE/HEAD" ] || die2 "no git clone at $CLONE"

W=$(mktemp -d "${TMPDIR:-/tmp}/patch-same-replay.XXXXXX") || die2 "mktemp failed"
trap 'rm -rf "$W"' EXIT

# ---- the merged PR list, newest merged first
list_merged() { # -> PR numbers on stdout, rc != 0 on a failed read
  if [ -n "${PSR_GH_FN:-}" ]; then "$PSR_GH_FN" "$SLUG" "$LASTN"; return; fi
  command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$SLUG" || true; }
  local page=1 rc have=0
  : > "$W/merged.tsv"
  while [ "$have" -lt "$LASTN" ]; do
    # Through a FILE and never `$( )`, so GH_REST_REASON survives (gh-rest.sh).
    # per_page=100 is GitHub's page maximum, not a cap on what is read.
    rc=0; gh_rest GET "repos/$SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page" > "$W/page" || rc=$?
    [ "$rc" = 0 ] || return 1
    jq -e 'type == "array"' "$W/page" >/dev/null 2>&1 || return 1
    [ "$(jq 'length' "$W/page")" -gt 0 ] || break
    jq -r '.[] | select(.merged_at != null) | "\(.merged_at)\t\(.number)\t\(.merge_commit_sha // "")"' "$W/page" >> "$W/merged.tsv" || return 1
    have=$(grep -c . "$W/merged.tsv")
    page=$((page + 1))
  done
  sort -r "$W/merged.tsv" | head -n "$LASTN" | cut -f2,3
}

read_verdicts() { # <pr> -> the verdicts JSON, rc != 0 on a failed read
  if [ -n "${PSR_VERDICTS_FN:-}" ]; then "$PSR_VERDICTS_FN" "$SLUG" "$1"; return; fi
  JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$SLUG&pr=$1" 2>/dev/null
}

# _adds_fragment <base-ref> <sha> — rc 0 when <sha>'s diff from its merge-base
# with <base-ref> adds a worker/*/schema.d/ file.
_adds_fragment() {
  local mb
  mb=$(git -C "$CLONE" merge-base "$1" "$2" 2>/dev/null) || return 1
  [ -n "$(git -C "$CLONE" diff --name-only --diff-filter=A "$mb" "$2" -- 'worker/*/schema.d/*' 2>/dev/null)" ]
}

# _empty_diff <base-ref> <sha> — rc 0 when <sha> has no diff from its
# merge-base with <base-ref> (or the merge-base cannot be read).
_empty_diff() {
  local mb
  mb=$(git -C "$CLONE" merge-base "$1" "$2" 2>/dev/null) || return 0
  git -C "$CLONE" diff --quiet "$mb" "$2" 2>/dev/null
}

# _code_differs <base-ref> <a> <b> — rc 0 when a file outside
# worker/*/schema.d/ has a different diff in <a> and <b> (each from its own
# merge-base with <base-ref>), by verbatim patch-id.
_code_differs() {
  local ia ib
  ia=$(_nonschema_id "$1" "$2") || return 0
  ib=$(_nonschema_id "$1" "$3") || return 0
  [ "$ia" != "$ib" ]
}
_nonschema_id() {
  local mb
  mb=$(git -C "$CLONE" merge-base "$1" "$2" 2>/dev/null) || return 1
  git -C "$CLONE" diff --no-renames --no-color --no-ext-diff "$mb" "$2" -- . ':(exclude)worker/*/schema.d/*' 2>/dev/null \
    | git -C "$CLONE" patch-id --verbatim 2>/dev/null | cut -d' ' -f1 | grep -E '^[0-9a-f]{40}$' || printf 'empty'
}

# _resolve_base <pr> <merge-sha> <last-head> — sets refs/psr/base/<pr> to
# main before the PR landed (header, THE BASE). rc 1 when no base resolves.
_resolve_base() {
  local pr="$1" mc="$2" last="$3" p1 first base
  git -C "$CLONE" update-ref -d "refs/psr/base/$pr" >/dev/null 2>&1
  [[ "$mc" =~ ^[0-9a-f]{40}$ ]] && [[ "$last" =~ ^[0-9a-f]{40}$ ]] || return 1
  if ! git -C "$CLONE" cat-file -e "$mc^{commit}" 2>/dev/null; then
    git -C "$CLONE" fetch -q origin "$mc" >/dev/null 2>&1 || return 1
    git -C "$CLONE" cat-file -e "$mc^{commit}" 2>/dev/null || return 1
  fi
  p1=$(git -C "$CLONE" rev-parse -q --verify "$mc^1^{commit}" 2>/dev/null) || return 1
  if git -C "$CLONE" merge-base --is-ancestor "$last" "$p1" 2>/dev/null; then
    # Newest first, the first-parent commits that hold L form one run that ends
    # at the landing commit. (--first-parent with --ancestry-path prints
    # nothing when L came in through a second parent, so walk it.)
    first=""
    while read -r c; do
      git -C "$CLONE" merge-base --is-ancestor "$last" "$c" 2>/dev/null || break
      first=$c
    done < <(git -C "$CLONE" rev-list --first-parent "$last..$p1" 2>/dev/null)
    [[ "$first" =~ ^[0-9a-f]{40}$ ]] || return 1
    base=$(git -C "$CLONE" rev-parse -q --verify "$first^1^{commit}" 2>/dev/null) || return 1
  else
    base=$p1
  fi
  git -C "$CLONE" update-ref "refs/psr/base/$pr" "$base" >/dev/null 2>&1
}

if ! list_merged > "$W/prs" 2>/dev/null; then
  echo "patch-same-replay: the merged PR list for $SLUG could not be read" >&2; exit 3
fi
grep -E $'^[0-9]+(\t[0-9a-f]*)?$' "$W/prs" | head -n "$LASTN" > "$W/prlist"

: > "$W/rows"; : > "$W/measured"; : > "$W/replayed"; : > "$W/rungs"; : > "$W/misses"
nprs=0; nread=0
while IFS=$'\t' read -r pr mc; do
  nprs=$((nprs + 1))
  if ! read_verdicts "$pr" > "$W/v" 2>/dev/null \
     || ! jq -e '(.rows | type) == "array"' "$W/v" >/dev/null 2>&1; then
    echo "verdict read failed" >> "$W/misses"; continue
  fi
  nread=$((nread + 1))
  jq -r '[.rows[] | select(.retracted_at == null and .source == "lead"
          and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
          and (((.note // "") | contains("lead-replay:")) | not))
          | select((.head_sha // "") | ascii_downcase | test("^[0-9a-f]{40}$"))]
        | sort_by(.id) | .[] | .head_sha | ascii_downcase' "$W/v" 2>/dev/null \
    | awk '$0 != prev {print; prev = $0}' > "$W/heads"
  n=$(grep -c . "$W/heads")
  [ "$n" -gt 0 ] || continue
  echo "$n" >> "$W/measured"
  replayed=1
  prev=""
  # The base: main before this PR landed. The last head must be local first.
  last=$(tail -n 1 "$W/heads"); based=0; BASE="refs/psr/base/$pr"
  if [ "$n" -gt 1 ] && patch_same_fetch "$CLONE" "" "$last" "$pr" >/dev/null 2>&1 \
     && _resolve_base "$pr" "${mc:-}" "$last"; then based=1; fi
  while read -r h; do
    if [ -z "$prev" ]; then prev="$h"; continue; fi
    byte="-"; rev="-"; miss="-"
    if ! patch_same_fetch "$CLONE" "$prev" "$h" "$pr" >/dev/null 2>&1; then
      miss="fetch failed"
    elif ! _ps_sha "$CLONE" "$prev" >/dev/null || ! _ps_sha "$CLONE" "$h" >/dev/null; then
      miss="sha gone"
    elif [ "$based" != 1 ] || _empty_diff "$BASE" "$prev" || _empty_diff "$BASE" "$h"; then
      miss="base unresolved"
    else
      byte=$(patch_same "$CLONE" "$BASE" "$prev" "$h" 2>/dev/null) || byte="-"
      rev=$(patch_same_review "$CLONE" "$BASE" "$prev" "$h" 2>/dev/null) || rev="-"
      [ -n "$byte" ] || byte="-"; [ -n "$rev" ] || rev="-"
      if [ "$rev" = "-" ]; then
        if _adds_fragment "$BASE" "$prev" || _adds_fragment "$BASE" "$h"; then
          if _code_differs "$BASE" "$prev" "$h"; then miss="restamp plus code change"
          else miss="fragment order or suffix changed"; fi
        else miss="code changed"; fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pr" "$prev" "$h" "$byte" "$rev" "$miss" >> "$W/rows"
    if [ "$rev" = "-" ]; then
      replayed=$((replayed + 1)); echo "full-review" >> "$W/rungs"; echo "$miss" >> "$W/misses"
    else
      echo "$rev" >> "$W/rungs"
    fi
    prev="$h"
  done < "$W/heads"
  echo "$replayed" >> "$W/replayed"
done < "$W/prlist"

if [ "$nprs" -gt 0 ] && [ "$nread" -eq 0 ]; then
  echo "patch-same-replay: every verdict read failed ($nprs PRs)" >&2; exit 3
fi

stats() { # <file of integers> -> "median p90 max" (nearest rank; 0 0 0 when empty)
  sort -n "$1" | awk '{v[NR] = $1} END {
    if (NR == 0) { print "0 0 0"; exit }
    m = int((NR * 50 + 99) / 100); p = int((NR * 90 + 99) / 100)
    print v[m], v[p], v[NR] }'
}
read -r m_med m_p90 m_max < <(stats "$W/measured")
read -r r_med r_p90 r_max < <(stats "$W/replayed")
npairs=$(grep -c . "$W/rows")
RUNGS="identical main-merge patch-id restamp restamp-rebase full-review"
rate() { awk -v h="$1" -v n="$npairs" 'BEGIN { printf "%.1f", (n > 0 ? 100 * h / n : 0) }'; }
hits() { grep -cxF "$1" "$W/rungs"; }
sort "$W/misses" | uniq -c | sort -k1,1nr -k2 | head -n 5 | sed -E 's/^ *([0-9]+) /\1\t/' > "$W/top"

if [ "$JSON" = 1 ]; then
  rj="{}"
  for r in $RUNGS; do
    rj=$(jq -c --arg r "$r" --argjson h "$(hits "$r")" --argjson p "$(rate "$(hits "$r")")" '. + {($r): {hits: $h, rate: $p}}' <<<"$rj")
  done
  jq -n --rawfile rows "$W/rows" --rawfile top "$W/top" --argjson rungs "$rj" \
     --argjson prs "$nprs" --argjson read "$nread" --argjson pairs "$npairs" \
     --argjson mm "$m_med" --argjson mp "$m_p90" --argjson mx "$m_max" \
     --argjson rm "$r_med" --argjson rp "$r_p90" --argjson rx "$r_max" '{
    target_metric: "lead-review-heads-per-merged-pr-p90", measured: $mp,
    prs: $prs, verdicts_read: $read, pairs: $pairs,
    measured_heads: {median: $mm, p90: $mp, max: $mx},
    replayed_heads: {median: $rm, p90: $rp, max: $rx},
    rungs: $rungs,
    top_miss_reasons: [$top | split("\n")[] | select(length > 0) | split("\t") | {count: (.[0] | tonumber), reason: .[1]}],
    rows: [$rows | split("\n")[] | select(length > 0) | split("\t")
           | {pr: (.[0] | tonumber), reviewed: .[1], head: .[2], byte_rung: .[3], review_rung: .[4], miss: .[5]}]
  }'
  exit 0
fi

cat "$W/rows"
echo "Target metric: lead-review-heads-per-merged-pr-p90"
echo "measured: $m_p90"
echo "lead-review heads per merged PR measured: median=$m_med p90=$m_p90 max=$m_max"
echo "lead-review heads per merged PR replayed: median=$r_med p90=$r_p90 max=$r_max"
for r in $RUNGS; do
  h=$(hits "$r"); echo "rung $r: hits=$h rate=$(rate "$h")%"
done
echo "top miss reasons:"
while IFS=$'\t' read -r c reason; do printf '  %s %s\n' "$c" "$reason"; done < "$W/top"
exit 0

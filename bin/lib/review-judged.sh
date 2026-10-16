#!/bin/bash
# bin/lib/review-judged.sh — which review mode a PR's lead verdict was judged
# under (BH-7123 wave B). Sourced by the ratchet lanes (bin/lesson-propose.sh,
# bin/review-tighten.sh); never executed. No `set -e`, no side effect at source.
#
#   rj_pr_mode <owner/repo> <pr>        strict|shadow|levels|cowboy|off, or
#                                       `unknown` with rc 1 when nothing is
#                                       reachable
#   rj_verdict_modes <owner/repo> <pr>  one `<verdict-id>\t<mode>` line per
#                                       lead verdict row of the PR whose report
#                                       is readable here (nothing = none)
#
# THE SOURCES, in order. (1) The hub keeps every lead report it wrote at
# state/lead-reviews/lr-<pr>-<sha12>.md, headed `# Lead review <key>
# (<repo>#<pr> at <sha>)`; the newest file of this PR whose header names this
# repo is read with rl_judged_mode (bin/lib/review-level.sh). (2) When no local
# report matches, GET /api/verdicts?repo=&pr= (one call per PR, cached for the
# process in $RJ_CACHE) answers the lead rows; the row's note carries
# `report:<ref>` (bin/lead-review-land.sh), the path the hub stored the report
# at, read the same way when it exists here. (3) Nothing readable is `unknown`,
# never a guess: the ratchet keeps a verdict it cannot place, so an outage can
# only make it stricter, not teach it from a sprint it cannot see.
#
# THE GAP (documented, not hidden): rl_cap writes its marker only when it ran,
# i.e. on a model BLOCK; a report whose model verdict was already MERGE carries
# no marker and reads `strict` here. A cowboy sprint's merges are therefore
# visible to review-tighten only when the lead report of the merge had a
# demotion in it. The fix is lead-review.sh printing the `## Review level`
# mode into every report header (owned by wave B2).
if [ -n "${REVIEW_JUDGED_LIB:-}" ]; then return 0 2>/dev/null; fi
REVIEW_JUDGED_LIB=1
_RJ_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=bin/lib/review-level.sh
command -v rl_judged_mode >/dev/null 2>&1 || [ ! -r "$_RJ_DIR/review-level.sh" ] || . "$_RJ_DIR/review-level.sh"

# The root is HARNESS, then the caller's H, else this file's own tree: a bin/lib
# file never falls back to the literal harness root (BH-2613 ratchet).
_rj_h() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || r=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)
  printf '%s' "$r"
}

# _rj_local_report <repo> <pr> — the newest local report of this repo's PR.
_rj_local_report() {
  local repo="$1" pr="$2" d f best="" bt=0 t
  d="$(_rj_h)/state/lead-reviews"
  [ -d "$d" ] || return 1
  for f in "$d/lr-$pr-"*.md; do
    [ -r "$f" ] || continue
    head -1 "$f" 2>/dev/null | grep -qF "($repo#$pr at " || continue
    t=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$t" -ge "$bt" ] && { bt="$t"; best="$f"; }
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# _rj_rows <repo> <pr> — the verdict rows of the PR, as JSON, cached per
# process. rc 1 when the API is not reachable (no _jobs_req, or it failed).
_rj_rows() {
  local repo="$1" pr="$2" k f q out
  command -v _jobs_req >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "${RJ_CACHE:-}" ] || RJ_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/rj.XXXXXX" 2>/dev/null) || return 1
  k=$(printf '%s#%s' "$repo" "$pr" | tr -c 'A-Za-z0-9._-' '_'); f="$RJ_CACHE/$k.json"
  if [ ! -s "$f" ]; then
    q=$(jq -nr --arg r "$repo" --arg p "$pr" '"repo=" + ($r|@uri) + "&pr=" + ($p|@uri)') || return 1
    out=$(_jobs_req GET "/api/verdicts?$q" 2>/dev/null 7>&- 8>&-) || return 1
    printf '%s' "$out" | jq -c '.rows // []' > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  fi
  cat "$f"
}

# _rj_report_path <ref> — a `report:` ref as a readable path, or nothing.
_rj_report_path() {
  local r="$1"
  case "$r" in
    ''|-|https://*) return 1 ;;
    /*) [ -r "$r" ] && printf '%s' "$r" ;;
    *)  [ -r "$(_rj_h)/$r" ] && printf '%s' "$(_rj_h)/$r" ;;
  esac
}

rj_verdict_modes() { # rj_verdict_modes <repo> <pr>
  local repo="${1:-}" pr="${2:-}" rows id note ref p m
  [ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || return 1
  rows=$(_rj_rows "$repo" "$pr") || return 1
  while IFS=$'\t' read -r id note; do
    [ -n "$id" ] || continue
    ref=$(printf '%s' "$note" | tr ' ' '\n' | sed -n 's/^report://p' | head -1)
    # the row's own report first; a row with no readable ref falls back to the
    # newest local report of the PR (the same file on the hub, renamed or not)
    p=$(_rj_report_path "$ref") || p=$(_rj_local_report "$repo" "$pr") || continue
    m=$(rl_judged_mode "$p") || continue
    printf '%s\t%s\n' "$id" "$m"
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.source == "lead") | [(.id|tostring), (.note // "")] | @tsv' 2>/dev/null)
  return 0
}

rj_pr_mode() { # rj_pr_mode <repo> <pr>
  local repo="${1:-}" pr="${2:-}" f m
  [ -n "$repo" ] && [[ "$pr" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 1; }
  if f=$(_rj_local_report "$repo" "$pr"); then rl_judged_mode "$f"; return 0; fi
  # rows come newest first (ORDER BY id DESC): the first readable one is the standing lead row
  m=$(rj_verdict_modes "$repo" "$pr" 2>/dev/null | head -1 | cut -f2)
  [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  printf 'unknown'; return 1
}

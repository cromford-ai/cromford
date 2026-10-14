#!/bin/bash
# bin/lib/slice-prs.sh — which merged PRs delivered a slice of issue #N
# (BH-6308). One reader, shared by the slice close-out (bin/lib/slice-closeout.sh:
# the close comment lists them) and the stale-parent alert
# (bin/lib/stall-alerts.sh: "its last slice merged H hours ago").
#
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
# Safe under `set -u`. The root is the caller's argument or ${HARNESS:-${H:-}},
# never a literal.
#
#   slice_merged_prs <repo-slug> <n> [harness]
#     -> TSV `merged_epoch<TAB>pr_url<TAB>pr_number`, newest merge first, one
#        row per PR, rc 0. No row and rc 0 = the whole timeline was read and no
#        merged PR names #n.
#     -> `ERR:<why>` and rc 1 when the timeline was NOT read to its end: no jq
#        or gh_rest, a page that failed or did not parse, or a page still full
#        at ISSUE_CLOSE_GUARD_PAGES (default 5). The same caps and words as
#        _issue_open_children, so "is there a merged slice?" is never answered
#        from half a list (D12).
#
# A PR counts when the issue timeline cross-references it, GitHub says it
# merged (`source.issue.pull_request.merged_at`), it is in the same repo, and
# it names #n: a body line `Part of #n`, `SLICE: C<k> of #n` or a closing
# keyword for #n, or a title that leads with a ticket key for n (`BH-n: …`).

# shellcheck source=bin/lib/gh-rest.sh
command -v gh_rest >/dev/null 2>&1 \
  || { [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"; }

_slp_arm() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"; return 0; }

_slp_pages() {
  local v="${ISSUE_CLOSE_GUARD_PAGES:-}" h="${1:-}"
  if [ -z "$v" ] && command -v _issue_env >/dev/null 2>&1; then v=$(_issue_env "$h" ISSUE_CLOSE_GUARD_PAGES 5); fi
  case "$v" in ''|*[!0-9]*|0) v=5 ;; esac
  printf '%s\n' "$v"
}

slice_merged_prs() {
  local slug="${1:-}" n="${2:-}" h="${3:-${HARNESS:-${H:-}}}" max p=1 page len rows="" r
  case "$n" in ''|*[!0-9]*) printf 'ERR:args\n'; return 1 ;; esac
  [ -n "$slug" ] || { printf 'ERR:args\n'; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'ERR:no-jq\n'; return 1; }
  command -v gh_rest >/dev/null 2>&1 || { printf 'ERR:no-gh-rest\n'; return 1; }
  max=$(_slp_pages "$h")
  while [ "$p" -le "$max" ]; do
    page=$(_slp_arm "$slug"; gh_rest GET "repos/$slug/issues/$n/timeline?per_page=100&page=$p" 2>/dev/null) \
      || { printf 'ERR:timeline-read\n'; return 1; }
    len=$(printf '%s' "$page" | jq -e 'if type == "array" then length else error("not a list") end' 2>/dev/null) \
      || { printf 'ERR:timeline-unparseable\n'; return 1; }
    r=$(printf '%s' "$page" | jq -r --argjson n "$n" --arg slug "$slug" '
          ("(^|[^0-9A-Za-z_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[ \t]+#" + ($n|tostring) + "([^0-9]|$)") as $kw
          | ("^[ \t>*_-]*(Part of:? #" + ($n|tostring) + "|SLICE:[ \t*_]*C[0-9]+[ \t]+of[ \t]+#" + ($n|tostring) + ")([^0-9]|$)") as $line
          | ("^[ \t\\[]*[A-Z][A-Z0-9]*-" + ($n|tostring) + "([^0-9]|$)") as $title
          | .[] | select(type == "object" and .event == "cross-referenced")
          | (.source.issue // empty)
          | select(type == "object" and (.pull_request | type) == "object" and (.pull_request.merged_at // "") != "")
          | select(((.repository.full_name // $slug) | ascii_downcase) == ($slug | ascii_downcase))
          | select(((.body // "") | split("\n") | map(sub("\r$"; "")) | any(test($line) or test($kw; "i")))
                   or ((.title // "") | test($title)))
          | [ (.pull_request.merged_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601),
              (.pull_request.html_url // .html_url // ""), .number ] | @tsv' 2>/dev/null) \
      || { printf 'ERR:timeline-unparseable\n'; return 1; }
    [ -n "$r" ] && rows="$rows$r"$'\n'
    [ "$len" = 100 ] || break
    p=$((p+1))
  done
  # Stopped by the cap on a FULL page: the rest was never read.
  [ "$p" -le "$max" ] || { printf 'ERR:timeline-capped\n'; return 1; }
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | sort -t$'\t' -k3,3n -u | sort -t$'\t' -k1,1nr -k3,3nr
  return 0
}

#!/bin/bash
# bin/lib/spec-repos.sh — BH-6576: a ticket names the repos its build may READ.
# Sourced by bin/fly-pool.sh; defines functions only.
#
# WHY. A pool machine's GitHub token sees one repo. A project-5 ticket that
# cites a spec file in another repo (example-org/project-6) planned, found the
# file unreadable and stopped PLAN_BLOCKED cross-repo-read. The per-project
# knob lane.fly-pool.<project>.extra_read_repos would fix it by widening EVERY
# build of the project. This line widens ONE ticket's build instead:
#
#   Spec-repo: <owner>/<repo>[, <owner>/<repo> ...]
#
# at the start of a line of the ticket BODY. The pool unions it into the
# BH-5910 read-only token (contents+metadata read) for that ticket's machine.
#
#   spec_repos_parse                  body on stdin -> the declared slugs,
#                                     one per line, deduped, at most 10
#   spec_repos_load <slug> <ticket>   sets SPEC_REPOS (comma list) for one
#                                     GitHub-Issues ticket; rc 0 read (or not
#                                     a GitHub issue), rc 2 unreadable
#   spec_repos_extra <knob> <spec> <own>
#                                     the spec repos the knob and the project
#                                     slug do not already cover, comma list
#   spec_repos_machine_has <json>     rc 0 when the pool machine json carries
#                                     a non-empty .spec_repos
#
# THE LINE. Key `Spec-repo:` or `Spec-repos:`, any case, at the start of the
# line, after optional spaces, a `- ` or `* ` bullet and one backtick. The key
# inside a sentence does not count, and neither does a line in a ``` or ~~~
# fence. Values are owner/repo words split on commas and spaces, each optionally
# in backticks; anything else is dropped. Body only: a comment author must not
# be able to widen a build's read access.
#
# THE READ. spec_repos_load is called as a plain command, never in `$( )`: its
# cache (_SPEC_REPOS_CACHE, one entry per <slug>#<n>, the unreadable answer
# too) lives in the calling shell, so one tick reads each ticket once. The read
# uses SPEC_REPOS_GH_TOKEN when the caller sets it (the pool passes the token
# its gates read the repo with), else the ambient GH_TOKEN. An unreadable body
# fails open: the spawn goes ahead with no spec repos, and the plan gate stops
# a plan that needs one.

declare -gA _SPEC_REPOS_CACHE 2>/dev/null || true
SPEC_REPOS_MAX=10

spec_repos_parse() {
  tr -d '\r' | awk -v max="$SPEC_REPOS_MAX" '
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      m = substr(line, 1, 3)
      if (m == "```" || m == "~~~") {
        if (fence == "") fence = m; else if (fence == m) fence = ""
        next
      }
      if (fence != "") next
      sub(/^[-*][ \t]+/, "", line)
      sub(/^`/, "", line)
      k = tolower(line)
      if (substr(k, 1, 10) == "spec-repo:") v = substr(line, 11)
      else if (substr(k, 1, 11) == "spec-repos:") v = substr(line, 12)
      else next
      gsub(/[`,]/, " ", v)
      n = split(v, w, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] !~ /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/) continue
        lk = tolower(w[i])
        if (lk in seen) continue
        seen[lk] = 1
        if (c < max) { print w[i]; c++ }
      }
    }'
}

spec_repos_load() {
  local slug="${1:-}" tid="${2:-}" key f rc=0 body list
  SPEC_REPOS=""
  # An in-app board ticket (cuid id) has no GitHub issue body to read.
  case "$tid" in ''|*[!0-9]*) return 0 ;; esac
  if [ -z "$slug" ] || ! command -v gh_rest >/dev/null 2>&1; then return 2; fi
  key="$slug#$tid"
  if [ -n "${_SPEC_REPOS_CACHE[$key]+x}" ]; then
    SPEC_REPOS="${_SPEC_REPOS_CACHE[$key]#?:}"
    return "${_SPEC_REPOS_CACHE[$key]%%:*}"
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/spec-repos.XXXXXX") || return 2
  GH_TOKEN="${SPEC_REPOS_GH_TOKEN:-${GH_TOKEN:-}}" gh_rest GET "repos/$slug/issues/$tid" > "$f" || rc=$?
  if [ "$rc" = 0 ]; then
    body=$(jq -r '.body // ""' "$f" 2>/dev/null) || rc=75
  fi
  rm -f "$f"
  if [ "$rc" != 0 ]; then
    echo "spec-repos: $key unreadable (http ${GH_REST_STATUS:-000}) — no spec repos this spawn" >&2
    _SPEC_REPOS_CACHE[$key]="2:"
    return 2
  fi
  list=$(printf '%s\n' "$body" | spec_repos_parse | paste -sd, -)
  _SPEC_REPOS_CACHE[$key]="0:$list"
  SPEC_REPOS="$list"
  return 0
}

spec_repos_extra() {
  local knob=" ${1,,} " own="${3,,}" w out="" seen=" "
  knob="${knob//,/ }"; knob="${knob//$'\t'/ }"; knob="${knob//$'\n'/ }"
  local -a ws=()
  IFS=',' read -r -a ws <<< "${2:-}" || true
  for w in ${ws[@]+"${ws[@]}"}; do
    [ -n "$w" ] && [ "${w,,}" != "$own" ] || continue
    case "$knob$seen" in *" ${w,,} "*) continue ;; esac
    seen="$seen${w,,} "; out="${out:+$out,}$w"
  done
  printf '%s\n' "$out"
}

spec_repos_machine_has() {
  [ -r "${1:-}" ] || return 1
  jq -e '(.spec_repos // "") | tostring | length > 0' "$1" >/dev/null 2>&1
}
